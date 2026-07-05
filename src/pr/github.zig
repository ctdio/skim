//! GitHub backend: shells out to the `gh` CLI and hands the raw JSON to the
//! pure parser in `parse.zig`. This is the imperative shell — the only IO in
//! the PR data layer lives here.

const std = @import("std");
const parse = @import("parse.zig");
const review_parse = @import("review_parse.zig");

pub const Error = error{ GhCommandFailed, GhNotFound };

const default_limit = 50;

const json_fields = "number,title,author,headRefName,baseRefName,isDraft,updatedAt,url,statusCheckRollup";

/// List open PRs for the repo in the current working directory.
pub fn listPullRequests(allocator: std.mem.Allocator) !parse.PullRequestList {
    const raw = try listPullRequestsRaw(allocator);
    defer allocator.free(raw);
    return parse.parse(allocator, raw);
}

/// List open PRs as the raw JSON `gh` emits, so callers can persist it verbatim
/// (e.g. to the on-disk cache) before parsing. Caller owns the returned bytes.
pub fn listPullRequestsRaw(allocator: std.mem.Allocator) ![]u8 {
    var buf: [16]u8 = undefined;
    const limit = std.fmt.bufPrint(&buf, "{d}", .{default_limit}) catch unreachable;

    const argv = [_][]const u8{
        "gh", "pr", "list", "--limit", limit, "--json", json_fields,
    };

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
        .max_output_bytes = 16 * 1024 * 1024,
    }) catch |err| switch (err) {
        error.FileNotFound => return Error.GhNotFound,
        else => return err,
    };
    errdefer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) {
            std.log.err("gh pr list failed ({d}): {s}", .{ code, result.stderr });
            return Error.GhCommandFailed;
        },
        else => return Error.GhCommandFailed,
    }

    return result.stdout;
}

/// Fetch a PR's head into a stable local ref (`refs/skim/pr-<number>`) without
/// touching the working tree, and fetch its base branch so `base...head` can be
/// diffed. Uses `pull/<number>/head`, which GitHub exposes on `origin` even for
/// fork PRs — so no extra remotes or worktrees are needed. Returns the local
/// head ref name; caller owns it.
pub fn fetchRef(allocator: std.mem.Allocator, params: struct {
    number: u32,
    base_ref: []const u8,
}) ![]u8 {
    const head_ref = try std.fmt.allocPrint(allocator, "refs/skim/pr-{d}", .{params.number});
    errdefer allocator.free(head_ref);

    const refspec = try std.fmt.allocPrint(allocator, "+pull/{d}/head:{s}", .{ params.number, head_ref });
    defer allocator.free(refspec);

    try runGit(allocator, &.{ "git", "fetch", "--quiet", "origin", refspec });

    if (params.base_ref.len > 0) {
        // Land the base in its remote-tracking ref so `origin/<base>...head`
        // resolves. Best-effort: a missing base only weakens the merge-base.
        const base_spec = try std.fmt.allocPrint(allocator, "+{s}:refs/remotes/origin/{s}", .{ params.base_ref, params.base_ref });
        defer allocator.free(base_spec);
        runGit(allocator, &.{ "git", "fetch", "--quiet", "origin", base_spec }) catch {};
    }

    return head_ref;
}

// =============================================================================
// Review data (gh api graphql / gh pr view)
// =============================================================================

pub const OwnerRepo = struct { owner: []const u8, repo: []const u8 };

/// A parsed `skim pr <arg>` / `skim debug pr-view <arg>` positional: a bare PR
/// number or a github.com PR URL. `url` fields alias the input slice.
pub const PrRequest = union(enum) {
    number: u32,
    url: struct { owner: []const u8, repo: []const u8, number: u32 },
};

pub const GhErrorKind = enum { not_installed, not_authenticated, not_found, rate_limited, network, other };

/// Typed key/value pairs for `gh api graphql` variables. `-f` passes strings,
/// `-F` passes typed (here: integer) values so the GraphQL `Int!` binds.
pub const KV = struct { key: []const u8, value: []const u8 };
pub const KVInt = struct { key: []const u8, value: i64 };

pub const GhResult = struct { stdout: []u8, stderr: []u8, exit_code: u32 };

/// Either the raw JSON bytes gh emitted (caller owns) or a classified failure.
/// Parsing stays in `review_parse.zig`; this shell only detects errors.
pub const GhFetch = union(enum) {
    ok: []u8,
    failed: GhErrorKind,
};

