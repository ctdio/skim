//! Fetch planning (pure): which refspecs to send to `git fetch`, and parsers
//! for the git output the prefetch worker reacts to. Every child that produces
//! the text parsed here runs with `LC_ALL=C`.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Oids `git cat-file --batch-check` reported missing. Keys borrow from the
/// parsed output.
pub const MissingSet = std.StringHashMapUnmanaged(void);

/// argv prefix of every prefetch fetch. `--no-write-fetch-head` leaves the
/// user's FETCH_HEAD alone; `--no-tags` keeps a PR fetch from pulling every tag;
/// `--no-auto-maintenance` keeps a background fetch from starting a gc. The
/// low-speed limit aborts an HTTP transfer that stalls below 1 KB/s for 30s.
pub const fetch_flags = [_][]const u8{
    "git",                   "-c",      "http.lowSpeedLimit=1000", "-c",                    "http.lowSpeedTime=30",
    "fetch",                 "--quiet", "--no-tags",               "--no-write-fetch-head", "--no-recurse-submodules",
    "--no-auto-maintenance", "origin",
};

const missing_ref_prefix = "fatal: couldn't find remote ref ";
const locked_ref_prefix = "error: cannot lock ref '";

/// 40 lowercase hex chars (SHA-1; GitHub has no SHA-256 repos).
pub fn isOid(text: []const u8) bool {
    if (text.len != 40) return false;
    for (text) |c| {
        switch (c) {
            '0'...'9', 'a'...'f' => {},
            else => return false,
        }
    }
    return true;
}

pub fn parseOid(text: []const u8) ?[40]u8 {
    if (!isOid(text)) return null;
    return text[0..40].*;
}

/// Oids that `git cat-file --batch-check` reported as `<oid> missing`.
/// Caller deinits the set; keys borrow from `output`.
pub fn parseBatchCheck(allocator: Allocator, output: []const u8) !MissingSet {
    var missing: MissingSet = .empty;
    errdefer missing.deinit(allocator);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        if (!std.mem.eql(u8, line[space + 1 ..], "missing")) continue;
        try missing.put(allocator, line[0..space], {});
    }
    return missing;
}

/// `fetch_flags ++ refspecs`, refspecs de-duplicated, order preserved.
/// Caller frees the outer slice only (strings are borrowed).
pub fn buildFetchArgv(allocator: Allocator, refspecs: []const []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = try .initCapacity(allocator, fetch_flags.len + refspecs.len);
    errdefer argv.deinit(allocator);
    argv.appendSliceAssumeCapacity(&fetch_flags);
    for (refspecs, 0..) |spec, i| {
        const seen = for (refspecs[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier, spec)) break true;
        } else false;
        if (!seen) argv.appendAssumeCapacity(spec);
    }
    return argv.toOwnedSlice(allocator);
}

/// `fatal: couldn't find remote ref refs/pull/98/head` → "refs/pull/98/head".
/// git names only the first missing ref of a batch. Requires LC_ALL=C on the
/// child. Null for any other failure.
pub fn missingRemoteRef(stderr: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (!std.mem.startsWith(u8, line, missing_ref_prefix)) continue;
        const ref = std.mem.trim(u8, line[missing_ref_prefix.len..], " ");
        if (ref.len > 0) return ref;
    }
    return null;
}

/// Remove every refspec whose source (text between an optional leading '+'
/// and ':') equals `remote_ref`. Returns the new length (in-place compaction).
pub fn dropRefspec(refspecs: [][]const u8, remote_ref: []const u8) usize {
    var kept: usize = 0;
    for (refspecs) |spec| {
        if (std.mem.eql(u8, refspecSource(spec), remote_ref)) continue;
        refspecs[kept] = spec;
        kept += 1;
    }
    return kept;
}

/// Remove every refspec whose destination git reported as
/// `error: cannot lock ref '<dest>'` (a stale remote-tracking ref in the way of
/// a directory, e.g. `origin/nest` blocking `origin/nest/inner`). git still
/// updates the other refs and keeps the fetched objects, but exits non-zero.
/// A lock held by another git process ("File exists") is not a conflict and
/// keeps its refspec; see `refLockHeld`. Returns the new length (in-place
/// compaction). Requires LC_ALL=C.
pub fn dropLockedRefspecs(refspecs: [][]const u8, stderr: []const u8) usize {
    var kept: usize = 0;
    for (refspecs) |spec| {
        if (isLocked(stderr, refspecDestination(spec))) continue;
        refspecs[kept] = spec;
        kept += 1;
    }
    return kept;
}

