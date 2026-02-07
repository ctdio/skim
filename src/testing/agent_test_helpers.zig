const std = @import("std");
const vaxis = @import("vaxis");

const Allocator = std.mem.Allocator;

// Color constants for testing (subset from rendering/common.zig)
const Color = struct {
    const white: vaxis.Cell.Color = .{ .index = 7 };
    const dim: vaxis.Cell.Color = .{ .rgb = [3]u8{ 100, 100, 100 } };
    const user_prefix: vaxis.Cell.Color = .{ .rgb = [3]u8{ 100, 149, 237 } }; // Cornflower blue
    const agent_prefix: vaxis.Cell.Color = .{ .rgb = [3]u8{ 144, 238, 144 } }; // Light green
    const tool_pending: vaxis.Cell.Color = .{ .rgb = [3]u8{ 255, 200, 100 } }; // Yellow/amber
    const tool_running: vaxis.Cell.Color = .{ .rgb = [3]u8{ 100, 200, 255 } }; // Light blue
    const tool_completed: vaxis.Cell.Color = .{ .rgb = [3]u8{ 100, 255, 100 } }; // Green
    const tool_failed: vaxis.Cell.Color = .{ .rgb = [3]u8{ 255, 100, 100 } }; // Red
    const plan_completed: vaxis.Cell.Color = .{ .rgb = [3]u8{ 100, 255, 100 } }; // Green
    const plan_pending: vaxis.Cell.Color = .{ .rgb = [3]u8{ 200, 200, 200 } }; // Gray
    const plan_in_progress: vaxis.Cell.Color = .{ .rgb = [3]u8{ 100, 200, 255 } }; // Light blue
};

// =============================================================================
// Local Type Definitions (mirrors src/agent/state.zig types)
// =============================================================================

/// Message role - indicates who sent the message
pub const MessageRole = enum {
    user,
    agent,
    tool,
    plan_snapshot,

    pub fn label(self: MessageRole) []const u8 {
        return switch (self) {
            .user => "You",
            .agent => "Agent",
            .tool => "Tool",
            .plan_snapshot => "Todos",
        };
    }
};

/// Tool execution status
pub const ToolStatus = enum {
    pending,
    running,
    completed,
    failed,

    pub fn label(self: ToolStatus) []const u8 {
        return switch (self) {
            .pending => "Pending",
            .running => "Running...",
            .completed => "Done",
            .failed => "Failed",
        };
    }

    pub fn color(self: ToolStatus) vaxis.Cell.Color {
        return switch (self) {
            .pending => Color.tool_pending,
            .running => Color.tool_running,
            .completed => Color.tool_completed,
            .failed => Color.tool_failed,
        };
    }
};

/// Plan entry priority
pub const PlanEntryPriority = enum {
    high,
    medium,
    low,
};

/// Plan entry status
pub const PlanEntryStatus = enum {
    pending,
    in_progress,
    completed,

    pub fn marker(self: PlanEntryStatus) []const u8 {
        return switch (self) {
            .pending => "[ ]",
            .in_progress => "[~]",
            .completed => "[x]",
        };
    }

    pub fn color(self: PlanEntryStatus) vaxis.Cell.Color {
        return switch (self) {
            .pending => Color.plan_pending,
            .in_progress => Color.plan_in_progress,
            .completed => Color.plan_completed,
        };
    }
};

/// A single plan/todo entry
pub const PlanEntry = struct {
    content: []const u8,
    priority: PlanEntryPriority = .medium,
    status: PlanEntryStatus = .pending,
};

/// A message in the agent chat
pub const Message = struct {
    role: MessageRole,
    content: []const u8,
    // Tool message fields
    tool_name: ?[]const u8 = null,
    tool_command: ?[]const u8 = null,
    tool_status: ToolStatus = .pending,
    tool_stdout: ?[]const u8 = null,
    // Plan snapshot fields
    plan_entries: ?[]const PlanEntry = null,
};

// =============================================================================
// TestAgentStateBuilder
// =============================================================================

