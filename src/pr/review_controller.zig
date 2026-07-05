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
    /// True while a thread interaction (reply/resolve/edit/delete) is in flight
    /// against this thread — blocks a second concurrent action on the same thread
    /// and drives the per-thread pending marker. Cleared on poll apply/failure.
    busy: bool = false,
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

/// The conversation operations on an existing review thread (FR-5). `resolve`
/// and `unresolve` are distinct so the worker can pick the right mutation
/// without re-reading thread state off-thread.
pub const ThreadMutationKind = enum { reply, resolve, unresolve, edit, delete };

/// Outcome of consuming a completed thread mutation.
pub const ThreadMutationOutcome = union(enum) {
    none,
    applied: ThreadMutationKind, // succeeded and applied locally; caller re-anchors + rebuilds
    failed: struct { kind: ThreadMutationKind, err: github.GhErrorKind },
};

/// Thread-safe handoff of a single in-flight thread mutation (reply/resolve/
/// unresolve/edit/delete) to the main loop. One runs at a time; a per-thread
/// `busy` flag blocks a second action on the same thread while further actions
/// queue. Inputs are set before spawn; outputs written under `mutex` then
/// `ready.store(true, .release)`. All buffers are `c_allocator`-owned so they
/// survive the thread boundary; `pollThreadMutations` frees them on consumption.
pub const ThreadMutation = struct {
    mutex: std.Thread.Mutex = .{},
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Inputs.
    kind: ThreadMutationKind = .reply,
    in_thread_id: []u8 = &.{}, // target thread node id (busy tracking + reply/resolve arg)
    in_comment_id: []u8 = &.{}, // edit/delete arg (comment node id)
    in_body: []u8 = &.{}, // reply/edit body

    // Outputs.
    out_raw: ?[]u8 = null, // mutation response JSON
    failed: bool = false,
    fail_kind: github.GhErrorKind = .other,
};

const QueuedThreadMutation = struct {
    kind: ThreadMutationKind,
    thread_id: []u8,
    comment_id: []u8,
    body: []u8,
};

/// Two-step delete confirmation (AD-8 draft safety for destructive ops). Armed
/// by the first `d` on a thread; the second `d` fires the delete, any other key
/// disarms. Keyed by the thread's node id (an owned copy) — NOT a positional
/// index — so a concurrent mutation that shifts or removes threads between the
/// two `d` keypresses can never redirect the delete onto a neighbouring thread.
/// The id is re-resolved to a live index at fire time (`fireThreadDelete`),
/// mirroring the save-time re-resolution of reply/edit. Transient UI state:
/// cleared on refetch alongside `expanded_threads`.
pub const DeleteConfirm = struct {
    thread_id: []u8,
};

/// The terminal review verdict (FR-6). Maps to a `PullRequestReviewEvent`
/// (`verdictEvent`) for the mutation and to a `ReviewState` (`verdictState`) for
/// the optimistic post-submit flip of the session's pending comments.
pub const Verdict = enum { comment, approve, request_changes };

const SubmitKind = enum { submit, discard };

/// Live submit-dialog state (FR-6/FR-7). `error_msg` (a failed submit, surfaced
/// in the dialog) and `body_stash` (the in-progress body preserved when the
/// dialog is closed with Esc so a reopen restores it — AD-8 draft safety) are
/// session-allocator-owned. The body editor itself lives in the imperative shell
/// (`app.state`), not here — the controller stays free of `vim_editor`, which is
/// outside the `pr/` test-module root.
pub const SubmitState = struct {
    verdict: Verdict = .comment,
    submitting: bool = false,
    confirm_discard: bool = false,
    error_msg: ?[]u8 = null,
    body_stash: ?[]u8 = null,
};

/// Thread-safe handoff of an in-flight submit/discard to the main loop (AD-3).
/// Inputs set before spawn; outputs written under `mutex` then
/// `ready.store(true, .release)`. All buffers are `c_allocator`-owned so they
/// survive the thread boundary; `pollSubmit` frees them on consumption.
pub const PendingSubmit = struct {
    mutex: std.Thread.Mutex = .{},
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    kind: SubmitKind = .submit,

    // Inputs.
    in_pr_node_id: []u8 = &.{},
    in_head_oid: []u8 = &.{},
    in_review_id: ?[]u8 = null, // cached pending review id, or null → worker creates (submit)
    in_event: []u8 = &.{}, // PullRequestReviewEvent string
    in_body: []u8 = &.{},
    verdict: Verdict = .comment,

    // Outputs.
    out_review_id: ?[]u8 = null, // review id used/created (cached on success)
    out_error_msg: ?[]u8 = null, // 200-with-errors message (self-approval etc.)
    failed: bool = false,
    fail_kind: github.GhErrorKind = .other,
};

/// Client-side disposition of a submit/discard request (before any worker spawn).
pub const SubmitAction = enum { started, refused_empty, refused_no_review, busy };

/// Outcome of consuming a completed submit/discard.
pub const SubmitOutcome = union(enum) {
    none,
    submitted: Verdict, // review posted; caller refetches for authoritative data
    submit_failed: github.GhErrorKind,
    discarded, // pending review deleted; drafts removed locally
    discard_failed: github.GhErrorKind,
};

/// Resolved/unresolved thread tallies for the status-bar summary (FR-6).
pub const ThreadCounts = struct {
    total: usize = 0,
    unresolved: usize = 0,
};

