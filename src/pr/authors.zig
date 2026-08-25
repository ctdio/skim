//! Pure derivation of the distinct PR authors for the "filter by user" picker.
//! Bytes in (the loaded PRs), owned tally out — sorted busiest-first — so the
//! author overlay's contents are a tested unit, independent of any rendering.

const std = @import("std");
const parse = @import("parse.zig");
const filter = @import("filter.zig");

const PullRequest = parse.PullRequest;

pub const AuthorCount = struct {
    login: []const u8,
    count: usize,
};

/// Distinct authors across `prs` with how many open PRs each has, sorted by
/// count descending then login ascending (case-insensitive). Authors are
/// deduped case-insensitively, keeping the first-seen spelling. PRs with an
/// empty author are skipped. Caller owns the slice; each `login` aliases the
/// backing `prs`, so it is only valid while they are.
pub fn distinct(allocator: std.mem.Allocator, prs: []const PullRequest) ![]AuthorCount {
    var list: std.ArrayList(AuthorCount) = .empty;
    errdefer list.deinit(allocator);

    for (prs) |pr| {
        if (pr.author.len == 0) continue;
        if (findAuthor(list.items, pr.author)) |idx| {
            list.items[idx].count += 1;
        } else {
            try list.append(allocator, .{ .login = pr.author, .count = 1 });
        }
    }

    const out = try list.toOwnedSlice(allocator);
    std.sort.block(AuthorCount, out, {}, lessThan);
    return out;
}

/// Does `login` match the overlay's filter `query`? Case-insensitive substring;
/// an empty query matches everything.
pub fn matchesQuery(login: []const u8, query: []const u8) bool {
    return filter.containsIgnoreCase(login, query);
}

fn findAuthor(items: []const AuthorCount, login: []const u8) ?usize {
    for (items, 0..) |a, i| {
        if (std.ascii.eqlIgnoreCase(a.login, login)) return i;
    }
    return null;
}

fn lessThan(_: void, a: AuthorCount, b: AuthorCount) bool {
    if (a.count != b.count) return a.count > b.count;
    return lessIgnoreCase(a.login, b.login);
}

fn lessIgnoreCase(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[i]);
        if (ca != cb) return ca < cb;
    }
    return a.len < b.len;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn samplePr(author: []const u8) PullRequest {
    return .{
        .number = 1,
        .title = "t",
        .author = author,
        .head_ref = "h",
        .base_ref = "main",
        .is_draft = false,
        .updated_at = "",
        .url = "",
        .ci = .none,
    };
}

test "distinct: empty PR list yields no authors" {
    const out = try distinct(testing.allocator, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "distinct: tallies PRs per author" {
    const prs = [_]PullRequest{ samplePr("alice"), samplePr("bob"), samplePr("alice") };
    const out = try distinct(testing.allocator, &prs);
    defer testing.allocator.free(out);

    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("alice", out[0].login);
    try testing.expectEqual(@as(usize, 2), out[0].count);
    try testing.expectEqualStrings("bob", out[1].login);
    try testing.expectEqual(@as(usize, 1), out[1].count);
}

test "distinct: dedupes authors case-insensitively, keeping first spelling" {
    const prs = [_]PullRequest{ samplePr("Alice"), samplePr("alice") };
    const out = try distinct(testing.allocator, &prs);
    defer testing.allocator.free(out);

    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("Alice", out[0].login);
    try testing.expectEqual(@as(usize, 2), out[0].count);
}

test "distinct: sorts busiest author first, then alphabetically" {
    const prs = [_]PullRequest{ samplePr("carol"), samplePr("bob"), samplePr("bob"), samplePr("alice") };
    const out = try distinct(testing.allocator, &prs);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("bob", out[0].login);
    try testing.expectEqualStrings("alice", out[1].login);
    try testing.expectEqualStrings("carol", out[2].login);
}

test "distinct: skips PRs with an empty author" {
    const prs = [_]PullRequest{ samplePr(""), samplePr("alice") };
    const out = try distinct(testing.allocator, &prs);
    defer testing.allocator.free(out);

    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("alice", out[0].login);
}

test "matchesQuery: empty query matches; substring is case-insensitive" {
    try testing.expect(matchesQuery("charlieduong94", ""));
    try testing.expect(matchesQuery("charlieduong94", "DUONG"));
    try testing.expect(!matchesQuery("charlieduong94", "octocat"));
}
