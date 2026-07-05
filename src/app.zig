const std = @import("std");
const vaxis = @import("vaxis");
const git = @import("git/diff.zig");
const blame_ctrl = @import("git/blame_controller.zig");
const parser = @import("git/parser.zig");
const syntax = @import("highlighting/core.zig");
const comments = @import("comments/store.zig");
const line_map = @import("line_map.zig");
const folds = @import("folds.zig");
const tui_server = @import("mcp/tui_server.zig");
const session_mgr = @import("mcp/session.zig");
const mcp_handlers = @import("mcp/handlers.zig");
const navigation = @import("navigation.zig");
const mouse = @import("mouse.zig");
const search = @import("search.zig");
const clipboard = @import("clipboard.zig");
const rendering_common = @import("rendering/common.zig");
const render_utils = @import("rendering/utils.zig");
const width_util = @import("rendering/width.zig");
const frame = @import("rendering/frame.zig");
const state_helpers = @import("state.zig");
const ui_components = @import("ui.zig");
const editor = @import("editor.zig");
const comment_editor = @import("comments/editor.zig");
const command_palette = @import("command_palette.zig");
const help = @import("help.zig");
const codex_manager = @import("codex/manager.zig");

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
const pr_review_mode = @import("modes/pr_review_mode.zig");
const review_submit_mode = @import("modes/review_submit_mode.zig");
const pr_info_mode = @import("modes/pr_info_mode.zig");
const agent_mode = @import("modes/agent_mode.zig");
const agent = @import("agent/agent.zig");
const debug_replay_controller = @import("agent/debug_replay_controller.zig");
const sessions = @import("acp/sessions.zig");
const app_config = @import("config.zig");
const build_options = @import("build_options");
const graphite_controller = @import("git/graphite_controller.zig");
const acp = @import("acp/acp.zig");
const connect = @import("acp/connect.zig");
const opencode = @import("opencode/opencode.zig");
const codex_mod = @import("codex/codex.zig");
const pr = @import("pr/pr.zig");
const pr_controller = @import("pr/controller.zig");
const review_controller = @import("pr/review_controller.zig");
const thread_anchor = @import("pr/thread_anchor.zig");
const thread_placement = @import("pr/thread_placement.zig");
const subagent_fetch = @import("agent/subagent_fetch.zig");
const hunk_view = @import("hunk_view.zig");

const DiffSource = git.DiffSource;
const Navigation = navigation.Navigation;
const RenderUtils = render_utils.RenderUtils;
const StateHelpers = state_helpers.StateHelpers;
const AsyncHighlightJob = state_helpers.AsyncHighlightJob;
const DividerPosition = ui_components.DividerPosition;

const Allocator = std.mem.Allocator;
const Vaxis = vaxis.Vaxis;
const Event = vaxis.Event;

// Use centralized definitions from rendering/common.zig
const Layout = rendering_common.Layout;
const FrameChars = rendering_common.FrameChars;
const profiling_enabled = build_options.enable_profile;

const HEADER_BUFFER_WIDTH = 4096;
const FRAME_TEXT_CAPACITY = 262144; // 256 KiB per frame scratch space

const HunkKey = struct {
    file_idx: usize,
    hunk_idx: usize,
};

const PendingJob = struct {
    file_path: []const u8, // Owned file path used by worker
    content: []const u8, // Owned NEW hunk content
    old_content: []const u8, // Owned OLD hunk content
};

// Static buffer for vaxis Tty writer (must persist for lifetime of Tty)
var tty_static_buffer: [4096]u8 = undefined;

