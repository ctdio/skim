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
const thread_placement = @import("thread_placement.zig");

pub const AnchoredThread = thread_placement.AnchoredThread;

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

/// Where new comments go while a session is active (AD-7). Defaults to GitHub
/// draft posting; the user toggles with `C`.
pub const CommentTarget = enum { github, local };

/// A session-owned review thread. Server threads point their strings into
/// `data_arena` (`owned == false`); optimistic placeholders and just-posted
/// threads own their strings via the session allocator (`owned == true`).
/// `posting == true` marks an in-flight optimistic placeholder — the ONE kind
/// of thread preserved across a refetch (`applyFetchedData`). `local_seq` is a
/// stable, monotonically increasing marker used to map a completed mutation back
/// to its placeholder even after array indices shift on refetch (0 for server
/// threads).
pub const SessionThread = struct {
    data: review_parse.ReviewThread,
    posting: bool = false,
    owned: bool = false,
    local_seq: u64 = 0,
};

/// Params for posting a review thread. Slices are borrowed by `startPostThread`
/// (deep-copied into placeholder / worker buffers before it returns).
pub const PostParams = struct {
    path: []const u8,
    line: u32,
    side: review_parse.Side,
    start_line: ?u32 = null,
    start_side: review_parse.Side = .right,
    body: []const u8,
};

/// Outcome of consuming a completed post mutation.
pub const MutationOutcome = union(enum) {
    none,
    posted, // a thread posted; caller re-anchors + rebuilds the LineMap
    failed: github.GhErrorKind, // post failed; the body is stashed for retry
};

/// Thread-safe handoff of a single in-flight post mutation to the main loop.
/// Inputs are set by the main thread before spawn; outputs are written by the
/// worker under `mutex` then `ready.store(true, .release)`. All buffers are
/// `c_allocator`-owned so they survive the thread boundary; `pollMutations`
/// frees them on consumption.
pub const PendingMutation = struct {
    mutex: std.Thread.Mutex = .{},
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Inputs.
    in_pr_node_id: []u8 = &.{},
    in_head_oid: []u8 = &.{},
    in_review_id: ?[]u8 = null, // cached pending review id, or null → worker creates
    in_path: []u8 = &.{},
    in_line: u32 = 0,
    in_side: review_parse.Side = .right,
    in_start_line: ?u32 = null,
    in_start_side: review_parse.Side = .right,
    in_body: []u8 = &.{},
    local_seq: u64 = 0,

    // Outputs.
    out_review_id: ?[]u8 = null, // review id used/created (cached on success)
    out_thread_raw: ?[]u8 = null, // addPullRequestReviewThread response JSON
    failed: bool = false,
    fail_kind: github.GhErrorKind = .other,
};

const QueuedPost = struct {
    path: []u8,
    line: u32,
    side: review_parse.Side,
    start_line: ?u32,
    start_side: review_parse.Side,
    body: []u8,
    local_seq: u64,
};

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
    // Server-thread element strings point into `data_arena`; placeholder/posted
    // thread strings are session-allocator-owned (see `SessionThread.owned`). The
    // lists themselves are allocator-managed so they can be reused across refetches.
    threads: std.ArrayList(SessionThread) = .{},
    reviews: std.ArrayList(review_parse.Review) = .{},
    checks: std.ArrayList(review_parse.CheckRun) = .{},

    // Derived render placement of `threads` (AD-4: recomputed by the App on every
    // diff refresh, never persisted). Allocator-owned; replaced via `setAnchored`.
    anchored: []AnchoredThread = &.{},
    unplaced_count: usize = 0,
    // Ephemeral expand/collapse UI state keyed by positional thread index. The
    // key INVERTS the default (unresolved → expanded, resolved → collapsed):
    // presence means "opposite of default". Positional keys are deliberately
    // transient and cleared on every `applyFetchedData`, so they are exempt from
    // AD-4's node-ID identity rule (this is view state, not review data).
    expanded_threads: std.AutoHashMapUnmanaged(usize, void) = .{},

    // Async machinery (AD-3).
    entry: PendingEntry = .{},
    entry_in_flight: bool = false,
    entry_thread: ?std.Thread = null,
    pending_kind: PendingKind = .none,
    entering_number: u32 = 0,
    entering_base_ref: []const u8 = "", // allocator-owned while a fetch is in flight

    // Write path (Phase 3): comment target, pending-review posting machinery.
    comment_target: CommentTarget = .github,
    // Cached pending-review id created/reused this session (session-allocator-owned).
    // Falls back to the fetched `pending_review_id`. See `currentReviewId`.
    posted_review_id: ?[]u8 = null,
    // One post mutation runs at a time; further posts queue (this also serializes
    // pending-review creation so two rapid posts can never double-create — AD-8).
    mutation: PendingMutation = .{},
    mutation_thread: ?std.Thread = null,
    posting_worker_active: bool = false,
    queued_posts: std.ArrayList(QueuedPost) = .{},
    local_seq_counter: u64 = 0,
    // Draft safety (NFR-2): the body of the last failed post, preserved so the
    // next comment-open pre-fills the editor. Session-allocator-owned.
    draft_failed_text: ?[]u8 = null,
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

    // Preserve in-flight optimistic placeholders across the refetch (they are
    // local-only and not yet on the server). Move their values out before
    // clearData tears down the thread list, then re-append after rebuild.
    var preserved: std.ArrayList(SessionThread) = .{};
    defer preserved.deinit(allocator);
    for (self.threads.items) |st| {
        if (st.posting) {
            try preserved.append(allocator, st); // moves ownership of gpa strings
        } else if (st.owned) {
            freeOwnedThread(allocator, st); // just-posted local copies → server is authoritative now
        }
    }

    clearData(self, allocator);
    // New payload → positional thread indices change; drop derived/UI state.
    freeAnchored(self, allocator);
    self.expanded_threads.clearRetainingCapacity();

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
        try self.threads.append(allocator, .{ .data = .{
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
        } });
    }

    // Re-append the preserved placeholders after the server threads.
    for (preserved.items) |st| try self.threads.append(allocator, st);

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
    // pending_review_id is session-allocator-owned (not arena) so a successful
    // post can replace it in place; clearData frees it.
    self.pending_review_id = if (d.pending_review_id) |id| try allocator.dupe(u8, id) else null;
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

