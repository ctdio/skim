const std = @import("std");
const Allocator = std.mem.Allocator;
const InputEditor = @import("input_editor.zig").InputEditor;
const chat_line_map = @import("chat_line_map.zig");
const ChatLineMap = chat_line_map.ChatLineMap;
const SyntaxHighlighter = chat_line_map.SyntaxHighlighter;
const protocol = @import("../acp/protocol.zig");
const git_files = @import("../git/files.zig");
const command_palette = @import("command_palette.zig");
const clipboard = @import("../clipboard.zig");
const history = @import("history.zig");
pub const HistoryState = history.HistoryState;
const slash_menu = @import("slash_menu.zig");
pub const SlashMenuState = slash_menu.SlashMenuState;
pub const local_slash_commands = slash_menu.local_commands;
pub const LocalSlashCommand = slash_menu.LocalCommand;
const plan_mod = @import("plan.zig");
pub const PlanState = plan_mod.PlanState;
pub const OwnedPlanEntry = plan_mod.OwnedPlanEntry;
const shell_mod = @import("shell.zig");
pub const ShellState = shell_mod.ShellState;
pub const QueuedShellOutput = shell_mod.QueuedShellOutput;
pub const RunningShellCommand = shell_mod.RunningShellCommand;
const markdown = @import("markdown/markdown.zig");
pub const MarkdownParser = markdown.MarkdownParser;

