const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const FindCommand = @import("../app.zig").App.FindCommand;
const navigation = @import("../navigation.zig");
const Navigation = navigation.Navigation;
const folds = @import("../folds.zig");
const hunk_view = @import("../hunk_view.zig");
const CommentController = @import("../comments/controller.zig").CommentController;
const review_controller = @import("../pr/review_controller.zig");

/// Handle keyboard input when in normal mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    // Special handling when there are no files (empty menu)
    if (app.state.files.len == 0) {
        try handleEmptyMenu(app, key);
        return;
    }

    // Two-step delete confirmation for review threads (AD-8). Armed by `d` on a
    // thread; a second `d` fires the delete, any other key disarms and falls
    // through to be processed normally.
    if (review_controller.deleteConfirmArmed(&app.state.review)) |armed_id| {
        app.needs_render = true;
        if (key.codepoint == 'd' and !key.mods.ctrl and !key.mods.alt) {
            // Fire using the armed node id (re-resolved to a live index inside
            // fireThreadDelete) BEFORE disarming frees the id buffer.
            try fireThreadDelete(app, armed_id);
            review_controller.disarmDeleteConfirm(&app.state.review, app.allocator);
            return;
        }
        // Otherwise: disarm; fall through to handle this key normally.
        review_controller.disarmDeleteConfirm(&app.state.review, app.allocator);
    }

    // If waiting for second z for zz (center cursor) or fold commands (za/zc/zo/zM/zR)
    if (app.state.pending_z) {
        app.state.pending_z = false;
        // ESC cancels pending z
        if (key.codepoint == 27) { // ESC
            return;
        }
        switch (key.codepoint) {
            'z' => {
                // zz - center the viewport on cursor
                Navigation.centerViewportOnCursor(app);
                app.state.cursor_column = 0;
                app.updateCurrentFileAndTriggerHighlighting();
                return;
            },
            'a' => {
                // za - toggle fold at cursor
                try folds.toggleFoldUnderCursor(app);
                return;
            },
            'c' => {
                // zc - close fold at cursor
                try folds.closeFoldUnderCursor(app);
                return;
            },
            'o' => {
                // zo - open fold at cursor (hunk level)
                try folds.openFoldUnderCursor(app);
                return;
            },
            'C' => {
                // zC - close file fold (fold entire file from anywhere)
                try folds.closeFileFoldUnderCursor(app);
                return;
            },
            'O' => {
                // zO - open file fold (unfold entire file from anywhere)
                try folds.openFileFoldUnderCursor(app);
                return;
            },
            'M' => {
                // zM - close all folds
                try folds.closeAllFoldsAndRebuild(app);
                return;
            },
            'R' => {
                // zR - open all folds
                try folds.openAllFoldsAndRebuild(app);
                return;
            },
            else => {
                // Any other key cancels the pending z, but still processes the key below
            },
        }
    }

    // If waiting for second character after g (like gg for top, gY for yank to agent)
    if (app.state.pending_g) {
        app.state.pending_g = false;
        // ESC cancels pending g
        if (key.codepoint == 27) { // ESC
            return;
        }
        // gg - scroll to top
        if (key.codepoint == 'g') {
            Navigation.scrollToTop(app);
            app.state.cursor_column = 0;
            app.updateCurrentFileAndTriggerHighlighting();
            return;
        }
        // gY - yank all comments to agent input
        if (key.codepoint == 'Y') {
            try CommentController.yankCommentsToAgent(app);
            return;
        }
        // Any other key cancels the pending g, but still processes the key below
    }

    // If waiting for second character after [ (like [h for previous hunk)
    if (app.state.pending_bracket) {
        app.state.pending_bracket = false;
        // ESC cancels pending bracket
        if (key.codepoint == 27) { // ESC
            return;
        }
        // If h, jump to previous code change
        if (key.codepoint == 'h') {
            Navigation.jumpToPreviousCodeChange(app);
            app.state.cursor_column = 0;
            app.updateCurrentFileAndTriggerHighlighting();
            return;
        }
        // If c, jump to previous comment
        if (key.codepoint == 'c') {
            Navigation.jumpToPreviousComment(app);
            app.state.cursor_column = 0;
            app.updateCurrentFileAndTriggerHighlighting();
            return;
        }
        // If s, navigate to parent branch (visually down toward trunk)
        if (key.codepoint == 's') {
            try app.navigateStackToParent();
            return;
        }
        // Any other key cancels the pending bracket, but still processes the key below
    }

    // If waiting for second character after ] (like ]h for next hunk)
    if (app.state.pending_close_bracket) {
        app.state.pending_close_bracket = false;
        // ESC cancels pending close bracket
        if (key.codepoint == 27) { // ESC
            return;
        }
        // If h, jump to next code change
        if (key.codepoint == 'h') {
            Navigation.jumpToNextCodeChange(app);
            app.state.cursor_column = 0;
            app.updateCurrentFileAndTriggerHighlighting();
            return;
        }
        // If c, jump to next comment
        if (key.codepoint == 'c') {
            Navigation.jumpToNextComment(app);
            app.state.cursor_column = 0;
            app.updateCurrentFileAndTriggerHighlighting();
            return;
        }
        // If s, navigate to child branch (visually up toward tip)
        if (key.codepoint == 's') {
            try app.navigateStackToChild();
            return;
        }
        // Any other key cancels the pending close bracket, but still processes the key below
    }

    // If waiting for character for f/t/F/T, execute the find
    if (app.state.pending_find) |cmd| {
        app.state.pending_find = null;
        // ESC cancels pending find
        if (key.codepoint == 27) { // ESC
            return;
        }
        // Convert key to u8 if it's a printable character
        if (key.codepoint >= 0 and key.codepoint <= 127) {
            const target_char: u8 = @intCast(key.codepoint);
            app.executeFindInLine(cmd, target_char);
        }
        return;
    }

    // If waiting for second key in Ctrl+w chord (window navigation)
    if (app.state.pending_ctrl_w) {
        app.state.pending_ctrl_w = false;
        // ESC cancels pending Ctrl+w
        if (key.codepoint == 27) { // ESC
            return;
        }
        // Support both Ctrl+w l and Ctrl+w Ctrl+l (vim-style)
        // Handle both control character codepoints AND ctrl+letter combinations
        const effective_key: u21 = blk: {
            // First check control character codepoints
            // Note: Some terminals send 127 (DEL) for Ctrl+H instead of 8 (BS)
            if (key.codepoint == 8 or key.codepoint == 127) break :blk 'h'; // Ctrl+h / backspace
            if (key.codepoint == 12) break :blk 'l'; // Ctrl+l as control char
            if (key.codepoint == 23) break :blk 'w'; // Ctrl+w as control char
            // Also handle ctrl+letter (some terminals report this way)
            if (key.mods.ctrl) {
                if (key.codepoint == 'h') break :blk 'h';
                if (key.codepoint == 'l') break :blk 'l';
                if (key.codepoint == 'w') break :blk 'w';
            }
            break :blk key.codepoint;
        };

        // Check which panels are visible and their positions
        const agent_panel_visible = app.isAgentPanelVisible();
        const agent_on_left = app.getAgentPanelSide() == .left;

        switch (effective_key) {
            'l' => {
                // Focus right - check what's on the right (agent panel if on right)
                if (agent_panel_visible and !agent_on_left) {
                    app.mode = .agent;
                    app.needs_render = true;
                }
            },
            'h' => {
                // Focus left - check if agent panel is on the left
                if (agent_panel_visible and agent_on_left) {
                    app.mode = .agent;
                    app.needs_render = true;
                }
                // Otherwise no-op (diff is already focused)
            },
            'w' => {
                // Cycle focus - switch to agent panel if visible
                if (agent_panel_visible) {
                    app.mode = .agent;
                    app.needs_render = true;
                }
            },
            'o' => {
                // Toggle fullscreen (vim's "only window" concept)
                if (app.tab_manager) |*tm| {
                    tm.toggleFullScreen();
                    app.needs_render = true;
                }
            },
            else => {},
        }
        return;
    }

    // Handle Ctrl+key combinations first (before regular key handling)
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n' => {
                Navigation.navigateToNextFile(app);
                app.state.cursor_column = 0; // Reset column on file change
            },
            'p', 'P' => {
                // Ctrl-P: Open file palette (VSCode-style)
                // Ctrl-Shift-P: Try to open command palette (if terminal supports it)
                if (key.mods.shift or key.codepoint == 'P') {
                    try app.startCommandPaletteInCommandMode();
                } else {
                    try app.startCommandPalette();
                }
            },
            'd' => {
                Navigation.pageDown(app);
                app.state.cursor_column = 0; // Reset column on page navigation
                app.updateCurrentFileAndTriggerHighlighting();
            },
            'u' => {
                Navigation.pageUp(app);
                app.state.cursor_column = 0; // Reset column on page navigation
                app.updateCurrentFileAndTriggerHighlighting();
            },
            'f' => {
                // Ctrl-f: full page down (less/more style)
                Navigation.fullPageDown(app);
                app.state.cursor_column = 0; // Reset column on page navigation
                app.updateCurrentFileAndTriggerHighlighting();
            },
            'b' => {
                // Ctrl-b: full page up (less/more style)
                Navigation.fullPageUp(app);
                app.state.cursor_column = 0; // Reset column on page navigation
                app.updateCurrentFileAndTriggerHighlighting();
            },
            'e' => {
                // Ctrl+E: Toggle agent panel
                try app.toggleAgentPanel();
            },
            'g' => try app.openInEditor(),
            'w' => {
                // Start Ctrl+w chord for window navigation
                app.state.pending_ctrl_w = true;
            },
            else => {},
        }
        return;
    }

    // Handle digit keys for count prefix (1-9, not 0 to match vim)
    if (!key.mods.alt and !key.mods.shift) {
        if (key.codepoint >= '1' and key.codepoint <= '9') {
            const digit = @as(usize, @intCast(key.codepoint - '0'));
            if (app.state.count_prefix) |count| {
                app.state.count_prefix = count * 10 + digit;
            } else {
                app.state.count_prefix = digit;
            }
            return;
        }
        // Handle 0 - append to existing count, or go to start of line (not applicable here)
        if (key.codepoint == '0' and app.state.count_prefix != null) {
            app.state.count_prefix = app.state.count_prefix.? * 10;
            return;
        }
    }

    switch (key.codepoint) {
        'j' => {
            Navigation.moveCursorDown(app);
            app.state.cursor_column = 0; // Reset column on vertical movement
            app.updateCurrentFileAndTriggerHighlighting();
        },
        'k' => {
            Navigation.moveCursorUp(app);
            app.state.cursor_column = 0; // Reset column on vertical movement
            app.updateCurrentFileAndTriggerHighlighting();
        },
        'h' => {
            Navigation.navigateToPreviousFile(app);
            app.state.cursor_column = 0; // Reset column on file change
        },
        'l' => {
            Navigation.navigateToNextFile(app);
            app.state.cursor_column = 0; // Reset column on file change
        },
        'g' => {
            app.state.pending_g = true; // Wait for second character (gg, gY, etc.)
        },
        'G' => {
            Navigation.scrollToBottom(app);
            app.state.cursor_column = 0; // Reset column on jump
            app.updateCurrentFileAndTriggerHighlighting();
        },
        ' ' => {
            // Space: full page down (less/more style)
            Navigation.fullPageDown(app);
            app.state.cursor_column = 0; // Reset column on page navigation
            app.updateCurrentFileAndTriggerHighlighting();
        },
        'b' => {
            // b: full page up (less/more style)
            Navigation.fullPageUp(app);
            app.state.cursor_column = 0; // Reset column on page navigation
            app.updateCurrentFileAndTriggerHighlighting();
        },
        vaxis.Key.page_down, vaxis.Key.kp_page_down => {
            Navigation.fullPageDown(app);
            app.state.cursor_column = 0; // Reset column on page navigation
            app.updateCurrentFileAndTriggerHighlighting();
        },
        vaxis.Key.page_up, vaxis.Key.kp_page_up => {
            Navigation.fullPageUp(app);
            app.state.cursor_column = 0; // Reset column on page navigation
            app.updateCurrentFileAndTriggerHighlighting();
        },
        '\r' => {
            // Enter replies to a review thread under the cursor, else
            // creates/edits an inline comment.
            if (reviewThreadUnderCursor(app)) |thread_idx| {
                try CommentController.startReplyInput(app, thread_idx);
            } else {
                try CommentController.startCommentInput(app);
            }
        },
        's' => app.toggleViewMode(),
        '\t' => {
            // Tab cycles hunk view mode, Shift+Tab goes backwards
            if (key.mods.shift) {
                try hunk_view.cycleHunkViewModePrev(app);
            } else {
                try hunk_view.cycleHunkViewMode(app);
            }
        },
        'r' => {
            try app.refresh();
            app.startReviewRefetch();
        },
        'y' => try CommentController.yankCurrentCommentToClipboard(app),
        'Y' => try CommentController.yankAllCommentsToClipboard(app),
        'd' => {
            // On a review thread, `d` arms delete confirmation for the viewer's
            // own comment; otherwise it deletes the inline comment under cursor.
            if (reviewThreadUnderCursor(app)) |thread_idx| {
                armThreadDelete(app, thread_idx);
            } else {
                try CommentController.deleteCommentUnderCursor(app);
            }
        },
        'x' => {
            // Toggle resolve/unresolve on the review thread under the cursor.
            if (reviewThreadUnderCursor(app)) |thread_idx| {
                try startThreadResolveToggle(app, thread_idx);
            } else {
                app.state.count_prefix = null;
            }
        },
        'e' => {
            // Edit the viewer's own comment in the review thread under the cursor.
            if (reviewThreadUnderCursor(app)) |thread_idx| {
                try startThreadEdit(app, thread_idx);
            } else {
                app.state.count_prefix = null;
            }
        },
        'D' => try CommentController.clearAllComments(app),
        'M' => {
            Navigation.centerCursor(app);
            app.state.cursor_column = 0; // Reset column on center
            app.updateCurrentFileAndTriggerHighlighting();
        },
        '/' => app.startSearch(),
        ':' => try app.startCommandPaletteInCommandMode(), // Vim-style command mode
        'n' => {
            app.searchNext();
            app.state.cursor_column = 0; // Reset column on search jump
            app.updateCurrentFileAndTriggerHighlighting();
        },
        'N' => {
            app.searchPrevious();
            app.state.cursor_column = 0; // Reset column on search jump
            app.updateCurrentFileAndTriggerHighlighting();
        },
        'v', 'V' => app.startVisualMode(), // v or Shift+V to start visual mode
        'f' => app.state.pending_find = .f, // Wait for character to find forward
        't' => app.state.pending_find = .t, // Wait for character to move till forward
        'F' => app.state.pending_find = .F, // Wait for character to find backward
        'T' => app.state.pending_find = .T, // Wait for character to move till backward
        ';' => { // Repeat last find in same direction
            if (app.state.last_find) |last| {
                app.executeFindInLine(last.command, last.char);
            }
        },
        'z' => {
            // Wait for second z for zz (center cursor)
            app.state.pending_z = true;
        },
        '[' => app.state.pending_bracket = true, // Wait for second character (like [h)
        ']' => app.state.pending_close_bracket = true, // Wait for second character (like ]h)
        '{' => {
            Navigation.jumpToPreviousEmptyLine(app);
            app.state.cursor_column = 0; // Reset column on jump
            app.updateCurrentFileAndTriggerHighlighting();
        },
        '}' => {
            Navigation.jumpToNextEmptyLine(app);
            app.state.cursor_column = 0; // Reset column on jump
            app.updateCurrentFileAndTriggerHighlighting();
        },
        '?' => app.mode = .help, // Show help overlay
        'a' => try app.stageCurrentFile(), // Stage the current file (git add)
        'A' => try app.stageAllFiles(), // Stage all files (git add -A)
        'o' => try toggleExpandUnderCursor(app), // Toggle comment/thread expand/collapse
        'B' => app.toggleBlame(), // Toggle git blame in gutter
        'S' => try app.startGraphiteStack(), // Open graphite stack picker
        'C' => toggleCommentTarget(app), // Toggle new-comment target (GitHub draft ⇄ local)
        'R' => openReviewSubmit(app), // Submit-review dialog (verdict + body)
        'i' => openPrInfo(app), // Read-only PR info panel
        else => {
            // Reset count prefix on any other key
            app.state.count_prefix = null;
        },
    }
}

