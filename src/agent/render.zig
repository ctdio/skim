const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const state = @import("state.zig");
const AgentState = state.AgentState;
const agent_help = @import("agent_help.zig");
const OwnedPlanEntry = state.OwnedPlanEntry;
const Message = state.Message;
const MAX_SLASH_MENU_VISIBLE = state.MAX_SLASH_MENU_VISIBLE;
const InputEditor = @import("input_editor.zig").InputEditor;
const AcpManager = @import("../acp/manager.zig").AcpManager;
const diff_algo = @import("diff.zig");
const DiffLine = diff_algo.DiffLine;
const chat_line_map = @import("chat_line_map.zig");
const ChatLineMap = chat_line_map.ChatLineMap;
const ChatLineRecord = chat_line_map.ChatLineRecord;
const StyledSegment = chat_line_map.StyledSegment;
const SideLineKind = chat_line_map.SideLineKind;
const protocol = @import("../acp/protocol.zig");
const command_palette = @import("command_palette.zig");
const render_plan = @import("render_plan.zig");

// Import skim's color palette for consistent styling
const rendering_common = @import("../rendering/common.zig");
const Color = rendering_common.Color;

// Import utilities for word-aware wrapping and dialog rendering
const rendering_utils = @import("../rendering/utils.zig");
const RenderUtils = rendering_utils.RenderUtils;

// Import markdown rendering for agent messages
const markdown = @import("markdown/markdown.zig");
const MarkdownColors = markdown.MarkdownColors;

/// Safely print text to window, handling invalid UTF-8 gracefully.
/// If text contains invalid UTF-8, renders valid portions and replaces invalid bytes with �.
/// Returns the print result (columns advanced).
fn safePrint(win: vaxis.Window, text: []const u8, style: vaxis.Style, row: usize, col_offset: usize) vaxis.Window.PrintResult {
    // Fast path: if valid UTF-8, print directly
    if (std.unicode.utf8ValidateSlice(text)) {
        var seg = [_]vaxis.Cell.Segment{
            .{ .text = text, .style = style },
        };
        return win.print(&seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
    }

    // Slow path: print character by character, replacing invalid sequences
    var col: usize = col_offset;
    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            // Invalid start byte - show replacement character
            win.writeCell(@intCast(col), @intCast(row), .{
                .char = .{ .grapheme = "�", .width = 1 },
                .style = style,
            });
            col += 1;
            i += 1;
            continue;
        };

        // Check if we have enough bytes
        if (i + seq_len > text.len) {
            // Truncated sequence - show replacement for remaining bytes
            while (i < text.len) {
                win.writeCell(@intCast(col), @intCast(row), .{
                    .char = .{ .grapheme = "�", .width = 1 },
                    .style = style,
                });
                col += 1;
                i += 1;
            }
            break;
        }

        // Validate the sequence
        const seq = text[i .. i + seq_len];
        if (std.unicode.utf8ValidateSlice(seq)) {
            // Valid sequence - print it with proper display width
            const char_width = vaxis.gwidth.gwidth(seq, .unicode);
            win.writeCell(@intCast(col), @intCast(row), .{
                .char = .{ .grapheme = seq, .width = @intCast(char_width) },
                .style = style,
            });
            col += char_width;
            i += seq_len;
        } else {
            // Invalid sequence - show replacement character
            win.writeCell(@intCast(col), @intCast(row), .{
                .char = .{ .grapheme = "�", .width = 1 },
                .style = style,
            });
            col += 1;
            i += 1; // Only skip one byte, try to resync
        }
    }

    return .{ .col = @intCast(col - col_offset), .row = 0, .overflow = false };
}

/// Render text with inline markdown styling for agent messages
/// Uses the message's markdown parser to apply styles to inline elements
fn renderTextWithMarkdown(
    win: vaxis.Window,
    text: []const u8,
    msg: *Message,
    base_style: vaxis.Style,
    is_cursor_line: bool,
    is_in_visual: bool,
    row: usize,
    col_offset: usize,
) void {
    if (text.len == 0) return;

    // Try to ensure markdown is parsed for this message
    if (!msg.ensureMarkdownParsed()) {
        // Parsing failed, fall back to plain rendering
        _ = safePrint(win, text, withHighlightBg(base_style, is_cursor_line, is_in_visual), row, col_offset);
        return;
    }

    const md_parser = &(msg.md_parser orelse {
        // No parser available, fall back to plain rendering
        _ = safePrint(win, text, withHighlightBg(base_style, is_cursor_line, is_in_visual), row, col_offset);
        return;
    });

    // Find where this text line starts in the full message content
    // This is a pointer subtraction to find the byte offset
    const text_start = getByteOffsetInContent(text, msg.content);

    if (text_start) |start_offset| {
        const end_offset = start_offset + text.len;

        // Render character by character, checking style at each position
        var col: usize = col_offset;
        var i: usize = 0;
        while (i < text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            const char_end = @min(i + char_len, text.len);
            const char_slice = text[i..char_end];
            const char_width = vaxis.gwidth.gwidth(char_slice, .unicode);

            // Get the style for this character position based on markdown AST
            const md_style = getMarkdownStyleAtPosition(md_parser, start_offset + i);
            const final_style = if (md_style) |ms|
                markdown.colors.mergeStyles(withHighlightBg(base_style, is_cursor_line, is_in_visual), ms)
            else
                withHighlightBg(base_style, is_cursor_line, is_in_visual);

            win.writeCell(@intCast(col), @intCast(row), .{
                .char = .{ .grapheme = char_slice, .width = @intCast(char_width) },
                .style = final_style,
            });

            col += char_width;
            i = char_end;
        }
        _ = end_offset;
    } else {
        // Could not find text offset, fall back to plain rendering
        _ = safePrint(win, text, withHighlightBg(base_style, is_cursor_line, is_in_visual), row, col_offset);
    }
}

/// Find the byte offset of a text slice within the full message content
/// Returns null if the text is not a direct slice of the content
fn getByteOffsetInContent(text: []const u8, content: []const u8) ?usize {
    if (text.len == 0) return null;
    if (content.len == 0) return null;

    // Check if text.ptr is within content's bounds
    const text_addr = @intFromPtr(text.ptr);
    const content_start = @intFromPtr(content.ptr);
    const content_end = content_start + content.len;

    if (text_addr >= content_start and text_addr < content_end) {
        return text_addr - content_start;
    }

    // Text is not a direct slice of content (might be a copy)
    // Fall back to searching for the text in content
    // Note: This is imprecise if the same text appears multiple times
    return std.mem.indexOf(u8, content, text);
}

/// Get the markdown style for a given byte position in the parsed content
/// Returns null if no special styling applies at this position
fn getMarkdownStyleAtPosition(md_parser: *const markdown.MarkdownParser, byte_pos: usize) ?vaxis.Style {
    const root = md_parser.getRoot() orelse return null;

    // Find the deepest node containing this position
    var best_style: ?vaxis.Style = null;
    walkForStyleAtPosition(root, byte_pos, md_parser, &best_style);

    return best_style;
}

/// Recursively walk the AST to find the style for a given position
fn walkForStyleAtPosition(
    node: @import("tree-sitter").Node,
    byte_pos: usize,
    md_parser: *const markdown.MarkdownParser,
    best_style: *?vaxis.Style,
) void {
    const start = node.startByte();
    const end = node.endByte();

    // Skip nodes that don't contain this position
    if (byte_pos < start or byte_pos >= end) return;

    // Check if this node has a special style
    // Use kind() method from tree-sitter to get node type string
    const node_type_str = node.kind();
    const node_type = markdown.NodeType.fromTreeSitter(node_type_str);

    // Get style for this node type
    const style = getStyleForNodeType(node_type, node, md_parser);
    if (style) |s| {
        // Deeper nodes override shallower ones
        if (best_style.* == null) {
            best_style.* = s;
        } else {
            // Merge styles for nested elements
            best_style.* = markdown.colors.mergeStyles(best_style.*.?, s);
        }
    }

    // Recurse into children
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        if (node.child(i)) |child| {
            walkForStyleAtPosition(child, byte_pos, md_parser, best_style);
        }
    }
}

/// Map node type to markdown style
fn getStyleForNodeType(node_type: markdown.NodeType, node: @import("tree-sitter").Node, md_parser: *const markdown.MarkdownParser) ?vaxis.Style {
    const md_colors = markdown.colors.default;

    return switch (node_type) {
        .heading => getHeaderStyleFromNode(node, md_parser, md_colors),
        .strong_emphasis => md_colors.bold,
        .emphasis => md_colors.italic,
        .strikethrough => md_colors.strikethrough,
        .code_span => .{
            .fg = md_colors.inline_code.fg,
            .bg = md_colors.inline_code_bg,
        },
        .link => md_colors.link_text,
        else => null,
    };
}

/// Get header style based on header level
fn getHeaderStyleFromNode(node: @import("tree-sitter").Node, md_parser: *const markdown.MarkdownParser, md_colors: MarkdownColors) vaxis.Style {
    const node_type_str = node.kind();

    // Check for setext heading (uses === or --- underlines)
    if (std.mem.eql(u8, node_type_str, "setext_heading")) {
        const level = getSetextLevelFromNode(node);
        return getHeaderStyleByLevel(level, md_colors);
    }

    // ATX heading: count # characters
    const text = md_parser.getNodeText(node);
    var level: usize = 0;
    for (text) |c| {
        if (c == '#') {
            level += 1;
        } else {
            break;
        }
    }

    level = @max(1, @min(6, level));
    return getHeaderStyleByLevel(level, md_colors);
}

/// Get header style by level number
fn getHeaderStyleByLevel(level: usize, md_colors: MarkdownColors) vaxis.Style {
    return switch (level) {
        1 => md_colors.h1,
        2 => md_colors.h2,
        3 => md_colors.h3,
        4 => md_colors.h4,
        5 => md_colors.h5,
        else => md_colors.h6,
    };
}

/// Determine setext header level by looking for underline child nodes
fn getSetextLevelFromNode(node: @import("tree-sitter").Node) usize {
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        if (node.child(i)) |child| {
            const child_type = child.kind();
            if (std.mem.eql(u8, child_type, "setext_h1_underline")) {
                return 1;
            }
            if (std.mem.eql(u8, child_type, "setext_h2_underline")) {
                return 2;
            }
        }
    }
    return 1; // Default to H1 if no underline found
}

/// Render text with syntax highlighting applied
/// If highlights is null, falls back to rendering with base_style
fn printWithHighlights(
    win: vaxis.Window,
    text: []const u8,
    highlights: ?[]const chat_line_map.Highlight,
    base_style: vaxis.Style,
    row: usize,
    col_offset: usize,
) void {
    if (text.len == 0) return;

    // If no highlights, use simple print
    if (highlights == null or highlights.?.len == 0) {
        _ = safePrint(win, text, base_style, row, col_offset);
        return;
    }

    const hl_list = highlights.?;

    // Track current byte position in text and display column
    var text_pos: usize = 0;
    var col: usize = col_offset;

    // Process each highlight - print character by character to handle highlighting correctly
    for (hl_list) |hl| {
        // Print any text before this highlight with base style
        while (text_pos < hl.start_byte and text_pos < text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(text[text_pos]) catch 1;
            const end = @min(text_pos + char_len, text.len);
            const char_slice = text[text_pos..end];
            const char_width = vaxis.gwidth.gwidth(char_slice, .unicode);

            win.writeCell(@intCast(col), @intCast(row), .{
                .char = .{ .grapheme = char_slice, .width = @intCast(char_width) },
                .style = base_style,
            });
            col += char_width;
            text_pos = end;
        }

        // Print the highlighted text with syntax color
        const hl_end = @min(hl.end_byte, text.len);
        if (text_pos < hl_end) {
            const fg_color = mapHighlightCategory(hl.category);
            const hl_style = vaxis.Style{
                .fg = fg_color,
                .bg = base_style.bg,
                .bold = base_style.bold,
                .italic = base_style.italic,
            };

            while (text_pos < hl_end) {
                const char_len = std.unicode.utf8ByteSequenceLength(text[text_pos]) catch 1;
                const end = @min(text_pos + char_len, text.len);
                const char_slice = text[text_pos..end];
                const char_width = vaxis.gwidth.gwidth(char_slice, .unicode);

                win.writeCell(@intCast(col), @intCast(row), .{
                    .char = .{ .grapheme = char_slice, .width = @intCast(char_width) },
                    .style = hl_style,
                });
                col += char_width;
                text_pos = end;
            }
        }
    }

    // Print any remaining text after the last highlight
    while (text_pos < text.len) {
        const char_len = std.unicode.utf8ByteSequenceLength(text[text_pos]) catch 1;
        const end = @min(text_pos + char_len, text.len);
        const char_slice = text[text_pos..end];
        const char_width = vaxis.gwidth.gwidth(char_slice, .unicode);

        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = char_slice, .width = @intCast(char_width) },
            .style = base_style,
        });
        col += char_width;
        text_pos = end;
    }
}

