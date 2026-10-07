//! The native half of the PR sidebar surface (`App.state.pr_surface`): owns
//! the UI thread's `Store` connection (AD-2), the `SyncWorker` and the
//! `PrefetchWorker`, and is the only sidebar code that calls `Store`, the
//! workers or `github` (D4). It reads the DB into an in-memory snapshot for
//! the pure `sidebar/controller.zig`, and is the Store side of a PR flip
//! (cached diffs, seen marks, local notes). Web builds compile
//! `surface_stub.zig` instead.

const std = @import("std");
const skim_io = @import("skim_io");
const store = @import("db/store.zig");
const types = @import("db/types.zig");
const sync = @import("sync/sync.zig");
const github = @import("github.zig");
const git = @import("git.zig");
const config = @import("../config.zig");
const sidebar_controller = @import("sidebar/controller.zig");
const sidebar_state = @import("sidebar/state.zig");
const prefetch = @import("prefetch/prefetch.zig");
const priority = @import("prefetch/priority.zig");
const ParsedLru = @import("prefetch/parsed_lru.zig").ParsedLru;
const parser = @import("../git/parser.zig");
const comments = @import("../comments/store.zig");
const flip = @import("flip.zig");
const notes = @import("notes.zig");
const review_controller = @import("review_controller.zig");

const Allocator = std.mem.Allocator;
const SidebarState = sidebar_state.SidebarState;
const SyncSnapshot = sidebar_state.SyncSnapshot;
const PrRecord = types.PrRecord;
const DiffKey = types.DiffKey;

pub const Surface = struct {
    /// UI-thread connection (AD-2); null while closed or unavailable.
    store: ?store.Store = null,
    repo_id: i64 = 0,
    sync: ?*sync.SyncWorker = null,
    /// Last `SyncWorker.generation()` the sidebar was reloaded for.
    seen_sync_generation: u64 = 0,
    /// `sidebar.message` holds the corrupt-DB notice; cleared by the first
    /// successful sync.
    quarantine_notice: bool = false,
    prefetch: ?*prefetch.PrefetchWorker = null,
    /// Last `PrefetchWorker.generation()` the cache glyphs and the seen
    /// backfill ran for.
    seen_prefetch_generation: u64 = 0,
    /// One prefetch target per visible PR, in row order (D10). Rebuilt by
    /// `pushVisible` whether or not a worker runs. The strings borrow the
    /// sidebar's records, which every reload follows with a `pushVisible`.
    targets: std.ArrayList(priority.Target) = .empty,
    /// The allocator `targets` grows with; set by its first rebuild.
    targets_allocator: ?Allocator = null,
    /// `OpenParams.gh_bin`, borrowed while open; `openInBrowser` runs it.
    gh_bin: []const u8 = "gh",
};

pub const OpenParams = struct {
    allocator: Allocator,
    sidebar: *SidebarState,
    /// Forwarded to `SyncWorker`; the offline harness points it at a fake.
    gh_bin: []const u8 = "gh",
    /// Forwarded to `PrefetchWorker` for review threads; separate from
    /// `gh_bin` so the harness can point each worker at its own fake.
    prefetch_gh_bin: []const u8 = "gh",
    /// git cwd for the prefetch worker's children.
    repo_root: []const u8 = ".",
};

pub const OpenAtParams = struct {
    allocator: Allocator,
    sidebar: *SidebarState,
    db_path: []const u8,
    repo_key: []const u8,
    owner: []const u8,
    name: []const u8,
    /// Presets to install; null reads them from ~/.skim/config.json.
    filters: ?*const config.PrFilters = null,
};

pub const StartSyncParams = struct {
    sidebar: *SidebarState,
    db_path: []const u8,
    repo_key: []const u8,
    owner: []const u8,
    name: []const u8,
    gh_bin: []const u8 = "gh",
};

pub const ReloadParams = struct {
    allocator: Allocator,
    sidebar: *SidebarState,
};

pub const StartPrefetchParams = struct {
    allocator: Allocator,
    sidebar: *SidebarState,
    repo_root: []const u8,
    db_path: []const u8,
    owner: []const u8,
    name: []const u8,
    gh_bin: []const u8 = "gh",
};

pub const SeenParams = struct {
    allocator: Allocator,
    number: u32,
    sidebar: *SidebarState,
    /// Unix seconds.
    now: i64,
};

pub const MyReviewParams = struct {
    allocator: Allocator,
    number: u32,
    sidebar: *SidebarState,
    /// GitHub review state, e.g. "APPROVED".
    state: []const u8,
    /// Commit the review was submitted against.
    oid: []const u8,
};

