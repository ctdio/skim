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
const git_parser = @import("../git/parser.zig");
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

    /// Check if the active manager supports session modes.
    pub fn hasModes(self: ManagerHandle) bool {
        return switch (self) {
            .acp => |m| m.hasModes(),
            .opencode => false,
            .codex => |m| m.hasModes(),
        };
    }

    /// Get the current mode display name.
    pub fn getCurrentModeName(self: ManagerHandle) []const u8 {
        return switch (self) {
            .acp => |m| m.getCurrentModeName(),
            .opencode => "",
            .codex => |m| m.getCurrentModeName(),
        };
    }

    /// Cycle to the next available mode.
    pub fn cycleToNextMode(self: ManagerHandle) ?[]const u8 {
        return switch (self) {
            .acp => |m| m.cycleToNextMode(),
            .opencode => null,
            .codex => |m| m.cycleToNextMode(),
        };
    }

    /// Adjust manager mode before sending a plan-acceptance prompt.
    pub fn prepareAcceptedPlanPrompt(self: ManagerHandle) void {
        switch (self) {
            .acp, .opencode => {},
            .codex => |m| m.setCollaborationMode(.default),
        }
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
            .codex => |m| m.status == .turn_active or m.hasPendingMessages(),
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
const MAX_CODEX_MESSAGES_PER_FRAME: usize = 20;
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
    _ = m.pollEvents() catch return .{
        .count = 0,
        .more_pending = false,
        .status_changed = false,
        .needs_line_map_dirty = false,
    };

    const pending_count = m.pendingMessageCount();
    if (pending_count == 0) return .{
        .count = 0,
        .more_pending = false,
        .status_changed = false,
        .needs_line_map_dirty = false,
    };

    const to_process = @min(pending_count, MAX_CODEX_MESSAGES_PER_FRAME);
    var count: usize = 0;

    for (m.pending_messages.items[0..to_process]) |msg| {
        // Process through CodexManager to classify + update turn state
        if (m.processMessage(msg)) |codex_event| {
            var event_to_free = codex_event;
            defer m.deinitEvent(&event_to_free);
            var skip_generic_conversion = false;

            // Update manager status based on event type
            switch (event_to_free) {
                .text_delta, .reasoning_delta, .command_output_delta => {
                    if (m.status != .turn_active) m.status = .turn_active;
                },
                .turn_completed => {
                    if (m.status == .turn_active) m.status = .thread_active;
                },
                .approval_requested => {
                    if (m.getPendingApproval()) |approval| {
                        switch (approval.*) {
                            .user_input => {
                                if (convertCodexUserInputPrompt(agent_state.allocator, approval)) |agent_event| {
                                    processAgentEvent(agent_state, agent_event);
                                    count += 1;

                                    const prompt_data = agent_event.question_prompt;
                                    for (prompt_data.questions) |q| {
                                        if (q.options.len > 0) agent_state.allocator.free(q.options);
                                    }
                                    agent_state.allocator.free(prompt_data.questions);
                                }
                            },
                            else => {},
                        }
                    }
                },
                .item_completed => {
                    if (maybeApplyCodexFileChange(agent_state, event_to_free)) {
                        skip_generic_conversion = true;
                        count += 1;
                    }
                },
                else => {},
            }

            if (skip_generic_conversion) {
                continue;
            }

            // Convert to AgentEvent and process inline while data is alive
            if (codexEventToAgentEvent(event_to_free)) |agent_event| {
                processAgentEvent(agent_state, agent_event);
                count += 1;
            }
        }
    }

    m.clearPendingMessagesN(to_process);

    return .{
        .count = count,
        .more_pending = m.hasPendingMessages(),
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

fn convertCodexUserInputPrompt(allocator: Allocator, approval: *const CodexManager.PendingApproval) ?AgentEvent {
    const state = @import("state.zig");
    const prompt = switch (approval.*) {
        .user_input => |ui| ui,
        else => return null,
    };
    const question_count = prompt.questions.len;
    if (question_count == 0) return null;

    const questions = allocator.alloc(state.QuestionData, question_count) catch return null;
    for (prompt.questions, 0..) |question, q_idx| {
        const raw_options = question.options orelse &.{};
        const option_items = allocator.alloc(state.QuestionOptionData, raw_options.len) catch {
            questions[q_idx] = .{
                .header = question.header,
                .question = question.question,
                .options = &[_]state.QuestionOptionData{},
                .multiple = false,
                .allow_custom = question.is_other,
            };
            continue;
        };
        for (raw_options, 0..) |opt, opt_idx| {
            option_items[opt_idx] = .{
                .label = opt.label,
                .description = opt.description,
            };
        }
        questions[q_idx] = .{
            .header = question.header,
            .question = question.question,
            .options = option_items,
            .multiple = false,
            .allow_custom = question.is_other,
        };
    }

    return .{ .question_prompt = .{
        .questions = questions,
    } };
}

fn maybeApplyCodexFileChange(agent_state: *AgentState, event: CodexManager.CodexEvent) bool {
    const item_event = switch (event) {
        .item_completed => |item| item,
        else => return false,
    };
    const file_change = switch (item_event.item) {
        .file_change => |fc| fc,
        else => return false,
    };

    const diff_text = file_change.diff orelse return false;
    const fallback_path = file_change.path orelse return false;
    const normalized_diff = normalizeCodexDiff(agent_state.allocator, diff_text) catch |err| {
        std.log.debug("maybeApplyCodexFileChange: failed to normalize diff for {s}: {}", .{ fallback_path, err });
        return false;
    };
    defer if (normalized_diff.owned_text) |owned| agent_state.allocator.free(owned);

    const files = git_parser.parse(agent_state.allocator, normalized_diff.text) catch |err| {
        std.log.debug("maybeApplyCodexFileChange: failed to parse diff for {s}: {}", .{ fallback_path, err });
        return false;
    };
    defer {
        for (files) |*file| {
            file.deinit(agent_state.allocator);
        }
        agent_state.allocator.free(files);
    }

    var applied_any = false;
    for (files) |file| {
        const display_path = resolveCodexFileChangePath(file, fallback_path);
        const title = buildCodexFileChangeTitle(agent_state.allocator, file, display_path) catch continue;
        defer agent_state.allocator.free(title);

        const old_new = buildOldNewFromUnifiedDiff(agent_state.allocator, file) catch |err| {
            std.log.debug("maybeApplyCodexFileChange: failed to build old/new text for {s}: {}", .{ display_path, err });
            continue;
        };
        defer agent_state.allocator.free(old_new.old_text);
        defer agent_state.allocator.free(old_new.new_text);

        agent_state.addDiffMessage(
            file_change.id,
            title,
            display_path,
            old_new.old_text,
            old_new.new_text,
        ) catch |err| {
            std.log.err("maybeApplyCodexFileChange: failed to add diff for {s}: {any}", .{ display_path, err });
            continue;
        };

        applied_any = true;
    }

    return applied_any;
}

fn normalizeCodexDiff(allocator: Allocator, diff_text: []const u8) !struct {
    text: []const u8,
    owned_text: ?[]u8,
} {
    if (std.mem.indexOfScalar(u8, diff_text, 0x1B) != null) {
        const stripped = try git_parser.stripAnsi(allocator, diff_text);
        return .{
            .text = stripped,
            .owned_text = stripped,
        };
    }

    return .{
        .text = diff_text,
        .owned_text = null,
    };
}

fn resolveCodexFileChangePath(file: git_parser.FileDiff, fallback_path: []const u8) []const u8 {
    if (file.new_path.len > 0) return file.new_path;
    if (file.old_path.len > 0) return file.old_path;
    return fallback_path;
}

fn buildCodexFileChangeTitle(allocator: Allocator, file: git_parser.FileDiff, path: []const u8) ![]const u8 {
    const action = if (file.old_path.len == 0 and file.new_path.len > 0)
        "Add"
    else if (file.new_path.len == 0 and file.old_path.len > 0)
        "Delete"
    else
        "Edit";

    return std.fmt.allocPrint(allocator, "{s} {s}", .{ action, path });
}

fn buildOldNewFromUnifiedDiff(allocator: Allocator, file: git_parser.FileDiff) !struct {
    old_text: []const u8,
    new_text: []const u8,
} {
    var old_lines: std.ArrayList([]const u8) = .{};
    defer old_lines.deinit(allocator);
    var new_lines: std.ArrayList([]const u8) = .{};
    defer new_lines.deinit(allocator);

    for (file.hunks) |hunk| {
        for (hunk.lines) |line| {
            switch (line.line_type) {
                .context => {
                    try old_lines.append(allocator, line.content);
                    try new_lines.append(allocator, line.content);
                },
                .delete => try old_lines.append(allocator, line.content),
                .add => try new_lines.append(allocator, line.content),
            }
        }
    }

    return .{
        .old_text = try joinDiffLines(allocator, old_lines.items),
        .new_text = try joinDiffLines(allocator, new_lines.items),
    };
}

fn joinDiffLines(allocator: Allocator, lines: []const []const u8) ![]const u8 {
    if (lines.len == 0) {
        return allocator.dupe(u8, "");
    }

    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);

    for (lines, 0..) |line, idx| {
        if (idx > 0) try output.append(allocator, '\n');
        try output.appendSlice(allocator, line);
    }

    return output.toOwnedSlice(allocator);
}

test "pollCodex batches large delta bursts across frames" {
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

    const first_result = pollCodex(&manager, &agent_state);
    try std.testing.expectEqual(MAX_CODEX_MESSAGES_PER_FRAME, first_result.count);
    try std.testing.expect(first_result.more_pending);
    try std.testing.expectEqual(@as(usize, 1), agent_state.messages.items.len);
    try std.testing.expectEqualStrings(expected_text.items[0..MAX_CODEX_MESSAGES_PER_FRAME], agent_state.messages.items[0].content);

    const second_result = pollCodex(&manager, &agent_state);
    try std.testing.expectEqual(chunk_count - MAX_CODEX_MESSAGES_PER_FRAME, second_result.count);
    try std.testing.expect(!second_result.more_pending);
    try std.testing.expectEqualStrings(expected_text.items, agent_state.messages.items[0].content);
}

test "codex handle stays active while queued messages remain" {
    const allocator = std.testing.allocator;

    var manager = CodexManager.init(allocator);
    defer manager.deinit();

    const proc = try CodexProcess.spawnRaw(allocator, &.{"/bin/cat"});
    const transport = try CodexTransport.init(allocator, proc);
    manager.process = proc;
    manager.transport = transport;
    manager.status = .thread_active;

    var decoder = CodexCodec.Decoder.init(allocator);
    const json =
        \\{"method":"item/agentMessage/delta","params":{"threadId":"t1","turnId":"turn-1","itemId":"item-1","delta":"x"}}
    ;
    const msg = try decoder.decode(json);
    try transport.pending_messages.append(allocator, msg);

    const handle: ManagerHandle = .{ .codex = &manager };
    try std.testing.expect(handle.hasActivity());

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    const result = pollCodex(&manager, &agent_state);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expect(!result.more_pending);
    try std.testing.expect(!handle.hasActivity());
}

test "pollCodex routes user input approvals through question prompt state" {
    const allocator = std.testing.allocator;

    var manager = CodexManager.init(allocator);
    defer manager.deinit();

    const proc = try CodexProcess.spawnRaw(allocator, &.{"/bin/cat"});
    const transport = try CodexTransport.init(allocator, proc);
    manager.process = proc;
    manager.transport = transport;
    manager.status = .turn_active;

    var decoder = CodexCodec.Decoder.init(allocator);
    const json =
        \\{"id":0,"method":"item/tool/requestUserInput","params":{"threadId":"t1","turnId":"turn-1","itemId":"call-1","questions":[{"id":"q1","header":"Scope","question":"What should we fix first?","options":[{"label":"UI"},{"label":"Protocol"}],"isOther":false},{"id":"q2","header":"Details","question":"Any constraints?","options":[{"label":"Keep it small"}],"isOther":true}]}}
    ;
    const msg = try decoder.decode(json);
    try transport.pending_messages.append(allocator, msg);

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    const result = pollCodex(&manager, &agent_state);
    try std.testing.expectEqual(@as(usize, 1), result.count);

    const pending = agent_state.getPendingQuestion() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), pending.questions.len);

    try std.testing.expectEqual(@as(usize, 2), pending.questions[0].options.len);
    try std.testing.expect(pending.questions[0].custom_index == null);

    try std.testing.expectEqual(@as(usize, 2), pending.questions[1].options.len);
    try std.testing.expectEqual(@as(usize, 1), pending.questions[1].custom_index.?);
    try std.testing.expectEqualStrings("Type your own answer", pending.questions[1].options[1].label);
}