/// Map tree-sitter highlight categories to colors (GitHub Dark theme)
fn mapHighlightCategory(category: []const u8) vaxis.Color {
    // Keywords
    if (std.mem.eql(u8, category, "keyword") or
        std.mem.eql(u8, category, "keyword.return") or
        std.mem.eql(u8, category, "keyword.function") or
        std.mem.eql(u8, category, "keyword.operator") or
        std.mem.eql(u8, category, "keyword.import") or
        std.mem.eql(u8, category, "keyword.storage") or
        std.mem.eql(u8, category, "keyword.modifier") or
        std.mem.eql(u8, category, "keyword.repeat") or
        std.mem.eql(u8, category, "keyword.conditional") or
        std.mem.eql(u8, category, "keyword.exception"))
    {
        return .{ .rgb = .{ 0xff, 0x7b, 0x72 } }; // Red-ish (keywords)
    }

    // Types
    if (std.mem.eql(u8, category, "type") or
        std.mem.eql(u8, category, "type.builtin") or
        std.mem.eql(u8, category, "type.qualifier"))
    {
        return .{ .rgb = .{ 0x79, 0xc0, 0xff } }; // Blue (types)
    }

    // Functions
    if (std.mem.eql(u8, category, "function") or
        std.mem.eql(u8, category, "function.builtin") or
        std.mem.eql(u8, category, "function.call") or
        std.mem.eql(u8, category, "function.method") or
        std.mem.eql(u8, category, "method"))
    {
        return .{ .rgb = .{ 0xd2, 0xa8, 0xff } }; // Purple (functions)
    }

    // Strings
    if (std.mem.eql(u8, category, "string") or
        std.mem.eql(u8, category, "string.special") or
        std.mem.eql(u8, category, "string.escape") or
        std.mem.eql(u8, category, "character"))
    {
        return .{ .rgb = .{ 0xa5, 0xd6, 0xff } }; // Light blue (strings)
    }

    // Numbers
    if (std.mem.eql(u8, category, "number") or
        std.mem.eql(u8, category, "float"))
    {
        return .{ .rgb = .{ 0x79, 0xc0, 0xff } }; // Blue (numbers)
    }

    // Comments
    if (std.mem.eql(u8, category, "comment") or
        std.mem.eql(u8, category, "comment.line") or
        std.mem.eql(u8, category, "comment.block"))
    {
        return .{ .rgb = .{ 0x8b, 0x94, 0x9e } }; // Gray (comments)
    }

    // Constants
    if (std.mem.eql(u8, category, "constant") or
        std.mem.eql(u8, category, "constant.builtin") or
        std.mem.eql(u8, category, "boolean"))
    {
        return .{ .rgb = .{ 0x79, 0xc0, 0xff } }; // Blue (constants)
    }

    // Variables
    if (std.mem.eql(u8, category, "variable") or
        std.mem.eql(u8, category, "variable.builtin") or
        std.mem.eql(u8, category, "variable.parameter"))
    {
        return .{ .rgb = .{ 0xff, 0xd0, 0x7b } }; // Orange (variables)
    }

    // Operators and punctuation
    if (std.mem.eql(u8, category, "operator") or
        std.mem.eql(u8, category, "punctuation") or
        std.mem.eql(u8, category, "punctuation.bracket") or
        std.mem.eql(u8, category, "punctuation.delimiter"))
    {
        return Color.white;
    }

    // Property/field
    if (std.mem.eql(u8, category, "property") or
        std.mem.eql(u8, category, "field"))
    {
        return .{ .rgb = .{ 0x7e, 0xe7, 0x87 } }; // Green (properties)
    }

    // Attribute
    if (std.mem.eql(u8, category, "attribute") or
        std.mem.eql(u8, category, "label"))
    {
        return .{ .rgb = .{ 0x7e, 0xe7, 0x87 } }; // Green (attributes)
    }

    // Default: white
    return Color.white;
}

// Gutter width for line numbers in side-by-side diff view
const GUTTER_WIDTH: usize = 5;

// Maximum height for the expandable input area (excluding separator and footer)
const MAX_INPUT_LINES: usize = 30;
// Maximum number of input lines to track (must be >= MAX_INPUT_LINES)
const MAX_TRACKED_LINES: usize = 100;

// Maximum number of plan entries to show (additional entries show "+N more")
const MAX_PLAN_ENTRIES: usize = 5;

// Maximum width for slash command menu
// Fixed widths for menus - prevents jarring resize on content change
const SLASH_MENU_WIDTH: usize = 60;
const FILE_PICKER_WIDTH: usize = 70;
const MENU_PADDING: usize = 1; // Horizontal padding inside menus

/// Merge a style with highlight background for history mode cursor/visual selection.
/// Visual selection takes precedence over cursor highlighting.
/// Preserves the foreground color and other style attributes, only overriding the background.
fn withHighlightBg(style: vaxis.Style, is_cursor_line: bool, is_in_visual: bool) vaxis.Style {
    const bg_color = if (is_in_visual)
        Color.visual_select_bg
    else if (is_cursor_line)
        Color.cursor_bg
    else
        return style;

    return vaxis.Style{
        .fg = style.fg,
        .bg = bg_color,
        .ul = style.ul,
        .ul_style = style.ul_style,
        .bold = style.bold,
        .dim = style.dim,
        .italic = style.italic,
        .blink = style.blink,
        .reverse = style.reverse,
        .invisible = style.invisible,
        .strikethrough = style.strikethrough,
    };
}

/// Legacy wrapper for cursor-only highlighting (for backwards compatibility).
fn withCursorBg(style: vaxis.Style, is_cursor_line: bool) vaxis.Style {
    return withHighlightBg(style, is_cursor_line, false);
}

/// Render diagonal fill pattern using Unicode box drawing diagonal character.
/// Used for empty panes in side-by-side diff view.
fn renderDiagonalFill(win: vaxis.Window, row: usize, col: usize, width: usize, is_cursor_line: bool) void {
    if (width == 0) return;

    const diagonal = "╱"; // U+2571 - 3 bytes in UTF-8
    const fill_style: vaxis.Style = if (is_cursor_line)
        .{ .fg = Color.gray_234, .bg = Color.cursor_bg }
    else
        .{ .fg = Color.gray_234 };

    var i: usize = 0;
    while (i < width) : (i += 1) {
        win.writeCell(@intCast(col + i), @intCast(row), .{
            .char = .{ .grapheme = diagonal, .width = 1 },
            .style = fill_style,
        });
    }
}

// =============================================================================
// File Reference Detection
// =============================================================================

/// A range representing an @file reference in the input text
const FileRefRange = struct {
    start: usize, // Position of @
    end: usize, // Position after the file path
};

/// Find all valid @file references in the input text (files that exist)
/// Returns a list of ranges. Caller owns the returned slice.
fn findFileRefRanges(allocator: std.mem.Allocator, text: []const u8) ![]FileRefRange {
    var ranges: std.ArrayList(FileRefRange) = .{};
    errdefer ranges.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '@') {
            // Check word boundary
            const at_word_boundary = (i == 0 or
                text[i - 1] == ' ' or
                text[i - 1] == '\n' or
                text[i - 1] == '\t');

            if (at_word_boundary) {
                const path_start = i + 1;
                var path_end = path_start;
                while (path_end < text.len and
                    text[path_end] != ' ' and
                    text[path_end] != '\n' and
                    text[path_end] != '\t')
                {
                    path_end += 1;
                }

                const file_path = text[path_start..path_end];
                if (file_path.len > 0) {
                    // Check if file exists
                    const cwd = std.fs.cwd();
                    if (cwd.access(file_path, .{})) {
                        try ranges.append(allocator, .{ .start = i, .end = path_end });
                        i = path_end;
                        continue;
                    } else |_| {}
                }
            }
        }
        i += 1;
    }

    return ranges.toOwnedSlice(allocator);
}

/// Check if a position is within any file reference range
fn isInFileRef(pos: usize, ranges: []const FileRefRange) bool {
    for (ranges) |r| {
        if (pos >= r.start and pos < r.end) return true;
    }
    return false;
}

// =============================================================================
// Scrollbar
// =============================================================================

const ScrollbarInfo = struct {
    thumb_start: usize,
    thumb_end: usize,
    show_top_arrow: bool,
    show_bottom_arrow: bool,
};

fn calculateScrollbar(
    viewport_height: usize,
    total_lines: usize,
    scroll_offset: usize,
) ScrollbarInfo {
    // Thumb size: proportional to viewport vs total
    const thumb_size = @max(1, (viewport_height * viewport_height) / total_lines);

    // Thumb position: proportional to scroll offset
    const scrollable_range = if (total_lines > viewport_height)
        total_lines - viewport_height
    else
        0;

    const thumb_pos = if (scrollable_range > 0)
        (scroll_offset * (viewport_height - thumb_size)) / scrollable_range
    else
        0;

    return .{
        .thumb_start = thumb_pos,
        .thumb_end = thumb_pos + thumb_size,
        .show_top_arrow = scroll_offset > 0,
        .show_bottom_arrow = scroll_offset < scrollable_range,
    };
}

fn renderScrollbar(win: vaxis.Window, info: ScrollbarInfo) void {
    // Guard against small windows to prevent integer overflow
    if (win.height < 3 or win.width == 0) return;

    const col = win.width - 1; // Rightmost column
    const track_style = vaxis.Style{ .fg = Color.dim_gray, .dim = true };
    const thumb_style = vaxis.Style{ .fg = Color.dim_gray };
    const arrow_style = vaxis.Style{ .fg = Color.dim_gray };

    // Pre-calculate bottom arrow position (safe now due to guard above)
    const bottom_arrow_row = win.height - 2;

    for (0..win.height) |row| {
        var char: []const u8 = undefined;
        var style: vaxis.Style = undefined;

        // Inset arrows by 1 row to avoid covering content at edges
        if (row == 1 and info.show_top_arrow) {
            char = "▴"; // Smaller, subtler arrow
            style = arrow_style;
        } else if (row == bottom_arrow_row and info.show_bottom_arrow) {
            char = "▾"; // Smaller, subtler arrow
            style = arrow_style;
        } else if (row >= info.thumb_start and row < info.thumb_end) {
            char = "│"; // Lighter bar for thumb
            style = thumb_style;
        } else {
            char = "│"; // Light vertical line for track
            style = track_style;
        }

        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = char, .width = 1 },
            .style = style,
        });
    }
}

// =============================================================================
// Unified Inline Menu Renderer
// =============================================================================

/// Generic menu item for unified rendering
const MenuItem = struct {
    name: []const u8,
    description: []const u8,
};

/// Render an inline menu using the model selector style
/// Returns the number of rows used
fn renderInlineMenu(
    win: vaxis.Window,
    title: []const u8,
    items: []const MenuItem,
    selected_idx: usize,
    scroll_offset: usize,
    max_visible: usize,
    footer: []const u8,
) usize {
    if (items.len == 0) return 0;

    const visible_count = @min(items.len - scroll_offset, max_visible);
    var row: usize = 0;

    // Row 0: Separator line
    const separator_style = vaxis.Style{ .fg = Color.dim_gray };
    for (0..win.width) |col| {
        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = separator_style,
        });
    }
    row += 1;

    // Row 1: Title
    const title_style = vaxis.Style{ .fg = Color.magenta, .bold = true };
    var title_seg = [_]vaxis.Cell.Segment{
        .{ .text = title, .style = title_style },
    };
    _ = win.print(&title_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });
    row += 1;

    // Rows 2+: Menu items
    const normal_style = vaxis.Style{ .fg = Color.white };
    const selected_style = vaxis.Style{ .fg = Color.black, .bg = Color.cyan, .bold = true };
    const desc_style = vaxis.Style{ .fg = Color.dim_gray };

    // Show scroll indicator at top if there are items above
    if (scroll_offset > 0 and row < win.height) {
        const scroll_ind = "  ↑ more";
        const scroll_style = vaxis.Style{ .fg = Color.dim_gray };
        var scroll_seg = [_]vaxis.Cell.Segment{
            .{ .text = scroll_ind, .style = scroll_style },
        };
        _ = win.print(&scroll_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });
        row += 1;
    }

    for (0..visible_count) |i| {
        if (row >= win.height) break;

        const item_idx = scroll_offset + i;
        if (item_idx >= items.len) break;

        const item = items[item_idx];
        const is_selected = item_idx == selected_idx;
        const style = if (is_selected) selected_style else normal_style;

        // Selection indicator
        const indicator: []const u8 = if (is_selected) "▸ " else "  ";
        var ind_seg = [_]vaxis.Cell.Segment{
            .{ .text = indicator, .style = style },
        };
        _ = win.print(&ind_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });

        // Item name
        var name_seg = [_]vaxis.Cell.Segment{
            .{ .text = item.name, .style = style },
        };
        _ = win.print(&name_seg, .{ .row_offset = @intCast(row), .col_offset = 3 });

        // Description (after name, if space allows)
        const name_end = 3 + item.name.len + 2;
        if (name_end < win.width and item.description.len > 0) {
            var desc_seg = [_]vaxis.Cell.Segment{
                .{ .text = item.description, .style = if (is_selected) style else desc_style },
            };
            _ = win.print(&desc_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(name_end) });
        }

        row += 1;
    }

    // Show scroll indicator at bottom if there are more items below
    const has_more_below = scroll_offset + visible_count < items.len;
    if (has_more_below and row < win.height) {
        const scroll_ind = "  ↓ more";
        const scroll_style = vaxis.Style{ .fg = Color.dim_gray };
        var scroll_seg = [_]vaxis.Cell.Segment{
            .{ .text = scroll_ind, .style = scroll_style },
        };
        _ = win.print(&scroll_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });
        row += 1;
    }

    // Footer row with keybindings
    if (row < win.height and footer.len > 0) {
        const kb_style = vaxis.Style{ .fg = Color.dim_gray };
        const kb_col = if (win.width > footer.len) win.width - footer.len else 0;

        var kb_seg = [_]vaxis.Cell.Segment{
            .{ .text = footer, .style = kb_style },
        };
        _ = win.print(&kb_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(kb_col) });
        row += 1;
    }

    return row;
}

// =============================================================================
// Input Line Utilities
// =============================================================================

/// Information about lines in the input text
const InputLineInfo = struct {
    line_count: usize,
    cursor_row: usize,
    cursor_col: usize,
    lines: [MAX_TRACKED_LINES]LineSpan,
};

const LineSpan = struct {
    start: usize,
    end: usize,
};

