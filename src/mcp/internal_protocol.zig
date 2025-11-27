const std = @import("std");
const Allocator = std.mem.Allocator;
const registry = @import("registry.zig");

// =============================================================================
// Internal Protocol Messages (MCP Adapter <-> Daemon)
// =============================================================================

/// Session ID type (UUID string) - reuse from registry
pub const SessionId = registry.SessionId;

/// Client summary for adapter communication
pub const ClientSummary = struct {
    id: []const u8,
    cwd: []const u8,
    diff_ref: []const u8,
    file_count: usize,
};

// =============================================================================
// Adapter -> Daemon Messages
// =============================================================================

/// Hello message from adapter to daemon on connect
pub const AdapterHelloPayload = struct {
    adapter_id: []const u8,
};

/// MCP request forwarded from adapter to daemon
pub const McpRequestPayload = struct {
    request_id: []const u8, // Internal UUID for correlation
    mcp_id: McpId, // Original JSON-RPC id
    method: []const u8,
    params: ?[]const u8, // Raw JSON string
};

/// MCP ID can be string, number, or null
pub const McpId = union(enum) {
    string: []const u8,
    number: i64,
    null_value: void,

    pub fn format(self: McpId, writer: anytype) !void {
        switch (self) {
            .string => |s| {
                try writer.writeByte('"');
                try writeJsonEscaped(writer, s);
                try writer.writeByte('"');
            },
            .number => |n| try std.fmt.formatInt(n, 10, .lower, .{}, writer),
            .null_value => try writer.writeAll("null"),
        }
    }
};

// =============================================================================
// Daemon -> Adapter Messages
// =============================================================================

/// Welcome response from daemon to adapter
pub const AdapterWelcomePayload = struct {
    adapter_id: []const u8,
    clients: []const ClientSummary,
};

/// MCP response from daemon to adapter
pub const McpResponsePayload = struct {
    request_id: []const u8,
    mcp_id: McpId, // Original MCP request ID to return to agent
    result: ?[]const u8, // Raw JSON string (null if error)
    @"error": ?McpErrorPayload,
};

/// MCP error in response
pub const McpErrorPayload = struct {
    code: i32,
    message: []const u8,
};

/// Client update notification from daemon to adapter
pub const ClientUpdatePayload = struct {
    action: ClientAction,
    client: ClientSummary,
};

pub const ClientAction = enum {
    connected,
    disconnected,
};

// =============================================================================
// Message Type Enum
// =============================================================================

pub const AdapterMessageType = enum {
    adapter_hello,
    adapter_goodbye,
    mcp_request,
    status_query,
};

pub const DaemonMessageType = enum {
    adapter_welcome,
    mcp_response,
    client_update,
    status_response,
};

// =============================================================================
// Parsed Message Unions
// =============================================================================

pub const ParsedAdapterMessage = union(enum) {
    adapter_hello: AdapterHelloPayload,
    adapter_goodbye: void,
    mcp_request: McpRequestPayload,
    status_query: void,
    unknown: []const u8,
};

/// Status response payload from daemon
pub const StatusResponsePayload = struct {
    clients: []const ClientSummary,
    adapter_count: usize,
};

pub const ParsedDaemonMessage = union(enum) {
    adapter_welcome: AdapterWelcomePayload,
    mcp_response: McpResponsePayload,
    client_update: ClientUpdatePayload,
    status_response: StatusResponsePayload,
    unknown: []const u8,
};

// =============================================================================
// Encoding Functions (Adapter -> Daemon)
// =============================================================================

pub fn encodeAdapterHello(allocator: Allocator, adapter_id: []const u8) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    const writer = output.writer();
    try writer.writeAll("{\"event\":\"adapter_hello\",\"adapter_id\":\"");
    try writer.writeAll(adapter_id);
    try writer.writeAll("\"}\n");
    return output.toOwnedSlice();
}

pub fn encodeAdapterGoodbye(allocator: Allocator) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    try output.appendSlice("{\"event\":\"adapter_goodbye\"}\n");
    return output.toOwnedSlice();
}

pub fn encodeMcpRequest(allocator: Allocator, payload: McpRequestPayload) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    const writer = output.writer();
    try writer.writeAll("{\"event\":\"mcp_request\",\"request_id\":\"");
    try writer.writeAll(payload.request_id);
    try writer.writeAll("\",\"mcp_id\":");
    try payload.mcp_id.format(writer);
    try writer.writeAll(",\"method\":\"");
    try writer.writeAll(payload.method);
    try writer.writeByte('"');

    if (payload.params) |params| {
        try writer.writeAll(",\"params\":");
        try writer.writeAll(params);
    }

    try writer.writeAll("}\n");
    return output.toOwnedSlice();
}