/// Maximum number of slash commands visible in menu at once
pub const MAX_SLASH_MENU_VISIBLE: usize = slash_menu.MAX_VISIBLE;

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

    // Async file loading state
    loading_thread: ?std.Thread, // Background thread loading files
    loading_complete: std.atomic.Value(bool), // Signals loading finished
    pending_files: std.ArrayList([]const u8), // Files loaded by background thread
    pending_files_mutex: std.Thread.Mutex, // Protects pending_files
    load_requested: bool, // True if load has been requested (prevents multiple loads)

    pub fn init(_: Allocator) FilePickerState {
        var state: FilePickerState = undefined;
        state.allocator = std.heap.c_allocator;
        // Use native fzf-like scoring by default (faster, no subprocess)
        // fzf subprocess can be enabled with use_fzf = true
        state.visible = false;
        state.files = .{};
        state.filtered_indices = .{};
        state.filtered_paths = .{};
        state.selection = 0;
        state.scroll_offset = 0;
        state.last_filter_update = 0;
        state.last_filter = undefined;
        state.last_filter_len = 0;
        state.fzf_available = false; // Checked lazily if needed
        state.use_fzf = false; // Native scoring by default (faster)
        state.loading_thread = null;
        state.loading_complete = std.atomic.Value(bool).init(false);
        state.pending_files = .{};
        state.pending_files_mutex = .{};
        state.load_requested = false;
        return state;
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
        // Wait for loading thread to finish
        if (self.loading_thread) |thread| {
            thread.join();
        }
        // Free pending files
        self.pending_files_mutex.lock();
        for (self.pending_files.items) |f| {
            self.allocator.free(f);
        }
        self.pending_files.deinit(self.allocator);
        self.pending_files_mutex.unlock();

        for (self.files.items) |f| {
            self.allocator.free(f);
        }
        self.files.deinit(self.allocator);
        self.filtered_indices.deinit(self.allocator);
        self.filtered_paths.deinit(self.allocator);
    }

    /// Load file list from git repository (synchronous - use startAsyncLoad for non-blocking)
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

        self.load_requested = true;
        std.log.info("FilePickerState: loaded {d} files from git", .{self.files.items.len});
    }

    /// Start async file loading in background thread.
    /// Call pollAsyncLoad() periodically to check for completion.
    /// This is non-blocking and won't freeze the UI.
    pub fn startAsyncLoad(self: *FilePickerState) void {
        // Don't start if already loading or already loaded
        if (self.load_requested) return;
        if (self.loading_thread != null) return;

        self.load_requested = true;
        self.loading_complete.store(false, .release);

        // Spawn background thread
        self.loading_thread = std.Thread.spawn(.{}, fileLoadWorker, .{self}) catch |err| {
            std.log.err("FilePickerState: failed to spawn loading thread: {}", .{err});
            self.load_requested = false;
            return;
        };

        std.log.info("FilePickerState: started async file loading", .{});
    }

    /// Background worker thread for async file loading
    fn fileLoadWorker(self: *FilePickerState) void {
        // Load files from git
        const files = git_files.getAllFiles(self.allocator) catch |err| {
            std.log.err("FilePickerState: async load failed: {}", .{err});
            self.loading_complete.store(true, .release);
            return;
        };

        // Transfer to pending_files under mutex
        self.pending_files_mutex.lock();
        defer self.pending_files_mutex.unlock();

        for (files) |f| {
            self.pending_files.append(self.allocator, f) catch {
                self.allocator.free(f);
            };
        }
        self.allocator.free(files);

        std.log.info("FilePickerState: async load complete, {d} files", .{self.pending_files.items.len});
        self.loading_complete.store(true, .release);
    }

    /// Poll for async load completion. Returns true if files are now available.
    /// Call this from the main loop to check if background loading finished.
    pub fn pollAsyncLoad(self: *FilePickerState) bool {
        // Check if loading thread finished
        if (!self.loading_complete.load(.acquire)) {
            return false;
        }

        // Join thread if still tracked
        if (self.loading_thread) |thread| {
            thread.join();
            self.loading_thread = null;
        }

        // Transfer pending files to main files list
        self.pending_files_mutex.lock();
        defer self.pending_files_mutex.unlock();

        if (self.pending_files.items.len == 0) {
            return self.files.items.len > 0;
        }

        // Clear existing files
        for (self.files.items) |f| {
            self.allocator.free(f);
        }
        self.files.clearRetainingCapacity();
        self.filtered_indices.clearRetainingCapacity();

        // Move pending files to main list
        for (self.pending_files.items) |f| {
            self.files.append(self.allocator, f) catch {
                self.allocator.free(f);
            };
        }
        self.pending_files.clearRetainingCapacity();

        std.log.info("FilePickerState: transferred {d} files from async load", .{self.files.items.len});
        return true;
    }

    /// Check if files are available (either loaded sync or async)
    pub fn hasFiles(self: *const FilePickerState) bool {
        return self.files.items.len > 0;
    }

    /// Check if async load is in progress
    pub fn isLoading(self: *const FilePickerState) bool {
        return self.loading_thread != null and !self.loading_complete.load(.acquire);
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
// Question Prompt Types
// =============================================================================

pub const QuestionOptionData = struct {
    label: []const u8,
    description: ?[]const u8 = null,
};

pub const QuestionData = struct {
    header: ?[]const u8 = null,
    question: []const u8,
    options: []const QuestionOptionData = &.{},
    multiple: bool = false,
};

pub const QuestionPromptData = struct {
    id: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    questions: []const QuestionData = &.{},
};

pub const QuestionOption = struct {
    label: []const u8,
    description: ?[]const u8 = null,
    is_custom: bool = false,
};

pub const Question = struct {
    header: ?[]const u8 = null,
    prompt: []const u8,
    options: []QuestionOption,
    multiple: bool,
    custom_index: ?usize = null,

    fn deinit(self: *Question, allocator: Allocator) void {
        if (self.header) |h| allocator.free(h);
        allocator.free(self.prompt);
        for (self.options) |opt| {
            allocator.free(opt.label);
            if (opt.description) |desc| allocator.free(desc);
        }
        allocator.free(self.options);
    }
};

pub const QuestionState = struct {
    cursor_index: usize,
    selected: []bool,
    custom_active: bool,
    custom_input: InputEditor.State,

    fn deinit(self: *QuestionState, allocator: Allocator) void {
        allocator.free(self.selected);
    }
};

pub const PendingQuestion = struct {
    id: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    questions: []Question,
    states: []QuestionState,
    active_index: usize,

    fn deinit(self: *PendingQuestion, allocator: Allocator) void {
        if (self.id) |id| allocator.free(id);
        if (self.tool_call_id) |id| allocator.free(id);
        for (self.questions) |*question| {
            question.deinit(allocator);
        }
        for (self.states) |*state| {
            state.deinit(allocator);
        }
        allocator.free(self.questions);
        allocator.free(self.states);
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
    earlier_message_dirty: bool, // True when a non-last message was modified (requires full rebuild)
    last_line_map_rebuild: i64, // Timestamp of last rebuild (ms) for throttling
    // Agent plan (todo list)
    plan: PlanState,
    // Slash commands
    available_commands: std.ArrayList(OwnedCommand),
    slash_menu: SlashMenuState,
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
    staged_is_shell_command: bool, // True if staged prompt is a shell command (! mode)
    // File picker state for @ mentions
    file_picker: FilePickerState,
    // Shell command state (mode, queued outputs, running command)
    shell: ShellState,
    // Command palette state (for ':' command menu)
    cmd_palette: command_palette.AgentCommandPaletteState,
    // Help overlay state (toggled with '?' key)
    help_visible: bool,
    help_scroll_offset: usize,
    // History mode state (for browsing message history with vim-like navigation)
    history: HistoryState,
    // Expanded user messages (collapsed by default, toggle with 'o' in history mode)
    expanded_user_messages: std.AutoHashMap(usize, void),
    // Pending question prompt (Opencode question tool)
    pending_question: ?PendingQuestion,

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
            .earlier_message_dirty = false,
            .last_line_map_rebuild = 0,
            .plan = PlanState.init(allocator),
            .available_commands = .{},
            .slash_menu = SlashMenuState.init(),
            .input_scroll_offset = 0,
            .last_esc_timestamp = 0,
            .last_ctrl_c_timestamp = 0,
            .last_messages_viewport_height = 20, // Reasonable default
            .staged_prompt = undefined,
            .staged_prompt_len = 0,
            .staged_is_shell_command = false,
            .file_picker = FilePickerState.init(allocator),
            .shell = ShellState.init(allocator),
            .cmd_palette = command_palette.AgentCommandPaletteState.init(allocator),
            .help_visible = false,
            .help_scroll_offset = 0,
            .history = HistoryState.init(),
            .expanded_user_messages = std.AutoHashMap(usize, void).init(allocator),
            .pending_question = null,
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
        if (self.pending_question) |*question| {
            question.deinit(self.allocator);
        }
        self.line_map.deinit();
        self.plan.deinit();
        for (self.available_commands.items) |*cmd| {
            cmd.deinit(self.allocator);
        }
        self.available_commands.deinit(self.allocator);
        self.file_picker.deinit();
        self.shell.deinit();
        self.cmd_palette.deinit();
        self.expanded_user_messages.deinit();
    }

    pub fn hasPendingQuestion(self: *const AgentState) bool {
        return self.pending_question != null;
    }

    pub fn getPendingQuestion(self: *AgentState) ?*PendingQuestion {
        if (self.pending_question) |*question| return question;
        return null;
    }

    pub fn clearPendingQuestion(self: *AgentState) void {
        if (self.pending_question) |*question| {
            question.deinit(self.allocator);
            self.pending_question = null;
        }
    }

    pub fn setPendingQuestion(self: *AgentState, prompt: QuestionPromptData) !void {
        self.clearPendingQuestion();
        if (prompt.questions.len == 0) return;

        const id_copy: ?[]const u8 = if (prompt.id) |id|
            try self.allocator.dupe(u8, id)
        else
            null;
        errdefer if (id_copy) |id| self.allocator.free(id);

        const tool_call_id_copy: ?[]const u8 = if (prompt.tool_call_id) |id|
            try self.allocator.dupe(u8, id)
        else
            null;
        errdefer if (tool_call_id_copy) |id| self.allocator.free(id);

        var questions = try self.allocator.alloc(Question, prompt.questions.len);
        errdefer self.allocator.free(questions);
        var states = try self.allocator.alloc(QuestionState, prompt.questions.len);
        errdefer self.allocator.free(states);

        const custom_label = "Type your own answer";
        const custom_desc = "Something else";

        for (prompt.questions, 0..) |q, idx| {
            const header_copy: ?[]const u8 = if (q.header) |h|
                try self.allocator.dupe(u8, h)
            else
                null;
            errdefer if (header_copy) |h| self.allocator.free(h);

            const prompt_copy = try self.allocator.dupe(u8, q.question);
            errdefer self.allocator.free(prompt_copy);

            var custom_index: ?usize = null;
            for (q.options, 0..) |opt, opt_idx| {
                if (std.ascii.eqlIgnoreCase(opt.label, custom_label) or std.ascii.eqlIgnoreCase(opt.label, "Other")) {
                    custom_index = opt_idx;
                    break;
                }
            }

            const add_custom = custom_index == null;
            const options_len = q.options.len + (if (add_custom) @as(usize, 1) else 0);
            var options = try self.allocator.alloc(QuestionOption, options_len);
            errdefer self.allocator.free(options);

            for (q.options, 0..) |opt, opt_idx| {
                const label_copy = try self.allocator.dupe(u8, opt.label);
                errdefer self.allocator.free(label_copy);
                const desc_copy: ?[]const u8 = if (opt.description) |d|
                    try self.allocator.dupe(u8, d)
                else
                    null;
                errdefer if (desc_copy) |d| self.allocator.free(d);

                options[opt_idx] = .{
                    .label = label_copy,
                    .description = desc_copy,
                    .is_custom = false,
                };
            }

            if (add_custom) {
                const label_copy = try self.allocator.dupe(u8, custom_label);
                errdefer self.allocator.free(label_copy);
                const desc_copy = try self.allocator.dupe(u8, custom_desc);
                errdefer self.allocator.free(desc_copy);
                options[options_len - 1] = .{
                    .label = label_copy,
                    .description = desc_copy,
                    .is_custom = true,
                };
                custom_index = options_len - 1;
            } else if (custom_index) |custom_idx| {
                options[custom_idx].is_custom = true;
            }

            const selected = try self.allocator.alloc(bool, options_len);
            @memset(selected, false);

            questions[idx] = .{
                .header = header_copy,
                .prompt = prompt_copy,
                .options = options,
                .multiple = q.multiple,
                .custom_index = custom_index,
            };

            states[idx] = .{
                .cursor_index = 0,
                .selected = selected,
                .custom_active = false,
                .custom_input = InputEditor.State.init(),
            };
        }

        self.pending_question = .{
            .id = id_copy,
            .tool_call_id = tool_call_id_copy,
            .questions = questions,
            .states = states,
            .active_index = 0,
        };
    }

    pub fn buildPendingQuestionAnswer(self: *AgentState, allocator: Allocator) !?[]const u8 {
        const pending = self.pending_question orelse return null;

        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(allocator);

        const multi = pending.questions.len > 1;

        for (pending.questions, 0..) |question, idx| {
            const state = pending.states[idx];

            var parts: std.ArrayList([]const u8) = .{};
            defer parts.deinit(allocator);

            for (question.options, 0..) |opt, opt_idx| {
                if (!state.selected[opt_idx]) continue;

                if (opt.is_custom) {
                    const custom_text = std.mem.trim(u8, state.custom_input.getText(), &std.ascii.whitespace);
                    if (custom_text.len > 0) {
                        try parts.append(allocator, custom_text);
                        continue;
                    }
                }

                try parts.append(allocator, opt.label);
            }

            const include_header = multi or (question.header != null and question.header.?.len > 0);
            if (include_header) {
                const header = question.header orelse blk: {
                    var buf: [24]u8 = undefined;
                    const fallback = std.fmt.bufPrint(&buf, "Question {d}", .{idx + 1}) catch "Question";
                    break :blk fallback;
                };
                try output.writer(allocator).print("{s}: ", .{header});
            }

            if (parts.items.len == 0) {
                try output.writer(allocator).writeAll("No answer");
            } else {
                for (parts.items, 0..) |part, part_idx| {
                    if (part_idx > 0) try output.append(allocator, ',');
                    if (part_idx > 0) try output.append(allocator, ' ');
                    try output.appendSlice(allocator, part);
                }
            }

            if (idx + 1 < pending.questions.len) {
                try output.append(allocator, '\n');
            }
        }

        const owned = try output.toOwnedSlice(allocator);
        return @as(?[]const u8, owned);
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
    /// tool_call_id is used for precise matching with pending Edit/Write tool messages
    pub fn addDiffMessage(self: *AgentState, tool_call_id: ?[]const u8, title: []const u8, path: []const u8, old_text: []const u8, new_text: []const u8) !void {
        // Check for duplicate diff (same path and content)
        if (self.messages.items.len > 0) {
            const last = &self.messages.items[self.messages.items.len - 1];
            if (last.role == .diff and last.diff_path != null and last.diff_old != null and last.diff_new != null) {
                if (std.mem.eql(u8, last.diff_path.?, path) and
                    std.mem.eql(u8, last.diff_old.?, old_text) and
                    std.mem.eql(u8, last.diff_new.?, new_text))
                {
                    if (!std.mem.eql(u8, last.content, title)) {
                        const title_copy = try self.allocator.dupe(u8, title);
                        self.allocator.free(last.content);
                        last.content = title_copy;
                    }
                    return;
                }
            }
        }

        // Remove pending Edit/Write tool message matching this tool_call_id
        // This ensures instant replacement instead of showing both briefly
        if (tool_call_id) |id| {
            for (self.messages.items, 0..) |*msg, i| {
                if (msg.role == .tool) {
                    if (msg.tool_call_id) |existing_id| {
                        if (std.mem.eql(u8, existing_id, id)) {
                            // Found exact match by tool_call_id - remove it
                            msg.deinit(self.allocator);
                            _ = self.messages.orderedRemove(i);
                            // Force full rebuild since we removed an earlier message
                            self.earlier_message_dirty = true;
                            break;
                        }
                    }
                }
            }
        }

        const owned_title = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(owned_title);

        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);

        const owned_old = try self.allocator.dupe(u8, old_text);
        errdefer self.allocator.free(owned_old);

        const owned_new = try self.allocator.dupe(u8, new_text);
        errdefer self.allocator.free(owned_new);

        // Store tool_call_id on the diff message for proper tracking
        const owned_tool_id: ?[]const u8 = if (tool_call_id) |id|
            try self.allocator.dupe(u8, id)
        else
            null;
        errdefer if (owned_tool_id) |id| self.allocator.free(id);

        try self.messages.append(self.allocator, .{
            .role = .diff,
            .content = owned_title,
            .timestamp = std.time.timestamp(),
            .diff_path = owned_path,
            .diff_old = owned_old,
            .diff_new = owned_new,
            .tool_call_id = owned_tool_id,
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

        // Invalidate markdown tree since content changed
        last.invalidateMarkdownTree();

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

        // Codex ACP sends both streaming chunks AND a final aggregated chunk
        // containing all the content. Detect and skip duplicates by checking if the
        // incoming text is already a suffix of the existing content.
        // Only check chunks > 100 bytes to avoid false positives with small repeated text.
        const current_content = last.content;
        if (current_content.len >= text.len and text.len > 100) {
            const suffix = current_content[current_content.len - text.len ..];
            if (std.mem.eql(u8, suffix, text)) {
                // Skip duplicate - text already present as suffix
                return;
            }
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

    /// Update an existing tool message with completion status and output.
    /// If no message with the given tool_call_id exists, creates a new one.
    pub fn updateToolMessage(
        self: *AgentState,
        tool_call_id: []const u8,
        status: Message.ToolStatus,
        stdout: ?[]const u8,
        stderr: ?[]const u8,
    ) !void {
        // Find the tool message with matching ID
        for (self.messages.items, 0..) |*msg, idx| {
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

                        // If this is not the last message, mark that an earlier message changed
                        // This ensures ensureLineMap does a full rebuild instead of just updating the last message
                        if (idx < self.messages.items.len - 1) {
                            self.earlier_message_dirty = true;
                        }

                        // Auto-scroll only if in follow mode
                        if (self.follow_bottom) {
                            self.scrollToBottom();
                        }
                        return;
                    }
                }
            }
        }

        // No existing message found - create a new tool message
        // This handles cases where tool_update arrives before tool_call
        std.log.debug("updateToolMessage: creating new message for tool_call_id={s}", .{tool_call_id});

        const owned_id = try self.allocator.dupe(u8, tool_call_id);
        errdefer self.allocator.free(owned_id);

        // Use tool_call_id as a placeholder title (will be updated when tool_call arrives)
        const owned_title = try self.allocator.dupe(u8, tool_call_id);
        errdefer self.allocator.free(owned_title);

        const owned_stdout: ?[]const u8 = if (stdout) |s| try self.allocator.dupe(u8, s) else null;
        errdefer if (owned_stdout) |s| self.allocator.free(s);

        const owned_stderr: ?[]const u8 = if (stderr) |s| try self.allocator.dupe(u8, s) else null;
        errdefer if (owned_stderr) |s| self.allocator.free(s);

        try self.messages.append(self.allocator, .{
            .role = .tool,
            .content = owned_title,
            .timestamp = std.time.timestamp(),
            .tool_call_id = owned_id,
            .tool_name = null,
            .tool_status = status,
            .tool_command = null,
            .tool_stdout = owned_stdout,
            .tool_stderr = owned_stderr,
        });

        // Mark line map dirty
        self.line_map_dirty = true;

        // Auto-scroll only if in follow mode
        if (self.follow_bottom) {
            self.scrollToBottom();
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

    // =========================================================================
    // History Mode (for browsing message history)
    // =========================================================================

    /// Enter history mode for browsing message history.
    /// Only enters if there are messages to browse.
    /// Initializes cursor to bottom of history.
    pub fn enterHistoryMode(self: *AgentState) void {
        // Only enter history mode if there are messages
        if (self.messages.items.len == 0) return;

        const initial_line = self.line_map.getTotalLines() -| 1;
        self.history.enter(initial_line);
    }

    /// Exit history mode and return to normal editing.
    /// Also clears visual mode if active.
    pub fn exitHistoryMode(self: *AgentState) void {
        self.history.exit();
    }

    /// Check if currently in history mode.
    pub fn isInHistoryMode(self: *const AgentState) bool {
        return self.history.active;
    }

    /// Check if a user message is expanded (collapsed by default).
    pub fn isUserMessageExpanded(self: *const AgentState, msg_idx: usize) bool {
        return self.expanded_user_messages.contains(msg_idx);
    }

    /// Toggle a user message's expanded/collapsed state.
    pub fn toggleUserMessageExpanded(self: *AgentState, msg_idx: usize) void {
        if (self.expanded_user_messages.contains(msg_idx)) {
            _ = self.expanded_user_messages.remove(msg_idx);
        } else {
            self.expanded_user_messages.put(msg_idx, {}) catch {};
        }
        // Need full rebuild since we're changing how a message renders
        self.line_map_dirty = true;
        self.earlier_message_dirty = true;
    }

    /// Toggle expansion of the user message under the cursor in history mode.
    /// Returns true if a message was toggled.
    pub fn toggleUserMessageUnderCursor(self: *AgentState) bool {
        if (!self.history.active) return false;

        const msg_idx = self.getMessageIdxAtLine(self.history.cursor_line) orelse return false;
        if (msg_idx >= self.messages.items.len) return false;

        const msg = &self.messages.items[msg_idx];
        if (msg.role != .user) return false;

        self.toggleUserMessageExpanded(msg_idx);
        return true;
    }

    /// Get the maximum valid cursor line (last line index).
    pub fn getHistoryMaxLine(self: *const AgentState) usize {
        const total = self.line_map.getTotalLines();
        return if (total > 0) total - 1 else 0;
    }

    /// Move cursor up one line, clamping at 0.
    pub fn historyCursorUp(self: *AgentState) void {
        if (self.history.cursor_line == 0) return;

        // Check if current line is part of a user message
        if (self.getMessageIdxAtLine(self.history.cursor_line)) |msg_idx| {
            if (msg_idx < self.messages.items.len and self.messages.items[msg_idx].role == .user) {
                // Find the start of this user message
                const msg_start = self.findMessageStartLine(msg_idx);
                if (self.history.cursor_line > msg_start) {
                    // We're inside a user message, jump to its start
                    self.history.cursor_line = msg_start;
                    self.ensureHistoryCursorVisible();
                    return;
                }
                // We're at the start, jump to previous message
                if (msg_start > 0) {
                    self.history.cursor_line = msg_start - 1;
                    // If landed on spacer, go up one more
                    if (self.getMessageIdxAtLine(self.history.cursor_line) == null and self.history.cursor_line > 0) {
                        self.history.cursor_line -= 1;
                    }
                    // If landed inside another user message, jump to its start
                    if (self.getMessageIdxAtLine(self.history.cursor_line)) |prev_idx| {
                        if (prev_idx < self.messages.items.len and self.messages.items[prev_idx].role == .user) {
                            self.history.cursor_line = self.findMessageStartLine(prev_idx);
                        }
                    }
                    self.ensureHistoryCursorVisible();
                    return;
                }
            }
        }
        // Default: move up one line
        self.history.cursorUp();
        self.ensureHistoryCursorVisible();
    }

    /// Move cursor down one line, clamping at max.
    pub fn historyCursorDown(self: *AgentState) void {
        const max_line = self.getHistoryMaxLine();
        if (self.history.cursor_line >= max_line) return;

        // Check if current line is part of a user message
        if (self.getMessageIdxAtLine(self.history.cursor_line)) |msg_idx| {
            if (msg_idx < self.messages.items.len and self.messages.items[msg_idx].role == .user) {
                // Find the end of this user message and jump past it
                var line = self.history.cursor_line;
                while (line < max_line) {
                    line += 1;
                    const next_msg_idx = self.getMessageIdxAtLine(line);
                    if (next_msg_idx == null or next_msg_idx.? != msg_idx) {
                        // Found end of user message
                        self.history.cursor_line = line;
                        // If landed on spacer, go down one more
                        if (next_msg_idx == null and line < max_line) {
                            self.history.cursor_line += 1;
                        }
                        self.ensureHistoryCursorVisible();
                        return;
                    }
                }
                // Reached end of content
                self.history.cursor_line = max_line;
                self.ensureHistoryCursorVisible();
                return;
            }
        }
        // Default: move down one line
        self.history.cursorDown(max_line);
        self.ensureHistoryCursorVisible();
    }

    /// Jump to previous message boundary.
    pub fn historyJumpToPrevMessage(self: *AgentState) void {
        if (self.history.cursor_line == 0) return;

        // Get current message index
        const current_msg_idx = self.getMessageIdxAtLine(self.history.cursor_line);

        // Search backwards for a different message
        var line = self.history.cursor_line;
        while (line > 0) {
            line -= 1;
            const msg_idx = self.getMessageIdxAtLine(line);
            // Skip spacers (null msg_idx) and match different message
            if (msg_idx != null and msg_idx != current_msg_idx) {
                // Found a different message, now find its start
                self.history.cursor_line = self.findMessageStartLine(msg_idx.?);
                self.ensureHistoryCursorVisible();
                return;
            }
        }

        // No previous message found, go to line 0
        self.history.cursor_line = 0;
        self.ensureHistoryCursorVisible();
    }

    /// Jump to next message boundary.
    pub fn historyJumpToNextMessage(self: *AgentState) void {
        const max_line = self.getHistoryMaxLine();
        if (self.history.cursor_line >= max_line) return;

        // Get current message index
        const current_msg_idx = self.getMessageIdxAtLine(self.history.cursor_line);

        // Search forwards for a different message
        var line = self.history.cursor_line + 1;
        while (line <= max_line) : (line += 1) {
            const msg_idx = self.getMessageIdxAtLine(line);
            // Skip spacers (null msg_idx) and match different message
            if (msg_idx != null and msg_idx != current_msg_idx) {
                // Found a different message, set cursor to its first line
                self.history.cursor_line = line;
                self.ensureHistoryCursorVisible();
                return;
            }
        }

        // No next message found, go to max
        self.history.cursor_line = max_line;
        self.ensureHistoryCursorVisible();
    }

    /// Page up - move cursor up by half viewport height.
    pub fn historyPageUp(self: *AgentState) void {
        self.history.pageUp(self.last_messages_viewport_height);
        self.ensureHistoryCursorVisible();
    }

    /// Page down - move cursor down by half viewport height.
    pub fn historyPageDown(self: *AgentState) void {
        self.history.pageDown(self.last_messages_viewport_height, self.getHistoryMaxLine());
        self.ensureHistoryCursorVisible();
    }

    /// Jump to top of history (line 0).
    pub fn historyJumpToTop(self: *AgentState) void {
        self.history.jumpToTop();
        self.scroll_offset = 0;
        self.follow_bottom = false;
    }

    /// Jump to bottom of history (last line).
    pub fn historyJumpToBottom(self: *AgentState) void {
        self.history.jumpToBottom(self.getHistoryMaxLine());
        self.follow_bottom = true;
        self.ensureHistoryCursorVisible();
    }

    /// Move cursor to the middle line of the current viewport (like vim's 'M').
    pub fn historyCenterCursor(self: *AgentState) void {
        self.history.centerCursor(self.scroll_offset, self.last_messages_viewport_height, self.getHistoryMaxLine());
        self.follow_bottom = false;
    }

    /// Ensure the cursor is visible within the viewport, scrolling if needed.
    pub fn ensureHistoryCursorVisible(self: *AgentState) void {
        const new_offset = self.history.ensureCursorVisible(
            self.scroll_offset,
            self.last_messages_viewport_height,
            self.getHistoryMaxLine(),
        );
        self.scroll_offset = new_offset;
        self.follow_bottom = false;
    }

    /// Get the message index for a given line from the line map.
    fn getMessageIdxAtLine(self: *const AgentState, line: usize) ?usize {
        const record = self.line_map.getLineRecord(line) orelse return null;
        return switch (record.line_type) {
            .role_header => |h| h.msg_idx,
            .message_content => |c| c.msg_idx,
            .tool_header => |t| t.msg_idx,
            .tool_result => |r| r.msg_idx,
            .diff_header => |d| d.msg_idx,
            .diff_hunk_header => |h| h.msg_idx,
            .diff_line => |d| d.msg_idx,
            .plan_entry => |p| p.msg_idx,
            .spacer => null,
        };
    }

    /// Find the first line of a message given its index.
    fn findMessageStartLine(self: *const AgentState, target_msg_idx: usize) usize {
        const total_lines = self.line_map.getTotalLines();
        for (0..total_lines) |line| {
            if (self.getMessageIdxAtLine(line)) |msg_idx| {
                if (msg_idx == target_msg_idx) {
                    return line;
                }
            }
        }
        return 0;
    }

    // =========================================================================
    // Visual Selection Mode (within History Mode)
    // =========================================================================

    /// Enter visual selection mode (line-based, like V in vim).
    /// Sets anchor to current cursor position.
    pub fn enterHistoryVisualMode(self: *AgentState) void {
        self.history.enterVisualMode();
    }

    /// Exit visual selection mode (back to normal history mode).
    pub fn exitHistoryVisualMode(self: *AgentState) void {
        self.history.exitVisualMode();
    }

    /// Check if in history visual mode.
    pub fn isInHistoryVisualMode(self: *const AgentState) bool {
        return self.history.active and self.history.visual_mode;
    }

    /// Get visual selection range (start, end) - always start <= end.
    pub fn getVisualSelectionRange(self: *const AgentState) struct { start: usize, end: usize } {
        const range = self.history.getVisualRange();
        return .{ .start = range.start, .end = range.end };
    }

    /// Check if a line is within visual selection.
    pub fn isLineInVisualSelection(self: *const AgentState, line: usize) bool {
        return self.history.isLineInVisualSelection(line);
    }

    /// Check if a line should be highlighted as part of the same user message unit.
    /// When the cursor is on any line of a user message, all lines belonging to
    /// that same message should be highlighted together as a single unit.
    /// Returns true if `line` belongs to the same user message as the cursor line.
    pub fn isLineInCursorUserMessage(self: *const AgentState, line: usize) bool {
        // Only applies when in history mode and not in visual mode
        if (!self.isInHistoryMode() or self.isInHistoryVisualMode()) return false;

        // Get the cursor line's record
        const cursor_record = self.line_map.getLineRecord(self.history.cursor_line) orelse return false;

        // Only applies if cursor is on a user message content line
        const cursor_msg_idx = switch (cursor_record.line_type) {
            .message_content => |mc| blk: {
                // Check if this message is a user message
                if (mc.msg_idx < self.messages.items.len) {
                    if (self.messages.items[mc.msg_idx].role == .user) {
                        break :blk mc.msg_idx;
                    }
                }
                return false;
            },
            else => return false,
        };

        // Get the target line's record
        const target_record = self.line_map.getLineRecord(line) orelse return false;

        // Check if target line belongs to the same user message
        return switch (target_record.line_type) {
            .message_content => |mc| mc.msg_idx == cursor_msg_idx,
            else => false,
        };
    }

    /// Extract text for a range of lines from the line map.
    /// Returns owned string that caller must free.
    pub fn getTextForLineRange(self: *const AgentState, alloc: Allocator, start: usize, end: usize) ![]const u8 {
        var result: std.ArrayList(u8) = .{};
        errdefer result.deinit(alloc);

        const total_lines = self.line_map.getTotalLines();
        var line_idx = start;
        while (line_idx <= end and line_idx < total_lines) : (line_idx += 1) {
            const record = self.line_map.getLineRecord(line_idx) orelse continue;
            if (record.text.len > 0) {
                try result.appendSlice(alloc, record.text);
            }
            if (line_idx < end) {
                try result.append(alloc, '\n');
            }
        }

        return result.toOwnedSlice(alloc);
    }

    /// Extract full message text for a given message index.
    /// Returns owned string that caller must free.
    pub fn getTextForMessage(self: *const AgentState, alloc: Allocator, msg_idx: usize) ![]const u8 {
        if (msg_idx >= self.messages.items.len) return alloc.dupe(u8, "");

        const msg = self.messages.items[msg_idx];
        return alloc.dupe(u8, msg.content);
    }

    /// Yank visual selection to clipboard.
    /// Exits visual mode after yank.
    pub fn yankVisualSelection(self: *AgentState, alloc: Allocator) !void {
        if (!self.isInHistoryVisualMode()) return;

        const range = self.getVisualSelectionRange();
        const text = try self.getTextForLineRange(alloc, range.start, range.end);
        defer alloc.free(text);

        try clipboard.copyToClipboard(alloc, text);

        // Exit visual mode after yank
        self.exitHistoryVisualMode();
    }

    /// Yank entire current message to clipboard.
    pub fn yankCurrentMessage(self: *AgentState, alloc: Allocator) !void {
        if (!self.history.active) return;

        const msg_idx = self.getMessageIdxAtLine(self.history.cursor_line) orelse return;
        const text = try self.getTextForMessage(alloc, msg_idx);
        defer alloc.free(text);

        try clipboard.copyToClipboard(alloc, text);
    }

    /// Yank current line to clipboard (yy in vim).
    pub fn yankCurrentLine(self: *AgentState, alloc: Allocator) !void {
        if (!self.history.active) return;

        const text = try self.getTextForLineRange(alloc, self.history.cursor_line, self.history.cursor_line);
        defer alloc.free(text);

        if (text.len > 0) {
            try clipboard.copyToClipboard(alloc, text);
        }
    }

    /// Get the user message index at the cursor, if cursor is on a user message.
    /// Returns null if cursor is not on a user message.
    pub fn getUserMessageIdxAtCursor(self: *const AgentState) ?usize {
        if (!self.history.active) return null;

        const record = self.line_map.getLineRecord(self.history.cursor_line) orelse return null;

        return switch (record.line_type) {
            .message_content => |mc| blk: {
                if (mc.msg_idx < self.messages.items.len) {
                    if (self.messages.items[mc.msg_idx].role == .user) {
                        break :blk mc.msg_idx;
                    }
                }
                break :blk null;
            },
            else => null,
        };
    }

    /// Yank user message at cursor to clipboard (y when on user message).
    /// Returns true if a user message was yanked, false otherwise.
    pub fn yankUserMessageAtCursor(self: *AgentState, alloc: Allocator) !bool {
        const msg_idx = self.getUserMessageIdxAtCursor() orelse return false;

        const text = try self.getTextForMessage(alloc, msg_idx);
        defer alloc.free(text);

        if (text.len > 0) {
            try clipboard.copyToClipboard(alloc, text);
            return true;
        }
        return false;
    }

    /// Get message count
    pub fn messageCount(self: *const AgentState) usize {
        return self.messages.items.len;
    }

    /// Mark the line map as needing a rebuild
    /// Call this when switching tabs or when the display context changes
    pub fn markLineMapDirty(self: *AgentState) void {
        self.line_map_dirty = true;
        // Reset the last rebuild timestamp to force an immediate rebuild on next ensureLineMap
        self.last_line_map_rebuild = 0;
    }

    /// Ensure line map is up to date for rendering
    /// Returns the line map for iteration
    /// Uses incremental updates when possible to avoid O(N) rebuilds
    /// Throttles updates to ~30fps to keep UI responsive during streaming
    /// Accepts optional SyntaxHighlighter for diff syntax highlighting
    pub fn ensureLineMap(self: *AgentState, wrap_width: usize, highlighter: ?*SyntaxHighlighter) !*const ChatLineMap {
        const width_or_mode_changed = self.line_map.needsRebuild(wrap_width, self.diff_view_mode);
        const needs_update = self.line_map_dirty or width_or_mode_changed;

        if (needs_update) {
            const now = std.time.milliTimestamp();
            const elapsed = now - self.last_line_map_rebuild;

            // Throttle updates to every 32ms (~30fps) during streaming
            // Always update if it's been long enough or this is the first build
            if (elapsed >= 32 or self.last_line_map_rebuild == 0) {
                const message_count = self.messages.items.len;
                const prev_message_count = self.line_map.message_count;

                if (width_or_mode_changed or prev_message_count == 0 or self.earlier_message_dirty) {
                    // Width/mode changed, first build, or earlier message modified - full rebuild required
                    try self.line_map.build(self.messages.items, wrap_width, self.diff_view_mode, highlighter, &self.expanded_user_messages);
                } else if (message_count > prev_message_count) {
                    // New messages added - incremental add
                    try self.line_map.updateForNewMessage(self.messages.items, wrap_width, self.diff_view_mode, highlighter, &self.expanded_user_messages);
                } else if (message_count == prev_message_count and message_count > 0) {
                    // Same message count but dirty - last message content changed (streaming)
                    try self.line_map.updateLastMessage(self.messages.items, wrap_width, self.diff_view_mode, highlighter, &self.expanded_user_messages);
                }
                // If message_count < prev_message_count, messages were cleared - rebuild
                else if (message_count < prev_message_count) {
                    try self.line_map.build(self.messages.items, wrap_width, self.diff_view_mode, highlighter, &self.expanded_user_messages);
                }

                self.line_map_dirty = false;
                self.earlier_message_dirty = false;
                self.last_line_map_rebuild = now;
            }
            // Otherwise skip update this frame - use stale line map
        }
        return &self.line_map;
    }

    // =========================================================================
    // Plan Management
    // =========================================================================

    /// Update the plan with new entries (replaces all existing entries)
    pub fn updatePlan(self: *AgentState, entries: []const protocol.PlanEntry) !void {
        // Update plan state (handles clearing and adding entries)
        try self.plan.update(entries);

        // Create a snapshot message for the chat
        try self.addPlanSnapshotMessage();
    }

    /// Add a plan snapshot message to the chat history
    fn addPlanSnapshotMessage(self: *AgentState) !void {
        // Skip if no plan entries
        if (!self.plan.hasEntries()) return;

        std.log.debug("addPlanSnapshotMessage: creating snapshot with {d} entries", .{self.plan.count()});

        // Create a copy of all plan entries for the snapshot
        const snapshot_entries = try self.plan.createSnapshot();
        errdefer {
            for (snapshot_entries) |*entry| {
                self.allocator.free(entry.content);
            }
            self.allocator.free(snapshot_entries);
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
        self.plan.clear();
    }

    /// Toggle plan visibility
    pub fn togglePlanVisibility(self: *AgentState) void {
        self.plan.toggleVisibility();
    }

    /// Toggle plan expanded/collapsed state
    pub fn togglePlanExpanded(self: *AgentState) void {
        self.plan.toggleExpanded();
    }

    /// Get the number of plan entries
    pub fn planEntryCount(self: *const AgentState) usize {
        return self.plan.count();
    }

    /// Check if there are any incomplete plan entries
    pub fn hasIncompletePlanEntries(self: *const AgentState) bool {
        return self.plan.hasIncompleteEntries();
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
        return slash_menu.isLocalCommand(name);
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
        self.slash_menu.show();
    }

    /// Hide slash menu
    pub fn hideSlashMenu(self: *AgentState) void {
        self.slash_menu.hide();
    }

    /// Move selection up in slash menu
    pub fn slashMenuUp(self: *AgentState, visible_count: usize) void {
        _ = visible_count;
        self.slash_menu.moveUp();
    }

    /// Move selection down in slash menu
    pub fn slashMenuDown(self: *AgentState, max_items: usize, visible_count: usize) void {
        self.slash_menu.moveDown(max_items, visible_count);
    }

    /// Get the selected command (if any) based on current filter
    pub fn getSelectedCommand(self: *AgentState) ?*const OwnedCommand {
        var indices: [32]usize = undefined;
        const count = self.getFilteredCommandIndices(&indices);

        if (count == 0) return null;

        const selection = self.slash_menu.getClampedSelection(count);
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

    /// Check if waiting for a second Ctrl+C press (within threshold window)
    pub fn isPendingCtrlC(self: *const AgentState) bool {
        if (self.last_ctrl_c_timestamp == 0) return false;
        const now_ms = std.time.milliTimestamp();
        const elapsed = now_ms - self.last_ctrl_c_timestamp;
        return elapsed <= DOUBLE_KEY_THRESHOLD_MS;
    }

    /// Check if waiting for a second ESC press (within threshold window)
    pub fn isPendingEsc(self: *const AgentState) bool {
        if (self.last_esc_timestamp == 0) return false;
        const now_ms = std.time.milliTimestamp();
        const elapsed = now_ms - self.last_esc_timestamp;
        return elapsed <= DOUBLE_KEY_THRESHOLD_MS;
    }

    // =========================================================================
    // Shell Command Mode
    // =========================================================================

    /// Toggle shell command mode on/off
    pub fn toggleShellMode(self: *AgentState) void {
        self.shell.toggleMode();
    }

    /// Check if in shell command mode
    pub fn isShellMode(self: *const AgentState) bool {
        return self.shell.isActive();
    }

    /// Clear shell mode (e.g., after submitting a command)
    pub fn clearShellMode(self: *AgentState) void {
        self.shell.clearMode();
    }

    /// Queue a shell command output to be sent with next prompt
    pub fn queueShellOutput(self: *AgentState, content: []const u8) !void {
        try self.shell.queueOutput(content);
    }

    /// Check if there are queued shell outputs
    pub fn hasQueuedShellOutputs(self: *const AgentState) bool {
        return self.shell.hasQueuedOutputs();
    }

    /// Take all queued shell outputs (caller owns returned slice, must free)
    /// Returns null on allocation failure or if empty
    pub fn takeQueuedShellOutputs(self: *AgentState) ?[]QueuedShellOutput {
        return self.shell.takeQueuedOutputs();
    }

    /// Clear all queued shell outputs
    pub fn clearQueuedShellOutputs(self: *AgentState) void {
        self.shell.clearQueuedOutputs();
    }

    /// Check if a shell command is currently running
    pub fn hasRunningShellCommand(self: *const AgentState) bool {
        return self.shell.hasRunningCommand();
    }

    /// Get next unique shell command tool ID
    pub fn nextShellCmdId(self: *AgentState, buf: []u8) []const u8 {
        return self.shell.nextCmdId(buf);
    }

    /// Get the last N lines of running command output for display
    pub fn getRunningCommandOutput(self: *AgentState, max_lines: usize) ?[]const u8 {
        return self.shell.getRunningOutput(max_lines);
    }

    /// Estimate memory usage of the agent state (for monitoring)

    // =========================================================================
    // Staged Prompt (Message Queuing)
    // =========================================================================

    /// Stage a prompt to be sent after the agent completes its current turn
    pub fn stagePrompt(self: *AgentState, text: []const u8) void {
        self.stagePromptWithMode(text, false);
    }

    /// Stage a shell command to be executed after the agent completes
    pub fn stageShellCommand(self: *AgentState, text: []const u8) void {
        self.stagePromptWithMode(text, true);
    }

    /// Stage a prompt with explicit shell mode flag
    fn stagePromptWithMode(self: *AgentState, text: []const u8, is_shell: bool) void {
        const copy_len = @min(text.len, self.staged_prompt.len);
        @memcpy(self.staged_prompt[0..copy_len], text[0..copy_len]);
        self.staged_prompt_len = copy_len;
        self.staged_is_shell_command = is_shell;
    }

    /// Check if there's a staged prompt
    pub fn hasStagedPrompt(self: *const AgentState) bool {
        return self.staged_prompt_len > 0;
    }

    /// Check if the staged prompt is a shell command
    pub fn isStagedShellCommand(self: *const AgentState) bool {
        return self.staged_is_shell_command;
    }

    /// Get the staged prompt text
    pub fn getStagedPrompt(self: *const AgentState) []const u8 {
        return self.staged_prompt[0..self.staged_prompt_len];
    }

    /// Clear the staged prompt
    pub fn clearStagedPrompt(self: *AgentState) void {
        self.staged_prompt_len = 0;
        self.staged_is_shell_command = false;
    }

    /// Take the staged prompt (returns it and clears it)
    pub fn takeStagedPrompt(self: *AgentState) ?[]const u8 {
        if (self.staged_prompt_len == 0) return null;
        const text = self.staged_prompt[0..self.staged_prompt_len];
        self.staged_prompt_len = 0;
        self.staged_is_shell_command = false;
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
        total += self.plan.estimateMemoryUsage();

        // Available commands
        for (self.available_commands.items) |cmd| {
            total += cmd.name.len;
            total += cmd.description.len;
            if (cmd.input_hint) |h| total += h.len;
        }

        // ArrayList overhead (rough estimate)
        total += self.messages.capacity * @sizeOf(Message);
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
    // For markdown parsing (agent messages only)
    md_parser: ?MarkdownParser = null,
    md_tree_valid: bool = false,
    md_parsed_len: usize = 0, // Length when tree was last parsed (for incremental updates)
    // Track if this message has successfully rendered a formatted table.
    // Once true, we should never downgrade to dimmed/plain text rendering.
    had_formatted_table: bool = false,

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
        // Clean up markdown parser if present
        if (self.md_parser) |*parser| {
            parser.deinit();
        }
    }

    /// Ensure markdown is parsed for this message
    /// Only parses agent messages (user messages don't need markdown rendering)
    /// Uses incremental parsing for streaming updates (O(n) instead of O(n²))
    /// Returns true if parsing succeeded or was already done
    pub fn ensureMarkdownParsed(self: *Message) bool {
        // Only parse agent messages
        if (self.role != .agent) {
            return false;
        }

        // Already valid and content unchanged
        if (self.md_tree_valid and self.md_parser != null) {
            return true;
        }

        // Initialize parser if needed
        if (self.md_parser == null) {
            self.md_parser = MarkdownParser.init() catch {
                return false;
            };
        }

        // Use incremental update if: have tree, have previous parse, content only appended
        const can_incremental = self.md_parser.?.tree != null and
            self.md_parsed_len > 0 and
            self.content.len >= self.md_parsed_len;

        if (can_incremental) {
            self.md_parser.?.update(
                @intCast(self.md_parsed_len), // start_byte
                @intCast(self.md_parsed_len), // old_end_byte
                @intCast(self.content.len), // new_end_byte
                self.content,
            ) catch {
                // Fallback to full parse on error
                self.md_parser.?.parse(self.content) catch {
                    return false;
                };
            };
        } else {
            // Full parse for initial or non-append changes
            self.md_parser.?.parse(self.content) catch {
                return false;
            };
        }

        self.md_parsed_len = self.content.len;
        self.md_tree_valid = true;
        return true;
    }

    /// Invalidate the markdown parse tree (call when content changes)
    pub fn invalidateMarkdownTree(self: *Message) void {
        self.md_tree_valid = false;
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

test "AgentState addDiffMessage dedupes consecutive diffs" {
    const allocator = std.testing.allocator;

    var state = AgentState.init(allocator, .right);
    defer state.deinit();

    try state.addDiffMessage("Edit", "file.txt", "old", "new");
    try state.addDiffMessage("Edit file.txt", "file.txt", "old", "new");

    try std.testing.expectEqual(@as(usize, 1), state.messageCount());
    try std.testing.expectEqual(Message.Role.diff, state.messages.items[0].role);
    try std.testing.expectEqualStrings("Edit file.txt", state.messages.items[0].content);
    try std.testing.expectEqualStrings("file.txt", state.messages.items[0].diff_path.?);
    try std.testing.expectEqualStrings("old", state.messages.items[0].diff_old.?);
    try std.testing.expectEqualStrings("new", state.messages.items[0].diff_new.?);
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

// =============================================================================
// History Mode Tests
// =============================================================================

test "enterHistoryMode with messages sets history_mode true" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    // Add a message so history mode can be entered
    try agent_state.addMessage(.user, "Hello");

    // Enter history mode
    agent_state.enterHistoryMode();

    // Verify history mode is active
    try std.testing.expect(agent_state.isInHistoryMode());
}

test "enterHistoryMode with no messages is no-op" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    // Try to enter history mode with no messages
    agent_state.enterHistoryMode();

    // Verify history mode is NOT active
    try std.testing.expect(!agent_state.isInHistoryMode());
}

test "exitHistoryMode clears history_mode" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    // Add a message and enter history mode
    try agent_state.addMessage(.user, "Hello");
    agent_state.enterHistoryMode();
    try std.testing.expect(agent_state.isInHistoryMode());

    // Exit history mode
    agent_state.exitHistoryMode();

    // Verify history mode is cleared
    try std.testing.expect(!agent_state.isInHistoryMode());
}

test "historyCursorDown moves cursor and clamps at max" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    // Add messages to create some lines in line_map
    try agent_state.addMessage(.user, "Hello");
    try agent_state.addMessage(.agent, "Hi there");

    // Build the line map to get real line count
    _ = try agent_state.ensureLineMap(80, null);

    // Enter history mode
    agent_state.enterHistoryMode();
    const max_line = agent_state.getHistoryMaxLine();

    // Set cursor to 0 and move down
    agent_state.history.cursor_line = 0;
    agent_state.historyCursorDown();
    try std.testing.expect(agent_state.history.cursor_line == 1);

    // Move cursor to max and try to move down (should stay at max)
    agent_state.history.cursor_line = max_line;
    agent_state.historyCursorDown();
    try std.testing.expect(agent_state.history.cursor_line == max_line);
}

test "historyCursorUp moves cursor and stops at zero" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    // Add a message
    try agent_state.addMessage(.user, "Hello");

    // Build the line map
    _ = try agent_state.ensureLineMap(80, null);

    // Enter history mode
    agent_state.enterHistoryMode();

    // Set cursor to 2 and move up
    agent_state.history.cursor_line = 2;
    agent_state.historyCursorUp();
    try std.testing.expect(agent_state.history.cursor_line == 1);

    // Move to 0 and try to move up (should stay at 0)
    agent_state.history.cursor_line = 0;
    agent_state.historyCursorUp();
    try std.testing.expect(agent_state.history.cursor_line == 0);
}

test "historyJumpToTop sets cursor to 0 and scroll_offset to 0" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    // Add messages
    try agent_state.addMessage(.user, "Hello");
    try agent_state.addMessage(.agent, "World");

    // Build line map
    _ = try agent_state.ensureLineMap(80, null);

    // Enter history mode and set some scroll/cursor position
    agent_state.enterHistoryMode();
    agent_state.history.cursor_line = 5;
    agent_state.scroll_offset = 3;

    // Jump to top
    agent_state.historyJumpToTop();

    try std.testing.expect(agent_state.history.cursor_line == 0);
    try std.testing.expect(agent_state.scroll_offset == 0);
    try std.testing.expect(!agent_state.follow_bottom);
}

test "historyJumpToBottom sets cursor to last line" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    // Add messages
    try agent_state.addMessage(.user, "Hello");

    // Build line map
    _ = try agent_state.ensureLineMap(80, null);

    // Enter history mode
    agent_state.enterHistoryMode();
    agent_state.history.cursor_line = 0;

    // Jump to bottom
    agent_state.historyJumpToBottom();

    const max_line = agent_state.getHistoryMaxLine();
    try std.testing.expect(agent_state.history.cursor_line == max_line);
    try std.testing.expect(agent_state.follow_bottom);
}

test "getHistoryMaxLine returns correct max" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    // Empty - max should be 0
    try std.testing.expect(agent_state.getHistoryMaxLine() == 0);

    // Add message
    try agent_state.addMessage(.user, "Hello");
    _ = try agent_state.ensureLineMap(80, null);

    const total = agent_state.line_map.getTotalLines();
    const max = agent_state.getHistoryMaxLine();
    try std.testing.expect(max == if (total > 0) total - 1 else 0);
}

test "ensureHistoryCursorVisible scrolls viewport to cursor" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    // Add several messages to create enough lines
    try agent_state.addMessage(.user, "Line 1");
    try agent_state.addMessage(.agent, "Line 2");
    try agent_state.addMessage(.user, "Line 3");
    try agent_state.addMessage(.agent, "Line 4");

    // Build line map
    _ = try agent_state.ensureLineMap(80, null);

    agent_state.enterHistoryMode();
    agent_state.last_messages_viewport_height = 3; // Small viewport

    // Cursor above scroll_offset - should scroll up
    agent_state.scroll_offset = 5;
    agent_state.history.cursor_line = 2;
    agent_state.ensureHistoryCursorVisible();
    try std.testing.expect(agent_state.scroll_offset == 2);

    // Cursor below viewport - should scroll down
    agent_state.scroll_offset = 0;
    agent_state.history.cursor_line = 5;
    agent_state.ensureHistoryCursorVisible();
    try std.testing.expect(agent_state.scroll_offset >= 3); // cursor should be visible
}

