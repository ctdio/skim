//! Controller for the native PR review picker (`pr_review` mode). Owns all
//! logic over `PrReviewState`: background loading of the open-PR list,
//! stack-grouped filtering, the author-filter overlay, and picker navigation.
//! App keeps only thin cross-cutting forwarders (selecting a PR swaps the diff
//! in `app.zig`; Esc/Ctrl-C peel back through App mode/quit state).

const std = @import("std");
const Allocator = std.mem.Allocator;

const parse = @import("parse.zig");
const github = @import("github.zig");
const cache = @import("cache.zig");
const filter = @import("filter.zig");
const authors = @import("authors.zig");
const stack = @import("stack.zig");
const render = @import("render.zig");
const graphite = @import("../git/graphite.zig");

/// Thread-safe handoff of a background `gh pr list` fetch to the main loop.
/// Worker writes the parsed list (or a failure flag) under the mutex; the main
/// loop polls `ready` and consumes it. The list arena is built with c_allocator
/// so it survives the thread boundary independent of the App allocator.
pub const PendingPrFetch = struct {
    mutex: std.Thread.Mutex = .{},
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result: ?parse.PullRequestList = null,
    fail_kind: ?github.GhErrorKind = null,
};

/// State for the native PR review picker (the `pr_review` mode). Mirrors the
/// standalone picker's fields but lives on App.state so it integrates with the
/// modal loop. All fields default, so it stays out of the State init literal.
pub const PrReviewState = struct {
    list: ?parse.PullRequestList = null,
    filtered: std.ArrayList(usize) = .{},
    selection: usize = 0,
    scroll: usize = 0,

    // Forge-native stacked-PR grouping (rebuilt whenever `list` changes).
    analysis: ?stack.Analysis = null,
    order: []usize = &.{}, // stack-grouped display order over list.items (owned)

    query_buf: [256]u8 = undefined,
    query_len: usize = 0,

    // Pinned author filter, layered on top of the text query.
    author_buf: [256]u8 = undefined,
    author_len: usize = 0,

    message_buf: [256]u8 = undefined,
    message_len: usize = 0,

    // Author-filter overlay.
    picking_author: bool = false,
    author_list: []authors.AuthorCount = &.{},
    author_filtered: std.ArrayList(usize) = .{},
    author_selection: usize = 0,
    author_scroll: usize = 0,
    author_query_buf: [256]u8 = undefined,
    author_query_len: usize = 0,

    // Boot flag + background-fetch lifecycle (owned here so the controller holds
    // the whole picker state rather than scattering it across App).
    pr_only: bool = false, // Booted directly into the PR picker (`skim pr`)
    fetch: PendingPrFetch = .{}, // Thread-safe result of the background PR load
    fetch_in_flight: bool = false, // A background PR load is running
    load_failed: bool = false, // Last fetch failed with no list to show
    fetch_thread: ?std.Thread = null, // Joined on consume / at deinit
    cache_key: ?[]const u8 = null, // Per-repo cache key (owned)

    fn query(self: *const PrReviewState) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    fn authorFilter(self: *const PrReviewState) []const u8 {
        return self.author_buf[0..self.author_len];
    }

    fn authorQuery(self: *const PrReviewState) []const u8 {
        return self.author_query_buf[0..self.author_query_len];
    }

    fn message(self: *const PrReviewState) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    fn items(self: *const PrReviewState) []const parse.PullRequest {
        return if (self.list) |*l| l.items else &.{};
    }
};

/// Begin (or restart) a background load of the open PR list. Paints the
/// last-known cached list instantly (stale-while-revalidate), then refreshes
/// off-thread so a slow `gh` never freezes the UI.
pub fn startListLoad(self: *PrReviewState, allocator: Allocator) !void {
    if (self.fetch_in_flight) return;
    if (self.cache_key == null) self.cache_key = cache.keyFor(allocator);
    loadFromCache(self, allocator);
    self.fetch_in_flight = true;
    setMessage(self, "");
    self.fetch_thread = std.Thread.spawn(.{}, fetchWorker, .{self}) catch {
        self.fetch_in_flight = false;
        setMessage(self, "failed to start PR loader");
        return;
    };
}