pub const PlanParams = struct {
    allocator: Allocator,
    sidebar: *const SidebarState,
    record: *const PrRecord,
    view: flip.DiffView,
    /// Null when no LRU exists (the parsed set then always comes from the DB).
    lru: ?*ParsedLru,
    /// Unix seconds; bumps the diff row's last_used_at on a DB hit.
    now: i64,
};

/// A cached diff ready to install without spawning anything.
pub const FlipHit = struct {
    /// Owned; installing moves it into the App.
    files: []parser.FileDiff,
    key: DiffKey,
    /// Owned. `.pr` view only.
    threads: ?types.CachedThreads,
    /// `threads` was fetched at the PR's current `updated_at`.
    threads_fresh: bool,
    /// The base branch the diff source compares against: the stack bottom's
    /// for the whole-stack view, else the PR's. Borrows the sidebar records.
    stack_base_ref: []const u8,

    pub fn deinit(self: *FlipHit, allocator: Allocator) void {
        freeFiles(allocator, self.files);
        if (self.threads) |threads| threads.deinit(allocator);
    }
};

pub const FlipPlan = union(enum) {
    hit: FlipHit,
    miss,

    pub fn deinit(self: *FlipPlan, allocator: Allocator) void {
        switch (self.*) {
            .hit => |*hit| hit.deinit(allocator),
            .miss => {},
        }
    }
};

/// How a PR's head relates to the head the user last marked seen (FR-8),
/// read from the merge base the prefetch worker's `.since_seen` job cached.
pub const SeenComparison = enum {
    /// Never seen, or seen at the current head.
    unchanged,
    /// The seen head is an ancestor of the head: a seen..head diff exists.
    fast_forward,
    /// History was rewritten; only per-file comparison is possible.
    rewritten,
    /// The worker has not compared them yet.
    pending,
};

pub const SaveNotesParams = struct {
    allocator: Allocator,
    number: u32,
    comments: *const comments.CommentStore,
    /// The diff the comments are anchored in.
    files: []const parser.FileDiff,
    /// Comment.id → local_note.id; new rows are added.
    note_ids: *std.AutoHashMapUnmanaged(u64, i64),
    /// Unix seconds.
    now: i64,
};

pub const RestoreNotesParams = struct {
    allocator: Allocator,
    number: u32,
    files: []const parser.FileDiff,
    /// Already cleared by the PR switch.
    comments: *comments.CommentStore,
    orphans: *std.ArrayList(notes.OrphanNote),
    note_ids: *std.AutoHashMapUnmanaged(u64, i64),
};

pub const ChangedFilesParams = struct {
    allocator: Allocator,
    sidebar: *const SidebarState,
    number: u32,
    /// The PR's diff on screen.
    current: []const parser.FileDiff,
    lru: ?*ParsedLru,
    /// Unix seconds.
    now: i64,
};

const TargetsParams = struct { allocator: Allocator, sidebar: *const SidebarState, numbers: []const u32 };

/// 40 ASCII zeros: "seen before the merge base was known". `getSeen` rejects
/// any oid that is not 40 chars, so an empty string is not an option.
/// `poll` backfills it once the prefetch worker resolves the merge base.
pub const unknown_merge_base: [40]u8 = @splat('0');

const quarantine_prefix = "PR database was corrupt";

/// Resolve the repo, open the store, load presets, paint the sidebar from the
/// DB, then start the sync worker. Failures set `sidebar.unavailable` /
/// `sidebar.message` instead of returning an error (NFR-3). No-op when the
/// surface is already open.
pub fn open(surface: *Surface, params: OpenParams) void {
    if (surface.store != null) return;
    const allocator = params.allocator;
    const sidebar = params.sidebar;
    sidebar.unavailable = .none;
    surface.gh_bin = params.gh_bin;

    const url = git.repoKey(allocator) orelse {
        sidebar.unavailable = .not_github;
        return;
    };
    defer allocator.free(url);
    const repo_key = std.mem.trim(u8, url, " \t\r\n");
    const owner_repo = github.parseOwnerRepo(allocator, repo_key) catch {
        sidebar.unavailable = .not_github;
        return;
    };
    defer {
        allocator.free(owner_repo.owner);
        allocator.free(owner_repo.repo);
    }

    const db_path = store.defaultPath(allocator) catch |err| {
        std.log.warn("pr surface: no PR database path: {}", .{err});
        sidebar.unavailable = .db_error;
        sidebar_controller.setMessage(sidebar, "PR database unavailable: HOME not set");
        return;
    };
    defer allocator.free(db_path);

    openAt(surface, .{
        .allocator = allocator,
        .sidebar = sidebar,
        .db_path = db_path,
        .repo_key = repo_key,
        .owner = owner_repo.owner,
        .name = owner_repo.repo,
    });
    if (surface.store == null) return;
    startSync(surface, .{
        .sidebar = sidebar,
        .db_path = db_path,
        .repo_key = repo_key,
        .owner = owner_repo.owner,
        .name = owner_repo.repo,
        .gh_bin = params.gh_bin,
    });
    // Ends with the pushVisible the paint ran before either worker existed.
    startPrefetch(surface, .{
        .allocator = allocator,
        .sidebar = sidebar,
        .repo_root = params.repo_root,
        .db_path = db_path,
        .owner = owner_repo.owner,
        .name = owner_repo.repo,
        .gh_bin = params.prefetch_gh_bin,
    });
}

