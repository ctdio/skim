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

pub const SplitOrientation = enum {
    vertical,
    horizontal,
};

pub const FocusDirection = enum {
    left,
    right,
    up,
    down,
};

pub const MoveDirection = enum {
    left,
    right,
    up,
    down,
};

pub const ResizeDirection = enum {
    narrower,
    wider,
    shorter,
    taller,
};

pub const PaneLeaf = struct {
    node_id: usize,
    tab_idx: usize,
    tab_id: u32,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

pub const PaneDivider = struct {
    orientation: SplitOrientation,
    x: usize,
    y: usize,
    length: usize,
};

pub const PaneLayoutSnapshot = struct {
    allocator: Allocator,
    panes: std.ArrayList(PaneLeaf),
    dividers: std.ArrayList(PaneDivider),
    focused_pane_id: ?usize,

    pub fn deinit(self: *PaneLayoutSnapshot) void {
        self.panes.deinit(self.allocator);
        self.dividers.deinit(self.allocator);
    }
};

const LayoutSpan = struct {
    columns: usize,
    rows: usize,
};

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
    layout_nodes: std.ArrayList(LayoutNode),
    root_node_id: ?usize,
    focused_pane_id: ?usize,

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
            .layout_nodes = .{},
            .root_node_id = null,
            .focused_pane_id = null,
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
        self.layout_nodes.deinit(self.allocator);
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
        const new_idx = self.tabs.items.len - 1;
        self.active_idx = new_idx;

        if (self.root_node_id == null) {
            const leaf_id = try self.createLeafNode(id);
            self.root_node_id = leaf_id;
            self.focused_pane_id = leaf_id;
        }

        return &self.tabs.items[new_idx];
    }

    pub fn createHiddenTab(self: *TabManager, name: []const u8) !*AgentTab {
        const previous_idx = self.active_idx;
        const previous_focused = self.focused_pane_id;
        const tab = try self.createTab(name);
        if (self.tabs.items.len > 1) {
            self.active_idx = previous_idx;
            self.focused_pane_id = previous_focused;
            self.syncActiveToFocusedPane();
        }
        return tab;
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

        const closed_tab_id = self.tabs.items[idx].id;
        const leaf_id = self.findLeafByTabId(closed_tab_id);
        var tab = self.tabs.orderedRemove(idx);
        tab.deinit();

        // Adjust active index if needed
        if (self.active_idx >= self.tabs.items.len) {
            self.active_idx = self.tabs.items.len - 1;
        } else if (self.active_idx > idx) {
            self.active_idx -= 1;
        }

        if (leaf_id) |visible_leaf_id| {
            if (self.countVisiblePanes() > 1) {
                _ = self.closePaneById(visible_leaf_id);
            } else if (self.tabs.items.len > 0) {
                const replacement_idx = @min(self.active_idx, self.tabs.items.len - 1);
                const replacement_tab_id = self.tabs.items[replacement_idx].id;
                self.setLeafTab(visible_leaf_id, replacement_tab_id);
                self.focused_pane_id = visible_leaf_id;
                self.active_idx = replacement_idx;
            }
        } else {
            self.syncActiveToFocusedPane();
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
        self.layout_nodes.clearRetainingCapacity();
        self.root_node_id = null;
        self.focused_pane_id = null;
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
        self.goToTab((self.active_idx + 1) % self.tabs.items.len);
    }

    /// Move to the previous tab (wraps around)
    pub fn prevTab(self: *TabManager) void {
        if (self.tabs.items.len == 0) return;
        const idx = if (self.active_idx == 0) self.tabs.items.len - 1 else self.active_idx - 1;
        self.goToTab(idx);
    }

    /// Go to a specific tab by index (0-based)
    pub fn goToTab(self: *TabManager, idx: usize) void {
        if (idx >= self.tabs.items.len) return;
        const tab_id = self.tabs.items[idx].id;
        if (self.findLeafByTabId(tab_id)) |leaf_id| {
            _ = self.focusPaneById(leaf_id);
            return;
        }
        self.active_idx = idx;
        self.showTabInFocusedPane(tab_id);
    }

    /// Go to a specific tab by number (1-based, vim-style)
    pub fn goToTabNumber(self: *TabManager, num: usize) void {
        if (num > 0 and num <= self.tabs.items.len) {
            self.goToTab(num - 1);
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

    pub fn isPaneSplitActive(self: *const TabManager) bool {
        return self.countVisiblePanes() > 1;
    }

    pub fn splitFocusedPane(self: *TabManager, orientation: SplitOrientation, new_tab_id: u32) !bool {
        const focused_leaf_id = self.focused_pane_id orelse return false;
        if (self.findTabById(new_tab_id) == null) return false;

        const new_leaf_id = try self.createLeafNode(new_tab_id);
        const parent_id = self.layout_nodes.items[focused_leaf_id].parent;
        const split_id = try self.createSplitNode(orientation, focused_leaf_id, new_leaf_id, 500);

        self.layout_nodes.items[split_id].parent = parent_id;
        self.layout_nodes.items[focused_leaf_id].parent = split_id;
        self.layout_nodes.items[new_leaf_id].parent = split_id;

        if (parent_id) |pid| {
            self.replaceChild(pid, focused_leaf_id, split_id);
        } else {
            self.root_node_id = split_id;
        }

        self.focused_pane_id = new_leaf_id;
        if (!self.focusPaneById(new_leaf_id)) {
            return false;
        }
        _ = self.equalizePaneSizes();
        return true;
    }

    pub fn showTabInFocusedPane(self: *TabManager, tab_id: u32) void {
        if (self.root_node_id == null) return;
        const focused_leaf_id = self.focused_pane_id orelse self.findAnyLeaf() orelse return;
        self.setLeafTab(focused_leaf_id, tab_id);
        self.focused_pane_id = focused_leaf_id;
        self.syncActiveToFocusedPane();
    }

    pub fn collectPaneLayout(self: *const TabManager, allocator: Allocator, width: usize, height: usize) !PaneLayoutSnapshot {
        var snapshot = PaneLayoutSnapshot{
            .allocator = allocator,
            .panes = .{},
            .dividers = .{},
            .focused_pane_id = self.focused_pane_id,
        };
        if (self.root_node_id) |root_id| {
            try self.collectPaneLayoutRecursive(root_id, 0, 0, width, height, &snapshot.panes, &snapshot.dividers);
        }
        return snapshot;
    }

    pub fn focusPaneById(self: *TabManager, pane_id: usize) bool {
        if (pane_id >= self.layout_nodes.items.len) return false;
        const node = self.layout_nodes.items[pane_id];
        const tab_id = switch (node.data) {
            .leaf => |id| id,
            .split => return false,
        };
        const tab_idx = self.findTabById(tab_id) orelse return false;
        self.focused_pane_id = pane_id;
        self.active_idx = tab_idx;
        return true;
    }

    pub fn focusNextPane(self: *TabManager) bool {
        return self.focusPaneByOffset(1);
    }

    pub fn focusPrevPane(self: *TabManager) bool {
        return self.focusPaneByOffset(-1);
    }

    pub fn focusPaneDirection(self: *TabManager, direction: FocusDirection) bool {
        const current = self.focused_pane_id orelse return false;
        const target = self.findDirectionalPane(current, direction) orelse return false;
        return self.focusPaneById(target);
    }

    pub fn moveFocusedPane(self: *TabManager, direction: MoveDirection) !bool {
        const leaf_id = self.focused_pane_id orelse return false;
        if (self.countVisiblePanes() <= 1) return false;
        if (self.root_node_id == null or self.root_node_id.? == leaf_id) return false;

        self.detachLeafFromLayout(leaf_id);
        const current_root = self.root_node_id orelse {
            self.root_node_id = leaf_id;
            self.focused_pane_id = leaf_id;
            return true;
        };

        const orientation: SplitOrientation = switch (direction) {
            .left, .right => .vertical,
            .up, .down => .horizontal,
        };
        const focused_first = switch (direction) {
            .left, .up => true,
            .right, .down => false,
        };
        const first = if (focused_first) leaf_id else current_root;
        const second = if (focused_first) current_root else leaf_id;
        const new_root = try self.createSplitNode(orientation, first, second, 500);
        self.layout_nodes.items[first].parent = new_root;
        self.layout_nodes.items[second].parent = new_root;
        self.root_node_id = new_root;
        self.focused_pane_id = leaf_id;
        self.syncActiveToFocusedPane();
        return true;
    }

    pub fn resizeFocusedPane(self: *TabManager, direction: ResizeDirection) bool {
        const leaf_id = self.focused_pane_id orelse return false;
        return switch (direction) {
            .narrower => self.adjustAncestorRatio(leaf_id, .vertical, false),
            .wider => self.adjustAncestorRatio(leaf_id, .vertical, true),
            .shorter => self.adjustAncestorRatio(leaf_id, .horizontal, false),
            .taller => self.adjustAncestorRatio(leaf_id, .horizontal, true),
        };
    }

    pub fn equalizePaneSizes(self: *TabManager) bool {
        const root_id = self.root_node_id orelse return false;
        if (self.countVisiblePanes() <= 1) return false;

        var changed = false;
        _ = self.equalizeNodeRecursive(root_id, &changed);
        return changed;
    }

    pub fn collapseToActivePane(self: *TabManager) bool {
        const focused = self.focused_pane_id orelse return false;
        if (self.countVisiblePanes() <= 1) return false;
        self.root_node_id = focused;
        self.layout_nodes.items[focused].parent = null;
        self.syncActiveToFocusedPane();
        return true;
    }

    pub fn closeFocusedPane(self: *TabManager) bool {
        const leaf_id = self.focused_pane_id orelse return false;
        return self.closePaneById(leaf_id);
    }

    fn closePaneById(self: *TabManager, leaf_id: usize) bool {
        if (self.countVisiblePanes() <= 1) return false;
        const next_focus = self.findAdjacentFocusCandidate(leaf_id);
        self.detachLeafFromLayout(leaf_id);
        if (next_focus) |candidate| {
            _ = self.focusPaneById(candidate);
        } else {
            self.syncActiveToFocusedPane();
        }
        return true;
    }

    fn countVisiblePanes(self: *const TabManager) usize {
        var count: usize = 0;
        self.countLeavesRecursive(self.root_node_id, &count);
        return count;
    }

    fn countLeavesRecursive(self: *const TabManager, node_id: ?usize, count: *usize) void {
        const id = node_id orelse return;
        const node = self.layout_nodes.items[id];
        switch (node.data) {
            .leaf => count.* += 1,
            .split => |split| {
                self.countLeavesRecursive(split.first, count);
                self.countLeavesRecursive(split.second, count);
            },
        }
    }

    fn focusPaneByOffset(self: *TabManager, delta: isize) bool {
        var leaves: std.ArrayList(usize) = .{};
        defer leaves.deinit(self.allocator);
        self.collectLeafIds(self.root_node_id, &leaves) catch return false;
        if (leaves.items.len <= 1) return false;

        const current = self.focused_pane_id orelse return false;
        var current_idx: usize = 0;
        for (leaves.items, 0..) |leaf_id, idx| {
            if (leaf_id == current) {
                current_idx = idx;
                break;
            }
        }

        const len_isize: isize = @intCast(leaves.items.len);
        const current_isize: isize = @intCast(current_idx);
        const next_isize = @mod(current_isize + delta + len_isize, len_isize);
        const next_idx: usize = @intCast(next_isize);
        return self.focusPaneById(leaves.items[next_idx]);
    }

    fn collectLeafIds(self: *const TabManager, node_id: ?usize, leaves: *std.ArrayList(usize)) !void {
        const id = node_id orelse return;
        const node = self.layout_nodes.items[id];
        switch (node.data) {
            .leaf => try leaves.append(self.allocator, id),
            .split => |split| {
                try self.collectLeafIds(split.first, leaves);
                try self.collectLeafIds(split.second, leaves);
            },
        }
    }

    fn collectPaneLayoutRecursive(
        self: *const TabManager,
        node_id: usize,
        x: usize,
        y: usize,
        width: usize,
        height: usize,
        panes: *std.ArrayList(PaneLeaf),
        dividers: *std.ArrayList(PaneDivider),
    ) !void {
        const node = self.layout_nodes.items[node_id];
        switch (node.data) {
            .leaf => |tab_id| {
                const tab_idx = self.findTabById(tab_id) orelse return;
                try panes.append(self.allocator, .{
                    .node_id = node_id,
                    .tab_idx = tab_idx,
                    .tab_id = tab_id,
                    .x = x,
                    .y = y,
                    .width = width,
                    .height = height,
                });
            },
            .split => |split| {
                if (split.orientation == .vertical) {
                    const divider_width: usize = if (width > 1) 1 else 0;
                    const available_width = width -| divider_width;
                    const first_width = splitLength(available_width, split.ratio_milli);
                    const second_width = width -| first_width -| divider_width;
                    try self.collectPaneLayoutRecursive(split.first, x, y, first_width, height, panes, dividers);
                    if (divider_width == 1) {
                        try dividers.append(self.allocator, .{
                            .orientation = .vertical,
                            .x = x + first_width,
                            .y = y,
                            .length = height,
                        });
                    }
                    try self.collectPaneLayoutRecursive(split.second, x + first_width + divider_width, y, second_width, height, panes, dividers);
                } else {
                    const divider_height: usize = if (height > 1) 1 else 0;
                    const available_height = height -| divider_height;
                    const first_height = splitLength(available_height, split.ratio_milli);
                    const second_height = height -| first_height -| divider_height;
                    try self.collectPaneLayoutRecursive(split.first, x, y, width, first_height, panes, dividers);
                    if (divider_height == 1) {
                        try dividers.append(self.allocator, .{
                            .orientation = .horizontal,
                            .x = x,
                            .y = y + first_height,
                            .length = width,
                        });
                    }
                    try self.collectPaneLayoutRecursive(split.second, x, y + first_height + divider_height, width, second_height, panes, dividers);
                }
            },
        }
    }

    fn findDirectionalPane(self: *const TabManager, current_leaf_id: usize, direction: FocusDirection) ?usize {
        var leaves: std.ArrayList(PaneLeaf) = .{};
        defer leaves.deinit(self.allocator);
        var dividers: std.ArrayList(PaneDivider) = .{};
        defer dividers.deinit(self.allocator);
        if (self.root_node_id) |root_id| {
            self.collectPaneLayoutRecursive(root_id, 0, 0, 1000, 1000, &leaves, &dividers) catch return null;
        }

        var current_leaf: ?PaneLeaf = null;
        for (leaves.items) |leaf| {
            if (leaf.node_id == current_leaf_id) {
                current_leaf = leaf;
                break;
            }
        }
        const current = current_leaf orelse return null;

        var best_id: ?usize = null;
        var best_overlap: usize = 0;
        var best_primary: usize = std.math.maxInt(usize);
        var best_secondary: usize = std.math.maxInt(usize);

        for (leaves.items) |candidate| {
            if (candidate.node_id == current.node_id) continue;
            const relation = directionalMetrics(current, candidate, direction) orelse continue;
            if (relation.overlap > best_overlap or
                (relation.overlap == best_overlap and relation.primary_dist < best_primary) or
                (relation.overlap == best_overlap and relation.primary_dist == best_primary and relation.secondary_dist < best_secondary))
            {
                best_id = candidate.node_id;
                best_overlap = relation.overlap;
                best_primary = relation.primary_dist;
                best_secondary = relation.secondary_dist;
            }
        }

        return best_id;
    }

    fn findAdjacentFocusCandidate(self: *const TabManager, leaf_id: usize) ?usize {
        return self.findDirectionalPane(leaf_id, .right) orelse
            self.findDirectionalPane(leaf_id, .left) orelse
            self.findDirectionalPane(leaf_id, .down) orelse
            self.findDirectionalPane(leaf_id, .up) orelse
            self.findAnyLeafExcept(leaf_id);
    }

    fn findAnyLeaf(self: *const TabManager) ?usize {
        return self.findLeafRecursive(self.root_node_id);
    }

    fn findAnyLeafExcept(self: *const TabManager, excluded_id: usize) ?usize {
        var leaves: std.ArrayList(usize) = .{};
        defer leaves.deinit(self.allocator);
        self.collectLeafIds(self.root_node_id, &leaves) catch return null;
        for (leaves.items) |leaf_id| {
            if (leaf_id != excluded_id) return leaf_id;
        }
        return null;
    }

    fn findLeafRecursive(self: *const TabManager, node_id: ?usize) ?usize {
        const id = node_id orelse return null;
        const node = self.layout_nodes.items[id];
        return switch (node.data) {
            .leaf => id,
            .split => |split| self.findLeafRecursive(split.first) orelse self.findLeafRecursive(split.second),
        };
    }

    fn detachLeafFromLayout(self: *TabManager, leaf_id: usize) void {
        const parent_id = self.layout_nodes.items[leaf_id].parent orelse {
            self.root_node_id = leaf_id;
            self.layout_nodes.items[leaf_id].parent = null;
            return;
        };
        const parent = self.layout_nodes.items[parent_id].data.split;
        const sibling_id = if (parent.first == leaf_id) parent.second else parent.first;
        const grandparent_id = self.layout_nodes.items[parent_id].parent;

        self.layout_nodes.items[leaf_id].parent = null;
        self.layout_nodes.items[sibling_id].parent = grandparent_id;

        if (grandparent_id) |gid| {
            self.replaceChild(gid, parent_id, sibling_id);
        } else {
            self.root_node_id = sibling_id;
        }
    }

    fn adjustAncestorRatio(self: *TabManager, leaf_id: usize, orientation: SplitOrientation, grow_positive: bool) bool {
        var child_id = leaf_id;
        var ancestor_id = self.layout_nodes.items[leaf_id].parent;
        while (ancestor_id) |id| {
            const node = &self.layout_nodes.items[id];
            switch (node.data) {
                .leaf => return false,
                .split => |*split| {
                    if (split.orientation == orientation) {
                        const child_is_first = split.first == child_id;
                        const step: i32 = 100;
                        const signed_delta: i32 = if (grow_positive)
                            (if (child_is_first) step else -step)
                        else
                            (if (child_is_first) -step else step);
                        const current_ratio: i32 = split.ratio_milli;
                        const next_ratio: i32 = std.math.clamp(current_ratio + signed_delta, 100, 900);
                        if (next_ratio == current_ratio) return false;
                        split.ratio_milli = @intCast(next_ratio);
                        return true;
                    }
                    child_id = id;
                    ancestor_id = node.parent;
                },
            }
        }
        return false;
    }

    fn equalizeNodeRecursive(self: *TabManager, node_id: usize, changed: *bool) LayoutSpan {
        const node = &self.layout_nodes.items[node_id];
        return switch (node.data) {
            .leaf => .{ .columns = 1, .rows = 1 },
            .split => |*split| blk: {
                const first_span = self.equalizeNodeRecursive(split.first, changed);
                const second_span = self.equalizeNodeRecursive(split.second, changed);
                const first_units, const second_units = switch (split.orientation) {
                    .vertical => .{ first_span.columns, second_span.columns },
                    .horizontal => .{ first_span.rows, second_span.rows },
                };
                const ratio = calculateEqualizedRatio(first_units, second_units);
                if (split.ratio_milli != ratio) {
                    split.ratio_milli = ratio;
                    changed.* = true;
                }
                break :blk switch (split.orientation) {
                    .vertical => .{
                        .columns = first_span.columns + second_span.columns,
                        .rows = @max(first_span.rows, second_span.rows),
                    },
                    .horizontal => .{
                        .columns = @max(first_span.columns, second_span.columns),
                        .rows = first_span.rows + second_span.rows,
                    },
                };
            },
        };
    }

    fn syncActiveToFocusedPane(self: *TabManager) void {
        if (self.focused_pane_id) |leaf_id| {
            _ = self.focusPaneById(leaf_id);
            return;
        }
        if (self.root_node_id) |_| {
            self.focused_pane_id = self.findAnyLeaf();
            if (self.focused_pane_id) |leaf_id| {
                _ = self.focusPaneById(leaf_id);
            }
        }
    }

    fn findLeafByTabId(self: *const TabManager, tab_id: u32) ?usize {
        for (self.layout_nodes.items, 0..) |node, node_id| {
            switch (node.data) {
                .leaf => |id| if (id == tab_id) return node_id,
                .split => {},
            }
        }
        return null;
    }

    fn setLeafTab(self: *TabManager, leaf_id: usize, tab_id: u32) void {
        self.layout_nodes.items[leaf_id].data = .{ .leaf = tab_id };
    }

    fn replaceChild(self: *TabManager, parent_id: usize, old_child_id: usize, new_child_id: usize) void {
        const split = &self.layout_nodes.items[parent_id].data.split;
        if (split.first == old_child_id) {
            split.first = new_child_id;
        } else if (split.second == old_child_id) {
            split.second = new_child_id;
        }
        self.layout_nodes.items[new_child_id].parent = parent_id;
    }

    fn createLeafNode(self: *TabManager, tab_id: u32) !usize {
        try self.layout_nodes.append(self.allocator, .{
            .parent = null,
            .data = .{ .leaf = tab_id },
        });
        return self.layout_nodes.items.len - 1;
    }

    fn createSplitNode(self: *TabManager, orientation: SplitOrientation, first: usize, second: usize, ratio_milli: u16) !usize {
        try self.layout_nodes.append(self.allocator, .{
            .parent = null,
            .data = .{ .split = .{
                .orientation = orientation,
                .first = first,
                .second = second,
                .ratio_milli = ratio_milli,
            } },
        });
        return self.layout_nodes.items.len - 1;
    }

    const LayoutNode = struct {
        parent: ?usize,
        data: union(enum) {
            leaf: u32,
            split: SplitNode,
        },
    };

    const SplitNode = struct {
        orientation: SplitOrientation,
        first: usize,
        second: usize,
        ratio_milli: u16,
    };

    const DirectionalRelation = struct {
        overlap: usize,
        primary_dist: usize,
        secondary_dist: usize,
    };

    fn splitLength(total: usize, ratio_milli: u16) usize {
        if (total <= 1) return total;
        const raw = (total * ratio_milli) / 1000;
        return std.math.clamp(raw, @as(usize, 1), total - 1);
    }

    fn directionalMetrics(current: PaneLeaf, candidate: PaneLeaf, direction: FocusDirection) ?DirectionalRelation {
        const current_right = current.x + current.width;
        const current_bottom = current.y + current.height;
        const candidate_right = candidate.x + candidate.width;
        const candidate_bottom = candidate.y + candidate.height;

        return switch (direction) {
            .left => if (candidate_right <= current.x) .{
                .overlap = intervalOverlap(current.y, current_bottom, candidate.y, candidate_bottom),
                .primary_dist = current.x - candidate_right,
                .secondary_dist = centerDistance(current.y, current_bottom, candidate.y, candidate_bottom),
            } else null,
            .right => if (candidate.x >= current_right) .{
                .overlap = intervalOverlap(current.y, current_bottom, candidate.y, candidate_bottom),
                .primary_dist = candidate.x - current_right,
                .secondary_dist = centerDistance(current.y, current_bottom, candidate.y, candidate_bottom),
            } else null,
            .up => if (candidate_bottom <= current.y) .{
                .overlap = intervalOverlap(current.x, current_right, candidate.x, candidate_right),
                .primary_dist = current.y - candidate_bottom,
                .secondary_dist = centerDistance(current.x, current_right, candidate.x, candidate_right),
            } else null,
            .down => if (candidate.y >= current_bottom) .{
                .overlap = intervalOverlap(current.x, current_right, candidate.x, candidate_right),
                .primary_dist = candidate.y - current_bottom,
                .secondary_dist = centerDistance(current.x, current_right, candidate.x, candidate_right),
            } else null,
        };
    }

    fn intervalOverlap(a_start: usize, a_end: usize, b_start: usize, b_end: usize) usize {
        const start = @max(a_start, b_start);
        const end = @min(a_end, b_end);
        return end -| start;
    }

    fn centerDistance(a_start: usize, a_end: usize, b_start: usize, b_end: usize) usize {
        const a_center = (a_start + a_end) / 2;
        const b_center = (b_start + b_end) / 2;
        return if (a_center > b_center) a_center - b_center else b_center - a_center;
    }

    fn calculateEqualizedRatio(first_units: usize, second_units: usize) u16 {
        const total_units = first_units + second_units;
        if (total_units == 0) return 500;

        const raw_ratio = ((first_units * 1000) + (total_units / 2)) / total_units;
        return @intCast(std.math.clamp(raw_ratio, @as(usize, 100), @as(usize, 900)));
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

test "TabManager: nested splits render multiple panes" {
    const allocator = std.testing.allocator;
    var mgr = TabManager.init(allocator, .right);
    defer mgr.deinit();

    const tab1 = try mgr.createTab("Tab 1");
    const tab2 = try mgr.createHiddenTab("Tab 2");
    try std.testing.expect(try mgr.splitFocusedPane(.vertical, tab2.id));

    const tab3 = try mgr.createHiddenTab("Tab 3");
    try std.testing.expect(try mgr.splitFocusedPane(.horizontal, tab3.id));

    var snapshot = try mgr.collectPaneLayout(allocator, 80, 24);
    defer snapshot.deinit();

    try std.testing.expectEqual(@as(usize, 3), snapshot.panes.items.len);
    try std.testing.expect(snapshot.dividers.items.len >= 2);
    try std.testing.expectEqual(tab1.id, snapshot.panes.items[0].tab_id);
    try std.testing.expectEqual(tab2.id, snapshot.panes.items[1].tab_id);
    try std.testing.expectEqual(tab3.id, snapshot.panes.items[2].tab_id);
}

test "TabManager: directional focus follows pane geometry" {
    const allocator = std.testing.allocator;
    var mgr = TabManager.init(allocator, .right);
    defer mgr.deinit();

    const left = try mgr.createTab("Left");
    const right_top = try mgr.createHiddenTab("Right Top");
    try std.testing.expect(try mgr.splitFocusedPane(.vertical, right_top.id));

    const right_bottom = try mgr.createHiddenTab("Right Bottom");
    try std.testing.expect(try mgr.splitFocusedPane(.horizontal, right_bottom.id));

    try std.testing.expectEqual(right_bottom.id, mgr.activeTab().?.id);
    try std.testing.expect(mgr.focusPaneDirection(.up));
    try std.testing.expectEqual(right_top.id, mgr.activeTab().?.id);
    try std.testing.expect(mgr.focusPaneDirection(.left));
    try std.testing.expectEqual(left.id, mgr.activeTab().?.id);
}

test "TabManager: move focused pane re-roots toward requested edge" {
    const allocator = std.testing.allocator;
    var mgr = TabManager.init(allocator, .right);
    defer mgr.deinit();

    const left = try mgr.createTab("Left");
    const right = try mgr.createHiddenTab("Right");
    try std.testing.expect(try mgr.splitFocusedPane(.vertical, right.id));
    try std.testing.expect(mgr.focusPaneDirection(.left));
    try std.testing.expectEqual(left.id, mgr.activeTab().?.id);

    try std.testing.expect(try mgr.moveFocusedPane(.down));

    var snapshot = try mgr.collectPaneLayout(allocator, 80, 24);
    defer snapshot.deinit();

    try std.testing.expectEqual(@as(usize, 2), snapshot.panes.items.len);
    try std.testing.expectEqual(left.id, snapshot.panes.items[1].tab_id);
    try std.testing.expect(snapshot.panes.items[1].y > snapshot.panes.items[0].y);
}

test "TabManager: resize adjusts ancestor ratio" {
    const allocator = std.testing.allocator;
    var mgr = TabManager.init(allocator, .right);
    defer mgr.deinit();

    _ = try mgr.createTab("Left");
    const right = try mgr.createHiddenTab("Right");
    try std.testing.expect(try mgr.splitFocusedPane(.vertical, right.id));

    var before = try mgr.collectPaneLayout(allocator, 80, 24);
    defer before.deinit();
    const before_width = before.panes.items[1].width;

    try std.testing.expect(mgr.resizeFocusedPane(.wider));

    var after = try mgr.collectPaneLayout(allocator, 80, 24);
    defer after.deinit();
    try std.testing.expect(after.panes.items[1].width > before_width);
}

test "TabManager: equalize pane sizes restores balanced nested layout" {
    const allocator = std.testing.allocator;
    var mgr = TabManager.init(allocator, .right);
    defer mgr.deinit();

    _ = try mgr.createTab("Left");
    const right_top = try mgr.createHiddenTab("Right Top");
    try std.testing.expect(try mgr.splitFocusedPane(.vertical, right_top.id));

    const right_bottom = try mgr.createHiddenTab("Right Bottom");
    try std.testing.expect(try mgr.splitFocusedPane(.horizontal, right_bottom.id));

    try std.testing.expect(mgr.resizeFocusedPane(.wider));
    try std.testing.expect(mgr.resizeFocusedPane(.shorter));

    var skewed = try mgr.collectPaneLayout(allocator, 81, 25);
    defer skewed.deinit();
    try std.testing.expect(skewed.panes.items[0].width != skewed.panes.items[1].width);
    try std.testing.expect(skewed.panes.items[1].height != skewed.panes.items[2].height);

    try std.testing.expect(mgr.equalizePaneSizes());

    var leveled = try mgr.collectPaneLayout(allocator, 81, 25);
    defer leveled.deinit();
    try std.testing.expectEqual(leveled.panes.items[0].width, leveled.panes.items[1].width);
    try std.testing.expectEqual(leveled.panes.items[1].height, leveled.panes.items[2].height);
}

test "TabManager: split auto-equalizes a skewed layout" {
    const allocator = std.testing.allocator;
    var mgr = TabManager.init(allocator, .right);
    defer mgr.deinit();

    _ = try mgr.createTab("Left");
    const right = try mgr.createHiddenTab("Right");
    try std.testing.expect(try mgr.splitFocusedPane(.vertical, right.id));
    try std.testing.expect(mgr.resizeFocusedPane(.wider));

    var skewed = try mgr.collectPaneLayout(allocator, 81, 25);
    defer skewed.deinit();
    try std.testing.expect(skewed.panes.items[0].width != skewed.panes.items[1].width);

    const right_bottom = try mgr.createHiddenTab("Right Bottom");
    try std.testing.expect(try mgr.splitFocusedPane(.horizontal, right_bottom.id));

    var leveled = try mgr.collectPaneLayout(allocator, 81, 25);
    defer leveled.deinit();
    try std.testing.expectEqual(leveled.panes.items[0].width, leveled.panes.items[1].width);
    try std.testing.expectEqual(leveled.panes.items[1].height, leveled.panes.items[2].height);
}

test "TabManager: collapse and close focused pane keep layout valid" {
    const allocator = std.testing.allocator;
    var mgr = TabManager.init(allocator, .right);
    defer mgr.deinit();

    const tab1 = try mgr.createTab("Tab 1");
    const tab2 = try mgr.createHiddenTab("Tab 2");
    try std.testing.expect(try mgr.splitFocusedPane(.vertical, tab2.id));
    const tab3 = try mgr.createHiddenTab("Tab 3");
    try std.testing.expect(try mgr.splitFocusedPane(.horizontal, tab3.id));

    try std.testing.expect(mgr.closeFocusedPane());
    try std.testing.expect(mgr.isPaneSplitActive());

    try std.testing.expect(mgr.collapseToActivePane());
    try std.testing.expect(!mgr.isPaneSplitActive());
    try std.testing.expectEqual(tab2.id, mgr.activeTab().?.id);
    try std.testing.expect(mgr.findLeafByTabId(tab1.id) != null);
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
