//! Pure parsing of the sync GraphQL responses (`queries.zig`) into the store's
//! row types. Bytes in, arena-owned rows out; no IO. Imports `db/types.zig`,
//! never `store.zig`, so this file compiles without SQLite (D4).
//!
//! Every parser rejects a response without `data` that carries a GraphQL
//! `errors` array with `error.GraphqlError`, and a `repository: null` with
//! `error.RepositoryNotFound`. The caller maps both onto a `GhErrorKind`.

const std = @import("std");
const json_fields = @import("../json.zig");
const parse = @import("../parse.zig");
const review_parse = @import("../review_parse.zig");
const types = @import("../db/types.zig");

const objField = json_fields.objField;
const objValue = json_fields.objValue;
const arrField = json_fields.arrField;
const strField = json_fields.strField;
const boolField = json_fields.boolField;
const optU32Field = json_fields.optU32Field;
const u32Field = json_fields.u32Field;

pub const ParseError = error{
    GraphqlError,
    RepositoryNotFound,
    MissingField,
    InvalidPayload,
    /// A hydrate response whose `nodes` array is not the length of the ids
    /// that were sent, so nodes cannot be matched back to PRs.
    NodeCountMismatch,
};

pub const IndexPage = struct {
    arena: std.heap.ArenaAllocator,
    /// "" when the response has no viewer.
    viewer_login: []const u8,
    rows: []types.IndexRow,
    has_next: bool,
    end_cursor: ?[]const u8,

    pub fn deinit(self: *IndexPage) void {
        self.arena.deinit();
    }
};

pub const ClosedPage = struct {
    arena: std.heap.ArenaAllocator,
    rows: []types.ClosedRow,
    has_next: bool,
    end_cursor: ?[]const u8,

    pub fn deinit(self: *ClosedPage) void {
        self.arena.deinit();
    }
};

pub const ReconcilePage = struct {
    arena: std.heap.ArenaAllocator,
    numbers: []u32,
    has_next: bool,
    end_cursor: ?[]const u8,

    pub fn deinit(self: *ReconcilePage) void {
        self.arena.deinit();
    }
};

pub const HydrateBatch = struct {
    arena: std.heap.ArenaAllocator,
    rows: []types.HydrateRow,
    /// Ids that came back `null` with a NOT_FOUND error (deleted or
    /// transferred), or as a non-PullRequest node. The caller marks these
    /// CLOSED so they leave the sidebar and are not re-requested every run.
    missing: []types.ClosedRow,
    /// Refs whose node came back `null` without a NOT_FOUND error for its
    /// slot (FORBIDDEN, or no error at all). The PR may still exist, so it is
    /// not closed; the caller marks it hydrated at its current `updated_at`
    /// so it is not re-requested until GitHub reports a change.
    unresolved: []types.NodeRef,

    pub fn deinit(self: *HydrateBatch) void {
        self.arena.deinit();
    }
};

pub const HydrateParams = struct {
    bytes: []const u8,
    /// The refs whose `node_id`s were sent, in request order. GitHub answers
    /// `nodes(ids:)` in the same order, so `nodes[i]` belongs to `refs[i]`.
    refs: []const types.NodeRef,
    viewer_login: []const u8,
};

pub const TeamsParams = struct {
    bytes: []const u8,
    /// The repo owner the teams query asked about; prefixed (lowercased) to
    /// every slug.
    owner: []const u8,
};

const PageInfo = struct { has_next: bool, end_cursor: ?[]const u8 };

pub fn parseIndexPage(allocator: std.mem.Allocator, bytes: []const u8) !IndexPage {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const root = try parseRoot(a, bytes);
    const data = try dataObject(root);
    const viewer_login = loginOf(objField(data, "viewer")) orelse "";
    const connection = try pullRequestsOf(data);
    const page = pageInfoOf(connection);

    const nodes = arrField(connection, "nodes") orelse &.{};
    const rows = try a.alloc(types.IndexRow, nodes.len);
    for (nodes, rows) |node, *row| row.* = try indexRowFrom(a, node);

    return .{
        .arena = arena,
        .viewer_login = viewer_login,
        .rows = rows,
        .has_next = page.has_next,
        .end_cursor = page.end_cursor,
    };
}

pub fn parseClosedPage(allocator: std.mem.Allocator, bytes: []const u8) !ClosedPage {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const root = try parseRoot(a, bytes);
    const connection = try pullRequestsOf(try dataObject(root));
    const page = pageInfoOf(connection);

    const nodes = arrField(connection, "nodes") orelse &.{};
    const rows = try a.alloc(types.ClosedRow, nodes.len);
    for (nodes, rows) |node, *row| {
        if (node != .object) return error.MissingField;
        const merged = std.mem.eql(u8, strField(node.object, "state") orelse "", "MERGED");
        row.* = .{
            .number = optU32Field(node.object, "number") orelse return error.MissingField,
            .state = if (merged) .merged else .closed,
            .updated_at = strField(node.object, "updatedAt") orelse return error.MissingField,
        };
    }

    return .{ .arena = arena, .rows = rows, .has_next = page.has_next, .end_cursor = page.end_cursor };
}

