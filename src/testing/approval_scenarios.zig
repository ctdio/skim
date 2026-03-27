const std = @import("std");
const harness = @import("harness.zig");
const snapshot = @import("snapshot.zig");
const approval_root = @import("approval_test_root");

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

    var app = initRenderTestApp(allocator);
    defer if (app.tab_manager) |*tm| tm.deinit();

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

    var app = initRenderTestApp(allocator);
    defer if (app.tab_manager) |*tm| tm.deinit();

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

fn initRenderTestApp(allocator: std.mem.Allocator) approval_root.App {
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
        .frame_text_buffer = &.{},
        .frame_text_used = 0,
        .frame_segment_arena = undefined,
        .syntax_highlighter = undefined,
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