/// Thread-safe handoff of a background entry/refetch to the main loop. Worker
/// writes results under the mutex, then `ready.store(true, .release)`. All
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

    // Thread interactions (Phase 4, FR-5): reply / resolve / edit / delete on an
    // existing thread. Serialized like posts (one worker, the rest queue) with a
    // per-thread `busy` marker so a second action on the same thread is refused.
    thread_mutation: ThreadMutation = .{},
    thread_mutation_thread: ?std.Thread = null,
    thread_mut_active: bool = false,
    queued_thread_mutations: std.ArrayList(QueuedThreadMutation) = .{},
    // Two-step delete confirmation state (null = disarmed). See `DeleteConfirm`.
    delete_confirm: ?DeleteConfirm = null,

    // Submit / discard (Phase 5, FR-6/FR-7). The verdict dialog + its async
    // machinery. A submit/discard is the terminal action: it refuses while any
    // inline post / thread-interaction work is outstanding (`hasThreadWriteWork`)
    // so its `createPendingReview` can never race `postThreadWorker`'s into a
    // double pending-review create (GitHub allows one pending review per PR).
    submit: SubmitState = .{},
    submit_mutation: PendingSubmit = .{},
    submit_thread: ?std.Thread = null,
    submit_in_flight: bool = false,

    // Read-only PR info panel scroll offset (transient view state; FR-7).
    info_scroll: usize = 0,
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
    disarmDeleteConfirm(self, allocator);

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
        failPost(self, allocator, seq);
        outcome = .{ .failed = fail_kind };
    } else if (applyPostedThread(self, allocator, out_thread_raw, seq)) {
        outcome = .posted;
    } else |_| {
        failPost(self, allocator, seq);
        outcome = .{ .failed = .other };
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

/// Borrow the stashed failed-draft body WITHOUT clearing it. Used to pre-fill an
/// editor whose send is not yet committed (reply): the stash is only cleared once
/// the send actually succeeds, so cancelling or emptying the editor preserves the
/// draft for retry (AD-8). Null when there is nothing stashed.
pub fn peekFailedDraft(self: *const ReviewSession) ?[]const u8 {
    return self.draft_failed_text;
}

// =============================================================================
// Thread interactions (FR-5): reply / resolve / edit / delete
// =============================================================================

/// Whether thread `thread_idx` has a mutation in flight (blocks a second action
/// on the same thread and drives the "…" busy badge).
pub fn isThreadBusy(self: *const ReviewSession, thread_idx: usize) bool {
    if (thread_idx >= self.threads.items.len) return false;
    return self.threads.items[thread_idx].busy;
}

/// The last comment authored by the viewer in `thread` (edit/delete target), or
/// null when the viewer owns none.
pub fn lastOwnCommentIdx(thread: *const SessionThread) ?usize {
    var result: ?usize = null;
    for (thread.data.comments, 0..) |c, i| {
        if (c.is_mine) result = i;
    }
    return result;
}

/// Begin an async reply to `thread_idx` with `body`. Refused (returns false)
/// when the index is out of range, the thread is busy, or the thread is still an
/// unposted placeholder. On success marks the thread busy and dispatches (or
/// queues) the worker.
pub fn startReply(self: *ReviewSession, allocator: Allocator, thread_idx: usize, body: []const u8) !bool {
    const st = mutableThread(self, thread_idx) orelse return false;
    if (st.busy or st.posting) return false;
    const thread_id = st.data.id;
    st.busy = true;
    errdefer st.busy = false;
    try beginThreadMutation(self, allocator, .{ .kind = .reply, .thread_id = thread_id, .comment_id = "", .body = body });
    return true;
}

/// Begin an async resolve/unresolve toggle on `thread_idx` (picks the mutation
/// from the thread's current resolved state). Same refusal rules as `startReply`.
pub fn startToggleResolve(self: *ReviewSession, allocator: Allocator, thread_idx: usize) !bool {
    const st = mutableThread(self, thread_idx) orelse return false;
    if (st.busy or st.posting) return false;
    const thread_id = st.data.id;
    const kind: ThreadMutationKind = if (st.data.is_resolved) .unresolve else .resolve;
    st.busy = true;
    errdefer st.busy = false;
    try beginThreadMutation(self, allocator, .{ .kind = kind, .thread_id = thread_id, .comment_id = "", .body = "" });
    return true;
}

/// Begin an async edit of the comment at `comment_idx` in `thread_idx` with
/// `new_body`. Refused when the index/comment is invalid, the thread is busy, or
/// it is an unposted placeholder.
pub fn startEditOwn(self: *ReviewSession, allocator: Allocator, thread_idx: usize, comment_idx: usize, new_body: []const u8) !bool {
    const st = mutableThread(self, thread_idx) orelse return false;
    if (st.busy or st.posting) return false;
    if (comment_idx >= st.data.comments.len) return false;
    const comment_id = st.data.comments[comment_idx].id;
    const thread_id = st.data.id;
    st.busy = true;
    errdefer st.busy = false;
    try beginThreadMutation(self, allocator, .{ .kind = .edit, .thread_id = thread_id, .comment_id = comment_id, .body = new_body });
    return true;
}

/// Begin an async delete of the viewer's last comment in `thread_idx`. Refused
/// when the thread is busy/placeholder or the viewer owns no comment in it.
pub fn startDeleteOwn(self: *ReviewSession, allocator: Allocator, thread_idx: usize) !bool {
    const st = mutableThread(self, thread_idx) orelse return false;
    if (st.busy or st.posting) return false;
    const own_idx = lastOwnCommentIdx(st) orelse return false;
    const comment_id = st.data.comments[own_idx].id;
    const thread_id = st.data.id;
    st.busy = true;
    errdefer st.busy = false;
    try beginThreadMutation(self, allocator, .{ .kind = .delete, .thread_id = thread_id, .comment_id = comment_id, .body = "" });
    return true;
}

/// Arm the two-step delete confirmation for the thread with `thread_id` (first
/// `d`). Stores an owned copy of the node id so it survives concurrent thread
/// removal/reordering; on OOM the confirmation is simply left disarmed.
pub fn armDeleteConfirm(self: *ReviewSession, allocator: Allocator, thread_id: []const u8) void {
    if (self.delete_confirm) |dc| allocator.free(dc.thread_id);
    self.delete_confirm = null;
    const id = allocator.dupe(u8, thread_id) catch return;
    self.delete_confirm = .{ .thread_id = id };
}

/// Disarm the delete confirmation (any key other than the confirming `d`).
pub fn disarmDeleteConfirm(self: *ReviewSession, allocator: Allocator) void {
    if (self.delete_confirm) |dc| allocator.free(dc.thread_id);
    self.delete_confirm = null;
}

/// The node id of the thread currently armed for delete confirmation, or null.
/// Borrows the session-owned copy; valid until the next arm/disarm/refetch.
pub fn deleteConfirmArmed(self: *const ReviewSession) ?[]const u8 {
    if (self.delete_confirm) |dc| return dc.thread_id;
    return null;
}

/// Consume a completed thread mutation, if ready. Joins the worker, clears the
/// target thread's busy flag, applies the response locally (append reply / flip
/// resolved / replace body / remove comment-or-thread) or stashes the failed
/// text (reply/edit) for retry, frees worker buffers, and dispatches the next
/// queued mutation. Returns `.none` when nothing is ready.
pub fn pollThreadMutations(self: *ReviewSession, allocator: Allocator) ThreadMutationOutcome {
    if (!self.thread_mutation.ready.load(.acquire)) return .none;

    self.thread_mutation.mutex.lock();
    const out_raw = self.thread_mutation.out_raw;
    const failed = self.thread_mutation.failed;
    const fail_kind = self.thread_mutation.fail_kind;
    self.thread_mutation.out_raw = null;
    self.thread_mutation.mutex.unlock();
    self.thread_mutation.ready.store(false, .release);

    if (self.thread_mutation_thread) |t| {
        t.join();
        self.thread_mutation_thread = null;
    }
    self.thread_mut_active = false;

    const ca = std.heap.c_allocator;
    const kind = self.thread_mutation.kind;
    const thread_id = self.thread_mutation.in_thread_id;
    const comment_id = self.thread_mutation.in_comment_id;

    // Clear the target thread's busy marker (found by node id — its positional
    // index may have shifted under a concurrent refetch).
    if (threadIdxById(self, thread_id)) |i| self.threads.items[i].busy = false;

    var outcome: ThreadMutationOutcome = .{ .failed = .{ .kind = kind, .err = .other } };
    if (failed) {
        if (kind == .reply or kind == .edit) stashFailedDraft(self, allocator, self.thread_mutation.in_body);
        outcome = .{ .failed = .{ .kind = kind, .err = fail_kind } };
    } else if (out_raw) |raw| {
        if (applyThreadMutation(self, allocator, .{ .kind = kind, .thread_id = thread_id, .comment_id = comment_id, .raw = raw })) {
            outcome = .{ .applied = kind };
        } else |_| {
            if (kind == .reply or kind == .edit) stashFailedDraft(self, allocator, self.thread_mutation.in_body);
            outcome = .{ .failed = .{ .kind = kind, .err = .other } };
        }
    }

    if (out_raw) |raw| ca.free(raw);
    freeThreadMutationBuffers(self);
    drainThreadQueue(self, allocator);
    return outcome;
}

/// Apply a completed thread-mutation response to the session (identity-keyed by
/// node id; positional indices are never trusted). Server threads touched by a
/// text mutation are first converted to session-owned copies so the response can
/// mutate their strings; on refetch those owned copies are discarded in favor of
/// authoritative server data. A response for a thread/comment that no longer
/// exists locally (e.g. a concurrent refetch removed it) is a silent no-op — no
/// crash, no log (a logged warn would fail the test runner). `params.raw` remains
/// owned by the caller.
pub fn applyThreadMutation(
    self: *ReviewSession,
    allocator: Allocator,
    params: struct { kind: ThreadMutationKind, thread_id: []const u8, comment_id: []const u8, raw: []const u8 },
) !void {
    switch (params.kind) {
        .reply => {
            var created = try review_parse.parseCreatedComment(allocator, params.raw, self.viewer_login);
            defer created.deinit();
            const idx = threadIdxById(self, params.thread_id) orelse return;
            try ensureOwnedThread(self, allocator, idx);
            try appendCommentOwned(self, allocator, idx, created.comment);
        },
        .resolve, .unresolve => {
            var r = try review_parse.parseResolveResult(allocator, params.raw);
            defer r.deinit();
            const idx = threadIdxById(self, params.thread_id) orelse return;
            self.threads.items[idx].data.is_resolved = r.is_resolved;
            // Reset expand override: default flips with resolved state.
            _ = self.expanded_threads.remove(idx);
        },
        .edit => {
            var u = try review_parse.parseUpdatedComment(allocator, params.raw);
            defer u.deinit();
            const loc = findCommentLoc(self, params.comment_id) orelse return;
            try ensureOwnedThread(self, allocator, loc.thread_idx);
            replaceCommentBodyOwned(self, allocator, loc.thread_idx, params.comment_id, u.body);
        },
        .delete => {
            const del_id = try review_parse.parseDeletedComment(allocator, params.raw);
            allocator.free(del_id);
            const loc = findCommentLoc(self, params.comment_id) orelse return;
            try ensureOwnedThread(self, allocator, loc.thread_idx);
            try removeCommentOwned(self, allocator, loc.thread_idx, params.comment_id);
            if (self.threads.items[loc.thread_idx].data.comments.len == 0) {
                removeThreadAt(self, allocator, loc.thread_idx);
            }
        },
    }
}

/// Count of draft threads to show in the status bar: threads whose comments are
/// all pending, plus in-flight placeholders.
pub fn draftCount(self: *const ReviewSession) usize {
    var count: usize = 0;
    for (self.threads.items) |*st| {
        if (isDraftThread(st)) count += 1;
    }
    return count;
}

/// Resolved/unresolved tallies over the SERVER threads (excludes in-flight
/// placeholders and drafts — a draft is not yet a conversation). Feeds the
/// status-bar review summary (FR-6).
pub fn threadCounts(self: *const ReviewSession) ThreadCounts {
    var counts = ThreadCounts{};
    for (self.threads.items) |*st| {
        if (st.posting or isDraftThread(st)) continue;
        counts.total += 1;
        if (!st.data.is_resolved) counts.unresolved += 1;
    }
    return counts;
}

/// Number of in-flight / queued optimistic placeholders (status-bar "posting…").
pub fn postingCount(self: *const ReviewSession) usize {
    var count: usize = 0;
    for (self.threads.items) |st| {
        if (st.posting) count += 1;
    }
    return count;
}

/// Total logical lines the PR info panel scrolls over (FR-7). MUST mirror the
/// section accounting in `review_render.drawInfoBody` so the mode's scroll clamp
/// (and `G`) agree with what is actually rendered: a Checks section (header +
/// rows + spacer), a Reviews section (header + rows + spacer), then the
/// Description (header + body lines). Each section is present only when non-empty.
pub fn infoLineCount(self: *const ReviewSession) usize {
    var total: usize = 0;
    if (self.checks.items.len > 0) total += 2 + self.checks.items.len; // header + rows + spacer
    if (self.reviews.items.len > 0) total += 2 + self.reviews.items.len; // header + rows + spacer
    if (self.body.len > 0) total += 1 + bodyLineCount(self.body); // header + body lines
    return total;
}

/// Whether any write-path work (a running worker, a ready result, or queued
/// posts) is outstanding — joins the main loop's poll predicate.
pub fn hasPostingWork(self: *const ReviewSession) bool {
    return hasThreadWriteWork(self) or hasSubmitWork(self);
}

/// Whether any inline post or thread-interaction (reply/resolve/edit/delete) work
/// is outstanding — excludes the terminal submit/discard. A submit/discard refuses
/// while this is true (see `submitGuard` / `startDiscard`) so its pending-review
/// creation can't race a concurrent `postThreadWorker` into a double create.
pub fn hasThreadWriteWork(self: *const ReviewSession) bool {
    return self.posting_worker_active or self.mutation.ready.load(.acquire) or self.queued_posts.items.len > 0 or
        self.thread_mut_active or self.thread_mutation.ready.load(.acquire) or self.queued_thread_mutations.items.len > 0;
}

/// Whether a submit/discard worker is running or has a result waiting — joins the
/// main loop's poll predicate so `pollSubmit` gets called.
pub fn hasSubmitWork(self: *const ReviewSession) bool {
    return self.submit_in_flight or self.submit_mutation.ready.load(.acquire);
}

// =============================================================================
// Submit / discard (FR-6/FR-7)
// =============================================================================

/// The `PullRequestReviewEvent` string for a verdict (mutation arg).
pub fn verdictEvent(verdict: Verdict) []const u8 {
    return switch (verdict) {
        .comment => "COMMENT",
        .approve => "APPROVE",
        .request_changes => "REQUEST_CHANGES",
    };
}

/// The human label for a verdict (dialog selector).
pub fn verdictLabel(verdict: Verdict) []const u8 {
    return switch (verdict) {
        .comment => "Comment",
        .approve => "Approve",
        .request_changes => "Request changes",
    };
}

/// Cycle the selected verdict (Tab / Shift-Tab in the dialog). `forward` advances
/// comment → approve → request_changes → comment.
pub fn cycleVerdict(self: *ReviewSession, forward: bool) void {
    const order = [_]Verdict{ .comment, .approve, .request_changes };
    var idx: usize = 0;
    for (order, 0..) |v, i| {
        if (v == self.submit.verdict) idx = i;
    }
    const n = order.len;
    idx = if (forward) (idx + 1) % n else (idx + n - 1) % n;
    self.submit.verdict = order[idx];
}

/// Begin an async submit of the selected verdict with `body` (FR-6). Refuses a
/// COMMENT review that would post nothing (empty body AND no drafts), refuses
/// (`.busy`) when a submit/discard is already in flight OR inline post/thread work
/// is still outstanding (`hasThreadWriteWork` — avoids a double pending-review
/// create), and refuses when no session is active. On `.started` the worker
/// ensures a pending review then submits it.
pub fn startSubmit(self: *ReviewSession, allocator: Allocator, body: []const u8) !SubmitAction {
    if (submitGuard(self, body)) |refusal| return refusal;
    clearSubmitError(self, allocator);
    try spawnSubmit(self, .submit, body);
    self.submit.submitting = true;
    return .started;
}

/// The client-side decision for a submit: a refusal `SubmitAction`, or null when
/// the submit should proceed (spawn a worker). Pure — split out so the decision
/// is unit-testable without spawning a live `gh` worker (AD-10).
pub fn submitGuard(self: *const ReviewSession, body: []const u8) ?SubmitAction {
    if (!self.active) return .refused_no_review;
    if (self.submit_in_flight or self.submit_mutation.ready.load(.acquire)) return .busy;
    if (hasThreadWriteWork(self)) return .busy;
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0 and self.submit.verdict == .comment and draftCount(self) == 0) return .refused_empty;
    return null;
}

