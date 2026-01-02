//! Agent Command Palette
//!
//! Provides a fuzzy-searchable command menu for agent mode, triggered by ':'.
//! Supports tab management, plan toggle, and other agent-specific commands.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Actions that can be executed from the command palette
pub const AgentCommandAction = union(enum) {
    new_tab: void,
    close_tab: void,
    next_tab: void,
    prev_tab: void,
    rename_tab: void,
    goto_tab: u8,
    toggle_plan: void,
};

/// A command in the palette
pub const AgentCommand = struct {
    name: []const u8,
    aliases: []const []const u8,
    description: []const u8,
    action: AgentCommandAction,
};

/// Static list of available commands
pub const COMMANDS = [_]AgentCommand{
    .{
        .name = "New Tab",
        .aliases = &[_][]const u8{ ":tabe", ":tabnew" },
        .description = "Create a new tab",
        .action = .new_tab,
    },
    .{
        .name = "Close Tab",
        .aliases = &[_][]const u8{ ":tabc", ":tabclose" },
        .description = "Close current tab",
        .action = .close_tab,
    },
    .{
        .name = "Next Tab",
        .aliases = &[_][]const u8{ ":tabn", ":tabnext" },
        .description = "Switch to next tab",
        .action = .next_tab,
    },
    .{
        .name = "Previous Tab",
        .aliases = &[_][]const u8{ ":tabp", ":tabprev" },
        .description = "Switch to previous tab",
        .action = .prev_tab,
    },
    .{
        .name = "Rename Tab",
        .aliases = &[_][]const u8{ ":tabr", ":tabrename" },
        .description = "Rename current tab",
        .action = .rename_tab,
    },
    .{
        .name = "Tab 1",
        .aliases = &[_][]const u8{":tab1"},
        .description = "Go to tab 1",
        .action = .{ .goto_tab = 1 },
    },
    .{
        .name = "Tab 2",
        .aliases = &[_][]const u8{":tab2"},
        .description = "Go to tab 2",
        .action = .{ .goto_tab = 2 },
    },
    .{
        .name = "Tab 3",
        .aliases = &[_][]const u8{":tab3"},
        .description = "Go to tab 3",
        .action = .{ .goto_tab = 3 },
    },
    .{
        .name = "Tab 4",
        .aliases = &[_][]const u8{":tab4"},
        .description = "Go to tab 4",
        .action = .{ .goto_tab = 4 },
    },
    .{
        .name = "Tab 5",
        .aliases = &[_][]const u8{":tab5"},
        .description = "Go to tab 5",
        .action = .{ .goto_tab = 5 },
    },
    .{
        .name = "Tab 6",
        .aliases = &[_][]const u8{":tab6"},
        .description = "Go to tab 6",
        .action = .{ .goto_tab = 6 },
    },
    .{
        .name = "Tab 7",
        .aliases = &[_][]const u8{":tab7"},
        .description = "Go to tab 7",
        .action = .{ .goto_tab = 7 },
    },
    .{
        .name = "Tab 8",
        .aliases = &[_][]const u8{":tab8"},
        .description = "Go to tab 8",
        .action = .{ .goto_tab = 8 },
    },
    .{
        .name = "Tab 9",
        .aliases = &[_][]const u8{":tab9"},
        .description = "Go to tab 9",
        .action = .{ .goto_tab = 9 },
    },
    .{
        .name = "Toggle Plan",
        .aliases = &[_][]const u8{ ":plan", ":todo" },
        .description = "Show/hide plan view",
        .action = .toggle_plan,
    },
};

/// Mode for the command palette
pub const PaletteMode = enum {
    search,
    rename_input,
};

