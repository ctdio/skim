const std = @import("std");

// =============================================================================
// Opencode REST API Protocol Types
// Based on OpenAPI spec from opencode serve
// =============================================================================

/// Protocol version constant
pub const PROTOCOL_VERSION = "0.0.3";

// =============================================================================
// Health Check
// =============================================================================

/// Response from GET /global/health
pub const HealthResponse = struct {
    healthy: bool,
    version: []const u8,
};

// =============================================================================
// Session Management
// =============================================================================

/// Session time information with numeric timestamps
pub const SessionTime = struct {
    created: i64,
    updated: i64,
};

/// Session information returned from API
pub const Session = struct {
    id: []const u8,
    time: SessionTime,
};

/// Request body for POST /session
pub const CreateSessionRequest = struct {
    // Empty object - no required fields
};

// =============================================================================
// Provider and Model Information
// =============================================================================

/// Model information within a provider
pub const ProviderModel = struct {
    id: []const u8,
    name: ?[]const u8 = null,
};

/// Provider information from GET /config/providers
pub const Provider = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    models: []const ProviderModel = &.{},
};

/// Response from GET /config/providers
pub const ProvidersResponse = struct {
    providers: []const Provider = &.{},
};

// =============================================================================
// Message Parts
// =============================================================================

/// Text part input for messages
pub const TextPartInput = struct {
    type: []const u8 = "text",
    text: []const u8,
};

/// Part union - currently only text is supported
pub const Part = union(enum) {
    text: TextPartInput,

    pub fn jsonStringify(self: Part, options: std.json.StringifyOptions, writer: anytype) !void {
        switch (self) {
            .text => |t| {
                try writer.writeAll("{\"type\":\"text\",\"text\":");
                try std.json.stringify(t.text, options, writer);
                try writer.writeByte('}');
            },
        }
    }
};

// =============================================================================
// Prompt Async (Main messaging endpoint)
// =============================================================================

/// Model specification for prompt requests
pub const ModelSpec = struct {
    providerID: []const u8,
    modelID: []const u8,
};

/// Request body for POST /session/{id}/prompt_async
pub const PromptAsyncRequest = struct {
    parts: []const Part,
    agent: ?[]const u8 = null, // Agent name: "build", "plan", or custom
    model: ?ModelSpec = null, // Model override: { providerID, modelID }

    /// Serialize to JSON for HTTP request body
    pub fn toJson(self: PromptAsyncRequest, allocator: std.mem.Allocator) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(allocator);
        const writer = output.writer(allocator);

        try writer.writeByte('{');

        // Parts array (required)
        try writer.writeAll("\"parts\":[");
        for (self.parts, 0..) |part, i| {
            if (i > 0) try writer.writeByte(',');
            switch (part) {
                .text => |t| {
                    try writer.writeAll("{\"type\":\"text\",\"text\":");
                    try writer.print("{f}", .{std.json.fmt(t.text, .{})});
                    try writer.writeByte('}');
                },
            }
        }
        try writer.writeByte(']');

        // Agent (optional)
        if (self.agent) |agent| {
            try writer.writeAll(",\"agent\":");
            try writer.print("{f}", .{std.json.fmt(agent, .{})});
        }

        // Model (optional)
        if (self.model) |model| {
            try writer.writeAll(",\"model\":{\"providerID\":");
            try writer.print("{f}", .{std.json.fmt(model.providerID, .{})});
            try writer.writeAll(",\"modelID\":");
            try writer.print("{f}", .{std.json.fmt(model.modelID, .{})});
            try writer.writeByte('}');
        }

        try writer.writeByte('}');

        return output.toOwnedSlice(allocator);
    }
};

/// Helper to create a simple text prompt request
pub fn createTextPrompt(allocator: std.mem.Allocator, text: []const u8) !PromptAsyncRequest {
    const parts = try allocator.alloc(Part, 1);
    parts[0] = .{ .text = .{ .text = text } };
    return .{ .parts = parts };
}

// =============================================================================
// SSE Event Types
// =============================================================================

/// All event types from Opencode SSE stream
pub const EventType = enum {
    // Server events
    server_connected,

    // Session events
    session_created,
    session_updated,
    session_deleted,
    session_idle,
    session_error,

    // Message events
    message_created,
    message_updated,
    message_deleted,
    message_part_updated,

    // Permission and question events
    permission_asked,
    permission_resolved,
    question_asked,
    question_resolved,

    // Unknown/unsupported
    unknown,

    pub fn fromString(s: []const u8) EventType {
        if (std.mem.eql(u8, s, "server.connected")) return .server_connected;
        if (std.mem.eql(u8, s, "session.created")) return .session_created;
        if (std.mem.eql(u8, s, "session.updated")) return .session_updated;
        if (std.mem.eql(u8, s, "session.deleted")) return .session_deleted;
        if (std.mem.eql(u8, s, "session.idle")) return .session_idle;
        if (std.mem.eql(u8, s, "session.error")) return .session_error;
        if (std.mem.eql(u8, s, "message.created")) return .message_created;
        if (std.mem.eql(u8, s, "message.updated")) return .message_updated;
        if (std.mem.eql(u8, s, "message.deleted")) return .message_deleted;
        if (std.mem.eql(u8, s, "message.part.updated")) return .message_part_updated;
        if (std.mem.eql(u8, s, "permission.asked")) return .permission_asked;
        if (std.mem.eql(u8, s, "permission.resolved")) return .permission_resolved;
        if (std.mem.eql(u8, s, "question.asked")) return .question_asked;
        if (std.mem.eql(u8, s, "question.resolved")) return .question_resolved;
        return .unknown;
    }
};

