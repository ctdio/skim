const std = @import("std");
const AgentState = @import("../agent/state.zig").AgentState;
const AgentMessage = @import("../agent/state.zig").Message;
const CodexManager = @import("manager.zig").CodexManager;

pub const ReplaySummary = struct {
    manager_status: CodexManager.Status = .thread_active,
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

    try replayLine(allocator, agent_state, trimmed, summary);
}

fn replayLine(allocator: std.mem.Allocator, agent_state: *AgentState, line: []const u8, summary: *ReplaySummary) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return;

    const entry_type = getObjectString(root.object, "type") orelse return;
    if (std.mem.eql(u8, entry_type, "event_msg")) {
        const payload = getObjectValue(root.object, "payload") orelse return;
        if (payload != .object) return;
        try replayEventMessage(agent_state, payload.object, summary);
        return;
    }

    if (std.mem.eql(u8, entry_type, "response_item")) {
        const payload = getObjectValue(root.object, "payload") orelse return;
        if (payload != .object) return;
        try replayResponseItem(allocator, agent_state, payload.object);
    }
}

fn replayEventMessage(agent_state: *AgentState, payload: std.json.ObjectMap, summary: *ReplaySummary) !void {
    const payload_type = getObjectString(payload, "type") orelse return;

    if (std.mem.eql(u8, payload_type, "task_started")) {
        summary.manager_status = .turn_active;
        return;
    }

    if (std.mem.eql(u8, payload_type, "task_complete")) {
        summary.manager_status = .thread_active;
        return;
    }

    if (std.mem.eql(u8, payload_type, "agent_message")) {
        const message = getObjectString(payload, "message") orelse return;
        if (message.len == 0) return;
        try agent_state.addCompletedAgentMessage(message);
        return;
    }

    if (std.mem.eql(u8, payload_type, "item_completed")) {
        const item = getObjectValue(payload, "item") orelse return;
        if (item != .object) return;
        try replayCompletedItem(agent_state, item.object);
        return;
    }

    if (std.mem.eql(u8, payload_type, "token_count")) {
        applyTokenCount(agent_state, payload);
    }
}

fn replayCompletedItem(agent_state: *AgentState, item: std.json.ObjectMap) !void {
    const item_type = getObjectString(item, "type") orelse return;

    if (std.mem.eql(u8, item_type, "Plan") or std.mem.eql(u8, item_type, "plan")) {
        const text = getObjectString(item, "text") orelse return;
        if (text.len == 0) return;
        try agent_state.addCompletedAgentMessage(text);
        return;
    }

    if (std.mem.eql(u8, item_type, "agentMessage") or std.mem.eql(u8, item_type, "agent_message")) {
        const text = getObjectString(item, "text") orelse return;
        if (text.len == 0) return;
        try agent_state.addCompletedAgentMessage(text);
    }
}

fn replayResponseItem(allocator: std.mem.Allocator, agent_state: *AgentState, payload: std.json.ObjectMap) !void {
    const payload_type = getObjectString(payload, "type") orelse return;

    if (std.mem.eql(u8, payload_type, "message")) {
        const role = getObjectString(payload, "role") orelse return;
        if (!std.mem.eql(u8, role, "user")) return;

        const content_value = getObjectValue(payload, "content") orelse return;
        if (content_value != .array) return;

        const text = extractMessageText(allocator, content_value.array.items) catch return;
        defer allocator.free(text);

        if (!shouldDisplayUserMessage(text)) return;
        try agent_state.addMessage(.user, text);
        return;
    }

    if (std.mem.eql(u8, payload_type, "function_call")) {
        const call_id = getObjectString(payload, "call_id") orelse return;
        const name = getObjectString(payload, "name") orelse return;
        const arguments = getObjectString(payload, "arguments");
        const command = extractToolCommand(allocator, name, arguments);
        const title = command orelse name;
        try agent_state.addToolMessage(call_id, name, title, command);
        return;
    }

    if (std.mem.eql(u8, payload_type, "function_call_output")) {
        const call_id = getObjectString(payload, "call_id") orelse return;
        const output = getObjectString(payload, "output");
        try agent_state.updateToolMessage(call_id, .completed, output, null);
    }
}

