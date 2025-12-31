const std = @import("std");
const Allocator = std.mem.Allocator;
const process = @import("process.zig");
const transport = @import("transport.zig");
const codec = @import("codec.zig");
const protocol = @import("protocol.zig");
const capabilities = @import("capabilities.zig");
const types = @import("types.zig");

// =============================================================================
// Terminal Entry for tracking spawned terminals
// =============================================================================

const TerminalEntry = struct {
    allocator: Allocator,
    child: std.process.Child,
    output_buffer: std.ArrayListUnmanaged(u8),
    output_byte_limit: u32,
    exited: bool,
    exit_code: ?u32,
    signal: ?u32,

    fn deinit(self: *TerminalEntry) void {
        self.output_buffer.deinit(self.allocator);
        // Don't need to do anything else - child process already cleaned up
    }
};

const TerminalRegistry = std.StringHashMapUnmanaged(TerminalEntry);

// =============================================================================
// ACP Client
// =============================================================================

/// High-level ACP client for communicating with coding agents
pub const Client = struct {
    allocator: Allocator,
    agent: *process.AgentProcess,
    transport: *transport.StdioTransport,
    state: State,
    next_request_id: i64,

    // Agent info from initialization
    agent_info: ?capabilities.PeerInfo,
    agent_capabilities: ?capabilities.AgentCapabilities,

    // Active session
    session_id: ?types.SessionId,

    // Session modes (from session/new response)
    session_modes: ?protocol.SessionModes,

    // Session models (from session/new response)
    session_models: ?protocol.SessionModels,

    // Terminal registry for spawned commands
    terminals: TerminalRegistry,
    next_terminal_id: u64,

    pub const State = enum {
        disconnected,
        connecting,
        initialized,
        session_active,
        failed,
    };

    pub const Error = error{
        AlreadyInitialized,
        NotInitialized,
        NoActiveSession,
        SessionAlreadyActive,
        InitializeFailed,
        SessionFailed,
        PromptFailed,
        Timeout,
        ProtocolError,
        AgentError,
    } || Allocator.Error || process.AgentProcess.SpawnError || transport.StdioTransport.Error;

    /// Spawn an agent and create a client
    pub fn spawn(allocator: Allocator, config: process.SpawnConfig) Error!*Client {
        const agent = try process.AgentProcess.spawn(allocator, config);
        errdefer agent.deinit();

        const trans = try transport.StdioTransport.init(allocator, agent);
        errdefer trans.deinit();

        const self = try allocator.create(Client);
        self.* = .{
            .allocator = allocator,
            .agent = agent,
            .transport = trans,
            .state = .disconnected,
            .next_request_id = 1,
            .agent_info = null,
            .agent_capabilities = null,
            .session_id = null,
            .session_modes = null,
            .session_models = null,
            .terminals = .{},
            .next_terminal_id = 1,
        };

        return self;
    }

    /// Initialize the ACP connection (handshake)
    pub fn initialize(self: *Client) Error!void {
        if (self.state != .disconnected) return error.AlreadyInitialized;

        self.state = .connecting;
        std.log.debug("ACP Client: Starting initialize handshake", .{});

        // Build initialize params
        const params = protocol.InitializeParams{
            .protocol_version = types.PROTOCOL_VERSION,
            .client_capabilities = capabilities.skimClientCapabilities(),
            .client_info = capabilities.skimClientInfo(),
        };

        const params_json = self.transport.encoder.encodeInitializeParams(params) catch |err| {
            std.log.err("ACP Client: Failed to encode params: {any}", .{err});
            return error.ProtocolError;
        };
        defer self.allocator.free(params_json);

        std.log.debug("ACP Client: Sending initialize request", .{});

        // Send initialize request
        const request_id = self.nextRequestId();
        _ = self.transport.sendRequest(request_id, "initialize", params_json) catch |err| {
            std.log.err("ACP Client: Failed to send request: {any}", .{err});
            return err;
        };

        std.log.debug("ACP Client: Waiting for response (3s timeout)...", .{});

        // Wait for response (short timeout - if agent doesn't respond quickly, it's not ACP-compatible)
        const response = self.transport.waitForResponse(request_id, 3000) catch |err| { // 3s timeout
            std.log.err("ACP Client: waitForResponse failed: {any}", .{err});
            return err;
        };
        if (response == null) {
            std.log.err("ACP Client: Initialize timed out - no response from agent", .{});
            self.state = .failed;
            return error.Timeout;
        }

        // Parse response
        var resp = response.?;
        defer resp.deinit(self.allocator);

        switch (resp) {
            .response => |r| {
                if (r.error_msg != null) {
                    self.state = .failed;
                    return error.InitializeFailed;
                }

                if (r.result_json) |result_json| {
                    std.log.debug("ACP Client: initialize result JSON: {s}", .{result_json});
                    const result = self.transport.decoder.parseInitializeResult(result_json) catch {
                        self.state = .failed;
                        return error.ProtocolError;
                    };

                    self.agent_info = result.agent_info;
                    self.agent_capabilities = result.agent_capabilities;
                    std.log.info("ACP Client: sessionCapabilities.resume = {}", .{result.agent_capabilities.session_capabilities.@"resume"});
                    self.state = .initialized;
                } else {
                    self.state = .failed;
                    return error.InitializeFailed;
                }
            },
            else => {
                self.state = .failed;
                return error.ProtocolError;
            },
        }
    }

    /// Create a new session
    pub fn createSession(self: *Client, cwd: []const u8) Error!types.SessionId {
        if (self.state != .initialized and self.state != .session_active) return error.NotInitialized;
        if (self.session_id != null) return error.SessionAlreadyActive;

        // Give the agent a moment to fully initialize after handshake
        std.Thread.sleep(100 * std.time.ns_per_ms);

        // Drain any pending notifications from the agent
        const drained = try self.transport.poll();
        self.transport.freeMessages(drained);
        std.log.debug("ACP Client: drained pending messages after initialize", .{});

        const params = protocol.SessionNewParams{
            .cwd = cwd,
            .mcp_servers = &.{},
        };

        const params_json = self.transport.encoder.encodeSessionNewParams(params) catch return error.ProtocolError;
        defer self.allocator.free(params_json);

        std.log.debug("ACP Client: session/new params: {s}", .{params_json});

        const request_id = self.nextRequestId();
        std.log.debug("ACP Client: Sending session/new request id={d}", .{request_id});
        _ = try self.transport.sendRequest(request_id, "session/new", params_json);

        // Wait for response (session creation can take longer - agent spawns subprocess)
        const response = try self.transport.waitForResponse(request_id, 30000); // 30s timeout
        if (response == null) return error.Timeout;

        var resp = response.?;
        defer resp.deinit(self.allocator);

        switch (resp) {
            .response => |r| {
                if (r.error_msg != null) return error.SessionFailed;

                if (r.result_json) |result_json| {
                    const result = self.transport.decoder.parseSessionNewResult(result_json) catch return error.ProtocolError;
                    // Decoder already duplicates the session_id, so we own this memory
                    self.session_id = result.session_id;
                    self.session_modes = result.modes;
                    self.session_models = result.models;
                    self.state = .session_active;
                    std.log.info("ACP Client: session created with id: {s}", .{result.session_id});

                    // Log available modes
                    if (result.modes) |modes| {
                        std.log.info("ACP Client: session has {d} available modes, current={s}", .{
                            modes.available_modes.len,
                            modes.current_mode_id orelse "(none)",
                        });
                    }

                    // Log available models
                    if (result.models) |models| {
                        std.log.info("ACP Client: session has {d} available models, current={s}", .{
                            models.available_models.len,
                            models.current_model_id orelse "(none)",
                        });
                    }

                    // NOTE: Don't poll here! The manager will poll and process all messages
                    // (including session/update notifications with available_commands).
                    // Polling here would consume messages from the transport queue, preventing
                    // the manager from seeing them.
                    std.log.info("ACP Client: session created, manager will poll for notifications", .{});

                    return result.session_id;
                } else {
                    return error.SessionFailed;
                }
            },
            else => return error.ProtocolError,
        }
    }

    /// Load (resume) an existing session
    /// The agent will replay conversation history via session/update notifications
    pub fn loadSession(self: *Client, session_id: []const u8, cwd: []const u8) Error!types.SessionId {
        if (self.state != .initialized and self.state != .session_active) return error.NotInitialized;

        // Log capability status but try anyway - session/load is a defined ACP method
        // and the agent may support it even if not explicitly advertised
        if (self.agent_capabilities) |caps| {
            if (!caps.load_session) {
                std.log.info("ACP Client: agent doesn't advertise loadSession capability, trying anyway", .{});
            }
        }

        // If we have an active session, we need to end it first
        if (self.session_id != null) {
            std.log.debug("ACP Client: ending existing session before loading", .{});
            if (self.session_id) |sid| {
                self.allocator.free(sid);
            }
            self.session_id = null;
        }

        // Give the agent a moment to prepare
        std.Thread.sleep(100 * std.time.ns_per_ms);

        // Drain any pending notifications
        const drained = try self.transport.poll();
        self.transport.freeMessages(drained);

        const params = protocol.SessionLoadParams{
            .session_id = session_id,
            .cwd = cwd,
            .mcp_servers = &.{},
        };

        const params_json = self.transport.encoder.encodeSessionLoadParams(params) catch return error.ProtocolError;
        defer self.allocator.free(params_json);

        std.log.debug("ACP Client: session/load params: {s}", .{params_json});

        const request_id = self.nextRequestId();
        std.log.info("ACP Client: Sending session/load request id={d} for session={s}", .{ request_id, session_id });
        _ = try self.transport.sendRequest(request_id, "session/load", params_json);

        // Wait for response - session loading may take time as agent replays history
        const response = try self.transport.waitForResponse(request_id, 60000); // 60s timeout
        if (response == null) return error.Timeout;

        var resp = response.?;
        defer resp.deinit(self.allocator);

        switch (resp) {
            .response => |r| {
                if (r.error_msg) |err| {
                    std.log.err("ACP Client: session/load failed: code={d} message={s}", .{ err.code, err.message });
                    return error.SessionFailed;
                }

                if (r.result_json) |result_json| {
                    // Parse result (same structure as session/new)
                    const result = self.transport.decoder.parseSessionNewResult(result_json) catch return error.ProtocolError;
                    self.session_id = result.session_id;
                    self.session_modes = result.modes;
                    self.session_models = result.models;
                    self.state = .session_active;
                    std.log.info("ACP Client: session loaded with id: {s}", .{result.session_id});
                    return result.session_id;
                } else {
                    return error.SessionFailed;
                }
            },
            else => return error.ProtocolError,
        }
    }

    /// Resume an existing session using session/new with resume option
    /// This is the preferred method for agents that advertise sessionCapabilities.resume
    /// (e.g., Claude Code ACP). The agent will load history from the specified session.
    /// Optionally pass mode/model to restore the previous session's mode/model settings.
    pub fn resumeSession(
        self: *Client,
        session_id_to_resume: []const u8,
        cwd: []const u8,
        mode: ?[]const u8,
        model: ?[]const u8,
    ) Error!types.SessionId {
        if (self.state != .initialized and self.state != .session_active) return error.NotInitialized;

        // Check if agent supports session resume via sessionCapabilities
        const supports_resume = if (self.agent_capabilities) |caps| caps.session_capabilities.@"resume" else false;
        if (!supports_resume) {
            std.log.warn("ACP Client: agent doesn't advertise sessionCapabilities.resume, trying anyway", .{});
        }

        // If we have an active session, clear it
        if (self.session_id != null) {
            std.log.debug("ACP Client: clearing existing session before resume", .{});
            if (self.session_id) |sid| {
                self.allocator.free(sid);
            }
            self.session_id = null;
        }

        // Give the agent a moment to prepare
        std.Thread.sleep(100 * std.time.ns_per_ms);

        // Drain any pending notifications
        const drained = try self.transport.poll();
        self.transport.freeMessages(drained);

        // Use session/new with resume option (Claude Code ACP style)
        // Include mode/model to restore previous session settings
        const params = protocol.SessionNewParams{
            .cwd = cwd,
            .mcp_servers = &.{},
            .@"resume" = session_id_to_resume,
            .mode = mode,
            .model = model,
        };

        const params_json = self.transport.encoder.encodeSessionNewParams(params) catch return error.ProtocolError;
        defer self.allocator.free(params_json);

        std.log.info("ACP Client: session/new (resume) params: {s}", .{params_json});

        const request_id = self.nextRequestId();
        std.log.info("ACP Client: Sending session/new with resume={s}", .{session_id_to_resume});
        _ = try self.transport.sendRequest(request_id, "session/new", params_json);

        // Wait for response - session resumption may take time as agent loads history
        const response = try self.transport.waitForResponse(request_id, 60000); // 60s timeout
        if (response == null) return error.Timeout;

        var resp = response.?;
        defer resp.deinit(self.allocator);

        switch (resp) {
            .response => |r| {
                if (r.error_msg) |err| {
                    std.log.err("ACP Client: session resume failed: code={d} message={s}", .{ err.code, err.message });
                    return error.SessionFailed;
                }

                if (r.result_json) |result_json| {
                    const result = self.transport.decoder.parseSessionNewResult(result_json) catch return error.ProtocolError;
                    self.session_id = result.session_id;
                    self.session_modes = result.modes;
                    self.session_models = result.models;
                    self.state = .session_active;
                    std.log.info("ACP Client: session resumed with id: {s}", .{result.session_id});
                    return result.session_id;
                } else {
                    return error.SessionFailed;
                }
            },
            else => return error.ProtocolError,
        }
    }

    /// Send a prompt without blocking.
    /// Returns the request ID for tracking the response.
    /// Use processMessages() to poll for responses.
    pub fn sendPromptAsync(self: *Client, text: []const u8) Error!i64 {
        if (self.state != .session_active) return error.NoActiveSession;
        const sid = self.session_id orelse return error.NoActiveSession;
        std.log.debug("ACP Client: sendPromptAsync with session_id={s}, text_len={d}", .{ sid, text.len });

        // Build prompt content
        const content = [_]protocol.ContentBlock{
            .{ .text = .{ .text = text } },
        };

        const params = protocol.SessionPromptParams{
            .session_id = sid,
            .content = &content,
        };

        const params_json = self.transport.encoder.encodeSessionPromptParams(params) catch return error.ProtocolError;
        defer self.allocator.free(params_json);

        std.log.info("ACP Client: session/prompt params: {s}", .{params_json});

        const request_id = self.nextRequestId();
        std.log.info("ACP Client: Sending session/prompt request id={d}", .{request_id});
        _ = try self.transport.sendRequest(request_id, "session/prompt", params_json);

        return request_id;
    }

    /// Send a prompt with content blocks without blocking.
    /// Returns the request ID for tracking the response.
    pub fn sendPromptContentAsync(self: *Client, content: []const protocol.ContentBlock) Error!i64 {
        if (self.state != .session_active) return error.NoActiveSession;
        const sid = self.session_id orelse return error.NoActiveSession;

        // Log content block summary
        var text_count: usize = 0;
        var resource_count: usize = 0;
        for (content) |block| {
            switch (block) {
                .text => text_count += 1,
                .embedded_resource => resource_count += 1,
                else => {},
            }
        }
        std.log.info("ACP Client: sendPromptContentAsync - {d} text blocks, {d} embedded resources", .{ text_count, resource_count });

        const params = protocol.SessionPromptParams{
            .session_id = sid,
            .content = content,
        };

        const params_json = self.transport.encoder.encodeSessionPromptParams(params) catch return error.ProtocolError;
        defer self.allocator.free(params_json);

        // Log full payload (truncate if too long for readability)
        const max_log_len: usize = 2000;
        if (params_json.len <= max_log_len) {
            std.log.info("ACP Client: session/prompt payload: {s}", .{params_json});
        } else {
            std.log.info("ACP Client: session/prompt payload (truncated {d} bytes): {s}...", .{ params_json.len, params_json[0..max_log_len] });
        }

        const request_id = self.nextRequestId();
        std.log.info("ACP Client: Sending session/prompt request id={d}", .{request_id});
        _ = try self.transport.sendRequest(request_id, "session/prompt", params_json);

        return request_id;
    }

    /// Process result for a completed prompt
    pub const PromptResult = struct {
        stop_reason: types.StopReason,
        completed: bool,
    };

    /// Send a prompt and process streaming updates
    /// Returns when the agent completes the turn.
    /// Calls the callback for each session/update notification.
    pub fn prompt(
        self: *Client,
        text: []const u8,
        callback: *const fn (update: protocol.SessionUpdateParams, ctx: ?*anyopaque) void,
        callback_ctx: ?*anyopaque,
    ) Error!types.StopReason {
        if (self.state != .session_active) return error.NoActiveSession;
        const sid = self.session_id orelse return error.NoActiveSession;
        std.log.debug("ACP Client: prompt called with session_id={s}, text_len={d}", .{ sid, text.len });

        // Build prompt content
        const content = [_]protocol.ContentBlock{
            .{ .text = .{ .text = text } },
        };

        const params = protocol.SessionPromptParams{
            .session_id = sid,
            .content = &content,
        };

        const params_json = self.transport.encoder.encodeSessionPromptParams(params) catch return error.ProtocolError;
        defer self.allocator.free(params_json);

        std.log.info("ACP Client: session/prompt params: {s}", .{params_json});

        const request_id = self.nextRequestId();
        std.log.info("ACP Client: Sending session/prompt request id={d}", .{request_id});
        _ = try self.transport.sendRequest(request_id, "session/prompt", params_json);

        // Process messages until we get the response
        var loop_count: u32 = 0;
        while (true) {
            const messages = try self.transport.poll();
            defer self.transport.freeMessages(messages);

            loop_count += 1;

            for (messages) |msg| {
                switch (msg) {
                    .notification => |n| {
                        if (std.mem.eql(u8, n.method, "session/update")) {
                            if (n.params_json) |pjson| {
                                const update = self.transport.decoder.parseSessionUpdateParams(pjson) catch |err| {
                                    std.log.err("ACP Client: failed to parse session/update: {any}", .{err});
                                    continue;
                                };
                                callback(update, callback_ctx);
                            }
                        }
                    },
                    .response => |r| {
                        if (r.id) |id| {
                            switch (id) {
                                .number => |int_id| {
                                    if (int_id == request_id) {
                                        // Got response - defer will free messages
                                        if (r.error_msg) |err| {
                                            std.log.err("ACP Client: prompt got error from agent: code={d} message={s}", .{ err.code, err.message });
                                            return error.PromptFailed;
                                        }
                                        if (r.result_json) |result_json| {
                                            const result = self.transport.decoder.parseSessionPromptResult(result_json) catch |err| {
                                                std.log.err("ACP Client: failed to parse prompt result: {any}", .{err});
                                                return error.ProtocolError;
                                            };
                                            std.log.info("ACP Client: prompt completed with stop_reason: {s}", .{result.stop_reason.toString()});
                                            return result.stop_reason;
                                        }
                                        std.log.warn("ACP Client: response has no result_json", .{});
                                        return error.ProtocolError;
                                    }
                                },
                                else => {},
                            }
                        }
                    },
                    .request => |req| {
                        std.log.debug("ACP Client: got request: {s}", .{req.method});
                        // Handle requests from agent (e.g., permission requests, file reads)
                        try self.handleAgentRequest(req);
                    },
                }
            }

            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }

    /// Cancel the current prompt
    pub fn cancelPrompt(self: *Client) Error!void {
        if (self.state != .session_active) return error.NoActiveSession;
        const sid = self.session_id orelse return error.NoActiveSession;

        const params = protocol.SessionCancelParams{
            .session_id = sid,
        };

        const params_json = self.transport.encoder.encodeSessionCancelParams(params) catch return error.ProtocolError;
        defer self.allocator.free(params_json);

        try self.transport.sendNotification("session/cancel", params_json);
    }

    /// Check if a method is one we send (client->agent), not agent->client
    /// These get echoed back when using `script` PTY wrapper
    fn isClientMethod(method: []const u8) bool {
        return std.mem.eql(u8, method, "initialize") or
            std.mem.eql(u8, method, "session/new") or
            std.mem.eql(u8, method, "session/prompt") or
            std.mem.eql(u8, method, "session/cancel") or
            std.mem.eql(u8, method, "session/resume") or
            std.mem.eql(u8, method, "session/fork") or
            std.mem.eql(u8, method, "session/set_mode");
    }

    /// Handle a request from the agent
    fn handleAgentRequest(self: *Client, request: codec.Request) Error!void {
        const id = request.id;

        // Filter out echoed commands from script PTY wrapper
        if (isClientMethod(request.method)) {
            std.log.debug("ACP Client: ignoring echoed command: {s}", .{request.method});
            return;
        }

        std.log.info("ACP Client: handling agent request: method={s}", .{request.method});

        if (std.mem.eql(u8, request.method, "fs/read_text_file")) {
            // Handle file read request
            if (request.params_json) |pjson| {
                const params = self.transport.decoder.parseReadTextFileParams(pjson) catch {
                    try self.transport.sendErrorResponse(id, -32600, "Invalid params");
                    return;
                };

                // Read file content
                const file = std.fs.openFileAbsolute(params.path, .{}) catch {
                    try self.transport.sendErrorResponse(id, -32001, "File not found");
                    return;
                };
                defer file.close();

                const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch {
                    try self.transport.sendErrorResponse(id, -32002, "Read error");
                    return;
                };
                defer self.allocator.free(content);

                const result = protocol.ReadTextFileResult{
                    .content = content,
                };

                const result_json = self.transport.encoder.encodeReadTextFileResult(result) catch return error.ProtocolError;
                defer self.allocator.free(result_json);

                try self.transport.sendResponse(id, result_json);
            }
        } else if (std.mem.eql(u8, request.method, "session/request_permission")) {
            // For now, auto-allow all permissions
            // In the future, skim will show a permission dialog
            const result_json =
                \\{"selected_option": "allow_once"}
            ;
            try self.transport.sendResponse(id, result_json);
        } else if (std.mem.eql(u8, request.method, "fs/write_text_file")) {
            // Handle file write request
            if (request.params_json) |pjson| {
                const params = self.transport.decoder.parseWriteTextFileParams(pjson) catch {
                    try self.transport.sendErrorResponse(id, -32600, "Invalid params");
                    return;
                };
                defer {
                    self.allocator.free(params.session_id);
                    self.allocator.free(params.path);
                    self.allocator.free(params.content);
                }

                std.log.info("ACP Client: writing file: {s} ({d} bytes)", .{ params.path, params.content.len });

                // Create parent directories if needed
                if (std.fs.path.dirname(params.path)) |dir| {
                    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
                        error.PathAlreadyExists => {},
                        else => {
                            std.log.err("ACP Client: failed to create directory: {any}", .{err});
                            try self.transport.sendErrorResponse(id, -32001, "Failed to create directory");
                            return;
                        },
                    };
                }

                // Write file content
                const file = std.fs.createFileAbsolute(params.path, .{ .truncate = true }) catch |err| {
                    std.log.err("ACP Client: failed to create file: {any}", .{err});
                    try self.transport.sendErrorResponse(id, -32001, "Failed to create file");
                    return;
                };
                defer file.close();

                file.writeAll(params.content) catch |err| {
                    std.log.err("ACP Client: failed to write file: {any}", .{err});
                    try self.transport.sendErrorResponse(id, -32002, "Write error");
                    return;
                };

                // Return success
                try self.transport.sendResponse(id, "{}");
            } else {
                try self.transport.sendErrorResponse(id, -32600, "Missing params");
            }
        } else if (std.mem.eql(u8, request.method, "terminal/create")) {
            // Handle terminal create request
            if (request.params_json) |pjson| {
                const params = self.transport.decoder.parseTerminalCreateParams(pjson) catch {
                    try self.transport.sendErrorResponse(id, -32600, "Invalid params");
                    return;
                };
                defer params.deinit(self.allocator);

                std.log.info("ACP Client: creating terminal for command: {s}", .{params.command});

                // Build the full command string for shell execution
                // We need to run through a shell to handle redirections, pipes, &&, etc.
                var cmd_buf: std.ArrayListUnmanaged(u8) = .{};
                defer cmd_buf.deinit(self.allocator);

                // If env vars are provided, prepend export statements to the command
                // This way the child inherits the parent environment and we add/override specific vars
                for (params.env) |ev| {
                    cmd_buf.appendSlice(self.allocator, "export ") catch {
                        try self.transport.sendErrorResponse(id, -32603, "Out of memory");
                        return;
                    };
                    // Shell-escape the env var name (usually safe but be careful)
                    cmd_buf.appendSlice(self.allocator, ev.name) catch {};
                    cmd_buf.appendSlice(self.allocator, "='") catch {};
                    // Shell-escape the value
                    for (ev.value) |c| {
                        if (c == '\'') {
                            cmd_buf.appendSlice(self.allocator, "'\\''") catch {};
                        } else {
                            cmd_buf.append(self.allocator, c) catch {};
                        }
                    }
                    cmd_buf.appendSlice(self.allocator, "'; ") catch {};
                }

                cmd_buf.appendSlice(self.allocator, params.command) catch {
                    try self.transport.sendErrorResponse(id, -32001, "Failed to build command");
                    return;
                };
                for (params.args) |arg| {
                    cmd_buf.append(self.allocator, ' ') catch {};
                    // Simple shell escaping - wrap in single quotes, escape existing single quotes
                    cmd_buf.append(self.allocator, '\'') catch {};
                    for (arg) |c| {
                        if (c == '\'') {
                            cmd_buf.appendSlice(self.allocator, "'\\''") catch {};
                        } else {
                            cmd_buf.append(self.allocator, c) catch {};
                        }
                    }
                    cmd_buf.append(self.allocator, '\'') catch {};
                }

                // Use user's shell from $SHELL env var, fallback to /bin/sh
                // Child inherits environment from skim (which inherits from user's terminal)
                const user_shell = std.posix.getenv("SHELL") orelse "/bin/sh";
                const argv = [_][]const u8{ user_shell, "-c", cmd_buf.items };

                // Spawn process
                var child = std.process.Child.init(&argv, self.allocator);
                child.cwd = params.cwd;
                child.stdout_behavior = .Pipe;
                child.stderr_behavior = .Pipe;

                child.spawn() catch |err| {
                    std.log.err("ACP Client: failed to spawn terminal: {any}", .{err});
                    try self.transport.sendErrorResponse(id, -32001, "Failed to spawn process");
                    return;
                };

                // Generate terminal ID and store entry
                const terminal_id = self.nextTerminalId();
                const entry = TerminalEntry{
                    .allocator = self.allocator,
                    .child = child,
                    .output_buffer = .{},
                    .output_byte_limit = params.output_byte_limit orelse 1024 * 1024,
                    .exited = false,
                    .exit_code = null,
                    .signal = null,
                };
                self.terminals.put(self.allocator, terminal_id, entry) catch {
                    try self.transport.sendErrorResponse(id, -32001, "Failed to store terminal");
                    return;
                };

                // Return terminal ID
                const result_json = std.fmt.allocPrint(self.allocator, "{{\"terminal_id\":\"{s}\"}}", .{terminal_id}) catch {
                    try self.transport.sendErrorResponse(id, -32001, "Failed to encode result");
                    return;
                };
                defer self.allocator.free(result_json);
                try self.transport.sendResponse(id, result_json);
            } else {
                try self.transport.sendErrorResponse(id, -32600, "Missing params");
            }
        } else if (std.mem.eql(u8, request.method, "terminal/output")) {
            // Handle terminal output request
            if (request.params_json) |pjson| {
                const params = self.transport.decoder.parseTerminalOutputParams(pjson) catch {
                    try self.transport.sendErrorResponse(id, -32600, "Invalid params");
                    return;
                };
                defer params.deinit(self.allocator);

                if (self.terminals.getPtr(params.terminal_id)) |entry| {
                    // Poll for new output
                    self.pollTerminalOutput(entry);

                    // Build response
                    const output = entry.output_buffer.items;
                    const truncated = entry.output_buffer.items.len >= entry.output_byte_limit;

                    var result_json: []const u8 = undefined;
                    if (entry.exited) {
                        if (entry.exit_code) |code| {
                            result_json = std.fmt.allocPrint(self.allocator, "{{\"output\":\"{s}\",\"truncated\":{},\"exit_status\":{{\"exit_code\":{d}}}}}", .{ output, truncated, code }) catch {
                                try self.transport.sendErrorResponse(id, -32001, "Failed to encode result");
                                return;
                            };
                        } else if (entry.signal) |sig| {
                            result_json = std.fmt.allocPrint(self.allocator, "{{\"output\":\"{s}\",\"truncated\":{},\"exit_status\":{{\"signal\":{d}}}}}", .{ output, truncated, sig }) catch {
                                try self.transport.sendErrorResponse(id, -32001, "Failed to encode result");
                                return;
                            };
                        } else {
                            result_json = std.fmt.allocPrint(self.allocator, "{{\"output\":\"{s}\",\"truncated\":{}}}", .{ output, truncated }) catch {
                                try self.transport.sendErrorResponse(id, -32001, "Failed to encode result");
                                return;
                            };
                        }
                    } else {
                        result_json = std.fmt.allocPrint(self.allocator, "{{\"output\":\"{s}\",\"truncated\":{}}}", .{ output, truncated }) catch {
                            try self.transport.sendErrorResponse(id, -32001, "Failed to encode result");
                            return;
                        };
                    }
                    defer self.allocator.free(result_json);
                    try self.transport.sendResponse(id, result_json);
                } else {
                    try self.transport.sendErrorResponse(id, -32001, "Terminal not found");
                }
            } else {
                try self.transport.sendErrorResponse(id, -32600, "Missing params");
            }
        } else if (std.mem.eql(u8, request.method, "terminal/wait_for_exit")) {
            // Handle terminal wait request
            if (request.params_json) |pjson| {
                const params = self.transport.decoder.parseTerminalOutputParams(pjson) catch {
                    try self.transport.sendErrorResponse(id, -32600, "Invalid params");
                    return;
                };
                defer params.deinit(self.allocator);

                if (self.terminals.getPtr(params.terminal_id)) |entry| {
                    // Wait for process to exit (blocking)
                    const term = entry.child.wait() catch {
                        try self.transport.sendErrorResponse(id, -32001, "Wait failed");
                        return;
                    };

                    var result_json: []const u8 = undefined;
                    switch (term.term) {
                        .Exited => |code| {
                            entry.exited = true;
                            entry.exit_code = code;
                            result_json = std.fmt.allocPrint(self.allocator, "{{\"exit_code\":{d}}}", .{code}) catch {
                                try self.transport.sendErrorResponse(id, -32001, "Failed to encode result");
                                return;
                            };
                        },
                        .Signal => |sig| {
                            entry.exited = true;
                            entry.signal = sig;
                            result_json = std.fmt.allocPrint(self.allocator, "{{\"signal\":{d}}}", .{sig}) catch {
                                try self.transport.sendErrorResponse(id, -32001, "Failed to encode result");
                                return;
                            };
                        },
                        else => {
                            result_json = std.fmt.allocPrint(self.allocator, "{{}}", .{}) catch {
                                try self.transport.sendErrorResponse(id, -32001, "Failed to encode result");
                                return;
                            };
                        },
                    }
                    defer self.allocator.free(result_json);
                    try self.transport.sendResponse(id, result_json);
                } else {
                    try self.transport.sendErrorResponse(id, -32001, "Terminal not found");
                }
            } else {
                try self.transport.sendErrorResponse(id, -32600, "Missing params");
            }
        } else if (std.mem.eql(u8, request.method, "terminal/kill")) {
            // Handle terminal kill request
            if (request.params_json) |pjson| {
                const params = self.transport.decoder.parseTerminalOutputParams(pjson) catch {
                    try self.transport.sendErrorResponse(id, -32600, "Invalid params");
                    return;
                };
                defer params.deinit(self.allocator);

                if (self.terminals.getPtr(params.terminal_id)) |entry| {
                    _ = entry.child.kill() catch {};
                    try self.transport.sendResponse(id, "{}");
                } else {
                    try self.transport.sendErrorResponse(id, -32001, "Terminal not found");
                }
            } else {
                try self.transport.sendErrorResponse(id, -32600, "Missing params");
            }
        } else if (std.mem.eql(u8, request.method, "terminal/release")) {
            // Handle terminal release request - clean up resources
            if (request.params_json) |pjson| {
                const params = self.transport.decoder.parseTerminalOutputParams(pjson) catch {
                    try self.transport.sendErrorResponse(id, -32600, "Invalid params");
                    return;
                };
                defer params.deinit(self.allocator);

                if (self.terminals.fetchRemove(params.terminal_id)) |kv| {
                    self.allocator.free(kv.key);
                    var entry = kv.value;
                    entry.deinit();
                }
                try self.transport.sendResponse(id, "{}");
            } else {
                try self.transport.sendErrorResponse(id, -32600, "Missing params");
            }
        } else {
            // Unknown method - log it clearly
            std.log.warn("ACP Client: unknown method from agent: {s}", .{request.method});
            try self.transport.sendErrorResponse(id, -32601, "Method not found");
        }
    }

    /// Check if agent is still running
    pub fn isAlive(self: *Client) bool {
        return self.agent.isAlive();
    }

    /// Get agent info (available after initialization)
    pub fn getAgentInfo(self: *Client) ?capabilities.PeerInfo {
        return self.agent_info;
    }

    /// Get agent capabilities (available after initialization)
    pub fn getAgentCapabilities(self: *Client) ?capabilities.AgentCapabilities {
        return self.agent_capabilities;
    }

    /// Get session modes (available after session creation)
    pub fn getSessionModes(self: *Client) ?protocol.SessionModes {
        return self.session_modes;
    }

    /// Get session models (available after session creation)
    pub fn getSessionModels(self: *Client) ?protocol.SessionModels {
        return self.session_models;
    }

    fn nextRequestId(self: *Client) i64 {
        const id = self.next_request_id;
        self.next_request_id += 1;
        return id;
    }

    pub fn deinit(self: *Client) void {
        // Clean up terminals
        var term_it = self.terminals.iterator();
        while (term_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.terminals.deinit(self.allocator);

        // Free owned session_id if present
        if (self.session_id) |sid| {
            self.allocator.free(sid);
        }
        self.transport.deinit();
        self.agent.deinit();
        self.allocator.destroy(self);
    }

    fn nextTerminalId(self: *Client) []const u8 {
        const id = std.fmt.allocPrint(self.allocator, "term_{d}", .{self.next_terminal_id}) catch return "term_error";
        self.next_terminal_id += 1;
        return id;
    }

    fn pollTerminalOutput(self: *Client, entry: *TerminalEntry) void {
        _ = self;
        if (entry.exited) return;

        // Try to read any available output from stdout
        if (entry.child.stdout) |stdout| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = stdout.read(&buf) catch break;
                if (n == 0) break;

                // Respect output limit
                const remaining = entry.output_byte_limit -| @as(u32, @intCast(entry.output_buffer.items.len));
                if (remaining == 0) break;

                const to_add = @min(n, remaining);
                entry.output_buffer.appendSlice(entry.allocator, buf[0..to_add]) catch break;
            }
        }

        // Check if process has exited
        const result = entry.child.wait() catch return;
        switch (result.term) {
            .Exited => |code| {
                entry.exited = true;
                entry.exit_code = code;
            },
            .Signal => |sig| {
                entry.exited = true;
                entry.signal = sig;
            },
            else => {},
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "client spawn and deinit" {
    const allocator = std.testing.allocator;

    // Create a client with a simple process
    var client = try Client.spawn(allocator, .{
        .command = "/bin/cat",
    });
    defer client.deinit();

    try std.testing.expectEqual(Client.State.disconnected, client.state);
    try std.testing.expect(client.isAlive());
}
