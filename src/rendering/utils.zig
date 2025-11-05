const std = @import("std");
const vaxis = @import("vaxis");
const parser = @import("../git/parser.zig");
const rendering_common = @import("common.zig");

const App = @import("../app.zig").App;
const Color = rendering_common.Color;
const FrameChars = rendering_common.FrameChars;

pub const RenderUtils = struct {
    // Frame buffer management
    pub fn resetFrameTextBuffer(app: *App) void {
        app.frame_text_used = 0;
    }

    pub fn remainingFrameTextCapacity(app: *App) usize {
        return app.frame_text_buffer.len - app.frame_text_used;
    }

    pub fn frameTextSlice(app: *App, len: usize) ![]u8 {
        if (len == 0) return app.frame_text_buffer[0..0];
        if (len > remainingFrameTextCapacity(app)) return error.FrameTextBufferOverflow;

        const start = app.frame_text_used;
        const end = start + len;
        app.frame_text_used = end;
        return app.frame_text_buffer[start..end];
    }

    pub fn copyFrameText(app: *App, text: []const u8) ![]const u8 {
        const slice = try frameTextSlice(app, text.len);
        if (text.len > 0) {
            @memcpy(slice, text);
        }
        return slice;
    }

    pub fn padTextForCursor(app: *App, text: []const u8, width: usize, is_cursor: bool) ![]const u8 {
        if (!is_cursor) return text;

        if (width > remainingFrameTextCapacity(app)) return error.FrameTextBufferOverflow;

        const slice = try frameTextSlice(app, width);
        const copy_len = @min(text.len, slice.len);

        if (copy_len > 0) {
            @memcpy(slice[0..copy_len], text[0..copy_len]);
        }
        if (copy_len < slice.len) {
            @memset(slice[copy_len..], ' ');
        }

        return slice;
    }

    pub fn getLineStyle(_: *App, line_type: parser.Line.LineType) vaxis.Style {
        return switch (line_type) {
            .add => .{ .bg = Color.diff_add_bg, .fg = Color.diff_add_fg },
            .delete => .{ .bg = Color.diff_delete_bg, .fg = Color.diff_delete_fg },
            .context => .{},
        };
    }

    pub fn renderGutter(
        app: *App,
        win: vaxis.Window,
        line_idx: usize,
        row: usize,
        is_cursor: bool,
        show_number: bool,
        file_lineno: ?u32,
        line_type: ?parser.Line.LineType,
        gutter_width: usize,
    ) !void {
        _ = line_idx; // No longer used, but kept for API compatibility

        const base_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.white, .bg = Color.dim }
        else
            .{ .fg = Color.dim };

        // Style for empty gutter (applies diff background for wrapped lines)
        const empty_gutter_style: vaxis.Style = if (line_type) |lt| switch (lt) {
            .add => if (is_cursor)
                .{ .fg = Color.dim, .bg = Color.cursor_bg }
            else
                .{ .fg = Color.dim, .bg = Color.diff_add_bg },
            .delete => if (is_cursor)
                .{ .fg = Color.dim, .bg = Color.cursor_bg }
            else
                .{ .fg = Color.dim, .bg = Color.diff_delete_bg },
            .context => base_style,
        } else base_style;

        if (show_number) {
            if (file_lineno) |lineno| {
                // Show line number and diff sign (GitHub style: number right-justified, sign after)
                const sign: []const u8 = if (line_type) |lt| switch (lt) {
                    .add => "+",
                    .delete => "-",
                    .context => " ",
                } else " ";

                // Format number
                var num_buf: [16]u8 = undefined;
                const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{lineno});
                const num_width = gutter_width - 1; // Reserve 1 char for sign
                const padding_needed = num_width -| num_str.len;

                // Build gutter with right-justified number and sign
                var buf: [32]u8 = undefined;
                var i: usize = 0;
                while (i < padding_needed) : (i += 1) {
                    buf[i] = ' ';
                }
                @memcpy(buf[padding_needed .. padding_needed + num_str.len], num_str);
                const sign_pos = padding_needed + num_str.len;
                @memcpy(buf[sign_pos .. sign_pos + sign.len], sign);

                const gutter_text = try copyFrameText(app, buf[0 .. sign_pos + sign.len]);

                // Color the sign and number based on line type (with matching background)
                const sign_style: vaxis.Style = if (line_type) |lt| switch (lt) {
                    .add => if (is_cursor)
                        .{ .fg = Color.diff_sign_add, .bg = Color.cursor_bg, .bold = true }
                    else
                        .{ .fg = Color.diff_sign_add, .bg = Color.diff_add_bg, .bold = true },
                    .delete => if (is_cursor)
                        .{ .fg = Color.diff_sign_delete, .bg = Color.cursor_bg, .bold = true }
                    else
                        .{ .fg = Color.diff_sign_delete, .bg = Color.diff_delete_bg, .bold = true },
                    .context => if (is_cursor)
                        .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
                    else
                        .{ .fg = Color.dim },
                } else base_style;

                // Apply diff background to number as well for add/delete lines
                const number_style: vaxis.Style = if (line_type) |lt| switch (lt) {
                    .add => if (is_cursor)
                        .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
                    else
                        .{ .fg = Color.diff_sign_add, .bg = Color.diff_add_bg },
                    .delete => if (is_cursor)
                        .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
                    else
                        .{ .fg = Color.diff_sign_delete, .bg = Color.diff_delete_bg },
                    .context => base_style,
                } else base_style;

                // Split into number and sign segments for different colors
                const number_text = gutter_text[0 .. gutter_text.len - 1];
                const sign_text = gutter_text[gutter_text.len - 1 ..];

                var segments = [_]vaxis.Cell.Segment{
                    .{ .text = number_text, .style = number_style },
                    .{ .text = sign_text, .style = sign_style },
                };
                _ = try win.print(&segments, .{ .row_offset = row, .col_offset = 1 });
            } else {
                // For hunk headers or other lines without file line numbers, always show empty gutter
                const spaces_slice = try frameTextSlice(app, gutter_width);
                @memset(spaces_slice, ' ');
                var seg = [_]vaxis.Cell.Segment{.{
                    .text = spaces_slice,
                    .style = base_style,
                }};
                _ = try win.print(&seg, .{ .row_offset = row, .col_offset = 1 });
            }
        } else {
            // For wrapped continuation lines, show empty gutter with diff background
            const spaces_slice = try frameTextSlice(app, gutter_width);
            @memset(spaces_slice, ' ');
            var seg = [_]vaxis.Cell.Segment{.{
                .text = spaces_slice,
                .style = empty_gutter_style,
            }};
            _ = try win.print(&seg, .{ .row_offset = row, .col_offset = 1 });
        }

        // Render spacing after gutter with appropriate diff background color
        const spacing_style: vaxis.Style = if (is_cursor)
            .{ .bg = Color.cursor_bg }
        else if (line_type) |lt| switch (lt) {
            .add => .{ .bg = Color.diff_add_bg },
            .delete => .{ .bg = Color.diff_delete_bg },
            .context => .{},
        } else .{};

        const spacing = try frameTextSlice(app, rendering_common.Layout.gutter_spacing);
        @memset(spacing, ' ');
        var spacing_seg = [_]vaxis.Cell.Segment{.{
            .text = spacing,
            .style = spacing_style,
        }};
        _ = try win.print(&spacing_seg, .{ .row_offset = row, .col_offset = 1 + gutter_width });
    }

    pub fn renderGutterSpacing(
        app: *App,
        win: vaxis.Window,
        row: usize,
        col_offset: usize,
        is_cursor: bool,
        line_type: ?parser.Line.LineType,
    ) !void {
        // Render spacing with the appropriate diff background color
        const spacing_style: vaxis.Style = if (is_cursor)
            .{ .bg = Color.cursor_bg }
        else if (line_type) |lt| switch (lt) {
            .add => .{ .bg = Color.diff_add_bg },
            .delete => .{ .bg = Color.diff_delete_bg },
            .context => .{},
        } else .{};

        const spacing = try frameTextSlice(app, rendering_common.Layout.gutter_spacing);
        @memset(spacing, ' ');
        var spacing_seg = [_]vaxis.Cell.Segment{.{
            .text = spacing,
            .style = spacing_style,
        }};
        _ = try win.print(&spacing_seg, .{ .row_offset = row, .col_offset = col_offset });
    }
};
