//! Tests for `acp/session_replay.zig`, the parser behind `skim debug acp` and
//! the landing-page agent demo.
//!
//! Lives here rather than beside the parser because the parser reaches
//! `agent/state.zig`, and a test target rooted at the parser would collect that
//! neighbourhood's `test {}` blocks too. Reaching the parser through the
//! `session_replay_root` NAMED module keeps this binary to these tests
//! (mirrors review_test_root and the web session tests).

const std = @import("std");
const replay_root = @import("session_replay_root");
const AgentState = replay_root.AgentState;
const AgentMessage = replay_root.AgentMessage;
const AcpManager = replay_root.AcpManager;

const replaySessionFromString = replay_root.acp_session_replay.replaySessionFromString;
const replaySessionLine = replay_root.acp_session_replay.replaySessionLine;
const ReplaySummary = replay_root.acp_session_replay.ReplaySummary;
const loadReplayLines = replay_root.acp_session_replay.loadReplayLines;

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

test "replaySessionLine turns tool_use and tool_result into a tool message" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    const log =
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Pulling your notes."},{"type":"tool_use","id":"t1","name":"get_comments","input":{"client_id":"skim-1"}}]}}
        \\{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"1 comment"}]}]}}
    ;

    const summary = try replaySessionFromString(allocator, &agent_state, log);
    try std.testing.expectEqual(AcpManager.Status.session_active, summary.manager_status);

    try std.testing.expectEqual(@as(usize, 2), agent_state.messages.items.len);
    try std.testing.expectEqualStrings("Pulling your notes.", agent_state.messages.items[0].content);

    const tool = agent_state.messages.items[1];
    try std.testing.expectEqual(AgentMessage.Role.tool, tool.role);
    try std.testing.expectEqualStrings("get_comments", tool.content);
    try std.testing.expectEqualStrings("get_comments", tool.tool_name.?);
    try std.testing.expectEqualStrings("{\"client_id\":\"skim-1\"}", tool.tool_command.?);
    try std.testing.expectEqual(AgentMessage.ToolStatus.completed, tool.tool_status);
    try std.testing.expectEqualStrings("1 comment", tool.tool_stdout.?);
}

test "replaySessionLine keeps text before a tool call ahead of it" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    const log =
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"before"},{"type":"tool_use","id":"t1","name":"add_comment","input":{}},{"type":"text","text":"after"}]}}
    ;

    _ = try replaySessionFromString(allocator, &agent_state, log);

    try std.testing.expectEqual(@as(usize, 3), agent_state.messages.items.len);
    try std.testing.expectEqualStrings("before", agent_state.messages.items[0].content);
    try std.testing.expectEqual(AgentMessage.Role.tool, agent_state.messages.items[1].role);
    try std.testing.expectEqualStrings("after", agent_state.messages.items[2].content);
}

test "replaySessionLine marks an errored tool_result as failed" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    const log =
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"add_comment","input":{}}]}}
        \\{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"no such client"}]}}
    ;

    _ = try replaySessionFromString(allocator, &agent_state, log);

    try std.testing.expectEqual(@as(usize, 1), agent_state.messages.items.len);
    const tool = agent_state.messages.items[0];
    try std.testing.expectEqual(AgentMessage.ToolStatus.failed, tool.tool_status);
    try std.testing.expectEqualStrings("no such client", tool.tool_stdout.?);
}

test "a tool_use title stands for the whole call" {
    const allocator = std.testing.allocator;
    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    const log =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a1","name":"add_comment","title":"add_comment(src/line_map.zig:50)","input":{"line":50,"text":"stale index"}}]}}
    ;

    _ = try replaySessionFromString(allocator, &agent_state, log);

    const tool = agent_state.messages.items[0];
    try std.testing.expectEqualStrings("add_comment(src/line_map.zig:50)", tool.content);
    // The title said what the call does, so the raw arguments stay off screen.
    try std.testing.expect(tool.tool_command == null);
}

test "a tool_use with no title keeps its arguments on screen" {
    const allocator = std.testing.allocator;
    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    const log =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a1","name":"add_comment","input":{"line":50}}]}}
    ;

    _ = try replaySessionFromString(allocator, &agent_state, log);

    const tool = agent_state.messages.items[0];
    try std.testing.expectEqualStrings("add_comment", tool.content);
    try std.testing.expect(tool.tool_command != null);
    try std.testing.expect(std.mem.indexOf(u8, tool.tool_command.?, "\"line\":50") != null);
}

// The transcript the landing page replays. It is data, not code, so nothing
// else would catch a parser change that silently drops half of it.
const SITE_TRANSCRIPTS = [_][]const u8{
    "site/src/lib/agent-two-way.jsonl",
};

test "the shipped transcripts replay into text and tool messages" {
    const allocator = std.testing.allocator;

    for (SITE_TRANSCRIPTS) |path| {
        const lines = loadReplayLines(allocator, path) catch |err| {
            std.debug.print("cannot read {s}: {t}\n", .{ path, err });
            return err;
        };
        defer {
            for (lines) |line| allocator.free(line);
            allocator.free(lines);
        }

        var agent_state = AgentState.init(allocator, .right);
        defer agent_state.deinit();

        var summary = ReplaySummary{};
        for (lines) |line| try replaySessionLine(allocator, &agent_state, line, &summary);

        var tools: usize = 0;
        for (agent_state.messages.items) |msg| {
            if (msg.role != .tool) continue;
            tools += 1;
            // Every tool call in these transcripts is answered, so none may be
            // left pending — a dropped `tool_result` would show as a spinner.
            try std.testing.expectEqual(AgentMessage.ToolStatus.completed, msg.tool_status);
            try std.testing.expect(msg.tool_stdout != null);
            // The call names itself, either through the `title` the transcript
            // carries or through the tool name it falls back to.
            try std.testing.expect(msg.content.len > 0);
        }
        try std.testing.expect(tools >= 3);
        try std.testing.expect(agent_state.messages.items.len > tools);
    }
}
