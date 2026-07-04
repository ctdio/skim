//! Controller for a native GitHub PR review session. Owns `ReviewSession`
//! state and all logic over it as free functions (App Struct Boundaries
//! pattern; template: `pr/controller.zig`). App keeps only thin forwarders.
//!
//! Layering (AD-1): this is the controller layer. IO lives in `github.zig`,
//! parsing in `review_parse.zig`. The async idiom (AD-3) mirrors
//! `pr/controller.zig`: a detached worker allocates with `c_allocator` so
//! results survive the thread boundary; the main loop polls an atomic `ready`
//! flag and consumes under a mutex. `applyFetchedData` is THE ownership
//! boundary (AD-4): every string the session keeps is deep-copied into a
//! session-owned arena; the fetch/parse arena is freed immediately after.

const std = @import("std");
const Allocator = std.mem.Allocator;

const github = @import("github.zig");
const review_parse = @import("review_parse.zig");

/// Params for entering a PR. `base_ref`/`title`/`url` are known when entering
/// from the picker (the PullRequest row carries them). For `skim pr <number>`
/// boot they are not — `base_ref == ""` signals the worker to resolve it via
/// `gh pr view` first (a three-call chain: fetchPrByNumber -> fetchRef ->
/// fetchReviewData). Picker entry skips the first call.
pub const EnterParams = struct {
    number: u32,
    base_ref: []const u8 = "",
    title: []const u8 = "",
    url: []const u8 = "",
};

const PendingKind = enum { none, enter, refetch };

/// Thread-safe handoff of a background entry/refetch to the main loop. Worker
/// writes results under the mutex, then `ready.store(true, .release)`. All
/// buffers are `c_allocator`-owned so they survive the thread boundary.
pub const PendingEntry = struct {
    mutex: std.Thread.Mutex = .{},
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    git_ok: bool = false, // fetchRef succeeded (a local head ref exists)
    fetched_head_ref: ?[]u8 = null, // local ref from fetchRef (refs/skim/pr-N)
    fetched_base_ref: ?[]u8 = null, // base branch name used for the diff
    gh_ok: bool = false, // review payload fetched successfully
    raw_json: ?[]u8 = null, // gh review payload (when gh_ok)
    gh_kind: github.GhErrorKind = .other, // classified failure (when !gh_ok)
};

/// Outcome of consuming a pending entry/refetch. `entered.head_ref`/`base_ref`
/// are owned by the allocator passed to `pollPending`; the caller frees them
/// after building the diff source.
pub const EntryOutcome = union(enum) {
    none,
    entered: struct {
        head_ref: []const u8,
        base_ref: []const u8,
        gh_error: ?github.GhErrorKind, // set when the diff entered but review data failed
    },
    refreshed: ?github.GhErrorKind, // review data re-applied; gh_error if the refetch failed
    fetch_failed, // git ref fetch failed — cannot enter the diff at all
};

pub const ReviewSession = struct {
    active: bool = false,
    number: u32 = 0,

    // Session-owned copies of the review payload, backed by `data_arena` (AD-4).
    data_arena: ?std.heap.ArenaAllocator = null,
    pr_node_id: []const u8 = "",
    head_ref_oid: []const u8 = "",
    base_ref: []const u8 = "",
    head_ref: []const u8 = "",
    title: []const u8 = "",
    body: []const u8 = "",
    author: []const u8 = "",
    viewer_login: []const u8 = "",
    review_decision: []const u8 = "",
    rollup: review_parse.RollupState = .none,
    is_draft: bool = false,
    truncated: bool = false,
    pending_review_id: ?[]const u8 = null,
    // Element strings/slices point into `data_arena`; the lists themselves are
    // allocator-managed so they can be reused across refetches. NOTE: Phase 3
    // wraps threads in SessionThread and Phase 4 turns comments into an
    // ArrayList — both planned mechanical refactors.
    threads: std.ArrayList(review_parse.ReviewThread) = .{},
    reviews: std.ArrayList(review_parse.Review) = .{},
    checks: std.ArrayList(review_parse.CheckRun) = .{},

    // Async machinery (AD-3).
    entry: PendingEntry = .{},
    entry_in_flight: bool = false,
    entry_thread: ?std.Thread = null,
    pending_kind: PendingKind = .none,
    entering_number: u32 = 0,
    entering_base_ref: []const u8 = "", // allocator-owned while a fetch is in flight
};

