//! Agent UI Module
//!
//! Provides the agent chat panel for interacting with AI coding agents via ACP.
//!
//! Components:
//! - AgentState: Conversation history and panel state
//! - InputEditor: Vim-style text input for prompts
//! - TabManager: Multi-tab management for concurrent agents
//! - render: Panel rendering functions

const std = @import("std");

pub const state = @import("state.zig");
pub const input_editor = @import("input_editor.zig");
pub const tab_manager = @import("tab_manager.zig");
pub const render = @import("render.zig");
pub const command_palette = @import("command_palette.zig");
pub const agent_help = @import("agent_help.zig");

// Re-export main types for convenience
pub const AgentState = state.AgentState;
pub const Message = state.Message;
pub const InputEditor = input_editor.InputEditor;
pub const TabManager = tab_manager.TabManager;
pub const AgentTab = tab_manager.AgentTab;
pub const renderAgentPanel = render.renderAgentPanel;
pub const AgentCommandPaletteState = command_palette.AgentCommandPaletteState;

test {
    // Run all tests in submodules
    std.testing.refAllDecls(@This());
}
