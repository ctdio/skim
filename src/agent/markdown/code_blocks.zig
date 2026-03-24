//! Fenced Code Block Rendering
//!
//! Handles rendering of fenced code blocks with syntax highlighting
//! and language labels. Code blocks show:
//! - Optional language label (subtle styling)
//! - Syntax-highlighted code content with dark background
//! - Padding for visual separation

const std = @import("std");
const vaxis = @import("vaxis");
const types = @import("types.zig");
const colors_mod = @import("colors.zig");

const StyledSpan = types.StyledSpan;
const NodeType = types.NodeType;
const MarkdownColors = colors_mod.MarkdownColors;

/// Color categories for syntax highlighting
pub const ColorCategory = enum {
    keyword,
    function,
    type,
    string,
    number,
    comment,
    constant,
    operator,
    default,
};

/// Highlight represents a syntax-highlighted range
pub const Highlight = struct {
    start_byte: usize,
    end_byte: usize,
    category: []const u8,

    pub fn getColorCategory(self: Highlight) ColorCategory {
        if (std.mem.startsWith(u8, self.category, "keyword")) return .keyword;
        if (std.mem.startsWith(u8, self.category, "function")) return .function;
        if (std.mem.startsWith(u8, self.category, "type")) return .type;
        if (std.mem.startsWith(u8, self.category, "string")) return .string;
        if (std.mem.startsWith(u8, self.category, "number")) return .number;
        if (std.mem.startsWith(u8, self.category, "comment")) return .comment;
        if (std.mem.startsWith(u8, self.category, "constant")) return .constant;
        if (std.mem.startsWith(u8, self.category, "operator") or
            std.mem.startsWith(u8, self.category, "punctuation")) return .operator;
        return .default;
    }
};

/// Callback type for syntax highlighting with context
/// Returns highlights for a given fake file path and content
pub const HighlightFn = *const fn (ctx: *anyopaque, path: []const u8, content: []const u8) ?[]const Highlight;

/// Highlight context for passing to the callback
pub const HighlightContext = struct {
    ctx: ?*anyopaque,
    func: ?HighlightFn,

    pub fn call(self: HighlightContext, path: []const u8, content: []const u8) ?[]const Highlight {
        if (self.func) |f| {
            if (self.ctx) |c| {
                return f(c, path, content);
            }
        }
        return null;
    }
};

