//! Background prefetch (AD-6): fetches PR heads in batches, writes `git diff`
//! bytes into diff_cache keyed by (merge_base, head), refreshes thread_cache
//! for the nearest PRs, and keeps the cache under budget. Talks to the UI only
//! through the DB, atomics, and a mutex-guarded target list.

const std = @import("std");
const builtin = @import("builtin");
const skim_io = @import("skim_io");
const github = @import("../github.zig");
const child_group = @import("../child_group.zig");
const review_parse = @import("../review_parse.zig");
const store_mod = @import("../db/store.zig");
const plan = @import("plan.zig");
const priority = @import("priority.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const Target = priority.Target;
const DiffKey = priority.DiffKey;
const EnvMap = std.process.Environ.Map;

pub const default_budget_bytes: u64 = 500 * 1024 * 1024;
/// Larger diffs are not cached; a flip to such a PR takes the miss path.
const max_diff_bytes = 64 * 1024 * 1024;
/// stdout/stderr cap for every git child other than `git diff`, and the
/// stderr cap for gh.
const max_git_output_bytes = 1024 * 1024;
/// stdout cap for one review-thread payload from gh.
const max_gh_output_bytes = 16 * 1024 * 1024;
const max_drop_retries = 3;
const stop_wait_ns = 2 * std.time.ns_per_s;
/// Upper bound on an idle sleep; wakes are normally explicit (setTargets,
/// setFocus, stop).
const idle_wait_ns = 30 * std.time.ns_per_s;
/// Wall-clock limit on one git or gh child. A fetch that hangs past it (dead
/// network, a remote that never answers) is killed and recorded as
/// `fetch_failed`; a gh call, as `gh_failed`.
pub const default_child_timeout_ns: u64 = 120 * std.time.ns_per_s;
/// No passphrase or host-key prompt underneath the TUI, and a host that does
/// not answer fails in 15s instead of the system's TCP timeout.
const default_ssh_command = "ssh -o BatchMode=yes -o ConnectTimeout=15";
/// Scratch kept between jobs; anything above it (a large diff) is released.
const scratch_retain_bytes = 1024 * 1024;
/// Diff views per target; `slotOf` ranks each target's views together.
const view_count = @typeInfo(priority.View).@"enum".fields.len;

pub const StartParams = struct {
    /// git cwd for every child.
    repo_root: []const u8,
    /// Absolute path of the PR database.
    db_path: []const u8,
    repo_id: i64,
    /// For `fetchReviewData`.
    owner: []const u8,
    name: []const u8,
    budget_bytes: u64 = default_budget_bytes,
    /// Targets nearest the focus whose diff rows eviction never deletes, even
    /// when that leaves the cache over budget: the rows the user is about to
    /// open stay cached when pinned rows alone fill the budget. Unpinned rows
    /// can therefore exceed `budget_bytes` by at most
    /// `view_count * keep_nearest * max_diff_bytes`; pinned rows are outside
    /// that bound.
    keep_nearest: usize = priority.thread_window,
    /// argv[0] for every git child. `std.process.spawn` resolves argv[0]
    /// against the parent's PATH, so tests point these at real paths instead.
    git_bin: []const u8 = "git",
    /// argv[0] for the review-thread gh child; resolved like `git_bin`.
    gh_bin: []const u8 = "gh",
    /// false skips thread_cache jobs. Zig tests that do not supply a fake
    /// `gh_bin` set this so they never reach the network.
    threads_enabled: bool = true,
    /// Wall-clock limit on each git and gh child.
    child_timeout_ns: u64 = default_child_timeout_ns,
};

pub const Phase = enum { starting, fetching, diffing, threads, idle, failed };

pub const LastError = enum { db_open, git_missing, fetch_failed, gh_failed };

/// What the worker is doing for `targets_version`. Counters and errors reset
/// when a new target list is picked up.
pub const Status = struct {
    phase: Phase = .starting,
    targets_version: u64 = 0,
    /// The focused PR number the worker last ordered its jobs by.
    focus: u32 = 0,
    targets: u32 = 0,
    diffs_ready: u32 = 0,
    /// Diff, whole-stack and thread jobs that failed (skips are not failures).
    failures: u32 = 0,
    /// First error recorded for this version: a later gh failure never hides
    /// an earlier fetch failure.
    last_error: ?LastError = null,
    gh_error: ?github.GhErrorKind = null,
};

pub const CachedDiff = struct { key: DiffKey, bytes: []u8 };

pub const PrefetchWorker = struct {
    allocator: Allocator,
    /// Strings duped in `start`, owned.
    config: StartParams,
    thread: ?std.Thread = null,

    stop_requested: std.atomic.Value(bool) = .init(false),
    /// Futex word for `stop`. The thread moves it running → exited when it is
    /// done with `self`; a `stop` that gives up waiting moves it running →
    /// orphaned, and the thread then frees `self` on its way out.
    life: std.atomic.Value(Life) = .init(.running),
    /// Futex word for idle waits. Bumped by every setTargets/setFocus/stop so
    /// a wake that lands mid-job is never lost.
    wake_seq: std.atomic.Value(u32) = .init(0),
    focus_number: std.atomic.Value(u32) = .init(0),
    gen: std.atomic.Value(u64) = .init(0),

    /// The git/gh child the thread is reading from, so `stop` can kill its
    /// process group.
    child: child_group.ChildSlot = .{},

    /// Guards `targets_arena`, `targets` and `targets_version`.
    targets_mutex: std.Io.Mutex = .init,
    targets_arena: std.heap.ArenaAllocator,
    targets: []Target = &.{},
    targets_version: u64 = 0,

    /// Guards `status_value`.
    status_mutex: std.Io.Mutex = .init,
    status_value: Status = .{},

    /// Replace the target list (display order). Deep-copied under the mutex;
    /// the worker notices the new version between jobs. Returns the version.
    pub fn setTargets(self: *PrefetchWorker, targets: []const Target) !u64 {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        errdefer arena.deinit();
        const copy = try cloneTargets(arena.allocator(), targets);

        self.targets_mutex.lockUncancelable(skim_io.get());
        self.targets_arena.deinit();
        self.targets_arena = arena;
        self.targets = copy;
        self.targets_version += 1;
        const version = self.targets_version;
        self.targets_mutex.unlock(skim_io.get());

        wake(self);
        return version;
    }

    /// The PR under the sidebar cursor. Read between jobs; no restart.
    pub fn setFocus(self: *PrefetchWorker, number: u32) void {
        self.focus_number.store(number, .release);
        wake(self);
    }

    /// Bumped after every diff_cache / thread_cache / merge_base_cache change
    /// that a cache read can observe. The UI re-reads cache state when it
    /// changes.
    pub fn generation(self: *const PrefetchWorker) u64 {
        return self.gen.load(.acquire);
    }

    pub fn status(self: *PrefetchWorker) Status {
        self.status_mutex.lockUncancelable(skim_io.get());
        defer self.status_mutex.unlock(skim_io.get());
        return self.status_value;
    }

    /// Ask the worker to stop, kill the process group of any git/gh child it
    /// is blocked on (SIGTERM, then SIGKILL), and wait up to 2s for the thread
    /// to exit, then join and free. A thread that still has not exited is
    /// detached and frees its own state once it unwinds, so `self` must not be
    /// used after this returns either way.
    pub fn stop(self: *PrefetchWorker) void {
        self.stop_requested.store(true, .release);
        wake(self);
        self.child.cancel();
        const thread = self.thread.?;
        if (!waitForExit(self) and self.life.cmpxchgStrong(.running, .orphaned, .acq_rel, .acquire) == null) {
            std.log.warn("prefetch: worker still busy 2s after its child was killed; detaching it", .{});
            thread.detach();
            return;
        }
        thread.join();
        destroyWorker(self);
    }
};

/// Where the worker thread is in its lifetime; see `PrefetchWorker.life`.
const Life = enum(u32) { running, exited, orphaned };

/// The worker's private view of one targets version.
const Round = struct {
    /// Owns `targets` and `states`.
    arena: std.heap.ArenaAllocator,
    /// Subprocess output, argv and orderings; reset before every job.
    scratch: std.heap.ArenaAllocator,
    version: u64 = 0,
    targets: []Target = &.{},
    states: []priority.JobState = &.{},
    threads_enabled: bool,
    /// Eviction ran since the targets version or the focus last changed.
    evicted: bool = false,
    failures: u32 = 0,
    first_error: ?LastError = null,
    gh_error: ?github.GhErrorKind = null,
    /// The focus the current ordering was built for.
    focus: u32 = 0,
    /// Target indices nearest-first for `focus`; scratch-owned, rebuilt before
    /// every job. Eviction keeps the rows at the front of this list.
    ordered: []const usize = &.{},
    /// First `slotOf` that did not fit in the budget: the nearest slot the
    /// latest eviction deleted a ranked row from. Diff jobs at or past it are
    /// `.evicted` instead of run. Null until a ranked row is deleted this
    /// version. Each eviction replaces it rather than only lowering it; what
    /// a stale boundary still strands after a focus move, `restoreStranded`
    /// re-pends.
    boundary: ?usize = null,
    /// `restoreStranded` already ran for this focus and version.
    stranded_checked: bool = false,
    /// The `wake_seq` that `recheckDone` last ran for.
    rechecked_wake: ?u32 = null,
    /// Outlives every targets version: PRs origin has no pull ref for are
    /// not fetched again until their head or `updated_at` moves.
    backoff: plan.FetchBackoff = .{},
    /// Owns `backoff`'s map.
    allocator: Allocator,

    fn init(allocator: Allocator, threads_enabled: bool) Round {
        return .{ .arena = .init(allocator), .scratch = .init(allocator), .threads_enabled = threads_enabled, .allocator = allocator };
    }

    fn deinit(self: *Round) void {
        self.arena.deinit();
        self.scratch.deinit();
        self.backoff.deinit(self.allocator);
    }

    fn noteError(self: *Round, err: LastError) void {
        if (self.first_error == null) self.first_error = err;
    }

    /// A focus move re-ranks the cache around the new cursor: eviction runs
    /// again, and the evicted views the new `ordered` puts inside the
    /// boundary go back to pending. `.done` rows are not re-run. Call after
    /// `ordered` is set for `focus`.
    fn moveFocus(self: *Round, focus: u32) void {
        if (self.focus == focus) return;
        self.focus = focus;
        self.evicted = false;
        self.stranded_checked = false;
        if (self.boundary) |boundary| _ = repend(self, boundary);
    }

    /// The boundary is a slot count measured around an earlier focus, so
    /// after a move across rows of different sizes it can leave evicted
    /// views nearer the cursor than a row that is still cached, where a
    /// fresh worker would have cached them instead. Once per focus, when no
    /// job is left, every evicted view nearer than the farthest `.done` one
    /// goes back to pending; jobs run nearest-first, so writing them evicts
    /// the farther rows until the first that does not fit evicts itself.
    /// Returns whether any view was re-pended.
    fn restoreStranded(self: *Round) bool {
        if (self.stranded_checked) return false;
        self.stranded_checked = true;
        var farthest_done: ?usize = null;
        for (self.ordered, 0..) |index, position| {
            for (std.enums.values(priority.View)) |view| {
                if (viewOutcome(&self.states[index], view).* == .done) farthest_done = slotOf(position, view);
            }
        }
        return repend(self, farthest_done orelse return false) > 0;
    }
};

/// Everything a job needs. Only the worker thread touches it.
const Ctx = struct {
    worker: *PrefetchWorker,
    store: *Store,
    env: *const EnvMap,
    round: *Round,

    fn config(self: Ctx) *const StartParams {
        return &self.worker.config;
    }

    fn scratch(self: Ctx) Allocator {
        return self.round.scratch.allocator();
    }

    fn bumpGeneration(self: Ctx) void {
        _ = self.worker.gen.fetchAdd(1, .release);
    }
};

const ChildResult = struct {
    ok: bool,
    /// Exit status; 1 for a child killed by a signal.
    exit_code: u32,
    stdout: []u8,
    stderr: []u8,
};

const KeyResolution = struct {
    key: DiffKey,
    /// The merge base was computed (and written to merge_base_cache) now,
    /// rather than read from it.
    computed: bool,
};

const FetchOutcome = enum { ok, partial, failed };

/// Where a missing commit can be fetched from.
const FetchSource = union(enum) {
    pull: u32,
    branch: struct { name: []const u8, index: usize, view: priority.View },
};

const WantedOid = struct { oid: []const u8, source: FetchSource };

/// What one eviction pass deleted.
const EvictResult = struct {
    deleted: usize = 0,
    /// The row the caller just wrote was among them.
    written_deleted: bool = false,
};

/// A ranked diff_cache key and the target view it was built for.
const RankedSlot = struct { key: DiffKey, index: usize, view: priority.View, slot: usize };

/// Start the worker thread. It opens its own `Store` on that thread; a DB that
/// cannot be opened is reported through `status()` (`last_error = .db_open`)
/// and retried on the next wake. `allocator` must be thread-safe. It must also
/// outlive a worker that `stop` had to detach: that thread frees its state
/// through it whenever it finally exits, so the owner must not deinit the
/// allocator while an orphan may still be live.
pub fn start(allocator: Allocator, params: StartParams) !*PrefetchWorker {
    const self = try allocator.create(PrefetchWorker);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .config = try dupeConfig(allocator, params),
        .targets_arena = .init(allocator),
    };
    errdefer freeConfig(allocator, self.config);
    self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
    return self;
}

/// Main-thread cache read (DB only, never git): resolves the DiffKey through
/// merge_base_cache and returns the cached bytes (caller-owned), or null on
/// any miss. A hit bumps last_used_at to `now`: a flip is real use.
pub fn lookupCached(store: *Store, params: struct {
    allocator: Allocator,
    repo_id: i64,
    inputs: priority.KeyInputs,
    now: i64,
}) !?CachedDiff {
    const key = (try cachedKey(store, .{ .repo_id = params.repo_id, .inputs = params.inputs })) orelse return null;
    const bytes = (try store.getDiff(params.allocator, .{ .repo_id = params.repo_id, .key = key, .now = params.now })) orelse return null;
    return .{ .key = key, .bytes = bytes };
}

/// Main-thread "is this PR prefetched?" for the sidebar glyph. Does not bump
/// last_used_at.
pub fn isCached(store: *Store, params: struct { repo_id: i64, inputs: priority.KeyInputs }) !bool {
    const key = (try cachedKey(store, .{ .repo_id = params.repo_id, .inputs = params.inputs })) orelse return false;
    return store.hasDiff(params.repo_id, key);
}

// =============================================================================
// Worker thread
// =============================================================================

fn workerMain(self: *PrefetchWorker) void {
    runWorker(self);
    if (self.life.cmpxchgStrong(.running, .exited, .acq_rel, .acquire) == null) {
        skim_io.get().futexWake(Life, &self.life.raw, std.math.maxInt(u32));
    } else {
        // `stop` gave up on this thread and detached it; nobody else will
        // free the worker.
        destroyWorker(self);
    }
}

fn runWorker(self: *PrefetchWorker) void {
    var store = openStore(self) orelse return;
    defer store.close();

    var env = skim_io.environ().createMap(self.allocator) catch |err| {
        std.log.warn("prefetch: child env failed: {any}", .{err});
        failUntilStopped(self, null);
        return;
    };
    defer env.deinit();

    var round: Round = .init(self.allocator, self.config.threads_enabled);
    defer round.deinit();
    const ctx: Ctx = .{ .worker = self, .store = &store, .env = &env, .round = &round };

    const has_core_ssh_command = coreSshCommandSet(ctx) catch |err| switch (err) {
        error.GitMissing => {
            std.log.warn("prefetch: git executable not found; prefetch disabled", .{});
            failUntilStopped(self, .git_missing);
            return;
        },
        error.Stopped => return,
    };
    applyChildEnv(&env, .{ .has_core_ssh_command = has_core_ssh_command }) catch |err| {
        std.log.warn("prefetch: child env failed: {any}", .{err});
        failUntilStopped(self, null);
        return;
    };
    sweepStaleTmpPacks(ctx) catch |err| switch (err) {
        error.Stopped => return,
        else => std.log.warn("prefetch: sweeping stale tmp packs failed: {any}", .{err}),
    };

    while (!self.stop_requested.load(.acquire)) {
        const seen_wake = self.wake_seq.load(.acquire);
        refreshSnapshot(self, &round) catch |err| std.log.warn("prefetch: snapshot failed: {any}", .{err});
        _ = round.scratch.reset(.{ .retain_with_limit = scratch_retain_bytes });
        const focus = self.focus_number.load(.acquire);

        const ordered = priority.order(.{ .allocator = ctx.scratch(), .targets = round.targets, .focus_number = focus }) catch |err| {
            std.log.warn("prefetch: ordering failed: {any}", .{err});
            waitForWake(self, seen_wake);
            continue;
        };
        round.ordered = ordered;
        round.moveFocus(focus);
        if (round.rechecked_wake != seen_wake) {
            round.rechecked_wake = seen_wake;
            recheckDone(ctx);
        }
        const job = priority.nextJob(.{
            .targets = round.targets,
            .ordered = ordered,
            .states = round.states,
            .threads_enabled = round.threads_enabled,
        }) orelse {
            if (round.restoreStranded()) continue;
            publishIdle(ctx);
            waitForWake(self, seen_wake);
            continue;
        };
        executeJob(ctx, job) catch |err| switch (err) {
            error.GitMissing => {
                std.log.warn("prefetch: git executable not found; prefetch disabled", .{});
                failUntilStopped(self, .git_missing);
                return;
            },
            error.Stopped => return,
        };
    }
}

