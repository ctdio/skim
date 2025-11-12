const std = @import("std");
const vaxis = @import("vaxis");
const parser = @import("../git/parser.zig");
const syntax = @import("../syntax.zig");
const rendering_common = @import("common.zig");
const render_utils = @import("utils.zig");
const state_helpers = @import("../state.zig");
const navigation = @import("../navigation.zig");
const display_lines = @import("../display_lines.zig");
const global_lines = @import("../global_lines.zig");
const file_header = @import("file_header.zig");

const App = @import("../app.zig").App;
const Color = rendering_common.Color;
const Layout = rendering_common.Layout;
const FrameChars = rendering_common.FrameChars;
const RenderUtils = render_utils.RenderUtils;
const StateHelpers = state_helpers.StateHelpers;
const Navigation = navigation.Navigation;
const FileHeader = file_header.FileHeader;

pub const UnifiedRenderer = struct {
    pub fn renderContent(app: *App, win: vaxis.Window) !void {
        if (app.state.files.len == 0) return;

        app.state.viewport_height = win.height;
        Navigation.clampScrollOffset(app);

        // Calculate global gutter width (consistent across all files)
        const gutter_width = StateHelpers.getGlobalGutterWidth(app.state.files);
        const content_width = win.width -| (Layout.sidebar_width + gutter_width + Layout.gutter_spacing);
        const sidebar_style = .{ .fg = Color.dim };

        var row: usize = 0;
        var global_line: usize = 0;

        // Loop through all files for continuous scrolling
        for (app.state.files, 0..) |*file, file_idx| {
            // Ensure syntax highlights are loaded (non-blocking)
            try StateHelpers.ensureHighlights(app, file, false);

            const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;
            const file_display_lines = display_lines.getTotalDisplayLines(file, &app.state.comment_store, file_path);

            // File header line
            if (global_line >= app.state.global_scroll_offset) {
                if (row >= win.height) break;
                // Render sidebar for file header
                var sidebar_seg = [_]vaxis.Cell.Segment{.{
                    .text = "┃",
                    .style = sidebar_style,
                }};
                _ = try win.print(&sidebar_seg, .{ .row_offset = row, .col_offset = 0 });

                const is_cursor = global_line == app.state.global_cursor_line;
                const rows_used = try FileHeader.render(app, win, file, row, is_cursor);
                row += rows_used;
            }
            global_line += 1;

            // Skip entire file if it's before scroll offset and after header
            if (global_line + file_display_lines < app.state.global_scroll_offset) {
                global_line += file_display_lines;
                continue;
            }

            // Render file content (hunks and lines)
            var local_line: usize = 0;

            for (file.hunks, 0..) |hunk, hunk_idx| {
                // Skip hunk header if before scroll offset
                if (global_line < app.state.global_scroll_offset) {
                    global_line += 1;
                    local_line += 1;
                } else {
                    if (row >= win.height) break;
                    // Render sidebar for hunk header
                    var sidebar_seg = [_]vaxis.Cell.Segment{.{
                        .text = "┃",
                        .style = sidebar_style,
                    }};
                    _ = try win.print(&sidebar_seg, .{ .row_offset = row, .col_offset = 0 });

                    const is_cursor = global_line == app.state.global_cursor_line;
                    const rows_used = try renderHunkHeader(app, win, hunk, global_line, row, content_width, gutter_width, is_cursor);
                    row += rows_used;
                    global_line += 1;
                    local_line += 1;
                }

                // Render hunk lines
                for (hunk.lines, 0..) |line, line_idx_in_hunk| {
                    if (global_line < app.state.global_scroll_offset) {
                        global_line += 1;
                        local_line += 1;
                        // Skip comment check if line is before scroll
                        if (app.state.comment_store.hasCommentAt(file_path, hunk_idx, line_idx_in_hunk)) {
                            global_line += 1;
                            local_line += 1;
                        }
                        continue;
                    }

                    if (row >= win.height) break;

                    // Render sidebar for diff line
                    var sidebar_seg = [_]vaxis.Cell.Segment{.{
                        .text = "┃",
                        .style = sidebar_style,
                    }};
                    _ = try win.print(&sidebar_seg, .{ .row_offset = row, .col_offset = 0 });

                    // Render code line
                    const is_cursor = global_line == app.state.global_cursor_line;
                    const rows_used = try renderDiffLine(app, win, file, hunk_idx, line_idx_in_hunk, line, global_line, row, content_width, gutter_width, is_cursor);
                    row += rows_used;
                    global_line += 1;
                    local_line += 1;

                    // Check for comments
                    if (RenderUtils.getCommentAt(app, file_path, hunk_idx, line_idx_in_hunk)) |comment| {
                        if (row < win.height) {
                            const is_cursor_on_comment = global_line == app.state.global_cursor_line;

                            // Render sidebar for comment rows
                            const comment_start_row = row;
                            const comment_rows = if (app.mode == .comment and is_cursor_on_comment)
                                try RenderUtils.renderCommentInputBox(app, win, row, gutter_width)
                            else
                                try RenderUtils.renderCommentDisplay(app, win, comment, row, gutter_width, is_cursor_on_comment);

                            // Render sidebar for all comment rows
                            var comment_row_idx: usize = 0;
                            while (comment_row_idx < comment_rows and comment_start_row + comment_row_idx < win.height) : (comment_row_idx += 1) {
                                var comment_sidebar = [_]vaxis.Cell.Segment{.{
                                    .text = "┃",
                                    .style = sidebar_style,
                                }};
                                _ = try win.print(&comment_sidebar, .{ .row_offset = comment_start_row + comment_row_idx, .col_offset = 0 });
                            }

                            row += comment_rows;
                            global_line += 1;
                            local_line += 1;
                        }
                    } else {
                        // Check if creating a new comment
                        if (app.mode == .comment and global_line - 1 == app.state.global_cursor_line) {
                            if (row < win.height) {
                                const comment_start_row = row;
                                const comment_rows = try RenderUtils.renderCommentInputBox(app, win, row, gutter_width);

                                // Render sidebar for all comment rows
                                var comment_row_idx: usize = 0;
                                while (comment_row_idx < comment_rows and comment_start_row + comment_row_idx < win.height) : (comment_row_idx += 1) {
                                    var new_comment_sidebar = [_]vaxis.Cell.Segment{.{
                                        .text = "┃",
                                        .style = sidebar_style,
                                    }};
                                    _ = try win.print(&new_comment_sidebar, .{ .row_offset = comment_start_row + comment_row_idx, .col_offset = 0 });
                                }

                                row += comment_rows;
                            }
                        }
                    }
                }
            }

            // Add spacing after file (except for last file)
            if (file_idx < app.state.files.len - 1) {
                var spacer_idx: usize = 0;
                while (spacer_idx < global_lines.file_spacing) : (spacer_idx += 1) {
                    if (global_line >= app.state.global_scroll_offset) {
                        if (row >= win.height) break;

                        // Render sidebar for spacer line
                        var sidebar_seg = [_]vaxis.Cell.Segment{.{
                            .text = "┃",
                            .style = sidebar_style,
                        }};
                        _ = try win.print(&sidebar_seg, .{ .row_offset = row, .col_offset = 0 });

                        // Check if cursor is on this spacer line
                        const is_cursor = global_line == app.state.global_cursor_line;
                        if (is_cursor) {
                            // Render cursor line across the spacer
                            const fill_start = 1; // After sidebar
                            const fill_width = win.width -| 1; // Before right border
                            if (fill_width > 0) {
                                const fill_text = try RenderUtils.frameTextSlice(app, fill_width);
                                @memset(fill_text, ' ');
                                var fill_seg = [_]vaxis.Cell.Segment{.{
                                    .text = fill_text,
                                    .style = .{ .bg = Color.cursor_bg },
                                }};
                                _ = try win.print(&fill_seg, .{ .row_offset = row, .col_offset = fill_start });
                            }
                        }

                        row += 1;
                    }
                    global_line += 1;
                }
            }
        }

        // Update current_file_idx based on what's at the top of viewport (for sticky header)
        // Use scroll offset instead of cursor position for more accurate header display
        app.state.current_file_idx = global_lines.getCurrentFileFromCursor(
            app.state.global_scroll_offset,
            app.state.files,
            &app.state.comment_store,
        );
    }

    fn renderHunkHeader(
        app: *App,
        win: vaxis.Window,
        hunk: parser.Hunk,
        _: usize, // line_idx kept for compatibility but cursor passed directly
        row: usize,
        content_width: usize,
        gutter_width: usize,
        is_cursor: bool,
    ) !usize {

        // Build header text: range and context
        var buf: [256]u8 = undefined;
        const old_end = hunk.header.old_start + hunk.header.old_count -| 1;
        const new_end = hunk.header.new_start + hunk.header.new_count -| 1;

        const header_text = try std.fmt.bufPrint(
            &buf,
            " ↕ {d}-{d} → {d}-{d}  {s}",
            .{
                hunk.header.old_start,
                old_end,
                hunk.header.new_start,
                new_end,
                hunk.header.context,
            },
        );

        // Calculate number of rows needed for wrapping
        const num_rows = if (header_text.len == 0) 1 else (header_text.len + content_width - 1) / content_width;

        const content_start = 1 + gutter_width + Layout.gutter_spacing;
        const fill_style: vaxis.Style = if (is_cursor)
            .{ .bg = Color.cursor_bg }
        else
            .{ .bg = Color.dim };

        // Find where context starts (after the range info and spacing)
        const range_end_marker = "  ";
        const range_end_pos = std.mem.indexOf(u8, header_text, range_end_marker);
        const range_len = if (range_end_pos) |pos| pos + range_end_marker.len else header_text.len;

        // Styles
        const range_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.white, .bg = Color.cursor_bg, .bold = true }
        else
            .{ .fg = Color.white, .bg = Color.dim, .bold = true };

        const context_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg }
        else
            .{ .fg = Color.white, .bg = Color.dim };

        const bar_char = "━";
        const char_bytes = bar_char.len; // 3 bytes

        // Render each wrapped row
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

            // Render solid bar in gutter (only on first row)
            // Bar only fills the line number area, not the diff sign column
            if (wrap_idx == 0) {
                const bar_width = gutter_width - 1; // Don't fill the sign column
                const gutter_bar = try RenderUtils.frameTextSlice(app, bar_width * char_bytes + 1); // +1 for space
                var byte_pos: usize = 0;
                for (0..bar_width) |_| {
                    if (byte_pos + char_bytes <= gutter_bar.len - 1) {
                        @memcpy(gutter_bar[byte_pos..byte_pos + char_bytes], bar_char);
                        byte_pos += char_bytes;
                    }
                }
                // Add trailing space for the sign column
                if (byte_pos < gutter_bar.len) {
                    gutter_bar[byte_pos] = ' ';
                    byte_pos += 1;
                }

                const gutter_style: vaxis.Style = if (is_cursor)
                    .{ .fg = Color.white, .bg = Color.cursor_bg }
                else
                    .{ .fg = Color.white, .bg = Color.dim };

                var gutter_seg = [_]vaxis.Cell.Segment{.{
                    .text = gutter_bar[0..byte_pos],
                    .style = gutter_style,
                }};
                _ = try win.print(&gutter_seg, .{ .row_offset = current_row, .col_offset = Layout.sidebar_width });
            } else {
                // Empty gutter for continuation rows
                const gutter_spaces = try RenderUtils.frameTextSlice(app, gutter_width);
                @memset(gutter_spaces, ' ');
                const empty_gutter_style: vaxis.Style = if (is_cursor)
                    .{ .bg = Color.cursor_bg }
                else
                    .{ .bg = Color.dim };
                var empty_gutter_seg = [_]vaxis.Cell.Segment{.{
                    .text = gutter_spaces,
                    .style = empty_gutter_style,
                }};
                _ = try win.print(&empty_gutter_seg, .{ .row_offset = current_row, .col_offset = Layout.sidebar_width });
            }

            // Render spacing after gutter
            try RenderUtils.renderGutterSpacing(app, win, current_row, 1 + gutter_width, is_cursor, null);

            // Render content for this row
            const text_start = wrap_idx * content_width;
            const text_end = @min(text_start + content_width, header_text.len);
            const chunk = if (text_start < header_text.len) header_text[text_start..text_end] else "";

            if (chunk.len > 0) {
                // Determine if we're in range or context section
                if (text_start < range_len) {
                    // This chunk contains range text (possibly mixed with context)
                    const range_chunk_end = @min(text_end, range_len);
                    const range_chunk = chunk[0..range_chunk_end - text_start];

                    if (range_chunk_end < text_end) {
                        // Mixed: range + context
                        const context_chunk = chunk[range_chunk_end - text_start..];
                        const range_text = try RenderUtils.copyFrameText(app, range_chunk);
                        const context_text = try RenderUtils.copyFrameText(app, context_chunk);

                        var segments = [_]vaxis.Cell.Segment{
                            .{ .text = range_text, .style = range_style },
                            .{ .text = context_text, .style = context_style },
                        };
                        _ = try win.print(&segments, .{ .row_offset = current_row, .col_offset = content_start });
                    } else {
                        // Pure range
                        const range_text = try RenderUtils.copyFrameText(app, range_chunk);
                        var seg = [_]vaxis.Cell.Segment{.{
                            .text = range_text,
                            .style = range_style,
                        }};
                        _ = try win.print(&seg, .{ .row_offset = current_row, .col_offset = content_start });
                    }
                } else {
                    // Pure context
                    const context_text = try RenderUtils.copyFrameText(app, chunk);
                    var seg = [_]vaxis.Cell.Segment{.{
                        .text = context_text,
                        .style = context_style,
                    }};
                    _ = try win.print(&seg, .{ .row_offset = current_row, .col_offset = content_start });
                }
            }

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
        _: usize, // line_idx kept for compatibility but cursor passed directly
        row: usize,
        content_width: usize,
        gutter_width: usize,
        is_cursor: bool,
    ) !usize {
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
            row,
            content_width,
            is_cursor,
            style,
            file_lineno,
            line.line_type,
            gutter_width,
        );
    }

    fn renderWrappedTextWithHighlights(
        app: *App,
        win: vaxis.Window,
        text: []const u8,
        byte_offset: usize,
        highlights: ?[]syntax.Highlight,
        start_row: usize,
        content_width: usize,
        is_cursor: bool,
        style: vaxis.Style,
        file_lineno: ?u32,
        line_type: ?parser.Line.LineType,
        gutter_width: usize,
    ) !usize {
        if (content_width == 0) return 1;

        // Handle empty lines explicitly
        if (text.len == 0) {
            try RenderUtils.renderGutter(app, win, 0, start_row, is_cursor, true, file_lineno, line_type, gutter_width);
            // Pad empty lines for cursor or diff lines (add/delete)
            const should_pad = is_cursor or (line_type != null and line_type.? != .context);
            const display_text = try RenderUtils.padTextForCursor(app, "", content_width, should_pad);
            var seg = [_]vaxis.Cell.Segment{.{
                .text = display_text,
                .style = style,
            }};
            _ = try win.print(&seg, .{ .row_offset = start_row, .col_offset = Layout.sidebar_width + gutter_width + Layout.gutter_spacing });

            return 1;
        }

        // No horizontal scrolling (removed with FOCUSED mode)
        var rows_rendered: usize = 0;
        var text_offset: usize = 0;

        while (text_offset < text.len) {
            const current_row = start_row + rows_rendered;
            if (current_row >= win.height) break;

            // Only show line number on first row
            const show_line_number = rows_rendered == 0;
            try RenderUtils.renderGutter(app, win, 0, current_row, is_cursor, show_line_number, file_lineno, line_type, gutter_width);

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

                _ = try win.print(padded_segments, .{ .row_offset = current_row, .col_offset = Layout.sidebar_width + gutter_width + Layout.gutter_spacing });
            } else {
                _ = try win.print(segments, .{ .row_offset = current_row, .col_offset = Layout.sidebar_width + gutter_width + Layout.gutter_spacing });
            }

            // Caret rendering removed with FOCUSED mode (show_caret is always false)

            text_offset += chunk_len;
            rows_rendered += 1;
        }

        return if (rows_rendered == 0) 1 else rows_rendered;
    }
};
