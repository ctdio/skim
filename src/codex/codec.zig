const std = @import("std");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;

// =============================================================================
// Request ID
// =============================================================================

pub const RequestId = union(enum) {
    string: []const u8,
    number: i64,
    null_value: void,

    pub fn eql(self: RequestId, other: RequestId) bool {
        return switch (self) {
            .string => |s| switch (other) {
                .string => |o| std.mem.eql(u8, s, o),
                else => false,
            },
            .number => |n| switch (other) {
                .number => |o| n == o,
                else => false,
            },
            .null_value => switch (other) {
                .null_value => true,
                else => false,
            },
        };
    }
};

// =============================================================================
// Decoded Message Types
// =============================================================================

pub const ServerRequest = struct {
    id: RequestId,
    method: []const u8,
    params_json: ?[]const u8,
};

pub const Response = struct {
    id: ?RequestId,
    result_json: ?[]const u8,
    error_msg: ?protocol.JsonRpcError,
};

pub const Notification = struct {
    method: []const u8,
    params_json: ?[]const u8,
};

pub const DecodedMessage = union(enum) {
    server_request: ServerRequest,
    response: Response,
    notification: Notification,

    pub fn deinit(self: *DecodedMessage, allocator: Allocator) void {
        switch (self.*) {
            .server_request => |*r| {
                switch (r.id) {
                    .string => |s| allocator.free(s),
                    else => {},
                }
                allocator.free(r.method);
                if (r.params_json) |p| allocator.free(p);
            },
            .response => |*r| {
                if (r.id) |id| {
                    switch (id) {
                        .string => |s| allocator.free(s),
                        else => {},
                    }
                }
                if (r.result_json) |res| allocator.free(res);
                if (r.error_msg) |e| allocator.free(e.message);
            },
            .notification => |*n| {
                allocator.free(n.method);
                if (n.params_json) |p| allocator.free(p);
            },
        }
    }
};

// =============================================================================
// Encoder
// =============================================================================

pub const Encoder = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) Encoder {
        return .{ .allocator = allocator };
    }

    pub fn encodeInitialize(self: *Encoder, id: i64, params: protocol.InitializeParams) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.print("{{\"method\":\"initialize\",\"id\":{d},\"params\":{{\"clientInfo\":{{", .{id});

        var first = true;
        if (params.client_name) |name| {
            try writer.print("\"name\":{f}", .{std.json.fmt(name, .{})});
            first = false;
        }
        if (params.title) |title| {
            if (!first) try writer.writeByte(',');
            try writer.print("\"title\":{f}", .{std.json.fmt(title, .{})});
            first = false;
        }
        if (params.client_version) |version| {
            if (!first) try writer.writeByte(',');
            try writer.print("\"version\":{f}", .{std.json.fmt(version, .{})});
        }

        try writer.writeAll("}}}");
        return output.toOwnedSlice(self.allocator);
    }

    pub fn encodeInitialized(self: *Encoder) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.writeAll("{\"method\":\"initialized\"}");
        return output.toOwnedSlice(self.allocator);
    }

    pub fn encodeThreadStart(self: *Encoder, id: i64, params: protocol.ThreadStartParams) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.print("{{\"id\":{d},\"method\":\"thread/start\",\"params\":{{", .{id});

        var first = true;
        if (params.model) |model| {
            try writer.print("\"model\":{f}", .{std.json.fmt(model, .{})});
            first = false;
        }
        if (params.cwd) |cwd| {
            if (!first) try writer.writeByte(',');
            try writer.print("\"cwd\":{f}", .{std.json.fmt(cwd, .{})});
            first = false;
        }
        if (params.approval_policy) |pol| {
            if (!first) try writer.writeByte(',');
            try writer.print("\"approvalPolicy\":{f}", .{std.json.fmt(pol.toString(), .{})});
            first = false;
        }
        if (params.reasoning_effort) |effort| {
            if (!first) try writer.writeByte(',');
            try writer.print("\"reasoningEffort\":{f}", .{std.json.fmt(effort.toString(), .{})});
            first = false;
        }
        if (params.service_tier) |service_tier| {
            if (!first) try writer.writeByte(',');
            try writer.print("\"serviceTier\":{f}", .{std.json.fmt(service_tier.toString(), .{})});
            first = false;
        }
        if (params.input) |input_items| {
            if (!first) try writer.writeByte(',');
            try writer.writeAll("\"input\":[");
            for (input_items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try self.writeInputItem(writer, item);
            }
            try writer.writeByte(']');
        }

        try writer.writeAll("}}");
        return output.toOwnedSlice(self.allocator);
    }

    pub fn encodeThreadResume(self: *Encoder, id: i64, params: protocol.ThreadResumeParams) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.print("{{\"id\":{d},\"method\":\"thread/resume\",\"params\":{{\"threadId\":{f}", .{
            id,
            std.json.fmt(params.thread_id, .{}),
        });
        if (params.cwd) |cwd| {
            try writer.print(",\"cwd\":{f}", .{std.json.fmt(cwd, .{})});
        }
        try writer.writeAll("}}");
        return output.toOwnedSlice(self.allocator);
    }

    pub fn encodeThreadFork(self: *Encoder, id: i64, params: protocol.ThreadForkParams) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.print("{{\"id\":{d},\"method\":\"thread/fork\",\"params\":{{\"threadId\":{f}", .{
            id,
            std.json.fmt(params.thread_id, .{}),
        });
        if (params.turn_id) |turn_id| {
            try writer.print(",\"turnId\":{f}", .{std.json.fmt(turn_id, .{})});
        }
        try writer.writeAll("}}");
        return output.toOwnedSlice(self.allocator);
    }

    pub fn encodeThreadList(self: *Encoder, id: i64, params: protocol.ThreadListParams) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.print("{{\"id\":{d},\"method\":\"thread/list\",\"params\":{{", .{id});

        var first = true;
        if (params.status) |status| {
            try writer.print("\"status\":{f}", .{std.json.fmt(status, .{})});
            first = false;
        }
        if (params.limit) |limit| {
            if (!first) try writer.writeByte(',');
            try writer.print("\"limit\":{d}", .{limit});
        }

        try writer.writeAll("}}");
        return output.toOwnedSlice(self.allocator);
    }

    pub fn encodeTurnStart(self: *Encoder, id: i64, params: protocol.TurnStartParams) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.print("{{\"id\":{d},\"method\":\"turn/start\",\"params\":{{\"threadId\":{f}", .{
            id,
            std.json.fmt(params.thread_id, .{}),
        });
        if (params.reasoning_effort) |effort| {
            try writer.print(",\"effort\":{f}", .{std.json.fmt(effort.toString(), .{})});
        }
        if (params.service_tier) |service_tier| {
            try writer.print(",\"serviceTier\":{f}", .{std.json.fmt(service_tier.toString(), .{})});
        }
        if (params.input) |input_items| {
            try writer.writeAll(",\"input\":[");
            for (input_items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try self.writeInputItem(writer, item);
            }
            try writer.writeByte(']');
        }
        try writer.writeAll("}}");
        return output.toOwnedSlice(self.allocator);
    }

    pub fn encodeTurnSteer(self: *Encoder, id: i64, params: protocol.TurnSteerParams) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.print("{{\"id\":{d},\"method\":\"turn/steer\",\"params\":{{\"threadId\":{f},\"turnId\":{f},\"input\":[", .{
            id,
            std.json.fmt(params.thread_id, .{}),
            std.json.fmt(params.turn_id, .{}),
        });
        for (params.input, 0..) |item, i| {
            if (i > 0) try writer.writeByte(',');
            try self.writeInputItem(writer, item);
        }
        try writer.writeAll("]}}");
        return output.toOwnedSlice(self.allocator);
    }

    pub fn encodeTurnInterrupt(self: *Encoder, id: i64, thread_id: []const u8, turn_id: []const u8) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.print("{{\"id\":{d},\"method\":\"turn/interrupt\",\"params\":{{\"threadId\":{f},\"turnId\":{f}}}}}", .{
            id,
            std.json.fmt(thread_id, .{}),
            std.json.fmt(turn_id, .{}),
        });
        return output.toOwnedSlice(self.allocator);
    }

    pub fn encodeModelList(self: *Encoder, id: i64) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.print("{{\"id\":{d},\"method\":\"model/list\",\"params\":{{}}}}", .{id});
        return output.toOwnedSlice(self.allocator);
    }

    pub fn encodeApprovalResponse(self: *Encoder, id: RequestId, decision_json: []const u8) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.writeAll("{\"id\":");
        try writeId(writer, id);
        try writer.writeAll(",\"result\":{\"decision\":");
        try writer.writeAll(decision_json);
        try writer.writeAll("}}");

        return output.toOwnedSlice(self.allocator);
    }

    pub fn encodeThreadCompact(self: *Encoder, id: i64, thread_id: []const u8) ![]u8 {
        return self.encodeSimpleThreadMethod(id, "thread/compact/start", thread_id);
    }

    pub fn encodeThreadRollback(self: *Encoder, id: i64, thread_id: []const u8, turn_id: []const u8) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.print("{{\"id\":{d},\"method\":\"thread/rollback\",\"params\":{{\"threadId\":{f},\"turnId\":{f}}}}}", .{
            id,
            std.json.fmt(thread_id, .{}),
            std.json.fmt(turn_id, .{}),
        });
        return output.toOwnedSlice(self.allocator);
    }

    pub fn encodeThreadArchive(self: *Encoder, id: i64, thread_id: []const u8) ![]u8 {
        return self.encodeSimpleThreadMethod(id, "thread/archive", thread_id);
    }

    pub fn encodeThreadUnarchive(self: *Encoder, id: i64, thread_id: []const u8) ![]u8 {
        return self.encodeSimpleThreadMethod(id, "thread/unarchive", thread_id);
    }

    pub fn encodeConfigRead(self: *Encoder, id: i64) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.print("{{\"id\":{d},\"method\":\"config/read\",\"params\":{{}}}}", .{id});
        return output.toOwnedSlice(self.allocator);
    }

    pub fn encodeUserInputResponse(self: *Encoder, id: RequestId, answers: []const []const u8) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.writeAll("{\"id\":");
        try writeId(writer, id);
        try writer.writeAll(",\"result\":{\"answers\":[");
        for (answers, 0..) |answer, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print("{f}", .{std.json.fmt(answer, .{})});
        }
        try writer.writeAll("]}}");
        return output.toOwnedSlice(self.allocator);
    }

    pub fn deinit(self: *Encoder) void {
        _ = self;
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    fn encodeSimpleThreadMethod(self: *Encoder, id: i64, method: []const u8, thread_id: []const u8) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);

        try writer.print("{{\"id\":{d},\"method\":{f},\"params\":{{\"threadId\":{f}}}}}", .{
            id,
            std.json.fmt(method, .{}),
            std.json.fmt(thread_id, .{}),
        });
        return output.toOwnedSlice(self.allocator);
    }

    fn writeInputItem(_: *Encoder, writer: anytype, item: protocol.InputItem) !void {
        switch (item) {
            .text => |t| {
                try writer.print("{{\"type\":\"text\",\"text\":{f}}}", .{std.json.fmt(t.text, .{})});
            },
            .image => |img| {
                try writer.writeAll("{\"type\":\"image\"");
                if (img.url) |url| {
                    try writer.print(",\"url\":{f}", .{std.json.fmt(url, .{})});
                }
                if (img.data) |data| {
                    try writer.print(",\"data\":{f}", .{std.json.fmt(data, .{})});
                }
                if (img.media_type) |mt| {
                    try writer.print(",\"mediaType\":{f}", .{std.json.fmt(mt, .{})});
                }
                try writer.writeByte('}');
            },
        }
    }
};

