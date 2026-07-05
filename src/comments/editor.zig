const std = @import("std");
const vaxis = @import("vaxis");
const Allocator = std.mem.Allocator;
const vim_editor = @import("../editor/vim_editor.zig");

/// CommentEditor - Vim-style comment editing with modal interface.
/// Uses the centralized VimEditor for core vim functionality.
pub const CommentEditor = struct {
    pub const VimEditor = vim_editor.VimEditor(4096);

    /// Where a saved comment is written: a local skim comment, or a GitHub draft
    /// review comment posted to the active PR session (AD-7).
    pub const Target = enum { local, github };

    /// Conversation context for editors opened on an existing GitHub review
    /// thread (FR-5). `.none` is the ordinary diff-line comment editor (routed by
    /// `Target`); `.reply`/`.edit_own` short-circuit the diff-coordinate save path
    /// and dispatch a thread mutation instead. Targets are keyed by GitHub node id
    /// (not positional index) so a thread/comment removed under a concurrent
    /// mutation while the editor is open re-resolves correctly at save time. The id
    /// slices borrow the target thread's session-owned/arena strings, which stay
    /// valid for the editor's lifetime (the target is never refetched away in
    /// comment mode and cannot be removed by a mutation on another thread).
    pub const EditContext = union(enum) {
        none,
        reply: struct { thread_id: []const u8 },
        edit_own: struct { thread_id: []const u8, comment_id: []const u8 },
    };

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
        // Destination of the saved comment (set when the editor is opened).
        target: Target = .local,
        // Thread-conversation context (reply/edit on a GitHub thread), or `.none`.
        edit_context: EditContext = .none,

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