pub fn parseReconcilePage(allocator: std.mem.Allocator, bytes: []const u8) !ReconcilePage {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const root = try parseRoot(a, bytes);
    const connection = try pullRequestsOf(try dataObject(root));
    const page = pageInfoOf(connection);

    const nodes = arrField(connection, "nodes") orelse &.{};
    const numbers = try a.alloc(u32, nodes.len);
    for (nodes, numbers) |node, *number| {
        if (node != .object) return error.MissingField;
        number.* = optU32Field(node.object, "number") orelse return error.MissingField;
    }

    return .{ .arena = arena, .numbers = numbers, .has_next = page.has_next, .end_cursor = page.end_cursor };
}

/// Hydrate rows for the PullRequest nodes, and a CLOSED row (built from the
/// ref) for every node GitHub reports gone: `null` with a NOT_FOUND error at
/// `path: ["nodes", i]`, or `{}`. Any other `null` is returned in
/// `unresolved`, since closing on FORBIDDEN or a transient error would drop a
/// PR that still exists.
pub fn parseHydrate(allocator: std.mem.Allocator, params: HydrateParams) !HydrateBatch {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const root = try parseRoot(a, params.bytes);
    const data = try dataObject(root);
    const nodes = arrField(data, "nodes") orelse return error.MissingField;
    if (nodes.len != params.refs.len) return error.NodeCountMismatch;
    const errors = arrField(root.object, "errors") orelse &.{};

    var rows: std.ArrayList(types.HydrateRow) = .empty;
    var missing: std.ArrayList(types.ClosedRow) = .empty;
    var unresolved: std.ArrayList(types.NodeRef) = .empty;
    for (nodes, params.refs, 0..) |node, ref, slot| {
        if (node == .null and !nodeNotFound(errors, slot)) {
            try unresolved.append(a, ref);
            continue;
        }
        // A node that is no longer a PullRequest comes back as `{}` (the
        // inline fragment matched nothing); treat it like a deleted one.
        const pr = if (node == .object and node.object.get("number") != null) node.object else {
            try missing.append(a, .{ .number = ref.number, .state = .closed, .updated_at = ref.updated_at });
            continue;
        };
        try rows.append(a, try hydrateRowFrom(a, .{ .pr = pr, .number = ref.number, .viewer_login = params.viewer_login }));
    }

    return .{ .arena = arena, .rows = rows.items, .missing = missing.items, .unresolved = unresolved.items };
}

/// One lowercase "owner/slug" per team the viewer belongs to in `owner`, the
/// form hydrate produces for `requested_teams`. Empty when
/// `viewer.organization` is null (user-owned repo, or not a member).
/// The slice and its strings are allocated from `allocator` along with the
/// parse tree, so pass an arena.
pub fn parseViewerTeams(allocator: std.mem.Allocator, params: TeamsParams) ![]const []const u8 {
    const root = try parseRoot(allocator, params.bytes);
    const data = try dataObject(root);
    const viewer = objField(data, "viewer") orelse return error.MissingField;
    const org = objField(viewer, "organization") orelse return &.{};
    const teams = objField(org, "teams") orelse return &.{};
    const nodes = arrField(teams, "nodes") orelse &.{};

    var names: std.ArrayList([]const u8) = .empty;
    for (nodes) |node| {
        if (node != .object) continue;
        const slug = strField(node.object, "slug") orelse continue;
        try names.append(allocator, try teamName(allocator, params.owner, slug));
    }
    return names.items;
}

/// Map a `statusCheckRollup.state` onto the sidebar's CI status. Unknown
/// values and a missing rollup are `.none`.
pub fn ciFromRollup(state: ?[]const u8) parse.CiStatus {
    const value = state orelse return .none;
    return switch (review_parse.rollupFromState(value)) {
        .success => .success,
        .failure, .err => .failure,
        .pending => .pending,
        .none => .none,
    };
}

// =============================================================================
// Helpers
// =============================================================================

/// Strings are always copied into `a`: the input bytes are the caller's
/// subprocess output, freed long before the rows are.
fn parseRoot(a: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .allocate = .alloc_always });
}

fn dataObject(root: std.json.Value) ParseError!std.json.ObjectMap {
    if (root != .object) return error.InvalidPayload;
    if (objField(root.object, "data")) |data| return data;
    if (review_parse.graphqlErrorMessage(root) != null) return error.GraphqlError;
    return error.MissingField;
}

