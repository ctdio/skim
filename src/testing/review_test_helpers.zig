//! Tests for the PR review-thread feature (Phase 2). Kept in `src/testing/`
//! (like the other `*_helpers`) and reaching production code through the
//! `review_test_root` named module — see `src/review_test_root.zig` for why.
//! Only this file's `test {}` blocks run in the `review_tests` binary.

const std = @import("std");
const review = @import("review_test_root");

const thread_anchor = review.thread_anchor;
const review_parse = review.review_parse;
const parser = review.parser;
const line_map = review.line_map;
const comments = review.comments;
const thread_block = review.thread_block;
const harness = review.harness;
const snapshot = review.snapshot;

const anchorThreads = review.anchorThreads;
const countUnplaced = review.countUnplaced;
const BucketReason = review.BucketReason;
const ReviewComment = review.ReviewComment;
const ReviewState = review.ReviewState;

const testing = std.testing;

// =============================================================================
// thread_anchor: pure side-aware anchoring
// =============================================================================

test "anchorThreads: RIGHT side on add line resolves inline" {
    var files = singleFile();
    const threads = [_]review_parse.ReviewThread{makeThread(.{ .path = "src/x.zig", .line = 11, .side = .right })};
    const anchored = try anchorThreads(testing.allocator, &threads, &files);
    defer testing.allocator.free(anchored);

    try testing.expectEqual(@as(usize, 1), anchored.len);
    try testing.expect(anchored[0].placement == .inline_line);
    const c = anchored[0].placement.inline_line;
    try testing.expectEqual(@as(usize, 0), c.file_idx);
    try testing.expectEqual(@as(usize, 0), c.hunk_idx);
    try testing.expectEqual(@as(usize, 2), c.line_idx); // "added one"
}

test "anchorThreads: RIGHT side on context line resolves inline" {
    var files = singleFile();
    const threads = [_]review_parse.ReviewThread{makeThread(.{ .path = "src/x.zig", .line = 13, .side = .right })};
    const anchored = try anchorThreads(testing.allocator, &threads, &files);
    defer testing.allocator.free(anchored);

    try testing.expect(anchored[0].placement == .inline_line);
    try testing.expectEqual(@as(usize, 4), anchored[0].placement.inline_line.line_idx); // "ctx after"
}

test "anchorThreads: LEFT side on delete line resolves inline via old_lineno" {
    var files = singleFile();
    const threads = [_]review_parse.ReviewThread{makeThread(.{ .path = "src/x.zig", .line = 11, .side = .left })};
    const anchored = try anchorThreads(testing.allocator, &threads, &files);
    defer testing.allocator.free(anchored);

    try testing.expect(anchored[0].placement == .inline_line);
    try testing.expectEqual(@as(usize, 1), anchored[0].placement.inline_line.line_idx); // "removed"
}

test "anchorThreads: LEFT side on context line resolves via old_lineno" {
    var files = singleFile();
    const threads = [_]review_parse.ReviewThread{makeThread(.{ .path = "src/x.zig", .line = 10, .side = .left })};
    const anchored = try anchorThreads(testing.allocator, &threads, &files);
    defer testing.allocator.free(anchored);

    try testing.expect(anchored[0].placement == .inline_line);
    try testing.expectEqual(@as(usize, 0), anchored[0].placement.inline_line.line_idx); // "ctx before"
}

test "anchorThreads: multi-line range anchors at end line" {
    // GitHub sends `line` = the last line of the range; anchor there.
    var files = singleFile();
    const threads = [_]review_parse.ReviewThread{blk: {
        var t = makeThread(.{ .path = "src/x.zig", .line = 12, .side = .right });
        t.start_line = 11;
        break :blk t;
    }};
    const anchored = try anchorThreads(testing.allocator, &threads, &files);
    defer testing.allocator.free(anchored);

    try testing.expect(anchored[0].placement == .inline_line);
    try testing.expectEqual(@as(usize, 3), anchored[0].placement.inline_line.line_idx); // "added two" (new 12)
}