pub fn encodeStatusQuery(allocator: Allocator) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    try output.appendSlice("{\"event\":\"status_query\"}\n");
    return output.toOwnedSlice();
}

// =============================================================================
// Encoding Functions (Daemon -> Adapter)
// =============================================================================

pub fn encodeAdapterWelcome(allocator: Allocator, adapter_id: []const u8, clients: []const ClientSummary) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    const writer = output.writer();
    try writer.writeAll("{\"event\":\"adapter_welcome\",\"adapter_id\":\"");
    try writer.writeAll(adapter_id);
    try writer.writeAll("\",\"clients\":[");

    for (clients, 0..) |client, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"id\":\"");
        try writer.writeAll(client.id);
        try writer.writeAll("\",\"cwd\":\"");
        try writeJsonEscaped(writer, client.cwd);
        try writer.writeAll("\",\"diff_ref\":\"");
        try writeJsonEscaped(writer, client.diff_ref);
        try writer.writeAll("\",\"file_count\":");
        try std.fmt.formatInt(client.file_count, 10, .lower, .{}, writer);
        try writer.writeByte('}');
    }

    try writer.writeAll("]}\n");
    return output.toOwnedSlice();
}

pub fn encodeMcpResponse(allocator: Allocator, request_id: []const u8, mcp_id: McpId, result: ?[]const u8, err: ?McpErrorPayload) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    const writer = output.writer();
    try writer.writeAll("{\"event\":\"mcp_response\",\"request_id\":\"");
    try writer.writeAll(request_id);
    try writer.writeAll("\",\"mcp_id\":");
    try mcp_id.format(writer);

    if (result) |r| {
        try writer.writeAll(",\"result\":");
        try writer.writeAll(r);
    }

    if (err) |e| {
        try writer.writeAll(",\"error\":{\"code\":");
        try std.fmt.formatInt(e.code, 10, .lower, .{}, writer);
        try writer.writeAll(",\"message\":\"");
        try writeJsonEscaped(writer, e.message);
        try writer.writeAll("\"}");
    }

    try writer.writeAll("}\n");
    return output.toOwnedSlice();
}

pub fn encodeClientUpdate(allocator: Allocator, action: ClientAction, client: ClientSummary) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    const writer = output.writer();
    try writer.writeAll("{\"event\":\"client_update\",\"action\":\"");
    try writer.writeAll(switch (action) {
        .connected => "connected",
        .disconnected => "disconnected",
    });
    try writer.writeAll("\",\"client\":{\"id\":\"");
    try writer.writeAll(client.id);
    try writer.writeAll("\",\"cwd\":\"");
    try writeJsonEscaped(writer, client.cwd);
    try writer.writeAll("\",\"diff_ref\":\"");
    try writeJsonEscaped(writer, client.diff_ref);
    try writer.writeAll("\",\"file_count\":");
    try std.fmt.formatInt(client.file_count, 10, .lower, .{}, writer);
    try writer.writeAll("}}\n");
    return output.toOwnedSlice();
}

pub fn encodeStatusResponse(allocator: Allocator, clients: []const ClientSummary, adapter_count: usize) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    const writer = output.writer();
    try writer.writeAll("{\"event\":\"status_response\",\"clients\":[");

    for (clients, 0..) |client, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"id\":\"");
        try writer.writeAll(client.id);
        try writer.writeAll("\",\"cwd\":\"");
        try writeJsonEscaped(writer, client.cwd);
        try writer.writeAll("\",\"diff_ref\":\"");
        try writeJsonEscaped(writer, client.diff_ref);
        try writer.writeAll("\",\"file_count\":");
        try std.fmt.formatInt(client.file_count, 10, .lower, .{}, writer);
        try writer.writeByte('}');
    }

    try writer.writeAll("],\"adapter_count\":");
    try std.fmt.formatInt(adapter_count, 10, .lower, .{}, writer);
    try writer.writeAll("}\n");
    return output.toOwnedSlice();
}

// =============================================================================
// Decoding Functions
// =============================================================================