/// Consume a completed background fetch, if any. Returns true when a result was
/// consumed (the caller should re-render); false when nothing was ready.
pub fn pollPendingFetch(self: *PrReviewState, allocator: Allocator) bool {
    if (!self.fetch.ready.load(.acquire)) return false;

    self.fetch.mutex.lock();
    const maybe = self.fetch.result;
    const fail_kind = self.fetch.fail_kind;
    self.fetch.result = null;
    self.fetch.fail_kind = null;
    self.fetch.mutex.unlock();
    self.fetch.ready.store(false, .release);

    if (self.fetch_thread) |t| {
        t.join();
        self.fetch_thread = null;
    }
    self.fetch_in_flight = false;

    if (maybe) |list| {
        if (self.list) |*old| old.deinit();
        self.list = list;
        rebuildStacks(self, allocator);
        rebuildFilter(self, allocator);
        // The author overlay aliases the arena we just freed; rebuild it
        // against the fresh PRs before anything reads it.
        if (self.picking_author) refreshAuthorList(self, allocator);
        setMessage(self, "");
        self.load_failed = false;
    } else if (fail_kind) |kind| {
        setMessage(self, github.kindMessage(kind));
        self.load_failed = true;
    }
    return true;
}

pub fn rebuildFilter(self: *PrReviewState, allocator: Allocator) void {
    self.filtered.clearRetainingCapacity();
    const list = self.list orelse return;
    // Walk the stack-grouped order when available so stacked PRs stay
    // contiguous (and their connector glyphs connect); otherwise fall back
    // to the list's natural order.
    if (self.order.len == list.items.len) {
        for (self.order) |idx| {
            if (filter.matchesFilters(list.items[idx], self.query(), self.authorFilter())) {
                self.filtered.append(allocator, idx) catch {};
            }
        }
    } else {
        for (list.items, 0..) |pull, i| {
            if (filter.matchesFilters(pull, self.query(), self.authorFilter())) {
                self.filtered.append(allocator, i) catch {};
            }
        }
    }
    if (self.filtered.items.len == 0) {
        self.selection = 0;
    } else if (self.selection >= self.filtered.items.len) {
        self.selection = self.filtered.items.len - 1;
    }
}

pub fn move(self: *PrReviewState, delta: isize) void {
    const len = self.filtered.items.len;
    if (len == 0) return;
    const cur: isize = @intCast(self.selection);
    const max: isize = @intCast(len - 1);
    self.selection = @intCast(std.math.clamp(cur + delta, 0, max));
}

/// Keep the selected row within the visible window. `rows` is the list
/// viewport height (window height minus header and status rows).
pub fn clampScroll(self: *PrReviewState, rows: usize) void {
    if (rows == 0) return;
    if (self.picking_author) {
        if (self.author_selection < self.author_scroll) {
            self.author_scroll = self.author_selection;
        } else if (self.author_selection >= self.author_scroll + rows) {
            self.author_scroll = self.author_selection - rows + 1;
        }
        return;
    }
    if (self.selection < self.scroll) {
        self.scroll = self.selection;
    } else if (self.selection >= self.scroll + rows) {
        self.scroll = self.selection - rows + 1;
    }
}

pub fn selected(self: *const PrReviewState) ?parse.PullRequest {
    if (self.filtered.items.len == 0) return null;
    const list = self.list orelse return null;
    if (self.selection >= self.filtered.items.len) return null;
    return list.items[self.filtered.items[self.selection]];
}

pub fn appendQueryChar(self: *PrReviewState, allocator: Allocator, c: u8) void {
    if (self.query_len < self.query_buf.len) {
        self.query_buf[self.query_len] = c;
        self.query_len += 1;
        rebuildFilter(self, allocator);
    }
}

pub fn backspaceQuery(self: *PrReviewState, allocator: Allocator) void {
    if (self.query_len > 0) self.query_len -= 1;
    rebuildFilter(self, allocator);
}

