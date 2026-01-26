//! Fenced Code Block Rendering
//!
//! Handles rendering of fenced code blocks with visual boundaries
//! and language labels. Code blocks show:
//! - Top border with optional language label
//! - Monospace code content
//! - Bottom border

const std = @import("std");
const vaxis = @import("vaxis");
const types = @import("types.zig");
const colors_mod = @import("colors.zig");

const StyledSpan = types.StyledSpan;
const NodeType = types.NodeType;
const MarkdownColors = colors_mod.MarkdownColors;

/// Renderer for fenced code blocks
pub const CodeBlockRenderer = struct {
    allocator: std.mem.Allocator,
    colors: MarkdownColors,

    /// Initialize a new code block renderer
    pub fn init(allocator: std.mem.Allocator, md_colors: MarkdownColors) CodeBlockRenderer {
        return .{
            .allocator = allocator,
            .colors = md_colors,
        };
    }

    /// Render a fenced code block into styled spans
    /// Returns owned slice of spans
    pub fn render(self: *CodeBlockRenderer, code: []const u8, language_hint: ?[]const u8) !std.ArrayList(StyledSpan) {
        var spans: std.ArrayList(StyledSpan) = .{};
        errdefer spans.deinit(self.allocator);

        // Render top border with language label
        try self.renderTopBorder(&spans, language_hint);

        // Render code content
        try self.renderPlain(&spans, code);

        // Render bottom border
        try self.renderBottomBorder(&spans);

        return spans;
    }

    /// Render the top border with optional language label
    fn renderTopBorder(self: *CodeBlockRenderer, spans: *std.ArrayList(StyledSpan), language_hint: ?[]const u8) !void {
        if (language_hint) |lang| {
            if (lang.len > 0) {
                // Top border: ```language
                try spans.append(self.allocator, .{
                    .text = "```",
                    .style = self.colors.code_block_border,
                    .indent = 0,
                    .node_type = .fenced_code_block,
                });
                try spans.append(self.allocator, .{
                    .text = lang,
                    .style = self.colors.code_block_lang,
                    .indent = 0,
                    .node_type = .fenced_code_block,
                });
                try spans.append(self.allocator, .{
                    .text = "\n",
                    .style = self.colors.code_block_border,
                    .indent = 0,
                    .node_type = .softbreak,
                });
                return;
            }
        }

        // Top border without language: ```
        try spans.append(self.allocator, .{
            .text = "```\n",
            .style = self.colors.code_block_border,
            .indent = 0,
            .node_type = .fenced_code_block,
        });
    }

    /// Render the bottom border
    fn renderBottomBorder(self: *CodeBlockRenderer, spans: *std.ArrayList(StyledSpan)) !void {
        try spans.append(self.allocator, .{
            .text = "```",
            .style = self.colors.code_block_border,
            .indent = 0,
            .node_type = .fenced_code_block,
        });
    }

    /// Render plain (unstyled) code content with code block background
    fn renderPlain(self: *CodeBlockRenderer, spans: *std.ArrayList(StyledSpan), code: []const u8) !void {
        if (code.len == 0) {
            return;
        }

        // Style for code content: text color with code block background
        const code_style = vaxis.Style{
            .fg = self.colors.text.fg,
            .bg = self.colors.code_block_bg,
        };

        // Emit code content, preserving newlines
        try spans.append(self.allocator, .{
            .text = code,
            .style = code_style,
            .indent = 0,
            .node_type = .fenced_code_block,
        });

        // Add newline after code if not already ending with one
        if (code.len > 0 and code[code.len - 1] != '\n') {
            try spans.append(self.allocator, .{
                .text = "\n",
                .style = self.colors.code_block_border,
                .indent = 0,
                .node_type = .softbreak,
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
        });

        // Return normalized language or the original if not in map
        return alias_map.get(info_string) orelse info_string;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "render plain code block" {
    const allocator = std.testing.allocator;
    var renderer = CodeBlockRenderer.init(allocator, colors_mod.default);

    const code = "const x = 1;";
    var spans = try renderer.render(code, null);
    defer spans.deinit(allocator);

    // Should have at least: top border, code content, bottom border
    try std.testing.expect(spans.items.len >= 3);

    // Find code content span
    var found_code = false;
    for (spans.items) |span| {
        if (std.mem.indexOf(u8, span.text, "const x = 1;") != null) {
            found_code = true;
            break;
        }
    }
    try std.testing.expect(found_code);

    // First span should be top border (contains ```)
    try std.testing.expect(std.mem.indexOf(u8, spans.items[0].text, "```") != null);

    // Last span should be bottom border (contains ```)
    try std.testing.expect(std.mem.indexOf(u8, spans.items[spans.items.len - 1].text, "```") != null);
}

test "render code block with language" {
    const allocator = std.testing.allocator;
    var renderer = CodeBlockRenderer.init(allocator, colors_mod.default);

    const code =
        \\def hello(name):
        \\    print(f"Hello, {name}!")
    ;
    var spans = try renderer.render(code, "python");
    defer spans.deinit(allocator);

    // Should have spans
    try std.testing.expect(spans.items.len >= 3);

    // Top border should include language label
    var found_lang = false;
    for (spans.items) |span| {
        if (std.mem.indexOf(u8, span.text, "python") != null) {
            found_lang = true;
            // Language label should have accent style
            try std.testing.expect(span.style.fg != .default);
            break;
        }
    }
    try std.testing.expect(found_lang);
}

test "render unknown language falls back to plain" {
    const allocator = std.testing.allocator;
    var renderer = CodeBlockRenderer.init(allocator, colors_mod.default);

    const code = "some code";
    var spans = try renderer.render(code, "unknownlang");
    defer spans.deinit(allocator);

    // Should still render with borders
    try std.testing.expect(spans.items.len >= 3);

    // Should include language in top border even if unknown
    var found_lang = false;
    for (spans.items) |span| {
        if (std.mem.indexOf(u8, span.text, "unknownlang") != null) {
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
    var renderer = CodeBlockRenderer.init(allocator, colors_mod.default);

    var spans = try renderer.render("", null);
    defer spans.deinit(allocator);

    // Should have at least borders
    try std.testing.expect(spans.items.len >= 2);

    // Should have top border
    try std.testing.expect(std.mem.indexOf(u8, spans.items[0].text, "```") != null);

    // Should have bottom border
    try std.testing.expect(std.mem.indexOf(u8, spans.items[spans.items.len - 1].text, "```") != null);
}