// =============================================================================
// Decoder
// =============================================================================

pub const Decoder = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) Decoder {
        return .{ .allocator = allocator };
    }

    pub fn decode(self: *Decoder, line: []const u8) !DecodedMessage {
        const trimmed = std.mem.trimRight(u8, line, "\n\r");

        const parsed = std.json.parseFromSlice(RawMessage, self.allocator, trimmed, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch {
            return error.InvalidJson;
        };
        defer parsed.deinit();

        const msg = parsed.value;

        const has_id = msg.id != null;
        const has_method = msg.method != null;

        if (has_id and has_method) {
            return .{ .server_request = .{
                .id = try self.parseId(msg.id.?),
                .method = try self.allocator.dupe(u8, msg.method.?),
                .params_json = try self.stringifyValue(msg.params),
            } };
        } else if (has_id) {
            return .{ .response = .{
                .id = try self.parseId(msg.id.?),
                .result_json = try self.stringifyValue(msg.result),
                .error_msg = if (msg.@"error") |e| blk: {
                    break :blk .{
                        .code = e.code,
                        .message = try self.allocator.dupe(u8, e.message),
                        .data = null,
                    };
                } else null,
            } };
        } else if (has_method) {
            return .{ .notification = .{
                .method = try self.allocator.dupe(u8, msg.method.?),
                .params_json = try self.stringifyValue(msg.params),
            } };
        } else {
            return error.InvalidMessage;
        }
    }

    // -------------------------------------------------------------------------
    // Level 2 Parse Methods
    // -------------------------------------------------------------------------

    pub fn parseInitializeResult(self: *Decoder, json: []const u8) !protocol.InitializeResult {
        const RawResult = struct {
            userAgent: ?[]const u8 = null,
        };

        const parsed = try std.json.parseFromSlice(RawResult, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        return .{
            .user_agent = if (parsed.value.userAgent) |ua| try self.allocator.dupe(u8, ua) else null,
        };
    }

    pub fn parseThreadStartResult(self: *Decoder, json: []const u8) !protocol.ThreadStartResult {
        const parsed = try std.json.parseFromSlice(RawThreadStartResult, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const r = parsed.value;
        const thread = try self.convertRawThread(r.thread);

        return .{
            .thread = thread,
            .model = if (r.model) |m| try self.allocator.dupe(u8, m) else null,
            .model_provider = if (r.modelProvider) |mp| try self.allocator.dupe(u8, mp) else null,
            .cwd = if (r.cwd) |c| try self.allocator.dupe(u8, c) else null,
            .approval_policy = if (r.approvalPolicy) |ap| protocol.ApprovalPolicy.fromString(ap) else null,
            .sandbox = if (r.sandbox) |s| protocol.SandboxPolicy{
                .type = if (s.type) |t| try self.allocator.dupe(u8, t) else null,
                .network_access = s.networkAccess orelse false,
            } else null,
            .reasoning_effort = if (r.reasoningEffort) |re| protocol.ReasoningEffort.fromString(re) else null,
            .service_tier = if (r.serviceTier) |st| protocol.ServiceTier.fromString(st) else null,
        };
    }

    pub fn parseThreadListResult(self: *Decoder, json: []const u8) !protocol.ThreadListResult {
        const RawResult = struct {
            data: ?[]const RawThread = null,
        };

        const parsed = try std.json.parseFromSlice(RawResult, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const raw_threads = parsed.value.data orelse &.{};
        const threads = try self.allocator.alloc(protocol.Thread, raw_threads.len);
        for (raw_threads, 0..) |rt, i| {
            threads[i] = try self.convertRawThread(rt);
        }

        return .{ .data = threads };
    }

    pub fn parseModelListResult(self: *Decoder, json: []const u8) !protocol.ModelListResult {
        const parsed = try std.json.parseFromSlice(RawModelListResult, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const raw_data = parsed.value.data orelse &.{};
        const models = try self.allocator.alloc(protocol.ModelInfo, raw_data.len);
        for (raw_data, 0..) |rm, i| {
            var efforts: ?[]protocol.ReasoningEffort = null;
            if (rm.supportedReasoningEfforts) |raw_efforts| {
                var effort_list: std.ArrayListUnmanaged(protocol.ReasoningEffort) = .{};
                for (raw_efforts) |re| {
                    if (protocol.ReasoningEffort.fromString(re.reasoningEffort)) |e| {
                        try effort_list.append(self.allocator, e);
                    }
                }
                if (effort_list.items.len > 0) {
                    efforts = try effort_list.toOwnedSlice(self.allocator);
                }
            }

            models[i] = .{
                .id = try self.allocator.dupe(u8, rm.id),
                .model = if (rm.model) |m| try self.allocator.dupe(u8, m) else null,
                .display_name = if (rm.displayName) |dn| try self.allocator.dupe(u8, dn) else null,
                .description = if (rm.description) |d| try self.allocator.dupe(u8, d) else null,
                .supported_reasoning_efforts = efforts,
                .is_default = rm.isDefault orelse false,
                .supports_personality = rm.supportsPersonality orelse false,
            };
        }

        return .{ .data = models };
    }

    pub fn parseItemStarted(self: *Decoder, json: []const u8) !protocol.ItemStartedParams {
        const parsed = try std.json.parseFromSlice(RawItemStartedParams, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const r = parsed.value;
        const item = try self.convertRawItem(r.item);

        return .{
            .thread_id = try self.allocator.dupe(u8, r.threadId),
            .turn_id = try self.allocator.dupe(u8, r.turnId),
            .item = item,
        };
    }

    pub fn parseTokenUsage(self: *Decoder, json: []const u8) !struct {
        thread_id: []const u8,
        turn_id: ?[]const u8,
        token_usage: protocol.TokenUsage,
    } {
        const parsed = try std.json.parseFromSlice(RawTokenUsageParams, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const r = parsed.value;
        const token_usage = r.tokenUsage orelse r.token_usage orelse RawTokenUsage{};
        const thread_id = r.threadId orelse r.thread_id orelse return error.InvalidTokenUsagePayload;
        const turn_id = r.turnId orelse r.turn_id;
        return .{
            .thread_id = try self.allocator.dupe(u8, thread_id),
            .turn_id = if (turn_id) |tid| try self.allocator.dupe(u8, tid) else null,
            .token_usage = .{
                .total = if (token_usage.total) |t| convertRawTokenCounts(t) else null,
                .last = if (token_usage.last) |l| convertRawTokenCounts(l) else null,
                .model_context_window = token_usage.modelContextWindow orelse token_usage.model_context_window,
            },
        };
    }

    pub fn parseCommandApproval(self: *Decoder, json: []const u8) !protocol.CommandApprovalParams {
        const RawParams = struct {
            threadId: []const u8,
            turnId: ?[]const u8 = null,
            command: []const u8,
            cwd: ?[]const u8 = null,
            itemId: ?[]const u8 = null,
            reason: ?[]const u8 = null,
        };

        const parsed = try std.json.parseFromSlice(RawParams, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const r = parsed.value;
        return .{
            .thread_id = try self.allocator.dupe(u8, r.threadId),
            .turn_id = if (r.turnId) |tid| try self.allocator.dupe(u8, tid) else null,
            .command = try self.allocator.dupe(u8, r.command),
            .cwd = if (r.cwd) |c| try self.allocator.dupe(u8, c) else null,
            .item_id = if (r.itemId) |iid| try self.allocator.dupe(u8, iid) else null,
            .reason = if (r.reason) |rsn| try self.allocator.dupe(u8, rsn) else null,
        };
    }

    pub fn parseFileChangeApproval(self: *Decoder, json: []const u8) !protocol.FileChangeApprovalParams {
        const RawParams = struct {
            threadId: []const u8,
            turnId: ?[]const u8 = null,
            path: []const u8,
            itemId: ?[]const u8 = null,
        };

        const parsed = try std.json.parseFromSlice(RawParams, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const r = parsed.value;
        return .{
            .thread_id = try self.allocator.dupe(u8, r.threadId),
            .turn_id = if (r.turnId) |tid| try self.allocator.dupe(u8, tid) else null,
            .path = try self.allocator.dupe(u8, r.path),
            .item_id = if (r.itemId) |iid| try self.allocator.dupe(u8, iid) else null,
        };
    }

    pub fn parseUserInput(self: *Decoder, json: []const u8) !protocol.UserInputParams {
        const RawOption = struct {
            label: []const u8,
            description: ?[]const u8 = null,
        };

        const RawQuestion = struct {
            id: []const u8,
            header: ?[]const u8 = null,
            question: []const u8,
            options: ?[]const RawOption = null,
            isOther: ?bool = null,
            isSecret: ?bool = null,
        };

        const RawParams = struct {
            threadId: []const u8,
            turnId: ?[]const u8 = null,
            questions: []const RawQuestion,
        };

        const parsed = try std.json.parseFromSlice(RawParams, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const r = parsed.value;

        const questions = try self.allocator.alloc(protocol.UserInputQuestion, r.questions.len);
        for (r.questions, 0..) |rq, i| {
            var options: ?[]protocol.UserInputOption = null;
            if (rq.options) |raw_opts| {
                const opts = try self.allocator.alloc(protocol.UserInputOption, raw_opts.len);
                for (raw_opts, 0..) |ro, j| {
                    opts[j] = .{
                        .label = try self.allocator.dupe(u8, ro.label),
                        .description = if (ro.description) |d| try self.allocator.dupe(u8, d) else null,
                    };
                }
                options = opts;
            }
            questions[i] = .{
                .id = try self.allocator.dupe(u8, rq.id),
                .header = if (rq.header) |h| try self.allocator.dupe(u8, h) else null,
                .question = try self.allocator.dupe(u8, rq.question),
                .options = options,
                .is_other = rq.isOther orelse false,
                .is_secret = rq.isSecret orelse false,
            };
        }

        return .{
            .thread_id = try self.allocator.dupe(u8, r.threadId),
            .turn_id = if (r.turnId) |tid| try self.allocator.dupe(u8, tid) else null,
            .questions = questions,
        };
    }

    pub fn parseRateLimits(self: *Decoder, json: []const u8) !protocol.RateLimits {
        const RawEntry = struct {
            usedPercent: ?f64 = null,
            used_percent: ?f64 = null,
            credits: ?f64 = null,
        };

        const RawParams = struct {
            primary: ?RawEntry = null,
            secondary: ?RawEntry = null,
        };

        const parsed = try std.json.parseFromSlice(RawParams, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const r = parsed.value;
        return .{
            .primary = if (r.primary) |e| .{
                .used_percent = e.usedPercent orelse e.used_percent orelse 0,
                .credits = e.credits,
            } else .{},
            .secondary = if (r.secondary) |e| .{
                .used_percent = e.usedPercent orelse e.used_percent orelse 0,
                .credits = e.credits,
            } else .{},
        };
    }

    pub fn parseTurnCompleted(self: *Decoder, json: []const u8) !struct {
        thread_id: []const u8,
        turn: protocol.Turn,
    } {
        const RawTurnCompleted = struct {
            threadId: []const u8,
            turn: RawTurn,
        };

        const parsed = try std.json.parseFromSlice(RawTurnCompleted, self.allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const r = parsed.value;
        return .{
            .thread_id = try self.allocator.dupe(u8, r.threadId),
            .turn = .{
                .id = try self.allocator.dupe(u8, r.turn.id),
                .status = if (r.turn.status) |s| protocol.TurnStatus.fromString(s) else null,
            },
        };
    }

    pub fn deinit(self: *Decoder) void {
        _ = self;
    }

    // -------------------------------------------------------------------------
    // Internal Helpers
    // -------------------------------------------------------------------------

    fn parseId(self: *Decoder, value: std.json.Value) !RequestId {
        return switch (value) {
            .string => |s| .{ .string = try self.allocator.dupe(u8, s) },
            .integer => |n| .{ .number = n },
            .null => .{ .null_value = {} },
            else => error.InvalidId,
        };
    }

    fn stringifyValue(self: *Decoder, value: ?std.json.Value) !?[]u8 {
        if (value == null) return null;

        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);
        const writer = output.writer(self.allocator);
        try writer.print("{f}", .{std.json.fmt(value.?, .{})});
        return try output.toOwnedSlice(self.allocator);
    }

    fn convertRawThread(self: *Decoder, rt: RawThread) !protocol.Thread {
        var turns: ?[]protocol.Turn = null;
        if (rt.turns) |raw_turns| {
            const t = try self.allocator.alloc(protocol.Turn, raw_turns.len);
            for (raw_turns, 0..) |raw_turn, i| {
                t[i] = .{
                    .id = try self.allocator.dupe(u8, raw_turn.id),
                    .status = if (raw_turn.status) |s| protocol.TurnStatus.fromString(s) else null,
                };
            }
            turns = t;
        }

        return .{
            .id = try self.allocator.dupe(u8, rt.id),
            .preview = if (rt.preview) |p| try self.allocator.dupe(u8, p) else null,
            .model_provider = if (rt.modelProvider) |mp| try self.allocator.dupe(u8, mp) else null,
            .created_at = rt.createdAt,
            .updated_at = rt.updatedAt,
            .path = if (rt.path) |p| try self.allocator.dupe(u8, p) else null,
            .cwd = if (rt.cwd) |c| try self.allocator.dupe(u8, c) else null,
            .cli_version = if (rt.cliVersion) |cv| try self.allocator.dupe(u8, cv) else null,
            .source = if (rt.source) |s| try self.allocator.dupe(u8, s) else null,
            .git_info = if (rt.gitInfo) |gi| protocol.GitInfo{
                .sha = if (gi.sha) |s| try self.allocator.dupe(u8, s) else null,
                .branch = if (gi.branch) |b| try self.allocator.dupe(u8, b) else null,
                .origin_url = if (gi.originUrl) |o| try self.allocator.dupe(u8, o) else null,
            } else null,
            .turns = turns,
        };
    }

    fn convertRawItem(self: *Decoder, raw: RawItem) !protocol.Item {
        const item_type = raw.type orelse return .{ .unknown = {} };

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

        const item_identifier = raw.id orelse raw.callId orelse "";
        const item_id = try self.allocator.dupe(u8, item_identifier);

        return switch (variant) {
            .user_message => .{ .user_message = .{
                .id = item_id,
                .content = try self.convertRawContentToTextContent(raw.content),
            } },
            .agent_message => .{ .agent_message = .{
                .id = item_id,
                .text = if (raw.text) |t| try self.allocator.dupe(u8, t) else try self.allocator.dupe(u8, ""),
            } },
            .reasoning => blk: {
                const summary_slice = try self.extractStringArray(raw.summary);
                const content_slice = try self.extractStringArray(raw.content);
                break :blk .{ .reasoning = .{
                    .id = item_id,
                    .summary = summary_slice,
                    .content = content_slice,
                } };
            },
            .command_execution => .{ .command_execution = .{
                .id = item_id,
                .command = if (raw.command) |c| try self.allocator.dupe(u8, c) else null,
                .cwd = if (raw.cwd) |c| try self.allocator.dupe(u8, c) else null,
                .exit_code = raw.exitCode,
                .stdout = if (raw.stdout) |s| try self.allocator.dupe(u8, s) else null,
                .stderr = if (raw.stderr) |s| try self.allocator.dupe(u8, s) else null,
                .status = if (raw.status) |s| protocol.CommandExecutionStatus.fromString(s) orelse .pending else .pending,
            } },
            .file_change => .{ .file_change = .{
                .id = item_id,
                .path = if (raw.path) |p| try self.allocator.dupe(u8, p) else null,
                .diff = if (raw.diff) |d| try self.allocator.dupe(u8, d) else null,
                .status = if (raw.status) |s| try self.allocator.dupe(u8, s) else null,
            } },
            .mcp_tool_call => .{ .mcp_tool_call = .{
                .id = item_id,
                .server_name = if (raw.serverName) |sn| try self.allocator.dupe(u8, sn) else null,
                .tool_name = if (raw.toolName) |tn| try self.allocator.dupe(u8, tn) else null,
                .arguments = if (raw.arguments) |a| try self.allocator.dupe(u8, a) else null,
                .output = if (raw.output) |o| try self.allocator.dupe(u8, o) else null,
                .status = if (raw.status) |s| try self.allocator.dupe(u8, s) else null,
            } },
            .function_call => .{ .function_call = .{
                .id = item_id,
                .call_id = if (raw.callId) |c| try self.allocator.dupe(u8, c) else null,
                .name = if (raw.name) |n| try self.allocator.dupe(u8, n) else null,
                .arguments = if (raw.arguments) |a| try self.allocator.dupe(u8, a) else null,
                .output = if (raw.output) |o| try self.allocator.dupe(u8, o) else null,
                .status = if (raw.status) |s| try self.allocator.dupe(u8, s) else null,
            } },
        };
    }

    fn convertRawContentToTextContent(self: *Decoder, raw_content: ?std.json.Value) !?[]protocol.TextContent {
        const content = raw_content orelse return null;
        const arr = switch (content) {
            .array => |a| a,
            else => return null,
        };
        if (arr.items.len == 0) return null;

        var list: std.ArrayListUnmanaged(protocol.TextContent) = .{};
        for (arr.items) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const text_val = obj.get("text") orelse continue;
            try list.append(self.allocator, .{
                .text = switch (text_val) {
                    .string => |s| try self.allocator.dupe(u8, s),
                    else => try self.allocator.dupe(u8, ""),
                },
            });
        }
        const result = try list.toOwnedSlice(self.allocator);
        return if (result.len == 0) null else result;
    }

    fn extractStringArray(self: *Decoder, raw_value: ?std.json.Value) ![][]const u8 {
        const value = raw_value orelse return try self.allocator.alloc([]const u8, 0);
        const arr = switch (value) {
            .array => |a| a,
            else => return try self.allocator.alloc([]const u8, 0),
        };

        var list: std.ArrayListUnmanaged([]const u8) = .{};
        for (arr.items) |item| {
            if (item == .string) {
                try list.append(self.allocator, try self.allocator.dupe(u8, item.string));
            }
        }
        return try list.toOwnedSlice(self.allocator);
    }
};

// =============================================================================
// Standalone helpers
// =============================================================================

fn writeId(writer: anytype, id: RequestId) !void {
    switch (id) {
        .string => |s| try writer.print("{f}", .{std.json.fmt(s, .{})}),
        .number => |n| try writer.print("{d}", .{n}),
        .null_value => try writer.writeAll("null"),
    }
}

fn convertRawTokenCounts(r: RawTokenCounts) protocol.TokenCounts {
    return .{
        .total_tokens = r.totalTokens orelse r.total_tokens orelse 0,
        .input_tokens = r.inputTokens orelse r.input_tokens orelse 0,
        .cached_input_tokens = r.cachedInputTokens orelse r.cached_input_tokens orelse 0,
        .output_tokens = r.outputTokens orelse r.output_tokens orelse 0,
        .reasoning_output_tokens = r.reasoningOutputTokens orelse r.reasoning_output_tokens orelse 0,
    };
}

// =============================================================================
// Raw JSON Structures for Parsing (camelCase wire format)
// =============================================================================

const RawMessage = struct {
    id: ?std.json.Value = null,
    method: ?[]const u8 = null,
    params: ?std.json.Value = null,
    result: ?std.json.Value = null,
    @"error": ?struct {
        code: i32,
        message: []const u8,
    } = null,
};

const RawGitInfo = struct {
    sha: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    originUrl: ?[]const u8 = null,
};

const RawTurn = struct {
    id: []const u8,
    status: ?[]const u8 = null,
};

const RawTextContent = struct {
    text: []const u8,
};

const RawItem = struct {
    type: ?[]const u8 = null,
    id: ?[]const u8 = null,
    callId: ?[]const u8 = null,
    name: ?[]const u8 = null,
    text: ?[]const u8 = null,
    content: ?std.json.Value = null,
    summary: ?std.json.Value = null,
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

const RawThread = struct {
    id: []const u8,
    preview: ?[]const u8 = null,
    modelProvider: ?[]const u8 = null,
    createdAt: ?i64 = null,
    updatedAt: ?i64 = null,
    path: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    cliVersion: ?[]const u8 = null,
    source: ?[]const u8 = null,
    gitInfo: ?RawGitInfo = null,
    turns: ?[]const RawTurn = null,
};

const RawSandboxPolicy = struct {
    type: ?[]const u8 = null,
    writableRoots: ?[]const []const u8 = null,
    networkAccess: ?bool = null,
};

const RawThreadStartResult = struct {
    thread: RawThread,
    model: ?[]const u8 = null,
    modelProvider: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    approvalPolicy: ?[]const u8 = null,
    sandbox: ?RawSandboxPolicy = null,
    reasoningEffort: ?[]const u8 = null,
    serviceTier: ?[]const u8 = null,
};

const RawReasoningEffort = struct {
    reasoningEffort: []const u8,
    description: ?[]const u8 = null,
};

const RawModelInfo = struct {
    id: []const u8,
    model: ?[]const u8 = null,
    displayName: ?[]const u8 = null,
    description: ?[]const u8 = null,
    supportedReasoningEfforts: ?[]const RawReasoningEffort = null,
    isDefault: ?bool = null,
    supportsPersonality: ?bool = null,
};

const RawModelListResult = struct {
    data: ?[]const RawModelInfo = null,
};

const RawItemStartedParams = struct {
    threadId: []const u8,
    turnId: []const u8,
    item: RawItem,
};

const RawTokenCounts = struct {
    totalTokens: ?u64 = null,
    total_tokens: ?u64 = null,
    inputTokens: ?u64 = null,
    input_tokens: ?u64 = null,
    cachedInputTokens: ?u64 = null,
    cached_input_tokens: ?u64 = null,
    outputTokens: ?u64 = null,
    output_tokens: ?u64 = null,
    reasoningOutputTokens: ?u64 = null,
    reasoning_output_tokens: ?u64 = null,
};

const RawTokenUsage = struct {
    total: ?RawTokenCounts = null,
    last: ?RawTokenCounts = null,
    modelContextWindow: ?u64 = null,
    model_context_window: ?u64 = null,
};

const RawTokenUsageParams = struct {
    threadId: ?[]const u8 = null,
    thread_id: ?[]const u8 = null,
    turnId: ?[]const u8 = null,
    turn_id: ?[]const u8 = null,
    tokenUsage: ?RawTokenUsage = null,
    token_usage: ?RawTokenUsage = null,
};

// =============================================================================
// Tests
// =============================================================================

test "encode initialize" {
    const allocator = std.testing.allocator;
    var encoder = Encoder.init(allocator);

    const result = try encoder.encodeInitialize(0, .{
        .client_name = "skim",
        .title = "Skim",
        .client_version = "0.1.0",
    });
    defer allocator.free(result);

    // Must NOT contain jsonrpc field
    try std.testing.expect(std.mem.indexOf(u8, result, "jsonrpc") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"method\":\"initialize\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":0") != null);
    // Must have nested clientInfo
    try std.testing.expect(std.mem.indexOf(u8, result, "\"clientInfo\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"skim\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"title\":\"Skim\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"version\":\"0.1.0\"") != null);
    // Must NOT have flat clientName/clientVersion
    try std.testing.expect(std.mem.indexOf(u8, result, "\"clientName\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"clientVersion\"") == null);
}

test "encode initialized notification" {
    const allocator = std.testing.allocator;
    var encoder = Encoder.init(allocator);

    const result = try encoder.encodeInitialized();
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "jsonrpc") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"method\":\"initialized\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\"") == null);
}

test "encode thread start" {
    const allocator = std.testing.allocator;
    var encoder = Encoder.init(allocator);

    var text_input = [_]protocol.InputItem{
        .{ .text = .{ .text = "Hello, world!" } },
    };
    const result = try encoder.encodeThreadStart(1, .{
        .model = "gpt-5.1-codex-mini",
        .cwd = "/home/user/projects/skim",
        .approval_policy = .on_request,
        .reasoning_effort = .medium,
        .service_tier = .fast,
        .input = &text_input,
    });
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "jsonrpc") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"method\":\"thread/start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"model\":\"gpt-5.1-codex-mini\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"approvalPolicy\":\"on-request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"reasoningEffort\":\"medium\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"serviceTier\":\"fast\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"input\":[") != null);
}

test "encode turn start" {
    const allocator = std.testing.allocator;
    var encoder = Encoder.init(allocator);

    var text_input = [_]protocol.InputItem{
        .{ .text = .{ .text = "Explain this code" } },
    };
    const result = try encoder.encodeTurnStart(5, .{
        .thread_id = "019c6c65-9df2-7003-b62e-9ab034e6d054",
        .reasoning_effort = .low,
        .service_tier = .fast,
        .input = &text_input,
    });
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "jsonrpc") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"method\":\"turn/start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"threadId\":\"019c6c65-9df2-7003-b62e-9ab034e6d054\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"effort\":\"low\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"serviceTier\":\"fast\"") != null);
}

test "encode turn interrupt" {
    const allocator = std.testing.allocator;
    var encoder = Encoder.init(allocator);

    const result = try encoder.encodeTurnInterrupt(7, "thread-1", "turn-1");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"method\":\"turn/interrupt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"threadId\":\"thread-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"turnId\":\"turn-1\"") != null);
}

