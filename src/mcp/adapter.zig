const std = @import("std");
const net = std.net;
const posix = std.posix;

const Allocator = std.mem.Allocator;

const internal_protocol = @import("internal_protocol.zig");
const discovery = @import("discovery.zig");
const registry = @import("registry.zig");

// =============================================================================
// MCP Adapter
// =============================================================================

/// Thin MCP adapter that bridges stdio (JSON-RPC from agent) to daemon (TCP)
pub const McpAdapter = struct {
    allocator: Allocator,

    // Connection to daemon
    daemon_stream: ?net.Stream,
    daemon_recv_buffer: [65536]u8,
    daemon_recv_len: usize,

    // Stdin buffer for MCP protocol
    stdin_buffer: [65536]u8,
    stdin_len: usize,

    // State
    adapter_id: registry.SessionId,
    running: bool,
    mcp_initialized: bool,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .daemon_stream = null,
            .daemon_recv_buffer = undefined,
            .daemon_recv_len = 0,
            .stdin_buffer = undefined,
            .stdin_len = 0,
            .adapter_id = registry.generateSessionId(),
            .running = false,
            .mcp_initialized = false,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.daemon_stream) |stream| {
            // Send goodbye
            const goodbye = internal_protocol.encodeAdapterGoodbye(self.allocator) catch null;
            if (goodbye) |msg| {
                stream.writeAll(msg) catch {};
                self.allocator.free(msg);
            }
            stream.close();
        }
        self.daemon_stream = null;
    }

    /// Connect to the daemon
    pub fn connectToDaemon(self: *Self, port: u16) !void {
        const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
        self.daemon_stream = try net.tcpConnectToAddress(address);

        // Set non-blocking and enable keepalive
        try setNonBlocking(self.daemon_stream.?.handle);
        setKeepalive(self.daemon_stream.?.handle);

        // Send hello
        const hello = try internal_protocol.encodeAdapterHello(self.allocator, &self.adapter_id);
        defer self.allocator.free(hello);

        // Temporarily set blocking for hello
        try setBlocking(self.daemon_stream.?.handle);
        try self.daemon_stream.?.writeAll(hello);
        try setNonBlocking(self.daemon_stream.?.handle);

        std.log.debug("Adapter connected to daemon on port {d}", .{port});
    }

    /// Main adapter loop
    pub fn run(self: *Self) !void {
        // Set stdin to non-blocking
        try setNonBlocking(std.io.getStdIn().handle);
        defer setBlocking(std.io.getStdIn().handle) catch {};

        self.running = true;

        while (self.running) {
            // Poll stdin for MCP requests from agent
            try self.pollStdin();

            // Poll daemon for responses
            try self.pollDaemon();

            // Small sleep to avoid busy-waiting
            std.time.sleep(1 * std.time.ns_per_ms);
        }
    }

    // =========================================================================
    // Stdin Handling (MCP JSON-RPC from agent)
    // =========================================================================

    fn pollStdin(self: *Self) !void {
        const stdin = std.io.getStdIn();

        const bytes_read = stdin.read(self.stdin_buffer[self.stdin_len..]) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };

        if (bytes_read == 0) {
            // EOF on stdin - agent disconnected
            std.log.debug("Stdin closed, shutting down adapter", .{});
            self.running = false;
            return;
        }

        self.stdin_len += bytes_read;

        // Parse complete lines (newline-delimited JSON-RPC)
        var parse_start: usize = 0;
        while (parse_start < self.stdin_len) {
            const newline_pos = std.mem.indexOfScalar(u8, self.stdin_buffer[parse_start..self.stdin_len], '\n');
            if (newline_pos) |pos| {
                const end = parse_start + pos;
                const line = self.stdin_buffer[parse_start..end];

                if (line.len > 0) {
                    try self.handleMcpRequest(line);
                }

                parse_start = end + 1;
            } else {
                break;
            }
        }

        // Move remaining data
        if (parse_start > 0 and parse_start < self.stdin_len) {
            const remaining = self.stdin_len - parse_start;
            std.mem.copyForwards(u8, self.stdin_buffer[0..remaining], self.stdin_buffer[parse_start..self.stdin_len]);
            self.stdin_len = remaining;
        } else if (parse_start >= self.stdin_len) {
            self.stdin_len = 0;
        }
    }

    fn handleMcpRequest(self: *Self, line: []const u8) !void {
        const stdout = std.io.getStdOut().writer();

        // Parse JSON-RPC request
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch {
            try self.sendMcpError(stdout, null, -32700, "Parse error");
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            try self.sendMcpError(stdout, null, -32600, "Invalid Request");
            return;
        }

        const obj = root.object;
        const method = obj.get("method") orelse {
            try self.sendMcpError(stdout, null, -32600, "Missing method");
            return;
        };

        if (method != .string) {
            try self.sendMcpError(stdout, null, -32600, "Invalid method");
            return;
        }

        const id = obj.get("id");
        const params = obj.get("params");

        // Handle notifications locally (no daemon round-trip needed)
        if (std.mem.eql(u8, method.string, "notifications/initialized")) {
            self.mcp_initialized = true;
            return; // No response for notifications
        }

        // Forward to daemon
        try self.forwardToDaemon(method.string, id, params);
    }

    fn forwardToDaemon(self: *Self, method: []const u8, id: ?std.json.Value, params: ?std.json.Value) !void {
        const stream = self.daemon_stream orelse {
            const stdout = std.io.getStdOut().writer();
            try self.sendMcpError(stdout, id, -32001, "Not connected to daemon");
            return;
        };

        // Generate request ID
        const request_id = registry.generateSessionId();

        // Parse MCP ID
        const mcp_id: internal_protocol.McpId = if (id) |id_val| blk: {
            break :blk switch (id_val) {
                .string => |s| .{ .string = try self.allocator.dupe(u8, s) },
                .integer => |n| .{ .number = n },
                .null => .{ .null_value = {} },
                else => .{ .null_value = {} },
            };
        } else .{ .null_value = {} };
        defer {
            switch (mcp_id) {
                .string => |s| self.allocator.free(s),
                else => {},
            }
        }

        // Stringify params
        var params_str: ?[]u8 = null;
        defer if (params_str) |p| self.allocator.free(p);

        if (params) |p| {
            var output = std.ArrayList(u8).init(self.allocator);
            errdefer output.deinit();
            try std.json.stringify(p, .{}, output.writer());
            params_str = try output.toOwnedSlice();
        }

        // Encode and send
        const msg = try internal_protocol.encodeMcpRequest(self.allocator, .{
            .request_id = &request_id,
            .mcp_id = mcp_id,
            .method = method,
            .params = params_str,
        });
        defer self.allocator.free(msg);

        // Temporarily set blocking for send
        try setBlocking(stream.handle);
        defer setNonBlocking(stream.handle) catch {};

        stream.writeAll(msg) catch |err| {
            std.log.err("Failed to send to daemon: {}", .{err});
            const stdout = std.io.getStdOut().writer();
            try self.sendMcpError(stdout, id, -32000, "Failed to communicate with daemon");
        };
    }

    // =========================================================================
    // Daemon Handling
    // =========================================================================

    fn pollDaemon(self: *Self) !void {
        const stream = self.daemon_stream orelse return;

        const bytes_read = stream.read(self.daemon_recv_buffer[self.daemon_recv_len..]) catch |err| switch (err) {
            error.WouldBlock => return,
            error.ConnectionResetByPeer, error.BrokenPipe => {
                std.log.err("Lost connection to daemon", .{});
                self.daemon_stream = null;
                self.running = false;
                return;
            },
            else => return err,
        };

        if (bytes_read == 0) {
            std.log.err("Daemon closed connection", .{});
            self.daemon_stream = null;
            self.running = false;
            return;
        }

        self.daemon_recv_len += bytes_read;

        // Parse complete lines
        var parse_start: usize = 0;
        while (parse_start < self.daemon_recv_len) {
            const newline_pos = std.mem.indexOfScalar(u8, self.daemon_recv_buffer[parse_start..self.daemon_recv_len], '\n');
            if (newline_pos) |pos| {
                const end = parse_start + pos;
                const line = self.daemon_recv_buffer[parse_start..end];

                if (line.len > 0) {
                    try self.handleDaemonMessage(line);
                }

                parse_start = end + 1;
            } else {
                break;
            }
        }

        // Move remaining data
        if (parse_start > 0 and parse_start < self.daemon_recv_len) {
            const remaining = self.daemon_recv_len - parse_start;
            std.mem.copyForwards(u8, self.daemon_recv_buffer[0..remaining], self.daemon_recv_buffer[parse_start..self.daemon_recv_len]);
            self.daemon_recv_len = remaining;
        } else if (parse_start >= self.daemon_recv_len) {
            self.daemon_recv_len = 0;
        }
    }

    fn handleDaemonMessage(self: *Self, line: []const u8) !void {
        var msg = internal_protocol.decodeDaemonMessage(self.allocator, line) catch |err| {
            std.log.warn("Failed to parse daemon message: {}", .{err});
            return;
        };
        defer internal_protocol.freeDaemonMessage(self.allocator, &msg);

        const stdout = std.io.getStdOut().writer();

        switch (msg) {
            .adapter_welcome => |welcome| {
                std.log.debug("Received welcome from daemon, {d} clients connected", .{welcome.clients.len});
            },
            .mcp_response => |response| {
                // Forward response to agent
                try self.writeMcpResponse(stdout, response);
            },
            .client_update => |update| {
                std.log.debug("Client {s}: {s}", .{
                    update.client.id,
                    if (update.action == .connected) "connected" else "disconnected",
                });
            },
            .status_response => {
                // Status responses are not expected by the adapter
                std.log.debug("Unexpected status_response received by adapter", .{});
            },
            .unknown => {},
        }
    }

    fn writeMcpResponse(self: *Self, writer: anytype, response: internal_protocol.McpResponsePayload) !void {
        _ = self;

        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");

        // Write the MCP ID from the response
        switch (response.mcp_id) {
            .number => |n| try std.fmt.formatInt(n, 10, .lower, .{}, writer),
            .string => |s| {
                try writer.writeByte('"');
                try writer.writeAll(s);
                try writer.writeByte('"');
            },
            .null_value => try writer.writeAll("null"),
        }

        if (response.result) |result| {
            try writer.writeAll(",\"result\":");
            try writer.writeAll(result);
        }

        if (response.@"error") |err| {
            try writer.writeAll(",\"error\":{\"code\":");
            try std.fmt.formatInt(err.code, 10, .lower, .{}, writer);
            try writer.writeAll(",\"message\":\"");
            try writer.writeAll(err.message);
            try writer.writeAll("\"}");
        }

        try writer.writeAll("}\n");
    }

    // =========================================================================
    // Helper Functions
    // =========================================================================

    fn sendMcpError(self: *Self, writer: anytype, id: ?std.json.Value, code: i32, message: []const u8) !void {
        _ = self;
        _ = id;

        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":");
        try std.fmt.formatInt(code, 10, .lower, .{}, writer);
        try writer.writeAll(",\"message\":\"");
        try writer.writeAll(message);
        try writer.writeAll("\"}}\n");
    }
};

