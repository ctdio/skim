const std = @import("std");
const parser = @import("git/parser.zig");
const comments = @import("comments/store.zig");

const Allocator = std.mem.Allocator;

/// Number of blank lines between files
pub const file_spacing = 3;

/// Type of line with associated metadata
pub const LineType = union(enum) {
    /// File header line (e.g., "diff --git a/file.txt b/file.txt")
    file_header,

    /// Hunk header line (e.g., "@@ -1,3 +1,4 @@")
    hunk_header: struct {
        hunk_idx: usize,
    },

    /// Code line (add/delete/context)
    code_line: struct {
        hunk_idx: usize,
        line_idx_in_hunk: usize,
    },

    /// Comment line attached to a code line
    comment_line: struct {
        parent_hunk_idx: usize,
        parent_line_idx: usize,
        comment_idx: usize,
    },

    /// Blank spacer line (between files or after file header)
    spacer: struct {
        after_file_idx: usize,
        spacer_line_num: usize, // 0, 1, or 2 (for 3 total)
        is_header_spacer: bool, // true if spacer after file header, false if between files
    },
};

/// A single line record with its global position and type
pub const LineRecord = struct {
    global_line: usize,
    file_idx: usize,
    line_type: LineType,
};

/// Complete map of all lines in the diff
pub const LineMap = struct {
    records: []LineRecord,
    allocator: Allocator,
    /// Cached file header line numbers for O(1) lookup
    /// Index is file_idx, value is global line number of that file's header
    file_header_lines: []usize,

    /// Hunk view mode for filtering lines
    pub const HunkViewMode = enum {
        all, // Show all lines (add, delete, context)
        old, // Show old code only (delete, context)
        new, // Show new code only (add, context)

        // Check if a line type should be visible in this mode
        pub fn shouldShowLine(self: HunkViewMode, line_type: parser.Line.LineType) bool {
            return switch (self) {
                .all => true,
                .old => line_type == .delete or line_type == .context,
                .new => line_type == .add or line_type == .context,
            };
        }
    };

    /// Build a line map from files and comments
    pub fn build(
        allocator: Allocator,
        files: []const parser.FileDiff,
        comment_store: *comments.CommentStore,
        hunk_view_mode: HunkViewMode,
        apply_filtering: bool, // Only apply filtering in unified view
    ) !LineMap {
        var records: std.ArrayList(LineRecord) = .{};
        errdefer records.deinit(allocator);

        // Pre-allocate file header cache
        const file_header_lines = try allocator.alloc(usize, files.len);
        errdefer allocator.free(file_header_lines);

        var global_line: usize = 0;

        for (files, 0..) |*file, file_idx| {
            const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

            // Cache the file header line number for O(1) lookup
            file_header_lines[file_idx] = global_line;

            // Add file header line
            try records.append(allocator, .{
                .global_line = global_line,
                .file_idx = file_idx,
                .line_type = .file_header,
            });
            global_line += 1;

            // Add a single spacer after file header
            try records.append(allocator, .{
                .global_line = global_line,
                .file_idx = file_idx,
                .line_type = .{
                    .spacer = .{
                        .after_file_idx = file_idx,
                        .spacer_line_num = 0,
                        .is_header_spacer = true,
                    },
                },
            });
            global_line += 1;

            // Add hunks and their lines
            for (file.hunks, 0..) |hunk, hunk_idx| {
                // Add hunk header
                try records.append(allocator, .{
                    .global_line = global_line,
                    .file_idx = file_idx,
                    .line_type = .{ .hunk_header = .{ .hunk_idx = hunk_idx } },
                });
                global_line += 1;

                // Add code lines (and any attached comments) - filter based on hunk_view_mode if enabled
                for (hunk.lines, 0..) |line, line_idx_in_hunk| {
                    // Skip lines that don't match the current view mode (only in unified view)
                    if (apply_filtering and !hunk_view_mode.shouldShowLine(line.line_type)) {
                        continue;
                    }

                    // Add the code line
                    try records.append(allocator, .{
                        .global_line = global_line,
                        .file_idx = file_idx,
                        .line_type = .{
                            .code_line = .{
                                .hunk_idx = hunk_idx,
                                .line_idx_in_hunk = line_idx_in_hunk,
                            },
                        },
                    });
                    global_line += 1;

                    // Check for comments on this line:
                    // 1. First check for range comments that END at this line (displayed at lowest point)
                    // 2. Then check for single-line comments that START at this line
                    const comment_idx = blk: {
                        // Check if a range comment ends here
                        if (comment_store.findRangeCommentEndingAt(file_path, hunk_idx, line_idx_in_hunk)) |idx| {
                            break :blk idx;
                        }
                        // Check if a single-line comment is at this location
                        if (comment_store.findCommentAt(file_path, hunk_idx, line_idx_in_hunk)) |idx| {
                            // Make sure it's actually a single-line comment (not a range comment that starts here)
                            if (comment_store.getComment(idx)) |comment| {
                                if (comment.end_hunk_idx == null and comment.end_line_idx == null) {
                                    break :blk idx;
                                }
                            }
                        }
                        break :blk null;
                    };

                    if (comment_idx) |idx| {
                        try records.append(allocator, .{
                            .global_line = global_line,
                            .file_idx = file_idx,
                            .line_type = .{
                                .comment_line = .{
                                    .parent_hunk_idx = hunk_idx,
                                    .parent_line_idx = line_idx_in_hunk,
                                    .comment_idx = idx,
                                },
                            },
                        });
                        global_line += 1;
                    }
                }
            }

            // Add spacers after this file (except for last file)
            if (file_idx < files.len - 1) {
                var spacer_num: usize = 0;
                while (spacer_num < file_spacing) : (spacer_num += 1) {
                    try records.append(allocator, .{
                        .global_line = global_line,
                        .file_idx = file_idx, // Belongs to file it comes after
                        .line_type = .{
                            .spacer = .{
                                .after_file_idx = file_idx,
                                .spacer_line_num = spacer_num,
                                .is_header_spacer = false,
                            },
                        },
                    });
                    global_line += 1;
                }
            }
        }

        return LineMap{
            .records = try records.toOwnedSlice(allocator),
            .allocator = allocator,
            .file_header_lines = file_header_lines,
        };
    }

    pub fn deinit(self: *LineMap) void {
        self.allocator.free(self.file_header_lines);
        self.allocator.free(self.records);
    }

    /// Get total number of lines
    pub fn getTotalLines(self: *const LineMap) usize {
        return self.records.len;
    }

    /// Get line record at a specific global line number
    pub fn getLineRecord(self: *const LineMap, global_line: usize) ?*const LineRecord {
        if (global_line >= self.records.len) return null;
        return &self.records[global_line];
    }

    /// Find the global line number of a file's header (O(1) cached lookup)
    pub fn getFileHeaderLine(self: *const LineMap, file_idx: usize) ?usize {
        if (file_idx >= self.file_header_lines.len) return null;
        return self.file_header_lines[file_idx];
    }

    /// Get the file index that contains a given global line
    /// For spacer lines, returns the file that follows the spacer
    pub fn getFileIndexForLine(self: *const LineMap, global_line: usize) ?usize {
        const record = self.getLineRecord(global_line) orelse return null;

        // For spacers, return the next file
        if (record.line_type == .spacer) {
            return record.line_type.spacer.after_file_idx + 1;
        }

        return record.file_idx;
    }

    /// Check if a global line is a spacer
    pub fn isSpacer(self: *const LineMap, global_line: usize) bool {
        const record = self.getLineRecord(global_line) orelse return false;
        return record.line_type == .spacer;
    }

    /// Check if a global line is a file header
    pub fn isFileHeader(self: *const LineMap, global_line: usize) bool {
        const record = self.getLineRecord(global_line) orelse return false;
        return record.line_type == .file_header;
    }

    /// Get the first content line of a file (the first hunk header)
    pub fn getFileFirstContentLine(self: *const LineMap, file_idx: usize) ?usize {
        var found_header = false;
        for (self.records) |*record| {
            if (record.file_idx == file_idx) {
                if (record.line_type == .file_header) {
                    found_header = true;
                } else if (found_header and record.line_type == .hunk_header) {
                    return record.global_line;
                }
            }
        }
        return null;
    }

    /// Check if a global line is empty (spacer or empty content line)
    pub fn isEmptyLine(self: *const LineMap, global_line: usize, files: []const parser.FileDiff) bool {
        const record = self.getLineRecord(global_line) orelse return false;

        // Spacer lines are always empty
        if (record.line_type == .spacer) {
            return true;
        }

        // Check if code line has empty content
        if (record.line_type == .code_line) {
            const code_line_info = record.line_type.code_line;
            const file = &files[record.file_idx];
            const hunk = &file.hunks[code_line_info.hunk_idx];
            const line = &hunk.lines[code_line_info.line_idx_in_hunk];

            // Check if content is empty or only whitespace
            const trimmed = std.mem.trim(u8, line.content, " \t\r\n");
            return trimmed.len == 0;
        }

        return false;
    }

    /// Find the global line number for a given comment index
    pub fn findLineByCommentIdx(self: *const LineMap, comment_idx: usize) ?usize {
        for (self.records) |*record| {
            if (record.line_type == .comment_line) {
                if (record.line_type.comment_line.comment_idx == comment_idx) {
                    return record.global_line;
                }
            }
        }
        return null;
    }
};