/// Raw adapter message envelope for JSON parsing
const RawAdapterMessage = struct {
    event: []const u8,
    adapter_id: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    mcp_id: ?std.json.Value = null,
    method: ?[]const u8 = null,
    params: ?std.json.Value = null,
};

/// Decode an adapter message
pub fn decodeAdapterMessage(allocator: Allocator, json_line: []const u8) !ParsedAdapterMessage {
    const trimmed = std.mem.trimRight(u8, json_line, "\n\r");

    const parsed = std.json.parseFromSlice(RawAdapterMessage, allocator, trimmed, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.err("JSON parse error: {} for input: {s}", .{ err, trimmed });
        return error.InvalidJson;
    };
    defer parsed.deinit();

    const msg = parsed.value;
    const event = msg.event;

    if (std.mem.eql(u8, event, "adapter_hello")) {
        return .{ .adapter_hello = .{
            .adapter_id = try allocator.dupe(u8, msg.adapter_id orelse return error.MissingField),
        } };
    } else if (std.mem.eql(u8, event, "adapter_goodbye")) {
        return .{ .adapter_goodbye = {} };
    } else if (std.mem.eql(u8, event, "status_query")) {
        return .{ .status_query = {} };
    } else if (std.mem.eql(u8, event, "mcp_request")) {
        // Parse MCP ID
        const mcp_id: McpId = if (msg.mcp_id) |id_val| blk: {
            break :blk switch (id_val) {
                .string => |s| .{ .string = try allocator.dupe(u8, s) },
                .integer => |n| .{ .number = n },
                .null => .{ .null_value = {} },
                else => return error.InvalidMcpId,
            };
        } else .{ .null_value = {} };

        // Stringify params if present
        const params_str: ?[]const u8 = if (msg.params) |p| blk: {
            var params_output = std.ArrayList(u8).init(allocator);
            errdefer params_output.deinit();
            std.json.stringify(p, .{}, params_output.writer()) catch return error.InvalidParams;
            break :blk try params_output.toOwnedSlice();
        } else null;

        return .{ .mcp_request = .{
            .request_id = try allocator.dupe(u8, msg.request_id orelse return error.MissingField),
            .mcp_id = mcp_id,
            .method = try allocator.dupe(u8, msg.method orelse return error.MissingField),
            .params = params_str,
        } };
    }

    return .{ .unknown = try allocator.dupe(u8, event) };
}

/// Raw daemon message envelope for JSON parsing
const RawDaemonMessage = struct {
    event: []const u8,
    adapter_id: ?[]const u8 = null,
    clients: ?[]const ClientSummaryRaw = null,
    adapter_count: ?usize = null,
    request_id: ?[]const u8 = null,
    mcp_id: ?std.json.Value = null, // Can be number, string, or null
    result: ?std.json.Value = null,
    @"error": ?struct {
        code: i32,
        message: []const u8,
    } = null,
    action: ?[]const u8 = null,
    client: ?ClientSummaryRaw = null,
};

const ClientSummaryRaw = struct {
    id: []const u8,
    cwd: []const u8,
    diff_ref: []const u8,
    file_count: usize,
};

