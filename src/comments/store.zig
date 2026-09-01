const std = @import("std");
const parser = @import("../git/parser.zig");

const Allocator = std.mem.Allocator;

/// Author label for anything the reviewer writes in the TUI or via the CLI.
/// Agent-authored replies carry the agent's own name instead, which is what
/// makes a thread read as an exchange rather than a pile of notes.
pub const local_author = "you";

/// A reply threaded under a comment. Ordered oldest-first.
pub const Reply = struct {
    author: []const u8,
    text: []const u8,

    pub fn deinit(self: *const Reply, allocator: Allocator) void {
        allocator.free(self.author);
        allocator.free(self.text);
    }
};

/// A comment attached to a specific line or range of lines in a diff, plus any
/// replies threaded under it. The comment's own text is the root of the thread;
/// `replies` holds every message posted after it.
pub const Comment = struct {
    /// Stable identity, unique for the store's lifetime and never reused. A
    /// comment's *index* shifts whenever a lower one is deleted, so anything
    /// that outlives a single call — an open reply editor, the expanded set, an
    /// agent that read `list_comments` a moment ago — must hold this instead.
    id: u64,
    file_path: []const u8, // Which file this comment belongs to
    hunk_idx: usize, // Which hunk (0-indexed) - start of range
    line_idx: usize, // Line within hunk (0-indexed, relative to all hunk lines) - start of range
    author: []const u8, // Who wrote the root comment
    text: []const u8, // The comment text (can be multi-line)
    replies: std.ArrayList(Reply), // Replies, oldest first

    // Range support (null means single-line comment)
    end_hunk_idx: ?usize, // End hunk for range comments
    end_line_idx: ?usize, // End line within hunk for range comments

    // Captured context for export (start line)
    line_type: parser.Line.LineType,
    line_content: []const u8,
    old_lineno: ?u32,
    new_lineno: ?u32,

    pub fn deinit(self: *Comment, allocator: Allocator) void {
        allocator.free(self.file_path);
        allocator.free(self.author);
        allocator.free(self.text);
        allocator.free(self.line_content);
        for (self.replies.items) |*reply| reply.deinit(allocator);
        self.replies.deinit(allocator);
    }
};

/// Everything needed to place a comment. `end_hunk_idx`/`end_line_idx` are set
/// together for a range comment and left null for a single-line one.
pub const AddParams = struct {
    file_path: []const u8,
    hunk_idx: usize,
    line_idx: usize,
    text: []const u8,
    line_type: parser.Line.LineType,
    line_content: []const u8,
    old_lineno: ?u32 = null,
    new_lineno: ?u32 = null,
    end_hunk_idx: ?usize = null,
    end_line_idx: ?usize = null,
    author: []const u8 = local_author,
};

