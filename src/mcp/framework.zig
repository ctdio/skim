const std = @import("std");
const Allocator = std.mem.Allocator;

// =============================================================================
// MCP Framework - A minimal MCP server framework for Zig
// =============================================================================

/// MCP Server configuration
pub const ServerConfig = struct {
    name: []const u8,
    version: []const u8,
};

/// Tool result content types
pub const ContentType = enum {
    text,
    image,
    resource,
};

/// A single content item in a tool result
pub const Content = struct {
    type: ContentType = .text,
    text: ?[]const u8 = null,
    // For images/resources, add more fields as needed
};

/// Tool execution result
pub const Result = union(enum) {
    success: struct {
        content: []const Content,
        is_error: bool = false,
    },
    failure: struct {
        code: i32,
        message: []const u8,
    },

    /// Create a text result
    pub fn text(allocator: Allocator, message: []const u8) !Result {
        const content = try allocator.alloc(Content, 1);
        content[0] = .{ .type = .text, .text = message };
        return .{ .success = .{ .content = content } };
    }

    /// Create a text error result
    pub fn textError(allocator: Allocator, message: []const u8) !Result {
        const content = try allocator.alloc(Content, 1);
        content[0] = .{ .type = .text, .text = message };
        return .{ .success = .{ .content = content, .is_error = true } };
    }

    /// Create an MCP error (not a tool error, but a protocol error)
    pub fn mcpError(code: i32, message: []const u8) Result {
        return .{ .failure = .{ .code = code, .message = message } };
    }

    /// Free allocated content
    pub fn deinit(self: *Result, allocator: Allocator) void {
        switch (self.*) {
            .success => |s| allocator.free(s.content),
            .failure => {},
        }
    }
};

/// Tool handler context - passed to all tool handlers
pub const Context = struct {
    allocator: Allocator,
    server: *Server,
    user_data: ?*anyopaque, // User-provided state (e.g., TUI client registry)

    pub fn init(allocator: Allocator, server: *Server) Context {
        return .{
            .allocator = allocator,
            .server = server,
            .user_data = null,
        };
    }

    pub fn withUserData(allocator: Allocator, server: *Server, user_data: ?*anyopaque) Context {
        return .{
            .allocator = allocator,
            .server = server,
            .user_data = user_data,
        };
    }

    /// Get user data cast to a specific type
    pub fn getUserData(self: *Context, comptime T: type) ?*T {
        if (self.user_data) |ptr| {
            return @ptrCast(@alignCast(ptr));
        }
        return null;
    }
};

/// Error codes
pub const ErrorCode = struct {
    pub const parse_error: i32 = -32700;
    pub const invalid_request: i32 = -32600;
    pub const method_not_found: i32 = -32601;
    pub const invalid_params: i32 = -32602;
    pub const internal_error: i32 = -32603;
};

/// A registered tool definition
pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8, // JSON schema string
    handler: *const fn (*Context, ?std.json.Value) Result,
};

