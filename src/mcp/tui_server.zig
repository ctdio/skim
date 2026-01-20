//! TUI TCP server for accepting CLI/MCP commands.
//!
//! Each TUI instance runs this server on an ephemeral port. CLI commands
//! and MCP adapters connect directly to send commands (get_context, add_comment, etc.)
//!
//! Protocol: Newline-delimited JSON
//!   Request:  {"method": "get_context", "id": "123", "params": {...}}
//!   Response: {"id": "123", "result": {...}}
//!   Error:    {"id": "123", "error": {"code": -1, "message": "..."}}

const std = @import("std");
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;

// =============================================================================
// Protocol Types
// =============================================================================

/// JSON-RPC-like request from CLI/MCP
pub const Request = struct {
    method: []const u8,
    id: []const u8,
    params: ?std.json.Value,
};

/// Response to send back
pub const Response = union(enum) {
    result: std.json.Value,
    err: struct {
        code: i32,
        message: []const u8,
    },
};

/// Standard error codes
pub const ErrorCode = struct {
    pub const PARSE_ERROR: i32 = -32700;
    pub const INVALID_REQUEST: i32 = -32600;
    pub const METHOD_NOT_FOUND: i32 = -32601;
    pub const INVALID_PARAMS: i32 = -32602;
    pub const INTERNAL_ERROR: i32 = -32603;
};

/// Callback type for handling requests
/// Returns a Response that the server will serialize and send back
pub const RequestHandler = *const fn (request: Request, user_data: ?*anyopaque) Response;

// =============================================================================
// TUI Server
// =============================================================================

