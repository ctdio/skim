const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;

/// Handle keyboard input when in commit selection mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    if (app.state.commit_list.items.len == 0) {
        // No commits - go back to normal mode
        app.mode = .normal;
        return;
    }

    const filtered_count = app.state.filtered_commits.items.len;

    // Handle Ctrl+key combinations
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n' => {
                if (filtered_count > 0) {
                    app.state.commit_selection = (app.state.commit_selection + 1) % filtered_count;
                    // Trigger lazy loading if near bottom
                    try checkLazyLoad(app);
                }
                return;
            },
            'p' => {
                if (filtered_count > 0) {
                    app.state.commit_selection = if (app.state.commit_selection == 0) filtered_count - 1 else app.state.commit_selection - 1;
                }
                return;
            },
            else => {},
        }
    }

    // Handle arrow keys
    if (key.codepoint == vaxis.Key.down) {
        if (filtered_count > 0) {
            app.state.commit_selection = (app.state.commit_selection + 1) % filtered_count;
            try checkLazyLoad(app);
        }
        return;
    }
    if (key.codepoint == vaxis.Key.up) {
        if (filtered_count > 0) {
            app.state.commit_selection = if (app.state.commit_selection == 0) filtered_count - 1 else app.state.commit_selection - 1;
        }
        return;
    }

    // Handle special keys
    switch (key.codepoint) {
        'j' => {
            if (filtered_count > 0) {
                app.state.commit_selection = (app.state.commit_selection + 1) % filtered_count;
                try checkLazyLoad(app);
            }
        },
        'k' => {
            if (filtered_count > 0) {
                app.state.commit_selection = if (app.state.commit_selection == 0) filtered_count - 1 else app.state.commit_selection - 1;
            }
        },
        27 => { // ESC key - clear search or go back
            if (app.state.commit_search_len > 0) {
                // Clear search
                app.state.commit_search_len = 0;
                app.state.commit_selection = 0;
                try app.filterCommits();
            } else {
                // Go back to normal mode
                app.mode = .normal;
            }
        },
        vaxis.Key.backspace => { // Backspace - delete last search char
            if (app.state.commit_search_len > 0) {
                app.state.commit_search_len -= 1;
                app.state.commit_selection = 0;
                try app.filterCommits();
            }
        },
        '\r' => { // Enter key - select commit and show diff mode submenu
            try app.selectCommitForDiff();
        },
        else => {
            // Handle text input for search
            if (key.codepoint >= 32 and key.codepoint <= 126) { // Printable ASCII
                if (app.state.commit_search_len < app.state.commit_search_query.len - 1) {
                    app.state.commit_search_query[app.state.commit_search_len] = @intCast(key.codepoint);
                    app.state.commit_search_len += 1;
                    app.state.commit_selection = 0;
                    try app.filterCommits();
                }
            }
        },
    }
}

/// Handle keyboard input when in commit diff mode submenu
pub fn handleDiffModeKey(app: *App, key: vaxis.Key) !void {
    // Handle Ctrl+key combinations
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n' => {
                app.state.commit_diff_mode_selection = (app.state.commit_diff_mode_selection + 1) % 2;
                return;
            },
            'p' => {
                app.state.commit_diff_mode_selection = if (app.state.commit_diff_mode_selection == 0) 1 else 0;
                return;
            },
            else => {},
        }
    }

    // Handle arrow keys
    if (key.codepoint == vaxis.Key.down) {
        app.state.commit_diff_mode_selection = (app.state.commit_diff_mode_selection + 1) % 2;
        return;
    }
    if (key.codepoint == vaxis.Key.up) {
        app.state.commit_diff_mode_selection = if (app.state.commit_diff_mode_selection == 0) 1 else 0;
        return;
    }

    switch (key.codepoint) {
        'j' => {
            app.state.commit_diff_mode_selection = (app.state.commit_diff_mode_selection + 1) % 2;
        },
        'k' => {
            app.state.commit_diff_mode_selection = if (app.state.commit_diff_mode_selection == 0) 1 else 0;
        },
        '1' => {
            app.state.commit_diff_mode_selection = 0;
            try app.applyCommitDiff();
        },
        '2' => {
            app.state.commit_diff_mode_selection = 1;
            try app.applyCommitDiff();
        },
        27 => { // ESC - go back to commit selection
            // Free the selected commit
            if (app.state.selected_commit_for_diff) |*commit| {
                commit.deinit(app.allocator);
                app.state.selected_commit_for_diff = null;
            }
            app.mode = .commit_selection;
        },
        '\r' => { // Enter - apply selected diff mode
            try app.applyCommitDiff();
        },
        else => {},
    }
}

/// Check if we need to lazy load more commits
fn checkLazyLoad(app: *App) !void {
    const filtered_count = app.state.filtered_commits.items.len;
    const loaded_count = app.state.commit_list.items.len;

    // If we're within 5 items of the bottom of the loaded list and not currently loading
    if (filtered_count > 0 and app.state.commit_selection >= filtered_count -| 5) {
        // Only load more if we might be near the end of loaded commits
        // Get the actual commit index at current selection
        if (app.state.commit_selection < filtered_count) {
            const actual_idx = app.state.filtered_commits.items[app.state.commit_selection];
            if (actual_idx >= loaded_count -| 5) {
                try app.loadMoreCommits();
            }
        }
    }
}