/// MCP Server
pub const Server = struct {
    allocator: Allocator,
    config: ServerConfig,
    tools: std.ArrayList(ToolDef),

    pub fn init(allocator: Allocator, config: ServerConfig) Server {
        return .{
            .allocator = allocator,
            .config = config,
            // Zig 0.15: ArrayList is unmanaged
            .tools = .{},
        };
    }

    pub fn deinit(self: *Server) void {
        self.tools.deinit(self.allocator);
    }

    /// Register a tool with the server
    pub fn tool(
        self: *Server,
        name: []const u8,
        description: []const u8,
        comptime ParamsType: ?type,
        handler: *const fn (*Context, ?std.json.Value) Result,
    ) !void {
        const schema = if (ParamsType) |T|
            comptime generateJsonSchema(T)
        else
            \\{"type":"object","properties":{},"required":[]}
        ;

        try self.tools.append(self.allocator, .{
            .name = name,
            .description = description,
            .input_schema = schema,
            .handler = handler,
        });
    }

    /// Handle an MCP request and return a response
    pub fn handleRequest(self: *Server, method: []const u8, params: ?std.json.Value, user_data: ?*anyopaque) Result {
        var ctx = Context.withUserData(self.allocator, self, user_data);

        if (std.mem.eql(u8, method, "initialize")) {
            return self.handleInitialize(params);
        } else if (std.mem.eql(u8, method, "tools/list")) {
            return self.handleToolsList();
        } else if (std.mem.eql(u8, method, "tools/call")) {
            return self.handleToolsCall(&ctx, params);
        } else if (std.mem.eql(u8, method, "notifications/initialized")) {
            // No response needed
            return Result.text(self.allocator, "") catch return Result.mcpError(ErrorCode.internal_error, "Allocation failed");
        }

        return Result.mcpError(ErrorCode.method_not_found, "Method not found");
    }

    fn handleInitialize(self: *Server, params: ?std.json.Value) Result {
        // Log client capabilities if provided
        if (params) |p| {
            if (p == .object) {
                if (p.object.get("clientCapabilities")) |caps| {
                    std.log.info("Client capabilities: {any}", .{caps});
                }
                if (p.object.get("clientInfo")) |info| {
                    std.log.info("Client info: {any}", .{info});
                }
                if (p.object.get("protocolVersion")) |version| {
                    std.log.info("Client protocol version: {any}", .{version});
                }
            }
        }

        // Return static initialize response
        // The actual JSON encoding happens in the transport layer
        const content = self.allocator.alloc(Content, 1) catch
            return Result.mcpError(ErrorCode.internal_error, "Allocation failed");
        content[0] = .{
            .type = .text,
            .text = "initialized",
        };
        return .{ .success = .{ .content = content } };
    }

    fn handleToolsList(self: *Server) Result {
        const content = self.allocator.alloc(Content, 1) catch
            return Result.mcpError(ErrorCode.internal_error, "Allocation failed");
        content[0] = .{
            .type = .text,
            .text = "tools_list",
        };
        return .{ .success = .{ .content = content } };
    }

    fn handleToolsCall(self: *Server, ctx: *Context, params: ?std.json.Value) Result {
        const p = params orelse return Result.mcpError(ErrorCode.invalid_params, "Missing params");

        if (p != .object) return Result.mcpError(ErrorCode.invalid_params, "Invalid params");

        const name_val = p.object.get("name") orelse
            return Result.mcpError(ErrorCode.invalid_params, "Missing tool name");

        if (name_val != .string) return Result.mcpError(ErrorCode.invalid_params, "Invalid tool name");

        const tool_name = name_val.string;
        const arguments = p.object.get("arguments");

        // Find and call the tool handler
        for (self.tools.items) |t| {
            if (std.mem.eql(u8, t.name, tool_name)) {
                return t.handler(ctx, arguments);
            }
        }

        return Result.mcpError(ErrorCode.invalid_params, "Unknown tool");
    }

    // =========================================================================
    // JSON Encoding Helpers
    // =========================================================================

    /// Encode the initialize response
    pub fn encodeInitializeResponse(self: *Server, allocator: Allocator) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(allocator);

        try output.appendSlice(allocator, "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"");
        try output.appendSlice(allocator, self.config.name);
        try output.appendSlice(allocator, "\",\"version\":\"");
        try output.appendSlice(allocator, self.config.version);
        try output.appendSlice(allocator, "\"}}");

        return output.toOwnedSlice(allocator);
    }

    /// Encode the tools/list response
    pub fn encodeToolsListResponse(self: *Server, allocator: Allocator) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(allocator);

        try output.appendSlice(allocator, "{\"tools\":[");

        for (self.tools.items, 0..) |t, i| {
            if (i > 0) try output.append(allocator, ',');
            try output.appendSlice(allocator, "{\"name\":\"");
            try output.appendSlice(allocator, t.name);
            try output.appendSlice(allocator, "\",\"description\":\"");
            try output.appendSlice(allocator, t.description);
            try output.appendSlice(allocator, "\",\"inputSchema\":");
            try output.appendSlice(allocator, t.input_schema);
            try output.append(allocator, '}');
        }

        try output.appendSlice(allocator, "]}");

        return output.toOwnedSlice(allocator);
    }

    /// Encode a tool result as JSON
    pub fn encodeToolResult(self: *Server, allocator: Allocator, result: Result) ![]u8 {
        _ = self;
        // Zig 0.15: ArrayList is unmanaged
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(allocator);

        switch (result) {
            .success => |s| {
                try output.appendSlice(allocator, "{\"content\":[");
                for (s.content, 0..) |c, i| {
                    if (i > 0) try output.append(allocator, ',');
                    try output.appendSlice(allocator, "{\"type\":\"");
                    try output.appendSlice(allocator, @tagName(c.type));
                    try output.appendSlice(allocator, "\"");
                    if (c.text) |text| {
                        try output.appendSlice(allocator, ",\"text\":\"");
                        try writeJsonEscaped(output.writer(allocator), text);
                        try output.append(allocator, '"');
                    }
                    try output.append(allocator, '}');
                }
                try output.append(allocator, ']');
                if (s.is_error) {
                    try output.appendSlice(allocator, ",\"isError\":true");
                }
                try output.append(allocator, '}');
            },
            .failure => {
                // This shouldn't be encoded as a tool result
                // It should be encoded as an MCP error response
                return error.InvalidResult;
            },
        }

        return output.toOwnedSlice(allocator);
    }
};

// =============================================================================
// Comptime JSON Schema Generation
// =============================================================================