/// Analyze input text to get line information
fn getInputLineInfo(text: []const u8, cursor_pos: usize) InputLineInfo {
    var info = InputLineInfo{
        .line_count = 1,
        .cursor_row = 0,
        .cursor_col = 0,
        .lines = undefined,
    };

    // Initialize first line
    info.lines[0] = .{ .start = 0, .end = 0 };

    var current_line: usize = 0;
    var line_start: usize = 0;

    for (text, 0..) |c, i| {
        if (c == '\n') {
            // End current line (only if within bounds)
            if (current_line < MAX_TRACKED_LINES) {
                info.lines[current_line].end = i;
            }

            // Check if cursor is on this line
            if (cursor_pos >= line_start and cursor_pos <= i) {
                info.cursor_row = @min(current_line, MAX_TRACKED_LINES - 1);
                info.cursor_col = cursor_pos - line_start;
            }

            // Start new line
            current_line += 1;
            if (current_line < MAX_TRACKED_LINES) {
                info.lines[current_line] = .{ .start = i + 1, .end = i + 1 };
            }
            line_start = i + 1;
            info.line_count += 1;
        }
    }

    // Handle last line
    if (current_line < MAX_TRACKED_LINES) {
        info.lines[current_line].end = text.len;
    }

    // Check if cursor is on the last line (clamp to max tracked line)
    if (cursor_pos >= line_start) {
        info.cursor_row = @min(current_line, MAX_TRACKED_LINES - 1);
        info.cursor_col = cursor_pos - line_start;
    }

    return info;
}

// =============================================================================
// Agent Panel Renderer
// =============================================================================

/// Render the agent chat panel
pub fn renderAgentPanel(app: *App, win: vaxis.Window) !void {
    if (win.width == 0 or win.height == 0) return;

    const agent_state = app.getActiveAgentState() orelse return;
    const is_focused = app.mode == .agent;

    // Use fill() instead of clear() to ensure all cells are explicitly set to spaces
    // This prevents artifacts from previous renders (e.g., permission dialogs)
    const blank = vaxis.Cell{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{},
    };
    win.fill(blank);

    // Calculate dynamic input height based on content or mode
    const text = agent_state.input.getText();

    // Check if there's a pending permission
    const pending_permission = if (app.getActiveAcpManager()) |mgr| mgr.getPendingPermission() else null;

    // Calculate height based on mode or pending permission
    // Note: model_selection mode renders as a centered dialog overlay, not in the input area
    const visible_lines = if (pending_permission) |perm| blk: {
        // Separator (1) + title (1) + description (0 or 1) + options + footer (1)
        const desc_rows: usize = if (perm.description != null) 1 else 0;
        break :blk 3 + desc_rows + perm.options.len;
    } else blk: {
        // Calculate wrapped line count accounting for panel width
        // This ensures the input area expands properly in side-by-side mode
        // Account for: prompt/continuation (3 chars) + scrollbar (1 char when visible) + margin (1 char)
        const input_col: usize = 3; // After "> " or "  "
        const max_input_width = if (win.width > input_col + 2) win.width - input_col - 2 else 1;
        var total_display_lines: usize = 0;
        var line_iter = std.mem.splitScalar(u8, text, '\n');
        while (line_iter.next()) |text_line| {
            if (text_line.len == 0) {
                total_display_lines += 1; // Empty line still takes one display line
            } else {
                // Calculate how many chunks this line wraps into
                const chunks = (text_line.len + max_input_width - 1) / max_input_width;
                total_display_lines += chunks;
            }
        }
        if (total_display_lines == 0) total_display_lines = 1; // Always show at least one line
        break :blk @max(3, @min(total_display_lines, MAX_INPUT_LINES));
    };

    // Calculate plan height (only if visible and has entries)
    const plan_entry_count = agent_state.plan.count();
    const plan_height: usize = if (agent_state.plan.visible and plan_entry_count > 0) blk: {
        // Header (1) + entries (all if expanded, 1 if collapsed)
        const visible_entries: usize = if (agent_state.plan.expanded) plan_entry_count else 1;
        break :blk 1 + visible_entries;
    } else 0;

    // Calculate status area height (shown between messages and plan when agent is thinking or session initializing with queued message)
    // Layout: empty row + "Generating..."/"Waiting..." (with inline hint) + empty row + optional queued message + empty row
    const is_thinking = app.isAgentThinking();
    const session_initializing = app.isSessionInitializing();
    const show_status_area = is_thinking or (session_initializing and agent_state.hasStagedPrompt());
    // Show interrupt hint inline when agent is thinking and vim is in normal mode
    const show_interrupt_hint = is_thinking and agent_state.input.vim.vim_mode == .normal;
    const status_height: usize = if (show_status_area) blk: {
        var height: usize = 3; // empty + "Generating..."/"Waiting..." + empty
        // Add queued message height if present
        if (agent_state.hasStagedPrompt()) {
            const staged_text = agent_state.getStagedPrompt();
            var line_count: usize = 0;
            var iter = std.mem.splitScalar(u8, staged_text, '\n');
            while (iter.next()) |_| {
                line_count += 1;
                if (line_count >= 3) break;
            }
            height += 1 + line_count + 1 + 1; // label + content lines + trailing bar + empty spacing
        }
        break :blk height;
    } else 0;

    // Calculate input area height (always shows normal input)
    // Layout: separator (1) + visible text lines + padding (1)
    // Note: Footer is now rendered by the unified status bar in app.zig, not here
    const padding_height: usize = 1; // Blank line between text and footer/statusline
    const input_height: usize = 1 + visible_lines + padding_height;

    // Calculate tab bar height (only shown when multiple tabs exist)
    const tab_bar_height: usize = if (app.tab_manager) |tm| (if (tm.tabCount() > 1) @as(usize, 1) else 0) else 0;

    // Layout: title (1 row) + tab bar (0 or 1) + messages (variable) + status (conditional) + plan (conditional) + input area (dynamic)
    const title_height: usize = 1;
    const fixed_height = title_height + tab_bar_height + status_height + plan_height + input_height;
    const messages_height = if (win.height > fixed_height)
        win.height - fixed_height
    else
        1;

    // Store viewport height for smart scrolling in key handlers
    agent_state.last_messages_viewport_height = messages_height;

    // Render title bar
    try renderTitleBar(app, win, is_focused);

    // Render tab bar (if multiple tabs)
    if (tab_bar_height > 0) {
        const tab_bar_win = win.child(.{
            .x_off = 0,
            .y_off = @intCast(title_height),
            .width = win.width,
            .height = 1,
        });
        _ = renderTabBar(app, tab_bar_win);
    }

    // Render message history
    const messages_win = win.child(.{
        .x_off = 0,
        .y_off = @intCast(title_height + tab_bar_height),
        .width = win.width,
        .height = @intCast(messages_height),
    });
    try renderMessages(app, messages_win, agent_state);

    // Render status area (if agent is thinking or session initializing with queued message)
    if (status_height > 0) {
        const status_win = win.child(.{
            .x_off = 0,
            .y_off = @intCast(title_height + tab_bar_height + messages_height),
            .width = win.width,
            .height = @intCast(status_height),
        });
        renderStatusArea(status_win, agent_state, is_thinking, show_interrupt_hint);
    }

    // Render plan area (if visible and has entries)
    if (plan_height > 0) {
        const plan_win = win.child(.{
            .x_off = 0,
            .y_off = @intCast(title_height + tab_bar_height + messages_height + status_height),
            .width = win.width,
            .height = @intCast(plan_height),
        });
        render_plan.renderPlanArea(plan_win, agent_state.plan.entries.items, agent_state.plan.expanded);
    }

    // Render input area (or permission prompt if pending)
    const input_win = win.child(.{
        .x_off = 0,
        .y_off = @intCast(title_height + tab_bar_height + messages_height + status_height + plan_height),
        .width = win.width,
        .height = @intCast(input_height),
    });
    try renderInputArea(app, input_win, agent_state, is_focused, pending_permission);

    // Render slash command menu as overlay (if visible)
    if (agent_state.slash_menu.visible) {
        try renderSlashMenu(win, agent_state, title_height + tab_bar_height + messages_height + status_height + plan_height);
    }

    // Render file picker menu as overlay (if visible)
    if (agent_state.file_picker.visible) {
        try renderFilePicker(win, agent_state, title_height + tab_bar_height + messages_height + status_height + plan_height);
    }

    // Render agent command palette as centered dialog (if visible)
    if (agent_state.cmd_palette.visible) {
        renderAgentCommandPalette(win, &agent_state.cmd_palette);
    }

    // Render model selection dialog as centered overlay (if in model_selection mode)
    if (app.mode == .model_selection) {
        renderModelSelectionDialog(app, win);
    }

    // Render help popup as overlay (if visible)
    if (agent_state.help_visible) {
        try agent_help.renderHelpPopup(app, win, agent_state);
    }
}

fn renderTitleBar(app: *App, win: vaxis.Window, is_focused: bool) !void {
    // Build title with server name when connected
    const title = if (app.getActiveAcpManager()) |mgr| blk: {
        if (mgr.server_name) |name| {
            // Show server name: " Claude Code " or " Claude Code [focused] "
            break :blk name;
        }
        break :blk "Agent";
    } else "Agent";

    const suffix = if (is_focused) " [focused]" else "";

    // Status from ACP connection
    var status_buf: [64]u8 = undefined;
    const status_text = if (app.getActiveAcpManager()) |mgr| blk: {
        const base_status = switch (mgr.status) {
            .disconnected => " Disconnected",
            .discovering => " Discovering...",
            .connecting => " Connecting...",
            .connected => " Creating session...",
            .session_active => " Active",
            .prompting => " Thinking...",
            .failed => " Failed",
        };
        // Show queued message count when prompting or during session initialization
        const queued = mgr.queuedPromptCount();
        if (queued > 0) {
            const fmt_result: ?[]const u8 = switch (mgr.status) {
                .discovering => std.fmt.bufPrint(&status_buf, " Discovering... ({d} queued)", .{queued}) catch null,
                .connecting => std.fmt.bufPrint(&status_buf, " Connecting... ({d} queued)", .{queued}) catch null,
                .connected => std.fmt.bufPrint(&status_buf, " Creating session... ({d} queued)", .{queued}) catch null,
                .prompting => std.fmt.bufPrint(&status_buf, " Thinking... ({d} queued)", .{queued}) catch null,
                else => null,
            };
            if (fmt_result) |result| {
                break :blk result;
            }
        }
        break :blk base_status;
    } else " Not connected";

    const title_style = vaxis.Style{
        .fg = Color.white,
        .bold = true,
    };

    // Clear title row (no background)
    for (0..win.width) |col| {
        win.writeCell(@intCast(col), 0, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{},
        });
    }

    // Print title: " {name} [focused] " or " {name} "
    var title_seg = [_]vaxis.Cell.Segment{
        .{ .text = " ", .style = title_style },
        .{ .text = title, .style = title_style },
        .{ .text = suffix, .style = title_style },
        .{ .text = " ", .style = title_style },
    };
    _ = win.print(&title_seg, .{ .row_offset = 0 });

    // Print status on the right
    const status_style = vaxis.Style{
        .fg = if (app.getActiveAcpManager()) |mgr|
            switch (mgr.status) {
                .session_active => Color.green,
                .discovering, .connecting, .connected, .prompting => Color.dim_gray,
                .disconnected => Color.white,
                .failed => Color.red,
            }
        else
            Color.white,
    };

    const status_width = std.unicode.utf8CountCodepoints(status_text) catch status_text.len;
    const title_width = 2 + (std.unicode.utf8CountCodepoints(title) catch title.len) + suffix.len; // " {title}{suffix} "
    const status_col = if (win.width > title_width + status_width)
        win.width - status_width
    else
        title_width;

    var status_seg = [_]vaxis.Cell.Segment{
        .{ .text = status_text, .style = status_style },
    };
    _ = win.print(&status_seg, .{ .row_offset = 0, .col_offset = @intCast(status_col) });
}

