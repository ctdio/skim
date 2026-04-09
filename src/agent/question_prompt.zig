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

pub fn countQuestionPromptLines(allocator: std.mem.Allocator, width: usize, pending: *PendingQuestion) usize {
    if (pending.confirming) {
        return countConfirmationLines(allocator, width, pending);
    }
    return countQuestionLines(allocator, width, pending);
}

pub fn renderInlineQuestionPrompt(allocator: std.mem.Allocator, win: vaxis.Window, pending: *PendingQuestion) !void {
    if (pending.confirming) {
        return renderConfirmationView(allocator, win, pending);
    }
    return renderQuestionView(allocator, win, pending);
}

// =============================================================================
// Question selection view
// =============================================================================

fn countQuestionLines(allocator: std.mem.Allocator, width: usize, pending: *PendingQuestion) usize {
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

fn renderQuestionView(allocator: std.mem.Allocator, win: vaxis.Window, pending: *PendingQuestion) !void {
    var row: usize = 0;

    // Row 0: Separator line
    renderSeparator(win, row);
    row += 1;

    const max_text_width = if (win.width > 4) win.width - 4 else 1;

    // Tabs header (if multiple questions)
    if (pending.questions.len > 1 and row < win.height) {
        renderTabsHeader(win, pending, row);
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
    // NOTE: vaxis cells store grapheme *references* into the segment text, so
    // all text passed to win.print must outlive the render frame. We use
    // multiple segments per option so that each piece is either a compile-time
    // literal or a heap-allocated string from the PendingQuestion — no
    // temporary formatting buffers needed.
    const normal_style = vaxis.Style{ .fg = Color.white };
    const selected_style = vaxis.Style{ .fg = Color.black, .bg = Color.cyan, .bold = true };
    const desc_style = vaxis.Style{ .fg = Color.dim_gray };

    for (question.options, 0..) |opt, idx| {
        if (row >= win.height) break;

        const is_cursor = idx == question_state.cursor_index;
        const is_selected = question_state.selected[idx];
        const style = if (is_cursor) selected_style else normal_style;

        const indicator: []const u8 = if (is_cursor) "▸ " else "  ";
        const checkbox: []const u8 = if (question.multiple) (if (is_selected) "[x] " else "[ ] ") else "";
        const num_str: []const u8 = if (idx < digits.len) digits[idx] else "?";

        var segs = [_]vaxis.Cell.Segment{
            .{ .text = indicator, .style = style },
            .{ .text = num_str, .style = style },
            .{ .text = ". ", .style = style },
            .{ .text = checkbox, .style = style },
            .{ .text = opt.label, .style = style },
        };
        _ = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = 1 });
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
        const footer = if (pending.questions.len > 1)
            (if (question.multiple)
                "h/l: prev/next  j/k: select  space: toggle  enter: confirm  ctrl-c: dismiss"
            else
                "h/l: prev/next  j/k: select  enter: confirm  ctrl-c: dismiss")
        else if (question.multiple)
            "j/k: select  space: toggle  enter: confirm  ctrl-c: dismiss"
        else
            "j/k: select  enter: confirm  ctrl-c: dismiss";
        const footer_style = vaxis.Style{ .fg = Color.dim_gray };
        var footer_seg = [_]vaxis.Cell.Segment{.{ .text = footer, .style = footer_style }};
        _ = win.print(&footer_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });
    }
}

// =============================================================================
// Confirmation view
// =============================================================================