fn pullRequestsOf(data: std.json.ObjectMap) ParseError!std.json.ObjectMap {
    const repository = objField(data, "repository") orelse return error.RepositoryNotFound;
    return objField(repository, "pullRequests") orelse error.MissingField;
}

fn pageInfoOf(connection: std.json.ObjectMap) PageInfo {
    const info = objField(connection, "pageInfo") orelse return .{ .has_next = false, .end_cursor = null };
    return .{ .has_next = boolField(info, "hasNextPage"), .end_cursor = strField(info, "endCursor") };
}

/// Whether `errors` holds a NOT_FOUND entry whose path is `["nodes", slot]`.
fn nodeNotFound(errors: []const std.json.Value, slot: usize) bool {
    for (errors) |entry| {
        if (entry != .object) continue;
        if (!std.mem.eql(u8, strField(entry.object, "type") orelse "", "NOT_FOUND")) continue;
        const path = arrField(entry.object, "path") orelse continue;
        if (path.len != 2 or path[0] != .string or !std.mem.eql(u8, path[0].string, "nodes")) continue;
        if (path[1] == .integer and path[1].integer == slot) return true;
    }
    return false;
}

fn loginOf(actor: ?std.json.ObjectMap) ?[]const u8 {
    return strField(actor orelse return null, "login");
}

fn indexRowFrom(a: std.mem.Allocator, node: std.json.Value) !types.IndexRow {
    if (node != .object) return error.MissingField;
    const pr = node.object;
    return .{
        .number = optU32Field(pr, "number") orelse return error.MissingField,
        .node_id = strField(pr, "id") orelse return error.MissingField,
        .title = strField(pr, "title") orelse "",
        // A deleted account comes back as `author: null`; `gh pr list` shows it as ghost.
        .author = loginOf(objField(pr, "author")) orelse "ghost",
        .url = strField(pr, "url") orelse "",
        .is_draft = boolField(pr, "isDraft"),
        .head_ref = strField(pr, "headRefName") orelse "",
        .base_ref = strField(pr, "baseRefName") orelse "",
        .head_oid = strField(pr, "headRefOid") orelse "",
        .base_oid = strField(pr, "baseRefOid") orelse "",
        .updated_at = strField(pr, "updatedAt") orelse return error.MissingField,
        .labels = try joinLabels(a, pr),
    };
}

fn joinLabels(a: std.mem.Allocator, pr: std.json.ObjectMap) ![]const u8 {
    const labels = objField(pr, "labels") orelse return "";
    const nodes = arrField(labels, "nodes") orelse return "";
    var names: std.ArrayList([]const u8) = .empty;
    for (nodes) |label| {
        if (label != .object) continue;
        try names.append(a, strField(label.object, "name") orelse continue);
    }
    return std.mem.join(a, "\n", names.items);
}

fn hydrateRowFrom(a: std.mem.Allocator, params: struct {
    pr: std.json.ObjectMap,
    number: u32,
    viewer_login: []const u8,
}) !types.HydrateRow {
    const pr = params.pr;
    const reviewers = try requestedReviewers(a, pr);
    const mine = myReview(pr, params.viewer_login);
    return .{
        .number = params.number,
        .updated_at = strField(pr, "updatedAt") orelse return error.MissingField,
        .additions = u32Field(pr, "additions"),
        .deletions = u32Field(pr, "deletions"),
        .changed_files = u32Field(pr, "changedFiles"),
        .review_decision = strField(pr, "reviewDecision") orelse "",
        .ci = ciFromRollup(headRollupState(pr)),
        .requested_users = reviewers.users,
        .requested_teams = reviewers.teams,
        .my_review_state = mine.state,
        .my_review_oid = mine.oid,
    };
}

fn headRollupState(pr: std.json.ObjectMap) ?[]const u8 {
    const commits = objField(pr, "commits") orelse return null;
    const nodes = arrField(commits, "nodes") orelse return null;
    if (nodes.len == 0) return null;
    const commit = objValue(nodes[0], "commit") orelse return null;
    const rollup = objField(commit, "statusCheckRollup") orelse return null;
    return strField(rollup, "state");
}

const Reviewers = struct { users: []const u8, teams: []const u8 };

/// Users and teams requested for review. `null` reviewers (a team the token
/// cannot see), bots and mannequins are skipped.
fn requestedReviewers(a: std.mem.Allocator, pr: std.json.ObjectMap) !Reviewers {
    const requests = objField(pr, "reviewRequests") orelse return .{ .users = "", .teams = "" };
    const nodes = arrField(requests, "nodes") orelse &.{};
    var users: std.ArrayList([]const u8) = .empty;
    var teams: std.ArrayList([]const u8) = .empty;
    for (nodes) |request| {
        const reviewer = objValue(request, "requestedReviewer") orelse continue;
        const typename = strField(reviewer, "__typename") orelse continue;
        if (std.mem.eql(u8, typename, "User")) {
            try users.append(a, strField(reviewer, "login") orelse continue);
        } else if (std.mem.eql(u8, typename, "Team")) {
            const slug = strField(reviewer, "slug") orelse continue;
            const org = loginOf(objField(reviewer, "organization")) orelse continue;
            try teams.append(a, try teamName(a, org, slug));
        }
    }
    return .{
        .users = try std.mem.join(a, "\n", users.items),
        .teams = try std.mem.join(a, "\n", teams.items),
    };
}

