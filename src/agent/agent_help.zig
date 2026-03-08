const std = @import("std");
const vaxis = @import("vaxis");

const App = @import("../app.zig").App;
const Color = @import("../rendering/common.zig").Color;
const FrameChars = @import("../rendering/common.zig").FrameChars;
const AgentState = @import("state.zig").AgentState;

const KEY_COL_WIDTH: usize = 14; // Fixed width for key column alignment

/// Render the agent help popup overlay
pub fn renderHelpPopup(app: *App, win: vaxis.Window, agent_state: *AgentState) !void {
    // Calculate popup dimensions
    const popup_width = @min(72, win.width -| 4);
    const popup_height = @min(35, win.height -| 4);
    const x_offset = if (win.width > popup_width) (win.width - popup_width) / 2 else 0;
    const y_offset = if (win.height > popup_height) (win.height - popup_height) / 2 else 0;

    const popup_win = win.child(.{
        .x_off = x_offset,
        .y_off = y_offset,
        .width = @intCast(popup_width),
        .height = @intCast(popup_height),
    });

    popup_win.clear();

    // Fill with dark gray background
    const bg_cell = vaxis.Cell{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .bg = Color.dialog_bg },
    };
    popup_win.fill(bg_cell);

    const border_style = vaxis.Style{ .fg = Color.dim_gray, .bg = Color.dialog_bg };
    const title_style = vaxis.Style{ .fg = Color.cyan, .bg = Color.dialog_bg, .bold = true };

    // Draw box border
    drawBoxBorder(popup_win, popup_width, popup_height, border_style);

    // Title centered in top border
    const title = " Agent Keybindings ";
    const title_x = if (popup_width > title.len) (popup_width - title.len) / 2 else 1;
    var title_seg = [_]vaxis.Cell.Segment{.{ .text = title, .style = title_style }};
    _ = popup_win.print(&title_seg, .{ .row_offset = 0, .col_offset = @intCast(title_x) });

    // Build scrollable content
    var content_lines: std.ArrayList(ContentLine) = .{};
    defer content_lines.deinit(app.allocator);

    const section_style = vaxis.Style{ .fg = Color.yellow, .bg = Color.dialog_bg, .bold = true };
    const key_style = vaxis.Style{ .fg = Color.cyan, .bg = Color.dialog_bg };
    const desc_style = vaxis.Style{ .fg = Color.white, .bg = Color.dialog_bg };

    // GLOBAL section
    try content_lines.append(app.allocator, .{ .section = "GLOBAL" });
    const global_bindings = [_]Binding{
        .{ .key = "Ctrl-e", .desc = "Close panel, return to diff" },
        .{ .key = "Ctrl-g", .desc = "Edit prompt in $EDITOR" },
        .{ .key = "Ctrl-w h/l", .desc = "Focus diff / agent" },
        .{ .key = "Ctrl-w w", .desc = "Cycle panel focus" },
        .{ .key = "Ctrl-w o", .desc = "Toggle fullscreen" },
        .{ .key = "Ctrl-s", .desc = "Stash / unstash prompt" },
        .{ .key = "Ctrl-t", .desc = "Toggle todo list" },
    };
    for (global_bindings) |b| {
        try content_lines.append(app.allocator, .{ .key = b.key, .desc = b.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .blank = true });

    // INSERT MODE
    try content_lines.append(app.allocator, .{ .section = "INSERT MODE" });
    const insert_bindings = [_]Binding{
        .{ .key = "Enter", .desc = "Send prompt" },
        .{ .key = "Ctrl-j", .desc = "Insert newline" },
        .{ .key = "Esc / Ctrl-c", .desc = "Exit to normal mode" },
        .{ .key = "/", .desc = "Slash command menu" },
        .{ .key = "@", .desc = "File picker" },
        .{ .key = "!", .desc = "Toggle shell mode" },
        .{ .key = "↑", .desc = "Restore stashed prompt" },
    };
    for (insert_bindings) |b| {
        try content_lines.append(app.allocator, .{ .key = b.key, .desc = b.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .blank = true });

    // NORMAL MODE
    try content_lines.append(app.allocator, .{ .section = "NORMAL MODE" });
    const normal_bindings = [_]Binding{
        .{ .key = "i/a/I/A", .desc = "Enter insert mode" },
        .{ .key = "h / l", .desc = "Cursor left / right" },
        .{ .key = "w/b/e", .desc = "Word motions" },
        .{ .key = "0 / $", .desc = "Line start / end" },
        .{ .key = "gg / G", .desc = "Top / bottom of input" },
        .{ .key = "Ctrl-d / u", .desc = "Half-page down / up" },
        .{ .key = "x / dd", .desc = "Delete char / line" },
        .{ .key = ":", .desc = "Command palette" },
        .{ .key = "?", .desc = "This help" },
        .{ .key = "gb", .desc = "History mode" },
        .{ .key = "gt / gT", .desc = "Next / prev tab" },
        .{ .key = "Space b/Esc", .desc = "History mode" },
        .{ .key = "Space f", .desc = "Follow mode (scroll bottom)" },
        .{ .key = "Space s", .desc = "Toggle diff view" },
        .{ .key = "Space t", .desc = "Cycle model variant" },
        .{ .key = "Tab", .desc = "Cycle session modes" },
        .{ .key = "Esc Esc", .desc = "Interrupt agent" },
    };
    for (normal_bindings) |b| {
        try content_lines.append(app.allocator, .{ .key = b.key, .desc = b.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .blank = true });

    // HISTORY MODE
    try content_lines.append(app.allocator, .{ .section = "HISTORY MODE" });
    const history_bindings = [_]Binding{
        .{ .key = "j / k", .desc = "Cursor down / up" },
        .{ .key = "h / l", .desc = "Prev / next message" },
        .{ .key = "gg / G", .desc = "Top / bottom" },
        .{ .key = "Ctrl-d / u", .desc = "Page down / up" },
        .{ .key = "M", .desc = "Center cursor" },
        .{ .key = "v", .desc = "Visual selection" },
        .{ .key = "y", .desc = "Yank user message" },
        .{ .key = "yy", .desc = "Yank current line" },
        .{ .key = "Y", .desc = "Yank entire message" },
        .{ .key = "Space f", .desc = "Resume follow mode" },
        .{ .key = "i", .desc = "Exit to insert" },
        .{ .key = "Esc / q", .desc = "Exit to normal" },
    };
    for (history_bindings) |b| {
        try content_lines.append(app.allocator, .{ .key = b.key, .desc = b.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .blank = true });

    // VISUAL MODE
    try content_lines.append(app.allocator, .{ .section = "VISUAL MODE" });
    const visual_bindings = [_]Binding{
        .{ .key = "j / k", .desc = "Extend selection" },
        .{ .key = "y", .desc = "Yank selection" },
        .{ .key = "Esc / v", .desc = "Exit" },
    };
    for (visual_bindings) |b| {
        try content_lines.append(app.allocator, .{ .key = b.key, .desc = b.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .blank = true });

    // PERMISSION PROMPT
    try content_lines.append(app.allocator, .{ .section = "PERMISSION PROMPT" });
    const perm_bindings = [_]Binding{
        .{ .key = "j/k / ↑↓", .desc = "Navigate options" },
        .{ .key = "Ctrl-d / u", .desc = "Scroll history" },
        .{ .key = "Enter / y", .desc = "Accept" },
        .{ .key = "Esc / n", .desc = "Reject" },
    };
    for (perm_bindings) |b| {
        try content_lines.append(app.allocator, .{ .key = b.key, .desc = b.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .blank = true });

    // MENUS
    try content_lines.append(app.allocator, .{ .section = "MENUS (/ @ :)" });
    const menu_bindings = [_]Binding{
        .{ .key = "Ctrl-n / p", .desc = "Navigate items" },
        .{ .key = "↑ / ↓", .desc = "Navigate (palette)" },
        .{ .key = "Tab", .desc = "Insert selected" },
        .{ .key = "Enter", .desc = "Execute" },
        .{ .key = "Esc", .desc = "Close" },
    };
    for (menu_bindings) |b| {
        try content_lines.append(app.allocator, .{ .key = b.key, .desc = b.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .blank = true });

    // SLASH COMMANDS
    try content_lines.append(app.allocator, .{ .section = "SLASH COMMANDS" });
    const slash_bindings = [_]Binding{
        .{ .key = "/clear", .desc = "Clear session" },
        .{ .key = "/fast", .desc = "Toggle Codex fast mode" },
        .{ .key = "/model", .desc = "Switch AI model" },
        .{ .key = "/permissions", .desc = "Switch Codex permission mode" },
        .{ .key = "/resume", .desc = "Resume session" },
    };
    for (slash_bindings) |b| {
        try content_lines.append(app.allocator, .{ .key = b.key, .desc = b.desc, .key_style = key_style, .desc_style = desc_style });
    }

    // Calculate scroll bounds
    const content_start_row: usize = 2;
    const content_end_row = popup_height -| 2;
    const max_visible = content_end_row -| content_start_row;
    const scroll_offset = agent_state.help_scroll_offset;
    const total_rows = content_lines.items.len;
    const visible_start = scroll_offset;
    const visible_end = @min(visible_start + max_visible, total_rows);

    // Render content
    var row: usize = content_start_row;
    for (visible_start..visible_end) |idx| {
        if (row >= content_end_row) break;
        const line = content_lines.items[idx];

        if (line.section) |section| {
            var sec_seg = [_]vaxis.Cell.Segment{.{ .text = section, .style = section_style }};
            _ = popup_win.print(&sec_seg, .{ .row_offset = @intCast(row), .col_offset = 2 });
        } else if (line.key) |key| {
            renderKeyBinding(popup_win, @intCast(row), key, line.desc.?, line.key_style.?, line.desc_style.?);
        }
        row += 1;
    }

    // Footer with scroll hints
    const footer_row = popup_height - 1;
    const has_more_above = scroll_offset > 0;
    const has_more_below = visible_end < total_rows;

    if (has_more_above or has_more_below) {
        var footer_buf: [64]u8 = undefined;
        const arrows = if (has_more_above and has_more_below)
            "↑↓"
        else if (has_more_above)
            "↑"
        else
            "↓";
        const footer = std.fmt.bufPrint(&footer_buf, " j/k {s} scroll │ ? or Esc to close ", .{arrows}) catch " scroll │ ? to close ";
        const footer_x = if (popup_width > footer.len) (popup_width - footer.len) / 2 else 1;
        var footer_seg = [_]vaxis.Cell.Segment{.{ .text = footer, .style = .{ .fg = Color.dim_gray, .bg = Color.dialog_bg } }};
        _ = popup_win.print(&footer_seg, .{ .row_offset = @intCast(footer_row), .col_offset = @intCast(footer_x) });
    } else {
        const footer = " ? or Esc to close ";
        const footer_x = if (popup_width > footer.len) (popup_width - footer.len) / 2 else 1;
        var footer_seg = [_]vaxis.Cell.Segment{.{ .text = footer, .style = .{ .fg = Color.dim_gray, .bg = Color.dialog_bg } }};
        _ = popup_win.print(&footer_seg, .{ .row_offset = @intCast(footer_row), .col_offset = @intCast(footer_x) });
    }
}

fn drawBoxBorder(win: vaxis.Window, width: usize, height: usize, style: vaxis.Style) void {
    if (width < 2 or height < 2) return;

    // Corners
    win.writeCell(0, 0, .{ .char = .{ .grapheme = FrameChars.top_left, .width = 1 }, .style = style });
    win.writeCell(@intCast(width - 1), 0, .{ .char = .{ .grapheme = FrameChars.top_right, .width = 1 }, .style = style });
    win.writeCell(0, @intCast(height - 1), .{ .char = .{ .grapheme = FrameChars.bottom_left, .width = 1 }, .style = style });
    win.writeCell(@intCast(width - 1), @intCast(height - 1), .{ .char = .{ .grapheme = FrameChars.bottom_right, .width = 1 }, .style = style });

    // Horizontal edges
    for (1..width - 1) |x| {
        win.writeCell(@intCast(x), 0, .{ .char = .{ .grapheme = FrameChars.horizontal, .width = 1 }, .style = style });
        win.writeCell(@intCast(x), @intCast(height - 1), .{ .char = .{ .grapheme = FrameChars.horizontal, .width = 1 }, .style = style });
    }

    // Vertical edges
    for (1..height - 1) |y| {
        win.writeCell(0, @intCast(y), .{ .char = .{ .grapheme = FrameChars.vertical, .width = 1 }, .style = style });
        win.writeCell(@intCast(width - 1), @intCast(y), .{ .char = .{ .grapheme = FrameChars.vertical, .width = 1 }, .style = style });
    }
}

fn renderKeyBinding(win: vaxis.Window, row: u16, key: []const u8, desc: []const u8, key_style: vaxis.Style, desc_style: vaxis.Style) void {
    const sep_style = vaxis.Style{ .fg = Color.dim_gray, .bg = Color.dialog_bg };

    // Print key (without padding first)
    var key_seg = [_]vaxis.Cell.Segment{
        .{ .text = "  ", .style = .{ .bg = Color.dialog_bg } },
        .{ .text = key, .style = key_style },
    };
    const key_result = win.print(&key_seg, .{ .row_offset = row, .col_offset = 1 });

    // Pad to fixed column position
    const pad_col: u16 = 1 + 2 + KEY_COL_WIDTH; // offset + "  " + key column width
    var col = key_result.col;
    while (col < pad_col) : (col += 1) {
        win.writeCell(col, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = key_style });
    }

    // Print separator and description (using string literals that persist)
    var desc_seg = [_]vaxis.Cell.Segment{
        .{ .text = " │ ", .style = sep_style },
        .{ .text = desc, .style = desc_style },
    };
    _ = win.print(&desc_seg, .{ .row_offset = row, .col_offset = pad_col });
}

// Total content rows (approximate, for scroll calculation)
const HELP_CONTENT_ROWS = 80;

/// Handle keyboard input when agent help is visible
/// Returns true if key was handled, false to pass through
pub fn handleKey(agent_state: *AgentState, key: vaxis.Key) bool {
    const max_visible: usize = 30;
    const max_scroll: usize = if (HELP_CONTENT_ROWS > max_visible) HELP_CONTENT_ROWS - max_visible else 0;

    switch (key.codepoint) {
        'j', 'J' => {
            if (agent_state.help_scroll_offset < max_scroll) {
                agent_state.help_scroll_offset += 1;
            }
            return true;
        },
        'k', 'K' => {
            if (agent_state.help_scroll_offset > 0) {
                agent_state.help_scroll_offset -= 1;
            }
            return true;
        },
        'd', 'D' => {
            if (!key.mods.ctrl) {
                const jump = max_visible / 2;
                agent_state.help_scroll_offset = @min(agent_state.help_scroll_offset + jump, max_scroll);
                return true;
            }
        },
        'u', 'U' => {
            if (!key.mods.ctrl) {
                const jump = max_visible / 2;
                if (agent_state.help_scroll_offset >= jump) {
                    agent_state.help_scroll_offset -= jump;
                } else {
                    agent_state.help_scroll_offset = 0;
                }
                return true;
            }
        },
        'g' => {
            agent_state.help_scroll_offset = 0;
            return true;
        },
        'G' => {
            agent_state.help_scroll_offset = max_scroll;
            return true;
        },
        'q', '?' => {
            agent_state.help_visible = false;
            agent_state.help_scroll_offset = 0;
            return true;
        },
        else => {},
    }

    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'd' => {
                const jump = max_visible / 2;
                agent_state.help_scroll_offset = @min(agent_state.help_scroll_offset + jump, max_scroll);
                return true;
            },
            'u' => {
                const jump = max_visible / 2;
                if (agent_state.help_scroll_offset >= jump) {
                    agent_state.help_scroll_offset -= jump;
                } else {
                    agent_state.help_scroll_offset = 0;
                }
                return true;
            },
            else => {},
        }
    }

    if (key.codepoint == 27) {
        agent_state.help_visible = false;
        agent_state.help_scroll_offset = 0;
        return true;
    }

    if (key.matches(vaxis.Key.down, .{})) {
        if (agent_state.help_scroll_offset < max_scroll) {
            agent_state.help_scroll_offset += 1;
        }
        return true;
    } else if (key.matches(vaxis.Key.up, .{})) {
        if (agent_state.help_scroll_offset > 0) {
            agent_state.help_scroll_offset -= 1;
        }
        return true;
    }

    return true;
}

const Binding = struct {
    key: []const u8,
    desc: []const u8,
};

const ContentLine = struct {
    section: ?[]const u8 = null,
    key: ?[]const u8 = null,
    desc: ?[]const u8 = null,
    key_style: ?vaxis.Style = null,
    desc_style: ?vaxis.Style = null,
    blank: bool = false,
};
