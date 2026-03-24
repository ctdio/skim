//! Test Helpers for Markdown Rendering
//!
//! Provides utilities for testing markdown rendering output in snapshot tests.
//!
//! Two approaches are available:
//! 1. Full pipeline: renderMarkdown() uses the actual MarkdownParser + MarkdownRenderer
//! 2. Manual helpers: renderHeader(), renderBold(), etc. for fine-grained control
//!
//! Prefer the full pipeline for integration tests that verify actual rendering behavior.

const std = @import("std");
const vaxis = @import("vaxis");

// Import the actual markdown rendering pipeline (via build.zig module)
const markdown = @import("markdown");
const MarkdownParser = markdown.MarkdownParser;
const MarkdownRenderer = markdown.MarkdownRenderer;
const StyledSpan = markdown.StyledSpan;
const md_colors = markdown.colors;

const Cell = vaxis.Cell;

// =============================================================================
// Markdown Colors (copied from agent/markdown/colors.zig)
// =============================================================================

/// Style configuration for markdown rendering
pub const MarkdownColors = struct {
    h1: vaxis.Style,
    h2: vaxis.Style,
    h3: vaxis.Style,
    h4: vaxis.Style,
    h5: vaxis.Style,
    h6: vaxis.Style,
    bold: vaxis.Style,
    italic: vaxis.Style,
    strikethrough: vaxis.Style,
    inline_code: vaxis.Style,
    inline_code_bg: vaxis.Color,
    link_text: vaxis.Style,
    link_url: vaxis.Style,
    text: vaxis.Style,
    list_marker: vaxis.Style,
    blockquote_border: vaxis.Style,
    blockquote_text: vaxis.Style,
    task_checked: vaxis.Style,
    task_unchecked: vaxis.Style,
    horizontal_rule: vaxis.Style,
    code_block_bg: vaxis.Color,
    code_block_border: vaxis.Style,
    code_block_lang: vaxis.Style,
    table_header: vaxis.Style,
    table_border: vaxis.Style,
    table_cell: vaxis.Style,
};

/// Default markdown colors matching skim's aesthetic
const default: MarkdownColors = .{
    .h1 = .{
        .fg = .{ .rgb = [3]u8{ 232, 232, 232 } },
        .bold = true,
    },
    .h2 = .{
        .fg = .{ .rgb = [3]u8{ 216, 216, 216 } },
        .bold = true,
    },
    .h3 = .{
        .fg = .{ .rgb = [3]u8{ 192, 192, 192 } },
        .bold = true,
    },
    .h4 = .{
        .fg = .{ .rgb = [3]u8{ 168, 168, 168 } },
    },
    .h5 = .{
        .fg = .{ .rgb = [3]u8{ 152, 152, 152 } },
    },
    .h6 = .{
        .fg = .{ .rgb = [3]u8{ 136, 136, 136 } },
    },
    .bold = .{
        .bold = true,
    },
    .italic = .{
        .italic = true,
    },
    .strikethrough = .{
        .strikethrough = true,
        .fg = .{ .rgb = [3]u8{ 100, 100, 100 } },
    },
    .inline_code = .{
        .fg = .{ .index = 6 },
    },
    .inline_code_bg = .{ .rgb = [3]u8{ 45, 45, 50 } },
    .link_text = .{
        .fg = .{ .rgb = [3]u8{ 88, 166, 255 } },
        .ul_style = .single,
    },
    .link_url = .{
        .fg = .{ .rgb = [3]u8{ 100, 100, 100 } },
    },
    .text = .{
        .fg = .{ .rgb = [3]u8{ 200, 200, 200 } },
    },
    .list_marker = .{
        .fg = .{ .rgb = [3]u8{ 0x6c, 0x70, 0x86 } },
    },
    .blockquote_border = .{
        .fg = .{ .rgb = [3]u8{ 0x6c, 0x70, 0x86 } },
    },
    .blockquote_text = .{
        .fg = .{ .rgb = [3]u8{ 0xa9, 0xb1, 0xd6 } },
    },
    .task_checked = .{
        .fg = .{ .rgb = [3]u8{ 0x9e, 0xce, 0x6a } },
    },
    .task_unchecked = .{
        .fg = .{ .rgb = [3]u8{ 0x6c, 0x70, 0x86 } },
    },
    .horizontal_rule = .{
        .fg = .{ .rgb = [3]u8{ 0x6c, 0x70, 0x86 } },
    },
    .code_block_bg = .{ .rgb = [3]u8{ 0x1a, 0x1b, 0x26 } },
    .code_block_border = .{
        .fg = .{ .rgb = [3]u8{ 0x6c, 0x70, 0x86 } },
    },
    .code_block_lang = .{
        .fg = .{ .rgb = [3]u8{ 0x6c, 0x70, 0x86 } },
        .bg = .{ .rgb = [3]u8{ 0x1a, 0x1b, 0x26 } },
    },
    .table_header = .{
        .fg = .{ .rgb = [3]u8{ 200, 200, 200 } },
        .bold = true,
    },
    .table_border = .{
        .fg = .{ .rgb = [3]u8{ 0x6c, 0x70, 0x86 } },
    },
    .table_cell = .{
        .fg = .{ .rgb = [3]u8{ 200, 200, 200 } },
    },
};

