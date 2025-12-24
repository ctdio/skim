const std = @import("std");
const Allocator = std.mem.Allocator;
const InputEditor = @import("input_editor.zig").InputEditor;
const ChatLineMap = @import("chat_line_map.zig").ChatLineMap;
const protocol = @import("../acp/protocol.zig");

/// Maximum number of slash commands visible in menu at once
pub const MAX_SLASH_MENU_VISIBLE: usize = 12;

/// Local slash command definition (handled by skim, not sent to agent)
pub const LocalSlashCommand = struct {
    name: []const u8,
    description: []const u8,
    is_local: bool, // True = handled locally, false = sent to agent
};

/// Local slash commands that skim handles (not sent to agent)
pub const local_slash_commands = [_]LocalSlashCommand{
    .{ .name = "model", .description = "Switch AI model (opus/sonnet/haiku)", .is_local = true },
};

// =============================================================================
// Plan Entry (Owned)
// =============================================================================

/// Owned plan entry - stores content string that needs to be freed
pub const OwnedPlanEntry = struct {
    content: []const u8, // Owned
    priority: protocol.PlanEntryPriority,
    status: protocol.PlanEntryStatus,

    pub fn deinit(self: *OwnedPlanEntry, allocator: Allocator) void {
        allocator.free(self.content);
    }
};