/// The store half of `open` for an already-resolved repo and path: open (and
/// quarantine) the DB, register the repo, load presets and paint. Spawns no
/// subprocess, so tests call it directly on a temp path.
pub fn openAt(surface: *Surface, params: OpenAtParams) void {
    const allocator = params.allocator;
    const sidebar = params.sidebar;
    if (std.fs.path.dirname(params.db_path)) |dir| {
        std.Io.Dir.cwd().createDirPath(skim_io.get(), dir) catch |err| {
            std.log.warn("pr surface: cannot create {s}: {}", .{ dir, err });
            return failDb(sidebar);
        };
    }
    var db = store.Store.open(allocator, params.db_path) catch |err| {
        std.log.warn("pr surface: cannot open {s}: {}", .{ params.db_path, err });
        return failDb(sidebar);
    };
    if (db.quarantined_path) |path| {
        var buf: [128]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, quarantine_prefix ++ "; moved to {s}. Rebuilding from GitHub", .{std.fs.path.basename(path)}) catch quarantine_prefix;
        sidebar_controller.setMessage(sidebar, message);
        surface.quarantine_notice = true;
    }
    const repo_id = db.ensureRepo(.{ .key = params.repo_key, .owner = params.owner, .name = params.name }) catch |err| {
        std.log.warn("pr surface: cannot register repo {s}: {}", .{ params.repo_key, err });
        db.close();
        return failDb(sidebar);
    };
    surface.store = db;
    surface.repo_id = repo_id;

    if (params.filters) |filters| {
        installPresets(allocator, sidebar, filters);
    } else {
        loadPresets(allocator, sidebar);
    }
    reload(surface, .{ .allocator = allocator, .sidebar = sidebar }) catch |err| {
        std.log.warn("pr surface: initial reload failed: {}", .{err});
        failDb(sidebar);
    };
}

/// Start the sync worker for the repo `openAt` registered. A failure leaves
/// the list usable from the DB and shows a sync error.
pub fn startSync(surface: *Surface, params: StartSyncParams) void {
    const worker = sync.SyncWorker.start(.{
        .repo_key = params.repo_key,
        .owner = params.owner,
        .name = params.name,
        .db_path = params.db_path,
        .gh_bin = params.gh_bin,
        // What the paint read from the UI connection, until the worker has
        // read it from its own.
        .initial_status = .{
            .running = false,
            .last_ok_at = params.sidebar.sync.last_ok_at,
            .last_error = if (params.sidebar.sync.last_error) |kind| ghKind(kind) else null,
        },
    }) catch |err| {
        std.log.warn("pr surface: sync worker failed to start: {}", .{err});
        params.sidebar.sync.last_error = .other;
        return;
    };
    surface.sync = worker;
    surface.seen_sync_generation = worker.generation();
    params.sidebar.sync = workerSnapshot(worker.status());
}

/// Start the prefetch worker for the repo `openAt` registered, then push the
/// visible set to both workers and paint the cache glyphs. A failure leaves
/// every flip a miss.
pub fn startPrefetch(surface: *Surface, params: StartPrefetchParams) void {
    if (surface.prefetch == null and surface.store != null) {
        // A worker `stop` had to detach frees itself whenever it exits, so
        // it must not allocate from the App's allocator, which may be
        // deinitialised by then.
        if (prefetch.start(std.heap.c_allocator, .{
            .repo_root = params.repo_root,
            .db_path = params.db_path,
            .repo_id = surface.repo_id,
            .owner = params.owner,
            .name = params.name,
            .gh_bin = params.gh_bin,
        })) |worker| {
            surface.prefetch = worker;
            surface.seen_prefetch_generation = worker.generation();
        } else |err| {
            std.log.warn("pr surface: prefetch worker failed to start: {}", .{err});
        }
    }
    const reload_params: ReloadParams = .{ .allocator = params.allocator, .sidebar = params.sidebar };
    pushVisible(surface, reload_params);
    refreshCached(surface, reload_params) catch |err| {
        std.log.warn("pr surface: cache glyphs not refreshed: {}", .{err});
    };
}

/// Stop the prefetch worker, then the sync worker. The store stays open.
pub fn stopWorkers(surface: *Surface) void {
    if (surface.prefetch) |worker| worker.stop();
    surface.prefetch = null;
    if (surface.sync) |worker| worker.stop();
    surface.sync = null;
}

