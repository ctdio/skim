const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const SessionInfo = types.SessionInfo;
const SessionDiscoveryError = types.SessionDiscoveryError;

// =============================================================================
// Claude Code Session Discovery
// =============================================================================

/// Discover sessions from Claude Code's history
/// Reads ~/.claude/history.jsonl and filters by project path
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

    // Parse JSONL and collect matching sessions
    var sessions: std.ArrayList(SessionInfo) = .{};
    errdefer {
        for (sessions.items) |*s| s.deinit();
        sessions.deinit(allocator);
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

        // Create SessionInfo
        const info = SessionInfo{
            .allocator = allocator,
            .id = allocator.dupe(u8, session_id) catch return error.OutOfMemory,
            .agent_type = .claude_code,
            .project_path = allocator.dupe(u8, entry.project) catch return error.OutOfMemory,
            .display = allocator.dupe(u8, entry.display) catch return error.OutOfMemory,
            .timestamp = entry.timestamp,
        };

        sessions.append(allocator, info) catch return error.OutOfMemory;
    }

    // Sort by timestamp descending (most recent first)
    std.mem.sort(SessionInfo, sessions.items, {}, struct {
        fn lessThan(_: void, a: SessionInfo, b: SessionInfo) bool {
            return a.timestamp > b.timestamp; // Descending
        }
    }.lessThan);

    // Deduplicate by session ID (keep most recent entry per session)
    var unique: std.ArrayList(SessionInfo) = .{};
    errdefer {
        for (unique.items) |*s| s.deinit();
        unique.deinit(allocator);
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    // Track which indices we've added to unique (to avoid double-free)
    var added_indices: std.ArrayList(usize) = .{};
    defer added_indices.deinit(allocator);

    for (sessions.items, 0..) |session, idx| {
        if (seen.contains(session.id)) {
            // Duplicate, free it immediately
            var s = session;
            s.deinit();
            continue;
        }

        seen.put(session.id, {}) catch return error.OutOfMemory;
        unique.append(allocator, session) catch return error.OutOfMemory;
        added_indices.append(allocator, idx) catch return error.OutOfMemory;

        if (unique.items.len >= limit) break;
    }

    // Free remaining sessions that weren't added to unique
    // (items after the limit that aren't duplicates)
    const processed_count = if (unique.items.len > 0)
        added_indices.items[added_indices.items.len - 1] + 1
    else
        0;

    for (sessions.items[processed_count..]) |*s| {
        s.deinit();
    }

    sessions.deinit(allocator);

    return unique.toOwnedSlice(allocator) catch return error.OutOfMemory;
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
