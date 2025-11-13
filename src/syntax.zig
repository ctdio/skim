const std = @import("std");
const zts = @import("zts");

// Embed highlight query files at compile time
// Programming languages
const JAVASCRIPT_HIGHLIGHTS = @embedFile("queries/javascript.scm");
const TYPESCRIPT_HIGHLIGHTS = @embedFile("queries/typescript.scm");
const PYTHON_HIGHLIGHTS = @embedFile("queries/python.scm");
const RUST_HIGHLIGHTS = @embedFile("queries/rust.scm");
const GO_HIGHLIGHTS = @embedFile("queries/go.scm");
const ZIG_HIGHLIGHTS = @embedFile("queries/zig.scm");
const C_HIGHLIGHTS = @embedFile("queries/c.scm");
const CPP_HIGHLIGHTS = @embedFile("queries/cpp.scm");
// Common file formats
const JSON_HIGHLIGHTS = @embedFile("queries/json.scm");
const TOML_HIGHLIGHTS = @embedFile("queries/toml.scm");
const MARKDOWN_HIGHLIGHTS = @embedFile("queries/markdown.scm");
const CSS_HIGHLIGHTS = @embedFile("queries/css.scm");
const BASH_HIGHLIGHTS = @embedFile("queries/bash.scm");

// Supported languages and file formats for syntax highlighting
pub const Language = enum {
    // Programming languages
    javascript,
    typescript,
    python,
    rust,
    go,
    zig,
    c,
    cpp,
    // Common file formats
    json,
    toml,
    markdown,
    css,
    bash,
    unknown,

    pub fn fromFilePath(path: []const u8) Language {
        const ext = std.fs.path.extension(path);

        // Extension mapping using compile-time string map for performance
        const ext_map = std.StaticStringMap(Language).initComptime(.{
            // JavaScript
            .{ ".js", .javascript },
            .{ ".jsx", .javascript },
            .{ ".mjs", .javascript },
            .{ ".cjs", .javascript },

            // TypeScript
            .{ ".ts", .typescript },
            .{ ".tsx", .typescript },
            .{ ".mts", .typescript },
            .{ ".cts", .typescript },

            // Python
            .{ ".py", .python },
            .{ ".pyi", .python },
            .{ ".pyw", .python },

            // Rust
            .{ ".rs", .rust },

            // Go
            .{ ".go", .go },

            // Zig
            .{ ".zig", .zig },

            // C
            .{ ".c", .c },
            .{ ".h", .c },

            // C++
            .{ ".cpp", .cpp },
            .{ ".cc", .cpp },
            .{ ".cxx", .cpp },
            .{ ".hpp", .cpp },
            .{ ".hxx", .cpp },
            .{ ".hh", .cpp },
            .{ ".C", .cpp },
            .{ ".H", .cpp },

            // JSON
            .{ ".json", .json },
            .{ ".jsonc", .json },
            .{ ".json5", .json },

            // TOML
            .{ ".toml", .toml },

            // Markdown
            .{ ".md", .markdown },
            .{ ".markdown", .markdown },
            .{ ".mdown", .markdown },
            .{ ".mkd", .markdown },
            .{ ".mkdn", .markdown },

            // CSS
            .{ ".css", .css },

            // Bash
            .{ ".sh", .bash },
            .{ ".bash", .bash },
            .{ ".zsh", .bash },
        });

        if (ext_map.get(ext)) |lang| {
            return lang;
        }

        // Check for files without extensions or special filenames
        const basename = std.fs.path.basename(path);
        if (std.mem.eql(u8, basename, "Makefile")) return .c;
        if (std.mem.eql(u8, basename, "Dockerfile")) return .bash;
        if (std.mem.eql(u8, basename, ".bashrc")) return .bash;
        if (std.mem.eql(u8, basename, ".bash_profile")) return .bash;
        if (std.mem.eql(u8, basename, ".zshrc")) return .bash;
        if (std.mem.eql(u8, basename, ".zprofile")) return .bash;

        return .unknown;
    }

    pub fn getName(self: Language) []const u8 {
        return switch (self) {
            .javascript => "JavaScript",
            .typescript => "TypeScript",
            .python => "Python",
            .rust => "Rust",
            .go => "Go",
            .zig => "Zig",
            .c => "C",
            .cpp => "C++",
            .json => "JSON",
            .toml => "TOML",
            .markdown => "Markdown",
            .css => "CSS",
            .bash => "Bash",
            .unknown => "Unknown",
        };
    }
};

