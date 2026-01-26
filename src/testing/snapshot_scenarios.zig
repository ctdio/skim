const std = @import("std");
const harness = @import("harness.zig");
const snapshot = @import("snapshot.zig");
const diff_helpers = @import("diff_test_helpers.zig");
const agent_helpers = @import("agent_test_helpers.zig");
const md_helpers = @import("markdown_test_helpers.zig");

// =============================================================================
// Diff Rendering Snapshot Tests
// =============================================================================

test "snapshot: diff_file_header" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    diff_helpers.renderFileHeaderAlloc(win, "src/main.zig", 12, 5, 0, false, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "diff_file_header", text);
}

test "snapshot: diff_file_header_with_cursor" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    diff_helpers.renderFileHeaderAlloc(win, "src/main.zig", 12, 5, 0, true, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "diff_file_header_cursor", text);
}

test "snapshot: diff_file_header_long_path" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 80, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    diff_helpers.renderFileHeaderAlloc(win, "src/components/rendering/unified_view.zig", 156, 42, 0, false, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "diff_file_header_long_path", text);
}

test "snapshot: diff_hunk_header" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    const hunk = diff_helpers.Hunk{
        .header = .{
            .old_start = 10,
            .old_count = 7,
            .new_start = 10,
            .new_count = 9,
            .context = "fn render()",
        },
        .lines = &[_]diff_helpers.Line{},
        .highlights = null,
        .old_highlights = null,
    };
    diff_helpers.renderHunkHeaderAlloc(win, hunk, 0, false, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "diff_hunk_header", text);
}

test "snapshot: diff_hunk_header_with_cursor" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    const hunk = diff_helpers.Hunk{
        .header = .{
            .old_start = 1,
            .old_count = 3,
            .new_start = 1,
            .new_count = 5,
            .context = "",
        },
        .lines = &[_]diff_helpers.Line{},
        .highlights = null,
        .old_highlights = null,
    };
    diff_helpers.renderHunkHeaderAlloc(win, hunk, 0, true, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "diff_hunk_header_cursor", text);
}

test "snapshot: diff_line_add" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    const line = diff_helpers.createLine(.add, "    const new_value = 42;", null, 15);
    diff_helpers.renderDiffLineAlloc(win, line, 0, 5, false, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "diff_line_add", text);
}

test "snapshot: diff_line_delete" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    const line = diff_helpers.createLine(.delete, "    const old_value = 0;", 14, null);
    diff_helpers.renderDiffLineAlloc(win, line, 0, 5, false, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "diff_line_delete", text);
}

test "snapshot: diff_line_context" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    const line = diff_helpers.createLine(.context, "fn main() void {", 10, 10);
    diff_helpers.renderDiffLineAlloc(win, line, 0, 5, false, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "diff_line_context", text);
}

test "snapshot: diff_line_with_cursor" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    const line = diff_helpers.createLine(.add, "    return result;", null, 25);
    diff_helpers.renderDiffLineAlloc(win, line, 0, 5, true, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "diff_line_cursor", text);
}

test "snapshot: diff_large_line_numbers" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    const line = diff_helpers.createLine(.context, "// Line 1234", 1234, 1234);
    diff_helpers.renderDiffLineAlloc(win, line, 0, 6, false, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "diff_large_line_numbers", text);
}

test "snapshot: diff_mixed_changes" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 70, 8);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    const gutter_width: usize = 5;

    // Render a sequence of mixed changes
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.context, "fn process(data: []const u8) void {", 10, 10), 0, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.delete, "    const result = old_function(data);", 11, null), 1, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.delete, "    log.debug(\"old\");", 12, null), 2, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.add, "    const result = new_function(data);", null, 11), 3, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.add, "    log.info(\"new\");", null, 12), 4, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.add, "    metrics.increment();", null, 13), 5, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.context, "    return result;", 13, 14), 6, gutter_width, false, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "diff_mixed_changes", text);
}