/// The worker's own connection. A failure is reported as `db_open` and
/// retried on every wake (new targets, a focus move, the idle timeout) until
/// it succeeds or the worker is stopped.
fn openStore(self: *PrefetchWorker) ?Store {
    while (!self.stop_requested.load(.acquire)) {
        const seen_wake = self.wake_seq.load(.acquire);
        if (Store.open(self.allocator, self.config.db_path)) |store| {
            return store;
        } else |err| {
            std.log.warn("prefetch: open db failed: {any}", .{err});
        }
        publishFailed(self, .db_open);
        waitForWake(self, seen_wake);
    }
    return null;
}

/// `git config --get core.sshCommand` in the repo: exit 0 with a value means
/// the user chose their own ssh. Anything else counts as unset.
fn coreSshCommandSet(ctx: Ctx) error{ GitMissing, Stopped }!bool {
    const result = runGit(ctx, .{ .argv = &.{ "git", "config", "--get", "core.sshCommand" } }) catch |err| switch (err) {
        error.GitMissing => return error.GitMissing,
        error.Stopped => return error.Stopped,
        else => {
            std.log.warn("prefetch: reading core.sshCommand failed: {any}", .{err});
            return false;
        },
    };
    return result.ok and trimOutput(result.stdout).len > 0;
}

fn executeJob(ctx: Ctx, job: priority.Job) error{ GitMissing, Stopped }!void {
    switch (job) {
        .fetch_batch => {
            publishStatus(ctx, .fetching);
            try fetchBatch(ctx, ctx.round.ordered);
        },
        .run => |run| {
            const state = &ctx.round.states[run.index];
            const outcome = switch (run.kind) {
                .diff => outcome: {
                    publishStatus(ctx, .diffing);
                    state.diff = try diffJob(ctx, .{ .index = run.index, .view = .pr });
                    break :outcome state.diff;
                },
                .whole_stack => outcome: {
                    publishStatus(ctx, .diffing);
                    state.whole_stack = try diffJob(ctx, .{ .index = run.index, .view = .whole_stack });
                    break :outcome state.whole_stack;
                },
                .since_seen => outcome: {
                    publishStatus(ctx, .diffing);
                    state.since_seen = try diffJob(ctx, .{ .index = run.index, .view = .since_seen });
                    break :outcome state.since_seen;
                },
                .threads => outcome: {
                    publishStatus(ctx, .threads);
                    state.threads = try threadsJob(ctx, run.index);
                    break :outcome state.threads;
                },
            };
            if (outcome == .failed) ctx.round.failures += 1;
        },
    }
}

/// Make sure the commits the capped, not-yet-attempted targets need exist
/// locally: `git cat-file --batch-check` finds the missing ones and a single
/// batched `git fetch` asks origin for them. Every candidate counts as
/// attempted whatever happens; a failed fetch never blocks diff jobs for
/// commits that are already present.
fn fetchBatch(ctx: Ctx, ordered: []const usize) error{ GitMissing, Stopped }!void {
    const round = ctx.round;
    const capped = priority.capBatch(ordered, priority.fetch_cap);
    defer for (capped) |i| {
        round.states[i].fetch_attempted = true;
    };

    const wanted = collectWanted(ctx, capped) catch |err| {
        std.log.warn("prefetch: fetch planning failed: {any}", .{err});
        return;
    };
    if (wanted.len == 0) return;

    var missing = missingObjects(ctx, wanted) catch |err| switch (err) {
        error.GitMissing => return error.GitMissing,
        error.Stopped => return error.Stopped,
        else => {
            std.log.warn("prefetch: git cat-file failed: {any}", .{err});
            return;
        },
    };
    defer missing.deinit(ctx.scratch());

    pinPresentHeads(ctx, .{ .wanted = wanted, .missing = &missing }) catch |err| switch (err) {
        error.GitMissing => return error.GitMissing,
        error.Stopped => return error.Stopped,
        else => std.log.warn("prefetch: pinning local PR refs failed: {any}", .{err}),
    };

    const refspecs = buildRefspecs(ctx, .{ .wanted = wanted, .missing = &missing }) catch |err| {
        std.log.warn("prefetch: refspec planning failed: {any}", .{err});
        return;
    };
    if (refspecs.len == 0) return;

    switch (try fetchWithFallback(ctx, refspecs)) {
        .ok, .partial => {},
        .failed => round.noteError(.fetch_failed),
    }
}

/// Every well-formed oid the not-yet-attempted targets' diffs need, with
/// where to fetch it.
fn collectWanted(ctx: Ctx, capped: []const usize) ![]WantedOid {
    var wanted: std.ArrayList(WantedOid) = .empty;
    const scratch = ctx.scratch();
    for (capped) |i| {
        if (ctx.round.states[i].fetch_attempted) continue;
        const target = ctx.round.targets[i];
        if (!pullBackedOff(ctx.round, target.number)) {
            try appendWanted(.{ .allocator = scratch, .list = &wanted, .item = .{ .oid = target.head_oid, .source = .{ .pull = target.number } } });
        }
        switch (target.base) {
            .trunk => |trunk| try appendWanted(.{ .allocator = scratch, .list = &wanted, .item = .{
                .oid = trunk.oid,
                .source = .{ .branch = .{ .name = target.base_ref, .index = i, .view = .pr } },
            } }),
            .parent_pr => |parent| if (!pullBackedOff(ctx.round, parent.number)) try appendWanted(.{ .allocator = scratch, .list = &wanted, .item = .{
                .oid = parent.head_oid,
                .source = .{ .pull = parent.number },
            } }),
        }
        if (target.whole_stack) |stack| try appendWanted(.{ .allocator = scratch, .list = &wanted, .item = .{
            .oid = stack.trunk_oid,
            .source = .{ .branch = .{ .name = stack.trunk_ref, .index = i, .view = .whole_stack } },
        } });
    }
    return wanted.items;
}

/// PR `number`'s pull ref was missing on origin at its current stamp.
fn pullBackedOff(round: *const Round, number: u32) bool {
    const target = targetByNumber(round, number) orelse return false;
    return round.backoff.blocks(.{ .number = number, .stamp = pullStamp(target) });
}

/// A failed fetch that blamed a missing `refs/pull/N/head` backs PR N off
/// at its current stamp.
fn notePullMissing(round: *Round, stderr: []const u8) void {
    const remote_ref = plan.missingRemoteRef(stderr) orelse return;
    const number = plan.missingPullNumber(remote_ref) orelse return;
    const target = targetByNumber(round, number) orelse return;
    round.backoff.record(round.allocator, .{ .number = number, .stamp = pullStamp(target) }) catch |err| {
        std.log.warn("prefetch #{d}: recording the missing pull ref failed: {any}", .{ number, err });
    };
}

fn targetByNumber(round: *const Round, number: u32) ?*const Target {
    for (round.targets) |*target| {
        if (target.number == number) return target;
    }
    return null;
}

fn pullStamp(target: *const Target) plan.FetchBackoff.Stamp {
    return plan.FetchBackoff.Stamp.of(.{ .head_oid = target.head_oid, .updated_at = target.updated_at });
}

fn appendWanted(params: struct { allocator: Allocator, list: *std.ArrayList(WantedOid), item: WantedOid }) !void {
    if (!plan.isOid(params.item.oid)) return;
    try params.list.append(params.allocator, params.item);
}

/// Refspecs for the wanted commits that are missing locally. A branch name
/// that fails `validateRefName` never reaches argv: the job that needed it is
/// marked skipped instead.
fn buildRefspecs(ctx: Ctx, params: struct { wanted: []const WantedOid, missing: *const plan.MissingSet }) ![][]const u8 {
    var refspecs: std.ArrayList([]const u8) = .empty;
    for (params.wanted) |item| {
        if (!params.missing.contains(item.oid)) continue;
        switch (item.source) {
            .pull => |number| try refspecs.append(ctx.scratch(), try github.buildPullRefspec(ctx.scratch(), number)),
            .branch => |branch| {
                const spec = github.buildBaseRefspec(ctx.scratch(), branch.name) catch |err| switch (err) {
                    error.InvalidRefName => {
                        const target = ctx.round.targets[branch.index];
                        std.log.warn("prefetch #{d}: rejected base ref name for the {s} diff: {any}", .{ target.number, @tagName(branch.view), err });
                        viewOutcome(&ctx.round.states[branch.index], branch.view).* = .skipped;
                        continue;
                    },
                    else => return err,
                };
                try refspecs.append(ctx.scratch(), spec);
            },
        }
    }
    return refspecs.items;
}

/// A PR head that is already local is never fetched, so nothing would create
/// or advance its `refs/skim/pr-<n>`, which keeps the head reachable and is
/// what the review entry diffs. Create the absent refs at the target's head,
/// and move an existing one forward when its commit is an ancestor of that
/// head. Any other existing ref is left alone: the review path may have just
/// fetched a newer head than this round's snapshot, and moving the ref back
/// would show a stale diff. `create` and the old-oid check of `update` refuse
/// a ref another fetch moved in the meantime instead of overwriting it.
fn pinPresentHeads(ctx: Ctx, params: struct { wanted: []const WantedOid, missing: *const plan.MissingSet }) !void {
    const listed = try runGit(ctx, .{ .argv = &.{ "git", "for-each-ref", "--format=%(refname) %(objectname)", "refs/skim/" } });
    if (!listed.ok) {
        std.log.warn("prefetch: git for-each-ref failed: {s}", .{trimOutput(listed.stderr)});
        return error.ListRefsFailed;
    }
    var commands: std.ArrayList([]const u8) = .empty;
    var pinned: std.ArrayList(u32) = .empty;
    for (params.wanted) |item| {
        if (params.missing.contains(item.oid)) continue;
        const number = switch (item.source) {
            .pull => |number| number,
            .branch => continue,
        };
        if (std.mem.indexOfScalar(u32, pinned.items, number) != null) continue;
        try pinned.append(ctx.scratch(), number);
        const ref = try github.localPullRef(ctx.scratch(), number);
        const command = if (listedOid(listed.stdout, ref)) |old| blk: {
            if (std.ascii.eqlIgnoreCase(old, item.oid)) continue;
            if (!try isAncestor(ctx, .{ .ancestor = old, .descendant = item.oid })) continue;
            break :blk try std.fmt.allocPrint(ctx.scratch(), "update {s} {s} {s}\n", .{ ref, item.oid, old });
        } else try std.fmt.allocPrint(ctx.scratch(), "create {s} {s}\n", .{ ref, item.oid });
        try commands.append(ctx.scratch(), command);
    }
    if (commands.items.len == 0) return;
    if (try updateRefs(ctx, try std.mem.concat(ctx.scratch(), u8, commands.items))) return;
    if (commands.items.len == 1) return error.UpdateRefFailed;
    // One raced or locked ref fails the whole transaction: pin the rest one
    // ref at a time.
    var failed = false;
    for (commands.items) |command| {
        if (!try updateRefs(ctx, command)) failed = true;
    }
    if (failed) return error.UpdateRefFailed;
}

/// `git update-ref --stdin` with `commands` as one transaction. False (and
/// logged) when git refused it.
fn updateRefs(ctx: Ctx, commands: []const u8) !bool {
    const result = try runGit(ctx, .{ .argv = &.{ "git", "update-ref", "--stdin" }, .stdin = commands });
    if (!result.ok) std.log.warn("prefetch: git update-ref failed: {s}", .{trimOutput(result.stderr)});
    return result.ok;
}

/// `git merge-base --is-ancestor`: exit 1 is a plain no; anything else
/// failed and is logged as one.
fn isAncestor(ctx: Ctx, pair: struct { ancestor: []const u8, descendant: []const u8 }) !bool {
    const result = try runGit(ctx, .{ .argv = &.{ "git", "merge-base", "--is-ancestor", pair.ancestor, pair.descendant } });
    if (result.ok) return true;
    if (result.exit_code != 1) std.log.warn("prefetch: git merge-base --is-ancestor {s} {s} failed: {s}", .{ pair.ancestor, pair.descendant, trimOutput(result.stderr) });
    return false;
}

/// The oid `ref` points at in a `%(refname) %(objectname)` listing.
fn listedOid(listing: []const u8, ref: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        if (std.mem.eql(u8, line[0..space], ref)) return line[space + 1 ..];
    }
    return null;
}

/// Delete the `tmp_pack_*` files fetches killed mid-transfer left in the
/// pack directory (`plan.isStaleTmpPack`); they are never cleaned otherwise
/// while auto maintenance is off.
fn sweepStaleTmpPacks(ctx: Ctx) !void {
    const result = try runGit(ctx, .{ .argv = &.{ "git", "rev-parse", "--git-path", "objects/pack" } });
    if (!result.ok) {
        std.log.warn("prefetch: git rev-parse --git-path failed: {s}", .{trimOutput(result.stderr)});
        return error.PackDirUnknown;
    }
    const reported = trimOutput(result.stdout);
    const pack_dir = if (std.fs.path.isAbsolute(reported)) reported else try std.fs.path.join(ctx.scratch(), &.{ ctx.config().repo_root, reported });
    const io = skim_io.get();
    var dir = std.Io.Dir.cwd().openDir(io, pack_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    const now_ns = skim_io.nanoTimestamp();
    var stale: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        if (!plan.isStaleTmpPack(.{ .name = entry.name, .mtime_ns = stat.mtime.toNanoseconds(), .now_ns = now_ns })) continue;
        try stale.append(ctx.scratch(), try ctx.scratch().dupe(u8, entry.name));
    }
    for (stale.items) |name| {
        dir.deleteFile(io, name) catch |err| std.log.warn("prefetch: removing {s} failed: {any}", .{ name, err });
    }
}

/// `git cat-file --batch-check` over the wanted oids. Input is at most
/// 3 * fetch_cap lines and the reply is far below a pipe buffer, so writing
/// all input before reading cannot deadlock.
fn missingObjects(ctx: Ctx, wanted: []const WantedOid) !plan.MissingSet {
    var input: std.ArrayList(u8) = .empty;
    for (wanted) |item| {
        try input.appendSlice(ctx.scratch(), item.oid);
        try input.append(ctx.scratch(), '\n');
    }
    const result = try runGit(ctx, .{ .argv = &.{ "git", "cat-file", "--batch-check" }, .stdin = input.items });
    if (!result.ok) {
        std.log.warn("prefetch: git cat-file failed: {s}", .{trimOutput(result.stderr)});
        return error.CatFileFailed;
    }
    return plan.parseBatchCheck(ctx.scratch(), result.stdout);
}

/// One bad ref fails the whole batch: a ref origin does not have (a closed
/// PR's dropped pull ref, a deleted base branch; git names only the first) or
/// a local ref git cannot lock (a stale remote-tracking ref in the way). Drop
/// the refs git named and retry the rest (up to `max_drop_retries` times),
/// then fetch whatever is left one refspec at a time. Any other failure
/// (network, auth, timeout) would fail every refspec alike, so it gets no
/// retries.
fn fetchWithFallback(ctx: Ctx, refspecs: [][]const u8) error{ GitMissing, Stopped }!FetchOutcome {
    var remaining = refspecs;
    var drops: usize = 0;
    while (remaining.len > 0) {
        const result = try runFetch(ctx, remaining);
        if (result.ok) return if (drops == 0) .ok else .partial;
        notePullMissing(ctx.round, result.stderr);
        const kept = dropFailedRefspecs(remaining, result.stderr) orelse {
            std.log.warn("prefetch: git fetch failed: {s}", .{trimOutput(result.stderr)});
            return .failed;
        };
        if (drops == max_drop_retries or kept == remaining.len) break;
        remaining = remaining[0..kept];
        drops += 1;
    }
    for (remaining) |spec| {
        if (ctx.worker.stop_requested.load(.acquire)) return error.Stopped;
        const result = try runFetch(ctx, &.{spec});
        if (result.ok) continue;
        notePullMissing(ctx.round, result.stderr);
        std.log.warn("prefetch: git fetch {s} failed: {s}", .{ spec, trimOutput(result.stderr) });
    }
    return .partial;
}