// =============================================================================
// Public Entry Point
// =============================================================================

/// Run the MCP adapter, connecting to daemon on the specified port
pub fn runAdapter(allocator: Allocator, port: u16) !void {
    var adapter = McpAdapter.init(allocator);
    defer adapter.deinit();

    adapter.connectToDaemon(port) catch |err| {
        // Daemon not running - check if auto-start is enabled
        if (discovery.isAutoStartEnabled()) {
            std.log.info("Auto-starting daemon...", .{});
            // TODO: Implement auto-start logic
            // For now, fall through to error
        }

        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32001,\"message\":\"skim daemon not running. Start with: skim daemon start\"}}\n");
        std.log.err("Failed to connect to daemon: {}", .{err});
        return;
    };

    try adapter.run();
}

/// Check if daemon is running and return status for MCP initialization
pub fn checkDaemonStatus(allocator: Allocator) discovery.DaemonStatus {
    return discovery.discoverDaemon(allocator);
}

// =============================================================================
// Helper Functions
// =============================================================================

fn setNonBlocking(handle: posix.fd_t) !void {
    const flags = try posix.fcntl(handle, posix.F.GETFL, @as(usize, 0));
    const O_NONBLOCK: usize = 0x0004; // darwin/macOS
    _ = try posix.fcntl(handle, posix.F.SETFL, flags | O_NONBLOCK);
}