/// Render the tab bar when multiple tabs exist (vim-style)
/// Returns true if tab bar was rendered, false if skipped (single tab)
fn renderTabBar(app: *App, win: vaxis.Window) bool {
    const tm = app.tab_manager orelse return false;

    // Don't show tab bar for single tab
    if (tm.tabCount() <= 1) return false;

    // Safety: ensure window has valid dimensions
    if (win.width == 0 or win.height == 0) return false;

    // Safety: ensure active_idx is valid
    if (tm.active_idx >= tm.tabs.items.len) return false;

    // Fill background with dim color - explicitly fill each cell
    const bg_style = vaxis.Style{ .bg = Color.gray_240 };
    for (0..win.width) |x| {
        win.writeCell(@intCast(x), 0, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = bg_style,
        });
    }

    const active_idx = tm.active_idx;
    var col: usize = 0;

    for (tm.tabs.items, 0..) |*tab, idx| {
        // Calculate tab width first to check if it fits
        const max_name_len: usize = 15;
        const name_len = @min(tab.name.len, max_name_len);

        // Check if tab has activity (thinking or permission)
        const has_activity = tab.isThinking();
        const has_permission = tab.hasPendingPermission();

        // Activity indicator suffix
        const suffix_len: usize = if (has_permission or has_activity) 1 else 0;

        // Calculate total tab width: 2 spaces + name + suffix
        const name_and_suffix = std.math.add(usize, name_len, suffix_len) catch break;
        const tab_width = std.math.add(usize, name_and_suffix, 2) catch break;

        // Check if tab fits (with room for separator if not last tab)
        const needs_separator = idx + 1 < tm.tabs.items.len;
        const total_needed = std.math.add(usize, tab_width, if (needs_separator) @as(usize, 1) else 0) catch break;

        // Break if tab doesn't fit
        const next_col = std.math.add(usize, col, total_needed) catch break;
        if (next_col > win.width) break;

        const is_active = idx == active_idx;

        // Active tab: darker gray (236) background, inactive: lighter gray (240)
        const tab_style: vaxis.Style = if (is_active) .{
            .fg = Color.bright_white,
            .bg = Color.gray_236,
            .bold = true,
        } else .{
            .fg = Color.white,
            .bg = Color.gray_240,
        };

        const display_name = tab.name[0..name_len];

        // Activity indicator suffix
        const suffix: []const u8 = if (!is_active and has_permission)
            "!"
        else if (!is_active and has_activity)
            "*"
        else
            "";

        const suffix_style: vaxis.Style = if (has_permission)
            .{ .fg = Color.yellow, .bg = tab_style.bg, .bold = true }
        else
            .{ .fg = Color.cyan, .bg = tab_style.bg };

        // Print tab: " name " or " name* "
        var seg = [_]vaxis.Cell.Segment{
            .{ .text = " ", .style = tab_style },
            .{ .text = display_name, .style = tab_style },
            .{ .text = suffix, .style = suffix_style },
            .{ .text = " ", .style = tab_style },
        };
        _ = win.print(&seg, .{ .col_offset = @intCast(col) });

        col = std.math.add(usize, col, tab_width) catch break;

        // Separator between tabs (vim-style |)
        if (needs_separator) {
            var sep_seg = [_]vaxis.Cell.Segment{
                .{ .text = "|", .style = .{ .fg = Color.gray_240, .bg = Color.gray_240 } },
            };
            _ = win.print(&sep_seg, .{ .col_offset = @intCast(col) });
            col = std.math.add(usize, col, 1) catch break;
        }
    }

    // Show tab count on the right (vim-style)
    var hint_buf: [32]u8 = undefined;
    const hint = std.fmt.bufPrint(&hint_buf, " {d}/{d} ", .{ active_idx + 1, tm.tabCount() }) catch " ";
    const hint_len = hint.len;

    // Only show hint if it fits
    if (hint_len <= win.width) {
        const hint_col = win.width - hint_len;
        var hint_seg = [_]vaxis.Cell.Segment{
            .{ .text = hint, .style = .{ .fg = Color.white, .bg = Color.gray_240 } },
        };
        _ = win.print(&hint_seg, .{ .col_offset = @intCast(hint_col) });
    }

    return true;
}

