const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const SessionInfo = types.SessionInfo;
const SessionDiscoveryError = types.SessionDiscoveryError;

// =============================================================================
// Codex Session Discovery
// =============================================================================

/// Discover sessions from Codex's session storage
/// Walks ~/.codex/sessions/YYYY/MM/DD/ directories
/// Filters to sessions matching the current working directory
pub fn listSessions(
    allocator: Allocator,
    cwd: []const u8,
    limit: usize,
) SessionDiscoveryError![]SessionInfo {
    const home = std.posix.getenv("HOME") orelse return error.HomeDirectoryNotFound;

    // Build path to sessions directory
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sessions_path = std.fmt.bufPrint(&path_buf, "{s}/.codex/sessions", .{home}) catch {
        return error.IoError;
    };

    // Open sessions directory
    var sessions_dir = std.fs.openDirAbsolute(sessions_path, .{ .iterate = true }) catch {
        return error.SessionDirectoryNotFound;
    };
    defer sessions_dir.close();

    var sessions: std.ArrayList(SessionInfo) = .{};
    errdefer {
        for (sessions.items) |*s| s.deinit();
        sessions.deinit(allocator);
    }

    // Walk year directories (2025, 2024, etc.)
    var year_iter = sessions_dir.iterate();
    while (year_iter.next() catch null) |year_entry| {
        if (year_entry.kind != .directory) continue;

        var year_dir = sessions_dir.openDir(year_entry.name, .{ .iterate = true }) catch continue;
        defer year_dir.close();

        // Walk month directories (01-12)
        var month_iter = year_dir.iterate();
        while (month_iter.next() catch null) |month_entry| {
            if (month_entry.kind != .directory) continue;

            var month_dir = year_dir.openDir(month_entry.name, .{ .iterate = true }) catch continue;
            defer month_dir.close();

            // Walk day directories (01-31)
            var day_iter = month_dir.iterate();
            while (day_iter.next() catch null) |day_entry| {
                if (day_entry.kind != .directory) continue;

                var day_dir = month_dir.openDir(day_entry.name, .{ .iterate = true }) catch continue;
                defer day_dir.close();

                // Find rollout files
                var file_iter = day_dir.iterate();
                while (file_iter.next() catch null) |file_entry| {
                    if (file_entry.kind != .file) continue;
                    if (!std.mem.startsWith(u8, file_entry.name, "rollout-")) continue;
                    if (!std.mem.endsWith(u8, file_entry.name, ".jsonl")) continue;

                    // Parse session from rollout file
                    var info = parseRolloutFile(allocator, day_dir, file_entry.name) catch continue;

                    // Filter by cwd - only include sessions from this project
                    if (!std.mem.eql(u8, info.project_path, cwd)) {
                        info.deinit();
                        continue;
                    }

                    sessions.append(allocator, info) catch return error.OutOfMemory;
                }
            }
        }
    }

    // Sort by timestamp descending (most recent first)
    std.mem.sort(SessionInfo, sessions.items, {}, struct {
        fn lessThan(_: void, a: SessionInfo, b: SessionInfo) bool {
            return a.timestamp > b.timestamp;
        }
    }.lessThan);

    // Limit results
    if (sessions.items.len > limit) {
        // Free excess items
        for (sessions.items[limit..]) |*s| s.deinit();
        sessions.items.len = limit;
    }

    return sessions.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// Parse a rollout file to extract session info
fn parseRolloutFile(
    allocator: Allocator,
    dir: std.fs.Dir,
    filename: []const u8,
) !SessionInfo {
    // Open and read file content
    const file = dir.openFile(filename, .{}) catch return error.IoError;
    defer file.close();

    // Read file content (limit to 256KB - enough to find session_meta and first user message)
    const content = file.readToEndAlloc(allocator, 256 * 1024) catch return error.IoError;
    defer allocator.free(content);

    // Get first line (session_meta)
    const first_nl = std.mem.indexOf(u8, content, "\n") orelse content.len;
    const first_line = content[0..first_nl];

    // Parse session_meta
    const parsed = std.json.parseFromSlice(RolloutEntry, allocator, first_line, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidJsonFormat;
    defer parsed.deinit();

    const entry = parsed.value;
    if (!std.mem.eql(u8, entry.type, "session_meta")) {
        return error.InvalidJsonFormat;
    }

    const payload = entry.payload orelse return error.InvalidJsonFormat;

    // Parse timestamp from ISO format or filename
    const timestamp = parseTimestamp(entry.timestamp) orelse
        parseFilenameTimestamp(filename) orelse
        std.time.milliTimestamp();

    // Find first user message by scanning for response_item entries
    // Note: findFirstUserMessage returns a slice into content, so we must dupe it
    // before content is freed by the defer above
    // Skip abandoned sessions (no actual user prompt sent)
    const display_text = findFirstUserMessage(content) orelse
        return error.InvalidJsonFormat;

    // Dupe display_text BEFORE content is freed
    const display_owned = allocator.dupe(u8, display_text) catch return error.OutOfMemory;
    errdefer allocator.free(display_owned);

    // Get branch from git info - also dupe before parsed is freed
    const branch_owned: ?[]const u8 = if (payload.git) |git|
        if (git.branch) |b| (allocator.dupe(u8, b) catch null) else null
    else
        null;
    errdefer if (branch_owned) |b| allocator.free(b);

    // Dupe other fields
    const id_owned = allocator.dupe(u8, payload.id) catch return error.OutOfMemory;
    errdefer allocator.free(id_owned);

    const project_path_owned = allocator.dupe(u8, payload.cwd) catch return error.OutOfMemory;

    return SessionInfo{
        .allocator = allocator,
        .id = id_owned,
        .agent_type = .codex,
        .project_path = project_path_owned,
        .display = display_owned,
        .timestamp = timestamp,
        .branch = branch_owned,
    };
}

/// Find the first user message in the session file
/// Returns a slice into content (caller must dupe before content is freed)
fn findFirstUserMessage(content: []const u8) ?[]const u8 {
    var remaining = content;

    // Look for response_item with role":"user" that contains actual user prompt
    // Skip system context lines (instructions, environment_context, etc.)
    while (remaining.len > 0) {
        // Find end of current line
        const nl_pos = std.mem.indexOf(u8, remaining, "\n") orelse remaining.len;
        const line = remaining[0..nl_pos];

        // Check if this is a user message line
        if (std.mem.indexOf(u8, line, "\"role\":\"user\"") != null) {
            // Skip system context lines
            if (std.mem.indexOf(u8, line, "user_instructions") != null or
                std.mem.indexOf(u8, line, "environment_context") != null or
                std.mem.indexOf(u8, line, "INSTRUCTIONS") != null or
                std.mem.indexOf(u8, line, "AGENTS.md") != null)
            {
                // Skip this line, it's system context
            } else {
                // This is an actual user message - extract the text
                if (extractTextFromLine(line)) |message| {
                    return message;
                }
            }
        }

        // Move to next line
        if (nl_pos >= remaining.len) break;
        remaining = remaining[nl_pos + 1 ..];
    }

    return null;
}

/// Extract the "text" field value from a JSON line (for response_item format)
/// Format: {"payload":{"content":[{"type":"input_text","text":"actual message"}]}}
/// Returns a slice into the line
fn extractTextFromLine(line: []const u8) ?[]const u8 {
    // Find "text":" pattern (the user message content)
    const marker = "\"text\":\"";
    const start_idx = std.mem.indexOf(u8, line, marker) orelse return null;
    const msg_start = start_idx + marker.len;

    if (msg_start >= line.len) return null;

    // Find the end of the text (closing quote, handling escapes)
    var i: usize = msg_start;
    while (i < line.len) {
        if (line[i] == '\\' and i + 1 < line.len) {
            // Skip escaped character
            i += 2;
            continue;
        }
        if (line[i] == '"') {
            break;
        }
        i += 1;
    }

    if (i <= msg_start) return null;

    const message = line[msg_start..i];

    // Skip context injection messages (from skim's fallback resume)
    if (std.mem.startsWith(u8, message, "This is a continuation of a previous conversation")) {
        return null;
    }

    // Truncate to first 100 chars for display, stop at newline or escaped newline
    const max_len: usize = @min(message.len, 100);
    var end: usize = max_len;
    var j: usize = 0;
    while (j < max_len) {
        if (message[j] == '\n') {
            end = j;
            break;
        }
        // Check for escaped newline \n
        if (message[j] == '\\' and j + 1 < max_len and message[j + 1] == 'n') {
            end = j;
            break;
        }
        j += 1;
    }

    if (end > 0) {
        return message[0..end];
    }

    return null;
}

/// Parse ISO 8601 timestamp to Unix milliseconds
fn parseTimestamp(iso: []const u8) ?i64 {
    // Format: "2025-11-04T17:41:02.060Z"
    if (iso.len < 19) return null;

    // Parse components
    const year = std.fmt.parseInt(i32, iso[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u32, iso[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u32, iso[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u32, iso[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u32, iso[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u32, iso[17..19], 10) catch return null;

    // Parse milliseconds if present
    var millis: u32 = 0;
    if (iso.len > 20 and iso[19] == '.') {
        const ms_end = std.mem.indexOfScalar(u8, iso[20..], 'Z') orelse (iso.len - 20);
        const ms_digits: usize = @min(ms_end, 3);
        const ms_str = iso[20 .. 20 + ms_digits];
        millis = std.fmt.parseInt(u32, ms_str, 10) catch 0;
    }

    // Convert to epoch (simplified - ignores leap seconds)
    const days_since_epoch = daysSinceEpoch(year, month, day);
    const secs: i64 = @as(i64, days_since_epoch) * 86400 +
        @as(i64, hour) * 3600 +
        @as(i64, minute) * 60 +
        @as(i64, second);

    return secs * 1000 + @as(i64, millis);
}

/// Parse timestamp from rollout filename
/// Format: rollout-2025-11-04T12-41-02-<uuid>.jsonl
fn parseFilenameTimestamp(filename: []const u8) ?i64 {
    if (!std.mem.startsWith(u8, filename, "rollout-")) return null;

    const date_part = filename[8..]; // After "rollout-"
    if (date_part.len < 19) return null;

    // Format: 2025-11-04T12-41-02 (dashes instead of colons for time)
    const year = std.fmt.parseInt(i32, date_part[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u32, date_part[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u32, date_part[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u32, date_part[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u32, date_part[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u32, date_part[17..19], 10) catch return null;

    const days_since_epoch = daysSinceEpoch(year, month, day);
    const secs: i64 = @as(i64, days_since_epoch) * 86400 +
        @as(i64, hour) * 3600 +
        @as(i64, minute) * 60 +
        @as(i64, second);

    return secs * 1000;
}

/// Calculate days since Unix epoch (1970-01-01)
fn daysSinceEpoch(year: i32, month: u32, day: u32) i32 {
    // Simplified calculation
    var y = year;
    var m = month;
    if (m <= 2) {
        y -= 1;
        m += 12;
    }

    const a = @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400);
    const days = 365 * y + a + @as(i32, @intCast(@divFloor((153 * (m - 3) + 2), 5))) +
        @as(i32, @intCast(day)) - 719528;
    return days;
}

/// Extract basename from path
fn extractBasename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        return path[idx + 1 ..];
    }
    return path;
}

// =============================================================================
// JSON Types
// =============================================================================

const GitInfo = struct {
    branch: ?[]const u8 = null,
    commit_hash: ?[]const u8 = null,
    repository_url: ?[]const u8 = null,
};

const SessionMeta = struct {
    id: []const u8,
    cwd: []const u8,
    git: ?GitInfo = null,
};

const RolloutEntry = struct {
    type: []const u8,
    timestamp: []const u8,
    payload: ?SessionMeta = null,
};


// =============================================================================
// Tests
// =============================================================================

test "parseTimestamp ISO format" {
    const ts = parseTimestamp("2025-11-04T17:41:02.060Z");
    try std.testing.expect(ts != null);
}

test "parseFilenameTimestamp" {
    const ts = parseFilenameTimestamp("rollout-2025-11-04T12-41-02-019a4ff5-37c3-7a52-b235-b52d61bcda45.jsonl");
    try std.testing.expect(ts != null);
}

test "extractBasename" {
    try std.testing.expectEqualStrings("project", extractBasename("/Users/test/project"));
    try std.testing.expectEqualStrings("foo", extractBasename("foo"));
}