/// The Phase 1 review query. MUST stay byte-compatible with
/// `scripts/test-infra/pr-review/pr-review.graphql` (the drift-check reference).
pub const review_query =
    \\query ($owner: String!, $name: String!, $number: Int!) {
    \\  viewer {
    \\    login
    \\  }
    \\  repository(owner: $owner, name: $name) {
    \\    pullRequest(number: $number) {
    \\      id
    \\      number
    \\      title
    \\      body
    \\      author {
    \\        login
    \\      }
    \\      isDraft
    \\      baseRefName
    \\      headRefName
    \\      headRefOid
    \\      reviewDecision
    \\      statusCheckRollup {
    \\        state
    \\      }
    \\      commits(last: 1) {
    \\        nodes {
    \\          commit {
    \\            statusCheckRollup {
    \\              state
    \\              contexts(first: 50) {
    \\                pageInfo {
    \\                  hasNextPage
    \\                }
    \\                nodes {
    \\                  __typename
    \\                  ... on CheckRun {
    \\                    name
    \\                    status
    \\                    conclusion
    \\                  }
    \\                  ... on StatusContext {
    \\                    context
    \\                    state
    \\                  }
    \\                }
    \\              }
    \\            }
    \\          }
    \\        }
    \\      }
    \\      reviews(first: 50) {
    \\        pageInfo {
    \\          hasNextPage
    \\        }
    \\        nodes {
    \\          id
    \\          state
    \\          author {
    \\            login
    \\          }
    \\          body
    \\          submittedAt
    \\        }
    \\      }
    \\      reviewThreads(first: 100) {
    \\        totalCount
    \\        pageInfo {
    \\          hasNextPage
    \\        }
    \\        nodes {
    \\          id
    \\          isResolved
    \\          isOutdated
    \\          line
    \\          startLine
    \\          originalLine
    \\          diffSide
    \\          startDiffSide
    \\          path
    \\          subjectType
    \\          comments(first: 50) {
    \\            totalCount
    \\            pageInfo {
    \\              hasNextPage
    \\            }
    \\            nodes {
    \\              id
    \\              databaseId
    \\              author {
    \\                login
    \\              }
    \\              body
    \\              createdAt
    \\              diffHunk
    \\              pullRequestReview {
    \\                id
    \\                state
    \\              }
    \\              replyTo {
    \\                id
    \\              }
    \\            }
    \\          }
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

/// Resolve the current repo's `owner/repo` from the origin remote URL.
pub fn getOriginOwnerRepo(allocator: std.mem.Allocator) !OwnerRepo {
    const url = gitLine(allocator, &.{ "git", "config", "--get", "remote.origin.url" }) orelse return error.NoOriginRemote;
    defer allocator.free(url);
    return parseOwnerRepo(allocator, url);
}

/// Parse `owner`/`repo` out of a GitHub remote URL. Handles the scp form
/// (`git@github.com:owner/repo(.git)`) and https form
/// (`https://github.com/owner/repo(.git)`), with or without `.git`/trailing
/// slash. Returned strings are owned by `allocator`.
pub fn parseOwnerRepo(allocator: std.mem.Allocator, remote_url: []const u8) !OwnerRepo {
    var url = std.mem.trim(u8, remote_url, " \t\r\n");
    const marker = "github.com";
    const idx = std.mem.indexOf(u8, url, marker) orelse return error.InvalidRemoteUrl;
    var rest = url[idx + marker.len ..];
    if (rest.len == 0) return error.InvalidRemoteUrl;
    // The separator after the host is ':' (scp) or '/' (https/ssh URL).
    if (rest[0] != ':' and rest[0] != '/') return error.InvalidRemoteUrl;
    rest = rest[1..];

    rest = std.mem.trimRight(u8, rest, "/");
    if (std.mem.endsWith(u8, rest, ".git")) rest = rest[0 .. rest.len - ".git".len];

    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidRemoteUrl;
    const owner = rest[0..slash];
    const repo = rest[slash + 1 ..];
    if (owner.len == 0 or repo.len == 0) return error.InvalidRemoteUrl;
    // A well-formed owner/repo has exactly one slash between them.
    if (std.mem.indexOfScalar(u8, repo, '/') != null) return error.InvalidRemoteUrl;

    return .{
        .owner = try allocator.dupe(u8, owner),
        .repo = try allocator.dupe(u8, repo),
    };
}

/// Parse a `pr` positional into a `PrRequest`. A bare integer is a PR number;
/// a string containing `github.com/` is parsed as a PR URL. Pure — tested below.
pub fn parsePrArg(arg: []const u8) !PrRequest {
    if (std.mem.indexOf(u8, arg, "github.com/") != null) {
        return parsePrUrl(arg);
    }
    const number = std.fmt.parseInt(u32, arg, 10) catch return error.InvalidPrArg;
    if (number == 0) return error.InvalidPrArg;
    return .{ .number = number };
}

fn parsePrUrl(arg: []const u8) !PrRequest {
    const marker = "github.com/";
    const idx = std.mem.indexOf(u8, arg, marker) orelse return error.InvalidPrArg;
    var rest = arg[idx + marker.len ..];
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| rest = rest[0..q];
    if (std.mem.indexOfScalar(u8, rest, '#')) |h| rest = rest[0..h];

    var it = std.mem.splitScalar(u8, rest, '/');
    const owner = it.next() orelse return error.InvalidPrArg;
    const repo = it.next() orelse return error.InvalidPrArg;
    const kind = it.next() orelse return error.InvalidPrArg;
    if (!std.mem.eql(u8, kind, "pull")) return error.InvalidPrArg;
    const num_str = it.next() orelse return error.InvalidPrArg;
    const number = std.fmt.parseInt(u32, num_str, 10) catch return error.InvalidPrArg;
    if (number == 0 or owner.len == 0 or repo.len == 0) return error.InvalidPrArg;

    return .{ .url = .{ .owner = owner, .repo = repo, .number = number } };
}

/// Fetch the full review payload for a PR via the GraphQL query above.
pub fn fetchReviewData(allocator: std.mem.Allocator, owner_repo: OwnerRepo, number: u32) !GhFetch {
    const argv = try buildGraphqlArgv(allocator, review_query, &.{
        .{ .key = "owner", .value = owner_repo.owner },
        .{ .key = "name", .value = owner_repo.repo },
    }, &.{
        .{ .key = "number", .value = @intCast(number) },
    });
    defer freeArgv(allocator, argv);
    return runGhCapture(allocator, argv, "gh api graphql");
}

/// Fetch a single PR's metadata (`gh pr view <n> --json ...`). Used to resolve
/// `baseRefName` for number-only entry (`skim pr <n>`) before the ref fetch.
pub fn fetchPrByNumber(allocator: std.mem.Allocator, number: u32) !GhFetch {
    var buf: [16]u8 = undefined;
    const num = std.fmt.bufPrint(&buf, "{d}", .{number}) catch unreachable;
    const argv = [_][]const u8{ "gh", "pr", "view", num, "--json", json_fields };
    return runGhCapture(allocator, &argv, "gh pr view");
}

// =============================================================================
// Write path (pending-review mutations)
// =============================================================================

/// Thread-node selection for the addPullRequestReviewThread response. Byte-mirrors
/// `review_query`'s `reviewThreads.nodes` shape so `review_parse.parseCreatedThread`
/// reuses the SAME node parser as the fetch path.
const thread_node_selection =
    \\thread {
    \\  id
    \\  isResolved
    \\  isOutdated
    \\  line
    \\  startLine
    \\  originalLine
    \\  diffSide
    \\  startDiffSide
    \\  path
    \\  subjectType
    \\  comments(first: 50) {
    \\    totalCount
    \\    pageInfo { hasNextPage }
    \\    nodes {
    \\      id
    \\      databaseId
    \\      author { login }
    \\      body
    \\      createdAt
    \\      diffHunk
    \\      pullRequestReview { id state }
    \\      replyTo { id }
    \\    }
    \\  }
    \\}
;

const create_review_mutation =
    \\mutation ($prId: ID!, $oid: GitObjectID!) {
    \\  addPullRequestReview(input: {pullRequestId: $prId, commitOID: $oid}) {
    \\    pullRequestReview { id state }
    \\  }
    \\}
;

const add_thread_mutation =
    \\mutation ($rid: ID!, $path: String!, $line: Int!, $side: DiffSide!, $body: String!) {
    \\  addPullRequestReviewThread(input: {pullRequestReviewId: $rid, path: $path, line: $line, side: $side, body: $body}) {
    ++ "\n" ++ thread_node_selection ++ "\n" ++
    \\  }
    \\}
;

const add_thread_range_mutation =
    \\mutation ($rid: ID!, $path: String!, $line: Int!, $side: DiffSide!, $sl: Int!, $ss: DiffSide!, $body: String!) {
    \\  addPullRequestReviewThread(input: {pullRequestReviewId: $rid, path: $path, line: $line, side: $side, startLine: $sl, startSide: $ss, body: $body}) {
    ++ "\n" ++ thread_node_selection ++ "\n" ++
    \\  }
    \\}
;

const delete_review_mutation =
    \\mutation ($id: ID!) {
    \\  deletePullRequestReview(input: {pullRequestReviewId: $id}) {
    \\    pullRequestReview { id state }
    \\  }
    \\}
;

const submit_review_mutation =
    \\mutation ($rid: ID!, $event: PullRequestReviewEvent!, $body: String!) {
    \\  submitPullRequestReview(input: {pullRequestReviewId: $rid, event: $event, body: $body}) {
    \\    pullRequestReview { id state }
    \\  }
    \\}
;

/// Comment-node selection for the reply mutation. Byte-mirrors the comment nodes
/// selected by `review_query`/`thread_node_selection` so `review_parse.parseCreatedComment`
/// reuses the SAME comment-node parser as the fetch path.
const reply_mutation =
    \\mutation ($tid: ID!, $body: String!) {
    \\  addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $tid, body: $body}) {
    \\    comment {
    \\      id
    \\      databaseId
    \\      author { login }
    \\      body
    \\      createdAt
    \\      diffHunk
    \\      pullRequestReview { id state }
    \\      replyTo { id }
    \\    }
    \\  }
    \\}
;

const resolve_thread_mutation =
    \\mutation ($tid: ID!) {
    \\  resolveReviewThread(input: {threadId: $tid}) {
    \\    thread { id isResolved }
    \\  }
    \\}
;

const unresolve_thread_mutation =
    \\mutation ($tid: ID!) {
    \\  unresolveReviewThread(input: {threadId: $tid}) {
    \\    thread { id isResolved }
    \\  }
    \\}
;

const update_comment_mutation =
    \\mutation ($cid: ID!, $body: String!) {
    \\  updatePullRequestReviewComment(input: {pullRequestReviewCommentId: $cid, body: $body}) {
    \\    pullRequestReviewComment { id body }
    \\  }
    \\}
;

const delete_comment_mutation =
    \\mutation ($cid: ID!) {
    \\  deletePullRequestReviewComment(input: {id: $cid}) {
    \\    clientMutationId
    \\    pullRequestReviewComment { id databaseId }
    \\  }
    \\}
;

/// Params for `addReviewThread`. `start_line == null` posts a single-line
/// comment; otherwise a multi-line range (start..line).
pub const AddThreadParams = struct {
    review_id: []const u8,
    path: []const u8,
    line: u32,
    side: review_parse.Side,
    start_line: ?u32 = null,
    start_side: review_parse.Side = .right,
    body: []const u8,
};

/// Create a PENDING review (event omitted → PENDING per GitHub). Returns the raw
/// mutation JSON (parse the id with `review_parse.parseCreatedReviewId`).
pub fn createPendingReview(allocator: std.mem.Allocator, pr_node_id: []const u8, commit_oid: []const u8) !GhFetch {
    const argv = try buildCreateReviewArgs(allocator, pr_node_id, commit_oid);
    defer freeArgv(allocator, argv);
    return runGhCapture(allocator, argv, "gh api graphql (addPullRequestReview)");
}

/// Post a review thread (line or range) to an existing pending review. Returns
/// the raw mutation JSON (parse with `review_parse.parseCreatedThread`). The
/// body is passed as a `-f body=<text>` argv element — no shell interpolation,
/// so multi-line / quote / `%` / emoji bodies are safe by construction.
pub fn addReviewThread(allocator: std.mem.Allocator, params: AddThreadParams) !GhFetch {
    const argv = try buildAddThreadArgs(allocator, params);
    defer freeArgv(allocator, argv);
    return runGhCapture(allocator, argv, "gh api graphql (addPullRequestReviewThread)");
}

/// Discard a pending review. Returns the raw mutation JSON. Like `submitReview`,
/// this routes through `runGhCaptureAllowErrorBody`: GitHub returns HTTP 200 with
/// an `errors` envelope for a domain rejection (e.g. the pending review was
/// deleted on the web mid-flight), so preserving that body lets the caller surface
/// the specific message via `review_parse.firstErrorMessage` instead of a generic
/// classified error. Used by `skim debug pr-discard` and the TUI discard flow.
pub fn deletePendingReview(allocator: std.mem.Allocator, review_id: []const u8) !GhFetch {
    const argv = try buildDeleteReviewArgs(allocator, review_id);
    defer freeArgv(allocator, argv);
    return runGhCaptureAllowErrorBody(allocator, argv, "gh api graphql (deletePullRequestReview)");
}

/// Submit a review (`submitPullRequestReview`), transitioning the pending review
/// to COMMENT/APPROVE/REQUEST_CHANGES and publishing all its draft comments.
/// `event` is the GraphQL enum string ("COMMENT" | "APPROVE" | "REQUEST_CHANGES");
/// pass it via `review_controller.verdictEvent`. Returns the raw mutation JSON —
/// note GitHub returns HTTP 200 with an `errors` envelope for a rejected submit
/// (e.g. approving your own PR), so parse with `review_parse.parseSubmitReview`,
/// which surfaces that envelope's message. The body is a `-f body=<text>` argv
/// element — shell-safe by construction.
pub fn submitReview(allocator: std.mem.Allocator, review_id: []const u8, event: []const u8, body: []const u8) !GhFetch {
    const argv = try buildSubmitReviewArgs(allocator, review_id, event, body);
    defer freeArgv(allocator, argv);
    return runGhCaptureAllowErrorBody(allocator, argv, "gh api graphql (submitPullRequestReview)");
}

/// Reply to an existing review thread. Returns the raw mutation JSON (parse with
/// `review_parse.parseCreatedComment`). GitHub attaches the reply to the viewer's
/// pending review if one exists (comment returns `state: PENDING`). The body is a
/// `-f body=<text>` argv element — shell-safe by construction.
pub fn replyToThread(allocator: std.mem.Allocator, thread_id: []const u8, body: []const u8) !GhFetch {
    const argv = try buildReplyArgs(allocator, thread_id, body);
    defer freeArgv(allocator, argv);
    return runGhCapture(allocator, argv, "gh api graphql (addPullRequestReviewThreadReply)");
}

/// Mark a review thread resolved. Idempotent server-side (resolving an already
/// resolved thread returns `isResolved: true`). Parse with `parseResolveResult`.
pub fn resolveThread(allocator: std.mem.Allocator, thread_id: []const u8) !GhFetch {
    const argv = try buildResolveArgs(allocator, resolve_thread_mutation, thread_id);
    defer freeArgv(allocator, argv);
    return runGhCapture(allocator, argv, "gh api graphql (resolveReviewThread)");
}

/// Mark a review thread unresolved. Parse with `parseResolveResult`.
pub fn unresolveThread(allocator: std.mem.Allocator, thread_id: []const u8) !GhFetch {
    const argv = try buildResolveArgs(allocator, unresolve_thread_mutation, thread_id);
    defer freeArgv(allocator, argv);
    return runGhCapture(allocator, argv, "gh api graphql (unresolveReviewThread)");
}

/// Edit a review comment's body. Parse with `review_parse.parseUpdatedComment`.
pub fn updateReviewComment(allocator: std.mem.Allocator, comment_node_id: []const u8, body: []const u8) !GhFetch {
    const argv = try buildUpdateCommentArgs(allocator, comment_node_id, body);
    defer freeArgv(allocator, argv);
    return runGhCapture(allocator, argv, "gh api graphql (updatePullRequestReviewComment)");
}

/// Delete a review comment. Parse/confirm with `review_parse.parseDeletedComment`.
pub fn deleteReviewComment(allocator: std.mem.Allocator, comment_node_id: []const u8) !GhFetch {
    const argv = try buildDeleteCommentArgs(allocator, comment_node_id);
    defer freeArgv(allocator, argv);
    return runGhCapture(allocator, argv, "gh api graphql (deletePullRequestReviewComment)");
}

fn buildReplyArgs(allocator: std.mem.Allocator, thread_id: []const u8, body: []const u8) ![][]const u8 {
    return buildGraphqlArgv(allocator, reply_mutation, &.{
        .{ .key = "tid", .value = thread_id },
        .{ .key = "body", .value = body },
    }, &.{});
}

fn buildSubmitReviewArgs(allocator: std.mem.Allocator, review_id: []const u8, event: []const u8, body: []const u8) ![][]const u8 {
    return buildGraphqlArgv(allocator, submit_review_mutation, &.{
        .{ .key = "rid", .value = review_id },
        .{ .key = "event", .value = event },
        .{ .key = "body", .value = body },
    }, &.{});
}

fn buildResolveArgs(allocator: std.mem.Allocator, mutation: []const u8, thread_id: []const u8) ![][]const u8 {
    return buildGraphqlArgv(allocator, mutation, &.{
        .{ .key = "tid", .value = thread_id },
    }, &.{});
}

fn buildUpdateCommentArgs(allocator: std.mem.Allocator, comment_node_id: []const u8, body: []const u8) ![][]const u8 {
    return buildGraphqlArgv(allocator, update_comment_mutation, &.{
        .{ .key = "cid", .value = comment_node_id },
        .{ .key = "body", .value = body },
    }, &.{});
}

fn buildDeleteCommentArgs(allocator: std.mem.Allocator, comment_node_id: []const u8) ![][]const u8 {
    return buildGraphqlArgv(allocator, delete_comment_mutation, &.{
        .{ .key = "cid", .value = comment_node_id },
    }, &.{});
}

fn buildCreateReviewArgs(allocator: std.mem.Allocator, pr_node_id: []const u8, commit_oid: []const u8) ![][]const u8 {
    return buildGraphqlArgv(allocator, create_review_mutation, &.{
        .{ .key = "prId", .value = pr_node_id },
        .{ .key = "oid", .value = commit_oid },
    }, &.{});
}

fn buildAddThreadArgs(allocator: std.mem.Allocator, params: AddThreadParams) ![][]const u8 {
    if (params.start_line) |sl| {
        return buildGraphqlArgv(allocator, add_thread_range_mutation, &.{
            .{ .key = "rid", .value = params.review_id },
            .{ .key = "path", .value = params.path },
            .{ .key = "side", .value = sideArg(params.side) },
            .{ .key = "ss", .value = sideArg(params.start_side) },
            .{ .key = "body", .value = params.body },
        }, &.{
            .{ .key = "line", .value = @intCast(params.line) },
            .{ .key = "sl", .value = @intCast(sl) },
        });
    }
    return buildGraphqlArgv(allocator, add_thread_mutation, &.{
        .{ .key = "rid", .value = params.review_id },
        .{ .key = "path", .value = params.path },
        .{ .key = "side", .value = sideArg(params.side) },
        .{ .key = "body", .value = params.body },
    }, &.{
        .{ .key = "line", .value = @intCast(params.line) },
    });
}

fn buildDeleteReviewArgs(allocator: std.mem.Allocator, review_id: []const u8) ![][]const u8 {
    return buildGraphqlArgv(allocator, delete_review_mutation, &.{
        .{ .key = "id", .value = review_id },
    }, &.{});
}

fn sideArg(side: review_parse.Side) []const u8 {
    return switch (side) {
        .left => "LEFT",
        .right => "RIGHT",
    };
}

/// Classify a gh failure from its exit code + stderr. Pure — string-matches the
/// real stderr forms gh 2.45.0 emits (see check-gh-errors.sh). Never sees the
/// missing-binary case (that surfaces as spawn error.FileNotFound -> not_installed).
pub fn classifyGhFailure(exit_code: u32, stderr: []const u8) GhErrorKind {
    _ = exit_code;
    if (containsIgnoreCase(stderr, "gh auth login")) return .not_authenticated;
    if (containsIgnoreCase(stderr, "Bad credentials")) return .not_authenticated;
    if (containsIgnoreCase(stderr, "HTTP 401")) return .not_authenticated;
    if (containsIgnoreCase(stderr, "API rate limit")) return .rate_limited;
    if (containsIgnoreCase(stderr, "Could not resolve to a")) return .not_found;
    if (containsIgnoreCase(stderr, "check your internet connection")) return .network;
    if (containsIgnoreCase(stderr, "error connecting to")) return .network;
    if (containsIgnoreCase(stderr, "dial tcp")) return .network;
    return .other;
}

/// Short, actionable status-bar message for a gh failure kind (AD-8).
pub fn kindMessage(kind: GhErrorKind) []const u8 {
    return switch (kind) {
        .not_installed => "gh not found — review features unavailable",
        .not_authenticated => "gh: not authenticated — run gh auth login",
        .not_found => "PR not found on GitHub",
        .rate_limited => "GitHub API rate limit reached — try again later",
        .network => "network error reaching GitHub",
        .other => "failed to load review data from gh",
    };
}

fn runGhCapture(allocator: std.mem.Allocator, argv: []const []const u8, label: []const u8) !GhFetch {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 16 * 1024 * 1024,
    }) catch |err| switch (err) {
        error.FileNotFound => return .{ .failed = .not_installed },
        else => return err,
    };
    errdefer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const code: u32 = switch (result.term) {
        .Exited => |c| c,
        else => 1,
    };
    if (code != 0) {
        std.log.err("{s} failed ({d}): {s}", .{ label, code, result.stderr });
        allocator.free(result.stdout);
        return .{ .failed = classifyGhFailure(code, result.stderr) };
    }
    return .{ .ok = result.stdout };
}

/// Like `runGhCapture`, but preserves the stdout GraphQL body on a nonzero exit
/// when that body is a 200-with-errors envelope. GitHub returns HTTP 200 with an
/// `errors` array for domain rejections (e.g. approving your own PR); `gh` still
/// exits nonzero and prints the envelope to stdout. Returning it as `.ok` lets
/// the caller's parser surface the real, human-readable rejection message rather
/// than a generic classified error (FR-6/AD-8). Genuine transport failures (no
/// errors envelope on stdout) still return `.failed`.
fn runGhCaptureAllowErrorBody(allocator: std.mem.Allocator, argv: []const []const u8, label: []const u8) !GhFetch {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 16 * 1024 * 1024,
    }) catch |err| switch (err) {
        error.FileNotFound => return .{ .failed = .not_installed },
        else => return err,
    };
    errdefer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const code: u32 = switch (result.term) {
        .Exited => |c| c,
        else => 1,
    };
    if (code != 0) {
        std.log.err("{s} failed ({d}): {s}", .{ label, code, result.stderr });
        if (std.mem.indexOf(u8, result.stdout, "\"errors\"") != null) {
            return .{ .ok = result.stdout };
        }
        allocator.free(result.stdout);
        return .{ .failed = classifyGhFailure(code, result.stderr) };
    }
    return .{ .ok = result.stdout };
}

