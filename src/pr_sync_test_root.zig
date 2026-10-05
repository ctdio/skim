//! Test root for the PR sync engine (src/pr/sync/). Rooted at `src/` so the
//! sync files can reach `../db/` and `../github.zig`. Its own step because it
//! links SQLite and carries the `pr_sync_options` module (the fake `gh` path).

const std = @import("std");

pub const queries = @import("pr/sync/queries.zig");
pub const sync_parse = @import("pr/sync/sync_parse.zig");
pub const planner = @import("pr/sync/planner.zig");
pub const sync = @import("pr/sync/sync.zig");
pub const sync_test = @import("pr/sync/sync_test.zig");
pub const fixtures = @import("pr/sync/fixtures.zig");
pub const test_support = @import("pr/sync/test_support.zig");
pub const scenario = @import("pr/sync/scenario.zig");

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;

const QueryCopy = struct { name: []const u8, copy: []const u8, query: []const u8 };

const query_copies = [_]QueryCopy{
    .{ .name = "index", .copy = @embedFile("sync_graphql_index"), .query = queries.index_query },
    .{ .name = "closed", .copy = @embedFile("sync_graphql_closed"), .query = queries.closed_query },
    .{ .name = "reconcile", .copy = @embedFile("sync_graphql_reconcile"), .query = queries.reconcile_query },
    .{ .name = "hydrate", .copy = @embedFile("sync_graphql_hydrate"), .query = queries.hydrate_query },
    .{ .name = "teams", .copy = @embedFile("sync_graphql_teams"), .query = queries.teams_query },
};

test "queries match scripts/test-infra/pr-sidebar/sync copies" {
    for (query_copies) |pair| {
        try testing.expectEqualStrings(std.mem.trimEnd(u8, pair.copy, "\n"), pair.query);
    }
}

test "every sync query is a named SkimSync operation" {
    for (query_copies) |pair| {
        try testing.expect(std.mem.startsWith(u8, pair.query, "query SkimSync"));
    }
}

test "page size constants match the literal first: values" {
    try expectFirst(queries.index_query, queries.index_page_size);
    try expectFirst(queries.closed_query, queries.closed_page_size);
    try expectFirst(queries.reconcile_query, queries.reconcile_page_size);
    try testing.expectEqual(25, queries.hydrate_batch_size);
}

fn expectFirst(query: []const u8, page_size: u32) !void {
    const at = std.mem.indexOf(u8, query, "pullRequests(states: ") orelse return error.TestUnexpectedResult;
    const line_end = std.mem.indexOfScalarPos(u8, query, at, '\n') orelse query.len;
    var first_buf: [32]u8 = undefined;
    const first = try std.fmt.bufPrint(&first_buf, "first: {d},", .{page_size});
    try testing.expect(std.mem.indexOf(u8, query[at..line_end], first) != null);
}