/// Replace the derived anchor slice (transfers ownership of `anchored`). The
/// previous slice is freed. `unplaced` is the count of threads whose path is
/// absent from the diff (surfaced so nothing is silently dropped).
pub fn setAnchored(self: *ReviewSession, allocator: Allocator, anchored: []AnchoredThread, unplaced: usize) void {
    if (self.anchored.len > 0) allocator.free(self.anchored);
    self.anchored = anchored;
    self.unplaced_count = unplaced;
}

/// Free the anchor slice (e.g. when a new payload invalidates positional
/// indices). Idempotent.
pub fn freeAnchored(self: *ReviewSession, allocator: Allocator) void {
    if (self.anchored.len > 0) allocator.free(self.anchored);
    self.anchored = &.{};
    self.unplaced_count = 0;
}

/// A transient `[]ReviewThread` view over the session's `SessionThread` list, for
/// feeding `thread_anchor.anchorThreads` (which lives in a module the controller
/// cannot import without escaping the `pr/` test-module root). Anchors reference
/// threads only by positional index, so the caller frees this view immediately
/// after anchoring. Caller owns the returned slice.
pub fn threadDataView(self: *const ReviewSession, allocator: Allocator) ![]review_parse.ReviewThread {
    const view = try allocator.alloc(review_parse.ReviewThread, self.threads.items.len);
    for (self.threads.items, 0..) |st, i| view[i] = st.data;
    return view;
}

/// Whether thread `thread_idx` renders expanded. Default: expanded unless the
/// thread is resolved. Presence in `expanded_threads` inverts that default.
pub fn isThreadExpanded(self: *const ReviewSession, thread_idx: usize) bool {
    const default_expanded = if (thread_idx < self.threads.items.len)
        !self.threads.items[thread_idx].data.is_resolved
    else
        true;
    const overridden = self.expanded_threads.contains(thread_idx);
    return default_expanded != overridden;
}

/// Flip the expand/collapse state of thread `thread_idx`.
pub fn toggleThreadExpanded(self: *ReviewSession, allocator: Allocator, thread_idx: usize) !void {
    if (self.expanded_threads.remove(thread_idx)) return;
    try self.expanded_threads.put(allocator, thread_idx, {});
}

// =============================================================================
// Write path: comment target, pending-review posting, draft safety
// =============================================================================

/// Toggle the comment target (GitHub draft ⇄ local). No-op unless a session is
/// active. Returns the new target so the caller can surface it.
pub fn toggleCommentTarget(self: *ReviewSession) CommentTarget {
    if (!self.active) return self.comment_target;
    self.comment_target = switch (self.comment_target) {
        .github => .local,
        .local => .github,
    };
    return self.comment_target;
}

/// Whether new comments should post to GitHub as drafts (session active AND
/// target is GitHub).
pub fn githubTargetActive(self: *const ReviewSession) bool {
    return self.active and self.comment_target == .github;
}

/// Begin posting a review thread: append an optimistic placeholder immediately
/// (so the block renders "posting…"), then dispatch a worker (or queue behind an
/// in-flight one — this serialization also prevents a double pending-review
/// create). The body/path slices are borrowed; copies are made before returning.
pub fn startPostThread(self: *ReviewSession, allocator: Allocator, params: PostParams) !void {
    const seq = try appendPlaceholder(self, allocator, params);
    errdefer removePlaceholder(self, allocator, seq);

    if (self.posting_worker_active or self.mutation.ready.load(.acquire)) {
        try enqueuePost(self, allocator, params, seq);
        return;
    }
    try spawnPost(self, params, seq);
}