/// Open the submit-review dialog for the active session. No-op (with a hint) when
/// no session is active (guards the key against non-review diffs).
fn openReviewSubmit(app: *App) void {
    if (!review_controller.isActive(&app.state.review)) {
        app.showStatusMessage("no active PR review session");
        return;
    }
    app.openReviewSubmit();
}

/// Open the read-only PR info panel for the active session. No-op (with a hint)
/// when no session is active.
fn openPrInfo(app: *App) void {
    if (!review_controller.isActive(&app.state.review)) {
        app.showStatusMessage("no active PR review session");
        return;
    }
    app.openPrInfo();
}

/// Toggle where new comments are written for the active PR review session. No-op
/// (with a hint) when no session is active.
fn toggleCommentTarget(app: *App) void {
    if (!review_controller.isActive(&app.state.review)) {
        app.showStatusMessage("no active PR review session");
        return;
    }
    const target = review_controller.toggleCommentTarget(&app.state.review);
    app.showStatusMessage(switch (target) {
        .github => "new comments → GitHub draft review",
        .local => "new comments → local (skim)",
    });
    app.needs_render = true;
}

/// Route the `o` key to the right expand/collapse target based on the record
/// under the cursor: review threads toggle their own expansion, everything else
/// falls through to the inline-comment toggle.
fn toggleExpandUnderCursor(app: *App) !void {
    const record = app.state.line_map.getLineRecord(app.state.global_cursor_line) orelse return;
    switch (record.line_type) {
        .review_thread => |thread_info| {
            try review_controller.toggleThreadExpanded(&app.state.review, app.allocator, thread_info.thread_idx);
            app.needs_render = true;
        },
        else => CommentController.toggleCommentUnderCursorExpanded(app),
    }
}

