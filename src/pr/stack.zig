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
};

/// Group `prs` into stacks by their base->head relationships. Caller owns the
/// returned analysis. Robust to cycles (a malformed base/head loop degrades to
/// each involved PR being its own root rather than looping forever).
pub fn analyze(allocator: std.mem.Allocator, prs: []const PullRequest) !Analysis {
    const n = prs.len;

    var parent_of = try allocator.alloc(?usize, n);
    errdefer allocator.free(parent_of);
    var stack_of = try allocator.alloc(usize, n);
    errdefer allocator.free(stack_of);
    var depth_of = try allocator.alloc(usize, n);
    errdefer allocator.free(depth_of);

    // head branch -> PR index. First spelling wins if a branch somehow repeats.
    var head_to_pr = std.StringHashMap(usize).init(allocator);
    defer head_to_pr.deinit();
    for (prs, 0..) |pr, i| {
        if (pr.head_ref.len == 0) continue;
        if (!head_to_pr.contains(pr.head_ref)) try head_to_pr.put(pr.head_ref, i);
    }

    // Initialize every parent to null up front: the cycle check below walks
    // parent links across the whole array, so all entries must be readable
    // before any are computed.
    for (0..n) |i| parent_of[i] = null;

    // parent = the open PR whose head is this PR's base. A PR is never its own
    // parent (a base==head PR is treated as a root).
    for (prs, 0..) |pr, i| {
        if (pr.base_ref.len == 0) continue;
        if (head_to_pr.get(pr.base_ref)) |p| {
            if (p != i and !isAncestor(parent_of, p, i)) parent_of[i] = p;
        }
    }

    var heights: std.ArrayList(usize) = .{};
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
