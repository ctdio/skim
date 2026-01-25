const std = @import("std");
const Allocator = std.mem.Allocator;

/// Queued shell command output to be sent with next prompt
pub const QueuedShellOutput = struct {
    content: []const u8, // Owned

    pub fn deinit(self: *QueuedShellOutput, allocator: Allocator) void {
        allocator.free(self.content);
    }
};

/// Running shell command state for streaming output
pub const RunningShellCommand = struct {
    child: std.process.Child,
    command: []const u8, // Owned
    tool_id: []const u8, // Owned
    stdout_buf: std.ArrayList(u8),
    stderr_buf: std.ArrayList(u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator, command: []const u8, tool_id: []const u8) !RunningShellCommand {
        return .{
            .child = undefined, // Set by caller after spawn
            .command = try allocator.dupe(u8, command),
            .tool_id = try allocator.dupe(u8, tool_id),
            .stdout_buf = .{},
            .stderr_buf = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RunningShellCommand) void {
        self.allocator.free(self.command);
        self.allocator.free(self.tool_id);
        self.stdout_buf.deinit(self.allocator);
        self.stderr_buf.deinit(self.allocator);
        // Kill the process if still running
        _ = self.child.kill() catch {};
    }

    /// Get the last N lines of stdout for display, processing carriage returns
    pub fn getLastLines(self: *RunningShellCommand, max_lines: usize) []const u8 {
        // Process carriage returns to get the "visual" output
        self.processCarriageReturns();

        const content = self.stdout_buf.items;
        if (content.len == 0) return "";

        // Find the start of the last N lines
        var line_count: usize = 0;
        var pos: usize = content.len;

        // Skip trailing newline if present
        if (pos > 0 and content[pos - 1] == '\n') {
            pos -= 1;
        }

        while (pos > 0 and line_count < max_lines) {
            pos -= 1;
            if (content[pos] == '\n') {
                line_count += 1;
            }
        }

        // If we found enough newlines, skip past the last one we found
        if (pos > 0 and content[pos] == '\n') {
            pos += 1;
        }

        return content[pos..];
    }

    /// Process carriage returns in the buffer to simulate terminal behavior
    /// \r moves cursor to start of line, subsequent chars overwrite
    fn processCarriageReturns(self: *RunningShellCommand) void {
        const content = self.stdout_buf.items;
        if (content.len == 0) return;

        // Check if there are any carriage returns to process
        if (std.mem.indexOf(u8, content, "\r") == null) return;

        // Process the buffer, handling \r by going back to line start
        var result = std.ArrayList(u8).initCapacity(self.allocator, content.len) catch return;
        defer {
            // Swap the processed result back
            self.stdout_buf.deinit(self.allocator);
            self.stdout_buf = result;
        }

        var line_start: usize = 0;
        var i: usize = 0;
        while (i < content.len) : (i += 1) {
            const c = content[i];
            if (c == '\r') {
                // Carriage return - next chars will overwrite from line_start
                // But first, if there's a \n right after, it's just a Windows line ending
                if (i + 1 < content.len and content[i + 1] == '\n') {
                    result.append(self.allocator, '\n') catch return;
                    i += 1;
                    line_start = result.items.len;
                } else {
                    // Pure \r - go back to line start, truncate to there
                    result.shrinkRetainingCapacity(line_start);
                }
            } else if (c == '\n') {
                result.append(self.allocator, '\n') catch return;
                line_start = result.items.len;
            } else {
                result.append(self.allocator, c) catch return;
            }
        }
    }
};

/// State for shell command mode and queued outputs
pub const ShellState = struct {
    allocator: Allocator,
    mode: bool,
    queued_outputs: std.ArrayList(QueuedShellOutput),
    running_cmd: ?RunningShellCommand,
    cmd_counter: u32,

    pub fn init(allocator: Allocator) ShellState {
        return .{
            .allocator = allocator,
            .mode = false,
            .queued_outputs = .{},
            .running_cmd = null,
            .cmd_counter = 0,
        };
    }

    pub fn deinit(self: *ShellState) void {
        for (self.queued_outputs.items) |*output| {
            output.deinit(self.allocator);
        }
        self.queued_outputs.deinit(self.allocator);
        if (self.running_cmd) |*cmd| {
            cmd.deinit();
        }
    }

    /// Toggle shell command mode on/off
    pub fn toggleMode(self: *ShellState) void {
        self.mode = !self.mode;
    }

    /// Check if in shell command mode
    pub fn isActive(self: *const ShellState) bool {
        return self.mode;
    }

    /// Clear shell mode (e.g., after submitting a command)
    pub fn clearMode(self: *ShellState) void {
        self.mode = false;
    }

    /// Queue a shell command output to be sent with next prompt
    pub fn queueOutput(self: *ShellState, content: []const u8) !void {
        const owned_content = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(owned_content);
        try self.queued_outputs.append(self.allocator, .{
            .content = owned_content,
        });
    }

    /// Check if there are queued shell outputs
    pub fn hasQueuedOutputs(self: *const ShellState) bool {
        return self.queued_outputs.items.len > 0;
    }

    /// Take all queued shell outputs (caller owns returned slice, must free)
    /// Returns null on allocation failure or if empty
    pub fn takeQueuedOutputs(self: *ShellState) ?[]QueuedShellOutput {
        if (self.queued_outputs.items.len == 0) return null;
        return self.queued_outputs.toOwnedSlice(self.allocator) catch null;
    }

    /// Clear all queued shell outputs
    pub fn clearQueuedOutputs(self: *ShellState) void {
        for (self.queued_outputs.items) |*output| {
            output.deinit(self.allocator);
        }
        self.queued_outputs.clearRetainingCapacity();
    }

    /// Check if a shell command is currently running
    pub fn hasRunningCommand(self: *const ShellState) bool {
        return self.running_cmd != null;
    }

    /// Get next unique shell command tool ID
    pub fn nextCmdId(self: *ShellState, buf: []u8) []const u8 {
        self.cmd_counter +%= 1;
        return std.fmt.bufPrint(buf, "shell_{d}", .{self.cmd_counter}) catch "shell_cmd";
    }

    /// Get the last N lines of running command output for display
    pub fn getRunningOutput(self: *ShellState, max_lines: usize) ?[]const u8 {
        if (self.running_cmd) |*cmd| {
            return cmd.getLastLines(max_lines);
        }
        return null;
    }
};

test "ShellState basic operations" {
    const allocator = std.testing.allocator;

    var state = ShellState.init(allocator);
    defer state.deinit();

    try std.testing.expect(!state.isActive());

    state.toggleMode();
    try std.testing.expect(state.isActive());

    state.clearMode();
    try std.testing.expect(!state.isActive());
}

test "ShellState queued outputs" {
    const allocator = std.testing.allocator;

    var state = ShellState.init(allocator);
    defer state.deinit();

    try std.testing.expect(!state.hasQueuedOutputs());

    try state.queueOutput("test output");
    try std.testing.expect(state.hasQueuedOutputs());

    const outputs = state.takeQueuedOutputs();
    try std.testing.expect(outputs != null);
    try std.testing.expectEqual(@as(usize, 1), outputs.?.len);
    try std.testing.expectEqualStrings("test output", outputs.?[0].content);

    // Clean up taken outputs
    for (outputs.?) |*o| {
        allocator.free(o.content);
    }
    allocator.free(outputs.?);

    try std.testing.expect(!state.hasQueuedOutputs());
}

test "ShellState cmd counter" {
    const allocator = std.testing.allocator;

    var state = ShellState.init(allocator);
    defer state.deinit();

    var buf: [32]u8 = undefined;
    const id1 = state.nextCmdId(&buf);
    try std.testing.expectEqualStrings("shell_1", id1);

    const id2 = state.nextCmdId(&buf);
    try std.testing.expectEqualStrings("shell_2", id2);
}
