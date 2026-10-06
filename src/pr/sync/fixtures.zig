//! Synthetic GraphQL responses in the captured sync shapes
//! (scripts/test-infra/pr-sidebar/sync/captured/), shared by `sync.zig`'s
//! tests and the sync harness. Pure: JSON bytes out, no file IO.

const std = @import("std");
const sync_parse = @import("sync_parse.zig");
const types = @import("../db/types.zig");

pub const SynthPr = struct {
    number: u32,
    updated_at: []const u8,
    title: []const u8 = "synthetic PR",
    author: ?[]const u8 = "octo",
    is_draft: bool = false,
    labels: []const []const u8 = &.{},
};

pub const IndexPageParams = struct {
    prs: []const SynthPr,
    has_next: bool = false,
    end_cursor: ?[]const u8 = null,
    viewer_login: []const u8 = "ctdio",
};

pub const SynthClosed = struct {
    number: u32,
    /// "CLOSED" or "MERGED".
    state: []const u8 = "CLOSED",
    updated_at: []const u8,
};

pub const ClosedPageParams = struct {
    rows: []const SynthClosed,
    has_next: bool = false,
    end_cursor: ?[]const u8 = null,
};

pub const ReconcilePageParams = struct {
    numbers: []const u32,
    has_next: bool = false,
    end_cursor: ?[]const u8 = null,
};

pub const SynthReview = struct {
    author: []const u8,
    state: []const u8,
    oid: []const u8,
};

pub const HydrateNodeParams = struct {
    number: u32,
    updated_at: []const u8,
    additions: u32 = 0,
    deletions: u32 = 0,
    changed_files: u32 = 0,
    review_decision: ?[]const u8 = null,
    /// `statusCheckRollup.state`; null for no rollup.
    rollup: ?[]const u8 = null,
    requested_users: []const []const u8 = &.{},
    reviews: []const SynthReview = &.{},
};

pub const SynthPrsParams = struct {
    count: u32,
    first_number: u32 = 1,
    /// `ts` offset of the first PR.
    newest_offset: u64,
    /// How much older each next PR is.
    spacing_secs: u64 = 1,
};

/// The fixed origin of `ts`.
pub const epoch_secs: u64 = 1_767_225_600; // 2026-01-01T00:00:00Z

/// `2026-01-01T00:00:00Z` plus `offset_secs`, in GitHub's timestamp form.
/// Caller owns the result.
pub fn ts(allocator: std.mem.Allocator, offset_secs: u64) ![]u8 {
    const secs: std.time.epoch.EpochSeconds = .{ .secs = epoch_secs + offset_secs };
    const year_day = secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = secs.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    });
}

/// PRs `first_number..`, newest first, every `updated_at` distinct. Allocated from
/// `allocator` with no way to free piecemeal, so pass an arena.
pub fn synthPrs(allocator: std.mem.Allocator, params: SynthPrsParams) ![]SynthPr {
    const prs = try allocator.alloc(SynthPr, params.count);
    for (prs, 0..) |*pr, i| {
        pr.* = .{ .number = params.first_number + @as(u32, @intCast(i)), .updated_at = try ts(allocator, params.newest_offset - i * params.spacing_secs) };
    }
    return prs;
}

/// The synthetic GraphQL node id of PR `number`. Caller owns the result.
pub fn nodeId(allocator: std.mem.Allocator, number: u32) ![]u8 {
    return std.fmt.allocPrint(allocator, "PR_synth{d}", .{number});
}

