const std = @import("std");
const vaxis = @import("vaxis");
const git = @import("git/diff.zig");
const parser = @import("git/parser.zig");
const syntax = @import("syntax.zig");
const navigation = @import("navigation.zig");
const render_utils = @import("rendering/utils.zig");
const render_unified = @import("rendering/unified.zig");
const render_side_by_side = @import("rendering/side_by_side.zig");
const state_helpers = @import("state.zig");
const ui_components = @import("ui.zig");
const DiffSource = git.DiffSource;
const Navigation = navigation.Navigation;
const RenderUtils = render_utils.RenderUtils;
const UnifiedRenderer = render_unified.UnifiedRenderer;
const SideBySideRenderer = render_side_by_side.SideBySideRenderer;
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
