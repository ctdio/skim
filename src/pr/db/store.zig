//! Typed repository over `~/.skim/prs.db`: the only API the PR feature uses to
//! read and write persisted PR data. One `Store` per thread (the UI thread,
//! the sync worker and the prefetch worker each open their own).
//!
//! Plain data types live in `types.zig` (no SQLite) and are re-exported here.

const std = @import("std");
const builtin = @import("builtin");
const skim_io = @import("skim_io");
const config = @import("../../config.zig");
const parse = @import("../parse.zig");
const sqlite = @import("sqlite.zig");
const migrations = @import("migrations.zig");
const types = @import("types.zig");

pub const PrState = types.PrState;
pub const DiffKey = types.DiffKey;
pub const PrRecord = types.PrRecord;
pub const RecordList = types.RecordList;
pub const IndexRow = types.IndexRow;
pub const HydrateRow = types.HydrateRow;
pub const ClosedRow = types.ClosedRow;
pub const NodeRef = types.NodeRef;
pub const NodeRefList = types.NodeRefList;
pub const RepoRow = types.RepoRow;
pub const OwnedRepo = types.OwnedRepo;
pub const SeenRow = types.SeenRow;
pub const OidPair = types.OidPair;
pub const MergeBaseEntry = types.MergeBaseEntry;
pub const ThreadRef = types.ThreadRef;
pub const CachedThreads = types.CachedThreads;
pub const NoteRow = types.NoteRow;
pub const NoteList = types.NoteList;
pub const SyncErrorKind = types.SyncErrorKind;
pub const listItems = types.listItems;

pub const EnsureRepoParams = struct {
    key: []const u8,
    owner: []const u8,
    name: []const u8,
};

pub const ViewerTeamsParams = struct {
    repo_id: i64,
    /// "org/slug" names; stored '\n'-joined.
    teams: []const []const u8,
    now: i64,
};

/// A null field leaves that watermark unchanged.
pub const Watermarks = struct {
    open: ?[]const u8 = null,
    closed: ?[]const u8 = null,
};

pub const SyncResult = struct {
    at: i64,
    /// A `SyncErrorKind` tag name; null records a successful sync.
    err_tag: ?[]const u8,
};

pub const SeenParams = struct {
    repo_id: i64,
    number: u32,
    /// 40-char SHA-1 hex.
    head_oid: []const u8,
    /// 40-char SHA-1 hex.
    merge_base_oid: []const u8,
    now: i64,
};

pub const DiffLookup = struct {
    repo_id: i64,
    key: DiffKey,
    now: i64,
};

pub const EvictParams = struct {
    repo_id: i64,
    budget_bytes: u64,
    ranked: []const DiffKey = &.{},
    /// Ranked entries before this index are never deleted, even when the
    /// budget cannot be met without them.
    keep_nearest: usize = 0,
};

pub const PutDiffParams = struct {
    repo_id: i64,
    key: DiffKey,
    bytes: []const u8,
    now: i64,
};

/// One PR of one repo: the lookup key for `getThreads` and `listNotes`.
pub const PrLookup = struct {
    repo_id: i64,
    number: u32,
};

pub const PutThreadsParams = struct {
    repo_id: i64,
    number: u32,
    pr_updated_at: []const u8,
    json: []const u8,
    now: i64,
};

pub const UpdateNoteParams = struct {
    id: i64,
    text: []const u8,
    replies: []const u8,
};

/// An eviction candidate: `rank` is its index in `EvictParams.ranked`
/// (meaningless for unranked rows).
const SizedKey = struct {
    key: DiffKey,
    size: u64,
    rank: usize,

    fn fartherFirst(_: void, a: SizedKey, b: SizedKey) bool {
        return a.rank > b.rank;
    }
};

