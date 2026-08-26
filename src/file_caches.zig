//! Per-file data the diff view derives from a parsed diff: add/delete counts,
//! renderable line counts, and the gutter width the largest line number needs.
//!
//! Split out of `app.zig` so it can be exercised without standing up an App.

const std = @import("std");
const parser = @import("git/parser.zig");
const rendering_common = @import("rendering/common.zig");

const Allocator = std.mem.Allocator;
const Layout = rendering_common.Layout;
const testing = std.testing;

pub const FileDiffStats = struct {
    additions: usize,
    deletions: usize,
};

/// Derived data for a whole file list. `stats` and `line_counts` are indexed by
/// file, so both are always as long as the list they were built from.
pub const FileCaches = struct {
    stats: []FileDiffStats,
    line_counts: []usize,
    gutter_width: usize,
};

pub fn build(allocator: Allocator, files: []const parser.FileDiff) !FileCaches {
    const stats = try allocator.alloc(FileDiffStats, files.len);
    errdefer allocator.free(stats);

    const line_counts = try allocator.alloc(usize, files.len);
    errdefer allocator.free(line_counts);

    var max_lineno: u32 = 0;
    for (files, 0..) |*file, idx| {
        const measured = measureFile(file);
        stats[idx] = measured.stats;
        line_counts[idx] = measured.line_count;
        max_lineno = @max(max_lineno, measured.max_lineno);
    }

    return .{
        .stats = stats,
        .line_counts = line_counts,
        .gutter_width = gutterWidthFor(max_lineno),
    };
}

/// Extend `caches` with `more`, measuring only the files that are new.
///
/// The loader streams a diff in batches. Rebuilding per batch rewalks every
/// line already walked, which costs O(batches x total lines) and gets worse the
/// longer the diff runs -- exactly when the pause is most visible.
pub fn append(allocator: Allocator, params: struct {
    caches: FileCaches,
    more: []const parser.FileDiff,
}) !FileCaches {
    const first_new = params.caches.stats.len;

    const stats = try allocator.alloc(FileDiffStats, first_new + params.more.len);
    errdefer allocator.free(stats);
    @memcpy(stats[0..first_new], params.caches.stats);

    const line_counts = try allocator.alloc(usize, first_new + params.more.len);
    errdefer allocator.free(line_counts);
    @memcpy(line_counts[0..first_new], params.caches.line_counts);

    var max_lineno: u32 = 0;
    for (params.more, first_new..) |*file, idx| {
        const measured = measureFile(file);
        stats[idx] = measured.stats;
        line_counts[idx] = measured.line_count;
        max_lineno = @max(max_lineno, measured.max_lineno);
    }

    return .{
        .stats = stats,
        .line_counts = line_counts,
        // Gutter width is monotonic in the largest line number, so the width
        // over both halves is the wider of the two. The files already measured
        // do not have to be rewalked to learn that.
        .gutter_width = @max(params.caches.gutter_width, gutterWidthFor(max_lineno)),
    };
}

pub fn countDigits(n: u32) usize {
    if (n == 0) return 1;
    var count: usize = 0;
    var num = n;
    while (num > 0) {
        count += 1;
        num /= 10;
    }
    return count;
}

/// Digits plus one column for the +/- sign, floored at the layout minimum.
pub fn gutterWidthFor(max_lineno: u32) usize {
    return @max(countDigits(max_lineno) + 1, Layout.min_gutter_width);
}

const MeasuredFile = struct {
    stats: FileDiffStats,
    line_count: usize,
    max_lineno: u32,
};

fn measureFile(file: *const parser.FileDiff) MeasuredFile {
    var additions: usize = 0;
    var deletions: usize = 0;
    var line_count: usize = 0;
    var max_lineno: u32 = 0;

    for (file.hunks) |hunk| {
        line_count += hunk.lines.len;
        for (hunk.lines) |line| {
            switch (line.line_type) {
                .add => additions += 1,
                .delete => deletions += 1,
                .context => {},
            }
            if (line.old_lineno) |old| {
                max_lineno = @max(max_lineno, old);
            }
            if (line.new_lineno) |new| {
                max_lineno = @max(max_lineno, new);
            }
        }
    }

    return .{
        .stats = .{ .additions = additions, .deletions = deletions },
        .line_count = line_count,
        .max_lineno = max_lineno,
    };
}

