const std = @import("std");
const harness = @import("harness.zig");
const snapshot = @import("snapshot.zig");
const diff_helpers = @import("diff_test_helpers.zig");
const agent_helpers = @import("agent_test_helpers.zig");
const md_helpers = @import("markdown_test_helpers.zig");
const help_helpers = @import("help_test_helpers.zig");
const model_helpers = @import("model_selection_test_helpers.zig");
const palette_helpers = @import("command_palette_test_helpers.zig");

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
// Subagent Block Rendering Snapshot Tests
// =============================================================================

test "snapshot: subagent_block_completed" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 8);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    _ = agent_helpers.renderSubagentBlock(win, "Explore", "Explore architecture", 12, "Read", .completed, 0, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "subagent_block_completed", text);
}

test "snapshot: subagent_block_running" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 8);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    _ = agent_helpers.renderSubagentBlock(win, "Explore", "Explore architecture", 6, "Read", .running, 0, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "subagent_block_running", text);
}

test "snapshot: subagent_block_failed" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 8);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    _ = agent_helpers.renderSubagentBlock(win, "Explore", "Explore architecture", 3, "Bash", .failed, 0, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "subagent_block_failed", text);
}

test "snapshot: subagent_block_no_summary" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 7);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    _ = agent_helpers.renderSubagentBlock(win, "Explore", "Explore code", 0, null, .running, 0, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "subagent_block_no_summary", text);
}

test "snapshot: subagent_conversation_mixed" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 70, 16);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    var row: usize = 0;

    // Regular tool call
    row = agent_helpers.renderToolCallAlloc(win, "Read", "src/main.zig", .completed, "// main entry", row, frame);
    row += 1;

    // Subagent block
    row = agent_helpers.renderSubagentBlock(win, "Explore", "Explore architecture", 8, "Read", .completed, row, frame);
    row += 1;

    // Another regular tool call
    row = agent_helpers.renderToolCallAlloc(win, "Bash", "zig build", .completed, "Build OK", row, frame);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "subagent_conversation_mixed", text);
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

test "snapshot: md_table_many_columns" {
    const allocator = std.testing.allocator;
    // Wide terminal to test large table rendering with many columns
    var ctx = try harness.createTestContext(allocator, 160, 30);
    defer ctx.deinit();

    const win = ctx.window();
    const frame_alloc = ctx.frameAllocator();

    // Large table with 8 columns and longer content to stress-test border rendering
    const table_md =
        \\| Language | Year | Paradigm | Typing | Memory Management | Primary Use Case | Notable Feature | Creator |
        \\|:---------|:-----|:---------|:-------|:------------------|:-----------------|:----------------|:--------|
        \\| Zig | 2016 | Imperative | Static | Manual | Systems programming | Comptime metaprogramming | Andrew Kelley |
        \\| Rust | 2010 | Multi-paradigm | Static | Ownership/Borrowing | Systems programming | Borrow checker | Graydon Hoare |
        \\| Go | 2009 | Imperative | Static | Garbage collected | Cloud infrastructure | Goroutines and channels | Rob Pike |
        \\| Python | 1991 | Multi-paradigm | Dynamic | Garbage collected | General purpose scripting | Readable syntax | Guido van Rossum |
        \\| JavaScript | 1995 | Multi-paradigm | Dynamic | Garbage collected | Web development | Event loop model | Brendan Eich |
        \\| TypeScript | 2012 | Multi-paradigm | Static | Garbage collected | Large-scale web apps | Structural typing | Microsoft |
        \\| C | 1972 | Imperative | Static | Manual | Operating systems | Portability | Dennis Ritchie |
        \\| C++ | 1985 | Multi-paradigm | Static | Manual with RAII | Games and systems | Template metaprogramming | Bjarne Stroustrup |
    ;

    try md_helpers.renderMarkdown(frame_alloc, win, table_md, 160);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_table_many_columns", text);
}

test "snapshot: md_table_with_emoji" {
    const allocator = std.testing.allocator;
    // Test that emojis in table cells are properly aligned
    // Emoji display width (2 cells) differs from byte length (3+ bytes)
    var ctx = try harness.createTestContext(allocator, 60, 12);
    defer ctx.deinit();

    const win = ctx.window();
    const frame_alloc = ctx.frameAllocator();

    // Table with emojis - tests that column widths and padding use display width
    const table_md =
        \\| Metric        | Target | Status      |
        \\|:--------------|:-------|:------------|
        \\| Cold startup  | <10ms  | ✅          |
        \\| Binary size   | <2MB   | ✅ (209KB)  |
        \\| Memory usage  | <50MB  | ✅          |
        \\| Scrolling FPS | 60     | ✅          |
    ;

    try md_helpers.renderMarkdown(frame_alloc, win, table_md, 60);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_table_with_emoji", text);
}

