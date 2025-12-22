const std = @import("std");
const Allocator = std.mem.Allocator;
const process = @import("process.zig");
const transport = @import("transport.zig");
const codec = @import("codec.zig");
const protocol = @import("protocol.zig");
const capabilities = @import("capabilities.zig");
const types = @import("types.zig");

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
                    const result = self.transport.decoder.parseInitializeResult(result_json) catch {
                        self.state = .failed;
                        return error.ProtocolError;
                    };

                    self.agent_info = result.agent_info;
                    self.agent_capabilities = result.agent_capabilities;
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
        _ = try self.transport.poll();
        self.transport.clearMessages();
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
                    self.session_id = result.session_id;
                    self.state = .session_active;
                    return result.session_id;
                } else {
                    return error.SessionFailed;
                }
            },
            else => return error.ProtocolError,
        }
    }

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

        const request_id = self.nextRequestId();
        _ = try self.transport.sendRequest(request_id, "session/prompt", params_json);

        // Process messages until we get the response
        while (true) {
            const messages = try self.transport.poll();

            for (messages) |msg| {
                switch (msg) {
                    .notification => |n| {
                        if (std.mem.eql(u8, n.method, "session/update")) {
                            if (n.params_json) |pjson| {
                                const update = self.transport.decoder.parseSessionUpdateParams(pjson) catch continue;
                                callback(update, callback_ctx);
                            }
                        }
                    },
                    .response => |r| {
                        if (r.id) |id| {
                            switch (id) {
                                .integer => |int_id| {
                                    if (int_id == request_id) {
                                        // Got response
                                        self.transport.clearMessages();
                                        if (r.error_msg != null) return error.PromptFailed;

                                        if (r.result_json) |result_json| {
                                            const result = self.transport.decoder.parseSessionPromptResult(result_json) catch return error.ProtocolError;
                                            return result.stop_reason;
                                        }
                                        return error.ProtocolError;
                                    }
                                },
                                else => {},
                            }
                        }
                    },
                    .request => |req| {
                        // Handle requests from agent (e.g., permission requests, file reads)
                        try self.handleAgentRequest(req);
                    },
                }
            }

            self.transport.clearMessages();
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

    /// Handle a request from the agent
    fn handleAgentRequest(self: *Client, request: codec.DecodedMessage.Request) Error!void {
        const id = request.id orelse return;

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
        } else {
            // Unknown method
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

    fn nextRequestId(self: *Client) i64 {
        const id = self.next_request_id;
        self.next_request_id += 1;
        return id;
    }

    pub fn deinit(self: *Client) void {
        self.transport.deinit();
        self.agent.deinit();
        self.allocator.destroy(self);
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
