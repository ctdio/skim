//! The PR sync engine's imperative shell. `runOnce` executes one sync pass
//! against an open `Store` (index → reconcile → closed → teams → watermarks →
//! hydrate); `SyncWorker` owns the background thread, its own `Store`
//! connection, the wake/stop protocol and the generation counter the UI polls.
//!
//! Every decision is made by `planner.zig` and every response is parsed by
//! `sync_parse.zig`; this file only moves bytes between `gh` and the store.
//! No write transaction is held across a `gh` call: each Store write commits
//! on its own.

const std = @import("std");
const skim_io = @import("skim_io");
const github = @import("../github.zig");
const store_mod = @import("../db/store.zig");
const types = @import("../db/types.zig");
const queries = @import("queries.zig");
const sync_parse = @import("sync_parse.zig");
const planner = @import("planner.zig");
const child_group = @import("../child_group.zig");

pub const Options = struct {
    repo_key: []const u8,
    owner: []const u8,
    name: []const u8,
    /// Absolute path of the PR database.
    db_path: []const u8,
    gh_bin: []const u8 = "gh",
    interval_ms: u32 = 60_000,
    /// What `status()` reports until the worker thread has read the stored
    /// sync result; the UI passes what its own connection last showed.
    initial_status: SyncStatus = .{ .running = false, .last_ok_at = null, .last_error = null },
};

pub const SyncStatus = struct {
    running: bool,
    last_ok_at: ?i64,
    last_error: ?github.GhErrorKind,
};

pub const RunParams = struct {
    store: *store_mod.Store,
    repo_id: i64,
    owner: []const u8,
    name: []const u8,
    gh_bin: []const u8 = "gh",
    /// Runs since the worker started (0, 1, 2, ...); drives reconcile cadence.
    sync_index: u64,
    /// PR numbers to hydrate first (what the sidebar is showing).
    priority: []const u32 = &.{},
    /// Per-run arena: every allocating Store read, every `gh` response and
    /// every parse result lives here and is dropped at the end of the run.
    arena: std.mem.Allocator,
    /// Called after each committed group so the UI can reload; the worker
    /// passes a function that bumps `generation`.
    on_commit: ?*const fn (ctx: *anyopaque) void = null,
    on_commit_ctx: *anyopaque = undefined,
    /// Unix seconds; recorded as `last_sync_at` and used for the teams TTL.
    now: i64,
    /// Checked before every `gh` call; once set, `runOnce` returns
    /// `error.Canceled`.
    cancel: ?*const std.atomic.Value(bool) = null,
    /// Holds the in-flight `gh` so `SyncWorker.stop` can kill it.
    child_slot: ?*child_group.ChildSlot = null,
};

pub const RunOutcome = union(enum) {
    ok: struct {
        /// PRs still waiting for hydrate after the per-run batch cap.
        hydrate_remaining: usize,
    },
    failed: github.GhErrorKind,
};

fn PassResult(comptime T: type) type {
    return union(enum) { ok: T, failed: github.GhErrorKind };
}

const IndexResult = struct {
    /// "" when GitHub returned no viewer.
    viewer_login: []const u8,
    /// New open watermark; null leaves it unchanged.
    watermark: ?[]const u8,
};

/// Time since the worker's last run: the monotonic timer, or the wall clock
/// when the timer cannot start. The wall clock can jump, but the interval
/// still elapses, so the worker keeps syncing instead of crashing.
const RunClock = struct {
    timer: ?skim_io.Timer,
    wall_started_ms: i64,

    fn start() RunClock {
        const timer = skim_io.Timer.start() catch |err| fallback: {
            std.log.warn("pr sync: no monotonic timer ({}); timing runs by the wall clock", .{err});
            break :fallback null;
        };
        return .{ .timer = timer, .wall_started_ms = skim_io.milliTimestamp() };
    }

    fn read(self: *RunClock) u64 {
        if (self.timer) |*timer| return timer.read();
        const elapsed_ms = skim_io.milliTimestamp() - self.wall_started_ms;
        if (elapsed_ms < 0) return 0;
        return @as(u64, @intCast(elapsed_ms)) * std.time.ns_per_ms;
    }

    fn reset(self: *RunClock) void {
        if (self.timer) |*timer| timer.reset();
        self.wall_started_ms = skim_io.milliTimestamp();
    }
};

