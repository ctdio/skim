/// Tagged union wrapping ACP, OpenCode, and Codex manager types.
/// Provides a unified interface for operations needed by agent_mode.zig and tab_manager.zig.
/// Protocol-specific features remain accessible via pattern matching on the union.
const std = @import("std");
const Allocator = std.mem.Allocator;
const AcpManager = @import("../acp/manager.zig").AcpManager;
const OpencodeManager = @import("../opencode/opencode.zig").OpencodeManager;
const CodexManager = @import("../codex/manager.zig").CodexManager;
const CodexCodec = @import("../codex/codec.zig");
const CodexProcess = @import("../codex/process.zig").CodexProcess;
const CodexTransport = @import("../codex/transport.zig").StdioTransport;
const AgentState = @import("state.zig").AgentState;
const AgentEvent = @import("events.zig").AgentEvent;
const processAgentEvent = @import("events.zig").processAgentEvent;
const acpMessageToAgentEvent = @import("events.zig").acpMessageToAgentEvent;
const opencodeEventToAgentEvent = @import("events.zig").opencodeEventToAgentEvent;
const codexEventToAgentEvent = @import("events.zig").codexEventToAgentEvent;
pub const ManagerHandle = union(enum) {
    acp: *AcpManager,
    opencode: *OpencodeManager,
    codex: *CodexManager,

    // =========================================================================
    // Common operations
    // =========================================================================

    /// Cancel the current prompt. Returns true if cancellation was sent.
    pub fn cancelPrompt(self: ManagerHandle) bool {
        return switch (self) {
            .acp => |m| m.cancelPrompt(),
            .opencode => |m| m.cancelPrompt(),
            .codex => |m| {
                m.interruptTurn() catch return false;
                return true;
            },
        };
    }

    /// Check if the agent is currently thinking/prompting.
    pub fn isPrompting(self: ManagerHandle) bool {
        return switch (self) {
            .acp => |m| m.isPrompting(),
            .opencode => |m| m.isThinking(),
            .codex => |m| m.status == .turn_active,
        };
    }

    /// Check if the agent is currently compacting context.
    pub fn isCompacting(self: ManagerHandle) bool {
        return switch (self) {
            .acp => false,
            .opencode => |m| m.isCompacting(),
            .codex => false,
        };
    }

    /// Check if the session is ready to accept prompts.
    pub fn isReady(self: ManagerHandle) bool {
        return switch (self) {
            .acp => |m| m.status == .session_active or m.status == .prompting,
            .opencode => |m| !m.pending_abort and m.isReadyForPrompt(),
            .codex => |m| m.status == .thread_active,
        };
    }

    /// Check if the manager is disconnected.
    pub fn isDisconnected(self: ManagerHandle) bool {
        return switch (self) {
            .acp => |m| m.status == .disconnected,
            .opencode => |m| m.status == .disconnected,
            .codex => |m| m.status == .disconnected,
        };
    }

    /// Check if the session is initializing (discovering, connecting, etc.).
    pub fn isInitializing(self: ManagerHandle) bool {
        return switch (self) {
            .acp => |m| m.status == .discovering or m.status == .connecting or m.status == .connected,
            .opencode => |m| m.status == .idle or m.status == .starting_server or m.status == .connecting,
            .codex => |m| m.status == .connecting or m.status == .initialized,
        };
    }

    /// Get the current model ID (for highlighting in model picker).
    pub fn getCurrentModelId(self: ManagerHandle) ?[]const u8 {
        return switch (self) {
            .acp => |m| m.getCurrentModelId(),
            .opencode => |m| m.getCurrentModelId(),
            .codex => |m| m.current_model orelse m.model,
        };
    }

    /// Get the current model display name.
    pub fn getCurrentModelName(self: ManagerHandle) []const u8 {
        return switch (self) {
            .acp => |m| m.getCurrentModelName(),
            .opencode => |m| m.getCurrentModelName(),
            .codex => |m| m.current_model orelse m.model orelse "Codex",
        };
    }

    /// Resolved model view for the UI — protocol-independent.
    pub const ModelView = struct {
        model_id: []const u8,
        name: []const u8,
        description: []const u8,
    };

    /// Get the number of available models.
    pub fn getModelCount(self: ManagerHandle) usize {
        return switch (self) {
            .acp => |m| m.getAvailableModels().len,
            .opencode => |m| m.getAvailableModels().len,
            .codex => |m| if (m.models) |models| models.len else 0,
        };
    }

    /// Get a resolved model view at the given index.
    pub fn getModelInfo(self: ManagerHandle, idx: usize) ModelView {
        return switch (self) {
            .acp => |m| {
                const model = m.getAvailableModels()[idx];
                return .{
                    .model_id = model.model_id,
                    .name = model.name orelse model.model_id,
                    .description = model.description orelse "",
                };
            },
            .opencode => |m| {
                const model = m.getAvailableModels()[idx];
                return .{
                    .model_id = model.model_id,
                    .name = model.name orelse model.model_id,
                    .description = model.description orelse "",
                };
            },
            .codex => |m| {
                const models = m.models orelse return .{ .model_id = "", .name = "Codex", .description = "" };
                if (idx >= models.len) return .{ .model_id = "", .name = "Codex", .description = "" };
                const model = models[idx];
                return .{
                    .model_id = model.id,
                    .name = model.display_name orelse model.id,
                    .description = model.description orelse "",
                };
            },
        };
    }

    /// Set model by ID (from picker selection).
    pub fn setModelById(self: ManagerHandle, id: []const u8) !void {
        switch (self) {
            .acp => |m| try m.setModel(id),
            .opencode => |m| try m.setModelById(id),
            .codex => |m| try m.setModel(id),
        }
    }

    /// Unified pending approval — wraps ACP permissions and Codex approvals.
    pub const PendingApproval = union(enum) {
        acp_permission: *AcpManager.PendingPermission,
        codex_command: *CodexManager.PendingApproval,
        codex_file_change: *CodexManager.PendingApproval,
        codex_user_input: *CodexManager.PendingApproval,
    };

    /// Get the pending approval request, if any.
    pub fn getPendingApproval(self: ManagerHandle) ?PendingApproval {
        return switch (self) {
            .acp => |m| {
                if (m.getPendingPermission()) |perm| {
                    return .{ .acp_permission = perm };
                }
                return null;
            },
            .opencode => null,
            .codex => |m| {
                if (m.getPendingApproval()) |approval| {
                    return switch (approval.*) {
                        .command => .{ .codex_command = approval },
                        .file_change => .{ .codex_file_change = approval },
                        .user_input => .{ .codex_user_input = approval },
                    };
                }
                return null;
            },
        };
    }

    /// Check if there is any pending approval (convenience for tab_manager).
    pub fn hasPendingApproval(self: ManagerHandle) bool {
        return self.getPendingApproval() != null;
    }

    /// Get a display name for the agent/server.
    pub fn getDisplayName(self: ManagerHandle) []const u8 {
        return switch (self) {
            .acp => |m| m.server_name orelse m.agent_name orelse "Agent",
            .opencode => "Opencode",
            .codex => "Codex",
        };
    }

    // =========================================================================
    // Unified polling and prompt management
    // =========================================================================

    pub const PollResult = struct {
        count: usize,
        more_pending: bool,
        status_changed: bool,
        needs_line_map_dirty: bool,
    };

    /// Poll events from the underlying manager and process them inline.
    /// Events are processed via processAgentEvent while their backing data is still alive,
    /// avoiding use-after-free for OpenCode events which are freed after each iteration.
    pub fn pollEvents(self: ManagerHandle, allocator: Allocator, agent_state: *AgentState) PollResult {
        return switch (self) {
            .acp => |m| pollAcp(m, agent_state),
            .opencode => |m| pollOpencode(m, allocator, agent_state),
            .codex => |m| pollCodex(m, agent_state),
        };
    }

    /// Send a text prompt to the agent.
    pub fn sendPrompt(self: ManagerHandle, text: []const u8) !void {
        switch (self) {
            .acp => |m| try m.sendPrompt(text),
            .opencode => |m| try m.sendPrompt(text),
            .codex => |m| try m.startTurn(text),
        }
    }

    /// Check if the manager is ready to accept a new prompt (for user-initiated sends).
    pub fn isReadyForPrompt(self: ManagerHandle) bool {
        return switch (self) {
            .acp => |m| m.status == .session_active or m.status == .prompting,
            .opencode => |m| m.isReadyForPrompt() and !m.pending_abort,
            .codex => |m| m.status == .thread_active,
        };
    }

    /// Check if the manager is ready for automatic staged-prompt delivery.
    pub fn isReadyForAutoSend(self: ManagerHandle) bool {
        return switch (self) {
            .acp => |m| m.status == .session_active and m.pending_prompt_id == null,
            .opencode => |m| m.isReadyForAutoSend() and !m.pending_abort,
            .codex => |m| m.status == .thread_active,
        };
    }

    /// Check if the manager has activity requiring responsive polling.
    pub fn hasActivity(self: ManagerHandle) bool {
        return switch (self) {
            .acp => |m| m.hasPendingOutput(),
            .opencode => |m| m.status == .prompting or m.hasPendingEvents() or m.pending_abort,
            .codex => |m| m.status == .turn_active,
        };
    }

    /// Return a static error string when the manager cannot accept prompts, null when ready.
    pub fn getStatusMessage(self: ManagerHandle) ?[]const u8 {
        return switch (self) {
            .acp => |m| switch (m.status) {
                .disconnected => "Agent disconnected. Close and reopen panel to reconnect.",
                .failed => "Agent connection failed. Close and reopen panel to retry.",
                .discovering, .connecting, .connected => "Agent connecting... please wait.",
                .session_active, .prompting => null,
            },
            .opencode => |m| switch (m.status) {
                .disconnected, .failed => "Opencode disconnected or failed. Close and reopen panel to reconnect.",
                .idle, .starting_server, .connecting => "Opencode connecting... please wait.",
                .session_active, .prompting => if (m.pending_abort) "Cancelling... please wait." else null,
            },
            .codex => |m| switch (m.status) {
                .disconnected, .@"error" => "Codex disconnected or failed. Close and reopen panel to reconnect.",
                .connecting, .initialized => "Codex connecting... please wait.",
                .thread_active, .turn_active => null,
            },
        };
    }

    // =========================================================================
    // Lifecycle
    // =========================================================================

    /// Deinitialize the manager.
    pub fn deinit(self: ManagerHandle) void {
        switch (self) {
            .acp => |m| m.deinit(),
            .opencode => |m| m.deinit(),
            .codex => |m| m.deinit(),
        }
    }

    /// Check if the manager can be safely destroyed (freed).
    pub fn canSafelyDestroy(self: ManagerHandle) bool {
        return switch (self) {
            .acp => true,
            .opencode => |m| m.canSafelyDestroy(),
            .codex => true,
        };
    }
};