/// One per thread (THREADSAFE=2): the UI thread, the sync worker and the
/// prefetch worker each open their own. Never share a Store across threads.
pub const Store = struct {
    allocator: std.mem.Allocator,
    db: sqlite.Db,
    /// Set by `open` when it renamed a corrupt file aside: the new path
    /// (`<path>.corrupt-<unix secs>`), allocator-owned, freed by `close`.
    quarantined_path: ?[]u8 = null,

    pub const default_file_name = "prs.db";

    /// Open (creating if needed) the DB at absolute `path` at mode 0600, apply
    /// connection pragmas, migrate. A file SQLite reports as corrupt / not a
    /// database is renamed to `<path>.corrupt-<unix secs>` and replaced by a
    /// fresh DB (`quarantined_path` says where it went). A file written by a
    /// newer skim fails with `error.SchemaTooNew` and is left alone.
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Store {
        if (std.mem.eql(u8, path, ":memory:")) {
            return .{ .allocator = allocator, .db = try openConfigured(allocator, path) };
        }

        try ensureFileMode(path);
        const db = openConfigured(allocator, path) catch |err| switch (err) {
            error.Corrupt => return reopenQuarantined(allocator, path),
            else => return err,
        };
        return .{ .allocator = allocator, .db = db };
    }

    pub fn close(self: *Store) void {
        self.db.close();
        if (self.quarantined_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    /// Rows written on this connection so far. Compare two readings to tell
    /// whether the writes between them changed anything.
    pub fn totalChanges(self: *Store) u64 {
        return self.db.totalChanges();
    }

    // --- repo -----------------------------------------------------------

    /// Id of the repo row for `params.key`, inserting it on first use. A known
    /// key gets its owner/name refreshed.
    pub fn ensureRepo(self: *Store, params: EnsureRepoParams) !i64 {
        var stmt = try self.db.prepare(
            \\INSERT INTO repo(key, owner, name) VALUES(?, ?, ?)
            \\ON CONFLICT(key) DO UPDATE SET owner = excluded.owner, name = excluded.name
            \\RETURNING id
        );
        defer stmt.finalize();
        try stmt.bindAll(.{ params.key, params.owner, params.name });
        if (!try stmt.step()) return error.SqliteError;
        const id = stmt.columnInt(0);
        // The autocommit transaction ends on the step that reaches DONE; a
        // failed commit only surfaces there.
        if (try stmt.step()) return error.SqliteError;
        return id;
    }

    pub fn getRepo(self: *Store, allocator: std.mem.Allocator, repo_id: i64) !?OwnedRepo {
        var stmt = try self.db.prepare(
            \\SELECT id, key, owner, name, viewer_login, viewer_teams, teams_synced_at,
            \\       open_watermark, closed_watermark, last_sync_at, last_sync_error
            \\FROM repo WHERE id = ?
        );
        defer stmt.finalize();
        try stmt.bind(1, repo_id);
        if (!try stmt.step()) return null;

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const row: RepoRow = .{
            .id = stmt.columnInt(0),
            .key = try a.dupe(u8, try stmt.columnText(1)),
            .owner = try a.dupe(u8, try stmt.columnText(2)),
            .name = try a.dupe(u8, try stmt.columnText(3)),
            .viewer_login = try dupeOpt(a, try stmt.columnTextOpt(4)),
            .viewer_teams = try a.dupe(u8, try stmt.columnText(5)),
            .teams_synced_at = stmt.columnInt(6),
            .open_watermark = try dupeOpt(a, try stmt.columnTextOpt(7)),
            .closed_watermark = try dupeOpt(a, try stmt.columnTextOpt(8)),
            .last_sync_at = stmt.columnInt(9),
            .last_sync_error = try dupeOpt(a, try stmt.columnTextOpt(10)),
        };
        return .{ .arena = arena, .row = row };
    }

    pub fn setViewer(self: *Store, repo_id: i64, login: []const u8) !void {
        try self.run("UPDATE repo SET viewer_login = ? WHERE id = ?", .{ login, repo_id });
    }

    pub fn setViewerTeams(self: *Store, params: ViewerTeamsParams) !void {
        const joined = try std.mem.join(self.allocator, "\n", params.teams);
        defer self.allocator.free(joined);
        try self.run(
            "UPDATE repo SET viewer_teams = ?, teams_synced_at = ? WHERE id = ?",
            .{ joined, params.now, params.repo_id },
        );
    }

    pub fn setWatermarks(self: *Store, repo_id: i64, marks: Watermarks) !void {
        try self.run(
            \\UPDATE repo SET open_watermark = COALESCE(?, open_watermark),
            \\                closed_watermark = COALESCE(?, closed_watermark)
            \\WHERE id = ?
        , .{ marks.open, marks.closed, repo_id });
    }

    pub fn setSyncResult(self: *Store, repo_id: i64, result: SyncResult) !void {
        try self.run(
            "UPDATE repo SET last_sync_at = ?, last_sync_error = ? WHERE id = ?",
            .{ result.at, result.err_tag, repo_id },
        );
    }

    // --- pr rows --------------------------------------------------------

    /// Upsert tier-1 index rows as OPEN. Hydrate columns are never written
    /// here, so they survive; a changed `updated_at` makes the row stale for
    /// `needsHydrate` while the old hydrate values keep rendering. A row
    /// identical to the stored one is not rewritten.
    pub fn upsertIndex(self: *Store, repo_id: i64, rows: []const IndexRow) !void {
        if (rows.len == 0) return;
        try self.db.begin(.immediate);
        errdefer self.db.rollback();
        var stmt = try self.db.prepare(
            \\INSERT INTO pr(repo_id, number, node_id, state, title, author, url, is_draft,
            \\               head_ref, base_ref, head_oid, base_oid, updated_at, labels)
            \\VALUES(?, ?, ?, 'OPEN', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            \\ON CONFLICT(repo_id, number) DO UPDATE SET
            \\  node_id = excluded.node_id, state = 'OPEN', title = excluded.title,
            \\  author = excluded.author, url = excluded.url, is_draft = excluded.is_draft,
            \\  head_ref = excluded.head_ref, base_ref = excluded.base_ref,
            \\  head_oid = excluded.head_oid, base_oid = excluded.base_oid,
            \\  updated_at = excluded.updated_at, labels = excluded.labels
            \\WHERE (pr.node_id, pr.state, pr.title, pr.author, pr.url, pr.is_draft, pr.head_ref,
            \\       pr.base_ref, pr.head_oid, pr.base_oid, pr.updated_at, pr.labels)
            \\  IS NOT (excluded.node_id, 'OPEN', excluded.title, excluded.author, excluded.url,
            \\          excluded.is_draft, excluded.head_ref, excluded.base_ref, excluded.head_oid,
            \\          excluded.base_oid, excluded.updated_at, excluded.labels)
        );
        defer stmt.finalize();
        for (rows) |row| {
            try stmt.bindAll(.{
                repo_id,      row.number,     row.node_id,  row.title,    row.author,
                row.url,      row.is_draft,   row.head_ref, row.base_ref, row.head_oid,
                row.base_oid, row.updated_at, row.labels,
            });
            _ = try stmt.step();
            stmt.reset();
        }
        try self.db.commit();
    }

    /// Write tier-2 fields. A row for a number that is not stored is a no-op.
    pub fn applyHydrate(self: *Store, repo_id: i64, rows: []const HydrateRow) !void {
        if (rows.len == 0) return;
        try self.db.begin(.immediate);
        errdefer self.db.rollback();
        var stmt = try self.db.prepare(
            \\UPDATE pr SET additions = ?, deletions = ?, changed_files = ?, review_decision = ?,
            \\              ci = ?, requested_users = ?, requested_teams = ?, my_review_state = ?,
            \\              my_review_oid = ?, hydrated_at_update = ?
            \\WHERE repo_id = ? AND number = ?
        );
        defer stmt.finalize();
        for (rows) |row| {
            try stmt.bindAll(.{
                row.additions,     row.deletions,       row.changed_files,   row.review_decision,
                @tagName(row.ci),  row.requested_users, row.requested_teams, row.my_review_state,
                row.my_review_oid, row.updated_at,      repo_id,             row.number,
            });
            _ = try stmt.step();
            stmt.reset();
        }
        try self.db.commit();
    }

    /// Stamp `hydrated_at_update` with each ref's `updated_at`, leaving the
    /// tier-2 fields as they are, so `needsHydrate` skips a PR GitHub would
    /// not resolve until its `updated_at` moves. A row whose `updated_at` no
    /// longer matches the ref, or that is not stored, is left alone.
    pub fn markHydrateUnresolved(self: *Store, repo_id: i64, refs: []const NodeRef) !void {
        if (refs.len == 0) return;
        try self.db.begin(.immediate);
        errdefer self.db.rollback();
        var stmt = try self.db.prepare(
            \\UPDATE pr SET hydrated_at_update = ?1
            \\WHERE repo_id = ?2 AND number = ?3 AND updated_at = ?1
        );
        defer stmt.finalize();
        for (refs) |ref| {
            try stmt.bindAll(.{ ref.updated_at, repo_id, ref.number });
            _ = try stmt.step();
            stmt.reset();
        }
        try self.db.commit();
    }

    /// Record closed/merged PRs. PRs never stored are ignored (older closed PRs
    /// are never inserted), and a row already in that state is not rewritten.
    pub fn markClosed(self: *Store, repo_id: i64, rows: []const ClosedRow) !void {
        if (rows.len == 0) return;
        try self.db.begin(.immediate);
        errdefer self.db.rollback();
        var stmt = try self.db.prepare(
            \\UPDATE pr SET state = ?1, updated_at = ?2
            \\WHERE repo_id = ?3 AND number = ?4 AND (state, updated_at) IS NOT (?1, ?2)
        );
        defer stmt.finalize();
        for (rows) |row| {
            try stmt.bindAll(.{ stateText(row.state), row.updated_at, repo_id, row.number });
            _ = try stmt.step();
            stmt.reset();
        }
        try self.db.commit();
    }

    /// Mark every stored OPEN row whose number is not in `open_numbers` as
    /// CLOSED. `open_numbers` must be the complete OPEN set: an empty slice
    /// closes every open row, so never call this after a failed page fetch.
    pub fn reconcileOpen(self: *Store, repo_id: i64, open_numbers: []const u32) !void {
        const wanted = try self.allocator.dupe(u32, open_numbers);
        defer self.allocator.free(wanted);
        std.mem.sort(u32, wanted, {}, std.sort.asc(u32));

        try self.db.begin(.immediate);
        errdefer self.db.rollback();

        var stale: std.ArrayList(u32) = .empty;
        defer stale.deinit(self.allocator);
        {
            var select = try self.db.prepare("SELECT number FROM pr WHERE repo_id = ? AND state = 'OPEN'");
            defer select.finalize();
            try select.bind(1, repo_id);
            while (try select.step()) {
                const number = try columnU32(&select, 0);
                if (std.sort.binarySearch(u32, wanted, number, orderU32) == null) {
                    try stale.append(self.allocator, number);
                }
            }
        }

        var close_stmt = try self.db.prepare("UPDATE pr SET state = 'CLOSED' WHERE repo_id = ? AND number = ?");
        defer close_stmt.finalize();
        for (stale.items) |number| {
            try close_stmt.bindAll(.{ repo_id, number });
            _ = try close_stmt.step();
            close_stmt.reset();
        }
        try self.db.commit();
    }

    /// OPEN rows never hydrated, or hydrated against an older `updated_at`,
    /// newest first.
    pub fn needsHydrate(self: *Store, allocator: std.mem.Allocator, repo_id: i64) !NodeRefList {
        var stmt = try self.db.prepare(
            \\SELECT number, node_id, updated_at FROM pr
            \\WHERE repo_id = ? AND state = 'OPEN'
            \\  AND (hydrated_at_update IS NULL OR hydrated_at_update != updated_at)
            \\ORDER BY updated_at DESC
        );
        defer stmt.finalize();
        try stmt.bind(1, repo_id);

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var items: std.ArrayList(NodeRef) = .empty;
        while (try stmt.step()) {
            try items.append(a, .{
                .number = try columnU32(&stmt, 0),
                .node_id = try a.dupe(u8, try stmt.columnText(1)),
                .updated_at = try a.dupe(u8, try stmt.columnText(2)),
            });
        }
        return .{ .arena = arena, .items = items.items };
    }

    /// Every OPEN row of the repo, newest first, with its seen state.
    pub fn listOpen(self: *Store, allocator: std.mem.Allocator, repo_id: i64) !RecordList {
        var stmt = try self.db.prepare(
            \\SELECT p.number, p.node_id, p.state, p.title, p.author, p.url, p.is_draft,
            \\       p.head_ref, p.base_ref, p.head_oid, p.base_oid, p.updated_at,
            \\       p.hydrated_at_update, p.additions, p.deletions, p.changed_files,
            \\       p.review_decision, p.ci, p.labels, p.requested_users, p.requested_teams,
            \\       p.my_review_state, p.my_review_oid, s.head_oid, s.merge_base_oid
            \\FROM pr p LEFT JOIN pr_seen s USING(repo_id, number)
            \\WHERE p.repo_id = ? AND p.state = 'OPEN'
            \\ORDER BY p.updated_at DESC
        );
        defer stmt.finalize();
        try stmt.bind(1, repo_id);

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var items: std.ArrayList(PrRecord) = .empty;
        while (try stmt.step()) {
            try items.append(a, .{
                .number = try columnU32(&stmt, 0),
                .node_id = try a.dupe(u8, try stmt.columnText(1)),
                .state = try parseState(try stmt.columnText(2)),
                .title = try a.dupe(u8, try stmt.columnText(3)),
                .author = try a.dupe(u8, try stmt.columnText(4)),
                .url = try a.dupe(u8, try stmt.columnText(5)),
                .is_draft = stmt.columnInt(6) != 0,
                .head_ref = try a.dupe(u8, try stmt.columnText(7)),
                .base_ref = try a.dupe(u8, try stmt.columnText(8)),
                .head_oid = try a.dupe(u8, try stmt.columnText(9)),
                .base_oid = try a.dupe(u8, try stmt.columnText(10)),
                .updated_at = try a.dupe(u8, try stmt.columnText(11)),
                .hydrated_at_update = try dupeOpt(a, try stmt.columnTextOpt(12)),
                .additions = try columnU32(&stmt, 13),
                .deletions = try columnU32(&stmt, 14),
                .changed_files = try columnU32(&stmt, 15),
                .review_decision = try a.dupe(u8, try stmt.columnText(16)),
                .ci = std.meta.stringToEnum(parse.CiStatus, try stmt.columnText(17)) orelse .none,
                .labels = try a.dupe(u8, try stmt.columnText(18)),
                .requested_users = try a.dupe(u8, try stmt.columnText(19)),
                .requested_teams = try a.dupe(u8, try stmt.columnText(20)),
                .my_review_state = try a.dupe(u8, try stmt.columnText(21)),
                .my_review_oid = try a.dupe(u8, try stmt.columnText(22)),
                .seen_head_oid = try dupeOpt(a, try stmt.columnTextOpt(23)),
                .seen_merge_base_oid = try dupeOpt(a, try stmt.columnTextOpt(24)),
            });
        }
        return .{ .arena = arena, .items = items.items };
    }

    // --- seen -----------------------------------------------------------

    pub fn getSeen(self: *Store, repo_id: i64, number: u32) !?SeenRow {
        var stmt = try self.db.prepare("SELECT head_oid, merge_base_oid, seen_at FROM pr_seen WHERE repo_id = ? AND number = ?");
        defer stmt.finalize();
        try stmt.bindAll(.{ repo_id, number });
        if (!try stmt.step()) return null;
        return .{
            .head_oid = try storedOid(try stmt.columnText(0)),
            .merge_base_oid = try storedOid(try stmt.columnText(1)),
            .seen_at = stmt.columnInt(2),
        };
    }

    /// Record what the user last looked at. Both oids must be 40-char SHA-1
    /// hex (`error.InvalidOid` otherwise); the row pins its diff in the cache.
    pub fn setSeen(self: *Store, params: SeenParams) !void {
        try validateOid(params.head_oid);
        try validateOid(params.merge_base_oid);
        try self.run(
            \\INSERT INTO pr_seen(repo_id, number, head_oid, merge_base_oid, seen_at)
            \\VALUES(?, ?, ?, ?, ?)
            \\ON CONFLICT(repo_id, number) DO UPDATE SET
            \\  head_oid = excluded.head_oid, merge_base_oid = excluded.merge_base_oid,
            \\  seen_at = excluded.seen_at
        , .{ params.repo_id, params.number, params.head_oid, params.merge_base_oid, params.now });
    }

    pub fn clearSeen(self: *Store, repo_id: i64, number: u32) !void {
        try self.run("DELETE FROM pr_seen WHERE repo_id = ? AND number = ?", .{ repo_id, number });
    }

    // --- diff cache -----------------------------------------------------

    /// Hit → bytes (caller-owned) and last_used_at bumped to `lookup.now`. The
    /// bump is best-effort: a hit is still returned when it fails (e.g. another
    /// connection holds the write lock past busy_timeout).
    pub fn getDiff(self: *Store, allocator: std.mem.Allocator, lookup: DiffLookup) !?[]u8 {
        const bytes = bytes: {
            var stmt = try self.db.prepare("SELECT bytes FROM diff_cache WHERE repo_id = ? AND merge_base_oid = ? AND head_oid = ?");
            defer stmt.finalize();
            try stmt.bindAll(.{ lookup.repo_id, &lookup.key.merge_base_oid, &lookup.key.head_oid });
            if (!try stmt.step()) return null;
            break :bytes try allocator.dupe(u8, stmt.columnBlob(0));
        };
        self.run(
            "UPDATE diff_cache SET last_used_at = ? WHERE repo_id = ? AND merge_base_oid = ? AND head_oid = ?",
            .{ lookup.now, lookup.repo_id, &lookup.key.merge_base_oid, &lookup.key.head_oid },
        ) catch |err| std.log.warn("pr store: diff LRU bump failed: {any}", .{err});
        return bytes;
    }

    /// Insert or replace the diff for `params.key`. Eviction is a separate
    /// call (`evictDiffsRanked`); the caller decides when.
    pub fn putDiff(self: *Store, params: PutDiffParams) !void {
        try self.run(
            \\INSERT INTO diff_cache(repo_id, merge_base_oid, head_oid, bytes, size, last_used_at)
            \\VALUES(?, ?, ?, ?, ?, ?)
            \\ON CONFLICT(repo_id, merge_base_oid, head_oid) DO UPDATE SET
            \\  bytes = excluded.bytes, size = excluded.size, last_used_at = excluded.last_used_at
        , .{
            params.repo_id,
            &params.key.merge_base_oid,
            &params.key.head_oid,
            sqlite.Blob{ .bytes = params.bytes },
            params.bytes.len,
            params.now,
        });
    }

    /// Delete unpinned rows until SUM(size) <= budget, in two passes: rows
    /// absent from `params.ranked` go first, least recently used first; then
    /// ranked rows from the end of the list (a key listed twice counts at its
    /// first, nearest position), stopping short of the first
    /// `params.keep_nearest` entries. Pinned = referenced by a pr_seen row;
    /// those are never deleted, even when the budget cannot be met. Returns
    /// the deleted keys in deletion order (allocator-owned, empty when under
    /// budget).
    pub fn evictDiffsRanked(self: *Store, allocator: std.mem.Allocator, params: EvictParams) ![]DiffKey {
        if (try self.diffCacheSize(params.repo_id) <= params.budget_bytes) return allocator.alloc(DiffKey, 0);

        var rank_of: std.AutoHashMapUnmanaged(DiffKey, usize) = .empty;
        defer rank_of.deinit(self.allocator);
        for (params.ranked, 0..) |key, rank| {
            const slot = try rank_of.getOrPut(self.allocator, key);
            if (!slot.found_existing) slot.value_ptr.* = rank;
        }

        try self.db.begin(.immediate);
        errdefer self.db.rollback();

        // Re-read under the write lock: another connection may have changed
        // the cache since the unlocked check.
        var total = try self.diffCacheSize(params.repo_id);

        var unranked: std.ArrayList(SizedKey) = .empty;
        defer unranked.deinit(self.allocator);
        var ranked: std.ArrayList(SizedKey) = .empty;
        defer ranked.deinit(self.allocator);
        {
            var candidates = try self.db.prepare(
                \\SELECT merge_base_oid, head_oid, size FROM diff_cache d
                \\WHERE repo_id = ? AND NOT EXISTS (
                \\  SELECT 1 FROM pr_seen s WHERE s.repo_id = d.repo_id
                \\    AND s.merge_base_oid = d.merge_base_oid AND s.head_oid = d.head_oid)
                \\ORDER BY last_used_at ASC
            );
            defer candidates.finalize();
            try candidates.bind(1, params.repo_id);
            while (try candidates.step()) {
                const key: DiffKey = .{
                    .merge_base_oid = try storedOid(try candidates.columnText(0)),
                    .head_oid = try storedOid(try candidates.columnText(1)),
                };
                const size = std.math.cast(u64, candidates.columnInt(2)) orelse return error.SqliteError;
                const rank = rank_of.get(key);
                if (rank) |r| if (r < params.keep_nearest) continue;
                const list = if (rank == null) &unranked else &ranked;
                try list.append(self.allocator, .{ .key = key, .size = size, .rank = rank orelse 0 });
            }
        }
        std.mem.sortUnstable(SizedKey, ranked.items, {}, SizedKey.fartherFirst);

        var delete = try self.db.prepare("DELETE FROM diff_cache WHERE repo_id = ? AND merge_base_oid = ? AND head_oid = ?");
        defer delete.finalize();
        var deleted: std.ArrayList(DiffKey) = .empty;
        errdefer deleted.deinit(allocator);
        for ([_][]const SizedKey{ unranked.items, ranked.items }) |victims| {
            for (victims) |victim| {
                if (total <= params.budget_bytes) break;
                try deleted.ensureUnusedCapacity(allocator, 1);
                try delete.bindAll(.{ params.repo_id, &victim.key.merge_base_oid, &victim.key.head_oid });
                _ = try delete.step();
                delete.reset();
                total -|= victim.size;
                deleted.appendAssumeCapacity(victim.key);
            }
        }
        try self.db.commit();
        return deleted.toOwnedSlice(allocator);
    }

    /// `evictDiffsRanked` with nothing ranked: plain LRU over unpinned rows.
    /// Returns rows deleted.
    pub fn evictDiffs(self: *Store, repo_id: i64, budget_bytes: u64) !usize {
        const deleted = try self.evictDiffsRanked(self.allocator, .{ .repo_id = repo_id, .budget_bytes = budget_bytes });
        defer self.allocator.free(deleted);
        return deleted.len;
    }

    /// Existence check that does NOT bump last_used_at (prefetch skip checks
    /// must not look like use, or LRU degrades to "recently scanned").
    pub fn hasDiff(self: *Store, repo_id: i64, key: DiffKey) !bool {
        var stmt = try self.db.prepare("SELECT 1 FROM diff_cache WHERE repo_id = ? AND merge_base_oid = ? AND head_oid = ?");
        defer stmt.finalize();
        try stmt.bindAll(.{ repo_id, &key.merge_base_oid, &key.head_oid });
        return stmt.step();
    }

    // --- merge-base cache -----------------------------------------------

    pub fn getMergeBase(self: *Store, repo_id: i64, pair: OidPair) !?[40]u8 {
        var stmt = try self.db.prepare("SELECT merge_base_oid FROM merge_base_cache WHERE repo_id = ? AND base_tip_oid = ? AND head_oid = ?");
        defer stmt.finalize();
        try stmt.bindAll(.{ repo_id, pair.base_tip_oid, pair.head_oid });
        if (!try stmt.step()) return null;
        return try storedOid(try stmt.columnText(0));
    }

    /// `entry.merge_base_oid` must be 40-char SHA-1 hex (`error.InvalidOid`).
    pub fn putMergeBase(self: *Store, repo_id: i64, entry: MergeBaseEntry) !void {
        try validateOid(entry.merge_base_oid);
        try self.run(
            "INSERT OR REPLACE INTO merge_base_cache(repo_id, base_tip_oid, head_oid, merge_base_oid) VALUES(?, ?, ?, ?)",
            .{ repo_id, entry.base_tip_oid, entry.head_oid, entry.merge_base_oid },
        );
    }

    // --- thread cache ---------------------------------------------------

    /// The cached `review_query` response and the `pr.updated_at` it was
    /// fetched against; the caller compares that with the PR to decide
    /// staleness. Both slices are owned by `allocator`.
    pub fn getThreads(self: *Store, allocator: std.mem.Allocator, lookup: PrLookup) !?CachedThreads {
        var stmt = try self.db.prepare("SELECT pr_updated_at, json FROM thread_cache WHERE repo_id = ? AND number = ?");
        defer stmt.finalize();
        try stmt.bindAll(.{ lookup.repo_id, lookup.number });
        if (!try stmt.step()) return null;
        const pr_updated_at = try allocator.dupe(u8, try stmt.columnText(0));
        errdefer allocator.free(pr_updated_at);
        return .{
            .pr_updated_at = pr_updated_at,
            .json = try allocator.dupe(u8, stmt.columnBlob(1)),
        };
    }

    pub fn putThreads(self: *Store, params: PutThreadsParams) !void {
        try self.run(
            \\INSERT INTO thread_cache(repo_id, number, pr_updated_at, json, fetched_at)
            \\VALUES(?, ?, ?, ?, ?)
            \\ON CONFLICT(repo_id, number) DO UPDATE SET
            \\  pr_updated_at = excluded.pr_updated_at, json = excluded.json,
            \\  fetched_at = excluded.fetched_at
        , .{ params.repo_id, params.number, params.pr_updated_at, sqlite.Blob{ .bytes = params.json }, params.now });
    }

    /// true iff a cached row exists whose pr_updated_at equals `ref.pr_updated_at`.
    pub fn threadsFresh(self: *Store, repo_id: i64, ref: ThreadRef) !bool {
        var stmt = try self.db.prepare("SELECT 1 FROM thread_cache WHERE repo_id = ? AND number = ? AND pr_updated_at = ?");
        defer stmt.finalize();
        try stmt.bindAll(.{ repo_id, ref.number, ref.pr_updated_at });
        return stmt.step();
    }

    // --- local notes ----------------------------------------------------

    /// Notes on one PR in insertion order.
    pub fn listNotes(self: *Store, allocator: std.mem.Allocator, lookup: PrLookup) !NoteList {
        var stmt = try self.db.prepare(
            \\SELECT id, number, file_path, line_type, old_lineno, new_lineno, end_old_lineno,
            \\       end_new_lineno, line_content, author, text, replies, created_at
            \\FROM local_note WHERE repo_id = ? AND number = ? ORDER BY id
        );
        defer stmt.finalize();
        try stmt.bindAll(.{ lookup.repo_id, lookup.number });

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var items: std.ArrayList(NoteRow) = .empty;
        while (try stmt.step()) {
            try items.append(a, .{
                .id = stmt.columnInt(0),
                .number = try columnU32(&stmt, 1),
                .file_path = try a.dupe(u8, try stmt.columnText(2)),
                .line_type = try a.dupe(u8, try stmt.columnText(3)),
                .old_lineno = try columnU32Opt(&stmt, 4),
                .new_lineno = try columnU32Opt(&stmt, 5),
                .end_old_lineno = try columnU32Opt(&stmt, 6),
                .end_new_lineno = try columnU32Opt(&stmt, 7),
                .line_content = try a.dupe(u8, try stmt.columnText(8)),
                .author = try a.dupe(u8, try stmt.columnText(9)),
                .text = try a.dupe(u8, try stmt.columnText(10)),
                .replies = try a.dupe(u8, try stmt.columnText(11)),
                .created_at = stmt.columnInt(12),
            });
        }
        return .{ .arena = arena, .items = items.items };
    }

    /// `note.id` is ignored; returns the new row id.
    pub fn insertNote(self: *Store, repo_id: i64, note: NoteRow) !i64 {
        try self.run(
            \\INSERT INTO local_note(repo_id, number, file_path, line_type, old_lineno, new_lineno,
            \\                       end_old_lineno, end_new_lineno, line_content, author, text,
            \\                       replies, created_at)
            \\VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        , .{
            repo_id,           note.number,     note.file_path,      note.line_type,
            note.old_lineno,   note.new_lineno, note.end_old_lineno, note.end_new_lineno,
            note.line_content, note.author,     note.text,           note.replies,
            note.created_at,
        });
        return self.db.lastInsertRowId();
    }

    pub fn updateNote(self: *Store, params: UpdateNoteParams) !void {
        try self.run("UPDATE local_note SET text = ?, replies = ? WHERE id = ?", .{ params.text, params.replies, params.id });
    }

    pub fn deleteNote(self: *Store, id: i64) !void {
        try self.run("DELETE FROM local_note WHERE id = ?", .{id});
    }

    /// Prepare, bind and run one statement that returns no rows.
    fn run(self: *Store, sql: []const u8, args: anytype) !void {
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindAll(args);
        _ = try stmt.step();
    }

    pub fn diffCacheSize(self: *Store, repo_id: i64) !u64 {
        var sum = try self.db.prepare("SELECT COALESCE(SUM(size), 0) FROM diff_cache WHERE repo_id = ?");
        defer sum.finalize();
        try sum.bind(1, repo_id);
        if (!try sum.step()) return error.SqliteError;
        return std.math.cast(u64, sum.columnInt(0)) orelse error.SqliteError;
    }
};

/// `$HOME/.skim/prs.db`. Pure string assembly; caller frees. The UI and both
/// workers open this same path.
pub fn defaultPath(allocator: std.mem.Allocator) ![]u8 {
    const dir = try config.getSkimDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, Store.default_file_name });
}

/// Force an existing file to mode 0600 (it may have been created looser);
/// SQLite creates a missing one at 0600 (`SQLITE_DEFAULT_FILE_PERMISSIONS` in
/// build.zig) and gives `-wal`/`-shm` the main file's mode. Path-based on
/// purpose: closing any fd on the file drops every POSIX lock this process
/// holds on it, including those of the other threads' open connections.
fn ensureFileMode(path: []const u8) !void {
    const io = skim_io.get();
    std.Io.Dir.cwd().setFilePermissions(io, path, .fromMode(0o600), .{}) catch |err| switch (err) {
        // A missing directory is `error.FileNotFound` here, not SQLite's
        // generic CANTOPEN.
        error.FileNotFound => try std.Io.Dir.cwd().access(io, std.fs.path.dirname(path) orelse ".", .{}),
        else => return err,
    };
}

/// Open `path` with the connection pragmas and bring the schema up to date.
/// busy_timeout goes first so the WAL switch and the migration wait for a
/// connection that holds the file instead of failing.
fn openConfigured(allocator: std.mem.Allocator, path: []const u8) !sqlite.Db {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var db = try sqlite.Db.open(path_z, .{});
    errdefer db.close();
    try db.exec("PRAGMA busy_timeout = 2000");
    try db.exec("PRAGMA journal_mode = WAL");
    try db.exec("PRAGMA synchronous = NORMAL");
    try db.exec("PRAGMA foreign_keys = ON");
    try migrations.migrate(&db);
    return db;
}

/// Move a corrupt DB aside and open a fresh one in its place. A second failure
/// is returned as is.
fn reopenQuarantined(allocator: std.mem.Allocator, path: []const u8) !Store {
    const moved_to = try quarantine(allocator, path);
    errdefer allocator.free(moved_to);
    std.log.warn("pr store: {s} is corrupt; moved it to {s} and started a fresh database", .{ path, moved_to });

    try ensureFileMode(path);
    const db = try openConfigured(allocator, path);
    return .{ .allocator = allocator, .db = db, .quarantined_path = moved_to };
}

/// Rename `path` to `<path>.corrupt-<unix secs>` (`-<n>` appended when that
/// name is taken) and delete its `-wal`/`-shm` side files. Returns the new
/// path, owned by `allocator`.
fn quarantine(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = skim_io.get();
    const moved_to = try unusedQuarantinePath(allocator, path);
    errdefer allocator.free(moved_to);
    try std.Io.Dir.renameAbsolute(path, moved_to, io);

    for ([_][]const u8{ "-wal", "-shm" }) |suffix| {
        const side = try std.fmt.allocPrint(allocator, "{s}{s}", .{ path, suffix });
        defer allocator.free(side);
        std.Io.Dir.deleteFileAbsolute(io, side) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    return moved_to;
}

fn unusedQuarantinePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = skim_io.get();
    const secs = skim_io.timestamp();
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        const candidate = if (attempt == 0)
            try std.fmt.allocPrint(allocator, "{s}.corrupt-{d}", .{ path, secs })
        else
            try std.fmt.allocPrint(allocator, "{s}.corrupt-{d}-{d}", .{ path, secs, attempt });
        std.Io.Dir.accessAbsolute(io, candidate, .{}) catch |err| switch (err) {
            error.FileNotFound => return candidate,
            else => {
                allocator.free(candidate);
                return err;
            },
        };
        allocator.free(candidate);
    }
}