// Represents a highlighted segment of text
pub const Highlight = struct {
    start_byte: usize,
    end_byte: usize,
    category: []const u8, // e.g., "@keyword", "@function", "@string"

    // Color index for 8-color terminal palette
    pub const ColorIndex = enum(u8) {
        black = 0,
        red = 1,
        green = 2,
        yellow = 3,
        blue = 4,
        magenta = 5,
        cyan = 6,
        white = 7,
    };

    // Map tree-sitter capture category to a terminal color
    // GitHub-inspired color scheme
    pub fn getColor(self: Highlight) ColorIndex {
        const cat = self.category;

        // Keywords - Orange (GitHub style: #d73a49)
        if (std.mem.eql(u8, cat, "keyword") or
            std.mem.eql(u8, cat, "keyword.control") or
            std.mem.eql(u8, cat, "keyword.function") or
            std.mem.eql(u8, cat, "keyword.return") or
            std.mem.eql(u8, cat, "keyword.operator"))
        {
            return .red; // Use red for orange-ish appearance
        }

        // Functions and methods - Magenta/Purple (GitHub style: #6f42c1)
        if (std.mem.eql(u8, cat, "function") or
            std.mem.eql(u8, cat, "function.call") or
            std.mem.eql(u8, cat, "function.method") or
            std.mem.eql(u8, cat, "function.builtin"))
        {
            return .magenta;
        }

        // Types/Classes - Yellow (GitHub style: #e36209)
        if (std.mem.eql(u8, cat, "type") or
            std.mem.eql(u8, cat, "type.builtin") or
            std.mem.eql(u8, cat, "type.definition") or
            std.mem.eql(u8, cat, "constructor"))
        {
            return .yellow;
        }

        // Strings - Blue (GitHub style: #032f62)
        if (std.mem.eql(u8, cat, "string") or
            std.mem.eql(u8, cat, "string.special"))
        {
            return .blue;
        }

        // Numbers - Blue (GitHub style: #005cc5)
        if (std.mem.eql(u8, cat, "number") or
            std.mem.eql(u8, cat, "constant.numeric"))
        {
            return .blue;
        }

        // Comments - Dark gray (GitHub style: #6a737d)
        if (std.mem.eql(u8, cat, "comment") or
            std.mem.eql(u8, cat, "comment.line") or
            std.mem.eql(u8, cat, "comment.block"))
        {
            return .black;
        }

        // Constants - Blue (GitHub style: #005cc5)
        if (std.mem.eql(u8, cat, "constant") or
            std.mem.eql(u8, cat, "constant.builtin") or
            std.mem.eql(u8, cat, "boolean"))
        {
            return .blue;
        }

        // Operators (white/default)
        if (std.mem.eql(u8, cat, "operator")) {
            return .white;
        }

        // Variables and parameters (white/default)
        if (std.mem.eql(u8, cat, "variable") or
            std.mem.eql(u8, cat, "variable.parameter") or
            std.mem.eql(u8, cat, "variable.builtin") or
            std.mem.eql(u8, cat, "property"))
        {
            return .white;
        }

        // Default for unknown categories
        return .white;
    }
};

// Cached parser and query for a language
const LanguageCache = struct {
    parser: *zts.Parser,
    query: *zts.Query,
};