/// Owned slash command - stores strings that need to be freed
pub const OwnedCommand = struct {
    name: []const u8, // Owned
    description: []const u8, // Owned
    input_hint: ?[]const u8, // Owned, optional

    pub fn deinit(self: *OwnedCommand, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        if (self.input_hint) |hint| allocator.free(hint);
    }
};

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
    line_map: ChatLineMap, // Pre-computed line map for stable rendering
    line_map_dirty: bool, // True when line_map needs rebuild
    // Agent plan (todo list)
    plan_entries: std.ArrayList(OwnedPlanEntry),
    plan_visible: bool, // Whether to show the plan above input
    // Slash commands
    available_commands: std.ArrayList(OwnedCommand),
    slash_menu_visible: bool,
    slash_menu_selection: usize, // Index into filtered commands
    slash_menu_scroll_offset: usize, // Scroll offset for menu pagination
    // Input area scrolling
    input_scroll_offset: usize, // Vertical scroll offset for multi-line input
    // Interrupt tracking (double-ESC to cancel)
    last_esc_timestamp: i64, // Timestamp of last ESC press (ms since epoch)

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
            .full_screen = true, // Default to full screen (toggle with 'z')
            .diff_view_mode = .unified, // Default to unified view
            .line_map = ChatLineMap.init(allocator),
            .line_map_dirty = true,
            .plan_entries = .{},
            .plan_visible = true, // Show plan by default when entries exist
            .available_commands = .{},
            .slash_menu_visible = false,
            .slash_menu_selection = 0,
            .slash_menu_scroll_offset = 0,
            .input_scroll_offset = 0,
            .last_esc_timestamp = 0,
        };
    }

    pub fn deinit(self: *AgentState) void {
        for (self.messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.messages.deinit(self.allocator);
        self.line_map.deinit();
        for (self.plan_entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.plan_entries.deinit(self.allocator);
        for (self.available_commands.items) |*cmd| {
            cmd.deinit(self.allocator);
        }
        self.available_commands.deinit(self.allocator);
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

        // Log memory usage every 10 messages to track growth
        if (self.messages.items.len % 10 == 0) {
            std.log.debug("Agent chat: {d} messages ({d} bytes content)", .{
                self.messages.items.len,
                self.estimateMemoryUsage(),
            });
        }

        // Mark line map dirty
        self.line_map_dirty = true;

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

        // Mark line map dirty
        self.line_map_dirty = true;

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

        // Append to existing agent message using ArrayList for efficient growth
        // This avoids reallocating the entire content on every append
        var content_list: std.ArrayList(u8) = .{};
        defer content_list.deinit(self.allocator);

        try content_list.appendSlice(self.allocator, last.content);
        try content_list.appendSlice(self.allocator, text);

        const new_content = try content_list.toOwnedSlice(self.allocator);
        self.allocator.free(last.content);
        last.content = new_content;

        // Mark line map dirty for streaming update
        self.line_map_dirty = true;

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

        // Append to existing thinking message using ArrayList for efficient growth
        var content_list: std.ArrayList(u8) = .{};
        defer content_list.deinit(self.allocator);

        try content_list.appendSlice(self.allocator, last.content);
        try content_list.appendSlice(self.allocator, text);

        const new_content = try content_list.toOwnedSlice(self.allocator);
        self.allocator.free(last.content);
        last.content = new_content;

        // Mark line map dirty for streaming update
        self.line_map_dirty = true;

        self.scrollToBottom();
    }

    /// Add a tool call message (or update existing if tool_call_id matches)
    pub fn addToolMessage(
        self: *AgentState,
        tool_call_id: []const u8,
        tool_name: ?[]const u8,
        title: []const u8,
        command: ?[]const u8,
    ) !void {
        // Check if we already have a message with this tool_call_id
        // (ACP sends tool_call twice: once without params, once with params)
        for (self.messages.items) |*msg| {
            if (msg.role == .tool) {
                if (msg.tool_call_id) |existing_id| {
                    if (std.mem.eql(u8, existing_id, tool_call_id)) {
                        // Update existing message with more info
                        // Update title if different (second call has more specific title)
                        if (!std.mem.eql(u8, title, msg.content)) {
                            const new_title = try self.allocator.dupe(u8, title);
                            self.allocator.free(msg.content);
                            msg.content = new_title;
                        }
                        // Update command if provided and not set
                        if (command != null and msg.tool_command == null) {
                            msg.tool_command = try self.allocator.dupe(u8, command.?);
                        }
                        // Mark dirty and scroll
                        self.line_map_dirty = true;
                        self.scrollToBottom();
                        return;
                    }
                }
            }
        }

        // No existing message, create new one
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

        // Mark line map dirty
        self.line_map_dirty = true;

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

                        // Mark line map dirty
                        self.line_map_dirty = true;

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
        self.line_map_dirty = true;
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
        self.line_map_dirty = true;
    }

    /// Get message count
    pub fn messageCount(self: *const AgentState) usize {
        return self.messages.items.len;
    }

    /// Ensure line map is up to date for rendering
    /// Returns the line map for iteration
    pub fn ensureLineMap(self: *AgentState, wrap_width: usize) !*const ChatLineMap {
        if (self.line_map_dirty or self.line_map.needsRebuild(wrap_width, self.diff_view_mode)) {
            try self.line_map.build(self.messages.items, wrap_width, self.diff_view_mode);
            self.line_map_dirty = false;
        }
        return &self.line_map;
    }

    // =========================================================================
    // Plan Management
    // =========================================================================

    /// Update the plan with new entries (replaces all existing entries)
    pub fn updatePlan(self: *AgentState, entries: []const protocol.PlanEntry) !void {
        // Clear existing entries
        self.clearPlan();

        // Add new entries
        for (entries) |entry| {
            const owned_content = try self.allocator.dupe(u8, entry.content);
            errdefer self.allocator.free(owned_content);

            try self.plan_entries.append(self.allocator, .{
                .content = owned_content,
                .priority = entry.priority,
                .status = entry.status,
            });
        }
    }

    /// Clear all plan entries
    pub fn clearPlan(self: *AgentState) void {
        for (self.plan_entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.plan_entries.clearRetainingCapacity();
    }

    /// Toggle plan visibility
    pub fn togglePlanVisibility(self: *AgentState) void {
        self.plan_visible = !self.plan_visible;
    }

    /// Get the number of plan entries
    pub fn planEntryCount(self: *const AgentState) usize {
        return self.plan_entries.items.len;
    }

    /// Check if there are any incomplete plan entries
    pub fn hasIncompletePlanEntries(self: *const AgentState) bool {
        for (self.plan_entries.items) |entry| {
            if (entry.status != .completed) return true;
        }
        return false;
    }

    // =========================================================================
    // Slash Command Management
    // =========================================================================

    /// Update available commands (replaces agent commands while preserving local commands)
    pub fn updateAvailableCommands(self: *AgentState, commands: []const protocol.AvailableCommand) !void {
        // Remove only non-local commands (preserve local slash commands)
        var i: usize = 0;
        while (i < self.available_commands.items.len) {
            if (!isLocalSlashCommand(self.available_commands.items[i].name)) {
                var cmd = self.available_commands.orderedRemove(i);
                cmd.deinit(self.allocator);
            } else {
                i += 1;
            }
        }

        // Add new commands from agent
        for (commands) |cmd| {
            const owned_name = try self.allocator.dupe(u8, cmd.name);
            errdefer self.allocator.free(owned_name);

            const owned_desc = try self.allocator.dupe(u8, cmd.description);
            errdefer self.allocator.free(owned_desc);

            const owned_hint: ?[]const u8 = if (cmd.input) |input|
                try self.allocator.dupe(u8, input.hint)
            else
                null;
            errdefer if (owned_hint) |h| self.allocator.free(h);

            try self.available_commands.append(self.allocator, .{
                .name = owned_name,
                .description = owned_desc,
                .input_hint = owned_hint,
            });
        }
    }

    /// Clear all available commands
    pub fn clearAvailableCommands(self: *AgentState) void {
        for (self.available_commands.items) |*cmd| {
            cmd.deinit(self.allocator);
        }
        self.available_commands.clearRetainingCapacity();
    }

    /// Add local slash commands (handled by skim, not sent to agent)
    /// Should be called when agent panel opens or session starts
    pub fn addLocalSlashCommands(self: *AgentState) !void {
        for (local_slash_commands) |local_cmd| {
            // Check if already added (avoid duplicates)
            var already_exists = false;
            for (self.available_commands.items) |existing| {
                if (std.mem.eql(u8, existing.name, local_cmd.name)) {
                    already_exists = true;
                    break;
                }
            }
            if (already_exists) continue;

            const owned_name = try self.allocator.dupe(u8, local_cmd.name);
            errdefer self.allocator.free(owned_name);

            const owned_desc = try self.allocator.dupe(u8, local_cmd.description);
            errdefer self.allocator.free(owned_desc);

            try self.available_commands.append(self.allocator, .{
                .name = owned_name,
                .description = owned_desc,
                .input_hint = null,
            });
        }
    }

    /// Check if a command is a local command (handled by skim)
    pub fn isLocalSlashCommand(name: []const u8) bool {
        for (local_slash_commands) |local_cmd| {
            if (std.mem.eql(u8, local_cmd.name, name)) {
                return true;
            }
        }
        return false;
    }

    /// Check if slash command menu should be shown based on input
    /// Returns true if input starts with "/" and we have commands
    pub fn shouldShowSlashMenu(self: *const AgentState) bool {
        const text = self.input.getText();
        return text.len > 0 and text[0] == '/' and self.available_commands.items.len > 0;
    }

    /// Get the filter text (everything after the "/")
    pub fn getSlashFilter(self: *const AgentState) []const u8 {
        const text = self.input.getText();
        if (text.len > 1 and text[0] == '/') {
            return text[1..];
        }
        return "";
    }

    /// Get filtered commands matching current input (fuzzy match)
    /// Returns slice of indices into available_commands
    pub fn getFilteredCommandIndices(self: *const AgentState, out_indices: []usize) usize {
        const filter = self.getSlashFilter();
        var count: usize = 0;

        for (self.available_commands.items, 0..) |cmd, idx| {
            if (count >= out_indices.len) break;

            // Match if filter is empty or fuzzy matches command name
            if (filter.len == 0 or fuzzyMatch(cmd.name, filter)) {
                out_indices[count] = idx;
                count += 1;
            }
        }

        return count;
    }

    /// Fuzzy match: check if all filter chars appear in order within the target
    fn fuzzyMatch(target: []const u8, filter: []const u8) bool {
        if (filter.len == 0) return true;
        if (filter.len > target.len) return false;

        var filter_idx: usize = 0;
        for (target) |c| {
            // Case-insensitive comparison
            const target_lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
            const filter_lower = if (filter[filter_idx] >= 'A' and filter[filter_idx] <= 'Z')
                filter[filter_idx] + 32
            else
                filter[filter_idx];

            if (target_lower == filter_lower) {
                filter_idx += 1;
                if (filter_idx >= filter.len) return true;
            }
        }
        return false;
    }

    /// Show slash menu and reset selection
    pub fn showSlashMenu(self: *AgentState) void {
        self.slash_menu_visible = true;
        self.slash_menu_selection = 0;
        self.slash_menu_scroll_offset = 0;
    }

    /// Hide slash menu
    pub fn hideSlashMenu(self: *AgentState) void {
        self.slash_menu_visible = false;
        self.slash_menu_selection = 0;
        self.slash_menu_scroll_offset = 0;
    }

    /// Move selection up in slash menu
    pub fn slashMenuUp(self: *AgentState, visible_count: usize) void {
        if (self.slash_menu_selection > 0) {
            self.slash_menu_selection -= 1;
            // Scroll up if selection goes above visible area
            if (self.slash_menu_selection < self.slash_menu_scroll_offset) {
                self.slash_menu_scroll_offset = self.slash_menu_selection;
            }
        }
        _ = visible_count; // Used by caller for bounds, we just need to follow selection
    }

    /// Move selection down in slash menu
    pub fn slashMenuDown(self: *AgentState, max_items: usize, visible_count: usize) void {
        if (max_items > 0 and self.slash_menu_selection < max_items - 1) {
            self.slash_menu_selection += 1;
            // Scroll down if selection goes below visible area
            if (visible_count > 0 and self.slash_menu_selection >= self.slash_menu_scroll_offset + visible_count) {
                self.slash_menu_scroll_offset = self.slash_menu_selection - visible_count + 1;
            }
        }
    }

    /// Get the selected command (if any) based on current filter
    pub fn getSelectedCommand(self: *AgentState) ?*const OwnedCommand {
        var indices: [32]usize = undefined;
        const count = self.getFilteredCommandIndices(&indices);

        if (count == 0) return null;

        // Clamp selection to valid range
        const selection = @min(self.slash_menu_selection, count - 1);
        return &self.available_commands.items[indices[selection]];
    }

    /// Insert the selected command into the input buffer
    /// Replaces current input with "/command "
    pub fn insertSelectedCommand(self: *AgentState) void {
        if (self.getSelectedCommand()) |cmd| {
            // Clear input and insert command
            self.input.clear();
            // Insert "/" + command name + " "
            InputEditor.insertCharPublic(&self.input, '/');
            for (cmd.name) |c| {
                InputEditor.insertCharPublic(&self.input, c);
            }
            InputEditor.insertCharPublic(&self.input, ' ');

            self.hideSlashMenu();
        }
    }

    // =========================================================================
    // Interrupt (Double-ESC)
    // =========================================================================

    /// Threshold for double-ESC detection (5 seconds in milliseconds)
    const DOUBLE_ESC_THRESHOLD_MS: i64 = 5000;

    /// Record an ESC key press and check if it's a double-ESC
    /// Returns true if this is a double-ESC (second ESC within threshold)
    pub fn recordEscPress(self: *AgentState) bool {
        const now_ms = std.time.milliTimestamp();
        const elapsed = now_ms - self.last_esc_timestamp;

        if (self.last_esc_timestamp != 0 and elapsed <= DOUBLE_ESC_THRESHOLD_MS) {
            // Double-ESC detected - reset timestamp and return true
            self.last_esc_timestamp = 0;
            return true;
        }

        // First ESC - record timestamp
        self.last_esc_timestamp = now_ms;
        return false;
    }

    /// Clear the ESC timestamp (e.g., when another key is pressed)
    pub fn clearEscTimestamp(self: *AgentState) void {
        self.last_esc_timestamp = 0;
    }

    /// Estimate memory usage of the agent state (for monitoring)
    fn estimateMemoryUsage(self: *const AgentState) usize {
        var total: usize = 0;

        // Message content
        for (self.messages.items) |msg| {
            total += msg.content.len;
            if (msg.diff_path) |p| total += p.len;
            if (msg.diff_old) |o| total += o.len;
            if (msg.diff_new) |n| total += n.len;
            if (msg.tool_call_id) |id| total += id.len;
            if (msg.tool_name) |n| total += n.len;
            if (msg.tool_command) |c| total += c.len;
            if (msg.tool_stdout) |s| total += s.len;
            if (msg.tool_stderr) |s| total += s.len;
        }

        // Plan entries
        for (self.plan_entries.items) |entry| {
            total += entry.content.len;
        }

        // Available commands
        for (self.available_commands.items) |cmd| {
            total += cmd.name.len;
            total += cmd.description.len;
            if (cmd.input_hint) |h| total += h.len;
        }

        // ArrayList overhead (rough estimate)
        total += self.messages.capacity * @sizeOf(Message);
        total += self.plan_entries.capacity * @sizeOf(OwnedPlanEntry);
        total += self.available_commands.capacity * @sizeOf(OwnedCommand);

        return total;
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
                .thinking => "Thinking",
                .system => "System",
                .diff => "Edit",
                .tool => "Tool",
                else => "",
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