/// TestAgentStateBuilder provides a fluent interface for constructing test Message structures.
/// Use init() to start, chain builder methods, then call build() to get the final slice.
pub const TestAgentStateBuilder = struct {
    allocator: Allocator,
    messages: std.ArrayList(Message),

    pub fn init(allocator: Allocator) TestAgentStateBuilder {
        return .{
            .allocator = allocator,
            .messages = .{},
        };
    }

    /// Add a user message
    pub fn addUserMessage(self: *TestAgentStateBuilder, content: []const u8) *TestAgentStateBuilder {
        const msg = Message{
            .role = .user,
            .content = self.allocator.dupe(u8, content) catch "",
        };
        self.messages.append(self.allocator, msg) catch {};
        return self;
    }

    /// Add an agent message
    pub fn addAgentMessage(self: *TestAgentStateBuilder, content: []const u8) *TestAgentStateBuilder {
        const msg = Message{
            .role = .agent,
            .content = self.allocator.dupe(u8, content) catch "",
        };
        self.messages.append(self.allocator, msg) catch {};
        return self;
    }

    /// Add a tool call message
    pub fn addToolCall(
        self: *TestAgentStateBuilder,
        name: []const u8,
        command: ?[]const u8,
        status: ToolStatus,
        stdout: ?[]const u8,
    ) *TestAgentStateBuilder {
        const msg = Message{
            .role = .tool,
            .content = self.allocator.dupe(u8, name) catch "",
            .tool_name = self.allocator.dupe(u8, name) catch null,
            .tool_command = if (command) |c| self.allocator.dupe(u8, c) catch null else null,
            .tool_status = status,
            .tool_stdout = if (stdout) |s| self.allocator.dupe(u8, s) catch null else null,
        };
        self.messages.append(self.allocator, msg) catch {};
        return self;
    }

    /// Add a plan snapshot message
    pub fn addPlanSnapshot(self: *TestAgentStateBuilder, entries: []const PlanEntry) *TestAgentStateBuilder {
        // Clone entries using ArrayList to build mutable slice
        var entries_list: std.ArrayList(PlanEntry) = .{};
        for (entries) |entry| {
            const cloned_entry = PlanEntry{
                .content = self.allocator.dupe(u8, entry.content) catch "",
                .priority = entry.priority,
                .status = entry.status,
            };
            entries_list.append(self.allocator, cloned_entry) catch {};
        }
        const cloned = entries_list.toOwnedSlice(self.allocator) catch &[_]PlanEntry{};

        const msg = Message{
            .role = .plan_snapshot,
            .content = "Todos",
            .plan_entries = cloned,
        };
        self.messages.append(self.allocator, msg) catch {};
        return self;
    }

    /// Build and return the messages slice
    pub fn build(self: *TestAgentStateBuilder) []Message {
        return self.messages.toOwnedSlice(self.allocator) catch &[_]Message{};
    }

    /// Clean up any remaining resources
    pub fn deinit(self: *TestAgentStateBuilder) void {
        // Free any unbuilt messages
        for (self.messages.items) |msg| {
            freeMessage(self.allocator, msg);
        }
        self.messages.deinit(self.allocator);
    }
};

/// Free a message and all its owned fields
fn freeMessage(allocator: Allocator, msg: Message) void {
    if (msg.content.len > 0 and msg.role != .plan_snapshot) {
        allocator.free(msg.content);
    }
    if (msg.tool_name) |n| allocator.free(n);
    if (msg.tool_command) |c| allocator.free(c);
    if (msg.tool_stdout) |s| allocator.free(s);
    if (msg.plan_entries) |entries| {
        for (entries) |entry| {
            if (entry.content.len > 0) {
                allocator.free(entry.content);
            }
        }
        allocator.free(entries);
    }
}

/// Free a slice of messages returned from build()
pub fn freeMessages(allocator: Allocator, messages: []Message) void {
    for (messages) |msg| {
        freeMessage(allocator, msg);
    }
    allocator.free(messages);
}

// =============================================================================
// Quick Helper Functions
// =============================================================================

/// Create a quick user message
pub fn createMessage(role: MessageRole, content: []const u8) Message {
    return Message{
        .role = role,
        .content = content,
    };
}

/// Create a quick tool message
pub fn createToolMessage(name: []const u8, status: ToolStatus, output: ?[]const u8) Message {
    return Message{
        .role = .tool,
        .content = name,
        .tool_name = name,
        .tool_status = status,
        .tool_stdout = output,
    };
}

/// Create a quick plan entry
pub fn createPlanEntry(priority: PlanEntryPriority, status: PlanEntryStatus, content: []const u8) PlanEntry {
    return PlanEntry{
        .content = content,
        .priority = priority,
        .status = status,
    };
}

