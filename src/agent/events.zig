/// Unified event type for ACP, OpenCode, and Codex protocol events.
/// Provides a single dispatch point for routing protocol events to AgentState.
const std = @import("std");
const Allocator = std.mem.Allocator;
const AgentState = @import("state.zig").AgentState;
const Message = @import("state.zig").Message;
const QuestionPromptData = @import("state.zig").QuestionPromptData;
const SubagentInfo = @import("state.zig").SubagentInfo;
const SubagentToolSummary = @import("state.zig").SubagentToolSummary;
const protocol = @import("../acp/protocol.zig");
const AcpManager = @import("../acp/manager.zig").AcpManager;
const opencode_manager = @import("../opencode/manager.zig");
const OpencodeEvent = opencode_manager.Event;
const codex_manager = @import("../codex/manager.zig");
const CodexEvent = codex_manager.CodexManager.CodexEvent;
const CodexPlanEntry = codex_manager.CodexManager.CodexEvent.PlanUpdatedEvent.PlanEntry;

/// A unified event representing an update from either ACP or OpenCode.
/// Provides a single processAgentEvent function for routing events to AgentState.
pub const AgentEvent = union(enum) {
    // Streaming content
    text_chunk: []const u8,
    completed_agent_message: []const u8,
    thinking_chunk: []const u8,
    message_complete: void,

    // System
    system_message: []const u8,
    error_message: []const u8,

    // Tools
    tool_call: ToolCallEvent,
    tool_update: ToolUpdateEvent,
    tool_diff: ToolDiffEvent,

    // Plan updates (ACP + Codex)
    plan_update: []const protocol.PlanEntry,
    codex_plan_update: []const CodexPlanEntry,
    commands_update: []const protocol.AvailableCommand,

    // Session lifecycle
    session_compacted: void,

    // Questions (OpenCode-only, but still part of unified type)
    question_prompt: QuestionPromptData,
    question_resolved: void,

    // Codex-specific metrics
    token_usage_update: CodexTokenUsageEvent,
    rate_limits_update: CodexRateLimitsEvent,
    mcp_server_status: void,

    pub const CodexTokenUsageEvent = struct {
        total_tokens: u64,
        input_tokens: u64,
        output_tokens: u64,
        cached_input_tokens: u64,
        model_context_window: u64,
    };

    pub const CodexRateLimitsEvent = struct {
        primary_used_percent: f64,
        secondary_used_percent: f64,
    };

    pub const ToolCallEvent = struct {
        tool_call_id: []const u8,
        tool_name: ?[]const u8,
        title: []const u8,
        command: ?[]const u8,
        subagent_info: ?OpencodeEvent.SubagentEventInfo = null,
    };

    pub const ToolUpdateEvent = struct {
        tool_call_id: []const u8,
        status: Message.ToolStatus,
        stdout: ?[]const u8,
        stderr: ?[]const u8,
        subagent_info: ?OpencodeEvent.SubagentEventInfo = null,
    };

    pub const ToolDiffEvent = struct {
        tool_call_id: ?[]const u8,
        title: []const u8,
        path: []const u8,
        old_text: []const u8,
        new_text: []const u8,
    };
};

/// Process a unified agent event, updating agent_state accordingly.
/// This consolidates the duplicated event-routing logic from pollTabAcpManager
/// and pollTabOpencodeManager.
pub fn processAgentEvent(agent_state: *AgentState, event: AgentEvent) void {
    switch (event) {
        .text_chunk => |text| {
            agent_state.appendToLastAgentMessage(text) catch {};
        },
        .completed_agent_message => |text| {
            agent_state.addCompletedAgentMessage(text) catch {};
        },
        .thinking_chunk => |text| {
            agent_state.appendToLastThinkingMessage(text) catch {};
        },
        .tool_call => |tc| {
            agent_state.addToolMessage(
                tc.tool_call_id,
                tc.tool_name,
                tc.title,
                tc.command,
            ) catch {};
            maybeApplyUpdatePlanToolCall(agent_state, tc.tool_name, tc.title, tc.command);
            maybeApplyRequestUserInputToolCall(agent_state, tc.tool_call_id, tc.tool_name, tc.title, tc.command);
            if (tc.subagent_info) |info| {
                if (convertSubagentInfo(agent_state.allocator, info)) |owned| {
                    agent_state.setSubagentInfoOnTool(tc.tool_call_id, owned);
                }
            }
        },
        .tool_update => |tu| {
            agent_state.updateToolMessage(
                tu.tool_call_id,
                tu.status,
                tu.stdout,
                tu.stderr,
            ) catch {};
            maybeResolvePendingQuestionFromToolUpdate(agent_state, tu.tool_call_id, tu.status);
            if (tu.subagent_info) |info| {
                // Partial update (from child session tracking) — only has
                // tool_count and summary, no description/agent_type. Merge
                // instead of replace to preserve the initial info.
                if (info.description == null and info.agent_type == null and info.session_id == null) {
                    const owned_summary = convertSummaryOnly(agent_state.allocator, info.summary);
                    agent_state.mergeSubagentToolProgress(tu.tool_call_id, info.tool_count, owned_summary, .{
                        .input_tokens = info.input_tokens,
                        .output_tokens = info.output_tokens,
                        .reasoning_tokens = info.reasoning_tokens,
                        .cache_read_tokens = info.cache_read_tokens,
                        .cache_write_tokens = info.cache_write_tokens,
                        .start_time_ms = info.start_time_ms,
                    });
                } else if (convertSubagentInfo(agent_state.allocator, info)) |owned| {
                    if (owned.session_id != null and owned.description == null and owned.agent_type == null) {
                        agent_state.mergeSubagentSessionIdOnTool(
                            tu.tool_call_id,
                            owned.session_id.?,
                            owned.title,
                        );
                        var to_free = owned;
                        to_free.deinit(agent_state.allocator);
                    } else {
                        agent_state.setSubagentInfoOnTool(tu.tool_call_id, owned);
                    }
                }
            }
        },
        .tool_diff => |diff| {
            agent_state.addDiffMessage(
                diff.tool_call_id,
                diff.title,
                diff.path,
                diff.old_text,
                diff.new_text,
            ) catch |err| {
                std.log.err("Failed to add diff message: {any}", .{err});
            };
        },
        .plan_update => |entries| {
            agent_state.updatePlan(entries) catch |err| {
                std.log.err("plan_update: updatePlan failed: {}", .{err});
            };
        },
        .codex_plan_update => |entries| {
            const plan_entries = agent_state.allocator.alloc(protocol.PlanEntry, entries.len) catch return;
            defer agent_state.allocator.free(plan_entries);

            for (entries, 0..) |entry, idx| {
                plan_entries[idx] = .{
                    .content = entry.content,
                    .status = switch (entry.status) {
                        .pending => .pending,
                        .in_progress => .in_progress,
                        .completed => .completed,
                    },
                    .priority = switch (entry.priority) {
                        .high => .high,
                        .medium => .medium,
                        .low => .low,
                    },
                };
            }

            agent_state.updatePlan(plan_entries) catch |err| {
                std.log.err("codex_plan_update: updatePlan failed: {}", .{err});
            };
        },
        .commands_update => |commands| {
            agent_state.updateAvailableCommands(commands) catch {};
        },
        .system_message => |msg| {
            agent_state.addMessage(.system, msg) catch {};
        },
        .error_message => |msg| {
            agent_state.addMessage(.system, msg) catch {};
        },
        .session_compacted => {
            agent_state.addMessage(.compacted, "") catch {};
        },
        .question_resolved => {
            agent_state.clearPendingQuestion();
        },
        .question_prompt => |prompt_data| {
            agent_state.setPendingQuestion(prompt_data) catch |err| {
                std.log.err("Failed to set pending question: {any}", .{err});
            };
        },
        .message_complete => {},
        .token_usage_update => |tu| {
            agent_state.codex_token_usage = .{
                .total_tokens = tu.total_tokens,
                .input_tokens = tu.input_tokens,
                .output_tokens = tu.output_tokens,
                .cached_input_tokens = tu.cached_input_tokens,
                .model_context_window = tu.model_context_window,
            };
        },
        .rate_limits_update => |rl| {
            agent_state.codex_rate_limits = .{
                .primary_used_percent = rl.primary_used_percent,
                .secondary_used_percent = rl.secondary_used_percent,
            };
        },
        .mcp_server_status => {},
    }
}