/// Begin an async discard of the pending review (FR-7): deletes it server-side,
/// removing all its draft comments. Refuses when there is no pending review to
/// discard, a submit/discard is already running, or inline post/thread work is
/// still outstanding (`hasThreadWriteWork`).
pub fn startDiscard(self: *ReviewSession, allocator: Allocator) !SubmitAction {
    if (!self.active) return .refused_no_review;
    if (self.submit_in_flight or self.submit_mutation.ready.load(.acquire)) return .busy;
    if (hasThreadWriteWork(self)) return .busy;
    if (currentReviewId(self) == null) return .refused_no_review;
    clearSubmitError(self, allocator);
    try spawnSubmit(self, .discard, "");
    self.submit.submitting = true;
    return .started;
}

/// Consume a completed submit/discard, if ready. Joins the worker, caches any
/// created review id, applies the local effect (optimistic verdict flip / draft
/// removal) or records the error for the dialog, closes the dialog on success,
/// and frees worker buffers. Returns `.none` when nothing is ready.
pub fn pollSubmit(self: *ReviewSession, allocator: Allocator) SubmitOutcome {
    if (!self.submit_mutation.ready.load(.acquire)) return .none;

    self.submit_mutation.mutex.lock();
    const out_review_id = self.submit_mutation.out_review_id;
    const out_error_msg = self.submit_mutation.out_error_msg;
    const failed = self.submit_mutation.failed;
    const fail_kind = self.submit_mutation.fail_kind;
    const kind = self.submit_mutation.kind;
    const verdict = self.submit_mutation.verdict;
    self.submit_mutation.out_review_id = null;
    self.submit_mutation.out_error_msg = null;
    self.submit_mutation.mutex.unlock();
    self.submit_mutation.ready.store(false, .release);

    if (self.submit_thread) |t| {
        t.join();
        self.submit_thread = null;
    }
    self.submit_in_flight = false;
    self.submit.submitting = false;

    const ca = std.heap.c_allocator;
    // Cache a created review id even on a partial failure (review created, submit
    // rejected) so a retry / discard reuses it instead of double-creating.
    if (out_review_id) |rid| setReviewId(self, allocator, rid);

    var outcome: SubmitOutcome = .none;
    if (failed) {
        setSubmitError(self, allocator, out_error_msg orelse github.kindMessage(fail_kind));
        outcome = if (kind == .discard) .{ .discard_failed = fail_kind } else .{ .submit_failed = fail_kind };
    } else if (kind == .discard) {
        applyDiscard(self, allocator);
        closeSubmitDialogSilent(self, allocator);
        outcome = .discarded;
    } else {
        applySubmitSuccess(self, allocator, verdict);
        closeSubmitDialogSilent(self, allocator);
        outcome = .{ .submitted = verdict };
    }

    if (out_review_id) |r| ca.free(r);
    if (out_error_msg) |r| ca.free(r);
    freeSubmitBuffers(self);
    return outcome;
}

/// Arm the two-step discard confirmation (first Ctrl-D). The second Ctrl-D fires
/// `startDiscard`; any other key disarms.
pub fn armDiscardConfirm(self: *ReviewSession) void {
    self.submit.confirm_discard = true;
}

/// Disarm the discard confirmation.
pub fn disarmDiscardConfirm(self: *ReviewSession) void {
    self.submit.confirm_discard = false;
}

/// Whether the discard confirmation is armed.
pub fn discardArmed(self: *const ReviewSession) bool {
    return self.submit.confirm_discard;
}

/// Preserve the in-progress submit body (Esc-out) so a reopen restores it (AD-8).
/// An empty/whitespace body clears the stash rather than preserving stale text.
pub fn stashSubmitBody(self: *ReviewSession, allocator: Allocator, body: []const u8) void {
    if (self.submit.body_stash) |s| allocator.free(s);
    self.submit.body_stash = null;
    if (std.mem.trim(u8, body, " \t\r\n").len == 0) return;
    self.submit.body_stash = allocator.dupe(u8, body) catch null;
}

/// Borrow the stashed submit body (to pre-fill the reopened editor), or null.
pub fn submitBodyStash(self: *const ReviewSession) ?[]const u8 {
    return self.submit.body_stash;
}

