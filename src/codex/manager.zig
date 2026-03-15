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

    // User-requested approval policy (set before startThread, sent on thread/start)
    requested_approval_policy: ?protocol.ApprovalPolicy,
    requested_reasoning_effort: ?protocol.ReasoningEffort,
    requested_service_tier: ?protocol.ServiceTier,
    requested_collaboration_mode: ?protocol.CollaborationMode,

    // Thread state (populated after startThread)
    thread_id: ?[]const u8,
    thread_info: ?protocol.Thread,
    model: ?[]const u8,
    model_provider: ?[]const u8,
    approval_policy: ?protocol.ApprovalPolicy,
    reasoning_effort: ?protocol.ReasoningEffort,
    service_tier: ?protocol.ServiceTier,
    collaboration_mode: ?protocol.CollaborationMode,

    // Model list (populated after listModels)
    models: ?[]protocol.ModelInfo,
    current_model: ?[]const u8,

    // Turn state (populated during active turn)
    turn_id: ?[]const u8,

    // Token usage (populated from thread/tokenUsage/updated notifications)
    token_usage: ?protocol.TokenUsage,

    // Rate limits (populated from account/rateLimits/updated notifications)
    rate_limits: ?protocol.RateLimits,

    // MCP server status (populated from codex/event/mcp_startup_* events)
    mcp_servers: ?McpServerStatus,

    // Pending approval request from the server
    pending_approval: ?PendingApproval,

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

    pub const CommandDecision = enum {
        accept,
        accept_for_session,
        accept_with_execpolicy_amendment,
        decline,
        cancel,
    };

    pub const FileChangeDecision = enum {
        accept,
        accept_for_session,
        decline,
        cancel,
    };

    pub const UserInputQuestion = struct {
        id: []const u8,
        header: ?[]const u8,
        question: []const u8,
        options: ?[]const protocol.UserInputOption,
        is_other: bool,
        selected_index: usize,
    };

    pub const PendingApproval = union(enum) {
        command: struct {
            request_id: codec.RequestId,
            item_id: ?[]const u8,
            thread_id: []const u8,
            turn_id: ?[]const u8,
            command: []const u8,
            cwd: ?[]const u8,
            reason: ?[]const u8,
            selected_decision: CommandDecision,
        },
        file_change: struct {
            request_id: codec.RequestId,
            item_id: ?[]const u8,
            thread_id: []const u8,
            turn_id: ?[]const u8,
            path: []const u8,
            selected_decision: FileChangeDecision,
        },
        user_input: struct {
            request_id: codec.RequestId,
            thread_id: []const u8,
            turn_id: ?[]const u8,
            questions: []UserInputQuestion,
            active_question: usize,
        },

        pub fn deinit(self: *PendingApproval, allocator: Allocator) void {
            switch (self.*) {
                .command => |*c| {
                    switch (c.request_id) {
                        .string => |s| allocator.free(s),
                        else => {},
                    }
                    if (c.item_id) |id| allocator.free(id);
                    allocator.free(c.thread_id);
                    if (c.turn_id) |tid| allocator.free(tid);
                    allocator.free(c.command);
                    if (c.cwd) |cwd| allocator.free(cwd);
                    if (c.reason) |r| allocator.free(r);
                },
                .file_change => |*f| {
                    switch (f.request_id) {
                        .string => |s| allocator.free(s),
                        else => {},
                    }
                    if (f.item_id) |id| allocator.free(id);
                    allocator.free(f.thread_id);
                    if (f.turn_id) |tid| allocator.free(tid);
                    allocator.free(f.path);
                },
                .user_input => |*u| {
                    switch (u.request_id) {
                        .string => |s| allocator.free(s),
                        else => {},
                    }
                    allocator.free(u.thread_id);
                    if (u.turn_id) |tid| allocator.free(tid);
                    for (u.questions) |*q| {
                        allocator.free(q.id);
                        if (q.header) |h| allocator.free(h);
                        allocator.free(q.question);
                        if (q.options) |opts| {
                            for (opts) |o| {
                                allocator.free(o.label);
                                if (o.description) |d| allocator.free(d);
                            }
                            allocator.free(opts);
                        }
                    }
                    allocator.free(u.questions);
                },
            }
        }
    };

    pub const McpServerEntry = struct {
        name: []const u8,
        state: []const u8,
    };

    pub const McpServerStatus = struct {
        servers: []McpServerEntry,
        complete: bool,
        ready: ?[][]const u8,
        failed: ?[][]const u8,
    };

    pub const Error = error{
        NotConnected,
        AlreadyConnected,
        HandshakeTimeout,
        HandshakeFailed,
        ThreadStartFailed,
        ThreadStartTimeout,
        ThreadListFailed,
        ThreadListTimeout,
        ThreadResumeFailed,
        ThreadResumeTimeout,
        ThreadForkFailed,
        ThreadForkTimeout,
        ModelListFailed,
        ModelListTimeout,
        TurnStartFailed,
        ApprovalSwitchDuringTurn,
        TurnSteerFailed,
        TurnInterruptFailed,
        CompactFailed,
        RollbackFailed,
        ArchiveFailed,
        ModelSwitchDuringTurn,
    } || Allocator.Error || process_mod.CodexProcess.SpawnError || transport_mod.StdioTransport.Error;

    pub fn init(allocator: Allocator) CodexManager {
        return .{
            .allocator = allocator,
            .process = null,
            .transport = null,
            .status = .disconnected,
            .requested_approval_policy = null,
            .requested_reasoning_effort = null,
            .requested_service_tier = null,
            .requested_collaboration_mode = null,
            .thread_id = null,
            .thread_info = null,
            .model = null,
            .model_provider = null,
            .approval_policy = null,
            .reasoning_effort = null,
            .service_tier = null,
            .collaboration_mode = null,
            .models = null,
            .current_model = null,
            .turn_id = null,
            .token_usage = null,
            .rate_limits = null,
            .mcp_servers = null,
            .pending_approval = null,
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
            .experimental_api = true,
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
        self.freePendingApproval();
        self.freePendingMessages();
        self.freeModels();
        self.token_usage = null;
        self.rate_limits = null;
        self.freeMcpServers();
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
            .approval_policy = self.requested_approval_policy,
            .reasoning_effort = self.requested_reasoning_effort,
            .service_tier = self.requested_service_tier,
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
        self.reasoning_effort = result.reasoning_effort orelse self.requested_reasoning_effort;
        self.service_tier = result.service_tier orelse self.requested_service_tier;
        self.requested_reasoning_effort = self.reasoning_effort;
        self.requested_service_tier = self.service_tier;

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
            .reasoning_effort = self.requested_reasoning_effort,
            .service_tier = self.requested_service_tier,
            .collaboration_mode = self.requested_collaboration_mode,
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
    // Session management (thread list, resume, fork)
    // =========================================================================

    /// List threads from the connected app-server.
    /// Returns an owned slice of Thread objects. Caller must free with freeThreadList().
    pub fn listThreads(self: *CodexManager) Error![]protocol.Thread {
        const transport = self.transport orelse return error.NotConnected;
        if (self.status == .disconnected or self.status == .connecting) return error.NotConnected;

        const req_id = self.nextRequestId();
        var encoder = codec.Encoder.init(self.allocator);
        const msg = encoder.encodeThreadList(req_id.number, .{}) catch return error.ThreadListFailed;
        defer self.allocator.free(msg);
        try transport.send(msg);

        const response = try self.waitForResponseOn(transport, req_id, 10_000) orelse return error.ThreadListTimeout;
        var resp = response;
        defer resp.deinit(self.allocator);

        const result_json = switch (resp) {
            .response => |r| blk: {
                if (r.error_msg != null) return error.ThreadListFailed;
                break :blk r.result_json orelse return error.ThreadListFailed;
            },
            else => return error.ThreadListFailed,
        };

        var decoder = codec.Decoder.init(self.allocator);
        const result = decoder.parseThreadListResult(result_json) catch return error.ThreadListFailed;
        return result.data;
    }

    /// Free a thread list returned by listThreads().
    pub fn freeThreadList(self: *CodexManager, threads: []protocol.Thread) void {
        for (threads) |thread| {
            self.allocator.free(thread.id);
            if (thread.preview) |p| self.allocator.free(p);
            if (thread.model_provider) |mp| self.allocator.free(mp);
            if (thread.path) |p| self.allocator.free(p);
            if (thread.cwd) |c| self.allocator.free(c);
            if (thread.cli_version) |cv| self.allocator.free(cv);
            if (thread.source) |s| self.allocator.free(s);
            if (thread.git_info) |gi| {
                if (gi.sha) |sha| self.allocator.free(sha);
                if (gi.branch) |b| self.allocator.free(b);
                if (gi.origin_url) |o| self.allocator.free(o);
            }
            if (thread.turns) |turns| {
                for (turns) |t| {
                    self.allocator.free(t.id);
                }
                self.allocator.free(turns);
            }
        }
        self.allocator.free(threads);
    }

    /// Resume an existing thread. After successful return, status is .thread_active.
    /// The response may trigger history replay events via subsequent polling.
    pub fn resumeThread(self: *CodexManager, thread_id: []const u8) Error!void {
        const transport = self.transport orelse return error.NotConnected;
        if (self.status != .initialized and self.status != .thread_active) return error.NotConnected;

        self.freeThreadState();

        const req_id = self.nextRequestId();
        var encoder = codec.Encoder.init(self.allocator);
        const msg = encoder.encodeThreadResume(req_id.number, .{
            .thread_id = thread_id,
        }) catch return error.ThreadResumeFailed;
        defer self.allocator.free(msg);
        try transport.send(msg);

        const response = try self.waitForResponseOn(transport, req_id, 15_000) orelse return error.ThreadResumeTimeout;
        var resp = response;
        defer resp.deinit(self.allocator);

        const result_json = switch (resp) {
            .response => |r| blk: {
                if (r.error_msg != null) return error.ThreadResumeFailed;
                break :blk r.result_json orelse return error.ThreadResumeFailed;
            },
            else => return error.ThreadResumeFailed,
        };

        // Parse thread resume result (same shape as thread/start but fewer fields)
        const RawResumeResult = struct {
            thread: ?std.json.Value = null,
            model: ?[]const u8 = null,
            modelProvider: ?[]const u8 = null,
            reasoningEffort: ?[]const u8 = null,
            serviceTier: ?[]const u8 = null,
        };

        const parsed = std.json.parseFromSlice(RawResumeResult, self.allocator, result_json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return error.ThreadResumeFailed;
        defer parsed.deinit();

        const r = parsed.value;

        const thread = self.parseThreadFromValue(
            r.thread orelse return error.ThreadResumeFailed,
            error.ThreadResumeFailed,
        ) catch return error.ThreadResumeFailed;
        self.thread_id = thread.id;
        self.thread_info = thread;

        // Store model info
        if (r.model) |m| {
            self.model = self.allocator.dupe(u8, m) catch return error.OutOfMemory;
        }
        if (r.modelProvider) |mp| {
            self.model_provider = self.allocator.dupe(u8, mp) catch return error.OutOfMemory;
        }
        self.reasoning_effort = if (r.reasoningEffort) |re| protocol.ReasoningEffort.fromString(re) else null;
        self.requested_reasoning_effort = self.reasoning_effort;
        self.service_tier = if (r.serviceTier) |st| protocol.ServiceTier.fromString(st) else null;
        self.requested_service_tier = self.service_tier;

        self.status = .thread_active;
    }

    /// Fork a thread, creating a new thread from the given thread's history.
    /// Returns the new thread info. After successful return, status is .thread_active
    /// with the new (forked) thread.
    pub fn forkThread(self: *CodexManager, thread_id: []const u8) Error!protocol.Thread {
        const transport = self.transport orelse return error.NotConnected;
        if (self.status != .initialized and self.status != .thread_active) return error.NotConnected;

        self.freeThreadState();

        const req_id = self.nextRequestId();
        var encoder = codec.Encoder.init(self.allocator);
        const msg = encoder.encodeThreadFork(req_id.number, .{
            .thread_id = thread_id,
        }) catch return error.ThreadForkFailed;
        defer self.allocator.free(msg);
        try transport.send(msg);

        const response = try self.waitForResponseOn(transport, req_id, 10_000) orelse return error.ThreadForkTimeout;
        var resp = response;
        defer resp.deinit(self.allocator);

        const result_json = switch (resp) {
            .response => |r| blk: {
                if (r.error_msg != null) return error.ThreadForkFailed;
                break :blk r.result_json orelse return error.ThreadForkFailed;
            },
            else => return error.ThreadForkFailed,
        };

        // Parse fork result (has a thread field)
        const RawForkResult = struct {
            thread: ?std.json.Value = null,
        };

        const parsed = std.json.parseFromSlice(RawForkResult, self.allocator, result_json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return error.ThreadForkFailed;
        defer parsed.deinit();

        const thread = self.parseThreadFromValue(
            parsed.value.thread orelse return error.ThreadForkFailed,
            error.ThreadForkFailed,
        ) catch return error.ThreadForkFailed;
        self.thread_id = thread.id;
        self.thread_info = thread;
        self.status = .thread_active;
        return thread;
    }

    // =========================================================================
    // Model management
    // =========================================================================

    /// Fetch available models from the app-server.
    /// Results are cached in self.models.
    pub fn listModels(self: *CodexManager) Error![]protocol.ModelInfo {
        const transport = self.transport orelse return error.NotConnected;
        if (self.status == .disconnected or self.status == .connecting) return error.NotConnected;

        const req_id = self.nextRequestId();
        var encoder = codec.Encoder.init(self.allocator);
        const msg = encoder.encodeModelList(req_id.number) catch return error.ModelListFailed;
        defer self.allocator.free(msg);
        try transport.send(msg);

        const response = try self.waitForResponseOn(transport, req_id, 10_000) orelse return error.ModelListTimeout;
        var resp = response;
        defer resp.deinit(self.allocator);

        const result_json = switch (resp) {
            .response => |r| blk: {
                if (r.error_msg != null) return error.ModelListFailed;
                break :blk r.result_json orelse return error.ModelListFailed;
            },
            else => return error.ModelListFailed,
        };

        var decoder = codec.Decoder.init(self.allocator);
        const result = decoder.parseModelListResult(result_json) catch return error.ModelListFailed;

        // Free previous model list if cached
        self.freeModels();
        self.models = result.data;

        return result.data;
    }

    /// Set the model for subsequent turns.
    /// The model_id is stored and used when starting new threads/turns.
    pub fn setModel(self: *CodexManager, model_id: []const u8) Error!void {
        if (self.current_model) |cm| self.allocator.free(cm);
        self.current_model = try self.allocator.dupe(u8, model_id);

        if (self.status == .turn_active) return error.ModelSwitchDuringTurn;
        if (self.status != .initialized and self.status != .thread_active) return;

        const cwd_copy = if (self.thread_info) |thread|
            if (thread.cwd) |cwd| try self.allocator.dupe(u8, cwd) else null
        else
            null;
        defer if (cwd_copy) |cwd| self.allocator.free(cwd);

        try self.startThread(self.current_model, cwd_copy);
    }

    /// Set the reasoning effort level for subsequent turns.
    pub fn setReasoningEffort(self: *CodexManager, effort: protocol.ReasoningEffort) void {
        self.requested_reasoning_effort = effort;
        self.reasoning_effort = effort;
    }

    /// Set the service tier for subsequent turns.
    pub fn setServiceTier(self: *CodexManager, service_tier: protocol.ServiceTier) void {
        self.requested_service_tier = service_tier;
        self.service_tier = service_tier;
    }

    /// Check if Codex collaboration modes are available.
    pub fn hasModes(self: *const CodexManager) bool {
        _ = self;
        return true;
    }

    /// Get the current collaboration mode for display.
    pub fn getCurrentModeName(self: *const CodexManager) []const u8 {
        const mode = self.requested_collaboration_mode orelse self.collaboration_mode orelse .default;
        return mode.displayName();
    }

    /// Cycle to the next collaboration mode for subsequent turns.
    pub fn cycleToNextMode(self: *CodexManager) ?[]const u8 {
        const current_mode = self.requested_collaboration_mode orelse self.collaboration_mode orelse .default;
        const next_mode: protocol.CollaborationMode = switch (current_mode) {
            .default => .plan,
            .plan => .default,
        };
        self.requested_collaboration_mode = next_mode;
        self.collaboration_mode = next_mode;
        return next_mode.displayName();
    }

    /// Set approval policy for subsequent turns.
    /// Restarts the active thread so policy applies immediately.
    pub fn setApprovalPolicy(self: *CodexManager, policy: protocol.ApprovalPolicy) Error!void {
        self.requested_approval_policy = policy;
        self.approval_policy = policy;

        if (self.status == .turn_active) return error.ApprovalSwitchDuringTurn;
        if (self.status != .initialized and self.status != .thread_active) return;

        const cwd_copy = if (self.thread_info) |thread|
            if (thread.cwd) |cwd| try self.allocator.dupe(u8, cwd) else null
        else
            null;
        defer if (cwd_copy) |cwd| self.allocator.free(cwd);

        try self.startThread(self.current_model, cwd_copy);
    }

    // =========================================================================
    // Approval handling
    // =========================================================================

    pub fn getPendingApproval(self: *CodexManager) ?*PendingApproval {
        if (self.pending_approval) |*approval| return approval;
        return null;
    }

    /// Respond to a pending command/file-change approval with a decision.
    pub fn respondToApproval(self: *CodexManager, decision_json: []const u8) Error!void {
        const transport = self.transport orelse return error.NotConnected;
        var approval = self.pending_approval orelse return;

        const request_id = switch (approval) {
            .command => |c| c.request_id,
            .file_change => |f| f.request_id,
            .user_input => |u| u.request_id,
        };

        var encoder = codec.Encoder.init(self.allocator);
        const msg = encoder.encodeApprovalResponse(request_id, decision_json) catch return error.TurnSteerFailed;
        defer self.allocator.free(msg);
        try transport.send(msg);

        approval.deinit(self.allocator);
        self.pending_approval = null;
    }

    /// Respond to a pending user-input request with answers.
    pub fn respondToUserInput(self: *CodexManager, answers: []const []const u8) Error!void {
        const transport = self.transport orelse return error.NotConnected;
        var approval = self.pending_approval orelse return;

        const request_id = switch (approval) {
            .user_input => |u| u.request_id,
            else => return,
        };

        var encoder = codec.Encoder.init(self.allocator);
        const msg = encoder.encodeUserInputResponse(request_id, answers) catch return error.TurnSteerFailed;
        defer self.allocator.free(msg);
        try transport.send(msg);

        approval.deinit(self.allocator);
        self.pending_approval = null;
    }

    /// Cancel a pending approval (decline + interrupt turn).
    pub fn cancelApproval(self: *CodexManager) Error!void {
        const transport = self.transport orelse return error.NotConnected;
        var approval = self.pending_approval orelse return;

        const request_id = switch (approval) {
            .command => |c| c.request_id,
            .file_change => |f| f.request_id,
            .user_input => |u| u.request_id,
        };

        var encoder = codec.Encoder.init(self.allocator);
        const msg = encoder.encodeApprovalResponse(request_id, "\"cancel\"") catch return error.TurnSteerFailed;
        defer self.allocator.free(msg);
        try transport.send(msg);

        approval.deinit(self.allocator);
        self.pending_approval = null;

        // Also interrupt the turn
        self.interruptTurn() catch {};
    }

    // =========================================================================
    // Thread operations (compact, rollback, archive, unarchive)
    // =========================================================================

    /// Compact the current thread to reduce context usage.
    pub fn compactThread(self: *CodexManager) Error!void {
        const transport = self.transport orelse return error.NotConnected;
        const thread_id = self.thread_id orelse return error.NotConnected;

        const req_id = self.nextRequestId();
        var encoder = codec.Encoder.init(self.allocator);
        const msg = encoder.encodeThreadCompact(req_id.number, thread_id) catch return error.CompactFailed;
        defer self.allocator.free(msg);
        try transport.send(msg);
    }

    /// Rollback a thread to a specific turn.
    pub fn rollbackThread(self: *CodexManager, turn_id: []const u8) Error!void {
        const transport = self.transport orelse return error.NotConnected;
        const thread_id = self.thread_id orelse return error.NotConnected;

        const req_id = self.nextRequestId();
        var encoder = codec.Encoder.init(self.allocator);
        const msg = encoder.encodeThreadRollback(req_id.number, thread_id, turn_id) catch return error.RollbackFailed;
        defer self.allocator.free(msg);
        try transport.send(msg);
    }

    /// Archive a thread.
    pub fn archiveThread(self: *CodexManager, thread_id: []const u8) Error!void {
        const transport = self.transport orelse return error.NotConnected;

        const req_id = self.nextRequestId();
        var encoder = codec.Encoder.init(self.allocator);
        const msg = encoder.encodeThreadArchive(req_id.number, thread_id) catch return error.ArchiveFailed;
        defer self.allocator.free(msg);
        try transport.send(msg);
    }

    /// Unarchive a thread.
    pub fn unarchiveThread(self: *CodexManager, thread_id: []const u8) Error!void {
        const transport = self.transport orelse return error.NotConnected;

        const req_id = self.nextRequestId();
        var encoder = codec.Encoder.init(self.allocator);
        const msg = encoder.encodeThreadUnarchive(req_id.number, thread_id) catch return error.ArchiveFailed;
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
            .server_request => |r| return self.processServerRequest(r),
            .response => return null,
        }
    }

    pub fn deinit(self: *CodexManager) void {
        self.disconnect();
        self.pending_messages.deinit(self.allocator);
        self.freeMcpServers();
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
        token_usage_updated: protocol.TokenUsage,
        rate_limits_updated: protocol.RateLimits,
        mcp_server_status: void,
        approval_requested: void,
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
            pub const PlanEntryPriority = enum {
                high,
                medium,
                low,
            };

            pub const PlanEntryStatus = enum {
                pending,
                in_progress,
                completed,
            };

            pub const PlanEntry = struct {
                content: []const u8,
                priority: PlanEntryPriority = .medium,
                status: PlanEntryStatus = .pending,
            };

            thread_id: []const u8,
            turn_id: []const u8,
            entries: []PlanEntry,
        };
    };

    /// Release memory owned by a CodexEvent payload.
    pub fn deinitEvent(self: *CodexManager, event: *CodexEvent) void {
        switch (event.*) {
            .text_delta, .reasoning_delta, .command_output_delta => |d| {
                self.allocator.free(d.thread_id);
                self.allocator.free(d.turn_id);
                self.allocator.free(d.item_id);
                self.allocator.free(d.delta);
            },
            .item_started, .item_completed => |e| {
                self.allocator.free(e.thread_id);
                self.allocator.free(e.turn_id);
                freeOwnedItem(self.allocator, e.item);
            },
            .turn_completed => |e| {
                self.allocator.free(e.thread_id);
                self.allocator.free(e.turn.id);
            },
            .plan_updated => |p| {
                self.allocator.free(p.thread_id);
                self.allocator.free(p.turn_id);
                for (p.entries) |entry| self.allocator.free(entry.content);
                self.allocator.free(p.entries);
            },
            else => {},
        }
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
        self.service_tier = null;
        self.collaboration_mode = null;

        if (self.turn_id) |tid| self.allocator.free(tid);
        self.turn_id = null;
    }

    fn freePendingApproval(self: *CodexManager) void {
        if (self.pending_approval) |*approval| {
            approval.deinit(self.allocator);
            self.pending_approval = null;
        }
    }

    fn freePendingMessages(self: *CodexManager) void {
        for (self.pending_messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.pending_messages.clearRetainingCapacity();
    }

    fn freeModels(self: *CodexManager) void {
        if (self.models) |models| {
            for (models) |m| {
                self.allocator.free(m.id);
                if (m.model) |model| self.allocator.free(model);
                if (m.display_name) |dn| self.allocator.free(dn);
                if (m.description) |d| self.allocator.free(d);
                if (m.supported_reasoning_efforts) |efforts| self.allocator.free(efforts);
            }
            self.allocator.free(models);
            self.models = null;
        }
        if (self.current_model) |cm| {
            self.allocator.free(cm);
            self.current_model = null;
        }
    }

    fn freeMcpServers(self: *CodexManager) void {
        if (self.mcp_servers) |mcp| {
            for (mcp.servers) |entry| {
                self.allocator.free(entry.name);
                self.allocator.free(entry.state);
            }
            self.allocator.free(mcp.servers);
            if (mcp.ready) |ready| {
                for (ready) |r| self.allocator.free(r);
                self.allocator.free(ready);
            }
            if (mcp.failed) |failed| {
                for (failed) |f| self.allocator.free(f);
                self.allocator.free(failed);
            }
            self.mcp_servers = null;
        }
    }

    fn parseThreadFromValue(self: *CodexManager, thread_val: std.json.Value, fail_err: Error) Error!protocol.Thread {
        var thread_json_buf: std.ArrayList(u8) = .{};
        defer thread_json_buf.deinit(self.allocator);
        const tw = thread_json_buf.writer(self.allocator);
        tw.print("{f}", .{std.json.fmt(thread_val, .{})}) catch return fail_err;

        var wrapper_buf: std.ArrayList(u8) = .{};
        defer wrapper_buf.deinit(self.allocator);
        const ww = wrapper_buf.writer(self.allocator);
        ww.print("{{\"data\":[{s}]}}", .{thread_json_buf.items}) catch return fail_err;

        var decoder = codec.Decoder.init(self.allocator);
        const list_result = decoder.parseThreadListResult(wrapper_buf.items) catch return fail_err;

        if (list_result.data.len > 0) {
            const thread = list_result.data[0];
            if (list_result.data.len > 1) {
                for (list_result.data[1..]) |t| {
                    self.allocator.free(t.id);
                }
            }
            self.allocator.free(list_result.data);
            return thread;
        }
        self.allocator.free(list_result.data);
        return fail_err;
    }

    fn parseTokenUsageNotification(self: *CodexManager, json: []const u8) ?CodexEvent {
        var decoder = codec.Decoder.init(self.allocator);
        const result = decoder.parseTokenUsage(json) catch return null;

        // Free the string fields we don't need to store
        self.allocator.free(result.thread_id);
        if (result.turn_id) |tid| self.allocator.free(tid);

        // Store on manager state
        self.token_usage = result.token_usage;

        return .{ .token_usage_updated = result.token_usage };
    }

    fn parseRateLimitsNotification(self: *CodexManager, json: []const u8) ?CodexEvent {
        // The params JSON has shape: {"rateLimits": {...}} or {"rate_limits": {...}}
        // Extract the inner object for the decoder.
        const RawWrapper = struct {
            rateLimits: ?std.json.Value = null,
            rate_limits: ?std.json.Value = null,
        };

        const parsed = std.json.parseFromSlice(RawWrapper, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return null;
        defer parsed.deinit();

        const rate_limits_value = parsed.value.rateLimits orelse parsed.value.rate_limits;
        if (rate_limits_value) |rl_val| {
            // Serialize the inner object back to JSON for the decoder
            var buf: std.ArrayList(u8) = .{};
            defer buf.deinit(self.allocator);
            const writer = buf.writer(self.allocator);
            writer.print("{f}", .{std.json.fmt(rl_val, .{})}) catch return null;

            var decoder = codec.Decoder.init(self.allocator);
            const rate_limits = decoder.parseRateLimits(buf.items) catch return null;

            self.rate_limits = rate_limits;
            return .{ .rate_limits_updated = rate_limits };
        }

        return null;
    }

    fn parseMcpStatusEvent(self: *CodexManager, method: []const u8, params_json: ?[]const u8) ?CodexEvent {
        const json = params_json orelse return null;

        if (std.mem.eql(u8, method, "codex/event/mcp_startup_update")) {
            // Parse: {"msg":{"type":"mcp_startup_update","server":"name","status":{"state":"starting"}}}
            const RawMsg = struct {
                msg: ?struct {
                    server: ?[]const u8 = null,
                    status: ?struct {
                        state: ?[]const u8 = null,
                    } = null,
                } = null,
            };

            const parsed = std.json.parseFromSlice(RawMsg, self.allocator, json, .{
                .ignore_unknown_fields = true,
            }) catch return null;
            defer parsed.deinit();

            if (parsed.value.msg) |msg| {
                const server_name = msg.server orelse return null;
                const state = if (msg.status) |s| s.state orelse "unknown" else "unknown";

                // Initialize mcp_servers if needed
                if (self.mcp_servers == null) {
                    const servers = self.allocator.alloc(McpServerEntry, 0) catch return null;
                    self.mcp_servers = .{
                        .servers = servers,
                        .complete = false,
                        .ready = null,
                        .failed = null,
                    };
                }

                // Check if server already exists, update it; else add new
                var found = false;
                if (self.mcp_servers) |*mcp| {
                    for (mcp.servers) |*entry| {
                        if (std.mem.eql(u8, entry.name, server_name)) {
                            self.allocator.free(entry.state);
                            entry.state = self.allocator.dupe(u8, state) catch return null;
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        const new_name = self.allocator.dupe(u8, server_name) catch return null;
                        const new_state = self.allocator.dupe(u8, state) catch {
                            self.allocator.free(new_name);
                            return null;
                        };
                        const new_entry = McpServerEntry{ .name = new_name, .state = new_state };
                        const old_len = mcp.servers.len;
                        const new_servers = self.allocator.alloc(McpServerEntry, old_len + 1) catch {
                            self.allocator.free(new_name);
                            self.allocator.free(new_state);
                            return null;
                        };
                        @memcpy(new_servers[0..old_len], mcp.servers);
                        new_servers[old_len] = new_entry;
                        self.allocator.free(mcp.servers);
                        mcp.servers = new_servers;
                    }
                }

                return .{ .mcp_server_status = {} };
            }
        } else if (std.mem.eql(u8, method, "codex/event/mcp_startup_complete")) {
            // Parse: {"msg":{"type":"mcp_startup_complete","ready":["name"],"failed":[],"cancelled":[]}}
            const RawComplete = struct {
                msg: ?struct {
                    ready: ?[]const []const u8 = null,
                    failed: ?[]const []const u8 = null,
                } = null,
            };

            const parsed = std.json.parseFromSlice(RawComplete, self.allocator, json, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch return null;
            defer parsed.deinit();

            if (parsed.value.msg) |msg| {
                if (self.mcp_servers == null) {
                    const servers = self.allocator.alloc(McpServerEntry, 0) catch return null;
                    self.mcp_servers = .{
                        .servers = servers,
                        .complete = false,
                        .ready = null,
                        .failed = null,
                    };
                }

                if (self.mcp_servers) |*mcp| {
                    mcp.complete = true;

                    // Store ready list
                    if (msg.ready) |ready| {
                        if (mcp.ready) |old_ready| {
                            for (old_ready) |r| self.allocator.free(r);
                            self.allocator.free(old_ready);
                        }
                        const new_ready = self.allocator.alloc([]const u8, ready.len) catch return .{ .mcp_server_status = {} };
                        for (ready, 0..) |r, i| {
                            new_ready[i] = self.allocator.dupe(u8, r) catch {
                                // Partial cleanup on failure
                                for (new_ready[0..i]) |nr| self.allocator.free(nr);
                                self.allocator.free(new_ready);
                                return .{ .mcp_server_status = {} };
                            };
                        }
                        mcp.ready = new_ready;

                        // Update server states to "ready" for matching servers
                        for (mcp.servers) |*entry| {
                            for (ready) |r| {
                                if (std.mem.eql(u8, entry.name, r)) {
                                    self.allocator.free(entry.state);
                                    entry.state = self.allocator.dupe(u8, "ready") catch break;
                                    break;
                                }
                            }
                        }
                    }

                    // Store failed list
                    if (msg.failed) |failed| {
                        if (mcp.failed) |old_failed| {
                            for (old_failed) |f| self.allocator.free(f);
                            self.allocator.free(old_failed);
                        }
                        const new_failed = self.allocator.alloc([]const u8, failed.len) catch return .{ .mcp_server_status = {} };
                        for (failed, 0..) |f, i| {
                            new_failed[i] = self.allocator.dupe(u8, f) catch {
                                for (new_failed[0..i]) |nf| self.allocator.free(nf);
                                self.allocator.free(new_failed);
                                return .{ .mcp_server_status = {} };
                            };
                        }
                        mcp.failed = new_failed;

                        // Update server states to "failed" for matching servers
                        for (mcp.servers) |*entry| {
                            for (failed) |f| {
                                if (std.mem.eql(u8, entry.name, f)) {
                                    self.allocator.free(entry.state);
                                    entry.state = self.allocator.dupe(u8, "failed") catch break;
                                    break;
                                }
                            }
                        }
                    }
                }

                return .{ .mcp_server_status = {} };
            }
        }

        return null;
    }

    fn processServerRequest(self: *CodexManager, req: codec.ServerRequest) ?CodexEvent {
        const ApprovalMethod = enum {
            command_approval,
            file_change_approval,
            user_input,
        };

        const approval_map = std.StaticStringMap(ApprovalMethod).initComptime(.{
            .{ "item/commandExecution/requestApproval", .command_approval },
            .{ "item/fileChange/requestApproval", .file_change_approval },
            .{ "tool/requestUserInput", .user_input },
        });

        if (approval_map.get(req.method)) |approval_type| {
            const json = req.params_json orelse return .{ .unknown = {} };
            return switch (approval_type) {
                .command_approval => self.parseCommandApprovalRequest(req.id, json),
                .file_change_approval => self.parseFileChangeApprovalRequest(req.id, json),
                .user_input => self.parseUserInputRequest(req.id, json),
            };
        }

        // Fall through to notification processing for non-approval server requests
        return self.processNotification(req.method, req.params_json);
    }

    fn parseCommandApprovalRequest(self: *CodexManager, request_id: codec.RequestId, json: []const u8) ?CodexEvent {
        var decoder = codec.Decoder.init(self.allocator);
        const params = decoder.parseCommandApproval(json) catch return null;

        // Free any existing pending approval
        self.freePendingApproval();

        self.pending_approval = .{ .command = .{
            .request_id = dupeRequestId(self.allocator, request_id) catch return null,
            .item_id = params.item_id,
            .thread_id = params.thread_id,
            .turn_id = params.turn_id,
            .command = params.command,
            .cwd = params.cwd,
            .reason = params.reason,
            .selected_decision = .accept,
        } };

        return .{ .approval_requested = {} };
    }

    fn parseFileChangeApprovalRequest(self: *CodexManager, request_id: codec.RequestId, json: []const u8) ?CodexEvent {
        var decoder = codec.Decoder.init(self.allocator);
        const params = decoder.parseFileChangeApproval(json) catch return null;

        self.freePendingApproval();

        self.pending_approval = .{ .file_change = .{
            .request_id = dupeRequestId(self.allocator, request_id) catch return null,
            .item_id = params.item_id,
            .thread_id = params.thread_id,
            .turn_id = params.turn_id,
            .path = params.path,
            .selected_decision = .accept,
        } };

        return .{ .approval_requested = {} };
    }

    fn parseUserInputRequest(self: *CodexManager, request_id: codec.RequestId, json: []const u8) ?CodexEvent {
        var decoder = codec.Decoder.init(self.allocator);
        const params = decoder.parseUserInput(json) catch return null;

        self.freePendingApproval();

        const questions = self.allocator.alloc(UserInputQuestion, params.questions.len) catch return null;
        for (params.questions, 0..) |q, i| {
            questions[i] = .{
                .id = q.id,
                .header = q.header,
                .question = q.question,
                .options = q.options,
                .is_other = q.is_other,
                .selected_index = 0,
            };
        }
        // params.questions shell is freed but inner strings are now owned by our questions
        self.allocator.free(params.questions);

        self.pending_approval = .{ .user_input = .{
            .request_id = dupeRequestId(self.allocator, request_id) catch return null,
            .thread_id = params.thread_id,
            .turn_id = params.turn_id,
            .questions = questions,
            .active_question = 0,
        } };

        return .{ .approval_requested = {} };
    }

    fn processNotification(self: *CodexManager, method: []const u8, params_json: ?[]const u8) ?CodexEvent {
        // Exception to AD-3: MCP startup events have no high-level equivalent
        if (std.mem.startsWith(u8, method, "codex/event/mcp_startup")) {
            return self.parseMcpStatusEvent(method, params_json);
        }

        // Filter out codex/event/* low-level notifications (AD-3)
        if (std.mem.startsWith(u8, method, "codex/event/")) return null;

        const Method = enum {
            agent_message_delta,
            reasoning_delta,
            command_output_delta,
            item_started,
            item_completed,
            turn_completed,
            plan_updated,
            token_usage_updated,
            rate_limits_updated,
        };

        const method_map = std.StaticStringMap(Method).initComptime(.{
            .{ "item/agentMessage/delta", .agent_message_delta },
            .{ "item/reasoning/summaryTextDelta", .reasoning_delta },
            .{ "item/commandExecution/outputDelta", .command_output_delta },
            .{ "item/started", .item_started },
            .{ "item/completed", .item_completed },
            .{ "turn/completed", .turn_completed },
            .{ "turn/planUpdated", .plan_updated },
            .{ "turn/plan_updated", .plan_updated },
            .{ "thread/planUpdated", .plan_updated },
            .{ "thread/plan_updated", .plan_updated },
            .{ "thread/tokenUsage/updated", .token_usage_updated },
            .{ "thread/token_usage/updated", .token_usage_updated },
            .{ "account/rateLimits/updated", .rate_limits_updated },
            .{ "account/rate_limits/updated", .rate_limits_updated },
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
            .plan_updated => self.parsePlanUpdated(json),
            .token_usage_updated => self.parseTokenUsageNotification(json),
            .rate_limits_updated => self.parseRateLimitsNotification(json),
        };
    }

    const DeltaTag = enum { text_delta, reasoning_delta, command_output_delta };

    fn parseDeltaEvent(self: *CodexManager, json: []const u8, tag: DeltaTag) ?CodexEvent {
        const RawDelta = struct {
            threadId: ?[]const u8 = null,
            turnId: ?[]const u8 = null,
            itemId: ?[]const u8 = null,
            delta: ?[]const u8 = null,
        };

        // Parse and then immediately duplicate fields used by downstream consumers.
        const parsed = std.json.parseFromSlice(RawDelta, self.allocator, json, .{
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();

        const r = parsed.value;
        const delta_text = r.delta orelse "";

        // Update turn_id if we see one from the server
        if (r.turnId) |tid| {
            if (self.turn_id == null) {
                self.turn_id = self.allocator.dupe(u8, tid) catch null;
            }
        }

        const owned_thread_id = self.allocator.dupe(u8, r.threadId orelse "") catch return null;
        errdefer self.allocator.free(owned_thread_id);
        const owned_turn_id = self.allocator.dupe(u8, r.turnId orelse "") catch return null;
        errdefer self.allocator.free(owned_turn_id);
        const owned_item_id = self.allocator.dupe(u8, r.itemId orelse "") catch return null;
        errdefer self.allocator.free(owned_item_id);
        const owned_delta = self.allocator.dupe(u8, delta_text) catch return null;
        errdefer self.allocator.free(owned_delta);

        const event = CodexEvent.DeltaEvent{
            .thread_id = owned_thread_id,
            .turn_id = owned_turn_id,
            .item_id = owned_item_id,
            .delta = owned_delta,
        };

        return switch (tag) {
            .text_delta => .{ .text_delta = event },
            .reasoning_delta => .{ .reasoning_delta = event },
            .command_output_delta => .{ .command_output_delta = event },
        };
    }

    const ItemTag = enum { item_started, item_completed };

    fn parseItemEvent(self: *CodexManager, json: []const u8, tag: ItemTag) ?CodexEvent {
        // Parse and then immediately duplicate fields used by downstream consumers.
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

        const owned_thread_id = self.allocator.dupe(u8, r.threadId orelse "") catch return null;
        errdefer self.allocator.free(owned_thread_id);
        const owned_turn_id = self.allocator.dupe(u8, r.turnId orelse "") catch return null;
        errdefer self.allocator.free(owned_turn_id);
        const item = convertCompactItemOwned(self.allocator, raw_item) catch return null;
        errdefer freeOwnedItem(self.allocator, item);

        const event = CodexEvent.ItemEvent{
            .thread_id = owned_thread_id,
            .turn_id = owned_turn_id,
            .item = item,
        };

        return switch (tag) {
            .item_started => .{ .item_started = event },
            .item_completed => .{ .item_completed = event },
        };
    }

    fn parseTurnCompleted(self: *CodexManager, json: []const u8) ?CodexEvent {
        // Parse and then immediately duplicate fields used by downstream consumers.
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

        const owned_thread_id = self.allocator.dupe(u8, r.threadId orelse "") catch return null;
        errdefer self.allocator.free(owned_thread_id);
        const owned_turn_id = self.allocator.dupe(u8, raw_turn.id) catch return null;
        errdefer self.allocator.free(owned_turn_id);

        return .{ .turn_completed = .{
            .thread_id = owned_thread_id,
            .turn = .{
                .id = owned_turn_id,
                .status = if (raw_turn.status) |s| protocol.TurnStatus.fromString(s) else null,
            },
        } };
    }

    fn parsePlanUpdated(self: *CodexManager, json: []const u8) ?CodexEvent {
        const RawPlanEntry = struct {
            content: ?[]const u8 = null,
            step: ?[]const u8 = null,
            title: ?[]const u8 = null,
            status: ?[]const u8 = null,
            state: ?[]const u8 = null,
            priority: ?[]const u8 = null,
        };

        const RawPlan = struct {
            entries: ?[]RawPlanEntry = null,
            steps: ?[]RawPlanEntry = null,
        };

        const RawPlanUpdated = struct {
            threadId: ?[]const u8 = null,
            turnId: ?[]const u8 = null,
            entries: ?[]RawPlanEntry = null,
            steps: ?[]RawPlanEntry = null,
            plan: ?RawPlan = null,
        };

        const parsed = std.json.parseFromSlice(RawPlanUpdated, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return null;
        defer parsed.deinit();

        const raw = parsed.value;
        const raw_entries = if (raw.entries) |entries|
            entries
        else if (raw.steps) |steps|
            steps
        else if (raw.plan) |plan|
            if (plan.entries) |entries| entries else if (plan.steps) |steps| steps else return null
        else
            return null;

        const owned_thread_id = self.allocator.dupe(u8, raw.threadId orelse "") catch return null;
        errdefer self.allocator.free(owned_thread_id);
        const owned_turn_id = self.allocator.dupe(u8, raw.turnId orelse "") catch return null;
        errdefer self.allocator.free(owned_turn_id);

        const entries = self.allocator.alloc(CodexEvent.PlanUpdatedEvent.PlanEntry, raw_entries.len) catch return null;
        var copied: usize = 0;
        errdefer {
            for (entries[0..copied]) |entry| self.allocator.free(entry.content);
            self.allocator.free(entries);
        }

        for (raw_entries) |entry| {
            const content_text = entry.content orelse entry.step orelse entry.title orelse continue;
            const content = self.allocator.dupe(u8, content_text) catch continue;
            entries[copied] = .{
                .content = content,
                .status = parsePlanStatus(entry.status orelse entry.state),
                .priority = parsePlanPriority(entry.priority),
            };
            copied += 1;
        }

        return .{ .plan_updated = .{
            .thread_id = owned_thread_id,
            .turn_id = owned_turn_id,
            .entries = entries[0..copied],
        } };
    }

    fn parsePlanStatus(raw_status: ?[]const u8) CodexEvent.PlanUpdatedEvent.PlanEntryStatus {
        const status = raw_status orelse return .pending;
        if (std.mem.eql(u8, status, "in-progress")) return .in_progress;
        if (std.mem.eql(u8, status, "running")) return .in_progress;
        if (std.mem.eql(u8, status, "done")) return .completed;
        if (std.mem.eql(u8, status, "in_progress")) return .in_progress;
        if (std.mem.eql(u8, status, "completed")) return .completed;
        return .pending;
    }

    fn parsePlanPriority(raw_priority: ?[]const u8) CodexEvent.PlanUpdatedEvent.PlanEntryPriority {
        const priority = raw_priority orelse return .medium;
        if (std.mem.eql(u8, priority, "high")) return .high;
        if (std.mem.eql(u8, priority, "low")) return .low;
        return .medium;
    }

    /// Compact item structure for low-overhead parsing.
    const RawItemCompact = struct {
        type: ?[]const u8 = null,
        id: ?[]const u8 = null,
        callId: ?[]const u8 = null,
        name: ?[]const u8 = null,
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

    fn convertCompactItemOwned(allocator: Allocator, raw: RawItemCompact) Allocator.Error!protocol.Item {
        const item_type = raw.type orelse return .{ .unknown = {} };
        const item_id = raw.id orelse raw.callId orelse "";
        const owned_id = try allocator.dupe(u8, item_id);
        errdefer allocator.free(owned_id);

        const map = std.StaticStringMap(enum {
            user_message,
            agent_message,
            reasoning,
            command_execution,
            file_change,
            mcp_tool_call,
            function_call,
        }).initComptime(.{
            .{ "userMessage", .user_message },
            .{ "agentMessage", .agent_message },
            .{ "reasoning", .reasoning },
            .{ "commandExecution", .command_execution },
            .{ "fileChange", .file_change },
            .{ "mcpToolCall", .mcp_tool_call },
            .{ "functionCall", .function_call },
            .{ "function_call", .function_call },
            .{ "functionCallOutput", .function_call },
            .{ "function_call_output", .function_call },
        });

        const variant = map.get(item_type) orelse return .{ .unknown = {} };

        return switch (variant) {
            .user_message => .{ .user_message = .{ .id = owned_id } },
            .agent_message => blk: {
                const owned_text = try allocator.dupe(u8, raw.text orelse "");
                errdefer allocator.free(owned_text);
                break :blk .{ .agent_message = .{
                    .id = owned_id,
                    .text = owned_text,
                } };
            },
            .reasoning => .{ .reasoning = .{
                .id = owned_id,
                .summary = &.{},
                .content = &.{},
            } },
            .command_execution => blk: {
                const owned_command = if (raw.command) |v| try allocator.dupe(u8, v) else null;
                errdefer if (owned_command) |v| allocator.free(v);
                const owned_cwd = if (raw.cwd) |v| try allocator.dupe(u8, v) else null;
                errdefer if (owned_cwd) |v| allocator.free(v);
                const owned_stdout = if (raw.stdout) |v| try allocator.dupe(u8, v) else null;
                errdefer if (owned_stdout) |v| allocator.free(v);
                const owned_stderr = if (raw.stderr) |v| try allocator.dupe(u8, v) else null;
                errdefer if (owned_stderr) |v| allocator.free(v);
                break :blk .{ .command_execution = .{
                    .id = owned_id,
                    .command = owned_command,
                    .cwd = owned_cwd,
                    .exit_code = raw.exitCode,
                    .stdout = owned_stdout,
                    .stderr = owned_stderr,
                    .status = if (raw.status) |s| protocol.CommandExecutionStatus.fromString(s) orelse .pending else .pending,
                } };
            },
            .file_change => blk: {
                const owned_path = if (raw.path) |v| try allocator.dupe(u8, v) else null;
                errdefer if (owned_path) |v| allocator.free(v);
                const owned_diff = if (raw.diff) |v| try allocator.dupe(u8, v) else null;
                errdefer if (owned_diff) |v| allocator.free(v);
                const owned_status = if (raw.status) |v| try allocator.dupe(u8, v) else null;
                errdefer if (owned_status) |v| allocator.free(v);
                break :blk .{ .file_change = .{
                    .id = owned_id,
                    .path = owned_path,
                    .diff = owned_diff,
                    .status = owned_status,
                } };
            },
            .mcp_tool_call => blk: {
                const owned_server_name = if (raw.serverName) |v| try allocator.dupe(u8, v) else null;
                errdefer if (owned_server_name) |v| allocator.free(v);
                const owned_tool_name = if (raw.toolName) |v| try allocator.dupe(u8, v) else null;
                errdefer if (owned_tool_name) |v| allocator.free(v);
                const owned_arguments = if (raw.arguments) |v| try allocator.dupe(u8, v) else null;
                errdefer if (owned_arguments) |v| allocator.free(v);
                const owned_output = if (raw.output) |v| try allocator.dupe(u8, v) else null;
                errdefer if (owned_output) |v| allocator.free(v);
                const owned_status = if (raw.status) |v| try allocator.dupe(u8, v) else null;
                errdefer if (owned_status) |v| allocator.free(v);
                break :blk .{ .mcp_tool_call = .{
                    .id = owned_id,
                    .server_name = owned_server_name,
                    .tool_name = owned_tool_name,
                    .arguments = owned_arguments,
                    .output = owned_output,
                    .status = owned_status,
                } };
            },
            .function_call => blk: {
                const owned_call_id = if (raw.callId) |v| try allocator.dupe(u8, v) else null;
                errdefer if (owned_call_id) |v| allocator.free(v);
                const owned_name = if (raw.name) |v| try allocator.dupe(u8, v) else null;
                errdefer if (owned_name) |v| allocator.free(v);
                const owned_arguments = if (raw.arguments) |v| try allocator.dupe(u8, v) else null;
                errdefer if (owned_arguments) |v| allocator.free(v);
                const owned_output = if (raw.output) |v| try allocator.dupe(u8, v) else null;
                errdefer if (owned_output) |v| allocator.free(v);
                const owned_status = if (raw.status) |v| try allocator.dupe(u8, v) else null;
                errdefer if (owned_status) |v| allocator.free(v);
                break :blk .{ .function_call = .{
                    .id = owned_id,
                    .call_id = owned_call_id,
                    .name = owned_name,
                    .arguments = owned_arguments,
                    .output = owned_output,
                    .status = owned_status,
                } };
            },
        };
    }
};

fn freeOwnedItem(allocator: Allocator, item: protocol.Item) void {
    switch (item) {
        .user_message => |u| allocator.free(u.id),
        .agent_message => |a| {
            allocator.free(a.id);
            allocator.free(a.text);
        },
        .reasoning => |r| {
            allocator.free(r.id);
        },
        .command_execution => |c| {
            allocator.free(c.id);
            if (c.command) |v| allocator.free(v);
            if (c.cwd) |v| allocator.free(v);
            if (c.stdout) |v| allocator.free(v);
            if (c.stderr) |v| allocator.free(v);
        },
        .file_change => |f| {
            allocator.free(f.id);
            if (f.path) |v| allocator.free(v);
            if (f.diff) |v| allocator.free(v);
            if (f.status) |v| allocator.free(v);
        },
        .mcp_tool_call => |m| {
            allocator.free(m.id);
            if (m.server_name) |v| allocator.free(v);
            if (m.tool_name) |v| allocator.free(v);
            if (m.arguments) |v| allocator.free(v);
            if (m.output) |v| allocator.free(v);
            if (m.status) |v| allocator.free(v);
        },
        .function_call => |f| {
            allocator.free(f.id);
            if (f.call_id) |v| allocator.free(v);
            if (f.name) |v| allocator.free(v);
            if (f.arguments) |v| allocator.free(v);
            if (f.output) |v| allocator.free(v);
            if (f.status) |v| allocator.free(v);
        },
        .unknown => {},
    }
}

// =============================================================================
// Standalone helpers
// =============================================================================

fn dupeRequestId(allocator: Allocator, id: codec.RequestId) Allocator.Error!codec.RequestId {
    return switch (id) {
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .number => |n| .{ .number = n },
        .null_value => .{ .null_value = {} },
    };
}

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

fn consumeProcessEventForTest(manager: *CodexManager, msg: codec.DecodedMessage) void {
    var event = manager.processMessage(msg);
    if (event) |*e| manager.deinitEvent(e);
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
        \\{"method":"item/agentMessage/delta","params":{"threadId":"t1","turnId":"turn-1","itemId":"item-1","delta":"Hello"}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    var event = manager.processMessage(msg);
    defer if (event) |*e| manager.deinitEvent(e);
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

    var event = manager.processMessage(msg);
    defer if (event) |*e| manager.deinitEvent(e);
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

    var event = manager.processMessage(msg);
    defer if (event) |*e| manager.deinitEvent(e);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .turn_completed);
    try std.testing.expectEqual(CodexManager.Status.thread_active, manager.status);
}

test "processMessage with reasoning delta returns reasoning_delta" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"item/reasoning/summaryTextDelta","params":{"threadId":"t1","turnId":"turn-1","itemId":"item-2","delta":"Thinking..."}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    var event = manager.processMessage(msg);
    defer if (event) |*e| manager.deinitEvent(e);
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

    var event = manager.processMessage(msg);
    defer if (event) |*e| manager.deinitEvent(e);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .item_started);
    try std.testing.expect(event.?.item_started.item == .command_execution);
}

test "processMessage with function call item parses call_id fallback" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"item/started","params":{"threadId":"t1","turnId":"turn-1","item":{"type":"functionCall","callId":"call_123","name":"spawn_agent","arguments":"{\"agent_type\":\"explorer\"}"}}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    var event = manager.processMessage(msg);
    defer if (event) |*e| manager.deinitEvent(e);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .item_started);
    try std.testing.expect(event.?.item_started.item == .function_call);
    const fc = event.?.item_started.item.function_call;
    try std.testing.expectEqualStrings("call_123", fc.id);
    try std.testing.expectEqualStrings("spawn_agent", fc.name.?);
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

    var event = manager.processMessage(msg);
    defer if (event) |*e| manager.deinitEvent(e);
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

    var event = manager.processMessage(msg);
    defer if (event) |*e| manager.deinitEvent(e);
    try std.testing.expect(event == null);
}

test "processMessage turn_id tracking from delta events" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    try std.testing.expect(manager.turn_id == null);

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"item/agentMessage/delta","params":{"threadId":"t1","turnId":"my-turn","itemId":"item-1","delta":"Hi"}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    consumeProcessEventForTest(&manager, msg);
    try std.testing.expect(manager.turn_id != null);
    try std.testing.expectEqualStrings("my-turn", manager.turn_id.?);
}

test "codex manager handshake" {
    if (!codexAvailable()) return;

    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.connect("codex", &.{"app-server"}, "/home/ctdio/projects/open-source/skim-wta");

    try std.testing.expectEqual(CodexManager.Status.initialized, manager.status);
    try std.testing.expect(manager.process != null);
    try std.testing.expect(manager.transport != null);
}

test "codex manager thread start" {
    if (!codexAvailable()) return;

    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.connect("codex", &.{"app-server"}, "/home/ctdio/projects/open-source/skim-wta");
    try std.testing.expectEqual(CodexManager.Status.initialized, manager.status);

    try manager.startThread(null, "/home/ctdio/projects/open-source/skim-wta");
    try std.testing.expectEqual(CodexManager.Status.thread_active, manager.status);
    try std.testing.expect(manager.thread_id != null);
    try std.testing.expect(manager.model != null);
}

// =============================================================================
// Phase 4: Approval Tests
// =============================================================================

test "processMessage with command approval server request stores pending approval" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"item/commandExecution/requestApproval","id":"req_cmd_1","params":{"threadId":"t1","turnId":"turn-1","itemId":"item-1","command":"ls -la","cwd":"/home/user","reason":"needs file listing"}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    try std.testing.expect(manager.pending_approval == null);
    var event = manager.processMessage(msg);
    defer if (event) |*e| manager.deinitEvent(e);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .approval_requested);
    try std.testing.expect(manager.pending_approval != null);

    const approval = manager.pending_approval.?;
    switch (approval) {
        .command => |cmd| {
            try std.testing.expectEqualStrings("t1", cmd.thread_id);
            try std.testing.expectEqualStrings("turn-1", cmd.turn_id.?);
            try std.testing.expectEqualStrings("item-1", cmd.item_id.?);
            try std.testing.expectEqualStrings("ls -la", cmd.command);
            try std.testing.expectEqualStrings("/home/user", cmd.cwd.?);
            try std.testing.expectEqualStrings("needs file listing", cmd.reason.?);
            try std.testing.expect(cmd.selected_decision == .accept);
        },
        else => try std.testing.expect(false),
    }
}

test "processMessage with file change approval server request stores pending approval" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"item/fileChange/requestApproval","id":"req_fc_1","params":{"threadId":"t1","turnId":"turn-1","itemId":"item-2","path":"/home/user/file.zig"}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    var event = manager.processMessage(msg);
    defer if (event) |*e| manager.deinitEvent(e);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .approval_requested);

    switch (manager.pending_approval.?) {
        .file_change => |fc| {
            try std.testing.expectEqualStrings("t1", fc.thread_id);
            try std.testing.expectEqualStrings("/home/user/file.zig", fc.path);
            try std.testing.expect(fc.selected_decision == .accept);
        },
        else => try std.testing.expect(false),
    }
}

test "processMessage with user input server request stores pending approval" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"tool/requestUserInput","id":"req_ui_1","params":{"threadId":"t1","turnId":"turn-1","questions":[{"id":"q1","header":"Choose auth","question":"Which auth method?","options":[{"label":"OAuth 2.0","description":"Standard OAuth"},{"label":"API Key"}],"isOther":false,"isSecret":false}]}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    var event = manager.processMessage(msg);
    defer if (event) |*e| manager.deinitEvent(e);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .approval_requested);

    switch (manager.pending_approval.?) {
        .user_input => |ui| {
            try std.testing.expectEqualStrings("t1", ui.thread_id);
            try std.testing.expectEqual(@as(usize, 1), ui.questions.len);
            try std.testing.expectEqualStrings("q1", ui.questions[0].id);
            try std.testing.expectEqualStrings("Choose auth", ui.questions[0].header.?);
            try std.testing.expectEqualStrings("Which auth method?", ui.questions[0].question);
            try std.testing.expectEqual(@as(usize, 2), ui.questions[0].options.?.len);
            try std.testing.expectEqualStrings("OAuth 2.0", ui.questions[0].options.?[0].label);
            try std.testing.expectEqualStrings("Standard OAuth", ui.questions[0].options.?[0].description.?);
            try std.testing.expectEqualStrings("API Key", ui.questions[0].options.?[1].label);
            try std.testing.expect(ui.questions[0].options.?[1].description == null);
            try std.testing.expect(!ui.questions[0].is_other);
            try std.testing.expectEqual(@as(usize, 0), ui.active_question);
        },
        else => try std.testing.expect(false),
    }
}