test "encode approval response - simple accept" {
    const allocator = std.testing.allocator;
    var encoder = Encoder.init(allocator);

    const result = try encoder.encodeApprovalResponse(.{ .number = 10 }, "\"accept\"");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "jsonrpc") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"decision\":\"accept\"") != null);
}

test "encode approval response - acceptForSession" {
    const allocator = std.testing.allocator;
    var encoder = Encoder.init(allocator);

    const result = try encoder.encodeApprovalResponse(.{ .number = 11 }, "\"acceptForSession\"");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"decision\":\"acceptForSession\"") != null);
}

test "encode approval response - acceptWithExecpolicyAmendment object" {
    const allocator = std.testing.allocator;
    var encoder = Encoder.init(allocator);

    const result = try encoder.encodeApprovalResponse(
        .{ .number = 12 },
        "{\"acceptWithExecpolicyAmendment\":{\"execpolicy_amendment\":[\"ls -la\"]}}",
    );
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":12") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"acceptWithExecpolicyAmendment\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"execpolicy_amendment\":[\"ls -la\"]") != null);
}

test "encode approval response - decline" {
    const allocator = std.testing.allocator;
    var encoder = Encoder.init(allocator);

    const result = try encoder.encodeApprovalResponse(.{ .string = "req_123" }, "\"decline\"");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":\"req_123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"decision\":\"decline\"") != null);
}