test "snapshot: md_table_proportional_widths" {
    const allocator = std.testing.allocator;
    // Test proportional width allocation: short columns stay compact, long columns get more space
    // 70 char terminal forces some constraint but enough to show proportionality
    var ctx = try harness.createTestContext(allocator, 70, 12);
    defer ctx.deinit();

    const win = ctx.window();
    const frame_alloc = ctx.frameAllocator();

    // Table with drastically different column content lengths:
    // - Year: 4 chars (should stay compact)
    // - Event: medium length
    // - Description: long content (should get most space)
    const table_md =
        \\| Year | Event | Description |
        \\|:-----|:------|:------------|
        \\| 2020 | Alpha | Initial release with basic functionality |
        \\| 2021 | Beta | Added streaming support and bug fixes |
        \\| 2022 | GA | General availability with full feature set |
        \\| 2023 | v2.0 | Major rewrite with improved performance |
    ;

    try md_helpers.renderMarkdown(frame_alloc, win, table_md, 70);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "md_table_proportional_widths", text);
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

// =============================================================================
// Blame Rendering Snapshot Tests
// =============================================================================

const blame_helpers = @import("blame_test_helpers.zig");

test "snapshot: blame_first_line_basic" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 80, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();

    // Jan 15, 2024 = 1705276800, "now" is 3 months later
    const blame = blame_helpers.createBlameLine("a1b2c3d4", "John Doe", "johndoe", "Fix critical bug in parser", 1705276800);
    const now: i64 = 1705276800 + (90 * 86400); // 90 days later

    blame_helpers.renderBlameFirstLine(frame, win, blame, 0, 0, null, now);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "blame_first_line_basic", text);
}

test "snapshot: blame_first_line_with_username" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 80, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();

    // When username differs from author, username is shown
    const blame = blame_helpers.createBlameLine("deadbeef", "Alice Smith", "asmith", "Add new feature", 1700000000);
    const now: i64 = 1700000000 + (30 * 86400); // 30 days later

    blame_helpers.renderBlameFirstLine(frame, win, blame, 0, 0, null, now);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "blame_first_line_username", text);
}

test "snapshot: blame_first_line_long_author" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 80, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();

    // Long author name should be truncated to 12 chars
    const blame = blame_helpers.createBlameLine("12345678", "Christopher Alexander Johnson", "", "Refactor module", 1690000000);
    const now: i64 = 1690000000 + (365 * 86400); // 1 year later

    blame_helpers.renderBlameFirstLine(frame, win, blame, 0, 0, null, now);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "blame_first_line_long_author", text);
}

test "snapshot: blame_uncommitted" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 80, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();

    const blame = blame_helpers.createUncommittedBlameLine();

    blame_helpers.renderBlameFirstLine(frame, win, blame, 0, 0, null, 1700000000);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "blame_uncommitted", text);
}

test "snapshot: blame_second_line_message" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 80, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();

    const blame = blame_helpers.createBlameLine("abcd1234", "Bob Wilson", "bwilson", "Implement async file loading for better performance", 1705276800);

    blame_helpers.renderBlameSecondLine(frame, win, blame, 0, 0, null);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "blame_second_line_message", text);
}

test "snapshot: blame_empty_line" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 80, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();

    // Empty blame (3rd+ line of same commit)
    blame_helpers.renderBlameEmpty(frame, win, 0, 0, null);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "blame_empty_line", text);
}

test "snapshot: blame_with_add_line" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 100, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();

    const blame = blame_helpers.createBlameLine("f00dcafe", "Developer", "dev", "Add logging", 1705276800);
    const now: i64 = 1705276800 + (7 * 86400); // 1 week later

    blame_helpers.renderDiffLineWithBlame(
        frame,
        win,
        blame,
        .first_line,
        42,
        "    log.info(\"Processing request\");",
        .add,
        0,
        5,
        now,
    );

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "blame_with_add_line", text);
}

test "snapshot: blame_with_delete_line" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 100, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();

    const blame = blame_helpers.createBlameLine("badf00d1", "OldDev", "olddev", "Original code", 1600000000);
    const now: i64 = 1700000000; // ~3 years later

    blame_helpers.renderDiffLineWithBlame(
        frame,
        win,
        blame,
        .first_line,
        15,
        "    // TODO: fix this later",
        .delete,
        0,
        5,
        now,
    );

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "blame_with_delete_line", text);
}

test "snapshot: blame_with_context_line" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 100, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();

    const blame = blame_helpers.createBlameLine("c0ffee42", "Maintainer", "maint", "Setup function", 1680000000);
    const now: i64 = 1700000000;

    blame_helpers.renderDiffLineWithBlame(
        frame,
        win,
        blame,
        .first_line,
        10,
        "fn init() void {",
        .context,
        0,
        5,
        now,
    );

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "blame_with_context_line", text);
}