/// Properties from message.part.updated event
pub const MessagePartUpdatedProperties = struct {
    /// The part object containing current text
    part: ?struct {
        type: []const u8,
        text: []const u8,
    } = null,
    /// Delta text chunk for streaming
    delta: ?[]const u8 = null,
};

/// Properties from session.idle event
pub const SessionIdleProperties = struct {
    sessionID: []const u8,
};

/// Generic SSE event with parsed JSON type and properties
pub const SseEventData = struct {
    type: EventType,
    type_string: []const u8,
    /// Raw properties JSON for further parsing
    properties_json: ?[]const u8 = null,
};

// =============================================================================
// Error Types
// =============================================================================

/// API error response structure
pub const ApiError = struct {
    code: []const u8,
    message: []const u8,
};

// =============================================================================
// Tests
// =============================================================================

test "EventType fromString" {
    try std.testing.expectEqual(EventType.message_part_updated, EventType.fromString("message.part.updated"));
    try std.testing.expectEqual(EventType.session_idle, EventType.fromString("session.idle"));
    try std.testing.expectEqual(EventType.session_error, EventType.fromString("session.error"));
    try std.testing.expectEqual(EventType.unknown, EventType.fromString("invalid.event"));
}

test "PromptAsyncRequest toJson" {
    const allocator = std.testing.allocator;

    var parts: [1]Part = .{.{ .text = .{ .text = "Hello world" } }};
    const request = PromptAsyncRequest{ .parts = &parts };

    const json = try request.toJson(allocator);
    defer allocator.free(json);

    // Verify JSON structure
    try std.testing.expect(std.mem.indexOf(u8, json, "\"parts\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Hello world") != null);
}

test "PromptAsyncRequest toJson with agent" {
    const allocator = std.testing.allocator;

    var parts: [1]Part = .{.{ .text = .{ .text = "Plan this feature" } }};
    const request = PromptAsyncRequest{
        .parts = &parts,
        .agent = "plan",
    };

    const json = try request.toJson(allocator);
    defer allocator.free(json);

    // Verify agent is included
    try std.testing.expect(std.mem.indexOf(u8, json, "\"agent\":\"plan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"parts\":") != null);
}

test "PromptAsyncRequest toJson with model" {
    const allocator = std.testing.allocator;

    var parts: [1]Part = .{.{ .text = .{ .text = "Hello" } }};
    const request = PromptAsyncRequest{
        .parts = &parts,
        .model = .{
            .providerID = "anthropic",
            .modelID = "claude-sonnet-4-20250514",
        },
    };

    const json = try request.toJson(allocator);
    defer allocator.free(json);

    // Verify model object is included
    try std.testing.expect(std.mem.indexOf(u8, json, "\"model\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"providerID\":\"anthropic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"modelID\":\"claude-sonnet-4-20250514\"") != null);
}

test "PromptAsyncRequest toJson with agent and model" {
    const allocator = std.testing.allocator;

    var parts: [1]Part = .{.{ .text = .{ .text = "Build this" } }};
    const request = PromptAsyncRequest{
        .parts = &parts,
        .agent = "build",
        .model = .{
            .providerID = "openai",
            .modelID = "gpt-4o",
        },
    };

    const json = try request.toJson(allocator);
    defer allocator.free(json);

    // Verify all fields are included
    try std.testing.expect(std.mem.indexOf(u8, json, "\"parts\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"agent\":\"build\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"model\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"providerID\":\"openai\"") != null);
}

test "createTextPrompt helper" {
    const allocator = std.testing.allocator;

    const prompt = try createTextPrompt(allocator, "Test message");
    defer allocator.free(prompt.parts);

    try std.testing.expectEqual(@as(usize, 1), prompt.parts.len);
    switch (prompt.parts[0]) {
        .text => |t| try std.testing.expectEqualStrings("Test message", t.text),
    }
}

test "HealthResponse structure" {
    const allocator = std.testing.allocator;

    const json = "{\"healthy\":true,\"version\":\"0.0.3\"}";
    const parsed = try std.json.parseFromSlice(HealthResponse, allocator, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expect(parsed.value.healthy);
    try std.testing.expectEqualStrings("0.0.3", parsed.value.version);
}

test "Session structure" {
    const allocator = std.testing.allocator;

    const json = "{\"id\":\"ses_123\",\"time\":{\"created\":1706900000,\"updated\":1706900100}}";
    const parsed = try std.json.parseFromSlice(Session, allocator, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("ses_123", parsed.value.id);
    try std.testing.expectEqual(@as(i64, 1706900000), parsed.value.time.created);
    try std.testing.expectEqual(@as(i64, 1706900100), parsed.value.time.updated);
}
