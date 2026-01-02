//! Tab Manager for Multi-Agent Support
//!
//! Manages multiple agent tabs, each with its own AgentState and AcpManager.
//! Enables concurrent work with multiple AI agents in a tabbed interface.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AgentState = @import("state.zig").AgentState;
const AcpManager = @import("../acp/manager.zig").AcpManager;

/// Maximum number of tabs allowed
pub const MAX_TABS: usize = 10;

/// Default name for new tabs
const DEFAULT_TAB_NAME = "New Tab";

/// Maximum length for auto-generated tab names
const MAX_TAB_NAME_LEN: usize = 24;

/// A single agent tab containing its own state and ACP connection
pub const AgentTab = struct {
    id: u32,
    name: []const u8, // Owned
    agent_state: AgentState,
    acp_manager: ?*AcpManager, // Owned, nullable until agent spawned
    allocator: Allocator,
    auto_named: bool, // True if name was auto-generated from first prompt

    /// Initialize a new tab with the given name
    pub fn init(allocator: Allocator, id: u32, name: []const u8, panel_side: AgentState.PanelSide) !AgentTab {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);

        return .{
            .id = id,
            .name = owned_name,
            .agent_state = AgentState.init(allocator, panel_side),
            .acp_manager = null,
            .allocator = allocator,
            .auto_named = false,
        };
    }

    /// Clean up tab resources
    pub fn deinit(self: *AgentTab) void {
        self.allocator.free(self.name);
        self.agent_state.deinit();
        if (self.acp_manager) |mgr| {
            mgr.deinit();
            self.allocator.destroy(mgr);
        }
    }

    /// Create and attach an ACP manager for this tab
    pub fn createAcpManager(self: *AgentTab) !*AcpManager {
        if (self.acp_manager != null) {
            return self.acp_manager.?;
        }

        const mgr = try self.allocator.create(AcpManager);
        mgr.* = AcpManager.init(self.allocator);
        self.acp_manager = mgr;
        return mgr;
    }

    /// Set the tab name (frees old name)
    pub fn setName(self: *AgentTab, new_name: []const u8) !void {
        const owned = try self.allocator.dupe(u8, new_name);
        self.allocator.free(self.name);
        self.name = owned;
    }

    /// Auto-name the tab from the first user prompt (if still using default name)
    /// Truncates to MAX_TAB_NAME_LEN and adds "..." if needed
    pub fn autoNameFromPrompt(self: *AgentTab, prompt: []const u8) !void {
        // Only auto-name if still using default name ("Session N") and not already auto-named
        const is_default_name = std.mem.eql(u8, self.name, DEFAULT_TAB_NAME) or
            std.mem.startsWith(u8, self.name, "Session ");
        if (self.auto_named or !is_default_name) {
            return;
        }

        // Skip empty prompts
        const trimmed = std.mem.trim(u8, prompt, &std.ascii.whitespace);
        if (trimmed.len == 0) return;

        // Take first line only
        const first_line_end = std.mem.indexOf(u8, trimmed, "\n") orelse trimmed.len;
        const first_line = trimmed[0..first_line_end];

        // Truncate if needed
        const display_name = if (first_line.len > MAX_TAB_NAME_LEN) blk: {
            // Find a good break point (word boundary)
            var end = MAX_TAB_NAME_LEN - 3; // Leave room for "..."
            while (end > 10 and first_line[end] != ' ') {
                end -= 1;
            }
            if (end <= 10) end = MAX_TAB_NAME_LEN - 3; // No good break, just truncate

            const truncated = try self.allocator.alloc(u8, end + 3);
            @memcpy(truncated[0..end], first_line[0..end]);
            @memcpy(truncated[end..][0..3], "...");
            break :blk truncated;
        } else blk: {
            break :blk try self.allocator.dupe(u8, first_line);
        };

        self.allocator.free(self.name);
        self.name = display_name;
        self.auto_named = true;
    }

    /// Check if this tab's agent is currently thinking
    pub fn isThinking(self: *const AgentTab) bool {
        if (self.acp_manager) |mgr| {
            return mgr.isPrompting();
        }
        return false;
    }

    /// Check if this tab has a pending permission request
    pub fn hasPendingPermission(self: *const AgentTab) bool {
        if (self.acp_manager) |mgr| {
            return mgr.getPendingPermission() != null;
        }
        return false;
    }
};

