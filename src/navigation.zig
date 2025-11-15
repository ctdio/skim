const std = @import("std");
const App = @import("app.zig").App;
const rendering = @import("rendering/common.zig");
const state_helpers = @import("state.zig");
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

        if (app.state.global_cursor_line >= count) {
            app.state.global_cursor_line -= count;
        } else {
            app.state.global_cursor_line = 0;
        }

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
        if (app.state.global_cursor_line >= scroll_amount) {
            app.state.global_cursor_line -= scroll_amount;
        } else {
            app.state.global_cursor_line = 0;
        }

        // Move viewport up by same amount to maintain screen position
        if (app.state.global_scroll_offset >= scroll_amount) {
            app.state.global_scroll_offset -= scroll_amount;
        } else {
            app.state.global_scroll_offset = 0;
        }

        // Clamp cursor column to new line length
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
        if (app.state.global_cursor_line >= count) {
            app.state.global_cursor_line -= count;
        } else {
            app.state.global_cursor_line = 0;
        }

        // Move viewport up by same amount
        if (app.state.global_scroll_offset >= count) {
            app.state.global_scroll_offset -= count;
        } else {
            app.state.global_scroll_offset = 0;
        }
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

    pub fn scrollPageDown(app: *App) void {
        const scroll_amount = app.state.viewport_height / 2;
        const total_lines = app.getTotalGlobalLines();

        // Move cursor down by half viewport, clamped to last line
        if (total_lines > 0) {
            app.state.global_cursor_line = @min(app.state.global_cursor_line + scroll_amount, total_lines - 1);
        }

        // Move viewport down by same amount to maintain screen position
        app.state.global_scroll_offset += scroll_amount;
        clampScrollOffset(app);
    }

    pub fn scrollPageUp(app: *App) void {
        const scroll_amount = app.state.viewport_height / 2;

        // Move cursor up by half viewport, clamped to 0
        if (app.state.global_cursor_line >= scroll_amount) {
            app.state.global_cursor_line -= scroll_amount;
        } else {
            app.state.global_cursor_line = 0;
        }

        // Move viewport up by same amount to maintain screen position
        if (app.state.global_scroll_offset >= scroll_amount) {
            app.state.global_scroll_offset -= scroll_amount;
        } else {
            app.state.global_scroll_offset = 0;
        }
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
    pub fn ensureCursorVisible(app: *App, with_padding: bool) void {
        const padding: usize = if (with_padding) Layout.cursor_padding else 0;
        const cursor_line = app.state.global_cursor_line;
        const scroll_offset = app.state.global_scroll_offset;
        const window_height = app.state.viewport_height;

        if (cursor_line < scroll_offset + padding) {
            app.state.global_scroll_offset = if (cursor_line >= padding)
                cursor_line - padding
            else
                0;
        } else if (cursor_line >= scroll_offset + window_height -| (padding + 1)) {
            app.state.global_scroll_offset = cursor_line -| (window_height -| (padding + 2));
        }
    }

    /// Calculate actual comment box height based on text content
    fn calculateCommentBoxHeight(app: *App) usize {
        const input = app.state.active_comment_input orelse return 6; // Fallback if no input

        // Fixed overhead: 2 lines (top spacer + label line) + 2 for bottom border/padding
        var height: usize = 4;

        // Count newlines in the text
        const text = input.text_buffer[0..input.text_len];
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

        // Calculate actual comment box height based on current text
        const comment_box_height = calculateCommentBoxHeight(app);
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
};
