const std = @import("std");
const Allocator = std.mem.Allocator;
const InputEditor = @import("input_editor.zig").InputEditor;

// =============================================================================
// Agent State
// =============================================================================

/// State for the agent UI panel.
/// Manages conversation history, input buffer, and display state.
pub const AgentState = struct {
    allocator: Allocator,
    messages: std.ArrayList(Message),
    input: InputEditor.State,
    scroll_offset: usize,
    follow_bottom: bool, // When true, auto-scroll to bottom on new messages
    visible: bool,
    panel_side: PanelSide,
    full_screen: bool,
    diff_view_mode: DiffViewMode, // View mode for inline diffs

    pub const PanelSide = enum {
        left,
        right,

        pub fn fromString(s: []const u8) ?PanelSide {
            if (std.mem.eql(u8, s, "left")) return .left;
            if (std.mem.eql(u8, s, "right")) return .right;
            return null;
        }
    };

    pub const DiffViewMode = enum {
        unified,
        side_by_side,
    };

    pub fn init(allocator: Allocator, panel_side: PanelSide) AgentState {
        return .{
            .allocator = allocator,
            .messages = .{}, // Zig 0.15: ArrayList is unmanaged
            .input = InputEditor.State.init(),
            .scroll_offset = 0,
            .follow_bottom = true,
            .visible = false,
            .panel_side = panel_side,
            .full_screen = false, // Default to split view (toggle with 'z')
            .diff_view_mode = .unified, // Default to unified view
        };
    }

    pub fn deinit(self: *AgentState) void {
        for (self.messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.messages.deinit(self.allocator);
    }

    /// Add a message to the conversation history
    pub fn addMessage(self: *AgentState, role: Message.Role, content: []const u8) !void {
        const owned_content = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(owned_content);

        try self.messages.append(self.allocator, .{
            .role = role,
            .content = owned_content,
            .timestamp = std.time.timestamp(),
        });

        // Auto-scroll to bottom on new message
        self.scrollToBottom();
    }

    /// Add a diff message (from tool_call with edit content)
    pub fn addDiffMessage(self: *AgentState, title: []const u8, path: []const u8, old_text: []const u8, new_text: []const u8) !void {
        const owned_title = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(owned_title);

        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);

        const owned_old = try self.allocator.dupe(u8, old_text);
        errdefer self.allocator.free(owned_old);

        const owned_new = try self.allocator.dupe(u8, new_text);
        errdefer self.allocator.free(owned_new);

        try self.messages.append(self.allocator, .{
            .role = .diff,
            .content = owned_title,
            .timestamp = std.time.timestamp(),
            .diff_path = owned_path,
            .diff_old = owned_old,
            .diff_new = owned_new,
        });

        // Auto-scroll to bottom on new message
        self.scrollToBottom();
    }

    /// Append text to the last agent message (for streaming responses)
    pub fn appendToLastAgentMessage(self: *AgentState, text: []const u8) !void {
        if (self.messages.items.len == 0) {
            // No messages yet, create new agent message
            try self.addMessage(.agent, text);
            return;
        }

        const last = &self.messages.items[self.messages.items.len - 1];
        if (last.role != .agent) {
            // Last message isn't from agent, create new one
            try self.addMessage(.agent, text);
            return;
        }

        // Append to existing agent message
        const new_content = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}",
            .{ last.content, text },
        );
        self.allocator.free(last.content);
        last.content = new_content;

        self.scrollToBottom();
    }

    /// Append text to the last thinking message (for streaming reasoning)
    pub fn appendToLastThinkingMessage(self: *AgentState, text: []const u8) !void {
        if (self.messages.items.len == 0) {
            // No messages yet, create new thinking message
            try self.addMessage(.thinking, text);
            return;
        }

        const last = &self.messages.items[self.messages.items.len - 1];
        if (last.role != .thinking) {
            // Last message isn't thinking, create new one
            try self.addMessage(.thinking, text);
            return;
        }

        // Append to existing thinking message
        const new_content = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}",
            .{ last.content, text },
        );
        self.allocator.free(last.content);
        last.content = new_content;

        self.scrollToBottom();
    }

    /// Add a tool call message
    pub fn addToolMessage(
        self: *AgentState,
        tool_call_id: []const u8,
        tool_name: ?[]const u8,
        title: []const u8,
        command: ?[]const u8,
    ) !void {
        const owned_title = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(owned_title);

        const owned_id = try self.allocator.dupe(u8, tool_call_id);
        errdefer self.allocator.free(owned_id);

        const owned_name: ?[]const u8 = if (tool_name) |n|
            try self.allocator.dupe(u8, n)
        else
            null;
        errdefer if (owned_name) |n| self.allocator.free(n);

        const owned_cmd: ?[]const u8 = if (command) |c|
            try self.allocator.dupe(u8, c)
        else
            null;
        errdefer if (owned_cmd) |c| self.allocator.free(c);

        try self.messages.append(self.allocator, .{
            .role = .tool,
            .content = owned_title,
            .timestamp = std.time.timestamp(),
            .tool_call_id = owned_id,
            .tool_name = owned_name,
            .tool_status = .pending,
            .tool_command = owned_cmd,
        });

        self.scrollToBottom();
    }

    /// Update an existing tool message with completion status and output
    pub fn updateToolMessage(
        self: *AgentState,
        tool_call_id: []const u8,
        status: Message.ToolStatus,
        stdout: ?[]const u8,
        stderr: ?[]const u8,
    ) !void {
        // Find the tool message with matching ID
        for (self.messages.items) |*msg| {
            if (msg.role == .tool) {
                if (msg.tool_call_id) |id| {
                    if (std.mem.eql(u8, id, tool_call_id)) {
                        // Update status
                        msg.tool_status = status;

                        // Update stdout if provided
                        if (stdout) |s| {
                            if (msg.tool_stdout) |old| self.allocator.free(old);
                            msg.tool_stdout = try self.allocator.dupe(u8, s);
                        }

                        // Update stderr if provided
                        if (stderr) |s| {
                            if (msg.tool_stderr) |old| self.allocator.free(old);
                            msg.tool_stderr = try self.allocator.dupe(u8, s);
                        }

                        self.scrollToBottom();
                        return;
                    }
                }
            }
        }
    }

    /// Clear all messages
    pub fn clearMessages(self: *AgentState) void {
        for (self.messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.messages.clearRetainingCapacity();
        self.scroll_offset = 0;
    }

    /// Scroll to show the most recent messages
    pub fn scrollToBottom(self: *AgentState) void {
        self.follow_bottom = true;
        self.scroll_offset = std.math.maxInt(usize);
    }

    /// Scroll up by n lines
    pub fn scrollUp(self: *AgentState, lines: usize) void {
        // Disable follow mode when user scrolls up
        self.follow_bottom = false;
        self.scroll_offset = self.scroll_offset -| lines;
    }

    /// Scroll down by n lines
    pub fn scrollDown(self: *AgentState, lines: usize) void {
        self.scroll_offset +|= lines;
    }

    /// Update scroll offset after rendering (to get actual clamped value)
    pub fn updateScrollOffset(self: *AgentState, actual_offset: usize, max_offset: usize) void {
        self.scroll_offset = actual_offset;
        // Re-enable follow mode if scrolled to bottom
        if (actual_offset >= max_offset) {
            self.follow_bottom = true;
        }
    }

    /// Toggle visibility
    pub fn toggle(self: *AgentState) void {
        self.visible = !self.visible;
    }

    /// Toggle full-screen mode
    pub fn toggleFullScreen(self: *AgentState) void {
        self.full_screen = !self.full_screen;
    }

    /// Toggle diff view mode (unified/side-by-side)
    pub fn toggleDiffViewMode(self: *AgentState) void {
        self.diff_view_mode = switch (self.diff_view_mode) {
            .unified => .side_by_side,
            .side_by_side => .unified,
        };
    }

    /// Get message count
    pub fn messageCount(self: *const AgentState) usize {
        return self.messages.items.len;
    }
};