/// Compacts `refspecs` past the refs a failed fetch blamed and returns the new
/// length, or null when the failure names no ref.
fn dropFailedRefspecs(refspecs: [][]const u8, stderr: []const u8) ?usize {
    if (plan.missingRemoteRef(stderr)) |missing| {
        std.log.info("prefetch: origin has no {s}; retrying the batch without it", .{missing});
        return plan.dropRefspec(refspecs, missing);
    }
    if (plan.refLockHeld(stderr)) {
        // Another git process (the user's, or a skim in another terminal)
        // holds a ref lock: contention, not a bad ref, so nothing is dropped.
        std.log.warn("prefetch: git fetch hit a ref lock held by another git process: {s}", .{trimOutput(stderr)});
        return null;
    }
    const kept = plan.dropLockedRefspecs(refspecs, stderr);
    if (kept == refspecs.len) return null;
    std.log.info("prefetch: git could not lock {d} local ref(s); retrying the batch without them: {s}", .{ refspecs.len - kept, trimOutput(stderr) });
    return kept;
}

/// A fetch that cannot run or does not finish in time is a failed fetch.
fn runFetch(ctx: Ctx, refspecs: []const []const u8) error{ GitMissing, Stopped }!ChildResult {
    const argv = plan.buildFetchArgv(ctx.scratch(), refspecs) catch |err| {
        std.log.warn("prefetch: git fetch argv failed: {any}", .{err});
        return failedResult();
    };
    return runGit(ctx, .{ .argv = argv }) catch |err| switch (err) {
        error.GitMissing => error.GitMissing,
        error.Stopped => error.Stopped,
        else => {
            std.log.warn("prefetch: git fetch did not complete: {any}", .{err});
            return failedResult();
        },
    };
}

fn failedResult() ChildResult {
    return .{ .ok = false, .exit_code = 1, .stdout = &.{}, .stderr = &.{} };
}

fn diffJob(ctx: Ctx, params: struct { index: usize, view: priority.View }) error{ GitMissing, Stopped }!priority.Outcome {
    const target = ctx.round.targets[params.index];
    return cacheDiff(ctx, .{ .target = target, .view = params.view }) catch |err| switch (err) {
        error.GitMissing => error.GitMissing,
        error.Stopped => error.Stopped,
        error.StdoutTooLong => outcome: {
            std.log.info("prefetch #{d}: {s} diff exceeds the cache limit; not cached", .{ target.number, @tagName(params.view) });
            break :outcome .skipped;
        },
        else => outcome: {
            std.log.warn("prefetch #{d}: {s} diff failed: {any}", .{ target.number, @tagName(params.view), err });
            break :outcome .failed;
        },
    };
}

/// (base tip, head) → merge base (cached in merge_base_cache) → DiffKey →
/// `git diff` bytes in diff_cache, unless that key is already cached. A hit
/// leaves last_used_at alone: prefetch is not use. A row that eviction
/// deletes as soon as it is written is `.evicted`: it lies past the boundary.
/// `.since_seen` is diffed only on a fast-forward (merge base == seen head);
/// for rewritten history the merge_base_cache row is the whole answer.
fn cacheDiff(ctx: Ctx, params: struct { target: Target, view: priority.View }) !priority.Outcome {
    const target = params.target;
    const inputs = priority.diffKeyFor(target, params.view) orelse return .skipped;
    if (!plan.isOid(inputs.base_tip_oid) or !plan.isOid(inputs.head_oid)) {
        std.log.warn("prefetch #{d}: malformed oid; {s} diff skipped", .{ target.number, @tagName(params.view) });
        return .skipped;
    }
    const resolved = try resolveKey(ctx, inputs);
    if (params.view == .since_seen and !std.ascii.eqlIgnoreCase(&resolved.key.merge_base_oid, inputs.base_tip_oid)) {
        if (resolved.computed) ctx.bumpGeneration();
        return .skipped;
    }
    const repo_id = ctx.config().repo_id;
    if (try ctx.store.hasDiff(repo_id, resolved.key)) {
        // A new merge_base_cache row is enough to flip `isCached` for this PR.
        if (resolved.computed) ctx.bumpGeneration();
        return .done;
    }

    const result = try runGit(ctx, .{
        .argv = &.{ "git", "diff", "--no-color", "--no-ext-diff", "-U10", &resolved.key.merge_base_oid, &resolved.key.head_oid },
        .stdout_limit = max_diff_bytes,
    });
    if (!result.ok) {
        std.log.warn("prefetch #{d}: git diff failed: {s}", .{ target.number, trimOutput(result.stderr) });
        return error.GitDiffFailed;
    }
    try ctx.store.putDiff(.{ .repo_id = repo_id, .key = resolved.key, .bytes = result.stdout, .now = skim_io.timestamp() });
    const evicted = evict(ctx, resolved.key);
    if (!evicted.written_deleted) {
        ctx.bumpGeneration();
        return .done;
    }
    // Written and deleted again: the cache only changed if other rows went too.
    if (evicted.deleted > 1) ctx.bumpGeneration();
    return .evicted;
}

fn resolveKey(ctx: Ctx, inputs: priority.KeyInputs) !KeyResolution {
    const repo_id = ctx.config().repo_id;
    const head = plan.parseOid(inputs.head_oid) orelse return error.InvalidOid;
    const pair: store_mod.OidPair = .{ .base_tip_oid = inputs.base_tip_oid, .head_oid = inputs.head_oid };
    if (try ctx.store.getMergeBase(repo_id, pair)) |merge_base| {
        return .{ .key = .{ .merge_base_oid = merge_base, .head_oid = head }, .computed = false };
    }

    const result = try runGit(ctx, .{ .argv = &.{ "git", "merge-base", inputs.base_tip_oid, inputs.head_oid } });
    if (!result.ok) {
        std.log.warn("prefetch: git merge-base {s} {s} failed: {s}", .{ inputs.base_tip_oid, inputs.head_oid, trimOutput(result.stderr) });
        return error.MergeBaseFailed;
    }
    const merge_base = plan.parseOid(trimOutput(result.stdout)) orelse return error.MergeBaseFailed;
    try ctx.store.putMergeBase(repo_id, .{ .base_tip_oid = inputs.base_tip_oid, .head_oid = inputs.head_oid, .merge_base_oid = &merge_base });
    return .{ .key = .{ .merge_base_oid = merge_base, .head_oid = head }, .computed = true };
}

/// Refresh the PR's review-thread payload unless thread_cache already holds
/// one for its current `updated_at`. A payload must parse before it is
/// stored, so a partial or garbage response never lands in the cache.
fn threadsJob(ctx: Ctx, index: usize) error{Stopped}!priority.Outcome {
    const target = ctx.round.targets[index];
    const config = ctx.config();
    const fresh = ctx.store.threadsFresh(config.repo_id, .{ .number = target.number, .pr_updated_at = target.updated_at }) catch |err| {
        std.log.warn("prefetch #{d}: thread cache read failed: {any}", .{ target.number, err });
        return .failed;
    };
    if (fresh) return .done;

    const argv = github.reviewDataArgv(ctx.scratch(), .{
        .owner_repo = .{ .owner = config.owner, .repo = config.name },
        .number = target.number,
        .gh_bin = config.gh_bin,
    }) catch |err| {
        std.log.warn("prefetch #{d}: gh argv failed: {any}", .{ target.number, err });
        return .failed;
    };
    const result = runChild(ctx, .{ .argv = argv, .bin = config.gh_bin, .stdout_limit = max_gh_output_bytes }) catch |err| {
        std.log.warn("prefetch #{d}: gh did not complete: {any}", .{ target.number, err });
        return switch (err) {
            error.Stopped => error.Stopped,
            error.ExecutableMissing => ghFailed(ctx, .{ .kind = .not_installed, .disable = true }),
            // A gh that hung once would hang (and cost a full timeout) again.
            error.Timeout => ghFailed(ctx, .{ .kind = .network, .disable = true }),
            else => ghFailed(ctx, .{ .kind = .other, .disable = false }),
        };
    };
    if (!result.ok) {
        const kind = github.classifyGhFailure(result.exit_code, result.stderr);
        // Every remaining call would fail the same way this version.
        const disable = switch (kind) {
            .not_installed, .not_authenticated, .rate_limited => true,
            // The repository itself, not this one PR, is unknown to gh.
            .not_found => std.mem.indexOf(u8, result.stderr, "Could not resolve to a Repository") != null,
            .network, .other => false,
        };
        if (disable) {
            std.log.warn("prefetch #{d}: review threads disabled for {s}/{s} this target list ({s}): {s}", .{ target.number, config.owner, config.name, @tagName(kind), trimOutput(result.stderr) });
        } else {
            std.log.warn("prefetch #{d}: review threads not fetched ({s}): {s}", .{ target.number, @tagName(kind), trimOutput(result.stderr) });
        }
        return ghFailed(ctx, .{ .kind = kind, .disable = disable });
    }
    const json = result.stdout;

    var parsed = review_parse.parsePrDetails(ctx.scratch(), json) catch |err| {
        std.log.warn("prefetch #{d}: discarding unparseable review payload: {any}", .{ target.number, err });
        return .failed;
    };
    parsed.deinit();

    ctx.store.putThreads(.{
        .repo_id = config.repo_id,
        .number = target.number,
        .pr_updated_at = target.updated_at,
        .json = json,
        .now = skim_io.timestamp(),
    }) catch |err| {
        std.log.warn("prefetch #{d}: thread cache write failed: {any}", .{ target.number, err });
        return .failed;
    };
    ctx.bumpGeneration();
    return .done;
}

fn ghFailed(ctx: Ctx, params: struct { kind: github.GhErrorKind, disable: bool }) priority.Outcome {
    ctx.round.gh_error = params.kind;
    ctx.round.noteError(.gh_failed);
    if (params.disable) ctx.round.threads_enabled = false;
    return .failed;
}

/// Another process sharing the DB (its own eviction, a cache clear) can
/// delete rows this worker recorded as `.done`. Once per wake (a focus move,
/// new targets, an explicit nudge; not the idle timeout, so two idle workers
/// never trade rows on a timer), each `.done` diff view whose row is gone
/// goes back to pending, and `restoreStranded` may run again for this focus.
/// A re-pended view past the room left is written once, evicted, and moves
/// the boundary, as on a cold start.
fn recheckDone(ctx: Ctx) void {
    const repended = rependMissing(ctx) catch |err| {
        std.log.warn("prefetch: diff cache recheck failed: {any}", .{err});
        return;
    };
    if (repended > 0) ctx.round.stranded_checked = false;
}

fn rependMissing(ctx: Ctx) !usize {
    const round = ctx.round;
    const repo_id = ctx.config().repo_id;
    var count: usize = 0;
    for (round.targets, round.states) |target, *state| {
        for (std.enums.values(priority.View)) |view| {
            const outcome = viewOutcome(state, view);
            if (outcome.* != .done) continue;
            const inputs = priority.diffKeyFor(target, view) orelse continue;
            const key = try cachedKey(ctx.store, .{ .repo_id = repo_id, .inputs = inputs });
            if (key != null and try ctx.store.hasDiff(repo_id, key.?)) continue;
            outcome.* = .pending;
            count += 1;
        }
    }
    return count;
}

/// Bring the diff cache under budget, deleting the rows farthest from the
/// cursor first: rows no current target maps to go before any ranked row,
/// and ranked rows go from the far end of `round.ordered`. The views of the
/// nearest `config.keep_nearest` targets are never deleted. Every deleted
/// ranked view becomes `.evicted`, the boundary moves to the nearest of them,
/// and pending views at or past it become `.evicted` without running: each
/// would be written only to be deleted again.
fn evict(ctx: Ctx, written: ?DiffKey) EvictResult {
    return evictRanked(ctx, written) catch |err| {
        std.log.warn("prefetch: diff cache eviction failed: {any}", .{err});
        return .{};
    };
}

fn evictRanked(ctx: Ctx, written: ?DiffKey) !EvictResult {
    const config = ctx.config();
    if (try ctx.store.diffCacheSize(config.repo_id) <= config.budget_bytes) return .{};
    const slots = try rankedSlots(ctx);
    const keys = try ctx.scratch().alloc(DiffKey, slots.len);
    var keep_nearest: usize = 0;
    for (slots, keys) |slot, *key| {
        key.* = slot.key;
        if (slot.slot < config.keep_nearest * view_count) keep_nearest += 1;
    }
    const deleted = try ctx.store.evictDiffsRanked(ctx.scratch(), .{
        .repo_id = config.repo_id,
        .budget_bytes = config.budget_bytes,
        .ranked = keys,
        .keep_nearest = keep_nearest,
    });
    var result: EvictResult = .{ .deleted = deleted.len };
    var nearest: ?usize = null;
    for (deleted) |key| {
        if (written != null and std.meta.eql(written.?, key)) result.written_deleted = true;
        if (markEvicted(.{ .states = ctx.round.states, .slots = slots, .key = key })) |slot| nearest = @min(nearest orelse slot, slot);
    }
    if (nearest) |boundary| {
        ctx.round.boundary = boundary;
        evictPastBoundary(ctx.round, boundary);
    }
    return result;
}

/// Every view whose slot holds `key` becomes `.evicted`. Returns the nearest
/// of those slots, or null when no current target maps to `key`.
fn markEvicted(params: struct { states: []priority.JobState, slots: []const RankedSlot, key: DiffKey }) ?usize {
    var nearest: ?usize = null;
    for (params.slots) |slot| {
        if (!std.meta.eql(slot.key, params.key)) continue;
        viewOutcome(&params.states[slot.index], slot.view).* = .evicted;
        nearest = @min(nearest orelse slot.slot, slot.slot);
    }
    return nearest;
}

/// `.evicted` views ranked before `below` go back to pending: their rows
/// may fit again. Returns how many did.
fn repend(round: *Round, below: usize) usize {
    var count: usize = 0;
    for (round.ordered, 0..) |index, position| {
        for (std.enums.values(priority.View)) |view| {
            const outcome = viewOutcome(&round.states[index], view);
            if (outcome.* != .evicted or slotOf(position, view) >= below) continue;
            outcome.* = .pending;
            count += 1;
        }
    }
    return count;
}

fn evictPastBoundary(round: *Round, boundary: usize) void {
    for (round.ordered, 0..) |index, position| {
        for (std.enums.values(priority.View)) |view| {
            const outcome = viewOutcome(&round.states[index], view);
            if (outcome.* == .pending and slotOf(position, view) >= boundary) outcome.* = .evicted;
        }
    }
}

/// The cached keys of every view of every target, nearest the cursor first.
/// Keys whose merge base is not cached have no row to keep.
fn rankedSlots(ctx: Ctx) ![]RankedSlot {
    var slots: std.ArrayList(RankedSlot) = .empty;
    for (ctx.round.ordered, 0..) |index, position| {
        const target = ctx.round.targets[index];
        for (std.enums.values(priority.View)) |view| {
            const inputs = priority.diffKeyFor(target, view) orelse continue;
            const key = (try cachedKey(ctx.store, .{ .repo_id = ctx.config().repo_id, .inputs = inputs })) orelse continue;
            try slots.append(ctx.scratch(), .{ .key = key, .index = index, .view = view, .slot = slotOf(position, view) });
        }
    }
    return slots.items;
}

/// A view's place in the eviction ranking: every view of a target sits
/// between the nearer and the farther targets, in `View` order.
fn slotOf(position: usize, view: priority.View) usize {
    return position * view_count + @intFromEnum(view);
}

/// The JobState field that tracks `view`'s diff.
fn viewOutcome(state: *priority.JobState, view: priority.View) *priority.Outcome {
    return switch (view) {
        .pr => &state.diff,
        .whole_stack => &state.whole_stack,
        .since_seen => &state.since_seen,
    };
}

/// `runChild` with `config.git_bin`.
fn runGit(ctx: Ctx, params: struct {
    argv: []const []const u8,
    stdin: ?[]const u8 = null,
    stdout_limit: usize = max_git_output_bytes,
}) !ChildResult {
    return runChild(ctx, .{
        .argv = params.argv,
        .bin = ctx.config().git_bin,
        .stdin = params.stdin,
        .stdout_limit = params.stdout_limit,
    }) catch |err| switch (err) {
        error.ExecutableMissing => error.GitMissing,
        else => err,
    };
}

