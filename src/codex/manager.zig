const std = @import("std");
const Allocator = std.mem.Allocator;
const process_mod = @import("process.zig");
const transport_mod = @import("transport.zig");
const codec = @import("codec.zig");
const protocol = @import("protocol.zig");

// =============================================================================
// Codex Manager
// =============================================================================

/// Orchestrates the full Codex app-server connection lifecycle.
/// Manages process spawning, transport, handshake, and event polling.
///
/// State machine:
///   disconnected -> connecting -> initialized -> thread_active
///                                                 |
///                                                 v
///                                             turn_active (Phase 3)
pub const CodexManager = struct {
    allocator: Allocator,
    process: ?*process_mod.CodexProcess,
    transport: ?*transport_mod.StdioTransport,
    status: Status,

    // Thread state (populated after startThread)
    thread_id: ?[]const u8,
    thread_info: ?protocol.Thread,
    model: ?[]const u8,
    model_provider: ?[]const u8,
    approval_policy: ?protocol.ApprovalPolicy,
    reasoning_effort: ?protocol.ReasoningEffort,

    // Request ID counter for outgoing requests
    request_id_counter: i64,

    // Messages drained from transport for the caller to consume
    pending_messages: std.ArrayListUnmanaged(codec.DecodedMessage),

    pub const Status = enum {
        disconnected,
        connecting,
        initialized,
        thread_active,
        turn_active,
        @"error",
    };

    pub const Error = error{
        NotConnected,
        AlreadyConnected,
        HandshakeTimeout,
        HandshakeFailed,
        ThreadStartFailed,
        ThreadStartTimeout,
    } || Allocator.Error || process_mod.CodexProcess.SpawnError || transport_mod.StdioTransport.Error;

    pub fn init(allocator: Allocator) CodexManager {
        return .{
            .allocator = allocator,
            .process = null,
            .transport = null,
            .status = .disconnected,
            .thread_id = null,
            .thread_info = null,
            .model = null,
            .model_provider = null,
            .approval_policy = null,
            .reasoning_effort = null,
            .request_id_counter = 0,
            .pending_messages = .{},
        };
    }

    /// Connect to codex app-server: spawn process, perform handshake.
    /// After successful return, status is .initialized.
    pub fn connect(self: *CodexManager, command: []const u8, args: ?[]const []const u8, cwd: ?[]const u8) Error!void {
        if (self.status != .disconnected) return error.AlreadyConnected;

        self.status = .connecting;
        errdefer self.status = .@"error";

        // 1. Spawn the codex app-server process
        const proc = try process_mod.CodexProcess.spawn(self.allocator, command, args, cwd);
        errdefer proc.deinit();

        // 2. Create transport and start background reader
        const transport = try transport_mod.StdioTransport.init(self.allocator, proc);
        errdefer transport.deinit();
        transport.startReader();

        // 3. Send initialize request
        const init_id = self.nextRequestId();
        var encoder = codec.Encoder.init(self.allocator);
        const init_msg = encoder.encodeInitialize(init_id.number, .{
            .client_name = "skim",
            .title = "Skim",
            .client_version = "0.1.0",
        }) catch return error.HandshakeFailed;
        defer self.allocator.free(init_msg);
        try transport.send(init_msg);

        // 4. Wait for initialize response
        const response = try self.waitForResponseOn(transport, init_id, 10_000) orelse return error.HandshakeTimeout;
        var resp = response;
        defer resp.deinit(self.allocator);

        // Check for error in response
        switch (resp) {
            .response => |r| {
                if (r.error_msg != null) return error.HandshakeFailed;
            },
            else => return error.HandshakeFailed,
        }

        // 5. Send initialized notification
        const initialized_msg = encoder.encodeInitialized() catch return error.HandshakeFailed;
        defer self.allocator.free(initialized_msg);
        try transport.send(initialized_msg);

        // 6. Handshake succeeded — take ownership of resources
        self.process = proc;
        self.transport = transport;
        self.status = .initialized;
    }

    /// Disconnect from codex: stop transport, terminate process, clean up state.
    pub fn disconnect(self: *CodexManager) void {
        if (self.transport) |t| {
            t.stopReader();
            t.deinit();
            self.transport = null;
        }

        if (self.process) |p| {
            p.deinit();
            self.process = null;
        }

        self.freeThreadState();
        self.freePendingMessages();
        self.status = .disconnected;
    }

    /// Start a new thread. After successful return, status is .thread_active.
    pub fn startThread(self: *CodexManager, model: ?[]const u8, cwd: ?[]const u8) Error!void {
        const transport = self.transport orelse return error.NotConnected;
        if (self.status != .initialized and self.status != .thread_active) return error.NotConnected;

        // Free previous thread state if restarting
        self.freeThreadState();

        const req_id = self.nextRequestId();
        var encoder = codec.Encoder.init(self.allocator);
        const msg = encoder.encodeThreadStart(req_id.number, .{
            .model = model,
            .cwd = cwd,
        }) catch return error.ThreadStartFailed;
        defer self.allocator.free(msg);
        try transport.send(msg);

        // Wait for thread/start response
        const response = try self.waitForResponse(req_id, 10_000) orelse return error.ThreadStartTimeout;
        var resp = response;
        defer resp.deinit(self.allocator);

        const result_json = switch (resp) {
            .response => |r| blk: {
                if (r.error_msg != null) return error.ThreadStartFailed;
                break :blk r.result_json orelse return error.ThreadStartFailed;
            },
            else => return error.ThreadStartFailed,
        };

        // Parse thread start result
        var decoder = codec.Decoder.init(self.allocator);
        const result = decoder.parseThreadStartResult(result_json) catch return error.ThreadStartFailed;

        // Store thread state (take ownership of heap-allocated fields)
        self.thread_id = result.thread.id;
        self.thread_info = result.thread;
        self.model = result.model;
        self.model_provider = result.model_provider;
        self.approval_policy = result.approval_policy;
        self.reasoning_effort = result.reasoning_effort;

        // Free fields from ThreadStartResult that we don't store in the manager
        if (result.cwd) |c| self.allocator.free(c);
        if (result.sandbox) |s| {
            if (s.type) |t| self.allocator.free(t);
        }

        self.status = .thread_active;
    }

    /// Drain new messages from the transport into pending_messages.
    /// Returns the count of new messages added.
    pub fn pollEvents(self: *CodexManager) Error!usize {
        const transport = self.transport orelse return error.NotConnected;

        const messages = try transport.drainMessages();
        if (messages.len == 0) return 0;

        // Transfer ownership of each message to pending_messages
        defer self.allocator.free(messages);
        for (messages) |msg| {
            self.pending_messages.append(self.allocator, msg) catch continue;
        }

        return messages.len;
    }

    /// Take all pending messages. Caller owns the returned slice and each message.
    /// Caller must call deinit on each DecodedMessage and free the slice.
    pub fn takePendingMessages(self: *CodexManager) Allocator.Error![]codec.DecodedMessage {
        if (self.pending_messages.items.len == 0) {
            return &[_]codec.DecodedMessage{};
        }

        const items = try self.allocator.dupe(codec.DecodedMessage, self.pending_messages.items);
        self.pending_messages.clearRetainingCapacity();
        return items;
    }

    pub fn deinit(self: *CodexManager) void {
        self.disconnect();
        self.pending_messages.deinit(self.allocator);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    fn nextRequestId(self: *CodexManager) codec.RequestId {
        const id = self.request_id_counter;
        self.request_id_counter += 1;
        return .{ .number = id };
    }

    /// Poll transport until we get a response matching expected_id or timeout.
    /// Non-matching messages are queued in pending_messages.
    fn waitForResponse(self: *CodexManager, expected_id: codec.RequestId, timeout_ms: u64) Error!?codec.DecodedMessage {
        return self.waitForResponseOn(self.transport orelse return error.NotConnected, expected_id, timeout_ms);
    }

    /// Poll a specific transport until we get a response matching expected_id or timeout.
    /// Used during connect() before self.transport is assigned.
    fn waitForResponseOn(self: *CodexManager, transport: *transport_mod.StdioTransport, expected_id: codec.RequestId, timeout_ms: u64) Error!?codec.DecodedMessage {
        const start = std.time.milliTimestamp();

        while (true) {
            const elapsed = std.time.milliTimestamp() - start;
            if (elapsed > @as(i64, @intCast(timeout_ms))) return null;

            const messages = try transport.drainMessages();
            if (messages.len == 0) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            }

            defer self.allocator.free(messages);

            var found: ?codec.DecodedMessage = null;
            for (messages) |msg| {
                if (found == null) {
                    const is_match = switch (msg) {
                        .response => |r| blk: {
                            if (r.id) |id| {
                                break :blk id.eql(expected_id);
                            }
                            break :blk false;
                        },
                        else => false,
                    };

                    if (is_match) {
                        found = msg;
                        continue;
                    }
                }
                // Non-matching messages go to pending_messages
                self.pending_messages.append(self.allocator, msg) catch {};
            }

            if (found) |f| return f;

            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    fn freeThreadState(self: *CodexManager) void {
        // thread_info owns the thread_id allocation via its id field.
        // We only need to free the top-level thread_info fields.
        if (self.thread_info) |ti| {
            self.allocator.free(ti.id);
            if (ti.preview) |p| self.allocator.free(p);
            if (ti.model_provider) |mp| self.allocator.free(mp);
            if (ti.path) |p| self.allocator.free(p);
            if (ti.cwd) |c| self.allocator.free(c);
            if (ti.cli_version) |cv| self.allocator.free(cv);
            if (ti.source) |s| self.allocator.free(s);
            if (ti.git_info) |gi| {
                if (gi.sha) |sha| self.allocator.free(sha);
                if (gi.branch) |b| self.allocator.free(b);
                if (gi.origin_url) |o| self.allocator.free(o);
            }
            if (ti.turns) |turns| {
                for (turns) |t| {
                    self.allocator.free(t.id);
                }
                self.allocator.free(turns);
            }
        }
        self.thread_info = null;
        // thread_id points into thread_info.id which was freed above
        self.thread_id = null;

        if (self.model) |m| self.allocator.free(m);
        self.model = null;

        if (self.model_provider) |mp| self.allocator.free(mp);
        self.model_provider = null;

        self.approval_policy = null;
        self.reasoning_effort = null;
    }

    fn freePendingMessages(self: *CodexManager) void {
        for (self.pending_messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.pending_messages.clearRetainingCapacity();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "initial state is disconnected" {
    const manager = CodexManager.init(std.testing.allocator);
    defer {
        var m = manager;
        m.deinit();
    }

    try std.testing.expectEqual(CodexManager.Status.disconnected, manager.status);
    try std.testing.expect(manager.process == null);
    try std.testing.expect(manager.transport == null);
    try std.testing.expect(manager.thread_id == null);
    try std.testing.expect(manager.model == null);
    try std.testing.expectEqual(@as(i64, 0), manager.request_id_counter);
}

test "connect fails when already connected" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    // Manually set status to initialized to simulate an existing connection
    manager.status = .initialized;

    const result = manager.connect("codex", null, null);
    try std.testing.expectError(error.AlreadyConnected, result);
}

test "request ID counter increments" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    const id1 = manager.nextRequestId();
    const id2 = manager.nextRequestId();
    const id3 = manager.nextRequestId();

    try std.testing.expectEqual(@as(i64, 0), id1.number);
    try std.testing.expectEqual(@as(i64, 1), id2.number);
    try std.testing.expectEqual(@as(i64, 2), id3.number);
}

test "disconnect from disconnected state is safe" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    // Should not panic or error
    manager.disconnect();
    try std.testing.expectEqual(CodexManager.Status.disconnected, manager.status);
}

test "deinit from disconnected state is safe" {
    var manager = CodexManager.init(std.testing.allocator);
    manager.deinit();
}

fn codexAvailable() bool {
    const result = std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ "which", "codex" },
    }) catch return false;
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    return result.term.Exited == 0;
}

test "codex manager handshake" {
    if (!codexAvailable()) return;

    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.connect("codex", null, "/home/ctdio/projects/open-source/skim-wta");

    try std.testing.expectEqual(CodexManager.Status.initialized, manager.status);
    try std.testing.expect(manager.process != null);
    try std.testing.expect(manager.transport != null);
}

test "codex manager thread start" {
    if (!codexAvailable()) return;

    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.connect("codex", null, "/home/ctdio/projects/open-source/skim-wta");
    try std.testing.expectEqual(CodexManager.Status.initialized, manager.status);

    try manager.startThread(null, "/home/ctdio/projects/open-source/skim-wta");
    try std.testing.expectEqual(CodexManager.Status.thread_active, manager.status);
    try std.testing.expect(manager.thread_id != null);
    try std.testing.expect(manager.model != null);
}
