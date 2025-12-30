const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const claude_adapter = @import("claude_adapter.zig");
const codex_adapter = @import("codex_adapter.zig");

const SessionInfo = types.SessionInfo;
const AgentType = types.AgentType;
const SessionDiscoveryError = types.SessionDiscoveryError;

// =============================================================================
// Unified Session Discovery
// =============================================================================

/// Default number of sessions to return per agent
pub const DEFAULT_LIMIT: usize = 20;

/// Discover sessions from a specific agent type
pub fn listSessions(
    allocator: Allocator,
    agent_type: AgentType,
    cwd: []const u8,
    limit: usize,
) SessionDiscoveryError![]SessionInfo {
    return switch (agent_type) {
        .claude_code => claude_adapter.listSessions(allocator, cwd, limit),
        .codex => codex_adapter.listSessions(allocator, cwd, limit),
    };
}

/// Discover sessions from all supported agents
/// Returns combined list sorted by timestamp (most recent first)
pub fn listAllSessions(
    allocator: Allocator,
    cwd: []const u8,
    limit: usize,
) SessionDiscoveryError![]SessionInfo {
    var all_sessions: std.ArrayList(SessionInfo) = .{};
    errdefer {
        for (all_sessions.items) |*s| s.deinit();
        all_sessions.deinit(allocator);
    }

    // Collect from Claude Code
    if (claude_adapter.listSessions(allocator, cwd, limit)) |sessions| {
        for (sessions) |session| {
            all_sessions.append(allocator, session) catch return error.OutOfMemory;
        }
        allocator.free(sessions);
    } else |_| {
        // Claude Code not available, continue
    }

    // Collect from Codex
    if (codex_adapter.listSessions(allocator, cwd, limit)) |sessions| {
        for (sessions) |session| {
            all_sessions.append(allocator, session) catch return error.OutOfMemory;
        }
        allocator.free(sessions);
    } else |_| {
        // Codex not available, continue
    }

    // Sort combined results by timestamp
    std.mem.sort(SessionInfo, all_sessions.items, {}, struct {
        fn lessThan(_: void, a: SessionInfo, b: SessionInfo) bool {
            return a.timestamp > b.timestamp;
        }
    }.lessThan);

    // Limit results
    if (all_sessions.items.len > limit) {
        for (all_sessions.items[limit..]) |*s| s.deinit();
        all_sessions.items.len = limit;
    }

    return all_sessions.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// Free a list of sessions
pub fn freeSessions(allocator: Allocator, sessions: []SessionInfo) void {
    for (sessions) |*s| {
        s.deinit();
    }
    allocator.free(sessions);
}

// =============================================================================
// Tests
// =============================================================================

test "listSessions returns empty on missing directory" {
    const allocator = std.testing.allocator;

    // Should not crash, may return error or empty list
    const result = listSessions(allocator, .claude_code, "/nonexistent/path", 10);
    if (result) |sessions| {
        freeSessions(allocator, sessions);
    } else |_| {
        // Expected - directory doesn't exist
    }
}