test "new approval replaces existing pending approval" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);

    // First approval
    const json1 =
        \\{"method":"item/commandExecution/requestApproval","id":"req_1","params":{"threadId":"t1","command":"ls"}}
    ;
    var msg1 = try decoder.decode(json1);
    defer msg1.deinit(std.testing.allocator);
    consumeProcessEventForTest(&manager, msg1);
    try std.testing.expect(manager.pending_approval != null);

    // Second approval should replace the first
    const json2 =
        \\{"method":"item/fileChange/requestApproval","id":"req_2","params":{"threadId":"t1","path":"/tmp/file.txt"}}
    ;
    var msg2 = try decoder.decode(json2);
    defer msg2.deinit(std.testing.allocator);
    consumeProcessEventForTest(&manager, msg2);

    switch (manager.pending_approval.?) {
        .file_change => |fc| try std.testing.expectEqualStrings("/tmp/file.txt", fc.path),
        else => try std.testing.expect(false),
    }
}

test "pending approval with string request id" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"item/commandExecution/requestApproval","id":"req_string_123","params":{"threadId":"t1","command":"echo hello"}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    consumeProcessEventForTest(&manager, msg);
    try std.testing.expect(manager.pending_approval != null);

    switch (manager.pending_approval.?) {
        .command => |cmd| {
            switch (cmd.request_id) {
                .string => |s| try std.testing.expectEqualStrings("req_string_123", s),
                else => try std.testing.expect(false),
            }
        },
        else => try std.testing.expect(false),
    }
}

