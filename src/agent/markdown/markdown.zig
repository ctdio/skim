//! Markdown Parsing Module
//!
//! Provides tree-sitter based markdown parsing infrastructure for agent messages.
//!
//! Components:
//! - types: Markdown AST node types and styled span structures
//! - parser: Incremental tree-sitter markdown parser wrapper

const std = @import("std");

pub const types = @import("types.zig");
pub const parser = @import("parser.zig");

// Re-export main types for convenience
pub const NodeType = types.NodeType;
pub const StyledSpan = types.StyledSpan;
pub const MarkdownParser = parser.MarkdownParser;
pub const ParseError = parser.ParseError;

test {
    // Run all tests in submodules
    std.testing.refAllDecls(@This());
}
