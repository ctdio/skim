const std = @import("std");
const vaxis = @import("vaxis");
const parser = @import("../git/parser.zig");
const comments = @import("../comments.zig");
const rendering_common = @import("common.zig");

const App = @import("../app.zig").App;
const Color = rendering_common.Color;
const FrameChars = rendering_common.FrameChars;
const Layout = rendering_common.Layout;

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

    /// Render inline comment input box (when in comment mode)
    pub fn renderCommentInputBox(
        app: *App,
        win: vaxis.Window,
        row: usize,
        gutter_width: usize,
    ) !usize {
        if (app.state.active_comment_input == null) return 0;
        if (row + 2 >= win.height) return 0; // Need at least 3 rows

        const input = app.state.active_comment_input.?;
        const content_start = 1 + gutter_width + Layout.gutter_spacing;
        const box_cell_width = (win.width -| content_start) -| 2; // Width in cells (-2 for right border)

        if (box_cell_width < 20) return 0; // Box too narrow

        const box_style: vaxis.Style = .{ .fg = Color.yellow, .bg = Color.dim, .bold = true };
        const text_style: vaxis.Style = .{ .fg = Color.white, .bg = Color.dim };

        // Top border: ╭─ Comment ─────╮
        // Build it as segments for proper rendering
        const label = " Comment ";
        const top_h_count = box_cell_width - 3 - label.len; // -3 for corners+1 horiz, -label

        var segments = std.ArrayList(vaxis.Cell.Segment).init(app.allocator);
        defer segments.deinit();

        // Top line segments
        try segments.append(.{ .text = try copyFrameText(app, FrameChars.top_left), .style = box_style });
        try segments.append(.{ .text = try copyFrameText(app, FrameChars.horizontal), .style = box_style });
        try segments.append(.{ .text = try copyFrameText(app, label), .style = box_style });

        var i: usize = 0;
        while (i < top_h_count) : (i += 1) {
            try segments.append(.{ .text = try copyFrameText(app, FrameChars.horizontal), .style = box_style });
        }
        try segments.append(.{ .text = try copyFrameText(app, FrameChars.top_right), .style = box_style });

        _ = try win.print(segments.items, .{ .row_offset = row, .col_offset = content_start });

        // Content line: │ text │
        segments.clearRetainingCapacity();

        const input_text = input.text_buffer[0..input.text_len];
        const first_line_end = std.mem.indexOfScalar(u8, input_text, '\n') orelse input_text.len;
        const first_line = input_text[0..first_line_end];

        // Build content with padding included (total width = box_cell_width - 2 for borders)
        const content_width = box_cell_width - 2; // -2 for left and right borders
        const display_text = blk: {
            var buf = try frameTextSlice(app, content_width);
            buf[0] = ' '; // Left padding
            const text_len = content_width - 2; // -2 for left and right padding
            const copy_len = @min(first_line.len, text_len);
            if (copy_len > 0) {
                @memcpy(buf[1 .. 1 + copy_len], first_line[0..copy_len]);
            }
            if (1 + copy_len < buf.len) {
                @memset(buf[1 + copy_len ..], ' ');
            }
            break :blk buf;
        };

        try segments.append(.{ .text = try copyFrameText(app, FrameChars.vertical), .style = box_style });
        try segments.append(.{ .text = display_text, .style = text_style });
        try segments.append(.{ .text = try copyFrameText(app, FrameChars.vertical), .style = box_style });

        _ = try win.print(segments.items, .{ .row_offset = row + 1, .col_offset = content_start });

        // Draw cursor on top
        const cursor_visible_pos = if (input.cursor_pos <= first_line_end) input.cursor_pos else first_line_end;
        const text_area_max = content_width - 2; // Max text without padding
        if (cursor_visible_pos < text_area_max) {
            const cursor_col = content_start + 2 + cursor_visible_pos; // +1 for border, +1 for padding
            const cursor_char = if (cursor_visible_pos < first_line.len) first_line[cursor_visible_pos .. cursor_visible_pos + 1] else " ";
            var cursor_seg = [_]vaxis.Cell.Segment{.{
                .text = try copyFrameText(app, cursor_char),
                .style = .{ .fg = Color.black, .bg = Color.white },
            }};
            _ = try win.print(&cursor_seg, .{ .row_offset = row + 1, .col_offset = cursor_col });
        }

        // Bottom border: ╰─ Enter:Save  ESC:Cancel ─╯
        segments.clearRetainingCapacity();

        const help_text = " Enter:Save  ESC:Cancel ";
        const bottom_h_count = box_cell_width - 3 - help_text.len; // -3 for corners+1 horiz, -help_text

        try segments.append(.{ .text = try copyFrameText(app, FrameChars.bottom_left), .style = box_style });
        try segments.append(.{ .text = try copyFrameText(app, FrameChars.horizontal), .style = box_style });
        try segments.append(.{ .text = try copyFrameText(app, help_text), .style = box_style });

        i = 0;
        while (i < bottom_h_count) : (i += 1) {
            try segments.append(.{ .text = try copyFrameText(app, FrameChars.horizontal), .style = box_style });
        }
        try segments.append(.{ .text = try copyFrameText(app, FrameChars.bottom_right), .style = box_style });

        _ = try win.print(segments.items, .{ .row_offset = row + 2, .col_offset = content_start });

        return 3; // Used 3 rows
    }

    /// Render saved comment display box (expanded view)
    pub fn renderCommentDisplay(
        app: *App,
        win: vaxis.Window,
        comment: *const comments.Comment,
        row: usize,
        gutter_width: usize,
    ) !usize {
        const content_start = 1 + gutter_width + Layout.gutter_spacing;
        const box_cell_width = (win.width -| content_start) -| 2; // -2 for right border

        if (box_cell_width < 20) return 0;

        const box_style: vaxis.Style = .{ .fg = Color.cyan, .bg = Color.dim, .bold = true };
        const text_style: vaxis.Style = .{ .fg = Color.white, .bg = Color.dim };

        var segments = std.ArrayList(vaxis.Cell.Segment).init(app.allocator);
        defer segments.deinit();

        // Top border: ╭─ Comment ─────╮
        const label = " Comment ";
        const top_h_count = box_cell_width - 3 - label.len; // -3 for corners+1 horiz, -label

        try segments.append(.{ .text = try copyFrameText(app, FrameChars.top_left), .style = box_style });
        try segments.append(.{ .text = try copyFrameText(app, FrameChars.horizontal), .style = box_style });
        try segments.append(.{ .text = try copyFrameText(app, label), .style = box_style });

        var i: usize = 0;
        while (i < top_h_count) : (i += 1) {
            try segments.append(.{ .text = try copyFrameText(app, FrameChars.horizontal), .style = box_style });
        }
        try segments.append(.{ .text = try copyFrameText(app, FrameChars.top_right), .style = box_style });

        _ = try win.print(segments.items, .{ .row_offset = row, .col_offset = content_start });

        // Split comment text by newlines and render each
        var lines_used: usize = 1;
        const content_width = box_cell_width - 2; // -2 for borders
        var line_iter = std.mem.splitScalar(u8, comment.text, '\n');

        while (line_iter.next()) |text_line| {
            if (row + lines_used >= win.height) break;

            segments.clearRetainingCapacity();

            const display_text = blk: {
                var buf = try frameTextSlice(app, content_width);
                buf[0] = ' '; // Left padding
                const text_len = content_width - 2; // -2 for left and right padding
                const copy_len = @min(text_line.len, text_len);
                if (copy_len > 0) {
                    @memcpy(buf[1 .. 1 + copy_len], text_line[0..copy_len]);
                }
                if (1 + copy_len < buf.len) {
                    @memset(buf[1 + copy_len ..], ' ');
                }
                break :blk buf;
            };

            try segments.append(.{ .text = try copyFrameText(app, FrameChars.vertical), .style = box_style });
            try segments.append(.{ .text = display_text, .style = text_style });
            try segments.append(.{ .text = try copyFrameText(app, FrameChars.vertical), .style = box_style });

            _ = try win.print(segments.items, .{ .row_offset = row + lines_used, .col_offset = content_start });

            lines_used += 1;
        }

        if (row + lines_used >= win.height) return lines_used;

        // Bottom border: ╰─────────────╯
        segments.clearRetainingCapacity();

        const bottom_h_count = box_cell_width - 2; // -2 for corners

        try segments.append(.{ .text = try copyFrameText(app, FrameChars.bottom_left), .style = box_style });

        i = 0;
        while (i < bottom_h_count) : (i += 1) {
            try segments.append(.{ .text = try copyFrameText(app, FrameChars.horizontal), .style = box_style });
        }
        try segments.append(.{ .text = try copyFrameText(app, FrameChars.bottom_right), .style = box_style });

        _ = try win.print(segments.items, .{ .row_offset = row + lines_used, .col_offset = content_start });

        return lines_used + 1;
    }

    /// Check if there's a comment at this file/hunk/line location
    pub fn hasCommentAt(
        app: *App,
        file_path: []const u8,
        hunk_idx: usize,
        line_idx_in_hunk: usize,
    ) bool {
        return app.state.comment_store.hasCommentAt(file_path, hunk_idx, line_idx_in_hunk);
    }

    /// Get comment at this location (returns null if none)
    pub fn getCommentAt(
        app: *App,
        file_path: []const u8,
        hunk_idx: usize,
        line_idx_in_hunk: usize,
    ) ?*const comments.Comment {
        const idx = app.state.comment_store.findCommentAt(file_path, hunk_idx, line_idx_in_hunk) orelse return null;
        return app.state.comment_store.getComment(idx);
    }
};
