//! Pure parsing of the GitHub PR review GraphQL payload (as emitted by
//! `gh api graphql` for the Phase 1 query) into review domain types. No IO —
//! bytes in, arena-owned data out — so it is trivially unit-testable against
//! captured payloads. Mirrors `parse.zig`: unknown enum strings degrade to
//! safe defaults (GitHub adds enum values over time) rather than erroring.

const std = @import("std");

pub const Side = enum { left, right };

pub const ReviewState = enum { pending, commented, approved, changes_requested, dismissed, unknown };

pub const SubjectType = enum { line, file };

pub const RollupState = enum { success, failure, pending, err, none };

pub const ReviewComment = struct {
    id: []const u8, // PRRC_* node id (stable identity)
    database_id: u64,
    author: []const u8,
    body: []const u8,
    created_at: []const u8,
    review_id: []const u8, // PRR_*
    review_state: ReviewState, // .pending => draft
    is_mine: bool, // author == viewer login (computed at parse time)
    diff_hunk: []const u8, // GitHub's diffHunk; last line = the commented line.
};

pub const ReviewThread = struct {
    id: []const u8, // PRRT_*
    path: []const u8,
    line: ?u32, // null when outdated
    start_line: ?u32,
    original_line: ?u32,
    side: Side,
    start_side: Side,
    is_resolved: bool,
    is_outdated: bool,
    subject_type: SubjectType,
    comments: []ReviewComment,
};

pub const Review = struct {
    id: []const u8,
    author: []const u8,
    state: ReviewState,
    body: []const u8,
    submitted_at: []const u8,
};

pub const CheckRun = struct {
    name: []const u8,
    status: []const u8,
    conclusion: []const u8,
};

pub const PrDetails = struct {
    pr_node_id: []const u8, // for mutations
    number: u32,
    title: []const u8,
    body: []const u8,
    author: []const u8,
    is_draft: bool,
    base_ref: []const u8,
    head_ref: []const u8,
    head_ref_oid: []const u8, // commitOID for pending-review creation
    review_decision: []const u8,
    rollup: RollupState,
    checks: []CheckRun,
    reviews: []Review,
    threads: []ReviewThread,
    viewer_login: []const u8,
    pending_review_id: ?[]const u8, // viewer's PENDING review, if any
    truncated: bool, // any pageInfo.hasNextPage (AD-9)
};

/// Owns the parsed details and the arena backing all of their strings/slices.
/// Free with `deinit`.
pub const PrReviewData = struct {
    arena: std.heap.ArenaAllocator,
    details: PrDetails,

    pub fn deinit(self: *PrReviewData) void {
        self.arena.deinit();
    }
};

/// Parse the GraphQL JSON for a single PR into `PrDetails`. Errors only on
/// structurally-broken payloads (invalid JSON, no `data.repository.pullRequest`);
/// unknown enums / missing scalar fields degrade to safe defaults.
pub fn parsePrDetails(allocator: std.mem.Allocator, json_bytes: []const u8) !PrReviewData {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidPayload;
    const data = objField(parsed.value.object, "data") orelse return error.InvalidPayload;
    const repository = objField(data, "repository") orelse return error.InvalidPayload;
    const pull_request = objField(repository, "pullRequest") orelse return error.InvalidPayload;

    const viewer_login = blk: {
        const viewer = objField(data, "viewer") orelse break :blk "";
        break :blk strField(viewer, "login") orelse "";
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var truncated = false;

    const checks = try parseChecks(a, pull_request, &truncated);
    const reviews = try parseReviews(a, pull_request, &truncated);
    const threads = try parseThreads(a, pull_request, viewer_login, &truncated);
    const pending_review_id = pendingReviewId(reviews, viewer_login);

    const details = PrDetails{
        .pr_node_id = try dupe(a, strField(pull_request, "id") orelse ""),
        .number = u32Field(pull_request, "number"),
        .title = try dupe(a, strField(pull_request, "title") orelse ""),
        .body = try dupe(a, strField(pull_request, "body") orelse ""),
        .author = try dupe(a, loginField(pull_request, "author")),
        .is_draft = boolField(pull_request, "isDraft"),
        .base_ref = try dupe(a, strField(pull_request, "baseRefName") orelse ""),
        .head_ref = try dupe(a, strField(pull_request, "headRefName") orelse ""),
        .head_ref_oid = try dupe(a, strField(pull_request, "headRefOid") orelse ""),
        .review_decision = try dupe(a, strField(pull_request, "reviewDecision") orelse ""),
        .rollup = parseRollup(pull_request),
        .checks = checks,
        .reviews = reviews,
        .threads = threads,
        .viewer_login = try dupe(a, viewer_login),
        .pending_review_id = if (pending_review_id) |id| try dupe(a, id) else null,
        .truncated = truncated,
    };

    return .{ .arena = arena, .details = details };
}

/// Minimal metadata from a `gh pr view --json ...` payload (a single object,
/// not the GraphQL `data.repository.pullRequest` envelope). Used to resolve
/// `base_ref` for number-only entry before the git ref fetch.
pub const PrViewMeta = struct {
    arena: std.heap.ArenaAllocator,
    number: u32,
    title: []const u8,
    base_ref: []const u8,
    head_ref: []const u8,
    url: []const u8,
    is_draft: bool,

    pub fn deinit(self: *PrViewMeta) void {
        self.arena.deinit();
    }
};

/// Extract the created review id from an `addPullRequestReview` mutation
/// response. Detects the `{"errors":[...]}` envelope (present even alongside
/// `data`) before reading. Returned bytes are owned by `allocator`.
pub fn parseCreatedReviewId(allocator: std.mem.Allocator, json_bytes: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    // Pure layer: surface the GraphQL error as a distinct error; the IO/controller
    // shell logs (mirrors `parse.zig`, which never logs).
    if (graphqlErrorMessage(parsed.value) != null) return error.GraphqlError;
    const data = objField(parsed.value.object, "data") orelse return error.InvalidPayload;
    const add = objField(data, "addPullRequestReview") orelse return error.InvalidPayload;
    const review = objField(add, "pullRequestReview") orelse return error.MissingReviewId;
    const id = strField(review, "id") orelse return error.MissingReviewId;
    if (id.len == 0) return error.MissingReviewId;
    return allocator.dupe(u8, id);
}

/// Owns a single `ReviewThread` parsed from an `addPullRequestReviewThread`
/// mutation response, plus the arena backing its strings. Free with `deinit`.
pub const CreatedThread = struct {
    arena: std.heap.ArenaAllocator,
    thread: ReviewThread,

    pub fn deinit(self: *CreatedThread) void {
        self.arena.deinit();
    }
};

/// Parse the `thread` node from an `addPullRequestReviewThread` response into a
/// `ReviewThread`, reusing the SAME node parser as the fetch path (the mutation
/// selection byte-mirrors the fetch query's thread nodes). Two distinct failure
/// shapes GitHub returns from a bad write are handled explicitly: the
/// `{"errors":[...]}` envelope (→ `error.GraphqlError`) and a `thread: null`
/// with no errors (a bad path — → `error.ThreadCreationFailed`).
pub fn parseCreatedThread(allocator: std.mem.Allocator, json_bytes: []const u8, viewer_login: []const u8) !CreatedThread {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    if (graphqlErrorMessage(parsed.value) != null) return error.GraphqlError;
    const data = objField(parsed.value.object, "data") orelse return error.InvalidPayload;
    const add = objField(data, "addPullRequestReviewThread") orelse return error.InvalidPayload;
    // A bad path yields `thread: null` (JSON null / absent) with no errors
    // envelope — objField returns null for both, so this is the failure branch.
    const node = objField(add, "thread") orelse return error.ThreadCreationFailed;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var truncated = false;
    const thread = try parseThreadNode(arena.allocator(), node, viewer_login, &truncated);
    return .{ .arena = arena, .thread = thread };
}

/// Owns a single `ReviewComment` parsed from an `addPullRequestReviewThreadReply`
/// mutation response, plus the arena backing its strings. Free with `deinit`.
pub const CreatedComment = struct {
    arena: std.heap.ArenaAllocator,
    comment: ReviewComment,

    pub fn deinit(self: *CreatedComment) void {
        self.arena.deinit();
    }
};

/// Parse the `comment` node from an `addPullRequestReviewThreadReply` response
/// into a `ReviewComment`, reusing the SAME comment-node parser as the fetch path
/// (the mutation selection byte-mirrors the fetch query's comment nodes). Detects
/// the GraphQL `{"errors":[...]}` envelope and a null `comment`.
pub fn parseCreatedComment(allocator: std.mem.Allocator, json_bytes: []const u8, viewer_login: []const u8) !CreatedComment {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    if (graphqlErrorMessage(parsed.value) != null) return error.GraphqlError;
    const data = objField(parsed.value.object, "data") orelse return error.InvalidPayload;
    const reply = objField(data, "addPullRequestReviewThreadReply") orelse return error.InvalidPayload;
    const node = objField(reply, "comment") orelse return error.ReplyFailed;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const comment = try parseCommentNode(arena.allocator(), node, viewer_login);
    return .{ .arena = arena, .comment = comment };
}

/// Result of a resolve/unresolve mutation: the thread id and its new resolved
/// state. Handles both `resolveReviewThread` and `unresolveReviewThread` keys.
pub const ResolveResult = struct {
    arena: std.heap.ArenaAllocator,
    thread_id: []const u8,
    is_resolved: bool,

    pub fn deinit(self: *ResolveResult) void {
        self.arena.deinit();
    }
};

pub fn parseResolveResult(allocator: std.mem.Allocator, json_bytes: []const u8) !ResolveResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    if (graphqlErrorMessage(parsed.value) != null) return error.GraphqlError;
    const data = objField(parsed.value.object, "data") orelse return error.InvalidPayload;
    const mutation = objField(data, "resolveReviewThread") orelse
        objField(data, "unresolveReviewThread") orelse return error.InvalidPayload;
    const thread = objField(mutation, "thread") orelse return error.ResolveFailed;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    // Allocate BEFORE the return literal: the literal copies `arena` by value, so
    // its state must already reflect the dupe (mirrors parsePrView).
    const thread_id = try dupe(arena.allocator(), strField(thread, "id") orelse "");
    const is_resolved = boolField(thread, "isResolved");
    return .{ .arena = arena, .thread_id = thread_id, .is_resolved = is_resolved };
}

