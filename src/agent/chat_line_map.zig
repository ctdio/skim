const std = @import("std");
const vaxis = @import("vaxis");
const state = @import("state.zig");
const AgentState = state.AgentState;
const Message = state.Message;
const diff_algo = @import("diff.zig");
const DiffLine = diff_algo.DiffLine;

const rendering_common = @import("../rendering/common.zig");
const Color = rendering_common.Color;

const Allocator = std.mem.Allocator;

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

    /// Tool result (e.g., "⎿  (No content)")
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

    /// Blank spacer between messages
    spacer,
};

/// A single line record with pre-computed content and style
pub const ChatLineRecord = struct {
    global_line: usize,
    line_type: ChatLineType,
    text: []const u8, // Owned by ChatLineMap
    style: vaxis.Style,
    indent: usize,
    // Optional prefix for special lines
    prefix: ?[]const u8 = null,
    prefix_style: ?vaxis.Style = null,
    fill_bg: bool = false,
    // Unified diff fields
    diff_line_num: ?usize = null,
    diff_line_num_str: ?[]const u8 = null, // Pre-formatted line number string (owned)
    diff_sign: ?u8 = null,
    diff_kind: ?DiffLine.Kind = null,
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
};

pub const SideLineKind = enum { context, add, delete, empty };

// =============================================================================
// Chat Line Map
// =============================================================================