/// Consume a completed post mutation, if ready. On success: cache the pending
/// review id, replace the placeholder with the parsed server thread, and (if
/// queued) dispatch the next post. On failure: remove the placeholder, stash the
/// body for retry (NFR-2), and surface the error kind. Returns `.none` when no
/// mutation is ready.
pub fn pollMutations(self: *ReviewSession, allocator: Allocator) MutationOutcome {
    if (!self.mutation.ready.load(.acquire)) return .none;

    self.mutation.mutex.lock();
    const out_review_id = self.mutation.out_review_id;
    const out_thread_raw = self.mutation.out_thread_raw;
    const failed = self.mutation.failed;
    const fail_kind = self.mutation.fail_kind;
    const seq = self.mutation.local_seq;
    self.mutation.out_review_id = null;
    self.mutation.out_thread_raw = null;
    self.mutation.mutex.unlock();
    self.mutation.ready.store(false, .release);

    if (self.mutation_thread) |t| {
        t.join();
        self.mutation_thread = null;
    }
    self.posting_worker_active = false;

    const ca = std.heap.c_allocator;
    var outcome: MutationOutcome = undefined;

    // Cache the review id whenever the worker resolved/created one — even on a
    // partial failure (review created, thread post failed). Otherwise the next
    // queued post would create a SECOND pending review and hit GitHub's "one
    // pending review per pull request" error.
    if (out_review_id) |rid| setReviewId(self, allocator, rid);

    if (failed) {
        stashFailedDraft(self, allocator, self.mutation.in_body);
        removePlaceholder(self, allocator, seq);
        outcome = .{ .failed = fail_kind };
    } else applied: {
        const raw = out_thread_raw orelse {
            stashFailedDraft(self, allocator, self.mutation.in_body);
            removePlaceholder(self, allocator, seq);
            outcome = .{ .failed = .other };
            break :applied;
        };
        var created = review_parse.parseCreatedThread(allocator, raw, self.viewer_login) catch {
            stashFailedDraft(self, allocator, self.mutation.in_body);
            removePlaceholder(self, allocator, seq);
            outcome = .{ .failed = .other };
            break :applied;
        };
        defer created.deinit();

        replacePlaceholderWithThread(self, allocator, seq, created.thread) catch {
            stashFailedDraft(self, allocator, self.mutation.in_body);
            removePlaceholder(self, allocator, seq);
            outcome = .{ .failed = .other };
            break :applied;
        };
        outcome = .posted;
    }

    // Free the worker's c_allocator buffers now that they're consumed.
    if (out_review_id) |r| ca.free(r);
    if (out_thread_raw) |r| ca.free(r);
    freeMutationBuffers(self);

    drainQueue(self, allocator);
    return outcome;
}

/// Take (and clear) the stashed failed-draft body, transferring ownership to the
/// caller (which must free it). Null when there is nothing stashed.
pub fn takeFailedDraft(self: *ReviewSession) ?[]u8 {
    const text = self.draft_failed_text orelse return null;
    self.draft_failed_text = null;
    return text;
}

/// Count of draft threads to show in the status bar: threads whose comments are
/// all pending, plus in-flight placeholders.
pub fn draftCount(self: *const ReviewSession) usize {
    var count: usize = 0;
    for (self.threads.items) |st| {
        if (st.posting) {
            count += 1;
            continue;
        }
        const comments = st.data.comments;
        if (comments.len == 0) continue;
        var all_pending = true;
        for (comments) |c| {
            if (c.review_state != .pending) {
                all_pending = false;
                break;
            }
        }
        if (all_pending) count += 1;
    }
    return count;
}

/// Number of in-flight / queued optimistic placeholders (status-bar "posting…").
pub fn postingCount(self: *const ReviewSession) usize {
    var count: usize = 0;
    for (self.threads.items) |st| {
        if (st.posting) count += 1;
    }
    return count;
}

/// Whether any write-path work (a running worker, a ready result, or queued
/// posts) is outstanding — joins the main loop's poll predicate.
pub fn hasPostingWork(self: *const ReviewSession) bool {
    return self.posting_worker_active or self.mutation.ready.load(.acquire) or self.queued_posts.items.len > 0;
}

