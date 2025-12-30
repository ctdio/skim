const std = @import("std");
const types = @import("types.zig");
const caps = @import("capabilities.zig");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;

// =============================================================================
// JSON-RPC ID
// =============================================================================

/// JSON-RPC ID can be string, number, or null
pub const JsonRpcId = union(enum) {
    string: []const u8,
    number: i64,
    null_value: void,

    pub fn eql(self: JsonRpcId, other: JsonRpcId) bool {
        return switch (self) {
            .string => |s| switch (other) {
                .string => |o| std.mem.eql(u8, s, o),
                else => false,
            },
            .number => |n| switch (other) {
                .number => |o| n == o,
                else => false,
            },
            .null_value => switch (other) {
                .null_value => true,
                else => false,
            },
        };
    }
};

// =============================================================================
// JSON-RPC Error
// =============================================================================

pub const JsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?[]const u8 = null,
};

/// Standard JSON-RPC error codes
pub const ErrorCode = struct {
    pub const parse_error: i32 = -32700;
    pub const invalid_request: i32 = -32600;
    pub const method_not_found: i32 = -32601;
    pub const invalid_params: i32 = -32602;
    pub const internal_error: i32 = -32603;
};

// =============================================================================
// Parsed Permission Request
// =============================================================================

/// Parsed permission option from agent
pub const ParsedPermissionOption = struct {
    option_id: []const u8,
    name: []const u8,
    kind: types.PermissionKind,

    pub fn deinit(self: *ParsedPermissionOption, allocator: Allocator) void {
        allocator.free(self.option_id);
        allocator.free(self.name);
    }
};

/// Parsed permission request from agent
pub const ParsedPermissionRequest = struct {
    session_id: []const u8,
    tool_call_id: []const u8,
    title: []const u8,
    description: ?[]const u8,
    options: []ParsedPermissionOption,

    pub fn deinit(self: *ParsedPermissionRequest, allocator: Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.tool_call_id);
        allocator.free(self.title);
        if (self.description) |d| allocator.free(d);
        for (self.options) |*opt| {
            opt.deinit(allocator);
        }
        allocator.free(self.options);
    }
};

// =============================================================================
// Parsed Terminal Types
// =============================================================================

/// Environment variable key-value pair
pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,

    pub fn deinit(self: *EnvVar, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

/// Parsed terminal/create params
pub const ParsedTerminalCreate = struct {
    session_id: []const u8,
    command: []const u8,
    args: [][]const u8,
    env: []EnvVar,
    cwd: ?[]const u8,
    output_byte_limit: ?u32,

    pub fn deinit(self: *ParsedTerminalCreate, allocator: Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.command);
        for (self.args) |arg| {
            allocator.free(arg);
        }
        if (self.args.len > 0) allocator.free(self.args);
        for (self.env) |*ev| {
            ev.deinit(allocator);
        }
        if (self.env.len > 0) allocator.free(self.env);
        if (self.cwd) |c| allocator.free(c);
    }
};

/// Parsed terminal ID params (for output, wait, kill, release)
pub const ParsedTerminalId = struct {
    session_id: []const u8,
    terminal_id: []const u8,

    pub fn deinit(self: *ParsedTerminalId, allocator: Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.terminal_id);
    }
};

// =============================================================================
// Decoded Message Types
// =============================================================================

/// Decoded request (has id and method)
pub const Request = struct {
    id: JsonRpcId,
    method: []const u8,
    params_json: ?[]const u8,
};

/// Decoded response (has id, no method)
pub const Response = struct {
    id: ?JsonRpcId,
    result_json: ?[]const u8,
    error_msg: ?JsonRpcError,
};

/// Decoded notification (no id, has method)
pub const Notification = struct {
    method: []const u8,
    params_json: ?[]const u8,
};

/// Union of all decoded message types
pub const DecodedMessage = union(enum) {
    request: Request,
    response: Response,
    notification: Notification,

    pub fn deinit(self: *DecodedMessage, allocator: Allocator) void {
        switch (self.*) {
            .request => |*r| {
                switch (r.id) {
                    .string => |s| allocator.free(s),
                    else => {},
                }
                allocator.free(r.method);
                if (r.params_json) |p| allocator.free(p);
            },
            .response => |*r| {
                if (r.id) |id| {
                    switch (id) {
                        .string => |s| allocator.free(s),
                        else => {},
                    }
                }
                if (r.result_json) |res| allocator.free(res);
                if (r.error_msg) |e| allocator.free(e.message);
            },
            .notification => |*n| {
                allocator.free(n.method);
                if (n.params_json) |p| allocator.free(p);
            },
        }
    }
};

// =============================================================================
// Encoder
// =============================================================================