/// Borrow the last submit-error text (surfaced in the dialog), or null.
pub fn submitError(self: *const ReviewSession) ?[]const u8 {
    return self.submit.error_msg;
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

    // Join any in-flight thread-mutation worker for the same reason.
    if (self.thread_mutation_thread) |t| t.join();
    self.thread_mutation_thread = null;
    self.thread_mut_active = false;

    // Join any in-flight submit/discard worker for the same reason.
    if (self.submit_thread) |t| t.join();
    self.submit_thread = null;
    self.submit_in_flight = false;

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
    freeThreadMutationBuffers(self);
    clearQueuedThreadMutations(self, allocator);
    self.queued_thread_mutations.deinit(allocator);
    if (self.draft_failed_text) |t| allocator.free(t);
    self.draft_failed_text = null;
    disarmDeleteConfirm(self, allocator);

    freeSubmitBuffers(self);
    if (self.submit.error_msg) |m| allocator.free(m);
    self.submit.error_msg = null;
    if (self.submit.body_stash) |s| allocator.free(s);
    self.submit.body_stash = null;

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

/// Roll back a failed post: stash the in-flight body for retry (NFR-2) and drop
/// the optimistic placeholder.
fn failPost(self: *ReviewSession, allocator: Allocator, seq: u64) void {
    stashFailedDraft(self, allocator, self.mutation.in_body);
    removePlaceholder(self, allocator, seq);
}

/// Success path for a completed post: parse the server thread and swap it in for
/// the placeholder. Errors (missing raw, parse failure, replace failure) all map
/// to the same `.other` rollback in `pollMutations`.
fn applyPostedThread(self: *ReviewSession, allocator: Allocator, raw: ?[]const u8, seq: u64) !void {
    const bytes = raw orelse return error.MissingThread;
    var created = try review_parse.parseCreatedThread(allocator, bytes, self.viewer_login);
    defer created.deinit();
    try replacePlaceholderWithThread(self, allocator, seq, created.thread);
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

/// Outcome of resolving a worker's pending-review id.
const ResolvedReviewId = struct {
    /// ca-owned working copy; the caller must free it.
    review_id: ?[]u8,
    /// ca-owned id to surface when a pending review was newly created.
    out_review_id: ?[]u8,
    failed: bool,
    fail_kind: github.GhErrorKind,
};

/// Reuse the passed pending-review id or create one via GitHub. Shared by the
/// post and submit workers so the create/parse/ownership dance stays in lockstep.
fn resolveReviewId(in_review_id: ?[]const u8, pr_node_id: []const u8, head_oid: []const u8) ResolvedReviewId {
    const ca = std.heap.c_allocator;
    var result: ResolvedReviewId = .{ .review_id = null, .out_review_id = null, .failed = false, .fail_kind = .other };
    if (in_review_id) |rid| {
        result.review_id = ca.dupe(u8, rid) catch blk: {
            result.failed = true;
            break :blk null;
        };
    } else if (github.createPendingReview(ca, pr_node_id, head_oid)) |fetch| {
        switch (fetch) {
            .ok => |raw| {
                defer ca.free(raw);
                if (review_parse.parseCreatedReviewId(ca, raw)) |id| {
                    result.review_id = id;
                    result.out_review_id = ca.dupe(u8, id) catch null;
                } else |_| {
                    result.failed = true;
                }
            },
            .failed => |k| {
                result.failed = true;
                result.fail_kind = k;
            },
        }
    } else |_| {
        result.failed = true;
    }
    return result;
}

/// Post worker (AD-3). Runs on `c_allocator` so its results survive the thread
/// boundary. Reuses the cached review id or creates a pending review first, then
/// posts the thread. Writes outputs under the mutex and flips `ready`.
fn postThreadWorker(self: *ReviewSession) void {
    const ca = std.heap.c_allocator;
    var out_thread_raw: ?[]u8 = null;

    const resolved = resolveReviewId(self.mutation.in_review_id, self.mutation.in_pr_node_id, self.mutation.in_head_oid);
    const review_id = resolved.review_id; // ca-owned working copy
    defer if (review_id) |r| ca.free(r);
    const out_review_id = resolved.out_review_id;
    var failed = resolved.failed;
    var fail_kind = resolved.fail_kind;

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
        comments[i] = try dupeComment(allocator, c);
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
    for (st.data.comments) |c| freeComment(allocator, c);
    if (st.data.comments.len > 0) allocator.free(st.data.comments);
    allocator.free(st.data.id);
    allocator.free(st.data.path);
}

/// Deep-copy one `ReviewComment` into session-allocator-owned strings.
fn dupeComment(allocator: Allocator, c: review_parse.ReviewComment) !review_parse.ReviewComment {
    return .{
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

/// Free one session-owned `ReviewComment`'s strings.
fn freeComment(allocator: Allocator, c: review_parse.ReviewComment) void {
    allocator.free(c.id);
    allocator.free(c.author);
    allocator.free(c.body);
    allocator.free(c.created_at);
    allocator.free(c.review_id);
    allocator.free(c.diff_hunk);
}

// --- Thread-interaction helpers ----------------------------------------------

pub const CommentLoc = struct { thread_idx: usize, comment_idx: usize };

/// Mutable pointer to the thread at `thread_idx`, or null when out of range.
fn mutableThread(self: *ReviewSession, thread_idx: usize) ?*SessionThread {
    if (thread_idx >= self.threads.items.len) return null;
    return &self.threads.items[thread_idx];
}

/// Positional index of the thread whose node id equals `id`, or null. Public so
/// the editor save path can re-resolve a reply/edit target whose index may have
/// shifted under a concurrent mutation while the editor was open (AD-4 identity).
pub fn threadIdxById(self: *const ReviewSession, id: []const u8) ?usize {
    for (self.threads.items, 0..) |st, i| {
        if (std.mem.eql(u8, st.data.id, id)) return i;
    }
    return null;
}

/// Locate a comment by node id across all threads, or null when absent. Public
/// for the same save-time re-resolution reason as `threadIdxById`.
pub fn findCommentLoc(self: *const ReviewSession, comment_id: []const u8) ?CommentLoc {
    for (self.threads.items, 0..) |st, ti| {
        for (st.data.comments, 0..) |c, ci| {
            if (std.mem.eql(u8, c.id, comment_id)) return .{ .thread_idx = ti, .comment_idx = ci };
        }
    }
    return null;
}

/// Dispatch a thread mutation, or queue it behind an in-flight one. Inputs are
/// borrowed; `spawnThreadMutation`/`enqueueThreadMutation` copy them.
fn beginThreadMutation(
    self: *ReviewSession,
    allocator: Allocator,
    params: struct { kind: ThreadMutationKind, thread_id: []const u8, comment_id: []const u8, body: []const u8 },
) !void {
    if (self.thread_mut_active or self.thread_mutation.ready.load(.acquire)) {
        try enqueueThreadMutation(self, allocator, params.kind, params.thread_id, params.comment_id, params.body);
        return;
    }
    try spawnThreadMutation(self, params.kind, params.thread_id, params.comment_id, params.body);
}

/// Copy the mutation inputs into `c_allocator` buffers and spawn the worker.
fn spawnThreadMutation(self: *ReviewSession, kind: ThreadMutationKind, thread_id: []const u8, comment_id: []const u8, body: []const u8) !void {
    const ca = std.heap.c_allocator;
    const tid = try ca.dupe(u8, thread_id);
    errdefer ca.free(tid);
    const cid = try ca.dupe(u8, comment_id);
    errdefer ca.free(cid);
    const b = try ca.dupe(u8, body);
    errdefer ca.free(b);

    self.thread_mutation.kind = kind;
    self.thread_mutation.in_thread_id = tid;
    self.thread_mutation.in_comment_id = cid;
    self.thread_mutation.in_body = b;
    self.thread_mutation.out_raw = null;
    self.thread_mutation.failed = false;
    self.thread_mutation.fail_kind = .other;
    self.thread_mutation.ready.store(false, .release);

    self.thread_mutation_thread = std.Thread.spawn(.{}, threadMutationWorker, .{self}) catch {
        // Detach the buffers from the struct; the errdefers above free them.
        self.thread_mutation.in_thread_id = &.{};
        self.thread_mutation.in_comment_id = &.{};
        self.thread_mutation.in_body = &.{};
        return error.SpawnFailed;
    };
    self.thread_mut_active = true;
}

/// Thread-mutation worker (AD-3). Runs on `c_allocator`; writes the raw response
/// (or failure classification) under the mutex, then flips `ready`.
fn threadMutationWorker(self: *ReviewSession) void {
    const ca = std.heap.c_allocator;
    var failed = false;
    var fail_kind: github.GhErrorKind = .other;
    var out_raw: ?[]u8 = null;

    const m = &self.thread_mutation;
    const result = switch (m.kind) {
        .reply => github.replyToThread(ca, m.in_thread_id, m.in_body),
        .resolve => github.resolveThread(ca, m.in_thread_id),
        .unresolve => github.unresolveThread(ca, m.in_thread_id),
        .edit => github.updateReviewComment(ca, m.in_comment_id, m.in_body),
        .delete => github.deleteReviewComment(ca, m.in_comment_id),
    };
    if (result) |fetch| {
        switch (fetch) {
            .ok => |raw| out_raw = raw,
            .failed => |k| {
                failed = true;
                fail_kind = k;
            },
        }
    } else |_| {
        failed = true;
    }

    m.mutex.lock();
    m.out_raw = out_raw;
    m.failed = failed;
    m.fail_kind = fail_kind;
    m.mutex.unlock();
    m.ready.store(true, .release);
}

/// Queue a thread mutation behind the in-flight worker (copying its inputs onto
/// the session allocator).
fn enqueueThreadMutation(self: *ReviewSession, allocator: Allocator, kind: ThreadMutationKind, thread_id: []const u8, comment_id: []const u8, body: []const u8) !void {
    const tid = try allocator.dupe(u8, thread_id);
    errdefer allocator.free(tid);
    const cid = try allocator.dupe(u8, comment_id);
    errdefer allocator.free(cid);
    const b = try allocator.dupe(u8, body);
    errdefer allocator.free(b);
    try self.queued_thread_mutations.append(allocator, .{ .kind = kind, .thread_id = tid, .comment_id = cid, .body = b });
}

/// Dispatch the next queued thread mutation if the worker is idle. If the spawn
/// fails, the target thread's busy marker is cleared so it isn't stuck.
fn drainThreadQueue(self: *ReviewSession, allocator: Allocator) void {
    if (self.queued_thread_mutations.items.len == 0) return;
    if (self.thread_mut_active or self.thread_mutation.ready.load(.acquire)) return;

    const q = self.queued_thread_mutations.orderedRemove(0);
    defer {
        allocator.free(q.thread_id);
        allocator.free(q.comment_id);
        allocator.free(q.body);
    }
    spawnThreadMutation(self, q.kind, q.thread_id, q.comment_id, q.body) catch {
        if (threadIdxById(self, q.thread_id)) |i| self.threads.items[i].busy = false;
    };
}

/// Free the `c_allocator` buffers held on `self.thread_mutation` and reset them.
fn freeThreadMutationBuffers(self: *ReviewSession) void {
    const ca = std.heap.c_allocator;
    if (self.thread_mutation.in_thread_id.len > 0) ca.free(self.thread_mutation.in_thread_id);
    if (self.thread_mutation.in_comment_id.len > 0) ca.free(self.thread_mutation.in_comment_id);
    if (self.thread_mutation.in_body.len > 0) ca.free(self.thread_mutation.in_body);
    if (self.thread_mutation.out_raw) |r| ca.free(r);
    self.thread_mutation.in_thread_id = &.{};
    self.thread_mutation.in_comment_id = &.{};
    self.thread_mutation.in_body = &.{};
    self.thread_mutation.out_raw = null;
}

/// Free every queued thread mutation's session-owned buffers.
fn clearQueuedThreadMutations(self: *ReviewSession, allocator: Allocator) void {
    for (self.queued_thread_mutations.items) |q| {
        allocator.free(q.thread_id);
        allocator.free(q.comment_id);
        allocator.free(q.body);
    }
    self.queued_thread_mutations.clearRetainingCapacity();
}

/// Convert the server thread at `idx` into a session-owned deep copy in place, so
/// its strings can be mutated (append/replace/remove). No-op when already owned.
fn ensureOwnedThread(self: *ReviewSession, allocator: Allocator, idx: usize) !void {
    const st = &self.threads.items[idx];
    if (st.owned) return;
    const owned_data = try dupeThreadOwned(allocator, st.data);
    self.threads.items[idx] = .{
        .data = owned_data,
        .posting = st.posting,
        .owned = true,
        .local_seq = st.local_seq,
        .busy = st.busy,
    };
}

/// Append a deep copy of `comment` to the owned thread at `idx` (reallocating its
/// comment slice). The thread MUST already be owned (`ensureOwnedThread`).
fn appendCommentOwned(self: *ReviewSession, allocator: Allocator, idx: usize, comment: review_parse.ReviewComment) !void {
    const t = &self.threads.items[idx].data;
    const old = t.comments;
    const new = try allocator.alloc(review_parse.ReviewComment, old.len + 1);
    @memcpy(new[0..old.len], old);
    new[old.len] = dupeComment(allocator, comment) catch |err| {
        allocator.free(new);
        return err;
    };
    if (old.len > 0) allocator.free(old);
    t.comments = new;
}

/// Replace the body of the comment with `comment_id` in the owned thread at `idx`.
fn replaceCommentBodyOwned(self: *ReviewSession, allocator: Allocator, idx: usize, comment_id: []const u8, new_body: []const u8) void {
    const t = &self.threads.items[idx].data;
    for (t.comments) |*c| {
        if (std.mem.eql(u8, c.id, comment_id)) {
            const nb = allocator.dupe(u8, new_body) catch return;
            allocator.free(c.body);
            c.body = nb;
            return;
        }
    }
}

/// Remove the comment with `comment_id` from the owned thread at `idx`, freeing
/// its strings and shrinking the comment slice.
fn removeCommentOwned(self: *ReviewSession, allocator: Allocator, idx: usize, comment_id: []const u8) !void {
    const t = &self.threads.items[idx].data;
    const old = t.comments;
    var target: ?usize = null;
    for (old, 0..) |c, i| {
        if (std.mem.eql(u8, c.id, comment_id)) {
            target = i;
            break;
        }
    }
    const ti = target orelse return;

    if (old.len == 1) {
        freeComment(allocator, old[0]);
        allocator.free(old);
        t.comments = &.{};
        return;
    }

    // Allocate the replacement BEFORE freeing anything so a failed alloc leaves
    // the thread untouched.
    const new = try allocator.alloc(review_parse.ReviewComment, old.len - 1);
    var j: usize = 0;
    for (old, 0..) |c, i| {
        if (i == ti) continue;
        new[j] = c;
        j += 1;
    }
    freeComment(allocator, old[ti]);
    allocator.free(old);
    t.comments = new;
}

/// Remove the thread at `idx` (its last comment was deleted), freeing it if owned
/// and shifting `expanded_threads` keys to match the new indexing.
fn removeThreadAt(self: *ReviewSession, allocator: Allocator, idx: usize) void {
    const st = self.threads.orderedRemove(idx);
    if (st.owned) freeOwnedThread(allocator, st);
    shiftExpandedAfterRemoval(self, allocator, idx);
}

/// Rebuild `expanded_threads` after removing the thread at `removed_idx`: drop
/// that key, shift higher keys down by one. On allocation failure the transient
/// expansion state is simply cleared (view state, not review data).
fn shiftExpandedAfterRemoval(self: *ReviewSession, allocator: Allocator, removed_idx: usize) void {
    var kept: std.ArrayList(usize) = .{};
    defer kept.deinit(allocator);
    var it = self.expanded_threads.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        if (k == removed_idx) continue;
        const shifted = if (k > removed_idx) k - 1 else k;
        kept.append(allocator, shifted) catch {
            self.expanded_threads.clearRetainingCapacity();
            return;
        };
    }
    self.expanded_threads.clearRetainingCapacity();
    for (kept.items) |k| self.expanded_threads.put(allocator, k, {}) catch {};
}

// --- Submit / discard helpers ------------------------------------------------

/// A thread that exists only as an unsubmitted draft: an in-flight placeholder,
/// or a server thread whose comments are all still `pending` (mine, not yet
/// submitted). These are the threads a discard removes.
/// Newline-delimited logical line count of `body` (matches how
/// `review_render.drawInfoBody` splits the description on '\n').
fn bodyLineCount(body: []const u8) usize {
    if (body.len == 0) return 0;
    var count: usize = 1;
    for (body) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

fn isDraftThread(st: *const SessionThread) bool {
    if (st.posting) return true;
    const comments = st.data.comments;
    if (comments.len == 0) return false;
    for (comments) |c| {
        if (c.review_state != .pending) return false;
    }
    return true;
}

/// The `ReviewState` a verdict submits into (optimistic post-submit flip).
fn verdictState(verdict: Verdict) review_parse.ReviewState {
    return switch (verdict) {
        .comment => .commented,
        .approve => .approved,
        .request_changes => .changes_requested,
    };
}

/// Copy the submit/discard inputs into `c_allocator` buffers and spawn the
/// worker. Buffers live on `self.submit_mutation` (freed by `pollSubmit` /
/// `deinitState`).
fn spawnSubmit(self: *ReviewSession, kind: SubmitKind, body: []const u8) !void {
    const ca = std.heap.c_allocator;

    const pr_node_id = try ca.dupe(u8, self.pr_node_id);
    errdefer ca.free(pr_node_id);
    const head_oid = try ca.dupe(u8, self.head_ref_oid);
    errdefer ca.free(head_oid);
    const event = try ca.dupe(u8, verdictEvent(self.submit.verdict));
    errdefer ca.free(event);
    const body_buf = try ca.dupe(u8, body);
    errdefer ca.free(body_buf);
    var review_id_buf: ?[]u8 = null;
    if (currentReviewId(self)) |rid| review_id_buf = try ca.dupe(u8, rid);
    errdefer if (review_id_buf) |r| ca.free(r);

    self.submit_mutation.kind = kind;
    self.submit_mutation.in_pr_node_id = pr_node_id;
    self.submit_mutation.in_head_oid = head_oid;
    self.submit_mutation.in_event = event;
    self.submit_mutation.in_body = body_buf;
    self.submit_mutation.in_review_id = review_id_buf;
    self.submit_mutation.verdict = self.submit.verdict;
    self.submit_mutation.out_review_id = null;
    self.submit_mutation.out_error_msg = null;
    self.submit_mutation.failed = false;
    self.submit_mutation.fail_kind = .other;
    self.submit_mutation.ready.store(false, .release);

    self.submit_thread = std.Thread.spawn(.{}, submitWorker, .{self}) catch {
        // Detach the buffers from the struct; the errdefers above free them.
        self.submit_mutation.in_pr_node_id = &.{};
        self.submit_mutation.in_head_oid = &.{};
        self.submit_mutation.in_event = &.{};
        self.submit_mutation.in_body = &.{};
        self.submit_mutation.in_review_id = null;
        return error.SpawnFailed;
    };
    self.submit_in_flight = true;
}

/// Submit/discard worker (AD-3). Runs on `c_allocator`. Submit ensures a pending
/// review (reuse cached id or create one) then calls `submitPullRequestReview`;
/// a 200-with-errors envelope (self-approval etc.) becomes an `out_error_msg`.
/// Discard deletes the pending review. Writes outputs under the mutex, flips
/// `ready`.
fn submitWorker(self: *ReviewSession) void {
    const ca = std.heap.c_allocator;
    const m = &self.submit_mutation;
    var failed = false;
    var fail_kind: github.GhErrorKind = .other;
    var out_review_id: ?[]u8 = null;
    var out_error_msg: ?[]u8 = null;

    if (m.kind == .discard) {
        if (m.in_review_id) |rid| {
            if (github.deletePendingReview(ca, rid)) |fetch| {
                switch (fetch) {
                    .ok => |raw| {
                        defer ca.free(raw);
                        if (review_parse.firstErrorMessage(ca, raw)) |maybe| {
                            if (maybe) |msg| {
                                failed = true;
                                out_error_msg = msg;
                            }
                        } else |_| {}
                    },
                    .failed => |k| {
                        failed = true;
                        fail_kind = k;
                    },
                }
            } else |_| {
                failed = true;
            }
        } else {
            failed = true;
        }
        m.mutex.lock();
        m.out_error_msg = out_error_msg;
        m.failed = failed;
        m.fail_kind = fail_kind;
        m.mutex.unlock();
        m.ready.store(true, .release);
        return;
    }

    // Submit path: resolve a review id first, then submit it.
    const resolved = resolveReviewId(m.in_review_id, m.in_pr_node_id, m.in_head_oid);
    const review_id = resolved.review_id; // ca-owned working copy
    defer if (review_id) |r| ca.free(r);
    out_review_id = resolved.out_review_id;
    failed = resolved.failed;
    fail_kind = resolved.fail_kind;

    if (!failed) {
        if (github.submitReview(ca, review_id.?, m.in_event, m.in_body)) |fetch| {
            switch (fetch) {
                .ok => |raw| {
                    defer ca.free(raw);
                    if (review_parse.parseSubmitReview(ca, raw)) |res| {
                        var r = res;
                        defer r.deinit();
                        if (!r.ok) {
                            failed = true;
                            out_error_msg = ca.dupe(u8, r.error_message) catch null;
                        }
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
    }

    m.mutex.lock();
    m.out_review_id = out_review_id;
    m.out_error_msg = out_error_msg;
    m.failed = failed;
    m.fail_kind = fail_kind;
    m.mutex.unlock();
    m.ready.store(true, .release);
}

/// Apply a successful submit locally: flip every still-`pending` comment to the
/// submitted verdict's state (immediate feedback before the caller's refetch),
/// and drop the now-consumed pending review ids.
fn applySubmitSuccess(self: *ReviewSession, allocator: Allocator, verdict: Verdict) void {
    const new_state = verdictState(verdict);
    for (self.threads.items) |*st| {
        for (st.data.comments) |*c| {
            if (c.review_state == .pending) c.review_state = new_state;
        }
        st.posting = false;
    }
    dropReviewIds(self, allocator);
}

/// Apply a successful discard locally: remove every draft/placeholder thread and
/// drop the pending review ids. Iterates back-to-front so `removeThreadAt`'s
/// index-shift bookkeeping stays correct.
fn applyDiscard(self: *ReviewSession, allocator: Allocator) void {
    var i: usize = self.threads.items.len;
    while (i > 0) {
        i -= 1;
        if (isDraftThread(&self.threads.items[i])) removeThreadAt(self, allocator, i);
    }
    clearQueuedPosts(self, allocator);
    dropReviewIds(self, allocator);
}

/// Free and null both cached pending-review ids.
fn dropReviewIds(self: *ReviewSession, allocator: Allocator) void {
    if (self.pending_review_id) |id| allocator.free(id);
    self.pending_review_id = null;
    if (self.posted_review_id) |id| allocator.free(id);
    self.posted_review_id = null;
}

/// Replace the dialog's error text with an owned copy of `msg`.
fn setSubmitError(self: *ReviewSession, allocator: Allocator, msg: []const u8) void {
    if (self.submit.error_msg) |m| allocator.free(m);
    self.submit.error_msg = allocator.dupe(u8, msg) catch null;
}

/// Clear the dialog's error text.
fn clearSubmitError(self: *ReviewSession, allocator: Allocator) void {
    if (self.submit.error_msg) |m| allocator.free(m);
    self.submit.error_msg = null;
}

/// Close the submit dialog after a successful submit/discard: drop the stashed
/// body (it was submitted or discarded), the error, and the discard arming.
fn closeSubmitDialogSilent(self: *ReviewSession, allocator: Allocator) void {
    if (self.submit.body_stash) |s| allocator.free(s);
    self.submit.body_stash = null;
    self.submit.confirm_discard = false;
    clearSubmitError(self, allocator);
}

/// Free the `c_allocator` buffers held on `self.submit_mutation` and reset them.
fn freeSubmitBuffers(self: *ReviewSession) void {
    const ca = std.heap.c_allocator;
    if (self.submit_mutation.in_pr_node_id.len > 0) ca.free(self.submit_mutation.in_pr_node_id);
    if (self.submit_mutation.in_head_oid.len > 0) ca.free(self.submit_mutation.in_head_oid);
    if (self.submit_mutation.in_event.len > 0) ca.free(self.submit_mutation.in_event);
    if (self.submit_mutation.in_body.len > 0) ca.free(self.submit_mutation.in_body);
    if (self.submit_mutation.in_review_id) |r| ca.free(r);
    if (self.submit_mutation.out_review_id) |r| ca.free(r);
    if (self.submit_mutation.out_error_msg) |r| ca.free(r);
    self.submit_mutation.in_pr_node_id = &.{};
    self.submit_mutation.in_head_oid = &.{};
    self.submit_mutation.in_event = &.{};
    self.submit_mutation.in_body = &.{};
    self.submit_mutation.in_review_id = null;
    self.submit_mutation.out_review_id = null;
    self.submit_mutation.out_error_msg = null;
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

test "infoLineCount: zero when nothing is displayed" {
    var session = ReviewSession{};
    try testing.expectEqual(@as(usize, 0), infoLineCount(&session));
}

test "infoLineCount: description-only counts a header plus each body line" {
    var session = ReviewSession{};
    session.body = "a\nb\nc";
    // 1 header + 3 body lines.
    try testing.expectEqual(@as(usize, 4), infoLineCount(&session));
}

test "infoLineCount: sums checks + reviews + description sections" {
    var session = ReviewSession{};
    defer session.checks.deinit(testing.allocator);
    defer session.reviews.deinit(testing.allocator);

    try session.checks.append(testing.allocator, .{ .name = "build", .status = "COMPLETED", .conclusion = "SUCCESS" });
    try session.checks.append(testing.allocator, .{ .name = "lint", .status = "COMPLETED", .conclusion = "FAILURE" });
    try session.reviews.append(testing.allocator, .{ .id = "R1", .author = "a", .state = .approved, .body = "", .submitted_at = "" });
    session.body = "a\nb\nc";

    // checks: 2 rows + header + spacer = 4; reviews: 1 row + header + spacer = 3;
    // description: 1 header + 3 body lines = 4. Total = 11. This MUST equal the
    // logical lines drawInfoBody renders so `G`/scroll reach the true bottom.
    try testing.expectEqual(@as(usize, 11), infoLineCount(&session));
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

test "peekFailedDraft borrows the body without clearing it" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try testing.expect(peekFailedDraft(&session) == null);

    stashFailedDraft(&session, testing.allocator, "retry me");
    try testing.expectEqualStrings("retry me", peekFailedDraft(&session).?);
    // Peeking again still finds it (not consumed) — a cancelled reply keeps the draft.
    try testing.expectEqualStrings("retry me", peekFailedDraft(&session).?);

    const taken = takeFailedDraft(&session);
    defer if (taken) |t| testing.allocator.free(t);
    try testing.expect(peekFailedDraft(&session) == null);
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

// --- Thread-interaction tests -----------------------------------------------

const reply_fixture =
    \\{"data":{"addPullRequestReviewThreadReply":{"comment":
    \\{"id":"PRRC_reply","databaseId":100,"author":{"login":"ctdio"},"body":"my reply","createdAt":"2025-02-02T00:00:00Z","diffHunk":"@@ -1 +1 @@","pullRequestReview":{"id":"PRR_2","state":"COMMENTED"},"replyTo":{"id":"PRRC_1"}}
    \\}}}
;
const resolve_fixture =
    \\{"data":{"resolveReviewThread":{"thread":{"id":"PRRT_1","isResolved":true}}}}
;
const unresolve_fixture =
    \\{"data":{"unresolveReviewThread":{"thread":{"id":"PRRT_1","isResolved":false}}}}
;
const update_fixture =
    \\{"data":{"updatePullRequestReviewComment":{"pullRequestReviewComment":{"id":"PRRC_1","body":"edited body"}}}}
;
const delete_fixture =
    \\{"data":{"deletePullRequestReviewComment":{"pullRequestReviewComment":{"id":"PRRC_1","databaseId":99}}}}
;

test "applyThreadMutation reply appends the server comment to the thread" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    session.viewer_login = "ctdio";
    try appendOwnedThread(&session, testing.allocator, "PRRT_1", false, &.{.{ .id = "PRRC_1", .mine = true }});

    try applyThreadMutation(&session, testing.allocator, .{ .kind = .reply, .thread_id = "PRRT_1", .comment_id = "", .raw = reply_fixture });

    try testing.expectEqual(@as(usize, 2), session.threads.items[0].data.comments.len);
    try testing.expectEqualStrings("PRRC_reply", session.threads.items[0].data.comments[1].id);
    try testing.expectEqualStrings("my reply", session.threads.items[0].data.comments[1].body);
    try testing.expect(session.threads.items[0].data.comments[1].is_mine);
}

test "applyThreadMutation reply converts a server (non-owned) thread to owned" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    session.viewer_login = "ctdio";

    var comments = [_]review_parse.ReviewComment{.{
        .id = "PRRC_1",
        .database_id = 99,
        .author = "ctdio",
        .body = "orig",
        .created_at = "",
        .review_id = "",
        .review_state = .commented,
        .is_mine = true,
        .diff_hunk = "",
    }};
    try session.threads.append(testing.allocator, .{ .data = .{
        .id = "PRRT_1",
        .path = "src/x.zig",
        .line = 10,
        .start_line = null,
        .original_line = 10,
        .side = .right,
        .start_side = .right,
        .is_resolved = false,
        .is_outdated = false,
        .subject_type = .line,
        .comments = &comments,
    }, .owned = false });

    try applyThreadMutation(&session, testing.allocator, .{ .kind = .reply, .thread_id = "PRRT_1", .comment_id = "", .raw = reply_fixture });

    try testing.expect(session.threads.items[0].owned);
    try testing.expectEqual(@as(usize, 2), session.threads.items[0].data.comments.len);
}

test "applyThreadMutation resolve flips is_resolved and clears the expand override" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try appendOwnedThread(&session, testing.allocator, "PRRT_1", false, &.{.{ .id = "PRRC_1", .mine = true }});
    try session.expanded_threads.put(testing.allocator, 0, {});

    try applyThreadMutation(&session, testing.allocator, .{ .kind = .resolve, .thread_id = "PRRT_1", .comment_id = "", .raw = resolve_fixture });

    try testing.expect(session.threads.items[0].data.is_resolved);
    try testing.expectEqual(@as(usize, 0), session.expanded_threads.count());
}

test "applyThreadMutation unresolve clears is_resolved" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try appendOwnedThread(&session, testing.allocator, "PRRT_1", true, &.{.{ .id = "PRRC_1", .mine = true }});

    try applyThreadMutation(&session, testing.allocator, .{ .kind = .unresolve, .thread_id = "PRRT_1", .comment_id = "", .raw = unresolve_fixture });

    try testing.expect(!session.threads.items[0].data.is_resolved);
}

test "applyThreadMutation edit replaces the comment body" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try appendOwnedThread(&session, testing.allocator, "PRRT_1", false, &.{.{ .id = "PRRC_1", .mine = true }});

    try applyThreadMutation(&session, testing.allocator, .{ .kind = .edit, .thread_id = "PRRT_1", .comment_id = "PRRC_1", .raw = update_fixture });

    try testing.expectEqualStrings("edited body", session.threads.items[0].data.comments[0].body);
}

test "applyThreadMutation delete drops the comment but keeps a multi-comment thread" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try appendOwnedThread(&session, testing.allocator, "PRRT_1", false, &.{
        .{ .id = "PRRC_1", .mine = true },
        .{ .id = "PRRC_2", .mine = false },
    });

    try applyThreadMutation(&session, testing.allocator, .{ .kind = .delete, .thread_id = "PRRT_1", .comment_id = "PRRC_1", .raw = delete_fixture });

    try testing.expectEqual(@as(usize, 1), session.threads.items.len);
    try testing.expectEqual(@as(usize, 1), session.threads.items[0].data.comments.len);
    try testing.expectEqualStrings("PRRC_2", session.threads.items[0].data.comments[0].id);
}

test "applyThreadMutation delete removes the whole thread with its last comment and shifts expansion" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try appendOwnedThread(&session, testing.allocator, "PRRT_1", false, &.{.{ .id = "PRRC_1", .mine = true }});
    try appendOwnedThread(&session, testing.allocator, "PRRT_2", false, &.{.{ .id = "PRRC_9", .mine = false }});
    // Override expansion of the second thread; deleting the first shifts it to 0.
    try session.expanded_threads.put(testing.allocator, 1, {});

    try applyThreadMutation(&session, testing.allocator, .{ .kind = .delete, .thread_id = "PRRT_1", .comment_id = "PRRC_1", .raw = delete_fixture });

    try testing.expectEqual(@as(usize, 1), session.threads.items.len);
    try testing.expectEqualStrings("PRRT_2", session.threads.items[0].data.id);
    try testing.expect(session.expanded_threads.contains(0));
    try testing.expect(!session.expanded_threads.contains(1));
}

test "applyThreadMutation on an unknown thread id is a silent no-op" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    session.viewer_login = "ctdio";

    try applyThreadMutation(&session, testing.allocator, .{ .kind = .reply, .thread_id = "PRRT_missing", .comment_id = "", .raw = reply_fixture });

    try testing.expectEqual(@as(usize, 0), session.threads.items.len);
}

test "lastOwnCommentIdx returns the last viewer-authored comment" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try appendOwnedThread(&session, testing.allocator, "PRRT_1", false, &.{
        .{ .id = "c0", .mine = false },
        .{ .id = "c1", .mine = true },
        .{ .id = "c2", .mine = false },
        .{ .id = "c3", .mine = true },
    });
    try testing.expectEqual(@as(?usize, 3), lastOwnCommentIdx(&session.threads.items[0]));
}

test "lastOwnCommentIdx returns null when the viewer owns no comment" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try appendOwnedThread(&session, testing.allocator, "PRRT_1", false, &.{
        .{ .id = "c0", .mine = false },
        .{ .id = "c1", .mine = false },
    });
    try testing.expectEqual(@as(?usize, null), lastOwnCommentIdx(&session.threads.items[0]));
}