const PageRequest = struct {
    query: []const u8,
    /// Omitted on the first page, which GraphQL reads as a null `$cursor`.
    cursor: ?[]const u8,
    /// Names the pass in `gh` failure logs.
    label: []const u8,
};

/// One full sync of the repo. A `gh` or parse failure is returned as
/// `.failed` after recording it with `setSyncResult` (keeping the previous
/// `last_sync_at`). Pages committed before the failure stay and reconcile
/// never applies a partial open set. A failure in the index, reconcile or
/// closed pass leaves the watermarks where they were; a hydrate failure comes
/// after they were committed, which is safe because `needsHydrate` still
/// lists the PRs it missed. A PR whose hydrate node does not resolve is not
/// a failure: it is marked hydrated at its current `updated_at` and asked
/// for again only once GitHub reports a change, so one inaccessible PR can
/// neither fail every run nor keep the worker rerunning. Only Store errors,
/// OOM and `error.Canceled` are returned as Zig errors.
pub fn runOnce(params: RunParams) !RunOutcome {
    const owned = (try params.store.getRepo(params.arena, params.repo_id)) orelse return error.RepoMissing;
    const repo = owned.row;
    const reconcile_due = planner.reconcileDue(.{ .had_open_watermark = repo.open_watermark != null, .sync_index = params.sync_index });

    const index = switch (try runIndexPass(params, .{ .repo = repo, .full_reread = reconcile_due })) {
        .ok => |result| result,
        .failed => |kind| return recordFailure(params, repo, kind),
    };
    if (reconcile_due) {
        if (try runReconcilePass(params)) |kind| return recordFailure(params, repo, kind);
    }
    const closed_watermark = switch (try runClosedPass(params, repo)) {
        .ok => |watermark| watermark,
        .failed => |kind| return recordFailure(params, repo, kind),
    };
    try runTeamsPass(params, repo, index.viewer_login);
    try params.store.setWatermarks(params.repo_id, .{ .open = index.watermark, .closed = closed_watermark });

    const hydrate_remaining = switch (try runHydratePass(params, index.viewer_login)) {
        .ok => |remaining| remaining,
        .failed => |kind| return recordFailure(params, repo, kind),
    };
    try params.store.setSyncResult(params.repo_id, .{ .at = params.now, .err_tag = null });
    notifyCommit(params);
    return .{ .ok = .{ .hydrate_remaining = hydrate_remaining } };
}

