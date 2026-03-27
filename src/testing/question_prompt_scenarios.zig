const std = @import("std");
const harness = @import("harness.zig");
const snapshot = @import("snapshot.zig");
const question_prompt = @import("question_prompt_root");

test "snapshot: agent_question_prompt" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 16);
    defer ctx.deinit();

    var state = question_prompt.AgentState.init(allocator, .left);
    defer state.deinit();

    const opts1 = try allocator.alloc(question_prompt.QuestionOptionData, 3);
    opts1[0] = .{ .label = "API usage", .description = "Request/response examples or client usage" };
    opts1[1] = .{ .label = "UI copy", .description = "Interface text or prompts" };
    opts1[2] = .{ .label = "Code snippets", .description = "Functions, patterns, or small modules" };

    const opts2 = try allocator.alloc(question_prompt.QuestionOptionData, 3);
    opts2[0] = .{ .label = "Beginner", .description = "New to the topic" };
    opts2[1] = .{ .label = "Intermediate", .description = "Some experience" };
    opts2[2] = .{ .label = "Advanced", .description = "Expert-level detail" };

    const questions = try allocator.alloc(question_prompt.QuestionData, 2);
    questions[0] = .{
        .header = "Topic",
        .question = "What kind of examples do you need?",
        .options = opts1,
        .multiple = false,
    };
    questions[1] = .{
        .header = "Audience",
        .question = "Who is the target audience for the examples?",
        .options = opts2,
        .multiple = false,
    };

    try state.setPendingQuestion(.{ .questions = questions });

    allocator.free(opts1);
    allocator.free(opts2);
    allocator.free(questions);

    if (state.getPendingQuestion()) |pending| {
        pending.active_index = 0;
        pending.states[0].cursor_index = 1;
        pending.states[0].selected[1] = true;
    }

    const win = ctx.window();
    try question_prompt.renderInlineQuestionPrompt(allocator, win, state.getPendingQuestion().?);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "agent_question_prompt", text);
}

test "snapshot: agent_question_prompt_with_custom_option" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 16);
    defer ctx.deinit();

    var state = question_prompt.AgentState.init(allocator, .left);
    defer state.deinit();

    const opts = try allocator.alloc(question_prompt.QuestionOptionData, 1);
    opts[0] = .{ .label = "Minimal patch", .description = "Keep the fix narrow" };

    const questions = try allocator.alloc(question_prompt.QuestionData, 1);
    questions[0] = .{
        .header = "Scope",
        .question = "How broad should the fix be?",
        .options = opts,
        .multiple = false,
        .allow_custom = true,
    };

    try state.setPendingQuestion(.{ .questions = questions });

    allocator.free(opts);
    allocator.free(questions);

    const win = ctx.window();
    try question_prompt.renderInlineQuestionPrompt(allocator, win, state.getPendingQuestion().?);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "agent_question_prompt_with_custom_option", text);
}
