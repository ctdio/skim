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

pub const UnifiedRenderer = struct {
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

        // Render vertical borders
        const border_style = .{ .fg = Color.dim };
        for (0..win.height) |border_row| {
            var left_seg = [_]vaxis.Cell.Segment{.{
                .text = FrameChars.vertical,
                .style = border_style,
            }};
            _ = try win.print(&left_seg, .{ .row_offset = border_row, .col_offset = 0 });

            if (win.width > 1) {
                var right_seg = [_]vaxis.Cell.Segment{.{
                    .text = FrameChars.vertical,
                    .style = border_style,
                }};
                _ = try win.print(&right_seg, .{ .row_offset = border_row, .col_offset = win.width -| 1 });
            }
        }

        const content_width = win.width -| (2 + gutter_width + Layout.gutter_spacing);

        // Adjust horizontal scroll to keep cursor visible (vim-like behavior)
        if (app.mode == .focused) {
            Navigation.adjustHorizontalScroll(app, content_width);
        }

        var row: usize = 0;
        var line_idx: usize = 0;

        for (file.hunks, 0..) |hunk, hunk_idx| {
            if (line_idx + hunk.lines.len < app.state.scroll_offset) {
                line_idx += hunk.lines.len + 1; // +1 for hunk header
                continue;
            }

            if (line_idx >= app.state.scroll_offset) {
                if (row >= win.height) break;
                const rows_used = try renderHunkHeader(app, win, hunk, line_idx, row, content_width, gutter_width);
                row += rows_used;
            }
            line_idx += 1;

            for (hunk.lines, 0..) |line, line_idx_in_hunk| {
                if (line_idx < app.state.scroll_offset) {
                    line_idx += 1;
                    continue;
                }

                if (row >= win.height) break;
                const rows_used = try renderDiffLine(app, win, file, hunk_idx, line_idx_in_hunk, line, line_idx, row, content_width, gutter_width);
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
        content_width: usize,
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

        const is_cursor = line_idx == app.state.cursor_line;
        const style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
        else
            .{ .fg = Color.cyan, .bg = Color.dim };

        // Fill the entire row with dim background first (from gutter to right edge)
        const fill_start = 1; // After left border
        const fill_end = win.width -| 1; // Before right border
        const fill_width = if (fill_end > fill_start) fill_end - fill_start else 0;
        const fill_style: vaxis.Style = .{ .bg = Color.dim };

        if (fill_width > 0) {
            const fill_text = try RenderUtils.frameTextSlice(app, fill_width);
            @memset(fill_text, ' ');
            var fill_seg = [_]vaxis.Cell.Segment{.{
                .text = fill_text,
                .style = fill_style,
            }};
            _ = try win.print(&fill_seg, .{ .row_offset = row, .col_offset = fill_start });
        }

        // Render spacing after gutter (hunk headers have no line_type, so use null)
        try RenderUtils.renderGutterSpacing(app, win, row, 1 + gutter_width, is_cursor, null);

        // Now render the actual content on top
        const content_start = 1 + gutter_width + Layout.gutter_spacing;
        const display_text = blk: {
            const slice = try RenderUtils.frameTextSlice(app, content_width);
            const copy_len = @min(header_text_stack.len, slice.len);
            if (copy_len > 0) {
                @memcpy(slice[0..copy_len], header_text_stack[0..copy_len]);
            }
            if (copy_len < slice.len) {
                @memset(slice[copy_len..], ' ');
            }
            break :blk slice;
        };

        var seg = [_]vaxis.Cell.Segment{.{
            .text = display_text,
            .style = style,
        }};
        _ = try win.print(&seg, .{ .row_offset = row, .col_offset = content_start });

        return 1;
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
        content_width: usize,
        gutter_width: usize,
    ) !usize {
        const is_cursor = line_idx == app.state.cursor_line;
        const base_style = RenderUtils.getLineStyle(app, line.line_type);
        const style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
        else
            base_style;

        // Use actual file line number from the diff
        // For deletions, show old line number; for additions and context, show new line number
        const file_lineno = switch (line.line_type) {
            .delete => line.old_lineno,
            .add, .context => line.new_lineno,
        };

        // Apply syntax highlighting to all lines (context, additions, deletions)
        // Calculate byte offset for syntax highlighting
        const byte_offset = StateHelpers.getLineByteOffset(file, hunk_idx, line_idx_in_hunk);

        return try renderWrappedTextWithHighlights(
            app,
            win,
            line.content,
            byte_offset,
            file.highlights,
            line_idx,
            row,
            content_width,
            is_cursor,
            style,
            file_lineno,
            line.line_type,
            gutter_width,
            app.mode == .focused, // show_caret
        );
    }

    fn renderWrappedTextWithHighlights(
        app: *App,
        win: vaxis.Window,
        text: []const u8,
        byte_offset: usize,
        highlights: ?[]syntax.Highlight,
        line_idx: usize,
        start_row: usize,
        content_width: usize,
        is_cursor: bool,
        style: vaxis.Style,
        file_lineno: ?u32,
        line_type: ?parser.Line.LineType,
        gutter_width: usize,
        show_caret: bool,
    ) !usize {
        if (content_width == 0) return 1;

        // Handle empty lines explicitly
        if (text.len == 0) {
            try RenderUtils.renderGutter(app, win, line_idx, start_row, is_cursor, true, file_lineno, line_type, gutter_width);
            // Pad empty lines for cursor or diff lines (add/delete)
            const should_pad = is_cursor or (line_type != null and line_type.? != .context);
            const display_text = try RenderUtils.padTextForCursor(app, "", content_width, should_pad);
            var seg = [_]vaxis.Cell.Segment{.{
                .text = display_text,
                .style = style,
            }};
            _ = try win.print(&seg, .{ .row_offset = start_row, .col_offset = 1 + gutter_width + Layout.gutter_spacing });

            // Render caret for empty line in FOCUSED mode
            const visible_cursor_col = if (app.state.cursor_col >= app.state.h_scroll_offset)
                app.state.cursor_col - app.state.h_scroll_offset
            else
                0;
            if (show_caret and is_cursor and visible_cursor_col < content_width) {
                const caret_text = try RenderUtils.copyFrameText(app, " ");
                var caret_seg = [_]vaxis.Cell.Segment{.{
                    .text = caret_text,
                    .style = .{ .fg = Color.caret_fg, .bg = Color.caret_bg, .bold = true },
                }};
                _ = try win.print(&caret_seg, .{ .row_offset = start_row, .col_offset = 1 + gutter_width + Layout.gutter_spacing + visible_cursor_col });
            }

            return 1;
        }

        // Apply horizontal scrolling - start rendering from h_scroll_offset
        const h_scroll = app.state.h_scroll_offset;
        const start_offset = @min(h_scroll, text.len);

        var rows_rendered: usize = 0;
        var text_offset: usize = start_offset;

        while (text_offset < text.len) {
            const current_row = start_row + rows_rendered;
            if (current_row >= win.height) break;

            // Only show line number on first row
            const show_line_number = rows_rendered == 0;
            try RenderUtils.renderGutter(app, win, line_idx, current_row, is_cursor, show_line_number, file_lineno, line_type, gutter_width);

            // Get the chunk of text for this row
            const remaining = text.len - text_offset;
            const chunk_len = @min(remaining, content_width);
            const chunk = text[text_offset .. text_offset + chunk_len];

            // Generate syntax-highlighted segments for this chunk
            const chunk_byte_offset = byte_offset + text_offset;
            const segments = try app.createHighlightedSegments(chunk, chunk_byte_offset, highlights, style);
            defer app.allocator.free(segments);

            // Pad segments to full width for cursor or diff lines (add/delete)
            const should_pad = is_cursor or (line_type != null and line_type.? != .context);
            if (should_pad and chunk.len < content_width) {
                // Create a new segments array with padding
                const padded_segments = try app.allocator.alloc(vaxis.Cell.Segment, segments.len + 1);
                defer app.allocator.free(padded_segments);

                @memcpy(padded_segments[0..segments.len], segments);

                // Add padding segment
                const padding_len = content_width - chunk.len;
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

            // Render caret in FOCUSED mode
            if (show_caret and is_cursor) {
                const cursor_col = app.state.cursor_col;
                const h_scroll_off = app.state.h_scroll_offset;

                // Calculate visible cursor position (accounting for horizontal scroll)
                if (cursor_col >= h_scroll_off and cursor_col < h_scroll_off + content_width) {
                    const visible_col = cursor_col - h_scroll_off;

                    // Check if cursor_col falls within this chunk
                    if (cursor_col >= text_offset and cursor_col < text_offset + chunk_len) {
                        const col_in_chunk = cursor_col - text_offset;
                        const caret_char = if (col_in_chunk < chunk.len) chunk[col_in_chunk .. col_in_chunk + 1] else " ";

                        // Render caret with bright yellow background at visible position
                        const caret_text = try RenderUtils.copyFrameText(app, caret_char);
                        var caret_seg = [_]vaxis.Cell.Segment{.{
                            .text = caret_text,
                            .style = .{ .fg = Color.caret_fg, .bg = Color.caret_bg, .bold = true },
                        }};
                        _ = try win.print(&caret_seg, .{ .row_offset = current_row, .col_offset = 1 + gutter_width + Layout.gutter_spacing + visible_col });
                    }
                }
            }

            text_offset += chunk_len;
            rows_rendered += 1;
        }

        return if (rows_rendered == 0) 1 else rows_rendered;
    }

    fn renderWrappedText(
        app: *App,
        win: vaxis.Window,
        text: []const u8,
        line_idx: usize,
        start_row: usize,
        content_width: usize,
        is_cursor: bool,
        style: vaxis.Style,
        file_lineno: ?u32,
        line_type: ?parser.Line.LineType,
        gutter_width: usize,
    ) !usize {
        _ = win;
        _ = text;
        _ = line_idx;
        _ = start_row;
        _ = content_width;
        _ = is_cursor;
        _ = style;
        _ = file_lineno;
        _ = line_type;
        _ = gutter_width;
        _ = app;

        // This function is not currently used but kept for potential future use
        return 1;
    }

    fn renderWrappedTextAlwaysFilled(
        app: *App,
        win: vaxis.Window,
        text: []const u8,
        line_idx: usize,
        start_row: usize,
        content_width: usize,
        is_cursor: bool,
        style: vaxis.Style,
        file_lineno: ?u32,
        line_type: ?parser.Line.LineType,
        gutter_width: usize,
    ) !usize {
        _ = is_cursor; // Unused - we always fill like cursor is on the line
        if (content_width == 0) return 1;

        // Calculate number of wrapped rows needed
        const num_rows = (text.len + content_width - 1) / content_width;
        if (num_rows == 0) {
            // Empty line - still render one row with full background
            try RenderUtils.renderGutter(app, win, line_idx, start_row, true, true, file_lineno, line_type, gutter_width); // Always fill gutter
            const display_text = try RenderUtils.padTextForCursor(app, "", content_width, true); // Always pad
            var seg = [_]vaxis.Cell.Segment{.{
                .text = display_text,
                .style = style,
            }};
            _ = try win.print(&seg, .{ .row_offset = start_row, .col_offset = 1 + gutter_width + Layout.gutter_spacing });
            return 1;
        }

        var rows_rendered: usize = 0;
        var text_offset: usize = 0;

        while (text_offset < text.len) {
            const current_row = start_row + rows_rendered;
            if (current_row >= win.height) break;

            // Only show line number on first row
            const show_line_number = rows_rendered == 0;
            try RenderUtils.renderGutter(app, win, line_idx, current_row, true, show_line_number, file_lineno, line_type, gutter_width); // Always fill gutter

            // Get the chunk of text for this row
            const remaining = text.len - text_offset;
            const chunk_len = @min(remaining, content_width);
            const chunk = text[text_offset .. text_offset + chunk_len];

            // Render the chunk - always pad
            const display_text = try RenderUtils.padTextForCursor(app, chunk, content_width, true); // Always pad
            var seg = [_]vaxis.Cell.Segment{.{
                .text = display_text,
                .style = style,
            }};
            _ = try win.print(&seg, .{ .row_offset = current_row, .col_offset = 1 + gutter_width + Layout.gutter_spacing });

            text_offset += chunk_len;
            rows_rendered += 1;
        }

        return if (rows_rendered == 0) 1 else rows_rendered;
    }
};
