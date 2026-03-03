const std = @import("std");
const vaxis = @import("vaxis");
const git = @import("git/diff.zig");
const blame = @import("git/blame.zig");
const parser = @import("git/parser.zig");
const syntax = @import("highlighting/core.zig");
const comments = @import("comments/store.zig");
const line_map = @import("line_map.zig");
const tui_server = @import("mcp/tui_server.zig");
const session_mgr = @import("mcp/session.zig");
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
const commit_selection_mode = @import("modes/commit_selection_mode.zig");
const graphite_mode = @import("modes/graphite_mode.zig");
const model_selection_mode = @import("modes/model_selection_mode.zig");
const permission_selection_mode = @import("modes/permission_selection_mode.zig");
const agent_selection_mode = @import("modes/agent_selection_mode.zig");
const session_picker_mode = @import("modes/session_picker_mode.zig");
const agent_mode = @import("modes/agent_mode.zig");
const agent = @import("agent/agent.zig");
const agent_state_mod = @import("agent/state.zig");
const sessions = @import("acp/sessions.zig");
const app_config = @import("config.zig");
const build_options = @import("build_options");
const graphite = @import("git/graphite.zig");
const acp = @import("acp/acp.zig");
const opencode = @import("opencode/opencode.zig");
const codex_mod = @import("codex/codex.zig");

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
const profiling_enabled = build_options.enable_profile;

const HEADER_BUFFER_WIDTH = 4096;
const FRAME_TEXT_CAPACITY = 262144; // 256 KiB per frame scratch space

const HunkKey = struct {
    file_idx: usize,
    hunk_idx: usize,
};

/// Packed key for fold state HashMap
/// Bit 63: 0 = file fold, 1 = hunk fold
/// Bits 0-30: file_idx (for files) or file_idx (for hunks)
/// Bits 31-62: hunk_idx (for hunks, 0 for files)
pub const FoldKey = struct {
    pub fn fileKey(file_idx: usize) u64 {
        return @as(u64, @intCast(file_idx)); // Bit 63 = 0 indicates file
    }

    pub fn hunkKey(file_idx: usize, hunk_idx: usize) u64 {
        // Set bit 63 to indicate hunk, pack file_idx in low bits, hunk_idx in mid bits
        return (@as(u64, 1) << 63) | (@as(u64, @intCast(hunk_idx)) << 31) | @as(u64, @intCast(file_idx));
    }
};

/// Anchor for preserving viewport position across LineMap rebuilds.
/// Captures position relative to a stable reference (file/hunk header).
const ViewportAnchor = struct {
    file_idx: usize,
    hunk_idx: ?usize, // null = anchor to file header
    scroll_offset_from_anchor: isize,
    cursor_offset_from_anchor: isize,
};

const PendingJob = struct {
    content: []const u8, // Owned NEW hunk content
    old_content: []const u8, // Owned OLD hunk content
};

// Static buffer for vaxis Tty writer (must persist for lifetime of Tty)
var tty_static_buffer: [4096]u8 = undefined;

/// Context for ACP connection thread
pub const AcpConnectContext = struct {
    app: *App,
    cwd: []const u8,
    agent: ?*const acp.AgentInfo, // Selected agent to connect to (null = use discovery)
    tab_id: u32, // Target tab ID for the connection
};

/// Context for Opencode connection thread
pub const OpencodeConnectContext = struct {
    mgr: *opencode.OpencodeManager,
    opencode_path: []const u8,
    port: u16,
    cwd: ?[]const u8,
};

/// Context for Codex connection thread
pub const CodexConnectContext = struct {
    mgr: *codex_mod.CodexManager,
    command: []const u8,
    args: ?[]const []const u8,
    cwd: ?[]const u8,
    model: ?[]const u8,
    approval_policy: ?[]const u8,
};

/// Unified pending connection state (replaces separate ACP/Opencode fields)
pub const PendingConnection = struct {
    thread: std.Thread,
    tab_id: u32,
    ctx: ConnectContext,

    pub const ConnectContext = union(enum) {
        acp: *AcpConnectContext,
        opencode: *OpencodeConnectContext,
        codex: *CodexConnectContext,
    };
};

/// Context for subagent modal fetch thread
pub const SubagentFetchContext = struct {
    app: *App,
    base_url: []const u8, // Owned copy
    session_id: []const u8, // Owned copy

    pub fn deinit(self: *SubagentFetchContext, allocator: std.mem.Allocator) void {
        allocator.free(self.base_url);
        allocator.free(self.session_id);
    }
};

/// Thread-safe pending result from subagent fetch worker.
/// Worker writes under mutex, main loop polls via atomic flag.
pub const PendingSubagentFetch = struct {
    mutex: std.Thread.Mutex = .{},
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    messages: ?[]opencode.Client.ModalMessage = null,
    error_message: ?[]const u8 = null, // String literal, not owned
};

/// Case-insensitive substring search
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    const end = haystack.len - needle.len + 1;
    outer: for (0..end) |i| {
        for (0..needle.len) |j| {
            const h = std.ascii.toLower(haystack[i + j]);
            const n = std.ascii.toLower(needle[j]);
            if (h != n) continue :outer;
        }
        return true;
    }
    return false;
}