test "pending approval with numeric request id" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"item/commandExecution/requestApproval","id":42,"params":{"threadId":"t1","command":"echo hello"}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    consumeProcessEventForTest(&manager, msg);

    switch (manager.pending_approval.?.command.request_id) {
        .number => |n| try std.testing.expectEqual(@as(i64, 42), n),
        else => try std.testing.expect(false),
    }
}

test "freePendingApproval cleans up properly" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"item/commandExecution/requestApproval","id":"req_1","params":{"threadId":"t1","command":"ls","cwd":"/tmp","reason":"testing"}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    consumeProcessEventForTest(&manager, msg);
    try std.testing.expect(manager.pending_approval != null);

    manager.freePendingApproval();
    try std.testing.expect(manager.pending_approval == null);
}

test "disconnect clears pending approval" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"item/commandExecution/requestApproval","id":"req_1","params":{"threadId":"t1","command":"ls"}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    consumeProcessEventForTest(&manager, msg);
    try std.testing.expect(manager.pending_approval != null);

    manager.disconnect();
    try std.testing.expect(manager.pending_approval == null);
}

test "processMessage non-approval server request falls through to notification" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    // A server request with a notification-like method that isn't an approval
    const json =
        \\{"method":"item/agentMessage/delta","id":"req_99","params":{"threadId":"t1","turnId":"turn-1","itemId":"item-1","delta":"Hello"}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    var event = manager.processMessage(msg);
    defer if (event) |*e| manager.deinitEvent(e);
    try std.testing.expect(event != null);
    // Should fall through to notification processing and produce text_delta
    try std.testing.expect(event.? == .text_delta);
    try std.testing.expect(manager.pending_approval == null);
}