test "snapshot: blame_commit_block" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 100, 6);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();

    // Simulate a block of lines from the same commit
    const blame = blame_helpers.createBlameLine("abc12345", "TeamLead", "lead", "Refactor error handling for clarity", 1705000000);
    const now: i64 = 1705000000 + (14 * 86400); // 2 weeks later

    // First line shows full blame info
    blame_helpers.renderDiffLineWithBlame(frame, win, blame, .first_line, 20, "    if (err) |e| {", .context, 0, 5, now);

    // Second line shows commit message
    blame_helpers.renderDiffLineWithBlame(frame, win, blame, .second_line, 21, "        log.err(\"Failed: {}\", .{e});", .context, 1, 5, now);

    // Third+ lines show empty blame
    blame_helpers.renderDiffLineWithBlame(frame, win, blame, .empty, 22, "        return error.Failed;", .context, 2, 5, now);
    blame_helpers.renderDiffLineWithBlame(frame, win, blame, .empty, 23, "    }", .context, 3, 5, now);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "blame_commit_block", text);
}

test "snapshot: blame_mixed_commits" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 110, 8);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();

    const now: i64 = 1710000000;

    // Different commits for different lines
    const blame1 = blame_helpers.createBlameLine("11111111", "Alice", "alice", "Initial impl", 1700000000);
    const blame2 = blame_helpers.createBlameLine("22222222", "Bob", "bob", "Add validation", 1705000000);
    const blame3 = blame_helpers.createBlameLine("33333333", "Charlie", "charlie", "Fix edge case", 1708000000);

    // Alice's code (1 line)
    blame_helpers.renderDiffLineWithBlame(frame, win, blame1, .first_line, 10, "fn process(data: []const u8) !void {", .context, 0, 5, now);

    // Bob's code (2 lines)
    blame_helpers.renderDiffLineWithBlame(frame, win, blame2, .first_line, 11, "    if (data.len == 0) return error.Empty;", .context, 1, 5, now);
    blame_helpers.renderDiffLineWithBlame(frame, win, blame2, .second_line, 12, "    if (data.len > MAX) return error.TooLarge;", .context, 2, 5, now);

    // Charlie's fix (deleted old, added new)
    blame_helpers.renderDiffLineWithBlame(frame, win, blame3, .first_line, 13, "    // Old buggy line", .delete, 3, 5, now);
    blame_helpers.renderDiffLineWithBlame(frame, win, blame3, .second_line, 13, "    // Fixed line with proper check", .add, 4, 5, now);

    // Alice's code continues
    blame_helpers.renderDiffLineWithBlame(frame, win, blame1, .first_line, 14, "    return processInternal(data);", .context, 5, 5, now);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "blame_mixed_commits", text);
}

test "snapshot: blame_relative_times" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 80, 7);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();

    const now: i64 = 1710000000;

    // Various relative times
    const blame_2y = blame_helpers.createBlameLine("aaaa1111", "Author", "", "2 years ago", now - (2 * 365 * 86400));
    const blame_6mo = blame_helpers.createBlameLine("bbbb2222", "Author", "", "6 months ago", now - (6 * 30 * 86400));
    const blame_3w = blame_helpers.createBlameLine("cccc3333", "Author", "", "3 weeks ago", now - (3 * 7 * 86400));
    const blame_5d = blame_helpers.createBlameLine("dddd4444", "Author", "", "5 days ago", now - (5 * 86400));
    const blame_2h = blame_helpers.createBlameLine("eeee5555", "Author", "", "2 hours ago", now - (2 * 3600));

    blame_helpers.renderBlameFirstLine(frame, win, blame_2y, 0, 0, null, now);
    blame_helpers.renderBlameFirstLine(frame, win, blame_6mo, 1, 0, null, now);
    blame_helpers.renderBlameFirstLine(frame, win, blame_3w, 2, 0, null, now);
    blame_helpers.renderBlameFirstLine(frame, win, blame_5d, 3, 0, null, now);
    blame_helpers.renderBlameFirstLine(frame, win, blame_2h, 4, 0, null, now);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "blame_relative_times", text);
}

// =============================================================================
// Help Popup Rendering Snapshot Tests
// =============================================================================

test "snapshot: help_box_border" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 40, 10);
    defer ctx.deinit();

    const win = ctx.window();
    help_helpers.fillBackground(win);
    help_helpers.drawBoxBorder(win, 40, 10);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "help_box_border", text);
}

test "snapshot: help_box_with_title" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 8);
    defer ctx.deinit();

    const win = ctx.window();
    help_helpers.fillBackground(win);
    help_helpers.drawBoxBorder(win, 50, 8);
    help_helpers.renderTitle(win, " Keybindings ", 50);
    help_helpers.renderFooter(win, " ? or Esc to close ", 7, 50);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "help_box_with_title", text);
}

