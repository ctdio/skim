const std = @import("std");
const vaxis = @import("vaxis");

const App = @import("app.zig").App;

pub fn renderHelpPopup(app: *App, win: vaxis.Window) !void {
    // Calculate popup dimensions - larger for help content
    const popup_width = @min(80, win.width - 4);
    const popup_height = @min(35, win.height - 4);
    const x_offset = if (win.width > popup_width) (win.width - popup_width) / 2 else 0;
    const y_offset = if (win.height > popup_height) (win.height - popup_height) / 2 else 0;

    const popup_win = win.child(.{
        .x_off = x_offset,
        .y_off = y_offset,
        .width = .{ .limit = popup_width },
        .height = .{ .limit = popup_height },
        .border = .{
            .where = .all,
            .style = .{
                .fg = .{ .index = 6 }, // cyan
            },
        },
    });

    popup_win.clear();

    // Fill with solid background to prevent text bleeding
    const bg_cell = vaxis.Cell{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{
            .bg = .{ .index = 0 }, // black background
        },
    };
    popup_win.fill(bg_cell);

    // Build all content lines first
    var content_lines = std.ArrayList(ContentLine).init(app.allocator);
    defer content_lines.deinit();

    // Title
    try content_lines.append(.{ .text = "Skim - Keybindings", .style = .{ .fg = .{ .index = 6 }, .bold = true } });

    // Separator
    try content_lines.append(.{ .text = null, .style = .{}, .is_separator = true });

    const section_style = vaxis.Style{
        .fg = .{ .index = 3 }, // yellow
        .bold = true,
    };
    const key_style = vaxis.Style{
        .fg = .{ .index = 6 }, // cyan
    };
    const desc_style = vaxis.Style{
        .fg = .{ .index = 7 }, // white
    };

    // NORMAL MODE section
    try content_lines.append(.{ .text = "NORMAL MODE", .style = section_style });

    const normal_bindings = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "h/l", .desc = "Previous/Next file" },
        .{ .key = "j/k", .desc = "Cursor down/up" },
        .{ .key = "g/G", .desc = "Jump to top/bottom" },
        .{ .key = "Ctrl-d/u", .desc = "Page down/up" },
        .{ .key = "Ctrl-n", .desc = "Next file" },
        .{ .key = "Shift-M", .desc = "Center cursor in viewport" },
        .{ .key = "zz", .desc = "Center viewport on cursor" },
        .{ .key = "[h/]h", .desc = "Previous/Next code change" },
        .{ .key = "[c/]c", .desc = "Previous/Next comment" },
        .{ .key = "{/}", .desc = "Previous/Next empty line" },
        .{ .key = "/", .desc = "Enter search mode" },
        .{ .key = "n/N", .desc = "Next/Previous search match" },
        .{ .key = "Ctrl-p", .desc = "Open file palette" },
        .{ .key = ":", .desc = "Open command palette" },
        .{ .key = "?", .desc = "Show this help" },
        .{ .key = "Enter", .desc = "Add/edit comment" },
        .{ .key = "d/D", .desc = "Delete comment / Clear all" },
        .{ .key = "y", .desc = "Yank current comment to clipboard" },
        .{ .key = "Y", .desc = "Yank all comments to clipboard" },
        .{ .key = "v/V", .desc = "Enter visual mode" },
        .{ .key = "s", .desc = "Toggle unified/side-by-side" },
        .{ .key = "Tab/Shift-Tab", .desc = "Cycle hunk view mode" },
        .{ .key = "r", .desc = "Refresh diff" },
        .{ .key = "Ctrl-g", .desc = "Open file in $EDITOR" },
        .{ .key = "Ctrl-C x2", .desc = "Force quit" },
    };

    for (normal_bindings) |binding| {
        try content_lines.append(.{ .key = binding.key, .desc = binding.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(.{ .text = "", .style = .{} }); // Blank line

    // SEARCH MODE section
    try content_lines.append(.{ .text = "SEARCH MODE", .style = section_style });

    const search_bindings = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "Type", .desc = "Enter search query (smart case)" },
        .{ .key = "Enter", .desc = "Execute search" },
        .{ .key = "ESC", .desc = "Cancel search" },
        .{ .key = "Backspace", .desc = "Delete character" },
    };

    for (search_bindings) |binding| {
        try content_lines.append(.{ .key = binding.key, .desc = binding.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(.{ .text = "", .style = .{} }); // Blank line

    // COMMAND PALETTE section
    try content_lines.append(.{ .text = "COMMAND PALETTE", .style = section_style });

    const palette_bindings = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "Type", .desc = "Filter files (default mode)" },
        .{ .key = ">", .desc = "Prefix to switch to command mode" },
        .{ .key = "Up/Down", .desc = "Navigate selection" },
        .{ .key = "Ctrl-p/n", .desc = "Navigate selection (vim)" },
        .{ .key = "Enter", .desc = "Execute command" },
        .{ .key = "ESC", .desc = "Cancel" },
    };

    for (palette_bindings) |binding| {
        try content_lines.append(.{ .key = binding.key, .desc = binding.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(.{ .text = "", .style = .{} }); // Blank line

    // VISUAL MODE section
    try content_lines.append(.{ .text = "VISUAL MODE", .style = section_style });

    const visual_bindings = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "j/k", .desc = "Extend selection" },
        .{ .key = "y", .desc = "Yank selection" },
        .{ .key = "v/ESC", .desc = "Exit visual mode" },
    };

    for (visual_bindings) |binding| {
        try content_lines.append(.{ .key = binding.key, .desc = binding.desc, .key_style = key_style, .desc_style = desc_style });
    }
    try content_lines.append(.{ .text = "", .style = .{} }); // Blank line

    // COMMENT MODE section
    try content_lines.append(.{ .text = "COMMENT MODE", .style = section_style });

    const comment_bindings = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "Enter", .desc = "Save comment" },
        .{ .key = "Shift-Enter", .desc = "Insert newline" },
        .{ .key = "ESC", .desc = "Cancel" },
        .{ .key = "Vim keybindings", .desc = "Full vim editing supported" },
    };

    for (comment_bindings) |binding| {
        try content_lines.append(.{ .key = binding.key, .desc = binding.desc, .key_style = key_style, .desc_style = desc_style });
    }

    // Footer
    try content_lines.append(.{ .text = "", .style = .{} }); // Blank line
    try content_lines.append(.{ .text = "j/k or ↑↓: Scroll  |  Ctrl-d/u: Page down/up  |  g/G: Top/Bottom  |  ? or ESC: Close", .style = .{ .fg = .{ .index = 8 } } });

    // Calculate visible range based on scroll offset
    const scroll_offset = app.state.help_scroll_offset;
    const max_visible_rows = popup_height - 2; // Account for borders
    const total_content_rows = content_lines.items.len;
    const visible_start = scroll_offset;
    const visible_end = @min(visible_start + max_visible_rows, total_content_rows);

    // Show scroll indicator at top if scrolled down
    var current_row: usize = 0;
    if (scroll_offset > 0) {
        const indicator = "▲ (scroll up for more)";
        var indicator_seg = [_]vaxis.Cell.Segment{
            .{ .text = indicator, .style = .{ .fg = .{ .index = 8 } } },
        };
        _ = try popup_win.print(&indicator_seg, .{ .row_offset = current_row });
        current_row += 1;
    }

    // Render visible content
    const render_utils = @import("rendering/utils.zig");
    const RenderUtils = render_utils.RenderUtils;

    for (visible_start..visible_end) |content_idx| {
        if (current_row >= max_visible_rows - 1) break; // Leave room for bottom indicator

        const line = content_lines.items[content_idx];

        if (line.is_separator) {
            // Render separator
            if (popup_width > 2) {
                const sep_width = popup_width - 2;
                const sep_text = try RenderUtils.frameTextSlice(app, sep_width);
                @memset(sep_text, '-');
                var sep_segments = [_]vaxis.Cell.Segment{
                    .{ .text = sep_text, .style = .{ .fg = .{ .index = 8 } } },
                };
                _ = try popup_win.print(&sep_segments, .{ .row_offset = current_row });
            }
        } else if (line.key) |key| {
            // Render keybinding
            var segments = [_]vaxis.Cell.Segment{
                .{ .text = "  ", .style = .{} },
                .{ .text = key, .style = line.key_style.? },
                .{ .text = "  ", .style = .{} },
                .{ .text = line.desc.?, .style = line.desc_style.? },
            };
            _ = try popup_win.print(&segments, .{ .row_offset = current_row });
        } else if (line.text) |text| {
            // Render regular text
            var text_seg = [_]vaxis.Cell.Segment{
                .{ .text = text, .style = line.style },
            };
            _ = try popup_win.print(&text_seg, .{ .row_offset = current_row });
        }

        current_row += 1;
    }

    // Show scroll indicator at bottom if there's more content
    if (visible_end < total_content_rows and current_row < max_visible_rows) {
        const indicator = "▼ (scroll down for more)";
        var indicator_seg = [_]vaxis.Cell.Segment{
            .{ .text = indicator, .style = .{ .fg = .{ .index = 8 } } },
        };
        _ = try popup_win.print(&indicator_seg, .{ .row_offset = current_row });
    }
}

const ContentLine = struct {
    text: ?[]const u8 = null,
    key: ?[]const u8 = null,
    desc: ?[]const u8 = null,
    style: vaxis.Style = .{},
    key_style: ?vaxis.Style = null,
    desc_style: ?vaxis.Style = null,
    is_separator: bool = false,
};
