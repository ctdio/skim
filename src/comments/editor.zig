const std = @import("std");
const vaxis = @import("vaxis");
const Allocator = std.mem.Allocator;
const vim_editor = @import("../editor/vim_editor.zig");

/// CommentEditor - Vim-style comment editing with modal interface.
/// Uses the centralized VimEditor for core vim functionality.
pub const CommentEditor = struct {
    pub const VimEditor = vim_editor.VimEditor(4096);

    /// Active comment input state.
    /// Contains comment-specific targeting info plus embedded vim state.
    pub const State = struct {
        // Comment-specific targeting
        target_file_path: []const u8,
        target_hunk_idx: usize,
        target_line_idx: usize,
        target_end_hunk_idx: ?usize,
        target_end_line_idx: ?usize,
        editing_comment_idx: ?usize,

        // Embedded vim state
        vim: VimEditor.State,

        // Re-export vim types for compatibility
        pub const VimMode = VimEditor.State.VimMode;
        pub const PendingFind = VimEditor.State.PendingFind;
        pub const PendingOperator = VimEditor.State.PendingOperator;
        pub const TextObject = VimEditor.State.TextObject;
        pub const UndoState = VimEditor.State.UndoState;
        pub const LastFind = VimEditor.State.LastFind;
        pub const LastChange = VimEditor.State.LastChange;
    };

    pub const SaveAction = VimEditor.SaveAction;

    /// Handle key input based on current vim mode.
    /// Returns SaveAction if the editor should exit.
    pub fn handleKey(state: *State, key: vaxis.Key, allocator: Allocator) !?SaveAction {
        return VimEditor.handleKey(&state.vim, key, allocator);
    }

    /// Public function to insert a character (used for paste handling).
    pub fn insertCharPublic(state: *State, char: u8) void {
        VimEditor.insertCharPublic(&state.vim, char);
    }
};
