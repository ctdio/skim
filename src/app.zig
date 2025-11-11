const std = @import("std");
const vaxis = @import("vaxis");
const git = @import("git/diff.zig");
const parser = @import("git/parser.zig");
const syntax = @import("syntax.zig");
const comments = @import("comments.zig");
const display_lines = @import("display_lines.zig");
const navigation = @import("navigation.zig");
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
    const dim = .{ .rgb = [3]u8{ 40, 40, 40 } }; // Dark gray #282828

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
    const divider_height = 1;
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
    needs_render: bool, // Flag to force re-render (e.g., after async highlighting)
    needs_async_highlight: bool, // Flag to trigger async highlighting for current file
    active_highlight_job: ?*AsyncHighlightJob, // Currently running async highlight job

    const Mode = enum {
        normal, // Normal navigation and viewing
        comment, // Comment editing
    };

    const State = struct {
        diff_source: DiffSource,
        files: []parser.FileDiff,
        current_file_idx: usize,
        scroll_offset: usize,
        cursor_line: usize,
        view_mode: ViewMode,
        viewport_height: usize,
        count_prefix: ?usize, // For vim-style count prefixes (e.g., 5j)
        comment_store: comments.CommentStore,
        active_comment_input: ?ActiveCommentInput,

        const ViewMode = enum {
            unified,
            side_by_side,
        };
    };

    const ActiveCommentInput = struct {
        target_file_path: []const u8, // Which file
        target_hunk_idx: usize, // Which hunk
        target_line_idx: usize, // Which line (relative to hunk)
        editing_comment_idx: ?usize, // If editing existing comment, its index
        text_buffer: [4096]u8, // Input buffer
        text_len: usize, // Current text length
        cursor_pos: usize, // Cursor position in buffer
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

        var app = App{
            .allocator = allocator,
            .vx = vx,
            .tty = tty,
            .mode = .normal,
            .state = State{
                .diff_source = config.diff_source,
                .files = files,
                .current_file_idx = 0,
                .scroll_offset = 0,
                .cursor_line = 0,
                .view_mode = .unified,
                .viewport_height = 0,
                .count_prefix = null,
                .comment_store = comments.CommentStore.init(allocator),
                .active_comment_input = null,
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
            .needs_render = false,
            .needs_async_highlight = true, // Start with highlighting needed for first file
            .active_highlight_job = null,
        };

        // Eagerly apply highlights for initial file if parser is cached
        if (files.len > 0) {
            const initial_file = &app.state.files[0];
            StateHelpers.startAsyncHighlight(&app, initial_file) catch {};
            // If highlights were applied, no need for async later
            if (initial_file.highlights != null) {
                app.needs_async_highlight = false;
            }
        }

        return app;
    }

    pub fn deinit(self: *App) void {
        // Clean up any active highlight job
        if (self.active_highlight_job) |job| {
            // Note: Thread might still be running, but it has its own copy of data
            // so it's safe to free the job struct after it completes
            job.deinit();
        }

        for (self.state.files) |*file| {
            file.deinit(self.allocator);
        }
        self.allocator.free(self.state.files);
        self.allocator.free(self.frame_text_buffer);
        self.state.comment_store.deinit();
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

        // Free old files
        for (self.state.files) |*file| {
            file.deinit(self.allocator);
        }
        self.allocator.free(self.state.files);

        // Update state with new files
        self.state.files = new_files;
        self.state.current_file_idx = new_file_idx;

        // Clamp cursor to new file's line count (don't reset to 0)
        const total_lines = self.getTotalLinesInCurrentFile();
        if (total_lines > 0 and self.state.cursor_line >= total_lines) {
            self.state.cursor_line = total_lines - 1;
        }
        Navigation.clampScrollOffset(self);
    }

    pub fn run(self: *App) !void {
        // Set up the terminal
        var buffered_writer = self.tty.bufferedWriter();

        try self.vx.enterAltScreen(buffered_writer.writer().any());

        // Reduced timeout from 1s to 100ms for faster startup
        // Terminal capabilities are nice-to-have, not critical
        try self.vx.queryTerminal(buffered_writer.writer().any(), 100 * std.time.ns_per_ms);

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
            const should_poll = !self.needs_render and self.active_highlight_job == null;
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

            // Check if active highlight job is complete
            if (self.active_highlight_job) |job| {
                if (job.isDone()) {
                    // Cache the parser in main app's highlighter for future use
                    // The worker thread created its own highlighter which was destroyed
                    // So we need to ensure the main app's cache is populated
                    self.syntax_highlighter.ensureCached(job.file_path);

                    // Get results and apply them
                    if (job.takeResults()) |highlights| {
                        const file_idx = job.file_idx;
                        if (file_idx < self.state.files.len) {
                            const file = &self.state.files[file_idx];
                            // Transfer ownership of highlights to file
                            const mutable_file = @constCast(file);
                            mutable_file.highlights = highlights;
                            // Trigger re-render to show colors
                            self.needs_render = true;
                        } else {
                            // File no longer exists (refresh happened), free highlights
                            self.syntax_highlighter.freeHighlights(highlights);
                        }
                    }
                    // Clean up job
                    job.deinit();
                    self.active_highlight_job = null;
                }
            }

            // Spawn async highlighting if needed (only if no job is active)
            if (self.needs_async_highlight and self.active_highlight_job == null and self.state.files.len > 0) {
                self.needs_async_highlight = false;

                const file = &self.state.files[self.state.current_file_idx];

                // Only trigger if file doesn't have highlights
                if (file.highlights == null) {
                    const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

                    // If parser is cached, apply highlights immediately (fast ~7ms)
                    if (self.syntax_highlighter.isCached(file_path)) {
                        StateHelpers.startAsyncHighlight(self, file) catch {};
                        // Trigger re-render if highlights were added
                        if (file.highlights != null) {
                            self.needs_render = true;
                        }
                    } else {
                        // Parser not cached - spawn background thread
                        self.active_highlight_job = StateHelpers.spawnAsyncHighlight(self, self.state.current_file_idx) catch null;
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
        // Handle Ctrl-C for double-press exit
        if (key.mods.ctrl and key.codepoint == 'c') {
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
        }
    }

    fn handleNormalMode(self: *App, key: vaxis.Key) !void {
        // Handle Ctrl+key combinations first (before regular key handling)
        if (key.mods.ctrl) {
            switch (key.codepoint) {
                'n' => Navigation.navigateToNextFile(self),
                'p' => Navigation.navigateToPreviousFile(self),
                'd' => Navigation.pageDown(self),
                'u' => Navigation.pageUp(self),
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

        switch (key.codepoint) {
            'q' => self.should_quit = true,
            'j' => Navigation.moveCursorDown(self),
            'k' => Navigation.moveCursorUp(self),
            'h' => Navigation.navigateToPreviousFile(self),
            'l' => Navigation.navigateToNextFile(self),
            'g' => Navigation.scrollToTop(self),
            'G' => Navigation.scrollToBottom(self),
            '\r' => try self.startCommentInput(), // Enter to create/edit comment
            's' => self.toggleViewMode(),
            'r' => try self.refresh(),
            'y' => try self.yankCommentsToClipboard(),
            'd' => try self.deleteCommentUnderCursor(),
            'D' => self.clearAllComments(),
            'M' => Navigation.centerCursor(self),
            else => {
                // Reset count prefix on any other key
                self.state.count_prefix = null;
            },
        }
    }

    fn toggleViewMode(self: *App) void {
        self.state.view_mode = switch (self.state.view_mode) {
            .unified => .side_by_side,
            .side_by_side => .unified,
        };
    }

    pub fn getTotalLinesInCurrentFile(self: *App) usize {
        if (self.state.current_file_idx >= self.state.files.len) return 0;

        const file = &self.state.files[self.state.current_file_idx];
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

        return display_lines.getTotalDisplayLines(file, &self.state.comment_store, file_path);
    }

    // Get the content of the line at the current cursor position
    pub fn getCurrentLineContent(self: *App) ?[]const u8 {
        if (self.state.current_file_idx >= self.state.files.len) return null;

        const file = &self.state.files[self.state.current_file_idx];
        var line_idx: usize = 0;

        for (file.hunks) |hunk| {
            // Hunk header line
            if (line_idx == self.state.cursor_line) {
                return null; // Hunk headers don't have editable content
            }
            line_idx += 1;

            // Hunk content lines
            for (hunk.lines) |line| {
                if (line_idx == self.state.cursor_line) {
                    return line.content;
                }
                line_idx += 1;
            }
        }

        return null;
    }

    fn handleCommentMode(self: *App, key: vaxis.Key) !void {
        var input = &self.state.active_comment_input.?;

        // Handle special keys
        if (key.mods.shift and key.codepoint == '\r') {
            // Shift+Enter - insert newline
            if (input.text_len < input.text_buffer.len) {
                // Insert newline at cursor position
                const remaining = input.text_len - input.cursor_pos;
                if (remaining > 0) {
                    std.mem.copyBackwards(
                        u8,
                        input.text_buffer[input.cursor_pos + 1 .. input.text_len + 1],
                        input.text_buffer[input.cursor_pos..input.text_len],
                    );
                }
                input.text_buffer[input.cursor_pos] = '\n';
                input.text_len += 1;
                input.cursor_pos += 1;
            }
            return;
        }

        if (key.mods.ctrl) {
            // Ctrl+S or Ctrl+Enter - save comment
            if (key.codepoint == 's' or key.codepoint == '\r') {
                try self.saveCurrentComment();
                self.mode = .normal;
                self.state.active_comment_input = null;
                return;
            }
            return;
        }

        switch (key.codepoint) {
            27 => { // ESC - cancel
                self.mode = .normal;
                self.state.active_comment_input = null;
            },
            '\r' => { // Enter - save comment
                try self.saveCurrentComment();
                self.mode = .normal;
                self.state.active_comment_input = null;
            },
            127, 8 => { // Backspace / Delete
                if (input.cursor_pos > 0) {
                    const remaining = input.text_len - input.cursor_pos;
                    if (remaining > 0) {
                        std.mem.copyForwards(
                            u8,
                            input.text_buffer[input.cursor_pos - 1 .. input.text_len - 1],
                            input.text_buffer[input.cursor_pos..input.text_len],
                        );
                    }
                    input.text_len -= 1;
                    input.cursor_pos -= 1;
                }
            },
            else => {
                // Regular character input
                if (key.codepoint >= 32 and key.codepoint < 127 and input.text_len < input.text_buffer.len) {
                    // Insert character at cursor position
                    const remaining = input.text_len - input.cursor_pos;
                    if (remaining > 0) {
                        std.mem.copyBackwards(
                            u8,
                            input.text_buffer[input.cursor_pos + 1 .. input.text_len + 1],
                            input.text_buffer[input.cursor_pos..input.text_len],
                        );
                    }
                    input.text_buffer[input.cursor_pos] = @intCast(key.codepoint);
                    input.text_len += 1;
                    input.cursor_pos += 1;
                }
            },
        }
    }

    fn startCommentInput(self: *App) !void {
        if (self.state.current_file_idx >= self.state.files.len) return;

        const file = &self.state.files[self.state.current_file_idx];
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

        // Determine what type of line the cursor is on
        const line_type = display_lines.getDisplayLineType(
            self.state.cursor_line,
            file,
            &self.state.comment_store,
            file_path,
        ) orelse return;

        var target_hunk_idx: usize = undefined;
        var target_line_idx: usize = undefined;
        var existing_comment_idx: ?usize = null;

        switch (line_type) {
            .hunk_header => {
                // Can't comment on hunk headers
                return;
            },
            .code_line => |code| {
                // Creating or editing comment on a code line
                target_hunk_idx = code.hunk_idx;
                target_line_idx = code.line_idx_in_hunk;
                existing_comment_idx = self.state.comment_store.findCommentAt(
                    file_path,
                    target_hunk_idx,
                    target_line_idx,
                );
            },
            .comment_line => |comment_info| {
                // Editing an existing comment
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
        if (self.state.current_file_idx >= self.state.files.len) return;

        const file = &self.state.files[self.state.current_file_idx];
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

        // Check if cursor is on a comment line
        const line_type = display_lines.getDisplayLineType(
            self.state.cursor_line,
            file,
            &self.state.comment_store,
            file_path,
        ) orelse return;

        switch (line_type) {
            .comment_line => |comment_info| {
                // Delete the comment
                try self.state.comment_store.deleteComment(comment_info.comment_idx);

                // After deletion, move cursor to the parent code line
                // (since the comment line no longer exists)
                if (self.state.cursor_line > 0) {
                    self.state.cursor_line -= 1;
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
        if (self.state.current_file_idx >= self.state.files.len) return;

        const file = &self.state.files[self.state.current_file_idx];
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

        // Skip if it's a deleted file or /dev/null
        if (file.new_path.len == 0 or std.mem.eql(u8, file_path, "/dev/null")) {
            return;
        }

        // Get the line number from the current cursor position
        var line_number: ?usize = null;
        const line_type = display_lines.getDisplayLineType(
            self.state.cursor_line,
            file,
            &self.state.comment_store,
            file_path,
        );

        if (line_type) |lt| {
            switch (lt) {
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
                .hunk_header => |header| {
                    // When on a hunk header, jump to the start of the hunk
                    const hunk = &file.hunks[header.hunk_idx];
                    line_number = hunk.header.new_start;
                },
                .comment_line => |comment| {
                    // When on a comment, jump to the parent code line
                    const hunk = &file.hunks[comment.parent_hunk_idx];
                    const line = &hunk.lines[comment.parent_line_idx];
                    if (line.new_lineno) |new_line| {
                        line_number = new_line;
                    } else if (line.old_lineno) |old_line| {
                        line_number = old_line;
                    }
                },
            }
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

    fn render(self: *App, win: vaxis.Window) !void {
        win.clear();
        RenderUtils.resetFrameTextBuffer(self);

        if (self.state.files.len == 0) {
            try UI.renderEmpty(self, win);
            return;
        }

        const content_height = win.height - Layout.header_height - Layout.divider_height - Layout.status_height - 1;

        const header_win = win.child(.{
            .x_off = 0,
            .y_off = 0,
            .width = .{ .limit = win.width },
            .height = .{ .limit = Layout.header_height },
        });
        try UI.renderHeader(self, header_win);

        const divider_top_win = win.child(.{
            .x_off = 0,
            .y_off = Layout.header_height,
            .width = .{ .limit = win.width },
            .height = .{ .limit = Layout.divider_height },
        });
        try UI.renderDivider(self, divider_top_win, .top);

        const content_win = win.child(.{
            .x_off = 0,
            .y_off = Layout.header_height + Layout.divider_height,
            .width = .{ .limit = win.width },
            .height = .{ .limit = content_height },
        });
        try self.renderContent(content_win);

        const divider_bottom_win = win.child(.{
            .x_off = 0,
            .y_off = win.height - Layout.status_height - 1,
            .width = .{ .limit = win.width },
            .height = .{ .limit = 1 },
        });
        try UI.renderDivider(self, divider_bottom_win, .bottom);

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
    pub fn createHighlightedSegments(
        self: *App,
        text: []const u8,
        line_byte_offset: usize,
        highlights: ?[]syntax.Highlight,
        base_style: vaxis.Style,
    ) ![]vaxis.Cell.Segment {
        if (highlights == null or text.len == 0) {
            // No highlights - return single segment
            var segments = try self.allocator.alloc(vaxis.Cell.Segment, 1);
            segments[0] = .{
                .text = text,
                .style = base_style,
            };
            return segments;
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
            return segments;
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
                    .cyan => {
                        // Comments - cyan (GitHub: #6a737d)
                        style.fg = Color.cyan;
                        style.dim = !has_colored_bg; // Don't dim on colored backgrounds
                    },
                    .green => {
                        // Unused but keep for completeness
                        style.fg = Color.green;
                        style.bold = has_colored_bg;
                    },
                    .white, .black => {
                        // Variables/Default - keep base style foreground
                        // (which is already light green/red for add/delete)
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

        return segments.toOwnedSlice();
    }
};