/// True when a ref lock failed because another git process holds the
/// `.lock` file ("Unable to create '...lock': File exists"). That is
/// transient contention, so the fetch counts as failed rather than dropping
/// the refspec the way a permanent directory/file conflict does.
pub fn refLockHeld(stderr: []const u8) bool {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        if (isHeldLockLine(std.mem.trim(u8, line, " \r\t"))) return true;
    }
    return false;
}

fn isLocked(stderr: []const u8, destination: []const u8) bool {
    if (destination.len == 0) return false;
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (!std.mem.startsWith(u8, line, locked_ref_prefix) or isHeldLockLine(line)) continue;
        const rest = line[locked_ref_prefix.len..];
        const quote = std.mem.indexOfScalar(u8, rest, '\'') orelse continue;
        if (std.mem.eql(u8, rest[0..quote], destination)) return true;
    }
    return false;
}

fn isHeldLockLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, locked_ref_prefix) and std.mem.indexOf(u8, line, "File exists") != null;
}

fn refspecSource(spec: []const u8) []const u8 {
    const unforced = if (std.mem.startsWith(u8, spec, "+")) spec[1..] else spec;
    const colon = std.mem.indexOfScalar(u8, unforced, ':') orelse return unforced;
    return unforced[0..colon];
}

fn refspecDestination(spec: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return "";
    return spec[colon + 1 ..];
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const oid_a = "a" ** 40;
const oid_b = "b" ** 40;
const oid_c = "c" ** 40;

test "isOid accepts 40 lowercase hex" {
    try testing.expect(isOid("0123456789abcdef0123456789abcdef01234567"));
}

test "isOid rejects short, uppercase, 64-char and non-hex" {
    try testing.expect(!isOid(""));
    try testing.expect(!isOid("a" ** 39));
    try testing.expect(!isOid("A" ** 40));
    try testing.expect(!isOid("a" ** 64));
    try testing.expect(!isOid("g" ** 40));
    try testing.expect(!isOid("-" ++ "a" ** 39));
}

test "parseOid copies a valid oid and rejects anything else" {
    try testing.expectEqualStrings(oid_a, &(parseOid(oid_a).?));
    try testing.expectEqual(@as(?[40]u8, null), parseOid("not an oid"));
}

test "parseBatchCheck collects only missing oids" {
    var missing = try parseBatchCheck(testing.allocator, oid_a ++ " commit 472\n" ++ oid_b ++ " missing\n" ++ oid_c ++ " tree 33\n");
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), missing.count());
    try testing.expect(missing.contains(oid_b));
}

test "parseBatchCheck tolerates a trailing line without newline" {
    var missing = try parseBatchCheck(testing.allocator, oid_a ++ " commit 472\n" ++ oid_b ++ " missing");
    defer missing.deinit(testing.allocator);
    try testing.expect(missing.contains(oid_b));
    try testing.expect(!missing.contains(oid_a));
}

test "parseBatchCheck on empty output finds nothing" {
    var missing = try parseBatchCheck(testing.allocator, "");
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), missing.count());
}

test "buildFetchArgv prefixes the fixed flags and dedupes refspecs" {
    const argv = try buildFetchArgv(testing.allocator, &.{ "s1", "s2", "s1" });
    defer testing.allocator.free(argv);
    const expected = [_][]const u8{
        "git",                   "-c",      "http.lowSpeedLimit=1000", "-c",                    "http.lowSpeedTime=30",
        "fetch",                 "--quiet", "--no-tags",               "--no-write-fetch-head", "--no-recurse-submodules",
        "--no-auto-maintenance", "origin",  "s1",                      "s2",
    };
    try testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, got| try testing.expectEqualStrings(want, got);
}

test "missingRemoteRef extracts the ref from git's fatal line" {
    try testing.expectEqualStrings("refs/pull/98/head", missingRemoteRef("fatal: couldn't find remote ref refs/pull/98/head\n").?);
}

test "missingRemoteRef finds the line among other stderr output" {
    const stderr = "warning: something\nfatal: couldn't find remote ref refs/heads/gone-base\r\n";
    try testing.expectEqualStrings("refs/heads/gone-base", missingRemoteRef(stderr).?);
}

