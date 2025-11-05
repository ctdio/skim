const std = @import("std");
const vaxis = @import("vaxis");

// Color constants for terminal output
pub const Color = struct {
    pub const black = .{ .index = 0 };
    pub const red = .{ .index = 1 };
    pub const green = .{ .index = 2 };
    pub const yellow = .{ .index = 3 };
    pub const blue = .{ .index = 4 };
    pub const magenta = .{ .index = 5 };
    pub const cyan = .{ .index = 6 };
    pub const white = .{ .index = 7 };
    pub const dim = .{ .rgb = [3]u8{ 40, 40, 40 } }; // Dark gray #282828

    // Muted diff background colors (RGB for better control)
    pub const diff_add_bg = .{ .rgb = [3]u8{ 13, 72, 32 } }; // Dark green #0d4820
    pub const diff_delete_bg = .{ .rgb = [3]u8{ 72, 13, 13 } }; // Dark red #480d0d
    pub const diff_add_fg = .{ .rgb = [3]u8{ 200, 255, 200 } }; // Light green text
    pub const diff_delete_fg = .{ .rgb = [3]u8{ 255, 200, 200 } }; // Light red text

    // Cursor line highlighting - slightly darker gray background
    pub const cursor_bg = .{ .rgb = [3]u8{ 80, 80, 80 } }; // Darker gray #505050
    pub const cursor_fg = .{ .rgb = [3]u8{ 255, 255, 255 } }; // White text

    // Pure white caret for focused mode - highly visible
    pub const caret_bg = .{ .rgb = [3]u8{ 255, 255, 255 } }; // Pure white #ffffff
    pub const caret_fg = .{ .rgb = [3]u8{ 0, 0, 0 } }; // Black text
};

// Layout constants
pub const Layout = struct {
    pub const header_height = 2;
    pub const divider_height = 1;
    pub const status_height = 1;
    pub const min_gutter_width = 5; // Minimum gutter width for consistency
    pub const cursor_padding = 3; // Padding around cursor when scrolling
    pub const page_scroll_lines = 10;
};

// Frame drawing characters
pub const FrameChars = struct {
    pub const vertical = "│";
    pub const horizontal = "─";
    pub const top_left = "╭";
    pub const top_right = "╮";
    pub const bottom_left = "╰";
    pub const bottom_right = "╯";
    pub const middle_left = "├";
    pub const middle_right = "┤";
};

// Buffer size constants
pub const HEADER_BUFFER_WIDTH = 4096;
pub const FRAME_TEXT_CAPACITY = 262144; // 256 KiB per frame scratch space
