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

        const uri = std.Uri.parse(uri_str) catch return error.InvalidResponse;

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
    // SSE Event Stream
    // =========================================================================

    /// Connection to SSE event stream (heap-allocated to keep buffer addresses stable)
    pub const EventStreamConnection = struct {
        allocator: Allocator,
        request: std.http.Client.Request,
        response: std.http.Client.Response,
        parser: sse.SseParser,
        buffer: [4096]u8 = undefined,
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

            const n = reader.readSliceShort(&self.buffer) catch |err| {
                log.err("Error reading from SSE stream: {}", .{err});
                return error.ConnectionFailed;
            };

            if (n == 0) {
                // Connection closed
                return null;
            }

            // Feed data to parser
            return try self.parser.feed(self.buffer[0..n]);
        }
    };

    /// GET /global/event - Connect to SSE event stream
    /// Returns a heap-allocated connection (caller owns, call deinit to free)
    pub fn connectEventStream(self: *Client) !*EventStreamConnection {
        const uri_str = try std.fmt.allocPrint(self.allocator, "{s}/global/event", .{self.base_url});
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
};

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
