//! Paging benchmark that drives the *real* loop: live highlight worker, real
//! frame pacer, and a terminal that can push back.
//!
//! `bench_scroll` answers "what does one frame cost" against a writer that
//! never blocks. That is not the situation the user is in. While paging, three
//! things interact:
//!
//!   1. `Ctrl-d` exposes hunks nobody has parsed yet, and the worker races to
//!      style them before the frame is drawn.
//!   2. The frame pacer holds the next frame for as long as the previous write
//!      took, so a terminal that falls behind changes when frames happen.
//!   3. Key repeat keeps arriving regardless, so held keys coalesce.
//!
//! `SKIM_BENCH_DRAIN_KBPS` is what makes 2 observable: frames are written to a
//! pipe drained at a fixed byte rate, so a write blocks exactly the way it does
//! against a slow terminal or an ssh link. With it unset the writer is memory
//! and the bench measures the pipeline alone.
//!
//! Reported:
//!   - pop-in: share of visible code rows still unstyled when a frame is drawn.
//!   - gap p50/p99/max: wall clock between consecutive frames. Smoothness is
//!     low spread; a p99 far above p50 is the stutter, quantified.
//!   - lag: keystroke to the frame that first showed it.
//!   - bytes/page and backlog, as before.

const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("app.zig");
const parser = @import("git/parser.zig");
const frame = @import("rendering/frame.zig");
const frame_pacer = @import("rendering/frame_pacer.zig");
const scroll_region = @import("rendering/scroll_region.zig");
const navigation = @import("navigation.zig");
const bench = @import("testing/bench_support.zig");
const skim_io = @import("skim_io");

const App = app_mod.App;
const Navigation = navigation.Navigation;
const FramePacer = frame_pacer.FramePacer;

/// Drains a pipe at a fixed byte rate, so the writer on the other end blocks
/// the way it does against a terminal that parses slower than skim emits.
const Drain = struct {
    read_fd: std.c.fd_t,
    bytes_per_sec: u64,
    stop: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,

    fn run(self: *Drain) void {
        // One 4KB sip, then sleep however long that many bytes are worth.
        var buf: [4096]u8 = undefined;
        const sip_ns = 4096 * std.time.ns_per_s / @max(self.bytes_per_sec, 1);
        while (!self.stop.load(.acquire)) {
            const n = std.c.read(self.read_fd, &buf, buf.len);
            if (n <= 0) break;
            skim_io.sleep(@intCast(@as(u64, @intCast(n)) * sip_ns / 4096));
        }
    }
};