// =============================================================================
// Per-protocol polling helpers (private)
// =============================================================================

const MAX_ACP_MESSAGES_PER_FRAME: usize = 20;
const MAX_OPENCODE_EVENTS_PER_FRAME: usize = 50;

fn pollAcp(m: *AcpManager, agent_state: *AgentState) ManagerHandle.PollResult {
    const status_before = m.status;

    const messages = m.poll() catch return .{
        .count = 0,
        .more_pending = false,
        .status_changed = false,
        .needs_line_map_dirty = false,
    };

    const to_process = @min(messages.len, MAX_ACP_MESSAGES_PER_FRAME);

    var count: usize = 0;
    for (messages[0..to_process]) |msg| {
        if (acpMessageToAgentEvent(msg)) |event| {
            processAgentEvent(agent_state, event);
            count += 1;
        }
    }

    m.clearMessagesN(to_process);

    return .{
        .count = count,
        .more_pending = messages.len > to_process,
        .status_changed = m.status != status_before,
        .needs_line_map_dirty = false,
    };
}

fn pollOpencode(m: *OpencodeManager, allocator: Allocator, agent_state: *AgentState) ManagerHandle.PollResult {
    const status_before = m.status;
    var count: usize = 0;
    var events_polled: usize = 0;
    var more_pending = false;

    while (m.poll()) |ev| {
        events_polled += 1;
        if (events_polled > MAX_OPENCODE_EVENTS_PER_FRAME) {
            more_pending = true;
            var event_copy = ev;
            event_copy.deinit(m.event_allocator);
            break;
        }
        var event = ev;
        defer event.deinit(m.event_allocator);

        m.last_event_ms = std.time.milliTimestamp();

        // Protocol-specific status management
        switch (event) {
            .message_chunk, .thinking_chunk => {
                m.stream_complete.store(false, .release);
                if (m.status != .prompting and !m.pending_abort) {
                    m.status = .prompting;
                }
            },
            .message_complete => {
                if (m.status == .prompting) {
                    m.status = .session_active;
                }
            },
            .status_change => |new_status| {
                m.status = new_status;
            },
            .err => {
                m.status = .failed;
            },
            .question_prompt => |prompt| {
                // Convert and process inline while event data is still alive.
                // convertQuestionPrompt creates temporary arrays that borrow strings
                // from the event; setPendingQuestion (called by processAgentEvent)
                // dupes everything, so we free the temporary arrays immediately after.
                if (convertQuestionPrompt(allocator, prompt)) |agent_event| {
                    processAgentEvent(agent_state, agent_event);
                    count += 1;
                    // Free temporary question prompt allocations
                    const prompt_data = agent_event.question_prompt;
                    for (prompt_data.questions) |q| {
                        if (q.options.len > 0) allocator.free(q.options);
                    }
                    allocator.free(prompt_data.questions);
                }
                continue; // Skip the generic conversion below
            },
            else => {},
        }

        // Process event inline while data is still alive
        if (opencodeEventToAgentEvent(allocator, event)) |agent_event| {
            defer switch (agent_event) {
                .commands_update => |commands| allocator.free(commands),
                else => {},
            };
            processAgentEvent(agent_state, agent_event);
            count += 1;
        }
    }

    // Post-poll maintenance: abort timeout
    if (m.pending_abort) {
        const now_ms = std.time.milliTimestamp();
        const last_event_ms = if (m.last_event_ms == 0) m.pending_abort_since_ms else m.last_event_ms;
        const idle_ms = now_ms - last_event_ms;
        const pending_ms = now_ms - m.pending_abort_since_ms;
        if (!m.hasPendingEvents() and pending_ms > 2000 and idle_ms > 500) {
            std.log.info("Opencode: abort timeout elapsed; clearing pending_abort", .{});
            m.pending_abort = false;
            m.pending_abort_since_ms = 0;
            if (m.status == .prompting) {
                m.status = .session_active;
            }
        }
    }

    return .{
        .count = count,
        .more_pending = more_pending or m.hasPendingEvents(),
        .status_changed = m.status != status_before,
        .needs_line_map_dirty = m.hasActiveChildSessions(),
    };
}

