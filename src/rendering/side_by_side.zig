const std = @import("std");
const vaxis = @import("vaxis");
const parser = @import("../git/parser.zig");
const syntax = @import("../highlighting/core.zig");
const comments = @import("../comments/store.zig");
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

        const profile_frame = app.profile_active_frame;
        var total_timer_opt: ?std.time.Timer = if (profile_frame) std.time.Timer.start() catch null else null;
        var gutter_ns: u64 = 0;
        var records_scanned: usize = 0;
        var rows_rendered: usize = 0;

        app.state.viewport_height = win.height;
        Navigation.clampScrollOffset(app);

        // Calculate global gutter width (consistent across all files)
        // Note: Blame is not shown in side-by-side view (too wide)
        var gutter_timer_opt: ?std.time.Timer = if (profile_frame) std.time.Timer.start() catch null else null;
        const gutter_width = app.getGlobalGutterWidth(false);
        if (gutter_timer_opt) |*timer| {
            gutter_ns = timer.read();
        }

        // Calculate layout: [sidebar][gutter][spacing][left_content][divider][gutter][spacing][right_content]
        // Total width = sidebar + 2 * gutter_width + 2 * spacing + 1 (middle divider) + left_content + right_content
        const total_borders_and_gutters = Layout.sidebar_width + (2 * gutter_width) + (2 * Layout.gutter_spacing) + 1;
        if (win.width <= total_borders_and_gutters) return; // Not enough space

        const available_width = win.width - total_borders_and_gutters;
        const left_content_width = available_width / 2;
        const right_content_width = available_width - left_content_width;

        const sidebar_style: vaxis.Cell.Style = .{ .fg = Color.dim };
        const middle_col = Layout.sidebar_width + gutter_width + Layout.gutter_spacing + left_content_width;

        var row: usize = 0;
        var last_highlighted_file_idx: ?usize = null;

        // Iterate through LineMap records (single source of truth for line positions)
        const start_index = @min(app.state.global_scroll_offset, app.state.line_map.records.len);
        for (app.state.line_map.records[start_index..]) |*record| {
            if (profile_frame) records_scanned += 1;
            const global_line = record.global_line;
            const file_idx = record.file_idx;

            if (row >= win.height) break;

            const file = &app.state.files[file_idx];

            // Only highlight once per file (not once per line!)
            if (last_highlighted_file_idx == null or last_highlighted_file_idx.? != file_idx) {
                try StateHelpers.ensureHighlights(app, file, false);
                last_highlighted_file_idx = file_idx;
            }
            const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

            const is_cursor = global_line == app.state.global_cursor_line;

            // Render sidebar and middle divider for all line types except spacers and file headers
            if (record.line_type != .spacer and record.line_type != .file_header) {
                var left_seg = [_]vaxis.Cell.Segment{.{
                    .text = "┃",
                    .style = sidebar_style,
                }};
                _ = win.print(&left_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(0) });
                var middle_seg = [_]vaxis.Cell.Segment{.{
                    .text = FrameChars.vertical,
                    .style = sidebar_style,
                }};
                _ = win.print(&middle_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(middle_col) });
            }

            // Render based on line type
            switch (record.line_type) {
                .file_header => {
                    const rows_used = try renderFileHeader(app, win, file, file_idx, row, left_content_width, right_content_width, gutter_width, is_cursor);
                    row += rows_used;
                },
                .hunk_header => |hunk_info| {
                    const hunk = &file.hunks[hunk_info.hunk_idx];
                    const is_in_visual = app.isLineInVisualSelection(global_line);
                    const rows_used = try renderHunkHeader(app, win, hunk.*, file_idx, hunk_info.hunk_idx, row, left_content_width, right_content_width, gutter_width, is_cursor, is_in_visual);
                    row += rows_used;
                },
                .code_line => |code_info| {
                    const hunk = &file.hunks[code_info.hunk_idx];
                    const line = &hunk.lines[code_info.line_idx_in_hunk];
                    const rows_used = try renderDiffLine(app, win, file, code_info.hunk_idx, code_info.line_idx_in_hunk, line.*, global_line, row, left_content_width, right_content_width, gutter_width, is_cursor);
                    row += rows_used;

                    // Check if we're creating a NEW comment on this code line
                    // (If editing an existing comment, it will be rendered in place of the comment_line below)
                    if (app.mode == .comment and is_cursor) {
                        if (app.state.active_comment_input) |input| {
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

                            if (is_in_comment_range) {
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
                                        _ = win.print(&left_seg_cmt, .{ .row_offset = @intCast(comment_start_row + comment_row_idx), .col_offset = @intCast(0) });
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
                            try renderSideBySideCommentInput(app, win, row, left_content_width, right_content_width, gutter_width, line.line_type)
                        else
                            try renderSideBySideComment(app, win, comment, comment_info.comment_idx, row, left_content_width, right_content_width, gutter_width, line.line_type, is_cursor);

                        // Render sidebar for all comment rows (no middle divider - spans full width)
                        var comment_row_idx: usize = 1; // First sidebar already rendered above
                        while (comment_row_idx < comment_rows and comment_start_row + comment_row_idx < win.height) : (comment_row_idx += 1) {
                            var comment_sidebar = [_]vaxis.Cell.Segment{.{
                                .text = "┃",
                                .style = sidebar_style,
                            }};
                            _ = win.print(&comment_sidebar, .{ .row_offset = @intCast(comment_start_row + comment_row_idx), .col_offset = @intCast(0) });
                        }
                        row += comment_rows;
                    }
                },
                .spacer => {
                    // Render spacer - just empty line with cursor highlight if needed (no borders)
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
                            _ = win.print(&fill_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(fill_start) });
                        }
                    }
                    row += 1;
                },
            }
        }

        rows_rendered = row;

        // Clear any remaining rows at the bottom of the screen
        // IMPORTANT: Must fill the entire row, not just the dividers, because vaxis
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

            // Then render the dividers
            var left_seg = [_]vaxis.Cell.Segment{.{
                .text = "┃",
                .style = sidebar_style,
            }};
            _ = win.print(&left_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(0) });
            var middle_seg = [_]vaxis.Cell.Segment{.{
                .text = FrameChars.vertical,
                .style = sidebar_style,
            }};
            _ = win.print(&middle_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(middle_col) });
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

        if (profile_frame) {
            const profile_log = std.log.scoped(.profile_render);
            const total_ns: u64 = if (total_timer_opt) |*timer| timer.read() else 0;
            profile_log.debug(
                "side-by-side content: total_ns={d} gutter_ns={d} scanned={d} rows={d} line_map={d} scroll={d} viewport={d} left_width={d} right_width={d} gutter_width={d}",
                .{ total_ns, gutter_ns, records_scanned, rows_rendered, app.state.line_map.records.len, app.state.global_scroll_offset, win.height, left_content_width, right_content_width, gutter_width },
            );
        }
    }

    fn renderFileHeader(
        app: *App,
        win: vaxis.Window,
        file: *const parser.FileDiff,
        file_idx: usize,
        row: usize,
        _: usize, // left_width
        _: usize, // right_width
        _: usize, // gutter_width
        is_cursor: bool,
    ) !usize {
        // For now, use simple file header similar to unified mode
        // TODO: Implement proper side-by-side file header if needed
        const rows_used = try FileHeader.render(app, win, file, file_idx, row, is_cursor);
        return rows_used;
    }

    fn renderHunkHeader(
        app: *App,
        win: vaxis.Window,
        hunk: parser.Hunk,
        file_idx: usize,
        hunk_idx: usize,
        row: usize,
        left_width: usize,
        right_width: usize,
        gutter_width: usize,
        is_cursor: bool,
        is_in_visual: bool,
    ) !usize {
        _ = right_width; // Same text on both sides, so right_width not needed

        const is_folded = app.isHunkFolded(file_idx, hunk_idx);

        // Build header text with fold indicator using shared utility
        var buf: [256]u8 = undefined;
        const base_header = try RenderUtils.buildHunkHeaderText(hunk, &buf);

        // Add fold indicator prefix and line count suffix for folded hunks
        var header_buf: [512]u8 = undefined;
        const fold_indicator = if (is_folded) "▶ " else "▼ ";
        const header_text = if (is_folded) blk: {
            const line_count = hunk.lines.len;
            break :blk std.fmt.bufPrint(&header_buf, "{s}{s}  [{d} lines]", .{ fold_indicator, base_header, line_count }) catch base_header;
        } else blk: {
            break :blk std.fmt.bufPrint(&header_buf, "{s}{s}", .{ fold_indicator, base_header }) catch base_header;
        };

        // Calculate number of rows needed for wrapping (use display width, not bytes)
        const text_display_width = RenderUtils.displayWidth(header_text);
        const num_rows = if (text_display_width == 0) 1 else (text_display_width + left_width - 1) / left_width;

        // Get styles using shared utilities
        const fill_style = RenderUtils.getFillStyle(app, is_cursor, is_in_visual);
        const range_len = RenderUtils.findHunkHeaderRangeEnd(header_text);
        const range_style = RenderUtils.getHunkRangeStyle(app, is_cursor, is_in_visual);
        const context_style = RenderUtils.getHunkContextStyle(app, is_cursor, is_in_visual);
        const right_col = 1 + gutter_width + Layout.gutter_spacing + left_width + 1;

        // Render each wrapped row
        var current_row = row;
        const middle_col = Layout.sidebar_width + gutter_width + Layout.gutter_spacing + left_width;

        for (0..num_rows) |wrap_idx| {
            if (current_row >= win.height) break;

            // Render sidebar and middle divider for continuation rows
            if (wrap_idx > 0) {
                try RenderUtils.renderContinuationBorders(win, current_row, middle_col);
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
                _ = win.print(&fill_seg, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(fill_start) });
            }

            // Render left gutter with spaces (no bar)
            const left_gutter_spaces = try RenderUtils.frameTextSlice(app, gutter_width);
            @memset(left_gutter_spaces, ' ');
            const left_gutter_style: vaxis.Style = if (is_cursor)
                .{ .bg = Color.cursor_bg }
            else
                .{};
            var left_gutter_seg = [_]vaxis.Cell.Segment{.{
                .text = left_gutter_spaces,
                .style = left_gutter_style,
            }};
            _ = win.print(&left_gutter_seg, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(1) });

            // Render spacing after left gutter
            try RenderUtils.renderGutterSpacing(app, win, current_row, 1 + gutter_width, is_cursor, null);

            // Render left content (slice by display width, not bytes)
            const display_start = wrap_idx * left_width;
            const byte_start = RenderUtils.skipCodepoints(header_text, display_start);
            const remaining_text = if (byte_start < header_text.len) header_text[byte_start..] else "";
            const chunk = app.profileSliceByDisplayWidth(remaining_text, left_width);

            // Calculate display position of range boundary
            const range_display_len = RenderUtils.displayWidth(header_text[0..range_len]);

            const left_content_start = 1 + gutter_width + Layout.gutter_spacing;
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
                        _ = win.print(&seg, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(left_content_start) });
                    } else {
                        // Mixed: range + context - split at the boundary
                        const range_codepoints = range_display_len - display_start;
                        const range_chunk = app.profileSliceByDisplayWidth(chunk, range_codepoints);
                        const context_byte_start = range_chunk.len;
                        const context_chunk = chunk[context_byte_start..];

                        const range_text = try RenderUtils.copyFrameText(app, range_chunk);
                        const context_text = try RenderUtils.copyFrameText(app, context_chunk);

                        var segments = [_]vaxis.Cell.Segment{
                            .{ .text = range_text, .style = range_style },
                            .{ .text = context_text, .style = context_style },
                        };
                        _ = win.print(&segments, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(left_content_start) });
                    }
                } else {
                    // Pure context
                    const context_text = try RenderUtils.copyFrameText(app, chunk);
                    var seg = [_]vaxis.Cell.Segment{.{
                        .text = context_text,
                        .style = context_style,
                    }};
                    _ = win.print(&seg, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(left_content_start) });
                }
            }

            // Render right gutter with spaces (no bar)
            const right_gutter_spaces = try RenderUtils.frameTextSlice(app, gutter_width);
            @memset(right_gutter_spaces, ' ');
            const right_gutter_style: vaxis.Style = if (is_cursor)
                .{ .bg = Color.cursor_bg }
            else
                .{};
            var right_gutter_seg = [_]vaxis.Cell.Segment{.{
                .text = right_gutter_spaces,
                .style = right_gutter_style,
            }};
            _ = win.print(&right_gutter_seg, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(right_col) });

            // Render spacing after right gutter
            try RenderUtils.renderGutterSpacing(app, win, current_row, right_col + gutter_width, is_cursor, null);

            // Render right content (same as left, reusing chunk and display position calculations)
            const right_content_start = right_col + gutter_width + Layout.gutter_spacing;
            if (chunk.len > 0) {
                // Reuse the display position calculations from left side
                if (display_start < range_display_len) {
                    const display_end = display_start + RenderUtils.displayWidth(chunk);
                    if (display_end <= range_display_len) {
                        // Pure range
                        const range_text = try RenderUtils.copyFrameText(app, chunk);
                        var seg = [_]vaxis.Cell.Segment{.{
                            .text = range_text,
                            .style = range_style,
                        }};
                        _ = win.print(&seg, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(right_content_start) });
                    } else {
                        // Mixed: range + context
                        const range_codepoints = range_display_len - display_start;
                        const range_chunk = app.profileSliceByDisplayWidth(chunk, range_codepoints);
                        const context_byte_start = range_chunk.len;
                        const context_chunk = chunk[context_byte_start..];

                        const range_text = try RenderUtils.copyFrameText(app, range_chunk);
                        const context_text = try RenderUtils.copyFrameText(app, context_chunk);

                        var segments = [_]vaxis.Cell.Segment{
                            .{ .text = range_text, .style = range_style },
                            .{ .text = context_text, .style = context_style },
                        };
                        _ = win.print(&segments, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(right_content_start) });
                    }
                } else {
                    // Pure context
                    const context_text = try RenderUtils.copyFrameText(app, chunk);
                    var seg = [_]vaxis.Cell.Segment{.{
                        .text = context_text,
                        .style = context_style,
                    }};
                    _ = win.print(&seg, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(right_content_start) });
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
        const style = RenderUtils.getDisplayStyle(app, is_cursor, is_in_visual, base_style);

        const middle_col = Layout.sidebar_width + gutter_width + Layout.gutter_spacing + left_width;
        const right_col = 1 + gutter_width + Layout.gutter_spacing + left_width + 1; // +1 for middle divider

        // Per-hunk highlighting: get highlights and byte offset from the hunk, not the file
        // This prevents multi-line constructs (like block comments) from bleeding across hunk boundaries
        const hunk = &file.hunks[hunk_idx];

        // Calculate byte offset within this hunk (not the whole file)
        const byte_offset = if (line.line_type == .delete)
            StateHelpers.getOldLineByteOffsetInHunk(hunk, line_idx_in_hunk)
        else
            StateHelpers.getLineByteOffsetInHunk(hunk, line_idx_in_hunk);

        // Use hunk-level highlights
        const highlights = if (line.line_type == .delete)
            hunk.old_highlights
        else
            hunk.highlights;

        const old_line_spans = StateHelpers.getLineHighlightSpans(hunk, .old, line_idx_in_hunk);
        const new_line_spans = StateHelpers.getLineHighlightSpans(hunk, .new, line_idx_in_hunk);

        switch (line.line_type) {
            .context => {
                // Show on both sides - calculate rows based on display width
                const content_display_width = RenderUtils.displayWidth(line.content);
                const num_rows = if (content_display_width == 0) 1 else (content_display_width + left_width - 1) / left_width;

                var current_row = row;
                var left_byte_offset_in_content: usize = 0;
                var right_byte_offset_in_content: usize = 0;

                for (0..num_rows) |wrap_idx| {
                    if (current_row >= win.height) break;

                    // Render sidebar and middle divider for continuation rows
                    if (wrap_idx > 0) {
                        try RenderUtils.renderContinuationBorders(win, current_row, middle_col);
                    }

                    const show_lineno = wrap_idx == 0;

                    // Render left side
                    try RenderUtils.renderGutter(app, win, 0, current_row, is_cursor, show_lineno, line.old_lineno, line.line_type, gutter_width);

                    // Slice by display width for left side
                    const left_remaining = line.content[left_byte_offset_in_content..];
                    const left_chunk = app.profileSliceByDisplayWidth(left_remaining, left_width);

                    // Generate syntax-highlighted segments for left chunk
                    const left_chunk_byte_offset = byte_offset + left_byte_offset_in_content;
                    const left_segments = try app.createHighlightedSegments(left_chunk, line.content, left_byte_offset_in_content, left_chunk_byte_offset, highlights, old_line_spans, style, global_line);
                    defer app.frameSegmentAllocator().free(left_segments);

                    // Pad context lines only when cursor is on them
                    if (is_cursor) {
                        const left_start_col = 1 + gutter_width + Layout.gutter_spacing;
                        const available_to_divider = middle_col -| left_start_col;
                        const left_current_width = RenderUtils.calculateSegmentsWidth(left_segments);

                        if (left_current_width < available_to_divider) {
                            const padded_segments = try app.profilePadSegments(left_segments, left_current_width, available_to_divider, style);
                            defer app.frameSegmentAllocator().free(padded_segments);
                            _ = win.print(padded_segments, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(left_start_col) });
                        } else {
                            _ = win.print(left_segments, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(left_start_col) });
                        }
                    } else {
                        _ = win.print(left_segments, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(1 + gutter_width + Layout.gutter_spacing) });
                    }

                    left_byte_offset_in_content += left_chunk.len;

                    // Render right side (same content)
                    try RenderUtils.renderGutterAtColumn(app, win, current_row, right_col, is_cursor, is_in_visual, show_lineno, line.new_lineno, line.line_type, gutter_width);

                    // Slice by display width for right side
                    const right_remaining = line.content[right_byte_offset_in_content..];
                    const right_chunk = app.profileSliceByDisplayWidth(right_remaining, right_width);

                    // Generate syntax-highlighted segments for right chunk
                    const right_chunk_byte_offset = byte_offset + right_byte_offset_in_content;
                    const right_segments = try app.createHighlightedSegments(right_chunk, line.content, right_byte_offset_in_content, right_chunk_byte_offset, highlights, new_line_spans, style, global_line);
                    defer app.frameSegmentAllocator().free(right_segments);

                    // Pad context lines only when cursor is on them
                    if (is_cursor) {
                        const right_start_col = right_col + gutter_width + Layout.gutter_spacing;
                        const available_to_edge = win.width -| right_start_col;
                        const right_current_width = RenderUtils.calculateSegmentsWidth(right_segments);

                        if (right_current_width < available_to_edge) {
                            const padded_segments = try app.profilePadSegments(right_segments, right_current_width, available_to_edge, style);
                            defer app.frameSegmentAllocator().free(padded_segments);
                            _ = win.print(padded_segments, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(right_start_col) });
                        } else {
                            _ = win.print(right_segments, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(right_start_col) });
                        }
                    } else {
                        _ = win.print(right_segments, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(right_col + gutter_width + Layout.gutter_spacing) });
                    }

                    right_byte_offset_in_content += right_chunk.len;
                    current_row += 1;
                }

                return if (num_rows == 0) 1 else num_rows;
            },
            .delete => {
                // Show on left only, wrap as needed
                // Note: Delete lines are not in the new file, so syntax highlighting won't apply
                const content_display_width = RenderUtils.displayWidth(line.content);
                const num_rows = if (content_display_width == 0) 1 else (content_display_width + left_width - 1) / left_width;

                var current_row = row;
                var byte_offset_in_content: usize = 0;

                for (0..num_rows) |_| {
                    if (current_row >= win.height) break;

                    // Render sidebar and middle divider for continuation rows
                    if (byte_offset_in_content > 0) {
                        try RenderUtils.renderContinuationBorders(win, current_row, middle_col);
                    }

                    const show_lineno = byte_offset_in_content == 0;

                    // Render left side
                    try RenderUtils.renderGutter(app, win, 0, current_row, is_cursor, show_lineno, line.old_lineno, line.line_type, gutter_width);

                    // Slice by display width
                    const remaining_text = line.content[byte_offset_in_content..];
                    const chunk = app.profileSliceByDisplayWidth(remaining_text, left_width);

                    // Generate syntax-highlighted segments for chunk
                    // (will fall back to plain text for delete lines since highlights is null)
                    const chunk_byte_offset = byte_offset + byte_offset_in_content;
                    const segments = try app.createHighlightedSegments(chunk, line.content, byte_offset_in_content, chunk_byte_offset, highlights, old_line_spans, style, global_line);
                    defer app.frameSegmentAllocator().free(segments);

                    // Always pad delete lines to show full-width background
                    const left_start_col = 1 + gutter_width + Layout.gutter_spacing;
                    const available_to_divider = middle_col -| left_start_col;
                    const current_width = RenderUtils.calculateSegmentsWidth(segments);

                    if (current_width < available_to_divider) {
                        const padded_segments = try app.profilePadSegments(segments, current_width, available_to_divider, style);
                        defer app.frameSegmentAllocator().free(padded_segments);
                        _ = win.print(padded_segments, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(left_start_col) });
                    } else {
                        _ = win.print(segments, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(left_start_col) });
                    }

                    // Right side empty - fill with dimmed diagonal pattern
                    try RenderUtils.renderGutterAtColumn(app, win, current_row, right_col, is_cursor, is_in_visual, false, null, null, gutter_width);
                    const fill_style: vaxis.Style = if (is_cursor)
                        .{ .fg = Color.gray_234, .bg = Color.cursor_bg }
                    else
                        .{ .fg = Color.gray_234 };
                    try renderDiagonalFill(app, win, current_row, right_col + gutter_width + Layout.gutter_spacing, right_width, fill_style);

                    byte_offset_in_content += chunk.len;
                    current_row += 1;
                }

                return if (num_rows == 0) 1 else num_rows;
            },
            .add => {
                // Show on right only, wrap as needed
                const content_display_width = RenderUtils.displayWidth(line.content);
                const num_rows = if (content_display_width == 0) 1 else (content_display_width + right_width - 1) / right_width;

                var current_row = row;
                var byte_offset_in_content: usize = 0;

                for (0..num_rows) |_| {
                    if (current_row >= win.height) break;

                    // Render sidebar and middle divider for continuation rows
                    if (byte_offset_in_content > 0) {
                        try RenderUtils.renderContinuationBorders(win, current_row, middle_col);
                    }

                    const show_lineno = byte_offset_in_content == 0;

                    // Left side empty - fill with dimmed diagonal pattern
                    try RenderUtils.renderGutter(app, win, 0, current_row, is_cursor, false, null, null, gutter_width);
                    const left_fill_style: vaxis.Style = if (is_cursor)
                        .{ .fg = Color.gray_234, .bg = Color.cursor_bg }
                    else
                        .{ .fg = Color.gray_234 };
                    try renderDiagonalFill(app, win, current_row, 1 + gutter_width + Layout.gutter_spacing, left_width, left_fill_style);

                    // Render right side
                    try RenderUtils.renderGutterAtColumn(app, win, current_row, right_col, is_cursor, is_in_visual, show_lineno, line.new_lineno, line.line_type, gutter_width);

                    // Slice by display width
                    const remaining_text = line.content[byte_offset_in_content..];
                    const chunk = app.profileSliceByDisplayWidth(remaining_text, right_width);

                    // Generate syntax-highlighted segments for chunk
                    const chunk_byte_offset = byte_offset + byte_offset_in_content;
                    const segments = try app.createHighlightedSegments(chunk, line.content, byte_offset_in_content, chunk_byte_offset, highlights, new_line_spans, style, global_line);
                    defer app.frameSegmentAllocator().free(segments);

                    // Always pad add lines to show full-width background
                    const right_start_col = right_col + gutter_width + Layout.gutter_spacing;
                    const available_to_edge = win.width -| right_start_col;
                    const current_width = RenderUtils.calculateSegmentsWidth(segments);

                    if (current_width < available_to_edge) {
                        const padded_segments = try app.profilePadSegments(segments, current_width, available_to_edge, style);
                        defer app.frameSegmentAllocator().free(padded_segments);
                        _ = win.print(padded_segments, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(right_start_col) });
                    } else {
                        _ = win.print(segments, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(right_start_col) });
                    }

                    byte_offset_in_content += chunk.len;
                    current_row += 1;
                }

                return if (num_rows == 0) 1 else num_rows;
            },
        }
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

        if (layout.width < 20) return 0; // Too narrow

        const border_style: vaxis.Style = .{ .fg = Color.yellow, .bg = Color.comment_hover_bg, .bold = true };
        const text_style: vaxis.Style = .{ .fg = Color.white, .bg = Color.comment_hover_bg };
        const label_style: vaxis.Style = .{ .fg = Color.yellow, .bg = Color.comment_hover_bg, .bold = true };
        const hints_style: vaxis.Style = .{ .fg = Color.yellow, .bg = Color.comment_hover_bg, .dim = true };

        var segments: std.ArrayList(vaxis.Cell.Segment) = .{};
        defer segments.deinit(app.allocator);

        var current_row = row;

        // Line 1: ┃ Comment                              Enter:Save  Ctrl+J:Newline  ESC:Cancel
        const hints = "Enter:Save  Ctrl+J:Newline  ESC:Cancel";
        const border_and_label = "┃ Comment";
        const spacing = "  ";
        const total_fixed = border_and_label.len + spacing.len + hints.len; // Total chars we're rendering
        const available_for_spacer = layout.width -| total_fixed;

        try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, "┃"), .style = border_style });
        try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, " Comment"), .style = label_style });

        // Spacer between label and hints
        if (available_for_spacer > 0) {
            const spacer = try RenderUtils.frameTextSlice(app, available_for_spacer);
            @memset(spacer, ' ');
            try segments.append(app.allocator, .{ .text = spacer, .style = .{ .bg = Color.comment_hover_bg } });
        }

        try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, spacing), .style = .{ .bg = Color.comment_hover_bg } });
        try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, hints), .style = hints_style });

        _ = win.print(segments.items, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(layout.start_col) });
        current_row += 1;

        // Line 2+: ┃ > [text] (multiple lines if newlines present)
        const input_text = input.vim.text_buffer[0..input.vim.text_len];
        const text_area_width = layout.width - 4; // -4 for "┃ > " or "┃   "

        var line_iter = std.mem.splitScalar(u8, input_text, '\n');
        var is_first_line = true;
        var char_offset: usize = 0; // Track position in buffer for cursor

        while (line_iter.next()) |text_line| {
            if (current_row >= win.height) break;

            // Wrap this line if it's too long
            var wrapped_lines = try RenderUtils.wrapText(app.allocator, text_line, text_area_width);
            defer wrapped_lines.deinit(app.allocator);

            // Track offset within the current text_line for wrapped segments
            var segment_offset: usize = 0;

            // Render each wrapped segment
            for (wrapped_lines.items) |wrapped_segment| {
                if (current_row >= win.height) break;

                segments.clearRetainingCapacity();
                try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, "┃"), .style = border_style });

                if (is_first_line) {
                    try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, " > "), .style = text_style });
                } else {
                    try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, "   "), .style = text_style });
                }

                const display_text = blk: {
                    var buf = try RenderUtils.frameTextSlice(app, text_area_width);
                    const copy_len = @min(wrapped_segment.len, text_area_width);
                    if (copy_len > 0) {
                        @memcpy(buf[0..copy_len], wrapped_segment[0..copy_len]);
                    }
                    if (copy_len < buf.len) {
                        @memset(buf[copy_len..], ' ');
                    }
                    break :blk buf;
                };

                try segments.append(app.allocator, .{ .text = display_text, .style = text_style });
                _ = win.print(segments.items, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(layout.start_col) });

                // Draw cursor and visual selection if in this wrapped segment
                const segment_start = char_offset + segment_offset;
                const segment_end = segment_start + wrapped_segment.len;

                // Handle visual mode selection highlighting
                if (input.vim.vim_mode == .visual and input.vim.visual_anchor != null) {
                    const anchor = input.vim.visual_anchor.?;
                    const selection_start = @min(anchor, input.vim.cursor_pos);
                    const selection_end = @max(anchor, input.vim.cursor_pos);

                    // Highlight any part of selection in this segment
                    if (selection_start < segment_end and selection_end >= segment_start) {
                        const highlight_start_in_seg = if (selection_start > segment_start)
                            selection_start - segment_start
                        else
                            0;
                        const highlight_end_in_seg = if (selection_end < segment_end)
                            selection_end - segment_start
                        else
                            wrapped_segment.len;

                        if (highlight_start_in_seg < text_area_width and highlight_end_in_seg > highlight_start_in_seg) {
                            const highlight_col_start = layout.start_col + 4 + highlight_start_in_seg;
                            const highlight_len = @min(highlight_end_in_seg - highlight_start_in_seg, text_area_width - highlight_start_in_seg);

                            if (highlight_len > 0) {
                                const highlight_text = wrapped_segment[highlight_start_in_seg..][0..highlight_len];
                                var highlight_seg = [_]vaxis.Cell.Segment{.{
                                    .text = try RenderUtils.copyFrameText(app, highlight_text),
                                    .style = .{ .fg = Color.white, .bg = Color.blue },
                                }};
                                _ = win.print(&highlight_seg, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(highlight_col_start) });
                            }
                        }
                    }
                }

                // Draw cursor if it's in this wrapped segment
                if (input.vim.cursor_pos >= segment_start and input.vim.cursor_pos <= segment_end) {
                    const cursor_pos_in_segment = input.vim.cursor_pos - segment_start;
                    if (cursor_pos_in_segment < text_area_width) {
                        const cursor_col = layout.start_col + 4 + cursor_pos_in_segment; // +4 for "┃ > " or "┃   "

                        // Set the terminal cursor position and shape
                        win.showCursor(@intCast(cursor_col), @intCast(current_row));

                        switch (input.vim.vim_mode) {
                            .normal, .visual => {
                                // Block cursor for normal/visual mode
                                win.setCursorShape(.block);
                            },
                            .insert => {
                                // Beam/line cursor for insert mode
                                win.setCursorShape(.beam);
                            },
                            .command => {
                                // Command mode - hide cursor here (it's shown in status bar)
                                win.hideCursor();
                            },
                        }
                    }
                }

                current_row += 1;
                is_first_line = false;
                segment_offset += wrapped_segment.len;

                // Account for spaces that were skipped during wrapping
                while (segment_offset < text_line.len and text_line[segment_offset] == ' ') {
                    segment_offset += 1;
                }
            }

            char_offset += text_line.len + 1; // +1 for the newline character
        }

        // Last line: ┃ (bottom spacer)
        segments.clearRetainingCapacity();
        try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, "┃"), .style = border_style });
        const bottom_spacer = try RenderUtils.frameTextSlice(app, layout.width - 1);
        @memset(bottom_spacer, ' ');
        try segments.append(app.allocator, .{ .text = bottom_spacer, .style = .{ .bg = Color.comment_hover_bg } });
        _ = win.print(segments.items, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(layout.start_col) });
        current_row += 1;

        return current_row - row; // Return actual number of rows used
    }

    /// Render saved comment display in side-by-side mode with optional truncation
    fn renderSideBySideComment(
        app: *App,
        win: vaxis.Window,
        comment: *const comments.Comment,
        comment_idx: usize,
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

        const is_expanded = app.isCommentExpanded(comment_idx);
        const max_lines = Layout.max_comment_lines;

        // Use cyan for regular comments, yellow when focused
        const border_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.yellow, .bg = Color.comment_hover_bg, .bold = true }
        else
            .{ .fg = Color.cyan, .bold = true };

        const text_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.white, .bg = Color.comment_hover_bg }
        else
            .{ .fg = Color.white };

        const label_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.yellow, .bg = Color.comment_hover_bg, .bold = true }
        else
            .{ .fg = Color.cyan, .bold = true };

        const hints_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.yellow, .bg = Color.comment_hover_bg, .dim = true }
        else
            .{};

        const bg_style: vaxis.Style = if (is_cursor)
            .{ .bg = Color.comment_hover_bg }
        else
            .{};

        var segments: std.ArrayList(vaxis.Cell.Segment) = .{};
        defer segments.deinit(app.allocator);

        var current_row = row;

        // Line 1: ┃ Comment                              Enter:Edit  d:Delete  o:Expand
        if (is_cursor) {
            const expand_hint = if (is_expanded) "o:Collapse" else "o:Expand";
            var hints_buf: [64]u8 = undefined;
            const hints = std.fmt.bufPrint(&hints_buf, "Enter:Edit  d:Delete  {s}", .{expand_hint}) catch "Enter:Edit  d:Delete";
            const border_and_label = "┃ Comment";
            const spacing = "  ";
            const total_fixed = border_and_label.len + spacing.len + hints.len;
            const available_for_spacer = layout.width -| total_fixed;

            try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, "┃"), .style = border_style });
            try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, " Comment"), .style = label_style });

            // Spacer between label and hints
            if (available_for_spacer > 0) {
                const spacer = try RenderUtils.frameTextSlice(app, available_for_spacer);
                @memset(spacer, ' ');
                try segments.append(app.allocator, .{ .text = spacer, .style = bg_style });
            }

            try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, spacing), .style = bg_style });
            try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, hints), .style = hints_style });
        } else {
            // Just label when not focused
            try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, "┃"), .style = border_style });
            try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, " Comment"), .style = label_style });
            const label_spacer = try RenderUtils.frameTextSlice(app, layout.width - 9); // -9 for "┃ Comment"
            @memset(label_spacer, ' ');
            try segments.append(app.allocator, .{ .text = label_spacer, .style = bg_style });
        }

        _ = win.print(segments.items, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(layout.start_col) });
        current_row += 1;

        // Render comment text lines with word wrapping
        const text_area_width = layout.width - 4; // -4 for "┃ > " or "┃   "
        var line_iter = std.mem.splitScalar(u8, comment.text, '\n');
        var is_first_line = true;
        var text_lines_rendered: usize = 0;
        var total_text_lines: usize = 0;
        var truncated = false;

        // First pass: count total lines if we need to truncate
        if (!is_expanded) {
            var count_iter = std.mem.splitScalar(u8, comment.text, '\n');
            while (count_iter.next()) |text_line| {
                var wrapped = try RenderUtils.wrapText(app.allocator, text_line, text_area_width);
                defer wrapped.deinit(app.allocator);
                total_text_lines += wrapped.items.len;
            }
        }

        while (line_iter.next()) |text_line| {
            if (current_row >= win.height) break;

            // Wrap this line if it's too long
            var wrapped_lines = try RenderUtils.wrapText(app.allocator, text_line, text_area_width);
            defer wrapped_lines.deinit(app.allocator);

            // Render each wrapped segment
            for (wrapped_lines.items) |wrapped_segment| {
                if (current_row >= win.height) break;

                // Check if we should truncate (only when collapsed)
                if (!is_expanded and text_lines_rendered >= max_lines) {
                    truncated = true;
                    break;
                }

                segments.clearRetainingCapacity();
                try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, "┃"), .style = border_style });
                if (is_first_line) {
                    try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, " > "), .style = text_style });
                } else {
                    try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, "   "), .style = text_style });
                }

                const display_text = blk: {
                    var buf = try RenderUtils.frameTextSlice(app, text_area_width);
                    const copy_len = @min(wrapped_segment.len, text_area_width);
                    if (copy_len > 0) {
                        @memcpy(buf[0..copy_len], wrapped_segment[0..copy_len]);
                    }
                    if (copy_len < buf.len) {
                        @memset(buf[copy_len..], ' ');
                    }
                    break :blk buf;
                };

                try segments.append(app.allocator, .{ .text = display_text, .style = text_style });
                _ = win.print(segments.items, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(layout.start_col) });
                current_row += 1;
                text_lines_rendered += 1;
                is_first_line = false;
            }

            if (truncated) break;
        }

        // Show truncation indicator if collapsed and has more lines
        if (truncated and total_text_lines > max_lines) {
            if (current_row < win.height) {
                segments.clearRetainingCapacity();
                try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, "┃"), .style = border_style });

                const remaining = total_text_lines - max_lines;
                var more_buf: [64]u8 = undefined;
                const more_text = std.fmt.bufPrint(&more_buf, "   ... {d} more line{s} (press o to expand)", .{
                    remaining,
                    if (remaining == 1) "" else "s",
                }) catch "   ... (press o to expand)";

                const display_text = blk: {
                    var buf = try RenderUtils.frameTextSlice(app, text_area_width);
                    const copy_len = @min(more_text.len, text_area_width);
                    if (copy_len > 0) {
                        @memcpy(buf[0..copy_len], more_text[0..copy_len]);
                    }
                    if (copy_len < buf.len) {
                        @memset(buf[copy_len..], ' ');
                    }
                    break :blk buf;
                };

                try segments.append(app.allocator, .{ .text = display_text, .style = hints_style });
                _ = win.print(segments.items, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(layout.start_col) });
                current_row += 1;
            }
        }

        if (current_row >= win.height) {
            return current_row - row;
        }

        // Line N: ┃ (bottom spacer)
        segments.clearRetainingCapacity();
        try segments.append(app.allocator, .{ .text = try RenderUtils.copyFrameText(app, "┃"), .style = border_style });
        const bottom_spacer = try RenderUtils.frameTextSlice(app, layout.width - 1);
        @memset(bottom_spacer, ' ');
        try segments.append(app.allocator, .{ .text = bottom_spacer, .style = bg_style });
        _ = win.print(segments.items, .{ .row_offset = @intCast(current_row), .col_offset = @intCast(layout.start_col) });
        current_row += 1;

        return current_row - row;
    }

    /// Render diagonal fill pattern using Unicode box drawing diagonal character
    fn renderDiagonalFill(app: *App, win: vaxis.Window, row: usize, col: usize, width: usize, style: vaxis.Style) !void {
        if (width == 0) return;

        // Build string of diagonal characters (╱ is 3 bytes in UTF-8)
        const diagonal = "╱";
        const diagonal_len = diagonal.len; // 3 bytes
        const total_bytes = width * diagonal_len;

        const fill_pattern = try RenderUtils.frameTextSlice(app, total_bytes);
        var i: usize = 0;
        while (i < width) : (i += 1) {
            @memcpy(fill_pattern[i * diagonal_len ..][0..diagonal_len], diagonal);
        }

        var fill_seg = [_]vaxis.Cell.Segment{.{
            .text = fill_pattern,
            .style = style,
        }};
        _ = win.print(&fill_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
    }
};
