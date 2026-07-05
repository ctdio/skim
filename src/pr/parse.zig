//! Pure parsing of GitHub PR JSON (as emitted by `gh pr list --json ...`) into
//! domain `PullRequest` values. No IO — bytes in, owned data out — so it is
//! trivially unit-testable against captured `gh` payloads.

const std = @import("std");
const json_fields = @import("json.zig");

const strField = json_fields.strField;
const boolField = json_fields.boolField;

pub const CiStatus = enum {
    none,
    pending,
    success,
    failure,
};

pub const PullRequest = struct {
    number: u32,
    title: []const u8,
    author: []const u8,
    head_ref: []const u8,
    base_ref: []const u8,
    is_draft: bool,
    updated_at: []const u8,
    url: []const u8,
    ci: CiStatus,
};

/// Owns the parsed PRs and the arena backing all of their strings. Free with
/// `deinit`.
pub const PullRequestList = struct {
    arena: std.heap.ArenaAllocator,
    items: []PullRequest,

    pub fn deinit(self: *PullRequestList) void {
        self.arena.deinit();
    }
};

/// Parse the JSON array produced by `gh pr list --json number,title,author,
/// headRefName,baseRefName,isDraft,updatedAt,url,statusCheckRollup`.
pub fn parse(allocator: std.mem.Allocator, json_bytes: []const u8) !PullRequestList {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .array) return error.InvalidPayload;
    const entries = parsed.value.array.items;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    var list = try arena_alloc.alloc(PullRequest, entries.len);
    for (entries, 0..) |entry, i| {
        list[i] = try parsePullRequest(arena_alloc, entry);
    }

    return .{ .arena = arena, .items = list };
}

fn parsePullRequest(allocator: std.mem.Allocator, value: std.json.Value) !PullRequest {
    if (value != .object) return error.InvalidPayload;
    const obj = value.object;

    return .{
        .number = try numberField(obj, "number"),
        .title = try stringField(allocator, obj, "title"),
        .author = try authorLogin(allocator, obj),
        .head_ref = try stringField(allocator, obj, "headRefName"),
        .base_ref = try stringField(allocator, obj, "baseRefName"),
        .is_draft = boolField(obj, "isDraft"),
        .updated_at = try stringField(allocator, obj, "updatedAt"),
        .url = try stringField(allocator, obj, "url"),
        .ci = rollupStatus(obj),
    };
}

fn numberField(obj: std.json.ObjectMap, key: []const u8) !u32 {
    const v = obj.get(key) orelse return error.MissingField;
    if (v != .integer) return error.InvalidField;
    return std.math.cast(u32, v.integer) orelse error.InvalidField;
}

fn stringField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = obj.get(key) orelse return allocator.dupe(u8, "");
    if (v != .string) return allocator.dupe(u8, "");
    return allocator.dupe(u8, v.string);
}

fn authorLogin(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]const u8 {
    const author = obj.get("author") orelse return allocator.dupe(u8, "");
    if (author != .object) return allocator.dupe(u8, "");
    const login = author.object.get("login") orelse return allocator.dupe(u8, "");
    if (login != .string) return allocator.dupe(u8, "");
    return allocator.dupe(u8, login.string);
}

/// Roll the `statusCheckRollup` array up to a single status: any failing check
/// wins, then any pending check, then all-success, else none.
fn rollupStatus(obj: std.json.ObjectMap) CiStatus {
    const rollup = obj.get("statusCheckRollup") orelse return .none;
    if (rollup != .array) return .none;
    const checks = rollup.array.items;
    if (checks.len == 0) return .none;

    var any_pending = false;
    var any_success = false;
    for (checks) |check| {
        switch (checkStatus(check)) {
            .failure => return .failure,
            .pending => any_pending = true,
            .success => any_success = true,
            .none => {},
        }
    }
    if (any_pending) return .pending;
    if (any_success) return .success;
    return .none;
}

/// Classify a single rollup entry. CheckRun entries carry `status` +
/// `conclusion`; StatusContext entries carry `state`.
fn checkStatus(check: std.json.Value) CiStatus {
    if (check != .object) return .none;
    const obj = check.object;

    if (strField(obj, "state")) |state| {
        if (eqAny(state, &.{ "FAILURE", "ERROR" })) return .failure;
        if (eqAny(state, &.{ "PENDING", "EXPECTED" })) return .pending;
        if (eqAny(state, &.{"SUCCESS"})) return .success;
    }

    if (strField(obj, "status")) |status| {
        if (!eqAny(status, &.{"COMPLETED"})) return .pending;
    }

    if (strField(obj, "conclusion")) |conclusion| {
        if (eqAny(conclusion, &.{ "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE" })) return .failure;
        if (eqAny(conclusion, &.{ "SUCCESS", "NEUTRAL", "SKIPPED" })) return .success;
    }

    return .none;
}

