const std = @import("std");
const net = std.net;
const posix = std.posix;

const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const internal_protocol = @import("internal_protocol.zig");
const registry = @import("registry.zig");
const discovery = @import("discovery.zig");
const line_resolver = @import("line_resolver.zig");
const framework = @import("framework.zig");
const tools = @import("tools.zig");

// =============================================================================
// Daemon Server
// =============================================================================

/// Central daemon server that manages TUI clients and MCP adapters
pub const Daemon = struct {
    allocator: Allocator,

    // TCP listeners
    tui_listener: ?net.Server,
    adapter_listener: ?net.Server,
    tui_port: u16,
    adapter_port: u16,

    // Registries
    tui_clients: registry.ClientRegistry,
    adapters: AdapterRegistry,

    // Pending connections (before hello/handshake)
    pending_tui_connections: std.ArrayList(PendingConnection),
    pending_adapter_connections: std.ArrayList(PendingConnection),

    // Request tracking for async response correlation
    pending_requests: std.AutoHashMap([36]u8, PendingRequest),

    // MCP Framework server
    mcp_server: framework.Server,

    // State
    running: bool,

    const Self = @This();

    pub fn init(allocator: Allocator, tui_port: u16, adapter_port: u16) !*Self {
        const daemon = try allocator.create(Self);
        errdefer allocator.destroy(daemon);

        daemon.* = .{
            .allocator = allocator,
            .tui_listener = null,
            .adapter_listener = null,
            .tui_port = tui_port,
            .adapter_port = adapter_port,
            .tui_clients = registry.ClientRegistry.init(allocator),
            .adapters = AdapterRegistry.init(allocator),
            .pending_tui_connections = std.ArrayList(PendingConnection).init(allocator),
            .pending_adapter_connections = std.ArrayList(PendingConnection).init(allocator),
            .pending_requests = std.AutoHashMap([36]u8, PendingRequest).init(allocator),
            .mcp_server = try tools.createServer(allocator),
            .running = false,
        };

        return daemon;
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        // Close pending connections
        for (self.pending_tui_connections.items) |*pending| {
            pending.stream.close();
        }
        self.pending_tui_connections.deinit();

        for (self.pending_adapter_connections.items) |*pending| {
            pending.stream.close();
        }
        self.pending_adapter_connections.deinit();

        // Clean up pending requests
        var req_it = self.pending_requests.valueIterator();
        while (req_it.next()) |req| {
            switch (req.mcp_id) {
                .string => |s| self.allocator.free(s),
                else => {},
            }
            self.allocator.free(req.method);
            if (req.params) |p| self.allocator.free(p);
        }
        self.pending_requests.deinit();

        self.mcp_server.deinit();
        self.tui_clients.deinit();
        self.adapters.deinit();
        self.allocator.destroy(self);
    }

    /// Start the daemon listeners
    pub fn start(self: *Self) !void {
        // Start TUI listener
        const tui_address = net.Address.initIp4(.{ 127, 0, 0, 1 }, self.tui_port);
        self.tui_listener = try tui_address.listen(.{ .reuse_address = true });
        try setNonBlocking(self.tui_listener.?.stream.handle);

        // Start adapter listener
        const adapter_address = net.Address.initIp4(.{ 127, 0, 0, 1 }, self.adapter_port);
        self.adapter_listener = try adapter_address.listen(.{ .reuse_address = true });
        try setNonBlocking(self.adapter_listener.?.stream.handle);

        self.running = true;

        // Write discovery file
        try discovery.writeDiscoveryFile(self.allocator, .{
            .tui_port = self.tui_port,
            .adapter_port = self.adapter_port,
            .pid = getCurrentPid(),
        });

        std.log.info("Daemon started: TUI port {d}, Adapter port {d}", .{ self.tui_port, self.adapter_port });
    }

    /// Stop the daemon
    pub fn stop(self: *Self) void {
        self.running = false;

        if (self.tui_listener) |*listener| {
            listener.deinit();
            self.tui_listener = null;
        }

        if (self.adapter_listener) |*listener| {
            listener.deinit();
            self.adapter_listener = null;
        }

        discovery.deleteDiscoveryFile(self.allocator);
        std.log.info("Daemon stopped", .{});
    }

    /// Main daemon loop
    pub fn run(self: *Self) !void {
        while (self.running) {
            // Accept new connections
            try self.acceptTuiConnections();
            try self.acceptAdapterConnections();

            // Poll pending connections for handshakes
            try self.pollPendingTuiConnections();
            try self.pollPendingAdapterConnections();

            // Poll registered clients for messages
            try self.pollTuiClients();
            try self.pollAdapters();

            // Sweep for timed-out requests (every loop iteration is fine for now)
            self.sweepTimedOutRequests();

            // Small sleep to avoid busy-waiting
            std.time.sleep(1 * std.time.ns_per_ms);
        }
    }

    // =========================================================================
    // TUI Client Handling
    // =========================================================================

    fn acceptTuiConnections(self: *Self) !void {
        if (self.tui_listener) |*listener| {
            const conn = listener.accept() catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };

            std.log.info("New TUI connection from {}", .{conn.address});
            try setNonBlocking(conn.stream.handle);

            try self.pending_tui_connections.append(.{
                .stream = conn.stream,
                .recv_buffer = undefined,
                .recv_len = 0,
                .connected_at = std.time.timestamp(),
            });
        }
    }

    fn pollPendingTuiConnections(self: *Self) !void {
        var i: usize = 0;
        while (i < self.pending_tui_connections.items.len) {
            var pending = &self.pending_tui_connections.items[i];

            const bytes_read = pending.stream.read(pending.recv_buffer[pending.recv_len..]) catch |err| switch (err) {
                error.WouldBlock => {
                    i += 1;
                    continue;
                },
                error.ConnectionResetByPeer, error.BrokenPipe => {
                    pending.stream.close();
                    _ = self.pending_tui_connections.swapRemove(i);
                    continue;
                },
                else => return err,
            };

            if (bytes_read == 0) {
                pending.stream.close();
                _ = self.pending_tui_connections.swapRemove(i);
                continue;
            }

            pending.recv_len += bytes_read;

            // Look for complete message
            if (std.mem.indexOfScalar(u8, pending.recv_buffer[0..pending.recv_len], '\n')) |newline_pos| {
                const line = pending.recv_buffer[0..newline_pos];

                const msg = protocol.decode(self.allocator, line) catch |err| {
                    std.log.err("Failed to decode TUI message: {}, raw: {s}", .{ err, line });
                    pending.stream.close();
                    _ = self.pending_tui_connections.swapRemove(i);
                    continue;
                };
                defer self.freeProtocolMessage(msg);

                switch (msg) {
                    .hello => |hello| {
                        std.log.info("TUI client registered: {s}", .{hello.id});

                        const client = self.tui_clients.add(pending.stream, hello) catch |err| {
                            std.log.err("Failed to register TUI client: {}", .{err});
                            pending.stream.close();
                            _ = self.pending_tui_connections.swapRemove(i);
                            continue;
                        };

                        // Send welcome
                        const welcome = protocol.encodeWelcome(self.allocator, &client.id) catch {
                            _ = self.pending_tui_connections.swapRemove(i);
                            continue;
                        };
                        defer self.allocator.free(welcome);
                        client.stream.writeAll(welcome) catch {};

                        // Notify adapters of new client
                        self.broadcastClientUpdate(.connected, client) catch {};

                        _ = self.pending_tui_connections.swapRemove(i);
                        continue;
                    },
                    else => {
                        pending.stream.close();
                        _ = self.pending_tui_connections.swapRemove(i);
                        continue;
                    },
                }
            }

            i += 1;
        }
    }

    fn pollTuiClients(self: *Self) !void {
        var to_remove = std.ArrayList(registry.SessionId).init(self.allocator);
        defer to_remove.deinit();

        var it = self.tui_clients.iterator();
        while (it.next()) |client_ptr| {
            const client = client_ptr.*;

            const bytes_read = client.stream.read(client.recv_buffer[client.recv_len..]) catch |err| switch (err) {
                error.WouldBlock => continue,
                error.ConnectionResetByPeer, error.BrokenPipe => {
                    std.log.info("TUI client {s} disconnected", .{client.id});
                    try to_remove.append(client.id);
                    continue;
                },
                else => return err,
            };

            if (bytes_read == 0) {
                std.log.info("TUI client {s} closed connection", .{client.id});
                try to_remove.append(client.id);
                continue;
            }

            client.recv_len += bytes_read;
            self.tui_clients.touch(client.id);

            try self.parseTuiMessages(client);
        }

        // Remove disconnected clients and notify adapters
        for (to_remove.items) |id| {
            if (self.tui_clients.get(id)) |client| {
                self.broadcastClientUpdate(.disconnected, client) catch {};
            }
            self.tui_clients.remove(id);
        }
    }

    fn parseTuiMessages(self: *Self, client: *registry.ClientInfo) !void {
        var parse_start: usize = 0;

        while (parse_start < client.recv_len) {
            const newline_pos = std.mem.indexOfScalar(u8, client.recv_buffer[parse_start..client.recv_len], '\n');
            if (newline_pos) |pos| {
                const end = parse_start + pos;
                const line = client.recv_buffer[parse_start..end];

                if (line.len > 0) {
                    try self.handleTuiMessage(client, line);
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

    fn handleTuiMessage(self: *Self, client: *registry.ClientInfo, line: []const u8) !void {
        const msg = protocol.decode(self.allocator, line) catch |err| {
            std.log.warn("Failed to parse TUI message: {}", .{err});
            return;
        };
        defer self.freeProtocolMessage(msg);

        switch (msg) {
            .comment_added => |result| {
                std.log.debug("TUI {s} comment_added: success={}", .{ client.id, result.success });
                // Find and complete the pending request
                try self.completePendingRequest(client, result);
            },
            .comments => |result| {
                std.log.debug("TUI {s} sent {} comments", .{ client.id, result.comments.len });
                try self.completePendingCommentsRequest(client, result);
            },
            .diff_context => |result| {
                std.log.debug("TUI {s} sent diff context with {} files", .{ client.id, result.files.len });
                try self.completePendingDiffContextRequest(client, result);
            },
            .file_diff => |result| {
                std.log.debug("TUI {s} sent file diff for {s} with {} hunks", .{ client.id, result.file, result.hunks.len });
                try self.completePendingFileDiffRequest(client, result);
            },
            .ping => {
                const pong = try protocol.encodePong(self.allocator);
                defer self.allocator.free(pong);
                client.stream.writeAll(pong) catch {};
            },
            else => {
                std.log.debug("TUI message from {s}: {}", .{ client.id, @as(std.meta.Tag(@TypeOf(msg)), msg) });
            },
        }
    }

    // =========================================================================
    // Adapter Handling
    // =========================================================================

    fn acceptAdapterConnections(self: *Self) !void {
        if (self.adapter_listener) |*listener| {
            const conn = listener.accept() catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };

            std.log.info("New adapter connection from {}", .{conn.address});
            try setNonBlocking(conn.stream.handle);

            try self.pending_adapter_connections.append(.{
                .stream = conn.stream,
                .recv_buffer = undefined,
                .recv_len = 0,
                .connected_at = std.time.timestamp(),
            });
        }
    }

    fn pollPendingAdapterConnections(self: *Self) !void {
        var i: usize = 0;
        while (i < self.pending_adapter_connections.items.len) {
            var pending = &self.pending_adapter_connections.items[i];

            const bytes_read = pending.stream.read(pending.recv_buffer[pending.recv_len..]) catch |err| switch (err) {
                error.WouldBlock => {
                    i += 1;
                    continue;
                },
                error.ConnectionResetByPeer, error.BrokenPipe => {
                    pending.stream.close();
                    _ = self.pending_adapter_connections.swapRemove(i);
                    continue;
                },
                else => return err,
            };

            if (bytes_read == 0) {
                pending.stream.close();
                _ = self.pending_adapter_connections.swapRemove(i);
                continue;
            }

            pending.recv_len += bytes_read;

            // Look for complete message
            if (std.mem.indexOfScalar(u8, pending.recv_buffer[0..pending.recv_len], '\n')) |newline_pos| {
                const line = pending.recv_buffer[0..newline_pos];

                var msg = internal_protocol.decodeAdapterMessage(self.allocator, line) catch {
                    pending.stream.close();
                    _ = self.pending_adapter_connections.swapRemove(i);
                    continue;
                };
                defer internal_protocol.freeAdapterMessage(self.allocator, &msg);

                switch (msg) {
                    .adapter_hello => |hello| {
                        std.log.info("Adapter registered: {s}", .{hello.adapter_id});

                        const adapter = self.adapters.add(pending.stream, hello.adapter_id) catch |err| {
                            std.log.err("Failed to register adapter: {}", .{err});
                            pending.stream.close();
                            _ = self.pending_adapter_connections.swapRemove(i);
                            continue;
                        };

                        // Send welcome with current client list
                        const clients = self.buildClientSummaryList() catch {
                            _ = self.pending_adapter_connections.swapRemove(i);
                            continue;
                        };
                        defer {
                            for (clients) |c| {
                                self.allocator.free(c.id);
                            }
                            self.allocator.free(clients);
                        }

                        const welcome = internal_protocol.encodeAdapterWelcome(self.allocator, &adapter.id, clients) catch {
                            _ = self.pending_adapter_connections.swapRemove(i);
                            continue;
                        };
                        defer self.allocator.free(welcome);
                        adapter.stream.writeAll(welcome) catch {};

                        _ = self.pending_adapter_connections.swapRemove(i);
                        continue;
                    },
                    else => {
                        pending.stream.close();
                        _ = self.pending_adapter_connections.swapRemove(i);
                        continue;
                    },
                }
            }

            i += 1;
        }
    }

    fn pollAdapters(self: *Self) !void {
        var to_remove = std.ArrayList(registry.SessionId).init(self.allocator);
        defer to_remove.deinit();

        var it = self.adapters.iterator();
        while (it.next()) |adapter_ptr| {
            const adapter = adapter_ptr.*;

            const bytes_read = adapter.stream.read(adapter.recv_buffer[adapter.recv_len..]) catch |err| switch (err) {
                error.WouldBlock => continue,
                error.ConnectionResetByPeer, error.BrokenPipe => {
                    std.log.info("Adapter {s} disconnected", .{adapter.id});
                    try to_remove.append(adapter.id);
                    continue;
                },
                else => return err,
            };

            if (bytes_read == 0) {
                std.log.info("Adapter {s} closed connection", .{adapter.id});
                try to_remove.append(adapter.id);
                continue;
            }

            adapter.recv_len += bytes_read;
            self.adapters.touch(adapter.id);

            try self.parseAdapterMessages(adapter);
        }

        // Remove disconnected adapters and cancel their pending requests
        for (to_remove.items) |id| {
            self.cancelPendingRequestsForAdapter(id);
            self.adapters.remove(id);
        }
    }

    fn parseAdapterMessages(self: *Self, adapter: *AdapterInfo) !void {
        var parse_start: usize = 0;

        while (parse_start < adapter.recv_len) {
            const newline_pos = std.mem.indexOfScalar(u8, adapter.recv_buffer[parse_start..adapter.recv_len], '\n');
            if (newline_pos) |pos| {
                const end = parse_start + pos;
                const line = adapter.recv_buffer[parse_start..end];

                if (line.len > 0) {
                    try self.handleAdapterMessage(adapter, line);
                }

                parse_start = end + 1;
            } else {
                break;
            }
        }

        // Move remaining data
        if (parse_start > 0 and parse_start < adapter.recv_len) {
            const remaining = adapter.recv_len - parse_start;
            std.mem.copyForwards(u8, adapter.recv_buffer[0..remaining], adapter.recv_buffer[parse_start..adapter.recv_len]);
            adapter.recv_len = remaining;
        } else if (parse_start >= adapter.recv_len) {
            adapter.recv_len = 0;
        }
    }

    fn handleAdapterMessage(self: *Self, adapter: *AdapterInfo, line: []const u8) !void {
        var msg = internal_protocol.decodeAdapterMessage(self.allocator, line) catch |err| {
            std.log.warn("Failed to parse adapter message: {}", .{err});
            return;
        };
        defer internal_protocol.freeAdapterMessage(self.allocator, &msg);

        switch (msg) {
            .mcp_request => |req| {
                std.log.debug("Adapter {s} MCP request: {s}", .{ adapter.id, req.method });
                try self.handleMcpRequest(adapter, req);
            },
            .adapter_goodbye => {
                std.log.info("Adapter {s} said goodbye", .{adapter.id});
            },
            else => {},
        }
    }

    // =========================================================================
    // MCP Request Handling
    // =========================================================================

    fn handleMcpRequest(self: *Self, adapter: *AdapterInfo, req: internal_protocol.McpRequestPayload) !void {
        // Use framework for initialize and tools/list
        if (std.mem.eql(u8, req.method, "initialize")) {
            try self.handleInitialize(adapter, req);
        } else if (std.mem.eql(u8, req.method, "tools/list")) {
            try self.handleToolsList(adapter, req);
        } else if (std.mem.eql(u8, req.method, "tools/call")) {
            try self.handleToolsCall(adapter, req);
        } else if (std.mem.eql(u8, req.method, "notifications/initialized")) {
            // No response needed for notifications
        } else {
            try self.sendMcpError(adapter, req.request_id, req.mcp_id, -32601, "Method not found");
        }
    }

    fn handleInitialize(self: *Self, adapter: *AdapterInfo, req: internal_protocol.McpRequestPayload) !void {
        // Use framework to encode initialize response
        const result = try self.mcp_server.encodeInitializeResponse(self.allocator);
        defer self.allocator.free(result);
        try self.sendMcpResponse(adapter, req.request_id, req.mcp_id, result);
    }

    fn handleToolsList(self: *Self, adapter: *AdapterInfo, req: internal_protocol.McpRequestPayload) !void {
        // Use framework to encode tools list response
        const result = try self.mcp_server.encodeToolsListResponse(self.allocator);
        defer self.allocator.free(result);
        try self.sendMcpResponse(adapter, req.request_id, req.mcp_id, result);
    }

    fn handleToolsCall(self: *Self, adapter: *AdapterInfo, req: internal_protocol.McpRequestPayload) !void {
        // Parse params to get tool name
        const params_str = req.params orelse {
            try self.sendMcpError(adapter, req.request_id, req.mcp_id, -32602, "Missing params");
            return;
        };

        const parsed = std.json.parseFromSlice(struct {
            name: []const u8,
            arguments: ?std.json.Value = null,
        }, self.allocator, params_str, .{ .ignore_unknown_fields = true }) catch {
            try self.sendMcpError(adapter, req.request_id, req.mcp_id, -32602, "Invalid params");
            return;
        };
        defer parsed.deinit();

        const tool_name = parsed.value.name;

        if (std.mem.eql(u8, tool_name, "list_clients")) {
            try self.handleListClients(adapter, req);
        } else if (std.mem.eql(u8, tool_name, "add_comment")) {
            try self.handleAddComment(adapter, req, parsed.value.arguments);
        } else if (std.mem.eql(u8, tool_name, "get_comments")) {
            try self.handleGetComments(adapter, req, parsed.value.arguments);
        } else if (std.mem.eql(u8, tool_name, "get_diff_context")) {
            try self.handleGetDiffContext(adapter, req, parsed.value.arguments);
        } else if (std.mem.eql(u8, tool_name, "get_file_diff")) {
            try self.handleGetFileDiff(adapter, req, parsed.value.arguments);
        } else {
            try self.sendMcpError(adapter, req.request_id, req.mcp_id, -32602, "Unknown tool");
        }
    }

    fn handleListClients(self: *Self, adapter: *AdapterInfo, req: internal_protocol.McpRequestPayload) !void {
        var output = std.ArrayList(u8).init(self.allocator);
        defer output.deinit();

        try output.appendSlice("{\"content\":[{\"type\":\"text\",\"text\":\"");

        const entries = try self.tui_clients.list(self.allocator);
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

        try output.appendSlice("\"}]}");

        try self.sendMcpResponse(adapter, req.request_id, req.mcp_id, output.items);
    }

    fn handleAddComment(self: *Self, adapter: *AdapterInfo, req: internal_protocol.McpRequestPayload, arguments: ?std.json.Value) !void {
        const args = arguments orelse {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Missing arguments");
            return;
        };

        if (args != .object) {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Invalid arguments");
            return;
        }

        const client_id = args.object.get("client_id") orelse {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Missing client_id");
            return;
        };
        const file = args.object.get("file") orelse {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Missing file");
            return;
        };
        const line_val = args.object.get("line") orelse {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Missing line");
            return;
        };
        const text = args.object.get("text") orelse {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Missing text");
            return;
        };

        if (client_id != .string or file != .string or text != .string) {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Invalid argument types");
            return;
        }

        const line: u32 = switch (line_val) {
            .integer => |i| @intCast(i),
            .number_string => |s| std.fmt.parseInt(u32, s, 10) catch {
                try self.sendToolError(adapter, req.request_id, req.mcp_id, "Invalid line number");
                return;
            },
            else => {
                try self.sendToolError(adapter, req.request_id, req.mcp_id, "Invalid line type");
                return;
            },
        };

        // Find TUI client
        const client = self.tui_clients.getByIdString(client_id.string) orelse {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Client not found");
            return;
        };

        // Store pending request for response correlation
        var request_id: [36]u8 = undefined;
        @memcpy(&request_id, req.request_id[0..36]);

        try self.pending_requests.put(request_id, .{
            .adapter_id = adapter.id,
            .mcp_id = switch (req.mcp_id) {
                .string => |s| .{ .string = try self.allocator.dupe(u8, s) },
                .number => |n| .{ .number = n },
                .null_value => .{ .null_value = {} },
            },
            .method = try self.allocator.dupe(u8, "add_comment"),
            .params = null,
            .tui_client_id = client.id,
            .created_at = std.time.timestamp(),
        });

        // Send add_comment to TUI
        const msg = try protocol.encodeAddComment(self.allocator, .{
            .file = file.string,
            .line = line,
            .text = text.string,
        });
        defer self.allocator.free(msg);

        client.stream.writeAll(msg) catch |err| {
            std.log.err("Failed to send to TUI: {}", .{err});
            _ = self.pending_requests.remove(request_id);
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Failed to send to client");
            return;
        };
    }

    fn handleGetComments(self: *Self, adapter: *AdapterInfo, req: internal_protocol.McpRequestPayload, arguments: ?std.json.Value) !void {
        const args = arguments orelse {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Missing arguments");
            return;
        };

        if (args != .object) {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Invalid arguments");
            return;
        }

        const client_id = args.object.get("client_id") orelse {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Missing client_id");
            return;
        };

        if (client_id != .string) {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Invalid client_id type");
            return;
        }

        // Find TUI client
        const client = self.tui_clients.getByIdString(client_id.string) orelse {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Client not found");
            return;
        };

        // Store pending request
        var request_id: [36]u8 = undefined;
        @memcpy(&request_id, req.request_id[0..36]);

        try self.pending_requests.put(request_id, .{
            .adapter_id = adapter.id,
            .mcp_id = switch (req.mcp_id) {
                .string => |s| .{ .string = try self.allocator.dupe(u8, s) },
                .number => |n| .{ .number = n },
                .null_value => .{ .null_value = {} },
            },
            .method = try self.allocator.dupe(u8, "get_comments"),
            .params = null,
            .tui_client_id = client.id,
            .created_at = std.time.timestamp(),
        });

        // Send get_comments to TUI
        const msg = try protocol.encodeGetComments(self.allocator);
        defer self.allocator.free(msg);

        client.stream.writeAll(msg) catch |err| {
            std.log.err("Failed to send to TUI: {}", .{err});
            _ = self.pending_requests.remove(request_id);
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Failed to send to client");
            return;
        };
    }

    fn handleGetDiffContext(self: *Self, adapter: *AdapterInfo, req: internal_protocol.McpRequestPayload, arguments: ?std.json.Value) !void {
        const args = arguments orelse {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Missing arguments");
            return;
        };

        if (args != .object) {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Invalid arguments");
            return;
        }

        const client_id = args.object.get("client_id") orelse {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Missing client_id");
            return;
        };

        if (client_id != .string) {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Invalid client_id type");
            return;
        }

        // Find TUI client
        const client = self.tui_clients.getByIdString(client_id.string) orelse {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Client not found");
            return;
        };

        // Store pending request
        var request_id: [36]u8 = undefined;
        @memcpy(&request_id, req.request_id[0..36]);

        try self.pending_requests.put(request_id, .{
            .adapter_id = adapter.id,
            .mcp_id = switch (req.mcp_id) {
                .string => |s| .{ .string = try self.allocator.dupe(u8, s) },
                .number => |n| .{ .number = n },
                .null_value => .{ .null_value = {} },
            },
            .method = try self.allocator.dupe(u8, "get_diff_context"),
            .params = null,
            .tui_client_id = client.id,
            .created_at = std.time.timestamp(),
        });

        // Send get_diff_context to TUI
        const msg = try protocol.encodeGetDiffContext(self.allocator);
        defer self.allocator.free(msg);

        client.stream.writeAll(msg) catch |err| {
            std.log.err("Failed to send to TUI: {}", .{err});
            _ = self.pending_requests.remove(request_id);
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Failed to send to client");
            return;
        };
    }

    fn handleGetFileDiff(self: *Self, adapter: *AdapterInfo, req: internal_protocol.McpRequestPayload, arguments: ?std.json.Value) !void {
        const args = arguments orelse {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Missing arguments");
            return;
        };

        if (args != .object) {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Invalid arguments");
            return;
        }

        const client_id = args.object.get("client_id") orelse {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Missing client_id");
            return;
        };

        const file_path = args.object.get("file") orelse {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Missing file");
            return;
        };

        if (client_id != .string or file_path != .string) {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Invalid argument types");
            return;
        }

        // Find TUI client
        const client = self.tui_clients.getByIdString(client_id.string) orelse {
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Client not found");
            return;
        };

        // Store pending request
        var request_id: [36]u8 = undefined;
        @memcpy(&request_id, req.request_id[0..36]);

        try self.pending_requests.put(request_id, .{
            .adapter_id = adapter.id,
            .mcp_id = switch (req.mcp_id) {
                .string => |s| .{ .string = try self.allocator.dupe(u8, s) },
                .number => |n| .{ .number = n },
                .null_value => .{ .null_value = {} },
            },
            .method = try self.allocator.dupe(u8, "get_file_diff"),
            .params = null,
            .tui_client_id = client.id,
            .created_at = std.time.timestamp(),
        });

        // Send get_file_diff to TUI
        const msg = try protocol.encodeGetFileDiff(self.allocator, file_path.string);
        defer self.allocator.free(msg);

        client.stream.writeAll(msg) catch |err| {
            std.log.err("Failed to send to TUI: {}", .{err});
            _ = self.pending_requests.remove(request_id);
            try self.sendToolError(adapter, req.request_id, req.mcp_id, "Failed to send to client");
            return;
        };
    }

    // =========================================================================
    // Response Handling
    // =========================================================================

    fn completePendingRequest(self: *Self, client: *registry.ClientInfo, result: protocol.CommentAddedPayload) !void {
        // Find pending request for this TUI client
        var found_key: ?[36]u8 = null;
        var it = self.pending_requests.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, &entry.value_ptr.tui_client_id, &client.id) and
                std.mem.eql(u8, entry.value_ptr.method, "add_comment"))
            {
                found_key = entry.key_ptr.*;
                break;
            }
        }

        if (found_key) |key| {
            if (self.pending_requests.fetchRemove(key)) |entry| {
                defer {
                    switch (entry.value.mcp_id) {
                        .string => |s| self.allocator.free(s),
                        else => {},
                    }
                    self.allocator.free(entry.value.method);
                }

                // Find adapter and send response
                if (self.adapters.get(entry.value.adapter_id)) |adapter| {
                    const response_text = if (result.success)
                        "Comment added successfully"
                    else
                        result.@"error" orelse "Failed to add comment";

                    var output = std.ArrayList(u8).init(self.allocator);
                    defer output.deinit();

                    try output.appendSlice("{\"content\":[{\"type\":\"text\",\"text\":\"");
                    try output.appendSlice(response_text);
                    try output.appendSlice("\"}]");
                    if (!result.success) {
                        try output.appendSlice(",\"isError\":true");
                    }
                    try output.appendSlice("}");

                    try self.sendMcpResponse(adapter, &key, entry.value.mcp_id, output.items);
                }
            }
        }
    }

    fn completePendingCommentsRequest(self: *Self, client: *registry.ClientInfo, result: protocol.CommentsPayload) !void {
        // Find pending request for this TUI client
        var found_key: ?[36]u8 = null;
        var it = self.pending_requests.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, &entry.value_ptr.tui_client_id, &client.id) and
                std.mem.eql(u8, entry.value_ptr.method, "get_comments"))
            {
                found_key = entry.key_ptr.*;
                break;
            }
        }

        if (found_key) |key| {
            if (self.pending_requests.fetchRemove(key)) |entry| {
                defer {
                    switch (entry.value.mcp_id) {
                        .string => |s| self.allocator.free(s),
                        else => {},
                    }
                    self.allocator.free(entry.value.method);
                }

                // Find adapter and send response
                if (self.adapters.get(entry.value.adapter_id)) |adapter| {
                    var output = std.ArrayList(u8).init(self.allocator);
                    defer output.deinit();

                    try output.appendSlice("{\"content\":[{\"type\":\"text\",\"text\":\"");

                    if (result.comments.len == 0) {
                        try output.appendSlice("No comments.");
                    } else {
                        try output.appendSlice("Comments:\\n");
                        for (result.comments) |comment| {
                            try output.writer().print("- {s}:{d} [{s}]: {s}\\n", .{
                                comment.file_path,
                                comment.line,
                                comment.line_type,
                                comment.text,
                            });
                        }
                    }

                    try output.appendSlice("\"}]}");

                    try self.sendMcpResponse(adapter, &key, entry.value.mcp_id, output.items);
                }
            }
        }
    }

    fn completePendingDiffContextRequest(self: *Self, client: *registry.ClientInfo, result: protocol.DiffContextPayload) !void {
        // Find pending request for this TUI client
        var found_key: ?[36]u8 = null;
        var it = self.pending_requests.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, &entry.value_ptr.tui_client_id, &client.id) and
                std.mem.eql(u8, entry.value_ptr.method, "get_diff_context"))
            {
                found_key = entry.key_ptr.*;
                break;
            }
        }

        if (found_key) |key| {
            if (self.pending_requests.fetchRemove(key)) |entry| {
                defer {
                    switch (entry.value.mcp_id) {
                        .string => |s| self.allocator.free(s),
                        else => {},
                    }
                    self.allocator.free(entry.value.method);
                }

                // Find adapter and send response
                if (self.adapters.get(entry.value.adapter_id)) |adapter| {
                    var output = std.ArrayList(u8).init(self.allocator);
                    defer output.deinit();

                    // Build JSON response with diff context metadata
                    try output.appendSlice("{\"content\":[{\"type\":\"text\",\"text\":\"");

                    // Header with diff mode and project info
                    try output.appendSlice("Diff Context:\\n");
                    try output.appendSlice("  Mode: ");
                    try writeJsonEscaped(output.writer(), result.diff_ref);
                    try output.appendSlice("\\n  Project: ");
                    try writeJsonEscaped(output.writer(), result.cwd);
                    try output.appendSlice("\\n\\n");

                    if (result.files.len == 0) {
                        try output.appendSlice("No files in diff.");
                    } else {
                        try output.writer().print("Files ({d}):\\n", .{result.files.len});
                        for (result.files) |file| {
                            // Format: path [status] (+additions/-deletions, N hunks)
                            try output.appendSlice("  ");
                            try writeJsonEscaped(output.writer(), file.path);
                            if (!std.mem.eql(u8, file.old_path, file.path) and file.old_path.len > 0) {
                                try output.appendSlice(" (was: ");
                                try writeJsonEscaped(output.writer(), file.old_path);
                                try output.appendSlice(")");
                            }
                            try output.appendSlice(" [");
                            try output.appendSlice(file.status);
                            try output.writer().print("] (+{d}/-{d}, {d} hunks)\\n", .{
                                file.additions,
                                file.deletions,
                                file.hunk_count,
                            });
                        }
                    }

                    try output.appendSlice("\"}]}");

                    try self.sendMcpResponse(adapter, &key, entry.value.mcp_id, output.items);
                }
            }
        }
    }

    fn completePendingFileDiffRequest(self: *Self, client: *registry.ClientInfo, result: protocol.FileDiffPayload) !void {
        // Find pending request for this TUI client
        var found_key: ?[36]u8 = null;
        var it = self.pending_requests.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, &entry.value_ptr.tui_client_id, &client.id) and
                std.mem.eql(u8, entry.value_ptr.method, "get_file_diff"))
            {
                found_key = entry.key_ptr.*;
                break;
            }
        }

        if (found_key) |key| {
            if (self.pending_requests.fetchRemove(key)) |entry| {
                defer {
                    switch (entry.value.mcp_id) {
                        .string => |s| self.allocator.free(s),
                        else => {},
                    }
                    self.allocator.free(entry.value.method);
                }

                // Find adapter and send response
                if (self.adapters.get(entry.value.adapter_id)) |adapter| {
                    var output = std.ArrayList(u8).init(self.allocator);
                    defer output.deinit();

                    // Build response with file diff content
                    try output.appendSlice("{\"content\":[{\"type\":\"text\",\"text\":\"");

                    // File header
                    try output.appendSlice("File: ");
                    try writeJsonEscaped(output.writer(), result.file);
                    if (!std.mem.eql(u8, result.old_file, result.file) and result.old_file.len > 0) {
                        try output.appendSlice(" (was: ");
                        try writeJsonEscaped(output.writer(), result.old_file);
                        try output.appendSlice(")");
                    }
                    try output.appendSlice("\\nStatus: ");
                    try output.appendSlice(result.status);
                    try output.appendSlice("\\n\\n");

                    // Output hunks
                    for (result.hunks) |hunk| {
                        // Hunk header
                        try writeJsonEscaped(output.writer(), hunk.header);
                        try output.appendSlice("\\n");

                        // Lines
                        for (hunk.lines) |line| {
                            // Prefix based on line type
                            if (std.mem.eql(u8, line.line_type, "add")) {
                                try output.appendSlice("+");
                            } else if (std.mem.eql(u8, line.line_type, "delete")) {
                                try output.appendSlice("-");
                            } else {
                                try output.appendSlice(" ");
                            }
                            try writeJsonEscaped(output.writer(), line.content);
                            try output.appendSlice("\\n");
                        }
                    }

                    try output.appendSlice("\"}]}");

                    try self.sendMcpResponse(adapter, &key, entry.value.mcp_id, output.items);
                }
            }
        }
    }

    fn cancelPendingRequestsForAdapter(self: *Self, adapter_id: registry.SessionId) void {
        var to_remove = std.ArrayList([36]u8).init(self.allocator);
        defer to_remove.deinit();

        var it = self.pending_requests.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, &entry.value_ptr.adapter_id, &adapter_id)) {
                to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.pending_requests.fetchRemove(key)) |entry| {
                switch (entry.value.mcp_id) {
                    .string => |s| self.allocator.free(s),
                    else => {},
                }
                self.allocator.free(entry.value.method);
                if (entry.value.params) |p| self.allocator.free(p);
            }
        }
    }

    fn sweepTimedOutRequests(self: *Self) void {
        const now = std.time.timestamp();
        const timeout_seconds: i64 = 30;

        var to_remove = std.ArrayList([36]u8).init(self.allocator);
        defer to_remove.deinit();

        var it = self.pending_requests.iterator();
        while (it.next()) |entry| {
            if (now - entry.value_ptr.created_at > timeout_seconds) {
                to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.pending_requests.fetchRemove(key)) |entry| {
                // Send timeout error to adapter
                if (self.adapters.get(entry.value.adapter_id)) |adapter| {
                    self.sendMcpError(adapter, &key, entry.value.mcp_id, -32000, "Request timed out") catch {};
                }

                switch (entry.value.mcp_id) {
                    .string => |s| self.allocator.free(s),
                    else => {},
                }
                self.allocator.free(entry.value.method);
                if (entry.value.params) |p| self.allocator.free(p);
            }
        }
    }

    // =========================================================================
    // Helper Functions
    // =========================================================================

    fn sendMcpResponse(self: *Self, adapter: *AdapterInfo, request_id: []const u8, mcp_id: internal_protocol.McpId, result: []const u8) !void {
        const msg = try internal_protocol.encodeMcpResponse(self.allocator, request_id, mcp_id, result, null);
        defer self.allocator.free(msg);
        adapter.stream.writeAll(msg) catch {};
    }

    fn sendMcpError(self: *Self, adapter: *AdapterInfo, request_id: []const u8, mcp_id: internal_protocol.McpId, code: i32, message: []const u8) !void {
        const msg = try internal_protocol.encodeMcpResponse(self.allocator, request_id, mcp_id, null, .{
            .code = code,
            .message = message,
        });
        defer self.allocator.free(msg);
        adapter.stream.writeAll(msg) catch {};
    }

    fn sendToolError(self: *Self, adapter: *AdapterInfo, request_id: []const u8, mcp_id: internal_protocol.McpId, message: []const u8) !void {
        var output = std.ArrayList(u8).init(self.allocator);
        defer output.deinit();

        try output.appendSlice("{\"content\":[{\"type\":\"text\",\"text\":\"Error: ");
        try output.appendSlice(message);
        try output.appendSlice("\"}],\"isError\":true}");

        try self.sendMcpResponse(adapter, request_id, mcp_id, output.items);
    }

    fn broadcastClientUpdate(self: *Self, action: internal_protocol.ClientAction, client: *registry.ClientInfo) !void {
        const msg = try internal_protocol.encodeClientUpdate(self.allocator, action, .{
            .id = &client.id,
            .cwd = client.cwd,
            .diff_ref = client.diff_ref,
            .file_count = client.files.len,
        });
        defer self.allocator.free(msg);

        var it = self.adapters.iterator();
        while (it.next()) |adapter_ptr| {
            adapter_ptr.*.stream.writeAll(msg) catch {};
        }
    }

    fn buildClientSummaryList(self: *Self) ![]internal_protocol.ClientSummary {
        const entries = try self.tui_clients.list(self.allocator);
        defer self.allocator.free(entries);

        var summaries = try self.allocator.alloc(internal_protocol.ClientSummary, entries.len);
        errdefer self.allocator.free(summaries);

        for (entries, 0..) |entry, i| {
            summaries[i] = .{
                .id = try self.allocator.dupe(u8, entry.id),
                .cwd = entry.cwd,
                .diff_ref = entry.diff_ref,
                .file_count = entry.file_count,
            };
        }

        return summaries;
    }

    fn freeProtocolMessage(self: *Self, msg: protocol.ParsedMessage) void {
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
            .welcome => |w| self.allocator.free(w.id),
            .add_comment => |ac| {
                self.allocator.free(ac.file);
                self.allocator.free(ac.text);
            },
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
            .@"error" => |e| {
                self.allocator.free(e.code);
                self.allocator.free(e.message);
            },
            .diff_context => |d| {
                self.allocator.free(d.diff_ref);
                self.allocator.free(d.cwd);
                for (d.files) |file| {
                    self.allocator.free(file.path);
                    self.allocator.free(file.old_path);
                    self.allocator.free(file.status);
                }
                self.allocator.free(d.files);
            },
            .get_file_diff => |gfd| {
                self.allocator.free(gfd.file);
            },
            .file_diff => |fd| {
                self.allocator.free(fd.file);
                self.allocator.free(fd.old_file);
                self.allocator.free(fd.status);
                for (fd.hunks) |hunk| {
                    self.allocator.free(hunk.header);
                    for (hunk.lines) |line| {
                        self.allocator.free(line.line_type);
                        self.allocator.free(line.content);
                    }
                    self.allocator.free(hunk.lines);
                }
                self.allocator.free(fd.hunks);
            },
            .unknown => |u| self.allocator.free(u),
            .get_comments, .get_diff_context, .ping, .pong => {},
        }
    }
};