fn countConfirmationLines(allocator: std.mem.Allocator, width: usize, pending: *PendingQuestion) usize {
    const max_text_width = if (width > 4) width - 4 else 1;
    var lines: usize = 0;

    lines += 1; // Spacer
    lines += 1; // Header

    for (pending.questions, 0..) |question, qi| {
        lines += 1; // Question label
        const q_state = pending.states[qi];
        for (question.options, 0..) |opt, oi| {
            if (q_state.selected[oi]) {
                if (opt.is_custom) {
                    const text = std.mem.trim(u8, q_state.custom_input.getText(), &std.ascii.whitespace);
                    if (text.len > 0) {
                        lines += countWrappedRows(allocator, text, max_text_width);
                        continue;
                    }
                }
                lines += countWrappedRows(allocator, opt.label, max_text_width);
            }
        }
        // At least one line for "No answer" case
        var has_selection = false;
        for (q_state.selected) |sel| {
            if (sel) {
                has_selection = true;
                break;
            }
        }
        if (!has_selection) lines += 1;
    }

    lines += 1; // Spacer before footer
    lines += 1; // Footer

    return @max(@as(usize, 3), lines);
}

fn renderConfirmationView(allocator: std.mem.Allocator, win: vaxis.Window, pending: *PendingQuestion) !void {
    var row: usize = 0;

    renderSeparator(win, row);
    row += 1;

    const max_text_width = if (win.width > 4) win.width - 4 else 1;

    // Spacer
    if (row < win.height) row += 1;

    // Header
    const header_style = vaxis.Style{ .fg = Color.white, .bold = true };
    if (row < win.height) {
        var seg = [_]vaxis.Cell.Segment{.{ .text = "Confirm your answers:", .style = header_style }};
        _ = win.print(&seg, .{ .row_offset = @intCast(row), .col_offset = 1 });
        row += 1;
    }

    const label_style = vaxis.Style{ .fg = Color.cyan, .bold = true };
    const answer_style = vaxis.Style{ .fg = Color.white };
    const no_answer_style = vaxis.Style{ .fg = Color.dim_gray, .italic = true };

    for (pending.questions, 0..) |question, qi| {
        if (row >= win.height) break;

        // Question header
        const header = question.header orelse question.prompt;
        var header_seg = [_]vaxis.Cell.Segment{.{ .text = header, .style = label_style }};
        _ = win.print(&header_seg, .{ .row_offset = @intCast(row), .col_offset = 2 });
        row += 1;

        // Selected answers
        const q_state = pending.states[qi];
        var has_selection = false;

        for (question.options, 0..) |opt, oi| {
            if (!q_state.selected[oi]) continue;
            has_selection = true;
            if (row >= win.height) break;

            if (opt.is_custom) {
                const text = std.mem.trim(u8, q_state.custom_input.getText(), &std.ascii.whitespace);
                if (text.len > 0) {
                    const used = renderWrappedText(allocator, win, text, row, 4, max_text_width, answer_style);
                    row += used;
                    continue;
                }
            }
            const used = renderWrappedText(allocator, win, opt.label, row, 4, max_text_width, answer_style);
            row += used;
        }

        if (!has_selection and row < win.height) {
            var seg = [_]vaxis.Cell.Segment{.{ .text = "No answer", .style = no_answer_style }};
            _ = win.print(&seg, .{ .row_offset = @intCast(row), .col_offset = 4 });
            row += 1;
        }
    }

    // Spacer
    if (row < win.height) row += 1;

    // Footer
    if (row < win.height) {
        const footer_style = vaxis.Style{ .fg = Color.dim_gray };
        var footer_seg = [_]vaxis.Cell.Segment{.{ .text = "enter: submit  ctrl-c/h: go back", .style = footer_style }};
        _ = win.print(&footer_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });
    }
}

// =============================================================================
// Helpers
// =============================================================================

const digits = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16", "17", "18", "19", "20", "21", "22", "23", "24", "25", "26", "27", "28", "29", "30", "31", "32" };

fn renderSeparator(win: vaxis.Window, row: usize) void {
    const separator_style = vaxis.Style{ .fg = Color.dim_gray };
    for (0..win.width) |col| {
        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = separator_style,
        });
    }
}

fn renderTabsHeader(win: vaxis.Window, pending: *PendingQuestion, row: usize) void {
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
}

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