// =============================================================================
// Phase 5: Session & Model Tests
// =============================================================================

test "new fields initialize to null" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    try std.testing.expect(manager.models == null);
    try std.testing.expect(manager.current_model == null);
    try std.testing.expect(manager.requested_reasoning_effort == null);
    try std.testing.expect(manager.requested_service_tier == null);
    try std.testing.expect(manager.requested_collaboration_mode == null);
    try std.testing.expect(manager.service_tier == null);
    try std.testing.expect(manager.collaboration_mode == null);
}

test "setModel stores and frees model id" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    try std.testing.expect(manager.current_model == null);

    try manager.setModel("gpt-5.1-codex-mini");
    try std.testing.expectEqualStrings("gpt-5.1-codex-mini", manager.current_model.?);

    // Setting again should replace
    try manager.setModel("gpt-5.3-codex");
    try std.testing.expectEqualStrings("gpt-5.3-codex", manager.current_model.?);
}

test "setReasoningEffort stores effort level" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    try std.testing.expect(manager.reasoning_effort == null);
    try std.testing.expect(manager.requested_reasoning_effort == null);

    manager.setReasoningEffort(.high);
    try std.testing.expect(manager.reasoning_effort.? == .high);
    try std.testing.expect(manager.requested_reasoning_effort.? == .high);

    manager.setReasoningEffort(.low);
    try std.testing.expect(manager.reasoning_effort.? == .low);
    try std.testing.expect(manager.requested_reasoning_effort.? == .low);
}