// =============================================================================
// Adapter Registry
// =============================================================================

pub const AdapterInfo = struct {
    id: registry.SessionId,
    stream: net.Stream,
    connected_at: i64,
    last_seen: i64,
    recv_buffer: [8192]u8,
    recv_len: usize,

    pub fn deinit(self: *AdapterInfo) void {
        self.stream.close();
    }
};

pub const AdapterRegistry = struct {
    allocator: Allocator,
    adapters: std.AutoHashMap(registry.SessionId, *AdapterInfo),

    pub fn init(allocator: Allocator) AdapterRegistry {
        return .{
            .allocator = allocator,
            .adapters = std.AutoHashMap(registry.SessionId, *AdapterInfo).init(allocator),
        };
    }

    pub fn deinit(self: *AdapterRegistry) void {
        var it = self.adapters.valueIterator();
        while (it.next()) |adapter_ptr| {
            adapter_ptr.*.deinit();
            self.allocator.destroy(adapter_ptr.*);
        }
        self.adapters.deinit();
    }

    pub fn add(self: *AdapterRegistry, stream: net.Stream, id_str: []const u8) !*AdapterInfo {
        const adapter = try self.allocator.create(AdapterInfo);
        errdefer self.allocator.destroy(adapter);

        var id: registry.SessionId = undefined;
        if (id_str.len >= 36) {
            @memcpy(&id, id_str[0..36]);
        } else {
            @memset(&id, 0);
            @memcpy(id[0..id_str.len], id_str);
        }

        const now = std.time.timestamp();
        adapter.* = .{
            .id = id,
            .stream = stream,
            .connected_at = now,
            .last_seen = now,
            .recv_buffer = undefined,
            .recv_len = 0,
        };

        try self.adapters.put(id, adapter);
        return adapter;
    }

    pub fn remove(self: *AdapterRegistry, id: registry.SessionId) void {
        if (self.adapters.fetchRemove(id)) |entry| {
            entry.value.deinit();
            self.allocator.destroy(entry.value);
        }
    }

    pub fn get(self: *AdapterRegistry, id: registry.SessionId) ?*AdapterInfo {
        return self.adapters.get(id);
    }

    pub fn touch(self: *AdapterRegistry, id: registry.SessionId) void {
        if (self.adapters.get(id)) |adapter| {
            adapter.last_seen = std.time.timestamp();
        }
    }

    pub fn count(self: *const AdapterRegistry) usize {
        return self.adapters.count();
    }

    pub fn iterator(self: *AdapterRegistry) std.AutoHashMap(registry.SessionId, *AdapterInfo).ValueIterator {
        return self.adapters.valueIterator();
    }
};