/// The review-thread index under the cursor, or null when the cursor is not on a
/// review-thread record.
fn reviewThreadUnderCursor(app: *App) ?usize {
    const record = app.state.line_map.getLineRecord(app.state.global_cursor_line) orelse return null;
    return switch (record.line_type) {
        .review_thread => |thread_info| thread_info.thread_idx,
        else => null,
    };
}

/// Toggle resolve/unresolve on the review thread at `thread_idx` (FR-5).
fn startThreadResolveToggle(app: *App, thread_idx: usize) !void {
    const started = review_controller.startToggleResolve(&app.state.review, app.allocator, thread_idx) catch |err| {
        std.log.err("failed to toggle resolve: {any}", .{err});
        app.showStatusError("failed to update thread");
        return;
    };
    if (!started) {
        app.showStatusMessage("cannot resolve this thread right now");
        return;
    }
    app.rebuildReviewLineMap();
    app.showStatusMessage("updating thread…");
    app.needs_render = true;
}

/// Open the editor to edit the viewer's last comment in the thread (FR-5).
fn startThreadEdit(app: *App, thread_idx: usize) !void {
    if (thread_idx >= app.state.review.threads.items.len) return;
    const thread = &app.state.review.threads.items[thread_idx];
    const own_idx = review_controller.lastOwnCommentIdx(thread) orelse {
        app.showStatusMessage("no comment of yours to edit here");
        return;
    };
    try CommentController.startEditOwnInput(app, thread_idx, own_idx);
}