/// A `SkimSyncIndex` response. Caller owns the result.
pub fn synthIndexPage(allocator: std.mem.Allocator, params: IndexPageParams) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = try a.alloc(IndexNodeJson, params.prs.len);
    for (params.prs, nodes) |pr, *node| {
        const labels = try a.alloc(NameJson, pr.labels.len);
        for (pr.labels, labels) |label, *out| out.* = .{ .name = label };
        node.* = .{
            .id = try nodeId(a, pr.number),
            .number = pr.number,
            .title = pr.title,
            .isDraft = pr.is_draft,
            .updatedAt = pr.updated_at,
            .url = try std.fmt.allocPrint(a, "https://github.com/acme/widgets/pull/{d}", .{pr.number}),
            .headRefName = try std.fmt.allocPrint(a, "feature-{d}", .{pr.number}),
            .baseRefName = "main",
            .headRefOid = try oidFor(a, pr.number, 'a'),
            .baseRefOid = try oidFor(a, pr.number, 'b'),
            .author = if (pr.author) |login| .{ .login = login } else null,
            .labels = .{ .nodes = labels },
        };
    }
    return std.json.Stringify.valueAlloc(allocator, .{ .data = .{
        .viewer = .{ .login = params.viewer_login },
        .repository = .{ .pullRequests = .{
            .pageInfo = .{ .hasNextPage = params.has_next, .endCursor = params.end_cursor },
            .nodes = nodes,
        } },
    } }, .{});
}

/// A `SkimSyncClosed` response. Caller owns the result.
pub fn synthClosedPage(allocator: std.mem.Allocator, params: ClosedPageParams) ![]u8 {
    const nodes = try allocator.alloc(ClosedNodeJson, params.rows.len);
    defer allocator.free(nodes);
    for (params.rows, nodes) |row, *node| node.* = .{ .number = row.number, .state = row.state, .updatedAt = row.updated_at };
    return std.json.Stringify.valueAlloc(allocator, .{ .data = .{ .repository = .{ .pullRequests = .{
        .pageInfo = .{ .hasNextPage = params.has_next, .endCursor = params.end_cursor },
        .nodes = nodes,
    } } } }, .{});
}

/// A `SkimSyncReconcile` response. Caller owns the result.
pub fn synthReconcilePage(allocator: std.mem.Allocator, params: ReconcilePageParams) ![]u8 {
    const nodes = try allocator.alloc(NumberJson, params.numbers.len);
    defer allocator.free(nodes);
    for (params.numbers, nodes) |number, *node| node.* = .{ .number = number };
    return std.json.Stringify.valueAlloc(allocator, .{ .data = .{ .repository = .{ .pullRequests = .{
        .pageInfo = .{ .hasNextPage = params.has_next, .endCursor = params.end_cursor },
        .nodes = nodes,
    } } } }, .{});
}

/// One `nodes(ids:)` element of a `SkimSyncHydrate` response, as the fake
/// `gh` serves it from `step-<n>/nodes/<id>.json`. Caller owns the result.
pub fn synthHydrateNode(allocator: std.mem.Allocator, params: HydrateNodeParams) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const requests = try a.alloc(ReviewRequestJson, params.requested_users.len);
    for (params.requested_users, requests) |login, *request| {
        request.* = .{ .requestedReviewer = .{ .__typename = "User", .login = login } };
    }
    const reviews = try a.alloc(ReviewJson, params.reviews.len);
    for (params.reviews, reviews) |review, *out| {
        out.* = .{ .author = .{ .login = review.author }, .state = review.state, .commit = .{ .oid = review.oid } };
    }
    const commits = try a.alloc(CommitNodeJson, 1);
    commits[0] = .{ .commit = .{ .statusCheckRollup = if (params.rollup) |state| .{ .state = state } else null } };

    return std.json.Stringify.valueAlloc(allocator, .{
        .number = params.number,
        .updatedAt = params.updated_at,
        .additions = params.additions,
        .deletions = params.deletions,
        .changedFiles = params.changed_files,
        .reviewDecision = params.review_decision,
        .reviewRequests = .{ .nodes = requests },
        .latestOpinionatedReviews = .{ .nodes = reviews },
        .commits = .{ .nodes = commits },
    }, .{});
}

/// A `SkimSyncTeams` response: `slugs == null` is a null organization (a
/// user-owned repo). Caller owns the result.
pub fn synthTeams(allocator: std.mem.Allocator, slugs: ?[]const []const u8) ![]u8 {
    const names = slugs orelse return allocator.dupe(u8, "{\"data\":{\"viewer\":{\"organization\":null}}}");
    const nodes = try allocator.alloc(SlugJson, names.len);
    defer allocator.free(nodes);
    for (names, nodes) |slug, *node| node.* = .{ .slug = slug };
    return std.json.Stringify.valueAlloc(allocator, .{ .data = .{ .viewer = .{ .organization = .{ .teams = .{ .nodes = nodes } } } } }, .{});
}