/// Result of an `updatePullRequestReviewComment` mutation: the comment id and its
/// new body. Both are arena-owned; free with `deinit`.
pub const UpdatedComment = struct {
    arena: std.heap.ArenaAllocator,
    id: []const u8,
    body: []const u8,

    pub fn deinit(self: *UpdatedComment) void {
        self.arena.deinit();
    }
};

pub fn parseUpdatedComment(allocator: std.mem.Allocator, json_bytes: []const u8) !UpdatedComment {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    if (graphqlErrorMessage(parsed.value) != null) return error.GraphqlError;
    const data = objField(parsed.value.object, "data") orelse return error.InvalidPayload;
    const update = objField(data, "updatePullRequestReviewComment") orelse return error.InvalidPayload;
    const comment = objField(update, "pullRequestReviewComment") orelse return error.UpdateFailed;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const id = try dupe(a, strField(comment, "id") orelse "");
    const body = try dupe(a, strField(comment, "body") orelse "");
    return .{ .arena = arena, .id = id, .body = body };
}

/// Confirm a `deletePullRequestReviewComment` mutation succeeded and return the
/// echoed comment id (owned by `allocator`). The id to remove locally comes from
/// the mutation record, not this response — this call only validates success.
pub fn parseDeletedComment(allocator: std.mem.Allocator, json_bytes: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    if (graphqlErrorMessage(parsed.value) != null) return error.GraphqlError;
    const data = objField(parsed.value.object, "data") orelse return error.InvalidPayload;
    const del = objField(data, "deletePullRequestReviewComment") orelse return error.InvalidPayload;
    const comment = objField(del, "pullRequestReviewComment") orelse return error.DeleteFailed;
    const id = strField(comment, "id") orelse return error.DeleteFailed;
    return allocator.dupe(u8, id);
}

pub fn parsePrView(allocator: std.mem.Allocator, json_bytes: []const u8) !PrViewMeta {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    const obj = parsed.value.object;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Allocate every string BEFORE the return literal: the literal copies
    // `arena` by value, so its state must already reflect these allocations.
    const title = try dupe(a, strField(obj, "title") orelse "");
    const base_ref = try dupe(a, strField(obj, "baseRefName") orelse "");
    const head_ref = try dupe(a, strField(obj, "headRefName") orelse "");
    const url = try dupe(a, strField(obj, "url") orelse "");

    return .{
        .arena = arena,
        .number = u32Field(obj, "number"),
        .title = title,
        .base_ref = base_ref,
        .head_ref = head_ref,
        .url = url,
        .is_draft = boolField(obj, "isDraft"),
    };
}

// =============================================================================
// Helpers
// =============================================================================

