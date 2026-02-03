const std = @import("std");
const Allocator = std.mem.Allocator;
const client_mod = @import("client.zig");
const protocol = @import("protocol.zig");
const sse = @import("sse.zig");
const server = @import("server.zig");

// =============================================================================
// Opencode Manager
// =============================================================================
//
// Session lifecycle management for Opencode AI agents.
// Mirrors the AcpManager pattern for consistent integration.
//
// Architecture:
// - Manager owns server process lifecycle
// - SSE reader thread pushes events to MessageQueue
// - Main thread polls for events via poll()
//
// =============================================================================

const log = std.log.scoped(.opencode);

/// Manager status enum - tracks connection state
pub const Status = enum {
    idle,
    starting_server,
    connecting,
    session_active,
    prompting,
    disconnected,
    failed,
};

/// Event types from the SSE stream
pub const Event = union(enum) {
    /// Delta text chunk from message.part.updated
    message_chunk: MessageChunk,
    /// Message complete (session.idle)
    message_complete: void,
    /// Status changed
    status_change: Status,
    /// Error occurred
    err: EventError,

    pub const MessageChunk = struct {
        delta: []const u8,

        pub fn deinit(self: *MessageChunk, allocator: Allocator) void {
            allocator.free(self.delta);
        }
    };

    pub const EventError = struct {
        code: ErrorCode,
        message: ?[]const u8 = null,

        pub const ErrorCode = enum {
            connection_failed,
            parse_error,
            server_error,
            session_error,
        };

        pub fn deinit(self: *EventError, allocator: Allocator) void {
            if (self.message) |m| allocator.free(m);
        }
    };

    pub fn deinit(self: *Event, allocator: Allocator) void {
        switch (self.*) {
            .message_chunk => |*chunk| chunk.deinit(allocator),
            .err => |*e| e.deinit(allocator),
            .message_complete, .status_change => {},
        }
    }
};

/// Thread-safe message queue for SSE thread -> main thread communication
pub const MessageQueue = struct {
    mutex: std.Thread.Mutex = .{},
    events: std.ArrayList(Event),
    allocator: Allocator,

    pub fn init(allocator: Allocator) MessageQueue {
        return .{
            .events = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MessageQueue) void {
        // Free any remaining events
        for (self.events.items) |*event| {
            event.deinit(self.allocator);
        }
        self.events.deinit(self.allocator);
    }

    /// Push an event to the queue (thread-safe)
    pub fn push(self: *MessageQueue, event: Event) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.events.append(self.allocator, event) catch {
            // If append fails, clean up the event
            var e = event;
            e.deinit(self.allocator);
        };
    }

    /// Pop an event from the queue (thread-safe)
    /// Returns null if queue is empty
    pub fn pop(self: *MessageQueue) ?Event {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }

    /// Get the number of pending events (thread-safe)
    pub fn len(self: *MessageQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.events.items.len;
    }
};

/// Configuration for connecting to opencode
pub const ConnectConfig = struct {
    /// Path to opencode executable
    opencode_path: []const u8,
    /// Port to connect on (or spawn server on)
    port: u16 = 4096,
    /// Working directory
    cwd: ?[]const u8 = null,
    /// Whether to spawn the server (vs connecting to existing)
    spawn_server: bool = true,
    /// Health check timeout in milliseconds
    health_timeout_ms: u64 = 30000,
};