fn extractMessageText(allocator: std.mem.Allocator, blocks: []const std.json.Value) ![]const u8 {
    var result: std.ArrayList(u8) = .{};
    defer result.deinit(allocator);

    for (blocks) |block| {
        if (block != .object) continue;
        const block_type = getObjectString(block.object, "type") orelse continue;
        if (!std.mem.eql(u8, block_type, "input_text") and !std.mem.eql(u8, block_type, "output_text")) {
            continue;
        }

        const text = getObjectString(block.object, "text") orelse continue;
        if (result.items.len > 0) {
            try result.append(allocator, '\n');
        }
        try result.appendSlice(allocator, text);
    }

    return result.toOwnedSlice(allocator);
}

fn shouldDisplayUserMessage(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) return false;
    if (std.mem.startsWith(u8, trimmed, "# AGENTS.md instructions for ")) return false;
    if (std.mem.startsWith(u8, trimmed, "<environment_context>")) return false;
    if (std.mem.startsWith(u8, trimmed, "<turn_aborted>")) return false;
    return true;
}

fn extractToolCommand(allocator: std.mem.Allocator, name: []const u8, arguments: ?[]const u8) ?[]const u8 {
    const args = arguments orelse return null;
    if (!std.mem.eql(u8, name, "exec_command")) return args;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{
        .ignore_unknown_fields = true,
    }) catch return args;
    defer parsed.deinit();

    if (parsed.value != .object) return args;
    return getObjectString(parsed.value.object, "cmd") orelse args;
}

fn applyTokenCount(agent_state: *AgentState, payload: std.json.ObjectMap) void {
    const info = getObjectValue(payload, "info") orelse return;
    if (info == .object) {
        const total_usage = getObjectValue(info.object, "total_token_usage") orelse getObjectValue(info.object, "last_token_usage") orelse std.json.Value{ .null = {} };
        if (total_usage == .object) {
            agent_state.codex_token_usage = .{
                .total_tokens = getObjectU64(total_usage.object, "total_tokens") orelse 0,
                .input_tokens = getObjectU64(total_usage.object, "input_tokens") orelse 0,
                .output_tokens = getObjectU64(total_usage.object, "output_tokens") orelse 0,
                .cached_input_tokens = getObjectU64(total_usage.object, "cached_input_tokens") orelse 0,
                .model_context_window = getObjectU64(info.object, "model_context_window") orelse 0,
            };
        }
    }

    const rate_limits = getObjectValue(payload, "rate_limits") orelse return;
    if (rate_limits != .object) return;

    const primary = getObjectValue(rate_limits.object, "primary") orelse return;
    const secondary = getObjectValue(rate_limits.object, "secondary") orelse return;
    if (primary != .object or secondary != .object) return;

    agent_state.codex_rate_limits = .{
        .primary_used_percent = getObjectF64(primary.object, "used_percent") orelse 0.0,
        .secondary_used_percent = getObjectF64(secondary.object, "used_percent") orelse 0.0,
    };
}

fn getObjectValue(object: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    return object.get(key);
}

fn getObjectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getObjectU64(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .number_string => |n| std.fmt.parseInt(u64, n, 10) catch null,
        else => null,
    };
}

fn getObjectF64(object: std.json.ObjectMap, key: []const u8) ?f64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .float => |n| n,
        .integer => |n| @floatFromInt(n),
        .number_string => |n| std.fmt.parseFloat(f64, n) catch null,
        else => null,
    };
}