/// Free the whole session. Joins any in-flight worker first so it can't write
/// into freed state, then frees worker buffers and the review-data arena.
pub fn deinitState(self: *ReviewSession, allocator: Allocator) void {
    if (self.entry_thread) |t| t.join();
    self.entry_thread = null;
    self.entry_in_flight = false;

    // Join any in-flight post worker so it can't write into freed state.
    if (self.mutation_thread) |t| t.join();
    self.mutation_thread = null;
    self.posting_worker_active = false;

    const ca = std.heap.c_allocator;
    if (self.entry.raw_json) |r| ca.free(r);
    if (self.entry.fetched_head_ref) |h| ca.free(h);
    if (self.entry.fetched_base_ref) |b| ca.free(b);
    self.entry.raw_json = null;
    self.entry.fetched_head_ref = null;
    self.entry.fetched_base_ref = null;
    if (self.entering_base_ref.len > 0) allocator.free(self.entering_base_ref);
    self.entering_base_ref = "";

    freeMutationBuffers(self);
    clearQueuedPosts(self, allocator);
    self.queued_posts.deinit(allocator);
    if (self.draft_failed_text) |t| allocator.free(t);
    self.draft_failed_text = null;

    // Free session-owned (placeholder / just-posted) thread strings before the
    // list is torn down; server threads are freed by clearData's arena.deinit.
    for (self.threads.items) |st| {
        if (st.owned) freeOwnedThread(allocator, st);
    }

    clearData(self, allocator);
    freeAnchored(self, allocator);
    self.expanded_threads.deinit(allocator);
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
/// Keeps the ArrayList buffers (cleared) so they can be reused on refetch. The
/// caller is responsible for any session-owned (`SessionThread.owned`) thread
/// strings BEFORE calling this — the server threads live in `data_arena` (freed
/// here); the review-id strings are freed here.
fn clearData(self: *ReviewSession, allocator: Allocator) void {
    if (self.data_arena) |*ar| ar.deinit();
    self.data_arena = null;
    if (self.pending_review_id) |id| allocator.free(id);
    self.pending_review_id = null;
    if (self.posted_review_id) |id| allocator.free(id);
    self.posted_review_id = null;
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
    self.rollup = .none;
    self.is_draft = false;
    self.truncated = false;
    self.active = false;
}

// --- Write path helpers ------------------------------------------------------

/// Append an optimistic placeholder thread (posting, session-owned) so the block
/// renders "posting…" immediately. Returns its stable `local_seq`, which maps the
/// eventual mutation result back to it even after refetch shifts array indices.
fn appendPlaceholder(self: *ReviewSession, allocator: Allocator, params: PostParams) !u64 {
    self.local_seq_counter += 1;
    const seq = self.local_seq_counter;

    const comments = try allocator.alloc(review_parse.ReviewComment, 1);
    errdefer allocator.free(comments);
    comments[0] = .{
        .id = try allocator.dupe(u8, "pending"),
        .database_id = 0,
        .author = try allocator.dupe(u8, self.viewer_login),
        .body = try allocator.dupe(u8, params.body),
        .created_at = try allocator.dupe(u8, ""),
        .review_id = try allocator.dupe(u8, ""),
        .review_state = .pending,
        .is_mine = true,
        .diff_hunk = try allocator.dupe(u8, ""),
    };
    const data = review_parse.ReviewThread{
        .id = try allocator.dupe(u8, "pending"),
        .path = try allocator.dupe(u8, params.path),
        .line = params.line,
        .start_line = params.start_line,
        .original_line = params.line,
        .side = params.side,
        .start_side = params.start_side,
        .is_resolved = false,
        .is_outdated = false,
        .subject_type = .line,
        .comments = comments,
    };
    try self.threads.append(allocator, .{ .data = data, .posting = true, .owned = true, .local_seq = seq });
    return seq;
}

/// Replace the placeholder identified by `seq` with a session-owned deep copy of
/// the server thread. If the placeholder vanished (e.g. a concurrent refetch),
/// the owned copy is freed rather than leaked.
fn replacePlaceholderWithThread(self: *ReviewSession, allocator: Allocator, seq: u64, thread: review_parse.ReviewThread) !void {
    const owned = try dupeThreadOwned(allocator, thread);
    for (self.threads.items, 0..) |st, i| {
        if (st.posting and st.local_seq == seq) {
            freeOwnedThread(allocator, st);
            self.threads.items[i] = .{ .data = owned, .posting = false, .owned = true, .local_seq = seq };
            return;
        }
    }
    freeOwnedThread(allocator, .{ .data = owned, .owned = true });
}

/// Remove the placeholder identified by `seq` (post failed), freeing its strings.
fn removePlaceholder(self: *ReviewSession, allocator: Allocator, seq: u64) void {
    for (self.threads.items, 0..) |st, i| {
        if (st.posting and st.local_seq == seq) {
            freeOwnedThread(allocator, st);
            _ = self.threads.orderedRemove(i);
            return;
        }
    }
}

/// Stash a failed post's body so the next comment-open pre-fills the editor
/// (NFR-2 draft safety). Replaces any previously stashed draft.
fn stashFailedDraft(self: *ReviewSession, allocator: Allocator, body: []const u8) void {
    if (self.draft_failed_text) |t| allocator.free(t);
    self.draft_failed_text = allocator.dupe(u8, body) catch null;
}

/// Cache the pending-review id used/created by a successful post.
fn setReviewId(self: *ReviewSession, allocator: Allocator, id: []const u8) void {
    if (self.posted_review_id) |r| allocator.free(r);
    self.posted_review_id = allocator.dupe(u8, id) catch null;
}

/// The pending-review id to reuse for the next post: the one cached this session,
/// falling back to the id fetched from GitHub. Null → the worker must create one.
fn currentReviewId(self: *const ReviewSession) ?[]const u8 {
    if (self.posted_review_id) |r| return r;
    return self.pending_review_id;
}

/// Copy the post params into `c_allocator` buffers and spawn the post worker.
/// Buffers live on `self.mutation` (freed by `pollMutations` / `deinitState`).
fn spawnPost(self: *ReviewSession, params: PostParams, seq: u64) !void {
    const ca = std.heap.c_allocator;

    const pr_node_id = try ca.dupe(u8, self.pr_node_id);
    errdefer ca.free(pr_node_id);
    const head_oid = try ca.dupe(u8, self.head_ref_oid);
    errdefer ca.free(head_oid);
    const path = try ca.dupe(u8, params.path);
    errdefer ca.free(path);
    const body = try ca.dupe(u8, params.body);
    errdefer ca.free(body);
    var review_id_buf: ?[]u8 = null;
    if (currentReviewId(self)) |rid| review_id_buf = try ca.dupe(u8, rid);
    errdefer if (review_id_buf) |r| ca.free(r);

    self.mutation.in_pr_node_id = pr_node_id;
    self.mutation.in_head_oid = head_oid;
    self.mutation.in_path = path;
    self.mutation.in_body = body;
    self.mutation.in_review_id = review_id_buf;
    self.mutation.in_line = params.line;
    self.mutation.in_side = params.side;
    self.mutation.in_start_line = params.start_line;
    self.mutation.in_start_side = params.start_side;
    self.mutation.local_seq = seq;
    self.mutation.failed = false;
    self.mutation.out_review_id = null;
    self.mutation.out_thread_raw = null;
    self.mutation.ready.store(false, .release);

    self.mutation_thread = std.Thread.spawn(.{}, postThreadWorker, .{self}) catch {
        // Detach the buffers from the struct; the errdefers above free them.
        self.mutation.in_pr_node_id = &.{};
        self.mutation.in_head_oid = &.{};
        self.mutation.in_path = &.{};
        self.mutation.in_body = &.{};
        self.mutation.in_review_id = null;
        return error.SpawnFailed;
    };
    self.posting_worker_active = true;
}

/// Post worker (AD-3). Runs on `c_allocator` so its results survive the thread
/// boundary. Reuses the cached review id or creates a pending review first, then
/// posts the thread. Writes outputs under the mutex and flips `ready`.
fn postThreadWorker(self: *ReviewSession) void {
    const ca = std.heap.c_allocator;
    var failed = false;
    var fail_kind: github.GhErrorKind = .other;
    var out_review_id: ?[]u8 = null;
    var out_thread_raw: ?[]u8 = null;

    var review_id: ?[]u8 = null; // ca-owned working copy
    defer if (review_id) |r| ca.free(r);

    if (self.mutation.in_review_id) |rid| {
        review_id = ca.dupe(u8, rid) catch blk: {
            failed = true;
            break :blk null;
        };
    } else if (github.createPendingReview(ca, self.mutation.in_pr_node_id, self.mutation.in_head_oid)) |fetch| {
        switch (fetch) {
            .ok => |raw| {
                defer ca.free(raw);
                if (review_parse.parseCreatedReviewId(ca, raw)) |id| {
                    review_id = id;
                    out_review_id = ca.dupe(u8, id) catch null;
                } else |_| {
                    failed = true;
                }
            },
            .failed => |k| {
                failed = true;
                fail_kind = k;
            },
        }
    } else |_| {
        failed = true;
    }

    if (!failed) {
        if (github.addReviewThread(ca, .{
            .review_id = review_id.?,
            .path = self.mutation.in_path,
            .line = self.mutation.in_line,
            .side = self.mutation.in_side,
            .start_line = self.mutation.in_start_line,
            .start_side = self.mutation.in_start_side,
            .body = self.mutation.in_body,
        })) |fetch| {
            switch (fetch) {
                .ok => |raw| out_thread_raw = raw,
                .failed => |k| {
                    failed = true;
                    fail_kind = k;
                },
            }
        } else |_| {
            failed = true;
        }
    }

    self.mutation.mutex.lock();
    self.mutation.out_review_id = out_review_id;
    self.mutation.out_thread_raw = out_thread_raw;
    self.mutation.failed = failed;
    self.mutation.fail_kind = fail_kind;
    self.mutation.mutex.unlock();
    self.mutation.ready.store(true, .release);
}

/// Queue a post behind the in-flight worker (copying its inputs onto the session
/// allocator). The placeholder for `seq` was already appended by the caller.
fn enqueuePost(self: *ReviewSession, allocator: Allocator, params: PostParams, seq: u64) !void {
    const path = try allocator.dupe(u8, params.path);
    errdefer allocator.free(path);
    const body = try allocator.dupe(u8, params.body);
    errdefer allocator.free(body);
    try self.queued_posts.append(allocator, .{
        .path = path,
        .line = params.line,
        .side = params.side,
        .start_line = params.start_line,
        .start_side = params.start_side,
        .body = body,
        .local_seq = seq,
    });
}

/// Dispatch the next queued post if the worker is idle. If the spawn fails, the
/// orphaned placeholder is removed.
fn drainQueue(self: *ReviewSession, allocator: Allocator) void {
    if (self.queued_posts.items.len == 0) return;
    if (self.posting_worker_active or self.mutation.ready.load(.acquire)) return;

    const q = self.queued_posts.orderedRemove(0);
    defer {
        if (q.path.len > 0) allocator.free(q.path);
        if (q.body.len > 0) allocator.free(q.body);
    }
    spawnPost(self, .{
        .path = q.path,
        .line = q.line,
        .side = q.side,
        .start_line = q.start_line,
        .start_side = q.start_side,
        .body = q.body,
    }, q.local_seq) catch {
        removePlaceholder(self, allocator, q.local_seq);
    };
}

/// Free the `c_allocator` buffers held on `self.mutation` (both inputs and any
/// unconsumed outputs) and reset them. Safe to call repeatedly.
fn freeMutationBuffers(self: *ReviewSession) void {
    const ca = std.heap.c_allocator;
    if (self.mutation.in_pr_node_id.len > 0) ca.free(self.mutation.in_pr_node_id);
    if (self.mutation.in_head_oid.len > 0) ca.free(self.mutation.in_head_oid);
    if (self.mutation.in_path.len > 0) ca.free(self.mutation.in_path);
    if (self.mutation.in_body.len > 0) ca.free(self.mutation.in_body);
    if (self.mutation.in_review_id) |r| ca.free(r);
    if (self.mutation.out_review_id) |r| ca.free(r);
    if (self.mutation.out_thread_raw) |r| ca.free(r);
    self.mutation.in_pr_node_id = &.{};
    self.mutation.in_head_oid = &.{};
    self.mutation.in_path = &.{};
    self.mutation.in_body = &.{};
    self.mutation.in_review_id = null;
    self.mutation.out_review_id = null;
    self.mutation.out_thread_raw = null;
}

/// Free every queued post's session-owned buffers (placeholders are freed
/// separately by the caller's owned-thread sweep).
fn clearQueuedPosts(self: *ReviewSession, allocator: Allocator) void {
    for (self.queued_posts.items) |q| {
        if (q.path.len > 0) allocator.free(q.path);
        if (q.body.len > 0) allocator.free(q.body);
    }
    self.queued_posts.clearRetainingCapacity();
}

/// Deep-copy a `ReviewThread` into session-allocator-owned strings (for
/// placeholders / just-posted threads that outlive the parse arena).
fn dupeThreadOwned(allocator: Allocator, thread: review_parse.ReviewThread) !review_parse.ReviewThread {
    const comments = try allocator.alloc(review_parse.ReviewComment, thread.comments.len);
    errdefer allocator.free(comments);
    for (thread.comments, 0..) |c, i| {
        comments[i] = .{
            .id = try allocator.dupe(u8, c.id),
            .database_id = c.database_id,
            .author = try allocator.dupe(u8, c.author),
            .body = try allocator.dupe(u8, c.body),
            .created_at = try allocator.dupe(u8, c.created_at),
            .review_id = try allocator.dupe(u8, c.review_id),
            .review_state = c.review_state,
            .is_mine = c.is_mine,
            .diff_hunk = try allocator.dupe(u8, c.diff_hunk),
        };
    }
    return .{
        .id = try allocator.dupe(u8, thread.id),
        .path = try allocator.dupe(u8, thread.path),
        .line = thread.line,
        .start_line = thread.start_line,
        .original_line = thread.original_line,
        .side = thread.side,
        .start_side = thread.start_side,
        .is_resolved = thread.is_resolved,
        .is_outdated = thread.is_outdated,
        .subject_type = thread.subject_type,
        .comments = comments,
    };
}

/// Free a session-owned (placeholder / posted-copy) thread's strings.
fn freeOwnedThread(allocator: Allocator, st: SessionThread) void {
    for (st.data.comments) |c| {
        allocator.free(c.id);
        allocator.free(c.author);
        allocator.free(c.body);
        allocator.free(c.created_at);
        allocator.free(c.review_id);
        allocator.free(c.diff_hunk);
    }
    if (st.data.comments.len > 0) allocator.free(st.data.comments);
    allocator.free(st.data.id);
    allocator.free(st.data.path);
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
    try testing.expectEqualStrings("PRRT_1", session.threads.items[0].data.id);
    try testing.expectEqualStrings("src/x.zig", session.threads.items[0].data.path);
    try testing.expectEqual(@as(usize, 1), session.threads.items[0].data.comments.len);
    try testing.expectEqualStrings("nit", session.threads.items[0].data.comments[0].body);

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
    try testing.expectEqual(@as(usize, 0), session.threads.items[0].data.comments.len);
    try testing.expectEqual(review_parse.Side.left, session.threads.items[0].data.side);
    try testing.expectEqual(review_parse.SubjectType.file, session.threads.items[0].data.subject_type);
}

test "isThreadExpanded: unresolved threads default to expanded" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try session.threads.append(testing.allocator, threadWith(false));
    try testing.expect(isThreadExpanded(&session, 0));
}