// =============================================================================
// Standalone Rendering Functions
// =============================================================================

/// Render a user message to a window
/// Format: "You: content"
pub fn renderUserMessage(
    win: vaxis.Window,
    content: []const u8,
    row: usize,
) void {
    if (row >= win.height) return;

    const prefix = "You: ";
    const prefix_style: vaxis.Style = .{ .fg = Color.user_prefix, .bold = true };
    const content_style: vaxis.Style = .{ .fg = Color.white };

    var segments = [_]vaxis.Cell.Segment{
        .{ .text = prefix, .style = prefix_style },
        .{ .text = content, .style = content_style },
    };

    _ = win.print(&segments, .{
        .row_offset = @intCast(row),
        .col_offset = 0,
    });
}

/// Render an agent message to a window
/// Format: "Agent: content"
pub fn renderAgentMessage(
    win: vaxis.Window,
    content: []const u8,
    row: usize,
) void {
    if (row >= win.height) return;

    const prefix = "Agent: ";
    const prefix_style: vaxis.Style = .{ .fg = Color.agent_prefix, .bold = true };
    const content_style: vaxis.Style = .{ .fg = Color.white };

    var segments = [_]vaxis.Cell.Segment{
        .{ .text = prefix, .style = prefix_style },
        .{ .text = content, .style = content_style },
    };

    _ = win.print(&segments, .{
        .row_offset = @intCast(row),
        .col_offset = 0,
    });
}

/// Render a tool call to a window
/// Format: "[status] name: command" or "[status] name" with optional stdout below
pub fn renderToolCall(
    win: vaxis.Window,
    name: []const u8,
    command: ?[]const u8,
    status: ToolStatus,
    stdout: ?[]const u8,
    row: usize,
) usize {
    if (row >= win.height) return row;

    var current_row = row;

    // Build status indicator
    var status_buf: [32]u8 = undefined;
    const status_text = std.fmt.bufPrint(&status_buf, "[{s}] ", .{status.label()}) catch "[?] ";

    const status_style: vaxis.Style = .{ .fg = status.color(), .bold = true };
    const name_style: vaxis.Style = .{ .fg = Color.white, .bold = true };
    const cmd_style: vaxis.Style = .{ .fg = Color.dim };

    // First line: [status] name: command
    if (command) |cmd| {
        var segments = [_]vaxis.Cell.Segment{
            .{ .text = status_text, .style = status_style },
            .{ .text = name, .style = name_style },
            .{ .text = ": ", .style = name_style },
            .{ .text = cmd, .style = cmd_style },
        };
        _ = win.print(&segments, .{
            .row_offset = @intCast(current_row),
            .col_offset = 0,
        });
    } else {
        var segments = [_]vaxis.Cell.Segment{
            .{ .text = status_text, .style = status_style },
            .{ .text = name, .style = name_style },
        };
        _ = win.print(&segments, .{
            .row_offset = @intCast(current_row),
            .col_offset = 0,
        });
    }
    current_row += 1;

    // Output line if present (for completed tools)
    if (stdout) |output| {
        if (current_row < win.height and output.len > 0) {
            const output_style: vaxis.Style = .{ .fg = Color.dim };
            var output_seg = [_]vaxis.Cell.Segment{
                .{ .text = "  ", .style = output_style },
                .{ .text = output, .style = output_style },
            };
            _ = win.print(&output_seg, .{
                .row_offset = @intCast(current_row),
                .col_offset = 0,
            });
            current_row += 1;
        }
    }

    return current_row;
}

/// Render a plan entry to a window
/// Format: "[x] content" or "[ ] content"
pub fn renderPlanEntry(
    win: vaxis.Window,
    entry: PlanEntry,
    row: usize,
) void {
    if (row >= win.height) return;

    const marker = entry.status.marker();
    const marker_style: vaxis.Style = .{ .fg = entry.status.color(), .bold = true };
    const content_style: vaxis.Style = if (entry.status == .completed)
        .{ .fg = Color.dim }
    else
        .{ .fg = Color.white };

    var segments = [_]vaxis.Cell.Segment{
        .{ .text = marker, .style = marker_style },
        .{ .text = " ", .style = content_style },
        .{ .text = entry.content, .style = content_style },
    };

    _ = win.print(&segments, .{
        .row_offset = @intCast(row),
        .col_offset = 0,
    });
}