test "encode thread compact uses thread/compact/start" {
    const allocator = std.testing.allocator;
    var encoder = Encoder.init(allocator);

    const result = try encoder.encodeThreadCompact(3, "thread-abc");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"method\":\"thread/compact/start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"threadId\":\"thread-abc\"") != null);
}

test "decode initialize response" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"id":0,"result":{"userAgent":"skim/0.98.0 (Ubuntu 24.4.0; x86_64) ghostty/1.2.3 (skim; 0.1.0)"}}
    ;

    var msg = try decoder.decode(json);
    defer msg.deinit(allocator);

    try std.testing.expect(msg == .response);
    try std.testing.expect(msg.response.id != null);
    try std.testing.expectEqual(@as(i64, 0), msg.response.id.?.number);
    try std.testing.expect(msg.response.result_json != null);
    try std.testing.expect(msg.response.error_msg == null);
}

test "decode thread start response" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"id":1,"result":{"thread":{"id":"019c6c65-9df2-7003-b62e-9ab034e6d054","preview":"","modelProvider":"openai","createdAt":1771345124,"updatedAt":1771345125,"path":"/home/user/.codex/sessions/019c6c65-9df2-7003-b62e-9ab034e6d054.jsonl","cwd":"/home/user/projects/skim","cliVersion":"0.98.0","source":"vscode","gitInfo":{"sha":"abc123","branch":"codex-app-server","originUrl":"git@github.com:ctdio/skim.git"},"turns":[]},"model":"gpt-5.1-codex-mini","modelProvider":"openai","cwd":"/home/user/projects/skim","approvalPolicy":"on-request","sandbox":{"type":"workspaceWrite","writableRoots":[],"networkAccess":false},"reasoningEffort":"medium","serviceTier":"fast"}}
    ;

    var msg = try decoder.decode(json);
    defer msg.deinit(allocator);

    try std.testing.expect(msg == .response);
    try std.testing.expectEqual(@as(i64, 1), msg.response.id.?.number);
    try std.testing.expect(msg.response.result_json != null);
}