// =============================================================================
// Render Helpers
// =============================================================================

/// Helper to render styled text using print (proper string handling)
fn printStyled(win: vaxis.Window, text: []const u8, style: vaxis.Style, row: usize, col: usize) usize {
    var segs = [_]Cell.Segment{.{ .text = text, .style = style }};
    const result = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
    return col + (result.col - col);
}

/// Render a header with specific level to window
pub fn renderHeader(
    win: vaxis.Window,
    text: []const u8,
    level: usize,
    row: usize,
) void {
    const style = switch (level) {
        1 => default.h1,
        2 => default.h2,
        3 => default.h3,
        4 => default.h4,
        5 => default.h5,
        else => default.h6,
    };
    _ = printStyled(win, text, style, row, 0);
}

/// Render bold text to window
pub fn renderBold(
    win: vaxis.Window,
    text: []const u8,
    row: usize,
    col: usize,
) usize {
    var segs = [_]Cell.Segment{.{ .text = text, .style = default.bold }};
    const result = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
    return result.col;
}

/// Render italic text to window
pub fn renderItalic(
    win: vaxis.Window,
    text: []const u8,
    row: usize,
    col: usize,
) usize {
    var segs = [_]Cell.Segment{.{ .text = text, .style = default.italic }};
    const result = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
    return result.col;
}

/// Render inline code to window
pub fn renderInlineCode(
    win: vaxis.Window,
    text: []const u8,
    row: usize,
    col: usize,
) usize {
    const style = vaxis.Style{
        .fg = default.inline_code.fg,
        .bg = default.inline_code_bg,
    };
    var segs = [_]Cell.Segment{.{ .text = text, .style = style }};
    const result = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
    return result.col;
}

/// Render link text to window
pub fn renderLink(
    win: vaxis.Window,
    text: []const u8,
    row: usize,
    col: usize,
) usize {
    var segs = [_]Cell.Segment{.{ .text = text, .style = default.link_text }};
    const result = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
    return result.col;
}

/// Render strikethrough text to window
pub fn renderStrikethrough(
    win: vaxis.Window,
    text: []const u8,
    row: usize,
    col: usize,
) usize {
    var segs = [_]Cell.Segment{.{ .text = text, .style = default.strikethrough }};
    const result = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
    return result.col;
}

/// Render a list bullet marker
pub fn renderListBullet(
    win: vaxis.Window,
    row: usize,
    indent: usize,
) usize {
    var segs = [_]Cell.Segment{.{ .text = "• ", .style = default.list_marker }};
    const result = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = @intCast(indent) });
    return result.col;
}

/// Render an ordered list number marker
/// Note: Number string is allocated and NOT freed - caller should use arena allocator
pub fn renderListNumber(
    allocator: std.mem.Allocator,
    win: vaxis.Window,
    number: usize,
    row: usize,
    indent: usize,
) !usize {
    // Allocate string - caller is responsible for cleanup (use arena allocator)
    const num_str = try std.fmt.allocPrint(allocator, "{d}. ", .{number});

    var segs = [_]Cell.Segment{.{ .text = num_str, .style = default.list_marker }};
    const result = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = @intCast(indent) });
    return result.col;
}

/// Render blockquote border
pub fn renderBlockquoteBorder(
    win: vaxis.Window,
    row: usize,
    indent: usize,
) usize {
    var segs = [_]Cell.Segment{.{ .text = "│ ", .style = default.blockquote_border }};
    const result = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = @intCast(indent) });
    return result.col;
}

/// Render blockquote text
pub fn renderBlockquoteText(
    win: vaxis.Window,
    text: []const u8,
    row: usize,
    col: usize,
) usize {
    var segs = [_]Cell.Segment{.{ .text = text, .style = default.blockquote_text }};
    const result = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
    return result.col;
}

/// Render task checkbox (checked)
pub fn renderTaskChecked(
    win: vaxis.Window,
    row: usize,
    indent: usize,
) usize {
    var segs = [_]Cell.Segment{.{ .text = "☑ ", .style = default.task_checked }};
    const result = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = @intCast(indent) });
    return result.col;
}

/// Render task checkbox (unchecked)
pub fn renderTaskUnchecked(
    win: vaxis.Window,
    row: usize,
    indent: usize,
) usize {
    var segs = [_]Cell.Segment{.{ .text = "☐ ", .style = default.task_unchecked }};
    const result = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = @intCast(indent) });
    return result.col;
}

/// Render horizontal rule
pub fn renderHorizontalRule(
    win: vaxis.Window,
    row: usize,
    width: usize,
) void {
    // Create a horizontal line of the specified width
    const hr_text = "────────────────────────────────────────────────────────────────────────────────";
    const actual_width = @min(width, hr_text.len);
    var segs = [_]Cell.Segment{.{ .text = hr_text[0..actual_width], .style = default.horizontal_rule }};
    _ = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = 0 });
}

