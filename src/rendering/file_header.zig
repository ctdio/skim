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
    /// Format: "  path/to/file.ext  +42 -15"
    /// Returns the number of rows used (always 1)
    pub fn render(
        app: *App,
        win: vaxis.Window,
        file: *const parser.FileDiff,
        row: usize,
        is_cursor: bool,
    ) !usize {
        if (row >= win.height) return 0;

        const stats = StateHelpers.calculateDiffStats(app, file);
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

        // Build header segments with different colors
        var buf_path: [1024]u8 = undefined;
        var buf_add: [64]u8 = undefined;
        var buf_del: [64]u8 = undefined;

        const path_text = try std.fmt.bufPrint(&buf_path, "  {s}  ", .{file_path});
        const add_text = try std.fmt.bufPrint(&buf_add, "+{d} ", .{stats.additions});
        const del_text = try std.fmt.bufPrint(&buf_del, "-{d}", .{stats.deletions});

        const path_copy = try RenderUtils.copyFrameText(app, path_text);
        const add_copy = try RenderUtils.copyFrameText(app, add_text);
        const del_copy = try RenderUtils.copyFrameText(app, del_text);

        // Styles: bright white for path, green for additions, red for deletions
        // If cursor is on this line, use cursor background for all
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

        var segments = [_]vaxis.Cell.Segment{
            .{ .text = path_copy, .style = path_style },
            .{ .text = add_copy, .style = add_style },
            .{ .text = del_copy, .style = del_style },
        };

        _ = try win.print(&segments, .{
            .row_offset = row,
            .col_offset = Layout.sidebar_width,
        });

        return 1; // Always uses 1 row
    }
};