/// Arm delete confirmation for the viewer's own comment in the thread (FR-5).
/// Refuses (with a hint) when the viewer owns no comment in the thread.
fn armThreadDelete(app: *App, thread_idx: usize) void {
    if (thread_idx >= app.state.review.threads.items.len) return;
    const thread = &app.state.review.threads.items[thread_idx];
    if (review_controller.lastOwnCommentIdx(thread) == null) {
        app.showStatusMessage("no comment of yours to delete here");
        return;
    }
    review_controller.armDeleteConfirm(&app.state.review, app.allocator, thread.data.id);
    app.showStatusMessage("press d again to delete your comment");
    app.needs_render = true;
}

/// Fire the confirmed delete of the viewer's own comment (FR-5). The armed thread
/// is re-resolved by node id: its positional index may have shifted (or the thread
/// may have vanished) under a concurrent mutation between the two `d` keypresses.
fn fireThreadDelete(app: *App, thread_id: []const u8) !void {
    const thread_idx = review_controller.threadIdxById(&app.state.review, thread_id) orelse {
        app.showStatusMessage("thread no longer exists");
        return;
    };
    const started = review_controller.startDeleteOwn(&app.state.review, app.allocator, thread_idx) catch |err| {
        std.log.err("failed to start delete: {any}", .{err});
        app.showStatusError("failed to delete comment");
        return;
    };
    if (!started) {
        app.showStatusMessage("cannot delete: no comment of yours here");
        return;
    }
    app.rebuildReviewLineMap();
    app.showStatusMessage("deleting comment…");
    app.needs_render = true;
}