test "anchorThreads: outdated thread buckets even when original_line would resolve" {
    var files = singleFile();
    const threads = [_]review_parse.ReviewThread{makeThread(.{ .path = "src/x.zig", .line = null, .is_outdated = true, .original_line = 11 })};
    const anchored = try anchorThreads(testing.allocator, &threads, &files);
    defer testing.allocator.free(anchored);

    try testing.expect(anchored[0].placement == .file_bucket);
    try testing.expectEqual(BucketReason.outdated, anchored[0].placement.file_bucket.reason);
    try testing.expectEqual(@as(usize, 0), anchored[0].placement.file_bucket.file_idx);
}

test "anchorThreads: line outside -U10 context buckets as out_of_context" {
    var files = singleFile();
    const threads = [_]review_parse.ReviewThread{makeThread(.{ .path = "src/x.zig", .line = 999, .side = .right })};
    const anchored = try anchorThreads(testing.allocator, &threads, &files);
    defer testing.allocator.free(anchored);

    try testing.expect(anchored[0].placement == .file_bucket);
    try testing.expectEqual(BucketReason.out_of_context, anchored[0].placement.file_bucket.reason);
}

test "anchorThreads: FILE subject buckets as file_level" {
    var files = singleFile();
    const threads = [_]review_parse.ReviewThread{makeThread(.{ .path = "src/x.zig", .line = null, .subject_type = .file })};
    const anchored = try anchorThreads(testing.allocator, &threads, &files);
    defer testing.allocator.free(anchored);

    try testing.expect(anchored[0].placement == .file_bucket);
    try testing.expectEqual(BucketReason.file_level, anchored[0].placement.file_bucket.reason);
}

test "anchorThreads: path not in diff is unplaced" {
    var files = singleFile();
    const threads = [_]review_parse.ReviewThread{makeThread(.{ .path = "does/not/exist.zig", .line = 5, .side = .right })};
    const anchored = try anchorThreads(testing.allocator, &threads, &files);
    defer testing.allocator.free(anchored);

    try testing.expect(anchored[0].placement == .unplaced);
    try testing.expectEqual(@as(usize, 1), countUnplaced(anchored));
}

test "anchorThreads: renamed file matches via old_path fallback" {
    const S = struct {
        var lines = [_]parser.Line{
            makeLine(.context, "unchanged", 1, 1),
            makeLine(.add, "new line", null, 2),
        };
        var hunks = [_]parser.Hunk{makeHunk(.{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 2, .context = "" }, &lines)};
    };
    var files = [_]parser.FileDiff{.{ .old_path = "old/name.zig", .new_path = "new/name.zig", .hunks = &S.hunks, .is_untracked = false }};

    // Thread was created against the pre-rename path.
    const threads = [_]review_parse.ReviewThread{makeThread(.{ .path = "old/name.zig", .line = 2, .side = .right })};
    const anchored = try anchorThreads(testing.allocator, &threads, &files);
    defer testing.allocator.free(anchored);

    try testing.expect(anchored[0].placement == .inline_line);
    try testing.expectEqual(@as(usize, 0), anchored[0].placement.inline_line.file_idx);
    try testing.expectEqual(@as(usize, 1), anchored[0].placement.inline_line.line_idx);
}

test "anchorThreads: empty diff yields all unplaced, totality holds" {
    const files = [_]parser.FileDiff{};
    const threads = [_]review_parse.ReviewThread{
        makeThread(.{ .path = "a.zig", .line = 1 }),
        makeThread(.{ .path = "b.zig", .line = 2 }),
    };
    const anchored = try anchorThreads(testing.allocator, &threads, &files);
    defer testing.allocator.free(anchored);

    try testing.expectEqual(@as(usize, 2), anchored.len);
    try testing.expect(anchored[0].placement == .unplaced);
    try testing.expect(anchored[1].placement == .unplaced);
    try testing.expectEqual(@as(usize, 2), countUnplaced(anchored));
}

