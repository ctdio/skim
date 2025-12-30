const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const sessions = @import("../acp/sessions.zig");

/// Handle keyboard input when in session picker mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    const session_count = app.state.session_list.len;

    if (session_count == 0) {
        // No sessions - go back to agent mode
        app.mode = .agent;
        return;
    }

    // Handle Ctrl+key combinations
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n' => {
                app.state.session_selection = (app.state.session_selection + 1) % session_count;
                return;
            },
            'p' => {
                app.state.session_selection = if (app.state.session_selection == 0) session_count - 1 else app.state.session_selection - 1;
                return;
            },
            else => {},
        }
    }

    // Handle arrow keys
    if (key.codepoint == vaxis.Key.down) {
        app.state.session_selection = (app.state.session_selection + 1) % session_count;
        return;
    }
    if (key.codepoint == vaxis.Key.up) {
        app.state.session_selection = if (app.state.session_selection == 0) session_count - 1 else app.state.session_selection - 1;
        return;
    }

    // Handle special keys
    switch (key.codepoint) {
        'j' => {
            app.state.session_selection = (app.state.session_selection + 1) % session_count;
        },
        'k' => {
            app.state.session_selection = if (app.state.session_selection == 0) session_count - 1 else app.state.session_selection - 1;
        },
        27 => { // ESC key - go back to agent mode
            freeSessionList(app);
            app.mode = .agent;
        },
        '\r' => { // Enter key - load selected session
            try loadSelectedSession(app);
        },
        else => {},
    }
}

/// Load the currently selected session
fn loadSelectedSession(app: *App) !void {
    if (app.state.session_list.len == 0) return;

    const selected = app.state.session_list[app.state.session_selection];
    const session_id = selected.id;

    // Get the ACP manager
    const mgr = app.acp_manager orelse {
        freeSessionList(app);
        app.mode = .agent;
        return;
    };

    // Try to resume the session via ACP
    std.log.info("Session picker: resuming session {s}", .{session_id});

    // Get CWD from the session or use current
    const cwd = if (selected.project_path.len > 0) selected.project_path else app.state.git_repo_root;

    // Note: Codex sessions are filtered out in discovery - codex-acp doesn't support resume

    // Use ACP protocol for session resume
    if (mgr.acp_client) |acp_client| {
        // Check if agent supports sessionCapabilities.resume
        const supports_resume = if (acp_client.agent_capabilities) |caps| caps.session_capabilities.@"resume" else false;

        if (supports_resume) {
            // Use the proper resumeSession method (session/new with resume option)
            _ = acp_client.resumeSession(session_id, cwd) catch |err| {
                std.log.err("Session picker: failed to resume session: {any}", .{err});
                if (app.state.agent_state) |*agent_state| {
                    agent_state.addMessage(
                        .system,
                        "Failed to resume session. The agent may not have this session in its history.",
                    ) catch {};
                }
                freeSessionList(app);
                app.mode = .agent;
                return;
            };

            // Session resumed successfully - display conversation history
            if (app.state.agent_state) |*agent_state| {
                // Clear existing messages and show history
                agent_state.clearMessages();

                // Parse and display session history
                displaySessionHistory(app, selected) catch {
                    agent_state.addMessage(.system, "Session resumed (couldn't load history display).") catch {};
                };
            }
        } else {
            // Agent doesn't support resume - try session/load as fallback
            std.log.info("Session picker: agent doesn't support resume, trying session/load", .{});
            _ = acp_client.loadSession(session_id, cwd) catch |err| {
                std.log.err("Session picker: session/load failed: {any}", .{err});

                // Final fallback: inject history as context
                std.log.info("Session picker: attempting fallback - injecting history as context", .{});
                const injected = injectHistoryAsContext(app, selected) catch |fallback_err| {
                    std.log.err("Session picker: fallback also failed: {any}", .{fallback_err});
                    if (app.state.agent_state) |*agent_state| {
                        agent_state.addMessage(
                            .system,
                            "Could not load session. The agent doesn't support session resume and the session file couldn't be read.",
                        ) catch {};
                    }
                    freeSessionList(app);
                    app.mode = .agent;
                    return;
                };

                if (injected) {
                    // Display the history in the UI (context was already sent to agent)
                    if (app.state.agent_state) |*agent_state| {
                        agent_state.clearMessages();
                        displaySessionHistoryWithMode(app, selected, true) catch {
                            agent_state.addMessage(.system, "Session context sent (couldn't display history).") catch {};
                        };
                    }
                }
                freeSessionList(app);
                app.mode = .agent;
                return;
            };

            // session/load succeeded
            if (app.state.agent_state) |*agent_state| {
                agent_state.addMessage(.system, "Session loaded successfully.") catch {};
            }
        }
    }

    // Clean up and return to agent mode
    freeSessionList(app);
    app.mode = .agent;
}

/// Display conversation history from a session in the UI
fn displaySessionHistory(app: *App, session_info: sessions.SessionInfo) !void {
    displaySessionHistoryWithMode(app, session_info, false) catch |err| return err;
}