/// Handle keyboard input when in empty menu (no files loaded)
fn handleEmptyMenu(app: *App, key: vaxis.Key) !void {
    // Fixed menu: working, staged, main, branch, commit, graphite stack, refresh, quit
    // Graphite detection happens lazily when user selects it
    const menu_items_count: usize = 8;

    // If waiting for second key in Ctrl+w chord (window navigation)
    if (app.state.pending_ctrl_w) {
        app.state.pending_ctrl_w = false;
        // ESC cancels pending Ctrl+w
        if (key.codepoint == 27) { // ESC
            return;
        }
        // Support both Ctrl+w l and Ctrl+w Ctrl+l (vim-style)
        const effective_key: u21 = blk: {
            if (key.codepoint == 8 or key.codepoint == 127) break :blk 'h'; // Ctrl+h / backspace
            if (key.codepoint == 12) break :blk 'l'; // Ctrl+l as control char
            if (key.codepoint == 23) break :blk 'w'; // Ctrl+w as control char
            if (key.mods.ctrl) {
                if (key.codepoint == 'h') break :blk 'h';
                if (key.codepoint == 'l') break :blk 'l';
                if (key.codepoint == 'w') break :blk 'w';
            }
            break :blk key.codepoint;
        };

        const agent_panel_visible = app.isAgentPanelVisible();
        const agent_on_left = app.getAgentPanelSide() == .left;

        switch (effective_key) {
            'l' => {
                if (agent_panel_visible and !agent_on_left) {
                    app.mode = .agent;
                    app.needs_render = true;
                }
            },
            'h' => {
                if (agent_panel_visible and agent_on_left) {
                    app.mode = .agent;
                    app.needs_render = true;
                }
            },
            'w' => {
                if (agent_panel_visible) {
                    app.mode = .agent;
                    app.needs_render = true;
                }
            },
            'o' => {
                if (app.tab_manager) |*tm| {
                    tm.toggleFullScreen();
                    app.needs_render = true;
                }
            },
            else => {},
        }
        return;
    }

    // Handle Ctrl+key combinations
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n' => {
                app.state.empty_menu_selection = (app.state.empty_menu_selection + 1) % menu_items_count;
                return;
            },
            'p' => {
                // Ctrl-P: navigate up in empty menu (symmetric with Ctrl-N)
                app.state.empty_menu_selection = if (app.state.empty_menu_selection == 0) menu_items_count - 1 else app.state.empty_menu_selection - 1;
                return;
            },
            'e' => {
                // Ctrl+E: Toggle agent panel
                try app.toggleAgentPanel();
                return;
            },
            'w' => {
                // Start Ctrl+w chord for window navigation
                app.state.pending_ctrl_w = true;
                return;
            },
            else => {},
        }
    }

    // Handle arrow keys
    if (key.codepoint == vaxis.Key.down) {
        app.state.empty_menu_selection = (app.state.empty_menu_selection + 1) % menu_items_count;
        return;
    }
    if (key.codepoint == vaxis.Key.up) {
        app.state.empty_menu_selection = if (app.state.empty_menu_selection == 0) menu_items_count - 1 else app.state.empty_menu_selection - 1;
        return;
    }

    // Some terminals send Shift+; as ';' + shift instead of ':'.
    if (!key.mods.ctrl and !key.mods.alt and (key.codepoint == ':' or (key.codepoint == ';' and key.mods.shift))) {
        try app.startCommandPaletteInCommandMode();
        return;
    }

    // Handle regular keys
    switch (key.codepoint) {
        'j' => {
            app.state.empty_menu_selection = (app.state.empty_menu_selection + 1) % menu_items_count;
        },
        'k' => {
            app.state.empty_menu_selection = if (app.state.empty_menu_selection == 0) menu_items_count - 1 else app.state.empty_menu_selection - 1;
        },
        '\r' => { // Enter key
            // Menu order: working(0), staged(1), main(2), branch(3), commit(4), stack(5), refresh(6), quit(7)
            switch (app.state.empty_menu_selection) {
                0 => try app.switchDiffMode(.working),
                1 => try app.switchDiffMode(.staged),
                2 => try app.switchDiffMode(.main),
                3 => try app.startBranchSelection(),
                4 => try app.startCommitSelection(),
                5 => try app.startGraphiteStack(), // Lazy detection happens here
                6 => {
                    try app.refresh();
                    app.startReviewRefetch();
                },
                7 => app.should_quit = true,
                else => {},
            }
        },
        else => {},
    }
}
