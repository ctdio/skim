const std = @import("std");
const parser = @import("git/parser.zig");

const Allocator = std.mem.Allocator;

/// A comment attached to a specific line or range of lines in a diff
pub const Comment = struct {
    file_path: []const u8, // Which file this comment belongs to
    hunk_idx: usize, // Which hunk (0-indexed) - start of range
    line_idx: usize, // Line within hunk (0-indexed, relative to all hunk lines) - start of range
    text: []const u8, // The comment text (can be multi-line)

    // Range support (null means single-line comment)
    end_hunk_idx: ?usize, // End hunk for range comments
    end_line_idx: ?usize, // End line within hunk for range comments

    // Captured context for export (start line)
    line_type: parser.Line.LineType,
    line_content: []const u8,
    old_lineno: ?u32,
    new_lineno: ?u32,

    pub fn deinit(self: *const Comment, allocator: Allocator) void {
        allocator.free(self.file_path);
        allocator.free(self.text);
        allocator.free(self.line_content);
    }
};

/// Storage for all comments in the current review session
pub const CommentStore = struct {
    comments: std.ArrayList(Comment),
    allocator: Allocator,

    pub fn init(allocator: Allocator) CommentStore {
        return .{
            .comments = std.ArrayList(Comment).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CommentStore) void {
        for (self.comments.items) |*comment| {
            comment.deinit(self.allocator);
        }
        self.comments.deinit();
    }

    /// Add a new comment (single line or range)
    pub fn addComment(
        self: *CommentStore,
        file_path: []const u8,
        hunk_idx: usize,
        line_idx: usize,
        text: []const u8,
        line_type: parser.Line.LineType,
        line_content: []const u8,
        old_lineno: ?u32,
        new_lineno: ?u32,
    ) !void {
        const comment = Comment{
            .file_path = try self.allocator.dupe(u8, file_path),
            .hunk_idx = hunk_idx,
            .line_idx = line_idx,
            .text = try self.allocator.dupe(u8, text),
            .end_hunk_idx = null,
            .end_line_idx = null,
            .line_type = line_type,
            .line_content = try self.allocator.dupe(u8, line_content),
            .old_lineno = old_lineno,
            .new_lineno = new_lineno,
        };
        try self.comments.append(comment);
    }

    /// Add a new range comment (for visual selections)
    pub fn addRangeComment(
        self: *CommentStore,
        file_path: []const u8,
        hunk_idx: usize,
        line_idx: usize,
        end_hunk_idx: usize,
        end_line_idx: usize,
        text: []const u8,
        line_type: parser.Line.LineType,
        line_content: []const u8,
        old_lineno: ?u32,
        new_lineno: ?u32,
    ) !void {
        const comment = Comment{
            .file_path = try self.allocator.dupe(u8, file_path),
            .hunk_idx = hunk_idx,
            .line_idx = line_idx,
            .text = try self.allocator.dupe(u8, text),
            .end_hunk_idx = end_hunk_idx,
            .end_line_idx = end_line_idx,
            .line_type = line_type,
            .line_content = try self.allocator.dupe(u8, line_content),
            .old_lineno = old_lineno,
            .new_lineno = new_lineno,
        };
        try self.comments.append(comment);
    }

    /// Update an existing comment's text
    pub fn updateComment(self: *CommentStore, comment_idx: usize, new_text: []const u8) !void {
        if (comment_idx >= self.comments.items.len) return error.InvalidCommentIndex;

        var comment = &self.comments.items[comment_idx];
        self.allocator.free(comment.text);
        comment.text = try self.allocator.dupe(u8, new_text);
    }

    /// Delete a comment
    pub fn deleteComment(self: *CommentStore, comment_idx: usize) !void {
        if (comment_idx >= self.comments.items.len) return error.InvalidCommentIndex;

        var comment = self.comments.orderedRemove(comment_idx);
        comment.deinit(self.allocator);
    }

    /// Clear all comments
    pub fn clearAll(self: *CommentStore) void {
        for (self.comments.items) |*comment| {
            comment.deinit(self.allocator);
        }
        self.comments.clearRetainingCapacity();
    }

    /// Find comment at specific location (returns index or null)
    pub fn findCommentAt(self: *const CommentStore, file_path: []const u8, hunk_idx: usize, line_idx: usize) ?usize {
        for (self.comments.items, 0..) |*comment, idx| {
            if (std.mem.eql(u8, comment.file_path, file_path) and
                comment.hunk_idx == hunk_idx and
                comment.line_idx == line_idx)
            {
                return idx;
            }
        }
        return null;
    }

    /// Check if there's a comment at this location
    pub fn hasCommentAt(self: *const CommentStore, file_path: []const u8, hunk_idx: usize, line_idx: usize) bool {
        return self.findCommentAt(file_path, hunk_idx, line_idx) != null;
    }

    /// Find a range comment that ENDS at this location (returns index or null)
    /// Range comments should be displayed after their END line (lowest point)
    pub fn findRangeCommentEndingAt(self: *const CommentStore, file_path: []const u8, hunk_idx: usize, line_idx: usize) ?usize {
        for (self.comments.items, 0..) |*comment, idx| {
            // Check if this is a range comment
            if (comment.end_hunk_idx == null or comment.end_line_idx == null) continue;

            // Check if it ends at this location
            if (std.mem.eql(u8, comment.file_path, file_path) and
                comment.end_hunk_idx.? == hunk_idx and
                comment.end_line_idx.? == line_idx)
            {
                return idx;
            }
        }
        return null;
    }

    /// Get comment at index
    pub fn getComment(self: *const CommentStore, idx: usize) ?*const Comment {
        if (idx >= self.comments.items.len) return null;
        return &self.comments.items[idx];
    }

    /// Export all comments with context for copy-pasting to coding agents
    /// Needs access to full file diff data to show context lines
    pub fn exportWithContext(
        self: *const CommentStore,
        allocator: Allocator,
        files: []const parser.FileDiff,
        context_lines_before: usize,
        context_lines_after: usize,
    ) ![]const u8 {
        var output = std.ArrayList(u8).init(allocator);
        errdefer output.deinit();

        const writer = output.writer();

        try writer.writeAll("<code_review>\n");

        if (self.comments.items.len == 0) {
            try writer.writeAll("No comments.\n");
            try writer.writeAll("</code_review>\n");
            return output.toOwnedSlice();
        }

        var current_file: ?[]const u8 = null;

        for (self.comments.items) |*comment| {
            // File header (only when file changes)
            if (current_file == null or !std.mem.eql(u8, current_file.?, comment.file_path)) {
                if (current_file != null) {
                    try writer.writeAll("\n");
                }
                try writer.print("File: {s}\n\n", .{comment.file_path});
                current_file = comment.file_path;
            }

            // Find the file and render context
            const file = blk: {
                for (files) |*f| {
                    const path = if (f.new_path.len > 0) f.new_path else f.old_path;
                    if (std.mem.eql(u8, path, comment.file_path)) {
                        break :blk f;
                    }
                }
                break :blk null;
            };

            if (file) |f| {
                try writer.writeAll("```diff\n");
                try renderCommentContext(
                    writer,
                    f,
                    comment,
                    context_lines_before,
                    context_lines_after,
                );
                try writer.writeAll("```\n\n");
            }

            // Comment text
            try writer.writeAll("Comment:\n");
            try writer.print("{s}\n\n", .{comment.text});
            try writer.writeAll("---\n\n");
        }

        try writer.writeAll("</code_review>\n");
        return output.toOwnedSlice();
    }

    fn renderCommentContext(
        writer: anytype,
        file: *const parser.FileDiff,
        comment: *const Comment,
        lines_before: usize,
        lines_after: usize,
    ) !void {
        if (comment.hunk_idx >= file.hunks.len) return;

        const start_hunk = &file.hunks[comment.hunk_idx];
        if (comment.line_idx >= start_hunk.lines.len) return;

        // Determine if this is a range comment or single-line comment
        const is_range = comment.end_hunk_idx != null and comment.end_line_idx != null;

        if (is_range) {
            // Range comment: show all lines in the range plus context
            const end_hunk_idx = comment.end_hunk_idx.?;
            const end_line_idx = comment.end_line_idx.?;

            if (end_hunk_idx >= file.hunks.len) return;

            // For simplicity, only handle ranges within the same hunk
            if (comment.hunk_idx == end_hunk_idx) {
                const target_start = comment.line_idx;
                const target_end = end_line_idx;
                const start_idx = if (target_start >= lines_before) target_start - lines_before else 0;
                const end_idx = @min(target_end + lines_after + 1, start_hunk.lines.len);

                // Render lines with proper formatting
                for (start_hunk.lines[start_idx..end_idx], start_idx..) |line, idx| {
                    const is_in_range = (idx >= target_start and idx <= target_end);

                    try renderDiffLine(writer, line, is_in_range);
                }
            }
        } else {
            // Single-line comment: original behavior
            const target_idx = comment.line_idx;
            const start_idx = if (target_idx >= lines_before) target_idx - lines_before else 0;
            const end_idx = @min(target_idx + lines_after + 1, start_hunk.lines.len);

            // Render lines with proper formatting
            for (start_hunk.lines[start_idx..end_idx], start_idx..) |line, idx| {
                const is_target = (idx == target_idx);

                try renderDiffLine(writer, line, is_target);
            }
        }
    }

    fn renderDiffLine(writer: anytype, line: parser.Line, is_highlighted: bool) !void {
        // Line number (use old for deletions, new for adds/context)
        const lineno = switch (line.line_type) {
            .delete => line.old_lineno,
            .add, .context => line.new_lineno,
        };

        // Diff marker
        const marker = switch (line.line_type) {
            .add => "+",
            .delete => "-",
            .context => " ",
        };

        // Format: "  150  │     .scroll_offset = 0,"
        if (lineno) |num| {
            try writer.print("{s} {d: >3}  │ {s}", .{ marker, num, line.content });
        } else {
            try writer.print("{s}      │ {s}", .{ marker, line.content });
        }

        // Add arrow marker for commented line(s)
        if (is_highlighted) {
            try writer.writeAll("  ← COMMENT");
        }

        try writer.writeAll("\n");
    }

    /// Simple export without context (backwards compatibility)
    pub fn exportToMarkdown(self: *const CommentStore, allocator: Allocator) ![]const u8 {
        var output = std.ArrayList(u8).init(allocator);
        errdefer output.deinit();

        const writer = output.writer();

        try writer.writeAll("<code_review>\n");

        if (self.comments.items.len == 0) {
            try writer.writeAll("No comments.\n");
            try writer.writeAll("</code_review>\n");
            return output.toOwnedSlice();
        }

        var current_file: ?[]const u8 = null;

        for (self.comments.items) |*comment| {
            if (current_file == null or !std.mem.eql(u8, current_file.?, comment.file_path)) {
                if (current_file != null) {
                    try writer.writeAll("\n");
                }
                try writer.print("File: {s}\n\n", .{comment.file_path});
                current_file = comment.file_path;
            }

            const line_type_str = switch (comment.line_type) {
                .add => "added",
                .delete => "deleted",
                .context => "context",
            };

            const lineno_str = if (comment.new_lineno) |n|
                try std.fmt.allocPrint(allocator, "{d}", .{n})
            else if (comment.old_lineno) |o|
                try std.fmt.allocPrint(allocator, "{d}", .{o})
            else
                try allocator.dupe(u8, "?");
            defer allocator.free(lineno_str);

            try writer.print("Line {s} ({s}): {s}\n\n", .{
                lineno_str,
                line_type_str,
                comment.line_content,
            });

            try writer.writeAll("Comment:\n");
            try writer.print("{s}\n\n", .{comment.text});
            try writer.writeAll("---\n\n");
        }

        try writer.writeAll("</code_review>\n");
        return output.toOwnedSlice();
    }
};

test "comment store basic operations" {
    const allocator = std.testing.allocator;

    var store = CommentStore.init(allocator);
    defer store.deinit();

    // Add comment
    try store.addComment(
        "test.zig",
        0,
        5,
        "This needs validation",
        .add,
        "const x = getValue();",
        null,
        42,
    );

    try std.testing.expectEqual(@as(usize, 1), store.comments.items.len);
    try std.testing.expect(store.hasCommentAt("test.zig", 0, 5));
    try std.testing.expect(!store.hasCommentAt("test.zig", 0, 6));

    // Find comment
    const idx = store.findCommentAt("test.zig", 0, 5);
    try std.testing.expect(idx != null);
    try std.testing.expectEqual(@as(usize, 0), idx.?);

    // Update comment
    try store.updateComment(0, "Updated comment text");
    const comment = store.getComment(0).?;
    try std.testing.expectEqualStrings("Updated comment text", comment.text);

    // Delete comment
    try store.deleteComment(0);
    try std.testing.expectEqual(@as(usize, 0), store.comments.items.len);
}

test "export to markdown" {
    const allocator = std.testing.allocator;

    var store = CommentStore.init(allocator);
    defer store.deinit();

    try store.addComment(
        "src/app.zig",
        0,
        10,
        "This should check for null",
        .add,
        "const value = data.getValue();",
        null,
        150,
    );

    const markdown = try store.exportToMarkdown(allocator);
    defer allocator.free(markdown);

    try std.testing.expect(std.mem.containsAtLeast(u8, markdown, 1, "<code_review>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, markdown, 1, "src/app.zig"));
    try std.testing.expect(std.mem.containsAtLeast(u8, markdown, 1, "This should check for null"));
}

test "clear all comments" {
    const allocator = std.testing.allocator;

    var store = CommentStore.init(allocator);
    defer store.deinit();

    // Add multiple comments
    try store.addComment(
        "file1.zig",
        0,
        5,
        "Comment 1",
        .add,
        "line 1",
        null,
        10,
    );

    try store.addComment(
        "file2.zig",
        1,
        10,
        "Comment 2",
        .delete,
        "line 2",
        20,
        null,
    );

    try store.addComment(
        "file3.zig",
        2,
        15,
        "Comment 3",
        .context,
        "line 3",
        30,
        30,
    );

    try std.testing.expectEqual(@as(usize, 3), store.comments.items.len);

    // Clear all comments
    store.clearAll();
    try std.testing.expectEqual(@as(usize, 0), store.comments.items.len);
}