test "snapshot: diff_full_hunk" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 70, 10);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    const gutter_width: usize = 5;

    // Render hunk header
    const hunk = diff_helpers.Hunk{
        .header = .{
            .old_start = 15,
            .old_count = 4,
            .new_start = 15,
            .new_count = 6,
            .context = "pub fn calculate()",
        },
        .lines = &[_]diff_helpers.Line{},
        .highlights = null,
        .old_highlights = null,
    };
    diff_helpers.renderHunkHeaderAlloc(win, hunk, 0, false, frame);

    // Render diff lines
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.context, "    var total: i32 = 0;", 15, 15), 1, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.delete, "    total += item.value;", 16, null), 2, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.add, "    total += item.value * multiplier;", null, 16), 3, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.add, "    if (total > MAX) total = MAX;", null, 17), 4, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.context, "    return total;", 17, 18), 5, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.context, "}", 18, 19), 6, gutter_width, false, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "diff_full_hunk", text);
}

test "snapshot: diff_multi_file" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 70, 15);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    const gutter_width: usize = 4;

    // First file
    diff_helpers.renderFileHeaderAlloc(win, "src/main.zig", 3, 1, 0, false, frame);
    diff_helpers.renderHunkHeaderAlloc(win, diff_helpers.Hunk{
        .header = .{ .old_start = 1, .old_count = 2, .new_start = 1, .new_count = 3, .context = "" },
        .lines = &[_]diff_helpers.Line{},
        .highlights = null,
        .old_highlights = null,
    }, 1, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.context, "const std = @import(\"std\");", 1, 1), 2, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.add, "const log = std.log;", null, 2), 3, gutter_width, false, frame);

    // Spacer row (blank line between files)
    // Row 4 is blank

    // Second file
    diff_helpers.renderFileHeaderAlloc(win, "src/utils.zig", 5, 2, 5, false, frame);
    diff_helpers.renderHunkHeaderAlloc(win, diff_helpers.Hunk{
        .header = .{ .old_start = 10, .old_count = 3, .new_start = 10, .new_count = 5, .context = "fn helper()" },
        .lines = &[_]diff_helpers.Line{},
        .highlights = null,
        .old_highlights = null,
    }, 6, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.delete, "    return null;", 10, null), 7, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.add, "    if (x == 0) return null;", null, 10), 8, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.add, "    return x * 2;", null, 11), 9, gutter_width, false, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "diff_multi_file", text);
}

// =============================================================================
// Agent Rendering Snapshot Tests
// =============================================================================

test "snapshot: agent_user_message" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    agent_helpers.renderUserMessage(win, "Can you help me fix this bug?", 0);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "agent_user_message", text);
}

test "snapshot: agent_response" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    agent_helpers.renderAgentMessage(win, "I'll analyze the code and find the issue.", 0);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "agent_response", text);
}

test "snapshot: agent_tool_pending" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    _ = agent_helpers.renderToolCallAlloc(win, "Read", "src/main.zig", .pending, null, 0, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "agent_tool_pending", text);
}

test "snapshot: agent_tool_running" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    _ = agent_helpers.renderToolCallAlloc(win, "Bash", "zig build test", .running, null, 0, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "agent_tool_running", text);
}

test "snapshot: agent_tool_completed" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 5);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    _ = agent_helpers.renderToolCallAlloc(win, "Bash", "echo hello", .completed, "hello", 0, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "agent_tool_completed", text);
}

test "snapshot: agent_tool_failed" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 5);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    _ = agent_helpers.renderToolCallAlloc(win, "Bash", "invalid_command", .failed, "command not found", 0, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "agent_tool_failed", text);
}

test "snapshot: agent_plan_entry_pending" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const entry = agent_helpers.createPlanEntry(.medium, .pending, "Implement user authentication");
    agent_helpers.renderPlanEntry(win, entry, 0);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "agent_plan_entry_pending", text);
}

test "snapshot: agent_plan_entry_in_progress" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const entry = agent_helpers.createPlanEntry(.high, .in_progress, "Writing unit tests");
    agent_helpers.renderPlanEntry(win, entry, 0);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "agent_plan_entry_in_progress", text);
}

test "snapshot: agent_plan_entry_completed" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const entry = agent_helpers.createPlanEntry(.low, .completed, "Update documentation");
    agent_helpers.renderPlanEntry(win, entry, 0);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "agent_plan_entry_completed", text);
}

