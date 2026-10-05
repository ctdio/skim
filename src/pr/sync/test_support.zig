//! Test-only helpers for the sync tests: temp directories, the fake `gh`
//! path, and scenario setup. This is the only file that imports the
//! `pr_sync_options` build module, so `github.zig` stays importable by every
//! other test root. Reached only through `pr_sync_test_root.zig`.
//!
//! Also holds the `github.runGraphql` subprocess tests, which need the fake.

const std = @import("std");
const skim_io = @import("skim_io");
const pr_sync_options = @import("pr_sync_options");
const github = @import("../github.zig");
const queries = @import("queries.zig");
const scenario = @import("scenario.zig");

pub const ScenarioFile = scenario.File;

pub const ScenarioParams = struct {
    root: []const u8,
    step: u32,
    files: []const ScenarioFile,
    sleep_ms: u32 = 0,
};

/// A temp directory under `.zig-cache/tmp/` with its absolute path, which
/// the fake `gh` launcher and `Store.open` both need.
pub const TmpRoot = struct {
    tmp: std.testing.TmpDir,
    /// Absolute path of the directory.
    path: []u8,

    pub fn init() !TmpRoot {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const relative = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        defer std.testing.allocator.free(relative);
        return .{ .tmp = tmp, .path = try skim_io.absolutePathAlloc(std.testing.allocator, relative) };
    }

    pub fn deinit(self: *TmpRoot) void {
        std.testing.allocator.free(self.path);
        self.tmp.cleanup();
    }
};

/// A `scenario.World` in its own `TmpRoot`, on the testing allocator.
pub const TestWorld = struct {
    tmp: TmpRoot,
    world: scenario.World,

    pub fn init() !TestWorld {
        var tmp = try TmpRoot.init();
        errdefer tmp.deinit();
        const world = try scenario.World.init(.{ .allocator = std.testing.allocator, .root = tmp.path, .fake_gh = fakeGhPath() });
        return .{ .tmp = tmp, .world = world };
    }

    pub fn deinit(self: *TestWorld) void {
        self.world.deinit();
        self.tmp.deinit();
    }
};

/// `<tmp>/prs.db`, absolute. Caller frees.
pub fn tmpDbPath(allocator: std.mem.Allocator, root: *const TmpRoot) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/prs.db", .{root.path});
}

/// Absolute path of scripts/test-infra/pr-sidebar/sync/fake-gh.
pub fn fakeGhPath() []const u8 {
    return pr_sync_options.fake_gh_path;
}

/// Write `params.files` under `<root>/step-<step>/` and (re)write the `<root>/gh`
/// launcher with `params.sleep_ms`. Returns the launcher path (caller frees),
/// to pass as `gh_bin`.
pub fn writeScenario(allocator: std.mem.Allocator, params: ScenarioParams) ![]u8 {
    try scenario.writeFiles(allocator, .{ .root = params.root, .step = params.step, .files = params.files });
    return scenario.writeLauncher(allocator, .{ .root = params.root, .fake_gh = fakeGhPath(), .sleep_ms = params.sleep_ms });
}

pub fn readCalls(allocator: std.mem.Allocator, root: []const u8) !scenario.Calls {
    return scenario.readCalls(allocator, root);
}

// =============================================================================
// Tests: github.runGraphql against the fake gh
// =============================================================================

const testing = std.testing;

const auth_failure_stderr = @embedFile("sync_fixture_auth_failure_stderr");
const repo_vars = [_]github.KV{ .{ .key = "owner", .value = "acme" }, .{ .key = "name", .value = "widgets" } };
const ok_index_body = "{\"data\":{\"repository\":null}}";

fn expectOk(fetch: github.GhFetch) ![]u8 {
    return switch (fetch) {
        .ok => |bytes| bytes,
        .failed => |kind| {
            std.debug.print("expected .ok, got .failed = {s}\n", .{@tagName(kind)});
            return error.TestUnexpectedResult;
        },
    };
}

