//! MCP Adapter - Bridge between AI agents (JSON-RPC over stdio) and TUI sessions.
//!
//! The adapter speaks MCP JSON-RPC over stdin/stdout with AI agents (Claude, etc.)
//! and connects directly to TUI sessions via TCP for tool execution.
//!
//! Architecture:
//! ```
//! AI Agent (Claude Desktop, etc.)
//!     │
//!     │ JSON-RPC over stdio
//!     ▼
//! MCP Adapter (skim mcp --stdio)
//!     │
//!     │ Discovers sessions via ~/.skim/sessions/
//!     │ Connects to TUI socket on-demand
//!     ▼
//! TUI Server (TCP)
//! ```

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const framework = @import("framework.zig");
const session_mgr = @import("session.zig");
const cli_client = @import("../cli/client.zig");
const skim_io = @import("skim_io");

// =============================================================================
// Write Buffers (Zig 0.15 requires buffers for file.writer())
// =============================================================================

var stdout_buffer: [4096]u8 = undefined;
var stdin_buffer: [65536]u8 = undefined;

/// Returned from `initialize` and surfaced by every MCP client. Tool
/// descriptions can only speak for one call; this is where the ordering between
/// them lives — get the diff before commenting, list before replying — along
/// with the one thing a model reliably gets wrong: omitting `author`, which
/// silently files its reply under the reviewer's name.
const server_instructions =
    \\skim is a terminal code-review UI the user is looking at right now. Comments
    \\you add and replies you post appear in their session immediately.
    \\
    \\A comment is a conversation, not a drop box. Every comment has an `author`
    \\and a thread of `replies`. When the reviewer asks something on a line, answer
    \\with `reply_to_comment` on that comment rather than opening a new one, so the
    \\question and the answer stay on the line they are about.
    \\
    \\Always pass `author` with your own name on `add_comment` and
    \\`reply_to_comment`. It is the label the reviewer sees; omit it and your
    \\message is attributed to them.
    \\
    \\Typical flow:
    \\  1. `list_sessions` to find the session (omit `session_id` if only one runs)
    \\  2. `get_diff` before commenting — never guess line numbers
    \\  3. `add_comment` for something new, using line_type "old" for `-` lines and
    \\     "new" for `+` and context lines
    \\  4. `list_comments` to read the threads, then `reply_to_comment` to answer
    \\     anything the reviewer addressed to you
    \\
    \\`index` on `reply_to_comment` and `delete_comment` is positional, and deleting
    \\a comment shifts every index above it down by one. Call `list_comments`
    \\immediately before using an index rather than reusing an older one.
;

// =============================================================================
// MCP Adapter
// =============================================================================

