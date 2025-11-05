const App = @import("app.zig").App;
const rendering = @import("rendering/common.zig");
const Layout = rendering.Layout;

pub const Navigation = struct {
    pub fn moveCursorDown(app: *App) void {
        const count = app.state.count_prefix orelse 1;
        app.state.count_prefix = null;

        const total_lines = app.getTotalLinesInCurrentFile();
        if (total_lines > 0) {
            const new_line = @min(app.state.cursor_line + count, total_lines - 1);
            app.state.cursor_line = new_line;
        }

        // Clamp cursor column to new line length (vim-like behavior)
        clampCursorColumn(app);
    }

    pub fn moveCursorUp(app: *App) void {
        const count = app.state.count_prefix orelse 1;
        app.state.count_prefix = null;

        if (app.state.cursor_line >= count) {
            app.state.cursor_line -= count;
        } else {
            app.state.cursor_line = 0;
        }

        // Clamp cursor column to new line length (vim-like behavior)
        clampCursorColumn(app);
    }

    pub fn moveCursorLeft(app: *App) void {
        const count = app.state.count_prefix orelse 1;
        app.state.count_prefix = null;

        if (app.state.cursor_col >= count) {
            app.state.cursor_col -= count;
        } else {
            app.state.cursor_col = 0;
        }
    }

    pub fn moveCursorRight(app: *App) void {
        const count = app.state.count_prefix orelse 1;
        app.state.count_prefix = null;

        // Get the current line content to limit horizontal movement
        const line_content = app.getCurrentLineContent();
        if (line_content) |content| {
            const max_col = if (content.len > 0) content.len - 1 else 0;
            const new_col = app.state.cursor_col + count;
            app.state.cursor_col = @min(new_col, max_col);
        }
    }

    pub fn navigateToNextFile(app: *App) void {
        if (app.state.files.len == 0) return;

        if (app.state.current_file_idx + 1 < app.state.files.len) {
            app.state.current_file_idx += 1;
        } else {
            // Wrap to first file
            app.state.current_file_idx = 0;
        }
        resetFileState(app);
    }

    pub fn navigateToPreviousFile(app: *App) void {
        if (app.state.files.len == 0) return;

        if (app.state.current_file_idx > 0) {
            app.state.current_file_idx -= 1;
        } else {
            // Wrap to last file
            app.state.current_file_idx = app.state.files.len - 1;
        }
        resetFileState(app);
    }

    pub fn resetFileState(app: *App) void {
        app.state.scroll_offset = 0;
        app.state.cursor_line = 0;
        app.state.cursor_col = 0;
        app.state.h_scroll_offset = 0;
    }

    pub fn pageDown(app: *App) void {
        const scroll_amount = app.state.viewport_height / 2;
        const total_lines = app.getTotalLinesInCurrentFile();

        // Move cursor down by half viewport, clamped to last line
        if (total_lines > 0) {
            app.state.cursor_line = @min(app.state.cursor_line + scroll_amount, total_lines - 1);
        }

        // Move viewport down by same amount to maintain screen position
        app.state.scroll_offset += scroll_amount;
        clampScrollOffset(app);

        // Clamp cursor column to new line length
        clampCursorColumn(app);
    }

    pub fn pageUp(app: *App) void {
        const scroll_amount = app.state.viewport_height / 2;

        // Move cursor up by half viewport, clamped to 0
        if (app.state.cursor_line >= scroll_amount) {
            app.state.cursor_line -= scroll_amount;
        } else {
            app.state.cursor_line = 0;
        }

        // Move viewport up by same amount to maintain screen position
        if (app.state.scroll_offset >= scroll_amount) {
            app.state.scroll_offset -= scroll_amount;
        } else {
            app.state.scroll_offset = 0;
        }

        // Clamp cursor column to new line length
        clampCursorColumn(app);
    }

    pub fn scrollDown(app: *App) void {
        const count = app.state.count_prefix orelse 1;
        app.state.count_prefix = null;

        const total_lines = app.getTotalLinesInCurrentFile();

        // Move cursor down, clamped to last line
        if (total_lines > 0) {
            app.state.cursor_line = @min(app.state.cursor_line + count, total_lines - 1);
        }

        // Move viewport down by same amount
        app.state.scroll_offset += count;
        clampScrollOffset(app);
        clampCursorColumn(app);
    }

    pub fn scrollUp(app: *App) void {
        const count = app.state.count_prefix orelse 1;
        app.state.count_prefix = null;

        // Move cursor up, clamped to 0
        if (app.state.cursor_line >= count) {
            app.state.cursor_line -= count;
        } else {
            app.state.cursor_line = 0;
        }

        // Move viewport up by same amount
        if (app.state.scroll_offset >= count) {
            app.state.scroll_offset -= count;
        } else {
            app.state.scroll_offset = 0;
        }

        clampCursorColumn(app);
    }

    pub fn scrollToTop(app: *App) void {
        app.state.cursor_line = 0;
        app.state.scroll_offset = 0;
        clampCursorColumn(app);
    }

    pub fn scrollToBottom(app: *App) void {
        const total_lines = app.getTotalLinesInCurrentFile();
        const viewport_height = app.state.viewport_height;

        // Move cursor to last line
        if (total_lines > 0) {
            app.state.cursor_line = total_lines - 1;
        }

        // Move viewport to show last page
        app.state.scroll_offset = if (total_lines > viewport_height)
            total_lines - viewport_height
        else
            0;

        clampCursorColumn(app);
    }

    pub fn centerCursor(app: *App) void {
        // Move cursor to the middle line of the current viewport (like vim's 'M')
        const viewport_height = app.state.viewport_height;
        const scroll_offset = app.state.scroll_offset;

        if (viewport_height > 0) {
            const half_viewport = viewport_height / 2;
            const middle_line = scroll_offset + half_viewport;

            const total_lines = app.getTotalLinesInCurrentFile();
            if (total_lines > 0) {
                app.state.cursor_line = @min(middle_line, total_lines - 1);
            }
        }

        clampCursorColumn(app);
    }

    pub fn scrollPageDown(app: *App) void {
        const scroll_amount = app.state.viewport_height / 2;
        const total_lines = app.getTotalLinesInCurrentFile();

        // Move cursor down by half viewport, clamped to last line
        if (total_lines > 0) {
            app.state.cursor_line = @min(app.state.cursor_line + scroll_amount, total_lines - 1);
        }

        // Move viewport down by same amount to maintain screen position
        app.state.scroll_offset += scroll_amount;
        clampScrollOffset(app);
        clampCursorColumn(app);
    }

    pub fn scrollPageUp(app: *App) void {
        const scroll_amount = app.state.viewport_height / 2;

        // Move cursor up by half viewport, clamped to 0
        if (app.state.cursor_line >= scroll_amount) {
            app.state.cursor_line -= scroll_amount;
        } else {
            app.state.cursor_line = 0;
        }

        // Move viewport up by same amount to maintain screen position
        if (app.state.scroll_offset >= scroll_amount) {
            app.state.scroll_offset -= scroll_amount;
        } else {
            app.state.scroll_offset = 0;
        }

        clampCursorColumn(app);
    }

    // Clamp cursor column to the current line length (vim-like behavior)
    pub fn clampCursorColumn(app: *App) void {
        const line_content = app.getCurrentLineContent();
        if (line_content) |content| {
            if (content.len > 0) {
                // In vim, cursor can be on any character, so max is len-1
                const max_col = content.len - 1;
                if (app.state.cursor_col > max_col) {
                    app.state.cursor_col = max_col;
                }
            } else {
                // Empty line - cursor at column 0
                app.state.cursor_col = 0;
            }
        } else {
            // No content (e.g., hunk header) - reset to column 0
            app.state.cursor_col = 0;
        }
    }

    // Adjust horizontal scroll offset to keep cursor visible (vim-like behavior)
    pub fn adjustHorizontalScroll(app: *App, content_width: usize) void {
        if (content_width == 0) return;

        const cursor_col = app.state.cursor_col;
        const h_scroll = app.state.h_scroll_offset;

        // If cursor is off the left edge, scroll left
        if (cursor_col < h_scroll) {
            app.state.h_scroll_offset = cursor_col;
        }
        // If cursor is off the right edge, scroll right
        else if (cursor_col >= h_scroll + content_width) {
            app.state.h_scroll_offset = cursor_col - content_width + 1;
        }
    }

    pub fn clampScrollOffset(app: *App) void {
        const total_lines = app.getTotalLinesInCurrentFile();
        const viewport_height = app.state.viewport_height;

        // Calculate max scroll offset (vim-style: can't scroll past end)
        const max_scroll = if (total_lines > viewport_height)
            total_lines - viewport_height
        else
            0;

        if (app.state.scroll_offset > max_scroll) {
            app.state.scroll_offset = max_scroll;
        }
    }

    pub fn adjustScrollToKeepCursorVisible(app: *App, window_height: usize) void {
        const padding = Layout.cursor_padding;
        const cursor_line = app.state.cursor_line;
        const scroll_offset = app.state.scroll_offset;

        if (cursor_line < scroll_offset + padding) {
            app.state.scroll_offset = if (cursor_line >= padding)
                cursor_line - padding
            else
                0;
        } else if (cursor_line >= scroll_offset + window_height -| (padding + 1)) {
            app.state.scroll_offset = cursor_line -| (window_height -| (padding + 2));
        }
    }
};
