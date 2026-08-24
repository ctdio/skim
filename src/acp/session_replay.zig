const std = @import("std");
const AgentState = @import("../agent/state.zig").AgentState;
const AgentMessage = @import("../agent/state.zig").Message;
const AcpManager = @import("manager.zig").AcpManager;

pub const ReplaySummary = struct {
    manager_status: AcpManager.Status = .session_active,
};

pub fn loadReplayLines(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    const file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 8 * 1024 * 1024);
    defer allocator.free(content);

    return loadReplayLinesFromString(allocator, content);
}

pub fn loadReplayLinesFromString(allocator: std.mem.Allocator, content: []const u8) ![][]const u8 {
    var lines_out: std.ArrayList([]const u8) = .{};
    errdefer {
        for (lines_out.items) |line| allocator.free(line);
        lines_out.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try lines_out.append(allocator, try allocator.dupe(u8, trimmed));
    }

    return lines_out.toOwnedSlice(allocator);
}

pub fn freeReplayLines(allocator: std.mem.Allocator, lines: [][]const u8) void {
    for (lines) |line| allocator.free(line);
    allocator.free(lines);
}

pub fn replaySessionFile(allocator: std.mem.Allocator, agent_state: *AgentState, path: []const u8) !ReplaySummary {
    const file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 8 * 1024 * 1024);
    defer allocator.free(content);

    return replaySessionFromString(allocator, agent_state, content);
}

pub fn replaySessionFromString(allocator: std.mem.Allocator, agent_state: *AgentState, content: []const u8) !ReplaySummary {
    var summary = ReplaySummary{};
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        try replaySessionLine(allocator, agent_state, line, &summary);
    }
    return summary;
}

pub fn replaySessionLine(allocator: std.mem.Allocator, agent_state: *AgentState, line: []const u8, summary: *ReplaySummary) !void {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return;

    const entry_type = getObjectString(root.object, "type") orelse return;
    if (std.mem.eql(u8, entry_type, "file-history-snapshot")) return;

    if (root.object.get("isMeta")) |is_meta| {
        if (is_meta == .bool and is_meta.bool) return;
    }

    const message_val = root.object.get("message") orelse return;
    if (message_val != .object) return;

    const role: AgentMessage.Role = if (std.mem.eql(u8, entry_type, "user"))
        .user
    else if (std.mem.eql(u8, entry_type, "assistant"))
        .agent
    else
        return;

    const content_val = message_val.object.get("content") orelse return;

    if (content_val == .string) {
        try addTextMessage(agent_state, role, content_val.string, summary);
        return;
    }
    if (content_val != .array) return;

    // Consecutive text blocks join into one message, which is how a single turn
    // reads. A tool block flushes the text before it so the transcript keeps the
    // order the agent produced.
    var text: std.ArrayList(u8) = .{};
    defer text.deinit(allocator);

    for (content_val.array.items) |item| {
        if (item != .object) continue;
        const block_type = getObjectString(item.object, "type") orelse continue;

        if (std.mem.eql(u8, block_type, "text")) {
            const chunk = getObjectString(item.object, "text") orelse continue;
            if (text.items.len > 0) try text.append(allocator, '\n');
            try text.appendSlice(allocator, chunk);
            continue;
        }

        try flushText(agent_state, role, &text, summary);

        if (std.mem.eql(u8, block_type, "tool_use")) {
            try replayToolUse(allocator, agent_state, item.object, summary);
        } else if (std.mem.eql(u8, block_type, "tool_result")) {
            try replayToolResult(allocator, agent_state, item.object, summary);
        }
    }

    try flushText(agent_state, role, &text, summary);
}

fn flushText(agent_state: *AgentState, role: AgentMessage.Role, text: *std.ArrayList(u8), summary: *ReplaySummary) !void {
    if (text.items.len == 0) return;
    try addTextMessage(agent_state, role, text.items, summary);
    text.clearRetainingCapacity();
}

fn addTextMessage(agent_state: *AgentState, role: AgentMessage.Role, content: []const u8, summary: *ReplaySummary) !void {
    if (content.len == 0 or shouldSkipContent(content)) return;
    try agent_state.addMessage(role, content);
    summary.manager_status = .session_active;
}

/// A `tool_use` block becomes a tool message. The tool name is the title, and
/// the JSON input rides along as the command so the arguments stay on screen.
///
/// A block may carry its own `title` instead, which then stands for the whole
/// call and the JSON is dropped. An agent log does not write one — this is for
/// a hand-written transcript, where the point is what the call does and not
/// every argument it takes. A live ACP session works the same way: the agent
/// sends a title, and the raw command only rides along when there is one.
fn replayToolUse(allocator: std.mem.Allocator, agent_state: *AgentState, block: std.json.ObjectMap, summary: *ReplaySummary) !void {
    const id = getObjectString(block, "id") orelse return;
    const name = getObjectString(block, "name") orelse return;
    const title = getObjectString(block, "title");

    var command: ?[]const u8 = null;
    defer if (command) |owned| allocator.free(owned);
    if (title == null) {
        if (block.get("input")) |input| {
            command = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(input, .{})});
        }
    }

    try agent_state.addToolMessage(id, name, title orelse name, command);
    summary.manager_status = .session_active;
}

/// A `tool_result` block closes the tool message its `tool_use_id` names.
fn replayToolResult(allocator: std.mem.Allocator, agent_state: *AgentState, block: std.json.ObjectMap, summary: *ReplaySummary) !void {
    const id = getObjectString(block, "tool_use_id") orelse return;

    const failed = if (block.get("is_error")) |flag| flag == .bool and flag.bool else false;

    const output = try toolResultText(allocator, block);
    defer allocator.free(output);

    try agent_state.updateToolMessage(
        id,
        if (failed) .failed else .completed,
        if (output.len == 0) null else output,
        null,
    );
    summary.manager_status = .session_active;
}

fn toolResultText(allocator: std.mem.Allocator, block: std.json.ObjectMap) ![]const u8 {
    const content = block.get("content") orelse return allocator.dupe(u8, "");
    if (content == .string) return allocator.dupe(u8, content.string);
    if (content != .array) return allocator.dupe(u8, "");

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);

    for (content.array.items) |item| {
        if (item != .object) continue;
        const text = getObjectString(item.object, "text") orelse continue;
        if (out.items.len > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, text);
    }

    return out.toOwnedSlice(allocator);
}

fn shouldSkipContent(content: []const u8) bool {
    return std.mem.startsWith(u8, content, "<command-name>") or
        std.mem.startsWith(u8, content, "<local-command");
}

fn getObjectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}
