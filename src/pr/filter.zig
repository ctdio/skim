//! Pure filtering for the PR picker. Case-insensitive substring matching across
//! a PR's author, title, and branch — so live search (notably "by user") is a
//! tested unit, independent of any rendering.

const std = @import("std");
const parse = @import("parse.zig");

const PullRequest = parse.PullRequest;

/// Does `pr` pass both the text `query` and the pinned `author` filter? An empty
/// `author` means "any author"; otherwise the PR's author must match it exactly
/// (case-insensitive). The author filter is a separate, persistent dimension
/// that layers on top of free-text search.
pub fn matchesFilters(pr: PullRequest, query: []const u8, author: []const u8) bool {
    if (author.len > 0 and !std.ascii.eqlIgnoreCase(pr.author, author)) return false;
    return matches(pr, query);
}

/// Does `pr` match `query`? An empty query matches everything. A query is split
/// on spaces into terms; every term must appear (AND) in at least one of the
/// author, title, or branch fields.
pub fn matches(pr: PullRequest, query: []const u8) bool {
    var terms = std.mem.tokenizeScalar(u8, query, ' ');
    while (terms.next()) |term| {
        if (!matchesTerm(pr, term)) return false;
    }
    return true;
}

/// Indices into `prs` that match `query`, in order. Caller owns the slice.
pub fn filterIndices(allocator: std.mem.Allocator, prs: []const PullRequest, query: []const u8) ![]usize {
    var out: std.ArrayList(usize) = .{};
    errdefer out.deinit(allocator);
    for (prs, 0..) |pr, i| {
        if (matches(pr, query)) try out.append(allocator, i);
    }
    return out.toOwnedSlice(allocator);
}

fn matchesTerm(pr: PullRequest, term: []const u8) bool {
    return containsIgnoreCase(pr.author, term) or
        containsIgnoreCase(pr.title, term) or
        containsIgnoreCase(pr.head_ref, term) or
        containsIgnoreCase(pr.base_ref, term);
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn samplePr(params: struct { author: []const u8, title: []const u8, head: []const u8 }) PullRequest {
    return .{
        .number = 1,
        .title = params.title,
        .author = params.author,
        .head_ref = params.head,
        .base_ref = "main",
        .is_draft = false,
        .updated_at = "",
        .url = "",
        .ci = .none,
    };
}

test "matches: empty query matches everything" {
    const pr = samplePr(.{ .author = "octocat", .title = "Add widget", .head = "feature" });
    try testing.expect(matches(pr, ""));
}

test "matches: by author is case-insensitive" {
    const pr = samplePr(.{ .author = "OctoCat", .title = "Add widget", .head = "feature" });
    try testing.expect(matches(pr, "octo"));
    try testing.expect(!matches(pr, "alice"));
}

test "matches: hits title and branch too" {
    const pr = samplePr(.{ .author = "alice", .title = "Fix login bug", .head = "fix/login" });
    try testing.expect(matches(pr, "login"));
    try testing.expect(matches(pr, "fix/log"));
}

test "matches: hits the base branch too" {
    const pr = samplePr(.{ .author = "alice", .title = "Fix login bug", .head = "fix/login" });
    // samplePr pins base_ref to "main"
    try testing.expect(matches(pr, "main"));
}

test "matches: multiple terms must all match (AND)" {
    const pr = samplePr(.{ .author = "alice", .title = "Fix login bug", .head = "fix/login" });
    try testing.expect(matches(pr, "alice login"));
    try testing.expect(!matches(pr, "alice payments"));
}

test "matchesFilters: empty author filter matches any author" {
    const pr = samplePr(.{ .author = "alice", .title = "Add widget", .head = "feature" });
    try testing.expect(matchesFilters(pr, "", ""));
    try testing.expect(matchesFilters(pr, "widget", ""));
}

test "matchesFilters: author filter is an exact case-insensitive match" {
    const pr = samplePr(.{ .author = "Alice", .title = "Add widget", .head = "feature" });
    try testing.expect(matchesFilters(pr, "", "alice"));
    try testing.expect(!matchesFilters(pr, "", "ali"));
    try testing.expect(!matchesFilters(pr, "", "bob"));
}

test "matchesFilters: query and author filter are ANDed together" {
    const pr = samplePr(.{ .author = "alice", .title = "Fix login", .head = "fix/login" });
    try testing.expect(matchesFilters(pr, "login", "alice"));
    try testing.expect(!matchesFilters(pr, "payments", "alice"));
    try testing.expect(!matchesFilters(pr, "login", "bob"));
}

test "filterIndices: returns matching positions in order" {
    const prs = [_]PullRequest{
        samplePr(.{ .author = "alice", .title = "a", .head = "x" }),
        samplePr(.{ .author = "bob", .title = "b", .head = "y" }),
        samplePr(.{ .author = "alice", .title = "c", .head = "z" }),
    };
    const idx = try filterIndices(testing.allocator, &prs, "alice");
    defer testing.allocator.free(idx);
    try testing.expectEqualSlices(usize, &.{ 0, 2 }, idx);
}