fn stateText(state: PrState) []const u8 {
    return switch (state) {
        .open => "OPEN",
        .closed => "CLOSED",
        .merged => "MERGED",
    };
}

fn parseState(text: []const u8) !PrState {
    if (std.mem.eql(u8, text, "OPEN")) return .open;
    if (std.mem.eql(u8, text, "CLOSED")) return .closed;
    if (std.mem.eql(u8, text, "MERGED")) return .merged;
    return error.SqliteError;
}

fn validateOid(oid: []const u8) !void {
    if (oid.len != 40) return error.InvalidOid;
}

/// Copy a stored oid into a fixed array. Every writer validates the length,
/// so a mismatch means the row was written by something else.
fn storedOid(text: []const u8) ![40]u8 {
    if (text.len != 40) return error.SqliteError;
    return text[0..40].*;
}

fn columnU32(stmt: *sqlite.Stmt, index: u16) !u32 {
    return std.math.cast(u32, stmt.columnInt(index)) orelse error.SqliteError;
}

fn columnU32Opt(stmt: *sqlite.Stmt, index: u16) !?u32 {
    if (stmt.columnIsNull(index)) return null;
    return try columnU32(stmt, index);
}

fn dupeOpt(allocator: std.mem.Allocator, text: ?[]const u8) !?[]const u8 {
    const value = text orelse return null;
    return try allocator.dupe(u8, value);
}