// =============================================================================
// Snapshot-friendly render functions (with allocator for persistent strings)
// =============================================================================

/// Render a tool call with allocator for persistent strings (for snapshot testing)
pub fn renderToolCallAlloc(
    win: vaxis.Window,
    name: []const u8,
    command: ?[]const u8,
    status: ToolStatus,
    stdout: ?[]const u8,
    row: usize,
    alloc: std.mem.Allocator,
) usize {
    if (row >= win.height) return row;

    var current_row = row;

    // Build status indicator with allocator
    const status_text = std.fmt.allocPrint(alloc, "[{s}] ", .{status.label()}) catch "[?] ";

    const status_style: vaxis.Style = .{ .fg = status.color(), .bold = true };
    const name_style: vaxis.Style = .{ .fg = Color.white, .bold = true };
    const cmd_style: vaxis.Style = .{ .fg = Color.dim };

    // First line: [status] name: command
    if (command) |cmd| {
        var segments = [_]vaxis.Cell.Segment{
            .{ .text = status_text, .style = status_style },
            .{ .text = name, .style = name_style },
            .{ .text = ": ", .style = name_style },
            .{ .text = cmd, .style = cmd_style },
        };
        _ = win.print(&segments, .{
            .row_offset = @intCast(current_row),
            .col_offset = 0,
        });
    } else {
        var segments = [_]vaxis.Cell.Segment{
            .{ .text = status_text, .style = status_style },
            .{ .text = name, .style = name_style },
        };
        _ = win.print(&segments, .{
            .row_offset = @intCast(current_row),
            .col_offset = 0,
        });
    }
    current_row += 1;

    // Output line if present (for completed tools)
    if (stdout) |output| {
        if (current_row < win.height and output.len > 0) {
            const output_style: vaxis.Style = .{ .fg = Color.dim };
            var output_seg = [_]vaxis.Cell.Segment{
                .{ .text = "  ", .style = output_style },
                .{ .text = output, .style = output_style },
            };
            _ = win.print(&output_seg, .{
                .row_offset = @intCast(current_row),
                .col_offset = 0,
            });
            current_row += 1;
        }
    }

    return current_row;
}

/// Render a subagent block with allocator for persistent strings (for snapshot testing).
/// Renders the bordered block layout matching the production addSubagentBlock + render.zig.
///
/// Layout:
///   ┃
///   ┃  {icon} {AgentType} Task
///   ┃
///   ┃  {description} ({N} toolcalls)
///   ┃  └ {LastToolName}    (only if last_tool != null)
///   ┃
pub fn renderSubagentBlock(
    win: vaxis.Window,
    agent_type: []const u8,
    description: []const u8,
    tool_count: usize,
    last_tool: ?[]const u8,
    status: ToolStatus,
    row: usize,
    alloc: std.mem.Allocator,
) usize {
    if (row >= win.height) return row;

    var current_row = row;
    const border_style: vaxis.Style = .{ .fg = Color.dim };
    const bold_style: vaxis.Style = .{ .bold = true };
    const dim_style: vaxis.Style = .{ .fg = Color.dim };

    const icon: []const u8 = switch (status) {
        .pending => "○",
        .running => "⠹",
        .completed => "✓",
        .failed => "✗",
    };
    const icon_color: vaxis.Cell.Color = switch (status) {
        .pending => Color.dim,
        .running => Color.tool_pending, // yellow
        .completed => Color.tool_completed, // green
        .failed => Color.tool_failed, // red
    };

    // Top border
    if (current_row < win.height) {
        var seg = [_]vaxis.Cell.Segment{.{ .text = "┃", .style = border_style }};
        _ = win.print(&seg, .{ .row_offset = @intCast(current_row) });
        current_row += 1;
    }

    // Header: "┃  {icon} {AgentType} Task"
    if (current_row < win.height) {
        const type_task = std.fmt.allocPrint(alloc, "{s} Task", .{agent_type}) catch "Task";
        var seg = [_]vaxis.Cell.Segment{
            .{ .text = "┃", .style = border_style },
            .{ .text = "  ", .style = .{} },
            .{ .text = icon, .style = .{ .fg = icon_color } },
            .{ .text = " ", .style = .{} },
            .{ .text = type_task, .style = bold_style },
        };
        _ = win.print(&seg, .{ .row_offset = @intCast(current_row) });
        current_row += 1;
    }

    // Middle border
    if (current_row < win.height) {
        var seg = [_]vaxis.Cell.Segment{.{ .text = "┃", .style = border_style }};
        _ = win.print(&seg, .{ .row_offset = @intCast(current_row) });
        current_row += 1;
    }

    // Description: "┃  {description} ({N} toolcalls)"
    if (current_row < win.height) {
        const desc_text = std.fmt.allocPrint(alloc, "{s} ({d} toolcalls)", .{ description, tool_count }) catch description;
        var seg = [_]vaxis.Cell.Segment{
            .{ .text = "┃", .style = border_style },
            .{ .text = "  ", .style = .{} },
            .{ .text = desc_text, .style = dim_style },
        };
        _ = win.print(&seg, .{ .row_offset = @intCast(current_row) });
        current_row += 1;
    }

    // Last tool: "┃  └ {ToolName}" (only if present)
    if (last_tool) |tool_name| {
        if (current_row < win.height) {
            const tool_text = std.fmt.allocPrint(alloc, "└ {s}", .{tool_name}) catch tool_name;
            var seg = [_]vaxis.Cell.Segment{
                .{ .text = "┃", .style = border_style },
                .{ .text = "  ", .style = .{} },
                .{ .text = tool_text, .style = dim_style },
            };
            _ = win.print(&seg, .{ .row_offset = @intCast(current_row) });
            current_row += 1;
        }
    }

    // Bottom border
    if (current_row < win.height) {
        var seg = [_]vaxis.Cell.Segment{.{ .text = "┃", .style = border_style }};
        _ = win.print(&seg, .{ .row_offset = @intCast(current_row) });
        current_row += 1;
    }

    return current_row;
}