fn setBlocking(handle: posix.fd_t) !void {
    const flags = try posix.fcntl(handle, posix.F.GETFL, @as(usize, 0));
    const O_NONBLOCK: usize = 0x0004;
    _ = try posix.fcntl(handle, posix.F.SETFL, flags & ~O_NONBLOCK);
}

fn setKeepalive(handle: posix.socket_t) void {
    const enable: c_int = 1;
    posix.setsockopt(handle, posix.SOL.SOCKET, posix.SO.KEEPALIVE, std.mem.asBytes(&enable)) catch |err| {
        std.log.warn("Failed to set SO_KEEPALIVE: {}", .{err});
    };

    // Set aggressive keepalive parameters to detect dead connections faster
    const keepalive_time: c_int = 30; // 30 seconds
    const IPPROTO_TCP: u32 = 6;

    const builtin = @import("builtin");
    if (builtin.os.tag == .macos) {
        const TCP_KEEPALIVE: u32 = 0x10; // macOS specific
        posix.setsockopt(handle, IPPROTO_TCP, TCP_KEEPALIVE, std.mem.asBytes(&keepalive_time)) catch {};
    } else if (builtin.os.tag == .linux) {
        const TCP_KEEPIDLE: u32 = 4;
        const TCP_KEEPINTVL: u32 = 5;
        const TCP_KEEPCNT: u32 = 6;
        const keepalive_interval: c_int = 10; // 10 seconds between probes
        const keepalive_count: c_int = 3; // 3 probes before giving up

        posix.setsockopt(handle, IPPROTO_TCP, TCP_KEEPIDLE, std.mem.asBytes(&keepalive_time)) catch {};
        posix.setsockopt(handle, IPPROTO_TCP, TCP_KEEPINTVL, std.mem.asBytes(&keepalive_interval)) catch {};
        posix.setsockopt(handle, IPPROTO_TCP, TCP_KEEPCNT, std.mem.asBytes(&keepalive_count)) catch {};
    }
}

// =============================================================================
// Tests
// =============================================================================

test "adapter init and deinit" {
    const allocator = std.testing.allocator;

    var adapter = McpAdapter.init(allocator);
    defer adapter.deinit();

    try std.testing.expect(!adapter.running);
    try std.testing.expect(adapter.daemon_stream == null);
}