// =============================================================================
// Protocol-specific conversion functions
// =============================================================================

/// Convert an ACP PendingMessage to a unified AgentEvent.
/// Returns null for event types that don't map (plan_update/commands_update with null data).
pub fn acpMessageToAgentEvent(msg: AcpManager.PendingMessage) ?AgentEvent {
    return switch (msg.kind) {
        .agent_text => .{ .text_chunk = msg.text },
        .agent_thinking => .{ .thinking_chunk = msg.text },
        .tool_call => .{ .tool_call = .{
            .tool_call_id = msg.tool_call_id orelse "",
            .tool_name = msg.tool_name,
            .title = msg.text,
            .command = msg.tool_command,
        } },
        .tool_update => .{ .tool_update = .{
            .tool_call_id = msg.tool_call_id orelse "",
            .status = switch (msg.tool_status) {
                .pending => .pending,
                .in_progress => .running,
                .completed => .completed,
                .failed => .failed,
            },
            .stdout = msg.tool_stdout,
            .stderr = msg.tool_stderr,
        } },
        .tool_diff => .{ .tool_diff = .{
            .tool_call_id = msg.tool_call_id,
            .title = msg.text,
            .path = msg.diff_path orelse "",
            .old_text = msg.diff_old orelse "",
            .new_text = msg.diff_new orelse "",
        } },
        .error_msg => .{ .error_message = msg.text },
        .plan_update => if (msg.plan_entries) |entries|
            @as(?AgentEvent, .{ .plan_update = entries })
        else
            null,
        .commands_update => if (msg.available_commands) |commands|
            @as(?AgentEvent, .{ .commands_update = commands })
        else
            null,
    };
}

/// Convert an OpenCode Event to a unified AgentEvent.
/// Returns null for events that are handled separately (status_change).
pub fn opencodeEventToAgentEvent(allocator: Allocator, event: OpencodeEvent) ?AgentEvent {
    return switch (event) {
        .message_chunk => |c| .{ .text_chunk = c.delta },
        .thinking_chunk => |c| .{ .thinking_chunk = c.delta },
        .message_complete => .{ .message_complete = {} },
        .system_message => |msg| .{ .system_message = msg },
        .tool_call => |tc| .{ .tool_call = .{
            .tool_call_id = tc.tool_call_id,
            .tool_name = tc.tool_name,
            .title = tc.title,
            .command = tc.command,
            .subagent_info = tc.subagent_info,
        } },
        .tool_update => |tu| .{ .tool_update = .{
            .tool_call_id = tu.tool_call_id,
            .status = switch (tu.status) {
                .pending => .pending,
                .running => .running,
                .completed => .completed,
                .failed => .failed,
            },
            .stdout = tu.stdout,
            .stderr = tu.stderr,
            .subagent_info = tu.subagent_info,
        } },
        .tool_diff => |d| .{ .tool_diff = .{
            .tool_call_id = d.tool_call_id,
            .title = d.title,
            .path = d.path,
            .old_text = d.old_text,
            .new_text = d.new_text,
        } },
        .commands_update => |commands| .{ .commands_update = convertOpencodeCommands(allocator, commands) orelse return null },
        .session_compacted => .{ .session_compacted = {} },
        .question_prompt => null, // Handled separately by pollEvents (needs allocator for conversion)
        .question_resolved => .{ .question_resolved = {} },
        .err => |e| .{ .error_message = e.message orelse @tagName(e.code) },
        .status_change => null, // Handled separately by caller
    };
}

