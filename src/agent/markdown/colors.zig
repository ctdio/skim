//! Markdown-specific Color Definitions
//!
//! Provides themed colors for rendering markdown elements in the terminal.
//! Uses vaxis styles compatible with the existing skim color palette.

const std = @import("std");
const vaxis = @import("vaxis");

/// Local color definitions for markdown rendering
/// These match the skim color palette from rendering/common.zig
const Color = struct {
    pub const dim: vaxis.Cell.Color = .{ .rgb = [3]u8{ 100, 100, 100 } }; // Medium gray #646464
    pub const chat_content: vaxis.Cell.Color = .{ .rgb = [3]u8{ 200, 200, 200 } }; // Light gray #C8C8C8

    // Standard colors for tests
    pub const white: vaxis.Cell.Color = .{ .index = 7 };
    pub const blue: vaxis.Cell.Color = .{ .index = 4 };
    pub const cyan: vaxis.Cell.Color = .{ .index = 6 };
    pub const red: vaxis.Cell.Color = .{ .index = 1 };
    pub const green: vaxis.Cell.Color = .{ .index = 2 };
};

/// Style configuration for markdown rendering
/// Each field corresponds to a markdown element type
pub const MarkdownColors = struct {
    /// H1 header - bright blue, bold for maximum visibility
    h1: vaxis.Style,
    /// H2 header - cyan-ish, bold
    h2: vaxis.Style,
    /// H3 header - purple, bold
    h3: vaxis.Style,
    /// H4 header - green
    h4: vaxis.Style,
    /// H5 header - yellow
    h5: vaxis.Style,
    /// H6 header - light blue, smallest header
    h6: vaxis.Style,
    /// Bold text (**text**)
    bold: vaxis.Style,
    /// Italic text (*text*)
    italic: vaxis.Style,
    /// Strikethrough text (~~text~~)
    strikethrough: vaxis.Style,
    /// Inline code (`code`)
    inline_code: vaxis.Style,
    /// Background color for inline code
    inline_code_bg: vaxis.Color,
    /// Link text ([text](url))
    link_text: vaxis.Style,
    /// Link URL (the URL portion)
    link_url: vaxis.Style,
    /// Normal text
    text: vaxis.Style,
    /// List marker style (bullet/number) - dim
    list_marker: vaxis.Style,
    /// Blockquote border (vertical bar) - dim
    blockquote_border: vaxis.Style,
    /// Blockquote text - slightly dimmed
    blockquote_text: vaxis.Style,
    /// Task list checked marker - green checkmark
    task_checked: vaxis.Style,
    /// Task list unchecked marker - dim empty box
    task_unchecked: vaxis.Style,
    /// Horizontal rule - dim
    horizontal_rule: vaxis.Style,
    /// Code block background - dark
    code_block_bg: vaxis.Color,
    /// Code block border (``` markers) - dim
    code_block_border: vaxis.Style,
    /// Code block language label - accent color
    code_block_lang: vaxis.Style,
    /// Table header row - bold for distinction
    table_header: vaxis.Style,
    /// Table borders (| and -) - dim
    table_border: vaxis.Style,
    /// Table cell content - normal text
    table_cell: vaxis.Style,
};

