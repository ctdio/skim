//! Isolated diff-content render benchmark.
//!
//! Measures `UnifiedRenderer.renderContent` / `SideBySideRenderer.renderContent`
//! at a fixed scroll offset — useful for attributing cost inside the content
//! renderers. For the cost a user actually feels while scrolling (full frame +
//! vaxis diff + emitted bytes), use `bench_scroll`.

const std = @import("std");

const app_mod = @import("app.zig");
const parser = @import("git/parser.zig");
const harness = @import("testing/harness.zig");
const unified = @import("rendering/unified.zig");
const side_by_side = @import("rendering/side_by_side.zig");
const search = @import("search.zig");
const bench = @import("testing/bench_support.zig");
const skim_io = @import("skim_io");

const App = app_mod.App;
const UnifiedRenderer = unified.UnifiedRenderer;
const SideBySideRenderer = side_by_side.SideBySideRenderer;

const BenchView = enum { unified, side_by_side, both };

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
    const scroll_offset = bench.envUsize(allocator, "SKIM_BENCH_SCROLL", 0);
    const view = bench.envEnum(BenchView, allocator, "SKIM_BENCH_VIEW", .unified);
    const search_query = bench.envString(allocator, "SKIM_BENCH_SEARCH");
    defer if (search_query) |query| allocator.free(query);

    std.log.info("=== RENDER CONTENT BENCH ===", .{});
    std.log.info("files={d} hunks={d} lines={d} view={s} size={d}x{d} warmup={d} iterations={d} scroll={d}", .{
        spec.file_count,
        spec.hunks_per_file,
        spec.lines_per_hunk,
        @tagName(view),
        width,
        height,
        warmup,
        iterations,
        scroll_offset,
    });

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

    try bench.addHunkHighlights(allocator, &app);

    if (search_query) |query| {
        const query_len = @min(query.len, app.state.search_state.query_buffer.len);
        @memcpy(app.state.search_state.query_buffer[0..query_len], query[0..query_len]);
        app.state.search_state.query_len = query_len;
        try search.performSearch(&app.state.search_state, &app.state.line_map, app.state.files);
        std.log.info("search enabled: query='{s}' matches={d}", .{ query[0..query_len], app.state.search_state.matches.items.len });
    } else {
        std.log.info("search disabled", .{});
    }

    var ctx = try harness.createTestContext(allocator, width, height);
    defer ctx.deinit();
    const win = ctx.window();

    app.state.global_scroll_offset = @min(scroll_offset, app.state.line_map.records.len);
    app.state.global_cursor_line = app.state.global_scroll_offset;

    switch (view) {
        .unified => try runBench(&app, win, .unified, iterations, warmup),
        .side_by_side => try runBench(&app, win, .side_by_side, iterations, warmup),
        .both => {
            try runBench(&app, win, .unified, iterations, warmup);
            try runBench(&app, win, .side_by_side, iterations, warmup);
        },
    }
}

fn runBench(app: *App, win: harness.Window, view: BenchView, iterations: usize, warmup: usize) !void {
    const samples = try app.allocator.alloc(u64, iterations);
    defer app.allocator.free(samples);

    var sample_idx: usize = 0;
    var iteration: usize = 0;
    while (iteration < warmup + iterations) : (iteration += 1) {
        app.state.view_mode = if (view == .unified) .unified else .side_by_side;
        app.resetFrameAllocators();

        var timer = try skim_io.Timer.start();
        switch (view) {
            .unified => try UnifiedRenderer.renderContent(app, win),
            .side_by_side => try SideBySideRenderer.renderContent(app, win),
            .both => unreachable,
        }
        const elapsed = timer.read();

        if (iteration >= warmup) {
            samples[sample_idx] = elapsed;
            sample_idx += 1;
        }
    }

    const stats = bench.computeStats(samples);
    const avg_fps = if (stats.avg == 0) 0 else @as(u64, @intFromFloat(1_000_000_000.0 / @as(f64, @floatFromInt(stats.avg))));
    std.log.info("{s}: min={d}us p50={d}us p90={d}us p99={d}us avg={d}us (~{d} fps)", .{
        @tagName(view),
        bench.nsToUs(stats.min),
        bench.nsToUs(stats.median),
        bench.nsToUs(stats.p90),
        bench.nsToUs(stats.p99),
        bench.nsToUs(stats.avg),
        avg_fps,
    });
}
