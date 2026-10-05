//! Pure reconstruction of stacked-PR groups from the open PR list. A PR is
//! "stacked on" another exactly when its base branch is that other PR's head
//! branch (`B.base_ref == A.head_ref`) — so the whole stack DAG falls out of
//! data we already have from `gh pr list`, with no `gt` dependency. Graphite
//! enrichment (restack status, ordering) layers on top elsewhere; this is the
//! forge-native core, and it works for anyone using stacked PRs.
//!
//! Bytes in (the loaded PRs), owned analysis out — so stack grouping is a tested
//! unit, independent of any rendering or the picker.

const std = @import("std");
const parse = @import("parse.zig");

const PullRequest = parse.PullRequest;

/// Where a PR sits in its stack, for drawing the connector glyph in the list.
/// `none` = standalone (a single-PR "stack"); the rest assume stack members are
/// rendered contiguously tip-first (see `displayOrder`).
pub const Mark = enum {
    none,
    top, // the tip of the stack
    middle,
    bottom, // the trunk-side base of the stack
};

/// One PR's branch relationship: it is stacked on the PR whose `head_ref`
/// equals its `base_ref`. Callers that know better parentage (Graphite) put
/// the authoritative parent branch in `base_ref`.
pub const Edge = struct {
    head_ref: []const u8,
    base_ref: []const u8,
};

/// Per-PR placement within its stack, indexed in lockstep with the input PRs.
pub const Analysis = struct {
    /// Stack id each PR belongs to (PRs sharing an id are one connected stack).
    stack_of: []usize,
    /// 0-based position from the bottom (trunk side) of the PR's stack.
    depth_of: []usize,
    /// Number of PRs in each stack, indexed by stack id.
    heights: []usize,
    /// Index of the PR this one is stacked on (its base is that PR's head), or
    /// null when its base is trunk / an unlisted branch.
    parent_of: []?usize,

    pub fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
        allocator.free(self.stack_of);
        allocator.free(self.depth_of);
        allocator.free(self.heights);
        allocator.free(self.parent_of);
    }

    /// Is this PR part of a multi-PR stack (vs. standalone)?
    pub fn isStacked(self: *const Analysis, index: usize) bool {
        return self.heights[self.stack_of[index]] > 1;
    }

    /// The connector glyph this PR should show, assuming the stack is rendered
    /// contiguously tip-first.
    pub fn markOf(self: *const Analysis, index: usize) Mark {
        const height = self.heights[self.stack_of[index]];
        if (height <= 1) return .none;
        const depth = self.depth_of[index];
        if (depth == height - 1) return .top;
        if (depth == 0) return .bottom;
        return .middle;
    }
};

/// A display order over `prs` that keeps each stack's members contiguous and
/// tip-first (highest depth first), with stacks appearing at the position of
/// their earliest member in the input. Standalone PRs keep their relative
/// order. Caller owns the returned slice. This is what makes the connector
/// glyphs read as a connected stack.
pub fn displayOrder(allocator: std.mem.Allocator, prs: []const PullRequest, analysis: Analysis) ![]usize {
    std.debug.assert(prs.len == analysis.stack_of.len);
    return displayOrderOf(allocator, analysis);
}

/// `displayOrder` over an analysis alone (it never needed the PRs). Members are
/// bucketed per stack and stably sorted deepest-first, so equal depths keep
/// input order and the whole pass is O(n log n).
pub fn displayOrderOf(allocator: std.mem.Allocator, analysis: Analysis) ![]usize {
    const n = analysis.stack_of.len;
    const stack_count = analysis.heights.len;

    // bucket_start[s]..bucket_start[s + 1] is stack s's slice of `members`.
    const bucket_start = try allocator.alloc(usize, stack_count + 1);
    defer allocator.free(bucket_start);
    bucket_start[0] = 0;
    for (analysis.heights, 0..) |height, sid| bucket_start[sid + 1] = bucket_start[sid] + height;

    const members = try allocator.alloc(usize, n);
    defer allocator.free(members);
    const fill = try allocator.alloc(usize, stack_count);
    defer allocator.free(fill);
    @memcpy(fill, bucket_start[0..stack_count]);
    for (analysis.stack_of, 0..) |sid, i| {
        members[fill[sid]] = i;
        fill[sid] += 1;
    }
    for (0..stack_count) |sid| {
        std.sort.block(usize, members[bucket_start[sid]..bucket_start[sid + 1]], analysis.depth_of, deeperFirst);
    }

    const out = try allocator.alloc(usize, n);
    errdefer allocator.free(out);
    const emitted = try allocator.alloc(bool, stack_count);
    defer allocator.free(emitted);
    @memset(emitted, false);

    var w: usize = 0;
    for (analysis.stack_of) |sid| {
        if (emitted[sid]) continue;
        emitted[sid] = true;
        const bucket = members[bucket_start[sid]..bucket_start[sid + 1]];
        @memcpy(out[w..][0..bucket.len], bucket);
        w += bucket.len;
    }
    return out;
}

