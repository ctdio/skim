const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;

// Total number of content rows in help popup (approximate)
// The actual content is ~53 rows, but we allow scrolling beyond to be safe
const HELP_CONTENT_ROWS = 60;

/// Handle keyboard input when in help mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    const max_visible = 30; // Max visible rows (popup_height - padding)
    const max_scroll = if (HELP_CONTENT_ROWS > max_visible) HELP_CONTENT_ROWS - max_visible else 0;

    switch (key.codepoint) {
        'j', 'J' => {
            // Scroll down one line
            if (app.state.help_scroll_offset < max_scroll) {
                app.state.help_scroll_offset += 1;
                app.needs_render = true;
            }
        },
        'k', 'K' => {
            // Scroll up one line
            if (app.state.help_scroll_offset > 0) {
                app.state.help_scroll_offset -= 1;
                app.needs_render = true;
            }
        },
        'd', 'D' => {
            // Page down (half page)
            const jump = max_visible / 2;
            app.state.help_scroll_offset = @min(app.state.help_scroll_offset + jump, max_scroll);
            app.needs_render = true;
        },
        'u', 'U' => {
            // Page up (half page)
            const jump = max_visible / 2;
            if (app.state.help_scroll_offset >= jump) {
                app.state.help_scroll_offset -= jump;
            } else {
                app.state.help_scroll_offset = 0;
            }
            app.needs_render = true;
        },
        'g' => {
            // Go to top
            app.state.help_scroll_offset = 0;
            app.needs_render = true;
        },
        'G' => {
            // Go to bottom
            app.state.help_scroll_offset = max_scroll;
            app.needs_render = true;
        },
        'q', '?', vaxis.Key.escape => {
            // Exit help mode and reset scroll
            app.state.help_scroll_offset = 0;
            app.mode = .normal;
            app.needs_render = true;
        },
        else => {},
    }

    // Also handle Ctrl+d and Ctrl+u
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'd' => {
                // Page down
                const jump = max_visible / 2;
                app.state.help_scroll_offset = @min(app.state.help_scroll_offset + jump, max_scroll);
                app.needs_render = true;
            },
            'u' => {
                // Page up
                const jump = max_visible / 2;
                if (app.state.help_scroll_offset >= jump) {
                    app.state.help_scroll_offset -= jump;
                } else {
                    app.state.help_scroll_offset = 0;
                }
                app.needs_render = true;
            },
            else => {},
        }
    }

    // Handle arrow keys
    if (key.matches(vaxis.Key.down, .{})) {
        if (app.state.help_scroll_offset < max_scroll) {
            app.state.help_scroll_offset += 1;
            app.needs_render = true;
        }
    } else if (key.matches(vaxis.Key.up, .{})) {
        if (app.state.help_scroll_offset > 0) {
            app.state.help_scroll_offset -= 1;
            app.needs_render = true;
        }
    }
}