fn convertOpencodeCommands(allocator: Allocator, commands: []const opencode_manager.AvailableCommand) ?[]const protocol.AvailableCommand {
    const converted = allocator.alloc(protocol.AvailableCommand, commands.len) catch return null;

    for (commands, 0..) |cmd, idx| {
        converted[idx] = .{
            .name = cmd.name,
            .description = cmd.description,
            .input = if (cmd.input) |input|
                .{ .hint = input.hint }
            else
                null,
        };
    }

    return converted;
}

/// Convert a Codex event to a unified AgentEvent.
/// Returns null for events that have no agent-side representation yet.
pub fn codexEventToAgentEvent(event: CodexEvent) ?AgentEvent {
    return switch (event) {
        .text_delta => |d| .{ .text_chunk = d.delta },
        .reasoning_delta => |d| .{ .thinking_chunk = d.delta },
        .command_output_delta => |d| .{ .tool_update = .{
            .tool_call_id = d.item_id,
            .status = .running,
            .stdout = d.delta,
            .stderr = null,
        } },
        .item_started => |e| blk: {
            switch (e.item) {
                .command_execution => |cmd| break :blk .{ .tool_call = .{
                    .tool_call_id = cmd.id,
                    .tool_name = null,
                    .title = cmd.command orelse "Command",
                    .command = cmd.command,
                } },
                .file_change => |fc| break :blk .{ .tool_call = .{
                    .tool_call_id = fc.id,
                    .tool_name = null,
                    .title = fc.path orelse "File change",
                    .command = null,
                } },
                .function_call => |fc| break :blk .{ .tool_call = .{
                    .tool_call_id = fc.id,
                    .tool_name = fc.name,
                    .title = fc.name orelse "Function call",
                    .command = fc.arguments,
                    .subagent_info = parseCodexSubagentInfo(fc.name, fc.arguments, fc.output),
                } },
                .mcp_tool_call => |m| break :blk .{ .tool_call = .{
                    .tool_call_id = m.id,
                    .tool_name = m.tool_name,
                    .title = m.tool_name orelse m.server_name orelse "MCP tool call",
                    .command = m.arguments,
                } },
                .agent_message => break :blk null,
                .user_message, .reasoning, .unknown => break :blk null,
            }
        },
        .item_completed => |e| blk: {
            switch (e.item) {
                .agent_message => |msg| break :blk if (msg.text.len > 0)
                    .{ .completed_agent_message = msg.text }
                else
                    .{ .message_complete = {} },
                .command_execution => |cmd| break :blk .{ .tool_update = .{
                    .tool_call_id = cmd.id,
                    .status = if (cmd.exit_code) |ec| (if (ec == 0) .completed else .failed) else .completed,
                    .stdout = cmd.stdout,
                    .stderr = cmd.stderr,
                } },
                .file_change => |fc| break :blk .{ .tool_update = .{
                    .tool_call_id = fc.id,
                    .status = .completed,
                    .stdout = fc.diff,
                    .stderr = null,
                } },
                .function_call => |fc| break :blk .{ .tool_update = .{
                    .tool_call_id = fc.id,
                    .status = mapFunctionCallStatus(fc.status),
                    .stdout = fc.output,
                    .stderr = null,
                    .subagent_info = parseCodexSubagentInfo(fc.name, fc.arguments, fc.output),
                } },
                .mcp_tool_call => |m| break :blk .{ .tool_update = .{
                    .tool_call_id = m.id,
                    .status = mapFunctionCallStatus(m.status),
                    .stdout = m.output,
                    .stderr = null,
                } },
                .user_message, .reasoning, .unknown => break :blk null,
            }
        },
        .turn_completed => .{ .message_complete = {} },
        .plan_updated => |p| .{ .codex_plan_update = p.entries },
        .token_usage_updated => |tu| blk: {
            const total = tu.total orelse tu.last orelse break :blk null;
            break :blk @as(?AgentEvent, .{ .token_usage_update = .{
                .total_tokens = total.total_tokens,
                .input_tokens = total.input_tokens,
                .output_tokens = total.output_tokens,
                .cached_input_tokens = total.cached_input_tokens,
                .model_context_window = tu.model_context_window orelse 0,
            } });
        },
        .rate_limits_updated => |rl| .{ .rate_limits_update = .{
            .primary_used_percent = rl.primary.used_percent,
            .secondary_used_percent = rl.secondary.used_percent,
        } },
        .mcp_server_status => .{ .mcp_server_status = {} },
        .approval_requested => null,
        .unknown => null,
    };
}

// =============================================================================
// Subagent info conversion (OpenCode Event → Agent state types)
// =============================================================================

/// Convert borrowed OpencodeEvent.SubagentEventInfo into owned SubagentInfo.
/// All strings are duped into the provided allocator.
fn convertSubagentInfo(allocator: Allocator, src: OpencodeEvent.SubagentEventInfo) ?SubagentInfo {
    var info: SubagentInfo = .{
        .tool_count = src.tool_count,
        .input_tokens = src.input_tokens,
        .output_tokens = src.output_tokens,
        .reasoning_tokens = src.reasoning_tokens,
        .cache_read_tokens = src.cache_read_tokens,
        .cache_write_tokens = src.cache_write_tokens,
        .start_time_ms = src.start_time_ms,
    };

    info.description = if (src.description) |d| allocator.dupe(u8, d) catch null else null;
    info.agent_type = if (src.agent_type) |a| allocator.dupe(u8, a) catch null else null;
    info.session_id = if (src.session_id) |s| allocator.dupe(u8, s) catch null else null;
    info.title = if (src.title) |t| allocator.dupe(u8, t) catch null else null;

    if (src.summary.len > 0) {
        var summaries: std.ArrayList(SubagentToolSummary) = .{};
        defer summaries.deinit(allocator);
        summaries.ensureTotalCapacity(allocator, src.summary.len) catch return info;
        for (src.summary) |entry| {
            const owned_name = allocator.dupe(u8, entry.tool_name) catch continue;
            const owned_title: ?[]const u8 = if (entry.title) |t| allocator.dupe(u8, t) catch null else null;
            summaries.append(allocator, .{
                .tool_name = owned_name,
                .title = owned_title,
                .status = convertToolStatus(entry.status),
            }) catch {
                allocator.free(owned_name);
                if (owned_title) |t| allocator.free(t);
                continue;
            };
        }
        info.summary = summaries.toOwnedSlice(allocator) catch {
            for (summaries.items) |*entry| {
                entry.deinit(allocator);
            }
            return info;
        };
    }

    return info;
}