test "snapshot: help_keybinding_alignment" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 8);
    defer ctx.deinit();

    const win = ctx.window();
    help_helpers.fillBackground(win);

    // Test various key lengths to verify alignment
    help_helpers.renderKeyBinding(win, 0, "j", "Short key");
    help_helpers.renderKeyBinding(win, 1, "Ctrl-d", "Medium key");
    help_helpers.renderKeyBinding(win, 2, "Ctrl-w h/l", "Long key");
    help_helpers.renderKeyBinding(win, 3, "Space b", "With space");
    help_helpers.renderKeyBinding(win, 4, "Esc Esc", "Double tap");

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "help_keybinding_alignment", text);
}

test "snapshot: help_section_header" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 6);
    defer ctx.deinit();

    const win = ctx.window();
    help_helpers.fillBackground(win);

    help_helpers.renderSection(win, "NORMAL MODE", 0);
    help_helpers.renderKeyBinding(win, 1, "j / k", "Move down / up");
    help_helpers.renderKeyBinding(win, 2, "h / l", "Move left / right");
    help_helpers.renderSection(win, "INSERT MODE", 4);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "help_section_header", text);
}

test "snapshot: help_popup_minimal" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 12);
    defer ctx.deinit();

    const win = ctx.window();

    const bindings = [_]help_helpers.Binding{
        help_helpers.section("NAVIGATION"),
        help_helpers.binding("j / k", "Move down / up"),
        help_helpers.binding("h / l", "Previous / next file"),
        help_helpers.binding("g / G", "Top / bottom"),
        help_helpers.blank(),
        help_helpers.section("ACTIONS"),
        help_helpers.binding("Enter", "Add comment"),
        help_helpers.binding("?", "This help"),
    };

    help_helpers.renderHelpPopup(win, " Keybindings ", &bindings, 50, 12);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "help_popup_minimal", text);
}

test "snapshot: help_popup_full" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 72, 25);
    defer ctx.deinit();

    const win = ctx.window();

    const bindings = [_]help_helpers.Binding{
        help_helpers.section("NORMAL MODE"),
        help_helpers.binding("h / l", "Previous / next file"),
        help_helpers.binding("j / k", "Cursor down / up"),
        help_helpers.binding("g / G", "Jump to top / bottom"),
        help_helpers.binding("Ctrl-d / u", "Page down / up"),
        help_helpers.binding("M", "Center cursor in viewport"),
        help_helpers.binding("[h / ]h", "Previous / next hunk"),
        help_helpers.binding("/", "Search"),
        help_helpers.binding("n / N", "Next / previous match"),
        help_helpers.binding("Ctrl-p", "File picker"),
        help_helpers.binding(":", "Command palette"),
        help_helpers.binding("?", "This help"),
        help_helpers.binding("Enter", "Add / edit comment"),
        help_helpers.binding("Ctrl-e", "Toggle agent panel"),
        help_helpers.blank(),
        help_helpers.section("VISUAL MODE"),
        help_helpers.binding("j / k", "Extend selection"),
        help_helpers.binding("y", "Yank selection"),
        help_helpers.binding("v / Esc", "Exit"),
    };

    help_helpers.renderHelpPopup(win, " Keybindings ", &bindings, 72, 25);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "help_popup_full", text);
}

test "snapshot: help_agent_popup" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 72, 20);
    defer ctx.deinit();

    const win = ctx.window();

    const bindings = [_]help_helpers.Binding{
        help_helpers.section("GLOBAL"),
        help_helpers.binding("Ctrl-e", "Close panel"),
        help_helpers.binding("Ctrl-w h/l", "Focus diff / agent"),
        help_helpers.binding("Ctrl-w o", "Toggle fullscreen"),
        help_helpers.blank(),
        help_helpers.section("INSERT MODE"),
        help_helpers.binding("Enter", "Send prompt"),
        help_helpers.binding("Ctrl-j", "Insert newline"),
        help_helpers.binding("Esc", "Exit to normal"),
        help_helpers.binding("/", "Slash commands"),
        help_helpers.binding("@", "File picker"),
        help_helpers.blank(),
        help_helpers.section("NORMAL MODE"),
        help_helpers.binding("i/a/I/A", "Enter insert"),
        help_helpers.binding("Space s", "Toggle diff view"),
        help_helpers.binding("Space t", "Cycle model variant"),
        help_helpers.binding("?", "This help"),
    };

    help_helpers.renderHelpPopup(win, " Agent Keybindings ", &bindings, 72, 20);

    const text = try ctx.captureToText();
    defer allocator.free(text);

    try snapshot.expectSnapshot(allocator, "help_agent_popup", text);
}

// =============================================================================
// ANSI Color Snapshot Tests
// =============================================================================
// These tests use captureToAnsi() to verify actual ANSI escape codes.
// While harder to read in snapshot files, they verify colors are applied correctly.
// The text snapshots above verify structure; these verify styling.

