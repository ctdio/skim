const std = @import("std");
const vaxis = @import("vaxis");

const App = @import("app.zig").App;
const Color = @import("rendering/common.zig").Color;
const FrameChars = @import("rendering/common.zig").FrameChars;

const KEY_COL_WIDTH: usize = 14; // Fixed width for key column alignment

pub fn renderHelpPopup(app: *App, win: vaxis.Window) !void {
    // Calculate popup dimensions - larger for help content
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
    const title = " Keybindings ";
    const title_x = if (popup_width > title.len) (popup_width - title.len) / 2 else 1;
    var title_seg = [_]vaxis.Cell.Segment{.{ .text = title, .style = title_style }};
    _ = popup_win.print(&title_seg, .{ .row_offset = 0, .col_offset = @intCast(title_x) });

    // Build scrollable content
    var content_lines: std.ArrayList(ContentLine) = .{};
    defer content_lines.deinit(app.allocator);

    const section_style = vaxis.Style{ .fg = Color.yellow, .bg = Color.dialog_bg, .bold = true };
    const key_style = vaxis.Style{ .fg = Color.cyan, .bg = Color.dialog_bg };
    const desc_style = vaxis.Style{ .fg = Color.white, .bg = Color.dialog_bg };

    // NORMAL MODE section
    try content_lines.append(app.allocator, .{ .section = "NORMAL MODE" });

    const core_bindings = [_]Binding{
        .{ .key = "h / l", .desc = "Previous / next file" },
        .{ .key = "j / k", .desc = "Cursor down / up" },
        .{ .key = "g / G", .desc = "Jump to top / bottom" },
        .{ .key = "Ctrl-d / u", .desc = "Page down / up" },
        .{ .key = "Ctrl-n", .desc = "Next file" },
        .{ .key = "M", .desc = "Center cursor in viewport" },
        .{ .key = "zz", .desc = "Center viewport on cursor" },
        .{ .key = "[h / ]h", .desc = "Previous / next hunk" },
        .{ .key = "[c / ]c", .desc = "Previous / next comment" },
        .{ .key = "{ / }", .desc = "Previous / next empty line" },
        .{ .key = "/", .desc = "Search" },
        .{ .key = "n / N", .desc = "Next / previous match" },
        .{ .key = "Ctrl-p", .desc = "File picker" },
        .{ .key = ":", .desc = "Command palette" },
        .{ .key = "?", .desc = "This help" },
        .{ .key = "Enter", .desc = "Add / edit comment" },
        .{ .key = "d / D", .desc = "Delete comment / all" },
        .{ .key = "y", .desc = "Yank comment" },
        .{ .key = "Y", .desc = "Yank all comments" },
        .{ .key = "v / V", .desc = "Visual mode" },
        .{ .key = "s", .desc = "Toggle side-by-side" },
        .{ .key = "Tab", .desc = "Cycle hunk filter" },
        .{ .key = "Ctrl-e", .desc = "Toggle agent panel" },
        .{ .key = "gY", .desc = "Send comments to agent" },
        .{ .key = "Ctrl-w h/l", .desc = "Focus diff / agent" },
        .{ .key = "r", .desc = "Refresh diff" },
        .{ .key = "Ctrl-g", .desc = "Open in $EDITOR" },
        .{ .key = "Ctrl-C ×2", .desc = "Force quit" },
    };
    for (core_bindings) |b| {
        try content_lines.append(app.allocator, .{ .key = b.key, .desc = b.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .blank = true });

    // SEARCH MODE
    try content_lines.append(app.allocator, .{ .section = "SEARCH MODE" });
    const search_bindings = [_]Binding{
        .{ .key = "<type>", .desc = "Search query (smart case)" },
        .{ .key = "Enter", .desc = "Execute search" },
        .{ .key = "Esc", .desc = "Cancel" },
    };
    for (search_bindings) |b| {
        try content_lines.append(app.allocator, .{ .key = b.key, .desc = b.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .blank = true });

    // COMMAND PALETTE
    try content_lines.append(app.allocator, .{ .section = "COMMAND PALETTE" });
    const palette_bindings = [_]Binding{
        .{ .key = "<type>", .desc = "Filter files" },
        .{ .key = ">", .desc = "Switch to command mode" },
        .{ .key = "↑ / ↓", .desc = "Navigate" },
        .{ .key = "Enter", .desc = "Execute" },
        .{ .key = "Esc", .desc = "Cancel" },
    };
    for (palette_bindings) |b| {
        try content_lines.append(app.allocator, .{ .key = b.key, .desc = b.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .blank = true });

    // VISUAL MODE
    try content_lines.append(app.allocator, .{ .section = "VISUAL MODE" });
    const visual_bindings = [_]Binding{
        .{ .key = "j / k", .desc = "Extend selection" },
        .{ .key = "y", .desc = "Yank selection" },
        .{ .key = "v / Esc", .desc = "Exit" },
    };
    for (visual_bindings) |b| {
        try content_lines.append(app.allocator, .{ .key = b.key, .desc = b.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .blank = true });

    // COMMENT MODE
    try content_lines.append(app.allocator, .{ .section = "COMMENT MODE" });
    const comment_bindings = [_]Binding{
        .{ .key = "Enter", .desc = "Save comment" },
        .{ .key = "Ctrl-j", .desc = "Insert newline" },
        .{ .key = "Esc", .desc = "Cancel" },
        .{ .key = "i/a/I/A", .desc = "Insert modes" },
        .{ .key = "h/j/k/l", .desc = "Move cursor" },
        .{ .key = "w/b/e", .desc = "Word motions" },
        .{ .key = "0 / $", .desc = "Line start / end" },
        .{ .key = "x / dd", .desc = "Delete char / line" },
    };
    for (comment_bindings) |b| {
        try content_lines.append(app.allocator, .{ .key = b.key, .desc = b.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(app.allocator, .{ .blank = true });

    // AGENT MODE
    try content_lines.append(app.allocator, .{ .section = "AGENT MODE" });
    const agent_bindings = [_]Binding{
        .{ .key = "Ctrl-e", .desc = "Close panel" },
        .{ .key = "Ctrl-l", .desc = "Clear history" },
        .{ .key = "Ctrl-d / u", .desc = "Page down / up" },
        .{ .key = "Ctrl-t", .desc = "Toggle todo list" },
        .{ .key = "Ctrl-w o", .desc = "Toggle fullscreen" },
        .{ .key = "gg / G", .desc = "Top / bottom" },
        .{ .key = "?", .desc = "Agent help (detailed)" },
    };
    for (agent_bindings) |b| {
        try content_lines.append(app.allocator, .{ .key = b.key, .desc = b.desc, .key_style = key_style, .desc_style = desc_style });
    }

    // Calculate scroll bounds
    const content_start_row: usize = 2; // After top border + 1 row padding
    const content_end_row = popup_height -| 2; // Before bottom border + footer
    const max_visible = content_end_row -| content_start_row;
    const scroll_offset = app.state.help_scroll_offset;
    const total_rows = content_lines.items.len;
    const visible_start = scroll_offset;
    const visible_end = @min(visible_start + max_visible, total_rows);

    // Render content
    var row: usize = content_start_row;
    for (visible_start..visible_end) |idx| {
        if (row >= content_end_row) break;
        const line = content_lines.items[idx];

        if (line.section) |section| {
            // Section header with underline effect
            var sec_seg = [_]vaxis.Cell.Segment{.{ .text = section, .style = section_style }};
            _ = popup_win.print(&sec_seg, .{ .row_offset = @intCast(row), .col_offset = 2 });
        } else if (line.key) |key| {
            // Keybinding row with aligned columns
            renderKeyBinding(app, popup_win, @intCast(row), key, line.desc.?, line.key_style.?, line.desc_style.?);
        }
        // Blank lines just advance row
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

fn renderKeyBinding(app: *App, win: vaxis.Window, row: u16, key: []const u8, desc: []const u8, key_style: vaxis.Style, desc_style: vaxis.Style) void {
    _ = app;
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
