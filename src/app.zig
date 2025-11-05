const std = @import("std");
const vaxis = @import("vaxis");
const git = @import("git/diff.zig");
const parser = @import("git/parser.zig");
const syntax = @import("syntax.zig");
const navigation = @import("navigation.zig");
const render_utils = @import("rendering/utils.zig");
const state_helpers = @import("state.zig");
const ui_components = @import("ui.zig");
const DiffSource = git.DiffSource;
const Navigation = navigation.Navigation;
const RenderUtils = render_utils.RenderUtils;
const StateHelpers = state_helpers.StateHelpers;
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
    const diff_add_bg = .{ .rgb = [3]u8{ 13, 72, 32 } }; // Dark green #0d4820
    const diff_delete_bg = .{ .rgb = [3]u8{ 72, 13, 13 } }; // Dark red #480d0d
    const diff_add_fg = .{ .rgb = [3]u8{ 200, 255, 200 } }; // Light green text
    const diff_delete_fg = .{ .rgb = [3]u8{ 255, 200, 200 } }; // Light red text

    // Cursor line highlighting - slightly darker gray background
    const cursor_bg = .{ .rgb = [3]u8{ 80, 80, 80 } }; // Darker gray #505050
    const cursor_fg = .{ .rgb = [3]u8{ 255, 255, 255 } }; // White text

    // Pure white caret for focused mode - highly visible
    const caret_bg = .{ .rgb = [3]u8{ 255, 255, 255 } }; // Pure white #ffffff
    const caret_fg = .{ .rgb = [3]u8{ 0, 0, 0 } }; // Black text
};

