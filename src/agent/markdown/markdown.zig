//! Markdown Parsing and Rendering Module
//!
//! Provides tree-sitter based markdown parsing and styled rendering for agent messages.
//!
//! Components:
//! - types: Markdown AST node types and styled span structures
//! - parser: Incremental tree-sitter markdown parser wrapper
//! - colors: Markdown-specific color/style definitions
//! - renderer: AST traversal and styled span generation

const std = @import("std");

pub const types = @import("types.zig");
pub const parser = @import("parser.zig");
pub const colors = @import("colors.zig");
pub const renderer = @import("renderer.zig");

// Re-export main types for convenience
pub const NodeType = types.NodeType;
pub const StyledSpan = types.StyledSpan;
pub const MarkdownParser = parser.MarkdownParser;
pub const ParseError = parser.ParseError;
pub const MarkdownColors = colors.MarkdownColors;
pub const MarkdownRenderer = renderer.MarkdownRenderer;

test {
    // Run all tests in submodules
    std.testing.refAllDecls(@This());
}
