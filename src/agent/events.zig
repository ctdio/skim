/// Unified event type for both ACP and OpenCode protocol events.
/// Provides a single dispatch point for routing protocol events to AgentState.
const std = @import("std");
const AgentState = @import("state.zig").AgentState;
const Message = @import("state.zig").Message;
const protocol = @import("../acp/protocol.zig");
const AcpManager = @import("../acp/manager.zig").AcpManager;
const opencode_manager = @import("../opencode/manager.zig");
const OpencodeEvent = opencode_manager.Event;

/// A unified event representing an update from either ACP or OpenCode.
/// This replaces the duplicated switch statements in pollTabAcpManager and
/// pollTabOpencodeManager with a single processAgentEvent function.
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

    // Questions (OpenCode-only, but still part of unified type)
    question_prompt: void, // Handled separately by caller (needs allocator for conversion)
    question_resolved: void,

    pub const ToolCallEvent = struct {
        tool_call_id: []const u8,
        tool_name: ?[]const u8,
        title: []const u8,
        command: ?[]const u8,
    };

    pub const ToolUpdateEvent = struct {
        tool_call_id: []const u8,
        status: Message.ToolStatus,
        stdout: ?[]const u8,
        stderr: ?[]const u8,
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
        },
        .tool_update => |tu| {
            agent_state.updateToolMessage(
                tu.tool_call_id,
                tu.status,
                tu.stdout,
                tu.stderr,
            ) catch {};
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
        .question_resolved => {
            agent_state.clearPendingQuestion();
        },
        // question_prompt is handled separately in the caller (needs allocator for conversion)
        .message_complete, .question_prompt => {},
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
        } },
        .tool_diff => |d| .{ .tool_diff = .{
            .tool_call_id = d.tool_call_id,
            .title = d.title,
            .path = d.path,
            .old_text = d.old_text,
            .new_text = d.new_text,
        } },
        .question_prompt => .{ .question_prompt = {} },
        .question_resolved => .{ .question_resolved = {} },
        .err => |e| .{ .error_message = e.message orelse @tagName(e.code) },
        .status_change => null, // Handled separately by caller
    };
}