/// TCP server that TUI runs to accept commands from CLI/MCP
pub const TuiServer = struct {
    allocator: Allocator,
    listener: ?net.Server,
    port: u16,
    handler: RequestHandler,
    user_data: ?*anyopaque,
    running: bool,

    /// Active client connections
    clients: std.ArrayList(ClientConnection),

    /// Initialize server (does not bind yet)
    pub fn init(allocator: Allocator, handler: RequestHandler, user_data: ?*anyopaque) TuiServer {
        return .{
            .allocator = allocator,
            .listener = null,
            .port = 0,
            .handler = handler,
            .user_data = user_data,
            .running = false,
            .clients = .{},
        };
    }

    pub fn deinit(self: *TuiServer) void {
        self.stop();
        self.clients.deinit(self.allocator);
    }

    /// Start listening on ephemeral port (port 0 lets OS assign)
    pub fn start(self: *TuiServer) !void {
        if (self.running) return;

        // Bind to localhost on ephemeral port
        const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        self.listener = try address.listen(.{
            .reuse_address = true,
        });

        // Get the assigned port
        self.port = self.listener.?.listen_address.getPort();

        // Set non-blocking for the listener
        try setNonBlocking(self.listener.?.stream.handle);

        self.running = true;
    }

    /// Get the bound port (call after start())
    pub fn getPort(self: *TuiServer) u16 {
        return self.port;
    }

    /// Stop server and close all connections
    pub fn stop(self: *TuiServer) void {
        if (!self.running) return;

        // Close all client connections
        for (self.clients.items) |*client| {
            client.stream.close();
        }
        self.clients.clearRetainingCapacity();

        // Close listener
        if (self.listener) |*listener| {
            listener.deinit();
            self.listener = null;
        }

        self.running = false;
    }

    /// Non-blocking poll for new connections and client data
    /// Call this from the TUI event loop
    pub fn poll(self: *TuiServer) !void {
        if (!self.running) return;

        // Accept new connections
        try self.acceptNewConnections();

        // Process data from existing clients
        try self.processClients();
    }

    // -------------------------------------------------------------------------
    // Internal Methods
    // -------------------------------------------------------------------------

    fn acceptNewConnections(self: *TuiServer) !void {
        if (self.listener == null) return;

        // Try to accept (non-blocking)
        while (true) {
            const conn = self.listener.?.accept() catch |err| {
                if (err == error.WouldBlock) break;
                return err;
            };

            // Set client socket to non-blocking
            try setNonBlocking(conn.stream.handle);

            try self.clients.append(self.allocator, .{
                .stream = conn.stream,
                .buffer = .{},
            });
        }
    }

    fn processClients(self: *TuiServer) !void {
        var i: usize = 0;
        while (i < self.clients.items.len) {
            var client = &self.clients.items[i];

            const should_remove = self.processClient(client) catch true;

            if (should_remove) {
                client.stream.close();
                client.buffer.deinit(self.allocator);
                _ = self.clients.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Process a single client connection. Returns true if client should be removed.
    fn processClient(self: *TuiServer, client: *ClientConnection) !bool {
        // Read available data
        var read_buf: [4096]u8 = undefined;
        const bytes_read = client.stream.read(&read_buf) catch |err| {
            if (err == error.WouldBlock) return false;
            return true; // Remove on error
        };

        if (bytes_read == 0) {
            return true; // Client disconnected
        }

        try client.buffer.appendSlice(self.allocator, read_buf[0..bytes_read]);

        // Process complete messages (newline-delimited)
        while (self.extractMessage(&client.buffer)) |message| {
            defer self.allocator.free(message);

            const response = self.handleMessage(message);
            // Note: We don't free the response here because:
            // 1. Error responses contain string literals (not allocated)
            // 2. Success responses are managed by the handler (App allocator)
            // The handler is responsible for its own memory management.
            // This avoids trying to free string literals which causes segfaults.

            // Send response
            const response_json = try serializeResponse(self.allocator, response);
            defer self.allocator.free(response_json);

            client.stream.writeAll(response_json) catch return true;
            client.stream.writeAll("\n") catch return true;
        }

        return false;
    }

    fn extractMessage(self: *TuiServer, buffer: *std.ArrayList(u8)) ?[]u8 {
        const newline_idx = std.mem.indexOfScalar(u8, buffer.items, '\n') orelse return null;

        // Extract message up to newline
        const message = self.allocator.dupe(u8, buffer.items[0..newline_idx]) catch return null;

        // Remove message from buffer (including newline)
        const remaining = buffer.items[newline_idx + 1 ..];
        std.mem.copyForwards(u8, buffer.items[0..remaining.len], remaining);
        buffer.shrinkRetainingCapacity(remaining.len);

        return message;
    }

    fn handleMessage(self: *TuiServer, message: []const u8) Response {
        // Parse JSON request
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, message, .{}) catch {
            return .{ .err = .{
                .code = ErrorCode.PARSE_ERROR,
                .message = "Invalid JSON",
            } };
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            return .{ .err = .{
                .code = ErrorCode.INVALID_REQUEST,
                .message = "Request must be an object",
            } };
        }

        const obj = root.object;

        // Extract method
        const method_val = obj.get("method") orelse {
            return .{ .err = .{
                .code = ErrorCode.INVALID_REQUEST,
                .message = "Missing 'method' field",
            } };
        };
        const method = switch (method_val) {
            .string => |s| s,
            else => return .{ .err = .{
                .code = ErrorCode.INVALID_REQUEST,
                .message = "'method' must be a string",
            } },
        };

        // Extract id
        const id_val = obj.get("id") orelse {
            return .{ .err = .{
                .code = ErrorCode.INVALID_REQUEST,
                .message = "Missing 'id' field",
            } };
        };
        const id = switch (id_val) {
            .string => |s| s,
            else => return .{ .err = .{
                .code = ErrorCode.INVALID_REQUEST,
                .message = "'id' must be a string",
            } },
        };

        // Extract params (optional)
        const params = obj.get("params");

        // Call handler
        const request = Request{
            .method = method,
            .id = id,
            .params = params,
        };

        return self.handler(request, self.user_data);
    }
};

// =============================================================================
// Client Connection
// =============================================================================

const ClientConnection = struct {
    stream: net.Stream,
    buffer: std.ArrayList(u8),
};

// =============================================================================
// Utility Functions
// =============================================================================

fn setNonBlocking(handle: posix.fd_t) !void {
    const flags = try posix.fcntl(handle, posix.F.GETFL, @as(usize, 0));
    const O_NONBLOCK: usize = 0x0004; // darwin/macOS
    _ = try posix.fcntl(handle, posix.F.SETFL, flags | O_NONBLOCK);
}

fn serializeResponse(allocator: Allocator, response: Response) ![]u8 {
    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);

    const writer = output.writer(allocator);

    switch (response) {
        .result => |result| {
            try writer.writeAll("{\"result\":");
            // Zig 0.15: Use Writer.Allocating with Stringify to serialize json.Value
            var alloc_writer: std.io.Writer.Allocating = .init(allocator);
            defer alloc_writer.deinit();
            var stringify: std.json.Stringify = .{ .writer = &alloc_writer.writer };
            stringify.write(result) catch return error.JsonSerializationFailed;
            try writer.writeAll(alloc_writer.written());
            try writer.writeAll("}");
        },
        .err => |e| {
            try writer.print("{{\"error\":{{\"code\":{d},\"message\":{f}}}}}", .{
                e.code,
                std.json.fmt(e.message, .{}),
            });
        },
    }

    return output.toOwnedSlice(allocator);
}

// =============================================================================
// Response Builder Helpers
// =============================================================================

/// Create a success response with a JSON object
pub fn successResponse(allocator: Allocator) !std.json.ObjectMap {
    return std.json.ObjectMap.init(allocator);
}

/// Create an error response
pub fn errorResponse(code: i32, message: []const u8) Response {
    return .{ .err = .{ .code = code, .message = message } };
}

// =============================================================================
// Tests
// =============================================================================

test "server binds to ephemeral port" {
    const allocator = std.testing.allocator;

    var server = TuiServer.init(allocator, testHandler, null);
    defer server.deinit();

    try server.start();
    const port = server.getPort();

    try std.testing.expect(port > 0);
    try std.testing.expect(server.running);

    server.stop();
    try std.testing.expect(!server.running);
}

test "server accepts connection" {
    const allocator = std.testing.allocator;

    var server = TuiServer.init(allocator, testHandler, null);
    defer server.deinit();

    try server.start();
    const port = server.getPort();

    // Connect as client
    const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const stream = try net.tcpConnectToAddress(address);
    defer stream.close();

    // Poll to accept
    try server.poll();

    try std.testing.expect(server.clients.items.len == 1);
}

test "server handles request" {
    const allocator = std.testing.allocator;

    var server = TuiServer.init(allocator, testEchoHandler, null);
    defer server.deinit();

    try server.start();
    const port = server.getPort();

    // Connect as client
    const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const stream = try net.tcpConnectToAddress(address);
    defer stream.close();

    // Send request
    try stream.writeAll("{\"method\":\"echo\",\"id\":\"test-1\",\"params\":{\"msg\":\"hello\"}}\n");

    // Poll to accept and process
    try server.poll();

    // Read response
    var response_buf: [1024]u8 = undefined;
    const bytes_read = try stream.read(&response_buf);
    const response = response_buf[0..bytes_read];

    try std.testing.expect(std.mem.indexOf(u8, response, "\"result\"") != null);
}

test "server handles malformed JSON" {
    const allocator = std.testing.allocator;

    var server = TuiServer.init(allocator, testHandler, null);
    defer server.deinit();

    try server.start();
    const port = server.getPort();

    // Connect as client
    const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const stream = try net.tcpConnectToAddress(address);
    defer stream.close();

    // Send malformed JSON
    try stream.writeAll("not valid json\n");

    // Poll to process
    try server.poll();

    // Read response
    var response_buf: [1024]u8 = undefined;
    const bytes_read = try stream.read(&response_buf);
    const response = response_buf[0..bytes_read];

    try std.testing.expect(std.mem.indexOf(u8, response, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "-32700") != null); // PARSE_ERROR
}

fn testHandler(_: Request, _: ?*anyopaque) Response {
    return .{ .result = .null };
}

fn testEchoHandler(_: Request, _: ?*anyopaque) Response {
    return .{ .result = .{ .string = "echoed" } };
}
