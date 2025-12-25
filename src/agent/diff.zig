const std = @import("std");
const Allocator = std.mem.Allocator;

// =============================================================================
// Line-Level Diff Algorithm
// =============================================================================
// Simple diff algorithm that computes line-level differences between two texts.
// Uses a greedy longest common subsequence approach for reasonable performance.

pub const DiffLine = struct {
    kind: Kind,
    content: []const u8,
    old_line_num: ?usize, // Line number in old text (1-based)
    new_line_num: ?usize, // Line number in new text (1-based)

    pub const Kind = enum {
        context, // Line exists in both old and new
        add, // Line only in new
        delete, // Line only in old
    };
};

pub const DiffResult = struct {
    lines: []DiffLine,
    additions: usize,
    deletions: usize,
    allocator: Allocator,

    pub fn deinit(self: *DiffResult) void {
        self.allocator.free(self.lines);
    }
};

/// Compute line-level diff between old_text and new_text.
/// Returns a list of DiffLines with proper line numbers.
/// old_start_line: Starting line number for old_text (defaults to 1 if null)
/// new_start_line: Starting line number for new_text (defaults to 1 if null)
pub fn computeDiff(
    allocator: Allocator,
    old_text: []const u8,
    new_text: []const u8,
    old_start_line: ?usize,
    new_start_line: ?usize,
) !DiffResult {
    // Use provided starting line numbers, or default to 1
    const old_start = old_start_line orelse 1;
    const new_start = new_start_line orelse 1;

    // Split into lines
    var old_lines_list: std.ArrayList([]const u8) = .{};
    defer old_lines_list.deinit(allocator);
    var new_lines_list: std.ArrayList([]const u8) = .{};
    defer new_lines_list.deinit(allocator);

    var old_iter = std.mem.splitScalar(u8, old_text, '\n');
    while (old_iter.next()) |line| {
        try old_lines_list.append(allocator, line);
    }
    var new_iter = std.mem.splitScalar(u8, new_text, '\n');
    while (new_iter.next()) |line| {
        try new_lines_list.append(allocator, line);
    }

    const old_lines = old_lines_list.items;
    const new_lines = new_lines_list.items;

    // Use Myers-like diff algorithm with LCS
    var result: std.ArrayList(DiffLine) = .{};
    errdefer result.deinit(allocator);

    var additions: usize = 0;
    var deletions: usize = 0;

    // Simple O(n*m) LCS-based diff
    // Build LCS table
    const m = old_lines.len;
    const n = new_lines.len;

    if (m == 0 and n == 0) {
        return DiffResult{
            .lines = try result.toOwnedSlice(allocator),
            .additions = 0,
            .deletions = 0,
            .allocator = allocator,
        };
    }

    // For empty old, everything is added
    if (m == 0) {
        for (new_lines, 0..) |line, i| {
            try result.append(allocator, .{
                .kind = .add,
                .content = line,
                .old_line_num = null,
                .new_line_num = new_start + i,
            });
            additions += 1;
        }
        return DiffResult{
            .lines = try result.toOwnedSlice(allocator),
            .additions = additions,
            .deletions = 0,
            .allocator = allocator,
        };
    }

    // For empty new, everything is deleted
    if (n == 0) {
        for (old_lines, 0..) |line, i| {
            try result.append(allocator, .{
                .kind = .delete,
                .content = line,
                .old_line_num = old_start + i,
                .new_line_num = null,
            });
            deletions += 1;
        }
        return DiffResult{
            .lines = try result.toOwnedSlice(allocator),
            .additions = 0,
            .deletions = deletions,
            .allocator = allocator,
        };
    }

    // Build LCS table for backtracking
    const lcs_table = try allocator.alloc([]usize, m + 1);
    defer {
        for (lcs_table) |row| allocator.free(row);
        allocator.free(lcs_table);
    }
    for (lcs_table, 0..) |*row, i| {
        row.* = try allocator.alloc(usize, n + 1);
        @memset(row.*, 0);
        if (i > 0) {
            for (0..n + 1) |j| {
                if (j == 0) {
                    row.*[j] = 0;
                } else if (std.mem.eql(u8, old_lines[i - 1], new_lines[j - 1])) {
                    row.*[j] = lcs_table[i - 1][j - 1] + 1;
                } else {
                    row.*[j] = @max(lcs_table[i - 1][j], row.*[j - 1]);
                }
            }
        }
    }

    // Backtrack to produce diff
    var diff_lines: std.ArrayList(DiffLine) = .{};
    defer diff_lines.deinit(allocator);

    var i: usize = m;
    var j: usize = n;

    while (i > 0 or j > 0) {
        if (i > 0 and j > 0 and std.mem.eql(u8, old_lines[i - 1], new_lines[j - 1])) {
            // Context line (same in both)
            try diff_lines.append(allocator, .{
                .kind = .context,
                .content = old_lines[i - 1],
                .old_line_num = old_start + i - 1,
                .new_line_num = new_start + j - 1,
            });
            i -= 1;
            j -= 1;
        } else if (j > 0 and (i == 0 or lcs_table[i][j - 1] >= lcs_table[i - 1][j])) {
            // Addition
            try diff_lines.append(allocator, .{
                .kind = .add,
                .content = new_lines[j - 1],
                .old_line_num = null,
                .new_line_num = new_start + j - 1,
            });
            additions += 1;
            j -= 1;
        } else if (i > 0) {
            // Deletion
            try diff_lines.append(allocator, .{
                .kind = .delete,
                .content = old_lines[i - 1],
                .old_line_num = old_start + i - 1,
                .new_line_num = null,
            });
            deletions += 1;
            i -= 1;
        }
    }

    // Reverse since we built it backwards
    std.mem.reverse(DiffLine, diff_lines.items);

    return DiffResult{
        .lines = try diff_lines.toOwnedSlice(allocator),
        .additions = additions,
        .deletions = deletions,
        .allocator = allocator,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "computeDiff empty to content" {
    const allocator = std.testing.allocator;
    var result = try computeDiff(allocator, "", "line1\nline2", null, null);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.lines.len);
    try std.testing.expectEqual(DiffLine.Kind.add, result.lines[0].kind);
    try std.testing.expectEqual(DiffLine.Kind.add, result.lines[1].kind);
    try std.testing.expectEqual(@as(usize, 2), result.additions);
    try std.testing.expectEqual(@as(usize, 0), result.deletions);
}

test "computeDiff content to empty" {
    const allocator = std.testing.allocator;
    var result = try computeDiff(allocator, "line1\nline2", "", null, null);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.lines.len);
    try std.testing.expectEqual(DiffLine.Kind.delete, result.lines[0].kind);
    try std.testing.expectEqual(DiffLine.Kind.delete, result.lines[1].kind);
    try std.testing.expectEqual(@as(usize, 0), result.additions);
    try std.testing.expectEqual(@as(usize, 2), result.deletions);
}