/// Encode JSON-RPC messages for sending to agent
pub const Encoder = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) Encoder {
        return .{ .allocator = allocator };
    }

    /// Encode a request (client -> agent)
    pub fn encodeRequest(self: *Encoder, id: i64, method: []const u8, params_json: ?[]const u8) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        if (params_json) |params| {
            try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":{f},\"params\":{s}}}", .{
                id,
                std.json.fmt(method, .{}),
                params,
            });
        } else {
            try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":{f}}}", .{
                id,
                std.json.fmt(method, .{}),
            });
        }

        return output.toOwnedSlice(self.allocator);
    }

    /// Encode a response (client -> agent, for agent-initiated requests)
    pub fn encodeResponse(self: *Encoder, id: JsonRpcId, result_json: ?[]const u8) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try self.writeId(writer, id);

        if (result_json) |result| {
            try writer.writeAll(",\"result\":");
            try writer.writeAll(result);
        } else {
            try writer.writeAll(",\"result\":null");
        }

        try writer.writeAll("}");
        return output.toOwnedSlice(self.allocator);
    }

    /// Encode a notification (client -> agent, no response expected)
    pub fn encodeNotification(self: *Encoder, method: []const u8, params_json: ?[]const u8) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        if (params_json) |params| {
            try writer.print("{{\"jsonrpc\":\"2.0\",\"method\":{f},\"params\":{s}}}", .{
                std.json.fmt(method, .{}),
                params,
            });
        } else {
            try writer.print("{{\"jsonrpc\":\"2.0\",\"method\":{f}}}", .{
                std.json.fmt(method, .{}),
            });
        }

        return output.toOwnedSlice(self.allocator);
    }

    /// Encode an error response (client -> agent)
    pub fn encodeError(self: *Encoder, id: JsonRpcId, code: i32, message: []const u8) ![]u8 {
        return self.encodeErrorResponse(id, code, message);
    }

    /// Encode an error response (client -> agent)
    pub fn encodeErrorResponse(self: *Encoder, id: JsonRpcId, code: i32, message: []const u8) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try self.writeId(writer, id);
        try writer.print(",\"error\":{{\"code\":{d},\"message\":{f}}}}}", .{
            code,
            std.json.fmt(message, .{}),
        });

        return output.toOwnedSlice(self.allocator);
    }

    /// Encode initialize params to JSON
    pub fn encodeInitializeParams(self: *Encoder, params: protocol.InitializeParams) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.print("{{\"protocolVersion\":{d}", .{params.protocol_version});

        // Client capabilities (use "fs" not "fileSystem" per ACP spec)
        try writer.print(",\"clientCapabilities\":{{\"fs\":{{\"readTextFile\":{},\"writeTextFile\":{}}},\"terminal\":{}}}", .{
            params.client_capabilities.file_system.read_text_file,
            params.client_capabilities.file_system.write_text_file,
            params.client_capabilities.terminal,
        });

        // Client info
        try writer.print(",\"clientInfo\":{{\"name\":{f}", .{std.json.fmt(params.client_info.name, .{})});
        if (params.client_info.title) |title| {
            try writer.print(",\"title\":{f}", .{std.json.fmt(title, .{})});
        }
        try writer.print(",\"version\":{f}}}}}", .{std.json.fmt(params.client_info.version, .{})});

        return output.toOwnedSlice(self.allocator);
    }

    /// Encode session/new params to JSON
    pub fn encodeSessionNewParams(self: *Encoder, params: protocol.SessionNewParams) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.print("{{\"cwd\":{f},\"mcpServers\":[", .{std.json.fmt(params.cwd, .{})});

        for (params.mcp_servers, 0..) |server, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print("{{\"name\":{f}", .{std.json.fmt(server.name, .{})});
            if (server.transport_json) |transport| {
                try writer.print(",\"transport\":{s}}}", .{transport});
            } else {
                try writer.writeByte('}');
            }
        }

        try writer.writeByte(']');

        // Add resume field if present (for session resumption)
        // Claude Code ACP expects: _meta.claudeCode.options.resume
        if (params.@"resume") |session_id| {
            try writer.print(",\"_meta\":{{\"claudeCode\":{{\"options\":{{\"resume\":{f}}}}}}}", .{std.json.fmt(session_id, .{})});
        }

        try writer.writeByte('}');
        return output.toOwnedSlice(self.allocator);
    }

    /// Encode session/load params to JSON
    pub fn encodeSessionLoadParams(self: *Encoder, params: protocol.SessionLoadParams) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.print("{{\"sessionId\":{f},\"cwd\":{f},\"mcpServers\":[", .{
            std.json.fmt(params.session_id, .{}),
            std.json.fmt(params.cwd, .{}),
        });

        for (params.mcp_servers, 0..) |server, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print("{{\"name\":{f}", .{std.json.fmt(server.name, .{})});
            if (server.transport_json) |transport| {
                try writer.print(",\"transport\":{s}}}", .{transport});
            } else {
                try writer.writeByte('}');
            }
        }

        try writer.writeAll("]}");
        return output.toOwnedSlice(self.allocator);
    }

    /// Encode session/prompt params to JSON
    pub fn encodeSessionPromptParams(self: *Encoder, params: protocol.SessionPromptParams) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.print("{{\"sessionId\":{f},\"prompt\":[", .{std.json.fmt(params.session_id, .{})});

        for (params.content, 0..) |block, i| {
            if (i > 0) try writer.writeByte(',');
            switch (block) {
                .text => |t| {
                    try writer.print("{{\"type\":\"text\",\"text\":{f}}}", .{std.json.fmt(t.text, .{})});
                },
                .resource_link => |r| {
                    try writer.print("{{\"type\":\"resourceLink\",\"uri\":{f}", .{std.json.fmt(r.uri, .{})});
                    if (r.name) |name| {
                        try writer.print(",\"name\":{f}}}", .{std.json.fmt(name, .{})});
                    } else {
                        try writer.writeByte('}');
                    }
                },
                .embedded_resource => |e| {
                    try writer.print("{{\"type\":\"resource\",\"resource\":{{\"uri\":{f},\"mimeType\":{f},\"text\":{f}}}}}", .{
                        std.json.fmt(e.resource.uri, .{}),
                        std.json.fmt(e.resource.mimeType, .{}),
                        std.json.fmt(e.resource.text, .{}),
                    });
                },
                .diff => {
                    // Diff content is only received from agents, not sent
                    // Skip silently (shouldn't happen in practice)
                },
            }
        }

        try writer.writeAll("]}");
        return output.toOwnedSlice(self.allocator);
    }

    /// Encode session/cancel params to JSON
    pub fn encodeSessionCancelParams(self: *Encoder, params: protocol.SessionCancelParams) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.print("{{\"sessionId\":{f}}}", .{std.json.fmt(params.session_id, .{})});

        return output.toOwnedSlice(self.allocator);
    }

    /// Encode session/set_mode params to JSON
    pub fn encodeSessionSetModeParams(self: *Encoder, params: protocol.SessionSetModeParams) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.print("{{\"sessionId\":{f},\"modeId\":{f}}}", .{
            std.json.fmt(params.session_id, .{}),
            std.json.fmt(params.mode_id, .{}),
        });

        return output.toOwnedSlice(self.allocator);
    }

    /// Encode session/set_model params to JSON
    pub fn encodeSessionSetModelParams(self: *Encoder, params: protocol.SessionSetModelParams) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.print("{{\"sessionId\":{f},\"modelId\":{f}}}", .{
            std.json.fmt(params.session_id, .{}),
            std.json.fmt(params.model_id, .{}),
        });

        return output.toOwnedSlice(self.allocator);
    }

    /// Encode fs/read_text_file result to JSON
    pub fn encodeReadTextFileResult(self: *Encoder, result: protocol.ReadTextFileResult) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.print("{{\"content\":{f}}}", .{std.json.fmt(result.content, .{})});

        return output.toOwnedSlice(self.allocator);
    }

    /// Encode permission response to JSON per ACP spec:
    /// https://agentclientprotocol.com/protocol/tool-calls#requesting-permission
    /// Result: {"outcome":{"outcome":"selected","optionId":"..."}} or {"outcome":{"outcome":"cancelled"}}
    pub fn encodePermissionResult(self: *Encoder, selected_option: ?[]const u8) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        if (selected_option) |option| {
            try writer.print("{{\"outcome\":{{\"outcome\":\"selected\",\"optionId\":{f}}}}}", .{
                std.json.fmt(option, .{}),
            });
        } else {
            try writer.writeAll("{\"outcome\":{\"outcome\":\"cancelled\"}}");
        }

        return output.toOwnedSlice(self.allocator);
    }

    fn writeId(self: *Encoder, writer: anytype, id: JsonRpcId) !void {
        _ = self;
        switch (id) {
            .string => |s| try writer.print("{f}", .{std.json.fmt(s, .{})}),
            .number => |n| try writer.print("{d}", .{n}),
            .null_value => try writer.writeAll("null"),
        }
    }

    pub fn deinit(self: *Encoder) void {
        _ = self;
        // Encoder doesn't hold any state that needs cleanup
    }
};

// =============================================================================
// Decoder
// =============================================================================