/// Group `prs` into stacks by their base->head relationships. Caller owns the
/// returned analysis. Robust to cycles (a malformed base/head loop degrades to
/// each involved PR being its own root rather than looping forever).
pub fn analyze(allocator: std.mem.Allocator, prs: []const PullRequest) !Analysis {
    return analyzeWith(allocator, prs, null);
}

/// Like `analyze`, but when `parent_branches` is supplied (one optional parent
/// branch name per PR, in lockstep with `prs`) that authoritative name drives
/// parentage instead of the PR's `base_ref`. Graphite's own stack metadata flows
/// in this way, which avoids the false chains a shared base branch creates in the
/// forge-native heuristic (many PRs sharing a base that is also some PR's head
/// would otherwise collapse into one giant stack). A null entry falls back to
/// that PR's `base_ref`, so PRs Graphite doesn't track still group forge-natively.
pub fn analyzeWith(
    allocator: std.mem.Allocator,
    prs: []const PullRequest,
    parent_branches: ?[]const ?[]const u8,
) !Analysis {
    const edges = try allocator.alloc(Edge, prs.len);
    defer allocator.free(edges);
    for (prs, edges, 0..) |pr, *edge, i| {
        const parent = if (parent_branches) |pb| pb[i] else null;
        edge.* = .{ .head_ref = pr.head_ref, .base_ref = parent orelse pr.base_ref };
    }
    return analyzeEdges(allocator, edges);
}

/// Group PRs, given as edges in input order, into stacks. Caller owns the
/// returned analysis. Robust to cycles (a malformed base/head loop degrades to
/// each involved PR being its own root rather than looping forever).
pub fn analyzeEdges(allocator: std.mem.Allocator, edges: []const Edge) !Analysis {
    const n = edges.len;

    var parent_of = try allocator.alloc(?usize, n);
    errdefer allocator.free(parent_of);
    var stack_of = try allocator.alloc(usize, n);
    errdefer allocator.free(stack_of);
    var depth_of = try allocator.alloc(usize, n);
    errdefer allocator.free(depth_of);

    // head branch -> PR index. First spelling wins if a branch somehow repeats.
    var head_to_pr = std.StringHashMap(usize).init(allocator);
    defer head_to_pr.deinit();
    for (edges, 0..) |edge, i| {
        if (edge.head_ref.len == 0) continue;
        if (!head_to_pr.contains(edge.head_ref)) try head_to_pr.put(edge.head_ref, i);
    }

    // Initialize every parent to null up front: the cycle check below walks
    // parent links across the whole array, so all entries must be readable
    // before any are computed.
    for (0..n) |i| parent_of[i] = null;

    // parent = the open PR whose head is this PR's base branch (Graphite's
    // parent when the caller knew it, else the GitHub base_ref). A PR is never
    // its own parent (a base==head PR is treated as a root).
    for (edges, 0..) |edge, i| {
        if (edge.base_ref.len == 0) continue;
        if (head_to_pr.get(edge.base_ref)) |p| {
            if (p != i and !isAncestor(parent_of, p, i)) parent_of[i] = p;
        }
    }

    var heights: std.ArrayList(usize) = .empty;
    errdefer heights.deinit(allocator);

    // Two passes keep ids stable and contiguous: number roots in input order,
    // then label every PR by its root's id and compute depth.
    var root_id = std.AutoHashMap(usize, usize).init(allocator);
    defer root_id.deinit();
    for (0..n) |i| {
        if (parent_of[i] == null) {
            const id = heights.items.len;
            try root_id.put(i, id);
            try heights.append(allocator, 0);
        }
    }
    for (0..n) |i| {
        const root = rootOf(parent_of, i);
        const id = root_id.get(root).?;
        stack_of[i] = id;
        depth_of[i] = depthFromRoot(parent_of, i);
        heights.items[id] += 1;
    }

    return .{
        .stack_of = stack_of,
        .depth_of = depth_of,
        .heights = try heights.toOwnedSlice(allocator),
        .parent_of = parent_of,
    };
}