test "computeDiff modification" {
    const allocator = std.testing.allocator;
    var result = try computeDiff(allocator, "line1\nline2\nline3", "line1\nmodified\nline3", null, null);
    defer result.deinit();

    // Should be: context(line1), delete(line2), add(modified), context(line3)
    try std.testing.expectEqual(@as(usize, 4), result.lines.len);
    try std.testing.expectEqual(DiffLine.Kind.context, result.lines[0].kind);
    try std.testing.expectEqualStrings("line1", result.lines[0].content);
    try std.testing.expectEqual(@as(usize, 1), result.additions);
    try std.testing.expectEqual(@as(usize, 1), result.deletions);
}

test "computeDiff identical content" {
    const allocator = std.testing.allocator;
    var result = try computeDiff(allocator, "same\ncontent", "same\ncontent", null, null);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.lines.len);
    try std.testing.expectEqual(DiffLine.Kind.context, result.lines[0].kind);
    try std.testing.expectEqual(DiffLine.Kind.context, result.lines[1].kind);
    try std.testing.expectEqual(@as(usize, 0), result.additions);
    try std.testing.expectEqual(@as(usize, 0), result.deletions);
}

test "computeDiff with custom starting line numbers" {
    const allocator = std.testing.allocator;
    // Simulate a hunk starting at line 448 in the old file and line 448 in the new file
    var result = try computeDiff(allocator, "line1\nline2\nline3", "line1\nmodified\nline3", 448, 448);
    defer result.deinit();

    // Should be: context(line1), delete(line2), add(modified), context(line3)
    try std.testing.expectEqual(@as(usize, 4), result.lines.len);

    // Context line 1 should be at line 448
    try std.testing.expectEqual(DiffLine.Kind.context, result.lines[0].kind);
    try std.testing.expectEqual(@as(?usize, 448), result.lines[0].old_line_num);
    try std.testing.expectEqual(@as(?usize, 448), result.lines[0].new_line_num);

    // Delete line 2 should be at old line 449
    try std.testing.expectEqual(DiffLine.Kind.delete, result.lines[1].kind);
    try std.testing.expectEqual(@as(?usize, 449), result.lines[1].old_line_num);
    try std.testing.expectEqual(@as(?usize, null), result.lines[1].new_line_num);

    // Add "modified" should be at new line 449
    try std.testing.expectEqual(DiffLine.Kind.add, result.lines[2].kind);
    try std.testing.expectEqual(@as(?usize, null), result.lines[2].old_line_num);
    try std.testing.expectEqual(@as(?usize, 449), result.lines[2].new_line_num);

    // Context line 3 should be at old line 450, new line 450
    try std.testing.expectEqual(DiffLine.Kind.context, result.lines[3].kind);
    try std.testing.expectEqual(@as(?usize, 450), result.lines[3].old_line_num);
    try std.testing.expectEqual(@as(?usize, 450), result.lines[3].new_line_num);
}
