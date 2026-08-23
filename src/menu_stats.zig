const std = @import("std");
const git = @import("git/diff.zig");
const App = @import("app.zig").App;
const platform = @import("platform.zig");

/// Context passed to the stats fetching thread
const MenuStatsContext = struct {
    app: *App,
};

/// Start async fetching of menu stats (non-blocking)
/// Call this on first render of empty menu, then check menu_stats_cached on subsequent renders
pub fn startMenuStatsFetch(app: *App) void {
    // The browser build has neither git nor threads, and the empty menu it draws
    // there is a static screen. Leave the stats unfetched.
    if (platform.is_web) return;
    if (app.state.menu_stats_cached or app.state.menu_stats_loading) return;

    app.state.menu_stats_loading = true;

    // Spawn detached thread to fetch stats
    const thread = std.Thread.spawn(.{}, menuStatsFetchWorker, .{app}) catch {
        // If thread spawn fails, fall back to sync fetch
        app.state.menu_stats_loading = false;
        fetchMenuStatsSync(app);
        return;
    };
    thread.detach();
}

/// Worker thread that fetches menu stats in background
fn menuStatsFetchWorker(app: *App) void {
    // Use a thread-local allocator for git operations
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Fetch stats using thread-local allocator
    const working = git.getDiffStats(alloc, .{ .working_dir = .{ .staged = false } }) catch git.DiffStats{ .files = 0, .additions = 0, .deletions = 0 };
    const staged = git.getDiffStats(alloc, .{ .working_dir = .{ .staged = true } }) catch git.DiffStats{ .files = 0, .additions = 0, .deletions = 0 };

    // Detect default branch
    var default_branch: []const u8 = "main";
    var branch_allocated = false;
    if (git.detectDefaultBranch(alloc)) |branch| {
        default_branch = branch;
        branch_allocated = true;
    } else |_| {}
    defer if (branch_allocated) alloc.free(default_branch);

    const main_stats = git.getDiffStats(alloc, .{ .single_ref = .{ .ref = default_branch, .staged = false } }) catch git.DiffStats{ .files = 0, .additions = 0, .deletions = 0 };

    // Copy default branch name to app's allocator (for long-term storage)
    const branch_copy = app.allocator.dupe(u8, default_branch) catch null;

    // Write results to app state
    // Note: This is safe because we only read these when menu_stats_cached is true
    app.state.working_stats = working;
    app.state.staged_stats = staged;
    app.state.main_stats = main_stats;
    app.state.default_branch_name = branch_copy;
    app.state.menu_stats_cached = true;
    app.state.menu_stats_loading = false;

    // Trigger re-render so stats appear without user input
    app.needs_render = true;
}

/// Synchronous fallback for stats fetching (used if thread spawn fails)
fn fetchMenuStatsSync(app: *App) void {
    app.state.working_stats = git.getDiffStats(app.allocator, .{ .working_dir = .{ .staged = false } }) catch git.DiffStats{ .files = 0, .additions = 0, .deletions = 0 };
    app.state.staged_stats = git.getDiffStats(app.allocator, .{ .working_dir = .{ .staged = true } }) catch git.DiffStats{ .files = 0, .additions = 0, .deletions = 0 };

    var default_branch: []const u8 = "main";
    var branch_allocated = false;
    if (git.detectDefaultBranch(app.allocator)) |branch| {
        default_branch = branch;
        branch_allocated = true;
    } else |_| {}

    app.state.main_stats = git.getDiffStats(app.allocator, .{ .single_ref = .{ .ref = default_branch, .staged = false } }) catch git.DiffStats{ .files = 0, .additions = 0, .deletions = 0 };

    // Store branch name (take ownership if allocated, otherwise dupe)
    if (branch_allocated) {
        app.state.default_branch_name = default_branch;
    } else {
        app.state.default_branch_name = app.allocator.dupe(u8, default_branch) catch null;
    }

    app.state.menu_stats_cached = true;
}