const MyReview = struct { state: []const u8, oid: []const u8 };

/// The viewer's latest APPROVED / CHANGES_REQUESTED review. GitHub logins are
/// case-insensitive.
fn myReview(pr: std.json.ObjectMap, viewer_login: []const u8) MyReview {
    const none: MyReview = .{ .state = "", .oid = "" };
    if (viewer_login.len == 0) return none;
    const reviews = objField(pr, "latestOpinionatedReviews") orelse return none;
    for (arrField(reviews, "nodes") orelse &.{}) |review| {
        if (review != .object) continue;
        const author = loginOf(objField(review.object, "author")) orelse continue;
        if (!std.ascii.eqlIgnoreCase(author, viewer_login)) continue;
        return .{
            .state = strField(review.object, "state") orelse "",
            .oid = strField(objField(review.object, "commit") orelse return none, "oid") orelse "",
        };
    }
    return none;
}

/// Lowercase "org/slug". Teams and hydrate both go through here, so the
/// viewer's teams and a PR's requested teams compare equal.
fn teamName(a: std.mem.Allocator, org: []const u8, slug: []const u8) ![]const u8 {
    const name = try std.fmt.allocPrint(a, "{s}/{s}", .{ org, slug });
    return std.ascii.lowerString(name, name);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const captured_index_page1 = @embedFile("sync_fixture_index_page1");
const captured_empty_index = @embedFile("sync_fixture_empty_index");
const captured_closed_page1 = @embedFile("sync_fixture_closed_page1");
const captured_reconcile_page1 = @embedFile("sync_fixture_reconcile_page1");
const captured_hydrate_batch = @embedFile("sync_fixture_hydrate_batch");
const captured_hydrate_partial_error = @embedFile("sync_fixture_hydrate_partial_error");
const captured_not_found_repo = @embedFile("sync_fixture_not_found_repo");
const captured_teams_null_org = @embedFile("sync_fixture_teams_null_org");

fn indexPageWith(comptime node: []const u8) []const u8 {
    return
    \\{"data":{"viewer":{"login":"ctdio"},"repository":{"pullRequests":{
    \\"pageInfo":{"hasNextPage":false,"endCursor":"c1"},"nodes":[
    ++ node ++ "]}}}}";
}

fn hydrateWith(comptime nodes: []const u8) []const u8 {
    return "{\"data\":{\"nodes\":[" ++ nodes ++ "]}}";
}

fn refsFor(comptime numbers: []const u32) [numbers.len]types.NodeRef {
    var refs: [numbers.len]types.NodeRef = undefined;
    for (numbers, &refs) |number, *ref| {
        ref.* = .{ .number = number, .node_id = "PR_x", .updated_at = "2026-01-01T00:00:00Z" };
    }
    return refs;
}

const full_index_node =
    \\{"id":"PR_1","number":7,"title":"Fix it","isDraft":true,"updatedAt":"2026-10-04T10:00:00Z",
    \\"url":"https://github.com/acme/widgets/pull/7","headRefName":"fix","baseRefName":"main",
    \\"headRefOid":"aaaa","baseRefOid":"bbbb","author":{"login":"octo"},
    \\"labels":{"nodes":[{"name":"bug"},{"name":"ci"}]}}
;

test "parseIndexPage on captured index-page1 returns 100 rows with viewer, cursor and has_next" {
    var page = try parseIndexPage(testing.allocator, captured_index_page1);
    defer page.deinit();
    try testing.expectEqual(100, page.rows.len);
    try testing.expectEqualStrings("ctdio", page.viewer_login);
    try testing.expect(page.has_next);
    try testing.expect(page.end_cursor != null);
}

test "captured index page leads with its newest row" {
    // GitHub's UPDATED_AT order is not strictly monotonic in the reported
    // updatedAt (this capture has one row ~2h out of place), so the watermark
    // relies only on row 0 being the newest.
    var page = try parseIndexPage(testing.allocator, captured_index_page1);
    defer page.deinit();
    for (page.rows[1..]) |row| {
        try testing.expect(std.mem.order(u8, page.rows[0].updated_at, row.updated_at) != .lt);
    }
}

test "index row maps every field" {
    var page = try parseIndexPage(testing.allocator, indexPageWith(full_index_node));
    defer page.deinit();
    const row = page.rows[0];
    try testing.expectEqual(7, row.number);
    try testing.expectEqualStrings("PR_1", row.node_id);
    try testing.expectEqualStrings("Fix it", row.title);
    try testing.expectEqualStrings("octo", row.author);
    try testing.expectEqualStrings("https://github.com/acme/widgets/pull/7", row.url);
    try testing.expect(row.is_draft);
    try testing.expectEqualStrings("fix", row.head_ref);
    try testing.expectEqualStrings("main", row.base_ref);
    try testing.expectEqualStrings("aaaa", row.head_oid);
    try testing.expectEqualStrings("bbbb", row.base_oid);
    try testing.expectEqualStrings("2026-10-04T10:00:00Z", row.updated_at);
    try testing.expectEqualStrings("bug\nci", row.labels);
    try testing.expectEqualStrings("c1", page.end_cursor.?);
    try testing.expect(!page.has_next);
}

test "index rows outlive the input bytes" {
    const bytes = try testing.allocator.dupe(u8, indexPageWith(full_index_node));
    var page = try parseIndexPage(testing.allocator, bytes);
    defer page.deinit();
    @memset(bytes, 'x');
    testing.allocator.free(bytes);
    try testing.expectEqualStrings("Fix it", page.rows[0].title);
    try testing.expectEqualStrings("ctdio", page.viewer_login);
}

test "index node with null author maps to ghost" {
    var page = try parseIndexPage(testing.allocator, indexPageWith(
        \\{"id":"PR_1","number":7,"updatedAt":"2026-10-04T10:00:00Z","author":null,"labels":{"nodes":[]}}
    ));
    defer page.deinit();
    try testing.expectEqualStrings("ghost", page.rows[0].author);
}

test "index node with no labels yields empty labels string" {
    var page = try parseIndexPage(testing.allocator, indexPageWith(
        \\{"id":"PR_1","number":7,"updatedAt":"2026-10-04T10:00:00Z","author":{"login":"a"},"labels":{"nodes":[]}}
    ));
    defer page.deinit();
    try testing.expectEqualStrings("", page.rows[0].labels);
}

test "empty repo page parses to zero rows, no next page, null cursor" {
    var page = try parseIndexPage(testing.allocator, captured_empty_index);
    defer page.deinit();
    try testing.expectEqual(0, page.rows.len);
    try testing.expect(!page.has_next);
    try testing.expectEqual(null, page.end_cursor);
}

test "index node missing id fails with MissingField" {
    try testing.expectError(error.MissingField, parseIndexPage(testing.allocator, indexPageWith(
        \\{"number":7,"updatedAt":"2026-10-04T10:00:00Z"}
    )));
}

test "index node missing updatedAt fails with MissingField" {
    try testing.expectError(error.MissingField, parseIndexPage(testing.allocator, indexPageWith(
        \\{"id":"PR_1","number":7}
    )));
}

test "repository null returns RepositoryNotFound" {
    try testing.expectError(error.RepositoryNotFound, parseIndexPage(testing.allocator, captured_not_found_repo));
}

test "errors without data returns GraphqlError" {
    try testing.expectError(error.GraphqlError, parseIndexPage(testing.allocator,
        \\{"errors":[{"message":"Something went wrong"}]}
    ));
}

test "a non-object body is InvalidPayload" {
    try testing.expectError(error.InvalidPayload, parseIndexPage(testing.allocator, "[]"));
}

test "truncated JSON is a parse error" {
    try testing.expect(std.meta.isError(parseIndexPage(testing.allocator, "{\"data\":")));
}

test "parseClosedPage on captured closed-page1 yields CLOSED/MERGED rows with updated_at" {
    var page = try parseClosedPage(testing.allocator, captured_closed_page1);
    defer page.deinit();
    try testing.expectEqual(50, page.rows.len);
    try testing.expect(page.has_next);
    // First captured node: #98531, CLOSED, 2026-10-05T00:29:03Z.
    try testing.expectEqual(98531, page.rows[0].number);
    try testing.expectEqual(types.PrState.closed, page.rows[0].state);
    try testing.expectEqualStrings("2026-10-05T00:29:03Z", page.rows[0].updated_at);
    var merged: usize = 0;
    for (page.rows) |row| {
        try testing.expect(row.state != .open);
        try testing.expect(row.updated_at.len > 0);
        merged += @intFromBool(row.state == .merged);
    }
    try testing.expect(merged > 0);
}

test "parseReconcilePage on captured reconcile-page1 yields 100 distinct numbers" {
    var page = try parseReconcilePage(testing.allocator, captured_reconcile_page1);
    defer page.deinit();
    try testing.expectEqual(100, page.numbers.len);
    try testing.expect(page.has_next);
    const sorted = try testing.allocator.dupe(u32, page.numbers);
    defer testing.allocator.free(sorted);
    std.mem.sort(u32, sorted, {}, std.sort.asc(u32));
    for (sorted[0 .. sorted.len - 1], sorted[1..]) |a, b| try testing.expect(a != b);
}

test "reconcile empty page yields zero numbers and no next page" {
    var page = try parseReconcilePage(testing.allocator,
        \\{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}
    );
    defer page.deinit();
    try testing.expectEqual(0, page.numbers.len);
    try testing.expect(!page.has_next);
}

test "parseHydrate on captured hydrate-batch maps additions/deletions/changed_files/review_decision/ci" {
    var index = try parseIndexPage(testing.allocator, captured_index_page1);
    defer index.deinit();
    var refs: [25]types.NodeRef = undefined;
    for (index.rows[0..25], &refs) |row, *ref| ref.* = .{ .number = row.number, .node_id = row.node_id, .updated_at = row.updated_at };

    var batch = try parseHydrate(testing.allocator, .{ .bytes = captured_hydrate_batch, .refs = &refs, .viewer_login = "ctdio" });
    defer batch.deinit();
    try testing.expectEqual(25, batch.rows.len);
    try testing.expectEqual(0, batch.missing.len);
    // #99649: +759 -437, 4 files, REVIEW_REQUIRED, rollup PENDING.
    const first = batch.rows[0];
    try testing.expectEqual(99649, first.number);
    try testing.expectEqual(759, first.additions);
    try testing.expectEqual(437, first.deletions);
    try testing.expectEqual(4, first.changed_files);
    try testing.expectEqualStrings("REVIEW_REQUIRED", first.review_decision);
    try testing.expectEqual(parse.CiStatus.pending, first.ci);
    try testing.expectEqualStrings("2026-10-05T00:54:43Z", first.updated_at);
}

test "hydrate rows align with refs by position" {
    const refs = refsFor(&.{ 30, 10, 20 });
    var batch = try parseHydrate(testing.allocator, .{
        .bytes = hydrateWith(
            \\{"number":30,"updatedAt":"t3","additions":3},{"number":10,"updatedAt":"t1","additions":1},{"number":20,"updatedAt":"t2","additions":2}
        ),
        .refs = &refs,
        .viewer_login = "me",
    });
    defer batch.deinit();
    for (batch.rows, refs) |row, ref| try testing.expectEqual(ref.number, row.number);
    try testing.expectEqual(3, batch.rows[0].additions);
    try testing.expectEqualStrings("t2", batch.rows[2].updated_at);
}

test "null node becomes a missing CLOSED row for that ref" {
    const refs = [_]types.NodeRef{
        .{ .number = 99649, .node_id = "PR_kwDOBC3Cis8AAAABGeb4Rw", .updated_at = "2026-10-05T00:54:43Z" },
        .{ .number = 4242, .node_id = "PR_doesNotExist000", .updated_at = "2026-01-02T00:00:00Z" },
    };
    var batch = try parseHydrate(testing.allocator, .{ .bytes = captured_hydrate_partial_error, .refs = &refs, .viewer_login = "ctdio" });
    defer batch.deinit();
    try testing.expectEqual(1, batch.rows.len);
    try testing.expectEqual(99649, batch.rows[0].number);
    try testing.expectEqual(1, batch.missing.len);
    try testing.expectEqual(4242, batch.missing[0].number);
    try testing.expectEqual(types.PrState.closed, batch.missing[0].state);
    try testing.expectEqualStrings("2026-01-02T00:00:00Z", batch.missing[0].updated_at);
}

test "a null node next to a FORBIDDEN error is unresolved and the rest of the batch still parses" {
    const refs = refsFor(&.{ 1, 2 });
    var batch = try parseHydrate(testing.allocator, .{
        .bytes =
        \\{"data":{"nodes":[{"number":1,"updatedAt":"t","additions":777},null]},"errors":[{"type":"FORBIDDEN","path":["nodes",1],"message":"Resource not accessible by integration"}]}
        ,
        .refs = &refs,
        .viewer_login = "me",
    });
    defer batch.deinit();
    try testing.expectEqual(1, batch.rows.len);
    try testing.expectEqual(1, batch.rows[0].number);
    try testing.expectEqual(777, batch.rows[0].additions);
    try testing.expectEqual(0, batch.missing.len);
    try testing.expectEqual(1, batch.unresolved.len);
    try testing.expectEqual(2, batch.unresolved[0].number);
}

test "a null node with no error entry is unresolved" {
    const refs = refsFor(&.{ 1, 2 });
    var batch = try parseHydrate(testing.allocator, .{
        .bytes = hydrateWith("{\"number\":1,\"updatedAt\":\"t\"},null"),
        .refs = &refs,
        .viewer_login = "me",
    });
    defer batch.deinit();
    try testing.expectEqual(1, batch.rows.len);
    try testing.expectEqual(0, batch.missing.len);
    try testing.expectEqual(2, batch.unresolved[0].number);
}

test "a NOT_FOUND error for another slot does not close a null node" {
    const refs = refsFor(&.{ 1, 2 });
    var batch = try parseHydrate(testing.allocator, .{
        .bytes =
        \\{"data":{"nodes":[null,null]},"errors":[{"type":"NOT_FOUND","path":["nodes",0]},{"type":"FORBIDDEN","path":["nodes",1]}]}
        ,
        .refs = &refs,
        .viewer_login = "me",
    });
    defer batch.deinit();
    try testing.expectEqual(0, batch.rows.len);
    try testing.expectEqual(1, batch.missing.len);
    try testing.expectEqual(1, batch.missing[0].number);
    try testing.expectEqual(1, batch.unresolved.len);
    try testing.expectEqual(2, batch.unresolved[0].number);
}

test "a batch whose every node is unresolved returns every ref as unresolved" {
    const refs = refsFor(&.{ 1, 2 });
    var batch = try parseHydrate(testing.allocator, .{
        .bytes =
        \\{"data":{"nodes":[null,null]},"errors":[{"type":"FORBIDDEN","path":["nodes",0]},{"type":"FORBIDDEN","path":["nodes",1]}]}
        ,
        .refs = &refs,
        .viewer_login = "me",
    });
    defer batch.deinit();
    try testing.expectEqual(0, batch.rows.len);
    try testing.expectEqual(0, batch.missing.len);
    try testing.expectEqual(2, batch.unresolved.len);
    try testing.expectEqual(1, batch.unresolved[0].number);
    try testing.expectEqual(2, batch.unresolved[1].number);
}

test "an empty batch parses to nothing" {
    var batch = try parseHydrate(testing.allocator, .{ .bytes = hydrateWith(""), .refs = &.{}, .viewer_login = "me" });
    defer batch.deinit();
    try testing.expectEqual(0, batch.rows.len);
    try testing.expectEqual(0, batch.missing.len);
    try testing.expectEqual(0, batch.unresolved.len);
}

test "every null node with its own NOT_FOUND error is missing" {
    const refs = refsFor(&.{ 1, 2, 3 });
    var batch = try parseHydrate(testing.allocator, .{
        .bytes =
        \\{"data":{"nodes":[null,{"number":2,"updatedAt":"t"},null]},"errors":[{"type":"NOT_FOUND","path":["nodes",2]},{"type":"NOT_FOUND","path":["nodes",0]}]}
        ,
        .refs = &refs,
        .viewer_login = "me",
    });
    defer batch.deinit();
    try testing.expectEqual(1, batch.rows.len);
    try testing.expectEqual(2, batch.missing.len);
    try testing.expectEqual(1, batch.missing[0].number);
    try testing.expectEqual(3, batch.missing[1].number);
}

test "a node that is no longer a PullRequest counts as missing" {
    const refs = refsFor(&.{5});
    var batch = try parseHydrate(testing.allocator, .{ .bytes = hydrateWith("{}"), .refs = &refs, .viewer_login = "me" });
    defer batch.deinit();
    try testing.expectEqual(0, batch.rows.len);
    try testing.expectEqual(5, batch.missing[0].number);
}

test "hydrate node count different from refs is NodeCountMismatch" {
    const refs = refsFor(&.{ 1, 2 });
    try testing.expectError(error.NodeCountMismatch, parseHydrate(testing.allocator, .{
        .bytes = hydrateWith("{\"number\":1,\"updatedAt\":\"t\"}"),
        .refs = &refs,
        .viewer_login = "me",
    }));
}

test "User reviewers join into requested_users" {
    const refs = refsFor(&.{1});
    var batch = try parseHydrate(testing.allocator, .{
        .bytes = hydrateWith(
            \\{"number":1,"updatedAt":"t","reviewRequests":{"nodes":[
            \\{"requestedReviewer":{"__typename":"User","login":"alice"}},
            \\{"requestedReviewer":{"__typename":"User","login":"bob"}}]}}
        ),
        .refs = &refs,
        .viewer_login = "me",
    });
    defer batch.deinit();
    try testing.expectEqualStrings("alice\nbob", batch.rows[0].requested_users);
    try testing.expectEqualStrings("", batch.rows[0].requested_teams);
}

test "Team reviewer joins as lowercase org/slug into requested_teams" {
    const refs = refsFor(&.{1});
    var batch = try parseHydrate(testing.allocator, .{
        .bytes = hydrateWith(
            \\{"number":1,"updatedAt":"t","reviewRequests":{"nodes":[
            \\{"requestedReviewer":{"__typename":"Team","slug":"Next-Core","organization":{"login":"Vercel"}}}]}}
        ),
        .refs = &refs,
        .viewer_login = "me",
    });
    defer batch.deinit();
    try testing.expectEqualStrings("vercel/next-core", batch.rows[0].requested_teams);
}

test "null, Bot and Mannequin requested reviewers are skipped" {
    const refs = refsFor(&.{1});
    var batch = try parseHydrate(testing.allocator, .{
        .bytes = hydrateWith(
            \\{"number":1,"updatedAt":"t","reviewRequests":{"nodes":[
            \\{"requestedReviewer":null},
            \\{"requestedReviewer":{"__typename":"Bot","login":"dependabot"}},
            \\{"requestedReviewer":{"__typename":"Mannequin","login":"old"}},
            \\{"requestedReviewer":{"__typename":"User","login":"carol"}}]}}
        ),
        .refs = &refs,
        .viewer_login = "me",
    });
    defer batch.deinit();
    try testing.expectEqualStrings("carol", batch.rows[0].requested_users);
    try testing.expectEqualStrings("", batch.rows[0].requested_teams);
}

test "my_review_state and oid come from the viewer's opinionated review, matched case-insensitively" {
    const refs = refsFor(&.{1});
    var batch = try parseHydrate(testing.allocator, .{
        .bytes = hydrateWith(
            \\{"number":1,"updatedAt":"t","latestOpinionatedReviews":{"nodes":[
            \\{"author":{"login":"someone"},"state":"CHANGES_REQUESTED","commit":{"oid":"1111"}},
            \\{"author":{"login":"ctdio"},"state":"APPROVED","commit":{"oid":"2222"}}]}}
        ),
        .refs = &refs,
        .viewer_login = "CTDio",
    });
    defer batch.deinit();
    try testing.expectEqualStrings("APPROVED", batch.rows[0].my_review_state);
    try testing.expectEqualStrings("2222", batch.rows[0].my_review_oid);
}

test "no review by viewer leaves my_review_state empty" {
    const refs = refsFor(&.{1});
    var batch = try parseHydrate(testing.allocator, .{
        .bytes = hydrateWith(
            \\{"number":1,"updatedAt":"t","latestOpinionatedReviews":{"nodes":[
            \\{"author":{"login":"someone"},"state":"APPROVED","commit":{"oid":"1111"}},
            \\{"author":null,"state":"APPROVED","commit":{"oid":"3333"}}]}}
        ),
        .refs = &refs,
        .viewer_login = "ctdio",
    });
    defer batch.deinit();
    try testing.expectEqualStrings("", batch.rows[0].my_review_state);
    try testing.expectEqualStrings("", batch.rows[0].my_review_oid);
}

test "null reviewDecision maps to empty string" {
    const refs = refsFor(&.{1});
    var batch = try parseHydrate(testing.allocator, .{
        .bytes = hydrateWith("{\"number\":1,\"updatedAt\":\"t\",\"reviewDecision\":null}"),
        .refs = &refs,
        .viewer_login = "me",
    });
    defer batch.deinit();
    try testing.expectEqualStrings("", batch.rows[0].review_decision);
}

test "ciFromRollup maps every rollup state" {
    const cases = [_]struct { state: ?[]const u8, want: parse.CiStatus }{
        .{ .state = "SUCCESS", .want = .success },
        .{ .state = "FAILURE", .want = .failure },
        .{ .state = "ERROR", .want = .failure },
        .{ .state = "PENDING", .want = .pending },
        .{ .state = "EXPECTED", .want = .pending },
        .{ .state = null, .want = .none },
        .{ .state = "SOMETHING_NEW", .want = .none },
    };
    for (cases) |case| try testing.expectEqual(case.want, ciFromRollup(case.state));
}

test "empty commits.nodes and a null rollup both give ci none" {
    const refs = refsFor(&.{ 1, 2 });
    var batch = try parseHydrate(testing.allocator, .{
        .bytes = hydrateWith(
            \\{"number":1,"updatedAt":"t","commits":{"nodes":[]}},
            \\{"number":2,"updatedAt":"t","commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}}
        ),
        .refs = &refs,
        .viewer_login = "me",
    });
    defer batch.deinit();
    try testing.expectEqual(parse.CiStatus.none, batch.rows[0].ci);
    try testing.expectEqual(parse.CiStatus.none, batch.rows[1].ci);
}

test "viewer teams join as lowercase owner/slug" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const teams = try parseViewerTeams(arena.allocator(), .{
        .bytes =
        \\{"data":{"viewer":{"organization":{"teams":{"nodes":[{"slug":"Core"},{"slug":"infra"}]}}}}}
        ,
        .owner = "Acme",
    });
    try testing.expectEqual(2, teams.len);
    try testing.expectEqualStrings("acme/core", teams[0]);
    try testing.expectEqualStrings("acme/infra", teams[1]);
}

test "null organization (user-owned repo) yields empty teams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const teams = try parseViewerTeams(arena.allocator(), .{ .bytes = captured_teams_null_org, .owner = "ctdio" });
    try testing.expectEqual(0, teams.len);
}