fn buildGraphqlArgv(allocator: std.mem.Allocator, query: []const u8, string_vars: []const KV, int_vars: []const KVInt) ![][]const u8 {
    var argv: std.ArrayList([]const u8) = .{};
    errdefer freeArgv(allocator, argv.items);

    try argv.append(allocator, try allocator.dupe(u8, "gh"));
    try argv.append(allocator, try allocator.dupe(u8, "api"));
    try argv.append(allocator, try allocator.dupe(u8, "graphql"));
    try argv.append(allocator, try allocator.dupe(u8, "-f"));
    try argv.append(allocator, try std.fmt.allocPrint(allocator, "query={s}", .{query}));

    for (string_vars) |kv| {
        try argv.append(allocator, try allocator.dupe(u8, "-f"));
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "{s}={s}", .{ kv.key, kv.value }));
    }
    for (int_vars) |kv| {
        try argv.append(allocator, try allocator.dupe(u8, "-F"));
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "{s}={d}", .{ kv.key, kv.value }));
    }

    return argv.toOwnedSlice(allocator);
}

fn freeArgv(allocator: std.mem.Allocator, argv: [][]const u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Run a git command and return its single trimmed line of stdout, or null on
/// any failure/empty output. Mirrors `cache.zig`'s helper (kept private there).
fn gitLine(allocator: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const ok = switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!ok) return null;

    const trimmed = std.mem.trimRight(u8, result.stdout, " \r\n");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}

