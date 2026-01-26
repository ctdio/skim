const std = @import("std");
const vaxis = @import("vaxis");
const state = @import("state.zig");
const AgentState = state.AgentState;
const Message = state.Message;
const diff_algo = @import("diff.zig");
const DiffLine = diff_algo.DiffLine;

const rendering_common = @import("../rendering/common.zig");
const Color = rendering_common.Color;

const rendering_utils = @import("../rendering/utils.zig");
const RenderUtils = rendering_utils.RenderUtils;

const highlighting = @import("../highlighting/core.zig");
pub const Highlight = highlighting.Highlight;
pub const SyntaxHighlighter = highlighting.SyntaxHighlighter;

// Markdown rendering for agent messages
const markdown = @import("markdown/markdown.zig");
const MarkdownRenderer = markdown.MarkdownRenderer;
const StyledSpan = markdown.StyledSpan;
const NodeType = markdown.NodeType;
const HighlightContext = markdown.code_blocks.HighlightContext;
const MdHighlight = markdown.code_blocks.Highlight;

const Allocator = std.mem.Allocator;

// Maximum number of diff lines to display before collapsing
const MAX_VISIBLE_DIFF_LINES: usize = 500;

// =============================================================================
// Styled Segment for inline formatting
// =============================================================================

/// A segment of text with its own style (for inline formatting like bold, code, etc.)
pub const StyledSegment = struct {
    text: []const u8,
    style: vaxis.Style,
};

// =============================================================================
// Chat Line Types
// =============================================================================

/// Type of chat line with associated metadata
pub const ChatLineType = union(enum) {
    /// Role header (e.g., "You", "Agent", "Thinking")
    role_header: struct {
        msg_idx: usize,
    },

    /// Message content line
    message_content: struct {
        msg_idx: usize,
        line_idx: usize, // Line index within wrapped message content
    },

    /// Tool header (e.g., "⏺ Bash(command)")
    tool_header: struct {
        msg_idx: usize,
    },

    /// Tool result (e.g., "↳  (No content)")
    tool_result: struct {
        msg_idx: usize,
    },

    /// Diff file header (e.g., "path/to/file.ext  +N -M")
    diff_header: struct {
        msg_idx: usize,
    },

    /// Diff hunk header (e.g., "┃       ↕ 1-10 → 1-12")
    diff_hunk_header: struct {
        msg_idx: usize,
    },

    /// Diff content line (unified or side-by-side)
    diff_line: struct {
        msg_idx: usize,
        line_idx: usize,
    },

    /// Plan snapshot entry line
    plan_entry: struct {
        msg_idx: usize,
        entry_idx: usize,
    },

    /// Blank spacer between messages
    spacer,
};

/// A single line record with pre-computed content and style
pub const ChatLineRecord = struct {
    global_line: usize,
    line_type: ChatLineType,
    text: []const u8, // Owned by ChatLineMap (used when segments is null)
    style: vaxis.Style, // Default style (used when segments is null)
    indent: usize,
    /// Multiple styled segments for inline formatting (e.g., bold, code within text)
    /// When set, overrides text/style fields for rendering
    segments: ?[]const StyledSegment = null,
    // Optional prefix for special lines
    prefix: ?[]const u8 = null,
    prefix_style: ?vaxis.Style = null,
    fill_bg: bool = false,
    // Unified diff fields
    diff_line_num: ?usize = null,
    diff_line_num_str: ?[]const u8 = null, // Pre-formatted line number string (owned)
    diff_sign: ?u8 = null,
    diff_kind: ?DiffLine.Kind = null,
    // Syntax highlighting for unified diff (byte offsets into text)
    diff_highlights: ?[]const Highlight = null,
    // Side-by-side diff fields
    sbs_left_num: ?usize = null,
    sbs_left_num_str: ?[]const u8 = null, // Pre-formatted (owned)
    sbs_left_content: ?[]const u8 = null,
    sbs_left_kind: ?SideLineKind = null,
    sbs_right_num: ?usize = null,
    sbs_right_num_str: ?[]const u8 = null, // Pre-formatted (owned)
    sbs_right_content: ?[]const u8 = null,
    sbs_right_kind: ?SideLineKind = null,
    sbs_left_width: usize = 0,
    // Syntax highlighting for side-by-side diff (byte offsets into respective content)
    sbs_left_highlights: ?[]const Highlight = null,
    sbs_right_highlights: ?[]const Highlight = null,
};

pub const SideLineKind = enum { context, add, delete, empty };

// =============================================================================
// Chat Line Map
// =============================================================================