/// MCP adapter that bridges stdio (JSON-RPC from agent) to TUI sessions (TCP)
pub const McpAdapter = struct {
    allocator: Allocator,
    server: framework.Server,
    running: bool,
    stdin_len: usize,

    pub fn init(allocator: Allocator) McpAdapter {
        var server = framework.Server.init(allocator, .{
            .name = "skim",
            .version = "1.0.0",
            .instructions = server_instructions,
        });

        // Register tools
        server.tool("list_sessions", "List all running skim TUI sessions", null, handleListSessions) catch {};
        server.tool("get_context", "Get diff context and comments from a skim session", GetContextParams, handleGetContext) catch {};
        server.tool("get_diff", "Get the full diff content with line numbers. Use this to see what lines exist before adding comments.", GetDiffParams, handleGetDiff) catch {};
        server.tool("add_comment", "Add a comment to a line in the diff. Call get_diff first for real line numbers, and pass your own name as `author`. To answer an existing comment use reply_to_comment instead of opening a new one.", AddCommentParams, handleAddComment) catch {};
        server.tool("reply_to_comment", "Append a reply to an existing comment's thread — the way to answer something the reviewer asked on a line. Run list_comments immediately before this for a fresh `index`, and pass your own name as `author` or the reply is attributed to the reviewer.", ReplyToCommentParams, handleReplyToComment) catch {};
        server.tool("list_comments", "List every comment with its `author` and its `replies` thread. Read it before replying: it gives the index reply_to_comment needs, and `author` tells your own messages from the reviewer's.", ListCommentsParams, handleListComments) catch {};
        server.tool("delete_comment", "Delete a comment and its whole reply thread by index. Every higher index shifts down by one, so re-run list_comments before using another.", DeleteCommentParams, handleDeleteComment) catch {};

        return .{
            .allocator = allocator,
            .server = server,
            .running = false,
            .stdin_len = 0,
        };
    }

    pub fn deinit(self: *McpAdapter) void {
        self.server.deinit();
    }

    /// Main adapter loop - read from stdin, process MCP requests, write to stdout
    pub fn run(self: *McpAdapter) !void {
        // Set stdin to non-blocking
        try setNonBlocking(std.Io.File.stdin().handle);
        defer setBlocking(std.Io.File.stdin().handle) catch {};

        self.running = true;

        while (self.running) {
            try self.pollStdin();
            skim_io.sleep(1 * std.time.ns_per_ms);
        }
    }

    fn pollStdin(self: *McpAdapter) !void {
        const stdin = std.Io.File.stdin();

        const bytes_read = posix.read(stdin.handle, stdin_buffer[self.stdin_len..]) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };

        if (bytes_read == 0) {
            // EOF on stdin - agent disconnected
            std.log.debug("Stdin closed, shutting down adapter", .{});
            self.running = false;
            return;
        }

        self.stdin_len += bytes_read;

        // Parse complete lines (newline-delimited JSON-RPC)
        var parse_start: usize = 0;
        while (parse_start < self.stdin_len) {
            const newline_pos = std.mem.indexOfScalar(u8, stdin_buffer[parse_start..self.stdin_len], '\n');
            if (newline_pos) |pos| {
                const end = parse_start + pos;
                const line = stdin_buffer[parse_start..end];

                if (line.len > 0) {
                    self.handleMcpRequest(line);
                }

                parse_start = end + 1;
            } else {
                break;
            }
        }

        // Move remaining data to start of buffer
        if (parse_start > 0 and parse_start < self.stdin_len) {
            const remaining = self.stdin_len - parse_start;
            std.mem.copyForwards(u8, stdin_buffer[0..remaining], stdin_buffer[parse_start..self.stdin_len]);
            self.stdin_len = remaining;
        } else if (parse_start >= self.stdin_len) {
            self.stdin_len = 0;
        }
    }

    fn handleMcpRequest(self: *McpAdapter, line: []const u8) void {
        std.log.debug("MCP request from agent: {s}", .{line});

        var file_writer = std.Io.File.stdout().writer(skim_io.get(), &stdout_buffer);
        defer file_writer.interface.flush() catch {};
        const stdout = &file_writer.interface;

        // Parse JSON-RPC request
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch {
            self.sendMcpError(stdout, null, framework.ErrorCode.parse_error, "Parse error");
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            self.sendMcpError(stdout, null, framework.ErrorCode.invalid_request, "Invalid Request");
            return;
        }

        const obj = root.object;
        const method = obj.get("method") orelse {
            self.sendMcpError(stdout, null, framework.ErrorCode.invalid_request, "Missing method");
            return;
        };

        if (method != .string) {
            self.sendMcpError(stdout, null, framework.ErrorCode.invalid_request, "Invalid method");
            return;
        }

        const id = obj.get("id");
        const params = obj.get("params");

        // Handle notification (no response needed)
        if (std.mem.eql(u8, method.string, "notifications/initialized")) {
            return;
        }

        // Handle request
        const result = self.server.handleRequest(method.string, params, null);

        // Encode and send response
        self.sendMcpResponse(stdout, id, method.string, result);
    }

    fn sendMcpResponse(self: *McpAdapter, writer: anytype, id: ?std.json.Value, method: []const u8, result: framework.Result) void {
        writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return;

        // Write ID
        if (id) |id_val| {
            switch (id_val) {
                .integer => |n| writer.print("{d}", .{n}) catch return,
                .string => |s| {
                    writer.writeByte('"') catch return;
                    writer.writeAll(s) catch return;
                    writer.writeByte('"') catch return;
                },
                else => writer.writeAll("null") catch return,
            }
        } else {
            writer.writeAll("null") catch return;
        }

        switch (result) {
            .success => |s| {
                // Special handling for initialize
                if (std.mem.eql(u8, method, "initialize")) {
                    const init_response = self.server.encodeInitializeResponse(self.allocator) catch {
                        writer.writeAll(",\"error\":{\"code\":-32603,\"message\":\"Failed to encode response\"}}\n") catch return;
                        return;
                    };
                    defer self.allocator.free(init_response);
                    writer.writeAll(",\"result\":") catch return;
                    writer.writeAll(init_response) catch return;
                } else if (std.mem.eql(u8, method, "tools/list")) {
                    const tools_response = self.server.encodeToolsListResponse(self.allocator) catch {
                        writer.writeAll(",\"error\":{\"code\":-32603,\"message\":\"Failed to encode response\"}}\n") catch return;
                        return;
                    };
                    defer self.allocator.free(tools_response);
                    writer.writeAll(",\"result\":") catch return;
                    writer.writeAll(tools_response) catch return;
                } else {
                    // Tool call result
                    var res = result;
                    defer res.deinit(self.allocator);
                    const tool_result = self.server.encodeToolResult(self.allocator, result) catch {
                        writer.writeAll(",\"error\":{\"code\":-32603,\"message\":\"Failed to encode response\"}}\n") catch return;
                        return;
                    };
                    defer self.allocator.free(tool_result);
                    writer.writeAll(",\"result\":") catch return;
                    writer.writeAll(tool_result) catch return;
                }
                _ = s;
            },
            .failure => |f| {
                writer.writeAll(",\"error\":{\"code\":") catch return;
                writer.print("{d}", .{f.code}) catch return;
                writer.writeAll(",\"message\":\"") catch return;
                writer.writeAll(f.message) catch return;
                writer.writeAll("\"}") catch return;
            },
        }

        writer.writeAll("}\n") catch return;
    }

    fn sendMcpError(self: *McpAdapter, writer: anytype, id: ?std.json.Value, code: i32, message: []const u8) void {
        _ = self;
        _ = id;

        writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":") catch return;
        writer.print("{d}", .{code}) catch return;
        writer.writeAll(",\"message\":\"") catch return;
        writer.writeAll(message) catch return;
        writer.writeAll("\"}}\n") catch return;
    }
};

