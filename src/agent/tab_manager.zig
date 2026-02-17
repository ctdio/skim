//! Tab Manager for Multi-Agent Support
//!
//! Manages multiple agent tabs, each with its own AgentState and AcpManager.
//! Enables concurrent work with multiple AI agents in a tabbed interface.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AgentState = @import("state.zig").AgentState;
const AcpManager = @import("../acp/manager.zig").AcpManager;
const opencode = @import("../opencode/opencode.zig");
const codex = @import("../codex/codex.zig");
pub const ManagerHandle = @import("manager_handle.zig").ManagerHandle;

/// Maximum number of tabs allowed
pub const MAX_TABS: usize = 10;

/// Default name for new tabs
const DEFAULT_TAB_NAME = "New Tab";

/// Maximum length for auto-generated tab names
const MAX_TAB_NAME_LEN: usize = 24;

/// A single agent tab containing its own state and manager connection.
/// The manager field uses a tagged union enforcing mutual exclusivity
/// between ACP and Opencode protocols at the type level.
pub const AgentTab = struct {
    id: u32,
    name: []const u8, // Owned
    agent_state: AgentState,
    manager: ?ManagerHandle, // Unified handle - nullable until agent spawned
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
            .manager = null,
            .allocator = allocator,
            .auto_named = false,
        };
    }

    /// Clean up tab resources
    pub fn deinit(self: *AgentTab) void {
        self.allocator.free(self.name);
        self.agent_state.deinit();
        if (self.manager) |m| {
            m.deinit();
            switch (m) {
                .acp => |mgr| self.allocator.destroy(mgr),
                .opencode => |mgr| {
                    // Only destroy if thread was cleanly joined
                    // If detached, thread may still access manager - leak it to avoid crash
                    if (mgr.canSafelyDestroy()) {
                        self.allocator.destroy(mgr);
                    }
                },
                .codex => |mgr| self.allocator.destroy(mgr),
            }
        }
    }

    /// Create and attach an ACP manager for this tab
    pub fn createAcpManager(self: *AgentTab) !*AcpManager {
        if (self.manager) |m| {
            switch (m) {
                .acp => |mgr| return mgr,
                .opencode => return error.AlreadyConnected,
                .codex => return error.AlreadyConnected,
            }
        }

        const mgr = try self.allocator.create(AcpManager);
        mgr.* = AcpManager.init(self.allocator);
        self.manager = .{ .acp = mgr };
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

    /// Check if this tab's agent is currently thinking (ACP or Opencode)
    pub fn isThinking(self: *const AgentTab) bool {
        if (self.manager) |m| {
            return m.isPrompting();
        }
        return false;
    }

    /// Check if this tab's agent is currently compacting context
    pub fn isCompacting(self: *const AgentTab) bool {
        if (self.manager) |m| {
            return m.isCompacting();
        }
        return false;
    }

    /// Check if this tab has a pending approval/permission request
    pub fn hasPendingApproval(self: *const AgentTab) bool {
        if (self.manager) |m| {
            return m.hasPendingApproval();
        }
        return false;
    }

    /// Get the active Opencode manager for this tab
    pub fn getActiveOpencodeManager(self: *AgentTab) ?*opencode.OpencodeManager {
        if (self.manager) |m| {
            return switch (m) {
                .opencode => |mgr| mgr,
                .acp => null,
                .codex => null,
            };
        }
        return null;
    }

    /// Get the active ACP manager for this tab
    pub fn getActiveAcpManager(self: *AgentTab) ?*AcpManager {
        if (self.manager) |m| {
            return switch (m) {
                .acp => |mgr| mgr,
                .opencode => null,
                .codex => null,
            };
        }
        return null;
    }

    /// Create and attach an Opencode manager for this tab
    pub fn createOpencodeManager(self: *AgentTab) !*opencode.OpencodeManager {
        if (self.manager) |m| {
            switch (m) {
                .opencode => |mgr| return mgr,
                .acp => return error.AlreadyConnected,
                .codex => return error.AlreadyConnected,
            }
        }

        const mgr = try self.allocator.create(opencode.OpencodeManager);
        mgr.* = opencode.OpencodeManager.init(self.allocator);
        self.manager = .{ .opencode = mgr };
        return mgr;
    }

    /// Create and attach a Codex manager for this tab
    pub fn createCodexManager(self: *AgentTab) !*codex.CodexManager {
        if (self.manager) |m| {
            switch (m) {
                .codex => |mgr| return mgr,
                .acp => return error.AlreadyConnected,
                .opencode => return error.AlreadyConnected,
            }
        }

        const mgr = try self.allocator.create(codex.CodexManager);
        mgr.* = codex.CodexManager.init(self.allocator);
        self.manager = .{ .codex = mgr };
        return mgr;
    }

    /// Disconnect all managers
    pub fn disconnectAll(self: *AgentTab) void {
        if (self.manager) |m| {
            m.deinit();
            switch (m) {
                .acp => |mgr| self.allocator.destroy(mgr),
                .opencode => |mgr| {
                    // Only destroy if thread was cleanly joined
                    if (mgr.canSafelyDestroy()) {
                        self.allocator.destroy(mgr);
                    }
                },
                .codex => |mgr| self.allocator.destroy(mgr),
            }
            self.manager = null;
        }
    }

    /// Check if session is ready (can accept prompts)
    pub fn isSessionReady(self: *const AgentTab) bool {
        if (self.manager) |m| {
            return m.isReady();
        }
        return false;
    }

    /// Check if session is initializing (discovering, connecting, etc.)
    pub fn isSessionInitializing(self: *const AgentTab) bool {
        if (self.manager) |m| {
            return m.isInitializing();
        }
        return false;
    }

    /// Check if any manager is connected (has a manager attached)
    pub fn hasManager(self: *const AgentTab) bool {
        return self.manager != null;
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
        self.next_id +|= 1; // Saturating to prevent overflow

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

    /// Close and wipe all tabs completely.
    /// Used when closing the last tab - fully resets the tab manager state.
    /// Next ensureTab() will create a fresh tab and trigger agent selection.
    pub fn closeAndWipeAll(self: *TabManager) void {
        for (self.tabs.items) |*tab| {
            tab.deinit();
        }
        self.tabs.clearRetainingCapacity();
        self.active_idx = 0;
        // Note: don't reset next_id to avoid potential ID reuse confusion
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

    /// Check if any tab has a pending approval/permission
    pub fn hasAnyPendingApproval(self: *const TabManager) bool {
        for (self.tabs.items) |*tab| {
            if (tab.hasPendingApproval()) {
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

    /// Check if any tab has manager activity (ACP or OpenCode)
    pub fn hasAnyActivity(self: *const TabManager) bool {
        for (self.tabs.items) |*tab| {
            if (tab.manager) |m| {
                if (m.hasActivity()) return true;
            }
        }
        return false;
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