/// Re-read the open PRs (with their seen baseline) and the repo row, install
/// them in the sidebar, then push the visible set to the workers. No-op while
/// no store is open.
pub fn reload(surface: *Surface, params: ReloadParams) !void {
    const db = if (surface.store) |*s| s else return;
    var records = try db.listOpen(params.allocator, surface.repo_id);
    var repo = (db.getRepo(params.allocator, surface.repo_id) catch |err| {
        records.deinit();
        return err;
    }) orelse {
        records.deinit();
        return error.RepoMissing;
    };
    defer repo.deinit();
    try sidebar_controller.applySnapshot(params.sidebar, params.allocator, .{
        .records = records,
        .viewer_login = repo.row.viewer_login orelse "",
        .viewer_teams = repo.row.viewer_teams,
        .sync = syncSnapshot(surface, repo.row),
    });
    // The DB answered, so a `.db_error` left by an earlier failed reload no
    // longer holds. gh states stay: `poll` owns those.
    if (params.sidebar.unavailable == .db_error) params.sidebar.unavailable = .none;
    pushVisible(surface, params);
}

/// FR-5: hydrate and prefetch the PRs the filter shows first. Rebuilds
/// `targets` even without a prefetch worker.
pub fn pushVisible(surface: *Surface, params: ReloadParams) void {
    const numbers = sidebar_controller.visibleNumbers(params.sidebar, params.allocator) catch |err| {
        std.log.warn("pr surface: skipping hydrate priority: {}", .{err});
        return;
    };
    defer params.allocator.free(numbers);
    if (surface.sync) |worker| worker.setHydratePriority(numbers);
    setTargets(surface, .{ .allocator = params.allocator, .sidebar = params.sidebar, .numbers = numbers });
}

/// Prefetch the PR under the sidebar cursor next.
pub fn focusPrefetch(surface: *Surface, sidebar: *const SidebarState) void {
    const worker = surface.prefetch orelse return;
    const record = sidebar_controller.selectedPr(sidebar) orelse return;
    worker.setFocus(record.number);
}

/// Main-loop hook: reload when the sync worker committed rows, refresh the
/// sync status, map gh failures onto `unavailable` while the DB is empty,
/// and refresh the cache glyphs and seen backfill when the prefetch worker
/// committed. True when the sidebar changed.
pub fn poll(surface: *Surface, params: ReloadParams) bool {
    const synced = pollSync(surface, params);
    const prefetched = pollPrefetch(surface, params);
    return synced or prefetched;
}

/// Resolve a flip without a subprocess (AD-5): the PR's DiffKey from
/// merge_base_cache, then its parsed set from the LRU or the cached bytes.
/// `.miss` when any step has nothing cached.
pub fn planFlip(surface: *Surface, params: PlanParams) !FlipPlan {
    const db = if (surface.store) |*s| s else return .miss;
    const sidebar = params.sidebar;
    const items = (sidebar.records orelse return .miss).items;
    const index = sidebar_controller.recordIndex(sidebar, params.record.number) orelse return .miss;
    const place = sidebar_controller.stackPlace(sidebar, index);
    const whole_stack = params.view == .whole_stack;
    const target_index = if (whole_stack) place.tip orelse return .miss else index;
    const inputs = priority.diffKeyFor(targetAt(sidebar, target_index), params.view) orelse return .miss;
    const head = oidArray(inputs.head_oid) orelse return .miss;
    const merge_base = (try db.getMergeBase(surface.repo_id, .{ .base_tip_oid = inputs.base_tip_oid, .head_oid = inputs.head_oid })) orelse return .miss;
    // A rewritten since-seen pair has a merge base but no seen..head diff.
    if (params.view == .since_seen and !std.ascii.eqlIgnoreCase(&merge_base, inputs.base_tip_oid)) return .miss;
    const key: DiffKey = .{ .merge_base_oid = merge_base, .head_oid = head };

    const taken = if (params.lru) |lru| lru.take(key) else null;
    const files = taken orelse (try parseCached(surface, .{ .allocator = params.allocator, .inputs = inputs, .now = params.now })) orelse return .miss;
    errdefer freeFiles(params.allocator, files);
    const threads = if (params.view == .pr) try db.getThreads(params.allocator, .{ .repo_id = surface.repo_id, .number = params.record.number }) else null;
    return .{ .hit = .{
        .files = files,
        .key = key,
        .threads = threads,
        .threads_fresh = if (threads) |cached| std.mem.eql(u8, cached.pr_updated_at, params.record.updated_at) else false,
        .stack_base_ref = if (whole_stack) items[place.bottom.?].base_ref else params.record.base_ref,
    } };
}