/// Decode a daemon message
pub fn decodeDaemonMessage(allocator: Allocator, json_line: []const u8) !ParsedDaemonMessage {
    const trimmed = std.mem.trimRight(u8, json_line, "\n\r");

    const parsed = std.json.parseFromSlice(RawDaemonMessage, allocator, trimmed, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.err("JSON parse error: {} for input: {s}", .{ err, trimmed });
        return error.InvalidJson;
    };
    defer parsed.deinit();

    const msg = parsed.value;
    const event = msg.event;

    if (std.mem.eql(u8, event, "adapter_welcome")) {
        const raw_clients = msg.clients orelse &[_]ClientSummaryRaw{};
        var clients = try allocator.alloc(ClientSummary, raw_clients.len);
        errdefer allocator.free(clients);

        for (raw_clients, 0..) |rc, i| {
            clients[i] = .{
                .id = try allocator.dupe(u8, rc.id),
                .cwd = try allocator.dupe(u8, rc.cwd),
                .diff_ref = try allocator.dupe(u8, rc.diff_ref),
                .file_count = rc.file_count,
            };
        }

        return .{ .adapter_welcome = .{
            .adapter_id = try allocator.dupe(u8, msg.adapter_id orelse return error.MissingField),
            .clients = clients,
        } };
    } else if (std.mem.eql(u8, event, "mcp_response")) {
        // Parse mcp_id
        const mcp_id: McpId = if (msg.mcp_id) |id_val| blk: {
            break :blk switch (id_val) {
                .integer => |n| .{ .number = n },
                .string => |s| .{ .string = try allocator.dupe(u8, s) },
                .null => .{ .null_value = {} },
                else => .{ .null_value = {} },
            };
        } else .{ .null_value = {} };

        // Stringify result if present
        const result_str: ?[]const u8 = if (msg.result) |r| blk: {
            var result_output = std.ArrayList(u8).init(allocator);
            errdefer result_output.deinit();
            std.json.stringify(r, .{}, result_output.writer()) catch return error.InvalidResult;
            break :blk try result_output.toOwnedSlice();
        } else null;

        const err_payload: ?McpErrorPayload = if (msg.@"error") |e| .{
            .code = e.code,
            .message = try allocator.dupe(u8, e.message),
        } else null;

        return .{ .mcp_response = .{
            .request_id = try allocator.dupe(u8, msg.request_id orelse return error.MissingField),
            .mcp_id = mcp_id,
            .result = result_str,
            .@"error" = err_payload,
        } };
    } else if (std.mem.eql(u8, event, "client_update")) {
        const action_str = msg.action orelse return error.MissingField;
        const action: ClientAction = if (std.mem.eql(u8, action_str, "connected"))
            .connected
        else if (std.mem.eql(u8, action_str, "disconnected"))
            .disconnected
        else
            return error.InvalidAction;

        const raw_client = msg.client orelse return error.MissingField;
        return .{ .client_update = .{
            .action = action,
            .client = .{
                .id = try allocator.dupe(u8, raw_client.id),
                .cwd = try allocator.dupe(u8, raw_client.cwd),
                .diff_ref = try allocator.dupe(u8, raw_client.diff_ref),
                .file_count = raw_client.file_count,
            },
        } };
    } else if (std.mem.eql(u8, event, "status_response")) {
        const raw_clients = msg.clients orelse &[_]ClientSummaryRaw{};
        var clients = try allocator.alloc(ClientSummary, raw_clients.len);
        errdefer allocator.free(clients);

        for (raw_clients, 0..) |rc, i| {
            clients[i] = .{
                .id = try allocator.dupe(u8, rc.id),
                .cwd = try allocator.dupe(u8, rc.cwd),
                .diff_ref = try allocator.dupe(u8, rc.diff_ref),
                .file_count = rc.file_count,
            };
        }

        return .{ .status_response = .{
            .clients = clients,
            .adapter_count = msg.adapter_count orelse 0,
        } };
    }

    return .{ .unknown = try allocator.dupe(u8, event) };
}

// =============================================================================
// Free Functions
// =============================================================================

pub fn freeAdapterMessage(allocator: Allocator, msg: *ParsedAdapterMessage) void {
    switch (msg.*) {
        .adapter_hello => |h| allocator.free(h.adapter_id),
        .adapter_goodbye, .status_query => {},
        .mcp_request => |r| {
            allocator.free(r.request_id);
            allocator.free(r.method);
            if (r.params) |p| allocator.free(p);
            switch (r.mcp_id) {
                .string => |s| allocator.free(s),
                else => {},
            }
        },
        .unknown => |u| allocator.free(u),
    }
}

pub fn freeDaemonMessage(allocator: Allocator, msg: *ParsedDaemonMessage) void {
    switch (msg.*) {
        .adapter_welcome => |w| {
            allocator.free(w.adapter_id);
            for (w.clients) |c| {
                allocator.free(c.id);
                allocator.free(c.cwd);
                allocator.free(c.diff_ref);
            }
            allocator.free(w.clients);
        },
        .mcp_response => |r| {
            allocator.free(r.request_id);
            switch (r.mcp_id) {
                .string => |s| allocator.free(s),
                else => {},
            }
            if (r.result) |res| allocator.free(res);
            if (r.@"error") |e| allocator.free(e.message);
        },
        .client_update => |u| {
            allocator.free(u.client.id);
            allocator.free(u.client.cwd);
            allocator.free(u.client.diff_ref);
        },
        .status_response => |s| {
            for (s.clients) |c| {
                allocator.free(c.id);
                allocator.free(c.cwd);
                allocator.free(c.diff_ref);
            }
            allocator.free(s.clients);
        },
        .unknown => |u| allocator.free(u),
    }
}

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
// Tests
// =============================================================================