/// Begin an async PR entry: git ref fetch + review-data fetch off-thread. No-op
/// (returns) if a fetch is already in flight — same guard as `startListLoad`.
pub fn startEnterPr(self: *ReviewSession, allocator: Allocator, params: EnterParams) !void {
    if (self.entry_in_flight) return;
    self.pending_kind = .enter;
    self.entering_number = params.number;
    self.entering_base_ref = if (params.base_ref.len > 0)
        try allocator.dupe(u8, params.base_ref)
    else
        "";
    try spawnWorker(self, allocator);
}

/// Re-fetch the review data only (no git fetch). Bound to `r` when a session is
/// active. No-op when nothing is active or a fetch is already running.
pub fn startRefetch(self: *ReviewSession, allocator: Allocator) !void {
    if (self.entry_in_flight or !self.active) return;
    self.pending_kind = .refetch;
    self.entering_number = self.number;
    self.entering_base_ref = "";
    try spawnWorker(self, allocator);
}

/// Consume a completed entry/refetch, if ready. Joins the worker, parses +
/// applies review data, and frees all worker (`c_allocator`) buffers.
pub fn pollPending(self: *ReviewSession, allocator: Allocator) EntryOutcome {
    if (!self.entry.ready.load(.acquire)) return .none;

    self.entry.mutex.lock();
    const git_ok = self.entry.git_ok;
    const head_ref = self.entry.fetched_head_ref;
    const base_ref = self.entry.fetched_base_ref;
    const gh_ok = self.entry.gh_ok;
    const raw_json = self.entry.raw_json;
    const gh_kind = self.entry.gh_kind;
    self.entry.fetched_head_ref = null;
    self.entry.fetched_base_ref = null;
    self.entry.raw_json = null;
    self.entry.mutex.unlock();
    self.entry.ready.store(false, .release);

    if (self.entry_thread) |t| {
        t.join();
        self.entry_thread = null;
    }
    self.entry_in_flight = false;
    const kind = self.pending_kind;
    self.pending_kind = .none;
    if (self.entering_base_ref.len > 0) {
        allocator.free(self.entering_base_ref);
        self.entering_base_ref = "";
    }

    const ca = std.heap.c_allocator;

    var gh_error: ?github.GhErrorKind = if (gh_ok) null else gh_kind;
    if (gh_ok) {
        if (raw_json) |raw| {
            if (review_parse.parsePrDetails(allocator, raw)) |parsed| {
                var data = parsed;
                defer data.deinit();
                applyFetchedData(self, allocator, &data) catch {
                    gh_error = .other;
                };
            } else |_| {
                gh_error = .other;
            }
        }
    }
    if (raw_json) |raw| ca.free(raw);

    if (kind == .refetch) {
        if (head_ref) |h| ca.free(h);
        if (base_ref) |b| ca.free(b);
        return .{ .refreshed = gh_error };
    }

    if (!git_ok) {
        if (head_ref) |h| ca.free(h);
        if (base_ref) |b| ca.free(b);
        return .fetch_failed;
    }

    const app_head = allocator.dupe(u8, head_ref orelse "") catch {
        if (head_ref) |h| ca.free(h);
        if (base_ref) |b| ca.free(b);
        return .fetch_failed;
    };
    const app_base = allocator.dupe(u8, base_ref orelse "") catch {
        allocator.free(app_head);
        if (head_ref) |h| ca.free(h);
        if (base_ref) |b| ca.free(b);
        return .fetch_failed;
    };
    if (head_ref) |h| ca.free(h);
    if (base_ref) |b| ca.free(b);

    return .{ .entered = .{ .head_ref = app_head, .base_ref = app_base, .gh_error = gh_error } };
}