test "snapshot: agent_plan_multiple_entries" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 6);
    defer ctx.deinit();

    const win = ctx.window();

    agent_helpers.renderPlanEntry(win, agent_helpers.createPlanEntry(.high, .completed, "Set up project structure"), 0);
    agent_helpers.renderPlanEntry(win, agent_helpers.createPlanEntry(.high, .completed, "Implement core logic"), 1);
    agent_helpers.renderPlanEntry(win, agent_helpers.createPlanEntry(.medium, .in_progress, "Add error handling"), 2);
    agent_helpers.renderPlanEntry(win, agent_helpers.createPlanEntry(.medium, .pending, "Write tests"), 3);
    agent_helpers.renderPlanEntry(win, agent_helpers.createPlanEntry(.low, .pending, "Update README"), 4);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "agent_plan_multiple_entries", text);
}

test "snapshot: agent_conversation" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 70, 12);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    var row: usize = 0;

    // User asks a question
    agent_helpers.renderUserMessage(win, "How do I fix the null pointer error?", row);
    row += 1;

    // Blank line
    row += 1;

    // Agent responds
    agent_helpers.renderAgentMessage(win, "Let me check the code.", row);
    row += 1;

    // Blank line
    row += 1;

    // Tool call
    row = agent_helpers.renderToolCallAlloc(win, "Read", "src/parser.zig", .completed, "// parser implementation", row, frame);

    // Blank line
    row += 1;

    // Agent follow-up
    agent_helpers.renderAgentMessage(win, "Found it! The issue is on line 42.", row);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "agent_conversation", text);
}

test "snapshot: agent_tool_no_command" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    _ = agent_helpers.renderToolCallAlloc(win, "WebSearch", null, .completed, "Found 5 results", 0, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "agent_tool_no_command", text);
}

// =============================================================================
// Edge Cases
// =============================================================================

test "snapshot: diff_empty_line_add" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    const line = diff_helpers.createLine(.add, "", null, 20);
    diff_helpers.renderDiffLineAlloc(win, line, 0, 5, false, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "diff_empty_line_add", text);
}

test "snapshot: diff_empty_line_delete" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    const line = diff_helpers.createLine(.delete, "", 15, null);
    diff_helpers.renderDiffLineAlloc(win, line, 0, 5, false, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "diff_empty_line_delete", text);
}

test "snapshot: agent_empty_message" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    agent_helpers.renderUserMessage(win, "", 0);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "agent_empty_message", text);
}

test "snapshot: agent_long_message" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 3);
    defer ctx.deinit();

    const win = ctx.window();
    agent_helpers.renderAgentMessage(win, "This is a very long message that might need to be truncated or wrapped depending on the terminal width.", 0);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "agent_long_message", text);
}

test "snapshot: diff_special_characters" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    const line = diff_helpers.createLine(.add, "    const msg = \"Hello, 世界!\";", null, 5);
    diff_helpers.renderDiffLineAlloc(win, line, 0, 5, false, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "diff_special_characters", text);
}

test "snapshot: diff_long_line" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 80, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    const line = diff_helpers.createLine(.add, "    const very_long_variable_name = some_function_with_a_very_long_name(arg1, arg2, arg3, arg4);", null, 100);
    diff_helpers.renderDiffLineAlloc(win, line, 0, 5, false, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "diff_long_line", text);
}

// =============================================================================
// Complex Scenarios
// =============================================================================

test "snapshot: agent_multi_tool_sequence" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 70, 15);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    var row: usize = 0;

    // User request
    agent_helpers.renderUserMessage(win, "Find and fix the bug in the parser", row);
    row += 2;

    // Agent thinking
    agent_helpers.renderAgentMessage(win, "Let me search for the parser file.", row);
    row += 2;

    // First tool - search
    row = agent_helpers.renderToolCallAlloc(win, "Glob", "src/**/*parser*.zig", .completed, "src/parser.zig", row, frame);
    row += 1;

    // Second tool - read
    row = agent_helpers.renderToolCallAlloc(win, "Read", "src/parser.zig", .completed, "fn parse() { ... }", row, frame);
    row += 1;

    // Third tool - edit
    row = agent_helpers.renderToolCallAlloc(win, "Edit", "src/parser.zig:42", .completed, "Fixed null check", row, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "agent_multi_tool_sequence", text);
}

