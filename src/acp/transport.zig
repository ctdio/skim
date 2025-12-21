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

        // Write message followed by newline
        self.agent.write(message) catch return error.WriteError;
        self.agent.write("\n") catch return error.WriteError;
    }

    /// Send a JSON-RPC request and return the request ID
    pub fn sendRequest(self: *StdioTransport, id: i64, method: []const u8, params_json: ?[]const u8) Error!i64 {
        const message = self.encoder.encodeRequest(id, method, params_json) catch return error.WriteError;
        defer self.allocator.free(message);
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
        // Read available data from agent stdout
        var temp_buffer: [8192]u8 = undefined;

        while (true) {
            const data = self.agent.readAvailable(&temp_buffer) catch |err| {
                if (err == error.WouldBlock) break;
                return error.ReadError;
            };

            if (data == null) break; // No data available

            if (data.?.len == 0) {
                // EOF - agent closed stdout
                break;
            }

            // Append to read buffer
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

        while (true) {
            // Check timeout
            const elapsed = std.time.milliTimestamp() - start;
            if (elapsed > @as(i64, @intCast(timeout_ms))) {
                return null; // Timeout
            }

            // Poll for messages
            const messages = try self.poll();

            // Look for response with matching ID
            for (messages, 0..) |msg, i| {
                switch (msg) {
                    .response => |resp| {
                        if (resp.id) |id| {
                            switch (id) {
                                .number => |int_id| {
                                    if (int_id == request_id) {
                                        // Found matching response - remove from queue
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

            // Brief sleep before next poll
            std.time.sleep(1 * std.time.ns_per_ms);
        }
    }

    /// Process buffer to extract complete JSON-RPC messages
    fn processBuffer(self: *StdioTransport) Error!void {
        while (true) {
            // Find newline delimiter
            const newline_pos = std.mem.indexOf(u8, self.read_buffer.items, "\n");
            if (newline_pos == null) break;

            // Extract complete line
            const line = self.read_buffer.items[0..newline_pos.?];

            // Skip empty lines
            if (line.len > 0) {
                // Decode JSON-RPC message
                const message = self.decoder.decode(line) catch |err| {
                    std.log.warn("Failed to decode message: {} - skipping", .{err});
                    // Skip malformed message
                    self.shiftBuffer(newline_pos.? + 1);
                    continue;
                };
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