/// AD-9: mark PR `number` seen at its current head, then reload so the
/// sidebar's `Δ` and `is:seen` follow. The merge base is the sentinel until
/// the worker resolves it (`poll` backfills).
pub fn markSeen(surface: *Surface, params: SeenParams) void {
    writeSeen(surface, params) catch |err| {
        std.log.warn("pr surface: marking #{d} seen failed: {}", .{ params.number, err });
    };
}

/// `m`: unseen when seen at the current head, else seen.
pub fn toggleSeen(surface: *Surface, params: SeenParams) void {
    const record = sidebar_controller.recordByNumber(params.sidebar, params.number) orelse return;
    if (!seenAtHead(record)) return markSeen(surface, params);
    clearSeen(surface, params) catch |err| {
        std.log.warn("pr surface: clearing #{d} seen failed: {}", .{ params.number, err });
    };
}

/// Show a review the viewer just submitted in the sidebar without waiting
/// for the sync to pick it up.
pub fn recordMyReview(surface: *Surface, params: MyReviewParams) void {
    writeMyReview(surface, params) catch |err| {
        std.log.warn("pr surface: recording review on #{d} failed: {}", .{ params.number, err });
    };
}

pub fn seenComparison(surface: *Surface, params: struct { sidebar: *const SidebarState, number: u32 }) SeenComparison {
    const record = sidebar_controller.recordByNumber(params.sidebar, params.number) orelse return .unchanged;
    const seen = record.seen_head_oid orelse return .unchanged;
    if (std.mem.eql(u8, seen, record.head_oid)) return .unchanged;
    const db = if (surface.store) |*s| s else return .pending;
    const merge_base = (db.getMergeBase(surface.repo_id, .{ .base_tip_oid = seen, .head_oid = record.head_oid }) catch |err| {
        std.log.warn("pr surface: since-seen merge base read failed: {}", .{err});
        return .pending;
    }) orelse return .pending;
    return if (std.ascii.eqlIgnoreCase(&merge_base, seen)) .fast_forward else .rewritten;
}

/// Seen records whose merge base is still the sentinel get the real one
/// once merge_base_cache has it; reloads when any row changed.
pub fn backfillSeen(surface: *Surface, params: ReloadParams) !void {
    const db = if (surface.store) |*s| s else return;
    const records = params.sidebar.records orelse return;
    var wrote = false;
    for (records.items, 0..) |*record, index| {
        if (!seenAtHead(record)) continue;
        const seen_merge_base = record.seen_merge_base_oid orelse continue;
        if (!std.mem.eql(u8, seen_merge_base, &unknown_merge_base)) continue;
        const merge_base = (try mergeBaseAt(surface, .{ .sidebar = params.sidebar, .index = index })) orelse continue;
        try db.setSeen(.{
            .repo_id = surface.repo_id,
            .number = record.number,
            .head_oid = record.head_oid,
            .merge_base_oid = &merge_base,
            .now = skim_io.timestamp(),
        });
        wrote = true;
    }
    if (wrote) try reload(surface, params);
}

/// FR-8: per file of `current`, whether its +/- lines differ from the diff
/// the user last saw. Empty when the PR is unchanged since seen, or the seen
/// diff is unavailable (unknown merge base, row gone). Caller owns.
pub fn changedFiles(surface: *Surface, params: ChangedFilesParams) ![]bool {
    const allocator = params.allocator;
    const key = seenKey(params.sidebar, params.number) orelse return allocator.alloc(bool, 0);
    if (params.lru) |lru| {
        if (lru.take(key)) |seen| {
            defer lru.put(key, seen);
            return flip.changedFiles(allocator, .{ .seen = seen, .current = params.current });
        }
    }
    const db = if (surface.store) |*s| s else return allocator.alloc(bool, 0);
    const bytes = (try db.getDiff(allocator, .{ .repo_id = surface.repo_id, .key = key, .now = params.now })) orelse return allocator.alloc(bool, 0);
    defer allocator.free(bytes);
    const seen = try parser.parse(allocator, bytes);
    defer freeFiles(allocator, seen);
    return flip.changedFiles(allocator, .{ .seen = seen, .current = params.current });
}

/// FR-9: write the PR's CommentStore back to `local_note` (insert new,
/// update edited, delete removed; orphans untouched).
pub fn saveNotes(surface: *Surface, params: SaveNotesParams) !void {
    const db = if (surface.store) |*s| s else return;
    const allocator = params.allocator;
    var saved = try db.listNotes(allocator, .{ .repo_id = surface.repo_id, .number = params.number });
    defer saved.deinit();
    var plan = try notes.planSave(.{
        .allocator = allocator,
        .number = params.number,
        .comments = params.comments,
        .files = params.files,
        .note_ids = params.note_ids,
        .saved = saved.items,
        .now = params.now,
    });
    defer plan.deinit(allocator);
    for (plan.inserts) |insert| {
        const id = try db.insertNote(surface.repo_id, insert.row);
        try params.note_ids.put(allocator, insert.comment_id, id);
    }
    for (plan.updates) |update| try db.updateNote(.{ .id = update.id, .text = update.text, .replies = update.replies });
    for (plan.deletes) |id| {
        try db.deleteNote(id);
        forgetNote(params.note_ids, id);
    }
}

