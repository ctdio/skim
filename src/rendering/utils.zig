const std = @import("std");
const vaxis = @import("vaxis");
const parser = @import("../git/parser.zig");
const blame = @import("../git/blame.zig");
const comments = @import("../comments/store.zig");
const rendering_common = @import("common.zig");
const state_helpers = @import("../state.zig");

const App = @import("../app.zig").App;
const StateHelpers = state_helpers.StateHelpers;
const Color = rendering_common.Color;
const FrameChars = rendering_common.FrameChars;
const Layout = rendering_common.Layout;

pub const RenderUtils = struct {
    // Unicode display width utilities

    /// Calculate the display width of a UTF-8 string in terminal cells.
    /// This counts codepoints, which works correctly for most characters
    /// including box-drawing chars, arrows, and symbols.
    /// Note: Does not handle full-width CJK characters (would need wcwidth tables).
    pub fn displayWidth(text: []const u8) usize {
        return std.unicode.utf8CountCodepoints(text) catch text.len;
    }

    /// Slice a UTF-8 string by display width (codepoints), not bytes.
    /// Returns a slice of the input text containing at most `max_width` codepoints.
    /// The returned slice ends at a valid UTF-8 boundary.
    pub fn sliceByDisplayWidth(text: []const u8, max_width: usize) []const u8 {
        if (max_width == 0) return text[0..0];

        var width: usize = 0;
        var byte_pos: usize = 0;

        while (byte_pos < text.len and width < max_width) {
            const byte = text[byte_pos];
            const char_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
            const next_pos = @min(byte_pos + char_len, text.len);
            byte_pos = next_pos;
            width += 1;
        }

        return text[0..byte_pos];
    }

    /// Skip a number of codepoints in a UTF-8 string and return the byte offset.
    /// Returns the byte position after skipping `count` codepoints.
    pub fn skipCodepoints(text: []const u8, count: usize) usize {
        var skipped: usize = 0;
        var byte_pos: usize = 0;

        while (byte_pos < text.len and skipped < count) {
            const byte = text[byte_pos];
            const char_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
            byte_pos = @min(byte_pos + char_len, text.len);
            skipped += 1;
        }

        return byte_pos;
    }

    // Style calculation utilities

    /// Get style for a line based on cursor, visual selection, and line type
    pub fn getDisplayStyle(
        app: *App,
        is_cursor: bool,
        is_in_visual: bool,
        base_style: vaxis.Style,
    ) vaxis.Style {
        if (is_cursor and app.mode == .visual) {
            return .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = true };
        } else if (is_cursor) {
            return .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true };
        } else if (is_in_visual) {
            return .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = false };
        } else {
            return base_style;
        }
    }

    /// Get fill style for backgrounds (e.g., hunk headers)
    pub fn getFillStyle(app: *App, is_cursor: bool, is_in_visual: bool) vaxis.Style {
        if (is_cursor and app.mode == .visual) {
            return .{ .bg = Color.visual_select_bg };
        } else if (is_cursor) {
            return .{ .bg = Color.cursor_bg };
        } else if (is_in_visual) {
            return .{ .bg = Color.visual_select_bg };
        } else {
            return .{};
        }
    }

    /// Get range style for hunk headers (bold text with icons)
    pub fn getHunkRangeStyle(app: *App, is_cursor: bool, is_in_visual: bool) vaxis.Style {
        if (is_cursor and app.mode == .visual) {
            return .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = true };
        } else if (is_cursor) {
            return .{ .fg = Color.white, .bg = Color.cursor_bg, .bold = true };
        } else if (is_in_visual) {
            return .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = true };
        } else {
            return .{ .fg = Color.dim };
        }
    }

    /// Get context style for hunk headers (dimmer text)
    pub fn getHunkContextStyle(app: *App, is_cursor: bool, is_in_visual: bool) vaxis.Style {
        if (is_cursor and app.mode == .visual) {
            return .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg };
        } else if (is_cursor) {
            return .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg };
        } else if (is_in_visual) {
            return .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg };
        } else {
            return .{ .fg = Color.dim };
        }
    }

    // Segment manipulation utilities

    /// Calculate the total display width (in terminal cells) of all segments
    /// This properly counts UTF-8 codepoints instead of bytes.
    pub fn calculateSegmentsWidth(segments: []const vaxis.Cell.Segment) usize {
        var total_width: usize = 0;
        for (segments) |seg| {
            // Count UTF-8 codepoints, not bytes
            // Each codepoint = 1 terminal cell (this works for most Unicode chars)
            // Note: This doesn't handle full-width chars (CJK) or combining chars,
            // but works correctly for arrows, symbols, and ASCII
            const codepoint_count = std.unicode.utf8CountCodepoints(seg.text) catch seg.text.len;
            total_width += codepoint_count;
        }
        return total_width;
    }

    /// Pad segments to full width with trailing spaces
    pub fn padSegments(
        app: *App,
        allocator: std.mem.Allocator,
        segments: []const vaxis.Cell.Segment,
        current_width: usize,
        target_width: usize,
        style: vaxis.Style,
    ) ![]vaxis.Cell.Segment {
        if (current_width >= target_width) return try allocator.dupe(vaxis.Cell.Segment, segments);

        const padded = try allocator.alloc(vaxis.Cell.Segment, segments.len + 1);
        @memcpy(padded[0..segments.len], segments);

        const padding_len = target_width - current_width;
        const padding = try frameTextSlice(app, padding_len);
        @memset(padding, ' ');
        padded[segments.len] = .{
            .text = padding,
            .style = style,
        };

        return padded;
    }

    // Border rendering utilities

    /// Render sidebar border
    pub fn renderSidebar(win: vaxis.Window, row: usize) !void {
        const sidebar_style = .{ .fg = Color.dim };
        var sidebar_seg = [_]vaxis.Cell.Segment{.{
            .text = "┃",
            .style = sidebar_style,
        }};
        _ = try win.print(&sidebar_seg, .{ .row_offset = row, .col_offset = 0 });
    }

    /// Render middle divider for side-by-side view
    pub fn renderMiddleDivider(win: vaxis.Window, row: usize, col: usize) !void {
        const divider_style = .{ .fg = Color.dim };
        var divider_seg = [_]vaxis.Cell.Segment{.{
            .text = FrameChars.vertical,
            .style = divider_style,
        }};
        _ = try win.print(&divider_seg, .{ .row_offset = row, .col_offset = col });
    }

    /// Render continuation row borders (sidebar + optional middle divider)
    pub fn renderContinuationBorders(
        win: vaxis.Window,
        row: usize,
        middle_col: ?usize,
    ) !void {
        try renderSidebar(win, row);
        if (middle_col) |col| {
            try renderMiddleDivider(win, row, col);
        }
    }

    // Hunk header utilities

    /// Build hunk header text
    pub fn buildHunkHeaderText(hunk: parser.Hunk, buf: []u8) ![]const u8 {
        const old_end = hunk.header.old_start + hunk.header.old_count -| 1;
        const new_end = hunk.header.new_start + hunk.header.new_count -| 1;

        return try std.fmt.bufPrint(
            buf,
            "↕ {d}-{d} → {d}-{d}  {s}",
            .{
                hunk.header.old_start,
                old_end,
                hunk.header.new_start,
                new_end,
                hunk.header.context,
            },
        );
    }

    /// Find where the context starts in the hunk header text
    pub fn findHunkHeaderRangeEnd(header_text: []const u8) usize {
        const range_end_marker = "  ";
        const range_end_pos = std.mem.indexOf(u8, header_text, range_end_marker);
        return if (range_end_pos) |pos| pos + range_end_marker.len else header_text.len;
    }

    // Gutter rendering with column offset

    /// Render gutter at a specific column (for side-by-side view)
    pub fn renderGutterAtColumn(
        app: *App,
        win: vaxis.Window,
        row: usize,
        col_offset: usize,
        is_cursor: bool,
        is_in_visual: bool,
        show_number: bool,
        file_lineno: ?u32,
        line_type: ?parser.Line.LineType,
        gutter_width: usize,
    ) !void {
        const base_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
        else if (is_in_visual)
            .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg }
        else
            .{ .fg = Color.dim };

        // Style for empty gutter (applies diff background for wrapped lines)
        const empty_gutter_style: vaxis.Style = if (line_type) |lt| switch (lt) {
            .add => if (is_cursor)
                .{ .fg = Color.dim, .bg = Color.cursor_bg }
            else if (is_in_visual)
                .{ .fg = Color.dim, .bg = Color.visual_select_bg }
            else
                .{ .fg = Color.dim, .bg = Color.diff_add_bg },
            .delete => if (is_cursor)
                .{ .fg = Color.dim, .bg = Color.cursor_bg }
            else if (is_in_visual)
                .{ .fg = Color.dim, .bg = Color.visual_select_bg }
            else
                .{ .fg = Color.dim, .bg = Color.diff_delete_bg },
            .context => base_style,
        } else base_style;

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

                const gutter_text = try copyFrameText(app, buf[0 .. sign_pos + sign.len]);

                // Color the sign and number based on line type (with matching background)
                // Use same colors as unified view for consistency
                const sign_style: vaxis.Style = if (line_type) |lt| switch (lt) {
                    .add => if (is_cursor)
                        .{ .fg = Color.diff_sign_add, .bg = Color.cursor_bg, .bold = true }
                    else if (is_in_visual)
                        .{ .fg = Color.diff_sign_add, .bg = Color.visual_select_bg, .bold = true }
                    else
                        .{ .fg = Color.diff_sign_add, .bg = Color.diff_add_bg, .bold = true },
                    .delete => if (is_cursor)
                        .{ .fg = Color.diff_sign_delete, .bg = Color.cursor_bg, .bold = true }
                    else if (is_in_visual)
                        .{ .fg = Color.diff_sign_delete, .bg = Color.visual_select_bg, .bold = true }
                    else
                        .{ .fg = Color.diff_sign_delete, .bg = Color.diff_delete_bg, .bold = true },
                    .context => if (is_cursor)
                        .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
                    else if (is_in_visual)
                        .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = true }
                    else
                        .{ .fg = Color.dim },
                } else base_style;

                // Apply diff background to number as well for add/delete lines
                // Use same colors as unified view for consistency
                const number_style: vaxis.Style = if (line_type) |lt| switch (lt) {
                    .add => if (is_cursor)
                        .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
                    else if (is_in_visual)
                        .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = true }
                    else
                        .{ .fg = Color.diff_sign_add, .bg = Color.diff_add_bg },
                    .delete => if (is_cursor)
                        .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
                    else if (is_in_visual)
                        .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = true }
                    else
                        .{ .fg = Color.diff_sign_delete, .bg = Color.diff_delete_bg },
                    .context => base_style,
                } else base_style;

                // Split into number and sign segments for different colors
                const number_text = gutter_text[0 .. gutter_text.len - 1];
                const sign_text = gutter_text[gutter_text.len - 1 ..];

                var segments = [_]vaxis.Cell.Segment{
                    .{ .text = number_text, .style = number_style },
                    .{ .text = sign_text, .style = sign_style },
                };
                _ = try win.print(&segments, .{ .row_offset = row, .col_offset = col_offset });
            } else {
                if (is_cursor or is_in_visual) {
                    const spaces_slice = try frameTextSlice(app, gutter_width);
                    @memset(spaces_slice, ' ');
                    var seg = [_]vaxis.Cell.Segment{.{
                        .text = spaces_slice,
                        .style = base_style,
                    }};
                    _ = try win.print(&seg, .{ .row_offset = row, .col_offset = col_offset });
                }
            }
        } else {
            // For wrapped continuation lines, show empty gutter with diff background
            const spaces_slice = try frameTextSlice(app, gutter_width);
            @memset(spaces_slice, ' ');
            var seg = [_]vaxis.Cell.Segment{.{
                .text = spaces_slice,
                .style = empty_gutter_style,
            }};
            _ = try win.print(&seg, .{ .row_offset = row, .col_offset = col_offset });
        }

        // Render spacing after gutter with appropriate diff background color
        const spacing_style: vaxis.Style = if (is_cursor)
            .{ .bg = Color.cursor_bg }
        else if (is_in_visual)
            .{ .bg = Color.visual_select_bg }
        else if (line_type) |lt| switch (lt) {
            .add => .{ .bg = Color.diff_add_bg },
            .delete => .{ .bg = Color.diff_delete_bg },
            .context => .{},
        } else .{};

        const spacing = try frameTextSlice(app, rendering_common.Layout.gutter_spacing);
        @memset(spacing, ' ');
        var spacing_seg = [_]vaxis.Cell.Segment{.{
            .text = spacing,
            .style = spacing_style,
        }};
        _ = try win.print(&spacing_seg, .{ .row_offset = row, .col_offset = col_offset + gutter_width });
    }

    // Frame buffer management
    pub fn resetFrameTextBuffer(app: *App) void {
        app.frame_text_used = 0;
    }

    pub fn remainingFrameTextCapacity(app: *App) usize {
        return app.frame_text_buffer.len - app.frame_text_used;
    }

    pub fn frameTextSlice(app: *App, len: usize) ![]u8 {
        if (len == 0) return app.frame_text_buffer[0..0];
        if (len > remainingFrameTextCapacity(app)) return error.FrameTextBufferOverflow;

        const start = app.frame_text_used;
        const end = start + len;
        app.frame_text_used = end;
        return app.frame_text_buffer[start..end];
    }

    pub fn copyFrameText(app: *App, text: []const u8) ![]const u8 {
        const slice = try frameTextSlice(app, text.len);
        if (text.len > 0) {
            @memcpy(slice, text);
        }
        return slice;
    }

    pub fn padTextForCursor(app: *App, text: []const u8, width: usize, is_cursor: bool) ![]const u8 {
        if (!is_cursor) return text;

        if (width > remainingFrameTextCapacity(app)) return error.FrameTextBufferOverflow;

        const slice = try frameTextSlice(app, width);
        const copy_len = @min(text.len, slice.len);

        if (copy_len > 0) {
            @memcpy(slice[0..copy_len], text[0..copy_len]);
        }
        if (copy_len < slice.len) {
            @memset(slice[copy_len..], ' ');
        }

        return slice;
    }

    pub fn getLineStyle(_: *App, line_type: parser.Line.LineType) vaxis.Style {
        return switch (line_type) {
            .add => .{ .bg = Color.diff_add_bg },
            .delete => .{ .bg = Color.diff_delete_bg },
            .context => .{},
        };
    }

    pub fn renderGutter(
        app: *App,
        win: vaxis.Window,
        line_idx: usize,
        row: usize,
        is_cursor_or_visual: bool,
        show_number: bool,
        file_lineno: ?u32,
        line_type: ?parser.Line.LineType,
        gutter_width: usize,
    ) !void {
        // Forward to extended version with no file path (no blame)
        try renderGutterWithBlame(app, win, line_idx, row, is_cursor_or_visual, show_number, file_lineno, line_type, gutter_width, null, false);
    }

    /// Render gutter with optional blame info
    /// When file_path is provided and show_blame is enabled, shows blame info before line number
    /// is_first_line_in_hunk: When true, always show blame (don't deduplicate with previous line)
    pub fn renderGutterWithBlame(
        app: *App,
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
        _ = line_idx; // No longer used, but kept for API compatibility

        // Check if we're in visual mode to use visual colors
        const is_visual = app.mode == .visual and is_cursor_or_visual;
        const is_cursor = !is_visual and is_cursor_or_visual;

        const base_style: vaxis.Style = if (is_visual)
            .{ .fg = Color.white, .bg = Color.visual_select_bg }
        else if (is_cursor)
            .{ .fg = Color.white, .bg = Color.dim }
        else
            .{ .fg = Color.dim };

        // Style for empty gutter (applies diff background for wrapped lines)
        const empty_gutter_style: vaxis.Style = if (line_type) |lt| switch (lt) {
            .add => if (is_visual)
                .{ .fg = Color.dim, .bg = Color.visual_select_bg }
            else if (is_cursor)
                .{ .fg = Color.dim, .bg = Color.cursor_bg }
            else
                .{ .fg = Color.dim, .bg = Color.diff_add_bg },
            .delete => if (is_visual)
                .{ .fg = Color.dim, .bg = Color.visual_select_bg }
            else if (is_cursor)
                .{ .fg = Color.dim, .bg = Color.cursor_bg }
            else
                .{ .fg = Color.dim, .bg = Color.diff_delete_bg },
            .context => base_style,
        } else base_style;

        // Calculate blame width if blame is shown
        const show_blame = app.state.show_blame and file_path != null;
        const blame_width: usize = if (show_blame) StateHelpers.BLAME_GUTTER_WIDTH else 0;
        const lineno_width = gutter_width - blame_width;

        // Track current column offset (starts after sidebar)
        var col_offset: usize = 1;

        // Render blame info if enabled
        if (show_blame) {
            // Blame gutter uses same background as the diff line
            const blame_style: vaxis.Style = if (is_visual)
                .{ .fg = Color.dim, .bg = Color.visual_select_bg }
            else if (is_cursor)
                .{ .fg = Color.dim, .bg = Color.cursor_bg }
            else if (line_type) |lt| switch (lt) {
                .add => .{ .fg = Color.dim, .bg = Color.diff_add_bg },
                .delete => .{ .fg = Color.dim, .bg = Color.diff_delete_bg },
                .context => .{ .fg = Color.dim },
            } else .{ .fg = Color.dim };

            if (show_number and file_lineno != null) {
                // Get blame info for this line
                const blame_info = if (file_path) |fp| app.getBlameForLine(fp, file_lineno.?) else null;

                if (blame_info) |info| {
                    // Check if this is an uncommitted line (hash starts with 00000000)
                    const is_uncommitted = std.mem.eql(u8, &info.commit_hash, "00000000");

                    // Check if same commit as previous line (for deduplication)
                    // Skip deduplication at the start of a hunk - always show blame there
                    const same_as_prev = if (is_first_line_in_hunk) false else blk: {
                        const prev_blame = if (file_path) |fp| app.getBlameForLine(fp, file_lineno.? -| 1) else null;
                        break :blk if (prev_blame) |prev| std.mem.eql(u8, &info.commit_hash, &prev.commit_hash) else false;
                    };

                    // Check if this is the 2nd line of a commit block (prev is same, prev-of-prev is different)
                    // Used to show commit message on the line after the blame info
                    const is_second_line_of_block = if (same_as_prev and file_lineno.? >= 2) blk: {
                        const prev_prev_blame = if (file_path) |fp| app.getBlameForLine(fp, file_lineno.? - 2) else null;
                        break :blk if (prev_prev_blame) |pp| !std.mem.eql(u8, &info.commit_hash, &pp.commit_hash) else true;
                    } else same_as_prev; // If line 1, treat as 2nd line of block if same_as_prev

                    var blame_buf: [StateHelpers.BLAME_GUTTER_WIDTH]u8 = undefined;
                    @memset(&blame_buf, ' ');

                    if (same_as_prev and is_second_line_of_block and info.summary.len > 0 and !is_uncommitted) {
                        // 2nd line of commit block - show commit message (skip for uncommitted - git generates useless summary)
                        const msg_len = @min(info.summary.len, StateHelpers.BLAME_GUTTER_WIDTH);
                        @memcpy(blame_buf[0..msg_len], info.summary[0..msg_len]);
                    } else if (same_as_prev) {
                        // 3rd+ line of commit block - do nothing
                    } else if (is_uncommitted) {
                        const uncommited_changes_title = "Uncommited changes";

                        @memcpy(blame_buf[0..uncommited_changes_title.len], uncommited_changes_title);
                    } else {
                        // Different commit - show full info
                        // Copy short hash (8 chars)
                        @memcpy(blame_buf[0..8], &info.commit_hash);
                        blame_buf[8] = ' ';

                        // Copy username or author (truncated to 12 chars)
                        // Prefer username if it's different from author and non-empty
                        const display_name = blk: {
                            if (info.username.len > 0) {
                                // Check if username looks different from author (not just a prefix)
                                const author_lower_start = if (info.author.len > 0) info.author[0] else 0;
                                const user_lower_start = if (info.username.len > 0) info.username[0] else 0;
                                if (author_lower_start != user_lower_start) {
                                    break :blk info.username;
                                }
                            }
                            break :blk info.author;
                        };
                        const name = blame.formatAuthor(display_name, 12);
                        @memcpy(blame_buf[9 .. 9 + name.len], name);
                        blame_buf[21] = ' ';

                        // Format date as "Mon DD YYYY" (11 chars)
                        var date_buf: [16]u8 = undefined;
                        const date_str = blame.formatDate(&date_buf, info.timestamp);
                        const date_start: usize = 22;
                        const date_len = @min(date_str.len, @as(usize, 11));
                        @memcpy(blame_buf[date_start .. date_start + date_len], date_str[0..date_len]);
                        blame_buf[33] = ' ';

                        // Format relative time (up to 4 chars)
                        var time_buf: [8]u8 = undefined;
                        const time_str = blame.formatRelativeTime(&time_buf, info.timestamp);
                        const time_start: usize = 34;
                        const time_len = @min(time_str.len, @as(usize, 4));
                        @memcpy(blame_buf[time_start .. time_start + time_len], time_str[0..time_len]);
                        // Commit message is shown on 2nd line of block (if available)
                    }

                    const blame_text = try copyFrameText(app, &blame_buf);
                    var blame_seg = [_]vaxis.Cell.Segment{.{
                        .text = blame_text,
                        .style = blame_style,
                    }};
                    _ = try win.print(&blame_seg, .{ .row_offset = row, .col_offset = col_offset });
                } else {
                    // No blame info - render empty space
                    const spaces = try frameTextSlice(app, blame_width);
                    @memset(spaces, ' ');
                    var blame_seg = [_]vaxis.Cell.Segment{.{
                        .text = spaces,
                        .style = blame_style,
                    }};
                    _ = try win.print(&blame_seg, .{ .row_offset = row, .col_offset = col_offset });
                }
            } else {
                // No line number - render empty blame space
                const spaces = try frameTextSlice(app, blame_width);
                @memset(spaces, ' ');
                var blame_seg = [_]vaxis.Cell.Segment{.{
                    .text = spaces,
                    .style = if (show_number) base_style else empty_gutter_style,
                }};
                _ = try win.print(&blame_seg, .{ .row_offset = row, .col_offset = col_offset });
            }
            col_offset += blame_width;
        }

        // Render line number and sign
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
                const num_width = lineno_width - 1; // Reserve 1 char for sign
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

                const gutter_text = try copyFrameText(app, buf[0 .. sign_pos + sign.len]);

                // Color the sign and number based on line type (with matching background)
                const sign_style: vaxis.Style = if (line_type) |lt| switch (lt) {
                    .add => if (is_visual)
                        .{ .fg = Color.diff_sign_add, .bg = Color.visual_select_bg, .bold = true }
                    else if (is_cursor)
                        .{ .fg = Color.diff_sign_add, .bg = Color.cursor_bg, .bold = true }
                    else
                        .{ .fg = Color.diff_sign_add, .bg = Color.diff_add_bg, .bold = true },
                    .delete => if (is_visual)
                        .{ .fg = Color.diff_sign_delete, .bg = Color.visual_select_bg, .bold = true }
                    else if (is_cursor)
                        .{ .fg = Color.diff_sign_delete, .bg = Color.cursor_bg, .bold = true }
                    else
                        .{ .fg = Color.diff_sign_delete, .bg = Color.diff_delete_bg, .bold = true },
                    .context => if (is_visual)
                        .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = true }
                    else if (is_cursor)
                        .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
                    else
                        .{ .fg = Color.dim },
                } else base_style;

                // Apply diff background to number as well for add/delete lines
                const number_style: vaxis.Style = if (line_type) |lt| switch (lt) {
                    .add => if (is_visual)
                        .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = true }
                    else if (is_cursor)
                        .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
                    else
                        .{ .fg = Color.diff_sign_add, .bg = Color.diff_add_bg },
                    .delete => if (is_visual)
                        .{ .fg = Color.visual_select_fg, .bg = Color.visual_select_bg, .bold = true }
                    else if (is_cursor)
                        .{ .fg = Color.cursor_fg, .bg = Color.cursor_bg, .bold = true }
                    else
                        .{ .fg = Color.diff_sign_delete, .bg = Color.diff_delete_bg },
                    .context => base_style,
                } else base_style;

                // Split into number and sign segments for different colors
                const number_text = gutter_text[0 .. gutter_text.len - 1];
                const sign_text = gutter_text[gutter_text.len - 1 ..];

                var segments = [_]vaxis.Cell.Segment{
                    .{ .text = number_text, .style = number_style },
                    .{ .text = sign_text, .style = sign_style },
                };
                _ = try win.print(&segments, .{ .row_offset = row, .col_offset = col_offset });
            } else {
                // For hunk headers or other lines without file line numbers, always show empty gutter
                const spaces_slice = try frameTextSlice(app, lineno_width);
                @memset(spaces_slice, ' ');
                var seg = [_]vaxis.Cell.Segment{.{
                    .text = spaces_slice,
                    .style = base_style,
                }};
                _ = try win.print(&seg, .{ .row_offset = row, .col_offset = col_offset });
            }
        } else {
            // For wrapped continuation lines, show empty gutter with diff background
            const spaces_slice = try frameTextSlice(app, lineno_width);
            @memset(spaces_slice, ' ');
            var seg = [_]vaxis.Cell.Segment{.{
                .text = spaces_slice,
                .style = empty_gutter_style,
            }};
            _ = try win.print(&seg, .{ .row_offset = row, .col_offset = col_offset });
        }

        // Render spacing after gutter with appropriate diff background color
        const spacing_style: vaxis.Style = if (is_visual)
            .{ .bg = Color.visual_select_bg }
        else if (is_cursor)
            .{ .bg = Color.cursor_bg }
        else if (line_type) |lt| switch (lt) {
            .add => .{ .bg = Color.diff_add_bg },
            .delete => .{ .bg = Color.diff_delete_bg },
            .context => .{},
        } else .{};

        const spacing = try frameTextSlice(app, rendering_common.Layout.gutter_spacing);
        @memset(spacing, ' ');
        var spacing_seg = [_]vaxis.Cell.Segment{.{
            .text = spacing,
            .style = spacing_style,
        }};
        _ = try win.print(&spacing_seg, .{ .row_offset = row, .col_offset = 1 + gutter_width });
    }

    pub fn renderGutterSpacing(
        app: *App,
        win: vaxis.Window,
        row: usize,
        col_offset: usize,
        is_cursor: bool,
        line_type: ?parser.Line.LineType,
    ) !void {
        // Render spacing with the appropriate background color
        const spacing_style: vaxis.Style = if (line_type) |lt| switch (lt) {
            .add => .{ .bg = Color.diff_add_bg },
            .delete => .{ .bg = Color.diff_delete_bg },
            .context => .{},
        } else if (is_cursor) .{ .bg = Color.cursor_bg } else .{}; // Hunk headers and comment lines - no background

        const spacing = try frameTextSlice(app, rendering_common.Layout.gutter_spacing);
        @memset(spacing, ' ');
        var spacing_seg = [_]vaxis.Cell.Segment{.{
            .text = spacing,
            .style = spacing_style,
        }};
        _ = try win.print(&spacing_seg, .{ .row_offset = row, .col_offset = col_offset });
    }

    /// Wrap text to fit within max_width (in display cells), breaking at word boundaries when possible
    /// Properly handles UTF-8 multi-byte characters.
    pub fn wrapText(allocator: std.mem.Allocator, text: []const u8, max_width: usize) !std.ArrayList([]const u8) {
        var lines = std.ArrayList([]const u8).init(allocator);
        errdefer lines.deinit();

        if (max_width == 0) return lines;

        // Handle empty text - still return one empty line
        if (text.len == 0) {
            try lines.append(text);
            return lines;
        }

        var byte_start: usize = 0;
        while (byte_start < text.len) {
            const remaining = text[byte_start..];
            const remaining_display_width = displayWidth(remaining);

            // If remaining text fits, add it as-is
            if (remaining_display_width <= max_width) {
                try lines.append(remaining);
                break;
            }

            // Get max_width characters worth of text
            const max_chunk = sliceByDisplayWidth(remaining, max_width);

            // Find the last space within this chunk to break at word boundary
            var break_byte_pos = max_chunk.len;
            var found_space = false;

            // Look backwards through the bytes to find a space
            // (Space is always a single byte in UTF-8)
            var i: usize = max_chunk.len;
            while (i > 0) : (i -= 1) {
                if (max_chunk[i - 1] == ' ') {
                    break_byte_pos = i - 1; // Break before the space
                    found_space = true;
                    break;
                }
            }

            // If no space found, hard break at max_width characters
            if (!found_space) {
                break_byte_pos = max_chunk.len;
            }

            // Add this segment
            try lines.append(remaining[0..break_byte_pos]);

            // Move past the break point and any spaces
            byte_start += break_byte_pos;
            if (found_space) {
                // Skip the space(s) we broke on
                while (byte_start < text.len and text[byte_start] == ' ') {
                    byte_start += 1;
                }
            }
        }

        return lines;
    }

    /// Render inline comment input box (when in comment mode)
    pub fn renderCommentInputBox(
        app: *App,
        win: vaxis.Window,
        row: usize,
        gutter_width: usize,
    ) !usize {
        if (app.state.active_comment_input == null) return 0;
        if (row + 3 >= win.height) return 0; // Need at least 4 rows

        const input = app.state.active_comment_input.?;

        // Render gutter for top spacer
        try renderCommentGutter(app, win, row, true, gutter_width);

        const content_start = 1 + gutter_width + Layout.gutter_spacing;
        const content_width = win.width -| content_start;

        if (content_width < 20) return 0; // Too narrow

        const border_style: vaxis.Style = .{ .fg = Color.yellow, .bg = Color.comment_hover_bg, .bold = true };
        const text_style: vaxis.Style = .{ .fg = Color.white, .bg = Color.comment_hover_bg };
        const label_style: vaxis.Style = .{ .fg = Color.yellow, .bg = Color.comment_hover_bg, .bold = true };
        const hints_style: vaxis.Style = .{ .fg = Color.yellow, .bg = Color.comment_hover_bg, .dim = true };

        var segments = std.ArrayList(vaxis.Cell.Segment).init(app.allocator);
        defer segments.deinit();

        var current_row = row;

        // Line 1: ┃ (top spacer)
        try segments.append(.{ .text = try copyFrameText(app, "┃"), .style = border_style });
        const top_spacer = try frameTextSlice(app, content_width - 1);
        @memset(top_spacer, ' ');
        try segments.append(.{ .text = top_spacer, .style = .{ .bg = Color.comment_hover_bg } });
        _ = try win.print(segments.items, .{ .row_offset = current_row, .col_offset = content_start });
        current_row += 1;

        // Render gutter for label line
        try renderEmptyCommentGutter(app, win, current_row, true, gutter_width);

        // Line 2: ┃ Comment [range info]                 Ctrl+S:Save  Enter:Newline  ESC:Cancel
        segments.clearRetainingCapacity();
        const hints = "Ctrl+S:Save  Enter:Newline  ESC:Cancel";

        // Build label with range info if applicable
        const label = blk: {
            if (input.target_end_hunk_idx != null and input.target_end_line_idx != null) {
                // Range comment - show line range
                const start_line = input.target_line_idx + 1; // +1 for 1-based display
                const end_line = input.target_end_line_idx.? + 1;
                if (input.target_hunk_idx == input.target_end_hunk_idx.?) {
                    // Same hunk - use frame text buffer for formatted string
                    var label_buf: [64]u8 = undefined;
                    const formatted = try std.fmt.bufPrint(&label_buf, " Comment (Lines {d}-{d})", .{ start_line, end_line });
                    break :blk try copyFrameText(app, formatted);
                } else {
                    // Different hunks (unlikely but handle it)
                    break :blk try copyFrameText(app, " Comment (Range)");
                }
            } else {
                // Single-line comment
                break :blk try copyFrameText(app, " Comment");
            }
        };

        const border_and_label_len = 1 + label.len; // "┃" + label
        const spacing = "  ";
        const total_fixed = border_and_label_len + spacing.len + hints.len;
        const available_for_spacer = content_width -| total_fixed;

        try segments.append(.{ .text = try copyFrameText(app, "┃"), .style = border_style });
        try segments.append(.{ .text = label, .style = label_style });

        // Spacer between label and hints
        if (available_for_spacer > 0) {
            const spacer = try frameTextSlice(app, available_for_spacer);
            @memset(spacer, ' ');
            try segments.append(.{ .text = spacer, .style = .{ .bg = Color.comment_hover_bg } });
        }

        try segments.append(.{ .text = try copyFrameText(app, spacing), .style = .{ .bg = Color.comment_hover_bg } });
        try segments.append(.{ .text = try copyFrameText(app, hints), .style = hints_style });

        _ = try win.print(segments.items, .{ .row_offset = current_row, .col_offset = content_start });
        current_row += 1;

        // Line 3+: ┃ > [text] (multiple lines if newlines present)
        const input_text = input.text_buffer[0..input.text_len];
        const text_area_width = content_width - 4; // -4 for "┃ > " or "┃   "

        var line_iter = std.mem.splitScalar(u8, input_text, '\n');
        var is_first_line = true;
        var char_offset: usize = 0; // Track position in buffer for cursor

        while (line_iter.next()) |text_line| {
            if (current_row >= win.height) break;

            // Wrap this line if it's too long
            var wrapped_lines = try wrapText(app.allocator, text_line, text_area_width);
            defer wrapped_lines.deinit();

            // Track offset within the current text_line for wrapped segments
            var segment_offset: usize = 0;

            // Render each wrapped segment
            for (wrapped_lines.items) |wrapped_segment| {
                if (current_row >= win.height) break;

                // Render gutter for this text line
                try renderEmptyCommentGutter(app, win, current_row, true, gutter_width);

                segments.clearRetainingCapacity();
                try segments.append(.{ .text = try copyFrameText(app, "┃"), .style = border_style });

                if (is_first_line) {
                    try segments.append(.{ .text = try copyFrameText(app, " > "), .style = text_style });
                } else {
                    try segments.append(.{ .text = try copyFrameText(app, "   "), .style = text_style });
                }

                const display_text = blk: {
                    var buf = try frameTextSlice(app, text_area_width);
                    const copy_len = @min(wrapped_segment.len, text_area_width);
                    if (copy_len > 0) {
                        @memcpy(buf[0..copy_len], wrapped_segment[0..copy_len]);
                    }
                    if (copy_len < buf.len) {
                        @memset(buf[copy_len..], ' ');
                    }
                    break :blk buf;
                };

                try segments.append(.{ .text = display_text, .style = text_style });
                _ = try win.print(segments.items, .{ .row_offset = current_row, .col_offset = content_start });

                // Draw cursor and visual selection if in this wrapped segment
                const segment_start = char_offset + segment_offset;
                const segment_end = segment_start + wrapped_segment.len;

                // Handle visual mode selection highlighting
                if (input.vim_mode == .visual and input.visual_anchor != null) {
                    const anchor = input.visual_anchor.?;
                    const selection_start = @min(anchor, input.cursor_pos);
                    const selection_end = @max(anchor, input.cursor_pos);

                    // Highlight any part of selection in this segment
                    if (selection_start < segment_end and selection_end >= segment_start) {
                        const highlight_start_in_seg = if (selection_start > segment_start)
                            selection_start - segment_start
                        else
                            0;
                        const highlight_end_in_seg = if (selection_end < segment_end)
                            selection_end - segment_start
                        else
                            wrapped_segment.len;

                        if (highlight_start_in_seg < text_area_width and highlight_end_in_seg > highlight_start_in_seg) {
                            const highlight_col_start = content_start + 4 + highlight_start_in_seg;
                            const highlight_len = @min(highlight_end_in_seg - highlight_start_in_seg, text_area_width - highlight_start_in_seg);

                            if (highlight_len > 0) {
                                const highlight_text = wrapped_segment[highlight_start_in_seg..][0..highlight_len];
                                var highlight_seg = [_]vaxis.Cell.Segment{.{
                                    .text = try copyFrameText(app, highlight_text),
                                    .style = .{ .fg = Color.white, .bg = Color.blue },
                                }};
                                _ = try win.print(&highlight_seg, .{ .row_offset = current_row, .col_offset = highlight_col_start });
                            }
                        }
                    }
                }

                // Draw cursor if it's in this wrapped segment
                if (input.cursor_pos >= segment_start and input.cursor_pos <= segment_end) {
                    const cursor_pos_in_segment = input.cursor_pos - segment_start;
                    if (cursor_pos_in_segment < text_area_width) {
                        const cursor_col = content_start + 4 + cursor_pos_in_segment; // +4 for "┃ > " or "┃   "

                        // Set the terminal cursor position and shape
                        win.showCursor(cursor_col, current_row);

                        switch (input.vim_mode) {
                            .normal, .visual => {
                                // Block cursor for normal/visual mode
                                win.setCursorShape(.block);
                            },
                            .insert => {
                                // Beam/line cursor for insert mode
                                win.setCursorShape(.beam);
                            },
                            .command => {
                                // Command mode - hide cursor here (it's shown in status bar)
                                win.hideCursor();
                            },
                        }
                    }
                }

                current_row += 1;
                is_first_line = false;
                segment_offset += wrapped_segment.len;

                // Account for spaces that were skipped during wrapping
                // Find how many spaces were between this segment and the next in the original
                while (segment_offset < text_line.len and text_line[segment_offset] == ' ') {
                    segment_offset += 1;
                }
            }

            char_offset += text_line.len + 1; // +1 for the newline character
        }

        // Render gutter for bottom spacer
        try renderEmptyCommentGutter(app, win, current_row, true, gutter_width);

        // Last line: ┃ (bottom spacer)
        segments.clearRetainingCapacity();
        try segments.append(.{ .text = try copyFrameText(app, "┃"), .style = border_style });
        const bottom_spacer = try frameTextSlice(app, content_width - 1);
        @memset(bottom_spacer, ' ');
        try segments.append(.{ .text = bottom_spacer, .style = .{ .bg = Color.comment_hover_bg } });
        _ = try win.print(segments.items, .{ .row_offset = current_row, .col_offset = content_start });
        current_row += 1;

        return current_row - row; // Return actual number of rows used
    }

    /// Render saved comment display box with optional truncation
    pub fn renderCommentDisplay(
        app: *App,
        win: vaxis.Window,
        comment: *const comments.Comment,
        comment_idx: usize,
        row: usize,
        gutter_width: usize,
        is_cursor: bool,
    ) !usize {
        // Render gutter for top spacer
        try renderCommentGutter(app, win, row, is_cursor, gutter_width);

        const content_start = 1 + gutter_width + Layout.gutter_spacing;
        const content_width = win.width -| content_start;

        if (content_width < 20) return 0;

        const is_expanded = app.isCommentExpanded(comment_idx);
        const max_lines = Layout.max_comment_lines;

        // Use cyan for regular comments, yellow when focused
        // Always use background - comment_bg for normal, comment_hover_bg when cursor is on it
        const border_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.yellow, .bg = Color.comment_hover_bg, .bold = true }
        else
            .{ .fg = Color.cyan, .bg = Color.comment_bg, .bold = true };

        const text_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.white, .bg = Color.comment_hover_bg }
        else
            .{ .fg = Color.white, .bg = Color.comment_bg };

        const label_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.yellow, .bg = Color.comment_hover_bg, .bold = true }
        else
            .{ .fg = Color.cyan, .bg = Color.comment_bg, .bold = true };

        const hints_style: vaxis.Style = if (is_cursor)
            .{ .fg = Color.yellow, .bg = Color.comment_hover_bg, .dim = true }
        else
            .{ .fg = Color.cyan, .bg = Color.comment_bg, .dim = true };

        const bg_style: vaxis.Style = if (is_cursor)
            .{ .bg = Color.comment_hover_bg }
        else
            .{ .bg = Color.comment_bg };

        var segments = std.ArrayList(vaxis.Cell.Segment).init(app.allocator);
        defer segments.deinit();

        var current_row = row;

        // Line 1: ┃ (top spacer)
        try segments.append(.{ .text = try copyFrameText(app, "┃"), .style = border_style });
        const top_spacer = try frameTextSlice(app, content_width - 1);
        @memset(top_spacer, ' ');
        try segments.append(.{ .text = top_spacer, .style = bg_style });
        _ = try win.print(segments.items, .{ .row_offset = current_row, .col_offset = content_start });
        current_row += 1;

        // Render gutter for label line
        try renderEmptyCommentGutter(app, win, current_row, is_cursor, gutter_width);

        // Line 2: ┃ Comment                              Enter:Edit  d:Delete  o:Expand
        segments.clearRetainingCapacity();
        if (is_cursor) {
            const expand_hint = if (is_expanded) "o:Collapse" else "o:Expand";
            var hints_buf: [64]u8 = undefined;
            const hints = std.fmt.bufPrint(&hints_buf, "Enter:Edit  d:Delete  {s}", .{expand_hint}) catch "Enter:Edit  d:Delete";
            const border_and_label = "┃ Comment";
            const spacing = "  ";
            const total_fixed = border_and_label.len + spacing.len + hints.len;
            const available_for_spacer = content_width -| total_fixed;

            try segments.append(.{ .text = try copyFrameText(app, "┃"), .style = border_style });
            try segments.append(.{ .text = try copyFrameText(app, " Comment"), .style = label_style });

            // Spacer between label and hints
            if (available_for_spacer > 0) {
                const spacer = try frameTextSlice(app, available_for_spacer);
                @memset(spacer, ' ');
                try segments.append(.{ .text = spacer, .style = bg_style });
            }

            try segments.append(.{ .text = try copyFrameText(app, spacing), .style = bg_style });
            try segments.append(.{ .text = try copyFrameText(app, hints), .style = hints_style });
        } else {
            // Just label when not focused
            try segments.append(.{ .text = try copyFrameText(app, "┃"), .style = border_style });
            try segments.append(.{ .text = try copyFrameText(app, " Comment"), .style = label_style });
            const label_spacer = try frameTextSlice(app, content_width - 9); // -9 for "┃ Comment"
            @memset(label_spacer, ' ');
            try segments.append(.{ .text = label_spacer, .style = bg_style });
        }

        _ = try win.print(segments.items, .{ .row_offset = current_row, .col_offset = content_start });
        current_row += 1;

        // Render comment text lines with word wrapping
        const text_area_width = content_width - 4; // -4 for "┃ > " or "┃   "
        var line_iter = std.mem.splitScalar(u8, comment.text, '\n');
        var is_first_line = true;
        var text_lines_rendered: usize = 0;
        var total_text_lines: usize = 0;
        var truncated = false;

        // First pass: count total lines if we need to truncate
        if (!is_expanded) {
            var count_iter = std.mem.splitScalar(u8, comment.text, '\n');
            while (count_iter.next()) |text_line| {
                var wrapped = try wrapText(app.allocator, text_line, text_area_width);
                defer wrapped.deinit();
                total_text_lines += wrapped.items.len;
            }
        }

        while (line_iter.next()) |text_line| {
            if (current_row >= win.height) break;

            // Wrap this line if it's too long
            var wrapped_lines = try wrapText(app.allocator, text_line, text_area_width);
            defer wrapped_lines.deinit();

            // Render each wrapped segment
            for (wrapped_lines.items) |wrapped_segment| {
                if (current_row >= win.height) break;

                // Check if we should truncate (only when collapsed)
                if (!is_expanded and text_lines_rendered >= max_lines) {
                    truncated = true;
                    break;
                }

                // Render gutter for text line
                try renderEmptyCommentGutter(app, win, current_row, is_cursor, gutter_width);

                segments.clearRetainingCapacity();
                try segments.append(.{ .text = try copyFrameText(app, "┃"), .style = border_style });
                if (is_first_line) {
                    try segments.append(.{ .text = try copyFrameText(app, " > "), .style = text_style });
                } else {
                    try segments.append(.{ .text = try copyFrameText(app, "   "), .style = text_style });
                }

                const display_text = blk: {
                    var buf = try frameTextSlice(app, text_area_width);
                    const copy_len = @min(wrapped_segment.len, text_area_width);
                    if (copy_len > 0) {
                        @memcpy(buf[0..copy_len], wrapped_segment[0..copy_len]);
                    }
                    if (copy_len < buf.len) {
                        @memset(buf[copy_len..], ' ');
                    }
                    break :blk buf;
                };

                try segments.append(.{ .text = display_text, .style = text_style });
                _ = try win.print(segments.items, .{ .row_offset = current_row, .col_offset = content_start });
                current_row += 1;
                text_lines_rendered += 1;
                is_first_line = false;
            }

            if (truncated) break;
        }

        // Show truncation indicator if collapsed and has more lines
        if (truncated and total_text_lines > max_lines) {
            if (current_row < win.height) {
                try renderEmptyCommentGutter(app, win, current_row, is_cursor, gutter_width);

                segments.clearRetainingCapacity();
                try segments.append(.{ .text = try copyFrameText(app, "┃"), .style = border_style });

                const remaining = total_text_lines - max_lines;
                var more_buf: [64]u8 = undefined;
                const more_text = std.fmt.bufPrint(&more_buf, "   ... {d} more line{s} (press o to expand)", .{
                    remaining,
                    if (remaining == 1) "" else "s",
                }) catch "   ... (press o to expand)";

                const display_text = blk: {
                    var buf = try frameTextSlice(app, text_area_width);
                    const copy_len = @min(more_text.len, text_area_width);
                    if (copy_len > 0) {
                        @memcpy(buf[0..copy_len], more_text[0..copy_len]);
                    }
                    if (copy_len < buf.len) {
                        @memset(buf[copy_len..], ' ');
                    }
                    break :blk buf;
                };

                try segments.append(.{ .text = display_text, .style = hints_style });
                _ = try win.print(segments.items, .{ .row_offset = current_row, .col_offset = content_start });
                current_row += 1;
            }
        }

        if (current_row >= win.height) {
            return current_row - row;
        }

        // Render gutter for bottom spacer
        try renderEmptyCommentGutter(app, win, current_row, is_cursor, gutter_width);

        // Line N: ┃ (bottom spacer)
        segments.clearRetainingCapacity();
        try segments.append(.{ .text = try copyFrameText(app, "┃"), .style = border_style });
        const bottom_spacer = try frameTextSlice(app, content_width - 1);
        @memset(bottom_spacer, ' ');
        try segments.append(.{ .text = bottom_spacer, .style = bg_style });
        _ = try win.print(segments.items, .{ .row_offset = current_row, .col_offset = content_start });
        current_row += 1;

        return current_row - row;
    }

    /// Render gutter for a comment line (no indicator, just background)
    fn renderCommentGutter(
        app: *App,
        win: vaxis.Window,
        row: usize,
        is_cursor: bool,
        gutter_width: usize,
    ) !void {
        // Apply hover background when cursor is on comment
        const gutter_style: vaxis.Style = if (is_cursor)
            .{ .bg = Color.comment_hover_bg }
        else
            .{};

        // Empty gutter (just spaces)
        const gutter_spaces = try frameTextSlice(app, gutter_width);
        @memset(gutter_spaces, ' ');

        var gutter_seg = [_]vaxis.Cell.Segment{.{
            .text = gutter_spaces,
            .style = gutter_style,
        }};
        _ = try win.print(&gutter_seg, .{ .row_offset = row, .col_offset = 1 });

        // Render gutter spacing with comment hover background
        const spacing_style: vaxis.Style = if (is_cursor)
            .{ .bg = Color.comment_hover_bg }
        else
            .{};
        const spacing = try frameTextSlice(app, rendering_common.Layout.gutter_spacing);
        @memset(spacing, ' ');
        var spacing_seg = [_]vaxis.Cell.Segment{.{
            .text = spacing,
            .style = spacing_style,
        }};
        _ = try win.print(&spacing_seg, .{ .row_offset = row, .col_offset = 1 + gutter_width });
    }

    /// Render empty gutter for continuation lines of comment boxes
    fn renderEmptyCommentGutter(
        app: *App,
        win: vaxis.Window,
        row: usize,
        is_cursor: bool,
        gutter_width: usize,
    ) !void {
        // Apply hover background when cursor is on comment
        const gutter_style: vaxis.Style = if (is_cursor)
            .{ .bg = Color.comment_hover_bg }
        else
            .{};

        // Empty gutter (just spaces)
        const gutter_spaces = try frameTextSlice(app, gutter_width);
        @memset(gutter_spaces, ' ');

        var gutter_seg = [_]vaxis.Cell.Segment{.{
            .text = gutter_spaces,
            .style = gutter_style,
        }};
        _ = try win.print(&gutter_seg, .{ .row_offset = row, .col_offset = 1 });

        // Render gutter spacing with comment hover background
        const spacing_style: vaxis.Style = if (is_cursor)
            .{ .bg = Color.comment_hover_bg }
        else
            .{};
        const spacing = try frameTextSlice(app, rendering_common.Layout.gutter_spacing);
        @memset(spacing, ' ');
        var spacing_seg = [_]vaxis.Cell.Segment{.{
            .text = spacing,
            .style = spacing_style,
        }};
        _ = try win.print(&spacing_seg, .{ .row_offset = row, .col_offset = 1 + gutter_width });
    }

    /// Check if there's a comment at this file/hunk/line location
    pub fn hasCommentAt(
        app: *App,
        file_path: []const u8,
        hunk_idx: usize,
        line_idx_in_hunk: usize,
    ) bool {
        return app.state.comment_store.hasCommentAt(file_path, hunk_idx, line_idx_in_hunk);
    }

    /// Get comment at this location (returns null if none)
    pub fn getCommentAt(
        app: *App,
        file_path: []const u8,
        hunk_idx: usize,
        line_idx_in_hunk: usize,
    ) ?*const comments.Comment {
        const idx = app.state.comment_store.findCommentAt(file_path, hunk_idx, line_idx_in_hunk) orelse return null;
        return app.state.comment_store.getComment(idx);
    }
};
