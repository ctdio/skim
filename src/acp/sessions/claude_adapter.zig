const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const SessionInfo = types.SessionInfo;
const SessionDiscoveryError = types.SessionDiscoveryError;

// =============================================================================
// Claude Code Session Discovery
// =============================================================================

/// Aggregated session data from multiple history entries
const SessionAggregate = struct {
    first_display: []const u8, // First message (for display)
    last_timestamp: i64, // Most recent activity (for sorting)
    message_count: usize, // Number of messages
    project_path: []const u8,
};

/// Discover sessions from Claude Code's history
/// Reads ~/.claude/history.jsonl and filters by project path
/// Shows first message as display, sorted by most recent activity
pub fn listSessions(
    allocator: Allocator,
    cwd: []const u8,
    limit: usize,
) SessionDiscoveryError![]SessionInfo {
    const home = std.posix.getenv("HOME") orelse return error.HomeDirectoryNotFound;

    // Build path to history.jsonl
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const history_path = std.fmt.bufPrint(&path_buf, "{s}/.claude/history.jsonl", .{home}) catch {
        return error.IoError;
    };

    // Open history file
    const file = std.fs.openFileAbsolute(history_path, .{}) catch {
        return error.SessionDirectoryNotFound;
    };
    defer file.close();

    // Read entire file (history.jsonl is typically < 5MB)
    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        return error.IoError;
    };
    defer allocator.free(content);

    // Group entries by sessionId to get first message, last timestamp, and count
    var session_map = std.StringHashMap(SessionAggregate).init(allocator);
    defer {
        var it = session_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.first_display);
            allocator.free(entry.value_ptr.project_path);
        }
        session_map.deinit();
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Parse JSON line
        const parsed = std.json.parseFromSlice(HistoryEntry, allocator, line, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        defer parsed.deinit();

        const entry = parsed.value;

        // Filter by project path (exact match)
        if (!std.mem.eql(u8, entry.project, cwd)) continue;

        // Skip entries without sessionId
        const session_id = entry.sessionId orelse continue;

        if (session_map.getPtr(session_id)) |agg| {
            // Update existing session aggregate
            agg.message_count += 1;
            if (entry.timestamp > agg.last_timestamp) {
                agg.last_timestamp = entry.timestamp;
            }
            // Keep first_display as-is (it's from the first entry we saw)
        } else {
            // New session - store first entry's display
            const id_copy = allocator.dupe(u8, session_id) catch return error.OutOfMemory;
            errdefer allocator.free(id_copy);

            const display_copy = allocator.dupe(u8, entry.display) catch return error.OutOfMemory;
            errdefer allocator.free(display_copy);

            const project_copy = allocator.dupe(u8, entry.project) catch return error.OutOfMemory;

            session_map.put(id_copy, .{
                .first_display = display_copy,
                .last_timestamp = entry.timestamp,
                .message_count = 1,
                .project_path = project_copy,
            }) catch return error.OutOfMemory;
        }
    }

    // Convert map to list for sorting
    var sessions: std.ArrayList(SessionInfo) = .{};
    errdefer {
        for (sessions.items) |*s| s.deinit();
        sessions.deinit(allocator);
    }

    var it = session_map.iterator();
    while (it.next()) |entry| {
        const info = SessionInfo{
            .allocator = allocator,
            .id = allocator.dupe(u8, entry.key_ptr.*) catch return error.OutOfMemory,
            .agent_type = .claude_code,
            .project_path = allocator.dupe(u8, entry.value_ptr.project_path) catch return error.OutOfMemory,
            .display = allocator.dupe(u8, entry.value_ptr.first_display) catch return error.OutOfMemory,
            .timestamp = entry.value_ptr.last_timestamp,
            .message_count = entry.value_ptr.message_count,
        };
        sessions.append(allocator, info) catch return error.OutOfMemory;
    }

    // Sort by timestamp descending (most recent first)
    std.mem.sort(SessionInfo, sessions.items, {}, struct {
        fn lessThan(_: void, a: SessionInfo, b: SessionInfo) bool {
            return a.timestamp > b.timestamp; // Descending
        }
    }.lessThan);

    // Limit results
    if (sessions.items.len > limit) {
        for (sessions.items[limit..]) |*s| {
            s.deinit();
        }
        sessions.shrinkRetainingCapacity(limit);
    }

    return sessions.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// Escape project path for Claude Code's directory naming
/// Converts "/" to "-" and removes leading dash
pub fn escapeProjectPath(allocator: Allocator, path: []const u8) Allocator.Error![]u8 {
    var result = try allocator.alloc(u8, path.len);
    for (path, 0..) |c, i| {
        result[i] = if (c == '/') '-' else c;
    }
    return result;
}

// =============================================================================
// JSON Types
// =============================================================================

const HistoryEntry = struct {
    display: []const u8,
    project: []const u8,
    timestamp: i64,
    sessionId: ?[]const u8 = null,
};

// =============================================================================
// Tests
// =============================================================================

test "escapeProjectPath" {
    const allocator = std.testing.allocator;
    const result = try escapeProjectPath(allocator, "/Users/test/projects/foo");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("-Users-test-projects-foo", result);
}