/// Private child runner: cwd = repo root, the worker's child env, argv[0]
/// swapped for `params.bin`, `params.stdin` written up front, run through
/// `child_group.run` on the worker's slot so `stop` can kill everything it
/// started (ssh, remote helpers, gh's own children). Output is scratch-owned.
/// Errors: `Stopped` (stop was requested, before or during the run),
/// `ExecutableMissing`, `StdoutTooLong` (over `params.stdout_limit`),
/// `StderrTooLong`, `Timeout` (over `config.child_timeout_ns`). Never logs at
/// .err and never prints to stderr (that would corrupt the TUI).
fn runChild(ctx: Ctx, params: struct {
    argv: []const []const u8,
    bin: []const u8,
    stdin: ?[]const u8 = null,
    stdout_limit: usize = max_git_output_bytes,
}) !ChildResult {
    if (ctx.worker.stop_requested.load(.acquire)) return error.Stopped;
    const argv = try ctx.scratch().dupe([]const u8, params.argv);
    argv[0] = params.bin;
    const output = child_group.run(.{
        .allocator = ctx.scratch(),
        .argv = argv,
        .cwd = ctx.config().repo_root,
        .environ_map = ctx.env,
        .stdin = params.stdin,
        .stdout_limit = params.stdout_limit,
        .stderr_limit = max_git_output_bytes,
        .timeout = .{ .total_ns = ctx.config().child_timeout_ns },
        .slot = &ctx.worker.child,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.ExecutableMissing,
        error.Canceled => return error.Stopped,
        else => |e| return e,
    };
    const exit_code: u32 = switch (output.term) {
        .exited => |code| code,
        else => 1,
    };
    return .{ .ok = exit_code == 0, .exit_code = exit_code, .stdout = output.stdout, .stderr = output.stderr };
}

/// Copy the shared target list into the round when its version changed, and
/// start that version's bookkeeping from scratch. Already-cached targets
/// resolve as hits with two SQL lookups and no subprocess.
fn refreshSnapshot(self: *PrefetchWorker, round: *Round) !void {
    self.targets_mutex.lockUncancelable(skim_io.get());
    defer self.targets_mutex.unlock(skim_io.get());
    if (self.targets_version == round.version) return;

    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    errdefer arena.deinit();
    const targets = try cloneTargets(arena.allocator(), self.targets);
    const states = try arena.allocator().alloc(priority.JobState, targets.len);
    @memset(states, .{});

    round.arena.deinit();
    round.arena = arena;
    round.version = self.targets_version;
    round.targets = targets;
    round.states = states;
    round.threads_enabled = self.config.threads_enabled;
    round.evicted = false;
    round.boundary = null;
    round.stranded_checked = false;
    round.failures = 0;
    round.first_error = null;
    round.gh_error = null;
}

/// Evicts once per targets version and once per focus move before reporting
/// idle, so the budget holds around the current cursor even when a round
/// wrote nothing (every key already cached). Version 0 (no target list yet)
/// never evicts.
fn publishIdle(ctx: Ctx) void {
    if (!ctx.round.evicted and ctx.round.version > 0) {
        ctx.round.evicted = true;
        if (evict(ctx, null).deleted > 0) ctx.bumpGeneration();
    }
    publishStatus(ctx, .idle);
}

fn publishStatus(ctx: Ctx, phase: Phase) void {
    const round = ctx.round;
    var diffs_ready: u32 = 0;
    for (round.states) |state| {
        if (state.diff == .done) diffs_ready += 1;
    }
    setStatus(ctx.worker, .{
        .phase = phase,
        .targets_version = round.version,
        .focus = round.focus,
        .targets = @intCast(round.targets.len),
        .diffs_ready = diffs_ready,
        .failures = round.failures,
        .last_error = round.first_error,
        .gh_error = round.gh_error,
    });
}

/// Report `failed` for whatever targets version is current.
fn publishFailed(self: *PrefetchWorker, last_error: ?LastError) void {
    self.targets_mutex.lockUncancelable(skim_io.get());
    const version = self.targets_version;
    self.targets_mutex.unlock(skim_io.get());
    setStatus(self, .{
        .phase = .failed,
        .targets_version = version,
        .focus = self.focus_number.load(.acquire),
        .last_error = last_error,
    });
}

fn setStatus(self: *PrefetchWorker, value: Status) void {
    self.status_mutex.lockUncancelable(skim_io.get());
    defer self.status_mutex.unlock(skim_io.get());
    self.status_value = value;
}

fn failUntilStopped(self: *PrefetchWorker, last_error: ?LastError) void {
    while (!self.stop_requested.load(.acquire)) {
        const seen_wake = self.wake_seq.load(.acquire);
        publishFailed(self, last_error);
        waitForWake(self, seen_wake);
    }
}

fn wake(self: *PrefetchWorker) void {
    _ = self.wake_seq.fetchAdd(1, .release);
    skim_io.get().futexWake(u32, &self.wake_seq.raw, 1);
}

/// Returns when `wake_seq` moves past `seen`, on timeout, or spuriously; the
/// caller just loops back to `nextJob`.
fn waitForWake(self: *PrefetchWorker, seen: u32) void {
    if (self.stop_requested.load(.acquire)) return;
    skim_io.get().futexWaitTimeout(u32, &self.wake_seq.raw, seen, .{
        .duration = .{ .raw = .{ .nanoseconds = idle_wait_ns }, .clock = .awake },
    }) catch {};
}

/// True once the thread has left `runWorker`; false after `stop_wait_ns`.
fn waitForExit(self: *PrefetchWorker) bool {
    const io = skim_io.get();
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .raw = .{ .nanoseconds = stop_wait_ns }, .clock = .awake });
    while (self.life.load(.acquire) == .running) {
        if (deadline.compare(.lte, .now(io, .awake))) return false;
        io.futexWaitTimeout(Life, &self.life.raw, .running, .{ .deadline = deadline }) catch {};
    }
    return true;
}

fn destroyWorker(self: *PrefetchWorker) void {
    const allocator = self.allocator;
    self.targets_arena.deinit();
    freeConfig(allocator, self.config);
    allocator.destroy(self);
}

/// Adds to the user's environment: no credential prompt on /dev/tty
/// underneath the TUI, C locale (stderr is parsed), and non-interactive ssh.
/// The ssh default is only set when the user has not chosen an ssh command
/// through GIT_SSH_COMMAND, GIT_SSH or core.sshCommand, because
/// GIT_SSH_COMMAND would override all three.
fn applyChildEnv(env: *EnvMap, params: struct { has_core_ssh_command: bool }) !void {
    try env.put("GIT_TERMINAL_PROMPT", "0");
    try env.put("LC_ALL", "C");
    if (params.has_core_ssh_command or env.get("GIT_SSH_COMMAND") != null or env.get("GIT_SSH") != null) return;
    try env.put("GIT_SSH_COMMAND", default_ssh_command);
}

fn cachedKey(store: *Store, params: struct { repo_id: i64, inputs: priority.KeyInputs }) !?DiffKey {
    const head = plan.parseOid(params.inputs.head_oid) orelse return null;
    const pair: store_mod.OidPair = .{ .base_tip_oid = params.inputs.base_tip_oid, .head_oid = params.inputs.head_oid };
    const merge_base = (try store.getMergeBase(params.repo_id, pair)) orelse return null;
    return .{ .merge_base_oid = merge_base, .head_oid = head };
}

fn cloneTargets(arena: Allocator, targets: []const Target) ![]Target {
    const copy = try arena.alloc(Target, targets.len);
    for (targets, copy) |source, *dest| {
        dest.* = .{
            .number = source.number,
            .head_ref = try arena.dupe(u8, source.head_ref),
            .base_ref = try arena.dupe(u8, source.base_ref),
            .head_oid = try arena.dupe(u8, source.head_oid),
            .updated_at = try arena.dupe(u8, source.updated_at),
            .base = switch (source.base) {
                .trunk => |trunk| .{ .trunk = .{ .oid = try arena.dupe(u8, trunk.oid) } },
                .parent_pr => |parent| .{ .parent_pr = .{ .number = parent.number, .head_oid = try arena.dupe(u8, parent.head_oid) } },
            },
            .whole_stack = if (source.whole_stack) |stack| .{
                .trunk_ref = try arena.dupe(u8, stack.trunk_ref),
                .trunk_oid = try arena.dupe(u8, stack.trunk_oid),
            } else null,
            .seen_head_oid = if (source.seen_head_oid) |seen| try arena.dupe(u8, seen) else null,
        };
    }
    return copy;
}

fn dupeConfig(allocator: Allocator, params: StartParams) !StartParams {
    var config = params;
    config.repo_root = try allocator.dupe(u8, params.repo_root);
    errdefer allocator.free(config.repo_root);
    config.db_path = try allocator.dupe(u8, params.db_path);
    errdefer allocator.free(config.db_path);
    config.owner = try allocator.dupe(u8, params.owner);
    errdefer allocator.free(config.owner);
    config.name = try allocator.dupe(u8, params.name);
    errdefer allocator.free(config.name);
    config.git_bin = try allocator.dupe(u8, params.git_bin);
    errdefer allocator.free(config.git_bin);
    config.gh_bin = try allocator.dupe(u8, params.gh_bin);
    return config;
}

fn freeConfig(allocator: Allocator, config: StartParams) void {
    allocator.free(config.repo_root);
    allocator.free(config.db_path);
    allocator.free(config.owner);
    allocator.free(config.name);
    allocator.free(config.git_bin);
    allocator.free(config.gh_bin);
}

fn trimOutput(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    /// Absolute path of the temp directory.
    dir: []u8,
    db_path: []u8,
    origin_path: []u8,
    clone_path: []u8,
    /// Isolated config + fixed identity for the commands that build the repos.
    build_env: std.process.Environ.Map,
    store: Store,
    repo_id: i64,
    main_tip: [40]u8,
    heads: [3][40]u8,

    /// Bare origin with main + feat-1, feat-2 (stacked on feat-1), feat-3 and
    /// refs/pull/{1,2,3}/head; main advances after the PRs. The clone under
    /// test is a --no-local single-branch clone of main, so it has none of the
    /// PR objects until the worker fetches them.
    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const relative = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        defer testing.allocator.free(relative);
        const dir = try skim_io.absolutePathAlloc(testing.allocator, relative);
        errdefer testing.allocator.free(dir);

        var build_env = try skim_io.environ().createMap(testing.allocator);
        errdefer build_env.deinit();
        try build_env.put("GIT_CONFIG_GLOBAL", "/dev/null");
        try build_env.put("GIT_CONFIG_NOSYSTEM", "1");
        try build_env.put("GIT_AUTHOR_NAME", "Skim Test");
        try build_env.put("GIT_AUTHOR_EMAIL", "test@example.invalid");
        try build_env.put("GIT_COMMITTER_NAME", "Skim Test");
        try build_env.put("GIT_COMMITTER_EMAIL", "test@example.invalid");
        try build_env.put("LC_ALL", "C");

        var self: Fixture = .{
            .tmp = tmp,
            .dir = dir,
            .db_path = try std.fmt.allocPrint(testing.allocator, "{s}/skim.db", .{dir}),
            .origin_path = try std.fmt.allocPrint(testing.allocator, "{s}/origin.git", .{dir}),
            .clone_path = try std.fmt.allocPrint(testing.allocator, "{s}/clone", .{dir}),
            .build_env = build_env,
            .store = undefined,
            .repo_id = 0,
            .main_tip = undefined,
            .heads = undefined,
        };
        try self.buildRepos();

        self.store = try Store.open(testing.allocator, self.db_path);
        self.repo_id = try self.store.ensureRepo(.{ .key = "github.com/o/r", .owner = "o", .name = "r" });
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.store.close();
        self.build_env.deinit();
        testing.allocator.free(self.clone_path);
        testing.allocator.free(self.origin_path);
        testing.allocator.free(self.db_path);
        testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }

    fn buildRepos(self: *Fixture) !void {
        const work = try std.fmt.allocPrint(testing.allocator, "{s}/work", .{self.dir});
        defer testing.allocator.free(work);

        try self.gitIgnore(self.dir, &.{ "init", "-q", "--bare", "-b", "main", self.origin_path });
        try self.gitIgnore(self.dir, &.{ "init", "-q", "-b", "main", work });
        try self.commitFile(.{ .work = work, .name = "base.txt", .contents = "base\n" });
        const fork = try self.revParse(work, "HEAD");

        try self.gitIgnore(work, &.{ "checkout", "-q", "-b", "feat-1" });
        try self.commitFile(.{ .work = work, .name = "f1.txt", .contents = "one\n" });
        try self.gitIgnore(work, &.{ "checkout", "-q", "-b", "feat-2" });
        try self.commitFile(.{ .work = work, .name = "f2.txt", .contents = "two\n" });
        try self.gitIgnore(work, &.{ "checkout", "-q", "-b", "feat-3", &fork });
        try self.commitFile(.{ .work = work, .name = "f3.txt", .contents = "three\n" });
        try self.gitIgnore(work, &.{ "checkout", "-q", "main" });
        try self.commitFile(.{ .work = work, .name = "later.txt", .contents = "later\n" });

        self.main_tip = try self.revParse(work, "main");
        for (&self.heads, [_][]const u8{ "feat-1", "feat-2", "feat-3" }) |*head, branch| head.* = try self.revParse(work, branch);

        try self.gitIgnore(work, &.{
            "push",                    "-q",                      self.origin_path,
            "main",                    "feat-1",                  "feat-2",
            "feat-3",                  "feat-1:refs/pull/1/head", "feat-2:refs/pull/2/head",
            "feat-3:refs/pull/3/head",
        });
        try self.gitIgnore(self.dir, &.{ "clone", "-q", "--no-local", "--single-branch", "--branch", "main", self.origin_path, self.clone_path });
    }

    fn commitFile(self: *Fixture, params: struct { work: []const u8, name: []const u8, contents: []const u8 }) !void {
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ params.work, params.name });
        defer testing.allocator.free(path);
        try std.Io.Dir.cwd().writeFile(skim_io.get(), .{ .sub_path = path, .data = params.contents });
        try self.gitIgnore(params.work, &.{ "add", params.name });
        try self.gitIgnore(params.work, &.{ "commit", "-q", "-m", params.name });
    }

    /// Executable `#!/bin/sh` script at `<dir>/<name>`; caller frees the path.
    fn writeScript(self: *Fixture, name: []const u8, body: []const u8) ![]u8 {
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ self.dir, name });
        errdefer testing.allocator.free(path);
        const script = try std.fmt.allocPrint(testing.allocator, "#!/bin/sh\n{s}", .{body});
        defer testing.allocator.free(script);
        try std.Io.Dir.cwd().writeFile(skim_io.get(), .{ .sub_path = path, .data = script, .flags = .{ .permissions = .executable_file } });
        return path;
    }

    fn revParse(self: *Fixture, cwd: []const u8, rev: []const u8) ![40]u8 {
        const out = try self.git(cwd, &.{ "rev-parse", rev });
        defer testing.allocator.free(out);
        return plan.parseOid(std.mem.trimEnd(u8, out, "\n")) orelse error.BadOid;
    }

    fn gitIgnore(self: *Fixture, cwd: []const u8, args: []const []const u8) !void {
        testing.allocator.free(try self.git(cwd, args));
    }

    /// Runs `git <args>` with the isolated build env; caller owns stdout.
    fn git(self: *Fixture, cwd: []const u8, args: []const []const u8) ![]u8 {
        return runTestGit(.{ .cwd = cwd, .args = args, .env = &self.build_env });
    }

    /// What the miss path renders, computed independently of the worker with
    /// the same environment the worker gives its children.
    fn expectedDiff(self: *Fixture, base_tip: []const u8, head: []const u8) ![]u8 {
        return diffIn(.{ .cwd = self.clone_path, .base_tip = base_tip, .head = head });
    }

    /// Computed in origin, which has every commit before the worker runs.
    fn mergeBase(self: *Fixture, a: []const u8, b: []const u8) ![40]u8 {
        const out = try self.git(self.origin_path, &.{ "merge-base", a, b });
        defer testing.allocator.free(out);
        return plan.parseOid(std.mem.trimEnd(u8, out, "\n")) orelse error.BadOid;
    }

    fn startWorker(self: *Fixture, overrides: struct {
        allocator: Allocator = testing.allocator,
        budget_bytes: u64 = default_budget_bytes,
        /// Every fixture target is inside the default window; eviction tests
        /// lower it so near rows can be evicted at all.
        keep_nearest: usize = priority.thread_window,
        db_path: ?[]const u8 = null,
        git_bin: []const u8 = "git",
        child_timeout_ns: u64 = default_child_timeout_ns,
        /// Thread jobs only run with a fake gh: a real one needs the network.
        gh_bin: ?[]const u8 = null,
    }) !*PrefetchWorker {
        return start(overrides.allocator, .{
            .repo_root = self.clone_path,
            .db_path = overrides.db_path orelse self.db_path,
            .repo_id = self.repo_id,
            .owner = "o",
            .name = "r",
            .budget_bytes = overrides.budget_bytes,
            .keep_nearest = overrides.keep_nearest,
            .git_bin = overrides.git_bin,
            .child_timeout_ns = overrides.child_timeout_ns,
            .gh_bin = overrides.gh_bin orelse "gh",
            .threads_enabled = overrides.gh_bin != null,
        });
    }

    /// PR 1 (trunk), PR 2 (stacked on 1, tip of the stack), PR 3 (trunk).
    fn targets(self: *const Fixture) [3]Target {
        return .{
            .{
                .number = 1,
                .head_ref = "feat-1",
                .base_ref = "main",
                .head_oid = &self.heads[0],
                .updated_at = "2026-01-01T00:00:01Z",
                .base = .{ .trunk = .{ .oid = &self.main_tip } },
            },
            .{
                .number = 2,
                .head_ref = "feat-2",
                .base_ref = "feat-1",
                .head_oid = &self.heads[1],
                .updated_at = "2026-01-01T00:00:02Z",
                .base = .{ .parent_pr = .{ .number = 1, .head_oid = &self.heads[0] } },
                .whole_stack = .{ .trunk_ref = "main", .trunk_oid = &self.main_tip },
            },
            .{
                .number = 3,
                .head_ref = "feat-3",
                .base_ref = "main",
                .head_oid = &self.heads[2],
                .updated_at = "2026-01-01T00:00:03Z",
                .base = .{ .trunk = .{ .oid = &self.main_tip } },
            },
        };
    }

    fn cachedDiff(self: *Fixture, base_tip: []const u8, head: []const u8) !?CachedDiff {
        return lookupCached(&self.store, .{
            .allocator = testing.allocator,
            .repo_id = self.repo_id,
            .inputs = .{ .base_tip_oid = base_tip, .head_oid = head },
            .now = 1,
        });
    }

    /// A one-commit PR off main's parent with a `lines`-line file, pushed to
    /// origin as `refs/pull/<number>/head` (replacing a fixture PR of that
    /// number); returns its head oid.
    fn pushTrunkPr(self: *Fixture, params: struct { number: u32, branch: []const u8, lines: usize }) ![40]u8 {
        const work = try self.tmpPath("work");
        defer testing.allocator.free(work);
        var contents: std.ArrayList(u8) = .empty;
        defer contents.deinit(testing.allocator);
        for (0..params.lines) |line| try contents.print(testing.allocator, "pr {d} line {d}\n", .{ params.number, line });
        const file = try std.fmt.allocPrint(testing.allocator, "{s}.txt", .{params.branch});
        defer testing.allocator.free(file);
        const refspec = try std.fmt.allocPrint(testing.allocator, "+{s}:refs/pull/{d}/head", .{ params.branch, params.number });
        defer testing.allocator.free(refspec);

        try self.gitIgnore(work, &.{ "checkout", "-q", "-b", params.branch, "main~1" });
        try self.commitFile(.{ .work = work, .name = file, .contents = contents.items });
        try self.gitIgnore(work, &.{ "push", "-q", self.origin_path, refspec });
        return self.revParse(work, "HEAD");
    }

    /// `<dir>/<name>`; caller frees.
    fn tmpPath(self: *Fixture, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ self.dir, name });
    }

    /// A git that appends a line to `log_path` for every `git diff`; caller
    /// frees the script path.
    fn diffLoggingGit(self: *Fixture, log_path: []const u8) ![]u8 {
        const body = try std.fmt.allocPrint(testing.allocator, "if [ \"$1\" = diff ]; then echo diff >> '{s}'; fi\nexec git \"$@\"\n", .{log_path});
        defer testing.allocator.free(body);
        return self.writeScript("diff-logging-git", body);
    }

    /// Fits PR 1 and PR 2's own diff with room to spare, but neither PR 3 nor
    /// the whole-stack diff on top of them.
    fn twoRowBudget(self: *Fixture) !u64 {
        const pr1 = try diffIn(.{ .cwd = self.origin_path, .base_tip = &self.main_tip, .head = &self.heads[0] });
        defer testing.allocator.free(pr1);
        const pr2 = try diffIn(.{ .cwd = self.origin_path, .base_tip = &self.heads[0], .head = &self.heads[1] });
        defer testing.allocator.free(pr2);
        return pr1.len + pr2.len + 16;
    }

    fn diffRowCount(self: *Fixture) !i64 {
        var stmt = try self.store.db.prepare("SELECT COUNT(*) FROM diff_cache WHERE repo_id = ?");
        defer stmt.finalize();
        try stmt.bind(1, self.repo_id);
        _ = try stmt.step();
        return stmt.columnInt(0);
    }
};

