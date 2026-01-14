const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;

/// Get the number of filtered models (or all models if no filter)
fn getFilteredCount(app: *App) usize {
    return app.state.model_filtered_indices.items.len;
}

/// Handle keyboard input when in model selection mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    const filtered_count = getFilteredCount(app);

    // Handle Ctrl+key combinations
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n' => {
                if (filtered_count > 0) {
                    app.state.model_selection = (app.state.model_selection + 1) % filtered_count;
                }
                return;
            },
            'p' => {
                if (filtered_count > 0) {
                    app.state.model_selection = if (app.state.model_selection == 0) filtered_count - 1 else app.state.model_selection - 1;
                }
                return;
            },
            'd' => {
                // Allow scrolling conversation history during model selection
                if (app.getActiveAgentState()) |agent_state| {
                    agent_state.follow_bottom = false;
                    agent_state.scrollDown(10);
                    app.needs_render = true;
                }
                return;
            },
            'u' => {
                // Allow scrolling conversation history during model selection
                if (app.getActiveAgentState()) |agent_state| {
                    agent_state.follow_bottom = false;
                    agent_state.scrollUp(10);
                    app.needs_render = true;
                }
                return;
            },
            else => {},
        }
    }

    // Handle arrow keys
    if (key.codepoint == vaxis.Key.down) {
        if (filtered_count > 0) {
            app.state.model_selection = (app.state.model_selection + 1) % filtered_count;
        }
        return;
    }
    if (key.codepoint == vaxis.Key.up) {
        if (filtered_count > 0) {
            app.state.model_selection = if (app.state.model_selection == 0) filtered_count - 1 else app.state.model_selection - 1;
        }
        return;
    }

    switch (key.codepoint) {
        27 => { // ESC - clear search or cancel
            if (app.state.model_filter_len > 0) {
                // Clear search query
                app.state.model_filter_query = [_]u8{0} ** 256;
                app.state.model_filter_len = 0;
                app.state.model_selection = 0;
                app.updateModelFilter();
            } else {
                // Exit mode
                app.mode = .agent;
            }
            app.needs_render = true;
        },
        '\r' => { // Enter - select model
            if (app.getActiveAcpManager()) |mgr| {
                const models = mgr.getAvailableModels();
                // Get the actual model index from filtered indices
                if (app.state.model_selection < app.state.model_filtered_indices.items.len) {
                    const actual_idx = app.state.model_filtered_indices.items[app.state.model_selection];
                    if (actual_idx < models.len) {
                        const selected_model = models[actual_idx];
                        mgr.setModel(selected_model.model_id) catch {};
                    }
                }
            }

            app.mode = .agent;
            app.needs_render = true;
        },
        vaxis.Key.backspace => { // Backspace - delete character from search
            if (app.state.model_filter_len > 0) {
                app.state.model_filter_len -= 1;
                app.state.model_filter_query[app.state.model_filter_len] = 0;
                app.updateModelFilter();
                app.needs_render = true;
            }
        },
        else => {
            // Handle printable characters for search
            if (key.codepoint >= 32 and key.codepoint < 127) {
                if (app.state.model_filter_len < 255) {
                    app.state.model_filter_query[app.state.model_filter_len] = @intCast(key.codepoint);
                    app.state.model_filter_len += 1;
                    app.updateModelFilter();
                    app.needs_render = true;
                }
            }
        },
    }
}
