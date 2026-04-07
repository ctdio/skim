const std = @import("std");
const agent_events = @import("../agent/events.zig");
const agent_state_mod = @import("../agent/state.zig");
const AgentState = agent_state_mod.AgentState;
const AgentMessage = agent_state_mod.Message;
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

pub fn lineStartsRequestUserInput(allocator: std.mem.Allocator, line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return false;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return false;
    if (!std.mem.eql(u8, getObjectString(root.object, "type") orelse return false, "response_item")) return false;

    const payload = getObjectValue(root.object, "payload") orelse return false;
    if (payload != .object) return false;
    if (!std.mem.eql(u8, getObjectString(payload.object, "type") orelse return false, "function_call")) return false;
    return std.mem.eql(u8, getObjectString(payload.object, "name") orelse return false, "request_user_input");
}

pub fn previewPendingQuestionResolution(allocator: std.mem.Allocator, agent_state: *AgentState, line: []const u8) !bool {
    const pending = agent_state.getPendingQuestion() orelse return false;
    const pending_tool_call_id = pending.tool_call_id orelse return false;

    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return false;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return false;
    if (!std.mem.eql(u8, getObjectString(root.object, "type") orelse return false, "response_item")) return false;

    const payload = getObjectValue(root.object, "payload") orelse return false;
    if (payload != .object) return false;
    if (!std.mem.eql(u8, getObjectString(payload.object, "type") orelse return false, "function_call_output")) return false;

    const call_id = getObjectString(payload.object, "call_id") orelse return false;
    if (!std.mem.eql(u8, call_id, pending_tool_call_id)) return false;

    const output = getObjectString(payload.object, "output") orelse return false;
    return applyPendingQuestionReplayAnswers(allocator, pending, output);
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
        replayAgentEvent(agent_state, .{ .clear_plan = {} });
        return;
    }

    if (std.mem.eql(u8, payload_type, "agent_message")) {
        const message = getObjectString(payload, "message") orelse return;
        if (message.len == 0) return;
        replayAgentEvent(agent_state, .{ .completed_agent_message = message });
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
        replayAgentEvent(agent_state, .{ .completed_plan_message = text });
        return;
    }

    if (std.mem.eql(u8, item_type, "agentMessage") or std.mem.eql(u8, item_type, "agent_message")) {
        const text = getObjectString(item, "text") orelse return;
        if (text.len == 0) return;
        replayAgentEvent(agent_state, .{ .completed_agent_message = text });
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
        const title = if (std.mem.eql(u8, name, "exec_command"))
            command orelse name
        else
            name;
        replayAgentEvent(agent_state, .{ .tool_call = .{
            .tool_call_id = call_id,
            .tool_name = name,
            .title = title,
            .command = command,
        } });
        return;
    }

    if (std.mem.eql(u8, payload_type, "custom_tool_call")) {
        const call_id = getObjectString(payload, "call_id") orelse return;
        const name = getObjectString(payload, "name") orelse return;
        const input = getObjectString(payload, "input");
        replayAgentEvent(agent_state, .{ .tool_call = .{
            .tool_call_id = call_id,
            .tool_name = name,
            .title = name,
            .command = input,
        } });
        return;
    }

    if (std.mem.eql(u8, payload_type, "function_call_output")) {
        const call_id = getObjectString(payload, "call_id") orelse return;
        const output = getObjectString(payload, "output");
        replayAgentEvent(agent_state, .{ .tool_update = .{
            .tool_call_id = call_id,
            .status = .completed,
            .stdout = output,
            .stderr = null,
        } });
        return;
    }

    if (std.mem.eql(u8, payload_type, "custom_tool_call_output")) {
        const call_id = getObjectString(payload, "call_id") orelse return;
        const output = getObjectString(payload, "output");
        replayAgentEvent(agent_state, .{ .tool_update = .{
            .tool_call_id = call_id,
            .status = .completed,
            .stdout = output,
            .stderr = null,
        } });
    }
}

fn replayAgentEvent(agent_state: *AgentState, event: agent_events.AgentEvent) void {
    agent_events.processAgentEvent(agent_state, event);
}