/// `git diff base_tip...head` in `cwd`; origin has every commit before the
/// worker fetches anything into the clone.
fn diffIn(params: struct { cwd: []const u8, base_tip: []const u8, head: []const u8 }) ![]u8 {
    var env = try skim_io.environ().createMap(testing.allocator);
    defer env.deinit();
    try env.put("LC_ALL", "C");
    const range = try std.fmt.allocPrint(testing.allocator, "{s}...{s}", .{ params.base_tip, params.head });
    defer testing.allocator.free(range);
    return runTestGit(.{ .cwd = params.cwd, .args = &.{ "diff", "--no-color", "--no-ext-diff", "-U10", range }, .env = &env });
}

fn runTestGit(params: struct { cwd: []const u8, args: []const []const u8, env: *const std.process.Environ.Map }) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argv.append(testing.allocator, "git");
    try argv.appendSlice(testing.allocator, params.args);
    const result = try std.process.run(testing.allocator, skim_io.get(), .{
        .argv = argv.items,
        .cwd = .{ .path = params.cwd },
        .environ_map = params.env,
    });
    defer testing.allocator.free(result.stderr);
    errdefer testing.allocator.free(result.stdout);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.log.warn("git {s} failed: {s}", .{ params.args[0], result.stderr });
            return error.GitFailed;
        },
        else => return error.GitFailed,
    }
    return result.stdout;
}

/// Poll until the worker reports idle (or failed) for `version`.
fn waitForIdle(worker: *PrefetchWorker, version: u64) !Status {
    var waited_ms: u64 = 0;
    while (waited_ms < 20_000) : (waited_ms += 5) {
        const current = worker.status();
        if (current.targets_version == version and (current.phase == .idle or current.phase == .failed)) return current;
        skim_io.sleep(5 * std.time.ns_per_ms);
    }
    return error.WorkerNotIdle;
}

/// Poll until the worker reports idle for `version` after ordering by `focus`.
fn waitForFocusIdle(worker: *PrefetchWorker, params: struct { version: u64, focus: u32 }) !Status {
    var waited_ms: u64 = 0;
    while (waited_ms < 20_000) : (waited_ms += 5) {
        const current = worker.status();
        if (current.targets_version == params.version and current.focus == params.focus and current.phase == .idle) return current;
        skim_io.sleep(5 * std.time.ns_per_ms);
    }
    return error.WorkerNotIdle;
}

/// Poll a pid file a script writes until it exists; returns the pid.
fn waitForPidFile(path: []const u8) !std.posix.pid_t {
    var waited_ms: u64 = 0;
    while (waited_ms < 10_000) : (waited_ms += 10) {
        const text = std.Io.Dir.cwd().readFileAlloc(skim_io.get(), path, testing.allocator, .limited(64)) catch {
            skim_io.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        defer testing.allocator.free(text);
        const trimmed = std.mem.trim(u8, text, " \n");
        if (trimmed.len > 0) return std.fmt.parseInt(std.posix.pid_t, trimmed, 10);
        skim_io.sleep(10 * std.time.ns_per_ms);
    }
    return error.PidFileMissing;
}

/// True once `pid` is gone (reaped), polling for up to 2s.
fn processGone(pid: std.posix.pid_t) bool {
    var waited_ms: u64 = 0;
    while (waited_ms < 2_000) : (waited_ms += 10) {
        std.posix.kill(pid, @enumFromInt(0)) catch return true;
        skim_io.sleep(10 * std.time.ns_per_ms);
    }
    return false;
}

/// Bit `i` set when `targets[i]`'s PR diff is cached in `store`.
fn cachedNumbers(store: *Store, params: struct { repo_id: i64, targets: []const Target }) !u64 {
    var mask: u64 = 0;
    for (params.targets, 0..) |target, i| {
        if (try isCached(store, .{ .repo_id = params.repo_id, .inputs = priority.diffKeyFor(target, .pr).? })) mask |= @as(u64, 1) << @intCast(i);
    }
    return mask;
}

/// Lines in `path`; 0 when the file does not exist yet.
fn countLines(path: []const u8) !usize {
    const text = std.Io.Dir.cwd().readFileAlloc(skim_io.get(), path, testing.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer testing.allocator.free(text);
    return std.mem.count(u8, text, "\n");
}

/// One-line trunk PRs `pr-1`..`pr-9` (one per `heads` slot), all with diffs
/// of the same size; returns a budget that fits `rows` of them and no more.
fn pushEqualPrs(params: struct { fx: *Fixture, heads: [][40]u8, targets: []Target, rows: u64 }) !u64 {
    const names = [_][]const u8{ "pr-1", "pr-2", "pr-3", "pr-4", "pr-5", "pr-6", "pr-7", "pr-8", "pr-9" };
    var row_size: u64 = 0;
    for (params.heads, params.targets, names[0..params.heads.len], 1..) |*head, *target, name, number| {
        head.* = try params.fx.pushTrunkPr(.{ .number = @intCast(number), .branch = name, .lines = 1 });
        target.* = .{
            .number = @intCast(number),
            .head_ref = name,
            .base_ref = "main",
            .head_oid = head,
            .updated_at = "2026-01-01T00:00:00Z",
            .base = .{ .trunk = .{ .oid = &params.fx.main_tip } },
        };
        const bytes = try diffIn(.{ .cwd = params.fx.origin_path, .base_tip = &params.fx.main_tip, .head = head });
        defer testing.allocator.free(bytes);
        row_size = bytes.len;
    }
    return params.rows * row_size + row_size / 2;
}

/// Poll until diff_cache holds `count` rows.
fn waitForRowCount(fx: *Fixture, count: i64) !void {
    var waited_ms: u64 = 0;
    while (waited_ms < 20_000) : (waited_ms += 5) {
        if (try fx.diffRowCount() == count) return;
        skim_io.sleep(5 * std.time.ns_per_ms);
    }
    return error.RowCountNotReached;
}

fn expectCachedEqualsGit(params: struct { fx: *Fixture, base_tip: []const u8, head: []const u8 }) !void {
    const expected = try params.fx.expectedDiff(params.base_tip, params.head);
    defer testing.allocator.free(expected);
    const cached = (try params.fx.cachedDiff(params.base_tip, params.head)).?;
    defer testing.allocator.free(cached.bytes);
    try testing.expect(expected.len > 0);
    try testing.expectEqualStrings(expected, cached.bytes);
}

test "worker caches each target's diff equal to git diff merge-base..head" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    const targets = fx.targets();
    const final = try waitForIdle(worker, try worker.setTargets(&targets));

    try testing.expectEqual(@as(u32, 3), final.diffs_ready);
    try testing.expectEqual(@as(u32, 0), final.failures);
    try testing.expectEqual(@as(?LastError, null), final.last_error);
    try expectCachedEqualsGit(.{ .fx = &fx, .base_tip = &fx.main_tip, .head = &fx.heads[0] });
    try expectCachedEqualsGit(.{ .fx = &fx, .base_tip = &fx.heads[0], .head = &fx.heads[1] });
    try expectCachedEqualsGit(.{ .fx = &fx, .base_tip = &fx.main_tip, .head = &fx.heads[2] });
}

test "fetched heads land in refs/skim/pr-N" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    const targets = fx.targets();
    _ = try waitForIdle(worker, try worker.setTargets(&targets));

    for (fx.heads, [_][]const u8{ "refs/skim/pr-1", "refs/skim/pr-2", "refs/skim/pr-3" }) |head, ref| {
        try testing.expectEqualStrings(&head, &(try fx.revParse(fx.clone_path, ref)));
    }
}

test "fetched objects land as a pack, so a killed fetch cannot leave a commit without its tree" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    const targets = fx.targets();
    _ = try waitForIdle(worker, try worker.setTargets(&targets));

    try testing.expectEqualStrings(&fx.heads[0], &(try fx.revParse(fx.clone_path, "refs/skim/pr-1")));
    const counts = try fx.git(fx.clone_path, &.{ "count-objects", "-v" });
    defer testing.allocator.free(counts);
    try testing.expect(std.mem.startsWith(u8, counts, "count: 0\n"));
}

test "a head already present locally still gets refs/skim/pr-N" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.gitIgnore(fx.clone_path, &.{ "fetch", "-q", "origin", "feat-1:refs/remotes/origin/feat-1" });
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    const targets = fx.targets();
    _ = try waitForIdle(worker, try worker.setTargets(&targets));

    try testing.expectEqualStrings(&fx.heads[0], &(try fx.revParse(fx.clone_path, "refs/skim/pr-1")));
}

test "an existing refs/skim/pr-N is never moved to the target's head" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.gitIgnore(fx.clone_path, &.{ "fetch", "-q", "origin", "feat-1:refs/remotes/origin/feat-1", "feat-3:refs/skim/pr-1" });
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    const targets = fx.targets();
    _ = try waitForIdle(worker, try worker.setTargets(&targets));

    try testing.expectEqualStrings(&fx.heads[2], &(try fx.revParse(fx.clone_path, "refs/skim/pr-1")));
}

test "an existing refs/skim/pr-N behind the target's head advances to it" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.gitIgnore(fx.clone_path, &.{ "fetch", "-q", "origin", "feat-2:refs/remotes/origin/feat-2", "feat-1:refs/skim/pr-2" });
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    const targets = fx.targets();
    _ = try waitForIdle(worker, try worker.setTargets(&targets));

    try testing.expectEqualStrings(&fx.heads[1], &(try fx.revParse(fx.clone_path, "refs/skim/pr-2")));
}

test "a ref git cannot lock does not stop the other heads from being pinned" {
    const io = skim_io.get();
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.gitIgnore(fx.clone_path, &.{ "fetch", "-q", "origin", "feat-1:refs/remotes/origin/feat-1", "feat-2:refs/remotes/origin/feat-2" });
    const refs_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git/refs/skim", .{fx.clone_path});
    defer testing.allocator.free(refs_dir);
    try std.Io.Dir.cwd().createDirPath(io, refs_dir);
    const lock = try std.fmt.allocPrint(testing.allocator, "{s}/pr-2.lock", .{refs_dir});
    defer testing.allocator.free(lock);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lock, .data = "" });
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    const targets = fx.targets();
    _ = try waitForIdle(worker, try worker.setTargets(&targets));

    try testing.expectEqualStrings(&fx.heads[0], &(try fx.revParse(fx.clone_path, "refs/skim/pr-1")));
}

test "worker start removes tmp_pack_ files a killed fetch left behind, and keeps fresh ones" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const pack_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git/objects/pack", .{fx.clone_path});
    defer testing.allocator.free(pack_dir);
    const stale = try std.fmt.allocPrint(testing.allocator, "{s}/tmp_pack_stale1", .{pack_dir});
    defer testing.allocator.free(stale);
    const fresh = try std.fmt.allocPrint(testing.allocator, "{s}/tmp_pack_fresh1", .{pack_dir});
    defer testing.allocator.free(fresh);
    try std.Io.Dir.cwd().createDirPath(skim_io.get(), pack_dir);
    try std.Io.Dir.cwd().writeFile(skim_io.get(), .{ .sub_path = stale, .data = "partial" });
    try std.Io.Dir.cwd().writeFile(skim_io.get(), .{ .sub_path = fresh, .data = "partial" });
    const touched = try std.process.run(testing.allocator, skim_io.get(), .{ .argv = &.{ "touch", "-d", "20 minutes ago", stale } });
    testing.allocator.free(touched.stdout);
    testing.allocator.free(touched.stderr);
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    const targets = fx.targets();
    _ = try waitForIdle(worker, try worker.setTargets(&targets));

    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(skim_io.get(), stale, .{}));
    try std.Io.Dir.cwd().access(skim_io.get(), fresh, .{});
}