fn renderMessages(app: *App, win: vaxis.Window, agent_state: *AgentState) !void {
    if (win.height == 0) return;

    // Clear the message area to remove any overlay artifacts
    win.clear();

    // Check agent connection status (unified across ACP and Opencode)
    const is_thinking = app.isAgentThinking();
    const is_loading = app.isSessionInitializing();

    // If no messages, show status-aware placeholder
    if (agent_state.messages.items.len == 0) {
        if (is_loading) {
            // Show prominent loading status in center
            const loading_text = if (app.getActiveAcpManager()) |mgr| switch (mgr.status) {
                .discovering => "Discovering agent...",
                .connecting => "Connecting to agent...",
                .connected => "Creating session...",
                else => "Initializing...",
            } else "Initializing...";
            const loading_style = vaxis.Style{
                .fg = Color.dim_gray,
                .bold = true,
            };
            var seg = [_]vaxis.Cell.Segment{
                .{ .text = loading_text, .style = loading_style },
            };
            const text_len = loading_text.len;
            const col = if (win.width > text_len) (win.width - text_len) / 2 else 0;
            _ = win.print(&seg, .{ .row_offset = @intCast(win.height / 2), .col_offset = @intCast(col) });
        } else if (!is_thinking) {
            const placeholder = "Type a prompt and press Enter to send.";
            const placeholder_style = vaxis.Style{
                .fg = Color.dim_gray,
                .italic = true,
            };
            var seg = [_]vaxis.Cell.Segment{
                .{ .text = placeholder, .style = placeholder_style },
            };
            const text_len = placeholder.len;
            const col = if (win.width > text_len) (win.width - text_len) / 2 else 0;
            _ = win.print(&seg, .{ .row_offset = @intCast(win.height / 2), .col_offset = @intCast(col) });
        }
        return;
    }

    // Ensure markdown is parsed for agent messages
    // This lazy-initializes the parser and parses content on first render
    // Parsing is skipped for non-agent messages (user, tool, etc.)
    for (agent_state.messages.items) |*msg| {
        _ = msg.ensureMarkdownParsed();
    }

    // Get the pre-computed line map (builds if dirty)
    // Reserve 4 cols for indent + 1 col for scrollbar
    const wrap_width = if (win.width > 5) win.width - 5 else 1;
    const line_map = agent_state.ensureLineMap(wrap_width, &app.syntax_highlighter) catch {
        // Fallback: show error message
        var err_seg = [_]vaxis.Cell.Segment{
            .{ .text = "Error building line map", .style = .{ .fg = Color.red } },
        };
        _ = win.print(&err_seg, .{ .row_offset = 0, .col_offset = 1 });
        return;
    };

    // Calculate scroll offset
    const total_lines = line_map.getTotalLines();
    const max_scroll = if (total_lines > win.height)
        total_lines - win.height
    else
        0;

    // Use max_scroll if in follow mode, otherwise use stored offset
    const scroll = if (agent_state.follow_bottom)
        max_scroll
    else
        @min(agent_state.scroll_offset, max_scroll);

    // Update stored offset with actual clamped value (for next scroll operation)
    agent_state.updateScrollOffset(scroll, max_scroll);

    // Render visible lines
    const start = scroll;
    const end = @min(start + win.height, total_lines);

    // Check if we're in history mode for cursor highlighting
    const in_history_mode = agent_state.isInHistoryMode();
    const in_visual_mode = agent_state.isInHistoryVisualMode();
    const cursor_line = agent_state.history.cursor_line;

    var row: usize = 0;
    for (start..end) |line_idx| {
        if (row >= win.height) break;

        const record = line_map.getLineRecord(line_idx) orelse continue;

        var col_offset: usize = record.indent;

        // Check if this is the cursor line in history mode
        // For user messages, highlight the entire message as a single unit
        const is_cursor_line = in_history_mode and (line_idx == cursor_line or agent_state.isLineInCursorUserMessage(line_idx));
        // Check if this line is in visual selection
        const is_in_visual = agent_state.isLineInVisualSelection(line_idx);

        // Fill background for diff lines (entire row) before printing anything
        if (record.fill_bg) {
            for (0..win.width) |col| {
                win.writeCell(@intCast(col), @intCast(row), .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = record.style,
                });
            }
        }

        // Visual selection highlighting - takes precedence over regular cursor
        if (is_in_visual) {
            const visual_style = vaxis.Style{ .bg = Color.visual_select_bg };
            for (0..win.width) |col| {
                win.writeCell(@intCast(col), @intCast(row), .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = visual_style,
                });
            }
        } else if (is_cursor_line and !in_visual_mode) {
            // Cursor line highlighting in history mode - only when NOT in visual mode
            // (in visual mode, the visual selection bg handles the cursor line too)
            const cursor_style = vaxis.Style{ .bg = Color.cursor_bg };
            for (0..win.width) |col| {
                win.writeCell(@intCast(col), @intCast(row), .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = cursor_style,
                });
            }
        }

        // Handle unified diff lines - render gutter at render time
        if (record.diff_kind) |kind| {
            // Format: "┃ NNN+ " where NNN is line number, + is sign
            const gutter_style: vaxis.Style = switch (kind) {
                .context => .{ .fg = Color.dim },
                .add => .{ .fg = Color.diff_sign_add, .bg = Color.diff_add_bg },
                .delete => .{ .fg = Color.diff_sign_delete, .bg = Color.diff_delete_bg },
            };

            // Print sidebar "┃ "
            var sidebar_seg = [_]vaxis.Cell.Segment{
                .{ .text = "┃ ", .style = .{ .fg = Color.dim } },
            };
            _ = win.print(&sidebar_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            col_offset += 2;

            // Print line number (use pre-formatted string to avoid buffer reuse issues)
            const num_text = record.diff_line_num_str orelse "   ";
            var num_seg = [_]vaxis.Cell.Segment{
                .{ .text = num_text, .style = gutter_style },
            };
            _ = win.print(&num_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            col_offset += 3;

            // Print sign (use static string to avoid buffer reuse issues)
            const sign_text: []const u8 = if (record.diff_sign) |sign| switch (sign) {
                '+' => "+",
                '-' => "-",
                else => " ",
            } else " ";
            var sign_seg = [_]vaxis.Cell.Segment{
                .{ .text = sign_text, .style = gutter_style },
            };
            _ = win.print(&sign_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            col_offset += 1;

            // Space after sign
            col_offset += 1;

            // Print content with syntax highlighting
            // Apply cursor/visual highlight to the style so text shows the highlight background
            const content_style = withHighlightBg(record.style, is_cursor_line, is_in_visual);
            printWithHighlights(win, record.text, record.diff_highlights, content_style, row, col_offset);

            row += 1;
            continue; // Skip normal text rendering for unified diff lines
        } else if (record.sbs_left_kind) |left_kind| {
            // Handle side-by-side diff lines
            const right_kind = record.sbs_right_kind orelse .empty;
            const left_width = record.sbs_left_width;

            // Left gutter style
            const left_gutter_style: vaxis.Style = switch (left_kind) {
                .context, .empty => .{ .fg = Color.dim },
                .delete => .{ .fg = Color.diff_sign_delete },
                .add => .{ .fg = Color.diff_sign_add },
            };

            // Right gutter style
            const right_gutter_style: vaxis.Style = switch (right_kind) {
                .context, .empty => .{ .fg = Color.dim },
                .delete => .{ .fg = Color.diff_sign_delete },
                .add => .{ .fg = Color.diff_sign_add },
            };

            // Left side: "┃ NNN  content"
            var sidebar_seg = [_]vaxis.Cell.Segment{
                .{ .text = "┃ ", .style = .{ .fg = Color.dim } },
            };
            _ = win.print(&sidebar_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            col_offset += 2;

            // Left line number (use pre-formatted string to avoid buffer reuse issues)
            const left_num_text = record.sbs_left_num_str orelse "   ";
            var left_num_seg = [_]vaxis.Cell.Segment{
                .{ .text = left_num_text, .style = left_gutter_style },
            };
            _ = win.print(&left_num_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            col_offset += 3;

            // Space after line number
            col_offset += 2;

            // Left content with syntax highlighting (truncate to width) or diagonal fill for empty
            if (left_kind == .empty) {
                // Fill with diagonal pattern for empty left side
                renderDiagonalFill(win, row, col_offset, left_width, is_cursor_line);
            } else {
                // Fill entire left content area with diff background first
                if (left_kind == .delete) {
                    const fill_style: vaxis.Style = if (is_cursor_line)
                        .{ .bg = Color.cursor_bg }
                    else if (is_in_visual)
                        .{ .bg = Color.visual_select_bg }
                    else
                        .{ .bg = Color.diff_delete_bg };
                    for (0..left_width) |i| {
                        win.writeCell(@intCast(col_offset + i), @intCast(row), .{
                            .char = .{ .grapheme = " ", .width = 1 },
                            .style = fill_style,
                        });
                    }
                }
                // Then render the text content on top
                if (record.sbs_left_content) |content| {
                    const left_content = if (content.len > left_width) content[0..left_width] else content;
                    const base_left_style: vaxis.Style = if (left_kind == .delete)
                        .{ .fg = Color.white, .bg = Color.diff_delete_bg }
                    else
                        .{ .fg = Color.white };
                    // Apply cursor/visual highlight to the style
                    const left_style = withHighlightBg(base_left_style, is_cursor_line, is_in_visual);
                    printWithHighlights(win, left_content, record.sbs_left_highlights, left_style, row, col_offset);
                }
            }
            col_offset += left_width;

            // Divider
            var div_seg = [_]vaxis.Cell.Segment{
                .{ .text = "│", .style = .{ .fg = Color.dim } },
            };
            _ = win.print(&div_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            col_offset += 1;

            // Right line number (use pre-formatted string to avoid buffer reuse issues)
            const right_num_text = record.sbs_right_num_str orelse "   ";
            var right_num_seg = [_]vaxis.Cell.Segment{
                .{ .text = right_num_text, .style = right_gutter_style },
            };
            _ = win.print(&right_num_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            col_offset += 3;

            // Space after line number
            col_offset += 2;

            // Right content with syntax highlighting (or diagonal fill for empty)
            if (right_kind == .empty) {
                // Fill with diagonal pattern for empty right side
                renderDiagonalFill(win, row, col_offset, left_width, is_cursor_line);
            } else {
                // Fill entire right content area with diff background first
                if (right_kind == .add) {
                    const fill_style: vaxis.Style = if (is_cursor_line)
                        .{ .bg = Color.cursor_bg }
                    else if (is_in_visual)
                        .{ .bg = Color.visual_select_bg }
                    else
                        .{ .bg = Color.diff_add_bg };
                    for (0..left_width) |i| {
                        win.writeCell(@intCast(col_offset + i), @intCast(row), .{
                            .char = .{ .grapheme = " ", .width = 1 },
                            .style = fill_style,
                        });
                    }
                }
                // Then render the text content on top
                if (record.sbs_right_content) |content| {
                    const base_right_style: vaxis.Style = if (right_kind == .add)
                        .{ .fg = Color.white, .bg = Color.diff_add_bg }
                    else
                        .{ .fg = Color.white };
                    // Apply cursor/visual highlight to the style
                    const right_style = withHighlightBg(base_right_style, is_cursor_line, is_in_visual);
                    printWithHighlights(win, content, record.sbs_right_highlights, right_style, row, col_offset);
                }
            }

            row += 1;
            continue; // Skip normal text rendering for sbs lines
        }

        // Render left bar for user and thinking messages (comment-style)
        // Agent messages and tools use no bar for a cleaner, more conversational look
        switch (record.line_type) {
            .message_content => {
                // Draw bar for user and thinking messages
                const messages = agent_state.messages.items;
                const msg_idx = record.line_type.message_content.msg_idx;
                if (msg_idx < messages.len) {
                    const msg = messages[msg_idx];
                    if (msg.role == .user) {
                        const bar_style = withHighlightBg(.{ .fg = Color.chat_user, .bg = Color.comment_bg }, is_cursor_line, is_in_visual);

                        var bar_seg = [_]vaxis.Cell.Segment{
                            .{ .text = "┃ ", .style = bar_style },
                        };
                        _ = win.print(&bar_seg, .{ .row_offset = @intCast(row), .col_offset = 0 });
                    } else if (msg.role == .thinking) {
                        const bar_style = withHighlightBg(.{ .fg = Color.dim }, is_cursor_line, is_in_visual);

                        var bar_seg = [_]vaxis.Cell.Segment{
                            .{ .text = "┃ ", .style = bar_style },
                        };
                        _ = win.print(&bar_seg, .{ .row_offset = @intCast(row), .col_offset = 0 });
                    }
                }
            },
            .role_header => {
                // Draw bar for user and thinking messages
                const messages = agent_state.messages.items;
                const msg_idx = record.line_type.role_header.msg_idx;
                if (msg_idx < messages.len) {
                    const msg = messages[msg_idx];
                    if (msg.role == .user) {
                        const bar_style = withHighlightBg(.{ .fg = Color.chat_user, .bg = Color.comment_bg }, is_cursor_line, is_in_visual);

                        var bar_seg = [_]vaxis.Cell.Segment{
                            .{ .text = "┃ ", .style = bar_style },
                        };
                        _ = win.print(&bar_seg, .{ .row_offset = @intCast(row), .col_offset = 0 });
                    } else if (msg.role == .thinking) {
                        const bar_style = withHighlightBg(.{ .fg = Color.dim }, is_cursor_line, is_in_visual);

                        var bar_seg = [_]vaxis.Cell.Segment{
                            .{ .text = "┃ ", .style = bar_style },
                        };
                        _ = win.print(&bar_seg, .{ .row_offset = @intCast(row), .col_offset = 0 });
                    }
                }
            },
            .diff_header, .diff_hunk_header => {
                // Draw bar for diff headers
                var bar_seg = [_]vaxis.Cell.Segment{
                    .{ .text = "┃ ", .style = withHighlightBg(.{ .fg = Color.white }, is_cursor_line, is_in_visual) },
                };
                _ = win.print(&bar_seg, .{ .row_offset = @intCast(row), .col_offset = 0 });
            },
            // No bar for tools - they use minimal icon-based design
            else => {},
        }

        // Print regular prefix if present
        if (record.prefix) |prefix| {
            const prefix_style = withHighlightBg(record.prefix_style orelse record.style, is_cursor_line, is_in_visual);
            var prefix_seg = [_]vaxis.Cell.Segment{
                .{ .text = prefix, .style = prefix_style },
            };
            _ = win.print(&prefix_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });
            col_offset += prefix.len;
        }

        // Print text - special handling for tool headers and agent messages
        switch (record.line_type) {
            .message_content => |mc| {
                // Check if we have pre-computed styled segments
                if (record.segments) |segments| {
                    // Render each segment with its own style
                    var col: usize = col_offset;
                    for (segments) |seg| {
                        const seg_style = withHighlightBg(seg.style, is_cursor_line, is_in_visual);
                        const result = safePrint(win, seg.text, seg_style, row, col);
                        col = result.col; // result.col is the final column position
                    }
                } else {
                    // Fall back to traditional rendering
                    const messages = agent_state.messages.items;
                    if (mc.msg_idx < messages.len) {
                        const msg = &messages[mc.msg_idx];
                        // For agent messages, try to render with markdown styling
                        if (msg.role == .agent and record.text.len > 0) {
                            renderTextWithMarkdown(win, record.text, msg, record.style, is_cursor_line, is_in_visual, row, col_offset);
                        } else {
                            // Non-agent messages or empty text - use plain rendering
                            _ = safePrint(win, record.text, withHighlightBg(record.style, is_cursor_line, is_in_visual), row, col_offset);
                        }
                    } else {
                        _ = safePrint(win, record.text, withHighlightBg(record.style, is_cursor_line, is_in_visual), row, col_offset);
                    }
                }
            },
            .tool_header => |th| {
                // Get icon color from message status
                const messages = agent_state.messages.items;
                const icon_color: vaxis.Color = if (th.msg_idx < messages.len) blk: {
                    const msg = messages[th.msg_idx];
                    break :blk switch (msg.tool_status) {
                        .pending => Color.yellow,
                        .running => Color.cyan,
                        .completed => Color.green,
                        .failed => Color.red,
                    };
                } else Color.white;

                // Find first space to split icon from rest
                if (std.mem.indexOf(u8, record.text, " ")) |space_idx| {
                    const icon = record.text[0..space_idx];
                    // Skip the space - we'll add it explicitly to avoid width calculation issues
                    const rest = if (space_idx + 1 < record.text.len) record.text[space_idx + 1 ..] else "";

                    // Print icon with color (with UTF-8 validation)
                    _ = safePrint(win, icon, withHighlightBg(.{ .fg = icon_color }, is_cursor_line, is_in_visual), row, col_offset);

                    // Use fixed width of 1 for the icon (all status icons are single-width)
                    // Then print space and rest with default style
                    _ = safePrint(win, " ", withHighlightBg(record.style, is_cursor_line, is_in_visual), row, col_offset + 1);
                    _ = safePrint(win, rest, withHighlightBg(record.style, is_cursor_line, is_in_visual), row, col_offset + 2);
                } else {
                    // No space found, print normally (with UTF-8 validation)
                    _ = safePrint(win, record.text, withHighlightBg(record.style, is_cursor_line, is_in_visual), row, col_offset);
                }
            },
            else => {
                // Print with UTF-8 validation to prevent grapheme iterator crash
                _ = safePrint(win, record.text, withHighlightBg(record.style, is_cursor_line, is_in_visual), row, col_offset);
            },
        }
        row += 1;
    }

    // Render scrollbar if content is scrollable
    if (total_lines > win.height) {
        const scrollbar_info = calculateScrollbar(win.height, total_lines, scroll);
        renderScrollbar(win, scrollbar_info);
    }

    // Render "more below" indicator when not following and there's content below
    if (!agent_state.follow_bottom and scroll < max_scroll) {
        const indicator = " ↓ more ";
        const indicator_style = vaxis.Style{
            .fg = Color.black,
            .bg = Color.yellow,
            .bold = true,
        };
        // Position at bottom-right, leaving room for scrollbar
        const indicator_len = indicator.len;
        const col = if (win.width > indicator_len + 2) win.width - indicator_len - 2 else 0;
        const last_row = if (win.height > 0) win.height - 1 else 0;
        var seg = [_]vaxis.Cell.Segment{
            .{ .text = indicator, .style = indicator_style },
        };
        _ = win.print(&seg, .{ .row_offset = @intCast(last_row), .col_offset = @intCast(col) });
    }
}

/// Render the status area shown between messages and plan when agent is thinking or waiting
/// Layout: empty row + status message (with inline hint) + empty row + optional queued message
fn renderStatusArea(win: vaxis.Window, agent_state: *AgentState, is_thinking: bool, show_interrupt_hint: bool) void {
    if (win.height == 0) return;

    const blank_cell = vaxis.Cell{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{},
    };
    win.fill(blank_cell);

    var row: usize = 0;

    // Row 0: empty padding
    row += 1;

    // Row 1: Status indicator with shimmer + inline interrupt hint
    if (row < win.height) {
        // Count only user messages for stable turn seed (agent messages change during streaming)
        var user_msg_count: usize = 0;
        for (agent_state.messages.items) |msg| {
            if (msg.role == .user) user_msg_count += 1;
        }
        renderThinkingIndicator(win, row, is_thinking, user_msg_count);

        // Add inline interrupt hint after the thinking indicator (when in normal mode)
        if (show_interrupt_hint) {
            // Position hint after the thinking message (max ~14 chars) + spacing
            const hint_col: usize = 16; // "Generating..." is 13 chars + some padding
            const pending_esc = agent_state.isPendingEsc();
            const has_queued = agent_state.hasStagedPrompt();

            // Show different hint based on whether first ESC was pressed
            const hint_text = if (pending_esc)
                if (has_queued) "(press esc again to interrupt and send queued)" else "(press esc again to interrupt)"
            else if (has_queued)
                "(esc to interrupt and send queued)"
            else
                "(esc to interrupt)";

            const hint_style = if (pending_esc)
                vaxis.Style{ .fg = Color.yellow, .bold = true }
            else
                vaxis.Style{ .fg = Color.dim_gray };

            var hint_seg = [_]vaxis.Cell.Segment{
                .{ .text = hint_text, .style = hint_style },
            };
            _ = win.print(&hint_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(hint_col) });
        }
        row += 1;
    }

    // Row 2: empty padding
    row += 1;

    // Rows 3+: Queued message preview (if present)
    if (agent_state.hasStagedPrompt() and row < win.height) {
        const staged_text = agent_state.getStagedPrompt();
        const is_shell = agent_state.isStagedShellCommand();
        renderStagedMessagePreview(win, staged_text, row, is_shell);
    }
}

/// Render a preview of the staged message (up to 3 lines)
/// Uses the same visual style as user messages (with bar and background)
fn renderStagedMessagePreview(win: vaxis.Window, text: []const u8, start_row: usize, is_shell: bool) void {
    if (text.len == 0 or start_row >= win.height) return;

    const max_preview_lines: usize = 3;
    // Use different colors for shell commands (green) vs regular messages (cyan/user color)
    const bar_color = if (is_shell) Color.green else Color.chat_user;
    const bar_style = vaxis.Style{ .fg = bar_color, .bg = Color.comment_bg };
    const text_style = vaxis.Style{ .fg = Color.white, .bg = Color.comment_bg };
    const label_style = vaxis.Style{ .fg = bar_color, .bg = Color.comment_bg, .bold = true };

    var row: usize = start_row;

    // Show label with bar (different text for shell commands)
    const label_text = if (is_shell) "Queued $:" else "Queued:";

    // Fill background for this row
    for (0..win.width) |col| {
        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{ .bg = Color.comment_bg },
        });
    }
    // Draw bar
    var bar_seg = [_]vaxis.Cell.Segment{
        .{ .text = "┃ ", .style = bar_style },
    };
    _ = win.print(&bar_seg, .{ .row_offset = @intCast(row), .col_offset = 0 });
    // Draw label
    var label_seg = [_]vaxis.Cell.Segment{
        .{ .text = label_text, .style = label_style },
    };
    _ = win.print(&label_seg, .{ .row_offset = @intCast(row), .col_offset = 2 });
    row += 1;

    // Extract up to 3 lines from staged text
    var line_iter = std.mem.splitScalar(u8, text, '\n');
    var lines_shown: usize = 0;

    while (line_iter.next()) |line| {
        if (lines_shown >= max_preview_lines or row >= win.height) break;

        // Fill background for this row
        for (0..win.width) |col| {
            win.writeCell(@intCast(col), @intCast(row), .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = .{ .bg = Color.comment_bg },
            });
        }

        // Draw bar
        var line_bar_seg = [_]vaxis.Cell.Segment{
            .{ .text = "┃ ", .style = bar_style },
        };
        _ = win.print(&line_bar_seg, .{ .row_offset = @intCast(row), .col_offset = 0 });

        // Truncate line to fit window width (leave room for "┃ " prefix)
        const max_line_len = if (win.width > 4) win.width - 4 else 1;
        const display_line = if (line.len > max_line_len) line[0..max_line_len] else line;

        // Print line content
        var line_seg = [_]vaxis.Cell.Segment{
            .{ .text = display_line, .style = text_style },
        };
        _ = win.print(&line_seg, .{ .row_offset = @intCast(row), .col_offset = 2 });

        row += 1;
        lines_shown += 1;
    }

    // If there are more lines, show "..." with same style
    if (line_iter.next() != null and row < win.height) {
        // Fill background
        for (0..win.width) |col| {
            win.writeCell(@intCast(col), @intCast(row), .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = .{ .bg = Color.comment_bg },
            });
        }
        // Draw bar and ellipsis
        var more_bar_seg = [_]vaxis.Cell.Segment{
            .{ .text = "┃ ", .style = bar_style },
        };
        _ = win.print(&more_bar_seg, .{ .row_offset = @intCast(row), .col_offset = 0 });
        var more_seg = [_]vaxis.Cell.Segment{
            .{ .text = "...", .style = text_style },
        };
        _ = win.print(&more_seg, .{ .row_offset = @intCast(row), .col_offset = 2 });
        row += 1;
    }

    // Add trailing empty line with background (matches chat message style)
    if (row < win.height) {
        // fill background
        for (0..win.width) |col| {
            win.writeCell(@intCast(col), @intCast(row), .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = .{ .bg = Color.comment_bg },
            });
        }

        var final_bar_seg = [_]vaxis.Cell.Segment{
            .{ .text = "┃ ", .style = bar_style },
        };

        _ = win.print(&final_bar_seg, .{ .row_offset = @intCast(row), .col_offset = 0 });
    }
}

/// Messages to show while agent is thinking (one per turn)
const thinking_messages = [_][]const u8{
    "Thinking...",
    "Generating...",
    "Working...",
    "Processing...",
    "Grinding...",
    "Cranking...",
    "Crunching...",
    "Computing...",
    "Pondering...",
    "Brewing...",
    "Cooking...",
    "Churning...",
};

/// Messages to show while waiting for session (one per attempt)
const waiting_messages = [_][]const u8{
    "Connecting...",
    "Starting...",
    "Warming up...",
    "Booting...",
};

