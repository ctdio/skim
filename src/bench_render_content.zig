const std = @import("std");

const app_mod = @import("app.zig");
const parser = @import("git/parser.zig");
const state_helpers = @import("state.zig");
const syntax = @import("highlighting/core.zig");
const harness = @import("testing/harness.zig");
const unified = @import("rendering/unified.zig");
const side_by_side = @import("rendering/side_by_side.zig");
const render_utils = @import("rendering/utils.zig");
const search = @import("search.zig");

const App = app_mod.App;
const StateHelpers = state_helpers.StateHelpers;
const UnifiedRenderer = unified.UnifiedRenderer;
const SideBySideRenderer = side_by_side.SideBySideRenderer;
const RenderUtils = render_utils.RenderUtils;

const BenchView = enum {
    unified,
    side_by_side,
    both,
};

const BenchStats = struct {
    samples: []u64,
    min: u64,
    median: u64,
    p90: u64,
    p99: u64,
    avg: u64,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const file_count = readEnvUsize(allocator, "SKIM_BENCH_FILES", 10);
    const hunks_per_file = readEnvUsize(allocator, "SKIM_BENCH_HUNKS", 6);
    const lines_per_hunk = readEnvUsize(allocator, "SKIM_BENCH_LINES", 60);
    const iterations = readEnvUsize(allocator, "SKIM_BENCH_ITERS", 200);
    const warmup = readEnvUsize(allocator, "SKIM_BENCH_WARMUP", 20);
    const width = readEnvU16(allocator, "SKIM_BENCH_WIDTH", 190);
    const height = readEnvU16(allocator, "SKIM_BENCH_HEIGHT", 60);
    const scroll_offset = readEnvUsize(allocator, "SKIM_BENCH_SCROLL", 0);
    const view = readEnvView(allocator, "SKIM_BENCH_VIEW", .unified);
    const diff_path = readEnvString(allocator, "SKIM_BENCH_DIFF_PATH");
    defer if (diff_path) |path| allocator.free(path);
    const search_query = readEnvString(allocator, "SKIM_BENCH_SEARCH");
    defer if (search_query) |query| allocator.free(query);

    std.log.info("=== RENDER CONTENT BENCH ===", .{});
    std.log.info("files={d} hunks={d} lines={d} view={s} size={d}x{d} warmup={d} iterations={d} scroll={d}", .{
        file_count,
        hunks_per_file,
        lines_per_hunk,
        @tagName(view),
        width,
        height,
        warmup,
        iterations,
        scroll_offset,
    });

    const diff_text = if (diff_path) |path|
        try std.fs.cwd().readFileAlloc(allocator, path, 100 * 1024 * 1024)
    else
        try buildDiffText(allocator, file_count, hunks_per_file, lines_per_hunk);
    defer allocator.free(diff_text);

    if (diff_path) |path| {
        std.log.info("diff source: file={s}", .{path});
    } else {
        std.log.info("diff source: synthetic", .{});
    }

    const files = try parser.parse(allocator, diff_text);
    errdefer {
        for (files) |*file| {
            file.deinit(allocator);
        }
        allocator.free(files);
    }

    var parsed_hunks: usize = 0;
    var parsed_lines: usize = 0;
    for (files) |*file| {
        parsed_hunks += file.hunks.len;
        for (file.hunks) |hunk| {
            parsed_lines += hunk.lines.len;
        }
    }
    std.log.info("parsed diff: files={d} hunks={d} lines={d}", .{ files.len, parsed_hunks, parsed_lines });

    var app = try App.initForRenderBench(allocator, files);
    defer app.deinit();

    try addHunkHighlights(allocator, &app);

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
        .unified => {
            const stats = try runBench(&app, win, .unified, iterations, warmup);
            reportStats("unified", stats);
            allocator.free(stats.samples);
        },
        .side_by_side => {
            const stats = try runBench(&app, win, .side_by_side, iterations, warmup);
            reportStats("side_by_side", stats);
            allocator.free(stats.samples);
        },
        .both => {
            const unified_stats = try runBench(&app, win, .unified, iterations, warmup);
            reportStats("unified", unified_stats);
            allocator.free(unified_stats.samples);

            const side_stats = try runBench(&app, win, .side_by_side, iterations, warmup);
            reportStats("side_by_side", side_stats);
            allocator.free(side_stats.samples);
        },
    }
}

fn readEnvUsize(allocator: std.mem.Allocator, name: []const u8, default_value: usize) usize {
    const env_value = std.process.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(env_value);
    if (env_value.len == 0) return default_value;
    return std.fmt.parseInt(usize, env_value, 10) catch default_value;
}

fn readEnvU16(allocator: std.mem.Allocator, name: []const u8, default_value: u16) u16 {
    const env_value = std.process.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(env_value);
    if (env_value.len == 0) return default_value;
    const parsed = std.fmt.parseInt(u16, env_value, 10) catch return default_value;
    return parsed;
}

fn readEnvView(allocator: std.mem.Allocator, name: []const u8, default_value: BenchView) BenchView {
    const env_value = std.process.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(env_value);
    if (env_value.len == 0) return default_value;

    if (std.ascii.eqlIgnoreCase(env_value, "unified")) return .unified;
    if (std.ascii.eqlIgnoreCase(env_value, "side")) return .side_by_side;
    if (std.ascii.eqlIgnoreCase(env_value, "side_by_side")) return .side_by_side;
    if (std.ascii.eqlIgnoreCase(env_value, "both")) return .both;
    return default_value;
}

fn readEnvString(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const env_value = std.process.getEnvVarOwned(allocator, name) catch return null;
    if (env_value.len == 0) {
        allocator.free(env_value);
        return null;
    }
    return env_value;
}