test "snapshot: diff_rename_file" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 70, 8);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    const gutter_width: usize = 4;

    // File header showing rename
    diff_helpers.renderFileHeaderAlloc(win, "src/old_name.zig -> src/new_name.zig", 2, 1, 0, false, frame);
    diff_helpers.renderHunkHeaderAlloc(win, diff_helpers.Hunk{
        .header = .{ .old_start = 1, .old_count = 3, .new_start = 1, .new_count = 4, .context = "module header" },
        .lines = &[_]diff_helpers.Line{},
        .highlights = null,
        .old_highlights = null,
    }, 1, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.context, "//! Old module description", 1, 1), 2, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.delete, "const OldName = @This();", 2, null), 3, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.add, "const NewName = @This();", null, 2), 4, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.add, "pub const VERSION = \"2.0.0\";", null, 3), 5, gutter_width, false, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "diff_rename_file", text);
}

// =============================================================================
// Markdown Rendering Snapshot Tests
// =============================================================================

test "snapshot: md_header_h1" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 3);
    defer ctx.deinit();

    const win = ctx.window();
    md_helpers.renderHeader(win, "Main Title", 1, 0);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_header_h1", text);
}

test "snapshot: md_header_h2" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 3);
    defer ctx.deinit();

    const win = ctx.window();
    md_helpers.renderHeader(win, "Section Header", 2, 0);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_header_h2", text);
}

test "snapshot: md_header_h3" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 3);
    defer ctx.deinit();

    const win = ctx.window();
    md_helpers.renderHeader(win, "Subsection", 3, 0);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_header_h3", text);
}

test "snapshot: md_all_headers" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 8);
    defer ctx.deinit();

    const win = ctx.window();
    md_helpers.renderHeader(win, "H1 Title", 1, 0);
    md_helpers.renderHeader(win, "H2 Section", 2, 1);
    md_helpers.renderHeader(win, "H3 Subsection", 3, 2);
    md_helpers.renderHeader(win, "H4 Detail", 4, 3);
    md_helpers.renderHeader(win, "H5 Minor", 5, 4);
    md_helpers.renderHeader(win, "H6 Smallest", 6, 5);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_all_headers", text);
}

test "snapshot: md_bold_text" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 3);
    defer ctx.deinit();

    const win = ctx.window();
    var col: usize = 0;
    col = md_helpers.renderText(win, "This is ", 0, col);
    col = md_helpers.renderBold(win, "bold", 0, col);
    _ = md_helpers.renderText(win, " text", 0, col);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_bold_text", text);
}

test "snapshot: md_italic_text" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 3);
    defer ctx.deinit();

    const win = ctx.window();
    var col: usize = 0;
    col = md_helpers.renderText(win, "This is ", 0, col);
    col = md_helpers.renderItalic(win, "italic", 0, col);
    _ = md_helpers.renderText(win, " text", 0, col);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_italic_text", text);
}

test "snapshot: md_strikethrough_text" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 3);
    defer ctx.deinit();

    const win = ctx.window();
    var col: usize = 0;
    col = md_helpers.renderText(win, "This is ", 0, col);
    col = md_helpers.renderStrikethrough(win, "deleted", 0, col);
    _ = md_helpers.renderText(win, " text", 0, col);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_strikethrough_text", text);
}

test "snapshot: md_inline_code" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 3);
    defer ctx.deinit();

    const win = ctx.window();
    var col: usize = 0;
    col = md_helpers.renderText(win, "Use ", 0, col);
    col = md_helpers.renderInlineCode(win, "const x = 42", 0, col);
    _ = md_helpers.renderText(win, " here", 0, col);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_inline_code", text);
}

test "snapshot: md_link" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 3);
    defer ctx.deinit();

    const win = ctx.window();
    var col: usize = 0;
    col = md_helpers.renderText(win, "Visit ", 0, col);
    col = md_helpers.renderLink(win, "my website", 0, col);
    _ = md_helpers.renderText(win, " for more", 0, col);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_link", text);
}