test "delete confirm arms with a thread id, reports it, and disarms" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try testing.expect(deleteConfirmArmed(&session) == null);
    armDeleteConfirm(&session, testing.allocator, "PRRT_9");
    try testing.expectEqualStrings("PRRT_9", deleteConfirmArmed(&session).?);
    disarmDeleteConfirm(&session, testing.allocator);
    try testing.expect(deleteConfirmArmed(&session) == null);
}

test "delete confirm survives a concurrent delete-last on an earlier thread without redirecting" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    // Threads A (idx 0) and B (idx 1); the viewer arms delete on B.
    try appendOwnedThread(&session, testing.allocator, "PRRT_A", false, &.{.{ .id = "PRRC_A", .mine = true }});
    try appendOwnedThread(&session, testing.allocator, "PRRT_B", false, &.{.{ .id = "PRRC_B", .mine = true }});
    armDeleteConfirm(&session, testing.allocator, "PRRT_B");

    // A concurrent delete-last on A (idx 0) removes it and shifts B down to idx 0.
    try applyThreadMutation(&session, testing.allocator, .{ .kind = .delete, .thread_id = "PRRT_A", .comment_id = "PRRC_A", .raw = delete_fixture });
    try testing.expectEqual(@as(usize, 1), session.threads.items.len);

    // The armed id still resolves to B (now at idx 0) — never a neighbour.
    const armed = deleteConfirmArmed(&session).?;
    try testing.expectEqualStrings("PRRT_B", armed);
    try testing.expectEqual(@as(?usize, 0), threadIdxById(&session, armed));
}