/// FR-9: the PR's persisted notes into `comments`; the ones that anchor
/// nowhere in `files` become orphans.
pub fn restoreNotes(surface: *Surface, params: RestoreNotesParams) !void {
    const restore_params: notes.RestoreParams = .{
        .allocator = params.allocator,
        .notes = &.{},
        .files = params.files,
        .comments = params.comments,
        .orphans = params.orphans,
        .note_ids = params.note_ids,
    };
    const db = if (surface.store) |*s| s else return notes.restore(restore_params);
    var rows = try db.listNotes(params.allocator, .{ .repo_id = surface.repo_id, .number = params.number });
    defer rows.deinit();
    var with_rows = restore_params;
    with_rows.notes = rows.items;
    try notes.restore(with_rows);
}

/// Hand the review session this repo's owner/name, so its entry and refetch
/// workers never run git to resolve them (a refetch stays gh-only).
pub fn shareOwnerRepo(surface: *Surface, params: struct { allocator: Allocator, review: *review_controller.ReviewSession }) void {
    const db = if (surface.store) |*s| s else return;
    var repo = (db.getRepo(params.allocator, surface.repo_id) catch |err| {
        std.log.warn("pr surface: repo row unreadable: {}", .{err});
        return;
    }) orelse return;
    defer repo.deinit();
    review_controller.setOwnerRepo(params.review, params.allocator, .{ .owner = repo.row.owner, .repo = repo.row.name }) catch |err| {
        std.log.warn("pr surface: review session keeps resolving owner/repo itself: {}", .{err});
    };
}

/// The main loop keeps ticking while the surface is open so a sync landing
/// in the background is drawn without waiting for input.
pub fn wantsTick(surface: *const Surface) bool {
    return surface.store != null or surface.sync != null;
}

pub fn requestSync(surface: *Surface) void {
    const worker = surface.sync orelse return;
    worker.requestSync();
}

