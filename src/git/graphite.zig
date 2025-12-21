const std = @import("std");

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

/// Check if the graphite CLI (gt) is available in PATH
pub fn isGraphiteAvailable(allocator: Allocator) bool {
    const args = &[_][]const u8{ "which", "gt" };
    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return false;
    const term = child.wait() catch return false;

    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

/// Check if the current directory is a graphite-tracked repository
pub fn isGraphiteRepo(allocator: Allocator) bool {
    // Run gt state - if it fails or returns empty, not a graphite repo
    const args = &[_][]const u8{ "gt", "state" };
    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return false;

    const stdout = child.stdout.?.readToEndAlloc(allocator, 1 * 1024 * 1024) catch return false;
    defer allocator.free(stdout);

    const term = child.wait() catch return false;

    return switch (term) {
        .Exited => |code| code == 0 and stdout.len > 2, // At least "{}"
        else => false,
    };
}

/// Get the current git branch name
pub fn getCurrentBranch(allocator: Allocator) ![]const u8 {
    const args = &[_][]const u8{ "git", "rev-parse", "--abbrev-ref", "HEAD" };
    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024);
    errdefer allocator.free(stdout);

    const term = try child.wait();

    if (term != .Exited or term.Exited != 0) {
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
    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return null;

    const stdout = child.stdout.?.readToEndAlloc(allocator, 1 * 1024 * 1024) catch return null;
    defer allocator.free(stdout);

    const term = child.wait() catch return null;

    if (term != .Exited or term.Exited != 0) {
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
    var stack_list: std.ArrayList(GraphiteBranch) = .{};
    errdefer {
        for (stack_list.items) |b| {
            allocator.free(b.name);
            if (b.parent_ref) |p| allocator.free(p);
        }
        stack_list.deinit(allocator);
    }

    // Walk up to trunk
    var ancestors: std.ArrayList([]const u8) = .{};
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
    var descendants: std.ArrayList([]const u8) = .{};
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

/// Find all descendants of a branch (children, grandchildren, etc.)
fn findDescendants(allocator: Allocator, branch_map: *std.StringHashMap(BranchInfo), parent: []const u8, result: *std.ArrayList([]const u8)) !void {
    // Find immediate children
    var children: std.ArrayList([]const u8) = .{};
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
    const allocator = std.testing.allocator;
    _ = isGraphiteAvailable(allocator);
    // Just verify it doesn't crash
}