test "delete confirm is cleared when the armed thread itself is removed" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try appendOwnedThread(&session, testing.allocator, "PRRT_A", false, &.{.{ .id = "PRRC_A", .mine = true }});
    try appendOwnedThread(&session, testing.allocator, "PRRT_B", false, &.{.{ .id = "PRRC_B", .mine = true }});
    armDeleteConfirm(&session, testing.allocator, "PRRT_B");

    // Delete-last on B removes B; the armed id no longer resolves, so a fire refuses.
    try applyThreadMutation(&session, testing.allocator, .{ .kind = .delete, .thread_id = "PRRT_B", .comment_id = "PRRC_B", .raw = delete_fixture });
    const armed = deleteConfirmArmed(&session).?;
    try testing.expect(threadIdxById(&session, armed) == null);
}

test "isThreadBusy reflects the busy flag and is false out of range" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try appendOwnedThread(&session, testing.allocator, "PRRT_1", false, &.{.{ .id = "PRRC_1", .mine = true }});
    try testing.expect(!isThreadBusy(&session, 0));
    session.threads.items[0].busy = true;
    try testing.expect(isThreadBusy(&session, 0));
    try testing.expect(!isThreadBusy(&session, 5));
}

test "startReply refuses a second action while the thread is busy" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try appendOwnedThread(&session, testing.allocator, "PRRT_1", false, &.{.{ .id = "PRRC_1", .mine = true }});
    session.threads.items[0].busy = true;
    try testing.expect(!try startReply(&session, testing.allocator, 0, "reply"));
}

