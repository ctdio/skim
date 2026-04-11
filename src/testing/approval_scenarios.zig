const std = @import("std");
const vaxis = @import("vaxis");
const harness = @import("harness.zig");
const snapshot = @import("snapshot.zig");
const approval_root = @import("approval_test_root");
const acp_replay = approval_root.AcpSessionReplay;
const codex_replay = approval_root.CodexSessionReplay;
const opencode_replay = approval_root.OpencodeSessionReplay;

const FRAME_TEXT_CAPACITY: usize = 262144;

test "snapshot: codex_command_approval" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 70, 12);
    defer ctx.deinit();

    const cmd = .{
        .command = @as([]const u8, "npm install --save express"),
        .cwd = @as(?[]const u8, "/home/user/project"),
        .reason = @as(?[]const u8, "Installing web framework dependency"),
        .selected_decision = approval_root.CommandDecision.accept,
    };

    const win = ctx.window();
    try approval_root.renderCommandApproval(win, &cmd);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "codex_command_approval", text);
}

test "snapshot: codex_file_change_approval" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 70, 10);
    defer ctx.deinit();

    const fc = .{
        .path = @as([]const u8, "src/components/Header.tsx"),
        .selected_decision = approval_root.FileChangeDecision.accept,
    };

    const win = ctx.window();
    try approval_root.renderFileChangeApproval(win, &fc);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "codex_file_change_approval", text);
}

test "snapshot: ansi_agent_input_prompt_ready" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 20, 1);
    defer ctx.deinit();

    const win = ctx.window();
    win.fill(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .bg = approval_root.Color.comment_bg },
    });

    var prompt_seg = [_]harness.Cell.Segment{
        .{ .text = "> ", .style = approval_root.getInputPromptStyle(false, true) },
        .{ .text = "hello", .style = .{ .fg = approval_root.Color.white, .bg = approval_root.Color.comment_bg } },
    };
    _ = win.print(&prompt_seg, .{ .row_offset = 0, .col_offset = 1 });

    const ansi = try ctx.captureToAnsi();
    defer allocator.free(ansi);

    try snapshot.expectSnapshot(allocator, "ansi_agent_input_prompt_ready", ansi);
}

test "snapshot: codex_user_input_single_question" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 70, 12);
    defer ctx.deinit();

    var opts = [_]approval_root.UserInputOption{
        .{ .label = "TypeScript", .description = "Strongly typed JavaScript" },
        .{ .label = "Python", .description = "General purpose scripting" },
        .{ .label = "Go", .description = "Systems programming" },
    };

    var questions = [_]approval_root.UserInputQuestion{
        .{
            .id = "lang",
            .header = "Language Selection",
            .question = "Which programming language should we use?",
            .options = &opts,
            .is_other = false,
            .selected_index = 1,
        },
    };

    const ui = .{
        .questions = @as([]approval_root.UserInputQuestion, &questions),
        .active_question = @as(usize, 0),
    };

    const win = ctx.window();
    try approval_root.renderUserInputApproval(win, &ui);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "codex_user_input_single_question", text);
}

test "codex thinking chunks render into chat state" {
    const allocator = std.testing.allocator;
    var agent_state = approval_root.AgentState.init(allocator, .right);
    defer agent_state.deinit();

    const codex_event = approval_root.CodexManager.CodexEvent{ .reasoning_delta = .{
        .thread_id = "thread-1",
        .turn_id = "turn-1",
        .item_id = "reasoning-1",
        .delta = "Considering options...",
    } };
    const agent_event = approval_root.codexEventToAgentEvent(codex_event) orelse return error.TestUnexpectedResult;

    approval_root.processAgentEvent(&agent_state, agent_event);

    try std.testing.expectEqual(@as(usize, 1), agent_state.messages.items.len);
    try std.testing.expectEqual(approval_root.AgentMessage.Role.thinking, agent_state.messages.items[0].role);
    try std.testing.expectEqualStrings("Considering options...", agent_state.messages.items[0].content);
}

