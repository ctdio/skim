const std = @import("std");
const Allocator = std.mem.Allocator;
const process = @import("process.zig");
const codec = @import("codec.zig");

// ACP protocol logging (opt-in via ACP_DEBUG=1 environment variable)
var acp_log_file: ?std.fs.File = null;
var acp_log_initialized: bool = false;
var acp_log_mutex: std.Thread.Mutex = .{};

fn initAcpLog() void {
    if (acp_log_initialized) return;
    acp_log_initialized = true;

    // Only enable if ACP_DEBUG environment variable is set
    const debug_env = std.posix.getenv("ACP_DEBUG") orelse return;
    if (debug_env.len == 0 or std.mem.eql(u8, debug_env, "0")) return;

    const home = std.posix.getenv("HOME") orelse return;

    // Ensure ~/.skim/ exists
    var path_buf: [512]u8 = undefined;
    const skim_dir = std.fmt.bufPrint(&path_buf, "{s}/.skim", .{home}) catch return;
    std.fs.makeDirAbsolute(skim_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return,
    };

    const log_path = std.fmt.bufPrint(&path_buf, "{s}/.skim/acp.log", .{home}) catch return;
    acp_log_file = std.fs.createFileAbsolute(log_path, .{ .truncate = false }) catch return;
    if (acp_log_file) |f| {
        f.seekFromEnd(0) catch {};
    }
}

fn logAcpMessage(direction: []const u8, message: []const u8) void {
    acp_log_mutex.lock();
    defer acp_log_mutex.unlock();

    initAcpLog();

    const file = acp_log_file orelse return;

    // Get timestamp
    const timestamp = std.time.timestamp();
    const hours = @mod(@divFloor(timestamp, 3600), 24);
    const minutes = @mod(@divFloor(timestamp, 60), 60);
    const seconds = @mod(timestamp, 60);

    // Write log entry: [HH:MM:SS] >>> message (for outgoing)
    //                  [HH:MM:SS] <<< message (for incoming)
    var buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&buf, "[{d:0>2}:{d:0>2}:{d:0>2}] {s} ", .{
        @as(u64, @intCast(hours)),
        @as(u64, @intCast(minutes)),
        @as(u64, @intCast(seconds)),
        direction,
    }) catch return;

    _ = file.write(header) catch return;
    _ = file.write(message) catch return;
    _ = file.write("\n") catch return;
}

// =============================================================================
// Stdio Transport
// =============================================================================

