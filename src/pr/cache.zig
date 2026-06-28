//! On-disk cache of the raw `gh pr list` JSON, keyed by repo identity. Lets the
//! picker paint the last-known list instantly while a fresh fetch runs in the
//! background (stale-while-revalidate), so opening `skim pr` no longer waits on
//! a GitHub round trip. The cache stores exactly what `gh` emitted, so
//! `parse.zig` stays the one and only parser.

const std = @import("std");

pub const subdir = ".skim/cache";

const max_cache_bytes = 16 * 1024 * 1024;

/// Stable cache key for the repo in the process cwd: the origin remote URL when
/// present, else the repo root path. Returns null when neither can be resolved
/// (e.g. not inside a git repo). Caller owns the result.
pub fn keyFor(allocator: std.mem.Allocator) ?[]u8 {
    if (gitLine(allocator, &.{ "git", "config", "--get", "remote.origin.url" })) |url| return url;
    return gitLine(allocator, &.{ "git", "rev-parse", "--show-toplevel" });
}

/// Read cached PR JSON for `key`. Returns null when the cache is absent or
/// unreadable. Caller owns the returned bytes.
pub fn read(allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    const path = try pathFor(allocator, key);
    defer allocator.free(path);
    return readFile(allocator, path);
}

/// Persist `json_bytes` as the cache for `key`, creating the cache directory on
/// demand. Best-effort: callers typically ignore the error.
pub fn write(allocator: std.mem.Allocator, key: []const u8, json_bytes: []const u8) !void {
    const path = try pathFor(allocator, key);
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |parent| {
        try std.fs.cwd().makePath(parent);
    }
    try writeFile(path, json_bytes);
}

// =============================================================================
// Helpers
// =============================================================================

/// Run a git command and return its single line of stdout (trimmed), or null on
/// any failure or empty output. Caller owns the result.
fn gitLine(allocator: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const ok = switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!ok) return null;

    const trimmed = std.mem.trimRight(u8, result.stdout, " \r\n");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}

fn pathFor(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    const name = try fileName(allocator, key);
    defer allocator.free(name);
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ home, subdir, name });
}

fn fileName(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const hash = std.hash.Wyhash.hash(0, key);
    return std.fmt.allocPrint(allocator, "prs-{x}.json", .{hash});
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    return file.readToEndAlloc(allocator, max_cache_bytes) catch null;
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "fileName is stable for the same key" {
    const a = try fileName(testing.allocator, "git@github.com:o/r.git");
    defer testing.allocator.free(a);
    const b = try fileName(testing.allocator, "git@github.com:o/r.git");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
}

test "fileName differs for different keys" {
    const a = try fileName(testing.allocator, "git@github.com:o/one.git");
    defer testing.allocator.free(a);
    const b = try fileName(testing.allocator, "git@github.com:o/two.git");
    defer testing.allocator.free(b);
    try testing.expect(!std.mem.eql(u8, a, b));
}

test "pathFor lands under ~/.skim/cache with the hashed name" {
    const key = "git@github.com:o/r.git";
    const path = try pathFor(testing.allocator, key);
    defer testing.allocator.free(path);
    const name = try fileName(testing.allocator, key);
    defer testing.allocator.free(name);

    try testing.expect(std.mem.indexOf(u8, path, "/.skim/cache/") != null);
    try testing.expect(std.mem.endsWith(u8, path, name));
}

test "writeFile then readFile round-trips bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/prs.json", .{dir});
    defer testing.allocator.free(path);

    try writeFile(path, "[{\"number\":1}]");
    const got = (try readFile(testing.allocator, path)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("[{\"number\":1}]", got);
}

test "readFile returns null for a missing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/nope.json", .{dir});
    defer testing.allocator.free(path);

    try testing.expectEqual(@as(?[]u8, null), try readFile(testing.allocator, path));
}