/// Convert only the summary portion of SubagentEventInfo into owned SubagentToolSummary slice.
/// Used for partial updates (child tool progress) where we merge into existing info.
fn convertSummaryOnly(allocator: Allocator, src: []opencode_manager.Event.SubagentToolSummary) []SubagentToolSummary {
    if (src.len == 0) return &.{};
    var summaries: std.ArrayList(SubagentToolSummary) = .{};
    defer summaries.deinit(allocator);
    summaries.ensureTotalCapacity(allocator, src.len) catch return &.{};
    for (src) |entry| {
        const owned_name = allocator.dupe(u8, entry.tool_name) catch continue;
        const owned_title: ?[]const u8 = if (entry.title) |t| allocator.dupe(u8, t) catch null else null;
        summaries.append(allocator, .{
            .tool_name = owned_name,
            .title = owned_title,
            .status = convertToolStatus(entry.status),
        }) catch {
            allocator.free(owned_name);
            if (owned_title) |t| allocator.free(t);
            continue;
        };
    }
    return summaries.toOwnedSlice(allocator) catch {
        for (summaries.items) |*entry| {
            entry.deinit(allocator);
        }
        return &.{};
    };
}

fn convertToolStatus(s: opencode_manager.ToolStatus) Message.ToolStatus {
    return switch (s) {
        .pending => .pending,
        .running => .running,
        .completed => .completed,
        .failed => .failed,
    };
}

fn mapFunctionCallStatus(raw_status: ?[]const u8) Message.ToolStatus {
    const status = raw_status orelse return .completed;
    if (std.mem.eql(u8, status, "pending")) return .pending;
    if (std.mem.eql(u8, status, "running")) return .running;
    if (std.mem.eql(u8, status, "in_progress")) return .running;
    if (std.mem.eql(u8, status, "failed")) return .failed;
    if (std.mem.eql(u8, status, "error")) return .failed;
    return .completed;
}

fn parseCodexSubagentInfo(name: ?[]const u8, arguments: ?[]const u8, output: ?[]const u8) ?OpencodeEvent.SubagentEventInfo {
    const maybe_agent_type = parseAgentTypeFromArgs(arguments);
    const maybe_description = parseDescriptionFromArgs(arguments);
    const maybe_session_id = parseSessionIdFromOutput(output);

    const is_spawn = if (name) |n| std.mem.eql(u8, n, "spawn_agent") else false;
    if (!is_spawn and maybe_session_id == null) return null;

    return .{
        .description = maybe_description,
        .agent_type = maybe_agent_type,
        .session_id = maybe_session_id,
        .title = if (name) |n| n else null,
        .tool_count = 0,
        .summary = &.{},
    };
}