/// Background sync for one repo. Runs once on `start`, then every
/// `interval_ms` and on `requestSync`, until `stop`; a run that leaves
/// hydrate work is followed at once by another while each one makes progress
/// (`planner.rerunImmediately`). It writes only to the
/// database and the counters below; the UI reloads from its own connection
/// when `generation()` changes.
pub const SyncWorker = struct {
    allocator: std.mem.Allocator,
    /// Strings duped in `start`, owned.
    options: Options,
    /// The worker thread's own connection: opened, used and closed on that
    /// thread only. Null until it opens.
    store: ?store_mod.Store = null,
    /// Set with `store`.
    repo_id: i64 = 0,
    thread: std.Thread,

    generation_value: std.atomic.Value(u64) = .init(0),
    /// Futex word. Every requestSync/stop bumps it and wakes the thread, so a
    /// wake that lands while a run is in flight is never lost.
    wake_seq: std.atomic.Value(u32) = .init(0),
    sync_requested: std.atomic.Value(bool) = .init(true),
    stop_requested: std.atomic.Value(bool) = .init(false),

    /// The in-flight `gh` call, killed by `stop`.
    child: child_group.ChildSlot = .{},

    /// Guards `status_value` and `priority`.
    mutex: std.Io.Mutex = .init,
    status_value: SyncStatus = .{ .running = false, .last_ok_at = null, .last_error = null },
    priority: std.ArrayList(u32) = .empty,

    /// Start the thread. It opens the database, registers the repo and reads
    /// the stored sync result itself, so the caller's thread never waits on
    /// SQLite; a database that cannot be opened is reported through
    /// `status()` (`last_error = .other`) and retried on every wake.
    pub fn start(options: Options) !*SyncWorker {
        const allocator = std.heap.c_allocator;
        const self = try allocator.create(SyncWorker);
        errdefer allocator.destroy(self);

        const owned_options = try dupeOptions(allocator, options);
        errdefer freeOptions(allocator, owned_options);

        self.* = .{
            .allocator = allocator,
            .options = owned_options,
            .thread = undefined,
            .status_value = options.initial_status,
        };
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
        return self;
    }

    /// Run a sync as soon as possible. Calls made while a run is in flight
    /// coalesce into one follow-up run.
    pub fn requestSync(self: *SyncWorker) void {
        self.sync_requested.store(true, .release);
        self.wake();
    }

    /// Bumped after every committed group of rows; the UI reloads when it changes.
    pub fn generation(self: *const SyncWorker) u64 {
        return self.generation_value.load(.acquire);
    }

    pub fn status(self: *SyncWorker) SyncStatus {
        self.mutex.lockUncancelable(skim_io.get());
        defer self.mutex.unlock(skim_io.get());
        return self.status_value;
    }

    /// PRs to hydrate first on the next run (copied).
    pub fn setHydratePriority(self: *SyncWorker, numbers: []const u32) void {
        self.mutex.lockUncancelable(skim_io.get());
        defer self.mutex.unlock(skim_io.get());
        self.priority.clearRetainingCapacity();
        self.priority.appendSlice(self.allocator, numbers) catch |err| {
            std.log.warn("pr sync: dropping hydrate priority: {}", .{err});
        };
    }

    /// Stop the thread, killing any in-flight `gh` call rather than waiting
    /// it out, close the database and free the worker.
    pub fn stop(self: *SyncWorker) void {
        self.stop_requested.store(true, .release);
        self.wake();
        self.child.cancel();
        self.thread.join();
        freeOptions(self.allocator, self.options);
        self.priority.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn wake(self: *SyncWorker) void {
        _ = self.wake_seq.fetchAdd(1, .release);
        skim_io.get().futexWake(u32, &self.wake_seq.raw, 1);
    }

    fn workerMain(self: *SyncWorker) void {
        const interval_ns = @as(u64, self.options.interval_ms) * std.time.ns_per_ms;
        if (!self.openStore(interval_ns)) return;
        defer self.store.?.close();
        var since_run = RunClock.start();
        var sync_index: u64 = 0;
        // `hydrate_remaining` of the last run when it was an immediate rerun.
        var rerun_remaining: ?usize = null;
        while (!self.stop_requested.load(.acquire)) {
            const seq = self.wake_seq.load(.acquire);
            if (self.sync_requested.swap(false, .acq_rel) or since_run.read() >= interval_ns) {
                const remaining = self.runOneGuarded(sync_index);
                sync_index += 1;
                since_run.reset();
                const again = planner.rerunImmediately(.{ .remaining = remaining, .previous_remaining = rerun_remaining });
                rerun_remaining = if (again) remaining else null;
                if (again) self.sync_requested.store(true, .release);
                continue;
            }
            self.waitForWake(seq, interval_ns -| since_run.read());
        }
    }

    /// Open this thread's connection, retrying on every wake (`requestSync`,
    /// the interval) while it fails. False when `stop` came first.
    fn openStore(self: *SyncWorker, interval_ns: u64) bool {
        while (!self.stop_requested.load(.acquire)) {
            const seq = self.wake_seq.load(.acquire);
            if (self.tryOpenStore()) {
                return true;
            } else |err| {
                std.log.warn("pr sync: cannot open {s}: {any}", .{ self.options.db_path, err });
                self.mutex.lockUncancelable(skim_io.get());
                self.status_value.last_error = .other;
                self.mutex.unlock(skim_io.get());
            }
            self.waitForWake(seq, interval_ns);
        }
        return false;
    }

    /// Open the database, register the repo and seed `status` from the
    /// stored sync result.
    fn tryOpenStore(self: *SyncWorker) !void {
        var store = try store_mod.Store.open(self.allocator, self.options.db_path);
        errdefer store.close();
        const repo_id = try store.ensureRepo(.{ .key = self.options.repo_key, .owner = self.options.owner, .name = self.options.name });
        const stored_status = try initialStatus(&store, repo_id);
        self.store = store;
        self.repo_id = repo_id;
        self.mutex.lockUncancelable(skim_io.get());
        defer self.mutex.unlock(skim_io.get());
        self.status_value = stored_status;
    }

    /// Sleep until `wake_seq` moves past `seq` or `timeout_ns` passes. A
    /// spurious or canceled wait just returns; the caller re-checks state.
    fn waitForWake(self: *SyncWorker, seq: u32, timeout_ns: u64) void {
        if (timeout_ns == 0) return;
        skim_io.get().futexWaitTimeout(u32, &self.wake_seq.raw, seq, .{
            .duration = .{ .raw = .{ .nanoseconds = @intCast(timeout_ns) }, .clock = .awake },
        }) catch {};
    }

    /// One run with its own arena. Returns how many PRs still wait for
    /// hydrate; 0 after a failed or canceled run.
    fn runOneGuarded(self: *SyncWorker, sync_index: u64) usize {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const priority = self.beginRun(arena.allocator());

        const outcome = runOnce(.{
            .store = &self.store.?,
            .repo_id = self.repo_id,
            .owner = self.options.owner,
            .name = self.options.name,
            .gh_bin = self.options.gh_bin,
            .sync_index = sync_index,
            .priority = priority,
            .arena = arena.allocator(),
            .on_commit = bumpGeneration,
            .on_commit_ctx = self,
            .now = skim_io.timestamp(),
            .cancel = &self.stop_requested,
            .child_slot = &self.child,
        }) catch |err| {
            if (err == error.Canceled) {
                self.finishCanceled();
                return 0;
            }
            std.log.err("pr sync: run failed: {}", .{err});
            self.finishRun(.{ .failed = .other });
            return 0;
        };
        self.finishRun(outcome);
        return switch (outcome) {
            .ok => |ok| ok.hydrate_remaining,
            .failed => 0,
        };
    }

    /// Mark the run started and snapshot the hydrate priority into `arena`.
    fn beginRun(self: *SyncWorker, arena: std.mem.Allocator) []const u32 {
        self.mutex.lockUncancelable(skim_io.get());
        defer self.mutex.unlock(skim_io.get());
        self.status_value.running = true;
        return arena.dupe(u32, self.priority.items) catch &.{};
    }

    fn finishRun(self: *SyncWorker, outcome: RunOutcome) void {
        self.mutex.lockUncancelable(skim_io.get());
        defer self.mutex.unlock(skim_io.get());
        self.status_value.running = false;
        switch (outcome) {
            .ok => {
                self.status_value.last_ok_at = skim_io.timestamp();
                self.status_value.last_error = null;
            },
            .failed => |kind| self.status_value.last_error = kind,
        }
    }

    fn finishCanceled(self: *SyncWorker) void {
        self.mutex.lockUncancelable(skim_io.get());
        defer self.mutex.unlock(skim_io.get());
        self.status_value.running = false;
    }

    fn bumpGeneration(ctx: *anyopaque) void {
        const self: *SyncWorker = @ptrCast(@alignCast(ctx));
        _ = self.generation_value.fetchAdd(1, .release);
    }
};

// =============================================================================
// Passes
// =============================================================================

/// Page OPEN PRs newest-first, upserting every page, until a page ends below
/// the lookback line under the watermark. `full_reread` ignores the watermark
/// and pages to the end: the backstop for a PR whose sort position lags its
/// `updatedAt` by more than the lookback.
fn runIndexPass(params: RunParams, pass: struct { repo: types.RepoRow, full_reread: bool }) !PassResult(IndexResult) {
    const repo = pass.repo;
    const watermark = wellFormed(repo.open_watermark);
    const stop_line = if (pass.full_reread) null else stopLine(watermark);
    var cursor: ?[]const u8 = null;
    var viewer_login: []const u8 = "";
    var first_row: ?[]const u8 = null;
    while (true) {
        const bytes = switch (try fetchPage(params, .{ .query = queries.index_query, .cursor = cursor, .label = "gh api graphql (SkimSyncIndex)" })) {
            .ok => |bytes| bytes,
            .failed => |kind| return .{ .failed = kind },
        };
        const page = sync_parse.parseIndexPage(params.arena, bytes) catch |err| return .{ .failed = try parseFailure(err) };

        if (cursor == null) {
            viewer_login = page.viewer_login;
            if (page.rows.len > 0) first_row = page.rows[0].updated_at;
            if (viewer_login.len > 0 and !std.mem.eql(u8, viewer_login, repo.viewer_login orelse "")) {
                try params.store.setViewer(params.repo_id, viewer_login);
            }
        }
        const before = params.store.totalChanges();
        try params.store.upsertIndex(params.repo_id, page.rows);
        notifyIfChanged(params, before);

        if (planner.shouldStopPaging(.{
            .watermark = if (stop_line) |*line| line else null,
            .last_updated_at = lastUpdatedAt(types.IndexRow, page.rows),
            .has_next = page.has_next,
        })) break;
        cursor = page.end_cursor orelse break;
    }
    return .{ .ok = .{ .viewer_login = viewer_login, .watermark = planner.nextWatermark(watermark, first_row) } };
}

/// Fetch the complete OPEN number set, then close every stored OPEN PR not in
/// it. Nothing is written unless every page succeeded: a partial set would
/// close PRs that are still open. Returns the failure kind, if any.
fn runReconcilePass(params: RunParams) !?github.GhErrorKind {
    var numbers: std.ArrayList(u32) = .empty;
    var cursor: ?[]const u8 = null;
    while (true) {
        const bytes = switch (try fetchPage(params, .{ .query = queries.reconcile_query, .cursor = cursor, .label = "gh api graphql (SkimSyncReconcile)" })) {
            .ok => |bytes| bytes,
            .failed => |kind| return kind,
        };
        const page = sync_parse.parseReconcilePage(params.arena, bytes) catch |err| return try parseFailure(err);
        try numbers.appendSlice(params.arena, page.numbers);
        if (!page.has_next) break;
        cursor = page.end_cursor orelse break;
    }
    const before = params.store.totalChanges();
    try params.store.reconcileOpen(params.repo_id, numbers.items);
    notifyIfChanged(params, before);
    return null;
}

/// Page CLOSED/MERGED PRs newest-first, marking stored ones closed, with the
/// same lookback stop rule as the index pass. On the first sync (no closed
/// watermark) one page is enough: nothing older can be in a store that was
/// empty. A watermark that does not parse is treated the same way rather
/// than paging the whole closed history. Returns the new closed watermark.
fn runClosedPass(params: RunParams, repo: types.RepoRow) !PassResult(?[]const u8) {
    const watermark = wellFormed(repo.closed_watermark);
    const stop_line = stopLine(watermark);
    var cursor: ?[]const u8 = null;
    var first_row: ?[]const u8 = null;
    while (true) {
        const bytes = switch (try fetchPage(params, .{ .query = queries.closed_query, .cursor = cursor, .label = "gh api graphql (SkimSyncClosed)" })) {
            .ok => |bytes| bytes,
            .failed => |kind| return .{ .failed = kind },
        };
        const page = sync_parse.parseClosedPage(params.arena, bytes) catch |err| return .{ .failed = try parseFailure(err) };
        if (cursor == null and page.rows.len > 0) first_row = page.rows[0].updated_at;
        const before = params.store.totalChanges();
        try params.store.markClosed(params.repo_id, page.rows);
        notifyIfChanged(params, before);

        if (watermark == null) break;
        if (planner.shouldStopPaging(.{
            .watermark = if (stop_line) |*line| line else null,
            .last_updated_at = lastUpdatedAt(types.ClosedRow, page.rows),
            .has_next = page.has_next,
        })) break;
        cursor = page.end_cursor orelse break;
    }
    return .{ .ok = planner.nextWatermark(watermark, first_row) };
}

/// Refresh the viewer's teams in the repo owner's org when they are stale or
/// the viewer changed. A `gh` or parse failure only degrades team review
/// filters, so it is logged and the run carries on; cancellation, OOM and
/// Store errors propagate.
fn runTeamsPass(params: RunParams, repo: types.RepoRow, viewer_login: []const u8) !void {
    if (viewer_login.len == 0) return;
    const viewer_changed = !std.mem.eql(u8, viewer_login, repo.viewer_login orelse "");
    if (!planner.teamsDue(.{ .teams_synced_at = repo.teams_synced_at, .now = params.now, .viewer_changed = viewer_changed })) return;

    try checkCanceled(params);
    const vars = [_]github.KV{ .{ .key = "owner", .value = params.owner }, .{ .key = "login", .value = viewer_login } };
    const bytes = switch (try github.runGraphql(params.arena, .{
        .query = queries.teams_query,
        .string_vars = &vars,
        .gh_bin = params.gh_bin,
        .label = "gh api graphql (SkimSyncTeams)",
        .child_slot = params.child_slot,
    })) {
        .ok => |bytes| bytes,
        // runGhArgv already logged the failure.
        .failed => return,
    };
    const teams = sync_parse.parseViewerTeams(params.arena, .{ .bytes = bytes, .owner = params.owner }) catch |err| {
        _ = try parseFailure(err);
        return;
    };
    try params.store.setViewerTeams(.{ .repo_id = params.repo_id, .teams = teams, .now = params.now });
    notifyCommit(params);
}

/// Hydrate PRs whose `updated_at` moved since their last hydrate, priority
/// numbers first, at most `planner.max_hydrate_batches_per_run` batches.
/// Each batch commits on its own. A PR whose node does not resolve is marked
/// hydrated at its current `updated_at` (keeping its old tier-2 values) and
/// the batches after it still run. Returns the PRs left for a later run by
/// the per-run batch cap.
fn runHydratePass(params: RunParams, viewer_login: []const u8) !PassResult(usize) {
    const stale = try params.store.needsHydrate(params.arena, params.repo_id);
    const ordered = try planner.orderForHydrate(params.arena, .{ .refs = stale.items, .priority = params.priority });
    var plan = planner.hydrateBatches(ordered);

    while (plan.batches.next()) |batch| {
        try checkCanceled(params);
        const ids = try params.arena.alloc(github.KV, batch.len);
        for (batch, ids) |ref, *id| id.* = .{ .key = "ids[]", .value = ref.node_id };
        const bytes = switch (try github.runGraphql(params.arena, .{
            .query = queries.hydrate_query,
            .string_vars = ids,
            .gh_bin = params.gh_bin,
            .allow_error_body = true,
            .label = "gh api graphql (SkimSyncHydrate)",
            .child_slot = params.child_slot,
        })) {
            .ok => |bytes| bytes,
            .failed => |kind| return .{ .failed = kind },
        };
        const hydrated = sync_parse.parseHydrate(params.arena, .{
            .bytes = bytes,
            .refs = batch,
            .viewer_login = viewer_login,
        }) catch |err| return .{ .failed = try parseFailure(err) };
        for (hydrated.unresolved) |ref| {
            std.log.warn("pr sync: PR #{d} did not resolve; skipping it until its updatedAt changes", .{ref.number});
        }
        const before = params.store.totalChanges();
        try params.store.applyHydrate(params.repo_id, hydrated.rows);
        try params.store.markClosed(params.repo_id, hydrated.missing);
        try params.store.markHydrateUnresolved(params.repo_id, hydrated.unresolved);
        notifyIfChanged(params, before);
    }
    return .{ .ok = plan.remaining };
}

// =============================================================================
// Helpers
// =============================================================================

fn fetchPage(params: RunParams, request: PageRequest) !github.GhFetch {
    try checkCanceled(params);
    var vars: [3]github.KV = .{
        .{ .key = "owner", .value = params.owner },
        .{ .key = "name", .value = params.name },
        undefined,
    };
    var len: usize = 2;
    if (request.cursor) |cursor| {
        vars[2] = .{ .key = "cursor", .value = cursor };
        len = 3;
    }
    return github.runGraphql(params.arena, .{
        .query = request.query,
        .string_vars = vars[0..len],
        .gh_bin = params.gh_bin,
        .label = request.label,
        .child_slot = params.child_slot,
    });
}

fn checkCanceled(params: RunParams) error{Canceled}!void {
    const cancel = params.cancel orelse return;
    if (cancel.load(.acquire)) return error.Canceled;
}

fn recordFailure(params: RunParams, repo: types.RepoRow, kind: github.GhErrorKind) !RunOutcome {
    // Re-writing the previous last_sync_at keeps the last good time, so the
    // UI can show "synced 5m ago · offline".
    try params.store.setSyncResult(params.repo_id, .{ .at = repo.last_sync_at, .err_tag = @tagName(kind) });
    notifyCommit(params);
    return .{ .failed = kind };
}

/// A response that does not parse is a failed run, not a crash. Only OOM
/// propagates.
fn parseFailure(err: anyerror) error{OutOfMemory}!github.GhErrorKind {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    std.log.warn("pr sync: parse failed: {}", .{err});
    return if (err == error.RepositoryNotFound) .not_found else .other;
}

/// `watermark`, or null when it is not in GitHub's fixed form: a pass then
/// behaves as if it had none, and its next watermark replaces it.
fn wellFormed(watermark: ?[]const u8) ?[]const u8 {
    const value = watermark orelse return null;
    if (planner.lookbackWatermark(value, 0) == null) {
        std.log.warn("pr sync: ignoring malformed watermark \"{s}\"", .{value});
        return null;
    }
    return value;
}

/// The paging stop line for `watermark`; null (page to the end) when there
/// is no watermark.
fn stopLine(watermark: ?[]const u8) ?planner.Timestamp {
    return planner.lookbackWatermark(watermark orelse return null, planner.watermark_lookback_secs);
}

fn lastUpdatedAt(comptime Row: type, rows: []const Row) ?[]const u8 {
    if (rows.len == 0) return null;
    return rows[rows.len - 1].updated_at;
}

fn notifyCommit(params: RunParams) void {
    if (params.on_commit) |on_commit| on_commit(params.on_commit_ctx);
}

/// `notifyCommit` when the store wrote any row since `before`
/// (`Store.totalChanges`), so a page that changed nothing does not make the
/// UI reload.
fn notifyIfChanged(params: RunParams, before: u64) void {
    if (params.store.totalChanges() != before) notifyCommit(params);
}

fn initialStatus(store: *store_mod.Store, repo_id: i64) !SyncStatus {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const owned = (try store.getRepo(arena.allocator(), repo_id)) orelse return error.RepoMissing;
    const repo = owned.row;
    const last_error = if (repo.last_sync_error) |tag| std.meta.stringToEnum(github.GhErrorKind, tag) else null;
    return .{
        .running = false,
        // A failed run re-writes the previous good time, so a nonzero
        // last_sync_at is the last success even when an error is recorded.
        .last_ok_at = if (repo.last_sync_at > 0) repo.last_sync_at else null,
        .last_error = last_error,
    };
}

fn dupeOptions(allocator: std.mem.Allocator, options: Options) !Options {
    var owned = options;
    owned.repo_key = try allocator.dupe(u8, options.repo_key);
    errdefer allocator.free(owned.repo_key);
    owned.owner = try allocator.dupe(u8, options.owner);
    errdefer allocator.free(owned.owner);
    owned.name = try allocator.dupe(u8, options.name);
    errdefer allocator.free(owned.name);
    owned.db_path = try allocator.dupe(u8, options.db_path);
    errdefer allocator.free(owned.db_path);
    owned.gh_bin = try allocator.dupe(u8, options.gh_bin);
    return owned;
}

fn freeOptions(allocator: std.mem.Allocator, options: Options) void {
    allocator.free(options.repo_key);
    allocator.free(options.owner);
    allocator.free(options.name);
    allocator.free(options.db_path);
    allocator.free(options.gh_bin);
}

test "RunClock without a timer measures elapsed time by the wall clock" {
    var clock: RunClock = .{ .timer = null, .wall_started_ms = skim_io.milliTimestamp() - 1500 };
    try std.testing.expect(clock.read() >= 1500 * std.time.ns_per_ms);
    clock.reset();
    try std.testing.expect(clock.read() < 1000 * std.time.ns_per_ms);
}

test "RunClock without a timer reads 0 when the wall clock moved backwards" {
    var clock: RunClock = .{ .timer = null, .wall_started_ms = skim_io.milliTimestamp() + 60_000 };
    try std.testing.expectEqual(0, clock.read());
}
