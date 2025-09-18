const std = @import("std");
const vaxis = @import("vaxis");
const git = @import("git/diff.zig");
const parser = @import("git/parser.zig");
const DiffSource = git.DiffSource;

const Allocator = std.mem.Allocator;
const Vaxis = vaxis.Vaxis;
const Event = vaxis.Event;

// Color constants for terminal output
const Color = struct {
    const black = .{ .index = 0 };
    const red = .{ .index = 1 };
    const green = .{ .index = 2 };
    const blue = .{ .index = 4 };
    const cyan = .{ .index = 6 };
    const white = .{ .index = 7 };
    const dim = .{ .index = 8 };
};

// Layout constants
const Layout = struct {
    const header_height = 2;
    const divider_height = 1;
    const status_height = 1;
    const gutter_width = 5; // Supports up to 99,999 lines
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
        view_mode: ViewMode,
        viewport_height: usize,

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
                .view_mode = .unified,
                .viewport_height = 0,
            },
            .should_quit = false,
            .last_ctrl_c = 0,
            .header_line_buffers = header_buffers,
            .frame_text_buffer = frame_buffer,
            .frame_text_used = 0,
        };
    }

    pub fn deinit(self: *App) void {
        for (self.state.files) |*file| {
            file.deinit(self.allocator);
        }
        self.allocator.free(self.state.files);
        self.allocator.free(self.frame_text_buffer);
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
        self.resetFileState();
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
        switch (key.codepoint) {
            'q' => self.should_quit = true,
            'j' => self.moveCursorDown(),
            'k' => self.moveCursorUp(),
            'h' => self.navigateToPreviousFile(),
            'l' => self.navigateToNextFile(),
            '\r' => self.mode = .focused,
            's' => self.toggleViewMode(),
            'r' => try self.refresh(),
            else => {},
        }

        if (key.mods.ctrl) {
            switch (key.codepoint) {
                'n' => self.navigateToNextFile(),
                'p' => self.navigateToPreviousFile(),
                'd' => self.pageDown(),
                'u' => self.pageUp(),
                else => {},
            }
        }
    }

    fn moveCursorDown(self: *App) void {
        const total_lines = self.getTotalLinesInCurrentFile();
        if (self.state.cursor_line + 1 < total_lines) {
            self.state.cursor_line += 1;
        }
    }

    fn moveCursorUp(self: *App) void {
        if (self.state.cursor_line > 0) {
            self.state.cursor_line -= 1;
        }
    }

    fn navigateToNextFile(self: *App) void {
        if (self.state.current_file_idx + 1 < self.state.files.len) {
            self.state.current_file_idx += 1;
            self.resetFileState();
        }
    }

    fn navigateToPreviousFile(self: *App) void {
        if (self.state.current_file_idx > 0) {
            self.state.current_file_idx -= 1;
            self.resetFileState();
        }
    }

    fn resetFileState(self: *App) void {
        self.state.scroll_offset = 0;
        self.state.cursor_line = 0;
    }

    fn toggleViewMode(self: *App) void {
        self.state.view_mode = switch (self.state.view_mode) {
            .unified => .side_by_side,
            .side_by_side => .unified,
        };
    }

    fn pageDown(self: *App) void {
        const scroll_amount = self.state.viewport_height / 2;
        const total_lines = self.getTotalLinesInCurrentFile();

        // Move cursor down by half viewport, clamped to last line
        if (total_lines > 0) {
            self.state.cursor_line = @min(
                self.state.cursor_line + scroll_amount,
                total_lines - 1
            );
        }

        // Move viewport down by same amount to maintain screen position
        self.state.scroll_offset += scroll_amount;
        self.clampScrollOffset();
    }

    fn pageUp(self: *App) void {
        const scroll_amount = self.state.viewport_height / 2;

        // Move cursor up by half viewport, clamped to 0
        if (self.state.cursor_line >= scroll_amount) {
            self.state.cursor_line -= scroll_amount;
        } else {
            self.state.cursor_line = 0;
        }

        // Move viewport up by same amount to maintain screen position
        if (self.state.scroll_offset >= scroll_amount) {
            self.state.scroll_offset -= scroll_amount;
        } else {
            self.state.scroll_offset = 0;
        }
    }

    fn getTotalLinesInCurrentFile(self: *App) usize {
        if (self.state.current_file_idx >= self.state.files.len) return 0;

        const file = &self.state.files[self.state.current_file_idx];
        var total: usize = 0;

        for (file.hunks) |hunk| {
            total += 1; // hunk header
            total += hunk.lines.len;
        }

        return total;
    }

    fn clampScrollOffset(self: *App) void {
        const total_lines = self.getTotalLinesInCurrentFile();
        const viewport_height = self.state.viewport_height;

        // Calculate max scroll offset (vim-style: can't scroll past end)
        const max_scroll = if (total_lines > viewport_height)
            total_lines - viewport_height
        else
            0;

        if (self.state.scroll_offset > max_scroll) {
            self.state.scroll_offset = max_scroll;
        }
    }

    fn handleFocusedMode(self: *App, key: vaxis.Key) !void {
        switch (key.codepoint) {
            27 => self.mode = .normal, // ESC
            'j' => self.scrollDown(),
            'k' => self.scrollUp(),
            'g' => self.scrollToTop(),
            'G' => self.scrollToBottom(),
            else => {},
        }

        if (key.mods.ctrl) {
            switch (key.codepoint) {
                'n' => self.scrollDown(),
                'p' => self.scrollUp(),
                'd' => self.scrollPageDown(),
                'u' => self.scrollPageUp(),
                else => {},
            }
        }
    }

    fn scrollDown(self: *App) void {
        self.state.scroll_offset += 1;
        self.clampScrollOffset();
    }

    fn scrollUp(self: *App) void {
        if (self.state.scroll_offset > 0) {
            self.state.scroll_offset -= 1;
        }
    }

    fn scrollToTop(self: *App) void {
        self.state.scroll_offset = 0;
    }

    fn scrollToBottom(self: *App) void {
        const total_lines = self.getTotalLinesInCurrentFile();
        const viewport_height = self.state.viewport_height;
        self.state.scroll_offset = if (total_lines > viewport_height)
            total_lines - viewport_height
        else
            0;
    }

    fn scrollPageDown(self: *App) void {
        const scroll_amount = self.state.viewport_height / 2;
        const total_lines = self.getTotalLinesInCurrentFile();

        // Move cursor down by half viewport, clamped to last line
        if (total_lines > 0) {
            self.state.cursor_line = @min(
                self.state.cursor_line + scroll_amount,
                total_lines - 1
            );
        }

        // Move viewport down by same amount to maintain screen position
        self.state.scroll_offset += scroll_amount;
        self.clampScrollOffset();
    }

    fn scrollPageUp(self: *App) void {
        const scroll_amount = self.state.viewport_height / 2;

        // Move cursor up by half viewport, clamped to 0
        if (self.state.cursor_line >= scroll_amount) {
            self.state.cursor_line -= scroll_amount;
        } else {
            self.state.cursor_line = 0;
        }

        // Move viewport up by same amount to maintain screen position
        if (self.state.scroll_offset >= scroll_amount) {
            self.state.scroll_offset -= scroll_amount;
        } else {
            self.state.scroll_offset = 0;
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
        self.resetFrameTextBuffer();

        if (self.state.files.len == 0) {
            try self.renderEmpty(win);
            return;
        }

        const content_height = win.height - Layout.header_height - Layout.divider_height - Layout.status_height - 1;

        const header_win = win.child(.{
            .x_off = 0,
            .y_off = 0,
            .width = .{ .limit = win.width },
            .height = .{ .limit = Layout.header_height },
        });
        try self.renderHeader(header_win);

        const divider_top_win = win.child(.{
            .x_off = 0,
            .y_off = Layout.header_height,
            .width = .{ .limit = win.width },
            .height = .{ .limit = Layout.divider_height },
        });
        try self.renderDivider(divider_top_win, .top);

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
        try self.renderDivider(divider_bottom_win, .bottom);

        const status_win = win.child(.{
            .x_off = 0,
            .y_off = win.height - Layout.status_height,
            .width = .{ .limit = win.width },
            .height = .{ .limit = Layout.status_height },
        });
        try self.renderStatus(status_win);
    }

    const DividerPosition = enum {
        top,
        middle,
        bottom,
    };

    fn renderDivider(self: *App, win: vaxis.Window, position: DividerPosition) !void {
        if (win.width == 0) return;

        const width = win.width;
        const left_char = switch (position) {
            .top => FrameChars.top_left,
            .middle => FrameChars.middle_left,
            .bottom => FrameChars.bottom_left,
        };
        const right_char = switch (position) {
            .top => FrameChars.top_right,
            .middle => FrameChars.middle_right,
            .bottom => FrameChars.bottom_right,
        };

        // Build the divider line
        const left_corner = try self.copyFrameText(left_char);
        const right_corner = try self.copyFrameText(right_char);

        // Calculate number of horizontal characters needed (width in cells minus 2 for corners)
        const num_h_chars = if (width > 2) width - 2 else 0;

        // Calculate byte length needed (each horizontal char is 3 bytes in UTF-8)
        const h_line_len = num_h_chars * FrameChars.horizontal.len;

        const h_line = if (h_line_len > 0) blk: {
            const line = try self.frameTextSlice(h_line_len);
            // Fill with horizontal characters
            var i: usize = 0;
            while (i < num_h_chars) : (i += 1) {
                const pos = i * FrameChars.horizontal.len;
                @memcpy(line[pos .. pos + FrameChars.horizontal.len], FrameChars.horizontal);
            }
            break :blk line;
        } else "";

        // Print left corner
        var left_seg = [_]vaxis.Cell.Segment{.{
            .text = left_corner,
            .style = .{ .fg = Color.dim },
        }};
        _ = try win.print(&left_seg, .{ .row_offset = 0 });

        // Print horizontal line
        if (h_line.len > 0) {
            var h_seg = [_]vaxis.Cell.Segment{.{
                .text = h_line,
                .style = .{ .fg = Color.dim },
            }};
            _ = try win.print(&h_seg, .{ .row_offset = 0, .col_offset = 1 });
        }

        // Print right corner
        var right_seg = [_]vaxis.Cell.Segment{.{
            .text = right_corner,
            .style = .{ .fg = Color.dim },
        }};
        _ = try win.print(&right_seg, .{ .row_offset = 0, .col_offset = win.width -| 1 });
    }

    fn renderEmpty(self: *App, win: vaxis.Window) !void {
        _ = self;
        const msg = "No changes to review";
        const row = win.height / 2;
        const col = (win.width -| msg.len) / 2;

        var seg = [_]vaxis.Cell.Segment{.{
            .text = msg,
            .style = .{ .fg = Color.dim },
        }};
        _ = try win.print(&seg, .{ .row_offset = row, .col_offset = col });
    }

    fn renderHeader(self: *App, win: vaxis.Window) !void {
        if (win.height == 0 or win.width == 0) return;
        win.clear();

        if (self.state.current_file_idx >= self.state.files.len) return;

        const current_file = &self.state.files[self.state.current_file_idx];
        const stats = self.calculateDiffStats(current_file);

        const mode_str = switch (self.mode) {
            .normal => "[NORMAL]",
            .focused => "[FOCUSED]",
            .comment => "[COMMENT]",
        };
        const view_str = switch (self.state.view_mode) {
            .unified => "Unified",
            .side_by_side => "Side-by-Side",
        };

        var buf: [1024]u8 = undefined;
        const header_text = try std.fmt.bufPrint(&buf, "Files ({d}) {s}  {s}", .{
            self.state.files.len,
            mode_str,
            view_str,
        });
        try self.printHeaderLine(win, 0, header_text, .{ .bold = true });

        const file_path = if (current_file.new_path.len > 0) current_file.new_path else current_file.old_path;

        var buf2: [2048]u8 = undefined;
        const file_text = try std.fmt.bufPrint(&buf2, "File {d} of {d}  {s}  +{d} -{d}", .{
            self.state.current_file_idx + 1,
            self.state.files.len,
            file_path,
            stats.additions,
            stats.deletions,
        });
        try self.printHeaderLine(win, 1, file_text, .{ .fg = Color.blue });
    }

    fn calculateDiffStats(self: *App, file: *const parser.FileDiff) struct { additions: usize, deletions: usize } {
        _ = self;
        var additions: usize = 0;
        var deletions: usize = 0;

        for (file.hunks) |hunk| {
            for (hunk.lines) |line| {
                switch (line.line_type) {
                    .add => additions += 1,
                    .delete => deletions += 1,
                    .context => {},
                }
            }
        }

        return .{ .additions = additions, .deletions = deletions };
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
        self.state.viewport_height = win.height;
        self.clampScrollOffset();
        self.adjustScrollToKeepCursorVisible(win.height);

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

        const content_width = win.width -| (2 + Layout.gutter_width);
        var row: usize = 0;
        var line_idx: usize = 0;

        for (file.hunks) |hunk| {
            if (line_idx + hunk.lines.len < self.state.scroll_offset) {
                line_idx += hunk.lines.len + 1; // +1 for hunk header
                continue;
            }

            if (line_idx >= self.state.scroll_offset) {
                if (row >= win.height) break;
                const rows_used = try self.renderHunkHeader(win, hunk, line_idx, row, content_width);
                row += rows_used;
            }
            line_idx += 1;

            for (hunk.lines) |line| {
                if (line_idx < self.state.scroll_offset) {
                    line_idx += 1;
                    continue;
                }

                if (row >= win.height) break;
                const rows_used = try self.renderDiffLine(win, line, line_idx, row, content_width);
                row += rows_used;
                line_idx += 1;
            }
        }
    }

    fn renderContentSideBySide(self: *App, win: vaxis.Window) !void {
        if (self.state.current_file_idx >= self.state.files.len) return;

        const file = &self.state.files[self.state.current_file_idx];
        self.state.viewport_height = win.height;
        self.clampScrollOffset();
        self.adjustScrollToKeepCursorVisible(win.height);

        // Calculate layout: [border][gutter][left_content][divider][gutter][right_content][border]
        // Total width = 2 (borders) + 2 * gutter_width + 1 (middle divider) + left_content + right_content
        const total_borders_and_gutters = 2 + (2 * Layout.gutter_width) + 1;
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
            const middle_col = 1 + Layout.gutter_width + left_content_width;
            var middle_seg = [_]vaxis.Cell.Segment{.{
                .text = FrameChars.vertical,
                .style = border_style,
            }};
            _ = try win.print(&middle_seg, .{ .row_offset = border_row, .col_offset = middle_col });
        }

        var row: usize = 0;
        var line_idx: usize = 0;

        for (file.hunks) |hunk| {
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
                );
                row += rows_used;
            }
            line_idx += 1;

            // Render diff lines
            for (hunk.lines) |line| {
                if (line_idx < self.state.scroll_offset) {
                    line_idx += 1;
                    continue;
                }

                if (row >= win.height) break;
                const rows_used = try self.renderDiffLineSideBySide(
                    win,
                    line,
                    line_idx,
                    row,
                    left_content_width,
                    right_content_width,
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

        const header_text = try self.copyFrameText(header_text_stack);
        const is_cursor = line_idx == self.state.cursor_line;
        const style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.white, .bg = Color.dim }
        else
            .{ .fg = Color.cyan, .bg = Color.dim };

        // Calculate how many rows this will take (same on both sides)
        const num_rows = if (header_text.len == 0) 1 else (header_text.len + left_width - 1) / left_width;

        const right_col = 1 + Layout.gutter_width + left_width + 1; // +1 for middle divider

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
                const fill_text = try self.frameTextSlice(fill_width);
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
                const slice = try self.frameTextSlice(left_width);
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
            _ = try win.print(&left_seg, .{ .row_offset = current_row, .col_offset = 1 + Layout.gutter_width });

            // Render right content
            const right_text_start = wrap_idx * right_width;
            const right_text_end = @min(right_text_start + right_width, header_text.len);
            const right_chunk = if (right_text_start < header_text.len) header_text[right_text_start..right_text_end] else "";

            const right_display = blk: {
                const slice = try self.frameTextSlice(right_width);
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
            _ = try win.print(&right_seg, .{ .row_offset = current_row, .col_offset = right_col + Layout.gutter_width });

            current_row += 1;
        }

        return if (num_rows == 0) 1 else num_rows;
    }

    fn renderDiffLineSideBySide(
        self: *App,
        win: vaxis.Window,
        line: parser.Line,
        line_idx: usize,
        row: usize,
        left_width: usize,
        right_width: usize,
    ) !usize {
        const is_cursor = line_idx == self.state.cursor_line;
        const base_style = self.getLineStyle(line.line_type);
        const style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.white, .bg = Color.dim }
        else
            base_style;

        const right_col = 1 + Layout.gutter_width + left_width + 1; // +1 for middle divider

        switch (line.line_type) {
            .context => {
                // Show on both sides - calculate rows based on left width
                const num_rows = if (line.content.len == 0) 1 else (line.content.len + left_width - 1) / left_width;

                var current_row = row;
                for (0..num_rows) |wrap_idx| {
                    if (current_row >= win.height) break;

                    const show_lineno = wrap_idx == 0;

                    // Render left side
                    try self.renderGutter(win, line_idx, current_row, is_cursor, show_lineno, line.old_lineno);

                    const left_start = wrap_idx * left_width;
                    const left_end = @min(left_start + left_width, line.content.len);
                    const left_chunk = if (left_start < line.content.len) line.content[left_start..left_end] else "";

                    const left_display = if (is_cursor) blk: {
                        const slice = try self.frameTextSlice(left_width);
                        if (left_chunk.len > 0) {
                            @memcpy(slice[0..left_chunk.len], left_chunk);
                        }
                        if (left_chunk.len < left_width) {
                            @memset(slice[left_chunk.len..], ' ');
                        }
                        break :blk slice;
                    } else left_chunk;

                    var left_seg = [_]vaxis.Cell.Segment{.{
                        .text = left_display,
                        .style = style,
                    }};
                    _ = try win.print(&left_seg, .{ .row_offset = current_row, .col_offset = 1 + Layout.gutter_width });

                    // Render right side (same content)
                    try self.renderGutterAtColumn(win, line_idx, current_row, is_cursor, show_lineno, line.new_lineno, right_col);

                    const right_start = wrap_idx * right_width;
                    const right_end = @min(right_start + right_width, line.content.len);
                    const right_chunk = if (right_start < line.content.len) line.content[right_start..right_end] else "";

                    const right_display = if (is_cursor) blk: {
                        const slice = try self.frameTextSlice(right_width);
                        if (right_chunk.len > 0) {
                            @memcpy(slice[0..right_chunk.len], right_chunk);
                        }
                        if (right_chunk.len < right_width) {
                            @memset(slice[right_chunk.len..], ' ');
                        }
                        break :blk slice;
                    } else right_chunk;

                    var right_seg = [_]vaxis.Cell.Segment{.{
                        .text = right_display,
                        .style = style,
                    }};
                    _ = try win.print(&right_seg, .{ .row_offset = current_row, .col_offset = right_col + Layout.gutter_width });

                    current_row += 1;
                }

                return if (num_rows == 0) 1 else num_rows;
            },
            .delete => {
                // Show on left only, wrap as needed
                const num_rows = if (line.content.len == 0) 1 else (line.content.len + left_width - 1) / left_width;

                var current_row = row;
                for (0..num_rows) |wrap_idx| {
                    if (current_row >= win.height) break;

                    const show_lineno = wrap_idx == 0;

                    // Render left side
                    try self.renderGutter(win, line_idx, current_row, is_cursor, show_lineno, line.old_lineno);

                    const text_start = wrap_idx * left_width;
                    const text_end = @min(text_start + left_width, line.content.len);
                    const chunk = if (text_start < line.content.len) line.content[text_start..text_end] else "";

                    const left_display = if (is_cursor) blk: {
                        const slice = try self.frameTextSlice(left_width);
                        if (chunk.len > 0) {
                            @memcpy(slice[0..chunk.len], chunk);
                        }
                        if (chunk.len < left_width) {
                            @memset(slice[chunk.len..], ' ');
                        }
                        break :blk slice;
                    } else chunk;

                    var left_seg = [_]vaxis.Cell.Segment{.{
                        .text = left_display,
                        .style = style,
                    }};
                    _ = try win.print(&left_seg, .{ .row_offset = current_row, .col_offset = 1 + Layout.gutter_width });

                    // Right side empty with cursor highlight if needed
                    if (is_cursor) {
                        try self.renderGutterAtColumn(win, line_idx, current_row, is_cursor, false, null, right_col);
                        const blank = try self.frameTextSlice(right_width);
                        @memset(blank, ' ');
                        var blank_seg = [_]vaxis.Cell.Segment{.{
                            .text = blank,
                            .style = .{ .fg = Color.white, .bg = Color.dim },
                        }};
                        _ = try win.print(&blank_seg, .{ .row_offset = current_row, .col_offset = right_col + Layout.gutter_width });
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
                        try self.renderGutter(win, line_idx, current_row, is_cursor, false, null);
                        const blank = try self.frameTextSlice(left_width);
                        @memset(blank, ' ');
                        var blank_seg = [_]vaxis.Cell.Segment{.{
                            .text = blank,
                            .style = .{ .fg = Color.white, .bg = Color.dim },
                        }};
                        _ = try win.print(&blank_seg, .{ .row_offset = current_row, .col_offset = 1 + Layout.gutter_width });
                    }

                    // Render right side
                    try self.renderGutterAtColumn(win, line_idx, current_row, is_cursor, show_lineno, line.new_lineno, right_col);

                    const text_start = wrap_idx * right_width;
                    const text_end = @min(text_start + right_width, line.content.len);
                    const chunk = if (text_start < line.content.len) line.content[text_start..text_end] else "";

                    const right_display = if (is_cursor) blk: {
                        const slice = try self.frameTextSlice(right_width);
                        if (chunk.len > 0) {
                            @memcpy(slice[0..chunk.len], chunk);
                        }
                        if (chunk.len < right_width) {
                            @memset(slice[chunk.len..], ' ');
                        }
                        break :blk slice;
                    } else chunk;

                    var right_seg = [_]vaxis.Cell.Segment{.{
                        .text = right_display,
                        .style = style,
                    }};
                    _ = try win.print(&right_seg, .{ .row_offset = current_row, .col_offset = right_col + Layout.gutter_width });

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
    ) !void {
        _ = line_idx;

        const style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.white, .bg = Color.dim }
        else
            .{ .fg = Color.dim };

        if (show_number) {
            if (file_lineno) |lineno| {
                var buf: [16]u8 = undefined;
                const gutter_stack = try std.fmt.bufPrint(&buf, "{d}", .{lineno});
                const gutter_text = try self.copyFrameText(gutter_stack);

                var seg = [_]vaxis.Cell.Segment{.{
                    .text = gutter_text,
                    .style = style,
                }};
                _ = try win.print(&seg, .{ .row_offset = row, .col_offset = col_offset });
            } else {
                if (is_cursor) {
                    const spaces = try self.copyFrameText("     ");
                    var seg = [_]vaxis.Cell.Segment{.{
                        .text = spaces,
                        .style = style,
                    }};
                    _ = try win.print(&seg, .{ .row_offset = row, .col_offset = col_offset });
                }
            }
        } else {
            if (is_cursor) {
                const spaces = try self.copyFrameText("     ");
                var seg = [_]vaxis.Cell.Segment{.{
                    .text = spaces,
                    .style = style,
                }};
                _ = try win.print(&seg, .{ .row_offset = row, .col_offset = col_offset });
            }
        }
    }

    fn adjustScrollToKeepCursorVisible(self: *App, window_height: usize) void {
        const padding = Layout.cursor_padding;
        const cursor_line = self.state.cursor_line;
        const scroll_offset = self.state.scroll_offset;

        if (cursor_line < scroll_offset + padding) {
            self.state.scroll_offset = if (cursor_line >= padding)
                cursor_line - padding
            else
                0;
        } else if (cursor_line >= scroll_offset + window_height -| (padding + 1)) {
            self.state.scroll_offset = cursor_line -| (window_height -| (padding + 2));
        }
    }

    fn renderHunkHeader(
        self: *App,
        win: vaxis.Window,
        hunk: parser.Hunk,
        line_idx: usize,
        row: usize,
        content_width: usize,
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
            .{ .fg = Color.white, .bg = Color.dim }
        else
            .{ .fg = Color.cyan, .bg = Color.dim };

        // Fill the entire row with dim background first (from gutter to right edge)
        const fill_start = 1; // After left border
        const fill_end = win.width -| 1; // Before right border
        const fill_width = if (fill_end > fill_start) fill_end - fill_start else 0;
        const fill_style: vaxis.Style = .{ .bg = Color.dim };

        if (fill_width > 0) {
            const fill_text = try self.frameTextSlice(fill_width);
            @memset(fill_text, ' ');
            var fill_seg = [_]vaxis.Cell.Segment{.{
                .text = fill_text,
                .style = fill_style,
            }};
            _ = try win.print(&fill_seg, .{ .row_offset = row, .col_offset = fill_start });
        }

        // Now render the actual content on top
        const content_start = 1 + Layout.gutter_width;
        const display_text = blk: {
            const slice = try self.frameTextSlice(content_width);
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
    ) !usize {
        _ = is_cursor; // Unused - we always fill like cursor is on the line
        if (content_width == 0) return 1;

        // Calculate number of wrapped rows needed
        const num_rows = (text.len + content_width - 1) / content_width;
        if (num_rows == 0) {
            // Empty line - still render one row with full background
            try self.renderGutter(win, line_idx, start_row, true, true, file_lineno); // Always fill gutter
            const display_text = try self.padTextForCursor("", content_width, true); // Always pad
            var seg = [_]vaxis.Cell.Segment{.{
                .text = display_text,
                .style = style,
            }};
            _ = try win.print(&seg, .{ .row_offset = start_row, .col_offset = 1 + Layout.gutter_width });
            return 1;
        }

        var rows_rendered: usize = 0;
        var text_offset: usize = 0;

        while (text_offset < text.len) {
            const current_row = start_row + rows_rendered;
            if (current_row >= win.height) break;

            // Only show line number on first row
            const show_line_number = rows_rendered == 0;
            try self.renderGutter(win, line_idx, current_row, true, show_line_number, file_lineno); // Always fill gutter

            // Get the chunk of text for this row
            const remaining = text.len - text_offset;
            const chunk_len = @min(remaining, content_width);
            const chunk = text[text_offset .. text_offset + chunk_len];

            // Render the chunk - always pad
            const display_text = try self.padTextForCursor(chunk, content_width, true); // Always pad
            var seg = [_]vaxis.Cell.Segment{.{
                .text = display_text,
                .style = style,
            }};
            _ = try win.print(&seg, .{ .row_offset = current_row, .col_offset = 1 + Layout.gutter_width });

            text_offset += chunk_len;
            rows_rendered += 1;
        }

        return if (rows_rendered == 0) 1 else rows_rendered;
    }

    fn renderDiffLine(
        self: *App,
        win: vaxis.Window,
        line: parser.Line,
        line_idx: usize,
        row: usize,
        content_width: usize,
    ) !usize {
        const is_cursor = line_idx == self.state.cursor_line;
        const base_style = self.getLineStyle(line.line_type);
        const style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.white, .bg = Color.dim }
        else
            base_style;

        // Use actual file line number from the diff
        // For deletions, show old line number; for additions and context, show new line number
        const file_lineno = switch (line.line_type) {
            .delete => line.old_lineno,
            .add, .context => line.new_lineno,
        };

        return try self.renderWrappedText(win, line.content, line_idx, row, content_width, is_cursor, style, file_lineno);
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
    ) !usize {
        if (content_width == 0) return 1;

        // Calculate number of wrapped rows needed
        const num_rows = (text.len + content_width - 1) / content_width;
        if (num_rows == 0) {
            // Empty line - still render one row
            try self.renderGutter(win, line_idx, start_row, is_cursor, true, file_lineno);
            const display_text = try self.padTextForCursor("", content_width, is_cursor);
            var seg = [_]vaxis.Cell.Segment{.{
                .text = display_text,
                .style = style,
            }};
            _ = try win.print(&seg, .{ .row_offset = start_row, .col_offset = 1 + Layout.gutter_width });
            return 1;
        }

        var rows_rendered: usize = 0;
        var text_offset: usize = 0;

        while (text_offset < text.len) {
            const current_row = start_row + rows_rendered;
            if (current_row >= win.height) break;

            // Only show line number on first row
            const show_line_number = rows_rendered == 0;
            try self.renderGutter(win, line_idx, current_row, is_cursor, show_line_number, file_lineno);

            // Get the chunk of text for this row
            const remaining = text.len - text_offset;
            const chunk_len = @min(remaining, content_width);
            const chunk = text[text_offset .. text_offset + chunk_len];

            // Render the chunk
            const display_text = try self.padTextForCursor(chunk, content_width, is_cursor);
            var seg = [_]vaxis.Cell.Segment{.{
                .text = display_text,
                .style = style,
            }};
            _ = try win.print(&seg, .{ .row_offset = current_row, .col_offset = 1 + Layout.gutter_width });

            text_offset += chunk_len;
            rows_rendered += 1;
        }

        return if (rows_rendered == 0) 1 else rows_rendered;
    }

    fn renderGutter(self: *App, win: vaxis.Window, line_idx: usize, row: usize, is_cursor: bool, show_number: bool, file_lineno: ?u32) !void {
        _ = line_idx; // No longer used, but kept for API compatibility

        const style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.white, .bg = Color.dim }
        else
            .{ .fg = Color.dim };

        if (show_number) {
            if (file_lineno) |lineno| {
                // Show actual file line number
                var buf: [16]u8 = undefined;
                const gutter_stack = try std.fmt.bufPrint(&buf, "{d}", .{lineno});
                const gutter_text = try self.copyFrameText(gutter_stack);

                var seg = [_]vaxis.Cell.Segment{.{
                    .text = gutter_text,
                    .style = style,
                }};
                _ = try win.print(&seg, .{ .row_offset = row, .col_offset = 1 });
            } else {
                // For hunk headers or other lines without file line numbers, show empty gutter
                if (is_cursor) {
                    const spaces = try self.copyFrameText("     "); // Match gutter width
                    var seg = [_]vaxis.Cell.Segment{.{
                        .text = spaces,
                        .style = style,
                    }};
                    _ = try win.print(&seg, .{ .row_offset = row, .col_offset = 1 });
                }
            }
        } else {
            // For wrapped continuation lines, show empty gutter with cursor highlight if needed
            if (is_cursor) {
                const spaces = try self.copyFrameText("     "); // Match gutter width
                var seg = [_]vaxis.Cell.Segment{.{
                    .text = spaces,
                    .style = style,
                }};
                _ = try win.print(&seg, .{ .row_offset = row, .col_offset = 1 });
            }
        }
    }

    fn padTextForCursor(self: *App, text: []const u8, width: usize, is_cursor: bool) ![]const u8 {
        if (!is_cursor) return text;

        if (width > self.remainingFrameTextCapacity()) return error.FrameTextBufferOverflow;

        const slice = try self.frameTextSlice(width);
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
        if (len > self.remainingFrameTextCapacity()) return error.FrameTextBufferOverflow;

        const start = self.frame_text_used;
        const end = start + len;
        self.frame_text_used = end;
        return self.frame_text_buffer[start..end];
    }

    fn copyFrameText(self: *App, text: []const u8) ![]const u8 {
        const slice = try self.frameTextSlice(text.len);
        if (text.len > 0) {
            @memcpy(slice, text);
        }
        return slice;
    }

    fn getLineStyle(self: *App, line_type: parser.Line.LineType) vaxis.Style {
        _ = self;
        return switch (line_type) {
            .add => .{ .bg = Color.green, .fg = Color.black },
            .delete => .{ .bg = Color.red, .fg = Color.black },
            .context => .{},
        };
    }

    fn renderStatus(self: *App, win: vaxis.Window) !void {
        const keybindings = switch (self.mode) {
            .normal => "h/l:File  j/k:Cursor  Ctrl-d/u:Page  ?:Focus  c:Comment  s:Toggle  r:Refresh  q:Quit  Ctrl-C?2:Exit",
            .focused => "j/k:Scroll  Ctrl-d/u:Page  g/G:Top/Bottom  ESC:Normal  Ctrl-C?2:Exit",
            .comment => "ESC:Cancel  Ctrl-S:Save  Ctrl-C?2:Exit",
        };

        var seg = [_]vaxis.Cell.Segment{.{
            .text = keybindings,
            .style = .{
                .fg = Color.black,
                .bg = Color.white,
            },
        }};
        _ = try win.print(&seg, .{ .row_offset = 0 });
    }

    fn printHeaderLine(self: *App, win: vaxis.Window, row: usize, text: []const u8, style: vaxis.Style) !void {
        if (row >= Layout.header_height) return;
        if (row >= win.height or win.width == 0) return;

        var buffer = &self.header_line_buffers[row];
        const width = @min(win.width, buffer.len);

        if (width == 0) return;

        @memset(buffer[0..width], ' ');

        const copy_len = @min(text.len, width);
        if (copy_len > 0) {
            @memcpy(buffer[0..copy_len], text[0..copy_len]);
        }

        var seg = [_]vaxis.Cell.Segment{.{
            .text = buffer[0..width],
            .style = style,
        }};
        _ = try win.print(&seg, .{ .row_offset = row, .col_offset = 0 });
    }
};