test "startReply refuses an unposted placeholder" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    session.active = true;
    const seq = try appendPlaceholder(&session, testing.allocator, samplePost("draft"));
    _ = seq;
    try testing.expect(!try startReply(&session, testing.allocator, 0, "reply"));
}

test "startToggleResolve queues an unresolve when the thread is resolved" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try appendOwnedThread(&session, testing.allocator, "PRRT_1", true, &.{.{ .id = "PRRC_1", .mine = true }});
    // Simulate an in-flight worker so beginThreadMutation enqueues (no real IO).
    session.thread_mut_active = true;

    try testing.expect(try startToggleResolve(&session, testing.allocator, 0));
    try testing.expectEqual(@as(usize, 1), session.queued_thread_mutations.items.len);
    try testing.expectEqual(ThreadMutationKind.unresolve, session.queued_thread_mutations.items[0].kind);
    try testing.expect(session.threads.items[0].busy);

    session.thread_mut_active = false; // no worker to join in deinit
}

test "startReply queues behind an in-flight mutation with its body" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try appendOwnedThread(&session, testing.allocator, "PRRT_1", false, &.{.{ .id = "PRRC_1", .mine = true }});
    session.thread_mut_active = true;

    try testing.expect(try startReply(&session, testing.allocator, 0, "queued reply"));
    try testing.expectEqual(ThreadMutationKind.reply, session.queued_thread_mutations.items[0].kind);
    try testing.expectEqualStrings("queued reply", session.queued_thread_mutations.items[0].body);
    try testing.expectEqualStrings("PRRT_1", session.queued_thread_mutations.items[0].thread_id);

    session.thread_mut_active = false;
}

test "pollThreadMutations: none when nothing is ready" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try testing.expect(pollThreadMutations(&session, testing.allocator) == .none);
}

test "pollThreadMutations applies a ready reply and clears busy" {
    const ca = std.heap.c_allocator;
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    session.viewer_login = "ctdio";
    try appendOwnedThread(&session, testing.allocator, "PRRT_1", false, &.{.{ .id = "PRRC_1", .mine = true }});
    session.threads.items[0].busy = true;

    // Simulate a completed worker (no real gh / thread spawned).
    session.thread_mutation.kind = .reply;
    session.thread_mutation.in_thread_id = try ca.dupe(u8, "PRRT_1");
    session.thread_mutation.in_comment_id = try ca.dupe(u8, "");
    session.thread_mutation.in_body = try ca.dupe(u8, "my reply");
    session.thread_mutation.out_raw = try ca.dupe(u8, reply_fixture);
    session.thread_mut_active = true;
    session.thread_mutation.ready.store(true, .release);

    const outcome = pollThreadMutations(&session, testing.allocator);
    try testing.expect(outcome == .applied);
    try testing.expectEqual(ThreadMutationKind.reply, outcome.applied);
    try testing.expectEqual(@as(usize, 2), session.threads.items[0].data.comments.len);
    try testing.expect(!session.threads.items[0].busy);
}