// =============================================================================
// Helpers
// =============================================================================

fn rootOf(parent_of: []const ?usize, start: usize) usize {
    var cur = start;
    var guard: usize = 0;
    while (parent_of[cur]) |p| {
        cur = p;
        guard += 1;
        if (guard > parent_of.len) break; // cycle guard (shouldn't trigger)
    }
    return cur;
}

fn depthFromRoot(parent_of: []const ?usize, start: usize) usize {
    var cur = start;
    var depth: usize = 0;
    while (parent_of[cur]) |p| {
        cur = p;
        depth += 1;
        if (depth > parent_of.len) break;
    }
    return depth;
}

fn deeperFirst(depth_of: []const usize, a: usize, b: usize) bool {
    return depth_of[a] > depth_of[b];
}

/// Would making `candidate_parent` the parent of `child` create a cycle — i.e.
/// is `child` already an ancestor of `candidate_parent`?
fn isAncestor(parent_of: []const ?usize, candidate_parent: usize, child: usize) bool {
    var cur: ?usize = candidate_parent;
    var guard: usize = 0;
    while (cur) |c| {
        if (c == child) return true;
        cur = parent_of[c];
        guard += 1;
        if (guard > parent_of.len) break;
    }
    return false;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn samplePr(params: struct { number: u32, head: []const u8, base: []const u8 }) PullRequest {
    return .{
        .number = params.number,
        .title = "t",
        .author = "a",
        .head_ref = params.head,
        .base_ref = params.base,
        .is_draft = false,
        .updated_at = "",
        .url = "",
        .ci = .none,
    };
}

test "analyze: standalone PRs each form their own single-PR stack" {
    const prs = [_]PullRequest{
        samplePr(.{ .number = 1, .head = "feat-a", .base = "main" }),
        samplePr(.{ .number = 2, .head = "feat-b", .base = "main" }),
    };
    var a = try analyze(testing.allocator, &prs);
    defer a.deinit(testing.allocator);

    try testing.expect(!a.isStacked(0));
    try testing.expect(!a.isStacked(1));
    try testing.expect(a.stack_of[0] != a.stack_of[1]);
    try testing.expectEqual(@as(?usize, null), a.parent_of[0]);
    try testing.expectEqual(@as(?usize, null), a.parent_of[1]);
}

test "analyze: a base matching another PR's head links them into one stack" {
    // #10 main<-feat ; #11 feat<-feat2 ; #12 feat2<-feat3 (bottom -> tip)
    const prs = [_]PullRequest{
        samplePr(.{ .number = 10, .head = "feat", .base = "main" }),
        samplePr(.{ .number = 11, .head = "feat2", .base = "feat" }),
        samplePr(.{ .number = 12, .head = "feat3", .base = "feat2" }),
    };
    var a = try analyze(testing.allocator, &prs);
    defer a.deinit(testing.allocator);

    try testing.expectEqual(a.stack_of[0], a.stack_of[1]);
    try testing.expectEqual(a.stack_of[1], a.stack_of[2]);
    try testing.expectEqual(@as(usize, 3), a.heights[a.stack_of[0]]);
    try testing.expect(a.isStacked(0));

    try testing.expectEqual(@as(?usize, null), a.parent_of[0]);
    try testing.expectEqual(@as(?usize, 0), a.parent_of[1]);
    try testing.expectEqual(@as(?usize, 1), a.parent_of[2]);

    try testing.expectEqual(@as(usize, 0), a.depth_of[0]);
    try testing.expectEqual(@as(usize, 1), a.depth_of[1]);
    try testing.expectEqual(@as(usize, 2), a.depth_of[2]);
}

test "analyze: stack detection is independent of input order" {
    // Same stack as above but listed tip-first.
    const prs = [_]PullRequest{
        samplePr(.{ .number = 12, .head = "feat3", .base = "feat2" }),
        samplePr(.{ .number = 11, .head = "feat2", .base = "feat" }),
        samplePr(.{ .number = 10, .head = "feat", .base = "main" }),
    };
    var a = try analyze(testing.allocator, &prs);
    defer a.deinit(testing.allocator);

    try testing.expectEqual(a.stack_of[0], a.stack_of[2]);
    try testing.expectEqual(@as(usize, 3), a.heights[a.stack_of[0]]);
    // #10 (index 2) is the bottom.
    try testing.expectEqual(@as(usize, 0), a.depth_of[2]);
    try testing.expectEqual(@as(usize, 2), a.depth_of[0]);
    try testing.expectEqual(@as(?usize, 2), a.parent_of[1]);
}

test "analyze: separate stacks get distinct ids" {
    const prs = [_]PullRequest{
        samplePr(.{ .number = 1, .head = "a2", .base = "a1" }),
        samplePr(.{ .number = 2, .head = "a1", .base = "main" }),
        samplePr(.{ .number = 3, .head = "b1", .base = "main" }),
    };
    var a = try analyze(testing.allocator, &prs);
    defer a.deinit(testing.allocator);

    try testing.expectEqual(a.stack_of[0], a.stack_of[1]);
    try testing.expect(a.stack_of[0] != a.stack_of[2]);
    try testing.expect(a.isStacked(0));
    try testing.expect(!a.isStacked(2));
}

test "analyze: a base==head self-loop is treated as a root, not a cycle" {
    const prs = [_]PullRequest{
        samplePr(.{ .number = 1, .head = "x", .base = "x" }),
    };
    var a = try analyze(testing.allocator, &prs);
    defer a.deinit(testing.allocator);

    try testing.expectEqual(@as(?usize, null), a.parent_of[0]);
    try testing.expectEqual(@as(usize, 0), a.depth_of[0]);
    try testing.expect(!a.isStacked(0));
}

test "analyze: a two-PR cycle does not loop forever" {
    // Malformed: A's base is B's head and B's base is A's head.
    const prs = [_]PullRequest{
        samplePr(.{ .number = 1, .head = "p", .base = "q" }),
        samplePr(.{ .number = 2, .head = "q", .base = "p" }),
    };
    var a = try analyze(testing.allocator, &prs);
    defer a.deinit(testing.allocator);

    // One edge is kept, the back-edge is dropped to break the cycle, so the two
    // still land in one stack with a clear bottom.
    try testing.expectEqual(a.stack_of[0], a.stack_of[1]);
    try testing.expectEqual(@as(usize, 2), a.heights[a.stack_of[0]]);
}

test "analyze: empty list yields empty analysis" {
    var a = try analyze(testing.allocator, &.{});
    defer a.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), a.stack_of.len);
    try testing.expectEqual(@as(usize, 0), a.heights.len);
}

