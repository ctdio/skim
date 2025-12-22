const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const agent = @import("../agent/agent.zig");

/// Handle keyboard input when in agent mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    const agent_state = &(app.state.agent_state orelse return);

    // Check for pending permission prompt
    if (app.acp_manager) |mgr| {
        if (mgr.hasPendingPermission()) {
            // Handle y/n keys for permission response
            if (key.codepoint == 'y' or key.codepoint == 'Y') {
                mgr.respondToPermission(true) catch |err| {
                    std.log.err("Agent: Failed to respond to permission: {any}", .{err});
                };
                app.needs_render = true;
                return;
            }
            if (key.codepoint == 'n' or key.codepoint == 'N') {
                mgr.cancelPermission() catch |err| {
                    std.log.err("Agent: Failed to cancel permission: {any}", .{err});
                };
                app.needs_render = true;
                return;
            }
            // Ignore other keys when permission prompt is active
            return;
        }
    }

    // Tab - toggle back to normal mode (hide panel)
    if (key.codepoint == '\t') {
        agent_state.visible = false;
        app.mode = .normal;
        app.needs_render = true;
        return;
    }

    // 'z' in normal vim mode - toggle full screen
    if (agent_state.input.vim_mode == .normal and key.codepoint == 'z') {
        agent_state.toggleFullScreen();
        app.needs_render = true;
        return;
    }

    // 'v' in normal vim mode - toggle diff view mode (unified/side-by-side)
    if (agent_state.input.vim_mode == .normal and key.codepoint == 'v') {
        agent_state.toggleDiffViewMode();
        app.needs_render = true;
        return;
    }

    // 'q' in normal vim mode with empty input - close panel
    if (agent_state.input.vim_mode == .normal and key.codepoint == 'q' and agent_state.input.isEmpty()) {
        agent_state.visible = false;
        app.mode = .normal;
        app.needs_render = true;
        return;
    }

    // Ctrl+L - clear message history
    if (key.mods.ctrl and key.codepoint == 'l') {
        agent_state.clearMessages();
        app.needs_render = true;
        return;
    }

    // Ctrl+K - cancel current prompt (TODO: implement when prompt sending works)
    if (key.mods.ctrl and key.codepoint == 'k') {
        // Will be implemented when ACP prompt cancellation is added
        return;
    }

    // Ctrl+D - page down (works in all modes)
    if (key.mods.ctrl and key.codepoint == 'd') {
        agent_state.scrollDown(10);
        app.needs_render = true;
        return;
    }

    // Ctrl+U - page up (works in all modes)
    if (key.mods.ctrl and key.codepoint == 'u') {
        agent_state.scrollUp(10);
        app.needs_render = true;
        return;
    }

    // Delegate to input editor
    const action = try agent.InputEditor.handleKey(&agent_state.input, key, app.allocator);

    if (action) |act| {
        switch (act) {
            .send => {
                const text = agent_state.input.getText();
                if (text.len > 0) {
                    // Add user message to history
                    try agent_state.addMessage(.user, text);

                    // Send to ACP agent (manager will queue if still connecting)
                    if (app.acp_manager) |mgr| {
                        if (mgr.status == .disconnected) {
                            try agent_state.addMessage(.system, "Agent disconnected. Close and reopen panel to reconnect.");
                        } else if (mgr.status == .failed) {
                            try agent_state.addMessage(.system, "Agent connection failed. Close and reopen panel to retry.");
                        } else {
                            // Send prompt - manager will queue if session not ready yet
                            const prompt_copy = try app.allocator.dupe(u8, text);
                            defer app.allocator.free(prompt_copy);

                            mgr.sendPrompt(prompt_copy) catch |err| {
                                std.log.err("Agent: Failed to send prompt: {any}", .{err});
                                try agent_state.addMessage(.system, "Failed to send prompt to agent");
                            };
                            // Queued status shown in input area, not as a message
                        }
                    } else {
                        try agent_state.addMessage(.system, "No agent configured. Close and reopen panel.");
                    }

                    // Clear input for next prompt
                    agent_state.input.clear();
                }
                app.needs_render = true;
            },
            .cancel => {
                // Cancel just clears input, doesn't close panel
                agent_state.input.clear();
                app.needs_render = true;
            },
        }
    } else {
        // Still editing
        app.needs_render = true;
    }
}