test "replaySessionFromString replays codex session items into agent state" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    const log =
        \\{"timestamp":"2026-03-27T03:54:03.784Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1","model_context_window":258400,"collaboration_mode_kind":"plan"}}
        \\{"timestamp":"2026-03-27T03:54:03.789Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Design split panes for the agent panel."}]}}
        \\{"timestamp":"2026-03-27T03:54:09.550Z","type":"event_msg","payload":{"type":"agent_message","message":"I’m expanding this into a handoff-grade spec now.","phase":"commentary","memory_citation":null}}
        \\{"timestamp":"2026-03-27T03:54:09.551Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"git status --short\",\"workdir\":\"/tmp/project\"}","call_id":"call-1"}}
        \\{"timestamp":"2026-03-27T03:54:09.552Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-1","output":"M src/agent/render.zig"}}
        \\{"timestamp":"2026-03-27T03:55:11.957Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"thread-1","turn_id":"turn-1","item":{"type":"Plan","id":"turn-1-plan","text":"<proposed_plan>\n# Split Panes\n\n## Summary\n- Add panes\n- Keep tabs\n</proposed_plan>"}}}
        \\{"timestamp":"2026-03-27T03:55:11.986Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":104367,"cached_input_tokens":101632,"output_tokens":3184,"reasoning_output_tokens":52,"total_tokens":107551},"last_token_usage":{"input_tokens":104367,"cached_input_tokens":101632,"output_tokens":3184,"reasoning_output_tokens":52,"total_tokens":107551},"model_context_window":258400},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":53.0,"window_minutes":300,"resets_at":1774594435},"secondary":{"used_percent":16.0,"window_minutes":10080,"resets_at":1775181235},"credits":null,"plan_type":"team"}}}
        \\{"timestamp":"2026-03-27T03:55:11.988Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","last_agent_message":"I’m expanding this into a handoff-grade spec now."}}
    ;

    const summary = try replaySessionFromString(allocator, &agent_state, log);

    try std.testing.expectEqual(@as(usize, 4), agent_state.messages.items.len);
    try std.testing.expectEqual(CodexManager.Status.thread_active, summary.manager_status);
    try std.testing.expect(agent_state.messages.items[0].role == .user);
    try std.testing.expect(agent_state.messages.items[1].role == .agent);
    try std.testing.expect(agent_state.messages.items[2].role == .tool);
    try std.testing.expect(agent_state.messages.items[3].role == .agent);
    try std.testing.expectEqualStrings("Design split panes for the agent panel.", agent_state.messages.items[0].content);
    try std.testing.expectEqualStrings("I’m expanding this into a handoff-grade spec now.", agent_state.messages.items[1].content);
    try std.testing.expectEqualStrings("git status --short", agent_state.messages.items[2].content);
    try std.testing.expect(agent_state.messages.items[2].tool_status == AgentMessage.ToolStatus.completed);
    try std.testing.expectEqualStrings("M src/agent/render.zig", agent_state.messages.items[2].tool_stdout.?);
    try std.testing.expectEqualStrings("<proposed_plan>\n# Split Panes\n\n## Summary\n- Add panes\n- Keep tabs\n</proposed_plan>", agent_state.messages.items[3].content);
    try std.testing.expectEqual(@as(u64, 107551), agent_state.codex_token_usage.?.total_tokens);
    try std.testing.expectEqual(@as(f64, 53.0), agent_state.codex_rate_limits.?.primary_used_percent);
}

test "replaySessionFromString skips internal transcript noise" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    const log =
        \\{"timestamp":"2026-03-27T03:54:03.789Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /tmp/project"}]}}
        \\{"timestamp":"2026-03-27T03:54:03.790Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<turn_aborted>\nInterrupted.\n</turn_aborted>"}]}}
        \\{"timestamp":"2026-03-27T03:54:03.791Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Show me the rendered plan."}]}}
    ;

    const summary = try replaySessionFromString(allocator, &agent_state, log);

    try std.testing.expectEqual(@as(usize, 1), agent_state.messages.items.len);
    try std.testing.expectEqual(CodexManager.Status.thread_active, summary.manager_status);
    try std.testing.expectEqualStrings("Show me the rendered plan.", agent_state.messages.items[0].content);
}

test "replaySessionFromString reports active turn status for in-progress sessions" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    const log =
        \\{"timestamp":"2026-03-27T03:54:03.784Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1","model_context_window":258400,"collaboration_mode_kind":"plan"}}
        \\{"timestamp":"2026-03-27T03:54:09.550Z","type":"event_msg","payload":{"type":"agent_message","message":"Still working...","phase":"commentary","memory_citation":null}}
    ;

    const summary = try replaySessionFromString(allocator, &agent_state, log);

    try std.testing.expectEqual(CodexManager.Status.turn_active, summary.manager_status);
    try std.testing.expectEqual(@as(usize, 1), agent_state.messages.items.len);
    try std.testing.expectEqualStrings("Still working...", agent_state.messages.items[0].content);
}

test "loadReplayLinesFromString keeps non-empty jsonl entries" {
    const allocator = std.testing.allocator;

    const log =
        \\
        \\{"type":"event_msg","payload":{"type":"task_started"}}
        \\
        \\{"type":"event_msg","payload":{"type":"task_complete"}}
    ;

    const lines = try loadReplayLinesFromString(allocator, log);
    defer freeReplayLines(allocator, lines);

    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}", lines[0]);
    try std.testing.expectEqualStrings("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}", lines[1]);
}
