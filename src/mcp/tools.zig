const std = @import("std");
const framework = @import("framework.zig");
const registry = @import("registry.zig");
const protocol = @import("protocol.zig");
const internal_protocol = @import("internal_protocol.zig");

const Allocator = std.mem.Allocator;
const Context = framework.Context;
const Result = framework.Result;
const Server = framework.Server;

// =============================================================================
// Tool Parameter Types
// =============================================================================

pub const AddCommentParams = struct {
    client_id: []const u8,
    file: []const u8,
    line: u32,
    text: []const u8,
};

pub const GetCommentsParams = struct {
    client_id: []const u8,
};

// =============================================================================
// Daemon State - Shared state accessible by tool handlers
// =============================================================================

/// Callback for sending messages to TUI clients
pub const SendToTuiCallback = *const fn (client_id: []const u8, msg: []const u8) bool;

/// Pending request tracker for async responses
pub const PendingRequest = struct {
    adapter_id: registry.SessionId,
    mcp_id: internal_protocol.McpId,
    method: []const u8,
    tui_client_id: registry.SessionId,
    created_at: i64,
};

/// State shared between daemon and tool handlers
pub const DaemonState = struct {
    allocator: Allocator,
    tui_clients: *registry.ClientRegistry,
    pending_requests: *std.AutoHashMap([36]u8, PendingRequest),
    current_adapter_id: ?registry.SessionId,
    current_request_id: ?[]const u8,
    current_mcp_id: internal_protocol.McpId,

    /// Send a message to a TUI client by ID
    pub fn sendToTui(self: *DaemonState, client_id: []const u8, msg: []const u8) !void {
        const client = self.tui_clients.getByIdString(client_id) orelse
            return error.ClientNotFound;
        try client.stream.writeAll(msg);
    }

    /// Store a pending request for async response correlation
    pub fn storePendingRequest(self: *DaemonState, tui_client_id: registry.SessionId, method: []const u8) !void {
        if (self.current_request_id == null or self.current_adapter_id == null) return;

        var request_id: [36]u8 = undefined;
        @memcpy(&request_id, self.current_request_id.?[0..36]);

        try self.pending_requests.put(request_id, .{
            .adapter_id = self.current_adapter_id.?,
            .mcp_id = switch (self.current_mcp_id) {
                .string => |s| .{ .string = try self.allocator.dupe(u8, s) },
                .number => |n| .{ .number = n },
                .null_value => .{ .null_value = {} },
            },
            .method = try self.allocator.dupe(u8, method),
            .tui_client_id = tui_client_id,
            .created_at = std.time.timestamp(),
        });
    }
};

// =============================================================================
// Tool Handlers
// =============================================================================

/// List all connected skim TUI clients
pub fn listClients(ctx: *Context, _: ?std.json.Value) Result {
    const state = ctx.getUserData(DaemonState) orelse
        return Result.mcpError(framework.ErrorCode.internal_error, "No daemon state");

    const entries = state.tui_clients.list(ctx.allocator) catch
        return Result.mcpError(framework.ErrorCode.internal_error, "Failed to list clients");
    defer ctx.allocator.free(entries);

    if (entries.len == 0) {
        return Result.text(ctx.allocator, "No skim clients connected.") catch
            return Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");
    }

    // Build response text
    var output = std.ArrayList(u8).init(ctx.allocator);
    defer output.deinit();

    output.appendSlice("Connected skim clients:\n") catch
        return Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");

    for (entries) |entry| {
        output.writer().print("- {s} ({s} in {s})\n", .{
            entry.id,
            entry.diff_ref,
            entry.cwd,
        }) catch return Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");
    }

    const text = output.toOwnedSlice() catch
        return Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");

    const content = ctx.allocator.alloc(framework.Content, 1) catch {
        ctx.allocator.free(text);
        return Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");
    };
    content[0] = .{ .type = .text, .text = text };

    return .{ .success = .{ .content = content } };
}

