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

    // Turn state (populated during active turn)
    turn_id: ?[]const u8,

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
        TurnStartFailed,
        TurnSteerFailed,
        TurnInterruptFailed,
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
            .turn_id = null,
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

    // =========================================================================
    // Turn lifecycle
    // =========================================================================

    /// Start a new turn with the given text input.
    pub fn startTurn(self: *CodexManager, text: []const u8) Error!void {
        const transport = self.transport orelse return error.NotConnected;
        if (self.status != .thread_active) return error.NotConnected;

        const thread_id = self.thread_id orelse return error.NotConnected;
        const req_id = self.nextRequestId();
        var encoder = codec.Encoder.init(self.allocator);
        var text_input = [_]protocol.InputItem{
            .{ .text = .{ .text = text } },
        };
        const msg = encoder.encodeTurnStart(req_id.number, .{
            .thread_id = thread_id,
            .input = &text_input,
        }) catch return error.TurnStartFailed;
        defer self.allocator.free(msg);
        try transport.send(msg);
        self.status = .turn_active;
    }

    /// Steer an active turn with additional text input.
    pub fn steerTurn(self: *CodexManager, text: []const u8) Error!void {
        const transport = self.transport orelse return error.NotConnected;
        if (self.status != .turn_active) return error.NotConnected;

        const thread_id = self.thread_id orelse return error.NotConnected;
        const turn_id = self.turn_id orelse return error.NotConnected;
        const req_id = self.nextRequestId();
        var encoder = codec.Encoder.init(self.allocator);
        var text_input = [_]protocol.InputItem{
            .{ .text = .{ .text = text } },
        };
        const msg = encoder.encodeTurnSteer(req_id.number, .{
            .thread_id = thread_id,
            .turn_id = turn_id,
            .input = &text_input,
        }) catch return error.TurnSteerFailed;
        defer self.allocator.free(msg);
        try transport.send(msg);
    }

    /// Interrupt the currently active turn.
    pub fn interruptTurn(self: *CodexManager) Error!void {
        const transport = self.transport orelse return error.NotConnected;
        if (self.status != .turn_active) return error.NotConnected;

        const thread_id = self.thread_id orelse return error.NotConnected;
        const turn_id = self.turn_id orelse return error.NotConnected;
        const req_id = self.nextRequestId();
        var encoder = codec.Encoder.init(self.allocator);
        const msg = encoder.encodeTurnInterrupt(req_id.number, thread_id, turn_id) catch return error.TurnInterruptFailed;
        defer self.allocator.free(msg);
        try transport.send(msg);
    }

    // =========================================================================
    // Event processing
    // =========================================================================

    /// Classify a decoded message into a typed CodexEvent.
    /// Returns null for messages that should be filtered out (codex/event/* notifications).
    pub fn processMessage(self: *CodexManager, msg: codec.DecodedMessage) ?CodexEvent {
        switch (msg) {
            .notification => |n| return self.processNotification(n.method, n.params_json),
            .server_request => |r| return self.processNotification(r.method, r.params_json),
            .response => return null,
        }
    }

    pub fn deinit(self: *CodexManager) void {
        self.disconnect();
        self.pending_messages.deinit(self.allocator);
    }

    // =========================================================================
    // CodexEvent — typed events produced by processMessage
    // =========================================================================

    pub const CodexEvent = union(enum) {
        text_delta: DeltaEvent,
        reasoning_delta: DeltaEvent,
        command_output_delta: DeltaEvent,
        item_started: ItemEvent,
        item_completed: ItemEvent,
        turn_completed: TurnCompletedEvent,
        plan_updated: PlanUpdatedEvent,
        unknown: void,

        pub const DeltaEvent = struct {
            thread_id: []const u8,
            turn_id: []const u8,
            item_id: []const u8,
            delta: []const u8,
        };

        pub const ItemEvent = struct {
            thread_id: []const u8,
            turn_id: []const u8,
            item: protocol.Item,
        };

        pub const TurnCompletedEvent = struct {
            thread_id: []const u8,
            turn: protocol.Turn,
        };

        pub const PlanUpdatedEvent = struct {
            thread_id: []const u8,
            turn_id: []const u8,
            plan_steps: []const u8,
        };
    };

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

        if (self.turn_id) |tid| self.allocator.free(tid);
        self.turn_id = null;
    }

    fn freePendingMessages(self: *CodexManager) void {
        for (self.pending_messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.pending_messages.clearRetainingCapacity();
    }

    fn processNotification(self: *CodexManager, method: []const u8, params_json: ?[]const u8) ?CodexEvent {
        // Filter out codex/event/* low-level notifications (AD-3)
        if (std.mem.startsWith(u8, method, "codex/event/")) return null;

        const Method = enum {
            agent_message_delta,
            reasoning_delta,
            command_output_delta,
            item_started,
            item_completed,
            turn_completed,
        };

        const method_map = std.StaticStringMap(Method).initComptime(.{
            .{ "item/agentMessage/delta", .agent_message_delta },
            .{ "item/reasoning/summaryTextDelta", .reasoning_delta },
            .{ "item/commandExecution/outputDelta", .command_output_delta },
            .{ "item/started", .item_started },
            .{ "item/completed", .item_completed },
            .{ "turn/completed", .turn_completed },
        });

        const variant = method_map.get(method) orelse return .{ .unknown = {} };
        const json = params_json orelse return .{ .unknown = {} };

        return switch (variant) {
            .agent_message_delta => self.parseDeltaEvent(json, .text_delta),
            .reasoning_delta => self.parseDeltaEvent(json, .reasoning_delta),
            .command_output_delta => self.parseDeltaEvent(json, .command_output_delta),
            .item_started => self.parseItemEvent(json, .item_started),
            .item_completed => self.parseItemEvent(json, .item_completed),
            .turn_completed => self.parseTurnCompleted(json),
        };
    }

    const DeltaTag = enum { text_delta, reasoning_delta, command_output_delta };

    fn parseDeltaEvent(self: *CodexManager, json: []const u8, tag: DeltaTag) ?CodexEvent {
        const RawDelta = struct {
            threadId: ?[]const u8 = null,
            turnId: ?[]const u8 = null,
            itemId: ?[]const u8 = null,
            delta: ?struct {
                text: ?[]const u8 = null,
            } = null,
        };

        // Parse without allocating — string slices reference into `json` (which is
        // params_json, alive until the DecodedMessage is freed by the caller).
        const parsed = std.json.parseFromSlice(RawDelta, self.allocator, json, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();

        const r = parsed.value;
        const delta_text = if (r.delta) |d| d.text orelse "" else "";

        // Update turn_id if we see one from the server
        if (r.turnId) |tid| {
            if (self.turn_id == null) {
                self.turn_id = self.allocator.dupe(u8, tid) catch null;
            }
        }

        const event = CodexEvent.DeltaEvent{
            .thread_id = r.threadId orelse "",
            .turn_id = r.turnId orelse "",
            .item_id = r.itemId orelse "",
            .delta = delta_text,
        };

        return switch (tag) {
            .text_delta => .{ .text_delta = event },
            .reasoning_delta => .{ .reasoning_delta = event },
            .command_output_delta => .{ .command_output_delta = event },
        };
    }

    const ItemTag = enum { item_started, item_completed };

    fn parseItemEvent(self: *CodexManager, json: []const u8, tag: ItemTag) ?CodexEvent {
        // Zero-alloc parse: string slices reference into `json` (which is params_json,
        // alive until the DecodedMessage is freed by the caller).
        const RawItemParams = struct {
            threadId: ?[]const u8 = null,
            turnId: ?[]const u8 = null,
            item: ?RawItemCompact = null,
        };

        const parsed = std.json.parseFromSlice(RawItemParams, self.allocator, json, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();

        const r = parsed.value;
        const raw_item = r.item orelse return null;

        // Update turn_id from item events
        if (r.turnId) |tid| {
            if (self.turn_id == null) {
                self.turn_id = self.allocator.dupe(u8, tid) catch null;
            }
        }

        const item = convertCompactItem(raw_item);

        const event = CodexEvent.ItemEvent{
            .thread_id = r.threadId orelse "",
            .turn_id = r.turnId orelse "",
            .item = item,
        };

        return switch (tag) {
            .item_started => .{ .item_started = event },
            .item_completed => .{ .item_completed = event },
        };
    }

    fn parseTurnCompleted(self: *CodexManager, json: []const u8) ?CodexEvent {
        // Zero-alloc parse: string slices reference into `json` (params_json)
        const RawTurnCompleted = struct {
            threadId: ?[]const u8 = null,
            turn: ?struct {
                id: []const u8 = "",
                status: ?[]const u8 = null,
            } = null,
        };

        const parsed = std.json.parseFromSlice(RawTurnCompleted, self.allocator, json, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();

        const r = parsed.value;
        const raw_turn = r.turn orelse return null;

        // Turn is done — transition back to thread_active
        self.status = .thread_active;

        // Free turn_id since the turn is complete
        if (self.turn_id) |tid| {
            self.allocator.free(tid);
            self.turn_id = null;
        }

        return .{ .turn_completed = .{
            .thread_id = r.threadId orelse "",
            .turn = .{
                .id = raw_turn.id,
                .status = if (raw_turn.status) |s| protocol.TurnStatus.fromString(s) else null,
            },
        } };
    }

    /// Compact item structure for zero-alloc parsing.
    /// String fields borrow directly from the source JSON.
    const RawItemCompact = struct {
        type: ?[]const u8 = null,
        id: ?[]const u8 = null,
        text: ?[]const u8 = null,
        command: ?[]const u8 = null,
        cwd: ?[]const u8 = null,
        exitCode: ?i32 = null,
        stdout: ?[]const u8 = null,
        stderr: ?[]const u8 = null,
        status: ?[]const u8 = null,
        path: ?[]const u8 = null,
        diff: ?[]const u8 = null,
        serverName: ?[]const u8 = null,
        toolName: ?[]const u8 = null,
        arguments: ?[]const u8 = null,
        output: ?[]const u8 = null,
    };

    fn convertCompactItem(raw: RawItemCompact) protocol.Item {
        const item_type = raw.type orelse return .{ .unknown = {} };
        const item_id = raw.id orelse "";

        const map = std.StaticStringMap(enum {
            user_message,
            agent_message,
            reasoning,
            command_execution,
            file_change,
            mcp_tool_call,
        }).initComptime(.{
            .{ "userMessage", .user_message },
            .{ "agentMessage", .agent_message },
            .{ "reasoning", .reasoning },
            .{ "commandExecution", .command_execution },
            .{ "fileChange", .file_change },
            .{ "mcpToolCall", .mcp_tool_call },
        });

        const variant = map.get(item_type) orelse return .{ .unknown = {} };

        return switch (variant) {
            .user_message => .{ .user_message = .{ .id = item_id } },
            .agent_message => .{ .agent_message = .{
                .id = item_id,
                .text = raw.text orelse "",
            } },
            .reasoning => .{ .reasoning = .{
                .id = item_id,
                .summary = &.{},
                .content = &.{},
            } },
            .command_execution => .{ .command_execution = .{
                .id = item_id,
                .command = raw.command,
                .cwd = raw.cwd,
                .exit_code = raw.exitCode,
                .stdout = raw.stdout,
                .stderr = raw.stderr,
                .status = if (raw.status) |s| protocol.CommandExecutionStatus.fromString(s) orelse .pending else .pending,
            } },
            .file_change => .{ .file_change = .{
                .id = item_id,
                .path = raw.path,
                .diff = raw.diff,
                .status = raw.status,
            } },
            .mcp_tool_call => .{ .mcp_tool_call = .{
                .id = item_id,
                .server_name = raw.serverName,
                .tool_name = raw.toolName,
                .arguments = raw.arguments,
                .output = raw.output,
                .status = raw.status,
            } },
        };
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

test "startTurn fails when not in thread_active state" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    const result = manager.startTurn("hello");
    try std.testing.expectError(error.NotConnected, result);
}

test "interruptTurn fails when not in turn_active state" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    manager.status = .thread_active;
    const result = manager.interruptTurn();
    try std.testing.expectError(error.NotConnected, result);
}

test "processMessage with agentMessage/delta notification returns text_delta" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"item/agentMessage/delta","params":{"threadId":"t1","turnId":"turn-1","itemId":"item-1","delta":{"text":"Hello"}}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    const event = manager.processMessage(msg);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .text_delta);
    try std.testing.expectEqualStrings("Hello", event.?.text_delta.delta);
}

test "processMessage with codex/event/* method returns null (filtered)" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"codex/event/something","params":{"data":"test"}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    const event = manager.processMessage(msg);
    try std.testing.expect(event == null);
}