pub fn main(process_init: std.process.Init) !void {
    skim_io.init(process_init);
    const allocator = std.heap.c_allocator;

    const spec = bench.SyntheticSpec{
        .file_count = bench.envUsize(allocator, "SKIM_BENCH_FILES", 40),
        .hunks_per_file = bench.envUsize(allocator, "SKIM_BENCH_HUNKS", 8),
        .lines_per_hunk = bench.envUsize(allocator, "SKIM_BENCH_LINES", 60),
    };
    const pages = bench.envUsize(allocator, "SKIM_BENCH_PAGES", 120);
    const page_ms = bench.envUsize(allocator, "SKIM_BENCH_PAGE_MS", 40);
    const width = bench.envU16(allocator, "SKIM_BENCH_WIDTH", 190);
    const height = bench.envU16(allocator, "SKIM_BENCH_HEIGHT", 60);
    const side_by_side = bench.envBool(allocator, "SKIM_BENCH_SBS", false);
    const scroll_up = bench.envBool(allocator, "SKIM_BENCH_UP", false);
    const drain_kbps = bench.envUsize(allocator, "SKIM_BENCH_DRAIN_KBPS", 0);

    std.log.info("=== HIGHLIGHT PAGING BENCH ===", .{});
    std.log.info(
        "pages={d} page_ms={d} size={d}x{d} view={s} dir={s} drain={d}KB/s",
        .{
            pages,                                           page_ms,
            width,                                           height,
            if (side_by_side) "side_by_side" else "unified", if (scroll_up) "up" else "down",
            drain_kbps,
        },
    );

    const diff_text = try bench.loadDiffText(allocator, spec);
    defer allocator.free(diff_text);

    const files = try parser.parse(allocator, diff_text);
    bench.logDiffShape(files);

    var app = try App.initForRenderBench(allocator, files);
    defer app.deinit();

    app.state.view_mode = if (side_by_side) .side_by_side else .unified;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var scroller: scroll_region.Scroller = .{ .allocator = allocator };
    defer scroller.deinit();

    var vx = try vaxis.init(skim_io.get(), allocator, skim_io.environMap(), .{});
    defer vx.screen.deinit(allocator);
    defer vx.screen_last.deinit(allocator);

    vx.state.alt_screen = true;
    try vx.resize(allocator, &out.writer, .{ .rows = height, .cols = width, .x_pixel = 0, .y_pixel = 0 });
    out.clearRetainingCapacity();

    try frame.render(&app, vx.window());
    try vx.render(&out.writer);
    out.clearRetainingCapacity();

    // Optional slow consumer.
    var pipe_fds: [2]std.c.fd_t = .{ -1, -1 };
    var drain: Drain = undefined;
    const throttled = drain_kbps > 0;
    if (throttled) {
        if (std.c.pipe(&pipe_fds) != 0) return error.PipeFailed;
        drain = .{ .read_fd = pipe_fds[0], .bytes_per_sec = drain_kbps * 1024 };
        drain.thread = try std.Thread.spawn(.{}, Drain.run, .{&drain});
    }
    defer if (throttled) {
        drain.stop.store(true, .release);
        _ = std.c.close(pipe_fds[1]);
        drain.thread.join();
        _ = std.c.close(pipe_fds[0]);
    };

    if (scroll_up) {
        app.state.global_scroll_offset = app.getTotalGlobalLines() -| 1;
        app.state.global_cursor_line = app.state.global_scroll_offset;
    }

    var stats: Stats = .{};
    var gaps: std.ArrayList(u64) = .empty;
    defer gaps.deinit(allocator);
    var lags: std.ArrayList(u64) = .empty;
    defer lags.deinit(allocator);

    var pacer: FramePacer = .{};
    var clock = try skim_io.Timer.start();

    const page_ns = page_ms * std.time.ns_per_ms;
    const run_ns = page_ns * pages;

    var next_key_ns: u64 = page_ns;
    var keys: u64 = 0;
    var pending_key_ns: ?u64 = null;
    var last_frame_ns: u64 = 0;

    while (true) {
        const now = clock.read();
        if (now >= run_ns) break;

        // Key repeat, arriving whether or not the last frame has been drawn.
        if (now >= next_key_ns and keys < pages) {
            if (scroll_up) Navigation.pageUp(&app) else Navigation.pageDown(&app);
            app.needs_render = true;
            keys += 1;
            next_key_ns += page_ns;
            if (pending_key_ns == null) pending_key_ns = now;
            stats.backlog_total += app.highlighter_jobs.pendingCount();
            stats.backlog_peak = @max(stats.backlog_peak, app.highlighter_jobs.pendingCount());
        }

        if (app.highlighter_jobs.applyResults(.{
            .files = app.state.files,
            .current_file_idx = app.state.current_file_idx,
        })) app.needs_render = true;

        if (app.needs_render and pacer.shouldRender(clock.read())) {
            const rows = countVisibleRows(&app);
            stats.unstyled_rows += rows.unstyled;
            stats.total_rows += rows.total;

            var build_timer = try skim_io.Timer.start();
            try frame.render(&app, vx.window());
            stats.build_ns += build_timer.read();

            out.clearRetainingCapacity();
            _ = try scroller.apply(&vx, &out.writer);
            try vx.render(&out.writer);
            try out.writer.flush();
            const payload = out.written();

            var write_timer = try skim_io.Timer.start();
            if (throttled) writeAll(pipe_fds[1], payload);
            const write_ns = write_timer.read();

            stats.bytes += payload.len;
            stats.frames += 1;
            app.needs_render = false;

            const drawn_at = clock.read();
            if (last_frame_ns > 0) try gaps.append(allocator, drawn_at -| last_frame_ns);
            last_frame_ns = drawn_at;
            if (pending_key_ns) |key_at| {
                try lags.append(allocator, drawn_at -| key_at);
                pending_key_ns = null;
            }

            pacer.recordFrame(drawn_at, write_ns);
        }

        _ = app.highlighter_jobs.submitVisible(.{
            .files = app.state.files,
            .line_map = &app.state.line_map,
            .viewport = .{
                .scroll_offset = app.state.global_scroll_offset,
                .height = app.state.viewport_height,
            },
        });

        skim_io.sleep(std.time.ns_per_ms);
    }

    stats.keys = keys;
    report(stats, gaps.items, lags.items);
}

