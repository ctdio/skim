/// Unified event type for both ACP and OpenCode protocol events.
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

/// A unified event representing an update from either ACP or OpenCode.
/// Provides a single processAgentEvent function for routing events to AgentState.
pub const AgentEvent = union(enum) {
    // Streaming content
    text_chunk: []const u8,
    thinking_chunk: []const u8,
    message_complete: void,

    // System
    system_message: []const u8,
    error_message: []const u8,

    // Tools
    tool_call: ToolCallEvent,
    tool_update: ToolUpdateEvent,
    tool_diff: ToolDiffEvent,

    // Plan (ACP-only, but still part of unified type)
    plan_update: []const protocol.PlanEntry,
    commands_update: []const protocol.AvailableCommand,

    // Session lifecycle
    session_compacted: void,

    // Questions (OpenCode-only, but still part of unified type)
    question_prompt: QuestionPromptData,
    question_resolved: void,

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
                    agent_state.setSubagentInfoOnTool(tu.tool_call_id, owned);
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
pub fn opencodeEventToAgentEvent(event: OpencodeEvent) ?AgentEvent {
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
        .commands_update => |commands| .{ .commands_update = commands },
        .session_compacted => .{ .session_compacted = {} },
        .question_prompt => null, // Handled separately by pollEvents (needs allocator for conversion)
        .question_resolved => .{ .question_resolved = {} },
        .err => |e| .{ .error_message = e.message orelse @tagName(e.code) },
        .status_change => null, // Handled separately by caller
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
        info.summary = summaries.toOwnedSlice(allocator) catch &.{};
    }

    return info;
}

/// Convert only the summary portion of SubagentEventInfo into owned SubagentToolSummary slice.
/// Used for partial updates (child tool progress) where we merge into existing info.
fn convertSummaryOnly(allocator: Allocator, src: []opencode_manager.Event.SubagentToolSummary) []SubagentToolSummary {
    if (src.len == 0) return &.{};
    var summaries: std.ArrayList(SubagentToolSummary) = .{};
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
    return summaries.toOwnedSlice(allocator) catch &.{};
}

fn convertToolStatus(s: opencode_manager.ToolStatus) Message.ToolStatus {
    return switch (s) {
        .pending => .pending,
        .running => .running,
        .completed => .completed,
        .failed => .failed,
    };
}