/// Manages Opencode agent sessions
pub const OpencodeManager = struct {
    allocator: Allocator,
    status: Status,
    client: ?*client_mod.Client,
    server_process: ?std.process.Child,
    session_id: ?[]const u8,
    message_queue: MessageQueue,

    // SSE reader thread
    sse_thread: ?std.Thread,
    should_stop: std.atomic.Value(bool),

    // Connection config (stored for reconnection)
    connect_config: ?ConnectConfig,
    base_url: ?[]const u8,

    pub fn init(allocator: Allocator) OpencodeManager {
        return .{
            .allocator = allocator,
            .status = .idle,
            .client = null,
            .server_process = null,
            .session_id = null,
            .message_queue = MessageQueue.init(allocator),
            .sse_thread = null,
            .should_stop = std.atomic.Value(bool).init(false),
            .connect_config = null,
            .base_url = null,
        };
    }

    pub fn deinit(self: *OpencodeManager) void {
        self.disconnect();
        self.message_queue.deinit();
    }

    /// Connect to an opencode server (spawning if configured)
    pub fn connect(self: *OpencodeManager, config: ConnectConfig) !void {
        if (self.status != .idle and self.status != .disconnected and self.status != .failed) {
            return error.AlreadyConnected;
        }

        // Store config for potential reconnection
        self.connect_config = config;

        // Build base URL
        const base_url = try std.fmt.allocPrint(self.allocator, "http://localhost:{d}", .{config.port});
        errdefer self.allocator.free(base_url);
        self.base_url = base_url;

        // Spawn server if requested
        if (config.spawn_server) {
            self.status = .starting_server;
            log.info("Starting opencode server...", .{});

            // Get log file path
            const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch null;
            defer if (home) |h| self.allocator.free(h);

            const log_file = if (home) |h|
                std.fmt.allocPrint(self.allocator, "{s}/.skim/opencode-server.log", .{h}) catch null
            else
                null;
            defer if (log_file) |f| self.allocator.free(f);

            const server_config = server.ServerConfig{
                .opencode_path = config.opencode_path,
                .port = config.port,
                .cwd = config.cwd,
                .log_file = log_file,
            };

            self.server_process = server.spawnServer(self.allocator, server_config) catch |err| {
                log.err("Failed to spawn server: {}", .{err});
                self.status = .failed;
                return error.SpawnFailed;
            };
        }

        // Connect to server
        self.status = .connecting;
        log.info("Connecting to opencode at {s}...", .{base_url});

        // Create client
        const client_ptr = try self.allocator.create(client_mod.Client);
        errdefer self.allocator.destroy(client_ptr);

        client_ptr.* = try client_mod.Client.init(self.allocator, base_url);
        self.client = client_ptr;

        // Wait for health
        server.waitForHealth(client_ptr, config.health_timeout_ms) catch |err| {
            log.err("Health check failed: {}", .{err});
            self.status = .failed;
            return error.HealthCheckFailed;
        };

        // Create session
        const session_id = client_ptr.createSession() catch |err| {
            log.err("Failed to create session: {}", .{err});
            self.status = .failed;
            return error.SessionFailed;
        };

        self.session_id = try self.allocator.dupe(u8, session_id);
        self.allocator.free(session_id);

        log.info("Session created: {s}", .{self.session_id.?});

        // Start SSE reader thread
        self.should_stop.store(false, .release);
        self.sse_thread = std.Thread.spawn(.{}, sseReaderThread, .{self}) catch |err| {
            log.err("Failed to spawn SSE reader thread: {}", .{err});
            self.status = .failed;
            return error.ThreadSpawnFailed;
        };

        self.status = .session_active;
        log.info("Connected successfully", .{});
    }

    /// Disconnect from the server
    pub fn disconnect(self: *OpencodeManager) void {
        log.info("Disconnecting...", .{});

        // Signal SSE thread to stop
        self.should_stop.store(true, .release);

        // Terminate server FIRST - this will close the SSE connection and unblock the reader thread
        if (self.server_process) |*proc| {
            server.terminateServer(proc);
            self.server_process = null;
        }

        // Now join SSE thread (should exit quickly since connection is closed)
        if (self.sse_thread) |thread| {
            thread.join();
            self.sse_thread = null;
        }

        // Clean up session
        if (self.session_id) |sid| {
            // Note: Session cleanup is handled by server termination.
            // The deleteSession API uses HTTP DELETE which may not work correctly
            // in all Zig versions, so we rely on server shutdown instead.
            self.allocator.free(sid);
            self.session_id = null;
        }

        // Clean up client
        if (self.client) |c| {
            c.deinit();
            self.allocator.destroy(c);
            self.client = null;
        }

        // Clean up URL
        if (self.base_url) |url| {
            self.allocator.free(url);
            self.base_url = null;
        }

        self.status = .disconnected;
        log.info("Disconnected", .{});
    }

    /// Send a prompt to the agent
    pub fn sendPrompt(self: *OpencodeManager, text: []const u8) !void {
        const c = self.client orelse return error.NotConnected;
        const sid = self.session_id orelse return error.NoSession;

        if (self.status != .session_active) {
            return error.InvalidState;
        }

        // Create prompt request
        const prompt = try protocol.createTextPrompt(self.allocator, text);
        defer self.allocator.free(prompt.parts);

        // Send async
        try c.sendPromptAsync(sid, prompt);

        self.status = .prompting;
        log.info("Sent prompt", .{});
    }

    /// Poll for events from the SSE stream
    /// Returns the next event or null if none available
    pub fn poll(self: *OpencodeManager) ?Event {
        return self.message_queue.pop();
    }

    /// Check if manager has pending events
    pub fn hasPendingEvents(self: *OpencodeManager) bool {
        return self.message_queue.len() > 0;
    }

    /// SSE reader thread function
    fn sseReaderThread(manager: *OpencodeManager) void {
        log.info("SSE reader thread started", .{});

        const c = manager.client orelse {
            manager.message_queue.push(.{ .err = .{ .code = .connection_failed } });
            return;
        };

        const conn = c.connectEventStream() catch {
            manager.message_queue.push(.{ .err = .{ .code = .connection_failed } });
            return;
        };
        defer conn.deinit();

        while (!manager.should_stop.load(.acquire)) {
            // Try to read an event
            const event_opt = conn.readEvent() catch |err| {
                log.err("SSE read error: {}", .{err});
                manager.message_queue.push(.{ .err = .{ .code = .connection_failed } });
                break;
            };

            if (event_opt) |sse_event| {
                var e = sse_event;
                defer e.deinit(manager.allocator);

                // Parse the SSE event data
                if (e.data) |data| {
                    manager.processEventData(data);
                }
            } else {
                // No event yet, brief sleep to avoid busy loop
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
        }

        log.info("SSE reader thread exiting", .{});
    }

    /// Process SSE event data JSON
    fn processEventData(self: *OpencodeManager, data: []const u8) void {
        // Quick check for events we care about before full JSON parse
        // This avoids expensive parsing for the many session/message update events
        const dominated_events = [_][]const u8{
            "message.part.updated",
            "session.idle",
            "session.error",
        };
        var dominated = false;
        for (dominated_events) |evt| {
            if (std.mem.indexOf(u8, data, evt) != null) {
                dominated = true;
                break;
            }
        }
        if (!dominated) {
            // Skip parsing events we don't handle
            return;
        }

        // Parse JSON - opencode wraps events in a "payload" object
        const parsed = std.json.parseFromSlice(struct {
            payload: struct {
                type: []const u8,
                properties: ?std.json.Value = null,
            },
        }, self.allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch {
            log.warn("Failed to parse SSE event JSON", .{});
            return;
        };
        defer parsed.deinit();

        const event_type = protocol.EventType.fromString(parsed.value.payload.type);
        log.debug("SSE event received: {s} -> {}", .{ parsed.value.payload.type, event_type });

        switch (event_type) {
            .message_part_updated => {
                // Extract delta from properties
                if (parsed.value.payload.properties) |props| {
                    if (props == .object) {
                        if (props.object.get("delta")) |delta_val| {
                            if (delta_val == .string) {
                                const delta = self.allocator.dupe(u8, delta_val.string) catch return;
                                self.message_queue.push(.{
                                    .message_chunk = .{ .delta = delta },
                                });
                            }
                        }
                    }
                }
            },
            .session_idle => {
                log.info("Session idle received, resetting status to session_active", .{});
                self.message_queue.push(.{ .message_complete = {} });
                // Update status back to session_active
                self.status = .session_active;
            },
            .session_error => {
                self.message_queue.push(.{ .err = .{ .code = .session_error } });
                self.status = .failed;
            },
            else => {
                // Ignore other event types for now
            },
        }
    }

    pub const Error = error{
        AlreadyConnected,
        NotConnected,
        NoSession,
        InvalidState,
        SpawnFailed,
        HealthCheckFailed,
        SessionFailed,
        ThreadSpawnFailed,
    } || Allocator.Error;
};

// =============================================================================
// Tests
// =============================================================================

test "MessageQueue push and pop" {
    const allocator = std.testing.allocator;
    var queue = MessageQueue.init(allocator);
    defer queue.deinit();

    // Push events
    const delta1 = try allocator.dupe(u8, "Hello");
    queue.push(.{ .message_chunk = .{ .delta = delta1 } });

    const delta2 = try allocator.dupe(u8, "World");
    queue.push(.{ .message_chunk = .{ .delta = delta2 } });

    queue.push(.{ .message_complete = {} });

    // Pop and verify order
    var event1 = queue.pop();
    try std.testing.expect(event1 != null);
    try std.testing.expectEqualStrings("Hello", event1.?.message_chunk.delta);
    event1.?.deinit(allocator);

    var event2 = queue.pop();
    try std.testing.expect(event2 != null);
    try std.testing.expectEqualStrings("World", event2.?.message_chunk.delta);
    event2.?.deinit(allocator);

    const event3 = queue.pop();
    try std.testing.expect(event3 != null);
    try std.testing.expect(event3.? == .message_complete);

    // Queue should be empty
    try std.testing.expect(queue.pop() == null);
}

test "MessageQueue thread safety" {
    const allocator = std.testing.allocator;
    var queue = MessageQueue.init(allocator);
    defer queue.deinit();

    const num_threads = 4;
    const items_per_thread = 100;

    // Spawn producer threads
    var threads: [num_threads]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn producer(q: *MessageQueue, alloc: Allocator, thread_id: usize) void {
                for (0..items_per_thread) |j| {
                    const msg = std.fmt.allocPrint(alloc, "t{d}-{d}", .{ thread_id, j }) catch continue;
                    q.push(.{ .message_chunk = .{ .delta = msg } });
                }
            }
        }.producer, .{ &queue, allocator, i });
    }

    // Wait for all threads
    for (&threads) |*t| {
        t.join();
    }

    // Verify all items were pushed
    try std.testing.expectEqual(@as(usize, num_threads * items_per_thread), queue.len());

    // Pop and free all items
    while (queue.pop()) |*event| {
        var e = event.*;
        e.deinit(allocator);
    }
}