fn runGit(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
    }) catch |err| switch (err) {
        error.FileNotFound => return Error.GhNotFound,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) {
            std.log.err("git fetch failed ({d}): {s}", .{ code, result.stderr });
            return Error.GhCommandFailed;
        },
        else => return Error.GhCommandFailed,
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn expectOwnerRepo(url: []const u8, owner: []const u8, repo: []const u8) !void {
    const or_ = try parseOwnerRepo(testing.allocator, url);
    defer testing.allocator.free(or_.owner);
    defer testing.allocator.free(or_.repo);
    try testing.expectEqualStrings(owner, or_.owner);
    try testing.expectEqualStrings(repo, or_.repo);
}

test "parseOwnerRepo: scp form with .git" {
    try expectOwnerRepo("git@github.com:ctdio/skim.git", "ctdio", "skim");
}

test "parseOwnerRepo: scp form without .git (live origin form)" {
    try expectOwnerRepo("git@github.com:ctdio/skim", "ctdio", "skim");
}

test "parseOwnerRepo: https form with .git" {
    try expectOwnerRepo("https://github.com/ctdio/skim.git", "ctdio", "skim");
}

test "parseOwnerRepo: https form without .git" {
    try expectOwnerRepo("https://github.com/ctdio/skim", "ctdio", "skim");
}