fn parseAgentTypeFromArgs(arguments: ?[]const u8) ?[]const u8 {
    const args = arguments orelse return null;
    const ParsedArgs = struct {
        agent_type: ?[]const u8 = null,
        agentType: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(ParsedArgs, std.heap.page_allocator, args, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch return null;
    defer parsed.deinit();
    return parsed.value.agent_type orelse parsed.value.agentType;
}

fn parseDescriptionFromArgs(arguments: ?[]const u8) ?[]const u8 {
    const args = arguments orelse return null;
    const ParsedArgs = struct {
        message: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(ParsedArgs, std.heap.page_allocator, args, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch return null;
    defer parsed.deinit();
    return parsed.value.message;
}

fn parseSessionIdFromOutput(output: ?[]const u8) ?[]const u8 {
    const raw_output = output orelse return null;
    const ParsedOutput = struct {
        agent_id: ?[]const u8 = null,
        session_id: ?[]const u8 = null,
        id: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(ParsedOutput, std.heap.page_allocator, raw_output, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch return null;
    defer parsed.deinit();
    return parsed.value.agent_id orelse parsed.value.session_id orelse parsed.value.id;
}

fn maybeApplyUpdatePlanToolCall(agent_state: *AgentState, tool_name: ?[]const u8, title: []const u8, command: ?[]const u8) void {
    const is_update_plan = if (tool_name) |name|
        std.mem.eql(u8, name, "update_plan")
    else
        std.mem.eql(u8, title, "update_plan");
    if (!is_update_plan) return;

    const args = command orelse return;
    const RawEntry = struct {
        step: ?[]const u8 = null,
        content: ?[]const u8 = null,
        status: ?[]const u8 = null,
        priority: ?[]const u8 = null,
    };
    const RawArgs = struct {
        plan: ?[]const RawEntry = null,
    };

    const parsed = std.json.parseFromSlice(RawArgs, std.heap.page_allocator, args, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch |err| {
        std.log.debug("maybeApplyUpdatePlanToolCall: failed to parse args: {}", .{err});
        return;
    };
    defer parsed.deinit();

    const raw_entries = parsed.value.plan orelse return;
    if (raw_entries.len == 0) return;

    const entries = agent_state.allocator.alloc(protocol.PlanEntry, raw_entries.len) catch return;
    defer agent_state.allocator.free(entries);

    var count: usize = 0;
    for (raw_entries) |entry| {
        const content = entry.step orelse entry.content orelse continue;
        entries[count] = .{
            .content = content,
            .status = parseProtocolPlanStatus(entry.status),
            .priority = parseProtocolPlanPriority(entry.priority),
        };
        count += 1;
    }
    if (count == 0) return;

    agent_state.updatePlan(entries[0..count]) catch |err| {
        std.log.err("maybeApplyUpdatePlanToolCall: updatePlan failed: {}", .{err});
    };
}

fn maybeApplyRequestUserInputToolCall(agent_state: *AgentState, tool_call_id: []const u8, tool_name: ?[]const u8, title: []const u8, command: ?[]const u8) void {
    if (!isRequestUserInputToolCall(tool_name, title)) return;

    const args = command orelse return;
    const prompt = parseRequestUserInputToolCall(agent_state.allocator, tool_call_id, args) orelse return;
    defer freeQuestionPromptArrays(agent_state.allocator, prompt);

    agent_state.setPendingQuestion(prompt) catch |err| {
        std.log.err("maybeApplyRequestUserInputToolCall: setPendingQuestion failed: {}", .{err});
    };
}

fn isRequestUserInputToolCall(tool_name: ?[]const u8, title: []const u8) bool {
    if (tool_name) |name| {
        return std.mem.eql(u8, name, "request_user_input");
    }
    return std.mem.eql(u8, title, "request_user_input");
}

fn parseRequestUserInputToolCall(allocator: Allocator, tool_call_id: []const u8, args: []const u8) ?QuestionPromptData {
    const state = @import("state.zig");

    const RawOption = struct {
        label: []const u8 = "",
        description: ?[]const u8 = null,
    };

    const RawQuestion = struct {
        header: ?[]const u8 = null,
        question: ?[]const u8 = null,
        prompt: ?[]const u8 = null,
        options: ?[]const RawOption = null,
        isOther: bool = false,
        is_other: bool = false,
        multiple: bool = false,
    };

    const RawArgs = struct {
        questions: ?[]const RawQuestion = null,
    };

    const parsed = std.json.parseFromSlice(RawArgs, std.heap.page_allocator, args, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch |err| {
        std.log.debug("parseRequestUserInputToolCall: failed to parse args: {}", .{err});
        return null;
    };
    defer parsed.deinit();

    const raw_questions = parsed.value.questions orelse return null;
    if (raw_questions.len == 0) return null;

    const questions = allocator.alloc(state.QuestionData, raw_questions.len) catch return null;
    errdefer {
        for (questions) |question| {
            allocator.free(question.options);
        }
        allocator.free(questions);
    }

    for (raw_questions, 0..) |raw_question, question_idx| {
        const question_text = raw_question.question orelse raw_question.prompt orelse "";
        const raw_options = raw_question.options orelse &.{};

        const option_items = allocator.alloc(state.QuestionOptionData, raw_options.len) catch return null;
        for (raw_options, 0..) |opt, opt_idx| {
            option_items[opt_idx] = .{
                .label = opt.label,
                .description = opt.description,
            };
        }

        questions[question_idx] = .{
            .header = raw_question.header,
            .question = question_text,
            .options = option_items,
            .multiple = raw_question.multiple,
            .allow_custom = raw_question.isOther or raw_question.is_other,
        };
    }

    return .{
        .tool_call_id = tool_call_id,
        .questions = questions,
    };
}

fn freeQuestionPromptArrays(allocator: Allocator, prompt: QuestionPromptData) void {
    for (prompt.questions) |question| {
        allocator.free(question.options);
    }
    allocator.free(prompt.questions);
}

fn maybeResolvePendingQuestionFromToolUpdate(agent_state: *AgentState, tool_call_id: []const u8, status: Message.ToolStatus) void {
    if (status != .completed and status != .failed) return;

    const pending = agent_state.getPendingQuestion() orelse return;
    const pending_tool_call_id = pending.tool_call_id orelse return;
    if (!std.mem.eql(u8, pending_tool_call_id, tool_call_id)) return;

    agent_state.clearPendingQuestion();
}

fn parseProtocolPlanStatus(raw_status: ?[]const u8) protocol.PlanEntryStatus {
    const status = raw_status orelse return .pending;
    if (std.mem.eql(u8, status, "in_progress")) return .in_progress;
    if (std.mem.eql(u8, status, "in-progress")) return .in_progress;
    if (std.mem.eql(u8, status, "running")) return .in_progress;
    if (std.mem.eql(u8, status, "completed")) return .completed;
    if (std.mem.eql(u8, status, "done")) return .completed;
    return .pending;
}

fn parseProtocolPlanPriority(raw_priority: ?[]const u8) protocol.PlanEntryPriority {
    const priority = raw_priority orelse return .medium;
    if (std.mem.eql(u8, priority, "high")) return .high;
    if (std.mem.eql(u8, priority, "low")) return .low;
    return .medium;
}

// =============================================================================
// Tests — codexEventToAgentEvent
// =============================================================================

const codex_codec = @import("../codex/codec.zig");
const codex_protocol = @import("../codex/protocol.zig");

test "codexEventToAgentEvent: text_delta maps to text_chunk" {
    const event = CodexEvent{ .text_delta = .{
        .thread_id = "t1",
        .turn_id = "turn-1",
        .item_id = "item-1",
        .delta = "Hello world",
    } };
    const result = codexEventToAgentEvent(event);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .text_chunk);
    try std.testing.expectEqualStrings("Hello world", result.?.text_chunk);
}

test "codexEventToAgentEvent: reasoning_delta maps to thinking_chunk" {
    const event = CodexEvent{ .reasoning_delta = .{
        .thread_id = "t1",
        .turn_id = "turn-1",
        .item_id = "item-1",
        .delta = "Considering...",
    } };
    const result = codexEventToAgentEvent(event);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .thinking_chunk);
    try std.testing.expectEqualStrings("Considering...", result.?.thinking_chunk);
}

test "codexEventToAgentEvent: item_started command_execution maps to tool_call" {
    const event = CodexEvent{ .item_started = .{
        .thread_id = "t1",
        .turn_id = "turn-1",
        .item = .{ .command_execution = .{
            .id = "cmd-1",
            .command = "ls -la",
        } },
    } };
    const result = codexEventToAgentEvent(event);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .tool_call);
    try std.testing.expectEqualStrings("cmd-1", result.?.tool_call.tool_call_id);
    try std.testing.expectEqualStrings("ls -la", result.?.tool_call.title);
}

test "codexEventToAgentEvent: item_completed command_execution maps to tool_update" {
    const event = CodexEvent{ .item_completed = .{
        .thread_id = "t1",
        .turn_id = "turn-1",
        .item = .{ .command_execution = .{
            .id = "cmd-1",
            .command = "ls -la",
            .exit_code = 0,
            .stdout = "file1\nfile2",
        } },
    } };
    const result = codexEventToAgentEvent(event);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .tool_update);
    try std.testing.expectEqual(Message.ToolStatus.completed, result.?.tool_update.status);
    try std.testing.expectEqualStrings("file1\nfile2", result.?.tool_update.stdout.?);
}

test "codexEventToAgentEvent: item_completed agent_message maps to completed agent text" {
    const event = CodexEvent{ .item_completed = .{
        .thread_id = "t1",
        .turn_id = "turn-1",
        .item = .{ .agent_message = .{
            .id = "msg-1",
            .text = "Plan mode reply",
        } },
    } };
    const result = codexEventToAgentEvent(event);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .completed_agent_message);
    try std.testing.expectEqualStrings("Plan mode reply", result.?.completed_agent_message);
}

test "codexEventToAgentEvent: item_completed command_execution with non-zero exit maps to failed" {
    const event = CodexEvent{ .item_completed = .{
        .thread_id = "t1",
        .turn_id = "turn-1",
        .item = .{ .command_execution = .{
            .id = "cmd-1",
            .command = "false",
            .exit_code = 1,
        } },
    } };
    const result = codexEventToAgentEvent(event);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .tool_update);
    try std.testing.expectEqual(Message.ToolStatus.failed, result.?.tool_update.status);
}

test "codexEventToAgentEvent: item_started mcp_tool_call maps to tool_call" {
    const event = CodexEvent{ .item_started = .{
        .thread_id = "t1",
        .turn_id = "turn-1",
        .item = .{ .mcp_tool_call = .{
            .id = "mcp-1",
            .server_name = "functions",
            .tool_name = "update_plan",
            .arguments = "{\"plan\":[{\"step\":\"a\",\"status\":\"pending\"}]}",
            .status = "pending",
        } },
    } };
    const result = codexEventToAgentEvent(event);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .tool_call);
    try std.testing.expectEqualStrings("mcp-1", result.?.tool_call.tool_call_id);
    try std.testing.expectEqualStrings("update_plan", result.?.tool_call.title);
    try std.testing.expectEqualStrings("{\"plan\":[{\"step\":\"a\",\"status\":\"pending\"}]}", result.?.tool_call.command.?);
}

test "processAgentEvent: update_plan tool call populates todos without plan_updated event" {
    const allocator = std.testing.allocator;
    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    processAgentEvent(&agent_state, .{ .tool_call = .{
        .tool_call_id = "mcp-1",
        .tool_name = "update_plan",
        .title = "update_plan",
        .command = "{\"plan\":[{\"step\":\"Investigate todo render\",\"status\":\"in_progress\",\"priority\":\"high\"},{\"content\":\"Validate codex fallback\",\"status\":\"pending\",\"priority\":\"low\"}]}",
    } });

    try std.testing.expectEqual(@as(usize, 2), agent_state.planEntryCount());
    try std.testing.expectEqual(@as(usize, 2), agent_state.messages.items.len);
    try std.testing.expectEqual(Message.Role.tool, agent_state.messages.items[0].role);
    try std.testing.expectEqual(Message.Role.plan_snapshot, agent_state.messages.items[1].role);
}

test "codexEventToAgentEvent: item_completed mcp_tool_call maps to tool_update" {
    const event = CodexEvent{ .item_completed = .{
        .thread_id = "t1",
        .turn_id = "turn-1",
        .item = .{ .mcp_tool_call = .{
            .id = "mcp-1",
            .server_name = "functions",
            .tool_name = "update_plan",
            .output = "Plan updated",
            .status = "completed",
        } },
    } };
    const result = codexEventToAgentEvent(event);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .tool_update);
    try std.testing.expectEqualStrings("mcp-1", result.?.tool_update.tool_call_id);
    try std.testing.expectEqual(Message.ToolStatus.completed, result.?.tool_update.status);
    try std.testing.expectEqualStrings("Plan updated", result.?.tool_update.stdout.?);
}

