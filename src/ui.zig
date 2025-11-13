const std = @import("std");
const vaxis = @import("vaxis");
const rendering_common = @import("rendering/common.zig");
const render_utils = @import("rendering/utils.zig");
const state_helpers = @import("state.zig");

const App = @import("app.zig").App;
const Color = rendering_common.Color;
const Layout = rendering_common.Layout;
const FrameChars = rendering_common.FrameChars;
const RenderUtils = render_utils.RenderUtils;
const StateHelpers = state_helpers.StateHelpers;

pub const DividerPosition = enum {
    top,
    middle,
    bottom,
};

pub const UI = struct {
    pub fn renderDivider(app: *App, win: vaxis.Window, position: DividerPosition) !void {
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
        const left_corner = try RenderUtils.copyFrameText(app, left_char);
        const right_corner = try RenderUtils.copyFrameText(app, right_char);

        // Calculate number of horizontal characters needed (width in cells minus 2 for corners)
        const num_h_chars = if (width > 2) width - 2 else 0;

        // Calculate byte length needed (each horizontal char is 3 bytes in UTF-8)
        const h_line_len = num_h_chars * FrameChars.horizontal.len;

        const h_line = if (h_line_len > 0) blk: {
            const line = try RenderUtils.frameTextSlice(app, h_line_len);
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

    pub fn renderEmpty(_: *App, win: vaxis.Window) !void {
        const msg = "No changes to review";
        const row = win.height / 2;
        const col = (win.width -| msg.len) / 2;

        var seg = [_]vaxis.Cell.Segment{.{
            .text = msg,
            .style = .{ .fg = Color.dim },
        }};
        _ = try win.print(&seg, .{ .row_offset = row, .col_offset = col });
    }

    pub fn renderHeader(app: *App, win: vaxis.Window) !void {
        if (win.height == 0 or win.width == 0) return;
        win.clear();

        if (app.state.current_file_idx >= app.state.files.len) return;

        const current_file = &app.state.files[app.state.current_file_idx];
        const stats = StateHelpers.calculateDiffStats(app, current_file);

        const file_path = if (current_file.new_path.len > 0) current_file.new_path else current_file.old_path;

        // First line: File info with stats
        var buf1: [512]u8 = undefined;
        const file_info = try std.fmt.bufPrint(&buf1, "File {d} of {d}  ", .{
            app.state.current_file_idx + 1,
            app.state.files.len,
        });

        var buf2: [64]u8 = undefined;
        const additions_text = try std.fmt.bufPrint(&buf2, "+{d}", .{stats.additions});

        var buf3: [64]u8 = undefined;
        const deletions_text = try std.fmt.bufPrint(&buf3, " -{d}", .{stats.deletions});

        // Copy to frame buffer for proper lifetime
        const file_info_copy = try RenderUtils.copyFrameText(app, file_info);
        const file_path_copy = try RenderUtils.copyFrameText(app, file_path);
        const additions_copy = try RenderUtils.copyFrameText(app, additions_text);
        const deletions_copy = try RenderUtils.copyFrameText(app, deletions_text);
        const spacer = try RenderUtils.copyFrameText(app, "  ");

        // Create segments with different colors
        var segments = [_]vaxis.Cell.Segment{
            .{ .text = file_info_copy, .style = .{ .fg = Color.white } },
            .{ .text = file_path_copy, .style = .{ .fg = Color.white, .bold = true } },
            .{ .text = spacer, .style = .{ .fg = Color.white } },
            .{ .text = additions_copy, .style = .{ .fg = Color.green, .bold = true } },
            .{ .text = deletions_copy, .style = .{ .fg = Color.red, .bold = true } },
        };

        _ = try win.print(&segments, .{ .row_offset = 0, .col_offset = 0 });
    }

    pub fn renderStatus(app: *App, win: vaxis.Window) !void {
        win.clear();

        const mode_str = switch (app.mode) {
            .normal => "-- NORMAL --",
            .comment => "-- COMMENT --",
            .search => "-- SEARCH --",
            .visual => "-- VISUAL --",
        };

        const view_str = switch (app.state.view_mode) {
            .unified => "[Unified]",
            .side_by_side => "[Side-by-Side]",
        };

        // Hunk view mode with symbol
        const hunk_view_symbol = app.state.hunk_view_mode.toSymbol();

        // Context-aware keybindings based on cursor position and mode
        const keybindings = switch (app.mode) {
            .normal => blk: {
                // Get line record from LineMap
                const record = app.state.line_map.getLineRecord(app.state.global_cursor_line);

                if (record) |rec| {
                    if (rec.file_idx < app.state.files.len) {
                        const file = &app.state.files[rec.file_idx];
                        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

                        switch (rec.line_type) {
                            .file_header => {
                                break :blk "h/l:File  j/k:Line  v:Visual  /:Search  g/G:Top/Bottom  q:Quit";
                            },
                            .comment_line => {
                                // Cursor is on a comment - show edit/delete options prominently
                                break :blk "Enter:Edit Comment  d:Delete Comment  v:Visual  /:Search  h/l:File  q:Quit";
                            },
                            .code_line => |code| {
                                // Check if this code line has a comment
                                if (app.state.comment_store.hasCommentAt(file_path, code.hunk_idx, code.line_idx_in_hunk)) {
                                    // Code line with comment - show edit option
                                    break :blk "Enter:Edit Comment  v:Visual  /:Search  n/N:Next/Prev  Ctrl-g:Editor  q:Quit";
                                } else {
                                    // Code line without comment - show add option
                                    break :blk "Enter:Add Comment  v:Visual  /:Search  n/N:Next/Prev  Ctrl-g:Editor  q:Quit";
                                }
                            },
                            .hunk_header => {
                                // On hunk header - show navigation
                                break :blk "h/l:File  j/k:Line  v:Visual  /:Search  g/G:Top/Bottom  Ctrl-g:Editor  q:Quit";
                            },
                            .spacer => {
                                break :blk "h/l:File  j/k:Line  v:Visual  /:Search  g/G:Top/Bottom  q:Quit";
                            },
                        }
                    }
                }
                // Default keybindings
                break :blk "h/l:File  j/k:Line  v:Visual  /:Search  n/N:Next/Prev  Ctrl-g:Editor  q:Quit";
            },
            .comment => "Enter:Save  Shift+Enter:Newline  ESC:Cancel",
            .search => "Enter:Search  ESC:Cancel  (Smart case: lowercase=ignore case, uppercase=exact)",
            .visual => "j/k:Move  y:Yank  v/ESC/Ctrl-C:Exit Visual",
        };

        // Get global position info
        const total_lines = app.getTotalGlobalLines();
        const current_line = app.state.global_cursor_line + 1; // Display 1-indexed
        const total_files = app.state.files.len;
        const current_file = app.state.current_file_idx + 1; // Display 1-indexed

        // Build status bar using segments with colors
        var segments = std.ArrayList(vaxis.Cell.Segment).init(app.allocator);
        defer segments.deinit();

        if (app.mode == .search) {
            // In search mode, show search prompt with current query
            const query = app.state.search_state.query_buffer[0..app.state.search_state.query_len];
            const match_count = app.state.search_state.matches.items.len;

            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, mode_str), .style = .{} });
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, "  /"), .style = .{} });
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, query), .style = .{} });

            if (match_count > 0) {
                const current_match = if (app.state.search_state.current_match_idx) |idx| idx + 1 else 0;
                var buf: [64]u8 = undefined;
                const match_info = try std.fmt.bufPrint(&buf, "  ({d} of {d} matches)  ", .{ current_match, match_count });
                try segments.append(.{ .text = try RenderUtils.copyFrameText(app, match_info), .style = .{} });
            } else if (app.state.search_state.query_len > 0) {
                try segments.append(.{ .text = try RenderUtils.copyFrameText(app, "_  "), .style = .{} });
            } else {
                try segments.append(.{ .text = try RenderUtils.copyFrameText(app, "_  "), .style = .{} });
            }

            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, keybindings), .style = .{} });
        } else {
            // Normal mode status bar with colored hunk view mode
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, mode_str), .style = .{} });
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, " "), .style = .{} });
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, view_str), .style = .{} });

            // Only show hunk view mode indicator in unified view (where filtering applies)
            if (app.state.view_mode == .unified) {
                try segments.append(.{ .text = try RenderUtils.copyFrameText(app, " ["), .style = .{} });

                // Add colored hunk view symbol
                if (app.state.hunk_view_mode == .all) {
                    // For "+/-" mode, color + green and - red
                    try segments.append(.{ .text = try RenderUtils.copyFrameText(app, "+"), .style = .{ .fg = Color.green, .bold = true } });
                    try segments.append(.{ .text = try RenderUtils.copyFrameText(app, "/"), .style = .{ .bold = true } });
                    try segments.append(.{ .text = try RenderUtils.copyFrameText(app, "-"), .style = .{ .fg = Color.red, .bold = true } });
                } else {
                    // For single mode, use appropriate color
                    const hunk_view_style: vaxis.Style = switch (app.state.hunk_view_mode) {
                        .all => unreachable, // Already handled above
                        .old => .{ .fg = Color.red, .bold = true },
                        .new => .{ .fg = Color.green, .bold = true },
                    };
                    try segments.append(.{ .text = try RenderUtils.copyFrameText(app, hunk_view_symbol), .style = hunk_view_style });
                }
                try segments.append(.{ .text = try RenderUtils.copyFrameText(app, "]"), .style = .{} });
            }

            if (app.state.count_prefix) |count| {
                var buf: [64]u8 = undefined;
                const count_str = try std.fmt.bufPrint(&buf, " [{d}]", .{count});
                try segments.append(.{ .text = try RenderUtils.copyFrameText(app, count_str), .style = .{} });
            }

            var buf: [128]u8 = undefined;
            const pos_info = try std.fmt.bufPrint(&buf, "  Line {d}/{d} (File {d}/{d})", .{ current_line, total_lines, current_file, total_files });
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, pos_info), .style = .{} });

            // Show search info if there are active matches in normal mode
            if (app.state.search_state.hasMatches()) {
                const match_count = app.state.search_state.matches.items.len;
                const current_match = if (app.state.search_state.current_match_idx) |idx| idx + 1 else 0;
                var match_buf: [64]u8 = undefined;
                const match_info = try std.fmt.bufPrint(&match_buf, "  [{d}/{d} matches]", .{ current_match, match_count });
                try segments.append(.{ .text = try RenderUtils.copyFrameText(app, match_info), .style = .{} });
            }

            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, "  "), .style = .{} });
            try segments.append(.{ .text = try RenderUtils.copyFrameText(app, keybindings), .style = .{} });
        }

        _ = try win.print(segments.items, .{ .row_offset = 0 });
    }

    pub fn printHeaderLine(app: *App, win: vaxis.Window, row: usize, text: []const u8, style: vaxis.Style) !void {
        if (row >= Layout.header_height) return;
        if (row >= win.height or win.width == 0) return;

        var buffer = &app.header_line_buffers[row];
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
