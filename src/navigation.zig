const std = @import("std");
const App = @import("app.zig").App;
const rendering = @import("rendering/common.zig");
const state_helpers = @import("state.zig");
const CommentController = @import("comments/controller.zig").CommentController;
const RenderUtils = @import("rendering/utils.zig").RenderUtils;
const SideBySideRenderer = @import("rendering/side_by_side.zig").SideBySideRenderer;
const comments = @import("comments/store.zig");
const line_map = @import("line_map.zig");
const parser = @import("git/parser.zig");
const skim_io = @import("skim_io");
const Layout = rendering.Layout;
const StateHelpers = state_helpers.StateHelpers;

pub const Navigation = struct {
    pub fn moveCursorDown(app: *App) void {
        const count = app.state.count_prefix orelse 1;
        app.state.count_prefix = null;

        const total_lines = app.getTotalGlobalLines();
        if (total_lines > 0) {
            const new_line = @min(app.state.global_cursor_line + count, total_lines - 1);
            app.state.global_cursor_line = new_line;
        }

        // Ensure cursor stays visible
        ensureCursorVisible(app, true);
    }

    pub fn moveCursorUp(app: *App) void {
        const count = app.state.count_prefix orelse 1;
        app.state.count_prefix = null;

        app.state.global_cursor_line -|= count;

        // Ensure cursor stays visible
        ensureCursorVisible(app, true);
    }

    pub fn navigateToNextFile(app: *App) void {
        if (app.state.files.len == 0) return;

        // Find which file cursor is currently in
        const current_file = app.state.line_map.getFileIndexForLine(app.state.global_cursor_line) orelse 0;

        // Jump to start of next file (or wrap to first)
        const next_file = if (current_file + 1 < app.state.files.len)
            current_file + 1
        else
            0;

        if (app.state.line_map.getFileHeaderLine(next_file)) |start_line| {
            app.state.current_file_idx = next_file;
            app.state.global_cursor_line = start_line;
            app.state.global_scroll_offset = start_line;

            // Force a full re-render when jumping files
            app.needs_render = true;
        }

        // Request async highlighting after navigation
        // Don't block - main loop will handle it
        app.needs_async_highlight = true;
    }

    pub fn navigateToPreviousFile(app: *App) void {
        if (app.state.files.len == 0) return;

        // Find which file cursor is currently in
        const current_file = app.state.line_map.getFileIndexForLine(app.state.global_cursor_line) orelse 0;

        // Jump to start of previous file (or wrap to last)
        const prev_file = if (current_file > 0)
            current_file - 1
        else
            app.state.files.len - 1;

        if (app.state.line_map.getFileHeaderLine(prev_file)) |start_line| {
            app.state.current_file_idx = prev_file;
            app.state.global_cursor_line = start_line;
            app.state.global_scroll_offset = start_line;

            // Force a full re-render when jumping files
            app.needs_render = true;
        }

        // Request async highlighting after navigation
        // Don't block - main loop will handle it
        app.needs_async_highlight = true;
    }

    pub fn pageDown(app: *App) void {
        const scroll_amount = app.state.viewport_height / 2;
        const total_lines = app.getTotalGlobalLines();

        // Move cursor down by half viewport, clamped to last line
        if (total_lines > 0) {
            app.state.global_cursor_line = @min(app.state.global_cursor_line + scroll_amount, total_lines - 1);
        }

        // Move viewport down by same amount to maintain screen position
        app.state.global_scroll_offset += scroll_amount;
        clampScrollOffset(app);

        // Clamp cursor column to new line length
    }

    pub fn pageUp(app: *App) void {
        const scroll_amount = app.state.viewport_height / 2;

        // Move cursor up by half viewport, clamped to 0
        app.state.global_cursor_line -|= scroll_amount;

        // Move viewport up by same amount to maintain screen position
        app.state.global_scroll_offset -|= scroll_amount;
    }

    pub fn scrollDown(app: *App) void {
        const count = app.state.count_prefix orelse 1;
        app.state.count_prefix = null;

        const total_lines = app.getTotalGlobalLines();

        // Move cursor down, clamped to last line
        if (total_lines > 0) {
            app.state.global_cursor_line = @min(app.state.global_cursor_line + count, total_lines - 1);
        }

        // Move viewport down by same amount
        app.state.global_scroll_offset += count;
        clampScrollOffset(app);
    }

    pub fn scrollUp(app: *App) void {
        const count = app.state.count_prefix orelse 1;
        app.state.count_prefix = null;

        // Move cursor up, clamped to 0
        app.state.global_cursor_line -|= count;

        // Move viewport up by same amount
        app.state.global_scroll_offset -|= count;
    }

    pub fn scrollToTop(app: *App) void {
        app.state.global_cursor_line = 0;
        app.state.global_scroll_offset = 0;
    }

    pub fn scrollToBottom(app: *App) void {
        const total_lines = app.getTotalGlobalLines();
        const viewport_height = app.state.viewport_height;

        // Move cursor to last line
        if (total_lines > 0) {
            app.state.global_cursor_line = total_lines - 1;
        }

        // Move viewport to show last page
        app.state.global_scroll_offset = if (total_lines > viewport_height)
            total_lines - viewport_height
        else
            0;
    }

    pub fn centerCursor(app: *App) void {
        // Move cursor to the middle line of the current viewport (like vim's 'M')
        const viewport_height = app.state.viewport_height;
        const scroll_offset = app.state.global_scroll_offset;

        if (viewport_height > 0) {
            const half_viewport = viewport_height / 2;
            const middle_line = scroll_offset + half_viewport;

            const total_lines = app.getTotalGlobalLines();
            if (total_lines > 0) {
                app.state.global_cursor_line = @min(middle_line, total_lines - 1);
            }
        }
    }

    pub fn centerViewportOnCursor(app: *App) void {
        // Center the viewport around the current cursor line (like vim's 'zz')
        const viewport_height = app.state.viewport_height;
        const cursor_line = app.state.global_cursor_line;
        const total_lines = app.getTotalGlobalLines();

        if (viewport_height > 0 and total_lines > 0) {
            const half_viewport = viewport_height / 2;

            // Calculate desired scroll offset to center cursor
            if (cursor_line >= half_viewport) {
                app.state.global_scroll_offset = cursor_line - half_viewport;
            } else {
                app.state.global_scroll_offset = 0;
            }

            // Ensure scroll offset doesn't go past the end
            clampScrollOffset(app);
        }
    }

    pub fn fullPageDown(app: *App) void {
        const scroll_amount = app.state.viewport_height;
        const total_lines = app.getTotalGlobalLines();

        // Move cursor down by a full viewport, clamped to last line
        if (total_lines > 0) {
            app.state.global_cursor_line = @min(app.state.global_cursor_line + scroll_amount, total_lines - 1);
        }

        // Move viewport down by same amount to maintain screen position
        app.state.global_scroll_offset += scroll_amount;
        clampScrollOffset(app);
    }

    pub fn fullPageUp(app: *App) void {
        const scroll_amount = app.state.viewport_height;

        // Move cursor up by a full viewport, clamped to 0
        app.state.global_cursor_line -|= scroll_amount;

        // Move viewport up by same amount to maintain screen position
        app.state.global_scroll_offset -|= scroll_amount;
    }

    pub fn clampScrollOffset(app: *App) void {
        const total_lines = app.getTotalGlobalLines();

        // Allow over-scrolling at the end so last file can be at top of screen
        // This creates a natural "padding" at the bottom for small files
        const max_scroll = if (total_lines > 0)
            total_lines - 1 // Any line can be at top of viewport
        else
            0;

        if (app.state.global_scroll_offset > max_scroll) {
            app.state.global_scroll_offset = max_scroll;
        }
    }

    // Adjust scroll to ensure cursor is visible with padding
    // Only called after explicit cursor movement (j/k), not during file navigation
    // Accounts for comment height when cursor is on a comment line
    pub fn ensureCursorVisible(app: *App, with_padding: bool) void {
        const padding: usize = if (with_padding) Layout.cursor_padding else 0;
        const cursor_line = app.state.global_cursor_line;
        const scroll_offset = app.state.global_scroll_offset;
        const window_height = app.state.viewport_height;

        // Check if cursor is on a comment line and get its rendered height
        const cursor_line_height = getSavedCommentHeight(app, cursor_line);

        if (cursor_line < scroll_offset + padding) {
            app.state.global_scroll_offset = if (cursor_line >= padding)
                cursor_line - padding
            else
                0;
        } else if (cursor_line + cursor_line_height > scroll_offset + window_height -| padding) {
            // Need to scroll down to show the entire comment
            const needed_bottom_space = cursor_line_height + padding;
            if (window_height > needed_bottom_space) {
                app.state.global_scroll_offset = (cursor_line + cursor_line_height) -| (window_height -| padding);
            } else {
                // Window too small, just show cursor line
                app.state.global_scroll_offset = cursor_line;
            }
        }
    }

    /// Calculate rendered height of a saved comment at the given line
    /// Returns 1 for non-comment lines
    fn getSavedCommentHeight(app: *App, global_line: usize) usize {
        const record = app.state.line_map.getLineRecord(global_line) orelse return 1;

        switch (record.line_type) {
            .comment_line => |comment_info| {
                const comment = app.state.comment_store.getComment(comment_info.comment_idx) orelse return 1;
                return savedCommentHeight(app, comment, record);
            },
            .review_thread => |thread_info| {
                const width = if (app.state.viewport_width > 0) app.state.viewport_width else 80;
                return RenderUtils.reviewThreadHeight(app, thread_info.thread_idx, thread_info.placement == .file_bucket, width);
            },
            else => return 1,
        }
    }

    /// Rows the comment block above an open reply editor occupies, or 0 when the
    /// editor is not a reply to a local comment.
    fn replyBlockHeight(app: *App) usize {
        const input = app.state.active_comment_input orelse return 0;
        const comment_id = switch (input.edit_context) {
            .local_reply => |lr| lr.comment_id,
            else => return 0,
        };
        const comment_idx = app.state.comment_store.findById(comment_id) orelse return 0;

        const record = app.state.line_map.getLineRecord(app.state.global_cursor_line) orelse return 0;
        if (record.line_type != .comment_line) return 0;

        const comment = app.state.comment_store.getComment(comment_idx) orelse return 0;
        return savedCommentHeight(app, comment, record);
    }

    /// Rendered height of a saved comment block, asked of the same row planner
    /// the renderers use so scrolling reserves exactly what gets painted. The
    /// block's width depends on the view: full content width in unified, and the
    /// anchor line's pane in side-by-side.
    fn savedCommentHeight(
        app: *App,
        comment: *const comments.Comment,
        record: *const line_map.LineRecord,
    ) usize {
        const viewport_width = if (app.state.viewport_width > 0) app.state.viewport_width else 80;

        switch (app.state.view_mode) {
            .unified => {
                const gutter_width = app.getGlobalGutterWidth(app.state.show_blame);
                const content_start = 1 + gutter_width + Layout.gutter_spacing;
                return RenderUtils.commentDisplayHeight(app, comment, viewport_width -| content_start);
            },
            .side_by_side => {
                const gutter_width = app.getGlobalGutterWidth(false);
                const total_borders_and_gutters = Layout.sidebar_width + (2 * gutter_width) + (2 * Layout.gutter_spacing) + 1;
                if (viewport_width <= total_borders_and_gutters) return 1;

                const available_width = viewport_width - total_borders_and_gutters;
                const left_content_width = available_width / 2;

                const line_type = anchorLineType(app, record, comment) orelse .context;
                return SideBySideRenderer.sideBySideCommentHeight(app, comment, .{
                    .line_type = line_type,
                    .left_width = left_content_width,
                    .right_width = available_width - left_content_width,
                    .gutter_width = gutter_width,
                });
            },
        }
    }

    /// The diff line a comment hangs off, which decides its pane in side-by-side.
    /// Falls back to the line type captured on the comment when the parent line is
    /// no longer reachable (a refreshed diff can drop it).
    fn anchorLineType(
        app: *App,
        record: *const line_map.LineRecord,
        comment: *const comments.Comment,
    ) ?parser.Line.LineType {
        const info = record.line_type.comment_line;
        if (record.file_idx >= app.state.files.len) return comment.line_type;

        const file = &app.state.files[record.file_idx];
        if (info.parent_hunk_idx >= file.hunks.len) return comment.line_type;

        const hunk = &file.hunks[info.parent_hunk_idx];
        if (info.parent_line_idx >= hunk.lines.len) return comment.line_type;

        return hunk.lines[info.parent_line_idx].line_type;
    }

    /// Calculate actual comment box height based on text content
    fn calculateCommentBoxHeight(app: *App) usize {
        const input = app.state.active_comment_input orelse return 6; // Fallback if no input

        // Fixed overhead: 2 lines (top spacer + label line) + 2 for bottom border/padding
        var height: usize = 4;

        // Count newlines in the text
        const text = input.vim.text_buffer[0..input.vim.text_len];
        var newline_count: usize = 0;
        for (text) |ch| {
            if (ch == '\n') {
                newline_count += 1;
            }
        }

        // Each text line (split by newlines) takes at least 1 row
        // Empty text = 1 line, "a\nb" = 2 lines, etc.
        const text_lines = newline_count + 1;
        height += text_lines;

        // Account for text wrapping (estimate based on typical viewport width)
        // Assume text area width is ~80-100 chars (conservative estimate)
        const estimated_text_width: usize = 80;

        // For each text line, estimate how many wrapped rows it needs
        var line_iter = std.mem.splitScalar(u8, text, '\n');
        var wrap_overhead: usize = 0;
        while (line_iter.next()) |line| {
            if (line.len > estimated_text_width) {
                // This line will wrap - add extra rows
                const wrapped_rows = (line.len + estimated_text_width - 1) / estimated_text_width;
                wrap_overhead += wrapped_rows - 1; // -1 because we already counted the base line
            }
        }
        height += wrap_overhead;

        // Add some buffer for safety (2-3 extra lines)
        height += 3;

        return height;
    }

    /// Ensure comment box is visible, accounting for its actual height
    /// Dynamically calculates height based on text content and wrapping
    pub fn ensureCommentBoxVisible(app: *App) void {
        const cursor_line = app.state.global_cursor_line;
        const scroll_offset = app.state.global_scroll_offset;
        const window_height = app.state.viewport_height;

        // A reply editor is drawn *below* the block it answers, so the block's
        // rows have to be reserved too or the box lands off the bottom of a long
        // thread.
        const comment_box_height = calculateCommentBoxHeight(app) + replyBlockHeight(app);
        const top_padding: usize = 2; // Room at top

        // Check if cursor is too high
        if (cursor_line < scroll_offset + top_padding) {
            app.state.global_scroll_offset = if (cursor_line >= top_padding)
                cursor_line - top_padding
            else
                0;
        }
        // Check if comment box would extend below viewport
        else if (cursor_line + comment_box_height >= scroll_offset + window_height) {
            // Scroll so the entire comment box fits, with cursor near bottom
            if (window_height > comment_box_height + top_padding) {
                app.state.global_scroll_offset = (cursor_line + comment_box_height) -| window_height + 1;
            } else {
                // Window too small, just show cursor
                app.state.global_scroll_offset = cursor_line;
            }
        }
    }

    /// Jump to next empty line (spacer or empty content line)
    /// Skips contiguous empty lines (vim-style paragraph motion)
    /// Supports count prefix (e.g., 3} jumps to 3rd next paragraph boundary)
    pub fn jumpToNextEmptyLine(app: *App) void {
        const count = app.state.count_prefix orelse 1;
        app.state.count_prefix = null;

        const total_lines = app.getTotalGlobalLines();
        if (total_lines == 0) return;

        var jumps_remaining = count;
        var search_line = app.state.global_cursor_line;

        while (search_line < total_lines and jumps_remaining > 0) {
            // Skip any contiguous empty lines from current position
            while (search_line < total_lines and app.state.line_map.isEmptyLine(search_line, app.state.files)) {
                search_line += 1;
            }

            // Skip non-empty lines to find next empty line
            while (search_line < total_lines and !app.state.line_map.isEmptyLine(search_line, app.state.files)) {
                search_line += 1;
            }

            // If we found an empty line, that's one jump
            if (search_line < total_lines and app.state.line_map.isEmptyLine(search_line, app.state.files)) {
                jumps_remaining -= 1;
                if (jumps_remaining == 0) {
                    app.state.global_cursor_line = search_line;
                    ensureCursorVisible(app, true);
                    return;
                }
                // Continue from next line for multiple jumps
                search_line += 1;
            }
        }

        // No wrapping - stay at current position if no more empty lines found
    }

    /// Jump to previous empty line (spacer or empty content line)
    /// Skips contiguous empty lines (vim-style paragraph motion)
    /// Supports count prefix (e.g., 3{ jumps to 3rd previous paragraph boundary)
    pub fn jumpToPreviousEmptyLine(app: *App) void {
        const count = app.state.count_prefix orelse 1;
        app.state.count_prefix = null;

        if (app.state.global_cursor_line == 0) return;

        var jumps_remaining = count;
        var search_line = app.state.global_cursor_line;

        // Search backward, including line 0
        while (jumps_remaining > 0) {
            // Skip any contiguous empty lines from current position
            while (app.state.line_map.isEmptyLine(search_line, app.state.files)) {
                if (search_line == 0) break;
                search_line -= 1;
            }

            // Skip non-empty lines to find previous empty line
            while (!app.state.line_map.isEmptyLine(search_line, app.state.files)) {
                if (search_line == 0) break;
                search_line -= 1;
            }

            // If we found an empty line, that's one jump
            if (app.state.line_map.isEmptyLine(search_line, app.state.files)) {
                jumps_remaining -= 1;
                if (jumps_remaining == 0) {
                    app.state.global_cursor_line = search_line;
                    ensureCursorVisible(app, true);
                    return;
                }
                // Continue from previous line for multiple jumps (only if not at start)
                if (search_line == 0) break;
                search_line -= 1;
            } else {
                // Didn't find an empty line, stop searching
                break;
            }
        }

        // No wrapping - stay at current position if no more empty lines found
    }

    /// Check if a line is a code change (add or delete line)
    fn isCodeChange(app: *App, line_num: usize) bool {
        if (app.state.line_map.getLineRecord(line_num)) |record| {
            if (record.line_type == .code_line) {
                const code_info = record.line_type.code_line;
                const file = &app.state.files[record.file_idx];
                const hunk = &file.hunks[code_info.hunk_idx];
                const line = &hunk.lines[code_info.line_idx_in_hunk];
                return line.line_type == .add or line.line_type == .delete;
            }
        }
        return false;
    }

    /// Jump to next contiguous block of code changes (vim-style ]h)
    /// Skips context lines and jumps between blocks of additions/deletions
    /// Supports count prefix (e.g., 3]h jumps to 3rd next change block)
    pub fn jumpToNextCodeChange(app: *App) void {
        const count = app.state.count_prefix orelse 1;
        app.state.count_prefix = null;

        const total_lines = app.getTotalGlobalLines();
        if (total_lines == 0) return;

        var jumps_remaining = count;
        var search_line = app.state.global_cursor_line + 1; // Start from next line

        while (search_line < total_lines and jumps_remaining > 0) {
            // Skip any contiguous code changes from current position
            while (search_line < total_lines and isCodeChange(app, search_line)) {
                search_line += 1;
            }

            // Skip non-change lines (context, headers, etc.)
            while (search_line < total_lines and !isCodeChange(app, search_line)) {
                search_line += 1;
            }

            // If we found a code change, that's one jump
            if (search_line < total_lines and isCodeChange(app, search_line)) {
                jumps_remaining -= 1;
                if (jumps_remaining == 0) {
                    app.state.global_cursor_line = search_line;
                    ensureCursorVisible(app, true);
                    return;
                }
                // Continue from next line for multiple jumps
                search_line += 1;
            }
        }

        // No wrapping - stay at current position if no more changes found
    }

    /// Jump to previous contiguous block of code changes (vim-style [h)
    /// Skips context lines and jumps between blocks of additions/deletions
    /// Supports count prefix (e.g., 3[h jumps to 3rd previous change block)
    pub fn jumpToPreviousCodeChange(app: *App) void {
        const count = app.state.count_prefix orelse 1;
        app.state.count_prefix = null;

        if (app.state.global_cursor_line == 0) return;

        var jumps_remaining = count;
        var search_line = app.state.global_cursor_line;

        // Move back one to start searching from previous line
        if (search_line > 0) {
            search_line -= 1;
        }

        // Search backward, including line 0
        while (jumps_remaining > 0) {
            // Skip any contiguous code changes from current position
            while (isCodeChange(app, search_line)) {
                if (search_line == 0) break;
                search_line -= 1;
            }

            // Skip non-change lines (context, headers, etc.)
            while (!isCodeChange(app, search_line)) {
                if (search_line == 0) break;
                search_line -= 1;
            }

            // If we found a code change, that's one jump
            if (isCodeChange(app, search_line)) {
                jumps_remaining -= 1;
                if (jumps_remaining == 0) {
                    app.state.global_cursor_line = search_line;
                    ensureCursorVisible(app, true);
                    return;
                }
                // Continue from previous line for multiple jumps
                if (search_line == 0) break;
                search_line -= 1;
            } else {
                // Didn't find a code change, stop searching
                break;
            }
        }

        // No wrapping - stay at current position if no more changes found
    }

    /// Jump to next comment line (vim-style ]c)
    /// Supports count prefix (e.g., 3]c jumps to 3rd next comment)
    pub fn jumpToNextComment(app: *App) void {
        const count = app.state.count_prefix orelse 1;
        app.state.count_prefix = null;

        const total_lines = app.getTotalGlobalLines();
        if (total_lines == 0) return;

        var jumps_remaining = count;
        var search_line = app.state.global_cursor_line + 1; // Start from next line

        while (search_line < total_lines and jumps_remaining > 0) {
            if (app.state.line_map.getLineRecord(search_line)) |record| {
                // Check if this is a comment line
                if (record.line_type == .comment_line) {
                    jumps_remaining -= 1;
                    if (jumps_remaining == 0) {
                        app.state.global_cursor_line = search_line;
                        centerViewportOnCursor(app);
                        return;
                    }
                }
            }
            search_line += 1;
        }

        // No wrapping - stay at current position if no more comments found
    }

    /// Jump to previous comment line (vim-style [c)
    /// Supports count prefix (e.g., 3[c jumps to 3rd previous comment)
    pub fn jumpToPreviousComment(app: *App) void {
        const count = app.state.count_prefix orelse 1;
        app.state.count_prefix = null;

        if (app.state.global_cursor_line == 0) return;

        var jumps_remaining = count;
        var search_line = app.state.global_cursor_line;

        // Move back one to start searching from previous line
        if (search_line > 0) {
            search_line -= 1;
        }

        // Search backward, including line 0
        while (jumps_remaining > 0) {
            if (app.state.line_map.getLineRecord(search_line)) |record| {
                // Check if this is a comment line
                if (record.line_type == .comment_line) {
                    jumps_remaining -= 1;
                    if (jumps_remaining == 0) {
                        app.state.global_cursor_line = search_line;
                        centerViewportOnCursor(app);
                        return;
                    }
                }
            }
            if (search_line == 0) break;
            search_line -= 1;
        }

        // No wrapping - stay at current position if no more comments found
    }
};