test "decode notification" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"method":"item/agentMessage/delta","params":{"threadId":"019c6c65","turnId":"1","delta":{"text":"Hello"}}}
    ;

    var msg = try decoder.decode(json);
    defer msg.deinit(allocator);

    try std.testing.expect(msg == .notification);
    try std.testing.expectEqualStrings("item/agentMessage/delta", msg.notification.method);
    try std.testing.expect(msg.notification.params_json != null);
}

test "decode server request - command approval" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"method":"item/commandExecution/requestApproval","id":"req_123","params":{"itemId":"item_1","threadId":"019c6c65","turnId":"1","command":"ls -la","reason":"needs to list files"}}
    ;

    var msg = try decoder.decode(json);
    defer msg.deinit(allocator);

    try std.testing.expect(msg == .server_request);
    try std.testing.expectEqualStrings("req_123", msg.server_request.id.string);
    try std.testing.expectEqualStrings("item/commandExecution/requestApproval", msg.server_request.method);
    try std.testing.expect(msg.server_request.params_json != null);
}

test "decode error response" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"id":1,"error":{"code":-32601,"message":"Method not found"}}
    ;

    var msg = try decoder.decode(json);
    defer msg.deinit(allocator);

    try std.testing.expect(msg == .response);
    try std.testing.expect(msg.response.error_msg != null);
    try std.testing.expectEqual(@as(i32, -32601), msg.response.error_msg.?.code);
    try std.testing.expectEqualStrings("Method not found", msg.response.error_msg.?.message);
}

