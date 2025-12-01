const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;

/// Handle keyboard input when in review log mode (panel focused)
/// This mode provides full navigation of the review panel while keeping
/// the panel open. Exit with Ctrl+w h, Ctrl+w w, q, or ESC.
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    // Estimate visible rows (will be refined by actual panel size during render)
    const max_visible: usize = 30;

    // Calculate max scroll based on actual content
    const log_lines = app.state.review_log_line_count;
    const max_scroll = if (log_lines > max_visible) log_lines - max_visible else 0;

    // Handle pending Ctrl+w chord for window navigation
    if (app.state.pending_ctrl_w) {
        app.state.pending_ctrl_w = false;
        // ESC cancels pending Ctrl+w
        if (key.codepoint == 27) { // ESC
            return;
        }
        const PanelStyle = @TypeOf(app.state.review_panel_style);
        const is_dialog = app.state.review_panel_style == PanelStyle.dialog;

        // Support both Ctrl+w h and Ctrl+w Ctrl+h (vim-style)
        // Ctrl+h sends 8 (backspace), Ctrl+l sends 12 (form feed), Ctrl+w sends 23
        const effective_key: u21 = switch (key.codepoint) {
            8 => 'h', // Ctrl+h
            12 => 'l', // Ctrl+l
            23 => 'w', // Ctrl+w
            else => key.codepoint,
        };
        switch (effective_key) {
            'h' => {
                // Focus left (diff) - only allowed in sidebar mode (dialog is modal)
                if (!is_dialog) {
                    app.mode = .normal;
                    app.needs_render = true;
                }
            },
            'l' => {
                // Focus right - already focused on panel, no-op
            },
            'w' => {
                // Cycle focus - only allowed in sidebar mode (dialog is modal)
                if (!is_dialog) {
                    app.mode = .normal;
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
            'w' => {
                // Start Ctrl+w chord for window navigation
                app.state.pending_ctrl_w = true;
                return;
            },
            'd' => {
                // Page down (half page)
                const jump = max_visible / 2;
                app.state.review_log_scroll = @min(app.state.review_log_scroll + jump, max_scroll);
                // Enable tail-follow if we reached the bottom
                if (app.state.review_log_scroll >= max_scroll) {
                    app.state.review_log_tail_follow = true;
                }
                app.needs_render = true;
                return;
            },
            'u' => {
                // Page up (half page) - disable tail-follow
                app.state.review_log_tail_follow = false;
                const jump = max_visible / 2;
                if (app.state.review_log_scroll >= jump) {
                    app.state.review_log_scroll -= jump;
                } else {
                    app.state.review_log_scroll = 0;
                }
                app.needs_render = true;
                return;
            },
            else => {},
        }
    }

    // Handle regular keys
    switch (key.codepoint) {
        'j' => {
            // Scroll down one line
            if (app.state.review_log_scroll < max_scroll) {
                app.state.review_log_scroll += 1;
                // Enable tail-follow if we reached the bottom
                if (app.state.review_log_scroll >= max_scroll) {
                    app.state.review_log_tail_follow = true;
                }
                app.needs_render = true;
            }
        },
        'k' => {
            // Scroll up one line - disable tail-follow
            if (app.state.review_log_scroll > 0) {
                app.state.review_log_tail_follow = false;
                app.state.review_log_scroll -= 1;
                app.needs_render = true;
            }
        },
        'd' => {
            // Page down (half page) - also works without Ctrl
            const jump = max_visible / 2;
            app.state.review_log_scroll = @min(app.state.review_log_scroll + jump, max_scroll);
            // Enable tail-follow if we reached the bottom
            if (app.state.review_log_scroll >= max_scroll) {
                app.state.review_log_tail_follow = true;
            }
            app.needs_render = true;
        },
        'u' => {
            // Page up (half page) - also works without Ctrl - disable tail-follow
            app.state.review_log_tail_follow = false;
            const jump = max_visible / 2;
            if (app.state.review_log_scroll >= jump) {
                app.state.review_log_scroll -= jump;
            } else {
                app.state.review_log_scroll = 0;
            }
            app.needs_render = true;
        },
        'g' => {
            // Go to top - disable tail-follow
            app.state.review_log_tail_follow = false;
            app.state.review_log_scroll = 0;
            app.needs_render = true;
        },
        'G' => {
            // Go to bottom - enable tail-follow
            app.state.review_log_tail_follow = true;
            app.state.review_log_scroll = max_scroll;
            app.needs_render = true;
        },
        'q', vaxis.Key.escape => {
            // In dialog mode: close the dialog entirely (it's modal)
            // In sidebar mode: just unfocus, keep panel open
            const PanelStyle = @TypeOf(app.state.review_panel_style);
            if (app.state.review_panel_style == PanelStyle.dialog) {
                app.state.review_panel_open = false;
            }
            app.mode = .normal;
            app.needs_render = true;
        },
        'L' => {
            // Close panel and exit mode
            app.state.review_panel_open = false;
            app.mode = .normal;
            app.needs_render = true;
        },
        '\t' => {
            // Tab toggles panel style (sidebar <-> dialog)
            const PanelStyle = @TypeOf(app.state.review_panel_style);
            app.state.review_panel_style = if (app.state.review_panel_style == PanelStyle.sidebar)
                PanelStyle.dialog
            else
                PanelStyle.sidebar;
            app.needs_render = true;
        },
        'r' => {
            // Refresh log content
            try app.loadReviewLogContent();
            app.needs_render = true;
        },
        else => {},
    }

    // Handle arrow keys
    if (key.matches(vaxis.Key.down, .{})) {
        if (app.state.review_log_scroll < max_scroll) {
            app.state.review_log_scroll += 1;
            // Enable tail-follow if we reached the bottom
            if (app.state.review_log_scroll >= max_scroll) {
                app.state.review_log_tail_follow = true;
            }
            app.needs_render = true;
        }
    } else if (key.matches(vaxis.Key.up, .{})) {
        if (app.state.review_log_scroll > 0) {
            // Disable tail-follow when scrolling up
            app.state.review_log_tail_follow = false;
            app.state.review_log_scroll -= 1;
            app.needs_render = true;
        }
    }
}
