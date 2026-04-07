const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

// =============================================================================
// Session History Parser
// =============================================================================
// Parses raw session JSONL files to extract conversation history.
// Used as a fallback when agents don't support session/load.

pub const HistoryMessage = struct {
    allocator: Allocator,
    role: Role,
    content: []const u8,
    timestamp: ?i64,

    pub const Role = enum { user, assistant, system };

    pub fn deinit(self: *HistoryMessage) void {
        self.allocator.free(self.content);
    }
};

pub const ParseError = error{
    FileNotFound,
    IoError,
    OutOfMemory,
};

/// Parse Claude Code session file and extract conversation messages
pub fn parseClaudeSession(
    allocator: Allocator,
    session_id: []const u8,
    project_path: []const u8,
) ParseError![]HistoryMessage {
    const home = std.posix.getenv("HOME") orelse return error.FileNotFound;

    // Escape project path (/ -> -)
    var escaped_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var escaped_len: usize = 0;
    for (project_path) |c| {
        if (escaped_len >= escaped_path_buf.len) break;
        escaped_path_buf[escaped_len] = if (c == '/') '-' else c;
        escaped_len += 1;
    }
    const escaped_path = escaped_path_buf[0..escaped_len];

    // Build path to session file
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const session_path = std.fmt.bufPrint(&path_buf, "{s}/.claude/projects/{s}/{s}.jsonl", .{
        home,
        escaped_path,
        session_id,
    }) catch return error.IoError;

    return parseSessionFile(allocator, session_path, .claude_code);
}

/// Parse Codex session file
pub fn parseCodexSession(
    allocator: Allocator,
    session_id: []const u8,
) ParseError![]HistoryMessage {
    const session_file = try findCodexSessionFile(allocator, session_id);
    defer allocator.free(session_file);

    return parseSessionFile(allocator, session_file, .codex);
}

pub fn findCodexSessionFile(allocator: Allocator, session_id: []const u8) ParseError![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.FileNotFound;

    var sessions_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sessions_dir = std.fmt.bufPrint(&sessions_path_buf, "{s}/.codex/sessions", .{home}) catch {
        return error.IoError;
    };

    return findCodexSessionFileInDir(allocator, sessions_dir, session_id) catch error.FileNotFound;
}

fn findCodexSessionFileInDir(allocator: Allocator, base_dir: []const u8, session_id: []const u8) ![]const u8 {
    // Walk year directories
    var base = std.fs.openDirAbsolute(base_dir, .{ .iterate = true }) catch return error.FileNotFound;
    defer base.close();

    var year_iter = base.iterate();
    while (year_iter.next() catch null) |year_entry| {
        if (year_entry.kind != .directory) continue;

        var year_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const year_path = std.fmt.bufPrint(&year_path_buf, "{s}/{s}", .{ base_dir, year_entry.name }) catch continue;

        var year_dir = std.fs.openDirAbsolute(year_path, .{ .iterate = true }) catch continue;
        defer year_dir.close();

        var month_iter = year_dir.iterate();
        while (month_iter.next() catch null) |month_entry| {
            if (month_entry.kind != .directory) continue;

            var month_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const month_path = std.fmt.bufPrint(&month_path_buf, "{s}/{s}", .{ year_path, month_entry.name }) catch continue;

            var month_dir = std.fs.openDirAbsolute(month_path, .{ .iterate = true }) catch continue;
            defer month_dir.close();

            var day_iter = month_dir.iterate();
            while (day_iter.next() catch null) |day_entry| {
                if (day_entry.kind != .directory) continue;

                var day_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const day_path = std.fmt.bufPrint(&day_path_buf, "{s}/{s}", .{ month_path, day_entry.name }) catch continue;

                var day_dir = std.fs.openDirAbsolute(day_path, .{ .iterate = true }) catch continue;
                defer day_dir.close();

                var file_iter = day_dir.iterate();
                while (file_iter.next() catch null) |file_entry| {
                    if (file_entry.kind != .file) continue;
                    if (!std.mem.endsWith(u8, file_entry.name, ".jsonl")) continue;

                    // Check if filename contains session ID
                    if (std.mem.indexOf(u8, file_entry.name, session_id) != null) {
                        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ day_path, file_entry.name });
                    }
                }
            }
        }
    }

    return error.FileNotFound;
}

const AgentFormat = enum { claude_code, codex };