test "markOf: tip/middle/bottom for a stack, none for standalone" {
    const prs = [_]PullRequest{
        samplePr(.{ .number = 10, .head = "feat", .base = "main" }), // bottom
        samplePr(.{ .number = 11, .head = "feat2", .base = "feat" }), // middle
        samplePr(.{ .number = 12, .head = "feat3", .base = "feat2" }), // tip
        samplePr(.{ .number = 7, .head = "solo", .base = "main" }), // standalone
    };
    var a = try analyze(testing.allocator, &prs);
    defer a.deinit(testing.allocator);

    try testing.expectEqual(Mark.bottom, a.markOf(0));
    try testing.expectEqual(Mark.middle, a.markOf(1));
    try testing.expectEqual(Mark.top, a.markOf(2));
    try testing.expectEqual(Mark.none, a.markOf(3));
}

test "analyzeWith: graphite parents override a misleading base_ref" {
    // Both feature PRs list `shared` as their base, and a PR's head is `shared`,
    // so the forge-native heuristic would chain all three into one stack. Graphite
    // says both features branch off trunk (`main`), so they must stay standalone.
    const prs = [_]PullRequest{
        samplePr(.{ .number = 1, .head = "shared", .base = "main" }),
        samplePr(.{ .number = 2, .head = "feat-a", .base = "shared" }),
        samplePr(.{ .number = 3, .head = "feat-b", .base = "shared" }),
    };
    const parents = [_]?[]const u8{ "main", "main", "main" };
    var a = try analyzeWith(testing.allocator, &prs, &parents);
    defer a.deinit(testing.allocator);

    try testing.expect(!a.isStacked(0));
    try testing.expect(!a.isStacked(1));
    try testing.expect(!a.isStacked(2));
    try testing.expectEqual(@as(?usize, null), a.parent_of[1]);
    try testing.expectEqual(@as(?usize, null), a.parent_of[2]);
}

test "analyzeWith: a null parent entry falls back to base_ref" {
    // #1 is untracked by graphite (null) so it links via base_ref; #2 is tracked
    // and points at #1's head. The two form one stack.
    const prs = [_]PullRequest{
        samplePr(.{ .number = 1, .head = "feat", .base = "main" }),
        samplePr(.{ .number = 2, .head = "feat2", .base = "feat" }),
    };
    const parents = [_]?[]const u8{ null, "feat" };
    var a = try analyzeWith(testing.allocator, &prs, &parents);
    defer a.deinit(testing.allocator);

    try testing.expectEqual(a.stack_of[0], a.stack_of[1]);
    try testing.expectEqual(@as(?usize, 0), a.parent_of[1]);
}