/// Deep-copy parsed review data into a fresh session-owned arena, replacing any
/// previous copy (AD-4). After this returns the caller can safely free `data`.
pub fn applyFetchedData(self: *ReviewSession, allocator: Allocator, data: *review_parse.PrReviewData) !void {
    const d = data.details;

    clearData(self);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    self.threads.clearRetainingCapacity();
    self.reviews.clearRetainingCapacity();
    self.checks.clearRetainingCapacity();

    for (d.threads) |t| {
        const comments = try a.alloc(review_parse.ReviewComment, t.comments.len);
        for (t.comments, 0..) |c, i| {
            comments[i] = .{
                .id = try a.dupe(u8, c.id),
                .database_id = c.database_id,
                .author = try a.dupe(u8, c.author),
                .body = try a.dupe(u8, c.body),
                .created_at = try a.dupe(u8, c.created_at),
                .review_id = try a.dupe(u8, c.review_id),
                .review_state = c.review_state,
                .is_mine = c.is_mine,
                .diff_hunk = try a.dupe(u8, c.diff_hunk),
            };
        }
        try self.threads.append(allocator, .{
            .id = try a.dupe(u8, t.id),
            .path = try a.dupe(u8, t.path),
            .line = t.line,
            .start_line = t.start_line,
            .original_line = t.original_line,
            .side = t.side,
            .start_side = t.start_side,
            .is_resolved = t.is_resolved,
            .is_outdated = t.is_outdated,
            .subject_type = t.subject_type,
            .comments = comments,
        });
    }

    for (d.reviews) |r| {
        try self.reviews.append(allocator, .{
            .id = try a.dupe(u8, r.id),
            .author = try a.dupe(u8, r.author),
            .state = r.state,
            .body = try a.dupe(u8, r.body),
            .submitted_at = try a.dupe(u8, r.submitted_at),
        });
    }

    for (d.checks) |c| {
        try self.checks.append(allocator, .{
            .name = try a.dupe(u8, c.name),
            .status = try a.dupe(u8, c.status),
            .conclusion = try a.dupe(u8, c.conclusion),
        });
    }

    self.pr_node_id = try a.dupe(u8, d.pr_node_id);
    self.head_ref_oid = try a.dupe(u8, d.head_ref_oid);
    self.base_ref = try a.dupe(u8, d.base_ref);
    self.head_ref = try a.dupe(u8, d.head_ref);
    self.title = try a.dupe(u8, d.title);
    self.body = try a.dupe(u8, d.body);
    self.author = try a.dupe(u8, d.author);
    self.viewer_login = try a.dupe(u8, d.viewer_login);
    self.review_decision = try a.dupe(u8, d.review_decision);
    self.pending_review_id = if (d.pending_review_id) |id| try a.dupe(u8, id) else null;
    self.rollup = d.rollup;
    self.is_draft = d.is_draft;
    self.truncated = d.truncated;
    self.number = d.number;

    self.data_arena = arena;
    self.active = true;
}

pub fn isActive(self: *const ReviewSession) bool {
    return self.active;
}

/// Free the whole session. Joins any in-flight worker first so it can't write
/// into freed state, then frees worker buffers and the review-data arena.
pub fn deinitState(self: *ReviewSession, allocator: Allocator) void {
    if (self.entry_thread) |t| t.join();
    self.entry_thread = null;
    self.entry_in_flight = false;

    const ca = std.heap.c_allocator;
    if (self.entry.raw_json) |r| ca.free(r);
    if (self.entry.fetched_head_ref) |h| ca.free(h);
    if (self.entry.fetched_base_ref) |b| ca.free(b);
    self.entry.raw_json = null;
    self.entry.fetched_head_ref = null;
    self.entry.fetched_base_ref = null;
    if (self.entering_base_ref.len > 0) allocator.free(self.entering_base_ref);
    self.entering_base_ref = "";

    clearData(self);
    self.threads.deinit(allocator);
    self.reviews.deinit(allocator);
    self.checks.deinit(allocator);
}

// =============================================================================
// Helpers
// =============================================================================

fn spawnWorker(self: *ReviewSession, allocator: Allocator) !void {
    self.entry.ready.store(false, .release);
    self.entry_in_flight = true;
    self.entry_thread = std.Thread.spawn(.{}, entryWorker, .{self}) catch {
        self.entry_in_flight = false;
        self.pending_kind = .none;
        if (self.entering_base_ref.len > 0) {
            allocator.free(self.entering_base_ref);
            self.entering_base_ref = "";
        }
        return error.SpawnFailed;
    };
}

fn entryWorker(self: *ReviewSession) void {
    const ca = std.heap.c_allocator;
    const number = self.entering_number;
    const kind = self.pending_kind;

    var git_ok = kind == .refetch; // refetch never touches git
    var head_ref: ?[]u8 = null;
    var base_ref_out: ?[]u8 = null;

    if (kind == .enter) {
        var base_ref: []const u8 = self.entering_base_ref;
        var resolved: ?[]u8 = null;
        if (base_ref.len == 0) {
            resolved = resolveBaseRef(ca, number);
            if (resolved) |r| base_ref = r;
        }
        if (github.fetchRef(ca, .{ .number = number, .base_ref = base_ref })) |hr| {
            git_ok = true;
            head_ref = hr;
            base_ref_out = ca.dupe(u8, base_ref) catch null;
        } else |_| {
            git_ok = false;
        }
        if (resolved) |r| ca.free(r);
    }

    var gh_ok = false;
    var raw_json: ?[]u8 = null;
    var gh_kind: github.GhErrorKind = .other;
    if (git_ok) {
        if (github.getOriginOwnerRepo(ca)) |owner_repo| {
            defer ca.free(owner_repo.owner);
            defer ca.free(owner_repo.repo);
            if (github.fetchReviewData(ca, owner_repo, number)) |fetch| {
                switch (fetch) {
                    .ok => |raw| {
                        gh_ok = true;
                        raw_json = raw;
                    },
                    .failed => |k| gh_kind = k,
                }
            } else |_| {
                gh_kind = .other;
            }
        } else |_| {
            gh_kind = .other;
        }
    }

    self.entry.mutex.lock();
    self.entry.git_ok = git_ok;
    self.entry.fetched_head_ref = head_ref;
    self.entry.fetched_base_ref = base_ref_out;
    self.entry.gh_ok = gh_ok;
    self.entry.raw_json = raw_json;
    self.entry.gh_kind = gh_kind;
    self.entry.mutex.unlock();
    self.entry.ready.store(true, .release);
}