test "decode unknown notification method" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"method":"future/unknown/method","params":{"data":"test"}}
    ;

    var msg = try decoder.decode(json);
    defer msg.deinit(allocator);

    try std.testing.expect(msg == .notification);
    try std.testing.expectEqualStrings("future/unknown/method", msg.notification.method);
}

test "decode invalid json" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const result = decoder.decode("not valid json {{{");
    try std.testing.expectError(error.InvalidJson, result);
}

test "parse initialize result" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"userAgent":"skim/0.98.0 (Ubuntu 24.4.0; x86_64) ghostty/1.2.3 (skim; 0.1.0)"}
    ;

    const result = try decoder.parseInitializeResult(json);
    defer {
        if (result.user_agent) |ua| allocator.free(ua);
    }

    try std.testing.expectEqualStrings("skim/0.98.0 (Ubuntu 24.4.0; x86_64) ghostty/1.2.3 (skim; 0.1.0)", result.user_agent.?);
}

test "parse thread start result" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"thread":{"id":"019c6c65-9df2-7003-b62e-9ab034e6d054","preview":"","modelProvider":"openai","createdAt":1771345124,"updatedAt":1771345125,"path":"/home/user/.codex/sessions/019c6c65-9df2-7003-b62e-9ab034e6d054.jsonl","cwd":"/home/user/projects/skim","cliVersion":"0.98.0","source":"vscode","gitInfo":{"sha":"abc123","branch":"codex-app-server","originUrl":"git@github.com:ctdio/skim.git"},"turns":[]},"model":"gpt-5.1-codex-mini","modelProvider":"openai","cwd":"/home/user/projects/skim","approvalPolicy":"on-request","sandbox":{"type":"workspaceWrite","writableRoots":[],"networkAccess":false},"reasoningEffort":"medium","serviceTier":"fast"}
    ;

    const result = try decoder.parseThreadStartResult(json);

    defer {
        allocator.free(result.thread.id);
        if (result.thread.preview) |p| allocator.free(p);
        if (result.thread.model_provider) |mp| allocator.free(mp);
        if (result.thread.path) |p| allocator.free(p);
        if (result.thread.cwd) |c| allocator.free(c);
        if (result.thread.cli_version) |cv| allocator.free(cv);
        if (result.thread.source) |s| allocator.free(s);
        if (result.thread.git_info) |gi| {
            if (gi.sha) |s| allocator.free(s);
            if (gi.branch) |b| allocator.free(b);
            if (gi.origin_url) |o| allocator.free(o);
        }
        if (result.thread.turns) |turns| allocator.free(turns);
        if (result.model) |m| allocator.free(m);
        if (result.model_provider) |mp| allocator.free(mp);
        if (result.cwd) |c| allocator.free(c);
        if (result.sandbox) |s| {
            if (s.type) |t| allocator.free(t);
        }
    }

    try std.testing.expectEqualStrings("019c6c65-9df2-7003-b62e-9ab034e6d054", result.thread.id);
    try std.testing.expectEqualStrings("openai", result.thread.model_provider.?);
    try std.testing.expectEqual(@as(i64, 1771345124), result.thread.created_at.?);
    try std.testing.expectEqualStrings("gpt-5.1-codex-mini", result.model.?);
    try std.testing.expect(result.approval_policy.? == .on_request);
    try std.testing.expect(result.reasoning_effort.? == .medium);
    try std.testing.expect(result.service_tier.? == .fast);

    const gi = result.thread.git_info.?;
    try std.testing.expectEqualStrings("abc123", gi.sha.?);
    try std.testing.expectEqualStrings("codex-app-server", gi.branch.?);
    try std.testing.expectEqualStrings("git@github.com:ctdio/skim.git", gi.origin_url.?);

    const sandbox = result.sandbox.?;
    try std.testing.expectEqualStrings("workspaceWrite", sandbox.type.?);
    try std.testing.expect(!sandbox.network_access);
}

test "parse thread list result with data key" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"data":[{"id":"019c-thread-1","preview":"First thread","modelProvider":"openai","createdAt":1771345124,"updatedAt":1771345125,"cwd":"/home/user","turns":[]},{"id":"019c-thread-2","preview":"Second thread","modelProvider":"anthropic","createdAt":1771345200,"updatedAt":1771345201,"cwd":"/home/user","turns":[]}]}
    ;

    const result = try decoder.parseThreadListResult(json);
    defer {
        for (result.data) |thread| {
            allocator.free(thread.id);
            if (thread.preview) |p| allocator.free(p);
            if (thread.model_provider) |mp| allocator.free(mp);
            if (thread.cwd) |c| allocator.free(c);
            if (thread.turns) |turns| allocator.free(turns);
        }
        allocator.free(result.data);
    }

    try std.testing.expectEqual(@as(usize, 2), result.data.len);
    try std.testing.expectEqualStrings("019c-thread-1", result.data[0].id);
    try std.testing.expectEqualStrings("First thread", result.data[0].preview.?);
    try std.testing.expectEqualStrings("019c-thread-2", result.data[1].id);
    try std.testing.expectEqualStrings("Second thread", result.data[1].preview.?);
}

test "parse item started - agent message with id and text" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"threadId":"019c6c65","turnId":"1","item":{"type":"agentMessage","id":"msg_123","text":"Hello, I can help!"}}
    ;

    const result = try decoder.parseItemStarted(json);
    defer {
        allocator.free(result.thread_id);
        allocator.free(result.turn_id);
        switch (result.item) {
            .agent_message => |am| {
                allocator.free(am.id);
                allocator.free(am.text);
            },
            else => {},
        }
    }

    try std.testing.expectEqualStrings("019c6c65", result.thread_id);
    try std.testing.expectEqualStrings("1", result.turn_id);
    try std.testing.expect(result.item == .agent_message);
    try std.testing.expectEqualStrings("msg_123", result.item.agent_message.id);
    try std.testing.expectEqualStrings("Hello, I can help!", result.item.agent_message.text);
}

test "parse item started - reasoning with id, summary, content arrays" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"threadId":"019c6c65","turnId":"1","item":{"type":"reasoning","id":"rs_456","summary":["Thinking about the problem"],"content":["Let me analyze this"]}}
    ;

    const result = try decoder.parseItemStarted(json);
    defer {
        allocator.free(result.thread_id);
        allocator.free(result.turn_id);
        switch (result.item) {
            .reasoning => |r| {
                allocator.free(r.id);
                for (r.summary) |s| allocator.free(s);
                allocator.free(r.summary);
                for (r.content) |c| allocator.free(c);
                allocator.free(r.content);
            },
            else => {},
        }
    }

    try std.testing.expect(result.item == .reasoning);
    const reasoning = result.item.reasoning;
    try std.testing.expectEqualStrings("rs_456", reasoning.id);
    try std.testing.expectEqual(@as(usize, 1), reasoning.summary.len);
    try std.testing.expectEqualStrings("Thinking about the problem", reasoning.summary[0]);
    try std.testing.expectEqual(@as(usize, 1), reasoning.content.len);
    try std.testing.expectEqualStrings("Let me analyze this", reasoning.content[0]);
}

test "parse item started - command execution" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"threadId":"019c6c65","turnId":"1","item":{"type":"commandExecution","id":"cmd_789","command":"ls -la","cwd":"/home/user","status":"completed","exitCode":0,"stdout":"file1\nfile2"}}
    ;

    const result = try decoder.parseItemStarted(json);
    defer {
        allocator.free(result.thread_id);
        allocator.free(result.turn_id);
        switch (result.item) {
            .command_execution => |ce| {
                allocator.free(ce.id);
                if (ce.command) |c| allocator.free(c);
                if (ce.cwd) |c| allocator.free(c);
                if (ce.stdout) |s| allocator.free(s);
            },
            else => {},
        }
    }

    try std.testing.expect(result.item == .command_execution);
    const ce = result.item.command_execution;
    try std.testing.expectEqualStrings("cmd_789", ce.id);
    try std.testing.expectEqualStrings("ls -la", ce.command.?);
    try std.testing.expectEqualStrings("/home/user", ce.cwd.?);
    try std.testing.expect(ce.status == .completed);
    try std.testing.expectEqual(@as(i32, 0), ce.exit_code.?);
    try std.testing.expectEqualStrings("file1\nfile2", ce.stdout.?);
}

