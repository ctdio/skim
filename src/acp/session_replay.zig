const std = @import("std");
const AgentState = @import("../agent/state.zig").AgentState;
const AgentMessage = @import("../agent/state.zig").Message;
const AcpManager = @import("manager.zig").AcpManager;

pub const ReplaySummary = struct {
    manager_status: AcpManager.Status = .session_active,
};

const ReplayMessage = struct {
    role: AgentMessage.Role,
    content: []const u8,

    fn deinit(self: *ReplayMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
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

    var message = try parseReplayMessage(allocator, trimmed) orelse return;
    defer message.deinit(allocator);

    try agent_state.addMessage(message.role, message.content);
    summary.manager_status = .session_active;
}

fn parseReplayMessage(allocator: std.mem.Allocator, line: []const u8) !?ReplayMessage {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    const entry_type = getObjectString(root.object, "type") orelse return null;
    if (std.mem.eql(u8, entry_type, "file-history-snapshot")) return null;

    if (root.object.get("isMeta")) |is_meta| {
        if (is_meta == .bool and is_meta.bool) return null;
    }

    const message_val = root.object.get("message") orelse return null;
    if (message_val != .object) return null;

    const role: AgentMessage.Role = if (std.mem.eql(u8, entry_type, "user"))
        .user
    else if (std.mem.eql(u8, entry_type, "assistant"))
        .agent
    else
        return null;

    const content = try extractMessageContent(allocator, message_val.object);
    errdefer allocator.free(content);

    if (content.len == 0 or shouldSkipContent(content)) {
        allocator.free(content);
        return null;
    }

    return .{
        .role = role,
        .content = content,
    };
}

fn extractMessageContent(allocator: std.mem.Allocator, message: std.json.ObjectMap) ![]const u8 {
    const content_val = message.get("content") orelse return allocator.dupe(u8, "");

    if (content_val == .string) {
        return allocator.dupe(u8, content_val.string);
    }

    if (content_val == .array) {
        var result: std.ArrayList(u8) = .{};
        defer result.deinit(allocator);

        for (content_val.array.items) |item| {
            if (item != .object) continue;
            const block_type = getObjectString(item.object, "type") orelse continue;
            if (!std.mem.eql(u8, block_type, "text")) continue;

            const text = getObjectString(item.object, "text") orelse continue;
            if (result.items.len > 0) {
                try result.append(allocator, '\n');
            }
            try result.appendSlice(allocator, text);
        }

        return result.toOwnedSlice(allocator);
    }

    return allocator.dupe(u8, "");
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

test "replaySessionFromString replays transcript messages" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    const log =
        \\{"type":"user","message":{"role":"user","content":"Plan the replay work."}}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I’m checking the persisted session formats first."}]}}
    ;

    const summary = try replaySessionFromString(allocator, &agent_state, log);

    try std.testing.expectEqual(AcpManager.Status.session_active, summary.manager_status);
    try std.testing.expectEqual(@as(usize, 2), agent_state.messages.items.len);
    try std.testing.expectEqualStrings("Plan the replay work.", agent_state.messages.items[0].content);
    try std.testing.expectEqualStrings("I’m checking the persisted session formats first.", agent_state.messages.items[1].content);
}

test "replaySessionLine skips meta messages" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    var summary = ReplaySummary{};
    try replaySessionLine(
        allocator,
        &agent_state,
        \\{"type":"user","isMeta":true,"message":{"role":"user","content":"Ignore me"}}
    ,
        &summary,
    );

    try std.testing.expectEqual(@as(usize, 0), agent_state.messages.items.len);
}