test "stacked PR is keyed on its parent's head" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    const targets = fx.targets();
    _ = try waitForIdle(worker, try worker.setTargets(&targets));

    const merge_base = (try fx.store.getMergeBase(fx.repo_id, .{ .base_tip_oid = &fx.heads[0], .head_oid = &fx.heads[1] })).?;
    try testing.expectEqualStrings(&fx.heads[0], &merge_base);
    const cached = (try fx.cachedDiff(&fx.heads[0], &fx.heads[1])).?;
    defer testing.allocator.free(cached.bytes);
    try testing.expect(std.mem.indexOf(u8, cached.bytes, "f2.txt") != null);
    try testing.expect(std.mem.indexOf(u8, cached.bytes, "f1.txt") == null);
}

test "whole-stack diff for a tip covers every stacked file" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    const targets = fx.targets();
    _ = try waitForIdle(worker, try worker.setTargets(&targets));

    try expectCachedEqualsGit(.{ .fx = &fx, .base_tip = &fx.main_tip, .head = &fx.heads[1] });
    const cached = (try fx.cachedDiff(&fx.main_tip, &fx.heads[1])).?;
    defer testing.allocator.free(cached.bytes);
    try testing.expect(std.mem.indexOf(u8, cached.bytes, "f1.txt") != null);
    try testing.expect(std.mem.indexOf(u8, cached.bytes, "f2.txt") != null);
    try testing.expect(std.mem.indexOf(u8, cached.bytes, "later.txt") == null);
    try testing.expectEqual(@as(i64, 4), try fx.diffRowCount());
}

test "second round with unchanged targets spawns no git fetch" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    const targets = fx.targets();
    _ = try waitForIdle(worker, try worker.setTargets(&targets));

    // Any fetch from here on would fail and record fetch_failed.
    const moved = try std.fmt.allocPrint(testing.allocator, "{s}.moved", .{fx.origin_path});
    defer testing.allocator.free(moved);
    try std.Io.Dir.renameAbsolute(fx.origin_path, moved, skim_io.get());

    const gen_before = worker.generation();
    const second = try waitForIdle(worker, try worker.setTargets(&targets));
    try testing.expectEqual(@as(?LastError, null), second.last_error);
    try testing.expectEqual(@as(u32, 3), second.diffs_ready);
    try testing.expectEqual(gen_before, worker.generation());
}

test "generation increases after diffs are written" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    try testing.expectEqual(@as(u64, 0), worker.generation());
    const targets = fx.targets();
    _ = try waitForIdle(worker, try worker.setTargets(&targets));
    try testing.expect(worker.generation() >= 4);
}

test "fast-forwarded seen PR caches the seen-head..head diff" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    const all = fx.targets();
    var target = all[1];
    target.base = .{ .trunk = .{ .oid = &fx.main_tip } };
    target.whole_stack = null;
    target.seen_head_oid = &fx.heads[0];
    const final = try waitForIdle(worker, try worker.setTargets(&.{target}));

    try testing.expectEqual(@as(u32, 0), final.failures);
    const merge_base = (try fx.store.getMergeBase(fx.repo_id, .{ .base_tip_oid = &fx.heads[0], .head_oid = &fx.heads[1] })).?;
    try testing.expectEqualStrings(&fx.heads[0], &merge_base);
    try expectCachedEqualsGit(.{ .fx = &fx, .base_tip = &fx.heads[0], .head = &fx.heads[1] });
    const cached = (try fx.cachedDiff(&fx.heads[0], &fx.heads[1])).?;
    defer testing.allocator.free(cached.bytes);
    try testing.expect(std.mem.indexOf(u8, cached.bytes, "f2.txt") != null);
    try testing.expect(std.mem.indexOf(u8, cached.bytes, "f1.txt") == null);
}

test "rewritten seen PR records the merge base and caches no since-seen diff" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    const all = fx.targets();
    var rewritten = all[2];
    // Unknown base: the PR's own diff is skipped, so any diff row for this
    // head could only come from the since-seen job.
    rewritten.base = .{ .trunk = .{ .oid = "" } };
    rewritten.seen_head_oid = &fx.heads[0];
    const final = try waitForIdle(worker, try worker.setTargets(&.{ all[0], rewritten }));

    try testing.expectEqual(Phase.idle, final.phase);
    try testing.expectEqual(@as(u32, 0), final.failures);
    const merge_base = (try fx.store.getMergeBase(fx.repo_id, .{ .base_tip_oid = &fx.heads[0], .head_oid = &fx.heads[2] })).?;
    try testing.expect(!std.mem.eql(u8, &fx.heads[0], &merge_base));
    try testing.expect(!try fx.store.hasDiff(fx.repo_id, .{ .merge_base_oid = merge_base, .head_oid = fx.heads[2] }));
    try testing.expectEqual(@as(i64, 1), try fx.diffRowCount());
}

test "eviction keeps pinned seen rows" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const pinned_base = try fx.mergeBase(&fx.main_tip, &fx.heads[0]);
    try fx.store.setSeen(.{ .repo_id = fx.repo_id, .number = 1, .head_oid = &fx.heads[0], .merge_base_oid = &pinned_base, .now = 1 });

    const worker = try fx.startWorker(.{ .budget_bytes = 1, .keep_nearest = 0 });
    defer worker.stop();
    const targets = fx.targets();
    const final = try waitForIdle(worker, try worker.setTargets(&targets));

    try testing.expectEqual(Phase.idle, final.phase);
    try testing.expectEqual(@as(i64, 1), try fx.diffRowCount());
    try testing.expect(try fx.store.hasDiff(fx.repo_id, .{ .merge_base_oid = pinned_base, .head_oid = fx.heads[0] }));
}

test "eviction never deletes the rows of the targets nearest the focus" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const pinned_base = try fx.mergeBase(&fx.main_tip, &fx.heads[0]);
    try fx.store.setSeen(.{ .repo_id = fx.repo_id, .number = 1, .head_oid = &fx.heads[0], .merge_base_oid = &pinned_base, .now = 1 });
    const worker = try fx.startWorker(.{ .budget_bytes = 1, .keep_nearest = 2 });
    defer worker.stop();
    worker.setFocus(1);
    const targets = fx.targets();

    const final = try waitForIdle(worker, try worker.setTargets(&targets));

    // PR 1 and both views of PR 2 are kept; PR 3 is the only one evictable.
    try testing.expectEqual(@as(u32, 2), final.diffs_ready);
    try testing.expectEqual(@as(i64, 3), try fx.diffRowCount());
    try testing.expect(!try isCached(&fx.store, .{ .repo_id = fx.repo_id, .inputs = .{ .base_tip_oid = &fx.main_tip, .head_oid = &fx.heads[2] } }));
}

test "eviction runs on idle even when nothing new was written" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const targets = fx.targets();
    {
        const worker = try fx.startWorker(.{});
        defer worker.stop();
        _ = try waitForIdle(worker, try worker.setTargets(&targets));
    }
    try testing.expectEqual(@as(i64, 4), try fx.diffRowCount());

    const worker = try fx.startWorker(.{ .budget_bytes = 1, .keep_nearest = 0 });
    defer worker.stop();
    _ = try waitForIdle(worker, try worker.setTargets(&targets));
    try testing.expectEqual(@as(i64, 0), try fx.diffRowCount());
}

test "focus set before targets orders the first round" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    worker.setFocus(3);
    const targets = fx.targets();
    _ = try waitForIdle(worker, try worker.setTargets(&targets));

    var stmt = try fx.store.db.prepare("SELECT head_oid FROM diff_cache WHERE repo_id = ? ORDER BY rowid LIMIT 1");
    defer stmt.finalize();
    try stmt.bind(1, fx.repo_id);
    try testing.expect(try stmt.step());
    try testing.expectEqualStrings(&fx.heads[2], try stmt.columnText(0));
}

test "invalid base name is skipped and never fetched" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    var targets = fx.targets();
    const absent_base = "0123456789abcdef0123456789abcdef01234567";
    targets[2].base_ref = "-evil";
    targets[2].base = .{ .trunk = .{ .oid = absent_base } };
    const final = try waitForIdle(worker, try worker.setTargets(&targets));

    try testing.expectEqual(@as(u32, 2), final.diffs_ready);
    try testing.expectEqual(@as(u32, 0), final.failures);
    try testing.expectEqual(@as(?LastError, null), final.last_error);
    try testing.expect(!try isCached(&fx.store, .{ .repo_id = fx.repo_id, .inputs = .{ .base_tip_oid = absent_base, .head_oid = &fx.heads[2] } }));
    // The head was still fetched; only the base was refused.
    try testing.expectEqualStrings(&fx.heads[2], &(try fx.revParse(fx.clone_path, "refs/skim/pr-3")));
    try testing.expect(try isCached(&fx.store, .{ .repo_id = fx.repo_id, .inputs = .{ .base_tip_oid = &fx.main_tip, .head_oid = &fx.heads[0] } }));
}

test "unknown base oid and malformed oids are skipped, not failed" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    var targets = fx.targets();
    targets[0].base = .{ .trunk = .{ .oid = "" } };
    targets[2].head_oid = "NOT-AN-OID";
    const final = try waitForIdle(worker, try worker.setTargets(&targets));

    try testing.expectEqual(Phase.idle, final.phase);
    try testing.expectEqual(@as(u32, 1), final.diffs_ready);
    try testing.expectEqual(@as(u32, 0), final.failures);
}

test "empty target list goes idle without spawning anything" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    const final = try waitForIdle(worker, try worker.setTargets(&.{}));
    try testing.expectEqual(@as(u32, 0), final.targets);
    try testing.expectEqual(@as(u32, 0), final.diffs_ready);
    try testing.expectEqual(@as(u64, 0), worker.generation());
}

test "a new target list replaces the old one" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    const targets = fx.targets();
    const first = try worker.setTargets(targets[0..1]);
    const second = try worker.setTargets(targets[2..3]);
    try testing.expect(second > first);
    const final = try waitForIdle(worker, second);

    try testing.expectEqual(@as(u32, 1), final.targets);
    try testing.expectEqual(@as(u32, 1), final.diffs_ready);
    try testing.expect(try isCached(&fx.store, .{ .repo_id = fx.repo_id, .inputs = .{ .base_tip_oid = &fx.main_tip, .head_oid = &fx.heads[2] } }));
}

test "setTargets deep-copies: the caller's strings may be freed right away" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    const head = try testing.allocator.dupe(u8, &fx.heads[2]);
    const base = try testing.allocator.dupe(u8, &fx.main_tip);
    var targets = fx.targets();
    targets[2].head_oid = head;
    targets[2].base = .{ .trunk = .{ .oid = base } };
    const version = try worker.setTargets(targets[2..3]);
    @memset(head, 'x');
    @memset(base, 'x');
    testing.allocator.free(head);
    testing.allocator.free(base);

    const final = try waitForIdle(worker, version);
    try testing.expectEqual(@as(u32, 1), final.diffs_ready);
}

test "stop returns promptly while idle" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const worker = try fx.startWorker(.{});
    const targets = fx.targets();
    _ = try waitForIdle(worker, try worker.setTargets(&targets));
    var timer = try skim_io.Timer.start();
    worker.stop();
    try testing.expect(timer.read() < std.time.ns_per_s);
}

test "stop before any targets are set" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const worker = try fx.startWorker(.{});
    worker.stop();
}

test "a pull ref missing on origin is dropped and the rest of the batch still fetches" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    const base = fx.targets();
    // origin has no refs/pull/9/head, so the first batched fetch fails on it.
    const targets = [_]Target{ base[0], base[1], base[2], .{
        .number = 9,
        .head_ref = "feat-9",
        .base_ref = "main",
        .head_oid = "abababababababababababababababababababab",
        .updated_at = "2026-01-01T00:00:09Z",
        .base = .{ .trunk = .{ .oid = &fx.main_tip } },
    } };

    const status = try waitForIdle(worker, try worker.setTargets(&targets));

    try testing.expectEqual(@as(u32, 3), status.diffs_ready);
    try testing.expectEqual(@as(u32, 1), status.failures);
    try testing.expectEqual(@as(?LastError, null), status.last_error);
    try expectCachedEqualsGit(.{ .fx = &fx, .base_tip = &fx.main_tip, .head = &fx.heads[2] });
}

test "a pull ref missing on origin is not fetched again until the PR changes" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const log_path = try fx.tmpPath("pull9.log");
    defer testing.allocator.free(log_path);
    const body = try std.fmt.allocPrint(testing.allocator, "for arg; do case \"$arg\" in *refs/pull/9/head*) echo fetch >> '{s}'; break;; esac; done\nexec git \"$@\"\n", .{log_path});
    defer testing.allocator.free(body);
    const git_bin = try fx.writeScript("pull9-logging-git", body);
    defer testing.allocator.free(git_bin);
    const worker = try fx.startWorker(.{ .git_bin = git_bin });
    defer worker.stop();
    const base = fx.targets();
    var targets = [_]Target{ base[0], base[1], base[2], .{
        .number = 9,
        .head_ref = "feat-9",
        .base_ref = "main",
        .head_oid = "abababababababababababababababababababab",
        .updated_at = "2026-01-01T00:00:09Z",
        .base = .{ .trunk = .{ .oid = &fx.main_tip } },
    } };
    _ = try waitForIdle(worker, try worker.setTargets(&targets));
    const first = try countLines(log_path);

    const resynced = try waitForIdle(worker, try worker.setTargets(&targets));
    try testing.expectEqual(first, try countLines(log_path));
    try testing.expectEqual(@as(u32, 3), resynced.diffs_ready);

    targets[3].updated_at = "2026-01-01T00:00:10Z";
    _ = try waitForIdle(worker, try worker.setTargets(&targets));
    try testing.expect(first > 0);
    try testing.expect(try countLines(log_path) > first);
}

test "unreachable origin records fetch_failed and still goes idle" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const moved = try std.fmt.allocPrint(testing.allocator, "{s}.moved", .{fx.origin_path});
    defer testing.allocator.free(moved);
    try std.Io.Dir.renameAbsolute(fx.origin_path, moved, skim_io.get());
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    const targets = fx.targets();

    const status = try waitForIdle(worker, try worker.setTargets(&targets));

    try testing.expectEqual(Phase.idle, status.phase);
    try testing.expectEqual(@as(?LastError, .fetch_failed), status.last_error);
    try testing.expectEqual(@as(u32, 0), status.diffs_ready);
    try testing.expectEqual(@as(i64, 0), try fx.diffRowCount());
}

test "missing git binary fails the worker with git_missing" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const worker = try fx.startWorker(.{ .git_bin = "/nonexistent/skim-test-git" });
    defer worker.stop();
    const targets = fx.targets();

    const status = try waitForIdle(worker, try worker.setTargets(&targets));

    try testing.expectEqual(Phase.failed, status.phase);
    try testing.expectEqual(@as(?LastError, .git_missing), status.last_error);
    try testing.expectEqual(@as(i64, 0), try fx.diffRowCount());
}

test "worker reports db_open failure and retries the open on the next target list" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const late_dir = try std.fmt.allocPrint(testing.allocator, "{s}/late", .{fx.dir});
    defer testing.allocator.free(late_dir);
    const late_db = try std.fmt.allocPrint(testing.allocator, "{s}/skim.db", .{late_dir});
    defer testing.allocator.free(late_db);
    const worker = try fx.startWorker(.{ .db_path = late_db });
    defer worker.stop();
    const targets = fx.targets();

    const failed = try waitForIdle(worker, try worker.setTargets(&targets));
    try testing.expectEqual(Phase.failed, failed.phase);
    try testing.expectEqual(@as(?LastError, .db_open), failed.last_error);

    try std.Io.Dir.cwd().createDirPath(skim_io.get(), late_dir);
    {
        var late = try Store.open(testing.allocator, late_db);
        defer late.close();
        try testing.expectEqual(fx.repo_id, try late.ensureRepo(.{ .key = "github.com/o/r", .owner = "o", .name = "r" }));
    }
    const recovered = try waitForIdle(worker, try worker.setTargets(&targets));
    try testing.expectEqual(Phase.idle, recovered.phase);
    try testing.expectEqual(@as(?LastError, null), recovered.last_error);
    try testing.expectEqual(@as(u32, 3), recovered.diffs_ready);
}