test "parse item started - file change" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"threadId":"019c6c65","turnId":"1","item":{"type":"fileChange","id":"fc_101","path":"/home/user/file.zig","diff":"@@ -1,3 +1,4 @@\n+new line","status":"modified"}}
    ;

    const result = try decoder.parseItemStarted(json);
    defer {
        allocator.free(result.thread_id);
        allocator.free(result.turn_id);
        switch (result.item) {
            .file_change => |fc| {
                allocator.free(fc.id);
                if (fc.path) |p| allocator.free(p);
                if (fc.diff) |d| allocator.free(d);
                if (fc.status) |s| allocator.free(s);
            },
            else => {},
        }
    }

    try std.testing.expect(result.item == .file_change);
    const fc = result.item.file_change;
    try std.testing.expectEqualStrings("fc_101", fc.id);
    try std.testing.expectEqualStrings("/home/user/file.zig", fc.path.?);
    try std.testing.expectEqualStrings("modified", fc.status.?);
    try std.testing.expect(fc.diff != null);
}

test "parse item started - mcp tool call" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"threadId":"019c6c65","turnId":"1","item":{"type":"mcpToolCall","id":"mcp_202","serverName":"my-server","toolName":"read_file","arguments":"{\"path\":\"file.txt\"}","output":"file contents here","status":"completed"}}
    ;

    const result = try decoder.parseItemStarted(json);
    defer {
        allocator.free(result.thread_id);
        allocator.free(result.turn_id);
        switch (result.item) {
            .mcp_tool_call => |mc| {
                allocator.free(mc.id);
                if (mc.server_name) |sn| allocator.free(sn);
                if (mc.tool_name) |tn| allocator.free(tn);
                if (mc.arguments) |a| allocator.free(a);
                if (mc.output) |o| allocator.free(o);
                if (mc.status) |s| allocator.free(s);
            },
            else => {},
        }
    }

    try std.testing.expect(result.item == .mcp_tool_call);
    const mc = result.item.mcp_tool_call;
    try std.testing.expectEqualStrings("mcp_202", mc.id);
    try std.testing.expectEqualStrings("my-server", mc.server_name.?);
    try std.testing.expectEqualStrings("read_file", mc.tool_name.?);
    try std.testing.expectEqualStrings("file contents here", mc.output.?);
    try std.testing.expectEqualStrings("completed", mc.status.?);
}

test "parse item started - function call spawn_agent" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"threadId":"019c6c65","turnId":"1","item":{"type":"functionCall","callId":"call_123","name":"spawn_agent","arguments":"{\"agent_type\":\"explorer\"}","status":"completed","output":"{\"agent_id\":\"019c-subagent\"}"}}
    ;

    const result = try decoder.parseItemStarted(json);
    defer {
        allocator.free(result.thread_id);
        allocator.free(result.turn_id);
        switch (result.item) {
            .function_call => |fc| {
                allocator.free(fc.id);
                if (fc.call_id) |id| allocator.free(id);
                if (fc.name) |name| allocator.free(name);
                if (fc.arguments) |args| allocator.free(args);
                if (fc.output) |output| allocator.free(output);
                if (fc.status) |status| allocator.free(status);
            },
            else => {},
        }
    }

    try std.testing.expect(result.item == .function_call);
    const fc = result.item.function_call;
    try std.testing.expectEqualStrings("call_123", fc.id);
    try std.testing.expectEqualStrings("call_123", fc.call_id.?);
    try std.testing.expectEqualStrings("spawn_agent", fc.name.?);
    try std.testing.expectEqualStrings("{\"agent_type\":\"explorer\"}", fc.arguments.?);
    try std.testing.expectEqualStrings("{\"agent_id\":\"019c-subagent\"}", fc.output.?);
}

test "parse item started - unknown type" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"threadId":"019c6c65","turnId":"1","item":{"type":"futureNewItemType","data":"something"}}
    ;

    const result = try decoder.parseItemStarted(json);
    defer {
        allocator.free(result.thread_id);
        allocator.free(result.turn_id);
    }

    try std.testing.expect(result.item == .unknown);
}

test "parse token usage" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"threadId":"019c6c65-9df2-7003-b62e-9ab034e6d054","turnId":"1","tokenUsage":{"total":{"totalTokens":16709,"inputTokens":16687,"cachedInputTokens":7936,"outputTokens":22,"reasoningOutputTokens":0},"last":{"totalTokens":500,"inputTokens":400,"cachedInputTokens":100,"outputTokens":100,"reasoningOutputTokens":50},"modelContextWindow":258400}}
    ;

    const result = try decoder.parseTokenUsage(json);
    defer {
        allocator.free(result.thread_id);
        if (result.turn_id) |tid| allocator.free(tid);
    }

    try std.testing.expectEqualStrings("019c6c65-9df2-7003-b62e-9ab034e6d054", result.thread_id);
    try std.testing.expectEqualStrings("1", result.turn_id.?);

    const total = result.token_usage.total.?;
    try std.testing.expectEqual(@as(u64, 16709), total.total_tokens);
    try std.testing.expectEqual(@as(u64, 16687), total.input_tokens);
    try std.testing.expectEqual(@as(u64, 7936), total.cached_input_tokens);
    try std.testing.expectEqual(@as(u64, 22), total.output_tokens);
    try std.testing.expectEqual(@as(u64, 0), total.reasoning_output_tokens);

    const last = result.token_usage.last.?;
    try std.testing.expectEqual(@as(u64, 500), last.total_tokens);
    try std.testing.expectEqual(@as(u64, 50), last.reasoning_output_tokens);

    try std.testing.expectEqual(@as(u64, 258400), result.token_usage.model_context_window.?);
}

test "parse token usage with snake_case fields" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"thread_id":"thread_1","turn_id":"2","token_usage":{"total":{"total_tokens":1000,"input_tokens":900,"cached_input_tokens":200,"output_tokens":100,"reasoning_output_tokens":20},"last":{"total_tokens":120,"input_tokens":100,"cached_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":5},"model_context_window":128000}}
    ;

    const result = try decoder.parseTokenUsage(json);
    defer {
        allocator.free(result.thread_id);
        if (result.turn_id) |tid| allocator.free(tid);
    }

    try std.testing.expectEqualStrings("thread_1", result.thread_id);
    try std.testing.expectEqualStrings("2", result.turn_id.?);
    try std.testing.expectEqual(@as(u64, 1000), result.token_usage.total.?.total_tokens);
    try std.testing.expectEqual(@as(u64, 120), result.token_usage.last.?.total_tokens);
    try std.testing.expectEqual(@as(u64, 128000), result.token_usage.model_context_window.?);
}

test "parse model list with object reasoning efforts" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"data":[{"id":"gpt-5.3-codex","model":"gpt-5.3-codex","displayName":"GPT-5.3 Codex","description":"Most capable model","supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast"},{"reasoningEffort":"medium","description":"Balanced"},{"reasoningEffort":"high","description":"Thorough"}],"isDefault":true,"supportsPersonality":true},{"id":"gpt-5.1-codex-mini","model":"gpt-5.1-codex-mini","displayName":"GPT-5.1 Codex Mini","supportedReasoningEfforts":[{"reasoningEffort":"low"},{"reasoningEffort":"medium"},{"reasoningEffort":"high"},{"reasoningEffort":"xhigh"}],"isDefault":false}]}
    ;

    const result = try decoder.parseModelListResult(json);
    defer {
        for (result.data) |m| {
            allocator.free(m.id);
            if (m.model) |model| allocator.free(model);
            if (m.display_name) |dn| allocator.free(dn);
            if (m.description) |d| allocator.free(d);
            if (m.supported_reasoning_efforts) |efforts| allocator.free(efforts);
        }
        allocator.free(result.data);
    }

    try std.testing.expectEqual(@as(usize, 2), result.data.len);

    const m0 = result.data[0];
    try std.testing.expectEqualStrings("gpt-5.3-codex", m0.id);
    try std.testing.expectEqualStrings("GPT-5.3 Codex", m0.display_name.?);
    try std.testing.expectEqualStrings("Most capable model", m0.description.?);
    try std.testing.expect(m0.is_default);
    try std.testing.expect(m0.supports_personality);
    try std.testing.expectEqual(@as(usize, 3), m0.supported_reasoning_efforts.?.len);
    try std.testing.expect(m0.supported_reasoning_efforts.?[0] == .low);
    try std.testing.expect(m0.supported_reasoning_efforts.?[1] == .medium);
    try std.testing.expect(m0.supported_reasoning_efforts.?[2] == .high);

    const m1 = result.data[1];
    try std.testing.expectEqualStrings("gpt-5.1-codex-mini", m1.id);
    try std.testing.expect(!m1.is_default);
    try std.testing.expectEqual(@as(usize, 4), m1.supported_reasoning_efforts.?.len);
    try std.testing.expect(m1.supported_reasoning_efforts.?[3] == .xhigh);
}