fn orderU32(key: u32, item: u32) std.math.Order {
    return std.math.order(key, item);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const oid_a = "a" ** 40;
const oid_b = "b" ** 40;
const oid_c = "c" ** 40;
const oid_d = "d" ** 40;

const TestDb = struct {
    tmp: testing.TmpDir,
    /// Absolute path of the temp directory.
    dir: []u8,
    /// `<dir>/prs.db`.
    path: []u8,

    fn init() !TestDb {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const relative = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        defer testing.allocator.free(relative);
        const dir = try skim_io.absolutePathAlloc(testing.allocator, relative);
        errdefer testing.allocator.free(dir);
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/prs.db", .{dir});
        return .{ .tmp = tmp, .dir = dir, .path = path };
    }

    fn deinit(self: *TestDb) void {
        testing.allocator.free(self.path);
        testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }

    fn open(self: *TestDb) !Store {
        return Store.open(testing.allocator, self.path);
    }
};

/// An OPEN index row whose fields are distinct per `number`.
fn indexRow(comptime number: u32, updated_at: []const u8) IndexRow {
    return .{
        .number = number,
        .node_id = std.fmt.comptimePrint("PR_node{d}", .{number}),
        .title = std.fmt.comptimePrint("Title {d}", .{number}),
        .author = std.fmt.comptimePrint("author{d}", .{number}),
        .url = std.fmt.comptimePrint("https://github.com/o/r/pull/{d}", .{number}),
        .is_draft = number % 2 == 0,
        .head_ref = std.fmt.comptimePrint("feature-{d}", .{number}),
        .base_ref = "main",
        .head_oid = std.fmt.comptimePrint("{d:0>40}", .{number}),
        .base_oid = oid_b,
        .updated_at = updated_at,
        .labels = "bug\nui",
    };
}

fn hydrateRow(number: u32, updated_at: []const u8) HydrateRow {
    return .{
        .number = number,
        .updated_at = updated_at,
        .additions = number * 10,
        .deletions = number,
        .changed_files = 3,
        .review_decision = "APPROVED",
        .ci = .success,
        .requested_users = "alice\nbob",
        .requested_teams = "org/core",
        .my_review_state = "COMMENTED",
        .my_review_oid = oid_c,
    };
}

fn diffKey(merge_base: *const [40]u8, head: *const [40]u8) DiffKey {
    return .{ .merge_base_oid = merge_base.*, .head_oid = head.* };
}

fn testRepo(store: *Store) !i64 {
    return store.ensureRepo(.{ .key = "git@github.com:o/r.git", .owner = "o", .name = "r" });
}

/// First column of the first row of `sql`, read on the store's own connection.
fn queryInt(store: *Store, sql: []const u8) !i64 {
    var stmt = try store.db.prepare(sql);
    defer stmt.finalize();
    if (!try stmt.step()) return error.NoRows;
    return stmt.columnInt(0);
}

fn writeGarbage(path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.createFileAbsolute(skim_io.get(), path, .{});
    defer file.close(skim_io.get());
    try file.writeStreamingAll(skim_io.get(), bytes);
}

/// Lines of /proc/locks held (not waited on) by this process on `inode`.
fn posixLocksHeld(inode: std.Io.File.INode) !usize {
    const io = skim_io.get();
    const file = try std.Io.Dir.openFileAbsolute(io, "/proc/locks", .{});
    defer file.close(io);
    const text = try skim_io.readAllAlloc(file, testing.allocator, 1 << 20);
    defer testing.allocator.free(text);

    const pid = std.os.linux.getpid();
    var held: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "->") != null) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        // `<id>: POSIX ADVISORY READ <pid> <maj>:<min>:<inode> <start> <end>`
        var values: [6][]const u8 = undefined;
        for (&values) |*value| value.* = fields.next() orelse return error.MalformedProcLocks;
        const owner = std.fmt.parseInt(std.os.linux.pid_t, values[4], 10) catch continue;
        if (owner != pid) continue;
        const device_inode = values[5];
        const inode_text = device_inode[(std.mem.lastIndexOfScalar(u8, device_inode, ':') orelse continue) + 1 ..];
        if (try std.fmt.parseInt(std.Io.File.INode, inode_text, 10) == inode) held += 1;
    }
    return held;
}

fn expectFileContents(path: []const u8, expected: []const u8) !void {
    const actual = try std.Io.Dir.cwd().readFileAlloc(skim_io.get(), path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(actual);
    try testing.expectEqualSlices(u8, expected, actual);
}

fn findRecord(list: RecordList, number: u32) ?PrRecord {
    for (list.items) |record| {
        if (record.number == number) return record;
    }
    return null;
}

// --- open ------------------------------------------------------------------

test "Store.open applies WAL and pragmas" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();

    const path_z = try testing.allocator.dupeZ(u8, t.path);
    defer testing.allocator.free(path_z);
    var raw = try sqlite.Db.open(path_z, .{});
    defer raw.close();
    var stmt = try raw.prepare("PRAGMA journal_mode");
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqualStrings("wal", try stmt.columnText(0));

    try testing.expectEqual(@as(i64, 1), try queryInt(&store, "PRAGMA foreign_keys"));
    try testing.expectEqual(@as(i64, 2000), try queryInt(&store, "PRAGMA busy_timeout"));
    try testing.expectEqual(@as(i64, 1), try queryInt(&store, "PRAGMA synchronous"));
    try testing.expectEqual(@as(u32, migrations.current_version), try store.db.userVersion());
}

test "Store.open creates the file with mode 0600" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();

    const stat = try std.Io.Dir.cwd().statFile(skim_io.get(), t.path, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "Store.open tightens an existing 0644 file to 0600" {
    var t = try TestDb.init();
    defer t.deinit();
    const file = try std.Io.Dir.createFileAbsolute(skim_io.get(), t.path, .{ .permissions = .fromMode(0o644) });
    file.close(skim_io.get());

    var store = try t.open();
    defer store.close();

    const stat = try std.Io.Dir.cwd().statFile(skim_io.get(), t.path, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "Store.open creates the WAL with mode 0600" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}-wal", .{t.path});
    defer testing.allocator.free(wal_path);
    const stat = try std.Io.Dir.cwd().statFile(skim_io.get(), wal_path, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "Store.open of a second connection keeps the first connection's lock on the DB file" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var t = try TestDb.init();
    defer t.deinit();
    var first = try t.open();
    defer first.close();
    try first.db.exec("BEGIN");
    _ = try queryInt(&first, "SELECT count(*) FROM sqlite_master");
    const inode = (try std.Io.Dir.cwd().statFile(skim_io.get(), t.path, .{})).inode;
    try testing.expect(try posixLocksHeld(inode) > 0);

    var second = try t.open();
    defer second.close();

    try testing.expect(try posixLocksHeld(inode) > 0);
    try first.db.exec("COMMIT");
}

test "Store.open quarantines a corrupt file and starts fresh" {
    var t = try TestDb.init();
    defer t.deinit();
    const garbage = [_]u8{0xAB} ** 4096;
    {
        const file = try std.Io.Dir.createFileAbsolute(skim_io.get(), t.path, .{});
        defer file.close(skim_io.get());
        try file.writeStreamingAll(skim_io.get(), &garbage);
    }

    var store = try t.open();
    defer store.close();

    try testing.expectEqual(@as(u32, migrations.current_version), try store.db.userVersion());
    _ = try testRepo(&store);

    var quarantined: ?[]u8 = null;
    defer if (quarantined) |name| testing.allocator.free(name);
    var count: usize = 0;
    var it = t.tmp.dir.iterate();
    while (try it.next(skim_io.get())) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "prs.db.corrupt-")) continue;
        count += 1;
        quarantined = try testing.allocator.dupe(u8, entry.name);
    }
    try testing.expectEqual(@as(usize, 1), count);

    const moved = try t.tmp.dir.readFileAlloc(skim_io.get(), quarantined.?, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(moved);
    try testing.expectEqualSlices(u8, &garbage, moved);

    const expected_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ t.dir, quarantined.? });
    defer testing.allocator.free(expected_path);
    try testing.expectEqualStrings(expected_path, store.quarantined_path.?);
}

test "Store.open quarantining twice in the same second keeps both files" {
    var t = try TestDb.init();
    defer t.deinit();
    const first_garbage = [_]u8{0xAB} ** 4096;
    const second_garbage = [_]u8{0xCD} ** 4096;

    try writeGarbage(t.path, &first_garbage);
    var first = try t.open();
    const first_moved = try testing.allocator.dupe(u8, first.quarantined_path.?);
    defer testing.allocator.free(first_moved);
    first.close();

    // Occupy the timestamped names the second quarantine could pick, so it
    // collides no matter where the second boundary falls.
    const now = skim_io.timestamp();
    for ([_]i64{ now, now + 1 }) |secs| {
        const name = try std.fmt.allocPrint(testing.allocator, "{s}.corrupt-{d}", .{ t.path, secs });
        defer testing.allocator.free(name);
        if (std.mem.eql(u8, name, first_moved)) continue;
        try writeGarbage(name, "occupied");
    }

    try writeGarbage(t.path, &second_garbage);
    var second = try t.open();
    defer second.close();
    const second_moved = second.quarantined_path.?;

    try testing.expect(!std.mem.eql(u8, first_moved, second_moved));
    try expectFileContents(first_moved, &first_garbage);
    try expectFileContents(second_moved, &second_garbage);
}

test "Store.open on a healthy file leaves quarantined_path null" {
    var t = try TestDb.init();
    defer t.deinit();
    {
        var first = try t.open();
        first.close();
    }
    var store = try t.open();
    defer store.close();
    try testing.expectEqual(@as(?[]u8, null), store.quarantined_path);
}

test "Store.open refuses a newer schema without quarantining it" {
    var t = try TestDb.init();
    defer t.deinit();
    {
        var store = try t.open();
        defer store.close();
        try store.db.exec(std.fmt.comptimePrint("PRAGMA user_version = {d}", .{migrations.current_version + 1}));
    }

    try testing.expectError(error.SchemaTooNew, t.open());

    var it = t.tmp.dir.iterate();
    while (try it.next(skim_io.get())) |entry| {
        try testing.expect(!std.mem.startsWith(u8, entry.name, "prs.db.corrupt-"));
    }
}

test "Store.open fails when the directory does not exist" {
    var t = try TestDb.init();
    defer t.deinit();
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/missing/prs.db", .{t.dir});
    defer testing.allocator.free(path);
    try testing.expectError(error.FileNotFound, Store.open(testing.allocator, path));
}

test "defaultPath lands under ~/.skim with the store file name" {
    const path = try defaultPath(testing.allocator);
    defer testing.allocator.free(path);
    try testing.expect(std.mem.endsWith(u8, path, "/.skim/prs.db"));
}

// --- repo ------------------------------------------------------------------

test "ensureRepo is idempotent per key" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();

    const first = try store.ensureRepo(.{ .key = "k1", .owner = "o", .name = "r" });
    const again = try store.ensureRepo(.{ .key = "k1", .owner = "o2", .name = "r2" });
    const other = try store.ensureRepo(.{ .key = "k2", .owner = "o", .name = "r" });
    try testing.expectEqual(first, again);
    try testing.expect(first != other);

    var repo = (try store.getRepo(testing.allocator, first)).?;
    defer repo.deinit();
    try testing.expectEqualStrings("o2", repo.row.owner);
    try testing.expectEqualStrings("r2", repo.row.name);
}

