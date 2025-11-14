const std = @import("std");
const vaxis = @import("vaxis");
const git = @import("git/diff.zig");
const parser = @import("git/parser.zig");
const syntax = @import("syntax.zig");
const comments = @import("comments.zig");
const line_map = @import("line_map.zig");
const navigation = @import("navigation.zig");
const rendering_common = @import("rendering/common.zig");
const render_utils = @import("rendering/utils.zig");
const render_unified = @import("rendering/unified.zig");
const render_side_by_side = @import("rendering/side_by_side.zig");
const state_helpers = @import("state.zig");
const ui_components = @import("ui.zig");
const editor = @import("editor.zig");
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

// Color constants for terminal output
const Color = struct {
    const black = .{ .index = 0 };
    const red = .{ .index = 1 };
    const green = .{ .index = 2 };
    const yellow = .{ .index = 3 };
    const blue = .{ .index = 4 };
    const magenta = .{ .index = 5 };
    const cyan = .{ .index = 6 };
    const white = .{ .index = 7 };
    const dim = .{ .rgb = [3]u8{ 100, 100, 100 } }; // Medium gray #646464

    // Muted diff background colors (RGB for better control)
    const diff_add_bg = .{ .rgb = [3]u8{ 3, 25, 10 } }; // Darker green #03190a
    const diff_delete_bg = .{ .rgb = [3]u8{ 72, 13, 13 } }; // Dark red #480d0d
    const diff_add_fg = .{ .rgb = [3]u8{ 240, 255, 240 } }; // Light green text
    const diff_delete_fg = .{ .rgb = [3]u8{ 255, 240, 240 } }; // Light red text

    // Cursor line highlighting - slightly darker gray background
    const cursor_bg = .{ .rgb = [3]u8{ 80, 80, 80 } }; // Darker gray #505050
    const cursor_fg = .{ .rgb = [3]u8{ 255, 255, 255 } }; // White text

    // Pure white caret for focused mode - highly visible
    const caret_bg = .{ .rgb = [3]u8{ 255, 255, 255 } }; // Pure white #ffffff
    const caret_fg = .{ .rgb = [3]u8{ 0, 0, 0 } }; // Black text
};

// Layout constants
const Layout = struct {
    const header_height = 1;
    const status_height = 1;
    const min_gutter_width = 5; // Minimum gutter width for consistency
    const cursor_padding = 3; // Padding around cursor when scrolling
    const page_scroll_lines = 10;
};

const FrameChars = struct {
    const vertical = "│";
    const horizontal = "─";
    const top_left = "╭";
    const top_right = "╮";
    const bottom_left = "╰";
    const bottom_right = "╯";
    const middle_left = "├";
    const middle_right = "┤";
};