fn expectFailed(expected: github.GhErrorKind, fetch: github.GhFetch) !void {
    switch (fetch) {
        .ok => |bytes| {
            defer testing.allocator.free(bytes);
            std.debug.print("expected .failed = {s}, got .ok: {s}\n", .{ @tagName(expected), bytes });
            return error.TestUnexpectedResult;
        },
        .failed => |kind| try testing.expectEqual(expected, kind),
    }
}

test "runGraphql uses gh_bin as argv[0]" {
    var root = try TmpRoot.init();
    defer root.deinit();
    const gh = try writeScenario(testing.allocator, .{
        .root = root.path,
        .step = 1,
        .files = &.{.{ .path = "SkimSyncIndex-first.json", .bytes = ok_index_body }},
    });
    defer testing.allocator.free(gh);

    const body = try expectOk(try github.runGraphql(testing.allocator, .{ .query = queries.index_query, .string_vars = &repo_vars, .gh_bin = gh }));
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(ok_index_body, body);

    var calls = try readCalls(testing.allocator, root.path);
    defer calls.deinit();
    try testing.expectEqual(1, calls.items.len);
    try testing.expectEqualStrings("SkimSyncIndex", calls.items[0].op);
    try testing.expectEqualStrings("first", calls.items[0].key);
}

test "runGraphql passes repeated ids[] as -f flags" {
    var root = try TmpRoot.init();
    defer root.deinit();
    const gh = try writeScenario(testing.allocator, .{
        .root = root.path,
        .step = 1,
        .files = &.{
            .{ .path = "nodes/A.json", .bytes = "{\"number\":1}" },
            .{ .path = "nodes/B.json", .bytes = "{\"number\":2}" },
            .{ .path = "nodes/C.json", .bytes = "{\"number\":3}" },
        },
    });
    defer testing.allocator.free(gh);

    const ids = [_]github.KV{ .{ .key = "ids[]", .value = "A" }, .{ .key = "ids[]", .value = "B" }, .{ .key = "ids[]", .value = "C" } };
    const body = try expectOk(try github.runGraphql(testing.allocator, .{ .query = queries.hydrate_query, .string_vars = &ids, .gh_bin = gh }));
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"number\":3") != null);

    var calls = try readCalls(testing.allocator, root.path);
    defer calls.deinit();
    try testing.expectEqualStrings("SkimSyncHydrate", calls.items[0].op);
    try testing.expectEqual(3, calls.items[0].ids.len);
    try testing.expectEqualStrings("A", calls.items[0].ids[0]);
    try testing.expectEqualStrings("C", calls.items[0].ids[2]);
}

test "runGraphql passes the cursor through -f" {
    var root = try TmpRoot.init();
    defer root.deinit();
    const gh = try writeScenario(testing.allocator, .{
        .root = root.path,
        .step = 1,
        .files = &.{.{ .path = "SkimSyncIndex-c_1-..json", .bytes = ok_index_body }},
    });
    defer testing.allocator.free(gh);

    const vars = repo_vars ++ [_]github.KV{.{ .key = "cursor", .value = "c/1+=" }};
    const body = try expectOk(try github.runGraphql(testing.allocator, .{ .query = queries.index_query, .string_vars = &vars, .gh_bin = gh }));
    testing.allocator.free(body);
}

test "runGraphql with a missing gh_bin is not_installed" {
    try expectFailed(.not_installed, try github.runGraphql(testing.allocator, .{ .query = queries.index_query, .gh_bin = "/nonexistent/gh" }));
}

test "runGraphql classifies the fake's stderr" {
    var root = try TmpRoot.init();
    defer root.deinit();
    const gh = try writeScenario(testing.allocator, .{
        .root = root.path,
        .step = 1,
        .files = &.{
            .{ .path = "fail-SkimSyncIndex", .bytes = auth_failure_stderr },
            .{ .path = "fail-SkimSyncIndex.code", .bytes = "4\n" },
        },
    });
    defer testing.allocator.free(gh);

    try expectFailed(.not_authenticated, try github.runGraphql(testing.allocator, .{ .query = queries.index_query, .string_vars = &repo_vars, .gh_bin = gh }));
}