// Manages syntax highlighting for multiple files
pub const SyntaxHighlighter = struct {
    allocator: std.mem.Allocator,
    // Cache parsers and queries by language for performance
    cache: std.AutoHashMap(Language, LanguageCache),

    pub fn init(allocator: std.mem.Allocator) !SyntaxHighlighter {
        return .{
            .allocator = allocator,
            .cache = std.AutoHashMap(Language, LanguageCache).init(allocator),
        };
    }

    pub fn deinit(self: *SyntaxHighlighter) void {
        // Free all cached parsers and queries
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.parser.deinit();
            entry.value_ptr.query.deinit();
        }
        self.cache.deinit();
    }

    // Free highlights returned by highlightFile/highlightContent
    pub fn freeHighlights(self: *SyntaxHighlighter, highlights: []Highlight) void {
        // Free each category string (they were duplicated during parsing)
        for (highlights) |h| {
            self.allocator.free(h.category);
        }
        self.allocator.free(highlights);
    }

    // Check if a language's parser/query is already cached (fast path available)
    pub fn isCached(self: *SyntaxHighlighter, file_path: []const u8) bool {
        const lang = Language.fromFilePath(file_path);
        if (lang == .unknown) return false;
        return self.cache.contains(lang);
    }

    // Ensure parser/query is cached for a language (doesn't generate highlights)
    pub fn ensureCached(self: *SyntaxHighlighter, file_path: []const u8) void {
        const lang = Language.fromFilePath(file_path);
        if (lang == .unknown) return;

        // This will create and cache the parser if not already cached
        _ = self.getOrCreateCache(lang) catch return;
    }

    // Highlights a file's content and returns array of highlight ranges
    pub fn highlightFile(
        self: *SyntaxHighlighter,
        file_path: []const u8,
        content: []const u8,
    ) ![]Highlight {
        const lang = Language.fromFilePath(file_path);

        if (lang == .unknown) {
            // No highlighting for unknown languages
            return &[_]Highlight{};
        }

        return try self.highlightContent(lang, content);
    }

    // Get or create cached parser and query for a language
    fn getOrCreateCache(self: *SyntaxHighlighter, lang: Language) !*LanguageCache {
        // Check if already cached
        if (self.cache.getPtr(lang)) |cached| {
            return cached;
        }

        // Not cached - create new parser and query
        const ts_lang = switch (lang) {
            .javascript => try zts.loadLanguage(.javascript),
            .typescript => try zts.loadLanguage(.typescript),
            .python => try zts.loadLanguage(.python),
            .rust => try zts.loadLanguage(.rust),
            .go => try zts.loadLanguage(.go),
            .zig => try zts.loadLanguage(.zig),
            .c => try zts.loadLanguage(.c),
            .cpp => try zts.loadLanguage(.cpp),
            .json => try zts.loadLanguage(.json),
            .toml => try zts.loadLanguage(.toml),
            .markdown => try zts.loadLanguage(.markdown),
            .css => try zts.loadLanguage(.css),
            .bash => try zts.loadLanguage(.bash),
            .unknown => unreachable,
        };

        // Get query string
        // TypeScript needs both JS and TS queries combined since TS is a superset of JS
        var combined_query: []const u8 = undefined;
        var needs_free = false;

        const query_str = switch (lang) {
            .javascript => JAVASCRIPT_HIGHLIGHTS,
            .typescript => blk: {
                // Combine JavaScript and TypeScript queries
                const combined = try std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{
                    JAVASCRIPT_HIGHLIGHTS,
                    TYPESCRIPT_HIGHLIGHTS,
                });
                combined_query = combined;
                needs_free = true;
                break :blk combined;
            },
            .python => PYTHON_HIGHLIGHTS,
            .rust => RUST_HIGHLIGHTS,
            .go => GO_HIGHLIGHTS,
            .zig => ZIG_HIGHLIGHTS,
            .c => C_HIGHLIGHTS,
            .cpp => blk: {
                // C++ needs both C and C++ queries combined
                const combined = try std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{
                    C_HIGHLIGHTS,
                    CPP_HIGHLIGHTS,
                });
                combined_query = combined;
                needs_free = true;
                break :blk combined;
            },
            .json => JSON_HIGHLIGHTS,
            .toml => TOML_HIGHLIGHTS,
            .markdown => MARKDOWN_HIGHLIGHTS,
            .css => CSS_HIGHLIGHTS,
            .bash => BASH_HIGHLIGHTS,
            .unknown => unreachable,
        };

        defer if (needs_free) self.allocator.free(combined_query);

        // Create parser (init already returns a pointer)
        const parser = zts.Parser.init() catch {
            return error.ParserInitFailed;
        };
        errdefer parser.deinit();

        parser.setLanguage(ts_lang) catch {
            parser.deinit();
            return error.LanguageSetFailed;
        };

        // Create query (init already returns a pointer)
        const query = zts.Query.init(ts_lang, query_str) catch {
            parser.deinit();
            return error.QueryInitFailed;
        };

        // Store in cache
        try self.cache.put(lang, .{
            .parser = parser,
            .query = query,
        });

        // Return pointer to cached entry
        return self.cache.getPtr(lang).?;
    }

    // Highlights content for a specific language
    fn highlightContent(
        self: *SyntaxHighlighter,
        lang: Language,
        content: []const u8,
    ) ![]Highlight {
        // Get cached parser and query (or create if first time)
        const cache = self.getOrCreateCache(lang) catch {
            return &[_]Highlight{};
        };

        // Parse the content using cached parser
        const tree = cache.parser.parseString(null, content) catch {
            return &[_]Highlight{};
        };
        defer tree.deinit();

        // Execute query using cached query
        var cursor = zts.QueryCursor.init() catch {
            return &[_]Highlight{};
        };
        defer cursor.deinit();

        const root = tree.rootNode();
        cursor.exec(cache.query, root);

        // Collect all captures into highlights
        var highlights = std.ArrayList(Highlight).init(self.allocator);
        errdefer highlights.deinit();

        var match: zts.QueryMatch = undefined;
        while (cursor.nextMatch(&match)) {
            // Convert pointer to slice
            const captures_slice = @as([*]const zts.QueryCapture, @ptrCast(match.captures))[0..match.capture_count];

            for (captures_slice) |capture| {
                const node = capture.node;

                // captureNameForId needs a length pointer
                var length: u32 = 0;
                const capture_name_opt = cache.query.captureNameForId(capture.index, &length);
                if (capture_name_opt == null) continue;

                const capture_name = capture_name_opt.?;

                if (capture_name.len == 0) continue;

                // IMPORTANT: duplicate the category string!
                // capture_name points to memory inside the Query object,
                // which is now cached and persists for the lifetime of SyntaxHighlighter
                const category_copy = try self.allocator.dupe(u8, capture_name);

                try highlights.append(.{
                    .start_byte = node.getStartByte(),
                    .end_byte = node.getEndByte(),
                    .category = category_copy,
                });
            }
        }

        return highlights.toOwnedSlice();
    }
};