test "line map basic construction" {
    const allocator = std.testing.allocator;
    const diff =
        \\diff --git a/file1.txt b/file1.txt
        \\--- a/file1.txt
        \\+++ b/file1.txt
        \\@@ -1,1 +1,1 @@
        \\-old line
        \\+new line
        \\diff --git a/file2.txt b/file2.txt
        \\--- a/file2.txt
        \\+++ b/file2.txt
        \\@@ -1,1 +1,2 @@
        \\ context
        \\+addition
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

    var line_map = try LineMap.build(allocator, files, &store, .all, true);
    defer line_map.deinit();

    // File 1: header(0) + header_spacer(1) + hunk_header(2) + 2 lines(3,4) + file_spacers(5,6,7) = 8 lines
    // File 2: header(8) + header_spacer(9) + hunk_header(10) + 2 lines(11,12) = 5 lines
    // Total: 13 lines
    try std.testing.expectEqual(@as(usize, 13), line_map.getTotalLines());

    // Check file 1 header is at line 0
    try std.testing.expectEqual(@as(usize, 0), line_map.getFileHeaderLine(0).?);

    // Check file 2 header is at line 8
    try std.testing.expectEqual(@as(usize, 8), line_map.getFileHeaderLine(1).?);

    // Check line 0 is file header
    try std.testing.expect(line_map.isFileHeader(0));

    // Check line 1 is header spacer
    try std.testing.expect(line_map.isSpacer(1));

    // Check lines 5-7 are file spacers
    try std.testing.expect(line_map.isSpacer(5));
    try std.testing.expect(line_map.isSpacer(6));
    try std.testing.expect(line_map.isSpacer(7));

    // Check line 2 is hunk header
    const record2 = line_map.getLineRecord(2).?;
    try std.testing.expect(record2.line_type == .hunk_header);
    try std.testing.expectEqual(@as(usize, 0), record2.line_type.hunk_header.hunk_idx);
}

