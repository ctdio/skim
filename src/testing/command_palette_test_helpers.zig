const std = @import("std");
const vaxis = @import("vaxis");

// Color constants (matching rendering/common.zig)
const Color = struct {
    const cyan: vaxis.Cell.Color = .{ .index = 6 };
    const white: vaxis.Cell.Color = .{ .index = 7 };
    const green: vaxis.Cell.Color = .{ .index = 2 };
    const red: vaxis.Cell.Color = .{ .index = 1 };
    const yellow: vaxis.Cell.Color = .{ .index = 3 };
    const dim_gray: vaxis.Cell.Color = .{ .index = 8 };
    const dim: vaxis.Cell.Color = .{ .rgb = [3]u8{ 100, 100, 100 } };
    const dialog_bg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 22, 22, 22 } };
};

const DIALOG_PADDING: usize = 1;

// =============================================================================
// Data Types
// =============================================================================

pub const FileEntry = struct {
    display_name: []const u8,
    description: []const u8 = "",
    additions: usize = 0,
    deletions: usize = 0,
};

pub const FilePaletteConfig = struct {
    files: []const FileEntry,
    selected_index: usize = 0,
    search_query: []const u8 = "",
    total_files: usize = 0,
    total_additions: usize = 0,
    total_deletions: usize = 0,
};

// =============================================================================
// Rendering
// =============================================================================

/// Fill window with dialog background color
fn fillBackground(win: vaxis.Window) void {
    const bg_cell = vaxis.Cell{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .bg = Color.dialog_bg },
    };
    win.fill(bg_cell);
}

/// Render a file dialog matching the real command palette "Go to File" layout.
/// Standalone test helper that doesn't require an App.
pub fn renderFilePalette(win: vaxis.Window, config: FilePaletteConfig, frame_alloc: std.mem.Allocator) void {
    fillBackground(win);

    // Row PADDING: Title with stats
    var title_buf: [256]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Go to File ({d} files, +{d}, -{d})", .{
        config.total_files,
        config.total_additions,
        config.total_deletions,
    }) catch "Go to File";

    var title_seg = [_]vaxis.Cell.Segment{.{
        .text = title,
        .style = .{ .fg = Color.cyan, .bg = Color.dialog_bg, .bold = true },
    }};
    _ = win.print(&title_seg, .{ .row_offset = @intCast(DIALOG_PADDING), .col_offset = @intCast(DIALOG_PADDING) });

    // Row PADDING+1: Input with "/ " prompt
    const query = config.search_query;
    var input_seg = [_]vaxis.Cell.Segment{
        .{ .text = "/ ", .style = .{ .fg = Color.yellow, .bg = Color.dialog_bg } },
        .{ .text = if (query.len > 0) query else "", .style = .{ .fg = Color.white, .bg = Color.dialog_bg } },
    };
    _ = win.print(&input_seg, .{ .row_offset = @intCast(DIALOG_PADDING + 1), .col_offset = @intCast(DIALOG_PADDING) });

    // Row PADDING+2: Separator line
    if (win.width > DIALOG_PADDING * 2) {
        const sep_width = win.width - (DIALOG_PADDING * 2);
        const sep_text = frame_alloc.alloc(u8, sep_width) catch return;
        @memset(sep_text, '-');
        var sep_seg = [_]vaxis.Cell.Segment{.{
            .text = sep_text,
            .style = .{ .fg = Color.dim_gray, .bg = Color.dialog_bg },
        }};
        _ = win.print(&sep_seg, .{ .row_offset = @intCast(DIALOG_PADDING + 2), .col_offset = @intCast(DIALOG_PADDING) });
    }

    // Row PADDING+3+: File items
    if (config.files.len == 0) {
        var no_seg = [_]vaxis.Cell.Segment{.{
            .text = "No matching commands",
            .style = .{ .fg = Color.dim_gray, .bg = Color.dialog_bg },
        }};
        _ = win.print(&no_seg, .{ .row_offset = @intCast(DIALOG_PADDING + 3), .col_offset = @intCast(DIALOG_PADDING) });
    } else {
        for (config.files, 0..) |file, i| {
            const row = DIALOG_PADDING + 3 + i;
            if (row >= win.height - DIALOG_PADDING) break;

            const is_selected = i == config.selected_index;

            // Selection indicator
            const indicator = if (is_selected) "▶ " else "  ";
            const indicator_style = vaxis.Style{
                .fg = if (is_selected) Color.cyan else Color.dim_gray,
                .bg = Color.dialog_bg,
            };

            // File name
            const name_style = vaxis.Style{
                .fg = if (is_selected) Color.white else Color.white,
                .bg = Color.dialog_bg,
                .bold = is_selected,
            };

            // Description
            const desc_style = vaxis.Style{
                .fg = Color.dim_gray,
                .bg = Color.dialog_bg,
            };

            var segments_buf: [8]vaxis.Cell.Segment = undefined;
            var seg_count: usize = 0;

            segments_buf[seg_count] = .{ .text = indicator, .style = indicator_style };
            seg_count += 1;
            segments_buf[seg_count] = .{ .text = file.display_name, .style = name_style };
            seg_count += 1;

            if (file.description.len > 0) {
                segments_buf[seg_count] = .{ .text = "  ", .style = .{ .bg = Color.dialog_bg } };
                seg_count += 1;
                segments_buf[seg_count] = .{ .text = file.description, .style = desc_style };
                seg_count += 1;
            }

            _ = win.print(segments_buf[0..seg_count], .{ .row_offset = @intCast(row), .col_offset = @intCast(DIALOG_PADDING) });
        }
    }
}
