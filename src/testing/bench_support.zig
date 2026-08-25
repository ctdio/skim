const std = @import("std");

const app_mod = @import("../app.zig");
const parser = @import("../git/parser.zig");
const state_helpers = @import("../state.zig");
const syntax = @import("../highlighting/core.zig");
const skim_io = @import("skim_io");

const App = app_mod.App;
const StateHelpers = state_helpers.StateHelpers;

pub const SyntheticSpec = struct {
    file_count: usize,
    hunks_per_file: usize,
    lines_per_hunk: usize,
};

pub const Stats = struct {
    samples: []u64,
    min: u64,
    median: u64,
    p90: u64,
    p99: u64,
    avg: u64,
};

/// Reads a `usize` knob from the environment, falling back to `default_value`.
pub fn envUsize(allocator: std.mem.Allocator, name: []const u8, default_value: usize) usize {
    const value = skim_io.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(value);
    if (value.len == 0) return default_value;
    return std.fmt.parseInt(usize, value, 10) catch default_value;
}

/// Reads a `u16` knob from the environment, falling back to `default_value`.
pub fn envU16(allocator: std.mem.Allocator, name: []const u8, default_value: u16) u16 {
    const value = skim_io.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(value);
    if (value.len == 0) return default_value;
    return std.fmt.parseInt(u16, value, 10) catch default_value;
}

/// Reads a boolean knob ("1"/"true"/"yes" are true), falling back to `default_value`.
pub fn envBool(allocator: std.mem.Allocator, name: []const u8, default_value: bool) bool {
    const value = skim_io.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(value);
    if (value.len == 0) return default_value;
    if (std.ascii.eqlIgnoreCase(value, "1")) return true;
    if (std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.ascii.eqlIgnoreCase(value, "yes")) return true;
    return false;
}

/// Reads an owned string knob; caller frees. Returns null when unset or empty.
pub fn envString(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const value = skim_io.getEnvVarOwned(allocator, name) catch return null;
    if (value.len == 0) {
        allocator.free(value);
        return null;
    }
    return value;
}

/// Reads an enum knob by tag name (case-insensitive), falling back to `default_value`.
pub fn envEnum(comptime T: type, allocator: std.mem.Allocator, name: []const u8, default_value: T) T {
    const value = skim_io.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(value);
    if (value.len == 0) return default_value;
    inline for (@typeInfo(T).@"enum".fields) |field| {
        if (std.ascii.eqlIgnoreCase(value, field.name)) return @field(T, field.name);
    }
    return default_value;
}

/// Loads diff text from `SKIM_BENCH_DIFF_PATH` when set, otherwise synthesizes one.
/// Caller owns the returned bytes.
pub fn loadDiffText(allocator: std.mem.Allocator, spec: SyntheticSpec) ![]u8 {
    if (envString(allocator, "SKIM_BENCH_DIFF_PATH")) |path| {
        defer allocator.free(path);
        std.log.info("diff source: file={s}", .{path});
        return std.Io.Dir.cwd().readFileAlloc(skim_io.get(), path, allocator, .limited(100 * 1024 * 1024));
    }
    std.log.info("diff source: synthetic", .{});
    return buildDiffText(allocator, spec);
}

/// Builds a synthetic unified diff with code-shaped content for syntax highlighting.
pub fn buildDiffText(allocator: std.mem.Allocator, spec: SyntheticSpec) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var path_buf: [256]u8 = undefined;
    var header_buf: [256]u8 = undefined;
    var line_buf: [256]u8 = undefined;

    for (0..spec.file_count) |file_idx| {
        const file_path = try std.fmt.bufPrint(&path_buf, "src/bench/file_{d}.zig", .{file_idx});

        try appendLine(allocator, &out, try std.fmt.bufPrint(&header_buf, "diff --git a/{s} b/{s}", .{ file_path, file_path }));
        try appendLine(allocator, &out, try std.fmt.bufPrint(&header_buf, "--- a/{s}", .{file_path}));
        try appendLine(allocator, &out, try std.fmt.bufPrint(&header_buf, "+++ b/{s}", .{file_path}));

        for (0..spec.hunks_per_file) |hunk_idx| {
            const start: u32 = @intCast(1 + hunk_idx * spec.lines_per_hunk);
            const count: u32 = @intCast(spec.lines_per_hunk);
            try appendLine(allocator, &out, try std.fmt.bufPrint(
                &header_buf,
                "@@ -{d},{d} +{d},{d} @@ bench hunk {d}",
                .{ start, count, start, count, hunk_idx },
            ));

            for (0..spec.lines_per_hunk) |line_idx| {
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

/// Runs the syntax highlighter synchronously over every hunk, mirroring the
/// steady state the TUI reaches once async highlighting has settled.
pub fn addHunkHighlights(allocator: std.mem.Allocator, app: *App) !void {
    var highlighter = try syntax.SyntaxHighlighter.init(allocator);
    defer highlighter.deinit();

    for (app.state.files) |*file| {
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;
        for (file.hunks) |*hunk| {
            const content = try StateHelpers.buildHunkContent(allocator, hunk);
            defer allocator.free(content);
            const old_content = try StateHelpers.buildHunkOldContent(allocator, hunk);
            defer allocator.free(old_content);

            hunk.highlights = highlighter.highlightFile(file_path, content) catch null;
            hunk.old_highlights = highlighter.highlightFile(file_path, old_content) catch null;
            StateHelpers.rebuildHunkHighlightCaches(allocator, hunk) catch {};
        }
    }
}

/// Logs a one-line summary of the parsed diff shape.
pub fn logDiffShape(files: []const parser.FileDiff) void {
    var hunks: usize = 0;
    var lines: usize = 0;
    for (files) |file| {
        hunks += file.hunks.len;
        for (file.hunks) |hunk| lines += hunk.lines.len;
    }
    std.log.info("parsed diff: files={d} hunks={d} lines={d}", .{ files.len, hunks, lines });
}

/// Sorts `samples` in place and derives summary statistics from them.
pub fn computeStats(samples: []u64) Stats {
    if (samples.len == 0) {
        return .{ .samples = samples, .min = 0, .median = 0, .p90 = 0, .p99 = 0, .avg = 0 };
    }
    std.mem.sort(u64, samples, {}, comptime std.sort.asc(u64));

    var total: u64 = 0;
    for (samples) |value| total += value;

    const len = samples.len;
    return .{
        .samples = samples,
        .min = samples[0],
        .median = samples[len / 2],
        .p90 = samples[(len * 90) / 100],
        .p99 = samples[(len * 99) / 100],
        .avg = total / @as(u64, @intCast(len)),
    };
}

pub fn nsToUs(ns: u64) u64 {
    return @divTrunc(ns, std.time.ns_per_us);
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
