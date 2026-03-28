const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const process_mod = @import("process.zig");
const codec = @import("codec.zig");

// =============================================================================
// Stdio Transport
// =============================================================================

/// Bidirectional stdio transport for the Codex app-server protocol.
/// Uses a background reader thread to asynchronously read JSON-RPC messages
/// from the process stdout, decode them, and queue them for consumption.
pub const StdioTransport = struct {
    allocator: Allocator,
    process: *process_mod.CodexProcess,
    decoder: codec.Decoder,

    // Thread-safe message queue
    pending_messages: std.ArrayListUnmanaged(codec.DecodedMessage),
    message_mutex: std.Thread.Mutex,

    // Background reader thread
    reader_thread: ?std.Thread,
    reader_running: std.atomic.Value(bool),

    pub const Error = error{
        ProcessNotRunning,
        WriteError,
    } || Allocator.Error;

    /// Create a new transport for a Codex process.
    /// Does NOT start the background reader -- call startReader() separately.
    pub fn init(allocator: Allocator, proc: *process_mod.CodexProcess) Allocator.Error!*StdioTransport {
        const self = try allocator.create(StdioTransport);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .process = proc,
            .decoder = codec.Decoder.init(allocator),
            .pending_messages = .{},
            .message_mutex = .{},
            .reader_thread = null,
            .reader_running = std.atomic.Value(bool).init(false),
        };

        return self;
    }

    /// Start the background reader thread that reads from process stdout
    pub fn startReader(self: *StdioTransport) void {
        if (self.reader_thread != null) return;

        self.reader_running.store(true, .release);
        self.reader_thread = std.Thread.spawn(.{}, readerThreadFn, .{self}) catch |err| {
            std.log.err("Codex Transport: failed to spawn reader thread: {}", .{err});
            return;
        };
    }

    /// Stop the background reader thread and wait for it to finish
    pub fn stopReader(self: *StdioTransport) void {
        if (self.reader_thread) |thread| {
            self.reader_running.store(false, .release);
            thread.join();
            self.reader_thread = null;
        }
    }

    /// Send a message to the codex process (message + newline).
    /// The message should be a complete JSON string without trailing newline.
    pub fn send(self: *StdioTransport, message: []const u8) Error!void {
        if (!self.process.isAlive()) return error.ProcessNotRunning;

        // Combine message + newline into a single write to avoid fragmentation
        const buf = self.allocator.alloc(u8, message.len + 1) catch return error.WriteError;
        defer self.allocator.free(buf);
        @memcpy(buf[0..message.len], message);
        buf[message.len] = '\n';

        self.process.write(buf) catch return error.WriteError;
    }

    /// Take all pending messages from the queue.
    /// Returns an owned slice -- caller must call freeMessages() after processing.
    pub fn drainMessages(self: *StdioTransport) Allocator.Error![]codec.DecodedMessage {
        self.message_mutex.lock();
        defer self.message_mutex.unlock();

        if (self.pending_messages.items.len == 0) {
            return &[_]codec.DecodedMessage{};
        }

        const items = try self.allocator.dupe(codec.DecodedMessage, self.pending_messages.items);
        self.pending_messages.clearRetainingCapacity();
        return items;
    }

    /// Return the number of queued messages waiting to be drained.
    pub fn pendingMessageCount(self: *StdioTransport) usize {
        self.message_mutex.lock();
        defer self.message_mutex.unlock();
        return self.pending_messages.items.len;
    }

    /// Free a slice of messages returned by drainMessages()
    pub fn freeMessages(self: *StdioTransport, messages: []codec.DecodedMessage) void {
        if (messages.len == 0) return;
        for (messages) |*msg| {
            msg.deinit(self.allocator);
        }
        self.allocator.free(messages);
    }

    pub fn deinit(self: *StdioTransport) void {
        self.stopReader();

        // Free any remaining messages in the queue
        self.message_mutex.lock();
        for (self.pending_messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.message_mutex.unlock();

        self.pending_messages.deinit(self.allocator);
        self.decoder.deinit();
        self.allocator.destroy(self);
    }

    // -------------------------------------------------------------------------
    // Background reader thread
    // -------------------------------------------------------------------------

    fn readerThreadFn(self: *StdioTransport) void {
        var local_buffer: [8192]u8 = undefined;
        var line_buffer: std.ArrayListUnmanaged(u8) = .{};
        defer line_buffer.deinit(self.allocator);

        while (self.reader_running.load(.acquire)) {
            if (!self.process.isAlive()) break;

            // Poll stdout with 100ms timeout to allow checking stop flag
            var fds = [_]posix.pollfd{
                .{ .fd = self.process.stdout.handle, .events = posix.POLL.IN, .revents = 0 },
            };

            const poll_result = posix.poll(&fds, 100) catch continue;

            if (poll_result == 0) continue;

            // Check for hangup (process exited)
            if (fds[0].revents & posix.POLL.HUP != 0) break;

            // Read available data
            if (fds[0].revents & posix.POLL.IN != 0) {
                const n = self.process.stdout.read(&local_buffer) catch continue;
                if (n == 0) break;

                // Append to line buffer and process complete lines
                line_buffer.appendSlice(self.allocator, local_buffer[0..n]) catch continue;
                self.processLines(&line_buffer);
            }
        }
    }

    /// Extract complete lines from the buffer and decode them as JSON-RPC messages
    fn processLines(self: *StdioTransport, line_buffer: *std.ArrayListUnmanaged(u8)) void {
        while (true) {
            const newline_pos = std.mem.indexOf(u8, line_buffer.items, "\n") orelse break;

            var line = line_buffer.items[0..newline_pos];
            if (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }

            if (line.len > 0) {
                // Find JSON start (skip any non-JSON prefix)
                const json_start = std.mem.indexOf(u8, line, "{");
                if (json_start) |start| {
                    const json_line = line[start..];

                    const message = self.decoder.decode(json_line) catch {
                        shiftBuffer(line_buffer, newline_pos + 1);
                        continue;
                    };

                    self.message_mutex.lock();
                    self.pending_messages.append(self.allocator, message) catch {};
                    self.message_mutex.unlock();
                }
            }

            shiftBuffer(line_buffer, newline_pos + 1);
        }
    }
};