fn parseRollup(pull_request: std.json.ObjectMap) RollupState {
    const rollup = objField(pull_request, "statusCheckRollup") orelse return .none;
    const state = strField(rollup, "state") orelse return .none;
    return rollupFromState(state);
}

fn rollupFromState(state: []const u8) RollupState {
    if (std.mem.eql(u8, state, "SUCCESS")) return .success;
    if (std.mem.eql(u8, state, "FAILURE")) return .failure;
    if (std.mem.eql(u8, state, "ERROR")) return .err;
    if (std.mem.eql(u8, state, "PENDING") or std.mem.eql(u8, state, "EXPECTED")) return .pending;
    return .none;
}

/// Checks come from the head commit's rollup contexts, which interleave
/// `CheckRun` (name/status/conclusion) and legacy `StatusContext`
/// (context/state) nodes. Both collapse into `CheckRun`.
fn parseChecks(a: std.mem.Allocator, pull_request: std.json.ObjectMap, truncated: *bool) ![]CheckRun {
    const commits = objField(pull_request, "commits") orelse return &.{};
    const commit_nodes = arrField(commits, "nodes") orelse return &.{};
    if (commit_nodes.len == 0) return &.{};
    const commit = objValue(commit_nodes[0], "commit") orelse return &.{};
    const rollup = objField(commit, "statusCheckRollup") orelse return &.{};
    const contexts = objField(rollup, "contexts") orelse return &.{};

    if (pageHasNext(contexts)) truncated.* = true;

    const nodes = arrField(contexts, "nodes") orelse return &.{};
    var list = try a.alloc(CheckRun, nodes.len);
    var count: usize = 0;
    for (nodes) |node| {
        if (node != .object) continue;
        const obj = node.object;
        const typename = strField(obj, "__typename") orelse "";
        if (std.mem.eql(u8, typename, "StatusContext")) {
            const state = strField(obj, "state") orelse "";
            list[count] = .{
                .name = try dupe(a, strField(obj, "context") orelse ""),
                .status = try dupe(a, state),
                .conclusion = try dupe(a, state),
            };
        } else {
            list[count] = .{
                .name = try dupe(a, strField(obj, "name") orelse ""),
                .status = try dupe(a, strField(obj, "status") orelse ""),
                .conclusion = try dupe(a, strField(obj, "conclusion") orelse ""),
            };
        }
        count += 1;
    }
    return list[0..count];
}

fn parseReviews(a: std.mem.Allocator, pull_request: std.json.ObjectMap, truncated: *bool) ![]Review {
    const reviews = objField(pull_request, "reviews") orelse return &.{};
    if (pageHasNext(reviews)) truncated.* = true;
    const nodes = arrField(reviews, "nodes") orelse return &.{};

    var list = try a.alloc(Review, nodes.len);
    var count: usize = 0;
    for (nodes) |node| {
        if (node != .object) continue;
        const obj = node.object;
        list[count] = .{
            .id = try dupe(a, strField(obj, "id") orelse ""),
            .author = try dupe(a, loginField(obj, "author")),
            .state = reviewStateFrom(strField(obj, "state") orelse ""),
            .body = try dupe(a, strField(obj, "body") orelse ""),
            .submitted_at = try dupe(a, strField(obj, "submittedAt") orelse ""),
        };
        count += 1;
    }
    return list[0..count];
}

fn parseThreads(a: std.mem.Allocator, pull_request: std.json.ObjectMap, viewer_login: []const u8, truncated: *bool) ![]ReviewThread {
    const review_threads = objField(pull_request, "reviewThreads") orelse return &.{};
    if (pageHasNext(review_threads)) truncated.* = true;
    const nodes = arrField(review_threads, "nodes") orelse return &.{};

    var list = try a.alloc(ReviewThread, nodes.len);
    var count: usize = 0;
    for (nodes) |node| {
        if (node != .object) continue;
        list[count] = try parseThreadNode(a, node.object, viewer_login, truncated);
        count += 1;
    }
    return list[0..count];
}

/// Parse one `reviewThreads.nodes[*]` object (or the byte-identical
/// `addPullRequestReviewThread.thread` node) into a `ReviewThread`. The single
/// source of truth for thread-node shape, shared by the fetch and mutation paths.
fn parseThreadNode(a: std.mem.Allocator, obj: std.json.ObjectMap, viewer_login: []const u8, truncated: *bool) !ReviewThread {
    return .{
        .id = try dupe(a, strField(obj, "id") orelse ""),
        .path = try dupe(a, strField(obj, "path") orelse ""),
        .line = optU32Field(obj, "line"),
        .start_line = optU32Field(obj, "startLine"),
        .original_line = optU32Field(obj, "originalLine"),
        .side = sideFrom(strField(obj, "diffSide") orelse ""),
        .start_side = sideFrom(strField(obj, "startDiffSide") orelse ""),
        .is_resolved = boolField(obj, "isResolved"),
        .is_outdated = boolField(obj, "isOutdated"),
        .subject_type = subjectTypeFrom(strField(obj, "subjectType") orelse ""),
        .comments = try parseComments(a, obj, viewer_login, truncated),
    };
}

/// If `root` carries a non-empty GraphQL `errors` array, return the first
/// error's message. GitHub returns HTTP 200 with `{"errors":[...], "data":…}`
/// for write failures like a duplicate pending review, so callers must check
/// this even when `data` is present.
fn graphqlErrorMessage(root: std.json.Value) ?[]const u8 {
    if (root != .object) return null;
    const errors = root.object.get("errors") orelse return null;
    if (errors != .array or errors.array.items.len == 0) return null;
    const first = errors.array.items[0];
    if (first != .object) return "GraphQL error";
    const msg = first.object.get("message") orelse return "GraphQL error";
    if (msg != .string) return "GraphQL error";
    return msg.string;
}

fn parseComments(a: std.mem.Allocator, thread: std.json.ObjectMap, viewer_login: []const u8, truncated: *bool) ![]ReviewComment {
    const comments = objField(thread, "comments") orelse return &.{};
    if (pageHasNext(comments)) truncated.* = true;
    const nodes = arrField(comments, "nodes") orelse return &.{};

    var list = try a.alloc(ReviewComment, nodes.len);
    var count: usize = 0;
    for (nodes) |node| {
        if (node != .object) continue;
        list[count] = try parseCommentNode(a, node.object, viewer_login);
        count += 1;
    }
    return list[0..count];
}

