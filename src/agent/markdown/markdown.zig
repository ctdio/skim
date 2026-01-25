//! Markdown Parsing and Rendering Module
//!
//! Provides tree-sitter based markdown parsing and styled rendering for agent messages.
//!
//! Components:
//! - types: Markdown AST node types and styled span structures
//! - parser: Incremental tree-sitter markdown parser wrapper
//! - colors: Markdown-specific color/style definitions
//! - renderer: AST traversal and styled span generation
//! - code_blocks: Fenced code block rendering with borders and language labels

const std = @import("std");

pub const types = @import("types.zig");
pub const parser = @import("parser.zig");
pub const colors = @import("colors.zig");
pub const renderer = @import("renderer.zig");
pub const code_blocks = @import("code_blocks.zig");

// Re-export main types for convenience
pub const NodeType = types.NodeType;
pub const StyledSpan = types.StyledSpan;
pub const MarkdownParser = parser.MarkdownParser;
pub const ParseError = parser.ParseError;
pub const MarkdownColors = colors.MarkdownColors;
pub const MarkdownRenderer = renderer.MarkdownRenderer;
pub const CodeBlockRenderer = code_blocks.CodeBlockRenderer;

test {
    // Run all tests in submodules
    std.testing.refAllDecls(@This());
}
