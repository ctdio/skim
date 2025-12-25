const std = @import("std");
const Allocator = std.mem.Allocator;
const client = @import("client.zig");
const process = @import("process.zig");
const protocol = @import("protocol.zig");
const types = @import("types.zig");
const codec = @import("codec.zig");

// =============================================================================
// ACP Manager
// =============================================================================

/// Manages ACP agent sessions for the skim TUI.
/// Handles agent lifecycle, message polling, and callback dispatch.
pub const AcpManager = struct {
    allocator: Allocator,
    acp_client: ?*client.Client,
    status: Status,
    agent_name: ?[]const u8,
    session_id: ?[]const u8,

    // Session modes
    available_modes: std.ArrayListUnmanaged(OwnedModeInfo),
    current_mode_id: ?[]const u8,

    // Message callbacks
    on_message: ?*const fn (text: []const u8, ctx: ?*anyopaque) void,
    on_tool_call: ?*const fn (tool: ToolCallInfo, ctx: ?*anyopaque) void,
    callback_ctx: ?*anyopaque,

    // Pending messages for TUI to consume
    pending_messages: std.ArrayListUnmanaged(PendingMessage),

    // Async prompting state
    pending_prompt_id: ?i64,
    queued_prompts: std.ArrayListUnmanaged([]const u8), // Messages queued while agent is responding

    // Permission request awaiting user response
    pending_permission: ?PendingPermission,

    // Request ID counter for JSON-RPC requests
    next_request_id: i64,

    pub const Status = enum {
        disconnected,
        discovering, // Looking for available agent in PATH
        connecting,
        connected,
        session_active,
        prompting,
        failed,
    };

    /// Owned mode info - strings need to be freed
    pub const OwnedModeInfo = struct {
        id: []const u8,
        name: ?[]const u8,
        description: ?[]const u8,

        pub fn deinit(self: *OwnedModeInfo, allocator: Allocator) void {
            allocator.free(self.id);
            if (self.name) |n| allocator.free(n);
            if (self.description) |d| allocator.free(d);
        }
    };

    pub const PendingMessage = struct {
        kind: Kind,
        text: []const u8, // Owned - title for tool messages, text for others
        // For tool_diff messages
        diff_path: ?[]const u8 = null,
        diff_old: ?[]const u8 = null,
        diff_new: ?[]const u8 = null,
        // For tool messages
        tool_call_id: ?[]const u8 = null,
        tool_name: ?[]const u8 = null,
        tool_command: ?[]const u8 = null,
        tool_stdout: ?[]const u8 = null,
        tool_stderr: ?[]const u8 = null,
        tool_status: types.ToolCallStatus = .pending,
        // For plan messages
        plan_entries: ?[]protocol.PlanEntry = null,
        // For commands update
        available_commands: ?[]protocol.AvailableCommand = null,

        pub const Kind = enum {
            agent_text,
            agent_thinking,
            tool_call, // New tool call started
            tool_update, // Tool call status/output update
            tool_diff,
            error_msg,
            plan_update, // Agent plan update
            commands_update, // Available slash commands update
        };

        pub fn deinit(self: *PendingMessage, allocator: Allocator) void {
            allocator.free(self.text);
            if (self.diff_path) |p| allocator.free(p);
            if (self.diff_old) |o| allocator.free(o);
            if (self.diff_new) |n| allocator.free(n);
            if (self.tool_call_id) |id| allocator.free(id);
            if (self.tool_name) |n| allocator.free(n);
            if (self.tool_command) |c| allocator.free(c);
            if (self.tool_stdout) |s| allocator.free(s);
            if (self.tool_stderr) |s| allocator.free(s);
            if (self.plan_entries) |entries| {
                for (entries) |entry| {
                    allocator.free(entry.content);
                }
                allocator.free(entries);
            }
            if (self.available_commands) |commands| {
                for (commands) |cmd| {
                    allocator.free(cmd.name);
                    allocator.free(cmd.description);
                    if (cmd.input) |input| allocator.free(input.hint);
                }
                allocator.free(commands);
            }
        }
    };

    pub const ToolCallInfo = struct {
        id: []const u8,
        title: ?[]const u8,
        kind: types.ToolCallKind,
        status: types.ToolCallStatus,
    };

    /// Pending permission request awaiting user response
    pub const PendingPermission = struct {
        request_id: codec.JsonRpcId,
        title: []const u8,
        description: ?[]const u8,
        options: []codec.ParsedPermissionOption,
        selected_index: usize,

        pub fn deinit(self: *PendingPermission, allocator: Allocator) void {
            allocator.free(self.title);
            if (self.description) |d| allocator.free(d);
            for (self.options) |*opt| {
                opt.deinit(allocator);
            }
            allocator.free(self.options);
        }
    };

    pub const Error = error{
        AlreadyConnected,
        NotConnected,
        NoSession,
        SpawnFailed,
        InitializeFailed,
        SessionFailed,
        PromptFailed,
    } || Allocator.Error;

    /// Agent info for connection - from config
    pub const AgentInfo = struct {
        name: []const u8,
        command: []const u8,
        args: []const []const u8,
        api_key_env: ?[]const u8 = null, // Environment variable containing API key (for status display)
        model: ?[]const u8 = null, // AI model to use (e.g., "sonnet", "opus")
        mode: ?[]const u8 = null, // Agent session mode (e.g., "plan", "code")
        from_config: bool = false, // true if loaded from config
        is_default: bool = false, // true if marked as default in config
    };

    pub fn init(allocator: Allocator) AcpManager {
        return .{
            .allocator = allocator,
            .acp_client = null,
            .status = .disconnected,
            .agent_name = null,
            .session_id = null,
            .available_modes = .{},
            .current_mode_id = null,
            .on_message = null,
            .on_tool_call = null,
            .callback_ctx = null,
            .pending_messages = .{},
            .pending_prompt_id = null,
            .queued_prompts = .{},
            .pending_permission = null,
            .next_request_id = 1000, // Start high to avoid collision with client IDs
        };
    }

    /// Get next request ID for JSON-RPC requests
    fn nextRequestId(self: *AcpManager) i64 {
        const id = self.next_request_id;
        self.next_request_id += 1;
        return id;
    }

    /// Spawn and connect to an agent
    pub fn connect(self: *AcpManager, agent_command: []const u8, args: []const []const u8, cwd: []const u8) Error!void {
        if (self.acp_client != null) return error.AlreadyConnected;

        self.status = .connecting;
        std.log.info("ACP: Spawning agent '{s}'", .{agent_command});

        // Spawn the agent
        const acp = client.Client.spawn(self.allocator, .{
            .command = agent_command,
            .args = args,
            .cwd = cwd,
        }) catch |err| {
            std.log.err("ACP: Failed to spawn agent: {any}", .{err});
            self.status = .failed;
            return error.SpawnFailed;
        };
        errdefer acp.deinit();

        std.log.info("ACP: Agent spawned, sending initialize...", .{});

        // Initialize the ACP handshake
        acp.initialize() catch |err| {
            std.log.err("ACP: Initialize failed: {any}", .{err});
            self.status = .failed;
            acp.deinit();
            return error.InitializeFailed;
        };

        self.acp_client = acp;
        self.status = .connected;
        std.log.info("ACP: Connected successfully", .{});

        // Store agent name if available
        if (acp.getAgentInfo()) |info| {
            self.agent_name = self.allocator.dupe(u8, info.name) catch null;
            std.log.info("ACP: Agent name: {s}", .{info.name});
        }
    }

    /// Create a new session in the current working directory
    pub fn createSession(self: *AcpManager, cwd: []const u8) Error!void {
        const acp = self.acp_client orelse return error.NotConnected;

        std.log.info("ACP: Creating session in {s}", .{cwd});

        const sid = acp.createSession(cwd) catch |err| {
            std.log.err("ACP: Session creation failed: {any}", .{err});
            self.status = .failed;
            return error.SessionFailed;
        };

        self.session_id = self.allocator.dupe(u8, sid) catch null;
        self.status = .session_active;
        std.log.info("ACP: Session created: {s}", .{sid});

        // Copy session modes from client
        if (acp.getSessionModes()) |modes| {
            self.clearModes();

            // Copy current mode id
            if (modes.current_mode_id) |id| {
                self.current_mode_id = self.allocator.dupe(u8, id) catch null;
            }

            // Copy available modes
            for (modes.available_modes) |mode| {
                const owned_mode = OwnedModeInfo{
                    .id = self.allocator.dupe(u8, mode.id) catch continue,
                    .name = if (mode.name) |n| self.allocator.dupe(u8, n) catch null else null,
                    .description = if (mode.description) |d| self.allocator.dupe(u8, d) catch null else null,
                };
                self.available_modes.append(self.allocator, owned_mode) catch {
                    self.allocator.free(owned_mode.id);
                    if (owned_mode.name) |n| self.allocator.free(n);
                    if (owned_mode.description) |d| self.allocator.free(d);
                };
            }

            std.log.info("ACP: Loaded {d} session modes, current={s}", .{
                self.available_modes.items.len,
                self.current_mode_id orelse "(none)",
            });
        }
    }

    /// Send a prompt to the agent (non-blocking).
    /// If the agent is already responding to a prompt, queues the message.
    /// If still connecting/creating session, queues for when session is ready.
    /// The manager will collect responses via poll().
    pub fn sendPrompt(self: *AcpManager, prompt_text: []const u8) Error!void {
        // Queue prompts while connecting or creating session - will send when ready
        if (self.status == .connecting or self.status == .connected) {
            const queued = try self.allocator.dupe(u8, prompt_text);
            try self.queued_prompts.append(self.allocator, queued);
            std.log.info("ACP Manager: queued prompt (session not ready), queue size: {d}", .{self.queued_prompts.items.len});
            return;
        }

        const acp = self.acp_client orelse return error.NotConnected;
        if (self.status != .session_active and self.status != .prompting) return error.NoSession;

        // If already prompting, queue the message for later
        if (self.pending_prompt_id != null) {
            const queued = try self.allocator.dupe(u8, prompt_text);
            try self.queued_prompts.append(self.allocator, queued);
            std.log.info("ACP Manager: queued prompt (agent busy), queue size: {d}", .{self.queued_prompts.items.len});
            return;
        }

        // Send prompt asynchronously
        const request_id = acp.sendPromptAsync(prompt_text) catch |err| {
            std.log.err("ACP Manager: failed to send prompt: {any}", .{err});
            return error.PromptFailed;
        };

        self.pending_prompt_id = request_id;
        self.status = .prompting;
        std.log.info("ACP Manager: sent prompt async, request_id={d}", .{request_id});
    }

    /// Send the next queued prompt if any.
    /// Called after each prompt completes, or when session first becomes active.
    /// Safe to call at any time - will only send when it's the user's turn.
    pub fn sendNextQueuedPrompt(self: *AcpManager) void {
        if (self.queued_prompts.items.len == 0) return;

        // Only send when session is active and it's not the agent's turn
        if (self.status != .session_active) return;
        if (self.pending_prompt_id != null) return;

        const acp = self.acp_client orelse return;

        // Pop first queued message
        const prompt_text = self.queued_prompts.orderedRemove(0);
        defer self.allocator.free(prompt_text);

        const request_id = acp.sendPromptAsync(prompt_text) catch |err| {
            std.log.err("ACP Manager: failed to send queued prompt: {any}", .{err});
            // Add error message to pending
            const err_text = self.allocator.dupe(u8, "Failed to send queued message") catch return;
            self.pending_messages.append(self.allocator, .{
                .kind = .error_msg,
                .text = err_text,
            }) catch {
                self.allocator.free(err_text);
            };
            return;
        };

        self.pending_prompt_id = request_id;
        self.status = .prompting;
    }

    /// Get number of queued prompts
    pub fn queuedPromptCount(self: *AcpManager) usize {
        return self.queued_prompts.items.len;
    }

    /// Cancel the current prompt (send interrupt to agent).
    /// Returns true if cancellation was sent, false if no prompt was active.
    pub fn cancelPrompt(self: *AcpManager) bool {
        const acp = self.acp_client orelse return false;

        // Only cancel if we're currently prompting
        if (self.pending_prompt_id == null or self.status != .prompting) {
            return false;
        }

        acp.cancelPrompt() catch |err| {
            std.log.err("ACP Manager: failed to send cancel: {any}", .{err});
            return false;
        };

        // Clear pending prompt - we'll receive a cancelled stop_reason in the response
        self.pending_prompt_id = null;
        self.status = .session_active;

        return true;
    }

    /// Check if agent is currently processing a prompt
    pub fn isPrompting(self: *AcpManager) bool {
        return self.status == .prompting and self.pending_prompt_id != null;
    }

    /// Poll for new messages from the agent (non-blocking).
    /// Returns slice of pending messages. Call clearMessages() after processing.
    pub fn poll(self: *AcpManager) Error![]PendingMessage {
        const acp = self.acp_client orelse return self.pending_messages.items;

        // Check if agent process died unexpectedly
        if (!acp.isAlive() and self.status != .failed) {
            std.log.warn("ACP Manager: agent process died unexpectedly", .{});
            self.status = .failed;
            const err_text = self.allocator.dupe(u8, "Agent stopped. Press 'a' to close panel and retry.") catch return self.pending_messages.items;
            self.pending_messages.append(self.allocator, .{
                .kind = .error_msg,
                .text = err_text,
            }) catch {
                self.allocator.free(err_text);
            };
            return self.pending_messages.items;
        }

        // Poll the transport for new messages
        const messages = acp.transport.poll() catch return self.pending_messages.items;

        // Process messages
        for (messages) |msg| {
            switch (msg) {
                .notification => |n| {
                    if (std.mem.eql(u8, n.method, "session/update")) {
                        if (n.params_json) |pjson| {
                            self.processSessionUpdate(pjson) catch {};
                        }
                    }
                },
                .response => |r| {
                    // Check if this is a response to our pending prompt
                    if (self.pending_prompt_id) |expected_id| {
                        if (r.id) |id| {
                            const response_id: ?i64 = switch (id) {
                                .number => |n| n,
                                .string, .null_value => null,
                            };
                            if (response_id == expected_id) {
                                self.pending_prompt_id = null;
                                self.status = .session_active;

                                // Check for error in response
                                if (r.error_msg) |err| {
                                    std.log.err("ACP Manager: prompt error: {s}", .{err.message});
                                    const err_text = self.allocator.dupe(u8, err.message) catch continue;
                                    self.pending_messages.append(self.allocator, .{
                                        .kind = .error_msg,
                                        .text = err_text,
                                    }) catch {
                                        self.allocator.free(err_text);
                                    };
                                }

                                // Send next queued prompt if any
                                self.sendNextQueuedPrompt();
                            }
                        }
                    }
                },
                .request => |req| {
                    // Handle requests from the agent
                    self.handleAgentRequest(req) catch |err| {
                        std.log.err("ACP Manager: failed to handle agent request: {any}", .{err});
                    };
                },
            }
        }

        // Free the messages we received from the transport
        acp.transport.freeMessages(messages);

        // Always check if we can send queued prompts (safe to call repeatedly)
        self.sendNextQueuedPrompt();

        return self.pending_messages.items;
    }

    /// Handle a request from the agent
    fn handleAgentRequest(self: *AcpManager, request: codec.Request) !void {
        const acp = self.acp_client orelse return;
        const id = request.id;

        // Filter out echoed commands from script PTY wrapper
        if (isClientMethod(request.method)) {
            std.log.debug("ACP Manager: ignoring echoed command: {s}", .{request.method});
            return;
        }

        if (std.mem.eql(u8, request.method, "fs/read_text_file")) {
            // Handle file read request
            if (request.params_json) |pjson| {
                const params = acp.transport.decoder.parseReadTextFileParams(pjson) catch {
                    try acp.transport.sendErrorResponse(id, -32600, "Invalid params");
                    return;
                };

                // Read file content
                const file = std.fs.openFileAbsolute(params.path, .{}) catch {
                    try acp.transport.sendErrorResponse(id, -32001, "File not found");
                    return;
                };
                defer file.close();

                const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch {
                    try acp.transport.sendErrorResponse(id, -32002, "Read error");
                    return;
                };
                defer self.allocator.free(content);

                const result = protocol.ReadTextFileResult{
                    .content = content,
                };

                const result_json = acp.transport.encoder.encodeReadTextFileResult(result) catch return error.PromptFailed;
                defer self.allocator.free(result_json);

                try acp.transport.sendResponse(id, result_json);
            }
        } else if (std.mem.eql(u8, request.method, "session/request_permission")) {
            // Parse permission request params
            if (request.params_json) |params_json| {
                const parsed = acp.transport.decoder.parseRequestPermissionParams(params_json) catch |err| {
                    std.log.err("ACP Manager: failed to parse permission params: {any}", .{err});
                    try acp.transport.sendErrorResponse(id, -32602, "Invalid permission params");
                    return;
                };

                // Store as pending permission for user to decide
                if (self.pending_permission) |*old| {
                    old.deinit(self.allocator);
                }

                self.pending_permission = .{
                    .request_id = id,
                    .title = parsed.title,
                    .description = parsed.description,
                    .options = parsed.options,
                    .selected_index = 0,
                };

                // Don't free parsed strings - they're now owned by pending_permission
                // Just free the session_id and tool_call_id which we don't need
                self.allocator.free(parsed.session_id);
                self.allocator.free(parsed.tool_call_id);
            } else {
                try acp.transport.sendErrorResponse(id, -32602, "Missing permission params");
            }
        } else if (std.mem.eql(u8, request.method, "fs/write_text_file")) {
            // Reject file writes for now (read-only mode)
            std.log.warn("ACP Manager: rejecting fs/write_text_file request (read-only)", .{});
            try acp.transport.sendErrorResponse(id, -32001, "File writes not supported");
        } else if (std.mem.startsWith(u8, request.method, "terminal/")) {
            // Terminal operations not supported
            std.log.warn("ACP Manager: rejecting terminal request: {s}", .{request.method});
            try acp.transport.sendErrorResponse(id, -32001, "Terminal not supported");
        } else {
            // Unknown method - log it clearly
            std.log.warn("ACP Manager: unknown method from agent: {s}", .{request.method});
            try acp.transport.sendErrorResponse(id, -32601, "Method not found");
        }
    }

    /// Check if a method is one we send (client->agent), not agent->client
    fn isClientMethod(method: []const u8) bool {
        return std.mem.eql(u8, method, "initialize") or
            std.mem.eql(u8, method, "session/new") or
            std.mem.eql(u8, method, "session/prompt") or
            std.mem.eql(u8, method, "session/cancel") or
            std.mem.eql(u8, method, "session/resume") or
            std.mem.eql(u8, method, "session/fork") or
            std.mem.eql(u8, method, "session/set_mode");
    }

    /// Clear processed messages
    pub fn clearMessages(self: *AcpManager) void {
        for (self.pending_messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.pending_messages.clearRetainingCapacity();
    }

    /// Check if connected and alive
    pub fn isConnected(self: *AcpManager) bool {
        if (self.acp_client) |acp| {
            return acp.isAlive();
        }
        return false;
    }

    /// Get agent info string for display
    pub fn getAgentDisplayName(self: *AcpManager) []const u8 {
        return self.agent_name orelse "Unknown Agent";
    }

    /// Get status string for display
    pub fn getStatusString(self: *AcpManager) []const u8 {
        return switch (self.status) {
            .disconnected => "Disconnected",
            .discovering => "Discovering...",
            .connecting => "Connecting...",
            .connected => "Connected",
            .session_active => "Ready",
            .prompting => "Thinking...",
            .failed => "Failed",
        };
    }

    // =========================================================================
    // Session Modes
    // =========================================================================

    /// Check if agent supports session modes
    pub fn hasModes(self: *AcpManager) bool {
        return self.available_modes.items.len > 0;
    }

    /// Get the current mode ID
    pub fn getCurrentModeId(self: *AcpManager) ?[]const u8 {
        return self.current_mode_id;
    }

    /// Get the current mode name for display
    pub fn getCurrentModeName(self: *AcpManager) []const u8 {
        const current_id = self.current_mode_id orelse return "";
        for (self.available_modes.items) |mode| {
            if (std.mem.eql(u8, mode.id, current_id)) {
                return mode.name orelse mode.id;
            }
        }
        return current_id;
    }

    /// Get available modes
    pub fn getAvailableModes(self: *AcpManager) []const OwnedModeInfo {
        return self.available_modes.items;
    }

    /// Set the session mode
    pub fn setMode(self: *AcpManager, mode_id: []const u8) Error!void {
        const acp = self.acp_client orelse return error.NotConnected;
        const sid = self.session_id orelse return error.NoSession;

        std.log.info("ACP Manager: setting mode to '{s}'", .{mode_id});

        const params = protocol.SessionSetModeParams{
            .session_id = sid,
            .mode_id = mode_id,
        };

        const params_json = acp.transport.encoder.encodeSessionSetModeParams(params) catch return error.PromptFailed;
        defer self.allocator.free(params_json);

        // Send as request per ACP spec (session/set_mode is a request, not notification)
        const request_id = self.nextRequestId();
        _ = acp.transport.sendRequest(request_id, "session/set_mode", params_json) catch |err| {
            std.log.err("ACP Manager: failed to send set_mode: {any}", .{err});
            return error.PromptFailed;
        };

        // Update local state immediately (agent will confirm via session/update)
        if (self.current_mode_id) |old| {
            self.allocator.free(old);
        }
        self.current_mode_id = self.allocator.dupe(u8, mode_id) catch null;
    }

    /// Cycle to the next mode (for Shift+Tab)
    /// Returns the name of the new mode, or null if no modes available
    pub fn cycleToNextMode(self: *AcpManager) ?[]const u8 {
        if (self.available_modes.items.len == 0) return null;

        const current_id = self.current_mode_id orelse {
            // No current mode, select the first one
            const first = self.available_modes.items[0];
            self.setMode(first.id) catch return null;
            return first.name orelse first.id;
        };

        // Find current mode index
        var current_idx: ?usize = null;
        for (self.available_modes.items, 0..) |mode, i| {
            if (std.mem.eql(u8, mode.id, current_id)) {
                current_idx = i;
                break;
            }
        }

        // Cycle to next mode
        const next_idx = if (current_idx) |idx|
            (idx + 1) % self.available_modes.items.len
        else
            0;

        const next_mode = self.available_modes.items[next_idx];
        self.setMode(next_mode.id) catch return null;
        return next_mode.name orelse next_mode.id;
    }

    /// Check if there's a pending permission request
    pub fn hasPendingPermission(self: *AcpManager) bool {
        return self.pending_permission != null;
    }

    /// Get the pending permission (for display)
    pub fn getPendingPermission(self: *AcpManager) ?*PendingPermission {
        if (self.pending_permission) |*perm| {
            return perm;
        }
        return null;
    }

    /// Respond to the pending permission request
    pub fn respondToPermission(self: *AcpManager, allow: bool) !void {
        const acp = self.acp_client orelse return error.NotConnected;
        var perm = self.pending_permission orelse return;

        // Get the selected option (use agent-provided optionId, or ACP standard fallbacks)
        const option_id = if (perm.options.len > 0)
            perm.options[perm.selected_index].option_id
        else if (allow)
            "allow_once"
        else
            "reject_once";

        // Build and send response per ACP spec: {"selectedOption": "option_id"}
        const result_json = acp.transport.encoder.encodePermissionResult(option_id) catch |err| {
            std.log.err("ACP Manager: failed to encode permission result: {any}", .{err});
            return error.PromptFailed;
        };
        defer self.allocator.free(result_json);

        std.log.info("ACP Manager: responding to permission with '{s}'", .{option_id});
        try acp.transport.sendResponse(perm.request_id, result_json);

        // Clear the pending permission
        perm.deinit(self.allocator);
        self.pending_permission = null;
    }

    /// Cancel/reject the pending permission request
    pub fn cancelPermission(self: *AcpManager) !void {
        const acp = self.acp_client orelse return error.NotConnected;
        var perm = self.pending_permission orelse return;

        // Send cancelled response using encoder (null = cancelled)
        const result_json = acp.transport.encoder.encodePermissionResult(null) catch |err| {
            std.log.err("ACP Manager: failed to encode cancel result: {any}", .{err});
            return error.PromptFailed;
        };
        defer self.allocator.free(result_json);

        std.log.info("ACP Manager: cancelling permission request", .{});
        try acp.transport.sendResponse(perm.request_id, result_json);

        // Clear the pending permission
        perm.deinit(self.allocator);
        self.pending_permission = null;
    }

    /// Disconnect from the agent
    pub fn disconnect(self: *AcpManager) void {
        if (self.acp_client) |acp| {
            acp.deinit();
            self.acp_client = null;
        }

        if (self.agent_name) |name| {
            self.allocator.free(name);
            self.agent_name = null;
        }

        if (self.session_id) |sid| {
            self.allocator.free(sid);
            self.session_id = null;
        }

        self.clearModes();
        self.clearMessages();
        self.clearQueuedPrompts();
        self.pending_prompt_id = null;
        self.status = .disconnected;
    }

    /// Clear session modes
    fn clearModes(self: *AcpManager) void {
        for (self.available_modes.items) |*mode| {
            mode.deinit(self.allocator);
        }
        self.available_modes.clearRetainingCapacity();
        if (self.current_mode_id) |id| {
            self.allocator.free(id);
            self.current_mode_id = null;
        }
    }

    /// Clear queued prompts
    fn clearQueuedPrompts(self: *AcpManager) void {
        for (self.queued_prompts.items) |prompt_text| {
            self.allocator.free(prompt_text);
        }
        self.queued_prompts.clearRetainingCapacity();
    }

    pub fn deinit(self: *AcpManager) void {
        self.disconnect();
        self.pending_messages.deinit(self.allocator);
        self.queued_prompts.deinit(self.allocator);
        self.available_modes.deinit(self.allocator);
        if (self.pending_permission) |*perm| {
            perm.deinit(self.allocator);
        }
    }

    // =========================================================================
    // Internal
    // =========================================================================

    fn handleSessionUpdate(update: protocol.SessionUpdateParams, ctx: ?*anyopaque) void {
        const self: *AcpManager = @ptrCast(@alignCast(ctx));

        // Determine message kind based on update type
        const msg_kind: PendingMessage.Kind = switch (update.update_type) {
            .agent_thought_chunk => .agent_thinking,
            else => .agent_text,
        };

        // Handle message updates (agent text or thinking responses)
        if (update.message) |msg| {
            for (msg.content) |block| {
                switch (block) {
                    .text => |t| {
                        const text = self.allocator.dupe(u8, t.text) catch continue;
                        self.pending_messages.append(self.allocator, .{
                            .kind = msg_kind,
                            .text = text,
                        }) catch {
                            self.allocator.free(text);
                        };
                    },
                    .diff, .resource_link => {},
                }
            }
        }

        // Handle tool calls
        if (update.tool_call) |tc| {
            const title = tc.title orelse "Tool";

            // Check if tool_call has diff content
            var has_diff = false;
            for (tc.content) |block| {
                if (block == .diff) {
                    has_diff = true;
                    const diff = block.diff;

                    // Create diff message
                    const title_copy = self.allocator.dupe(u8, title) catch continue;
                    const path_copy = self.allocator.dupe(u8, diff.path) catch {
                        self.allocator.free(title_copy);
                        continue;
                    };
                    const old_copy = self.allocator.dupe(u8, diff.old_text) catch {
                        self.allocator.free(title_copy);
                        self.allocator.free(path_copy);
                        continue;
                    };
                    const new_copy = self.allocator.dupe(u8, diff.new_text) catch {
                        self.allocator.free(title_copy);
                        self.allocator.free(path_copy);
                        self.allocator.free(old_copy);
                        continue;
                    };

                    self.pending_messages.append(self.allocator, .{
                        .kind = .tool_diff,
                        .text = title_copy,
                        .diff_path = path_copy,
                        .diff_old = old_copy,
                        .diff_new = new_copy,
                    }) catch {
                        self.allocator.free(title_copy);
                        self.allocator.free(path_copy);
                        self.allocator.free(old_copy);
                        self.allocator.free(new_copy);
                    };
                }
            }

            // If no diff, create or update a tool_call message with metadata
            if (!has_diff) {
                // Check if we already have a pending message for this tool_call_id
                // (ACP sends tool_call twice: once without params, once with params)
                var existing: ?*PendingMessage = null;
                for (self.pending_messages.items) |*pm| {
                    if (pm.kind == .tool_call) {
                        if (pm.tool_call_id) |existing_id| {
                            if (std.mem.eql(u8, existing_id, tc.tool_call_id)) {
                                existing = pm;
                                break;
                            }
                        }
                    }
                }

                if (existing) |pm| {
                    // Update existing message with new info
                    // Update title if we got a more specific one
                    if (!std.mem.eql(u8, title, pm.text)) {
                        const new_text = self.allocator.dupe(u8, title) catch return;
                        self.allocator.free(pm.text);
                        pm.text = new_text;
                    }
                    // Update command if provided
                    if (tc.command) |cmd| {
                        if (pm.tool_command == null) {
                            pm.tool_command = self.allocator.dupe(u8, cmd) catch null;
                        }
                    }
                    // Update status
                    pm.tool_status = tc.status;
                } else {
                    // Create new pending message
                    const text = self.allocator.dupe(u8, title) catch return;
                    const id_copy = self.allocator.dupe(u8, tc.tool_call_id) catch {
                        self.allocator.free(text);
                        return;
                    };
                    const name_copy: ?[]const u8 = if (tc.tool_name) |n|
                        self.allocator.dupe(u8, n) catch null
                    else
                        null;
                    const cmd_copy: ?[]const u8 = if (tc.command) |c|
                        self.allocator.dupe(u8, c) catch null
                    else
                        null;

                    self.pending_messages.append(self.allocator, .{
                        .kind = .tool_call,
                        .text = text,
                        .tool_call_id = id_copy,
                        .tool_name = name_copy,
                        .tool_command = cmd_copy,
                        .tool_status = tc.status,
                    }) catch {
                        self.allocator.free(text);
                        self.allocator.free(id_copy);
                        if (name_copy) |n| self.allocator.free(n);
                        if (cmd_copy) |c| self.allocator.free(c);
                    };
                }
            }
        }

        // Handle tool call updates
        if (update.tool_call_update) |tcu| {
            // Extract content text for stdout (tool output is in content blocks, not toolResponse.stdout)
            var output_text: ?[]const u8 = null;
            for (tcu.content) |block| {
                if (block == .text) {
                    output_text = self.allocator.dupe(u8, block.text.text) catch null;
                    break;
                }
            }

            // Fallback to toolResponse.stdout if present
            if (output_text == null and tcu.stdout != null) {
                output_text = self.allocator.dupe(u8, tcu.stdout.?) catch null;
            }

            const id_copy = self.allocator.dupe(u8, tcu.tool_call_id) catch return;
            const text_copy = self.allocator.dupe(u8, tcu.tool_call_id) catch {
                self.allocator.free(id_copy);
                return;
            };
            const name_copy: ?[]const u8 = if (tcu.tool_name) |n|
                self.allocator.dupe(u8, n) catch null
            else
                null;
            const stderr_copy: ?[]const u8 = if (tcu.stderr) |s|
                self.allocator.dupe(u8, s) catch null
            else
                null;

            self.pending_messages.append(self.allocator, .{
                .kind = .tool_update,
                .text = text_copy,
                .tool_call_id = id_copy,
                .tool_name = name_copy,
                .tool_stdout = output_text,
                .tool_stderr = stderr_copy,
                .tool_status = tcu.status orelse .pending,
            }) catch {
                self.allocator.free(id_copy);
                self.allocator.free(text_copy);
                if (name_copy) |n| self.allocator.free(n);
                if (output_text) |s| self.allocator.free(s);
                if (stderr_copy) |s| self.allocator.free(s);
            };
        }

        // Handle plan updates
        if (update.plan) |plan| {
            // Copy plan entries
            const entries_copy = self.allocator.alloc(protocol.PlanEntry, plan.entries.len) catch return;
            var copied_count: usize = 0;

            for (plan.entries) |entry| {
                const content_copy = self.allocator.dupe(u8, entry.content) catch {
                    // Clean up already copied entries on error
                    for (entries_copy[0..copied_count]) |e| {
                        self.allocator.free(e.content);
                    }
                    self.allocator.free(entries_copy);
                    return;
                };
                entries_copy[copied_count] = .{
                    .content = content_copy,
                    .priority = entry.priority,
                    .status = entry.status,
                };
                copied_count += 1;
            }

            self.pending_messages.append(self.allocator, .{
                .kind = .plan_update,
                .text = self.allocator.dupe(u8, "Plan update") catch {
                    for (entries_copy[0..copied_count]) |e| {
                        self.allocator.free(e.content);
                    }
                    self.allocator.free(entries_copy);
                    return;
                },
                .plan_entries = entries_copy[0..copied_count],
            }) catch {
                for (entries_copy[0..copied_count]) |e| {
                    self.allocator.free(e.content);
                }
                self.allocator.free(entries_copy);
            };
        }

        // Handle current mode updates
        if (update.current_mode_update) |mode_update| {
            // Update local state
            if (self.current_mode_id) |old| {
                self.allocator.free(old);
            }
            self.current_mode_id = self.allocator.dupe(u8, mode_update.mode_id) catch null;

            // Add a pending message to trigger UI update
            const mode_name = blk: {
                for (self.available_modes.items) |mode| {
                    if (std.mem.eql(u8, mode.id, mode_update.mode_id)) {
                        break :blk mode.name orelse mode.id;
                    }
                }
                break :blk mode_update.mode_id;
            };
            const msg_text = std.fmt.allocPrint(self.allocator, "Mode changed to: {s}", .{mode_name}) catch return;
            self.pending_messages.append(self.allocator, .{
                .kind = .agent_text,
                .text = msg_text,
            }) catch {
                self.allocator.free(msg_text);
            };
        }

        // Handle available commands updates (slash commands)
        if (update.available_commands) |cmds_update| {
            // Copy commands
            const commands_copy = self.allocator.alloc(protocol.AvailableCommand, cmds_update.commands.len) catch return;
            var copied_count: usize = 0;

            for (cmds_update.commands) |cmd| {
                const name_copy = self.allocator.dupe(u8, cmd.name) catch {
                    // Clean up on error
                    for (commands_copy[0..copied_count]) |c| {
                        self.allocator.free(c.name);
                        self.allocator.free(c.description);
                        if (c.input) |i| self.allocator.free(i.hint);
                    }
                    self.allocator.free(commands_copy);
                    return;
                };
                const desc_copy = self.allocator.dupe(u8, cmd.description) catch {
                    self.allocator.free(name_copy);
                    for (commands_copy[0..copied_count]) |c| {
                        self.allocator.free(c.name);
                        self.allocator.free(c.description);
                        if (c.input) |i| self.allocator.free(i.hint);
                    }
                    self.allocator.free(commands_copy);
                    return;
                };
                const input_copy: ?protocol.AvailableCommandInput = if (cmd.input) |input| blk: {
                    const hint_copy = self.allocator.dupe(u8, input.hint) catch {
                        self.allocator.free(name_copy);
                        self.allocator.free(desc_copy);
                        for (commands_copy[0..copied_count]) |c| {
                            self.allocator.free(c.name);
                            self.allocator.free(c.description);
                            if (c.input) |i| self.allocator.free(i.hint);
                        }
                        self.allocator.free(commands_copy);
                        return;
                    };
                    break :blk .{ .hint = hint_copy };
                } else null;

                commands_copy[copied_count] = .{
                    .name = name_copy,
                    .description = desc_copy,
                    .input = input_copy,
                };
                copied_count += 1;
            }

            self.pending_messages.append(self.allocator, .{
                .kind = .commands_update,
                .text = self.allocator.dupe(u8, "Commands update") catch {
                    for (commands_copy[0..copied_count]) |c| {
                        self.allocator.free(c.name);
                        self.allocator.free(c.description);
                        if (c.input) |i| self.allocator.free(i.hint);
                    }
                    self.allocator.free(commands_copy);
                    return;
                },
                .available_commands = commands_copy[0..copied_count],
            }) catch {
                for (commands_copy[0..copied_count]) |c| {
                    self.allocator.free(c.name);
                    self.allocator.free(c.description);
                    if (c.input) |i| self.allocator.free(i.hint);
                }
                self.allocator.free(commands_copy);
            };
        }
    }

    fn processSessionUpdate(self: *AcpManager, json: []const u8) !void {
        const acp = self.acp_client orelse return;
        const update = try acp.transport.decoder.parseSessionUpdateParams(json);
        handleSessionUpdate(update, self);
    }
};

// =============================================================================
// Agent Utilities
// =============================================================================

/// Config agent struct for loadAgentList parameter (mirrors config.AgentConfig)
pub const ConfigAgent = struct {
    name: []const u8,
    command: []const u8,
    api_key_env: ?[]const u8 = null,
    default: bool = false,
    args: ?[]const []const u8 = null,
    model: ?[]const u8 = null,
    mode: ?[]const u8 = null,
};

/// Load agent list from config agents.
/// Returns null if no agents are configured.
/// Returns owned slice that must be freed with freeAgentList().
pub fn loadAgentList(allocator: Allocator, config_agents: ?[]const ConfigAgent) !?[]AcpManager.AgentInfo {
    // Only use explicitly configured agents - no auto-discovery
    const agents = config_agents orelse return null;
    if (agents.len == 0) return null;

    const result = try allocator.alloc(AcpManager.AgentInfo, agents.len);
    errdefer allocator.free(result);

    for (agents, 0..) |cfg, i| {
        result[i] = .{
            .name = try allocator.dupe(u8, cfg.name),
            .command = try allocator.dupe(u8, cfg.command),
            .args = if (cfg.args) |a| try dupeStringSlice(allocator, a) else &.{},
            .api_key_env = if (cfg.api_key_env) |e| try allocator.dupe(u8, e) else null,
            .model = if (cfg.model) |m| try allocator.dupe(u8, m) else null,
            .mode = if (cfg.mode) |m| try allocator.dupe(u8, m) else null,
            .from_config = true,
            .is_default = cfg.default,
        };
    }
    return result;
}

/// Free an agent list returned by loadAgentList
pub fn freeAgentList(allocator: Allocator, agents: []AcpManager.AgentInfo) void {
    for (agents) |agent| {
        allocator.free(agent.name);
        allocator.free(agent.command);
        if (agent.args.len > 0) {
            for (agent.args) |arg| allocator.free(arg);
            allocator.free(agent.args);
        }
        if (agent.api_key_env) |e| allocator.free(e);
        if (agent.model) |m| allocator.free(m);
        if (agent.mode) |m| allocator.free(m);
    }
    allocator.free(agents);
}

/// Find the default agent in a list (first one marked as default, or first one)
pub fn findDefaultOrFirst(agents: []const AcpManager.AgentInfo) ?*const AcpManager.AgentInfo {
    if (agents.len == 0) return null;
    // First, look for explicitly marked default
    for (agents) |*agent| {
        if (agent.is_default) return agent;
    }
    // No default marked - return first agent
    return &agents[0];
}

/// Duplicate a slice of strings
fn dupeStringSlice(allocator: Allocator, strings: []const []const u8) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, strings.len);
    for (strings, 0..) |s, i| {
        result[i] = try allocator.dupe(u8, s);
    }
    return result;
}

// =============================================================================
// Tests
// =============================================================================

test "AcpManager init and deinit" {
    const allocator = std.testing.allocator;

    var manager = AcpManager.init(allocator);
    defer manager.deinit();

    try std.testing.expectEqual(AcpManager.Status.disconnected, manager.status);
    try std.testing.expect(!manager.isConnected());
}

test "AcpManager status strings" {
    const allocator = std.testing.allocator;

    var manager = AcpManager.init(allocator);
    defer manager.deinit();

    try std.testing.expectEqualStrings("Disconnected", manager.getStatusString());
    try std.testing.expectEqualStrings("Unknown Agent", manager.getAgentDisplayName());
}