/// Render a shimmering status indicator (message selected per turn for thinking, time-based for waiting)
fn renderThinkingIndicator(win: vaxis.Window, row: usize, is_thinking: bool, turn_seed: usize) void {
    if (win.width < 20 or row >= win.height) return;

    const now = std.time.milliTimestamp();

    // Select message: per-turn for thinking, time-based cycling for waiting
    const text = if (is_thinking) blk: {
        const idx = turn_seed % thinking_messages.len;
        break :blk thinking_messages[idx];
    } else blk: {
        // Cycle waiting messages every 1.5 seconds to show activity
        const idx: usize = @intCast(@mod(@divFloor(now, 1500), waiting_messages.len));
        break :blk waiting_messages[idx];
    };

    // Shimmer effect (time-based animation)
    const shimmer_speed: i64 = 80;
    const phase: usize = @intCast(@mod(@divFloor(now, shimmer_speed), 10));

    var col: usize = 1;
    for (text, 0..) |_, idx| {
        if (col >= win.width) break;

        // Wave of brightness that travels across the text
        const pos_offset = (idx + phase) % 10;
        const brightness: u8 = switch (pos_offset) {
            0 => 255,
            1 => 230,
            2 => 190,
            3 => 150,
            4, 5 => 120,
            6 => 150,
            7 => 190,
            8 => 230,
            9 => 255,
            else => 120,
        };

        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = text[idx .. idx + 1], .width = 1 },
            .style = .{ .fg = .{ .rgb = .{ brightness, brightness, brightness } } },
        });
        col += 1;
    }
}

// =============================================================================
// Slash Command Menu
// =============================================================================

/// Render the slash command menu as a popup above the input area
fn renderSlashMenu(win: vaxis.Window, agent_state: *AgentState, input_top: usize) !void {
    // Get filtered commands
    var indices: [32]usize = undefined;
    const filtered_count = agent_state.getFilteredCommandIndices(&indices);

    if (filtered_count == 0) return;

    // Calculate menu dimensions with scroll support
    const visible_count = @min(filtered_count, MAX_SLASH_MENU_VISIBLE);
    const max_scroll = if (filtered_count > visible_count) filtered_count - visible_count else 0;
    const scroll_offset = @min(agent_state.slash_menu.scroll_offset, max_scroll);
    const menu_height = visible_count + 1; // title row + items
    const menu_width = @min(SLASH_MENU_WIDTH, win.width -| 4); // fixed width, capped to window

    // Position menu just above the input area (bottom-anchored)
    const menu_y = if (input_top > menu_height) input_top - menu_height else 0;
    const menu_x: usize = 2; // Small left margin

    // Create menu window - no pre-clearing needed since each frame re-renders
    // the underlying content, and we fill the menu area with dialog_bg
    const menu_win = win.child(.{
        .x_off = @intCast(menu_x),
        .y_off = @intCast(menu_y),
        .width = @intCast(menu_width),
        .height = @intCast(menu_height),
    });

    // Fill background with dialog color
    const bg_cell = vaxis.Cell{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .bg = Color.dialog_bg },
    };
    menu_win.fill(bg_cell);

    // Row 0: Title with scroll indicators
    const has_more_above = scroll_offset > 0;
    const has_more_below = scroll_offset + visible_count < filtered_count;
    const title_style = vaxis.Style{ .fg = Color.cyan, .bg = Color.dialog_bg, .bold = true };
    const indicator_style = vaxis.Style{ .fg = Color.dim_gray, .bg = Color.dialog_bg };

    var title_seg = [_]vaxis.Cell.Segment{
        .{ .text = "Commands", .style = title_style },
    };
    _ = menu_win.print(&title_seg, .{ .row_offset = 0, .col_offset = MENU_PADDING });

    // Show scroll indicators on the right (inside padding)
    if (has_more_above) {
        var up_seg = [_]vaxis.Cell.Segment{.{ .text = "▲", .style = indicator_style }};
        _ = menu_win.print(&up_seg, .{ .row_offset = 0, .col_offset = @intCast(menu_width -| 4) });
    }
    if (has_more_below) {
        var down_seg = [_]vaxis.Cell.Segment{.{ .text = "▼", .style = indicator_style }};
        _ = menu_win.print(&down_seg, .{ .row_offset = 0, .col_offset = @intCast(menu_width -| 2) });
    }

    // Clamp selection to valid range
    const selection = @min(agent_state.slash_menu.selection, filtered_count - 1);

    // Render command items (with scroll offset applied)
    for (0..visible_count) |i| {
        const item_idx = scroll_offset + i;
        if (item_idx >= filtered_count) break;

        const cmd_idx = indices[item_idx];
        const cmd = &agent_state.available_commands.items[cmd_idx];
        const is_selected = (item_idx == selection);
        const row = i + 1; // title row + item index

        // Style based on selection (neutral colors)
        const name_style: vaxis.Style = if (is_selected)
            .{ .fg = Color.black, .bg = Color.white, .bold = true }
        else
            .{ .fg = Color.white, .bg = Color.dialog_bg, .bold = true };

        const desc_style: vaxis.Style = if (is_selected)
            .{ .fg = Color.black, .bg = Color.white }
        else
            .{ .fg = Color.dim_gray, .bg = Color.dialog_bg };

        // Fill row background if selected
        if (is_selected) {
            for (0..menu_width) |col| {
                menu_win.writeCell(@intCast(col), @intCast(row), .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = .{ .bg = Color.white },
                });
            }
        }

        // Format: " /command  description"
        var col: usize = MENU_PADDING;

        // Print "/" prefix
        var slash_seg = [_]vaxis.Cell.Segment{
            .{ .text = "/", .style = name_style },
        };
        _ = menu_win.print(&slash_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
        col += 1;

        // Print command name (truncate if needed)
        const max_name_len = @min(cmd.name.len, 20);
        const name_text = cmd.name[0..max_name_len];
        var name_seg = [_]vaxis.Cell.Segment{
            .{ .text = name_text, .style = name_style },
        };
        _ = menu_win.print(&name_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
        col += max_name_len + 2; // +2 for spacing

        // Print description (truncate to fit, accounting for right padding)
        const remaining_width = if (menu_width > col + MENU_PADDING) menu_width - col - MENU_PADDING else 0;
        if (remaining_width > 0 and cmd.description.len > 0) {
            const desc_len = @min(cmd.description.len, remaining_width);
            const desc_text = cmd.description[0..desc_len];
            var desc_seg = [_]vaxis.Cell.Segment{
                .{ .text = desc_text, .style = desc_style },
            };
            _ = menu_win.print(&desc_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
        }
    }
}

/// Render file picker menu overlay
fn renderFilePicker(win: vaxis.Window, agent_state: *AgentState, input_top: usize) !void {
    const filtered_count = agent_state.file_picker.getFilteredCount();

    if (filtered_count == 0) return;

    // Calculate menu dimensions with scroll support
    const visible_count = @min(filtered_count, state.MAX_FILE_MENU_VISIBLE);
    const max_scroll = if (filtered_count > visible_count) filtered_count - visible_count else 0;
    const scroll_offset = @min(agent_state.file_picker.scroll_offset, max_scroll);
    const menu_height = visible_count + 1; // title row only, no vertical padding
    const menu_width = @min(FILE_PICKER_WIDTH, win.width -| 4); // fixed width, capped to window

    // Position menu just above the input area (bottom-anchored)
    const menu_y = if (input_top > menu_height) input_top - menu_height else 0;
    const menu_x: usize = 2; // Small left margin

    // Create menu window - no pre-clearing needed since each frame re-renders
    // the underlying content, and we fill the menu area with dialog_bg
    const menu_win = win.child(.{
        .x_off = @intCast(menu_x),
        .y_off = @intCast(menu_y),
        .width = @intCast(menu_width),
        .height = @intCast(menu_height),
    });

    // Fill background with dialog color
    const bg_cell = vaxis.Cell{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .bg = Color.dialog_bg },
    };
    menu_win.fill(bg_cell);

    // Row 0: Title with scroll indicators
    const has_more_above = scroll_offset > 0;
    const has_more_below = scroll_offset + visible_count < filtered_count;
    const title_style = vaxis.Style{ .fg = Color.cyan, .bg = Color.dialog_bg, .bold = true };
    const indicator_style = vaxis.Style{ .fg = Color.dim_gray, .bg = Color.dialog_bg };

    var title_seg = [_]vaxis.Cell.Segment{
        .{ .text = "Files", .style = title_style },
    };
    _ = menu_win.print(&title_seg, .{ .row_offset = 0, .col_offset = MENU_PADDING });

    // Show scroll indicators on the right (inside padding)
    if (has_more_above) {
        var up_seg = [_]vaxis.Cell.Segment{.{ .text = "▲", .style = indicator_style }};
        _ = menu_win.print(&up_seg, .{ .row_offset = 0, .col_offset = @intCast(menu_width -| 4) });
    }
    if (has_more_below) {
        var down_seg = [_]vaxis.Cell.Segment{.{ .text = "▼", .style = indicator_style }};
        _ = menu_win.print(&down_seg, .{ .row_offset = 0, .col_offset = @intCast(menu_width -| 2) });
    }

    // Clamp selection to valid range
    const selection = @min(agent_state.file_picker.selection, filtered_count - 1);

    // Render file items (with scroll offset applied)
    for (0..visible_count) |i| {
        const item_idx = scroll_offset + i;
        if (item_idx >= filtered_count) break;

        const file_idx = agent_state.file_picker.filtered_indices.items[item_idx];
        const file_path = agent_state.file_picker.files.items[file_idx];
        const is_selected = (item_idx == selection);
        const row = i + 1; // title row + item index

        // Style based on selection
        const path_style: vaxis.Style = if (is_selected)
            .{ .fg = Color.black, .bg = Color.white, .bold = true }
        else
            .{ .fg = Color.white, .bg = Color.dialog_bg };

        // Fill row background if selected
        if (is_selected) {
            for (0..menu_width) |col| {
                menu_win.writeCell(@intCast(col), @intCast(row), .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = .{ .bg = Color.white },
                });
            }
        }

        // Print file path with @ prefix
        var col: usize = MENU_PADDING;

        // Print "@" prefix
        var at_seg = [_]vaxis.Cell.Segment{
            .{ .text = "@", .style = path_style },
        };
        _ = menu_win.print(&at_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
        col += 1;

        // Print file path (truncate if needed, accounting for right padding)
        const max_path_len = if (menu_width > col + MENU_PADDING) menu_width - col - MENU_PADDING else 1;
        const path_len = @min(file_path.len, max_path_len);
        const path_text = file_path[0..path_len];
        var path_seg = [_]vaxis.Cell.Segment{
            .{ .text = path_text, .style = path_style },
        };
        _ = menu_win.print(&path_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
    }
}

fn renderInputArea(app: *App, win: vaxis.Window, agent_state: *AgentState, is_focused: bool, pending_permission: ?*AcpManager.PendingPermission) !void {
    if (win.height == 0) return;

    // Fill the entire input area with spaces to prevent artifacts from previous renders
    // (e.g., permission dialogs leaving remnants when dismissed)
    // Using fill() instead of clear() for more robust clearing
    const blank_cell = vaxis.Cell{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{},
    };
    win.fill(blank_cell);

    // Note: model_selection mode is now rendered as a centered dialog overlay in renderAgentPanel

    // Check if there's a pending permission - render inline permission prompt instead
    if (pending_permission) |perm| {
        try renderInlinePermissionPrompt(win, perm);
        return;
    }

    const text = agent_state.input.getText();
    const input_col: usize = 3; // After "> " or "  "

    // Calculate how many display lines we'll have with wrapping
    // We need to do this before rendering to know the input area height
    // Account for: prompt/continuation (3 chars) + scrollbar (1 char when visible) + margin (1 char)
    const max_input_width_for_calc = if (win.width > input_col + 2) win.width - input_col - 2 else 1;
    var total_display_lines: usize = 0;
    var line_iter_calc = std.mem.splitScalar(u8, text, '\n');
    while (line_iter_calc.next()) |text_line| {
        if (text_line.len == 0) {
            total_display_lines += 1; // Empty line still takes one display line
        } else {
            // Calculate how many chunks this line wraps into
            const chunks = (text_line.len + max_input_width_for_calc - 1) / max_input_width_for_calc;
            total_display_lines += chunks;
        }
    }
    if (total_display_lines == 0) total_display_lines = 1; // Always show at least one line

    const visible_lines = @min(total_display_lines, MAX_INPUT_LINES);

    // Calculate cursor's actual display row (accounting for wrapping)
    const cursor_pos = agent_state.input.vim.cursor_pos;
    var cursor_display_row: usize = 0;
    var pos: usize = 0;
    var line_iter_cursor = std.mem.splitScalar(u8, text, '\n');
    while (line_iter_cursor.next()) |text_line| {
        const line_start = pos;
        const line_end = pos + text_line.len;

        if (cursor_pos >= line_start and cursor_pos <= line_end) {
            // Cursor is on this logical line, calculate wrapped row
            const offset_in_line = cursor_pos - line_start;
            const wrapped_rows_before = offset_in_line / max_input_width_for_calc;
            cursor_display_row += wrapped_rows_before;
            break;
        }

        // Count wrapped rows for this line
        if (text_line.len == 0) {
            cursor_display_row += 1;
        } else {
            const chunks = (text_line.len + max_input_width_for_calc - 1) / max_input_width_for_calc;
            cursor_display_row += chunks;
        }

        pos = line_end + 1; // +1 for newline
    }

    // Calculate scroll offset to keep cursor in view
    var scroll_offset = agent_state.input_scroll_offset;

    // Scroll up if cursor is above visible area
    if (cursor_display_row < scroll_offset) {
        scroll_offset = cursor_display_row;
    }
    // Scroll down if cursor is below visible area
    if (cursor_display_row >= scroll_offset + visible_lines) {
        scroll_offset = cursor_display_row - visible_lines + 1;
    }
    // Clamp scroll offset to valid range
    const max_scroll = if (total_display_lines > visible_lines) total_display_lines - visible_lines else 0;
    scroll_offset = @min(scroll_offset, max_scroll);

    // Update stored scroll offset
    agent_state.input_scroll_offset = scroll_offset;

    // Layout:
    // Row 0: Separator line
    // Rows 1..: Input lines with "> " prompt on first line
    // Last row: Footer with mode (left) and keybindings (right)

    // Separator line
    const separator_style = vaxis.Style{ .fg = Color.dim_gray };
    for (0..win.width) |col| {
        win.writeCell(@intCast(col), 0, .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = separator_style,
        });
    }

    // Check if we're in shell command mode (using shell_mode flag)
    const is_shell_mode = agent_state.isShellMode();

    // Dim prompt when session is not ready
    const session_ready = app.isSessionReady();
    const prompt_style = if (is_shell_mode)
        vaxis.Style{ .fg = Color.yellow, .bold = true }
    else if (session_ready)
        vaxis.Style{ .fg = Color.magenta, .bold = true }
    else
        vaxis.Style{ .fg = Color.dim_gray };
    const text_style = vaxis.Style{ .fg = Color.white };
    const file_ref_style = vaxis.Style{ .fg = Color.cyan, .bold = true };

    // Find file reference ranges for highlighting
    const file_ref_ranges = findFileRefRanges(app.allocator, text) catch &[_]FileRefRange{};
    defer if (file_ref_ranges.len > 0) app.allocator.free(file_ref_ranges);
    const has_file_refs = file_ref_ranges.len > 0;
    // Use the same max_input_width as calculated earlier for consistency
    const max_input_width = max_input_width_for_calc;
    // Content starts after separator
    const content_start_row: usize = 1;

    // Split text by newlines and wrap each line
    var line_iter = std.mem.splitScalar(u8, text, '\n');
    var display_row: usize = 0; // Physical display row (including wrapping)
    var visible_row: usize = 0; // Row within the visible window
    var char_offset: usize = 0; // Track absolute position in buffer
    var is_first_line = true;

    var line_num: usize = 0;
    while (line_iter.next()) |text_line| {
        // Stop if we've filled the visible area
        if (visible_row >= visible_lines) break;

        // For lines after the first, account for the newline character before processing the line
        // (splitScalar doesn't include the delimiter, so we need to manually track it)
        if (line_num > 0) {
            char_offset += 1; // Account for '\n' that ended previous line
        }
        line_num += 1;

        // Use word-aware wrapping for this line
        var wrapped_lines = try RenderUtils.wrapText(app.allocator, text_line, max_input_width);
        defer wrapped_lines.deinit(app.allocator);

        // Track offset within the original line for cursor positioning
        var segment_offset: usize = 0;

        for (wrapped_lines.items) |wrapped_segment| {
            // Stop if we've filled the visible area
            if (visible_row >= visible_lines) break;

            const chunk = wrapped_segment;
            const chunk_len = chunk.len;

            // Skip rows that are scrolled out of view
            if (display_row >= scroll_offset) {
                const row = visible_row + content_start_row;

                // First line gets the prompt ("> " for normal, "$ " for shell mode), others get "  " for alignment
                if (is_first_line) {
                    const prompt_char = if (is_shell_mode) "$ " else "> ";
                    var prompt_seg = [_]vaxis.Cell.Segment{
                        .{ .text = prompt_char, .style = prompt_style },
                    };
                    _ = win.print(&prompt_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });
                    is_first_line = false;
                } else {
                    var cont_seg = [_]vaxis.Cell.Segment{
                        .{ .text = "  ", .style = text_style },
                    };
                    _ = win.print(&cont_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });
                }
            } else {
                // Still need to track is_first_line even for scrolled rows
                if (is_first_line) is_first_line = false;
            }

            // Determine segment start and end positions in the full buffer
            const segment_start = char_offset + segment_offset;
            const segment_end = segment_start + chunk_len;

            // Only render if in visible area
            if (display_row >= scroll_offset) {
                const row = visible_row + content_start_row;

                // Check for visual mode selection highlighting or file references
                const vim_mode = agent_state.input.vim.vim_mode;
                const visual_anchor = agent_state.input.vim.visual_anchor;
                const in_visual_mode = vim_mode == .visual and visual_anchor != null;

                if (in_visual_mode or has_file_refs) {
                    // Character-by-character rendering for visual selection or file refs
                    const anchor = if (in_visual_mode) visual_anchor.? else 0;
                    const cursor = agent_state.input.vim.cursor_pos;
                    const sel_start = if (in_visual_mode) @min(anchor, cursor) else 0;
                    const sel_end = if (in_visual_mode) @max(anchor, cursor) else 0;

                    // Visual selection style
                    const visual_style = vaxis.Style{
                        .fg = Color.black,
                        .bg = Color.cyan,
                        .bold = true,
                    };

                    // Render each character with appropriate style (UTF-8 aware)
                    var byte_idx: usize = 0;
                    var display_col: usize = input_col;
                    while (byte_idx < chunk.len) {
                        if (display_col >= win.width) break;

                        // Get UTF-8 sequence length for this character
                        const seq_len = std.unicode.utf8ByteSequenceLength(chunk[byte_idx]) catch 1;
                        const char_end = @min(byte_idx + seq_len, chunk.len);
                        const grapheme = chunk[byte_idx..char_end];

                        // Calculate display width for this grapheme
                        const char_width = vaxis.gwidth.gwidth(grapheme, .unicode);

                        const abs_pos = segment_start + byte_idx;
                        const in_selection = in_visual_mode and abs_pos >= sel_start and abs_pos <= sel_end;
                        const in_file_ref = isInFileRef(abs_pos, file_ref_ranges);
                        const style = if (in_selection)
                            visual_style
                        else if (in_file_ref)
                            file_ref_style
                        else
                            text_style;

                        win.writeCell(@intCast(display_col), @intCast(row), .{
                            .char = .{ .grapheme = grapheme, .width = @intCast(char_width) },
                            .style = style,
                        });

                        display_col += char_width;
                        byte_idx = char_end;
                    }
                } else {
                    // Normal rendering (no visual mode, no file refs)
                    var text_seg = [_]vaxis.Cell.Segment{
                        .{ .text = chunk, .style = text_style },
                    };
                    _ = win.print(&text_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(input_col) });
                }

                // Set terminal cursor if it's in this segment
                if (is_focused and agent_state.input.vim.vim_mode != .command) {
                    const vim_cursor_pos = agent_state.input.vim.cursor_pos;

                    // Determine if cursor is in this segment
                    // For empty text, show cursor at position 0
                    // For empty lines (chunk_len == 0), cursor should be shown if it's exactly at segment_start
                    // For non-empty lines:
                    //   - In normal/visual mode: cursor is ON the character (inclusive end)
                    //   - In insert mode: cursor is BETWEEN characters (exclusive end)
                    const cursor_in_segment = if (text.len == 0)
                        vim_cursor_pos == 0 and segment_start == 0
                    else if (chunk_len == 0)
                        vim_cursor_pos == segment_start
                    else if (vim_mode == .normal or vim_mode == .visual)
                        vim_cursor_pos >= segment_start and vim_cursor_pos < segment_end
                    else
                        vim_cursor_pos >= segment_start and vim_cursor_pos <= segment_end;

                    if (cursor_in_segment) {
                        // Calculate cursor byte offset within the segment
                        const cursor_byte_offset = if (vim_cursor_pos >= segment_start)
                            @min(vim_cursor_pos - segment_start, chunk_len)
                        else
                            0;

                        // Convert byte offset to display column by calculating display width
                        // of characters from segment start to cursor position
                        var cursor_display_offset: usize = 0;
                        var byte_pos: usize = 0;
                        while (byte_pos < cursor_byte_offset and byte_pos < chunk.len) {
                            const seq_len = std.unicode.utf8ByteSequenceLength(chunk[byte_pos]) catch 1;
                            const char_end = @min(byte_pos + seq_len, chunk.len);
                            const grapheme = chunk[byte_pos..char_end];
                            cursor_display_offset += vaxis.gwidth.gwidth(grapheme, .unicode);
                            byte_pos = char_end;
                        }
                        const cursor_col = input_col + cursor_display_offset;

                        if (cursor_col < win.width) {
                            // Set cursor shape based on vim mode
                            switch (vim_mode) {
                                .normal, .visual => {
                                    // Block cursor for normal/visual mode
                                    win.setCursorShape(.block);
                                },
                                .insert => {
                                    // Beam/line cursor for insert mode
                                    win.setCursorShape(.beam);
                                },
                                .command => {
                                    // Should never reach here due to outer check
                                    unreachable;
                                },
                            }
                            // Show terminal cursor at position
                            win.showCursor(@intCast(cursor_col), @intCast(row));
                        }
                    }
                }

                visible_row += 1;
            }

            // Update segment_offset to account for this wrapped segment
            segment_offset += chunk_len;

            // Account for spaces that were trimmed during wrapping
            while (segment_offset < text_line.len and text_line[segment_offset] == ' ') {
                segment_offset += 1;
            }

            display_row += 1;

            // Break after rendering empty line
            if (text_line.len == 0) break;
        }

        // Move char_offset to the end of this line
        char_offset += text_line.len;
    }

    // Render scrollbar if input area is scrollable
    if (total_display_lines > visible_lines) {
        const scrollbar_info = calculateScrollbar(visible_lines, total_display_lines, scroll_offset);
        // Render scrollbar in input area (offset by staged message + separator)
        const scrollbar_win = win.child(.{
            .x_off = 0,
            .y_off = @intCast(content_start_row),
            .width = win.width,
            .height = @intCast(visible_lines),
        });
        renderScrollbar(scrollbar_win, scrollbar_info);
    }
    // Note: Footer is now rendered by the unified status bar in UI.renderStatus
}

