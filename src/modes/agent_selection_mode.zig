const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const acp = @import("../acp/acp.zig");

/// Handle keyboard input when in agent selection mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    const agents = app.state.configured_agents orelse {
        // No agents, exit selection mode
        app.mode = .agent;
        app.needs_render = true;
        return;
    };

    const agent_count = agents.len;
    if (agent_count == 0) {
        app.mode = .agent;
        app.needs_render = true;
        return;
    }

    // Handle Ctrl+key combinations
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n' => {
                app.state.agent_selection_idx = (app.state.agent_selection_idx + 1) % agent_count;
                app.needs_render = true;
                return;
            },
            'p' => {
                app.state.agent_selection_idx = if (app.state.agent_selection_idx == 0)
                    agent_count - 1
                else
                    app.state.agent_selection_idx - 1;
                app.needs_render = true;
                return;
            },
            else => {},
        }
    }

    // Handle arrow keys
    if (key.codepoint == vaxis.Key.down) {
        app.state.agent_selection_idx = (app.state.agent_selection_idx + 1) % agent_count;
        app.needs_render = true;
        return;
    }
    if (key.codepoint == vaxis.Key.up) {
        app.state.agent_selection_idx = if (app.state.agent_selection_idx == 0)
            agent_count - 1
        else
            app.state.agent_selection_idx - 1;
        app.needs_render = true;
        return;
    }

    switch (key.codepoint) {
        'j' => {
            app.state.agent_selection_idx = (app.state.agent_selection_idx + 1) % agent_count;
            app.needs_render = true;
        },
        'k' => {
            app.state.agent_selection_idx = if (app.state.agent_selection_idx == 0)
                agent_count - 1
            else
                app.state.agent_selection_idx - 1;
            app.needs_render = true;
        },
        27, 'q' => { // ESC or q - cancel
            app.pending_agent_connect_idx = null;
            // If we were creating a new tab, close it since user cancelled
            if (app.state.pending_tab_for_selection) |tab_id| {
                if (app.tab_manager) |*tm| {
                    if (tm.findTabById(tab_id)) |idx| {
                        _ = tm.closeTab(idx);
                    }
                }
                app.state.pending_tab_for_selection = null;
            }
            app.mode = .agent;
            app.needs_render = true;
        },
        '\r' => { // Enter - select agent and connect
            app.queueSelectedAgentConnection();
        },
        else => {},
    }
}