test "snapshot: md_unordered_list" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 5);
    defer ctx.deinit();

    const win = ctx.window();

    // Three bullet items
    var col = md_helpers.renderListBullet(win, 0, 0);
    _ = md_helpers.renderText(win, "First item", 0, col);

    col = md_helpers.renderListBullet(win, 1, 0);
    _ = md_helpers.renderText(win, "Second item", 1, col);

    col = md_helpers.renderListBullet(win, 2, 0);
    _ = md_helpers.renderText(win, "Third item", 2, col);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_unordered_list", text);
}

test "snapshot: md_ordered_list" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 5);
    defer ctx.deinit();

    const win = ctx.window();
    const frame_alloc = ctx.frameAllocator();

    // Three numbered items (use frame allocator so strings persist until capture)
    var col = try md_helpers.renderListNumber(frame_alloc, win, 1, 0, 0);
    _ = md_helpers.renderText(win, "First step", 0, col);

    col = try md_helpers.renderListNumber(frame_alloc, win, 2, 1, 0);
    _ = md_helpers.renderText(win, "Second step", 1, col);

    col = try md_helpers.renderListNumber(frame_alloc, win, 3, 2, 0);
    _ = md_helpers.renderText(win, "Third step", 2, col);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_ordered_list", text);
}

test "snapshot: md_nested_list" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 6);
    defer ctx.deinit();

    const win = ctx.window();

    // Parent item
    var col = md_helpers.renderListBullet(win, 0, 0);
    _ = md_helpers.renderText(win, "Parent item", 0, col);

    // Nested items (indent = 3)
    col = md_helpers.renderListBullet(win, 1, 3);
    _ = md_helpers.renderText(win, "Nested item 1", 1, col);

    col = md_helpers.renderListBullet(win, 2, 3);
    _ = md_helpers.renderText(win, "Nested item 2", 2, col);

    // Back to parent level
    col = md_helpers.renderListBullet(win, 3, 0);
    _ = md_helpers.renderText(win, "Another parent", 3, col);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_nested_list", text);
}

test "snapshot: md_task_list" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 5);
    defer ctx.deinit();

    const win = ctx.window();

    // Task list with checked and unchecked items
    var col = md_helpers.renderTaskChecked(win, 0, 0);
    _ = md_helpers.renderText(win, "Completed task", 0, col);

    col = md_helpers.renderTaskUnchecked(win, 1, 0);
    _ = md_helpers.renderText(win, "Pending task", 1, col);

    col = md_helpers.renderTaskChecked(win, 2, 0);
    _ = md_helpers.renderText(win, "Another done", 2, col);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_task_list", text);
}

test "snapshot: md_blockquote" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 4);
    defer ctx.deinit();

    const win = ctx.window();

    // Blockquote with multiple lines
    var col = md_helpers.renderBlockquoteBorder(win, 0, 0);
    _ = md_helpers.renderBlockquoteText(win, "This is a quote", 0, col);

    col = md_helpers.renderBlockquoteBorder(win, 1, 0);
    _ = md_helpers.renderBlockquoteText(win, "spanning multiple lines", 1, col);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_blockquote", text);
}

test "snapshot: md_horizontal_rule" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 40, 3);
    defer ctx.deinit();

    const win = ctx.window();
    md_helpers.renderHorizontalRule(win, 0, 32);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_horizontal_rule", text);
}

test "snapshot: md_simple_table" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 8);
    defer ctx.deinit();

    const win = ctx.window();
    // Use frame allocator so strings persist until ctx.deinit()
    const frame_alloc = ctx.frameAllocator();

    // Use full markdown rendering pipeline
    const table_md =
        \\| Name | Value |
        \\|:-----|:------|
        \\| foo  | 42    |
        \\| bar  | 99    |
    ;

    try md_helpers.renderMarkdown(frame_alloc, win, table_md, 50);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_simple_table", text);
}