test "codex thinking chunks skip short aggregated duplicates" {
    const allocator = std.testing.allocator;
    var agent_state = approval_root.AgentState.init(allocator, .right);
    defer agent_state.deinit();

    approval_root.processAgentEvent(&agent_state, .{ .thinking_chunk = "Thinking" });
    approval_root.processAgentEvent(&agent_state, .{ .thinking_chunk = "..." });
    approval_root.processAgentEvent(&agent_state, .{ .thinking_chunk = "Thinking..." });

    try std.testing.expectEqual(@as(usize, 1), agent_state.messages.items.len);
    try std.testing.expectEqual(approval_root.AgentMessage.Role.thinking, agent_state.messages.items[0].role);
    try std.testing.expectEqualStrings("Thinking...", agent_state.messages.items[0].content);
}

test "snapshot: codex_reasoning_text_delta_panel" {
    const allocator = std.testing.allocator;

    var app = try initRenderTestApp(allocator);
    defer deinitRenderTestApp(&app);

    var ctx = try harness.createTestContext(allocator, 80, 16);
    defer ctx.deinit();

    const tab = try app.tab_manager.?.createTab("Tab 1");
    const mgr = try tab.createCodexManager();

    const proc = try approval_root.CodexProcess.spawnRaw(allocator, &.{"/bin/cat"});
    mgr.process = proc;
    mgr.transport = try approval_root.CodexTransport.init(allocator, proc);
    mgr.status = .thread_active;
    tab.agent_state.visible = true;
    app.mode = .agent;

    var decoder = approval_root.CodexCodec.Decoder.init(allocator);
    const json =
        \\{"method":"item/reasoning/textDelta","params":{"threadId":"t1","turnId":"turn-1","itemId":"reasoning-1","contentIndex":0,"delta":"Inspecting the render path before changing the panel."}}
    ;
    const msg = try decoder.decode(json);
    try mgr.transport.?.pending_messages.append(allocator, msg);

    const result = tab.manager.?.pollEvents(allocator, &tab.agent_state);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqual(approval_root.CodexManager.Status.turn_active, mgr.status);

    try approval_root.renderAgentPanel(&app, ctx.window());

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Inspecting the render path before changing the panel.") != null);
    try snapshot.expectSnapshot(allocator, "codex_reasoning_text_delta_panel", text);
}

test "snapshot: codex_reasoning_summary_panel" {
    const allocator = std.testing.allocator;

    var app = try initRenderTestApp(allocator);
    defer deinitRenderTestApp(&app);

    var ctx = try harness.createTestContext(allocator, 90, 18);
    defer ctx.deinit();

    const tab = try app.tab_manager.?.createTab("Tab 1");
    const mgr = try tab.createCodexManager();

    const proc = try approval_root.CodexProcess.spawnRaw(allocator, &.{"/bin/cat"});
    mgr.process = proc;
    mgr.transport = try approval_root.CodexTransport.init(allocator, proc);
    mgr.status = .thread_active;
    tab.agent_state.visible = true;
    app.mode = .agent;

    var decoder = approval_root.CodexCodec.Decoder.init(allocator);
    const messages = [_][]const u8{
        "{\"method\":\"item/reasoning/summaryPartAdded\",\"params\":{\"threadId\":\"t1\",\"turnId\":\"turn-1\",\"itemId\":\"reasoning-1\",\"summaryIndex\":0}}",
        "{\"method\":\"item/reasoning/summaryTextDelta\",\"params\":{\"threadId\":\"t1\",\"turnId\":\"turn-1\",\"itemId\":\"reasoning-1\",\"summaryIndex\":0,\"delta\":\"**Comparing options**\\n\\nStart with the risk profile.\"}}",
        "{\"method\":\"item/reasoning/summaryPartAdded\",\"params\":{\"threadId\":\"t1\",\"turnId\":\"turn-1\",\"itemId\":\"reasoning-1\",\"summaryIndex\":1}}",
        "{\"method\":\"item/reasoning/summaryTextDelta\",\"params\":{\"threadId\":\"t1\",\"turnId\":\"turn-1\",\"itemId\":\"reasoning-1\",\"summaryIndex\":1,\"delta\":\"**Choosing a default**\\n\\nPrefer the safer migration path.\"}}",
    };

    for (messages) |json| {
        const msg = try decoder.decode(json);
        try mgr.transport.?.pending_messages.append(allocator, msg);
    }

    const result = tab.manager.?.pollEvents(allocator, &tab.agent_state);
    try std.testing.expectEqual(@as(usize, 3), result.count);
    try std.testing.expectEqual(approval_root.CodexManager.Status.turn_active, mgr.status);

    try approval_root.renderAgentPanel(&app, ctx.window());

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Comparing options") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Choosing a default") != null);
    try snapshot.expectSnapshot(allocator, "codex_reasoning_summary_panel", text);
}

