const std = @import("std");
const parser = @import("git/parser.zig");
const comments = @import("comments.zig");

/// Represents the type of line being displayed
pub const DisplayLineType = union(enum) {
    hunk_header: struct {
        hunk_idx: usize,
    },
    code_line: struct {
        hunk_idx: usize,
        line_idx_in_hunk: usize,
    },
    comment_line: struct {
        comment_idx: usize,
        parent_hunk_idx: usize,
        parent_line_idx: usize,
    },
};

/// Given a cursor line index, determine what type of line it is
pub fn getDisplayLineType(
    line_idx: usize,
    file: *const parser.FileDiff,
    comment_store: *const comments.CommentStore,
    file_path: []const u8,
) ?DisplayLineType {
    var current_line: usize = 0;

    for (file.hunks, 0..) |hunk, hunk_idx| {
        // Hunk header
        if (current_line == line_idx) {
            return DisplayLineType{ .hunk_header = .{ .hunk_idx = hunk_idx } };
        }
        current_line += 1;

        // Hunk lines
        for (hunk.lines, 0..) |_, line_idx_in_hunk| {
            // Code line
            if (current_line == line_idx) {
                return DisplayLineType{ .code_line = .{
                    .hunk_idx = hunk_idx,
                    .line_idx_in_hunk = line_idx_in_hunk,
                } };
            }
            current_line += 1;

            // Check if there's a comment after this code line
            if (comment_store.findCommentAt(file_path, hunk_idx, line_idx_in_hunk)) |comment_idx| {
                if (current_line == line_idx) {
                    return DisplayLineType{ .comment_line = .{
                        .comment_idx = comment_idx,
                        .parent_hunk_idx = hunk_idx,
                        .parent_line_idx = line_idx_in_hunk,
                    } };
                }
                current_line += 1;
            }
        }
    }

    return null;
}

/// Count total display lines including comments
pub fn getTotalDisplayLines(
    file: *const parser.FileDiff,
    comment_store: *const comments.CommentStore,
    file_path: []const u8,
) usize {
    var total: usize = 0;

    for (file.hunks, 0..) |hunk, hunk_idx| {
        total += 1; // hunk header

        for (hunk.lines, 0..) |_, line_idx_in_hunk| {
            total += 1; // code line

            // Check if there's a comment
            if (comment_store.hasCommentAt(file_path, hunk_idx, line_idx_in_hunk)) {
                total += 1; // comment line
            }
        }
    }

    return total;
}

test "getDisplayLineType maps to diff line numbers" {
    const allocator = std.testing.allocator;
    const diff =
        \\diff --git a/sample.txt b/sample.txt
        \\--- a/sample.txt
        \\+++ b/sample.txt
        \\@@ -10,2 +100,3 @@
        \\ context line
        \\-removed line
        \\+added line
        \\+another addition
    ;

    const files = try parser.parse(allocator, diff);
    defer {
        for (files) |*file| {
            file.deinit(allocator);
        }
        allocator.free(files);
    }

    var store = comments.CommentStore.init(allocator);
    defer store.deinit();

    const file = &files[0];
    const path = if (file.new_path.len > 0) file.new_path else file.old_path;

    // Hunk header at display line 0
    const header_type = getDisplayLineType(0, file, &store, path).?;
    try std.testing.expect(header_type == .hunk_header);

    // First code line (context) should map to new line 100
    const context_type = getDisplayLineType(1, file, &store, path).?;
    try std.testing.expect(context_type == .code_line);
    const context_line = file.hunks[context_type.code_line.hunk_idx].lines[context_type.code_line.line_idx_in_hunk];
    try std.testing.expectEqual(@as(?u32, 100), context_line.new_lineno);

    // Second code line (deletion) should use old line numbers
    const delete_type = getDisplayLineType(2, file, &store, path).?;
    try std.testing.expect(delete_type == .code_line);
    const delete_line = file.hunks[delete_type.code_line.hunk_idx].lines[delete_type.code_line.line_idx_in_hunk];
    try std.testing.expectEqual(@as(?u32, 11), delete_line.old_lineno);

    // Third code line (addition) should map to new line 101
    const add_type = getDisplayLineType(3, file, &store, path).?;
    try std.testing.expect(add_type == .code_line);
    const add_line = file.hunks[add_type.code_line.hunk_idx].lines[add_type.code_line.line_idx_in_hunk];
    try std.testing.expectEqual(@as(?u32, 101), add_line.new_lineno);
}