test "generation moves when only merge bases were written" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const pairs = [_][2][]const u8{
        .{ &fx.main_tip, &fx.heads[0] },
        .{ &fx.heads[0], &fx.heads[1] },
        .{ &fx.main_tip, &fx.heads[1] },
        .{ &fx.main_tip, &fx.heads[2] },
    };
    for (pairs) |pair| {
        const merge_base = try fx.mergeBase(pair[0], pair[1]);
        try fx.store.putDiff(.{ .repo_id = fx.repo_id, .key = .{ .merge_base_oid = merge_base, .head_oid = pair[1][0..40].* }, .bytes = "cached", .now = 1 });
    }
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    const targets = fx.targets();

    const final = try waitForIdle(worker, try worker.setTargets(&targets));

    try testing.expectEqual(@as(u32, 3), final.diffs_ready);
    try testing.expectEqual(@as(i64, 4), try fx.diffRowCount());
    try testing.expect(try isCached(&fx.store, .{ .repo_id = fx.repo_id, .inputs = .{ .base_tip_oid = &fx.main_tip, .head_oid = &fx.heads[2] } }));
    try testing.expect(worker.generation() > 0);
}

test "under budget pressure the rows nearest the focus survive" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var budget: u64 = 0;
    for ([_][2][]const u8{ .{ &fx.main_tip, &fx.heads[0] }, .{ &fx.heads[0], &fx.heads[1] }, .{ &fx.main_tip, &fx.heads[1] } }) |pair| {
        const bytes = try diffIn(.{ .cwd = fx.origin_path, .base_tip = pair[0], .head = pair[1] });
        defer testing.allocator.free(bytes);
        budget += bytes.len;
    }
    const worker = try fx.startWorker(.{ .budget_bytes = budget, .keep_nearest = 0 });
    defer worker.stop();
    worker.setFocus(1);
    const targets = fx.targets();

    _ = try waitForIdle(worker, try worker.setTargets(&targets));

    try testing.expectEqual(@as(i64, 3), try fx.diffRowCount());
    try testing.expect(try isCached(&fx.store, .{ .repo_id = fx.repo_id, .inputs = .{ .base_tip_oid = &fx.main_tip, .head_oid = &fx.heads[0] } }));
    try testing.expect(try isCached(&fx.store, .{ .repo_id = fx.repo_id, .inputs = .{ .base_tip_oid = &fx.heads[0], .head_oid = &fx.heads[1] } }));
    try testing.expect(!try isCached(&fx.store, .{ .repo_id = fx.repo_id, .inputs = .{ .base_tip_oid = &fx.main_tip, .head_oid = &fx.heads[2] } }));
}

test "a remote-tracking ref that cannot be locked is dropped, not reported as a fetch failure" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const work = try std.fmt.allocPrint(testing.allocator, "{s}/work", .{fx.dir});
    defer testing.allocator.free(work);
    try fx.gitIgnore(work, &.{ "checkout", "-q", "-b", "nest/inner", &fx.main_tip });
    try fx.commitFile(.{ .work = work, .name = "nest.txt", .contents = "nest\n" });
    const nest_tip = try fx.revParse(work, "nest/inner");
    try fx.gitIgnore(work, &.{ "push", "-q", fx.origin_path, "nest/inner" });
    // A stale file ref where the fetch wants a directory: git cannot lock
    // refs/remotes/origin/nest/inner.
    try fx.gitIgnore(fx.clone_path, &.{ "update-ref", "refs/remotes/origin/nest", &fx.main_tip });

    const worker = try fx.startWorker(.{});
    defer worker.stop();
    var targets = fx.targets();
    targets[2].base_ref = "nest/inner";
    targets[2].base = .{ .trunk = .{ .oid = &nest_tip } };

    const final = try waitForIdle(worker, try worker.setTargets(&targets));

    try testing.expectEqual(@as(?LastError, null), final.last_error);
    try testing.expectEqual(@as(u32, 3), final.diffs_ready);
    try expectCachedEqualsGit(.{ .fx = &fx, .base_tip = &nest_tip, .head = &fx.heads[2] });
}

test "a git fetch that outlives the timeout is killed and recorded as fetch_failed" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const git_bin = try fx.writeScript("slow-fetch-git",
        \\for arg; do [ "$arg" = fetch ] && exec sleep 30; done
        \\exec git "$@"
        \\
    );
    defer testing.allocator.free(git_bin);
    const worker = try fx.startWorker(.{ .git_bin = git_bin, .child_timeout_ns = std.time.ns_per_s });
    defer worker.stop();
    const targets = fx.targets();
    var timer = try skim_io.Timer.start();

    const final = try waitForIdle(worker, try worker.setTargets(&targets));

    try testing.expect(timer.read() < 10 * std.time.ns_per_s);
    try testing.expectEqual(Phase.idle, final.phase);
    try testing.expectEqual(@as(?LastError, .fetch_failed), final.last_error);
}

test "stop gives up on a hung git after its wait, kills it, and the thread frees itself" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const git_bin = try fx.writeScript("hung-git", "exec sleep 5\n");
    defer testing.allocator.free(git_bin);
    var debug_allocator: std.heap.DebugAllocator(.{ .thread_safe = true, .enable_memory_limit = true }) = .init;
    const worker = try fx.startWorker(.{ .allocator = debug_allocator.allocator(), .git_bin = git_bin });
    const targets = fx.targets();
    _ = try worker.setTargets(&targets);
    skim_io.sleep(200 * std.time.ns_per_ms);

    var timer = try skim_io.Timer.start();
    worker.stop();
    try testing.expect(timer.read() < 3 * std.time.ns_per_s);

    var waited_ms: u64 = 0;
    while (debug_allocator.total_requested_bytes != 0 and waited_ms < 2_000) : (waited_ms += 10) {
        skim_io.sleep(10 * std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(usize, 0), debug_allocator.total_requested_bytes);
    try testing.expectEqual(std.heap.Check.ok, debug_allocator.deinit());
}

test "user's core.sshCommand is left in charge of ssh" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const log_path = try std.fmt.allocPrint(testing.allocator, "{s}/ssh-env.log", .{fx.dir});
    defer testing.allocator.free(log_path);
    const body = try std.fmt.allocPrint(testing.allocator, "printf '%s\\n' \"${{GIT_SSH_COMMAND-unset}}\" >> '{s}'\nexec git \"$@\"\n", .{log_path});
    defer testing.allocator.free(body);
    const git_bin = try fx.writeScript("env-git", body);
    defer testing.allocator.free(git_bin);
    try fx.gitIgnore(fx.clone_path, &.{ "config", "core.sshCommand", "ssh -i /dev/null" });

    const worker = try fx.startWorker(.{ .git_bin = git_bin });
    defer worker.stop();
    const targets = fx.targets();
    _ = try waitForIdle(worker, try worker.setTargets(&targets));

    const log = try std.Io.Dir.cwd().readFileAlloc(skim_io.get(), log_path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(log);
    try testing.expect(log.len > 0);
    try testing.expect(std.mem.indexOf(u8, log, default_ssh_command) == null);
}

test "a timed-out git gets SIGTERM before anything harsher" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const term_log = try std.fmt.allocPrint(testing.allocator, "{s}/term.log", .{fx.dir});
    defer testing.allocator.free(term_log);
    const body = try std.fmt.allocPrint(testing.allocator,
        \\for arg; do
        \\  if [ "$arg" = fetch ]; then
        \\    trap 'echo term >> "{s}"; exit 143' TERM
        \\    sleep 30 &
        \\    wait
        \\  fi
        \\done
        \\exec git "$@"
        \\
    , .{term_log});
    defer testing.allocator.free(body);
    const git_bin = try fx.writeScript("term-git", body);
    defer testing.allocator.free(git_bin);
    const worker = try fx.startWorker(.{ .git_bin = git_bin, .child_timeout_ns = std.time.ns_per_s });
    defer worker.stop();
    const targets = fx.targets();

    const final = try waitForIdle(worker, try worker.setTargets(&targets));

    try testing.expectEqual(@as(?LastError, .fetch_failed), final.last_error);
    const log = try std.Io.Dir.cwd().readFileAlloc(skim_io.get(), term_log, testing.allocator, .limited(1024));
    defer testing.allocator.free(log);
    try testing.expectEqualStrings("term\n", log);
}

test "a gh that outlives the timeout is killed and recorded as gh_failed" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const gh_bin = try fx.writeScript("slow-gh", "exec sleep 30\n");
    defer testing.allocator.free(gh_bin);
    const worker = try fx.startWorker(.{ .gh_bin = gh_bin, .child_timeout_ns = std.time.ns_per_s });
    defer worker.stop();
    const targets = fx.targets();
    var timer = try skim_io.Timer.start();

    const final = try waitForIdle(worker, try worker.setTargets(&targets));

    try testing.expect(timer.read() < 10 * std.time.ns_per_s);
    try testing.expectEqual(Phase.idle, final.phase);
    try testing.expectEqual(@as(?LastError, .gh_failed), final.last_error);
    try testing.expectEqual(@as(u32, 3), final.diffs_ready);
}

test "stop during a hung gh returns promptly and leaves no process behind" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const pid_path = try std.fmt.allocPrint(testing.allocator, "{s}/gh.pid", .{fx.dir});
    defer testing.allocator.free(pid_path);
    const child_pid_path = try std.fmt.allocPrint(testing.allocator, "{s}/gh-child.pid", .{fx.dir});
    defer testing.allocator.free(child_pid_path);
    const body = try std.fmt.allocPrint(testing.allocator, "echo $$ > '{s}'\nsleep 30 &\necho $! > '{s}'\nwait\n", .{ pid_path, child_pid_path });
    defer testing.allocator.free(body);
    const gh_bin = try fx.writeScript("hung-gh", body);
    defer testing.allocator.free(gh_bin);
    const worker = try fx.startWorker(.{ .gh_bin = gh_bin });
    const targets = fx.targets();
    _ = try worker.setTargets(&targets);
    const gh_pid = try waitForPidFile(pid_path);
    const sleep_pid = try waitForPidFile(child_pid_path);

    var timer = try skim_io.Timer.start();
    worker.stop();

    try testing.expect(timer.read() < 1500 * std.time.ns_per_ms);
    try testing.expect(processGone(gh_pid));
    try testing.expect(processGone(sleep_pid));
}

test "a new worker focused elsewhere keeps the rows nearest its focus under budget" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const targets = fx.targets();
    {
        const worker = try fx.startWorker(.{});
        defer worker.stop();
        worker.setFocus(1);
        _ = try waitForIdle(worker, try worker.setTargets(&targets));
    }
    try testing.expectEqual(@as(i64, 4), try fx.diffRowCount());
    const pr3 = try diffIn(.{ .cwd = fx.origin_path, .base_tip = &fx.main_tip, .head = &fx.heads[2] });
    defer testing.allocator.free(pr3);

    const worker = try fx.startWorker(.{ .budget_bytes = pr3.len, .keep_nearest = 0 });
    defer worker.stop();
    worker.setFocus(3);
    _ = try waitForIdle(worker, try worker.setTargets(&targets));

    try testing.expectEqual(@as(i64, 1), try fx.diffRowCount());
    try testing.expect(try isCached(&fx.store, .{ .repo_id = fx.repo_id, .inputs = .{ .base_tip_oid = &fx.main_tip, .head_oid = &fx.heads[2] } }));
}

test "a focus move within one target list re-ranks eviction around the new focus" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const pr1 = try diffIn(.{ .cwd = fx.origin_path, .base_tip = &fx.main_tip, .head = &fx.heads[0] });
    defer testing.allocator.free(pr1);
    const pr3 = try diffIn(.{ .cwd = fx.origin_path, .base_tip = &fx.main_tip, .head = &fx.heads[2] });
    defer testing.allocator.free(pr3);
    const worker = try fx.startWorker(.{ .budget_bytes = @max(pr1.len, pr3.len), .keep_nearest = 0 });
    defer worker.stop();
    worker.setFocus(1);
    const targets = fx.targets();
    const version = try worker.setTargets(&targets);
    _ = try waitForFocusIdle(worker, .{ .version = version, .focus = 1 });
    try testing.expect(try isCached(&fx.store, .{ .repo_id = fx.repo_id, .inputs = .{ .base_tip_oid = &fx.main_tip, .head_oid = &fx.heads[0] } }));

    worker.setFocus(3);
    _ = try waitForFocusIdle(worker, .{ .version = version, .focus = 3 });

    try testing.expectEqual(@as(i64, 1), try fx.diffRowCount());
    try testing.expect(try isCached(&fx.store, .{ .repo_id = fx.repo_id, .inputs = .{ .base_tip_oid = &fx.main_tip, .head_oid = &fx.heads[2] } }));
}

test "a focus move re-diffs only the rows that crossed the eviction boundary" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const log_path = try fx.tmpPath("diff.log");
    defer testing.allocator.free(log_path);
    const git_bin = try fx.diffLoggingGit(log_path);
    defer testing.allocator.free(git_bin);
    const worker = try fx.startWorker(.{ .git_bin = git_bin, .budget_bytes = try fx.twoRowBudget(), .keep_nearest = 0 });
    defer worker.stop();
    worker.setFocus(1);
    const targets = fx.targets();
    const version = try worker.setTargets(&targets);
    _ = try waitForFocusIdle(worker, .{ .version = version, .focus = 1 });
    const settled = try countLines(log_path);

    worker.setFocus(3);
    _ = try waitForFocusIdle(worker, .{ .version = version, .focus = 3 });

    // Only PR 3 moved inside the boundary; PR 1 and the whole-stack view are
    // past it and stay evicted without another `git diff`.
    try testing.expectEqual(@as(usize, 1), try countLines(log_path) - settled);
    try testing.expect(try isCached(&fx.store, .{ .repo_id = fx.repo_id, .inputs = .{ .base_tip_oid = &fx.main_tip, .head_oid = &fx.heads[2] } }));
    try testing.expect(!try isCached(&fx.store, .{ .repo_id = fx.repo_id, .inputs = .{ .base_tip_oid = &fx.main_tip, .head_oid = &fx.heads[0] } }));
}

test "a jump across rows of mixed sizes leaves the rows a fresh worker would cache" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const names = [_][]const u8{ "pr-1", "pr-2", "pr-3", "pr-4", "pr-5", "pr-6", "pr-7", "pr-8", "pr-9" };
    var heads: [names.len][40]u8 = undefined;
    var targets: [names.len]Target = undefined;
    var fresh_budget: u64 = 0;
    for (&heads, &targets, names, 1..) |*head, *target, name, number| {
        // PRs 7-9 are each larger than PRs 1-6 together.
        head.* = try fx.pushTrunkPr(.{ .number = @intCast(number), .branch = name, .lines = if (number > 6) 400 else 1 });
        target.* = .{
            .number = @intCast(number),
            .head_ref = name,
            .base_ref = "main",
            .head_oid = head,
            .updated_at = "2026-01-01T00:00:00Z",
            .base = .{ .trunk = .{ .oid = &fx.main_tip } },
        };
        const bytes = try diffIn(.{ .cwd = fx.origin_path, .base_tip = &fx.main_tip, .head = head });
        defer testing.allocator.free(bytes);
        if (number <= 7) fresh_budget += bytes.len;
    }

    const moved = try fx.startWorker(.{ .budget_bytes = fresh_budget, .keep_nearest = 0 });
    moved.setFocus(9);
    const version = try moved.setTargets(&targets);
    _ = try waitForFocusIdle(moved, .{ .version = version, .focus = 9 });
    moved.setFocus(1);
    _ = try waitForFocusIdle(moved, .{ .version = version, .focus = 1 });
    moved.stop();

    const fresh_db = try fx.tmpPath("fresh.db");
    defer testing.allocator.free(fresh_db);
    var fresh_store = try Store.open(testing.allocator, fresh_db);
    defer fresh_store.close();
    try testing.expectEqual(fx.repo_id, try fresh_store.ensureRepo(.{ .key = "github.com/o/r", .owner = "o", .name = "r" }));
    const fresh = try fx.startWorker(.{ .budget_bytes = fresh_budget, .keep_nearest = 0, .db_path = fresh_db });
    fresh.setFocus(1);
    _ = try waitForFocusIdle(fresh, .{ .version = try fresh.setTargets(&targets), .focus = 1 });
    fresh.stop();

    const expected = try cachedNumbers(&fresh_store, .{ .repo_id = fx.repo_id, .targets = &targets });
    try testing.expectEqual(@as(u64, 0b1111111), expected);
    try testing.expectEqual(expected, try cachedNumbers(&fx.store, .{ .repo_id = fx.repo_id, .targets = &targets }));
}