test "snapshot: codex_user_input_multiple_questions" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 70, 14);
    defer ctx.deinit();

    var opts1 = [_]approval_root.UserInputOption{
        .{ .label = "REST API", .description = null },
        .{ .label = "GraphQL", .description = null },
    };

    var opts2 = [_]approval_root.UserInputOption{
        .{ .label = "PostgreSQL", .description = null },
        .{ .label = "MongoDB", .description = null },
        .{ .label = "SQLite", .description = null },
    };

    var questions = [_]approval_root.UserInputQuestion{
        .{
            .id = "api_style",
            .header = "API Style",
            .question = "What API style do you prefer?",
            .options = &opts1,
            .is_other = false,
            .selected_index = 0,
        },
        .{
            .id = "database",
            .header = "Database",
            .question = "Which database should we use?",
            .options = &opts2,
            .is_other = false,
            .selected_index = 2,
        },
    };

    const ui = .{
        .questions = @as([]approval_root.UserInputQuestion, &questions),
        .active_question = @as(usize, 0),
    };

    const win = ctx.window();
    try approval_root.renderUserInputApproval(win, &ui);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "codex_user_input_multiple_questions", text);
}

test "snapshot: codex_user_input_with_is_other" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 70, 10);
    defer ctx.deinit();

    var opts = [_]approval_root.UserInputOption{
        .{ .label = "Yes", .description = null },
        .{ .label = "No", .description = null },
    };

    var questions = [_]approval_root.UserInputQuestion{
        .{
            .id = "confirm",
            .header = null,
            .question = "Do you want to proceed with the refactoring?",
            .options = &opts,
            .is_other = true,
            .selected_index = 0,
        },
    };

    const ui = .{
        .questions = @as([]approval_root.UserInputQuestion, &questions),
        .active_question = @as(usize, 0),
    };

    const win = ctx.window();
    try approval_root.renderUserInputApproval(win, &ui);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "codex_user_input_with_is_other", text);
}

test "renderAgentPanel shows codex user input prompt after approval request" {
    const allocator = std.testing.allocator;

    var app = try initRenderTestApp(allocator);
    defer deinitRenderTestApp(&app);

    var ctx = try harness.createTestContext(allocator, 80, 18);
    defer ctx.deinit();

    const tab = try app.tab_manager.?.createTab("Tab 1");
    const mgr = try tab.createCodexManager();

    const proc = try approval_root.CodexProcess.spawnRaw(allocator, &.{"/bin/cat"});
    mgr.process = proc;
    mgr.transport = try approval_root.CodexTransport.init(allocator, proc);
    mgr.status = .turn_active;

    var decoder = approval_root.CodexCodec.Decoder.init(allocator);
    const json =
        \\{"id":0,"method":"item/tool/requestUserInput","params":{"threadId":"t1","turnId":"turn-1","itemId":"call-1","questions":[{"id":"q1","header":"Scope","question":"How should sessions be split?","options":[{"label":"Tab scoped","description":"Keep one session per pane"},{"label":"Shared","description":"Reuse one session across panes"}],"isOther":false},{"id":"q2","header":"Constraints","question":"Any constraints?","options":[{"label":"Keep it small","description":"Prefer a narrow patch"}],"isOther":true}]}}
    ;
    const msg = try decoder.decode(json);
    try mgr.transport.?.pending_messages.append(allocator, msg);

    const result = tab.manager.?.pollEvents(allocator, &tab.agent_state);
    try std.testing.expectEqual(@as(usize, 1), result.count);

    const pending = tab.agent_state.getPendingQuestion() orelse return error.TestUnexpectedResult;
    pending.active_index = 1;

    try approval_root.renderAgentPanel(&app, ctx.window());

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Any constraints?") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Keep it small") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Type your own answer") != null);
}