fn pollCodex(m: *CodexManager, agent_state: *AgentState) ManagerHandle.PollResult {
    const status_before = m.status;
    const transport = m.transport orelse return .{
        .count = 0,
        .more_pending = false,
        .status_changed = false,
        .needs_line_map_dirty = false,
    };

    const messages = transport.drainMessages() catch return .{
        .count = 0,
        .more_pending = false,
        .status_changed = false,
        .needs_line_map_dirty = false,
    };

    const to_process = messages.len;
    var count: usize = 0;

    for (messages[0..to_process]) |raw_msg| {
        var msg = raw_msg;
        defer msg.deinit(m.allocator);

        // Process through CodexManager to classify + update turn state
        if (m.processMessage(msg)) |codex_event| {
            var event_to_free = codex_event;
            defer m.deinitEvent(&event_to_free);

            // Update manager status based on event type
            switch (event_to_free) {
                .text_delta, .reasoning_delta, .command_output_delta => {
                    if (m.status != .turn_active) m.status = .turn_active;
                },
                .turn_completed => {
                    if (m.status == .turn_active) m.status = .thread_active;
                },
                else => {},
            }

            // Convert to AgentEvent and process inline while data is alive
            if (codexEventToAgentEvent(event_to_free)) |agent_event| {
                processAgentEvent(agent_state, agent_event);
                count += 1;
            }
        }
    }

    m.allocator.free(messages);

    return .{
        .count = count,
        .more_pending = false,
        .status_changed = m.status != status_before,
        .needs_line_map_dirty = false,
    };
}