// =============================================================================
// Tests - Builder
// =============================================================================
const harness = @import("harness.zig");

test "builder creates user message" {
    const allocator = std.testing.allocator;

    var builder = TestAgentStateBuilder.init(allocator);
    _ = builder.addUserMessage("Hello!");
    const messages = builder.build();
    defer freeMessages(allocator, messages);

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(MessageRole.user, messages[0].role);
    try std.testing.expectEqualStrings("Hello!", messages[0].content);
}

test "builder creates agent message" {
    const allocator = std.testing.allocator;

    var builder = TestAgentStateBuilder.init(allocator);
    _ = builder.addAgentMessage("I can help with that.");
    const messages = builder.build();
    defer freeMessages(allocator, messages);

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(MessageRole.agent, messages[0].role);
    try std.testing.expectEqualStrings("I can help with that.", messages[0].content);
}

test "builder creates tool call" {
    const allocator = std.testing.allocator;

    var builder = TestAgentStateBuilder.init(allocator);
    _ = builder.addToolCall("Bash", "ls -la", .running, null);
    const messages = builder.build();
    defer freeMessages(allocator, messages);

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(MessageRole.tool, messages[0].role);
    try std.testing.expectEqualStrings("Bash", messages[0].tool_name.?);
    try std.testing.expectEqualStrings("ls -la", messages[0].tool_command.?);
    try std.testing.expectEqual(ToolStatus.running, messages[0].tool_status);
    try std.testing.expect(messages[0].tool_stdout == null);
}

test "builder creates plan snapshot" {
    const allocator = std.testing.allocator;

    const entries = [_]PlanEntry{
        createPlanEntry(.high, .completed, "First task"),
        createPlanEntry(.medium, .pending, "Second task"),
    };

    var builder = TestAgentStateBuilder.init(allocator);
    _ = builder.addPlanSnapshot(&entries);
    const messages = builder.build();
    defer freeMessages(allocator, messages);

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(MessageRole.plan_snapshot, messages[0].role);
    try std.testing.expect(messages[0].plan_entries != null);
    try std.testing.expectEqual(@as(usize, 2), messages[0].plan_entries.?.len);
    try std.testing.expectEqualStrings("First task", messages[0].plan_entries.?[0].content);
    try std.testing.expectEqual(PlanEntryStatus.completed, messages[0].plan_entries.?[0].status);
}