fn parseEnvBool(value: []const u8) bool {
    if (value.len == 0) return true;
    if (std.mem.eql(u8, value, "1")) return true;
    if (std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.ascii.eqlIgnoreCase(value, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(value, "on")) return true;
    return false;
}

fn readEnvBool(allocator: Allocator, name: []const u8) bool {
    const env_value = std.process.getEnvVarOwned(allocator, name) catch return false;
    defer allocator.free(env_value);
    return parseEnvBool(env_value);
}

fn readEnvU32(allocator: Allocator, name: []const u8, default_value: u32) u32 {
    const env_value = std.process.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(env_value);
    if (env_value.len == 0) return default_value;
    return std.fmt.parseInt(u32, env_value, 10) catch default_value;
}

const FileCaches = struct {
    stats: []StateHelpers.FileDiffStats,
    line_counts: []usize,
    gutter_width: usize,
};

const RenderProfileCounters = struct {
    slice_ns: u64 = 0,
    slice_calls: u64 = 0,
    pad_ns: u64 = 0,
    pad_calls: u64 = 0,
    gutter_ns: u64 = 0,
    gutter_calls: u64 = 0,
    highlight_total_ns: u64 = 0,
    highlight_calls: u64 = 0,
    highlight_overlap_ns: u64 = 0,
    highlight_overlap_calls: u64 = 0,
    highlight_build_ns: u64 = 0,
    highlight_build_calls: u64 = 0,
    search_ns: u64 = 0,
    search_calls: u64 = 0,
};

fn buildFileCaches(allocator: Allocator, files: []const parser.FileDiff) !FileCaches {
    const stats = try allocator.alloc(StateHelpers.FileDiffStats, files.len);
    errdefer allocator.free(stats);

    const line_counts = try allocator.alloc(usize, files.len);
    errdefer allocator.free(line_counts);

    var global_max_lineno: u32 = 0;

    for (files, 0..) |*file, idx| {
        var additions: usize = 0;
        var deletions: usize = 0;
        var line_count: usize = 0;
        var file_max_lineno: u32 = 0;

        for (file.hunks) |hunk| {
            line_count += hunk.lines.len;
            for (hunk.lines) |line| {
                switch (line.line_type) {
                    .add => additions += 1,
                    .delete => deletions += 1,
                    .context => {},
                }
                if (line.old_lineno) |old| {
                    file_max_lineno = @max(file_max_lineno, old);
                }
                if (line.new_lineno) |new| {
                    file_max_lineno = @max(file_max_lineno, new);
                }
            }
        }

        stats[idx] = .{ .additions = additions, .deletions = deletions };
        line_counts[idx] = line_count;
        global_max_lineno = @max(global_max_lineno, file_max_lineno);
    }

    const digits = StateHelpers.countDigits(global_max_lineno);
    const calculated = digits + 1;
    const base_width = @max(calculated, Layout.min_gutter_width);

    return .{
        .stats = stats,
        .line_counts = line_counts,
        .gutter_width = base_width,
    };
}

pub const App = struct {
    allocator: Allocator,
    vx: ?Vaxis, // null in headless mode (print command)
    tty: ?vaxis.Tty, // null in headless mode (print command)
    mode: Mode,
    state: State,
    should_quit: bool,
    should_suspend_for_editor: bool,
    editor_file_path: ?[]const u8,
    editor_line_number: ?usize,
    editor_is_prompt_edit: bool, // True if editing agent prompt (read content back after)
    last_ctrl_c: i64,
    header_line_buffers: [Layout.header_height][HEADER_BUFFER_WIDTH]u8,
    frame_text_buffer: []u8,
    frame_text_used: usize,
    frame_segment_arena: std.heap.ArenaAllocator,
    syntax_highlighter: syntax.SyntaxHighlighter,
    highlight_worker: ?*state_helpers.HighlightWorker, // Long-lived worker thread with cached parsers
    pending_highlight_jobs: std.AutoHashMap(HunkKey, PendingJob), // {file_idx, hunk_idx} -> owned content strings
    needs_render: bool, // Flag to force re-render (e.g., after async highlighting)
    needs_async_highlight: bool, // Flag to trigger async highlighting for current file
    tui_server: ?tui_server.TuiServer, // TCP server for CLI/MCP connections
    session_manager: ?session_mgr.SessionManager, // Session file management
    blame_cache: std.StringHashMap(blame.BlameData), // file_path -> blame data
    pending_connection: ?PendingConnection, // Background connection thread (ACP or Opencode)
    pending_subagent_fetch: PendingSubagentFetch, // Thread-safe result from subagent fetch worker
    in_bracketed_paste: bool, // Whether we're currently receiving bracketed paste input
    agent_only: bool, // Start in agent-only mode (no diff view)
    tab_manager: ?agent.TabManager, // Multi-tab agent manager
    profile_render: bool, // Enable render timing logs
    profile_every_n: u32, // Log every N frames when profiling
    profile_frame_counter: u64, // Incremented on each rendered frame
    profile_active_frame: bool, // True when current render should be profiled
    profile_counters: RenderProfileCounters,

    const Mode = enum {
        normal, // Normal navigation and viewing
        comment, // Comment editing
        search, // Search input
        visual, // Visual selection mode
        command_palette, // Command palette
        help, // Help overlay
        branch_selection, // Branch selection menu (when empty)
        commit_selection, // Commit selection menu
        commit_diff_mode, // Submenu to select diff mode after commit selection
        graphite_stack, // Graphite stack picker
        agent, // Agent chat panel
        model_selection, // AI model selection menu
        permission_selection, // Codex permission mode menu
        agent_selection, // Agent selection menu (before connecting)
        session_picker, // Session picker for /resume command
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
        pager_mode: bool, // True when reading diff from stdin (disables git-dependent features)
        git_repo_root: []const u8, // Absolute path to git repository root
        files: []parser.FileDiff,
        file_diff_stats: []StateHelpers.FileDiffStats,
        file_line_counts: []usize,
        global_gutter_width: usize,
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
        pending_space: bool, // Waiting for second character after Space (agent mode: Space+f for follow)
        pending_bracket: bool, // Waiting for second character after [ (like [h)
        pending_close_bracket: bool, // Waiting for second character after ] (like ]h)
        empty_menu_selection: usize, // Selected index in empty state menu (0 = working, 1 = staged, 2 = main, 3 = branch, 4 = refresh, 5 = quit)
        branch_list: [][]const u8, // List of available branches for selection
        branch_selection: usize, // Selected branch index in branch selection menu
        branch_search_query: [256]u8, // Search query buffer for filtering branches
        branch_search_len: usize, // Length of search query
        filtered_branches: std.ArrayList(usize), // Indices of branches matching search query
        help_scroll_offset: usize, // Scroll position in help overlay

        // Commit selection state
        commit_list: std.ArrayList(git.CommitInfo), // Loaded commits
        commit_selection: usize, // Selected index in commit selection menu
        commit_search_query: [256]u8, // Search query buffer for filtering commits
        commit_search_len: usize, // Length of search query
        filtered_commits: std.ArrayList(usize), // Indices of commits matching search query
        commits_loaded_count: usize, // Total commits loaded (for lazy loading)
        commits_loading: bool, // Whether commits are being loaded
        selected_commit_for_diff: ?git.CommitInfo, // Commit selected for diff mode submenu (owned copy)
        commit_diff_mode_selection: usize, // 0 = HEAD vs commit, 1 = commit vs parent

        // Session picker state (for /resume command)
        session_list: []sessions.SessionInfo, // Discovered sessions
        session_selection: usize, // Selected session index

        expanded_comments: std.AutoHashMap(usize, void), // Set of expanded comment indices
        collapsed_folds: std.AutoHashMap(u64, void), // Set of collapsed file/hunk folds (keyed by FoldKey)

        pending_ctrl_w: bool, // Waiting for second key in Ctrl+w chord

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
        model_selection: usize, // Selected index in model picker (within filtered list)
        model_filter_query: [256]u8, // Search query for filtering models
        model_filter_len: usize, // Length of search query
        model_filtered_indices: std.ArrayList(usize), // Indices of models matching filter
        permission_selection: usize, // Selected index in permission mode picker

        // Agent selection state (for choosing which agent to connect to)
        configured_agents: ?[]acp.AgentInfo, // Available agents from config or fallback
        agent_selection_idx: usize, // Selected index in agent picker

        // Tab waiting for agent selection (after :new_tab)
        pending_tab_for_selection: ?u32,

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
        const log = std.log.scoped(.app_init);
        const is_agent_only = if (@hasField(@TypeOf(config), "agent_only")) config.agent_only else false;

        const profile_render = if (profiling_enabled) readEnvBool(allocator, "SKIM_PROFILE_RENDER") else false;
        const profile_every_n = if (profiling_enabled) readEnvU32(allocator, "SKIM_PROFILE_RENDER_EVERY", 30) else 0;
        if (profiling_enabled and profile_render) {
            log.info("Render profiling enabled (every {d} frames)", .{profile_every_n});
        }

        // Determine if we're in pager mode (reading diff from stdin)
        const is_pager_mode = config.diff_source == .stdin;

        // Get git repository root (for resolving file paths)
        // In pager/agent-only mode, use current directory as fallback
        const git_repo_root = if (is_agent_only or is_pager_mode)
            try allocator.dupe(u8, ".")
        else
            try git.getRepoRoot(allocator);
        errdefer allocator.free(git_repo_root);

        // Load and parse diff BEFORE initializing TUI
        // This ensures git errors print correctly (TUI puts terminal in raw mode)
        const files = if (is_agent_only) blk: {
            break :blk try allocator.alloc(parser.FileDiff, 0);
        } else if (is_pager_mode) blk: {
            // Pager mode: parse directly from stdin content
            // Strip ANSI codes since git sends colored output to pagers
            const stdin_text = config.stdin_content orelse "";
            const clean_text = try parser.stripAnsi(allocator, stdin_text);

            // Check for combined diff format (produced during merge/rebase conflicts)
            // Combined diff uses "diff --cc" header instead of "diff --git"
            // We can't parse this format, so fall back to fetching unified diff
            if (std.mem.startsWith(u8, clean_text, "diff --cc ") or
                std.mem.indexOf(u8, clean_text, "\ndiff --cc ") != null)
            {
                log.info("Detected combined diff format, fetching unified diff instead", .{});
                allocator.free(clean_text);
                // Fall back to fetching proper unified diff with HEAD
                const diff_result = try git.getDiffWithUntracked(allocator, .{ .working_dir = .{ .staged = false } });
                defer diff_result.deinit(allocator);
                const parsed_files = try parser.parse(allocator, diff_result.diff_text);
                parser.markUntrackedFiles(parsed_files, diff_result.untracked_paths);
                break :blk parsed_files;
            }

            defer allocator.free(clean_text);
            break :blk try parser.parse(allocator, clean_text);
        } else blk: {
            // Normal mode: load git diff (including untracked files for working directory mode)
            const diff_result = try git.getDiffWithUntracked(allocator, config.diff_source);
            defer diff_result.deinit(allocator);

            const parsed_files = try parser.parse(allocator, diff_result.diff_text);
            parser.markUntrackedFiles(parsed_files, diff_result.untracked_paths);
            break :blk parsed_files;
        };
        errdefer {
            for (files) |*file| {
                file.deinit(allocator);
            }
            allocator.free(files);
        }

        // Now initialize TUI (after git operations complete successfully)
        // This ensures git errors print correctly before terminal enters raw mode
        var tty = try vaxis.Tty.init(&tty_static_buffer);
        errdefer tty.deinit();

        clipboard.setTtyFd(tty.fd);

        var vx = try Vaxis.init(allocator, .{
            .kitty_keyboard_flags = .{
                .disambiguate = true,
                .report_events = false,
                .report_alternate_keys = true,
                .report_all_as_ctl_seqs = true,
                .report_text = true,
            },
            .system_clipboard_allocator = allocator,
        });
        errdefer vx.deinit(allocator, tty.writer());

        const header_buffers = std.mem.zeroes([Layout.header_height][HEADER_BUFFER_WIDTH]u8);

        const frame_buffer = try allocator.alloc(u8, FRAME_TEXT_CAPACITY);
        errdefer allocator.free(frame_buffer);
        @memset(frame_buffer, 0);

        var syntax_highlighter = try syntax.SyntaxHighlighter.init(allocator);
        errdefer syntax_highlighter.deinit();

        var comment_store = comments.CommentStore.init(allocator);
        errdefer comment_store.deinit();

        var frame_segment_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer frame_segment_arena.deinit();

        const caches = try buildFileCaches(allocator, files);
        errdefer {
            allocator.free(caches.stats);
            allocator.free(caches.line_counts);
        }

        // Build the line map (default to showing all lines, filtering enabled for unified view)
        // Note: collapsed_folds is null during init as it hasn't been initialized yet
        var built_line_map = try line_map.LineMap.build(allocator, files, &comment_store, .all, true, null);
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
            .stdin => .stdin,
        };
        errdefer switch (owned_diff_source) {
            .working_dir, .stdin => {},
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
                .pager_mode = is_pager_mode,
                .git_repo_root = git_repo_root,
                .files = files,
                .file_diff_stats = caches.stats,
                .file_line_counts = caches.line_counts,
                .global_gutter_width = caches.gutter_width,
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
                .pending_space = false,
                .pending_bracket = false,
                .pending_close_bracket = false,
                .empty_menu_selection = 0,
                .branch_list = &[_][]const u8{},
                .branch_selection = 0,
                .branch_search_query = undefined,
                .branch_search_len = 0,
                .filtered_branches = .{},
                .help_scroll_offset = 0,
                .commit_list = .{},
                .commit_selection = 0,
                .commit_search_query = undefined,
                .commit_search_len = 0,
                .filtered_commits = .{},
                .commits_loaded_count = 0,
                .commits_loading = false,
                .selected_commit_for_diff = null,
                .commit_diff_mode_selection = 0,
                .session_list = &[_]sessions.SessionInfo{},
                .session_selection = 0,
                .expanded_comments = std.AutoHashMap(usize, void).init(allocator),
                .collapsed_folds = std.AutoHashMap(u64, void).init(allocator),
                .pending_ctrl_w = false,
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
                .model_filter_query = [_]u8{0} ** 256,
                .model_filter_len = 0,
                .model_filtered_indices = .{},
                .permission_selection = 0,
                .configured_agents = null, // Loaded when agent panel opens
                .agent_selection_idx = 0,
                .pending_tab_for_selection = null, // No tab waiting for agent selection
            },
            .should_quit = false,
            .should_suspend_for_editor = false,
            .editor_file_path = null,
            .editor_line_number = null,
            .editor_is_prompt_edit = false,
            .last_ctrl_c = 0,
            .header_line_buffers = header_buffers,
            .frame_text_buffer = frame_buffer,
            .frame_text_used = 0,
            .frame_segment_arena = frame_segment_arena,
            .syntax_highlighter = syntax_highlighter,
            .highlight_worker = null, // Will be created on first use
            .pending_highlight_jobs = std.AutoHashMap(HunkKey, PendingJob).init(allocator),
            .needs_render = false,
            .needs_async_highlight = true, // Start with highlighting needed for first file
            .tui_server = null,
            .session_manager = null,
            .blame_cache = std.StringHashMap(blame.BlameData).init(allocator),
            .pending_connection = null,
            .pending_subagent_fetch = .{},
            .in_bracketed_paste = false,
            .agent_only = is_agent_only,
            .tab_manager = null, // Lazy initialization on first agent panel open
            .profile_render = profile_render,
            .profile_every_n = profile_every_n,
            .profile_frame_counter = 0,
            .profile_active_frame = false,
            .profile_counters = .{},
        };

        // Graphite detection is lazy - happens on first access to avoid blocking startup
        // Main loop will spawn background thread to highlight initial file
        return app;
    }

    /// Initialize App in headless mode (no TUI, for print command).
    /// Loads and parses the diff but skips TTY/vaxis initialization.
    pub fn initHeadless(allocator: Allocator, diff_source: DiffSource) !App {
        // Get git repository root
        const git_repo_root = try git.getRepoRoot(allocator);
        errdefer allocator.free(git_repo_root);

        // Load and parse diff
        const diff_result = try git.getDiffWithUntracked(allocator, diff_source);
        defer diff_result.deinit(allocator);

        const files = try parser.parse(allocator, diff_result.diff_text);
        errdefer {
            for (files) |*file| {
                file.deinit(allocator);
            }
            allocator.free(files);
        }
        parser.markUntrackedFiles(files, diff_result.untracked_paths);

        const header_buffers = std.mem.zeroes([Layout.header_height][HEADER_BUFFER_WIDTH]u8);

        const frame_buffer = try allocator.alloc(u8, FRAME_TEXT_CAPACITY);
        errdefer allocator.free(frame_buffer);
        @memset(frame_buffer, 0);

        var syntax_highlighter = try syntax.SyntaxHighlighter.init(allocator);
        errdefer syntax_highlighter.deinit();

        var comment_store = comments.CommentStore.init(allocator);
        errdefer comment_store.deinit();

        var frame_segment_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer frame_segment_arena.deinit();

        const caches = try buildFileCaches(allocator, files);
        errdefer {
            allocator.free(caches.stats);
            allocator.free(caches.line_counts);
        }

        var built_line_map = try line_map.LineMap.build(allocator, files, &comment_store, .all, true, null);
        errdefer built_line_map.deinit();

        // Deep copy diff_source
        const owned_diff_source: DiffSource = switch (diff_source) {
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
            .stdin => .stdin,
        };
        errdefer switch (owned_diff_source) {
            .working_dir, .stdin => {},
            .single_ref => |sr| allocator.free(sr.ref),
            .two_refs => |tr| {
                allocator.free(tr.ref1);
                allocator.free(tr.ref2);
            },
        };

        return App{
            .allocator = allocator,
            .vx = null, // Headless mode - no TUI
            .tty = null, // Headless mode - no TUI
            .mode = .normal,
            .state = State{
                .diff_source = owned_diff_source,
                .pager_mode = false,
                .git_repo_root = git_repo_root,
                .files = files,
                .file_diff_stats = caches.stats,
                .file_line_counts = caches.line_counts,
                .global_gutter_width = caches.gutter_width,
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
                .pending_space = false,
                .pending_bracket = false,
                .pending_close_bracket = false,
                .empty_menu_selection = 0,
                .branch_list = &[_][]const u8{},
                .branch_selection = 0,
                .branch_search_query = undefined,
                .branch_search_len = 0,
                .filtered_branches = .{},
                .help_scroll_offset = 0,
                .commit_list = .{},
                .commit_selection = 0,
                .commit_search_query = undefined,
                .commit_search_len = 0,
                .filtered_commits = .{},
                .commits_loaded_count = 0,
                .commits_loading = false,
                .selected_commit_for_diff = null,
                .commit_diff_mode_selection = 0,
                .session_list = &[_]sessions.SessionInfo{},
                .session_selection = 0,
                .expanded_comments = std.AutoHashMap(usize, void).init(allocator),
                .collapsed_folds = std.AutoHashMap(u64, void).init(allocator),
                .pending_ctrl_w = false,
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
                .graphite_detected = false,
                .graphite_available = false,
                .graphite_stack = null,
                .graphite_stack_selection = 0,
                .model_selection = 0,
                .model_filter_query = [_]u8{0} ** 256,
                .model_filter_len = 0,
                .model_filtered_indices = .{},
                .permission_selection = 0,
                .configured_agents = null,
                .agent_selection_idx = 0,
                .pending_tab_for_selection = null,
            },
            .should_quit = false,
            .should_suspend_for_editor = false,
            .editor_file_path = null,
            .editor_line_number = null,
            .editor_is_prompt_edit = false,
            .last_ctrl_c = 0,
            .header_line_buffers = header_buffers,
            .frame_text_buffer = frame_buffer,
            .frame_text_used = 0,
            .frame_segment_arena = frame_segment_arena,
            .syntax_highlighter = syntax_highlighter,
            .highlight_worker = null,
            .pending_highlight_jobs = std.AutoHashMap(HunkKey, PendingJob).init(allocator),
            .needs_render = false,
            .needs_async_highlight = false, // No async highlighting in headless mode
            .tui_server = null,
            .session_manager = null,
            .blame_cache = std.StringHashMap(blame.BlameData).init(allocator),
            .pending_connection = null,
            .pending_subagent_fetch = .{},
            .in_bracketed_paste = false,
            .agent_only = false,
            .tab_manager = null,
            .profile_render = false,
            .profile_every_n = 0,
            .profile_frame_counter = 0,
            .profile_active_frame = false,
            .profile_counters = .{},
        };
    }

    pub fn initForRenderBench(allocator: Allocator, files: []parser.FileDiff) !App {
        const git_repo_root = try allocator.dupe(u8, ".");
        errdefer allocator.free(git_repo_root);

        const header_buffers = std.mem.zeroes([Layout.header_height][HEADER_BUFFER_WIDTH]u8);

        const frame_buffer = try allocator.alloc(u8, FRAME_TEXT_CAPACITY);
        errdefer allocator.free(frame_buffer);
        @memset(frame_buffer, 0);

        var syntax_highlighter = try syntax.SyntaxHighlighter.init(allocator);
        errdefer syntax_highlighter.deinit();

        var comment_store = comments.CommentStore.init(allocator);
        errdefer comment_store.deinit();

        var frame_segment_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer frame_segment_arena.deinit();

        const caches = try buildFileCaches(allocator, files);
        errdefer {
            allocator.free(caches.stats);
            allocator.free(caches.line_counts);
        }

        var built_line_map = try line_map.LineMap.build(allocator, files, &comment_store, .all, true, null);
        errdefer built_line_map.deinit();

        return App{
            .allocator = allocator,
            .vx = null,
            .tty = null,
            .mode = .normal,
            .state = State{
                .diff_source = .stdin,
                .pager_mode = true,
                .git_repo_root = git_repo_root,
                .files = files,
                .file_diff_stats = caches.stats,
                .file_line_counts = caches.line_counts,
                .global_gutter_width = caches.gutter_width,
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
                .pending_space = false,
                .pending_bracket = false,
                .pending_close_bracket = false,
                .empty_menu_selection = 0,
                .branch_list = &[_][]const u8{},
                .branch_selection = 0,
                .branch_search_query = undefined,
                .branch_search_len = 0,
                .filtered_branches = .{},
                .help_scroll_offset = 0,
                .commit_list = .{},
                .commit_selection = 0,
                .commit_search_query = undefined,
                .commit_search_len = 0,
                .filtered_commits = .{},
                .commits_loaded_count = 0,
                .commits_loading = false,
                .selected_commit_for_diff = null,
                .commit_diff_mode_selection = 0,
                .session_list = &[_]sessions.SessionInfo{},
                .session_selection = 0,
                .expanded_comments = std.AutoHashMap(usize, void).init(allocator),
                .collapsed_folds = std.AutoHashMap(u64, void).init(allocator),
                .pending_ctrl_w = false,
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
                .graphite_detected = false,
                .graphite_available = false,
                .graphite_stack = null,
                .graphite_stack_selection = 0,
                .model_selection = 0,
                .model_filter_query = [_]u8{0} ** 256,
                .model_filter_len = 0,
                .model_filtered_indices = .{},
                .permission_selection = 0,
                .configured_agents = null,
                .agent_selection_idx = 0,
                .pending_tab_for_selection = null,
            },
            .should_quit = false,
            .should_suspend_for_editor = false,
            .editor_file_path = null,
            .editor_line_number = null,
            .editor_is_prompt_edit = false,
            .last_ctrl_c = 0,
            .header_line_buffers = header_buffers,
            .frame_text_buffer = frame_buffer,
            .frame_text_used = 0,
            .frame_segment_arena = frame_segment_arena,
            .syntax_highlighter = syntax_highlighter,
            .highlight_worker = null,
            .pending_highlight_jobs = std.AutoHashMap(HunkKey, PendingJob).init(allocator),
            .needs_render = false,
            .needs_async_highlight = false,
            .tui_server = null,
            .session_manager = null,
            .blame_cache = std.StringHashMap(blame.BlameData).init(allocator),
            .pending_connection = null,
            .pending_subagent_fetch = .{},
            .in_bracketed_paste = false,
            .agent_only = false,
            .tab_manager = null,
            .profile_render = false,
            .profile_every_n = 0,
            .profile_frame_counter = 0,
            .profile_active_frame = false,
            .profile_counters = .{},
        };
    }

    fn shouldProfileFrame(self: *App) bool {
        if (!profiling_enabled) {
            self.profile_active_frame = false;
            return false;
        }
        if (!self.profile_render) {
            self.profile_active_frame = false;
            return false;
        }
        self.profile_frame_counter += 1;
        const every = if (self.profile_every_n == 0) 1 else self.profile_every_n;
        const active = (self.profile_frame_counter % every) == 0;
        self.profile_active_frame = active;
        return active;
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
            .working_dir, .stdin => {},
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
        self.freeFileCaches();
        self.allocator.free(self.frame_text_buffer);
        self.frame_segment_arena.deinit();
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
        // Free commit list
        for (self.state.commit_list.items) |*commit| {
            commit.deinit(self.allocator);
        }
        self.state.commit_list.deinit(self.allocator);
        self.state.filtered_commits.deinit(self.allocator);
        // Free selected commit for diff mode
        if (self.state.selected_commit_for_diff) |*commit| {
            commit.deinit(self.allocator);
        }
        self.state.expanded_comments.deinit();
        self.state.collapsed_folds.deinit();
        self.state.branch_stats_cache.deinit();
        self.state.model_filtered_indices.deinit(self.allocator);
        // Clean up cached default branch name
        if (self.state.default_branch_name) |name| {
            self.allocator.free(name);
        }
        // Clean up graphite stack
        if (self.state.graphite_stack) |*stack| {
            stack.deinit(self.allocator);
        }
        // Clean up TUI server and session
        if (self.session_manager) |*sm| {
            sm.removeSession();
            sm.deinit();
        }
        if (self.tui_server) |*server| {
            server.deinit();
        }
        // Clean up pending connection thread and context
        // IMPORTANT: Must join (not detach) to wait for thread to complete
        // before freeing resources it depends on (manager, transport, etc.)
        if (self.pending_connection) |conn| {
            conn.thread.join();
            switch (conn.ctx) {
                .acp => |ctx| self.allocator.destroy(ctx),
                .opencode => |ctx| self.allocator.destroy(ctx),
                .codex => |ctx| self.allocator.destroy(ctx),
            }
            self.pending_connection = null;
        }
        // Clean up tab manager (handles per-tab ACP, Opencode, and Codex managers)
        if (self.tab_manager) |*tm| {
            tm.deinit();
        }
        // Clean up blame cache
        var blame_iter = self.blame_cache.iterator();
        while (blame_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.blame_cache.deinit();
        self.syntax_highlighter.deinit();
        // Only deinit vx/tty in TUI mode (not headless)
        if (self.vx) |*vx| {
            if (self.tty) |*tty| {
                vx.deinit(self.allocator, tty.writer());
                tty.deinit();
            }
        }
    }

    // =========================================================================
    // Tab Manager Helpers
    // =========================================================================

    /// Get the active agent state from the current tab
    pub fn getActiveAgentState(self: *App) ?*agent.AgentState {
        if (self.tab_manager) |*tm| {
            if (tm.activeTab()) |tab| {
                return &tab.agent_state;
            }
        }
        return null;
    }

    /// Get the active agent state (const version)
    pub fn getActiveAgentStateConst(self: *const App) ?*const agent.AgentState {
        if (self.tab_manager) |tm| {
            if (tm.activeTabConst()) |tab| {
                return &tab.agent_state;
            }
        }
        return null;
    }

    /// Get the active manager (ACP or OpenCode) from the current tab
    pub fn getActiveManager(self: *App) ?agent.tab_manager.ManagerHandle {
        if (self.tab_manager) |*tm| {
            if (tm.activeTab()) |tab| return tab.manager;
        }
        return null;
    }

    /// Get the active ACP manager from the current tab
    pub fn getActiveAcpManager(self: *App) ?*acp.AcpManager {
        if (self.tab_manager) |*tm| {
            if (tm.activeTab()) |tab| {
                return tab.getActiveAcpManager();
            }
        }
        return null;
    }

    /// Check if agent panel is visible
    pub fn isAgentPanelVisible(self: *const App) bool {
        const tm = self.tab_manager orelse return false;
        return tm.panel_visible;
    }

    /// Check if waiting for a second Ctrl+C press (for normal/comment modes)
    pub fn isPendingCtrlC(self: *const App) bool {
        if (self.last_ctrl_c == 0) return false;
        const now: i64 = @intCast(std.time.nanoTimestamp());
        return (now - self.last_ctrl_c) < App.CTRL_C_TIMEOUT_NS;
    }

    /// Update the filtered model indices based on the current filter query
    /// Works with both ACP and OpenCode managers
    pub fn updateModelFilter(self: *App) void {
        // Clear existing filtered indices
        self.state.model_filtered_indices.clearRetainingCapacity();

        const query = self.state.model_filter_query[0..self.state.model_filter_len];

        if (self.getActiveManager()) |mgr| {
            const count = mgr.getModelCount();
            if (query.len == 0) {
                for (0..count) |i| {
                    self.state.model_filtered_indices.append(self.allocator, i) catch {};
                }
            } else {
                for (0..count) |i| {
                    const model = mgr.getModelInfo(i);
                    if (containsIgnoreCase(model.name, query) or containsIgnoreCase(model.model_id, query)) {
                        self.state.model_filtered_indices.append(self.allocator, i) catch {};
                    }
                }
            }
        }

        // Reset selection to 0 if current selection is out of bounds
        if (self.state.model_selection >= self.state.model_filtered_indices.items.len) {
            self.state.model_selection = 0;
        }
    }

    /// Reset model filter state (called when entering model selection mode)
    pub fn resetModelFilter(self: *App) void {
        self.state.model_filter_query = [_]u8{0} ** 256;
        self.state.model_filter_len = 0;
        self.state.model_selection = 0;
        self.updateModelFilter();
    }

    /// Check if agent panel is in full-screen mode
    pub fn isAgentFullScreen(self: *const App) bool {
        const tm = self.tab_manager orelse return false;
        return tm.full_screen;
    }

    /// Check if both diff and agent panels are visible (split view)
    pub fn areBothPanelsVisible(self: *const App) bool {
        return self.isAgentPanelVisible() and !self.isAgentFullScreen();
    }

    /// Get the agent panel side
    pub fn getAgentPanelSide(self: *const App) agent.AgentState.PanelSide {
        const tm = self.tab_manager orelse return .right;
        return tm.panel_side;
    }

    /// Initialize tab manager if not already initialized
    pub fn ensureTabManager(self: *App) !*agent.TabManager {
        if (self.tab_manager == null) {
            const config = app_config.load(self.allocator) catch app_config.Config{};
            const panel_side: agent.AgentState.PanelSide = switch (config.agent_panel_side) {
                .left => .left,
                .right => .right,
            };
            self.tab_manager = agent.TabManager.init(self.allocator, panel_side);
        }
        return &(self.tab_manager.?);
    }

    /// Check if any manager (across all tabs) has activity requiring responsive polling
    pub fn hasAnyManagerActivity(self: *const App) bool {
        if (self.tab_manager) |tm| {
            return tm.hasAnyActivity();
        }
        return false;
    }

    /// Get the active Opencode manager from the current tab
    pub fn getActiveOpencodeManager(self: *App) ?*opencode.OpencodeManager {
        if (self.tab_manager) |*tm| {
            if (tm.activeTab()) |tab| {
                return tab.getActiveOpencodeManager();
            }
        }
        return null;
    }

    /// Check if the active tab's agent is thinking (ACP or Opencode)
    pub fn isAgentThinking(self: *App) bool {
        if (self.tab_manager) |*tm| {
            if (tm.activeTab()) |tab| {
                return tab.isThinking();
            }
        }
        return false;
    }

    /// Check if the active tab's agent is compacting context
    pub fn isAgentCompacting(self: *App) bool {
        if (self.tab_manager) |*tm| {
            if (tm.activeTab()) |tab| {
                return tab.isCompacting();
            }
        }
        return false;
    }

    /// Check if the active tab's session is ready (can accept prompts)
    pub fn isSessionReady(self: *App) bool {
        if (self.tab_manager) |*tm| {
            if (tm.activeTab()) |tab| {
                return tab.isSessionReady();
            }
        }
        return false;
    }

    /// Check if the active tab's session is initializing
    pub fn isSessionInitializing(self: *App) bool {
        if (self.tab_manager) |*tm| {
            if (tm.activeTab()) |tab| {
                return tab.isSessionInitializing();
            }
        }
        return false;
    }

    /// Check if any tab has a running shell command
    pub fn hasAnyRunningShellCommand(self: *const App) bool {
        if (self.tab_manager) |tm| {
            for (tm.tabs.items) |*tab| {
                if (tab.agent_state.hasRunningShellCommand()) return true;
            }
        }
        return false;
    }

    /// Auto-name the active tab from the user's first prompt
    pub fn autoNameActiveTab(self: *App, prompt: []const u8) void {
        if (self.tab_manager) |*tm| {
            if (tm.activeTab()) |tab| {
                tab.autoNameFromPrompt(prompt) catch {};
            }
        }
    }

    pub fn refresh(self: *App) !void {
        // Disabled in pager mode (stdin content is read once)
        if (self.state.pager_mode) return;

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

        const caches = try buildFileCaches(self.allocator, new_files);
        errdefer {
            self.allocator.free(caches.stats);
            self.allocator.free(caches.line_counts);
        }

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
        self.freeFileCaches();

        // Rebuild line map with new files (preserve hunk view mode and fold state)
        const new_line_map = try line_map.LineMap.build(self.allocator, new_files, &self.state.comment_store, self.convertHunkViewMode(), self.shouldApplyHunkFiltering(), &self.state.collapsed_folds);
        errdefer {
            // If LineMap.build failed, clean up new_files since old state is already freed
            for (new_files) |*file| {
                file.deinit(self.allocator);
            }
            self.allocator.free(new_files);
        }

        // Update state with new files and line map
        self.state.files = new_files;
        self.state.file_diff_stats = caches.stats;
        self.state.file_line_counts = caches.line_counts;
        self.state.global_gutter_width = caches.gutter_width;
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

        // Keep external session discovery metadata in sync with the current diff.
        self.syncSessionMetadata();
    }

    /// Stage the current file (git add) and refresh the view
    pub fn stageCurrentFile(self: *App) !void {
        // Disabled in pager mode
        if (self.state.pager_mode) return;

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
        // Disabled in pager mode
        if (self.state.pager_mode) return;

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
        // Set up the terminal (requires TUI mode - vx/tty must be initialized)
        const tty = &(self.tty orelse return error.HeadlessMode);
        const vx = &(self.vx orelse return error.HeadlessMode);
        const writer = tty.writer();

        try vx.enterAltScreen(writer);

        // Query terminal capabilities (50ms timeout - enough for modern terminals)
        try vx.queryTerminal(writer, 50 * std.time.ns_per_ms);

        var loop: vaxis.Loop(Event) = .{
            .tty = tty,
            .vaxis = vx,
        };
        try loop.init();
        try loop.start();
        defer loop.stop();

        // Start TUI server for CLI/MCP connections
        self.startTuiServer() catch |err| {
            std.log.warn("Failed to start TUI server: {any}", .{err});
        };

        // If agent-only mode, start with agent panel open and in full-screen mode
        if (self.agent_only) {
            // Initialize tab manager with first tab
            const tm = self.ensureTabManager() catch |err| {
                std.log.err("Failed to initialize tab manager: {any}", .{err});
                return;
            };
            _ = tm.ensureTab() catch |err| {
                std.log.err("Failed to create initial tab: {any}", .{err});
                return;
            };

            tm.panel_visible = true;
            tm.full_screen = true;
            self.mode = .agent;

            // Add local slash commands (like /model)
            if (self.getActiveAgentState()) |agent_state| {
                agent_state.addLocalSlashCommands() catch |err| {
                    std.log.err("Failed to add local slash commands: {any}", .{err});
                };
            }

            // Start ACP session
            self.startAcpSession() catch |err| {
                std.log.err("Failed to start ACP session: {any}", .{err});
            };
        }

        var first_render = true;
        var last_shimmer_render: i64 = 0;

        // Main event loop
        while (!self.should_quit) {
            // Only block on pollEvent if we don't need to render AND no async job is running
            // AND no TUI server active (need to poll for incoming connections)
            // AND no ACP data pending (agent actively producing output)
            // This allows async operations to trigger immediate renders
            const server_active = self.tui_server != null;
            const stats_loading = self.state.menu_stats_loading;
            // Check all tabs for manager activity (ACP or OpenCode)
            const manager_active = self.hasAnyManagerActivity();
            // Check if a shell command is running (needs streaming output) - check all tabs
            const shell_cmd_running = self.hasAnyRunningShellCommand();
            // Check if a connection thread is running (need to poll for completion)
            const connecting = self.pending_connection != null;
            const should_poll = !self.needs_render and self.pending_highlight_jobs.count() == 0 and !server_active and !stats_loading and !manager_active and !shell_cmd_running and !connecting;
            if (should_poll) {
                loop.pollEvent();
            } else {
                // Adaptive sleep based on activity level:
                // - High activity (prompting): 5ms for smooth streaming (~200 FPS)
                // - Medium activity (connecting, shell running): 8ms (~125 FPS)
                // - Low activity (just rendering): 16ms (~60 FPS)
                const is_high_activity = manager_active or shell_cmd_running;
                const is_medium_activity = connecting or server_active;
                const sleep_ms: u64 = if (is_high_activity) 5 else if (is_medium_activity) 8 else 16;
                std.Thread.sleep(sleep_ms * std.time.ns_per_ms);
            }
            // When not blocking (acp_active, mcp_active, etc.), events are still
            // captured by the vaxis reader thread and available via tryEvent()

            // Check if we need to suspend for editor
            if (self.should_suspend_for_editor) {
                // Stop the event loop to release TTY
                loop.stop();

                // Exit alt screen
                try vx.exitAltScreen(tty.writer());

                // Open editor (blocks until editor exits)
                if (self.editor_file_path) |file_path| {
                    defer self.allocator.free(file_path);
                    editor.openInEditor(self.allocator, file_path, self.editor_line_number) catch |err| {
                        std.log.err("Failed to open editor: {any}", .{err});
                    };

                    // If this was a prompt edit, read the content back
                    if (self.editor_is_prompt_edit) {
                        // Read the edited content from the temp file
                        if (std.fs.cwd().readFileAlloc(self.allocator, file_path, 1024 * 1024)) |content| {
                            defer self.allocator.free(content);
                            if (self.getActiveAgentState()) |agent_state| {
                                // Trim trailing newlines (editors often add them)
                                var trimmed = content;
                                while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\n') {
                                    trimmed = trimmed[0 .. trimmed.len - 1];
                                }
                                // Update the input editor with the new content
                                agent_state.input.setText(trimmed);
                                // Position cursor at end
                                agent_state.input.vim.cursor_pos = agent_state.input.vim.text_len;
                            }
                        } else |err| {
                            std.log.err("Failed to read edited prompt: {any}", .{err});
                        }
                        // Delete the temp file
                        std.fs.cwd().deleteFile(file_path) catch |err| {
                            std.log.warn("Failed to delete temp file: {any}", .{err});
                        };
                    }
                }

                // Re-enter alt screen
                try vx.enterAltScreen(tty.writer());

                // Restart the event loop
                try loop.start();

                // Refresh diff after returning from editor (only for file editing, not prompt editing)
                if (!self.editor_is_prompt_edit) {
                    try self.refresh();
                }

                // Force a full render after re-entering alt screen
                self.needs_render = true;

                // Clear the suspend flag
                self.should_suspend_for_editor = false;
                self.editor_file_path = null;
                self.editor_line_number = null;
                self.editor_is_prompt_edit = false;
            }

            // Process all pending events
            var had_events = false;
            while (loop.tryEvent()) |event| {
                try self.handleEvent(event);
                had_events = true;
            }

            // Clear expired messages
            self.clearExpiredStatusMessage();

            // Poll all agent managers (connection thread + per-tab polling)
            {
                const has_any_manager = if (self.tab_manager) |tm| blk: {
                    for (tm.tabs.items) |*tab| {
                        if (tab.manager != null) break :blk true;
                    }
                    break :blk false;
                } else false;

                if (self.pending_connection != null or has_any_manager) {
                    self.pollAllManagers();
                }
            }

            // Throttled re-render for the shimmer animation on the thinking indicator.
            // The shimmer changes phase every 80ms, so re-rendering faster is wasted work.
            if (manager_active and !self.needs_render) {
                const now_ms = std.time.milliTimestamp();
                if (now_ms - last_shimmer_render >= 80) {
                    self.needs_render = true;
                    last_shimmer_render = now_ms;
                }
            }

            // Poll running shell command for streaming output
            if (agent_mode.pollRunningShellCommand(self)) {
                self.needs_render = true;
            }

            // Poll async file loading for file picker (all tabs)
            if (self.tab_manager) |*tm| {
                for (tm.tabs.items) |*tab| {
                    if (tab.agent_state.file_picker.pollAsyncLoad()) {
                        self.needs_render = true;
                    }
                }
            }

            // Poll subagent fetch result (worker thread -> main thread)
            self.pollSubagentFetch();

            // Render if we had events, need to update, or first render
            if (had_events or self.needs_render or first_render) {
                const win = vx.window();

                if (profiling_enabled) {
                    const profile_log = std.log.scoped(.profile_loop);
                    _ = self.shouldProfileFrame();

                    if (self.profile_active_frame) {
                        var render_timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try self.render(win);
                        const render_ns: u64 = if (render_timer_opt) |*timer| timer.read() else 0;

                        var vx_timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try vx.render(tty.writer());
                        const vx_ns: u64 = if (vx_timer_opt) |*timer| timer.read() else 0;

                        profile_log.debug(
                            "frame {d}: render_ns={d} vx_ns={d} events={} needs_render={} pending_jobs={d}",
                            .{ self.profile_frame_counter, render_ns, vx_ns, had_events, self.needs_render, self.pending_highlight_jobs.count() },
                        );
                    } else {
                        try self.render(win);
                        try vx.render(tty.writer());
                    }

                    self.profile_active_frame = false;
                } else {
                    try self.render(win);
                    try vx.render(tty.writer());
                }
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
                    const hunk_idx = result.hunk_idx;

                    // Remove from pending jobs and free content
                    const key = HunkKey{ .file_idx = file_idx, .hunk_idx = hunk_idx };
                    if (self.pending_highlight_jobs.fetchRemove(key)) |entry| {
                        self.allocator.free(entry.value.content);
                        self.allocator.free(entry.value.old_content);
                    }

                    // Apply highlights to hunk
                    if (file_idx < self.state.files.len) {
                        const file = &self.state.files[file_idx];
                        if (hunk_idx < file.hunks.len) {
                            const hunk = &file.hunks[hunk_idx];
                            const mutable_hunk = @constCast(hunk);

                            if (result.highlights) |highlights| {
                                mutable_hunk.highlights = highlights;
                            }
                            if (result.old_highlights) |old_highlights| {
                                mutable_hunk.old_highlights = old_highlights;
                            }

                            if (result.highlights != null or result.old_highlights != null) {
                                StateHelpers.rebuildHunkHighlightCaches(self.allocator, mutable_hunk) catch |err| {
                                    std.log.warn("Failed to rebuild highlight cache: {any}", .{err});
                                };
                            }

                            // Only trigger re-render if this is the CURRENT file
                            if (file_idx == self.state.current_file_idx) {
                                self.needs_render = true;
                            }
                        } else {
                            // Hunk no longer exists, free highlights
                            if (self.highlight_worker) |w| {
                                if (result.highlights) |highlights| {
                                    w.highlighter.freeHighlights(highlights);
                                }
                                if (result.old_highlights) |old_highlights| {
                                    w.highlighter.freeHighlights(old_highlights);
                                }
                            }
                        }
                    } else {
                        // File no longer exists (refresh happened), free highlights
                        if (self.highlight_worker) |w| {
                            if (result.highlights) |highlights| {
                                w.highlighter.freeHighlights(highlights);
                            }
                            if (result.old_highlights) |old_highlights| {
                                w.highlighter.freeHighlights(old_highlights);
                            }
                        }
                    }
                }
            }

            // Poll TUI server for incoming connections and requests
            if (self.tui_server) |*server| {
                server.poll() catch |err| {
                    std.log.warn("TUI server poll error: {any}", .{err});
                };
            }

            // Submit highlighting jobs for visible hunks (per-hunk highlighting)
            // Strategy: Highlight hunks in files that are currently visible on screen
            // This ensures smooth scrolling without waiting for highlights
            if (self.state.files.len > 0) {
                // Create worker on first use
                if (self.highlight_worker == null) {
                    self.highlight_worker = state_helpers.HighlightWorker.init(self.allocator) catch null;
                }

                if (self.highlight_worker) |worker| {
                    // Determine which files are visible in the viewport
                    const viewport_height = self.state.viewport_height;
                    const scroll_line = self.state.global_scroll_offset;
                    const visible_end = scroll_line + viewport_height;

                    // Start from file at scroll position
                    const start_file_idx = self.state.line_map.getFileIndexForLine(scroll_line) orelse 0;

                    // Submit jobs for visible hunks (current file + up to 3 files ahead)
                    var hunks_submitted: usize = 0;
                    const max_hunks_per_frame: usize = 8; // Limit hunks per frame to prevent overwhelming

                    var check_idx = start_file_idx;
                    file_loop: while (check_idx < self.state.files.len) : (check_idx += 1) {
                        const file = &self.state.files[check_idx];

                        // Check if this file is visible or close to visible
                        if (self.state.line_map.getFileHeaderLine(check_idx)) |file_header_line| {
                            const buffer_lines = viewport_height; // One screen ahead
                            if (file_header_line > visible_end + buffer_lines) {
                                break; // File is too far ahead
                            }
                        }

                        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

                        // Iterate through hunks in this file
                        for (file.hunks, 0..) |*hunk, hunk_idx| {
                            if (hunks_submitted >= max_hunks_per_frame) break :file_loop;

                            // Skip if already highlighted or job pending
                            const key = HunkKey{ .file_idx = check_idx, .hunk_idx = hunk_idx };
                            if (hunk.highlights != null or self.pending_highlight_jobs.contains(key)) {
                                continue;
                            }

                            // Build NEW hunk content (add/context lines)
                            const content = StateHelpers.buildHunkContent(self.allocator, hunk) catch continue;
                            errdefer self.allocator.free(content);

                            // Build OLD hunk content (delete/context lines)
                            const old_content = StateHelpers.buildHunkOldContent(self.allocator, hunk) catch {
                                self.allocator.free(content);
                                continue;
                            };
                            errdefer self.allocator.free(old_content);

                            // Submit job to worker
                            worker.submitJob(.{
                                .file_path = file_path,
                                .content = content,
                                .old_content = old_content,
                                .file_idx = check_idx,
                                .hunk_idx = hunk_idx,
                            }) catch {
                                self.allocator.free(content);
                                self.allocator.free(old_content);
                                continue;
                            };

                            // Track pending job (store both content strings)
                            self.pending_highlight_jobs.put(key, .{
                                .content = content,
                                .old_content = old_content,
                            }) catch {
                                self.allocator.free(content);
                                self.allocator.free(old_content);
                            };

                            hunks_submitted += 1;
                        }
                    }
                }

                // Reset the flag after processing
                self.needs_async_highlight = false;
            }
        }

        // Exit alt screen before returning
        try vx.exitAltScreen(tty.writer());
    }

    fn handleEvent(self: *App, event: Event) !void {
        switch (event) {
            .key_press => |key| try self.handleKey(key),
            .winsize => |ws| try self.vx.?.resize(self.allocator, self.tty.?.writer(), ws),
            .paste_start => {
                self.in_bracketed_paste = true;
                // Save undo state before bracketed paste begins
                switch (self.mode) {
                    .agent => {
                        if (self.getActiveAgentState()) |agent_state| {
                            agent.InputEditor.VimEditor.pushUndoPublic(&agent_state.input.vim);
                        }
                    },
                    .comment => {
                        if (self.state.active_comment_input) |*input| {
                            comment_editor.CommentEditor.VimEditor.pushUndoPublic(&input.vim);
                        }
                    },
                    else => {},
                }
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
                if (self.getActiveAgentState()) |agent_state| {
                    // Save undo state before paste
                    if (text.len > 0) {
                        agent.InputEditor.VimEditor.pushUndoPublic(&agent_state.input.vim);
                    }
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
                    // Save undo state before paste
                    if (text.len > 0) {
                        comment_editor.CommentEditor.VimEditor.pushUndoPublic(&input.vim);
                    }
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
        // Handle Ctrl-C in modal overlays
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
                .commit_selection => {
                    self.mode = .normal;
                    self.state.commit_search_len = 0;
                    self.state.filtered_commits.clearRetainingCapacity();
                    self.needs_render = true;
                    return;
                },
                .commit_diff_mode => {
                    // Go back to commit selection
                    self.mode = .commit_selection;
                    // Free the selected commit
                    if (self.state.selected_commit_for_diff) |*commit| {
                        commit.deinit(self.allocator);
                        self.state.selected_commit_for_diff = null;
                    }
                    self.needs_render = true;
                    return;
                },
                .visual => {
                    self.mode = .normal;
                    self.state.visual_anchor = null;
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
                .permission_selection => {
                    self.mode = .agent;
                    self.needs_render = true;
                    return;
                },
                .session_picker => {
                    // Cancel session picker, return to agent mode
                    sessions.freeSessions(self.allocator, self.state.session_list);
                    self.state.session_list = &[_]sessions.SessionInfo{};
                    self.state.session_selection = 0;
                    self.mode = .agent;
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
                    // In agent mode, single Ctrl+C exits history mode.
                    if (self.getActiveAgentState()) |agent_state| {
                        if (agent_state.isInHistoryMode()) {
                            agent_state.exitHistoryMode();
                            agent_state.input.vim.vim_mode = .normal;
                            self.needs_render = true;
                            return;
                        }
                    }
                },
                .normal, .comment => {},
            }
        }

        switch (self.mode) {
            .normal => try normal_mode.handleKey(self, key),
            .comment => try comment_mode.handleKey(self, key),
            .search => try search_mode.handleKey(self, key),
            .visual => try visual_mode.handleKey(self, key),
            .command_palette => try command_palette_mode.handleKey(self, key),
            .help => try help_mode.handleKey(self, key),
            .branch_selection => try branch_selection_mode.handleKey(self, key),
            .commit_selection => try commit_selection_mode.handleKey(self, key),
            .commit_diff_mode => try commit_selection_mode.handleDiffModeKey(self, key),
            .graphite_stack => try graphite_mode.handleKey(self, key),
            .model_selection => try model_selection_mode.handleKey(self, key),
            .permission_selection => try permission_selection_mode.handleKey(self, key),
            .agent_selection => try agent_selection_mode.handleKey(self, key),
            .session_picker => try session_picker_mode.handleKey(self, key),
            .agent => try agent_mode.handleKey(self, key),
        }
    }

    pub fn toggleViewMode(self: *App) void {
        // Capture viewport anchor before toggle (anchor to viewport top for stable view)
        const anchor = self.captureViewportAnchor(self.state.global_scroll_offset);

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
            &self.state.collapsed_folds,
        ) catch |err| {
            std.log.err("Failed to rebuild LineMap on view toggle: {any}", .{err});
            return;
        };

        // Restore viewport position from anchor
        _ = self.restoreViewportFromAnchor(anchor);
    }

    pub fn toggleBlame(self: *App) void {
        // Disabled in pager mode
        if (self.state.pager_mode) return;

        self.state.show_blame = !self.state.show_blame;
        self.needs_render = true;

        // If enabling blame, fetch blame for all visible files
        if (self.state.show_blame) {
            self.fetchBlameForVisibleFiles();
        }
    }

    /// Toggle the agent chat panel visibility and focus
    pub fn toggleAgentPanel(self: *App) !void {
        // Initialize tab manager and ensure we have at least one tab
        const tm = try self.ensureTabManager();
        const tab = try tm.ensureTab();
        var agent_state = &tab.agent_state;

        if (tm.panel_visible) {
            // Hide panel, return to normal mode
            tm.panel_visible = false;
            agent_state.visible = false;
            self.mode = .normal;
        } else {
            // Show panel, enter agent mode
            tm.panel_visible = true;
            agent_state.visible = true;
            self.mode = .agent;

            // Re-enable scroll following when reopening panel
            // (user may have scrolled up before closing, we want to see new messages)
            agent_state.scrollToBottom();

            // Preemptively load file list in background for @ mentions
            // This ensures files are ready when user types @, avoiding UI freeze
            if (!agent_state.file_picker.hasFiles() and !agent_state.file_picker.isLoading()) {
                agent_state.file_picker.startAsyncLoad();
            }

            // Add local slash commands (like /model)
            agent_state.addLocalSlashCommands() catch |err| {
                std.log.err("Failed to add local slash commands: {any}", .{err});
            };

            // Auto-connect to agent if not connected
            const has_active_agent = if (self.getActiveManager()) |mgr|
                !mgr.isDisconnected()
            else
                false;
            if (!has_active_agent) {
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

        // Capture anchor based on cursor position (for hunk cycling, cursor is the reference)
        const anchor = self.captureViewportAnchor(self.state.global_cursor_line);

        // Cycle to previous mode
        self.state.hunk_view_mode = self.state.hunk_view_mode.prev();

        // Rebuild LineMap
        self.state.line_map.deinit();
        self.state.line_map = try line_map.LineMap.build(self.allocator, self.state.files, &self.state.comment_store, self.convertHunkViewMode(), self.shouldApplyHunkFiltering(), &self.state.collapsed_folds);

        // Restore positions from anchor
        _ = self.restoreViewportFromAnchor(anchor);
    }

    pub fn cycleHunkViewMode(self: *App) !void {
        // Only apply in unified mode
        if (!self.shouldApplyHunkFiltering()) return;

        // Capture anchor based on cursor position (for hunk cycling, cursor is the reference)
        const anchor = self.captureViewportAnchor(self.state.global_cursor_line);

        // Cycle to next mode
        self.state.hunk_view_mode = self.state.hunk_view_mode.next();

        // Rebuild LineMap to reflect new filtering
        self.state.line_map.deinit();
        self.state.line_map = try line_map.LineMap.build(self.allocator, self.state.files, &self.state.comment_store, self.convertHunkViewMode(), self.shouldApplyHunkFiltering(), &self.state.collapsed_folds);

        // Restore positions from anchor
        _ = self.restoreViewportFromAnchor(anchor);
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

    // Helper: Find the global line number of a specific code line
    fn findCodeLine(self: *App, file_idx: usize, hunk_idx: usize, line_idx_in_hunk: usize) ?usize {
        for (self.state.line_map.records) |*record| {
            if (record.file_idx == file_idx and record.line_type == .code_line) {
                const code_info = record.line_type.code_line;
                if (code_info.hunk_idx == hunk_idx and code_info.line_idx_in_hunk == line_idx_in_hunk) {
                    return record.global_line;
                }
            }
        }
        return null;
    }

    /// Capture viewport anchor for preserving position across LineMap rebuilds.
    /// Uses the viewport top (global_scroll_offset) as reference by default.
    /// Pass a specific reference_line to anchor from a different position (e.g., cursor).
    fn captureViewportAnchor(self: *App, reference_line: usize) ?ViewportAnchor {
        const record = self.state.line_map.getLineRecord(reference_line) orelse return null;

        var anchor_line: ?usize = null;
        var anchor_file: usize = record.file_idx;
        var anchor_hunk: ?usize = null;

        switch (record.line_type) {
            .file_header => {
                anchor_line = reference_line;
                anchor_hunk = null;
            },
            .hunk_header => |hunk_info| {
                anchor_line = reference_line;
                anchor_hunk = hunk_info.hunk_idx;
            },
            .code_line => |code_info| {
                anchor_line = self.findHunkHeaderLine(record.file_idx, code_info.hunk_idx);
                anchor_hunk = code_info.hunk_idx;
            },
            .comment_line => |comment_info| {
                anchor_line = self.findHunkHeaderLine(record.file_idx, comment_info.parent_hunk_idx);
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

        const anc_line = anchor_line orelse return null;
        return ViewportAnchor{
            .file_idx = anchor_file,
            .hunk_idx = anchor_hunk,
            .scroll_offset_from_anchor = @as(isize, @intCast(self.state.global_scroll_offset)) - @as(isize, @intCast(anc_line)),
            .cursor_offset_from_anchor = @as(isize, @intCast(self.state.global_cursor_line)) - @as(isize, @intCast(anc_line)),
        };
    }

    /// Restore viewport position from anchor after LineMap rebuild.
    /// Returns true if anchor was found and positions restored, false if fallback clamping was used.
    fn restoreViewportFromAnchor(self: *App, anchor: ?ViewportAnchor) bool {
        const total_lines = self.getTotalGlobalLines();
        if (total_lines == 0) {
            self.state.global_cursor_line = 0;
            self.state.global_scroll_offset = 0;
            return false;
        }

        if (anchor) |anc| {
            if (anc.file_idx < self.state.files.len) {
                // Find anchor line in new LineMap
                const new_anchor_line = if (anc.hunk_idx) |hunk_idx|
                    self.findHunkHeaderLine(anc.file_idx, hunk_idx)
                else
                    self.state.line_map.getFileHeaderLine(anc.file_idx);

                if (new_anchor_line) |anchor_line| {
                    // Restore cursor position
                    const target_cursor_signed = @as(isize, @intCast(anchor_line)) + anc.cursor_offset_from_anchor;
                    const target_cursor = if (target_cursor_signed < 0) 0 else @as(usize, @intCast(target_cursor_signed));
                    self.state.global_cursor_line = @min(target_cursor, total_lines - 1);

                    // Restore scroll position
                    const target_scroll_signed = @as(isize, @intCast(anchor_line)) + anc.scroll_offset_from_anchor;
                    const target_scroll = if (target_scroll_signed < 0) 0 else @as(usize, @intCast(target_scroll_signed));
                    self.state.global_scroll_offset = target_scroll;

                    Navigation.clampScrollOffset(self);
                    return true;
                }
            }
        }

        // Fallback: clamp positions if anchor restoration failed
        if (self.state.global_cursor_line >= total_lines) {
            self.state.global_cursor_line = total_lines - 1;
        }
        Navigation.clampScrollOffset(self);
        return false;
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

    pub fn saveCurrentComment(self: *App) !bool {
        if (self.state.active_comment_input == null) return false;

        const input = self.state.active_comment_input.?;
        if (input.vim.text_len == 0) {
            // Empty comment - delete if editing existing, otherwise do nothing
            if (input.editing_comment_idx) |idx| {
                try self.state.comment_store.deleteComment(idx);
            }
            return true;
        }

        const comment_text = input.vim.text_buffer[0..input.vim.text_len];

        // Get line context for the comment
        const file_idx = self.findFileIndexByPath(input.target_file_path) orelse {
            self.showStatusMessage("Comment target file not found");
            return false;
        };
        const file = &self.state.files[file_idx];
        if (input.target_hunk_idx >= file.hunks.len) {
            self.showStatusMessage("Comment target hunk not found");
            return false;
        }
        const hunk = &file.hunks[input.target_hunk_idx];
        if (input.target_line_idx >= hunk.lines.len) {
            self.showStatusMessage("Comment target line not found");
            return false;
        }
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
                const end_hunk_idx = input.target_end_hunk_idx.?;
                const end_line_idx = input.target_end_line_idx.?;
                if (end_hunk_idx >= file.hunks.len) {
                    self.showStatusMessage("Comment range hunk not found");
                    return false;
                }
                const end_hunk = &file.hunks[end_hunk_idx];
                if (end_line_idx >= end_hunk.lines.len) {
                    self.showStatusMessage("Comment range line not found");
                    return false;
                }
                // Add range comment
                try self.state.comment_store.addRangeComment(
                    input.target_file_path,
                    input.target_hunk_idx,
                    input.target_line_idx,
                    end_hunk_idx,
                    end_line_idx,
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
        self.state.line_map = try line_map.LineMap.build(self.allocator, self.state.files, &self.state.comment_store, self.convertHunkViewMode(), self.shouldApplyHunkFiltering(), &self.state.collapsed_folds);

        // Move cursor to the saved comment so it can be easily yanked
        if (self.state.line_map.findLineByCommentIdx(saved_comment_idx)) |comment_line| {
            self.state.global_cursor_line = comment_line;
        }
        return true;
    }

    fn findFileIndexByPath(self: *App, target_path: []const u8) ?usize {
        if (target_path.len == 0) return null;
        for (self.state.files, 0..) |file, idx| {
            if (std.mem.eql(u8, file.new_path, target_path) or std.mem.eql(u8, file.old_path, target_path)) {
                return idx;
            }
        }
        return null;
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
        if (!self.isAgentPanelVisible()) {
            try self.toggleAgentPanel();
        }

        // Set the input text in the active agent state
        if (self.getActiveAgentState()) |agent_state| {
            agent_state.input.setText(output);
            // Switch to insert mode so user can add context
            agent_state.input.vim.vim_mode = .insert;
            // Move cursor to end
            agent_state.input.vim.cursor_pos = agent_state.input.vim.text_len;
        }

        self.needs_render = true;
    }

    pub fn deleteCommentUnderCursor(self: *App) !void {
        // Get line record from LineMap
        const record = self.state.line_map.getLineRecord(self.state.global_cursor_line) orelse return;

        switch (record.line_type) {
            .comment_line => |comment_info| {
                const parent_file_idx = record.file_idx;
                const parent_hunk_idx = comment_info.parent_hunk_idx;
                const parent_line_idx = comment_info.parent_line_idx;

                // Capture positions BEFORE deletion
                const old_parent_pos = self.findCodeLine(parent_file_idx, parent_hunk_idx, parent_line_idx);
                const old_scroll = self.state.global_scroll_offset;
                const comment_line = self.state.global_cursor_line; // cursor is on the comment

                // Delete the comment
                try self.state.comment_store.deleteComment(comment_info.comment_idx);

                // Rebuild LineMap since comment count changed
                self.state.line_map.deinit();
                self.state.line_map = try line_map.LineMap.build(self.allocator, self.state.files, &self.state.comment_store, self.convertHunkViewMode(), self.shouldApplyHunkFiltering(), &self.state.collapsed_folds);

                const total_lines = self.getTotalGlobalLines();
                if (total_lines == 0) {
                    self.state.global_cursor_line = 0;
                    self.state.global_scroll_offset = 0;
                    return;
                }

                // Find parent in new LineMap (position unchanged since it's above the deleted comment)
                if (self.findCodeLine(parent_file_idx, parent_hunk_idx, parent_line_idx)) |new_parent_line| {
                    self.state.global_cursor_line = new_parent_line;

                    // Determine scroll position based on where scroll was relative to parent/comment
                    if (old_parent_pos) |parent_pos| {
                        if (old_scroll <= parent_pos) {
                            // Scroll was at or before parent - content at scroll unchanged
                            self.state.global_scroll_offset = old_scroll;
                        } else if (old_scroll <= comment_line) {
                            // Scroll was between parent and comment (or on comment)
                            // Show parent at top (cursor is there anyway)
                            self.state.global_scroll_offset = new_parent_line;
                        } else {
                            // Scroll was AFTER the comment - content shifted up by 1
                            // Reduce scroll by 1 to show same visual content
                            self.state.global_scroll_offset = if (old_scroll > 0) old_scroll - 1 else 0;
                        }
                    } else {
                        // Couldn't find old parent, keep scroll at same position minus 1
                        self.state.global_scroll_offset = if (old_scroll > 0) old_scroll - 1 else 0;
                    }

                    // Clamp to valid range
                    if (self.state.global_scroll_offset >= total_lines) {
                        self.state.global_scroll_offset = total_lines - 1;
                    }
                } else {
                    // Fallback: keep cursor and scroll in valid range
                    self.state.global_cursor_line = @min(self.state.global_cursor_line, total_lines - 1);
                    self.state.global_scroll_offset = @min(old_scroll, total_lines - 1);
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
        // Count comments above the current scroll position (these affect viewport)
        var comments_above_scroll: usize = 0;
        var comments_above_cursor: usize = 0;
        for (self.state.line_map.records) |*record| {
            if (record.line_type == .comment_line) {
                if (record.global_line < self.state.global_scroll_offset) {
                    comments_above_scroll += 1;
                }
                if (record.global_line < self.state.global_cursor_line) {
                    comments_above_cursor += 1;
                }
            }
        }

        self.state.comment_store.clearAll();

        // Rebuild LineMap since comment count changed
        self.state.line_map.deinit();
        self.state.line_map = try line_map.LineMap.build(self.allocator, self.state.files, &self.state.comment_store, self.convertHunkViewMode(), self.shouldApplyHunkFiltering(), &self.state.collapsed_folds);

        // Adjust scroll and cursor to account for removed comments above them
        const total_lines = self.getTotalGlobalLines();
        if (total_lines == 0) {
            self.state.global_scroll_offset = 0;
            self.state.global_cursor_line = 0;
            return;
        }

        // Reduce positions by the number of comments that were above them
        if (self.state.global_scroll_offset >= comments_above_scroll) {
            self.state.global_scroll_offset -= comments_above_scroll;
        } else {
            self.state.global_scroll_offset = 0;
        }

        if (self.state.global_cursor_line >= comments_above_cursor) {
            self.state.global_cursor_line -= comments_above_cursor;
        } else {
            self.state.global_cursor_line = 0;
        }

        // Clamp to valid range
        if (self.state.global_scroll_offset >= total_lines) {
            self.state.global_scroll_offset = total_lines - 1;
        }
        if (self.state.global_cursor_line >= total_lines) {
            self.state.global_cursor_line = total_lines - 1;
        }

        Navigation.clampScrollOffset(self);
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

    /// Open the current agent prompt in the user's $EDITOR for editing.
    /// After the editor closes, the edited content is read back into the input.
    pub fn editAgentPromptInEditor(self: *App) !void {
        const agent_state = self.getActiveAgentState() orelse return;

        // Get current input text
        const input_text = agent_state.input.getText();

        // Generate a unique filename with full path
        const timestamp = std.time.timestamp();
        var path_buf: [256]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "/tmp/skim-prompt-{d}.txt", .{timestamp}) catch {
            std.log.err("Failed to build temp file path", .{});
            return;
        };

        // Create and write the temp file
        const file = std.fs.cwd().createFile(full_path, .{}) catch |err| {
            std.log.err("Failed to create temp file: {any}", .{err});
            return;
        };
        file.writeAll(input_text) catch |err| {
            file.close();
            std.log.err("Failed to write to temp file: {any}", .{err});
            return;
        };
        file.close();

        // Check if editor is terminal-based
        const is_terminal = try editor.isCurrentEditorTerminal(self.allocator);

        if (is_terminal) {
            // Terminal editor: suspend TUI and wait for editor to complete
            const path_copy = try self.allocator.dupe(u8, full_path);
            self.should_suspend_for_editor = true;
            self.editor_file_path = path_copy;
            self.editor_line_number = null;
            self.editor_is_prompt_edit = true;
            // Prevent blocking on next pollEvent() so editor opens immediately
            self.needs_render = true;
        } else {
            // GUI editor: not well suited for prompt editing (no way to know when done)
            // For now, just show a message
            std.log.warn("GUI editors not supported for prompt editing", .{});
            // Clean up the temp file
            std.fs.cwd().deleteFile(full_path) catch {};
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
            .switch_agent => {
                // Disconnect current tab's agent if connected
                if (self.getActiveAcpManager()) |mgr| {
                    mgr.disconnect();
                }
                if (self.tab_manager) |*tm| {
                    if (tm.activeTab()) |tab| {
                        tab.disconnectAll();
                    }
                }
                // Reload agents and show selection
                self.state.configured_agents = self.loadConfiguredAgents();
                self.state.agent_selection_idx = 0;
                self.mode = .agent_selection;
            },
            .select_commit => {
                try self.startCommitSelection();
            },
        }
    }

    pub fn startBranchSelection(self: *App) !void {
        // Disabled in pager mode
        if (self.state.pager_mode) return;

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

    // =========================================================================
    // Commit Selection
    // =========================================================================

    const COMMIT_BATCH_SIZE: usize = 50;

    pub fn startCommitSelection(self: *App) !void {
        // Disabled in pager mode
        if (self.state.pager_mode) return;

        // Free old commit list
        for (self.state.commit_list.items) |*commit| {
            commit.deinit(self.allocator);
        }
        self.state.commit_list.clearRetainingCapacity();

        // Reset state
        self.state.commit_selection = 0;
        self.state.commit_search_len = 0;
        self.state.commits_loaded_count = 0;
        self.state.commits_loading = false;

        // Load first batch of commits
        try self.loadMoreCommits();

        // Initialize filtered list
        try self.filterCommits();

        self.mode = .commit_selection;
    }

    pub fn loadMoreCommits(self: *App) !void {
        if (self.state.commits_loading) return;

        self.state.commits_loading = true;
        defer self.state.commits_loading = false;

        const new_commits = git.getCommits(self.allocator, self.state.commits_loaded_count, COMMIT_BATCH_SIZE) catch |err| {
            std.log.err("Failed to load commits: {}", .{err});
            return;
        };
        errdefer {
            for (new_commits) |*c| c.deinit(self.allocator);
            self.allocator.free(new_commits);
        }

        // Append to commit list
        for (new_commits) |commit| {
            try self.state.commit_list.append(self.allocator, commit);
        }
        self.allocator.free(new_commits);

        self.state.commits_loaded_count += COMMIT_BATCH_SIZE;

        // Update filtered list
        try self.filterCommits();
    }

    pub fn filterCommits(self: *App) !void {
        self.state.filtered_commits.clearRetainingCapacity();

        const query = self.state.commit_search_query[0..self.state.commit_search_len];

        // If no query, show all commits
        if (query.len == 0) {
            for (self.state.commit_list.items, 0..) |_, idx| {
                try self.state.filtered_commits.append(self.allocator, idx);
            }
        } else {
            // Filter by hash, subject, author (case-insensitive)
            for (self.state.commit_list.items, 0..) |commit, idx| {
                if (self.matchesCommitQuery(commit, query)) {
                    try self.state.filtered_commits.append(self.allocator, idx);
                }
            }
        }

        // Clamp selection to filtered list
        if (self.state.filtered_commits.items.len > 0 and self.state.commit_selection >= self.state.filtered_commits.items.len) {
            self.state.commit_selection = self.state.filtered_commits.items.len - 1;
        }
    }

    fn matchesCommitQuery(self: *App, commit: git.CommitInfo, query: []const u8) bool {
        _ = self;
        // Case-insensitive substring match on hash, subject, author
        return containsIgnoreCase(commit.hash, query) or
            containsIgnoreCase(commit.short_hash, query) or
            containsIgnoreCase(commit.subject, query) or
            containsIgnoreCase(commit.author, query);
    }

    /// Select a commit and show diff mode submenu
    pub fn selectCommitForDiff(self: *App) !void {
        const filtered_count = self.state.filtered_commits.items.len;
        if (filtered_count == 0) return;

        const filtered_idx = self.state.filtered_commits.items[self.state.commit_selection];
        const commit = self.state.commit_list.items[filtered_idx];

        // Free any existing selected commit
        if (self.state.selected_commit_for_diff) |*old_commit| {
            old_commit.deinit(self.allocator);
        }

        // Make a copy of the selected commit
        self.state.selected_commit_for_diff = .{
            .hash = try self.allocator.dupe(u8, commit.hash),
            .short_hash = try self.allocator.dupe(u8, commit.short_hash),
            .subject = try self.allocator.dupe(u8, commit.subject),
            .author = try self.allocator.dupe(u8, commit.author),
            .date = try self.allocator.dupe(u8, commit.date),
        };

        self.state.commit_diff_mode_selection = 0;
        self.mode = .commit_diff_mode;
    }

    /// Apply the selected diff mode with the chosen commit
    pub fn applyCommitDiff(self: *App) !void {
        const commit = self.state.selected_commit_for_diff orelse return;

        // Free old diff_source if needed
        switch (self.state.diff_source) {
            .working_dir, .stdin => {},
            .single_ref => |sr| {
                self.allocator.free(sr.ref);
            },
            .two_refs => |tr| {
                self.allocator.free(tr.ref1);
                self.allocator.free(tr.ref2);
            },
        }

        if (self.state.commit_diff_mode_selection == 0) {
            // Option 0: HEAD vs selected commit (changes from commit to HEAD)
            const commit_ref = try self.allocator.dupe(u8, commit.hash);
            errdefer self.allocator.free(commit_ref);

            const head_ref = try self.allocator.dupe(u8, "HEAD");

            self.state.diff_source = .{ .two_refs = .{
                .ref1 = commit_ref,
                .ref2 = head_ref,
                .use_merge_base = false,
            } };
        } else {
            // Option 1: commit vs its parent (commit's own changes)
            var parent_buf: [64]u8 = undefined;
            const parent_ref = try std.fmt.bufPrint(&parent_buf, "{s}^", .{commit.hash});

            const commit_ref = try self.allocator.dupe(u8, commit.hash);
            errdefer self.allocator.free(commit_ref);

            const parent_copy = try self.allocator.dupe(u8, parent_ref);

            self.state.diff_source = .{ .two_refs = .{
                .ref1 = parent_copy,
                .ref2 = commit_ref,
                .use_merge_base = false,
            } };
        }

        // Free the selected commit
        if (self.state.selected_commit_for_diff) |*c| {
            c.deinit(self.allocator);
            self.state.selected_commit_for_diff = null;
        }

        // Go back to normal mode and refresh
        self.mode = .normal;
        try self.refresh();
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

    // Subagent modal fetch

    /// Start async fetch of subagent session messages for the drill-in modal.
    /// Opens the modal in loading state and spawns a background thread.
    pub fn startSubagentModalFetch(self: *App, session_id: []const u8, title: []const u8) void {
        const agent_state = self.getActiveAgentState() orelse return;

        // Get base_url from the active opencode manager
        const mgr = self.getActiveOpencodeManager() orelse return;
        const base_url = mgr.base_url orelse return;

        // Open modal in loading state
        agent_state.openSubagentModal(session_id, title) catch |err| {
            std.log.err("Failed to open subagent modal: {}", .{err});
            return;
        };

        // Create context for the fetch thread
        // Use c_allocator since the worker thread frees with c_allocator
        const ctx = std.heap.c_allocator.create(SubagentFetchContext) catch return;
        ctx.* = .{
            .app = self,
            .base_url = std.heap.c_allocator.dupe(u8, base_url) catch {
                std.heap.c_allocator.destroy(ctx);
                return;
            },
            .session_id = std.heap.c_allocator.dupe(u8, session_id) catch {
                std.heap.c_allocator.free(ctx.base_url);
                std.heap.c_allocator.destroy(ctx);
                return;
            },
        };

        const thread = std.Thread.spawn(.{}, subagentFetchWorker, .{ctx}) catch {
            // On thread spawn failure, show error in modal
            if (agent_state.getSubagentModal()) |modal| {
                modal.loading = false;
                modal.error_message = self.allocator.dupe(u8, "Failed to start fetch thread") catch null;
            }
            ctx.deinit(std.heap.c_allocator);
            std.heap.c_allocator.destroy(ctx);
            return;
        };
        thread.detach();

        self.needs_render = true;
    }

    /// Worker thread that fetches subagent session messages.
    /// Stores result in pending_subagent_fetch for main-thread processing (avoids data race).
    fn subagentFetchWorker(ctx: *SubagentFetchContext) void {
        const app = ctx.app;
        const pending = &app.pending_subagent_fetch;

        // Create a temporary client for the fetch
        var client = opencode.Client.init(std.heap.c_allocator, ctx.base_url) catch {
            pending.mutex.lock();
            pending.error_message = "Failed to connect to server";
            pending.mutex.unlock();
            pending.ready.store(true, .release);
            app.needs_render = true;
            ctx.deinit(std.heap.c_allocator);
            std.heap.c_allocator.destroy(ctx);
            return;
        };
        defer client.deinit();

        const modal_messages = client.fetchSessionMessages(ctx.session_id) catch |err| {
            const err_msg: []const u8 = switch (err) {
                error.SessionNotFound => "Session not found",
                error.ConnectionFailed => "Connection failed",
                error.ServerError => "Server error",
                error.InvalidResponse => "Invalid response from server",
                else => "Failed to fetch messages",
            };
            std.log.err("Subagent fetch failed: {s} ({})", .{ err_msg, err });
            pending.mutex.lock();
            pending.error_message = err_msg;
            pending.mutex.unlock();
            pending.ready.store(true, .release);
            app.needs_render = true;
            ctx.deinit(std.heap.c_allocator);
            std.heap.c_allocator.destroy(ctx);
            return;
        };

        pending.mutex.lock();
        pending.messages = modal_messages;
        pending.mutex.unlock();
        pending.ready.store(true, .release);
        app.needs_render = true;
        ctx.deinit(std.heap.c_allocator);
        std.heap.c_allocator.destroy(ctx);
    }

    /// Poll for completed subagent fetch and process on main thread.
    /// This avoids the data race of modifying modal.messages from the worker thread.
    fn pollSubagentFetch(self: *App) void {
        if (!self.pending_subagent_fetch.ready.load(.acquire)) return;

        // Take pending data under mutex
        self.pending_subagent_fetch.mutex.lock();
        const messages = self.pending_subagent_fetch.messages;
        const err_msg = self.pending_subagent_fetch.error_message;
        self.pending_subagent_fetch.messages = null;
        self.pending_subagent_fetch.error_message = null;
        self.pending_subagent_fetch.mutex.unlock();
        self.pending_subagent_fetch.ready.store(false, .release);

        processSubagentFetchResult(self, messages, err_msg);
    }

    /// Process fetched subagent messages on the main thread (safe to modify modal state).
    fn processSubagentFetchResult(app: *App, modal_messages: ?[]opencode.Client.ModalMessage, err_msg: ?[]const u8) void {
        const agent_state = app.getActiveAgentState() orelse {
            // Modal was closed while fetch was in progress — free the messages
            if (modal_messages) |msgs| {
                for (msgs) |*m| m.deinit(std.heap.c_allocator);
                std.heap.c_allocator.free(msgs);
            }
            return;
        };

        const modal = agent_state.getSubagentModal() orelse {
            if (modal_messages) |msgs| {
                for (msgs) |*m| m.deinit(std.heap.c_allocator);
                std.heap.c_allocator.free(msgs);
            }
            return;
        };

        modal.loading = false;

        if (err_msg) |msg| {
            modal.error_message = agent_state.allocator.dupe(u8, msg) catch null;
        } else if (modal_messages) |msgs| {
            // Convert ModalMessages to Messages for ChatLineMap rendering
            for (msgs) |*m| {
                const alloc = agent_state.allocator;
                switch (m.role) {
                    .user => {
                        const content = if (m.content) |c| (alloc.dupe(u8, c) catch "") else "";
                        modal.messages.append(alloc, .{
                            .role = .user,
                            .content = content,
                            .timestamp = 0,
                        }) catch {};
                    },
                    .assistant => {
                        const content = if (m.content) |c| (alloc.dupe(u8, c) catch "") else "";
                        modal.messages.append(alloc, .{
                            .role = .agent,
                            .content = content,
                            .timestamp = 0,
                        }) catch {};
                    },
                    .tool => {
                        const display = m.tool_title orelse m.tool_name orelse "Tool";
                        const content = alloc.dupe(u8, display) catch "";
                        const duped_name = if (m.tool_name) |n| (alloc.dupe(u8, n) catch null) else null;
                        modal.messages.append(alloc, .{
                            .role = .tool,
                            .content = content,
                            .tool_name = duped_name,
                            .tool_status = .completed,
                            .timestamp = 0,
                        }) catch {};
                    },
                }

                // Free the originals (owned by c_allocator)
                m.deinit(std.heap.c_allocator);
            }
            std.heap.c_allocator.free(msgs);
            modal.line_map_dirty = true;
        }

        app.needs_render = true;
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
        // Disabled in pager mode
        if (self.state.pager_mode) return;

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
            .working_dir, .stdin => {},
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
        // Disabled in pager mode
        if (self.state.pager_mode) return;

        // Free old diff_source if needed
        switch (self.state.diff_source) {
            .working_dir, .stdin => {},
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

    // Check if a file is folded (collapsed)
    pub fn isFileFolded(self: *App, file_idx: usize) bool {
        return self.state.collapsed_folds.contains(FoldKey.fileKey(file_idx));
    }

    // Check if a hunk is folded (collapsed)
    pub fn isHunkFolded(self: *App, file_idx: usize, hunk_idx: usize) bool {
        // If file is folded, hunk is implicitly folded
        if (self.isFileFolded(file_idx)) return true;
        return self.state.collapsed_folds.contains(FoldKey.hunkKey(file_idx, hunk_idx));
    }

    // Toggle file fold state
    pub fn toggleFileFold(self: *App, file_idx: usize) void {
        const key = FoldKey.fileKey(file_idx);
        if (self.state.collapsed_folds.contains(key)) {
            _ = self.state.collapsed_folds.remove(key);
        } else {
            self.state.collapsed_folds.put(key, {}) catch {};
        }
    }

    // Toggle hunk fold state
    pub fn toggleHunkFold(self: *App, file_idx: usize, hunk_idx: usize) void {
        const key = FoldKey.hunkKey(file_idx, hunk_idx);
        if (self.state.collapsed_folds.contains(key)) {
            _ = self.state.collapsed_folds.remove(key);
        } else {
            self.state.collapsed_folds.put(key, {}) catch {};
        }
    }

    // Close (fold) a file
    pub fn closeFileFold(self: *App, file_idx: usize) void {
        self.state.collapsed_folds.put(FoldKey.fileKey(file_idx), {}) catch {};
    }

    // Close (fold) a hunk
    pub fn closeHunkFold(self: *App, file_idx: usize, hunk_idx: usize) void {
        self.state.collapsed_folds.put(FoldKey.hunkKey(file_idx, hunk_idx), {}) catch {};
    }

    // Open (unfold) a file
    pub fn openFileFold(self: *App, file_idx: usize) void {
        _ = self.state.collapsed_folds.remove(FoldKey.fileKey(file_idx));
    }

    // Open (unfold) a hunk
    pub fn openHunkFold(self: *App, file_idx: usize, hunk_idx: usize) void {
        _ = self.state.collapsed_folds.remove(FoldKey.hunkKey(file_idx, hunk_idx));
    }

    // Close all folds (fold all files and hunks)
    pub fn closeAllFolds(self: *App) void {
        for (self.state.files, 0..) |file, file_idx| {
            self.state.collapsed_folds.put(FoldKey.fileKey(file_idx), {}) catch {};
            for (file.hunks, 0..) |_, hunk_idx| {
                self.state.collapsed_folds.put(FoldKey.hunkKey(file_idx, hunk_idx), {}) catch {};
            }
        }
    }

    // Open all folds (unfold everything)
    pub fn openAllFolds(self: *App) void {
        self.state.collapsed_folds.clearRetainingCapacity();
    }

    // Count total lines in a hunk (for fold indicator)
    pub fn getHunkLineCount(self: *App, file_idx: usize, hunk_idx: usize) usize {
        if (file_idx >= self.state.files.len) return 0;
        const file = &self.state.files[file_idx];
        if (hunk_idx >= file.hunks.len) return 0;
        return file.hunks[hunk_idx].lines.len;
    }

    // Count total lines in a file (for fold indicator)
    pub fn getFileLineCount(self: *App, file_idx: usize) usize {
        if (file_idx >= self.state.file_line_counts.len) return 0;
        return self.state.file_line_counts[file_idx];
    }

    pub fn getFileDiffStats(self: *App, file_idx: usize) StateHelpers.FileDiffStats {
        if (file_idx >= self.state.file_diff_stats.len) {
            return .{ .additions = 0, .deletions = 0 };
        }
        return self.state.file_diff_stats[file_idx];
    }

    pub fn getGlobalGutterWidth(self: *App, show_blame: bool) usize {
        const base_width = self.state.global_gutter_width;
        if (show_blame) {
            return base_width + StateHelpers.BLAME_GUTTER_WIDTH + StateHelpers.BLAME_SEPARATOR_WIDTH;
        }
        return base_width;
    }

    pub fn frameSegmentAllocator(self: *App) std.mem.Allocator {
        return self.frame_segment_arena.allocator();
    }

    pub fn resetFrameAllocators(self: *App) void {
        RenderUtils.resetFrameTextBuffer(self);
        _ = self.frame_segment_arena.reset(.retain_capacity);
    }

    fn freeFileCaches(self: *App) void {
        self.allocator.free(self.state.file_diff_stats);
        self.allocator.free(self.state.file_line_counts);
    }

    pub fn profileSliceByDisplayWidth(self: *App, text: []const u8, max_width: usize) []const u8 {
        if (profiling_enabled) {
            if (!self.profile_active_frame) {
                return RenderUtils.sliceByDisplayWidth(text, max_width);
            }
            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
            const slice = RenderUtils.sliceByDisplayWidth(text, max_width);
            if (timer_opt) |*timer| {
                self.profile_counters.slice_ns += timer.read();
            }
            self.profile_counters.slice_calls += 1;
            return slice;
        }

        return RenderUtils.sliceByDisplayWidth(text, max_width);
    }

    pub fn profilePadSegments(
        self: *App,
        segments: []vaxis.Cell.Segment,
        current_width: usize,
        available_width: usize,
        style: vaxis.Style,
    ) ![]vaxis.Cell.Segment {
        const allocator = self.frameSegmentAllocator();
        if (profiling_enabled) {
            if (!self.profile_active_frame) {
                return RenderUtils.padSegments(self, allocator, segments, current_width, available_width, style);
            }
            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
            const padded = try RenderUtils.padSegments(self, allocator, segments, current_width, available_width, style);
            if (timer_opt) |*timer| {
                self.profile_counters.pad_ns += timer.read();
            }
            self.profile_counters.pad_calls += 1;
            return padded;
        }

        return RenderUtils.padSegments(self, allocator, segments, current_width, available_width, style);
    }

    pub fn profileRenderGutterWithBlame(
        self: *App,
        win: vaxis.Window,
        line_idx: usize,
        row: usize,
        is_cursor_or_visual: bool,
        show_number: bool,
        file_lineno: ?u32,
        line_type: ?parser.Line.LineType,
        gutter_width: usize,
        file_path: ?[]const u8,
        is_first_line_in_hunk: bool,
    ) !void {
        if (profiling_enabled) {
            if (!self.profile_active_frame) {
                return RenderUtils.renderGutterWithBlame(self, win, line_idx, row, is_cursor_or_visual, show_number, file_lineno, line_type, gutter_width, file_path, is_first_line_in_hunk);
            }
            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
            try RenderUtils.renderGutterWithBlame(self, win, line_idx, row, is_cursor_or_visual, show_number, file_lineno, line_type, gutter_width, file_path, is_first_line_in_hunk);
            if (timer_opt) |*timer| {
                self.profile_counters.gutter_ns += timer.read();
            }
            self.profile_counters.gutter_calls += 1;
            return;
        }

        return RenderUtils.renderGutterWithBlame(self, win, line_idx, row, is_cursor_or_visual, show_number, file_lineno, line_type, gutter_width, file_path, is_first_line_in_hunk);
    }

    // Toggle fold at cursor position (file header -> fold file, hunk/code -> fold hunk)
    pub fn toggleFoldUnderCursor(self: *App) !void {
        const record = self.state.line_map.getLineRecord(self.state.global_cursor_line) orelse return;
        const file_idx = record.file_idx;

        // Track which fold was toggled for cursor positioning
        var target_hunk_idx: ?usize = null;

        switch (record.line_type) {
            .file_header => {
                self.toggleFileFold(file_idx);
            },
            .hunk_header => |hunk_info| {
                self.toggleHunkFold(file_idx, hunk_info.hunk_idx);
                target_hunk_idx = hunk_info.hunk_idx;
            },
            .code_line => |code_info| {
                self.toggleHunkFold(file_idx, code_info.hunk_idx);
                target_hunk_idx = code_info.hunk_idx;
            },
            .comment_line => |comment_info| {
                self.toggleHunkFold(file_idx, comment_info.parent_hunk_idx);
                target_hunk_idx = comment_info.parent_hunk_idx;
            },
            .spacer => {
                // On spacer, no fold action
                return;
            },
        }

        // Rebuild LineMap and move cursor to fold header
        self.state.line_map.deinit();
        self.state.line_map = try line_map.LineMap.build(self.allocator, self.state.files, &self.state.comment_store, self.convertHunkViewMode(), self.shouldApplyHunkFiltering(), &self.state.collapsed_folds);
        self.moveCursorToFoldHeader(file_idx, target_hunk_idx);
        self.needs_render = true;
    }

    // Close fold at cursor position
    pub fn closeFoldUnderCursor(self: *App) !void {
        const record = self.state.line_map.getLineRecord(self.state.global_cursor_line) orelse return;
        const file_idx = record.file_idx;

        // Track which fold was closed for cursor positioning
        var target_hunk_idx: ?usize = null;

        switch (record.line_type) {
            .file_header => {
                self.closeFileFold(file_idx);
            },
            .hunk_header => |hunk_info| {
                self.closeHunkFold(file_idx, hunk_info.hunk_idx);
                target_hunk_idx = hunk_info.hunk_idx;
            },
            .code_line => |code_info| {
                self.closeHunkFold(file_idx, code_info.hunk_idx);
                target_hunk_idx = code_info.hunk_idx;
            },
            .comment_line => |comment_info| {
                self.closeHunkFold(file_idx, comment_info.parent_hunk_idx);
                target_hunk_idx = comment_info.parent_hunk_idx;
            },
            .spacer => {
                return;
            },
        }

        // Rebuild LineMap and move cursor to fold header
        self.state.line_map.deinit();
        self.state.line_map = try line_map.LineMap.build(self.allocator, self.state.files, &self.state.comment_store, self.convertHunkViewMode(), self.shouldApplyHunkFiltering(), &self.state.collapsed_folds);
        self.moveCursorToFoldHeader(file_idx, target_hunk_idx);
        self.needs_render = true;
    }

    // Open fold at cursor position
    pub fn openFoldUnderCursor(self: *App) !void {
        const record = self.state.line_map.getLineRecord(self.state.global_cursor_line) orelse return;
        const file_idx = record.file_idx;

        // Track which fold was opened for cursor positioning
        var target_hunk_idx: ?usize = null;

        switch (record.line_type) {
            .file_header => {
                self.openFileFold(file_idx);
            },
            .hunk_header => |hunk_info| {
                self.openHunkFold(file_idx, hunk_info.hunk_idx);
                target_hunk_idx = hunk_info.hunk_idx;
            },
            .code_line => |code_info| {
                self.openHunkFold(file_idx, code_info.hunk_idx);
                target_hunk_idx = code_info.hunk_idx;
            },
            .comment_line => |comment_info| {
                self.openHunkFold(file_idx, comment_info.parent_hunk_idx);
                target_hunk_idx = comment_info.parent_hunk_idx;
            },
            .spacer => {
                return;
            },
        }

        // Rebuild LineMap and move cursor to fold header
        self.state.line_map.deinit();
        self.state.line_map = try line_map.LineMap.build(self.allocator, self.state.files, &self.state.comment_store, self.convertHunkViewMode(), self.shouldApplyHunkFiltering(), &self.state.collapsed_folds);
        self.moveCursorToFoldHeader(file_idx, target_hunk_idx);
        self.needs_render = true;
    }

    // Close all folds and rebuild LineMap
    pub fn closeAllFoldsAndRebuild(self: *App) !void {
        // Capture anchor before closing all
        const anchor = self.captureViewportAnchor(self.state.global_cursor_line);

        self.closeAllFolds();

        // Rebuild LineMap
        self.state.line_map.deinit();
        self.state.line_map = try line_map.LineMap.build(self.allocator, self.state.files, &self.state.comment_store, self.convertHunkViewMode(), self.shouldApplyHunkFiltering(), &self.state.collapsed_folds);
        _ = self.restoreViewportFromAnchor(anchor);
        self.needs_render = true;
    }

    // Open all folds and rebuild LineMap
    pub fn openAllFoldsAndRebuild(self: *App) !void {
        // Capture anchor before opening all
        const anchor = self.captureViewportAnchor(self.state.global_cursor_line);

        self.openAllFolds();

        // Rebuild LineMap
        self.state.line_map.deinit();
        self.state.line_map = try line_map.LineMap.build(self.allocator, self.state.files, &self.state.comment_store, self.convertHunkViewMode(), self.shouldApplyHunkFiltering(), &self.state.collapsed_folds);
        _ = self.restoreViewportFromAnchor(anchor);
        self.needs_render = true;
    }

    // Move cursor to the fold header (file or hunk) after folding
    fn moveCursorToFoldHeader(self: *App, file_idx: usize, hunk_idx: ?usize) void {
        // Search for the header line in the rebuilt LineMap
        for (0..self.state.line_map.records.len) |line_idx| {
            const record = self.state.line_map.getLineRecord(line_idx) orelse continue;
            if (record.file_idx != file_idx) continue;

            if (hunk_idx) |h_idx| {
                // Looking for hunk header
                switch (record.line_type) {
                    .hunk_header => |hunk_info| {
                        if (hunk_info.hunk_idx == h_idx) {
                            self.state.global_cursor_line = line_idx;
                            Navigation.ensureCursorVisible(self, true);
                            return;
                        }
                    },
                    else => {},
                }
            } else {
                // Looking for file header
                switch (record.line_type) {
                    .file_header => {
                        self.state.global_cursor_line = line_idx;
                        Navigation.ensureCursorVisible(self, true);
                        return;
                    },
                    else => {},
                }
            }
        }
    }

    // Close the file containing the cursor (zC - fold entire file from anywhere)
    pub fn closeFileFoldUnderCursor(self: *App) !void {
        const record = self.state.line_map.getLineRecord(self.state.global_cursor_line) orelse return;
        const file_idx = record.file_idx;

        // Close the file fold
        self.closeFileFold(file_idx);

        // Rebuild LineMap
        self.state.line_map.deinit();
        self.state.line_map = try line_map.LineMap.build(self.allocator, self.state.files, &self.state.comment_store, self.convertHunkViewMode(), self.shouldApplyHunkFiltering(), &self.state.collapsed_folds);

        // Move cursor to the file header
        self.moveCursorToFoldHeader(file_idx, null);
        self.needs_render = true;
    }

    // Open the file containing the cursor (zO - unfold entire file from anywhere)
    pub fn openFileFoldUnderCursor(self: *App) !void {
        const record = self.state.line_map.getLineRecord(self.state.global_cursor_line) orelse return;
        const file_idx = record.file_idx;

        // Open the file fold
        self.openFileFold(file_idx);

        // Rebuild LineMap
        self.state.line_map.deinit();
        self.state.line_map = try line_map.LineMap.build(self.allocator, self.state.files, &self.state.comment_store, self.convertHunkViewMode(), self.shouldApplyHunkFiltering(), &self.state.collapsed_folds);

        // Move cursor to the file header
        self.moveCursorToFoldHeader(file_idx, null);
        self.needs_render = true;
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
        const profile_frame = if (profiling_enabled) self.profile_active_frame else false;
        var total_timer_opt: ?std.time.Timer = if (profile_frame) std.time.Timer.start() catch null else null;
        var header_ns: u64 = 0;
        var content_ns: u64 = 0;
        var status_ns: u64 = 0;
        var agent_ns: u64 = 0;
        var overlay_ns: u64 = 0;
        if (profile_frame) {
            self.profile_counters = .{};
        }

        win.clear();
        self.resetFrameAllocators();

        // Hide cursor by default - comment input will show it when needed
        win.hideCursor();

        // Content height without dividers (continuous mode)
        const content_height = win.height - Layout.header_height - Layout.status_height;

        // Check if agent panel should be shown (visible and not full-screen)
        // Don't show when in agent_selection mode (selecting which agent to connect to)
        const show_agent_panel = self.isAgentPanelVisible() and !self.isAgentFullScreen() and self.mode != .agent_selection;

        // Render header and content (or empty/branch menu if no files)
        if (self.state.files.len == 0) {
            // No files - show empty state or branch selection menu
            // If agent panel is visible, render it as sidebar with empty menu in main area
            if (show_agent_panel) {
                const panel_side = self.getAgentPanelSide();
                const panel_width = win.width * 3 / 10; // 30% for agent panel
                const diff_width = win.width - panel_width;

                if (panel_side == .left) {
                    // Agent panel on left
                    const agent_win = win.child(.{
                        .x_off = 0,
                        .y_off = Layout.header_height,
                        .width = @intCast(panel_width),
                        .height = @intCast(content_height),
                    });
                    if (profile_frame) {
                        var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try agent.renderAgentPanel(self, agent_win);
                        if (timer_opt) |*timer| agent_ns += timer.read();
                    } else {
                        try agent.renderAgentPanel(self, agent_win);
                    }

                    // Empty menu on right
                    const content_win = win.child(.{
                        .x_off = @intCast(panel_width),
                        .y_off = 0,
                        .width = @intCast(diff_width),
                        .height = @intCast(win.height),
                    });
                    if (self.mode == .branch_selection) {
                        if (profile_frame) {
                            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                            try UI.renderBranchSelectionMenu(self, content_win);
                            if (timer_opt) |*timer| overlay_ns += timer.read();
                        } else {
                            try UI.renderBranchSelectionMenu(self, content_win);
                        }
                    } else if (self.mode == .commit_selection) {
                        if (profile_frame) {
                            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                            try UI.renderCommitSelectionMenu(self, content_win);
                            if (timer_opt) |*timer| overlay_ns += timer.read();
                        } else {
                            try UI.renderCommitSelectionMenu(self, content_win);
                        }
                    } else if (self.mode == .commit_diff_mode) {
                        if (profile_frame) {
                            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                            try UI.renderCommitSelectionMenu(self, content_win);
                            if (timer_opt) |*timer| overlay_ns += timer.read();
                            timer_opt = std.time.Timer.start() catch null;
                            try UI.renderCommitDiffModeMenu(self, content_win);
                            if (timer_opt) |*timer| overlay_ns += timer.read();
                        } else {
                            try UI.renderCommitSelectionMenu(self, content_win);
                            try UI.renderCommitDiffModeMenu(self, content_win);
                        }
                    } else {
                        if (profile_frame) {
                            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                            try UI.renderEmptyMenu(self, content_win);
                            if (timer_opt) |*timer| overlay_ns += timer.read();
                        } else {
                            try UI.renderEmptyMenu(self, content_win);
                        }
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
                        if (profile_frame) {
                            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                            try UI.renderBranchSelectionMenu(self, content_win);
                            if (timer_opt) |*timer| overlay_ns += timer.read();
                        } else {
                            try UI.renderBranchSelectionMenu(self, content_win);
                        }
                    } else if (self.mode == .commit_selection) {
                        if (profile_frame) {
                            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                            try UI.renderCommitSelectionMenu(self, content_win);
                            if (timer_opt) |*timer| overlay_ns += timer.read();
                        } else {
                            try UI.renderCommitSelectionMenu(self, content_win);
                        }
                    } else if (self.mode == .commit_diff_mode) {
                        if (profile_frame) {
                            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                            try UI.renderCommitSelectionMenu(self, content_win);
                            if (timer_opt) |*timer| overlay_ns += timer.read();
                            timer_opt = std.time.Timer.start() catch null;
                            try UI.renderCommitDiffModeMenu(self, content_win);
                            if (timer_opt) |*timer| overlay_ns += timer.read();
                        } else {
                            try UI.renderCommitSelectionMenu(self, content_win);
                            try UI.renderCommitDiffModeMenu(self, content_win);
                        }
                    } else {
                        if (profile_frame) {
                            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                            try UI.renderEmptyMenu(self, content_win);
                            if (timer_opt) |*timer| overlay_ns += timer.read();
                        } else {
                            try UI.renderEmptyMenu(self, content_win);
                        }
                    }

                    // Agent panel on right
                    const agent_win = win.child(.{
                        .x_off = @intCast(diff_width),
                        .y_off = Layout.header_height,
                        .width = @intCast(panel_width),
                        .height = @intCast(content_height),
                    });
                    if (profile_frame) {
                        var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try agent.renderAgentPanel(self, agent_win);
                        if (timer_opt) |*timer| agent_ns += timer.read();
                    } else {
                        try agent.renderAgentPanel(self, agent_win);
                    }
                }
            } else {
                // No agent panel - full screen empty menu
                if (self.mode == .branch_selection) {
                    if (profile_frame) {
                        var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try UI.renderBranchSelectionMenu(self, win);
                        if (timer_opt) |*timer| overlay_ns += timer.read();
                    } else {
                        try UI.renderBranchSelectionMenu(self, win);
                    }
                } else if (self.mode == .commit_selection) {
                    if (profile_frame) {
                        var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try UI.renderCommitSelectionMenu(self, win);
                        if (timer_opt) |*timer| overlay_ns += timer.read();
                    } else {
                        try UI.renderCommitSelectionMenu(self, win);
                    }
                } else if (self.mode == .commit_diff_mode) {
                    if (profile_frame) {
                        var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try UI.renderCommitSelectionMenu(self, win);
                        if (timer_opt) |*timer| overlay_ns += timer.read();
                        timer_opt = std.time.Timer.start() catch null;
                        try UI.renderCommitDiffModeMenu(self, win);
                        if (timer_opt) |*timer| overlay_ns += timer.read();
                    } else {
                        try UI.renderCommitSelectionMenu(self, win);
                        try UI.renderCommitDiffModeMenu(self, win);
                    }
                } else {
                    if (profile_frame) {
                        var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try UI.renderEmptyMenu(self, win);
                        if (timer_opt) |*timer| overlay_ns += timer.read();
                    } else {
                        try UI.renderEmptyMenu(self, win);
                    }
                }
            }
        } else {
            // Normal rendering with header, content, and status bar
            // Split content area based on panels
            if (show_agent_panel) {
                const panel_side = self.getAgentPanelSide();
                const panel_width = win.width * 3 / 10; // 30% for agent panel
                const diff_width = win.width - panel_width;

                if (panel_side == .left) {
                    // Agent panel on left (starts at y=0, full height including header area)
                    const agent_win = win.child(.{
                        .x_off = 0,
                        .y_off = 0,
                        .width = @intCast(panel_width),
                        .height = @intCast(content_height + Layout.header_height),
                    });
                    if (profile_frame) {
                        var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try agent.renderAgentPanel(self, agent_win);
                        if (timer_opt) |*timer| agent_ns += timer.read();
                    } else {
                        try agent.renderAgentPanel(self, agent_win);
                    }

                    // Header above diff content (on right side)
                    const header_win = win.child(.{
                        .x_off = @intCast(panel_width),
                        .y_off = 0,
                        .width = @intCast(diff_width),
                        .height = @intCast(Layout.header_height),
                    });
                    if (profile_frame) {
                        var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try UI.renderHeader(self, header_win);
                        if (timer_opt) |*timer| header_ns += timer.read();
                    } else {
                        try UI.renderHeader(self, header_win);
                    }

                    // Diff content on right (below header)
                    const content_win = win.child(.{
                        .x_off = @intCast(panel_width),
                        .y_off = Layout.header_height,
                        .width = @intCast(diff_width),
                        .height = @intCast(content_height),
                    });
                    if (profile_frame) {
                        var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try self.renderContent(content_win);
                        if (timer_opt) |*timer| content_ns += timer.read();
                    } else {
                        try self.renderContent(content_win);
                    }
                } else {
                    // Agent panel on right (default)
                    // Header above diff content (on left side)
                    const header_win = win.child(.{
                        .x_off = 0,
                        .y_off = 0,
                        .width = @intCast(diff_width),
                        .height = @intCast(Layout.header_height),
                    });
                    if (profile_frame) {
                        var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try UI.renderHeader(self, header_win);
                        if (timer_opt) |*timer| header_ns += timer.read();
                    } else {
                        try UI.renderHeader(self, header_win);
                    }

                    // Diff content on left (below header)
                    const content_win = win.child(.{
                        .x_off = 0,
                        .y_off = Layout.header_height,
                        .width = @intCast(diff_width),
                        .height = @intCast(content_height),
                    });
                    if (profile_frame) {
                        var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try self.renderContent(content_win);
                        if (timer_opt) |*timer| content_ns += timer.read();
                    } else {
                        try self.renderContent(content_win);
                    }

                    // Agent panel on right (starts at y=0, full height including header area)
                    const agent_win = win.child(.{
                        .x_off = @intCast(diff_width),
                        .y_off = 0,
                        .width = @intCast(panel_width),
                        .height = @intCast(content_height + Layout.header_height),
                    });
                    if (profile_frame) {
                        var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try agent.renderAgentPanel(self, agent_win);
                        if (timer_opt) |*timer| agent_ns += timer.read();
                    } else {
                        try agent.renderAgentPanel(self, agent_win);
                    }
                }
            } else {
                // Full width - header spans full width
                const header_win = win.child(.{
                    .x_off = 0,
                    .y_off = 0,
                    .width = @intCast(win.width),
                    .height = @intCast(Layout.header_height),
                });
                if (profile_frame) {
                    var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                    try UI.renderHeader(self, header_win);
                    if (timer_opt) |*timer| header_ns += timer.read();
                } else {
                    try UI.renderHeader(self, header_win);
                }
                // Full width content
                const content_win = win.child(.{
                    .x_off = 0,
                    .y_off = Layout.header_height,
                    .width = @intCast(win.width),
                    .height = @intCast(content_height),
                });
                if (profile_frame) {
                    var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                    try self.renderContent(content_win);
                    if (timer_opt) |*timer| content_ns += timer.read();
                } else {
                    try self.renderContent(content_win);
                }
            }
        }

        // Render unified status bar (handles both diff mode and agent mode content)
        // This is outside the files check so it renders even when there are no files
        const status_win = win.child(.{
            .x_off = 0,
            .y_off = win.height - Layout.status_height,
            .width = @intCast(win.width),
            .height = @intCast(Layout.status_height),
        });
        if (profile_frame) {
            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
            try UI.renderStatus(self, status_win);
            if (timer_opt) |*timer| status_ns += timer.read();
        } else {
            try UI.renderStatus(self, status_win);
        }

        // Render command palette overlay if in command palette mode
        if (self.mode == .command_palette) {
            if (profile_frame) {
                var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                try command_palette.renderCommandPalette(self, win);
                if (timer_opt) |*timer| overlay_ns += timer.read();
            } else {
                try command_palette.renderCommandPalette(self, win);
            }
        }

        // Render help overlay if in help mode
        if (self.mode == .help) {
            if (profile_frame) {
                var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                try help.renderHelpPopup(self, win);
                if (timer_opt) |*timer| overlay_ns += timer.read();
            } else {
                try help.renderHelpPopup(self, win);
            }
        }

        // Render graphite stack dialog if in graphite_stack mode
        if (self.mode == .graphite_stack) {
            if (profile_frame) {
                var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                try UI.renderGraphiteStackDialog(self, win);
                if (timer_opt) |*timer| overlay_ns += timer.read();
            } else {
                try UI.renderGraphiteStackDialog(self, win);
            }
        }

        // Render model selection dialog if in model_selection mode
        if (self.mode == .model_selection) {
            if (profile_frame) {
                var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                try UI.renderModelSelectionDialog(self, win);
                if (timer_opt) |*timer| overlay_ns += timer.read();
            } else {
                try UI.renderModelSelectionDialog(self, win);
            }
        }

        // Render permission selection dialog if in permission_selection mode
        if (self.mode == .permission_selection) {
            if (profile_frame) {
                var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                try UI.renderPermissionSelectionDialog(self, win);
                if (timer_opt) |*timer| overlay_ns += timer.read();
            } else {
                try UI.renderPermissionSelectionDialog(self, win);
            }
        }

        // Render agent selection dialog if in agent_selection mode
        if (self.mode == .agent_selection) {
            if (profile_frame) {
                var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                try UI.renderAgentSelectionDialog(self, win);
                if (timer_opt) |*timer| overlay_ns += timer.read();
            } else {
                try UI.renderAgentSelectionDialog(self, win);
            }
        }

        // Render session picker dialog if in session_picker mode
        if (self.mode == .session_picker) {
            if (profile_frame) {
                var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                try UI.renderSessionPickerDialog(self, win);
                if (timer_opt) |*timer| overlay_ns += timer.read();
            } else {
                try UI.renderSessionPickerDialog(self, win);
            }
        }

        // Render commit selection overlay if in commit_selection or commit_diff_mode
        if (self.mode == .commit_selection) {
            if (profile_frame) {
                var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                try UI.renderCommitSelectionMenu(self, win);
                if (timer_opt) |*timer| overlay_ns += timer.read();
            } else {
                try UI.renderCommitSelectionMenu(self, win);
            }
        }
        if (self.mode == .commit_diff_mode) {
            if (profile_frame) {
                var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                try UI.renderCommitSelectionMenu(self, win);
                if (timer_opt) |*timer| overlay_ns += timer.read();
                timer_opt = std.time.Timer.start() catch null;
                try UI.renderCommitDiffModeMenu(self, win);
                if (timer_opt) |*timer| overlay_ns += timer.read();
            } else {
                try UI.renderCommitSelectionMenu(self, win);
                try UI.renderCommitDiffModeMenu(self, win);
            }
        }

        // Render agent panel full-screen if in full-screen mode AND in agent mode
        // Only render when actually focused on the agent panel (mode == .agent)
        // Use a child window that excludes the status bar row (status bar is unified)
        if (self.isAgentPanelVisible() and self.isAgentFullScreen() and self.mode == .agent) {
            const agent_win = win.child(.{
                .x_off = 0,
                .y_off = 0,
                .width = win.width,
                .height = if (win.height > Layout.status_height) win.height - Layout.status_height else win.height,
            });
            if (profile_frame) {
                var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                try agent.renderAgentPanel(self, agent_win);
                if (timer_opt) |*timer| agent_ns += timer.read();
            } else {
                try agent.renderAgentPanel(self, agent_win);
            }
        }

        if (profile_frame) {
            const profile_log = std.log.scoped(.profile_render);
            const total_ns: u64 = if (total_timer_opt) |*timer| timer.read() else 0;
            profile_log.debug(
                "render frame {d}: total_ns={d} header_ns={d} content_ns={d} status_ns={d} agent_ns={d} overlay_ns={d} mode={s} view={s} files={d} lines={d}",
                .{ self.profile_frame_counter, total_ns, header_ns, content_ns, status_ns, agent_ns, overlay_ns, @tagName(self.mode), @tagName(self.state.view_mode), self.state.files.len, self.state.line_map.records.len },
            );
            profile_log.debug(
                "render micro: slice_ns={d} slice_calls={d} pad_ns={d} pad_calls={d} gutter_ns={d} gutter_calls={d} highlight_ns={d} highlight_calls={d} overlap_ns={d} overlap_calls={d} build_ns={d} build_calls={d} search_ns={d} search_calls={d}",
                .{
                    self.profile_counters.slice_ns,
                    self.profile_counters.slice_calls,
                    self.profile_counters.pad_ns,
                    self.profile_counters.pad_calls,
                    self.profile_counters.gutter_ns,
                    self.profile_counters.gutter_calls,
                    self.profile_counters.highlight_total_ns,
                    self.profile_counters.highlight_calls,
                    self.profile_counters.highlight_overlap_ns,
                    self.profile_counters.highlight_overlap_calls,
                    self.profile_counters.highlight_build_ns,
                    self.profile_counters.highlight_build_calls,
                    self.profile_counters.search_ns,
                    self.profile_counters.search_calls,
                },
            );
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
        line_spans: ?[]const parser.LineHighlightSpan,
        base_style: vaxis.Style,
        global_line: usize,
    ) ![]vaxis.Cell.Segment {
        var total_timer_opt: ?std.time.Timer = null;
        if (self.profile_active_frame) {
            total_timer_opt = std.time.Timer.start() catch null;
        }
        defer if (total_timer_opt) |*timer| {
            self.profile_counters.highlight_total_ns += timer.read();
            self.profile_counters.highlight_calls += 1;
        };

        const allocator = self.frameSegmentAllocator();

        // Check for merge conflict markers and apply special styling
        if (getConflictMarkerStyle(full_line_text, base_style)) |conflict_style| {
            var segments = try allocator.alloc(vaxis.Cell.Segment, 1);
            segments[0] = .{
                .text = text,
                .style = conflict_style,
            };
            return try self.applySearchHighlighting(segments, text, full_line_text, text_offset, global_line);
        }

        if (text.len == 0) {
            var segments = try allocator.alloc(vaxis.Cell.Segment, 1);
            segments[0] = .{
                .text = text,
                .style = base_style,
            };
            return try self.applySearchHighlighting(segments, text, full_line_text, text_offset, global_line);
        }

        if (line_spans) |spans| {
            if (spans.len == 0) {
                var segments = try allocator.alloc(vaxis.Cell.Segment, 1);
                segments[0] = .{ .text = text, .style = base_style };
                return try self.applySearchHighlighting(segments, text, full_line_text, text_offset, global_line);
            }

            var build_timer_opt: ?std.time.Timer = null;
            if (self.profile_active_frame) {
                build_timer_opt = std.time.Timer.start() catch null;
            }

            var segments: std.ArrayList(vaxis.Cell.Segment) = .{};
            errdefer segments.deinit(allocator);

            var pos: usize = 0;
            var span_idx: usize = 0;
            const chunk_start = text_offset;
            const chunk_end = text_offset + text.len;

            while (pos < text.len) {
                const absolute_pos = chunk_start + pos;
                while (span_idx < spans.len and spans[span_idx].end <= absolute_pos) {
                    span_idx += 1;
                }

                if (span_idx >= spans.len or spans[span_idx].start >= chunk_end) {
                    const chunk = text[pos..];
                    try segments.append(allocator, .{ .text = chunk, .style = base_style });
                    break;
                }

                const span = spans[span_idx];
                if (span.start > absolute_pos) {
                    const end = @min(span.start, chunk_end);
                    const chunk = text[pos .. end - chunk_start];
                    try segments.append(allocator, .{ .text = chunk, .style = base_style });
                    pos = end - chunk_start;
                    continue;
                }

                const end = @min(span.end, chunk_end);
                const chunk = text[pos .. end - chunk_start];
                var style = base_style;
                switch (span.category) {
                    .keyword => style.fg = Color.syntax_keyword,
                    .function => style.fg = Color.syntax_function,
                    .type => style.fg = Color.syntax_type,
                    .string => style.fg = Color.syntax_string,
                    .number, .constant => style.fg = Color.syntax_number,
                    .comment => style.fg = Color.syntax_comment,
                    .operator => style.fg = Color.syntax_operator,
                    .default => {},
                }

                try segments.append(allocator, .{ .text = chunk, .style = style });
                pos = end - chunk_start;
                span_idx += 1;
            }

            if (build_timer_opt) |*timer| {
                self.profile_counters.highlight_build_ns += timer.read();
                self.profile_counters.highlight_build_calls += 1;
            }

            const owned_segments = try segments.toOwnedSlice(allocator);
            return try self.applySearchHighlighting(owned_segments, text, full_line_text, text_offset, global_line);
        }

        if (highlights == null) {
            // No highlights - return single segment
            var segments = try allocator.alloc(vaxis.Cell.Segment, 1);
            segments[0] = .{
                .text = text,
                .style = base_style,
            };
            // Still apply search highlighting even without syntax highlights
            return try self.applySearchHighlighting(segments, text, full_line_text, text_offset, global_line);
        }

        const file_highlights = highlights.?;

        const line_start = line_byte_offset;
        const line_end = line_byte_offset + text.len;

        var overlap_timer_opt: ?std.time.Timer = null;
        if (self.profile_active_frame) {
            overlap_timer_opt = std.time.Timer.start() catch null;
        }
        const start_index = findHighlightStartIndex(file_highlights, line_start);
        if (overlap_timer_opt) |*timer| {
            self.profile_counters.highlight_overlap_ns += timer.read();
            self.profile_counters.highlight_overlap_calls += 1;
        }

        // Build segments by walking highlights in order
        var build_timer_opt: ?std.time.Timer = null;
        if (self.profile_active_frame) {
            build_timer_opt = std.time.Timer.start() catch null;
        }

        var segments: std.ArrayList(vaxis.Cell.Segment) = .{};
        errdefer segments.deinit(allocator);

        var pos: usize = 0;
        var idx = start_index;
        while (pos < text.len) {
            const absolute_pos = line_start + pos;
            while (idx < file_highlights.len and file_highlights[idx].end_byte <= absolute_pos) {
                idx += 1;
            }

            if (idx >= file_highlights.len or file_highlights[idx].start_byte >= line_end) {
                const chunk = text[pos..];
                try segments.append(allocator, .{ .text = chunk, .style = base_style });
                break;
            }

            const h = file_highlights[idx];
            const local_start = if (h.start_byte > line_start) h.start_byte - line_start else 0;
            const local_end = if (h.end_byte < line_end) h.end_byte - line_start else text.len;

            if (local_start > pos) {
                const chunk = text[pos..@min(local_start, text.len)];
                try segments.append(allocator, .{ .text = chunk, .style = base_style });
                pos = @min(local_start, text.len);
                continue;
            }

            if (local_end <= pos) {
                idx += 1;
                continue;
            }

            const end = @min(local_end, text.len);
            const chunk = text[pos..end];

            const color_category = h.getColorCategory();
            var style = base_style;
            switch (color_category) {
                .keyword => style.fg = Color.syntax_keyword,
                .function => style.fg = Color.syntax_function,
                .type => style.fg = Color.syntax_type,
                .string => style.fg = Color.syntax_string,
                .number, .constant => style.fg = Color.syntax_number,
                .comment => style.fg = Color.syntax_comment,
                .operator => style.fg = Color.syntax_operator,
                .default => {},
            }

            try segments.append(allocator, .{ .text = chunk, .style = style });
            pos = end;
            idx += 1;
        }

        if (build_timer_opt) |*timer| {
            self.profile_counters.highlight_build_ns += timer.read();
            self.profile_counters.highlight_build_calls += 1;
        }

        const owned_segments = try segments.toOwnedSlice(allocator);
        return try self.applySearchHighlighting(owned_segments, text, full_line_text, text_offset, global_line);
    }

    fn findHighlightStartIndex(highlights: []syntax.Highlight, line_start: usize) usize {
        var lo: usize = 0;
        var hi: usize = highlights.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (highlights[mid].start_byte < line_start) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        if (lo > 0 and highlights[lo - 1].end_byte > line_start) {
            return lo - 1;
        }
        return lo;
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
        var search_timer_opt: ?std.time.Timer = null;
        if (self.profile_active_frame) {
            search_timer_opt = std.time.Timer.start() catch null;
        }
        defer if (search_timer_opt) |*timer| {
            self.profile_counters.search_ns += timer.read();
            self.profile_counters.search_calls += 1;
        };
        _ = full_line_text;
        _ = chunk_offset;

        const allocator = self.frameSegmentAllocator();

        // Check if search is active
        const search_state = &self.state.search_state;
        if (search_state.query_len == 0) {
            return segments;
        }

        // KEY OPTIMIZATION: Check if this line is in the matches list
        // If not, no need to search or highlight - just return segments as-is
        const is_match_line = isMatchLine(search_state.matches.items, global_line);

        if (!is_match_line) {
            // This line doesn't match - return segments unchanged
            return segments;
        }

        const query = search_state.query_buffer[0..search_state.query_len];

        if (query.len > chunk_text.len) {
            return segments;
        }

        // Determine case sensitivity (smart case)
        const is_case_sensitive = search.isCaseSensitive(query);

        // Find all matches in the chunk_text (this is the actual text to render)
        var chunk_matches: std.ArrayList(struct { start: usize, end: usize }) = .{};
        defer chunk_matches.deinit(allocator);

        var search_pos: usize = 0;
        while (search_pos <= chunk_text.len - query.len) {
            const slice = chunk_text[search_pos .. search_pos + query.len];
            const is_match = if (is_case_sensitive)
                std.mem.eql(u8, slice, query)
            else
                std.ascii.eqlIgnoreCase(slice, query);

            if (is_match) {
                try chunk_matches.append(allocator, .{ .start = search_pos, .end = search_pos + query.len });
                search_pos += query.len;
            } else {
                search_pos += 1;
            }
        }

        if (chunk_matches.items.len == 0) {
            return segments;
        }

        // Now map the matches from chunk_text coordinates to segment coordinates
        var result_segments: std.ArrayList(vaxis.Cell.Segment) = .{};
        errdefer result_segments.deinit(allocator);

        var text_pos: usize = 0; // Current position in chunk_text
        for (segments) |seg| {
            const seg_start = text_pos;
            const seg_end = text_pos + seg.text.len;

            // Find matches that overlap with this segment
            var seg_matches: std.ArrayList(struct { start: usize, end: usize }) = .{};
            defer seg_matches.deinit(allocator);

            for (chunk_matches.items) |match| {
                if (match.end > seg_start and match.start < seg_end) {
                    // Match overlaps this segment - convert to segment-local coordinates
                    const local_start = if (match.start > seg_start) match.start - seg_start else 0;
                    const local_end = @min(match.end, seg_end) - seg_start;
                    try seg_matches.append(allocator, .{ .start = local_start, .end = local_end });
                }
            }

            if (seg_matches.items.len == 0) {
                // No matches in this segment - add as-is
                try result_segments.append(allocator, seg);
            } else {
                // Split segment at match boundaries
                var pos: usize = 0;
                for (seg_matches.items) |match| {
                    // Add text before match (if any)
                    if (match.start > pos) {
                        const before_text = seg.text[pos..match.start];
                        try result_segments.append(allocator, .{
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
                    try result_segments.append(allocator, .{
                        .text = match_text,
                        .style = match_style,
                    });

                    pos = match.end;
                }

                // Add text after last match (if any)
                if (pos < seg.text.len) {
                    const after_text = seg.text[pos..];
                    try result_segments.append(allocator, .{
                        .text = after_text,
                        .style = seg.style,
                    });
                }
            }

            text_pos += seg.text.len;
        }

        const result = try result_segments.toOwnedSlice(allocator);
        allocator.free(segments);
        return result;
    }

    fn isMatchLine(matches: []const usize, line: usize) bool {
        if (matches.len == 0) return false;
        var lo: usize = 0;
        var hi: usize = matches.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const value = matches[mid];
            if (value < line) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo < matches.len and matches[lo] == line;
    }

    // ===== TUI Server Integration =====

    /// Start TUI server and write session file
    fn startTuiServer(self: *App) !void {
        // Initialize session manager
        var sm = try session_mgr.SessionManager.init(self.allocator);
        errdefer sm.deinit();

        // Create and start TUI server
        var server = tui_server.TuiServer.init(self.allocator, handleTuiServerRequest, self);
        try server.start();

        const port = server.getPort();
        std.log.info("TUI server started on port {d}", .{port});

        self.tui_server = server;
        self.session_manager = sm;

        // Write initial session metadata once server and manager are registered.
        try self.writeSessionMetadata();
    }

    /// Handle incoming request from CLI/MCP
    fn handleTuiServerRequest(request: tui_server.Request, user_data: ?*anyopaque) tui_server.Response {
        const self: *App = @ptrCast(@alignCast(user_data.?));

        if (std.mem.eql(u8, request.method, "get_context")) {
            return self.handleGetContext();
        } else if (std.mem.eql(u8, request.method, "get_diff")) {
            return self.handleGetDiff(request.params);
        } else if (std.mem.eql(u8, request.method, "add_comment")) {
            return self.handleAddComment(request.params);
        } else if (std.mem.eql(u8, request.method, "list_comments")) {
            return self.handleListComments();
        } else if (std.mem.eql(u8, request.method, "delete_comment")) {
            return self.handleDeleteComment(request.params);
        }

        return tui_server.errorResponse(tui_server.ErrorCode.METHOD_NOT_FOUND, "Unknown method");
    }

    fn writeSessionMetadata(self: *App) !void {
        const sm = &(self.session_manager orelse return);
        const server = &(self.tui_server orelse return);

        var file_list: std.ArrayList([]const u8) = .{};
        defer file_list.deinit(self.allocator);

        for (self.state.files) |file| {
            const path = if (file.new_path.len > 0) file.new_path else file.old_path;
            try file_list.append(self.allocator, path);
        }

        try sm.writeSession(.{
            .pid = session_mgr.getCurrentPid(),
            .port = server.getPort(),
            .cwd = self.state.git_repo_root,
            .diff_ref = self.getDiffRefString(),
            .files = file_list.items,
            .started_at = std.time.timestamp(),
        });
    }

    fn syncSessionMetadata(self: *App) void {
        self.writeSessionMetadata() catch |err| {
            std.log.warn("Failed to sync session metadata: {any}", .{err});
        };
    }

    /// Handle get_context request - returns session state
    fn handleGetContext(self: *App) tui_server.Response {
        var result = std.json.ObjectMap.init(self.allocator);

        // Add diff_ref
        const diff_ref = self.getDiffRefString();
        result.put("diff_ref", .{ .string = self.allocator.dupe(u8, diff_ref) catch return tui_server.errorResponse(tui_server.ErrorCode.INTERNAL_ERROR, "Allocation failed") }) catch {
            return tui_server.errorResponse(tui_server.ErrorCode.INTERNAL_ERROR, "Allocation failed");
        };

        // Add cwd
        result.put("cwd", .{ .string = self.allocator.dupe(u8, self.state.git_repo_root) catch return tui_server.errorResponse(tui_server.ErrorCode.INTERNAL_ERROR, "Allocation failed") }) catch {
            return tui_server.errorResponse(tui_server.ErrorCode.INTERNAL_ERROR, "Allocation failed");
        };

        // Add view_mode
        const view_mode_str = switch (self.state.view_mode) {
            .unified => "unified",
            .side_by_side => "side_by_side",
        };
        result.put("view_mode", .{ .string = self.allocator.dupe(u8, view_mode_str) catch return tui_server.errorResponse(tui_server.ErrorCode.INTERNAL_ERROR, "Allocation failed") }) catch {
            return tui_server.errorResponse(tui_server.ErrorCode.INTERNAL_ERROR, "Allocation failed");
        };

        // Add files array
        var files_arr = std.json.Array.init(self.allocator);
        for (self.state.files) |file| {
            const path = if (file.new_path.len > 0) file.new_path else file.old_path;
            files_arr.append(.{ .string = self.allocator.dupe(u8, path) catch continue }) catch {};
        }
        result.put("files", .{ .array = files_arr }) catch {};

        // Add comment count
        result.put("comment_count", .{ .integer = @intCast(self.state.comment_store.comments.items.len) }) catch {};

        return .{ .result = .{ .object = result } };
    }

    /// Handle get_diff request - returns formatted diff with line numbers
    /// Params: { file?: string } - optional file filter
    fn handleGetDiff(self: *App, params: ?std.json.Value) tui_server.Response {
        // Optional file filter
        const file_filter: ?[]const u8 = blk: {
            const p = params orelse break :blk null;
            if (p != .object) break :blk null;
            const file_val = p.object.get("file") orelse break :blk null;
            if (file_val != .string) break :blk null;
            if (file_val.string.len == 0) break :blk null;
            break :blk file_val.string;
        };

        var output: std.ArrayList(u8) = .{};
        const writer = output.writer(self.allocator);

        for (self.state.files) |*file| {
            const path = if (file.new_path.len > 0) file.new_path else file.old_path;

            // Skip if file filter is set and doesn't match
            if (file_filter) |filter| {
                if (!std.mem.eql(u8, path, filter)) continue;
            }

            // File header
            writer.print("=== {s} ===\n", .{path}) catch continue;

            for (file.hunks, 0..) |*hunk, hunk_idx| {
                // Hunk header
                writer.print("\n@@ Hunk {d}: -{d},{d} +{d},{d} @@", .{
                    hunk_idx,
                    hunk.header.old_start,
                    hunk.header.old_count,
                    hunk.header.new_start,
                    hunk.header.new_count,
                }) catch continue;
                if (hunk.header.context.len > 0) {
                    writer.print(" {s}", .{hunk.header.context}) catch {};
                }
                writer.writeAll("\n") catch continue;

                // Lines with line numbers
                for (hunk.lines) |*line| {
                    const marker: u8 = switch (line.line_type) {
                        .add => '+',
                        .delete => '-',
                        .context => ' ',
                    };

                    // Format: "marker old_line new_line | content"
                    // e.g. "+     42 | const x = 1;"  (added line, new line 42)
                    // e.g. "-  41    | const y = 2;"  (deleted line, old line 41)
                    // e.g. "   41 42 | unchanged"     (context line)
                    const old_str: []const u8 = if (line.old_lineno) |n| blk: {
                        break :blk std.fmt.allocPrint(self.allocator, "{d: >4}", .{n}) catch "????";
                    } else "    ";
                    defer if (line.old_lineno != null) self.allocator.free(old_str);

                    const new_str: []const u8 = if (line.new_lineno) |n| blk: {
                        break :blk std.fmt.allocPrint(self.allocator, "{d: >4}", .{n}) catch "????";
                    } else "    ";
                    defer if (line.new_lineno != null) self.allocator.free(new_str);

                    writer.print("{c} {s} {s} | {s}\n", .{ marker, old_str, new_str, line.content }) catch continue;
                }
            }
            writer.writeAll("\n") catch {};
        }

        const diff_text = output.toOwnedSlice(self.allocator) catch {
            output.deinit(self.allocator);
            return tui_server.errorResponse(tui_server.ErrorCode.INTERNAL_ERROR, "Failed to build diff");
        };

        var result = std.json.ObjectMap.init(self.allocator);
        result.put("diff", .{ .string = diff_text }) catch {
            self.allocator.free(diff_text);
            return tui_server.errorResponse(tui_server.ErrorCode.INTERNAL_ERROR, "Failed to build result");
        };
        return .{ .result = .{ .object = result } };
    }

    /// Handle add_comment request
    /// Params: { file: string, line: number, line_type: "new"|"old", text: string }
    fn handleAddComment(self: *App, params: ?std.json.Value) tui_server.Response {
        const p = params orelse return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "Missing params");
        if (p != .object) return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "params must be object");

        const obj = p.object;

        // Extract parameters
        const file_val = obj.get("file") orelse return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "Missing 'file'");
        const file = if (file_val == .string) file_val.string else return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "'file' must be string");

        const line_val = obj.get("line") orelse return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "Missing 'line'");
        const line_num: u32 = switch (line_val) {
            .integer => |i| if (i >= 0) @intCast(i) else return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "'line' must be non-negative"),
            else => return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "'line' must be integer"),
        };

        const line_type_val = obj.get("line_type") orelse return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "Missing 'line_type'");
        const line_type_str = if (line_type_val == .string) line_type_val.string else return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "'line_type' must be string");
        const use_new_lineno = if (std.mem.eql(u8, line_type_str, "new"))
            true
        else if (std.mem.eql(u8, line_type_str, "old"))
            false
        else
            return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "'line_type' must be 'new' or 'old'");

        const text_val = obj.get("text") orelse return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "Missing 'text'");
        const text = if (text_val == .string) text_val.string else return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "'text' must be string");

        // Find the file in the diff
        const file_diff = blk: {
            for (self.state.files) |*f| {
                const path = if (f.new_path.len > 0) f.new_path else f.old_path;
                if (std.mem.eql(u8, path, file)) {
                    break :blk f;
                }
            }
            return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "File not found in diff");
        };

        // Find the hunk and line by line number
        const line_info: struct { hunk_idx: usize, line_idx: usize, line: *const parser.Line } = blk: {
            for (file_diff.hunks, 0..) |*hunk, hunk_idx| {
                for (hunk.lines, 0..) |*line, line_idx| {
                    const target_lineno = if (use_new_lineno) line.new_lineno else line.old_lineno;
                    if (target_lineno) |ln| {
                        if (ln == line_num) {
                            break :blk .{ .hunk_idx = hunk_idx, .line_idx = line_idx, .line = line };
                        }
                    }
                }
            }
            return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "Line not found in diff");
        };

        // Add the comment
        self.state.comment_store.addComment(
            file,
            line_info.hunk_idx,
            line_info.line_idx,
            text,
            line_info.line.line_type,
            line_info.line.content,
            line_info.line.old_lineno,
            line_info.line.new_lineno,
        ) catch {
            return tui_server.errorResponse(tui_server.ErrorCode.INTERNAL_ERROR, "Failed to add comment");
        };

        // Rebuild LineMap
        self.state.line_map.deinit();
        self.state.line_map = line_map.LineMap.build(
            self.allocator,
            self.state.files,
            &self.state.comment_store,
            self.convertHunkViewMode(),
            self.shouldApplyHunkFiltering(),
            &self.state.collapsed_folds,
        ) catch {
            return tui_server.errorResponse(tui_server.ErrorCode.INTERNAL_ERROR, "Failed to rebuild line map");
        };
        self.needs_render = true;

        // Auto-scroll to show the new comment (for external callers like CLI/MCP)
        const comment_idx = self.state.comment_store.comments.items.len - 1;
        if (self.state.line_map.findLineByCommentIdx(comment_idx)) |comment_line| {
            // Center the comment in the viewport
            const half_viewport = self.state.viewport_height / 2;
            if (comment_line >= half_viewport) {
                self.state.global_scroll_offset = comment_line - half_viewport;
            } else {
                self.state.global_scroll_offset = 0;
            }
            // Also move cursor to the comment line
            self.state.global_cursor_line = comment_line;
        }

        var result = std.json.ObjectMap.init(self.allocator);
        result.put("success", .{ .bool = true }) catch {};
        result.put("comment_index", .{ .integer = @intCast(comment_idx) }) catch {};
        return .{ .result = .{ .object = result } };
    }

    /// Handle list_comments request
    fn handleListComments(self: *App) tui_server.Response {
        var result = std.json.ObjectMap.init(self.allocator);

        var comments_arr = std.json.Array.init(self.allocator);
        for (self.state.comment_store.comments.items, 0..) |comment, idx| {
            var comment_obj = std.json.ObjectMap.init(self.allocator);
            comment_obj.put("index", .{ .integer = @intCast(idx) }) catch continue;
            comment_obj.put("file_path", .{ .string = self.allocator.dupe(u8, comment.file_path) catch continue }) catch continue;
            comment_obj.put("hunk_idx", .{ .integer = @intCast(comment.hunk_idx) }) catch continue;
            comment_obj.put("line_idx", .{ .integer = @intCast(comment.line_idx) }) catch continue;
            comment_obj.put("text", .{ .string = self.allocator.dupe(u8, comment.text) catch continue }) catch continue;
            comments_arr.append(.{ .object = comment_obj }) catch {};
        }

        result.put("comments", .{ .array = comments_arr }) catch {};
        return .{ .result = .{ .object = result } };
    }

    /// Handle delete_comment request
    fn handleDeleteComment(self: *App, params: ?std.json.Value) tui_server.Response {
        const p = params orelse return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "Missing params");
        if (p != .object) return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "params must be object");

        const obj = p.object;

        const index_val = obj.get("index") orelse return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "Missing 'index'");
        const index: usize = switch (index_val) {
            .integer => |i| if (i >= 0) @intCast(i) else return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "'index' must be non-negative"),
            else => return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "'index' must be integer"),
        };

        // Delete comment
        self.state.comment_store.deleteComment(index) catch {
            return tui_server.errorResponse(tui_server.ErrorCode.INVALID_PARAMS, "Invalid comment index");
        };

        // Rebuild LineMap
        self.state.line_map.deinit();
        self.state.line_map = line_map.LineMap.build(
            self.allocator,
            self.state.files,
            &self.state.comment_store,
            self.convertHunkViewMode(),
            self.shouldApplyHunkFiltering(),
            &self.state.collapsed_folds,
        ) catch {
            return tui_server.errorResponse(tui_server.ErrorCode.INTERNAL_ERROR, "Failed to rebuild line map");
        };
        self.needs_render = true;

        var result = std.json.ObjectMap.init(self.allocator);
        result.put("success", .{ .bool = true }) catch {};
        return .{ .result = .{ .object = result } };
    }

    /// Get session port (for status display)
    pub fn getSessionPort(self: *const App) ?u16 {
        if (self.tui_server) |server| {
            return server.port;
        }
        return null;
    }

    // =========================================================================
    // Review Methods
    // =========================================================================

    /// Background thread function for ACP connection
    fn acpConnectThreadFn(ctx: *AcpConnectContext) void {
        std.log.info("ACP: Background connection thread started for tab {d}", .{ctx.tab_id});

        // Get the manager from the target tab
        const mgr: *acp.AcpManager = blk: {
            if (ctx.app.tab_manager) |*tm| {
                if (tm.findTabById(ctx.tab_id)) |idx| {
                    if (tm.getTab(idx)) |tab| {
                        if (tab.getActiveAcpManager()) |m| {
                            break :blk m;
                        }
                    }
                }
            }
            std.log.err("ACP: No manager found for tab {d}", .{ctx.tab_id});
            return;
        };

        // Get agent info from context (required - no auto-discovery)
        const agent_info: acp.AgentInfo = if (ctx.agent) |a| a.* else {
            std.log.err("ACP: No agent provided in context", .{});
            mgr.status = .failed;
            return;
        };
        std.log.info("ACP: Using agent: {s}", .{agent_info.name});

        // Update status to connecting
        mgr.status = .connecting;

        // Convert AgentInfo.EnvVar to AcpManager.EnvVar for connect call
        const mgr_env = ctx.app.allocator.alloc(acp.AcpManager.EnvVar, agent_info.env.len) catch {
            std.log.err("ACP: Failed to allocate env vars", .{});
            return;
        };
        defer ctx.app.allocator.free(mgr_env);
        for (agent_info.env, 0..) |ev, i| {
            mgr_env[i] = .{ .name = ev.name, .value = ev.value };
        }

        // Connect to agent (spawn + initialize)
        mgr.connect(agent_info.command, agent_info.args, ctx.cwd, mgr_env) catch |err| {
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

        // Apply configured model if set and matches an available model
        if (agent_info.model) |model_name| {
            std.log.info("ACP: Applying configured model: {s}", .{model_name});
            _ = mgr.applyConfiguredModel(model_name);
        }
    }

    /// Start an ACP agent session (non-blocking)
    /// If agents are configured, may show selection menu first.
    pub fn startAcpSession(self: *App) !void {
        std.log.info("ACP: startAcpSession called", .{});

        // Check if connection already in progress
        if (self.pending_connection != null) {
            std.log.info("ACP: Connection already in progress", .{});
            self.showStatusMessage("Connection already in progress...");
            return;
        }

        // Check if already connected
        if (self.getActiveAcpManager()) |mgr| {
            if (mgr.isConnected()) {
                std.log.info("ACP: Already connected", .{});
                self.showStatusMessage("Agent already connected");
                return;
            }
        }

        // Load configured agents (if not already loaded)
        if (self.state.configured_agents == null) {
            self.state.configured_agents = self.loadConfiguredAgents();
        }

        const agents = self.state.configured_agents orelse {
            // No agents configured - show error in agent panel and stay in agent mode
            std.log.warn("ACP: No agents configured in ~/.skim/config.json", .{});
            if (self.getActiveAgentState()) |agent_state| {
                agent_state.addMessage(.system, "No agents configured. Add agents to ~/.skim/config.json") catch {};
            }
            return;
        };

        // Decision logic for agent selection
        if (agents.len == 0) {
            std.log.warn("ACP: Empty agents list in config", .{});
            if (self.getActiveAgentState()) |agent_state| {
                agent_state.addMessage(.system, "No agents configured. Add agents to ~/.skim/config.json") catch {};
            }
            return;
        }

        // Always show agent selection menu
        std.log.info("ACP: {d} agent(s) configured, showing selection menu", .{agents.len});
        self.state.agent_selection_idx = 0;
        self.mode = .agent_selection;
        self.needs_render = true;
    }

    /// Connect to a specific agent.
    /// Agent info is required - no auto-discovery.
    /// Manager is stored directly in the target tab (pending_tab_for_selection or active tab).
    pub fn connectToAgent(self: *App, agent_info: ?*const acp.AgentInfo) !void {
        // Ensure tab manager exists
        const tm = self.ensureTabManager() catch |err| {
            std.log.err("ACP: Failed to ensure tab manager: {any}", .{err});
            self.showStatusMessage("Failed to initialize tabs");
            return;
        };

        // Find target tab (pending_tab_for_selection or active)
        const target_tab: *agent.AgentTab = blk: {
            if (self.state.pending_tab_for_selection) |pending_id| {
                if (tm.findTabById(pending_id)) |idx| {
                    if (tm.getTab(idx)) |tab| {
                        break :blk tab;
                    }
                }
            }
            break :blk tm.activeTab() orelse {
                std.log.err("ACP: No target tab found", .{});
                self.showStatusMessage("No tab available");
                return;
            };
        };

        // Check protocol for Opencode/Codex routing
        if (agent_info) |info| {
            if (info.protocol == .opencode) {
                try self.connectToOpencodeAgent(target_tab, info);
                return;
            }
            if (info.protocol == .codex) {
                try self.connectToCodexAgent(target_tab, info);
                return;
            }
        }

        // Clean up any existing manager on target tab
        target_tab.disconnectAll();

        // Create and initialize the manager with discovering status
        const mgr = try self.allocator.create(acp.AcpManager);
        mgr.* = acp.AcpManager.init(self.allocator);
        mgr.status = .discovering;

        // Store server name from config (for display in title bar)
        if (agent_info) |info| {
            mgr.server_name = self.allocator.dupe(u8, info.name) catch null;
        }

        // Store directly in target tab
        target_tab.manager = .{ .acp = mgr };

        // Clear pending tab selection
        self.state.pending_tab_for_selection = null;

        if (agent_info) |info| {
            self.showStatusMessage("Connecting to agent...");
            std.log.info("ACP: Connecting to {s} for tab {d}", .{ info.name, target_tab.id });
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
            .tab_id = target_tab.id,
        };

        // Spawn background thread for connection
        const thread = std.Thread.spawn(.{}, acpConnectThreadFn, .{ctx}) catch |err| {
            std.log.err("Failed to spawn ACP connect thread: {any}", .{err});
            self.showStatusMessage("Failed to start connection");
            self.allocator.destroy(ctx);
            // Clean up the manager we stored in the tab
            target_tab.manager = null;
            mgr.deinit();
            self.allocator.destroy(mgr);
            return;
        };

        self.pending_connection = .{
            .thread = thread,
            .tab_id = target_tab.id,
            .ctx = .{ .acp = ctx },
        };
    }

    /// Connect to an Opencode agent for the given tab (non-blocking)
    fn connectToOpencodeAgent(self: *App, target_tab: *agent.AgentTab, agent_info: *const acp.AgentInfo) !void {
        // Clean up any existing managers on target tab
        target_tab.disconnectAll();

        // Clear pending tab selection
        self.state.pending_tab_for_selection = null;

        // Create Opencode manager and store it in the tab immediately (enables rendering)
        const mgr = try target_tab.createOpencodeManager();

        self.showStatusMessage("Connecting to Opencode...");
        std.log.info("Opencode: Connecting to {s} for tab {d}", .{ agent_info.name, target_tab.id });
        self.needs_render = true;

        // Store connection context (static lifetime for thread)
        const ctx = try self.allocator.create(OpencodeConnectContext);
        ctx.* = .{
            .mgr = mgr,
            .opencode_path = agent_info.command,
            .port = 4096,
            .cwd = self.state.git_repo_root,
        };

        // Spawn background thread for connection
        const thread = std.Thread.spawn(.{}, opcConnectThreadFn, .{ctx}) catch |err| {
            std.log.err("Failed to spawn Opencode connect thread: {any}", .{err});
            self.showStatusMessage("Failed to start connection");
            self.allocator.destroy(ctx);
            target_tab.manager = null;
            mgr.deinit();
            self.allocator.destroy(mgr);
            return;
        };

        self.pending_connection = .{
            .thread = thread,
            .tab_id = target_tab.id,
            .ctx = .{ .opencode = ctx },
        };
    }

    fn opcConnectThreadFn(ctx: *OpencodeConnectContext) void {
        std.log.info("Opencode: Background connection thread started", .{});

        ctx.mgr.connect(.{
            .opencode_path = ctx.opencode_path,
            .port = ctx.port,
            .cwd = ctx.cwd,
            .spawn_server = true,
        }) catch |err| {
            std.log.err("Opencode: Connect failed: {}", .{err});
            return;
        };

        std.log.info("Opencode: Connected successfully", .{});
    }

    /// Connect to a Codex agent for the given tab (non-blocking)
    fn connectToCodexAgent(self: *App, target_tab: *agent.AgentTab, agent_info: *const acp.AgentInfo) !void {
        // Clean up any existing managers on target tab
        target_tab.disconnectAll();

        // Clear pending tab selection
        self.state.pending_tab_for_selection = null;

        // Create Codex manager and store it in the tab immediately (enables rendering)
        const mgr = try target_tab.createCodexManager();

        self.showStatusMessage("Connecting to Codex...");
        std.log.info("Codex: Connecting to {s} for tab {d}", .{ agent_info.name, target_tab.id });
        self.needs_render = true;

        // Store connection context (static lifetime for thread)
        const ctx = try self.allocator.create(CodexConnectContext);
        ctx.* = .{
            .mgr = mgr,
            .command = agent_info.command,
            .args = agent_info.args,
            .cwd = self.state.git_repo_root,
            .model = agent_info.model,
            .approval_policy = agent_info.approval_policy,
        };

        // Spawn background thread for connection
        const thread = std.Thread.spawn(.{}, codexConnectThreadFn, .{ctx}) catch |err| {
            std.log.err("Failed to spawn Codex connect thread: {any}", .{err});
            self.showStatusMessage("Failed to start connection");
            self.allocator.destroy(ctx);
            target_tab.manager = null;
            mgr.deinit();
            self.allocator.destroy(mgr);
            return;
        };

        self.pending_connection = .{
            .thread = thread,
            .tab_id = target_tab.id,
            .ctx = .{ .codex = ctx },
        };
    }

    fn codexConnectThreadFn(ctx: *CodexConnectContext) void {
        std.log.info("Codex: Background connection thread started", .{});

        ctx.mgr.requested_approval_policy = if (ctx.approval_policy) |approval_policy|
            codex_mod.protocol.ApprovalPolicy.fromString(approval_policy)
        else
            null;

        // Connect to codex app-server (spawn process, handshake)
        ctx.mgr.connect(ctx.command, ctx.args, ctx.cwd) catch |err| {
            std.log.err("Codex: Connect failed: {}", .{err});
            return;
        };

        std.log.info("Codex: Connected, starting thread...", .{});

        // Start a thread (creates conversation context)
        ctx.mgr.startThread(ctx.model, ctx.cwd) catch |err| {
            std.log.err("Codex: StartThread failed: {}", .{err});
            return;
        };

        std.log.info("Codex: Thread started successfully", .{});
    }

    /// Connect to the currently selected agent in the selection menu
    pub fn connectToSelectedAgent(self: *App) !void {
        const agents = self.state.configured_agents orelse return;
        if (self.state.agent_selection_idx >= agents.len) return;
        try self.connectToAgent(&agents[self.state.agent_selection_idx]);
    }

    /// Load configured agents from config file.
    /// Returns null if no agents are configured.
    pub fn loadConfiguredAgents(self: *App) ?[]acp.AgentInfo {
        // Try to load from config - now uses standard agent_servers format
        const cfg_agents = app_config.getConfiguredAgents(self.allocator) catch null;

        if (cfg_agents) |agents| {
            if (agents.len > 0) {
                // Convert config.AgentServerConfig to acp.ConfigAgent
                const acp_agents = self.allocator.alloc(acp.ConfigAgent, agents.len) catch {
                    app_config.freeAgentServers(self.allocator, agents);
                    return null;
                };
                defer self.allocator.free(acp_agents);

                for (agents, 0..) |cfg, i| {
                    // Convert env vars
                    const env_slice: ?[]const acp.ConfigEnvVar = if (cfg.env) |env| blk: {
                        const env_copy = self.allocator.alloc(acp.ConfigEnvVar, env.len) catch {
                            app_config.freeAgentServers(self.allocator, agents);
                            return null;
                        };
                        for (env, 0..) |ev, j| {
                            env_copy[j] = .{ .name = ev.name, .value = ev.value };
                        }
                        break :blk env_copy;
                    } else null;

                    // Convert skim extensions
                    const skim_ext: ?acp.SkimAgentExtensions = if (cfg.skim) |s|
                        .{ .default = s.default, .mode = s.mode, .model = s.model }
                    else
                        null;

                    // Convert protocol enum
                    const protocol: acp.AcpManager.Protocol = switch (cfg.protocol) {
                        .acp => .acp,
                        .opencode => .opencode,
                        .codex => .codex,
                    };

                    acp_agents[i] = .{
                        .name = cfg.name,
                        .command = cfg.command,
                        .args = cfg.args,
                        .env = env_slice,
                        .skim = skim_ext,
                        .protocol = protocol,
                        .approval_policy = cfg.approval_policy,
                    };
                }

                // loadAgentList will dupe all strings and expand env vars
                const result = (acp.loadAgentList(self.allocator, acp_agents) catch null) orelse {
                    // Free converted env slices
                    for (acp_agents) |a| {
                        if (a.env) |e| self.allocator.free(e);
                    }
                    app_config.freeAgentServers(self.allocator, agents);
                    return null;
                };

                // Free converted env slices
                for (acp_agents) |a| {
                    if (a.env) |e| self.allocator.free(e);
                }
                // Clean up config agents (loadAgentList made copies)
                app_config.freeAgentServers(self.allocator, agents);
                return result;
            }
            app_config.freeAgentServers(self.allocator, agents);
        }

        // No agents configured
        return null;
    }

    /// Disconnect from the ACP agent for the active tab
    pub fn stopAcpSession(self: *App) void {
        if (self.tab_manager) |*tm| {
            if (tm.activeTab()) |tab| {
                if (tab.manager != null) {
                    tab.disconnectAll();
                    self.showStatusMessage("Disconnected from agent");
                    self.needs_render = true;
                }
            }
        }
    }

    /// Check ACP agent status for the active tab
    pub fn getAcpStatus(self: *App) ?acp.AcpManager.Status {
        if (self.getActiveAcpManager()) |mgr| {
            return mgr.status;
        }
        return null;
    }

    /// Poll all managers: check connection thread, then poll each tab's manager.
    fn pollAllManagers(self: *App) void {
        const connection_active = self.pollConnectionThread();

        // Don't poll tabs while an ACP or Codex connection thread is active — it would clear
        // messages that waitForResponse() in the background thread needs.
        if (connection_active) {
            if (self.pending_connection) |conn| {
                switch (conn.ctx) {
                    .acp, .codex => return,
                    .opencode => {},
                }
            }
        }

        // Poll all tabs via unified ManagerHandle.pollEvents
        if (self.tab_manager) |*tm| {
            for (tm.tabs.items, 0..) |*tab, tab_idx| {
                const handle = tab.manager orelse continue;
                self.pollTabManager(handle, &tab.agent_state, tab_idx == tm.active_idx);
            }
        }
    }

    /// Check if the pending connection thread completed and handle success/failure.
    /// Returns true if a connection thread is still active.
    fn pollConnectionThread(self: *App) bool {
        const conn = self.pending_connection orelse return false;

        const tab = self.getConnectingTab() orelse {
            // Tab disappeared — clean up connection state
            conn.thread.join();
            switch (conn.ctx) {
                .acp => |ctx| self.allocator.destroy(ctx),
                .opencode => |ctx| self.allocator.destroy(ctx),
                .codex => |ctx| self.allocator.destroy(ctx),
            }
            self.pending_connection = null;
            return false;
        };

        const handle = tab.manager orelse {
            // Manager was removed from the tab — clean up
            conn.thread.join();
            switch (conn.ctx) {
                .acp => |ctx| self.allocator.destroy(ctx),
                .opencode => |ctx| self.allocator.destroy(ctx),
                .codex => |ctx| self.allocator.destroy(ctx),
            }
            self.pending_connection = null;
            return false;
        };

        // Check if the manager is still initializing (thread still working)
        if (handle.isInitializing()) return true;

        // Thread is done — join and clean up
        conn.thread.join();

        switch (conn.ctx) {
            .acp => |ctx| {
                self.allocator.destroy(ctx);
                switch (handle) {
                    .acp => |mgr| {
                        if (mgr.status == .session_active) {
                            const agent_name = mgr.getAgentDisplayName();
                            const model_name = mgr.getCurrentModelName();
                            const msg = if (model_name.len > 0)
                                std.fmt.allocPrint(self.allocator, "Connected to {s} · {s}", .{ agent_name, model_name }) catch "Connected"
                            else
                                std.fmt.allocPrint(self.allocator, "Connected to {s}", .{agent_name}) catch "Connected";
                            defer if (!std.mem.eql(u8, msg, "Connected")) self.allocator.free(msg);
                            self.showStatusMessage(msg);

                            if (self.getConnectingAgentState()) |agent_state_conn| {
                                const welcome_msg = if (model_name.len > 0)
                                    std.fmt.allocPrint(self.allocator, "Connected to {s} · {s}. You can start chatting!", .{ agent_name, model_name }) catch "Connected! You can start chatting."
                                else
                                    std.fmt.allocPrint(self.allocator, "Connected to {s}. You can start chatting!", .{agent_name}) catch "Connected! You can start chatting.";
                                defer if (!std.mem.eql(u8, welcome_msg, "Connected! You can start chatting.")) self.allocator.free(welcome_msg);
                                agent_state_conn.addMessage(.system, welcome_msg) catch {};
                            }

                            std.log.info("ACP: Connection complete for tab {d}", .{conn.tab_id});
                            mgr.sendNextQueuedPrompt();
                        } else if (mgr.status == .failed) {
                            self.showStatusMessage("Failed to connect to agent");
                            if (self.getConnectingAgentState()) |agent_state_conn| {
                                agent_state_conn.addMessage(.system, "Connection failed. Press 'a' to close this panel and try again.") catch {};
                            }
                            tab.manager = null;
                            mgr.deinit();
                            self.allocator.destroy(mgr);
                        }
                    },
                    .opencode, .codex => {},
                }
            },
            .opencode => |ctx| {
                self.allocator.destroy(ctx);
                switch (handle) {
                    .opencode => |mgr| {
                        if (mgr.status == .session_active) {
                            self.showStatusMessage("Connected to Opencode");
                            if (self.getConnectingAgentState()) |agent_state_conn| {
                                agent_state_conn.addMessage(.system, "Connected to Opencode. You can start chatting!") catch {};
                            }
                            std.log.info("Opencode: Connection complete for tab {d}", .{conn.tab_id});
                        } else if (mgr.status == .failed or mgr.status == .disconnected) {
                            self.showStatusMessage("Failed to connect to Opencode");
                            if (self.getConnectingAgentState()) |agent_state_conn| {
                                agent_state_conn.addMessage(.system, "Connection failed. Check if opencode is installed.") catch {};
                            }
                            tab.manager = null;
                            mgr.deinit();
                            self.allocator.destroy(mgr);
                        }
                    },
                    .acp, .codex => {},
                }
            },
            .codex => |ctx| {
                self.allocator.destroy(ctx);
                switch (handle) {
                    .codex => |mgr| {
                        if (mgr.status == .thread_active) {
                            const model_name = mgr.model orelse "Codex";
                            const msg = std.fmt.allocPrint(self.allocator, "Connected to Codex · {s}", .{model_name}) catch "Connected to Codex";
                            defer if (!std.mem.eql(u8, msg, "Connected to Codex")) self.allocator.free(msg);
                            self.showStatusMessage(msg);

                            if (self.getConnectingAgentState()) |agent_state_conn| {
                                const welcome_msg = std.fmt.allocPrint(self.allocator, "Connected to Codex · {s}. You can start chatting!", .{model_name}) catch "Connected to Codex! You can start chatting.";
                                defer if (!std.mem.eql(u8, welcome_msg, "Connected to Codex! You can start chatting.")) self.allocator.free(welcome_msg);
                                agent_state_conn.addMessage(.system, welcome_msg) catch {};
                            }

                            std.log.info("Codex: Connection complete for tab {d}", .{conn.tab_id});
                        } else if (mgr.status == .@"error" or mgr.status == .disconnected) {
                            self.showStatusMessage("Failed to connect to Codex");
                            if (self.getConnectingAgentState()) |agent_state_conn| {
                                agent_state_conn.addMessage(.system, "Connection failed. Check if codex is installed.") catch {};
                            }
                            tab.manager = null;
                            mgr.deinit();
                            self.allocator.destroy(mgr);
                        }
                    },
                    .acp, .opencode => {},
                }
            },
        }

        self.pending_connection = null;
        self.needs_render = true;
        return false;
    }

    /// Get the tab being connected (via pending_connection.tab_id)
    fn getConnectingTab(self: *App) ?*agent.AgentTab {
        const conn = self.pending_connection orelse return null;
        if (self.tab_manager) |*tm| {
            if (tm.findTabById(conn.tab_id)) |idx| {
                return tm.getTab(idx);
            }
        }
        return null;
    }

    /// Get the agent state for the tab being connected
    fn getConnectingAgentState(self: *App) ?*agent.AgentState {
        if (self.getConnectingTab()) |tab| {
            return &tab.agent_state;
        }
        return null;
    }

    /// Poll a single tab's manager and route events to its agent state
    fn pollTabManager(self: *App, handle: agent.tab_manager.ManagerHandle, agent_state_ptr: *agent.AgentState, is_active_tab: bool) void {
        const was_prompting = handle.isPrompting();

        const result = handle.pollEvents(self.allocator, agent_state_ptr);

        if (result.count > 0) self.needs_render = true;
        if (result.more_pending) self.needs_render = true;
        if (result.status_changed) self.needs_render = true;
        if (result.needs_line_map_dirty) agent_state_ptr.line_map_dirty = true;

        // Auto-execute staged shell commands when agent finishes prompting
        if (was_prompting and !handle.isPrompting()) {
            if (agent_state_ptr.hasStagedPrompt() and agent_state_ptr.isStagedShellCommand()) {
                const staged = agent_state_ptr.getStagedPrompt();
                agent_mode.handleShellCommand(self, agent_state_ptr, staged) catch {};
                agent_state_ptr.clearStagedPrompt();
            }
        }

        // Auto-send staged prompts when manager is ready
        if (handle.isReadyForAutoSend() and agent_state_ptr.hasStagedPrompt()) {
            if (agent_state_ptr.isStagedShellCommand()) {
                const staged = agent_state_ptr.getStagedPrompt();
                agent_mode.handleShellCommand(self, agent_state_ptr, staged) catch {};
                agent_state_ptr.clearStagedPrompt();
            } else if (agent_state_ptr.takeStagedPrompt()) |staged| {
                if (is_active_tab) {
                    std.log.info("Agent: Auto-sending staged message ({d} bytes)", .{staged.len});
                }

                agent_state_ptr.addMessage(.user, staged) catch {};

                handle.sendPrompt(staged) catch |err| {
                    std.log.err("Agent: Failed to send staged prompt: {any}", .{err});
                    agent_state_ptr.addMessage(.system, "Failed to send staged message") catch {};
                };

                self.needs_render = true;
            }
        }
    }

    /// Get the diff reference string for display
    fn getDiffRefString(self: *App) []const u8 {
        return switch (self.state.diff_source) {
            .working_dir => |wd| if (wd.staged) "staged" else "working",
            .single_ref => |sr| sr.ref,
            .two_refs => "refs",
            .stdin => "stdin",
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