// =============================================================================
// Tool Parameter Types
// =============================================================================

const GetContextParams = struct {
    session_id: []const u8 = "",
};

const GetDiffParams = struct {
    session_id: []const u8 = "",
    file: []const u8 = "", // Optional: specific file, or empty for all files
};

const AddCommentParams = struct {
    session_id: []const u8 = "",
    file: []const u8,
    line: u32,
    line_type: []const u8 = "new",
    text: []const u8,
    author: []const u8 = "",
};

const ReplyToCommentParams = struct {
    session_id: []const u8 = "",
    index: u32,
    text: []const u8,
    author: []const u8 = "",
};

const ListCommentsParams = struct {
    session_id: []const u8 = "",
};

const DeleteCommentParams = struct {
    session_id: []const u8 = "",
    index: u32,
};

// =============================================================================
// Tool Handlers
// =============================================================================

fn handleListSessions(ctx: *framework.Context, args: ?std.json.Value) framework.Result {
    _ = args;

    var sm = session_mgr.SessionManager.init(ctx.allocator) catch {
        return framework.Result.mcpError(framework.ErrorCode.internal_error, "Failed to init session manager");
    };
    defer sm.deinit();

    const sessions = sm.listSessions() catch {
        return framework.Result.mcpError(framework.ErrorCode.internal_error, "Failed to list sessions");
    };
    defer {
        for (sessions) |*s| {
            var sess = s.*;
            sess.deinit(ctx.allocator);
        }
        ctx.allocator.free(sessions);
    }

    // Build text output
    var output: std.Io.Writer.Allocating = .init(ctx.allocator);
    const writer = &output.writer;

    if (sessions.len == 0) {
        writer.writeAll("No skim sessions running.\n") catch {};
    } else {
        writer.print("Running skim sessions ({d}):\n\n", .{sessions.len}) catch {};
        for (sessions) |s| {
            writer.print("  PID: {d}\n", .{s.pid}) catch {};
            writer.print("  CWD: {s}\n", .{s.cwd}) catch {};
            writer.print("  Diff: {s}\n", .{s.diff_ref}) catch {};
            writer.print("  Files: {d}\n\n", .{s.files.len}) catch {};
        }
    }

    const text = output.toOwnedSlice() catch {
        return framework.Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");
    };

    return framework.Result.text(ctx.allocator, text) catch {
        ctx.allocator.free(text);
        return framework.Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");
    };
}