const Stats = struct {
    frames: u64 = 0,
    keys: u64 = 0,
    bytes: u64 = 0,
    unstyled_rows: u64 = 0,
    total_rows: u64 = 0,
    backlog_total: u64 = 0,
    backlog_peak: u64 = 0,
    build_ns: u64 = 0,
};

const RowCount = struct { total: u64, unstyled: u64 };

/// Counts the code rows in the viewport and how many sit in a hunk with no
/// highlights yet. Headers and spacers have nothing to style, so neither counts.
fn countVisibleRows(app: *const App) RowCount {
    var count: RowCount = .{ .total = 0, .unstyled = 0 };

    const start = app.state.global_scroll_offset;
    const end = @min(start + app.state.viewport_height, app.state.line_map.getTotalLines());

    var line = start;
    while (line < end) : (line += 1) {
        const record = app.state.line_map.getLineRecord(line) orelse continue;
        const code = switch (record.line_type) {
            .code_line => |code_line| code_line,
            else => continue,
        };
        if (record.file_idx >= app.state.files.len) continue;
        const file = &app.state.files[record.file_idx];
        if (code.hunk_idx >= file.hunks.len) continue;

        count.total += 1;
        if (file.hunks[code.hunk_idx].highlights == null) count.unstyled += 1;
    }

    return count;
}

fn writeAll(fd: std.c.fd_t, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (n <= 0) return;
        offset += @intCast(n);
    }
}

fn report(stats: Stats, gaps: []u64, lags: []u64) void {
    const keys = @max(stats.keys, 1);
    const pop_in_pct = if (stats.total_rows == 0) 0 else stats.unstyled_rows * 100 / stats.total_rows;

    const gap = bench.computeStats(gaps);
    const lag = bench.computeStats(lags);

    std.log.info("pop-in       : {d}% of visible code rows unstyled at paint", .{pop_in_pct});
    std.log.info("frames/page  : {d}.{d:0>2}", .{ stats.frames / keys, (stats.frames * 100 / keys) % 100 });
    std.log.info("frame gap    : p50={d}ms p90={d}ms p99={d}ms max={d}ms", .{
        gap.median / std.time.ns_per_ms,
        gap.p90 / std.time.ns_per_ms,
        gap.p99 / std.time.ns_per_ms,
        if (gaps.len == 0) 0 else gaps[gaps.len - 1] / std.time.ns_per_ms,
    });
    std.log.info("key->frame   : p50={d}ms p90={d}ms p99={d}ms", .{
        lag.median / std.time.ns_per_ms,
        lag.p90 / std.time.ns_per_ms,
        lag.p99 / std.time.ns_per_ms,
    });
    std.log.info("bytes/page   : {d}", .{stats.bytes / keys});
    std.log.info("backlog      : avg={d} peak={d} hunks queued at keystroke", .{ stats.backlog_total / keys, stats.backlog_peak });
    std.log.info("build/page   : {d}us of frame.render", .{stats.build_ns / keys / std.time.ns_per_us});
    std.log.info("totals       : keys={d} frames={d} bytes={d}", .{ stats.keys, stats.frames, stats.bytes });
}
