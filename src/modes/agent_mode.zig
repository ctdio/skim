const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const agent = @import("../agent/agent.zig");
const state = @import("../agent/state.zig");

/// Handle keyboard input when in agent mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    const agent_state = &(app.state.agent_state orelse return);

    // Debug: log all key presses to help diagnose Shift+Tab issues
    std.log.debug("Agent key: codepoint=0x{X}, shift={}, ctrl={}, alt={}", .{
        key.codepoint,
        key.mods.shift,
        key.mods.ctrl,
        key.mods.alt,
    });

    // Check for pending permission prompt
    if (app.acp_manager) |mgr| {
        if (mgr.getPendingPermission()) |perm| {
            const num_options = perm.options.len;

            // Navigation: Ctrl+n / Down / j = next, Ctrl+p / Up / k = prev
            const is_down = (key.codepoint == 'n' and key.mods.ctrl) or
                key.codepoint == vaxis.Key.down or
                (key.codepoint == 'j' and !key.mods.ctrl);
            const is_up = (key.codepoint == 'p' and key.mods.ctrl) or
                key.codepoint == vaxis.Key.up or
                (key.codepoint == 'k' and !key.mods.ctrl);

            if (is_down and num_options > 0) {
                perm.selected_index = (perm.selected_index + 1) % num_options;
                app.needs_render = true;
                return;
            }
            if (is_up and num_options > 0) {
                perm.selected_index = if (perm.selected_index == 0) num_options - 1 else perm.selected_index - 1;
                app.needs_render = true;
                return;
            }

            // Enter: confirm selected option
            if (key.codepoint == vaxis.Key.enter or key.codepoint == 'y' or key.codepoint == 'Y') {
                mgr.respondToPermission(true) catch |err| {
                    std.log.err("Agent: Failed to respond to permission: {any}", .{err});
                };
                app.needs_render = true;
                return;
            }

            // Escape / n: cancel/reject
            if (key.codepoint == 27 or key.codepoint == 'n' or key.codepoint == 'N') {
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

    // Double-ESC to interrupt agent (only in normal vim mode)
    // ESC must be pressed twice within 5 seconds to trigger cancellation
    if (key.codepoint == 27 and agent_state.input.vim.vim_mode == .normal) {
        if (agent_state.recordEscPress()) {
            // Double-ESC detected - try to cancel the prompt
            if (app.acp_manager) |mgr| {
                if (mgr.cancelPrompt()) {
                    std.log.info("Agent: Interrupted agent via double-ESC", .{});
                    try agent_state.addMessage(.system, "Interrupted");
                    app.needs_render = true;
                    return;
                }
            }
            // No active prompt to cancel, just ignore
        }
        // First ESC or no cancellation - continue to other ESC handling
    }

    // Handle slash command menu navigation when visible
    if (agent_state.slash_menu_visible and agent_state.input.vim.vim_mode == .insert) {
        // Get filtered command count for bounds checking
        var indices: [32]usize = undefined;
        const filtered_count = agent_state.getFilteredCommandIndices(&indices);
        const visible_count = @min(filtered_count, state.MAX_SLASH_MENU_VISIBLE);

        // Ctrl+N - move down in menu
        if (key.mods.ctrl and key.codepoint == 'n') {
            agent_state.slashMenuDown(filtered_count, visible_count);
            app.needs_render = true;
            return;
        }

        // Ctrl+P - move up in menu
        if (key.mods.ctrl and key.codepoint == 'p') {
            agent_state.slashMenuUp(visible_count);
            app.needs_render = true;
            return;
        }

        // Enter - insert selected command and send immediately
        if (key.matches(vaxis.Key.enter, .{})) {
            if (agent_state.getSelectedCommand()) |cmd| {
                // Build full command text
                var cmd_text: std.ArrayList(u8) = .{};
                defer cmd_text.deinit(app.allocator);

                try cmd_text.append(app.allocator, '/');
                try cmd_text.appendSlice(app.allocator, cmd.name);

                const text = try cmd_text.toOwnedSlice(app.allocator);
                defer app.allocator.free(text);

                // Add to message history
                try agent_state.addMessage(.user, text);

                // Send to ACP agent
                if (app.acp_manager) |mgr| {
                    if (mgr.status == .disconnected) {
                        try agent_state.addMessage(.system, "Agent disconnected. Close and reopen panel to reconnect.");
                    } else if (mgr.status == .failed) {
                        try agent_state.addMessage(.system, "Agent connection failed. Close and reopen panel to retry.");
                    } else {
                        const prompt_copy = try app.allocator.dupe(u8, text);
                        defer app.allocator.free(prompt_copy);

                        mgr.sendPrompt(prompt_copy) catch |err| {
                            std.log.err("Agent: Failed to send prompt: {any}", .{err});
                            try agent_state.addMessage(.system, "Failed to send prompt to agent");
                        };
                    }
                } else {
                    try agent_state.addMessage(.system, "No agent configured. Close and reopen panel.");
                }

                // Clear input and hide menu
                agent_state.input.clear();
                agent_state.hideSlashMenu();
                app.needs_render = true;
            }
            return;
        }

        // Tab - insert selected command
        if (key.codepoint == vaxis.Key.tab and !key.mods.shift) {
            agent_state.insertSelectedCommand();
            app.needs_render = true;
            return;
        }

        // Escape - hide menu (but stay in insert mode)
        if (key.codepoint == 27) {
            agent_state.hideSlashMenu();
            app.needs_render = true;
            return;
        }
    }

    // Handle pending leader key in normal vim mode
    if (app.state.pending_leader and agent_state.input.vim.vim_mode == .normal) {
        app.state.pending_leader = false;
        // ESC cancels pending leader
        if (key.codepoint == 27) { // ESC
            return;
        }
        switch (key.codepoint) {
            'd' => {
                // Focus diff - close agent panel, return to normal mode
                agent_state.visible = false;
                app.mode = .normal;
                app.needs_render = true;
            },
            'a' => {
                // ,a in agent mode just toggles (closes) the panel
                agent_state.visible = false;
                app.mode = .normal;
                app.needs_render = true;
            },
            else => {},
        }
        return;
    }

    // ',' in normal vim mode - start leader key sequence
    if (agent_state.input.vim.vim_mode == .normal and key.codepoint == ',') {
        app.state.pending_leader = true;
        return;
    }

    // 'z' in normal vim mode - toggle full screen
    if (agent_state.input.vim.vim_mode == .normal and key.codepoint == 'z') {
        agent_state.toggleFullScreen();
        app.needs_render = true;
        return;
    }

    // 'V' (shift+v) in normal vim mode - toggle diff view mode (unified/side-by-side)
    // Note: lowercase 'v' is reserved for vim visual mode
    if (agent_state.input.vim.vim_mode == .normal and key.codepoint == 'V') {
        agent_state.toggleDiffViewMode();
        app.needs_render = true;
        return;
    }

    // 'q' in normal vim mode with empty input - close panel
    if (agent_state.input.vim.vim_mode == .normal and key.codepoint == 'q' and agent_state.input.isEmpty()) {
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

    // Cycle through session modes:
    // - Shift+Tab (requires kitty keyboard protocol - many terminals don't support this)
    // - Ctrl+Shift+M (works in most terminals)
    // - Alt+M (works in terminals that support meta key)
    // - 'm' in normal mode only
    const is_mode_cycle = key.matches(vaxis.Key.tab, .{ .shift = true }) or
        (key.codepoint == 0x09 and key.mods.shift) or
        (key.codepoint == 'm' and key.mods.ctrl and key.mods.shift) or
        (key.codepoint == 0x0D and key.mods.ctrl and key.mods.shift) or // Ctrl+Shift+M as capital M
        (key.codepoint == 'm' and key.mods.alt) or
        (key.codepoint == 'M' and key.mods.alt) or
        (agent_state.input.vim.vim_mode == .normal and key.codepoint == 'm' and !key.mods.alt and !key.mods.ctrl);

    if (is_mode_cycle) {
        std.log.info("Agent: Mode cycle key detected (codepoint=0x{X}, alt={})", .{ key.codepoint, key.mods.alt });
        if (app.acp_manager) |mgr| {
            if (mgr.cycleToNextMode()) |mode_name| {
                std.log.info("Agent: Cycled to mode '{s}'", .{mode_name});
                app.needs_render = true;
            } else {
                std.log.info("Agent: No modes available to cycle", .{});
            }
        } else {
            std.log.info("Agent: No ACP manager", .{});
        }
        return;
    }

    // During bracketed paste, Enter should insert newline, not send prompt
    if (app.in_bracketed_paste and agent_state.input.vim.vim_mode == .insert) {
        if (key.matches(vaxis.Key.enter, .{})) {
            agent.InputEditor.insertCharPublic(&agent_state.input, '\n');
            app.needs_render = true;
            return;
        }
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

    // Update slash menu visibility based on current input
    updateSlashMenuVisibility(app, agent_state);
}

/// Update slash menu visibility based on input content
fn updateSlashMenuVisibility(app: *App, agent_state: *agent.AgentState) void {
    if (agent_state.input.vim.vim_mode != .insert) {
        // Only show menu in insert mode
        agent_state.hideSlashMenu();
        return;
    }

    const text = agent_state.input.getText();
    const has_slash = text.len > 0 and text[0] == '/';
    const cmd_count = agent_state.available_commands.items.len;

    // Debug log to help diagnose slash menu issues
    if (has_slash) {
        std.log.info("Slash typed: cmd_count={d} visible={}", .{ cmd_count, agent_state.slash_menu_visible });
    }

    const should_show = agent_state.shouldShowSlashMenu();

    if (should_show and !agent_state.slash_menu_visible) {
        // Before showing menu, poll for any pending ACP updates to ensure we have latest commands
        // This fixes race condition where agent sends commands but we haven't polled yet
        // Poll multiple times with small delays to give transport time to receive notifications
        if (cmd_count <= 1) { // Only local commands present
            std.log.debug("Slash menu: only {d} commands, polling ACP for updates", .{cmd_count});

            // Try up to 5 times with 10ms delays to catch pending notifications
            var poll_attempts: u8 = 0;
            while (poll_attempts < 5 and agent_state.available_commands.items.len <= 1) : (poll_attempts += 1) {
                app.pollAcpUpdates();

                // Check if we got commands
                if (agent_state.available_commands.items.len > 1) {
                    std.log.info("Slash menu: got {d} commands after {d} poll attempts", .{
                        agent_state.available_commands.items.len,
                        poll_attempts + 1,
                    });
                    break;
                }

                // Small delay to let transport receive notifications
                if (poll_attempts < 4) {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                }
            }

            if (agent_state.available_commands.items.len <= 1) {
                std.log.warn("Slash menu: still only {d} commands after {d} attempts", .{
                    agent_state.available_commands.items.len,
                    poll_attempts,
                });
            }
        }

        // Show menu when "/" is typed at start
        std.log.info("Showing slash menu with {d} commands", .{agent_state.available_commands.items.len});
        agent_state.showSlashMenu();
    } else if (!should_show and agent_state.slash_menu_visible) {
        // Hide menu when "/" is deleted or input changes
        agent_state.hideSlashMenu();
    }

    // Keep selection in bounds when filter changes
    if (agent_state.slash_menu_visible) {
        var indices: [32]usize = undefined;
        const count = agent_state.getFilteredCommandIndices(&indices);
        if (count > 0 and agent_state.slash_menu_selection >= count) {
            agent_state.slash_menu_selection = count - 1;
        }
    }
}