/// Default markdown color scheme matching skim's aesthetic
pub const default: MarkdownColors = .{
    // Headers use a muted neutral grayscale hierarchy
    .h1 = .{
        .fg = .{ .rgb = [3]u8{ 232, 232, 232 } }, // Off-white #E8E8E8
        .bold = true,
    },
    .h2 = .{
        .fg = .{ .rgb = [3]u8{ 216, 216, 216 } }, // Soft gray #D8D8D8
        .bold = true,
    },
    .h3 = .{
        .fg = .{ .rgb = [3]u8{ 192, 192, 192 } }, // Medium gray #C0C0C0
        .bold = true,
    },
    .h4 = .{
        .fg = .{ .rgb = [3]u8{ 168, 168, 168 } }, // Slate gray #A8A8A8
    },
    .h5 = .{
        .fg = .{ .rgb = [3]u8{ 152, 152, 152 } }, // Cooler gray #989898
    },
    .h6 = .{
        .fg = .{ .rgb = [3]u8{ 136, 136, 136 } }, // Dim gray #888888
    },

    // Emphasis styles
    .bold = .{
        .bold = true,
    },
    .italic = .{
        .italic = true,
    },
    .strikethrough = .{
        .strikethrough = true,
        .fg = Color.dim, // Dim gray for struck-through text
    },

    // Inline code - subtle background distinction
    .inline_code = .{
        .fg = Color.cyan,
    },
    .inline_code_bg = .{ .rgb = [3]u8{ 45, 45, 50 } }, // Dark gray background

    // Links
    .link_text = .{
        .fg = .{ .rgb = [3]u8{ 88, 166, 255 } }, // Blue #58A6FF
        .ul_style = .single,
    },
    .link_url = .{
        .fg = Color.dim, // Dim gray for URLs
    },

    // Normal text
    .text = .{
        .fg = Color.chat_content, // Light gray #C8C8C8
    },

    // Block element styles
    .list_marker = .{
        .fg = .{ .rgb = [3]u8{ 0x6c, 0x70, 0x86 } }, // Dim gray
    },
    .blockquote_border = .{
        .fg = .{ .rgb = [3]u8{ 0x6c, 0x70, 0x86 } }, // Dim gray
    },
    .blockquote_text = .{
        .fg = .{ .rgb = [3]u8{ 0xa9, 0xb1, 0xd6 } }, // Slightly dimmed text
    },
    .task_checked = .{
        .fg = .{ .rgb = [3]u8{ 0x9e, 0xce, 0x6a } }, // Green
    },
    .task_unchecked = .{
        .fg = .{ .rgb = [3]u8{ 0x6c, 0x70, 0x86 } }, // Dim gray
    },
    .horizontal_rule = .{
        .fg = .{ .rgb = [3]u8{ 0x6c, 0x70, 0x86 } }, // Dim gray
    },
    // Code block styles
    .code_block_bg = .{ .rgb = [3]u8{ 0x1a, 0x1b, 0x26 } }, // Dark background
    .code_block_border = .{
        .fg = .{ .rgb = [3]u8{ 0x6c, 0x70, 0x86 } }, // Dim gray
    },
    .code_block_lang = .{
        .fg = .{ .rgb = [3]u8{ 0x6c, 0x70, 0x86 } }, // Dim gray for language label
        .bg = .{ .rgb = [3]u8{ 0x1a, 0x1b, 0x26 } }, // Same as code_block_bg
    },
    // Table styles
    .table_header = .{
        .fg = Color.chat_content,
        .bold = true,
    },
    .table_border = .{
        .fg = .{ .rgb = [3]u8{ 0x6c, 0x70, 0x86 } }, // Dim gray
    },
    .table_cell = .{
        .fg = Color.chat_content,
    },
};