/// Complete map of all lines in the chat
pub const ChatLineMap = struct {
    records: std.ArrayList(ChatLineRecord),
    strings: std.ArrayList([]const u8), // Owned strings to free on deinit
    highlights: std.ArrayList([]const Highlight), // Owned highlight arrays to free on deinit
    allocator: Allocator,
    wrap_width: usize, // Width used for wrapping (rebuild if changed)
    message_count: usize, // Number of messages processed (for incremental updates)
    diff_view_mode: AgentState.DiffViewMode, // Current view mode
    last_msg_start_idx: usize, // Cached index where last message starts (for O(1) streaming updates)
    last_msg_strings_start: usize, // Cached index where last message's strings start (for efficient cleanup)
    last_msg_highlights_start: usize, // Cached index where last message's highlights start
    // Reference to expanded user messages set (set during build, used for collapsed/expanded state)
    expanded_user_messages: ?*const std.AutoHashMap(usize, void),

    /// Initialize an empty chat line map
    pub fn init(allocator: Allocator) ChatLineMap {
        var self = ChatLineMap{
            .records = .{},
            .strings = .{},
            .highlights = .{},
            .allocator = allocator,
            .wrap_width = 0,
            .message_count = 0,
            .diff_view_mode = .unified,
            .last_msg_start_idx = 0,
            .last_msg_strings_start = 0,
            .last_msg_highlights_start = 0,
            .expanded_user_messages = null,
        };

        // Pre-allocate capacity to avoid cold allocation lag on first message
        // This warms up the allocator and avoids page faults on first use
        self.records.ensureTotalCapacity(allocator, 64) catch {};
        self.strings.ensureTotalCapacity(allocator, 16) catch {};

        return self;
    }

    /// Free all resources
    pub fn deinit(self: *ChatLineMap) void {
        // Free owned strings
        for (self.strings.items) |s| {
            self.allocator.free(s);
        }
        self.strings.deinit(self.allocator);
        // Free owned highlight arrays
        self.freeHighlights(0);
        self.highlights.deinit(self.allocator);
        self.records.deinit(self.allocator);
    }

    /// Free highlight arrays starting from index
    fn freeHighlights(self: *ChatLineMap, start_idx: usize) void {
        for (self.highlights.items[start_idx..]) |hl_array| {
            // Free each category string in the highlight
            for (hl_array) |h| {
                self.allocator.free(h.category);
            }
            self.allocator.free(hl_array);
        }
    }

    /// Build or rebuild the line map from messages
    pub fn build(
        self: *ChatLineMap,
        messages: []const Message,
        wrap_width: usize,
        diff_view_mode: AgentState.DiffViewMode,
        highlighter: ?*SyntaxHighlighter,
        expanded_user_messages: ?*const std.AutoHashMap(usize, void),
    ) !void {
        // Clear existing data
        for (self.strings.items) |s| {
            self.allocator.free(s);
        }
        self.strings.clearRetainingCapacity();
        self.freeHighlights(0);
        self.highlights.clearRetainingCapacity();
        self.records.clearRetainingCapacity();

        self.wrap_width = wrap_width;
        self.message_count = messages.len;
        self.diff_view_mode = diff_view_mode;
        self.last_msg_start_idx = 0;
        self.last_msg_strings_start = 0;
        self.last_msg_highlights_start = 0;
        self.expanded_user_messages = expanded_user_messages;

        // Pre-allocate capacity to reduce reallocations during build
        // Estimate: ~10 lines per message on average (header + content lines + spacing)
        //           ~3 owned strings per message (header, content chunks, tool outputs)
        const estimated_lines = messages.len * 10;
        const estimated_strings = messages.len * 3;
        try self.records.ensureTotalCapacity(self.allocator, estimated_lines);
        try self.strings.ensureTotalCapacity(self.allocator, estimated_strings);

        var global_line: usize = 0;

        for (messages, 0..) |msg, msg_idx| {
            // Track where the last message starts (for O(1) streaming updates)
            if (msg_idx == messages.len - 1) {
                self.last_msg_start_idx = self.records.items.len;
                self.last_msg_strings_start = self.strings.items.len;
                self.last_msg_highlights_start = self.highlights.items.len;
            }

            // Handle different message types
            switch (msg.role) {
                .tool => {
                    // Skip pending Edit/Write tools if a diff exists for that tool_call_id
                    if (shouldSkipToolForDiff(msg, messages)) continue;

                    // Tool header: ⏺ ToolName(args)
                    try self.addToolHeader(&global_line, msg_idx, msg);

                    // Tool result if completed/failed
                    if (msg.tool_status == .completed or msg.tool_status == .failed) {
                        try self.addToolResult(&global_line, msg_idx, msg);
                    }
                },
                .diff => {
                    // Diff content (no role header - diff has its own file header)
                    if (msg.diff_path != null and msg.diff_old != null and msg.diff_new != null) {
                        try self.addDiffContent(&global_line, msg_idx, msg, wrap_width, diff_view_mode, highlighter);
                    }
                },
                .plan_snapshot => {
                    // Plan snapshot header
                    try self.addRoleHeader(&global_line, msg_idx, msg.role);

                    // Plan entries
                    if (msg.plan_snapshot_entries) |entries| {
                        try self.addPlanSnapshotEntries(&global_line, msg_idx, entries);
                    }
                },
                .user, .agent, .thinking => {
                    // No role header for user/agent/thinking - styling makes it obvious
                    // Content lines only
                    try self.addMessageContent(&global_line, msg_idx, msg, wrap_width, highlighter);
                },
                else => {
                    // Role header for other types (system, etc.)
                    try self.addRoleHeader(&global_line, msg_idx, msg.role);

                    // Content lines
                    try self.addMessageContent(&global_line, msg_idx, msg, wrap_width, highlighter);
                },
            }

            // Spacer between messages
            try self.records.append(self.allocator, .{
                .global_line = global_line,
                .line_type = .spacer,
                .text = "",
                .style = .{},
                .indent = 0,
            });
            global_line += 1;
        }
    }

    /// Check if rebuild is needed (width changed, etc.)
    pub fn needsRebuild(self: *const ChatLineMap, wrap_width: usize, diff_view_mode: AgentState.DiffViewMode) bool {
        return self.wrap_width != wrap_width or self.diff_view_mode != diff_view_mode;
    }

    /// Update incrementally when a new message is appended
    pub fn updateForNewMessage(
        self: *ChatLineMap,
        messages: []const Message,
        wrap_width: usize,
        diff_view_mode: AgentState.DiffViewMode,
        highlighter: ?*SyntaxHighlighter,
        expanded_user_messages: ?*const std.AutoHashMap(usize, void),
    ) !void {
        // Store expanded state reference for this update
        self.expanded_user_messages = expanded_user_messages;

        // If width changed or view mode changed, full rebuild
        if (self.needsRebuild(wrap_width, diff_view_mode)) {
            try self.build(messages, wrap_width, diff_view_mode, highlighter, expanded_user_messages);
            return;
        }

        // If message count increased, add new messages
        if (messages.len > self.message_count) {
            // Don't remove the trailing spacer - it provides the visual gap between messages
            // Just continue from where we left off
            var global_line: usize = if (self.records.items.len > 0)
                self.records.items[self.records.items.len - 1].global_line + 1
            else
                0;

            // Add new messages
            for (self.message_count..messages.len) |msg_idx| {
                const msg = &messages[msg_idx];

                // Track where the last message starts (for O(1) streaming updates)
                self.last_msg_start_idx = self.records.items.len;
                self.last_msg_strings_start = self.strings.items.len;
                self.last_msg_highlights_start = self.highlights.items.len;

                switch (msg.role) {
                    .tool => {
                        // Skip pending Edit/Write tools if a diff exists for that tool_call_id
                        if (shouldSkipToolForDiff(msg.*, messages)) continue;

                        try self.addToolHeader(&global_line, msg_idx, msg.*);
                        if (msg.tool_status == .completed or msg.tool_status == .failed) {
                            try self.addToolResult(&global_line, msg_idx, msg.*);
                        }
                    },
                    .diff => {
                        try self.addRoleHeader(&global_line, msg_idx, msg.role);
                        if (msg.diff_path != null and msg.diff_old != null and msg.diff_new != null) {
                            try self.addDiffContent(&global_line, msg_idx, msg.*, wrap_width, diff_view_mode, highlighter);
                        }
                    },
                    .plan_snapshot => {
                        try self.addRoleHeader(&global_line, msg_idx, msg.role);
                        if (msg.plan_snapshot_entries) |entries| {
                            try self.addPlanSnapshotEntries(&global_line, msg_idx, entries);
                        }
                    },
                    .user, .agent, .thinking => {
                        // No role header for user/agent/thinking - styling makes it obvious
                        try self.addMessageContent(&global_line, msg_idx, msg.*, wrap_width, highlighter);
                    },
                    else => {
                        // Role header for other types (system, etc.)
                        try self.addRoleHeader(&global_line, msg_idx, msg.role);
                        try self.addMessageContent(&global_line, msg_idx, msg.*, wrap_width, highlighter);
                    },
                }

                // Spacer
                try self.records.append(self.allocator, .{
                    .global_line = global_line,
                    .line_type = .spacer,
                    .text = "",
                    .style = .{},
                    .indent = 0,
                });
                global_line += 1;
            }

            self.message_count = messages.len;
        }
    }

    /// Update when the last message content changes (streaming)
    /// Uses cached last_msg_start_idx for O(1) lookup instead of O(N) search
    pub fn updateLastMessage(
        self: *ChatLineMap,
        messages: []const Message,
        wrap_width: usize,
        diff_view_mode: AgentState.DiffViewMode,
        highlighter: ?*SyntaxHighlighter,
        expanded_user_messages: ?*const std.AutoHashMap(usize, void),
    ) !void {
        if (messages.len == 0) return;

        // Store expanded state reference for this update
        self.expanded_user_messages = expanded_user_messages;

        // If width changed, full rebuild
        if (self.needsRebuild(wrap_width, diff_view_mode)) {
            try self.build(messages, wrap_width, diff_view_mode, highlighter, expanded_user_messages);
            return;
        }

        const last_msg_idx = messages.len - 1;
        const msg = &messages[last_msg_idx];

        // Use cached index for O(1) lookup - validate it's still correct
        const idx = self.last_msg_start_idx;

        // Validate the cached index is reasonable
        if (idx <= self.records.items.len) {
            // Free strings added by the last message (O(1) using cached index)
            const strings_start = self.last_msg_strings_start;
            if (strings_start < self.strings.items.len) {
                for (self.strings.items[strings_start..]) |s| {
                    self.allocator.free(s);
                }
                self.strings.shrinkRetainingCapacity(strings_start);
            }

            // Free highlights added by the last message
            const highlights_start = self.last_msg_highlights_start;
            if (highlights_start < self.highlights.items.len) {
                self.freeHighlights(highlights_start);
                self.highlights.shrinkRetainingCapacity(highlights_start);
            }

            // Shrink records to remove last message
            self.records.shrinkRetainingCapacity(idx);

            // Re-add the last message
            var global_line: usize = if (idx > 0)
                self.records.items[idx - 1].global_line + 1
            else
                0;

            switch (msg.role) {
                .tool => {
                    // Skip pending Edit/Write tools if a diff exists for that tool_call_id
                    if (!shouldSkipToolForDiff(msg.*, messages)) {
                        try self.addToolHeader(&global_line, last_msg_idx, msg.*);
                        if (msg.tool_status == .completed or msg.tool_status == .failed) {
                            try self.addToolResult(&global_line, last_msg_idx, msg.*);
                        }
                    }
                },
                .diff => {
                    try self.addRoleHeader(&global_line, last_msg_idx, msg.role);
                    if (msg.diff_path != null and msg.diff_old != null and msg.diff_new != null) {
                        try self.addDiffContent(&global_line, last_msg_idx, msg.*, wrap_width, diff_view_mode, highlighter);
                    }
                },
                .plan_snapshot => {
                    try self.addRoleHeader(&global_line, last_msg_idx, msg.role);
                    if (msg.plan_snapshot_entries) |entries| {
                        try self.addPlanSnapshotEntries(&global_line, last_msg_idx, entries);
                    }
                },
                .user, .agent, .thinking => {
                    // No role header for user/agent/thinking - styling makes it obvious
                    try self.addMessageContent(&global_line, last_msg_idx, msg.*, wrap_width, highlighter);
                },
                else => {
                    // Role header for other types (system, etc.)
                    try self.addRoleHeader(&global_line, last_msg_idx, msg.role);
                    try self.addMessageContent(&global_line, last_msg_idx, msg.*, wrap_width, highlighter);
                },
            }

            // Spacer
            try self.records.append(self.allocator, .{
                .global_line = global_line,
                .line_type = .spacer,
                .text = "",
                .style = .{},
                .indent = 0,
            });
        } else {
            // Message not found, rebuild
            try self.build(messages, wrap_width, diff_view_mode, highlighter, self.expanded_user_messages);
        }
    }

    /// Get total number of lines
    pub fn getTotalLines(self: *const ChatLineMap) usize {
        return self.records.items.len;
    }

    /// Get line record at a specific global line number
    pub fn getLineRecord(self: *const ChatLineMap, global_line: usize) ?*const ChatLineRecord {
        if (global_line >= self.records.items.len) return null;
        return &self.records.items[global_line];
    }

    // =========================================================================
    // Private helpers
    // =========================================================================

    /// Check if a tool message should be skipped because a diff exists for it.
    /// This handles Edit/Write tools that have matching diffs, OR phantom tool
    /// messages created when tool_update arrives before tool_call (no tool_name).
    fn shouldSkipToolForDiff(msg: Message, messages: []const Message) bool {
        // First check: if we have a tool_call_id, see if any diff matches it
        // This catches phantom tool messages that have no tool_name
        if (msg.tool_call_id) |tool_id| {
            for (messages) |other| {
                if (other.role == .diff) {
                    if (other.tool_call_id) |diff_id| {
                        if (std.mem.eql(u8, diff_id, tool_id)) {
                            return true;
                        }
                    }
                }
            }
        }

        // Second check: for known Edit/Write tools, also skip if completed
        if (msg.tool_name) |name| {
            const is_edit = std.mem.startsWith(u8, name, "mcp__acp__Edit") or std.mem.eql(u8, name, "Edit");
            const is_write = std.mem.startsWith(u8, name, "mcp__acp__Write") or std.mem.eql(u8, name, "Write");
            if (is_edit or is_write) {
                // Skip completed Edit/Write tools even without a diff
                // (the diff might have arrived before the tool_call was added to state)
                if (msg.tool_status == .completed) {
                    return true;
                }
            }
        }

        return false;
    }

    fn addRoleHeader(self: *ChatLineMap, global_line: *usize, msg_idx: usize, role: Message.Role) !void {
        const style: vaxis.Style = switch (role) {
            .user => .{ .fg = Color.chat_user, .bg = Color.comment_bg, .bold = true },
            .agent => .{ .fg = Color.chat_agent, .bold = true },
            .thinking => .{ .fg = Color.dim },
            .system => .{ .fg = Color.chat_system, .bold = true },
            .diff => .{ .fg = Color.white, .bold = true },
            .tool => .{ .fg = Color.chat_tool, .bold = true },
            .plan_snapshot => .{ .fg = Color.dim, .bold = true },
        };

        // Thinking uses same indent as user (for left bar) but no background fill
        const indent: usize = if (role == .user or role == .thinking) 2 else 1;

        try self.records.append(self.allocator, .{
            .global_line = global_line.*,
            .line_type = .{ .role_header = .{ .msg_idx = msg_idx } },
            .text = role.label(),
            .style = style,
            .indent = indent,
            .fill_bg = role == .user,
        });
        global_line.* += 1;
    }

    /// Helper to check if a character is a good break point for wrapping
    fn isBreakableChar(c: u8) bool {
        return c == ' ' or c == '/' or c == '-' or c == ',' or c == ')' or c == '(' or c == '"' or c == '\'';
    }

    /// Wrap a command string into multiple lines respecting word boundaries
    /// Returns owned array of line strings (caller must free)
    fn wrapCommandString(allocator: Allocator, cmd: []const u8, max_width: usize, max_lines: usize) ![][]const u8 {
        var lines: std.ArrayList([]const u8) = .{};
        errdefer lines.deinit(allocator);

        if (cmd.len == 0) {
            try lines.append(allocator, "");
            return lines.toOwnedSlice(allocator);
        }

        var remaining = cmd;
        var line_count: usize = 0;

        while (remaining.len > 0 and line_count < max_lines) {
            // Last line or command fits in remaining space
            if (remaining.len <= max_width or line_count == max_lines - 1) {
                // If this is the last allowed line and there's more content, truncate
                if (line_count == max_lines - 1 and remaining.len > max_width) {
                    const truncated = try std.fmt.allocPrint(allocator, "{s}...", .{remaining[0..@min(max_width - 3, remaining.len)]});
                    try lines.append(allocator, truncated);
                } else {
                    try lines.append(allocator, remaining);
                }
                break;
            }

            // Find a good break point
            var break_at = max_width;
            const min_segment = max_width / 2; // Don't break too early

            // Search backwards from max_width for a breakable character
            while (break_at > min_segment) {
                if (break_at > 0 and isBreakableChar(remaining[break_at - 1])) {
                    // Break after the breakable character
                    break;
                }
                break_at -= 1;
            }

            // If no good break point found, hard break at max_width
            if (break_at <= min_segment) {
                break_at = max_width;
            }

            try lines.append(allocator, remaining[0..break_at]);
            remaining = remaining[break_at..];

            // Trim leading spaces from next line
            while (remaining.len > 0 and remaining[0] == ' ') {
                remaining = remaining[1..];
            }

            line_count += 1;
        }

        if (lines.items.len == 0) {
            try lines.append(allocator, "");
        }

        return lines.toOwnedSlice(allocator);
    }

    fn addToolHeader(self: *ChatLineMap, global_line: *usize, msg_idx: usize, msg: Message) !void {
        const tool_name = msg.tool_name orelse "Tool";
        const status_icon: []const u8 = switch (msg.tool_status) {
            .pending => "○",
            .running => "◐",
            .completed => "⏺",
            .failed => "✗",
        };
        // Text uses default color (icon is colored by render.zig)
        const text_style: vaxis.Style = .{};

        // Handle tool command with smart wrapping
        if (msg.tool_command) |cmd| {
            // For multiline commands, extract first line only
            const first_line = if (std.mem.indexOfScalar(u8, cmd, '\n')) |newline_pos|
                cmd[0..newline_pos]
            else
                cmd;

            // Calculate available width for command text
            // Format: "{icon} {tool_name}({command})"
            // Account for: status_icon (1-2 chars) + space + tool_name + "(" + ")"
            const prefix_len = status_icon.len + 1 + tool_name.len + 1; // icon + space + name + (
            const suffix_len = 1; // )

            // Calculate max width for first line
            // Use wrap_width with some safety margin
            const available_width = if (self.wrap_width > prefix_len + suffix_len + 10)
                self.wrap_width - prefix_len - suffix_len - 5 // 5 char safety margin
            else
                40; // Minimum reasonable width

            // Wrap command into lines (max 4 lines total)
            const max_lines: usize = 4;
            const wrapped_lines = try wrapCommandString(self.allocator, first_line, available_width, max_lines);
            defer self.allocator.free(wrapped_lines);

            // Generate and store lines
            for (wrapped_lines, 0..) |line, i| {
                const is_first = i == 0;
                const is_last = i == wrapped_lines.len - 1;

                const line_text = if (is_first) blk: {
                    // First line: "{icon} {tool_name}({command_part}"
                    const closing = if (is_last) ")" else "";
                    break :blk try std.fmt.allocPrint(self.allocator, "{s} {s}({s}{s}", .{
                        status_icon,
                        tool_name,
                        line,
                        closing,
                    });
                } else blk: {
                    // Continuation line: "  │      {command_part})"
                    const closing = if (is_last) ")" else "";
                    break :blk try std.fmt.allocPrint(self.allocator, "  │      {s}{s}", .{
                        line,
                        closing,
                    });
                };

                try self.strings.append(self.allocator, line_text);
                try self.records.append(self.allocator, .{
                    .global_line = global_line.*,
                    .line_type = .{ .tool_header = .{ .msg_idx = msg_idx } },
                    .text = line_text,
                    .style = text_style,
                    .indent = 1,
                });
                global_line.* += 1;
            }
        } else {
            // No command, just show icon and content
            const header_text = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{
                status_icon,
                msg.content,
            });
            try self.strings.append(self.allocator, header_text);

            try self.records.append(self.allocator, .{
                .global_line = global_line.*,
                .line_type = .{ .tool_header = .{ .msg_idx = msg_idx } },
                .text = header_text,
                .style = text_style,
                .indent = 1,
            });
            global_line.* += 1;
        }
    }

    fn addToolResult(self: *ChatLineMap, global_line: *usize, msg_idx: usize, msg: Message) !void {
        // Skip showing output for MCP file tools - they have custom diff rendering
        if (msg.tool_name) |name| {
            if (std.mem.startsWith(u8, name, "mcp__acp__Read") or
                std.mem.startsWith(u8, name, "mcp__acp__Edit") or
                std.mem.startsWith(u8, name, "mcp__acp__Write"))
            {
                return;
            }
        }

        const max_output_lines = 8;
        // Slightly brighter than dim (index 8), use a light gray
        const output_style: vaxis.Style = .{ .fg = .{ .rgb = .{ 140, 140, 140 } } };

        // For running or completed shell commands with output, show actual lines
        if (msg.tool_stdout) |stdout| {
            if (stdout.len > 0) {
                // Count total lines and find where to start (last N lines)
                var total_lines: usize = 0;
                var count_iter = std.mem.splitScalar(u8, stdout, '\n');
                while (count_iter.next()) |line| {
                    // Don't count empty trailing line
                    if (line.len == 0 and count_iter.peek() == null) continue;
                    total_lines += 1;
                }

                const skip_lines = if (total_lines > max_output_lines) total_lines - max_output_lines else 0;

                // Show truncation indicator if we're skipping lines
                if (skip_lines > 0) {
                    const truncate_text = try std.fmt.allocPrint(self.allocator, "↳ (+{d} lines)", .{skip_lines});
                    try self.strings.append(self.allocator, truncate_text);

                    try self.records.append(self.allocator, .{
                        .global_line = global_line.*,
                        .line_type = .{ .tool_result = .{ .msg_idx = msg_idx } },
                        .text = truncate_text,
                        .style = .{ .fg = Color.dim_gray },
                        .indent = 1,
                    });
                    global_line.* += 1;
                }

                // Show each line of output (only last N lines)
                // Calculate effective width for wrapping (account for indent + prefix)
                // indent: 1 char, prefix: 3 chars ("↳ " or "  ")
                const prefix_len: usize = 3;
                const indent_chars: usize = 1;
                const effective_wrap_width = if (self.wrap_width > prefix_len + indent_chars + 10)
                    self.wrap_width - prefix_len - indent_chars
                else
                    40; // Minimum reasonable width

                var iter = std.mem.splitScalar(u8, stdout, '\n');
                var line_num: usize = 0;
                var first = skip_lines == 0; // Only use ⎿ prefix if no truncation indicator
                while (iter.next()) |line| {
                    // Skip empty trailing line
                    if (line.len == 0 and iter.peek() == null) continue;

                    // Skip lines before our window
                    if (line_num < skip_lines) {
                        line_num += 1;
                        continue;
                    }
                    line_num += 1;

                    // Wrap the output line if it's too long
                    var wrapped_lines = try RenderUtils.wrapText(self.allocator, line, effective_wrap_width);
                    defer wrapped_lines.deinit(self.allocator);

                    for (wrapped_lines.items, 0..) |wrapped_segment, wrap_idx| {
                        // First wrapped segment of first output line gets "↳ ", others get "  "
                        const prefix = if (first and wrap_idx == 0) "↳ " else "  ";
                        if (wrap_idx == 0) first = false;

                        const line_text = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, wrapped_segment });
                        try self.strings.append(self.allocator, line_text);

                        try self.records.append(self.allocator, .{
                            .global_line = global_line.*,
                            .line_type = .{ .tool_result = .{ .msg_idx = msg_idx } },
                            .text = line_text,
                            .style = output_style,
                            .indent = 1,
                        });
                        global_line.* += 1;
                    }
                }
                return;
            }
        }

        // Fallback for no output or failed status
        const result_text = if (msg.tool_status == .failed) blk: {
            if (msg.tool_stderr) |stderr| {
                var stderr_iter = std.mem.splitScalar(u8, stderr, '\n');
                if (stderr_iter.next()) |first_line| {
                    const max_len = @min(first_line.len, 80);
                    break :blk try std.fmt.allocPrint(self.allocator, "↳ {s}", .{first_line[0..max_len]});
                }
            }
            break :blk try self.allocator.dupe(u8, "↳ Failed");
        } else blk: {
            break :blk try self.allocator.dupe(u8, "↳ (No content)");
        };
        try self.strings.append(self.allocator, result_text);

        try self.records.append(self.allocator, .{
            .global_line = global_line.*,
            .line_type = .{ .tool_result = .{ .msg_idx = msg_idx } },
            .text = result_text,
            .style = .{ .fg = Color.dim_gray },
            .indent = 1,
        });
        global_line.* += 1;
    }

    fn addMessageContent(self: *ChatLineMap, global_line: *usize, msg_idx: usize, msg: Message, wrap_width: usize, highlighter: ?*SyntaxHighlighter) !void {
        // For agent messages with parsed markdown, use the markdown renderer
        if (msg.role == .agent and msg.md_parser != null and msg.md_tree_valid) {
            try self.addMarkdownContent(global_line, msg_idx, msg, wrap_width, highlighter);
            return;
        }

        // Fall back to plain text rendering for non-agent messages or unparsed markdown
        try self.addPlainTextContent(global_line, msg_idx, msg, wrap_width);
    }

    /// Add plain text content without markdown rendering (used for user/thinking/system messages)
    fn addPlainTextContent(self: *ChatLineMap, global_line: *usize, msg_idx: usize, msg: Message, wrap_width: usize) !void {
        const content_style: vaxis.Style = switch (msg.role) {
            .user => .{ .fg = Color.chat_content, .bg = Color.comment_bg },
            .thinking => .{ .fg = Color.dim },
            else => .{ .fg = Color.chat_content },
        };

        const fill_bg = msg.role == .user;
        // User and thinking messages indent to make room for bar, others start at column 1 for a small margin
        const indent: usize = if (msg.role == .user or msg.role == .thinking) 2 else 1;

        // Check if user message is collapsed (default) vs expanded
        const is_user_collapsed = msg.role == .user and !self.isMessageExpanded(msg_idx);

        // Add padding at the top for user messages only
        if (msg.role == .user) {
            try self.records.append(self.allocator, .{
                .global_line = global_line.*,
                .line_type = .{ .message_content = .{ .msg_idx = msg_idx, .line_idx = 0 } },
                .text = "",
                .style = content_style,
                .indent = indent,
                .fill_bg = fill_bg,
            });
            global_line.* += 1;
        }

        // For thinking messages, trim leading newlines to avoid extra spacing
        const content = if (msg.role == .thinking)
            std.mem.trimLeft(u8, msg.content, "\n")
        else
            msg.content;

        // For collapsed user messages, show single truncated line
        if (is_user_collapsed) {
            try self.addCollapsedUserContent(global_line, msg_idx, content, content_style, indent, wrap_width);
        } else {
            // Expanded or non-user: show full content with wrapping
            try self.addExpandedContent(global_line, msg_idx, content, content_style, indent, fill_bg, wrap_width);
        }

        // Add padding at the bottom for user messages only
        if (msg.role == .user) {
            // Get current line_idx (approximation based on records added)
            const line_idx = if (is_user_collapsed) @as(usize, 2) else self.countLinesForMessage(msg_idx);
            try self.records.append(self.allocator, .{
                .global_line = global_line.*,
                .line_type = .{ .message_content = .{ .msg_idx = msg_idx, .line_idx = line_idx } },
                .text = "",
                .style = content_style,
                .indent = indent,
                .fill_bg = fill_bg,
            });
            global_line.* += 1;
        }
    }

    /// Check if a message is expanded (user messages are collapsed by default)
    fn isMessageExpanded(self: *const ChatLineMap, msg_idx: usize) bool {
        if (self.expanded_user_messages) |expanded| {
            return expanded.contains(msg_idx);
        }
        return false;
    }

    /// Add collapsed user content (up to 5 lines, with "…" on last line if truncated)
    fn addCollapsedUserContent(
        self: *ChatLineMap,
        global_line: *usize,
        msg_idx: usize,
        content: []const u8,
        style: vaxis.Style,
        indent: usize,
        wrap_width: usize,
    ) !void {
        const max_collapsed_lines: usize = 5;

        // First, wrap all content to get total line count
        var all_wrapped_lines: std.ArrayList([]const u8) = .{};
        defer all_wrapped_lines.deinit(self.allocator);

        var content_iter = std.mem.splitScalar(u8, content, '\n');
        while (content_iter.next()) |line| {
            if (line.len == 0) {
                try all_wrapped_lines.append(self.allocator, "");
            } else {
                var wrapped = try RenderUtils.wrapText(self.allocator, line, wrap_width);
                defer wrapped.deinit(self.allocator);
                for (wrapped.items) |wrapped_line| {
                    try all_wrapped_lines.append(self.allocator, wrapped_line);
                }
            }
        }

        const total_lines = all_wrapped_lines.items.len;
        const has_more = total_lines > max_collapsed_lines;
        const lines_to_show = @min(total_lines, max_collapsed_lines);

        var line_idx: usize = 1; // Start at 1 since 0 is the padding line
        for (0..lines_to_show) |i| {
            const line_text = all_wrapped_lines.items[i];
            const is_last_visible = i == lines_to_show - 1;

            // On last visible line, add "…" if there's more content
            if (is_last_visible and has_more) {
                var text_buf: [1024]u8 = undefined;
                const truncated_text = if (line_text.len > wrap_width -| 4)
                    line_text[0 .. wrap_width -| 4]
                else
                    line_text;
                const display = std.fmt.bufPrint(&text_buf, "{s} …", .{truncated_text}) catch line_text;
                const content_copy = try self.allocator.dupe(u8, display);
                try self.strings.append(self.allocator, content_copy);

                try self.records.append(self.allocator, .{
                    .global_line = global_line.*,
                    .line_type = .{ .message_content = .{ .msg_idx = msg_idx, .line_idx = line_idx } },
                    .text = content_copy,
                    .style = style,
                    .indent = indent,
                    .fill_bg = true,
                });
            } else {
                const content_copy = try self.allocator.dupe(u8, line_text);
                try self.strings.append(self.allocator, content_copy);

                try self.records.append(self.allocator, .{
                    .global_line = global_line.*,
                    .line_type = .{ .message_content = .{ .msg_idx = msg_idx, .line_idx = line_idx } },
                    .text = content_copy,
                    .style = style,
                    .indent = indent,
                    .fill_bg = true,
                });
            }
            global_line.* += 1;
            line_idx += 1;
        }
    }

    /// Add expanded content with full wrapping (existing behavior)
    fn addExpandedContent(
        self: *ChatLineMap,
        global_line: *usize,
        msg_idx: usize,
        content: []const u8,
        content_style: vaxis.Style,
        indent: usize,
        fill_bg: bool,
        wrap_width: usize,
    ) !void {
        var line_idx: usize = 1; // Start at 1 since 0 is the padding line
        var content_iter = std.mem.splitScalar(u8, content, '\n');
        while (content_iter.next()) |line| {
            if (line.len == 0) {
                try self.records.append(self.allocator, .{
                    .global_line = global_line.*,
                    .line_type = .{ .message_content = .{ .msg_idx = msg_idx, .line_idx = line_idx } },
                    .text = "",
                    .style = if (fill_bg) content_style else .{},
                    .indent = indent,
                    .fill_bg = fill_bg,
                });
                global_line.* += 1;
                line_idx += 1;
            } else {
                // Use word-aware wrapping instead of hard wrapping
                var wrapped_lines = try RenderUtils.wrapText(self.allocator, line, wrap_width);
                defer wrapped_lines.deinit(self.allocator);

                for (wrapped_lines.items) |wrapped_segment| {
                    const content_copy = try self.allocator.dupe(u8, wrapped_segment);
                    try self.strings.append(self.allocator, content_copy);

                    try self.records.append(self.allocator, .{
                        .global_line = global_line.*,
                        .line_type = .{ .message_content = .{ .msg_idx = msg_idx, .line_idx = line_idx } },
                        .text = content_copy,
                        .style = content_style,
                        .indent = indent,
                        .fill_bg = fill_bg,
                    });
                    global_line.* += 1;
                    line_idx += 1;
                }
            }
        }
    }

    /// Count lines added for a message (for line_idx calculation)
    fn countLinesForMessage(self: *const ChatLineMap, msg_idx: usize) usize {
        var count: usize = 0;
        for (self.records.items) |rec| {
            switch (rec.line_type) {
                .message_content => |mc| {
                    if (mc.msg_idx == msg_idx) count = @max(count, mc.line_idx + 1);
                },
                else => {},
            }
        }
        return count;
    }

    /// Add markdown-rendered content for agent messages
    fn addMarkdownContent(self: *ChatLineMap, global_line: *usize, msg_idx: usize, msg: Message, wrap_width: usize, highlighter: ?*SyntaxHighlighter) !void {
        const md_parser = &(msg.md_parser orelse return);

        // Create highlight context if we have a highlighter
        const highlight_ctx = if (highlighter) |hl|
            HighlightContext{ .ctx = @ptrCast(hl), .func = highlightCallback }
        else
            HighlightContext{ .ctx = null, .func = null };

        // Create renderer with highlight context for code blocks
        var renderer = MarkdownRenderer.initWithHighlighter(self.allocator, markdown.colors.default, highlight_ctx);
        defer renderer.deinit();

        const spans = renderer.render(md_parser) catch {
            // Fall back to plain text if rendering fails
            try self.addPlainTextContent(global_line, msg_idx, msg, wrap_width);
            return;
        };

        // Base indent for agent messages
        const base_indent: usize = 1;

        // Collect styled segments per line, preserving per-span styling
        var line_idx: usize = 0;
        var current_line_segments: std.ArrayList(StyledSegment) = .{};
        defer current_line_segments.deinit(self.allocator);
        var current_indent: usize = base_indent;
        var current_node_type: NodeType = .text;
        var current_line_len: usize = 0;

        for (spans) |span| {
            // Check if this span contains newlines
            var span_iter = std.mem.splitScalar(u8, span.text, '\n');
            var first_segment = true;

            while (span_iter.next()) |segment| {
                if (!first_segment) {
                    // Flush the current line before starting a new one
                    try self.flushMarkdownLine(
                        global_line,
                        msg_idx,
                        &line_idx,
                        &current_line_segments,
                        current_indent,
                        current_node_type,
                        wrap_width,
                    );

                    // Reset for new line
                    current_line_segments.clearRetainingCapacity();
                    current_indent = base_indent + span.indent;
                    current_node_type = span.node_type;
                    current_line_len = 0;
                }

                // Add segment to current line
                if (segment.len > 0) {
                    // Copy segment text for storage
                    const text_copy = try self.allocator.dupe(u8, segment);
                    try self.strings.append(self.allocator, text_copy);

                    try current_line_segments.append(self.allocator, .{
                        .text = text_copy,
                        .style = span.style,
                    });
                    current_indent = base_indent + span.indent;
                    current_node_type = span.node_type;
                    current_line_len += segment.len;
                }

                first_segment = false;
            }
        }

        // Flush any remaining content
        if (current_line_segments.items.len > 0) {
            try self.flushMarkdownLine(
                global_line,
                msg_idx,
                &line_idx,
                &current_line_segments,
                current_indent,
                current_node_type,
                wrap_width,
            );
        }
    }

    /// Flush accumulated markdown segments as a line record, with word wrapping
    fn flushMarkdownLine(
        self: *ChatLineMap,
        global_line: *usize,
        msg_idx: usize,
        line_idx: *usize,
        segments: *std.ArrayList(StyledSegment),
        indent: usize,
        node_type: NodeType,
        wrap_width: usize,
    ) !void {
        const is_code_block = node_type == .fenced_code_block or node_type == .code_block;

        if (segments.items.len == 0) {
            // Empty line - use code block background if in code block
            const empty_style: vaxis.Style = if (is_code_block)
                .{ .bg = markdown.colors.default.code_block_bg }
            else
                .{};
            try self.records.append(self.allocator, .{
                .global_line = global_line.*,
                .line_type = .{ .message_content = .{ .msg_idx = msg_idx, .line_idx = line_idx.* } },
                .text = "",
                .style = empty_style,
                .indent = indent,
                .fill_bg = is_code_block,
            });
            global_line.* += 1;
            line_idx.* += 1;
            return;
        }

        // Calculate total line length
        var total_len: usize = 0;
        for (segments.items) |seg| {
            total_len += seg.text.len;
        }

        // Calculate available width (accounting for indent)
        const available_width = if (wrap_width > indent) wrap_width - indent else wrap_width;

        // If fits on one line or is a code block (don't wrap code), output as-is
        if (total_len <= available_width or is_code_block) {
            try self.outputSegmentLine(global_line, msg_idx, line_idx, segments.items, indent, is_code_block);
            return;
        }

        // Word wrapping needed - split segments across multiple lines
        var current_line: std.ArrayList(StyledSegment) = .{};
        defer current_line.deinit(self.allocator);
        var current_width: usize = 0;

        for (segments.items) |seg| {
            // Try to fit this segment on the current line
            if (current_width + seg.text.len <= available_width) {
                // Fits entirely
                try current_line.append(self.allocator, seg);
                current_width += seg.text.len;
            } else {
                // Need to split this segment
                var remaining = seg.text;
                const remaining_style = seg.style;

                while (remaining.len > 0) {
                    const space_left = if (available_width > current_width) available_width - current_width else 0;

                    if (remaining.len <= space_left) {
                        // Rest fits on current line
                        try current_line.append(self.allocator, .{
                            .text = remaining,
                            .style = remaining_style,
                        });
                        current_width += remaining.len;
                        break;
                    }

                    // Find a good break point (word boundary)
                    var break_at: usize = space_left;

                    // Look for last space within the available space
                    if (space_left > 0) {
                        var last_space: ?usize = null;
                        for (remaining[0..space_left], 0..) |c, i| {
                            if (c == ' ') last_space = i;
                        }
                        if (last_space) |sp| {
                            break_at = sp + 1; // Include the space in current line
                        }
                    }

                    // If we couldn't find a break point and current line has content, flush it first
                    if (break_at == 0 and current_line.items.len > 0) {
                        try self.outputSegmentLine(global_line, msg_idx, line_idx, current_line.items, indent, is_code_block);
                        current_line.clearRetainingCapacity();
                        current_width = 0;
                        continue;
                    }

                    // If still no break point (very long word at start of line), force break at available width
                    if (break_at == 0) {
                        break_at = @min(available_width, remaining.len);
                        if (break_at == 0) break_at = 1; // At least one character
                    }

                    // Add portion to current line
                    if (break_at > 0 and break_at <= remaining.len) {
                        // Copy the text portion for storage
                        const text_portion = try self.allocator.dupe(u8, remaining[0..break_at]);
                        try self.strings.append(self.allocator, text_portion);

                        try current_line.append(self.allocator, .{
                            .text = text_portion,
                            .style = remaining_style,
                        });
                    }

                    // Flush current line
                    try self.outputSegmentLine(global_line, msg_idx, line_idx, current_line.items, indent, is_code_block);
                    current_line.clearRetainingCapacity();
                    current_width = 0;

                    // Skip leading spaces on new line
                    remaining = remaining[break_at..];
                    while (remaining.len > 0 and remaining[0] == ' ') {
                        remaining = remaining[1..];
                    }
                }
            }
        }

        // Flush any remaining content
        if (current_line.items.len > 0) {
            try self.outputSegmentLine(global_line, msg_idx, line_idx, current_line.items, indent, is_code_block);
        }
    }

    /// Output a single line of segments as a record
    fn outputSegmentLine(
        self: *ChatLineMap,
        global_line: *usize,
        msg_idx: usize,
        line_idx: *usize,
        segs: []const StyledSegment,
        indent: usize,
        is_code_block: bool,
    ) !void {
        if (segs.len == 0) return;

        // If only one segment, use simple text/style fields
        if (segs.len == 1) {
            try self.records.append(self.allocator, .{
                .global_line = global_line.*,
                .line_type = .{ .message_content = .{ .msg_idx = msg_idx, .line_idx = line_idx.* } },
                .text = segs[0].text,
                .style = segs[0].style,
                .indent = indent,
                .fill_bg = is_code_block,
            });
            global_line.* += 1;
            line_idx.* += 1;
            return;
        }

        // Multiple segments - store them for per-segment rendering
        const segments_copy = try self.allocator.dupe(StyledSegment, segs);

        // Calculate total text for fallback rendering
        var total_len: usize = 0;
        for (segs) |seg| {
            total_len += seg.text.len;
        }
        const combined_text = try self.allocator.alloc(u8, total_len);
        var offset: usize = 0;
        for (segs) |seg| {
            @memcpy(combined_text[offset..][0..seg.text.len], seg.text);
            offset += seg.text.len;
        }
        try self.strings.append(self.allocator, combined_text);

        try self.records.append(self.allocator, .{
            .global_line = global_line.*,
            .line_type = .{ .message_content = .{ .msg_idx = msg_idx, .line_idx = line_idx.* } },
            .text = combined_text, // Fallback for non-segment-aware rendering
            .style = segs[0].style, // Default to first segment's style
            .indent = indent,
            .segments = segments_copy,
            .fill_bg = is_code_block,
        });
        global_line.* += 1;
        line_idx.* += 1;
    }

    fn addPlanSnapshotEntries(self: *ChatLineMap, global_line: *usize, msg_idx: usize, entries: []const state.OwnedPlanEntry) !void {
        for (entries, 0..) |entry, entry_idx| {
            // Status icon with color
            const status_icon: []const u8 = switch (entry.status) {
                .pending => "○",
                .in_progress => "◉",
                .completed => "✓",
            };
            const icon_style: vaxis.Style = switch (entry.status) {
                .pending => .{ .fg = Color.dim },
                .in_progress => .{ .fg = Color.yellow, .bold = true },
                .completed => .{ .fg = Color.green },
            };

            // Content style
            const content_style: vaxis.Style = switch (entry.status) {
                .pending => .{ .fg = Color.dim },
                .in_progress => .{ .fg = Color.white },
                .completed => .{ .fg = Color.dim },
            };

            // Reference entry content directly - no copy needed
            try self.records.append(self.allocator, .{
                .global_line = global_line.*,
                .line_type = .{ .plan_entry = .{ .msg_idx = msg_idx, .entry_idx = entry_idx } },
                .text = entry.content,
                .style = content_style,
                .indent = 1,
                .prefix = status_icon,
                .prefix_style = icon_style,
            });
            global_line.* += 1;
        }
    }

    /// Find starting line number by locating text in the actual file on disk
    /// Tries new_text first (file already modified), then old_text (file not yet modified)
    /// Returns null if file can't be read or neither text found
    fn findStartingLineInFile(allocator: Allocator, file_path: []const u8, old_text: []const u8, new_text: []const u8) ?usize {
        // Try to read the file
        const file = std.fs.cwd().openFile(file_path, .{}) catch return null;
        defer file.close();

        const file_content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return null;
        defer allocator.free(file_content);

        // Try to find new_text first (file has already been modified)
        // Then fall back to old_text (file not yet modified)
        const search_text = if (new_text.len > 0 and std.mem.indexOf(u8, file_content, new_text) != null)
            new_text
        else if (old_text.len > 0)
            old_text
        else
            return 1; // Both empty, start at line 1

        const pos = std.mem.indexOf(u8, file_content, search_text) orelse return null;

        // Count newlines before this position to get line number
        var line_num: usize = 1;
        for (file_content[0..pos]) |c| {
            if (c == '\n') line_num += 1;
        }

        return line_num;
    }

    /// Parse hunk header from text to extract starting line numbers
    /// Format: @@ -old_start,old_count +new_start,new_count @@
    /// Returns null if no valid hunk header is found
    fn parseHunkHeader(text: []const u8) ?struct { old_start: usize, new_start: usize } {
        // Look for @@ marker
        const start_marker = std.mem.indexOf(u8, text, "@@") orelse return null;
        if (start_marker + 2 >= text.len) return null;

        const after_first = text[start_marker + 2 ..];
        const end_marker = std.mem.indexOf(u8, after_first, "@@") orelse return null;

        // Extract the range portion between the two @@
        const range_text = std.mem.trim(u8, after_first[0..end_marker], " \t");

        // Parse old range (-old_start,old_count)
        var tokens = std.mem.tokenizeScalar(u8, range_text, ' ');
        const old_token = tokens.next() orelse return null;
        const new_token = tokens.next() orelse return null;

        if (old_token.len < 2 or old_token[0] != '-') return null;
        if (new_token.len < 2 or new_token[0] != '+') return null;

        // Extract start numbers (before comma)
        const old_comma = std.mem.indexOfScalar(u8, old_token, ',');
        const old_start_str = if (old_comma) |idx| old_token[1..idx] else old_token[1..];
        const old_start = std.fmt.parseInt(usize, old_start_str, 10) catch return null;

        const new_comma = std.mem.indexOfScalar(u8, new_token, ',');
        const new_start_str = if (new_comma) |idx| new_token[1..idx] else new_token[1..];
        const new_start = std.fmt.parseInt(usize, new_start_str, 10) catch return null;

        return .{ .old_start = old_start, .new_start = new_start };
    }

    fn addDiffContent(
        self: *ChatLineMap,
        global_line: *usize,
        msg_idx: usize,
        msg: Message,
        wrap_width: usize,
        view_mode: AgentState.DiffViewMode,
        highlighter: ?*SyntaxHighlighter,
    ) !void {
        const path = msg.diff_path orelse return;
        const old_text = msg.diff_old orelse return;
        const new_text = msg.diff_new orelse return;

        // Highlighter is stored for use when rendering diff lines
        const hl = highlighter;

        // Try to find starting line number:
        // 1. First try parsing hunk header from message content (e.g., "@@ -150,3 +150,26 @@")
        // 2. If that fails, try to find the text in the actual file on disk
        const hunk_info = parseHunkHeader(msg.content);
        const file_start_line = if (hunk_info) |info|
            info.old_start
        else
            findStartingLineInFile(self.allocator, path, old_text, new_text);

        const old_start_line = file_start_line;
        const new_start_line = file_start_line; // Same starting point for both

        // Compute diff
        var diff_result = diff_algo.computeDiff(self.allocator, old_text, new_text, old_start_line, new_start_line) catch {
            // Fallback to just showing filename - duplicate to own the memory
            const basename_copy = try self.allocator.dupe(u8, std.fs.path.basename(path));
            try self.strings.append(self.allocator, basename_copy);

            try self.records.append(self.allocator, .{
                .global_line = global_line.*,
                .line_type = .{ .diff_header = .{ .msg_idx = msg_idx } },
                .text = basename_copy,
                .style = .{ .fg = Color.white, .bold = true },
                .indent = 0,
            });
            global_line.* += 1;
            return;
        };
        defer diff_result.deinit();

        // File header with stats
        const header_text = try std.fmt.allocPrint(self.allocator, "{s}  +{d} -{d}", .{
            path,
            diff_result.additions,
            diff_result.deletions,
        });
        try self.strings.append(self.allocator, header_text);

        try self.records.append(self.allocator, .{
            .global_line = global_line.*,
            .line_type = .{ .diff_header = .{ .msg_idx = msg_idx } },
            .text = header_text,
            .style = .{ .fg = Color.white, .bold = true },
            .indent = 0,
        });
        global_line.* += 1;

        // Compute line ranges for hunk header
        var old_start: usize = 0;
        var old_end: usize = 0;
        var new_start: usize = 0;
        var new_end: usize = 0;

        for (diff_result.lines) |line| {
            if (line.old_line_num) |n| {
                if (old_start == 0) old_start = n;
                old_end = n;
            }
            if (line.new_line_num) |n| {
                if (new_start == 0) new_start = n;
                new_end = n;
            }
        }

        // Hunk header
        const hunk_text = try std.fmt.allocPrint(self.allocator, "┃       ↕ {d}-{d} → {d}-{d}", .{
            old_start,
            old_end,
            new_start,
            new_end,
        });
        try self.strings.append(self.allocator, hunk_text);

        try self.records.append(self.allocator, .{
            .global_line = global_line.*,
            .line_type = .{ .diff_hunk_header = .{ .msg_idx = msg_idx } },
            .text = hunk_text,
            .style = .{ .fg = Color.dim },
            .indent = 0,
        });
        global_line.* += 1;

        // Show all edits with limited context (5 lines) around each change.
        // Collapse irrelevant context between non-contiguous edits.
        const context_lines: usize = 5;
        const total_diff_lines = diff_result.lines.len;

        // Build a mask of which lines to show:
        // - All change lines (add/delete)
        // - Up to context_lines before and after each change
        var show_line = try self.allocator.alloc(bool, total_diff_lines);
        defer self.allocator.free(show_line);
        @memset(show_line, false);

        // First pass: mark all change lines and their context
        for (diff_result.lines, 0..) |line, idx| {
            if (line.kind != .context) {
                // Mark this change line
                show_line[idx] = true;
                // Mark context before
                const start = if (idx > context_lines) idx - context_lines else 0;
                for (start..idx) |i| {
                    show_line[i] = true;
                }
                // Mark context after
                const end = @min(idx + context_lines + 1, total_diff_lines);
                for ((idx + 1)..end) |i| {
                    show_line[i] = true;
                }
            }
        }

        // Second pass: render lines, inserting separators where we skip
        var line_idx: usize = 0;
        var prev_shown: ?usize = null;

        switch (view_mode) {
            .unified => {
                while (line_idx < total_diff_lines) {
                    if (show_line[line_idx]) {
                        // Check if we need a separator (skipped lines between shown regions)
                        if (prev_shown) |prev| {
                            const skipped = line_idx - prev - 1;
                            if (skipped > 0) {
                                // Add separator showing how many lines were skipped
                                const sep_text = try std.fmt.allocPrint(self.allocator, "┃       ⋮ {d} lines", .{skipped});
                                try self.strings.append(self.allocator, sep_text);

                                try self.records.append(self.allocator, .{
                                    .global_line = global_line.*,
                                    .line_type = .{ .diff_line = .{ .msg_idx = msg_idx, .line_idx = line_idx } },
                                    .text = sep_text,
                                    .style = .{ .fg = Color.dim },
                                    .indent = 0,
                                });
                                global_line.* += 1;
                            }
                        }

                        // Render this line with syntax highlighting
                        try self.addUnifiedDiffLine(global_line, msg_idx, line_idx, diff_result.lines[line_idx], path, hl);
                        prev_shown = line_idx;
                    }
                    line_idx += 1;
                }
            },
            .side_by_side => {
                // For side-by-side, collect the lines to show and pass to existing function
                var lines_to_show: std.ArrayList(DiffLine) = .{};
                defer lines_to_show.deinit(self.allocator);

                while (line_idx < total_diff_lines) {
                    if (show_line[line_idx]) {
                        // Check if we need a separator
                        if (prev_shown) |prev| {
                            const skipped = line_idx - prev - 1;
                            if (skipped > 0) {
                                // Add separator showing how many lines were skipped
                                const sep_text = try std.fmt.allocPrint(self.allocator, "┃       ⋮ {d} lines", .{skipped});
                                try self.strings.append(self.allocator, sep_text);

                                try self.records.append(self.allocator, .{
                                    .global_line = global_line.*,
                                    .line_type = .{ .diff_line = .{ .msg_idx = msg_idx, .line_idx = line_idx } },
                                    .text = sep_text,
                                    .style = .{ .fg = Color.dim },
                                    .indent = 0,
                                });
                                global_line.* += 1;
                            }
                        }
                        try lines_to_show.append(self.allocator, diff_result.lines[line_idx]);
                        prev_shown = line_idx;
                    }
                    line_idx += 1;
                }

                if (lines_to_show.items.len > 0) {
                    try self.addSideBySideDiffLines(global_line, msg_idx, lines_to_show.items, wrap_width, path, hl);
                }
            },
        }
    }

    /// Add a single unified diff line with optional syntax highlighting
    fn addUnifiedDiffLine(
        self: *ChatLineMap,
        global_line: *usize,
        msg_idx: usize,
        line_idx: usize,
        diff_line: DiffLine,
        file_path: []const u8,
        highlighter: ?*SyntaxHighlighter,
    ) !void {
        const line_num: ?usize = switch (diff_line.kind) {
            .context, .delete => diff_line.old_line_num,
            .add => diff_line.new_line_num,
        };
        const line_style: vaxis.Style = switch (diff_line.kind) {
            .context => .{ .fg = Color.white },
            .add => .{ .fg = Color.white, .bg = Color.diff_add_bg },
            .delete => .{ .fg = Color.white, .bg = Color.diff_delete_bg },
        };
        const should_fill = diff_line.kind != .context;

        // Copy content since diff_result will be freed
        const content_copy = try self.allocator.dupe(u8, diff_line.content);
        try self.strings.append(self.allocator, content_copy);

        // Generate per-line syntax highlights if highlighter is available
        var line_highlights: ?[]const Highlight = null;
        if (highlighter) |hl| {
            if (diff_line.content.len > 0) {
                line_highlights = hl.highlightFile(file_path, diff_line.content) catch null;
                if (line_highlights) |h| {
                    try self.highlights.append(self.allocator, h);
                }
            }
        }

        // Pre-format line number string (owned) to avoid buffer reuse issues in render
        const line_num_str: ?[]const u8 = if (line_num) |n| blk: {
            const str = try std.fmt.allocPrint(self.allocator, "{d:>3}", .{n});
            try self.strings.append(self.allocator, str);
            break :blk str;
        } else null;

        const sign: u8 = switch (diff_line.kind) {
            .context => ' ',
            .add => '+',
            .delete => '-',
        };

        try self.records.append(self.allocator, .{
            .global_line = global_line.*,
            .line_type = .{ .diff_line = .{ .msg_idx = msg_idx, .line_idx = line_idx } },
            .text = content_copy,
            .style = line_style,
            .indent = 0,
            .fill_bg = should_fill,
            .diff_line_num = line_num,
            .diff_line_num_str = line_num_str,
            .diff_sign = sign,
            .diff_kind = diff_line.kind,
            .diff_highlights = line_highlights,
        });
        global_line.* += 1;
    }

    fn addUnifiedDiffLines(
        self: *ChatLineMap,
        global_line: *usize,
        msg_idx: usize,
        diff_lines: []const DiffLine,
        file_path: []const u8,
        highlighter: ?*SyntaxHighlighter,
    ) !void {
        for (diff_lines, 0..) |diff_line, line_idx| {
            const line_num: ?usize = switch (diff_line.kind) {
                .context, .delete => diff_line.old_line_num,
                .add => diff_line.new_line_num,
            };
            const sign: u8 = switch (diff_line.kind) {
                .context => ' ',
                .add => '+',
                .delete => '-',
            };
            const line_style: vaxis.Style = switch (diff_line.kind) {
                .context => .{ .fg = Color.white },
                .add => .{ .fg = Color.white, .bg = Color.diff_add_bg },
                .delete => .{ .fg = Color.white, .bg = Color.diff_delete_bg },
            };
            const should_fill = diff_line.kind != .context;

            // Copy content since diff_result will be freed
            const content_copy = try self.allocator.dupe(u8, diff_line.content);
            try self.strings.append(self.allocator, content_copy);

            // Generate per-line syntax highlights if highlighter is available
            var line_highlights: ?[]const Highlight = null;
            if (highlighter) |hl| {
                if (diff_line.content.len > 0) {
                    line_highlights = hl.highlightFile(file_path, diff_line.content) catch null;
                    if (line_highlights) |h| {
                        try self.highlights.append(self.allocator, h);
                    }
                }
            }

            // Pre-format line number string (owned) to avoid buffer reuse issues in render
            const line_num_str: ?[]const u8 = if (line_num) |n| blk: {
                const str = try std.fmt.allocPrint(self.allocator, "{d:>3}", .{n});
                try self.strings.append(self.allocator, str);
                break :blk str;
            } else null;

            try self.records.append(self.allocator, .{
                .global_line = global_line.*,
                .line_type = .{ .diff_line = .{ .msg_idx = msg_idx, .line_idx = line_idx } },
                .text = content_copy,
                .style = line_style,
                .indent = 0,
                .fill_bg = should_fill,
                .diff_line_num = line_num,
                .diff_line_num_str = line_num_str,
                .diff_sign = sign,
                .diff_kind = diff_line.kind,
                .diff_highlights = line_highlights,
            });
            global_line.* += 1;
        }
    }

    fn addSideBySideDiffLines(
        self: *ChatLineMap,
        global_line: *usize,
        msg_idx: usize,
        diff_lines: []const DiffLine,
        wrap_width: usize,
        file_path: []const u8,
        highlighter: ?*SyntaxHighlighter,
    ) !void {
        // Layout: "┃ NNN  content│NNN  content"
        // Left gutter: 2 (┃ ) + 3 (num) + 2 (space) = 7
        // Divider: 1
        // Right gutter: 3 (num) + 2 (space) = 5
        // Total overhead: 13
        const total_gutter: usize = 13;
        const min_content_width: usize = 15; // Minimum chars per side for readability
        const min_sbs_width = total_gutter + (min_content_width * 2);

        // Fall back to unified view if panel is too narrow for side-by-side
        if (wrap_width < min_sbs_width) {
            return self.addUnifiedDiffLines(global_line, msg_idx, diff_lines, file_path, highlighter);
        }

        const remaining = wrap_width - total_gutter;
        const left_content_width = remaining / 2;

        // Collect left and right lines
        var left_lines: std.ArrayList(SideLine) = .{};
        defer left_lines.deinit(self.allocator);
        var right_lines: std.ArrayList(SideLine) = .{};
        defer right_lines.deinit(self.allocator);

        for (diff_lines) |diff_line| {
            switch (diff_line.kind) {
                .context => {
                    try left_lines.append(self.allocator, .{
                        .content = diff_line.content,
                        .line_num = diff_line.old_line_num,
                        .kind = .context,
                    });
                    try right_lines.append(self.allocator, .{
                        .content = diff_line.content,
                        .line_num = diff_line.new_line_num,
                        .kind = .context,
                    });
                },
                .delete => {
                    try left_lines.append(self.allocator, .{
                        .content = diff_line.content,
                        .line_num = diff_line.old_line_num,
                        .kind = .delete,
                    });
                    try right_lines.append(self.allocator, .{
                        .content = "",
                        .line_num = null,
                        .kind = .empty,
                    });
                },
                .add => {
                    try left_lines.append(self.allocator, .{
                        .content = "",
                        .line_num = null,
                        .kind = .empty,
                    });
                    try right_lines.append(self.allocator, .{
                        .content = diff_line.content,
                        .line_num = diff_line.new_line_num,
                        .kind = .add,
                    });
                },
            }
        }

        // Render paired lines
        const max_lines = @max(left_lines.items.len, right_lines.items.len);
        for (0..max_lines) |i| {
            const left = if (i < left_lines.items.len) left_lines.items[i] else SideLine{ .content = "", .line_num = null, .kind = .empty };
            const right = if (i < right_lines.items.len) right_lines.items[i] else SideLine{ .content = "", .line_num = null, .kind = .empty };

            const has_change = left.kind == .delete or right.kind == .add;

            const left_kind: SideLineKind = switch (left.kind) {
                .context => .context,
                .add => .add,
                .delete => .delete,
                .empty => .empty,
            };
            const right_kind: SideLineKind = switch (right.kind) {
                .context => .context,
                .add => .add,
                .delete => .delete,
                .empty => .empty,
            };

            // Copy content
            const left_content = if (left.content.len > 0)
                try self.allocator.dupe(u8, left.content)
            else
                null;
            if (left_content) |c| try self.strings.append(self.allocator, c);

            const right_content = if (right.content.len > 0)
                try self.allocator.dupe(u8, right.content)
            else
                null;
            if (right_content) |c| try self.strings.append(self.allocator, c);

            // Generate per-line syntax highlights if highlighter is available
            var left_highlights: ?[]const Highlight = null;
            var right_highlights: ?[]const Highlight = null;
            if (highlighter) |hl| {
                if (left.content.len > 0) {
                    left_highlights = hl.highlightFile(file_path, left.content) catch null;
                    if (left_highlights) |h| {
                        try self.highlights.append(self.allocator, h);
                    }
                }
                if (right.content.len > 0) {
                    right_highlights = hl.highlightFile(file_path, right.content) catch null;
                    if (right_highlights) |h| {
                        try self.highlights.append(self.allocator, h);
                    }
                }
            }

            // Pre-format line number strings (owned) to avoid buffer reuse issues in render
            const left_num_str: ?[]const u8 = if (left.line_num) |n| blk: {
                const str = try std.fmt.allocPrint(self.allocator, "{d:>3}", .{n});
                try self.strings.append(self.allocator, str);
                break :blk str;
            } else null;

            const right_num_str: ?[]const u8 = if (right.line_num) |n| blk: {
                const str = try std.fmt.allocPrint(self.allocator, "{d:>3}", .{n});
                try self.strings.append(self.allocator, str);
                break :blk str;
            } else null;

            try self.records.append(self.allocator, .{
                .global_line = global_line.*,
                .line_type = .{ .diff_line = .{ .msg_idx = msg_idx, .line_idx = i } },
                .text = "",
                .style = .{ .fg = Color.white },
                .indent = 0,
                .fill_bg = has_change,
                .sbs_left_num = left.line_num,
                .sbs_left_num_str = left_num_str,
                .sbs_left_content = left_content,
                .sbs_left_kind = left_kind,
                .sbs_right_num = right.line_num,
                .sbs_right_num_str = right_num_str,
                .sbs_right_content = right_content,
                .sbs_right_kind = right_kind,
                .sbs_left_width = left_content_width,
                .sbs_left_highlights = left_highlights,
                .sbs_right_highlights = right_highlights,
            });
            global_line.* += 1;
        }
    }
};

