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
