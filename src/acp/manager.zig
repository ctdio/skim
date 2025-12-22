const std = @import("std");
const Allocator = std.mem.Allocator;
const client = @import("client.zig");
const process = @import("process.zig");
const protocol = @import("protocol.zig");
const types = @import("types.zig");
const codec = @import("codec.zig");

// =============================================================================
// ACP Manager
// =============================================================================

/// Manages ACP agent sessions for the skim TUI.
/// Handles agent lifecycle, message polling, and callback dispatch.
pub const AcpManager = struct {
    allocator: Allocator,
    acp_client: ?*client.Client,
    status: Status,
    agent_name: ?[]const u8,
    session_id: ?[]const u8,

    // Message callbacks
    on_message: ?*const fn (text: []const u8, ctx: ?*anyopaque) void,
    on_tool_call: ?*const fn (tool: ToolCallInfo, ctx: ?*anyopaque) void,
    callback_ctx: ?*anyopaque,

    // Pending messages for TUI to consume
    pending_messages: std.ArrayListUnmanaged(PendingMessage),

    pub const Status = enum {
        disconnected,
        connecting,
        connected,
        session_active,
        prompting,
        failed,
    };

    pub const PendingMessage = struct {
        kind: Kind,
        text: []const u8, // Owned

        pub const Kind = enum {
            agent_text,
            tool_start,
            tool_complete,
            error_msg,
        };

        pub fn deinit(self: *PendingMessage, allocator: Allocator) void {
            allocator.free(self.text);
        }
    };

    pub const ToolCallInfo = struct {
        id: []const u8,
        title: ?[]const u8,
        kind: types.ToolCallKind,
        status: types.ToolCallStatus,
    };

    pub const Error = error{
        AlreadyConnected,
        NotConnected,
        NoSession,
        SpawnFailed,
        InitializeFailed,
        SessionFailed,
        PromptFailed,
    } || Allocator.Error;

    /// Known agent commands to try
    pub const KnownAgent = struct {
        name: []const u8,
        command: []const u8,
        args: []const []const u8,
    };

    pub const known_agents = [_]KnownAgent{
        .{ .name = "Claude Code ACP", .command = "claude-code-acp", .args = &.{} },
        .{ .name = "Codex ACP", .command = "codex-acp", .args = &.{} },
        .{ .name = "Gemini CLI", .command = "gemini", .args = &.{"--experimental-acp"} },
    };

    pub fn init(allocator: Allocator) AcpManager {
        return .{
            .allocator = allocator,
            .acp_client = null,
            .status = .disconnected,
            .agent_name = null,
            .session_id = null,
            .on_message = null,
            .on_tool_call = null,
            .callback_ctx = null,
            .pending_messages = .{},
        };
    }

    /// Spawn and connect to an agent
    pub fn connect(self: *AcpManager, agent_command: []const u8, args: []const []const u8, cwd: []const u8) Error!void {
        if (self.acp_client != null) return error.AlreadyConnected;

        self.status = .connecting;
        std.log.info("ACP: Spawning agent '{s}'", .{agent_command});

        // Spawn the agent
        const acp = client.Client.spawn(self.allocator, .{
            .command = agent_command,
            .args = args,
            .cwd = cwd,
        }) catch |err| {
            std.log.err("ACP: Failed to spawn agent: {any}", .{err});
            self.status = .failed;
            return error.SpawnFailed;
        };
        errdefer acp.deinit();

        std.log.info("ACP: Agent spawned, sending initialize...", .{});

        // Initialize the ACP handshake
        acp.initialize() catch |err| {
            std.log.err("ACP: Initialize failed: {any}", .{err});
            self.status = .failed;
            acp.deinit();
            return error.InitializeFailed;
        };

        self.acp_client = acp;
        self.status = .connected;
        std.log.info("ACP: Connected successfully", .{});

        // Store agent name if available
        if (acp.getAgentInfo()) |info| {
            self.agent_name = self.allocator.dupe(u8, info.name) catch null;
            std.log.info("ACP: Agent name: {s}", .{info.name});
        }
    }

    /// Create a new session in the current working directory
    pub fn createSession(self: *AcpManager, cwd: []const u8) Error!void {
        const acp = self.acp_client orelse return error.NotConnected;

        std.log.info("ACP: Creating session in {s}", .{cwd});

        const sid = acp.createSession(cwd) catch |err| {
            std.log.err("ACP: Session creation failed: {any}", .{err});
            self.status = .failed;
            return error.SessionFailed;
        };

        self.session_id = self.allocator.dupe(u8, sid) catch null;
        self.status = .session_active;
        std.log.info("ACP: Session created: {s}", .{sid});
    }

    /// Send a prompt to the agent
    /// The manager will collect responses via poll()
    pub fn sendPrompt(self: *AcpManager, prompt_text: []const u8) Error!void {
        const acp = self.acp_client orelse return error.NotConnected;
        if (self.status != .session_active) return error.NoSession;

        self.status = .prompting;

        // Send prompt with internal callback that queues messages
        _ = acp.prompt(prompt_text, handleSessionUpdate, self) catch {
            self.status = .session_active; // Revert to session active on failure
            return error.PromptFailed;
        };

        self.status = .session_active;
    }

    /// Poll for new messages from the agent (non-blocking).
    /// Returns slice of pending messages. Call clearMessages() after processing.
    pub fn poll(self: *AcpManager) Error![]PendingMessage {
        const acp = self.acp_client orelse return self.pending_messages.items;

        // Poll the transport for new messages
        const messages = acp.transport.poll() catch return self.pending_messages.items;

        // Process any session/update notifications
        for (messages) |msg| {
            switch (msg) {
                .notification => |n| {
                    if (std.mem.eql(u8, n.method, "session/update")) {
                        if (n.params_json) |pjson| {
                            self.processSessionUpdate(pjson) catch {};
                        }
                    }
                },
                else => {},
            }
        }

        acp.transport.clearMessages();

        return self.pending_messages.items;
    }

    /// Clear processed messages
    pub fn clearMessages(self: *AcpManager) void {
        for (self.pending_messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.pending_messages.clearRetainingCapacity();
    }

    /// Check if connected and alive
    pub fn isConnected(self: *AcpManager) bool {
        if (self.acp_client) |acp| {
            return acp.isAlive();
        }
        return false;
    }

    /// Get agent info string for display
    pub fn getAgentDisplayName(self: *AcpManager) []const u8 {
        return self.agent_name orelse "Unknown Agent";
    }

    /// Get status string for display
    pub fn getStatusString(self: *AcpManager) []const u8 {
        return switch (self.status) {
            .disconnected => "Disconnected",
            .connecting => "Connecting...",
            .connected => "Connected",
            .session_active => "Ready",
            .prompting => "Thinking...",
            .failed => "Failed",
        };
    }

    /// Disconnect from the agent
    pub fn disconnect(self: *AcpManager) void {
        if (self.acp_client) |acp| {
            acp.deinit();
            self.acp_client = null;
        }

        if (self.agent_name) |name| {
            self.allocator.free(name);
            self.agent_name = null;
        }

        if (self.session_id) |sid| {
            self.allocator.free(sid);
            self.session_id = null;
        }

        self.clearMessages();
        self.status = .disconnected;
    }

    pub fn deinit(self: *AcpManager) void {
        self.disconnect();
        self.pending_messages.deinit(self.allocator);
    }

    // =========================================================================
    // Internal
    // =========================================================================

    fn handleSessionUpdate(update: protocol.SessionUpdateParams, ctx: ?*anyopaque) void {
        const self: *AcpManager = @ptrCast(@alignCast(ctx));

        // Handle message updates (agent text responses)
        if (update.message) |msg| {
            for (msg.content) |block| {
                switch (block) {
                    .text => |t| {
                        const text = self.allocator.dupe(u8, t.text) catch continue;
                        self.pending_messages.append(self.allocator, .{
                            .kind = .agent_text,
                            .text = text,
                        }) catch {
                            self.allocator.free(text);
                        };
                    },
                    else => {},
                }
            }
        }

        // Handle tool calls
        if (update.tool_call) |tc| {
            const title = tc.title orelse "Tool";
            const text = self.allocator.dupe(u8, title) catch return;
            self.pending_messages.append(self.allocator, .{
                .kind = .tool_start,
                .text = text,
            }) catch {
                self.allocator.free(text);
            };
        }

        // Handle tool call updates
        if (update.tool_call_update) |tcu| {
            if (tcu.status) |status| {
                if (status == .completed or status == .failed) {
                    const text = self.allocator.dupe(u8, tcu.tool_call_id) catch return;
                    self.pending_messages.append(self.allocator, .{
                        .kind = .tool_complete,
                        .text = text,
                    }) catch {
                        self.allocator.free(text);
                    };
                }
            }
        }
    }

    fn processSessionUpdate(self: *AcpManager, json: []const u8) !void {
        const acp = self.acp_client orelse return;
        const update = try acp.transport.decoder.parseSessionUpdateParams(json);
        handleSessionUpdate(update, self);
    }
};

// =============================================================================
// Agent Discovery
// =============================================================================

/// Check if an agent command is available in PATH
pub fn isAgentAvailable(command: []const u8) bool {
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "which", command },
    }) catch return false;
    defer {
        std.heap.page_allocator.free(result.stdout);
        std.heap.page_allocator.free(result.stderr);
    }
    return result.term == .Exited and result.term.Exited == 0;
}

/// Find first available agent from known list
pub fn findAvailableAgent() ?AcpManager.KnownAgent {
    for (AcpManager.known_agents) |agent| {
        if (isAgentAvailable(agent.command)) {
            return agent;
        }
    }
    return null;
}

// =============================================================================
// Tests
// =============================================================================

test "AcpManager init and deinit" {
    const allocator = std.testing.allocator;

    var manager = AcpManager.init(allocator);
    defer manager.deinit();

    try std.testing.expectEqual(AcpManager.Status.disconnected, manager.status);
    try std.testing.expect(!manager.isConnected());
}

test "AcpManager status strings" {
    const allocator = std.testing.allocator;

    var manager = AcpManager.init(allocator);
    defer manager.deinit();

    try std.testing.expectEqualStrings("Disconnected", manager.getStatusString());
    try std.testing.expectEqualStrings("Unknown Agent", manager.getAgentDisplayName());
}