test "isThreadExpanded: resolved threads default to collapsed" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try session.threads.append(testing.allocator, threadWith(true));
    try testing.expect(!isThreadExpanded(&session, 0));
}

test "toggleThreadExpanded: collapses an unresolved thread" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try session.threads.append(testing.allocator, threadWith(false));
    try toggleThreadExpanded(&session, testing.allocator, 0);
    try testing.expect(!isThreadExpanded(&session, 0));
}

test "toggleThreadExpanded: expands a resolved thread" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try session.threads.append(testing.allocator, threadWith(true));
    try toggleThreadExpanded(&session, testing.allocator, 0);
    try testing.expect(isThreadExpanded(&session, 0));
}

test "toggleThreadExpanded: toggling twice returns to default" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try session.threads.append(testing.allocator, threadWith(false));
    try toggleThreadExpanded(&session, testing.allocator, 0);
    try toggleThreadExpanded(&session, testing.allocator, 0);
    try testing.expect(isThreadExpanded(&session, 0));
    try testing.expectEqual(@as(usize, 0), session.expanded_threads.count());
}

test "setAnchored: stores slice and unplaced count, frees on replace" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);

    const first = try testing.allocator.alloc(AnchoredThread, 2);
    first[0] = .{ .thread_idx = 0, .placement = .unplaced };
    first[1] = .{ .thread_idx = 1, .placement = .{ .file_bucket = .{ .file_idx = 0, .reason = .outdated } } };
    setAnchored(&session, testing.allocator, first, 1);
    try testing.expectEqual(@as(usize, 2), session.anchored.len);
    try testing.expectEqual(@as(usize, 1), session.unplaced_count);

    // Replacing frees the previous slice (leak-checked by the testing allocator).
    const second = try testing.allocator.alloc(AnchoredThread, 1);
    second[0] = .{ .thread_idx = 0, .placement = .{ .inline_line = .{ .file_idx = 0, .hunk_idx = 0, .line_idx = 0 } } };
    setAnchored(&session, testing.allocator, second, 0);
    try testing.expectEqual(@as(usize, 1), session.anchored.len);
    try testing.expectEqual(@as(usize, 0), session.unplaced_count);
}