/// Manages a collection of agent tabs
pub const TabManager = struct {
    allocator: Allocator,
    tabs: std.ArrayList(AgentTab),
    active_idx: usize,
    next_id: u32,

    // Panel-level state (shared across all tabs)
    panel_visible: bool,
    panel_side: AgentState.PanelSide,
    full_screen: bool,

    /// Initialize the tab manager with one default tab
    pub fn init(allocator: Allocator, panel_side: AgentState.PanelSide) TabManager {
        return .{
            .allocator = allocator,
            .tabs = .{},
            .active_idx = 0,
            .next_id = 1,
            .panel_visible = false,
            .panel_side = panel_side,
            .full_screen = true,
        };
    }

    /// Clean up all tabs
    pub fn deinit(self: *TabManager) void {
        for (self.tabs.items) |*tab| {
            tab.deinit();
        }
        self.tabs.deinit(self.allocator);
    }

    /// Ensure at least one tab exists, creating a default if needed
    pub fn ensureTab(self: *TabManager) !*AgentTab {
        if (self.tabs.items.len == 0) {
            return try self.createTab(DEFAULT_TAB_NAME);
        }
        return self.activeTab().?;
    }

    /// Create a new tab with the given name
    /// If name is DEFAULT_TAB_NAME, generates "Session N" instead
    pub fn createTab(self: *TabManager, name: []const u8) !*AgentTab {
        if (self.tabs.items.len >= MAX_TABS) {
            return error.TooManyTabs;
        }

        const id = self.next_id;
        self.next_id += 1;

        // Generate "Session N" for default tabs
        var name_buf: [32]u8 = undefined;
        const actual_name = if (std.mem.eql(u8, name, DEFAULT_TAB_NAME))
            std.fmt.bufPrint(&name_buf, "Session {d}", .{id}) catch name
        else
            name;

        const tab = try AgentTab.init(self.allocator, id, actual_name, self.panel_side);
        try self.tabs.append(self.allocator, tab);

        // Switch to the new tab
        self.active_idx = self.tabs.items.len - 1;

        return &self.tabs.items[self.active_idx];
    }

    /// Close the tab at the given index
    /// Returns false if this is the last tab (cannot close)
    pub fn closeTab(self: *TabManager, idx: usize) bool {
        if (self.tabs.items.len <= 1) {
            return false; // Cannot close last tab
        }
        if (idx >= self.tabs.items.len) {
            return false;
        }

        var tab = self.tabs.orderedRemove(idx);
        tab.deinit();

        // Adjust active index if needed
        if (self.active_idx >= self.tabs.items.len) {
            self.active_idx = self.tabs.items.len - 1;
        } else if (self.active_idx > idx) {
            self.active_idx -= 1;
        }

        return true;
    }

    /// Close the currently active tab
    pub fn closeActiveTab(self: *TabManager) bool {
        return self.closeTab(self.active_idx);
    }

    /// Get the currently active tab
    pub fn activeTab(self: *TabManager) ?*AgentTab {
        if (self.tabs.items.len == 0) {
            return null;
        }
        return &self.tabs.items[self.active_idx];
    }

    /// Get the currently active tab (const version)
    pub fn activeTabConst(self: *const TabManager) ?*const AgentTab {
        if (self.tabs.items.len == 0) {
            return null;
        }
        return &self.tabs.items[self.active_idx];
    }

    /// Move to the next tab (wraps around)
    pub fn nextTab(self: *TabManager) void {
        if (self.tabs.items.len == 0) return;
        self.active_idx = (self.active_idx + 1) % self.tabs.items.len;
    }

    /// Move to the previous tab (wraps around)
    pub fn prevTab(self: *TabManager) void {
        if (self.tabs.items.len == 0) return;
        if (self.active_idx == 0) {
            self.active_idx = self.tabs.items.len - 1;
        } else {
            self.active_idx -= 1;
        }
    }

    /// Go to a specific tab by index (0-based)
    pub fn goToTab(self: *TabManager, idx: usize) void {
        if (idx < self.tabs.items.len) {
            self.active_idx = idx;
        }
    }

    /// Go to a specific tab by number (1-based, vim-style)
    pub fn goToTabNumber(self: *TabManager, num: usize) void {
        if (num > 0 and num <= self.tabs.items.len) {
            self.active_idx = num - 1;
        }
    }

    /// Get the number of tabs
    pub fn tabCount(self: *const TabManager) usize {
        return self.tabs.items.len;
    }

    /// Toggle panel visibility
    pub fn toggleVisible(self: *TabManager) void {
        self.panel_visible = !self.panel_visible;
    }

    /// Toggle full-screen mode
    pub fn toggleFullScreen(self: *TabManager) void {
        self.full_screen = !self.full_screen;
    }

    /// Check if any tab has a pending permission
    pub fn hasAnyPendingPermission(self: *const TabManager) bool {
        for (self.tabs.items) |*tab| {
            if (tab.hasPendingPermission()) {
                return true;
            }
        }
        return false;
    }

    /// Check if any tab's agent is thinking
    pub fn hasAnyThinking(self: *const TabManager) bool {
        for (self.tabs.items) |*tab| {
            if (tab.isThinking()) {
                return true;
            }
        }
        return false;
    }

    /// Poll all tabs' ACP managers for updates
    /// Returns true if any tab had activity
    pub fn pollAllTabs(self: *TabManager) bool {
        var had_activity = false;
        for (self.tabs.items) |*tab| {
            if (tab.acp_manager) |mgr| {
                const messages = mgr.poll() catch continue;
                if (messages.len > 0) {
                    had_activity = true;
                }
            }
        }
        return had_activity;
    }

    /// Get tab by index
    pub fn getTab(self: *TabManager, idx: usize) ?*AgentTab {
        if (idx >= self.tabs.items.len) {
            return null;
        }
        return &self.tabs.items[idx];
    }

    /// Find tab index by ID
    pub fn findTabById(self: *const TabManager, id: u32) ?usize {
        for (self.tabs.items, 0..) |tab, idx| {
            if (tab.id == id) {
                return idx;
            }
        }
        return null;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "TabManager: create and close tabs" {
    const allocator = std.testing.allocator;
    var mgr = TabManager.init(allocator, .right);
    defer mgr.deinit();

    // Start with no tabs
    try std.testing.expectEqual(@as(usize, 0), mgr.tabCount());

    // Create first tab
    const tab1 = try mgr.createTab("Tab 1");
    try std.testing.expectEqual(@as(usize, 1), mgr.tabCount());
    try std.testing.expectEqual(@as(u32, 1), tab1.id);
    try std.testing.expectEqualStrings("Tab 1", tab1.name);

    // Create second tab
    const tab2 = try mgr.createTab("Tab 2");
    try std.testing.expectEqual(@as(usize, 2), mgr.tabCount());
    try std.testing.expectEqual(@as(u32, 2), tab2.id);

    // Active tab should be the second one
    try std.testing.expectEqual(@as(usize, 1), mgr.active_idx);

    // Cannot close last tab if only one exists
    _ = mgr.closeTab(0); // Close first tab
    try std.testing.expectEqual(@as(usize, 1), mgr.tabCount());
    try std.testing.expect(!mgr.closeActiveTab()); // Cannot close last
    try std.testing.expectEqual(@as(usize, 1), mgr.tabCount());
}

test "TabManager: tab navigation" {
    const allocator = std.testing.allocator;
    var mgr = TabManager.init(allocator, .right);
    defer mgr.deinit();

    // Create 3 tabs
    _ = try mgr.createTab("Tab 1");
    _ = try mgr.createTab("Tab 2");
    _ = try mgr.createTab("Tab 3");

    // Active should be last created (idx 2)
    try std.testing.expectEqual(@as(usize, 2), mgr.active_idx);

    // Next tab wraps
    mgr.nextTab();
    try std.testing.expectEqual(@as(usize, 0), mgr.active_idx);

    // Previous tab wraps
    mgr.prevTab();
    try std.testing.expectEqual(@as(usize, 2), mgr.active_idx);

    // Go to specific tab
    mgr.goToTab(1);
    try std.testing.expectEqual(@as(usize, 1), mgr.active_idx);

    // Go to tab by number (1-based)
    mgr.goToTabNumber(3);
    try std.testing.expectEqual(@as(usize, 2), mgr.active_idx);
}

test "TabManager: max tabs limit" {
    const allocator = std.testing.allocator;
    var mgr = TabManager.init(allocator, .right);
    defer mgr.deinit();

    // Create MAX_TABS tabs
    var i: usize = 0;
    while (i < MAX_TABS) : (i += 1) {
        _ = try mgr.createTab("Tab");
    }

    try std.testing.expectEqual(MAX_TABS, mgr.tabCount());

    // Next create should fail
    const result = mgr.createTab("One more");
    try std.testing.expectError(error.TooManyTabs, result);
}

test "AgentTab: rename" {
    const allocator = std.testing.allocator;
    var tab = try AgentTab.init(allocator, 1, "Original", .right);
    defer tab.deinit();

    try std.testing.expectEqualStrings("Original", tab.name);

    try tab.setName("Renamed");
    try std.testing.expectEqualStrings("Renamed", tab.name);
}

test "AgentTab: autoNameFromPrompt" {
    const allocator = std.testing.allocator;

    // Test basic auto-naming
    {
        var tab = try AgentTab.init(allocator, 1, DEFAULT_TAB_NAME, .right);
        defer tab.deinit();

        try std.testing.expectEqualStrings(DEFAULT_TAB_NAME, tab.name);
        try std.testing.expect(!tab.auto_named);

        try tab.autoNameFromPrompt("Fix the login bug");
        try std.testing.expectEqualStrings("Fix the login bug", tab.name);
        try std.testing.expect(tab.auto_named);
    }

    // Test truncation of long prompts
    {
        var tab = try AgentTab.init(allocator, 2, DEFAULT_TAB_NAME, .right);
        defer tab.deinit();

        try tab.autoNameFromPrompt("This is a very long prompt that should be truncated because it exceeds the maximum length");
        try std.testing.expect(tab.name.len <= MAX_TAB_NAME_LEN);
        try std.testing.expect(std.mem.endsWith(u8, tab.name, "..."));
    }

    // Test that auto-naming only happens once
    {
        var tab = try AgentTab.init(allocator, 3, DEFAULT_TAB_NAME, .right);
        defer tab.deinit();

        try tab.autoNameFromPrompt("First prompt");
        try std.testing.expectEqualStrings("First prompt", tab.name);

        try tab.autoNameFromPrompt("Second prompt");
        try std.testing.expectEqualStrings("First prompt", tab.name); // Should not change
    }

    // Test that custom-named tabs are not auto-renamed
    {
        var tab = try AgentTab.init(allocator, 4, "My Custom Tab", .right);
        defer tab.deinit();

        try tab.autoNameFromPrompt("Some prompt");
        try std.testing.expectEqualStrings("My Custom Tab", tab.name); // Should not change
    }
}