test "codexEventToAgentEvent: item_started spawn_agent maps to tool_call with subagent info" {
    const event = CodexEvent{ .item_started = .{
        .thread_id = "t1",
        .turn_id = "turn-1",
        .item = .{ .function_call = .{
            .id = "call-1",
            .call_id = "call-1",
            .name = "spawn_agent",
            .arguments = "{\"agent_type\":\"explorer\",\"message\":\"Explore architecture\"}",
        } },
    } };
    const result = codexEventToAgentEvent(event);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .tool_call);
    try std.testing.expectEqualStrings("call-1", result.?.tool_call.tool_call_id);
    try std.testing.expect(result.?.tool_call.subagent_info != null);
    const info = result.?.tool_call.subagent_info.?;
    try std.testing.expectEqualStrings("explorer", info.agent_type.?);
    try std.testing.expectEqualStrings("Explore architecture", info.description.?);
}

test "codexEventToAgentEvent: item_completed spawn_agent output maps to session_id" {
    const event = CodexEvent{ .item_completed = .{
        .thread_id = "t1",
        .turn_id = "turn-1",
        .item = .{ .function_call = .{
            .id = "call-1",
            .call_id = "call-1",
            .name = "spawn_agent",
            .output = "{\"agent_id\":\"019c-subagent\"}",
            .status = "completed",
        } },
    } };
    const result = codexEventToAgentEvent(event);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .tool_update);
    try std.testing.expect(result.?.tool_update.subagent_info != null);
    const info = result.?.tool_update.subagent_info.?;
    try std.testing.expectEqualStrings("019c-subagent", info.session_id.?);
}

