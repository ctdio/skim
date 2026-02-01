const std = @import("std");
const vaxis = @import("vaxis");
const parser = @import("../git/parser.zig");
const rendering_common = @import("common.zig");
const render_utils = @import("utils.zig");
const state_helpers = @import("../state.zig");

const App = @import("../app.zig").App;
const Color = rendering_common.Color;
const Layout = rendering_common.Layout;
const RenderUtils = render_utils.RenderUtils;
const StateHelpers = state_helpers.StateHelpers;

pub const FileHeader = struct {
    /// Render a minimal file header block
    /// Format: "▶ path/to/file.ext  +42 -15" (folded) or "▼ path/to/file.ext  +42 -15" (expanded)
    /// Returns the number of rows used (always 1)
    pub fn render(
        app: *App,
        win: vaxis.Window,
        file: *const parser.FileDiff,
        file_idx: usize,
        row: usize,
        is_cursor: bool,
    ) !usize {
        if (row >= win.height) return 0;

        const stats = StateHelpers.calculateDiffStats(app, file);
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;
        const is_folded = app.isFileFolded(file_idx);

        // Fold indicator: ▶ for folded, ▼ for expanded
        const fold_indicator = if (is_folded) "▶ " else "▼ ";

        // Build header segments with different colors
        var buf_path: [1024]u8 = undefined;
        var buf_add: [64]u8 = undefined;
        var buf_del: [64]u8 = undefined;
        var buf_lines: [64]u8 = undefined;

        const path_text = try std.fmt.bufPrint(&buf_path, "{s}  ", .{file_path});
        const add_text = try std.fmt.bufPrint(&buf_add, "+{d} ", .{stats.additions});
        const del_text = try std.fmt.bufPrint(&buf_del, "-{d}", .{stats.deletions});

        // Line count hint for folded files
        const lines_text = if (is_folded) blk: {
            const line_count = app.getFileLineCount(file_idx);
            break :blk try std.fmt.bufPrint(&buf_lines, "  [{d} lines]", .{line_count});
        } else "";

        const fold_copy = try RenderUtils.copyFrameText(app, fold_indicator);
        const path_copy = try RenderUtils.copyFrameText(app, path_text);
        const add_copy = try RenderUtils.copyFrameText(app, add_text);
        const del_copy = try RenderUtils.copyFrameText(app, del_text);
        const lines_copy = try RenderUtils.copyFrameText(app, lines_text);

        // Styles: dim for fold indicator, bright white for path, green for additions, red for deletions
        // If cursor is on this line, use cursor background for all
        const fold_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.dim_gray, .bg = Color.cursor_bg }
        else
            .{ .fg = Color.dim_gray };

        const path_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.white, .bg = Color.cursor_bg, .bold = true }
        else
            .{ .fg = Color.white, .bold = true };

        const add_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.diff_sign_add, .bg = Color.cursor_bg }
        else
            .{ .fg = Color.diff_sign_add };

        const del_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.diff_sign_delete, .bg = Color.cursor_bg }
        else
            .{ .fg = Color.diff_sign_delete };

        // Style for untracked indicator (yellow/warning color)
        const untracked_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.yellow, .bg = Color.cursor_bg }
        else
            .{ .fg = Color.yellow };

        // Style for line count hint (dim)
        const lines_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.dim_gray, .bg = Color.cursor_bg }
        else
            .{ .fg = Color.dim_gray };

        const untracked_text = if (file.is_untracked)
            try RenderUtils.copyFrameText(app, "  [untracked]")
        else
            "";

        if (file.is_untracked) {
            var segments = [_]vaxis.Cell.Segment{
                .{ .text = fold_copy, .style = fold_style },
                .{ .text = path_copy, .style = path_style },
                .{ .text = add_copy, .style = add_style },
                .{ .text = del_copy, .style = del_style },
                .{ .text = untracked_text, .style = untracked_style },
                .{ .text = lines_copy, .style = lines_style },
            };
            _ = win.print(&segments, .{
                .row_offset = @intCast(row),
                .col_offset = 0,
            });
        } else {
            var segments = [_]vaxis.Cell.Segment{
                .{ .text = fold_copy, .style = fold_style },
                .{ .text = path_copy, .style = path_style },
                .{ .text = add_copy, .style = add_style },
                .{ .text = del_copy, .style = del_style },
                .{ .text = lines_copy, .style = lines_style },
            };
            _ = win.print(&segments, .{
                .row_offset = @intCast(row),
                .col_offset = 0,
            });
        }

        return 1; // Always uses 1 row
    }
};
