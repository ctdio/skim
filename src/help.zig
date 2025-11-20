const std = @import("std");
const vaxis = @import("vaxis");

const App = @import("app.zig").App;

pub fn renderHelpPopup(_: *App, win: vaxis.Window) !void {
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

    var row: usize = 0;

    // Title
    const title = "Skim - Keybindings";
    const title_style = vaxis.Style{
        .fg = .{ .index = 6 }, // cyan
        .bold = true,
    };
    var title_segments = [_]vaxis.Cell.Segment{
        .{ .text = title, .style = title_style },
    };
    _ = try popup_win.print(&title_segments, .{ .row_offset = row });
    row += 1;

    // Separator
    var sep_text: [80]u8 = undefined;
    for (0..@min(popup_width - 2, sep_text.len)) |i| {
        sep_text[i] = '-';
    }
    var sep_segments = [_]vaxis.Cell.Segment{
        .{ .text = sep_text[0..@min(popup_width - 2, sep_text.len)], .style = .{ .fg = .{ .index = 8 } } },
    };
    _ = try popup_win.print(&sep_segments, .{ .row_offset = row });
    row += 1;

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

    // Helper function to print a keybinding line
    const KeyBinding = struct {
        key: []const u8,
        desc: []const u8,
    };

    // NORMAL MODE section
    var normal_header = [_]vaxis.Cell.Segment{
        .{ .text = "NORMAL MODE", .style = section_style },
    };
    _ = try popup_win.print(&normal_header, .{ .row_offset = row });
    row += 1;

    const normal_bindings = [_]KeyBinding{
        .{ .key = "h/l", .desc = "Previous/Next file" },
        .{ .key = "j/k", .desc = "Cursor down/up" },
        .{ .key = "g/G", .desc = "Jump to top/bottom" },
        .{ .key = "Ctrl-d/u", .desc = "Page down/up" },
        .{ .key = "Ctrl-n", .desc = "Next file" },
        .{ .key = "Shift-M", .desc = "Center cursor in viewport" },
        .{ .key = "zz", .desc = "Center viewport on cursor" },
        .{ .key = "[h/]h", .desc = "Previous/Next hunk" },
        .{ .key = "[c/]c", .desc = "Previous/Next comment" },
        .{ .key = "{/}", .desc = "Previous/Next empty line" },
        .{ .key = "/", .desc = "Enter search mode" },
        .{ .key = "n/N", .desc = "Next/Previous search match" },
        .{ .key = "Ctrl-p", .desc = "Open file palette" },
        .{ .key = ":", .desc = "Open command palette" },
        .{ .key = "?", .desc = "Show this help" },
        .{ .key = "Enter", .desc = "Add/edit comment" },
        .{ .key = "d/D", .desc = "Delete comment / Clear all" },
        .{ .key = "y", .desc = "Yank comments to clipboard" },
        .{ .key = "v/V", .desc = "Enter visual mode" },
        .{ .key = "s", .desc = "Toggle unified/side-by-side" },
        .{ .key = "Tab/Shift-Tab", .desc = "Cycle hunk view mode" },
        .{ .key = "r", .desc = "Refresh diff" },
        .{ .key = "Ctrl-g", .desc = "Open file in $EDITOR" },
        .{ .key = "Ctrl-C x2", .desc = "Force quit" },
    };

    for (normal_bindings) |binding| {
        var segments = [_]vaxis.Cell.Segment{
            .{ .text = "  ", .style = .{} },
            .{ .text = binding.key, .style = key_style },
            .{ .text = "  ", .style = .{} },
            .{ .text = binding.desc, .style = desc_style },
        };
        _ = try popup_win.print(&segments, .{ .row_offset = row });
        row += 1;
    }
    row += 1;

    // SEARCH MODE section
    var search_header = [_]vaxis.Cell.Segment{
        .{ .text = "SEARCH MODE", .style = section_style },
    };
    _ = try popup_win.print(&search_header, .{ .row_offset = row });
    row += 1;

    const search_bindings = [_]KeyBinding{
        .{ .key = "Type", .desc = "Enter search query (smart case)" },
        .{ .key = "Enter", .desc = "Execute search" },
        .{ .key = "ESC", .desc = "Cancel search" },
        .{ .key = "Backspace", .desc = "Delete character" },
    };

    for (search_bindings) |binding| {
        var segments = [_]vaxis.Cell.Segment{
            .{ .text = "  ", .style = .{} },
            .{ .text = binding.key, .style = key_style },
            .{ .text = "  ", .style = .{} },
            .{ .text = binding.desc, .style = desc_style },
        };
        _ = try popup_win.print(&segments, .{ .row_offset = row });
        row += 1;
    }
    row += 1;

    // COMMAND PALETTE section
    var palette_header = [_]vaxis.Cell.Segment{
        .{ .text = "COMMAND PALETTE", .style = section_style },
    };
    _ = try popup_win.print(&palette_header, .{ .row_offset = row });
    row += 1;

    const palette_bindings = [_]KeyBinding{
        .{ .key = "Type", .desc = "Filter files (default mode)" },
        .{ .key = ">", .desc = "Prefix to switch to command mode" },
        .{ .key = "Up/Down", .desc = "Navigate selection" },
        .{ .key = "Ctrl-p/n", .desc = "Navigate selection (vim)" },
        .{ .key = "Enter", .desc = "Execute command" },
        .{ .key = "ESC", .desc = "Cancel" },
    };

    for (palette_bindings) |binding| {
        var segments = [_]vaxis.Cell.Segment{
            .{ .text = "  ", .style = .{} },
            .{ .text = binding.key, .style = key_style },
            .{ .text = "  ", .style = .{} },
            .{ .text = binding.desc, .style = desc_style },
        };
        _ = try popup_win.print(&segments, .{ .row_offset = row });
        row += 1;
    }
    row += 1;

    // VISUAL MODE section
    var visual_header = [_]vaxis.Cell.Segment{
        .{ .text = "VISUAL MODE", .style = section_style },
    };
    _ = try popup_win.print(&visual_header, .{ .row_offset = row });
    row += 1;

    const visual_bindings = [_]KeyBinding{
        .{ .key = "j/k", .desc = "Extend selection" },
        .{ .key = "y", .desc = "Yank selection" },
        .{ .key = "v/ESC", .desc = "Exit visual mode" },
    };

    for (visual_bindings) |binding| {
        var segments = [_]vaxis.Cell.Segment{
            .{ .text = "  ", .style = .{} },
            .{ .text = binding.key, .style = key_style },
            .{ .text = "  ", .style = .{} },
            .{ .text = binding.desc, .style = desc_style },
        };
        _ = try popup_win.print(&segments, .{ .row_offset = row });
        row += 1;
    }
    row += 1;

    // COMMENT MODE section
    var comment_header = [_]vaxis.Cell.Segment{
        .{ .text = "COMMENT MODE", .style = section_style },
    };
    _ = try popup_win.print(&comment_header, .{ .row_offset = row });
    row += 1;

    const comment_bindings = [_]KeyBinding{
        .{ .key = "Enter", .desc = "Save comment" },
        .{ .key = "Shift-Enter", .desc = "Insert newline" },
        .{ .key = "ESC", .desc = "Cancel" },
        .{ .key = "Vim keybindings", .desc = "Full vim editing supported" },
    };

    for (comment_bindings) |binding| {
        var segments = [_]vaxis.Cell.Segment{
            .{ .text = "  ", .style = .{} },
            .{ .text = binding.key, .style = key_style },
            .{ .text = "  ", .style = .{} },
            .{ .text = binding.desc, .style = desc_style },
        };
        _ = try popup_win.print(&segments, .{ .row_offset = row });
        row += 1;
    }

    // Footer
    row += 1;
    var footer_segments = [_]vaxis.Cell.Segment{
        .{ .text = "Press ? or ESC to close", .style = .{ .fg = .{ .index = 8 } } },
    };
    _ = try popup_win.print(&footer_segments, .{ .row_offset = row });
}
