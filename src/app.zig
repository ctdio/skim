const std = @import("std");
const vaxis = @import("vaxis");
const git = @import("git/diff.zig");
const blame = @import("git/blame.zig");
const parser = @import("git/parser.zig");
const syntax = @import("highlighting/core.zig");
const comments = @import("comments/store.zig");
const line_map = @import("line_map.zig");
const mcp_client = @import("mcp/client.zig");
const mcp_protocol = @import("mcp/protocol.zig");
const mcp_registry = @import("mcp/registry.zig");
const mcp_handlers = @import("mcp/handlers.zig");
const navigation = @import("navigation.zig");
const search = @import("search.zig");
const clipboard = @import("clipboard.zig");
const rendering_common = @import("rendering/common.zig");
const render_utils = @import("rendering/utils.zig");
const render_unified = @import("rendering/unified.zig");
const render_side_by_side = @import("rendering/side_by_side.zig");
const state_helpers = @import("state.zig");
const ui_components = @import("ui.zig");
const editor = @import("editor.zig");
const comment_editor = @import("comments/editor.zig");
const command_palette = @import("command_palette.zig");
const help = @import("help.zig");

// Mode handlers
const normal_mode = @import("modes/normal_mode.zig");
const comment_mode = @import("modes/comment_mode.zig");
const search_mode = @import("modes/search_mode.zig");
const visual_mode = @import("modes/visual_mode.zig");
const command_palette_mode = @import("modes/command_palette_mode.zig");
const help_mode = @import("modes/help_mode.zig");
const branch_selection_mode = @import("modes/branch_selection_mode.zig");
const mcp_status_mode = @import("modes/mcp_status_mode.zig");
const mcp_status = @import("mcp_status.zig");
const graphite_mode = @import("modes/graphite_mode.zig");
const model_selection_mode = @import("modes/model_selection_mode.zig");
const agent_selection_mode = @import("modes/agent_selection_mode.zig");
const agent_mode = @import("modes/agent_mode.zig");
const agent = @import("agent/agent.zig");
const app_config = @import("config.zig");
const graphite = @import("git/graphite.zig");
const acp = @import("acp/acp.zig");

const DiffSource = git.DiffSource;
const Navigation = navigation.Navigation;
const RenderUtils = render_utils.RenderUtils;
const UnifiedRenderer = render_unified.UnifiedRenderer;
const SideBySideRenderer = render_side_by_side.SideBySideRenderer;
const StateHelpers = state_helpers.StateHelpers;
const AsyncHighlightJob = state_helpers.AsyncHighlightJob;
const UI = ui_components.UI;
const DividerPosition = ui_components.DividerPosition;

const Allocator = std.mem.Allocator;
const Vaxis = vaxis.Vaxis;
const Event = vaxis.Event;

// Use centralized definitions from rendering/common.zig
const Color = rendering_common.Color;
const Layout = rendering_common.Layout;
const FrameChars = rendering_common.FrameChars;

const HEADER_BUFFER_WIDTH = 4096;
const FRAME_TEXT_CAPACITY = 262144; // 256 KiB per frame scratch space

const PendingJob = struct {
    content: []const u8, // Owned NEW file content
    old_content: []const u8, // Owned OLD file content
};

// Static buffer for vaxis Tty writer (must persist for lifetime of Tty)
var tty_static_buffer: [4096]u8 = undefined;

/// Context for ACP connection thread
pub const AcpConnectContext = struct {
    app: *App,
    cwd: []const u8,
    agent: ?*const acp.AgentInfo, // Selected agent to connect to (null = use discovery)
};