test "snapshot: ansi_diff_file_header" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    diff_helpers.renderFileHeaderAlloc(win, "src/main.zig", 12, 5, 0, false, frame);

    const ansi = try ctx.captureToAnsi();
    defer allocator.free(ansi);

    try snapshot.expectSnapshot(allocator, "ansi_diff_file_header", ansi);
}

test "snapshot: ansi_diff_line_add" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    const line = diff_helpers.createLine(.add, "    const new_value = 42;", null, 15);
    diff_helpers.renderDiffLineAlloc(win, line, 0, 5, false, frame);

    const ansi = try ctx.captureToAnsi();
    defer allocator.free(ansi);

    try snapshot.expectSnapshot(allocator, "ansi_diff_line_add", ansi);
}

test "snapshot: ansi_diff_line_delete" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    const line = diff_helpers.createLine(.delete, "    const old_value = 0;", 14, null);
    diff_helpers.renderDiffLineAlloc(win, line, 0, 5, false, frame);

    const ansi = try ctx.captureToAnsi();
    defer allocator.free(ansi);

    try snapshot.expectSnapshot(allocator, "ansi_diff_line_delete", ansi);
}

test "snapshot: ansi_diff_line_context" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    const line = diff_helpers.createLine(.context, "fn main() void {", 10, 10);
    diff_helpers.renderDiffLineAlloc(win, line, 0, 5, false, frame);

    const ansi = try ctx.captureToAnsi();
    defer allocator.free(ansi);

    try snapshot.expectSnapshot(allocator, "ansi_diff_line_context", ansi);
}

test "snapshot: ansi_diff_hunk_header" {
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

    const ansi = try ctx.captureToAnsi();
    defer allocator.free(ansi);

    try snapshot.expectSnapshot(allocator, "ansi_diff_hunk_header", ansi);
}

test "snapshot: ansi_diff_mixed_changes" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 70, 8);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    const gutter_width: usize = 5;

    // Render a sequence of mixed changes to verify all line type colors
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.context, "fn process(data: []const u8) void {", 10, 10), 0, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.delete, "    const result = old_function(data);", 11, null), 1, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.delete, "    log.debug(\"old\");", 12, null), 2, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.add, "    const result = new_function(data);", null, 11), 3, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.add, "    log.info(\"new\");", null, 12), 4, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.add, "    metrics.increment();", null, 13), 5, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.context, "    return result;", 13, 14), 6, gutter_width, false, frame);

    const ansi = try ctx.captureToAnsi();
    defer allocator.free(ansi);

    try snapshot.expectSnapshot(allocator, "ansi_diff_mixed_changes", ansi);
}

test "snapshot: ansi_diff_cursor_line" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    const line = diff_helpers.createLine(.add, "    return result;", null, 25);
    diff_helpers.renderDiffLineAlloc(win, line, 0, 5, true, frame);

    const ansi = try ctx.captureToAnsi();
    defer allocator.free(ansi);

    try snapshot.expectSnapshot(allocator, "ansi_diff_cursor_line", ansi);
}

test "snapshot: ansi_diff_full_hunk" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 70, 10);
    defer ctx.deinit();

    const win = ctx.window();
    const frame = ctx.frameAllocator();
    const gutter_width: usize = 5;

    // Complete hunk with header and all line types
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
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.context, "    var total: i32 = 0;", 15, 15), 1, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.delete, "    total += item.value;", 16, null), 2, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.add, "    total += item.value * multiplier;", null, 16), 3, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.add, "    if (total > MAX) total = MAX;", null, 17), 4, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.context, "    return total;", 17, 18), 5, gutter_width, false, frame);
    diff_helpers.renderDiffLineAlloc(win, diff_helpers.createLine(.context, "}", 18, 19), 6, gutter_width, false, frame);

    const ansi = try ctx.captureToAnsi();
    defer allocator.free(ansi);

    try snapshot.expectSnapshot(allocator, "ansi_diff_full_hunk", ansi);
}

test "snapshot: ansi_md_bold" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 3);
    defer ctx.deinit();

    const win = ctx.window();
    var col: usize = 0;
    col = md_helpers.renderText(win, "This is ", 0, col);
    col = md_helpers.renderBold(win, "bold", 0, col);
    _ = md_helpers.renderText(win, " text", 0, col);

    const ansi = try ctx.captureToAnsi();
    defer allocator.free(ansi);

    try snapshot.expectSnapshot(allocator, "ansi_md_bold", ansi);
}

test "snapshot: ansi_md_inline_code" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 3);
    defer ctx.deinit();

    const win = ctx.window();
    var col: usize = 0;
    col = md_helpers.renderText(win, "Use ", 0, col);
    col = md_helpers.renderInlineCode(win, "const x = 42", 0, col);
    _ = md_helpers.renderText(win, " here", 0, col);

    const ansi = try ctx.captureToAnsi();
    defer allocator.free(ansi);

    try snapshot.expectSnapshot(allocator, "ansi_md_inline_code", ansi);
}