test "codexEventToAgentEvent: turn_completed maps to message_complete" {
    const event = CodexEvent{ .turn_completed = .{
        .thread_id = "t1",
        .turn = .{ .id = "turn-1", .status = .completed },
    } };
    const result = codexEventToAgentEvent(event);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .message_complete);
}

test "codexEventToAgentEvent: plan_updated maps to codex_plan_update" {
    var entries = [_]CodexPlanEntry{
        .{ .content = "First step", .status = .in_progress, .priority = .medium },
        .{ .content = "Second step", .status = .pending, .priority = .low },
    };
    const event = CodexEvent{ .plan_updated = .{
        .thread_id = "t1",
        .turn_id = "turn-1",
        .entries = entries[0..],
    } };

    const result = codexEventToAgentEvent(event);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .codex_plan_update);
    try std.testing.expectEqual(@as(usize, 2), result.?.codex_plan_update.len);
    try std.testing.expectEqualStrings("First step", result.?.codex_plan_update[0].content);
    try std.testing.expectEqual(CodexEvent.PlanUpdatedEvent.PlanEntryStatus.in_progress, result.?.codex_plan_update[0].status);
}

test "processAgentEvent: codex plan notification updates todo state end-to-end" {
    const allocator = std.testing.allocator;

    var manager = codex_manager.CodexManager.init(allocator);
    defer manager.deinit();

    var decoder = codex_codec.Decoder.init(allocator);
    const json =
        \\{"method":"thread/plan_updated","params":{"threadId":"thread-1","turnId":"turn-1","plan":{"steps":[{"title":"Reproduce protocol event","state":"running","priority":"high"},{"step":"Verify todo render pipeline","state":"done","priority":"medium"}]}}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(allocator);

    var codex_event = manager.processMessage(msg);
    defer if (codex_event) |*e| manager.deinitEvent(e);
    try std.testing.expect(codex_event != null);

    const agent_event = codexEventToAgentEvent(codex_event.?);
    try std.testing.expect(agent_event != null);
    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    processAgentEvent(&agent_state, agent_event.?);

    try std.testing.expectEqual(@as(usize, 2), agent_state.planEntryCount());
    try std.testing.expectEqual(CodexEvent.PlanUpdatedEvent.PlanEntryStatus.in_progress, codex_event.?.plan_updated.entries[0].status);
    try std.testing.expectEqual(CodexEvent.PlanUpdatedEvent.PlanEntryStatus.completed, codex_event.?.plan_updated.entries[1].status);

    try std.testing.expectEqual(@as(usize, 1), agent_state.messages.items.len);
    try std.testing.expectEqual(Message.Role.plan_snapshot, agent_state.messages.items[0].role);
    try std.testing.expect(agent_state.messages.items[0].plan_snapshot_entries != null);
    const snapshot_entries = agent_state.messages.items[0].plan_snapshot_entries.?;
    try std.testing.expectEqual(@as(usize, 2), snapshot_entries.len);
    try std.testing.expectEqualStrings("Reproduce protocol event", snapshot_entries[0].content);
    try std.testing.expectEqualStrings("Verify todo render pipeline", snapshot_entries[1].content);
}

test "processAgentEvent: codex completed agent message without delta still renders" {
    const allocator = std.testing.allocator;

    var manager = codex_manager.CodexManager.init(allocator);
    defer manager.deinit();

    var decoder = codex_codec.Decoder.init(allocator);
    const json =
        \\{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"agentMessage","id":"msg-1","text":"Plan output is ready"}}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(allocator);

    var codex_event = manager.processMessage(msg);
    defer if (codex_event) |*e| manager.deinitEvent(e);
    try std.testing.expect(codex_event != null);

    const agent_event = codexEventToAgentEvent(codex_event.?);
    try std.testing.expect(agent_event != null);
    try std.testing.expect(agent_event.? == .completed_agent_message);

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    processAgentEvent(&agent_state, agent_event.?);

    try std.testing.expectEqual(@as(usize, 1), agent_state.messages.items.len);
    try std.testing.expectEqual(Message.Role.agent, agent_state.messages.items[0].role);
    try std.testing.expectEqualStrings("Plan output is ready", agent_state.messages.items[0].content);
}

test "processAgentEvent: codex request_user_input function call opens pending question" {
    const allocator = std.testing.allocator;

    var manager = codex_manager.CodexManager.init(allocator);
    defer manager.deinit();

    var decoder = codex_codec.Decoder.init(allocator);
    const json =
        \\{"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"functionCall","id":"call-1","callId":"call-1","name":"request_user_input","arguments":"{\"questions\":[{\"header\":\"Split Model\",\"question\":\"How should sessions be split?\",\"options\":[{\"label\":\"Tab scoped\",\"description\":\"Keep one session per pane\"},{\"label\":\"Shared\",\"description\":\"Reuse one session across panes\"}],\"isOther\":false},{\"header\":\"V1 Scope\",\"question\":\"What should land first?\",\"options\":[{\"label\":\"Display prompt\",\"description\":\"Show the plan questions\"}],\"isOther\":true}]}"}}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(allocator);

    var codex_event = manager.processMessage(msg);
    defer if (codex_event) |*e| manager.deinitEvent(e);
    try std.testing.expect(codex_event != null);

    const agent_event = codexEventToAgentEvent(codex_event.?);
    try std.testing.expect(agent_event != null);
    try std.testing.expect(agent_event.? == .tool_call);

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    processAgentEvent(&agent_state, agent_event.?);

    const pending = agent_state.getPendingQuestion() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("call-1", pending.tool_call_id.?);
    try std.testing.expectEqual(@as(usize, 2), pending.questions.len);
    try std.testing.expectEqualStrings("How should sessions be split?", pending.questions[0].prompt);
    try std.testing.expectEqual(@as(usize, 2), pending.questions[0].options.len);
    try std.testing.expect(pending.questions[0].custom_index == null);
    try std.testing.expectEqual(@as(usize, 2), pending.questions[1].options.len);
    try std.testing.expectEqual(@as(usize, 1), pending.questions[1].custom_index.?);
}