/// Renderer for fenced code blocks
pub const CodeBlockRenderer = struct {
    allocator: std.mem.Allocator,
    colors: MarkdownColors,
    highlight_ctx: HighlightContext,

    /// Initialize a new code block renderer
    pub fn init(allocator: std.mem.Allocator, md_colors: MarkdownColors, highlight_ctx: HighlightContext) CodeBlockRenderer {
        return .{
            .allocator = allocator,
            .colors = md_colors,
            .highlight_ctx = highlight_ctx,
        };
    }

    /// No cleanup needed - highlights are managed externally
    pub fn deinit(self: *CodeBlockRenderer) void {
        _ = self;
    }

    /// Render a fenced code block into styled spans
    /// Returns owned slice of spans
    pub fn render(self: *CodeBlockRenderer, code: []const u8, language_hint: ?[]const u8) !std.ArrayList(StyledSpan) {
        var spans: std.ArrayList(StyledSpan) = .{};
        errdefer spans.deinit(self.allocator);

        const bg_style = vaxis.Style{ .bg = self.colors.code_block_bg };
        const code_indent: usize = 1; // Code content indent
        const label_indent: usize = 1; // Language label - 2 spaces from edge

        // Language label line (if provided) or empty header line for consistent spacing
        const has_language = if (language_hint) |lang| lang.len > 0 else false;
        if (has_language) {
            try spans.append(self.allocator, .{
                .text = language_hint.?,
                .style = self.colors.code_block_lang,
                .indent = label_indent,
                .node_type = .fenced_code_block,
            });
            try spans.append(self.allocator, .{
                .text = "\n",
                .style = bg_style,
                .indent = code_indent,
                .node_type = .fenced_code_block,
            });
        } else {
            // No language - add two empty lines to match visual spacing of language label + newline
            try spans.append(self.allocator, .{
                .text = "\n",
                .style = bg_style,
                .indent = code_indent,
                .node_type = .fenced_code_block,
            });
            try spans.append(self.allocator, .{
                .text = "\n",
                .style = bg_style,
                .indent = code_indent,
                .node_type = .fenced_code_block,
            });
        }

        // Empty line before code content (consistent header spacing)
        try spans.append(self.allocator, .{
            .text = "\n",
            .style = bg_style,
            .indent = code_indent,
            .node_type = .fenced_code_block,
        });

        // Render code content with syntax highlighting
        try self.renderHighlighted(&spans, code, language_hint, code_indent);

        // Bottom padding - empty line after code block
        try spans.append(self.allocator, .{
            .text = "\n",
            .style = bg_style,
            .indent = code_indent,
            .node_type = .fenced_code_block,
        });

        return spans;
    }

    /// Render code with syntax highlighting
    fn renderHighlighted(self: *CodeBlockRenderer, spans: *std.ArrayList(StyledSpan), code: []const u8, language_hint: ?[]const u8, indent: usize) !void {
        // Strip trailing whitespace/newlines from code
        var trimmed_code = std.mem.trimRight(u8, code, " \t\n\r");

        // Also strip trailing fence markers (```) that might be included by parser
        while (std.mem.endsWith(u8, trimmed_code, "```")) {
            trimmed_code = std.mem.trimRight(u8, trimmed_code[0 .. trimmed_code.len - 3], " \t\n\r");
        }

        if (trimmed_code.len == 0) {
            return;
        }

        // Base style for code content
        const base_style = vaxis.Style{
            .fg = self.colors.text.fg,
            .bg = self.colors.code_block_bg,
        };

        // Try to get syntax highlights if highlight context available
        var highlights: ?[]const Highlight = null;
        if (language_hint) |lang| {
            // Map normalized language to file extension for highlighter
            const fake_path = mapLanguageToPath(lang);
            if (fake_path) |path| {
                highlights = self.highlight_ctx.call(path, trimmed_code);
            }
        }

        // Render each line with highlighting
        var line_iter = std.mem.splitScalar(u8, trimmed_code, '\n');
        var byte_offset: usize = 0;

        while (line_iter.next()) |line| {
            // Render line content
            if (highlights != null and line.len > 0) {
                // Render line with syntax highlighting
                try self.renderLineWithHighlights(spans, line, highlights.?, byte_offset, base_style, indent);
            } else {
                // No highlights, render plain with indent
                try spans.append(self.allocator, .{
                    .text = line,
                    .style = base_style,
                    .indent = indent,
                    .node_type = .fenced_code_block,
                });
            }

            // Add newline - use fenced_code_block node type for fill_bg
            try spans.append(self.allocator, .{
                .text = "\n",
                .style = base_style,
                .indent = 0,
                .node_type = .fenced_code_block,
            });

            byte_offset += line.len + 1; // +1 for the newline
        }
    }

    /// Render a single line with syntax highlights applied
    fn renderLineWithHighlights(
        self: *CodeBlockRenderer,
        spans: *std.ArrayList(StyledSpan),
        line: []const u8,
        highlights: []const Highlight,
        line_offset: usize,
        base_style: vaxis.Style,
        indent: usize,
    ) !void {
        var pos: usize = 0;
        const line_end = line_offset + line.len;

        // Find highlights that overlap with this line
        for (highlights) |hl| {
            // Skip highlights that don't overlap with this line
            if (hl.end_byte <= line_offset or hl.start_byte >= line_end) continue;

            // Calculate overlap within the line
            const hl_start_in_line = if (hl.start_byte > line_offset) hl.start_byte - line_offset else 0;
            const hl_end_in_line = @min(hl.end_byte - line_offset, line.len);

            if (hl_start_in_line > pos) {
                // Emit unhighlighted text before this highlight
                try spans.append(self.allocator, .{
                    .text = line[pos..hl_start_in_line],
                    .style = base_style,
                    .indent = indent, // All spans use same indent
                    .node_type = .fenced_code_block,
                });
            }

            if (hl_start_in_line < hl_end_in_line and hl_start_in_line >= pos) {
                // Emit highlighted text
                const hl_style = getStyleForHighlight(hl, base_style);
                try spans.append(self.allocator, .{
                    .text = line[hl_start_in_line..hl_end_in_line],
                    .style = hl_style,
                    .indent = indent, // All spans use same indent
                    .node_type = .fenced_code_block,
                });
                pos = hl_end_in_line;
            }
        }

        // Emit any remaining unhighlighted text
        if (pos < line.len) {
            try spans.append(self.allocator, .{
                .text = line[pos..],
                .style = base_style,
                .indent = indent, // All spans use same indent
                .node_type = .fenced_code_block,
            });
        }
    }

    /// Detect language from fence info string
    /// Normalizes common aliases (e.g., "py" -> "python", "js" -> "javascript")
    pub fn detectLanguage(info_string: []const u8) ?[]const u8 {
        if (info_string.len == 0) {
            return null;
        }

        // Language alias map for common shorthand names
        const alias_map = std.StaticStringMap([]const u8).initComptime(.{
            // Python
            .{ "py", "python" },
            .{ "python", "python" },
            .{ "python3", "python" },
            // JavaScript
            .{ "js", "javascript" },
            .{ "javascript", "javascript" },
            .{ "jsx", "javascript" },
            // TypeScript
            .{ "ts", "typescript" },
            .{ "typescript", "typescript" },
            .{ "tsx", "typescript" },
            // Rust
            .{ "rs", "rust" },
            .{ "rust", "rust" },
            // Go
            .{ "go", "go" },
            .{ "golang", "go" },
            // Shell/Bash
            .{ "sh", "bash" },
            .{ "bash", "bash" },
            .{ "shell", "bash" },
            .{ "zsh", "bash" },
            // C/C++
            .{ "c", "c" },
            .{ "cpp", "cpp" },
            .{ "c++", "cpp" },
            .{ "cxx", "cpp" },
            // Zig
            .{ "zig", "zig" },
            // JSON
            .{ "json", "json" },
            // YAML
            .{ "yaml", "yaml" },
            .{ "yml", "yaml" },
            // Markdown
            .{ "md", "markdown" },
            .{ "markdown", "markdown" },
            // HTML/CSS
            .{ "html", "html" },
            .{ "css", "css" },
            // SQL
            .{ "sql", "sql" },
            // TOML
            .{ "toml", "toml" },
        });

        // Return normalized language or the original if not in map
        return alias_map.get(info_string) orelse info_string;
    }
};