/// `gh pr view <n> --web` for the selected PR, with the `gh` the surface was
/// opened with. Blocks until `gh` exits.
pub fn openInBrowser(surface: *const Surface, sidebar: *const SidebarState) void {
    const record = sidebar_controller.selectedPr(sidebar) orelse return;
    var buf: [16]u8 = undefined;
    const num = std.fmt.bufPrint(&buf, "{d}", .{record.number}) catch return;
    var child = std.process.spawn(skim_io.get(), .{
        .argv = &.{ surface.gh_bin, "pr", "view", num, "--web" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        std.log.warn("pr surface: opening #{d} in the browser failed: {any}", .{ record.number, err });
        return;
    };
    const term = child.wait(skim_io.get()) catch |err| {
        std.log.warn("pr surface: waiting on gh for #{d} failed: {any}", .{ record.number, err });
        return;
    };
    if (term != .exited or term.exited != 0) std.log.warn("pr surface: gh pr view #{d} --web ended with {any}", .{ record.number, term });
}

/// Stop both workers and close the store.
pub fn close(surface: *Surface) void {
    stopWorkers(surface);
    if (surface.targets_allocator) |allocator| surface.targets.deinit(allocator);
    if (surface.store) |*db| db.close();
    surface.* = .{};
}

// =============================================================================
// Helpers
// =============================================================================

comptime {
    // syncSnapshot maps GhErrorKind onto SyncErrorKind by tag name.
    const gh = @typeInfo(github.GhErrorKind).@"enum".fields;
    const kinds = @typeInfo(types.SyncErrorKind).@"enum".fields;
    std.debug.assert(gh.len == kinds.len);
    for (gh, kinds) |a, b| std.debug.assert(std.mem.eql(u8, a.name, b.name));
}

fn pollSync(surface: *Surface, params: ReloadParams) bool {
    const worker = surface.sync orelse return false;
    const sidebar = params.sidebar;
    var changed = false;
    const generation = worker.generation();
    if (generation != surface.seen_sync_generation) {
        surface.seen_sync_generation = generation;
        reload(surface, params) catch |err| {
            std.log.warn("pr surface: reload failed: {}", .{err});
        };
        changed = true;
    }

    const snapshot = workerSnapshot(worker.status());
    if (!std.meta.eql(snapshot, sidebar.sync)) {
        sidebar.sync = snapshot;
        changed = true;
    }
    if (surface.quarantine_notice and snapshot.last_ok_at != null and snapshot.last_error == null) {
        surface.quarantine_notice = false;
        if (std.mem.startsWith(u8, sidebar.messageText(), quarantine_prefix)) sidebar_controller.setMessage(sidebar, "");
        changed = true;
    }

    const unavailable = ghUnavailable(sidebar);
    if (unavailable != sidebar.unavailable) {
        sidebar.unavailable = unavailable;
        changed = true;
    }
    return changed;
}

fn pollPrefetch(surface: *Surface, params: ReloadParams) bool {
    const worker = surface.prefetch orelse return false;
    const generation = worker.generation();
    if (generation == surface.seen_prefetch_generation) return false;
    surface.seen_prefetch_generation = generation;
    backfillSeen(surface, params) catch |err| {
        std.log.warn("pr surface: seen backfill failed: {}", .{err});
    };
    refreshCached(surface, params) catch |err| {
        std.log.warn("pr surface: cache glyphs not refreshed: {}", .{err});
    };
    return true;
}

fn setTargets(surface: *Surface, params: TargetsParams) void {
    rebuildTargets(surface, params) catch |err| {
        std.log.warn("pr surface: prefetch targets not updated: {}", .{err});
        return;
    };
    const worker = surface.prefetch orelse return;
    _ = worker.setTargets(surface.targets.items) catch |err| {
        std.log.warn("pr surface: prefetch targets not handed over: {}", .{err});
    };
}

fn rebuildTargets(surface: *Surface, params: TargetsParams) !void {
    surface.targets_allocator = params.allocator;
    surface.targets.clearRetainingCapacity();
    for (params.numbers) |number| {
        const index = sidebar_controller.recordIndex(params.sidebar, number) orelse continue;
        try surface.targets.append(params.allocator, targetAt(params.sidebar, index));
    }
}

/// The prefetch target of record `index`, with its stack placement.
fn targetAt(sidebar: *const SidebarState, index: usize) priority.Target {
    const items = sidebar.records.?.items;
    const place = sidebar_controller.stackPlace(sidebar, index);
    return priority.targetFor(.{
        .rec = &items[index],
        .parent = if (place.parent) |parent| &items[parent] else null,
        .bottom = if (place.bottom) |bottom| &items[bottom] else null,
        .is_tip = if (place.tip) |tip| tip == index else false,
    });
}

/// The `.pr` view merge base of record `index`, when cached.
fn mergeBaseAt(surface: *Surface, params: struct { sidebar: *const SidebarState, index: usize }) !?[40]u8 {
    const db = if (surface.store) |*s| s else return null;
    const inputs = priority.diffKeyFor(targetAt(params.sidebar, params.index), .pr) orelse return null;
    return db.getMergeBase(surface.repo_id, .{ .base_tip_oid = inputs.base_tip_oid, .head_oid = inputs.head_oid });
}

fn refreshCached(surface: *Surface, params: ReloadParams) !void {
    const db = if (surface.store) |*s| s else return;
    const cached = &params.sidebar.cached;
    cached.clearRetainingCapacity();
    for (surface.targets.items) |target| {
        const inputs = priority.diffKeyFor(target, .pr) orelse continue;
        if (try prefetch.isCached(db, .{ .repo_id = surface.repo_id, .inputs = inputs })) try cached.put(params.allocator, target.number, {});
    }
}

fn parseCached(surface: *Surface, params: struct { allocator: Allocator, inputs: priority.KeyInputs, now: i64 }) !?[]parser.FileDiff {
    const db = if (surface.store) |*s| s else return null;
    const cached = (try prefetch.lookupCached(db, .{ .allocator = params.allocator, .repo_id = surface.repo_id, .inputs = params.inputs, .now = params.now })) orelse return null;
    defer params.allocator.free(cached.bytes);
    return try parser.parse(params.allocator, cached.bytes);
}

fn writeSeen(surface: *Surface, params: SeenParams) !void {
    const db = if (surface.store) |*s| s else return;
    const index = sidebar_controller.recordIndex(params.sidebar, params.number) orelse return;
    const record = &params.sidebar.records.?.items[index];
    const merge_base = (try mergeBaseAt(surface, .{ .sidebar = params.sidebar, .index = index })) orelse unknown_merge_base;
    try db.setSeen(.{
        .repo_id = surface.repo_id,
        .number = params.number,
        .head_oid = record.head_oid,
        .merge_base_oid = &merge_base,
        .now = params.now,
    });
    try reload(surface, .{ .allocator = params.allocator, .sidebar = params.sidebar });
}

fn writeMyReview(surface: *Surface, params: MyReviewParams) !void {
    const db = if (surface.store) |*s| s else return;
    try db.setMyReview(.{ .repo_id = surface.repo_id, .number = params.number, .state = params.state, .oid = params.oid });
    try reload(surface, .{ .allocator = params.allocator, .sidebar = params.sidebar });
}

fn clearSeen(surface: *Surface, params: SeenParams) !void {
    const db = if (surface.store) |*s| s else return;
    try db.clearSeen(surface.repo_id, params.number);
    try reload(surface, .{ .allocator = params.allocator, .sidebar = params.sidebar });
}

fn seenAtHead(record: *const PrRecord) bool {
    const seen = record.seen_head_oid orelse return false;
    return std.mem.eql(u8, seen, record.head_oid);
}

/// The DiffKey of the diff the user last saw (pinned by its seen row), when
/// the PR changed since and the seen merge base is known.
fn seenKey(sidebar: *const SidebarState, number: u32) ?DiffKey {
    const record = sidebar_controller.recordByNumber(sidebar, number) orelse return null;
    const seen_head = record.seen_head_oid orelse return null;
    if (std.mem.eql(u8, seen_head, record.head_oid)) return null;
    const seen_merge_base = record.seen_merge_base_oid orelse return null;
    if (std.mem.eql(u8, seen_merge_base, &unknown_merge_base)) return null;
    return .{
        .merge_base_oid = oidArray(seen_merge_base) orelse return null,
        .head_oid = oidArray(seen_head) orelse return null,
    };
}

fn forgetNote(note_ids: *std.AutoHashMapUnmanaged(u64, i64), note_id: i64) void {
    var it = note_ids.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != note_id) continue;
        note_ids.removeByPtr(entry.key_ptr);
        return;
    }
}

