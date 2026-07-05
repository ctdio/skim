//! Controller for review-comment operations. Owns all logic over the comment
//! sub-state on `App.state` (`comment_store`, `active_comment_input`,
//! `expanded_comments`): starting/saving the inline comment editor, yanking
//! comments to the clipboard or agent panel, deleting/clearing comments, and
//! the per-comment expand/collapse toggle. App keeps only mode dispatch and the
//! shared cross-cutting services these functions reach through.

const std = @import("std");

const App = @import("../app.zig").App;
const comment_editor = @import("editor.zig");
const clipboard = @import("../clipboard.zig");
const navigation = @import("../navigation.zig");
const hunk_view = @import("../hunk_view.zig");
const thread_anchor = @import("../pr/thread_anchor.zig");
const review_controller = @import("../pr/review_controller.zig");
const parser = @import("../git/parser.zig");

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
            .file_header, .hunk_header, .spacer, .review_thread => {
                // Can't comment on these line types (GitHub review threads are
                // read-only in this phase — no local comment editing on them).
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

        // New comments follow the active comment target (GitHub draft vs local);
        // editing an existing local comment is always a local edit.
        const target: comment_editor.CommentEditor.Target = if (existing_comment_idx == null and review_controller.githubTargetActive(&app.state.review))
            .github
        else
            .local;

        // Initialize input buffer
        var input = comment_editor.CommentEditor.State{
            .target_file_path = file_path,
            .target_hunk_idx = target_hunk_idx,
            .target_line_idx = target_line_idx,
            .target_end_hunk_idx = null, // Single-line comment
            .target_end_line_idx = null, // Single-line comment
            .editing_comment_idx = existing_comment_idx,
            .target = target,
            .vim = comment_editor.CommentEditor.VimEditor.State.initWithMode(.insert),
        };

        // If editing existing comment, load its text
        if (existing_comment_idx) |idx| {
            if (app.state.comment_store.getComment(idx)) |comment| {
                input.vim.setText(comment.text);
                input.vim.cursor_pos = input.vim.text_len; // Start cursor at end
            }
        } else if (target == .github) {
            // Draft safety (NFR-2): pre-fill a previously failed post so its text
            // is never lost.
            if (review_controller.takeFailedDraft(&app.state.review)) |text| {
                defer app.allocator.free(text);
                input.vim.setText(text);
                input.vim.cursor_pos = input.vim.text_len;
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

        const target: comment_editor.CommentEditor.Target = if (review_controller.githubTargetActive(&app.state.review)) .github else .local;

        // Initialize input buffer for range comment
        var input = comment_editor.CommentEditor.State{
            .target_file_path = file_path,
            .target_hunk_idx = start_code.hunk_idx,
            .target_line_idx = start_code.line_idx_in_hunk,
            .target_end_hunk_idx = if (is_single_line) null else end_code.hunk_idx,
            .target_end_line_idx = if (is_single_line) null else end_code.line_idx_in_hunk,
            .editing_comment_idx = null, // Always creating new comment from visual mode
            .target = target,
            .vim = comment_editor.CommentEditor.VimEditor.State.initWithMode(.insert),
        };

        if (target == .github) {
            if (review_controller.takeFailedDraft(&app.state.review)) |text| {
                defer app.allocator.free(text);
                input.vim.setText(text);
                input.vim.cursor_pos = input.vim.text_len;
            }
        }

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

    /// Open the inline editor to reply to the review thread at `thread_idx`
    /// (FR-5). Refuses when the thread is still an unposted placeholder or busy.
    /// Pre-fills a previously failed reply/edit body for draft safety (AD-8).
    pub fn startReplyInput(app: *App, thread_idx: usize) !void {
        if (thread_idx >= app.state.review.threads.items.len) return;
        const thread = app.state.review.threads.items[thread_idx];
        if (thread.posting) {
            app.showStatusMessage("thread is still posting");
            return;
        }
        if (review_controller.isThreadBusy(&app.state.review, thread_idx)) {
            app.showStatusMessage("thread is busy");
            return;
        }

        var input = comment_editor.CommentEditor.State{
            .target_file_path = thread.data.path,
            .target_hunk_idx = 0,
            .target_line_idx = 0,
            .target_end_hunk_idx = null,
            .target_end_line_idx = null,
            .editing_comment_idx = null,
            .target = .local,
            .edit_context = .{ .reply = .{ .thread_id = thread.data.id } },
            .vim = comment_editor.CommentEditor.VimEditor.State.initWithMode(.insert),
        };
        // Peek (do not consume) the stashed failed draft: the stash is only cleared
        // once the reply is actually sent (saveReply), so cancelling or emptying the
        // editor preserves the draft for retry (AD-8).
        if (review_controller.peekFailedDraft(&app.state.review)) |text| {
            input.vim.setText(text);
            input.vim.cursor_pos = input.vim.text_len;
        }

        app.state.active_comment_input = input;
        app.mode = .comment;
    }

    /// Open the inline editor to edit the viewer's comment at `comment_idx` in the
    /// thread at `thread_idx` (FR-5), pre-filled with its current body. Refuses on
    /// a placeholder / busy thread or an invalid comment index.
    pub fn startEditOwnInput(app: *App, thread_idx: usize, comment_idx: usize) !void {
        if (thread_idx >= app.state.review.threads.items.len) return;
        const thread = app.state.review.threads.items[thread_idx];
        if (thread.posting) {
            app.showStatusMessage("thread is still posting");
            return;
        }
        if (review_controller.isThreadBusy(&app.state.review, thread_idx)) {
            app.showStatusMessage("thread is busy");
            return;
        }
        if (comment_idx >= thread.data.comments.len) return;
        const comment = thread.data.comments[comment_idx];

        var input = comment_editor.CommentEditor.State{
            .target_file_path = thread.data.path,
            .target_hunk_idx = 0,
            .target_line_idx = 0,
            .target_end_hunk_idx = null,
            .target_end_line_idx = null,
            .editing_comment_idx = null,
            .target = .local,
            .edit_context = .{ .edit_own = .{ .thread_id = thread.data.id, .comment_id = comment.id } },
            .vim = comment_editor.CommentEditor.VimEditor.State.initWithMode(.insert),
        };
        input.vim.setText(comment.body);
        input.vim.cursor_pos = input.vim.text_len;

        app.state.active_comment_input = input;
        app.mode = .comment;
    }

    pub fn saveCurrentComment(app: *App) !bool {
        if (app.state.active_comment_input == null) return false;

        const input = app.state.active_comment_input.?;

        // Thread conversation editors (reply / edit-own) dispatch a thread
        // mutation instead of the diff-coordinate comment path (FR-5).
        switch (input.edit_context) {
            .none => {},
            .reply => |r| return saveReply(app, r.thread_id, input),
            .edit_own => |e| return saveEditOwn(app, e.comment_id, input),
        }

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

        // GitHub draft target: post an optimistic thread rather than storing a
        // local comment (AD-7). Editing existing comments stays local.
        if (input.target == .github) {
            return postDraftComment(app, .{ .input = input, .file = file, .line = line, .comment_text = comment_text });
        }

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
        try hunk_view.rebuildLineMap(app);

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
                try hunk_view.rebuildLineMap(app);

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
        try hunk_view.rebuildLineMap(app);

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

    /// Post the editor's contents as an optimistic GitHub draft thread (AD-6/7).
    /// Derives `(side, line)` from the diff line, handles single-line and range
    /// selections, then re-anchors + rebuilds so the placeholder renders. On a
    /// malformed line (no derivable coordinates) it refuses and keeps the editor.
    fn postDraftComment(app: *App, ctx: struct {
        input: comment_editor.CommentEditor.State,
        file: *const parser.FileDiff,
        line: *const parser.Line,
        comment_text: []const u8,
    }) !bool {
        const input = ctx.input;
        // `ctx.line` is the selection's first line (target_line_idx).
        const first_coords = thread_anchor.deriveGithubCoords(ctx.line.*) orelse {
            app.showStatusMessage("cannot post a draft on this line");
            return false;
        };

        var post_line = first_coords.line_no;
        var post_side = first_coords.side;
        var start_line: ?u32 = null;
        var start_side = first_coords.side;

        // Range selection: GitHub anchors the thread to the LAST line and carries
        // the first line as `startLine` (target_end_* holds the later line).
        if (input.target_end_hunk_idx) |end_hunk_idx| {
            if (input.target_end_line_idx) |end_line_idx| {
                if (end_hunk_idx >= ctx.file.hunks.len) {
                    app.showStatusMessage("Comment range hunk not found");
                    return false;
                }
                const end_hunk = &ctx.file.hunks[end_hunk_idx];
                if (end_line_idx >= end_hunk.lines.len) {
                    app.showStatusMessage("Comment range line not found");
                    return false;
                }
                const last_coords = thread_anchor.deriveGithubCoords(end_hunk.lines[end_line_idx]) orelse {
                    app.showStatusMessage("cannot post a draft on this range");
                    return false;
                };
                start_line = first_coords.line_no;
                start_side = first_coords.side;
                post_line = last_coords.line_no;
                post_side = last_coords.side;
            }
        }

        review_controller.startPostThread(&app.state.review, app.allocator, .{
            .path = input.target_file_path,
            .line = post_line,
            .side = post_side,
            .start_line = start_line,
            .start_side = start_side,
            .body = ctx.comment_text,
        }) catch |err| {
            std.log.err("failed to start draft post: {any}", .{err});
            app.showStatusMessage("failed to post draft comment");
            return false;
        };

        app.rebuildReviewLineMap();
        app.showStatusMessage("posting draft comment…");
        return true;
    }

    /// Dispatch an async reply to a thread from the editor's contents (FR-5).
    /// The thread is re-resolved by node id at save time (its positional index may
    /// have shifted under a concurrent mutation while the editor was open). Empty
    /// body closes the editor without sending. On a refused/failed start the editor
    /// stays open so the text is not lost.
    fn saveReply(app: *App, thread_id: []const u8, input: comment_editor.CommentEditor.State) !bool {
        const body = input.vim.text_buffer[0..input.vim.text_len];
        if (body.len == 0) return true;

        const thread_idx = review_controller.threadIdxById(&app.state.review, thread_id) orelse {
            app.showStatusMessage("thread no longer exists");
            return true;
        };

        const started = review_controller.startReply(&app.state.review, app.allocator, thread_idx, body) catch |err| {
            std.log.err("failed to start reply: {any}", .{err});
            app.showStatusMessage("failed to send reply");
            return false;
        };
        if (!started) {
            app.showStatusMessage("cannot reply to this thread right now");
            return false;
        }

        // The reply is now committed to the send path; the pre-filled failed draft
        // (if any) has served its purpose, so clear the stash (AD-8).
        if (review_controller.takeFailedDraft(&app.state.review)) |text| app.allocator.free(text);

        app.rebuildReviewLineMap();
        app.showStatusMessage("sending reply…");
        return true;
    }

    /// Dispatch an async edit of the viewer's comment from the editor's contents
    /// (FR-5). The comment is re-resolved by node id at save time (its thread /
    /// comment indices may have shifted under a concurrent mutation while the editor
    /// was open). An empty edit is refused (GitHub rejects empty bodies) and keeps
    /// the editor open.
    fn saveEditOwn(app: *App, comment_id: []const u8, input: comment_editor.CommentEditor.State) !bool {
        const body = input.vim.text_buffer[0..input.vim.text_len];
        if (body.len == 0) {
            app.showStatusMessage("edit cannot be empty");
            return false;
        }

        const loc = review_controller.findCommentLoc(&app.state.review, comment_id) orelse {
            app.showStatusMessage("comment no longer exists");
            return true;
        };

        const started = review_controller.startEditOwn(&app.state.review, app.allocator, loc.thread_idx, loc.comment_idx, body) catch |err| {
            std.log.err("failed to start edit: {any}", .{err});
            app.showStatusMessage("failed to save edit");
            return false;
        };
        if (!started) {
            app.showStatusMessage("cannot edit this comment right now");
            return false;
        }

        app.rebuildReviewLineMap();
        app.showStatusMessage("saving edit…");
        return true;
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
