//! The native half of the PR sidebar surface (`App.state.pr_surface`): owns
//! the UI thread's `Store` connection (AD-2) and the `SyncWorker`, and is the
//! only sidebar code that calls `Store`, `SyncWorker` or `github` (D4). It
//! reads the DB into an in-memory snapshot for the pure
//! `sidebar/controller.zig`. Web builds compile `surface_stub.zig` instead.

const std = @import("std");
const skim_io = @import("skim_io");
const store = @import("db/store.zig");
const types = @import("db/types.zig");
const sync = @import("sync/sync.zig");
const github = @import("github.zig");
const cache = @import("cache.zig");
const config = @import("../config.zig");
const sidebar_controller = @import("sidebar/controller.zig");
const sidebar_state = @import("sidebar/state.zig");

const Allocator = std.mem.Allocator;
const SidebarState = sidebar_state.SidebarState;
const SyncSnapshot = sidebar_state.SyncSnapshot;

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
};

pub const OpenParams = struct {
    allocator: Allocator,
    sidebar: *SidebarState,
    /// Forwarded to `SyncWorker`; the offline harness points it at a fake.
    gh_bin: []const u8 = "gh",
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

    const url = cache.keyFor(allocator) orelse {
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
    // The paint's pushVisible ran before the worker existed.
    pushVisible(surface, .{ .allocator = allocator, .sidebar = sidebar });
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
        sidebar.unavailable = .db_error;
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
    }) catch |err| {
        std.log.warn("pr surface: sync worker failed to start: {}", .{err});
        params.sidebar.sync.last_error = .other;
        return;
    };
    surface.sync = worker;
    surface.seen_sync_generation = worker.generation();
    params.sidebar.sync = workerSnapshot(worker.status());
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

/// FR-5: hydrate the PRs the filter shows first. No-op without a worker.
pub fn pushVisible(surface: *Surface, params: ReloadParams) void {
    const worker = surface.sync orelse return;
    const numbers = sidebar_controller.visibleNumbers(params.sidebar, params.allocator) catch |err| {
        std.log.warn("pr surface: skipping hydrate priority: {}", .{err});
        return;
    };
    defer params.allocator.free(numbers);
    worker.setHydratePriority(numbers);
}

/// Main-loop hook: reload when the worker committed rows, refresh the sync
/// status, and map gh failures onto `unavailable` while the DB is empty.
/// True when the sidebar changed.
pub fn poll(surface: *Surface, params: ReloadParams) bool {
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

/// The main loop keeps ticking while the surface is open so a sync landing
/// in the background is drawn without waiting for input.
pub fn wantsTick(surface: *const Surface) bool {
    return surface.store != null or surface.sync != null;
}

pub fn requestSync(surface: *Surface) void {
    const worker = surface.sync orelse return;
    worker.requestSync();
}

/// `gh pr view <n> --web` for the selected PR. Blocks until `gh` exits
/// (moved unchanged from the picker).
pub fn openInBrowser(sidebar: *const SidebarState) void {
    const record = sidebar_controller.selectedPr(sidebar) orelse return;
    var buf: [16]u8 = undefined;
    const num = std.fmt.bufPrint(&buf, "{d}", .{record.number}) catch return;
    var child = std.process.spawn(skim_io.get(), .{
        .argv = &.{ "gh", "pr", "view", num, "--web" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(skim_io.get()) catch {};
}

/// Stop the worker and close the store.
pub fn close(surface: *Surface) void {
    if (surface.sync) |worker| worker.stop();
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

fn failDb(sidebar: *SidebarState) void {
    sidebar.unavailable = .db_error;
    sidebar_controller.setMessage(sidebar, "PR database unavailable — see ~/.skim/tui.log");
}

/// Configured presets, or the built-in `all` when config cannot be read.
fn loadPresets(allocator: Allocator, sidebar: *SidebarState) void {
    var cfg = config.load(allocator) catch |err| {
        std.log.warn("pr surface: config load failed, using the built-in preset: {}", .{err});
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