pub fn openInBrowser(self: *PrReviewState, allocator: Allocator) void {
    const pull = selected(self) orelse return;
    var buf: [16]u8 = undefined;
    const num = std.fmt.bufPrint(&buf, "{d}", .{pull.number}) catch return;
    var child = std.process.Child.init(&.{ "gh", "pr", "view", num, "--web" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return;
    _ = child.wait() catch {};
}

pub fn view(self: *const PrReviewState) render.View {
    return .{
        .prs = self.items(),
        .filtered = self.filtered.items,
        .selected = self.selection,
        .scroll = self.scroll,
        .loading = self.fetch_in_flight,
        .load_failed = self.load_failed,
        .query = self.query(),
        .message = self.message(),
        .author_filter = self.authorFilter(),
        .pr_only = self.pr_only,
        .picking_author = self.picking_author,
        .authors = self.author_list,
        .author_filtered = self.author_filtered.items,
        .author_selected = self.author_selection,
        .author_scroll = self.author_scroll,
        .author_query = self.authorQuery(),
        .analysis = if (self.analysis) |*a| a else null,
    };
}

pub fn setMessage(self: *PrReviewState, text: []const u8) void {
    const n = @min(text.len, self.message_buf.len);
    @memcpy(self.message_buf[0..n], text[0..n]);
    self.message_len = n;
}

// --- author filter overlay ---------------------------------------------------

pub fn openAuthorPicker(self: *PrReviewState, allocator: Allocator) void {
    if (self.list == null) return;
    self.author_query_len = 0;
    self.author_selection = 0;
    self.author_scroll = 0;
    self.picking_author = true;
    refreshAuthorList(self, allocator);
}

pub fn applySelectedAuthor(self: *PrReviewState, allocator: Allocator) void {
    if (self.author_filtered.items.len == 0) {
        closeAuthorPicker(self, allocator);
        return;
    }
    const login = self.author_list[self.author_filtered.items[self.author_selection]].login;
    const n = @min(login.len, self.author_buf.len);
    @memcpy(self.author_buf[0..n], login[0..n]);
    self.author_len = n;

    closeAuthorPicker(self, allocator);
    self.selection = 0;
    self.scroll = 0;
    rebuildFilter(self, allocator);
}

pub fn closeAuthorPicker(self: *PrReviewState, allocator: Allocator) void {
    self.picking_author = false;
    freeAuthors(self, allocator);
    self.author_query_len = 0;
}

pub fn authorMove(self: *PrReviewState, delta: isize) void {
    const len = self.author_filtered.items.len;
    if (len == 0) return;
    const cur: isize = @intCast(self.author_selection);
    const max: isize = @intCast(len - 1);
    self.author_selection = @intCast(std.math.clamp(cur + delta, 0, max));
}

pub fn appendAuthorQueryChar(self: *PrReviewState, allocator: Allocator, c: u8) void {
    if (self.author_query_len < self.author_query_buf.len) {
        self.author_query_buf[self.author_query_len] = c;
        self.author_query_len += 1;
        rebuildAuthorFilter(self, allocator);
    }
}

pub fn backspaceAuthorQuery(self: *PrReviewState, allocator: Allocator) void {
    if (self.author_query_len > 0) self.author_query_len -= 1;
    rebuildAuthorFilter(self, allocator);
}

/// Free the whole PR picker sub-state. Joins any in-flight loader first so its
/// worker can't write into freed state.
pub fn deinitState(self: *PrReviewState, allocator: Allocator) void {
    if (self.fetch_thread) |t| t.join();
    self.fetch_thread = null;
    if (self.fetch.result) |*list| list.deinit();
    if (self.list) |*list| list.deinit();
    if (self.analysis) |*a| a.deinit(allocator);
    if (self.order.len > 0) allocator.free(self.order);
    self.filtered.deinit(allocator);
    if (self.author_list.len > 0) allocator.free(self.author_list);
    self.author_filtered.deinit(allocator);
    if (self.cache_key) |k| allocator.free(k);
}

// =============================================================================
// Helpers
// =============================================================================

fn fetchWorker(self: *PrReviewState) void {
    const ca = std.heap.c_allocator;
    var fail_kind: ?github.GhErrorKind = null;
    var list: ?parse.PullRequestList = null;
    switch (github.listPullRequestsRaw(ca) catch github.GhFetch{ .failed = .other }) {
        .ok => |raw| {
            defer ca.free(raw);
            if (self.cache_key) |key| cache.write(ca, key, raw) catch {};
            if (parse.parse(ca, raw)) |parsed| {
                list = parsed;
            } else |_| {
                fail_kind = .other;
            }
        },
        .failed => |kind| fail_kind = kind,
    }

    self.fetch.mutex.lock();
    if (self.fetch.result) |*stale| stale.deinit();
    self.fetch.result = list;
    self.fetch.fail_kind = fail_kind;
    self.fetch.mutex.unlock();
    self.fetch.ready.store(true, .release);
}

fn loadFromCache(self: *PrReviewState, allocator: Allocator) void {
    const key = self.cache_key orelse return;
    const raw = (cache.read(allocator, key) catch return) orelse return;
    defer allocator.free(raw);
    const list = parse.parse(allocator, raw) catch return;
    if (self.list) |*old| old.deinit();
    self.list = list;
    rebuildStacks(self, allocator);
    rebuildFilter(self, allocator);
}

/// Recompute the stacked-PR grouping for the current list. Stack data is
/// purely index-based, so it's cheap to rebuild and independent of the
/// list's string arena.
fn rebuildStacks(self: *PrReviewState, allocator: Allocator) void {
    if (self.analysis) |*a| a.deinit(allocator);
    self.analysis = null;
    if (self.order.len > 0) allocator.free(self.order);
    self.order = &.{};

    const list = self.list orelse return;

    // Prefer Graphite's authoritative parent-branch relationships when the repo
    // is graphite-tracked; the forge-native base_ref heuristic (used as fallback
    // for untracked PRs) over-groups when a shared base is also a PR's head.
    var gp = graphite.getBranchParents(allocator);
    defer if (gp) |*g| g.deinit();

    var parent_branches: ?[]?[]const u8 = null;
    defer if (parent_branches) |pb| allocator.free(pb);
    if (gp) |*g| {
        if (allocator.alloc(?[]const u8, list.items.len)) |pb| {
            for (list.items, 0..) |pr, i| pb[i] = g.parentOf(pr.head_ref);
            parent_branches = pb;
        } else |_| {}
    }

    var analysis = stack.analyzeWith(allocator, list.items, parent_branches) catch return;
    const order = stack.displayOrder(allocator, list.items, analysis) catch {
        analysis.deinit(allocator);
        return;
    };
    self.analysis = analysis;
    self.order = order;
}

fn refreshAuthorList(self: *PrReviewState, allocator: Allocator) void {
    const list = self.list orelse return;
    freeAuthors(self, allocator);
    self.author_list = authors.distinct(allocator, list.items) catch {
        closeAuthorPicker(self, allocator);
        return;
    };
    rebuildAuthorFilter(self, allocator);
}

fn rebuildAuthorFilter(self: *PrReviewState, allocator: Allocator) void {
    self.author_filtered.clearRetainingCapacity();
    for (self.author_list, 0..) |a, i| {
        if (authors.matchesQuery(a.login, self.authorQuery())) {
            self.author_filtered.append(allocator, i) catch {};
        }
    }
    if (self.author_filtered.items.len == 0) {
        self.author_selection = 0;
    } else if (self.author_selection >= self.author_filtered.items.len) {
        self.author_selection = self.author_filtered.items.len - 1;
    }
}

fn freeAuthors(self: *PrReviewState, allocator: Allocator) void {
    if (self.author_list.len > 0) allocator.free(self.author_list);
    self.author_list = &.{};
    self.author_filtered.clearRetainingCapacity();
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "pollPendingFetch surfaces a rate-limit failure with its actionable message" {
    var state: PrReviewState = .{};
    defer deinitState(&state, testing.allocator);

    state.fetch_in_flight = true;
    state.fetch.fail_kind = .rate_limited;
    state.fetch.ready.store(true, .release);

    try testing.expect(pollPendingFetch(&state, testing.allocator));
    try testing.expectEqualStrings(github.kindMessage(.rate_limited), state.message());
    try testing.expect(state.load_failed);
}

test "pollPendingFetch surfaces a network failure distinctly from an auth failure" {
    var state: PrReviewState = .{};
    defer deinitState(&state, testing.allocator);

    state.fetch_in_flight = true;
    state.fetch.fail_kind = .network;
    state.fetch.ready.store(true, .release);

    try testing.expect(pollPendingFetch(&state, testing.allocator));
    try testing.expectEqualStrings(github.kindMessage(.network), state.message());
}