test "renderAgentPanel uses plain background for question prompt input area" {
    const allocator = std.testing.allocator;

    var app = try initRenderTestApp(allocator);
    defer deinitRenderTestApp(&app);

    var ctx = try harness.createTestContext(allocator, 80, 18);
    defer ctx.deinit();

    const tab = try app.tab_manager.?.createTab("Tab 1");
    const mgr = try tab.createCodexManager();

    const proc = try approval_root.CodexProcess.spawnRaw(allocator, &.{"/bin/cat"});
    mgr.process = proc;
    mgr.transport = try approval_root.CodexTransport.init(allocator, proc);
    mgr.status = .turn_active;

    var decoder = approval_root.CodexCodec.Decoder.init(allocator);
    const json =
        \\{"id":0,"method":"item/tool/requestUserInput","params":{"threadId":"t1","turnId":"turn-1","itemId":"call-1","questions":[{"id":"q1","header":"Scope","question":"How should sessions be split?","options":[{"label":"Tab scoped","description":"Keep one session per pane"},{"label":"Shared","description":"Reuse one session across panes"}],"isOther":false}]}}
    ;
    const msg = try decoder.decode(json);
    try mgr.transport.?.pending_messages.append(allocator, msg);

    const result = tab.manager.?.pollEvents(allocator, &tab.agent_state);
    try std.testing.expectEqual(@as(usize, 1), result.count);

    try approval_root.renderAgentPanel(&app, ctx.window());

    const cell = ctx.screen.readCell(79, 17) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(harness.Cell.Color, .default), cell.style.bg);
}

test "snapshot: agent_slash_menu_shows_command_details" {
    const allocator = std.testing.allocator;

    var app = try initRenderTestApp(allocator);
    defer deinitRenderTestApp(&app);

    var ctx = try harness.createTestContext(allocator, 80, 18);
    defer ctx.deinit();

    const tab = try app.tab_manager.?.createTab("Tab 1");
    try tab.agent_state.addLocalSlashCommands();
    tab.agent_state.input.vim.vim_mode = .insert;
    tab.agent_state.input.setText("/pl");
    tab.agent_state.showSlashMenu();

    try approval_root.renderAgentPanel(&app, ctx.window());

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "agent_slash_menu_shows_command_details", text);
}

test "renderAgentPanel handles nested split panes in a short viewport" {
    const allocator = std.testing.allocator;

    var app = try initRenderTestApp(allocator);
    defer deinitRenderTestApp(&app);

    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    _ = try app.tab_manager.?.createTab("Tab 1");
    const tab2 = try app.tab_manager.?.createHiddenTab("Tab 2");
    try std.testing.expect(try app.tab_manager.?.splitFocusedPane(.vertical, tab2.id));

    const tab3 = try app.tab_manager.?.createHiddenTab("Tab 3");
    try std.testing.expect(try app.tab_manager.?.splitFocusedPane(.horizontal, tab3.id));

    try approval_root.renderAgentPanel(&app, ctx.window());

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try std.testing.expect(text.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, text, "Tab 3") != null);
}

test "snapshot: codex_completed_plan_panel" {
    const allocator = std.testing.allocator;

    var app = try initRenderTestApp(allocator);
    defer deinitRenderTestApp(&app);

    var ctx = try harness.createTestContext(allocator, 80, 24);
    defer ctx.deinit();

    const tab = try app.tab_manager.?.createTab("Tab 1");
    const mgr = try tab.createCodexManager();
    mgr.status = .thread_active;

    const log =
        \\{"timestamp":"2026-03-27T03:54:03.784Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1","model_context_window":258400,"collaboration_mode_kind":"plan"}}
        \\{"timestamp":"2026-03-27T03:54:03.789Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Design split panes for the agent panel."}]}}
        \\{"timestamp":"2026-03-27T03:54:09.550Z","type":"event_msg","payload":{"type":"agent_message","message":"I’m expanding this into a handoff-grade spec now.","phase":"commentary","memory_citation":null}}
        \\{"timestamp":"2026-03-27T03:55:11.957Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"thread-1","turn_id":"turn-1","item":{"type":"Plan","id":"turn-1-plan","text":"# Split Panes\n\n## Summary\nAdd vertical panes inside the agent panel.\n\n## Key Changes\n- Keep tabs as workspaces.\n- Route input through the focused pane."}}}
        \\{"timestamp":"2026-03-27T03:55:11.988Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","last_agent_message":"I’m expanding this into a handoff-grade spec now."}}
    ;

    const summary = try codex_replay.replaySessionFromString(allocator, &tab.agent_state, log);
    mgr.status = summary.manager_status;
    try approval_root.renderAgentPanel(&app, ctx.window());

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Press Enter to accept this plan") != null);
    try snapshot.expectSnapshot(allocator, "codex_completed_plan_panel", text);
}