// Tests
test "Language detection from file extensions" {
    try std.testing.expectEqual(Language.javascript, Language.fromFilePath("app.js"));
    try std.testing.expectEqual(Language.javascript, Language.fromFilePath("src/component.jsx"));
    try std.testing.expectEqual(Language.typescript, Language.fromFilePath("index.ts"));
    try std.testing.expectEqual(Language.typescript, Language.fromFilePath("Component.tsx"));
    try std.testing.expectEqual(Language.python, Language.fromFilePath("script.py"));
    try std.testing.expectEqual(Language.rust, Language.fromFilePath("main.rs"));
    try std.testing.expectEqual(Language.go, Language.fromFilePath("server.go"));
    try std.testing.expectEqual(Language.zig, Language.fromFilePath("build.zig"));
    try std.testing.expectEqual(Language.c, Language.fromFilePath("program.c"));
    try std.testing.expectEqual(Language.c, Language.fromFilePath("header.h"));
    try std.testing.expectEqual(Language.cpp, Language.fromFilePath("app.cpp"));
    try std.testing.expectEqual(Language.cpp, Language.fromFilePath("lib.hpp"));
    try std.testing.expectEqual(Language.unknown, Language.fromFilePath("README.md"));
}

test "Language detection for special filenames" {
    try std.testing.expectEqual(Language.c, Language.fromFilePath("Makefile"));
    try std.testing.expectEqual(Language.c, Language.fromFilePath("src/Makefile"));
}