test "setServiceTier stores service tier" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    try std.testing.expect(manager.service_tier == null);
    try std.testing.expect(manager.requested_service_tier == null);

    manager.setServiceTier(.fast);
    try std.testing.expect(manager.service_tier.? == .fast);
    try std.testing.expect(manager.requested_service_tier.? == .fast);

    manager.setServiceTier(.flex);
    try std.testing.expect(manager.service_tier.? == .flex);
    try std.testing.expect(manager.requested_service_tier.? == .flex);
}

test "cycleToNextMode stores collaboration mode" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    try std.testing.expectEqualStrings("Code", manager.getCurrentModeName());

    try std.testing.expectEqualStrings("Plan", manager.cycleToNextMode().?);
    try std.testing.expect(manager.collaboration_mode.? == .plan);
    try std.testing.expect(manager.requested_collaboration_mode.? == .plan);
    try std.testing.expectEqualStrings("Plan", manager.getCurrentModeName());

    try std.testing.expectEqualStrings("Code", manager.cycleToNextMode().?);
    try std.testing.expect(manager.collaboration_mode.? == .default);
    try std.testing.expect(manager.requested_collaboration_mode.? == .default);
    try std.testing.expectEqualStrings("Code", manager.getCurrentModeName());
}

test "listThreads fails when not connected" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    const result = manager.listThreads();
    try std.testing.expectError(error.NotConnected, result);
}

