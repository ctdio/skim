const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const navigation = @import("../navigation.zig");
const Navigation = navigation.Navigation;

/// Handle keyboard input when in visual mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    // Handle Ctrl+key combinations
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n' => Navigation.navigateToNextFile(app),
            'p' => Navigation.navigateToPreviousFile(app),
            'd' => Navigation.pageDown(app),
            'u' => Navigation.pageUp(app),
            else => {},
        }
        return;
    }

    // Handle digit keys for count prefix (1-9, matching vim behavior)
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
        // Handle 0 as part of multi-digit count (e.g., 10, 20)
        if (key.codepoint == '0' and app.state.count_prefix != null) {
            app.state.count_prefix = app.state.count_prefix.? * 10;
            return;
        }
    }

    switch (key.codepoint) {
        27 => { // ESC - exit visual mode
            app.mode = .normal;
            app.state.visual_anchor = null;
            app.state.count_prefix = null; // Clear count prefix when exiting
            app.needs_render = true; // Force full redraw after exiting visual mode
        },
        'v' => { // v again - exit visual mode (toggle)
            app.mode = .normal;
            app.state.visual_anchor = null;
            app.state.count_prefix = null; // Clear count prefix when exiting
            app.needs_render = true; // Force full redraw after exiting visual mode
        },
        '\r' => { // Enter - create comment for visual selection
            try app.startCommentInputForVisualSelection();
        },
        'j' => Navigation.moveCursorDown(app),
        'k' => Navigation.moveCursorUp(app),
        'h' => Navigation.navigateToPreviousFile(app),
        'l' => Navigation.navigateToNextFile(app),
        'g' => Navigation.scrollToTop(app),
        'G' => Navigation.scrollToBottom(app),
        'M' => Navigation.centerCursor(app),
        'y' => {
            try app.yankVisualSelection();
            // Exit visual mode after yanking
            app.mode = .normal;
            app.state.visual_anchor = null;
            app.state.count_prefix = null; // Clear count prefix when exiting
            app.needs_render = true; // Force full redraw after yanking
        },
        else => {},
    }
}