test "build returns messages slice" {
    const allocator = std.testing.allocator;

    var builder = TestAgentStateBuilder.init(allocator);
    _ = builder.addUserMessage("Question?");
    _ = builder.addAgentMessage("Answer.");
    _ = builder.addToolCall("Read", null, .completed, "file contents");
    const messages = builder.build();
    defer freeMessages(allocator, messages);

    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try std.testing.expectEqual(MessageRole.user, messages[0].role);
    try std.testing.expectEqual(MessageRole.agent, messages[1].role);
    try std.testing.expectEqual(MessageRole.tool, messages[2].role);
}

// =============================================================================
// Tests - Rendering
// =============================================================================

test "renderUserMessage writes prefix and content" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    renderUserMessage(win, "Hello world", 0);

    // Verify prefix "You: " is rendered
    const cell0 = ctx.screen.readCell(0, 0);
    try std.testing.expect(cell0 != null);
    try std.testing.expectEqualStrings("Y", cell0.?.char.grapheme);

    // Verify content starts after prefix
    const cell5 = ctx.screen.readCell(5, 0);
    try std.testing.expect(cell5 != null);
    try std.testing.expectEqualStrings("H", cell5.?.char.grapheme);
}

test "renderAgentMessage writes role header and content" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    renderAgentMessage(win, "I can help", 0);

    // Verify prefix "Agent: " is rendered
    const cell0 = ctx.screen.readCell(0, 0);
    try std.testing.expect(cell0 != null);
    try std.testing.expectEqualStrings("A", cell0.?.char.grapheme);

    // Verify content starts after prefix (7 chars: "Agent: ")
    const cell7 = ctx.screen.readCell(7, 0);
    try std.testing.expect(cell7 != null);
    try std.testing.expectEqualStrings("I", cell7.?.char.grapheme);
}

test "renderToolCall renders pending status" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    _ = renderToolCall(win, "Bash", "ls", .pending, null, 0);

    // Verify status indicator is rendered
    const cell0 = ctx.screen.readCell(0, 0);
    try std.testing.expect(cell0 != null);
    try std.testing.expectEqualStrings("[", cell0.?.char.grapheme);

    // Verify "Pending" text
    const cell1 = ctx.screen.readCell(1, 0);
    try std.testing.expect(cell1 != null);
    try std.testing.expectEqualStrings("P", cell1.?.char.grapheme);
}

test "renderToolCall renders completed status with output" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 5);
    defer ctx.deinit();

    const win = ctx.window();
    const next_row = renderToolCall(win, "Bash", "echo hi", .completed, "hi", 0);

    // Verify we advanced to row 2 (tool header + output)
    try std.testing.expectEqual(@as(usize, 2), next_row);

    // Verify "Done" status
    const cell1 = ctx.screen.readCell(1, 0);
    try std.testing.expect(cell1 != null);
    try std.testing.expectEqualStrings("D", cell1.?.char.grapheme);

    // Verify output on second row (starts with "  " indent)
    const output_cell = ctx.screen.readCell(2, 1);
    try std.testing.expect(output_cell != null);
    try std.testing.expectEqualStrings("h", output_cell.?.char.grapheme);
}

test "renderPlanEntry renders completed entry" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const entry = createPlanEntry(.high, .completed, "Done task");
    renderPlanEntry(win, entry, 0);

    // Verify "[x]" marker
    const cell0 = ctx.screen.readCell(0, 0);
    try std.testing.expect(cell0 != null);
    try std.testing.expectEqualStrings("[", cell0.?.char.grapheme);

    const cell1 = ctx.screen.readCell(1, 0);
    try std.testing.expect(cell1 != null);
    try std.testing.expectEqualStrings("x", cell1.?.char.grapheme);
}

test "renderPlanEntry renders pending entry" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 60, 3);
    defer ctx.deinit();

    const win = ctx.window();
    const entry = createPlanEntry(.medium, .pending, "Todo task");
    renderPlanEntry(win, entry, 0);

    // Verify "[ ]" marker
    const cell0 = ctx.screen.readCell(0, 0);
    try std.testing.expect(cell0 != null);
    try std.testing.expectEqualStrings("[", cell0.?.char.grapheme);

    const cell1 = ctx.screen.readCell(1, 0);
    try std.testing.expect(cell1 != null);
    try std.testing.expectEqualStrings(" ", cell1.?.char.grapheme);

    // Verify content starts after marker and space
    const cell4 = ctx.screen.readCell(4, 0);
    try std.testing.expect(cell4 != null);
    try std.testing.expectEqualStrings("T", cell4.?.char.grapheme);
}