// =============================================================================
// Message
// =============================================================================

pub const Message = struct {
    role: Role,
    content: []const u8, // Owned by AgentState
    timestamp: i64,
    // For diff messages
    diff_path: ?[]const u8 = null,
    diff_old: ?[]const u8 = null,
    diff_new: ?[]const u8 = null,
    // For tool messages
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null, // "Bash", "Edit", "Read", etc.
    tool_status: ToolStatus = .pending,
    tool_command: ?[]const u8 = null, // For Bash: the command
    tool_stdout: ?[]const u8 = null, // For Bash: command output
    tool_stderr: ?[]const u8 = null, // For Bash: error output

    pub const ToolStatus = enum {
        pending,
        running,
        completed,
        failed,
    };

    pub const Role = enum {
        user,
        agent,
        thinking,
        system,
        diff,
        tool, // Tool call (Bash, Read, etc.)

        pub fn label(self: Role) []const u8 {
            return switch (self) {
                .user => "You",
                .agent => "Agent",
                .thinking => "Thinking",
                .system => "System",
                .diff => "Edit",
                .tool => "Tool",
            };
        }
    };

    pub fn deinit(self: *Message, allocator: Allocator) void {
        allocator.free(self.content);
        if (self.diff_path) |p| allocator.free(p);
        if (self.diff_old) |o| allocator.free(o);
        if (self.diff_new) |n| allocator.free(n);
        if (self.tool_call_id) |id| allocator.free(id);
        if (self.tool_name) |n| allocator.free(n);
        if (self.tool_command) |c| allocator.free(c);
        if (self.tool_stdout) |s| allocator.free(s);
        if (self.tool_stderr) |s| allocator.free(s);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "AgentState init and deinit" {
    const allocator = std.testing.allocator;

    var state = AgentState.init(allocator, .right);
    defer state.deinit();

    try std.testing.expect(!state.visible);
    try std.testing.expect(!state.full_screen);
    try std.testing.expectEqual(@as(usize, 0), state.messageCount());
}

test "AgentState add and clear messages" {
    const allocator = std.testing.allocator;

    var state = AgentState.init(allocator, .left);
    defer state.deinit();

    try state.addMessage(.user, "Hello");
    try state.addMessage(.agent, "Hi there!");
    try std.testing.expectEqual(@as(usize, 2), state.messageCount());

    state.clearMessages();
    try std.testing.expectEqual(@as(usize, 0), state.messageCount());
}

test "AgentState append to last agent message" {
    const allocator = std.testing.allocator;

    var state = AgentState.init(allocator, .right);
    defer state.deinit();

    try state.addMessage(.agent, "Hello");
    try state.appendToLastAgentMessage(" world");

    try std.testing.expectEqual(@as(usize, 1), state.messageCount());
    try std.testing.expectEqualStrings("Hello world", state.messages.items[0].content);
}

test "AgentState append creates new message if last is user" {
    const allocator = std.testing.allocator;

    var state = AgentState.init(allocator, .right);
    defer state.deinit();

    try state.addMessage(.user, "Question?");
    try state.appendToLastAgentMessage("Answer");

    try std.testing.expectEqual(@as(usize, 2), state.messageCount());
    try std.testing.expectEqual(Message.Role.agent, state.messages.items[1].role);
}

test "PanelSide fromString" {
    try std.testing.expectEqual(AgentState.PanelSide.left, AgentState.PanelSide.fromString("left"));
    try std.testing.expectEqual(AgentState.PanelSide.right, AgentState.PanelSide.fromString("right"));
    try std.testing.expect(AgentState.PanelSide.fromString("invalid") == null);
}
