const std = @import("std");
const net = std.net;
const posix = std.posix;
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const registry = @import("registry.zig");

const Allocator = std.mem.Allocator;

/// A connection that hasn't sent a hello yet
const PendingConnection = struct {
    stream: net.Stream,
    recv_buffer: [8192]u8,
    recv_len: usize,
    connected_at: i64,
};

/// MCP Server that handles both TCP connections from skim TUI clients
/// and MCP JSON-RPC requests from AI agents via stdio.
pub const McpServer = struct {
    allocator: Allocator,
    tcp_listener: ?net.Server,
    port: u16,
    clients: registry.ClientRegistry,
    pending_connections: std.ArrayList(PendingConnection),
    running: bool,
    mcp_initialized: bool,

    // Stdin buffer for MCP protocol
    stdin_buffer: [65536]u8,
    stdin_len: usize,

    pub fn init(allocator: Allocator, port: u16) !*McpServer {
        const server = try allocator.create(McpServer);
        errdefer allocator.destroy(server);

        server.* = .{
            .allocator = allocator,
            .tcp_listener = null,
            .port = port,
            .clients = registry.ClientRegistry.init(allocator),
            .pending_connections = std.ArrayList(PendingConnection).init(allocator),
            .running = false,
            .mcp_initialized = false,
            .stdin_buffer = undefined,
            .stdin_len = 0,
        };

        return server;
    }

    pub fn deinit(self: *McpServer) void {
        self.stop();
        // Close any pending connections
        for (self.pending_connections.items) |*pending| {
            pending.stream.close();
        }
        self.pending_connections.deinit();
        self.clients.deinit();
        self.allocator.destroy(self);
    }

    /// Start the TCP listener
    pub fn start(self: *McpServer) !void {
        const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, self.port);
        self.tcp_listener = try address.listen(.{
            .reuse_address = true,
        });

        // Set non-blocking mode for accept
        if (self.tcp_listener) |listener| {
            const flags = try posix.fcntl(listener.stream.handle, posix.F.GETFL, @as(usize, 0));
            const O_NONBLOCK: usize = 0x0004; // darwin/macOS
            const new_flags = flags | O_NONBLOCK;
            _ = try posix.fcntl(listener.stream.handle, posix.F.SETFL, new_flags);
        }

        self.running = true;
        std.log.info("MCP server listening on port {d}", .{self.port});

        // Write discovery file
        try self.writeDiscoveryFile();
    }

    /// Stop the server
    pub fn stop(self: *McpServer) void {
        self.running = false;
        if (self.tcp_listener) |*listener| {
            listener.deinit();
            self.tcp_listener = null;
        }
        self.deleteDiscoveryFile();
    }

    /// Main server loop - processes both MCP and TCP traffic
    pub fn run(self: *McpServer) !void {
        // Set stdin to non-blocking
        try self.setStdinNonBlocking(true);
        defer self.setStdinNonBlocking(false) catch {};

        while (self.running) {
            // 1. Check for new TCP connections
            try self.acceptNewClients();

            // 2. Poll pending connections for hello messages
            try self.pollPendingConnections();

            // 3. Poll stdin for MCP requests
            try self.pollMcpStdin();

            // 4. Poll all connected skim clients for messages
            try self.pollSkimClients();

            // Small sleep to avoid busy-waiting
            std.time.sleep(1 * std.time.ns_per_ms);
        }
    }

    // =========================================================================
    // TCP Client Handling
    // =========================================================================

    fn acceptNewClients(self: *McpServer) !void {
        // Use pointer capture since accept() requires mutable reference
        if (self.tcp_listener) |*listener| {
            // Try to accept (non-blocking)
            const conn = listener.accept() catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };

            std.log.info("New client connection from {}", .{conn.address});

            // Set non-blocking mode on client socket
            const flags = try posix.fcntl(conn.stream.handle, posix.F.GETFL, @as(usize, 0));
            const O_NONBLOCK: usize = 0x0004;
            const new_flags = flags | O_NONBLOCK;
            _ = try posix.fcntl(conn.stream.handle, posix.F.SETFL, new_flags);

            // Add to pending connections - will be registered when hello is received
            try self.pending_connections.append(.{
                .stream = conn.stream,
                .recv_buffer = undefined,
                .recv_len = 0,
                .connected_at = std.time.timestamp(),
            });
        }
    }

    fn pollPendingConnections(self: *McpServer) !void {
        var i: usize = 0;
        while (i < self.pending_connections.items.len) {
            var pending = &self.pending_connections.items[i];

            // Try to read from pending connection
            const bytes_read = pending.stream.read(pending.recv_buffer[pending.recv_len..]) catch |err| switch (err) {
                error.WouldBlock => {
                    i += 1;
                    continue;
                },
                error.ConnectionResetByPeer, error.BrokenPipe => {
                    // Connection failed, remove it
                    pending.stream.close();
                    _ = self.pending_connections.swapRemove(i);
                    continue;
                },
                else => return err,
            };

            if (bytes_read == 0) {
                // Connection closed
                pending.stream.close();
                _ = self.pending_connections.swapRemove(i);
                continue;
            }

            pending.recv_len += bytes_read;

            // Look for complete message (newline-delimited)
            if (std.mem.indexOfScalar(u8, pending.recv_buffer[0..pending.recv_len], '\n')) |newline_pos| {
                const line = pending.recv_buffer[0..newline_pos];

                // Try to parse as hello message
                const msg = protocol.decode(self.allocator, line) catch {
                    // Invalid message, close connection
                    pending.stream.close();
                    _ = self.pending_connections.swapRemove(i);
                    continue;
                };
                defer {
                    // Free the parsed message
                    switch (msg) {
                        .hello => |h| {
                            self.allocator.free(h.id);
                            self.allocator.free(h.cwd);
                            self.allocator.free(h.diff_ref);
                            for (h.files) |f| {
                                self.allocator.free(f.path);
                                self.allocator.free(f.old_path);
                            }
                            self.allocator.free(h.files);
                        },
                        else => {},
                    }
                }

                switch (msg) {
                    .hello => |hello| {
                        std.log.info("Received hello from client: {s}", .{hello.id});

                        // Register the client
                        const client = self.clients.add(pending.stream, hello) catch |err| {
                            std.log.err("Failed to register client: {}", .{err});
                            pending.stream.close();
                            _ = self.pending_connections.swapRemove(i);
                            continue;
                        };

                        // Send welcome message
                        const welcome = protocol.encodeWelcome(self.allocator, &client.id) catch {
                            _ = self.pending_connections.swapRemove(i);
                            continue;
                        };
                        defer self.allocator.free(welcome);

                        client.stream.writeAll(welcome) catch {};

                        // Remove from pending (don't close stream - it's now owned by registry)
                        _ = self.pending_connections.swapRemove(i);
                        continue;
                    },
                    else => {
                        // Not a hello message, close connection
                        pending.stream.close();
                        _ = self.pending_connections.swapRemove(i);
                        continue;
                    },
                }
            }

            i += 1;
        }
    }

    fn pollSkimClients(self: *McpServer) !void {
        var to_remove = std.ArrayList(registry.SessionId).init(self.allocator);
        defer to_remove.deinit();

        var it = self.clients.iterator();
        while (it.next()) |client_ptr| {
            const client = client_ptr.*;

            // Try to read from client
            const bytes_read = client.stream.read(client.recv_buffer[client.recv_len..]) catch |err| switch (err) {
                error.WouldBlock => continue,
                error.ConnectionResetByPeer, error.BrokenPipe => {
                    std.log.info("Client {s} disconnected", .{client.id});
                    try to_remove.append(client.id);
                    continue;
                },
                else => return err,
            };

            if (bytes_read == 0) {
                std.log.info("Client {s} closed connection", .{client.id});
                try to_remove.append(client.id);
                continue;
            }

            client.recv_len += bytes_read;
            self.clients.touch(client.id);

            // Parse messages
            try self.parseClientMessages(client);
        }

        // Remove disconnected clients
        for (to_remove.items) |id| {
            self.clients.remove(id);
        }
    }

    fn parseClientMessages(self: *McpServer, client: *registry.ClientInfo) !void {
        var parse_start: usize = 0;

        while (parse_start < client.recv_len) {
            const newline_pos = std.mem.indexOfScalar(u8, client.recv_buffer[parse_start..client.recv_len], '\n');
            if (newline_pos) |pos| {
                const end = parse_start + pos;
                const line = client.recv_buffer[parse_start..end];

                if (line.len > 0) {
                    try self.handleClientMessage(client, line);
                }

                parse_start = end + 1;
            } else {
                break;
            }
        }

        // Move remaining data
        if (parse_start > 0 and parse_start < client.recv_len) {
            const remaining = client.recv_len - parse_start;
            std.mem.copyForwards(u8, client.recv_buffer[0..remaining], client.recv_buffer[parse_start..client.recv_len]);
            client.recv_len = remaining;
        } else if (parse_start >= client.recv_len) {
            client.recv_len = 0;
        }
    }

    fn handleClientMessage(self: *McpServer, client: *registry.ClientInfo, line: []const u8) !void {
        const msg = protocol.decode(self.allocator, line) catch |err| {
            std.log.warn("Failed to parse client message: {}", .{err});
            return;
        };
        defer {
            // Free message after processing
            const m = msg;
            switch (m) {
                .comment_added => |ca| {
                    if (ca.@"error") |e| self.allocator.free(e);
                },
                .comments => |c| {
                    for (c.comments) |comment| {
                        self.allocator.free(comment.file_path);
                        self.allocator.free(comment.text);
                        self.allocator.free(comment.line_type);
                    }
                    self.allocator.free(c.comments);
                },
                else => {},
            }
        }

        switch (msg) {
            .comment_added => |result| {
                std.log.debug("Client {s} confirmed comment: success={}", .{ client.id, result.success });
            },
            .comments => |result| {
                std.log.debug("Client {s} sent {} comments", .{ client.id, result.comments.len });
            },
            .ping => {
                const pong = try protocol.encodePong(self.allocator);
                defer self.allocator.free(pong);
                client.stream.writeAll(pong) catch {};
            },
            else => {
                std.log.debug("Received message from client: {}", .{@as(std.meta.Tag(@TypeOf(msg)), msg)});
            },
        }
    }

    // =========================================================================
    // MCP Protocol Handling (stdio)
    // =========================================================================

    fn setStdinNonBlocking(self: *McpServer, non_blocking: bool) !void {
        _ = self;
        const stdin_fd = std.io.getStdIn().handle;
        const flags = try posix.fcntl(stdin_fd, posix.F.GETFL, @as(usize, 0));
        const O_NONBLOCK: usize = 0x0004; // darwin/macOS
        const new_flags: usize = if (non_blocking)
            flags | O_NONBLOCK
        else
            flags & ~O_NONBLOCK;
        _ = try posix.fcntl(stdin_fd, posix.F.SETFL, new_flags);
    }

    fn pollMcpStdin(self: *McpServer) !void {
        const stdin = std.io.getStdIn();

        // Try to read (non-blocking)
        const bytes_read = stdin.read(self.stdin_buffer[self.stdin_len..]) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };

        if (bytes_read == 0) {
            // EOF on stdin - agent disconnected
            std.log.info("MCP stdin closed, shutting down", .{});
            self.running = false;
            return;
        }

        self.stdin_len += bytes_read;

        // Parse complete lines (newline-delimited JSON-RPC)
        var parse_start: usize = 0;
        while (parse_start < self.stdin_len) {
            const newline_pos = std.mem.indexOfScalar(u8, self.stdin_buffer[parse_start..self.stdin_len], '\n');
            if (newline_pos) |pos| {
                const end = parse_start + pos;
                const line = self.stdin_buffer[parse_start..end];

                if (line.len > 0) {
                    try self.handleMcpRequest(line);
                }

                parse_start = end + 1;
            } else {
                break;
            }
        }

        // Move remaining data
        if (parse_start > 0 and parse_start < self.stdin_len) {
            const remaining = self.stdin_len - parse_start;
            std.mem.copyForwards(u8, self.stdin_buffer[0..remaining], self.stdin_buffer[parse_start..self.stdin_len]);
            self.stdin_len = remaining;
        } else if (parse_start >= self.stdin_len) {
            self.stdin_len = 0;
        }
    }

    fn handleMcpRequest(self: *McpServer, line: []const u8) !void {
        const stdout = std.io.getStdOut().writer();

        // Parse JSON-RPC request
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch {
            try self.sendMcpError(stdout, null, -32700, "Parse error");
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            try self.sendMcpError(stdout, null, -32600, "Invalid Request");
            return;
        }

        const obj = root.object;
        const method = obj.get("method") orelse {
            try self.sendMcpError(stdout, null, -32600, "Missing method");
            return;
        };

        if (method != .string) {
            try self.sendMcpError(stdout, null, -32600, "Invalid method");
            return;
        }

        const id = obj.get("id");
        const params = obj.get("params");

        // Dispatch based on method
        if (std.mem.eql(u8, method.string, "initialize")) {
            try self.handleInitialize(stdout, id, params);
        } else if (std.mem.eql(u8, method.string, "tools/list")) {
            try self.handleToolsList(stdout, id);
        } else if (std.mem.eql(u8, method.string, "tools/call")) {
            try self.handleToolsCall(stdout, id, params);
        } else if (std.mem.eql(u8, method.string, "notifications/initialized")) {
            // Client notification, no response needed
            self.mcp_initialized = true;
        } else {
            try self.sendMcpError(stdout, id, -32601, "Method not found");
        }
    }

    fn handleInitialize(self: *McpServer, writer: anytype, id: ?std.json.Value, params: ?std.json.Value) !void {
        _ = self;
        _ = params;

        // Build response dynamically since id is runtime value
        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        if (id) |id_val| {
            switch (id_val) {
                .integer => |n| try writer.print("{d}", .{n}),
                .string => |s| try writer.print("\"{s}\"", .{s}),
                else => try writer.writeAll("null"),
            }
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"skim-mcp\",\"version\":\"0.1.0\"}}}\n");
    }

    fn handleToolsList(self: *McpServer, writer: anytype, id: ?std.json.Value) !void {
        _ = self;
        _ = id;

        const response =
            \\{"jsonrpc":"2.0","id":0,"result":{"tools":[
            \\{"name":"list_clients","description":"List all connected skim instances","inputSchema":{"type":"object","properties":{},"required":[]}},
            \\{"name":"add_comment","description":"Add a review comment to a specific line","inputSchema":{"type":"object","properties":{"client_id":{"type":"string","description":"ID of the skim instance"},"file":{"type":"string","description":"File path"},"line":{"type":"integer","description":"Line number"},"text":{"type":"string","description":"Comment text"}},"required":["client_id","file","line","text"]}},
            \\{"name":"get_comments","description":"Get all comments from a skim instance","inputSchema":{"type":"object","properties":{"client_id":{"type":"string","description":"ID of the skim instance"}},"required":["client_id"]}}
            \\]}}
        ;

        try writer.writeAll(response);
        try writer.writeByte('\n');
    }

    fn handleToolsCall(self: *McpServer, writer: anytype, id: ?std.json.Value, params: ?std.json.Value) !void {
        const p = params orelse {
            try self.sendMcpError(writer, id, -32602, "Missing params");
            return;
        };

        if (p != .object) {
            try self.sendMcpError(writer, id, -32602, "Invalid params");
            return;
        }

        const name = p.object.get("name") orelse {
            try self.sendMcpError(writer, id, -32602, "Missing tool name");
            return;
        };

        if (name != .string) {
            try self.sendMcpError(writer, id, -32602, "Invalid tool name");
            return;
        }

        const arguments = p.object.get("arguments");

        if (std.mem.eql(u8, name.string, "list_clients")) {
            try self.handleListClients(writer, id);
        } else if (std.mem.eql(u8, name.string, "add_comment")) {
            try self.handleAddComment(writer, id, arguments);
        } else if (std.mem.eql(u8, name.string, "get_comments")) {
            try self.handleGetComments(writer, id, arguments);
        } else {
            try self.sendMcpError(writer, id, -32602, "Unknown tool");
        }
    }

    fn handleListClients(self: *McpServer, writer: anytype, id: ?std.json.Value) !void {
        _ = id;

        var output = std.ArrayList(u8).init(self.allocator);
        defer output.deinit();

        try output.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"");

        // Build client list
        const entries = try self.clients.list(self.allocator);
        defer self.allocator.free(entries);

        if (entries.len == 0) {
            try output.appendSlice("No skim clients connected.");
        } else {
            try output.appendSlice("Connected skim clients:\\n");
            for (entries) |entry| {
                try output.appendSlice("- ");
                try output.appendSlice(&entry.id.*);
                try output.appendSlice(" (");
                try output.appendSlice(entry.diff_ref);
                try output.appendSlice(" in ");
                try output.appendSlice(entry.cwd);
                try output.appendSlice(")\\n");
            }
        }

        try output.appendSlice("\"}]}}");
        try output.append('\n');

        try writer.writeAll(output.items);
    }

    fn handleAddComment(self: *McpServer, writer: anytype, id: ?std.json.Value, arguments: ?std.json.Value) !void {
        _ = id;

        const args = arguments orelse {
            try self.sendToolError(writer, "Missing arguments");
            return;
        };

        if (args != .object) {
            try self.sendToolError(writer, "Invalid arguments");
            return;
        }

        const client_id = args.object.get("client_id") orelse {
            try self.sendToolError(writer, "Missing client_id");
            return;
        };
        const file = args.object.get("file") orelse {
            try self.sendToolError(writer, "Missing file");
            return;
        };
        const line_val = args.object.get("line") orelse {
            try self.sendToolError(writer, "Missing line");
            return;
        };
        const text = args.object.get("text") orelse {
            try self.sendToolError(writer, "Missing text");
            return;
        };

        if (client_id != .string or file != .string or text != .string) {
            try self.sendToolError(writer, "Invalid argument types");
            return;
        }

        const line: u32 = switch (line_val) {
            .integer => |i| @intCast(i),
            .number_string => |s| std.fmt.parseInt(u32, s, 10) catch {
                try self.sendToolError(writer, "Invalid line number");
                return;
            },
            else => {
                try self.sendToolError(writer, "Invalid line type");
                return;
            },
        };

        // Find client
        const client = self.clients.getByIdString(client_id.string) orelse {
            try self.sendToolError(writer, "Client not found");
            return;
        };

        // Send add_comment message to client
        const msg = try protocol.encodeAddComment(self.allocator, .{
            .file = file.string,
            .line = line,
            .text = text.string,
        });
        defer self.allocator.free(msg);

        client.stream.writeAll(msg) catch |err| {
            std.log.err("Failed to send to client: {}", .{err});
            try self.sendToolError(writer, "Failed to send to client");
            return;
        };

        try self.sendToolSuccess(writer, "Comment sent to skim client");
    }

    fn handleGetComments(self: *McpServer, writer: anytype, id: ?std.json.Value, arguments: ?std.json.Value) !void {
        _ = id;

        const args = arguments orelse {
            try self.sendToolError(writer, "Missing arguments");
            return;
        };

        if (args != .object) {
            try self.sendToolError(writer, "Invalid arguments");
            return;
        }

        const client_id = args.object.get("client_id") orelse {
            try self.sendToolError(writer, "Missing client_id");
            return;
        };

        if (client_id != .string) {
            try self.sendToolError(writer, "Invalid client_id type");
            return;
        }

        // Find client
        const client = self.clients.getByIdString(client_id.string) orelse {
            try self.sendToolError(writer, "Client not found");
            return;
        };

        // Send get_comments request to client
        const msg = try protocol.encodeGetComments(self.allocator);
        defer self.allocator.free(msg);

        client.stream.writeAll(msg) catch |err| {
            std.log.err("Failed to send to client: {}", .{err});
            try self.sendToolError(writer, "Failed to send to client");
            return;
        };

        // Note: In a more complete implementation, we'd wait for the response
        // For MVP, we just acknowledge the request was sent
        try self.sendToolSuccess(writer, "Comment request sent to skim client");
    }

    fn sendMcpError(self: *McpServer, writer: anytype, id: ?std.json.Value, code: i32, message: []const u8) !void {
        _ = id;

        var output = std.ArrayList(u8).init(self.allocator);
        defer output.deinit();

        const w = output.writer();
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}\n", .{ code, message });

        try writer.writeAll(output.items);
    }

    fn sendToolError(self: *McpServer, writer: anytype, message: []const u8) !void {
        var output = std.ArrayList(u8).init(self.allocator);
        defer output.deinit();

        const w = output.writer();
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"Error: {s}\"}}],\"isError\":true}}}}\n", .{message});

        try writer.writeAll(output.items);
    }

    fn sendToolSuccess(self: *McpServer, writer: anytype, message: []const u8) !void {
        var output = std.ArrayList(u8).init(self.allocator);
        defer output.deinit();

        const w = output.writer();
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}}}\n", .{message});

        try writer.writeAll(output.items);
    }

    // =========================================================================
    // Discovery File
    // =========================================================================

    fn writeDiscoveryFile(self: *McpServer) !void {
        const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch return;
        defer self.allocator.free(home);

        const dir_path = try std.fmt.allocPrint(self.allocator, "{s}/.skim", .{home});
        defer self.allocator.free(dir_path);

        std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const file_path = try std.fmt.allocPrint(self.allocator, "{s}/.skim/mcp.json", .{home});
        defer self.allocator.free(file_path);

        const file = try std.fs.createFileAbsolute(file_path, .{});
        defer file.close();

        const pid = getCurrentPid();
        try file.writer().print("{{\"port\":{d},\"pid\":{d}}}\n", .{ self.port, pid });
    }

    fn deleteDiscoveryFile(self: *McpServer) void {
        const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch return;
        defer self.allocator.free(home);

        const file_path = std.fmt.allocPrint(self.allocator, "{s}/.skim/mcp.json", .{home}) catch return;
        defer self.allocator.free(file_path);

        std.fs.deleteFileAbsolute(file_path) catch {};
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Cross-platform getpid implementation
fn getCurrentPid() i32 {
    if (builtin.os.tag == .linux) {
        return @intCast(std.os.linux.getpid());
    } else {
        // macOS and other POSIX systems
        const c_getpid = @extern(*const fn () callconv(.C) c_int, .{ .name = "getpid" });
        return @intCast(c_getpid());
    }
}

// =============================================================================
// Tests
// =============================================================================

test "server init and deinit" {
    const allocator = std.testing.allocator;

    const server = try McpServer.init(allocator, 19847);
    defer server.deinit();

    try std.testing.expect(!server.running);
    try std.testing.expectEqual(@as(u16, 19847), server.port);
}