/// Decode JSON-RPC messages from agent
pub const Decoder = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) Decoder {
        return .{ .allocator = allocator };
    }

    /// Decode a JSON-RPC message line
    pub fn decode(self: *Decoder, line: []const u8) !DecodedMessage {
        const trimmed = std.mem.trimRight(u8, line, "\n\r");

        // Parse as generic JSON first
        const parsed = std.json.parseFromSlice(RawMessage, self.allocator, trimmed, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            std.log.err("ACP JSON parse error: {} for: {s}", .{ err, trimmed });
            return error.InvalidJson;
        };
        defer parsed.deinit();

        const msg = parsed.value;

        // Validate jsonrpc version
        if (!std.mem.eql(u8, msg.jsonrpc, "2.0")) {
            return error.InvalidJsonRpcVersion;
        }

        // Determine message type based on presence of id and method
        const has_id = msg.id != null;
        const has_method = msg.method != null;

        if (has_id and has_method) {
            // Request: has id AND method
            return .{ .request = .{
                .id = try self.parseId(msg.id.?),
                .method = try self.allocator.dupe(u8, msg.method.?),
                .params_json = try self.stringifyValue(msg.params),
            } };
        } else if (has_id) {
            // Response: has id, no method
            return .{ .response = .{
                .id = try self.parseId(msg.id.?),
                .result_json = try self.stringifyValue(msg.result),
                .error_msg = if (msg.@"error") |e| blk: {
                    break :blk .{
                        .code = e.code,
                        .message = try self.allocator.dupe(u8, e.message),
                        .data = null,
                    };
                } else null,
            } };
        } else if (has_method) {
            // Notification: no id, has method
            return .{ .notification = .{
                .method = try self.allocator.dupe(u8, msg.method.?),
                .params_json = try self.stringifyValue(msg.params),
            } };
        } else {
            return error.InvalidMessage;
        }
    }

    fn parseId(self: *Decoder, value: std.json.Value) !JsonRpcId {
        return switch (value) {
            .string => |s| .{ .string = try self.allocator.dupe(u8, s) },
            .integer => |n| .{ .number = n },
            .null => .{ .null_value = {} },
            else => error.InvalidId,
        };
    }

    fn stringifyValue(self: *Decoder, value: ?std.json.Value) !?[]u8 {
        if (value == null) return null;

        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);
        try writer.print("{f}", .{std.json.fmt(value.?, .{})});
        const result = try output.toOwnedSlice(self.allocator);
        return result;
    }

    /// Parse initialize result from JSON
    pub fn parseInitializeResult(self: *Decoder, json: []const u8) !protocol.InitializeResult {
        const parsed = try std.json.parseFromSlice(RawInitializeResult, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const r = parsed.value;

        // Check if agentCapabilities.sessionCapabilities.resume is present (even if empty {})
        // Claude Code ACP advertises: agentCapabilities: { sessionCapabilities: { resume: {} } }
        const supports_resume = if (r.agentCapabilities) |ac|
            if (ac.sessionCapabilities) |sc| sc.@"resume" != null else false
        else
            false;

        return .{
            .protocol_version = r.protocolVersion,
            .agent_capabilities = .{
                .load_session = if (r.agentCapabilities) |ac| ac.loadSession orelse false else false,
                .prompt = .{
                    .image = if (r.agentCapabilities) |ac| if (ac.prompt) |p| p.image orelse false else false else false,
                    .audio = if (r.agentCapabilities) |ac| if (ac.prompt) |p| p.audio orelse false else false else false,
                    .embedded_context = if (r.agentCapabilities) |ac| if (ac.prompt) |p| p.embeddedContext orelse false else false else false,
                },
                .session_capabilities = .{
                    .@"resume" = supports_resume,
                },
            },
            .agent_info = .{
                .name = try self.allocator.dupe(u8, if (r.agentInfo) |ai| ai.name else "unknown"),
                .title = if (r.agentInfo) |ai| if (ai.title) |t| try self.allocator.dupe(u8, t) else null else null,
                .version = try self.allocator.dupe(u8, if (r.agentInfo) |ai| ai.version else "0.0.0"),
            },
        };
    }

    /// Parse session/new result from JSON
    pub fn parseSessionNewResult(self: *Decoder, json: []const u8) !protocol.SessionNewResult {
        const RawMode = struct {
            id: []const u8,
            name: ?[]const u8 = null,
            description: ?[]const u8 = null,
        };

        const RawModes = struct {
            currentModeId: ?[]const u8 = null,
            availableModes: ?[]const RawMode = null,
        };

        const RawModel = struct {
            modelId: []const u8,
            name: ?[]const u8 = null,
            displayName: ?[]const u8 = null, // Claude Code uses displayName
            description: ?[]const u8 = null,
        };

        const RawModels = struct {
            currentModelId: ?[]const u8 = null,
            availableModels: ?[]const RawModel = null,
        };

        const RawResult = struct {
            sessionId: []const u8,
            modes: ?RawModes = null,
            models: ?RawModels = null,
        };

        const parsed = try std.json.parseFromSlice(RawResult, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const r = parsed.value;

        // Parse modes if present
        var modes: ?protocol.SessionModes = null;
        if (r.modes) |raw_modes| {
            var available_modes: std.ArrayListUnmanaged(protocol.ModeInfo) = .{};
            errdefer {
                for (available_modes.items) |*m| {
                    self.allocator.free(m.id);
                    if (m.name) |n| self.allocator.free(n);
                    if (m.description) |d| self.allocator.free(d);
                }
                available_modes.deinit(self.allocator);
            }

            if (raw_modes.availableModes) |raw_avail| {
                for (raw_avail) |rm| {
                    try available_modes.append(self.allocator, .{
                        .id = try self.allocator.dupe(u8, rm.id),
                        .name = if (rm.name) |n| try self.allocator.dupe(u8, n) else null,
                        .description = if (rm.description) |d| try self.allocator.dupe(u8, d) else null,
                    });
                }
            }

            modes = .{
                .current_mode_id = if (raw_modes.currentModeId) |id| try self.allocator.dupe(u8, id) else null,
                .available_modes = try available_modes.toOwnedSlice(self.allocator),
            };
        }

        // Parse models if present
        var models: ?protocol.SessionModels = null;
        if (r.models) |raw_models| {
            var available_models: std.ArrayListUnmanaged(protocol.ModelInfo) = .{};
            errdefer {
                for (available_models.items) |*m| {
                    self.allocator.free(m.model_id);
                    if (m.name) |n| self.allocator.free(n);
                    if (m.description) |d| self.allocator.free(d);
                }
                available_models.deinit(self.allocator);
            }

            if (raw_models.availableModels) |raw_avail| {
                for (raw_avail) |rm| {
                    // Prefer displayName (Claude Code) over name (Codex), fall back to null
                    const model_name = rm.displayName orelse rm.name;
                    try available_models.append(self.allocator, .{
                        .model_id = try self.allocator.dupe(u8, rm.modelId),
                        .name = if (model_name) |n| try self.allocator.dupe(u8, n) else null,
                        .description = if (rm.description) |d| try self.allocator.dupe(u8, d) else null,
                    });
                }
            }

            models = .{
                .current_model_id = if (raw_models.currentModelId) |id| try self.allocator.dupe(u8, id) else null,
                .available_models = try available_models.toOwnedSlice(self.allocator),
            };
        }

        return .{
            .session_id = try self.allocator.dupe(u8, r.sessionId),
            .modes = modes,
            .models = models,
        };
    }

    /// Parse session/prompt result from JSON
    pub fn parseSessionPromptResult(self: *Decoder, json: []const u8) !protocol.SessionPromptResult {
        _ = self;
        const parsed = try std.json.parseFromSlice(struct {
            stopReason: []const u8,
        }, std.heap.page_allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        return .{
            .stop_reason = types.StopReason.fromString(parsed.value.stopReason) orelse .end_turn,
        };
    }

    /// Parse fs/read_text_file params from JSON
    pub fn parseReadTextFileParams(self: *Decoder, json: []const u8) !protocol.ReadTextFileParams {
        const parsed = try std.json.parseFromSlice(struct {
            sessionId: []const u8,
            path: []const u8,
            line: ?u32 = null,
            limit: ?u32 = null,
        }, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        return .{
            .session_id = try self.allocator.dupe(u8, parsed.value.sessionId),
            .path = try self.allocator.dupe(u8, parsed.value.path),
            .line = parsed.value.line,
            .limit = parsed.value.limit,
        };
    }

    /// Parse fs/write_text_file params from JSON
    pub fn parseWriteTextFileParams(self: *Decoder, json: []const u8) !protocol.WriteTextFileParams {
        const parsed = try std.json.parseFromSlice(struct {
            sessionId: []const u8,
            path: []const u8,
            content: []const u8,
        }, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        return .{
            .session_id = try self.allocator.dupe(u8, parsed.value.sessionId),
            .path = try self.allocator.dupe(u8, parsed.value.path),
            .content = try self.allocator.dupe(u8, parsed.value.content),
        };
    }

    /// Parse terminal/create params from JSON
    pub fn parseTerminalCreateParams(self: *Decoder, json: []const u8) !ParsedTerminalCreate {
        const RawEnvVar = struct {
            name: []const u8,
            value: []const u8,
        };

        const parsed = try std.json.parseFromSlice(struct {
            sessionId: []const u8,
            command: []const u8,
            args: ?[]const []const u8 = null,
            env: ?[]const RawEnvVar = null,
            cwd: ?[]const u8 = null,
            outputByteLimit: ?u32 = null,
        }, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        // Duplicate strings we need to keep
        const session_id = try self.allocator.dupe(u8, parsed.value.sessionId);
        errdefer self.allocator.free(session_id);

        const command = try self.allocator.dupe(u8, parsed.value.command);
        errdefer self.allocator.free(command);

        const cwd = if (parsed.value.cwd) |c| try self.allocator.dupe(u8, c) else null;
        errdefer if (cwd) |c| self.allocator.free(c);

        // Duplicate args array
        var args: [][]const u8 = &.{};
        if (parsed.value.args) |raw_args| {
            const args_alloc = try self.allocator.alloc([]const u8, raw_args.len);
            for (raw_args, 0..) |arg, i| {
                args_alloc[i] = try self.allocator.dupe(u8, arg);
            }
            args = args_alloc;
        }

        // Duplicate env vars array
        var env: []EnvVar = &.{};
        if (parsed.value.env) |raw_env| {
            const env_alloc = try self.allocator.alloc(EnvVar, raw_env.len);
            for (raw_env, 0..) |ev, i| {
                env_alloc[i] = .{
                    .name = try self.allocator.dupe(u8, ev.name),
                    .value = try self.allocator.dupe(u8, ev.value),
                };
            }
            env = env_alloc;
        }

        return .{
            .session_id = session_id,
            .command = command,
            .args = args,
            .env = env,
            .cwd = cwd,
            .output_byte_limit = parsed.value.outputByteLimit,
        };
    }

    /// Parse terminal/output params from JSON
    pub fn parseTerminalOutputParams(self: *Decoder, json: []const u8) !ParsedTerminalId {
        const parsed = try std.json.parseFromSlice(struct {
            sessionId: []const u8,
            terminalId: []const u8,
        }, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        return .{
            .session_id = try self.allocator.dupe(u8, parsed.value.sessionId),
            .terminal_id = try self.allocator.dupe(u8, parsed.value.terminalId),
        };
    }

    /// Parse terminal/wait_for_exit params from JSON (same format as output)
    pub const parseTerminalWaitParams = parseTerminalOutputParams;

    /// Parse terminal/kill params from JSON (same format as output)
    pub const parseTerminalKillParams = parseTerminalOutputParams;

    /// Parse terminal/release params from JSON (same format as output)
    pub const parseTerminalReleaseParams = parseTerminalOutputParams;

    /// Parse session/request_permission params from JSON
    /// Handles Claude Code ACP format where toolCallId/title are nested inside toolCall object
    pub fn parseRequestPermissionParams(self: *Decoder, json: []const u8) !ParsedPermissionRequest {
        const RawOption = struct {
            optionId: []const u8,
            name: []const u8,
            kind: ?[]const u8 = null,
        };

        // Claude Code ACP format: toolCallId and title are inside toolCall object
        const RawToolCall = struct {
            toolCallId: []const u8,
            title: ?[]const u8 = null,
            rawInput: ?std.json.Value = null,
        };

        const RawParams = struct {
            sessionId: []const u8,
            // Flat format (legacy)
            toolCallId: ?[]const u8 = null,
            title: ?[]const u8 = null,
            // Nested format (Claude Code ACP)
            toolCall: ?RawToolCall = null,
            description: ?[]const u8 = null,
            options: ?[]const RawOption = null,
        };

        const parsed = try std.json.parseFromSlice(RawParams, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const r = parsed.value;

        // Extract toolCallId and title from either flat or nested format
        const tool_call_id: []const u8 = if (r.toolCall) |tc|
            tc.toolCallId
        else if (r.toolCallId) |id|
            id
        else
            return error.MissingField;

        const title: []const u8 = if (r.toolCall) |tc|
            tc.title orelse "Tool call"
        else if (r.title) |t|
            t
        else
            "Tool call";

        // Parse options
        var options: std.ArrayList(ParsedPermissionOption) = .{};
        errdefer {
            for (options.items) |*opt| {
                self.allocator.free(opt.option_id);
                self.allocator.free(opt.name);
            }
            options.deinit(self.allocator);
        }

        if (r.options) |raw_opts| {
            for (raw_opts) |opt| {
                try options.append(self.allocator, .{
                    .option_id = try self.allocator.dupe(u8, opt.optionId),
                    .name = try self.allocator.dupe(u8, opt.name),
                    .kind = if (opt.kind) |k| types.PermissionKind.fromString(k) orelse .allow_once else .allow_once,
                });
            }
        }

        return .{
            .session_id = try self.allocator.dupe(u8, r.sessionId),
            .tool_call_id = try self.allocator.dupe(u8, tool_call_id),
            .title = try self.allocator.dupe(u8, title),
            .description = if (r.description) |d| try self.allocator.dupe(u8, d) else null,
            .options = try options.toOwnedSlice(self.allocator),
        };
    }

    /// Parse session/update params from JSON (for notifications)
    pub fn parseSessionUpdateParams(self: *Decoder, json: []const u8) !protocol.SessionUpdateParams {
        // Log raw JSON for debugging (truncated)
        const max_log_len = 800;
        const log_json = if (json.len > max_log_len) json[0..max_log_len] else json;
        std.log.info("CODEC: parseSessionUpdateParams len={d} JSON: {s}...", .{ json.len, log_json });

        const parsed = try std.json.parseFromSlice(RawSessionUpdate, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const r = parsed.value;

        // Parse message content if present
        var message_result: ?protocol.MessageUpdate = null;
        var tool_call_result: ?protocol.ToolCall = null;
        var tool_call_update_result: ?protocol.ToolCallUpdate = null;
        var update_type: protocol.SessionUpdateType = .unknown;

        // Handle Claude Code ACP format: update.content
        if (r.update) |upd| {
            // Get the update type (agent_message_chunk, agent_thought_chunk, tool_call, etc.)
            if (upd.sessionUpdate) |session_update_type| {
                update_type = protocol.SessionUpdateType.fromString(session_update_type);
                std.log.info("CODEC: update_type={s}", .{session_update_type});
            } else {
                std.log.info("CODEC: no sessionUpdate field", .{});
            }

            // Extract tool name from _meta.claudeCode
            var tool_name: ?[]const u8 = null;
            var tool_response_stdout: ?[]const u8 = null;
            var tool_response_stderr: ?[]const u8 = null;
            var tool_response_interrupted: bool = false;

            if (upd._meta) |meta| {
                std.log.info("CODEC: _meta present, claudeCode={}", .{meta.claudeCode != null});
                if (meta.claudeCode) |cc| {
                    std.log.info("CODEC: claudeCode.toolName={?s}, toolResponse={}", .{ cc.toolName, cc.toolResponse != null });
                    if (cc.toolName) |tn| {
                        tool_name = self.allocator.dupe(u8, tn) catch null;
                    }
                    // toolResponse can be either:
                    // - array of content blocks: [{"type":"text","text":"..."}]
                    // - object with stdout/stderr (older format)
                    if (cc.toolResponse) |tr| {
                        switch (tr) {
                            .array => |arr| {
                                std.log.info("CODEC: toolResponse is array with {d} items", .{arr.items.len});
                                // Extract text from content blocks
                                for (arr.items) |item| {
                                    if (item == .object) {
                                        const obj = item.object;
                                        if (obj.get("type")) |type_val| {
                                            if (type_val == .string and std.mem.eql(u8, type_val.string, "text")) {
                                                if (obj.get("text")) |text_val| {
                                                    if (text_val == .string) {
                                                        std.log.info("CODEC: found toolResponse text, len={d}", .{text_val.string.len});
                                                        tool_response_stdout = self.allocator.dupe(u8, text_val.string) catch null;
                                                        break;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            },
                            .object => |obj| {
                                // Older format with stdout/stderr fields
                                if (obj.get("stdout")) |s| {
                                    if (s == .string) {
                                        std.log.info("CODEC: toolResponse.stdout len={d}", .{s.string.len});
                                        tool_response_stdout = self.allocator.dupe(u8, s.string) catch null;
                                    }
                                }
                                if (obj.get("stderr")) |s| {
                                    if (s == .string) {
                                        tool_response_stderr = self.allocator.dupe(u8, s.string) catch null;
                                    }
                                }
                                if (obj.get("interrupted")) |i| {
                                    if (i == .bool) {
                                        tool_response_interrupted = i.bool;
                                    }
                                }
                            },
                            else => {
                                std.log.info("CODEC: toolResponse is unexpected type: {s}", .{@tagName(tr)});
                            },
                        }
                    }
                }
            } else {
                std.log.info("CODEC: no _meta field", .{});
            }

            // Extract command/file_path from rawInput for tool calls
            var command: ?[]const u8 = null;
            var description: ?[]const u8 = null;

            if (upd.rawInput) |raw_input| {
                if (raw_input == .object) {
                    // Bash tool: extract command
                    if (raw_input.object.get("command")) |cmd| {
                        if (cmd == .string) {
                            command = self.allocator.dupe(u8, cmd.string) catch null;
                        }
                    }
                    // Read tool: extract file_path (use command field for display)
                    if (raw_input.object.get("file_path")) |fp| {
                        if (fp == .string) {
                            command = self.allocator.dupe(u8, fp.string) catch null;
                        }
                    }
                    if (raw_input.object.get("description")) |desc| {
                        if (desc == .string) {
                            description = self.allocator.dupe(u8, desc.string) catch null;
                        }
                    }
                }
            }

            // Handle tool_call_update (completion/status update)
            if (update_type == .tool_call_update) {
                const tool_call_id = if (upd.toolCallId) |id|
                    self.allocator.dupe(u8, id) catch ""
                else
                    "";

                std.log.info("CODEC: tool_call_update id={s} has_content={} stdout_len={?d} rawOutput={}", .{
                    tool_call_id,
                    upd.content != null,
                    if (tool_response_stdout) |s| s.len else null,
                    upd.rawOutput != null,
                });

                // Try rawOutput as fallback for stdout
                // rawOutput can be either:
                // - string: direct output (some agents)
                // - object: {"aggregated_output":"..."} (Codex format)
                if (tool_response_stdout == null and upd.rawOutput != null) {
                    const raw_out = upd.rawOutput.?;
                    switch (raw_out) {
                        .string => |s| {
                            std.log.info("CODEC: rawOutput is string, len={d}", .{s.len});
                            tool_response_stdout = self.allocator.dupe(u8, s) catch null;
                        },
                        .object => |obj| {
                            // Codex format: {"aggregated_output":"..."}
                            if (obj.get("aggregated_output")) |ao| {
                                if (ao == .string) {
                                    std.log.info("CODEC: rawOutput.aggregated_output len={d}", .{ao.string.len});
                                    tool_response_stdout = self.allocator.dupe(u8, ao.string) catch null;
                                }
                            }
                        },
                        else => {
                            std.log.info("CODEC: rawOutput is unexpected type: {s}", .{@tagName(raw_out)});
                        },
                    }
                }

                // Parse content blocks for tool_call_update
                // Structure: [{"type":"content","content":{"type":"text","text":"..."}}]
                // Or: [{"type":"text","text":"..."}]
                // Or: [{"type":"terminal","terminalId":"term_1"}]
                var update_content: []const protocol.ContentBlock = &.{};
                var terminal_id_from_content: ?[]const u8 = null;

                if (upd.content) |content_val| {
                    std.log.info("CODEC: content is {s}", .{@tagName(content_val)});
                    if (content_val == .array) {
                        std.log.info("CODEC: content array has {d} items", .{content_val.array.items.len});
                        var text_blocks: std.ArrayList(protocol.ContentBlock) = .{};
                        for (content_val.array.items, 0..) |item, idx| {
                            if (item != .object) {
                                std.log.info("CODEC: content[{d}] is not object, is {s}", .{ idx, @tagName(item) });
                                continue;
                            }
                            const obj = item.object;

                            // Log what type field we have
                            if (obj.get("type")) |type_val| {
                                if (type_val == .string) {
                                    std.log.info("CODEC: content[{d}].type = {s}", .{ idx, type_val.string });
                                }
                            }

                            // Check for type:"terminal" with terminalId
                            if (obj.get("type")) |type_val| {
                                if (type_val == .string and std.mem.eql(u8, type_val.string, "terminal")) {
                                    if (obj.get("terminalId")) |tid| {
                                        if (tid == .string) {
                                            std.log.info("CODEC: found terminal reference: {s}", .{tid.string});
                                            terminal_id_from_content = self.allocator.dupe(u8, tid.string) catch null;
                                        }
                                    }
                                    continue;
                                }
                            }

                            // Try to get text directly from {"type":"text","text":"..."}
                            if (obj.get("type")) |type_val| {
                                if (type_val == .string and std.mem.eql(u8, type_val.string, "text")) {
                                    if (obj.get("text")) |text_val| {
                                        if (text_val == .string) {
                                            std.log.info("CODEC: found direct text: {s}...", .{text_val.string[0..@min(text_val.string.len, 50)]});
                                            const text_copy = self.allocator.dupe(u8, text_val.string) catch continue;
                                            text_blocks.append(self.allocator, .{ .text = .{ .text = text_copy } }) catch {
                                                self.allocator.free(text_copy);
                                            };
                                            continue;
                                        }
                                    }
                                }
                            }

                            // Check for type:"content" wrapper
                            if (obj.get("type")) |type_val| {
                                if (type_val == .string and std.mem.eql(u8, type_val.string, "content")) {
                                    // Get nested content.text
                                    if (obj.get("content")) |inner| {
                                        if (inner == .object) {
                                            if (inner.object.get("type")) |inner_type| {
                                                if (inner_type == .string and std.mem.eql(u8, inner_type.string, "text")) {
                                                    if (inner.object.get("text")) |text_val| {
                                                        if (text_val == .string) {
                                                            std.log.info("CODEC: found nested content.text: {s}...", .{text_val.string[0..@min(text_val.string.len, 50)]});
                                                            const text_copy = self.allocator.dupe(u8, text_val.string) catch continue;
                                                            text_blocks.append(self.allocator, .{ .text = .{ .text = text_copy } }) catch {
                                                                self.allocator.free(text_copy);
                                                            };
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        std.log.info("CODEC: parsed {d} text blocks from content", .{text_blocks.items.len});
                        if (text_blocks.items.len > 0) {
                            update_content = text_blocks.toOwnedSlice(self.allocator) catch &.{};
                        }
                    }
                }

                tool_call_update_result = .{
                    .tool_call_id = tool_call_id,
                    .status = if (upd.status) |s|
                        types.ToolCallStatus.fromString(s)
                    else
                        null,
                    .tool_name = tool_name,
                    .stdout = tool_response_stdout,
                    .stderr = tool_response_stderr,
                    .interrupted = tool_response_interrupted,
                    .content = update_content,
                    .terminal_id = terminal_id_from_content,
                };
            }

            // Handle content for text streaming or tool_call with diffs
            if (upd.content) |content_val| {
                switch (content_val) {
                    .object => |obj| {
                        // Single content object - check for text
                        if (obj.get("type")) |type_val| {
                            if (type_val == .string and std.mem.eql(u8, type_val.string, "text")) {
                                if (obj.get("text")) |text_val| {
                                    if (text_val == .string and text_val.string.len > 0) {
                                        const text_copy = self.allocator.dupe(u8, text_val.string) catch return error.OutOfMemory;
                                        const content_arr = self.allocator.alloc(protocol.ContentBlock, 1) catch {
                                            self.allocator.free(text_copy);
                                            return error.OutOfMemory;
                                        };
                                        content_arr[0] = .{ .text = .{ .text = text_copy } };
                                        message_result = .{ .content = content_arr };
                                    }
                                }
                            }
                        }
                    },
                    .array => |arr| {
                        // Array of content blocks - check for diffs (tool_call)
                        var diff_count: usize = 0;
                        for (arr.items) |item| {
                            if (item == .object) {
                                if (item.object.get("type")) |type_val| {
                                    if (type_val == .string and std.mem.eql(u8, type_val.string, "diff")) {
                                        diff_count += 1;
                                    }
                                }
                            }
                        }

                        if (diff_count > 0) {
                            const content_arr = self.allocator.alloc(protocol.ContentBlock, diff_count) catch return error.OutOfMemory;
                            var i: usize = 0;

                            for (arr.items) |item| {
                                if (item != .object) continue;
                                const obj = item.object;

                                if (obj.get("type")) |type_val| {
                                    if (type_val != .string or !std.mem.eql(u8, type_val.string, "diff")) continue;

                                    const path = if (obj.get("path")) |v| if (v == .string) v.string else "" else "";
                                    const old_text = if (obj.get("oldText")) |v| if (v == .string) v.string else "" else "";
                                    const new_text = if (obj.get("newText")) |v| if (v == .string) v.string else "" else "";

                                    const path_copy = self.allocator.dupe(u8, path) catch continue;
                                    const old_copy = self.allocator.dupe(u8, old_text) catch {
                                        self.allocator.free(path_copy);
                                        continue;
                                    };
                                    const new_copy = self.allocator.dupe(u8, new_text) catch {
                                        self.allocator.free(path_copy);
                                        self.allocator.free(old_copy);
                                        continue;
                                    };

                                    content_arr[i] = .{
                                        .diff = .{
                                            .path = path_copy,
                                            .old_text = old_copy,
                                            .new_text = new_copy,
                                        },
                                    };
                                    i += 1;
                                }
                            }

                            if (i > 0) {
                                // Build tool_call with diff content
                                const tool_call_id = if (upd.toolCallId) |id|
                                    self.allocator.dupe(u8, id) catch ""
                                else
                                    "";
                                const title = if (upd.title) |t|
                                    self.allocator.dupe(u8, t) catch null
                                else
                                    null;

                                tool_call_result = .{
                                    .tool_call_id = tool_call_id,
                                    .title = title,
                                    .kind = if (upd.kind) |k|
                                        if (std.mem.eql(u8, k, "edit")) .edit else .other
                                    else
                                        .other,
                                    .status = if (upd.status) |s|
                                        types.ToolCallStatus.fromString(s) orelse .pending
                                    else
                                        .pending,
                                    .content = content_arr[0..i],
                                    .tool_name = tool_name,
                                    .command = command,
                                    .description = description,
                                };
                            }
                        }
                    },
                    else => {},
                }
            }

            // Build tool_call for non-diff tools (like Bash) when we have a tool_call update type
            if (update_type == .tool_call and tool_call_result == null and upd.toolCallId != null) {
                const tool_call_id = self.allocator.dupe(u8, upd.toolCallId.?) catch "";
                const title = if (upd.title) |t|
                    self.allocator.dupe(u8, t) catch null
                else
                    null;

                tool_call_result = .{
                    .tool_call_id = tool_call_id,
                    .title = title,
                    .kind = if (upd.kind) |k| blk: {
                        if (std.mem.eql(u8, k, "edit")) break :blk types.ToolCallKind.edit;
                        if (std.mem.eql(u8, k, "execute")) break :blk types.ToolCallKind.execute;
                        break :blk types.ToolCallKind.other;
                    } else .other,
                    .status = if (upd.status) |s|
                        types.ToolCallStatus.fromString(s) orelse .pending
                    else
                        .pending,
                    .tool_name = tool_name,
                    .command = command,
                    .description = description,
                };
            }
        }

        // Fallback: handle legacy message format if update wasn't present
        if (message_result == null and tool_call_result == null) {
            if (r.message) |msg| {
                if (msg.content) |content_blocks| {
                    var text_count: usize = 0;
                    for (content_blocks) |block| {
                        if (std.mem.eql(u8, block.type, "text") and block.text != null) {
                            text_count += 1;
                        }
                    }

                    if (text_count > 0) {
                        const content = self.allocator.alloc(protocol.ContentBlock, text_count) catch return error.OutOfMemory;
                        var i: usize = 0;
                        for (content_blocks) |block| {
                            if (std.mem.eql(u8, block.type, "text")) {
                                if (block.text) |text| {
                                    const text_copy = self.allocator.dupe(u8, text) catch continue;
                                    content[i] = .{ .text = .{ .text = text_copy } };
                                    i += 1;
                                }
                            }
                        }
                        message_result = .{ .content = content[0..i] };
                    }
                }
            }
        }

        // Handle plan updates
        var plan_result: ?protocol.PlanUpdate = null;
        if (update_type == .plan) {
            if (r.update) |upd| {
                if (upd.entries) |raw_entries| {
                    const plan_entries = self.allocator.alloc(protocol.PlanEntry, raw_entries.len) catch return error.OutOfMemory;
                    var entry_count: usize = 0;

                    for (raw_entries) |raw_entry| {
                        const content_copy = self.allocator.dupe(u8, raw_entry.content) catch continue;
                        plan_entries[entry_count] = .{
                            .content = content_copy,
                            .priority = if (raw_entry.priority) |p|
                                protocol.PlanEntryPriority.fromString(p)
                            else
                                .medium,
                            .status = if (raw_entry.status) |s|
                                protocol.PlanEntryStatus.fromString(s)
                            else
                                .pending,
                        };
                        entry_count += 1;
                    }

                    plan_result = .{ .entries = plan_entries[0..entry_count] };
                }
            }
        }

        // Handle current mode updates
        var mode_update_result: ?protocol.CurrentModeUpdate = null;
        if (update_type == .current_mode_update) {
            // Check update.currentModeId first (nested format from Claude Code)
            if (r.update) |upd| {
                if (upd.currentModeId) |mode_id| {
                    std.log.info("ACP Codec: Found currentModeId={s}", .{mode_id});
                    mode_update_result = .{
                        .mode_id = self.allocator.dupe(u8, mode_id) catch "",
                    };
                }
            }
            // Fallback to top-level currentModeUpdate (some agents may use this)
            if (mode_update_result == null and r.currentModeUpdate != null) {
                const mode_id = r.currentModeUpdate.?.modeId;
                std.log.info("ACP Codec: Found modeId at top-level={s}", .{mode_id});
                mode_update_result = .{
                    .mode_id = self.allocator.dupe(u8, mode_id) catch "",
                };
            }
            if (mode_update_result == null) {
                std.log.warn("ACP Codec: current_mode_update notification had no currentModeId!", .{});
            }
        }

        // Handle available commands updates (slash commands)
        var commands_result: ?protocol.AvailableCommandsUpdate = null;
        if (update_type == .available_commands_update) {
            // Check update.availableCommands (nested format from agent)
            if (r.update) |upd| {
                if (upd.availableCommands) |raw_commands| {
                    const commands = self.allocator.alloc(protocol.AvailableCommand, raw_commands.len) catch return error.OutOfMemory;
                    var cmd_count: usize = 0;

                    for (raw_commands) |raw_cmd| {
                        const name_copy = self.allocator.dupe(u8, raw_cmd.name) catch continue;
                        const desc_copy = self.allocator.dupe(u8, raw_cmd.description) catch {
                            self.allocator.free(name_copy);
                            continue;
                        };
                        const input_copy: ?protocol.AvailableCommandInput = if (raw_cmd.input) |input| blk: {
                            const hint_copy = self.allocator.dupe(u8, input.hint) catch {
                                self.allocator.free(name_copy);
                                self.allocator.free(desc_copy);
                                continue;
                            };
                            break :blk .{ .hint = hint_copy };
                        } else null;

                        commands[cmd_count] = .{
                            .name = name_copy,
                            .description = desc_copy,
                            .input = input_copy,
                        };
                        cmd_count += 1;
                    }

                    commands_result = .{ .commands = commands[0..cmd_count] };
                }
            }
            // Fallback to top-level availableCommandsUpdate
            if (commands_result == null and r.availableCommandsUpdate != null) {
                const raw_commands = r.availableCommandsUpdate.?.commands;
                const commands = self.allocator.alloc(protocol.AvailableCommand, raw_commands.len) catch return error.OutOfMemory;
                var cmd_count: usize = 0;

                for (raw_commands) |raw_cmd| {
                    const name_copy = self.allocator.dupe(u8, raw_cmd.name) catch continue;
                    const desc_copy = self.allocator.dupe(u8, raw_cmd.description) catch {
                        self.allocator.free(name_copy);
                        continue;
                    };
                    const input_copy: ?protocol.AvailableCommandInput = if (raw_cmd.input) |input| blk: {
                        const hint_copy = self.allocator.dupe(u8, input.hint) catch {
                            self.allocator.free(name_copy);
                            self.allocator.free(desc_copy);
                            continue;
                        };
                        break :blk .{ .hint = hint_copy };
                    } else null;

                    commands[cmd_count] = .{
                        .name = name_copy,
                        .description = desc_copy,
                        .input = input_copy,
                    };
                    cmd_count += 1;
                }

                commands_result = .{ .commands = commands[0..cmd_count] };
            }
        }

        return .{
            .session_id = r.sessionId,
            .update_type = update_type,
            .message = message_result,
            .tool_call = tool_call_result,
            .tool_call_update = tool_call_update_result,
            .plan = plan_result,
            .current_mode_update = mode_update_result,
            .available_commands = commands_result,
        };
    }

    pub fn deinit(self: *Decoder) void {
        _ = self;
        // Decoder doesn't hold any state that needs cleanup
    }
};

// =============================================================================
// Raw JSON Structures for Parsing
// =============================================================================

const RawMessage = struct {
    jsonrpc: []const u8,
    id: ?std.json.Value = null,
    method: ?[]const u8 = null,
    params: ?std.json.Value = null,
    result: ?std.json.Value = null,
    @"error": ?struct {
        code: i32,
        message: []const u8,
    } = null,
};

const RawInitializeResult = struct {
    protocolVersion: u32,
    agentCapabilities: ?struct {
        loadSession: ?bool = null,
        prompt: ?struct {
            image: ?bool = null,
            audio: ?bool = null,
            embeddedContext: ?bool = null,
        } = null,
        // Claude Code ACP nests sessionCapabilities inside agentCapabilities
        sessionCapabilities: ?struct {
            // If present (even empty {}), agent supports session resume
            // via session/new with resume option
            @"resume": ?struct {} = null,
        } = null,
    } = null,
    agentInfo: ?struct {
        name: []const u8,
        title: ?[]const u8 = null,
        version: []const u8,
    } = null,
};

/// Raw plan entry for JSON parsing
const RawPlanEntry = struct {
    content: []const u8,
    priority: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

const RawAvailableCommandInput = struct {
    hint: []const u8,
};

const RawAvailableCommand = struct {
    name: []const u8,
    description: []const u8,
    input: ?RawAvailableCommandInput = null,
};

const RawSessionUpdate = struct {
    sessionId: []const u8,
    // Claude Code ACP uses "update" with nested content
    update: ?struct {
        sessionUpdate: ?[]const u8 = null,
        toolCallId: ?[]const u8 = null,
        title: ?[]const u8 = null,
        kind: ?[]const u8 = null,
        status: ?[]const u8 = null,
        // content can be object (for text) or array (for tool_call with diffs)
        content: ?std.json.Value = null,
        // rawInput contains tool-specific parameters (command for Bash, file_path for Edit, etc.)
        rawInput: ?std.json.Value = null,
        // rawOutput contains tool output (for completed tool calls)
        // Can be either a string (direct output) or object {"aggregated_output":"..."} (Codex)
        rawOutput: ?std.json.Value = null,
        // entries for plan updates
        entries: ?[]const RawPlanEntry = null,
        // Mode update for current_mode_update notifications (camelCase from agent!)
        currentModeId: ?[]const u8 = null,
        // Available commands for slash command menu (camelCase from agent)
        availableCommands: ?[]const RawAvailableCommand = null,
        // _meta contains Claude Code specific metadata
        _meta: ?struct {
            claudeCode: ?struct {
                toolName: ?[]const u8 = null,
                // toolResponse can be either:
                // - array of content blocks: [{"type":"text","text":"..."}]
                // - struct with stdout/stderr (older format)
                toolResponse: ?std.json.Value = null,
            } = null,
        } = null,
    } = null,
    // Legacy format (may not be used)
    message: ?struct {
        type: []const u8 = "message_update",
        content: ?[]const struct {
            type: []const u8,
            text: ?[]const u8 = null,
        } = null,
    } = null,
    toolCall: ?std.json.Value = null,
    toolCallUpdate: ?std.json.Value = null,
    // Top-level currentModeUpdate (some agents may use this)
    currentModeUpdate: ?struct {
        modeId: []const u8,
    } = null,
    // Top-level availableCommandsUpdate (some agents may use this)
    availableCommandsUpdate: ?struct {
        commands: []const RawAvailableCommand,
    } = null,
};

// =============================================================================
// Helper Functions
// =============================================================================

// =============================================================================
// Free Functions
// =============================================================================

pub fn freeRequest(allocator: Allocator, req: *Request) void {
    switch (req.id) {
        .string => |s| allocator.free(s),
        else => {},
    }
    allocator.free(req.method);
    if (req.params_json) |p| allocator.free(p);
}

pub fn freeResponse(allocator: Allocator, resp: *Response) void {
    if (resp.id) |id| {
        switch (id) {
            .string => |s| allocator.free(s),
            else => {},
        }
    }
    if (resp.result_json) |r| allocator.free(r);
    if (resp.error_msg) |e| allocator.free(e.message);
}

pub fn freeNotification(allocator: Allocator, notif: *Notification) void {
    allocator.free(notif.method);
    if (notif.params_json) |p| allocator.free(p);
}

pub fn freeDecodedMessage(allocator: Allocator, msg: *DecodedMessage) void {
    switch (msg.*) {
        .request => |*r| freeRequest(allocator, r),
        .response => |*r| freeResponse(allocator, r),
        .notification => |*n| freeNotification(allocator, n),
    }
}

// =============================================================================
// Tests
// =============================================================================

test "encode initialize request" {
    const allocator = std.testing.allocator;
    var encoder = Encoder.init(allocator);

    const params = try encoder.encodeInitializeParams(.{
        .protocol_version = 1,
        .client_capabilities = caps.skimClientCapabilities(),
        .client_info = caps.skimClientInfo(),
    });
    defer allocator.free(params);

    const request = try encoder.encodeRequest(0, "initialize", params);
    defer allocator.free(request);

    try std.testing.expect(std.mem.indexOf(u8, request, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"method\":\"initialize\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"protocolVersion\":1") != null);
    // Verify correct field names per ACP spec
    try std.testing.expect(std.mem.indexOf(u8, params, "\"fs\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"readTextFile\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"writeTextFile\":") != null);
}

test "decode response with result" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1}}
    ;

    var msg = try decoder.decode(json);
    defer freeDecodedMessage(allocator, &msg);

    try std.testing.expect(msg == .response);
    try std.testing.expect(msg.response.id != null);
    try std.testing.expectEqual(@as(i64, 0), msg.response.id.?.number);
    try std.testing.expect(msg.response.result_json != null);
    try std.testing.expect(msg.response.error_msg == null);
}

test "decode notification" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_123"}}
    ;

    var msg = try decoder.decode(json);
    defer freeDecodedMessage(allocator, &msg);

    try std.testing.expect(msg == .notification);
    try std.testing.expectEqualStrings("session/update", msg.notification.method);
    try std.testing.expect(msg.notification.params_json != null);
}

test "decode request from agent" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"jsonrpc":"2.0","id":100,"method":"fs/read_text_file","params":{"path":"/test.zig"}}
    ;

    var msg = try decoder.decode(json);
    defer freeDecodedMessage(allocator, &msg);

    try std.testing.expect(msg == .request);
    try std.testing.expectEqual(@as(i64, 100), msg.request.id.number);
    try std.testing.expectEqualStrings("fs/read_text_file", msg.request.method);
}

test "decode error response" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}
    ;

    var msg = try decoder.decode(json);
    defer freeDecodedMessage(allocator, &msg);

    try std.testing.expect(msg == .response);
    try std.testing.expect(msg.response.error_msg != null);
    try std.testing.expectEqual(@as(i32, -32601), msg.response.error_msg.?.code);
}

test "encode and decode roundtrip" {
    const allocator = std.testing.allocator;
    var encoder = Encoder.init(allocator);
    var decoder = Decoder.init(allocator);

    const params = try encoder.encodeSessionNewParams(.{
        .cwd = "/tmp/repo",
    });
    defer allocator.free(params);

    const request = try encoder.encodeRequest(42, "session/new", params);
    defer allocator.free(request);

    var msg = try decoder.decode(request);
    defer freeDecodedMessage(allocator, &msg);

    try std.testing.expect(msg == .request);
    try std.testing.expectEqual(@as(i64, 42), msg.request.id.number);
    try std.testing.expectEqualStrings("session/new", msg.request.method);
}

test "JsonRpcId equality" {
    const id1 = JsonRpcId{ .number = 42 };
    const id2 = JsonRpcId{ .number = 42 };
    const id3 = JsonRpcId{ .number = 43 };

    try std.testing.expect(id1.eql(id2));
    try std.testing.expect(!id1.eql(id3));
}