test "pollCodex renders completed file changes as diff messages" {
    const allocator = std.testing.allocator;

    var manager = CodexManager.init(allocator);
    defer manager.deinit();

    const proc = try CodexProcess.spawnRaw(allocator, &.{"/bin/cat"});
    const transport = try CodexTransport.init(allocator, proc);
    manager.process = proc;
    manager.transport = transport;
    manager.status = .turn_active;

    var decoder = CodexCodec.Decoder.init(allocator);
    const started_json =
        \\{"method":"item/started","params":{"threadId":"t1","turnId":"turn-1","item":{"type":"fileChange","id":"fc-1","path":"src/example.zig","status":"modified"}}}
    ;
    const completed_json =
        \\{"method":"item/completed","params":{"threadId":"t1","turnId":"turn-1","item":{"type":"fileChange","id":"fc-1","path":"src/example.zig","diff":"--- src/example.zig\n+++ src/example.zig\n@@ -1,2 +1,2 @@\n const x = 1;\n-const y = 2;\n+const y = 3;\n","status":"modified"}}}
    ;

    const started_msg = try decoder.decode(started_json);
    try transport.pending_messages.append(allocator, started_msg);

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    const started_result = pollCodex(&manager, &agent_state);
    try std.testing.expectEqual(@as(usize, 1), started_result.count);
    try std.testing.expectEqual(@as(usize, 1), agent_state.messages.items.len);
    try std.testing.expectEqualStrings("src/example.zig", agent_state.messages.items[0].content);
    try std.testing.expectEqual(.tool, agent_state.messages.items[0].role);

    const completed_msg = try decoder.decode(completed_json);
    try transport.pending_messages.append(allocator, completed_msg);

    const completed_result = pollCodex(&manager, &agent_state);
    try std.testing.expectEqual(@as(usize, 1), completed_result.count);
    try std.testing.expectEqual(@as(usize, 1), agent_state.messages.items.len);
    try std.testing.expectEqual(.diff, agent_state.messages.items[0].role);
    try std.testing.expectEqualStrings("Edit src/example.zig", agent_state.messages.items[0].content);
    try std.testing.expectEqualStrings("src/example.zig", agent_state.messages.items[0].diff_path.?);
    try std.testing.expectEqualStrings("const x = 1;\nconst y = 2;", agent_state.messages.items[0].diff_old.?);
    try std.testing.expectEqualStrings("const x = 1;\nconst y = 3;", agent_state.messages.items[0].diff_new.?);
}