/// Case-insensitive substring search
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
    blame: blame_ctrl.Blame, // git-blame gutter sub-state (cache + async fetch machinery)
    pending_connection: ?connect.PendingConnection, // Background connection thread (ACP or Opencode)
    pending_agent_connect_idx: ?usize, // Selected agent index queued to start after the next render
    pending_subagent_fetch: subagent_fetch.PendingSubagentFetch, // Thread-safe result from subagent fetch worker
    in_bracketed_paste: bool, // Whether we're currently receiving bracketed paste input
    agent_only: bool, // Start in agent-only mode (no diff view)
    tab_manager: ?agent.TabManager, // Multi-tab agent manager
    profile_render: bool, // Enable render timing logs
    profile_every_n: u32, // Log every N frames when profiling
    profile_frame_counter: u64, // Incremented on each rendered frame
    profile_active_frame: bool, // True when current render should be profiled
    profile_counters: RenderProfileCounters,

    pub const Mode = @import("mode.zig").Mode;

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
        pager_mode: bool, // True when the current diff comes from stdin and cannot be refreshed from git
        git_repo_root: []const u8, // Git repository root, or current directory while viewing stdin input
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
        viewport_width: usize,
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
        help_scroll_offset: usize, // Scroll position in help overlay

        // Branch selection state (loaded list, filtering)
        branch_select: branch_selection_mode.BranchSelectState = .{},

        // Commit selection state (loading, filtering, diff-mode submenu)
        commit_select: commit_selection_mode.CommitSelectState = .{},

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
        graphite: graphite_controller.GraphiteState = .{},

        // Model selection state
        model_select: model_selection_mode.ModelSelectState = .{},
        permission_selection: usize, // Selected index in permission mode picker

        // Agent selection state (for choosing which agent to connect to)
        configured_agents: ?[]acp.AgentInfo, // Available agents from config or fallback
        agent_selection_idx: usize, // Selected index in agent picker

        // Tab waiting for agent selection (after :new_tab)
        pending_tab_for_selection: ?u32,

        // PR review picker state (defaulted, so it stays out of the init literal)
        pr: pr_controller.PrReviewState = .{},

        // Native GitHub PR review session (async entry + review data). Defaulted.
        review: review_controller.ReviewSession = .{},

        // Submit-review dialog body editor (Phase 5). Non-null only while the
        // dialog is open. Defaulted null (stays out of the init literal); the
        // editor buffer is large so it is only allocated on demand.
        review_submit_editor: ?comment_editor.CommentEditor.VimEditor.State = null,

        // Boot straight into this PR number when set (`skim pr <n|url>`).
        pr_boot_number: ?u32 = null,

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
        const is_pr_only = if (@hasField(@TypeOf(config), "pr_only")) config.pr_only else false;

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
        const files = if (is_agent_only or is_pr_only) blk: {
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
        var built_line_map = try line_map.LineMap.build(allocator, files, &comment_store, .all, true, null, null);
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

        var app = App{
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
                .viewport_width = 0,
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
                .help_scroll_offset = 0,
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
            .blame = blame_ctrl.Blame.init(allocator),
            .pending_connection = null,
            .pending_agent_connect_idx = null,
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

        app.state.pr.pr_only = is_pr_only;
        app.state.pr_boot_number = if (@hasField(@TypeOf(config), "pr_request")) config.pr_request else null;

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

        var built_line_map = try line_map.LineMap.build(allocator, files, &comment_store, .all, true, null, null);
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
                .viewport_width = 0,
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
                .help_scroll_offset = 0,
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
            .blame = blame_ctrl.Blame.init(allocator),
            .pending_connection = null,
            .pending_agent_connect_idx = null,
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

        var built_line_map = try line_map.LineMap.build(allocator, files, &comment_store, .all, true, null, null);
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
                .viewport_width = 0,
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
                .help_scroll_offset = 0,
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
            .blame = blame_ctrl.Blame.init(allocator),
            .pending_connection = null,
            .pending_agent_connect_idx = null,
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
            self.allocator.free(entry.value_ptr.file_path);
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
        self.state.branch_select.deinit(self.allocator);
        self.state.commit_select.deinit(self.allocator);
        self.state.expanded_comments.deinit();
        self.state.collapsed_folds.deinit();
        self.state.branch_stats_cache.deinit();
        self.state.model_select.deinit(self.allocator);
        // Clean up cached default branch name
        if (self.state.default_branch_name) |name| {
            self.allocator.free(name);
        }
        // Clean up graphite stack
        self.state.graphite.deinit(self.allocator);
        // Clean up PR review state (joins any in-flight loader first so its
        // worker can't write into freed state).
        pr_controller.deinitState(&self.state.pr, self.allocator);
        // Clean up native GitHub review session (joins its in-flight worker too).
        review_controller.deinitState(&self.state.review, self.allocator);
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
        self.blame.deinit();
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
        if (self.pending_agent_connect_idx != null) return true;
        if (self.tab_manager) |*tm| {
            if (tm.activeTab()) |tab| {
                return tab.isSessionInitializing();
            }
        }
        return false;
    }

    pub fn getPendingAgentInfo(self: *const App) ?*const acp.AgentInfo {
        const idx = self.pending_agent_connect_idx orelse return null;
        const agents = self.state.configured_agents orelse return null;
        if (idx >= agents.len) return null;
        return &agents[idx];
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

    /// Thin forwarder: steps the active debug replay, wiring app-level services
    /// into the controller. Retained because many call sites (tests, agent mode)
    /// only hold an `*App`.
    pub fn stepActiveDebugReplay(self: *App) !bool {
        return debug_replay_controller.step(.{
            .allocator = self.allocator,
            .agent_state = self.getActiveAgentState(),
            .manager = self.getActiveManager(),
            .needs_render = &self.needs_render,
        });
    }

    /// Thin forwarder: tears down the active replay via the controller, then
    /// applies the app-lifecycle side effects (quit / panel visibility / mode).
    pub fn exitActiveDebugReplay(self: *App) void {
        const agent_state = self.getActiveAgentState() orelse return;
        const quit_app = debug_replay_controller.exit(agent_state);

        if (quit_app) {
            self.should_quit = true;
            return;
        }

        if (self.tab_manager) |*tm| {
            tm.panel_visible = false;
        }
        agent_state.visible = false;
        self.mode = .normal;
        self.needs_render = true;
    }

    /// Auto-name the active tab from the user's first prompt
    pub fn autoNameActiveTab(self: *App, prompt: []const u8) void {
        if (self.tab_manager) |*tm| {
            if (tm.activeTab()) |tab| {
                tab.autoNameFromPrompt(prompt) catch {};
            }
        }
    }

    fn ensureGitRepositoryContext(self: *App) !bool {
        if (!self.state.pager_mode) return true;

        const git_repo_root = git.getRepoRoot(self.allocator) catch |err| switch (err) {
            error.GitCommandFailed => {
                self.showStatusMessage("Git-backed diffs require a git repository");
                return false;
            },
            else => return err,
        };

        self.allocator.free(self.state.git_repo_root);
        self.state.git_repo_root = git_repo_root;
        return true;
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

        // Re-derive review-thread anchors against the freshly parsed diff (AD-4)
        // before building the map that will emit their records.
        self.reanchorReview(new_files);

        // Rebuild line map with new files (preserve hunk view mode and fold state)
        const new_line_map = try line_map.LineMap.build(self.allocator, new_files, &self.state.comment_store, hunk_view.convertHunkViewMode(self), hunk_view.shouldApplyHunkFiltering(self), &self.state.collapsed_folds, self.reviewAnchored());
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
        graphite_controller.refreshStack(&self.state.graphite, self.allocator);

        // Keep external session discovery metadata in sync with the current diff.
        mcp_handlers.syncSessionMetadata(self);
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

        // Enable mouse reporting so the wheel can scroll the diff and panels.
        // vaxis disables it automatically on deinit.
        try vx.setMouseMode(writer, true);

        // Start TUI server for CLI/MCP connections
        mcp_handlers.startTuiServer(self) catch |err| {
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
            connect.startAcpSession(self) catch |err| {
                std.log.err("Failed to start ACP session: {any}", .{err});
            };
        }

        // If launched as `skim pr`, open straight into the PR picker and kick off
        // the background load so the first frame shows the cached/loading list.
        // `skim pr <n|url>` instead enters that PR directly, off-thread.
        if (self.state.pr.pr_only) {
            self.mode = .pr_review;
            if (self.state.pr_boot_number) |number| {
                var msg_buf: [64]u8 = undefined;
                const loading = std.fmt.bufPrint(&msg_buf, "Loading PR #{d}…", .{number}) catch "Loading PR…";
                pr_controller.setMessage(&self.state.pr, loading);
                review_controller.startEnterPr(&self.state.review, self.allocator, .{ .number = number }) catch |err| {
                    std.log.err("Failed to start PR entry: {any}", .{err});
                    pr_controller.setMessage(&self.state.pr, "failed to start PR entry");
                };
            } else {
                pr_controller.startListLoad(&self.state.pr, self.allocator) catch |err| {
                    std.log.err("Failed to start PR load: {any}", .{err});
                };
            }
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
            const replay_playing = debug_replay_controller.isPlaying(self.getActiveAgentStateConst());
            // Check if a shell command is running (needs streaming output) - check all tabs
            const shell_cmd_running = self.hasAnyRunningShellCommand();
            // Check if a connection thread is running (need to poll for completion)
            const connecting = self.pending_connection != null;
            const blame_active = self.blame.isActive();
            const pr_active = self.state.pr.fetch.ready.load(.acquire) or self.state.pr.fetch_in_flight;
            const review_active = self.state.review.entry.ready.load(.acquire) or self.state.review.entry_in_flight or review_controller.hasPostingWork(&self.state.review);
            const should_poll = !self.needs_render and self.pending_highlight_jobs.count() == 0 and !server_active and !stats_loading and !manager_active and !replay_playing and !shell_cmd_running and !connecting and !blame_active and !pr_active and !review_active;
            if (should_poll) {
                loop.pollEvent();
            } else {
                // Adaptive sleep based on activity level:
                // - High activity (prompting): 5ms for smooth streaming (~200 FPS)
                // - Medium activity (connecting, shell running): 8ms (~125 FPS)
                // - Low activity (just rendering): 16ms (~60 FPS)
                const is_high_activity = manager_active or replay_playing or shell_cmd_running;
                const is_medium_activity = connecting or server_active;
                const sleep_ms: u64 = if (is_high_activity) 5 else if (is_medium_activity) 8 else 16;
                std.Thread.sleep(sleep_ms * std.time.ns_per_ms);
            }
            // When not blocking (acp_active, mcp_active, etc.), events are still
            // captured by the vaxis reader thread and available via tryEvent()

            debug_replay_controller.advanceIfDue(.{
                .allocator = self.allocator,
                .agent_state = self.getActiveAgentState(),
                .manager = self.getActiveManager(),
                .needs_render = &self.needs_render,
            });

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

                // Suspending for the editor resets terminal state, so
                // re-assert mouse reporting.
                try vx.setMouseMode(tty.writer(), true);

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
                    connect.pollAllManagers(self);
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
            subagent_fetch.pollSubagentFetch(self);
            if (blame_ctrl.pollPending(&self.blame, self.profile_render)) self.needs_render = true;
            if (pr_controller.pollPendingFetch(&self.state.pr, self.allocator)) self.needs_render = true;
            self.pollReviewEntry();
            self.pollReviewMutations();
            self.pollReviewThreadMutations();
            self.pollReviewSubmit();

            // Render if we had events, need to update, or first render
            if (had_events or self.needs_render or first_render) {
                const win = vx.window();

                if (profiling_enabled) {
                    const profile_log = std.log.scoped(.profile_loop);
                    _ = self.shouldProfileFrame();

                    if (self.profile_active_frame) {
                        var render_timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try frame.render(self, win);
                        const render_ns: u64 = if (render_timer_opt) |*timer| timer.read() else 0;

                        var vx_timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
                        try vx.render(tty.writer());
                        const vx_ns: u64 = if (vx_timer_opt) |*timer| timer.read() else 0;

                        profile_log.debug(
                            "frame {d}: render_ns={d} vx_ns={d} events={} needs_render={} pending_jobs={d}",
                            .{ self.profile_frame_counter, render_ns, vx_ns, had_events, self.needs_render, self.pending_highlight_jobs.count() },
                        );
                    } else {
                        try frame.render(self, win);
                        try vx.render(tty.writer());
                    }

                    self.profile_active_frame = false;
                } else {
                    try frame.render(self, win);
                    try vx.render(tty.writer());
                }
                // Don't clear needs_render if we're about to suspend for editor
                // This prevents blocking on the next pollEvent()
                if (!self.should_suspend_for_editor) {
                    self.needs_render = false; // Clear the flag after rendering
                }
            }

            if (self.pending_agent_connect_idx != null) {
                connect.startQueuedAgentConnection(self) catch |err| {
                    std.log.err("Failed to start queued agent connection: {any}", .{err});
                    self.pending_agent_connect_idx = null;
                    self.showStatusMessage("Failed to start connection");
                };
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
                        self.allocator.free(entry.value.file_path);
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

                            const file_path_copy = self.allocator.dupe(u8, file_path) catch {
                                self.allocator.free(content);
                                self.allocator.free(old_content);
                                continue;
                            };
                            errdefer self.allocator.free(file_path_copy);

                            self.pending_highlight_jobs.put(key, .{
                                .file_path = file_path_copy,
                                .content = content,
                                .old_content = old_content,
                            }) catch {
                                self.allocator.free(file_path_copy);
                                self.allocator.free(content);
                                self.allocator.free(old_content);
                                continue;
                            };

                            worker.submitJob(.{
                                .file_path = file_path_copy,
                                .content = content,
                                .old_content = old_content,
                                .file_idx = check_idx,
                                .hunk_idx = hunk_idx,
                            }) catch {
                                if (self.pending_highlight_jobs.fetchRemove(key)) |entry| {
                                    self.allocator.free(entry.value.file_path);
                                    self.allocator.free(entry.value.content);
                                    self.allocator.free(entry.value.old_content);
                                }
                                continue;
                            };

                            hunks_submitted += 1;
                        }
                    }
                }

                // Reset the flag after processing
                self.needs_async_highlight = false;
            }

            if (self.state.show_blame) {
                blame_ctrl.requestBlameForViewport(&self.blame, self.blameViewportParams());
            }
        }

        // Exit alt screen before returning
        try vx.exitAltScreen(tty.writer());
    }

    fn handleEvent(self: *App, event: Event) !void {
        switch (event) {
            .key_press => |key| try self.handleKey(key),
            .mouse => |m| try self.handleMouse(m),
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

    /// Translate a mouse-wheel notch into the navigation keystroke the active
    /// mode binds for line scrolling, routed through the normal keyboard
    /// dispatch so every surface reuses its existing scroll behavior. Non-wheel
    /// mouse events (clicks, drags, motion) are ignored.
    fn handleMouse(self: *App, m: vaxis.Mouse) !void {
        const down = switch (m.button) {
            .wheel_down => true,
            .wheel_up => false,
            else => return,
        };
        const codepoint = mouse.wheelKeyForMode(self.mode, down) orelse return;
        var i: usize = 0;
        while (i < mouse.lines_per_notch) : (i += 1) {
            try self.handleKey(.{ .codepoint = codepoint });
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
                    self.state.branch_select.search_len = 0;
                    self.state.branch_select.filtered.clearRetainingCapacity();
                    self.needs_render = true;
                    return;
                },
                .commit_selection => {
                    self.mode = .normal;
                    self.state.commit_select.search_len = 0;
                    self.state.commit_select.filtered.clearRetainingCapacity();
                    self.needs_render = true;
                    return;
                },
                .commit_diff_mode => {
                    // Go back to commit selection
                    self.mode = .commit_selection;
                    // Free the selected commit
                    if (self.state.commit_select.selected_for_diff) |*commit| {
                        commit.deinit(self.allocator);
                        self.state.commit_select.selected_for_diff = null;
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
                .pr_review => {
                    // Ctrl+C is a back button, peeling one layer at a time:
                    // author overlay -> list, then list -> the diff being
                    // reviewed (or quit if `skim pr` has nothing behind it).
                    if (self.state.pr.picking_author) {
                        pr_controller.closeAuthorPicker(&self.state.pr, self.allocator);
                    } else if (self.state.pr.pr_only) {
                        self.should_quit = true;
                    } else {
                        self.mode = .normal;
                    }
                    self.needs_render = true;
                    return;
                },
                .review_submit => {
                    self.closeReviewSubmit();
                    self.needs_render = true;
                    return;
                },
                .pr_info => {
                    self.mode = .normal;
                    self.needs_render = true;
                    return;
                },
                .agent => {
                    // In agent mode, single Ctrl+C closes subagent drill-in first,
                    // then exits history mode.
                    if (self.getActiveAgentState()) |agent_state| {
                        if (agent_state.hasSubagentModal()) {
                            agent_state.closeSubagentModal();
                            self.needs_render = true;
                            return;
                        }
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
            .pr_review => try pr_review_mode.handleKey(self, key),
            .review_submit => try review_submit_mode.handleKey(self, key),
            .pr_info => try pr_info_mode.handleKey(self, key),
            .agent => try agent_mode.handleKey(self, key),
        }
    }

    pub fn toggleViewMode(self: *App) void {
        // Capture viewport anchor before toggle (anchor to viewport top for stable view)
        const anchor = hunk_view.captureViewportAnchor(self, self.state.global_scroll_offset);

        // Toggle view mode
        self.state.view_mode = switch (self.state.view_mode) {
            .unified => .side_by_side,
            .side_by_side => .unified,
        };

        // Rebuild LineMap because filtering rules changed
        // Side-by-side: always show all lines (filtering=false)
        // Unified: apply current hunk view mode (filtering=true)
        hunk_view.rebuildLineMap(self) catch |err| {
            std.log.err("Failed to rebuild LineMap on view toggle: {any}", .{err});
            return;
        };

        // Restore viewport position from anchor
        _ = hunk_view.restoreViewportFromAnchor(self, anchor);
    }

    pub fn toggleBlame(self: *App) void {
        // Disabled in pager mode
        if (self.state.pager_mode) return;

        self.state.show_blame = !self.state.show_blame;
        self.needs_render = true;

        if (self.state.show_blame) {
            blame_ctrl.requestBlameForViewport(&self.blame, self.blameViewportParams());
        }
    }

    /// Build the viewport snapshot the blame controller needs to prefetch blame.
    fn blameViewportParams(self: *App) blame_ctrl.ViewportParams {
        return .{
            .show_blame = self.state.show_blame,
            .pager_mode = self.state.pager_mode,
            .files = self.state.files,
            .viewport_height = self.state.viewport_height,
            .global_scroll_offset = self.state.global_scroll_offset,
            .line_map = &self.state.line_map,
        };
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
                try connect.startAcpSession(self);
            }
        }

        self.needs_render = true;
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
            .file_header, .hunk_header, .comment_line, .review_thread, .spacer => null,
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
            .file_header, .review_thread, .spacer => {
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
                self.state.configured_agents = connect.loadConfiguredAgents(self);
                self.state.agent_selection_idx = 0;
                self.mode = .agent_selection;
            },
            .select_commit => {
                try self.startCommitSelection();
            },
            .enter_pr_review => {
                try pr_controller.startListLoad(&self.state.pr, self.allocator);
                self.mode = .pr_review;
            },
        }
    }

    /// Open the branch picker. Thin cross-cutting forwarder: gates on git repo
    /// context, resets/loads the sub-state via the controller, then owns the
    /// App mode transition.
    pub fn startBranchSelection(self: *App) !void {
        if (!try self.ensureGitRepositoryContext()) return;

        try branch_selection_mode.start(&self.state.branch_select, self.allocator);

        self.mode = .branch_selection;
    }

    // =========================================================================
    // Commit Selection
    // =========================================================================

    /// Open the commit picker. Thin cross-cutting forwarder: gates on git repo
    /// context, resets/loads the sub-state via the controller, then owns the
    /// App mode transition.
    pub fn startCommitSelection(self: *App) !void {
        if (!try self.ensureGitRepositoryContext()) return;

        try commit_selection_mode.start(&self.state.commit_select, self.allocator);

        self.mode = .commit_selection;
    }

    /// Apply the selected diff mode with the chosen commit. Cross-cutting:
    /// rebuilds `state.diff_source` and drives an App refresh, so it stays here
    /// rather than in the commit-selection controller.
    pub fn applyCommitDiff(self: *App) !void {
        const commit = self.state.commit_select.selected_for_diff orelse return;

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

        if (self.state.commit_select.diff_mode_selection == 0) {
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
        if (self.state.commit_select.selected_for_diff) |*c| {
            c.deinit(self.allocator);
            self.state.commit_select.selected_for_diff = null;
        }

        // Go back to normal mode and refresh
        self.state.pager_mode = false;
        self.mode = .normal;
        try self.refresh();
    }

    // Graphite stack functions

    /// Open the Graphite stack picker. Thin cross-cutting forwarder: runs lazy
    /// detection via the controller, then owns App mode/status transitions.
    pub fn startGraphiteStack(self: *App) !void {
        if (!try self.ensureGitRepositoryContext()) return;

        graphite_controller.ensureDetected(&self.state.graphite, self.allocator);

        if (!self.state.graphite.available) {
            self.state.status_message = "Graphite CLI (gt) not installed";
            self.state.status_message_time = std.time.milliTimestamp();
            return;
        }

        // Use cached stack - don't re-fetch (that's slow)
        // Stack is refreshed on app refresh ('r' key)
        if (self.state.graphite.stack) |stack| {
            self.state.graphite.selection = stack.current_idx;
            self.mode = .graphite_stack;
        } else {
            self.state.status_message = "Not in a Graphite stack";
            self.state.status_message_time = std.time.milliTimestamp();
        }
    }

    // =========================================================================
    // PR Review (native `skim pr` / `:pr`)
    // =========================================================================

    /// Review the highlighted PR natively: fetch its head + base into local refs
    /// (no worktree) and swap the diff to `origin/<base>...refs/skim/pr-<n>`.
    pub fn reviewSelectedPr(self: *App) !void {
        const pull = pr_controller.selected(&self.state.pr) orelse return;
        try self.selectPullRequest(pull);
    }

    /// Begin reviewing a PR selected from the picker. Kicks off the async entry
    /// worker (git fetch + gh review fetch) off-thread and returns immediately —
    /// the main loop's `pollReviewEntry` swaps the diff once the fetch lands, so
    /// the picker never freezes. Stays in `.pr_review` mode (with a "Loading…"
    /// message) until entry completes.
    pub fn selectPullRequest(self: *App, pull: pr.PullRequest) !void {
        var msg_buf: [64]u8 = undefined;
        const loading = std.fmt.bufPrint(&msg_buf, "Loading PR #{d}…", .{pull.number}) catch "Loading PR…";
        pr_controller.setMessage(&self.state.pr, loading);

        review_controller.startEnterPr(&self.state.review, self.allocator, .{
            .number = pull.number,
            .base_ref = pull.base_ref,
            .title = pull.title,
            .url = pull.url,
        }) catch {
            pr_controller.setMessage(&self.state.pr, "failed to start PR entry");
        };
        self.needs_render = true;
    }

    /// Consume a completed PR entry/refetch from the review worker. On entry,
    /// swaps the diff source to `origin/<base>...refs/skim/pr-<n>`; on graceful
    /// degradation (git ok, gh failed) still enters and surfaces the reason.
    fn pollReviewEntry(self: *App) void {
        switch (review_controller.pollPending(&self.state.review, self.allocator)) {
            .none => {},
            .entered => |info| {
                defer self.allocator.free(info.head_ref);
                defer self.allocator.free(info.base_ref);
                self.enterReviewDiff(info.head_ref, info.base_ref) catch |err| {
                    std.log.err("Failed to enter PR diff: {any}", .{err});
                    pr_controller.setMessage(&self.state.pr, "failed to open PR diff");
                    self.needs_render = true;
                    return;
                };
                if (info.gh_error) |kind| {
                    self.showStatusMessage(pr.github.kindMessage(kind));
                }
                self.needs_render = true;
            },
            .refreshed => |gh_error| {
                if (gh_error) |kind| self.showStatusMessage(pr.github.kindMessage(kind));
                // Refetch replaced the thread set; re-anchor + rebuild so the new
                // threads render (the diff files are unchanged, so no full refresh).
                self.rebuildReviewLineMap();
                self.needs_render = true;
            },
            .fetch_failed => {
                pr_controller.setMessage(&self.state.pr, "fetch failed — is gh/git authenticated?");
                self.needs_render = true;
            },
        }
    }

    /// Consume a completed draft-post mutation. On success the placeholder became
    /// a real server thread, so re-anchor + rebuild the LineMap; on failure surface
    /// the classified error (the body is stashed for the next comment-open).
    fn pollReviewMutations(self: *App) void {
        switch (review_controller.pollMutations(&self.state.review, self.allocator)) {
            .none => {},
            .posted => {
                self.rebuildReviewLineMap();
                self.showStatusMessage("draft comment posted");
                self.needs_render = true;
            },
            .failed => |kind| {
                self.rebuildReviewLineMap();
                self.showStatusMessage(pr.github.kindMessage(kind));
                self.needs_render = true;
            },
        }
    }

    /// Consume a completed thread interaction (reply / resolve / edit / delete).
    /// On success the local model was already updated in place, so re-anchor +
    /// rebuild the LineMap; on failure surface the classified error (reply/edit
    /// bodies are stashed for the next editor-open).
    fn pollReviewThreadMutations(self: *App) void {
        switch (review_controller.pollThreadMutations(&self.state.review, self.allocator)) {
            .none => {},
            .applied => |kind| {
                self.rebuildReviewLineMap();
                self.showStatusMessage(threadMutationAppliedMessage(kind));
                self.needs_render = true;
            },
            .failed => |info| {
                self.rebuildReviewLineMap();
                self.showStatusMessage(pr.github.kindMessage(info.err));
                self.needs_render = true;
            },
        }
    }

    fn threadMutationAppliedMessage(kind: review_controller.ThreadMutationKind) []const u8 {
        return switch (kind) {
            .reply => "reply posted",
            .resolve => "thread resolved",
            .unresolve => "thread unresolved",
            .edit => "comment updated",
            .delete => "comment deleted",
        };
    }

    /// Consume a completed submit/discard (Phase 5). On success the dialog closes
    /// and a refetch pulls authoritative post-submit data; on failure the dialog
    /// stays open with the classified error (the body is preserved for retry).
    fn pollReviewSubmit(self: *App) void {
        switch (review_controller.pollSubmit(&self.state.review, self.allocator)) {
            .none => {},
            .submitted => |verdict| {
                self.state.review_submit_editor = null;
                self.mode = .normal;
                self.rebuildReviewLineMap();
                self.showStatusMessage(submittedMessage(verdict));
                self.startReviewRefetch();
                self.needs_render = true;
            },
            .discarded => {
                self.state.review_submit_editor = null;
                self.mode = .normal;
                self.rebuildReviewLineMap();
                self.showStatusMessage("pending review discarded");
                self.needs_render = true;
            },
            .submit_failed, .discard_failed => {
                self.showStatusMessage("submit failed — see dialog");
                self.needs_render = true;
            },
        }
    }

    fn submittedMessage(verdict: review_controller.Verdict) []const u8 {
        return switch (verdict) {
            .comment => "review submitted (comment)",
            .approve => "review submitted (approve)",
            .request_changes => "review submitted (request changes)",
        };
    }

    /// Open the submit-review dialog for the active session (bound to `R`). Inits
    /// the body editor (restoring any Esc-stashed body) and switches to the
    /// dialog mode. No-op when no review session is active.
    pub fn openReviewSubmit(self: *App) void {
        if (!review_controller.isActive(&self.state.review)) return;
        // A submit's pending-review create must not race an in-flight draft post
        // (double-create). Refuse to open the dialog until posts settle.
        if (review_controller.hasThreadWriteWork(&self.state.review)) {
            self.showStatusMessage("drafts still posting — try again in a moment");
            self.needs_render = true;
            return;
        }
        var editor_state = comment_editor.CommentEditor.VimEditor.State.init();
        if (review_controller.submitBodyStash(&self.state.review)) |stash| {
            editor_state.setText(stash);
        }
        self.state.review_submit_editor = editor_state;
        review_controller.disarmDiscardConfirm(&self.state.review);
        self.mode = .review_submit;
        self.needs_render = true;
    }

    /// Close the submit dialog (Esc / Ctrl-C), preserving the in-progress body so
    /// a reopen restores it (AD-8), and return to the diff.
    pub fn closeReviewSubmit(self: *App) void {
        if (self.state.review_submit_editor) |*ed| {
            review_controller.stashSubmitBody(&self.state.review, self.allocator, ed.getText());
        }
        self.state.review_submit_editor = null;
        review_controller.disarmDiscardConfirm(&self.state.review);
        self.mode = .normal;
        self.needs_render = true;
    }

    /// Fire the submit with the dialog's current body + verdict. Surfaces the
    /// client-side refusal (empty body / no review) as a status message; on
    /// `.started` the async worker runs and `pollReviewSubmit` consumes it.
    pub fn submitReviewNow(self: *App) void {
        const body = if (self.state.review_submit_editor) |*ed| ed.getText() else "";
        const action = review_controller.startSubmit(&self.state.review, self.allocator, body) catch {
            self.showStatusMessage("failed to start submit");
            return;
        };
        switch (action) {
            .started => self.showStatusMessage("submitting review…"),
            .refused_empty => self.showStatusMessage("nothing to submit — add a body or drafts"),
            .refused_no_review => self.showStatusMessage("no active review"),
            .busy => self.showStatusMessage("a submit is already in progress"),
        }
        self.needs_render = true;
    }

    /// Fire a discard of the pending review (second Ctrl-D). Surfaces refusals.
    pub fn discardReviewNow(self: *App) void {
        const action = review_controller.startDiscard(&self.state.review, self.allocator) catch {
            self.showStatusMessage("failed to start discard");
            return;
        };
        switch (action) {
            .started => self.showStatusMessage("discarding pending review…"),
            .refused_no_review => self.showStatusMessage("no pending review to discard"),
            .refused_empty, .busy => self.showStatusMessage("a submit is already in progress"),
        }
        review_controller.disarmDiscardConfirm(&self.state.review);
        self.needs_render = true;
    }

    /// Open the read-only PR info panel (bound to `i`). No-op without a session.
    pub fn openPrInfo(self: *App) void {
        if (!review_controller.isActive(&self.state.review)) return;
        self.state.review.info_scroll = 0;
        self.mode = .pr_info;
        self.needs_render = true;
    }

    /// Swap the diff to the fetched PR refs and refresh. `head_ref` is the local
    /// ref from `git fetch` (e.g. `refs/skim/pr-42`); `base_ref` is the base
    /// branch name (empty → diff against HEAD).
    fn enterReviewDiff(self: *App, head_ref: []const u8, base_ref: []const u8) !void {
        const ref2 = try self.allocator.dupe(u8, head_ref);
        errdefer self.allocator.free(ref2);
        const ref1 = if (base_ref.len > 0)
            try std.fmt.allocPrint(self.allocator, "origin/{s}", .{base_ref})
        else
            try self.allocator.dupe(u8, "HEAD");
        errdefer self.allocator.free(ref1);

        switch (self.state.diff_source) {
            .working_dir, .stdin => {},
            .single_ref => |sr| self.allocator.free(sr.ref),
            .two_refs => |tr| {
                self.allocator.free(tr.ref1);
                self.allocator.free(tr.ref2);
            },
        }

        self.state.diff_source = DiffSource{ .two_refs = .{
            .ref1 = ref1,
            .ref2 = ref2,
            .use_merge_base = true,
        } };

        pr_controller.setMessage(&self.state.pr, "");
        self.state.pager_mode = false;
        self.mode = .normal;
        try self.refresh();
    }

    /// Anchored review threads for the active session, or null when no session
    /// is active / no threads anchored. Passed into `LineMap.build`.
    pub fn reviewAnchored(self: *App) ?[]const thread_placement.AnchoredThread {
        if (!review_controller.isActive(&self.state.review)) return null;
        if (self.state.review.anchored.len == 0) return null;
        return self.state.review.anchored;
    }

    /// Re-derive review-thread anchors against `files` (AD-4: anchors are never
    /// persisted — every diff refresh recomputes them). No-op-safe when no
    /// session is active. Must run before any `LineMap.build` on a new diff.
    fn reanchorReview(self: *App, files: []const parser.FileDiff) void {
        if (!review_controller.isActive(&self.state.review)) {
            review_controller.freeAnchored(&self.state.review, self.allocator);
            return;
        }
        // Anchors reference threads by positional index; a transient view over the
        // session's SessionThread list feeds the pure anchorer (AD-4/AD-6).
        const view = review_controller.threadDataView(&self.state.review, self.allocator) catch {
            review_controller.freeAnchored(&self.state.review, self.allocator);
            return;
        };
        defer self.allocator.free(view);
        const anchored = thread_anchor.anchorThreads(self.allocator, view, files) catch {
            review_controller.freeAnchored(&self.state.review, self.allocator);
            return;
        };
        review_controller.setAnchored(&self.state.review, self.allocator, anchored, thread_placement.countUnplaced(anchored));
    }

    /// Re-anchor against the current diff and rebuild the LineMap in place. Used
    /// after a review refetch (`r`), which replaces threads without touching the
    /// diff files, so `refresh()` would be wasteful — only the thread records change.
    pub fn rebuildReviewLineMap(self: *App) void {
        self.reanchorReview(self.state.files);
        const rebuilt = line_map.LineMap.build(
            self.allocator,
            self.state.files,
            &self.state.comment_store,
            hunk_view.convertHunkViewMode(self),
            hunk_view.shouldApplyHunkFiltering(self),
            &self.state.collapsed_folds,
            self.reviewAnchored(),
        ) catch |err| {
            std.log.err("Failed to rebuild LineMap after review refetch: {any}", .{err});
            return;
        };
        self.state.line_map.deinit();
        self.state.line_map = rebuilt;
        const total_lines = self.getTotalGlobalLines();
        if (total_lines > 0 and self.state.global_cursor_line >= total_lines) {
            self.state.global_cursor_line = total_lines - 1;
        }
        Navigation.clampScrollOffset(self);
    }

    /// Re-fetch review data for the active session (bound to the `r` refresh).
    /// No-op when no session is active or a fetch is already running.
    pub fn startReviewRefetch(self: *App) void {
        review_controller.startRefetch(&self.state.review, self.allocator) catch |err| {
            std.log.warn("Failed to start review refetch: {any}", .{err});
        };
    }

    /// Esc peels back one layer at a time: query, then the pinned author, then
    /// leave — so a stray Esc never drops you out with filters still applied.
    /// Owns App mode/quit state, so it stays a thin cross-cutting forwarder.
    pub fn prClearOrLeave(self: *App) void {
        const p = &self.state.pr;
        if (p.query_len > 0) {
            p.query_len = 0;
            pr_controller.rebuildFilter(p, self.allocator);
        } else if (p.author_len > 0) {
            p.author_len = 0;
            pr_controller.rebuildFilter(p, self.allocator);
        } else if (p.pr_only) {
            self.should_quit = true;
        } else {
            self.mode = .normal;
        }
    }

    pub fn selectGraphiteStackBranch(self: *App, idx: usize) !void {
        const stack = self.state.graphite.stack orelse return;
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
        self.state.graphite.stack.?.current_idx = idx;

        // Go back to normal mode and refresh
        self.state.pager_mode = false;
        self.mode = .normal;
        try self.refresh();
    }

    /// Navigate to parent branch (toward trunk, visually down in stack display)
    pub fn navigateStackToParent(self: *App) !void {
        const stack = self.state.graphite.stack orelse {
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
        const stack = self.state.graphite.stack orelse {
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
        if (!try self.ensureGitRepositoryContext()) return;

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
        self.state.pager_mode = false;
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
    pub fn getVisualSelection(self: *App) ?struct { start: usize, end: usize } {
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
                return width_util.sliceByDisplayWidth(text, max_width);
            }
            var timer_opt: ?std.time.Timer = std.time.Timer.start() catch null;
            const slice = width_util.sliceByDisplayWidth(text, max_width);
            if (timer_opt) |*timer| {
                self.profile_counters.slice_ns += timer.read();
            }
            self.profile_counters.slice_calls += 1;
            return slice;
        }

        return width_util.sliceByDisplayWidth(text, max_width);
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
                .review_thread => {
                    // Threads are not part of the yankable diff text.
                },
                .spacer => {
                    // Skip spacer lines
                },
            }
        }

        try clipboard.copyToClipboard(self.allocator, buffer.items);
    }

    /// Show a temporary status message (displayed for 3 seconds)
    /// Note: This duplicates the message, so caller can free their copy.
    pub fn showStatusMessage(self: *App, message: []const u8) void {
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

test "queueSelectedAgentConnection switches to agent mode and queues selection" {
    const allocator = std.testing.allocator;

    const agents = [_]acp.AgentInfo{
        .{
            .name = "Codex",
            .command = "codex",
            .args = &.{},
            .protocol = .codex,
        },
    };

    var app = App{
        .allocator = allocator,
        .vx = undefined,
        .tty = undefined,
        .mode = .agent_selection,
        .state = undefined,
        .should_quit = false,
        .should_suspend_for_editor = false,
        .editor_file_path = null,
        .editor_line_number = null,
        .editor_is_prompt_edit = false,
        .last_ctrl_c = 0,
        .header_line_buffers = undefined,
        .frame_text_buffer = &.{},
        .frame_text_used = 0,
        .frame_segment_arena = std.heap.ArenaAllocator.init(allocator),
        .syntax_highlighter = undefined,
        .highlight_worker = null,
        .pending_highlight_jobs = std.AutoHashMap(HunkKey, PendingJob).init(allocator),
        .needs_render = false,
        .needs_async_highlight = false,
        .tui_server = null,
        .session_manager = null,
        .blame = blame_ctrl.Blame.init(allocator),
        .pending_connection = null,
        .pending_agent_connect_idx = null,
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
    defer app.pending_highlight_jobs.deinit();
    defer app.blame.deinit();
    defer app.frame_segment_arena.deinit();

    app.state.configured_agents = &agents;
    app.state.agent_selection_idx = 0;

    connect.queueSelectedAgentConnection(&app);

    try std.testing.expectEqual(App.Mode.agent, app.mode);
    try std.testing.expect(app.needs_render);
    try std.testing.expectEqual(@as(?usize, 0), app.pending_agent_connect_idx);
    try std.testing.expectEqualStrings("Codex", app.getPendingAgentInfo().?.name);
}

test "isSessionInitializing returns true for queued agent connection" {
    const allocator = std.testing.allocator;

    var app = App{
        .allocator = allocator,
        .vx = undefined,
        .tty = undefined,
        .mode = .agent,
        .state = undefined,
        .should_quit = false,
        .should_suspend_for_editor = false,
        .editor_file_path = null,
        .editor_line_number = null,
        .editor_is_prompt_edit = false,
        .last_ctrl_c = 0,
        .header_line_buffers = undefined,
        .frame_text_buffer = &.{},
        .frame_text_used = 0,
        .frame_segment_arena = std.heap.ArenaAllocator.init(allocator),
        .syntax_highlighter = undefined,
        .highlight_worker = null,
        .pending_highlight_jobs = std.AutoHashMap(HunkKey, PendingJob).init(allocator),
        .needs_render = false,
        .needs_async_highlight = false,
        .tui_server = null,
        .session_manager = null,
        .blame = blame_ctrl.Blame.init(allocator),
        .pending_connection = null,
        .pending_agent_connect_idx = 0,
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
    defer app.pending_highlight_jobs.deinit();
    defer app.blame.deinit();
    defer app.frame_segment_arena.deinit();

    try std.testing.expect(app.isSessionInitializing());
}

test "stdin-backed app can switch to staged diff" {
    const allocator = std.testing.allocator;

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch unreachable;

    try setupGitRepoWithWorkingAndStagedChanges(allocator, tmp.dir);

    var app = try initPagerModeAppFromWorkingDiff(allocator);
    defer app.deinit();

    try std.testing.expect(app.state.pager_mode);
    try std.testing.expect(app.state.diff_source == .stdin);
    try std.testing.expect(diffContainsLine(app.state.files, "working line"));
    try std.testing.expect(!diffContainsLine(app.state.files, "staged line"));

    try app.switchDiffMode(.staged);

    try std.testing.expect(!app.state.pager_mode);
    try std.testing.expect(app.state.diff_source == .working_dir);
    try std.testing.expect(app.state.diff_source.working_dir.staged);
    try std.testing.expect(diffContainsLine(app.state.files, "staged line"));
    try std.testing.expect(!diffContainsLine(app.state.files, "working line"));
}

test "stdin-backed app can open commit selection" {
    const allocator = std.testing.allocator;

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch unreachable;

    try setupGitRepoWithWorkingAndStagedChanges(allocator, tmp.dir);

    var app = try initPagerModeAppFromWorkingDiff(allocator);
    defer app.deinit();

    try std.testing.expect(app.state.pager_mode);
    try std.testing.expect(app.mode == .normal);

    try app.startCommitSelection();

    try std.testing.expect(app.state.pager_mode);
    try std.testing.expect(app.mode == .commit_selection);
    try std.testing.expect(app.state.commit_select.list.items.len > 0);
}

fn setupGitRepoWithWorkingAndStagedChanges(allocator: Allocator, dir: std.fs.Dir) !void {
    try runTestCommand(allocator, &.{ "git", "init", "-q" });
    try runTestCommand(allocator, &.{ "git", "config", "user.email", "skim-test@example.com" });
    try runTestCommand(allocator, &.{ "git", "config", "user.name", "Skim Test" });

    try dir.writeFile(.{ .sub_path = "demo.txt", .data = "base\n" });
    try runTestCommand(allocator, &.{ "git", "add", "demo.txt" });
    try runTestCommand(allocator, &.{ "git", "commit", "-q", "-m", "base" });

    try dir.writeFile(.{ .sub_path = "demo.txt", .data = "base\nstaged line\n" });
    try runTestCommand(allocator, &.{ "git", "add", "demo.txt" });

    try dir.writeFile(.{ .sub_path = "demo.txt", .data = "base\nstaged line\nworking line\n" });
}

fn initPagerModeAppFromWorkingDiff(allocator: Allocator) !App {
    const diff_result = try git.getDiffWithUntracked(allocator, .{ .working_dir = .{ .staged = false } });
    defer diff_result.deinit(allocator);

    const files = try parser.parse(allocator, diff_result.diff_text);
    errdefer {
        for (files) |*file| {
            file.deinit(allocator);
        }
        allocator.free(files);
    }

    parser.markUntrackedFiles(files, diff_result.untracked_paths);
    return App.initForRenderBench(allocator, files);
}

fn diffContainsLine(files: []const parser.FileDiff, expected: []const u8) bool {
    for (files) |file| {
        for (file.hunks) |hunk| {
            for (hunk.lines) |line| {
                if (std.mem.eql(u8, line.content, expected)) {
                    return true;
                }
            }
        }
    }

    return false;
}

fn runTestCommand(allocator: Allocator, argv: []const []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code == 0) return;
        },
        else => {},
    }

    std.debug.print("command failed\nstdout:\n{s}\nstderr:\n{s}\n", .{ result.stdout, result.stderr });
    return error.TestUnexpectedResult;
}
