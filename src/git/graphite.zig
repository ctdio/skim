const std = @import("std");
const skim_io = @import("skim_io");

const Allocator = std.mem.Allocator;

/// A branch in the graphite stack
pub const GraphiteBranch = struct {
    name: []const u8,
    is_trunk: bool,
    needs_restack: bool,
    parent_ref: ?[]const u8,
};

/// An ordered stack of branches from trunk to tip
pub const GraphiteStack = struct {
    branches: []GraphiteBranch,
    current_idx: usize,

    pub fn deinit(self: *GraphiteStack, allocator: Allocator) void {
        for (self.branches) |branch| {
            allocator.free(branch.name);
            if (branch.parent_ref) |parent| {
                allocator.free(parent);
            }
        }
        allocator.free(self.branches);
    }

    pub fn currentBranch(self: *const GraphiteStack) ?*const GraphiteBranch {
        if (self.current_idx < self.branches.len) {
            return &self.branches[self.current_idx];
        }
        return null;
    }

    pub fn parentBranch(self: *const GraphiteStack) ?*const GraphiteBranch {
        if (self.current_idx > 0) {
            return &self.branches[self.current_idx - 1];
        }
        return null;
    }

    pub fn childBranch(self: *const GraphiteStack) ?*const GraphiteBranch {
        if (self.current_idx + 1 < self.branches.len) {
            return &self.branches[self.current_idx + 1];
        }
        return null;
    }
};

/// Authoritative branch→parent relationships from `gt state`, used to group
/// stacked PRs by Graphite's own metadata rather than inferring parentage from
/// GitHub base refs (which chains everything sharing a base into one false
/// stack). Branch-name strings are owned by the arena.
pub const BranchParents = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMap([]const u8),

    pub fn deinit(self: *BranchParents) void {
        self.map.deinit();
        self.arena.deinit();
    }

    /// The Graphite parent branch of `branch`, or null when `branch` is trunk or
    /// not tracked by Graphite. A non-null result may itself be the trunk branch.
    pub fn parentOf(self: *const BranchParents, branch: []const u8) ?[]const u8 {
        return self.map.get(branch);
    }
};