/// Parse one comment node (a `comments.nodes[*]` object, or the byte-identical
/// `comment` node returned by `addPullRequestReviewThreadReply`) into a
/// `ReviewComment`. The single source of truth for comment-node shape, shared by
/// the fetch path and the reply mutation path.
fn parseCommentNode(a: std.mem.Allocator, obj: std.json.ObjectMap, viewer_login: []const u8) !ReviewComment {
    const author = loginField(obj, "author");
    const review = objField(obj, "pullRequestReview");
    return .{
        .id = try dupe(a, strField(obj, "id") orelse ""),
        .database_id = u64Field(obj, "databaseId"),
        .author = try dupe(a, author),
        .body = try dupe(a, strField(obj, "body") orelse ""),
        .created_at = try dupe(a, strField(obj, "createdAt") orelse ""),
        .review_id = try dupe(a, if (review) |r| strField(r, "id") orelse "" else ""),
        .review_state = reviewStateFrom(if (review) |r| strField(r, "state") orelse "" else ""),
        .is_mine = viewer_login.len > 0 and std.mem.eql(u8, author, viewer_login),
        .diff_hunk = try dupe(a, strField(obj, "diffHunk") orelse ""),
    };
}

/// GitHub only ever exposes the viewer's own PENDING review, but match author
/// too so a future multi-review payload can't misattribute a draft.
fn pendingReviewId(reviews: []const Review, viewer_login: []const u8) ?[]const u8 {
    for (reviews) |review| {
        if (review.state != .pending) continue;
        if (viewer_login.len > 0 and !std.mem.eql(u8, review.author, viewer_login)) continue;
        return review.id;
    }
    return null;
}

fn reviewStateFrom(state: []const u8) ReviewState {
    if (std.mem.eql(u8, state, "PENDING")) return .pending;
    if (std.mem.eql(u8, state, "COMMENTED")) return .commented;
    if (std.mem.eql(u8, state, "APPROVED")) return .approved;
    if (std.mem.eql(u8, state, "CHANGES_REQUESTED")) return .changes_requested;
    if (std.mem.eql(u8, state, "DISMISSED")) return .dismissed;
    return .unknown;
}

fn sideFrom(side: []const u8) Side {
    if (std.mem.eql(u8, side, "LEFT")) return .left;
    return .right;
}

fn subjectTypeFrom(subject: []const u8) SubjectType {
    if (std.mem.eql(u8, subject, "FILE")) return .file;
    return .line;
}

fn pageHasNext(obj: std.json.ObjectMap) bool {
    const page_info = objField(obj, "pageInfo") orelse return false;
    return boolField(page_info, "hasNextPage");
}

fn dupe(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    return a.dupe(u8, s);
}

fn objField(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const v = obj.get(key) orelse return null;
    if (v != .object) return null;
    return v.object;
}

fn objValue(value: std.json.Value, key: []const u8) ?std.json.ObjectMap {
    if (value != .object) return null;
    return objField(value.object, key);
}

fn arrField(obj: std.json.ObjectMap, key: []const u8) ?[]std.json.Value {
    const v = obj.get(key) orelse return null;
    if (v != .array) return null;
    return v.array.items;
}

fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn boolField(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return v == .bool and v.bool;
}

fn u32Field(obj: std.json.ObjectMap, key: []const u8) u32 {
    return optU32Field(obj, key) orelse 0;
}

fn optU32Field(obj: std.json.ObjectMap, key: []const u8) ?u32 {
    const v = obj.get(key) orelse return null;
    if (v != .integer) return null;
    return std.math.cast(u32, v.integer);
}

fn u64Field(obj: std.json.ObjectMap, key: []const u8) u64 {
    const v = obj.get(key) orelse return 0;
    if (v != .integer) return 0;
    if (v.integer < 0) return 0;
    return @intCast(v.integer);
}

fn loginField(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const author = objField(obj, key) orelse return "";
    return strField(author, "login") orelse "";
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

// A compact, complete payload modeled on the real ziglang/zig #26015 shapes:
// viewer, PR metadata, a CheckRun + StatusContext, three reviews, and one
// outdated+resolved thread carrying a two-comment reply chain.
const full_payload =
    \\{"data":{"viewer":{"login":"ctdio"},"repository":{"pullRequest":{
    \\"id":"PR_kwDOAmaRMs61ANwe","number":26015,"title":"Fix deprecated init","body":"Body text","author":{"login":"meowjesty"},
    \\"isDraft":false,"baseRefName":"master","headRefName":"fix-branch","headRefOid":"cd82d454c6c5f87436e59bf5c984af6cad809113","reviewDecision":"APPROVED",
    \\"statusCheckRollup":{"state":"SUCCESS"},
    \\"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS","contexts":{"pageInfo":{"hasNextPage":false},"nodes":[
    \\{"__typename":"CheckRun","name":"x86_64-linux-debug","status":"COMPLETED","conclusion":"SUCCESS"},
    \\{"__typename":"StatusContext","context":"legacy-ci","state":"SUCCESS"}
    \\]}}}}]},
    \\"reviews":{"pageInfo":{"hasNextPage":false},"nodes":[
    \\{"id":"PRR_A","state":"COMMENTED","author":{"login":"IOKG04"},"body":"","submittedAt":"2025-11-22T22:14:26Z"},
    \\{"id":"PRR_B","state":"COMMENTED","author":{"login":"meowjesty"},"body":"","submittedAt":"2025-11-23T01:19:27Z"},
    \\{"id":"PRR_C","state":"APPROVED","author":{"login":"mlugg"},"body":"lgtm","submittedAt":"2025-11-23T09:43:56Z"}
    \\]},
    \\"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false},"nodes":[
    \\{"id":"PRRT_1","isResolved":true,"isOutdated":true,"line":null,"startLine":null,"originalLine":5,"diffSide":"RIGHT","startDiffSide":null,"path":"doc/langref/testing_detect_leak.zig","subjectType":"LINE",
    \\"comments":{"totalCount":2,"pageInfo":{"hasNextPage":false},"nodes":[
    \\{"id":"PRRC_1","databaseId":2553379794,"author":{"login":"IOKG04"},"body":"first","createdAt":"2025-11-22T22:14:26Z","diffHunk":"@@ -1,9 +1,10 @@","pullRequestReview":{"id":"PRR_A","state":"COMMENTED"},"replyTo":null},
    \\{"id":"PRRC_2","databaseId":2553649818,"author":{"login":"meowjesty"},"body":"reply","createdAt":"2025-11-23T01:19:27Z","diffHunk":"@@ -1,9 +1,10 @@","pullRequestReview":{"id":"PRR_B","state":"COMMENTED"},"replyTo":{"id":"PRRC_1"}}
    \\]}}
    \\]}
    \\}}}}