fn applyPendingQuestionReplayAnswers(allocator: std.mem.Allocator, pending: *agent_state_mod.PendingQuestion, output: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, output, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    defer parsed.deinit();

    if (parsed.value != .object) return false;
    const answers_value = getObjectValue(parsed.value.object, "answers") orelse return false;
    if (answers_value != .object) return false;

    var applied_any = false;
    pending.confirming = false;

    for (pending.questions, pending.states, 0..) |*question, *question_state, question_idx| {
        const answer_entry = findPendingQuestionReplayAnswer(answers_value.object, question.*, question_idx, pending.questions.len) orelse continue;
        if (answer_entry != .object) continue;

        const answer_list = getObjectValue(answer_entry.object, "answers") orelse continue;
        if (answer_list != .array) continue;

        if (applyReplayAnswersToQuestion(question, question_state, answer_list.array.items)) {
            applied_any = true;
        }
    }

    return applied_any;
}

fn findPendingQuestionReplayAnswer(
    answers: std.json.ObjectMap,
    question: agent_state_mod.Question,
    question_idx: usize,
    question_count: usize,
) ?std.json.Value {
    _ = question_idx;
    if (question.id) |id| {
        if (answers.get(id)) |entry| return entry;
    }

    if (question_count == 1) {
        var iter = answers.iterator();
        if (iter.next()) |entry| return entry.value_ptr.*;
    }

    return null;
}

fn applyReplayAnswersToQuestion(
    question: *agent_state_mod.Question,
    question_state: *agent_state_mod.QuestionState,
    answer_items: []const std.json.Value,
) bool {
    @memset(question_state.selected, false);
    question_state.custom_active = false;
    question_state.custom_input.clear();

    var first_selected: ?usize = null;

    for (answer_items) |answer_item| {
        if (answer_item != .string) continue;
        const selected_idx = selectReplayQuestionAnswer(question, question_state, answer_item.string) orelse continue;
        if (first_selected == null) {
            first_selected = selected_idx;
        }
        if (!question.multiple) break;
    }

    if (first_selected) |selected_idx| {
        question_state.cursor_index = selected_idx;
        return true;
    }

    return false;
}

fn selectReplayQuestionAnswer(
    question: *agent_state_mod.Question,
    question_state: *agent_state_mod.QuestionState,
    answer: []const u8,
) ?usize {
    for (question.options, 0..) |option, option_idx| {
        if (!std.mem.eql(u8, option.label, answer)) continue;
        question_state.selected[option_idx] = true;
        return option_idx;
    }

    if (question.custom_index) |custom_idx| {
        question_state.selected[custom_idx] = true;
        question_state.custom_input.setText(answer);
        return custom_idx;
    }

    return null;
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
        \\{"timestamp":"2026-03-27T03:55:11.957Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"thread-1","turn_id":"turn-1","item":{"type":"Plan","id":"turn-1-plan","text":"# Split Panes\n\n## Summary\n- Add panes\n- Keep tabs"}}}
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

test "replaySessionFromString clears codex todo state on task_complete" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    const log =
        \\{"timestamp":"2026-04-07T14:43:35.617Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        \\{"timestamp":"2026-04-07T14:43:35.618Z","type":"response_item","payload":{"type":"function_call","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"Implement Codex apply_patch handling\",\"status\":\"in_progress\",\"priority\":\"high\"}]}","call_id":"call-plan-1"}}
        \\{"timestamp":"2026-04-07T14:43:35.619Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}
    ;

    const summary = try replaySessionFromString(allocator, &agent_state, log);

    try std.testing.expectEqual(CodexManager.Status.thread_active, summary.manager_status);
    try std.testing.expectEqual(@as(usize, 0), agent_state.planEntryCount());
    try std.testing.expectEqual(@as(usize, 2), agent_state.messages.items.len);
    try std.testing.expectEqual(AgentMessage.Role.tool, agent_state.messages.items[0].role);
    try std.testing.expectEqual(AgentMessage.Role.plan_snapshot, agent_state.messages.items[1].role);
}

test "replaySessionFromString restores request_user_input pending question" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    const log =
        \\{"timestamp":"2026-03-28T14:43:47.709Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{\"questions\":[{\"header\":\"Split Model\",\"id\":\"split_model\",\"question\":\"When a user creates a split in agent mode, what should each pane represent?\",\"options\":[{\"label\":\"Independent sessions (Recommended)\",\"description\":\"Each pane has its own AgentState and manager connection.\"},{\"label\":\"Shared session\",\"description\":\"All panes mirror the same live session.\"}]}]}","call_id":"call-request-1"}}
    ;

    _ = try replaySessionFromString(allocator, &agent_state, log);

    try std.testing.expectEqual(@as(usize, 1), agent_state.messages.items.len);
    try std.testing.expectEqual(AgentMessage.Role.tool, agent_state.messages.items[0].role);

    const pending = agent_state.getPendingQuestion() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("call-request-1", pending.tool_call_id.?);
    try std.testing.expectEqual(@as(usize, 1), pending.questions.len);
    try std.testing.expectEqualStrings("When a user creates a split in agent mode, what should each pane represent?", pending.questions[0].prompt);
    try std.testing.expectEqual(@as(usize, 2), pending.questions[0].options.len);
}