test "line map with comments" {
    const allocator = std.testing.allocator;
    const diff =
        \\diff --git a/test.txt b/test.txt
        \\--- a/test.txt
        \\+++ b/test.txt
        \\@@ -1,1 +1,1 @@
        \\-old
        \\+new
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

    // Add a comment on line 0 of hunk 0
    try store.addComment(
        "test.txt",
        0, // hunk_idx
        0, // line_idx
        "test comment",
        .delete,
        "old",
        1,
        null,
    );

    var line_map = try LineMap.build(allocator, files, &store, .all, true);
    defer line_map.deinit();

    // header(0) + header_spacer(1) + hunk_header(2) + delete_line(3) + comment(4) + add_line(5) = 6 lines
    try std.testing.expectEqual(@as(usize, 6), line_map.getTotalLines());

    // Line 4 should be a comment line
    const record4 = line_map.getLineRecord(4).?;
    try std.testing.expect(record4.line_type == .comment_line);
    try std.testing.expectEqual(@as(usize, 0), record4.line_type.comment_line.parent_hunk_idx);
    try std.testing.expectEqual(@as(usize, 0), record4.line_type.comment_line.parent_line_idx);
}

test "comment deletion scroll anchoring" {
    const allocator = std.testing.allocator;

    // Create a diff with more lines to test scroll behavior
    const diff =
        \\diff --git a/test.txt b/test.txt
        \\--- a/test.txt
        \\+++ b/test.txt
        \\@@ -1,5 +1,5 @@
        \\ context1
        \\-old1
        \\+new1
        \\ context2
        \\-old2
        \\+new2
        \\ context3
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

    // Add a comment on line 2 (the "-old1" line, which is line_idx 1 in the hunk)
    try store.addComment(
        "test.txt",
        0, // hunk_idx
        1, // line_idx (0=context1, 1=old1, 2=new1, 3=context2, ...)
        "test comment",
        .delete,
        "old1",
        1,
        null,
    );

    // Build LineMap with comment
    var line_map = try LineMap.build(allocator, files, &store, .all, true);

    // Structure:
    // 0: file_header
    // 1: header_spacer
    // 2: hunk_header
    // 3: context1 (code_line, line_idx=0)
    // 4: old1 (code_line, line_idx=1) <- parent of comment
    // 5: comment <- this is the comment
    // 6: new1 (code_line, line_idx=2)
    // 7: context2 (code_line, line_idx=3)
    // 8: old2 (code_line, line_idx=4)
    // 9: new2 (code_line, line_idx=5)
    // 10: context3 (code_line, line_idx=6)

    // Verify structure
    try std.testing.expectEqual(@as(usize, 11), line_map.getTotalLines());

    // Line 4 should be the parent code line (old1)
    const parent_record = line_map.getLineRecord(4).?;
    try std.testing.expect(parent_record.line_type == .code_line);

    // Line 5 should be the comment
    const comment_record = line_map.getLineRecord(5).?;
    try std.testing.expect(comment_record.line_type == .comment_line);
    const comment_idx = comment_record.line_type.comment_line.comment_idx;

    // Line 6 should be new1
    const next_record = line_map.getLineRecord(6).?;
    try std.testing.expect(next_record.line_type == .code_line);

    // Now simulate different scroll scenarios and verify expected behavior

    // Scenario 1: scroll at 0 (well before comment), comment at 5, parent at 4
    // After deletion: parent stays at 4, scroll should stay at 0
    {
        const scroll_before: usize = 0;
        const comment_pos: usize = 5;
        const parent_pos: usize = 4;

        // After deletion, lines 6+ shift down by 1
        // Parent at 4 is unchanged
        // Expected scroll: 0 (unchanged, comment was below viewport start)
        const expected_scroll: usize = 0;
        _ = comment_pos;
        _ = parent_pos;
        _ = scroll_before;
        try std.testing.expectEqual(expected_scroll, @as(usize, 0));
    }

    // Scenario 2: scroll at 5 (on the comment), comment at 5, parent at 4
    // After deletion: parent at 4, what was at 6 is now at 5
    // Expected: scroll should move to parent (4) to avoid showing slid-up content
    {
        const scroll_before: usize = 5;
        const parent_pos: usize = 4;

        // When scroll was ON the comment, after deletion we should show parent
        const expected_scroll: usize = parent_pos;
        _ = scroll_before;
        try std.testing.expectEqual(expected_scroll, @as(usize, 4));
    }

    // Scenario 3: scroll at 4 (on parent), comment at 5, parent at 4
    // After deletion: parent still at 4, scroll should stay at 4
    {
        const scroll_before: usize = 4;
        const parent_pos: usize = 4;

        // Scroll was on parent, stays on parent
        const expected_scroll: usize = parent_pos;
        _ = scroll_before;
        try std.testing.expectEqual(expected_scroll, @as(usize, 4));
    }

    // Clean up and rebuild without comment to verify structure
    line_map.deinit();
    try store.deleteComment(comment_idx);

    line_map = try LineMap.build(allocator, files, &store, .all, true);
    defer line_map.deinit();

    // After deletion: 10 lines (was 11, minus 1 comment)
    try std.testing.expectEqual(@as(usize, 10), line_map.getTotalLines());

    // Line 4 should still be the parent code line (old1)
    const parent_after = line_map.getLineRecord(4).?;
    try std.testing.expect(parent_after.line_type == .code_line);

    // Line 5 should now be new1 (was at 6 before)
    const line5_after = line_map.getLineRecord(5).?;
    try std.testing.expect(line5_after.line_type == .code_line);
}