/// State for the agent command palette
pub const AgentCommandPaletteState = struct {
    allocator: Allocator,
    visible: bool,
    mode: PaletteMode,

    // Search state
    query_buffer: [256]u8,
    query_len: usize,
    filtered_indices: std.ArrayList(usize),
    selected_idx: usize,
    scroll_offset: usize,

    // Rename input state
    rename_buffer: [64]u8,
    rename_len: usize,

    const max_visible_items = 10;

    pub fn init(allocator: Allocator) AgentCommandPaletteState {
        return .{
            .allocator = allocator,
            .visible = false,
            .mode = .search,
            .query_buffer = undefined,
            .query_len = 0,
            .filtered_indices = .{},
            .selected_idx = 0,
            .scroll_offset = 0,
            .rename_buffer = undefined,
            .rename_len = 0,
        };
    }

    pub fn deinit(self: *AgentCommandPaletteState) void {
        self.filtered_indices.deinit(self.allocator);
    }

    /// Open the command palette
    pub fn open(self: *AgentCommandPaletteState) void {
        self.visible = true;
        self.mode = .search;
        self.query_len = 0;
        self.selected_idx = 0;
        self.scroll_offset = 0;
        self.rename_len = 0;
        self.filterCommands();
    }

    /// Close the command palette
    pub fn close(self: *AgentCommandPaletteState) void {
        self.visible = false;
        self.mode = .search;
        self.query_len = 0;
        self.rename_len = 0;
    }

    /// Switch to rename input mode
    pub fn startRenameInput(self: *AgentCommandPaletteState) void {
        self.mode = .rename_input;
        self.rename_len = 0;
    }

    /// Get the rename text
    pub fn getRenameText(self: *const AgentCommandPaletteState) []const u8 {
        return self.rename_buffer[0..self.rename_len];
    }

    /// Append character to query
    pub fn appendQueryChar(self: *AgentCommandPaletteState, char: u8) void {
        if (self.query_len < self.query_buffer.len) {
            self.query_buffer[self.query_len] = char;
            self.query_len += 1;
            self.filterCommands();
        }
    }

    /// Delete last character from query
    pub fn deleteQueryChar(self: *AgentCommandPaletteState) void {
        if (self.query_len > 0) {
            self.query_len -= 1;
            self.filterCommands();
        }
    }

    /// Append character to rename buffer
    pub fn appendRenameChar(self: *AgentCommandPaletteState, char: u8) void {
        if (self.rename_len < self.rename_buffer.len) {
            self.rename_buffer[self.rename_len] = char;
            self.rename_len += 1;
        }
    }

    /// Delete last character from rename buffer
    pub fn deleteRenameChar(self: *AgentCommandPaletteState) void {
        if (self.rename_len > 0) {
            self.rename_len -= 1;
        }
    }

    /// Get current query text
    pub fn getQuery(self: *const AgentCommandPaletteState) []const u8 {
        return self.query_buffer[0..self.query_len];
    }

    /// Filter commands based on current query
    pub fn filterCommands(self: *AgentCommandPaletteState) void {
        self.filtered_indices.clearRetainingCapacity();
        const query = self.getQuery();

        for (COMMANDS, 0..) |cmd, idx| {
            if (self.matchesCommand(cmd, query)) {
                self.filtered_indices.append(self.allocator, idx) catch continue;
            }
        }

        // Clamp selection
        if (self.filtered_indices.items.len == 0) {
            self.selected_idx = 0;
        } else if (self.selected_idx >= self.filtered_indices.items.len) {
            self.selected_idx = self.filtered_indices.items.len - 1;
        }

        self.adjustScrollOffset();
    }

    /// Check if a command matches the query
    fn matchesCommand(self: *const AgentCommandPaletteState, cmd: AgentCommand, query: []const u8) bool {
        _ = self;
        if (query.len == 0) return true;

        // Check name
        if (containsIgnoreCase(cmd.name, query)) return true;

        // Check aliases
        for (cmd.aliases) |alias| {
            if (containsIgnoreCase(alias, query)) return true;
        }

        // Check description
        if (containsIgnoreCase(cmd.description, query)) return true;

        return false;
    }

    /// Move selection up
    pub fn moveUp(self: *AgentCommandPaletteState) void {
        if (self.filtered_indices.items.len == 0) return;
        self.selected_idx = if (self.selected_idx == 0)
            self.filtered_indices.items.len - 1
        else
            self.selected_idx - 1;
        self.adjustScrollOffset();
    }

    /// Move selection down
    pub fn moveDown(self: *AgentCommandPaletteState) void {
        if (self.filtered_indices.items.len == 0) return;
        self.selected_idx = (self.selected_idx + 1) % self.filtered_indices.items.len;
        self.adjustScrollOffset();
    }

    fn adjustScrollOffset(self: *AgentCommandPaletteState) void {
        if (self.filtered_indices.items.len == 0) {
            self.scroll_offset = 0;
            return;
        }

        // Scroll down if selection is below visible area
        if (self.selected_idx >= self.scroll_offset + max_visible_items) {
            self.scroll_offset = self.selected_idx - max_visible_items + 1;
        }

        // Scroll up if selection is above visible area
        if (self.selected_idx < self.scroll_offset) {
            self.scroll_offset = self.selected_idx;
        }
    }

    /// Get the currently selected command
    pub fn getSelectedCommand(self: *const AgentCommandPaletteState) ?*const AgentCommand {
        if (self.filtered_indices.items.len == 0) return null;
        const cmd_idx = self.filtered_indices.items[self.selected_idx];
        return &COMMANDS[cmd_idx];
    }

    /// Get visible range of commands for rendering
    pub fn getVisibleRange(self: *const AgentCommandPaletteState) struct { start: usize, end: usize } {
        const start = self.scroll_offset;
        const end = @min(start + max_visible_items, self.filtered_indices.items.len);
        return .{ .start = start, .end = end };
    }

    /// Get command at filtered index
    pub fn getCommandAt(self: *const AgentCommandPaletteState, filtered_idx: usize) ?*const AgentCommand {
        if (filtered_idx >= self.filtered_indices.items.len) return null;
        const cmd_idx = self.filtered_indices.items[filtered_idx];
        return &COMMANDS[cmd_idx];
    }
};

/// Case-insensitive substring search
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}