;

test "parsePrDetails: full payload happy path populates every field" {
    var data = try parsePrDetails(testing.allocator, full_payload);
    defer data.deinit();
    const d = data.details;

    try testing.expectEqualStrings("PR_kwDOAmaRMs61ANwe", d.pr_node_id);
    try testing.expectEqual(@as(u32, 26015), d.number);
    try testing.expectEqualStrings("Fix deprecated init", d.title);
    try testing.expectEqualStrings("Body text", d.body);
    try testing.expectEqualStrings("meowjesty", d.author);
    try testing.expect(!d.is_draft);
    try testing.expectEqualStrings("master", d.base_ref);
    try testing.expectEqualStrings("fix-branch", d.head_ref);
    try testing.expectEqualStrings("cd82d454c6c5f87436e59bf5c984af6cad809113", d.head_ref_oid);
    try testing.expectEqualStrings("APPROVED", d.review_decision);
    try testing.expectEqual(RollupState.success, d.rollup);
    try testing.expectEqualStrings("ctdio", d.viewer_login);
    try testing.expect(!d.truncated);
    try testing.expectEqual(@as(?[]const u8, null), d.pending_review_id);
}

test "parsePrDetails: checks map both CheckRun and StatusContext" {
    var data = try parsePrDetails(testing.allocator, full_payload);
    defer data.deinit();
    const checks = data.details.checks;

    try testing.expectEqual(@as(usize, 2), checks.len);
    try testing.expectEqualStrings("x86_64-linux-debug", checks[0].name);
    try testing.expectEqualStrings("COMPLETED", checks[0].status);
    try testing.expectEqualStrings("SUCCESS", checks[0].conclusion);
    // StatusContext -> name=context, status=conclusion=state
    try testing.expectEqualStrings("legacy-ci", checks[1].name);
    try testing.expectEqualStrings("SUCCESS", checks[1].status);
    try testing.expectEqualStrings("SUCCESS", checks[1].conclusion);
}

test "parsePrDetails: reviews parsed with states" {
    var data = try parsePrDetails(testing.allocator, full_payload);
    defer data.deinit();
    const reviews = data.details.reviews;

    try testing.expectEqual(@as(usize, 3), reviews.len);
    try testing.expectEqualStrings("IOKG04", reviews[0].author);
    try testing.expectEqual(ReviewState.commented, reviews[0].state);
    try testing.expectEqual(ReviewState.approved, reviews[2].state);
    try testing.expectEqualStrings("lgtm", reviews[2].body);
}

test "parsePrDetails: outdated thread has null line, preserved originalLine" {
    var data = try parsePrDetails(testing.allocator, full_payload);
    defer data.deinit();
    const threads = data.details.threads;

    try testing.expectEqual(@as(usize, 1), threads.len);
    const t = threads[0];
    try testing.expectEqualStrings("PRRT_1", t.id);
    try testing.expectEqualStrings("doc/langref/testing_detect_leak.zig", t.path);
    try testing.expectEqual(@as(?u32, null), t.line);
    try testing.expectEqual(@as(?u32, null), t.start_line);
    try testing.expectEqual(@as(?u32, 5), t.original_line);
    try testing.expect(t.is_outdated);
    try testing.expect(t.is_resolved);
    try testing.expectEqual(Side.right, t.side);
    // startDiffSide was null -> defaults to right
    try testing.expectEqual(Side.right, t.start_side);
    try testing.expectEqual(SubjectType.line, t.subject_type);
}

test "parsePrDetails: reply chain parsed as two comments in order" {
    var data = try parsePrDetails(testing.allocator, full_payload);
    defer data.deinit();
    const comments = data.details.threads[0].comments;

    try testing.expectEqual(@as(usize, 2), comments.len);
    try testing.expectEqualStrings("PRRC_1", comments[0].id);
    try testing.expectEqual(@as(u64, 2553379794), comments[0].database_id);
    try testing.expectEqualStrings("IOKG04", comments[0].author);
    try testing.expectEqualStrings("PRR_A", comments[0].review_id);
    try testing.expectEqual(ReviewState.commented, comments[0].review_state);
    try testing.expect(!comments[0].is_mine);
    try testing.expectEqual(@as(u64, 2553649818), comments[1].database_id);
    try testing.expectEqualStrings("reply", comments[1].body);
}

test "parsePrDetails: draft comment by viewer sets pending state, is_mine, pending_review_id" {
    const payload =
        \\{"data":{"viewer":{"login":"ctdio"},"repository":{"pullRequest":{
        \\"id":"PR_1","number":7,"title":"t","body":"","author":{"login":"ctdio"},
        \\"isDraft":false,"baseRefName":"main","headRefName":"h","headRefOid":"oid","reviewDecision":"",
        \\"statusCheckRollup":null,"commits":{"nodes":[]},
        \\"reviews":{"pageInfo":{"hasNextPage":false},"nodes":[
        \\{"id":"PRR_pending","state":"PENDING","author":{"login":"ctdio"},"body":"","submittedAt":null}
        \\]},
        \\"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false},"nodes":[
        \\{"id":"PRRT_1","isResolved":false,"isOutdated":false,"line":10,"startLine":null,"originalLine":10,"diffSide":"RIGHT","startDiffSide":"RIGHT","path":"src/x.zig","subjectType":"LINE",
        \\"comments":{"totalCount":1,"pageInfo":{"hasNextPage":false},"nodes":[
        \\{"id":"PRRC_1","databaseId":1,"author":{"login":"ctdio"},"body":"draft note","createdAt":"2025-01-01T00:00:00Z","diffHunk":"@@","pullRequestReview":{"id":"PRR_pending","state":"PENDING"},"replyTo":null}
        \\]}}
        \\]}
        \\}}}}
    ;
    var data = try parsePrDetails(testing.allocator, payload);
    defer data.deinit();
    const d = data.details;

    try testing.expectEqualStrings("PRR_pending", d.pending_review_id.?);
    const comment = d.threads[0].comments[0];
    try testing.expectEqual(ReviewState.pending, comment.review_state);
    try testing.expect(comment.is_mine);
    try testing.expectEqual(@as(?u32, 10), d.threads[0].line);
    try testing.expect(!d.threads[0].is_outdated);
}