test "missingRemoteRef returns null for network failures" {
    try testing.expectEqual(@as(?[]const u8, null), missingRemoteRef("fatal: unable to access 'https://github.com/o/r/': Could not resolve host: github.com\n"));
    try testing.expectEqual(@as(?[]const u8, null), missingRemoteRef("fatal: couldn't find remote ref \n"));
}

test "dropRefspec removes every spec whose source matches" {
    var specs = [_][]const u8{
        "+refs/pull/1/head:refs/skim/pr-1",
        "+refs/pull/98/head:refs/skim/pr-98",
        "+refs/pull/2/head:refs/skim/pr-2",
        "+refs/pull/98/head:refs/skim/pr-98",
    };
    const len = dropRefspec(&specs, "refs/pull/98/head");
    try testing.expectEqual(@as(usize, 2), len);
    try testing.expectEqualStrings("+refs/pull/1/head:refs/skim/pr-1", specs[0]);
    try testing.expectEqualStrings("+refs/pull/2/head:refs/skim/pr-2", specs[1]);
}

test "dropRefspec matches sources without a leading plus" {
    var specs = [_][]const u8{ "refs/heads/x:refs/remotes/origin/x", "+refs/pull/1/head:refs/skim/pr-1" };
    const len = dropRefspec(&specs, "refs/heads/x");
    try testing.expectEqual(@as(usize, 1), len);
    try testing.expectEqualStrings("+refs/pull/1/head:refs/skim/pr-1", specs[0]);
}

test "dropRefspec does not match a prefix of a longer source" {
    var specs = [_][]const u8{"+refs/pull/10/head:refs/skim/pr-10"};
    try testing.expectEqual(@as(usize, 1), dropRefspec(&specs, "refs/pull/1"));
}

test "dropLockedRefspecs drops every spec whose destination git could not lock" {
    var specs = [_][]const u8{
        "+refs/pull/1/head:refs/skim/pr-1",
        "+refs/heads/nest/inner:refs/remotes/origin/nest/inner",
        "+refs/heads/a/b:refs/remotes/origin/a/b",
    };
    const stderr =
        "error: cannot lock ref 'refs/remotes/origin/nest/inner': 'refs/remotes/origin/nest' exists; cannot create 'refs/remotes/origin/nest/inner'\n" ++
        "error: cannot lock ref 'refs/remotes/origin/a/b': 'refs/remotes/origin/a' exists; cannot create 'refs/remotes/origin/a/b'\n";
    const len = dropLockedRefspecs(&specs, stderr);
    try testing.expectEqual(@as(usize, 1), len);
    try testing.expectEqualStrings("+refs/pull/1/head:refs/skim/pr-1", specs[0]);
}

test "dropLockedRefspecs keeps everything when no ref failed to lock" {
    var specs = [_][]const u8{"+refs/pull/1/head:refs/skim/pr-1"};
    try testing.expectEqual(@as(usize, 1), dropLockedRefspecs(&specs, "fatal: unable to access 'https://x/': timeout\n"));
    try testing.expectEqual(@as(usize, 1), dropLockedRefspecs(&specs, "error: cannot lock ref 'refs/skim/pr-9': unable to create lock\n"));
}

test "refLockHeld is true when another git process holds a ref lock" {
    const stderr = "error: cannot lock ref 'refs/remotes/origin/feat': Unable to create '/r/.git/refs/remotes/origin/feat.lock': File exists.\n\nAnother git process seems to be running in this repository\n";
    try testing.expect(refLockHeld(stderr));
}

test "refLockHeld is false for a directory/file ref conflict and other failures" {
    try testing.expect(!refLockHeld("error: cannot lock ref 'refs/remotes/origin/nest/inner': 'refs/remotes/origin/nest' exists; cannot create 'refs/remotes/origin/nest/inner'\n"));
    try testing.expect(!refLockHeld("fatal: couldn't find remote ref refs/pull/9/head\n"));
    try testing.expect(!refLockHeld(""));
}

test "dropLockedRefspecs keeps a spec whose lock is held by another git process" {
    var specs = [_][]const u8{"+refs/heads/feat:refs/remotes/origin/feat"};
    const stderr = "error: cannot lock ref 'refs/remotes/origin/feat': Unable to create '/r/.git/refs/remotes/origin/feat.lock': File exists.\n";
    try testing.expectEqual(@as(usize, 1), dropLockedRefspecs(&specs, stderr));
}
