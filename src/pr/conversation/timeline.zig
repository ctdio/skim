//! The PR conversation as one time-ordered list: top-level comments, review
//! verdicts and summaries, and one entry per code thread. Pure: no vaxis, no
//! IO. `render.zig` lays these out; `state.zig` holds the cursor.

const std = @import("std");
const review_parse = @import("../review_parse.zig");
const review_controller = @import("../review_controller.zig");

const Allocator = std.mem.Allocator;

pub const Entry = struct {
    /// ISO8601 from GitHub; sorts lexically.
    at: []const u8,
    author: []const u8,
    body: []const u8,
    kind: Kind,
};

pub const Kind = union(enum) {
    comment,
    review: review_parse.ReviewState,
    thread: Thread,
};

pub const Thread = struct {
    /// Index into the session's `threads`, for jumping to it in the diff.
    index: usize,
    path: []const u8,
    line: ?u32,
    replies: usize,
    resolved: bool,
    outdated: bool,
};

/// Every entry, oldest first; ties keep comments, then reviews, then threads.
/// A review left only as the container for inline comments (commented, no
/// body) and the viewer's unsubmitted review are skipped: their content is
/// already in the thread entries.
pub fn build(arena: Allocator, params: struct {
    comments: []const review_parse.IssueComment,
    reviews: []const review_parse.Review,
    threads: []const review_controller.SessionThread,
}) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    for (params.comments) |comment| {
        try entries.append(arena, .{ .at = comment.created_at, .author = comment.author, .body = comment.body, .kind = .comment });
    }
    for (params.reviews) |review| {
        switch (review.state) {
            .pending => continue,
            .commented, .unknown => if (std.mem.trim(u8, review.body, " \t\r\n").len == 0) continue,
            .approved, .changes_requested, .dismissed => {},
        }
        try entries.append(arena, .{ .at = review.submitted_at, .author = review.author, .body = review.body, .kind = .{ .review = review.state } });
    }
    for (params.threads, 0..) |session_thread, index| {
        if (session_thread.posting) continue;
        const thread = session_thread.data;
        if (thread.comments.len == 0) continue;
        const first = thread.comments[0];
        try entries.append(arena, .{ .at = first.created_at, .author = first.author, .body = first.body, .kind = .{ .thread = .{
            .index = index,
            .path = thread.path,
            .line = thread.line orelse thread.original_line,
            .replies = thread.comments.len - 1,
            .resolved = thread.is_resolved,
            .outdated = thread.is_outdated,
        } } });
    }
    std.mem.sort(Entry, entries.items, {}, earlier);
    return entries.items;
}

fn earlier(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.at, b.at) == .lt;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn makeComment(author: []const u8, at: []const u8) review_parse.IssueComment {
    return .{ .id = "", .author = author, .body = "hi", .created_at = at };
}

fn makeReview(params: struct { author: []const u8, state: review_parse.ReviewState, at: []const u8, body: []const u8 = "" }) review_parse.Review {
    return .{ .id = "", .author = params.author, .state = params.state, .body = params.body, .submitted_at = params.at };
}

fn makeThread(comments: []review_parse.ReviewComment) review_controller.SessionThread {
    return .{ .data = .{
        .id = "",
        .path = "src/x.zig",
        .line = 42,
        .start_line = null,
        .original_line = 40,
        .side = .right,
        .start_side = .right,
        .is_resolved = true,
        .is_outdated = false,
        .subject_type = .line,
        .comments = comments,
    } };
}

fn reviewComment(author: []const u8, at: []const u8) review_parse.ReviewComment {
    return .{ .id = "", .database_id = 0, .author = author, .body = "nit", .created_at = at, .review_id = "", .review_state = .commented, .is_mine = false, .diff_hunk = "" };
}

test "build: merges comments, reviews and threads oldest first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const comments = [_]review_parse.IssueComment{ makeComment("alice", "2025-01-03T00:00:00Z"), makeComment("bob", "2025-01-01T00:00:00Z") };
    const reviews = [_]review_parse.Review{makeReview(.{ .author = "carol", .state = .approved, .at = "2025-01-02T00:00:00Z" })};
    var thread_comments = [_]review_parse.ReviewComment{reviewComment("dave", "2025-01-04T00:00:00Z")};
    const threads = [_]review_controller.SessionThread{makeThread(&thread_comments)};

    const entries = try build(arena.allocator(), .{ .comments = &comments, .reviews = &reviews, .threads = &threads });

    try testing.expectEqual(@as(usize, 4), entries.len);
    try testing.expectEqualStrings("bob", entries[0].author);
    try testing.expectEqualStrings("carol", entries[1].author);
    try testing.expectEqualStrings("alice", entries[2].author);
    try testing.expectEqualStrings("dave", entries[3].author);
}

test "build: skips a bodiless commented review and the viewer's pending review" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const reviews = [_]review_parse.Review{
        makeReview(.{ .author = "a", .state = .commented, .at = "1", .body = " \n" }),
        makeReview(.{ .author = "b", .state = .pending, .at = "2", .body = "draft" }),
        makeReview(.{ .author = "c", .state = .commented, .at = "3", .body = "overall looks good" }),
    };

    const entries = try build(arena.allocator(), .{ .comments = &.{}, .reviews = &reviews, .threads = &.{} });

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("c", entries[0].author);
}

test "build: a thread entry carries its first comment, reply count and session index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var thread_comments = [_]review_parse.ReviewComment{ reviewComment("dave", "2"), reviewComment("erin", "3") };
    var posting = makeThread(&thread_comments);
    posting.posting = true;
    const threads = [_]review_controller.SessionThread{ posting, makeThread(&thread_comments) };

    const entries = try build(arena.allocator(), .{ .comments = &.{}, .reviews = &.{}, .threads = &threads });

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("dave", entries[0].author);
    try testing.expectEqual(@as(usize, 1), entries[0].kind.thread.index);
    try testing.expectEqual(@as(usize, 1), entries[0].kind.thread.replies);
    try testing.expectEqual(@as(?u32, 42), entries[0].kind.thread.line);
    try testing.expect(entries[0].kind.thread.resolved);
}