test "anchorThreads: totality — mixed 8-thread input maps every thread exactly once" {
    var files = singleFile();
    const threads = [_]review_parse.ReviewThread{
        makeThread(.{ .path = "src/x.zig", .line = 11, .side = .right }), // inline
        makeThread(.{ .path = "src/x.zig", .line = 11, .side = .left }), // inline (delete)
        makeThread(.{ .path = "src/x.zig", .line = null, .is_outdated = true }), // bucket outdated
        makeThread(.{ .path = "src/x.zig", .line = 999, .side = .right }), // bucket out_of_context
        makeThread(.{ .path = "src/x.zig", .line = null, .subject_type = .file }), // bucket file_level
        makeThread(.{ .path = "missing.zig", .line = 3 }), // unplaced
        makeThread(.{ .path = "src/x.zig", .line = 13, .side = .right }), // inline (context)
        makeThread(.{ .path = "src/x.zig", .line = null }), // null line -> bucket outdated
    };
    const anchored = try anchorThreads(testing.allocator, &threads, &files);
    defer testing.allocator.free(anchored);

    try testing.expectEqual(@as(usize, 8), anchored.len);
    var inline_count: usize = 0;
    var bucket_count: usize = 0;
    var unplaced_count: usize = 0;
    for (anchored, 0..) |a, i| {
        try testing.expectEqual(i, a.thread_idx);
        switch (a.placement) {
            .inline_line => inline_count += 1,
            .file_bucket => bucket_count += 1,
            .unplaced => unplaced_count += 1,
        }
    }
    try testing.expectEqual(@as(usize, 3), inline_count);
    try testing.expectEqual(@as(usize, 4), bucket_count);
    try testing.expectEqual(@as(usize, 1), unplaced_count);
    try testing.expectEqual(inline_count + bucket_count + unplaced_count, anchored.len);
}

test "anchorThreads: two threads on the same coordinate both anchor inline in order" {
    var files = singleFile();
    const threads = [_]review_parse.ReviewThread{
        makeThread(.{ .path = "src/x.zig", .line = 11, .side = .right }),
        makeThread(.{ .path = "src/x.zig", .line = 11, .side = .right }),
    };
    const anchored = try anchorThreads(testing.allocator, &threads, &files);
    defer testing.allocator.free(anchored);

    try testing.expect(anchored[0].placement == .inline_line);
    try testing.expect(anchored[1].placement == .inline_line);
    try testing.expectEqual(anchored[0].placement.inline_line.line_idx, anchored[1].placement.inline_line.line_idx);
    try testing.expectEqual(@as(usize, 0), anchored[0].thread_idx);
    try testing.expectEqual(@as(usize, 1), anchored[1].thread_idx);
}

// =============================================================================
// line_map: review-thread record emission (integration through LineMap.build)
// =============================================================================

test "LineMap: inline thread emits a review_thread record after its code line" {
    const allocator = testing.allocator;
    var files = singleFile();
    var store = comments.CommentStore.init(allocator);
    defer store.deinit();

    const threads = [_]review_parse.ReviewThread{makeThread(.{ .path = "src/x.zig", .line = 11, .side = .right })};
    const anchored = try anchorThreads(allocator, &threads, &files);
    defer allocator.free(anchored);

    var map = try line_map.LineMap.build(allocator, &files, &store, .all, true, null, anchored);
    defer map.deinit();

    const thread_line = map.findLineByThreadIdx(0) orelse return error.ThreadRecordMissing;
    const record = map.getLineRecord(thread_line).?;
    try testing.expect(record.line_type == .review_thread);
    try testing.expectEqual(@as(usize, 0), record.line_type.review_thread.thread_idx);
    try testing.expect(record.line_type.review_thread.placement == .inline_line);

    // The record must sit immediately after the anchored "added one" code line.
    const prev = map.getLineRecord(thread_line - 1).?;
    try testing.expect(prev.line_type == .code_line);
    try testing.expectEqual(@as(usize, 2), prev.line_type.code_line.line_idx_in_hunk);
}