fn clipText(text: []const u8, max_len: usize) []const u8 {
    return if (text.len > max_len) text[0..max_len] else text;
}

// =============================================================================
// Inline Model Picker
// =============================================================================

/// Maximum visible models in the model selection dialog
const MAX_MODEL_PICKER_VISIBLE: usize = 10;
const MODEL_PICKER_WIDTH: usize = 80;
const MODEL_PICKER_PADDING: usize = 1;

/// Common model entry for rendering - avoids generics by normalizing both ACP and OpenCode models
const ModelEntry = struct {
    model_id: []const u8,
    name: []const u8,
    description: []const u8,
};

/// Render model selection as a centered dialog (matching file picker style)
/// Works with both ACP and OpenCode managers
fn renderModelSelectionDialog(app: *App, win: vaxis.Window) void {
    // Build normalized model entries from whichever manager is active
    var entries_buf: [256]ModelEntry = undefined;
    var entry_count: usize = 0;
    var current_model_id: ?[]const u8 = null;

    if (app.getActiveAcpManager()) |mgr| {
        const models = mgr.getAvailableModels();
        current_model_id = mgr.getCurrentModelId();
        for (models) |m| {
            if (entry_count >= entries_buf.len) break;
            entries_buf[entry_count] = .{
                .model_id = m.model_id,
                .name = m.name orelse m.model_id,
                .description = m.description orelse "",
            };
            entry_count += 1;
        }
    } else if (app.getActiveOpencodeManager()) |mgr| {
        const models = mgr.getAvailableModels();
        current_model_id = mgr.getCurrentModelId();
        for (models) |m| {
            if (entry_count >= entries_buf.len) break;
            entries_buf[entry_count] = .{
                .model_id = m.model_id,
                .name = m.name orelse m.model_id,
                .description = m.description orelse "",
            };
            entry_count += 1;
        }
    }

    if (entry_count == 0) return;

    const entries = entries_buf[0..entry_count];

    // Use filtered indices for search support
    const filtered = app.state.model_filtered_indices.items;
    const filtered_count = filtered.len;

    // Fixed width, capped to window size (matches file picker pattern)
    const dialog_width = @min(MODEL_PICKER_WIDTH, win.width -| 4);

    // Dynamic height: header(3) + visible items + padding
    const header_rows: usize = 3; // title, input, separator
    const visible_items = @max(1, @min(filtered_count, MAX_MODEL_PICKER_VISIBLE));
    const content_height = header_rows + visible_items + (MODEL_PICKER_PADDING * 2);
    const dialog_height = @min(content_height, win.height -| 4);

    // Center horizontally
    const x_offset = if (win.width > dialog_width) (win.width - dialog_width) / 2 else 0;

    // Anchor top at where max-height dialog would be centered (stable anchor, expands downward)
    const max_height = header_rows + MAX_MODEL_PICKER_VISIBLE + (MODEL_PICKER_PADDING * 2);
    const y_offset = if (win.height > max_height) (win.height - max_height) / 2 else 0;

    // Create dialog window
    const dialog_win = win.child(.{
        .x_off = @intCast(x_offset),
        .y_off = @intCast(y_offset),
        .width = @intCast(dialog_width),
        .height = @intCast(dialog_height),
    });

    // Clear and fill with dark gray background
    dialog_win.clear();
    const bg_cell = vaxis.Cell{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .bg = Color.dialog_bg },
    };
    dialog_win.fill(bg_cell);

    const P = MODEL_PICKER_PADDING;

    // Row 0: Title
    var title_seg = [_]vaxis.Cell.Segment{
        .{ .text = "Switch Model", .style = .{ .fg = Color.cyan, .bg = Color.dialog_bg, .bold = true } },
    };
    _ = dialog_win.print(&title_seg, .{ .row_offset = P, .col_offset = P });

    // Row 1: Search input
    const query_len = app.state.model_filter_len;
    const query = app.state.model_filter_query[0..query_len];
    var input_seg = [_]vaxis.Cell.Segment{
        .{ .text = "/ ", .style = .{ .fg = Color.yellow, .bg = Color.dialog_bg } },
        .{ .text = query, .style = .{ .fg = Color.white, .bg = Color.dialog_bg } },
    };
    _ = dialog_win.print(&input_seg, .{ .row_offset = P + 1, .col_offset = P });

    // Cursor after input text
    dialog_win.showCursor(@intCast(P + 2 + query_len), @intCast(P + 1));

    // Row 2: Separator (dashes like file picker)
    if (dialog_win.width > P * 2) {
        const sep_width = dialog_win.width - (P * 2);
        for (0..sep_width) |col| {
            dialog_win.writeCell(@intCast(P + col), @intCast(P + 2), .{
                .char = .{ .grapheme = "-", .width = 1 },
                .style = .{ .fg = Color.dim_gray, .bg = Color.dialog_bg },
            });
        }
    }

    // Calculate scroll offset
    var scroll_offset: usize = 0;
    if (filtered_count > MAX_MODEL_PICKER_VISIBLE) {
        if (app.state.model_selection >= MAX_MODEL_PICKER_VISIBLE) {
            scroll_offset = app.state.model_selection - MAX_MODEL_PICKER_VISIBLE + 1;
        }
        if (scroll_offset + MAX_MODEL_PICKER_VISIBLE > filtered_count) {
            scroll_offset = filtered_count - MAX_MODEL_PICKER_VISIBLE;
        }
    }

    // Rows 3+: Model list
    if (filtered_count == 0) {
        var no_match_seg = [_]vaxis.Cell.Segment{
            .{ .text = "No matching models", .style = .{ .fg = Color.dim_gray, .bg = Color.dialog_bg } },
        };
        _ = dialog_win.print(&no_match_seg, .{ .row_offset = @intCast(P + 3), .col_offset = P });
    } else {
        const visible_count = @min(filtered_count - scroll_offset, MAX_MODEL_PICKER_VISIBLE);

        for (0..visible_count) |i| {
            const selection_idx = scroll_offset + i;
            if (selection_idx >= filtered_count) break;

            const actual_model_idx = filtered[selection_idx];
            if (actual_model_idx >= entries.len) continue;

            const entry = entries[actual_model_idx];
            const is_selected = selection_idx == app.state.model_selection;
            const is_current = if (current_model_id) |cid| std.mem.eql(u8, entry.model_id, cid) else false;

            const row = P + 3 + i;

            // Selection indicator
            const indicator: []const u8 = if (is_selected) "▶ " else "  ";

            // Current marker (right of name)
            const current_marker: []const u8 = if (is_current) " ✓" else "";

            // Description (truncated to fit)
            const inner_width = if (dialog_win.width > P * 2) dialog_win.width - (P * 2) else 0;
            const name_and_marker_len = 2 + entry.name.len + current_marker.len + 2;
            const max_desc_len = if (inner_width > name_and_marker_len) inner_width - name_and_marker_len else 0;
            const truncated_desc = if (entry.description.len > max_desc_len) entry.description[0..max_desc_len] else entry.description;

            var item_seg = [_]vaxis.Cell.Segment{
                .{ .text = indicator, .style = .{ .fg = Color.cyan, .bg = Color.dialog_bg } },
                .{ .text = entry.name, .style = .{ .fg = if (is_selected) Color.white else Color.dim_gray, .bg = Color.dialog_bg, .bold = is_selected } },
                .{ .text = current_marker, .style = .{ .fg = Color.green, .bg = Color.dialog_bg } },
                .{ .text = "  ", .style = .{ .bg = Color.dialog_bg } },
                .{ .text = truncated_desc, .style = .{ .fg = Color.dim_gray, .bg = Color.dialog_bg } },
            };
            _ = dialog_win.print(&item_seg, .{ .row_offset = @intCast(row), .col_offset = P });
        }

        // Scroll indicator ("..." at bottom like file picker)
        if (scroll_offset + visible_count < filtered_count) {
            const dots_row = P + 3 + visible_count;
            if (dots_row < dialog_win.height) {
                var dots_seg = [_]vaxis.Cell.Segment{
                    .{ .text = "...", .style = .{ .fg = Color.dim_gray, .bg = Color.dialog_bg } },
                };
                _ = dialog_win.print(&dots_seg, .{ .row_offset = @intCast(dots_row), .col_offset = P + 2 });
            }
        }
    }
}