fn buildDiffText(
    allocator: std.mem.Allocator,
    file_count: usize,
    hunks_per_file: usize,
    lines_per_hunk: usize,
) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    var path_buf: [256]u8 = undefined;
    var header_buf: [256]u8 = undefined;
    var line_buf: [256]u8 = undefined;

    for (0..file_count) |file_idx| {
        const file_path = try std.fmt.bufPrint(&path_buf, "src/bench/file_{d}.zig", .{file_idx});

        try appendLine(allocator, &out, try std.fmt.bufPrint(&header_buf, "diff --git a/{s} b/{s}", .{ file_path, file_path }));
        try appendLine(allocator, &out, try std.fmt.bufPrint(&header_buf, "--- a/{s}", .{file_path}));
        try appendLine(allocator, &out, try std.fmt.bufPrint(&header_buf, "+++ b/{s}", .{file_path}));

        for (0..hunks_per_file) |hunk_idx| {
            const start = @as(u32, @intCast(1 + hunk_idx * lines_per_hunk));
            const count = @as(u32, @intCast(lines_per_hunk));
            try appendLine(allocator, &out, try std.fmt.bufPrint(&header_buf, "@@ -{d},{d} +{d},{d} @@ bench hunk {d}", .{ start, count, start, count, hunk_idx }));

            for (0..lines_per_hunk) |line_idx| {
                const content = try std.fmt.bufPrint(
                    &line_buf,
                    "const value_{d} = {d}; if (value_{d} > 3) {{ return \"alpha\"; }} else {{ return \"beta\"; }}",
                    .{ line_idx, line_idx, line_idx },
                );
                switch (line_idx % 3) {
                    0 => try appendPrefixedLine(allocator, &out, ' ', content),
                    1 => try appendPrefixedLine(allocator, &out, '+', content),
                    else => try appendPrefixedLine(allocator, &out, '-', content),
                }
            }
        }
    }

    return out.toOwnedSlice(allocator);
}

fn appendLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    try out.appendSlice(allocator, line);
    try out.append(allocator, '\n');
}

fn appendPrefixedLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), prefix: u8, line: []const u8) !void {
    try out.append(allocator, prefix);
    try out.appendSlice(allocator, line);
    try out.append(allocator, '\n');
}

fn addHunkHighlights(allocator: std.mem.Allocator, app: *App) !void {
    var highlighter = try syntax.SyntaxHighlighter.init(allocator);
    defer highlighter.deinit();

    for (app.state.files) |*file| {
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;
        for (file.hunks) |*hunk| {
            const content = try StateHelpers.buildHunkContent(allocator, hunk);
            defer allocator.free(content);
            const old_content = try StateHelpers.buildHunkOldContent(allocator, hunk);
            defer allocator.free(old_content);

            const highlights = highlighter.highlightFile(file_path, content) catch null;
            const old_highlights = highlighter.highlightFile(file_path, old_content) catch null;
            hunk.highlights = highlights;
            hunk.old_highlights = old_highlights;
            StateHelpers.rebuildHunkHighlightCaches(allocator, hunk) catch {};
        }
    }
}

fn runBench(app: *App, win: harness.Window, view: BenchView, iterations: usize, warmup: usize) !BenchStats {
    var samples = try app.allocator.alloc(u64, iterations);
    var sample_idx: usize = 0;

    var iteration: usize = 0;
    while (iteration < warmup + iterations) : (iteration += 1) {
        if (view == .unified) {
            app.state.view_mode = .unified;
        } else {
            app.state.view_mode = .side_by_side;
        }

        app.resetFrameAllocators();
        const start_ns = std.time.nanoTimestamp();
        switch (view) {
            .unified => try UnifiedRenderer.renderContent(app, win),
            .side_by_side => try SideBySideRenderer.renderContent(app, win),
            .both => unreachable,
        }
        const elapsed = std.time.nanoTimestamp() - start_ns;

        if (iteration >= warmup) {
            samples[sample_idx] = @intCast(elapsed);
            sample_idx += 1;
        }
    }

    const stats = computeStats(samples);
    return stats;
}

fn computeStats(samples: []u64) BenchStats {
    if (samples.len == 0) {
        return .{ .samples = samples, .min = 0, .median = 0, .p90 = 0, .p99 = 0, .avg = 0 };
    }
    const sorted = samples;
    std.mem.sort(u64, sorted, {}, comptime std.sort.asc(u64));

    var total: u64 = 0;
    for (sorted) |value| total += value;

    const len = sorted.len;
    const median = sorted[len / 2];
    const p90 = sorted[(len * 90) / 100];
    const p99 = sorted[(len * 99) / 100];

    return .{
        .samples = samples,
        .min = sorted[0],
        .median = median,
        .p90 = p90,
        .p99 = p99,
        .avg = if (len == 0) 0 else total / @as(u64, @intCast(len)),
    };
}

fn reportStats(label: []const u8, stats: BenchStats) void {
    const avg_fps = if (stats.avg == 0) 0 else @as(u64, @intFromFloat(1_000_000_000.0 / @as(f64, @floatFromInt(stats.avg))));
    std.log.info(
        "{s}: min={d}us p50={d}us p90={d}us p99={d}us avg={d}us (~{d} fps)",
        .{ label, nsToUs(stats.min), nsToUs(stats.median), nsToUs(stats.p90), nsToUs(stats.p99), nsToUs(stats.avg), avg_fps },
    );
}

fn nsToUs(ns: u64) u64 {
    return @divTrunc(ns, std.time.ns_per_us);
}
