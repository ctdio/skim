const std = @import("std");
const vaxis = @import("vaxis");
const state = @import("state.zig");

pub const AgentState = state.AgentState;
pub const PendingQuestion = state.PendingQuestion;
pub const QuestionOptionData = state.QuestionOptionData;
pub const QuestionData = state.QuestionData;
pub const QuestionPromptData = state.QuestionPromptData;
const rendering_common = @import("../rendering/common.zig");
const Color = rendering_common.Color;
const rendering_utils = @import("../rendering/utils.zig");
const RenderUtils = rendering_utils.RenderUtils;

fn renderWrappedText(
    allocator: std.mem.Allocator,
    win: vaxis.Window,
    text: []const u8,
    start_row: usize,
    col_offset: usize,
    max_width: usize,
    style: vaxis.Style,
) usize {
    if (text.len == 0) return 0;

    var wrapped = RenderUtils.wrapText(allocator, text, max_width) catch return 0;
    defer wrapped.deinit(allocator);

    var row = start_row;
    for (wrapped.items) |line| {
        if (row >= win.height) break;
        var seg = [_]vaxis.Cell.Segment{.{ .text = line, .style = style }};
        _ = win.print(&seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
        row += 1;
    }

    return row - start_row;
}

fn countWrappedRows(allocator: std.mem.Allocator, text: []const u8, max_width: usize) usize {
    if (text.len == 0) return 1;
    var wrapped = RenderUtils.wrapText(allocator, text, max_width) catch return 1;
    defer wrapped.deinit(allocator);
    return @max(@as(usize, 1), wrapped.items.len);
}

pub fn countQuestionPromptLines(allocator: std.mem.Allocator, width: usize, pending: *PendingQuestion) usize {
    const max_text_width = if (width > 4) width - 4 else 1;
    const question = pending.questions[pending.active_index];
    const question_state = pending.states[pending.active_index];

    var lines: usize = 0;

    if (pending.questions.len > 1) {
        lines += 1; // Tabs row
    }
    lines += 1; // Blank line
    lines += countWrappedRows(allocator, question.prompt, max_text_width);

    for (question.options) |opt| {
        lines += 1; // Label line
        if (opt.description != null) {
            lines += 1; // Description line
        }
    }

    if (question.custom_index) |custom_idx| {
        if (question_state.selected[custom_idx]) {
            const custom_text = question_state.custom_input.getText();
            const display_text = if (custom_text.len > 0) custom_text else "Type your own answer...";
            lines += countWrappedRows(allocator, display_text, max_text_width);
        }
    }

    lines += 1; // Footer

    return @max(@as(usize, 3), lines);
}

pub fn renderInlineQuestionPrompt(allocator: std.mem.Allocator, win: vaxis.Window, pending: *PendingQuestion) !void {
    var row: usize = 0;

    // Row 0: Separator line
    const separator_style = vaxis.Style{ .fg = Color.dim_gray };
    for (0..win.width) |col| {
        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = separator_style,
        });
    }
    row += 1;

    const max_text_width = if (win.width > 4) win.width - 4 else 1;

    // Tabs header (if multiple questions)
    if (pending.questions.len > 1 and row < win.height) {
        const tab_style = vaxis.Style{ .fg = Color.white };
        const active_style = vaxis.Style{ .fg = Color.black, .bg = Color.cyan, .bold = true };
        var col: usize = 1;

        for (pending.questions, 0..) |question, idx| {
            const label = question.header orelse "Question";
            const style = if (idx == pending.active_index) active_style else tab_style;
            const label_len = label.len;

            if (col + label_len >= win.width) break;
            var seg = [_]vaxis.Cell.Segment{.{ .text = label, .style = style }};
            _ = win.print(&seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
            col += label_len + 2;
        }
        row += 1;
    }

    // Spacer row
    if (row < win.height) row += 1;

    const question = pending.questions[pending.active_index];
    const question_state = pending.states[pending.active_index];

    // Question prompt text
    const question_style = vaxis.Style{ .fg = Color.white, .bold = true };
    if (row < win.height) {
        const used_rows = renderWrappedText(allocator, win, question.prompt, row, 1, max_text_width, question_style);
        row += used_rows;
    }

    // Options
    const normal_style = vaxis.Style{ .fg = Color.white };
    const selected_style = vaxis.Style{ .fg = Color.black, .bg = Color.cyan, .bold = true };
    const desc_style = vaxis.Style{ .fg = Color.dim_gray, .italic = true };

    for (question.options, 0..) |opt, idx| {
        if (row >= win.height) break;

        const is_cursor = idx == question_state.cursor_index;
        const is_selected = question_state.selected[idx];
        const style = if (is_cursor) selected_style else normal_style;

        const indicator: []const u8 = if (is_cursor) "▸ " else "  ";
        const checkbox: []const u8 = if (question.multiple) (if (is_selected) "[x] " else "[ ] ") else "";

        var line_buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s}{d}. {s}{s}", .{ indicator, idx + 1, checkbox, opt.label }) catch opt.label;
        var line_seg = [_]vaxis.Cell.Segment{.{ .text = line, .style = style }};
        _ = win.print(&line_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });
        row += 1;

        if (opt.description) |desc| {
            if (row >= win.height) break;
            var desc_seg = [_]vaxis.Cell.Segment{.{ .text = desc, .style = desc_style }};
            _ = win.print(&desc_seg, .{ .row_offset = @intCast(row), .col_offset = 5 });
            row += 1;
        }
    }

    // Custom input line
    if (question.custom_index) |custom_idx| {
        if (question_state.selected[custom_idx] and row < win.height) {
            const custom_text = question_state.custom_input.getText();
            const display_text = if (custom_text.len > 0) custom_text else "Type your own answer...";
            const input_style = if (custom_text.len > 0) normal_style else desc_style;
            var input_seg = [_]vaxis.Cell.Segment{.{ .text = display_text, .style = input_style }};
            _ = win.print(&input_seg, .{ .row_offset = @intCast(row), .col_offset = 5 });
            row += 1;
        }
    }

    // Footer
    if (row < win.height) {
        const footer = if (question.multiple)
            "tab: next  up/down: select  space: toggle  enter: confirm  esc: dismiss"
        else
            "tab: next  up/down: select  enter: confirm  esc: dismiss";
        const footer_style = vaxis.Style{ .fg = Color.dim_gray };
        var footer_seg = [_]vaxis.Cell.Segment{.{ .text = footer, .style = footer_style }};
        _ = win.print(&footer_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });
    }
}