fn parseSessionFile(
    allocator: Allocator,
    path: []const u8,
    format: AgentFormat,
) ParseError![]HistoryMessage {
    const file = std.fs.openFileAbsolute(path, .{}) catch return error.FileNotFound;
    defer file.close();

    // Read file (limit to 50MB for safety)
    const content = file.readToEndAlloc(allocator, 50 * 1024 * 1024) catch return error.IoError;
    defer allocator.free(content);

    var messages: std.ArrayList(HistoryMessage) = .{};
    errdefer {
        for (messages.items) |*m| m.deinit();
        messages.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const msg = switch (format) {
            .claude_code => parseClaudeLine(allocator, line),
            .codex => parseCodexLine(allocator, line),
        } catch continue;

        if (msg) |m| {
            messages.append(allocator, m) catch return error.OutOfMemory;
        }
    }

    return messages.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn parseClaudeLine(allocator: Allocator, line: []const u8) !?HistoryMessage {
    // Parse as dynamic JSON value first
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    // Get type field
    const type_val = root.object.get("type") orelse return null;
    if (type_val != .string) return null;
    const entry_type = type_val.string;

    // Skip non-message entries
    if (std.mem.eql(u8, entry_type, "file-history-snapshot")) return null;

    // Skip meta messages
    if (root.object.get("isMeta")) |is_meta| {
        if (is_meta == .bool and is_meta.bool) return null;
    }

    // Get message object
    const message_val = root.object.get("message") orelse return null;
    if (message_val != .object) return null;

    // Extract content
    const content = extractClaudeContent(allocator, message_val.object) catch return null;
    if (content.len == 0) {
        allocator.free(content);
        return null;
    }

    // Skip command-like messages
    if (std.mem.startsWith(u8, content, "<command-name>") or
        std.mem.startsWith(u8, content, "<local-command"))
    {
        allocator.free(content);
        return null;
    }

    const role: HistoryMessage.Role = if (std.mem.eql(u8, entry_type, "user"))
        .user
    else if (std.mem.eql(u8, entry_type, "assistant"))
        .assistant
    else {
        allocator.free(content);
        return null;
    };

    return HistoryMessage{
        .allocator = allocator,
        .role = role,
        .content = content,
        .timestamp = null,
    };
}

fn extractClaudeContent(allocator: Allocator, message: std.json.ObjectMap) ![]const u8 {
    const content_val = message.get("content") orelse return allocator.dupe(u8, "");

    // String content (user messages)
    if (content_val == .string) {
        return allocator.dupe(u8, content_val.string);
    }

    // Array content (assistant messages)
    if (content_val == .array) {
        var result: std.ArrayList(u8) = .{};
        errdefer result.deinit(allocator);

        for (content_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const type_field = obj.get("type") orelse continue;
            if (type_field != .string) continue;

            if (std.mem.eql(u8, type_field.string, "text")) {
                const text_field = obj.get("text") orelse continue;
                if (text_field != .string) continue;

                if (result.items.len > 0) {
                    result.append(allocator, '\n') catch {};
                }
                result.appendSlice(allocator, text_field.string) catch {};
            }
        }

        return result.toOwnedSlice(allocator);
    }

    return allocator.dupe(u8, "");
}

fn parseCodexLine(allocator: Allocator, line: []const u8) !?HistoryMessage {
    const parsed = std.json.parseFromSlice(CodexEntry, allocator, line, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    const entry = parsed.value;

    // Only parse response_item entries with messages
    if (entry.type == null) return null;
    if (!std.mem.eql(u8, entry.type.?, "response_item")) return null;

    const payload = entry.payload orelse return null;
    if (payload.type == null) return null;
    if (!std.mem.eql(u8, payload.type.?, "message")) return null;

    const role_str = payload.role orelse return null;
    const role: HistoryMessage.Role = if (std.mem.eql(u8, role_str, "user"))
        .user
    else if (std.mem.eql(u8, role_str, "assistant"))
        .assistant
    else
        return null;

    // Extract text content
    const content_blocks = payload.content orelse return null;
    var result: std.ArrayList(u8) = .{};
    defer result.deinit(allocator);

    for (content_blocks) |block| {
        if (block.type) |t| {
            if (std.mem.eql(u8, t, "input_text") or std.mem.eql(u8, t, "output_text")) {
                if (block.text) |text| {
                    // Skip system/instruction messages
                    if (std.mem.startsWith(u8, text, "<user_instructions>")) continue;
                    if (std.mem.startsWith(u8, text, "<environment_context>")) continue;

                    if (result.items.len > 0) {
                        result.append(allocator, '\n') catch {};
                    }
                    result.appendSlice(allocator, text) catch {};
                }
            }
        }
    }

    if (result.items.len == 0) return null;

    return HistoryMessage{
        .allocator = allocator,
        .role = role,
        .content = result.toOwnedSlice(allocator) catch return null,
        .timestamp = null,
    };
}

// =============================================================================
// JSON Types (for Codex - simpler structure)
// =============================================================================

const CodexEntry = struct {
    type: ?[]const u8 = null,
    payload: ?CodexPayload = null,
};

const CodexPayload = struct {
    type: ?[]const u8 = null,
    role: ?[]const u8 = null,
    content: ?[]const CodexContentBlock = null,
};

const CodexContentBlock = struct {
    type: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

// =============================================================================
// Public API
// =============================================================================

/// Free a list of history messages
pub fn freeMessages(allocator: Allocator, messages: []HistoryMessage) void {
    for (messages) |*m| m.deinit();
    allocator.free(messages);
}

// =============================================================================
// Tests
// =============================================================================

test "parseClaudeLine user message" {
    const allocator = std.testing.allocator;

    const line =
        \\{"type":"user","message":{"role":"user","content":"Hello world"}}
    ;

    const result = try parseClaudeLine(allocator, line);
    try std.testing.expect(result != null);

    var msg = result.?;
    defer msg.deinit();

    try std.testing.expectEqual(HistoryMessage.Role.user, msg.role);
    try std.testing.expectEqualStrings("Hello world", msg.content);
}

test "parseClaudeLine skips meta messages" {
    const allocator = std.testing.allocator;

    const line =
        \\{"type":"user","isMeta":true,"message":{"role":"user","content":"test"}}
    ;

    const result = try parseClaudeLine(allocator, line);
    try std.testing.expect(result == null);
}

test "parseClaudeLine skips file snapshots" {
    const allocator = std.testing.allocator;

    const line =
        \\{"type":"file-history-snapshot","messageId":"abc"}
    ;

    const result = try parseClaudeLine(allocator, line);
    try std.testing.expect(result == null);
}
