//! Scroll-session benchmark for the diff view.
//!
//! Unlike `bench_render_content`, this measures the *whole* per-keystroke cost
//! the user actually feels while scrolling:
//!
//!   1. `frame.render` - skim building the next screen into the vaxis buffer
//!   2. `vaxis.render` - diffing against the previous screen and emitting bytes
//!   3. the byte volume itself, which is what the terminal emulator must parse
//!
//! Each iteration advances the viewport (so caches see a moving window, like
//! real scrolling) instead of re-rendering the same offset.

const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("app.zig");
const parser = @import("git/parser.zig");
const frame = @import("rendering/frame.zig");
const scroll_region = @import("rendering/scroll_region.zig");
const navigation = @import("navigation.zig");
const bench = @import("testing/bench_support.zig");
const skim_io = @import("skim_io");

const App = app_mod.App;
const Navigation = navigation.Navigation;

const Motion = enum {
    /// `j` - one line at a time, the worst case for per-frame overhead.
    line,
    /// `Ctrl-d` - half a viewport.
    half_page,
    /// `Ctrl-f` - a full viewport, the worst case for cell churn.
    page,
    /// `]f` - jump between files.
    file,
};

const View = enum { unified, side_by_side, both };

const FrameSamples = struct {
    build_ns: []u64,
    flush_ns: []u64,
    total_ns: []u64,
    bytes: []u64,

    fn alloc(allocator: std.mem.Allocator, count: usize) !FrameSamples {
        return .{
            .build_ns = try allocator.alloc(u64, count),
            .flush_ns = try allocator.alloc(u64, count),
            .total_ns = try allocator.alloc(u64, count),
            .bytes = try allocator.alloc(u64, count),
        };
    }

    fn free(self: FrameSamples, allocator: std.mem.Allocator) void {
        allocator.free(self.build_ns);
        allocator.free(self.flush_ns);
        allocator.free(self.total_ns);
        allocator.free(self.bytes);
    }
};

pub fn main(process_init: std.process.Init) !void {
    skim_io.init(process_init);

    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const spec = bench.SyntheticSpec{
        .file_count = bench.envUsize(allocator, "SKIM_BENCH_FILES", 10),
        .hunks_per_file = bench.envUsize(allocator, "SKIM_BENCH_HUNKS", 6),
        .lines_per_hunk = bench.envUsize(allocator, "SKIM_BENCH_LINES", 60),
    };
    const iterations = bench.envUsize(allocator, "SKIM_BENCH_ITERS", 200);
    const warmup = bench.envUsize(allocator, "SKIM_BENCH_WARMUP", 20);
    const width = bench.envU16(allocator, "SKIM_BENCH_WIDTH", 190);
    const height = bench.envU16(allocator, "SKIM_BENCH_HEIGHT", 60);
    const motion = bench.envEnum(Motion, allocator, "SKIM_BENCH_MOTION", .line);
    const view = bench.envEnum(View, allocator, "SKIM_BENCH_VIEW", .unified);
    const highlight = bench.envBool(allocator, "SKIM_BENCH_HIGHLIGHT", true);

    std.log.info("=== SCROLL BENCH ===", .{});
    std.log.info(
        "motion={s} view={s} size={d}x{d} highlight={} warmup={d} iterations={d}",
        .{ @tagName(motion), @tagName(view), width, height, highlight, warmup, iterations },
    );

    const diff_text = try bench.loadDiffText(allocator, spec);
    defer allocator.free(diff_text);

    const files = try parser.parse(allocator, diff_text);
    errdefer {
        for (files) |*file| file.deinit(allocator);
        allocator.free(files);
    }
    bench.logDiffShape(files);

    var app = try App.initForRenderBench(allocator, files);
    defer app.deinit();

    if (highlight) try bench.addHunkHighlights(allocator, &app);

    std.log.info("line map: records={d}", .{app.state.line_map.records.len});

    switch (view) {
        .unified => try runView(&app, .unified, motion, width, height, iterations, warmup),
        .side_by_side => try runView(&app, .side_by_side, motion, width, height, iterations, warmup),
        .both => {
            try runView(&app, .unified, motion, width, height, iterations, warmup);
            try runView(&app, .side_by_side, motion, width, height, iterations, warmup);
        },
    }
}

