//! Compile-time target facts that the rest of the tree branches on.
//!
//! The web build (`zig build web`) compiles skim to wasm, where there are no
//! processes, threads, sockets, or a terminal. Code that a web build reaches
//! must not resolve those types or call those functions.

const builtin = @import("builtin");
const std = @import("std");

/// True when the current target is wasm, i.e. the browser build.
pub const is_web = builtin.target.cpu.arch.isWasm();

/// Tree-sitter grammars the web build links. The parse tables are about 90% of
/// the wasm module, and C++ alone is 5.5 MB, so the browser ships only the
/// languages the demo needs. Every other language falls back to plain text with
/// diff colours. `build.zig` reads this list to pick which grammars to compile
/// for the wasm target, so the two stay in step.
pub const web_grammars = [_][]const u8{
    "javascript",
    "typescript",
    "python",
    "rust",
    "go",
    "zig",
    "markdown",
    "markdown_inline",
};

/// Grammars linked for something other than diff highlighting.
const web_highlight_grammars = [_][]const u8{
    "javascript",
    "typescript",
    "python",
    "rust",
    "go",
    "zig",
};

/// True when the current build links the named tree-sitter grammar.
pub fn linksGrammar(comptime name: []const u8) bool {
    if (!is_web) return true;
    for (web_highlight_grammars) |grammar| {
        if (comptime std.mem.eql(u8, grammar, name)) return true;
    }
    return false;
}
