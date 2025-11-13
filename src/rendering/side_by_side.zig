const std = @import("std");
const vaxis = @import("vaxis");
const parser = @import("../git/parser.zig");
const syntax = @import("../syntax.zig");
const comments = @import("../comments.zig");
const rendering_common = @import("common.zig");
const render_utils = @import("utils.zig");
const state_helpers = @import("../state.zig");
const navigation = @import("../navigation.zig");
const file_header = @import("file_header.zig");

const App = @import("../app.zig").App;
const Color = rendering_common.Color;
const Layout = rendering_common.Layout;
const FrameChars = rendering_common.FrameChars;
const RenderUtils = render_utils.RenderUtils;
const StateHelpers = state_helpers.StateHelpers;
const Navigation = navigation.Navigation;
const FileHeader = file_header.FileHeader;

pub const SideBySideRenderer = struct {
    pub fn renderContent(app: *App, win: vaxis.Window) !void {
        if (app.state.files.len == 0) return;

        app.state.viewport_height = win.height;
        Navigation.clampScrollOffset(app);

        // Calculate global gutter width (consistent across all files)
        const gutter_width = StateHelpers.getGlobalGutterWidth(app.state.files);

        // Calculate layout: [sidebar][gutter][spacing][left_content][divider][gutter][spacing][right_content]
        // Total width = sidebar + 2 * gutter_width + 2 * spacing + 1 (middle divider) + left_content + right_content
        const total_borders_and_gutters = Layout.sidebar_width + (2 * gutter_width) + (2 * Layout.gutter_spacing) + 1;
        if (win.width <= total_borders_and_gutters) return; // Not enough space

        const available_width = win.width - total_borders_and_gutters;
        const left_content_width = available_width / 2;
        const right_content_width = available_width - left_content_width;

        const sidebar_style = .{ .fg = Color.dim };
        const middle_col = Layout.sidebar_width + gutter_width + Layout.gutter_spacing + left_content_width;

        var row: usize = 0;

        // Iterate through LineMap records (single source of truth for line positions)
        for (app.state.line_map.records) |*record| {
            const global_line = record.global_line;
            const file_idx = record.file_idx;

            // Skip lines before scroll offset
            if (global_line < app.state.global_scroll_offset) continue;
            if (row >= win.height) break;

            const file = &app.state.files[file_idx];
            try StateHelpers.ensureHighlights(app, file, false);
            const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

            // Render sidebar and middle divider for all line types
            var left_seg = [_]vaxis.Cell.Segment{.{
                .text = "┃",
                .style = sidebar_style,
            }};
            _ = try win.print(&left_seg, .{ .row_offset = row, .col_offset = 0 });
            var middle_seg = [_]vaxis.Cell.Segment{.{
                .text = FrameChars.vertical,
                .style = sidebar_style,
            }};
            _ = try win.print(&middle_seg, .{ .row_offset = row, .col_offset = middle_col });

            const is_cursor = global_line == app.state.global_cursor_line;

            // Render based on line type
            switch (record.line_type) {
                .file_header => {
                    const rows_used = try renderFileHeader(app, win, file, row, left_content_width, right_content_width, gutter_width, is_cursor);
                    row += rows_used;
                },
                .hunk_header => |hunk_info| {
                    const hunk = &file.hunks[hunk_info.hunk_idx];
                    const is_in_visual = app.isLineInVisualSelection(global_line);
                    const rows_used = try renderHunkHeader(app, win, hunk.*, row, left_content_width, right_content_width, gutter_width, is_cursor, is_in_visual);
                    row += rows_used;
                },
                .code_line => |code_info| {
                    const hunk = &file.hunks[code_info.hunk_idx];
                    const line = &hunk.lines[code_info.line_idx_in_hunk];
                    const rows_used = try renderDiffLine(app, win, file, code_info.hunk_idx, code_info.line_idx_in_hunk, line.*, global_line, row, left_content_width, right_content_width, gutter_width, is_cursor);
                    row += rows_used;

                    // Check if we're creating/editing a comment on this code line
                    if (app.mode == .comment and is_cursor) {
                        if (app.state.active_comment_input) |input| {
                            // Check if the active comment is for this line
                            if (std.mem.eql(u8, input.target_file_path, file_path) and
                                input.target_hunk_idx == code_info.hunk_idx and
                                input.target_line_idx == code_info.line_idx_in_hunk)
                            {
                                if (row < win.height) {
                                    const comment_start_row = row;
                                    const comment_rows = try renderSideBySideCommentInput(app, win, row, left_content_width, right_content_width, gutter_width, line.line_type);

                                    // Render sidebar and middle divider for all comment input rows
                                    var comment_row_idx: usize = 0;
                                    while (comment_row_idx < comment_rows and comment_start_row + comment_row_idx < win.height) : (comment_row_idx += 1) {
                                        var left_seg_cmt = [_]vaxis.Cell.Segment{.{
                                            .text = "┃",
                                            .style = sidebar_style,
                                        }};
                                        _ = try win.print(&left_seg_cmt, .{ .row_offset = comment_start_row + comment_row_idx, .col_offset = 0 });
                                        // No middle divider for comment boxes - they span full width
                                    }
                                    row += comment_rows;
                                }
                            }
                        }
                    }
                },
                .comment_line => |comment_info| {
                    if (app.state.comment_store.getComment(comment_info.comment_idx)) |comment| {
                        // Get parent line type for positioning the comment
                        const hunk = &file.hunks[comment_info.parent_hunk_idx];
                        const line = &hunk.lines[comment_info.parent_line_idx];

                        const comment_start_row = row;
                        const comment_rows = if (app.mode == .comment and is_cursor)
                            try renderSideBySideCommentInput(app, win, row, left_content_width, right_content_width, gutter_width, line.line_type)
                        else
                            try renderSideBySideComment(app, win, comment, row, left_content_width, right_content_width, gutter_width, line.line_type, is_cursor);

                        // Render sidebar for all comment rows (no middle divider - spans full width)
                        var comment_row_idx: usize = 1; // First sidebar already rendered above
                        while (comment_row_idx < comment_rows and comment_start_row + comment_row_idx < win.height) : (comment_row_idx += 1) {
                            var comment_sidebar = [_]vaxis.Cell.Segment{.{
                                .text = "┃",
                                .style = sidebar_style,
                            }};
                            _ = try win.print(&comment_sidebar, .{ .row_offset = comment_start_row + comment_row_idx, .col_offset = 0 });
                        }
                        row += comment_rows;
                    }
                },
                .spacer => {
                    // Render spacer - just empty line with cursor highlight if needed
                    if (is_cursor) {
                        const fill_start = 1; // After sidebar
                        const fill_width = win.width -| 1;
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
                },
            }
        }

        // Clear any remaining rows at the bottom of the screen
        while (row < win.height) : (row += 1) {
            var left_seg = [_]vaxis.Cell.Segment{.{
                .text = "┃",
                .style = sidebar_style,
            }};
            _ = try win.print(&left_seg, .{ .row_offset = row, .col_offset = 0 });
            var middle_seg = [_]vaxis.Cell.Segment{.{
                .text = FrameChars.vertical,
                .style = sidebar_style,
            }};
            _ = try win.print(&middle_seg, .{ .row_offset = row, .col_offset = middle_col });
        }

        // Update current_file_idx based on what's at the top of viewport (for sticky header)
        // Use scroll offset instead of cursor position for more accurate header display
        app.state.current_file_idx = app.state.line_map.getFileIndexForLine(app.state.global_scroll_offset) orelse 0;
    }

    fn renderFileHeader(
        app: *App,
        win: vaxis.Window,
        file: *const parser.FileDiff,
        row: usize,
        _: usize, // left_width
        _: usize, // right_width
        _: usize, // gutter_width
        is_cursor: bool,
    ) !usize {
        // For now, use simple file header similar to unified mode
        // TODO: Implement proper side-by-side file header if needed
        const rows_used = try FileHeader.render(app, win, file, row, is_cursor);
        return rows_used;
    }

    fn renderHunkHeader(
        app: *App,
        win: vaxis.Window,
        hunk: parser.Hunk,
        row: usize,
        left_width: usize,
        right_width: usize,
        gutter_width: usize,
        is_cursor: bool,
        is_in_visual: bool,
    ) !usize {
        _ = right_width; // Same text on both sides, so right_width not needed

        // Build header text: range and context
        var buf: [256]u8 = undefined;
        const old_end = hunk.header.old_start + hunk.header.old_count -| 1;
        const new_end = hunk.header.new_start + hunk.header.new_count -| 1;

        const header_text = try std.fmt.bufPrint(
            &buf,
            "↕ {d}-{d} → {d}-{d}  {s}",
            .{
                hunk.header.old_start,
                old_end,
                hunk.header.new_start,
                new_end,
                hunk.header.context,
            },
        );

        // Calculate number of rows needed for wrapping (based on left width)
        const num_rows = if (header_text.len == 0) 1 else (header_text.len + left_width - 1) / left_width;

        const fill_style: vaxis.Style = if (is_cursor and app.mode == .visual)
            .{ .bg = Color.visual_select_bg }
        else if (is_cursor)
            .{ .bg = Color.cursor_bg }
        else if (is_in_visual)
            .{ .bg = Color.visual_select_bg }
        else
            .{ .bg = Color.dim };

        // Find where context starts (after the range info and spacing)
        const range_end_marker = "  ";
        const range_end_pos = std.mem.indexOf(u8, header_text, range_end_marker);
        const range_len = if (range_end_pos) |pos| pos + range_end_marker.len else header_text.len;

        // Styles
        const range_style: vaxis.Style = if (is_cursor and app.mode == .visual)
            .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = true }
        else if (is_cursor)
            .{ .fg = Color.white, .bg = Color.cursor_bg, .bold = true }
        else if (is_in_visual)
            .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = true }
        else
            .{ .fg = Color.white, .bg = Color.dim, .bold = true };

        const context_style: vaxis.Style = if (is_cursor and app.mode == .visual)
            .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg }
        else if (is_cursor)
            .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg }
        else if (is_in_visual)
            .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg }
        else
            .{ .fg = Color.white, .bg = Color.dim };

        const bar_char = "━";
        const char_bytes = bar_char.len; // 3 bytes
        const right_col = 1 + gutter_width + Layout.gutter_spacing + left_width + 1;

        // Render each wrapped row
        var current_row = row;
        const sidebar_style = .{ .fg = Color.dim };
        const middle_col = Layout.sidebar_width + gutter_width + Layout.gutter_spacing + left_width;

        for (0..num_rows) |wrap_idx| {
            if (current_row >= win.height) break;

            // Render sidebar and middle divider for continuation rows
            if (wrap_idx > 0) {
                var left_seg = [_]vaxis.Cell.Segment{.{
                    .text = "┃",
                    .style = sidebar_style,
                }};
                _ = try win.print(&left_seg, .{ .row_offset = current_row, .col_offset = 0 });
                var middle_seg = [_]vaxis.Cell.Segment{.{
                    .text = FrameChars.vertical,
                    .style = sidebar_style,
                }};
                _ = try win.print(&middle_seg, .{ .row_offset = current_row, .col_offset = middle_col });
            }

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

            // Render left gutter (bar on first row, empty on continuation rows)
            // Fill entire gutter width with bars (no sign column for hunk headers)
            if (wrap_idx == 0) {
                const bar_width = gutter_width; // Fill entire gutter
                const left_gutter_bar = try RenderUtils.frameTextSlice(app, bar_width * char_bytes);
                var left_byte_pos: usize = 0;
                for (0..bar_width) |_| {
                    if (left_byte_pos + char_bytes <= left_gutter_bar.len) {
                        @memcpy(left_gutter_bar[left_byte_pos .. left_byte_pos + char_bytes], bar_char);
                        left_byte_pos += char_bytes;
                    }
                }

                const gutter_style: vaxis.Style = if (is_cursor)
                    .{ .fg = Color.white, .bg = Color.cursor_bg }
                else
                    .{ .fg = Color.white, .bg = Color.dim };

                var left_gutter_seg = [_]vaxis.Cell.Segment{.{
                    .text = left_gutter_bar[0..left_byte_pos],
                    .style = gutter_style,
                }};
                _ = try win.print(&left_gutter_seg, .{ .row_offset = current_row, .col_offset = 1 });
            } else {
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
                _ = try win.print(&empty_gutter_seg, .{ .row_offset = current_row, .col_offset = 1 });
            }

            // Render spacing after left gutter
            try RenderUtils.renderGutterSpacing(app, win, current_row, 1 + gutter_width, is_cursor, null);

            // Render left content
            const text_start = wrap_idx * left_width;
            const text_end = @min(text_start + left_width, header_text.len);
            const chunk = if (text_start < header_text.len) header_text[text_start..text_end] else "";

            const left_content_start = 1 + gutter_width + Layout.gutter_spacing;
            if (chunk.len > 0) {
                if (text_start < range_len) {
                    const range_chunk_end = @min(text_end, range_len);
                    const range_chunk = chunk[0 .. range_chunk_end - text_start];

                    if (range_chunk_end < text_end) {
                        const context_chunk = chunk[range_chunk_end - text_start ..];
                        const range_text = try RenderUtils.copyFrameText(app, range_chunk);
                        const context_text = try RenderUtils.copyFrameText(app, context_chunk);

                        var segments = [_]vaxis.Cell.Segment{
                            .{ .text = range_text, .style = range_style },
                            .{ .text = context_text, .style = context_style },
                        };
                        _ = try win.print(&segments, .{ .row_offset = current_row, .col_offset = left_content_start });
                    } else {
                        const range_text = try RenderUtils.copyFrameText(app, range_chunk);
                        var seg = [_]vaxis.Cell.Segment{.{
                            .text = range_text,
                            .style = range_style,
                        }};
                        _ = try win.print(&seg, .{ .row_offset = current_row, .col_offset = left_content_start });
                    }
                } else {
                    const context_text = try RenderUtils.copyFrameText(app, chunk);
                    var seg = [_]vaxis.Cell.Segment{.{
                        .text = context_text,
                        .style = context_style,
                    }};
                    _ = try win.print(&seg, .{ .row_offset = current_row, .col_offset = left_content_start });
                }
            }

            // Render right gutter (bar on first row, empty on continuation rows)
            // Fill entire gutter width with bars (no sign column for hunk headers)
            if (wrap_idx == 0) {
                const bar_width = gutter_width; // Fill entire gutter
                const right_gutter_bar = try RenderUtils.frameTextSlice(app, bar_width * char_bytes);
                var right_byte_pos: usize = 0;
                for (0..bar_width) |_| {
                    if (right_byte_pos + char_bytes <= right_gutter_bar.len) {
                        @memcpy(right_gutter_bar[right_byte_pos .. right_byte_pos + char_bytes], bar_char);
                        right_byte_pos += char_bytes;
                    }
                }

                const gutter_style: vaxis.Style = if (is_cursor)
                    .{ .fg = Color.white, .bg = Color.cursor_bg }
                else
                    .{ .fg = Color.white, .bg = Color.dim };

                var right_gutter_seg = [_]vaxis.Cell.Segment{.{
                    .text = right_gutter_bar[0..right_byte_pos],
                    .style = gutter_style,
                }};
                _ = try win.print(&right_gutter_seg, .{ .row_offset = current_row, .col_offset = right_col });
            } else {
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
                _ = try win.print(&empty_gutter_seg, .{ .row_offset = current_row, .col_offset = right_col });
            }

            // Render spacing after right gutter
            try RenderUtils.renderGutterSpacing(app, win, current_row, right_col + gutter_width, is_cursor, null);

            // Render right content (same as left)
            const right_content_start = right_col + gutter_width + Layout.gutter_spacing;
            if (chunk.len > 0) {
                if (text_start < range_len) {
                    const range_chunk_end = @min(text_end, range_len);
                    const range_chunk = chunk[0 .. range_chunk_end - text_start];

                    if (range_chunk_end < text_end) {
                        const context_chunk = chunk[range_chunk_end - text_start ..];
                        const range_text = try RenderUtils.copyFrameText(app, range_chunk);
                        const context_text = try RenderUtils.copyFrameText(app, context_chunk);

                        var segments = [_]vaxis.Cell.Segment{
                            .{ .text = range_text, .style = range_style },
                            .{ .text = context_text, .style = context_style },
                        };
                        _ = try win.print(&segments, .{ .row_offset = current_row, .col_offset = right_content_start });
                    } else {
                        const range_text = try RenderUtils.copyFrameText(app, range_chunk);
                        var seg = [_]vaxis.Cell.Segment{.{
                            .text = range_text,
                            .style = range_style,
                        }};
                        _ = try win.print(&seg, .{ .row_offset = current_row, .col_offset = right_content_start });
                    }
                } else {
                    const context_text = try RenderUtils.copyFrameText(app, chunk);
                    var seg = [_]vaxis.Cell.Segment{.{
                        .text = context_text,
                        .style = context_style,
                    }};
                    _ = try win.print(&seg, .{ .row_offset = current_row, .col_offset = right_content_start });
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
        global_line: usize,
        row: usize,
        left_width: usize,
        right_width: usize,
        gutter_width: usize,
        is_cursor: bool,
    ) !usize {
        const base_style = RenderUtils.getLineStyle(app, line.line_type);
        const is_in_visual = app.isLineInVisualSelection(global_line);
        const style: vaxis.Style = if (is_cursor and app.mode == .visual)
            // Cursor in visual mode uses visual selection colors
            .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = true }
        else if (is_cursor)
            // Normal cursor
            .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
        else if (is_in_visual)
            // Visual selection (non-cursor lines)
            .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = false }
        else
            base_style;

        const sidebar_style = .{ .fg = Color.dim };
        const middle_col = Layout.sidebar_width + gutter_width + Layout.gutter_spacing + left_width;
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

                    // Render sidebar and middle divider for continuation rows
                    if (wrap_idx > 0) {
                        var left_seg = [_]vaxis.Cell.Segment{.{
                            .text = "┃",
                            .style = sidebar_style,
                        }};
                        _ = try win.print(&left_seg, .{ .row_offset = current_row, .col_offset = 0 });
                        var middle_seg = [_]vaxis.Cell.Segment{.{
                            .text = FrameChars.vertical,
                            .style = sidebar_style,
                        }};
                        _ = try win.print(&middle_seg, .{ .row_offset = current_row, .col_offset = middle_col });
                    }

                    const show_lineno = wrap_idx == 0;

                    // Render left side
                    try RenderUtils.renderGutter(app, win, 0, current_row, is_cursor, show_lineno, line.old_lineno, line.line_type, gutter_width);

                    const left_start = wrap_idx * left_width;
                    const left_end = @min(left_start + left_width, line.content.len);
                    const left_chunk = if (left_start < line.content.len) line.content[left_start..left_end] else "";

                    // Generate syntax-highlighted segments for left chunk
                    const left_chunk_byte_offset = byte_offset + left_start;
                    const left_segments = try app.createHighlightedSegments(left_chunk, line.content, left_start, left_chunk_byte_offset, file.highlights, style, global_line);
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
                    try renderGutterAtColumn(app, win, current_row, is_cursor, show_lineno, line.new_lineno, right_col, line.line_type, gutter_width);

                    const right_start = wrap_idx * right_width;
                    const right_end = @min(right_start + right_width, line.content.len);
                    const right_chunk = if (right_start < line.content.len) line.content[right_start..right_end] else "";

                    // Generate syntax-highlighted segments for right chunk
                    const right_chunk_byte_offset = byte_offset + right_start;
                    const right_segments = try app.createHighlightedSegments(right_chunk, line.content, right_start, right_chunk_byte_offset, file.highlights, style, global_line);
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

                    // Render sidebar and middle divider for continuation rows
                    if (wrap_idx > 0) {
                        var left_seg = [_]vaxis.Cell.Segment{.{
                            .text = "┃",
                            .style = sidebar_style,
                        }};
                        _ = try win.print(&left_seg, .{ .row_offset = current_row, .col_offset = 0 });
                        var middle_seg = [_]vaxis.Cell.Segment{.{
                            .text = FrameChars.vertical,
                            .style = sidebar_style,
                        }};
                        _ = try win.print(&middle_seg, .{ .row_offset = current_row, .col_offset = middle_col });
                    }

                    const show_lineno = wrap_idx == 0;

                    // Render left side
                    try RenderUtils.renderGutter(app, win, 0, current_row, is_cursor, show_lineno, line.old_lineno, line.line_type, gutter_width);

                    const text_start = wrap_idx * left_width;
                    const text_end = @min(text_start + left_width, line.content.len);
                    const chunk = if (text_start < line.content.len) line.content[text_start..text_end] else "";

                    // Generate syntax-highlighted segments for chunk
                    // (will fall back to plain text for delete lines since they're not in new file)
                    const chunk_byte_offset = byte_offset + text_start;
                    const segments = try app.createHighlightedSegments(chunk, line.content, text_start, chunk_byte_offset, file.highlights, style, global_line);
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
                        try renderGutterAtColumn(app, win, current_row, is_cursor, false, null, right_col, null, gutter_width);
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

                    // Render sidebar and middle divider for continuation rows
                    if (wrap_idx > 0) {
                        var left_seg = [_]vaxis.Cell.Segment{.{
                            .text = "┃",
                            .style = sidebar_style,
                        }};
                        _ = try win.print(&left_seg, .{ .row_offset = current_row, .col_offset = 0 });
                        var middle_seg = [_]vaxis.Cell.Segment{.{
                            .text = FrameChars.vertical,
                            .style = sidebar_style,
                        }};
                        _ = try win.print(&middle_seg, .{ .row_offset = current_row, .col_offset = middle_col });
                    }

                    const show_lineno = wrap_idx == 0;

                    // Left side empty with cursor highlight if needed
                    if (is_cursor) {
                        try RenderUtils.renderGutter(app, win, 0, current_row, is_cursor, false, null, null, gutter_width);
                        const blank = try RenderUtils.frameTextSlice(app, left_width);
                        @memset(blank, ' ');
                        var blank_seg = [_]vaxis.Cell.Segment{.{
                            .text = blank,
                            .style = .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg },
                        }};
                        _ = try win.print(&blank_seg, .{ .row_offset = current_row, .col_offset = 1 + gutter_width + Layout.gutter_spacing });
                    }

                    // Render right side
                    try renderGutterAtColumn(app, win, current_row, is_cursor, show_lineno, line.new_lineno, right_col, line.line_type, gutter_width);

                    const text_start = wrap_idx * right_width;
                    const text_end = @min(text_start + right_width, line.content.len);
                    const chunk = if (text_start < line.content.len) line.content[text_start..text_end] else "";

                    // Generate syntax-highlighted segments for chunk
                    const chunk_byte_offset = byte_offset + text_start;
                    const segments = try app.createHighlightedSegments(chunk, line.content, text_start, chunk_byte_offset, file.highlights, style, global_line);
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
        row: usize,
        is_cursor: bool,
        show_number: bool,
        file_lineno: ?u32,
        col_offset: usize,
        line_type: ?parser.Line.LineType,
        gutter_width: usize,
    ) !void {
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

    /// Render comment input box in side-by-side mode
    fn renderSideBySideCommentInput(
        app: *App,
        win: vaxis.Window,
        row: usize,
        left_width: usize,
        right_width: usize,
        gutter_width: usize,
        line_type: parser.Line.LineType,
    ) !usize {
        if (app.state.active_comment_input == null) return 0;
        if (row + 2 >= win.height) return 0; // Need at least 3 rows

        const input = app.state.active_comment_input.?;

        // Determine positioning based on line type
        const PaneLayout = struct {
            start_col: usize,
            width: usize,
        };

        const layout: PaneLayout = switch (line_type) {
            .delete => .{
                // Left pane only
                .start_col = 1 + gutter_width + Layout.gutter_spacing,
                .width = left_width,
            },
            .add => .{
                // Right pane only
                .start_col = 1 + gutter_width + Layout.gutter_spacing + left_width + 1 + gutter_width + Layout.gutter_spacing,
                .width = right_width,
            },
            .context => .{
                // Across both panes
                .start_col = 1 + gutter_width + Layout.gutter_spacing,
                .width = left_width + 1 + gutter_width + Layout.gutter_spacing + right_width, // Include middle divider and right gutter
            },
        };

        if (layout.width < 20) return 0; // Box too narrow

        const box_style: vaxis.Style = .{ .fg = Color.yellow, .bg = Color.dim, .bold = true };
        const text_style: vaxis.Style = .{ .fg = Color.white, .bg = Color.dim };

        var segments = std.ArrayList(vaxis.Cell.Segment).init(app.allocator);
        defer segments.deinit();

        // Top border: ╭─ Comment ─────╮
        const label = " Comment ";
        const top_h_count = layout.width - 3 - label.len;

        try segments.append(.{ .text = try RenderUtils.copyFrameText(app, FrameChars.top_left), .style = box_style });
        try segments.append(.{ .text = try RenderUtils.copyFrameText(app, FrameChars.horizontal), .style = box_style });
        try segments.append(.{ .text = try RenderUtils.copyFrameText(app, label), .style = box_style });

        var i: usize = 0;
        while (i < top_h_count) : (i += 1) {
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, FrameChars.horizontal), .style = box_style });
        }
        try segments.append(.{ .text = try RenderUtils.copyFrameText(app, FrameChars.top_right), .style = box_style });

        _ = try win.print(segments.items, .{ .row_offset = row, .col_offset = layout.start_col });

        // Content line: │ text │
        segments.clearRetainingCapacity();

        const input_text = input.text_buffer[0..input.text_len];
        const first_line_end = std.mem.indexOfScalar(u8, input_text, '\n') orelse input_text.len;
        const first_line = input_text[0..first_line_end];

        const content_width = layout.width - 2; // -2 for left and right borders
        const display_text = blk: {
            var buf = try RenderUtils.frameTextSlice(app, content_width);
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

        try segments.append(.{ .text = try RenderUtils.copyFrameText(app, FrameChars.vertical), .style = box_style });
        try segments.append(.{ .text = display_text, .style = text_style });
        try segments.append(.{ .text = try RenderUtils.copyFrameText(app, FrameChars.vertical), .style = box_style });

        _ = try win.print(segments.items, .{ .row_offset = row + 1, .col_offset = layout.start_col });

        // Draw cursor
        const cursor_visible_pos = if (input.cursor_pos <= first_line_end) input.cursor_pos else first_line_end;
        const text_area_max = content_width - 2;
        if (cursor_visible_pos < text_area_max) {
            const cursor_col = layout.start_col + 2 + cursor_visible_pos;
            const cursor_char = if (cursor_visible_pos < first_line.len) first_line[cursor_visible_pos .. cursor_visible_pos + 1] else " ";
            var cursor_seg = [_]vaxis.Cell.Segment{.{
                .text = try RenderUtils.copyFrameText(app, cursor_char),
                .style = .{ .fg = Color.black, .bg = Color.white },
            }};
            _ = try win.print(&cursor_seg, .{ .row_offset = row + 1, .col_offset = cursor_col });
        }

        // Bottom border: ╰─ Enter:Save  ESC:Cancel ─╯
        segments.clearRetainingCapacity();

        const help_text = " Enter:Save  ESC:Cancel ";
        const bottom_h_count = layout.width - 3 - help_text.len;

        try segments.append(.{ .text = try RenderUtils.copyFrameText(app, FrameChars.bottom_left), .style = box_style });
        try segments.append(.{ .text = try RenderUtils.copyFrameText(app, FrameChars.horizontal), .style = box_style });
        try segments.append(.{ .text = try RenderUtils.copyFrameText(app, help_text), .style = box_style });

        i = 0;
        while (i < bottom_h_count) : (i += 1) {
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, FrameChars.horizontal), .style = box_style });
        }
        try segments.append(.{ .text = try RenderUtils.copyFrameText(app, FrameChars.bottom_right), .style = box_style });

        _ = try win.print(segments.items, .{ .row_offset = row + 2, .col_offset = layout.start_col });

        return 3; // Used 3 rows
    }

    /// Render saved comment display in side-by-side mode
    fn renderSideBySideComment(
        app: *App,
        win: vaxis.Window,
        comment: *const comments.Comment,
        row: usize,
        left_width: usize,
        right_width: usize,
        gutter_width: usize,
        line_type: parser.Line.LineType,
        is_cursor: bool,
    ) !usize {
        // Determine positioning based on line type
        const PaneLayout = struct {
            start_col: usize,
            width: usize,
        };

        const layout: PaneLayout = switch (line_type) {
            .delete => .{
                // Left pane only
                .start_col = 1 + gutter_width + Layout.gutter_spacing,
                .width = left_width,
            },
            .add => .{
                // Right pane only
                .start_col = 1 + gutter_width + Layout.gutter_spacing + left_width + 1 + gutter_width + Layout.gutter_spacing,
                .width = right_width,
            },
            .context => .{
                // Across both panes
                .start_col = 1 + gutter_width + Layout.gutter_spacing,
                .width = left_width + 1 + gutter_width + Layout.gutter_spacing + right_width,
            },
        };

        if (layout.width < 20) return 0;

        const box_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.yellow, .bg = Color.cursor_bg, .bold = true }
        else
            .{ .fg = Color.cyan, .bg = Color.dim, .bold = true };

        const text_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg }
        else
            .{ .fg = Color.white, .bg = Color.dim };

        var segments = std.ArrayList(vaxis.Cell.Segment).init(app.allocator);
        defer segments.deinit();

        // Top border: ╭─ Comment ─────╮
        const label = " Comment ";
        const top_h_count = layout.width - 3 - label.len;

        try segments.append(.{ .text = try RenderUtils.copyFrameText(app, FrameChars.top_left), .style = box_style });
        try segments.append(.{ .text = try RenderUtils.copyFrameText(app, FrameChars.horizontal), .style = box_style });
        try segments.append(.{ .text = try RenderUtils.copyFrameText(app, label), .style = box_style });

        var i: usize = 0;
        while (i < top_h_count) : (i += 1) {
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, FrameChars.horizontal), .style = box_style });
        }
        try segments.append(.{ .text = try RenderUtils.copyFrameText(app, FrameChars.top_right), .style = box_style });

        _ = try win.print(segments.items, .{ .row_offset = row, .col_offset = layout.start_col });

        // Render comment text lines
        var lines_used: usize = 1;
        const content_width = layout.width - 2; // -2 for borders
        var line_iter = std.mem.splitScalar(u8, comment.text, '\n');

        while (line_iter.next()) |text_line| {
            if (row + lines_used >= win.height) break;

            segments.clearRetainingCapacity();

            const display_text = blk: {
                var buf = try RenderUtils.frameTextSlice(app, content_width);
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

            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, FrameChars.vertical), .style = box_style });
            try segments.append(.{ .text = display_text, .style = text_style });
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, FrameChars.vertical), .style = box_style });

            _ = try win.print(segments.items, .{ .row_offset = row + lines_used, .col_offset = layout.start_col });
            lines_used += 1;
        }

        // Bottom border: ╰───────────╯
        if (row + lines_used < win.height) {
            segments.clearRetainingCapacity();

            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, FrameChars.bottom_left), .style = box_style });
            i = 0;
            while (i < layout.width - 2) : (i += 1) {
                try segments.append(.{ .text = try RenderUtils.copyFrameText(app, FrameChars.horizontal), .style = box_style });
            }
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, FrameChars.bottom_right), .style = box_style });

            _ = try win.print(segments.items, .{ .row_offset = row + lines_used, .col_offset = layout.start_col });
            lines_used += 1;
        }

        return lines_used;
    }
};