test "parse command approval" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"itemId":"item_1","threadId":"019c6c65","turnId":"1","command":"ls -la","reason":"needs to list files"}
    ;

    const result = try decoder.parseCommandApproval(json);
    defer {
        allocator.free(result.thread_id);
        if (result.turn_id) |tid| allocator.free(tid);
        allocator.free(result.command);
        if (result.item_id) |iid| allocator.free(iid);
        if (result.reason) |r| allocator.free(r);
    }

    try std.testing.expectEqualStrings("019c6c65", result.thread_id);
    try std.testing.expectEqualStrings("1", result.turn_id.?);
    try std.testing.expectEqualStrings("ls -la", result.command);
    try std.testing.expectEqualStrings("item_1", result.item_id.?);
    try std.testing.expectEqualStrings("needs to list files", result.reason.?);
}

test "parse file change approval" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"itemId":"item_2","threadId":"019c6c65","turnId":"1","path":"/home/user/file.zig"}
    ;

    const result = try decoder.parseFileChangeApproval(json);
    defer {
        allocator.free(result.thread_id);
        if (result.turn_id) |tid| allocator.free(tid);
        allocator.free(result.path);
        if (result.item_id) |iid| allocator.free(iid);
    }

    try std.testing.expectEqualStrings("019c6c65", result.thread_id);
    try std.testing.expectEqualStrings("1", result.turn_id.?);
    try std.testing.expectEqualStrings("/home/user/file.zig", result.path);
    try std.testing.expectEqualStrings("item_2", result.item_id.?);
}

test "parse user input" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"threadId":"019c6c65","turnId":"1","questions":[{"id":"q1","header":"Choose a model","question":"Which model?","options":[{"label":"GPT-5","description":"Most capable"},{"label":"GPT-4"}],"isOther":false,"isSecret":false}]}
    ;

    const result = try decoder.parseUserInput(json);
    defer {
        allocator.free(result.thread_id);
        if (result.turn_id) |tid| allocator.free(tid);
        for (result.questions) |q| {
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
        allocator.free(result.questions);
    }

    try std.testing.expectEqualStrings("019c6c65", result.thread_id);
    try std.testing.expectEqual(@as(usize, 1), result.questions.len);

    const q = result.questions[0];
    try std.testing.expectEqualStrings("q1", q.id);
    try std.testing.expectEqualStrings("Choose a model", q.header.?);
    try std.testing.expectEqualStrings("Which model?", q.question);
    try std.testing.expect(!q.is_other);
    try std.testing.expect(!q.is_secret);
    try std.testing.expectEqual(@as(usize, 2), q.options.?.len);
    try std.testing.expectEqualStrings("GPT-5", q.options.?[0].label);
    try std.testing.expectEqualStrings("Most capable", q.options.?[0].description.?);
    try std.testing.expectEqualStrings("GPT-4", q.options.?[1].label);
    try std.testing.expect(q.options.?[1].description == null);
}

test "parse rate limits with primary/secondary" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"primary":{"usedPercent":5.2,"credits":100},"secondary":{"usedPercent":0.0,"credits":null}}
    ;

    const result = try decoder.parseRateLimits(json);

    try std.testing.expectApproxEqRel(@as(f64, 5.2), result.primary.used_percent, 0.001);
    try std.testing.expectApproxEqRel(@as(f64, 100.0), result.primary.credits.?, 0.001);
    try std.testing.expectApproxEqRel(@as(f64, 0.0), result.secondary.used_percent, 0.001);
    try std.testing.expect(result.secondary.credits == null);
}

test "parse rate limits with snake_case used_percent" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"primary":{"used_percent":42.5},"secondary":{"used_percent":1.25}}
    ;

    const result = try decoder.parseRateLimits(json);

    try std.testing.expectApproxEqRel(@as(f64, 42.5), result.primary.used_percent, 0.001);
    try std.testing.expectApproxEqRel(@as(f64, 1.25), result.secondary.used_percent, 0.001);
}

test "parse turn completed" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"threadId":"019c6c65","turn":{"id":"1","items":[],"status":"completed","error":null}}
    ;

    const result = try decoder.parseTurnCompleted(json);
    defer {
        allocator.free(result.thread_id);
        allocator.free(result.turn.id);
    }

    try std.testing.expectEqualStrings("019c6c65", result.thread_id);
    try std.testing.expectEqualStrings("1", result.turn.id);
    try std.testing.expect(result.turn.status.? == .completed);
}

test "parse turn completed - interrupted status" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"threadId":"019c6c65","turn":{"id":"2","items":[],"status":"interrupted","error":null}}
    ;

    const result = try decoder.parseTurnCompleted(json);
    defer {
        allocator.free(result.thread_id);
        allocator.free(result.turn.id);
    }

    try std.testing.expect(result.turn.status.? == .interrupted);
}

test "round-trip encode/decode initialize" {
    const allocator = std.testing.allocator;
    var encoder = Encoder.init(allocator);
    var decoder = Decoder.init(allocator);

    const encoded = try encoder.encodeInitialize(42, .{
        .client_name = "skim",
        .title = "Skim",
        .client_version = "0.1.0",
    });
    defer allocator.free(encoded);

    var msg = try decoder.decode(encoded);
    defer msg.deinit(allocator);

    // Message has both id and method, so it's classified as server_request by our decoder.
    // From the CLIENT side, this is a request we SEND. The key check is it decodes without error.
    try std.testing.expect(msg == .server_request);
    try std.testing.expectEqualStrings("initialize", msg.server_request.method);
    try std.testing.expectEqual(@as(i64, 42), msg.server_request.id.number);
}

test "null/missing optional fields in item started" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"threadId":"t1","turnId":"1","item":{"type":"agentMessage","id":"msg_1","text":""}}
    ;

    const result = try decoder.parseItemStarted(json);
    defer {
        allocator.free(result.thread_id);
        allocator.free(result.turn_id);
        switch (result.item) {
            .agent_message => |am| {
                allocator.free(am.id);
                allocator.free(am.text);
            },
            else => {},
        }
    }

    try std.testing.expect(result.item == .agent_message);
    try std.testing.expectEqualStrings("", result.item.agent_message.text);
}

test "reasoning item with empty arrays" {
    const allocator = std.testing.allocator;
    var decoder = Decoder.init(allocator);

    const json =
        \\{"threadId":"t1","turnId":"1","item":{"type":"reasoning","id":"rs_1","summary":[],"content":[]}}
    ;

    const result = try decoder.parseItemStarted(json);
    defer {
        allocator.free(result.thread_id);
        allocator.free(result.turn_id);
        switch (result.item) {
            .reasoning => |r| {
                allocator.free(r.id);
                allocator.free(r.summary);
                allocator.free(r.content);
            },
            else => {},
        }
    }

    try std.testing.expect(result.item == .reasoning);
    try std.testing.expectEqual(@as(usize, 0), result.item.reasoning.summary.len);
    try std.testing.expectEqual(@as(usize, 0), result.item.reasoning.content.len);
}

test "RequestId equality" {
    const id1 = RequestId{ .number = 42 };
    const id2 = RequestId{ .number = 42 };
    const id3 = RequestId{ .number = 43 };
    const id4 = RequestId{ .string = "abc" };
    const id5 = RequestId{ .string = "abc" };

    try std.testing.expect(id1.eql(id2));
    try std.testing.expect(!id1.eql(id3));
    try std.testing.expect(!id1.eql(id4));
    try std.testing.expect(id4.eql(id5));
}