test "encode and decode adapter_hello" {
    const allocator = std.testing.allocator;

    const encoded = try encodeAdapterHello(allocator, "test-adapter-123");
    defer allocator.free(encoded);

    var decoded = try decodeAdapterMessage(allocator, encoded);
    defer freeAdapterMessage(allocator, &decoded);

    try std.testing.expect(decoded == .adapter_hello);
    try std.testing.expectEqualStrings("test-adapter-123", decoded.adapter_hello.adapter_id);
}

test "encode and decode adapter_welcome" {
    const allocator = std.testing.allocator;

    const clients = [_]ClientSummary{
        .{ .id = "client-1", .cwd = "/tmp/repo", .diff_ref = "main..dev", .file_count = 3 },
    };

    const encoded = try encodeAdapterWelcome(allocator, "adapter-456", &clients);
    defer allocator.free(encoded);

    var decoded = try decodeDaemonMessage(allocator, encoded);
    defer freeDaemonMessage(allocator, &decoded);

    try std.testing.expect(decoded == .adapter_welcome);
    try std.testing.expectEqualStrings("adapter-456", decoded.adapter_welcome.adapter_id);
    try std.testing.expectEqual(@as(usize, 1), decoded.adapter_welcome.clients.len);
    try std.testing.expectEqualStrings("client-1", decoded.adapter_welcome.clients[0].id);
}

test "encode and decode mcp_request" {
    const allocator = std.testing.allocator;

    const encoded = try encodeMcpRequest(allocator, .{
        .request_id = "req-123",
        .mcp_id = .{ .number = 42 },
        .method = "tools/call",
        .params = "{\"name\":\"list_clients\"}",
    });
    defer allocator.free(encoded);

    var decoded = try decodeAdapterMessage(allocator, encoded);
    defer freeAdapterMessage(allocator, &decoded);

    try std.testing.expect(decoded == .mcp_request);
    try std.testing.expectEqualStrings("req-123", decoded.mcp_request.request_id);
    try std.testing.expectEqual(@as(i64, 42), decoded.mcp_request.mcp_id.number);
    try std.testing.expectEqualStrings("tools/call", decoded.mcp_request.method);
}

test "encode and decode mcp_response success" {
    const allocator = std.testing.allocator;

    const encoded = try encodeMcpResponse(allocator, "req-123", .{ .number = 42 }, "{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}", null);
    defer allocator.free(encoded);

    var decoded = try decodeDaemonMessage(allocator, encoded);
    defer freeDaemonMessage(allocator, &decoded);

    try std.testing.expect(decoded == .mcp_response);
    try std.testing.expectEqualStrings("req-123", decoded.mcp_response.request_id);
    try std.testing.expectEqual(@as(i64, 42), decoded.mcp_response.mcp_id.number);
    try std.testing.expect(decoded.mcp_response.result != null);
    try std.testing.expect(decoded.mcp_response.@"error" == null);
}

test "encode and decode mcp_response error" {
    const allocator = std.testing.allocator;

    const encoded = try encodeMcpResponse(allocator, "req-456", .{ .number = 99 }, null, .{
        .code = -32001,
        .message = "Client not found",
    });
    defer allocator.free(encoded);

    var decoded = try decodeDaemonMessage(allocator, encoded);
    defer freeDaemonMessage(allocator, &decoded);

    try std.testing.expect(decoded == .mcp_response);
    try std.testing.expectEqualStrings("req-456", decoded.mcp_response.request_id);
    try std.testing.expectEqual(@as(i64, 99), decoded.mcp_response.mcp_id.number);
    try std.testing.expect(decoded.mcp_response.result == null);
    try std.testing.expect(decoded.mcp_response.@"error" != null);
    try std.testing.expectEqual(@as(i32, -32001), decoded.mcp_response.@"error".?.code);
}

test "encode and decode client_update" {
    const allocator = std.testing.allocator;

    const encoded = try encodeClientUpdate(allocator, .connected, .{
        .id = "tui-789",
        .cwd = "/home/user/project",
        .diff_ref = "--staged",
        .file_count = 5,
    });
    defer allocator.free(encoded);

    var decoded = try decodeDaemonMessage(allocator, encoded);
    defer freeDaemonMessage(allocator, &decoded);

    try std.testing.expect(decoded == .client_update);
    try std.testing.expectEqual(ClientAction.connected, decoded.client_update.action);
    try std.testing.expectEqualStrings("tui-789", decoded.client_update.client.id);
}