test "accepting a codex completed plan switches the next turn to code mode" {
    const allocator = std.testing.allocator;

    var app = try initRenderTestApp(allocator);
    defer deinitRenderTestApp(&app);

    const tab = try app.tab_manager.?.createTab("Tab 1");
    const mgr = try tab.createCodexManager();

    const proc = try approval_root.CodexProcess.spawnRaw(allocator, &.{"/bin/cat"});
    const transport = try approval_root.CodexTransport.init(allocator, proc);
    mgr.process = proc;
    mgr.transport = transport;
    mgr.status = .thread_active;
    mgr.thread_id = "thread-1";
    mgr.collaboration_mode = .plan;
    mgr.requested_collaboration_mode = .plan;

    try tab.agent_state.addCompletedAgentMessage("<proposed_plan>\n# Plan\n</proposed_plan>");
    tab.agent_state.input.vim.vim_mode = .insert;

    try approval_root.handleAgentKey(&app, .{ .codepoint = vaxis.Key.enter });

    try std.testing.expect(app.needs_render);
    try std.testing.expectEqual(approval_root.CodexManager.Status.turn_active, mgr.status);
    try std.testing.expectEqual(.default, mgr.collaboration_mode.?);
    try std.testing.expectEqual(.default, mgr.requested_collaboration_mode.?);
    try std.testing.expectEqual(@as(usize, 2), tab.agent_state.messages.items.len);
    try std.testing.expectEqualStrings("This plan looks correct.", tab.agent_state.messages.items[1].content);
}

test "snapshot: codex_replay_in_progress_panel" {
    const allocator = std.testing.allocator;

    var app = try initRenderTestApp(allocator);
    defer deinitRenderTestApp(&app);

    var ctx = try harness.createTestContext(allocator, 80, 24);
    defer ctx.deinit();

    const tab = try app.tab_manager.?.createTab("Replay");
    const mgr = try tab.createCodexManager();
    mgr.status = .thread_active;
    tab.agent_state.visible = true;
    app.mode = .agent;

    const log =
        \\{"timestamp":"2026-03-27T03:54:03.784Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1","model_context_window":258400,"collaboration_mode_kind":"plan"}}
        \\{"timestamp":"2026-03-27T03:54:03.789Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Design split panes for the agent panel."}]}}
        \\{"timestamp":"2026-03-27T03:54:09.550Z","type":"event_msg","payload":{"type":"agent_message","message":"I’m expanding this into a handoff-grade spec now.","phase":"commentary","memory_citation":null}}
        \\{"timestamp":"2026-03-27T03:55:11.957Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"thread-1","turn_id":"turn-1","item":{"type":"Plan","id":"turn-1-plan","text":"<proposed_plan>\n# Split Panes\n\n## Summary\nAdd vertical panes inside the agent panel.\n\n## Key Changes\n- Keep tabs as workspaces.\n- Route input through the focused pane.\n</proposed_plan>"}}}
        \\{"timestamp":"2026-03-27T03:55:11.988Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","last_agent_message":"I’m expanding this into a handoff-grade spec now."}}
    ;

    const lines = try codex_replay.loadReplayLinesFromString(allocator, log);
    tab.agent_state.startDebugReplay(.codex, lines, .{ .codex = .thread_active }, false, false);

    try std.testing.expect(try app.stepActiveDebugReplay());
    try std.testing.expect(try app.stepActiveDebugReplay());
    try std.testing.expect(try app.stepActiveDebugReplay());

    try approval_root.renderAgentPanel(&app, ctx.window());

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "codex_replay_in_progress_panel", text);
}