/// Storage for all comments in the current review session
pub const CommentStore = struct {
    comments: std.ArrayList(Comment),
    allocator: Allocator,
    /// Monotonic source of `Comment.id`. Never decremented, so a deleted
    /// comment's id cannot be handed to a later one.
    next_id: u64,

    pub fn init(allocator: Allocator) CommentStore {
        return .{
            .comments = .empty,
            .allocator = allocator,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *CommentStore) void {
        for (self.comments.items) |*comment| {
            comment.deinit(self.allocator);
        }
        self.comments.deinit(self.allocator);
    }

    /// Add a comment (single-line or range). Returns its index.
    pub fn add(self: *CommentStore, params: AddParams) !usize {
        const comment = Comment{
            .id = self.next_id,
            .file_path = try self.allocator.dupe(u8, params.file_path),
            .hunk_idx = params.hunk_idx,
            .line_idx = params.line_idx,
            .author = try self.allocator.dupe(u8, params.author),
            .text = try self.allocator.dupe(u8, params.text),
            .replies = .empty,
            .end_hunk_idx = params.end_hunk_idx,
            .end_line_idx = params.end_line_idx,
            .line_type = params.line_type,
            .line_content = try self.allocator.dupe(u8, params.line_content),
            .old_lineno = params.old_lineno,
            .new_lineno = params.new_lineno,
        };
        try self.comments.append(self.allocator, comment);
        self.next_id += 1;
        return self.comments.items.len - 1;
    }

    /// Resolve a stable id to its current index, or null if it was deleted.
    pub fn findById(self: *const CommentStore, id: u64) ?usize {
        for (self.comments.items, 0..) |comment, idx| {
            if (comment.id == id) return idx;
        }
        return null;
    }

    /// The stable id of the comment at `comment_idx`, or null if out of range.
    pub fn idAt(self: *const CommentStore, comment_idx: usize) ?u64 {
        if (comment_idx >= self.comments.items.len) return null;
        return self.comments.items[comment_idx].id;
    }

    /// Update an existing comment's text
    pub fn updateComment(self: *CommentStore, comment_idx: usize, new_text: []const u8) !void {
        if (comment_idx >= self.comments.items.len) return error.InvalidCommentIndex;

        var comment = &self.comments.items[comment_idx];
        const text = try self.allocator.dupe(u8, new_text);
        self.allocator.free(comment.text);
        comment.text = text;
    }

    /// Append a reply to a comment's thread. Returns the reply's index.
    pub fn addReply(self: *CommentStore, comment_idx: usize, author: []const u8, text: []const u8) !usize {
        if (comment_idx >= self.comments.items.len) return error.InvalidCommentIndex;

        var comment = &self.comments.items[comment_idx];
        const reply = Reply{
            .author = try self.allocator.dupe(u8, author),
            .text = try self.allocator.dupe(u8, text),
        };
        errdefer reply.deinit(self.allocator);
        try comment.replies.append(self.allocator, reply);
        return comment.replies.items.len - 1;
    }

    /// Update an existing reply's text
    pub fn updateReply(self: *CommentStore, comment_idx: usize, reply_idx: usize, new_text: []const u8) !void {
        if (comment_idx >= self.comments.items.len) return error.InvalidCommentIndex;
        var comment = &self.comments.items[comment_idx];
        if (reply_idx >= comment.replies.items.len) return error.InvalidReplyIndex;

        var reply = &comment.replies.items[reply_idx];
        const text = try self.allocator.dupe(u8, new_text);
        self.allocator.free(reply.text);
        reply.text = text;
    }

    /// Delete a reply from a comment's thread
    pub fn deleteReply(self: *CommentStore, comment_idx: usize, reply_idx: usize) !void {
        if (comment_idx >= self.comments.items.len) return error.InvalidCommentIndex;
        var comment = &self.comments.items[comment_idx];
        if (reply_idx >= comment.replies.items.len) return error.InvalidReplyIndex;

        const reply = comment.replies.orderedRemove(reply_idx);
        reply.deinit(self.allocator);
    }

    /// Number of replies threaded under a comment
    pub fn replyCount(self: *const CommentStore, comment_idx: usize) usize {
        if (comment_idx >= self.comments.items.len) return 0;
        return self.comments.items[comment_idx].replies.items.len;
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
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();

        const writer = &output.writer;

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

            try writeThread(writer, comment);
            try writer.writeAll("---\n\n");
        }

        try writer.writeAll("</code_review>\n");
        return output.toOwnedSlice();
    }

    pub fn exportSingleCommentWithContext(
        self: *const CommentStore,
        allocator: Allocator,
        comment_idx: usize,
        files: []const parser.FileDiff,
        context_lines_before: usize,
        context_lines_after: usize,
    ) ![]const u8 {
        if (comment_idx >= self.comments.items.len) {
            return error.InvalidCommentIndex;
        }

        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();

        const writer = &output.writer;
        const comment = &self.comments.items[comment_idx];

        try writer.writeAll("<code_review>\n");
        try writer.print("File: {s}\n\n", .{comment.file_path});

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

        try writeThread(writer, comment);
        try writer.writeAll("---\n");

        try writer.writeAll("</code_review>\n");
        return output.toOwnedSlice();
    }

    /// Write a comment and its replies as a conversation. Replies are labelled
    /// with their author so an agent reading the export can tell who said what
    /// and which turn it is answering.
    fn writeThread(writer: anytype, comment: *const Comment) !void {
        try writer.print("Comment ({s}):\n", .{comment.author});
        try writer.print("{s}\n\n", .{comment.text});

        for (comment.replies.items) |reply| {
            try writer.print("Reply ({s}):\n", .{reply.author});
            try writer.print("{s}\n\n", .{reply.text});
        }
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
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();

        const writer = &output.writer;

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

            try writeThread(writer, comment);
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

    const idx = try store.add(.{
        .file_path = "test.zig",
        .hunk_idx = 0,
        .line_idx = 5,
        .text = "This needs validation",
        .line_type = .add,
        .line_content = "const x = getValue();",
        .new_lineno = 42,
    });
    try std.testing.expectEqual(@as(usize, 0), idx);

    try std.testing.expectEqual(@as(usize, 1), store.comments.items.len);
    try std.testing.expect(store.hasCommentAt("test.zig", 0, 5));
    try std.testing.expect(!store.hasCommentAt("test.zig", 0, 6));

    const found = store.findCommentAt("test.zig", 0, 5);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(usize, 0), found.?);

    try store.updateComment(0, "Updated comment text");
    const comment = store.getComment(0).?;
    try std.testing.expectEqualStrings("Updated comment text", comment.text);

    try store.deleteComment(0);
    try std.testing.expectEqual(@as(usize, 0), store.comments.items.len);
}