test "snapshot: ansi_md_link" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 3);
    defer ctx.deinit();

    const win = ctx.window();
    var col: usize = 0;
    col = md_helpers.renderText(win, "Visit ", 0, col);
    col = md_helpers.renderLink(win, "my website", 0, col);
    _ = md_helpers.renderText(win, " for more", 0, col);

    const ansi = try ctx.captureToAnsi();
    defer allocator.free(ansi);

    try snapshot.expectSnapshot(allocator, "ansi_md_link", ansi);
}

test "snapshot: ansi_md_header_h1" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 50, 3);
    defer ctx.deinit();

    const win = ctx.window();
    md_helpers.renderHeader(win, "Main Title", 1, 0);

    const ansi = try ctx.captureToAnsi();
    defer allocator.free(ansi);

    try snapshot.expectSnapshot(allocator, "ansi_md_header_h1", ansi);
}

// =============================================================================
// Model Selection Dialog Snapshot Tests
// =============================================================================

test "snapshot: model_selection_basic" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 80, 18);
    defer ctx.deinit();

    const models = [_]model_helpers.ModelEntry{
        .{ .model_id = "anthropic/claude-sonnet-4", .name = "Claude Sonnet 4 (Anthropic)" },
        .{ .model_id = "anthropic/claude-opus-4", .name = "Claude Opus 4 (Anthropic)" },
        .{ .model_id = "openai/gpt-4o", .name = "GPT-4o (OpenAI)" },
        .{ .model_id = "openai/o3", .name = "o3 (OpenAI)" },
    };
    const indices = [_]usize{ 0, 1, 2, 3 };

    const win = ctx.window();
    model_helpers.renderModelSelectionDialog(win, .{
        .models = &models,
        .selected_index = 0,
        .current_model_id = "anthropic/claude-sonnet-4",
        .filtered_indices = &indices,
    }, ctx.frameAllocator());

    const text = try ctx.captureToText();
    defer allocator.free(text);
    try snapshot.expectSnapshot(allocator, "model_selection_basic", text);
}

test "snapshot: model_selection_no_provider_name" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 80, 18);
    defer ctx.deinit();

    // Simulates OpenCode models where provider name is missing - names should NOT have ()
    const models = [_]model_helpers.ModelEntry{
        .{ .model_id = "gpt-5.2-codex", .name = "GPT-5.2 Codex" },
        .{ .model_id = "gpt-5.1-codex", .name = "GPT-5.1 Codex" },
        .{ .model_id = "gpt-5.1-codex-mini", .name = "GPT-5.1 Codex mini" },
        .{ .model_id = "trinity-large", .name = "Trinity Large Preview" },
        .{ .model_id = "glm-4.7-free", .name = "GLM-4.7 Free" },
    };
    const indices = [_]usize{ 0, 1, 2, 3, 4 };

    const win = ctx.window();
    model_helpers.renderModelSelectionDialog(win, .{
        .models = &models,
        .selected_index = 2,
        .filtered_indices = &indices,
    }, ctx.frameAllocator());

    const text = try ctx.captureToText();
    defer allocator.free(text);
    try snapshot.expectSnapshot(allocator, "model_selection_no_provider", text);
}

test "snapshot: model_selection_with_descriptions" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 80, 20);
    defer ctx.deinit();

    const models = [_]model_helpers.ModelEntry{
        .{ .model_id = "anthropic/claude-sonnet-4", .name = "Claude Sonnet 4", .description = "Fast and capable" },
        .{ .model_id = "anthropic/claude-opus-4", .name = "Claude Opus 4", .description = "Most powerful model" },
        .{ .model_id = "openai/gpt-4o", .name = "GPT-4o", .description = "Multimodal reasoning" },
    };
    const indices = [_]usize{ 0, 1, 2 };

    const win = ctx.window();
    model_helpers.renderModelSelectionDialog(win, .{
        .models = &models,
        .selected_index = 1,
        .current_model_id = "anthropic/claude-opus-4",
        .filtered_indices = &indices,
    }, ctx.frameAllocator());

    const text = try ctx.captureToText();
    defer allocator.free(text);
    try snapshot.expectSnapshot(allocator, "model_selection_descriptions", text);
}

test "snapshot: model_selection_no_matches" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 80, 10);
    defer ctx.deinit();

    const models = [_]model_helpers.ModelEntry{
        .{ .model_id = "anthropic/claude-sonnet-4", .name = "Claude Sonnet 4" },
    };
    const indices = [_]usize{};

    const win = ctx.window();
    model_helpers.renderModelSelectionDialog(win, .{
        .models = &models,
        .search_query = "xyz",
        .filtered_indices = &indices,
    }, ctx.frameAllocator());

    const text = try ctx.captureToText();
    defer allocator.free(text);
    try snapshot.expectSnapshot(allocator, "model_selection_no_matches", text);
}