test "snapshot: codex_replay_apply_patch_diff_panel" {
    const allocator = std.testing.allocator;

    var app = try initRenderTestApp(allocator);
    defer deinitRenderTestApp(&app);

    var ctx = try harness.createTestContext(allocator, 100, 24);
    defer ctx.deinit();

    const tab = try app.tab_manager.?.createTab("Replay");
    const mgr = try tab.createCodexManager();
    mgr.status = .thread_active;
    tab.agent_state.visible = true;
    app.mode = .agent;

    const log =
        \\{"timestamp":"2026-04-07T14:28:32.593Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Add a regression test for tab reallocation."}]}}
        \\{"timestamp":"2026-04-07T14:28:57.480Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"call-apply-patch-1","name":"apply_patch","input":"*** Begin Patch\n*** Update File: src/modes/agent_mode.zig\n@@\n test \"old test\" {\n-    try std.testing.expect(true);\n+    try std.testing.expect(false);\n }\n*** End Patch\n"}}
        \\{"timestamp":"2026-04-07T14:28:57.541Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-apply-patch-1","output":"{\"output\":\"Success. Updated the following files:\\nM src/modes/agent_mode.zig\\n\"}"}}
        \\{"timestamp":"2026-04-07T14:29:07.781Z","type":"event_msg","payload":{"type":"agent_message","message":"The realloc-path tests are in.","phase":"commentary","memory_citation":null}}
    ;

    const summary = try codex_replay.replaySessionFromString(allocator, &tab.agent_state, log);
    mgr.status = summary.manager_status;

    try approval_root.renderAgentPanel(&app, ctx.window());

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "src/modes/agent_mode.zig") != null);
    try snapshot.expectSnapshot(allocator, "codex_replay_apply_patch_diff_panel", text);
}

test "snapshot: codex_replay_user_input_panel" {
    const allocator = std.testing.allocator;

    var app = try initRenderTestApp(allocator);
    defer deinitRenderTestApp(&app);

    var ctx = try harness.createTestContext(allocator, 120, 18);
    defer ctx.deinit();

    const tab = try app.tab_manager.?.createTab("Replay");
    const mgr = try tab.createCodexManager();
    mgr.status = .thread_active;
    tab.agent_state.visible = true;
    app.mode = .agent;

    const log =
        \\{"timestamp":"2026-03-28T14:43:35.617Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        \\{"timestamp":"2026-03-28T14:43:35.618Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Pick the pane model for v1."}]}}
        \\{"timestamp":"2026-03-28T14:43:47.709Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{\"questions\":[{\"header\":\"Pane Model\",\"id\":\"pane_model\",\"question\":\"V1 split model?\",\"options\":[{\"label\":\"Independent\"},{\"label\":\"Shared\"}],\"isOther\":true}]}","call_id":"call-request-1"}}
    ;

    const lines = try codex_replay.loadReplayLinesFromString(allocator, log);
    tab.agent_state.startDebugReplay(.codex, lines, .{ .codex = .thread_active }, false, false);

    try std.testing.expect(try app.stepActiveDebugReplay());
    try std.testing.expect(try app.stepActiveDebugReplay());
    try std.testing.expect(try app.stepActiveDebugReplay());

    try approval_root.renderAgentPanel(&app, ctx.window());

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "codex_replay_user_input_panel", text);
}

