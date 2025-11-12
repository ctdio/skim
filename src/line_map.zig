const std = @import("std");
const parser = @import("git/parser.zig");
const comments = @import("comments.zig");

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

    /// Blank spacer line between files
    spacer: struct {
        after_file_idx: usize,
        spacer_line_num: usize, // 0, 1, or 2 (for 3 total)
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

    /// Build a line map from files and comments
    pub fn build(
        allocator: Allocator,
        files: []const parser.FileDiff,
        comment_store: *comments.CommentStore,
    ) !LineMap {
        var records = std.ArrayList(LineRecord).init(allocator);
        errdefer records.deinit();

        var global_line: usize = 0;

        for (files, 0..) |*file, file_idx| {
            const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

            // Add file header line
            try records.append(.{
                .global_line = global_line,
                .file_idx = file_idx,
                .line_type = .file_header,
            });
            global_line += 1;

            // Add hunks and their lines
            for (file.hunks, 0..) |hunk, hunk_idx| {
                // Add hunk header
                try records.append(.{
                    .global_line = global_line,
                    .file_idx = file_idx,
                    .line_type = .{ .hunk_header = .{ .hunk_idx = hunk_idx } },
                });
                global_line += 1;

                // Add code lines (and any attached comments)
                for (hunk.lines, 0..) |_, line_idx_in_hunk| {
                    // Add the code line
                    try records.append(.{
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

                    // Check for comment on this line
                    if (comment_store.findCommentAt(file_path, hunk_idx, line_idx_in_hunk)) |comment_idx| {
                        try records.append(.{
                            .global_line = global_line,
                            .file_idx = file_idx,
                            .line_type = .{
                                .comment_line = .{
                                    .parent_hunk_idx = hunk_idx,
                                    .parent_line_idx = line_idx_in_hunk,
                                    .comment_idx = comment_idx,
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
                    try records.append(.{
                        .global_line = global_line,
                        .file_idx = file_idx, // Belongs to file it comes after
                        .line_type = .{
                            .spacer = .{
                                .after_file_idx = file_idx,
                                .spacer_line_num = spacer_num,
                            },
                        },
                    });
                    global_line += 1;
                }
            }
        }

        return LineMap{
            .records = try records.toOwnedSlice(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LineMap) void {
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

    /// Find the global line number of a file's header
    pub fn getFileHeaderLine(self: *const LineMap, file_idx: usize) ?usize {
        for (self.records) |*record| {
            if (record.file_idx == file_idx and record.line_type == .file_header) {
                return record.global_line;
            }
        }
        return null;
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

    var line_map = try LineMap.build(allocator, files, &store);
    defer line_map.deinit();

    // File 1: header(0) + hunk_header(1) + 2 lines(2,3) + spacers(4,5,6) = 7 lines
    // File 2: header(7) + hunk_header(8) + 2 lines(9,10) = 4 lines
    // Total: 11 lines
    try std.testing.expectEqual(@as(usize, 11), line_map.getTotalLines());

    // Check file 1 header is at line 0
    try std.testing.expectEqual(@as(usize, 0), line_map.getFileHeaderLine(0).?);

    // Check file 2 header is at line 7
    try std.testing.expectEqual(@as(usize, 7), line_map.getFileHeaderLine(1).?);

    // Check line 0 is file header
    try std.testing.expect(line_map.isFileHeader(0));

    // Check lines 4-6 are spacers
    try std.testing.expect(line_map.isSpacer(4));
    try std.testing.expect(line_map.isSpacer(5));
    try std.testing.expect(line_map.isSpacer(6));

    // Check line 1 is hunk header
    const record1 = line_map.getLineRecord(1).?;
    try std.testing.expect(record1.line_type == .hunk_header);
    try std.testing.expectEqual(@as(usize, 0), record1.line_type.hunk_header.hunk_idx);
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

    var line_map = try LineMap.build(allocator, files, &store);
    defer line_map.deinit();

    // header(0) + hunk_header(1) + delete_line(2) + comment(3) + add_line(4) = 5 lines
    try std.testing.expectEqual(@as(usize, 5), line_map.getTotalLines());

    // Line 3 should be a comment line
    const record3 = line_map.getLineRecord(3).?;
    try std.testing.expect(record3.line_type == .comment_line);
    try std.testing.expectEqual(@as(usize, 0), record3.line_type.comment_line.parent_hunk_idx);
    try std.testing.expectEqual(@as(usize, 0), record3.line_type.comment_line.parent_line_idx);
}