/// Complete map of all lines in the chat
pub const ChatLineMap = struct {
    records: std.ArrayList(ChatLineRecord),
    strings: std.ArrayList([]const u8), // Owned strings to free on deinit
    allocator: Allocator,
    wrap_width: usize, // Width used for wrapping (rebuild if changed)
    message_count: usize, // Number of messages processed (for incremental updates)
    diff_view_mode: AgentState.DiffViewMode, // Current view mode

    /// Initialize an empty chat line map
    pub fn init(allocator: Allocator) ChatLineMap {
        return .{
            .records = .{},
            .strings = .{},
            .allocator = allocator,
            .wrap_width = 0,
            .message_count = 0,
            .diff_view_mode = .unified,
        };
    }

    /// Free all resources
    pub fn deinit(self: *ChatLineMap) void {
        // Free owned strings
        for (self.strings.items) |s| {
            self.allocator.free(s);
        }
        self.strings.deinit(self.allocator);
        self.records.deinit(self.allocator);
    }

    /// Build or rebuild the line map from messages
    pub fn build(
        self: *ChatLineMap,
        messages: []const Message,
        wrap_width: usize,
        diff_view_mode: AgentState.DiffViewMode,
    ) !void {
        // Clear existing data
        for (self.strings.items) |s| {
            self.allocator.free(s);
        }
        self.strings.clearRetainingCapacity();
        self.records.clearRetainingCapacity();

        self.wrap_width = wrap_width;
        self.message_count = messages.len;
        self.diff_view_mode = diff_view_mode;

        // Pre-allocate capacity to reduce reallocations during build
        // Estimate: ~10 lines per message on average (header + content lines + spacing)
        //           ~3 owned strings per message (header, content chunks, tool outputs)
        const estimated_lines = messages.len * 10;
        const estimated_strings = messages.len * 3;
        try self.records.ensureTotalCapacity(self.allocator, estimated_lines);
        try self.strings.ensureTotalCapacity(self.allocator, estimated_strings);

        var global_line: usize = 0;

        for (messages, 0..) |msg, msg_idx| {
            // Handle different message types
            switch (msg.role) {
                .tool => {
                    // Tool header: ⏺ ToolName(args)
                    try self.addToolHeader(&global_line, msg_idx, msg);

                    // Tool result if completed/failed
                    if (msg.tool_status == .completed or msg.tool_status == .failed) {
                        try self.addToolResult(&global_line, msg_idx, msg);
                    }
                },
                .diff => {
                    // Diff header
                    try self.addRoleHeader(&global_line, msg_idx, msg.role);

                    // Diff content
                    if (msg.diff_path != null and msg.diff_old != null and msg.diff_new != null) {
                        try self.addDiffContent(&global_line, msg_idx, msg, wrap_width, diff_view_mode);
                    }
                },
                .user, .agent => {
                    // No role header for user/agent - styling makes it obvious
                    // Content lines only
                    try self.addMessageContent(&global_line, msg_idx, msg, wrap_width);
                },
                else => {
                    // Role header for other types (thinking, system, etc.)
                    try self.addRoleHeader(&global_line, msg_idx, msg.role);

                    // Content lines
                    try self.addMessageContent(&global_line, msg_idx, msg, wrap_width);
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
    ) !void {
        // If width changed or view mode changed, full rebuild
        if (self.needsRebuild(wrap_width, diff_view_mode)) {
            try self.build(messages, wrap_width, diff_view_mode);
            return;
        }

        // If message count increased, add new messages
        if (messages.len > self.message_count) {
            // Remove last spacer if present
            if (self.records.items.len > 0) {
                const last = &self.records.items[self.records.items.len - 1];
                if (last.line_type == .spacer) {
                    _ = self.records.pop();
                }
            }

            var global_line: usize = if (self.records.items.len > 0)
                self.records.items[self.records.items.len - 1].global_line + 1
            else
                0;

            // Add new messages
            for (self.message_count..messages.len) |msg_idx| {
                const msg = &messages[msg_idx];

                switch (msg.role) {
                    .tool => {
                        try self.addToolHeader(&global_line, msg_idx, msg.*);
                        if (msg.tool_status == .completed or msg.tool_status == .failed) {
                            try self.addToolResult(&global_line, msg_idx, msg.*);
                        }
                    },
                    .diff => {
                        try self.addRoleHeader(&global_line, msg_idx, msg.role);
                        if (msg.diff_path != null and msg.diff_old != null and msg.diff_new != null) {
                            try self.addDiffContent(&global_line, msg_idx, msg.*, wrap_width, diff_view_mode);
                        }
                    },
                    .user, .agent => {
                        // No role header for user/agent - styling makes it obvious
                        try self.addMessageContent(&global_line, msg_idx, msg.*, wrap_width);
                    },
                    else => {
                        // Role header for other types (thinking, system, etc.)
                        try self.addRoleHeader(&global_line, msg_idx, msg.role);
                        try self.addMessageContent(&global_line, msg_idx, msg.*, wrap_width);
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
    pub fn updateLastMessage(
        self: *ChatLineMap,
        messages: []const Message,
        wrap_width: usize,
        diff_view_mode: AgentState.DiffViewMode,
    ) !void {
        if (messages.len == 0) return;

        // If width changed, full rebuild
        if (self.needsRebuild(wrap_width, diff_view_mode)) {
            try self.build(messages, wrap_width, diff_view_mode);
            return;
        }

        const last_msg_idx = messages.len - 1;
        const msg = &messages[last_msg_idx];

        // Find where the last message starts
        var start_idx: ?usize = null;
        for (self.records.items, 0..) |record, i| {
            switch (record.line_type) {
                .role_header => |rh| if (rh.msg_idx == last_msg_idx) {
                    start_idx = i;
                    break;
                },
                .tool_header => |th| if (th.msg_idx == last_msg_idx) {
                    start_idx = i;
                    break;
                },
                .diff_header => |dh| if (dh.msg_idx == last_msg_idx) {
                    start_idx = i;
                    break;
                },
                else => {},
            }
        }

        if (start_idx) |idx| {
            // Remove lines from this message
            // First, free any owned strings from removed lines
            var i = idx;
            while (i < self.records.items.len) {
                const record = &self.records.items[i];
                // Check if this string is owned (in our strings list)
                for (self.strings.items, 0..) |s, si| {
                    if (std.mem.eql(u8, s, record.text)) {
                        self.allocator.free(s);
                        _ = self.strings.orderedRemove(si);
                        break;
                    }
                }
                i += 1;
            }

            self.records.shrinkRetainingCapacity(idx);

            // Re-add the last message
            var global_line: usize = if (idx > 0)
                self.records.items[idx - 1].global_line + 1
            else
                0;

            switch (msg.role) {
                .tool => {
                    try self.addToolHeader(&global_line, last_msg_idx, msg.*);
                    if (msg.tool_status == .completed or msg.tool_status == .failed) {
                        try self.addToolResult(&global_line, last_msg_idx, msg.*);
                    }
                },
                .diff => {
                    try self.addRoleHeader(&global_line, last_msg_idx, msg.role);
                    if (msg.diff_path != null and msg.diff_old != null and msg.diff_new != null) {
                        try self.addDiffContent(&global_line, last_msg_idx, msg.*, wrap_width, diff_view_mode);
                    }
                },
                .user, .agent => {
                    // No role header for user/agent - styling makes it obvious
                    try self.addMessageContent(&global_line, last_msg_idx, msg.*, wrap_width);
                },
                else => {
                    // Role header for other types (thinking, system, etc.)
                    try self.addRoleHeader(&global_line, last_msg_idx, msg.role);
                    try self.addMessageContent(&global_line, last_msg_idx, msg.*, wrap_width);
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
            try self.build(messages, wrap_width, diff_view_mode);
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

    fn addRoleHeader(self: *ChatLineMap, global_line: *usize, msg_idx: usize, role: Message.Role) !void {
        const style: vaxis.Style = switch (role) {
            .user => .{ .fg = Color.chat_user, .bg = Color.comment_bg, .bold = true },
            .agent => .{ .fg = Color.chat_agent, .bold = true },
            .thinking => .{ .fg = Color.chat_thinking, .italic = true },
            .system => .{ .fg = Color.chat_system, .bold = true },
            .diff => .{ .fg = Color.white, .bold = true },
            .tool => .{ .fg = Color.chat_tool, .bold = true },
        };

        try self.records.append(self.allocator, .{
            .global_line = global_line.*,
            .line_type = .{ .role_header = .{ .msg_idx = msg_idx } },
            .text = role.label(),
            .style = style,
            .indent = 1,
            .fill_bg = role == .user,
        });
        global_line.* += 1;
    }

    fn addToolHeader(self: *ChatLineMap, global_line: *usize, msg_idx: usize, msg: Message) !void {
        const tool_name = msg.tool_name orelse "Tool";
        const status_icon: []const u8 = switch (msg.tool_status) {
            .pending => "○",
            .running => "◐",
            .completed => "⏺",
            .failed => "✗",
        };
        const status_style: vaxis.Style = switch (msg.tool_status) {
            .pending => .{ .fg = .{ .index = 3 } }, // yellow
            .running => .{ .fg = .{ .index = 6 } }, // cyan
            .completed => .{ .fg = .{ .index = 2 } }, // green
            .failed => .{ .fg = .{ .index = 1 } }, // red
        };

        // Format header text
        const header_text = if (msg.tool_command) |cmd| blk: {
            const max_cmd = @min(cmd.len, 60);
            const truncated = if (cmd.len > 60) "..." else "";
            break :blk try std.fmt.allocPrint(self.allocator, "{s} {s}({s}{s})", .{
                status_icon,
                tool_name,
                cmd[0..max_cmd],
                truncated,
            });
        } else blk: {
            break :blk try std.fmt.allocPrint(self.allocator, "{s} {s}", .{
                status_icon,
                msg.content,
            });
        };
        try self.strings.append(self.allocator, header_text);

        try self.records.append(self.allocator, .{
            .global_line = global_line.*,
            .line_type = .{ .tool_header = .{ .msg_idx = msg_idx } },
            .text = header_text,
            .style = status_style,
            .indent = 1,
        });
        global_line.* += 1;
    }

    fn addToolResult(self: *ChatLineMap, global_line: *usize, msg_idx: usize, msg: Message) !void {
        const result_text = if (msg.tool_status == .failed) blk: {
            if (msg.tool_stderr) |stderr| {
                var stderr_iter = std.mem.splitScalar(u8, stderr, '\n');
                if (stderr_iter.next()) |first_line| {
                    const max_len = @min(first_line.len, 80);
                    break :blk try std.fmt.allocPrint(self.allocator, "⎿  {s}", .{first_line[0..max_len]});
                }
            }
            break :blk try self.allocator.dupe(u8, "⎿  Failed");
        } else blk: {
            if (msg.tool_stdout) |stdout| {
                if (stdout.len == 0) {
                    break :blk try self.allocator.dupe(u8, "⎿  (No content)");
                }
                var line_count: usize = 0;
                var iter = std.mem.splitScalar(u8, stdout, '\n');
                while (iter.next()) |_| line_count += 1;
                if (line_count > 1) {
                    break :blk try std.fmt.allocPrint(self.allocator, "⎿  ({d} lines)", .{line_count});
                } else {
                    const max_len = @min(stdout.len, 60);
                    const truncated = if (stdout.len > 60) "..." else "";
                    break :blk try std.fmt.allocPrint(self.allocator, "⎿  {s}{s}", .{ stdout[0..max_len], truncated });
                }
            }
            break :blk try self.allocator.dupe(u8, "⎿  Done");
        };
        try self.strings.append(self.allocator, result_text);

        try self.records.append(self.allocator, .{
            .global_line = global_line.*,
            .line_type = .{ .tool_result = .{ .msg_idx = msg_idx } },
            .text = result_text,
            .style = .{ .fg = .{ .index = 8 } }, // dim
            .indent = 1,
        });
        global_line.* += 1;
    }

    fn addMessageContent(self: *ChatLineMap, global_line: *usize, msg_idx: usize, msg: Message, wrap_width: usize) !void {
        const content_style: vaxis.Style = switch (msg.role) {
            .user => .{ .fg = Color.chat_content, .bg = Color.comment_bg },
            .thinking => .{ .fg = Color.chat_thinking, .italic = true },
            else => .{ .fg = Color.chat_content },
        };

        const fill_bg = msg.role == .user;
        // User messages indent to make room for bar, others start at column 1 for a small margin
        const indent: usize = if (msg.role == .user) 2 else 1;

        // Add padding at the top for user messages
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

        var line_idx: usize = 0;
        var content_iter = std.mem.splitScalar(u8, msg.content, '\n');
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
                var remaining = line;
                while (remaining.len > 0) {
                    const chunk_len = @min(remaining.len, wrap_width);
                    // Duplicate content to own it - message content can be freed during streaming
                    const content_copy = try self.allocator.dupe(u8, remaining[0..chunk_len]);
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
                    remaining = remaining[chunk_len..];
                }
            }
        }

        // Add padding at the bottom for user messages
        if (msg.role == .user) {
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
    ) !void {
        const path = msg.diff_path orelse return;
        const old_text = msg.diff_old orelse return;
        const new_text = msg.diff_new orelse return;

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

        // Blank line
        try self.records.append(self.allocator, .{
            .global_line = global_line.*,
            .line_type = .spacer,
            .text = "",
            .style = .{},
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

        // Diff lines
        switch (view_mode) {
            .unified => try self.addUnifiedDiffLines(global_line, msg_idx, diff_result.lines),
            .side_by_side => try self.addSideBySideDiffLines(global_line, msg_idx, diff_result.lines, wrap_width),
        }
    }

    fn addUnifiedDiffLines(
        self: *ChatLineMap,
        global_line: *usize,
        msg_idx: usize,
        diff_lines: []const DiffLine,
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
            return self.addUnifiedDiffLines(global_line, msg_idx, diff_lines);
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
    try line_map.build(messages, 80, .unified);

    try std.testing.expectEqual(@as(usize, 0), line_map.getTotalLines());
}