/// Resolve a PR's base branch name via `gh pr view` (number-only entry). Best
/// effort — returns null on any failure; the caller then diffs against HEAD.
fn resolveBaseRef(ca: Allocator, number: u32) ?[]u8 {
    const fetch = github.fetchPrByNumber(ca, number) catch return null;
    switch (fetch) {
        .ok => |raw| {
            defer ca.free(raw);
            var meta = review_parse.parsePrView(ca, raw) catch return null;
            defer meta.deinit();
            if (meta.base_ref.len == 0) return null;
            return ca.dupe(u8, meta.base_ref) catch null;
        },
        .failed => return null,
    }
}

/// Tear down the current review-data arena and reset all payload-backed fields.
/// Keeps the ArrayList buffers (cleared) so they can be reused on refetch.
fn clearData(self: *ReviewSession) void {
    if (self.data_arena) |*ar| ar.deinit();
    self.data_arena = null;
    self.threads.clearRetainingCapacity();
    self.reviews.clearRetainingCapacity();
    self.checks.clearRetainingCapacity();
    self.pr_node_id = "";
    self.head_ref_oid = "";
    self.base_ref = "";
    self.head_ref = "";
    self.title = "";
    self.body = "";
    self.author = "";
    self.viewer_login = "";
    self.review_decision = "";
    self.pending_review_id = null;
    self.rollup = .none;
    self.is_draft = false;
    self.truncated = false;
    self.active = false;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const canned_payload =
    \\{"data":{"viewer":{"login":"ctdio"},"repository":{"pullRequest":{
    \\"id":"PR_1","number":42,"title":"Widget","body":"desc","author":{"login":"octocat"},
    \\"isDraft":false,"baseRefName":"main","headRefName":"feat","headRefOid":"abc123","reviewDecision":"APPROVED",
    \\"statusCheckRollup":{"state":"SUCCESS"},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS","contexts":{"pageInfo":{"hasNextPage":false},"nodes":[
    \\{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"}
    \\]}}}}]},
    \\"reviews":{"pageInfo":{"hasNextPage":false},"nodes":[
    \\{"id":"PRR_1","state":"APPROVED","author":{"login":"mlugg"},"body":"lgtm","submittedAt":"2025-01-01T00:00:00Z"}
    \\]},
    \\"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false},"nodes":[
    \\{"id":"PRRT_1","isResolved":false,"isOutdated":false,"line":10,"startLine":null,"originalLine":10,"diffSide":"RIGHT","startDiffSide":null,"path":"src/x.zig","subjectType":"LINE",
    \\"comments":{"pageInfo":{"hasNextPage":false},"nodes":[
    \\{"id":"PRRC_1","databaseId":99,"author":{"login":"mlugg"},"body":"nit","createdAt":"2025-01-01T00:00:00Z","diffHunk":"@@ -1 +1 @@","pullRequestReview":{"id":"PRR_1","state":"COMMENTED"},"replyTo":null}
    \\]}}
    \\]}
    \\}}}}
;

const second_payload =
    \\{"data":{"viewer":{"login":"ctdio"},"repository":{"pullRequest":{
    \\"id":"PR_2","number":7,"title":"Second","body":"other","author":{"login":"someone"},
    \\"isDraft":true,"baseRefName":"develop","headRefName":"fix","headRefOid":"def456","reviewDecision":"",
    \\"statusCheckRollup":null,"commits":{"nodes":[]},
    \\"reviews":{"pageInfo":{"hasNextPage":false},"nodes":[]},
    \\"reviewThreads":{"totalCount":0,"pageInfo":{"hasNextPage":false},"nodes":[]}
    \\}}}}
;