test "processMessage with turn/completed returns turn_completed and transitions status" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    manager.status = .turn_active;

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"turn/completed","params":{"threadId":"t1","turn":{"id":"turn-1","status":"completed"}}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    const event = manager.processMessage(msg);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .turn_completed);
    try std.testing.expectEqual(CodexManager.Status.thread_active, manager.status);
}

test "processMessage with reasoning delta returns reasoning_delta" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"item/reasoning/summaryTextDelta","params":{"threadId":"t1","turnId":"turn-1","itemId":"item-2","delta":{"text":"Thinking..."}}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    const event = manager.processMessage(msg);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .reasoning_delta);
    try std.testing.expectEqualStrings("Thinking...", event.?.reasoning_delta.delta);
}

test "processMessage with item/started returns item_started" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"item/started","params":{"threadId":"t1","turnId":"turn-1","item":{"type":"commandExecution","id":"cmd-1","command":"ls -la"}}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    const event = manager.processMessage(msg);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .item_started);
    try std.testing.expect(event.?.item_started.item == .command_execution);
}

test "processMessage with unknown method returns unknown" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"future/unknown","params":{"data":"test"}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    const event = manager.processMessage(msg);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .unknown);
}

test "processMessage with response returns null" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"id":1,"result":{"data":"test"}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    const event = manager.processMessage(msg);
    try std.testing.expect(event == null);
}

test "processMessage turn_id tracking from delta events" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    try std.testing.expect(manager.turn_id == null);

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"item/agentMessage/delta","params":{"threadId":"t1","turnId":"my-turn","itemId":"item-1","delta":{"text":"Hi"}}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    _ = manager.processMessage(msg);
    try std.testing.expect(manager.turn_id != null);
    try std.testing.expectEqualStrings("my-turn", manager.turn_id.?);
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