fn runView(
    app: *App,
    view: View,
    motion: Motion,
    width: u16,
    height: u16,
    iterations: usize,
    warmup: usize,
) !void {
    const allocator = app.allocator;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var vx = try vaxis.init(skim_io.get(), allocator, skim_io.environMap(), .{});
    defer vx.screen.deinit(allocator);
    defer vx.screen_last.deinit(allocator);

    // Pretend we are in the alt screen so vaxis emits the same cursor motion it
    // would in the real TUI rather than the scrollback-relative variant.
    vx.state.alt_screen = true;
    try vx.resize(allocator, &out.writer, .{ .rows = height, .cols = width, .x_pixel = 0, .y_pixel = 0 });
    out.clearRetainingCapacity();

    app.state.view_mode = if (view == .unified) .unified else .side_by_side;
    app.state.global_scroll_offset = 0;
    app.state.global_cursor_line = 0;

    // Prime the viewport dimensions and the last-screen diff baseline.
    try frame.render(app, vx.window());
    try vx.render(&out.writer);
    out.clearRetainingCapacity();

    var samples = try FrameSamples.alloc(allocator, iterations);
    defer samples.free(allocator);

    var sample_idx: usize = 0;
    var iteration: usize = 0;
    while (iteration < warmup + iterations) : (iteration += 1) {
        advance(app, motion);

        var timer = try skim_io.Timer.start();
        try frame.render(app, vx.window());
        const build_ns = timer.read();

        out.clearRetainingCapacity();
        _ = try scroll_region.apply(&vx, &out.writer);
        try vx.render(&out.writer);
        try out.writer.flush();
        const total_ns = timer.read();

        if (iteration >= warmup) {
            samples.build_ns[sample_idx] = build_ns;
            samples.flush_ns[sample_idx] = total_ns - build_ns;
            samples.total_ns[sample_idx] = total_ns;
            samples.bytes[sample_idx] = out.written().len;
            sample_idx += 1;
        }
    }

    report(@tagName(view), samples);
}

/// Applies one navigation step, wrapping back to the top when the motion runs
/// off the end so a long run keeps exercising fresh content.
fn advance(app: *App, motion: Motion) void {
    const before_scroll = app.state.global_scroll_offset;
    const before_cursor = app.state.global_cursor_line;
    switch (motion) {
        .line => Navigation.moveCursorDown(app),
        .half_page => Navigation.pageDown(app),
        .page => Navigation.fullPageDown(app),
        .file => Navigation.navigateToNextFile(app),
    }
    const stalled = app.state.global_scroll_offset == before_scroll and
        app.state.global_cursor_line == before_cursor;
    if (stalled) {
        app.state.global_scroll_offset = 0;
        app.state.global_cursor_line = 0;
    }
}

fn report(label: []const u8, samples: FrameSamples) void {
    const build = bench.computeStats(samples.build_ns);
    const flush = bench.computeStats(samples.flush_ns);
    const total = bench.computeStats(samples.total_ns);
    const bytes = bench.computeStats(samples.bytes);

    const fps = if (total.avg == 0) 0 else @as(u64, @intFromFloat(1_000_000_000.0 / @as(f64, @floatFromInt(total.avg))));

    std.log.info("{s} frame.render : min={d}us p50={d}us p90={d}us p99={d}us avg={d}us", .{
        label, bench.nsToUs(build.min), bench.nsToUs(build.median), bench.nsToUs(build.p90), bench.nsToUs(build.p99), bench.nsToUs(build.avg),
    });
    std.log.info("{s} vaxis.render : min={d}us p50={d}us p90={d}us p99={d}us avg={d}us", .{
        label, bench.nsToUs(flush.min), bench.nsToUs(flush.median), bench.nsToUs(flush.p90), bench.nsToUs(flush.p99), bench.nsToUs(flush.avg),
    });
    std.log.info("{s} total        : min={d}us p50={d}us p90={d}us p99={d}us avg={d}us (~{d} fps)", .{
        label, bench.nsToUs(total.min), bench.nsToUs(total.median), bench.nsToUs(total.p90), bench.nsToUs(total.p99), bench.nsToUs(total.avg), fps,
    });
    std.log.info("{s} bytes/frame  : min={d} p50={d} p90={d} p99={d} avg={d}", .{
        label, bytes.min, bytes.median, bytes.p90, bytes.p99, bytes.avg,
    });
}
