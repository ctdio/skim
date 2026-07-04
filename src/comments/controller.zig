//! Controller for review-comment operations. Owns all logic over the comment
//! sub-state on `App.state` (`comment_store`, `active_comment_input`,
//! `expanded_comments`): starting/saving the inline comment editor, yanking
//! comments to the clipboard or agent panel, deleting/clearing comments, and
//! the per-comment expand/collapse toggle. App keeps only mode dispatch and the
//! shared cross-cutting services these functions reach through.

const std = @import("std");

const App = @import("../app.zig").App;
const comment_editor = @import("editor.zig");
const line_map = @import("../line_map.zig");
const clipboard = @import("../clipboard.zig");
const navigation = @import("../navigation.zig");
const hunk_view = @import("../hunk_view.zig");

const Navigation = navigation.Navigation;

pub const CommentController = struct {
    pub fn startCommentInput(app: *App) !void {
        // Get line record from LineMap
        const record = app.state.line_map.getLineRecord(app.state.global_cursor_line) orelse return;

        if (record.file_idx >= app.state.files.len) return;
        const file = &app.state.files[record.file_idx];
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

        var target_hunk_idx: usize = undefined;
        var target_line_idx: usize = undefined;
        var existing_comment_idx: ?usize = null;

        switch (record.line_type) {
            .file_header, .hunk_header, .spacer => {
                // Can't comment on these line types
                return;
            },
            .code_line => |code| {
                // Check if there's already a comment on this code line
                target_hunk_idx = code.hunk_idx;
                target_line_idx = code.line_idx_in_hunk;

                // First check if there's an existing comment in the store
                existing_comment_idx = app.state.comment_store.findCommentAt(
                    file_path,
                    target_hunk_idx,
                    target_line_idx,
                );

                // If we found an existing comment, move cursor to the comment line
                if (existing_comment_idx != null) {
                    // Find the comment line in the LineMap (it should be right after this code line)
                    const total_lines = app.state.line_map.getTotalLines();
                    var search_line = app.state.global_cursor_line + 1;
                    while (search_line < total_lines) : (search_line += 1) {
                        if (app.state.line_map.getLineRecord(search_line)) |search_record| {
                            if (search_record.line_type == .comment_line) {
                                const comment_info = search_record.line_type.comment_line;
                                if (comment_info.comment_idx == existing_comment_idx.?) {
                                    // Found the comment line - move cursor to it
                                    app.state.global_cursor_line = search_line;
                                    break;
                                }
                            } else if (search_record.line_type != .spacer) {
                                // Reached a non-spacer, non-comment line - stop searching
                                break;
                            }
                        }
                    }
                }
            },
            .comment_line => |comment_info| {
                // User pressed Enter on the comment line itself - edit that comment
                target_hunk_idx = comment_info.parent_hunk_idx;
                target_line_idx = comment_info.parent_line_idx;
                existing_comment_idx = comment_info.comment_idx;
            },
        }

        // Initialize input buffer
        var input = comment_editor.CommentEditor.State{
            .target_file_path = file_path,
            .target_hunk_idx = target_hunk_idx,
            .target_line_idx = target_line_idx,
            .target_end_hunk_idx = null, // Single-line comment
            .target_end_line_idx = null, // Single-line comment
            .editing_comment_idx = existing_comment_idx,
            .vim = comment_editor.CommentEditor.VimEditor.State.initWithMode(.insert),
        };

        // If editing existing comment, load its text
        if (existing_comment_idx) |idx| {
            if (app.state.comment_store.getComment(idx)) |comment| {
                input.vim.setText(comment.text);
                input.vim.cursor_pos = input.vim.text_len; // Start cursor at end
            }
        }

        app.state.active_comment_input = input;
        app.mode = .comment;
    }

    pub fn startCommentInputForVisualSelection(app: *App) !void {
        // Get visual selection range
        const selection = app.getVisualSelection() orelse return;
        const start_line = selection.start;
        const end_line = selection.end;

        // Get records for start and end lines
        const start_record = app.state.line_map.getLineRecord(start_line) orelse return;
        const end_record = app.state.line_map.getLineRecord(end_line) orelse return;

        // Selection must be within the same file
        if (start_record.file_idx != end_record.file_idx) {
            return; // Can't comment across multiple files
        }

        // Can only comment on code lines
        if (start_record.line_type != .code_line or end_record.line_type != .code_line) {
            return;
        }

        const start_code = start_record.line_type.code_line;
        const end_code = end_record.line_type.code_line;

        // Selection must be within the same hunk
        if (start_code.hunk_idx != end_code.hunk_idx) {
            return; // Can't comment across multiple hunks
        }

        // Get file information from start line
        if (start_record.file_idx >= app.state.files.len) return;
        const file = &app.state.files[start_record.file_idx];
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

        // Check if selection is a single line
        const is_single_line = (start_line == end_line);

        // Initialize input buffer for range comment
        const input = comment_editor.CommentEditor.State{
            .target_file_path = file_path,
            .target_hunk_idx = start_code.hunk_idx,
            .target_line_idx = start_code.line_idx_in_hunk,
            .target_end_hunk_idx = if (is_single_line) null else end_code.hunk_idx,
            .target_end_line_idx = if (is_single_line) null else end_code.line_idx_in_hunk,
            .editing_comment_idx = null, // Always creating new comment from visual mode
            .vim = comment_editor.CommentEditor.VimEditor.State.initWithMode(.insert),
        };

        app.state.active_comment_input = input;
        app.mode = .comment;

        // Move cursor to the end of the range (lowest selection point) where the comment will appear
        app.state.global_cursor_line = end_line;

        // Ensure the comment box is visible on screen
        // Use extra padding to account for comment box height (starts with ~4 lines minimum)
        Navigation.ensureCommentBoxVisible(app);

        // Exit visual mode
        app.state.visual_anchor = null;
    }

    pub fn saveCurrentComment(app: *App) !bool {
        if (app.state.active_comment_input == null) return false;

        const input = app.state.active_comment_input.?;
        if (input.vim.text_len == 0) {
            // Empty comment - delete if editing existing, otherwise do nothing
            if (input.editing_comment_idx) |idx| {
                try app.state.comment_store.deleteComment(idx);
            }
            return true;
        }

        const comment_text = input.vim.text_buffer[0..input.vim.text_len];

        // Get line context for the comment
        const file_idx = findFileIndexByPath(app, input.target_file_path) orelse {
            app.showStatusMessage("Comment target file not found");
            return false;
        };
        const file = &app.state.files[file_idx];
        if (input.target_hunk_idx >= file.hunks.len) {
            app.showStatusMessage("Comment target hunk not found");
            return false;
        }
        const hunk = &file.hunks[input.target_hunk_idx];
        if (input.target_line_idx >= hunk.lines.len) {
            app.showStatusMessage("Comment target line not found");
            return false;
        }
        const line = &hunk.lines[input.target_line_idx];

        // Track the comment index for cursor positioning after save
        var saved_comment_idx: usize = undefined;

        if (input.editing_comment_idx) |idx| {
            // Update existing comment
            try app.state.comment_store.updateComment(idx, comment_text);
            saved_comment_idx = idx;
        } else {
            // Check if this is a range comment
            if (input.target_end_hunk_idx != null and input.target_end_line_idx != null) {
                const end_hunk_idx = input.target_end_hunk_idx.?;
                const end_line_idx = input.target_end_line_idx.?;
                if (end_hunk_idx >= file.hunks.len) {
                    app.showStatusMessage("Comment range hunk not found");
                    return false;
                }
                const end_hunk = &file.hunks[end_hunk_idx];
                if (end_line_idx >= end_hunk.lines.len) {
                    app.showStatusMessage("Comment range line not found");
                    return false;
                }
                // Add range comment
                try app.state.comment_store.addRangeComment(
                    input.target_file_path,
                    input.target_hunk_idx,
                    input.target_line_idx,
                    end_hunk_idx,
                    end_line_idx,
                    comment_text,
                    line.line_type,
                    line.content,
                    line.old_lineno,
                    line.new_lineno,
                );
            } else {
                // Add single-line comment
                try app.state.comment_store.addComment(
                    input.target_file_path,
                    input.target_hunk_idx,
                    input.target_line_idx,
                    comment_text,
                    line.line_type,
                    line.content,
                    line.old_lineno,
                    line.new_lineno,
                );
            }
            // New comment is at the end of the list
            saved_comment_idx = app.state.comment_store.comments.items.len - 1;
        }

        // Rebuild LineMap since comment count changed
        app.state.line_map.deinit();
        app.state.line_map = try line_map.LineMap.build(app.allocator, app.state.files, &app.state.comment_store, hunk_view.convertHunkViewMode(app), hunk_view.shouldApplyHunkFiltering(app), &app.state.collapsed_folds);

        // Move cursor to the saved comment so it can be easily yanked
        if (app.state.line_map.findLineByCommentIdx(saved_comment_idx)) |comment_line| {
            app.state.global_cursor_line = comment_line;
        }
        return true;
    }

    pub fn yankCurrentCommentToClipboard(app: *App) !void {
        // Get line record from LineMap
        const record = app.state.line_map.getLineRecord(app.state.global_cursor_line) orelse return;

        switch (record.line_type) {
            .comment_line => |comment_info| {
                // Generate export with context (10 lines before, 10 lines after for LLM context)
                const output = try app.state.comment_store.exportSingleCommentWithContext(
                    app.allocator,
                    comment_info.comment_idx,
                    app.state.files,
                    10, // lines before
                    10, // lines after
                );
                defer app.allocator.free(output);

                try clipboard.copyToClipboard(app.allocator, output);
            },
            else => {}, // Not on a comment line, do nothing
        }
    }

    pub fn yankAllCommentsToClipboard(app: *App) !void {
        // Generate export with context (10 lines before, 10 lines after for LLM context)
        const output = try app.state.comment_store.exportWithContext(
            app.allocator,
            app.state.files,
            10, // lines before
            10, // lines after
        );
        defer app.allocator.free(output);

        try clipboard.copyToClipboard(app.allocator, output);
    }

    /// Yank all comments and send to agent panel input
    pub fn yankCommentsToAgent(app: *App) !void {
        // Generate export with context (10 lines before, 10 lines after for LLM context)
        const output = try app.state.comment_store.exportWithContext(
            app.allocator,
            app.state.files,
            10, // lines before
            10, // lines after
        );
        defer app.allocator.free(output);

        if (output.len == 0) {
            app.showStatusMessage("No comments to send");
            return;
        }

        // Open agent panel if not already open
        if (!app.isAgentPanelVisible()) {
            try app.toggleAgentPanel();
        }

        // Set the input text in the active agent state
        if (app.getActiveAgentState()) |agent_state| {
            agent_state.input.setText(output);
            // Switch to insert mode so user can add context
            agent_state.input.vim.vim_mode = .insert;
            // Move cursor to end
            agent_state.input.vim.cursor_pos = agent_state.input.vim.text_len;
        }

        app.needs_render = true;
    }

    pub fn deleteCommentUnderCursor(app: *App) !void {
        // Get line record from LineMap
        const record = app.state.line_map.getLineRecord(app.state.global_cursor_line) orelse return;

        switch (record.line_type) {
            .comment_line => |comment_info| {
                const parent_file_idx = record.file_idx;
                const parent_hunk_idx = comment_info.parent_hunk_idx;
                const parent_line_idx = comment_info.parent_line_idx;

                // Capture positions BEFORE deletion
                const old_parent_pos = findCodeLine(app, parent_file_idx, parent_hunk_idx, parent_line_idx);
                const old_scroll = app.state.global_scroll_offset;
                const comment_line = app.state.global_cursor_line; // cursor is on the comment

                // Delete the comment
                try app.state.comment_store.deleteComment(comment_info.comment_idx);

                // Rebuild LineMap since comment count changed
                app.state.line_map.deinit();
                app.state.line_map = try line_map.LineMap.build(app.allocator, app.state.files, &app.state.comment_store, hunk_view.convertHunkViewMode(app), hunk_view.shouldApplyHunkFiltering(app), &app.state.collapsed_folds);

                const total_lines = app.getTotalGlobalLines();
                if (total_lines == 0) {
                    app.state.global_cursor_line = 0;
                    app.state.global_scroll_offset = 0;
                    return;
                }

                // Find parent in new LineMap (position unchanged since it's above the deleted comment)
                if (findCodeLine(app, parent_file_idx, parent_hunk_idx, parent_line_idx)) |new_parent_line| {
                    app.state.global_cursor_line = new_parent_line;

                    // Determine scroll position based on where scroll was relative to parent/comment
                    if (old_parent_pos) |parent_pos| {
                        if (old_scroll <= parent_pos) {
                            // Scroll was at or before parent - content at scroll unchanged
                            app.state.global_scroll_offset = old_scroll;
                        } else if (old_scroll <= comment_line) {
                            // Scroll was between parent and comment (or on comment)
                            // Show parent at top (cursor is there anyway)
                            app.state.global_scroll_offset = new_parent_line;
                        } else {
                            // Scroll was AFTER the comment - content shifted up by 1
                            // Reduce scroll by 1 to show same visual content
                            app.state.global_scroll_offset = if (old_scroll > 0) old_scroll - 1 else 0;
                        }
                    } else {
                        // Couldn't find old parent, keep scroll at same position minus 1
                        app.state.global_scroll_offset = if (old_scroll > 0) old_scroll - 1 else 0;
                    }

                    // Clamp to valid range
                    if (app.state.global_scroll_offset >= total_lines) {
                        app.state.global_scroll_offset = total_lines - 1;
                    }
                } else {
                    // Fallback: keep cursor and scroll in valid range
                    app.state.global_cursor_line = @min(app.state.global_cursor_line, total_lines - 1);
                    app.state.global_scroll_offset = @min(old_scroll, total_lines - 1);
                }

                Navigation.clampScrollOffset(app);
            },
            else => {
                // Not on a comment line - do nothing
                return;
            },
        }
    }

    pub fn toggleCommentUnderCursorExpanded(app: *App) void {
        // Get line record from LineMap
        const record = app.state.line_map.getLineRecord(app.state.global_cursor_line) orelse return;

        switch (record.line_type) {
            .comment_line => |comment_info| {
                toggleCommentExpanded(app, comment_info.comment_idx);
                app.needs_render = true;
            },
            else => {
                // Not on a comment line - do nothing
                return;
            },
        }
    }

    pub fn clearAllComments(app: *App) !void {
        // Count comments above the current scroll position (these affect viewport)
        var comments_above_scroll: usize = 0;
        var comments_above_cursor: usize = 0;
        for (app.state.line_map.records) |*record| {
            if (record.line_type == .comment_line) {
                if (record.global_line < app.state.global_scroll_offset) {
                    comments_above_scroll += 1;
                }
                if (record.global_line < app.state.global_cursor_line) {
                    comments_above_cursor += 1;
                }
            }
        }

        app.state.comment_store.clearAll();

        // Rebuild LineMap since comment count changed
        app.state.line_map.deinit();
        app.state.line_map = try line_map.LineMap.build(app.allocator, app.state.files, &app.state.comment_store, hunk_view.convertHunkViewMode(app), hunk_view.shouldApplyHunkFiltering(app), &app.state.collapsed_folds);

        // Adjust scroll and cursor to account for removed comments above them
        const total_lines = app.getTotalGlobalLines();
        if (total_lines == 0) {
            app.state.global_scroll_offset = 0;
            app.state.global_cursor_line = 0;
            return;
        }

        // Reduce positions by the number of comments that were above them
        if (app.state.global_scroll_offset >= comments_above_scroll) {
            app.state.global_scroll_offset -= comments_above_scroll;
        } else {
            app.state.global_scroll_offset = 0;
        }

        if (app.state.global_cursor_line >= comments_above_cursor) {
            app.state.global_cursor_line -= comments_above_cursor;
        } else {
            app.state.global_cursor_line = 0;
        }

        // Clamp to valid range
        if (app.state.global_scroll_offset >= total_lines) {
            app.state.global_scroll_offset = total_lines - 1;
        }
        if (app.state.global_cursor_line >= total_lines) {
            app.state.global_cursor_line = total_lines - 1;
        }

        Navigation.clampScrollOffset(app);
    }

    // Check if a comment is expanded (collapsed by default)
    pub fn isCommentExpanded(app: *App, comment_idx: usize) bool {
        return app.state.expanded_comments.contains(comment_idx);
    }

    // Toggle comment expanded/collapsed state
    pub fn toggleCommentExpanded(app: *App, comment_idx: usize) void {
        if (app.state.expanded_comments.contains(comment_idx)) {
            _ = app.state.expanded_comments.remove(comment_idx);
        } else {
            app.state.expanded_comments.put(comment_idx, {}) catch {};
        }
    }

    fn findFileIndexByPath(app: *App, target_path: []const u8) ?usize {
        if (target_path.len == 0) return null;
        for (app.state.files, 0..) |file, idx| {
            if (std.mem.eql(u8, file.new_path, target_path) or std.mem.eql(u8, file.old_path, target_path)) {
                return idx;
            }
        }
        return null;
    }

    fn findCodeLine(app: *App, file_idx: usize, hunk_idx: usize, line_idx_in_hunk: usize) ?usize {
        for (app.state.line_map.records) |*record| {
            if (record.file_idx == file_idx and record.line_type == .code_line) {
                const code_info = record.line_type.code_line;
                if (code_info.hunk_idx == hunk_idx and code_info.line_idx_in_hunk == line_idx_in_hunk) {
                    return record.global_line;
                }
            }
        }
        return null;
    }
};