test "applyFetchedData: clears stale anchors and expansion overrides" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);

    const anchored = try testing.allocator.alloc(AnchoredThread, 1);
    anchored[0] = .{ .thread_idx = 0, .placement = .unplaced };
    setAnchored(&session, testing.allocator, anchored, 1);
    try session.expanded_threads.put(testing.allocator, 3, {});

    var data = try review_parse.parsePrDetails(testing.allocator, canned_payload);
    try applyFetchedData(&session, testing.allocator, &data);
    data.deinit();

    try testing.expectEqual(@as(usize, 0), session.anchored.len);
    try testing.expectEqual(@as(usize, 0), session.unplaced_count);
    try testing.expectEqual(@as(usize, 0), session.expanded_threads.count());
}

test "toggleCommentTarget: no-op when session inactive" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    // Default target is github; inactive toggle must not change it.
    try testing.expectEqual(CommentTarget.github, toggleCommentTarget(&session));
    try testing.expectEqual(CommentTarget.github, session.comment_target);
}

test "toggleCommentTarget: flips github and back when active" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    session.active = true;
    try testing.expectEqual(CommentTarget.local, toggleCommentTarget(&session));
    try testing.expectEqual(CommentTarget.github, toggleCommentTarget(&session));
}

test "githubTargetActive: true only when active and target is github" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try testing.expect(!githubTargetActive(&session)); // inactive
    session.active = true;
    try testing.expect(githubTargetActive(&session));
    session.comment_target = .local;
    try testing.expect(!githubTargetActive(&session));
}