test "replaySessionFromString clears restored request_user_input after tool output" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    const log =
        \\{"timestamp":"2026-03-28T14:43:47.709Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{\"questions\":[{\"header\":\"Split Model\",\"id\":\"split_model\",\"question\":\"When a user creates a split in agent mode, what should each pane represent?\",\"options\":[{\"label\":\"Independent sessions (Recommended)\",\"description\":\"Each pane has its own AgentState and manager connection.\"}]}]}","call_id":"call-request-1"}}
        \\{"timestamp":"2026-03-28T14:44:13.322Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-request-1","output":"{\"answers\":{\"split_model\":{\"answers\":[\"Independent sessions (Recommended)\"]}}}"}}
    ;

    _ = try replaySessionFromString(allocator, &agent_state, log);

    try std.testing.expect(agent_state.getPendingQuestion() == null);
    try std.testing.expectEqual(@as(usize, 1), agent_state.messages.items.len);
    try std.testing.expect(agent_state.messages.items[0].tool_status == AgentMessage.ToolStatus.completed);
    try std.testing.expect(agent_state.messages.items[0].tool_stdout != null);
}

test "replaySessionFromString replays custom apply_patch tool calls into diff messages" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    const log =
        \\{"timestamp":"2026-04-07T14:28:32.593Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Add a regression test for tab reallocation."}]}}
        \\{"timestamp":"2026-04-07T14:28:57.480Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"call-apply-patch-1","name":"apply_patch","input":"*** Begin Patch\n*** Update File: src/modes/agent_mode.zig\n@@\n test \"old test\" {\n-    try std.testing.expect(true);\n+    try std.testing.expect(false);\n }\n*** End Patch\n"}}
        \\{"timestamp":"2026-04-07T14:28:57.541Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-apply-patch-1","output":"{\"output\":\"Success. Updated the following files:\\nM src/modes/agent_mode.zig\\n\"}"}}
    ;

    _ = try replaySessionFromString(allocator, &agent_state, log);

    try std.testing.expectEqual(@as(usize, 3), agent_state.messages.items.len);
    try std.testing.expectEqual(AgentMessage.Role.user, agent_state.messages.items[0].role);
    try std.testing.expectEqual(AgentMessage.Role.diff, agent_state.messages.items[1].role);
    try std.testing.expectEqualStrings("Edit src/modes/agent_mode.zig", agent_state.messages.items[1].content);
    try std.testing.expectEqualStrings("src/modes/agent_mode.zig", agent_state.messages.items[1].diff_path.?);
    try std.testing.expectEqualStrings("test \"old test\" {\n    try std.testing.expect(true);\n}", agent_state.messages.items[1].diff_old.?);
    try std.testing.expectEqualStrings("test \"old test\" {\n    try std.testing.expect(false);\n}", agent_state.messages.items[1].diff_new.?);
    try std.testing.expectEqual(AgentMessage.Role.tool, agent_state.messages.items[2].role);
    try std.testing.expectEqual(AgentMessage.ToolStatus.completed, agent_state.messages.items[2].tool_status);
}