test "snapshot: model_selection_scroll_indicators" {
    const allocator = std.testing.allocator;
    // Small window to force scrolling with many models
    var ctx = try harness.createTestContext(allocator, 80, 10);
    defer ctx.deinit();

    const models = [_]model_helpers.ModelEntry{
        .{ .model_id = "m1", .name = "Model One" },
        .{ .model_id = "m2", .name = "Model Two" },
        .{ .model_id = "m3", .name = "Model Three" },
        .{ .model_id = "m4", .name = "Model Four" },
        .{ .model_id = "m5", .name = "Model Five" },
        .{ .model_id = "m6", .name = "Model Six" },
        .{ .model_id = "m7", .name = "Model Seven" },
        .{ .model_id = "m8", .name = "Model Eight" },
    };
    const indices = [_]usize{ 0, 1, 2, 3, 4, 5, 6, 7 };

    const win = ctx.window();
    model_helpers.renderModelSelectionDialog(win, .{
        .models = &models,
        .selected_index = 0,
        .filtered_indices = &indices,
    }, ctx.frameAllocator());

    const text = try ctx.captureToText();
    defer allocator.free(text);
    try snapshot.expectSnapshot(allocator, "model_selection_scroll", text);
}

// =============================================================================
// Model Selection ANSI Snapshot Tests
// =============================================================================
// These tests capture ANSI escape codes to verify:
// - Background color (dialog_bg) fills the entire dialog area
// - Foreground colors for selected vs unselected items
// - Bold attribute on selected model name
// - Current model checkmark uses green color
// - No style leaks between elements

test "snapshot: ansi_model_selection_basic" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 80, 18);
    defer ctx.deinit();

    const models = [_]model_helpers.ModelEntry{
        .{ .model_id = "anthropic/claude-sonnet-4", .name = "Claude Sonnet 4 (Anthropic)" },
        .{ .model_id = "anthropic/claude-opus-4", .name = "Claude Opus 4 (Anthropic)" },
        .{ .model_id = "openai/gpt-4o", .name = "GPT-4o (OpenAI)" },
        .{ .model_id = "openai/o3", .name = "o3 (OpenAI)" },
    };
    const indices = [_]usize{ 0, 1, 2, 3 };

    const win = ctx.window();
    model_helpers.renderModelSelectionDialog(win, .{
        .models = &models,
        .selected_index = 0,
        .current_model_id = "anthropic/claude-sonnet-4",
        .filtered_indices = &indices,
    }, ctx.frameAllocator());

    const ansi = try ctx.captureToAnsi();
    defer allocator.free(ansi);
    try snapshot.expectSnapshot(allocator, "ansi_model_selection_basic", ansi);
}

test "snapshot: ansi_model_selection_no_provider" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 80, 18);
    defer ctx.deinit();

    // Models without provider names - verifies no "()" artifacts
    const models = [_]model_helpers.ModelEntry{
        .{ .model_id = "gpt-5.2-codex", .name = "GPT-5.2 Codex" },
        .{ .model_id = "gpt-5.1-codex", .name = "GPT-5.1 Codex" },
        .{ .model_id = "gpt-5.1-codex-mini", .name = "GPT-5.1 Codex mini" },
        .{ .model_id = "trinity-large", .name = "Trinity Large Preview" },
        .{ .model_id = "glm-4.7-free", .name = "GLM-4.7 Free" },
    };
    const indices = [_]usize{ 0, 1, 2, 3, 4 };

    const win = ctx.window();
    model_helpers.renderModelSelectionDialog(win, .{
        .models = &models,
        .selected_index = 2,
        .filtered_indices = &indices,
    }, ctx.frameAllocator());

    const ansi = try ctx.captureToAnsi();
    defer allocator.free(ansi);
    try snapshot.expectSnapshot(allocator, "ansi_model_selection_no_provider", ansi);
}

test "snapshot: ansi_model_selection_descriptions" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 80, 20);
    defer ctx.deinit();

    const models = [_]model_helpers.ModelEntry{
        .{ .model_id = "anthropic/claude-sonnet-4", .name = "Claude Sonnet 4", .description = "Fast and capable" },
        .{ .model_id = "anthropic/claude-opus-4", .name = "Claude Opus 4", .description = "Most powerful model" },
        .{ .model_id = "openai/gpt-4o", .name = "GPT-4o", .description = "Multimodal reasoning" },
    };
    const indices = [_]usize{ 0, 1, 2 };

    const win = ctx.window();
    model_helpers.renderModelSelectionDialog(win, .{
        .models = &models,
        .selected_index = 1,
        .current_model_id = "anthropic/claude-opus-4",
        .filtered_indices = &indices,
    }, ctx.frameAllocator());

    const ansi = try ctx.captureToAnsi();
    defer allocator.free(ansi);
    try snapshot.expectSnapshot(allocator, "ansi_model_selection_descriptions", ansi);
}