test "processAgentEvent: codex request_user_input completion clears matching pending question" {
    const allocator = std.testing.allocator;

    var manager = codex_manager.CodexManager.init(allocator);
    defer manager.deinit();

    var decoder = codex_codec.Decoder.init(allocator);

    const start_json =
        \\{"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"functionCall","id":"call-1","callId":"call-1","name":"request_user_input","arguments":"{\"questions\":[{\"header\":\"Scope\",\"question\":\"What should we fix first?\",\"options\":[{\"label\":\"UI\"}],\"isOther\":false}]}"}}}
    ;
    var start_msg = try decoder.decode(start_json);
    defer start_msg.deinit(allocator);

    const complete_json =
        \\{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"functionCall","id":"call-1","callId":"call-1","name":"request_user_input","status":"completed","output":"{\"status\":\"submitted\"}"}}}
    ;
    var complete_msg = try decoder.decode(complete_json);
    defer complete_msg.deinit(allocator);

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    var start_event = manager.processMessage(start_msg);
    defer if (start_event) |*e| manager.deinitEvent(e);
    try std.testing.expect(start_event != null);

    const start_agent_event = codexEventToAgentEvent(start_event.?);
    try std.testing.expect(start_agent_event != null);
    processAgentEvent(&agent_state, start_agent_event.?);

    try std.testing.expect(agent_state.getPendingQuestion() != null);

    var complete_event = manager.processMessage(complete_msg);
    defer if (complete_event) |*e| manager.deinitEvent(e);
    try std.testing.expect(complete_event != null);

    const complete_agent_event = codexEventToAgentEvent(complete_event.?);
    try std.testing.expect(complete_agent_event != null);
    try std.testing.expect(complete_agent_event.? == .tool_update);
    processAgentEvent(&agent_state, complete_agent_event.?);

    try std.testing.expect(agent_state.getPendingQuestion() == null);
}

test "codexEventToAgentEvent: unknown maps to null" {
    const event = CodexEvent{ .unknown = {} };
    const result = codexEventToAgentEvent(event);
    try std.testing.expect(result == null);
}

test "codexEventToAgentEvent: command_output_delta maps to tool_update running" {
    const event = CodexEvent{ .command_output_delta = .{
        .thread_id = "t1",
        .turn_id = "turn-1",
        .item_id = "cmd-1",
        .delta = "output line",
    } };
    const result = codexEventToAgentEvent(event);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .tool_update);
    try std.testing.expectEqual(Message.ToolStatus.running, result.?.tool_update.status);
    try std.testing.expectEqualStrings("output line", result.?.tool_update.stdout.?);
}

// =============================================================================
// Phase 6: Token usage and rate limits event mapping
// =============================================================================

test "codexEventToAgentEvent: token_usage_updated maps to token_usage_update" {
    const event = CodexEvent{ .token_usage_updated = codex_protocol.TokenUsage{
        .total = codex_protocol.TokenCounts{
            .total_tokens = 16709,
            .input_tokens = 16687,
            .cached_input_tokens = 7936,
            .output_tokens = 22,
            .reasoning_output_tokens = 0,
        },
        .last = codex_protocol.TokenCounts{
            .total_tokens = 500,
            .input_tokens = 400,
            .cached_input_tokens = 100,
            .output_tokens = 100,
            .reasoning_output_tokens = 50,
        },
        .model_context_window = 258400,
    } };
    const result = codexEventToAgentEvent(event);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .token_usage_update);
    try std.testing.expectEqual(@as(u64, 16709), result.?.token_usage_update.total_tokens);
    try std.testing.expectEqual(@as(u64, 16687), result.?.token_usage_update.input_tokens);
    try std.testing.expectEqual(@as(u64, 22), result.?.token_usage_update.output_tokens);
    try std.testing.expectEqual(@as(u64, 7936), result.?.token_usage_update.cached_input_tokens);
    try std.testing.expectEqual(@as(u64, 258400), result.?.token_usage_update.model_context_window);
}

test "codexEventToAgentEvent: token_usage_updated without total maps to null" {
    const event = CodexEvent{ .token_usage_updated = codex_protocol.TokenUsage{
        .total = null,
        .last = null,
        .model_context_window = null,
    } };
    const result = codexEventToAgentEvent(event);
    try std.testing.expect(result == null);
}

test "codexEventToAgentEvent: token_usage_updated falls back to last when total missing" {
    const event = CodexEvent{ .token_usage_updated = codex_protocol.TokenUsage{
        .total = null,
        .last = codex_protocol.TokenCounts{
            .total_tokens = 900,
            .input_tokens = 700,
            .cached_input_tokens = 100,
            .output_tokens = 200,
            .reasoning_output_tokens = 20,
        },
        .model_context_window = 128000,
    } };
    const result = codexEventToAgentEvent(event);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .token_usage_update);
    try std.testing.expectEqual(@as(u64, 900), result.?.token_usage_update.total_tokens);
    try std.testing.expectEqual(@as(u64, 128000), result.?.token_usage_update.model_context_window);
}

test "codexEventToAgentEvent: rate_limits_updated maps to rate_limits_update" {
    const event = CodexEvent{ .rate_limits_updated = codex_protocol.RateLimits{
        .primary = .{ .used_percent = 42.5, .credits = null },
        .secondary = .{ .used_percent = 1.0, .credits = null },
    } };
    const result = codexEventToAgentEvent(event);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .rate_limits_update);
    try std.testing.expectApproxEqRel(@as(f64, 42.5), result.?.rate_limits_update.primary_used_percent, 0.001);
    try std.testing.expectApproxEqRel(@as(f64, 1.0), result.?.rate_limits_update.secondary_used_percent, 0.001);
}

test "codexEventToAgentEvent: mcp_server_status maps to mcp_server_status" {
    const event = CodexEvent{ .mcp_server_status = {} };
    const result = codexEventToAgentEvent(event);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .mcp_server_status);
}