test "getRepo returns null for an unknown id" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    try testing.expectEqual(@as(?OwnedRepo, null), try store.getRepo(testing.allocator, 42));
}

test "a fresh repo row has empty sync state" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    var repo = (try store.getRepo(testing.allocator, repo_id)).?;
    defer repo.deinit();
    try testing.expectEqual(repo_id, repo.row.id);
    try testing.expectEqualStrings("git@github.com:o/r.git", repo.row.key);
    try testing.expectEqual(@as(?[]const u8, null), repo.row.viewer_login);
    try testing.expectEqualStrings("", repo.row.viewer_teams);
    try testing.expectEqual(@as(i64, 0), repo.row.teams_synced_at);
    try testing.expectEqual(@as(?[]const u8, null), repo.row.open_watermark);
    try testing.expectEqual(@as(?[]const u8, null), repo.row.closed_watermark);
    try testing.expectEqual(@as(i64, 0), repo.row.last_sync_at);
    try testing.expectEqual(@as(?[]const u8, null), repo.row.last_sync_error);
}

test "setViewer and setViewerTeams are visible through getRepo" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try store.setViewer(repo_id, "octocat");
    try store.setViewerTeams(.{ .repo_id = repo_id, .teams = &.{ "org/a", "org/b" }, .now = 1234 });

    var repo = (try store.getRepo(testing.allocator, repo_id)).?;
    defer repo.deinit();
    try testing.expectEqualStrings("octocat", repo.row.viewer_login.?);
    try testing.expectEqualStrings("org/a\norg/b", repo.row.viewer_teams);
    try testing.expectEqual(@as(i64, 1234), repo.row.teams_synced_at);
}

test "setViewerTeams with no teams stores an empty list" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try store.setViewerTeams(.{ .repo_id = repo_id, .teams = &.{"org/a"}, .now = 1 });
    try store.setViewerTeams(.{ .repo_id = repo_id, .teams = &.{}, .now = 2 });

    var repo = (try store.getRepo(testing.allocator, repo_id)).?;
    defer repo.deinit();
    try testing.expectEqualStrings("", repo.row.viewer_teams);
    try testing.expectEqual(@as(i64, 2), repo.row.teams_synced_at);
}

test "setWatermarks leaves a null field unchanged" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try store.setWatermarks(repo_id, .{ .open = "2026-01-01T00:00:00Z" });
    {
        var repo = (try store.getRepo(testing.allocator, repo_id)).?;
        defer repo.deinit();
        try testing.expectEqualStrings("2026-01-01T00:00:00Z", repo.row.open_watermark.?);
        try testing.expectEqual(@as(?[]const u8, null), repo.row.closed_watermark);
    }

    try store.setWatermarks(repo_id, .{ .closed = "2026-02-01T00:00:00Z" });
    var repo = (try store.getRepo(testing.allocator, repo_id)).?;
    defer repo.deinit();
    try testing.expectEqualStrings("2026-01-01T00:00:00Z", repo.row.open_watermark.?);
    try testing.expectEqualStrings("2026-02-01T00:00:00Z", repo.row.closed_watermark.?);
}

test "setSyncResult records and clears the error tag" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try store.setSyncResult(repo_id, .{ .at = 5, .err_tag = "network" });
    {
        var repo = (try store.getRepo(testing.allocator, repo_id)).?;
        defer repo.deinit();
        try testing.expectEqual(@as(i64, 5), repo.row.last_sync_at);
        try testing.expectEqualStrings("network", repo.row.last_sync_error.?);
        try testing.expectEqual(SyncErrorKind.network, std.meta.stringToEnum(SyncErrorKind, repo.row.last_sync_error.?).?);
    }

    try store.setSyncResult(repo_id, .{ .at = 9, .err_tag = null });
    var repo = (try store.getRepo(testing.allocator, repo_id)).?;
    defer repo.deinit();
    try testing.expectEqual(@as(i64, 9), repo.row.last_sync_at);
    try testing.expectEqual(@as(?[]const u8, null), repo.row.last_sync_error);
}

// --- pr rows ---------------------------------------------------------------

test "upsertIndex then listOpen returns rows newest first" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try store.upsertIndex(repo_id, &.{
        indexRow(1, "2026-01-01T00:00:00Z"),
        indexRow(2, "2026-03-01T00:00:00Z"),
        indexRow(3, "2026-02-01T00:00:00Z"),
    });

    var list = try store.listOpen(testing.allocator, repo_id);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 3), list.items.len);
    try testing.expectEqual(@as(u32, 2), list.items[0].number);
    try testing.expectEqual(@as(u32, 3), list.items[1].number);
    try testing.expectEqual(@as(u32, 1), list.items[2].number);

    const expected = indexRow(2, "2026-03-01T00:00:00Z");
    const got = list.items[0];
    try testing.expectEqualStrings(expected.node_id, got.node_id);
    try testing.expectEqual(PrState.open, got.state);
    try testing.expectEqualStrings(expected.title, got.title);
    try testing.expectEqualStrings(expected.author, got.author);
    try testing.expectEqualStrings(expected.url, got.url);
    try testing.expectEqual(true, got.is_draft);
    try testing.expectEqual(false, list.items[2].is_draft);
    try testing.expectEqualStrings(expected.head_ref, got.head_ref);
    try testing.expectEqualStrings(expected.base_ref, got.base_ref);
    try testing.expectEqualStrings(expected.head_oid, got.head_oid);
    try testing.expectEqualStrings(expected.base_oid, got.base_oid);
    try testing.expectEqualStrings(expected.updated_at, got.updated_at);
    try testing.expectEqualStrings("bug\nui", got.labels);
    try testing.expectEqual(@as(?[]const u8, null), got.hydrated_at_update);
    try testing.expectEqual(@as(u32, 0), got.additions);
    try testing.expectEqualStrings("", got.review_decision);
    try testing.expectEqual(parse.CiStatus.none, got.ci);
    try testing.expectEqualStrings("", got.requested_users);
    try testing.expectEqual(@as(?[]const u8, null), got.seen_head_oid);
    try testing.expectEqual(@as(?[]const u8, null), got.seen_merge_base_oid);
}

test "listOpen on a repo with no rows is empty" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    var list = try store.listOpen(testing.allocator, repo_id);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 0), list.items.len);
}

test "upsertIndex with no rows is a no-op" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try store.upsertIndex(repo_id, &.{});
    try testing.expectEqual(@as(i64, 0), try queryInt(&store, "SELECT count(*) FROM pr"));
}

test "upsert index then hydrate preserves hydrate fields until updatedAt changes" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);
    const t1 = "2026-01-01T00:00:00Z";
    const t2 = "2026-01-02T00:00:00Z";

    try store.upsertIndex(repo_id, &.{indexRow(1, t1)});
    {
        var refs = try store.needsHydrate(testing.allocator, repo_id);
        defer refs.deinit();
        try testing.expectEqual(@as(usize, 1), refs.items.len);
        try testing.expectEqual(@as(u32, 1), refs.items[0].number);
        try testing.expectEqualStrings("PR_node1", refs.items[0].node_id);
        try testing.expectEqualStrings(t1, refs.items[0].updated_at);
    }

    var hydrate = hydrateRow(1, t1);
    hydrate.additions = 10;
    hydrate.ci = .failure;
    try store.applyHydrate(repo_id, &.{hydrate});
    {
        var refs = try store.needsHydrate(testing.allocator, repo_id);
        defer refs.deinit();
        try testing.expectEqual(@as(usize, 0), refs.items.len);
    }

    var retitled = indexRow(1, t1);
    retitled.title = "New title";
    try store.upsertIndex(repo_id, &.{retitled});
    {
        var list = try store.listOpen(testing.allocator, repo_id);
        defer list.deinit();
        const got = list.items[0];
        try testing.expectEqualStrings("New title", got.title);
        try testing.expectEqual(@as(u32, 10), got.additions);
        try testing.expectEqual(@as(u32, 1), got.deletions);
        try testing.expectEqual(@as(u32, 3), got.changed_files);
        try testing.expectEqual(parse.CiStatus.failure, got.ci);
        try testing.expectEqualStrings("APPROVED", got.review_decision);
        try testing.expectEqualStrings("alice\nbob", got.requested_users);
        try testing.expectEqualStrings("org/core", got.requested_teams);
        try testing.expectEqualStrings("COMMENTED", got.my_review_state);
        try testing.expectEqualStrings(oid_c, got.my_review_oid);
        try testing.expectEqualStrings(t1, got.hydrated_at_update.?);

        var refs = try store.needsHydrate(testing.allocator, repo_id);
        defer refs.deinit();
        try testing.expectEqual(@as(usize, 0), refs.items.len);
    }

    try store.upsertIndex(repo_id, &.{indexRow(1, t2)});
    var list = try store.listOpen(testing.allocator, repo_id);
    defer list.deinit();
    try testing.expectEqual(@as(u32, 10), list.items[0].additions);
    var refs = try store.needsHydrate(testing.allocator, repo_id);
    defer refs.deinit();
    try testing.expectEqual(@as(usize, 1), refs.items.len);
    try testing.expectEqualStrings(t2, refs.items[0].updated_at);
}

test "needsHydrate orders newest first and skips closed rows" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try store.upsertIndex(repo_id, &.{
        indexRow(1, "2026-01-01T00:00:00Z"),
        indexRow(2, "2026-01-03T00:00:00Z"),
        indexRow(3, "2026-01-02T00:00:00Z"),
    });
    try store.markClosed(repo_id, &.{.{ .number = 3, .state = .closed, .updated_at = "2026-01-04T00:00:00Z" }});

    var refs = try store.needsHydrate(testing.allocator, repo_id);
    defer refs.deinit();
    try testing.expectEqual(@as(usize, 2), refs.items.len);
    try testing.expectEqual(@as(u32, 2), refs.items[0].number);
    try testing.expectEqual(@as(u32, 1), refs.items[1].number);
}

test "applyHydrate ignores unknown numbers" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try store.applyHydrate(repo_id, &.{hydrateRow(99, "2026-01-01T00:00:00Z")});
    try testing.expectEqual(@as(i64, 0), try queryInt(&store, "SELECT count(*) FROM pr"));
}

test "markHydrateUnresolved keeps a row out of needsHydrate until its updated_at changes" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);
    const t1 = "2026-01-01T00:00:00Z";
    const t2 = "2026-01-02T00:00:00Z";
    const t3 = "2026-01-03T00:00:00Z";
    try store.upsertIndex(repo_id, &.{ indexRow(1, t1), indexRow(2, t1) });
    var hydrate = hydrateRow(1, t1);
    hydrate.additions = 10;
    try store.applyHydrate(repo_id, &.{hydrate});
    try store.upsertIndex(repo_id, &.{indexRow(1, t2)});

    try store.markHydrateUnresolved(repo_id, &.{
        .{ .number = 1, .node_id = "PR_node1", .updated_at = t2 },
        .{ .number = 99, .node_id = "PR_node99", .updated_at = t2 },
    });
    {
        var refs = try store.needsHydrate(testing.allocator, repo_id);
        defer refs.deinit();
        try testing.expectEqual(@as(usize, 1), refs.items.len);
        try testing.expectEqual(@as(u32, 2), refs.items[0].number);
        var list = try store.listOpen(testing.allocator, repo_id);
        defer list.deinit();
        const got = list.items[0];
        try testing.expectEqual(@as(u32, 1), got.number);
        try testing.expectEqual(@as(u32, 10), got.additions);
        try testing.expectEqualStrings(t2, got.hydrated_at_update.?);
    }

    try store.upsertIndex(repo_id, &.{indexRow(1, t3)});
    var refs = try store.needsHydrate(testing.allocator, repo_id);
    defer refs.deinit();
    try testing.expectEqual(@as(usize, 2), refs.items.len);
    try testing.expectEqual(@as(u32, 1), refs.items[0].number);
    try testing.expectEqualStrings(t3, refs.items[0].updated_at);
}