test "debug replay previews codex question answer before clearing prompt" {
    const allocator = std.testing.allocator;

    var app = try initRenderTestApp(allocator);
    defer deinitRenderTestApp(&app);

    const tab = try app.tab_manager.?.createTab("Replay");
    const mgr = try tab.createCodexManager();
    mgr.status = .thread_active;
    tab.agent_state.visible = true;
    app.mode = .agent;

    const log =
        \\{"timestamp":"2026-03-28T14:43:35.617Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        \\{"timestamp":"2026-03-28T14:43:35.618Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Pick the pane model for v1."}]}}
        \\{"timestamp":"2026-03-28T14:43:47.709Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{\"questions\":[{\"header\":\"Pane Model\",\"id\":\"pane_model\",\"question\":\"V1 split model?\",\"options\":[{\"label\":\"Independent\"},{\"label\":\"Shared\"}],\"isOther\":true}]}","call_id":"call-request-1"}}
        \\{"timestamp":"2026-03-28T14:44:13.322Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-request-1","output":"{\"answers\":{\"pane_model\":{\"answers\":[\"Shared\"]}}}"}}
    ;

    const lines = try codex_replay.loadReplayLinesFromString(allocator, log);
    tab.agent_state.startDebugReplay(.codex, lines, .{ .codex = .thread_active }, false, false);

    try std.testing.expect(try app.stepActiveDebugReplay());
    try std.testing.expect(try app.stepActiveDebugReplay());
    try std.testing.expect(try app.stepActiveDebugReplay());

    try std.testing.expect(approval_root.agent_state.debug_replay_question_prompt_linger_ms >= 1200);

    const replay_prompt = tab.agent_state.getDebugReplayConst() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @as(?i64, approval_root.agent_state.debug_replay_question_prompt_linger_ms),
        replay_prompt.step_delay_override_ms,
    );

    const replay_before = tab.agent_state.getDebugReplayConst() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), replay_before.current_index);

    try std.testing.expect(try app.stepActiveDebugReplay());

    try std.testing.expect(approval_root.agent_state.debug_replay_question_answer_preview_linger_ms >= 1500);

    const replay_preview = tab.agent_state.getDebugReplayConst() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), replay_preview.current_index);
    try std.testing.expectEqual(
        @as(?i64, approval_root.agent_state.debug_replay_question_answer_preview_linger_ms),
        replay_preview.step_delay_override_ms,
    );

    const pending = tab.agent_state.getPendingQuestion() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), pending.states[0].cursor_index);
    try std.testing.expect(!pending.states[0].selected[0]);
    try std.testing.expect(pending.states[0].selected[1]);

    try std.testing.expect(try app.stepActiveDebugReplay());
    try std.testing.expect(tab.agent_state.getPendingQuestion() == null);
}

test "snapshot: codex_replay_user_input_selected_panel" {
    const allocator = std.testing.allocator;

    var app = try initRenderTestApp(allocator);
    defer deinitRenderTestApp(&app);

    var ctx = try harness.createTestContext(allocator, 120, 18);
    defer ctx.deinit();

    const tab = try app.tab_manager.?.createTab("Replay");
    const mgr = try tab.createCodexManager();
    mgr.status = .thread_active;
    tab.agent_state.visible = true;
    app.mode = .agent;

    const log =
        \\{"timestamp":"2026-03-28T14:43:35.617Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        \\{"timestamp":"2026-03-28T14:43:35.618Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Pick the pane model for v1."}]}}
        \\{"timestamp":"2026-03-28T14:43:47.709Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{\"questions\":[{\"header\":\"Pane Model\",\"id\":\"pane_model\",\"question\":\"V1 split model?\",\"options\":[{\"label\":\"Independent\"},{\"label\":\"Shared\"}],\"isOther\":true}]}","call_id":"call-request-1"}}
        \\{"timestamp":"2026-03-28T14:44:13.322Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-request-1","output":"{\"answers\":{\"pane_model\":{\"answers\":[\"Shared\"]}}}"}}
    ;

    const lines = try codex_replay.loadReplayLinesFromString(allocator, log);
    tab.agent_state.startDebugReplay(.codex, lines, .{ .codex = .thread_active }, false, false);

    try std.testing.expect(try app.stepActiveDebugReplay());
    try std.testing.expect(try app.stepActiveDebugReplay());
    try std.testing.expect(try app.stepActiveDebugReplay());
    try std.testing.expect(try app.stepActiveDebugReplay());

    try approval_root.renderAgentPanel(&app, ctx.window());

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "codex_replay_user_input_selected_panel", text);
}

test "snapshot: acp_replay_in_progress_panel" {
    const allocator = std.testing.allocator;

    var app = try initRenderTestApp(allocator);
    defer deinitRenderTestApp(&app);

    var ctx = try harness.createTestContext(allocator, 80, 24);
    defer ctx.deinit();

    const tab = try app.tab_manager.?.createTab("Replay");
    const mgr = try tab.createAcpManager();
    mgr.status = .session_active;
    tab.agent_state.visible = true;
    app.mode = .agent;

    const log =
        \\{"type":"user","message":{"role":"user","content":"Design ACP replay next."}}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I’m reading the real Claude session format first."}]}}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Replay can work at transcript granularity even without a native ACP event log."}]}}
    ;

    const lines = try acp_replay.loadReplayLinesFromString(allocator, log);
    tab.agent_state.startDebugReplay(.acp, lines, .{ .acp = .session_active }, false, false);

    try std.testing.expect(try app.stepActiveDebugReplay());
    try std.testing.expect(try app.stepActiveDebugReplay());

    try approval_root.renderAgentPanel(&app, ctx.window());

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "acp_replay_in_progress_panel", text);
}

