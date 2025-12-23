const std = @import("std");
const vaxis = @import("vaxis");
const Allocator = std.mem.Allocator;
const vim_editor = @import("../editor/vim_editor.zig");

/// Agent Input Editor - Vim-style text input editor for agent prompts.
/// Uses the centralized VimEditor for full vim functionality.
pub const InputEditor = struct {
    pub const VimEditor = vim_editor.VimEditor(8192);

    /// Input editor state - wraps VimEditor.State
    pub const State = struct {
        vim: VimEditor.State,

        // Re-export vim types for compatibility
        pub const VimMode = VimEditor.State.VimMode;

        pub fn init() State {
            return .{
                .vim = VimEditor.State.init(),
            };
        }

        pub fn getText(self: *const State) []const u8 {
            return self.vim.getText();
        }

        pub fn clear(self: *State) void {
            self.vim.clear();
        }

        pub fn isEmpty(self: *const State) bool {
            return self.vim.isEmpty();
        }

        // Accessors for commonly used vim state fields
        pub fn getVimMode(self: *const State) VimMode {
            return self.vim.vim_mode;
        }

        pub fn getCursorPos(self: *const State) usize {
            return self.vim.cursor_pos;
        }
    };

    /// Action to take after handling key
    pub const Action = enum {
        send,
        cancel,
    };

    /// Handle key input based on current vim mode
    pub fn handleKey(state: *State, key: vaxis.Key, allocator: Allocator) !?Action {
        const result = try VimEditor.handleKey(&state.vim, key, allocator);
        if (result) |save_action| {
            return switch (save_action) {
                .save => if (state.vim.text_len > 0) .send else null,
                .cancel => .cancel,
            };
        }
        return null;
    }

    /// Public function to insert a character (used for paste handling)
    pub fn insertCharPublic(state: *State, char: u8) void {
        VimEditor.insertCharPublic(&state.vim, char);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "InputEditor init" {
    var state = InputEditor.State.init();
    try std.testing.expect(state.isEmpty());
    try std.testing.expectEqual(InputEditor.State.VimMode.insert, state.vim.vim_mode);
}

test "InputEditor insert characters" {
    var state = InputEditor.State.init();

    InputEditor.insertCharPublic(&state, 'h');
    InputEditor.insertCharPublic(&state, 'e');
    InputEditor.insertCharPublic(&state, 'l');
    InputEditor.insertCharPublic(&state, 'l');
    InputEditor.insertCharPublic(&state, 'o');

    try std.testing.expectEqualStrings("hello", state.getText());
    try std.testing.expectEqual(@as(usize, 5), state.vim.cursor_pos);
}

test "InputEditor clear" {
    var state = InputEditor.State.init();
    InputEditor.insertCharPublic(&state, 'a');
    InputEditor.insertCharPublic(&state, 'b');

    state.clear();

    try std.testing.expect(state.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), state.vim.cursor_pos);
}