// =============================================================================
// Agent Command Palette
// =============================================================================

/// Maximum visible items in command palette
const MAX_CMD_PALETTE_VISIBLE: usize = 10;

/// Render the agent command palette - same approach as diff view's command_palette.zig
fn renderAgentCommandPalette(win: vaxis.Window, cmd_palette: *command_palette.AgentCommandPaletteState) void {
    const filtered = cmd_palette.filtered_indices.items;
    if (filtered.len == 0 and cmd_palette.mode != .rename_input) return;

    // Fixed width, dynamic height based on content
    const palette_width: usize = 60;
    const visible_count = @min(filtered.len, MAX_CMD_PALETTE_VISIBLE);

    // Dynamic height: 3 header rows (title, input, separator) + visible items (min 1 for no results) + vertical padding
    const header_rows: usize = 3;
    const content_rows = @max(1, visible_count);
    const content_height = header_rows + content_rows + (MENU_PADDING * 2); // add top and bottom padding
    const palette_height = @min(content_height, win.height -| 4);

    const x_offset = if (win.width > palette_width) (win.width - palette_width) / 2 else 0;
    // Calculate y_offset based on where the dialog would be if at max height (centered)
    // This creates a stable anchor point that expands downward
    const max_height = header_rows + MAX_CMD_PALETTE_VISIBLE + (MENU_PADDING * 2);
    const y_offset = if (win.height > max_height) (win.height - max_height) / 2 else 0;

    // Create palette window
    const palette_win = win.child(.{
        .x_off = @intCast(x_offset),
        .y_off = @intCast(y_offset),
        .width = @intCast(palette_width),
        .height = @intCast(palette_height),
    });

    // Clear and fill with dark gray background to differentiate from main content
    palette_win.clear();
    const bg_cell = vaxis.Cell{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .bg = Color.dialog_bg },
    };
    palette_win.fill(bg_cell);

    // Line 0: Title (with vertical padding)
    const title: []const u8 = if (cmd_palette.mode == .rename_input) "Rename Tab" else "Commands";
    const title_style = vaxis.Style{ .fg = Color.cyan, .bg = Color.dialog_bg, .bold = true };
    var title_seg = [_]vaxis.Cell.Segment{.{ .text = title, .style = title_style }};
    _ = palette_win.print(&title_seg, .{ .row_offset = MENU_PADDING, .col_offset = MENU_PADDING });

    // Line 1: Input field
    const input_prompt: []const u8 = if (cmd_palette.mode == .rename_input) "Name: " else ": ";
    const input_text = if (cmd_palette.mode == .rename_input)
        cmd_palette.rename_buffer[0..cmd_palette.rename_len]
    else
        cmd_palette.query_buffer[0..cmd_palette.query_len];

    var input_seg = [_]vaxis.Cell.Segment{
        .{ .text = input_prompt, .style = .{ .fg = Color.cyan, .bg = Color.dialog_bg } },
        .{ .text = input_text, .style = .{ .fg = Color.white, .bg = Color.dialog_bg } },
    };
    _ = palette_win.print(&input_seg, .{ .row_offset = MENU_PADDING + 1, .col_offset = MENU_PADDING });

    // Show cursor
    const cursor_x = MENU_PADDING + input_prompt.len + input_text.len;
    palette_win.showCursor(@intCast(cursor_x), @intCast(MENU_PADDING + 1));

    // Line 2: Separator
    if (palette_win.width > MENU_PADDING * 2) {
        for (MENU_PADDING..palette_win.width - MENU_PADDING) |col| {
            palette_win.writeCell(@intCast(col), @intCast(MENU_PADDING + 2), .{
                .char = .{ .grapheme = "-", .width = 1 },
                .style = .{ .fg = Color.dim_gray, .bg = Color.dialog_bg },
            });
        }
    }

    // Lines 3+: Items (only in search mode, with vertical padding)
    if (cmd_palette.mode == .search and filtered.len > 0) {
        const scroll = cmd_palette.scroll_offset;

        for (0..visible_count) |i| {
            const item_idx = scroll + i;
            if (item_idx >= filtered.len) break;

            const cmd_idx = filtered[item_idx];
            const cmd = command_palette.COMMANDS[cmd_idx];
            const is_selected = item_idx == cmd_palette.selected_idx;
            const row = MENU_PADDING + 3 + i;

            // Selection indicator
            const indicator: []const u8 = if (is_selected) "▶ " else "  ";
            const indicator_style = vaxis.Style{
                .fg = if (is_selected) Color.cyan else Color.dim_gray,
                .bg = Color.dialog_bg,
            };

            // Command name
            const name_style = vaxis.Style{
                .fg = Color.white,
                .bg = Color.dialog_bg,
                .bold = is_selected,
            };

            // Alias/description
            const desc_style = vaxis.Style{ .fg = Color.dim_gray, .bg = Color.dialog_bg };

            var item_seg = [_]vaxis.Cell.Segment{
                .{ .text = indicator, .style = indicator_style },
                .{ .text = cmd.name, .style = name_style },
                .{ .text = "  ", .style = .{ .bg = Color.dialog_bg } },
                .{ .text = cmd.aliases[0], .style = desc_style },
            };
            _ = palette_win.print(&item_seg, .{ .row_offset = @intCast(row), .col_offset = MENU_PADDING });
        }
    } else if (cmd_palette.mode == .search and filtered.len == 0) {
        // No matching commands
        var no_match_seg = [_]vaxis.Cell.Segment{
            .{ .text = "No matching commands", .style = .{ .fg = Color.dim_gray, .bg = Color.dialog_bg } },
        };
        _ = palette_win.print(&no_match_seg, .{ .row_offset = MENU_PADDING + 3, .col_offset = MENU_PADDING });
    }
}

// =============================================================================
// Inline Permission Prompt
// =============================================================================

/// Helper function to wrap text and render it across multiple rows
fn renderWrappedText(
    win: vaxis.Window,
    text: []const u8,
    start_row: usize,
    col_offset: usize,
    max_width: usize,
    style: vaxis.Style,
) usize {
    if (text.len == 0) return 0;

    var row = start_row;
    var pos: usize = 0;

    while (pos < text.len) {
        if (row >= win.height) break;

        // Calculate how much text fits on this line
        const remaining = text[pos..];
        const chunk_len = @min(remaining.len, max_width);
        var break_at = chunk_len;

        // If we're not at the end, try to break at a word boundary
        if (chunk_len < remaining.len and chunk_len > 10) {
            // Search backwards for a space
            var search_pos = chunk_len;
            while (search_pos > chunk_len / 2) : (search_pos -= 1) {
                if (remaining[search_pos - 1] == ' ') {
                    break_at = search_pos;
                    break;
                }
            }
        }

        const chunk = remaining[0..break_at];
        var seg = [_]vaxis.Cell.Segment{
            .{ .text = chunk, .style = style },
        };
        _ = win.print(&seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(col_offset) });

        pos += break_at;
        // Skip leading space on next line
        if (pos < text.len and text[pos] == ' ') {
            pos += 1;
        }
        row += 1;
    }

    return row - start_row; // Return number of rows used
}

/// Render the permission prompt inline in place of the input area
fn renderInlinePermissionPrompt(win: vaxis.Window, perm: *AcpManager.PendingPermission) !void {
    var row: usize = 0;

    // Row 0: Separator line
    const separator_style = vaxis.Style{ .fg = Color.dim_gray };
    for (0..win.width) |col| {
        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = separator_style,
        });
    }
    row += 1;

    // Row 1+: Title (wrapped if needed)
    const title_style = vaxis.Style{ .fg = Color.magenta, .bold = true };
    const max_text_width = if (win.width > 3) win.width - 3 else 1; // Leave margin
    const title_rows = renderWrappedText(win, perm.title, row, 1, max_text_width, title_style);
    row += title_rows;

    // Row N+: Description (wrapped if present)
    if (perm.description) |desc| {
        const desc_style = vaxis.Style{ .fg = Color.dim_gray, .italic = true };
        const desc_rows = renderWrappedText(win, desc, row, 1, max_text_width, desc_style);
        row += desc_rows;
    }

    // Rows: Options
    const normal_style = vaxis.Style{ .fg = Color.white };
    const selected_style = vaxis.Style{ .fg = Color.black, .bg = Color.cyan, .bold = true };

    for (perm.options, 0..) |opt, i| {
        if (row >= win.height) break;

        const is_selected = i == perm.selected_index;
        const style = if (is_selected) selected_style else normal_style;

        // Selection indicator
        const indicator: []const u8 = if (is_selected) "▸ " else "  ";
        var ind_seg = [_]vaxis.Cell.Segment{
            .{ .text = indicator, .style = style },
        };
        _ = win.print(&ind_seg, .{ .row_offset = @intCast(row), .col_offset = 1 });

        // Option name
        var name_seg = [_]vaxis.Cell.Segment{
            .{ .text = opt.name, .style = style },
        };
        _ = win.print(&name_seg, .{ .row_offset = @intCast(row), .col_offset = 3 });

        row += 1;
    }

    // Footer row with keybindings
    if (row < win.height) {
        const footer = "j/k:navigate  Enter:confirm  ESC:cancel";
        const kb_style = vaxis.Style{ .fg = Color.dim_gray };
        const kb_col = if (win.width > footer.len) win.width - footer.len else 0;

        var kb_seg = [_]vaxis.Cell.Segment{
            .{ .text = footer, .style = kb_style },
        };
        _ = win.print(&kb_seg, .{ .row_offset = @intCast(row), .col_offset = @intCast(kb_col) });
    }
}