fn handleGetContext(ctx: *framework.Context, args: ?std.json.Value) framework.Result {
    const session_pid = parseSessionId(args);

    var client = cli_client.autoConnect(ctx.allocator, session_pid) catch |err| {
        return switch (err) {
            error.NoSessionsRunning => framework.Result.textError(ctx.allocator, "No skim sessions running") catch framework.Result.mcpError(framework.ErrorCode.internal_error, "No sessions"),
            error.AmbiguousSessions => framework.Result.textError(ctx.allocator, "Multiple sessions found, specify session_id") catch framework.Result.mcpError(framework.ErrorCode.internal_error, "Ambiguous"),
            error.SessionNotFound => framework.Result.textError(ctx.allocator, "Session not found") catch framework.Result.mcpError(framework.ErrorCode.internal_error, "Not found"),
            else => framework.Result.mcpError(framework.ErrorCode.internal_error, "Connection failed"),
        };
    };
    defer client.deinit();

    var response = client.request("get_context", "mcp-ctx", null) catch {
        return framework.Result.mcpError(framework.ErrorCode.internal_error, "Request failed");
    };

    switch (response) {
        .result => |result| {
            // Serialize result to JSON text
            var alloc_writer: std.Io.Writer.Allocating = .init(ctx.allocator);
            var stringify: std.json.Stringify = .{ .writer = &alloc_writer.writer };
            stringify.write(result) catch {
                alloc_writer.deinit();
                response.deinit(ctx.allocator);
                return framework.Result.mcpError(framework.ErrorCode.internal_error, "Serialization failed");
            };
            const text = ctx.allocator.dupe(u8, alloc_writer.written()) catch {
                alloc_writer.deinit();
                response.deinit(ctx.allocator);
                return framework.Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");
            };
            alloc_writer.deinit();
            response.deinit(ctx.allocator);

            return framework.Result.text(ctx.allocator, text) catch {
                ctx.allocator.free(text);
                return framework.Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");
            };
        },
        .err => |e| {
            // Must duplicate message before freeing response, as e.message points into response
            const message = ctx.allocator.dupe(u8, e.message) catch {
                response.deinit(ctx.allocator);
                return framework.Result.mcpError(e.code, e.message);
            };
            response.deinit(ctx.allocator);
            return framework.Result.textError(ctx.allocator, message) catch {
                ctx.allocator.free(message);
                return framework.Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");
            };
        },
    }
}