test "appendPlaceholder: creates an owned in-flight draft thread" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    session.active = true;

    const seq = try appendPlaceholder(&session, testing.allocator, samplePost("body text"));
    try testing.expectEqual(@as(u64, 1), seq);
    try testing.expectEqual(@as(usize, 1), session.threads.items.len);

    const st = session.threads.items[0];
    try testing.expect(st.posting);
    try testing.expect(st.owned);
    try testing.expectEqual(@as(u64, 1), st.local_seq);
    try testing.expectEqualStrings("src/x.zig", st.data.path);
    try testing.expectEqual(@as(usize, 1), st.data.comments.len);
    try testing.expectEqualStrings("body text", st.data.comments[0].body);
    try testing.expectEqual(review_parse.ReviewState.pending, st.data.comments[0].review_state);

    try testing.expectEqual(@as(usize, 1), postingCount(&session));
    try testing.expectEqual(@as(usize, 1), draftCount(&session));
}

test "removePlaceholder: drops the in-flight draft (failed post)" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    const seq = try appendPlaceholder(&session, testing.allocator, samplePost("oops"));
    removePlaceholder(&session, testing.allocator, seq);
    try testing.expectEqual(@as(usize, 0), session.threads.items.len);
    try testing.expectEqual(@as(usize, 0), postingCount(&session));
}

