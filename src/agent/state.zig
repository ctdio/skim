const std = @import("std");
const Allocator = std.mem.Allocator;
const InputEditor = @import("input_editor.zig").InputEditor;
const ChatLineMap = @import("chat_line_map.zig").ChatLineMap;
const protocol = @import("../acp/protocol.zig");
const git_files = @import("../git/files.zig");

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
    .{ .name = "clear", .description = "Clear session and start fresh", .is_local = true },
    .{ .name = "model", .description = "Switch AI model", .is_local = true },
    .{ .name = "resume", .description = "Resume previous session", .is_local = true },
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
// File Picker State
// =============================================================================

/// Maximum number of file menu items visible at once
pub const MAX_FILE_MENU_VISIBLE: usize = 10;
/// Maximum file size for embedding in ACP resource (1MB)
pub const MAX_FILE_SIZE: usize = 1024 * 1024;
/// Maximum number of filtered results
pub const MAX_FILTERED_RESULTS: usize = 1000;

/// State for the @ file picker menu
pub const FilePickerState = struct {
    allocator: Allocator,
    visible: bool,
    files: std.ArrayList([]const u8), // All files in repo (owned)
    filtered_indices: std.ArrayList(usize), // Indices into files matching filter
    filtered_paths: std.ArrayList([]const u8), // Paths from fzf (for fzf mode, not owned)
    selection: usize, // Index into filtered_indices
    scroll_offset: usize, // Scroll offset for menu pagination
    last_filter_update: i64, // Timestamp for throttling (ms)
    last_filter: [256]u8, // Cache last filter to avoid redundant updates
    last_filter_len: usize,
    fzf_available: bool, // Whether fzf binary is available
    use_fzf: bool, // Whether to use fzf for filtering

    pub fn init(allocator: Allocator) FilePickerState {
        // Use native fzf-like scoring by default (faster, no subprocess)
        // fzf subprocess can be enabled with use_fzf = true
        std.log.info("FilePickerState: using native fzf-like scoring", .{});
        return .{
            .allocator = allocator,
            .visible = false,
            .files = .{},
            .filtered_indices = .{},
            .filtered_paths = .{},
            .selection = 0,
            .scroll_offset = 0,
            .last_filter_update = 0,
            .last_filter = undefined,
            .last_filter_len = 0,
            .fzf_available = false, // Checked lazily if needed
            .use_fzf = false, // Native scoring by default (faster)
        };
    }

    /// Check if fzf binary is available (called lazily)
    pub fn checkFzfAvailable() bool {
        var child = std.process.Child.init(&.{ "fzf", "--version" }, std.heap.page_allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.stdin_behavior = .Ignore;
        _ = child.spawn() catch return false;
        const term = child.wait() catch return false;
        return term.Exited == 0;
    }

    pub fn deinit(self: *FilePickerState) void {
        for (self.files.items) |f| {
            self.allocator.free(f);
        }
        self.files.deinit(self.allocator);
        self.filtered_indices.deinit(self.allocator);
        self.filtered_paths.deinit(self.allocator);
    }

    /// Load file list from git repository
    pub fn loadFiles(self: *FilePickerState) !void {
        // Clear existing files
        for (self.files.items) |f| {
            self.allocator.free(f);
        }
        self.files.clearRetainingCapacity();
        self.filtered_indices.clearRetainingCapacity();

        // Load from git
        const files = try git_files.getAllFiles(self.allocator);
        errdefer git_files.freeFileList(self.allocator, files);

        // Transfer ownership
        for (files) |f| {
            try self.files.append(self.allocator, f);
        }
        // Free just the outer slice (inner strings now owned by self.files)
        self.allocator.free(files);

        std.log.info("FilePickerState: loaded {d} files from git", .{self.files.items.len});
    }

    /// Check if there's an active @ trigger at cursor position
    /// Returns the position info if found, null otherwise
    pub fn getActiveAtPosition(input_text: []const u8, cursor_pos: usize) ?struct { start: usize, end: usize } {
        if (input_text.len == 0 or cursor_pos == 0) return null;

        // Search backwards from cursor for @
        var at_pos: ?usize = null;
        const search_end = @min(cursor_pos, input_text.len);

        var i: usize = 0;
        while (i < search_end) : (i += 1) {
            const c = input_text[i];
            if (c == '@') {
                // Check if @ is at word boundary (start of input or after space/newline)
                if (i == 0 or input_text[i - 1] == ' ' or input_text[i - 1] == '\n' or input_text[i - 1] == '\t') {
                    at_pos = i;
                }
            } else if (c == ' ' or c == '\n' or c == '\t') {
                // Hit word boundary - if we had an @, check if cursor is still in that word
                if (at_pos != null) {
                    if (i <= cursor_pos) {
                        // Cursor is beyond this @word, reset
                        at_pos = null;
                    }
                }
            }
        }

        if (at_pos) |start| {
            // Find end (space, newline, tab, or end of string up to cursor)
            var end = start + 1;
            while (end < input_text.len and end <= cursor_pos) : (end += 1) {
                const c = input_text[end];
                if (c == ' ' or c == '\n' or c == '\t') break;
            }
            return .{ .start = start, .end = @min(end, cursor_pos) };
        }
        return null;
    }

    /// Get the filter text (everything after @ up to cursor)
    pub fn getFileFilter(input_text: []const u8, cursor_pos: usize) []const u8 {
        const active = getActiveAtPosition(input_text, cursor_pos) orelse return "";
        if (active.end <= active.start + 1) return "";
        return input_text[active.start + 1 .. active.end];
    }

    /// Check if file menu should be shown
    pub fn shouldShow(self: *const FilePickerState, input_text: []const u8, cursor_pos: usize) bool {
        return getActiveAtPosition(input_text, cursor_pos) != null and self.files.items.len > 0;
    }

    /// Update filtered indices based on current filter
    pub fn updateFilter(self: *FilePickerState, filter: []const u8) !void {
        // Check if filter changed
        const filter_changed = filter.len != self.last_filter_len or
            (filter.len > 0 and !std.mem.eql(u8, filter, self.last_filter[0..self.last_filter_len]));

        if (!filter_changed and (self.filtered_indices.items.len > 0 or self.filtered_paths.items.len > 0)) {
            return; // No update needed
        }

        // Throttle updates (50ms)
        const now = std.time.milliTimestamp();
        if (now - self.last_filter_update < 50 and self.last_filter_update != 0 and !filter_changed) {
            return;
        }
        self.last_filter_update = now;

        // Cache the filter
        const copy_len = @min(filter.len, self.last_filter.len);
        @memcpy(self.last_filter[0..copy_len], filter[0..copy_len]);
        self.last_filter_len = copy_len;

        // Clear previous results
        self.filtered_indices.clearRetainingCapacity();
        self.filtered_paths.clearRetainingCapacity();

        // Use fzf if available and filter is non-empty
        if (self.use_fzf and filter.len > 0) {
            self.updateFilterWithFzf(filter) catch {
                // Fallback to simple matching on fzf error
                self.updateFilterSimple(filter);
            };
        } else {
            self.updateFilterSimple(filter);
        }

        // Clamp selection
        const result_count = self.getFilteredCount();
        if (result_count == 0) {
            self.selection = 0;
        } else if (self.selection >= result_count) {
            self.selection = result_count - 1;
        }
    }

    /// Get the count of filtered results (works for both fzf and simple mode)
    pub fn getFilteredCount(self: *const FilePickerState) usize {
        if (self.filtered_paths.items.len > 0) {
            return self.filtered_paths.items.len;
        }
        return self.filtered_indices.items.len;
    }

    /// Update filter using fzf --filter
    fn updateFilterWithFzf(self: *FilePickerState, filter: []const u8) !void {
        if (self.files.items.len == 0) return;

        // Build hashmap for O(1) path->index lookup
        var path_to_idx = std.StringHashMap(usize).init(self.allocator);
        defer path_to_idx.deinit();
        for (self.files.items, 0..) |path, idx| {
            path_to_idx.put(path, idx) catch break;
        }

        // Build fzf command
        var child = std.process.Child.init(&.{ "fzf", "--filter", filter }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.stdin_behavior = .Pipe;

        try child.spawn();

        // Write file list to stdin
        if (child.stdin) |stdin| {
            for (self.files.items) |path| {
                stdin.writeAll(path) catch break;
                stdin.writeAll("\n") catch break;
            }
            stdin.close();
            child.stdin = null;
        }

        // Read sorted results from stdout
        if (child.stdout) |stdout| {
            // Read all output at once
            const max_output = 1024 * 1024; // 1MB max
            const output = stdout.readToEndAlloc(self.allocator, max_output) catch {
                _ = child.wait() catch {};
                return error.ReadFailed;
            };
            defer self.allocator.free(output);

            // Parse line by line - O(1) lookup per line
            var count: usize = 0;
            var iter = std.mem.splitScalar(u8, output, '\n');
            while (iter.next()) |path| {
                if (path.len == 0) continue;
                if (count >= MAX_FILTERED_RESULTS) break;

                if (path_to_idx.get(path)) |idx| {
                    try self.filtered_indices.append(self.allocator, idx);
                    count += 1;
                }
            }
        }

        _ = child.wait() catch {};
    }

    /// Update filter using fzf-like scoring (native, no subprocess)
    fn updateFilterSimple(self: *FilePickerState, filter: []const u8) void {
        if (filter.len == 0) {
            // No filter - show all files in original order
            for (self.files.items, 0..) |_, idx| {
                if (self.filtered_indices.items.len >= MAX_FILTERED_RESULTS) break;
                self.filtered_indices.append(self.allocator, idx) catch break;
            }
            return;
        }

        // Collect scored matches
        var scored: std.ArrayList(ScoredMatch) = .{};
        defer scored.deinit(self.allocator);

        for (self.files.items, 0..) |path, idx| {
            if (fuzzyScore(path, filter)) |score| {
                scored.append(self.allocator, .{ .index = idx, .score = score }) catch break;
            }
        }

        // Sort by score (highest first)
        std.mem.sort(ScoredMatch, scored.items, {}, compareScoredMatches);

        // Add to filtered indices (limited)
        for (scored.items) |match| {
            if (self.filtered_indices.items.len >= MAX_FILTERED_RESULTS) break;
            self.filtered_indices.append(self.allocator, match.index) catch break;
        }
    }

    /// Move selection up
    pub fn menuUp(self: *FilePickerState) void {
        if (self.selection > 0) {
            self.selection -= 1;
            if (self.selection < self.scroll_offset) {
                self.scroll_offset = self.selection;
            }
        }
    }

    /// Move selection down
    pub fn menuDown(self: *FilePickerState) void {
        const count = self.getFilteredCount();
        if (count > 0 and self.selection < count - 1) {
            self.selection += 1;
            if (self.selection >= self.scroll_offset + MAX_FILE_MENU_VISIBLE) {
                self.scroll_offset = self.selection - MAX_FILE_MENU_VISIBLE + 1;
            }
        }
    }

    /// Get the currently selected file path
    pub fn getSelectedFile(self: *const FilePickerState) ?[]const u8 {
        const count = self.getFilteredCount();
        if (count == 0) return null;
        const clamped_selection = @min(self.selection, count - 1);
        const file_idx = self.filtered_indices.items[clamped_selection];
        if (file_idx >= self.files.items.len) return null;
        return self.files.items[file_idx];
    }

    /// Show the menu and reset selection
    pub fn show(self: *FilePickerState) void {
        self.visible = true;
        self.selection = 0;
        self.scroll_offset = 0;
        self.last_filter_len = 0; // Force filter update
    }

    /// Hide the menu
    pub fn hide(self: *FilePickerState) void {
        self.visible = false;
        self.selection = 0;
        self.scroll_offset = 0;
    }
};

/// Fuzzy match: check if all filter chars appear in order within the target (case-insensitive)
pub fn fuzzyMatch(target: []const u8, filter: []const u8) bool {
    if (filter.len == 0) return true;
    if (filter.len > target.len) return false;

    var filter_idx: usize = 0;
    for (target) |c| {
        const target_lower = std.ascii.toLower(c);
        const filter_lower = std.ascii.toLower(filter[filter_idx]);

        if (target_lower == filter_lower) {
            filter_idx += 1;
            if (filter_idx >= filter.len) return true;
        }
    }
    return false;
}

/// fzf-like scoring constants (based on fzf's algo.go)
const SCORE_MATCH: i32 = 16;
const SCORE_GAP_START: i32 = -3;
const SCORE_GAP_EXTENSION: i32 = -1;
const BONUS_BOUNDARY: i32 = SCORE_MATCH / 2; // 8
const BONUS_CAMEL: i32 = BONUS_BOUNDARY - 1; // 7
const BONUS_CONSECUTIVE: i32 = -(SCORE_GAP_START + SCORE_GAP_EXTENSION); // 4
const BONUS_FIRST_CHAR_MULTIPLIER: i32 = 2;

/// Fuzzy match with fzf-like scoring. Returns score (higher = better match), or null if no match.
pub fn fuzzyScore(target: []const u8, filter: []const u8) ?i32 {
    if (filter.len == 0) return 0;
    if (filter.len > target.len) return null;

    var score: i32 = 0;
    var filter_idx: usize = 0;
    var prev_matched: bool = false;
    var prev_char: u8 = 0;

    for (target, 0..) |c, i| {
        const target_lower = std.ascii.toLower(c);
        const filter_lower = std.ascii.toLower(filter[filter_idx]);

        if (target_lower == filter_lower) {
            // Base match score
            score += SCORE_MATCH;

            // Bonus for word boundary (start, after /, _, -, ., space)
            const is_boundary = (i == 0) or
                prev_char == '/' or prev_char == '_' or
                prev_char == '-' or prev_char == '.' or
                prev_char == ' ';

            // Bonus for camelCase (lowercase followed by uppercase)
            const is_camel = (prev_char >= 'a' and prev_char <= 'z') and
                (c >= 'A' and c <= 'Z');

            if (is_boundary) {
                var bonus = BONUS_BOUNDARY;
                if (filter_idx == 0) bonus *= BONUS_FIRST_CHAR_MULTIPLIER;
                score += bonus;
            } else if (is_camel) {
                score += BONUS_CAMEL;
            }

            // Bonus for consecutive matches
            if (prev_matched) {
                score += BONUS_CONSECUTIVE;
            }

            prev_matched = true;
            filter_idx += 1;
            if (filter_idx >= filter.len) {
                return score;
            }
        } else {
            // Gap penalty
            if (prev_matched) {
                score += SCORE_GAP_START;
            } else if (filter_idx > 0) {
                score += SCORE_GAP_EXTENSION;
            }
            prev_matched = false;
        }
        prev_char = c;
    }

    // Didn't match all filter characters
    return null;
}

/// Scored match result for sorting
const ScoredMatch = struct {
    index: usize,
    score: i32,
};

/// Compare function for sorting scored matches (higher score first)
fn compareScoredMatches(_: void, a: ScoredMatch, b: ScoredMatch) bool {
    return a.score > b.score;
}

// =============================================================================
// Agent State
// =============================================================================

/// State for the agent UI panel.
/// Manages conversation history, input buffer, and display state.
pub const AgentState = struct {
    allocator: Allocator,
    messages: std.ArrayList(Message),
    input: InputEditor.State,
    // Prompt stashing (Ctrl+S to stash/unstash)
    stash_buffer: [8192]u8,
    stash_len: usize,
    scroll_offset: usize,
    follow_bottom: bool, // When true, auto-scroll to bottom on new messages
    visible: bool,
    panel_side: PanelSide,
    full_screen: bool,
    diff_view_mode: DiffViewMode, // View mode for inline diffs
    line_map: ChatLineMap, // Pre-computed line map for stable rendering
    line_map_dirty: bool, // True when line_map needs rebuild
    last_line_map_rebuild: i64, // Timestamp of last rebuild (ms) for throttling
    // Agent plan (todo list)
    plan_entries: std.ArrayList(OwnedPlanEntry),
    plan_visible: bool, // Whether to show the plan above input
    plan_expanded: bool, // Whether to show all plan entries (true) or limited (false)
    // Slash commands
    available_commands: std.ArrayList(OwnedCommand),
    slash_menu_visible: bool,
    slash_menu_selection: usize, // Index into filtered commands
    slash_menu_scroll_offset: usize, // Scroll offset for menu pagination
    // Input area scrolling
    input_scroll_offset: usize, // Vertical scroll offset for multi-line input
    // Interrupt tracking (double-ESC to cancel, double Ctrl+C to exit)
    last_esc_timestamp: i64, // Timestamp of last ESC press (ms since epoch)
    last_ctrl_c_timestamp: i64, // Timestamp of last Ctrl+C press (ms since epoch)
    // Viewport tracking for smart scrolling
    last_messages_viewport_height: usize, // Height of messages area from last render
    // Staged prompt (queued to send after agent completes)
    staged_prompt: [8192]u8,
    staged_prompt_len: usize,
    // File picker state for @ mentions
    file_picker: FilePickerState,
    // Shell command mode (activated by ! key)
    shell_mode: bool,
    // Queued shell command outputs (sent with next prompt)
    queued_shell_outputs: std.ArrayList(QueuedShellOutput),
    // Currently running shell command (for streaming output)
    running_shell_cmd: ?RunningShellCommand,
    // Counter for generating unique shell command tool IDs
    shell_cmd_counter: u32,

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
        var self = AgentState{
            .allocator = allocator,
            .messages = .{}, // Zig 0.15: ArrayList is unmanaged
            .input = InputEditor.State.init(),
            .stash_buffer = undefined,
            .stash_len = 0,
            .scroll_offset = 0,
            .follow_bottom = true,
            .visible = false,
            .panel_side = panel_side,
            .full_screen = true, // Default to full screen (toggle with 'z')
            .diff_view_mode = .unified, // Default to unified view
            .line_map = ChatLineMap.init(allocator),
            .line_map_dirty = true,
            .last_line_map_rebuild = 0,
            .plan_entries = .{},
            .plan_visible = true, // Show plan by default when entries exist
            .plan_expanded = false, // Default to collapsed (Ctrl+T to expand)
            .available_commands = .{},
            .slash_menu_visible = false,
            .slash_menu_selection = 0,
            .slash_menu_scroll_offset = 0,
            .input_scroll_offset = 0,
            .last_esc_timestamp = 0,
            .last_ctrl_c_timestamp = 0,
            .last_messages_viewport_height = 20, // Reasonable default
            .staged_prompt = undefined,
            .staged_prompt_len = 0,
            .file_picker = FilePickerState.init(allocator),
            .shell_mode = false,
            .queued_shell_outputs = .{},
            .running_shell_cmd = null,
            .shell_cmd_counter = 0,
        };

        // Pre-allocate capacity to avoid cold allocation lag on first message/tool
        self.messages.ensureTotalCapacity(allocator, 32) catch {};
        self.available_commands.ensureTotalCapacity(allocator, 16) catch {};

        return self;
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
        self.file_picker.deinit();
        for (self.queued_shell_outputs.items) |*output| {
            output.deinit(self.allocator);
        }
        self.queued_shell_outputs.deinit(self.allocator);
        if (self.running_shell_cmd) |*cmd| {
            cmd.deinit();
        }
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

        // Auto-scroll only if in follow mode
        if (self.follow_bottom) {
            self.scrollToBottom();
        }
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

        // Auto-scroll only if in follow mode
        if (self.follow_bottom) {
            self.scrollToBottom();
        }
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

        // Use content_buffer for O(1) amortized appends during streaming
        if (last.content_buffer.capacity == 0) {
            // First append - initialize buffer with existing content
            try last.content_buffer.appendSlice(self.allocator, last.content);
            // Free the original content slice since buffer now owns the data
            self.allocator.free(last.content);
        }

        // Append new text to buffer (O(1) amortized)
        try last.content_buffer.appendSlice(self.allocator, text);

        // Update content to point to buffer's items
        last.content = last.content_buffer.items;

        // Mark line map dirty for streaming update
        self.line_map_dirty = true;

        // Auto-scroll only if in follow mode
        if (self.follow_bottom) {
            self.scrollToBottom();
        }
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

        // Use content_buffer for O(1) amortized appends during streaming
        if (last.content_buffer.capacity == 0) {
            // First append - initialize buffer with existing content
            try last.content_buffer.appendSlice(self.allocator, last.content);
            // Free the original content slice since buffer now owns the data
            self.allocator.free(last.content);
        }

        // Append new text to buffer (O(1) amortized)
        try last.content_buffer.appendSlice(self.allocator, text);

        // Update content to point to buffer's items
        last.content = last.content_buffer.items;

        // Mark line map dirty for streaming update
        self.line_map_dirty = true;

        // Auto-scroll only if in follow mode
        if (self.follow_bottom) {
            self.scrollToBottom();
        }
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
                        // Mark dirty and scroll only if in follow mode
                        self.line_map_dirty = true;
                        if (self.follow_bottom) {
                            self.scrollToBottom();
                        }
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

        // Auto-scroll only if in follow mode
        if (self.follow_bottom) {
            self.scrollToBottom();
        }
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

                        // Auto-scroll only if in follow mode
                        if (self.follow_bottom) {
                            self.scrollToBottom();
                        }
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

    // =========================================================================
    // Prompt Stashing
    // =========================================================================

    /// Stash the current input prompt
    pub fn stashPrompt(self: *AgentState) void {
        const text = self.input.getText();
        const copy_len = @min(text.len, self.stash_buffer.len);
        @memcpy(self.stash_buffer[0..copy_len], text[0..copy_len]);
        self.stash_len = copy_len;
    }

    /// Unstash the saved prompt into input
    pub fn unstashPrompt(self: *AgentState) void {
        if (self.stash_len > 0) {
            self.input.setText(self.stash_buffer[0..self.stash_len]);
        }
    }

    /// Clear the stash buffer
    pub fn clearStash(self: *AgentState) void {
        self.stash_len = 0;
    }

    /// Check if stash has content
    pub fn hasStash(self: *const AgentState) bool {
        return self.stash_len > 0;
    }

    /// Update scroll offset after rendering (to get actual clamped value)
    pub fn updateScrollOffset(self: *AgentState, actual_offset: usize, max_offset: usize) void {
        self.scroll_offset = actual_offset;
        // Re-enable follow mode if scrolled to the bottom
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
    /// Throttles rebuilds to ~30fps to keep UI responsive during streaming
    pub fn ensureLineMap(self: *AgentState, wrap_width: usize) !*const ChatLineMap {
        const needs_rebuild = self.line_map_dirty or self.line_map.needsRebuild(wrap_width, self.diff_view_mode);

        if (needs_rebuild) {
            const now = std.time.milliTimestamp();
            const elapsed = now - self.last_line_map_rebuild;

            // Throttle rebuilds to every 32ms (~30fps) during streaming
            // Always rebuild if it's been long enough or this is the first build
            if (elapsed >= 32 or self.last_line_map_rebuild == 0) {
                try self.line_map.build(self.messages.items, wrap_width, self.diff_view_mode);
                self.line_map_dirty = false;
                self.last_line_map_rebuild = now;
            }
            // Otherwise skip rebuild this frame - use stale line map
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

        // Create a snapshot message for the chat
        try self.addPlanSnapshotMessage();
    }

    /// Add a plan snapshot message to the chat history
    fn addPlanSnapshotMessage(self: *AgentState) !void {
        // Skip if no plan entries
        if (self.plan_entries.items.len == 0) return;

        std.log.debug("addPlanSnapshotMessage: creating snapshot with {d} entries", .{self.plan_entries.items.len});

        // Create a copy of all plan entries for the snapshot
        const snapshot_entries = try self.allocator.alloc(OwnedPlanEntry, self.plan_entries.items.len);
        errdefer self.allocator.free(snapshot_entries);

        for (self.plan_entries.items, 0..) |entry, i| {
            const content_copy = try self.allocator.dupe(u8, entry.content);
            errdefer {
                // Clean up any entries we've already copied on error
                for (snapshot_entries[0..i]) |*copied| {
                    self.allocator.free(copied.content);
                }
                self.allocator.free(content_copy);
            }

            snapshot_entries[i] = .{
                .content = content_copy,
                .priority = entry.priority,
                .status = entry.status,
            };
        }

        // Add message with snapshot (content must be heap-allocated for deinit)
        const owned_content = try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(owned_content);

        try self.messages.append(self.allocator, .{
            .role = .plan_snapshot,
            .content = owned_content,
            .timestamp = std.time.timestamp(),
            .plan_snapshot_entries = snapshot_entries,
        });

        // Mark line map dirty
        self.line_map_dirty = true;

        std.log.debug("addPlanSnapshotMessage: added snapshot, total messages now {d}", .{self.messages.items.len});

        // Auto-scroll only if in follow mode
        if (self.follow_bottom) {
            self.scrollToBottom();
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

    /// Get the filter text (command name only, up to first space after "/")
    /// For "/status-update since last week", returns "status-update"
    pub fn getSlashFilter(self: *const AgentState) []const u8 {
        const text = self.input.getText();
        if (text.len > 1 and text[0] == '/') {
            const after_slash = text[1..];
            // Find first space - only filter on command name, not arguments
            if (std.mem.indexOfScalar(u8, after_slash, ' ')) |space_idx| {
                return after_slash[0..space_idx];
            }
            return after_slash;
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
    // Interrupt (Double-ESC, Double Ctrl+C)
    // =========================================================================

    /// Threshold for double-key detection (5 seconds in milliseconds)
    const DOUBLE_KEY_THRESHOLD_MS: i64 = 5000;

    /// Record an ESC key press and check if it's a double-ESC
    /// Returns true if this is a double-ESC (second ESC within threshold)
    pub fn recordEscPress(self: *AgentState) bool {
        const now_ms = std.time.milliTimestamp();
        const elapsed = now_ms - self.last_esc_timestamp;

        if (self.last_esc_timestamp != 0 and elapsed <= DOUBLE_KEY_THRESHOLD_MS) {
            // Double-ESC detected - reset timestamp and return true
            self.last_esc_timestamp = 0;
            return true;
        }

        // First ESC - record timestamp
        self.last_esc_timestamp = now_ms;
        return false;
    }

    /// Record a Ctrl+C key press and check if it's a double Ctrl+C
    /// Returns true if this is a double Ctrl+C (second Ctrl+C within threshold)
    pub fn recordCtrlCPress(self: *AgentState) bool {
        const now_ms = std.time.milliTimestamp();
        const elapsed = now_ms - self.last_ctrl_c_timestamp;

        if (self.last_ctrl_c_timestamp != 0 and elapsed <= DOUBLE_KEY_THRESHOLD_MS) {
            // Double Ctrl+C detected - reset timestamp and return true
            self.last_ctrl_c_timestamp = 0;
            return true;
        }

        // First Ctrl+C - record timestamp
        self.last_ctrl_c_timestamp = now_ms;
        return false;
    }

    /// Clear the ESC timestamp (e.g., when another key is pressed)
    pub fn clearEscTimestamp(self: *AgentState) void {
        self.last_esc_timestamp = 0;
    }

    /// Clear the Ctrl+C timestamp (e.g., when another key is pressed)
    pub fn clearCtrlCTimestamp(self: *AgentState) void {
        self.last_ctrl_c_timestamp = 0;
    }

    // =========================================================================
    // Shell Command Mode
    // =========================================================================

    /// Toggle shell command mode on/off
    pub fn toggleShellMode(self: *AgentState) void {
        self.shell_mode = !self.shell_mode;
    }

    /// Check if in shell command mode
    pub fn isShellMode(self: *const AgentState) bool {
        return self.shell_mode;
    }

    /// Clear shell mode (e.g., after submitting a command)
    pub fn clearShellMode(self: *AgentState) void {
        self.shell_mode = false;
    }

    /// Queue a shell command output to be sent with next prompt
    pub fn queueShellOutput(self: *AgentState, content: []const u8) !void {
        const owned_content = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(owned_content);
        try self.queued_shell_outputs.append(self.allocator, .{
            .content = owned_content,
        });
    }

    /// Check if there are queued shell outputs
    pub fn hasQueuedShellOutputs(self: *const AgentState) bool {
        return self.queued_shell_outputs.items.len > 0;
    }

    /// Take all queued shell outputs (caller owns returned slice, must free)
    /// Returns null on allocation failure or if empty
    pub fn takeQueuedShellOutputs(self: *AgentState) ?[]QueuedShellOutput {
        if (self.queued_shell_outputs.items.len == 0) return null;
        return self.queued_shell_outputs.toOwnedSlice(self.allocator) catch null;
    }

    /// Clear all queued shell outputs
    pub fn clearQueuedShellOutputs(self: *AgentState) void {
        for (self.queued_shell_outputs.items) |*output| {
            output.deinit(self.allocator);
        }
        self.queued_shell_outputs.clearRetainingCapacity();
    }

    /// Check if a shell command is currently running
    pub fn hasRunningShellCommand(self: *const AgentState) bool {
        return self.running_shell_cmd != null;
    }

    /// Get next unique shell command tool ID
    pub fn nextShellCmdId(self: *AgentState, buf: []u8) []const u8 {
        self.shell_cmd_counter +%= 1;
        return std.fmt.bufPrint(buf, "shell_{d}", .{self.shell_cmd_counter}) catch "shell_cmd";
    }

    /// Get the last N lines of running command output for display
    pub fn getRunningCommandOutput(self: *const AgentState, max_lines: usize) ?[]const u8 {
        if (self.running_shell_cmd) |*cmd| {
            return cmd.getLastLines(max_lines);
        }
        return null;
    }

    /// Estimate memory usage of the agent state (for monitoring)

    // =========================================================================
    // Staged Prompt (Message Queuing)
    // =========================================================================

    /// Stage a prompt to be sent after the agent completes its current turn
    pub fn stagePrompt(self: *AgentState, text: []const u8) void {
        const copy_len = @min(text.len, self.staged_prompt.len);
        @memcpy(self.staged_prompt[0..copy_len], text[0..copy_len]);
        self.staged_prompt_len = copy_len;
    }

    /// Check if there's a staged prompt
    pub fn hasStagedPrompt(self: *const AgentState) bool {
        return self.staged_prompt_len > 0;
    }

    /// Get the staged prompt text
    pub fn getStagedPrompt(self: *const AgentState) []const u8 {
        return self.staged_prompt[0..self.staged_prompt_len];
    }

    /// Clear the staged prompt
    pub fn clearStagedPrompt(self: *AgentState) void {
        self.staged_prompt_len = 0;
    }

    /// Take the staged prompt (returns it and clears it)
    pub fn takeStagedPrompt(self: *AgentState) ?[]const u8 {
        if (self.staged_prompt_len == 0) return null;
        const text = self.staged_prompt[0..self.staged_prompt_len];
        self.staged_prompt_len = 0;
        return text;
    }
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
    content: []const u8, // Owned by AgentState (or points to content_buffer.items if streaming)
    timestamp: i64,
    // For streaming content - allows O(1) amortized appends instead of O(n) copy each time
    content_buffer: std.ArrayListUnmanaged(u8) = .{},
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
    // For plan snapshot messages
    plan_snapshot_entries: ?[]const OwnedPlanEntry = null,

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
        plan_snapshot, // Todo list snapshot

        pub fn label(self: Role) []const u8 {
            return switch (self) {
                .thinking => "Thinking",
                .system => "System",
                .tool => "Tool",
                .plan_snapshot => "Todos",
                else => "",
            };
        }
    };

    pub fn deinit(self: *Message, allocator: Allocator) void {
        // If content_buffer was used (streaming), free it; otherwise free the content slice
        if (self.content_buffer.capacity > 0) {
            self.content_buffer.deinit(allocator);
        } else {
            allocator.free(self.content);
        }
        if (self.diff_path) |p| allocator.free(p);
        if (self.diff_old) |o| allocator.free(o);
        if (self.diff_new) |n| allocator.free(n);
        if (self.tool_call_id) |id| allocator.free(id);
        if (self.tool_name) |n| allocator.free(n);
        if (self.tool_command) |c| allocator.free(c);
        if (self.tool_stdout) |s| allocator.free(s);
        if (self.tool_stderr) |s| allocator.free(s);
        if (self.plan_snapshot_entries) |entries| {
            for (entries) |*entry| {
                // Each entry owns its content
                allocator.free(entry.content);
            }
            allocator.free(entries);
        }
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

// =============================================================================
// File Picker Tests
// =============================================================================

test "fuzzyMatch basic" {
    try std.testing.expect(fuzzyMatch("src/main.zig", "main"));
    try std.testing.expect(fuzzyMatch("src/main.zig", "smz"));
    try std.testing.expect(fuzzyMatch("src/main.zig", "src"));
    try std.testing.expect(fuzzyMatch("src/main.zig", ""));
    try std.testing.expect(!fuzzyMatch("src/main.zig", "xyz"));
    try std.testing.expect(!fuzzyMatch("short", "longer"));
}

test "fuzzyMatch case insensitive" {
    try std.testing.expect(fuzzyMatch("README.md", "readme"));
    try std.testing.expect(fuzzyMatch("README.md", "README"));
    try std.testing.expect(fuzzyMatch("CamelCase.ts", "cc"));
    try std.testing.expect(fuzzyMatch("CamelCase.ts", "CC"));
}

test "getActiveAtPosition basic" {
    // @ at start
    const pos1 = FilePickerState.getActiveAtPosition("@src", 4);
    try std.testing.expect(pos1 != null);
    try std.testing.expectEqual(@as(usize, 0), pos1.?.start);
    try std.testing.expectEqual(@as(usize, 4), pos1.?.end);

    // @ after space
    const pos2 = FilePickerState.getActiveAtPosition("check @foo", 10);
    try std.testing.expect(pos2 != null);
    try std.testing.expectEqual(@as(usize, 6), pos2.?.start);
    try std.testing.expectEqual(@as(usize, 10), pos2.?.end);

    // No @ - should return null
    const pos3 = FilePickerState.getActiveAtPosition("no at symbol", 12);
    try std.testing.expect(pos3 == null);
}

test "getActiveAtPosition email addresses should not trigger" {
    // email@domain.com - @ is not at word boundary
    const pos = FilePickerState.getActiveAtPosition("user@example.com", 16);
    try std.testing.expect(pos == null);
}

test "getActiveAtPosition multiple @ uses closest to cursor" {
    // "check @file1 and @file2" with cursor at position 23
    const input = "check @file1 and @file2";
    const pos = FilePickerState.getActiveAtPosition(input, 23);
    try std.testing.expect(pos != null);
    try std.testing.expectEqual(@as(usize, 17), pos.?.start); // Second @
}

test "getFileFilter extracts filter text" {
    try std.testing.expectEqualStrings("src/m", FilePickerState.getFileFilter("@src/m", 6));
    try std.testing.expectEqualStrings("foo", FilePickerState.getFileFilter("check @foo", 10));
    try std.testing.expectEqualStrings("", FilePickerState.getFileFilter("@", 1));
    try std.testing.expectEqualStrings("", FilePickerState.getFileFilter("no at", 5));
}

test "fuzzyScore returns null for non-matches" {
    try std.testing.expect(fuzzyScore("hello", "xyz") == null);
    try std.testing.expect(fuzzyScore("abc", "abcd") == null); // filter longer than target
}

test "fuzzyScore returns score for matches" {
    // Basic match
    const score1 = fuzzyScore("hello", "hlo");
    try std.testing.expect(score1 != null);
    try std.testing.expect(score1.? > 0);

    // Empty filter always matches with score 0
    try std.testing.expectEqual(@as(?i32, 0), fuzzyScore("anything", ""));
}

test "fuzzyScore prefers word boundary matches" {
    // "src/main.zig" with filter "m" should score higher matching at boundary
    const score_boundary = fuzzyScore("src/main.zig", "m").?;
    const score_middle = fuzzyScore("something", "m").?;

    // Boundary match (after /) should score higher
    try std.testing.expect(score_boundary > score_middle);
}

test "fuzzyScore prefers consecutive matches" {
    // Consecutive "mai" in "main" vs scattered "m.a.i"
    const score_consecutive = fuzzyScore("main.zig", "mai").?;
    const score_scattered = fuzzyScore("m_a_i.txt", "mai").?;

    // Consecutive should score higher
    try std.testing.expect(score_consecutive > score_scattered);
}

test "fuzzyScore case insensitive" {
    const score1 = fuzzyScore("README.md", "read");
    const score2 = fuzzyScore("readme.md", "READ");

    try std.testing.expect(score1 != null);
    try std.testing.expect(score2 != null);
}