/// Run `gt state` and return each branch's Graphite parent. Returns null when
/// graphite isn't installed or the repo isn't graphite-tracked, so callers can
/// fall back to forge-native inference.
pub fn getBranchParents(allocator: Allocator) ?BranchParents {
    const args = &[_][]const u8{ "gt", "state" };
    var child = std.process.spawn(skim_io.get(), .{
        .argv = args,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;
    const stdout = skim_io.readAllAlloc(child.stdout.?, allocator, 4 * 1024 * 1024) catch return null;
    defer allocator.free(stdout);
    const term = child.wait(skim_io.get()) catch return null;
    if (term != .exited or term.exited != 0) return null;

    return parseBranchParents(allocator, stdout);
}

/// Pure parse of `gt state` JSON into a branch→parent map. Every branch carrying
/// a first parent ref is recorded (mapping to that parent, which may be trunk);
/// the trunk branch itself has no parents and is omitted. Returns null on
/// malformed JSON.
pub fn parseBranchParents(allocator: Allocator, json_str: []const u8) ?BranchParents {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    const a = arena.allocator();
    var map = std.StringHashMap([]const u8).init(allocator);

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const branch_value = entry.value_ptr.*;
        if (branch_value != .object) continue;
        const parent = firstParentRef(branch_value.object) orelse continue;
        const key = a.dupe(u8, entry.key_ptr.*) catch break;
        const val = a.dupe(u8, parent) catch break;
        map.put(key, val) catch break;
    }

    return .{ .arena = arena, .map = map };
}

/// Check if the graphite CLI (gt) is available in PATH
pub fn isGraphiteAvailable() bool {
    const args = &[_][]const u8{ "which", "gt" };
    var child = std.process.spawn(skim_io.get(), .{
        .argv = args,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(skim_io.get()) catch return false;

    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Check if the current directory is a graphite-tracked repository
pub fn isGraphiteRepo(allocator: Allocator) bool {
    // Run gt state - if it fails or returns empty, not a graphite repo
    const args = &[_][]const u8{ "gt", "state" };
    var child = std.process.spawn(skim_io.get(), .{
        .argv = args,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return false;

    const stdout = skim_io.readAllAlloc(child.stdout.?, allocator, 1 * 1024 * 1024) catch return false;
    defer allocator.free(stdout);

    const term = child.wait(skim_io.get()) catch return false;

    return switch (term) {
        .exited => |code| code == 0 and stdout.len > 2, // At least "{}"
        else => false,
    };
}

/// Get the current git branch name
pub fn getCurrentBranch(allocator: Allocator) ![]const u8 {
    const args = &[_][]const u8{ "git", "rev-parse", "--abbrev-ref", "HEAD" };
    var child = try std.process.spawn(skim_io.get(), .{
        .argv = args,
        .stdout = .pipe,
        .stderr = .ignore,
    });

    const stdout = try skim_io.readAllAlloc(child.stdout.?, allocator, 1024);
    errdefer allocator.free(stdout);

    const term = try child.wait(skim_io.get());

    if (term != .exited or term.exited != 0) {
        allocator.free(stdout);
        return error.GitCommandFailed;
    }

    // Trim trailing newline
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    const result = try allocator.dupe(u8, trimmed);
    allocator.free(stdout);

    return result;
}

/// Parse gt state JSON output and build the stack for the current branch
pub fn getGraphiteStack(allocator: Allocator) !?GraphiteStack {
    // Get current branch first
    const current_branch = getCurrentBranch(allocator) catch return null;
    defer allocator.free(current_branch);

    // Run gt state
    const args = &[_][]const u8{ "gt", "state" };
    var child = std.process.spawn(skim_io.get(), .{
        .argv = args,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;

    const stdout = skim_io.readAllAlloc(child.stdout.?, allocator, 1 * 1024 * 1024) catch return null;
    defer allocator.free(stdout);

    const term = child.wait(skim_io.get()) catch return null;

    if (term != .exited or term.exited != 0) {
        return null;
    }

    // Parse JSON and build stack
    return buildStackFromJson(allocator, stdout, current_branch);
}

/// Parse the gt state JSON and build an ordered stack
fn buildStackFromJson(allocator: Allocator, json_str: []const u8, current_branch: []const u8) !?GraphiteStack {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    // First pass: find all branches and their parents
    var branch_map = std.StringHashMap(BranchInfo).init(allocator);
    defer {
        var it = branch_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.parent_ref) |p| allocator.free(p);
        }
        branch_map.deinit();
    }

    var trunk_name: ?[]const u8 = null;

    var obj_it = root.object.iterator();
    while (obj_it.next()) |entry| {
        const branch_name = entry.key_ptr.*;
        const branch_value = entry.value_ptr.*;

        if (branch_value != .object) continue;

        const is_trunk = if (branch_value.object.get("trunk")) |t| t == .bool and t.bool else false;
        const needs_restack = if (branch_value.object.get("needs_restack")) |r| r == .bool and r.bool else false;

        var parent_ref: ?[]const u8 = null;
        if (branch_value.object.get("parents")) |parents| {
            if (parents == .array and parents.array.items.len > 0) {
                const first_parent = parents.array.items[0];
                if (first_parent == .object) {
                    if (first_parent.object.get("ref")) |ref| {
                        if (ref == .string) {
                            parent_ref = try allocator.dupe(u8, ref.string);
                        }
                    }
                }
            }
        }

        const name_copy = try allocator.dupe(u8, branch_name);
        errdefer allocator.free(name_copy);

        try branch_map.put(name_copy, .{
            .is_trunk = is_trunk,
            .needs_restack = needs_restack,
            .parent_ref = parent_ref,
        });

        if (is_trunk) {
            trunk_name = name_copy;
        }
    }

    // Check if current branch is in the graphite state
    if (!branch_map.contains(current_branch)) {
        return null;
    }

    // Build the stack: walk from current branch up to trunk
    var stack_list: std.ArrayList(GraphiteBranch) = .empty;
    errdefer {
        for (stack_list.items) |b| {
            allocator.free(b.name);
            if (b.parent_ref) |p| allocator.free(p);
        }
        stack_list.deinit(allocator);
    }

    // Walk up to trunk
    var ancestors: std.ArrayList([]const u8) = .empty;
    defer ancestors.deinit(allocator);

    var walker: []const u8 = current_branch;
    while (true) {
        try ancestors.append(allocator, walker);
        if (branch_map.get(walker)) |info| {
            if (info.is_trunk or info.parent_ref == null) break;
            walker = info.parent_ref.?;
        } else {
            break;
        }
    }

    // Reverse to get trunk-first order
    std.mem.reverse([]const u8, ancestors.items);

    // Build the final stack
    var current_idx: usize = 0;
    for (ancestors.items, 0..) |branch_name, idx| {
        if (std.mem.eql(u8, branch_name, current_branch)) {
            current_idx = idx;
        }

        const info = branch_map.get(branch_name) orelse continue;

        try stack_list.append(allocator, .{
            .name = try allocator.dupe(u8, branch_name),
            .is_trunk = info.is_trunk,
            .needs_restack = info.needs_restack,
            .parent_ref = if (info.parent_ref) |p| try allocator.dupe(u8, p) else null,
        });
    }

    // Now walk down from current to find children (branches where parent = current)
    // This is more complex - need to find all descendants
    var descendants: std.ArrayList([]const u8) = .empty;
    defer descendants.deinit(allocator);

    try findDescendants(allocator, &branch_map, current_branch, &descendants);

    // Add descendants to the stack
    for (descendants.items) |branch_name| {
        const info = branch_map.get(branch_name) orelse continue;

        try stack_list.append(allocator, .{
            .name = try allocator.dupe(u8, branch_name),
            .is_trunk = info.is_trunk,
            .needs_restack = info.needs_restack,
            .parent_ref = if (info.parent_ref) |p| try allocator.dupe(u8, p) else null,
        });
    }

    if (stack_list.items.len == 0) {
        return null;
    }

    return GraphiteStack{
        .branches = try stack_list.toOwnedSlice(allocator),
        .current_idx = current_idx,
    };
}

const BranchInfo = struct {
    is_trunk: bool,
    needs_restack: bool,
    parent_ref: ?[]const u8,
};

/// The `ref` of a branch's first parent in `gt state`, or null when it has none.
fn firstParentRef(obj: std.json.ObjectMap) ?[]const u8 {
    const parents = obj.get("parents") orelse return null;
    if (parents != .array or parents.array.items.len == 0) return null;
    const first = parents.array.items[0];
    if (first != .object) return null;
    const ref = first.object.get("ref") orelse return null;
    if (ref != .string) return null;
    return ref.string;
}

/// Find all descendants of a branch (children, grandchildren, etc.)
fn findDescendants(allocator: Allocator, branch_map: *std.StringHashMap(BranchInfo), parent: []const u8, result: *std.ArrayList([]const u8)) !void {
    // Find immediate children
    var children: std.ArrayList([]const u8) = .empty;
    defer children.deinit(allocator);

    var it = branch_map.iterator();
    while (it.next()) |entry| {
        const info = entry.value_ptr.*;
        if (info.parent_ref) |p| {
            if (std.mem.eql(u8, p, parent)) {
                try children.append(allocator, entry.key_ptr.*);
            }
        }
    }

    // Add children and recurse
    for (children.items) |child| {
        try result.append(allocator, child);
        try findDescendants(allocator, branch_map, child, result);
    }
}

/// Refresh the graphite stack (call after branch changes)
pub fn refreshGraphiteStack(allocator: Allocator, old_stack: ?*GraphiteStack) !?GraphiteStack {
    if (old_stack) |stack| {
        var s = stack.*;
        s.deinit(allocator);
    }
    return getGraphiteStack(allocator);
}

test "isGraphiteAvailable returns bool" {
    _ = isGraphiteAvailable();
    // Just verify it doesn't crash
}

test "parseBranchParents: maps each branch to its parent, omitting trunk" {
    const json =
        \\{
        \\  "main": { "trunk": true },
        \\  "feat-a": { "parents": [{ "ref": "main" }] },
        \\  "feat-b": { "parents": [{ "ref": "feat-a" }] }
        \\}
    ;
    var bp = parseBranchParents(std.testing.allocator, json).?;
    defer bp.deinit();

    try std.testing.expectEqualStrings("main", bp.parentOf("feat-a").?);
    try std.testing.expectEqualStrings("feat-a", bp.parentOf("feat-b").?);
    // Trunk has no parents entry, so it is absent from the map.
    try std.testing.expectEqual(@as(?[]const u8, null), bp.parentOf("main"));
    // An unknown branch is absent too.
    try std.testing.expectEqual(@as(?[]const u8, null), bp.parentOf("nope"));
}

test "parseBranchParents: malformed JSON yields null" {
    try std.testing.expectEqual(@as(?BranchParents, null), parseBranchParents(std.testing.allocator, "not json"));
}