// =============================================================================
// Helpers
// =============================================================================

/// Remove processed bytes from the front of a buffer
fn shiftBuffer(buffer: *std.ArrayListUnmanaged(u8), count: usize) void {
    if (count >= buffer.items.len) {
        buffer.clearRetainingCapacity();
    } else {
        std.mem.copyForwards(u8, buffer.items[0 .. buffer.items.len - count], buffer.items[count..]);
        buffer.shrinkRetainingCapacity(buffer.items.len - count);
    }
}

// =============================================================================
// Tests
// =============================================================================

test "transport init and deinit" {
    const allocator = std.testing.allocator;

    var proc = try process_mod.CodexProcess.spawnRaw(allocator, &.{"/bin/cat"});
    defer proc.deinit();

    var transport = try StdioTransport.init(allocator, proc);
    defer transport.deinit();

    try std.testing.expectEqual(@as(usize, 0), transport.pending_messages.items.len);
}

test "transport send message" {
    const allocator = std.testing.allocator;

    var proc = try process_mod.CodexProcess.spawnRaw(allocator, &.{"/bin/cat"});
    defer proc.deinit();

    var transport = try StdioTransport.init(allocator, proc);
    defer transport.deinit();

    try transport.send("{\"method\":\"test\"}");
}

test "transport reader receives echoed json" {
    const allocator = std.testing.allocator;

    // cat echoes stdin to stdout, so we can send JSON and receive it back
    var proc = try process_mod.CodexProcess.spawnRaw(allocator, &.{"/bin/cat"});
    defer proc.deinit();

    var transport = try StdioTransport.init(allocator, proc);
    defer transport.deinit();

    transport.startReader();

    // Send a valid JSON-RPC notification (no id, has method)
    try transport.send("{\"method\":\"test/notification\",\"params\":{\"data\":\"hello\"}}");

    // Wait briefly for the reader thread to process the echo
    std.Thread.sleep(200 * std.time.ns_per_ms);

    const messages = try transport.drainMessages();
    defer transport.freeMessages(messages);

    try std.testing.expect(messages.len > 0);
    try std.testing.expect(messages[0] == .notification);
    try std.testing.expectEqualStrings("test/notification", messages[0].notification.method);
}

test "transport drainMessages returns empty when no messages" {
    const allocator = std.testing.allocator;

    var proc = try process_mod.CodexProcess.spawnRaw(allocator, &.{"/bin/cat"});
    defer proc.deinit();

    var transport = try StdioTransport.init(allocator, proc);
    defer transport.deinit();

    const messages = try transport.drainMessages();
    try std.testing.expectEqual(@as(usize, 0), messages.len);
}
