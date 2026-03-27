const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("../acp/protocol.zig");

/// Owned plan entry - stores content string that needs to be freed
pub const OwnedPlanEntry = struct {
    content: []const u8, // Owned
    priority: protocol.PlanEntryPriority,
    status: protocol.PlanEntryStatus,

    pub fn deinit(self: *OwnedPlanEntry, allocator: Allocator) void {
        allocator.free(self.content);
    }

    /// Create a deep copy of this entry
    pub fn clone(self: *const OwnedPlanEntry, allocator: Allocator) !OwnedPlanEntry {
        return .{
            .content = try allocator.dupe(u8, self.content),
            .priority = self.priority,
            .status = self.status,
        };
    }
};

/// Maximum number of plan entries to show when collapsed
pub const MAX_COLLAPSED_ENTRIES: usize = 5;

/// State for the agent plan/todo list
pub const PlanState = struct {
    allocator: Allocator,
    entries: std.ArrayList(OwnedPlanEntry),
    visible: bool,
    expanded: bool,

    pub fn init(allocator: Allocator) PlanState {
        return .{
            .allocator = allocator,
            .entries = .{},
            .visible = true, // Show by default when entries exist
            .expanded = false, // Collapsed by default
        };
    }

    pub fn deinit(self: *PlanState) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
    }

    /// Clear all plan entries
    pub fn clear(self: *PlanState) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.clearRetainingCapacity();
    }

    /// Update the plan with new entries (replaces all existing entries)
    pub fn update(self: *PlanState, new_entries: []const protocol.PlanEntry) !void {
        // Clear existing entries
        self.clear();

        // Add new entries
        for (new_entries) |entry| {
            const owned_content = try self.allocator.dupe(u8, entry.content);
            errdefer self.allocator.free(owned_content);

            try self.entries.append(self.allocator, .{
                .content = owned_content,
                .priority = entry.priority,
                .status = entry.status,
            });
        }
    }

    /// Toggle plan visibility
    pub fn toggleVisibility(self: *PlanState) void {
        self.visible = !self.visible;
    }

    /// Toggle expanded/collapsed state
    pub fn toggleExpanded(self: *PlanState) void {
        self.expanded = !self.expanded;
    }

    /// Get the number of plan entries
    pub fn count(self: *const PlanState) usize {
        return self.entries.items.len;
    }

    /// Check if there are any entries
    pub fn hasEntries(self: *const PlanState) bool {
        return self.entries.items.len > 0;
    }

    /// Check if there are any incomplete plan entries
    pub fn hasIncompleteEntries(self: *const PlanState) bool {
        for (self.entries.items) |entry| {
            if (entry.status != .completed) return true;
        }
        return false;
    }

    /// Create a snapshot copy of all entries (caller owns the result)
    pub fn createSnapshot(self: *const PlanState) ![]OwnedPlanEntry {
        if (self.entries.items.len == 0) return &[_]OwnedPlanEntry{};

        const snapshot = try self.allocator.alloc(OwnedPlanEntry, self.entries.items.len);
        errdefer self.allocator.free(snapshot);

        for (self.entries.items, 0..) |entry, i| {
            const content_copy = try self.allocator.dupe(u8, entry.content);
            errdefer {
                // Clean up any entries we've already copied on error
                for (snapshot[0..i]) |*copied| {
                    self.allocator.free(copied.content);
                }
                self.allocator.free(content_copy);
            }

            snapshot[i] = .{
                .content = content_copy,
                .priority = entry.priority,
                .status = entry.status,
            };
        }

        return snapshot;
    }

    /// Estimate memory usage
    pub fn estimateMemoryUsage(self: *const PlanState) usize {
        var total: usize = self.entries.capacity * @sizeOf(OwnedPlanEntry);
        for (self.entries.items) |entry| {
            total += entry.content.len;
        }
        return total;
    }
};

test "PlanState basic operations" {
    const allocator = std.testing.allocator;

    var state = PlanState.init(allocator);
    defer state.deinit();

    try std.testing.expect(!state.hasEntries());
    try std.testing.expectEqual(@as(usize, 0), state.count());

    // Add entries
    const entries = [_]protocol.PlanEntry{
        .{ .content = "Task 1", .priority = .high, .status = .pending },
        .{ .content = "Task 2", .priority = .medium, .status = .in_progress },
    };
    try state.update(&entries);

    try std.testing.expect(state.hasEntries());
    try std.testing.expectEqual(@as(usize, 2), state.count());
    try std.testing.expect(state.hasIncompleteEntries());

    // Toggle visibility
    try std.testing.expect(state.visible);
    state.toggleVisibility();
    try std.testing.expect(!state.visible);

    // Clear
    state.clear();
    try std.testing.expect(!state.hasEntries());
}

test "PlanState snapshot" {
    const allocator = std.testing.allocator;

    var state = PlanState.init(allocator);
    defer state.deinit();

    const entries = [_]protocol.PlanEntry{
        .{ .content = "Test task", .priority = .medium, .status = .pending },
    };
    try state.update(&entries);

    const snapshot = try state.createSnapshot();
    defer {
        for (snapshot) |*entry| {
            allocator.free(entry.content);
        }
        allocator.free(snapshot);
    }

    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqualStrings("Test task", snapshot[0].content);
}