test "snapshot: md_wide_table_truncated" {
    const allocator = std.testing.allocator;
    // Use 80 width terminal, but table has many columns
    var ctx = try harness.createTestContext(allocator, 80, 12);
    defer ctx.deinit();

    const win = ctx.window();
    const frame_alloc = ctx.frameAllocator();

    // Table with many columns that must be truncated
    const wide_table_md =
        \\| Category | Feature | Status | Priority | Owner | Notes |
        \\|:---------|:--------|:-------|:---------|:------|:------|
        \\| Core | Event Loop | Completed | P0 | @alice | Uses io_uring |
        \\| Rendering | Virtual Scroll | In Progress | P1 | @bob | Renders visible only |
        \\| Git | Blame View | Planned | P2 | TBD | Shows commit info |
    ;

    try md_helpers.renderMarkdown(frame_alloc, win, wide_table_md, 80);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_wide_table_truncated", text);
}

test "snapshot: md_table_narrow_terminal" {
    const allocator = std.testing.allocator;
    // Very narrow terminal - 40 chars
    var ctx = try harness.createTestContext(allocator, 40, 10);
    defer ctx.deinit();

    const win = ctx.window();
    const frame_alloc = ctx.frameAllocator();

    const table_md =
        \\| Column A | Column B | Column C |
        \\|:---------|:---------|:---------|
        \\| Long content here | More text | Extra |
        \\| Another row | Data | Values |
    ;

    try md_helpers.renderMarkdown(frame_alloc, win, table_md, 40);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_table_narrow_terminal", text);
}

test "snapshot: md_code_block" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 6);
    defer ctx.deinit();

    const win = ctx.window();

    // Code block with language label
    var col: usize = 0;
    col = md_helpers.renderCodeBlockBorder(win, "```", 0, col);
    _ = md_helpers.renderCodeBlockLang(win, "zig", 0, col);

    // Code content (rendered as regular text with code styling)
    _ = md_helpers.renderInlineCode(win, "const x = 42;", 1, 0);
    _ = md_helpers.renderInlineCode(win, "return x * 2;", 2, 0);

    // Closing fence
    _ = md_helpers.renderCodeBlockBorder(win, "```", 3, 0);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_code_block", text);
}

test "snapshot: md_mixed_emphasis" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    var col: usize = 0;
    col = md_helpers.renderText(win, "Normal ", 0, col);
    col = md_helpers.renderBold(win, "bold", 0, col);
    col = md_helpers.renderText(win, " and ", 0, col);
    col = md_helpers.renderItalic(win, "italic", 0, col);
    col = md_helpers.renderText(win, " and ", 0, col);
    col = md_helpers.renderInlineCode(win, "code", 0, col);
    _ = md_helpers.renderText(win, " here", 0, col);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_mixed_emphasis", text);
}

test "snapshot: md_paragraph_with_link" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    var col: usize = 0;
    col = md_helpers.renderText(win, "Check out the ", 0, col);
    col = md_helpers.renderLink(win, "documentation", 0, col);
    col = md_helpers.renderText(win, " for details on ", 0, col);
    col = md_helpers.renderInlineCode(win, "setup()", 0, col);
    _ = md_helpers.renderText(win, ".", 0, col);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_paragraph_with_link", text);
}

test "snapshot: md_complex_document" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 15);
    defer ctx.deinit();

    const win = ctx.window();
    var row: usize = 0;

    // Header
    md_helpers.renderHeader(win, "Getting Started", 1, row);
    row += 2;

    // Paragraph with emphasis
    var col: usize = 0;
    col = md_helpers.renderText(win, "This guide covers ", row, col);
    col = md_helpers.renderBold(win, "essential", row, col);
    _ = md_helpers.renderText(win, " concepts.", row, col);
    row += 2;

    // Subheader
    md_helpers.renderHeader(win, "Prerequisites", 2, row);
    row += 1;

    // List
    col = md_helpers.renderListBullet(win, row, 0);
    _ = md_helpers.renderText(win, "Zig compiler", row, col);
    row += 1;

    col = md_helpers.renderListBullet(win, row, 0);
    _ = md_helpers.renderText(win, "Git installed", row, col);
    row += 2;

    // Blockquote
    col = md_helpers.renderBlockquoteBorder(win, row, 0);
    _ = md_helpers.renderBlockquoteText(win, "Note: Read the docs first!", row, col);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_complex_document", text);
}