test "replacePlaceholderWithThread: swaps the placeholder for the server thread" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    const seq = try appendPlaceholder(&session, testing.allocator, samplePost("draft"));

    const server = review_parse.ReviewThread{
        .id = "PRRT_new",
        .path = "src/x.zig",
        .line = 10,
        .start_line = null,
        .original_line = 10,
        .side = .right,
        .start_side = .right,
        .is_resolved = false,
        .is_outdated = false,
        .subject_type = .line,
        .comments = &.{},
    };
    try replacePlaceholderWithThread(&session, testing.allocator, seq, server);

    try testing.expectEqual(@as(usize, 1), session.threads.items.len);
    const st = session.threads.items[0];
    try testing.expect(!st.posting);
    try testing.expect(st.owned);
    try testing.expectEqualStrings("PRRT_new", st.data.id);
    try testing.expectEqual(@as(usize, 0), postingCount(&session));
}

test "stashFailedDraft / takeFailedDraft: round-trips the body, then clears" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    stashFailedDraft(&session, testing.allocator, "unsaved comment");

    const first = takeFailedDraft(&session);
    defer if (first) |t| testing.allocator.free(t);
    try testing.expect(first != null);
    try testing.expectEqualStrings("unsaved comment", first.?);

    // Second take is empty (ownership was transferred out).
    try testing.expect(takeFailedDraft(&session) == null);
}

test "stashFailedDraft: replaces a previously stashed body without leaking" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    stashFailedDraft(&session, testing.allocator, "first");
    stashFailedDraft(&session, testing.allocator, "second");

    const text = takeFailedDraft(&session);
    defer if (text) |t| testing.allocator.free(t);
    try testing.expectEqualStrings("second", text.?);
}

test "enqueuePost / clearQueuedPosts: queues then frees without leaking" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try enqueuePost(&session, testing.allocator, samplePost("queued"), 7);
    try testing.expectEqual(@as(usize, 1), session.queued_posts.items.len);
    try testing.expectEqual(@as(u64, 7), session.queued_posts.items[0].local_seq);
    clearQueuedPosts(&session, testing.allocator);
    try testing.expectEqual(@as(usize, 0), session.queued_posts.items.len);
}

test "applyFetchedData: preserves an in-flight placeholder across a refetch" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    session.active = true;

    _ = try appendPlaceholder(&session, testing.allocator, samplePost("still posting"));

    var data = try review_parse.parsePrDetails(testing.allocator, canned_payload);
    try applyFetchedData(&session, testing.allocator, &data);
    data.deinit();

    // One server thread plus the preserved placeholder.
    try testing.expectEqual(@as(usize, 2), session.threads.items.len);
    try testing.expect(!session.threads.items[0].posting); // server thread
    try testing.expect(session.threads.items[1].posting); // preserved placeholder
    try testing.expectEqualStrings("still posting", session.threads.items[1].data.comments[0].body);
    try testing.expectEqual(@as(usize, 1), postingCount(&session));
}

test "threadDataView: mirrors each SessionThread's data by index" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    _ = try appendPlaceholder(&session, testing.allocator, samplePost("v"));

    const view = try threadDataView(&session, testing.allocator);
    defer testing.allocator.free(view);
    try testing.expectEqual(@as(usize, 1), view.len);
    try testing.expectEqualStrings("src/x.zig", view[0].path);
}

test "pollMutations: caches a created review id even when the thread post fails" {
    const ca = std.heap.c_allocator;
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    session.active = true;

    const seq = try appendPlaceholder(&session, testing.allocator, samplePost("draft body"));

    // Simulate a worker that created the pending review but failed to post the
    // thread (no real gh / thread spawned).
    session.mutation.local_seq = seq;
    session.mutation.failed = true;
    session.mutation.fail_kind = .network;
    session.mutation.out_review_id = try ca.dupe(u8, "PRR_created");
    session.mutation.in_body = try ca.dupe(u8, "draft body");
    session.posting_worker_active = true;
    session.mutation.ready.store(true, .release);

    const outcome = pollMutations(&session, testing.allocator);
    try testing.expect(outcome == .failed);
    try testing.expectEqual(github.GhErrorKind.network, outcome.failed);

    // The created review id is cached so a retry reuses it (no double-create).
    try testing.expect(session.posted_review_id != null);
    try testing.expectEqualStrings("PRR_created", session.posted_review_id.?);
    try testing.expectEqualStrings("PRR_created", currentReviewId(&session).?);

    // The failed body is stashed and the placeholder removed.
    try testing.expectEqual(@as(usize, 0), session.threads.items.len);
    const stashed = takeFailedDraft(&session);
    defer if (stashed) |t| testing.allocator.free(t);
    try testing.expectEqualStrings("draft body", stashed.?);
}

test "pollMutations: none when no mutation is ready" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try testing.expect(pollMutations(&session, testing.allocator) == .none);
}

fn samplePost(body: []const u8) PostParams {
    return .{ .path = "src/x.zig", .line = 10, .side = .right, .body = body };
}

fn threadWith(is_resolved: bool) SessionThread {
    return .{ .data = .{
        .id = "PRRT_x",
        .path = "x",
        .line = 1,
        .start_line = null,
        .original_line = 1,
        .side = .right,
        .start_side = .right,
        .is_resolved = is_resolved,
        .is_outdated = false,
        .subject_type = .line,
        .comments = &.{},
    } };
}