/// Render normal text
pub fn renderText(
    win: vaxis.Window,
    text: []const u8,
    row: usize,
    col: usize,
) usize {
    var segs = [_]Cell.Segment{.{ .text = text, .style = default.text }};
    const result = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
    return result.col;
}

/// Render table header cell
pub fn renderTableHeader(
    win: vaxis.Window,
    text: []const u8,
    row: usize,
    col: usize,
) usize {
    var segs = [_]Cell.Segment{.{ .text = text, .style = default.table_header }};
    const result = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
    return result.col;
}

/// Render table border character
pub fn renderTableBorder(
    win: vaxis.Window,
    text: []const u8,
    row: usize,
    col: usize,
) usize {
    var segs = [_]Cell.Segment{.{ .text = text, .style = default.table_border }};
    const result = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
    return result.col;
}

/// Render table cell content
pub fn renderTableCell(
    win: vaxis.Window,
    text: []const u8,
    row: usize,
    col: usize,
) usize {
    var segs = [_]Cell.Segment{.{ .text = text, .style = default.table_cell }};
    const result = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
    return result.col;
}

/// Render code block border
pub fn renderCodeBlockBorder(
    win: vaxis.Window,
    text: []const u8,
    row: usize,
    col: usize,
) usize {
    var segs = [_]Cell.Segment{.{ .text = text, .style = default.code_block_border }};
    const result = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
    return result.col;
}

/// Render code block language label
pub fn renderCodeBlockLang(
    win: vaxis.Window,
    text: []const u8,
    row: usize,
    col: usize,
) usize {
    var segs = [_]Cell.Segment{.{ .text = text, .style = default.code_block_lang }};
    const result = win.print(&segs, .{ .row_offset = @intCast(row), .col_offset = @intCast(col) });
    return result.col;
}

// =============================================================================
// Full Pipeline Integration
// =============================================================================

/// Render markdown source through the full pipeline (parser + renderer) to a window.
/// This is the preferred method for integration tests as it tests actual rendering behavior.
///
/// Parameters:
/// - allocator: Used for temporary allocations during parsing/rendering
/// - win: The vaxis window to render to
/// - source: The markdown source text
/// - max_width: Maximum width for table rendering (use window width)
///
/// Returns error if parsing or rendering fails.
pub fn renderMarkdown(
    allocator: std.mem.Allocator,
    win: vaxis.Window,
    source: []const u8,
    max_width: usize,
) !void {
    // Parse markdown
    var parser = try MarkdownParser.init();
    defer parser.deinit();
    try parser.parse(source);

    // Render to styled spans
    var renderer = MarkdownRenderer.initWithHighlighter(
        allocator,
        md_colors.default,
        .{ .ctx = null, .func = null },
        max_width,
    );
    // Note: don't defer deinit - we need spans to stay valid during rendering

    const spans = renderer.render(&parser) catch |err| {
        renderer.deinit();
        return err;
    };

    // Render spans to window
    // Note: We intentionally do NOT call renderer.deinit() because the arena
    // allocator keeps all memory valid, and the spans/strings need to remain
    // valid for the window cells that reference them.
    var row: usize = 0;
    var col: usize = 0;

    for (spans) |span| {
        // Handle newlines
        if (std.mem.eql(u8, span.text, "\n")) {
            row += 1;
            col = 0;
            continue;
        }

        // Split on embedded newlines within span text
        var lines = std.mem.splitScalar(u8, span.text, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) {
                row += 1;
                col = 0;
            }
            first = false;

            if (line.len == 0) continue;

            // Render this segment
            var segs = [_]Cell.Segment{.{ .text = line, .style = span.style }};
            const result = win.print(&segs, .{
                .row_offset = @intCast(row),
                .col_offset = @intCast(col),
            });
            col = result.col;
        }
    }

    // Note: renderer.deinit() is NOT called - the arena allocator handles cleanup.
    // This is required because window cells hold pointers to the rendered text.
}

// =============================================================================
// Tests
// =============================================================================

test "markdown colors available" {
    // Verify all markdown style colors are accessible
    try std.testing.expect(default.h1.bold);
    try std.testing.expect(default.h2.bold);
    try std.testing.expect(default.bold.bold);
    try std.testing.expect(default.italic.italic);
    try std.testing.expect(default.strikethrough.strikethrough);
}

test "renderMarkdown - simple table" {
    const allocator = std.testing.allocator;

    // Use arena allocator for rendering since we don't call renderer.deinit()
    // (to keep spans alive for display)
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Create a mock screen using the proper API
    var screen = try vaxis.Screen.init(allocator, .{ .cols = 80, .rows = 10, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);

    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 80,
        .height = 10,
        .screen = &screen,
    };

    const table_md =
        \\| Name | Value |
        \\|:-----|:------|
        \\| foo  | 42    |
    ;

    try renderMarkdown(arena_alloc, win, table_md, 80);

    // Just verify it doesn't crash - actual content verified via snapshot tests
}