/// Callback for processing messages in the background reader thread.
/// This allows heavy parsing (like session/update JSON) to happen off the main thread.
/// The callback receives the decoded message and should return true if it handled
/// the message (preventing it from being added to pending_messages).
pub const MessageCallback = *const fn (message: codec.DecodedMessage, ctx: ?*anyopaque) bool;

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

    // Optional callback for processing messages in background thread
    message_callback: ?MessageCallback,
    message_callback_ctx: ?*anyopaque,

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
            .message_callback = null,
            .message_callback_ctx = null,
        };

        // Start background reader thread
        self.startReaderThread();

        return self;
    }

    /// Set a callback to process messages in the background reader thread.
    /// The callback is invoked for each decoded message BEFORE it's added to the queue.
    /// If the callback returns true, the message is considered handled and won't be queued.
    /// This is useful for offloading heavy parsing (like session/update) from the main thread.
    pub fn setMessageCallback(self: *StdioTransport, callback: MessageCallback, ctx: ?*anyopaque) void {
        self.message_callback = callback;
        self.message_callback_ctx = ctx;
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
        // Reader thread started - runs until agent exits

        var local_buffer: [8192]u8 = undefined;
        var line_buffer: std.ArrayListUnmanaged(u8) = .{};
        defer line_buffer.deinit(self.allocator);

        while (self.reader_running.load(.acquire)) {
            // Check if agent is still alive
            if (!self.agent.isAlive()) {
                break;
            }

            // Poll with short timeout to allow thread to check stop flag
            const posix = std.posix;
            var fds = [_]posix.pollfd{
                .{ .fd = self.agent.stdout.handle, .events = posix.POLL.IN, .revents = 0 },
            };

            const poll_result = posix.poll(&fds, 100) catch {
                continue;
            };

            if (poll_result == 0) {
                // Periodic heartbeat log every ~5 seconds (50 x 100ms polls)
                continue;
            }

            // Check for hangup
            if (fds[0].revents & posix.POLL.HUP != 0) {
                break;
            }

            // Read available data
            if (fds[0].revents & posix.POLL.IN != 0) {
                const n = self.agent.stdout.read(&local_buffer) catch {
                    continue;
                };

                if (n == 0) {
                    break;
                }

                // Append to line buffer and process complete lines
                line_buffer.appendSlice(self.allocator, local_buffer[0..n]) catch continue;
                self.processLinesFromBuffer(&line_buffer);
            }
        }
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

                    // Log incoming message (opt-in via ACP_DEBUG=1)
                    logAcpMessage("<<<", json_line);

                    // Decode message
                    var message = self.decoder.decode(json_line) catch |err| {
                        std.log.warn("ACP Transport: decode error: {}", .{err});
                        self.shiftLineBuffer(line_buffer, newline_pos + 1);
                        continue;
                    };

                    // If callback is set, let it process the message first
                    // This allows heavy parsing to happen in this background thread
                    var handled = false;
                    if (self.message_callback) |callback| {
                        handled = callback(message, self.message_callback_ctx);
                    }

                    // Only queue the message if callback didn't handle it
                    if (!handled) {
                        self.message_mutex.lock();
                        self.pending_messages.append(self.allocator, message) catch {};
                        self.message_mutex.unlock();
                    } else {
                        message.deinit(self.allocator);
                    }
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

        // Log outgoing message (opt-in via ACP_DEBUG=1)
        logAcpMessage(">>>", message);

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
    /// Returns owned slice of messages - caller must call freeMessages() after processing.
    /// This method moves messages out of the queue atomically, so the reader thread
    /// can continue appending without affecting the returned slice.
    pub fn poll(self: *StdioTransport) Error![]codec.DecodedMessage {
        self.message_mutex.lock();
        defer self.message_mutex.unlock();

        if (self.pending_messages.items.len == 0) {
            return &[_]codec.DecodedMessage{};
        }

        // Take ownership of the items by copying to a new allocation
        // This ensures the reader thread won't overwrite our data
        const items = self.allocator.dupe(codec.DecodedMessage, self.pending_messages.items) catch {
            return &[_]codec.DecodedMessage{};
        };

        // Clear the list so reader thread starts fresh
        self.pending_messages.clearRetainingCapacity();

        return items;
    }

    /// Clear processed messages (no-op, kept for API compatibility).
    /// Caller should use freeMessages() instead.
    pub fn clearMessages(self: *StdioTransport) void {
        _ = self;
        // No-op - messages are now owned by caller after poll()
    }

    /// Free a slice of messages returned by poll()
    pub fn freeMessages(self: *StdioTransport, messages: []codec.DecodedMessage) void {
        if (messages.len == 0) return;
        for (messages) |*msg| {
            msg.deinit(self.allocator);
        }
        self.allocator.free(messages);
    }

    /// Wait for a response with specific ID (blocking with timeout).
    /// Uses the background reader thread's message queue.
    pub fn waitForResponse(self: *StdioTransport, request_id: i64, timeout_ms: u64) Error!?codec.DecodedMessage {
        const start = std.time.milliTimestamp();

        while (true) {
            // Check timeout
            const elapsed = std.time.milliTimestamp() - start;
            if (elapsed > @as(i64, @intCast(timeout_ms))) {
                return null; // Timeout
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

        // Free any remaining messages in the queue
        self.message_mutex.lock();
        for (self.pending_messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.message_mutex.unlock();

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