test "pollThreadMutations stashes the body and clears busy on a failed reply" {
    const ca = std.heap.c_allocator;
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try appendOwnedThread(&session, testing.allocator, "PRRT_1", false, &.{.{ .id = "PRRC_1", .mine = true }});
    session.threads.items[0].busy = true;

    session.thread_mutation.kind = .reply;
    session.thread_mutation.in_thread_id = try ca.dupe(u8, "PRRT_1");
    session.thread_mutation.in_comment_id = try ca.dupe(u8, "");
    session.thread_mutation.in_body = try ca.dupe(u8, "draft reply");
    session.thread_mutation.failed = true;
    session.thread_mutation.fail_kind = .network;
    session.thread_mut_active = true;
    session.thread_mutation.ready.store(true, .release);

    const outcome = pollThreadMutations(&session, testing.allocator);
    try testing.expect(outcome == .failed);
    try testing.expectEqual(github.GhErrorKind.network, outcome.failed.err);
    try testing.expect(!session.threads.items[0].busy);

    const stashed = takeFailedDraft(&session);
    defer if (stashed) |t| testing.allocator.free(t);
    try testing.expectEqualStrings("draft reply", stashed.?);
}

test "verdictEvent: maps each verdict to its PullRequestReviewEvent" {
    try testing.expectEqualStrings("COMMENT", verdictEvent(.comment));
    try testing.expectEqualStrings("APPROVE", verdictEvent(.approve));
    try testing.expectEqualStrings("REQUEST_CHANGES", verdictEvent(.request_changes));
}

test "verdictLabel: maps each verdict to its human label" {
    try testing.expectEqualStrings("Comment", verdictLabel(.comment));
    try testing.expectEqualStrings("Approve", verdictLabel(.approve));
    try testing.expectEqualStrings("Request changes", verdictLabel(.request_changes));
}

test "cycleVerdict: forward wraps comment -> approve -> request_changes -> comment" {
    var session = ReviewSession{};
    try testing.expectEqual(Verdict.comment, session.submit.verdict);
    cycleVerdict(&session, true);
    try testing.expectEqual(Verdict.approve, session.submit.verdict);
    cycleVerdict(&session, true);
    try testing.expectEqual(Verdict.request_changes, session.submit.verdict);
    cycleVerdict(&session, true);
    try testing.expectEqual(Verdict.comment, session.submit.verdict);
}

test "cycleVerdict: backward wraps comment -> request_changes" {
    var session = ReviewSession{};
    cycleVerdict(&session, false);
    try testing.expectEqual(Verdict.request_changes, session.submit.verdict);
    cycleVerdict(&session, false);
    try testing.expectEqual(Verdict.approve, session.submit.verdict);
}

test "submitGuard: refuses when no session is active" {
    var session = ReviewSession{};
    try testing.expectEqual(SubmitAction.refused_no_review, submitGuard(&session, "body").?);
}

test "submitGuard: refuses empty-body COMMENT with no drafts" {
    var session = ReviewSession{};
    session.active = true;
    session.submit.verdict = .comment;
    try testing.expectEqual(SubmitAction.refused_empty, submitGuard(&session, "   \n").?);
}

test "submitGuard: allows empty-body APPROVE with no drafts" {
    var session = ReviewSession{};
    session.active = true;
    session.submit.verdict = .approve;
    try testing.expect(submitGuard(&session, "") == null);
}

test "submitGuard: allows empty-body COMMENT when a draft exists" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    session.active = true;
    session.submit.verdict = .comment;
    try appendOwnedThread(&session, testing.allocator, "PRRT_draft", false, &.{
        .{ .id = "PRRC_d", .mine = true, .state = .pending },
    });
    try testing.expect(submitGuard(&session, "") == null);
}

test "submitGuard: refuses while a submit is in flight" {
    var session = ReviewSession{};
    session.active = true;
    session.submit.verdict = .approve;
    session.submit_in_flight = true;
    try testing.expectEqual(SubmitAction.busy, submitGuard(&session, "body").?);
}

test "startDiscard: refuses when there is no pending review" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    session.active = true;
    const action = try startDiscard(&session, testing.allocator);
    try testing.expectEqual(SubmitAction.refused_no_review, action);
}

test "submitGuard: refuses while an inline draft post is still in flight" {
    var session = ReviewSession{};
    session.active = true;
    session.submit.verdict = .approve;
    session.posting_worker_active = true; // a post worker is mid-createPendingReview
    try testing.expectEqual(SubmitAction.busy, submitGuard(&session, "body").?);
    session.posting_worker_active = false; // avoid deinit joining a nonexistent worker
}

test "startDiscard: refuses (busy) while an inline draft post is still in flight" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    session.active = true;
    // A pending review exists (discard would otherwise proceed) but a post is
    // mid-flight — discard must refuse rather than race the create/delete.
    session.pending_review_id = try testing.allocator.dupe(u8, "PRR_pending");
    session.posting_worker_active = true;
    const action = try startDiscard(&session, testing.allocator);
    try testing.expectEqual(SubmitAction.busy, action);
    session.posting_worker_active = false;
}

test "threadCounts: counts unresolved and total over server threads, excluding drafts" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    try appendOwnedThread(&session, testing.allocator, "PRRT_a", false, &.{
        .{ .id = "c1", .mine = false, .state = .commented },
    });
    try appendOwnedThread(&session, testing.allocator, "PRRT_b", true, &.{
        .{ .id = "c2", .mine = false, .state = .commented },
    });
    try appendOwnedThread(&session, testing.allocator, "PRRT_draft", false, &.{
        .{ .id = "c3", .mine = true, .state = .pending },
    });
    const counts = threadCounts(&session);
    try testing.expectEqual(@as(usize, 2), counts.total);
    try testing.expectEqual(@as(usize, 1), counts.unresolved);
}

test "applySubmitSuccess: flips pending comments to the verdict state and drops review ids" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    session.pending_review_id = try testing.allocator.dupe(u8, "PRR_pending");
    try appendOwnedThread(&session, testing.allocator, "PRRT_a", false, &.{
        .{ .id = "c1", .mine = true, .state = .pending },
    });

    applySubmitSuccess(&session, testing.allocator, .approve);

    try testing.expectEqual(review_parse.ReviewState.approved, session.threads.items[0].data.comments[0].review_state);
    try testing.expect(session.pending_review_id == null);
    try testing.expect(session.posted_review_id == null);
}

test "applyDiscard: removes draft threads but keeps submitted ones" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);
    session.pending_review_id = try testing.allocator.dupe(u8, "PRR_pending");
    try appendOwnedThread(&session, testing.allocator, "PRRT_submitted", false, &.{
        .{ .id = "c1", .mine = false, .state = .commented },
    });
    try appendOwnedThread(&session, testing.allocator, "PRRT_draft", false, &.{
        .{ .id = "c2", .mine = true, .state = .pending },
    });

    applyDiscard(&session, testing.allocator);

    try testing.expectEqual(@as(usize, 1), session.threads.items.len);
    try testing.expectEqualStrings("PRRT_submitted", session.threads.items[0].data.id);
    try testing.expect(session.pending_review_id == null);
}

test "stashSubmitBody: round-trips a body and an empty body clears it" {
    var session = ReviewSession{};
    defer deinitState(&session, testing.allocator);

    stashSubmitBody(&session, testing.allocator, "half-written review");
    try testing.expectEqualStrings("half-written review", submitBodyStash(&session).?);

    stashSubmitBody(&session, testing.allocator, "   ");
    try testing.expect(submitBodyStash(&session) == null);
}

test "discard confirm: arm then disarm toggles the flag" {
    var session = ReviewSession{};
    try testing.expect(!discardArmed(&session));
    armDiscardConfirm(&session);
    try testing.expect(discardArmed(&session));
    disarmDiscardConfirm(&session);
    try testing.expect(!discardArmed(&session));
}

fn samplePost(body: []const u8) PostParams {
    return .{ .path = "src/x.zig", .line = 10, .side = .right, .body = body };
}

const CommentSeed = struct { id: []const u8, mine: bool, body: []const u8 = "orig", state: review_parse.ReviewState = .commented };

/// Append a fully session-owned thread for tests (so `deinitState` frees it and
/// the testing allocator leak-checks it).
fn appendOwnedThread(session: *ReviewSession, allocator: Allocator, id: []const u8, is_resolved: bool, seeds: []const CommentSeed) !void {
    const arr = try allocator.alloc(review_parse.ReviewComment, seeds.len);
    for (seeds, 0..) |s, i| {
        arr[i] = .{
            .id = try allocator.dupe(u8, s.id),
            .database_id = 0,
            .author = try allocator.dupe(u8, "ctdio"),
            .body = try allocator.dupe(u8, s.body),
            .created_at = try allocator.dupe(u8, ""),
            .review_id = try allocator.dupe(u8, ""),
            .review_state = s.state,
            .is_mine = s.mine,
            .diff_hunk = try allocator.dupe(u8, ""),
        };
    }
    try session.threads.append(allocator, .{ .data = .{
        .id = try allocator.dupe(u8, id),
        .path = try allocator.dupe(u8, "src/x.zig"),
        .line = 10,
        .start_line = null,
        .original_line = 10,
        .side = .right,
        .start_side = .right,
        .is_resolved = is_resolved,
        .is_outdated = false,
        .subject_type = .line,
        .comments = arr,
    }, .owned = true });
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