test "a new comment defaults to the local author and has no replies" {
    const allocator = std.testing.allocator;

    var store = CommentStore.init(allocator);
    defer store.deinit();

    _ = try store.add(.{
        .file_path = "test.zig",
        .hunk_idx = 0,
        .line_idx = 0,
        .text = "note",
        .line_type = .add,
        .line_content = "x",
    });

    const comment = store.getComment(0).?;
    try std.testing.expectEqualStrings(local_author, comment.author);
    try std.testing.expectEqual(@as(usize, 0), store.replyCount(0));
}

test "replies append to a comment in order and keep their authors" {
    const allocator = std.testing.allocator;

    var store = CommentStore.init(allocator);
    defer store.deinit();

    _ = try store.add(.{
        .file_path = "test.zig",
        .hunk_idx = 0,
        .line_idx = 0,
        .text = "why is this not cached?",
        .line_type = .add,
        .line_content = "const x = foo();",
    });

    try std.testing.expectEqual(@as(usize, 0), try store.addReply(0, "claude", "foo() memoizes internally"));
    try std.testing.expectEqual(@as(usize, 1), try store.addReply(0, local_author, "ok, drop the TODO then"));

    const comment = store.getComment(0).?;
    try std.testing.expectEqual(@as(usize, 2), comment.replies.items.len);
    try std.testing.expectEqualStrings("claude", comment.replies.items[0].author);
    try std.testing.expectEqualStrings("foo() memoizes internally", comment.replies.items[0].text);
    try std.testing.expectEqualStrings(local_author, comment.replies.items[1].author);
    try std.testing.expectEqualStrings("ok, drop the TODO then", comment.replies.items[1].text);
}

test "addReply rejects an out-of-range comment index" {
    const allocator = std.testing.allocator;

    var store = CommentStore.init(allocator);
    defer store.deinit();

    try std.testing.expectError(error.InvalidCommentIndex, store.addReply(0, "claude", "hi"));
}

test "updateReply replaces only the targeted reply text" {
    const allocator = std.testing.allocator;

    var store = CommentStore.init(allocator);
    defer store.deinit();

    _ = try store.add(.{
        .file_path = "test.zig",
        .hunk_idx = 0,
        .line_idx = 0,
        .text = "root",
        .line_type = .add,
        .line_content = "x",
    });
    _ = try store.addReply(0, "claude", "first");
    _ = try store.addReply(0, local_author, "second");

    try store.updateReply(0, 0, "revised");

    const comment = store.getComment(0).?;
    try std.testing.expectEqualStrings("revised", comment.replies.items[0].text);
    try std.testing.expectEqualStrings("second", comment.replies.items[1].text);
}

test "updateReply rejects an out-of-range reply index" {
    const allocator = std.testing.allocator;

    var store = CommentStore.init(allocator);
    defer store.deinit();

    _ = try store.add(.{
        .file_path = "test.zig",
        .hunk_idx = 0,
        .line_idx = 0,
        .text = "root",
        .line_type = .add,
        .line_content = "x",
    });

    try std.testing.expectError(error.InvalidReplyIndex, store.updateReply(0, 0, "nope"));
}

test "deleteReply removes the reply and keeps the rest in order" {
    const allocator = std.testing.allocator;

    var store = CommentStore.init(allocator);
    defer store.deinit();

    _ = try store.add(.{
        .file_path = "test.zig",
        .hunk_idx = 0,
        .line_idx = 0,
        .text = "root",
        .line_type = .add,
        .line_content = "x",
    });
    _ = try store.addReply(0, "claude", "first");
    _ = try store.addReply(0, local_author, "second");
    _ = try store.addReply(0, "claude", "third");

    try store.deleteReply(0, 1);

    const comment = store.getComment(0).?;
    try std.testing.expectEqual(@as(usize, 2), comment.replies.items.len);
    try std.testing.expectEqualStrings("first", comment.replies.items[0].text);
    try std.testing.expectEqualStrings("third", comment.replies.items[1].text);
}

test "deleting a comment frees its replies" {
    const allocator = std.testing.allocator;

    var store = CommentStore.init(allocator);
    defer store.deinit();

    _ = try store.add(.{
        .file_path = "test.zig",
        .hunk_idx = 0,
        .line_idx = 0,
        .text = "root",
        .line_type = .add,
        .line_content = "x",
    });
    _ = try store.addReply(0, "claude", "a reply that must be freed");

    try store.deleteComment(0);
    try std.testing.expectEqual(@as(usize, 0), store.comments.items.len);
}