var first_lines = [_]parser.Line{
    .{ .line_type = .context, .content = "ctx", .old_lineno = 7, .new_lineno = 7 },
    .{ .line_type = .add, .content = "new", .old_lineno = null, .new_lineno = 8 },
};
var second_lines = [_]parser.Line{
    .{ .line_type = .delete, .content = "gone", .old_lineno = 41, .new_lineno = null },
};
/// Five-digit line numbers: appending this file has to widen the gutter.
var third_lines = [_]parser.Line{
    .{ .line_type = .add, .content = "deep", .old_lineno = null, .new_lineno = 12345 },
    .{ .line_type = .context, .content = "tail", .old_lineno = 12344, .new_lineno = 12346 },
};

var first_hunks = [_]parser.Hunk{.{
    .header = .{ .old_start = 7, .old_count = 1, .new_start = 7, .new_count = 2, .context = "" },
    .lines = &first_lines,
    .highlights = null,
    .old_highlights = null,
}};
var second_hunks = [_]parser.Hunk{.{
    .header = .{ .old_start = 41, .old_count = 1, .new_start = 41, .new_count = 0, .context = "" },
    .lines = &second_lines,
    .highlights = null,
    .old_highlights = null,
}};
var third_hunks = [_]parser.Hunk{.{
    .header = .{ .old_start = 12344, .old_count = 1, .new_start = 12345, .new_count = 2, .context = "" },
    .lines = &third_lines,
    .highlights = null,
    .old_highlights = null,
}};

const three_files = [_]parser.FileDiff{
    .{ .old_path = "a", .new_path = "a", .hunks = &first_hunks, .is_untracked = false },
    .{ .old_path = "b", .new_path = "b", .hunks = &second_hunks, .is_untracked = false },
    .{ .old_path = "c", .new_path = "c", .hunks = &third_hunks, .is_untracked = false },
};

fn expectMatchesBuild(files: []const parser.FileDiff, split_at: usize) !void {
    const whole = try build(testing.allocator, files);
    defer testing.allocator.free(whole.stats);
    defer testing.allocator.free(whole.line_counts);

    const partial = try build(testing.allocator, files[0..split_at]);
    const appended = try append(testing.allocator, .{ .caches = partial, .more = files[split_at..] });
    testing.allocator.free(partial.stats);
    testing.allocator.free(partial.line_counts);
    defer testing.allocator.free(appended.stats);
    defer testing.allocator.free(appended.line_counts);

    try testing.expectEqualSlices(FileDiffStats, whole.stats, appended.stats);
    try testing.expectEqualSlices(usize, whole.line_counts, appended.line_counts);
    try testing.expectEqual(whole.gutter_width, appended.gutter_width);
}

test "appending the rest of a diff matches building it all at once" {
    try expectMatchesBuild(&three_files, 1);
}

test "appending onto an empty cache matches building it all at once" {
    try expectMatchesBuild(&three_files, 0);
}

test "appending the last file matches building it all at once" {
    try expectMatchesBuild(&three_files, 2);
}

test "appending a file with wider line numbers widens the gutter" {
    const narrow = try build(testing.allocator, three_files[0..2]);
    defer testing.allocator.free(narrow.stats);
    defer testing.allocator.free(narrow.line_counts);

    const widened = try append(testing.allocator, .{ .caches = narrow, .more = three_files[2..] });
    defer testing.allocator.free(widened.stats);
    defer testing.allocator.free(widened.line_counts);

    try testing.expectEqual(@as(usize, Layout.min_gutter_width), narrow.gutter_width);
    try testing.expectEqual(@as(usize, 6), widened.gutter_width);
}

test "gutter width never drops below the layout minimum" {
    try testing.expectEqual(@as(usize, Layout.min_gutter_width), gutterWidthFor(0));
    try testing.expectEqual(@as(usize, Layout.min_gutter_width), gutterWidthFor(9));
}