test "LineMap: file-bucket thread emits a record before the first hunk header" {
    const allocator = testing.allocator;
    var files = singleFile();
    var store = comments.CommentStore.init(allocator);
    defer store.deinit();

    const threads = [_]review_parse.ReviewThread{makeThread(.{ .path = "src/x.zig", .line = null, .is_outdated = true })};
    const anchored = try anchorThreads(allocator, &threads, &files);
    defer allocator.free(anchored);

    var map = try line_map.LineMap.build(allocator, &files, &store, .all, true, null, anchored);
    defer map.deinit();

    const thread_line = map.findLineByThreadIdx(0) orelse return error.ThreadRecordMissing;
    const record = map.getLineRecord(thread_line).?;
    try testing.expect(record.line_type.review_thread.placement == .file_bucket);

    // The next record is the first hunk header (bucket sits under the header spacer).
    const next = map.getLineRecord(thread_line + 1).?;
    try testing.expect(next.line_type == .hunk_header);
}

test "LineMap: null review_threads yields identical records to omitting threads" {
    const allocator = testing.allocator;
    var files = singleFile();
    var store = comments.CommentStore.init(allocator);
    defer store.deinit();

    // Anchor a real thread, but pass null → it must NOT be emitted.
    const threads = [_]review_parse.ReviewThread{makeThread(.{ .path = "src/x.zig", .line = 11, .side = .right })};
    const anchored = try anchorThreads(allocator, &threads, &files);
    defer allocator.free(anchored);

    var with_null = try line_map.LineMap.build(allocator, &files, &store, .all, true, null, null);
    defer with_null.deinit();
    var with_empty = try line_map.LineMap.build(allocator, &files, &store, .all, true, null, &.{});
    defer with_empty.deinit();

    try testing.expectEqual(with_null.records.len, with_empty.records.len);
    try testing.expect(with_null.findLineByThreadIdx(0) == null);

    // And a map WITH the anchors has strictly more records (one per thread).
    var with_threads = try line_map.LineMap.build(allocator, &files, &store, .all, true, null, anchored);
    defer with_threads.deinit();
    try testing.expectEqual(with_null.records.len + 1, with_threads.records.len);
}

test "LineMap: two inline threads on one line emit two consecutive records in order" {
    const allocator = testing.allocator;
    var files = singleFile();
    var store = comments.CommentStore.init(allocator);
    defer store.deinit();

    const threads = [_]review_parse.ReviewThread{
        makeThread(.{ .path = "src/x.zig", .line = 11, .side = .right }),
        makeThread(.{ .path = "src/x.zig", .line = 11, .side = .right }),
    };
    const anchored = try anchorThreads(allocator, &threads, &files);
    defer allocator.free(anchored);

    var map = try line_map.LineMap.build(allocator, &files, &store, .all, true, null, anchored);
    defer map.deinit();

    const first = map.findLineByThreadIdx(0) orelse return error.ThreadRecordMissing;
    const second = map.findLineByThreadIdx(1) orelse return error.ThreadRecordMissing;
    try testing.expectEqual(first + 1, second);
}

// =============================================================================
// thread_block: rendering + height parity (snapshot-backed)
// =============================================================================

test "threadDisplayHeight: collapsed thread is exactly one row" {
    var thread = makeThread(.{ .path = "src/x.zig", .line = 11, .side = .right });
    var cmts = [_]ReviewComment{makeComment(.{ .author = "alice", .body = "looks off" })};
    thread.comments = &cmts;

    const info = thread_block.ThreadRenderInfo{
        .thread = &thread,
        .is_bucketed = false,
        .expanded = false,
    };
    try testing.expectEqual(@as(usize, 1), thread_block.threadDisplayHeight(testing.allocator, info, 60));
}

