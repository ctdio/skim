const vaxis = @import("vaxis");
const App = @import("../app.zig").App;

/// Get the number of available models from the ACP manager
fn getModelCount(app: *App) usize {
    if (app.acp_manager) |mgr| {
        return mgr.getAvailableModels().len;
    }
    return 0;
}

/// Handle keyboard input when in model selection mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    const model_count = getModelCount(app);
    if (model_count == 0) {
        // No models available, just exit
        app.mode = .agent;
        app.needs_render = true;
        return;
    }

    // Handle Ctrl+key combinations
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n' => {
                app.state.model_selection = (app.state.model_selection + 1) % model_count;
                return;
            },
            'p' => {
                app.state.model_selection = if (app.state.model_selection == 0) model_count - 1 else app.state.model_selection - 1;
                return;
            },
            'd' => {
                // Allow scrolling conversation history during model selection
                if (app.state.agent_state) |*agent_state| {
                    agent_state.follow_bottom = false;
                    agent_state.scrollDown(10);
                    app.needs_render = true;
                }
                return;
            },
            'u' => {
                // Allow scrolling conversation history during model selection
                if (app.state.agent_state) |*agent_state| {
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
        app.state.model_selection = (app.state.model_selection + 1) % model_count;
        return;
    }
    if (key.codepoint == vaxis.Key.up) {
        app.state.model_selection = if (app.state.model_selection == 0) model_count - 1 else app.state.model_selection - 1;
        return;
    }

    switch (key.codepoint) {
        'j' => {
            app.state.model_selection = (app.state.model_selection + 1) % model_count;
        },
        'k' => {
            app.state.model_selection = if (app.state.model_selection == 0) model_count - 1 else app.state.model_selection - 1;
        },
        27, 'q' => { // ESC or q - cancel
            app.mode = .agent;
            app.needs_render = true;
        },
        '\r' => { // Enter - select model
            if (app.acp_manager) |mgr| {
                const models = mgr.getAvailableModels();
                if (app.state.model_selection < models.len) {
                    const selected_model = models[app.state.model_selection];
                    mgr.setModel(selected_model.model_id) catch {};
                }
            }

            app.mode = .agent;
            app.needs_render = true;
        },
        else => {},
    }
}