/// Map language name to a fake file path for the syntax highlighter
fn mapLanguageToPath(lang: []const u8) ?[]const u8 {
    const path_map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "python", "code.py" },
        .{ "javascript", "code.js" },
        .{ "typescript", "code.ts" },
        .{ "rust", "code.rs" },
        .{ "go", "code.go" },
        .{ "bash", "code.sh" },
        .{ "c", "code.c" },
        .{ "cpp", "code.cpp" },
        .{ "zig", "code.zig" },
        .{ "json", "code.json" },
        .{ "toml", "code.toml" },
        .{ "markdown", "code.md" },
        .{ "css", "code.css" },
    });
    return path_map.get(lang);
}

/// Get vaxis style for a syntax highlight category
fn getStyleForHighlight(hl: Highlight, base_style: vaxis.Style) vaxis.Style {
    const color_cat = hl.getColorCategory();

    // Syntax highlighting colors (GitHub-inspired, matching highlighting/core.zig)
    const fg_color: vaxis.Color = switch (color_cat) {
        .keyword => .{ .rgb = [3]u8{ 255, 123, 114 } }, // Coral red #FF7B72
        .function => .{ .rgb = [3]u8{ 210, 168, 255 } }, // Purple #D2A8FF
        .type => .{ .index = 6 }, // Cyan accent to match agent UI
        .string => .{ .rgb = [3]u8{ 165, 214, 255 } }, // Light blue #A5D6FF
        .number => .{ .rgb = [3]u8{ 121, 192, 255 } }, // Cyan #79C0FF
        .comment => .{ .rgb = [3]u8{ 139, 148, 158 } }, // Gray #8B949E
        .constant => .{ .rgb = [3]u8{ 121, 192, 255 } }, // Cyan #79C0FF
        .operator => .{ .rgb = [3]u8{ 255, 123, 114 } }, // Coral red #FF7B72
        .default => base_style.fg,
    };

    return .{
        .fg = fg_color,
        .bg = base_style.bg,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "render plain code block" {
    const allocator = std.testing.allocator;
    var renderer = CodeBlockRenderer.init(allocator, colors_mod.default, .{ .ctx = null, .func = null });
    defer renderer.deinit();

    const code = "const x = 1;";
    var spans = try renderer.render(code, null);
    defer spans.deinit(allocator);

    // Should have spans: padding + code content + newline + bottom padding
    try std.testing.expect(spans.items.len >= 3);

    // Find code content span
    var found_code = false;
    for (spans.items) |span| {
        if (std.mem.indexOf(u8, span.text, "const x = 1;") != null) {
            found_code = true;
            // Should have code block background
            try std.testing.expect(span.style.bg != .default);
            break;
        }
    }
    try std.testing.expect(found_code);
}

test "render code block with language" {
    const allocator = std.testing.allocator;
    var renderer = CodeBlockRenderer.init(allocator, colors_mod.default, .{ .ctx = null, .func = null });
    defer renderer.deinit();

    const code =
        \\def hello(name):
        \\    print(f"Hello, {name}!")
    ;
    var spans = try renderer.render(code, "python");
    defer spans.deinit(allocator);

    // Should have spans
    try std.testing.expect(spans.items.len >= 3);

    // Should include language label
    var found_lang = false;
    for (spans.items) |span| {
        if (std.mem.eql(u8, span.text, "python")) {
            found_lang = true;
            // Language label should have accent style
            try std.testing.expect(span.style.fg != .default);
            break;
        }
    }
    try std.testing.expect(found_lang);
}

test "type highlights use cyan accent" {
    const style = getStyleForHighlight(.{
        .start_byte = 0,
        .end_byte = 4,
        .category = "type",
    }, .{ .fg = .default, .bg = .default });

    try std.testing.expectEqual(vaxis.Color{ .index = 6 }, style.fg);
}

test "render unknown language falls back to plain" {
    const allocator = std.testing.allocator;
    var renderer = CodeBlockRenderer.init(allocator, colors_mod.default, .{ .ctx = null, .func = null });
    defer renderer.deinit();

    const code = "some code";
    var spans = try renderer.render(code, "unknownlang");
    defer spans.deinit(allocator);

    // Should still render with padding and content
    try std.testing.expect(spans.items.len >= 3);

    // Should include language label even if unknown (for display)
    var found_lang = false;
    for (spans.items) |span| {
        if (std.mem.eql(u8, span.text, "unknownlang")) {
            found_lang = true;
            break;
        }
    }
    try std.testing.expect(found_lang);
}

test "language detection - aliases" {
    // Common aliases should be normalized
    try std.testing.expectEqualStrings("python", CodeBlockRenderer.detectLanguage("py").?);
    try std.testing.expectEqualStrings("python", CodeBlockRenderer.detectLanguage("python").?);
    try std.testing.expectEqualStrings("javascript", CodeBlockRenderer.detectLanguage("js").?);
    try std.testing.expectEqualStrings("javascript", CodeBlockRenderer.detectLanguage("javascript").?);
    try std.testing.expectEqualStrings("typescript", CodeBlockRenderer.detectLanguage("ts").?);
    try std.testing.expectEqualStrings("typescript", CodeBlockRenderer.detectLanguage("typescript").?);
    try std.testing.expectEqualStrings("rust", CodeBlockRenderer.detectLanguage("rs").?);
    try std.testing.expectEqualStrings("rust", CodeBlockRenderer.detectLanguage("rust").?);
    try std.testing.expectEqualStrings("bash", CodeBlockRenderer.detectLanguage("sh").?);
    try std.testing.expectEqualStrings("bash", CodeBlockRenderer.detectLanguage("bash").?);
    try std.testing.expectEqualStrings("bash", CodeBlockRenderer.detectLanguage("shell").?);

    // Unknown languages should return the original (for display purposes)
    try std.testing.expectEqualStrings("unknownlang", CodeBlockRenderer.detectLanguage("unknownlang").?);

    // Empty string should return null
    try std.testing.expect(CodeBlockRenderer.detectLanguage("") == null);
}

test "empty code block" {
    const allocator = std.testing.allocator;
    var renderer = CodeBlockRenderer.init(allocator, colors_mod.default, .{ .ctx = null, .func = null });
    defer renderer.deinit();

    var spans = try renderer.render("", null);
    defer spans.deinit(allocator);

    // Should have at least top padding span
    try std.testing.expect(spans.items.len >= 1);

    // All spans should have code block background
    for (spans.items) |span| {
        if (span.node_type == .fenced_code_block) {
            try std.testing.expect(span.style.bg != .default);
        }
    }
}