test "pollCodex falls back to tool updates for unparsable file changes" {
    const allocator = std.testing.allocator;

    var manager = CodexManager.init(allocator);
    defer manager.deinit();

    const proc = try CodexProcess.spawnRaw(allocator, &.{"/bin/cat"});
    const transport = try CodexTransport.init(allocator, proc);
    manager.process = proc;
    manager.transport = transport;
    manager.status = .turn_active;

    var decoder = CodexCodec.Decoder.init(allocator);
    const started_json =
        \\{"method":"item/started","params":{"threadId":"t1","turnId":"turn-1","item":{"type":"fileChange","id":"fc-2","path":"src/example.zig","status":"modified"}}}
    ;
    const completed_json =
        \\{"method":"item/completed","params":{"threadId":"t1","turnId":"turn-1","item":{"type":"fileChange","id":"fc-2","path":"src/example.zig","diff":"not actually a diff","status":"modified"}}}
    ;

    const started_msg = try decoder.decode(started_json);
    try transport.pending_messages.append(allocator, started_msg);

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    _ = pollCodex(&manager, &agent_state);
    try std.testing.expectEqual(@as(usize, 1), agent_state.messages.items.len);
    try std.testing.expectEqual(.tool, agent_state.messages.items[0].role);

    const completed_msg = try decoder.decode(completed_json);
    try transport.pending_messages.append(allocator, completed_msg);

    const completed_result = pollCodex(&manager, &agent_state);
    try std.testing.expectEqual(@as(usize, 1), completed_result.count);
    try std.testing.expectEqual(@as(usize, 1), agent_state.messages.items.len);
    try std.testing.expectEqual(.tool, agent_state.messages.items[0].role);
    try std.testing.expectEqual(.completed, agent_state.messages.items[0].tool_status);
    try std.testing.expectEqualStrings("not actually a diff", agent_state.messages.items[0].tool_stdout.?);
}