fn handleGetDiff(ctx: *framework.Context, args: ?std.json.Value) framework.Result {
    const session_pid = parseSessionId(args);

    // Get optional file filter
    const file_filter: ?[]const u8 = blk: {
        const params = args orelse break :blk null;
        if (params != .object) break :blk null;
        const file_val = params.object.get("file") orelse break :blk null;
        if (file_val != .string) break :blk null;
        if (file_val.string.len == 0) break :blk null;
        break :blk file_val.string;
    };

    var client = cli_client.autoConnect(ctx.allocator, session_pid) catch |err| {
        return switch (err) {
            error.NoSessionsRunning => framework.Result.textError(ctx.allocator, "No skim sessions running") catch framework.Result.mcpError(framework.ErrorCode.internal_error, "No sessions"),
            error.AmbiguousSessions => framework.Result.textError(ctx.allocator, "Multiple sessions found, specify session_id") catch framework.Result.mcpError(framework.ErrorCode.internal_error, "Ambiguous"),
            error.SessionNotFound => framework.Result.textError(ctx.allocator, "Session not found") catch framework.Result.mcpError(framework.ErrorCode.internal_error, "Not found"),
            else => framework.Result.mcpError(framework.ErrorCode.internal_error, "Connection failed"),
        };
    };
    defer client.deinit();

    // Build params for TUI request
    var req_params_obj: ?std.json.Value = null;
    if (file_filter) |f| {
        var req_params: std.json.ObjectMap = .empty;
        req_params.put(ctx.allocator, ctx.allocator.dupe(u8, "file") catch return framework.Result.mcpError(framework.ErrorCode.internal_error, "Alloc failed"), .{ .string = ctx.allocator.dupe(u8, f) catch return framework.Result.mcpError(framework.ErrorCode.internal_error, "Alloc failed") }) catch {};
        req_params_obj = .{ .object = req_params };
    }
    defer if (req_params_obj) |*p| {
        if (p.* == .object) {
            var it = p.object.iterator();
            while (it.next()) |entry| {
                ctx.allocator.free(entry.key_ptr.*);
                if (entry.value_ptr.* == .string) ctx.allocator.free(entry.value_ptr.string);
            }
            p.object.deinit(ctx.allocator);
        }
    };

    var response = client.request("get_diff", "mcp-diff", req_params_obj) catch {
        return framework.Result.mcpError(framework.ErrorCode.internal_error, "Request failed");
    };

    switch (response) {
        .result => |result| {
            // The result should contain "diff" field with the formatted diff text
            if (result == .object) {
                if (result.object.get("diff")) |diff_val| {
                    if (diff_val == .string) {
                        const text = ctx.allocator.dupe(u8, diff_val.string) catch {
                            response.deinit(ctx.allocator);
                            return framework.Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");
                        };
                        response.deinit(ctx.allocator);
                        return framework.Result.text(ctx.allocator, text) catch {
                            ctx.allocator.free(text);
                            return framework.Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");
                        };
                    }
                }
            }
            response.deinit(ctx.allocator);
            return framework.Result.mcpError(framework.ErrorCode.internal_error, "Invalid response format");
        },
        .err => |e| {
            const message = ctx.allocator.dupe(u8, e.message) catch {
                response.deinit(ctx.allocator);
                return framework.Result.mcpError(e.code, e.message);
            };
            response.deinit(ctx.allocator);
            return framework.Result.textError(ctx.allocator, message) catch {
                ctx.allocator.free(message);
                return framework.Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");
            };
        },
    }
}

fn handleAddComment(ctx: *framework.Context, args: ?std.json.Value) framework.Result {
    const params = args orelse {
        return framework.Result.mcpError(framework.ErrorCode.invalid_params, "Missing parameters");
    };

    if (params != .object) {
        return framework.Result.mcpError(framework.ErrorCode.invalid_params, "Invalid parameters");
    }

    const obj = params.object;

    // Get required parameters
    const file = if (obj.get("file")) |f| if (f == .string) f.string else null else null;
    const line = if (obj.get("line")) |l| if (l == .integer) @as(u32, @intCast(l.integer)) else null else null;
    const text = if (obj.get("text")) |t| if (t == .string) t.string else null else null;

    if (file == null or line == null or text == null) {
        return framework.Result.mcpError(framework.ErrorCode.invalid_params, "Missing required parameters: file, line, text");
    }

    const line_type = if (obj.get("line_type")) |lt| if (lt == .string) lt.string else "new" else "new";
    const session_pid = parseSessionId(args);

    var client = cli_client.autoConnect(ctx.allocator, session_pid) catch |err| {
        return switch (err) {
            error.NoSessionsRunning => framework.Result.textError(ctx.allocator, "No skim sessions running") catch framework.Result.mcpError(framework.ErrorCode.internal_error, "No sessions"),
            error.AmbiguousSessions => framework.Result.textError(ctx.allocator, "Multiple sessions found, specify session_id") catch framework.Result.mcpError(framework.ErrorCode.internal_error, "Ambiguous"),
            error.SessionNotFound => framework.Result.textError(ctx.allocator, "Session not found") catch framework.Result.mcpError(framework.ErrorCode.internal_error, "Not found"),
            else => framework.Result.mcpError(framework.ErrorCode.internal_error, "Connection failed"),
        };
    };
    defer client.deinit();

    // Build params for TUI request
    var req_params: std.json.ObjectMap = .empty;
    defer req_params.deinit(ctx.allocator);

    req_params.put(ctx.allocator, ctx.allocator.dupe(u8, "file") catch return framework.Result.mcpError(framework.ErrorCode.internal_error, "Alloc failed"), .{ .string = ctx.allocator.dupe(u8, file.?) catch return framework.Result.mcpError(framework.ErrorCode.internal_error, "Alloc failed") }) catch {};
    req_params.put(ctx.allocator, ctx.allocator.dupe(u8, "line") catch return framework.Result.mcpError(framework.ErrorCode.internal_error, "Alloc failed"), .{ .integer = @as(i64, @intCast(line.?)) }) catch {};
    req_params.put(ctx.allocator, ctx.allocator.dupe(u8, "line_type") catch return framework.Result.mcpError(framework.ErrorCode.internal_error, "Alloc failed"), .{ .string = ctx.allocator.dupe(u8, line_type) catch return framework.Result.mcpError(framework.ErrorCode.internal_error, "Alloc failed") }) catch {};
    req_params.put(ctx.allocator, ctx.allocator.dupe(u8, "text") catch return framework.Result.mcpError(framework.ErrorCode.internal_error, "Alloc failed"), .{ .string = ctx.allocator.dupe(u8, text.?) catch return framework.Result.mcpError(framework.ErrorCode.internal_error, "Alloc failed") }) catch {};
    putAuthor(ctx, &req_params, obj);

    var response = client.request("add_comment", "mcp-add", .{ .object = req_params }) catch {
        return framework.Result.mcpError(framework.ErrorCode.internal_error, "Request failed");
    };

    switch (response) {
        .result => {
            response.deinit(ctx.allocator);
            return framework.Result.text(ctx.allocator, "Comment added successfully.") catch framework.Result.mcpError(framework.ErrorCode.internal_error, "Alloc failed");
        },
        .err => |e| {
            // Must duplicate message before freeing response, as e.message points into response
            const message = ctx.allocator.dupe(u8, e.message) catch {
                response.deinit(ctx.allocator);
                return framework.Result.mcpError(e.code, e.message);
            };
            response.deinit(ctx.allocator);
            return framework.Result.textError(ctx.allocator, message) catch {
                ctx.allocator.free(message);
                return framework.Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");
            };
        },
    }
}