/// Generate a JSON schema string from a Zig struct type at compile time
fn generateJsonSchema(comptime T: type) []const u8 {
    const info = @typeInfo(T);
    // Zig 0.15: type info enum values are lowercase strings
    if (info != .@"struct") {
        @compileError("JSON schema can only be generated for struct types");
    }

    comptime var schema: []const u8 = "{\"type\":\"object\",\"properties\":{";
    comptime var required: []const u8 = "";
    comptime var first_prop = true;
    comptime var first_req = true;

    inline for (info.@"struct".fields) |field| {
        if (!first_prop) {
            schema = schema ++ ",";
        }
        first_prop = false;

        schema = schema ++ "\"" ++ field.name ++ "\":{";
        schema = schema ++ jsonTypeFor(field.type);
        schema = schema ++ "}";

        // All fields are required unless they have a default value
        // Zig 0.15: default_value is now default_value_ptr
        if (field.default_value_ptr == null) {
            if (!first_req) {
                required = required ++ ",";
            }
            first_req = false;
            required = required ++ "\"" ++ field.name ++ "\"";
        }
    }

    schema = schema ++ "},\"required\":[" ++ required ++ "]}";
    return schema;
}

/// Get the JSON type string for a Zig type
fn jsonTypeFor(comptime T: type) []const u8 {
    const info = @typeInfo(T);

    // Zig 0.15: type info enum values are lowercase strings
    return switch (info) {
        .int, .comptime_int => "\"type\":\"integer\"",
        .float, .comptime_float => "\"type\":\"number\"",
        .bool => "\"type\":\"boolean\"",
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                return "\"type\":\"string\"";
            }
            return "\"type\":\"object\"";
        },
        .optional => |opt| jsonTypeFor(opt.child),
        else => "\"type\":\"object\"",
    };
}

// =============================================================================
// Helper Functions
// =============================================================================

fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
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
// Parameter Parsing Helpers
// =============================================================================

/// Parse a JSON value into a Zig struct
pub fn parseParams(comptime T: type, allocator: Allocator, value: ?std.json.Value) !T {
    const val = value orelse return error.MissingParams;

    if (val != .object) return error.InvalidParams;

    var result: T = undefined;
    // Zig 0.15: type info enum values are lowercase strings
    const info = @typeInfo(T).@"struct";

    inline for (info.fields) |field| {
        const json_val = val.object.get(field.name);

        if (json_val) |v| {
            @field(result, field.name) = try parseValue(field.type, allocator, v);
        } else if (field.defaultValue()) |default| {
            // Zig 0.15: use defaultValue() method instead of default_value field
            @field(result, field.name) = default;
        } else {
            return error.MissingField;
        }
    }

    return result;
}

fn parseValue(comptime T: type, allocator: Allocator, value: std.json.Value) !T {
    const info = @typeInfo(T);

    // Zig 0.15: type info enum values are lowercase
    switch (info) {
        .int => {
            return switch (value) {
                .integer => |i| @intCast(i),
                .number_string => |s| try std.fmt.parseInt(T, s, 10),
                else => error.InvalidType,
            };
        },
        .float => {
            return switch (value) {
                .float => |f| @floatCast(f),
                .integer => |i| @floatFromInt(i),
                else => error.InvalidType,
            };
        },
        .bool => {
            return switch (value) {
                .bool => |b| b,
                else => error.InvalidType,
            };
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                return switch (value) {
                    .string => |s| try allocator.dupe(u8, s),
                    else => error.InvalidType,
                };
            }
            return error.UnsupportedType;
        },
        .optional => |opt| {
            if (value == .null) return null;
            return try parseValue(opt.child, allocator, value);
        },
        else => return error.UnsupportedType,
    }
}

// =============================================================================
// Tests
// =============================================================================

test "generate json schema for simple struct" {
    const TestParams = struct {
        name: []const u8,
        count: u32,
        enabled: bool,
    };

    const schema = comptime generateJsonSchema(TestParams);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"count\":{\"type\":\"integer\"},\"enabled\":{\"type\":\"boolean\"}},\"required\":[\"name\",\"count\",\"enabled\"]}",
        schema,
    );
}

test "generate json schema with optional field" {
    const TestParams = struct {
        name: []const u8,
        description: []const u8 = "default",
    };

    const schema = comptime generateJsonSchema(TestParams);
    // Only 'name' should be required since 'description' has a default
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"description\":{\"type\":\"string\"}},\"required\":[\"name\"]}",
        schema,
    );
}

test "parse params from json" {
    const allocator = std.testing.allocator;

    const TestParams = struct {
        name: []const u8,
        count: u32,
    };

    // Create a mock JSON object
    var obj = std.json.ObjectMap.init(allocator);
    defer obj.deinit();
    try obj.put("name", .{ .string = "test" });
    try obj.put("count", .{ .integer = 42 });

    const params = try parseParams(TestParams, allocator, .{ .object = obj });
    defer allocator.free(params.name);

    try std.testing.expectEqualStrings("test", params.name);
    try std.testing.expectEqual(@as(u32, 42), params.count);
}