test "applyFetchedData: deep copies survive freeing the source arena" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);

    var data = try review_parse.parsePrDetails(testing.allocator, canned_payload);
    applyFetchedData(&session, testing.allocator, &data) catch |err| {
        data.deinit();
        return err;
    };
    // Free the parse arena immediately — session copies must remain valid.
    data.deinit();

    try testing.expect(isActive(&session));
    try testing.expectEqual(@as(u32, 42), session.number);
    try testing.expectEqualStrings("PR_1", session.pr_node_id);
    try testing.expectEqualStrings("abc123", session.head_ref_oid);
    try testing.expectEqualStrings("main", session.base_ref);
    try testing.expectEqualStrings("Widget", session.title);
    try testing.expectEqualStrings("octocat", session.author);
    try testing.expectEqualStrings("ctdio", session.viewer_login);
    try testing.expectEqual(review_parse.RollupState.success, session.rollup);

    try testing.expectEqual(@as(usize, 1), session.threads.items.len);
    try testing.expectEqualStrings("PRRT_1", session.threads.items[0].id);
    try testing.expectEqualStrings("src/x.zig", session.threads.items[0].path);
    try testing.expectEqual(@as(usize, 1), session.threads.items[0].comments.len);
    try testing.expectEqualStrings("nit", session.threads.items[0].comments[0].body);

    try testing.expectEqual(@as(usize, 1), session.reviews.items.len);
    try testing.expectEqualStrings("mlugg", session.reviews.items[0].author);
    try testing.expectEqual(@as(usize, 1), session.checks.items.len);
    try testing.expectEqualStrings("build", session.checks.items[0].name);
}

test "applyFetchedData: second apply replaces the first (leak check)" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);

    var first = try review_parse.parsePrDetails(testing.allocator, canned_payload);
    try applyFetchedData(&session, testing.allocator, &first);
    first.deinit();

    var second = try review_parse.parsePrDetails(testing.allocator, second_payload);
    try applyFetchedData(&session, testing.allocator, &second);
    second.deinit();

    try testing.expectEqual(@as(u32, 7), session.number);
    try testing.expectEqualStrings("Second", session.title);
    try testing.expectEqualStrings("develop", session.base_ref);
    try testing.expect(session.is_draft);
    try testing.expectEqual(@as(usize, 0), session.threads.items.len);
    try testing.expectEqual(@as(usize, 0), session.reviews.items.len);
}

test "deinitState: clean on a never-used session" {
    var session = ReviewSession{};
    deinitState(&session, testing.allocator);
    try testing.expect(!isActive(&session));
}

test "startRefetch: no-op when session is inactive" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try startRefetch(&session, testing.allocator);
    try testing.expect(!session.entry_in_flight);
}

test "startEnterPr: no-op while a fetch is already in flight" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    // Simulate an in-flight fetch without spawning a real IO worker.
    session.entry_in_flight = true;
    try startEnterPr(&session, testing.allocator, .{ .number = 5, .base_ref = "main" });
    try testing.expect(session.entry_thread == null);
    try testing.expectEqual(@as(u32, 0), session.entering_number);
    try testing.expectEqualStrings("", session.entering_base_ref);
    // Reset so deinitState doesn't wait on a nonexistent worker.
    session.entry_in_flight = false;
}

test "applyFetchedData: thread with zero comments copies cleanly" {
    const payload =
        \\{"data":{"viewer":{"login":"ctdio"},"repository":{"pullRequest":{
        \\"id":"PR_1","number":3,"title":"t","body":"","author":{"login":"a"},
        \\"isDraft":false,"baseRefName":"main","headRefName":"h","headRefOid":"o","reviewDecision":"",
        \\"statusCheckRollup":null,"commits":{"nodes":[]},
        \\"reviews":{"pageInfo":{"hasNextPage":false},"nodes":[]},
        \\"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false},"nodes":[
        \\{"id":"PRRT_1","isResolved":false,"isOutdated":false,"line":1,"startLine":null,"originalLine":1,"diffSide":"LEFT","startDiffSide":null,"path":"x","subjectType":"FILE",
        \\"comments":{"pageInfo":{"hasNextPage":false},"nodes":[]}}
        \\]}
        \\}}}}
    ;
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    var data = try review_parse.parsePrDetails(testing.allocator, payload);
    try applyFetchedData(&session, testing.allocator, &data);
    data.deinit();

    try testing.expectEqual(@as(usize, 1), session.threads.items.len);
    try testing.expectEqual(@as(usize, 0), session.threads.items[0].comments.len);
    try testing.expectEqual(review_parse.Side.left, session.threads.items[0].side);
    try testing.expectEqual(review_parse.SubjectType.file, session.threads.items[0].subject_type);
}