fn handleReplyToComment(ctx: *framework.Context, args: ?std.json.Value) framework.Result {
    const params = args orelse {
        return framework.Result.mcpError(framework.ErrorCode.invalid_params, "Missing parameters");
    };

    if (params != .object) {
        return framework.Result.mcpError(framework.ErrorCode.invalid_params, "Invalid parameters");
    }

    const obj = params.object;

    const index = if (obj.get("index")) |i| if (i == .integer) @as(u32, @intCast(i.integer)) else null else null;
    const text = if (obj.get("text")) |t| if (t == .string) t.string else null else null;

    if (index == null or text == null) {
        return framework.Result.mcpError(framework.ErrorCode.invalid_params, "Missing required parameters: index, text");
    }

    const session_pid = parseSessionId(args);

    var client = cli_client.autoConnect(ctx.allocator, session_pid) catch |err| {
        return switch (err) {
            error.NoSessionsRunning => framework.Result.textError(ctx.allocator, "No skim sessions running") catch framework.Result.mcpError(framework.ErrorCode.internal_error, "No sessions"),
            error.AmbiguousSessions => framework.Result.textError(ctx.allocator, "Multiple sessions found, specify session_id") catch framework.Result.mcpError(framework.ErrorCode.internal_error, "Ambiguous"),
            error.SessionNotFound => framework.Result.textError(ctx.allocator, "Session not found") catch framework.Result.mcpError(framework.ErrorCode.internal_error, "Not found"),
            else => framework.Result.mcpError(framework.ErrorCode.internal_error, "Connection failed"),
        };
    };
    defer client.deinit();

    var req_params: std.json.ObjectMap = .empty;
    defer req_params.deinit(ctx.allocator);

    req_params.put(ctx.allocator, ctx.allocator.dupe(u8, "index") catch return framework.Result.mcpError(framework.ErrorCode.internal_error, "Alloc failed"), .{ .integer = @as(i64, @intCast(index.?)) }) catch {};
    req_params.put(ctx.allocator, ctx.allocator.dupe(u8, "text") catch return framework.Result.mcpError(framework.ErrorCode.internal_error, "Alloc failed"), .{ .string = ctx.allocator.dupe(u8, text.?) catch return framework.Result.mcpError(framework.ErrorCode.internal_error, "Alloc failed") }) catch {};
    putAuthor(ctx, &req_params, obj);

    var response = client.request("reply_comment", "mcp-reply", .{ .object = req_params }) catch {
        return framework.Result.mcpError(framework.ErrorCode.internal_error, "Request failed");
    };

    switch (response) {
        .result => {
            response.deinit(ctx.allocator);
            return framework.Result.text(ctx.allocator, "Reply added successfully.") catch framework.Result.mcpError(framework.ErrorCode.internal_error, "Alloc failed");
        },
        .err => |e| {
            // Must duplicate message before freeing response, as e.message points into response
            const message = ctx.allocator.dupe(u8, e.message) catch {
                response.deinit(ctx.allocator);
                return framework.Result.mcpError(e.code, e.message);
            };
            response.deinit(ctx.allocator);
            return framework.Result.textError(ctx.allocator, message) catch {
                ctx.allocator.free(message);
                return framework.Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");
            };
        },
    }
}