test "SyntaxHighlighter initialization" {
    const allocator = std.testing.allocator;
    var highlighter = try SyntaxHighlighter.init(allocator);
    defer highlighter.deinit();
}

test "Highlight simple JavaScript code" {
    const allocator = std.testing.allocator;
    var highlighter = try SyntaxHighlighter.init(allocator);
    defer highlighter.deinit();

    const js_code = "const x = 123;";
    const highlights = try highlighter.highlightContent(.javascript, js_code);
    defer highlighter.freeHighlights(highlights);

    // Debug output
    std.debug.print("\n=== JS Highlights: '{s}' ===\n", .{js_code});
    std.debug.print("Total: {}\n", .{highlights.len});
    for (highlights) |h| {
        const text = js_code[h.start_byte..h.end_byte];
        std.debug.print("  '{s}' -> {s}\n", .{ text, h.category });
    }

    // Should return highlights for keywords, variables, and numbers
    try std.testing.expect(highlights.len > 0);

    // Verify we have at least one keyword capture (for "const")
    var found_keyword = false;
    for (highlights) |h| {
        if (std.mem.eql(u8, h.category, "keyword")) {
            found_keyword = true;
            break;
        }
    }
    try std.testing.expect(found_keyword);
}

test "Highlight TypeScript with types" {
    const allocator = std.testing.allocator;
    var highlighter = try SyntaxHighlighter.init(allocator);
    defer highlighter.deinit();

    const ts_code =
        \\function greet(name: string): void {
        \\  console.log(name);
        \\}
    ;
    const highlights = try highlighter.highlightContent(.typescript, ts_code);
    defer highlighter.freeHighlights(highlights);

    try std.testing.expect(highlights.len > 0);

    // Should have keyword "function"
    var found_function_keyword = false;
    for (highlights) |h| {
        if (std.mem.eql(u8, h.category, "keyword.function")) {
            found_function_keyword = true;
            break;
        }
    }
    try std.testing.expect(found_function_keyword);
}

test "Highlight Zig code" {
    const allocator = std.testing.allocator;
    var highlighter = try SyntaxHighlighter.init(allocator);
    defer highlighter.deinit();

    const zig_code =
        \\const std = @import("std");
        \\pub fn main() void {
        \\    const x: u32 = 42;
        \\}
    ;
    const highlights = try highlighter.highlightContent(.zig, zig_code);
    defer highlighter.freeHighlights(highlights);

    try std.testing.expect(highlights.len > 0);

    // Should have keyword "const"
    var found_const = false;
    for (highlights) |h| {
        if (std.mem.eql(u8, h.category, "keyword")) {
            found_const = true;
            break;
        }
    }
    try std.testing.expect(found_const);
}

test "Debug JavaScript highlights" {
    const allocator = std.testing.allocator;
    var highlighter = try SyntaxHighlighter.init(allocator);
    defer highlighter.deinit();

    const js_code =
        \\const message = "Hello World";
        \\function greet(name) {
        \\  console.log(name);
        \\  return name;
        \\}
    ;

    const highlights = try highlighter.highlightContent(.javascript, js_code);
    defer highlighter.freeHighlights(highlights);

    std.debug.print("\n\n=== JavaScript Highlights Debug ===\n", .{});
    std.debug.print("Total highlights: {}\n", .{highlights.len});
    std.debug.print("\nCode:\n{s}\n\n", .{js_code});
    std.debug.print("Highlights:\n", .{});
    for (highlights) |h| {
        const text = js_code[h.start_byte..h.end_byte];
        std.debug.print("  [{d:3}-{d:3}] '{s:<15}' -> {s}\n", .{ h.start_byte, h.end_byte, text, h.category });
    }
    std.debug.print("===================================\n\n", .{});
}
