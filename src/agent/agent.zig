//! Agent UI Module
//!
//! Provides the agent chat panel for interacting with AI coding agents via ACP.
//!
//! Components:
//! - AgentState: Conversation history and panel state
//! - InputEditor: Vim-style text input for prompts
//! - render: Panel rendering functions

const std = @import("std");

pub const state = @import("state.zig");
pub const input_editor = @import("input_editor.zig");
pub const render = @import("render.zig");

// Re-export main types for convenience
pub const AgentState = state.AgentState;
pub const Message = state.Message;
pub const InputEditor = input_editor.InputEditor;
pub const renderAgentPanel = render.renderAgentPanel;

test {
    // Run all tests in submodules
    std.testing.refAllDecls(@This());
}
