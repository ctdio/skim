const std = @import("std");
const vaxis = @import("vaxis");

// Color constants (subset from rendering/common.zig)
const Color = struct {
    const cyan: vaxis.Cell.Color = .{ .index = 6 };
    const yellow: vaxis.Cell.Color = .{ .index = 3 };
    const white: vaxis.Cell.Color = .{ .index = 7 };
    const dim_gray: vaxis.Cell.Color = .{ .index = 8 };
    const dialog_bg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 22, 22, 22 } };
};

// Frame drawing characters
const FrameChars = struct {
    const vertical = "│";
    const horizontal = "─";
    const top_left = "╭";
    const top_right = "╮";
    const bottom_left = "╰";
    const bottom_right = "╯";
};

const KEY_COL_WIDTH: usize = 14;

// =============================================================================
// Rendering Functions
// =============================================================================

/// Draw a box border around the given dimensions
pub fn drawBoxBorder(win: vaxis.Window, width: usize, height: usize) void {
    const style = vaxis.Style{ .fg = Color.dim_gray, .bg = Color.dialog_bg };

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

/// Render a centered title in the top border
pub fn renderTitle(win: vaxis.Window, title: []const u8, width: usize) void {
    const style = vaxis.Style{ .fg = Color.cyan, .bg = Color.dialog_bg, .bold = true };
    const title_x = if (width > title.len) (width - title.len) / 2 else 1;
    var seg = [_]vaxis.Cell.Segment{.{ .text = title, .style = style }};
    _ = win.print(&seg, .{ .row_offset = 0, .col_offset = @intCast(title_x) });
}

/// Render a section header
pub fn renderSection(win: vaxis.Window, name: []const u8, row: u16) void {
    const style = vaxis.Style{ .fg = Color.yellow, .bg = Color.dialog_bg, .bold = true };
    var seg = [_]vaxis.Cell.Segment{.{ .text = name, .style = style }};
    _ = win.print(&seg, .{ .row_offset = row, .col_offset = 2 });
}

/// Render a keybinding line with aligned columns
/// Uses a simpler approach without dynamic padding for test purposes
pub fn renderKeyBinding(win: vaxis.Window, row: u16, key_text: []const u8, desc: []const u8) void {
    const key_style = vaxis.Style{ .fg = Color.cyan, .bg = Color.dialog_bg };
    const desc_style = vaxis.Style{ .fg = Color.white, .bg = Color.dialog_bg };
    const sep_style = vaxis.Style{ .fg = Color.dim_gray, .bg = Color.dialog_bg };

    // Print key (without dynamic padding - test helper simplification)
    var key_seg = [_]vaxis.Cell.Segment{
        .{ .text = "  ", .style = .{ .bg = Color.dialog_bg } },
        .{ .text = key_text, .style = key_style },
    };
    const key_end = win.print(&key_seg, .{ .row_offset = row, .col_offset = 1 });

    // Calculate padding needed to align to column 17 (1 + 2 + 14)
    const pad_col: u16 = 17;
    var col = key_end.col;

    // Write padding spaces
    while (col < pad_col) : (col += 1) {
        win.writeCell(col, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = key_style });
    }

    // Print separator and description
    var desc_seg = [_]vaxis.Cell.Segment{
        .{ .text = " │ ", .style = sep_style },
        .{ .text = desc, .style = desc_style },
    };
    _ = win.print(&desc_seg, .{ .row_offset = row, .col_offset = pad_col });
}

/// Render a centered footer
pub fn renderFooter(win: vaxis.Window, text: []const u8, row: u16, width: usize) void {
    const style = vaxis.Style{ .fg = Color.dim_gray, .bg = Color.dialog_bg };
    const footer_x = if (width > text.len) (width - text.len) / 2 else 1;
    var seg = [_]vaxis.Cell.Segment{.{ .text = text, .style = style }};
    _ = win.print(&seg, .{ .row_offset = row, .col_offset = @intCast(footer_x) });
}

/// Fill window with background color
pub fn fillBackground(win: vaxis.Window) void {
    const bg_cell = vaxis.Cell{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .bg = Color.dialog_bg },
    };
    win.fill(bg_cell);
}

/// Render a complete help popup with bindings
pub fn renderHelpPopup(win: vaxis.Window, title: []const u8, bindings: []const Binding, width: usize, height: usize) void {
    fillBackground(win);
    drawBoxBorder(win, width, height);
    renderTitle(win, title, width);

    var row: u16 = 2;
    for (bindings) |b| {
        if (b.is_section) {
            renderSection(win, b.key, row);
        } else if (!b.is_blank) {
            renderKeyBinding(win, row, b.key, b.desc);
        }
        row += 1;
        if (row >= height - 2) break;
    }

    renderFooter(win, " ? or Esc to close ", @intCast(height - 1), width);
}

// =============================================================================
// Data Types
// =============================================================================

pub const Binding = struct {
    key: []const u8,
    desc: []const u8 = "",
    is_section: bool = false,
    is_blank: bool = false,
};

pub fn section(name: []const u8) Binding {
    return .{ .key = name, .is_section = true };
}

pub fn binding(k: []const u8, d: []const u8) Binding {
    return .{ .key = k, .desc = d };
}

pub fn blank() Binding {
    return .{ .key = "", .is_blank = true };
}