test "resumeThread fails when not connected" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    const result = manager.resumeThread("some-thread-id");
    try std.testing.expectError(error.NotConnected, result);
}

test "forkThread fails when not connected" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    const result = manager.forkThread("some-thread-id");
    try std.testing.expectError(error.NotConnected, result);
}

test "listModels fails when not connected" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    const result = manager.listModels();
    try std.testing.expectError(error.NotConnected, result);
}

test "freeModels cleans up properly" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    // Set a current_model
    try manager.setModel("test-model");
    try std.testing.expect(manager.current_model != null);

    manager.freeModels();
    try std.testing.expect(manager.current_model == null);
    try std.testing.expect(manager.models == null);
}

test "disconnect clears models" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.setModel("test-model");
    try std.testing.expect(manager.current_model != null);

    manager.disconnect();
    try std.testing.expect(manager.current_model == null);
    try std.testing.expect(manager.models == null);
}

test "freeThreadList handles empty list" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    // Create an empty thread list
    const threads = try std.testing.allocator.alloc(protocol.Thread, 0);
    manager.freeThreadList(threads);
}

// Integration tests with real codex binary

test "codex manager listThreads" {
    if (!codexAvailable()) return;

    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.connect("codex", &.{"app-server"}, "/home/ctdio/projects/open-source/skim-wta");
    try std.testing.expectEqual(CodexManager.Status.initialized, manager.status);

    const threads = try manager.listThreads();
    defer manager.freeThreadList(threads);

    // Should return a list (may be empty if no threads exist)
    // The important thing is it parsed successfully
}

