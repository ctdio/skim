const std = @import("std");
const vaxis = @import("vaxis");
const parser = @import("../git/parser.zig");
const syntax = @import("../highlighting/core.zig");
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

pub const UnifiedRenderer = struct {
    pub fn renderContent(app: *App, win: vaxis.Window) !void {
        if (app.state.files.len == 0) return;

        app.state.viewport_height = win.height;
        Navigation.clampScrollOffset(app);

        // Calculate global gutter width (consistent across all files)
        const gutter_width = StateHelpers.getGlobalGutterWidthWithBlame(app.state.files, app.state.show_blame);
        const content_width = win.width -| (Layout.sidebar_width + gutter_width + Layout.gutter_spacing);
        const sidebar_style: vaxis.Cell.Style = .{ .fg = Color.dim };

        var row: usize = 0;
        var last_highlighted_file_idx: ?usize = null;

        // Iterate through LineMap records (single source of truth for line positions)
        for (app.state.line_map.records) |*record| {
            const global_line = record.global_line;
            const file_idx = record.file_idx;

            // Skip lines before scroll offset
            if (global_line < app.state.global_scroll_offset) continue;
            if (row >= win.height) break;

            const file = &app.state.files[file_idx];

            // Only highlight once per file (not once per line!)
            if (last_highlighted_file_idx == null or last_highlighted_file_idx.? != file_idx) {
                try StateHelpers.ensureHighlights(app, file, false);
                last_highlighted_file_idx = file_idx;
            }

            const is_cursor = global_line == app.state.global_cursor_line;

            // Render sidebar for all line types except spacers and file headers
            if (record.line_type != .spacer and record.line_type != .file_header) {
                var sidebar_seg = [_]vaxis.Cell.Segment{.{
                    .text = "┃",
                    .style = sidebar_style,
                }};
                _ = win.print(&sidebar_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(0 )});
            }

            // Render based on line type
            switch (record.line_type) {
                .file_header => {
                    const rows_used = try FileHeader.render(app, win, file, row, is_cursor);
                    row += rows_used;
                },
                .hunk_header => |hunk_info| {
                    const hunk = &file.hunks[hunk_info.hunk_idx];
                    const is_in_visual = app.isLineInVisualSelection(global_line);
                    const rows_used = try renderHunkHeader(app, win, hunk.*, global_line, row, content_width, gutter_width, is_cursor, is_in_visual);
                    row += rows_used;
                },
                .code_line => |code_info| {
                    const hunk = &file.hunks[code_info.hunk_idx];
                    const line = &hunk.lines[code_info.line_idx_in_hunk];
                    const rows_used = try renderDiffLine(app, win, file, code_info.hunk_idx, code_info.line_idx_in_hunk, line.*, global_line, row, content_width, gutter_width, is_cursor);
                    row += rows_used;

                    // Check if we're creating a NEW comment on this code line
                    // (If editing an existing comment, it will be rendered in place of the comment_line below)
                    if (app.mode == .comment and is_cursor) {
                        if (app.state.active_comment_input) |input| {
                            const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

                            // Check if this line is in the comment range (for new comments only)
                            const is_in_comment_range = blk: {
                                if (input.editing_comment_idx != null) break :blk false;
                                if (!std.mem.eql(u8, input.target_file_path, file_path)) break :blk false;
                                if (input.target_hunk_idx != code_info.hunk_idx) break :blk false;

                                // Check if line is within range
                                if (input.target_end_line_idx) |end_idx| {
                                    // Range comment - check if current line is within [start, end]
                                    const start_idx = input.target_line_idx;
                                    const current_idx = code_info.line_idx_in_hunk;
                                    break :blk (current_idx >= start_idx and current_idx <= end_idx);
                                } else {
                                    // Single-line comment - exact match
                                    break :blk (input.target_line_idx == code_info.line_idx_in_hunk);
                                }
                            };

                            if (is_in_comment_range)
                            {
                                if (row < win.height) {
                                    const comment_start_row = row;
                                    const comment_rows = try RenderUtils.renderCommentInputBox(app, win, row, gutter_width);

                                    // Render sidebar for all comment input rows
                                    var comment_row_idx: usize = 0;
                                    while (comment_row_idx < comment_rows and comment_start_row + comment_row_idx < win.height) : (comment_row_idx += 1) {
                                        var comment_sidebar = [_]vaxis.Cell.Segment{.{
                                            .text = "┃",
                                            .style = sidebar_style,
                                        }};
                                        _ = win.print(&comment_sidebar, .{ .row_offset = @intCast(comment_start_row + comment_row_idx), .col_offset = @intCast(0 )});
                                    }
                                    row += comment_rows;
                                }
                            }
                        }
                    }
                },
                .comment_line => |comment_info| {
                    if (app.state.comment_store.getComment(comment_info.comment_idx)) |comment| {
                        const comment_start_row = row;

                        // Check if we're editing THIS specific comment
                        const is_editing_this_comment = blk: {
                            if (app.mode == .comment and is_cursor) {
                                if (app.state.active_comment_input) |input| {
                                    if (input.editing_comment_idx) |editing_idx| {
                                        break :blk editing_idx == comment_info.comment_idx;
                                    }
                                }
                            }
                            break :blk false;
                        };

                        const comment_rows = if (is_editing_this_comment)
                            try RenderUtils.renderCommentInputBox(app, win, row, gutter_width)
                        else
                            try RenderUtils.renderCommentDisplay(app, win, comment, comment_info.comment_idx, row, gutter_width, is_cursor);

                        // Render sidebar for all comment rows
                        var comment_row_idx: usize = 1; // First sidebar already rendered above
                        while (comment_row_idx < comment_rows and comment_start_row + comment_row_idx < win.height) : (comment_row_idx += 1) {
                            var comment_sidebar = [_]vaxis.Cell.Segment{.{
                                .text = "┃",
                                .style = sidebar_style,
                            }};
                            _ = win.print(&comment_sidebar, .{ .row_offset = @intCast(comment_start_row + comment_row_idx), .col_offset = @intCast(0 )});
                        }
                        row += comment_rows;
                    }
                },
                .spacer => {
                    // Render spacer - just empty line with cursor highlight if needed (no left border)
                    if (is_cursor) {
                        const fill_start = 0; // No sidebar for spacers
                        const fill_width = win.width;
                        if (fill_width > 0) {
                            const fill_text = try RenderUtils.frameTextSlice(app, fill_width);
                            @memset(fill_text, ' ');
                            var fill_seg = [_]vaxis.Cell.Segment{.{
                                .text = fill_text,
                                .style = .{ .bg = Color.cursor_bg },
                            }};
                            _ = win.print(&fill_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(fill_start )});
                        }
                    }
                    row += 1;
                },
            }
        }

        // Clear any remaining rows at the bottom of the screen
        // This ensures old content doesn't linger when we scroll/jump
        // IMPORTANT: Must fill the entire row, not just the sidebar, because vaxis
        // uses differential rendering and won't clear cells that haven't changed
        while (row < win.height) : (row += 1) {
            // Fill the entire row with spaces first to clear old content
            const fill_text = try RenderUtils.frameTextSlice(app, win.width);
            @memset(fill_text, ' ');
            var fill_seg = [_]vaxis.Cell.Segment{.{
                .text = fill_text,
                .style = .{},
            }};
            _ = win.print(&fill_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(0) });

            // Then render the sidebar
            var sidebar_seg = [_]vaxis.Cell.Segment{.{
                .text = "┃",
                .style = sidebar_style,
            }};
            _ = win.print(&sidebar_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(0) });
        }

        // Render scrollbar if content is scrollable
        const total_lines = app.state.line_map.records.len;
        if (total_lines > win.height) {
            const scrollbar_info = rendering_common.calculateScrollbar(win.height, total_lines, app.state.global_scroll_offset);
            rendering_common.renderScrollbar(win, scrollbar_info);
        }

        // Update current_file_idx based on what's at the top of viewport (for sticky header)
        // Use scroll offset instead of cursor position for more accurate header display
        app.state.current_file_idx = app.state.line_map.getFileIndexForLine(app.state.global_scroll_offset) orelse 0;
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
        is_in_visual: bool,
    ) !usize {
        // Build header text using shared utility
        var buf: [256]u8 = undefined;
        const header_text = try RenderUtils.buildHunkHeaderText(hunk, &buf);

        // Calculate number of rows needed for wrapping (use display width, not bytes)
        const text_display_width = RenderUtils.displayWidth(header_text);
        const num_rows = if (text_display_width == 0) 1 else (text_display_width + content_width - 1) / content_width;

        const content_start = 1 + gutter_width + Layout.gutter_spacing;

        // Get styles using shared utilities
        const fill_style = RenderUtils.getFillStyle(app, is_cursor, is_in_visual);
        const range_len = RenderUtils.findHunkHeaderRangeEnd(header_text);
        const range_style = RenderUtils.getHunkRangeStyle(app, is_cursor, is_in_visual);
        const context_style = RenderUtils.getHunkContextStyle(app, is_cursor, is_in_visual);

        // Render each wrapped row
        var current_row = row;
        for (0..num_rows) |wrap_idx| {
            if (current_row >= win.height) break;

            // Render sidebar for continuation rows (first row already has sidebar from main loop)
            if (wrap_idx > 0) {
                try RenderUtils.renderContinuationBorders(win, current_row, null);
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
                _ = win.print(&fill_seg, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(fill_start )});
            }

            // Render spaces in gutter (no bar)
            const gutter_spaces = try RenderUtils.frameTextSlice(app, gutter_width);
            @memset(gutter_spaces, ' ');
            const gutter_style: vaxis.Style = if (is_cursor)
                .{ .bg = Color.cursor_bg }
            else
                .{};
            var gutter_seg = [_]vaxis.Cell.Segment{.{
                .text = gutter_spaces,
                .style = gutter_style,
            }};
            _ = win.print(&gutter_seg, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(Layout.sidebar_width )});

            // Render spacing after gutter
            try RenderUtils.renderGutterSpacing(app, win, current_row, 1 + gutter_width, is_cursor, null);

            // Render content for this row (slice by display width, not bytes)
            // Skip codepoints for previous rows, then take up to content_width codepoints
            const display_start = wrap_idx * content_width;
            const byte_start = RenderUtils.skipCodepoints(header_text, display_start);
            const remaining_text = if (byte_start < header_text.len) header_text[byte_start..] else "";
            const chunk = RenderUtils.sliceByDisplayWidth(remaining_text, content_width);

            // Calculate display position of range boundary
            const range_display_len = RenderUtils.displayWidth(header_text[0..range_len]);

            if (chunk.len > 0) {
                // Determine if we're in range or context section based on display position
                if (display_start < range_display_len) {
                    // This chunk starts in range section (possibly mixed with context)
                    const display_end = display_start + RenderUtils.displayWidth(chunk);
                    if (display_end <= range_display_len) {
                        // Pure range
                        const range_text = try RenderUtils.copyFrameText(app, chunk);
                        var seg = [_]vaxis.Cell.Segment{.{
                            .text = range_text,
                            .style = range_style,
                        }};
                        _ = win.print(&seg, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(content_start )});
                    } else {
                        // Mixed: range + context - split at the boundary
                        const range_codepoints = range_display_len - display_start;
                        const range_chunk = RenderUtils.sliceByDisplayWidth(chunk, range_codepoints);
                        const context_byte_start = range_chunk.len;
                        const context_chunk = chunk[context_byte_start..];

                        const range_text = try RenderUtils.copyFrameText(app, range_chunk);
                        const context_text = try RenderUtils.copyFrameText(app, context_chunk);

                        var segments = [_]vaxis.Cell.Segment{
                            .{ .text = range_text, .style = range_style },
                            .{ .text = context_text, .style = context_style },
                        };
                        _ = win.print(&segments, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(content_start )});
                    }
                } else {
                    // Pure context
                    const context_text = try RenderUtils.copyFrameText(app, chunk);
                    var seg = [_]vaxis.Cell.Segment{.{
                        .text = context_text,
                        .style = context_style,
                    }};
                    _ = win.print(&seg, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(content_start )});
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
        content_width: usize,
        gutter_width: usize,
        is_cursor: bool,
    ) !usize {
        const base_style = RenderUtils.getLineStyle(app, line.line_type);
        const is_in_visual = app.isLineInVisualSelection(global_line);
        const style = RenderUtils.getDisplayStyle(app, is_cursor, is_in_visual, base_style);

        // Use actual file line number from the diff
        // For deletions, show old line number; for additions and context, show new line number
        const file_lineno = switch (line.line_type) {
            .delete => line.old_lineno,
            .add, .context => line.new_lineno,
        };

        // Calculate byte offset and apply appropriate syntax highlighting
        // For deleted lines, use OLD file highlights and offsets
        // For add/context lines, use NEW file highlights and offsets
        const byte_offset = if (line.line_type == .delete)
            StateHelpers.getOldLineByteOffset(file, hunk_idx, line_idx_in_hunk)
        else
            StateHelpers.getLineByteOffset(file, hunk_idx, line_idx_in_hunk);

        const highlights = if (line.line_type == .delete)
            file.old_highlights
        else
            file.highlights;

        // Get file path for blame lookup
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

        // First line in hunk should always show blame (no deduplication with previous hunk)
        const is_first_line_in_hunk = line_idx_in_hunk == 0;

        return try renderWrappedTextWithHighlights(
            app,
            win,
            line.content,
            byte_offset,
            highlights,
            row,
            content_width,
            is_cursor,
            is_in_visual,
            style,
            file_lineno,
            line.line_type,
            gutter_width,
            global_line,
            file_path,
            is_first_line_in_hunk,
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
        is_in_visual: bool,
        style: vaxis.Style,
        file_lineno: ?u32,
        line_type: ?parser.Line.LineType,
        gutter_width: usize,
        global_line: usize,
        file_path: ?[]const u8,
        is_first_line_in_hunk: bool,
    ) !usize {
        if (content_width == 0) return 1;

        // Handle empty lines explicitly
        if (text.len == 0) {
            try RenderUtils.renderGutterWithBlame(app, win, 0, start_row, is_cursor or is_in_visual, true, file_lineno, line_type, gutter_width, file_path, is_first_line_in_hunk);
            // Pad empty lines for cursor, visual selection, or diff lines (add/delete)
            const should_pad = is_cursor or is_in_visual or (line_type != null and line_type.? != .context);
            const display_text = try RenderUtils.padTextForCursor(app, "", content_width, should_pad);
            var seg = [_]vaxis.Cell.Segment{.{
                .text = display_text,
                .style = style,
            }};
            _ = win.print(&seg, .{ .row_offset = @intCast(start_row), .col_offset = @intCast(Layout.sidebar_width + gutter_width + Layout.gutter_spacing )});

            return 1;
        }

        // No horizontal scrolling (removed with FOCUSED mode)
        var rows_rendered: usize = 0;
        var byte_offset_in_text: usize = 0;

        while (byte_offset_in_text < text.len) {
            const current_row = start_row + rows_rendered;
            if (current_row >= win.height) break;

            // Render sidebar for continuation rows (first row already has sidebar from main loop)
            if (rows_rendered > 0) {
                try RenderUtils.renderContinuationBorders(win, current_row, null);
            }

            // Only show line number on first row
            // Only pass is_first_line_in_hunk for the first rendered row
            const show_line_number = rows_rendered == 0;
            const first_line_flag = is_first_line_in_hunk and rows_rendered == 0;
            try RenderUtils.renderGutterWithBlame(app, win, 0, current_row, is_cursor or is_in_visual, show_line_number, file_lineno, line_type, gutter_width, file_path, first_line_flag);

            // Get the chunk of text for this row (slice by display width, not bytes)
            const remaining_text = text[byte_offset_in_text..];
            const chunk = RenderUtils.sliceByDisplayWidth(remaining_text, content_width);

            // Generate syntax-highlighted segments for this chunk
            const chunk_byte_offset = byte_offset + byte_offset_in_text;
            const segments = try app.createHighlightedSegments(chunk, text, byte_offset_in_text, chunk_byte_offset, highlights, style, global_line);
            defer app.allocator.free(segments);

            // Pad segments to full width for cursor, visual selection, or diff lines (add/delete)
            const should_pad = is_cursor or is_in_visual or (line_type != null and line_type.? != .context);
            const content_start_col = Layout.sidebar_width + gutter_width + Layout.gutter_spacing;

            if (should_pad) {
                // Always pad to ensure background extends to the right edge
                const available_width = win.width -| content_start_col;
                const current_width = RenderUtils.calculateSegmentsWidth(segments);

                if (current_width < available_width) {
                    const padded_segments = try RenderUtils.padSegments(app, app.allocator, segments, current_width, available_width, style);
                    defer app.allocator.free(padded_segments);
                    _ = win.print(padded_segments, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(content_start_col )});
                } else {
                    _ = win.print(segments, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(content_start_col )});
                }
            } else {
                _ = win.print(segments, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(content_start_col )});
            }

            // Caret rendering removed with FOCUSED mode (show_caret is always false)

            byte_offset_in_text += chunk.len;
            rows_rendered += 1;
        }

        return if (rows_rendered == 0) 1 else rows_rendered;
    }
};
