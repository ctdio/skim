//! Schema migrations for `~/.skim/prs.db`, keyed by `PRAGMA user_version`.
//! Append-only: never edit a step that has shipped; add a new one.

const std = @import("std");
const skim_io = @import("skim_io");
const sqlite = @import("sqlite.zig");

pub const MigrateError = sqlite.Error || error{SchemaTooNew};

/// Index i holds the SQL that moves user_version from i to i+1.
pub const steps = [_][:0]const u8{ migration_1, migration_2 };

pub const current_version: u32 = steps.len;

/// Bring `db` up to `current_version`. Each step runs in its own
/// BEGIN IMMEDIATE transaction together with its user_version bump, and the
/// version is re-read inside the transaction, so two connections opening a
/// fresh file at once (UI + sync worker) cannot both apply a step.
///
/// A file whose user_version is above `current_version` was written by a newer
/// skim: `error.SchemaTooNew`, and nothing is touched.
pub fn migrate(db: *sqlite.Db) MigrateError!void {
    while (true) {
        try db.begin(.immediate);
        errdefer db.rollback();

        const version = try db.userVersion();
        if (version > current_version) return error.SchemaTooNew;
        if (version == current_version) {
            try db.commit();
            return;
        }

        try db.exec(steps[version]);
        var buf: [64]u8 = undefined;
        const bump = std.fmt.bufPrintZ(&buf, "PRAGMA user_version = {d}", .{version + 1}) catch unreachable;
        try db.exec(bump);
        try db.commit();
    }
}

