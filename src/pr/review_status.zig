//! Who has approved a PR and how its checks stand, summarized from the review
//! session's reviews and check runs for the status line above the diff.
//! Pure: no vaxis, no IO.

const std = @import("std");
const review_parse = @import("review_parse.zig");

const Allocator = std.mem.Allocator;
const Review = review_parse.Review;
const CheckRun = review_parse.CheckRun;

pub const CheckOutcome = enum { passed, failed, pending };

pub const Status = struct {
    /// Logins whose latest verdict is an approval, in first-review order.
    approvers: []const []const u8,
    /// Logins whose latest verdict requests changes, in first-review order.
    change_requesters: []const []const u8,
    passed: usize,
    failed: usize,
    pending: usize,
    /// Names of the failed checks, in check order.
    failing: []const []const u8,
};

/// Summarize `reviews` (oldest first, as GitHub returns them) and `checks`.
/// Only an author's latest approve / request-changes / dismissal counts: a
/// later plain comment does not withdraw an approval.
pub fn summarize(arena: Allocator, params: struct {
    reviews: []const Review,
    checks: []const CheckRun,
}) !Status {
    var authors: std.ArrayList([]const u8) = .empty;
    var verdicts: std.ArrayList(review_parse.ReviewState) = .empty;
    for (params.reviews) |review| {
        switch (review.state) {
            .approved, .changes_requested, .dismissed => {},
            .commented, .pending, .unknown => continue,
        }
        if (review.author.len == 0) continue;
        const index = indexOfAuthor(authors.items, review.author) orelse blk: {
            try authors.append(arena, review.author);
            try verdicts.append(arena, review.state);
            break :blk authors.items.len - 1;
        };
        verdicts.items[index] = review.state;
    }

    var approvers: std.ArrayList([]const u8) = .empty;
    var change_requesters: std.ArrayList([]const u8) = .empty;
    for (authors.items, verdicts.items) |author, verdict| {
        switch (verdict) {
            .approved => try approvers.append(arena, author),
            .changes_requested => try change_requesters.append(arena, author),
            else => {},
        }
    }

    var status: Status = .{
        .approvers = approvers.items,
        .change_requesters = change_requesters.items,
        .passed = 0,
        .failed = 0,
        .pending = 0,
        .failing = &.{},
    };
    var failing: std.ArrayList([]const u8) = .empty;
    for (params.checks) |check| {
        switch (checkOutcome(check)) {
            .passed => status.passed += 1,
            .pending => status.pending += 1,
            .failed => {
                status.failed += 1;
                try failing.append(arena, check.name);
            },
        }
    }
    status.failing = failing.items;
    return status;
}

/// A check that has not completed is pending; a completed one failed when its
/// conclusion is a failure, and passed otherwise (success, neutral, skipped).
pub fn checkOutcome(check: CheckRun) CheckOutcome {
    if (!std.mem.eql(u8, check.status, "COMPLETED")) return .pending;
    const failures = [_][]const u8{ "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE" };
    for (failures) |failure| {
        if (std.mem.eql(u8, check.conclusion, failure)) return .failed;
    }
    return .passed;
}

/// GitHub logins are case-insensitive.
fn indexOfAuthor(authors: []const []const u8, author: []const u8) ?usize {
    for (authors, 0..) |existing, index| {
        if (std.ascii.eqlIgnoreCase(existing, author)) return index;
    }
    return null;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn makeReview(author: []const u8, state: review_parse.ReviewState) Review {
    return .{ .id = "", .author = author, .state = state, .body = "", .submitted_at = "" };
}

fn makeCheck(name: []const u8, status: []const u8, conclusion: []const u8) CheckRun {
    return .{ .name = name, .status = status, .conclusion = conclusion };
}

test "summarize: lists each approver once, in first-review order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const reviews = [_]Review{ makeReview("bob", .approved), makeReview("alice", .approved), makeReview("bob", .approved) };

    const status = try summarize(arena.allocator(), .{ .reviews = &reviews, .checks = &.{} });

    try testing.expectEqual(@as(usize, 2), status.approvers.len);
    try testing.expectEqualStrings("bob", status.approvers[0]);
    try testing.expectEqualStrings("alice", status.approvers[1]);
}

test "summarize: a later comment keeps an approval" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const reviews = [_]Review{ makeReview("alice", .approved), makeReview("alice", .commented) };

    const status = try summarize(arena.allocator(), .{ .reviews = &reviews, .checks = &.{} });

    try testing.expectEqual(@as(usize, 1), status.approvers.len);
}

test "summarize: a later change request replaces an approval" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const reviews = [_]Review{ makeReview("alice", .approved), makeReview("Alice", .changes_requested) };

    const status = try summarize(arena.allocator(), .{ .reviews = &reviews, .checks = &.{} });

    try testing.expectEqual(@as(usize, 0), status.approvers.len);
    try testing.expectEqual(@as(usize, 1), status.change_requesters.len);
    try testing.expectEqualStrings("alice", status.change_requesters[0]);
}

test "summarize: a dismissed approval no longer counts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const reviews = [_]Review{ makeReview("alice", .approved), makeReview("alice", .dismissed) };

    const status = try summarize(arena.allocator(), .{ .reviews = &reviews, .checks = &.{} });

    try testing.expectEqual(@as(usize, 0), status.approvers.len);
    try testing.expectEqual(@as(usize, 0), status.change_requesters.len);
}

test "summarize: tallies checks and names the failed ones" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const checks = [_]CheckRun{
        makeCheck("build", "COMPLETED", "SUCCESS"),
        makeCheck("lint", "COMPLETED", "FAILURE"),
        makeCheck("docs", "COMPLETED", "SKIPPED"),
        makeCheck("e2e", "IN_PROGRESS", ""),
        makeCheck("deploy", "COMPLETED", "TIMED_OUT"),
    };

    const status = try summarize(arena.allocator(), .{ .reviews = &.{}, .checks = &checks });

    try testing.expectEqual(@as(usize, 2), status.passed);
    try testing.expectEqual(@as(usize, 2), status.failed);
    try testing.expectEqual(@as(usize, 1), status.pending);
    try testing.expectEqualStrings("lint", status.failing[0]);
    try testing.expectEqualStrings("deploy", status.failing[1]);
}
