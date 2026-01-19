//! TCP client for connecting to TUI server sessions.
//!
//! Provides connection management and request/response handling for CLI commands.

const std = @import("std");
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const session_mgr = @import("../mcp/session.zig");

// =============================================================================
// Error Types
// =============================================================================

pub const ClientError = error{
    NoSessionsRunning,
    AmbiguousSessions,
    SessionNotFound,
    ConnectionFailed,
    RequestFailed,
    InvalidResponse,
    ServerError,
};

// =============================================================================
// Client
// =============================================================================

/// TCP client for communicating with a TUI server session
pub const Client = struct {
    allocator: Allocator,
    stream: net.Stream,

    /// Connect to a TUI server on the specified port
    pub fn connect(allocator: Allocator, port: u16) !Client {
        const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
        const stream = net.tcpConnectToAddress(address) catch {
            return error.ConnectionFailed;
        };

        return .{
            .allocator = allocator,
            .stream = stream,
        };
    }

    pub fn deinit(self: *Client) void {
        self.stream.close();
    }

    /// Send a request and wait for response
    /// Returns the parsed JSON response or an error
    pub fn request(self: *Client, method: []const u8, id: []const u8, params: ?std.json.Value) !Response {
        // Build request JSON
        var request_buf: std.ArrayList(u8) = .{};
        defer request_buf.deinit(self.allocator);

        const writer = request_buf.writer(self.allocator);
        try writer.print("{{\"method\":{f},\"id\":{f}", .{
            std.json.fmt(method, .{}),
            std.json.fmt(id, .{}),
        });

        if (params) |p| {
            try writer.writeAll(",\"params\":");
            // Serialize params using Stringify
            var alloc_writer: std.io.Writer.Allocating = .init(self.allocator);
            defer alloc_writer.deinit();
            var stringify: std.json.Stringify = .{ .writer = &alloc_writer.writer };
            stringify.write(p) catch return error.RequestFailed;
            try writer.writeAll(alloc_writer.written());
        }

        try writer.writeAll("}\n");

        // Send request
        self.stream.writeAll(request_buf.items) catch return error.RequestFailed;

        // Read response (newline-delimited)
        var response_buf: [65536]u8 = undefined;
        var total_read: usize = 0;

        while (total_read < response_buf.len) {
            const bytes_read = self.stream.read(response_buf[total_read..]) catch return error.RequestFailed;
            if (bytes_read == 0) break;
            total_read += bytes_read;

            // Check for newline
            if (std.mem.indexOfScalar(u8, response_buf[0..total_read], '\n')) |_| {
                break;
            }
        }

        if (total_read == 0) return error.InvalidResponse;

        // Trim newline
        var response_len = total_read;
        if (response_len > 0 and response_buf[response_len - 1] == '\n') {
            response_len -= 1;
        }

        // Parse response
        return parseResponse(self.allocator, response_buf[0..response_len]);
    }
};

// =============================================================================
// Response Types
// =============================================================================

pub const Response = union(enum) {
    result: std.json.Value,
    err: struct {
        code: i32,
        message: []const u8,
    },

    pub fn deinit(self: *Response, allocator: Allocator) void {
        switch (self.*) {
            .result => |r| freeJsonValue(allocator, r),
            .err => |e| allocator.free(e.message),
        }
    }
};

fn parseResponse(allocator: Allocator, data: []const u8) !Response {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
        return error.InvalidResponse;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;

    const obj = root.object;

    // Check for error
    if (obj.get("error")) |err_val| {
        if (err_val == .object) {
            const err_obj = err_val.object;
            const code = if (err_obj.get("code")) |c| switch (c) {
                .integer => |i| @as(i32, @intCast(i)),
                else => -1,
            } else -1;

            const message = if (err_obj.get("message")) |m| switch (m) {
                .string => |s| try allocator.dupe(u8, s),
                else => try allocator.dupe(u8, "Unknown error"),
            } else try allocator.dupe(u8, "Unknown error");

            return .{ .err = .{ .code = code, .message = message } };
        }
    }

    // Check for result
    if (obj.get("result")) |result_val| {
        return .{ .result = try cloneJsonValue(allocator, result_val) };
    }

    return error.InvalidResponse;
}

// =============================================================================
// Auto-Connect
// =============================================================================

/// Find and connect to appropriate session
/// - If session_pid provided, connect to that specific session
/// - If only one session, connect to it
/// - If multiple sessions and one matches cwd, connect to it
/// - Otherwise error with AmbiguousSessions
pub fn autoConnect(allocator: Allocator, session_pid: ?posix.pid_t) !Client {
    var sm = session_mgr.SessionManager.init(allocator) catch {
        return error.NoSessionsRunning;
    };
    defer sm.deinit();

    const sessions = sm.listSessions() catch {
        return error.NoSessionsRunning;
    };
    defer {
        for (sessions) |*s| {
            var sess = s.*;
            sess.deinit(allocator);
        }
        allocator.free(sessions);
    }

    if (sessions.len == 0) {
        return error.NoSessionsRunning;
    }

    if (session_pid) |pid| {
        // Explicit session requested
        for (sessions) |s| {
            if (s.pid == pid) {
                return Client.connect(allocator, s.port);
            }
        }
        return error.SessionNotFound;
    }

    if (sessions.len == 1) {
        return Client.connect(allocator, sessions[0].port);
    }

    // Multiple sessions - try cwd match
    const cwd = std.process.getCwdAlloc(allocator) catch {
        return error.AmbiguousSessions;
    };
    defer allocator.free(cwd);

    for (sessions) |s| {
        if (std.mem.eql(u8, s.cwd, cwd)) {
            return Client.connect(allocator, s.port);
        }
    }

    return error.AmbiguousSessions;
}

// =============================================================================
// JSON Helpers
// =============================================================================

fn cloneJsonValue(allocator: Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var new_arr = std.json.Array.initCapacity(allocator, arr.items.len) catch return error.OutOfMemory;
            for (arr.items) |item| {
                new_arr.appendAssumeCapacity(try cloneJsonValue(allocator, item));
            }
            break :blk .{ .array = new_arr };
        },
        .object => |obj| blk: {
            var new_obj = std.json.ObjectMap.init(allocator);
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try cloneJsonValue(allocator, entry.value_ptr.*);
                try new_obj.put(key, val);
            }
            break :blk .{ .object = new_obj };
        },
    };
}

fn freeJsonValue(allocator: Allocator, value: std.json.Value) void {
    switch (value) {
        .object => |obj| {
            var map = obj;
            var it = map.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            map.deinit();
        },
        .array => |arr| {
            var list = arr;
            for (list.items) |item| {
                freeJsonValue(allocator, item);
            }
            list.deinit();
        },
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        else => {},
    }
}

// =============================================================================
// Tests
// =============================================================================

test "parseResponse with result" {
    const allocator = std.testing.allocator;
    const data = "{\"result\":{\"success\":true}}";

    var response = try parseResponse(allocator, data);
    defer response.deinit(allocator);

    try std.testing.expect(response == .result);
}

test "parseResponse with error" {
    const allocator = std.testing.allocator;
    const data = "{\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}";

    var response = try parseResponse(allocator, data);
    defer response.deinit(allocator);

    try std.testing.expect(response == .err);
    try std.testing.expectEqual(@as(i32, -32601), response.err.code);
}