test "parseOwnerRepo: trailing slash tolerated" {
    try expectOwnerRepo("https://github.com/ctdio/skim/", "ctdio", "skim");
}

test "parseOwnerRepo: surrounding whitespace trimmed" {
    try expectOwnerRepo("  git@github.com:ctdio/skim.git\n", "ctdio", "skim");
}

test "parseOwnerRepo: ssh:// URL form" {
    try expectOwnerRepo("ssh://git@github.com/ctdio/skim.git", "ctdio", "skim");
}

test "parseOwnerRepo: rejects non-github url" {
    try testing.expectError(error.InvalidRemoteUrl, parseOwnerRepo(testing.allocator, "https://gitlab.com/ctdio/skim.git"));
}

test "parseOwnerRepo: rejects garbage" {
    try testing.expectError(error.InvalidRemoteUrl, parseOwnerRepo(testing.allocator, "not a url"));
}

test "parseOwnerRepo: rejects missing repo segment" {
    try testing.expectError(error.InvalidRemoteUrl, parseOwnerRepo(testing.allocator, "git@github.com:ctdio"));
}

test "parseOwnerRepo: rejects extra path segments" {
    try testing.expectError(error.InvalidRemoteUrl, parseOwnerRepo(testing.allocator, "https://github.com/ctdio/skim/extra"));
}