/// Convert an OpenCode QuestionPrompt event into a question_prompt AgentEvent.
fn convertQuestionPrompt(allocator: Allocator, prompt: @import("../opencode/manager.zig").Event.QuestionPrompt) ?AgentEvent {
    const state = @import("state.zig");
    const question_count = prompt.questions.len;
    if (question_count == 0) return null;

    const questions = allocator.alloc(state.QuestionData, question_count) catch return null;
    for (prompt.questions, 0..) |question, q_idx| {
        const option_count = question.options.len;
        const option_items = allocator.alloc(state.QuestionOptionData, option_count) catch {
            questions[q_idx] = .{
                .header = question.header,
                .question = question.question,
                .options = &[_]state.QuestionOptionData{},
                .multiple = question.multiple,
            };
            continue;
        };
        for (question.options, 0..) |opt, opt_idx| {
            option_items[opt_idx] = .{
                .label = opt.label,
                .description = opt.description,
            };
        }
        questions[q_idx] = .{
            .header = question.header,
            .question = question.question,
            .options = option_items,
            .multiple = question.multiple,
        };
    }

    return .{ .question_prompt = .{
        .id = prompt.id,
        .tool_call_id = prompt.tool_call_id,
        .questions = questions,
    } };
}

test "pollCodex processes all delta messages without dropping overflow" {
    const allocator = std.testing.allocator;

    var manager = CodexManager.init(allocator);
    defer manager.deinit();

    const proc = try CodexProcess.spawnRaw(allocator, &.{"/bin/cat"});
    const transport = try CodexTransport.init(allocator, proc);
    manager.process = proc;
    manager.transport = transport;
    manager.status = .thread_active;

    var decoder = CodexCodec.Decoder.init(allocator);
    var expected_text: std.ArrayListUnmanaged(u8) = .{};
    defer expected_text.deinit(allocator);

    const chunk_count: usize = 60;
    for (0..chunk_count) |i| {
        const char_byte: u8 = @as(u8, @intCast('a' + @as(u8, @intCast(i % 26))));
        try expected_text.append(allocator, char_byte);

        const json = try std.fmt.allocPrint(allocator, "{{\"method\":\"item/agentMessage/delta\",\"params\":{{\"threadId\":\"t1\",\"turnId\":\"turn-1\",\"itemId\":\"item-1\",\"delta\":\"{c}\"}}}}", .{char_byte});
        defer allocator.free(json);

        const msg = try decoder.decode(json);
        try transport.pending_messages.append(allocator, msg);
    }

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    const result = pollCodex(&manager, &agent_state);
    try std.testing.expectEqual(chunk_count, result.count);
    try std.testing.expectEqual(@as(usize, 1), agent_state.messages.items.len);
    try std.testing.expectEqualStrings(expected_text.items, agent_state.messages.items[0].content);
}
