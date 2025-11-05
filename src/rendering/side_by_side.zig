const std = @import("std");
const vaxis = @import("vaxis");
const parser = @import("../git/parser.zig");
const syntax = @import("../syntax.zig");
const rendering_common = @import("common.zig");
const render_utils = @import("utils.zig");
const state_helpers = @import("../state.zig");
const navigation = @import("../navigation.zig");

const App = @import("../app.zig").App;
const Color = rendering_common.Color;
const Layout = rendering_common.Layout;
const FrameChars = rendering_common.FrameChars;
const RenderUtils = render_utils.RenderUtils;
const StateHelpers = state_helpers.StateHelpers;
const Navigation = navigation.Navigation;

pub const SideBySideRenderer = struct {
    pub fn renderContent(app: *App, win: vaxis.Window) !void {
        if (app.state.current_file_idx >= app.state.files.len) return;

        const file = &app.state.files[app.state.current_file_idx];

        // Ensure syntax highlights are loaded for this file
        try StateHelpers.ensureHighlights(app, file);

        app.state.viewport_height = win.height;
        Navigation.clampScrollOffset(app);
        Navigation.adjustScrollToKeepCursorVisible(app, win.height);

        // Calculate gutter width based on maximum line number in file
        const gutter_width = StateHelpers.getGutterWidth(file);

        // Calculate layout: [border][gutter][spacing][left_content][divider][gutter][spacing][right_content][border]
        // Total width = 2 (borders) + 2 * gutter_width + 2 * spacing + 1 (middle divider) + left_content + right_content
        const total_borders_and_gutters = 2 + (2 * gutter_width) + (2 * Layout.gutter_spacing) + 1;
        if (win.width <= total_borders_and_gutters) return; // Not enough space

        const available_width = win.width - total_borders_and_gutters;
        const left_content_width = available_width / 2;
        const right_content_width = available_width - left_content_width;

        // Render outer borders
        const border_style = .{ .fg = Color.dim };
        for (0..win.height) |border_row| {
            // Left border
            var left_seg = [_]vaxis.Cell.Segment{.{
                .text = FrameChars.vertical,
                .style = border_style,
            }};
            _ = try win.print(&left_seg, .{ .row_offset = border_row, .col_offset = 0 });

            // Right border
            if (win.width > 1) {
                var right_seg = [_]vaxis.Cell.Segment{.{
                    .text = FrameChars.vertical,
                    .style = border_style,
                }};
                _ = try win.print(&right_seg, .{ .row_offset = border_row, .col_offset = win.width -| 1 });
            }

            // Middle divider
            const middle_col = 1 + gutter_width + Layout.gutter_spacing + left_content_width;
            var middle_seg = [_]vaxis.Cell.Segment{.{
                .text = FrameChars.vertical,
                .style = border_style,
            }};
            _ = try win.print(&middle_seg, .{ .row_offset = border_row, .col_offset = middle_col });
        }

        var row: usize = 0;
        var line_idx: usize = 0;

        for (file.hunks, 0..) |hunk, hunk_idx| {
            // Skip hunks that are before scroll offset
            if (line_idx + hunk.lines.len < app.state.scroll_offset) {
                line_idx += hunk.lines.len + 1; // +1 for hunk header
                continue;
            }

            // Render hunk header if visible
            if (line_idx >= app.state.scroll_offset) {
                if (row >= win.height) break;
                const rows_used = try renderHunkHeader(
                    app,
                    win,
                    hunk,
                    line_idx,
                    row,
                    left_content_width,
                    right_content_width,
                    gutter_width,
                );
                row += rows_used;
            }
            line_idx += 1;

            // Render diff lines
            for (hunk.lines, 0..) |line, line_idx_in_hunk| {
                if (line_idx < app.state.scroll_offset) {
                    line_idx += 1;
                    continue;
                }

                if (row >= win.height) break;
                const rows_used = try renderDiffLine(
                    app,
                    win,
                    file,
                    hunk_idx,
                    line_idx_in_hunk,
                    line,
                    line_idx,
                    row,
                    left_content_width,
                    right_content_width,
                    gutter_width,
                );
                row += rows_used;
                line_idx += 1;
            }
        }
    }

    fn renderHunkHeader(
        app: *App,
        win: vaxis.Window,
        hunk: parser.Hunk,
        line_idx: usize,
        row: usize,
        left_width: usize,
        right_width: usize,
        gutter_width: usize,
    ) !usize {
        var buf: [256]u8 = undefined;

        // Calculate end line numbers for clearer range display
        const old_end = hunk.header.old_start + hunk.header.old_count -| 1;
        const new_end = hunk.header.new_start + hunk.header.new_count -| 1;

        const header_text_stack = try std.fmt.bufPrint(
            &buf,
            "━━ ↕ {d}-{d} → {d}-{d} ━━ {s}",
            .{
                hunk.header.old_start,
                old_end,
                hunk.header.new_start,
                new_end,
                hunk.header.context,
            },
        );

        const header_text = try RenderUtils.copyFrameText(app, header_text_stack);
        const is_cursor = line_idx == app.state.cursor_line;
        const style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
        else
            .{ .fg = Color.cyan, .bg = Color.dim };

        // Calculate how many rows this will take (same on both sides)
        const num_rows = if (header_text.len == 0) 1 else (header_text.len + left_width - 1) / left_width;

        const right_col = 1 + gutter_width + Layout.gutter_spacing + left_width + 1; // +1 for middle divider

        // Render wrapped text on both left and right sides
        const fill_style: vaxis.Style = .{ .bg = Color.dim };
        var current_row = row;
        for (0..num_rows) |wrap_idx| {
            if (current_row >= win.height) break;

            // Fill the entire row with dim background first
            const fill_start = 1; // After left border
            const fill_end = win.width -| 1; // Before right border
            const fill_width = if (fill_end > fill_start) fill_end - fill_start else 0;

            if (fill_width > 0) {
                const fill_text = try RenderUtils.frameTextSlice(app, fill_width);
                @memset(fill_text, ' ');
                var fill_seg = [_]vaxis.Cell.Segment{.{
                    .text = fill_text,
                    .style = fill_style,
                }};
                _ = try win.print(&fill_seg, .{ .row_offset = current_row, .col_offset = fill_start });
            }

            // Render left content
            const text_start = wrap_idx * left_width;
            const text_end = @min(text_start + left_width, header_text.len);
            const chunk = if (text_start < header_text.len) header_text[text_start..text_end] else "";

            const left_display = blk: {
                const slice = try RenderUtils.frameTextSlice(app, left_width);
                const copy_len = @min(chunk.len, slice.len);
                if (copy_len > 0) {
                    @memcpy(slice[0..copy_len], chunk);
                }
                if (copy_len < slice.len) {
                    @memset(slice[copy_len..], ' ');
                }
                break :blk slice;
            };

            // Render spacing after left gutter (hunk headers have no line_type)
            try RenderUtils.renderGutterSpacing(app, win, current_row, 1 + gutter_width, is_cursor, null);

            var left_seg = [_]vaxis.Cell.Segment{.{
                .text = left_display,
                .style = style,
            }};
            _ = try win.print(&left_seg, .{ .row_offset = current_row, .col_offset = 1 + gutter_width + Layout.gutter_spacing });

            // Render right content
            const right_text_start = wrap_idx * right_width;
            const right_text_end = @min(right_text_start + right_width, header_text.len);
            const right_chunk = if (right_text_start < header_text.len) header_text[right_text_start..right_text_end] else "";

            const right_display = blk: {
                const slice = try RenderUtils.frameTextSlice(app, right_width);
                const copy_len = @min(right_chunk.len, slice.len);
                if (copy_len > 0) {
                    @memcpy(slice[0..copy_len], right_chunk);
                }
                if (copy_len < slice.len) {
                    @memset(slice[copy_len..], ' ');
                }
                break :blk slice;
            };

            // Render spacing after right gutter (hunk headers have no line_type)
            try RenderUtils.renderGutterSpacing(app, win, current_row, right_col + gutter_width, is_cursor, null);

            var right_seg = [_]vaxis.Cell.Segment{.{
                .text = right_display,
                .style = style,
            }};
            _ = try win.print(&right_seg, .{ .row_offset = current_row, .col_offset = right_col + gutter_width + Layout.gutter_spacing });

            current_row += 1;
        }

        return if (num_rows == 0) 1 else num_rows;
    }

    fn renderDiffLine(
        app: *App,
        win: vaxis.Window,
        file: *const parser.FileDiff,
        hunk_idx: usize,
        line_idx_in_hunk: usize,
        line: parser.Line,
        line_idx: usize,
        row: usize,
        left_width: usize,
        right_width: usize,
        gutter_width: usize,
    ) !usize {
        const is_cursor = line_idx == app.state.cursor_line;
        const base_style = RenderUtils.getLineStyle(app, line.line_type);
        const style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
        else
            base_style;

        const right_col = 1 + gutter_width + Layout.gutter_spacing + left_width + 1; // +1 for middle divider

        // Calculate byte offset for syntax highlighting
        const byte_offset = StateHelpers.getLineByteOffset(file, hunk_idx, line_idx_in_hunk);

        switch (line.line_type) {
            .context => {
                // Show on both sides - calculate rows based on left width
                const num_rows = if (line.content.len == 0) 1 else (line.content.len + left_width - 1) / left_width;

                var current_row = row;
                for (0..num_rows) |wrap_idx| {
                    if (current_row >= win.height) break;

                    const show_lineno = wrap_idx == 0;

                    // Render left side
                    try RenderUtils.renderGutter(app, win, line_idx, current_row, is_cursor, show_lineno, line.old_lineno, line.line_type, gutter_width);

                    const left_start = wrap_idx * left_width;
                    const left_end = @min(left_start + left_width, line.content.len);
                    const left_chunk = if (left_start < line.content.len) line.content[left_start..left_end] else "";

                    // Generate syntax-highlighted segments for left chunk
                    const left_chunk_byte_offset = byte_offset + left_start;
                    const left_segments = try app.createHighlightedSegments(left_chunk, left_chunk_byte_offset, file.highlights, style);
                    defer app.allocator.free(left_segments);

                    // Pad context lines only when cursor is on them
                    if (is_cursor and left_chunk.len < left_width) {
                        const padded_segments = try app.allocator.alloc(vaxis.Cell.Segment, left_segments.len + 1);
                        defer app.allocator.free(padded_segments);

                        @memcpy(padded_segments[0..left_segments.len], left_segments);

                        const padding_len = left_width - left_chunk.len;
                        const padding = try RenderUtils.frameTextSlice(app, padding_len);
                        @memset(padding, ' ');
                        padded_segments[left_segments.len] = .{
                            .text = padding,
                            .style = style,
                        };

                        _ = try win.print(padded_segments, .{ .row_offset = current_row, .col_offset = 1 + gutter_width + Layout.gutter_spacing });
                    } else {
                        _ = try win.print(left_segments, .{ .row_offset = current_row, .col_offset = 1 + gutter_width + Layout.gutter_spacing });
                    }

                    // Render right side (same content)
                    try renderGutterAtColumn(app, win, line_idx, current_row, is_cursor, show_lineno, line.new_lineno, right_col, line.line_type, gutter_width);

                    const right_start = wrap_idx * right_width;
                    const right_end = @min(right_start + right_width, line.content.len);
                    const right_chunk = if (right_start < line.content.len) line.content[right_start..right_end] else "";

                    // Generate syntax-highlighted segments for right chunk
                    const right_chunk_byte_offset = byte_offset + right_start;
                    const right_segments = try app.createHighlightedSegments(right_chunk, right_chunk_byte_offset, file.highlights, style);
                    defer app.allocator.free(right_segments);

                    // Pad context lines only when cursor is on them
                    if (is_cursor and right_chunk.len < right_width) {
                        const padded_segments = try app.allocator.alloc(vaxis.Cell.Segment, right_segments.len + 1);
                        defer app.allocator.free(padded_segments);

                        @memcpy(padded_segments[0..right_segments.len], right_segments);

                        const padding_len = right_width - right_chunk.len;
                        const padding = try RenderUtils.frameTextSlice(app, padding_len);
                        @memset(padding, ' ');
                        padded_segments[right_segments.len] = .{
                            .text = padding,
                            .style = style,
                        };

                        _ = try win.print(padded_segments, .{ .row_offset = current_row, .col_offset = right_col + gutter_width + Layout.gutter_spacing });
                    } else {
                        _ = try win.print(right_segments, .{ .row_offset = current_row, .col_offset = right_col + gutter_width + Layout.gutter_spacing });
                    }

                    current_row += 1;
                }

                return if (num_rows == 0) 1 else num_rows;
            },
            .delete => {
                // Show on left only, wrap as needed
                // Note: Delete lines are not in the new file, so syntax highlighting won't apply
                const num_rows = if (line.content.len == 0) 1 else (line.content.len + left_width - 1) / left_width;

                var current_row = row;
                for (0..num_rows) |wrap_idx| {
                    if (current_row >= win.height) break;

                    const show_lineno = wrap_idx == 0;

                    // Render left side
                    try RenderUtils.renderGutter(app, win, line_idx, current_row, is_cursor, show_lineno, line.old_lineno, line.line_type, gutter_width);

                    const text_start = wrap_idx * left_width;
                    const text_end = @min(text_start + left_width, line.content.len);
                    const chunk = if (text_start < line.content.len) line.content[text_start..text_end] else "";

                    // Generate syntax-highlighted segments for chunk
                    // (will fall back to plain text for delete lines since they're not in new file)
                    const chunk_byte_offset = byte_offset + text_start;
                    const segments = try app.createHighlightedSegments(chunk, chunk_byte_offset, file.highlights, style);
                    defer app.allocator.free(segments);

                    // Always pad delete lines to show full-width background
                    if (chunk.len < left_width) {
                        const padded_segments = try app.allocator.alloc(vaxis.Cell.Segment, segments.len + 1);
                        defer app.allocator.free(padded_segments);

                        @memcpy(padded_segments[0..segments.len], segments);

                        const padding_len = left_width - chunk.len;
                        const padding = try RenderUtils.frameTextSlice(app, padding_len);
                        @memset(padding, ' ');
                        padded_segments[segments.len] = .{
                            .text = padding,
                            .style = style,
                        };

                        _ = try win.print(padded_segments, .{ .row_offset = current_row, .col_offset = 1 + gutter_width + Layout.gutter_spacing });
                    } else {
                        _ = try win.print(segments, .{ .row_offset = current_row, .col_offset = 1 + gutter_width + Layout.gutter_spacing });
                    }

                    // Right side empty with cursor highlight if needed
                    if (is_cursor) {
                        try renderGutterAtColumn(app, win, line_idx, current_row, is_cursor, false, null, right_col, null, gutter_width);
                        const blank = try RenderUtils.frameTextSlice(app, right_width);
                        @memset(blank, ' ');
                        var blank_seg = [_]vaxis.Cell.Segment{.{
                            .text = blank,
                            .style = .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg },
                        }};
                        _ = try win.print(&blank_seg, .{ .row_offset = current_row, .col_offset = right_col + gutter_width + Layout.gutter_spacing });
                    }

                    current_row += 1;
                }

                return if (num_rows == 0) 1 else num_rows;
            },
            .add => {
                // Show on right only, wrap as needed
                const num_rows = if (line.content.len == 0) 1 else (line.content.len + right_width - 1) / right_width;

                var current_row = row;
                for (0..num_rows) |wrap_idx| {
                    if (current_row >= win.height) break;

                    const show_lineno = wrap_idx == 0;

                    // Left side empty with cursor highlight if needed
                    if (is_cursor) {
                        try RenderUtils.renderGutter(app, win, line_idx, current_row, is_cursor, false, null, null, gutter_width);
                        const blank = try RenderUtils.frameTextSlice(app, left_width);
                        @memset(blank, ' ');
                        var blank_seg = [_]vaxis.Cell.Segment{.{
                            .text = blank,
                            .style = .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg },
                        }};
                        _ = try win.print(&blank_seg, .{ .row_offset = current_row, .col_offset = 1 + gutter_width + Layout.gutter_spacing });
                    }

                    // Render right side
                    try renderGutterAtColumn(app, win, line_idx, current_row, is_cursor, show_lineno, line.new_lineno, right_col, line.line_type, gutter_width);

                    const text_start = wrap_idx * right_width;
                    const text_end = @min(text_start + right_width, line.content.len);
                    const chunk = if (text_start < line.content.len) line.content[text_start..text_end] else "";

                    // Generate syntax-highlighted segments for chunk
                    const chunk_byte_offset = byte_offset + text_start;
                    const segments = try app.createHighlightedSegments(chunk, chunk_byte_offset, file.highlights, style);
                    defer app.allocator.free(segments);

                    // Always pad add lines to show full-width background
                    if (chunk.len < right_width) {
                        const padded_segments = try app.allocator.alloc(vaxis.Cell.Segment, segments.len + 1);
                        defer app.allocator.free(padded_segments);

                        @memcpy(padded_segments[0..segments.len], segments);

                        const padding_len = right_width - chunk.len;
                        const padding = try RenderUtils.frameTextSlice(app, padding_len);
                        @memset(padding, ' ');
                        padded_segments[segments.len] = .{
                            .text = padding,
                            .style = style,
                        };

                        _ = try win.print(padded_segments, .{ .row_offset = current_row, .col_offset = right_col + gutter_width + Layout.gutter_spacing });
                    } else {
                        _ = try win.print(segments, .{ .row_offset = current_row, .col_offset = right_col + gutter_width + Layout.gutter_spacing });
                    }

                    current_row += 1;
                }

                return if (num_rows == 0) 1 else num_rows;
            },
        }
    }

    fn renderGutterAtColumn(
        app: *App,
        win: vaxis.Window,
        line_idx: usize,
        row: usize,
        is_cursor: bool,
        show_number: bool,
        file_lineno: ?u32,
        col_offset: usize,
        line_type: ?parser.Line.LineType,
        gutter_width: usize,
    ) !void {
        _ = line_idx;

        const base_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
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

                const gutter_text = try RenderUtils.copyFrameText(app, buf[0 .. sign_pos + sign.len]);

                // Color the sign and number based on line type (with matching background)
                const sign_style: vaxis.Style = if (line_type) |lt| switch (lt) {
                    .add => if (is_cursor)
                        .{ .fg = Color.green, .bg = Color.cursor_bg, .bold = true }
                    else
                        .{ .fg = Color.green, .bg = Color.diff_add_bg, .bold = true },
                    .delete => if (is_cursor)
                        .{ .fg = Color.red, .bg = Color.cursor_bg, .bold = true }
                    else
                        .{ .fg = Color.red, .bg = Color.diff_delete_bg, .bold = true },
                    .context => if (is_cursor)
                        .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
                    else
                        .{ .fg = Color.dim },
                } else base_style;

                // Apply diff background to number as well for add/delete lines
                const number_style: vaxis.Style = if (line_type) |lt| switch (lt) {
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

                // Split into number and sign segments for different colors
                const number_text = gutter_text[0 .. gutter_text.len - 1];
                const sign_text = gutter_text[gutter_text.len - 1 ..];

                var segments = [_]vaxis.Cell.Segment{
                    .{ .text = number_text, .style = number_style },
                    .{ .text = sign_text, .style = sign_style },
                };
                _ = try win.print(&segments, .{ .row_offset = row, .col_offset = col_offset });
            } else {
                if (is_cursor) {
                    const spaces_slice = try RenderUtils.frameTextSlice(app, gutter_width);
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
            const spaces_slice = try RenderUtils.frameTextSlice(app, gutter_width);
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
        else if (line_type) |lt| switch (lt) {
            .add => .{ .bg = Color.diff_add_bg },
            .delete => .{ .bg = Color.diff_delete_bg },
            .context => .{},
        } else .{};

        const spacing = try RenderUtils.frameTextSlice(app, rendering_common.Layout.gutter_spacing);
        @memset(spacing, ' ');
        var spacing_seg = [_]vaxis.Cell.Segment{.{
            .text = spacing,
            .style = spacing_style,
        }};
        _ = try win.print(&spacing_seg, .{ .row_offset = row, .col_offset = col_offset + gutter_width });
    }
};