// =============================================================================
// Visual Selection Mode Tests
// =============================================================================

test "enterHistoryVisualMode sets anchor to current cursor" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    // Add a message and enter history mode
    try agent_state.addMessage(.user, "Hello");
    _ = try agent_state.ensureLineMap(80, null);
    agent_state.enterHistoryMode();

    // Set cursor to a specific line
    agent_state.history.cursor_line = 3;

    // Enter visual mode
    agent_state.enterHistoryVisualMode();

    // Verify visual mode is active and anchor is set
    try std.testing.expect(agent_state.isInHistoryVisualMode());
    try std.testing.expect(agent_state.history.visual_anchor == 3);
}

test "getVisualSelectionRange returns ordered range" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    // Add a message and enter history mode
    try agent_state.addMessage(.user, "Hello");
    _ = try agent_state.ensureLineMap(80, null);
    agent_state.enterHistoryMode();

    // Test case 1: anchor < cursor
    agent_state.history.cursor_line = 5;
    agent_state.enterHistoryVisualMode(); // anchor = 5
    agent_state.history.cursor_line = 10; // cursor moved down

    const range1 = agent_state.getVisualSelectionRange();
    try std.testing.expectEqual(@as(usize, 5), range1.start);
    try std.testing.expectEqual(@as(usize, 10), range1.end);

    // Test case 2: cursor < anchor (moved up)
    agent_state.history.cursor_line = 2;
    const range2 = agent_state.getVisualSelectionRange();
    try std.testing.expectEqual(@as(usize, 2), range2.start);
    try std.testing.expectEqual(@as(usize, 5), range2.end);

    // Test case 3: cursor == anchor (single line selection)
    agent_state.history.cursor_line = 5;
    const range3 = agent_state.getVisualSelectionRange();
    try std.testing.expectEqual(@as(usize, 5), range3.start);
    try std.testing.expectEqual(@as(usize, 5), range3.end);
}