test "parsePrDetails: unknown enum values degrade to safe defaults" {
    const payload =
        \\{"data":{"viewer":{"login":"ctdio"},"repository":{"pullRequest":{
        \\"id":"PR_1","number":1,"title":"t","body":"","author":{"login":"a"},
        \\"isDraft":false,"baseRefName":"main","headRefName":"h","headRefOid":"o","reviewDecision":"",
        \\"statusCheckRollup":{"state":"WEIRD_NEW_STATE"},"commits":{"nodes":[]},
        \\"reviews":{"pageInfo":{"hasNextPage":false},"nodes":[
        \\{"id":"PRR_1","state":"NEW_THING","author":{"login":"a"},"body":"","submittedAt":""}
        \\]},
        \\"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false},"nodes":[
        \\{"id":"PRRT_1","isResolved":false,"isOutdated":false,"line":1,"startLine":null,"originalLine":1,"diffSide":"BOGUS","startDiffSide":"BOGUS","path":"x","subjectType":"MYSTERY",
        \\"comments":{"pageInfo":{"hasNextPage":false},"nodes":[]}}
        \\]}
        \\}}}}
    ;
    var data = try parsePrDetails(testing.allocator, payload);
    defer data.deinit();
    const d = data.details;

    try testing.expectEqual(RollupState.none, d.rollup);
    try testing.expectEqual(ReviewState.unknown, d.reviews[0].state);
    try testing.expectEqual(Side.right, d.threads[0].side); // BOGUS -> right default
    try testing.expectEqual(SubjectType.line, d.threads[0].subject_type); // MYSTERY -> line
}

test "parsePrDetails: hasNextPage anywhere sets truncated" {
    const payload =
        \\{"data":{"viewer":{"login":"ctdio"},"repository":{"pullRequest":{
        \\"id":"PR_1","number":1,"title":"t","body":"","author":{"login":"a"},
        \\"isDraft":false,"baseRefName":"main","headRefName":"h","headRefOid":"o","reviewDecision":"",
        \\"statusCheckRollup":null,"commits":{"nodes":[]},
        \\"reviews":{"pageInfo":{"hasNextPage":false},"nodes":[]},
        \\"reviewThreads":{"totalCount":200,"pageInfo":{"hasNextPage":true},"nodes":[]}
        \\}}}}
    ;
    var data = try parsePrDetails(testing.allocator, payload);
    defer data.deinit();
    try testing.expect(data.details.truncated);
}

test "parsePrDetails: empty threads and reviews yield empty slices" {
    const payload =
        \\{"data":{"viewer":{"login":"ctdio"},"repository":{"pullRequest":{
        \\"id":"PR_1","number":1,"title":"t","body":"","author":{"login":"a"},
        \\"isDraft":false,"baseRefName":"main","headRefName":"h","headRefOid":"o","reviewDecision":"",
        \\"statusCheckRollup":null,"commits":{"nodes":[]},
        \\"reviews":{"pageInfo":{"hasNextPage":false},"nodes":[]},
        \\"reviewThreads":{"totalCount":0,"pageInfo":{"hasNextPage":false},"nodes":[]}
        \\}}}}
    ;
    var data = try parsePrDetails(testing.allocator, payload);
    defer data.deinit();
    try testing.expectEqual(@as(usize, 0), data.details.threads.len);
    try testing.expectEqual(@as(usize, 0), data.details.reviews.len);
    try testing.expectEqual(@as(usize, 0), data.details.checks.len);
    try testing.expectEqualStrings("", data.details.body);
}

test "parsePrDetails: rejects invalid JSON" {
    try testing.expectError(error.SyntaxError, parsePrDetails(testing.allocator, "{not json"));
}

test "parsePrDetails: rejects empty string" {
    try testing.expectError(error.UnexpectedEndOfInput, parsePrDetails(testing.allocator, ""));
}

test "parsePrDetails: rejects payload missing data.repository" {
    try testing.expectError(error.InvalidPayload, parsePrDetails(testing.allocator, "{\"data\":{\"viewer\":{\"login\":\"x\"}}}"));
}

test "parsePrDetails: rejects payload missing pullRequest" {
    try testing.expectError(error.InvalidPayload, parsePrDetails(testing.allocator, "{\"data\":{\"repository\":{}}}"));
}

test "parsePrView: extracts base_ref and metadata from gh pr view output" {
    const json =
        \\{"number":26015,"title":"Fix deprecated init","author":{"login":"meowjesty"},
        \\"headRefName":"fix-branch","baseRefName":"master","isDraft":false,
        \\"updatedAt":"2025-11-23T09:43:56Z","url":"https://github.com/ziglang/zig/pull/26015","statusCheckRollup":[]}
    ;
    var meta = try parsePrView(testing.allocator, json);
    defer meta.deinit();
    try testing.expectEqual(@as(u32, 26015), meta.number);
    try testing.expectEqualStrings("master", meta.base_ref);
    try testing.expectEqualStrings("fix-branch", meta.head_ref);
    try testing.expectEqualStrings("Fix deprecated init", meta.title);
    try testing.expect(!meta.is_draft);
}

test "parsePrView: rejects invalid JSON" {
    try testing.expectError(error.SyntaxError, parsePrView(testing.allocator, "{bad"));
}

// =============================================================================
// Mutation-response parsers — canned data captured live via `gh api graphql`
// against a scratch PR on 2026-07-04 (see phase-03 captured/*.json fixtures).
// =============================================================================

const mutation_add_review =
    \\{"data":{"addPullRequestReview":{"pullRequestReview":{"id":"PRR_kwDOQOqc088AAAABE_3crg","state":"PENDING"}}}}
;

const mutation_add_thread =
    \\{"data":{"addPullRequestReviewThread":{"thread":{"id":"PRRT_kwDOQOqc086OXy_S","isResolved":false,"isOutdated":false,"line":655,"startLine":655,"originalLine":655,"diffSide":"RIGHT","startDiffSide":null,"path":"README.md","subjectType":"LINE","comments":{"totalCount":1,"pageInfo":{"hasNextPage":false},"nodes":[{"id":"PRRC_kwDOQOqc087SC5gz","databaseId":3523975219,"author":{"login":"ctdio"},"body":"harness single-line \"quote\" %s émoji 🎉\nsecond line with `backtick` & <html>","createdAt":"2026-07-04T23:02:51Z","diffHunk":"@@ -652,3 +652,8 @@ Built with:\n ## License\n \n MIT\n+harness-line-1","pullRequestReview":{"id":"PRR_kwDOQOqc088AAAABE_3crg","state":"PENDING"},"replyTo":null}]}}}}}
;

