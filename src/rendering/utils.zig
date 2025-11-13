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
    // Style calculation utilities

    /// Get style for a line based on cursor, visual selection, and line type
    pub fn getDisplayStyle(
        app: *App,
        is_cursor: bool,
        is_in_visual: bool,
        base_style: vaxis.Style,
    ) vaxis.Style {
        if (is_cursor and app.mode == .visual) {
            return .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = true };
        } else if (is_cursor) {
            return .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true };
        } else if (is_in_visual) {
            return .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = false };
        } else {
            return base_style;
        }
    }

    /// Get fill style for backgrounds (e.g., hunk headers)
    pub fn getFillStyle(app: *App, is_cursor: bool, is_in_visual: bool) vaxis.Style {
        if (is_cursor and app.mode == .visual) {
            return .{ .bg = Color.visual_select_bg };
        } else if (is_cursor) {
            return .{ .bg = Color.cursor_bg };
        } else if (is_in_visual) {
            return .{ .bg = Color.visual_select_bg };
        } else {
            return .{};
        }
    }

    /// Get range style for hunk headers (bold text with icons)
    pub fn getHunkRangeStyle(app: *App, is_cursor: bool, is_in_visual: bool) vaxis.Style {
        if (is_cursor and app.mode == .visual) {
            return .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = true };
        } else if (is_cursor) {
            return .{ .fg = Color.white, .bg = Color.cursor_bg, .bold = true };
        } else if (is_in_visual) {
            return .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = true };
        } else {
            return .{ .fg = Color.dim };
        }
    }

    /// Get context style for hunk headers (dimmer text)
    pub fn getHunkContextStyle(app: *App, is_cursor: bool, is_in_visual: bool) vaxis.Style {
        if (is_cursor and app.mode == .visual) {
            return .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg };
        } else if (is_cursor) {
            return .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg };
        } else if (is_in_visual) {
            return .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg };
        } else {
            return .{ .fg = Color.dim };
        }
    }

    // Segment manipulation utilities

    /// Pad segments to full width with trailing spaces
    pub fn padSegments(
        app: *App,
        allocator: std.mem.Allocator,
        segments: []const vaxis.Cell.Segment,
        current_width: usize,
        target_width: usize,
        style: vaxis.Style,
    ) ![]vaxis.Cell.Segment {
        if (current_width >= target_width) return try allocator.dupe(vaxis.Cell.Segment, segments);

        const padded = try allocator.alloc(vaxis.Cell.Segment, segments.len + 1);
        @memcpy(padded[0..segments.len], segments);

        const padding_len = target_width - current_width;
        const padding = try frameTextSlice(app, padding_len);
        @memset(padding, ' ');
        padded[segments.len] = .{
            .text = padding,
            .style = style,
        };

        return padded;
    }

    // Border rendering utilities

    /// Render sidebar border
    pub fn renderSidebar(win: vaxis.Window, row: usize) !void {
        const sidebar_style = .{ .fg = Color.dim };
        var sidebar_seg = [_]vaxis.Cell.Segment{.{
            .text = "┃",
            .style = sidebar_style,
        }};
        _ = try win.print(&sidebar_seg, .{ .row_offset = row, .col_offset = 0 });
    }

    /// Render middle divider for side-by-side view
    pub fn renderMiddleDivider(win: vaxis.Window, row: usize, col: usize) !void {
        const divider_style = .{ .fg = Color.dim };
        var divider_seg = [_]vaxis.Cell.Segment{.{
            .text = FrameChars.vertical,
            .style = divider_style,
        }};
        _ = try win.print(&divider_seg, .{ .row_offset = row, .col_offset = col });
    }

    /// Render continuation row borders (sidebar + optional middle divider)
    pub fn renderContinuationBorders(
        win: vaxis.Window,
        row: usize,
        middle_col: ?usize,
    ) !void {
        try renderSidebar(win, row);
        if (middle_col) |col| {
            try renderMiddleDivider(win, row, col);
        }
    }

    // Hunk header utilities

    /// Build hunk header text
    pub fn buildHunkHeaderText(hunk: parser.Hunk, buf: []u8) ![]const u8 {
        const old_end = hunk.header.old_start + hunk.header.old_count -| 1;
        const new_end = hunk.header.new_start + hunk.header.new_count -| 1;

        return try std.fmt.bufPrint(
            buf,
            "↕ {d}-{d} → {d}-{d}  {s}",
            .{
                hunk.header.old_start,
                old_end,
                hunk.header.new_start,
                new_end,
                hunk.header.context,
            },
        );
    }

    /// Find where the context starts in the hunk header text
    pub fn findHunkHeaderRangeEnd(header_text: []const u8) usize {
        const range_end_marker = "  ";
        const range_end_pos = std.mem.indexOf(u8, header_text, range_end_marker);
        return if (range_end_pos) |pos| pos + range_end_marker.len else header_text.len;
    }

    // Gutter rendering with column offset

    /// Render gutter at a specific column (for side-by-side view)
    pub fn renderGutterAtColumn(
        app: *App,
        win: vaxis.Window,
        row: usize,
        col_offset: usize,
        is_cursor: bool,
        is_in_visual: bool,
        show_number: bool,
        file_lineno: ?u32,
        line_type: ?parser.Line.LineType,
        gutter_width: usize,
    ) !void {
        const base_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
        else if (is_in_visual)
            .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg }
        else
            .{ .fg = Color.dim };

        // Style for empty gutter (applies diff background for wrapped lines)
        const empty_gutter_style: vaxis.Style = if (line_type) |lt| switch (lt) {
            .add => if (is_cursor)
                .{ .fg = Color.dim, .bg = Color.cursor_bg }
            else if (is_in_visual)
                .{ .fg = Color.dim, .bg = Color.visual_select_bg }
            else
                .{ .fg = Color.dim, .bg = Color.diff_add_bg },
            .delete => if (is_cursor)
                .{ .fg = Color.dim, .bg = Color.cursor_bg }
            else if (is_in_visual)
                .{ .fg = Color.dim, .bg = Color.visual_select_bg }
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
                        .{ .fg = Color.green, .bg = Color.cursor_bg, .bold = true }
                    else if (is_in_visual)
                        .{ .fg = Color.green, .bg = Color.visual_select_bg, .bold = true }
                    else
                        .{ .fg = Color.green, .bg = Color.diff_add_bg, .bold = true },
                    .delete => if (is_cursor)
                        .{ .fg = Color.red, .bg = Color.cursor_bg, .bold = true }
                    else if (is_in_visual)
                        .{ .fg = Color.red, .bg = Color.visual_select_bg, .bold = true }
                    else
                        .{ .fg = Color.red, .bg = Color.diff_delete_bg, .bold = true },
                    .context => if (is_cursor)
                        .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
                    else if (is_in_visual)
                        .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = true }
                    else
                        .{ .fg = Color.dim },
                } else base_style;

                // Apply diff background to number as well for add/delete lines
                const number_style: vaxis.Style = if (line_type) |lt| switch (lt) {
                    .add => if (is_cursor)
                        .{ .fg = Color.dim, .bg = Color.cursor_bg }
                    else if (is_in_visual)
                        .{ .fg = Color.dim, .bg = Color.visual_select_bg }
                    else
                        .{ .fg = Color.dim, .bg = Color.diff_add_bg },
                    .delete => if (is_cursor)
                        .{ .fg = Color.dim, .bg = Color.cursor_bg }
                    else if (is_in_visual)
                        .{ .fg = Color.dim, .bg = Color.visual_select_bg }
                    else
                        .{ .fg = Color.dim, .bg = Color.diff_delete_bg },
                    .context => base_style,
                } else base_style;

                // Split into number and sign segments for different colors
                const number_text = gutter_text[0 .. gutter_text.len - 1];
                const sign_text = gutter_text[gutter_text.len - 1 ..];

                var segments = [_]vaxis.Cell.Segment{
                    .{ .text = number_text, .style = number_style },
                    .{ .text = sign_text, .style = sign_style },
                };
                _ = try win.print(&segments, .{ .row_offset = row, .col_offset = col_offset });
            } else {
                if (is_cursor or is_in_visual) {
                    const spaces_slice = try frameTextSlice(app, gutter_width);
                    @memset(spaces_slice, ' ');
                    var seg = [_]vaxis.Cell.Segment{.{
                        .text = spaces_slice,
                        .style = base_style,
                    }};
                    _ = try win.print(&seg, .{ .row_offset = row, .col_offset = col_offset });
                }
            }
        } else {
            // For wrapped continuation lines, show empty gutter with diff background
            const spaces_slice = try frameTextSlice(app, gutter_width);
            @memset(spaces_slice, ' ');
            var seg = [_]vaxis.Cell.Segment{.{
                .text = spaces_slice,
                .style = empty_gutter_style,
            }};
            _ = try win.print(&seg, .{ .row_offset = row, .col_offset = col_offset });
        }

        // Render spacing after gutter with appropriate diff background color
        const spacing_style: vaxis.Style = if (is_cursor)
            .{ .bg = Color.cursor_bg }
        else if (is_in_visual)
            .{ .bg = Color.visual_select_bg }
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
        _ = try win.print(&spacing_seg, .{ .row_offset = row, .col_offset = col_offset + gutter_width });
    }

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
            .add => .{ .bg = Color.diff_add_bg },
            .delete => .{ .bg = Color.diff_delete_bg },
            .context => .{},
        };
    }

    pub fn renderGutter(
        app: *App,
        win: vaxis.Window,
        line_idx: usize,
        row: usize,
        is_cursor_or_visual: bool,
        show_number: bool,
        file_lineno: ?u32,
        line_type: ?parser.Line.LineType,
        gutter_width: usize,
    ) !void {
        _ = line_idx; // No longer used, but kept for API compatibility

        // Check if we're in visual mode to use visual colors
        const is_visual = app.mode == .visual and is_cursor_or_visual;
        const is_cursor = !is_visual and is_cursor_or_visual;

        const base_style: vaxis.Style = if (is_visual)
            .{ .fg = Color.white, .bg = Color.visual_select_bg }
        else if (is_cursor)
            .{ .fg = Color.white, .bg = Color.dim }
        else
            .{ .fg = Color.dim };

        // Style for empty gutter (applies diff background for wrapped lines)
        const empty_gutter_style: vaxis.Style = if (line_type) |lt| switch (lt) {
            .add => if (is_visual)
                .{ .fg = Color.dim, .bg = Color.visual_select_bg }
            else if (is_cursor)
                .{ .fg = Color.dim, .bg = Color.cursor_bg }
            else
                .{ .fg = Color.dim, .bg = Color.diff_add_bg },
            .delete => if (is_visual)
                .{ .fg = Color.dim, .bg = Color.visual_select_bg }
            else if (is_cursor)
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
                    .add => if (is_visual)
                        .{ .fg = Color.diff_sign_add, .bg = Color.visual_select_bg, .bold = true }
                    else if (is_cursor)
                        .{ .fg = Color.diff_sign_add, .bg = Color.cursor_bg, .bold = true }
                    else
                        .{ .fg = Color.diff_sign_add, .bg = Color.diff_add_bg, .bold = true },
                    .delete => if (is_visual)
                        .{ .fg = Color.diff_sign_delete, .bg = Color.visual_select_bg, .bold = true }
                    else if (is_cursor)
                        .{ .fg = Color.diff_sign_delete, .bg = Color.cursor_bg, .bold = true }
                    else
                        .{ .fg = Color.diff_sign_delete, .bg = Color.diff_delete_bg, .bold = true },
                    .context => if (is_visual)
                        .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = true }
                    else if (is_cursor)
                        .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
                    else
                        .{ .fg = Color.dim },
                } else base_style;

                // Apply diff background to number as well for add/delete lines
                const number_style: vaxis.Style = if (line_type) |lt| switch (lt) {
                    .add => if (is_visual)
                        .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = true }
                    else if (is_cursor)
                        .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
                    else
                        .{ .fg = Color.diff_sign_add, .bg = Color.diff_add_bg },
                    .delete => if (is_visual)
                        .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = true }
                    else if (is_cursor)
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
        const spacing_style: vaxis.Style = if (is_visual)
            .{ .bg = Color.visual_select_bg }
        else if (is_cursor)
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
        // Render spacing with the appropriate background color
        const spacing_style: vaxis.Style = if (line_type) |lt| switch (lt) {
            .add => .{ .bg = Color.diff_add_bg },
            .delete => .{ .bg = Color.diff_delete_bg },
            .context => .{},
        } else if (is_cursor) .{ .bg = Color.cursor_bg } else .{}; // Hunk headers and comment lines - no background

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

        // Render gutter for top row (always highlighted since we're editing)
        try renderCommentGutter(app, win, row, true, gutter_width);

        const content_start = 1 + gutter_width + Layout.gutter_spacing;
        const box_cell_width = (win.width -| content_start) -| 2; // Width in cells (-2 for right border)

        if (box_cell_width < 20) return 0; // Box too narrow

        const box_style: vaxis.Style = .{ .fg = Color.comment_border_focus, .bg = Color.comment_hover_bg };
        const text_style: vaxis.Style = .{ .fg = Color.white, .bg = Color.comment_hover_bg };

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

        // Render gutter for content line
        try renderEmptyCommentGutter(app, win, row + 1, true, gutter_width);

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

        // Render gutter for bottom border
        try renderEmptyCommentGutter(app, win, row + 2, true, gutter_width);

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
        is_cursor: bool,
    ) !usize {
        // Render gutter for first row (with bullet indicator)
        try renderCommentGutter(app, win, row, is_cursor, gutter_width);

        const content_start = 1 + gutter_width + Layout.gutter_spacing;
        const box_cell_width = (win.width -| content_start) -| 2; // -2 for right border

        if (box_cell_width < 20) return 0;

        // Use neutral colors - slightly lighter border and dark background when focused
        const box_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.comment_border_focus, .bg = Color.comment_hover_bg }
        else
            .{ .fg = Color.comment_border };

        const text_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.white, .bg = Color.comment_hover_bg }
        else
            .{ .fg = Color.white };

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

            // Render gutter for content line (empty, no indicator)
            try renderEmptyCommentGutter(app, win, row + lines_used, is_cursor, gutter_width);

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

        // Render gutter for bottom border
        try renderEmptyCommentGutter(app, win, row + lines_used, is_cursor, gutter_width);

        // Bottom border: ╰─ Enter:Edit  d:Delete ─╯ (when cursor is on comment)
        // or just: ╰─────────────╯ (when cursor is elsewhere)
        segments.clearRetainingCapacity();

        if (is_cursor) {
            // Show action hints when cursor is on this comment
            const help_text = " Enter:Edit  d:Delete ";
            const bottom_h_count = box_cell_width - 3 - help_text.len; // -3 for corners+1 horiz, -help_text

            try segments.append(.{ .text = try copyFrameText(app, FrameChars.bottom_left), .style = box_style });
            try segments.append(.{ .text = try copyFrameText(app, FrameChars.horizontal), .style = box_style });
            try segments.append(.{ .text = try copyFrameText(app, help_text), .style = box_style });

            i = 0;
            while (i < bottom_h_count) : (i += 1) {
                try segments.append(.{ .text = try copyFrameText(app, FrameChars.horizontal), .style = box_style });
            }
            try segments.append(.{ .text = try copyFrameText(app, FrameChars.bottom_right), .style = box_style });
        } else {
            // Plain bottom border when cursor is not on this comment
            const bottom_h_count = box_cell_width - 2; // -2 for corners

            try segments.append(.{ .text = try copyFrameText(app, FrameChars.bottom_left), .style = box_style });

            i = 0;
            while (i < bottom_h_count) : (i += 1) {
                try segments.append(.{ .text = try copyFrameText(app, FrameChars.horizontal), .style = box_style });
            }
            try segments.append(.{ .text = try copyFrameText(app, FrameChars.bottom_right), .style = box_style });
        }

        _ = try win.print(segments.items, .{ .row_offset = row + lines_used, .col_offset = content_start });

        return lines_used + 1;
    }

    /// Render gutter for a comment line (shows comment indicator)
    fn renderCommentGutter(
        app: *App,
        win: vaxis.Window,
        row: usize,
        is_cursor: bool,
        gutter_width: usize,
    ) !void {
        // Gutter style - neutral gray marker with hover background
        const gutter_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.comment_marker, .bg = Color.comment_hover_bg, .bold = true }
        else
            .{ .fg = Color.comment_marker };

        // Build gutter text: right-aligned comment indicator
        var buf: [16]u8 = undefined;
        const indicator = "●"; // Comment indicator

        // Right-align the indicator in the gutter
        const gutter_text = blk: {
            const text = try std.fmt.bufPrint(&buf, "{s: >[1]}", .{ indicator, gutter_width });
            break :blk try copyFrameText(app, text);
        };

        var gutter_seg = [_]vaxis.Cell.Segment{.{
            .text = gutter_text,
            .style = gutter_style,
        }};
        _ = try win.print(&gutter_seg, .{ .row_offset = row, .col_offset = 1 });

        // Render gutter spacing (space between gutter and content)
        try renderGutterSpacing(app, win, row, 1 + gutter_width, is_cursor, null);
    }

    /// Render empty gutter for continuation lines of comment boxes
    fn renderEmptyCommentGutter(
        app: *App,
        win: vaxis.Window,
        row: usize,
        is_cursor: bool,
        gutter_width: usize,
    ) !void {
        // Apply hover background when cursor is on comment
        const gutter_style: vaxis.Style = if (is_cursor)
            .{ .bg = Color.comment_hover_bg }
        else
            .{};

        // Empty gutter (just spaces)
        const gutter_spaces = try frameTextSlice(app, gutter_width);
        @memset(gutter_spaces, ' ');

        var gutter_seg = [_]vaxis.Cell.Segment{.{
            .text = gutter_spaces,
            .style = gutter_style,
        }};
        _ = try win.print(&gutter_seg, .{ .row_offset = row, .col_offset = 1 });

        // Render gutter spacing (space between gutter and content)
        try renderGutterSpacing(app, win, row, 1 + gutter_width, is_cursor, null);
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
