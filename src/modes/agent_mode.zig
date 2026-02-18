const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const agent = @import("../agent/agent.zig");
const state = @import("../agent/state.zig");
const protocol = @import("../acp/protocol.zig");
const sessions = @import("../acp/sessions.zig");
const AcpManager = @import("../acp/manager.zig").AcpManager;
const ManagerHandle = @import("../agent/manager_handle.zig").ManagerHandle;
const CodexManager = @import("../codex/manager.zig").CodexManager;
const codex_protocol = @import("../codex/protocol.zig");
const command_palette = @import("../agent/command_palette.zig");
const opencode = @import("../opencode/opencode.zig");

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

    // Check for pending question prompt
    if (agent_state.getPendingQuestion()) |question| {
        if (try handleQuestionPrompt(app, agent_state, question, key)) {
            return;
        }
    }

    // Handle subagent drill-in modal when active (captures all keys)
    if (agent_state.hasSubagentModal()) {
        if (key.codepoint == 27 or key.codepoint == 'q') { // ESC or q
            agent_state.closeSubagentModal();
            app.needs_render = true;
            return;
        }
        if (key.codepoint == 'j' or key.codepoint == vaxis.Key.down) {
            if (agent_state.getSubagentModal()) |modal| {
                modal.scrollDown(modal.line_map.getTotalLines());
            }
            app.needs_render = true;
            return;
        }
        if (key.codepoint == 'k' or key.codepoint == vaxis.Key.up) {
            if (agent_state.getSubagentModal()) |modal| {
                modal.scrollUp();
            }
            app.needs_render = true;
            return;
        }
        // Ctrl+D - page down
        if (key.mods.ctrl and key.codepoint == 'd') {
            if (agent_state.getSubagentModal()) |modal| {
                const half_page = @max(1, agent_state.last_messages_viewport_height / 2);
                for (0..half_page) |_| {
                    modal.scrollDown(modal.line_map.getTotalLines());
                }
            }
            app.needs_render = true;
            return;
        }
        // Ctrl+U - page up
        if (key.mods.ctrl and key.codepoint == 'u') {
            if (agent_state.getSubagentModal()) |modal| {
                const half_page = @max(1, agent_state.last_messages_viewport_height / 2);
                for (0..half_page) |_| {
                    modal.scrollUp();
                }
            }
            app.needs_render = true;
            return;
        }
        // Consume all other keys when modal is active
        return;
    }

    // Check for pending approval prompt (unified across ACP + Codex)
    if (app.getActiveManager()) |mgr| {
        if (mgr.getPendingApproval()) |approval| {
            if (handleApprovalKeys(app, agent_state, mgr, approval, key)) {
                return;
            }
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

        // Enter - drill into subagent message (if cursor is on a subagent tool message with session_id)
        if (key.codepoint == vaxis.Key.enter) {
            if (agent_state.getMessageIdxAtCursorLine()) |msg_idx| {
                if (msg_idx < agent_state.messages.items.len) {
                    const msg = &agent_state.messages.items[msg_idx];
                    if (msg.subagent_info) |info| {
                        if (info.session_id) |session_id| {
                            const title = info.description orelse info.agent_type orelse "Subagent";
                            app.startSubagentModalFetch(session_id, title);
                            app.needs_render = true;
                            return;
                        }
                    }
                }
            }
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
            const tab = if (app.tab_manager) |*tm| tm.activeTab() else null;
            const cancelled = if (tab) |t| (if (t.manager) |m| m.cancelPrompt() else false) else false;

            if (cancelled) {
                agent_state.addMessage(.system, "Interrupted") catch |err| {
                    std.log.err("Failed to add interrupt message: {any}", .{err});
                };

                // Auto-execute staged shell commands after interrupt
                if (agent_state.hasStagedPrompt() and agent_state.isStagedShellCommand()) {
                    const staged = agent_state.getStagedPrompt();
                    handleShellCommand(app, agent_state, staged) catch |err| {
                        std.log.err("Failed to run staged shell command after interrupt: {any}", .{err});
                    };
                    agent_state.clearStagedPrompt();
                }

                app.needs_render = true;
                return;
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

                // Send to active agent (Opencode or ACP)
                try sendPromptToActiveManager(app, text);

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
            if (key.codepoint == 'b' or key.codepoint == 'h' or key.codepoint == 27) {
                // Space+b, Space+h, or Space+Esc - enter history mode (if messages exist)
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
            if (key.codepoint == 't') {
                // Space+t - cycle model variant (Opencode) or thinking effort (Codex)
                if (app.getActiveManager()) |mgr| {
                    switch (mgr) {
                        .opencode => |op| {
                            if (op.getCurrentModelId() == null) {
                                try agent_state.addMessage(.system, "Select a model to use variants");
                            } else if (op.cycleVariant()) |variant| {
                                const msg = std.fmt.allocPrint(app.allocator, "Variant: {s}", .{variant}) catch "Variant updated";
                                defer if (!std.mem.eql(u8, msg, "Variant updated")) app.allocator.free(msg);
                                try agent_state.addMessage(.system, msg);
                            } else {
                                try agent_state.addMessage(.system, "No variants available for current model");
                            }
                        },
                        .codex => |cm| {
                            const next_effort = getNextCodexReasoningEffort(cm);
                            cm.setReasoningEffort(next_effort);
                            var msg_buf: [64]u8 = undefined;
                            const msg = std.fmt.bufPrint(&msg_buf, "Thinking effort: {s}", .{next_effort.toString()}) catch "Thinking effort updated";
                            try agent_state.addMessage(.system, msg);
                        },
                        .acp => {
                            try agent_state.addMessage(.system, "Space+t is available for Opencode variants or Codex thinking effort");
                        },
                    }
                } else {
                    try agent_state.addMessage(.system, "No active agent");
                }
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

                // Handle typed local slash commands directly (without requiring slash-menu selection)
                if (text.len > 1 and text[0] == '/') {
                    const cmd_name = extractSlashCommandName(text);
                    if (cmd_name.len > 0 and state.AgentState.isLocalSlashCommand(cmd_name)) {
                        const args = extractCommandArgs(text, cmd_name);
                        try handleLocalCommand(app, agent_state, cmd_name, args);
                        agent_state.input.clear();
                        agent_state.hideSlashMenu();
                        app.needs_render = true;
                        return;
                    }
                }

                const is_thinking = app.isAgentThinking();
                const session_not_ready = app.isSessionInitializing();

                // Handle staged shell commands first - they can execute anytime with empty input
                if (text.len == 0 and agent_state.hasStagedPrompt() and agent_state.isStagedShellCommand()) {
                    const staged = agent_state.getStagedPrompt();
                    try handleShellCommand(app, agent_state, staged);
                    agent_state.clearStagedPrompt();
                    app.needs_render = true;
                    return; // Done - don't fall through to other handlers
                }
                // Handle staged message scenarios (agent thinking or session not ready)
                else if ((is_thinking or session_not_ready) and agent_state.hasStagedPrompt()) {
                    if (text.len == 0 and is_thinking) {
                        // Empty prompt + staged message + agent thinking = interrupt and send immediately
                        const staged = agent_state.getStagedPrompt();

                        // Interrupt agent and send staged message
                        const active_tab = if (app.tab_manager) |*tm| tm.activeTab() else null;
                        const interrupted = if (active_tab) |t| (if (t.manager) |m| m.cancelPrompt() else false) else false;
                        const interrupted_opencode = if (active_tab) |t| (if (t.manager) |m| switch (m) {
                            .opencode => interrupted,
                            .acp, .codex => false,
                        } else false) else false;
                        if (interrupted) {
                            std.log.info("Agent: Interrupted via staged message immediate send", .{});
                            try agent_state.addMessage(.system, "Interrupted");
                        }

                        if (interrupted and interrupted_opencode) {
                            // For Opencode, wait for session to return to idle before sending
                            return;
                        }

                        try agent_state.addMessage(.user, staged);

                        // Auto-name the tab from the first user prompt
                        app.autoNameActiveTab(staged);

                        // Send to active agent (Opencode or ACP)
                        try sendPromptToActiveManager(app, staged);

                        agent_state.clearStagedPrompt();
                    } else if (text.len == 0) {
                        // Empty prompt + staged message + session not ready = do nothing (already queued)
                        // Message will be sent automatically when session becomes ready
                    } else {
                        // Non-empty prompt + staged message = append to staged message
                        const current_staged = agent_state.getStagedPrompt();
                        const was_shell = agent_state.isStagedShellCommand();
                        var combined_buf: [8192]u8 = undefined;
                        const combined = std.fmt.bufPrint(&combined_buf, "{s}\n{s}", .{ current_staged, text }) catch text;
                        // Preserve the shell command flag when appending
                        if (was_shell) {
                            agent_state.stageShellCommand(combined);
                        } else {
                            agent_state.stagePrompt(combined);
                        }
                        agent_state.input.clear();
                    }
                } else if (text.len > 0) {
                    if (is_thinking or session_not_ready) {
                        // Agent thinking or session not ready - stage for later
                        if (agent_state.isShellMode()) {
                            agent_state.stageShellCommand(text);
                            agent_state.clearShellMode();
                        } else {
                            agent_state.stagePrompt(text);
                        }
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

                            // Send to active agent (Opencode or ACP)
                            try sendPromptToActiveManager(app, text);

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

fn getNextCodexReasoningEffort(cm: *CodexManager) codex_protocol.ReasoningEffort {
    const all_efforts = [_]codex_protocol.ReasoningEffort{ .low, .medium, .high, .xhigh };
    var supported: []const codex_protocol.ReasoningEffort = &all_efforts;
    var default_effort: ?codex_protocol.ReasoningEffort = null;

    const current_model_id = cm.current_model orelse cm.model;
    if (current_model_id) |model_id| {
        if (cm.models) |models| {
            for (models) |m| {
                if (!std.mem.eql(u8, m.id, model_id)) continue;
                if (m.supported_reasoning_efforts) |efforts| {
                    if (efforts.len > 0) {
                        supported = efforts;
                    }
                }
                default_effort = m.default_reasoning_effort;
                break;
            }
        }
    }

    const current = cm.reasoning_effort orelse default_effort orelse supported[0];
    var idx: usize = 0;
    while (idx < supported.len) : (idx += 1) {
        if (supported[idx] == current) {
            return supported[(idx + 1) % supported.len];
        }
    }
    return supported[0];
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
/// Handle shell command execution (commands starting with !)
/// Public so it can be called from app.zig for auto-executing staged shell commands
pub fn handleShellCommand(app: *App, agent_state: *agent.AgentState, command: []const u8) !void {
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

fn extractSlashCommandName(input: []const u8) []const u8 {
    if (input.len < 2 or input[0] != '/') return "";
    const after_slash = input[1..];
    if (std.mem.indexOfScalar(u8, after_slash, ' ')) |space_idx| {
        return after_slash[0..space_idx];
    }
    return after_slash;
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
        if (app.getActiveManager()) |mgr| {
            switch (mgr) {
                .codex => |cm| {
                    _ = cm.listModels() catch |err| {
                        std.log.err("Codex: failed to load model list: {any}", .{err});
                        try agent_state.addMessage(.system, "Failed to load Codex models");
                        return;
                    };
                },
                .acp, .opencode => {},
            }
        }

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

    if (std.mem.eql(u8, command_name, "thinking")) {
        if (app.getActiveManager()) |mgr| {
            switch (mgr) {
                .codex => |cm| {
                    const trimmed_args = std.mem.trim(u8, args, &std.ascii.whitespace);
                    if (trimmed_args.len == 0) {
                        const current = if (cm.reasoning_effort) |effort| effort.toString() else "default";
                        var status_buf: [128]u8 = undefined;
                        const status = std.fmt.bufPrint(&status_buf, "Thinking effort: {s} (options: low|medium|high|xhigh)", .{current}) catch "Thinking effort: default";
                        try agent_state.addMessage(.system, status);
                        return;
                    }

                    const effort_text = if (std.mem.indexOfAny(u8, trimmed_args, &std.ascii.whitespace)) |idx|
                        trimmed_args[0..idx]
                    else
                        trimmed_args;

                    if (codex_protocol.ReasoningEffort.fromString(effort_text)) |effort| {
                        cm.setReasoningEffort(effort);
                        var confirm_buf: [96]u8 = undefined;
                        const confirm = std.fmt.bufPrint(&confirm_buf, "Thinking effort set to: {s}", .{effort.toString()}) catch "Thinking effort updated";
                        try agent_state.addMessage(.system, confirm);
                    } else {
                        try agent_state.addMessage(.system, "Invalid thinking effort. Use: low, medium, high, or xhigh");
                    }
                    return;
                },
                .acp, .opencode => {
                    try agent_state.addMessage(.system, "Thinking settings are only available for Codex");
                    return;
                },
            }
        }
        try agent_state.addMessage(.system, "No active agent");
        return;
    }

    if (std.mem.eql(u8, command_name, "resume")) {
        // Discover available sessions for current project
        const cwd = app.state.git_repo_root;

        // Check active manager type to determine session discovery strategy
        const session_list = if (app.getActiveManager()) |mgr| blk: {
            switch (mgr) {
                .codex => |cm| {
                    // Use live thread listing from the connected CodexManager
                    const threads = cm.listThreads() catch |err| {
                        std.log.err("Failed to list codex threads: {any}", .{err});
                        // Fall back to file-based discovery
                        break :blk sessions.listSessions(app.allocator, .codex, cwd, 20) catch |err2| {
                            std.log.err("Fallback session discovery also failed: {any}", .{err2});
                            try agent_state.addMessage(.system, "No sessions found for this project");
                            return;
                        };
                    };
                    defer cm.freeThreadList(threads);
                    break :blk sessions.threadsToSessionInfos(app.allocator, threads) catch |err| {
                        std.log.err("Failed to convert threads to sessions: {any}", .{err});
                        try agent_state.addMessage(.system, "No sessions found for this project");
                        return;
                    };
                },
                .acp => |am| {
                    // Determine agent type from ACP manager name
                    const agent_type: sessions.AgentType = if (am.agent_name) |name| at: {
                        if (std.mem.indexOf(u8, name, "claude") != null or
                            std.mem.indexOf(u8, name, "Claude") != null)
                        {
                            break :at .claude_code;
                        } else if (std.mem.indexOf(u8, name, "codex") != null or
                            std.mem.indexOf(u8, name, "Codex") != null)
                        {
                            break :at .codex;
                        }
                        break :at .claude_code;
                    } else .claude_code;
                    break :blk sessions.listSessions(app.allocator, agent_type, cwd, 20) catch |err| {
                        std.log.err("Failed to discover sessions: {any}", .{err});
                        try agent_state.addMessage(.system, "No sessions found for this project");
                        return;
                    };
                },
                .opencode => {
                    try agent_state.addMessage(.system, "Session resume not supported for opencode");
                    return;
                },
            }
        } else blk: {
            // No active manager, fall back to claude_code file discovery
            break :blk sessions.listSessions(app.allocator, .claude_code, cwd, 20) catch |err| {
                std.log.err("Failed to discover sessions: {any}", .{err});
                try agent_state.addMessage(.system, "No sessions found for this project");
                return;
            };
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
        // (main loop calls pollAllManagers regularly - no need to block the key handler)
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

/// Route a prompt to the active manager (Opencode or ACP).
/// Tries Opencode manager first if available, then falls back to ACP.
/// MVP Limitation for Opencode: @file references and shell outputs are NOT supported
/// (sent as literal text or discarded).
pub fn sendPromptToActiveManager(app: *App, text: []const u8) !void {
    const tab = (if (app.tab_manager) |*tm| tm.activeTab() else null) orelse {
        if (app.getActiveAgentState()) |agent_state| {
            try agent_state.addMessage(.system, "No agent tab available");
        }
        return error.NoAgentTab;
    };
    const agent_state = &tab.agent_state;

    const m = tab.manager orelse {
        try agent_state.addMessage(.system, "No agent configured. Close and reopen panel.");
        return;
    };

    // Check if the manager can accept prompts (protocol-agnostic)
    if (m.getStatusMessage()) |msg| {
        try agent_state.addMessage(.system, msg);
        app.needs_render = true;
        return;
    }

    // Protocol-specific content building (ACP handles @file references, OpenCode/Codex are simpler)
    switch (m) {
        .opencode => |mgr| {
            if (std.mem.indexOf(u8, text, "@") != null) {
                std.log.info("Opencode MVP: @file references not supported, sending as literal text", .{});
            }
            if (agent_state.hasQueuedShellOutputs()) {
                std.log.info("Opencode MVP: Shell outputs not supported, discarding", .{});
                _ = agent_state.takeQueuedShellOutputs();
            }
            mgr.sendPrompt(text) catch |err| {
                std.log.err("Opencode: Failed to send prompt: {any}", .{err});
                try agent_state.addMessage(.system, "Failed to send prompt to Opencode");
            };
        },
        .codex => |mgr| {
            if (agent_state.hasQueuedShellOutputs()) {
                _ = agent_state.takeQueuedShellOutputs();
            }
            mgr.startTurn(text) catch |err| {
                std.log.err("Codex: Failed to start turn: {any}", .{err});
                try agent_state.addMessage(.system, "Failed to send prompt to Codex");
            };
        },
        .acp => |mgr| {
            try sendPromptWithFiles(app, mgr, text);
        },
    }
    app.needs_render = true;
}

/// Handle keyboard input for approval prompts (unified across ACP + Codex)
fn handleApprovalKeys(app: *App, agent_state: *state.AgentState, mgr: ManagerHandle, approval: ManagerHandle.PendingApproval, key: vaxis.Key) bool {
    // Allow scrolling during approval prompts
    if (key.mods.ctrl and key.codepoint == 'd') {
        agent_state.follow_bottom = false;
        const scroll_amount = @max(1, agent_state.last_messages_viewport_height / 2);
        agent_state.scrollDown(scroll_amount);
        app.needs_render = true;
        return true;
    }
    if (key.mods.ctrl and key.codepoint == 'u') {
        agent_state.follow_bottom = false;
        const scroll_amount = @max(1, agent_state.last_messages_viewport_height / 2);
        agent_state.scrollUp(scroll_amount);
        app.needs_render = true;
        return true;
    }

    switch (approval) {
        .acp_permission => |perm| return handleAcpPermissionKeys(app, mgr, perm, key),
        .codex_command => |a| switch (a.*) {
            .command => |*cmd| return handleCodexCommandKeys(app, mgr, cmd, key),
            else => return true,
        },
        .codex_file_change => |a| switch (a.*) {
            .file_change => |*fc| return handleCodexFileChangeKeys(app, mgr, fc, key),
            else => return true,
        },
        .codex_user_input => |a| switch (a.*) {
            .user_input => |*ui| return handleCodexUserInputKeys(app, mgr, ui, key),
            else => return true,
        },
    }
}

fn handleAcpPermissionKeys(app: *App, mgr: ManagerHandle, perm: *AcpManager.PendingPermission, key: vaxis.Key) bool {
    const num_options = perm.options.len;

    const is_down = (key.codepoint == 'n' and key.mods.ctrl) or
        key.codepoint == vaxis.Key.down or
        (key.codepoint == 'j' and !key.mods.ctrl);
    const is_up = (key.codepoint == 'p' and key.mods.ctrl) or
        key.codepoint == vaxis.Key.up or
        (key.codepoint == 'k' and !key.mods.ctrl);

    if (is_down and num_options > 0) {
        perm.selected_index = (perm.selected_index + 1) % num_options;
        app.needs_render = true;
        return true;
    }
    if (is_up and num_options > 0) {
        perm.selected_index = if (perm.selected_index == 0) num_options - 1 else perm.selected_index - 1;
        app.needs_render = true;
        return true;
    }

    // Enter/y/Y: confirm selected option
    if (key.codepoint == vaxis.Key.enter or key.codepoint == 'y' or key.codepoint == 'Y') {
        switch (mgr) {
            .acp => |m| m.respondToPermission(true) catch |err| {
                std.log.err("Agent: Failed to respond to permission: {any}", .{err});
            },
            else => {},
        }
        app.needs_render = true;
        return true;
    }

    // Escape / n: cancel/reject
    if (key.codepoint == 27 or key.codepoint == 'n' or key.codepoint == 'N') {
        switch (mgr) {
            .acp => |m| m.cancelPermission() catch |err| {
                std.log.err("Agent: Failed to cancel permission: {any}", .{err});
            },
            else => {},
        }
        app.needs_render = true;
        return true;
    }

    return true; // Consume all other keys
}

fn handleCodexCommandKeys(app: *App, mgr: ManagerHandle, cmd: anytype, key: vaxis.Key) bool {
    const Decision = CodexManager.CommandDecision;
    const decision_order = [_]Decision{ .accept, .accept_for_session, .accept_with_execpolicy_amendment, .decline, .cancel };

    const is_down = (key.codepoint == 'n' and key.mods.ctrl) or
        key.codepoint == vaxis.Key.down or
        (key.codepoint == 'j' and !key.mods.ctrl);
    const is_up = (key.codepoint == 'p' and key.mods.ctrl) or
        key.codepoint == vaxis.Key.up or
        (key.codepoint == 'k' and !key.mods.ctrl);

    if (is_down) {
        const cur_idx = findDecisionIndex(Decision, &decision_order, cmd.selected_decision);
        cmd.selected_decision = decision_order[(cur_idx + 1) % decision_order.len];
        app.needs_render = true;
        return true;
    }
    if (is_up) {
        const cur_idx = findDecisionIndex(Decision, &decision_order, cmd.selected_decision);
        cmd.selected_decision = decision_order[if (cur_idx == 0) decision_order.len - 1 else cur_idx - 1];
        app.needs_render = true;
        return true;
    }

    // y/Enter: accept (use current selection)
    if (key.codepoint == 'y' or key.codepoint == vaxis.Key.enter) {
        const decision_json = switch (cmd.selected_decision) {
            .accept => "\"accept\"",
            .accept_for_session => "\"acceptForSession\"",
            .accept_with_execpolicy_amendment => "\"accept\"", // Simplified — full amendment requires exec policy data
            .decline => "\"decline\"",
            .cancel => "\"cancel\"",
        };
        respondToCodexApproval(mgr, decision_json);
        app.needs_render = true;
        return true;
    }

    // Y: accept for session (shortcut)
    if (key.codepoint == 'Y') {
        respondToCodexApproval(mgr, "\"acceptForSession\"");
        app.needs_render = true;
        return true;
    }

    // n: decline
    if (key.codepoint == 'n') {
        respondToCodexApproval(mgr, "\"decline\"");
        app.needs_render = true;
        return true;
    }

    // ESC: cancel (decline + interrupt)
    if (key.codepoint == 27) {
        cancelCodexApproval(mgr);
        app.needs_render = true;
        return true;
    }

    return true; // Consume all other keys
}

fn handleCodexFileChangeKeys(app: *App, mgr: ManagerHandle, fc: anytype, key: vaxis.Key) bool {
    const Decision = CodexManager.FileChangeDecision;
    const decision_order = [_]Decision{ .accept, .accept_for_session, .decline, .cancel };

    const is_down = (key.codepoint == 'n' and key.mods.ctrl) or
        key.codepoint == vaxis.Key.down or
        (key.codepoint == 'j' and !key.mods.ctrl);
    const is_up = (key.codepoint == 'p' and key.mods.ctrl) or
        key.codepoint == vaxis.Key.up or
        (key.codepoint == 'k' and !key.mods.ctrl);

    if (is_down) {
        const cur_idx = findDecisionIndex(Decision, &decision_order, fc.selected_decision);
        fc.selected_decision = decision_order[(cur_idx + 1) % decision_order.len];
        app.needs_render = true;
        return true;
    }
    if (is_up) {
        const cur_idx = findDecisionIndex(Decision, &decision_order, fc.selected_decision);
        fc.selected_decision = decision_order[if (cur_idx == 0) decision_order.len - 1 else cur_idx - 1];
        app.needs_render = true;
        return true;
    }

    // y/Enter: accept
    if (key.codepoint == 'y' or key.codepoint == vaxis.Key.enter) {
        const decision_json = switch (fc.selected_decision) {
            .accept => "\"accept\"",
            .accept_for_session => "\"acceptForSession\"",
            .decline => "\"decline\"",
            .cancel => "\"cancel\"",
        };
        respondToCodexApproval(mgr, decision_json);
        app.needs_render = true;
        return true;
    }

    // Y: accept for session
    if (key.codepoint == 'Y') {
        respondToCodexApproval(mgr, "\"acceptForSession\"");
        app.needs_render = true;
        return true;
    }

    // n: decline
    if (key.codepoint == 'n') {
        respondToCodexApproval(mgr, "\"decline\"");
        app.needs_render = true;
        return true;
    }

    // ESC: cancel
    if (key.codepoint == 27) {
        cancelCodexApproval(mgr);
        app.needs_render = true;
        return true;
    }

    return true;
}

fn handleCodexUserInputKeys(app: *App, mgr: ManagerHandle, ui: anytype, key: vaxis.Key) bool {
    if (ui.questions.len == 0) return true;

    const q = &ui.questions[ui.active_question];

    const is_down = (key.codepoint == 'n' and key.mods.ctrl) or
        key.codepoint == vaxis.Key.down or
        (key.codepoint == 'j' and !key.mods.ctrl);
    const is_up = (key.codepoint == 'p' and key.mods.ctrl) or
        key.codepoint == vaxis.Key.up or
        (key.codepoint == 'k' and !key.mods.ctrl);

    if (q.options) |opts| {
        if (is_down and opts.len > 0) {
            q.selected_index = (q.selected_index + 1) % opts.len;
            app.needs_render = true;
            return true;
        }
        if (is_up and opts.len > 0) {
            q.selected_index = if (q.selected_index == 0) opts.len - 1 else q.selected_index - 1;
            app.needs_render = true;
            return true;
        }
    }

    // Tab: next question
    if (key.codepoint == vaxis.Key.tab and ui.questions.len > 1) {
        ui.active_question = (ui.active_question + 1) % ui.questions.len;
        app.needs_render = true;
        return true;
    }

    // Enter: submit
    if (key.codepoint == vaxis.Key.enter) {
        submitCodexUserInput(app.allocator, mgr, ui);
        app.needs_render = true;
        return true;
    }

    // ESC: cancel
    if (key.codepoint == 27) {
        cancelCodexApproval(mgr);
        app.needs_render = true;
        return true;
    }

    return true;
}

fn respondToCodexApproval(mgr: ManagerHandle, decision_json: []const u8) void {
    switch (mgr) {
        .codex => |m| m.respondToApproval(decision_json) catch |err| {
            std.log.err("Codex: Failed to respond to approval: {any}", .{err});
        },
        else => {},
    }
}

fn cancelCodexApproval(mgr: ManagerHandle) void {
    switch (mgr) {
        .codex => |m| m.cancelApproval() catch |err| {
            std.log.err("Codex: Failed to cancel approval: {any}", .{err});
        },
        else => {},
    }
}

fn submitCodexUserInput(allocator: std.mem.Allocator, mgr: ManagerHandle, ui: anytype) void {
    // Collect selected option labels as answers
    var answers_list: std.ArrayListUnmanaged([]const u8) = .{};
    defer answers_list.deinit(allocator);

    for (ui.questions) |q| {
        if (q.options) |opts| {
            if (q.selected_index < opts.len) {
                answers_list.append(allocator, opts[q.selected_index].label) catch continue;
            }
        }
    }

    switch (mgr) {
        .codex => |m| m.respondToUserInput(answers_list.items) catch |err| {
            std.log.err("Codex: Failed to respond to user input: {any}", .{err});
        },
        else => {},
    }
}

fn findDecisionIndex(comptime T: type, decisions: []const T, current: T) usize {
    for (decisions, 0..) |d, i| {
        if (d == current) return i;
    }
    return 0;
}

fn handleQuestionPrompt(app: *App, agent_state: *state.AgentState, pending: *state.PendingQuestion, key: vaxis.Key) !bool {
    if (pending.questions.len == 0) return false;

    // Confirmation view: only accept enter (submit) or esc/backspace (go back)
    if (pending.confirming) {
        if (key.codepoint == vaxis.Key.enter) {
            try submitPendingQuestion(app, agent_state, pending);
            return true;
        }
        if (key.codepoint == 27 or key.codepoint == vaxis.Key.backspace or
            (key.codepoint == 'h' and !key.mods.ctrl))
        {
            pending.confirming = false;
            app.needs_render = true;
            return true;
        }
        return true;
    }

    const question = &pending.questions[pending.active_index];
    const q_state = &pending.states[pending.active_index];
    const options_len = question.options.len;

    const is_down = (key.codepoint == 'n' and key.mods.ctrl) or
        key.codepoint == vaxis.Key.down or
        (key.codepoint == 'j' and !key.mods.ctrl);
    const is_up = (key.codepoint == 'p' and key.mods.ctrl) or
        key.codepoint == vaxis.Key.up or
        (key.codepoint == 'k' and !key.mods.ctrl);
    const is_next = key.codepoint == vaxis.Key.tab or
        key.codepoint == vaxis.Key.right or
        (key.codepoint == 'l' and !key.mods.ctrl);
    const is_prev = (key.mods.shift and key.codepoint == vaxis.Key.tab) or
        key.codepoint == vaxis.Key.left or
        (key.codepoint == 'h' and !key.mods.ctrl);

    if (q_state.custom_active) {
        if (key.codepoint == vaxis.Key.enter) {
            try advanceQuestionOrSubmit(app, agent_state, pending);
            return true;
        }
        if (key.codepoint == 27) {
            q_state.custom_active = false;
            app.needs_render = true;
            return true;
        }
        _ = try agent.InputEditor.handleKey(&q_state.custom_input, key, app.allocator);
        app.needs_render = true;
        return true;
    }

    if (is_next and pending.questions.len > 1) {
        q_state.custom_active = false;
        pending.active_index = (pending.active_index + 1) % pending.questions.len;
        app.needs_render = true;
        return true;
    }

    if (is_prev and pending.questions.len > 1) {
        q_state.custom_active = false;
        pending.active_index = if (pending.active_index == 0) pending.questions.len - 1 else pending.active_index - 1;
        app.needs_render = true;
        return true;
    }

    if (is_down and options_len > 0) {
        q_state.cursor_index = (q_state.cursor_index + 1) % options_len;
        app.needs_render = true;
        return true;
    }
    if (is_up and options_len > 0) {
        q_state.cursor_index = if (q_state.cursor_index == 0) options_len - 1 else q_state.cursor_index - 1;
        app.needs_render = true;
        return true;
    }

    if (key.codepoint >= '1' and key.codepoint <= '9' and options_len > 0) {
        const idx = @as(usize, @intCast(key.codepoint - '1'));
        if (idx < options_len) {
            q_state.cursor_index = idx;
            if (question.multiple) {
                q_state.selected[idx] = !q_state.selected[idx];
                if (question.options[idx].is_custom and q_state.selected[idx]) {
                    q_state.custom_active = true;
                }
            } else {
                @memset(q_state.selected, false);
                q_state.selected[idx] = true;
                if (question.options[idx].is_custom) {
                    q_state.custom_active = true;
                }
            }
            app.needs_render = true;
            return true;
        }
    }

    if (question.multiple and key.codepoint == ' ' and options_len > 0) {
        const idx = q_state.cursor_index;
        q_state.selected[idx] = !q_state.selected[idx];
        if (question.options[idx].is_custom and q_state.selected[idx]) {
            q_state.custom_active = true;
        }
        app.needs_render = true;
        return true;
    }

    if (key.codepoint == vaxis.Key.enter) {
        if (question.multiple) {
            try advanceQuestionOrSubmit(app, agent_state, pending);
            return true;
        }

        if (options_len > 0) {
            const idx = q_state.cursor_index;
            @memset(q_state.selected, false);
            q_state.selected[idx] = true;
            if (question.options[idx].is_custom and q_state.custom_input.getText().len == 0) {
                q_state.custom_active = true;
                app.needs_render = true;
                return true;
            }
        }

        try advanceQuestionOrSubmit(app, agent_state, pending);
        return true;
    }

    if (key.codepoint == 27) {
        // For OpenCode: reject the question via the dedicated endpoint
        if (pending.id) |request_id| {
            const tab = if (app.tab_manager) |*tm| tm.activeTab() else null;
            if (tab) |t| {
                if (t.manager) |m| {
                    if (m == .opencode) {
                        m.opencode.rejectQuestion(request_id) catch |err| {
                            std.log.err("Failed to reject question: {}", .{err});
                        };
                    }
                }
            }
        }
        agent_state.clearPendingQuestion();
        app.needs_render = true;
        return true;
    }

    // Allow scrolling during question prompts
    if (key.mods.ctrl and key.codepoint == 'd') {
        agent_state.follow_bottom = false;
        const scroll_amount = @max(1, agent_state.last_messages_viewport_height / 2);
        agent_state.scrollDown(scroll_amount);
        app.needs_render = true;
        return true;
    }

    if (key.mods.ctrl and key.codepoint == 'u') {
        agent_state.follow_bottom = false;
        const scroll_amount = @max(1, agent_state.last_messages_viewport_height / 2);
        agent_state.scrollUp(scroll_amount);
        app.needs_render = true;
        return true;
    }

    return true;
}

fn advanceQuestionOrSubmit(app: *App, agent_state: *state.AgentState, pending: *state.PendingQuestion) !void {
    _ = agent_state;
    if (pending.active_index + 1 < pending.questions.len) {
        pending.active_index += 1;
        app.needs_render = true;
        return;
    }
    // Show confirmation view before submitting
    pending.confirming = true;
    app.needs_render = true;
}

fn submitPendingQuestion(app: *App, agent_state: *state.AgentState, pending: *state.PendingQuestion) !void {
    const tab = (if (app.tab_manager) |*tm| tm.activeTab() else null) orelse return;
    const m = tab.manager orelse return;

    // For OpenCode: use the dedicated question reply endpoint with structured answers
    if (m == .opencode) {
        if (pending.id) |request_id| {
            const answers = buildQuestionAnswers(app.allocator, pending) catch null;
            defer {
                if (answers) |a| {
                    for (a) |inner| app.allocator.free(inner);
                    app.allocator.free(a);
                }
            }

            if (answers) |a| {
                // Show the answer in the chat as a user message
                const display = agent_state.buildPendingQuestionAnswer(app.allocator) catch null;
                if (display) |text| {
                    defer app.allocator.free(text);
                    agent_state.addMessage(.user, text) catch {};
                }

                m.opencode.respondToQuestion(request_id, a) catch |err| {
                    std.log.err("Failed to reply to question: {}", .{err});
                    try agent_state.addMessage(.system, "Failed to send question reply");
                };
                agent_state.clearPendingQuestion();
                app.needs_render = true;
                return;
            }
        }
        // Fallback: no request ID or answer building failed — send as text prompt
        std.log.warn("Question has no request ID, falling back to text prompt", .{});
    }

    // ACP / fallback: send answer as a regular text prompt
    const answer_opt = try agent_state.buildPendingQuestionAnswer(app.allocator);
    const answer = answer_opt orelse return;
    defer app.allocator.free(answer);

    try agent_state.addMessage(.user, answer);
    try sendPromptToActiveManager(app, answer);
    agent_state.clearPendingQuestion();
    app.needs_render = true;
}

/// Build 2D answers array for the OpenCode question reply endpoint.
/// Returns `[]const []const []const u8` — caller owns all allocations.
fn buildQuestionAnswers(allocator: std.mem.Allocator, pending: *state.PendingQuestion) ![]const []const []const u8 {
    var outer: std.ArrayList([]const []const u8) = .{};
    errdefer {
        for (outer.items) |inner| allocator.free(inner);
        outer.deinit(allocator);
    }

    for (pending.questions, 0..) |question, qi| {
        const q_state = pending.states[qi];
        var inner: std.ArrayList([]const u8) = .{};
        errdefer inner.deinit(allocator);

        for (question.options, 0..) |opt, oi| {
            if (!q_state.selected[oi]) continue;
            if (opt.is_custom) {
                const custom_text = std.mem.trim(u8, q_state.custom_input.getText(), &std.ascii.whitespace);
                if (custom_text.len > 0) {
                    try inner.append(allocator, custom_text);
                    continue;
                }
            }
            try inner.append(allocator, opt.label);
        }

        try outer.append(allocator, try inner.toOwnedSlice(allocator));
    }

    return try outer.toOwnedSlice(allocator);
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