/// Merge two styles, with overlay taking precedence over base
/// Used for nested styling (e.g., bold text inside a header)
pub fn mergeStyles(base: vaxis.Style, overlay: vaxis.Style) vaxis.Style {
    return .{
        // Overlay fg takes precedence if not default
        .fg = if (overlay.fg != .default) overlay.fg else base.fg,
        // Overlay bg takes precedence if not default
        .bg = if (overlay.bg != .default) overlay.bg else base.bg,
        // Combine boolean attributes - OR them together
        .bold = base.bold or overlay.bold,
        .dim = base.dim or overlay.dim,
        .italic = base.italic or overlay.italic,
        .ul_style = if (overlay.ul_style != .off) overlay.ul_style else base.ul_style,
        .blink = base.blink or overlay.blink,
        .reverse = base.reverse or overlay.reverse,
        .invisible = base.invisible or overlay.invisible,
        .strikethrough = base.strikethrough or overlay.strikethrough,
        // Underline color - overlay takes precedence if set
        .ul = if (overlay.ul != .default) overlay.ul else base.ul,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "default colors defined" {
    // All header styles should have colors set
    try std.testing.expect(default.h1.fg != .default);
    try std.testing.expect(default.h2.fg != .default);
    try std.testing.expect(default.h3.fg != .default);
    try std.testing.expect(default.h4.fg != .default);
    try std.testing.expect(default.h5.fg != .default);
    try std.testing.expect(default.h6.fg != .default);

    // Headers h1-h3 should be bold
    try std.testing.expect(default.h1.bold);
    try std.testing.expect(default.h2.bold);
    try std.testing.expect(default.h3.bold);

    // Emphasis styles should have their attributes
    try std.testing.expect(default.bold.bold);
    try std.testing.expect(default.italic.italic);
    try std.testing.expect(default.strikethrough.strikethrough);

    // Inline code should have foreground color
    try std.testing.expect(default.inline_code.fg != .default);

    // Link text should be styled
    try std.testing.expect(default.link_text.fg != .default);
    try std.testing.expect(default.link_text.ul_style != .off);
}

test "inline code uses cyan accent" {
    try std.testing.expectEqual(Color.cyan, default.inline_code.fg);
}

test "mergeStyles - overlay fg" {
    // Blue overlay should replace white base
    const base = vaxis.Style{ .fg = Color.white };
    const overlay = vaxis.Style{ .fg = Color.blue };
    const merged = mergeStyles(base, overlay);

    try std.testing.expectEqual(Color.blue, merged.fg);
}

test "mergeStyles - preserve base when overlay default" {
    // When overlay has default fg, base fg should be preserved
    const base = vaxis.Style{ .fg = Color.cyan, .bold = true };
    const overlay = vaxis.Style{ .italic = true }; // Default fg

    const merged = mergeStyles(base, overlay);

    try std.testing.expectEqual(Color.cyan, merged.fg);
    try std.testing.expect(merged.bold);
    try std.testing.expect(merged.italic);
}

test "mergeStyles - combine attributes" {
    // Bold base + italic overlay = bold and italic
    const base = vaxis.Style{ .bold = true };
    const overlay = vaxis.Style{ .italic = true };
    const merged = mergeStyles(base, overlay);

    try std.testing.expect(merged.bold);
    try std.testing.expect(merged.italic);
}

test "mergeStyles - overlay bg takes precedence" {
    const base = vaxis.Style{ .bg = Color.red };
    const overlay = vaxis.Style{ .bg = Color.green };
    const merged = mergeStyles(base, overlay);

    try std.testing.expectEqual(Color.green, merged.bg);
}

test "mergeStyles - preserve base bg when overlay default" {
    const base = vaxis.Style{ .bg = Color.blue };
    const overlay = vaxis.Style{}; // Default bg

    const merged = mergeStyles(base, overlay);

    try std.testing.expectEqual(Color.blue, merged.bg);
}

test "mergeStyles - strikethrough combination" {
    // Base strikethrough + overlay bold = both
    const base = vaxis.Style{ .strikethrough = true };
    const overlay = vaxis.Style{ .bold = true };
    const merged = mergeStyles(base, overlay);

    try std.testing.expect(merged.strikethrough);
    try std.testing.expect(merged.bold);
}

test "mergeStyles - ul_style overlay takes precedence" {
    const base = vaxis.Style{ .ul_style = .single };
    const overlay = vaxis.Style{ .ul_style = .double };
    const merged = mergeStyles(base, overlay);

    try std.testing.expectEqual(vaxis.Style.Underline.double, merged.ul_style);
}

test "mergeStyles - preserve base ul_style when overlay off" {
    const base = vaxis.Style{ .ul_style = .single };
    const overlay = vaxis.Style{}; // ul_style defaults to .off

    const merged = mergeStyles(base, overlay);

    try std.testing.expectEqual(vaxis.Style.Underline.single, merged.ul_style);
}
