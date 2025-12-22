const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const FindCommand = @import("../app.zig").App.FindCommand;
const navigation = @import("../navigation.zig");
const Navigation = navigation.Navigation;

/// Handle keyboard input when in normal mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    // Special handling when there are no files (empty menu)
    if (app.state.files.len == 0) {
        try handleEmptyMenu(app, key);
        return;
    }

    // If waiting for second z for zz (center cursor)
    if (app.state.pending_z) {
        app.state.pending_z = false;
        // ESC cancels pending z
        if (key.codepoint == 27) { // ESC
            return;
        }
        // If second z, center the viewport on cursor (like vim's zz)
        if (key.codepoint == 'z') {
            Navigation.centerViewportOnCursor(app);
            app.state.cursor_column = 0;
            app.updateCurrentFileAndTriggerHighlighting();
            return;
        }
        // Any other key cancels the pending z, but still processes the key below
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
            std.log.debug("Jumping to previous code change", .{});
            Navigation.jumpToPreviousCodeChange(app);
            app.state.cursor_column = 0;
            app.updateCurrentFileAndTriggerHighlighting();
            return;
        }
        // If c, jump to previous comment
        if (key.codepoint == 'c') {
            std.log.debug("Jumping to previous comment", .{});
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
            std.log.debug("Jumping to next code change", .{});
            Navigation.jumpToNextCodeChange(app);
            app.state.cursor_column = 0;
            app.updateCurrentFileAndTriggerHighlighting();
            return;
        }
        // If c, jump to next comment
        if (key.codepoint == 'c') {
            std.log.debug("Jumping to next comment", .{});
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
        // Ctrl+h sends 8 (backspace), Ctrl+l sends 12 (form feed), Ctrl+w sends 23
        const effective_key: u21 = switch (key.codepoint) {
            8 => 'h', // Ctrl+h
            12 => 'l', // Ctrl+l
            23 => 'w', // Ctrl+w
            else => key.codepoint,
        };
        switch (effective_key) {
            'l' => {
                // Focus right (review panel) - enter review_log mode
                if (app.state.review_panel_open) {
                    app.mode = .review_log;
                    app.needs_render = true;
                }
            },
            'h' => {
                // Focus left (diff) - already in normal mode, no-op
            },
            'w' => {
                // Cycle focus - enter review_log mode if panel is open
                if (app.state.review_panel_open) {
                    app.mode = .review_log;
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
            Navigation.scrollToTop(app);
            app.state.cursor_column = 0; // Reset column on jump
            app.updateCurrentFileAndTriggerHighlighting();
        },
        'G' => {
            Navigation.scrollToBottom(app);
            app.state.cursor_column = 0; // Reset column on jump
            app.updateCurrentFileAndTriggerHighlighting();
        },
        '\r' => try app.startCommentInput(), // Enter to create/edit comment
        's' => app.toggleViewMode(),
        '\t' => try app.toggleAgentPanel(), // Tab to toggle agent panel
        '<' => try app.cycleHunkViewModePrev(), // < for previous hunk view mode
        '>' => try app.cycleHunkViewMode(), // > for next hunk view mode
        'r' => try app.refresh(),
        'y' => try app.yankCurrentCommentToClipboard(),
        'Y' => try app.yankAllCommentsToClipboard(),
        'd' => try app.deleteCommentUnderCursor(),
        'D' => try app.clearAllComments(),
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
        ',' => { // Repeat last find in opposite direction
            if (app.state.last_find) |last| {
                const opposite_cmd = switch (last.command) {
                    .f => FindCommand.F,
                    .F => FindCommand.f,
                    .t => FindCommand.T,
                    .T => FindCommand.t,
                };
                app.executeFindInLine(opposite_cmd, last.char);
            }
        },
        'z' => app.state.pending_z = true, // Wait for second z for zz (center cursor)
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
        'R' => try app.startReview(), // Start AI review
        'L' => try app.toggleReviewPanel(), // Toggle review log side panel
        'a' => try app.stageCurrentFile(), // Stage the current file (git add)
        'A' => try app.stageAllFiles(), // Stage all files (git add -A)
        'o' => app.toggleCommentUnderCursorExpanded(), // Toggle comment expand/collapse
        'B' => app.toggleBlame(), // Toggle git blame in gutter
        'S' => try app.startGraphiteStack(), // Open graphite stack picker
        else => {
            // Reset count prefix on any other key
            app.state.count_prefix = null;
        },
    }
}

/// Handle keyboard input when in empty menu (no files loaded)
fn handleEmptyMenu(app: *App, key: vaxis.Key) !void {
    // Fixed menu: working, staged, main, branch, graphite stack, refresh, quit
    // Graphite detection happens lazily when user selects it
    const menu_items_count: usize = 7;

    // Handle Ctrl+key combinations
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n' => {
                app.state.empty_menu_selection = (app.state.empty_menu_selection + 1) % menu_items_count;
                return;
            },
            'p' => {
                app.state.empty_menu_selection = if (app.state.empty_menu_selection == 0) menu_items_count - 1 else app.state.empty_menu_selection - 1;
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

    // Handle regular keys
    switch (key.codepoint) {
        'j' => {
            app.state.empty_menu_selection = (app.state.empty_menu_selection + 1) % menu_items_count;
        },
        'k' => {
            app.state.empty_menu_selection = if (app.state.empty_menu_selection == 0) menu_items_count - 1 else app.state.empty_menu_selection - 1;
        },
        '\r' => { // Enter key
            // Menu order: working(0), staged(1), main(2), branch(3), stack(4), refresh(5), quit(6)
            switch (app.state.empty_menu_selection) {
                0 => try app.switchDiffMode(.working),
                1 => try app.switchDiffMode(.staged),
                2 => try app.switchDiffMode(.main),
                3 => try app.startBranchSelection(),
                4 => try app.startGraphiteStack(), // Lazy detection happens here
                5 => try app.refresh(),
                6 => app.should_quit = true,
                else => {},
            }
        },
        else => {},
    }
}