pub const App = struct {
    allocator: Allocator,
    vx: Vaxis,
    tty: vaxis.Tty,
    mode: Mode,
    state: State,
    should_quit: bool,
    should_suspend_for_editor: bool,
    editor_file_path: ?[]const u8,
    editor_line_number: ?usize,
    last_ctrl_c: i64,
    header_line_buffers: [Layout.header_height][HEADER_BUFFER_WIDTH]u8,
    frame_text_buffer: []u8,
    frame_text_used: usize,
    syntax_highlighter: syntax.SyntaxHighlighter,
    highlight_worker: ?*state_helpers.HighlightWorker, // Long-lived worker thread with cached parsers
    pending_highlight_jobs: std.AutoHashMap(usize, PendingJob), // file_idx -> owned content strings
    needs_render: bool, // Flag to force re-render (e.g., after async highlighting)
    needs_async_highlight: bool, // Flag to trigger async highlighting for current file
    mcp: ?*mcp_client.McpClient, // MCP client for server connection
    mcp_port: ?u16, // Port to connect to MCP server
    blame_cache: std.StringHashMap(blame.BlameData), // file_path -> blame data
    acp_manager: ?*acp.AcpManager, // ACP agent session manager
    acp_connect_thread: ?std.Thread, // Background thread for ACP connection
    acp_connect_ctx: ?*AcpConnectContext, // Context for ACP connection thread (freed after join)
    in_bracketed_paste: bool, // Whether we're currently receiving bracketed paste input
    agent_only: bool, // Start in agent-only mode (no diff view)

    const Mode = enum {
        normal, // Normal navigation and viewing
        comment, // Comment editing
        search, // Search input
        visual, // Visual selection mode
        command_palette, // Command palette
        help, // Help overlay
        branch_selection, // Branch selection menu (when empty)
        mcp_status, // MCP server connection status
        graphite_stack, // Graphite stack picker
        agent, // Agent chat panel
        model_selection, // AI model selection menu
        agent_selection, // Agent selection menu (before connecting)
    };

    // Character find commands for NORMAL mode (f/t/F/T)
    pub const FindCommand = enum {
        f, // Find character forward (move to char)
        t, // Till character forward (move before char)
        F, // Find character backward
        T, // Till character backward
    };

    // Last find operation for ; and , repeat in NORMAL mode
    const NormalModeLastFind = struct {
        command: FindCommand,
        char: u8,
    };

    const State = struct {
        diff_source: DiffSource,
        git_repo_root: []const u8, // Absolute path to git repository root
        files: []parser.FileDiff,
        line_map: line_map.LineMap, // Complete map of all lines
        current_file_idx: usize, // Tracks which file is visible in sticky header
        global_scroll_offset: usize, // Scroll position across all files
        global_cursor_line: usize, // Cursor position across all files
        cursor_column: usize, // Horizontal cursor position within current line (0-based)
        view_mode: ViewMode,
        hunk_view_mode: HunkViewMode,
        viewport_height: usize,
        count_prefix: ?usize, // For vim-style count prefixes (e.g., 5j)
        comment_store: comments.CommentStore,
        active_comment_input: ?comment_editor.CommentEditor.State,
        search_state: SearchState,
        command_palette_state: command_palette.CommandPaletteState,
        visual_anchor: ?usize, // Visual mode: anchor line (where selection started)
        pending_find: ?FindCommand, // Waiting for character for f/t/F/T
        last_find: ?NormalModeLastFind, // Last f/t/F/T command for ; and , repeat
        pending_z: bool, // Waiting for second z for zz (center cursor)
        pending_g: bool, // Waiting for second g for gg (agent mode: scroll to top)
        pending_bracket: bool, // Waiting for second character after [ (like [h)
        pending_close_bracket: bool, // Waiting for second character after ] (like ]h)
        empty_menu_selection: usize, // Selected index in empty state menu (0 = working, 1 = staged, 2 = main, 3 = branch, 4 = refresh, 5 = quit)
        branch_list: [][]const u8, // List of available branches for selection
        branch_selection: usize, // Selected branch index in branch selection menu
        branch_search_query: [256]u8, // Search query buffer for filtering branches
        branch_search_len: usize, // Length of search query
        filtered_branches: std.ArrayList(usize), // Indices of branches matching search query
        help_scroll_offset: usize, // Scroll position in help overlay
        expanded_comments: std.AutoHashMap(usize, void), // Set of expanded comment indices

        pending_ctrl_w: bool, // Waiting for second key in Ctrl+w chord
        pending_leader: bool, // Waiting for second key after leader (,)

        // Temporary status message
        status_message: ?[]const u8, // Message to show in status bar
        status_message_owned: ?[]const u8, // Owned copy (for freeing)
        status_message_time: i64, // When message was set (for auto-clear)

        // Blame view
        show_blame: bool, // Whether to show git blame info in gutter

        // Cached stats for menu items (fetched async to avoid blocking UI)
        menu_stats_cached: bool, // Whether stats have been fetched
        menu_stats_loading: bool, // Whether async fetch is in progress
        working_stats: git.DiffStats,
        staged_stats: git.DiffStats,
        main_stats: git.DiffStats,
        default_branch_name: ?[]const u8, // Cached default branch name
        branch_stats_cache: std.AutoHashMap(usize, git.DiffStats), // branch_idx -> stats

        // Graphite stack state (lazy-loaded to avoid blocking startup)
        graphite_detected: bool, // Has graphite detection been performed?
        graphite_available: bool, // Is gt CLI installed?
        graphite_stack: ?graphite.GraphiteStack, // Current stack (null if not graphite repo)
        graphite_stack_selection: usize, // Selected index in stack picker

        // Model selection state
        model_selection: usize, // Selected index in model picker

        // Agent selection state (for choosing which agent to connect to)
        configured_agents: ?[]acp.AgentInfo, // Available agents from config or fallback
        agent_selection_idx: usize, // Selected index in agent picker

        // Agent panel state
        agent_state: ?agent.AgentState, // Agent chat panel state

        const ViewMode = enum {
            unified,
            side_by_side,
        };

        const HunkViewMode = enum {
            all, // Show all lines (add, delete, context) - displayed as "+/-"
            old, // Show old code only (delete, context) - displayed as "-"
            new, // Show new code only (add, context) - displayed as "+"

            pub fn next(self: HunkViewMode) HunkViewMode {
                return switch (self) {
                    .all => .new,
                    .new => .old,
                    .old => .all,
                };
            }

            pub fn prev(self: HunkViewMode) HunkViewMode {
                return switch (self) {
                    .all => .old,
                    .old => .new,
                    .new => .all,
                };
            }

            pub fn toSymbol(self: HunkViewMode) []const u8 {
                return switch (self) {
                    .all => "+/-",
                    .old => "-",
                    .new => "+",
                };
            }

            // Check if a line type should be visible in this mode
            pub fn shouldShowLine(self: HunkViewMode, line_type: parser.Line.LineType) bool {
                return switch (self) {
                    .all => true,
                    .old => line_type == .delete or line_type == .context,
                    .new => line_type == .add or line_type == .context,
                };
            }
        };
    };

    // SearchState is now in search.zig
    const SearchState = search.SearchState;

    const CTRL_C_TIMEOUT_NS = 1 * std.time.ns_per_s; // 1 second window

    pub fn init(allocator: Allocator, config: anytype) !App {
        // Use static buffer for Tty (must persist for lifetime of Tty)
        var tty = try vaxis.Tty.init(&tty_static_buffer);
        errdefer tty.deinit();

        var vx = try Vaxis.init(allocator, .{
            // Enable kitty keyboard protocol for proper modifier detection (Shift+Enter, etc.)
            .kitty_keyboard_flags = .{
                .disambiguate = true,
                .report_events = false,
                .report_alternate_keys = true,
                .report_all_as_ctl_seqs = true,
                .report_text = true,
            },
            // Enable system clipboard allocator for paste support (OSC 52)
            .system_clipboard_allocator = allocator,
        });
        errdefer vx.deinit(allocator, tty.writer());

        // Get git repository root (for resolving file paths)
        const git_repo_root = try git.getRepoRoot(allocator);
        errdefer allocator.free(git_repo_root);

        // Load git diff (including untracked files for working directory mode)
        const diff_result = try git.getDiffWithUntracked(allocator, config.diff_source);
        errdefer diff_result.deinit(allocator);

        const files = try parser.parse(allocator, diff_result.diff_text);
        errdefer {
            for (files) |*file| {
                file.deinit(allocator);
            }
            allocator.free(files);
        }

        // Mark untracked files
        parser.markUntrackedFiles(files, diff_result.untracked_paths);
        diff_result.deinit(allocator);

        const header_buffers = std.mem.zeroes([Layout.header_height][HEADER_BUFFER_WIDTH]u8);

        const frame_buffer = try allocator.alloc(u8, FRAME_TEXT_CAPACITY);
        errdefer allocator.free(frame_buffer);
        @memset(frame_buffer, 0);

        var syntax_highlighter = try syntax.SyntaxHighlighter.init(allocator);
        errdefer syntax_highlighter.deinit();

        var comment_store = comments.CommentStore.init(allocator);
        errdefer comment_store.deinit();

        // Build the line map (default to showing all lines, filtering enabled for unified view)
        var built_line_map = try line_map.LineMap.build(allocator, files, &comment_store, .all, true);
        errdefer built_line_map.deinit();

        // Deep copy diff_source - App takes ownership of its own copy
        // so Config.deinit() and App.deinit() don't double-free
        const owned_diff_source: DiffSource = switch (config.diff_source) {
            .working_dir => |wd| .{ .working_dir = wd },
            .single_ref => |sr| .{ .single_ref = .{
                .ref = try allocator.dupe(u8, sr.ref),
                .staged = sr.staged,
            } },
            .two_refs => |tr| blk: {
                const ref1 = try allocator.dupe(u8, tr.ref1);
                errdefer allocator.free(ref1);
                const ref2 = try allocator.dupe(u8, tr.ref2);
                break :blk .{ .two_refs = .{
                    .ref1 = ref1,
                    .ref2 = ref2,
                    .use_merge_base = tr.use_merge_base,
                } };
            },
        };
        errdefer switch (owned_diff_source) {
            .working_dir => {},
            .single_ref => |sr| allocator.free(sr.ref),
            .two_refs => |tr| {
                allocator.free(tr.ref1);
                allocator.free(tr.ref2);
            },
        };

        const app = App{
            .allocator = allocator,
            .vx = vx,
            .tty = tty,
            .mode = .normal,
            .state = State{
                .diff_source = owned_diff_source,
                .git_repo_root = git_repo_root,
                .files = files,
                .line_map = built_line_map,
                .current_file_idx = 0,
                .global_scroll_offset = 0,
                .global_cursor_line = 0,
                .cursor_column = 0,
                .view_mode = .unified,
                .hunk_view_mode = .all,
                .viewport_height = 0,
                .count_prefix = null,
                .comment_store = comment_store,
                .active_comment_input = null,
                .search_state = SearchState.init(allocator),
                .command_palette_state = command_palette.CommandPaletteState.init(allocator),
                .visual_anchor = null,
                .pending_find = null,
                .last_find = null,
                .pending_z = false,
                .pending_g = false,
                .pending_bracket = false,
                .pending_close_bracket = false,
                .empty_menu_selection = 0,
                .branch_list = &[_][]const u8{},
                .branch_selection = 0,
                .branch_search_query = undefined,
                .branch_search_len = 0,
                .filtered_branches = .{},
                .help_scroll_offset = 0,
                .expanded_comments = std.AutoHashMap(usize, void).init(allocator),
                .pending_ctrl_w = false,
                .pending_leader = false,
                .status_message = null,
                .status_message_owned = null,
                .status_message_time = 0,
                .show_blame = false,
                .menu_stats_cached = false,
                .menu_stats_loading = false,
                .working_stats = git.DiffStats{ .files = 0, .additions = 0, .deletions = 0 },
                .staged_stats = git.DiffStats{ .files = 0, .additions = 0, .deletions = 0 },
                .main_stats = git.DiffStats{ .files = 0, .additions = 0, .deletions = 0 },
                .default_branch_name = null,
                .branch_stats_cache = std.AutoHashMap(usize, git.DiffStats).init(allocator),
                .graphite_detected = false, // Lazy detection on first access
                .graphite_available = false,
                .graphite_stack = null,
                .graphite_stack_selection = 0,
                .model_selection = 0,
                .configured_agents = null, // Loaded when agent panel opens
                .agent_selection_idx = 0,
                .agent_state = null, // Lazy initialization on first toggle
            },
            .should_quit = false,
            .should_suspend_for_editor = false,
            .editor_file_path = null,
            .editor_line_number = null,
            .last_ctrl_c = 0,
            .header_line_buffers = header_buffers,
            .frame_text_buffer = frame_buffer,
            .frame_text_used = 0,
            .syntax_highlighter = syntax_highlighter,
            .highlight_worker = null, // Will be created on first use
            .pending_highlight_jobs = std.AutoHashMap(usize, PendingJob).init(allocator),
            .needs_render = false,
            .needs_async_highlight = true, // Start with highlighting needed for first file
            .mcp = null,
            .mcp_port = if (@hasField(@TypeOf(config), "mcp_port")) config.mcp_port else null,
            .blame_cache = std.StringHashMap(blame.BlameData).init(allocator),
            .acp_manager = null,
            .acp_connect_thread = null,
            .acp_connect_ctx = null,
            .in_bracketed_paste = false,
            .agent_only = if (@hasField(@TypeOf(config), "agent_only")) config.agent_only else false,
        };

        // Graphite detection is lazy - happens on first access to avoid blocking startup
        // Main loop will spawn background thread to highlight initial file
        return app;
    }

    pub fn deinit(self: *App) void {
        // Clean up highlight worker
        if (self.highlight_worker) |worker| {
            worker.deinit();
        }

        // Free pending job content strings
        var iter = self.pending_highlight_jobs.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.content);
            self.allocator.free(entry.value_ptr.old_content);
        }
        self.pending_highlight_jobs.deinit();

        // Free diff_source if needed
        switch (self.state.diff_source) {
            .working_dir => {},
            .single_ref => |sr| {
                self.allocator.free(sr.ref);
            },
            .two_refs => |tr| {
                self.allocator.free(tr.ref1);
                self.allocator.free(tr.ref2);
            },
        }

        self.allocator.free(self.state.git_repo_root);
        for (self.state.files) |*file| {
            file.deinit(self.allocator);
        }
        self.allocator.free(self.state.files);
        self.allocator.free(self.frame_text_buffer);
        self.state.line_map.deinit();
        self.state.comment_store.deinit();
        self.state.search_state.deinit();
        self.state.command_palette_state.deinit();
        // Free branch list
        for (self.state.branch_list) |branch| {
            self.allocator.free(branch);
        }
        self.allocator.free(self.state.branch_list);
        self.state.filtered_branches.deinit(self.allocator);
        self.state.expanded_comments.deinit();
        self.state.branch_stats_cache.deinit();
        // Clean up cached default branch name
        if (self.state.default_branch_name) |name| {
            self.allocator.free(name);
        }
        // Clean up graphite stack
        if (self.state.graphite_stack) |*stack| {
            stack.deinit(self.allocator);
        }
        // Clean up MCP client
        if (self.mcp) |mcp| {
            mcp.deinit();
            self.allocator.destroy(mcp);
        }
        // Clean up ACP connection thread and context
        if (self.acp_connect_thread) |thread| {
            thread.detach();
            self.acp_connect_thread = null;
        }
        if (self.acp_connect_ctx) |ctx| {
            self.allocator.destroy(ctx);
            self.acp_connect_ctx = null;
        }
        // Clean up ACP manager
        if (self.acp_manager) |mgr| {
            mgr.deinit();
            self.allocator.destroy(mgr);
        }
        // Clean up blame cache
        var blame_iter = self.blame_cache.iterator();
        while (blame_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.blame_cache.deinit();
        self.syntax_highlighter.deinit();
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
    }

    pub fn refresh(self: *App) !void {
        // Load fresh git diff (including untracked files for working directory mode)
        const diff_result = try git.getDiffWithUntracked(self.allocator, self.state.diff_source);
        defer diff_result.deinit(self.allocator);

        const new_files = try parser.parse(self.allocator, diff_result.diff_text);
        errdefer {
            for (new_files) |*file| {
                file.deinit(self.allocator);
            }
            self.allocator.free(new_files);
        }

        // Mark untracked files
        parser.markUntrackedFiles(new_files, diff_result.untracked_paths);

        // Try to preserve current file if it still exists
        var new_file_idx: usize = 0;
        if (self.state.current_file_idx < self.state.files.len) {
            const current_file = &self.state.files[self.state.current_file_idx];
            const current_path = if (current_file.new_path.len > 0)
                current_file.new_path
            else
                current_file.old_path;

            // Search for the same file in new files
            for (new_files, 0..) |*new_file, idx| {
                const new_path = if (new_file.new_path.len > 0)
                    new_file.new_path
                else
                    new_file.old_path;

                if (std.mem.eql(u8, current_path, new_path)) {
                    new_file_idx = idx;
                    break;
                }
            }
        }

        // Free old files and line map
        for (self.state.files) |*file| {
            file.deinit(self.allocator);
        }
        self.allocator.free(self.state.files);
        self.state.line_map.deinit();

        // Rebuild line map with new files (preserve hunk view mode)
        const new_line_map = try line_map.LineMap.build(self.allocator, new_files, &self.state.comment_store, self.convertHunkViewMode(), self.shouldApplyHunkFiltering());
        errdefer {
            // If LineMap.build failed, clean up new_files since old state is already freed
            for (new_files) |*file| {
                file.deinit(self.allocator);
            }
            self.allocator.free(new_files);
        }

        // Update state with new files and line map
        self.state.files = new_files;
        self.state.line_map = new_line_map;
        self.state.current_file_idx = new_file_idx;

        // Clamp global cursor to total line count (don't reset to 0)
        const total_lines = self.getTotalGlobalLines();
        if (total_lines > 0 and self.state.global_cursor_line >= total_lines) {
            self.state.global_cursor_line = total_lines - 1;
        }
        Navigation.clampScrollOffset(self);

        // Invalidate menu stats cache (will be re-fetched on next render if needed)
        self.state.menu_stats_cached = false;
        self.state.menu_stats_loading = false;
        if (self.state.default_branch_name) |name| {
            self.allocator.free(name);
            self.state.default_branch_name = null;
        }
        self.state.branch_stats_cache.clearRetainingCapacity();

        // Refresh graphite stack (branch state may have changed)
        self.refreshGraphiteStack();
    }

    /// Stage the current file (git add) and refresh the view
    pub fn stageCurrentFile(self: *App) !void {
        if (self.state.files.len == 0) return;
        if (self.state.current_file_idx >= self.state.files.len) return;

        const file = &self.state.files[self.state.current_file_idx];
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

        if (file_path.len == 0) return;

        // Stage the file
        git.stageFile(self.allocator, file_path) catch {
            // Show error in status message
            self.state.status_message = "Failed to stage file";
            self.state.status_message_time = std.time.milliTimestamp();
            return;
        };

        // Show success message
        self.state.status_message = "File staged";
        self.state.status_message_time = std.time.milliTimestamp();

        // Refresh to reflect changes
        try self.refresh();
    }

    /// Stage all files (git add -A) and switch to staged view
    pub fn stageAllFiles(self: *App) !void {
        // Stage all files
        git.stageAllFiles(self.allocator) catch {
            self.state.status_message = "Failed to stage files";
            self.state.status_message_time = std.time.milliTimestamp();
            return;
        };

        // Show success message
        self.state.status_message = "All files staged";
        self.state.status_message_time = std.time.milliTimestamp();

        // Switch to staged view to show what was staged
        try self.switchDiffMode(.staged);
    }

    // Update current_file_idx based on cursor position and trigger highlighting if file changed
    pub fn updateCurrentFileAndTriggerHighlighting(self: *App) void {
        const cursor_file_idx = self.state.line_map.getFileIndexForLine(self.state.global_cursor_line) orelse return;

        // If we moved to a different file, update and request highlighting
        if (cursor_file_idx != self.state.current_file_idx) {
            self.state.current_file_idx = cursor_file_idx;
            self.needs_async_highlight = true;
        }
    }

    pub fn run(self: *App) !void {
        // Set up the terminal
        const writer = self.tty.writer();

        try self.vx.enterAltScreen(writer);

        // Query terminal capabilities (50ms timeout - enough for modern terminals)
        try self.vx.queryTerminal(writer, 50 * std.time.ns_per_ms);

        var loop: vaxis.Loop(Event) = .{
            .tty = &self.tty,
            .vaxis = &self.vx,
        };
        try loop.init();
        try loop.start();
        defer loop.stop();

        // Auto-connect to MCP server (only if MCP is enabled)
        if (app_config.isMcpEnabled(self.allocator)) {
            const mcp_port = self.mcp_port orelse 9999;
            std.log.debug("MCP: Attempting to connect to port {d}", .{mcp_port});
            if (self.allocator.create(mcp_client.McpClient)) |m| {
                m.* = mcp_client.McpClient.init(self.allocator);

                // Try connecting with retries (3 attempts with backoff)
                if (m.connectWithRetry(mcp_port, 3)) {
                    std.log.debug("MCP: Connection successful, connected={}", .{m.connected});
                    self.mcp = m;
                    // Small delay to ensure daemon has finished accepting
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    // Send hello message to register with server
                    self.sendMcpHello() catch |err| {
                        std.log.debug("MCP: Failed to send hello: {any}", .{err});
                    };
                    std.log.debug("MCP: Hello sent, connected={}", .{m.connected});
                } else |err| {
                    std.log.debug("MCP: Connection failed after retries: {any}", .{err});
                    // Server not available - keep client for potential reconnection
                    self.mcp = m;
                }
            } else |_| {
                // Allocation failed - continue without MCP
            }
        }

        // If agent-only mode, start with agent panel open and in full-screen mode
        if (self.agent_only) {
            // Initialize agent state
            const config = app_config.load(self.allocator) catch app_config.Config{};
            const panel_side: agent.AgentState.PanelSide = switch (config.agent_panel_side) {
                .left => .left,
                .right => .right,
            };
            self.state.agent_state = agent.AgentState.init(self.allocator, panel_side);

            var agent_state = &(self.state.agent_state.?);
            agent_state.visible = true;
            agent_state.full_screen = true;
            self.mode = .agent;

            // Add local slash commands (like /model)
            agent_state.addLocalSlashCommands() catch |err| {
                std.log.err("Failed to add local slash commands: {any}", .{err});
            };

            // Start ACP session
            self.startAcpSession() catch |err| {
                std.log.err("Failed to start ACP session: {any}", .{err});
            };
        }

        var first_render = true;

        // Main event loop
        while (!self.should_quit) {
            // Only block on pollEvent if we don't need to render AND no async job is running
            // AND not connected to MCP (reader thread may queue messages anytime)
            // AND not needing MCP reconnection (reconnect logic must run periodically)
            // AND no active review process streaming to the panel
            // AND no ACP connection in progress or active session
            // This allows async operations to trigger immediate renders
            const mcp_active = if (self.mcp) |mcp| mcp.connected or mcp.needsReconnect() else false;
            const stats_loading = self.state.menu_stats_loading;
            const agent_panel_visible = if (self.state.agent_state) |as| as.visible else false;
            // Consider ACP "active" during connection phases and communication
            // This ensures non-blocking event loop while connecting (for responsive UI)
            // Note: .connected is included because createSession() runs AFTER connect() sets .connected
            const acp_active = if (self.acp_manager) |mgr| mgr.status == .discovering or mgr.status == .connecting or mgr.status == .connected or mgr.status == .prompting or (agent_panel_visible and mgr.status == .session_active) else false;
            const should_poll = !self.needs_render and self.pending_highlight_jobs.count() == 0 and !mcp_active and !stats_loading and !acp_active;
            if (should_poll) {
                loop.pollEvent();
            }
            // When not blocking (acp_active, mcp_active, etc.), events are still
            // captured by the vaxis reader thread and available via tryEvent()

            // Check if we need to suspend for editor
            if (self.should_suspend_for_editor) {
                // Stop the event loop to release TTY
                loop.stop();

                // Exit alt screen
                try self.vx.exitAltScreen(self.tty.writer());

                // Open editor (blocks until editor exits)
                if (self.editor_file_path) |file_path| {
                    defer self.allocator.free(file_path);
                    editor.openInEditor(self.allocator, file_path, self.editor_line_number) catch |err| {
                        std.log.err("Failed to open editor: {any}", .{err});
                    };
                }

                // Re-enter alt screen
                try self.vx.enterAltScreen(self.tty.writer());

                // Restart the event loop
                try loop.start();

                // Refresh diff after returning from editor
                try self.refresh();

                // Force a full render after re-entering alt screen
                self.needs_render = true;

                // Clear the suspend flag
                self.should_suspend_for_editor = false;
                self.editor_file_path = null;
                self.editor_line_number = null;
            }

            // Process all pending events
            var had_events = false;
            while (loop.tryEvent()) |event| {
                try self.handleEvent(event);
                had_events = true;
            }

            // Clear expired messages
            self.clearExpiredStatusMessage();

            // Poll ACP agent for updates
            self.pollAcpUpdates();

            // Force re-render while agent is discovering/connecting/thinking
            // This keeps the UI responsive during connection
            if (self.acp_manager) |mgr| {
                if (mgr.status == .discovering or mgr.status == .connecting or mgr.status == .connected or mgr.status == .prompting) {
                    self.needs_render = true;
                }
            }

            // Render if we had events, need to update, or first render
            if (had_events or self.needs_render or first_render) {
                const win = self.vx.window();
                try self.render(win);
                try self.vx.render(self.tty.writer());
                // Don't clear needs_render if we're about to suspend for editor
                // This prevents blocking on the next pollEvent()
                if (!self.should_suspend_for_editor) {
                    self.needs_render = false; // Clear the flag after rendering
                }
            }

            if (first_render) {
                first_render = false;
            }

            // Check for completed highlighting results
            if (self.highlight_worker) |worker| {
                var results: std.ArrayList(state_helpers.HighlightResult) = .{};
                defer results.deinit(self.allocator);

                worker.pollResults(self.allocator, &results) catch {};

                for (results.items) |result| {
                    const file_idx = result.file_idx;

                    // Remove from pending jobs and free content
                    if (self.pending_highlight_jobs.fetchRemove(file_idx)) |entry| {
                        self.allocator.free(entry.value.content);
                        self.allocator.free(entry.value.old_content);
                    }

                    // Apply highlights to file
                    if (result.highlights) |highlights| {
                        if (file_idx < self.state.files.len) {
                            const file = &self.state.files[file_idx];
                            const mutable_file = @constCast(file);
                            mutable_file.highlights = highlights;

                            // Also apply old highlights if available
                            if (result.old_highlights) |old_highlights| {
                                mutable_file.old_highlights = old_highlights;
                            }

                            // Only trigger re-render if this is the CURRENT file
                            if (file_idx == self.state.current_file_idx) {
                                self.needs_render = true;
                            }
                        } else {
                            // File no longer exists (refresh happened), free highlights
                            if (self.highlight_worker) |w| {
                                w.highlighter.freeHighlights(highlights);
                                if (result.old_highlights) |old_highlights| {
                                    w.highlighter.freeHighlights(old_highlights);
                                }
                            }
                        }
                    }
                }
            }

            // Process MCP messages (reader thread handles receiving)
            if (self.mcp) |mcp| {
                // Check if reconnection is needed (reader thread sets flag on disconnect)
                if (mcp.needsReconnect()) {
                    if (mcp.tryReconnect()) {
                        // Small delay to ensure daemon has finished accepting
                        std.Thread.sleep(10 * std.time.ns_per_ms);
                        // Reconnected - send hello again to re-register
                        self.sendMcpHello() catch {};
                    }
                }

                const messages = mcp.consumeMessages();
                defer mcp.freeMessages(messages);

                for (messages) |*msg| {
                    try self.handleMcpMessage(msg);
                }
            }

            // Submit highlighting jobs for visible files
            // Strategy: Highlight files that are currently visible on screen
            // This ensures smooth scrolling without waiting for highlights
            if (self.state.files.len > 0) {
                // Create worker on first use
                if (self.highlight_worker == null) {
                    self.highlight_worker = state_helpers.HighlightWorker.init(self.allocator) catch null;
                }

                if (self.highlight_worker) |worker| {
                    // Determine which files are visible in the viewport
                    // Strategy: Check files around scroll position (current + next few)
                    const viewport_height = self.state.viewport_height;
                    const scroll_line = self.state.global_scroll_offset;
                    const visible_end = scroll_line + viewport_height;

                    // Start from file at scroll position
                    const start_file_idx = self.state.line_map.getFileIndexForLine(scroll_line) orelse 0;

                    // Submit jobs for visible files (current + up to 3 ahead for smooth scrolling)
                    var files_submitted: usize = 0;
                    var check_idx = start_file_idx;
                    while (check_idx < self.state.files.len and files_submitted < 4) : (check_idx += 1) {
                        const file = &self.state.files[check_idx];

                        // Skip if already highlighted or job pending
                        if (file.highlights != null or self.pending_highlight_jobs.contains(check_idx)) {
                            continue;
                        }

                        // Check if this file is visible or close to visible
                        if (self.state.line_map.getFileHeaderLine(check_idx)) |file_header_line| {
                            // Only submit if file starts before end of viewport + buffer
                            const buffer_lines = viewport_height; // One screen ahead
                            if (file_header_line > visible_end + buffer_lines) {
                                break; // File is too far ahead
                            }
                        }

                        // Build NEW file content (add/context lines)
                        const content = StateHelpers.buildFileContent(self.allocator, file) catch continue;
                        errdefer self.allocator.free(content);

                        // Build OLD file content (delete/context lines)
                        const old_content = StateHelpers.buildOldFileContent(self.allocator, file) catch {
                            self.allocator.free(content);
                            continue;
                        };
                        errdefer self.allocator.free(old_content);

                        // Submit job to worker
                        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;
                        worker.submitJob(.{
                            .file_path = file_path,
                            .content = content,
                            .old_content = old_content,
                            .file_idx = check_idx,
                        }) catch {
                            self.allocator.free(content);
                            self.allocator.free(old_content);
                            continue;
                        };

                        // Track pending job (store both content strings)
                        self.pending_highlight_jobs.put(check_idx, .{
                            .content = content,
                            .old_content = old_content,
                        }) catch {
                            self.allocator.free(content);
                            self.allocator.free(old_content);
                        };

                        files_submitted += 1;
                    }
                }

                // Reset the flag after processing
                self.needs_async_highlight = false;
            }
        }

        // Exit alt screen before returning
        try self.vx.exitAltScreen(self.tty.writer());
    }

    fn handleEvent(self: *App, event: Event) !void {
        switch (event) {
            .key_press => |key| try self.handleKey(key),
            .winsize => |ws| try self.vx.resize(self.allocator, self.tty.writer(), ws),
            .paste_start => {
                self.in_bracketed_paste = true;
            },
            .paste_end => {
                self.in_bracketed_paste = false;
            },
            .paste => |text| {
                // Handle OSC 52 paste: insert full text into active input
                try self.handlePastedText(text);
                // Free the text allocated by vaxis
                self.allocator.free(text);
            },
            else => {},
        }
    }

    fn handlePastedText(self: *App, text: []const u8) !void {
        switch (self.mode) {
            .agent => {
                if (self.state.agent_state) |*agent_state| {
                    // Insert pasted text into input editor
                    for (text) |char| {
                        if (char == '\r') continue; // Skip carriage returns
                        agent.InputEditor.insertCharPublic(&agent_state.input, char);
                    }
                    self.needs_render = true;
                }
            },
            .comment => {
                // Insert into comment editor
                if (self.state.active_comment_input) |*input| {
                    for (text) |char| {
                        if (char == '\r') continue;
                        comment_editor.CommentEditor.insertCharPublic(input, char);
                    }
                    self.needs_render = true;
                }
            },
            .search => {
                // Insert into search input
                for (text) |char| {
                    if (char >= 32 and char < 127) {
                        if (self.state.search_state.query_len < self.state.search_state.query_buffer.len - 1) {
                            self.state.search_state.query_buffer[self.state.search_state.query_len] = char;
                            self.state.search_state.query_len += 1;
                        }
                    }
                }
                self.needs_render = true;
            },
            else => {},
        }
    }

    fn handleKey(self: *App, key: vaxis.Key) !void {
        // Handle Ctrl-C for double-press exit (or single press in modal overlays)
        if (key.mods.ctrl and key.codepoint == 'c') {
            // In modal overlay modes, single Ctrl-C closes the modal
            switch (self.mode) {
                .command_palette => {
                    self.mode = .normal;
                    self.state.command_palette_state.reset();
                    self.needs_render = true;
                    return;
                },
                .help => {
                    self.mode = .normal;
                    self.needs_render = true;
                    return;
                },
                .search => {
                    self.mode = .normal;
                    self.state.search_state.reset();
                    self.needs_render = true;
                    return;
                },
                .branch_selection => {
                    self.mode = .normal;
                    self.state.branch_search_len = 0;
                    self.state.filtered_branches.clearRetainingCapacity();
                    self.needs_render = true;
                    return;
                },
                .visual => {
                    self.mode = .normal;
                    self.state.visual_anchor = null;
                    return;
                },
                .mcp_status => {
                    self.mode = .normal;
                    self.needs_render = true;
                    return;
                },
                .graphite_stack => {
                    self.mode = .normal;
                    self.needs_render = true;
                    return;
                },
                .model_selection => {
                    self.mode = .normal;
                    self.needs_render = true;
                    return;
                },
                .agent_selection => {
                    // Cancel agent selection, close panel
                    self.mode = .normal;
                    self.needs_render = true;
                    return;
                },
                .agent => {
                    // In agent mode, respect vim mode state:
                    // - Insert mode: first Ctrl+C exits to normal vim mode
                    // - Normal vim mode: double Ctrl+C exits the app
                    if (self.state.agent_state) |*agent_state| {
                        if (agent_state.input.vim.vim_mode == .insert) {
                            // First Ctrl+C in insert mode - exit to normal vim mode
                            // (handled by vim_editor, will be processed below)
                            // Fall through to agent_mode.handleKey
                        } else {
                            // In normal vim mode - require double Ctrl+C to exit app
                            if (agent_state.recordCtrlCPress()) {
                                // Double Ctrl+C detected - exit the app
                                self.should_quit = true;
                            }
                            // Single Ctrl+C - wait for second press (do nothing)
                            return;
                        }
                    }
                },
                .normal, .comment => {
                    // In normal/comment modes, double-press to quit
                    const now: i64 = @intCast(std.time.nanoTimestamp());
                    if (now - self.last_ctrl_c < App.CTRL_C_TIMEOUT_NS) {
                        self.should_quit = true;
                        return;
                    }
                    self.last_ctrl_c = now;
                    return;
                },
            }
        }

        // Reset double-press timer on any other key
        self.last_ctrl_c = 0;

        switch (self.mode) {
            .normal => try normal_mode.handleKey(self, key),
            .comment => try comment_mode.handleKey(self, key),
            .search => try search_mode.handleKey(self, key),
            .visual => try visual_mode.handleKey(self, key),
            .command_palette => try command_palette_mode.handleKey(self, key),
            .help => try help_mode.handleKey(self, key),
            .branch_selection => try branch_selection_mode.handleKey(self, key),
            .mcp_status => try mcp_status_mode.handleKey(self, key),
            .graphite_stack => try graphite_mode.handleKey(self, key),
            .model_selection => try model_selection_mode.handleKey(self, key),
            .agent_selection => try agent_selection_mode.handleKey(self, key),
            .agent => try agent_mode.handleKey(self, key),
        }
    }

    pub fn toggleViewMode(self: *App) void {
        // Capture current position for anchoring
        const old_cursor = self.state.global_cursor_line;
        const old_scroll = self.state.global_scroll_offset;

        // Toggle view mode
        self.state.view_mode = switch (self.state.view_mode) {
            .unified => .side_by_side,
            .side_by_side => .unified,
        };

        // Rebuild LineMap because filtering rules changed
        // Side-by-side: always show all lines (filtering=false)
        // Unified: apply current hunk view mode (filtering=true)
        self.state.line_map.deinit();
        self.state.line_map = line_map.LineMap.build(
            self.allocator,
            self.state.files,
            &self.state.comment_store,
            self.convertHunkViewMode(),
            self.shouldApplyHunkFiltering(),
        ) catch |err| {
            std.log.err("Failed to rebuild LineMap on view toggle: {any}", .{err});
            return;
        };

        // Restore cursor and scroll positions (simple preservation since line count may have changed)
        const total_lines = self.getTotalGlobalLines();
        if (total_lines > 0) {
            self.state.global_cursor_line = @min(old_cursor, total_lines - 1);
            self.state.global_scroll_offset = @min(old_scroll, total_lines - 1);
        } else {
            self.state.global_cursor_line = 0;
            self.state.global_scroll_offset = 0;
        }
        Navigation.clampScrollOffset(self);
    }

    pub fn toggleBlame(self: *App) void {
        self.state.show_blame = !self.state.show_blame;
        self.needs_render = true;

        // If enabling blame, fetch blame for all visible files
        if (self.state.show_blame) {
            self.fetchBlameForVisibleFiles();
        }
    }

    /// Toggle the agent chat panel visibility and focus
    pub fn toggleAgentPanel(self: *App) !void {
        // Check if ACP is enabled
        if (!app_config.isAcpEnabled(self.allocator)) {
            self.showStatusMessage("ACP is experimental. Enable in ~/.skim/config.json");
            return;
        }

        // Initialize agent state if first time opening
        if (self.state.agent_state == null) {
            // Load panel side from config
            const config = app_config.load(self.allocator) catch app_config.Config{};
            const panel_side: agent.AgentState.PanelSide = switch (config.agent_panel_side) {
                .left => .left,
                .right => .right,
            };
            self.state.agent_state = agent.AgentState.init(self.allocator, panel_side);
        }

        var agent_state = &(self.state.agent_state.?);

        if (agent_state.visible) {
            // Hide panel, return to normal mode
            agent_state.visible = false;
            self.mode = .normal;
        } else {
            // Show panel, enter agent mode
            agent_state.visible = true;
            self.mode = .agent;

            // Re-enable scroll following when reopening panel
            // (user may have scrolled up before closing, we want to see new messages)
            agent_state.scrollToBottom();

            // Add local slash commands (like /model)
            agent_state.addLocalSlashCommands() catch |err| {
                std.log.err("Failed to add local slash commands: {any}", .{err});
            };

            // Auto-connect to ACP agent if not connected
            if (self.acp_manager == null or self.acp_manager.?.status == .disconnected) {
                try self.startAcpSession();
            }
        }

        self.needs_render = true;
    }

    /// Fetch blame data for all visible files (cached per file path)
    fn fetchBlameForVisibleFiles(self: *App) void {
        for (self.state.files) |*file| {
            const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

            // Skip if already cached
            if (self.blame_cache.contains(file_path)) continue;

            // Skip untracked files (no blame available)
            if (file.is_untracked) continue;

            // Fetch blame data
            const blame_data = blame.getBlame(self.allocator, file_path, null) catch {
                // Silently skip files that fail to blame (binary, too large, etc.)
                continue;
            };

            // Cache it (need to dupe the key since file_path is from parsed diff)
            const key = self.allocator.dupe(u8, file_path) catch continue;
            self.blame_cache.put(key, blame_data) catch {
                self.allocator.free(key);
                var bd = blame_data;
                bd.deinit();
            };
        }
    }

    /// Get blame info for a specific file line (returns null if not available)
    pub fn getBlameForLine(self: *App, file_path: []const u8, lineno: u32) ?*const blame.BlameLine {
        const data = self.blame_cache.get(file_path) orelse return null;
        return data.getLine(lineno);
    }

    pub fn cycleHunkViewModePrev(self: *App) !void {
        // Only apply in unified mode
        if (!self.shouldApplyHunkFiltering()) return;

        // Same logic as cycleHunkViewMode but cycles backwards
        const old_record = self.state.line_map.getLineRecord(self.state.global_cursor_line);

        var anchor: ?struct {
            file_idx: usize,
            hunk_idx: ?usize,
            cursor_offset: isize,
            scroll_offset: isize,
        } = null;

        if (old_record) |rec| {
            var anchor_line: ?usize = null;
            var anchor_file: usize = rec.file_idx;
            var anchor_hunk: ?usize = null;

            switch (rec.line_type) {
                .file_header => {
                    anchor_line = self.state.global_cursor_line;
                    anchor_hunk = null;
                },
                .hunk_header => |hunk_info| {
                    anchor_line = self.state.global_cursor_line;
                    anchor_hunk = hunk_info.hunk_idx;
                },
                .code_line => |code_info| {
                    anchor_line = self.findHunkHeaderLine(rec.file_idx, code_info.hunk_idx);
                    anchor_hunk = code_info.hunk_idx;
                },
                .comment_line => |comment_info| {
                    anchor_line = self.findHunkHeaderLine(rec.file_idx, comment_info.parent_hunk_idx);
                    anchor_hunk = comment_info.parent_hunk_idx;
                },
                .spacer => |spacer_info| {
                    const next_file_idx = if (spacer_info.is_header_spacer)
                        spacer_info.after_file_idx
                    else
                        spacer_info.after_file_idx + 1;

                    anchor_file = next_file_idx;
                    anchor_line = self.state.line_map.getFileHeaderLine(next_file_idx);
                    anchor_hunk = null;
                },
            }

            if (anchor_line) |anc_line| {
                anchor = .{
                    .file_idx = anchor_file,
                    .hunk_idx = anchor_hunk,
                    .cursor_offset = @as(isize, @intCast(self.state.global_cursor_line)) - @as(isize, @intCast(anc_line)),
                    .scroll_offset = @as(isize, @intCast(self.state.global_scroll_offset)) - @as(isize, @intCast(anc_line)),
                };
            }
        }

        // Cycle to previous mode
        self.state.hunk_view_mode = self.state.hunk_view_mode.prev();

        // Rebuild LineMap
        self.state.line_map.deinit();
        self.state.line_map = try line_map.LineMap.build(self.allocator, self.state.files, &self.state.comment_store, self.convertHunkViewMode(), self.shouldApplyHunkFiltering());

        // Restore positions
        if (anchor) |anc| {
            if (anc.file_idx < self.state.files.len) {
                const new_anchor_line = if (anc.hunk_idx) |hunk_idx|
                    self.findHunkHeaderLine(anc.file_idx, hunk_idx)
                else
                    self.state.line_map.getFileHeaderLine(anc.file_idx);

                if (new_anchor_line) |anchor_line| {
                    const total_lines = self.getTotalGlobalLines();
                    if (total_lines == 0) {
                        self.state.global_cursor_line = 0;
                        self.state.global_scroll_offset = 0;
                        return;
                    }

                    const target_cursor_signed = @as(isize, @intCast(anchor_line)) + anc.cursor_offset;
                    const target_cursor = if (target_cursor_signed < 0) 0 else @as(usize, @intCast(target_cursor_signed));
                    self.state.global_cursor_line = @min(target_cursor, total_lines - 1);

                    const target_scroll_signed = @as(isize, @intCast(anchor_line)) + anc.scroll_offset;
                    const target_scroll = if (target_scroll_signed < 0) 0 else @as(usize, @intCast(target_scroll_signed));
                    self.state.global_scroll_offset = target_scroll;

                    Navigation.clampScrollOffset(self);
                    return;
                }
            }
        }

        const total_lines = self.getTotalGlobalLines();
        if (total_lines > 0 and self.state.global_cursor_line >= total_lines) {
            self.state.global_cursor_line = total_lines - 1;
        }
        Navigation.clampScrollOffset(self);
    }

    pub fn cycleHunkViewMode(self: *App) !void {
        // Only apply in unified mode
        if (!self.shouldApplyHunkFiltering()) return;

        // Before rebuilding, capture anchor information to preserve BOTH cursor and scroll positions
        // This prevents the viewport from jumping around
        const old_record = self.state.line_map.getLineRecord(self.state.global_cursor_line);

        var anchor: ?struct {
            file_idx: usize,
            hunk_idx: ?usize, // null means anchor to file header
            cursor_offset: isize, // signed offset of cursor from anchor line
            scroll_offset: isize, // signed offset of scroll from anchor line
        } = null;

        if (old_record) |rec| {
            // Find the anchor line for this record
            var anchor_line: ?usize = null;
            var anchor_file: usize = rec.file_idx;
            var anchor_hunk: ?usize = null;

            switch (rec.line_type) {
                .file_header => {
                    // Cursor is on file header - anchor to it
                    anchor_line = self.state.global_cursor_line;
                    anchor_hunk = null;
                },
                .hunk_header => |hunk_info| {
                    // Cursor is on hunk header - anchor to it
                    anchor_line = self.state.global_cursor_line;
                    anchor_hunk = hunk_info.hunk_idx;
                },
                .code_line => |code_info| {
                    // Cursor is on code line - anchor to the hunk header
                    anchor_line = self.findHunkHeaderLine(rec.file_idx, code_info.hunk_idx);
                    anchor_hunk = code_info.hunk_idx;
                },
                .comment_line => |comment_info| {
                    // Cursor is on comment - anchor to the hunk header
                    anchor_line = self.findHunkHeaderLine(rec.file_idx, comment_info.parent_hunk_idx);
                    anchor_hunk = comment_info.parent_hunk_idx;
                },
                .spacer => |spacer_info| {
                    // Cursor is on spacer - anchor to the file header
                    const next_file_idx = if (spacer_info.is_header_spacer)
                        spacer_info.after_file_idx
                    else
                        spacer_info.after_file_idx + 1;

                    anchor_file = next_file_idx;
                    anchor_line = self.state.line_map.getFileHeaderLine(next_file_idx);
                    anchor_hunk = null;
                },
            }

            // If we found an anchor, calculate offsets
            if (anchor_line) |anc_line| {
                anchor = .{
                    .file_idx = anchor_file,
                    .hunk_idx = anchor_hunk,
                    .cursor_offset = @as(isize, @intCast(self.state.global_cursor_line)) - @as(isize, @intCast(anc_line)),
                    .scroll_offset = @as(isize, @intCast(self.state.global_scroll_offset)) - @as(isize, @intCast(anc_line)),
                };
            }
        }

        // Cycle to next mode
        self.state.hunk_view_mode = self.state.hunk_view_mode.next();

        // Rebuild LineMap to reflect new filtering
        self.state.line_map.deinit();
        self.state.line_map = try line_map.LineMap.build(self.allocator, self.state.files, &self.state.comment_store, self.convertHunkViewMode(), self.shouldApplyHunkFiltering());

        // Restore both cursor and scroll positions using anchor
        if (anchor) |anc| {
            if (anc.file_idx < self.state.files.len) {
                // Find the anchor line in the new LineMap
                const new_anchor_line = if (anc.hunk_idx) |hunk_idx|
                    self.findHunkHeaderLine(anc.file_idx, hunk_idx)
                else
                    self.state.line_map.getFileHeaderLine(anc.file_idx);

                if (new_anchor_line) |anchor_line| {
                    const total_lines = self.getTotalGlobalLines();
                    if (total_lines == 0) {
                        self.state.global_cursor_line = 0;
                        self.state.global_scroll_offset = 0;
                        return;
                    }

                    // Restore cursor: anchor + offset
                    const target_cursor_signed = @as(isize, @intCast(anchor_line)) + anc.cursor_offset;
                    const target_cursor = if (target_cursor_signed < 0) 0 else @as(usize, @intCast(target_cursor_signed));
                    self.state.global_cursor_line = @min(target_cursor, total_lines - 1);

                    // Restore scroll: anchor + offset
                    const target_scroll_signed = @as(isize, @intCast(anchor_line)) + anc.scroll_offset;
                    const target_scroll = if (target_scroll_signed < 0) 0 else @as(usize, @intCast(target_scroll_signed));
                    self.state.global_scroll_offset = target_scroll;

                    // Only clamp scroll if it's out of bounds (minimal adjustment)
                    Navigation.clampScrollOffset(self);
                    return;
                }
            }
        }

        // Fallback: if anchor restoration failed, just clamp cursor and scroll
        const total_lines = self.getTotalGlobalLines();
        if (total_lines > 0 and self.state.global_cursor_line >= total_lines) {
            self.state.global_cursor_line = total_lines - 1;
        }
        Navigation.clampScrollOffset(self);
    }

    // Helper: Find the global line number of a hunk header
    fn findHunkHeaderLine(self: *App, file_idx: usize, hunk_idx: usize) ?usize {
        for (self.state.line_map.records) |*record| {
            if (record.file_idx == file_idx and record.line_type == .hunk_header) {
                if (record.line_type.hunk_header.hunk_idx == hunk_idx) {
                    return record.global_line;
                }
            }
        }
        return null;
    }

    // Convert App.State.HunkViewMode to LineMap.HunkViewMode
    fn convertHunkViewMode(self: *App) line_map.LineMap.HunkViewMode {
        return switch (self.state.hunk_view_mode) {
            .all => .all,
            .old => .old,
            .new => .new,
        };
    }

    // Check if hunk view mode filtering should be applied (only in unified view)
    fn shouldApplyHunkFiltering(self: *App) bool {
        return self.state.view_mode == .unified;
    }

    pub fn getTotalGlobalLines(self: *App) usize {
        return self.state.line_map.getTotalLines();
    }

    // Get the content of the line at the current cursor position
    pub fn getCurrentLineContent(self: *App) ?[]const u8 {
        // Get line record from LineMap
        const record = self.state.line_map.getLineRecord(self.state.global_cursor_line) orelse return null;

        if (record.file_idx >= self.state.files.len) return null;
        const file = &self.state.files[record.file_idx];

        return switch (record.line_type) {
            .code_line => |code| file.hunks[code.hunk_idx].lines[code.line_idx_in_hunk].content,
            .file_header, .hunk_header, .comment_line, .spacer => null,
        };
    }

    // Execute a find command (f/t/F/T) in NORMAL mode
    pub fn executeFindInLine(self: *App, cmd: FindCommand, target_char: u8) void {
        const line_content = self.getCurrentLineContent() orelse return;
        const count = self.state.count_prefix orelse 1;
        self.state.count_prefix = null; // Clear count prefix

        const line_len = line_content.len;
        var found_count: usize = 0;

        switch (cmd) {
            .f => { // Find forward - move to character
                var pos = self.state.cursor_column + 1;
                while (pos < line_len) : (pos += 1) {
                    if (line_content[pos] == target_char) {
                        found_count += 1;
                        if (found_count == count) {
                            self.state.cursor_column = pos;
                            self.state.last_find = .{ .command = cmd, .char = target_char };
                            return;
                        }
                    }
                }
            },
            .t => { // Till forward - move before character
                var pos = self.state.cursor_column + 1;
                while (pos < line_len) : (pos += 1) {
                    if (line_content[pos] == target_char) {
                        found_count += 1;
                        if (found_count == count) {
                            self.state.cursor_column = if (pos > 0) pos - 1 else 0;
                            self.state.last_find = .{ .command = cmd, .char = target_char };
                            return;
                        }
                    }
                }
            },
            .F => { // Find backward - move to character
                if (self.state.cursor_column > 0) {
                    var pos = self.state.cursor_column - 1;
                    while (true) {
                        if (line_content[pos] == target_char) {
                            found_count += 1;
                            if (found_count == count) {
                                self.state.cursor_column = pos;
                                self.state.last_find = .{ .command = cmd, .char = target_char };
                                return;
                            }
                        }
                        if (pos == 0) break;
                        pos -= 1;
                    }
                }
            },
            .T => { // Till backward - move after character
                if (self.state.cursor_column > 0) {
                    var pos = self.state.cursor_column - 1;
                    while (true) {
                        if (line_content[pos] == target_char) {
                            found_count += 1;
                            if (found_count == count) {
                                self.state.cursor_column = @min(pos + 1, line_len - 1);
                                self.state.last_find = .{ .command = cmd, .char = target_char };
                                return;
                            }
                        }
                        if (pos == 0) break;
                        pos -= 1;
                    }
                }
            },
        }
    }

    pub fn startCommentInput(self: *App) !void {
        // Get line record from LineMap
        const record = self.state.line_map.getLineRecord(self.state.global_cursor_line) orelse return;

        if (record.file_idx >= self.state.files.len) return;
        const file = &self.state.files[record.file_idx];
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

        var target_hunk_idx: usize = undefined;
        var target_line_idx: usize = undefined;
        var existing_comment_idx: ?usize = null;

        switch (record.line_type) {
            .file_header, .hunk_header, .spacer => {
                // Can't comment on these line types
                return;
            },
            .code_line => |code| {
                // Check if there's already a comment on this code line
                target_hunk_idx = code.hunk_idx;
                target_line_idx = code.line_idx_in_hunk;

                // First check if there's an existing comment in the store
                existing_comment_idx = self.state.comment_store.findCommentAt(
                    file_path,
                    target_hunk_idx,
                    target_line_idx,
                );

                // If we found an existing comment, move cursor to the comment line
                if (existing_comment_idx != null) {
                    // Find the comment line in the LineMap (it should be right after this code line)
                    const total_lines = self.state.line_map.getTotalLines();
                    var search_line = self.state.global_cursor_line + 1;
                    while (search_line < total_lines) : (search_line += 1) {
                        if (self.state.line_map.getLineRecord(search_line)) |search_record| {
                            if (search_record.line_type == .comment_line) {
                                const comment_info = search_record.line_type.comment_line;
                                if (comment_info.comment_idx == existing_comment_idx.?) {
                                    // Found the comment line - move cursor to it
                                    self.state.global_cursor_line = search_line;
                                    break;
                                }
                            } else if (search_record.line_type != .spacer) {
                                // Reached a non-spacer, non-comment line - stop searching
                                break;
                            }
                        }
                    }
                }
            },
            .comment_line => |comment_info| {
                // User pressed Enter on the comment line itself - edit that comment
                target_hunk_idx = comment_info.parent_hunk_idx;
                target_line_idx = comment_info.parent_line_idx;
                existing_comment_idx = comment_info.comment_idx;
            },
        }

        // Initialize input buffer
        var input = comment_editor.CommentEditor.State{
            .target_file_path = file_path,
            .target_hunk_idx = target_hunk_idx,
            .target_line_idx = target_line_idx,
            .target_end_hunk_idx = null, // Single-line comment
            .target_end_line_idx = null, // Single-line comment
            .editing_comment_idx = existing_comment_idx,
            .vim = comment_editor.CommentEditor.VimEditor.State.initWithMode(.insert),
        };

        // If editing existing comment, load its text
        if (existing_comment_idx) |idx| {
            if (self.state.comment_store.getComment(idx)) |comment| {
                input.vim.setText(comment.text);
                input.vim.cursor_pos = input.vim.text_len; // Start cursor at end
            }
        }

        self.state.active_comment_input = input;
        self.mode = .comment;
    }

    pub fn startCommentInputForVisualSelection(self: *App) !void {
        // Get visual selection range
        const selection = self.getVisualSelection() orelse return;
        const start_line = selection.start;
        const end_line = selection.end;

        // Get records for start and end lines
        const start_record = self.state.line_map.getLineRecord(start_line) orelse return;
        const end_record = self.state.line_map.getLineRecord(end_line) orelse return;

        // Selection must be within the same file
        if (start_record.file_idx != end_record.file_idx) {
            return; // Can't comment across multiple files
        }

        // Can only comment on code lines
        if (start_record.line_type != .code_line or end_record.line_type != .code_line) {
            return;
        }

        const start_code = start_record.line_type.code_line;
        const end_code = end_record.line_type.code_line;

        // Selection must be within the same hunk
        if (start_code.hunk_idx != end_code.hunk_idx) {
            return; // Can't comment across multiple hunks
        }

        // Get file information from start line
        if (start_record.file_idx >= self.state.files.len) return;
        const file = &self.state.files[start_record.file_idx];
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

        // Check if selection is a single line
        const is_single_line = (start_line == end_line);

        // Initialize input buffer for range comment
        const input = comment_editor.CommentEditor.State{
            .target_file_path = file_path,
            .target_hunk_idx = start_code.hunk_idx,
            .target_line_idx = start_code.line_idx_in_hunk,
            .target_end_hunk_idx = if (is_single_line) null else end_code.hunk_idx,
            .target_end_line_idx = if (is_single_line) null else end_code.line_idx_in_hunk,
            .editing_comment_idx = null, // Always creating new comment from visual mode
            .vim = comment_editor.CommentEditor.VimEditor.State.initWithMode(.insert),
        };

        self.state.active_comment_input = input;
        self.mode = .comment;

        // Move cursor to the end of the range (lowest selection point) where the comment will appear
        self.state.global_cursor_line = end_line;

        // Ensure the comment box is visible on screen
        // Use extra padding to account for comment box height (starts with ~4 lines minimum)
        Navigation.ensureCommentBoxVisible(self);

        // Exit visual mode
        self.state.visual_anchor = null;
    }

    pub fn saveCurrentComment(self: *App) !void {
        if (self.state.active_comment_input == null) return;

        const input = self.state.active_comment_input.?;
        if (input.vim.text_len == 0) {
            // Empty comment - delete if editing existing, otherwise do nothing
            if (input.editing_comment_idx) |idx| {
                try self.state.comment_store.deleteComment(idx);
            }
            return;
        }

        const comment_text = input.vim.text_buffer[0..input.vim.text_len];

        // Get line context for the comment
        const file = &self.state.files[self.state.current_file_idx];
        const hunk = &file.hunks[input.target_hunk_idx];
        const line = &hunk.lines[input.target_line_idx];

        // Track the comment index for cursor positioning after save
        var saved_comment_idx: usize = undefined;

        if (input.editing_comment_idx) |idx| {
            // Update existing comment
            try self.state.comment_store.updateComment(idx, comment_text);
            saved_comment_idx = idx;
        } else {
            // Check if this is a range comment
            if (input.target_end_hunk_idx != null and input.target_end_line_idx != null) {
                // Add range comment
                try self.state.comment_store.addRangeComment(
                    input.target_file_path,
                    input.target_hunk_idx,
                    input.target_line_idx,
                    input.target_end_hunk_idx.?,
                    input.target_end_line_idx.?,
                    comment_text,
                    line.line_type,
                    line.content,
                    line.old_lineno,
                    line.new_lineno,
                );
            } else {
                // Add single-line comment
                try self.state.comment_store.addComment(
                    input.target_file_path,
                    input.target_hunk_idx,
                    input.target_line_idx,
                    comment_text,
                    line.line_type,
                    line.content,
                    line.old_lineno,
                    line.new_lineno,
                );
            }
            // New comment is at the end of the list
            saved_comment_idx = self.state.comment_store.comments.items.len - 1;
        }

        // Rebuild LineMap since comment count changed
        self.state.line_map.deinit();
        self.state.line_map = try line_map.LineMap.build(self.allocator, self.state.files, &self.state.comment_store, self.convertHunkViewMode(), self.shouldApplyHunkFiltering());

        // Move cursor to the saved comment so it can be easily yanked
        if (self.state.line_map.findLineByCommentIdx(saved_comment_idx)) |comment_line| {
            self.state.global_cursor_line = comment_line;
        }
    }

    pub fn yankCurrentCommentToClipboard(self: *App) !void {
        // Get line record from LineMap
        const record = self.state.line_map.getLineRecord(self.state.global_cursor_line) orelse return;

        switch (record.line_type) {
            .comment_line => |comment_info| {
                // Generate export with context (10 lines before, 10 lines after for LLM context)
                const output = try self.state.comment_store.exportSingleCommentWithContext(
                    self.allocator,
                    comment_info.comment_idx,
                    self.state.files,
                    10, // lines before
                    10, // lines after
                );
                defer self.allocator.free(output);

                try clipboard.copyToClipboard(self.allocator, output);
            },
            else => {}, // Not on a comment line, do nothing
        }
    }

    pub fn yankAllCommentsToClipboard(self: *App) !void {
        // Generate export with context (10 lines before, 10 lines after for LLM context)
        const output = try self.state.comment_store.exportWithContext(
            self.allocator,
            self.state.files,
            10, // lines before
            10, // lines after
        );
        defer self.allocator.free(output);

        try clipboard.copyToClipboard(self.allocator, output);
    }

    /// Yank all comments and send to agent panel input
    pub fn yankCommentsToAgent(self: *App) !void {
        // Check if ACP is enabled
        if (!app_config.isAcpEnabled(self.allocator)) {
            return;
        }

        // Generate export with context (10 lines before, 10 lines after for LLM context)
        const output = try self.state.comment_store.exportWithContext(
            self.allocator,
            self.state.files,
            10, // lines before
            10, // lines after
        );
        defer self.allocator.free(output);

        if (output.len == 0) {
            self.showStatusMessage("No comments to send");
            return;
        }

        // Open agent panel if not already open
        if (self.state.agent_state) |*agent_state| {
            if (!agent_state.visible) {
                try self.toggleAgentPanel();
            }
            // Set the input text
            agent_state.input.setText(output);
            // Switch to insert mode so user can add context
            agent_state.input.vim.vim_mode = .insert;
            // Move cursor to end
            agent_state.input.vim.cursor_pos = agent_state.input.vim.text_len;
        } else {
            // No agent state yet, open panel first
            try self.toggleAgentPanel();
            if (self.state.agent_state) |*agent_state| {
                agent_state.input.setText(output);
                agent_state.input.vim.vim_mode = .insert;
                agent_state.input.vim.cursor_pos = agent_state.input.vim.text_len;
            }
        }

        self.needs_render = true;
    }

    pub fn deleteCommentUnderCursor(self: *App) !void {
        // Get line record from LineMap
        const record = self.state.line_map.getLineRecord(self.state.global_cursor_line) orelse return;

        switch (record.line_type) {
            .comment_line => |comment_info| {
                // Delete the comment
                try self.state.comment_store.deleteComment(comment_info.comment_idx);

                // Rebuild LineMap since comment count changed
                self.state.line_map.deinit();
                self.state.line_map = try line_map.LineMap.build(self.allocator, self.state.files, &self.state.comment_store, self.convertHunkViewMode(), self.shouldApplyHunkFiltering());

                // After deletion, move cursor up one line (to the parent code line)
                // since the comment line no longer exists
                if (self.state.global_cursor_line > 0) {
                    self.state.global_cursor_line -= 1;
                }
                Navigation.clampScrollOffset(self);
            },
            else => {
                // Not on a comment line - do nothing
                return;
            },
        }
    }

    pub fn toggleCommentUnderCursorExpanded(self: *App) void {
        // Get line record from LineMap
        const record = self.state.line_map.getLineRecord(self.state.global_cursor_line) orelse return;

        switch (record.line_type) {
            .comment_line => |comment_info| {
                self.toggleCommentExpanded(comment_info.comment_idx);
                self.needs_render = true;
            },
            else => {
                // Not on a comment line - do nothing
                return;
            },
        }
    }

    pub fn clearAllComments(self: *App) !void {
        self.state.comment_store.clearAll();

        // Rebuild LineMap since comment count changed
        self.state.line_map.deinit();
        self.state.line_map = try line_map.LineMap.build(self.allocator, self.state.files, &self.state.comment_store, self.convertHunkViewMode(), self.shouldApplyHunkFiltering());
    }

    pub fn openInEditor(self: *App) !void {
        // Get line record from LineMap
        const record = self.state.line_map.getLineRecord(self.state.global_cursor_line) orelse return;

        if (record.file_idx >= self.state.files.len) return;
        const file = &self.state.files[record.file_idx];
        const relative_path = if (file.new_path.len > 0) file.new_path else file.old_path;

        // Skip if it's a deleted file or /dev/null
        if (file.new_path.len == 0 or std.mem.eql(u8, relative_path, "/dev/null")) {
            return;
        }

        // Resolve to absolute path (git diff returns paths relative to repo root)
        const absolute_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.state.git_repo_root, relative_path });
        defer self.allocator.free(absolute_path);

        // Get the line number from the line type
        var line_number: ?usize = null;

        switch (record.line_type) {
            .code_line => |code| {
                const hunk = &file.hunks[code.hunk_idx];
                const line = &hunk.lines[code.line_idx_in_hunk];
                // Prefer new line number for added/context lines, old for deleted
                if (line.new_lineno) |new_line| {
                    line_number = new_line;
                } else if (line.old_lineno) |old_line| {
                    line_number = old_line;
                }
            },
            .hunk_header => |hunk_info| {
                // When on a hunk header, jump to the start of the hunk
                const hunk = &file.hunks[hunk_info.hunk_idx];
                line_number = hunk.header.new_start;
            },
            .comment_line => |comment_info| {
                // When on a comment, jump to the parent code line
                const hunk = &file.hunks[comment_info.parent_hunk_idx];
                const line = &hunk.lines[comment_info.parent_line_idx];
                if (line.new_lineno) |new_line| {
                    line_number = new_line;
                } else if (line.old_lineno) |old_line| {
                    line_number = old_line;
                }
            },
            .file_header, .spacer => {
                // No specific line number for these
                line_number = null;
            },
        }

        // Check if editor is terminal-based
        const is_terminal = try editor.isCurrentEditorTerminal(self.allocator);

        if (is_terminal) {
            // Terminal editor: suspend TUI and wait for editor to complete
            // Need to allocate the path since we're storing a pointer for later use
            const path_copy = try self.allocator.dupe(u8, absolute_path);
            self.should_suspend_for_editor = true;
            self.editor_file_path = path_copy;
            self.editor_line_number = line_number;
            // Prevent blocking on next pollEvent() so editor opens immediately
            self.needs_render = true;
        } else {
            // GUI editor: just spawn it without suspending TUI
            editor.openInEditor(self.allocator, absolute_path, line_number) catch |err| {
                std.log.err("Failed to open editor: {any}", .{err});
            };
        }
    }

    // Search functions
    pub fn startSearch(self: *App) void {
        self.state.search_state.reset();
        self.mode = .search;
    }

    pub fn startCommandPalette(self: *App) !void {
        self.state.command_palette_state.reset();
        // Build command registry with current files
        try self.state.command_palette_state.buildCommandRegistry(self, self.state.files);
        self.mode = .command_palette;
    }

    pub fn startCommandPaletteInCommandMode(self: *App) !void {
        self.state.command_palette_state.reset();
        // Build command registry with current files
        try self.state.command_palette_state.buildCommandRegistry(self, self.state.files);
        // Pre-populate with '>' to start in command mode
        self.state.command_palette_state.query_buffer[0] = '>';
        self.state.command_palette_state.query_len = 1;
        try self.state.command_palette_state.filterCommands();
        self.mode = .command_palette;
    }

    pub fn performSearch(self: *App) !void {
        try search.performSearch(&self.state.search_state, &self.state.line_map, self.state.files);
    }

    /// Jump to first search match (used for live search preview)
    pub fn jumpToFirstSearchMatch(self: *App) void {
        if (search.jumpToFirstMatch(&self.state.search_state, self.state.global_cursor_line)) |new_line| {
            self.state.global_cursor_line = new_line;
            Navigation.centerViewportOnCursor(self);
        }
    }

    pub fn executeCommand(self: *App, action: command_palette.CommandAction) !void {
        switch (action) {
            .jump_to_file => |file_idx| {
                // Navigate to file using existing file navigation logic
                if (file_idx < self.state.files.len) {
                    if (self.state.line_map.getFileHeaderLine(file_idx)) |header_line| {
                        self.state.global_cursor_line = header_line;
                        self.state.global_scroll_offset = header_line;
                        self.state.current_file_idx = file_idx;
                        self.needs_async_highlight = true;
                    }
                }
            },
            .toggle_view_mode => {
                // Toggle between unified and side-by-side
                self.state.view_mode = switch (self.state.view_mode) {
                    .unified => .side_by_side,
                    .side_by_side => .unified,
                };
            },
            .refresh_diff => {
                try self.refresh();
            },
            .show_help => {
                self.mode = .help;
            },
            .quit => {
                self.should_quit = true;
            },
            .switch_diff_mode => |mode| {
                try self.switchDiffMode(mode);
            },
            .show_mcp_status => {
                self.mode = .mcp_status;
            },
            .switch_agent => {
                // Disconnect current agent if connected
                if (self.acp_manager) |mgr| {
                    mgr.disconnect();
                    self.acp_manager = null;
                }
                // Reload agents and show selection
                _ = self.loadConfiguredAgents();
                self.mode = .agent_selection;
            },
        }
    }

    pub fn startBranchSelection(self: *App) !void {
        // Free old branch list
        for (self.state.branch_list) |branch| {
            self.allocator.free(branch);
        }
        self.allocator.free(self.state.branch_list);

        // Fetch branches
        self.state.branch_list = try git.getBranches(self.allocator);
        self.state.branch_selection = 0;
        self.state.branch_search_len = 0;

        // Initialize filtered list with all branches
        try self.filterBranches();

        self.mode = .branch_selection;
    }

    pub fn filterBranches(self: *App) !void {
        self.state.filtered_branches.clearRetainingCapacity();

        const query = self.state.branch_search_query[0..self.state.branch_search_len];

        // If no query, show all branches
        if (query.len == 0) {
            for (self.state.branch_list, 0..) |_, idx| {
                try self.state.filtered_branches.append(self.allocator, idx);
            }
            return;
        }

        // Case-insensitive search
        for (self.state.branch_list, 0..) |branch, idx| {
            if (self.matchesBranchQuery(branch, query)) {
                try self.state.filtered_branches.append(self.allocator, idx);
            }
        }

        // Clamp selection to filtered list
        if (self.state.filtered_branches.items.len > 0 and self.state.branch_selection >= self.state.filtered_branches.items.len) {
            self.state.branch_selection = self.state.filtered_branches.items.len - 1;
        }
    }

    fn matchesBranchQuery(self: *App, branch: []const u8, query: []const u8) bool {
        _ = self;
        // Simple case-insensitive substring match
        if (branch.len < query.len) return false;

        var i: usize = 0;
        while (i <= branch.len - query.len) : (i += 1) {
            var matches = true;
            for (query, 0..) |qc, j| {
                const bc = branch[i + j];
                const qc_lower = if (qc >= 'A' and qc <= 'Z') qc + 32 else qc;
                const bc_lower = if (bc >= 'A' and bc <= 'Z') bc + 32 else bc;
                if (qc_lower != bc_lower) {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }

    // Menu stats async fetching

    /// Context passed to the stats fetching thread
    const MenuStatsContext = struct {
        app: *App,
    };

    /// Start async fetching of menu stats (non-blocking)
    /// Call this on first render of empty menu, then check menu_stats_cached on subsequent renders
    pub fn startMenuStatsFetch(self: *App) void {
        if (self.state.menu_stats_cached or self.state.menu_stats_loading) return;

        self.state.menu_stats_loading = true;

        // Spawn detached thread to fetch stats
        const thread = std.Thread.spawn(.{}, menuStatsFetchWorker, .{self}) catch {
            // If thread spawn fails, fall back to sync fetch
            self.state.menu_stats_loading = false;
            self.fetchMenuStatsSync();
            return;
        };
        thread.detach();
    }

    /// Worker thread that fetches menu stats in background
    fn menuStatsFetchWorker(self: *App) void {
        // Use a thread-local allocator for git operations
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const alloc = gpa.allocator();

        // Fetch stats using thread-local allocator
        const working = git.getDiffStats(alloc, .{ .working_dir = .{ .staged = false } }) catch git.DiffStats{ .files = 0, .additions = 0, .deletions = 0 };
        const staged = git.getDiffStats(alloc, .{ .working_dir = .{ .staged = true } }) catch git.DiffStats{ .files = 0, .additions = 0, .deletions = 0 };

        // Detect default branch
        var default_branch: []const u8 = "main";
        var branch_allocated = false;
        if (git.detectDefaultBranch(alloc)) |branch| {
            default_branch = branch;
            branch_allocated = true;
        } else |_| {}
        defer if (branch_allocated) alloc.free(default_branch);

        const main_stats = git.getDiffStats(alloc, .{ .single_ref = .{ .ref = default_branch, .staged = false } }) catch git.DiffStats{ .files = 0, .additions = 0, .deletions = 0 };

        // Copy default branch name to app's allocator (for long-term storage)
        const branch_copy = self.allocator.dupe(u8, default_branch) catch null;

        // Write results to app state
        // Note: This is safe because we only read these when menu_stats_cached is true
        self.state.working_stats = working;
        self.state.staged_stats = staged;
        self.state.main_stats = main_stats;
        self.state.default_branch_name = branch_copy;
        self.state.menu_stats_cached = true;
        self.state.menu_stats_loading = false;

        // Trigger re-render so stats appear without user input
        self.needs_render = true;
    }

    /// Synchronous fallback for stats fetching (used if thread spawn fails)
    fn fetchMenuStatsSync(self: *App) void {
        self.state.working_stats = git.getDiffStats(self.allocator, .{ .working_dir = .{ .staged = false } }) catch git.DiffStats{ .files = 0, .additions = 0, .deletions = 0 };
        self.state.staged_stats = git.getDiffStats(self.allocator, .{ .working_dir = .{ .staged = true } }) catch git.DiffStats{ .files = 0, .additions = 0, .deletions = 0 };

        var default_branch: []const u8 = "main";
        var branch_allocated = false;
        if (git.detectDefaultBranch(self.allocator)) |branch| {
            default_branch = branch;
            branch_allocated = true;
        } else |_| {}

        self.state.main_stats = git.getDiffStats(self.allocator, .{ .single_ref = .{ .ref = default_branch, .staged = false } }) catch git.DiffStats{ .files = 0, .additions = 0, .deletions = 0 };

        // Store branch name (take ownership if allocated, otherwise dupe)
        if (branch_allocated) {
            self.state.default_branch_name = default_branch;
        } else {
            self.state.default_branch_name = self.allocator.dupe(u8, default_branch) catch null;
        }

        self.state.menu_stats_cached = true;
    }

    // Graphite stack functions

    /// Lazy graphite detection - only runs once on first access
    /// This avoids blocking startup with `which gt` and `gt state` calls
    pub fn ensureGraphiteDetected(self: *App) void {
        if (self.state.graphite_detected) return;

        self.state.graphite_detected = true;
        self.state.graphite_available = graphite.isGraphiteAvailable(self.allocator);

        if (self.state.graphite_available) {
            if (graphite.getGraphiteStack(self.allocator) catch null) |stack| {
                self.state.graphite_stack = stack;
            }
        }
    }

    pub fn startGraphiteStack(self: *App) !void {
        self.ensureGraphiteDetected();

        if (!self.state.graphite_available) {
            self.state.status_message = "Graphite CLI (gt) not installed";
            self.state.status_message_time = std.time.milliTimestamp();
            return;
        }

        // Use cached stack - don't re-fetch (that's slow)
        // Stack is refreshed on app refresh ('r' key)
        if (self.state.graphite_stack) |stack| {
            self.state.graphite_stack_selection = stack.current_idx;
            self.mode = .graphite_stack;
        } else {
            self.state.status_message = "Not in a Graphite stack";
            self.state.status_message_time = std.time.milliTimestamp();
        }
    }

    /// Refresh the graphite stack (called on app refresh)
    /// Only re-fetches if a graphite stack was already loaded to avoid unnecessary
    /// process spawns when not using graphite mode.
    pub fn refreshGraphiteStack(self: *App) void {
        // Skip if graphite hasn't been detected or isn't available
        if (!self.state.graphite_detected or !self.state.graphite_available) return;

        // Only re-fetch if we already had a graphite stack loaded
        // This avoids blocking when not using graphite mode
        if (self.state.graphite_stack == null) return;

        // Free old stack
        if (self.state.graphite_stack) |*old_stack| {
            old_stack.deinit(self.allocator);
            self.state.graphite_stack = null;
        }

        // Re-fetch stack
        if (graphite.getGraphiteStack(self.allocator) catch null) |stack| {
            self.state.graphite_stack = stack;
        }
    }

    pub fn selectGraphiteStackBranch(self: *App, idx: usize) !void {
        const stack = self.state.graphite_stack orelse return;
        if (idx >= stack.branches.len) return;

        const selected = &stack.branches[idx];

        // Free old diff_source
        switch (self.state.diff_source) {
            .working_dir => {},
            .single_ref => |sr| self.allocator.free(sr.ref),
            .two_refs => |tr| {
                self.allocator.free(tr.ref1);
                self.allocator.free(tr.ref2);
            },
        }

        // For trunk, diff against HEAD (working changes)
        // For other branches, diff against parent
        if (selected.is_trunk) {
            self.state.diff_source = DiffSource{ .working_dir = .{ .staged = false } };
        } else if (selected.parent_ref) |parent| {
            const parent_copy = try self.allocator.dupe(u8, parent);
            errdefer self.allocator.free(parent_copy);
            const branch_copy = try self.allocator.dupe(u8, selected.name);
            errdefer self.allocator.free(branch_copy);

            self.state.diff_source = DiffSource{ .two_refs = .{
                .ref1 = parent_copy,
                .ref2 = branch_copy,
                .use_merge_base = true,
            } };
        } else {
            // No parent - shouldn't happen for non-trunk branches
            self.state.status_message = "No parent branch found";
            self.state.status_message_time = std.time.milliTimestamp();
            return;
        }

        // Update current_idx in stack to reflect selection
        self.state.graphite_stack.?.current_idx = idx;

        // Go back to normal mode and refresh
        self.mode = .normal;
        try self.refresh();
    }

    /// Navigate to parent branch (toward trunk, visually down in stack display)
    pub fn navigateStackToParent(self: *App) !void {
        const stack = self.state.graphite_stack orelse {
            self.state.status_message = "Not in a Graphite stack";
            self.state.status_message_time = std.time.milliTimestamp();
            return;
        };

        if (stack.current_idx == 0) {
            self.state.status_message = "Already at trunk (bottom of stack)";
            self.state.status_message_time = std.time.milliTimestamp();
            return;
        }

        try self.selectGraphiteStackBranch(stack.current_idx - 1);
    }

    /// Navigate to child branch (toward tip, visually up in stack display)
    pub fn navigateStackToChild(self: *App) !void {
        const stack = self.state.graphite_stack orelse {
            self.state.status_message = "Not in a Graphite stack";
            self.state.status_message_time = std.time.milliTimestamp();
            return;
        };

        if (stack.current_idx + 1 >= stack.branches.len) {
            self.state.status_message = "Already at tip (top of stack)";
            self.state.status_message_time = std.time.milliTimestamp();
            return;
        }

        try self.selectGraphiteStackBranch(stack.current_idx + 1);
    }

    pub fn switchDiffMode(self: *App, mode: command_palette.DiffMode) !void {
        // Free old diff_source if needed
        switch (self.state.diff_source) {
            .working_dir => {},
            .single_ref => |sr| {
                self.allocator.free(sr.ref);
            },
            .two_refs => |tr| {
                self.allocator.free(tr.ref1);
                self.allocator.free(tr.ref2);
            },
        }

        // Update diff_source based on mode
        self.state.diff_source = switch (mode) {
            .working => DiffSource{ .working_dir = .{ .staged = false } },
            .staged => DiffSource{ .working_dir = .{ .staged = true } },
            .main => blk: {
                // Use cached default branch name if available (from async menu stats fetch)
                // to avoid blocking git command. Fall back to detection only if not cached.
                const default_branch = if (self.state.default_branch_name) |cached|
                    try self.allocator.dupe(u8, cached)
                else
                    try git.detectDefaultBranch(self.allocator);
                // Use single_ref to match command-line behavior (skim main)
                // This compares working tree to default branch
                break :blk DiffSource{ .single_ref = .{
                    .ref = default_branch,
                    .staged = false,
                } };
            },
        };

        // Refresh to load new diff
        try self.refresh();
    }

    pub fn searchNext(self: *App) void {
        if (search.nextMatch(&self.state.search_state, self.state.global_cursor_line)) |new_line| {
            self.state.global_cursor_line = new_line;
            Navigation.centerViewportOnCursor(self);
        }
    }

    pub fn searchPrevious(self: *App) void {
        if (search.previousMatch(&self.state.search_state, self.state.global_cursor_line)) |new_line| {
            self.state.global_cursor_line = new_line;
            Navigation.centerViewportOnCursor(self);
        }
    }

    // Visual mode functions
    pub fn startVisualMode(self: *App) void {
        self.state.visual_anchor = self.state.global_cursor_line;
        self.mode = .visual;
    }

    // Get the visual selection range (start_line, end_line) inclusive
    fn getVisualSelection(self: *App) ?struct { start: usize, end: usize } {
        const anchor = self.state.visual_anchor orelse return null;
        const cursor = self.state.global_cursor_line;

        const start = @min(anchor, cursor);
        const end = @max(anchor, cursor);

        return .{ .start = start, .end = end };
    }

    // Check if a line is in the visual selection
    pub fn isLineInVisualSelection(self: *App, global_line: usize) bool {
        if (self.mode != .visual) return false;

        const selection = self.getVisualSelection() orelse return false;
        return global_line >= selection.start and global_line <= selection.end;
    }

    // Check if a comment is expanded (collapsed by default)
    pub fn isCommentExpanded(self: *App, comment_idx: usize) bool {
        return self.state.expanded_comments.contains(comment_idx);
    }

    // Toggle comment expanded/collapsed state
    pub fn toggleCommentExpanded(self: *App, comment_idx: usize) void {
        if (self.state.expanded_comments.contains(comment_idx)) {
            _ = self.state.expanded_comments.remove(comment_idx);
        } else {
            self.state.expanded_comments.put(comment_idx, {}) catch {};
        }
    }

    pub fn yankVisualSelection(self: *App) !void {
        const selection = self.getVisualSelection() orelse return;

        // Build text from selected lines
        var buffer: std.ArrayList(u8) = .{};
        defer buffer.deinit(self.allocator);

        var line_idx = selection.start;
        while (line_idx <= selection.end) : (line_idx += 1) {
            const record = self.state.line_map.getLineRecord(line_idx) orelse continue;

            if (record.file_idx >= self.state.files.len) continue;
            const file = &self.state.files[record.file_idx];

            // Add line content based on type
            switch (record.line_type) {
                .file_header => {
                    const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;
                    try buffer.appendSlice(self.allocator, "File: ");
                    try buffer.appendSlice(self.allocator, file_path);
                    try buffer.append(self.allocator, '\n');
                },
                .hunk_header => |hunk_info| {
                    const hunk = &file.hunks[hunk_info.hunk_idx];
                    try buffer.appendSlice(self.allocator, "@@ -");
                    var num_buf: [32]u8 = undefined;
                    const old_start_str = try std.fmt.bufPrint(&num_buf, "{d}", .{hunk.header.old_start});
                    try buffer.appendSlice(self.allocator, old_start_str);
                    try buffer.append(self.allocator, ',');
                    const old_count_str = try std.fmt.bufPrint(&num_buf, "{d}", .{hunk.header.old_count});
                    try buffer.appendSlice(self.allocator, old_count_str);
                    try buffer.appendSlice(self.allocator, " +");
                    const new_start_str = try std.fmt.bufPrint(&num_buf, "{d}", .{hunk.header.new_start});
                    try buffer.appendSlice(self.allocator, new_start_str);
                    try buffer.append(self.allocator, ',');
                    const new_count_str = try std.fmt.bufPrint(&num_buf, "{d}", .{hunk.header.new_count});
                    try buffer.appendSlice(self.allocator, new_count_str);
                    try buffer.appendSlice(self.allocator, " @@\n");
                },
                .code_line => |code| {
                    const line = &file.hunks[code.hunk_idx].lines[code.line_idx_in_hunk];
                    // Add line type prefix
                    switch (line.line_type) {
                        .add => try buffer.append(self.allocator, '+'),
                        .delete => try buffer.append(self.allocator, '-'),
                        .context => try buffer.append(self.allocator, ' '),
                    }
                    try buffer.appendSlice(self.allocator, line.content);
                    try buffer.append(self.allocator, '\n');
                },
                .comment_line => |comment_info| {
                    if (self.state.comment_store.getComment(comment_info.comment_idx)) |comment| {
                        try buffer.appendSlice(self.allocator, "Comment: ");
                        try buffer.appendSlice(self.allocator, comment.text);
                        try buffer.append(self.allocator, '\n');
                    }
                },
                .spacer => {
                    // Skip spacer lines
                },
            }
        }

        try clipboard.copyToClipboard(self.allocator, buffer.items);
    }

    fn render(self: *App, win: vaxis.Window) !void {
        win.clear();
        RenderUtils.resetFrameTextBuffer(self);

        // Hide cursor by default - comment input will show it when needed
        win.hideCursor();

        // Content height without dividers (continuous mode)
        const content_height = win.height - Layout.header_height - Layout.status_height;

        // Check if agent panel should be shown (visible and not full-screen)
        // Don't show when in agent_selection mode (selecting which agent to connect to)
        const show_agent_panel = if (self.state.agent_state) |as|
            as.visible and !as.full_screen and self.mode != .agent_selection
        else
            false;

        // Render header and content (or empty/branch menu if no files)
        if (self.state.files.len == 0) {
            // No files - show empty state or branch selection menu
            // If agent panel is visible, render it as sidebar with empty menu in main area
            if (show_agent_panel) {
                const agent_state = self.state.agent_state.?;
                const panel_width = win.width * 3 / 10; // 30% for agent panel
                const divider_width: usize = 1;
                const diff_width = win.width - panel_width - divider_width;

                if (agent_state.panel_side == .left) {
                    // Agent panel on left
                    const agent_win = win.child(.{
                        .x_off = 0,
                        .y_off = Layout.header_height,
                        .width = @intCast(panel_width),
                        .height = @intCast(content_height),
                    });
                    try agent.renderAgentPanel(self, agent_win);

                    // Vertical divider
                    const divider_win = win.child(.{
                        .x_off = @intCast(panel_width),
                        .y_off = Layout.header_height,
                        .width = @intCast(divider_width),
                        .height = @intCast(content_height),
                    });
                    try UI.renderVerticalDivider(divider_win);

                    // Empty menu on right
                    const content_win = win.child(.{
                        .x_off = @intCast(panel_width + divider_width),
                        .y_off = 0,
                        .width = @intCast(diff_width),
                        .height = @intCast(win.height),
                    });
                    if (self.mode == .branch_selection) {
                        try UI.renderBranchSelectionMenu(self, content_win);
                    } else {
                        try UI.renderEmptyMenu(self, content_win);
                    }
                } else {
                    // Empty menu on left
                    const content_win = win.child(.{
                        .x_off = 0,
                        .y_off = 0,
                        .width = @intCast(diff_width),
                        .height = @intCast(win.height),
                    });
                    if (self.mode == .branch_selection) {
                        try UI.renderBranchSelectionMenu(self, content_win);
                    } else {
                        try UI.renderEmptyMenu(self, content_win);
                    }

                    // Vertical divider
                    const divider_win = win.child(.{
                        .x_off = @intCast(diff_width),
                        .y_off = Layout.header_height,
                        .width = @intCast(divider_width),
                        .height = @intCast(content_height),
                    });
                    try UI.renderVerticalDivider(divider_win);

                    // Agent panel on right
                    const agent_win = win.child(.{
                        .x_off = @intCast(diff_width + divider_width),
                        .y_off = Layout.header_height,
                        .width = @intCast(panel_width),
                        .height = @intCast(content_height),
                    });
                    try agent.renderAgentPanel(self, agent_win);
                }
            } else {
                // No agent panel - full screen empty menu
                if (self.mode == .branch_selection) {
                    try UI.renderBranchSelectionMenu(self, win);
                } else {
                    try UI.renderEmptyMenu(self, win);
                }
            }
        } else {
            // Normal rendering with header, content, and status bar
            const header_win = win.child(.{
                .x_off = 0,
                .y_off = 0,
                .width = @intCast(win.width),
                .height = @intCast(Layout.header_height),
            });
            try UI.renderHeader(self, header_win);

            // Split content area based on panels
            if (show_agent_panel) {
                const agent_state = self.state.agent_state.?;
                const panel_width = win.width * 3 / 10; // 30% for agent panel
                const divider_width: usize = 1;
                const diff_width = win.width - panel_width - divider_width;

                if (agent_state.panel_side == .left) {
                    // Agent panel on left
                    const agent_win = win.child(.{
                        .x_off = 0,
                        .y_off = Layout.header_height,
                        .width = @intCast(panel_width),
                        .height = @intCast(content_height),
                    });
                    try agent.renderAgentPanel(self, agent_win);

                    // Vertical divider
                    const divider_win = win.child(.{
                        .x_off = @intCast(panel_width),
                        .y_off = Layout.header_height,
                        .width = @intCast(divider_width),
                        .height = @intCast(content_height),
                    });
                    try UI.renderVerticalDivider(divider_win);

                    // Diff content on right
                    const content_win = win.child(.{
                        .x_off = @intCast(panel_width + divider_width),
                        .y_off = Layout.header_height,
                        .width = @intCast(diff_width),
                        .height = @intCast(content_height),
                    });
                    try self.renderContent(content_win);
                } else {
                    // Agent panel on right (default)
                    const content_win = win.child(.{
                        .x_off = 0,
                        .y_off = Layout.header_height,
                        .width = @intCast(diff_width),
                        .height = @intCast(content_height),
                    });
                    try self.renderContent(content_win);

                    // Vertical divider
                    const divider_win = win.child(.{
                        .x_off = @intCast(diff_width),
                        .y_off = Layout.header_height,
                        .width = @intCast(divider_width),
                        .height = @intCast(content_height),
                    });
                    try UI.renderVerticalDivider(divider_win);

                    // Agent panel on right
                    const agent_win = win.child(.{
                        .x_off = @intCast(diff_width + divider_width),
                        .y_off = Layout.header_height,
                        .width = @intCast(panel_width),
                        .height = @intCast(content_height),
                    });
                    try agent.renderAgentPanel(self, agent_win);
                }
            } else {
                // Full width content
                const content_win = win.child(.{
                    .x_off = 0,
                    .y_off = Layout.header_height,
                    .width = @intCast(win.width),
                    .height = @intCast(content_height),
                });
                try self.renderContent(content_win);
            }

            // Render status bar
            const status_win = win.child(.{
                .x_off = 0,
                .y_off = win.height - Layout.status_height,
                .width = @intCast(win.width),
                .height = @intCast(Layout.status_height),
            });
            try UI.renderStatus(self, status_win);
        }

        // Render command palette overlay if in command palette mode
        if (self.mode == .command_palette) {
            try command_palette.renderCommandPalette(self, win);
        }

        // Render help overlay if in help mode
        if (self.mode == .help) {
            try help.renderHelpPopup(self, win);
        }

        // Render MCP status overlay if in mcp_status mode
        if (self.mode == .mcp_status) {
            try mcp_status.renderMcpStatusPopup(self, win);
        }

        // Render graphite stack dialog if in graphite_stack mode
        if (self.mode == .graphite_stack) {
            try UI.renderGraphiteStackDialog(self, win);
        }

        // Render model selection dialog if in model_selection mode
        if (self.mode == .model_selection) {
            try UI.renderModelSelectionDialog(self, win);
        }

        // Render agent selection dialog if in agent_selection mode
        if (self.mode == .agent_selection) {
            try UI.renderAgentSelectionDialog(self, win);
        }

        // Render agent panel full-screen if in full-screen mode
        // Don't render during agent selection (dialog is shown instead)
        if (self.state.agent_state) |as| {
            if (as.visible and as.full_screen and self.mode != .agent_selection) {
                try agent.renderAgentPanel(self, win);
            }
        }
    }

    fn renderContent(self: *App, win: vaxis.Window) !void {
        switch (self.state.view_mode) {
            .unified => try UnifiedRenderer.renderContent(self, win),
            .side_by_side => try SideBySideRenderer.renderContent(self, win),
        }
    }

    // Detect merge conflict markers and return appropriate style
    // Conflict markers: <<<<<<< (ours/HEAD), ======= (separator), >>>>>>> (theirs), ||||||| (base in diff3)
    fn getConflictMarkerStyle(line_text: []const u8, base_style: vaxis.Style) ?vaxis.Style {
        // Check for each type of conflict marker at start of line
        if (std.mem.startsWith(u8, line_text, "<<<<<<<")) {
            // "Ours" marker (HEAD/current changes) - blue
            return vaxis.Style{
                .fg = Color.conflict_ours_fg,
                .bg = if (base_style.bg != .default) base_style.bg else Color.conflict_ours_bg,
                .bold = true,
            };
        } else if (std.mem.startsWith(u8, line_text, "=======")) {
            // Separator marker - yellow
            return vaxis.Style{
                .fg = Color.conflict_separator_fg,
                .bg = if (base_style.bg != .default) base_style.bg else Color.conflict_separator_bg,
                .bold = true,
            };
        } else if (std.mem.startsWith(u8, line_text, ">>>>>>>")) {
            // "Theirs" marker (incoming changes) - purple
            return vaxis.Style{
                .fg = Color.conflict_theirs_fg,
                .bg = if (base_style.bg != .default) base_style.bg else Color.conflict_theirs_bg,
                .bold = true,
            };
        } else if (std.mem.startsWith(u8, line_text, "|||||||")) {
            // Base marker (diff3 mode) - gray
            return vaxis.Style{
                .fg = Color.conflict_base_fg,
                .bg = if (base_style.bg != .default) base_style.bg else Color.conflict_base_bg,
                .bold = true,
            };
        }
        return null;
    }

    // Generate colored segments for a line of text using syntax highlights
    // Returns array of segments with syntax colors applied as foreground
    // text: the text chunk to render (may be part of a wrapped line)
    // full_line_text: the complete line text (for search highlighting)
    // text_offset: offset of this chunk within the full line
    // line_byte_offset: byte offset for syntax highlighting
    pub fn createHighlightedSegments(
        self: *App,
        text: []const u8,
        full_line_text: []const u8,
        text_offset: usize,
        line_byte_offset: usize,
        highlights: ?[]syntax.Highlight,
        base_style: vaxis.Style,
        global_line: usize,
    ) ![]vaxis.Cell.Segment {
        // Check for merge conflict markers and apply special styling
        if (getConflictMarkerStyle(full_line_text, base_style)) |conflict_style| {
            var segments = try self.allocator.alloc(vaxis.Cell.Segment, 1);
            segments[0] = .{
                .text = text,
                .style = conflict_style,
            };
            return try self.applySearchHighlighting(segments, text, full_line_text, text_offset, global_line);
        }

        if (highlights == null or text.len == 0) {
            // No highlights - return single segment
            var segments = try self.allocator.alloc(vaxis.Cell.Segment, 1);
            segments[0] = .{
                .text = text,
                .style = base_style,
            };
            // Still apply search highlighting even without syntax highlights
            return try self.applySearchHighlighting(segments, text, full_line_text, text_offset, global_line);
        }

        const file_highlights = highlights.?;

        // Find highlights that overlap with this line
        var relevant_highlights: std.ArrayList(syntax.Highlight) = .{};
        defer relevant_highlights.deinit(self.allocator);

        const line_start = line_byte_offset;
        const line_end = line_byte_offset + text.len;

        for (file_highlights) |h| {
            // Check if highlight overlaps with this line
            if (h.end_byte > line_start and h.start_byte < line_end) {
                // Adjust highlight bounds to line-local coordinates
                const local_start = if (h.start_byte > line_start) h.start_byte - line_start else 0;
                const local_end = if (h.end_byte < line_end) h.end_byte - line_start else text.len;

                // Safety: ensure bounds are valid and within text length
                const safe_start = @min(local_start, text.len);
                const safe_end = @min(@max(local_end, safe_start), text.len);

                // Skip empty or invalid highlights
                if (safe_start >= safe_end) continue;

                try relevant_highlights.append(self.allocator, .{
                    .start_byte = safe_start,
                    .end_byte = safe_end,
                    .category = h.category,
                });
            }
        }

        if (relevant_highlights.items.len == 0) {
            // No relevant highlights - return single segment
            var segments = try self.allocator.alloc(vaxis.Cell.Segment, 1);
            segments[0] = .{
                .text = text,
                .style = base_style,
            };
            // Still apply search highlighting even without syntax highlights
            return try self.applySearchHighlighting(segments, text, full_line_text, text_offset, global_line);
        }

        // Build segments by splitting text at highlight boundaries
        var segments: std.ArrayList(vaxis.Cell.Segment) = .{};
        errdefer segments.deinit(self.allocator);

        var pos: usize = 0;
        while (pos < text.len) {
            // Find the next highlight that starts at or after pos
            var next_highlight: ?syntax.Highlight = null;
            var next_start: usize = text.len;

            for (relevant_highlights.items) |h| {
                if (h.start_byte <= pos and h.end_byte > pos) {
                    // We're inside this highlight
                    next_highlight = h;
                    next_start = pos;
                    break;
                } else if (h.start_byte > pos and h.start_byte < next_start) {
                    // Clamp to text length to prevent out of bounds
                    next_start = @min(h.start_byte, text.len);
                }
            }

            if (next_highlight) |h| {
                // Render highlighted segment
                const end = @min(h.end_byte, text.len);
                // Safety check: ensure we don't go beyond text bounds
                if (pos >= text.len) break;
                const chunk = text[pos..end];

                // Apply GitHub-inspired syntax colors with improved harmony and contrast
                const color_category = h.getColorCategory();
                var style = base_style;

                // Map semantic categories to our optimized color palette
                // These colors work well on both plain and diff backgrounds
                switch (color_category) {
                    .keyword => {
                        // Soft coral/salmon - less harsh than bold red
                        style.fg = Color.syntax_keyword;
                    },
                    .function => {
                        // Light purple - stands out well
                        style.fg = Color.syntax_function;
                    },
                    .type => {
                        // Warm yellow - good contrast on all backgrounds
                        style.fg = Color.syntax_type;
                    },
                    .string => {
                        // Light blue - easy to read
                        style.fg = Color.syntax_string;
                    },
                    .number, .constant => {
                        // Bright blue - distinct from strings
                        style.fg = Color.syntax_number;
                    },
                    .comment => {
                        // Medium gray - finally visible!
                        style.fg = Color.syntax_comment;
                    },
                    .operator => {
                        // Same as keywords for consistency
                        style.fg = Color.syntax_operator;
                    },
                    .default => {
                        // Keep base style (diff colors for add/delete, white otherwise)
                    },
                }

                try segments.append(self.allocator, .{
                    .text = chunk,
                    .style = style,
                });

                pos = end;
            } else {
                // Render unhighlighted segment until next highlight
                // Safety check: ensure next_start doesn't exceed text bounds
                if (pos >= text.len) break;
                const safe_next_start = @min(next_start, text.len);
                const chunk = text[pos..safe_next_start];
                try segments.append(self.allocator, .{
                    .text = chunk,
                    .style = base_style,
                });

                pos = safe_next_start;
            }
        }

        const owned_segments = try segments.toOwnedSlice(self.allocator);
        return try self.applySearchHighlighting(owned_segments, text, full_line_text, text_offset, global_line);
    }

    // Apply search highlighting on top of existing segments
    // Uses the search_state.matches as the source of truth for which lines should be highlighted
    fn applySearchHighlighting(
        self: *App,
        segments: []vaxis.Cell.Segment,
        chunk_text: []const u8,
        full_line_text: []const u8,
        chunk_offset: usize,
        global_line: usize,
    ) ![]vaxis.Cell.Segment {
        _ = full_line_text;
        _ = chunk_offset;
        defer self.allocator.free(segments);

        // Check if search is active
        const search_state = &self.state.search_state;
        if (search_state.query_len == 0) {
            const new_segments = try self.allocator.alloc(vaxis.Cell.Segment, segments.len);
            @memcpy(new_segments, segments);
            return new_segments;
        }

        // KEY OPTIMIZATION: Check if this line is in the matches list
        // If not, no need to search or highlight - just return segments as-is
        const is_match_line = blk: {
            for (search_state.matches.items) |match_line| {
                if (match_line == global_line) break :blk true;
            }
            break :blk false;
        };

        if (!is_match_line) {
            // This line doesn't match - return segments unchanged
            const new_segments = try self.allocator.alloc(vaxis.Cell.Segment, segments.len);
            @memcpy(new_segments, segments);
            return new_segments;
        }

        const query = search_state.query_buffer[0..search_state.query_len];

        if (query.len > chunk_text.len) {
            const new_segments = try self.allocator.alloc(vaxis.Cell.Segment, segments.len);
            @memcpy(new_segments, segments);
            return new_segments;
        }

        // Determine case sensitivity (smart case)
        const is_case_sensitive = search.isCaseSensitive(query);

        // Find all matches in the chunk_text (this is the actual text to render)
        var chunk_matches: std.ArrayList(struct { start: usize, end: usize }) = .{};
        defer chunk_matches.deinit(self.allocator);

        var search_pos: usize = 0;
        while (search_pos <= chunk_text.len - query.len) {
            const slice = chunk_text[search_pos .. search_pos + query.len];
            const is_match = if (is_case_sensitive)
                std.mem.eql(u8, slice, query)
            else
                std.ascii.eqlIgnoreCase(slice, query);

            if (is_match) {
                try chunk_matches.append(self.allocator, .{ .start = search_pos, .end = search_pos + query.len });
                search_pos += query.len;
            } else {
                search_pos += 1;
            }
        }

        if (chunk_matches.items.len == 0) {
            const new_segments = try self.allocator.alloc(vaxis.Cell.Segment, segments.len);
            @memcpy(new_segments, segments);
            return new_segments;
        }

        // Now map the matches from chunk_text coordinates to segment coordinates
        var result_segments: std.ArrayList(vaxis.Cell.Segment) = .{};
        errdefer result_segments.deinit(self.allocator);

        var text_pos: usize = 0; // Current position in chunk_text
        for (segments) |seg| {
            const seg_start = text_pos;
            const seg_end = text_pos + seg.text.len;

            // Find matches that overlap with this segment
            var seg_matches: std.ArrayList(struct { start: usize, end: usize }) = .{};
            defer seg_matches.deinit(self.allocator);

            for (chunk_matches.items) |match| {
                if (match.end > seg_start and match.start < seg_end) {
                    // Match overlaps this segment - convert to segment-local coordinates
                    const local_start = if (match.start > seg_start) match.start - seg_start else 0;
                    const local_end = @min(match.end, seg_end) - seg_start;
                    try seg_matches.append(self.allocator, .{ .start = local_start, .end = local_end });
                }
            }

            if (seg_matches.items.len == 0) {
                // No matches in this segment - add as-is
                try result_segments.append(self.allocator, seg);
            } else {
                // Split segment at match boundaries
                var pos: usize = 0;
                for (seg_matches.items) |match| {
                    // Add text before match (if any)
                    if (match.start > pos) {
                        const before_text = seg.text[pos..match.start];
                        try result_segments.append(self.allocator, .{
                            .text = before_text,
                            .style = seg.style,
                        });
                    }

                    // Add highlighted match
                    const match_text = seg.text[match.start..match.end];
                    var match_style = seg.style;
                    match_style.bg = rendering_common.Color.search_match_bg;
                    match_style.fg = rendering_common.Color.search_match_fg;
                    match_style.bold = true;
                    try result_segments.append(self.allocator, .{
                        .text = match_text,
                        .style = match_style,
                    });

                    pos = match.end;
                }

                // Add text after last match (if any)
                if (pos < seg.text.len) {
                    const after_text = seg.text[pos..];
                    try result_segments.append(self.allocator, .{
                        .text = after_text,
                        .style = seg.style,
                    });
                }
            }

            text_pos += seg.text.len;
        }

        const result = try result_segments.toOwnedSlice(self.allocator);
        return result;
    }

    // ===== MCP Integration =====

    /// Send hello message to MCP server to register this client
    fn sendMcpHello(self: *App) !void {
        const mcp = self.mcp orelse return;
        try mcp_handlers.sendHello(self.allocator, mcp, self.state.files, self.state.diff_source);
    }

    /// Handle incoming MCP message
    fn handleMcpMessage(self: *App, msg: *mcp_protocol.ParsedMessage) !void {
        const mcp = self.mcp orelse return;

        switch (msg.*) {
            .add_comment => |ac| {
                // Delegate to handler - returns comment_idx if successful
                const result = mcp_handlers.handleAddComment(self.allocator, mcp, ac, self.state.files, &self.state.comment_store) catch |err| {
                    std.log.warn("MCP add_comment failed: {any}", .{err});
                    return;
                };
                if (result) |_| {
                    // Rebuild LineMap since comment count changed
                    self.state.line_map.deinit();
                    self.state.line_map = line_map.LineMap.build(
                        self.allocator,
                        self.state.files,
                        &self.state.comment_store,
                        self.convertHunkViewMode(),
                        self.shouldApplyHunkFiltering(),
                    ) catch |err| {
                        std.log.err("Failed to rebuild LineMap: {any}", .{err});
                        return;
                    };
                    self.needs_render = true;
                }
            },
            .get_comments => {
                mcp_handlers.handleGetComments(self.allocator, mcp, &self.state.comment_store) catch |err| {
                    std.log.warn("MCP get_comments failed: {any}", .{err});
                };
            },
            .get_diff_context => {
                mcp_handlers.handleGetDiffContext(self.allocator, mcp, self.state.files, self.state.diff_source, self.state.git_repo_root) catch |err| {
                    std.log.warn("MCP get_diff_context failed: {any}", .{err});
                };
            },
            .get_file_diff => |gfd| {
                mcp_handlers.handleGetFileDiff(self.allocator, mcp, self.state.files, gfd.file) catch |err| {
                    std.log.warn("MCP get_file_diff failed: {any}", .{err});
                };
            },
            .welcome => |w| {
                // Store session ID for status display
                if (mcp.session_id) |old_id| {
                    self.allocator.free(old_id);
                }
                mcp.session_id = self.allocator.dupe(u8, w.id) catch null;
            },
            .ping => {
                // Respond with pong
                const pong = mcp_protocol.encodePong(self.allocator) catch {
                    return;
                };
                defer self.allocator.free(pong);
                mcp.send(pong) catch {};
            },
            .@"error" => {
                // Silently ignore errors - can check status via command palette
            },
            else => {},
        }
    }

    // =========================================================================
    // Review Methods
    // =========================================================================

    /// Background thread function for ACP connection
    fn acpConnectThreadFn(ctx: *AcpConnectContext) void {
        std.log.info("ACP: Background connection thread started", .{});

        const mgr = ctx.app.acp_manager orelse {
            std.log.err("ACP: No manager in thread context", .{});
            return;
        };

        // Get agent info from context (required - no auto-discovery)
        const agent_info: acp.AgentInfo = if (ctx.agent) |a| a.* else {
            std.log.err("ACP: No agent provided in context", .{});
            if (ctx.app.state.agent_state) |*agent_state| {
                agent_state.addMessage(.system, "No agent configured. Configure agents in ~/.skim/config.json") catch {};
            }
            mgr.status = .failed;
            return;
        };
        std.log.info("ACP: Using agent: {s}", .{agent_info.name});

        // Update status to connecting
        mgr.status = .connecting;

        // Connect to agent (spawn + initialize)
        mgr.connect(agent_info.command, agent_info.args, ctx.cwd) catch |err| {
            std.log.err("ACP: Connect failed: {}", .{err});
            return;
        };
        std.log.info("ACP: Connected, now creating session...", .{});

        // Create session
        mgr.createSession(ctx.cwd) catch |err| {
            std.log.err("ACP: CreateSession failed: {}, status now={s}", .{ err, mgr.getStatusString() });
            return;
        };
        std.log.info("ACP: Session created successfully! status={s}", .{mgr.getStatusString()});

        // Apply configured mode if set (e.g., "plan", "bypassPermissions")
        if (agent_info.mode) |mode_id| {
            std.log.info("ACP: Applying configured mode: {s}", .{mode_id});
            mgr.setMode(mode_id) catch |err| {
                std.log.warn("ACP: Failed to set mode: {}", .{err});
            };
        }

        // TODO: Apply configured model if set (requires ACP model selection support)
        if (agent_info.model) |model_name| {
            std.log.info("ACP: Configured model: {s} (model selection not yet implemented)", .{model_name});
        }
    }

    /// Start an ACP agent session (non-blocking)
    /// If agents are configured, may show selection menu first.
    pub fn startAcpSession(self: *App) !void {
        // Check if ACP is enabled
        if (!app_config.isAcpEnabled(self.allocator)) {
            self.showStatusMessage("ACP is experimental. Enable in ~/.skim/config.json");
            return;
        }

        std.log.info("ACP: startAcpSession called", .{});

        // Check if connection already in progress
        if (self.acp_connect_thread != null) {
            std.log.info("ACP: Connection already in progress", .{});
            self.showStatusMessage("Connection already in progress...");
            return;
        }

        // Check if already connected
        if (self.acp_manager) |mgr| {
            if (mgr.isConnected()) {
                std.log.info("ACP: Already connected", .{});
                self.showStatusMessage("Agent already connected");
                return;
            }
            // Previous session died, clean it up
            std.log.info("ACP: Cleaning up dead session", .{});
            mgr.deinit();
            self.allocator.destroy(mgr);
            self.acp_manager = null;
        }

        // Load configured agents (if not already loaded)
        if (self.state.configured_agents == null) {
            self.state.configured_agents = self.loadConfiguredAgents();
        }

        const agents = self.state.configured_agents orelse {
            // No agents configured - show error in agent panel and stay in agent mode
            std.log.warn("ACP: No agents configured in ~/.skim/config.json", .{});
            if (self.state.agent_state) |*agent_state| {
                agent_state.addMessage(.system, "No agents configured. Add agents to ~/.skim/config.json") catch {};
            }
            return;
        };

        // Decision logic for agent selection
        if (agents.len == 0) {
            std.log.warn("ACP: Empty agents list in config", .{});
            if (self.state.agent_state) |*agent_state| {
                agent_state.addMessage(.system, "No agents configured. Add agents to ~/.skim/config.json") catch {};
            }
            return;
        }

        if (agents.len == 1) {
            // Single agent: auto-connect
            std.log.info("ACP: Single agent configured, auto-connecting", .{});
            try self.connectToAgent(&agents[0]);
            return;
        }

        // Multiple agents: check for default
        if (acp.findDefaultOrFirst(agents)) |default_agent| {
            if (default_agent.is_default) {
                // Default is explicitly set
                std.log.info("ACP: Default agent found, auto-connecting to {s}", .{default_agent.name});
                try self.connectToAgent(default_agent);
                return;
            }
        }

        // No default set with multiple agents: show selection menu
        std.log.info("ACP: Multiple agents configured, showing selection menu", .{});
        self.state.agent_selection_idx = 0;
        self.mode = .agent_selection;
        self.needs_render = true;
    }

    /// Connect to a specific agent.
    /// Agent info is required - no auto-discovery.
    pub fn connectToAgent(self: *App, agent_info: ?*const acp.AgentInfo) !void {
        // Create and initialize the manager with discovering status
        const mgr = try self.allocator.create(acp.AcpManager);
        mgr.* = acp.AcpManager.init(self.allocator);
        mgr.status = .discovering;
        self.acp_manager = mgr;

        if (agent_info) |info| {
            self.showStatusMessage("Connecting to agent...");
            std.log.info("ACP: Connecting to {s}", .{info.name});
        } else {
            self.showStatusMessage("Discovering agent...");
        }
        self.needs_render = true;

        // Store connection context (static lifetime for thread)
        const ctx = try self.allocator.create(AcpConnectContext);
        ctx.* = .{
            .app = self,
            .cwd = self.state.git_repo_root,
            .agent = agent_info,
        };

        // Spawn background thread for connection
        self.acp_connect_thread = std.Thread.spawn(.{}, acpConnectThreadFn, .{ctx}) catch |err| {
            std.log.err("Failed to spawn ACP connect thread: {any}", .{err});
            self.showStatusMessage("Failed to start connection");
            self.allocator.destroy(ctx);
            mgr.deinit();
            self.allocator.destroy(mgr);
            self.acp_manager = null;
            return;
        };

        // Store context so it can be freed after thread joins
        self.acp_connect_ctx = ctx;
    }

    /// Connect to the currently selected agent in the selection menu
    pub fn connectToSelectedAgent(self: *App) !void {
        const agents = self.state.configured_agents orelse return;
        if (self.state.agent_selection_idx >= agents.len) return;
        try self.connectToAgent(&agents[self.state.agent_selection_idx]);
    }

    /// Load configured agents from config file.
    /// Returns null if no agents are configured.
    fn loadConfiguredAgents(self: *App) ?[]acp.AgentInfo {
        // Try to load from config
        const cfg_agents = app_config.getConfiguredAgents(self.allocator) catch null;

        if (cfg_agents) |agents| {
            if (agents.len > 0) {
                // Convert to ACP ConfigAgent format for loadAgentList
                const config_slice = self.allocator.alloc(acp.ConfigAgent, agents.len) catch {
                    app_config.freeAgents(self.allocator, agents);
                    return null;
                };

                for (agents, 0..) |cfg, i| {
                    config_slice[i] = .{
                        .name = cfg.name,
                        .command = cfg.command,
                        .api_key_env = cfg.api_key_env,
                        .default = cfg.default,
                        .args = cfg.args,
                        .model = cfg.model,
                        .mode = cfg.mode,
                    };
                }

                // loadAgentList will dupe all strings
                const result = (acp.loadAgentList(self.allocator, config_slice) catch null) orelse {
                    self.allocator.free(config_slice);
                    app_config.freeAgents(self.allocator, agents);
                    return null;
                };

                // Clean up
                self.allocator.free(config_slice);
                app_config.freeAgents(self.allocator, agents);
                return result;
            }
            app_config.freeAgents(self.allocator, agents);
        }

        // No agents configured
        return null;
    }

    /// Disconnect from the ACP agent
    pub fn stopAcpSession(self: *App) void {
        if (self.acp_manager) |mgr| {
            mgr.deinit();
            self.allocator.destroy(mgr);
            self.acp_manager = null;
            self.showStatusMessage("Disconnected from agent");
            self.needs_render = true;
        }
    }

    /// Check ACP agent status
    pub fn getAcpStatus(self: *App) ?acp.AcpManager.Status {
        if (self.acp_manager) |mgr| {
            return mgr.status;
        }
        return null;
    }

    /// Poll ACP agent for updates
    /// Phase 3: Just log messages and show status. Phase 4 will add smart comment placement.
    pub fn pollAcpUpdates(self: *App) void {
        // Track if we clear the thread in this call (to avoid double-check)
        var thread_was_cleared = false;

        // Check if connection thread completed
        if (self.acp_connect_thread != null) {
            if (self.acp_manager) |mgr| {
                // Check if connection finished
                // NOTE: Thread sets status to .connected BEFORE calling createSession(),
                // so we also wait for .connected to change to .session_active or .failed
                const thread_still_working = mgr.status == .discovering or mgr.status == .connecting or mgr.status == .connected;
                if (!thread_still_working) {
                    // Thread is done, clean it up
                    if (self.acp_connect_thread) |thread| {
                        thread.join();
                        self.acp_connect_thread = null;
                        thread_was_cleared = true;
                    }
                    // Free the connection context
                    if (self.acp_connect_ctx) |ctx| {
                        self.allocator.destroy(ctx);
                        self.acp_connect_ctx = null;
                    }

                    // Update UI based on result
                    if (mgr.status == .session_active) {
                        const msg = std.fmt.allocPrint(self.allocator, "Connected to {s}", .{mgr.getAgentDisplayName()}) catch "Connected";
                        defer if (!std.mem.eql(u8, msg, "Connected")) self.allocator.free(msg);
                        self.showStatusMessage(msg);

                        // Add welcome message to agent chat
                        if (self.state.agent_state) |*agent_state| {
                            const welcome_msg = std.fmt.allocPrint(self.allocator, "Connected to {s}. You can start chatting!", .{mgr.getAgentDisplayName()}) catch "Connected! You can start chatting.";
                            defer if (!std.mem.eql(u8, welcome_msg, "Connected! You can start chatting.")) self.allocator.free(welcome_msg);
                            agent_state.addMessage(.system, welcome_msg) catch {};
                        }

                        // Send any prompts that were queued while connecting
                        mgr.sendNextQueuedPrompt();
                    } else if (mgr.status == .failed) {
                        self.showStatusMessage("Failed to connect to agent");
                        // Add error message to chat history so user can see what happened
                        if (self.state.agent_state) |*agent_state| {
                            agent_state.addMessage(.system, "Connection failed. Press 'a' to close this panel and try again.") catch {};
                        }
                        // Clean up failed manager
                        mgr.deinit();
                        self.allocator.destroy(mgr);
                        self.acp_manager = null;
                    }
                    self.needs_render = true;
                }
            }
        }

        // Don't poll while connection thread is active - it would clear messages
        // that waitForResponse() in the background thread needs
        // UNLESS we just cleared the thread in this same call
        if (self.acp_connect_thread != null and !thread_was_cleared) {
            return;
        }

        const mgr = self.acp_manager orelse return;

        // Track status before polling to detect when agent finishes
        const status_before = mgr.status;

        // Poll for new messages (this also updates status when agent finishes)
        const messages = mgr.poll() catch return;

        // Trigger redraw if status changed (e.g., prompting -> session_active)
        // This ensures the "Generating..." indicator is cleared when agent finishes
        if (mgr.status != status_before) {
            self.needs_render = true;
        }

        // Process each message (if any)
        for (messages) |msg| {
            switch (msg.kind) {
                .agent_text => {
                    // Forward to agent state message history
                    if (self.state.agent_state) |*agent_state| {
                        agent_state.appendToLastAgentMessage(msg.text) catch {};
                    }

                    self.needs_render = true;
                },
                .agent_thinking => {
                    // Forward to agent state as thinking message
                    if (self.state.agent_state) |*agent_state| {
                        agent_state.appendToLastThinkingMessage(msg.text) catch {};
                    }
                    self.needs_render = true;
                },
                .tool_call => {
                    // Forward to agent state with full tool info
                    if (self.state.agent_state) |*agent_state| {
                        agent_state.addToolMessage(
                            msg.tool_call_id orelse "",
                            msg.tool_name,
                            msg.text,
                            msg.tool_command,
                        ) catch {};
                    }

                    self.needs_render = true;
                },
                .tool_update => {
                    // Update existing tool message with status and output
                    if (self.state.agent_state) |*agent_state| {
                        const status: agent.Message.ToolStatus = switch (msg.tool_status) {
                            .pending => .pending,
                            .in_progress => .running,
                            .completed => .completed,
                            .failed => .failed,
                        };
                        agent_state.updateToolMessage(
                            msg.tool_call_id orelse "",
                            status,
                            msg.tool_stdout,
                            msg.tool_stderr,
                        ) catch {};
                    }

                    self.needs_render = true;
                },
                .tool_diff => {
                    // Forward diff to agent state
                    if (self.state.agent_state) |*agent_state| {
                        agent_state.addDiffMessage(
                            msg.text,
                            msg.diff_path orelse "",
                            msg.diff_old orelse "",
                            msg.diff_new orelse "",
                        ) catch |err| {
                            std.log.err("Failed to add diff message: {any}", .{err});
                        };
                    }

                    self.needs_render = true;
                },
                .error_msg => {
                    // Forward to agent state
                    if (self.state.agent_state) |*agent_state| {
                        const err_msg = std.fmt.allocPrint(self.allocator, "[Error: {s}]", .{msg.text}) catch "[Error]";
                        defer self.allocator.free(err_msg);
                        agent_state.addMessage(.system, err_msg) catch {};
                    }

                    self.needs_render = true;
                },
                .plan_update => {
                    // Update agent plan
                    if (self.state.agent_state) |*agent_state| {
                        if (msg.plan_entries) |entries| {
                            std.log.debug("plan_update: received {d} entries", .{entries.len});
                            agent_state.updatePlan(entries) catch |err| {
                                std.log.err("plan_update: updatePlan failed: {}", .{err});
                            };
                        }
                    }

                    self.needs_render = true;
                },
                .commands_update => {
                    // Update available slash commands
                    if (self.state.agent_state) |*agent_state| {
                        if (msg.available_commands) |commands| {
                            agent_state.updateAvailableCommands(commands) catch {};
                        }
                    }
                    self.needs_render = true;
                },
                // Note: If agent doesn't send commands, we add mock ones in startAcpSession
            }
        }

        // Clear processed messages
        mgr.clearMessages();

        // Check if agent just finished responding and there's a staged message to send
        // The condition: agent is idle (session_active) and no pending prompt request
        const has_staged = if (self.state.agent_state) |as| as.hasStagedPrompt() else false;
        const agent_idle = mgr.status == .session_active and mgr.pending_prompt_id == null;

        if (has_staged and agent_idle) {
            if (self.state.agent_state) |*agent_state| {
                // Take and send the staged message
                if (agent_state.takeStagedPrompt()) |staged| {
                    std.log.info("Agent: Auto-sending staged message ({d} bytes)", .{staged.len});

                    // Add to message history
                    agent_state.addMessage(.user, staged) catch {};

                    // Send to agent
                    const prompt_copy = self.allocator.dupe(u8, staged) catch return;
                    defer self.allocator.free(prompt_copy);

                    mgr.sendPrompt(prompt_copy) catch |err| {
                        std.log.err("Agent: Failed to send staged prompt: {any}", .{err});
                        agent_state.addMessage(.system, "Failed to send staged message") catch {};
                    };

                    self.needs_render = true;
                }
            }
        } else if (has_staged) {
            // Debug: log why we're not sending (agent not idle yet)
            std.log.debug("Agent: Staged message waiting (status={}, pending_id={?})", .{
                @intFromEnum(mgr.status),
                mgr.pending_prompt_id,
            });
        }
    }

    /// Get the diff reference string for display
    fn getDiffRefString(self: *App) []const u8 {
        return switch (self.state.diff_source) {
            .working_dir => |wd| if (wd.staged) "staged" else "working",
            .single_ref => |sr| sr.ref,
            .two_refs => "refs",
        };
    }

    /// Show a temporary status message (displayed for 3 seconds)
    /// Note: This duplicates the message, so caller can free their copy.
    fn showStatusMessage(self: *App, message: []const u8) void {
        // Free previous allocated message if any
        if (self.state.status_message_owned) |old| {
            self.allocator.free(old);
            self.state.status_message_owned = null;
        }

        // Duplicate the message so it persists
        const owned = self.allocator.dupe(u8, message) catch {
            self.state.status_message = null;
            return;
        };
        self.state.status_message_owned = owned;
        self.state.status_message = owned;
        self.state.status_message_time = std.time.timestamp();
        self.needs_render = true;
    }

    /// Clear status message if it has expired (after 3 seconds)
    pub fn clearExpiredStatusMessage(self: *App) void {
        if (self.state.status_message != null) {
            const elapsed = std.time.timestamp() - self.state.status_message_time;
            if (elapsed >= 3) {
                // Free owned message if any
                if (self.state.status_message_owned) |owned| {
                    self.allocator.free(owned);
                    self.state.status_message_owned = null;
                }
                self.state.status_message = null;
                self.needs_render = true;
            }
        }
    }
};

// ===== Tests =====
// Note: searchInLine tests moved to src/search.zig

test "search highlighting - basic match" {
    const allocator = std.testing.allocator;

    // Create a mock App with search state
    var app = App{
        .allocator = allocator,
        .vx = undefined,
        .tty = undefined,
        .should_quit = false,
        .last_ctrl_c_time = 0,
        .mode = .normal,
        .state = undefined,
    };

    // Initialize search state
    app.state.search_state = App.SearchState.init(allocator);
    defer app.state.search_state.deinit();

    // Set search query
    const query = "test";
    @memcpy(app.state.search_state.query_buffer[0..query.len], query);
    app.state.search_state.query_len = query.len;

    // Add line 100 to matches (simulate that performSearch found it)
    try app.state.search_state.matches.append(100);

    // Create input segments (single segment with plain text)
    const chunk_text = "this is a test string";
    var input_segments = [_]vaxis.Cell.Segment{
        .{
            .text = chunk_text,
            .style = .{},
        },
    };

    const input_copy = try allocator.alloc(vaxis.Cell.Segment, input_segments.len);
    @memcpy(input_copy, &input_segments);

    // Apply highlighting (pretend we're on global line 100)
    const result = try app.applySearchHighlighting(
        input_copy,
        chunk_text,
        chunk_text,
        0,
        100,
    );
    defer allocator.free(result);

    // Verify: should have 3 segments (before, match, after)
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("this is a ", result[0].text);
    try std.testing.expectEqualStrings("test", result[1].text);
    try std.testing.expectEqualStrings(" string", result[2].text);

    // Verify the match has search highlight style
    try std.testing.expect(result[1].style.bold);
}

test "search highlighting - multiple matches" {
    const allocator = std.testing.allocator;

    var app = App{
        .allocator = allocator,
        .vx = undefined,
        .tty = undefined,
        .should_quit = false,
        .last_ctrl_c_time = 0,
        .mode = .normal,
        .state = undefined,
    };

    app.state.search_state = App.SearchState.init(allocator);
    defer app.state.search_state.deinit();

    const query = "the";
    @memcpy(app.state.search_state.query_buffer[0..query.len], query);
    app.state.search_state.query_len = query.len;

    // Add line 200 to matches
    try app.state.search_state.matches.append(200);

    const chunk_text = "the quick brown fox jumps over the lazy dog";
    var input_segments = [_]vaxis.Cell.Segment{
        .{
            .text = chunk_text,
            .style = .{},
        },
    };

    const input_copy = try allocator.alloc(vaxis.Cell.Segment, input_segments.len);
    @memcpy(input_copy, &input_segments);

    const result = try app.applySearchHighlighting(
        input_copy,
        chunk_text,
        chunk_text,
        0,
        200,
    );
    defer allocator.free(result);

    // Should have 5 segments: match1, text, match2, text
    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqualStrings("the", result[0].text);
    try std.testing.expectEqualStrings(" quick brown fox jumps over ", result[1].text);
    try std.testing.expectEqualStrings("the", result[2].text);
    try std.testing.expectEqualStrings(" lazy dog", result[3].text);
}

test "search highlighting - case insensitive" {
    const allocator = std.testing.allocator;

    var app = App{
        .allocator = allocator,
        .vx = undefined,
        .tty = undefined,
        .should_quit = false,
        .last_ctrl_c_time = 0,
        .mode = .normal,
        .state = undefined,
    };

    app.state.search_state = App.SearchState.init(allocator);
    defer app.state.search_state.deinit();

    // Lowercase query (should match any case)
    const query = "test";
    @memcpy(app.state.search_state.query_buffer[0..query.len], query);
    app.state.search_state.query_len = query.len;

    // Add line 300 to matches
    try app.state.search_state.matches.append(300);

    const chunk_text = "Test TEST test";
    var input_segments = [_]vaxis.Cell.Segment{
        .{
            .text = chunk_text,
            .style = .{},
        },
    };

    const input_copy = try allocator.alloc(vaxis.Cell.Segment, input_segments.len);
    @memcpy(input_copy, &input_segments);

    const result = try app.applySearchHighlighting(
        input_copy,
        chunk_text,
        chunk_text,
        0,
        300,
    );
    defer allocator.free(result);

    // Should match all 3 occurrences
    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqualStrings("Test", result[0].text);
    try std.testing.expect(result[0].style.bold);
    try std.testing.expectEqualStrings(" ", result[1].text);
    try std.testing.expectEqualStrings("TEST", result[2].text);
    try std.testing.expect(result[2].style.bold);
    try std.testing.expectEqualStrings(" ", result[3].text);
    try std.testing.expectEqualStrings("test", result[4].text);
    try std.testing.expect(result[4].style.bold);
}

test "search highlighting - across syntax segments" {
    const allocator = std.testing.allocator;

    var app = App{
        .allocator = allocator,
        .vx = undefined,
        .tty = undefined,
        .should_quit = false,
        .last_ctrl_c_time = 0,
        .mode = .normal,
        .state = undefined,
    };

    app.state.search_state = App.SearchState.init(allocator);
    defer app.state.search_state.deinit();

    const query = "function";
    @memcpy(app.state.search_state.query_buffer[0..query.len], query);
    app.state.search_state.query_len = query.len;

    // Add line 400 to matches
    try app.state.search_state.matches.append(400);

    // Simulate syntax-highlighted segments
    const chunk_text = "function test() {}";
    var input_segments = [_]vaxis.Cell.Segment{
        .{ // keyword
            .text = "function",
            .style = .{ .fg = .{ .rgb = [3]u8{ 255, 0, 0 } }, .bold = true },
        },
        .{ // space
            .text = " ",
            .style = .{},
        },
        .{ // function name
            .text = "test",
            .style = .{ .fg = .{ .rgb = [3]u8{ 255, 0, 255 } } },
        },
        .{ // rest
            .text = "() {}",
            .style = .{},
        },
    };

    const input_copy = try allocator.alloc(vaxis.Cell.Segment, input_segments.len);
    @memcpy(input_copy, &input_segments);

    const result = try app.applySearchHighlighting(
        input_copy,
        chunk_text,
        chunk_text,
        0,
        400,
    );
    defer allocator.free(result);

    // First segment should be highlighted with search colors (not syntax colors)
    try std.testing.expect(result.len > 0);
    try std.testing.expectEqualStrings("function", result[0].text);
    try std.testing.expect(result[0].style.bold);
    // Search highlight should override syntax highlighting
}