test "threadDisplayHeight equals the rows renderThreadDisplay actually draws" {
    var thread = makeThread(.{ .path = "src/x.zig", .line = 11, .side = .right });
    var cmts = [_]ReviewComment{
        makeComment(.{ .author = "alice", .body = "first comment here" }),
        makeComment(.{ .author = "bob", .body = "a reply that is a bit longer so it wraps across the narrow column width" }),
    };
    thread.comments = &cmts;

    const info = thread_block.ThreadRenderInfo{
        .thread = &thread,
        .is_bucketed = false,
        .expanded = true,
    };

    const width: usize = 40;
    const height = thread_block.threadDisplayHeight(testing.allocator, info, width);

    var ctx = try harness.createTestContext(testing.allocator, @intCast(width), 40);
    defer ctx.deinit();
    const drawn = thread_block.renderThreadDisplay(ctx.window(), info, 0, width, ctx.frameAllocator());

    try testing.expectEqual(height, drawn);
}

test "snapshot: thread_collapsed" {
    var thread = makeThread(.{ .path = "src/x.zig", .line = 11, .side = .right });
    var cmts = [_]ReviewComment{makeComment(.{ .author = "alice", .body = "this needs a null check" })};
    thread.comments = &cmts;

    try renderThreadSnapshot("thread_collapsed", .{
        .thread = &thread,
        .is_bucketed = false,
        .expanded = false,
    });
}

test "snapshot: thread_expanded_single" {
    var thread = makeThread(.{ .path = "src/x.zig", .line = 11, .side = .right });
    var cmts = [_]ReviewComment{makeComment(.{ .author = "alice", .body = "this needs a null check before deref" })};
    thread.comments = &cmts;

    try renderThreadSnapshot("thread_expanded_single", .{
        .thread = &thread,
        .is_bucketed = false,
        .expanded = true,
    });
}

test "snapshot: thread_expanded_replies" {
    var thread = makeThread(.{ .path = "src/x.zig", .line = 11, .side = .right });
    var cmts = [_]ReviewComment{
        makeComment(.{ .author = "alice", .body = "should this be guarded?" }),
        makeComment(.{ .author = "bob", .body = "yes, fixing now" }),
    };
    thread.comments = &cmts;

    try renderThreadSnapshot("thread_expanded_replies", .{
        .thread = &thread,
        .is_bucketed = false,
        .expanded = true,
    });
}

test "snapshot: thread_resolved_collapsed" {
    var thread = makeThread(.{ .path = "src/x.zig", .line = 11, .side = .right });
    thread.is_resolved = true;
    var cmts = [_]ReviewComment{makeComment(.{ .author = "alice", .body = "done" })};
    thread.comments = &cmts;

    try renderThreadSnapshot("thread_resolved_collapsed", .{
        .thread = &thread,
        .is_bucketed = false,
        .expanded = false,
    });
}

test "snapshot: thread_outdated_bucket" {
    var thread = makeThread(.{ .path = "src/x.zig", .line = null, .is_outdated = true });
    var cmts = [_]ReviewComment{makeComment(.{ .author = "alice", .body = "context has since moved" })};
    thread.comments = &cmts;

    try renderThreadSnapshot("thread_outdated_bucket", .{
        .thread = &thread,
        .is_bucketed = true,
        .bucket_reason = .outdated,
        .expanded = true,
    });
}

test "snapshot: thread_file_level_bucket" {
    var thread = makeThread(.{ .path = "src/x.zig", .line = null, .subject_type = .file });
    var cmts = [_]ReviewComment{makeComment(.{ .author = "alice", .body = "whole-file note" })};
    thread.comments = &cmts;

    try renderThreadSnapshot("thread_file_level_bucket", .{
        .thread = &thread,
        .is_bucketed = true,
        .bucket_reason = .file_level,
        .expanded = true,
    });
}