/// Forward the caller's `author`, when it supplied a non-empty one. Omitted, the
/// TUI attributes the message to the local reviewer.
fn putAuthor(ctx: *framework.Context, req_params: *std.json.ObjectMap, obj: std.json.ObjectMap) void {
    const val = obj.get("author") orelse return;
    if (val != .string or val.string.len == 0) return;

    const key = ctx.allocator.dupe(u8, "author") catch return;
    const author = ctx.allocator.dupe(u8, val.string) catch {
        ctx.allocator.free(key);
        return;
    };
    req_params.put(ctx.allocator, key, .{ .string = author }) catch {};
}

fn handleListComments(ctx: *framework.Context, args: ?std.json.Value) framework.Result {
    const session_pid = parseSessionId(args);

    var client = cli_client.autoConnect(ctx.allocator, session_pid) catch |err| {
        return switch (err) {
            error.NoSessionsRunning => framework.Result.textError(ctx.allocator, "No skim sessions running") catch framework.Result.mcpError(framework.ErrorCode.internal_error, "No sessions"),
            error.AmbiguousSessions => framework.Result.textError(ctx.allocator, "Multiple sessions found, specify session_id") catch framework.Result.mcpError(framework.ErrorCode.internal_error, "Ambiguous"),
            error.SessionNotFound => framework.Result.textError(ctx.allocator, "Session not found") catch framework.Result.mcpError(framework.ErrorCode.internal_error, "Not found"),
            else => framework.Result.mcpError(framework.ErrorCode.internal_error, "Connection failed"),
        };
    };
    defer client.deinit();

    var response = client.request("list_comments", "mcp-list", null) catch {
        return framework.Result.mcpError(framework.ErrorCode.internal_error, "Request failed");
    };

    switch (response) {
        .result => |result| {
            // Serialize result to JSON text
            var alloc_writer: std.Io.Writer.Allocating = .init(ctx.allocator);
            var stringify: std.json.Stringify = .{ .writer = &alloc_writer.writer };
            stringify.write(result) catch {
                alloc_writer.deinit();
                response.deinit(ctx.allocator);
                return framework.Result.mcpError(framework.ErrorCode.internal_error, "Serialization failed");
            };
            const json_text = ctx.allocator.dupe(u8, alloc_writer.written()) catch {
                alloc_writer.deinit();
                response.deinit(ctx.allocator);
                return framework.Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");
            };
            alloc_writer.deinit();
            response.deinit(ctx.allocator);

            return framework.Result.text(ctx.allocator, json_text) catch {
                ctx.allocator.free(json_text);
                return framework.Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");
            };
        },
        .err => |e| {
            // Must duplicate message before freeing response, as e.message points into response
            const message = ctx.allocator.dupe(u8, e.message) catch {
                response.deinit(ctx.allocator);
                return framework.Result.mcpError(e.code, e.message);
            };
            response.deinit(ctx.allocator);
            return framework.Result.textError(ctx.allocator, message) catch {
                ctx.allocator.free(message);
                return framework.Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");
            };
        },
    }
}