test "snapshot: ansi_model_selection_no_matches" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 80, 10);
    defer ctx.deinit();

    const models = [_]model_helpers.ModelEntry{
        .{ .model_id = "anthropic/claude-sonnet-4", .name = "Claude Sonnet 4" },
    };
    const indices = [_]usize{};

    const win = ctx.window();
    model_helpers.renderModelSelectionDialog(win, .{
        .models = &models,
        .search_query = "xyz",
        .filtered_indices = &indices,
    }, ctx.frameAllocator());

    const ansi = try ctx.captureToAnsi();
    defer allocator.free(ansi);
    try snapshot.expectSnapshot(allocator, "ansi_model_selection_no_matches", ansi);
}

test "snapshot: ansi_model_selection_scroll" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 80, 10);
    defer ctx.deinit();

    const models = [_]model_helpers.ModelEntry{
        .{ .model_id = "m1", .name = "Model One" },
        .{ .model_id = "m2", .name = "Model Two" },
        .{ .model_id = "m3", .name = "Model Three" },
        .{ .model_id = "m4", .name = "Model Four" },
        .{ .model_id = "m5", .name = "Model Five" },
        .{ .model_id = "m6", .name = "Model Six" },
        .{ .model_id = "m7", .name = "Model Seven" },
        .{ .model_id = "m8", .name = "Model Eight" },
    };
    const indices = [_]usize{ 0, 1, 2, 3, 4, 5, 6, 7 };

    const win = ctx.window();
    model_helpers.renderModelSelectionDialog(win, .{
        .models = &models,
        .selected_index = 0,
        .filtered_indices = &indices,
    }, ctx.frameAllocator());

    const ansi = try ctx.captureToAnsi();
    defer allocator.free(ansi);
    try snapshot.expectSnapshot(allocator, "ansi_model_selection_scroll", ansi);
}

test "snapshot: model_selection_with_provider_suffix" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 80, 14);
    defer ctx.deinit();

    // Model names with provider suffix (the normal case after the alloc_always fix)
    const models = [_]model_helpers.ModelEntry{
        .{ .model_id = "openrouter/gpt-5.2-codex", .name = "GPT-5.2 Codex (openrouter)" },
        .{ .model_id = "openrouter/gpt-5.1-codex", .name = "GPT-5.1 Codex (openrouter)" },
        .{ .model_id = "anthropic/claude-opus-4", .name = "Claude Opus 4 (anthropic)" },
    };
    const indices = [_]usize{ 0, 1, 2 };

    const win = ctx.window();
    model_helpers.renderModelSelectionDialog(win, .{
        .models = &models,
        .selected_index = 0,
        .filtered_indices = &indices,
    }, ctx.frameAllocator());

    const text = try ctx.captureToText();
    defer allocator.free(text);
    try snapshot.expectSnapshot(allocator, "model_selection_with_provider", text);
}

// =============================================================================
// Command Palette (File Dialog) Snapshot Tests
// =============================================================================

test "snapshot: file_dialog_basic" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 100, 12);
    defer ctx.deinit();

    const files = [_]palette_helpers.FileEntry{
        .{ .display_name = "src/main.zig", .description = "Entry point", .additions = 5, .deletions = 2 },
        .{ .display_name = "src/ui.zig", .description = "UI rendering", .additions = 42, .deletions = 10 },
        .{ .display_name = "src/command_palette.zig", .description = "Command palette", .additions = 0, .deletions = 3 },
    };

    const win = ctx.window();
    palette_helpers.renderFilePalette(win, .{
        .files = &files,
        .selected_index = 0,
        .total_files = 3,
        .total_additions = 47,
        .total_deletions = 15,
    }, ctx.frameAllocator());

    const text = try ctx.captureToText();
    defer allocator.free(text);
    try snapshot.expectSnapshot(allocator, "file_dialog_basic", text);
}

test "snapshot: ansi_file_dialog_basic" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 100, 12);
    defer ctx.deinit();

    const files = [_]palette_helpers.FileEntry{
        .{ .display_name = "src/main.zig", .description = "Entry point", .additions = 5, .deletions = 2 },
        .{ .display_name = "src/ui.zig", .description = "UI rendering", .additions = 42, .deletions = 10 },
        .{ .display_name = "src/command_palette.zig", .description = "Command palette", .additions = 0, .deletions = 3 },
    };

    const win = ctx.window();
    palette_helpers.renderFilePalette(win, .{
        .files = &files,
        .selected_index = 0,
        .total_files = 3,
        .total_additions = 47,
        .total_deletions = 15,
    }, ctx.frameAllocator());

    const ansi = try ctx.captureToAnsi();
    defer allocator.free(ansi);
    try snapshot.expectSnapshot(allocator, "ansi_file_dialog_basic", ansi);
}
