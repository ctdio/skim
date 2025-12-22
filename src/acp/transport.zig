const std = @import("std");
const Allocator = std.mem.Allocator;
const process = @import("process.zig");
const codec = @import("codec.zig");

// =============================================================================
// Stdio Transport
// =============================================================================

/// Manages JSON-RPC communication over stdio with an agent process
pub const StdioTransport = struct {
    allocator: Allocator,
    agent: *process.AgentProcess,
    decoder: codec.Decoder,
    encoder: codec.Encoder,

    // Message buffering - using managed ArrayLists
    read_buffer: std.ArrayListUnmanaged(u8),
    pending_messages: std.ArrayListUnmanaged(codec.DecodedMessage),

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
        };

        return self;
    }

    /// Send a JSON-RPC message to the agent
    pub fn send(self: *StdioTransport, message: []const u8) Error!void {
        if (!self.agent.isAlive()) return error.AgentNotRunning;

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

    /// Poll for available messages (non-blocking)
    /// Returns slice of pending messages. Caller should process and call clearMessages().
    pub fn poll(self: *StdioTransport) Error![]codec.DecodedMessage {
        // Check stderr for any error messages
        self.agent.checkStderr();

        // Read available data from agent stdout
        var temp_buffer: [8192]u8 = undefined;

        while (true) {
            const data = self.agent.readAvailable(&temp_buffer) catch |err| {
                if (err == error.WouldBlock) break;
                std.log.debug("ACP Transport: poll read error: {}", .{err});
                return error.ReadError;
            };

            if (data == null) break; // No data available

            if (data.?.len == 0) {
                // EOF - agent closed stdout
                std.log.debug("ACP Transport: EOF on agent stdout", .{});
                break;
            }

            // Append to read buffer
            std.log.debug("ACP Transport: received {d} bytes", .{data.?.len});
            self.read_buffer.appendSlice(self.allocator, data.?) catch return error.ReadError;
        }

        // Process complete lines from buffer
        try self.processBuffer();

        return self.pending_messages.items;
    }

    /// Clear processed messages from the queue
    pub fn clearMessages(self: *StdioTransport) void {
        // Free any allocated data in messages
        for (self.pending_messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.pending_messages.clearRetainingCapacity();
    }

    /// Wait for a response with specific ID (blocking with timeout)
    pub fn waitForResponse(self: *StdioTransport, request_id: i64, timeout_ms: u64) Error!?codec.DecodedMessage {
        const start = std.time.milliTimestamp();
        var last_log: i64 = 0;
        const posix = std.posix;

        std.log.debug("ACP Transport: waitForResponse starting for id={d}, timeout={d}ms", .{ request_id, timeout_ms });
        std.log.debug("ACP Transport: stdout handle={d}", .{self.agent.stdout.handle});

        while (true) {
            // Check timeout
            const elapsed = std.time.milliTimestamp() - start;
            if (elapsed > @as(i64, @intCast(timeout_ms))) {
                std.log.debug("ACP Transport: waitForResponse timeout after {d}ms", .{elapsed});
                return null; // Timeout
            }

            // Log every 2 seconds
            if (elapsed - last_log > 2000) {
                std.log.debug("ACP Transport: waiting for response id={d}, elapsed={d}ms, pending={d}, agent alive={}", .{ request_id, elapsed, self.pending_messages.items.len, self.agent.isAlive() });
                last_log = elapsed;
            }

            // Poll BOTH stdout and stderr - if stderr fills up, process blocks!
            const stdout_fd = self.agent.stdout.handle;
            const stderr_fd = if (self.agent.stderr) |se| se.handle else -1;
            var fds = [_]posix.pollfd{
                .{ .fd = stdout_fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = stderr_fd, .events = posix.POLL.IN, .revents = 0 },
            };

            const poll_result = posix.poll(&fds, 500) catch |err| {
                std.log.debug("ACP Transport: poll error: {}", .{err});
                continue;
            };

            if (poll_result == 0) {
                std.log.debug("ACP Transport: poll timeout on fd={d} (fd valid)", .{stdout_fd});
            }

            // Drain stderr first to prevent blocking
            if (poll_result > 0 and stderr_fd != -1 and (fds[1].revents & posix.POLL.IN) != 0) {
                var stderr_buf: [4096]u8 = undefined;
                const stderr_file = self.agent.stderr.?;
                const n = stderr_file.read(&stderr_buf) catch 0;
                if (n > 0) {
                    std.log.debug("ACP Transport: stderr: {s}", .{stderr_buf[0..n]});
                }
            }

            // Check stdout
            if (poll_result > 0 and (fds[0].revents & posix.POLL.IN) != 0) {
                var temp_buffer: [8192]u8 = undefined;
                const n = self.agent.stdout.read(&temp_buffer) catch |err| {
                    std.log.debug("ACP Transport: read error: {}", .{err});
                    continue;
                };

                if (n > 0) {
                    std.log.debug("ACP Transport: read {d} bytes", .{n});
                    self.read_buffer.appendSlice(self.allocator, temp_buffer[0..n]) catch return error.ReadError;

                    // Process the buffer
                    try self.processBuffer();

                    // Check for matching response
                    for (self.pending_messages.items, 0..) |msg, i| {
                        switch (msg) {
                            .response => |resp| {
                                if (resp.id) |id| {
                                    switch (id) {
                                        .number => |int_id| {
                                            if (int_id == request_id) {
                                                std.log.debug("ACP Transport: found matching response id={d}", .{request_id});
                                                const result = self.pending_messages.orderedRemove(i);
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
                }
            }

            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    /// Process buffer to extract complete JSON-RPC messages
    /// Handles PTY echo pollution from 'script' wrapper by finding JSON within lines
    fn processBuffer(self: *StdioTransport) Error!void {
        while (true) {
            // Find newline delimiter
            const newline_pos = std.mem.indexOf(u8, self.read_buffer.items, "\n");
            if (newline_pos == null) break;

            // Extract complete line, trimming any trailing \r (CRLF from PTY)
            var line = self.read_buffer.items[0..newline_pos.?];
            if (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }

            // Skip empty lines
            if (line.len > 0) {
                // Find JSON object start - script may prefix with stderr output
                const json_start = std.mem.indexOf(u8, line, "{");
                if (json_start == null) {
                    // No JSON in this line - skip it (likely pure stderr output)
                    std.log.debug("ACP Transport: skipping non-JSON line: {s}", .{line[0..@min(line.len, 100)]});
                    self.shiftBuffer(newline_pos.? + 1);
                    continue;
                }

                const json_line = line[json_start.?..];
                if (json_start.? > 0) {
                    std.log.debug("ACP Transport: found JSON at offset {d}, prefix: {s}", .{ json_start.?, line[0..json_start.?] });
                }
                std.log.debug("ACP Transport: processing JSON ({d} bytes): {s}", .{ json_line.len, json_line[0..@min(json_line.len, 200)] });

                // Decode JSON-RPC message
                const message = self.decoder.decode(json_line) catch |err| {
                    std.log.warn("Failed to decode message: {} - skipping", .{err});
                    // Skip malformed message
                    self.shiftBuffer(newline_pos.? + 1);
                    continue;
                };
                std.log.debug("ACP Transport: decoded message type", .{});
                self.pending_messages.append(self.allocator, message) catch return error.ReadError;
            }

            // Remove processed line from buffer
            self.shiftBuffer(newline_pos.? + 1);
        }
    }

    /// Remove processed bytes from the beginning of read buffer
    fn shiftBuffer(self: *StdioTransport, count: usize) void {
        if (count >= self.read_buffer.items.len) {
            self.read_buffer.clearRetainingCapacity();
        } else {
            std.mem.copyForwards(
                u8,
                self.read_buffer.items[0 .. self.read_buffer.items.len - count],
                self.read_buffer.items[count..],
            );
            self.read_buffer.shrinkRetainingCapacity(self.read_buffer.items.len - count);
        }
    }

    pub fn deinit(self: *StdioTransport) void {
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