fn oidArray(oid: []const u8) ?[40]u8 {
    if (oid.len != 40) return null;
    return oid[0..40].*;
}

fn freeFiles(allocator: Allocator, files: []parser.FileDiff) void {
    for (files) |*file| file.deinit(allocator);
    allocator.free(files);
}

fn failDb(sidebar: *SidebarState) void {
    sidebar.unavailable = .db_error;
    sidebar_controller.setMessage(sidebar, "PR database unavailable — see ~/.skim/tui.log");
}

/// Configured presets, or the built-in `all` when config cannot be read.
fn loadPresets(allocator: Allocator, sidebar: *SidebarState) void {
    var cfg = config.load(allocator) catch |err| {
        // No config file is the default setup, not a failure.
        if (err != error.FileNotFound) std.log.warn("pr surface: config load failed, using the built-in preset: {}", .{err});
        installPresets(allocator, sidebar, &config.PrFilters{});
        return;
    };
    defer cfg.deinit(allocator);
    installPresets(allocator, sidebar, &cfg.pr_filters);
}

fn installPresets(allocator: Allocator, sidebar: *SidebarState, filters: *const config.PrFilters) void {
    sidebar_controller.setPresets(sidebar, allocator, filters) catch |err| {
        std.log.warn("pr surface: cannot install presets: {}", .{err});
    };
}

/// gh missing / unauthenticated make the surface unavailable only while the
/// DB has nothing to show; with rows, the stale list stays and the header
/// carries the error.
fn ghUnavailable(sidebar: *const SidebarState) sidebar_state.Unavailable {
    const current = sidebar.unavailable;
    const keeps_gh_state = current == .none or current == .gh_missing or current == .gh_unauthenticated;
    if (!keeps_gh_state) return current;
    const rows = if (sidebar.records) |records| records.items.len else 0;
    if (rows > 0) return .none;
    const kind = sidebar.sync.last_error orelse return .none;
    return switch (kind) {
        .not_installed => .gh_missing,
        .not_authenticated => .gh_unauthenticated,
        else => .none,
    };
}

fn syncSnapshot(surface: *Surface, repo: types.RepoRow) SyncSnapshot {
    if (surface.sync) |worker| return workerSnapshot(worker.status());
    const kind = if (repo.last_sync_error) |tag| std.meta.stringToEnum(types.SyncErrorKind, tag) else null;
    return .{
        .last_ok_at = if (repo.last_sync_at > 0) repo.last_sync_at else null,
        .last_error = kind,
        .last_error_message = if (kind) |k| github.kindMessage(ghKind(k)) else "",
    };
}

fn workerSnapshot(status: sync.SyncStatus) SyncSnapshot {
    const kind = status.last_error orelse return .{ .running = status.running, .last_ok_at = status.last_ok_at };
    return .{
        .running = status.running,
        .last_ok_at = status.last_ok_at,
        .last_error = std.meta.stringToEnum(types.SyncErrorKind, @tagName(kind)).?,
        .last_error_message = github.kindMessage(kind),
    };
}

fn ghKind(kind: types.SyncErrorKind) github.GhErrorKind {
    return std.meta.stringToEnum(github.GhErrorKind, @tagName(kind)).?;
}
