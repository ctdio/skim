const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;

// Half-page jump for d/u/Ctrl-d/Ctrl-u. Scrolling has no upper bound here:
// `help.renderHelpPopup` clamps the offset to the popup's real height, since it
// is the only place that knows how many rows the overlay has.
const HALF_PAGE = 15;

/// Open the help overlay; closing it returns to `return_to`.
pub fn open(app: *App, return_to: App.Mode) void {
    app.state.help_scroll_offset = 0;
    app.state.help_return_mode = return_to;
    app.mode = .help;
    app.needs_render = true;
}

/// Close the help overlay, back to the mode that opened it.
pub fn close(app: *App) void {
    app.state.help_scroll_offset = 0;
    app.mode = app.state.help_return_mode;
    app.state.help_return_mode = .normal;
    app.needs_render = true;
}

/// Handle keyboard input when in help mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    const offset = &app.state.help_scroll_offset;

    switch (key.codepoint) {
        'j', 'J' => {
            offset.* +|= 1;
            app.needs_render = true;
        },
        'k', 'K' => {
            offset.* -|= 1;
            app.needs_render = true;
        },
        'd', 'D' => {
            offset.* +|= HALF_PAGE;
            app.needs_render = true;
        },
        'u', 'U' => {
            offset.* -|= HALF_PAGE;
            app.needs_render = true;
        },
        'g' => {
            offset.* = 0;
            app.needs_render = true;
        },
        'G' => {
            offset.* = std.math.maxInt(usize);
            app.needs_render = true;
        },
        'q', '?', vaxis.Key.escape => close(app),
        else => {},
    }

    // Also handle Ctrl+d and Ctrl+u
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'd' => {
                offset.* +|= HALF_PAGE;
                app.needs_render = true;
            },
            'u' => {
                offset.* -|= HALF_PAGE;
                app.needs_render = true;
            },
            else => {},
        }
    }

    // Handle arrow keys
    if (key.matches(vaxis.Key.down, .{})) {
        offset.* +|= 1;
        app.needs_render = true;
    } else if (key.matches(vaxis.Key.up, .{})) {
        offset.* -|= 1;
        app.needs_render = true;
    }
}