test "codex manager listModels" {
    if (!codexAvailable()) return;

    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.connect("codex", &.{"app-server"}, "/home/ctdio/projects/open-source/skim-wta");
    try std.testing.expectEqual(CodexManager.Status.initialized, manager.status);

    const models = try manager.listModels();

    // Should have at least one model
    try std.testing.expect(models.len > 0);
    try std.testing.expect(manager.models != null);

    // Check that at least one model has an id
    try std.testing.expect(models[0].id.len > 0);

    // Check for default model
    var has_default = false;
    for (models) |m| {
        if (m.is_default) {
            has_default = true;
            break;
        }
    }
    try std.testing.expect(has_default);
}

// =============================================================================
// Phase 6: Advanced Features Tests
// =============================================================================

test "new phase 6 fields initialize to null" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    try std.testing.expect(manager.token_usage == null);
    try std.testing.expect(manager.rate_limits == null);
    try std.testing.expect(manager.mcp_servers == null);
}

test "processMessage with token usage notification stores usage and returns event" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"thread/tokenUsage/updated","params":{"threadId":"t1","turnId":"1","tokenUsage":{"total":{"totalTokens":16709,"inputTokens":16687,"cachedInputTokens":7936,"outputTokens":22,"reasoningOutputTokens":0},"last":{"totalTokens":500,"inputTokens":400,"cachedInputTokens":100,"outputTokens":100,"reasoningOutputTokens":50},"modelContextWindow":258400}}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    try std.testing.expect(manager.token_usage == null);
    var event = manager.processMessage(msg);
    defer if (event) |*e| manager.deinitEvent(e);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .token_usage_updated);

    // Verify stored state
    try std.testing.expect(manager.token_usage != null);
    const tu = manager.token_usage.?;
    try std.testing.expect(tu.total != null);
    try std.testing.expectEqual(@as(u64, 16709), tu.total.?.total_tokens);
    try std.testing.expectEqual(@as(u64, 16687), tu.total.?.input_tokens);
    try std.testing.expectEqual(@as(u64, 7936), tu.total.?.cached_input_tokens);
    try std.testing.expectEqual(@as(u64, 22), tu.total.?.output_tokens);
    try std.testing.expectEqual(@as(u64, 258400), tu.model_context_window.?);

    // Verify last usage
    try std.testing.expect(tu.last != null);
    try std.testing.expectEqual(@as(u64, 500), tu.last.?.total_tokens);
}

test "processMessage with turn/planUpdated returns plan_updated entries" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"turn/planUpdated","params":{"threadId":"t1","turnId":"turn-1","entries":[{"step":"Investigate rendering path","status":"completed","priority":"high"},{"content":"Wire codex plan updates","status":"in_progress","priority":"medium"}]}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    var event = manager.processMessage(msg);
    defer if (event) |*e| manager.deinitEvent(e);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .plan_updated);

    const plan = event.?.plan_updated;
    try std.testing.expectEqualStrings("t1", plan.thread_id);
    try std.testing.expectEqualStrings("turn-1", plan.turn_id);
    try std.testing.expectEqual(@as(usize, 2), plan.entries.len);
    try std.testing.expectEqualStrings("Investigate rendering path", plan.entries[0].content);
    try std.testing.expectEqual(CodexManager.CodexEvent.PlanUpdatedEvent.PlanEntryStatus.completed, plan.entries[0].status);
    try std.testing.expectEqual(CodexManager.CodexEvent.PlanUpdatedEvent.PlanEntryPriority.high, plan.entries[0].priority);
    try std.testing.expectEqual(CodexManager.CodexEvent.PlanUpdatedEvent.PlanEntryStatus.in_progress, plan.entries[1].status);
}