test "Status enum values" {
    // Test initial status
    const mgr = OpencodeManager.init(std.testing.allocator);
    defer @constCast(&mgr).deinit();

    try std.testing.expectEqual(Status.idle, mgr.status);
}

test "OpencodeManager init" {
    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    try std.testing.expectEqual(Status.idle, manager.status);
    try std.testing.expect(manager.client == null);
    try std.testing.expect(manager.server_process == null);
    try std.testing.expect(manager.session_id == null);
}

test "Event deinit" {
    const allocator = std.testing.allocator;

    // Test message_chunk deinit
    const delta = try allocator.dupe(u8, "test delta");
    var event1 = Event{ .message_chunk = .{ .delta = delta } };
    event1.deinit(allocator);

    // Test error deinit
    const msg = try allocator.dupe(u8, "error message");
    var event2 = Event{ .err = .{ .code = .connection_failed, .message = msg } };
    event2.deinit(allocator);

    // Test message_complete deinit (no-op)
    var event3 = Event{ .message_complete = {} };
    event3.deinit(allocator);
}

// Integration tests - skipped in unit test runs (require live server)
test "integration: connect and disconnect" {
    // Skip in normal test runs - requires opencode binary
    if (true) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var manager = OpencodeManager.init(allocator);
    defer manager.deinit();

    try manager.connect(.{
        .opencode_path = "/usr/local/bin/opencode",
        .port = 14096,
        .spawn_server = true,
    });

    try std.testing.expectEqual(Status.session_active, manager.status);
    try std.testing.expect(manager.session_id != null);

    manager.disconnect();
    try std.testing.expectEqual(Status.disconnected, manager.status);
}