fn eqAny(value: []const u8, candidates: []const []const u8) bool {
    for (candidates) |c| {
        if (std.mem.eql(u8, value, c)) return true;
    }
    return false;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "parse: empty array yields no PRs" {
    var list = try parse(testing.allocator, "[]");
    defer list.deinit();
    try testing.expectEqual(@as(usize, 0), list.items.len);
}

test "parse: extracts core fields and author login" {
    const json =
        \\[{
        \\  "number": 42,
        \\  "title": "Add widget",
        \\  "author": {"login": "octocat", "is_bot": false},
        \\  "headRefName": "feature/widget",
        \\  "baseRefName": "main",
        \\  "isDraft": true,
        \\  "updatedAt": "2026-06-23T14:03:09Z",
        \\  "url": "https://github.com/o/r/pull/42",
        \\  "statusCheckRollup": []
        \\}]
    ;
    var list = try parse(testing.allocator, json);
    defer list.deinit();

    try testing.expectEqual(@as(usize, 1), list.items.len);
    const pr = list.items[0];
    try testing.expectEqual(@as(u32, 42), pr.number);
    try testing.expectEqualStrings("Add widget", pr.title);
    try testing.expectEqualStrings("octocat", pr.author);
    try testing.expectEqualStrings("feature/widget", pr.head_ref);
    try testing.expectEqualStrings("main", pr.base_ref);
    try testing.expect(pr.is_draft);
    try testing.expectEqualStrings("https://github.com/o/r/pull/42", pr.url);
    try testing.expectEqual(CiStatus.none, pr.ci);
}

test "ci rollup: all completed-success checks roll up to success" {
    const json =
        \\[{"number":1,"title":"t","author":{"login":"a"},"headRefName":"h","baseRefName":"b","isDraft":false,"updatedAt":"x","url":"u",
        \\  "statusCheckRollup":[
        \\    {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},
        \\    {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SKIPPED"}
        \\  ]}]
    ;
    var list = try parse(testing.allocator, json);
    defer list.deinit();
    try testing.expectEqual(CiStatus.success, list.items[0].ci);
}

test "ci rollup: any failing check makes the whole rollup failure" {
    const json =
        \\[{"number":1,"title":"t","author":{"login":"a"},"headRefName":"h","baseRefName":"b","isDraft":false,"updatedAt":"x","url":"u",
        \\  "statusCheckRollup":[
        \\    {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},
        \\    {"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}
        \\  ]}]
    ;
    var list = try parse(testing.allocator, json);
    defer list.deinit();
    try testing.expectEqual(CiStatus.failure, list.items[0].ci);
}

test "ci rollup: in-progress check with no failures is pending" {
    const json =
        \\[{"number":1,"title":"t","author":{"login":"a"},"headRefName":"h","baseRefName":"b","isDraft":false,"updatedAt":"x","url":"u",
        \\  "statusCheckRollup":[
        \\    {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},
        \\    {"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":null}
        \\  ]}]
    ;
    var list = try parse(testing.allocator, json);
    defer list.deinit();
    try testing.expectEqual(CiStatus.pending, list.items[0].ci);
}

test "ci rollup: legacy StatusContext state is honored" {
    const json =
        \\[{"number":1,"title":"t","author":{"login":"a"},"headRefName":"h","baseRefName":"b","isDraft":false,"updatedAt":"x","url":"u",
        \\  "statusCheckRollup":[
        \\    {"__typename":"StatusContext","state":"ERROR"}
        \\  ]}]
    ;
    var list = try parse(testing.allocator, json);
    defer list.deinit();
    try testing.expectEqual(CiStatus.failure, list.items[0].ci);
}

test "parse: missing author object degrades to empty string" {
    const json =
        \\[{"number":1,"title":"t","headRefName":"h","baseRefName":"b","isDraft":false,"updatedAt":"x","url":"u"}]
    ;
    var list = try parse(testing.allocator, json);
    defer list.deinit();
    try testing.expectEqualStrings("", list.items[0].author);
    try testing.expectEqual(CiStatus.none, list.items[0].ci);
}
