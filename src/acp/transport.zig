const std = @import("std");
const Allocator = std.mem.Allocator;
const process = @import("process.zig");
const codec = @import("codec.zig");

// =============================================================================
// Stdio Transport
// =============================================================================

/// Manages JSON-RPC communication over stdio with an agent process.
/// Uses a background thread for non-blocking reads.
pub const StdioTransport = struct {
    allocator: Allocator,
    agent: *process.AgentProcess,
    decoder: codec.Decoder,
    encoder: codec.Encoder,

    // Message buffering - using managed ArrayLists
    read_buffer: std.ArrayListUnmanaged(u8),
    pending_messages: std.ArrayListUnmanaged(codec.DecodedMessage),

    // Background reader thread
    reader_thread: ?std.Thread,
    reader_running: std.atomic.Value(bool),
    message_mutex: std.Thread.Mutex,

    pub const Error = error{
        AgentNotRunning,
        WriteError,
        ReadError,
        DecodeError,
    } || Allocator.Error;

    /// Create a new transport for an agent process
    pub fn init(allocator: Allocator, agent: *process.AgentProcess) Allocator.Error!*StdioTransport {
        const self = try allocator.create(StdioTransport);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .agent = agent,
            .decoder = codec.Decoder.init(allocator),
            .encoder = codec.Encoder.init(allocator),
            .read_buffer = .{},
            .pending_messages = .{},
            .reader_thread = null,
            .reader_running = std.atomic.Value(bool).init(false),
            .message_mutex = .{},
        };

        // Start background reader thread
        self.startReaderThread();

        return self;
    }

    /// Start the background reader thread
    fn startReaderThread(self: *StdioTransport) void {
        if (self.reader_thread != null) return;

        self.reader_running.store(true, .release);
        self.reader_thread = std.Thread.spawn(.{}, readerThreadFn, .{self}) catch |err| {
            std.log.err("ACP Transport: failed to spawn reader thread: {}", .{err});
            return;
        };
    }

    /// Stop the background reader thread
    fn stopReaderThread(self: *StdioTransport) void {
        if (self.reader_thread) |thread| {
            self.reader_running.store(false, .release);
            thread.join();
            self.reader_thread = null;
        }
    }

    /// Background thread function that reads from agent stdout
    fn readerThreadFn(self: *StdioTransport) void {
        std.log.debug("ACP Transport: reader thread started", .{});

        var local_buffer: [8192]u8 = undefined;
        var line_buffer: std.ArrayListUnmanaged(u8) = .{};
        defer line_buffer.deinit(self.allocator);

        while (self.reader_running.load(.acquire)) {
            // Check if agent is still alive
            if (!self.agent.isAlive()) {
                std.log.debug("ACP Transport: agent no longer alive, stopping reader", .{});
                break;
            }

            // Poll with short timeout to allow thread to check stop flag
            const posix = std.posix;
            var fds = [_]posix.pollfd{
                .{ .fd = self.agent.stdout.handle, .events = posix.POLL.IN, .revents = 0 },
            };

            const poll_result = posix.poll(&fds, 100) catch |err| {
                std.log.debug("ACP Transport: reader poll error: {}", .{err});
                continue;
            };

            if (poll_result == 0) {
                // Periodic heartbeat log every ~5 seconds (50 x 100ms polls)
                continue;
            }

            // Check for hangup
            if (fds[0].revents & posix.POLL.HUP != 0) {
                std.log.debug("ACP Transport: reader got HUP", .{});
                break;
            }

            // Read available data
            if (fds[0].revents & posix.POLL.IN != 0) {
                const n = self.agent.stdout.read(&local_buffer) catch |err| {
                    std.log.debug("ACP Transport: reader read error: {}", .{err});
                    continue;
                };

                if (n == 0) {
                    std.log.debug("ACP Transport: reader got EOF", .{});
                    break;
                }

                std.log.debug("ACP Transport: reader got {d} bytes", .{n});

                // Append to line buffer and process complete lines
                line_buffer.appendSlice(self.allocator, local_buffer[0..n]) catch continue;
                self.processLinesFromBuffer(&line_buffer);
            }
        }

        std.log.debug("ACP Transport: reader thread exiting", .{});
    }

    /// Process complete lines from the line buffer (called from reader thread)
    fn processLinesFromBuffer(self: *StdioTransport, line_buffer: *std.ArrayListUnmanaged(u8)) void {
        while (true) {
            const newline_pos = std.mem.indexOf(u8, line_buffer.items, "\n") orelse break;

            // Extract line
            var line = line_buffer.items[0..newline_pos];
            if (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }

            if (line.len > 0) {
                // Find JSON start
                const json_start = std.mem.indexOf(u8, line, "{");
                if (json_start) |start| {
                    const json_line = line[start..];

                    // Decode and add to pending messages (with mutex)
                    const message = self.decoder.decode(json_line) catch |err| {
                        std.log.warn("ACP Transport: decode error: {}", .{err});
                        self.shiftLineBuffer(line_buffer, newline_pos + 1);
                        continue;
                    };

                    self.message_mutex.lock();
                    self.pending_messages.append(self.allocator, message) catch {};
                    std.log.debug("ACP Transport: decoded and queued message, pending count={d}", .{self.pending_messages.items.len});
                    self.message_mutex.unlock();
                }
            }

            self.shiftLineBuffer(line_buffer, newline_pos + 1);
        }
    }

    /// Remove processed bytes from line buffer
    fn shiftLineBuffer(_: *StdioTransport, buffer: *std.ArrayListUnmanaged(u8), count: usize) void {
        if (count >= buffer.items.len) {
            buffer.clearRetainingCapacity();
        } else {
            std.mem.copyForwards(u8, buffer.items[0 .. buffer.items.len - count], buffer.items[count..]);
            buffer.shrinkRetainingCapacity(buffer.items.len - count);
        }
    }

    /// Send a JSON-RPC message to the agent
    pub fn send(self: *StdioTransport, message: []const u8) Error!void {
        if (!self.agent.isAlive()) return error.AgentNotRunning;

        std.log.info("ACP Transport: send() called with {d} byte message", .{message.len});

        // Write message followed by newline in a single buffer to avoid fragmentation
        const buf = self.allocator.alloc(u8, message.len + 1) catch return error.WriteError;
        defer self.allocator.free(buf);
        @memcpy(buf[0..message.len], message);
        buf[message.len] = '\n';

        self.agent.write(buf) catch return error.WriteError;
    }

    /// Send a JSON-RPC request and return the request ID
    pub fn sendRequest(self: *StdioTransport, id: i64, method: []const u8, params_json: ?[]const u8) Error!i64 {
        const message = self.encoder.encodeRequest(id, method, params_json) catch return error.WriteError;
        defer self.allocator.free(message);
        std.log.debug("ACP Transport: sending request: {s}", .{message});
        try self.send(message);
        return id;
    }

    /// Send a JSON-RPC notification (no response expected)
    pub fn sendNotification(self: *StdioTransport, method: []const u8, params_json: ?[]const u8) Error!void {
        const message = self.encoder.encodeNotification(method, params_json) catch return error.WriteError;
        defer self.allocator.free(message);
        try self.send(message);
    }

    /// Send a JSON-RPC response
    pub fn sendResponse(self: *StdioTransport, id: codec.JsonRpcId, result_json: ?[]const u8) Error!void {
        const message = self.encoder.encodeResponse(id, result_json) catch return error.WriteError;
        defer self.allocator.free(message);
        try self.send(message);
    }

    /// Send a JSON-RPC error response
    pub fn sendErrorResponse(self: *StdioTransport, id: codec.JsonRpcId, code: i32, err_message: []const u8) Error!void {
        const message = self.encoder.encodeError(id, code, err_message) catch return error.WriteError;
        defer self.allocator.free(message);
        try self.send(message);
    }

    /// Poll for available messages (non-blocking).
    /// Background thread handles reading; this just returns queued messages.
    /// Returns slice of pending messages. Caller should process and call clearMessages().
    pub fn poll(self: *StdioTransport) Error![]codec.DecodedMessage {
        // Just return pending messages - reading happens in background thread
        self.message_mutex.lock();
        defer self.message_mutex.unlock();
        return self.pending_messages.items;
    }

    /// Clear processed messages from the queue
    pub fn clearMessages(self: *StdioTransport) void {
        self.message_mutex.lock();
        defer self.message_mutex.unlock();

        // Free any allocated data in messages
        for (self.pending_messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.pending_messages.clearRetainingCapacity();
    }

    /// Wait for a response with specific ID (blocking with timeout).
    /// Uses the background reader thread's message queue.
    pub fn waitForResponse(self: *StdioTransport, request_id: i64, timeout_ms: u64) Error!?codec.DecodedMessage {
        const start = std.time.milliTimestamp();
        var last_log: i64 = 0;

        std.log.debug("ACP Transport: waitForResponse starting for id={d}, timeout={d}ms", .{ request_id, timeout_ms });

        while (true) {
            // Check timeout
            const elapsed = std.time.milliTimestamp() - start;
            if (elapsed > @as(i64, @intCast(timeout_ms))) {
                std.log.debug("ACP Transport: waitForResponse timeout after {d}ms", .{elapsed});
                return null; // Timeout
            }

            // Log every 2 seconds
            if (elapsed - last_log > 2000) {
                self.message_mutex.lock();
                const pending_count = self.pending_messages.items.len;
                self.message_mutex.unlock();
                std.log.debug("ACP Transport: waiting for response id={d}, elapsed={d}ms, pending={d}, agent alive={}", .{ request_id, elapsed, pending_count, self.agent.isAlive() });
                last_log = elapsed;
            }

            // Check for matching response in queue (filled by background thread)
            self.message_mutex.lock();
            for (self.pending_messages.items, 0..) |msg, i| {
                switch (msg) {
                    .response => |resp| {
                        if (resp.id) |id| {
                            switch (id) {
                                .number => |int_id| {
                                    if (int_id == request_id) {
                                        std.log.debug("ACP Transport: found matching response id={d}", .{request_id});
                                        const result = self.pending_messages.orderedRemove(i);
                                        self.message_mutex.unlock();
                                        return result;
                                    }
                                },
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            }
            self.message_mutex.unlock();

            // Sleep briefly before checking again
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    pub fn deinit(self: *StdioTransport) void {
        // Stop reader thread first
        self.stopReaderThread();

        self.clearMessages();
        self.pending_messages.deinit(self.allocator);
        self.read_buffer.deinit(self.allocator);
        self.decoder.deinit();
        self.encoder.deinit();
        self.allocator.destroy(self);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "transport init and deinit" {
    const allocator = std.testing.allocator;

    // Create a simple process for testing
    var agent = try process.AgentProcess.spawn(allocator, .{
        .command = "/bin/cat",
    });
    defer agent.deinit();

    var transport = try StdioTransport.init(allocator, agent);
    defer transport.deinit();

    try std.testing.expect(transport.pending_messages.items.len == 0);
}

test "transport send message" {
    const allocator = std.testing.allocator;

    // Create cat process which echoes input
    var agent = try process.AgentProcess.spawn(allocator, .{
        .command = "/bin/cat",
    });
    defer agent.deinit();

    var transport = try StdioTransport.init(allocator, agent);
    defer transport.deinit();

    // Test that send doesn't fail
    try transport.send("{\"jsonrpc\":\"2.0\",\"method\":\"test\"}");

    // The message is written; the basic flow works.
    // Full integration testing of receiving would require
    // more complex async handling.
}