test "snapshot: thread_suggestion" {
    var thread = makeThread(.{ .path = "src/x.zig", .line = 11, .side = .right });
    var cmts = [_]ReviewComment{makeComment(.{
        .author = "alice",
        .body = "use a guard here:\n```suggestion\nif (x == null) return;\n```\nthanks",
    })};
    thread.comments = &cmts;

    try renderThreadSnapshot("thread_suggestion", .{
        .thread = &thread,
        .is_bucketed = false,
        .expanded = true,
        .target_line_content = "    doStuff(x);",
    });
}

test "snapshot: thread_draft_badge" {
    var thread = makeThread(.{ .path = "src/x.zig", .line = 11, .side = .right });
    var cmts = [_]ReviewComment{makeComment(.{ .author = "alice", .body = "pending review note", .review_state = .pending })};
    thread.comments = &cmts;

    try renderThreadSnapshot("thread_draft_badge", .{
        .thread = &thread,
        .is_bucketed = false,
        .expanded = true,
    });
}

// =============================================================================
// Test builders
// =============================================================================

fn renderThreadSnapshot(name: []const u8, info: thread_block.ThreadRenderInfo) !void {
    const allocator = testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 24);
    defer ctx.deinit();

    _ = thread_block.renderThreadDisplay(ctx.window(), info, 0, 60, ctx.frameAllocator());

    const text = try ctx.captureToText();
    defer allocator.free(text);
    try snapshot.expectSnapshot(allocator, name, text);
}

fn makeComment(params: struct {
    author: []const u8,
    body: []const u8,
    created_at: []const u8 = "2024-01-15T10:00:00Z",
    review_state: ReviewState = .commented,
}) ReviewComment {
    return .{
        .id = "PRRC_x",
        .database_id = 1,
        .author = params.author,
        .body = params.body,
        .created_at = params.created_at,
        .review_id = "PRR_x",
        .review_state = params.review_state,
        .is_mine = false,
        .diff_hunk = "",
    };
}

fn makeLine(lt: parser.Line.LineType, content: []const u8, old_lineno: ?u32, new_lineno: ?u32) parser.Line {
    return .{ .line_type = lt, .content = content, .old_lineno = old_lineno, .new_lineno = new_lineno };
}

fn makeHunk(header: parser.HunkHeader, lines: []parser.Line) parser.Hunk {
    return .{ .header = header, .lines = lines, .highlights = null, .old_highlights = null };
}

fn makeThread(params: struct {
    path: []const u8,
    line: ?u32,
    side: review_parse.Side = .right,
    is_outdated: bool = false,
    subject_type: review_parse.SubjectType = .line,
    original_line: ?u32 = null,
}) review_parse.ReviewThread {
    return .{
        .id = "PRRT_x",
        .path = params.path,
        .line = params.line,
        .start_line = null,
        .original_line = params.original_line,
        .side = params.side,
        .start_side = params.side,
        .is_resolved = false,
        .is_outdated = params.is_outdated,
        .subject_type = params.subject_type,
        .comments = &.{},
    };
}

// A single file: hunk covering old 10-13 / new 10-14, one context, one delete,
// two adds, one trailing context.
fn singleFile() [1]parser.FileDiff {
    const S = struct {
        var lines = [_]parser.Line{
            makeLine(.context, "ctx before", 10, 10),
            makeLine(.delete, "removed", 11, null),
            makeLine(.add, "added one", null, 11),
            makeLine(.add, "added two", null, 12),
            makeLine(.context, "ctx after", 12, 13),
        };
        var hunks = [_]parser.Hunk{makeHunk(.{ .old_start = 10, .old_count = 3, .new_start = 10, .new_count = 4, .context = "" }, &lines)};
    };
    return .{.{ .old_path = "src/x.zig", .new_path = "src/x.zig", .hunks = &S.hunks, .is_untracked = false }};
}