const mutation_add_thread_range =
    \\{"data":{"addPullRequestReviewThread":{"thread":{"id":"PRRT_kwDOQOqc086OXy_i","isResolved":false,"isOutdated":false,"line":658,"startLine":656,"originalLine":658,"diffSide":"RIGHT","startDiffSide":"RIGHT","path":"README.md","subjectType":"LINE","comments":{"totalCount":1,"pageInfo":{"hasNextPage":false},"nodes":[{"id":"PRRC_kwDOQOqc087SC5hH","databaseId":3523975239,"author":{"login":"ctdio"},"body":"multi\nline range body \"with quotes\" 100% 🚀","createdAt":"2026-07-04T23:02:52Z","diffHunk":"@@ -652,3 +652,8 @@ Built with:\n ## License\n \n MIT\n+harness-line-1\n+harness-line-2\n+harness-line-3\n+harness-line-4","pullRequestReview":{"id":"PRR_kwDOQOqc088AAAABE_3crg","state":"PENDING"},"replyTo":null}]}}}}}
;

const mutation_error_envelope =
    \\{"data":{"addPullRequestReview":null},"errors":[{"type":"UNPROCESSABLE","path":["addPullRequestReview"],"locations":[{"line":2,"column":7}],"message":"User can only have one pending review per pull request"}]}
;

const mutation_null_thread =
    \\{"data":{"addPullRequestReviewThread":{"thread":null}}}
;

const mutation_delete_review =
    \\{"data":{"deletePullRequestReview":{"pullRequestReview":{"id":"PRR_kwDOQOqc088AAAABE_3crg","state":"PENDING"}}}}
;

test "parseCreatedReviewId: extracts the created PENDING review id" {
    const id = try parseCreatedReviewId(testing.allocator, mutation_add_review);
    defer testing.allocator.free(id);
    try testing.expectEqualStrings("PRR_kwDOQOqc088AAAABE_3crg", id);
}

test "parseCreatedReviewId: reuses on the delete-review response shape" {
    // deletePullRequestReview returns the same pullRequestReview{id} shape, but
    // under a different mutation key — parseCreatedReviewId only knows the
    // add key, so this must fail cleanly (delete has its own dedicated call).
    try testing.expectError(error.InvalidPayload, parseCreatedReviewId(testing.allocator, mutation_delete_review));
}

test "parseCreatedReviewId: detects the GraphQL error envelope (HTTP 200)" {
    try testing.expectError(error.GraphqlError, parseCreatedReviewId(testing.allocator, mutation_error_envelope));
}

test "parseCreatedReviewId: missing review id errors cleanly" {
    try testing.expectError(error.MissingReviewId, parseCreatedReviewId(testing.allocator, "{\"data\":{\"addPullRequestReview\":{\"pullRequestReview\":{\"state\":\"PENDING\"}}}}"));
}

test "parseCreatedThread: full node parses to ReviewThread with hostile body byte-exact" {
    var created = try parseCreatedThread(testing.allocator, mutation_add_thread, "ctdio");
    defer created.deinit();
    const t = created.thread;

    try testing.expectEqualStrings("PRRT_kwDOQOqc086OXy_S", t.id);
    try testing.expectEqualStrings("README.md", t.path);
    try testing.expectEqual(@as(?u32, 655), t.line);
    try testing.expectEqual(Side.right, t.side);
    try testing.expect(!t.is_resolved);
    try testing.expect(!t.is_outdated);
    try testing.expectEqual(@as(usize, 1), t.comments.len);
    const c = t.comments[0];
    try testing.expectEqualStrings("PRRC_kwDOQOqc087SC5gz", c.id);
    try testing.expectEqualStrings("ctdio", c.author);
    try testing.expectEqual(ReviewState.pending, c.review_state);
    try testing.expect(c.is_mine); // viewer == author
    try testing.expectEqualStrings("harness single-line \"quote\" %s émoji \u{1F389}\nsecond line with `backtick` & <html>", c.body);
    try testing.expectEqualStrings("PRR_kwDOQOqc088AAAABE_3crg", c.review_id);
}

test "parseCreatedThread: range variant carries startLine and startSide" {
    var created = try parseCreatedThread(testing.allocator, mutation_add_thread_range, "ctdio");
    defer created.deinit();
    const t = created.thread;
    try testing.expectEqual(@as(?u32, 658), t.line);
    try testing.expectEqual(@as(?u32, 656), t.start_line);
    try testing.expectEqual(Side.right, t.side);
    try testing.expectEqual(Side.right, t.start_side);
}

test "parseCreatedThread: thread:null (bad path) is a distinct failure" {
    try testing.expectError(error.ThreadCreationFailed, parseCreatedThread(testing.allocator, mutation_null_thread, "ctdio"));
}

test "parseCreatedThread: detects the GraphQL error envelope" {
    const err_body =
        \\{"data":{"addPullRequestReviewThread":null},"errors":[{"message":"Something failed"}]}
    ;
    try testing.expectError(error.GraphqlError, parseCreatedThread(testing.allocator, err_body, "ctdio"));
}

test "parseCreatedThread: is_mine false when viewer differs from author" {
    var created = try parseCreatedThread(testing.allocator, mutation_add_thread, "someone-else");
    defer created.deinit();
    try testing.expect(!created.thread.comments[0].is_mine);
}

// =============================================================================
// Thread-interaction mutation parsers (Phase 4) — canned data captured live via
// `gh api graphql` against a scratch PR on 2026-07-05 (see phase-04 captured/).
// =============================================================================

const mutation_reply =
    \\{"data":{"addPullRequestReviewThreadReply":{"comment":{"id":"PRRC_kwDOQOqc087SDGoO","databaseId":3524028942,"author":{"login":"ctdio"},"body":"harness reply \"quoted\" %s émoji 🎯\nsecond line `backtick` & <html>","createdAt":"2026-07-05T00:02:21Z","diffHunk":"@@ -652,3 +652,8 @@ Built with:\n ## License\n \n MIT\n+harness-line-1","pullRequestReview":{"id":"PRR_kwDOQOqc088AAAABE_6Wmw","state":"COMMENTED"},"replyTo":{"id":"PRRC_kwDOQOqc087SDGn3"}}}}}
;

const mutation_reply_pending =
    \\{"data":{"addPullRequestReviewThreadReply":{"comment":{"id":"PRRC_kwDOQOqc087SDGo-","databaseId":3524028990,"author":{"login":"ctdio"},"body":"reply issued while a pending review exists","createdAt":"2026-07-05T00:02:23Z","diffHunk":"@@ -652,3 +652,8 @@ Built with:\n ## License\n \n MIT\n+harness-line-1","pullRequestReview":{"id":"PRR_kwDOQOqc088AAAABE_6WvQ","state":"PENDING"},"replyTo":{"id":"PRRC_kwDOQOqc087SDGn3"}}}}}
;

