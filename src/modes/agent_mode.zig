const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const agent = @import("../agent/agent.zig");
const state = @import("../agent/state.zig");
const protocol = @import("../acp/protocol.zig");
const sessions = @import("../acp/sessions.zig");
const AcpManager = @import("../acp/manager.zig").AcpManager;
const command_palette = @import("../agent/command_palette.zig");

/// Handle keyboard input when in agent mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    const agent_state = app.getActiveAgentState() orelse return;

    // Handle help overlay when visible
    if (agent_state.help_visible) {
        if (agent.agent_help.handleKey(agent_state, key)) {
            app.needs_render = true;
            return;
        }
    }

    // Check for pending permission prompt
    if (app.getActiveAcpManager()) |mgr| {
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

    // Handle history mode key events
    if (agent_state.isInHistoryMode()) {
        // Check visual mode first (within history mode)
        if (agent_state.isInHistoryVisualMode()) {
            // Visual mode keybindings
            if (key.codepoint == 27 or key.codepoint == 'v') { // ESC or v
                // Exit visual mode, stay in history mode
                agent_state.exitHistoryVisualMode();
                app.needs_render = true;
                return;
            }
            // Ctrl+D - page down while extending selection
            if (key.mods.ctrl and key.codepoint == 'd') {
                agent_state.historyPageDown();
                agent_state.history.pending_g = false;
                app.needs_render = true;
                return;
            }
            // Ctrl+U - page up while extending selection
            if (key.mods.ctrl and key.codepoint == 'u') {
                agent_state.historyPageUp();
                agent_state.history.pending_g = false;
                app.needs_render = true;
                return;
            }
            if (key.codepoint == 'j') {
                // Extend selection down
                agent_state.historyCursorDown();
                agent_state.history.pending_g = false;
                app.needs_render = true;
                return;
            }
            if (key.codepoint == 'k') {
                // Extend selection up
                agent_state.historyCursorUp();
                agent_state.history.pending_g = false;
                app.needs_render = true;
                return;
            }
            if (key.codepoint == 'y') {
                // Yank selection to clipboard
                agent_state.yankVisualSelection(app.allocator) catch |err| {
                    std.log.err("Failed to yank visual selection: {any}", .{err});
                };
                app.needs_render = true;
                return;
            }
            // o - toggle expand/collapse of user message under cursor (also works in visual mode)
            if (key.codepoint == 'o') {
                if (agent_state.toggleUserMessageUnderCursor()) {
                    agent_state.history.pending_g = false;
                    app.needs_render = true;
                }
                return;
            }
            // Consume other keys in visual mode
            return;
        }

        // Regular history mode keybindings
        if (key.codepoint == 'i') {
            // 'i' exits history mode and enters insert mode
            agent_state.exitHistoryMode();
            agent_state.input.vim.vim_mode = .insert;
            app.needs_render = true;
            return;
        }
        if (key.codepoint == 27 or key.codepoint == 'q') { // ESC or q
            // ESC/q exits history mode to normal mode
            agent_state.exitHistoryMode();
            agent_state.input.vim.vim_mode = .normal;
            agent_state.history.pending_g = false;
            app.needs_render = true;
            return;
        }

        // v - enter visual mode
        if (key.codepoint == 'v') {
            agent_state.enterHistoryVisualMode();
            app.needs_render = true;
            return;
        }

        // Y - yank entire current message
        if (key.codepoint == 'Y') {
            agent_state.yankCurrentMessage(app.allocator) catch |err| {
                std.log.err("Failed to yank message: {any}", .{err});
            };
            app.needs_render = true;
            return;
        }

        // y - yank user message at cursor (like comment yanking in diff mode)
        // yy - yank current line
        if (key.codepoint == 'y') {
            if (agent_state.history.pending_y) {
                // Second 'y' - yank current line
                agent_state.yankCurrentLine(app.allocator) catch |err| {
                    std.log.err("Failed to yank current line: {any}", .{err});
                };
                agent_state.history.pending_y = false;
                agent_state.history.pending_g = false;
                app.needs_render = true;
                return;
            } else {
                // First 'y' - try to yank user message at cursor
                const yanked = agent_state.yankUserMessageAtCursor(app.allocator) catch |err| {
                    std.log.err("Failed to yank user message: {any}", .{err});
                    return;
                };
                if (yanked) {
                    // Successfully yanked user message
                    agent_state.history.pending_y = false;
                    agent_state.history.pending_g = false;
                    app.needs_render = true;
                    return;
                } else {
                    // Not on a user message - wait for second 'y' for yy
                    agent_state.history.pending_y = true;
                    agent_state.history.pending_g = false;
                    return;
                }
            }
        }

        // Line navigation: j/k move cursor down/up
        if (key.codepoint == 'j') {
            agent_state.historyCursorDown();
            agent_state.history.pending_g = false;
            agent_state.history.pending_y = false;
            app.needs_render = true;
            return;
        }
        if (key.codepoint == 'k') {
            agent_state.historyCursorUp();
            agent_state.history.pending_g = false;
            agent_state.history.pending_y = false;
            app.needs_render = true;
            return;
        }

        // Message navigation: h/l jump between messages
        if (key.codepoint == 'h') {
            agent_state.historyJumpToPrevMessage();
            agent_state.history.pending_g = false;
            agent_state.history.pending_y = false;
            app.needs_render = true;
            return;
        }
        if (key.codepoint == 'l') {
            agent_state.historyJumpToNextMessage();
            agent_state.history.pending_g = false;
            agent_state.history.pending_y = false;
            app.needs_render = true;
            return;
        }

        // Page navigation: Ctrl-d/u
        if (key.mods.ctrl and key.codepoint == 'd') {
            agent_state.historyPageDown();
            agent_state.history.pending_g = false;
            agent_state.history.pending_y = false;
            app.needs_render = true;
            return;
        }
        if (key.mods.ctrl and key.codepoint == 'u') {
            agent_state.historyPageUp();
            agent_state.history.pending_g = false;
            agent_state.history.pending_y = false;
            app.needs_render = true;
            return;
        }

        // Jump to top/bottom: gg / G
        if (key.codepoint == 'g') {
            if (agent_state.history.pending_g) {
                // Second 'g' - jump to top
                agent_state.historyJumpToTop();
                agent_state.history.pending_g = false;
                agent_state.history.pending_y = false;
                app.needs_render = true;
                return;
            } else {
                // First 'g' - set pending
                agent_state.history.pending_g = true;
                agent_state.history.pending_y = false;
                return;
            }
        }
        if (key.codepoint == 'G') {
            agent_state.historyJumpToBottom();
            agent_state.history.pending_g = false;
            agent_state.history.pending_y = false;
            app.needs_render = true;
            return;
        }

        // M - move cursor to middle of viewport
        if (key.codepoint == 'M') {
            agent_state.historyCenterCursor();
            agent_state.history.pending_g = false;
            agent_state.history.pending_y = false;
            app.needs_render = true;
            return;
        }

        // o - toggle expand/collapse of user message under cursor
        if (key.codepoint == 'o') {
            if (agent_state.toggleUserMessageUnderCursor()) {
                agent_state.history.pending_g = false;
                agent_state.history.pending_y = false;
                app.needs_render = true;
            }
            return;
        }

        // Space prefix commands in history mode (Space+f for follow/resume)
        if (app.state.pending_space) {
            app.state.pending_space = false;
            if (key.codepoint == 'f') {
                // Space+f - scroll to bottom, enable follow mode, exit history mode
                agent_state.exitHistoryMode();
                agent_state.scrollToBottom();
                app.needs_render = true;
                return;
            }
            // Unknown space-sequence in history mode, ignore
            agent_state.history.pending_g = false;
            agent_state.history.pending_y = false;
            return;
        } else if (key.codepoint == ' ' and !key.mods.ctrl and !key.mods.alt) {
            // First Space - wait for second key
            app.state.pending_space = true;
            agent_state.history.pending_g = false;
            agent_state.history.pending_y = false;
            return;
        }

        // Ctrl+W chord for window navigation in history mode
        if (key.mods.ctrl and key.codepoint == 'w') {
            app.state.pending_ctrl_w = true;
            agent_state.history.pending_g = false;
            agent_state.history.pending_y = false;
            return;
        }

        // Handle pending Ctrl+W chord in history mode
        if (app.state.pending_ctrl_w) {
            app.state.pending_ctrl_w = false;
            agent_state.history.pending_g = false;
            agent_state.history.pending_y = false;
            // ESC cancels pending Ctrl+w
            if (key.codepoint == 27) {
                return;
            }
            if (key.codepoint == 'o') {
                // Toggle fullscreen
                if (app.tab_manager) |*tm| {
                    tm.toggleFullScreen();
                    app.needs_render = true;
                }
                return;
            }
            if (key.codepoint == 'h' or key.codepoint == 'l' or key.codepoint == 'w') {
                // Window navigation - exit history mode and switch to diff
                agent_state.exitHistoryMode();
                app.mode = .normal;
                app.needs_render = true;
                return;
            }
            // Unknown Ctrl+w sequence - ignore
            return;
        }

        // Any other key clears pending states
        agent_state.history.pending_g = false;
        agent_state.history.pending_y = false;

        // Consume other keys in history mode (don't pass to input editor)
        return;
    }

    // Double-ESC to interrupt agent (only in normal vim mode)
    // ESC must be pressed twice within 5 seconds to trigger cancellation
    if (key.codepoint == 27 and agent_state.input.vim.vim_mode == .normal) {
        if (agent_state.recordEscPress()) {
            // Double-ESC detected - try to cancel the prompt
            if (app.getActiveAcpManager()) |mgr| {
                if (mgr.cancelPrompt()) {
                    std.log.info("Agent: Interrupted agent via double-ESC", .{});
                    try agent_state.addMessage(.system, "Interrupted");
                    app.needs_render = true;
                    return;
                }
            }
            // No active prompt to cancel, just ignore
        } else {
            // First ESC - re-render to show "press esc again" hint
            app.needs_render = true;
        }
        // First ESC or no cancellation - continue to other ESC handling
    }

    // Handle slash command menu navigation when visible
    if (agent_state.slash_menu.visible and agent_state.input.vim.vim_mode == .insert) {
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
                // Extract any arguments after the command name from the input
                const input_text = agent_state.input.getText();
                const args = extractCommandArgs(input_text, cmd.name);

                // Check if this is a local command (handled by skim, not agent)
                if (state.AgentState.isLocalSlashCommand(cmd.name)) {
                    // Handle local commands client-side with arguments
                    try handleLocalCommand(app, agent_state, cmd.name, args);

                    // Clear input and hide menu
                    agent_state.input.clear();
                    agent_state.hideSlashMenu();
                    app.needs_render = true;
                    return;
                }

                // Build full command text for agent commands, including any arguments
                var cmd_text: std.ArrayList(u8) = .{};
                defer cmd_text.deinit(app.allocator);

                try cmd_text.append(app.allocator, '/');
                try cmd_text.appendSlice(app.allocator, cmd.name);

                // Append arguments if present
                if (args.len > 0) {
                    try cmd_text.append(app.allocator, ' ');
                    try cmd_text.appendSlice(app.allocator, args);
                }

                const raw_text = try cmd_text.toOwnedSlice(app.allocator);
                defer app.allocator.free(raw_text);

                const text = std.mem.trim(u8, raw_text, &std.ascii.whitespace);

                // Add to message history
                try agent_state.addMessage(.user, text);

                // Auto-name the tab from the first user prompt
                app.autoNameActiveTab(text);

                // Send to ACP agent
                if (app.getActiveAcpManager()) |mgr| {
                    if (mgr.status == .disconnected) {
                        try agent_state.addMessage(.system, "Agent disconnected. Close and reopen panel to reconnect.");
                    } else if (mgr.status == .failed) {
                        try agent_state.addMessage(.system, "Agent connection failed. Close and reopen panel to retry.");
                    } else {
                        // Parse prompt for @file references and send as content blocks
                        try sendPromptWithFiles(app, mgr, text);
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

    // Handle file picker menu navigation when visible
    if (agent_state.file_picker.visible and agent_state.input.vim.vim_mode == .insert) {
        // Ctrl+N - move down in file menu
        if (key.mods.ctrl and key.codepoint == 'n') {
            agent_state.file_picker.menuDown();
            app.needs_render = true;
            return;
        }

        // Ctrl+P - move up in file menu
        if (key.mods.ctrl and key.codepoint == 'p') {
            agent_state.file_picker.menuUp();
            app.needs_render = true;
            return;
        }

        // Enter or Tab - insert selected file as ACP resource
        if (key.matches(vaxis.Key.enter, .{}) or key.codepoint == vaxis.Key.tab) {
            if (agent_state.file_picker.getSelectedFile()) |selected_path| {
                try insertFileAsResource(app, agent_state, selected_path);
            }
            agent_state.file_picker.hide();
            app.needs_render = true;
            return;
        }

        // Escape - hide file menu (but stay in insert mode)
        if (key.codepoint == 27) {
            agent_state.file_picker.hide();
            app.needs_render = true;
            return;
        }
    }

    // Handle command palette when visible
    if (agent_state.cmd_palette.visible) {
        if (agent_state.cmd_palette.mode == .rename_input) {
            // Rename input mode
            switch (key.codepoint) {
                27 => { // ESC - cancel rename
                    agent_state.cmd_palette.close();
                    app.needs_render = true;
                    return;
                },
                vaxis.Key.enter => {
                    // Confirm rename
                    const new_name = agent_state.cmd_palette.getRenameText();
                    if (new_name.len > 0) {
                        if (app.tab_manager) |*tm| {
                            if (tm.activeTab()) |tab| {
                                tab.setName(new_name) catch {};
                                tab.auto_named = false;
                            }
                        }
                    }
                    agent_state.cmd_palette.close();
                    app.needs_render = true;
                    return;
                },
                127, 8 => { // Backspace
                    agent_state.cmd_palette.deleteRenameChar();
                    app.needs_render = true;
                    return;
                },
                else => {
                    if (key.codepoint >= 32 and key.codepoint < 127) {
                        agent_state.cmd_palette.appendRenameChar(@intCast(key.codepoint));
                        app.needs_render = true;
                    }
                    return;
                },
            }
        }

        // Search mode
        switch (key.codepoint) {
            27 => { // ESC - close palette
                agent_state.cmd_palette.close();
                app.needs_render = true;
                return;
            },
            vaxis.Key.enter => {
                // Execute selected command
                if (agent_state.cmd_palette.getSelectedCommand()) |cmd| {
                    // Close command palette BEFORE executing (in case command switches tabs)
                    agent_state.cmd_palette.close();
                    try executeAgentCommand(app, agent_state, cmd.action);
                } else {
                    agent_state.cmd_palette.close();
                }
                app.needs_render = true;
                return;
            },
            vaxis.Key.up => {
                agent_state.cmd_palette.moveUp();
                app.needs_render = true;
                return;
            },
            vaxis.Key.down => {
                agent_state.cmd_palette.moveDown();
                app.needs_render = true;
                return;
            },
            127, 8 => { // Backspace
                agent_state.cmd_palette.deleteQueryChar();
                app.needs_render = true;
                return;
            },
            else => {
                // Ctrl+N/P for navigation
                if (key.mods.ctrl) {
                    if (key.codepoint == 'n') {
                        agent_state.cmd_palette.moveDown();
                        app.needs_render = true;
                        return;
                    }
                    if (key.codepoint == 'p') {
                        agent_state.cmd_palette.moveUp();
                        app.needs_render = true;
                        return;
                    }
                }
                // Regular character input
                if (key.codepoint >= 32 and key.codepoint < 127) {
                    agent_state.cmd_palette.appendQueryChar(@intCast(key.codepoint));
                    app.needs_render = true;
                }
                return;
            },
        }
    }

    // ':' in normal vim mode - open command palette
    if (agent_state.input.vim.vim_mode == .normal and key.codepoint == ':' and !key.mods.ctrl and !key.mods.alt) {
        agent_state.cmd_palette.open();
        app.needs_render = true;
        return;
    }

    // '?' in normal vim mode - show help overlay
    if (agent_state.input.vim.vim_mode == .normal and key.codepoint == '?') {
        agent_state.help_visible = true;
        agent_state.help_scroll_offset = 0;
        app.needs_render = true;
        return;
    }

    // Vim g-prefix commands in normal mode (gb, gt, gT)
    // Note: gg and G are left to the input editor for normal vim behavior
    if (agent_state.input.vim.vim_mode == .normal) {
        // Handle 'gb', 'gt'/'gT' sequences
        if (app.state.pending_g) {
            app.state.pending_g = false;
            if (key.codepoint == 'b') {
                // gb - enter history mode (if messages exist)
                if (agent_state.messages.items.len > 0) {
                    agent_state.enterHistoryMode();
                    app.needs_render = true;
                }
                return;
            }
            if (key.codepoint == 't') {
                // gt - next tab
                if (app.tab_manager) |*tm| {
                    tm.nextTab();
                    // Mark the new tab's line map as dirty to force rebuild
                    if (tm.activeTab()) |tab| {
                        tab.agent_state.markLineMapDirty();
                    }
                    app.needs_render = true;
                }
                return;
            }
            if (key.codepoint == 'T') {
                // gT - previous tab
                if (app.tab_manager) |*tm| {
                    tm.prevTab();
                    // Mark the new tab's line map as dirty to force rebuild
                    if (tm.activeTab()) |tab| {
                        tab.agent_state.markLineMapDirty();
                    }
                    app.needs_render = true;
                }
                return;
            }
            // Unknown g-sequence (including gg) - pass through to input editor
            // Re-inject the 'g' that was consumed, then let this key through
            // For simplicity, just don't consume - let input editor handle
        } else if (key.codepoint == 'g' and !key.mods.ctrl and !key.mods.alt) {
            // First 'g' - wait for second
            app.state.pending_g = true;
            return;
        }

        // Space prefix commands (Space+b/h for history, Space+f for follow, Space+s for diff style)
        if (app.state.pending_space) {
            app.state.pending_space = false;
            if (key.codepoint == 'b' or key.codepoint == 'h') {
                // Space+b or Space+h - enter history mode (if messages exist)
                if (agent_state.messages.items.len > 0) {
                    agent_state.enterHistoryMode();
                    app.needs_render = true;
                }
                return;
            }
            if (key.codepoint == 'f') {
                // Space+f - scroll to bottom, enable follow mode
                agent_state.scrollToBottom();
                app.needs_render = true;
                return;
            }
            if (key.codepoint == 's') {
                // Space+s - toggle diff view mode (unified/side-by-side)
                agent_state.toggleDiffViewMode();
                app.needs_render = true;
                return;
            }
            // Unknown space-sequence, ignore
            return;
        } else if (key.codepoint == ' ' and !key.mods.ctrl and !key.mods.alt) {
            // First Space - wait for second key
            app.state.pending_space = true;
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
        // Handle both control character codepoints AND ctrl+letter combinations
        const effective_key: u21 = blk: {
            // First check control character codepoints
            // Note: Some terminals send 127 (DEL) for Ctrl+H instead of 8 (BS)
            if (key.codepoint == 8 or key.codepoint == 127) break :blk 'h'; // Ctrl+h / backspace
            if (key.codepoint == 12) break :blk 'l'; // Ctrl+l as control char
            if (key.codepoint == 23) break :blk 'w'; // Ctrl+w as control char
            // Also handle ctrl+letter (some terminals report this way)
            if (key.mods.ctrl) {
                if (key.codepoint == 'h') break :blk 'h';
                if (key.codepoint == 'l') break :blk 'l';
                if (key.codepoint == 'w') break :blk 'w';
            }
            break :blk key.codepoint;
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
            'o' => {
                // Toggle fullscreen (vim's "only window" concept)
                if (app.tab_manager) |*tm| {
                    tm.toggleFullScreen();
                    app.needs_render = true;
                }
                return;
            },
            else => {},
        }
        return;
    }

    // Ctrl+E - close agent panel and return to diff (toggle)
    if (key.mods.ctrl and key.codepoint == 'e') {
        if (app.tab_manager) |*tm| {
            tm.panel_visible = false;
        }
        agent_state.visible = false;
        app.mode = .normal;
        app.needs_render = true;
        return;
    }

    // Ctrl+G - open current prompt in $EDITOR (works in normal and insert mode)
    if (key.mods.ctrl and key.codepoint == 'g') {
        app.editAgentPromptInEditor() catch |err| {
            std.log.err("Failed to open prompt in editor: {any}", .{err});
        };
        return;
    }


    // Ctrl+D - page down (only in history mode, otherwise pass to input editor)
    if (key.mods.ctrl and key.codepoint == 'd') {
        if (agent_state.isInHistoryMode()) {
            agent_state.follow_bottom = false; // Disable follow mode
            const scroll_amount = @max(1, agent_state.last_messages_viewport_height / 2);
            agent_state.scrollDown(scroll_amount);
            app.needs_render = true;
            return;
        }
        // Normal/insert mode: fall through to input editor for vim half-page down
    }

    // Ctrl+U - page up (only in history mode, otherwise pass to input editor)
    if (key.mods.ctrl and key.codepoint == 'u') {
        if (agent_state.isInHistoryMode()) {
            agent_state.follow_bottom = false; // Disable follow mode
            const scroll_amount = @max(1, agent_state.last_messages_viewport_height / 2);
            agent_state.scrollUp(scroll_amount);
            app.needs_render = true;
            return;
        }
        // Normal/insert mode: fall through to input editor for vim half-page up
    }

    // Up arrow on empty input - restore staged prompt into input for editing
    if (key.codepoint == vaxis.Key.up and agent_state.input.isEmpty() and agent_state.hasStagedPrompt()) {
        const staged = agent_state.takeStagedPrompt() orelse return;
        agent_state.input.setText(staged);
        agent_state.input.vim.cursor_pos = agent_state.input.vim.text_len;
        agent_state.input.vim.vim_mode = .insert;
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
            if (app.getActiveAcpManager()) |mgr| {
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
        agent_state.togglePlanExpanded();
        app.needs_render = true;
        return;
    }

    // '!' key in insert mode with empty input - toggle shell command mode
    // Only triggers when input is empty, so users can type '!' normally in prompts
    if (agent_state.input.vim.vim_mode == .insert and key.codepoint == '!' and !key.mods.ctrl and !key.mods.alt) {
        if (agent_state.input.getText().len == 0) {
            agent_state.toggleShellMode();
            app.needs_render = true;
            return;
        }
        // Otherwise fall through to let '!' be inserted as a character
    }

    // Backspace on empty input in shell mode - exit shell mode
    if (agent_state.isShellMode() and agent_state.input.vim.vim_mode == .insert and
        key.codepoint == vaxis.Key.backspace and agent_state.input.getText().len == 0)
    {
        agent_state.clearShellMode();
        app.needs_render = true;
        return;
    }

    // Escape in shell mode - exit shell mode
    if (agent_state.isShellMode() and key.codepoint == 27) {
        agent_state.clearShellMode();
        app.needs_render = true;
        // Don't return - let normal ESC handling proceed (switches to normal mode)
    }

    // Delegate to input editor
    const action = try agent.InputEditor.handleKey(&agent_state.input, key, app.allocator);

    if (action) |act| {
        switch (act) {
            .send => {
                const raw_text = agent_state.input.getText();
                const text = std.mem.trim(u8, raw_text, &std.ascii.whitespace);
                const is_thinking = if (app.getActiveAcpManager()) |mgr| mgr.status == .prompting else false;
                const session_not_ready = if (app.getActiveAcpManager()) |mgr|
                    mgr.status == .discovering or mgr.status == .connecting or mgr.status == .connected
                else
                    false;

                // Handle staged message scenarios first (agent thinking or session not ready)
                if ((is_thinking or session_not_ready) and agent_state.hasStagedPrompt()) {
                    if (text.len == 0 and is_thinking) {
                        // Empty prompt + staged message + agent thinking = interrupt and send immediately
                        if (app.getActiveAcpManager()) |mgr| {
                            if (mgr.cancelPrompt()) {
                                std.log.info("Agent: Interrupted via staged message immediate send", .{});
                                try agent_state.addMessage(.system, "Interrupted");
                            }
                        }

                        // Send the staged message
                        const staged = agent_state.getStagedPrompt();
                        try agent_state.addMessage(.user, staged);

                        // Auto-name the tab from the first user prompt
                        app.autoNameActiveTab(staged);

                        if (app.getActiveAcpManager()) |mgr| {
                            if (mgr.status == .disconnected) {
                                try agent_state.addMessage(.system, "Agent disconnected. Close and reopen panel to reconnect.");
                            } else if (mgr.status == .failed) {
                                try agent_state.addMessage(.system, "Agent connection failed. Close and reopen panel to retry.");
                            } else {
                                try sendPromptWithFiles(app, mgr, staged);
                            }
                        }

                        agent_state.clearStagedPrompt();
                    } else if (text.len == 0) {
                        // Empty prompt + staged message + session not ready = do nothing (already queued)
                        // Message will be sent automatically when session becomes ready
                    } else {
                        // Non-empty prompt + staged message = append to staged message
                        const current_staged = agent_state.getStagedPrompt();
                        var combined_buf: [8192]u8 = undefined;
                        const combined = std.fmt.bufPrint(&combined_buf, "{s}\n{s}", .{ current_staged, text }) catch text;
                        agent_state.stagePrompt(combined);
                        agent_state.input.clear();
                    }
                } else if (text.len > 0) {
                    if (is_thinking or session_not_ready) {
                        // Agent thinking or session not ready - stage for later
                        agent_state.stagePrompt(text);
                        agent_state.input.clear();
                    } else {
                        // Check if in shell command mode
                        if (agent_state.isShellMode()) {
                            // Execute as shell command
                            try handleShellCommand(app, agent_state, text);
                            agent_state.input.clear();
                            agent_state.clearShellMode();
                        } else {
                            // Agent not thinking - send normally
                            // Add user message to history
                            try agent_state.addMessage(.user, text);

                            // Auto-name the tab from the first user prompt
                            app.autoNameActiveTab(text);

                            // Send to ACP agent (manager will queue if still connecting)
                            if (app.getActiveAcpManager()) |mgr| {
                                if (mgr.status == .disconnected) {
                                    try agent_state.addMessage(.system, "Agent disconnected. Close and reopen panel to reconnect.");
                                } else if (mgr.status == .failed) {
                                    try agent_state.addMessage(.system, "Agent connection failed. Close and reopen panel to retry.");
                                } else {
                                    // Parse and send prompt with file references
                                    try sendPromptWithFiles(app, mgr, text);
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

    // Update file picker visibility based on current input
    updateFilePickerVisibility(app, agent_state);
}

/// Insert a file reference into the input (displayed as @path/to/file)
/// The file content is resolved and embedded when the prompt is sent.
fn insertFileAsResource(_: *App, agent_state: *agent.AgentState, file_path: []const u8) !void {
    const input_text = agent_state.input.getText();
    const cursor_pos = agent_state.input.vim.cursor_pos;

    // Find the @ position to replace
    const active = state.FilePickerState.getActiveAtPosition(input_text, cursor_pos) orelse return;

    // Build new text: before @ + @file_path + space + after query
    var new_text: std.ArrayList(u8) = .{};
    defer new_text.deinit(agent_state.allocator);

    try new_text.appendSlice(agent_state.allocator, input_text[0..active.start]);
    try new_text.append(agent_state.allocator, '@');
    try new_text.appendSlice(agent_state.allocator, file_path);
    try new_text.append(agent_state.allocator, ' '); // Add space after file reference
    if (active.end < input_text.len) {
        try new_text.appendSlice(agent_state.allocator, input_text[active.end..]);
    }

    // Update input - cursor positioned after the space
    agent_state.input.setText(new_text.items);
    agent_state.input.vim.cursor_pos = active.start + 1 + file_path.len + 1; // @path + space
}

/// Get MIME type for a file path based on extension
fn getMimeType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".zig")) return "text/x-zig";
    if (std.mem.endsWith(u8, path, ".py")) return "text/x-python";
    if (std.mem.endsWith(u8, path, ".ts")) return "text/typescript";
    if (std.mem.endsWith(u8, path, ".tsx")) return "text/typescript";
    if (std.mem.endsWith(u8, path, ".js")) return "text/javascript";
    if (std.mem.endsWith(u8, path, ".jsx")) return "text/javascript";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
    if (std.mem.endsWith(u8, path, ".md")) return "text/markdown";
    if (std.mem.endsWith(u8, path, ".rs")) return "text/x-rust";
    if (std.mem.endsWith(u8, path, ".go")) return "text/x-go";
    if (std.mem.endsWith(u8, path, ".c")) return "text/x-c";
    if (std.mem.endsWith(u8, path, ".cpp") or std.mem.endsWith(u8, path, ".cc")) return "text/x-c++";
    if (std.mem.endsWith(u8, path, ".h") or std.mem.endsWith(u8, path, ".hpp")) return "text/x-c";
    if (std.mem.endsWith(u8, path, ".java")) return "text/x-java";
    if (std.mem.endsWith(u8, path, ".rb")) return "text/x-ruby";
    if (std.mem.endsWith(u8, path, ".sh") or std.mem.endsWith(u8, path, ".bash")) return "text/x-shellscript";
    if (std.mem.endsWith(u8, path, ".yaml") or std.mem.endsWith(u8, path, ".yml")) return "text/yaml";
    if (std.mem.endsWith(u8, path, ".toml")) return "text/toml";
    if (std.mem.endsWith(u8, path, ".html")) return "text/html";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css";
    if (std.mem.endsWith(u8, path, ".xml")) return "application/xml";
    if (std.mem.endsWith(u8, path, ".sql")) return "text/x-sql";
    return "text/plain";
}

/// Escape a string for JSON embedding
fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            0x08 => try result.appendSlice(allocator, "\\b"), // backspace
            0x0C => try result.appendSlice(allocator, "\\f"), // form feed
            else => {
                if (c < 0x20) {
                    // Control characters - use unicode escape
                    var buf: [6]u8 = undefined;
                    _ = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try result.appendSlice(allocator, &buf);
                } else {
                    try result.append(allocator, c);
                }
            },
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Handle shell command execution (commands starting with !)
/// Spawns the command asynchronously and streams output to the UI.
fn handleShellCommand(app: *App, agent_state: *agent.AgentState, command: []const u8) !void {
    // If a command is already running, reject
    if (agent_state.shell.running_cmd != null) {
        try agent_state.addMessage(.system, "A command is already running. Wait for it to complete.");
        return;
    }

    // Add user message showing the command
    var cmd_msg: [2048]u8 = undefined;
    const cmd_text = std.fmt.bufPrint(&cmd_msg, "$ {s}", .{command}) catch command;
    try agent_state.addMessage(.user, cmd_text);

    // Generate unique tool ID for this command
    var tool_id_buf: [32]u8 = undefined;
    const tool_id = agent_state.nextShellCmdId(&tool_id_buf);

    // Add a "running" tool message that will be updated with output
    try agent_state.addToolMessage(tool_id, "Bash", command, command);

    // Initialize running command state
    var running_cmd = state.RunningShellCommand.init(app.allocator, command, tool_id) catch |err| {
        std.log.err("Failed to init running command: {any}", .{err});
        try agent_state.updateToolMessage(tool_id, .failed, null, "Failed to initialize command");
        return;
    };

    // Spawn the command using sh -c
    const user_shell = std.posix.getenv("SHELL") orelse "/bin/sh";
    var argv_storage: [3][]const u8 = .{ user_shell, "-c", command };
    running_cmd.child = std.process.Child.init(&argv_storage, app.allocator);
    running_cmd.child.stdout_behavior = .Pipe;
    running_cmd.child.stderr_behavior = .Pipe;
    running_cmd.child.stdin_behavior = .Close;

    running_cmd.child.spawn() catch |err| {
        std.log.err("Failed to spawn command: {any}", .{err});
        running_cmd.deinit();
        try agent_state.updateToolMessage(tool_id, .failed, null, "Failed to spawn command");
        return;
    };

    // Store running command for polling
    agent_state.shell.running_cmd = running_cmd;
    agent_state.line_map_dirty = true;
}

/// Poll running shell command for output. Returns true if there was activity.
/// Called from the main event loop.
pub fn pollRunningShellCommand(app: *App) bool {
    const agent_state = app.getActiveAgentState() orelse return false;
    var cmd = &(agent_state.shell.running_cmd orelse return false);

    var had_activity = false;
    var read_buf: [4096]u8 = undefined;

    // Try to read from stdout (non-blocking via poll)
    if (cmd.child.stdout) |stdout| {
        // Check if data is available
        var poll_fds = [_]std.posix.pollfd{
            .{ .fd = stdout.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const poll_result = std.posix.poll(&poll_fds, 0) catch 0;

        if (poll_result > 0 and (poll_fds[0].revents & std.posix.POLL.IN) != 0) {
            const bytes_read = stdout.read(&read_buf) catch 0;
            if (bytes_read > 0) {
                cmd.stdout_buf.appendSlice(app.allocator, read_buf[0..bytes_read]) catch {};
                had_activity = true;
            }
        }
    }

    // Try to read from stderr
    if (cmd.child.stderr) |stderr| {
        var poll_fds = [_]std.posix.pollfd{
            .{ .fd = stderr.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const poll_result = std.posix.poll(&poll_fds, 0) catch 0;

        if (poll_result > 0 and (poll_fds[0].revents & std.posix.POLL.IN) != 0) {
            const bytes_read = stderr.read(&read_buf) catch 0;
            if (bytes_read > 0) {
                cmd.stderr_buf.appendSlice(app.allocator, read_buf[0..bytes_read]) catch {};
                had_activity = true;
            }
        }
    }

    // Update tool message with last 8 lines if we got new output
    if (had_activity) {
        const last_lines = cmd.getLastLines(8);
        agent_state.updateToolMessage(cmd.tool_id, .running, last_lines, null) catch {};
        agent_state.line_map_dirty = true;
        app.needs_render = true;
    }

    // Check if process has terminated (non-blocking)
    const wait_result = std.posix.waitpid(cmd.child.id, std.c.W.NOHANG);
    const exited = wait_result.pid != 0;
    if (exited) {
        // Process has completed - finalize
        // Parse exit status using POSIX macros
        const exit_success = std.c.W.IFEXITED(wait_result.status) and
            std.c.W.EXITSTATUS(wait_result.status) == 0;
        const status: state.Message.ToolStatus = if (exit_success) .completed else .failed;

        // Update with final output
        const stdout_content = cmd.stdout_buf.items;
        const stderr_content = if (cmd.stderr_buf.items.len > 0) cmd.stderr_buf.items else null;
        agent_state.updateToolMessage(cmd.tool_id, status, stdout_content, stderr_content) catch {};

        // Queue output for next prompt
        queueCommandOutput(app, agent_state, cmd.command, stdout_content, stderr_content orelse "", wait_result.status) catch |err| {
            std.log.err("Failed to queue command output: {any}", .{err});
        };

        // Clean up
        cmd.deinit();
        agent_state.shell.running_cmd = null;
        agent_state.line_map_dirty = true;
        app.needs_render = true;
        return true;
    }

    return had_activity;
}

/// Queue shell command output to be sent with the next prompt
fn queueCommandOutput(
    app: *App,
    agent_state: *agent.AgentState,
    command: []const u8,
    stdout: []const u8,
    stderr: []const u8,
    wait_status: u32,
) !void {
    // Build the resource content with command, exit code, and output
    var content_buf: std.ArrayList(u8) = .{};
    defer content_buf.deinit(app.allocator);

    const writer = content_buf.writer(app.allocator);

    // Write command header
    try writer.print("$ {s}\n", .{command});

    // Write stdout if present
    if (stdout.len > 0) {
        try writer.writeAll(stdout);
        if (!std.mem.endsWith(u8, stdout, "\n")) {
            try writer.writeByte('\n');
        }
    }

    // Write stderr if present
    if (stderr.len > 0) {
        try writer.writeAll("# stderr:\n");
        try writer.writeAll(stderr);
        if (!std.mem.endsWith(u8, stderr, "\n")) {
            try writer.writeByte('\n');
        }
    }

    // Parse exit code from wait status
    const exit_code: i32 = if (std.c.W.IFEXITED(wait_status))
        @intCast(std.c.W.EXITSTATUS(wait_status))
    else if (std.c.W.IFSIGNALED(wait_status))
        -@as(i32, @intCast(std.c.W.TERMSIG(wait_status)))
    else if (std.c.W.IFSTOPPED(wait_status))
        -@as(i32, @intCast(std.c.W.STOPSIG(wait_status)))
    else
        @intCast(wait_status);
    try writer.print("# exit code: {d}\n", .{exit_code});

    // Queue for sending with next prompt
    try agent_state.queueShellOutput(content_buf.items);
}

/// Extract arguments from slash command input.
/// For input like "/model sonnet", returns "sonnet".
/// For input like "/model", returns "".
fn extractCommandArgs(input: []const u8, command_name: []const u8) []const u8 {
    // Input format: "/command_name args..."
    // We need to extract everything after "/command_name "

    // Skip leading "/"
    if (input.len == 0 or input[0] != '/') return "";

    const after_slash = input[1..];

    // Check if input starts with the command name
    if (!std.mem.startsWith(u8, after_slash, command_name)) return "";

    // Skip past the command name
    const after_cmd = after_slash[command_name.len..];

    // Skip any whitespace between command and args
    var i: usize = 0;
    while (i < after_cmd.len and (after_cmd[i] == ' ' or after_cmd[i] == '\t')) : (i += 1) {}

    if (i >= after_cmd.len) return "";

    // Return the remaining text (arguments)
    return std.mem.trim(u8, after_cmd[i..], &std.ascii.whitespace);
}

/// Handle local slash commands (executed by skim, not sent to agent)
fn handleLocalCommand(app: *App, agent_state: *agent.AgentState, command_name: []const u8, args: []const u8) !void {
    if (std.mem.eql(u8, command_name, "clear")) {
        // Clear the current session and start a new one
        std.log.info("Clear command: resetting session", .{});

        // Clear agent state (messages, plan, etc.)
        agent_state.clearMessages();
        agent_state.clearPlan();
        agent_state.clearStagedPrompt();
        agent_state.clearQueuedShellOutputs();

        // Reset and create a new ACP session
        if (app.getActiveAcpManager()) |mgr| {
            // Capture copies of current mode/model before reset (resetSession frees them)
            const current_mode: ?[]const u8 = if (mgr.current_mode_id) |m|
                app.allocator.dupe(u8, m) catch null
            else
                null;
            defer if (current_mode) |m| app.allocator.free(m);

            const current_model: ?[]const u8 = if (mgr.current_model_id) |m|
                app.allocator.dupe(u8, m) catch null
            else
                null;
            defer if (current_model) |m| app.allocator.free(m);

            std.log.info("Clear: preserving mode={s}, model={s}", .{
                current_mode orelse "(none)",
                current_model orelse "(none)",
            });

            // First reset the existing session state
            mgr.resetSession();

            // Then create a new session with the same mode/model settings
            const cwd = app.state.git_repo_root;
            mgr.createSessionWithSettings(cwd, current_mode, current_model) catch |err| {
                std.log.err("Clear: failed to create new session: {any}", .{err});
                try agent_state.addMessage(.system, "Failed to create new session");
                return;
            };
            try agent_state.addMessage(.system, "Session cleared. Starting fresh.");
        } else {
            try agent_state.addMessage(.system, "Chat cleared. (No agent connected)");
        }
        return;
    }

    if (std.mem.eql(u8, command_name, "model")) {
        // Switch to model selection mode with optional preselected model
        app.resetModelFilter();
        app.mode = .model_selection;

        // If args provided, try to preselect that model
        if (args.len > 0) {
            // Log the requested model for debugging
            std.log.info("Model command with args: '{s}'", .{args});
            // Model selection mode will handle the preselection
        }

        try agent_state.addMessage(.system, "Switching to model selection...");
        return;
    }

    if (std.mem.eql(u8, command_name, "resume")) {
        // Discover available sessions for current project
        const cwd = app.state.git_repo_root;

        // Determine which agent type we're using
        const agent_type: sessions.AgentType = if (app.getActiveAcpManager()) |mgr| blk: {
            if (mgr.agent_name) |name| {
                // Check agent name to determine type
                if (std.mem.indexOf(u8, name, "claude") != null or
                    std.mem.indexOf(u8, name, "Claude") != null)
                {
                    break :blk .claude_code;
                } else if (std.mem.indexOf(u8, name, "codex") != null or
                    std.mem.indexOf(u8, name, "Codex") != null)
                {
                    break :blk .codex;
                }
            }
            break :blk .claude_code; // Default to Claude Code
        } else .claude_code;

        // Discover sessions
        const session_list = sessions.listSessions(app.allocator, agent_type, cwd, 20) catch |err| {
            std.log.err("Failed to discover sessions: {any}", .{err});
            try agent_state.addMessage(.system, "No sessions found for this project");
            return;
        };

        if (session_list.len == 0) {
            try agent_state.addMessage(.system, "No sessions found for this project");
            return;
        }

        // Store sessions and switch to picker mode
        app.state.session_list = session_list;
        app.state.session_selection = 0;
        app.mode = .session_picker;

        std.log.info("Resume: found {d} sessions for {s}", .{ session_list.len, cwd });
        return;
    }

    // Unknown local command (shouldn't happen, but handle gracefully)
    try agent_state.addMessage(.system, "Unknown local command");
}

/// Update slash menu visibility based on input content
fn updateSlashMenuVisibility(_: *App, agent_state: *agent.AgentState) void {
    if (agent_state.input.vim.vim_mode != .insert) {
        // Only show menu in insert mode
        agent_state.hideSlashMenu();
        return;
    }

    const should_show = agent_state.shouldShowSlashMenu();

    if (should_show and !agent_state.slash_menu.visible) {
        // Commands from the agent will appear on the next event loop iteration
        // (main loop calls pollAcpUpdates regularly - no need to block the key handler)
        agent_state.showSlashMenu();
    } else if (!should_show and agent_state.slash_menu.visible) {
        // Hide menu when "/" is deleted or input changes
        agent_state.hideSlashMenu();
    }

    // Keep selection in bounds when filter changes
    if (agent_state.slash_menu.visible) {
        var indices: [32]usize = undefined;
        const count = agent_state.getFilteredCommandIndices(&indices);
        if (count > 0 and agent_state.slash_menu.selection >= count) {
            agent_state.slash_menu.selection = count - 1;
        }
    }
}

/// Update file picker visibility based on input content
fn updateFilePickerVisibility(_: *App, agent_state: *agent.AgentState) void {
    if (agent_state.input.vim.vim_mode != .insert) {
        // Only show menu in insert mode
        agent_state.file_picker.visible = false;
        return;
    }

    const input_text = agent_state.input.getText();
    const cursor_pos = agent_state.input.vim.cursor_pos;

    // Check if there's an active @ trigger at cursor position
    const active = state.FilePickerState.getActiveAtPosition(input_text, cursor_pos);

    if (active != null and !agent_state.file_picker.visible) {
        // Start async load if not already loaded/loading
        // Files should already be preloaded when panel opens, but handle edge case
        if (!agent_state.file_picker.hasFiles() and !agent_state.file_picker.isLoading()) {
            agent_state.file_picker.startAsyncLoad();
        }
        agent_state.file_picker.visible = true;
        agent_state.file_picker.selection = 0;
        agent_state.file_picker.scroll_offset = 0;
    } else if (active == null and agent_state.file_picker.visible) {
        // Hide picker when @ is deleted
        agent_state.file_picker.visible = false;
    }

    // Update filter when picker is visible
    if (agent_state.file_picker.visible) {
        const filter = state.FilePickerState.getFileFilter(input_text, cursor_pos);
        agent_state.file_picker.updateFilter(filter) catch {};
    }
}

/// Send a prompt, parsing @file references and embedding file content.
/// Also includes any queued shell command outputs as embedded resources.
/// Falls back to simple text prompt if parsing fails or no files/shell outputs.
fn sendPromptWithFiles(app: *App, mgr: *AcpManager, text: []const u8) !void {
    const agent_state = app.getActiveAgentState() orelse return;

    // Take any queued shell outputs
    const queued_outputs_opt = agent_state.takeQueuedShellOutputs();
    defer {
        if (queued_outputs_opt) |outputs| {
            for (outputs) |*output| {
                var mutable_output = output.*;
                mutable_output.deinit(app.allocator);
            }
            app.allocator.free(outputs);
        }
    }

    // Check if there are any @ references that might be files
    const has_at = std.mem.indexOf(u8, text, "@") != null;
    const has_shell_outputs = queued_outputs_opt != null and queued_outputs_opt.?.len > 0;
    const queued_count: usize = if (queued_outputs_opt) |o| o.len else 0;
    std.log.info("sendPromptWithFiles: text_len={d}, has_at={}, queued_shell_outputs={d}", .{ text.len, has_at, queued_count });

    // If we have shell outputs or @file references, send as content blocks
    if (has_at or has_shell_outputs) {
        // Parse @file references
        var parsed = parsePromptContent(app.allocator, text) catch |err| {
            std.log.warn("sendPromptWithFiles: Failed to parse prompt content: {}", .{err});
            // If we have shell outputs, we still need to send them
            if (queued_outputs_opt) |queued_outputs| {
                try sendWithShellOutputsOnly(app, mgr, text, queued_outputs);
                return;
            }
            // Fall back to simple text prompt
            const prompt_copy = try app.allocator.dupe(u8, text);
            defer app.allocator.free(prompt_copy);
            return mgr.sendPrompt(prompt_copy);
        };
        defer parsed.deinit();

        std.log.info("sendPromptWithFiles: parsed {d} blocks, {d} file resources", .{ parsed.blocks.len, parsed.resources.len });

        // Log resource URIs
        for (parsed.resources, 0..) |res, i| {
            std.log.info("sendPromptWithFiles: resource[{d}] uri={s}, mime={s}, text_len={d}", .{ i, res.uri, res.mime_type, res.text.len });
        }

        if (parsed.resources.len > 0 or has_shell_outputs) {
            // Build combined content blocks: parsed blocks + shell output blocks
            const total_blocks = parsed.blocks.len + queued_count;
            var combined_blocks = try app.allocator.alloc(protocol.ContentBlock, total_blocks);
            defer app.allocator.free(combined_blocks);

            // Copy parsed blocks first
            @memcpy(combined_blocks[0..parsed.blocks.len], parsed.blocks);

            // Add shell output blocks
            if (queued_outputs_opt) |queued_outputs| {
                for (queued_outputs, 0..) |output, i| {
                    combined_blocks[parsed.blocks.len + i] = .{
                        .embedded_resource = .{
                            .resource = .{
                                .uri = "shell://command",
                                .mimeType = "text/plain",
                                .text = output.content,
                            },
                        },
                    };
                }
            }

            std.log.info("sendPromptWithFiles: sending {d} content blocks ({d} parsed + {d} shell)", .{
                total_blocks,
                parsed.blocks.len,
                queued_count,
            });

            mgr.sendPromptContent(combined_blocks) catch |err| {
                std.log.err("sendPromptWithFiles: Failed to send prompt content: {any}", .{err});
                try agent_state.addMessage(.system, "Failed to send prompt to agent");
            };
        } else {
            // No file resources or shell outputs - send as simple text
            std.log.info("sendPromptWithFiles: no valid file refs or shell outputs, sending as simple text", .{});
            const prompt_copy = try app.allocator.dupe(u8, text);
            defer app.allocator.free(prompt_copy);
            mgr.sendPrompt(prompt_copy) catch |err| {
                std.log.err("sendPromptWithFiles: Failed to send prompt: {any}", .{err});
                try agent_state.addMessage(.system, "Failed to send prompt to agent");
            };
        }
    } else {
        // No @ and no shell outputs - send simple text prompt
        std.log.info("sendPromptWithFiles: no @ or shell outputs, sending as simple text", .{});
        const prompt_copy = try app.allocator.dupe(u8, text);
        defer app.allocator.free(prompt_copy);
        mgr.sendPrompt(prompt_copy) catch |err| {
            std.log.err("sendPromptWithFiles: Failed to send prompt: {any}", .{err});
            try agent_state.addMessage(.system, "Failed to send prompt to agent");
        };
    }
}

/// Helper to send prompt with shell outputs when @file parsing failed
fn sendWithShellOutputsOnly(
    app: *App,
    mgr: *AcpManager,
    text: []const u8,
    queued_outputs: []const state.QueuedShellOutput,
) !void {
    const agent_state = app.getActiveAgentState() orelse return;

    // Build blocks: text + shell outputs
    const total_blocks = 1 + queued_outputs.len;
    var blocks = try app.allocator.alloc(protocol.ContentBlock, total_blocks);
    defer app.allocator.free(blocks);

    // Text block first
    blocks[0] = .{ .text = .{ .text = text } };

    // Shell output blocks
    for (queued_outputs, 0..) |output, i| {
        blocks[1 + i] = .{
            .embedded_resource = .{
                .resource = .{
                    .uri = "shell://command",
                    .mimeType = "text/plain",
                    .text = output.content,
                },
            },
        };
    }

    std.log.info("sendWithShellOutputsOnly: sending {d} blocks (1 text + {d} shell)", .{ total_blocks, queued_outputs.len });

    mgr.sendPromptContent(blocks) catch |err| {
        std.log.err("sendWithShellOutputsOnly: Failed to send prompt content: {any}", .{err});
        try agent_state.addMessage(.system, "Failed to send prompt to agent");
    };
}

/// Parsed content with ownership
pub const ParsedContent = struct {
    blocks: []protocol.ContentBlock,
    resources: []OwnedResource,
    allocator: std.mem.Allocator,

    pub const OwnedResource = struct {
        uri: []u8,
        mime_type: []const u8, // Static string, not owned
        text: []u8,
    };

    pub fn deinit(self: *ParsedContent) void {
        // Free owned strings in resources
        for (self.resources) |res| {
            self.allocator.free(res.uri);
            self.allocator.free(res.text);
        }
        self.allocator.free(self.resources);
        self.allocator.free(self.blocks);
    }
};

/// Parse prompt text and extract @file references into content blocks.
/// Returns text blocks and embedded resource blocks.
/// Caller owns the returned ParsedContent and must call deinit().
pub fn parsePromptContent(allocator: std.mem.Allocator, input_text: []const u8) !ParsedContent {
    var blocks: std.ArrayList(protocol.ContentBlock) = .{};
    errdefer blocks.deinit(allocator);

    var resources: std.ArrayList(ParsedContent.OwnedResource) = .{};
    errdefer {
        for (resources.items) |res| {
            allocator.free(res.uri);
            allocator.free(res.text);
        }
        resources.deinit(allocator);
    }

    if (input_text.len == 0) {
        return .{
            .blocks = try blocks.toOwnedSlice(allocator),
            .resources = try resources.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    var i: usize = 0;
    var text_start: usize = 0;

    while (i < input_text.len) {
        // Check for @ at word boundary
        if (input_text[i] == '@') {
            const at_word_boundary = (i == 0 or
                input_text[i - 1] == ' ' or
                input_text[i - 1] == '\n' or
                input_text[i - 1] == '\t');

            if (at_word_boundary) {
                // Find end of file path (until whitespace or end)
                const path_start = i + 1;
                var path_end = path_start;
                while (path_end < input_text.len and
                    input_text[path_end] != ' ' and
                    input_text[path_end] != '\n' and
                    input_text[path_end] != '\t')
                {
                    path_end += 1;
                }

                const file_path = input_text[path_start..path_end];

                // Try to read the file
                if (file_path.len > 0) {
                    const cwd = std.fs.cwd();
                    if (cwd.openFile(file_path, .{})) |file| {
                        defer file.close();

                        // Check file size
                        const stat = file.stat() catch {
                            i += 1;
                            continue;
                        };
                        if (stat.size > state.MAX_FILE_SIZE) {
                            i += 1;
                            continue;
                        }

                        // Read file content
                        const content = file.readToEndAlloc(allocator, state.MAX_FILE_SIZE) catch {
                            i += 1;
                            continue;
                        };
                        errdefer allocator.free(content);

                        // Add text block for content before this @file
                        if (i > text_start) {
                            try blocks.append(allocator, .{
                                .text = .{ .text = input_text[text_start..i] },
                            });
                        }

                        // Build file URI
                        const abs_path = cwd.realpathAlloc(allocator, file_path) catch {
                            allocator.free(content);
                            i += 1;
                            continue;
                        };
                        var uri_buf: std.ArrayList(u8) = .{};
                        defer uri_buf.deinit(allocator);
                        try uri_buf.appendSlice(allocator, "file://");
                        try uri_buf.appendSlice(allocator, abs_path);
                        allocator.free(abs_path);
                        const uri = try uri_buf.toOwnedSlice(allocator);
                        errdefer allocator.free(uri);

                        const mime_type = getMimeType(file_path);

                        // Store resource with ownership
                        try resources.append(allocator, .{
                            .uri = uri,
                            .mime_type = mime_type,
                            .text = content,
                        });

                        // Add embedded resource block (pointing to last resource)
                        const res = &resources.items[resources.items.len - 1];
                        try blocks.append(allocator, .{
                            .embedded_resource = .{
                                .resource = .{
                                    .uri = res.uri,
                                    .mimeType = res.mime_type,
                                    .text = res.text,
                                },
                            },
                        });

                        // Move past the @file reference
                        i = path_end;
                        text_start = path_end;
                        continue;
                    } else |_| {
                        // File doesn't exist, treat @ as regular text
                    }
                }
            }
        }
        i += 1;
    }

    // Add remaining text as final block
    if (text_start < input_text.len) {
        try blocks.append(allocator, .{
            .text = .{ .text = input_text[text_start..] },
        });
    }

    return .{
        .blocks = try blocks.toOwnedSlice(allocator),
        .resources = try resources.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "parsePromptContent plain text no @ references" {
    const allocator = std.testing.allocator;
    const parsed = try parsePromptContent(allocator, "hello world");
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.blocks.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.resources.len);
    try std.testing.expectEqualStrings("hello world", parsed.blocks[0].text.text);
}

test "parsePromptContent empty input" {
    const allocator = std.testing.allocator;
    const parsed = try parsePromptContent(allocator, "");
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), parsed.blocks.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.resources.len);
}

test "parsePromptContent @ not at word boundary treated as text" {
    const allocator = std.testing.allocator;
    // Email-like pattern - @ not at word boundary
    const parsed = try parsePromptContent(allocator, "contact me at user@example.com");
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.blocks.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.resources.len);
    try std.testing.expectEqualStrings("contact me at user@example.com", parsed.blocks[0].text.text);
}

test "parsePromptContent @nonexistent file treated as text" {
    const allocator = std.testing.allocator;
    const parsed = try parsePromptContent(allocator, "look at @nonexistent_file_12345.txt please");
    defer parsed.deinit();

    // File doesn't exist, so @ is kept as regular text
    try std.testing.expectEqual(@as(usize, 1), parsed.blocks.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.resources.len);
    try std.testing.expectEqualStrings("look at @nonexistent_file_12345.txt please", parsed.blocks[0].text.text);
}

test "parsePromptContent @README.md creates embedded resource" {
    const allocator = std.testing.allocator;
    const parsed = try parsePromptContent(allocator, "explain @README.md please");
    defer parsed.deinit();

    // Should have: text("explain ") + embedded_resource(README.md) + text(" please")
    try std.testing.expectEqual(@as(usize, 3), parsed.blocks.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.resources.len);

    // First block: text before @
    try std.testing.expectEqualStrings("explain ", parsed.blocks[0].text.text);

    // Second block: embedded resource
    try std.testing.expect(std.mem.endsWith(u8, parsed.blocks[1].embedded_resource.resource.uri, "/README.md"));
    try std.testing.expectEqualStrings("text/markdown", parsed.blocks[1].embedded_resource.resource.mimeType);
    try std.testing.expect(parsed.blocks[1].embedded_resource.resource.text.len > 0);

    // Third block: text after @file
    try std.testing.expectEqualStrings(" please", parsed.blocks[2].text.text);
}

test "parsePromptContent @build.zig at start of input" {
    const allocator = std.testing.allocator;
    const parsed = try parsePromptContent(allocator, "@build.zig explain this");
    defer parsed.deinit();

    // Should have: embedded_resource(build.zig) + text(" explain this")
    try std.testing.expectEqual(@as(usize, 2), parsed.blocks.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.resources.len);

    // First block: embedded resource (no leading text)
    try std.testing.expect(std.mem.endsWith(u8, parsed.blocks[0].embedded_resource.resource.uri, "/build.zig"));

    // Second block: text after
    try std.testing.expectEqualStrings(" explain this", parsed.blocks[1].text.text);
}

test "parsePromptContent multiple @file references" {
    const allocator = std.testing.allocator;
    const parsed = try parsePromptContent(allocator, "compare @README.md and @build.zig");
    defer parsed.deinit();

    // Should have: text("compare ") + embedded(README) + text(" and ") + embedded(build.zig)
    try std.testing.expectEqual(@as(usize, 4), parsed.blocks.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.resources.len);

    try std.testing.expectEqualStrings("compare ", parsed.blocks[0].text.text);
    try std.testing.expect(std.mem.endsWith(u8, parsed.blocks[1].embedded_resource.resource.uri, "/README.md"));
    try std.testing.expectEqualStrings(" and ", parsed.blocks[2].text.text);
    try std.testing.expect(std.mem.endsWith(u8, parsed.blocks[3].embedded_resource.resource.uri, "/build.zig"));
}

/// Execute an agent command palette action
fn executeAgentCommand(app: *App, agent_state: *agent.AgentState, action: command_palette.AgentCommandAction) !void {
    switch (action) {
        .new_tab => {
            const tm = try app.ensureTabManager();
            const new_tab = try tm.createTab("New Tab");

            // Store tab ID for agent selection to target
            app.state.pending_tab_for_selection = new_tab.id;

            // Load configured agents if not already loaded
            if (app.state.configured_agents == null) {
                app.state.configured_agents = app.loadConfiguredAgents();
            }

            // Switch to agent selection mode to pick agent for this tab
            app.mode = .agent_selection;
        },
        .close_tab => {
            const tm = try app.ensureTabManager();
            if (tm.tabCount() <= 1) {
                // Last tab - wipe completely and return to diff view
                // Next Ctrl+E will prompt for agent selection
                tm.closeAndWipeAll();
                tm.panel_visible = false;
                app.mode = .normal;
            } else {
                _ = tm.closeActiveTab();
            }
        },
        .next_tab => {
            const tm = try app.ensureTabManager();
            tm.nextTab();
        },
        .prev_tab => {
            const tm = try app.ensureTabManager();
            tm.prevTab();
        },
        .rename_tab => {
            // Switch to rename input mode
            agent_state.cmd_palette.startRenameInput();
        },
        .toggle_plan => {
            agent_state.togglePlanExpanded();
        },
    }
}
