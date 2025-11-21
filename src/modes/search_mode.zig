const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const navigation = @import("../navigation.zig");
const Navigation = navigation.Navigation;

/// Handle keyboard input when in search mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    var search_state = &app.state.search_state;

    // Handle special keys
    if (key.mods.ctrl) {
        return;
    }

    switch (key.codepoint) {
        27 => { // ESC - cancel search
            app.mode = .normal;
            search_state.reset();
            app.needs_render = true; // Force full redraw after closing search
        },
        '\r' => { // Enter - execute search
            if (search_state.query_len > 0) {
                try app.performSearch();
                app.jumpToFirstSearchMatch(); // Jump to first match (already centered from preview)
                app.mode = .normal;
                app.needs_render = true; // Force full redraw after closing search
            } else {
                app.mode = .normal;
                app.needs_render = true; // Force full redraw
            }
        },
        127, 8 => { // Backspace / Delete
            if (search_state.query_len > 0) {
                search_state.query_len -= 1;
                // Update search results as user types
                try app.performSearch();
                // Jump to first match in preview (vim-style incremental search)
                app.jumpToFirstSearchMatch();
            }
        },
        else => {
            // Regular character input
            if (key.codepoint >= 32 and key.codepoint < 127 and search_state.query_len < search_state.query_buffer.len) {
                search_state.query_buffer[search_state.query_len] = @intCast(key.codepoint);
                search_state.query_len += 1;
                // Update search results as user types (live highlighting)
                try app.performSearch();
                // Jump to first match in preview (vim-style incremental search)
                app.jumpToFirstSearchMatch();
            }
        },
    }
}