const mutation_resolve =
    \\{"data":{"resolveReviewThread":{"thread":{"id":"PRRT_kwDOQOqc086OX9Bp","isResolved":true}}}}
;

const mutation_unresolve =
    \\{"data":{"unresolveReviewThread":{"thread":{"id":"PRRT_kwDOQOqc086OX9Bp","isResolved":false}}}}
;

const mutation_update_comment =
    \\{"data":{"updatePullRequestReviewComment":{"pullRequestReviewComment":{"id":"PRRC_kwDOQOqc087SDGoO","body":"edited reply body — 100% changed 🔁"}}}}
;

const mutation_delete_comment =
    \\{"data":{"deletePullRequestReviewComment":{"clientMutationId":null,"pullRequestReviewComment":{"id":"PRRC_kwDOQOqc087SDGoO","databaseId":3524028942}}}}
;

test "parseCreatedComment: reply node parses byte-exact with COMMENTED state" {
    var created = try parseCreatedComment(testing.allocator, mutation_reply, "ctdio");
    defer created.deinit();
    const c = created.comment;
    try testing.expectEqualStrings("PRRC_kwDOQOqc087SDGoO", c.id);
    try testing.expectEqual(@as(u64, 3524028942), c.database_id);
    try testing.expectEqualStrings("ctdio", c.author);
    try testing.expectEqualStrings("harness reply \"quoted\" %s émoji \u{1F3AF}\nsecond line `backtick` & <html>", c.body);
    try testing.expectEqual(ReviewState.commented, c.review_state);
    try testing.expect(c.is_mine);
    try testing.expectEqualStrings("PRR_kwDOQOqc088AAAABE_6Wmw", c.review_id);
}

test "parseCreatedComment: reply joining a pending review carries pending state" {
    var created = try parseCreatedComment(testing.allocator, mutation_reply_pending, "ctdio");
    defer created.deinit();
    // Risk 1b: a reply issued while a pending review exists returns PENDING —
    // the draft-badge path is real and must be surfaced.
    try testing.expectEqual(ReviewState.pending, created.comment.review_state);
}

test "parseCreatedComment: is_mine false when viewer differs from author" {
    var created = try parseCreatedComment(testing.allocator, mutation_reply, "someone-else");
    defer created.deinit();
    try testing.expect(!created.comment.is_mine);
}

test "parseCreatedComment: detects the GraphQL error envelope" {
    const err_body =
        \\{"data":{"addPullRequestReviewThreadReply":null},"errors":[{"message":"nope"}]}
    ;
    try testing.expectError(error.GraphqlError, parseCreatedComment(testing.allocator, err_body, "ctdio"));
}

test "parseResolveResult: resolve sets isResolved true" {
    var r = try parseResolveResult(testing.allocator, mutation_resolve);
    defer r.deinit();
    try testing.expectEqualStrings("PRRT_kwDOQOqc086OX9Bp", r.thread_id);
    try testing.expect(r.is_resolved);
}

test "parseResolveResult: unresolve sets isResolved false (different top-level key)" {
    var r = try parseResolveResult(testing.allocator, mutation_unresolve);
    defer r.deinit();
    try testing.expectEqualStrings("PRRT_kwDOQOqc086OX9Bp", r.thread_id);
    try testing.expect(!r.is_resolved);
}

test "parseResolveResult: detects the GraphQL error envelope" {
    const err_body =
        \\{"data":{"resolveReviewThread":null},"errors":[{"message":"nope"}]}
    ;
    try testing.expectError(error.GraphqlError, parseResolveResult(testing.allocator, err_body));
}

test "parseUpdatedComment: extracts id and new body byte-exact" {
    var u = try parseUpdatedComment(testing.allocator, mutation_update_comment);
    defer u.deinit();
    try testing.expectEqualStrings("PRRC_kwDOQOqc087SDGoO", u.id);
    try testing.expectEqualStrings("edited reply body — 100% changed \u{1F501}", u.body);
}

test "parseUpdatedComment: detects the GraphQL error envelope" {
    const err_body =
        \\{"data":{"updatePullRequestReviewComment":null},"errors":[{"message":"nope"}]}
    ;
    try testing.expectError(error.GraphqlError, parseUpdatedComment(testing.allocator, err_body));
}

test "parseDeletedComment: confirms success and echoes the deleted id" {
    const id = try parseDeletedComment(testing.allocator, mutation_delete_comment);
    defer testing.allocator.free(id);
    try testing.expectEqualStrings("PRRC_kwDOQOqc087SDGoO", id);
}

test "parseDeletedComment: detects the GraphQL error envelope" {
    const err_body =
        \\{"data":{"deletePullRequestReviewComment":null},"errors":[{"message":"nope"}]}
    ;
    try testing.expectError(error.GraphqlError, parseDeletedComment(testing.allocator, err_body));
}

test "parsePrDetails: unicode and CRLF bodies survive byte-exact" {
    // Body carries an emoji and a ```suggestion fence with CRLF, matching the
    // real captured comment body. In a Zig `\\` literal the \r\n are literal
    // backslash-escapes that std.json turns into CR/LF bytes.
    const payload =
        \\{"data":{"viewer":{"login":"ctdio"},"repository":{"pullRequest":{
        \\"id":"PR_1","number":1,"title":"t","body":"","author":{"login":"a"},
        \\"isDraft":false,"baseRefName":"main","headRefName":"h","headRefOid":"o","reviewDecision":"",
        \\"statusCheckRollup":null,"commits":{"nodes":[]},
        \\"reviews":{"pageInfo":{"hasNextPage":false},"nodes":[]},
        \\"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false},"nodes":[
        \\{"id":"PRRT_1","isResolved":false,"isOutdated":false,"line":1,"startLine":null,"originalLine":1,"diffSide":"RIGHT","startDiffSide":null,"path":"x","subjectType":"LINE",
        \\"comments":{"pageInfo":{"hasNextPage":false},"nodes":[
        \\{"id":"PRRC_1","databaseId":1,"author":{"login":"a"},"body":"```suggestion\r\n  var x = .empty;\r\n```\r\n\r\nUse ☔ instead","createdAt":"","diffHunk":"","pullRequestReview":{"id":"PRR_1","state":"COMMENTED"},"replyTo":null}
        \\]}}
        \\]}
        \\}}}}
    ;
    var data = try parsePrDetails(testing.allocator, payload);
    defer data.deinit();
    const body = data.details.threads[0].comments[0].body;
    try testing.expectEqualStrings("```suggestion\r\n  var x = .empty;\r\n```\r\n\r\nUse \u{2614} instead", body);
}