// Layout constants
const Layout = struct {
    const header_height = 2;
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
    last_ctrl_c: i64,
    header_line_buffers: [Layout.header_height][HEADER_BUFFER_WIDTH]u8,
    frame_text_buffer: []u8,
    frame_text_used: usize,
    syntax_highlighter: syntax.SyntaxHighlighter,

    const Mode = enum {
        normal, // File navigation
        focused, // Detailed in-file navigation
        comment, // Comment editing
    };

    const State = struct {
        diff_source: DiffSource,
        files: []parser.FileDiff,
        current_file_idx: usize,
        scroll_offset: usize,
        cursor_line: usize,
        cursor_col: usize, // Horizontal cursor position (for FOCUSED mode)
        h_scroll_offset: usize, // Horizontal scroll offset (for FOCUSED mode)
        view_mode: ViewMode,
        viewport_height: usize,
        count_prefix: ?usize, // For vim-style count prefixes (e.g., 5j)

        const ViewMode = enum {
            unified,
            side_by_side,
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

        return App{
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
                .cursor_col = 0,
                .h_scroll_offset = 0,
                .view_mode = .unified,
                .viewport_height = 0,
                .count_prefix = null,
            },
            .should_quit = false,
            .last_ctrl_c = 0,
            .header_line_buffers = header_buffers,
            .frame_text_buffer = frame_buffer,
            .frame_text_used = 0,
            .syntax_highlighter = syntax_highlighter,
        };
    }

    pub fn deinit(self: *App) void {
        for (self.state.files) |*file| {
            file.deinit(self.allocator);
        }
        self.allocator.free(self.state.files);
        self.allocator.free(self.frame_text_buffer);
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
        Navigation.resetFileState(self);
    }

    pub fn run(self: *App) !void {
        // Set up the terminal
        var buffered_writer = self.tty.bufferedWriter();
        try self.vx.enterAltScreen(buffered_writer.writer().any());
        try self.vx.queryTerminal(buffered_writer.writer().any(), 1 * std.time.ns_per_s);
        try buffered_writer.flush();

        var loop: vaxis.Loop(Event) = .{
            .tty = &self.tty,
            .vaxis = &self.vx,
        };
        try loop.init();
        try loop.start();
        defer loop.stop();

        // Main event loop
        while (!self.should_quit) {
            loop.pollEvent();

            while (loop.tryEvent()) |event| {
                try self.handleEvent(event);
            }

            // Render
            const win = self.vx.window();
            try self.render(win);
            try self.vx.render(buffered_writer.writer().any());
            try buffered_writer.flush();
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
            .focused => try self.handleFocusedMode(key),
            .comment => try self.handleCommentMode(key),
        }
    }

    fn handleNormalMode(self: *App, key: vaxis.Key) !void {
        // Handle digit keys for count prefix (1-9, not 0 to match vim)
        if (!key.mods.ctrl and !key.mods.alt and !key.mods.shift) {
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
            '\r' => {
                self.mode = .focused;
                Navigation.clampCursorColumn(self); // Ensure cursor is at valid position
            },
            's' => self.toggleViewMode(),
            'r' => try self.refresh(),
            'M' => Navigation.centerCursor(self),
            else => {
                // Reset count prefix on any other key
                self.state.count_prefix = null;
            },
        }

        if (key.mods.ctrl) {
            switch (key.codepoint) {
                'n' => Navigation.navigateToNextFile(self),
                'p' => Navigation.navigateToPreviousFile(self),
                'd' => Navigation.pageDown(self),
                'u' => Navigation.pageUp(self),
                else => {},
            }
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
        var total: usize = 0;

        for (file.hunks) |hunk| {
            total += 1; // hunk header
            total += hunk.lines.len;
        }

        return total;
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

    fn handleFocusedMode(self: *App, key: vaxis.Key) !void {
        // Handle digit keys for count prefix (1-9, not 0 to match vim)
        if (!key.mods.ctrl and !key.mods.alt and !key.mods.shift) {
            if (key.codepoint >= '1' and key.codepoint <= '9') {
                const digit = @as(usize, @intCast(key.codepoint - '0'));
                if (self.state.count_prefix) |count| {
                    self.state.count_prefix = count * 10 + digit;
                } else {
                    self.state.count_prefix = digit;
                }
                return;
            }
            // Handle 0 - append to existing count
            if (key.codepoint == '0' and self.state.count_prefix != null) {
                self.state.count_prefix = self.state.count_prefix.? * 10;
                return;
            }
        }

        switch (key.codepoint) {
            27 => self.mode = .normal, // ESC
            'j' => Navigation.moveCursorDown(self),
            'k' => Navigation.moveCursorUp(self),
            'h' => Navigation.moveCursorLeft(self),
            'l' => Navigation.moveCursorRight(self),
            'g' => Navigation.scrollToTop(self),
            'G' => Navigation.scrollToBottom(self),
            'M' => Navigation.centerCursor(self),
            else => {
                // Reset count prefix on any other key
                self.state.count_prefix = null;
            },
        }

        if (key.mods.ctrl) {
            switch (key.codepoint) {
                'd' => Navigation.pageDown(self),
                'u' => Navigation.pageUp(self),
                else => {},
            }
        }
    }

    fn handleCommentMode(self: *App, key: vaxis.Key) !void {
        _ = self;
        switch (key.codepoint) {
            27 => {}, // ESC - back to normal (to be implemented)
            else => {},
        }
    }

    fn render(self: *App, win: vaxis.Window) !void {
        win.clear();
        RenderUtils.resetFrameTextBuffer(self);

        if (self.state.files.len == 0) {
            try UI.renderEmpty(self,win);
            return;
        }

        const content_height = win.height - Layout.header_height - Layout.divider_height - Layout.status_height - 1;

        const header_win = win.child(.{
            .x_off = 0,
            .y_off = 0,
            .width = .{ .limit = win.width },
            .height = .{ .limit = Layout.header_height },
        });
        try UI.renderHeader(self,header_win);

        const divider_top_win = win.child(.{
            .x_off = 0,
            .y_off = Layout.header_height,
            .width = .{ .limit = win.width },
            .height = .{ .limit = Layout.divider_height },
        });
        try UI.renderDivider(self,divider_top_win, .top);

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
        try UI.renderDivider(self,divider_bottom_win, .bottom);

        const status_win = win.child(.{
            .x_off = 0,
            .y_off = win.height - Layout.status_height,
            .width = .{ .limit = win.width },
            .height = .{ .limit = Layout.status_height },
        });
        try UI.renderStatus(self,status_win);
    }

    fn renderContent(self: *App, win: vaxis.Window) !void {
        switch (self.state.view_mode) {
            .unified => try self.renderContentUnified(win),
            .side_by_side => try self.renderContentSideBySide(win),
        }
    }

    fn renderContentUnified(self: *App, win: vaxis.Window) !void {
        if (self.state.current_file_idx >= self.state.files.len) return;

        const file = &self.state.files[self.state.current_file_idx];

        // Ensure syntax highlights are loaded for this file
        try StateHelpers.ensureHighlights(self,file);

        self.state.viewport_height = win.height;
        Navigation.clampScrollOffset(self);
        Navigation.adjustScrollToKeepCursorVisible(self, win.height);

        // Calculate gutter width based on maximum line number in file
        const gutter_width = StateHelpers.getGutterWidth(file);

        // Render vertical borders
        const border_style = .{ .fg = Color.dim };
        for (0..win.height) |border_row| {
            var left_seg = [_]vaxis.Cell.Segment{.{
                .text = FrameChars.vertical,
                .style = border_style,
            }};
            _ = try win.print(&left_seg, .{ .row_offset = border_row, .col_offset = 0 });

            if (win.width > 1) {
                var right_seg = [_]vaxis.Cell.Segment{.{
                    .text = FrameChars.vertical,
                    .style = border_style,
                }};
                _ = try win.print(&right_seg, .{ .row_offset = border_row, .col_offset = win.width -| 1 });
            }
        }

        const content_width = win.width -| (2 + gutter_width);

        // Adjust horizontal scroll to keep cursor visible (vim-like behavior)
        if (self.mode == .focused) {
            Navigation.adjustHorizontalScroll(self, content_width);
        }

        var row: usize = 0;
        var line_idx: usize = 0;

        for (file.hunks, 0..) |hunk, hunk_idx| {
            if (line_idx + hunk.lines.len < self.state.scroll_offset) {
                line_idx += hunk.lines.len + 1; // +1 for hunk header
                continue;
            }

            if (line_idx >= self.state.scroll_offset) {
                if (row >= win.height) break;
                const rows_used = try self.renderHunkHeader(win, hunk, line_idx, row, content_width, gutter_width);
                row += rows_used;
            }
            line_idx += 1;

            for (hunk.lines, 0..) |line, line_idx_in_hunk| {
                if (line_idx < self.state.scroll_offset) {
                    line_idx += 1;
                    continue;
                }

                if (row >= win.height) break;
                const rows_used = try self.renderDiffLine(win, file, hunk_idx, line_idx_in_hunk, line, line_idx, row, content_width, gutter_width);
                row += rows_used;
                line_idx += 1;
            }
        }
    }

    fn renderContentSideBySide(self: *App, win: vaxis.Window) !void {
        if (self.state.current_file_idx >= self.state.files.len) return;

        const file = &self.state.files[self.state.current_file_idx];

        // Ensure syntax highlights are loaded for this file
        try StateHelpers.ensureHighlights(self,file);

        self.state.viewport_height = win.height;
        Navigation.clampScrollOffset(self);
        Navigation.adjustScrollToKeepCursorVisible(self, win.height);

        // Calculate gutter width based on maximum line number in file
        const gutter_width = StateHelpers.getGutterWidth(file);

        // Calculate layout: [border][gutter][left_content][divider][gutter][right_content][border]
        // Total width = 2 (borders) + 2 * gutter_width + 1 (middle divider) + left_content + right_content
        const total_borders_and_gutters = 2 + (2 * gutter_width) + 1;
        if (win.width <= total_borders_and_gutters) return; // Not enough space

        const available_width = win.width - total_borders_and_gutters;
        const left_content_width = available_width / 2;
        const right_content_width = available_width - left_content_width;

        // Render outer borders
        const border_style = .{ .fg = Color.dim };
        for (0..win.height) |border_row| {
            // Left border
            var left_seg = [_]vaxis.Cell.Segment{.{
                .text = FrameChars.vertical,
                .style = border_style,
            }};
            _ = try win.print(&left_seg, .{ .row_offset = border_row, .col_offset = 0 });

            // Right border
            if (win.width > 1) {
                var right_seg = [_]vaxis.Cell.Segment{.{
                    .text = FrameChars.vertical,
                    .style = border_style,
                }};
                _ = try win.print(&right_seg, .{ .row_offset = border_row, .col_offset = win.width -| 1 });
            }

            // Middle divider
            const middle_col = 1 + gutter_width + left_content_width;
            var middle_seg = [_]vaxis.Cell.Segment{.{
                .text = FrameChars.vertical,
                .style = border_style,
            }};
            _ = try win.print(&middle_seg, .{ .row_offset = border_row, .col_offset = middle_col });
        }

        var row: usize = 0;
        var line_idx: usize = 0;

        for (file.hunks, 0..) |hunk, hunk_idx| {
            // Skip hunks that are before scroll offset
            if (line_idx + hunk.lines.len < self.state.scroll_offset) {
                line_idx += hunk.lines.len + 1; // +1 for hunk header
                continue;
            }

            // Render hunk header if visible
            if (line_idx >= self.state.scroll_offset) {
                if (row >= win.height) break;
                const rows_used = try self.renderHunkHeaderSideBySide(
                    win,
                    hunk,
                    line_idx,
                    row,
                    left_content_width,
                    right_content_width,
                    gutter_width,
                );
                row += rows_used;
            }
            line_idx += 1;

            // Render diff lines
            for (hunk.lines, 0..) |line, line_idx_in_hunk| {
                if (line_idx < self.state.scroll_offset) {
                    line_idx += 1;
                    continue;
                }

                if (row >= win.height) break;
                const rows_used = try self.renderDiffLineSideBySide(
                    win,
                    file,
                    hunk_idx,
                    line_idx_in_hunk,
                    line,
                    line_idx,
                    row,
                    left_content_width,
                    right_content_width,
                    gutter_width,
                );
                row += rows_used;
                line_idx += 1;
            }
        }
    }

    fn renderHunkHeaderSideBySide(
        self: *App,
        win: vaxis.Window,
        hunk: parser.Hunk,
        line_idx: usize,
        row: usize,
        left_width: usize,
        right_width: usize,
        gutter_width: usize,
    ) !usize {
        var buf: [256]u8 = undefined;

        // Calculate end line numbers for clearer range display
        const old_end = hunk.header.old_start + hunk.header.old_count -| 1;
        const new_end = hunk.header.new_start + hunk.header.new_count -| 1;

        const header_text_stack = try std.fmt.bufPrint(
            &buf,
            "━━ ↕ {d}-{d} → {d}-{d} ━━ {s}",
            .{
                hunk.header.old_start,
                old_end,
                hunk.header.new_start,
                new_end,
                hunk.header.context,
            },
        );

        const header_text = try RenderUtils.copyFrameText(self,header_text_stack);
        const is_cursor = line_idx == self.state.cursor_line;
        const style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
        else
            .{ .fg = Color.cyan, .bg = Color.dim };

        // Calculate how many rows this will take (same on both sides)
        const num_rows = if (header_text.len == 0) 1 else (header_text.len + left_width - 1) / left_width;

        const right_col = 1 + gutter_width + left_width + 1; // +1 for middle divider

        // Render wrapped text on both left and right sides
        const fill_style: vaxis.Style = .{ .bg = Color.dim };
        var current_row = row;
        for (0..num_rows) |wrap_idx| {
            if (current_row >= win.height) break;

            // Fill the entire row with dim background first
            const fill_start = 1; // After left border
            const fill_end = win.width -| 1; // Before right border
            const fill_width = if (fill_end > fill_start) fill_end - fill_start else 0;

            if (fill_width > 0) {
                const fill_text = try RenderUtils.frameTextSlice(self,fill_width);
                @memset(fill_text, ' ');
                var fill_seg = [_]vaxis.Cell.Segment{.{
                    .text = fill_text,
                    .style = fill_style,
                }};
                _ = try win.print(&fill_seg, .{ .row_offset = current_row, .col_offset = fill_start });
            }

            // Render left content
            const text_start = wrap_idx * left_width;
            const text_end = @min(text_start + left_width, header_text.len);
            const chunk = if (text_start < header_text.len) header_text[text_start..text_end] else "";

            const left_display = blk: {
                const slice = try RenderUtils.frameTextSlice(self,left_width);
                const copy_len = @min(chunk.len, slice.len);
                if (copy_len > 0) {
                    @memcpy(slice[0..copy_len], chunk);
                }
                if (copy_len < slice.len) {
                    @memset(slice[copy_len..], ' ');
                }
                break :blk slice;
            };

            var left_seg = [_]vaxis.Cell.Segment{.{
                .text = left_display,
                .style = style,
            }};
            _ = try win.print(&left_seg, .{ .row_offset = current_row, .col_offset = 1 + gutter_width });

            // Render right content
            const right_text_start = wrap_idx * right_width;
            const right_text_end = @min(right_text_start + right_width, header_text.len);
            const right_chunk = if (right_text_start < header_text.len) header_text[right_text_start..right_text_end] else "";

            const right_display = blk: {
                const slice = try RenderUtils.frameTextSlice(self,right_width);
                const copy_len = @min(right_chunk.len, slice.len);
                if (copy_len > 0) {
                    @memcpy(slice[0..copy_len], right_chunk);
                }
                if (copy_len < slice.len) {
                    @memset(slice[copy_len..], ' ');
                }
                break :blk slice;
            };

            var right_seg = [_]vaxis.Cell.Segment{.{
                .text = right_display,
                .style = style,
            }};
            _ = try win.print(&right_seg, .{ .row_offset = current_row, .col_offset = right_col + gutter_width });

            current_row += 1;
        }

        return if (num_rows == 0) 1 else num_rows;
    }

    fn renderDiffLineSideBySide(
        self: *App,
        win: vaxis.Window,
        file: *const parser.FileDiff,
        hunk_idx: usize,
        line_idx_in_hunk: usize,
        line: parser.Line,
        line_idx: usize,
        row: usize,
        left_width: usize,
        right_width: usize,
        gutter_width: usize,
    ) !usize {
        const is_cursor = line_idx == self.state.cursor_line;
        const base_style = RenderUtils.getLineStyle(self,line.line_type);
        const style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
        else
            base_style;

        const right_col = 1 + gutter_width + left_width + 1; // +1 for middle divider

        // Calculate byte offset for syntax highlighting
        const byte_offset = StateHelpers.getLineByteOffset(file, hunk_idx, line_idx_in_hunk);

        switch (line.line_type) {
            .context => {
                // Show on both sides - calculate rows based on left width
                const num_rows = if (line.content.len == 0) 1 else (line.content.len + left_width - 1) / left_width;

                var current_row = row;
                for (0..num_rows) |wrap_idx| {
                    if (current_row >= win.height) break;

                    const show_lineno = wrap_idx == 0;

                    // Render left side
                    try RenderUtils.renderGutter(self,win, line_idx, current_row, is_cursor, show_lineno, line.old_lineno, line.line_type, gutter_width);

                    const left_start = wrap_idx * left_width;
                    const left_end = @min(left_start + left_width, line.content.len);
                    const left_chunk = if (left_start < line.content.len) line.content[left_start..left_end] else "";

                    // Generate syntax-highlighted segments for left chunk
                    const left_chunk_byte_offset = byte_offset + left_start;
                    const left_segments = try self.createHighlightedSegments(left_chunk, left_chunk_byte_offset, file.highlights, style);
                    defer self.allocator.free(left_segments);

                    // If cursor is on this line, we need to pad the segments
                    if (is_cursor and left_chunk.len < left_width) {
                        const padded_segments = try self.allocator.alloc(vaxis.Cell.Segment, left_segments.len + 1);
                        defer self.allocator.free(padded_segments);

                        @memcpy(padded_segments[0..left_segments.len], left_segments);

                        const padding_len = left_width - left_chunk.len;
                        const padding = try RenderUtils.frameTextSlice(self,padding_len);
                        @memset(padding, ' ');
                        padded_segments[left_segments.len] = .{
                            .text = padding,
                            .style = style,
                        };

                        _ = try win.print(padded_segments, .{ .row_offset = current_row, .col_offset = 1 + gutter_width });
                    } else {
                        _ = try win.print(left_segments, .{ .row_offset = current_row, .col_offset = 1 + gutter_width });
                    }

                    // Render right side (same content)
                    try self.renderGutterAtColumn(win, line_idx, current_row, is_cursor, show_lineno, line.new_lineno, right_col, line.line_type, gutter_width);

                    const right_start = wrap_idx * right_width;
                    const right_end = @min(right_start + right_width, line.content.len);
                    const right_chunk = if (right_start < line.content.len) line.content[right_start..right_end] else "";

                    // Generate syntax-highlighted segments for right chunk
                    const right_chunk_byte_offset = byte_offset + right_start;
                    const right_segments = try self.createHighlightedSegments(right_chunk, right_chunk_byte_offset, file.highlights, style);
                    defer self.allocator.free(right_segments);

                    // If cursor is on this line, we need to pad the segments
                    if (is_cursor and right_chunk.len < right_width) {
                        const padded_segments = try self.allocator.alloc(vaxis.Cell.Segment, right_segments.len + 1);
                        defer self.allocator.free(padded_segments);

                        @memcpy(padded_segments[0..right_segments.len], right_segments);

                        const padding_len = right_width - right_chunk.len;
                        const padding = try RenderUtils.frameTextSlice(self,padding_len);
                        @memset(padding, ' ');
                        padded_segments[right_segments.len] = .{
                            .text = padding,
                            .style = style,
                        };

                        _ = try win.print(padded_segments, .{ .row_offset = current_row, .col_offset = right_col + gutter_width });
                    } else {
                        _ = try win.print(right_segments, .{ .row_offset = current_row, .col_offset = right_col + gutter_width });
                    }

                    current_row += 1;
                }

                return if (num_rows == 0) 1 else num_rows;
            },
            .delete => {
                // Show on left only, wrap as needed
                // Note: Delete lines are not in the new file, so syntax highlighting won't apply
                const num_rows = if (line.content.len == 0) 1 else (line.content.len + left_width - 1) / left_width;

                var current_row = row;
                for (0..num_rows) |wrap_idx| {
                    if (current_row >= win.height) break;

                    const show_lineno = wrap_idx == 0;

                    // Render left side
                    try RenderUtils.renderGutter(self,win, line_idx, current_row, is_cursor, show_lineno, line.old_lineno, line.line_type, gutter_width);

                    const text_start = wrap_idx * left_width;
                    const text_end = @min(text_start + left_width, line.content.len);
                    const chunk = if (text_start < line.content.len) line.content[text_start..text_end] else "";

                    // Generate syntax-highlighted segments for chunk
                    // (will fall back to plain text for delete lines since they're not in new file)
                    const chunk_byte_offset = byte_offset + text_start;
                    const segments = try self.createHighlightedSegments(chunk, chunk_byte_offset, file.highlights, style);
                    defer self.allocator.free(segments);

                    // If cursor is on this line, we need to pad the segments
                    if (is_cursor and chunk.len < left_width) {
                        const padded_segments = try self.allocator.alloc(vaxis.Cell.Segment, segments.len + 1);
                        defer self.allocator.free(padded_segments);

                        @memcpy(padded_segments[0..segments.len], segments);

                        const padding_len = left_width - chunk.len;
                        const padding = try RenderUtils.frameTextSlice(self,padding_len);
                        @memset(padding, ' ');
                        padded_segments[segments.len] = .{
                            .text = padding,
                            .style = style,
                        };

                        _ = try win.print(padded_segments, .{ .row_offset = current_row, .col_offset = 1 + gutter_width });
                    } else {
                        _ = try win.print(segments, .{ .row_offset = current_row, .col_offset = 1 + gutter_width });
                    }

                    // Right side empty with cursor highlight if needed
                    if (is_cursor) {
                        try self.renderGutterAtColumn(win, line_idx, current_row, is_cursor, false, null, right_col, null, gutter_width);
                        const blank = try RenderUtils.frameTextSlice(self,right_width);
                        @memset(blank, ' ');
                        var blank_seg = [_]vaxis.Cell.Segment{.{
                            .text = blank,
                            .style = .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg },
                        }};
                        _ = try win.print(&blank_seg, .{ .row_offset = current_row, .col_offset = right_col + gutter_width });
                    }

                    current_row += 1;
                }

                return if (num_rows == 0) 1 else num_rows;
            },
            .add => {
                // Show on right only, wrap as needed
                const num_rows = if (line.content.len == 0) 1 else (line.content.len + right_width - 1) / right_width;

                var current_row = row;
                for (0..num_rows) |wrap_idx| {
                    if (current_row >= win.height) break;

                    const show_lineno = wrap_idx == 0;

                    // Left side empty with cursor highlight if needed
                    if (is_cursor) {
                        try RenderUtils.renderGutter(self,win, line_idx, current_row, is_cursor, false, null, null, gutter_width);
                        const blank = try RenderUtils.frameTextSlice(self,left_width);
                        @memset(blank, ' ');
                        var blank_seg = [_]vaxis.Cell.Segment{.{
                            .text = blank,
                            .style = .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg },
                        }};
                        _ = try win.print(&blank_seg, .{ .row_offset = current_row, .col_offset = 1 + gutter_width });
                    }

                    // Render right side
                    try self.renderGutterAtColumn(win, line_idx, current_row, is_cursor, show_lineno, line.new_lineno, right_col, line.line_type, gutter_width);

                    const text_start = wrap_idx * right_width;
                    const text_end = @min(text_start + right_width, line.content.len);
                    const chunk = if (text_start < line.content.len) line.content[text_start..text_end] else "";

                    // Generate syntax-highlighted segments for chunk
                    const chunk_byte_offset = byte_offset + text_start;
                    const segments = try self.createHighlightedSegments(chunk, chunk_byte_offset, file.highlights, style);
                    defer self.allocator.free(segments);

                    // If cursor is on this line, we need to pad the segments
                    if (is_cursor and chunk.len < right_width) {
                        const padded_segments = try self.allocator.alloc(vaxis.Cell.Segment, segments.len + 1);
                        defer self.allocator.free(padded_segments);

                        @memcpy(padded_segments[0..segments.len], segments);

                        const padding_len = right_width - chunk.len;
                        const padding = try RenderUtils.frameTextSlice(self,padding_len);
                        @memset(padding, ' ');
                        padded_segments[segments.len] = .{
                            .text = padding,
                            .style = style,
                        };

                        _ = try win.print(padded_segments, .{ .row_offset = current_row, .col_offset = right_col + gutter_width });
                    } else {
                        _ = try win.print(segments, .{ .row_offset = current_row, .col_offset = right_col + gutter_width });
                    }

                    current_row += 1;
                }

                return if (num_rows == 0) 1 else num_rows;
            },
        }
    }

    fn renderGutterAtColumn(
        self: *App,
        win: vaxis.Window,
        line_idx: usize,
        row: usize,
        is_cursor: bool,
        show_number: bool,
        file_lineno: ?u32,
        col_offset: usize,
        line_type: ?parser.Line.LineType,
        gutter_width: usize,
    ) !void {
        _ = line_idx;

        const base_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
        else
            .{ .fg = Color.dim };

        if (show_number) {
            if (file_lineno) |lineno| {
                // Show line number and diff sign (GitHub style: number right-justified, sign after)
                const sign: []const u8 = if (line_type) |lt| switch (lt) {
                    .add => "+",
                    .delete => "-",
                    .context => " ",
                } else " ";

                // Format number
                var num_buf: [16]u8 = undefined;
                const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{lineno});
                const num_width = gutter_width - 1; // Reserve 1 char for sign
                const padding_needed = num_width -| num_str.len;

                // Build gutter with right-justified number and sign
                var buf: [32]u8 = undefined;
                var i: usize = 0;
                while (i < padding_needed) : (i += 1) {
                    buf[i] = ' ';
                }
                @memcpy(buf[padding_needed .. padding_needed + num_str.len], num_str);
                const sign_pos = padding_needed + num_str.len;
                @memcpy(buf[sign_pos .. sign_pos + sign.len], sign);

                const gutter_text = try RenderUtils.copyFrameText(self,buf[0 .. sign_pos + sign.len]);

                // Color the sign based on line type (with matching background)
                const sign_style: vaxis.Style = if (line_type) |lt| switch (lt) {
                    .add => if (is_cursor)
                        .{ .fg = Color.green, .bg = Color.cursor_bg, .bold = true }
                    else
                        .{ .fg = Color.green, .bg = Color.diff_add_bg, .bold = true },
                    .delete => if (is_cursor)
                        .{ .fg = Color.red, .bg = Color.cursor_bg, .bold = true }
                    else
                        .{ .fg = Color.red, .bg = Color.diff_delete_bg, .bold = true },
                    .context => if (is_cursor)
                        .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
                    else
                        .{ .fg = Color.dim },
                } else base_style;

                const number_style: vaxis.Style = base_style;

                // Split into number and sign segments for different colors
                const number_text = gutter_text[0 .. gutter_text.len - 1];
                const sign_text = gutter_text[gutter_text.len - 1 ..];

                var segments = [_]vaxis.Cell.Segment{
                    .{ .text = number_text, .style = number_style },
                    .{ .text = sign_text, .style = sign_style },
                };
                _ = try win.print(&segments, .{ .row_offset = row, .col_offset = col_offset });
            } else {
                if (is_cursor) {
                    const spaces_slice = try RenderUtils.frameTextSlice(self,gutter_width);
                    @memset(spaces_slice, ' ');
                    var seg = [_]vaxis.Cell.Segment{.{
                        .text = spaces_slice,
                        .style = base_style,
                    }};
                    _ = try win.print(&seg, .{ .row_offset = row, .col_offset = col_offset });
                }
            }
        } else {
            if (is_cursor) {
                const spaces_slice = try RenderUtils.frameTextSlice(self,gutter_width);
                @memset(spaces_slice, ' ');
                var seg = [_]vaxis.Cell.Segment{.{
                    .text = spaces_slice,
                    .style = base_style,
                }};
                _ = try win.print(&seg, .{ .row_offset = row, .col_offset = col_offset });
            }
        }
    }

    fn renderHunkHeader(
        self: *App,
        win: vaxis.Window,
        hunk: parser.Hunk,
        line_idx: usize,
        row: usize,
        content_width: usize,
        gutter_width: usize,
    ) !usize {
        var buf: [256]u8 = undefined;

        // Calculate end line numbers for clearer range display
        const old_end = hunk.header.old_start + hunk.header.old_count -| 1;
        const new_end = hunk.header.new_start + hunk.header.new_count -| 1;

        const header_text_stack = try std.fmt.bufPrint(
            &buf,
            "━━ ↕ {d}-{d} → {d}-{d} ━━ {s}",
            .{
                hunk.header.old_start,
                old_end,
                hunk.header.new_start,
                new_end,
                hunk.header.context,
            },
        );

        const is_cursor = line_idx == self.state.cursor_line;
        const style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
        else
            .{ .fg = Color.cyan, .bg = Color.dim };

        // Fill the entire row with dim background first (from gutter to right edge)
        const fill_start = 1; // After left border
        const fill_end = win.width -| 1; // Before right border
        const fill_width = if (fill_end > fill_start) fill_end - fill_start else 0;
        const fill_style: vaxis.Style = .{ .bg = Color.dim };

        if (fill_width > 0) {
            const fill_text = try RenderUtils.frameTextSlice(self,fill_width);
            @memset(fill_text, ' ');
            var fill_seg = [_]vaxis.Cell.Segment{.{
                .text = fill_text,
                .style = fill_style,
            }};
            _ = try win.print(&fill_seg, .{ .row_offset = row, .col_offset = fill_start });
        }

        // Now render the actual content on top
        const content_start = 1 + gutter_width;
        const display_text = blk: {
            const slice = try RenderUtils.frameTextSlice(self,content_width);
            const copy_len = @min(header_text_stack.len, slice.len);
            if (copy_len > 0) {
                @memcpy(slice[0..copy_len], header_text_stack[0..copy_len]);
            }
            if (copy_len < slice.len) {
                @memset(slice[copy_len..], ' ');
            }
            break :blk slice;
        };

        var seg = [_]vaxis.Cell.Segment{.{
            .text = display_text,
            .style = style,
        }};
        _ = try win.print(&seg, .{ .row_offset = row, .col_offset = content_start });

        return 1;
    }

    fn renderWrappedTextAlwaysFilled(
        self: *App,
        win: vaxis.Window,
        text: []const u8,
        line_idx: usize,
        start_row: usize,
        content_width: usize,
        is_cursor: bool,
        style: vaxis.Style,
        file_lineno: ?u32,
        line_type: ?parser.Line.LineType,
        gutter_width: usize,
    ) !usize {
        _ = is_cursor; // Unused - we always fill like cursor is on the line
        if (content_width == 0) return 1;

        // Calculate number of wrapped rows needed
        const num_rows = (text.len + content_width - 1) / content_width;
        if (num_rows == 0) {
            // Empty line - still render one row with full background
            try RenderUtils.renderGutter(self,win, line_idx, start_row, true, true, file_lineno, line_type, gutter_width); // Always fill gutter
            const display_text = try RenderUtils.padTextForCursor(self,"", content_width, true); // Always pad
            var seg = [_]vaxis.Cell.Segment{.{
                .text = display_text,
                .style = style,
            }};
            _ = try win.print(&seg, .{ .row_offset = start_row, .col_offset = 1 + gutter_width });
            return 1;
        }

        var rows_rendered: usize = 0;
        var text_offset: usize = 0;

        while (text_offset < text.len) {
            const current_row = start_row + rows_rendered;
            if (current_row >= win.height) break;

            // Only show line number on first row
            const show_line_number = rows_rendered == 0;
            try RenderUtils.renderGutter(self,win, line_idx, current_row, true, show_line_number, file_lineno, line_type, gutter_width); // Always fill gutter

            // Get the chunk of text for this row
            const remaining = text.len - text_offset;
            const chunk_len = @min(remaining, content_width);
            const chunk = text[text_offset .. text_offset + chunk_len];

            // Render the chunk - always pad
            const display_text = try RenderUtils.padTextForCursor(self,chunk, content_width, true); // Always pad
            var seg = [_]vaxis.Cell.Segment{.{
                .text = display_text,
                .style = style,
            }};
            _ = try win.print(&seg, .{ .row_offset = current_row, .col_offset = 1 + gutter_width });

            text_offset += chunk_len;
            rows_rendered += 1;
        }

        return if (rows_rendered == 0) 1 else rows_rendered;
    }

    fn renderDiffLine(
        self: *App,
        win: vaxis.Window,
        file: *const parser.FileDiff,
        hunk_idx: usize,
        line_idx_in_hunk: usize,
        line: parser.Line,
        line_idx: usize,
        row: usize,
        content_width: usize,
        gutter_width: usize,
    ) !usize {
        const is_cursor = line_idx == self.state.cursor_line;
        const base_style = RenderUtils.getLineStyle(self,line.line_type);
        const style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
        else
            base_style;

        // Use actual file line number from the diff
        // For deletions, show old line number; for additions and context, show new line number
        const file_lineno = switch (line.line_type) {
            .delete => line.old_lineno,
            .add, .context => line.new_lineno,
        };

        // Apply syntax highlighting to all lines (context, additions, deletions)
        // Calculate byte offset for syntax highlighting
        const byte_offset = StateHelpers.getLineByteOffset(file, hunk_idx, line_idx_in_hunk);

        return try self.renderWrappedTextWithHighlights(
            win,
            line.content,
            byte_offset,
            file.highlights,
            line_idx,
            row,
            content_width,
            is_cursor,
            style,
            file_lineno,
            line.line_type,
            gutter_width,
            self.mode == .focused, // show_caret
        );
    }

    // Generate colored segments for a line of text using syntax highlights
    // Returns array of segments with syntax colors applied as foreground
    fn createHighlightedSegments(
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

    // Render wrapped text with syntax highlighting applied
    fn renderWrappedTextWithHighlights(
        self: *App,
        win: vaxis.Window,
        text: []const u8,
        byte_offset: usize,
        highlights: ?[]syntax.Highlight,
        line_idx: usize,
        start_row: usize,
        content_width: usize,
        is_cursor: bool,
        style: vaxis.Style,
        file_lineno: ?u32,
        line_type: ?parser.Line.LineType,
        gutter_width: usize,
        show_caret: bool,
    ) !usize {
        if (content_width == 0) return 1;

        // Handle empty lines explicitly
        if (text.len == 0) {
            try RenderUtils.renderGutter(self,win, line_idx, start_row, is_cursor, true, file_lineno, line_type, gutter_width);
            const display_text = try RenderUtils.padTextForCursor(self,"", content_width, is_cursor);
            var seg = [_]vaxis.Cell.Segment{.{
                .text = display_text,
                .style = style,
            }};
            _ = try win.print(&seg, .{ .row_offset = start_row, .col_offset = 1 + gutter_width });

            // Render caret for empty line in FOCUSED mode
            const visible_cursor_col = if (self.state.cursor_col >= self.state.h_scroll_offset)
                self.state.cursor_col - self.state.h_scroll_offset
            else
                0;
            if (show_caret and is_cursor and visible_cursor_col < content_width) {
                const caret_text = try RenderUtils.copyFrameText(self," ");
                var caret_seg = [_]vaxis.Cell.Segment{.{
                    .text = caret_text,
                    .style = .{ .fg = Color.caret_fg, .bg = Color.caret_bg, .bold = true },
                }};
                _ = try win.print(&caret_seg, .{ .row_offset = start_row, .col_offset = 1 + gutter_width + visible_cursor_col });
            }

            return 1;
        }

        // Apply horizontal scrolling - start rendering from h_scroll_offset
        const h_scroll = self.state.h_scroll_offset;
        const start_offset = @min(h_scroll, text.len);

        var rows_rendered: usize = 0;
        var text_offset: usize = start_offset;

        while (text_offset < text.len) {
            const current_row = start_row + rows_rendered;
            if (current_row >= win.height) break;

            // Only show line number on first row
            const show_line_number = rows_rendered == 0;
            try RenderUtils.renderGutter(self,win, line_idx, current_row, is_cursor, show_line_number, file_lineno, line_type, gutter_width);

            // Get the chunk of text for this row
            const remaining = text.len - text_offset;
            const chunk_len = @min(remaining, content_width);
            const chunk = text[text_offset .. text_offset + chunk_len];

            // Generate syntax-highlighted segments for this chunk
            const chunk_byte_offset = byte_offset + text_offset;
            const segments = try self.createHighlightedSegments(chunk, chunk_byte_offset, highlights, style);
            defer self.allocator.free(segments);

            // If cursor is on this line, we need to pad the segments
            if (is_cursor and chunk.len < content_width) {
                // Create a new segments array with padding
                const padded_segments = try self.allocator.alloc(vaxis.Cell.Segment, segments.len + 1);
                defer self.allocator.free(padded_segments);

                @memcpy(padded_segments[0..segments.len], segments);

                // Add padding segment
                const padding_len = content_width - chunk.len;
                const padding = try RenderUtils.frameTextSlice(self,padding_len);
                @memset(padding, ' ');
                padded_segments[segments.len] = .{
                    .text = padding,
                    .style = style,
                };

                _ = try win.print(padded_segments, .{ .row_offset = current_row, .col_offset = 1 + gutter_width });
            } else {
                _ = try win.print(segments, .{ .row_offset = current_row, .col_offset = 1 + gutter_width });
            }

            // Render caret in FOCUSED mode
            if (show_caret and is_cursor) {
                const cursor_col = self.state.cursor_col;
                const h_scroll_off = self.state.h_scroll_offset;

                // Calculate visible cursor position (accounting for horizontal scroll)
                if (cursor_col >= h_scroll_off and cursor_col < h_scroll_off + content_width) {
                    const visible_col = cursor_col - h_scroll_off;

                    // Check if cursor_col falls within this chunk
                    if (cursor_col >= text_offset and cursor_col < text_offset + chunk_len) {
                        const col_in_chunk = cursor_col - text_offset;
                        const caret_char = if (col_in_chunk < chunk.len) chunk[col_in_chunk .. col_in_chunk + 1] else " ";

                        // Render caret with bright yellow background at visible position
                        const caret_text = try RenderUtils.copyFrameText(self,caret_char);
                        var caret_seg = [_]vaxis.Cell.Segment{.{
                            .text = caret_text,
                            .style = .{ .fg = Color.caret_fg, .bg = Color.caret_bg, .bold = true },
                        }};
                        _ = try win.print(&caret_seg, .{ .row_offset = current_row, .col_offset = 1 + gutter_width + visible_col });
                    }
                }
            }

            text_offset += chunk_len;
            rows_rendered += 1;
        }

        return if (rows_rendered == 0) 1 else rows_rendered;
    }

    fn renderWrappedText(
        self: *App,
        win: vaxis.Window,
        text: []const u8,
        line_idx: usize,
        start_row: usize,
        content_width: usize,
        is_cursor: bool,
        style: vaxis.Style,
        file_lineno: ?u32,
        line_type: ?parser.Line.LineType,
        gutter_width: usize,
    ) !usize {
        if (content_width == 0) return 1;

        // Handle empty lines explicitly
        if (text.len == 0) {
            try RenderUtils.renderGutter(self,win, line_idx, start_row, is_cursor, true, file_lineno, line_type, gutter_width);
            const display_text = try RenderUtils.padTextForCursor(self,"", content_width, is_cursor);
            var seg = [_]vaxis.Cell.Segment{.{
                .text = display_text,
                .style = style,
            }};
            _ = try win.print(&seg, .{ .row_offset = start_row, .col_offset = 1 + gutter_width });
            return 1;
        }

        var rows_rendered: usize = 0;
        var text_offset: usize = 0;

        while (text_offset < text.len) {
            const current_row = start_row + rows_rendered;
            if (current_row >= win.height) break;

            // Only show line number on first row
            const show_line_number = rows_rendered == 0;
            try RenderUtils.renderGutter(self,win, line_idx, current_row, is_cursor, show_line_number, file_lineno, line_type, gutter_width);

            // Get the chunk of text for this row
            const remaining = text.len - text_offset;
            const chunk_len = @min(remaining, content_width);
            const chunk = text[text_offset .. text_offset + chunk_len];

            // Render the chunk
            const display_text = try RenderUtils.padTextForCursor(self,chunk, content_width, is_cursor);
            var seg = [_]vaxis.Cell.Segment{.{
                .text = display_text,
                .style = style,
            }};
            _ = try win.print(&seg, .{ .row_offset = current_row, .col_offset = 1 + gutter_width });

            text_offset += chunk_len;
            rows_rendered += 1;
        }

        return if (rows_rendered == 0) 1 else rows_rendered;
    }

    fn renderGutter(self: *App, win: vaxis.Window, line_idx: usize, row: usize, is_cursor: bool, show_number: bool, file_lineno: ?u32, line_type: ?parser.Line.LineType, gutter_width: usize) !void {
        _ = line_idx; // No longer used, but kept for API compatibility

        const base_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.white, .bg = Color.dim }
        else
            .{ .fg = Color.dim };

        if (show_number) {
            if (file_lineno) |lineno| {
                // Show line number and diff sign (GitHub style: number right-justified, sign after)
                const sign: []const u8 = if (line_type) |lt| switch (lt) {
                    .add => "+",
                    .delete => "-",
                    .context => " ",
                } else " ";

                // Format number
                var num_buf: [16]u8 = undefined;
                const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{lineno});
                const num_width = gutter_width - 1; // Reserve 1 char for sign
                const padding_needed = num_width -| num_str.len;

                // Build gutter with right-justified number and sign
                var buf: [32]u8 = undefined;
                var i: usize = 0;
                while (i < padding_needed) : (i += 1) {
                    buf[i] = ' ';
                }
                @memcpy(buf[padding_needed .. padding_needed + num_str.len], num_str);
                const sign_pos = padding_needed + num_str.len;
                @memcpy(buf[sign_pos .. sign_pos + sign.len], sign);

                const gutter_text = try RenderUtils.copyFrameText(self,buf[0 .. sign_pos + sign.len]);

                // Color the sign based on line type (with matching background)
                const sign_style: vaxis.Style = if (line_type) |lt| switch (lt) {
                    .add => if (is_cursor)
                        .{ .fg = Color.green, .bg = Color.cursor_bg, .bold = true }
                    else
                        .{ .fg = Color.green, .bg = Color.diff_add_bg, .bold = true },
                    .delete => if (is_cursor)
                        .{ .fg = Color.red, .bg = Color.cursor_bg, .bold = true }
                    else
                        .{ .fg = Color.red, .bg = Color.diff_delete_bg, .bold = true },
                    .context => if (is_cursor)
                        .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
                    else
                        .{ .fg = Color.dim },
                } else base_style;

                const number_style: vaxis.Style = base_style;

                // Split into number and sign segments for different colors
                const number_text = gutter_text[0 .. gutter_text.len - 1];
                const sign_text = gutter_text[gutter_text.len - 1 ..];

                var segments = [_]vaxis.Cell.Segment{
                    .{ .text = number_text, .style = number_style },
                    .{ .text = sign_text, .style = sign_style },
                };
                _ = try win.print(&segments, .{ .row_offset = row, .col_offset = 1 });
            } else {
                // For hunk headers or other lines without file line numbers, always show empty gutter
                const spaces_slice = try RenderUtils.frameTextSlice(self,gutter_width);
                @memset(spaces_slice, ' ');
                var seg = [_]vaxis.Cell.Segment{.{
                    .text = spaces_slice,
                    .style = base_style,
                }};
                _ = try win.print(&seg, .{ .row_offset = row, .col_offset = 1 });
            }
        } else {
            // For wrapped continuation lines, always show empty gutter
            const spaces_slice = try RenderUtils.frameTextSlice(self,gutter_width);
            @memset(spaces_slice, ' ');
            var seg = [_]vaxis.Cell.Segment{.{
                .text = spaces_slice,
                .style = base_style,
            }};
            _ = try win.print(&seg, .{ .row_offset = row, .col_offset = 1 });
        }
    }

    fn padTextForCursor(self: *App, text: []const u8, width: usize, is_cursor: bool) ![]const u8 {
        if (!is_cursor) return text;

        if (width > RenderUtils.remainingFrameTextCapacity(self)) return error.FrameTextBufferOverflow;

        const slice = try RenderUtils.frameTextSlice(self,width);
        const copy_len = @min(text.len, slice.len);

        if (copy_len > 0) {
            @memcpy(slice[0..copy_len], text[0..copy_len]);
        }
        if (copy_len < slice.len) {
            @memset(slice[copy_len..], ' ');
        }

        return slice;
    }

    fn resetFrameTextBuffer(self: *App) void {
        self.frame_text_used = 0;
    }

    fn remainingFrameTextCapacity(self: *App) usize {
        return self.frame_text_buffer.len - self.frame_text_used;
    }

    fn frameTextSlice(self: *App, len: usize) ![]u8 {
        if (len == 0) return self.frame_text_buffer[0..0];
        if (len > RenderUtils.remainingFrameTextCapacity(self)) return error.FrameTextBufferOverflow;

        const start = self.frame_text_used;
        const end = start + len;
        self.frame_text_used = end;
        return self.frame_text_buffer[start..end];
    }

    fn copyFrameText(self: *App, text: []const u8) ![]const u8 {
        const slice = try RenderUtils.frameTextSlice(self,text.len);
        if (text.len > 0) {
            @memcpy(slice, text);
        }
        return slice;
    }

    fn getLineStyle(self: *App, line_type: parser.Line.LineType) vaxis.Style {
        _ = self;
        return switch (line_type) {
            .add => .{ .bg = Color.diff_add_bg, .fg = Color.diff_add_fg },
            .delete => .{ .bg = Color.diff_delete_bg, .fg = Color.diff_delete_fg },
            .context => .{},
        };
    }
};
