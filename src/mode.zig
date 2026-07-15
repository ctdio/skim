//! The modal state enum for the application.
//!
//! Extracted into its own file so lightweight modules (e.g. mouse-wheel
//! routing) can depend on the mode set without pulling in all of app.zig's
//! rendering and git dependencies.

pub const Mode = enum {
    normal, // Normal navigation and viewing
    comment, // Comment editing
    search, // Search input
    visual, // Visual selection mode
    command_palette, // Command palette
    help, // Help overlay
    branch_selection, // Branch selection menu (when empty)
    commit_selection, // Commit selection menu
    commit_diff_mode, // Submenu to select diff mode after commit selection
    graphite_stack, // Graphite stack picker
    agent, // Agent chat panel
    model_selection, // AI model selection menu
    permission_selection, // Codex permission mode menu
    agent_selection, // Agent selection menu (before connecting)
    session_picker, // Session picker for /resume command
};
