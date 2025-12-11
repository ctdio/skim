const std = @import("std");
const net = std.net;
const posix = std.posix;
const protocol = @import("protocol.zig");
const discovery = @import("discovery.zig");

const Allocator = std.mem.Allocator;

/// TCP client for skim TUI to connect to MCP server.
/// Uses a background thread for reading to avoid blocking the main event loop.
pub const McpClient = struct {
    allocator: Allocator,
    stream: ?net.Stream,
    connected: bool,
    session_id: ?[]const u8,
    last_connect_port: ?u16, // For reconnection
    last_reconnect_attempt: i64, // Timestamp of last reconnect attempt

    // Thread-safe message queue (reader thread -> main thread)
    message_queue: std.ArrayList(protocol.ParsedMessage),
    queue_mutex: std.Thread.Mutex,

    // Reader thread management
    reader_thread: ?std.Thread,
    shutdown_flag: std.atomic.Value(bool),
    needs_reconnect: std.atomic.Value(bool),

    // For freeing messages (needed by main thread)
    const Self = @This();

    pub fn init(allocator: Allocator) McpClient {
        return .{
            .allocator = allocator,
            .stream = null,
            .connected = false,
            .session_id = null,
            .last_connect_port = null,
            .last_reconnect_attempt = 0,
            .message_queue = std.ArrayList(protocol.ParsedMessage).init(allocator),
            .queue_mutex = .{},
            .reader_thread = null,
            .shutdown_flag = std.atomic.Value(bool).init(false),
            .needs_reconnect = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *McpClient) void {
        self.disconnect();

        // Clear any remaining messages in queue
        self.queue_mutex.lock();
        for (self.message_queue.items) |*msg| {
            freeMessageStatic(self.allocator, msg);
        }
        self.message_queue.deinit();
        self.queue_mutex.unlock();

        if (self.session_id) |id| {
            self.allocator.free(id);
        }
    }

    /// Attempt to connect to the MCP server on specified port.
    /// Spawns a background reader thread for incoming messages.
    pub fn connect(self: *McpClient, port: u16) !void {
        if (self.connected) return;

        self.last_connect_port = port;
        const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
        self.stream = try net.tcpConnectToAddress(address);
        self.connected = true;
        self.shutdown_flag.store(false, .release);
        self.needs_reconnect.store(false, .release);

        // Enable TCP keepalive to detect dead connections
        if (self.stream) |s| {
            setKeepalive(s.handle);
        }

        // Spawn reader thread
        self.reader_thread = try std.Thread.spawn(.{}, readerThreadFn, .{self});
    }

    /// Attempt to connect with retries (for initial connection)
    pub fn connectWithRetry(self: *McpClient, port: u16, max_retries: u32) !void {
        var retries: u32 = 0;
        while (retries < max_retries) : (retries += 1) {
            self.connect(port) catch |err| {
                if (retries + 1 < max_retries) {
                    // Wait before retry (50ms, 100ms, 150ms...)
                    std.time.sleep((retries + 1) * 50 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            return; // Success
        }
    }

    /// Check if reconnection is needed (set by reader thread on disconnect)
    pub fn needsReconnect(self: *McpClient) bool {
        return self.needs_reconnect.load(.acquire);
    }

    /// Attempt to reconnect if disconnected (with 2 second cooldown)
    pub fn tryReconnect(self: *McpClient) bool {
        if (self.connected) return true;

        const port = self.last_connect_port orelse return false;

        // Cooldown: only try once every 2 seconds
        const now = std.time.timestamp();
        if (now - self.last_reconnect_attempt < 2) {
            return false;
        }
        self.last_reconnect_attempt = now;

        // Clean up old reader thread if any
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }

        // Close old stream if any (to avoid fd leak)
        if (self.stream) |stream| {
            stream.close();
            self.stream = null;
        }

        self.connect(port) catch {
            return false;
        };

        // Clear the reconnect flag on success
        self.needs_reconnect.store(false, .release);
        std.log.info("MCP client reconnected to daemon", .{});
        return true;
    }

    /// Check if reconnection is needed and attempt if so
    /// Returns true if connected (either already or after reconnect)
    pub fn checkAndReconnect(self: *McpClient) bool {
        if (self.connected) return true;
        if (!self.needs_reconnect.load(.acquire)) return false;
        return self.tryReconnect();
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

    /// Disconnect from the server and stop reader thread
    pub fn disconnect(self: *McpClient) void {
        if (!self.connected) return;

        // Signal reader thread to stop
        self.shutdown_flag.store(true, .release);

        // Close stream (this will unblock the reader thread's blocking read)
        if (self.stream) |stream| {
            stream.close();
        }
        self.stream = null;
        self.connected = false;

        // Wait for reader thread to finish
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
    }

    /// Send a message to the server (called from main thread)
    pub fn send(self: *McpClient, msg: []const u8) !void {
        if (!self.connected) return error.NotConnected;

        const stream = self.stream orelse return error.NotConnected;

        // Write is thread-safe on TCP sockets (full-duplex)
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

    /// Send diff context response
    pub fn sendDiffContext(self: *McpClient, payload: protocol.DiffContextPayload) !void {
        const msg = try protocol.encodeDiffContext(self.allocator, payload);
        defer self.allocator.free(msg);
        try self.send(msg);
    }

    /// Send file diff response
    pub fn sendFileDiff(self: *McpClient, payload: protocol.FileDiffPayload) !void {
        const msg = try protocol.encodeFileDiff(self.allocator, payload);
        defer self.allocator.free(msg);
        try self.send(msg);
    }

    /// Check if there are pending messages to process (non-blocking)
    pub fn hasPendingMessages(self: *McpClient) bool {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        return self.message_queue.items.len > 0;
    }

    /// Get and clear pending messages (called from main thread)
    pub fn consumeMessages(self: *McpClient) []protocol.ParsedMessage {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        const messages = self.message_queue.toOwnedSlice() catch {
            return &[_]protocol.ParsedMessage{};
        };
        self.message_queue = std.ArrayList(protocol.ParsedMessage).init(self.allocator);
        return messages;
    }

    /// Free a list of consumed messages
    pub fn freeMessages(self: *McpClient, messages: []protocol.ParsedMessage) void {
        for (messages) |*msg| {
            freeMessageStatic(self.allocator, msg);
        }
        self.allocator.free(messages);
    }

    /// Free a single message (static version for use by reader thread)
    fn freeMessageStatic(allocator: Allocator, msg: *protocol.ParsedMessage) void {
        switch (msg.*) {
            .hello => |h| {
                allocator.free(h.id);
                allocator.free(h.cwd);
                allocator.free(h.diff_ref);
                for (h.files) |f| {
                    allocator.free(f.path);
                    allocator.free(f.old_path);
                }
                allocator.free(h.files);
            },
            .welcome => |w| {
                allocator.free(w.id);
            },
            .add_comment => |ac| {
                allocator.free(ac.file);
                allocator.free(ac.text);
            },
            .comment_added => |ca| {
                if (ca.@"error") |e| allocator.free(e);
            },
            .comments => |c| {
                for (c.comments) |comment| {
                    allocator.free(comment.file_path);
                    allocator.free(comment.text);
                    allocator.free(comment.line_type);
                }
                allocator.free(c.comments);
            },
            .@"error" => |e| {
                allocator.free(e.code);
                allocator.free(e.message);
            },
            .diff_context => |d| {
                allocator.free(d.diff_ref);
                allocator.free(d.cwd);
                for (d.files) |file| {
                    allocator.free(file.path);
                    allocator.free(file.old_path);
                    allocator.free(file.status);
                }
                allocator.free(d.files);
            },
            .get_file_diff => |gfd| {
                allocator.free(gfd.file);
            },
            .file_diff => |fd| {
                allocator.free(fd.file);
                allocator.free(fd.old_file);
                allocator.free(fd.status);
                for (fd.hunks) |hunk| {
                    allocator.free(hunk.header);
                    for (hunk.lines) |line| {
                        allocator.free(line.line_type);
                        allocator.free(line.content);
                    }
                    allocator.free(hunk.lines);
                }
                allocator.free(fd.hunks);
            },
            .unknown => |u| {
                allocator.free(u);
            },
            .get_comments, .get_diff_context, .ping, .pong => {},
        }
    }

    // =========================================================================
    // Reader Thread
    // =========================================================================

    fn readerThreadFn(self: *Self) void {
        var recv_buffer: [8192]u8 = undefined;
        var recv_len: usize = 0;

        while (!self.shutdown_flag.load(.acquire)) {
            const stream = self.stream orelse break;

            // Blocking read
            const bytes_read = stream.read(recv_buffer[recv_len..]) catch |err| {
                switch (err) {
                    error.ConnectionResetByPeer, error.BrokenPipe => {
                        std.log.debug("MCP reader: connection error: {}", .{err});
                        // Signal that reconnection is needed (unless shutting down)
                        if (!self.shutdown_flag.load(.acquire)) {
                            self.connected = false;
                            self.needs_reconnect.store(true, .release);
                        }
                    },
                    else => {
                        // Socket was likely closed by main thread during shutdown
                        if (!self.shutdown_flag.load(.acquire)) {
                            std.log.debug("MCP reader: read error: {}", .{err});
                            self.connected = false;
                            self.needs_reconnect.store(true, .release);
                        }
                    },
                }
                break;
            };

            if (bytes_read == 0) {
                // EOF - server closed connection
                std.log.debug("MCP reader: EOF, server disconnected", .{});
                // Signal that reconnection is needed (unless shutting down)
                if (!self.shutdown_flag.load(.acquire)) {
                    self.connected = false;
                    self.needs_reconnect.store(true, .release);
                }
                break;
            }

            recv_len += bytes_read;

            // Parse complete messages (newline-delimited)
            var start: usize = 0;
            while (start < recv_len) {
                const newline_pos = std.mem.indexOfScalar(u8, recv_buffer[start..recv_len], '\n');
                if (newline_pos) |pos| {
                    const end = start + pos;
                    const line = recv_buffer[start..end];

                    if (line.len > 0) {
                        // Parse the JSON message
                        const msg = protocol.decode(self.allocator, line) catch {
                            start = end + 1;
                            continue;
                        };

                        // Add to queue (thread-safe)
                        self.queue_mutex.lock();
                        self.message_queue.append(msg) catch {
                            // Queue full or OOM, drop message
                            freeMessageStatic(self.allocator, @constCast(&msg));
                        };
                        self.queue_mutex.unlock();
                    }

                    start = end + 1;
                } else {
                    break;
                }
            }

            // Move remaining data to beginning of buffer
            if (start > 0 and start < recv_len) {
                const remaining = recv_len - start;
                std.mem.copyForwards(u8, recv_buffer[0..remaining], recv_buffer[start..recv_len]);
                recv_len = remaining;
            } else if (start >= recv_len) {
                recv_len = 0;
            }
        }

        std.log.debug("MCP reader: thread exiting", .{});
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

fn setKeepalive(handle: posix.socket_t) void {
    const enable: c_int = 1;
    posix.setsockopt(handle, posix.SOL.SOCKET, posix.SO.KEEPALIVE, std.mem.asBytes(&enable)) catch |err| {
        std.log.warn("Failed to set SO_KEEPALIVE: {}", .{err});
    };

    // Set aggressive keepalive parameters to detect dead connections faster
    // TCP_KEEPALIVE (macOS) / TCP_KEEPIDLE (Linux): idle time before first probe
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

test "client init and deinit" {
    const allocator = std.testing.allocator;

    var client = McpClient.init(allocator);
    defer client.deinit();

    try std.testing.expect(!client.connected);
    try std.testing.expect(client.stream == null);
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