test "parsePrArg: bare number" {
    const request = try parsePrArg("42");
    try testing.expectEqual(@as(u32, 42), request.number);
}

test "parsePrArg: zero is rejected" {
    try testing.expectError(error.InvalidPrArg, parsePrArg("0"));
}

test "parsePrArg: non-numeric is rejected" {
    try testing.expectError(error.InvalidPrArg, parsePrArg("abc"));
}

test "parsePrArg: negative is rejected" {
    try testing.expectError(error.InvalidPrArg, parsePrArg("-3"));
}

test "parsePrArg: full github PR url" {
    const request = try parsePrArg("https://github.com/ctdio/skim/pull/42");
    try testing.expectEqualStrings("ctdio", request.url.owner);
    try testing.expectEqualStrings("skim", request.url.repo);
    try testing.expectEqual(@as(u32, 42), request.url.number);
}

test "parsePrArg: url with trailing /files segment" {
    const request = try parsePrArg("https://github.com/ctdio/skim/pull/42/files");
    try testing.expectEqual(@as(u32, 42), request.url.number);
    try testing.expectEqualStrings("skim", request.url.repo);
}

test "parsePrArg: url with query string" {
    const request = try parsePrArg("https://github.com/ctdio/skim/pull/42?diff=split");
    try testing.expectEqual(@as(u32, 42), request.url.number);
}