fn handleDeleteComment(ctx: *framework.Context, args: ?std.json.Value) framework.Result {
    const params = args orelse {
        return framework.Result.mcpError(framework.ErrorCode.invalid_params, "Missing parameters");
    };

    if (params != .object) {
        return framework.Result.mcpError(framework.ErrorCode.invalid_params, "Invalid parameters");
    }

    const obj = params.object;

    // Get required index parameter
    const index = if (obj.get("index")) |i| if (i == .integer) @as(u32, @intCast(i.integer)) else null else null;

    if (index == null) {
        return framework.Result.mcpError(framework.ErrorCode.invalid_params, "Missing required parameter: index");
    }

    const session_pid = parseSessionId(args);

    var client = cli_client.autoConnect(ctx.allocator, session_pid) catch |err| {
        return switch (err) {
            error.NoSessionsRunning => framework.Result.textError(ctx.allocator, "No skim sessions running") catch framework.Result.mcpError(framework.ErrorCode.internal_error, "No sessions"),
            error.AmbiguousSessions => framework.Result.textError(ctx.allocator, "Multiple sessions found, specify session_id") catch framework.Result.mcpError(framework.ErrorCode.internal_error, "Ambiguous"),
            error.SessionNotFound => framework.Result.textError(ctx.allocator, "Session not found") catch framework.Result.mcpError(framework.ErrorCode.internal_error, "Not found"),
            else => framework.Result.mcpError(framework.ErrorCode.internal_error, "Connection failed"),
        };
    };
    defer client.deinit();

    // Build params for TUI request
    var req_params: std.json.ObjectMap = .empty;
    defer req_params.deinit(ctx.allocator);

    req_params.put(ctx.allocator, ctx.allocator.dupe(u8, "index") catch return framework.Result.mcpError(framework.ErrorCode.internal_error, "Alloc failed"), .{ .integer = @as(i64, @intCast(index.?)) }) catch {};

    var response = client.request("delete_comment", "mcp-del", .{ .object = req_params }) catch {
        return framework.Result.mcpError(framework.ErrorCode.internal_error, "Request failed");
    };

    switch (response) {
        .result => {
            response.deinit(ctx.allocator);
            return framework.Result.text(ctx.allocator, "Comment deleted successfully.") catch framework.Result.mcpError(framework.ErrorCode.internal_error, "Alloc failed");
        },
        .err => |e| {
            // Must duplicate message before freeing response, as e.message points into response
            const message = ctx.allocator.dupe(u8, e.message) catch {
                response.deinit(ctx.allocator);
                return framework.Result.mcpError(e.code, e.message);
            };
            response.deinit(ctx.allocator);
            return framework.Result.textError(ctx.allocator, message) catch {
                ctx.allocator.free(message);
                return framework.Result.mcpError(framework.ErrorCode.internal_error, "Allocation failed");
            };
        },
    }
}

// =============================================================================
// Helper Functions
// =============================================================================

fn parseSessionId(args: ?std.json.Value) ?posix.pid_t {
    const params = args orelse return null;
    if (params != .object) return null;

    const session_id = params.object.get("session_id") orelse return null;

    return switch (session_id) {
        .string => |s| if (s.len > 0) std.fmt.parseInt(posix.pid_t, s, 10) catch null else null,
        .integer => |i| @intCast(i),
        else => null,
    };
}

fn setNonBlocking(handle: posix.fd_t) !void {
    try skim_io.setNonBlocking(handle, true);
}

fn setBlocking(handle: posix.fd_t) !void {
    try skim_io.setNonBlocking(handle, false);
}

// =============================================================================
// Public Entry Point
// =============================================================================

/// Run the MCP adapter
pub fn runAdapter(allocator: Allocator) !void {
    var adapter = McpAdapter.init(allocator);
    defer adapter.deinit();

    try adapter.run();
}

// =============================================================================
// Tests
// =============================================================================

test "adapter init and deinit" {
    const allocator = std.testing.allocator;

    var adapter = McpAdapter.init(allocator);
    defer adapter.deinit();

    try std.testing.expect(!adapter.running);
}

test "parseSessionId with string" {
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "session_id", .{ .string = "12345" });

    const pid = parseSessionId(.{ .object = obj });
    try std.testing.expectEqual(@as(?posix.pid_t, 12345), pid);
}

test "parseSessionId with integer" {
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "session_id", .{ .integer = 54321 });

    const pid = parseSessionId(.{ .object = obj });
    try std.testing.expectEqual(@as(?posix.pid_t, 54321), pid);
}

test "parseSessionId with empty string" {
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "session_id", .{ .string = "" });

    const pid = parseSessionId(.{ .object = obj });
    try std.testing.expectEqual(@as(?posix.pid_t, null), pid);
}

test "parseSessionId with null args" {
    const pid = parseSessionId(null);
    try std.testing.expectEqual(@as(?posix.pid_t, null), pid);
}