test "replaySessionFromString replays multi-file custom apply_patch tool calls into diff messages" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    const log =
        \\{"timestamp":"2026-04-07T14:28:32.593Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Apply the tab-panel fixes."}]}}
        \\{"timestamp":"2026-04-07T14:28:57.480Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"call-apply-patch-2","name":"apply_patch","input":"*** Begin Patch\n*** Add File: src/testing/new_case.zig\n+test \"new case\" {}\n*** Update File: src/modes/agent_mode.zig\n-const mode_name = \"agent\";\n+const mode_name = \"agent_panel\";\n*** Delete File: src/testing/old_case.zig\n-test \"old case\" {}\n*** End Patch\n"}}
        \\{"timestamp":"2026-04-07T14:28:57.541Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-apply-patch-2","output":"{\"output\":\"Success. Updated the following files:\\nA src/testing/new_case.zig\\nM src/modes/agent_mode.zig\\nD src/testing/old_case.zig\\n\"}"}}
    ;

    _ = try replaySessionFromString(allocator, &agent_state, log);

    try std.testing.expectEqual(@as(usize, 5), agent_state.messages.items.len);

    try std.testing.expectEqual(AgentMessage.Role.user, agent_state.messages.items[0].role);

    try std.testing.expectEqual(AgentMessage.Role.diff, agent_state.messages.items[1].role);
    try std.testing.expectEqualStrings("Add src/testing/new_case.zig", agent_state.messages.items[1].content);
    try std.testing.expectEqualStrings("src/testing/new_case.zig", agent_state.messages.items[1].diff_path.?);
    try std.testing.expectEqualStrings("", agent_state.messages.items[1].diff_old.?);
    try std.testing.expectEqualStrings("test \"new case\" {}", agent_state.messages.items[1].diff_new.?);

    try std.testing.expectEqual(AgentMessage.Role.diff, agent_state.messages.items[2].role);
    try std.testing.expectEqualStrings("Edit src/modes/agent_mode.zig", agent_state.messages.items[2].content);
    try std.testing.expectEqualStrings("src/modes/agent_mode.zig", agent_state.messages.items[2].diff_path.?);
    try std.testing.expectEqualStrings("const mode_name = \"agent\";", agent_state.messages.items[2].diff_old.?);
    try std.testing.expectEqualStrings("const mode_name = \"agent_panel\";", agent_state.messages.items[2].diff_new.?);

    try std.testing.expectEqual(AgentMessage.Role.diff, agent_state.messages.items[3].role);
    try std.testing.expectEqualStrings("Delete src/testing/old_case.zig", agent_state.messages.items[3].content);
    try std.testing.expectEqualStrings("src/testing/old_case.zig", agent_state.messages.items[3].diff_path.?);
    try std.testing.expectEqualStrings("test \"old case\" {}", agent_state.messages.items[3].diff_old.?);
    try std.testing.expectEqualStrings("", agent_state.messages.items[3].diff_new.?);

    try std.testing.expectEqual(AgentMessage.Role.tool, agent_state.messages.items[4].role);
    try std.testing.expectEqual(AgentMessage.ToolStatus.completed, agent_state.messages.items[4].tool_status);
    try std.testing.expectEqualStrings("call-apply-patch-2", agent_state.messages.items[4].tool_call_id.?);
}

test "previewPendingQuestionResolution applies recorded codex answers to pending question" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    const question_log =
        \\{"timestamp":"2026-03-28T14:43:47.709Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{\"questions\":[{\"header\":\"Split Model\",\"id\":\"split_model\",\"question\":\"Which pane model should v1 use?\",\"options\":[{\"label\":\"Independent sessions (Recommended)\"},{\"label\":\"Shared session\"}]}]}","call_id":"call-request-1"}}
    ;
    _ = try replaySessionFromString(allocator, &agent_state, question_log);

    const output_line =
        \\{"timestamp":"2026-03-28T14:44:13.322Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-request-1","output":"{\"answers\":{\"split_model\":{\"answers\":[\"Shared session\"]}}}"}}
    ;

    try std.testing.expect(try previewPendingQuestionResolution(allocator, &agent_state, output_line));

    const pending = agent_state.getPendingQuestion() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), pending.states[0].cursor_index);
    try std.testing.expect(!pending.states[0].selected[0]);
    try std.testing.expect(pending.states[0].selected[1]);
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