// =============================================================================
// Supporting Types
// =============================================================================

const PendingConnection = struct {
    stream: net.Stream,
    recv_buffer: [8192]u8,
    recv_len: usize,
    connected_at: i64,
};

const PendingRequest = struct {
    adapter_id: registry.SessionId,
    mcp_id: internal_protocol.McpId,
    method: []const u8,
    params: ?[]const u8,
    tui_client_id: registry.SessionId,
    created_at: i64,
};

// =============================================================================
// Helper Functions
// =============================================================================

fn setNonBlocking(handle: posix.fd_t) !void {
    const flags = try posix.fcntl(handle, posix.F.GETFL, @as(usize, 0));
    const O_NONBLOCK: usize = 0x0004; // darwin/macOS
    _ = try posix.fcntl(handle, posix.F.SETFL, flags | O_NONBLOCK);
}

fn getCurrentPid() i32 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .linux) {
        return @intCast(std.os.linux.getpid());
    } else {
        // Use extern for macOS and other POSIX systems
        const c_getpid = @extern(*const fn () callconv(.C) c_int, .{ .name = "getpid" });
        return @intCast(c_getpid());
    }
}

/// Write a string with JSON escaping (for embedding in JSON strings)
fn writeJsonEscaped(writer: anytype, str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

test "daemon init and deinit" {
    const allocator = std.testing.allocator;

    const daemon = try Daemon.init(allocator, 19999, 19998);
    defer daemon.deinit();

    try std.testing.expect(!daemon.running);
    try std.testing.expectEqual(@as(u16, 19999), daemon.tui_port);
    try std.testing.expectEqual(@as(u16, 19998), daemon.adapter_port);
}

test "adapter registry add and remove" {
    const allocator = std.testing.allocator;

    var reg = AdapterRegistry.init(allocator);
    defer reg.deinit();

    try std.testing.expectEqual(@as(usize, 0), reg.count());
}