test "parsePrArg: url missing pull segment is rejected" {
    try testing.expectError(error.InvalidPrArg, parsePrArg("https://github.com/ctdio/skim/issues/42"));
}

test "parsePrArg: url with non-numeric pr number is rejected" {
    try testing.expectError(error.InvalidPrArg, parsePrArg("https://github.com/ctdio/skim/pull/abc"));
}

test "parsePrArg: empty string is rejected" {
    try testing.expectError(error.InvalidPrArg, parsePrArg(""));
}

test "parsePrArg: url with trailing pull slash and no number is rejected" {
    try testing.expectError(error.InvalidPrArg, parsePrArg("https://github.com/ctdio/skim/pull/"));
}

test "classifyGhFailure: bare HTTP 401 without Bad credentials" {
    try testing.expectEqual(GhErrorKind.not_authenticated, classifyGhFailure(1, "gh: request failed (HTTP 401)"));
}

test "classifyGhFailure: no-auth form" {
    try testing.expectEqual(GhErrorKind.not_authenticated, classifyGhFailure(4, "gh auth login required to run this command"));
}

test "classifyGhFailure: bad-token form" {
    try testing.expectEqual(GhErrorKind.not_authenticated, classifyGhFailure(1, "gh: Bad credentials (HTTP 401)"));
}

test "classifyGhFailure: not found (PullRequest)" {
    try testing.expectEqual(GhErrorKind.not_found, classifyGhFailure(1, "GraphQL: Could not resolve to a PullRequest with the number of 999999999."));
}

test "classifyGhFailure: not found (Repository)" {
    try testing.expectEqual(GhErrorKind.not_found, classifyGhFailure(1, "Could not resolve to a Repository with the name 'o/no-such'."));
}

test "classifyGhFailure: rate limited" {
    try testing.expectEqual(GhErrorKind.rate_limited, classifyGhFailure(1, "API rate limit exceeded for user ID 1."));
}

test "classifyGhFailure: network" {
    try testing.expectEqual(GhErrorKind.network, classifyGhFailure(1, "error connecting to api.github.com"));
}

test "classifyGhFailure: unknown falls through to other" {
    try testing.expectEqual(GhErrorKind.other, classifyGhFailure(1, "some unexpected message"));
}

fn argvContains(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |a| {
        if (std.mem.eql(u8, a, needle)) return true;
    }
    return false;
}

test "buildCreateReviewArgs: carries pullRequestId + commitOID, omits event" {
    const argv = try buildCreateReviewArgs(testing.allocator, "PR_node", "deadbeef");
    defer freeArgv(testing.allocator, argv);
    try testing.expect(argvContains(argv, "prId=PR_node"));
    try testing.expect(argvContains(argv, "oid=deadbeef"));
    // event must never be sent — sending one submits the review immediately.
    for (argv) |a| try testing.expect(!std.mem.startsWith(u8, a, "event="));
    // The query itself must not mention an event.
    try testing.expect(std.mem.indexOf(u8, argv[4], "event") == null);
}

test "buildAddThreadArgs: hostile single-line body survives verbatim as -f body=" {
    const hostile = "line one \"quote\" %s émoji 🎉\nsecond `backtick` & <html>";
    const argv = try buildAddThreadArgs(testing.allocator, .{
        .review_id = "PRR_1",
        .path = "README.md",
        .line = 655,
        .side = .right,
        .body = hostile,
    });
    defer freeArgv(testing.allocator, argv);

    const expected_body = "body=" ++ "line one \"quote\" %s émoji 🎉\nsecond `backtick` & <html>";
    try testing.expect(argvContains(argv, expected_body));
    try testing.expect(argvContains(argv, "path=README.md"));
    try testing.expect(argvContains(argv, "side=RIGHT"));
    try testing.expect(argvContains(argv, "line=655"));
    try testing.expect(argvContains(argv, "rid=PRR_1"));
    // single-line → no startLine / startSide
    for (argv) |a| {
        try testing.expect(!std.mem.startsWith(u8, a, "sl="));
        try testing.expect(!std.mem.startsWith(u8, a, "ss="));
    }
}

test "buildAddThreadArgs: range variant carries startLine + startSide" {
    const argv = try buildAddThreadArgs(testing.allocator, .{
        .review_id = "PRR_1",
        .path = "README.md",
        .line = 658,
        .side = .right,
        .start_line = 656,
        .start_side = .left,
        .body = "range",
    });
    defer freeArgv(testing.allocator, argv);
    try testing.expect(argvContains(argv, "line=658"));
    try testing.expect(argvContains(argv, "sl=656"));
    try testing.expect(argvContains(argv, "ss=LEFT"));
    try testing.expect(argvContains(argv, "side=RIGHT"));
}

