const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const SessionInfo = types.SessionInfo;
const SessionDiscoveryError = types.SessionDiscoveryError;

// =============================================================================
// Claude Code Session Discovery
// =============================================================================

// How many session files to read for detailed info (branches, message counts)
// Sessions beyond this limit use history.jsonl data only
const MAX_SESSION_FILES_TO_READ = 50;

/// Discover sessions from Claude Code
/// Uses a two-tier approach for performance:
/// 1. Reads ~/.claude/history.jsonl to find sessionIds and timestamps
/// 2. Sorts by timestamp from history (fast)
/// 3. Only reads session files for the top N most recent sessions
pub fn listSessions(
    allocator: Allocator,
    cwd: []const u8,
    limit: usize,
) SessionDiscoveryError![]SessionInfo {
    const home = std.posix.getenv("HOME") orelse return error.HomeDirectoryNotFound;

    // Step 1: Read history.jsonl to find unique sessionIds for this project
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const history_path = std.fmt.bufPrint(&path_buf, "{s}/.claude/history.jsonl", .{home}) catch {
        return error.IoError;
    };

    const file = std.fs.openFileAbsolute(history_path, .{}) catch {
        return error.SessionDirectoryNotFound;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        return error.IoError;
    };
    defer allocator.free(content);

    // Collect unique sessionIds with their first display text and last timestamp from history
    var session_list: std.ArrayList(HistoryAggregate) = .{};
    defer {
        for (session_list.items) |*agg| {
            allocator.free(agg.session_id);
            allocator.free(agg.first_display);
        }
        session_list.deinit(allocator);
    }

    // Use a set to track seen session IDs
    var seen_ids = std.StringHashMap(usize).init(allocator); // value = index in session_list
    defer seen_ids.deinit();

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const parsed = std.json.parseFromSlice(HistoryEntry, allocator, line, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        defer parsed.deinit();

        const entry = parsed.value;

        // Filter by project path (exact match)
        if (!std.mem.eql(u8, entry.project, cwd)) continue;

        // Skip entries without sessionId
        const session_id = entry.sessionId orelse continue;

        if (seen_ids.get(session_id)) |idx| {
            // Update timestamp if newer
            if (entry.timestamp > session_list.items[idx].last_timestamp) {
                session_list.items[idx].last_timestamp = entry.timestamp;
            }
        } else {
            const id_copy = allocator.dupe(u8, session_id) catch return error.OutOfMemory;
            errdefer allocator.free(id_copy);

            const display_copy = allocator.dupe(u8, entry.display) catch return error.OutOfMemory;

            const idx = session_list.items.len;
            session_list.append(allocator, .{
                .session_id = id_copy,
                .first_display = display_copy,
                .last_timestamp = entry.timestamp,
            }) catch return error.OutOfMemory;

            seen_ids.put(session_id, idx) catch return error.OutOfMemory;
        }
    }

    // Step 2: Sort by timestamp from history (fast - no file I/O)
    std.mem.sort(HistoryAggregate, session_list.items, {}, struct {
        fn lessThan(_: void, a: HistoryAggregate, b: HistoryAggregate) bool {
            return a.last_timestamp > b.last_timestamp; // Descending
        }
    }.lessThan);

    // Step 3: Build SessionInfo list
    // Only read session files for the top MAX_SESSION_FILES_TO_READ sessions
    var sessions: std.ArrayList(SessionInfo) = .{};
    errdefer {
        for (sessions.items) |*s| s.deinit();
        sessions.deinit(allocator);
    }

    // Build escaped project path for session file lookup
    const escaped_path = escapeProjectPath(allocator, cwd) catch return error.OutOfMemory;
    defer allocator.free(escaped_path);

    // Process sessions - read files only for recent ones
    const files_to_read = @min(session_list.items.len, MAX_SESSION_FILES_TO_READ);

    std.log.info("Session discovery: found {d} unique sessions in history, reading files for top {d}", .{ session_list.items.len, files_to_read });

    for (session_list.items, 0..) |history_agg, idx| {
        const session_id = history_agg.session_id;

        // For recent sessions, try to read the session file for accurate data
        if (idx < files_to_read) {
            var session_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const session_path = std.fmt.bufPrint(&session_path_buf, "{s}/.claude/projects/{s}/{s}.jsonl", .{
                home,
                escaped_path,
                session_id,
            }) catch {
                // Fall back to history data
                appendHistorySession(allocator, &sessions, session_id, cwd, history_agg) catch continue;
                continue;
            };

            // Try to read session file for accurate data
            const session_data = readSessionFile(allocator, session_path) catch {
                // Fall back to history data
                appendHistorySession(allocator, &sessions, session_id, cwd, history_agg) catch continue;
                continue;
            };
            defer freeSessionData(allocator, session_data);

            // Use session as a single entry (don't expand branches - resuming gives the whole session)
            // If we have branches, use the most recent branch's info for display
            const display = if (session_data.branches.len > 0) blk: {
                // Find most recent branch by timestamp
                var best_branch = session_data.branches[0];
                for (session_data.branches[1..]) |branch| {
                    if (branch.timestamp > best_branch.timestamp) {
                        best_branch = branch;
                    }
                }
                break :blk best_branch.summary;
            } else if (session_data.first_user_message.len > 0)
                session_data.first_user_message
            else
                history_agg.first_display;

            const timestamp = if (session_data.last_timestamp > 0)
                session_data.last_timestamp
            else
                history_agg.last_timestamp;

            // Get last message if available and different from display
            const last_msg: ?[]const u8 = if (session_data.last_user_message.len > 0 and
                !std.mem.eql(u8, session_data.last_user_message, display))
                allocator.dupe(u8, session_data.last_user_message) catch null
            else
                null;

            const info = SessionInfo{
                .allocator = allocator,
                .id = allocator.dupe(u8, session_id) catch continue,
                .agent_type = .claude_code,
                .project_path = allocator.dupe(u8, cwd) catch continue,
                .display = allocator.dupe(u8, display) catch continue,
                .timestamp = timestamp,
                .message_count = session_data.total_message_count,
                .last_message = last_msg,
            };
            sessions.append(allocator, info) catch continue;
        } else {
            // For older sessions, just use history data (no file read)
            appendHistorySession(allocator, &sessions, session_id, cwd, history_agg) catch continue;
        }

        // Early exit if we have enough sessions
        if (sessions.items.len >= limit) {
            std.log.info("Session discovery: reached limit at idx {d}", .{idx});
            break;
        }
    }

    std.log.info("Session discovery: collected {d} sessions, limit is {d}", .{ sessions.items.len, limit });

    // Sort by timestamp (most recent first)
    std.mem.sort(SessionInfo, sessions.items, {}, struct {
        fn lessThan(_: void, a: SessionInfo, b: SessionInfo) bool {
            return a.timestamp > b.timestamp;
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

/// Append a session using only history.jsonl data (no file read)
fn appendHistorySession(
    allocator: Allocator,
    sessions: *std.ArrayList(SessionInfo),
    session_id: []const u8,
    cwd: []const u8,
    history_agg: HistoryAggregate,
) !void {
    const info = SessionInfo{
        .allocator = allocator,
        .id = try allocator.dupe(u8, session_id),
        .agent_type = .claude_code,
        .project_path = try allocator.dupe(u8, cwd),
        .display = try allocator.dupe(u8, history_agg.first_display),
        .timestamp = history_agg.last_timestamp,
        .message_count = 0, // Unknown without reading file
    };
    try sessions.append(allocator, info);
}

/// Escape project path for Claude Code's directory naming
/// Converts "/" to "-"
pub fn escapeProjectPath(allocator: Allocator, path: []const u8) Allocator.Error![]u8 {
    var result = try allocator.alloc(u8, path.len);
    for (path, 0..) |c, i| {
        result[i] = if (c == '/') '-' else c;
    }
    return result;
}

// =============================================================================
// Session File Parsing
// =============================================================================

/// Data extracted from a session file
const SessionFileData = struct {
    branches: []Branch,
    first_user_message: []const u8,
    last_user_message: []const u8,
    total_message_count: usize,
    last_timestamp: i64,
};

/// A conversation branch in a session
const Branch = struct {
    leaf_uuid: []const u8,
    summary: []const u8,
    timestamp: i64,
    message_count: usize,
};

/// Aggregate data from history.jsonl
const HistoryAggregate = struct {
    session_id: []const u8,
    first_display: []const u8,
    last_timestamp: i64,
};

/// Extract text content from a message content field
/// Handles both string content and array of content blocks
fn extractTextContent(content_val: std.json.Value) []const u8 {
    // Case 1: content is a string
    if (content_val == .string) {
        return content_val.string;
    }

    // Case 2: content is an array of content blocks
    // Look for the first text block: {"type": "text", "text": "..."}
    if (content_val == .array) {
        for (content_val.array.items) |item| {
            if (item == .object) {
                const type_field = item.object.get("type") orelse continue;
                if (type_field == .string and std.mem.eql(u8, type_field.string, "text")) {
                    const text_field = item.object.get("text") orelse continue;
                    if (text_field == .string) {
                        return text_field.string;
                    }
                }
            }
        }
    }

    return "";
}

/// Read a session file and extract metadata
/// Optimized for speed - only parses what we need
fn readSessionFile(allocator: Allocator, path: []const u8) !SessionFileData {
    const file = std.fs.openFileAbsolute(path, .{}) catch return error.IoError;
    defer file.close();

    // Read file (limit to 50MB)
    const content = file.readToEndAlloc(allocator, 50 * 1024 * 1024) catch return error.IoError;
    defer allocator.free(content);

    var branches: std.ArrayList(Branch) = .{};
    errdefer {
        for (branches.items) |b| {
            allocator.free(b.leaf_uuid);
            allocator.free(b.summary);
        }
        branches.deinit(allocator);
    }

    var first_user_message: []const u8 = "";
    var first_user_message_owned = false;
    errdefer if (first_user_message_owned) allocator.free(first_user_message);

    var last_user_message: []const u8 = "";
    var last_user_message_owned = false;
    errdefer if (last_user_message_owned) allocator.free(last_user_message);

    var total_user_count: usize = 0;
    var total_assistant_count: usize = 0;
    var last_timestamp: i64 = 0;

    // Track messages per branch (leafUuid)
    var branch_counts = std.StringHashMap(usize).init(allocator);
    defer branch_counts.deinit();

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Quick check for entry type without full JSON parse
        // Look for "type":" pattern
        const type_start = std.mem.indexOf(u8, line, "\"type\":\"") orelse continue;
        const type_value_start = type_start + 8;
        const type_end = std.mem.indexOfPos(u8, line, type_value_start, "\"") orelse continue;
        const entry_type = line[type_value_start..type_end];

        // Handle summary entries (conversation branches) - need full parse
        if (std.mem.eql(u8, entry_type, "summary")) {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
            defer parsed.deinit();

            const root = parsed.value;
            if (root != .object) continue;

            const summary_val = root.object.get("summary") orelse continue;
            const leaf_uuid_val = root.object.get("leafUuid") orelse continue;

            if (summary_val != .string or leaf_uuid_val != .string) continue;

            var branch_timestamp: i64 = 0;
            if (root.object.get("timestamp")) |ts_val| {
                if (ts_val == .string) {
                    branch_timestamp = parseIsoTimestamp(ts_val.string) catch 0;
                } else if (ts_val == .integer) {
                    branch_timestamp = ts_val.integer;
                }
            }

            const msg_count = branch_counts.get(leaf_uuid_val.string) orelse 0;

            const branch = Branch{
                .leaf_uuid = allocator.dupe(u8, leaf_uuid_val.string) catch continue,
                .summary = allocator.dupe(u8, summary_val.string) catch continue,
                .timestamp = branch_timestamp,
                .message_count = msg_count,
            };
            branches.append(allocator, branch) catch continue;
            continue;
        }

        // Count user/assistant messages without full JSON parse
        if (std.mem.eql(u8, entry_type, "user")) {
            // Check for isMeta:true to skip
            if (std.mem.indexOf(u8, line, "\"isMeta\":true") != null) continue;

            total_user_count += 1;

            // Track per-branch count - extract leafUuid quickly
            if (std.mem.indexOf(u8, line, "\"leafUuid\":\"")) |leaf_start| {
                const uuid_start = leaf_start + 12;
                if (std.mem.indexOfPos(u8, line, uuid_start, "\"")) |uuid_end| {
                    const leaf_uuid = line[uuid_start..uuid_end];
                    const count = branch_counts.get(leaf_uuid) orelse 0;
                    branch_counts.put(leaf_uuid, count + 1) catch {};
                }
            }

            // Parse user message content - need to do this for first and last message tracking
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
            defer parsed.deinit();

            if (parsed.value == .object) {
                if (parsed.value.object.get("message")) |msg_val| {
                    if (msg_val == .object) {
                        if (msg_val.object.get("content")) |content_val| {
                            const msg_content = extractTextContent(content_val);
                            if (msg_content.len > 0 and
                                !std.mem.startsWith(u8, msg_content, "<command-name>") and
                                !std.mem.startsWith(u8, msg_content, "<local-command"))
                            {
                                // Capture first user message if we haven't yet
                                if (first_user_message.len == 0) {
                                    first_user_message = allocator.dupe(u8, msg_content) catch "";
                                    first_user_message_owned = first_user_message.len > 0;
                                }
                                // Always update last user message (free previous if owned)
                                if (last_user_message_owned) {
                                    allocator.free(last_user_message);
                                }
                                last_user_message = allocator.dupe(u8, msg_content) catch "";
                                last_user_message_owned = last_user_message.len > 0;
                            }
                        }
                    }
                }
            }

            // Extract timestamp quickly
            if (std.mem.indexOf(u8, line, "\"timestamp\":\"")) |ts_start| {
                const ts_value_start = ts_start + 13;
                if (std.mem.indexOfPos(u8, line, ts_value_start, "\"")) |ts_end| {
                    const ts = parseIsoTimestamp(line[ts_value_start..ts_end]) catch 0;
                    if (ts > last_timestamp) last_timestamp = ts;
                }
            }
        } else if (std.mem.eql(u8, entry_type, "assistant")) {
            total_assistant_count += 1;

            // Track per-branch count
            if (std.mem.indexOf(u8, line, "\"leafUuid\":\"")) |leaf_start| {
                const uuid_start = leaf_start + 12;
                if (std.mem.indexOfPos(u8, line, uuid_start, "\"")) |uuid_end| {
                    const leaf_uuid = line[uuid_start..uuid_end];
                    const count = branch_counts.get(leaf_uuid) orelse 0;
                    branch_counts.put(leaf_uuid, count + 1) catch {};
                }
            }

            // Extract timestamp quickly
            if (std.mem.indexOf(u8, line, "\"timestamp\":\"")) |ts_start| {
                const ts_value_start = ts_start + 13;
                if (std.mem.indexOfPos(u8, line, ts_value_start, "\"")) |ts_end| {
                    const ts = parseIsoTimestamp(line[ts_value_start..ts_end]) catch 0;
                    if (ts > last_timestamp) last_timestamp = ts;
                }
            }
        }
    }

    // Update branch message counts from our tracking
    for (branches.items) |*branch| {
        if (branch_counts.get(branch.leaf_uuid)) |count| {
            branch.message_count = count;
        }
    }

    // If we have branches but their timestamps are 0, use the session's last timestamp
    for (branches.items) |*branch| {
        if (branch.timestamp == 0) {
            branch.timestamp = last_timestamp;
        }
    }

    return SessionFileData{
        .branches = branches.toOwnedSlice(allocator) catch return error.OutOfMemory,
        .first_user_message = first_user_message,
        .last_user_message = last_user_message,
        .total_message_count = total_user_count + total_assistant_count,
        .last_timestamp = last_timestamp,
    };
}

fn freeSessionData(allocator: Allocator, data: SessionFileData) void {
    for (data.branches) |branch| {
        allocator.free(branch.leaf_uuid);
        allocator.free(branch.summary);
    }
    allocator.free(data.branches);
    if (data.first_user_message.len > 0) {
        allocator.free(data.first_user_message);
    }
    if (data.last_user_message.len > 0) {
        allocator.free(data.last_user_message);
    }
}

/// Parse ISO 8601 timestamp to Unix milliseconds
fn parseIsoTimestamp(iso: []const u8) !i64 {
    // Format: "2025-12-31T17:57:29.254Z"
    if (iso.len < 20) return error.InvalidFormat;

    // Parse components
    const year = std.fmt.parseInt(i32, iso[0..4], 10) catch return error.InvalidFormat;
    const month = std.fmt.parseInt(u8, iso[5..7], 10) catch return error.InvalidFormat;
    const day = std.fmt.parseInt(u8, iso[8..10], 10) catch return error.InvalidFormat;
    const hour = std.fmt.parseInt(u8, iso[11..13], 10) catch return error.InvalidFormat;
    const minute = std.fmt.parseInt(u8, iso[14..16], 10) catch return error.InvalidFormat;
    const second = std.fmt.parseInt(u8, iso[17..19], 10) catch return error.InvalidFormat;

    // Parse milliseconds if present
    var millis: i64 = 0;
    if (iso.len >= 23 and iso[19] == '.') {
        millis = std.fmt.parseInt(i64, iso[20..23], 10) catch 0;
    }

    // Calculate days from epoch (1970-01-01) using manual calculation
    const days_since_epoch = daysSinceEpoch(year, month, day);

    const epoch_secs: i64 = days_since_epoch * 86400 +
        @as(i64, hour) * 3600 +
        @as(i64, minute) * 60 +
        @as(i64, second);

    return epoch_secs * 1000 + millis;
}

/// Calculate days since Unix epoch (1970-01-01)
fn daysSinceEpoch(year: i32, month: u8, day: u8) i64 {
    // Days in each month (non-leap year)
    const days_before_month = [_]i32{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };

    // Calculate years since 1970
    const y = year - 1;
    const era_days = y * 365 + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400);

    // Days from 0 to 1970-01-01
    const epoch_days: i32 = 1969 * 365 + @divFloor(@as(i32, 1969), 4) - @divFloor(@as(i32, 1969), 100) + @divFloor(@as(i32, 1969), 400);

    // Days in current year
    const is_leap = (@mod(year, 4) == 0 and @mod(year, 100) != 0) or (@mod(year, 400) == 0);
    var year_days = days_before_month[@as(usize, month) - 1] + @as(i32, day) - 1;
    if (is_leap and month > 2) year_days += 1;

    return @as(i64, era_days + year_days - epoch_days);
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

test "parseIsoTimestamp" {
    const ts = try parseIsoTimestamp("2025-12-31T17:57:29.254Z");
    // Should be roughly 1767207449254 (Dec 31, 2025)
    try std.testing.expect(ts > 1767000000000);
    try std.testing.expect(ts < 1768000000000);
}

test "daysSinceEpoch" {
    // 1970-01-01 should be day 0
    try std.testing.expectEqual(@as(i64, 0), daysSinceEpoch(1970, 1, 1));
    // 1970-01-02 should be day 1
    try std.testing.expectEqual(@as(i64, 1), daysSinceEpoch(1970, 1, 2));
    // 2000-01-01 should be ~10957 days (30 years)
    const y2k = daysSinceEpoch(2000, 1, 1);
    try std.testing.expect(y2k > 10950 and y2k < 10965);
}