test "markHydrateUnresolved leaves a row whose updated_at moved after the ref was read" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);
    try store.upsertIndex(repo_id, &.{indexRow(1, "2026-01-01T00:00:00Z")});
    var stale = try store.needsHydrate(testing.allocator, repo_id);
    defer stale.deinit();
    try store.upsertIndex(repo_id, &.{indexRow(1, "2026-01-02T00:00:00Z")});

    try store.markHydrateUnresolved(repo_id, stale.items);

    var refs = try store.needsHydrate(testing.allocator, repo_id);
    defer refs.deinit();
    try testing.expectEqual(@as(usize, 1), refs.items.len);
    try testing.expectEqualStrings("2026-01-02T00:00:00Z", refs.items[0].updated_at);
    try testing.expectEqual(@as(i64, 1), try queryInt(&store, "SELECT count(*) FROM pr WHERE hydrated_at_update IS NULL"));
}

test "markClosed hides a row from listOpen and ignores unknown numbers" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try store.upsertIndex(repo_id, &.{ indexRow(1, "2026-01-01T00:00:00Z"), indexRow(2, "2026-01-02T00:00:00Z") });
    try store.markClosed(repo_id, &.{
        .{ .number = 2, .state = .merged, .updated_at = "2026-01-05T00:00:00Z" },
        .{ .number = 99, .state = .closed, .updated_at = "2026-01-05T00:00:00Z" },
    });

    var list = try store.listOpen(testing.allocator, repo_id);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqual(@as(u32, 1), list.items[0].number);
    try testing.expectEqual(@as(i64, 2), try queryInt(&store, "SELECT count(*) FROM pr"));
    try testing.expectEqual(@as(i64, 1), try queryInt(&store, "SELECT count(*) FROM pr WHERE number=2 AND state='MERGED' AND updated_at='2026-01-05T00:00:00Z'"));
}

test "upsertIndex of an unchanged row writes nothing" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);
    try store.upsertIndex(repo_id, &.{indexRow(1, "2026-01-01T00:00:00Z")});

    const before = store.totalChanges();
    try store.upsertIndex(repo_id, &.{indexRow(1, "2026-01-01T00:00:00Z")});
    try testing.expectEqual(before, store.totalChanges());
}

test "upsertIndex of a changed row is counted as a write" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);
    try store.upsertIndex(repo_id, &.{indexRow(1, "2026-01-01T00:00:00Z")});

    const before = store.totalChanges();
    var renamed = indexRow(1, "2026-01-01T00:00:00Z");
    renamed.title = "renamed";
    try store.upsertIndex(repo_id, &.{renamed});
    try testing.expectEqual(before + 1, store.totalChanges());
    try testing.expectEqual(@as(i64, 1), try queryInt(&store, "SELECT count(*) FROM pr WHERE title='renamed'"));
}

test "upsertIndex of an otherwise unchanged row reopens it after reconcile closed it" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);
    const row = indexRow(1, "2026-01-01T00:00:00Z");
    try store.upsertIndex(repo_id, &.{row});
    try store.reconcileOpen(repo_id, &.{});

    const before = store.totalChanges();
    try store.upsertIndex(repo_id, &.{row});

    try testing.expectEqual(before + 1, store.totalChanges());
    var list = try store.listOpen(testing.allocator, repo_id);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqual(@as(u32, 1), list.items[0].number);
    try testing.expectEqual(PrState.open, list.items[0].state);
}

test "markClosed of a row already in that state writes nothing" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);
    try store.upsertIndex(repo_id, &.{indexRow(1, "2026-01-01T00:00:00Z")});
    const merged: ClosedRow = .{ .number = 1, .state = .merged, .updated_at = "2026-01-05T00:00:00Z" };
    try store.markClosed(repo_id, &.{merged});

    const before = store.totalChanges();
    try store.markClosed(repo_id, &.{ merged, .{ .number = 99, .state = .closed, .updated_at = "2026-01-05T00:00:00Z" } });
    try testing.expectEqual(before, store.totalChanges());
}

test "reconcileOpen closes stored OPEN rows missing from the set" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try store.upsertIndex(repo_id, &.{
        indexRow(1, "2026-01-01T00:00:00Z"),
        indexRow(2, "2026-01-02T00:00:00Z"),
        indexRow(3, "2026-01-03T00:00:00Z"),
    });
    try store.reconcileOpen(repo_id, &.{ 3, 1 });

    var list = try store.listOpen(testing.allocator, repo_id);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqual(@as(u32, 3), list.items[0].number);
    try testing.expectEqual(@as(u32, 1), list.items[1].number);
    try testing.expectEqual(@as(i64, 1), try queryInt(&store, "SELECT count(*) FROM pr WHERE number=2 AND state='CLOSED'"));
}

test "reconcileOpen leaves merged rows merged" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try store.upsertIndex(repo_id, &.{ indexRow(1, "2026-01-01T00:00:00Z"), indexRow(2, "2026-01-02T00:00:00Z") });
    try store.markClosed(repo_id, &.{.{ .number = 2, .state = .merged, .updated_at = "2026-01-03T00:00:00Z" }});
    try store.reconcileOpen(repo_id, &.{1});

    try testing.expectEqual(@as(i64, 1), try queryInt(&store, "SELECT count(*) FROM pr WHERE number=2 AND state='MERGED'"));
}

test "reconcileOpen with an empty set closes every open row of that repo only" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_a = try store.ensureRepo(.{ .key = "a", .owner = "o", .name = "a" });
    const repo_b = try store.ensureRepo(.{ .key = "b", .owner = "o", .name = "b" });

    try store.upsertIndex(repo_a, &.{ indexRow(1, "2026-01-01T00:00:00Z"), indexRow(2, "2026-01-02T00:00:00Z") });
    try store.upsertIndex(repo_b, &.{indexRow(1, "2026-01-01T00:00:00Z")});
    try store.reconcileOpen(repo_a, &.{});

    var list_a = try store.listOpen(testing.allocator, repo_a);
    defer list_a.deinit();
    try testing.expectEqual(@as(usize, 0), list_a.items.len);
    var list_b = try store.listOpen(testing.allocator, repo_b);
    defer list_b.deinit();
    try testing.expectEqual(@as(usize, 1), list_b.items.len);
}

test "upsertIndex reopens a previously closed PR" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try store.upsertIndex(repo_id, &.{indexRow(1, "2026-01-01T00:00:00Z")});
    try store.markClosed(repo_id, &.{.{ .number = 1, .state = .closed, .updated_at = "2026-01-02T00:00:00Z" }});
    try store.upsertIndex(repo_id, &.{indexRow(1, "2026-01-03T00:00:00Z")});

    var list = try store.listOpen(testing.allocator, repo_id);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqual(PrState.open, list.items[0].state);
}

test "rows are isolated per repo_id" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_a = try store.ensureRepo(.{ .key = "a", .owner = "o", .name = "a" });
    const repo_b = try store.ensureRepo(.{ .key = "b", .owner = "o", .name = "b" });

    try store.upsertIndex(repo_a, &.{ indexRow(1, "2026-01-01T00:00:00Z"), indexRow(2, "2026-01-01T00:00:00Z") });
    var other = indexRow(1, "2026-01-01T00:00:00Z");
    other.title = "from b";
    try store.upsertIndex(repo_b, &.{other});

    var list_a = try store.listOpen(testing.allocator, repo_a);
    defer list_a.deinit();
    try testing.expectEqual(@as(usize, 2), list_a.items.len);
    for (list_a.items) |record| {
        try testing.expect(!std.mem.eql(u8, record.title, "from b"));
    }
    var list_b = try store.listOpen(testing.allocator, repo_b);
    defer list_b.deinit();
    try testing.expectEqual(@as(usize, 1), list_b.items.len);
    try testing.expectEqualStrings("from b", list_b.items[0].title);
}

test "listOpen strings outlive the statement and the store" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    const repo_id = try testRepo(&store);
    var row = indexRow(1, "2026-01-01T00:00:00Z");
    row.title = "t\xc3\xadtulo with 'quotes' and \"more\"";
    try store.upsertIndex(repo_id, &.{row});

    var list = try store.listOpen(testing.allocator, repo_id);
    defer list.deinit();
    store.close();

    try testing.expectEqualStrings("t\xc3\xadtulo with 'quotes' and \"more\"", list.items[0].title);
    try testing.expectEqualStrings("bug\nui", list.items[0].labels);
}

// --- seen ------------------------------------------------------------------

test "setSeen/getSeen round-trip and clearSeen removes" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try testing.expectEqual(@as(?SeenRow, null), try store.getSeen(repo_id, 1));
    try store.setSeen(.{ .repo_id = repo_id, .number = 1, .head_oid = oid_a, .merge_base_oid = oid_b, .now = 77 });
    try store.setSeen(.{ .repo_id = repo_id, .number = 1, .head_oid = oid_c, .merge_base_oid = oid_d, .now = 88 });

    const seen = (try store.getSeen(repo_id, 1)).?;
    try testing.expectEqualStrings(oid_c, &seen.head_oid);
    try testing.expectEqualStrings(oid_d, &seen.merge_base_oid);
    try testing.expectEqual(@as(i64, 88), seen.seen_at);

    try store.clearSeen(repo_id, 1);
    try testing.expectEqual(@as(?SeenRow, null), try store.getSeen(repo_id, 1));
}

test "setSeen rejects an oid that is not 40 characters" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try testing.expectError(error.InvalidOid, store.setSeen(.{ .repo_id = repo_id, .number = 1, .head_oid = "abc", .merge_base_oid = oid_b, .now = 1 }));
    try testing.expectError(error.InvalidOid, store.setSeen(.{ .repo_id = repo_id, .number = 1, .head_oid = oid_a, .merge_base_oid = "", .now = 1 }));
    try testing.expectEqual(@as(?SeenRow, null), try store.getSeen(repo_id, 1));
}

test "listOpen exposes seen oids" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try store.upsertIndex(repo_id, &.{ indexRow(1, "2026-01-01T00:00:00Z"), indexRow(2, "2026-01-02T00:00:00Z") });
    try store.setSeen(.{ .repo_id = repo_id, .number = 1, .head_oid = oid_a, .merge_base_oid = oid_b, .now = 1 });

    var list = try store.listOpen(testing.allocator, repo_id);
    defer list.deinit();
    const one = findRecord(list, 1).?;
    try testing.expectEqualStrings(oid_a, one.seen_head_oid.?);
    try testing.expectEqualStrings(oid_b, one.seen_merge_base_oid.?);
    const two = findRecord(list, 2).?;
    try testing.expectEqual(@as(?[]const u8, null), two.seen_head_oid);
    try testing.expectEqual(@as(?[]const u8, null), two.seen_merge_base_oid);
}

// --- diff cache ------------------------------------------------------------

test "putDiff/getDiff round-trip and bump last_used_at" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);
    const key = diffKey(oid_a, oid_b);

    try store.putDiff(.{ .repo_id = repo_id, .key = key, .bytes = "diff --git a b\n\x00binary", .now = 100 });
    const bytes = (try store.getDiff(testing.allocator, .{ .repo_id = repo_id, .key = key, .now = 200 })).?;
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, "diff --git a b\n\x00binary", bytes);
    try testing.expectEqual(@as(i64, 200), try queryInt(&store, "SELECT last_used_at FROM diff_cache"));
}

test "putDiff replaces the bytes for an existing key" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);
    const key = diffKey(oid_a, oid_b);

    try store.putDiff(.{ .repo_id = repo_id, .key = key, .bytes = "old", .now = 1 });
    try store.putDiff(.{ .repo_id = repo_id, .key = key, .bytes = "newer", .now = 2 });

    const bytes = (try store.getDiff(testing.allocator, .{ .repo_id = repo_id, .key = key, .now = 3 })).?;
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("newer", bytes);
    try testing.expectEqual(@as(i64, 5), try queryInt(&store, "SELECT size FROM diff_cache"));
    try testing.expectEqual(@as(i64, 1), try queryInt(&store, "SELECT count(*) FROM diff_cache"));
}

test "putDiff stores an empty diff as a hit" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);
    const key = diffKey(oid_a, oid_b);

    try store.putDiff(.{ .repo_id = repo_id, .key = key, .bytes = "", .now = 1 });
    const bytes = (try store.getDiff(testing.allocator, .{ .repo_id = repo_id, .key = key, .now = 2 })).?;
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 0), bytes.len);
}

test "getDiff misses on a different key" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try store.putDiff(.{ .repo_id = repo_id, .key = diffKey(oid_a, oid_b), .bytes = "x", .now = 1 });
    try testing.expectEqual(@as(?[]u8, null), try store.getDiff(testing.allocator, .{ .repo_id = repo_id, .key = diffKey(oid_b, oid_a), .now = 2 }));
    try testing.expectEqual(@as(i64, 1), try queryInt(&store, "SELECT last_used_at FROM diff_cache"));
}

