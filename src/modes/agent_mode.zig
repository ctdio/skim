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

            // Allow scrolling during permission prompts
            // Ctrl+D - page down
            if (key.mods.ctrl and key.codepoint == 'd') {
                agent_state.follow_bottom = false;
                const scroll_amount = @max(1, agent_state.last_messages_viewport_height / 2);
                agent_state.scrollDown(scroll_amount);
                app.needs_render = true;
                return;
            }

            // Ctrl+U - page up
            if (key.mods.ctrl and key.codepoint == 'u') {
                agent_state.follow_bottom = false;
                const scroll_amount = @max(1, agent_state.last_messages_viewport_height / 2);
                agent_state.scrollUp(scroll_amount);
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
                // Check if this is a local command (handled by skim, not agent)
                if (state.AgentState.isLocalSlashCommand(cmd.name)) {
                    // Handle local commands client-side
                    try handleLocalCommand(app, agent_state, cmd.name);

                    // Clear input and hide menu
                    agent_state.input.clear();
                    agent_state.hideSlashMenu();
                    app.needs_render = true;
                    return;
                }

                // Build full command text for agent commands
                var cmd_text: std.ArrayList(u8) = .{};
                defer cmd_text.deinit(app.allocator);

                try cmd_text.append(app.allocator, '/');
                try cmd_text.appendSlice(app.allocator, cmd.name);

                const raw_text = try cmd_text.toOwnedSlice(app.allocator);
                defer app.allocator.free(raw_text);

                const text = std.mem.trim(u8, raw_text, &std.ascii.whitespace);

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


    // 'z' in normal vim mode - toggle full screen
    if (agent_state.input.vim.vim_mode == .normal and key.codepoint == 'z') {
        agent_state.toggleFullScreen();
        // When exiting fullscreen, return focus to diff
        if (!agent_state.full_screen) {
            app.mode = .normal;
        }
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

    // Vim navigation in normal mode: 'gg' to scroll to top, 'G' to scroll to bottom
    if (agent_state.input.vim.vim_mode == .normal) {
        // Handle 'gg' sequence
        if (app.state.pending_g) {
            app.state.pending_g = false;
            if (key.codepoint == 'g') {
                // gg - scroll to top, disable follow mode
                agent_state.follow_bottom = false;
                agent_state.scroll_offset = 0;
                app.needs_render = true;
                return;
            }
        } else if (key.codepoint == 'g' and !key.mods.ctrl and !key.mods.alt) {
            // First 'g' - wait for second
            app.state.pending_g = true;
            return;
        }

        // 'G' - scroll to bottom, enable follow mode
        if (key.codepoint == 'G') {
            agent_state.scrollToBottom(); // Sets follow_bottom = true
            app.needs_render = true;
            return;
        }
    }


    // Ctrl+W chord for window navigation (vim-style)
    if (key.mods.ctrl and key.codepoint == 'w') {
        app.state.pending_ctrl_w = true;
        return;
    }

    // Handle pending Ctrl+W chord
    if (app.state.pending_ctrl_w) {
        app.state.pending_ctrl_w = false;
        // ESC cancels pending Ctrl+w
        if (key.codepoint == 27) { // ESC
            return;
        }
        // Support both Ctrl+w h and Ctrl+w Ctrl+h (vim-style)
        // Ctrl+h sends 8 (backspace), Ctrl+l sends 12 (form feed), Ctrl+w sends 23
        const effective_key: u21 = switch (key.codepoint) {
            8 => 'h', // Ctrl+h
            12 => 'l', // Ctrl+l
            23 => 'w', // Ctrl+w
            else => key.codepoint,
        };

        // Check agent panel position to determine correct navigation
        const agent_on_left = agent_state.panel_side == .left;

        switch (effective_key) {
            'h' => {
                // If agent is on right, focus left (diff)
                // If agent is on left, already leftmost - no-op
                if (!agent_on_left) {
                    app.mode = .normal;
                    app.needs_render = true;
                }
                return;
            },
            'l' => {
                // If agent is on left, focus right (diff)
                // If agent is on right, already rightmost - no-op
                if (agent_on_left) {
                    app.mode = .normal;
                    app.needs_render = true;
                }
                return;
            },
            'w' => {
                // Cycle windows: always return to diff
                app.mode = .normal;
                app.needs_render = true;
                return;
            },
            else => {},
        }
        return;
    }

    // Ctrl+E - close agent panel and return to diff (toggle)
    if (key.mods.ctrl and key.codepoint == 'e') {
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
        agent_state.follow_bottom = false; // Disable follow mode
        const scroll_amount = @max(1, agent_state.last_messages_viewport_height / 2);
        agent_state.scrollDown(scroll_amount);
        app.needs_render = true;
        return;
    }

    // Ctrl+U - page up (works in all modes)
    if (key.mods.ctrl and key.codepoint == 'u') {
        agent_state.follow_bottom = false; // Disable follow mode
        const scroll_amount = @max(1, agent_state.last_messages_viewport_height / 2);
        agent_state.scrollUp(scroll_amount);
        app.needs_render = true;
        return;
    }

    // Cycle through session modes (only in normal vim mode):
    // - Tab (plain tab key in normal mode)
    // - Shift+Tab (requires kitty keyboard protocol - many terminals don't support this)
    // - Ctrl+Shift+M (works in most terminals)
    // - Alt+M (works in terminals that support meta key)
    if (agent_state.input.vim.vim_mode == .normal) {
        const is_mode_cycle = key.matches(vaxis.Key.tab, .{}) or
            key.matches(vaxis.Key.tab, .{ .shift = true }) or
            (key.codepoint == 0x09 and key.mods.shift) or
            (key.codepoint == 'm' and key.mods.ctrl and key.mods.shift) or
            (key.codepoint == 0x0D and key.mods.ctrl and key.mods.shift) or // Ctrl+Shift+M as capital M
            (key.codepoint == 'm' and key.mods.alt) or
            (key.codepoint == 'M' and key.mods.alt);

        if (is_mode_cycle) {
            if (app.acp_manager) |mgr| {
                if (mgr.cycleToNextMode()) |_| {
                    app.needs_render = true;
                }
            }
            return;
        }
    }

    // During bracketed paste, Enter should insert newline, not send prompt
    if (app.in_bracketed_paste and agent_state.input.vim.vim_mode == .insert) {
        if (key.matches(vaxis.Key.enter, .{})) {
            agent.InputEditor.insertCharPublic(&agent_state.input, '\n');
            app.needs_render = true;
            return;
        }
    }

    // Ctrl+S: Stash/unstash prompt
    if (key.mods.ctrl and key.codepoint == 's') {
        const text = agent_state.input.getText();
        const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);

        if (trimmed.len == 0) {
            // Empty input - unstash if stash exists
            if (agent_state.hasStash()) {
                agent_state.unstashPrompt();
                agent_state.clearStash();
                // Position cursor at end of restored text
                agent_state.input.vim.cursor_pos = agent_state.input.vim.text_len;
                // Switch to insert mode for immediate editing
                agent_state.input.vim.vim_mode = .insert;
            }
            // Else: no-op (silent, no message)
        } else {
            // Non-empty input - stash and clear
            agent_state.stashPrompt();
            agent_state.input.clear();
        }
        app.needs_render = true;
        return;
    }

    // Ctrl+T: Toggle plan expansion (expand/collapse todo list)
    if (key.mods.ctrl and key.codepoint == 't') {
        agent_state.plan_expanded = !agent_state.plan_expanded;
        app.needs_render = true;
        return;
    }

    // Delegate to input editor
    const action = try agent.InputEditor.handleKey(&agent_state.input, key, app.allocator);

    if (action) |act| {
        switch (act) {
            .send => {
                const raw_text = agent_state.input.getText();
                const text = std.mem.trim(u8, raw_text, &std.ascii.whitespace);
                const is_thinking = if (app.acp_manager) |mgr| mgr.status == .prompting else false;

                // Block prompt submission if session is not ready yet
                if (app.acp_manager) |mgr| {
                    if (mgr.status == .discovering or mgr.status == .connecting or mgr.status == .connected) {
                        // Session not ready - ignore submission
                        return;
                    }
                }

                // Handle staged message scenarios first
                if (is_thinking and agent_state.hasStagedPrompt()) {
                    if (text.len == 0) {
                        // Empty prompt + staged message = interrupt and send immediately
                        if (app.acp_manager) |mgr| {
                            if (mgr.cancelPrompt()) {
                                std.log.info("Agent: Interrupted via staged message immediate send", .{});
                                try agent_state.addMessage(.system, "Interrupted");
                            }
                        }

                        // Send the staged message
                        const staged = agent_state.getStagedPrompt();
                        try agent_state.addMessage(.user, staged);

                        if (app.acp_manager) |mgr| {
                            if (mgr.status == .disconnected) {
                                try agent_state.addMessage(.system, "Agent disconnected. Close and reopen panel to reconnect.");
                            } else if (mgr.status == .failed) {
                                try agent_state.addMessage(.system, "Agent connection failed. Close and reopen panel to retry.");
                            } else {
                                const prompt_copy = try app.allocator.dupe(u8, staged);
                                defer app.allocator.free(prompt_copy);

                                mgr.sendPrompt(prompt_copy) catch |err| {
                                    std.log.err("Agent: Failed to send prompt: {any}", .{err});
                                    try agent_state.addMessage(.system, "Failed to send prompt to agent");
                                };
                            }
                        }

                        agent_state.clearStagedPrompt();
                    } else {
                        // Non-empty prompt + staged message = append to staged message
                        const current_staged = agent_state.getStagedPrompt();
                        var combined_buf: [8192]u8 = undefined;
                        const combined = std.fmt.bufPrint(&combined_buf, "{s}\n{s}", .{ current_staged, text }) catch text;
                        agent_state.stagePrompt(combined);
                        agent_state.input.clear();
                    }
                } else if (text.len > 0) {
                    if (is_thinking) {
                        // Agent thinking, no staged message - stage this one
                        agent_state.stagePrompt(text);
                        agent_state.input.clear();
                    } else {
                        // Agent not thinking - send normally
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

                        // Auto-populate from stash if available
                        if (agent_state.hasStash()) {
                            agent_state.unstashPrompt();
                            agent_state.clearStash();
                            // Position cursor at end for immediate editing
                            agent_state.input.vim.cursor_pos = agent_state.input.vim.text_len;
                            agent_state.input.vim.vim_mode = .insert;
                        }
                    }
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

/// Handle local slash commands (executed by skim, not sent to agent)
fn handleLocalCommand(app: *App, agent_state: *agent.AgentState, command_name: []const u8) !void {
    if (std.mem.eql(u8, command_name, "model")) {
        // Switch to model selection mode
        app.mode = .model_selection;
        try agent_state.addMessage(.system, "Switching to model selection...");
        return;
    }

    // Unknown local command (shouldn't happen, but handle gracefully)
    try agent_state.addMessage(.system, "Unknown local command");
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
    _ = has_slash;

    const should_show = agent_state.shouldShowSlashMenu();

    if (should_show and !agent_state.slash_menu_visible) {
        // Before showing menu, poll once for any pending ACP updates
        // Commands will appear on next render if they arrive after this poll
        if (cmd_count <= 1) { // Only local commands present
            app.pollAcpUpdates();
        }

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