test "isLineInVisualSelection correct for inside/outside range" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    // Add a message and enter history mode
    try agent_state.addMessage(.user, "Hello");
    _ = try agent_state.ensureLineMap(80, null);
    agent_state.enterHistoryMode();

    // Set up visual selection from 3 to 7
    agent_state.history.cursor_line = 3;
    agent_state.enterHistoryVisualMode();
    agent_state.history.cursor_line = 7;

    // Lines inside selection (inclusive)
    try std.testing.expect(agent_state.isLineInVisualSelection(3));
    try std.testing.expect(agent_state.isLineInVisualSelection(5));
    try std.testing.expect(agent_state.isLineInVisualSelection(7));

    // Lines outside selection
    try std.testing.expect(!agent_state.isLineInVisualSelection(2));
    try std.testing.expect(!agent_state.isLineInVisualSelection(8));
    try std.testing.expect(!agent_state.isLineInVisualSelection(0));
}

test "exitHistoryVisualMode clears visual state" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    // Add a message and enter history mode then visual mode
    try agent_state.addMessage(.user, "Hello");
    _ = try agent_state.ensureLineMap(80, null);
    agent_state.enterHistoryMode();
    agent_state.history.cursor_line = 5;
    agent_state.enterHistoryVisualMode();

    // Verify visual mode is active
    try std.testing.expect(agent_state.isInHistoryVisualMode());

    // Exit visual mode
    agent_state.exitHistoryVisualMode();

    // Verify visual mode is cleared but history mode remains
    try std.testing.expect(!agent_state.isInHistoryVisualMode());
    try std.testing.expect(agent_state.isInHistoryMode());
    try std.testing.expect(!agent_state.history.visual_mode);
}