test "getDiff returns the hit when the last_used_at bump cannot get the write lock" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    var holder = try t.open();
    defer holder.close();
    const repo_id = try testRepo(&store);
    const key = diffKey(oid_a, oid_b);
    try store.putDiff(.{ .repo_id = repo_id, .key = key, .bytes = "cached", .now = 1 });

    try store.db.exec("PRAGMA busy_timeout = 0");
    try holder.db.begin(.immediate);
    defer holder.db.rollback();

    const bytes = (try store.getDiff(testing.allocator, .{ .repo_id = repo_id, .key = key, .now = 2 })).?;
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("cached", bytes);
    try testing.expectEqual(@as(i64, 1), try queryInt(&store, "SELECT last_used_at FROM diff_cache"));
}

test "evict LRU skips pinned seen rows" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);
    const hundred = "x" ** 100;
    const k1 = diffKey(oid_a, oid_b);
    const k2 = diffKey(oid_a, oid_c);
    const k3 = diffKey(oid_a, oid_d);

    try store.putDiff(.{ .repo_id = repo_id, .key = k1, .bytes = hundred, .now = 1 });
    try store.putDiff(.{ .repo_id = repo_id, .key = k2, .bytes = hundred, .now = 2 });
    try store.putDiff(.{ .repo_id = repo_id, .key = k3, .bytes = hundred, .now = 3 });
    try store.setSeen(.{ .repo_id = repo_id, .number = 1, .head_oid = oid_b, .merge_base_oid = oid_a, .now = 1 });

    try testing.expectEqual(@as(usize, 2), try store.evictDiffs(repo_id, 150));

    try testing.expectEqual(@as(i64, 100), try queryInt(&store, "SELECT sum(size) FROM diff_cache"));
    try testing.expect(try store.hasDiff(repo_id, k1));
    try testing.expect(!try store.hasDiff(repo_id, k2));
    try testing.expect(!try store.hasDiff(repo_id, k3));
}

test "evictDiffs deletes oldest first and stops once under budget" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);
    const hundred = "x" ** 100;

    try store.putDiff(.{ .repo_id = repo_id, .key = diffKey(oid_a, oid_b), .bytes = hundred, .now = 30 });
    try store.putDiff(.{ .repo_id = repo_id, .key = diffKey(oid_a, oid_c), .bytes = hundred, .now = 10 });
    try store.putDiff(.{ .repo_id = repo_id, .key = diffKey(oid_a, oid_d), .bytes = hundred, .now = 20 });

    try testing.expectEqual(@as(usize, 1), try store.evictDiffs(repo_id, 200));
    try testing.expect(!try store.hasDiff(repo_id, diffKey(oid_a, oid_c)));
    try testing.expect(try store.hasDiff(repo_id, diffKey(oid_a, oid_b)));
    try testing.expect(try store.hasDiff(repo_id, diffKey(oid_a, oid_d)));
}

test "evictDiffs under budget deletes nothing" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try store.putDiff(.{ .repo_id = repo_id, .key = diffKey(oid_a, oid_b), .bytes = "x" ** 100, .now = 1 });
    try testing.expectEqual(@as(usize, 0), try store.evictDiffs(repo_id, 100));
    try testing.expectEqual(@as(usize, 0), try store.evictDiffs(repo_id, 1000));
    try testing.expect(try store.hasDiff(repo_id, diffKey(oid_a, oid_b)));
}

test "evictDiffs under budget returns without taking the write lock" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    var holder = try t.open();
    defer holder.close();
    const repo_id = try testRepo(&store);
    try store.putDiff(.{ .repo_id = repo_id, .key = diffKey(oid_a, oid_b), .bytes = "x" ** 100, .now = 1 });

    try store.db.exec("PRAGMA busy_timeout = 0");
    try holder.db.begin(.immediate);
    defer holder.db.rollback();

    try testing.expectEqual(@as(usize, 0), try store.evictDiffs(repo_id, 100));
}

test "sync writes with no rows return without taking the write lock" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    var holder = try t.open();
    defer holder.close();
    const repo_id = try testRepo(&store);

    try store.db.exec("PRAGMA busy_timeout = 0");
    try holder.db.begin(.immediate);
    defer holder.db.rollback();

    try store.upsertIndex(repo_id, &.{});
    try store.applyHydrate(repo_id, &.{});
    try store.markClosed(repo_id, &.{});
}

test "evictDiffs with only pinned rows over budget returns 0" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try store.putDiff(.{ .repo_id = repo_id, .key = diffKey(oid_a, oid_b), .bytes = "x" ** 100, .now = 1 });
    try store.setSeen(.{ .repo_id = repo_id, .number = 1, .head_oid = oid_b, .merge_base_oid = oid_a, .now = 1 });

    try testing.expectEqual(@as(usize, 0), try store.evictDiffs(repo_id, 0));
    try testing.expect(try store.hasDiff(repo_id, diffKey(oid_a, oid_b)));
}

test "evictDiffs only counts and deletes rows of its own repo" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_a = try store.ensureRepo(.{ .key = "a", .owner = "o", .name = "a" });
    const repo_b = try store.ensureRepo(.{ .key = "b", .owner = "o", .name = "b" });

    try store.putDiff(.{ .repo_id = repo_a, .key = diffKey(oid_a, oid_b), .bytes = "x" ** 100, .now = 1 });
    try store.putDiff(.{ .repo_id = repo_b, .key = diffKey(oid_a, oid_b), .bytes = "x" ** 100, .now = 1 });

    try testing.expectEqual(@as(usize, 0), try store.evictDiffs(repo_a, 150));
    try testing.expectEqual(@as(usize, 1), try store.evictDiffs(repo_b, 50));
    try testing.expect(try store.hasDiff(repo_a, diffKey(oid_a, oid_b)));
    try testing.expect(!try store.hasDiff(repo_b, diffKey(oid_a, oid_b)));
}

test "hasDiff does not bump last_used_at" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try store.putDiff(.{ .repo_id = repo_id, .key = diffKey(oid_a, oid_b), .bytes = "x", .now = 100 });
    try testing.expect(try store.hasDiff(repo_id, diffKey(oid_a, oid_b)));
    try testing.expectEqual(@as(i64, 100), try queryInt(&store, "SELECT last_used_at FROM diff_cache"));
    try testing.expect(!try store.hasDiff(repo_id, diffKey(oid_c, oid_d)));
}

test "evictDiffsRanked deletes rows outside the ranking before ranked ones" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);
    const hundred = "x" ** 100;
    const k1 = diffKey(oid_a, oid_b);
    const k2 = diffKey(oid_a, oid_c);
    const k3 = diffKey(oid_a, oid_d);
    try store.putDiff(.{ .repo_id = repo_id, .key = k1, .bytes = hundred, .now = 1 });
    try store.putDiff(.{ .repo_id = repo_id, .key = k2, .bytes = hundred, .now = 2 });
    try store.putDiff(.{ .repo_id = repo_id, .key = k3, .bytes = hundred, .now = 3 });

    const deleted = try store.evictDiffsRanked(testing.allocator, .{ .repo_id = repo_id, .budget_bytes = 200, .ranked = &.{ k1, k3 } });
    defer testing.allocator.free(deleted);

    try testing.expectEqualSlices(DiffKey, &.{k2}, deleted);
    try testing.expect(try store.hasDiff(repo_id, k1));
    try testing.expect(!try store.hasDiff(repo_id, k2));
    try testing.expect(try store.hasDiff(repo_id, k3));
}

test "evictDiffsRanked deletes ranked rows farthest first, whatever their age" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);
    const hundred = "x" ** 100;
    const k1 = diffKey(oid_a, oid_b);
    const k2 = diffKey(oid_a, oid_c);
    const k3 = diffKey(oid_a, oid_d);
    try store.putDiff(.{ .repo_id = repo_id, .key = k1, .bytes = hundred, .now = 1 });
    try store.putDiff(.{ .repo_id = repo_id, .key = k2, .bytes = hundred, .now = 9 });
    try store.putDiff(.{ .repo_id = repo_id, .key = k3, .bytes = hundred, .now = 5 });

    const deleted = try store.evictDiffsRanked(testing.allocator, .{ .repo_id = repo_id, .budget_bytes = 100, .ranked = &.{ k1, k3, k2 } });
    defer testing.allocator.free(deleted);

    try testing.expectEqualSlices(DiffKey, &.{ k2, k3 }, deleted);
    try testing.expect(try store.hasDiff(repo_id, k1));
    try testing.expect(!try store.hasDiff(repo_id, k2));
    try testing.expect(!try store.hasDiff(repo_id, k3));
}

test "evictDiffsRanked never deletes a pinned row, even one ranked last" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);
    const hundred = "x" ** 100;
    const k1 = diffKey(oid_a, oid_b);
    const k2 = diffKey(oid_a, oid_c);
    try store.putDiff(.{ .repo_id = repo_id, .key = k1, .bytes = hundred, .now = 1 });
    try store.putDiff(.{ .repo_id = repo_id, .key = k2, .bytes = hundred, .now = 2 });
    try store.setSeen(.{ .repo_id = repo_id, .number = 2, .head_oid = oid_c, .merge_base_oid = oid_a, .now = 1 });

    const deleted = try store.evictDiffsRanked(testing.allocator, .{ .repo_id = repo_id, .budget_bytes = 100, .ranked = &.{ k1, k2 } });
    defer testing.allocator.free(deleted);

    try testing.expectEqualSlices(DiffKey, &.{k1}, deleted);
    try testing.expect(!try store.hasDiff(repo_id, k1));
    try testing.expect(try store.hasDiff(repo_id, k2));
}

test "evictDiffsRanked counts a key ranked twice at its nearest position" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);
    const hundred = "x" ** 100;
    const k1 = diffKey(oid_a, oid_b);
    const k2 = diffKey(oid_a, oid_c);
    try store.putDiff(.{ .repo_id = repo_id, .key = k1, .bytes = hundred, .now = 1 });
    try store.putDiff(.{ .repo_id = repo_id, .key = k2, .bytes = hundred, .now = 2 });

    const deleted = try store.evictDiffsRanked(testing.allocator, .{ .repo_id = repo_id, .budget_bytes = 100, .ranked = &.{ k1, k2, k1 } });
    defer testing.allocator.free(deleted);

    try testing.expectEqualSlices(DiffKey, &.{k2}, deleted);
    try testing.expect(try store.hasDiff(repo_id, k1));
    try testing.expect(!try store.hasDiff(repo_id, k2));
}

test "evictDiffsRanked keeps the keep_nearest ranked rows when pinned bytes alone exceed the budget" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);
    const hundred = "x" ** 100;
    const pinned = diffKey(oid_a, oid_b);
    const near = diffKey(oid_a, oid_c);
    const next = diffKey(oid_b, oid_c);
    const far = diffKey(oid_a, oid_d);
    try store.putDiff(.{ .repo_id = repo_id, .key = pinned, .bytes = hundred, .now = 1 });
    try store.putDiff(.{ .repo_id = repo_id, .key = near, .bytes = hundred, .now = 2 });
    try store.putDiff(.{ .repo_id = repo_id, .key = next, .bytes = hundred, .now = 3 });
    try store.putDiff(.{ .repo_id = repo_id, .key = far, .bytes = hundred, .now = 4 });
    try store.setSeen(.{ .repo_id = repo_id, .number = 1, .head_oid = oid_b, .merge_base_oid = oid_a, .now = 1 });

    const deleted = try store.evictDiffsRanked(testing.allocator, .{
        .repo_id = repo_id,
        .budget_bytes = 50,
        .ranked = &.{ near, next, far },
        .keep_nearest = 2,
    });
    defer testing.allocator.free(deleted);

    try testing.expectEqualSlices(DiffKey, &.{far}, deleted);
    try testing.expect(try store.hasDiff(repo_id, pinned));
    try testing.expect(try store.hasDiff(repo_id, near));
    try testing.expect(try store.hasDiff(repo_id, next));
}

test "evictDiffsRanked under budget deletes nothing and reports nothing" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);
    const k1 = diffKey(oid_a, oid_b);
    try store.putDiff(.{ .repo_id = repo_id, .key = k1, .bytes = "x" ** 100, .now = 1 });

    const deleted = try store.evictDiffsRanked(testing.allocator, .{ .repo_id = repo_id, .budget_bytes = 100, .ranked = &.{k1} });
    defer testing.allocator.free(deleted);

    try testing.expectEqual(@as(usize, 0), deleted.len);
    try testing.expect(try store.hasDiff(repo_id, k1));
}

