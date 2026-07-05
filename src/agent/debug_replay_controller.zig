const std = @import("std");

const agent_state_mod = @import("state.zig");
const acp_session_replay = @import("../acp/session_replay.zig");
const codex_session_replay = @import("../codex/session_replay.zig");
const opencode_session_replay = @import("../opencode/session_replay.zig");
const ManagerHandle = @import("manager_handle.zig").ManagerHandle;

const AgentState = agent_state_mod.AgentState;
const DebugReplayManagerStatus = agent_state_mod.DebugReplayManagerStatus;

pub const StepContext = struct {
    allocator: std.mem.Allocator,
    agent_state: ?*AgentState,
    manager: ?ManagerHandle,
    needs_render: *bool,
};

pub fn isPlaying(agent_state: ?*const AgentState) bool {
    if (agent_state) |st| {
        return st.isDebugReplayPlaying();
    }
    return false;
}

pub fn togglePlaying(agent_state: ?*AgentState, needs_render: *bool) bool {
    const st = agent_state orelse return false;
    const playing = st.toggleDebugReplayPlaying();
    needs_render.* = true;
    return playing;
}

pub fn restart(agent_state: ?*AgentState, manager: ?ManagerHandle, needs_render: *bool) void {
    const st = agent_state orelse return;
    st.restartDebugReplay();
    if (st.getDebugReplayConst()) |replay| {
        syncManagerStatus(manager, replay.manager_status);
    }
    needs_render.* = true;
}

/// Tear down the active replay's sub-state. Returns whether exiting should quit
/// the whole app; the caller applies that app-level decision.
pub fn exit(agent_state: *AgentState) bool {
    const quit_app = if (agent_state.getDebugReplayConst()) |replay| replay.exit_quits_app else false;

    agent_state.clearDebugReplay();
    agent_state.exitHistoryMode();
    agent_state.input.vim.vim_mode = .normal;

    return quit_app;
}

pub fn step(ctx: StepContext) !bool {
    const agent_state = ctx.agent_state orelse return false;
    const replay = agent_state.getDebugReplay() orelse return false;
    if (replay.isComplete()) {
        replay.playing = false;
        return false;
    }

    const current_line = replay.lines[replay.current_index];

    if (replay.kind == .codex and !replay.previewing_current_line) {
        if (try codex_session_replay.previewPendingQuestionResolution(ctx.allocator, agent_state, current_line)) {
            replay.previewing_current_line = true;
            replay.step_delay_override_ms = agent_state_mod.debug_replay_question_answer_preview_linger_ms;
            replay.last_step_ms = std.time.milliTimestamp();
            syncManagerStatus(ctx.manager, replay.manager_status);
            if (!agent_state.isInHistoryMode() and agent_state.messages.items.len > 0) {
                agent_state.enterHistoryMode();
            }
            ctx.needs_render.* = true;
            return true;
        }
    }

    switch (replay.kind) {
        .acp => {
            var summary = acp_session_replay.ReplaySummary{
                .manager_status = switch (replay.manager_status) {
                    .acp => |status| status,
                    else => .session_active,
                },
            };
            try acp_session_replay.replaySessionLine(
                ctx.allocator,
                agent_state,
                current_line,
                &summary,
            );
            replay.manager_status = .{ .acp = summary.manager_status };
        },
        .opencode => {
            const mgr_handle = ctx.manager orelse return false;
            switch (mgr_handle) {
                .opencode => |mgr| {
                    try opencode_session_replay.replaySessionLine(mgr, current_line);
                    _ = mgr_handle.pollEvents(ctx.allocator, agent_state);
                    replay.manager_status = .{ .opencode = mgr.status };
                },
                else => return false,
            }
        },
        .codex => {
            var summary = codex_session_replay.ReplaySummary{
                .manager_status = switch (replay.manager_status) {
                    .codex => |status| status,
                    else => .thread_active,
                },
            };
            try codex_session_replay.replaySessionLine(
                ctx.allocator,
                agent_state,
                current_line,
                &summary,
            );
            replay.manager_status = .{ .codex = summary.manager_status };
        },
    }

    replay.previewing_current_line = false;
    replay.current_index += 1;
    replay.step_delay_override_ms = switch (replay.kind) {
        .codex => if (codex_session_replay.lineStartsRequestUserInput(ctx.allocator, current_line))
            agent_state_mod.debug_replay_question_prompt_linger_ms
        else
            null,
        else => null,
    };
    replay.last_step_ms = std.time.milliTimestamp();
    if (replay.isComplete()) {
        replay.playing = false;
    }

    syncManagerStatus(ctx.manager, replay.manager_status);
    if (!agent_state.isInHistoryMode() and agent_state.messages.items.len > 0) {
        agent_state.enterHistoryMode();
    }
    ctx.needs_render.* = true;
    return true;
}

pub fn advanceIfDue(ctx: StepContext) void {
    const agent_state = ctx.agent_state orelse return;
    const replay = agent_state.getDebugReplay() orelse return;
    if (!replay.playing or replay.isComplete()) return;

    const now = std.time.milliTimestamp();
    const step_delay_ms = replay.step_delay_override_ms orelse replay.step_interval_ms;
    if (now - replay.last_step_ms < step_delay_ms) return;

    _ = step(ctx) catch |err| {
        std.log.err("Failed to advance debug replay: {any}", .{err});
        if (agent_state.getDebugReplay()) |active_replay| {
            active_replay.playing = false;
        }
        return;
    };
}

fn syncManagerStatus(manager: ?ManagerHandle, status: DebugReplayManagerStatus) void {
    if (manager) |mgr| {
        switch (mgr) {
            .acp => |acp_mgr| switch (status) {
                .acp => |acp_status| acp_mgr.status = acp_status,
                else => {},
            },
            .opencode => |opencode_mgr| switch (status) {
                .opencode => |opencode_status| opencode_mgr.status = opencode_status,
                else => {},
            },
            .codex => |codex_mgr| switch (status) {
                .codex => |codex_status| codex_mgr.status = codex_status,
                else => {},
            },
        }
    }
}