/// Migration 1: the whole initial schema.
///
/// Blob columns (`diff_cache.bytes`, `thread_cache.json`) come last in their
/// rows. SQLite stores a large value on overflow pages, and reading any
/// column after it walks that page chain: with `bytes` before `size`,
/// `SUM(size)` over a 300 MB diff_cache took 79 ms against 0.08 ms with
/// `bytes` last, and eviction sums the cache after every diff it writes.
const migration_1 =
    \\CREATE TABLE repo (
    \\  id               INTEGER PRIMARY KEY,
    \\  key              TEXT NOT NULL UNIQUE,      -- git.repoKey(): origin URL or repo root
    \\  owner            TEXT NOT NULL,
    \\  name             TEXT NOT NULL,
    \\  viewer_login     TEXT,                      -- from GraphQL viewer.login
    \\  viewer_teams     TEXT NOT NULL DEFAULT '',  -- '\n'-joined "org/slug" the viewer belongs to
    \\  teams_synced_at  INTEGER NOT NULL DEFAULT 0,-- unix secs; refreshed at most daily
    \\  open_watermark   TEXT,                      -- max updatedAt seen on OPEN index pass (ISO8601)
    \\  closed_watermark TEXT,                      -- max updatedAt seen on CLOSED/MERGED pass
    \\  last_sync_at     INTEGER NOT NULL DEFAULT 0,
    \\  last_sync_error  TEXT                       -- GhErrorKind tag name, NULL on success
    \\);
    \\
    \\CREATE TABLE pr (
    \\  repo_id            INTEGER NOT NULL REFERENCES repo(id) ON DELETE CASCADE,
    \\  number             INTEGER NOT NULL,
    \\  node_id            TEXT NOT NULL,
    \\  state              TEXT NOT NULL,           -- 'OPEN' | 'CLOSED' | 'MERGED'
    \\  title              TEXT NOT NULL,
    \\  author             TEXT NOT NULL,
    \\  url                TEXT NOT NULL,
    \\  is_draft           INTEGER NOT NULL,
    \\  head_ref           TEXT NOT NULL,
    \\  base_ref           TEXT NOT NULL,
    \\  head_oid           TEXT NOT NULL,
    \\  base_oid           TEXT NOT NULL DEFAULT '',
    \\  updated_at         TEXT NOT NULL,           -- GitHub updatedAt (ISO8601, sorts lexically)
    \\  -- hydrated (tier-2) fields; NULL/'' until hydrated
    \\  hydrated_at_update TEXT,                    -- updated_at value the hydrate pass saw; != updated_at => stale
    \\  additions          INTEGER NOT NULL DEFAULT 0,
    \\  deletions          INTEGER NOT NULL DEFAULT 0,
    \\  changed_files      INTEGER NOT NULL DEFAULT 0,
    \\  review_decision    TEXT NOT NULL DEFAULT '', -- APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED | ''
    \\  ci                 TEXT NOT NULL DEFAULT 'none', -- none|pending|success|failure (parse.CiStatus tag)
    \\  labels             TEXT NOT NULL DEFAULT '', -- '\n'-joined; written by the INDEX pass (cheap)
    \\  requested_users    TEXT NOT NULL DEFAULT '', -- '\n'-joined logins
    \\  requested_teams    TEXT NOT NULL DEFAULT '', -- '\n'-joined "org/slug"
    \\  my_review_state    TEXT NOT NULL DEFAULT '', -- viewer's latest review state ('' = none)
    \\  my_review_oid      TEXT NOT NULL DEFAULT '', -- commit the viewer's latest review was on
    \\  PRIMARY KEY (repo_id, number)
    \\);
    \\CREATE INDEX pr_by_state ON pr(repo_id, state, updated_at DESC);
    \\
    \\CREATE TABLE pr_seen (
    \\  repo_id        INTEGER NOT NULL REFERENCES repo(id) ON DELETE CASCADE,
    \\  number         INTEGER NOT NULL,
    \\  head_oid       TEXT NOT NULL,
    \\  merge_base_oid TEXT NOT NULL,
    \\  seen_at        INTEGER NOT NULL,
    \\  PRIMARY KEY (repo_id, number)
    \\);
    \\
    \\CREATE TABLE diff_cache (
    \\  repo_id        INTEGER NOT NULL REFERENCES repo(id) ON DELETE CASCADE,
    \\  merge_base_oid TEXT NOT NULL,
    \\  head_oid       TEXT NOT NULL,
    \\  size           INTEGER NOT NULL,
    \\  last_used_at   INTEGER NOT NULL,
    \\  bytes          BLOB NOT NULL,               -- raw `git diff --no-color --no-ext-diff -U10` output (last column: see above)
    \\  PRIMARY KEY (repo_id, merge_base_oid, head_oid)
    \\);
    \\CREATE INDEX diff_cache_lru ON diff_cache(repo_id, last_used_at);
    \\
    \\-- A merge base is a pure function of two commit ids, so rows never go stale
    \\-- (deleted only with their repo). Lets the UI thread resolve a DiffKey from
    \\-- pr rows without running `git merge-base`. Written by the prefetch worker.
    \\CREATE TABLE merge_base_cache (
    \\  repo_id        INTEGER NOT NULL REFERENCES repo(id) ON DELETE CASCADE,
    \\  base_tip_oid   TEXT NOT NULL,   -- trunk: pr.base_oid; stacked: parent pr.head_oid; whole-stack: bottom pr.base_oid
    \\  head_oid       TEXT NOT NULL,
    \\  merge_base_oid TEXT NOT NULL,
    \\  PRIMARY KEY (repo_id, base_tip_oid, head_oid)
    \\);
    \\
    \\CREATE TABLE thread_cache (
    \\  repo_id        INTEGER NOT NULL REFERENCES repo(id) ON DELETE CASCADE,
    \\  number         INTEGER NOT NULL,
    \\  pr_updated_at  TEXT NOT NULL,               -- pr.updated_at when fetched; mismatch => stale
    \\  fetched_at     INTEGER NOT NULL,
    \\  json           BLOB NOT NULL,               -- raw `review_query` response bytes (last column: see above)
    \\  PRIMARY KEY (repo_id, number)
    \\);
    \\
    \\CREATE TABLE local_note (
    \\  id          INTEGER PRIMARY KEY,
    \\  repo_id     INTEGER NOT NULL REFERENCES repo(id) ON DELETE CASCADE,
    \\  number      INTEGER NOT NULL,
    \\  file_path   TEXT NOT NULL,
    \\  line_type   TEXT NOT NULL,                  -- parser.Line.LineType tag
    \\  old_lineno  INTEGER,
    \\  new_lineno  INTEGER,
    \\  end_old_lineno INTEGER,
    \\  end_new_lineno INTEGER,
    \\  line_content TEXT NOT NULL,                 -- for re-anchoring by content if lines moved
    \\  author      TEXT NOT NULL,
    \\  text        TEXT NOT NULL,
    \\  replies     TEXT NOT NULL DEFAULT '',       -- JSON array [{author,text}]
    \\  created_at  INTEGER NOT NULL
    \\);
    \\CREATE INDEX local_note_by_pr ON local_note(repo_id, number);
;

/// Migration 2: the review query gained top-level PR comments. Cached
/// responses are keyed only by `pr.updated_at`, so ones fetched before would
/// never show them; dropping them makes the next open refetch.
const migration_2 =
    \\DELETE FROM thread_cache;
;

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "migrate fresh db sets user_version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp);
    defer testing.allocator.free(path);
    var db = try sqlite.Db.open(path, .{});
    defer db.close();

    try migrate(&db);

    try testing.expectEqual(current_version, try db.userVersion());
    const expected = [_][]const u8{ "diff_cache", "local_note", "merge_base_cache", "pr", "pr_seen", "repo", "thread_cache" };
    var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name");
    defer stmt.finalize();
    for (expected) |name| {
        try testing.expect(try stmt.step());
        try testing.expectEqualStrings(name, try stmt.columnText(0));
    }
    try testing.expect(!try stmt.step());
}

