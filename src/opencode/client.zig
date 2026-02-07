const std = @import("std");
const protocol = @import("protocol.zig");
const sse = @import("sse.zig");

// =============================================================================
// Opencode HTTP Client
// =============================================================================
//
// HTTP client for Opencode REST API using std.http.Client.
// Provides typed methods for each API endpoint.
//
// =============================================================================

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.opencode);

/// Client error types
pub const ClientError = error{
    ConnectionFailed,
    Timeout,
    InvalidResponse,
    ServerError,
    SessionNotFound,
    BadRequest,
    OutOfMemory,
    HttpError,
};

/// HTTP client for Opencode REST API
pub const Client = struct {
    allocator: Allocator,
    base_url: []const u8,
    http_client: std.http.Client,

    /// Initialize client with base URL (e.g., "http://localhost:4096")
    pub fn init(allocator: Allocator, base_url: []const u8) !Client {
        return .{
            .allocator = allocator,
            .base_url = try allocator.dupe(u8, base_url),
            .http_client = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.base_url);
        self.http_client.deinit();
    }

    // =========================================================================
    // Health Check
    // =========================================================================

    /// GET /global/health - Check server health
    pub fn healthCheck(self: *Client) !protocol.HealthResponse {
        const uri_str = try std.fmt.allocPrint(self.allocator, "{s}/global/health", .{self.base_url});
        defer self.allocator.free(uri_str);

        const uri = std.Uri.parse(uri_str) catch |err| {
            log.err("Invalid health URI: {s} ({})", .{ uri_str, err });
            return error.InvalidResponse;
        };

        var req = self.http_client.request(.GET, uri, .{}) catch return error.ConnectionFailed;
        defer req.deinit();

        req.sendBodiless() catch return error.ConnectionFailed;

        var redirect_buffer: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch return error.ConnectionFailed;

        if (response.head.status != .ok) {
            log.err("Health check failed with status: {}", .{response.head.status});
            return error.ServerError;
        }

        var body_buffer: [8192]u8 = undefined;
        var body_reader = response.reader(&body_buffer);
        const body = body_reader.allocRemaining(self.allocator, std.Io.Limit.limited(1024 * 1024)) catch return error.InvalidResponse;
        defer self.allocator.free(body);

        const parsed = std.json.parseFromSlice(protocol.HealthResponse, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return error.InvalidResponse;
        defer parsed.deinit();

        return .{
            .healthy = parsed.value.healthy,
            .version = try self.allocator.dupe(u8, parsed.value.version),
        };
    }

    // =========================================================================
    // Configuration
    // =========================================================================

    /// GET /config - Get server configuration (includes default model)
    /// Returns parsed config response (caller must deinit)
    pub fn getConfig(self: *Client, directory: ?[]const u8) !std.json.Parsed(protocol.ConfigResponse) {
        const uri_str = if (directory) |dir|
            try std.fmt.allocPrint(self.allocator, "{s}/config?directory={s}", .{ self.base_url, dir })
        else
            try std.fmt.allocPrint(self.allocator, "{s}/config", .{self.base_url});
        defer self.allocator.free(uri_str);

        const uri = std.Uri.parse(uri_str) catch return error.InvalidResponse;

        var req = self.http_client.request(.GET, uri, .{}) catch return error.ConnectionFailed;
        defer req.deinit();

        req.sendBodiless() catch return error.ConnectionFailed;

        var redirect_buffer: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch return error.ConnectionFailed;

        if (response.head.status != .ok) {
            log.err("Get config failed with status: {}", .{response.head.status});
            return error.ServerError;
        }

        var body_buffer: [8192]u8 = undefined;
        var body_reader = response.reader(&body_buffer);
        const body = body_reader.allocRemaining(self.allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
            log.err("Failed to read config body: {}", .{err});
            return error.InvalidResponse;
        };
        defer self.allocator.free(body);

        return std.json.parseFromSlice(protocol.ConfigResponse, self.allocator, body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            const preview = if (body.len > 200) body[0..200] else body;
            log.err("Failed to parse config JSON: {} body={s}", .{ err, preview });
            return error.InvalidResponse;
        };
    }

    /// GET /global/config - Get global server configuration
    /// Returns parsed config response (caller must deinit)
    pub fn getGlobalConfig(self: *Client) !std.json.Parsed(protocol.ConfigResponse) {
        const uri_str = try std.fmt.allocPrint(self.allocator, "{s}/global/config", .{self.base_url});
        defer self.allocator.free(uri_str);

        const uri = std.Uri.parse(uri_str) catch return error.InvalidResponse;

        var req = self.http_client.request(.GET, uri, .{}) catch return error.ConnectionFailed;
        defer req.deinit();

        req.sendBodiless() catch return error.ConnectionFailed;

        var redirect_buffer: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch return error.ConnectionFailed;

        if (response.head.status != .ok) {
            log.err("Get global config failed with status: {}", .{response.head.status});
            return error.ServerError;
        }

        var body_buffer: [8192]u8 = undefined;
        var body_reader = response.reader(&body_buffer);
        const body = body_reader.allocRemaining(self.allocator, std.Io.Limit.limited(1024 * 1024)) catch return error.InvalidResponse;
        defer self.allocator.free(body);

        return std.json.parseFromSlice(protocol.ConfigResponse, self.allocator, body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return error.InvalidResponse;
    }

    /// GET /config/providers - Get available providers and models
    /// Returns parsed providers response (caller must deinit)
    pub fn getProviders(self: *Client, directory: ?[]const u8) !std.json.Parsed(protocol.ProvidersResponse) {
        const uri_str = if (directory) |dir|
            try std.fmt.allocPrint(self.allocator, "{s}/config/providers?directory={s}", .{ self.base_url, dir })
        else
            try std.fmt.allocPrint(self.allocator, "{s}/config/providers", .{self.base_url});
        defer self.allocator.free(uri_str);

        const uri = std.Uri.parse(uri_str) catch return error.InvalidResponse;

        var req = self.http_client.request(.GET, uri, .{}) catch return error.ConnectionFailed;
        defer req.deinit();

        req.sendBodiless() catch return error.ConnectionFailed;

        var redirect_buffer: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch return error.ConnectionFailed;

        if (response.head.status != .ok) {
            log.err("Get providers failed with status: {}", .{response.head.status});
            return error.ServerError;
        }

        var body_buffer: [8192]u8 = undefined;
        var body_reader = response.reader(&body_buffer);
        const body = body_reader.allocRemaining(self.allocator, std.Io.Limit.limited(1024 * 1024)) catch return error.InvalidResponse;
        defer self.allocator.free(body);

        return std.json.parseFromSlice(protocol.ProvidersResponse, self.allocator, body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return error.InvalidResponse;
    }

    // =========================================================================
    // Session Management
    // =========================================================================

    /// POST /session - Create a new session
    /// Returns the session ID
    pub fn createSession(self: *Client) ![]const u8 {
        const uri_str = try std.fmt.allocPrint(self.allocator, "{s}/session", .{self.base_url});
        defer self.allocator.free(uri_str);

        const uri = std.Uri.parse(uri_str) catch return error.InvalidResponse;

        var req = self.http_client.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch return error.ConnectionFailed;
        defer req.deinit();

        // Empty JSON body
        var body_data = "{}".*;
        req.sendBodyComplete(&body_data) catch return error.ConnectionFailed;

        var redirect_buffer: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch return error.ConnectionFailed;

        if (response.head.status != .ok and response.head.status != .created) {
            log.err("Create session failed with status: {}", .{response.head.status});
            return error.ServerError;
        }

        var body_buffer: [8192]u8 = undefined;
        var body_reader = response.reader(&body_buffer);
        const response_body = body_reader.allocRemaining(self.allocator, std.Io.Limit.limited(1024 * 1024)) catch return error.InvalidResponse;
        defer self.allocator.free(response_body);

        const parsed = std.json.parseFromSlice(protocol.Session, self.allocator, response_body, .{
            .ignore_unknown_fields = true,
        }) catch return error.InvalidResponse;
        defer parsed.deinit();

        return try self.allocator.dupe(u8, parsed.value.id);
    }

    /// DELETE /session/{id} - Delete a session
    pub fn deleteSession(self: *Client, session_id: []const u8) !void {
        const uri_str = try std.fmt.allocPrint(self.allocator, "{s}/session/{s}", .{ self.base_url, session_id });
        defer self.allocator.free(uri_str);

        const uri = std.Uri.parse(uri_str) catch return error.InvalidResponse;

        var req = self.http_client.request(.DELETE, uri, .{}) catch return error.ConnectionFailed;
        defer req.deinit();

        req.sendBodiless() catch return error.ConnectionFailed;

        var redirect_buffer: [4096]u8 = undefined;
        const response = req.receiveHead(&redirect_buffer) catch return error.ConnectionFailed;

        if (response.head.status != .ok and response.head.status != .no_content) {
            if (response.head.status == .not_found) {
                return error.SessionNotFound;
            }
            log.err("Delete session failed with status: {}", .{response.head.status});
            return error.ServerError;
        }
    }

    // =========================================================================
    // Messaging
    // =========================================================================

    /// POST /session/{id}/prompt_async - Send a message asynchronously
    /// Returns immediately (204 No Content), actual response via SSE
    pub fn sendPromptAsync(self: *Client, session_id: []const u8, prompt_request: protocol.PromptAsyncRequest) !void {
        const uri_str = try std.fmt.allocPrint(self.allocator, "{s}/session/{s}/prompt_async", .{ self.base_url, session_id });
        defer self.allocator.free(uri_str);

        const uri = std.Uri.parse(uri_str) catch return error.InvalidResponse;

        const body = try prompt_request.toJson(self.allocator);
        defer self.allocator.free(body);

        // Need to copy body to a mutable buffer for sendBodyComplete
        const body_buf = try self.allocator.alloc(u8, body.len);
        defer self.allocator.free(body_buf);
        @memcpy(body_buf, body);

        var req = self.http_client.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch return error.ConnectionFailed;
        defer req.deinit();

        req.sendBodyComplete(body_buf) catch return error.ConnectionFailed;

        var redirect_buffer: [4096]u8 = undefined;
        const response = req.receiveHead(&redirect_buffer) catch return error.ConnectionFailed;

        // Accept both 200 OK and 204 No Content
        if (response.head.status != .ok and response.head.status != .no_content) {
            if (response.head.status == .not_found) {
                return error.SessionNotFound;
            }
            if (response.head.status == .bad_request) {
                return error.BadRequest;
            }
            log.err("Send prompt async failed with status: {}", .{response.head.status});
            return error.ServerError;
        }
    }

    /// POST /session/{id}/abort - Abort the current generation
    /// Stops the agent without disconnecting the session
    /// Note: Uses a separate HTTP client to avoid thread safety issues with SSE connection
    pub fn abortSession(self: *Client, session_id: []const u8) !void {
        const uri_str = try std.fmt.allocPrint(self.allocator, "{s}/session/{s}/abort", .{ self.base_url, session_id });
        defer self.allocator.free(uri_str);

        const uri = std.Uri.parse(uri_str) catch return error.InvalidResponse;

        // Create a temporary HTTP client to avoid thread safety issues
        // The main http_client may be in use by the SSE reader thread
        var temp_client: std.http.Client = .{ .allocator = self.allocator };
        defer temp_client.deinit();

        var req = temp_client.request(.POST, uri, .{}) catch return error.ConnectionFailed;
        defer req.deinit();

        // POST requires a body in Zig std.http.Client; send minimal JSON body
        var body_data = "{}".*;
        req.sendBodyComplete(&body_data) catch return error.ConnectionFailed;

        var redirect_buffer: [4096]u8 = undefined;
        const response = req.receiveHead(&redirect_buffer) catch return error.ConnectionFailed;

        if (response.head.status != .ok and response.head.status != .no_content) {
            if (response.head.status == .not_found) {
                return error.SessionNotFound;
            }
            log.err("Abort session failed with status: {}", .{response.head.status});
            return error.ServerError;
        }

        log.info("Session aborted successfully", .{});
    }

    /// POST /session/{id}/message - Send a message synchronously
    /// Returns the response message (blocking call)
    pub fn sendMessageSync(self: *Client, session_id: []const u8, prompt_request: protocol.PromptAsyncRequest) ![]const u8 {
        const uri_str = try std.fmt.allocPrint(self.allocator, "{s}/session/{s}/message", .{ self.base_url, session_id });
        defer self.allocator.free(uri_str);

        const uri = std.Uri.parse(uri_str) catch return error.InvalidResponse;

        const body = try prompt_request.toJson(self.allocator);
        defer self.allocator.free(body);

        // Need to copy body to a mutable buffer for sendBodyComplete
        const body_buf = try self.allocator.alloc(u8, body.len);
        defer self.allocator.free(body_buf);
        @memcpy(body_buf, body);

        var req = self.http_client.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch return error.ConnectionFailed;
        defer req.deinit();

        req.sendBodyComplete(body_buf) catch return error.ConnectionFailed;

        var redirect_buffer: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch return error.ConnectionFailed;

        if (response.head.status != .ok) {
            if (response.head.status == .not_found) {
                return error.SessionNotFound;
            }
            log.err("Send message sync failed with status: {}", .{response.head.status});
            return error.ServerError;
        }

        var body_buffer: [8192]u8 = undefined;
        var body_reader = response.reader(&body_buffer);
        return body_reader.allocRemaining(self.allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch return error.InvalidResponse;
    }

    // =========================================================================
    // Question / Permission Responses
    // =========================================================================

    /// POST /question/{requestID}/reply - Reply to a question from the agent
    /// `body` is pre-serialized JSON: {"answers": [["label1"], ["label2", "label3"]]}
    /// Uses a separate HTTP client to avoid thread safety issues with SSE connection
    pub fn replyToQuestion(self: *Client, request_id: []const u8, body: []const u8) !void {
        const uri_str = try std.fmt.allocPrint(self.allocator, "{s}/question/{s}/reply", .{ self.base_url, request_id });
        defer self.allocator.free(uri_str);

        const uri = std.Uri.parse(uri_str) catch return error.InvalidResponse;

        var temp_client: std.http.Client = .{ .allocator = self.allocator };
        defer temp_client.deinit();

        var req = temp_client.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch return error.ConnectionFailed;
        defer req.deinit();

        const body_buf = try self.allocator.alloc(u8, body.len);
        defer self.allocator.free(body_buf);
        @memcpy(body_buf, body);

        req.sendBodyComplete(body_buf) catch return error.ConnectionFailed;

        var redirect_buffer: [4096]u8 = undefined;
        const response = req.receiveHead(&redirect_buffer) catch return error.ConnectionFailed;

        if (response.head.status != .ok) {
            if (response.head.status == .not_found) {
                log.err("Question {s} not found (may have already been answered)", .{request_id});
                return error.SessionNotFound;
            }
            log.err("Reply to question failed with status: {}", .{response.head.status});
            return error.ServerError;
        }

        log.info("Replied to question {s}", .{request_id});
    }

    /// POST /question/{requestID}/reject - Reject/dismiss a question
    /// Uses a separate HTTP client to avoid thread safety issues with SSE connection
    pub fn rejectQuestion(self: *Client, request_id: []const u8) !void {
        const uri_str = try std.fmt.allocPrint(self.allocator, "{s}/question/{s}/reject", .{ self.base_url, request_id });
        defer self.allocator.free(uri_str);

        const uri = std.Uri.parse(uri_str) catch return error.InvalidResponse;

        var temp_client: std.http.Client = .{ .allocator = self.allocator };
        defer temp_client.deinit();

        var req = temp_client.request(.POST, uri, .{}) catch return error.ConnectionFailed;
        defer req.deinit();

        var body_data = "{}".*;
        req.sendBodyComplete(&body_data) catch return error.ConnectionFailed;

        var redirect_buffer: [4096]u8 = undefined;
        const response = req.receiveHead(&redirect_buffer) catch return error.ConnectionFailed;

        if (response.head.status != .ok) {
            if (response.head.status == .not_found) {
                log.err("Question {s} not found for rejection", .{request_id});
                return error.SessionNotFound;
            }
            log.err("Reject question failed with status: {}", .{response.head.status});
            return error.ServerError;
        }

        log.info("Rejected question {s}", .{request_id});
    }

    // =========================================================================
    // SSE Event Stream
    // =========================================================================

    /// Connection to SSE event stream (heap-allocated to keep buffer addresses stable)
    pub const EventStreamConnection = struct {
        allocator: Allocator,
        request: std.http.Client.Request,
        response: std.http.Client.Response,
        parser: sse.SseParser,
        // read_buf is intentionally small: readSliceShort loops until the
        // buffer is full, so a large buffer delays event delivery. At 256
        // bytes, we return after ~1 SSE event instead of batching ~20.
        read_buf: [256]u8 = undefined,
        body_buffer: [8192]u8 = undefined,
        redirect_buffer: [4096]u8 = undefined,
        body_reader: ?*std.Io.Reader = null,

        pub fn deinit(self: *EventStreamConnection) void {
            self.parser.deinit();
            self.request.deinit();
            // Free the heap-allocated struct itself
            self.allocator.destroy(self);
        }

        /// Read the next SSE event from the stream
        /// Returns null if no complete event is available yet
        pub fn readEvent(self: *EventStreamConnection) !?sse.SseEvent {
            // First check if we have a complete event from previous data
            if (try self.parser.feed("")) |event| {
                return event;
            }

            // Get or initialize body reader (must only call response.reader() once)
            const reader = self.body_reader orelse blk: {
                self.body_reader = self.response.reader(&self.body_buffer);
                break :blk self.body_reader.?;
            };

            // readSliceShort loops until the output buffer is full. With a
            // small 256-byte read_buf, it returns after ~1 SSE event instead
            // of batching many events into a large buffer.
            const n = reader.readSliceShort(&self.read_buf) catch |err| {
                log.err("Error reading from SSE stream: {}", .{err});
                return error.ConnectionFailed;
            };

            if (n == 0) {
                return error.ConnectionFailed;
            }

            return try self.parser.feed(self.read_buf[0..n]);
        }
    };

    /// GET /event - Connect to SSE event stream (project-scoped bus events)
    /// Returns a heap-allocated connection (caller owns, call deinit to free)
    pub fn connectEventStream(self: *Client) !*EventStreamConnection {
        const uri_str = try std.fmt.allocPrint(self.allocator, "{s}/event", .{self.base_url});
        defer self.allocator.free(uri_str);

        const uri = std.Uri.parse(uri_str) catch return error.InvalidResponse;

        var req = self.http_client.request(.GET, uri, .{
            .extra_headers = &.{
                .{ .name = "Accept", .value = "text/event-stream" },
                .{ .name = "Cache-Control", .value = "no-cache" },
            },
        }) catch return error.ConnectionFailed;
        errdefer req.deinit();

        req.sendBodiless() catch return error.ConnectionFailed;

        // Heap-allocate to keep buffer addresses stable after return
        const conn = try self.allocator.create(EventStreamConnection);
        errdefer self.allocator.destroy(conn);

        conn.* = .{
            .allocator = self.allocator,
            .request = req,
            .response = undefined,
            .parser = sse.SseParser.init(self.allocator),
        };

        // Use conn.request (not req) since req was moved into the struct
        conn.response = conn.request.receiveHead(&conn.redirect_buffer) catch return error.ConnectionFailed;

        if (conn.response.head.status != .ok) {
            log.err("Connect event stream failed with status: {}", .{conn.response.head.status});
            return error.ServerError;
        }

        return conn;
    }

    // =========================================================================
    // Session Messages (for Subagent Drill-In Modal)
    // =========================================================================

    /// Message part from session messages endpoint
    pub const SessionMessagePart = struct {
        type: []const u8,
        text: ?[]const u8 = null,
        toolName: ?[]const u8 = null,
        state: ?ToolState = null,

        pub const ToolState = struct {
            title: ?[]const u8 = null,
            status: ?[]const u8 = null,
        };
    };

    /// Single message from session messages endpoint
    pub const SessionMessage = struct {
        id: ?[]const u8 = null,
        role: ?[]const u8 = null,
        parts: ?[]const SessionMessagePart = null,
    };

    /// Response from session messages endpoint
    pub const SessionMessagesResponse = struct {
        messages: []const SessionMessage = &.{},
    };

    /// Parsed modal message suitable for display
    pub const ModalMessage = struct {
        role: ModalRole,
        content: ?[]const u8 = null,
        tool_name: ?[]const u8 = null,
        tool_title: ?[]const u8 = null,

        pub const ModalRole = enum {
            user,
            assistant,
            tool,
        };

        pub fn deinit(self: *ModalMessage, alloc: Allocator) void {
            if (self.content) |c| alloc.free(c);
            if (self.tool_name) |n| alloc.free(n);
            if (self.tool_title) |t| alloc.free(t);
        }
    };

    /// GET /session/{id}/messages - Fetch messages for a session
    /// Uses a separate HTTP client to avoid thread safety issues with SSE connection.
    /// Returns owned array of ModalMessages (caller must free each and the slice).
    pub fn fetchSessionMessages(self: *Client, session_id: []const u8) ![]ModalMessage {
        const uri_str = try std.fmt.allocPrint(self.allocator, "{s}/session/{s}/messages", .{ self.base_url, session_id });
        defer self.allocator.free(uri_str);

        const uri = std.Uri.parse(uri_str) catch return error.InvalidResponse;

        var temp_client: std.http.Client = .{ .allocator = self.allocator };
        defer temp_client.deinit();

        var req = temp_client.request(.GET, uri, .{}) catch return error.ConnectionFailed;
        defer req.deinit();

        req.sendBodiless() catch return error.ConnectionFailed;

        var redirect_buffer: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch return error.ConnectionFailed;

        if (response.head.status == .not_found) {
            return error.SessionNotFound;
        }

        if (response.head.status != .ok) {
            log.err("Fetch session messages failed with status: {}", .{response.head.status});
            return error.ServerError;
        }

        var body_buffer: [8192]u8 = undefined;
        var body_reader = response.reader(&body_buffer);
        const body = body_reader.allocRemaining(self.allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch return error.InvalidResponse;
        defer self.allocator.free(body);

        return parseSessionMessages(self.allocator, body);
    }
};

/// Parse session messages JSON body into ModalMessage array.
/// Tries the structured { "messages": [...] } format first, then falls back to raw array [...].
fn parseSessionMessages(allocator: Allocator, body: []const u8) ![]Client.ModalMessage {
    // Try structured response { "messages": [...] }
    if (std.json.parseFromSlice(Client.SessionMessagesResponse, allocator, body, .{
        .ignore_unknown_fields = true,
    })) |parsed| {
        defer parsed.deinit();
        return convertMessages(allocator, parsed.value.messages);
    } else |_| {}

    // Fallback: try parsing as raw array of messages
    if (std.json.parseFromSlice([]const Client.SessionMessage, allocator, body, .{
        .ignore_unknown_fields = true,
    })) |parsed| {
        defer parsed.deinit();
        return convertMessages(allocator, parsed.value);
    } else |_| {}

    log.warn("Failed to parse session messages response", .{});
    return error.InvalidResponse;
}

fn convertMessages(allocator: Allocator, messages: []const Client.SessionMessage) ![]Client.ModalMessage {
    var result: std.ArrayList(Client.ModalMessage) = .{};
    errdefer {
        for (result.items) |*m| m.deinit(allocator);
        result.deinit(allocator);
    }

    for (messages) |msg| {
        const role_str = msg.role orelse "assistant";
        const parts = msg.parts orelse continue;

        for (parts) |part| {
            if (std.mem.eql(u8, part.type, "tool-invocation") or std.mem.eql(u8, part.type, "tool-result")) {
                try result.append(allocator, .{
                    .role = .tool,
                    .tool_name = if (part.toolName) |n| try allocator.dupe(u8, n) else null,
                    .tool_title = if (part.state) |s| (if (s.title) |t| try allocator.dupe(u8, t) else null) else null,
                });
            } else if (std.mem.eql(u8, part.type, "text")) {
                if (part.text) |text| {
                    if (text.len > 0) {
                        const role: Client.ModalMessage.ModalRole = if (std.mem.eql(u8, role_str, "user")) .user else .assistant;
                        try result.append(allocator, .{
                            .role = role,
                            .content = try allocator.dupe(u8, text),
                        });
                    }
                }
            }
        }
    }

    return result.toOwnedSlice(allocator);
}

// =============================================================================
// Tests
// =============================================================================

test "client init and deinit" {
    const allocator = std.testing.allocator;

    var client = try Client.init(allocator, "http://localhost:4096");
    defer client.deinit();

    try std.testing.expectEqualStrings("http://localhost:4096", client.base_url);
}

test "EventStreamConnection parser integration" {
    // Test that EventStreamConnection correctly uses the SSE parser
    // This doesn't require a real server
    const allocator = std.testing.allocator;

    var parser = sse.SseParser.init(allocator);
    defer parser.deinit();

    // Simulate receiving SSE data
    const data = "data: {\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"ses_123\"}}\n\n";
    var event = try parser.feed(data);
    try std.testing.expect(event != null);
    defer event.?.deinit(allocator);

    try std.testing.expect(event.?.data != null);
    try std.testing.expect(std.mem.indexOf(u8, event.?.data.?, "session.idle") != null);
}

// Integration tests - skipped in unit test runs (require live server)
test "integration: health check" {
    // Skip in normal test runs - requires live server
    if (true) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var client = try Client.init(allocator, "http://localhost:4096");
    defer client.deinit();

    const health = try client.healthCheck();
    defer allocator.free(health.version);

    try std.testing.expect(health.healthy);
}

test "integration: create and delete session" {
    // Skip in normal test runs - requires live server
    if (true) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var client = try Client.init(allocator, "http://localhost:4096");
    defer client.deinit();

    const session_id = try client.createSession();
    defer allocator.free(session_id);

    try std.testing.expect(session_id.len > 0);

    try client.deleteSession(session_id);
}

test "integration: send prompt async" {
    // Skip in normal test runs - requires live server
    if (true) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var client = try Client.init(allocator, "http://localhost:4096");
    defer client.deinit();

    const session_id = try client.createSession();
    defer allocator.free(session_id);

    var parts: [1]protocol.Part = .{.{ .text = .{ .text = "Hello" } }};
    try client.sendPromptAsync(session_id, .{ .parts = &parts });

    try client.deleteSession(session_id);
}

test "parseSessionMessages with structured response" {
    const allocator = std.testing.allocator;

    const json =
        \\{"messages":[
        \\  {"id":"msg_1","role":"user","parts":[{"type":"text","text":"Explore this codebase"}]},
        \\  {"id":"msg_2","role":"assistant","parts":[
        \\    {"type":"tool-invocation","toolName":"Read","state":{"title":"Read(build.zig)","status":"completed"}},
        \\    {"type":"text","text":"This is a Zig project."}
        \\  ]}
        \\]}
    ;

    const messages = try parseSessionMessages(allocator, json);
    defer {
        for (messages) |*m| m.deinit(allocator);
        allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 3), messages.len);

    // First message: user text
    try std.testing.expectEqual(Client.ModalMessage.ModalRole.user, messages[0].role);
    try std.testing.expectEqualStrings("Explore this codebase", messages[0].content.?);
    try std.testing.expect(messages[0].tool_name == null);

    // Second message: tool invocation
    try std.testing.expectEqual(Client.ModalMessage.ModalRole.tool, messages[1].role);
    try std.testing.expectEqualStrings("Read", messages[1].tool_name.?);
    try std.testing.expectEqualStrings("Read(build.zig)", messages[1].tool_title.?);

    // Third message: assistant text
    try std.testing.expectEqual(Client.ModalMessage.ModalRole.assistant, messages[2].role);
    try std.testing.expectEqualStrings("This is a Zig project.", messages[2].content.?);
}

test "parseSessionMessages with empty session" {
    const allocator = std.testing.allocator;

    const json = \\{"messages":[]}
    ;

    const messages = try parseSessionMessages(allocator, json);
    defer allocator.free(messages);

    try std.testing.expectEqual(@as(usize, 0), messages.len);
}

test "parseSessionMessages with raw array format" {
    const allocator = std.testing.allocator;

    const json =
        \\[{"id":"msg_1","role":"user","parts":[{"type":"text","text":"Hello"}]}]
    ;

    const messages = try parseSessionMessages(allocator, json);
    defer {
        for (messages) |*m| m.deinit(allocator);
        allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(Client.ModalMessage.ModalRole.user, messages[0].role);
    try std.testing.expectEqualStrings("Hello", messages[0].content.?);
}

test "parseSessionMessages with malformed response" {
    const allocator = std.testing.allocator;

    const json = \\not valid json at all
    ;

    const result = parseSessionMessages(allocator, json);
    try std.testing.expectError(error.InvalidResponse, result);
}

test "parseSessionMessages skips empty text parts" {
    const allocator = std.testing.allocator;

    const json =
        \\{"messages":[
        \\  {"id":"msg_1","role":"assistant","parts":[
        \\    {"type":"text","text":""},
        \\    {"type":"text","text":"Actual content"}
        \\  ]}
        \\]}
    ;

    const messages = try parseSessionMessages(allocator, json);
    defer {
        for (messages) |*m| m.deinit(allocator);
        allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("Actual content", messages[0].content.?);
}