test "processMessage with thread/plan_updated parses nested plan steps" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"thread/plan_updated","params":{"threadId":"t1","turnId":"turn-2","plan":{"steps":[{"title":"First nested step","state":"running","priority":"high"},{"step":"Second nested step","state":"done","priority":"low"}]}}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    var event = manager.processMessage(msg);
    defer if (event) |*e| manager.deinitEvent(e);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .plan_updated);

    const plan = event.?.plan_updated;
    try std.testing.expectEqualStrings("t1", plan.thread_id);
    try std.testing.expectEqualStrings("turn-2", plan.turn_id);
    try std.testing.expectEqual(@as(usize, 2), plan.entries.len);
    try std.testing.expectEqualStrings("First nested step", plan.entries[0].content);
    try std.testing.expectEqual(CodexManager.CodexEvent.PlanUpdatedEvent.PlanEntryStatus.in_progress, plan.entries[0].status);
    try std.testing.expectEqual(CodexManager.CodexEvent.PlanUpdatedEvent.PlanEntryPriority.high, plan.entries[0].priority);
    try std.testing.expectEqualStrings("Second nested step", plan.entries[1].content);
    try std.testing.expectEqual(CodexManager.CodexEvent.PlanUpdatedEvent.PlanEntryStatus.completed, plan.entries[1].status);
    try std.testing.expectEqual(CodexManager.CodexEvent.PlanUpdatedEvent.PlanEntryPriority.low, plan.entries[1].priority);
}

test "processMessage with rate limits notification stores limits and returns event" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":42.5,"windowDurationMins":300,"resetsAt":1771349237},"secondary":{"usedPercent":1.0,"windowDurationMins":10080,"resetsAt":1771892798},"credits":{"hasCredits":false,"unlimited":false,"balance":null},"planType":null}}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    try std.testing.expect(manager.rate_limits == null);
    var event = manager.processMessage(msg);
    defer if (event) |*e| manager.deinitEvent(e);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .rate_limits_updated);

    // Verify stored state
    try std.testing.expect(manager.rate_limits != null);
    const rl = manager.rate_limits.?;
    try std.testing.expectApproxEqRel(@as(f64, 42.5), rl.primary.used_percent, 0.001);
    try std.testing.expectApproxEqRel(@as(f64, 1.0), rl.secondary.used_percent, 0.001);
}

test "processMessage with snake_case token usage notification stores usage" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"thread/token_usage/updated","params":{"thread_id":"t1","turn_id":"1","token_usage":{"total":{"total_tokens":2500,"input_tokens":2000,"cached_input_tokens":500,"output_tokens":500,"reasoning_output_tokens":0},"model_context_window":128000}}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    var event = manager.processMessage(msg);
    defer if (event) |*e| manager.deinitEvent(e);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .token_usage_updated);
    try std.testing.expect(manager.token_usage != null);
    try std.testing.expectEqual(@as(u64, 2500), manager.token_usage.?.total.?.total_tokens);
    try std.testing.expectEqual(@as(u64, 128000), manager.token_usage.?.model_context_window.?);
}

test "processMessage with snake_case rate limits notification stores limits" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"account/rate_limits/updated","params":{"rate_limits":{"primary":{"used_percent":10.5},"secondary":{"used_percent":2.25}}}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    var event = manager.processMessage(msg);
    defer if (event) |*e| manager.deinitEvent(e);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .rate_limits_updated);
    try std.testing.expect(manager.rate_limits != null);
    try std.testing.expectApproxEqRel(@as(f64, 10.5), manager.rate_limits.?.primary.used_percent, 0.001);
    try std.testing.expectApproxEqRel(@as(f64, 2.25), manager.rate_limits.?.secondary.used_percent, 0.001);
}

test "processMessage with MCP startup update creates server entry" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"codex/event/mcp_startup_update","params":{"msg":{"type":"mcp_startup_update","server":"codex_apps","status":{"state":"starting"}}}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    try std.testing.expect(manager.mcp_servers == null);
    var event = manager.processMessage(msg);
    defer if (event) |*e| manager.deinitEvent(e);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .mcp_server_status);

    // Verify stored state
    try std.testing.expect(manager.mcp_servers != null);
    const mcp = manager.mcp_servers.?;
    try std.testing.expectEqual(@as(usize, 1), mcp.servers.len);
    try std.testing.expectEqualStrings("codex_apps", mcp.servers[0].name);
    try std.testing.expectEqualStrings("starting", mcp.servers[0].state);
    try std.testing.expect(!mcp.complete);
}

test "processMessage with MCP startup complete marks completion" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);

    // First, send an update to create the server entry
    const update_json =
        \\{"method":"codex/event/mcp_startup_update","params":{"msg":{"type":"mcp_startup_update","server":"codex_apps","status":{"state":"starting"}}}}
    ;
    var update_msg = try decoder.decode(update_json);
    defer update_msg.deinit(std.testing.allocator);
    consumeProcessEventForTest(&manager, update_msg);

    // Then send completion
    const complete_json =
        \\{"method":"codex/event/mcp_startup_complete","params":{"msg":{"type":"mcp_startup_complete","ready":["codex_apps"],"failed":[],"cancelled":[]}}}
    ;
    var complete_msg = try decoder.decode(complete_json);
    defer complete_msg.deinit(std.testing.allocator);
    var event = manager.processMessage(complete_msg);
    defer if (event) |*e| manager.deinitEvent(e);
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .mcp_server_status);

    // Verify completion state
    const mcp = manager.mcp_servers.?;
    try std.testing.expect(mcp.complete);
    try std.testing.expect(mcp.ready != null);
    try std.testing.expectEqual(@as(usize, 1), mcp.ready.?.len);
    try std.testing.expectEqualStrings("codex_apps", mcp.ready.?[0]);

    // Server state should be updated to "ready"
    try std.testing.expectEqualStrings("ready", mcp.servers[0].state);
}

test "MCP startup update updates existing server entry" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);

    // First update
    const json1 =
        \\{"method":"codex/event/mcp_startup_update","params":{"msg":{"type":"mcp_startup_update","server":"test_server","status":{"state":"starting"}}}}
    ;
    var msg1 = try decoder.decode(json1);
    defer msg1.deinit(std.testing.allocator);
    consumeProcessEventForTest(&manager, msg1);

    try std.testing.expectEqualStrings("starting", manager.mcp_servers.?.servers[0].state);

    // Second update for same server
    const json2 =
        \\{"method":"codex/event/mcp_startup_update","params":{"msg":{"type":"mcp_startup_update","server":"test_server","status":{"state":"ready"}}}}
    ;
    var msg2 = try decoder.decode(json2);
    defer msg2.deinit(std.testing.allocator);
    consumeProcessEventForTest(&manager, msg2);

    // Should still have one entry with updated state
    try std.testing.expectEqual(@as(usize, 1), manager.mcp_servers.?.servers.len);
    try std.testing.expectEqualStrings("ready", manager.mcp_servers.?.servers[0].state);
}

test "compactThread fails when not connected" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    const result = manager.compactThread();
    try std.testing.expectError(error.NotConnected, result);
}

test "rollbackThread fails when not connected" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    const result = manager.rollbackThread("turn-1");
    try std.testing.expectError(error.NotConnected, result);
}

test "archiveThread fails when not connected" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    const result = manager.archiveThread("thread-1");
    try std.testing.expectError(error.NotConnected, result);
}

test "unarchiveThread fails when not connected" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    const result = manager.unarchiveThread("thread-1");
    try std.testing.expectError(error.NotConnected, result);
}

test "disconnect clears token usage and rate limits" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    // Set some token usage data via notification
    var decoder = codec.Decoder.init(std.testing.allocator);
    const tu_json =
        \\{"method":"thread/tokenUsage/updated","params":{"threadId":"t1","turnId":"1","tokenUsage":{"total":{"totalTokens":100,"inputTokens":90,"cachedInputTokens":0,"outputTokens":10,"reasoningOutputTokens":0},"modelContextWindow":100000}}}
    ;
    var tu_msg = try decoder.decode(tu_json);
    defer tu_msg.deinit(std.testing.allocator);
    consumeProcessEventForTest(&manager, tu_msg);
    try std.testing.expect(manager.token_usage != null);

    // Set rate limit data via notification
    const rl_json =
        \\{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":5.0},"secondary":{"usedPercent":0.0}}}}
    ;
    var rl_msg = try decoder.decode(rl_json);
    defer rl_msg.deinit(std.testing.allocator);
    consumeProcessEventForTest(&manager, rl_msg);
    try std.testing.expect(manager.rate_limits != null);

    manager.disconnect();
    try std.testing.expect(manager.token_usage == null);
    try std.testing.expect(manager.rate_limits == null);
    try std.testing.expect(manager.mcp_servers == null);
}

test "token usage updated event contains correct data" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    const json =
        \\{"method":"thread/tokenUsage/updated","params":{"threadId":"t1","turnId":"1","tokenUsage":{"total":{"totalTokens":5000,"inputTokens":4500,"cachedInputTokens":2000,"outputTokens":500,"reasoningOutputTokens":100},"last":{"totalTokens":1000,"inputTokens":900,"cachedInputTokens":0,"outputTokens":100,"reasoningOutputTokens":0},"modelContextWindow":128000}}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    var event = manager.processMessage(msg);
    defer if (event) |*e| manager.deinitEvent(e);
    try std.testing.expect(event != null);

    const tu_event = event.?.token_usage_updated;
    try std.testing.expect(tu_event.total != null);
    try std.testing.expectEqual(@as(u64, 5000), tu_event.total.?.total_tokens);
    try std.testing.expectEqual(@as(u64, 128000), tu_event.model_context_window.?);
}

test "other codex/event/* methods are still filtered" {
    var manager = CodexManager.init(std.testing.allocator);
    defer manager.deinit();

    var decoder = codec.Decoder.init(std.testing.allocator);
    // Non-MCP codex/event should still be filtered
    const json =
        \\{"method":"codex/event/some_other_event","params":{"data":"test"}}
    ;
    var msg = try decoder.decode(json);
    defer msg.deinit(std.testing.allocator);

    var event = manager.processMessage(msg);
    defer if (event) |*e| manager.deinitEvent(e);
    try std.testing.expect(event == null);
}
