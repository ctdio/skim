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
                app.mode = .normal;
                app.needs_render = true; // Force full redraw after closing search
                // Jump to first match at or after cursor, or wrap to first match
                if (search_state.hasMatches()) {
                    const cursor = app.state.global_cursor_line;
                    var found = false;

                    // Find first match at or after cursor
                    for (search_state.matches.items, 0..) |match_line, idx| {
                        if (match_line >= cursor) {
                            search_state.current_match_idx = idx;
                            app.state.global_cursor_line = match_line;
                            found = true;
                            break;
                        }
                    }

                    // If no match after cursor, wrap to first match
                    if (!found and search_state.matches.items.len > 0) {
                        search_state.current_match_idx = 0;
                        app.state.global_cursor_line = search_state.matches.items[0];
                    }

                    Navigation.ensureCursorVisible(app, false); // no padding for search jumps
                }
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
            }
        },
        else => {
            // Regular character input
            if (key.codepoint >= 32 and key.codepoint < 127 and search_state.query_len < search_state.query_buffer.len) {
                search_state.query_buffer[search_state.query_len] = @intCast(key.codepoint);
                search_state.query_len += 1;
                // Update search results as user types (live highlighting)
                try app.performSearch();
            }
        },
    }
}