test "clearAll frees comments that carry replies" {
    const allocator = std.testing.allocator;

    var store = CommentStore.init(allocator);
    defer store.deinit();

    _ = try store.add(.{
        .file_path = "file1.zig",
        .hunk_idx = 0,
        .line_idx = 5,
        .text = "Comment 1",
        .line_type = .add,
        .line_content = "line 1",
        .new_lineno = 10,
    });
    _ = try store.addReply(0, "claude", "reply 1");
    _ = try store.add(.{
        .file_path = "file2.zig",
        .hunk_idx = 1,
        .line_idx = 10,
        .text = "Comment 2",
        .line_type = .delete,
        .line_content = "line 2",
        .old_lineno = 20,
    });

    try std.testing.expectEqual(@as(usize, 2), store.comments.items.len);

    store.clearAll();
    try std.testing.expectEqual(@as(usize, 0), store.comments.items.len);
}

test "export to markdown" {
    const allocator = std.testing.allocator;

    var store = CommentStore.init(allocator);
    defer store.deinit();

    _ = try store.add(.{
        .file_path = "src/app.zig",
        .hunk_idx = 0,
        .line_idx = 10,
        .text = "This should check for null",
        .line_type = .add,
        .line_content = "const value = data.getValue();",
        .new_lineno = 150,
    });

    const markdown = try store.exportToMarkdown(allocator);
    defer allocator.free(markdown);

    try std.testing.expect(std.mem.containsAtLeast(u8, markdown, 1, "<code_review>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, markdown, 1, "src/app.zig"));
    try std.testing.expect(std.mem.containsAtLeast(u8, markdown, 1, "This should check for null"));
    try std.testing.expect(std.mem.containsAtLeast(u8, markdown, 1, "Comment (you):"));
}

test "export to markdown labels each reply with its author" {
    const allocator = std.testing.allocator;

    var store = CommentStore.init(allocator);
    defer store.deinit();

    _ = try store.add(.{
        .file_path = "src/app.zig",
        .hunk_idx = 0,
        .line_idx = 10,
        .text = "why is this not cached?",
        .line_type = .add,
        .line_content = "const value = data.getValue();",
        .new_lineno = 150,
    });
    _ = try store.addReply(0, "claude", "getValue memoizes internally");
    _ = try store.addReply(0, local_author, "ok, drop the TODO then");

    const markdown = try store.exportToMarkdown(allocator);
    defer allocator.free(markdown);

    try std.testing.expect(std.mem.containsAtLeast(u8, markdown, 1, "Comment (you):\nwhy is this not cached?"));
    try std.testing.expect(std.mem.containsAtLeast(u8, markdown, 1, "Reply (claude):\ngetValue memoizes internally"));
    try std.testing.expect(std.mem.containsAtLeast(u8, markdown, 1, "Reply (you):\nok, drop the TODO then"));

    // Replies follow the root comment, in order.
    const root_at = std.mem.indexOf(u8, markdown, "why is this not cached?").?;
    const first_reply_at = std.mem.indexOf(u8, markdown, "getValue memoizes internally").?;
    const second_reply_at = std.mem.indexOf(u8, markdown, "ok, drop the TODO then").?;
    try std.testing.expect(root_at < first_reply_at);
    try std.testing.expect(first_reply_at < second_reply_at);
}

test "a comment's id survives the deletion of a lower-indexed comment" {
    const allocator = std.testing.allocator;

    var store = CommentStore.init(allocator);
    defer store.deinit();

    _ = try store.add(.{
        .file_path = "a.zig",
        .hunk_idx = 0,
        .line_idx = 0,
        .text = "first",
        .line_type = .add,
        .line_content = "x",
    });
    _ = try store.add(.{
        .file_path = "a.zig",
        .hunk_idx = 0,
        .line_idx = 1,
        .text = "second",
        .line_type = .add,
        .line_content = "y",
    });

    const second_id = store.idAt(1).?;
    try store.deleteComment(0);

    // The index moved; the id did not.
    try std.testing.expectEqual(@as(?usize, 0), store.findById(second_id));
    try std.testing.expectEqualStrings("second", store.getComment(0).?.text);
}

test "a deleted comment's id is not handed to a later comment" {
    const allocator = std.testing.allocator;

    var store = CommentStore.init(allocator);
    defer store.deinit();

    _ = try store.add(.{
        .file_path = "a.zig",
        .hunk_idx = 0,
        .line_idx = 0,
        .text = "first",
        .line_type = .add,
        .line_content = "x",
    });
    const first_id = store.idAt(0).?;
    try store.deleteComment(0);

    _ = try store.add(.{
        .file_path = "a.zig",
        .hunk_idx = 0,
        .line_idx = 1,
        .text = "second",
        .line_type = .add,
        .line_content = "y",
    });

    try std.testing.expect(store.idAt(0).? != first_id);
    try std.testing.expectEqual(@as(?usize, null), store.findById(first_id));
}