/// Display conversation history with mode indicator
/// context_injected: true if history was injected as context (not native resume)
fn displaySessionHistoryWithMode(app: *App, session_info: sessions.SessionInfo, context_injected: bool) !void {
    const agent_state = &(app.state.agent_state orelse return error.NoAgentState);

    // Parse session file based on agent type
    const history = switch (session_info.agent_type) {
        .claude_code => try sessions.parseClaudeSession(
            app.allocator,
            session_info.id,
            session_info.project_path,
        ),
        .codex => try sessions.parseCodexSession(
            app.allocator,
            session_info.id,
        ),
    };
    defer sessions.freeMessages(app.allocator, history);

    if (history.len == 0) {
        const msg = if (context_injected) "Context sent (no history to display)." else "Session resumed (no history to display).";
        try agent_state.addMessage(.system, msg);
        return;
    }

    std.log.info("Session picker: displaying {d} messages from history", .{history.len});

    // Add each message to the UI
    for (history) |msg| {
        const role: @import("../agent/state.zig").Message.Role = switch (msg.role) {
            .user => .user,
            .assistant => .agent,
            .system => .system,
        };
        try agent_state.addMessage(role, msg.content);
    }

    const marker = if (context_injected) "--- Context injected (agent has history) ---" else "--- Session resumed ---";
    try agent_state.addMessage(.system, marker);
}

/// Free the session list and reset state
fn freeSessionList(app: *App) void {
    sessions.freeSessions(app.allocator, app.state.session_list);
    app.state.session_list = &[_]sessions.SessionInfo{};
    app.state.session_selection = 0;
}

/// Fallback: inject conversation history as context to the agent
/// This sends the previous conversation as a prompt so the agent has context
fn injectHistoryAsContext(app: *App, session_info: sessions.SessionInfo) !bool {
    const agent_state = &(app.state.agent_state orelse return error.NoAgentState);
    const mgr = app.acp_manager orelse return error.NoAgentState;

    // Re-create a session since the previous attempt may have cleared it
    const cwd = if (session_info.project_path.len > 0) session_info.project_path else app.state.git_repo_root;
    if (mgr.acp_client) |acp_client| {
        if (acp_client.session_id == null) {
            std.log.info("Session picker: fallback - creating new session for context injection", .{});
            _ = acp_client.createSession(cwd) catch |err| {
                std.log.err("Session picker: fallback - failed to create session: {any}", .{err});
                return err;
            };
        }
    }

    // Parse session file based on agent type
    const history = switch (session_info.agent_type) {
        .claude_code => sessions.parseClaudeSession(
            app.allocator,
            session_info.id,
            session_info.project_path,
        ) catch |err| {
            std.log.err("Session picker: failed to parse Claude session: {any}", .{err});
            return err;
        },
        .codex => sessions.parseCodexSession(
            app.allocator,
            session_info.id,
        ) catch |err| {
            std.log.err("Session picker: failed to parse Codex session: {any}", .{err});
            return err;
        },
    };
    defer sessions.freeMessages(app.allocator, history);

    if (history.len == 0) {
        std.log.info("Session picker: session file was empty or had no parseable messages", .{});
        return false;
    }

    std.log.info("Session picker: loaded {d} messages from session history", .{history.len});

    // Build context message from history
    var context_buf: std.ArrayList(u8) = .{};
    defer context_buf.deinit(app.allocator);

    context_buf.appendSlice(app.allocator, "This is a continuation of a previous conversation. Here's the conversation history:\n\n") catch return error.OutOfMemory;

    for (history) |msg| {
        const role_label = switch (msg.role) {
            .user => "User",
            .assistant => "Assistant",
            .system => "System",
        };

        // Truncate very long messages
        const max_len: usize = 1500;
        const content = if (msg.content.len > max_len)
            msg.content[0..max_len]
        else
            msg.content;

        context_buf.appendSlice(app.allocator, role_label) catch {};
        context_buf.appendSlice(app.allocator, ": ") catch {};
        context_buf.appendSlice(app.allocator, content) catch {};
        if (msg.content.len > max_len) {
            context_buf.appendSlice(app.allocator, "...[truncated]") catch {};
        }
        context_buf.appendSlice(app.allocator, "\n\n") catch {};
    }

    context_buf.appendSlice(app.allocator, "---\nPlease continue from where we left off. Acknowledge that you have this context but don't repeat it - just be ready to help with follow-up questions or continue the task.") catch {};

    // Clear UI messages
    agent_state.clearMessages();

    // Show context injection in UI
    try agent_state.addMessage(.system, "Injecting previous conversation as context...");

    // Send context to agent
    const context_msg = context_buf.items;
    std.log.info("Session picker: sending {d} byte context to agent", .{context_msg.len});

    mgr.sendPrompt(context_msg) catch |err| {
        std.log.err("Session picker: failed to send context: {any}", .{err});
        return err;
    };

    return true;
}
