const std = @import("std");
const vaxis = @import("vaxis");

// Color constants for terminal output - typed as vaxis.Cell.Color
pub const Color = struct {
    pub const black: vaxis.Cell.Color = .{ .index = 0 };
    pub const red: vaxis.Cell.Color = .{ .index = 1 };
    pub const green: vaxis.Cell.Color = .{ .index = 2 };
    pub const yellow: vaxis.Cell.Color = .{ .index = 3 };
    pub const blue: vaxis.Cell.Color = .{ .index = 4 };
    pub const magenta: vaxis.Cell.Color = .{ .index = 5 };
    pub const cyan: vaxis.Cell.Color = .{ .index = 6 };
    pub const white: vaxis.Cell.Color = .{ .index = 7 };
    pub const dim: vaxis.Cell.Color = .{ .rgb = [3]u8{ 100, 100, 100 } }; // Medium gray #646464

    // Diff background colors - slightly darkened for subtle depth
    pub const diff_add_bg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 37, 53, 37 } }; // Darker green #253525
    pub const diff_delete_bg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 54, 32, 32 } }; // Darker red #362020

    // Diff foreground colors for +/- signs and header stats
    pub const diff_sign_add: vaxis.Cell.Color = .{ .rgb = [3]u8{ 63, 185, 80 } }; // Bright green #3FB950
    pub const diff_sign_delete: vaxis.Cell.Color = .{ .rgb = [3]u8{ 247, 81, 73 } }; // Bright red #F75149

    // Comment colors - darker, subdued grays
    pub const comment_border: vaxis.Cell.Color = .{ .rgb = [3]u8{ 80, 80, 80 } }; // Dark gray #505050
    pub const comment_border_focus: vaxis.Cell.Color = .{ .rgb = [3]u8{ 100, 100, 100 } }; // Medium gray when focused #646464
    pub const comment_marker: vaxis.Cell.Color = .{ .rgb = [3]u8{ 90, 90, 90 } }; // Dark gray #5a5a5a
    pub const comment_bg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 35, 35, 35 } }; // Dark gray background for comments #232323
    pub const comment_hover_bg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 25, 25, 25 } }; // Very dark gray for hover state #191919

    // Cursor line highlighting - slightly darker gray background
    pub const cursor_bg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 80, 80, 80 } }; // Darker gray #505050
    pub const cursor_fg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 255, 255, 255 } }; // White text

    // Pure white caret for focused mode - highly visible
    pub const caret_bg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 255, 255, 255 } }; // Pure white #ffffff
    pub const caret_fg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 0, 0, 0 } }; // Black text

    // Search highlight - bright yellow background for visibility
    pub const search_match_bg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 180, 150, 0 } }; // Bright yellow-orange #b49600
    pub const search_match_fg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 0, 0, 0 } }; // Black text for contrast

    // Visual selection - blue background like vim
    pub const visual_select_bg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 50, 70, 100 } }; // Dark blue #324664
    pub const visual_select_fg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 255, 255, 255 } }; // White text

    // Syntax highlighting colors - GitHub Dark theme
    // Official GitHub Primer colors for syntax highlighting
    pub const syntax_keyword: vaxis.Cell.Color = .{ .rgb = [3]u8{ 255, 123, 114 } }; // Coral red #FF7B72
    pub const syntax_function: vaxis.Cell.Color = .{ .rgb = [3]u8{ 210, 168, 255 } }; // Purple #D2A8FF
    pub const syntax_type: vaxis.Cell.Color = .{ .rgb = [3]u8{ 255, 166, 87 } }; // Orange #FFA657
    pub const syntax_string: vaxis.Cell.Color = .{ .rgb = [3]u8{ 165, 214, 255 } }; // Light blue #A5D6FF
    pub const syntax_number: vaxis.Cell.Color = .{ .rgb = [3]u8{ 121, 192, 255 } }; // Bright blue #79C0FF
    pub const syntax_comment: vaxis.Cell.Color = .{ .rgb = [3]u8{ 139, 148, 158 } }; // Gray #8B949E
    pub const syntax_constant: vaxis.Cell.Color = .{ .rgb = [3]u8{ 121, 192, 255 } }; // Bright blue #79C0FF
    pub const syntax_operator: vaxis.Cell.Color = .{ .rgb = [3]u8{ 255, 123, 114 } }; // Coral red (same as keywords) #FF7B72

    // Merge conflict marker colors - distinct colors for each marker type
    pub const conflict_ours_fg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 88, 166, 255 } }; // Blue #58A6FF (<<<<<<< HEAD)
    pub const conflict_ours_bg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 35, 50, 70 } }; // Dark blue background #233246
    pub const conflict_separator_fg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 255, 200, 50 } }; // Yellow #FFC832 (=======)
    pub const conflict_separator_bg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 60, 55, 30 } }; // Dark yellow background #3C371E
    pub const conflict_theirs_fg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 210, 168, 255 } }; // Purple #D2A8FF (>>>>>>>)
    pub const conflict_theirs_bg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 55, 40, 70 } }; // Dark purple background #372846
    pub const conflict_base_fg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 139, 148, 158 } }; // Gray #8B949E (|||||||)
    pub const conflict_base_bg: vaxis.Cell.Color = .{ .rgb = [3]u8{ 45, 45, 50 } }; // Dark gray background #2D2D32
};

// Layout constants
pub const Layout = struct {
    pub const header_height = 1;
    pub const status_height = 1;
    pub const sidebar_width = 1; // Sidebar (┃)
    pub const min_gutter_width = 5; // Minimum gutter width for consistency
    pub const cursor_padding = 3; // Padding around cursor when scrolling
    pub const page_scroll_lines = 10;
    pub const gutter_spacing = 2; // Spacing between gutter and content
    pub const max_comment_lines = 6; // Max visible text lines in collapsed comments
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