test "a focus move re-caches the rows another process deleted while the worker idled" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var heads: [9][40]u8 = undefined;
    var targets: [9]Target = undefined;
    const budget = try pushEqualPrs(.{ .fx = &fx, .heads = &heads, .targets = &targets, .rows = 3 });

    const moved = try fx.startWorker(.{ .budget_bytes = budget, .keep_nearest = 0 });
    moved.setFocus(1);
    const version = try moved.setTargets(&targets);
    _ = try waitForFocusIdle(moved, .{ .version = version, .focus = 1 });
    try fx.store.db.exec("DELETE FROM diff_cache");
    moved.setFocus(2);
    const moved_status = try waitForFocusIdle(moved, .{ .version = version, .focus = 2 });
    moved.stop();

    const fresh_db = try fx.tmpPath("fresh.db");
    defer testing.allocator.free(fresh_db);
    var fresh_store = try Store.open(testing.allocator, fresh_db);
    defer fresh_store.close();
    try testing.expectEqual(fx.repo_id, try fresh_store.ensureRepo(.{ .key = "github.com/o/r", .owner = "o", .name = "r" }));
    const fresh = try fx.startWorker(.{ .budget_bytes = budget, .keep_nearest = 0, .db_path = fresh_db });
    fresh.setFocus(2);
    const fresh_status = try waitForFocusIdle(fresh, .{ .version = try fresh.setTargets(&targets), .focus = 2 });
    fresh.stop();

    const expected = try cachedNumbers(&fresh_store, .{ .repo_id = fx.repo_id, .targets = &targets });
    try testing.expectEqual(@as(u64, 0b111), expected);
    try testing.expectEqual(expected, try cachedNumbers(&fx.store, .{ .repo_id = fx.repo_id, .targets = &targets }));
    try testing.expectEqual(fresh_status.diffs_ready, moved_status.diffs_ready);
}

test "an idle wake re-caches the rows another process deleted" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var heads: [9][40]u8 = undefined;
    var targets: [9]Target = undefined;
    const budget = try pushEqualPrs(.{ .fx = &fx, .heads = &heads, .targets = &targets, .rows = 3 });
    const worker = try fx.startWorker(.{ .budget_bytes = budget, .keep_nearest = 0 });
    defer worker.stop();
    worker.setFocus(1);
    _ = try waitForFocusIdle(worker, .{ .version = try worker.setTargets(&targets), .focus = 1 });
    try fx.store.db.exec("DELETE FROM diff_cache");

    worker.setFocus(1);

    try waitForRowCount(&fx, 3);
    try testing.expectEqual(@as(u64, 0b111), try cachedNumbers(&fx.store, .{ .repo_id = fx.repo_id, .targets = &targets }));
}

test "slotOf gives every view of every target its own consecutive slot" {
    var expected: usize = 0;
    for (0..4) |position| {
        for (std.enums.values(priority.View)) |view| {
            try testing.expectEqual(expected, slotOf(position, view));
            expected += 1;
        }
    }
}

test "markEvicted evicts every view that shares the deleted key and returns the nearest slot" {
    const shared: DiffKey = .{ .merge_base_oid = @splat('a'), .head_oid = @splat('b') };
    const other: DiffKey = .{ .merge_base_oid = @splat('c'), .head_oid = @splat('d') };
    var states = [_]priority.JobState{
        .{ .diff = .done },
        .{ .diff = .done, .whole_stack = .done },
        .{ .diff = .done },
    };
    const slots = [_]RankedSlot{
        .{ .key = other, .index = 0, .view = .pr, .slot = 0 },
        .{ .key = other, .index = 1, .view = .pr, .slot = 2 },
        .{ .key = shared, .index = 1, .view = .whole_stack, .slot = 3 },
        .{ .key = shared, .index = 2, .view = .pr, .slot = 4 },
    };

    const nearest = markEvicted(.{ .states = &states, .slots = &slots, .key = shared });

    try testing.expectEqual(@as(?usize, 3), nearest);
    try testing.expectEqual(priority.Outcome.evicted, states[1].whole_stack);
    try testing.expectEqual(priority.Outcome.evicted, states[2].diff);
    try testing.expectEqual(priority.Outcome.done, states[0].diff);
    try testing.expectEqual(priority.Outcome.done, states[1].diff);
}

test "a focus move re-pends the evicted views the new order puts inside the boundary" {
    var round: Round = .init(testing.allocator, false);
    defer round.deinit();
    var states = [_]priority.JobState{ .{ .diff = .done }, .{ .diff = .evicted }, .{ .diff = .evicted } };
    round.states = &states;
    round.ordered = &.{ 2, 0, 1 };
    round.boundary = slotOf(1, .pr);

    round.moveFocus(3);

    try testing.expectEqual(priority.Outcome.pending, states[2].diff);
    try testing.expectEqual(priority.Outcome.evicted, states[1].diff);
    try testing.expectEqual(priority.Outcome.done, states[0].diff);
}

test "restoreStranded re-pends evicted views nearer than the farthest cached one" {
    var round: Round = .init(testing.allocator, false);
    defer round.deinit();
    var states = [_]priority.JobState{
        .{ .diff = .done },
        .{ .diff = .evicted, .whole_stack = .evicted },
        .{ .diff = .done },
        .{ .diff = .evicted },
    };
    round.states = &states;
    round.ordered = &.{ 0, 1, 2, 3 };

    try testing.expect(round.restoreStranded());

    try testing.expectEqual(priority.Outcome.pending, states[1].diff);
    try testing.expectEqual(priority.Outcome.pending, states[1].whole_stack);
    try testing.expectEqual(priority.Outcome.evicted, states[3].diff);
}

test "restoreStranded leaves evicted views that lie past every cached one" {
    var round: Round = .init(testing.allocator, false);
    defer round.deinit();
    var states = [_]priority.JobState{ .{ .diff = .done }, .{ .diff = .done }, .{ .diff = .evicted }, .{ .diff = .evicted } };
    round.states = &states;
    round.ordered = &.{ 0, 1, 2, 3 };

    try testing.expect(!round.restoreStranded());

    try testing.expectEqual(priority.Outcome.evicted, states[2].diff);
    try testing.expectEqual(priority.Outcome.evicted, states[3].diff);
}

test "restoreStranded runs once per focus" {
    var round: Round = .init(testing.allocator, false);
    defer round.deinit();
    var states = [_]priority.JobState{ .{ .diff = .evicted }, .{ .diff = .done } };
    round.states = &states;
    round.ordered = &.{ 0, 1 };
    try testing.expect(round.restoreStranded());
    states[0].diff = .evicted;

    try testing.expect(!round.restoreStranded());
    round.moveFocus(7);
    try testing.expect(round.restoreStranded());
}

test "markEvicted returns null for a key no target maps to" {
    const key: DiffKey = .{ .merge_base_oid = @splat('a'), .head_oid = @splat('b') };
    var states = [_]priority.JobState{.{ .diff = .done }};
    const slots = [_]RankedSlot{.{ .key = .{ .merge_base_oid = @splat('c'), .head_oid = @splat('d') }, .index = 0, .view = .pr, .slot = 0 }};

    try testing.expectEqual(@as(?usize, null), markEvicted(.{ .states = &states, .slots = &slots, .key = key }));
    try testing.expectEqual(priority.Outcome.done, states[0].diff);
}

test "a new targets version at the same focus re-diffs only the first row past the boundary" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const log_path = try fx.tmpPath("diff.log");
    defer testing.allocator.free(log_path);
    const git_bin = try fx.diffLoggingGit(log_path);
    defer testing.allocator.free(git_bin);
    const worker = try fx.startWorker(.{ .git_bin = git_bin, .budget_bytes = try fx.twoRowBudget(), .keep_nearest = 2 });
    defer worker.stop();
    worker.setFocus(1);
    const targets = fx.targets();
    _ = try waitForFocusIdle(worker, .{ .version = try worker.setTargets(&targets), .focus = 1 });
    const settled = try countLines(log_path);

    _ = try waitForFocusIdle(worker, .{ .version = try worker.setTargets(&targets), .focus = 1 });

    // PR 1 and PR 2 (both views) are kept; PR 3 is diffed once, found past
    // the boundary, and nothing farther runs.
    try testing.expectEqual(@as(usize, 1), try countLines(log_path) - settled);
    try testing.expectEqual(@as(i64, 3), try fx.diffRowCount());
}

test "a diff written and evicted in the same job leaves the generation alone" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const worker = try fx.startWorker(.{ .budget_bytes = try fx.twoRowBudget(), .keep_nearest = 2 });
    defer worker.stop();
    worker.setFocus(1);
    const targets = fx.targets();
    _ = try waitForFocusIdle(worker, .{ .version = try worker.setTargets(&targets), .focus = 1 });
    const settled = worker.generation();

    _ = try waitForFocusIdle(worker, .{ .version = try worker.setTargets(&targets), .focus = 1 });

    try testing.expectEqual(settled, worker.generation());
}

test "runGit refuses to spawn once stop is requested" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const log_path = try fx.tmpPath("spawn.log");
    defer testing.allocator.free(log_path);
    const body = try std.fmt.allocPrint(testing.allocator, "echo ran >> '{s}'\nexec git \"$@\"\n", .{log_path});
    defer testing.allocator.free(body);
    const git_bin = try fx.writeScript("spawn-logging-git", body);
    defer testing.allocator.free(git_bin);
    var worker: PrefetchWorker = .{
        .allocator = testing.allocator,
        .config = .{ .repo_root = fx.clone_path, .db_path = fx.db_path, .repo_id = fx.repo_id, .owner = "o", .name = "r", .git_bin = git_bin },
        .targets_arena = .init(testing.allocator),
    };
    defer worker.targets_arena.deinit();
    worker.stop_requested.store(true, .release);
    var env = try skim_io.environ().createMap(testing.allocator);
    defer env.deinit();
    var round: Round = .init(testing.allocator, false);
    defer round.deinit();
    const ctx: Ctx = .{ .worker = &worker, .store = &fx.store, .env = &env, .round = &round };

    try testing.expectError(error.Stopped, runGit(ctx, .{ .argv = &.{ "git", "status" } }));
    try testing.expectEqual(@as(usize, 0), try countLines(log_path));
}

test "an unauthenticated gh is called once per targets version" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const log_path = try fx.tmpPath("gh.log");
    defer testing.allocator.free(log_path);
    const body = try std.fmt.allocPrint(testing.allocator, "echo call >> '{s}'\necho 'To get started with GitHub CLI, please run:  gh auth login' >&2\nexit 4\n", .{log_path});
    defer testing.allocator.free(body);
    const gh_bin = try fx.writeScript("unauthenticated-gh", body);
    defer testing.allocator.free(gh_bin);
    const worker = try fx.startWorker(.{ .gh_bin = gh_bin });
    defer worker.stop();
    const targets = fx.targets();

    const first = try waitForIdle(worker, try worker.setTargets(&targets));

    try testing.expectEqual(@as(usize, 1), try countLines(log_path));
    try testing.expectEqual(@as(?github.GhErrorKind, .not_authenticated), first.gh_error);
    try testing.expectEqual(@as(?LastError, .gh_failed), first.last_error);
    try testing.expectEqual(@as(u32, 3), first.diffs_ready);

    _ = try waitForIdle(worker, try worker.setTargets(&targets));

    try testing.expectEqual(@as(usize, 2), try countLines(log_path));
}

test "a repository gh cannot resolve disables thread jobs for the version" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const log_path = try fx.tmpPath("gh.log");
    defer testing.allocator.free(log_path);
    const body = try std.fmt.allocPrint(testing.allocator, "echo call >> '{s}'\necho \"GraphQL: Could not resolve to a Repository with the name 'o/r'. (repository)\" >&2\nexit 1\n", .{log_path});
    defer testing.allocator.free(body);
    const gh_bin = try fx.writeScript("no-repo-gh", body);
    defer testing.allocator.free(gh_bin);
    const worker = try fx.startWorker(.{ .gh_bin = gh_bin });
    defer worker.stop();
    const targets = fx.targets();

    const final = try waitForIdle(worker, try worker.setTargets(&targets));

    try testing.expectEqual(@as(usize, 1), try countLines(log_path));
    try testing.expectEqual(@as(?github.GhErrorKind, .not_found), final.gh_error);
}

test "stop does not wait out the grace period once the child's leader has exited" {
    // The early exit rests on waitid; elsewhere stop waits out the grace period.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    const pid_path = try fx.tmpPath("gh.pid");
    defer testing.allocator.free(pid_path);
    const body = try std.fmt.allocPrint(testing.allocator, "sleep 30 &\necho $$ > '{s}'\nwait\n", .{pid_path});
    defer testing.allocator.free(body);
    const gh_bin = try fx.writeScript("hung-gh", body);
    defer testing.allocator.free(gh_bin);
    const worker = try fx.startWorker(.{ .gh_bin = gh_bin });
    const targets = fx.targets();
    _ = try worker.setTargets(&targets);
    const gh_pid = try waitForPidFile(pid_path);

    var timer = try skim_io.Timer.start();
    worker.stop();

    try testing.expect(timer.read() < 250 * std.time.ns_per_ms);
    try testing.expect(processGone(gh_pid));
}

test "applyChildEnv makes ssh non-interactive when nothing configures it" {
    var env: EnvMap = .init(testing.allocator);
    defer env.deinit();
    try applyChildEnv(&env, .{ .has_core_ssh_command = false });
    try testing.expectEqualStrings(default_ssh_command, env.get("GIT_SSH_COMMAND").?);
    try testing.expectEqualStrings("0", env.get("GIT_TERMINAL_PROMPT").?);
    try testing.expectEqualStrings("C", env.get("LC_ALL").?);
}

test "applyChildEnv keeps the user's GIT_SSH_COMMAND" {
    var env: EnvMap = .init(testing.allocator);
    defer env.deinit();
    try env.put("GIT_SSH_COMMAND", "ssh -i key");
    try applyChildEnv(&env, .{ .has_core_ssh_command = false });
    try testing.expectEqualStrings("ssh -i key", env.get("GIT_SSH_COMMAND").?);
}

test "applyChildEnv does not shadow GIT_SSH" {
    var env: EnvMap = .init(testing.allocator);
    defer env.deinit();
    try env.put("GIT_SSH", "/usr/bin/plink");
    try applyChildEnv(&env, .{ .has_core_ssh_command = false });
    try testing.expectEqual(@as(?[]const u8, null), env.get("GIT_SSH_COMMAND"));
}

test "applyChildEnv does not shadow core.sshCommand" {
    var env: EnvMap = .init(testing.allocator);
    defer env.deinit();
    try applyChildEnv(&env, .{ .has_core_ssh_command = true });
    try testing.expectEqual(@as(?[]const u8, null), env.get("GIT_SSH_COMMAND"));
    try testing.expectEqualStrings("0", env.get("GIT_TERMINAL_PROMPT").?);
}

test "lookupCached returns the diff a worker stored" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const worker = try fx.startWorker(.{});
    defer worker.stop();
    const targets = fx.targets();
    _ = try waitForIdle(worker, try worker.setTargets(&targets));

    const cached = (try fx.cachedDiff(&fx.main_tip, &fx.heads[2])).?;
    defer testing.allocator.free(cached.bytes);
    const merge_base = try fx.mergeBase(&fx.main_tip, &fx.heads[2]);
    try testing.expectEqualStrings(&merge_base, &cached.key.merge_base_oid);
    try testing.expectEqualStrings(&fx.heads[2], &cached.key.head_oid);
    try testing.expect(try isCached(&fx.store, .{ .repo_id = fx.repo_id, .inputs = .{ .base_tip_oid = &fx.main_tip, .head_oid = &fx.heads[2] } }));
}

test "lookupCached is null before the merge base is known" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try testing.expectEqual(@as(?CachedDiff, null), try fx.cachedDiff(&fx.main_tip, &fx.heads[0]));
    try testing.expect(!try isCached(&fx.store, .{ .repo_id = fx.repo_id, .inputs = .{ .base_tip_oid = &fx.main_tip, .head_oid = &fx.heads[0] } }));
}

test "lookupCached is null when the merge base is known but the diff was evicted" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const merge_base = "c" ** 40;
    try fx.store.putMergeBase(fx.repo_id, .{ .base_tip_oid = &fx.main_tip, .head_oid = &fx.heads[0], .merge_base_oid = merge_base });
    try testing.expectEqual(@as(?CachedDiff, null), try fx.cachedDiff(&fx.main_tip, &fx.heads[0]));
}