const HEADER_BUFFER_WIDTH = 4096;
const FRAME_TEXT_CAPACITY = 262144; // 256 KiB per frame scratch space

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
    pending_highlight_jobs: std.AutoHashMap(usize, []const u8), // file_idx -> owned content string
    needs_render: bool, // Flag to force re-render (e.g., after async highlighting)
    needs_async_highlight: bool, // Flag to trigger async highlighting for current file

    const Mode = enum {
        normal, // Normal navigation and viewing
        comment, // Comment editing
        search, // Search input
        visual, // Visual selection mode
    };

    // Character find commands for NORMAL mode (f/t/F/T)
    const FindCommand = enum {
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
        active_comment_input: ?ActiveCommentInput,
        search_state: SearchState,
        visual_anchor: ?usize, // Visual mode: anchor line (where selection started)
        pending_find: ?FindCommand, // Waiting for character for f/t/F/T
        last_find: ?NormalModeLastFind, // Last f/t/F/T command for ; and , repeat

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
                    .all => .old,
                    .old => .new,
                    .new => .all,
                };
            }

            pub fn prev(self: HunkViewMode) HunkViewMode {
                return switch (self) {
                    .all => .new,
                    .old => .all,
                    .new => .old,
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

    const SearchState = struct {
        query_buffer: [256]u8, // Search query input buffer
        query_len: usize, // Current query length
        matches: std.ArrayList(usize), // Global line indices of matches
        current_match_idx: ?usize, // Index in matches array (not global line)
        allocator: Allocator, // For matches ArrayList

        fn init(allocator: Allocator) SearchState {
            return .{
                .query_buffer = undefined,
                .query_len = 0,
                .matches = std.ArrayList(usize).init(allocator),
                .current_match_idx = null,
                .allocator = allocator,
            };
        }

        fn deinit(self: *SearchState) void {
            self.matches.deinit();
        }

        fn reset(self: *SearchState) void {
            self.query_len = 0;
            self.matches.clearRetainingCapacity();
            self.current_match_idx = null;
        }

        pub fn hasMatches(self: *const SearchState) bool {
            return self.matches.items.len > 0;
        }

        fn getCurrentMatchLine(self: *const SearchState) ?usize {
            if (self.current_match_idx) |idx| {
                if (idx < self.matches.items.len) {
                    return self.matches.items[idx];
                }
            }
            return null;
        }
    };

    const ActiveCommentInput = struct {
        target_file_path: []const u8, // Which file
        target_hunk_idx: usize, // Which hunk
        target_line_idx: usize, // Which line (relative to hunk)
        editing_comment_idx: ?usize, // If editing existing comment, its index
        text_buffer: [4096]u8, // Input buffer
        text_len: usize, // Current text length
        cursor_pos: usize, // Cursor position in buffer
        vim_mode: VimMode, // Current vim mode (normal, insert, or visual)
        visual_anchor: ?usize, // Visual mode: position where selection started
        pending_find: ?PendingFind, // Waiting for character for f/t/F/T
        pending_operator: ?PendingOperator, // Waiting for motion after operator (d, y, c)
        pending_replace: bool, // Waiting for character for 'r' command
        pending_text_object: ?TextObject, // Waiting for text object (iw, aw, etc.)
        yank_buffer: [4096]u8, // Yank/copy buffer
        yank_len: usize, // Length of yanked text
        count_prefix: ?usize, // Count prefix for operations (e.g., 3 in 3dd)
        undo_stack: [32]UndoState, // Undo history
        undo_count: usize, // Number of undo states
        undo_index: usize, // Current position in undo stack
        last_find: ?LastFind, // Last f/t/F/T command for ; and ,
        last_change: ?LastChange, // Last change for . repeat
        command_buffer: [256]u8, // Command-line buffer (for :w, :q, etc.)
        command_len: usize, // Length of command

        const VimMode = enum {
            normal,
            insert,
            visual,
            command, // Ex command mode (:w, :q, etc.)
        };

        const PendingFind = enum {
            f, // Find character forward (move to char)
            t, // Till character forward (move before char)
            F, // Find character backward
            T, // Till character backward
        };

        const PendingOperator = enum {
            d, // Delete
            y, // Yank
            c, // Change
        };

        const TextObject = enum {
            iw, // inner word
            aw, // around word
            i_quote, // inside quotes
            a_quote, // around quotes
            i_paren, // inside parentheses
            a_paren, // around parentheses
            i_bracket, // inside brackets
            a_bracket, // around brackets
            i_brace, // inside braces
            a_brace, // around braces
        };

        const UndoState = struct {
            text: [4096]u8,
            text_len: usize,
            cursor_pos: usize,
        };

        const LastFind = struct {
            command: PendingFind,
            char: u8,
        };

        const LastChange = struct {
            operator: PendingOperator,
            motion: ?u8, // Key for motion (w, e, b, etc.)
            count: ?usize,
        };
    };

    const CTRL_C_TIMEOUT_NS = 1 * std.time.ns_per_s; // 1 second window

    pub fn init(allocator: Allocator, config: anytype) !App {
        var tty = try vaxis.Tty.init();
        errdefer tty.deinit();

        var vx = try Vaxis.init(allocator, .{});
        errdefer vx.deinit(allocator, tty.anyWriter());

        // Load git diff
        const diff_text = try git.getDiff(allocator, config.diff_source);
        errdefer allocator.free(diff_text);

        const files = try parser.parse(allocator, diff_text);
        errdefer {
            for (files) |*file| {
                file.deinit(allocator);
            }
            allocator.free(files);
        }
        allocator.free(diff_text);

        const header_buffers = std.mem.zeroes([Layout.header_height][HEADER_BUFFER_WIDTH]u8);

        const frame_buffer = try allocator.alloc(u8, FRAME_TEXT_CAPACITY);
        @memset(frame_buffer, 0);

        const syntax_highlighter = try syntax.SyntaxHighlighter.init(allocator);

        var comment_store = comments.CommentStore.init(allocator);
        errdefer comment_store.deinit();

        // Build the line map (default to showing all lines, filtering enabled for unified view)
        const built_line_map = try line_map.LineMap.build(allocator, files, &comment_store, .all, true);
        errdefer built_line_map.deinit();

        const app = App{
            .allocator = allocator,
            .vx = vx,
            .tty = tty,
            .mode = .normal,
            .state = State{
                .diff_source = config.diff_source,
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
                .visual_anchor = null,
                .pending_find = null,
                .last_find = null,
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
            .pending_highlight_jobs = std.AutoHashMap(usize, []const u8).init(allocator),
            .needs_render = false,
            .needs_async_highlight = true, // Start with highlighting needed for first file
        };

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
            self.allocator.free(entry.value_ptr.*);
        }
        self.pending_highlight_jobs.deinit();

        for (self.state.files) |*file| {
            file.deinit(self.allocator);
        }
        self.allocator.free(self.state.files);
        self.allocator.free(self.frame_text_buffer);
        self.state.line_map.deinit();
        self.state.comment_store.deinit();
        self.state.search_state.deinit();
        self.syntax_highlighter.deinit();
        self.vx.deinit(self.allocator, self.tty.anyWriter());
        self.tty.deinit();
    }

    pub fn refresh(self: *App) !void {
        // Load fresh git diff
        const diff_text = try git.getDiff(self.allocator, self.state.diff_source);
        defer self.allocator.free(diff_text);

        const new_files = try parser.parse(self.allocator, diff_text);
        errdefer {
            for (new_files) |*file| {
                file.deinit(self.allocator);
            }
            self.allocator.free(new_files);
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

        // Rebuild line map with new files (preserve hunk view mode)
        const new_line_map = try line_map.LineMap.build(self.allocator, new_files, &self.state.comment_store, self.convertHunkViewMode(), self.shouldApplyHunkFiltering());

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
    }

    // Update current_file_idx based on cursor position and trigger highlighting if file changed
    fn updateCurrentFileAndTriggerHighlighting(self: *App) void {
        const cursor_file_idx = self.state.line_map.getFileIndexForLine(self.state.global_cursor_line) orelse return;

        // If we moved to a different file, update and request highlighting
        if (cursor_file_idx != self.state.current_file_idx) {
            self.state.current_file_idx = cursor_file_idx;
            self.needs_async_highlight = true;
        }
    }

    pub fn run(self: *App) !void {
        // Set up the terminal
        var buffered_writer = self.tty.bufferedWriter();

        try self.vx.enterAltScreen(buffered_writer.writer().any());

        // Query terminal capabilities (50ms timeout - enough for modern terminals)
        try self.vx.queryTerminal(buffered_writer.writer().any(), 50 * std.time.ns_per_ms);

        try buffered_writer.flush();

        var loop: vaxis.Loop(Event) = .{
            .tty = &self.tty,
            .vaxis = &self.vx,
        };
        try loop.init();
        try loop.start();
        defer loop.stop();

        var first_render = true;

        // Main event loop
        while (!self.should_quit) {
            // Only block on pollEvent if we don't need to render AND no async job is running
            // This allows async operations to trigger immediate renders
            const should_poll = !self.needs_render and self.pending_highlight_jobs.count() == 0;
            if (should_poll) {
                loop.pollEvent();
            } else {
                // If we need to render or have an active job, check for events without blocking
                // Then sleep briefly to avoid busy-looping
                std.time.sleep(1 * std.time.ns_per_ms); // 1ms delay
            }

            // Check if we need to suspend for editor
            if (self.should_suspend_for_editor) {
                // Stop the event loop to release TTY
                loop.stop();

                // Exit alt screen
                try self.vx.exitAltScreen(buffered_writer.writer().any());
                try buffered_writer.flush();

                // Open editor (blocks until editor exits)
                if (self.editor_file_path) |file_path| {
                    editor.openInEditor(self.allocator, file_path, self.editor_line_number) catch |err| {
                        std.log.err("Failed to open editor: {}", .{err});
                    };
                }

                // Re-enter alt screen
                try self.vx.enterAltScreen(buffered_writer.writer().any());
                try buffered_writer.flush();

                // Restart the event loop
                try loop.start();

                // Refresh diff after returning from editor
                try self.refresh();

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

            // Render if we had events, need to update, or first render
            if (had_events or self.needs_render or first_render) {
                const win = self.vx.window();
                try self.render(win);
                try self.vx.render(buffered_writer.writer().any());
                try buffered_writer.flush();
                self.needs_render = false; // Clear the flag after rendering
            }

            if (first_render) {
                first_render = false;
            }

            // Check for completed highlighting results
            if (self.highlight_worker) |worker| {
                var results = std.ArrayList(state_helpers.HighlightResult).init(self.allocator);
                defer results.deinit();

                worker.pollResults(&results) catch {};

                for (results.items) |result| {
                    const file_idx = result.file_idx;

                    // Remove from pending jobs and free content
                    if (self.pending_highlight_jobs.fetchRemove(file_idx)) |entry| {
                        self.allocator.free(entry.value);
                    }

                    // Apply highlights to file
                    if (result.highlights) |highlights| {
                        if (file_idx < self.state.files.len) {
                            const file = &self.state.files[file_idx];
                            const mutable_file = @constCast(file);
                            mutable_file.highlights = highlights;

                            // Only trigger re-render if this is the CURRENT file
                            if (file_idx == self.state.current_file_idx) {
                                self.needs_render = true;
                            }
                        } else {
                            // File no longer exists (refresh happened), free highlights
                            if (self.highlight_worker) |w| {
                                w.highlighter.freeHighlights(highlights);
                            }
                        }
                    }
                }
            }

            // Submit new highlighting jobs
            if (self.needs_async_highlight and self.state.files.len > 0) {
                self.needs_async_highlight = false;

                const file = &self.state.files[self.state.current_file_idx];
                const file_idx = self.state.current_file_idx;

                // Only submit if file doesn't have highlights and no job is pending
                if (file.highlights == null and !self.pending_highlight_jobs.contains(file_idx)) {
                    // Create worker on first use
                    if (self.highlight_worker == null) {
                        self.highlight_worker = state_helpers.HighlightWorker.init(self.allocator) catch null;
                    }

                    if (self.highlight_worker) |worker| {
                        // Build content string (fast, single allocation)
                        const content = StateHelpers.buildFileContent(self.allocator, file) catch continue;

                        // Submit job to worker
                        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;
                        worker.submitJob(.{
                            .file_path = file_path,
                            .content = content,
                            .file_idx = file_idx,
                        }) catch {
                            self.allocator.free(content);
                            continue;
                        };

                        // Track pending job
                        self.pending_highlight_jobs.put(file_idx, content) catch {
                            self.allocator.free(content);
                        };
                    }
                }
            }
        }
    }

    fn handleEvent(self: *App, event: Event) !void {
        switch (event) {
            .key_press => |key| try self.handleKey(key),
            .winsize => |ws| try self.vx.resize(self.allocator, self.tty.anyWriter(), ws),
            else => {},
        }
    }

    fn handleKey(self: *App, key: vaxis.Key) !void {
        // Handle Ctrl-C for double-press exit (or single press in visual mode)
        if (key.mods.ctrl and key.codepoint == 'c') {
            // In visual mode, single Ctrl-C exits visual mode
            if (self.mode == .visual) {
                self.mode = .normal;
                self.state.visual_anchor = null;
                return;
            }

            // In other modes, double-press to quit
            const now: i64 = @intCast(std.time.nanoTimestamp());
            if (now - self.last_ctrl_c < App.CTRL_C_TIMEOUT_NS) {
                self.should_quit = true;
                return;
            }
            self.last_ctrl_c = now;
            return;
        }

        // Reset double-press timer on any other key
        self.last_ctrl_c = 0;

        switch (self.mode) {
            .normal => try self.handleNormalMode(key),
            .comment => try self.handleCommentMode(key),
            .search => try self.handleSearchMode(key),
            .visual => try self.handleVisualMode(key),
        }
    }

    fn handleNormalMode(self: *App, key: vaxis.Key) !void {
        // If waiting for character for f/t/F/T, execute the find
        if (self.state.pending_find) |cmd| {
            self.state.pending_find = null;
            // ESC cancels pending find
            if (key.codepoint == 27) { // ESC
                return;
            }
            // Convert key to u8 if it's a printable character
            if (key.codepoint >= 0 and key.codepoint <= 127) {
                const target_char: u8 = @intCast(key.codepoint);
                self.executeFindInLine(cmd, target_char);
            }
            return;
        }

        // Handle Ctrl+key combinations first (before regular key handling)
        if (key.mods.ctrl) {
            switch (key.codepoint) {
                'n' => {
                    Navigation.navigateToNextFile(self);
                    self.state.cursor_column = 0; // Reset column on file change
                },
                'p' => {
                    Navigation.navigateToPreviousFile(self);
                    self.state.cursor_column = 0; // Reset column on file change
                },
                'd' => {
                    Navigation.pageDown(self);
                    self.state.cursor_column = 0; // Reset column on page navigation
                    self.updateCurrentFileAndTriggerHighlighting();
                },
                'u' => {
                    Navigation.pageUp(self);
                    self.state.cursor_column = 0; // Reset column on page navigation
                    self.updateCurrentFileAndTriggerHighlighting();
                },
                'g' => try self.openInEditor(),
                else => {},
            }
            return;
        }

        // Handle digit keys for count prefix (1-9, not 0 to match vim)
        if (!key.mods.alt and !key.mods.shift) {
            if (key.codepoint >= '1' and key.codepoint <= '9') {
                const digit = @as(usize, @intCast(key.codepoint - '0'));
                if (self.state.count_prefix) |count| {
                    self.state.count_prefix = count * 10 + digit;
                } else {
                    self.state.count_prefix = digit;
                }
                return;
            }
            // Handle 0 - append to existing count, or go to start of line (not applicable here)
            if (key.codepoint == '0' and self.state.count_prefix != null) {
                self.state.count_prefix = self.state.count_prefix.? * 10;
                return;
            }
        }

        // Handle Shift+Tab before the main switch
        if (key.mods.shift and key.codepoint == '\t') {
            try self.cycleHunkViewModePrev();
            return;
        }

        switch (key.codepoint) {
            'q' => self.should_quit = true,
            'j' => {
                Navigation.moveCursorDown(self);
                self.state.cursor_column = 0; // Reset column on vertical movement
                self.updateCurrentFileAndTriggerHighlighting();
            },
            'k' => {
                Navigation.moveCursorUp(self);
                self.state.cursor_column = 0; // Reset column on vertical movement
                self.updateCurrentFileAndTriggerHighlighting();
            },
            'h' => {
                Navigation.navigateToPreviousFile(self);
                self.state.cursor_column = 0; // Reset column on file change
            },
            'l' => {
                Navigation.navigateToNextFile(self);
                self.state.cursor_column = 0; // Reset column on file change
            },
            'g' => {
                Navigation.scrollToTop(self);
                self.state.cursor_column = 0; // Reset column on jump
                self.updateCurrentFileAndTriggerHighlighting();
            },
            'G' => {
                Navigation.scrollToBottom(self);
                self.state.cursor_column = 0; // Reset column on jump
                self.updateCurrentFileAndTriggerHighlighting();
            },
            '\r' => try self.startCommentInput(), // Enter to create/edit comment
            's' => self.toggleViewMode(),
            '\t' => try self.cycleHunkViewMode(), // Tab to cycle hunk view mode forward
            'r' => try self.refresh(),
            'y' => try self.yankCommentsToClipboard(),
            'd' => try self.deleteCommentUnderCursor(),
            'D' => self.clearAllComments(),
            'M' => {
                Navigation.centerCursor(self);
                self.state.cursor_column = 0; // Reset column on center
                self.updateCurrentFileAndTriggerHighlighting();
            },
            '/' => self.startSearch(),
            'n' => {
                self.searchNext();
                self.state.cursor_column = 0; // Reset column on search jump
                self.updateCurrentFileAndTriggerHighlighting();
            },
            'N' => {
                self.searchPrevious();
                self.state.cursor_column = 0; // Reset column on search jump
                self.updateCurrentFileAndTriggerHighlighting();
            },
            'v' => self.startVisualMode(),
            'f' => self.state.pending_find = .f, // Wait for character to find forward
            't' => self.state.pending_find = .t, // Wait for character to move till forward
            'F' => self.state.pending_find = .F, // Wait for character to find backward
            'T' => self.state.pending_find = .T, // Wait for character to move till backward
            ';' => { // Repeat last find in same direction
                if (self.state.last_find) |last| {
                    self.executeFindInLine(last.command, last.char);
                }
            },
            ',' => { // Repeat last find in opposite direction
                if (self.state.last_find) |last| {
                    const opposite_cmd = switch (last.command) {
                        .f => FindCommand.F,
                        .F => FindCommand.f,
                        .t => FindCommand.T,
                        .T => FindCommand.t,
                    };
                    self.executeFindInLine(opposite_cmd, last.char);
                }
            },
            else => {
                // Reset count prefix on any other key
                self.state.count_prefix = null;
            },
        }
    }

    fn toggleViewMode(self: *App) void {
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
            std.log.err("Failed to rebuild LineMap on view toggle: {}", .{err});
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

    fn cycleHunkViewModePrev(self: *App) !void {
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

    fn cycleHunkViewMode(self: *App) !void {
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
    fn executeFindInLine(self: *App, cmd: FindCommand, target_char: u8) void {
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

    fn handleCommentMode(self: *App, key: vaxis.Key) !void {
        const input = &self.state.active_comment_input.?;

        // Ctrl+S - save comment (works in both modes)
        if (key.mods.ctrl and key.codepoint == 's') {
            try self.saveCurrentComment();
            self.mode = .normal;
            self.state.active_comment_input = null;
            return;
        }

        // Dispatch based on vim mode
        switch (input.vim_mode) {
            .normal => try self.handleCommentModeNormal(key),
            .insert => try self.handleCommentModeInsert(key),
            .visual => try self.handleCommentModeVisual(key),
            .command => try self.handleCommentModeCommand(key),
        }
    }

    fn handleCommentModeNormal(self: *App, key: vaxis.Key) !void {
        var input = &self.state.active_comment_input.?;

        // Handle Ctrl+R for redo
        if (key.mods.ctrl and key.codepoint == 'r') {
            self.performRedo(input);
            return;
        }

        // Handle Ctrl+D for page down
        if (key.mods.ctrl and key.codepoint == 'd') {
            const count = input.count_prefix orelse 1;
            var i: usize = 0;
            while (i < count * 10) : (i += 1) { // Move down 10 lines per page
                self.moveCursorDown(input);
            }
            input.count_prefix = null;
            return;
        }

        // Handle Ctrl+U for page up
        if (key.mods.ctrl and key.codepoint == 'u') {
            const count = input.count_prefix orelse 1;
            var i: usize = 0;
            while (i < count * 10) : (i += 1) { // Move up 10 lines per page
                self.moveCursorUp(input);
            }
            input.count_prefix = null;
            return;
        }

        // Handle Ctrl+W to exit (like closing a tab in VS Code/browsers)
        if (key.mods.ctrl and key.codepoint == 'w') {
            self.mode = .normal;
            self.state.active_comment_input = null;
            return;
        }

        // Handle pending replace (r command)
        if (input.pending_replace) {
            if (key.codepoint >= 32 and key.codepoint < 127) {
                self.pushUndo(input);
                if (input.cursor_pos < input.text_len) {
                    input.text_buffer[input.cursor_pos] = @intCast(key.codepoint);
                }
                input.pending_replace = false;
            }
            return;
        }

        // Handle pending find commands (f/t/F/T)
        if (input.pending_find) |find_cmd| {
            if (key.codepoint >= 32 and key.codepoint < 127) {
                const target_char: u8 = @intCast(key.codepoint);
                input.last_find = .{ .command = find_cmd, .char = target_char };
                try self.executeFind(input, find_cmd, target_char);
                input.pending_find = null;
            }
            return;
        }

        // Handle count prefix (0-9)
        if (key.codepoint >= '0' and key.codepoint <= '9') {
            const digit = key.codepoint - '0';
            if (input.count_prefix) |current| {
                input.count_prefix = current * 10 + digit;
            } else if (digit != 0) { // 0 is a motion, not a count prefix
                input.count_prefix = digit;
            } else {
                // 0 is "go to start of line"
                input.cursor_pos = self.findLineStart(input.*);
            }
            return;
        }

        // Handle pending operator + motion (dw, yw, etc.) or line operation (dd, yy, cc)
        if (input.pending_operator) |operator| {
            const count = input.count_prefix orelse 1;

            // Check for double operator (dd, yy, cc) - operate on whole lines
            const is_line_operation = switch (operator) {
                .d => key.codepoint == 'd',
                .y => key.codepoint == 'y',
                .c => key.codepoint == 'c',
            };

            if (is_line_operation) {
                self.pushUndo(input);
                // Operate on count lines
                const line_start = self.findLineStart(input.*);
                var line_end = self.findLineEnd(input.*);

                // Extend to count lines
                var lines: usize = 1;
                while (lines < count and line_end < input.text_len) : (lines += 1) {
                    if (input.text_buffer[line_end] == '\n') line_end += 1;
                    while (line_end < input.text_len and input.text_buffer[line_end] != '\n') {
                        line_end += 1;
                    }
                }

                // Include final newline if there is one
                if (line_end < input.text_len and input.text_buffer[line_end] == '\n') {
                    line_end += 1;
                }

                try self.executeOperator(input, operator, line_start, line_end);
                input.pending_operator = null;
                input.count_prefix = null;
                return;
            }

            // Handle line-wise motions (j/k)
            if (key.codepoint == 'j' or key.codepoint == 'k') {
                self.pushUndo(input);
                const line_start = self.findLineStart(input.*);
                var line_end = self.findLineEnd(input.*);

                // Extend by count lines in the direction
                var lines: usize = 0;
                while (lines < count) : (lines += 1) {
                    if (key.codepoint == 'j') {
                        // Down
                        if (line_end < input.text_len) {
                            if (input.text_buffer[line_end] == '\n') line_end += 1;
                            while (line_end < input.text_len and input.text_buffer[line_end] != '\n') {
                                line_end += 1;
                            }
                        }
                    } else {
                        // Up - would need to implement going backwards
                        // For now just handle current line
                    }
                }

                // Include newline
                if (line_end < input.text_len and input.text_buffer[line_end] == '\n') {
                    line_end += 1;
                }

                try self.executeOperator(input, operator, line_start, line_end);
                input.pending_operator = null;
                input.count_prefix = null;
                return;
            }

            // Execute motion to get end position (with count)
            self.pushUndo(input);
            const start_pos = input.cursor_pos;
            var end_pos: usize = start_pos;

            var i: usize = 0;
            while (i < count) : (i += 1) {
                end_pos = switch (key.codepoint) {
                    'w' => self.findNextWordStart(input.*),
                    'e' => self.findWordEnd(input.*),
                    'b' => self.findPrevWordStart(input.*),
                    '$' => self.findLineEnd(input.*),
                    '^' => blk: {
                        var pos = self.findLineStart(input.*);
                        while (pos < input.text_len and (input.text_buffer[pos] == ' ' or input.text_buffer[pos] == '\t')) {
                            pos += 1;
                        }
                        break :blk pos;
                    },
                    '{' => self.findPrevParagraph(input.*),
                    '}' => self.findNextParagraph(input.*),
                    else => {
                        // Invalid motion - cancel operator
                        input.pending_operator = null;
                        input.count_prefix = null;
                        return;
                    },
                };
            }

            // Execute operator on range
            try self.executeOperator(input, operator, start_pos, end_pos);
            input.pending_operator = null;
            input.count_prefix = null;
            return;
        }

        const count = input.count_prefix orelse 1;

        switch (key.codepoint) {
            // Undo/Redo
            'u' => {
                self.performUndo(input);
                input.count_prefix = null;
            },

            // Mode transitions
            'i' => {
                input.vim_mode = .insert;
                input.count_prefix = null;
            },
            'a' => {
                input.cursor_pos = @min(input.cursor_pos + 1, input.text_len);
                input.vim_mode = .insert;
                input.count_prefix = null;
            },
            'I' => {
                input.cursor_pos = self.findLineStart(input.*);
                input.vim_mode = .insert;
                input.count_prefix = null;
            },
            'A' => {
                input.cursor_pos = self.findLineEnd(input.*);
                input.vim_mode = .insert;
                input.count_prefix = null;
            },
            'o' => {
                self.pushUndo(input);
                input.cursor_pos = self.findLineEnd(input.*);
                try self.insertChar(input, '\n');
                input.vim_mode = .insert;
                input.count_prefix = null;
            },
            'O' => {
                self.pushUndo(input);
                const line_start = self.findLineStart(input.*);
                input.cursor_pos = line_start;
                try self.insertChar(input, '\n');
                input.cursor_pos = line_start;
                input.vim_mode = .insert;
                input.count_prefix = null;
            },
            's' => { // Substitute character (delete + insert)
                self.pushUndo(input);
                if (input.cursor_pos < input.text_len) {
                    try self.deleteChar(input, input.cursor_pos);
                }
                input.vim_mode = .insert;
                input.count_prefix = null;
            },

            // Navigation with count support
            'h' => {
                var i: usize = 0;
                while (i < count and input.cursor_pos > 0) : (i += 1) {
                    input.cursor_pos -= 1;
                }
                input.count_prefix = null;
            },
            'l' => {
                var i: usize = 0;
                while (i < count and input.cursor_pos < input.text_len) : (i += 1) {
                    input.cursor_pos += 1;
                }
                input.count_prefix = null;
            },
            'j' => {
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    self.moveCursorDown(input);
                }
                input.count_prefix = null;
            },
            'k' => {
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    self.moveCursorUp(input);
                }
                input.count_prefix = null;
            },
            'w' => {
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    input.cursor_pos = self.findNextWordStart(input.*);
                }
                input.count_prefix = null;
            },
            'e' => {
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    input.cursor_pos = self.findWordEnd(input.*);
                }
                input.count_prefix = null;
            },
            'b' => {
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    input.cursor_pos = self.findPrevWordStart(input.*);
                }
                input.count_prefix = null;
            },
            '$' => {
                input.cursor_pos = self.findLineEnd(input.*);
                input.count_prefix = null;
            },
            '^' => { // First non-blank of line
                var pos = self.findLineStart(input.*);
                while (pos < input.text_len and (input.text_buffer[pos] == ' ' or input.text_buffer[pos] == '\t')) {
                    pos += 1;
                }
                input.cursor_pos = pos;
                input.count_prefix = null;
            },
            'g' => { // gg - go to start of buffer
                if (input.count_prefix == null) {
                    // Waiting for second 'g'
                    input.count_prefix = 999; // Use as a flag for 'g' pressed
                } else {
                    input.cursor_pos = 0;
                    input.count_prefix = null;
                }
            },
            'G' => {
                input.cursor_pos = input.text_len;
                input.count_prefix = null;
            },
            '{' => { // Previous paragraph
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    input.cursor_pos = self.findPrevParagraph(input.*);
                }
                input.count_prefix = null;
            },
            '}' => { // Next paragraph
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    input.cursor_pos = self.findNextParagraph(input.*);
                }
                input.count_prefix = null;
            },

            // Visual mode
            'v' => {
                input.visual_anchor = input.cursor_pos;
                input.vim_mode = .visual;
                input.count_prefix = null;
            },

            // Command mode
            ':' => {
                input.command_len = 0;
                input.vim_mode = .command;
                input.count_prefix = null;
            },

            // Find commands
            'f' => {
                input.pending_find = .f;
                // count_prefix preserved for repeat
            },
            't' => {
                input.pending_find = .t;
                // count_prefix preserved for repeat
            },
            'F' => {
                input.pending_find = .F;
                // count_prefix preserved for repeat
            },
            'T' => {
                input.pending_find = .T;
                // count_prefix preserved for repeat
            },
            ';' => { // Repeat last find
                if (input.last_find) |last| {
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        try self.executeFind(input, last.command, last.char);
                    }
                }
                input.count_prefix = null;
            },
            ',' => { // Repeat last find in opposite direction
                if (input.last_find) |last| {
                    const opposite = switch (last.command) {
                        .f => ActiveCommentInput.PendingFind.F,
                        .F => ActiveCommentInput.PendingFind.f,
                        .t => ActiveCommentInput.PendingFind.T,
                        .T => ActiveCommentInput.PendingFind.t,
                    };
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        try self.executeFind(input, opposite, last.char);
                    }
                }
                input.count_prefix = null;
            },

            // Editing
            'r' => {
                input.pending_replace = true;
                input.count_prefix = null;
            },
            'x' => { // Delete character under cursor
                self.pushUndo(input);
                var i: usize = 0;
                while (i < count and input.cursor_pos < input.text_len) : (i += 1) {
                    try self.deleteChar(input, input.cursor_pos);
                }
                input.count_prefix = null;
            },
            'd' => input.pending_operator = .d,
            'y' => input.pending_operator = .y,
            'c' => input.pending_operator = .c,
            'C' => { // Change to end of line
                self.pushUndo(input);
                const line_end = self.findLineEnd(input.*);
                while (input.cursor_pos < line_end) {
                    try self.deleteChar(input, input.cursor_pos);
                }
                input.vim_mode = .insert;
                input.count_prefix = null;
            },
            'D' => { // Delete to end of line
                self.pushUndo(input);
                const line_end = self.findLineEnd(input.*);
                while (input.cursor_pos < line_end) {
                    try self.deleteChar(input, input.cursor_pos);
                }
                input.count_prefix = null;
            },
            'Y' => { // Yank line (like yy)
                const line_start = self.findLineStart(input.*);
                var line_end = self.findLineEnd(input.*);
                if (line_end < input.text_len and input.text_buffer[line_end] == '\n') {
                    line_end += 1;
                }
                const yank_size = line_end - line_start;
                if (yank_size > 0 and yank_size <= input.yank_buffer.len) {
                    @memcpy(input.yank_buffer[0..yank_size], input.text_buffer[line_start..line_end]);
                    input.yank_len = yank_size;
                }
                input.count_prefix = null;
            },
            'p' => { // Paste after cursor
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    try self.pasteAfterCursor(input);
                }
                input.count_prefix = null;
            },
            'P' => { // Paste before cursor
                self.pushUndo(input);
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    // Insert yanked text at cursor position
                    for (0..input.yank_len) |j| {
                        if (input.text_len >= input.text_buffer.len) break;
                        try self.insertChar(input, input.yank_buffer[j]);
                    }
                    // Move cursor back to start of pasted text
                    if (input.yank_len > 0 and input.cursor_pos >= input.yank_len) {
                        input.cursor_pos -= input.yank_len;
                    }
                }
                input.count_prefix = null;
            },
            'J' => { // Join lines
                self.pushUndo(input);
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const line_end = self.findLineEnd(input.*);
                    // If there's a newline, replace it with a space
                    if (line_end < input.text_len and input.text_buffer[line_end] == '\n') {
                        input.text_buffer[line_end] = ' ';
                    }
                }
                input.count_prefix = null;
            },
            'M' => { // Move to middle line (vim-style)
                self.centerCommentCursor(input);
            },

            27 => { // ESC - Clear pending state (use :q or Ctrl-S to exit)
                // Clear any pending state
                input.pending_find = null;
                input.pending_operator = null;
                input.pending_replace = false;
                input.count_prefix = null;
                // Don't exit - use :q or Ctrl-S to save/exit
            },

            else => {
                // Unknown key - clear count prefix
                input.count_prefix = null;
            },
        }
    }

    fn handleCommentModeInsert(self: *App, key: vaxis.Key) !void {
        var input = &self.state.active_comment_input.?;

        // Ctrl+W - exit comment editor (modern app behavior)
        if (key.mods.ctrl and key.codepoint == 'w') {
            self.mode = .normal;
            self.state.active_comment_input = null;
            return;
        }

        // ESC or Ctrl+C - return to normal mode
        if (key.codepoint == 27 or (key.codepoint == 'c' and key.mods.ctrl)) {
            input.vim_mode = .normal;
            // Move cursor left by 1 if not at start (vim behavior)
            if (input.cursor_pos > 0) {
                input.cursor_pos -= 1;
            }
            return;
        }

        // Enter - insert newline
        if (key.matches(vaxis.Key.enter, .{})) {
            try self.insertChar(input, '\n');
            return;
        }

        switch (key.codepoint) {
            127, 8 => { // Backspace / Delete
                if (input.cursor_pos > 0) {
                    try self.deleteChar(input, input.cursor_pos - 1);
                    input.cursor_pos -= 1;
                }
            },
            else => {
                // Regular character input
                if (key.codepoint >= 32 and key.codepoint < 127) {
                    try self.insertChar(input, @intCast(key.codepoint));
                }
            },
        }
    }

    fn handleCommentModeVisual(self: *App, key: vaxis.Key) !void {
        var input = &self.state.active_comment_input.?;

        // Ctrl+W - exit comment editor (modern app behavior)
        if (key.mods.ctrl and key.codepoint == 'w') {
            self.mode = .normal;
            self.state.active_comment_input = null;
            return;
        }

        // Handle pending find commands (f/t/F/T) in visual mode
        if (input.pending_find) |find_cmd| {
            if (key.codepoint >= 32 and key.codepoint < 127) {
                const target_char: u8 = @intCast(key.codepoint);
                input.last_find = .{ .command = find_cmd, .char = target_char };
                try self.executeFind(input, find_cmd, target_char);
                input.pending_find = null;
            } else if (key.codepoint == 27) { // ESC cancels pending find
                input.pending_find = null;
            }
            return;
        }

        // Handle count prefix (0-9) - allows things like 2ft in visual mode
        if (key.codepoint >= '0' and key.codepoint <= '9') {
            const digit = key.codepoint - '0';
            if (input.count_prefix) |current| {
                input.count_prefix = current * 10 + digit;
            } else if (digit != 0) {
                input.count_prefix = digit;
            } else {
                // 0 is "go to start of line"
                input.cursor_pos = self.findLineStart(input.*);
            }
            return;
        }

        switch (key.codepoint) {
            // Exit visual mode
            27 => { // ESC
                input.vim_mode = .normal;
                input.visual_anchor = null;
            },
            'v' => { // Toggle visual mode off
                input.vim_mode = .normal;
                input.visual_anchor = null;
            },

            // Navigation (extends selection)
            'h' => if (input.cursor_pos > 0) {
                input.cursor_pos -= 1;
            },
            'l' => if (input.cursor_pos < input.text_len) {
                input.cursor_pos += 1;
            },
            'j' => self.moveCursorDown(input),
            'k' => self.moveCursorUp(input),
            'w' => {
                const count = input.count_prefix orelse 1;
                input.count_prefix = null;
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    input.cursor_pos = self.findNextWordStart(input.*);
                }
            },
            'e' => {
                const count = input.count_prefix orelse 1;
                input.count_prefix = null;
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    input.cursor_pos = self.findWordEnd(input.*);
                }
            },
            'b' => {
                const count = input.count_prefix orelse 1;
                input.count_prefix = null;
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    input.cursor_pos = self.findPrevWordStart(input.*);
                }
            },
            '0' => {
                input.count_prefix = null;
                input.cursor_pos = self.findLineStart(input.*);
            },
            '$' => {
                input.count_prefix = null;
                input.cursor_pos = self.findLineEnd(input.*);
            },
            'G' => {
                input.count_prefix = null;
                input.cursor_pos = input.text_len;
            },
            // Character find motions
            'f' => input.pending_find = .f,
            't' => input.pending_find = .t,
            'F' => input.pending_find = .F,
            'T' => input.pending_find = .T,
            ';' => { // Repeat last find (respects count: 3; repeats find 3 times)
                if (input.last_find) |last| {
                    const repeat_count = input.count_prefix orelse 1;
                    var i: usize = 0;
                    while (i < repeat_count) : (i += 1) {
                        input.count_prefix = 1; // Each iteration finds 1 occurrence
                        try self.executeFind(input, last.command, last.char);
                    }
                }
            },
            ',' => { // Repeat last find in opposite direction (respects count)
                if (input.last_find) |last| {
                    const repeat_count = input.count_prefix orelse 1;
                    const opposite = switch (last.command) {
                        .f => ActiveCommentInput.PendingFind.F,
                        .F => ActiveCommentInput.PendingFind.f,
                        .t => ActiveCommentInput.PendingFind.T,
                        .T => ActiveCommentInput.PendingFind.t,
                    };
                    var i: usize = 0;
                    while (i < repeat_count) : (i += 1) {
                        input.count_prefix = 1; // Each iteration finds 1 occurrence
                        try self.executeFind(input, opposite, last.char);
                    }
                }
            },

            // Operations on selection
            'y' => { // Yank (copy) selection
                input.count_prefix = null; // Clear count
                const selection = self.getCommentVisualSelection(input.*) orelse return;
                const start = selection.start;
                const end = selection.end;

                // Copy selection to yank buffer
                const yank_size = end - start;
                if (yank_size > 0 and yank_size <= input.yank_buffer.len) {
                    @memcpy(input.yank_buffer[0..yank_size], input.text_buffer[start..end]);
                    input.yank_len = yank_size;

                    // Also copy to system clipboard
                    self.copyToSystemClipboard(input.text_buffer[start..end]) catch |err| {
                        std.log.err("Failed to copy to system clipboard: {}", .{err});
                    };
                }

                input.vim_mode = .normal;
                input.visual_anchor = null;
            },
            'd' => { // Delete selection
                input.count_prefix = null; // Clear count
                const selection = self.getCommentVisualSelection(input.*) orelse return;
                const start = selection.start;
                const end = selection.end;

                // Delete from end to start to maintain positions
                var pos = end;
                while (pos > start) {
                    pos -= 1;
                    try self.deleteChar(input, pos);
                }

                // Place cursor at start of deletion
                input.cursor_pos = start;
                input.vim_mode = .normal;
                input.visual_anchor = null;
            },

            else => {
                // Clear count prefix for unrecognized keys
                input.count_prefix = null;
            }
        }
    }

    fn handleCommentModeCommand(self: *App, key: vaxis.Key) !void {
        var input = &self.state.active_comment_input.?;

        // ESC - return to normal mode
        if (key.codepoint == 27) {
            input.vim_mode = .normal;
            input.command_len = 0;
            return;
        }

        // Enter - execute command
        if (key.matches(vaxis.Key.enter, .{})) {
            const command = input.command_buffer[0..input.command_len];

            // Parse and execute command
            if (std.mem.eql(u8, command, "w")) {
                // :w - save comment
                try self.saveCurrentComment();
                // Rebuild LineMap since comment count changed
                self.state.line_map.deinit();
                self.state.line_map = try line_map.LineMap.build(self.allocator, self.state.files, &self.state.comment_store, self.convertHunkViewMode(), self.shouldApplyHunkFiltering());
                self.mode = .normal;
                self.state.active_comment_input = null;
            } else if (std.mem.eql(u8, command, "q")) {
                // :q - quit without saving
                self.mode = .normal;
                self.state.active_comment_input = null;
            } else if (std.mem.eql(u8, command, "wq")) {
                // :wq - save and quit
                try self.saveCurrentComment();
                // Rebuild LineMap since comment count changed
                self.state.line_map.deinit();
                self.state.line_map = try line_map.LineMap.build(self.allocator, self.state.files, &self.state.comment_store, self.convertHunkViewMode(), self.shouldApplyHunkFiltering());
                self.mode = .normal;
                self.state.active_comment_input = null;
            } else {
                // Unknown command - just return to normal mode
                input.vim_mode = .normal;
                input.command_len = 0;
            }
            return;
        }

        // Backspace - delete character from command
        if (key.codepoint == 127 or key.codepoint == 8) {
            if (input.command_len > 0) {
                input.command_len -= 1;
            }
            return;
        }

        // Regular character input - add to command buffer
        if (key.codepoint >= 32 and key.codepoint < 127) {
            if (input.command_len < input.command_buffer.len) {
                input.command_buffer[input.command_len] = @intCast(key.codepoint);
                input.command_len += 1;
            }
        }
    }

    // Execute a find command (f/t/F/T) with count support
    fn executeFind(self: *App, input: *ActiveCommentInput, cmd: ActiveCommentInput.PendingFind, target_char: u8) !void {
        const line_start = self.findLineStart(input.*);
        const line_end = self.findLineEnd(input.*);
        const count = input.count_prefix orelse 1;
        input.count_prefix = null; // Clear count after use

        var found_count: usize = 0;

        switch (cmd) {
            .f => { // Find forward - move to character
                var pos = input.cursor_pos + 1;
                while (pos < line_end) : (pos += 1) {
                    if (input.text_buffer[pos] == target_char) {
                        found_count += 1;
                        if (found_count == count) {
                            input.cursor_pos = pos;
                            return;
                        }
                    }
                }
            },
            .t => { // Till forward - move before character
                var pos = input.cursor_pos + 1;
                while (pos < line_end) : (pos += 1) {
                    if (input.text_buffer[pos] == target_char) {
                        found_count += 1;
                        if (found_count == count) {
                            input.cursor_pos = pos - 1;
                            return;
                        }
                    }
                }
            },
            .F => { // Find backward - move to character
                if (input.cursor_pos > line_start) {
                    var pos = input.cursor_pos - 1;
                    while (pos >= line_start) {
                        if (input.text_buffer[pos] == target_char) {
                            found_count += 1;
                            if (found_count == count) {
                                input.cursor_pos = pos;
                                return;
                            }
                        }
                        if (pos == line_start) break;
                        pos -= 1;
                    }
                }
            },
            .T => { // Till backward - move after character
                if (input.cursor_pos > line_start) {
                    var pos = input.cursor_pos - 1;
                    while (pos >= line_start) {
                        if (input.text_buffer[pos] == target_char) {
                            found_count += 1;
                            if (found_count == count) {
                                input.cursor_pos = pos + 1;
                                return;
                            }
                        }
                        if (pos == line_start) break;
                        pos -= 1;
                    }
                }
            },
        }
    }

    // Get visual selection range for comment input
    fn getCommentVisualSelection(self: *App, input: ActiveCommentInput) ?struct { start: usize, end: usize } {
        _ = self;
        const anchor = input.visual_anchor orelse return null;
        const cursor = input.cursor_pos;

        const start = @min(anchor, cursor);
        var end = @max(anchor, cursor);

        // Visual mode is inclusive - include character under cursor
        if (end < input.text_len) {
            end += 1;
        }

        return .{ .start = start, .end = end };
    }

    // Helper: Insert character at cursor position
    fn insertChar(self: *App, input: *ActiveCommentInput, char: u8) !void {
        _ = self;
        if (input.text_len >= input.text_buffer.len) return;

        const remaining = input.text_len - input.cursor_pos;
        if (remaining > 0) {
            std.mem.copyBackwards(
                u8,
                input.text_buffer[input.cursor_pos + 1 .. input.text_len + 1],
                input.text_buffer[input.cursor_pos..input.text_len],
            );
        }
        input.text_buffer[input.cursor_pos] = char;
        input.text_len += 1;
        input.cursor_pos += 1;
    }

    // Helper: Delete character at position
    fn deleteChar(self: *App, input: *ActiveCommentInput, pos: usize) !void {
        _ = self;
        if (pos >= input.text_len) return;

        const remaining = input.text_len - pos - 1;
        if (remaining > 0) {
            std.mem.copyForwards(
                u8,
                input.text_buffer[pos .. input.text_len - 1],
                input.text_buffer[pos + 1 .. input.text_len],
            );
        }
        input.text_len -= 1;
    }

    // Helper: Find start of current line
    fn findLineStart(self: *App, input: ActiveCommentInput) usize {
        _ = self;
        var pos = input.cursor_pos;
        while (pos > 0 and input.text_buffer[pos - 1] != '\n') {
            pos -= 1;
        }
        return pos;
    }

    // Helper: Find end of current line
    fn findLineEnd(self: *App, input: ActiveCommentInput) usize {
        _ = self;
        var pos = input.cursor_pos;
        while (pos < input.text_len and input.text_buffer[pos] != '\n') {
            pos += 1;
        }
        return pos;
    }

    // Helper: Move cursor down one line
    fn moveCursorDown(self: *App, input: *ActiveCommentInput) void {
        const current_line_start = self.findLineStart(input.*);
        const current_line_end = self.findLineEnd(input.*);
        const col_offset = input.cursor_pos - current_line_start;

        // Move to start of next line
        if (current_line_end < input.text_len) {
            const next_line_start = current_line_end + 1;
            var next_line_end = next_line_start;
            while (next_line_end < input.text_len and input.text_buffer[next_line_end] != '\n') {
                next_line_end += 1;
            }

            // Try to preserve column position
            const next_line_len = next_line_end - next_line_start;
            input.cursor_pos = next_line_start + @min(col_offset, next_line_len);
        }
    }

    // Helper: Move cursor up one line
    fn moveCursorUp(self: *App, input: *ActiveCommentInput) void {
        const current_line_start = self.findLineStart(input.*);
        const col_offset = input.cursor_pos - current_line_start;

        // Move to start of previous line
        if (current_line_start > 0) {
            const prev_line_end = current_line_start - 1; // Skip the newline
            var prev_line_start = prev_line_end;
            while (prev_line_start > 0 and input.text_buffer[prev_line_start - 1] != '\n') {
                prev_line_start -= 1;
            }

            // Try to preserve column position
            const prev_line_len = prev_line_end - prev_line_start;
            input.cursor_pos = prev_line_start + @min(col_offset, prev_line_len);
        }
    }

    // Helper: Center cursor in comment text (move to middle line)
    fn centerCommentCursor(self: *App, input: *ActiveCommentInput) void {
        _ = self;
        if (input.text_len == 0) return;

        // Count total lines in the text
        var line_count: usize = 1;
        var i: usize = 0;
        while (i < input.text_len) : (i += 1) {
            if (input.text_buffer[i] == '\n') {
                line_count += 1;
            }
        }

        // Find the middle line
        const middle_line = line_count / 2;

        // Navigate to the middle line
        var current_line: usize = 0;
        var pos: usize = 0;
        while (pos < input.text_len and current_line < middle_line) {
            if (input.text_buffer[pos] == '\n') {
                current_line += 1;
            }
            pos += 1;
        }

        // Position cursor at the start of the middle line
        input.cursor_pos = pos;
    }

    // Helper: Find next word start
    fn findNextWordStart(self: *App, input: ActiveCommentInput) usize {
        _ = self;
        var pos = input.cursor_pos;

        // Skip current word
        while (pos < input.text_len and !isWordBoundary(input.text_buffer[pos])) {
            pos += 1;
        }

        // Skip whitespace
        while (pos < input.text_len and isWordBoundary(input.text_buffer[pos])) {
            pos += 1;
        }

        return pos;
    }

    // Helper: Find previous word start
    fn findPrevWordStart(self: *App, input: ActiveCommentInput) usize {
        _ = self;
        if (input.cursor_pos == 0) return 0;

        var pos = input.cursor_pos - 1;

        // Skip whitespace backwards
        while (pos > 0 and isWordBoundary(input.text_buffer[pos])) {
            pos -= 1;
        }

        // Skip word backwards
        while (pos > 0 and !isWordBoundary(input.text_buffer[pos - 1])) {
            pos -= 1;
        }

        return pos;
    }

    // Helper: Find end of current word
    fn findWordEnd(self: *App, input: ActiveCommentInput) usize {
        _ = self;
        var pos = input.cursor_pos;

        // If we're on whitespace, skip to next word first
        if (pos < input.text_len and isWordBoundary(input.text_buffer[pos])) {
            while (pos < input.text_len and isWordBoundary(input.text_buffer[pos])) {
                pos += 1;
            }
        }

        // Move to end of word
        while (pos < input.text_len and !isWordBoundary(input.text_buffer[pos])) {
            pos += 1;
        }

        // Back up one if we ended on the boundary (to land on last char of word)
        if (pos > input.cursor_pos) {
            pos -= 1;
        }

        return pos;
    }

    // Execute an operator (d/y/c) on a range
    fn executeOperator(self: *App, input: *ActiveCommentInput, operator: ActiveCommentInput.PendingOperator, start_pos: usize, end_pos: usize) !void {
        const range_start = @min(start_pos, end_pos);
        const range_end = @max(start_pos, end_pos);

        switch (operator) {
            .y => { // Yank
                const yank_size = range_end - range_start;
                if (yank_size > 0 and yank_size <= input.yank_buffer.len) {
                    @memcpy(input.yank_buffer[0..yank_size], input.text_buffer[range_start..range_end]);
                    input.yank_len = yank_size;

                    // Also copy to system clipboard
                    self.copyToSystemClipboard(input.text_buffer[range_start..range_end]) catch |err| {
                        std.log.err("Failed to copy to system clipboard: {}", .{err});
                    };
                }
            },
            .d => { // Delete
                // Yank before deleting (vim behavior)
                const yank_size = range_end - range_start;
                if (yank_size > 0 and yank_size <= input.yank_buffer.len) {
                    @memcpy(input.yank_buffer[0..yank_size], input.text_buffer[range_start..range_end]);
                    input.yank_len = yank_size;

                    // Also copy to system clipboard
                    self.copyToSystemClipboard(input.text_buffer[range_start..range_end]) catch |err| {
                        std.log.err("Failed to copy to system clipboard: {}", .{err});
                    };
                }

                // Delete from end to start to maintain positions
                var pos = range_end;
                while (pos > range_start) {
                    pos -= 1;
                    try self.deleteChar(input, pos);
                }

                // Place cursor at start of deletion
                input.cursor_pos = range_start;
            },
            .c => { // Change (delete and enter insert mode)
                // Yank before deleting
                const yank_size = range_end - range_start;
                if (yank_size > 0 and yank_size <= input.yank_buffer.len) {
                    @memcpy(input.yank_buffer[0..yank_size], input.text_buffer[range_start..range_end]);
                    input.yank_len = yank_size;

                    // Also copy to system clipboard
                    self.copyToSystemClipboard(input.text_buffer[range_start..range_end]) catch |err| {
                        std.log.err("Failed to copy to system clipboard: {}", .{err});
                    };
                }

                // Delete from end to start
                var pos = range_end;
                while (pos > range_start) {
                    pos -= 1;
                    try self.deleteChar(input, pos);
                }

                // Enter insert mode at deletion point
                input.cursor_pos = range_start;
                input.vim_mode = .insert;
            },
        }
    }

    // Copy text to system clipboard
    fn copyToSystemClipboard(self: *App, text: []const u8) !void {
        const argv = [_][]const u8{"pbcopy"};
        var child = std.process.Child.init(&argv, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        if (child.stdin) |stdin| {
            try stdin.writeAll(text);
            stdin.close();
            child.stdin = null;
        }

        _ = try child.wait();
    }

    // Read text from system clipboard
    fn readFromSystemClipboard(self: *App) ![]const u8 {
        const argv = [_][]const u8{"pbpaste"};
        var child = std.process.Child.init(&argv, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        const stdout = child.stdout.?;
        const output = try stdout.readToEndAlloc(self.allocator, 1024 * 1024); // 1MB max

        _ = try child.wait();

        return output;
    }

    // Paste yanked text after cursor (tries system clipboard first, falls back to yank buffer)
    fn pasteAfterCursor(self: *App, input: *ActiveCommentInput) !void {
        // Try to paste from system clipboard first
        const clipboard_text = self.readFromSystemClipboard() catch null;
        defer if (clipboard_text) |text| self.allocator.free(text);

        // Move cursor forward by 1 to paste after
        if (input.cursor_pos < input.text_len) {
            input.cursor_pos += 1;
        }

        if (clipboard_text) |text| {
            // Paste from system clipboard
            for (text) |char| {
                if (input.text_len >= input.text_buffer.len) break;
                try self.insertChar(input, char);
            }
        } else if (input.yank_len > 0) {
            // Fall back to yank buffer
            for (0..input.yank_len) |i| {
                if (input.text_len >= input.text_buffer.len) break;
                try self.insertChar(input, input.yank_buffer[i]);
            }
        } else {
            // Nothing to paste - move cursor back
            if (input.cursor_pos > 0) {
                input.cursor_pos -= 1;
            }
            return;
        }

        // Leave cursor at end of pasted text
        if (input.cursor_pos > 0) {
            input.cursor_pos -= 1;
        }
    }

    // Helper: Check if character is a word boundary
    fn isWordBoundary(char: u8) bool {
        return char == ' ' or char == '\n' or char == '\t' or char == '.' or char == ',' or char == ';';
    }

    // Helper: Save current state to undo stack
    fn pushUndo(self: *App, input: *ActiveCommentInput) void {
        _ = self;
        if (input.undo_count >= input.undo_stack.len) {
            // Stack full - shift everything down
            var i: usize = 1;
            while (i < input.undo_stack.len) : (i += 1) {
                input.undo_stack[i - 1] = input.undo_stack[i];
            }
            input.undo_count = input.undo_stack.len - 1;
        }

        // Truncate redo history if we're not at the end
        if (input.undo_index < input.undo_count) {
            input.undo_count = input.undo_index;
        }

        // Save current state
        const undo_state = &input.undo_stack[input.undo_count];
        @memcpy(undo_state.text[0..input.text_len], input.text_buffer[0..input.text_len]);
        undo_state.text_len = input.text_len;
        undo_state.cursor_pos = input.cursor_pos;

        input.undo_count += 1;
        input.undo_index = input.undo_count;
    }

    // Helper: Undo last change
    fn performUndo(self: *App, input: *ActiveCommentInput) void {
        _ = self;
        if (input.undo_index == 0) return; // Nothing to undo

        input.undo_index -= 1;
        const undo_state = &input.undo_stack[input.undo_index];

        @memcpy(input.text_buffer[0..undo_state.text_len], undo_state.text[0..undo_state.text_len]);
        input.text_len = undo_state.text_len;
        input.cursor_pos = undo_state.cursor_pos;
    }

    // Helper: Redo last undone change
    fn performRedo(self: *App, input: *ActiveCommentInput) void {
        _ = self;
        if (input.undo_index >= input.undo_count) return; // Nothing to redo

        const undo_state = &input.undo_stack[input.undo_index];

        @memcpy(input.text_buffer[0..undo_state.text_len], undo_state.text[0..undo_state.text_len]);
        input.text_len = undo_state.text_len;
        input.cursor_pos = undo_state.cursor_pos;

        input.undo_index += 1;
    }

    // Helper: Find next blank line (paragraph movement)
    fn findNextParagraph(self: *App, input: ActiveCommentInput) usize {
        _ = self;
        var pos = input.cursor_pos;
        var found_content = false;

        // Skip current line
        while (pos < input.text_len and input.text_buffer[pos] != '\n') {
            pos += 1;
        }
        if (pos < input.text_len) pos += 1; // Skip the newline

        // Find next blank line or end
        while (pos < input.text_len) {
            const line_start = pos;
            var is_blank = true;

            // Check if line is blank
            while (pos < input.text_len and input.text_buffer[pos] != '\n') {
                if (input.text_buffer[pos] != ' ' and input.text_buffer[pos] != '\t') {
                    is_blank = false;
                    found_content = true;
                }
                pos += 1;
            }

            if (is_blank and found_content) {
                return line_start;
            }

            if (pos < input.text_len) pos += 1; // Skip newline
        }

        return input.text_len;
    }

    // Helper: Find previous blank line (paragraph movement)
    fn findPrevParagraph(self: *App, input: ActiveCommentInput) usize {
        _ = self;
        if (input.cursor_pos == 0) return 0;

        var pos = input.cursor_pos;
        var found_content = false;

        // Move to start of current line
        while (pos > 0 and input.text_buffer[pos - 1] != '\n') {
            pos -= 1;
        }

        // Move up one line
        if (pos > 0) pos -= 1;
        while (pos > 0 and input.text_buffer[pos - 1] != '\n') {
            pos -= 1;
        }

        // Find previous blank line
        while (pos > 0) {
            const line_start = pos;
            var is_blank = true;
            var line_end = pos;

            // Check if line is blank
            while (line_end < input.text_len and input.text_buffer[line_end] != '\n') {
                if (input.text_buffer[line_end] != ' ' and input.text_buffer[line_end] != '\t') {
                    is_blank = false;
                    found_content = true;
                }
                line_end += 1;
            }

            if (is_blank and found_content) {
                return line_start;
            }

            // Move to previous line
            if (pos == 0) break;
            pos -= 1;
            while (pos > 0 and input.text_buffer[pos - 1] != '\n') {
                pos -= 1;
            }
        }

        return 0;
    }

    fn startCommentInput(self: *App) !void {
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
        var input = ActiveCommentInput{
            .target_file_path = file_path,
            .target_hunk_idx = target_hunk_idx,
            .target_line_idx = target_line_idx,
            .editing_comment_idx = existing_comment_idx,
            .text_buffer = undefined,
            .text_len = 0,
            .cursor_pos = 0,
            .vim_mode = .insert, // Start in insert mode for user-friendliness
            .visual_anchor = null,
            .pending_find = null,
            .pending_operator = null,
            .pending_replace = false,
            .pending_text_object = null,
            .yank_buffer = undefined,
            .yank_len = 0,
            .count_prefix = null,
            .undo_stack = undefined,
            .undo_count = 0,
            .undo_index = 0,
            .last_find = null,
            .last_change = null,
            .command_buffer = undefined,
            .command_len = 0,
        };
        @memset(&input.text_buffer, 0);

        // If editing existing comment, load its text
        if (existing_comment_idx) |idx| {
            if (self.state.comment_store.getComment(idx)) |comment| {
                const copy_len = @min(comment.text.len, input.text_buffer.len);
                @memcpy(input.text_buffer[0..copy_len], comment.text[0..copy_len]);
                input.text_len = copy_len;
                input.cursor_pos = copy_len; // Start cursor at end
            }
        }

        self.state.active_comment_input = input;
        self.mode = .comment;
    }

    fn saveCurrentComment(self: *App) !void {
        if (self.state.active_comment_input == null) return;

        const input = self.state.active_comment_input.?;
        if (input.text_len == 0) {
            // Empty comment - delete if editing existing, otherwise do nothing
            if (input.editing_comment_idx) |idx| {
                try self.state.comment_store.deleteComment(idx);
            }
            return;
        }

        const comment_text = input.text_buffer[0..input.text_len];

        // Get line context for the comment
        const file = &self.state.files[self.state.current_file_idx];
        const hunk = &file.hunks[input.target_hunk_idx];
        const line = &hunk.lines[input.target_line_idx];

        if (input.editing_comment_idx) |idx| {
            // Update existing comment
            try self.state.comment_store.updateComment(idx, comment_text);
        } else {
            // Add new comment
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

        // Rebuild LineMap since comment count changed
        self.state.line_map.deinit();
        self.state.line_map = try line_map.LineMap.build(self.allocator, self.state.files, &self.state.comment_store, self.convertHunkViewMode(), self.shouldApplyHunkFiltering());
    }

    fn yankCommentsToClipboard(self: *App) !void {
        // Generate export with context (5 lines before, 3 lines after)
        const output = try self.state.comment_store.exportWithContext(
            self.allocator,
            self.state.files,
            5, // lines before
            3, // lines after
        );
        defer self.allocator.free(output);

        // Copy to clipboard using pbcopy on macOS
        const argv = [_][]const u8{"pbcopy"};
        var child = std.process.Child.init(&argv, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        if (child.stdin) |stdin| {
            try stdin.writeAll(output);
            stdin.close();
            child.stdin = null;
        }

        _ = try child.wait();
    }

    fn deleteCommentUnderCursor(self: *App) !void {
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

    fn clearAllComments(self: *App) void {
        self.state.comment_store.clearAll();
    }

    fn openInEditor(self: *App) !void {
        // Get line record from LineMap
        const record = self.state.line_map.getLineRecord(self.state.global_cursor_line) orelse return;

        if (record.file_idx >= self.state.files.len) return;
        const file = &self.state.files[record.file_idx];
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

        // Skip if it's a deleted file or /dev/null
        if (file.new_path.len == 0 or std.mem.eql(u8, file_path, "/dev/null")) {
            return;
        }

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
            self.should_suspend_for_editor = true;
            self.editor_file_path = file_path;
            self.editor_line_number = line_number;
        } else {
            // GUI editor: just spawn it without suspending TUI
            editor.openInEditor(self.allocator, file_path, line_number) catch |err| {
                std.log.err("Failed to open editor: {}", .{err});
            };
        }
    }

    // Search functions
    fn startSearch(self: *App) void {
        self.state.search_state.reset();
        self.mode = .search;
    }

    fn handleSearchMode(self: *App, key: vaxis.Key) !void {
        var search_state = &self.state.search_state;

        // Handle special keys
        if (key.mods.ctrl) {
            return;
        }

        switch (key.codepoint) {
            27 => { // ESC - cancel search
                self.mode = .normal;
                search_state.reset();
            },
            '\r' => { // Enter - execute search
                if (search_state.query_len > 0) {
                    try self.performSearch();
                    self.mode = .normal;
                    // Jump to first match at or after cursor, or wrap to first match
                    if (search_state.hasMatches()) {
                        const cursor = self.state.global_cursor_line;
                        var found = false;

                        // Find first match at or after cursor
                        for (search_state.matches.items, 0..) |match_line, idx| {
                            if (match_line >= cursor) {
                                search_state.current_match_idx = idx;
                                self.state.global_cursor_line = match_line;
                                found = true;
                                break;
                            }
                        }

                        // If no match after cursor, wrap to first match
                        if (!found and search_state.matches.items.len > 0) {
                            search_state.current_match_idx = 0;
                            self.state.global_cursor_line = search_state.matches.items[0];
                        }

                        Navigation.ensureCursorVisible(self, false); // no padding for search jumps
                    }
                } else {
                    self.mode = .normal;
                }
            },
            127, 8 => { // Backspace / Delete
                if (search_state.query_len > 0) {
                    search_state.query_len -= 1;
                    // Update search results as user types
                    try self.performSearch();
                }
            },
            else => {
                // Regular character input
                if (key.codepoint >= 32 and key.codepoint < 127 and search_state.query_len < search_state.query_buffer.len) {
                    search_state.query_buffer[search_state.query_len] = @intCast(key.codepoint);
                    search_state.query_len += 1;
                    // Update search results as user types (live highlighting)
                    try self.performSearch();
                }
            },
        }
    }

    fn performSearch(self: *App) !void {
        var search_state = &self.state.search_state;
        search_state.matches.clearRetainingCapacity();

        if (search_state.query_len == 0) return;

        const query = search_state.query_buffer[0..search_state.query_len];

        // Smart case: case-insensitive if query is all lowercase, sensitive otherwise
        const is_case_sensitive = blk: {
            for (query) |c| {
                if (c >= 'A' and c <= 'Z') break :blk true;
            }
            break :blk false;
        };

        // Search through all lines in LineMap
        const total_lines = self.state.line_map.getTotalLines();
        var line_idx: usize = 0;
        while (line_idx < total_lines) : (line_idx += 1) {
            const record = self.state.line_map.getLineRecord(line_idx) orelse continue;

            // Only search code lines (add, delete, context)
            if (record.line_type != .code_line) continue;

            const file = &self.state.files[record.file_idx];
            const code = record.line_type.code_line;
            const line_content = file.hunks[code.hunk_idx].lines[code.line_idx_in_hunk].content;

            // Search for query in line content
            if (searchInLine(line_content, query, is_case_sensitive)) {
                try search_state.matches.append(line_idx);
            }
        }
    }

    fn searchInLine(haystack: []const u8, needle: []const u8, case_sensitive: bool) bool {
        if (needle.len > haystack.len) return false;

        var i: usize = 0;
        while (i <= haystack.len - needle.len) : (i += 1) {
            const slice = haystack[i .. i + needle.len];
            if (case_sensitive) {
                if (std.mem.eql(u8, slice, needle)) return true;
            } else {
                if (std.ascii.eqlIgnoreCase(slice, needle)) return true;
            }
        }
        return false;
    }

    fn searchNext(self: *App) void {
        var search_state = &self.state.search_state;

        if (!search_state.hasMatches()) return;

        if (search_state.current_match_idx) |current_idx| {
            // Move to next match
            const next_idx = (current_idx + 1) % search_state.matches.items.len;
            search_state.current_match_idx = next_idx;
        } else {
            // No current match - find first match after cursor
            const cursor = self.state.global_cursor_line;
            var found = false;
            for (search_state.matches.items, 0..) |match_line, idx| {
                if (match_line > cursor) {
                    search_state.current_match_idx = idx;
                    found = true;
                    break;
                }
            }
            // If no match after cursor, wrap to first
            if (!found and search_state.matches.items.len > 0) {
                search_state.current_match_idx = 0;
            }
        }

        // Jump to the match
        if (search_state.getCurrentMatchLine()) |line| {
            self.state.global_cursor_line = line;
            Navigation.ensureCursorVisible(self, false); // no padding for search jumps
        }
    }

    fn searchPrevious(self: *App) void {
        var search_state = &self.state.search_state;

        if (!search_state.hasMatches()) return;

        if (search_state.current_match_idx) |current_idx| {
            // Move to previous match (with wraparound)
            const prev_idx = if (current_idx == 0)
                search_state.matches.items.len - 1
            else
                current_idx - 1;
            search_state.current_match_idx = prev_idx;
        } else {
            // No current match - find last match before cursor
            const cursor = self.state.global_cursor_line;
            var found = false;
            var idx = search_state.matches.items.len;
            while (idx > 0) {
                idx -= 1;
                const match_line = search_state.matches.items[idx];
                if (match_line < cursor) {
                    search_state.current_match_idx = idx;
                    found = true;
                    break;
                }
            }
            // If no match before cursor, wrap to last
            if (!found and search_state.matches.items.len > 0) {
                search_state.current_match_idx = search_state.matches.items.len - 1;
            }
        }

        // Jump to the match
        if (search_state.getCurrentMatchLine()) |line| {
            self.state.global_cursor_line = line;
            Navigation.ensureCursorVisible(self, false); // no padding for search jumps
        }
    }

    // Visual mode functions
    fn startVisualMode(self: *App) void {
        self.state.visual_anchor = self.state.global_cursor_line;
        self.mode = .visual;
    }

    fn handleVisualMode(self: *App, key: vaxis.Key) !void {
        // Handle Ctrl+key combinations
        if (key.mods.ctrl) {
            switch (key.codepoint) {
                'n' => Navigation.navigateToNextFile(self),
                'p' => Navigation.navigateToPreviousFile(self),
                'd' => Navigation.pageDown(self),
                'u' => Navigation.pageUp(self),
                else => {},
            }
            return;
        }

        switch (key.codepoint) {
            27 => { // ESC - exit visual mode
                self.mode = .normal;
                self.state.visual_anchor = null;
            },
            'v' => { // v again - exit visual mode (toggle)
                self.mode = .normal;
                self.state.visual_anchor = null;
            },
            'j' => Navigation.moveCursorDown(self),
            'k' => Navigation.moveCursorUp(self),
            'h' => Navigation.navigateToPreviousFile(self),
            'l' => Navigation.navigateToNextFile(self),
            'g' => Navigation.scrollToTop(self),
            'G' => Navigation.scrollToBottom(self),
            'M' => Navigation.centerCursor(self),
            'y' => {
                try self.yankVisualSelection();
                // Exit visual mode after yanking
                self.mode = .normal;
                self.state.visual_anchor = null;
            },
            else => {},
        }
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

    fn yankVisualSelection(self: *App) !void {
        const selection = self.getVisualSelection() orelse return;

        // Build text from selected lines
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        var line_idx = selection.start;
        while (line_idx <= selection.end) : (line_idx += 1) {
            const record = self.state.line_map.getLineRecord(line_idx) orelse continue;

            if (record.file_idx >= self.state.files.len) continue;
            const file = &self.state.files[record.file_idx];

            // Add line content based on type
            switch (record.line_type) {
                .file_header => {
                    const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;
                    try buffer.appendSlice("File: ");
                    try buffer.appendSlice(file_path);
                    try buffer.append('\n');
                },
                .hunk_header => |hunk_info| {
                    const hunk = &file.hunks[hunk_info.hunk_idx];
                    try buffer.appendSlice("@@ -");
                    var num_buf: [32]u8 = undefined;
                    const old_start_str = try std.fmt.bufPrint(&num_buf, "{d}", .{hunk.header.old_start});
                    try buffer.appendSlice(old_start_str);
                    try buffer.append(',');
                    const old_count_str = try std.fmt.bufPrint(&num_buf, "{d}", .{hunk.header.old_count});
                    try buffer.appendSlice(old_count_str);
                    try buffer.appendSlice(" +");
                    const new_start_str = try std.fmt.bufPrint(&num_buf, "{d}", .{hunk.header.new_start});
                    try buffer.appendSlice(new_start_str);
                    try buffer.append(',');
                    const new_count_str = try std.fmt.bufPrint(&num_buf, "{d}", .{hunk.header.new_count});
                    try buffer.appendSlice(new_count_str);
                    try buffer.appendSlice(" @@\n");
                },
                .code_line => |code| {
                    const line = &file.hunks[code.hunk_idx].lines[code.line_idx_in_hunk];
                    // Add line type prefix
                    switch (line.line_type) {
                        .add => try buffer.append('+'),
                        .delete => try buffer.append('-'),
                        .context => try buffer.append(' '),
                    }
                    try buffer.appendSlice(line.content);
                    try buffer.append('\n');
                },
                .comment_line => |comment_info| {
                    if (self.state.comment_store.getComment(comment_info.comment_idx)) |comment| {
                        try buffer.appendSlice("Comment: ");
                        try buffer.appendSlice(comment.text);
                        try buffer.append('\n');
                    }
                },
                .spacer => {
                    // Skip spacer lines
                },
            }
        }

        // Copy to clipboard using pbcopy on macOS
        const argv = [_][]const u8{"pbcopy"};
        var child = std.process.Child.init(&argv, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        if (child.stdin) |stdin| {
            try stdin.writeAll(buffer.items);
            stdin.close();
            child.stdin = null;
        }

        _ = try child.wait();
    }

    fn render(self: *App, win: vaxis.Window) !void {
        win.clear();
        RenderUtils.resetFrameTextBuffer(self);

        // Hide cursor by default - comment input will show it when needed
        win.hideCursor();

        if (self.state.files.len == 0) {
            try UI.renderEmpty(self, win);
            return;
        }

        // Content height without dividers (continuous mode)
        const content_height = win.height - Layout.header_height - Layout.status_height;

        const header_win = win.child(.{
            .x_off = 0,
            .y_off = 0,
            .width = .{ .limit = win.width },
            .height = .{ .limit = Layout.header_height },
        });
        try UI.renderHeader(self, header_win);

        const content_win = win.child(.{
            .x_off = 0,
            .y_off = Layout.header_height,
            .width = .{ .limit = win.width },
            .height = .{ .limit = content_height },
        });
        try self.renderContent(content_win);

        const status_win = win.child(.{
            .x_off = 0,
            .y_off = win.height - Layout.status_height,
            .width = .{ .limit = win.width },
            .height = .{ .limit = Layout.status_height },
        });
        try UI.renderStatus(self, status_win);
    }

    fn renderContent(self: *App, win: vaxis.Window) !void {
        switch (self.state.view_mode) {
            .unified => try UnifiedRenderer.renderContent(self, win),
            .side_by_side => try SideBySideRenderer.renderContent(self, win),
        }
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
        var relevant_highlights = std.ArrayList(syntax.Highlight).init(self.allocator);
        defer relevant_highlights.deinit();

        const line_start = line_byte_offset;
        const line_end = line_byte_offset + text.len;

        for (file_highlights) |h| {
            // Check if highlight overlaps with this line
            if (h.end_byte > line_start and h.start_byte < line_end) {
                // Adjust highlight bounds to line-local coordinates
                const local_start = if (h.start_byte > line_start) h.start_byte - line_start else 0;
                const local_end = if (h.end_byte < line_end) h.end_byte - line_start else text.len;

                try relevant_highlights.append(.{
                    .start_byte = local_start,
                    .end_byte = local_end,
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
        var segments = std.ArrayList(vaxis.Cell.Segment).init(self.allocator);
        errdefer segments.deinit();

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
                    next_start = h.start_byte;
                }
            }

            if (next_highlight) |h| {
                // Render highlighted segment
                const end = @min(h.end_byte, text.len);
                const chunk = text[pos..end];

                // Apply GitHub-inspired syntax colors
                // Use brighter/bolder colors on colored backgrounds for readability
                const highlight_color = h.getColor();
                var style = base_style;

                // Check if we're on a colored background (add/delete line)
                // RGB colors indicate diff backgrounds
                const has_colored_bg = switch (style.bg) {
                    .rgb => true,
                    else => false,
                };

                switch (highlight_color) {
                    .red => {
                        // Keywords - red/orange (GitHub: #d73a49)
                        // Use bright yellow on colored backgrounds for better contrast
                        if (has_colored_bg) {
                            style.fg = Color.yellow;
                            style.bold = true;
                        } else {
                            style.fg = Color.red;
                            style.bold = true;
                        }
                    },
                    .magenta => {
                        // Functions - magenta/purple (GitHub: #6f42c1)
                        style.fg = Color.magenta;
                        style.bold = has_colored_bg; // Bold on colored backgrounds
                    },
                    .yellow => {
                        // Classes/Types - yellow (GitHub: #e36209)
                        style.fg = Color.yellow;
                        style.bold = has_colored_bg;
                    },
                    .blue => {
                        // Strings/Numbers/Constants - blue (GitHub: #032f62, #005cc5)
                        // Use cyan on colored backgrounds for better visibility
                        if (has_colored_bg) {
                            style.fg = Color.cyan;
                            style.bold = false;
                        } else {
                            style.fg = Color.blue;
                            style.bold = false;
                        }
                    },
                    .black => {
                        // Comments - medium gray (GitHub: #6a737d)
                        // Brighten on colored backgrounds for better readability
                        if (has_colored_bg) {
                            style.fg = .{ .rgb = [3]u8{ 140, 140, 140 } }; // Lighter gray #8c8c8c
                        } else {
                            style.fg = Color.dim;
                        }
                    },
                    .green => {
                        // Unused but keep for completeness
                        style.fg = Color.green;
                        style.bold = has_colored_bg;
                    },
                    .white => {
                        // Variables/Default - keep base style foreground
                        // (which is already light green/red for add/delete)
                    },
                    .cyan => {
                        // Cyan color (unused currently)
                        style.fg = Color.cyan;
                    },
                }

                try segments.append(.{
                    .text = chunk,
                    .style = style,
                });

                pos = end;
            } else {
                // Render unhighlighted segment until next highlight
                const chunk = text[pos..next_start];
                try segments.append(.{
                    .text = chunk,
                    .style = base_style,
                });

                pos = next_start;
            }
        }

        const owned_segments = try segments.toOwnedSlice();
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
        const is_case_sensitive = blk: {
            for (query) |c| {
                if (c >= 'A' and c <= 'Z') break :blk true;
            }
            break :blk false;
        };

        // Find all matches in the chunk_text (this is the actual text to render)
        var chunk_matches = std.ArrayList(struct { start: usize, end: usize }).init(self.allocator);
        defer chunk_matches.deinit();

        var search_pos: usize = 0;
        while (search_pos <= chunk_text.len - query.len) {
            const slice = chunk_text[search_pos .. search_pos + query.len];
            const is_match = if (is_case_sensitive)
                std.mem.eql(u8, slice, query)
            else
                std.ascii.eqlIgnoreCase(slice, query);

            if (is_match) {
                try chunk_matches.append(.{ .start = search_pos, .end = search_pos + query.len });
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
        var result_segments = std.ArrayList(vaxis.Cell.Segment).init(self.allocator);
        errdefer result_segments.deinit();

        var text_pos: usize = 0; // Current position in chunk_text
        for (segments) |seg| {
            const seg_start = text_pos;
            const seg_end = text_pos + seg.text.len;

            // Find matches that overlap with this segment
            var seg_matches = std.ArrayList(struct { start: usize, end: usize }).init(self.allocator);
            defer seg_matches.deinit();

            for (chunk_matches.items) |match| {
                if (match.end > seg_start and match.start < seg_end) {
                    // Match overlaps this segment - convert to segment-local coordinates
                    const local_start = if (match.start > seg_start) match.start - seg_start else 0;
                    const local_end = @min(match.end, seg_end) - seg_start;
                    try seg_matches.append(.{ .start = local_start, .end = local_end });
                }
            }

            if (seg_matches.items.len == 0) {
                // No matches in this segment - add as-is
                try result_segments.append(seg);
            } else {
                // Split segment at match boundaries
                var pos: usize = 0;
                for (seg_matches.items) |match| {
                    // Add text before match (if any)
                    if (match.start > pos) {
                        const before_text = seg.text[pos..match.start];
                        try result_segments.append(.{
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
                    try result_segments.append(.{
                        .text = match_text,
                        .style = match_style,
                    });

                    pos = match.end;
                }

                // Add text after last match (if any)
                if (pos < seg.text.len) {
                    const after_text = seg.text[pos..];
                    try result_segments.append(.{
                        .text = after_text,
                        .style = seg.style,
                    });
                }
            }

            text_pos += seg.text.len;
        }

        const result = try result_segments.toOwnedSlice();
        return result;
    }
};

// ===== Tests =====

test "searchInLine - case sensitive" {
    try std.testing.expect(App.searchInLine("Hello World", "World", true));
    try std.testing.expect(!App.searchInLine("Hello World", "world", true));
    try std.testing.expect(!App.searchInLine("Hello World", "WORLD", true));
}

test "searchInLine - case insensitive" {
    try std.testing.expect(App.searchInLine("Hello World", "world", false));
    try std.testing.expect(App.searchInLine("Hello World", "WORLD", false));
    try std.testing.expect(App.searchInLine("Hello World", "WoRlD", false));
}

test "searchInLine - edge cases" {
    // Empty strings
    try std.testing.expect(!App.searchInLine("", "test", false));
    try std.testing.expect(!App.searchInLine("test", "", false));

    // Needle longer than haystack
    try std.testing.expect(!App.searchInLine("hi", "hello", false));

    // Multiple occurrences
    try std.testing.expect(App.searchInLine("test test test", "test", false));

    // Partial match
    try std.testing.expect(!App.searchInLine("testing", "tin", false));
    try std.testing.expect(App.searchInLine("testing", "test", false));
}

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
