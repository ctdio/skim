const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;

/// Handle keyboard input when in command palette mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    var palette_state = &app.state.command_palette_state;

    // Handle Ctrl+n and Ctrl+p for navigation
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n' => {
                palette_state.moveSelectionDown();
                return;
            },
            'p' => {
                palette_state.moveSelectionUp();
                return;
            },
            else => return,
        }
    }

    // Arrow keys for navigation
    if (key.codepoint == vaxis.Key.up) {
        palette_state.moveSelectionUp();
        return;
    }
    if (key.codepoint == vaxis.Key.down) {
        palette_state.moveSelectionDown();
        return;
    }

    switch (key.codepoint) {
        27 => { // ESC - cancel
            app.mode = .normal;
            palette_state.reset();
            app.needs_render = true; // Force full redraw after closing popup
        },
        '\r' => { // Enter - execute selected command
            // Save the command action before resetting state
            const maybe_action = if (palette_state.getSelectedCommand()) |cmd| cmd.action else null;

            // Exit command palette mode and reset state
            app.mode = .normal;
            palette_state.reset();
            app.needs_render = true; // Force full redraw after closing popup

            // Execute the command if there was one (may change mode again, e.g., to .help)
            if (maybe_action) |action| {
                try app.executeCommand(action);
            }
        },
        127, 8 => { // Backspace / Delete
            if (palette_state.query_len > 0) {
                palette_state.query_len -= 1;
                // Update filtered results
                try palette_state.filterCommands();
            }
        },
        else => {
            // Regular character input
            if (key.codepoint >= 32 and key.codepoint < 127 and palette_state.query_len < palette_state.query_buffer.len) {
                palette_state.query_buffer[palette_state.query_len] = @intCast(key.codepoint);
                palette_state.query_len += 1;
                // Update filtered results (live filtering)
                try palette_state.filterCommands();
            }
        },
    }
}