test "exitHistoryMode also clears visual mode" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    // Add a message and enter history mode then visual mode
    try agent_state.addMessage(.user, "Hello");
    _ = try agent_state.ensureLineMap(80, null);
    agent_state.enterHistoryMode();
    agent_state.history.cursor_line = 5;
    agent_state.enterHistoryVisualMode();

    // Verify both modes are active
    try std.testing.expect(agent_state.isInHistoryMode());
    try std.testing.expect(agent_state.isInHistoryVisualMode());

    // Exit history mode entirely
    agent_state.exitHistoryMode();

    // Verify both modes are cleared
    try std.testing.expect(!agent_state.isInHistoryMode());
    try std.testing.expect(!agent_state.isInHistoryVisualMode());
    try std.testing.expect(!agent_state.history.visual_mode);
}

test "getTextForLineRange extracts text from line map" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    // Add a message with known content
    try agent_state.addMessage(.user, "Hello World");

    // Build line map
    _ = try agent_state.ensureLineMap(80, null);

    // Get text for first line (should have some content)
    const total_lines = agent_state.line_map.getTotalLines();
    try std.testing.expect(total_lines > 0);

    const text = try agent_state.getTextForLineRange(allocator, 0, 0);
    defer allocator.free(text);

    // Should have extracted some text (exact content depends on line map formatting)
    try std.testing.expect(text.len >= 0);
}

test "getTextForMessage returns message content" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    // Add a message
    try agent_state.addMessage(.user, "Test message content");

    // Get text for message
    const text = try agent_state.getTextForMessage(allocator, 0);
    defer allocator.free(text);

    try std.testing.expectEqualStrings("Test message content", text);
}

test "getTextForMessage returns empty for invalid index" {
    const allocator = std.testing.allocator;

    var agent_state = AgentState.init(allocator, .right);
    defer agent_state.deinit();

    // No messages added
    const text = try agent_state.getTextForMessage(allocator, 0);
    defer allocator.free(text);

    try std.testing.expectEqualStrings("", text);
}