test "displayOrder: groups a stack contiguously, tip first" {
    // Input is bottom->tip; display should be tip->bottom and contiguous.
    const prs = [_]PullRequest{
        samplePr(.{ .number = 10, .head = "feat", .base = "main" }),
        samplePr(.{ .number = 11, .head = "feat2", .base = "feat" }),
        samplePr(.{ .number = 12, .head = "feat3", .base = "feat2" }),
    };
    var a = try analyze(testing.allocator, &prs);
    defer a.deinit(testing.allocator);

    const order = try displayOrder(testing.allocator, &prs, a);
    defer testing.allocator.free(order);
    try testing.expectEqualSlices(usize, &.{ 2, 1, 0 }, order);
}

test "displayOrder: standalone PRs keep their relative order" {
    const prs = [_]PullRequest{
        samplePr(.{ .number = 1, .head = "a", .base = "main" }),
        samplePr(.{ .number = 2, .head = "b", .base = "main" }),
        samplePr(.{ .number = 3, .head = "c", .base = "main" }),
    };
    var a = try analyze(testing.allocator, &prs);
    defer a.deinit(testing.allocator);

    const order = try displayOrder(testing.allocator, &prs, a);
    defer testing.allocator.free(order);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, order);
}

test "displayOrder: a stack surfaces at its earliest member, standalone interleaved" {
    // #9 standalone, then a 2-PR stack whose earliest member (the base) is at
    // index 1; the tip at index 2 is pulled up under it.
    const prs = [_]PullRequest{
        samplePr(.{ .number = 9, .head = "solo", .base = "main" }),
        samplePr(.{ .number = 10, .head = "feat", .base = "main" }),
        samplePr(.{ .number = 11, .head = "feat2", .base = "feat" }),
        samplePr(.{ .number = 8, .head = "solo2", .base = "main" }),
    };
    var a = try analyze(testing.allocator, &prs);
    defer a.deinit(testing.allocator);

    const order = try displayOrder(testing.allocator, &prs, a);
    defer testing.allocator.free(order);
    // 9 (solo), then stack tip 11 then base 10, then 8 (solo).
    try testing.expectEqualSlices(usize, &.{ 0, 2, 1, 3 }, order);
}

test "analyzeEdges groups a three-edge chain into one stack with depths 0,1,2" {
    const edges = [_]Edge{
        .{ .head_ref = "feat", .base_ref = "main" },
        .{ .head_ref = "feat2", .base_ref = "feat" },
        .{ .head_ref = "feat3", .base_ref = "feat2" },
    };
    var a = try analyzeEdges(testing.allocator, &edges);
    defer a.deinit(testing.allocator);

    try testing.expectEqualSlices(usize, &.{ 0, 0, 0 }, a.stack_of);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, a.depth_of);
    try testing.expectEqualSlices(usize, &.{3}, a.heights);
    try testing.expectEqualSlices(?usize, &.{ null, 0, 1 }, a.parent_of);
}

test "analyzeEdges treats a base that matches no head as a root" {
    const edges = [_]Edge{
        .{ .head_ref = "feat", .base_ref = "release/9" },
        .{ .head_ref = "other", .base_ref = "main" },
    };
    var a = try analyzeEdges(testing.allocator, &edges);
    defer a.deinit(testing.allocator);

    try testing.expectEqualSlices(?usize, &.{ null, null }, a.parent_of);
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, a.stack_of);
    try testing.expectEqualSlices(usize, &.{ 1, 1 }, a.heights);
}

test "analyzeEdges is cycle-safe on a base/head loop" {
    const edges = [_]Edge{
        .{ .head_ref = "p", .base_ref = "q" },
        .{ .head_ref = "q", .base_ref = "p" },
    };
    var a = try analyzeEdges(testing.allocator, &edges);
    defer a.deinit(testing.allocator);

    try testing.expectEqual(a.stack_of[0], a.stack_of[1]);
    try testing.expectEqual(@as(usize, 2), a.heights[a.stack_of[0]]);
}