// JSON shapes. Field names are the GraphQL names.

const LoginJson = struct { login: []const u8 };
const NameJson = struct { name: []const u8 };
const NumberJson = struct { number: u32 };
const SlugJson = struct { slug: []const u8 };

const IndexNodeJson = struct {
    id: []const u8,
    number: u32,
    title: []const u8,
    isDraft: bool,
    updatedAt: []const u8,
    url: []const u8,
    headRefName: []const u8,
    baseRefName: []const u8,
    headRefOid: []const u8,
    baseRefOid: []const u8,
    author: ?LoginJson,
    labels: struct { nodes: []const NameJson },
};

const ClosedNodeJson = struct { number: u32, state: []const u8, updatedAt: []const u8 };

const ReviewRequestJson = struct { requestedReviewer: struct { __typename: []const u8, login: []const u8 } };

const ReviewJson = struct { author: LoginJson, state: []const u8, commit: struct { oid: []const u8 } };

const CommitNodeJson = struct { commit: struct { statusCheckRollup: ?struct { state: []const u8 } } };

/// A 40-char hex oid unique to `number`.
fn oidFor(a: std.mem.Allocator, number: u32, fill: u8) ![]u8 {
    const oid = try a.alloc(u8, 40);
    @memset(oid, fill);
    _ = std.fmt.bufPrint(oid[0..10], "{d:0>10}", .{number}) catch unreachable;
    return oid;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "ts formats the offset from 2026-01-01" {
    const zero = try ts(testing.allocator, 0);
    defer testing.allocator.free(zero);
    try testing.expectEqualStrings("2026-01-01T00:00:00Z", zero);
    const later = try ts(testing.allocator, 86_400 * 31 + 3600 + 61);
    defer testing.allocator.free(later);
    try testing.expectEqualStrings("2026-02-01T01:01:01Z", later);
}

test "synthIndexPage parses as an index page" {
    const bytes = try synthIndexPage(testing.allocator, .{
        .prs = &.{.{ .number = 7, .updated_at = "2026-01-01T00:00:07Z", .author = null, .labels = &.{ "bug", "ci" } }},
        .has_next = true,
        .end_cursor = "c/1+=",
    });
    defer testing.allocator.free(bytes);
    var page = try sync_parse.parseIndexPage(testing.allocator, bytes);
    defer page.deinit();
    try testing.expectEqualStrings("ctdio", page.viewer_login);
    try testing.expectEqualStrings("c/1+=", page.end_cursor.?);
    try testing.expectEqualStrings("PR_synth7", page.rows[0].node_id);
    try testing.expectEqualStrings("ghost", page.rows[0].author);
    try testing.expectEqualStrings("bug\nci", page.rows[0].labels);
    try testing.expectEqual(40, page.rows[0].head_oid.len);
}

test "synthHydrateNode parses as a hydrate node" {
    const node = try synthHydrateNode(testing.allocator, .{
        .number = 3,
        .updated_at = "t",
        .additions = 5,
        .rollup = "FAILURE",
        .requested_users = &.{"alice"},
        .reviews = &.{.{ .author = "ctdio", .state = "APPROVED", .oid = "abc" }},
    });
    defer testing.allocator.free(node);
    const bytes = try std.fmt.allocPrint(testing.allocator, "{{\"data\":{{\"nodes\":[{s}]}}}}", .{node});
    defer testing.allocator.free(bytes);
    const refs = [_]types.NodeRef{.{ .number = 3, .node_id = "PR_synth3", .updated_at = "t" }};
    var batch = try sync_parse.parseHydrate(testing.allocator, .{ .bytes = bytes, .refs = &refs, .viewer_login = "ctdio" });
    defer batch.deinit();
    try testing.expectEqual(5, batch.rows[0].additions);
    try testing.expectEqualStrings("alice", batch.rows[0].requested_users);
    try testing.expectEqualStrings("APPROVED", batch.rows[0].my_review_state);
}