/// Add a comment to a specific line in a skim client
pub fn addComment(ctx: *Context, args: ?std.json.Value) Result {
    const state = ctx.getUserData(DaemonState) orelse
        return Result.mcpError(framework.ErrorCode.internal_error, "No daemon state");

    const params = framework.parseParams(AddCommentParams, ctx.allocator, args) catch |err| {
        return switch (err) {
            error.MissingParams => Result.mcpError(framework.ErrorCode.invalid_params, "Missing arguments"),
            error.InvalidParams => Result.mcpError(framework.ErrorCode.invalid_params, "Invalid arguments"),
            error.MissingField => Result.mcpError(framework.ErrorCode.invalid_params, "Missing required field"),
            error.InvalidType => Result.mcpError(framework.ErrorCode.invalid_params, "Invalid field type"),
            else => Result.mcpError(framework.ErrorCode.internal_error, "Failed to parse params"),
        };
    };
    defer ctx.allocator.free(params.client_id);
    defer ctx.allocator.free(params.file);
    defer ctx.allocator.free(params.text);

    // Find TUI client
    const client = state.tui_clients.getByIdString(params.client_id) orelse
        return Result.textError(ctx.allocator, "Client not found") catch
            return Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");

    // Encode and send add_comment message to TUI
    const msg = protocol.encodeAddComment(ctx.allocator, .{
        .file = params.file,
        .line = params.line,
        .text = params.text,
    }) catch return Result.mcpError(framework.ErrorCode.internal_error, "Failed to encode message");
    defer ctx.allocator.free(msg);

    // Store pending request for async response
    state.storePendingRequest(client.id, "add_comment") catch {};

    client.stream.writeAll(msg) catch
        return Result.textError(ctx.allocator, "Failed to send to client") catch
            return Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");

    // Return pending result - actual result will come async
    return Result.text(ctx.allocator, "Comment request sent") catch
        return Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");
}

/// Get all comments from a skim client
pub fn getComments(ctx: *Context, args: ?std.json.Value) Result {
    const state = ctx.getUserData(DaemonState) orelse
        return Result.mcpError(framework.ErrorCode.internal_error, "No daemon state");

    const params = framework.parseParams(GetCommentsParams, ctx.allocator, args) catch |err| {
        return switch (err) {
            error.MissingParams => Result.mcpError(framework.ErrorCode.invalid_params, "Missing arguments"),
            error.InvalidParams => Result.mcpError(framework.ErrorCode.invalid_params, "Invalid arguments"),
            error.MissingField => Result.mcpError(framework.ErrorCode.invalid_params, "Missing required field"),
            error.InvalidType => Result.mcpError(framework.ErrorCode.invalid_params, "Invalid field type"),
            else => Result.mcpError(framework.ErrorCode.internal_error, "Failed to parse params"),
        };
    };
    defer ctx.allocator.free(params.client_id);

    // Find TUI client
    const client = state.tui_clients.getByIdString(params.client_id) orelse
        return Result.textError(ctx.allocator, "Client not found") catch
            return Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");

    // Encode and send get_comments message to TUI
    const msg = protocol.encodeGetComments(ctx.allocator) catch
        return Result.mcpError(framework.ErrorCode.internal_error, "Failed to encode message");
    defer ctx.allocator.free(msg);

    // Store pending request for async response
    state.storePendingRequest(client.id, "get_comments") catch {};

    client.stream.writeAll(msg) catch
        return Result.textError(ctx.allocator, "Failed to send to client") catch
            return Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");

    // Return pending result - actual result will come async
    return Result.text(ctx.allocator, "Comments request sent") catch
        return Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");
}

// =============================================================================
// Server Setup
// =============================================================================

/// Create and configure the skim MCP server
pub fn createServer(allocator: Allocator) !Server {
    var server = Server.init(allocator, .{
        .name = "skim-mcp",
        .version = "0.1.0",
    });

    // Register tools
    try server.tool(
        "list_clients",
        "List all connected skim instances",
        null,
        listClients,
    );

    try server.tool(
        "add_comment",
        "Add a review comment to a specific line",
        AddCommentParams,
        addComment,
    );

    try server.tool(
        "get_comments",
        "Get all comments from a skim instance",
        GetCommentsParams,
        getComments,
    );

    return server;
}

// =============================================================================
// Tests
// =============================================================================

test "create server with tools" {
    const allocator = std.testing.allocator;

    var server = try createServer(allocator);
    defer server.deinit();

    try std.testing.expectEqual(@as(usize, 3), server.tools.items.len);
    try std.testing.expectEqualStrings("list_clients", server.tools.items[0].name);
    try std.testing.expectEqualStrings("add_comment", server.tools.items[1].name);
    try std.testing.expectEqualStrings("get_comments", server.tools.items[2].name);
}

test "encode tools list" {
    const allocator = std.testing.allocator;

    var server = try createServer(allocator);
    defer server.deinit();

    const tools_json = try server.encodeToolsListResponse(allocator);
    defer allocator.free(tools_json);

    // Verify it contains our tools
    try std.testing.expect(std.mem.indexOf(u8, tools_json, "list_clients") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_json, "add_comment") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_json, "get_comments") != null);
}

test "encode initialize response" {
    const allocator = std.testing.allocator;

    var server = try createServer(allocator);
    defer server.deinit();

    const init_json = try server.encodeInitializeResponse(allocator);
    defer allocator.free(init_json);

    try std.testing.expect(std.mem.indexOf(u8, init_json, "skim-mcp") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_json, "0.1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_json, "protocolVersion") != null);
}