test "snapshot: opencode_replay_in_progress_panel" {
    const allocator = std.testing.allocator;

    var app = try initRenderTestApp(allocator);
    defer deinitRenderTestApp(&app);

    var ctx = try harness.createTestContext(allocator, 80, 24);
    defer ctx.deinit();

    const tab = try app.tab_manager.?.createTab("Replay");
    const mgr = try tab.createOpencodeManager();
    mgr.status = .session_active;
    tab.agent_state.visible = true;
    app.mode = .agent;

    const log =
        \\[12:00:00.000] {"type":"session.status","properties":{"sessionID":"ses_demo","status":"busy"}}
        \\[12:00:00.010] {"payload":{"type":"message.part.updated","properties":{"part":{"sessionID":"ses_demo","type":"tool","callID":"call_1","tool":"bash","state":{"status":"pending","input":{"command":"rg debug replay src"}}}}}}
        \\[12:00:00.020] {"payload":{"type":"message.part.updated","properties":{"part":{"sessionID":"ses_demo","type":"tool","callID":"call_1","tool":"bash","state":{"status":"running","input":{"command":"rg debug replay src"}}}}}}
        \\[12:00:00.030] {"payload":{"type":"message.part.updated","properties":{"sessionID":"ses_demo","delta":"Tracing the replay state through the app now."}}}
    ;

    const lines = try opencode_replay.loadReplayLinesFromString(allocator, log);
    tab.agent_state.startDebugReplay(.opencode, lines, .{ .opencode = .session_active }, false, false);

    try std.testing.expect(try app.stepActiveDebugReplay());
    try std.testing.expect(try app.stepActiveDebugReplay());
    try std.testing.expect(try app.stepActiveDebugReplay());
    try std.testing.expect(try app.stepActiveDebugReplay());

    try approval_root.renderAgentPanel(&app, ctx.window());

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "opencode_replay_in_progress_panel", text);
}

fn initRenderTestApp(allocator: std.mem.Allocator) !approval_root.App {
    const frame_buffer = try allocator.alloc(u8, FRAME_TEXT_CAPACITY);
    var syntax_highlighter = try approval_root.SyntaxHighlighter.init(allocator);
    errdefer syntax_highlighter.deinit();

    return .{
        .allocator = allocator,
        .vx = null,
        .tty = null,
        .mode = .agent,
        .state = undefined,
        .should_quit = false,
        .should_suspend_for_editor = false,
        .editor_file_path = null,
        .editor_line_number = null,
        .editor_is_prompt_edit = false,
        .last_ctrl_c = 0,
        .header_line_buffers = undefined,
        .frame_text_buffer = frame_buffer,
        .frame_text_used = 0,
        .frame_segment_arena = undefined,
        .syntax_highlighter = syntax_highlighter,
        .highlight_worker = null,
        .pending_highlight_jobs = undefined,
        .needs_render = false,
        .needs_async_highlight = false,
        .tui_server = null,
        .session_manager = null,
        .blame_cache = undefined,
        .pending_blame_results = .{},
        .pending_blame_mutex = .{},
        .pending_blame_ready = std.atomic.Value(bool).init(false),
        .blame_requests_in_flight = .{},
        .pending_connection = null,
        .pending_agent_connect_idx = null,
        .pending_subagent_fetch = .{},
        .in_bracketed_paste = false,
        .agent_only = false,
        .tab_manager = approval_root.TabManager.init(allocator, .right),
        .profile_render = false,
        .profile_every_n = 0,
        .profile_frame_counter = 0,
        .profile_active_frame = false,
        .profile_counters = .{},
    };
}

fn deinitRenderTestApp(app: *approval_root.App) void {
    if (app.tab_manager) |*tm| tm.deinit();
    app.syntax_highlighter.deinit();
    app.allocator.free(app.frame_text_buffer);
}