test "buildDeleteReviewArgs: carries the review id" {
    const argv = try buildDeleteReviewArgs(testing.allocator, "PRR_del");
    defer freeArgv(testing.allocator, argv);
    try testing.expect(argvContains(argv, "id=PRR_del"));
    try testing.expect(std.mem.indexOf(u8, argv[4], "deletePullRequestReview") != null);
}

test "buildSubmitReviewArgs: carries review id, event, and hostile body verbatim" {
    const hostile = "ship it \"quote\" %s émoji 🚀\nsecond `backtick` & <html>";
    const argv = try buildSubmitReviewArgs(testing.allocator, "PRR_1", "COMMENT", hostile);
    defer freeArgv(testing.allocator, argv);
    try testing.expect(argvContains(argv, "rid=PRR_1"));
    try testing.expect(argvContains(argv, "event=COMMENT"));
    try testing.expect(argvContains(argv, "body=" ++ "ship it \"quote\" %s émoji 🚀\nsecond `backtick` & <html>"));
    try testing.expect(std.mem.indexOf(u8, argv[4], "submitPullRequestReview") != null);
    // event must be bound as a typed enum variable, not baked into the query text.
    try testing.expect(std.mem.indexOf(u8, argv[4], "PullRequestReviewEvent!") != null);
}

test "buildSubmitReviewArgs: approve event carries verbatim" {
    const argv = try buildSubmitReviewArgs(testing.allocator, "PRR_2", "APPROVE", "");
    defer freeArgv(testing.allocator, argv);
    try testing.expect(argvContains(argv, "event=APPROVE"));
    try testing.expect(argvContains(argv, "body="));
}

test "buildReplyArgs: carries thread id + hostile body verbatim" {
    const hostile = "reply \"quote\" %s émoji 🎯\nsecond `backtick` & <html>";
    const argv = try buildReplyArgs(testing.allocator, "PRRT_1", hostile);
    defer freeArgv(testing.allocator, argv);
    try testing.expect(argvContains(argv, "tid=PRRT_1"));
    try testing.expect(argvContains(argv, "body=" ++ "reply \"quote\" %s émoji 🎯\nsecond `backtick` & <html>"));
    try testing.expect(std.mem.indexOf(u8, argv[4], "addPullRequestReviewThreadReply") != null);
}

test "buildResolveArgs: resolve carries thread id and mutation name" {
    const argv = try buildResolveArgs(testing.allocator, resolve_thread_mutation, "PRRT_9");
    defer freeArgv(testing.allocator, argv);
    try testing.expect(argvContains(argv, "tid=PRRT_9"));
    try testing.expect(std.mem.indexOf(u8, argv[4], "resolveReviewThread") != null);
    try testing.expect(std.mem.indexOf(u8, argv[4], "unresolveReviewThread") == null);
}

test "buildResolveArgs: unresolve uses the unresolve mutation" {
    const argv = try buildResolveArgs(testing.allocator, unresolve_thread_mutation, "PRRT_9");
    defer freeArgv(testing.allocator, argv);
    try testing.expect(std.mem.indexOf(u8, argv[4], "unresolveReviewThread") != null);
}

test "buildUpdateCommentArgs: carries comment id + body verbatim" {
    const argv = try buildUpdateCommentArgs(testing.allocator, "PRRC_7", "edited 100% 🔁");
    defer freeArgv(testing.allocator, argv);
    try testing.expect(argvContains(argv, "cid=PRRC_7"));
    try testing.expect(argvContains(argv, "body=edited 100% 🔁"));
    try testing.expect(std.mem.indexOf(u8, argv[4], "updatePullRequestReviewComment") != null);
}

test "buildDeleteCommentArgs: carries comment id and mutation name" {
    const argv = try buildDeleteCommentArgs(testing.allocator, "PRRC_del");
    defer freeArgv(testing.allocator, argv);
    try testing.expect(argvContains(argv, "cid=PRRC_del"));
    try testing.expect(std.mem.indexOf(u8, argv[4], "deletePullRequestReviewComment") != null);
}

test "buildGraphqlArgv: mirrors gh api graphql -f/-F shape" {
    const argv = try buildGraphqlArgv(testing.allocator, "QUERY", &.{
        .{ .key = "owner", .value = "ctdio" },
        .{ .key = "name", .value = "skim" },
    }, &.{
        .{ .key = "number", .value = 42 },
    });
    defer freeArgv(testing.allocator, argv);

    try testing.expectEqual(@as(usize, 11), argv.len);
    try testing.expectEqualStrings("gh", argv[0]);
    try testing.expectEqualStrings("api", argv[1]);
    try testing.expectEqualStrings("graphql", argv[2]);
    try testing.expectEqualStrings("-f", argv[3]);
    try testing.expectEqualStrings("query=QUERY", argv[4]);
    try testing.expectEqualStrings("-f", argv[5]);
    try testing.expectEqualStrings("owner=ctdio", argv[6]);
    try testing.expectEqualStrings("-f", argv[7]);
    try testing.expectEqualStrings("name=skim", argv[8]);
    try testing.expectEqualStrings("-F", argv[9]);
    try testing.expectEqualStrings("number=42", argv[10]);
}