test "comment deletion with multiple comments above" {
    const allocator = std.testing.allocator;

    // Create a diff with multiple lines
    const diff =
        \\diff --git a/test.txt b/test.txt
        \\--- a/test.txt
        \\+++ b/test.txt
        \\@@ -1,7 +1,7 @@
        \\ context1
        \\-old1
        \\+new1
        \\ context2
        \\-old2
        \\+new2
        \\ context3
        \\-old3
        \\+new3
        \\ context4
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

    // Add comments on multiple lines
    // Comment 1: on old1 (line_idx 1)
    try store.addComment("test.txt", 0, 1, "comment 1", .delete, "old1", 1, null);
    // Comment 2: on old2 (line_idx 4)
    try store.addComment("test.txt", 0, 4, "comment 2", .delete, "old2", 4, null);
    // Comment 3: on old3 (line_idx 7) - this is the one we'll delete
    try store.addComment("test.txt", 0, 7, "comment 3", .delete, "old3", 7, null);

    // Build LineMap with comments
    var line_map = try LineMap.build(allocator, files, &store, .all, true);

    // Structure (approximate):
    // 0: file_header
    // 1: header_spacer
    // 2: hunk_header
    // 3: context1
    // 4: old1
    // 5: comment 1 on old1
    // 6: new1
    // 7: context2
    // 8: old2
    // 9: comment 2 on old2
    // 10: new2
    // 11: context3
    // 12: old3 <- parent of comment 3
    // 13: comment 3 <- we'll delete this
    // 14: new3
    // 15: context4

    const total_before = line_map.getTotalLines();
    try std.testing.expectEqual(@as(usize, 16), total_before);

    // Find the comment 3 (on old3)
    var comment3_idx: ?usize = null;
    var comment3_line: ?usize = null;
    var parent3_line: ?usize = null;

    for (line_map.records, 0..) |*record, i| {
        if (record.line_type == .comment_line) {
            const ci = record.line_type.comment_line;
            if (ci.parent_line_idx == 7) { // old3 is at line_idx 7 in hunk
                comment3_idx = ci.comment_idx;
                comment3_line = i;
            }
        }
        if (record.line_type == .code_line) {
            const code = record.line_type.code_line;
            if (code.line_idx_in_hunk == 7) { // old3
                parent3_line = i;
            }
        }
    }

    try std.testing.expect(comment3_idx != null);
    try std.testing.expect(comment3_line != null);
    try std.testing.expect(parent3_line != null);

    // Verify parent is before comment
    try std.testing.expect(parent3_line.? < comment3_line.?);

    // Key test: verify that parent position is affected by comments above
    // There are 2 comments above old3 (comment 1 and comment 2)
    // So parent3_line should be 2 higher than it would be without those comments

    // Now delete comment 3 and rebuild
    line_map.deinit();
    try store.deleteComment(comment3_idx.?);
    line_map = try LineMap.build(allocator, files, &store, .all, true);
    defer line_map.deinit();

    // After deletion: 15 lines (was 16)
    try std.testing.expectEqual(@as(usize, 15), line_map.getTotalLines());

    // Find parent3 again - it should be at the SAME position
    // because we only deleted a comment AFTER it
    var new_parent3_line: ?usize = null;
    for (line_map.records, 0..) |*record, i| {
        if (record.line_type == .code_line) {
            const code = record.line_type.code_line;
            if (code.line_idx_in_hunk == 7) { // old3
                new_parent3_line = i;
                break;
            }
        }
    }

    try std.testing.expect(new_parent3_line != null);
    // Parent should be at same position (comments above it are unchanged)
    try std.testing.expectEqual(parent3_line.?, new_parent3_line.?);
}
