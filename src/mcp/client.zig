const std = @import("std");
const net = std.net;
const posix = std.posix;
const protocol = @import("protocol.zig");
const discovery = @import("discovery.zig");

const Allocator = std.mem.Allocator;

/// TCP client for skim TUI to connect to MCP server.
/// Handles non-blocking I/O for integration with the main event loop.
pub const McpClient = struct {
    allocator: Allocator,
    stream: ?net.Stream,
    recv_buffer: [8192]u8,
    recv_len: usize,
    pending_messages: std.ArrayList(protocol.ParsedMessage),
    connected: bool,
    session_id: ?[]const u8,

    pub fn init(allocator: Allocator) McpClient {
        return .{
            .allocator = allocator,
            .stream = null,
            .recv_buffer = undefined,
            .recv_len = 0,
            .pending_messages = std.ArrayList(protocol.ParsedMessage).init(allocator),
            .connected = false,
            .session_id = null,
        };
    }

    pub fn deinit(self: *McpClient) void {
        self.disconnect();
        self.clearPendingMessages();
        self.pending_messages.deinit();
        if (self.session_id) |id| {
            self.allocator.free(id);
        }
    }

    /// Attempt to connect to the MCP server on specified port.
    /// Returns error if connection fails.
    pub fn connect(self: *McpClient, port: u16) !void {
        if (self.connected) return;

        const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
        self.stream = try net.tcpConnectToAddress(address);
        self.connected = true;
        self.recv_len = 0;

        // Set non-blocking mode
        try self.setNonBlocking(true);
    }

    /// Connection result for discovery-based connection
    pub const DiscoveryResult = union(enum) {
        connected: u16, // port connected to
        not_running,
        stale: []const u8, // reason
        unhealthy: []const u8, // reason
        connection_failed: anyerror,
    };

    /// Attempt to connect using daemon discovery.
    /// Returns the discovery result indicating success or reason for failure.
    pub fn connectWithDiscovery(self: *McpClient) DiscoveryResult {
        if (self.connected) return .{ .connected = 0 };

        const status = discovery.discoverDaemon(self.allocator);

        switch (status) {
            .running => |info| {
                self.connect(info.tui_port) catch |err| {
                    return .{ .connection_failed = err };
                };
                return .{ .connected = info.tui_port };
            },
            .not_running => return .not_running,
            .stale => |s| return .{ .stale = s.reason },
            .unhealthy => |u| return .{ .unhealthy = u.reason },
        }
    }

    /// Check if daemon is running without connecting
    pub fn isDaemonRunning(self: *McpClient) bool {
        const status = discovery.discoverDaemon(self.allocator);
        return status == .running;
    }

    /// Disconnect from the server
    pub fn disconnect(self: *McpClient) void {
        if (self.stream) |stream| {
            stream.close();
        }
        self.stream = null;
        self.connected = false;
        self.recv_len = 0;
    }

    /// Send a message to the server
    pub fn send(self: *McpClient, msg: []const u8) !void {
        if (!self.connected) return error.NotConnected;

        const stream = self.stream orelse return error.NotConnected;

        // Temporarily set blocking mode for send
        try self.setNonBlocking(false);
        defer self.setNonBlocking(true) catch {};

        try stream.writeAll(msg);
    }

    /// Send a hello message to register with the server
    pub fn sendHello(self: *McpClient, payload: protocol.HelloPayload) !void {
        const msg = try protocol.encodeHello(self.allocator, payload);
        defer self.allocator.free(msg);
        try self.send(msg);
    }

    /// Send a comment_added response
    pub fn sendCommentAdded(self: *McpClient, success: bool, comment_idx: ?usize, err_msg: ?[]const u8) !void {
        const msg = try protocol.encodeCommentAdded(self.allocator, success, comment_idx, err_msg);
        defer self.allocator.free(msg);
        try self.send(msg);
    }

    /// Send comments list
    pub fn sendComments(self: *McpClient, comments: []const protocol.CommentInfo) !void {
        const msg = try protocol.encodeComments(self.allocator, comments);
        defer self.allocator.free(msg);
        try self.send(msg);
    }

    /// Poll for incoming messages (non-blocking).
    /// Messages are added to pending_messages and should be consumed by the caller.
    pub fn pollMessages(self: *McpClient) !void {
        if (!self.connected) return;

        const stream = self.stream orelse return;

        // Try to read available data (non-blocking)
        const bytes_read = stream.read(self.recv_buffer[self.recv_len..]) catch |err| switch (err) {
            error.WouldBlock => return, // No data available, that's fine
            error.ConnectionResetByPeer, error.BrokenPipe => {
                std.log.debug("MCP client: pollMessages got connection error: {}", .{err});
                self.handleDisconnect();
                return;
            },
            else => {
                std.log.debug("MCP client: pollMessages got error: {}", .{err});
                return err;
            },
        };

        if (bytes_read == 0) {
            // Connection closed by server (EOF)
            std.log.debug("MCP client: pollMessages got 0 bytes (EOF), disconnecting", .{});
            self.handleDisconnect();
            return;
        }

        std.log.debug("MCP client: pollMessages read {d} bytes", .{bytes_read});
        self.recv_len += bytes_read;

        // Parse complete messages (newline-delimited)
        try self.parseBufferedMessages();
    }

    /// Check if there are pending messages to process
    pub fn hasPendingMessages(self: *const McpClient) bool {
        return self.pending_messages.items.len > 0;
    }

    /// Get and clear pending messages
    pub fn consumeMessages(self: *McpClient) []protocol.ParsedMessage {
        const messages = self.pending_messages.toOwnedSlice() catch {
            return &[_]protocol.ParsedMessage{};
        };
        self.pending_messages = std.ArrayList(protocol.ParsedMessage).init(self.allocator);
        return messages;
    }

    /// Free a list of consumed messages
    pub fn freeMessages(self: *McpClient, messages: []protocol.ParsedMessage) void {
        for (messages) |*msg| {
            self.freeMessage(msg);
        }
        self.allocator.free(messages);
    }

    /// Free a single message
    pub fn freeMessage(self: *McpClient, msg: *protocol.ParsedMessage) void {
        switch (msg.*) {
            .hello => |h| {
                self.allocator.free(h.id);
                self.allocator.free(h.cwd);
                self.allocator.free(h.diff_ref);
                for (h.files) |f| {
                    self.allocator.free(f.path);
                    self.allocator.free(f.old_path);
                }
                self.allocator.free(h.files);
            },
            .welcome => |w| {
                self.allocator.free(w.id);
            },
            .add_comment => |ac| {
                self.allocator.free(ac.file);
                self.allocator.free(ac.text);
            },
            .comment_added => |ca| {
                if (ca.@"error") |e| self.allocator.free(e);
            },
            .comments => |c| {
                for (c.comments) |comment| {
                    self.allocator.free(comment.file_path);
                    self.allocator.free(comment.text);
                    self.allocator.free(comment.line_type);
                }
                self.allocator.free(c.comments);
            },
            .@"error" => |e| {
                self.allocator.free(e.code);
                self.allocator.free(e.message);
            },
            .unknown => |u| {
                self.allocator.free(u);
            },
            .get_comments, .ping, .pong => {},
        }
    }

    // Internal helpers

    fn setNonBlocking(self: *McpClient, non_blocking: bool) !void {
        if (self.stream) |stream| {
            const flags = try posix.fcntl(stream.handle, posix.F.GETFL, @as(usize, 0));
            // O_NONBLOCK value for darwin/macOS
            const O_NONBLOCK: usize = 0x0004;
            const new_flags: usize = if (non_blocking)
                flags | O_NONBLOCK
            else
                flags & ~O_NONBLOCK;
            _ = try posix.fcntl(stream.handle, posix.F.SETFL, new_flags);
        }
    }

    fn handleDisconnect(self: *McpClient) void {
        std.log.debug("MCP client: handleDisconnect called", .{});
        self.disconnect();
    }

    fn parseBufferedMessages(self: *McpClient) !void {
        var start: usize = 0;

        while (start < self.recv_len) {
            // Find newline
            const newline_pos = std.mem.indexOfScalar(u8, self.recv_buffer[start..self.recv_len], '\n');
            if (newline_pos) |pos| {
                const end = start + pos;
                const line = self.recv_buffer[start..end];

                if (line.len > 0) {
                    // Parse the JSON message
                    const msg = protocol.decode(self.allocator, line) catch {
                        start = end + 1;
                        continue;
                    };
                    try self.pending_messages.append(msg);
                }

                start = end + 1;
            } else {
                // No complete message yet
                break;
            }
        }

        // Move remaining data to beginning of buffer
        if (start > 0 and start < self.recv_len) {
            const remaining = self.recv_len - start;
            std.mem.copyForwards(u8, self.recv_buffer[0..remaining], self.recv_buffer[start..self.recv_len]);
            self.recv_len = remaining;
        } else if (start >= self.recv_len) {
            self.recv_len = 0;
        }
    }

    fn clearPendingMessages(self: *McpClient) void {
        for (self.pending_messages.items) |*msg| {
            self.freeMessage(msg);
        }
        self.pending_messages.clearRetainingCapacity();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "client init and deinit" {
    const allocator = std.testing.allocator;

    var client = McpClient.init(allocator);
    defer client.deinit();

    try std.testing.expect(!client.connected);
    try std.testing.expect(client.stream == null);
}

test "parse buffered messages" {
    const allocator = std.testing.allocator;

    var client = McpClient.init(allocator);
    defer client.deinit();

    // Simulate receiving two messages
    const data = "{\"event\":\"ping\"}\n{\"event\":\"pong\"}\n";
    @memcpy(client.recv_buffer[0..data.len], data);
    client.recv_len = data.len;

    try client.parseBufferedMessages();

    try std.testing.expectEqual(@as(usize, 2), client.pending_messages.items.len);
    try std.testing.expect(client.pending_messages.items[0] == .ping);
    try std.testing.expect(client.pending_messages.items[1] == .pong);
    try std.testing.expectEqual(@as(usize, 0), client.recv_len);
}

test "parse partial message buffering" {
    const allocator = std.testing.allocator;

    var client = McpClient.init(allocator);
    defer client.deinit();

    // Simulate receiving partial message
    const partial = "{\"event\":\"pi";
    @memcpy(client.recv_buffer[0..partial.len], partial);
    client.recv_len = partial.len;

    try client.parseBufferedMessages();

    // No complete messages yet
    try std.testing.expectEqual(@as(usize, 0), client.pending_messages.items.len);
    // Partial data still in buffer
    try std.testing.expectEqual(@as(usize, partial.len), client.recv_len);
}

test "discovery result types" {
    const allocator = std.testing.allocator;

    var client = McpClient.init(allocator);
    defer client.deinit();

    // Without a daemon running, should return not_running
    const result = client.connectWithDiscovery();
    switch (result) {
        .not_running, .stale, .unhealthy, .connection_failed => {},
        .connected => {
            // If somehow connected, disconnect
            client.disconnect();
        },
    }

    // Client should not be connected (no daemon in test)
    // Note: This test may pass or fail depending on whether a daemon is actually running
}