test "migrate creates the schema indexes" {
    var db = try sqlite.Db.open(":memory:", .{});
    defer db.close();
    try migrate(&db);

    const expected = [_][]const u8{ "diff_cache_lru", "local_note_by_pr", "pr_by_state" };
    var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type='index' AND sql IS NOT NULL ORDER BY name");
    defer stmt.finalize();
    for (expected) |name| {
        try testing.expect(try stmt.step());
        try testing.expectEqualStrings(name, try stmt.columnText(0));
    }
    try testing.expect(!try stmt.step());
}

test "idempotent reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp);
    defer testing.allocator.free(path);
    {
        var db = try sqlite.Db.open(path, .{});
        defer db.close();
        try migrate(&db);
        try db.exec("INSERT INTO repo(key, owner, name) VALUES('k', 'o', 'n')");
    }

    var db = try sqlite.Db.open(path, .{});
    defer db.close();
    try migrate(&db);

    try testing.expectEqual(current_version, try db.userVersion());
    var stmt = try db.prepare("SELECT key FROM repo");
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqualStrings("k", try stmt.columnText(0));
}

test "diff_cache and thread_cache keep their blob column last" {
    var db = try sqlite.Db.open(":memory:", .{});
    defer db.close();
    try migrate(&db);

    const diff_last = try lastColumn(&db, "PRAGMA table_info(diff_cache)");
    defer testing.allocator.free(diff_last);
    const thread_last = try lastColumn(&db, "PRAGMA table_info(thread_cache)");
    defer testing.allocator.free(thread_last);

    try testing.expectEqualStrings("bytes", diff_last);
    try testing.expectEqualStrings("json", thread_last);
}

test "migration 2 drops review responses cached by migration 1's schema" {
    var db = try sqlite.Db.open(":memory:", .{});
    defer db.close();
    try db.exec(steps[0]);
    try db.exec("PRAGMA user_version = 1");
    try db.exec("INSERT INTO repo(id, key, owner, name) VALUES(1, 'k', 'o', 'n')");
    try db.exec("INSERT INTO thread_cache(repo_id, number, pr_updated_at, fetched_at, json) VALUES(1, 7, 't', 0, x'00')");

    try migrate(&db);

    var stmt = try db.prepare("SELECT count(*) FROM thread_cache");
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
}

test "migrate refuses a newer schema" {
    var db = try sqlite.Db.open(":memory:", .{});
    defer db.close();
    try db.exec(std.fmt.comptimePrint("PRAGMA user_version = {d}", .{current_version + 1}));

    try testing.expectError(error.SchemaTooNew, migrate(&db));
    try testing.expectEqual(current_version + 1, try db.userVersion());
}

test "a failing step leaves user_version and the schema untouched" {
    var db = try sqlite.Db.open(":memory:", .{});
    defer db.close();
    // A pre-existing `repo` table makes migration 1's CREATE TABLE fail.
    try db.exec("CREATE TABLE repo(x)");

    try testing.expectError(error.SqliteError, migrate(&db));
    try testing.expectEqual(@as(u32, 0), try db.userVersion());
    var stmt = try db.prepare("SELECT count(*) FROM sqlite_master WHERE name='pr'");
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
}

test "migration 1 enforces foreign keys with ON DELETE CASCADE" {
    var db = try sqlite.Db.open(":memory:", .{});
    defer db.close();
    try db.exec("PRAGMA foreign_keys=ON");
    try migrate(&db);

    try db.exec(
        \\INSERT INTO repo(id, key, owner, name) VALUES(1, 'k', 'o', 'n');
        \\INSERT INTO pr(repo_id, number, node_id, state, title, author, url, is_draft,
        \\               head_ref, base_ref, head_oid, updated_at)
        \\VALUES(1, 7, 'N', 'OPEN', 't', 'a', 'u', 0, 'h', 'b', 'oid', '2026-01-01T00:00:00Z');
        \\DELETE FROM repo;
    );

    var stmt = try db.prepare("SELECT count(*) FROM pr");
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
}

/// `<tmp>/test.db` as an absolute, NUL-terminated path. Caller frees.
fn tmpDbPath(tmp: *testing.TmpDir) ![:0]u8 {
    const relative = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/test.db", .{tmp.sub_path});
    defer testing.allocator.free(relative);
    const absolute = try skim_io.absolutePathAlloc(testing.allocator, relative);
    defer testing.allocator.free(absolute);
    return testing.allocator.dupeZ(u8, absolute);
}

/// Name of the last column a `PRAGMA table_info` lists; testing.allocator-owned.
fn lastColumn(db: *sqlite.Db, pragma: []const u8) ![]u8 {
    var stmt = try db.prepare(pragma);
    defer stmt.finalize();
    var name: []u8 = &.{};
    errdefer testing.allocator.free(name);
    while (try stmt.step()) {
        testing.allocator.free(name);
        name = &.{};
        name = try testing.allocator.dupe(u8, try stmt.columnText(1));
    }
    return name;
}
