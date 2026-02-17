const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const claude_adapter = @import("claude_adapter.zig");
const codex_adapter = @import("codex_adapter.zig");
const codex_protocol = @import("../../codex/protocol.zig");

const SessionInfo = types.SessionInfo;
const AgentType = types.AgentType;
const SessionDiscoveryError = types.SessionDiscoveryError;

// =============================================================================
// Unified Session Discovery
// =============================================================================

/// Default number of sessions to return per agent
pub const DEFAULT_LIMIT: usize = 20;

/// Discover sessions from a specific agent type.
/// For codex, falls back to file-based discovery. Use threadsToSessionInfos()
/// when a connected CodexManager has provided thread data.
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

/// Convert a slice of codex Thread objects to SessionInfo objects.
/// Used when a connected CodexManager provides thread data via thread/list.
pub fn threadsToSessionInfos(
    allocator: Allocator,
    threads: []const codex_protocol.Thread,
) Allocator.Error![]SessionInfo {
    var result: std.ArrayList(SessionInfo) = .{};
    errdefer {
        for (result.items) |*s| s.deinit();
        result.deinit(allocator);
    }

    for (threads) |thread| {
        const info = threadToSessionInfo(allocator, thread) catch continue;
        try result.append(allocator, info);
    }

    return result.toOwnedSlice(allocator);
}

/// Convert a single codex Thread to a SessionInfo.
pub fn threadToSessionInfo(allocator: Allocator, thread: codex_protocol.Thread) Allocator.Error!SessionInfo {
    return .{
        .allocator = allocator,
        .id = try allocator.dupe(u8, thread.id),
        .agent_type = .codex,
        .project_path = if (thread.cwd) |cwd| try allocator.dupe(u8, cwd) else try allocator.dupe(u8, ""),
        .display = if (thread.preview) |p|
            (if (p.len > 0) try allocator.dupe(u8, p) else try allocator.dupe(u8, "(no preview)"))
        else
            try allocator.dupe(u8, "(no preview)"),
        .timestamp = if (thread.updated_at) |ts| ts * 1000 else 0, // seconds to milliseconds
        .message_count = if (thread.turns) |turns| turns.len else 0,
        .branch = if (thread.git_info) |gi| (if (gi.branch) |b| try allocator.dupe(u8, b) else null) else null,
        .last_message = if (thread.preview) |p|
            (if (p.len > 0) try allocator.dupe(u8, p) else null)
        else
            null,
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

    // Collect from Codex (file-based fallback)
    if (codex_adapter.listSessions(allocator, cwd, limit)) |codex_sessions| {
        for (codex_sessions) |session| {
            all_sessions.append(allocator, session) catch return error.OutOfMemory;
        }
        allocator.free(codex_sessions);
    } else |_| {
        // Codex sessions not available, continue
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
    if (result) |sessions_list| {
        freeSessions(allocator, sessions_list);
    } else |_| {
        // Expected - directory doesn't exist
    }
}

test "threadToSessionInfo maps fields correctly" {
    const allocator = std.testing.allocator;

    const thread = codex_protocol.Thread{
        .id = "019c-thread-1",
        .preview = "Fix the login bug",
        .cwd = "/home/user/project",
        .updated_at = 1771345125,
        .turns = &.{},
        .git_info = .{
            .branch = "feature-branch",
        },
    };

    var info = try threadToSessionInfo(allocator, thread);
    defer info.deinit();

    try std.testing.expectEqualStrings("019c-thread-1", info.id);
    try std.testing.expect(info.agent_type == .codex);
    try std.testing.expectEqualStrings("/home/user/project", info.project_path);
    try std.testing.expectEqualStrings("Fix the login bug", info.display);
    try std.testing.expectEqual(@as(i64, 1771345125 * 1000), info.timestamp);
    try std.testing.expectEqual(@as(usize, 0), info.message_count);
    try std.testing.expectEqualStrings("feature-branch", info.branch.?);
    try std.testing.expectEqualStrings("Fix the login bug", info.last_message.?);
}

test "threadToSessionInfo handles null fields" {
    const allocator = std.testing.allocator;

    const thread = codex_protocol.Thread{
        .id = "minimal-thread",
    };

    var info = try threadToSessionInfo(allocator, thread);
    defer info.deinit();

    try std.testing.expectEqualStrings("minimal-thread", info.id);
    try std.testing.expect(info.agent_type == .codex);
    try std.testing.expectEqualStrings("", info.project_path);
    try std.testing.expectEqualStrings("(no preview)", info.display);
    try std.testing.expectEqual(@as(i64, 0), info.timestamp);
    try std.testing.expectEqual(@as(usize, 0), info.message_count);
    try std.testing.expect(info.branch == null);
    try std.testing.expect(info.last_message == null);
}

test "threadsToSessionInfos converts multiple threads" {
    const allocator = std.testing.allocator;

    const threads = &[_]codex_protocol.Thread{
        .{
            .id = "thread-1",
            .preview = "First",
            .updated_at = 100,
        },
        .{
            .id = "thread-2",
            .preview = "Second",
            .updated_at = 200,
        },
    };

    const infos = try threadsToSessionInfos(allocator, threads);
    defer freeSessions(allocator, infos);

    try std.testing.expectEqual(@as(usize, 2), infos.len);
    try std.testing.expectEqualStrings("thread-1", infos[0].id);
    try std.testing.expectEqualStrings("thread-2", infos[1].id);
}

test "threadsToSessionInfos handles empty list" {
    const allocator = std.testing.allocator;

    const threads = &[_]codex_protocol.Thread{};
    const infos = try threadsToSessionInfos(allocator, threads);
    defer freeSessions(allocator, infos);

    try std.testing.expectEqual(@as(usize, 0), infos.len);
}

test "listSessions codex falls back to file-based discovery" {
    const allocator = std.testing.allocator;

    // Codex should now fall back to file-based discovery instead of returning empty
    const result = listSessions(allocator, .codex, "/nonexistent/path", 10);
    if (result) |sessions_list| {
        freeSessions(allocator, sessions_list);
    } else |_| {
        // Expected if no codex sessions exist
    }
}
