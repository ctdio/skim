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
    pub const dim = .{ .rgb = [3]u8{ 100, 100, 100 } }; // Medium gray #646464

    // Muted diff background colors (RGB for better control)
    pub const diff_add_bg = .{ .rgb = [3]u8{ 43, 62, 43 } }; // Darker green #2B3E2B
    pub const diff_delete_bg = .{ .rgb = [3]u8{ 63, 38, 38 } }; // Darker red #3F2626
    pub const diff_add_fg = .{ .rgb = [3]u8{ 63, 185, 80 } }; // Green text #3FB950
    pub const diff_delete_fg = .{ .rgb = [3]u8{ 247, 81, 73 } }; // Red text #F75149

    // Comment colors - darker, subdued grays
    pub const comment_border = .{ .rgb = [3]u8{ 80, 80, 80 } }; // Dark gray #505050
    pub const comment_border_focus = .{ .rgb = [3]u8{ 100, 100, 100 } }; // Medium gray when focused #646464
    pub const comment_marker = .{ .rgb = [3]u8{ 90, 90, 90 } }; // Dark gray #5a5a5a
    pub const comment_bg = .{ .rgb = [3]u8{ 35, 35, 35 } }; // Dark gray background for comments #232323
    pub const comment_hover_bg = .{ .rgb = [3]u8{ 25, 25, 25 } }; // Very dark gray for hover state #191919

    // Cursor line highlighting - slightly darker gray background
    pub const cursor_bg = .{ .rgb = [3]u8{ 80, 80, 80 } }; // Darker gray #505050
    pub const cursor_fg = .{ .rgb = [3]u8{ 255, 255, 255 } }; // White text

    // Pure white caret for focused mode - highly visible
    pub const caret_bg = .{ .rgb = [3]u8{ 255, 255, 255 } }; // Pure white #ffffff
    pub const caret_fg = .{ .rgb = [3]u8{ 0, 0, 0 } }; // Black text

    // Darker colors for +/- diff signs
    pub const diff_sign_add = .{ .rgb = [3]u8{ 0, 160, 0 } }; // Darker green #00a000
    pub const diff_sign_delete = .{ .rgb = [3]u8{ 160, 0, 0 } }; // Darker red #a00000

    // Search highlight - bright yellow background for visibility
    pub const search_match_bg = .{ .rgb = [3]u8{ 180, 150, 0 } }; // Bright yellow-orange #b49600
    pub const search_match_fg = .{ .rgb = [3]u8{ 0, 0, 0 } }; // Black text for contrast

    // Visual selection - blue background like vim
    pub const visual_select_bg = .{ .rgb = [3]u8{ 50, 70, 100 } }; // Dark blue #324664
    pub const visual_select_fg = .{ .rgb = [3]u8{ 255, 255, 255 } }; // White text
};

// Layout constants
pub const Layout = struct {
    pub const header_height = 2;
    pub const status_height = 1;
    pub const sidebar_width = 1; // Sidebar (┃)
    pub const min_gutter_width = 5; // Minimum gutter width for consistency
    pub const cursor_padding = 0; // No padding - vim-like scrolling (scroll only when cursor goes off screen)
    pub const page_scroll_lines = 10;
    pub const gutter_spacing = 2; // Spacing between gutter and content
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