// --- merge-base cache ------------------------------------------------------

test "putMergeBase then getMergeBase round-trips" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try store.putMergeBase(repo_id, .{ .base_tip_oid = oid_a, .head_oid = oid_b, .merge_base_oid = oid_c });
    const got = (try store.getMergeBase(repo_id, .{ .base_tip_oid = oid_a, .head_oid = oid_b })).?;
    try testing.expectEqualStrings(oid_c, &got);
}

test "getMergeBase is null for an unknown pair" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try testing.expectEqual(@as(?[40]u8, null), try store.getMergeBase(repo_id, .{ .base_tip_oid = oid_a, .head_oid = oid_b }));
    try store.putMergeBase(repo_id, .{ .base_tip_oid = oid_a, .head_oid = oid_b, .merge_base_oid = oid_c });
    try testing.expectEqual(@as(?[40]u8, null), try store.getMergeBase(repo_id, .{ .base_tip_oid = oid_b, .head_oid = oid_a }));
}

test "putMergeBase replaces an existing entry" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try store.putMergeBase(repo_id, .{ .base_tip_oid = oid_a, .head_oid = oid_b, .merge_base_oid = oid_c });
    try store.putMergeBase(repo_id, .{ .base_tip_oid = oid_a, .head_oid = oid_b, .merge_base_oid = oid_d });
    const got = (try store.getMergeBase(repo_id, .{ .base_tip_oid = oid_a, .head_oid = oid_b })).?;
    try testing.expectEqualStrings(oid_d, &got);
}

test "putMergeBase rejects a merge base that is not 40 characters" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try testing.expectError(error.InvalidOid, store.putMergeBase(repo_id, .{ .base_tip_oid = oid_a, .head_oid = oid_b, .merge_base_oid = "short" }));
}

test "merge_base_cache rows are deleted with their repo" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try store.putMergeBase(repo_id, .{ .base_tip_oid = oid_a, .head_oid = oid_b, .merge_base_oid = oid_c });
    try store.db.exec("DELETE FROM repo");
    try testing.expectEqual(@as(?[40]u8, null), try store.getMergeBase(repo_id, .{ .base_tip_oid = oid_a, .head_oid = oid_b }));
    try testing.expectEqual(@as(i64, 0), try queryInt(&store, "SELECT count(*) FROM merge_base_cache"));
}

// --- thread cache ----------------------------------------------------------

test "putThreads/getThreads round-trip; second put replaces" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try testing.expectEqual(@as(?CachedThreads, null), try store.getThreads(testing.allocator, .{ .repo_id = repo_id, .number = 1 }));
    try store.putThreads(.{ .repo_id = repo_id, .number = 1, .pr_updated_at = "T1", .json = "{\"a\":1}", .now = 1 });
    try store.putThreads(.{ .repo_id = repo_id, .number = 1, .pr_updated_at = "T2", .json = "{\"b\":2}", .now = 2 });

    const cached = (try store.getThreads(testing.allocator, .{ .repo_id = repo_id, .number = 1 })).?;
    defer cached.deinit(testing.allocator);
    try testing.expectEqualStrings("T2", cached.pr_updated_at);
    try testing.expectEqualStrings("{\"b\":2}", cached.json);
    try testing.expectEqual(@as(i64, 2), try queryInt(&store, "SELECT fetched_at FROM thread_cache"));
}

test "threadsFresh is true only for a matching pr_updated_at" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    try store.putThreads(.{ .repo_id = repo_id, .number = 1, .pr_updated_at = "T1", .json = "[]", .now = 1 });
    try testing.expect(try store.threadsFresh(repo_id, .{ .number = 1, .pr_updated_at = "T1" }));
    try testing.expect(!try store.threadsFresh(repo_id, .{ .number = 1, .pr_updated_at = "T2" }));
    try testing.expect(!try store.threadsFresh(repo_id, .{ .number = 2, .pr_updated_at = "T1" }));
}

// --- local notes -----------------------------------------------------------

fn testNote(number: u32, text: []const u8) NoteRow {
    return .{
        .id = 0,
        .number = number,
        .file_path = "src/main.zig",
        .line_type = "add",
        .old_lineno = null,
        .new_lineno = 12,
        .end_old_lineno = null,
        .end_new_lineno = 14,
        .line_content = "    const x = 1;",
        .author = "me",
        .text = text,
        .replies = "",
        .created_at = 1700,
    };
}

test "insertNote/listNotes returns notes for one PR in insertion order" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    const first_id = try store.insertNote(repo_id, testNote(1, "first"));
    var second = testNote(1, "second");
    second.old_lineno = 7;
    second.new_lineno = null;
    second.end_old_lineno = 8;
    second.end_new_lineno = null;
    second.line_type = "delete";
    second.replies = "[{\"author\":\"bot\",\"text\":\"ok\"}]";
    const second_id = try store.insertNote(repo_id, second);
    _ = try store.insertNote(repo_id, testNote(2, "other pr"));
    try testing.expect(second_id > first_id);

    var notes = try store.listNotes(testing.allocator, .{ .repo_id = repo_id, .number = 1 });
    defer notes.deinit();
    try testing.expectEqual(@as(usize, 2), notes.items.len);

    const a = notes.items[0];
    try testing.expectEqual(first_id, a.id);
    try testing.expectEqual(@as(u32, 1), a.number);
    try testing.expectEqualStrings("src/main.zig", a.file_path);
    try testing.expectEqualStrings("add", a.line_type);
    try testing.expectEqual(@as(?u32, null), a.old_lineno);
    try testing.expectEqual(@as(?u32, 12), a.new_lineno);
    try testing.expectEqual(@as(?u32, null), a.end_old_lineno);
    try testing.expectEqual(@as(?u32, 14), a.end_new_lineno);
    try testing.expectEqualStrings("    const x = 1;", a.line_content);
    try testing.expectEqualStrings("me", a.author);
    try testing.expectEqualStrings("first", a.text);
    try testing.expectEqualStrings("", a.replies);
    try testing.expectEqual(@as(i64, 1700), a.created_at);

    const b = notes.items[1];
    try testing.expectEqual(second_id, b.id);
    try testing.expectEqualStrings("delete", b.line_type);
    try testing.expectEqual(@as(?u32, 7), b.old_lineno);
    try testing.expectEqual(@as(?u32, null), b.new_lineno);
    try testing.expectEqual(@as(?u32, 8), b.end_old_lineno);
    try testing.expectEqualStrings("[{\"author\":\"bot\",\"text\":\"ok\"}]", b.replies);
}

test "updateNote changes text and replies only" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    const id = try store.insertNote(repo_id, testNote(1, "before"));
    try store.updateNote(.{ .id = id, .text = "after", .replies = "[]" });

    var notes = try store.listNotes(testing.allocator, .{ .repo_id = repo_id, .number = 1 });
    defer notes.deinit();
    try testing.expectEqual(@as(usize, 1), notes.items.len);
    try testing.expectEqualStrings("after", notes.items[0].text);
    try testing.expectEqualStrings("[]", notes.items[0].replies);
    try testing.expectEqualStrings("src/main.zig", notes.items[0].file_path);
    try testing.expectEqual(@as(?u32, 12), notes.items[0].new_lineno);
    try testing.expectEqual(@as(i64, 1700), notes.items[0].created_at);
}

test "deleteNote removes the row" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    const repo_id = try testRepo(&store);

    const keep = try store.insertNote(repo_id, testNote(1, "keep"));
    const drop = try store.insertNote(repo_id, testNote(1, "drop"));
    try store.deleteNote(drop);

    var notes = try store.listNotes(testing.allocator, .{ .repo_id = repo_id, .number = 1 });
    defer notes.deinit();
    try testing.expectEqual(@as(usize, 1), notes.items.len);
    try testing.expectEqual(keep, notes.items[0].id);
}

test "insertNote for an unknown repo violates the foreign key" {
    var t = try TestDb.init();
    defer t.deinit();
    var store = try t.open();
    defer store.close();
    try testing.expectError(error.Constraint, store.insertNote(999, testNote(1, "orphan")));
}

// --- concurrency -----------------------------------------------------------

const WriterContext = struct {
    path: []const u8,
    repo_id: i64,
    failed: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
};

const writer_iterations = 200;

fn stampFor(buf: *[20]u8, iteration: usize) []const u8 {
    return std.fmt.bufPrint(buf, "2026-01-01T00:{d:0>2}:{d:0>2}Z", .{ iteration / 60, iteration % 60 }) catch unreachable;
}

fn runWriter(ctx: *WriterContext) void {
    defer ctx.done.store(true, .release);
    writeRows(ctx) catch {
        ctx.failed.store(true, .release);
    };
}

fn writeRows(ctx: *WriterContext) !void {
    var store = try Store.open(testing.allocator, ctx.path);
    defer store.close();
    for (0..writer_iterations) |iteration| {
        var buf: [20]u8 = undefined;
        const stamp = stampFor(&buf, iteration);
        var rows: [10]IndexRow = undefined;
        var hydrates: [10]HydrateRow = undefined;
        inline for (0..10) |k| {
            rows[k] = indexRow(k + 1, stamp);
            hydrates[k] = hydrateRow(k + 1, stamp);
        }
        try store.upsertIndex(ctx.repo_id, &rows);
        try store.applyHydrate(ctx.repo_id, &hydrates);
    }
}

test "concurrent writer + reader no busy error" {
    var t = try TestDb.init();
    defer t.deinit();
    var reader = try t.open();
    defer reader.close();
    const repo_id = try testRepo(&reader);

    var ctx: WriterContext = .{ .path = t.path, .repo_id = repo_id };
    const thread = try std.Thread.spawn(.{}, runWriter, .{&ctx});
    var reads: usize = 0;
    var read_failed = false;
    while (!ctx.done.load(.acquire)) {
        var list = reader.listOpen(testing.allocator, repo_id) catch {
            read_failed = true;
            break;
        };
        list.deinit();
        reads += 1;
    }
    thread.join();

    try testing.expect(!read_failed);
    try testing.expect(!ctx.failed.load(.acquire));
    try testing.expect(reads > 0);

    var buf: [20]u8 = undefined;
    const final_stamp = stampFor(&buf, writer_iterations - 1);
    var list = try reader.listOpen(testing.allocator, repo_id);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 10), list.items.len);
    for (list.items) |record| {
        try testing.expectEqualStrings(final_stamp, record.updated_at);
        try testing.expectEqualStrings(final_stamp, record.hydrated_at_update.?);
    }
}

test "reader sees a consistent snapshot during an open write transaction" {
    var t = try TestDb.init();
    defer t.deinit();
    var writer = try t.open();
    defer writer.close();
    var reader = try t.open();
    defer reader.close();
    const repo_id = try testRepo(&writer);

    try writer.db.begin(.immediate);
    var insert = try writer.db.prepare(
        \\INSERT INTO pr(repo_id, number, node_id, state, title, author, url, is_draft,
        \\               head_ref, base_ref, head_oid, updated_at)
        \\VALUES(?, 5, 'N5', 'OPEN', 't', 'a', 'u', 0, 'h', 'b', 'oid', '2026-01-01T00:00:00Z')
    );
    try insert.bind(1, repo_id);
    _ = try insert.step();
    insert.finalize();

    {
        var list = try reader.listOpen(testing.allocator, repo_id);
        defer list.deinit();
        try testing.expectEqual(@as(usize, 0), list.items.len);
    }

    try writer.db.commit();
    var list = try reader.listOpen(testing.allocator, repo_id);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqual(@as(u32, 5), list.items[0].number);
}

const OpenerContext = struct {
    path: []const u8,
    failed: std.atomic.Value(bool) = .init(false),
};

fn runOpener(ctx: *OpenerContext) void {
    var store = Store.open(testing.allocator, ctx.path) catch {
        ctx.failed.store(true, .release);
        return;
    };
    store.close();
}

test "two stores opening a fresh file concurrently both succeed" {
    var t = try TestDb.init();
    defer t.deinit();

    var ctx: OpenerContext = .{ .path = t.path };
    var threads: [2]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, runOpener, .{&ctx});
    for (threads) |thread| thread.join();

    try testing.expect(!ctx.failed.load(.acquire));
    var store = try t.open();
    defer store.close();
    try testing.expectEqual(@as(u32, migrations.current_version), try store.db.userVersion());
}
