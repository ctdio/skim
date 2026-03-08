const std = @import("std");

/// Maximum number of slash commands visible in menu at once
pub const MAX_VISIBLE: usize = 12;

/// Local slash command definition (handled by skim, not sent to agent)
pub const LocalCommand = struct {
    name: []const u8,
    description: []const u8,
};

/// Local slash commands that skim handles (not sent to agent)
pub const local_commands = [_]LocalCommand{
    .{ .name = "clear", .description = "Clear session and start fresh" },
    .{ .name = "fast", .description = "Toggle Codex fast mode" },
    .{ .name = "model", .description = "Switch AI model" },
    .{ .name = "thinking", .description = "Set Codex thinking effort" },
    .{ .name = "permissions", .description = "Switch Codex permission mode" },
    .{ .name = "resume", .description = "Resume previous session" },
};

/// Check if a command is a local command (handled by skim)
pub fn isLocalCommand(name: []const u8) bool {
    for (local_commands) |cmd| {
        if (std.mem.eql(u8, cmd.name, name)) {
            return true;
        }
    }
    return false;
}

/// State for the slash command menu UI
pub const SlashMenuState = struct {
    visible: bool,
    selection: usize,
    scroll_offset: usize,

    pub fn init() SlashMenuState {
        return .{
            .visible = false,
            .selection = 0,
            .scroll_offset = 0,
        };
    }

    /// Show menu and reset selection
    pub fn show(self: *SlashMenuState) void {
        self.visible = true;
        self.selection = 0;
        self.scroll_offset = 0;
    }

    /// Hide menu and reset state
    pub fn hide(self: *SlashMenuState) void {
        self.visible = false;
        self.selection = 0;
        self.scroll_offset = 0;
    }

    /// Move selection up
    pub fn moveUp(self: *SlashMenuState) void {
        if (self.selection > 0) {
            self.selection -= 1;
            if (self.selection < self.scroll_offset) {
                self.scroll_offset = self.selection;
            }
        }
    }

    /// Move selection down
    pub fn moveDown(self: *SlashMenuState, max_items: usize, visible_count: usize) void {
        if (max_items > 0 and self.selection < max_items - 1) {
            self.selection += 1;
            if (visible_count > 0 and self.selection >= self.scroll_offset + visible_count) {
                self.scroll_offset = self.selection - visible_count + 1;
            }
        }
    }

    /// Get clamped selection index
    pub fn getClampedSelection(self: *const SlashMenuState, count: usize) usize {
        if (count == 0) return 0;
        return @min(self.selection, count - 1);
    }
};

test "SlashMenuState basic operations" {
    var state = SlashMenuState.init();

    try std.testing.expect(!state.visible);

    state.show();
    try std.testing.expect(state.visible);
    try std.testing.expectEqual(@as(usize, 0), state.selection);

    state.moveDown(10, 5);
    try std.testing.expectEqual(@as(usize, 1), state.selection);

    state.moveUp();
    try std.testing.expectEqual(@as(usize, 0), state.selection);

    state.hide();
    try std.testing.expect(!state.visible);
}

test "isLocalCommand" {
    try std.testing.expect(isLocalCommand("clear"));
    try std.testing.expect(isLocalCommand("fast"));
    try std.testing.expect(isLocalCommand("model"));
    try std.testing.expect(isLocalCommand("thinking"));
    try std.testing.expect(isLocalCommand("permissions"));
    try std.testing.expect(isLocalCommand("resume"));
    try std.testing.expect(!isLocalCommand("status"));
    try std.testing.expect(!isLocalCommand("review"));
}