test "runGraphql with allow_error_body keeps a partial-error body on exit 1" {
    var root = try TmpRoot.init();
    defer root.deinit();
    const gh = try writeScenario(testing.allocator, .{
        .root = root.path,
        .step = 1,
        .files = &.{.{ .path = "nodes/A.json", .bytes = "{\"number\":1}" }},
    });
    defer testing.allocator.free(gh);

    const ids = [_]github.KV{ .{ .key = "ids[]", .value = "A" }, .{ .key = "ids[]", .value = "GONE" } };
    const body = try expectOk(try github.runGraphql(testing.allocator, .{
        .query = queries.hydrate_query,
        .string_vars = &ids,
        .gh_bin = gh,
        .allow_error_body = true,
    }));
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"errors\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"number\":1") != null);
}

test "runGraphql without allow_error_body classifies exit 1 as failed" {
    var root = try TmpRoot.init();
    defer root.deinit();
    const gh = try writeScenario(testing.allocator, .{
        .root = root.path,
        .step = 1,
        .files = &.{.{ .path = "nodes/A.json", .bytes = "{\"number\":1}" }},
    });
    defer testing.allocator.free(gh);

    const ids = [_]github.KV{ .{ .key = "ids[]", .value = "A" }, .{ .key = "ids[]", .value = "GONE" } };
    try expectFailed(.not_found, try github.runGraphql(testing.allocator, .{ .query = queries.hydrate_query, .string_vars = &ids, .gh_bin = gh }));
}

test "runGraphql idle timeout maps to network" {
    var root = try TmpRoot.init();
    defer root.deinit();
    const gh = try writeScenario(testing.allocator, .{
        .root = root.path,
        .step = 1,
        .files = &.{.{ .path = "SkimSyncIndex-first.json", .bytes = ok_index_body }},
        .sleep_ms = 2000,
    });
    defer testing.allocator.free(gh);

    var timer = try skim_io.Timer.start();
    try expectFailed(.network, try github.runGraphql(testing.allocator, .{
        .query = queries.index_query,
        .string_vars = &repo_vars,
        .gh_bin = gh,
        .idle_timeout_ms = 200,
    }));
    try testing.expect(timer.read() < 1500 * std.time.ns_per_ms);
}

test "runGraphql with allow_error_body still fails when the body has no data" {
    var root = try TmpRoot.init();
    defer root.deinit();
    const gh = try writeScenario(testing.allocator, .{
        .root = root.path,
        .step = 1,
        .files = &.{
            .{ .path = "fail-SkimSyncIndex", .bytes = "gh: Something went wrong\n" },
            .{ .path = "fail-SkimSyncIndex.stdout", .bytes = "{\"errors\":[{\"message\":\"x\"}]}" },
        },
    });
    defer testing.allocator.free(gh);

    try expectFailed(.other, try github.runGraphql(testing.allocator, .{
        .query = queries.index_query,
        .string_vars = &repo_vars,
        .gh_bin = gh,
        .allow_error_body = true,
    }));
}

test "runGraphql with a gh_bin that cannot be executed is other, not a Zig error" {
    var root = try TmpRoot.init();
    defer root.deinit();
    try expectFailed(.other, try github.runGraphql(testing.allocator, .{ .query = queries.index_query, .string_vars = &repo_vars, .gh_bin = root.path }));
}

test "fake gh exits 98 with a message for a query without a SkimSync operation" {
    var root = try TmpRoot.init();
    defer root.deinit();
    const gh = try writeScenario(testing.allocator, .{ .root = root.path, .step = 1, .files = &.{} });
    defer testing.allocator.free(gh);

    const result = try std.process.run(testing.allocator, skim_io.get(), .{ .argv = &.{ gh, "api", "graphql", "-f", "query={viewer{login}}" } });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 98 }, result.term);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "no SkimSync operation") != null);
}
