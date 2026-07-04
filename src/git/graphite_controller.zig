//! Controller for the Graphite stack sub-state (`GraphiteState`): lazy CLI
//! detection, the cached stack, and the picker selection index. App keeps only
//! thin cross-cutting forwarders (opening the picker, swapping the diff to a
//! stack branch) that hand this sub-state to the free functions below.

const std = @import("std");
const Allocator = std.mem.Allocator;

const graphite = @import("graphite.zig");

/// Graphite stack sub-state (lazy-loaded to avoid blocking startup). All fields
/// default so it stays out of the State init literal.
pub const GraphiteState = struct {
    detected: bool = false, // Has graphite detection been performed?
    available: bool = false, // Is gt CLI installed?
    stack: ?graphite.GraphiteStack = null, // Current stack (null if not graphite repo)
    selection: usize = 0, // Selected index in stack picker

    pub fn deinit(self: *GraphiteState, allocator: Allocator) void {
        if (self.stack) |*stack| {
            stack.deinit(allocator);
        }
    }
};

/// Lazy graphite detection - only runs once on first access. Avoids blocking
/// startup with `which gt` and `gt state` calls.
pub fn ensureDetected(self: *GraphiteState, allocator: Allocator) void {
    if (self.detected) return;

    self.detected = true;
    self.available = graphite.isGraphiteAvailable(allocator);

    if (self.available) {
        if (graphite.getGraphiteStack(allocator) catch null) |stack| {
            self.stack = stack;
        }
    }
}

/// Refresh the graphite stack (called on app refresh). Only re-fetches if a
/// stack was already loaded to avoid unnecessary process spawns when not using
/// graphite mode.
pub fn refreshStack(self: *GraphiteState, allocator: Allocator) void {
    // Skip if graphite hasn't been detected or isn't available
    if (!self.detected or !self.available) return;

    // Only re-fetch if we already had a graphite stack loaded
    // This avoids blocking when not using graphite mode
    if (self.stack == null) return;

    // Free old stack
    if (self.stack) |*old_stack| {
        old_stack.deinit(allocator);
        self.stack = null;
    }

    // Re-fetch stack
    if (graphite.getGraphiteStack(allocator) catch null) |stack| {
        self.stack = stack;
    }
}