const SideLine = struct {
    content: []const u8,
    line_num: ?usize,
    kind: enum { context, add, delete, empty },
};

/// Highlight callback wrapper for the markdown module
/// Wraps SyntaxHighlighter.highlightFile to be compatible with HighlightContext
fn highlightCallback(ctx: *anyopaque, path: []const u8, content: []const u8) ?[]const MdHighlight {
    const hl: *SyntaxHighlighter = @ptrCast(@alignCast(ctx));
    const highlights = hl.highlightFile(path, content) catch return null;
    // The Highlight types have identical layout, so we can safely cast
    return @ptrCast(highlights);
}

// =============================================================================
// Tests
// =============================================================================

test "ChatLineMap init and deinit" {
    const allocator = std.testing.allocator;
    var line_map = ChatLineMap.init(allocator);
    defer line_map.deinit();

    try std.testing.expectEqual(@as(usize, 0), line_map.getTotalLines());
}

test "ChatLineMap build with empty messages" {
    const allocator = std.testing.allocator;
    var line_map = ChatLineMap.init(allocator);
    defer line_map.deinit();

    const messages: []const Message = &.{};
    try line_map.build(messages, 80, .unified, null, null);

    try std.testing.expectEqual(@as(usize, 0), line_map.getTotalLines());
}
