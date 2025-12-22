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

        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try writer.print("{d}", .{id});
        try writer.writeAll(",\"method\":\"");
        try writer.writeAll(method);
        try writer.writeByte('"');

        if (params_json) |params| {
            try writer.writeAll(",\"params\":");
            try writer.writeAll(params);
        }

        try writer.writeAll("}");
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

        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"");
        try writer.writeAll(method);
        try writer.writeByte('"');

        if (params_json) |params| {
            try writer.writeAll(",\"params\":");
            try writer.writeAll(params);
        }

        try writer.writeAll("}");
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
        try writer.print(",\"error\":{{\"code\":{d},\"message\":\"", .{code});
        try writeJsonEscaped(writer, message);
        try writer.writeAll("\"}}");

        return output.toOwnedSlice(self.allocator);
    }

    /// Encode initialize params to JSON
    pub fn encodeInitializeParams(self: *Encoder, params: protocol.InitializeParams) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.writeAll("{\"protocolVersion\":");
        try writer.print("{d}", .{params.protocol_version});

        // Client capabilities
        try writer.writeAll(",\"clientCapabilities\":{\"fileSystem\":{\"readTextFile\":");
        try writer.writeAll(if (params.client_capabilities.file_system.read_text_file) "true" else "false");
        try writer.writeAll(",\"writeTextFile\":");
        try writer.writeAll(if (params.client_capabilities.file_system.write_text_file) "true" else "false");
        try writer.writeAll("},\"terminal\":");
        try writer.writeAll(if (params.client_capabilities.terminal) "true" else "false");
        try writer.writeByte('}');

        // Client info
        try writer.writeAll(",\"clientInfo\":{\"name\":\"");
        try writeJsonEscaped(writer, params.client_info.name);
        try writer.writeByte('"');
        if (params.client_info.title) |title| {
            try writer.writeAll(",\"title\":\"");
            try writeJsonEscaped(writer, title);
            try writer.writeByte('"');
        }
        try writer.writeAll(",\"version\":\"");
        try writeJsonEscaped(writer, params.client_info.version);
        try writer.writeAll("\"}}");

        return output.toOwnedSlice(self.allocator);
    }

    /// Encode session/new params to JSON
    pub fn encodeSessionNewParams(self: *Encoder, params: protocol.SessionNewParams) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.writeAll("{\"cwd\":\"");
        try writeJsonEscaped(writer, params.cwd);
        try writer.writeAll("\",\"mcpServers\":[");

        for (params.mcp_servers, 0..) |server, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeAll("{\"name\":\"");
            try writeJsonEscaped(writer, server.name);
            try writer.writeByte('"');
            if (server.transport_json) |transport| {
                try writer.writeAll(",\"transport\":");
                try writer.writeAll(transport);
            }
            try writer.writeByte('}');
        }

        try writer.writeAll("]}");
        return output.toOwnedSlice(self.allocator);
    }

    /// Encode session/prompt params to JSON
    pub fn encodeSessionPromptParams(self: *Encoder, params: protocol.SessionPromptParams) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.writeAll("{\"sessionId\":\"");
        try writeJsonEscaped(writer, params.session_id);
        try writer.writeAll("\",\"prompt\":[");

        for (params.content, 0..) |block, i| {
            if (i > 0) try writer.writeByte(',');
            switch (block) {
                .text => |t| {
                    try writer.writeAll("{\"type\":\"text\",\"text\":\"");
                    try writeJsonEscaped(writer, t.text);
                    try writer.writeAll("\"}");
                },
                .resource_link => |r| {
                    try writer.writeAll("{\"type\":\"resourceLink\",\"uri\":\"");
                    try writeJsonEscaped(writer, r.uri);
                    try writer.writeByte('"');
                    if (r.name) |name| {
                        try writer.writeAll(",\"name\":\"");
                        try writeJsonEscaped(writer, name);
                        try writer.writeByte('"');
                    }
                    try writer.writeByte('}');
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

        try writer.writeAll("{\"sessionId\":\"");
        try writeJsonEscaped(writer, params.session_id);
        try writer.writeAll("\"}");

        return output.toOwnedSlice(self.allocator);
    }

    /// Encode fs/read_text_file result to JSON
    pub fn encodeReadTextFileResult(self: *Encoder, result: protocol.ReadTextFileResult) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.writeAll("{\"content\":\"");
        try writeJsonEscaped(writer, result.content);
        try writer.writeAll("\"}");

        return output.toOwnedSlice(self.allocator);
    }

    /// Encode permission response to JSON
    pub fn encodePermissionResult(self: *Encoder, selected_option: ?[]const u8) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        if (selected_option) |option| {
            try writer.writeAll("{\"selectedOption\":\"");
            try writeJsonEscaped(writer, option);
            try writer.writeAll("\"}");
        } else {
            try writer.writeAll("{\"outcome\":\"cancelled\"}");
        }

        return output.toOwnedSlice(self.allocator);
    }

    fn writeId(self: *Encoder, writer: anytype, id: JsonRpcId) !void {
        _ = self;
        switch (id) {
            .string => |s| {
                try writer.writeByte('"');
                try writeJsonEscaped(writer, s);
                try writer.writeByte('"');
            },
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
        return .{
            .protocol_version = r.protocolVersion,
            .agent_capabilities = .{
                .load_session = if (r.agentCapabilities) |ac| ac.loadSession orelse false else false,
                .prompt = .{
                    .image = if (r.agentCapabilities) |ac| if (ac.prompt) |p| p.image orelse false else false else false,
                    .audio = if (r.agentCapabilities) |ac| if (ac.prompt) |p| p.audio orelse false else false else false,
                    .embedded_context = if (r.agentCapabilities) |ac| if (ac.prompt) |p| p.embeddedContext orelse false else false else false,
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
        const parsed = try std.json.parseFromSlice(struct {
            sessionId: []const u8,
        }, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        return .{
            .session_id = try self.allocator.dupe(u8, parsed.value.sessionId),
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

    /// Parse session/request_permission params from JSON
    pub fn parseRequestPermissionParams(self: *Decoder, json: []const u8) !ParsedPermissionRequest {
        const RawOption = struct {
            optionId: []const u8,
            name: []const u8,
            kind: ?[]const u8 = null,
        };

        const RawParams = struct {
            sessionId: []const u8,
            toolCallId: []const u8,
            title: []const u8,
            description: ?[]const u8 = null,
            options: ?[]const RawOption = null,
        };

        const parsed = try std.json.parseFromSlice(RawParams, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const r = parsed.value;

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
            .tool_call_id = try self.allocator.dupe(u8, r.toolCallId),
            .title = try self.allocator.dupe(u8, r.title),
            .description = if (r.description) |d| try self.allocator.dupe(u8, d) else null,
            .options = try options.toOwnedSlice(self.allocator),
        };
    }

    /// Parse session/update params from JSON (for notifications)
    pub fn parseSessionUpdateParams(self: *Decoder, json: []const u8) !protocol.SessionUpdateParams {
        // Log raw JSON for debugging
        std.log.debug("parseSessionUpdateParams raw JSON: {s}", .{json});

        const parsed = try std.json.parseFromSlice(RawSessionUpdate, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const r = parsed.value;
        std.log.debug("parsed: update present={}, message present={}", .{ r.update != null, r.message != null });

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
                std.log.debug("Session update type: {s}", .{session_update_type});
            }

            // Extract tool name from _meta.claudeCode
            var tool_name: ?[]const u8 = null;
            var tool_response_stdout: ?[]const u8 = null;
            var tool_response_stderr: ?[]const u8 = null;
            var tool_response_interrupted: bool = false;

            if (upd._meta) |meta| {
                if (meta.claudeCode) |cc| {
                    if (cc.toolName) |tn| {
                        tool_name = self.allocator.dupe(u8, tn) catch null;
                    }
                    if (cc.toolResponse) |tr| {
                        if (tr.stdout) |s| {
                            tool_response_stdout = self.allocator.dupe(u8, s) catch null;
                        }
                        if (tr.stderr) |s| {
                            tool_response_stderr = self.allocator.dupe(u8, s) catch null;
                        }
                        tool_response_interrupted = tr.interrupted orelse false;
                    }
                }
            }

            // Extract command from rawInput for Bash tools
            var command: ?[]const u8 = null;
            var description: ?[]const u8 = null;

            if (upd.rawInput) |raw_input| {
                if (raw_input == .object) {
                    if (raw_input.object.get("command")) |cmd| {
                        if (cmd == .string) {
                            command = self.allocator.dupe(u8, cmd.string) catch null;
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

                // Parse content blocks for tool_call_update
                // Structure: [{"type":"content","content":{"type":"text","text":"..."}}]
                var update_content: []const protocol.ContentBlock = &.{};
                if (upd.content) |content_val| {
                    if (content_val == .array) {
                        var text_blocks: std.ArrayList(protocol.ContentBlock) = .{};
                        for (content_val.array.items) |item| {
                            if (item != .object) continue;
                            const obj = item.object;

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
                                        std.log.debug("Found text in update.content: {s}", .{text_val.string});
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
                            std.log.debug("Found {d} diff content blocks in tool_call", .{diff_count});
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

        return .{
            .session_id = r.sessionId,
            .update_type = update_type,
            .message = message_result,
            .tool_call = tool_call_result,
            .tool_call_update = tool_call_update_result,
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
    } = null,
    agentInfo: ?struct {
        name: []const u8,
        title: ?[]const u8 = null,
        version: []const u8,
    } = null,
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
        // _meta contains Claude Code specific metadata
        _meta: ?struct {
            claudeCode: ?struct {
                toolName: ?[]const u8 = null,
                toolResponse: ?struct {
                    stdout: ?[]const u8 = null,
                    stderr: ?[]const u8 = null,
                    interrupted: ?bool = null,
                    isImage: ?bool = null,
                } = null,
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
};

// =============================================================================
// Helper Functions
// =============================================================================

fn writeJsonEscaped(writer: anytype, str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

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