test "analyzeEdges ignores empty head_ref and base_ref" {
    // An empty head must not become a parent for an empty base.
    const edges = [_]Edge{
        .{ .head_ref = "", .base_ref = "main" },
        .{ .head_ref = "feat", .base_ref = "" },
    };
    var a = try analyzeEdges(testing.allocator, &edges);
    defer a.deinit(testing.allocator);

    try testing.expectEqualSlices(?usize, &.{ null, null }, a.parent_of);
    try testing.expectEqualSlices(usize, &.{ 1, 1 }, a.heights);
}

test "analyzeWith parent override equals analyzeEdges on edges built from the override" {
    const prs = [_]PullRequest{
        samplePr(.{ .number = 1, .head = "shared", .base = "main" }),
        samplePr(.{ .number = 2, .head = "feat-a", .base = "shared" }),
        samplePr(.{ .number = 3, .head = "feat-b", .base = "shared" }),
        samplePr(.{ .number = 4, .head = "feat-c", .base = "feat-b" }),
    };
    const parents = [_]?[]const u8{ null, "main", null, "feat-b" };
    var via_prs = try analyzeWith(testing.allocator, &prs, &parents);
    defer via_prs.deinit(testing.allocator);

    const edges = [_]Edge{
        .{ .head_ref = "shared", .base_ref = "main" },
        .{ .head_ref = "feat-a", .base_ref = "main" },
        .{ .head_ref = "feat-b", .base_ref = "shared" },
        .{ .head_ref = "feat-c", .base_ref = "feat-b" },
    };
    var via_edges = try analyzeEdges(testing.allocator, &edges);
    defer via_edges.deinit(testing.allocator);

    try testing.expectEqualSlices(usize, via_edges.stack_of, via_prs.stack_of);
    try testing.expectEqualSlices(usize, via_edges.depth_of, via_prs.depth_of);
    try testing.expectEqualSlices(usize, via_edges.heights, via_prs.heights);
    try testing.expectEqualSlices(?usize, via_edges.parent_of, via_prs.parent_of);
}

test "displayOrderOf on an empty analysis returns an empty order" {
    var a = try analyzeEdges(testing.allocator, &.{});
    defer a.deinit(testing.allocator);

    const order = try displayOrderOf(testing.allocator, a);
    defer testing.allocator.free(order);
    try testing.expectEqualSlices(usize, &.{}, order);
}

test "displayOrderOf keeps a base/head cycle together in input order" {
    // Neither member is a root, so both sit at depth 0 and keep input order.
    const edges = [_]Edge{
        .{ .head_ref = "solo", .base_ref = "main" },
        .{ .head_ref = "p", .base_ref = "q" },
        .{ .head_ref = "q", .base_ref = "p" },
    };
    var a = try analyzeEdges(testing.allocator, &edges);
    defer a.deinit(testing.allocator);

    const order = try displayOrderOf(testing.allocator, a);
    defer testing.allocator.free(order);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, order);
}

test "displayOrderOf keeps stacks contiguous and tip-first on a forked stack" {
    // base (0) has two children: left (1) and right (2); right has a child (4).
    // A standalone PR (3) sits between them in input order.
    const edges = [_]Edge{
        .{ .head_ref = "base", .base_ref = "main" },
        .{ .head_ref = "left", .base_ref = "base" },
        .{ .head_ref = "right", .base_ref = "base" },
        .{ .head_ref = "solo", .base_ref = "main" },
        .{ .head_ref = "right2", .base_ref = "right" },
    };
    var a = try analyzeEdges(testing.allocator, &edges);
    defer a.deinit(testing.allocator);

    const order = try displayOrderOf(testing.allocator, a);
    defer testing.allocator.free(order);
    // Deepest first; equal depths keep input order (left before right).
    try testing.expectEqualSlices(usize, &.{ 4, 1, 2, 0, 3 }, order);
}

test "displayOrderOf on 3000 standalone entries returns identity order" {
    const n = 3000;
    const names = try testing.allocator.alloc([8]u8, n);
    defer testing.allocator.free(names);
    const edges = try testing.allocator.alloc(Edge, n);
    defer testing.allocator.free(edges);
    for (names, edges, 0..) |*name, *edge, i| {
        _ = std.fmt.bufPrint(name, "b{d:0>7}", .{i}) catch unreachable;
        edge.* = .{ .head_ref = name, .base_ref = "main" };
    }
    var a = try analyzeEdges(testing.allocator, edges);
    defer a.deinit(testing.allocator);

    const order = try displayOrderOf(testing.allocator, a);
    defer testing.allocator.free(order);
    for (order, 0..) |got, i| try testing.expectEqual(i, got);
}
