const std = @import("std");
const vaxis = @import("vaxis");
const Allocator = std.mem.Allocator;

// =============================================================================
// Agent Input Editor
// =============================================================================

/// Vim-style text input editor for agent prompts.
/// Adapted from CommentEditor with focus on prompt input.
pub const InputEditor = struct {
    /// Input editor state
    pub const State = struct {
        text_buffer: [8192]u8, // Larger buffer for prompts
        text_len: usize,
        cursor_pos: usize,
        vim_mode: VimMode,
        visual_anchor: ?usize,
        yank_buffer: [8192]u8,
        yank_len: usize,
        undo_stack: [32]UndoState,
        undo_count: usize,
        undo_index: usize,

        pub const VimMode = enum {
            normal,
            insert,
            visual,
        };

        pub const UndoState = struct {
            text: [8192]u8,
            text_len: usize,
            cursor_pos: usize,
        };

        /// Initialize empty input state
        pub fn init() State {
            var state: State = undefined;
            @memset(&state.text_buffer, 0);
            @memset(&state.yank_buffer, 0);
            state.text_len = 0;
            state.cursor_pos = 0;
            state.vim_mode = .insert; // Start in insert mode for quick typing
            state.visual_anchor = null;
            state.yank_len = 0;
            state.undo_count = 0;
            state.undo_index = 0;
            return state;
        }

        /// Get the current text content
        pub fn getText(self: *const State) []const u8 {
            return self.text_buffer[0..self.text_len];
        }

        /// Clear the input buffer
        pub fn clear(self: *State) void {
            @memset(&self.text_buffer, 0);
            self.text_len = 0;
            self.cursor_pos = 0;
            self.vim_mode = .insert;
            self.visual_anchor = null;
        }

        /// Check if buffer is empty
        pub fn isEmpty(self: *const State) bool {
            return self.text_len == 0;
        }
    };

    /// Action to take after handling key
    pub const Action = enum {
        send, // Send the prompt
        cancel, // Cancel/hide panel
    };

    /// Handle key input based on current vim mode
    pub fn handleKey(state: *State, key: vaxis.Key, allocator: Allocator) !?Action {
        _ = allocator;

        // Ctrl+S - send prompt (works in all modes)
        if (key.mods.ctrl and key.codepoint == 's') {
            if (state.text_len > 0) {
                return .send;
            }
            return null;
        }

        // Dispatch based on vim mode
        switch (state.vim_mode) {
            .normal => return handleNormalMode(state, key),
            .insert => return handleInsertMode(state, key),
            .visual => return handleVisualMode(state, key),
        }
    }

    // =========================================================================
    // Normal Mode
    // =========================================================================

    fn handleNormalMode(state: *State, key: vaxis.Key) ?Action {
        // Ctrl+R for redo
        if (key.mods.ctrl and key.codepoint == 'r') {
            performRedo(state);
            return null;
        }

        switch (key.codepoint) {
            // Mode changes
            'i' => state.vim_mode = .insert,
            'a' => {
                if (state.cursor_pos < state.text_len) {
                    state.cursor_pos += 1;
                }
                state.vim_mode = .insert;
            },
            'A' => {
                state.cursor_pos = findLineEnd(state.*);
                state.vim_mode = .insert;
            },
            'I' => {
                state.cursor_pos = findLineStart(state.*);
                state.vim_mode = .insert;
            },
            'o' => {
                // Open line below
                state.cursor_pos = findLineEnd(state.*);
                insertChar(state, '\n');
                state.vim_mode = .insert;
            },
            'O' => {
                // Open line above
                state.cursor_pos = findLineStart(state.*);
                insertChar(state, '\n');
                if (state.cursor_pos > 0) {
                    state.cursor_pos -= 1;
                }
                state.vim_mode = .insert;
            },
            'v' => {
                state.vim_mode = .visual;
                state.visual_anchor = state.cursor_pos;
            },

            // Navigation
            'h' => if (state.cursor_pos > 0) {
                state.cursor_pos -= 1;
            },
            'l' => if (state.cursor_pos < state.text_len) {
                state.cursor_pos += 1;
            },
            'j' => moveCursorDown(state),
            'k' => moveCursorUp(state),
            'w' => state.cursor_pos = findNextWordStart(state.*),
            'e' => state.cursor_pos = findWordEnd(state.*),
            'b' => state.cursor_pos = findPrevWordStart(state.*),
            '0' => state.cursor_pos = findLineStart(state.*),
            '$' => state.cursor_pos = findLineEnd(state.*),
            '^' => {
                // First non-whitespace character
                var pos = findLineStart(state.*);
                while (pos < state.text_len and (state.text_buffer[pos] == ' ' or state.text_buffer[pos] == '\t')) {
                    pos += 1;
                }
                state.cursor_pos = pos;
            },
            'g' => {
                // gg - go to start (simplified, just handles g as go to start)
                state.cursor_pos = 0;
            },
            'G' => state.cursor_pos = state.text_len,

            // Editing
            'x' => {
                if (state.cursor_pos < state.text_len) {
                    pushUndo(state);
                    deleteChar(state, state.cursor_pos);
                }
            },
            'd' => {
                // dd - delete line (simplified)
                pushUndo(state);
                const line_start = findLineStart(state.*);
                var line_end = findLineEnd(state.*);
                // Include newline if present
                if (line_end < state.text_len and state.text_buffer[line_end] == '\n') {
                    line_end += 1;
                }
                // Delete the line
                var pos = line_end;
                while (pos > line_start) {
                    pos -= 1;
                    deleteChar(state, pos);
                }
                state.cursor_pos = line_start;
            },
            'u' => performUndo(state),
            'p' => {
                // Paste after cursor
                if (state.yank_len > 0) {
                    pushUndo(state);
                    if (state.cursor_pos < state.text_len) {
                        state.cursor_pos += 1;
                    }
                    var i: usize = 0;
                    while (i < state.yank_len) : (i += 1) {
                        insertChar(state, state.yank_buffer[i]);
                    }
                }
            },
            'P' => {
                // Paste before cursor
                if (state.yank_len > 0) {
                    pushUndo(state);
                    var i: usize = 0;
                    while (i < state.yank_len) : (i += 1) {
                        insertChar(state, state.yank_buffer[i]);
                    }
                }
            },

            // ESC clears any pending state
            27 => {},

            else => {},
        }

        return null;
    }

    // =========================================================================
    // Insert Mode
    // =========================================================================

    fn handleInsertMode(state: *State, key: vaxis.Key) ?Action {
        // ESC or Ctrl+C - return to normal mode
        if (key.codepoint == 27 or (key.codepoint == 'c' and key.mods.ctrl)) {
            state.vim_mode = .normal;
            if (state.cursor_pos > 0) {
                state.cursor_pos -= 1;
            }
            return null;
        }

        // Ctrl+J or Shift+Enter - insert newline
        if ((key.mods.ctrl and key.codepoint == 'j') or
            key.matches(vaxis.Key.enter, .{ .shift = true }))
        {
            insertChar(state, '\n');
            return null;
        }

        // Enter (no modifiers) - send prompt
        if (key.matches(vaxis.Key.enter, .{})) {
            if (state.text_len > 0) {
                return .send;
            }
            return null;
        }

        switch (key.codepoint) {
            127, 8 => { // Backspace
                if (state.cursor_pos > 0) {
                    deleteChar(state, state.cursor_pos - 1);
                    state.cursor_pos -= 1;
                }
            },
            else => {
                // Regular character input
                if (key.codepoint >= 32 and key.codepoint < 127) {
                    insertChar(state, @intCast(key.codepoint));
                }
            },
        }

        return null;
    }

    // =========================================================================
    // Visual Mode
    // =========================================================================

    fn handleVisualMode(state: *State, key: vaxis.Key) ?Action {
        switch (key.codepoint) {
            // Exit visual mode
            27, 'v' => {
                state.vim_mode = .normal;
                state.visual_anchor = null;
            },

            // Navigation (extends selection)
            'h' => if (state.cursor_pos > 0) {
                state.cursor_pos -= 1;
            },
            'l' => if (state.cursor_pos < state.text_len) {
                state.cursor_pos += 1;
            },
            'j' => moveCursorDown(state),
            'k' => moveCursorUp(state),
            'w' => state.cursor_pos = findNextWordStart(state.*),
            'e' => state.cursor_pos = findWordEnd(state.*),
            'b' => state.cursor_pos = findPrevWordStart(state.*),
            '0' => state.cursor_pos = findLineStart(state.*),
            '$' => state.cursor_pos = findLineEnd(state.*),

            // Operations on selection
            'y' => {
                if (getVisualSelection(state.*)) |sel| {
                    const size = sel.end - sel.start;
                    if (size > 0 and size <= state.yank_buffer.len) {
                        @memcpy(state.yank_buffer[0..size], state.text_buffer[sel.start..sel.end]);
                        state.yank_len = size;
                    }
                }
                state.vim_mode = .normal;
                state.visual_anchor = null;
            },
            'd' => {
                if (getVisualSelection(state.*)) |sel| {
                    pushUndo(state);
                    var pos = sel.end;
                    while (pos > sel.start) {
                        pos -= 1;
                        deleteChar(state, pos);
                    }
                    state.cursor_pos = sel.start;
                }
                state.vim_mode = .normal;
                state.visual_anchor = null;
            },

            else => {},
        }

        return null;
    }

    // =========================================================================
    // Helper Functions
    // =========================================================================

    fn insertChar(state: *State, char: u8) void {
        if (state.text_len >= state.text_buffer.len - 1) return;

        // Shift text to make room
        var i = state.text_len;
        while (i > state.cursor_pos) {
            state.text_buffer[i] = state.text_buffer[i - 1];
            i -= 1;
        }
        state.text_buffer[state.cursor_pos] = char;
        state.text_len += 1;
        state.cursor_pos += 1;
    }

    fn deleteChar(state: *State, pos: usize) void {
        if (pos >= state.text_len) return;

        // Shift text to fill gap
        var i = pos;
        while (i < state.text_len - 1) {
            state.text_buffer[i] = state.text_buffer[i + 1];
            i += 1;
        }
        state.text_len -= 1;
    }

    fn findLineStart(state: State) usize {
        if (state.cursor_pos == 0) return 0;
        var pos = state.cursor_pos;
        if (pos > 0) pos -= 1;
        while (pos > 0 and state.text_buffer[pos] != '\n') {
            pos -= 1;
        }
        if (state.text_buffer[pos] == '\n') pos += 1;
        return pos;
    }

    fn findLineEnd(state: State) usize {
        var pos = state.cursor_pos;
        while (pos < state.text_len and state.text_buffer[pos] != '\n') {
            pos += 1;
        }
        return pos;
    }

    fn findNextWordStart(state: State) usize {
        var pos = state.cursor_pos;
        // Skip current word
        while (pos < state.text_len and !isWhitespace(state.text_buffer[pos])) {
            pos += 1;
        }
        // Skip whitespace
        while (pos < state.text_len and isWhitespace(state.text_buffer[pos])) {
            pos += 1;
        }
        return pos;
    }

    fn findWordEnd(state: State) usize {
        var pos = state.cursor_pos;
        if (pos < state.text_len) pos += 1;
        // Skip whitespace
        while (pos < state.text_len and isWhitespace(state.text_buffer[pos])) {
            pos += 1;
        }
        // Find end of word
        while (pos < state.text_len and !isWhitespace(state.text_buffer[pos])) {
            pos += 1;
        }
        if (pos > 0) pos -= 1;
        return pos;
    }

    fn findPrevWordStart(state: State) usize {
        if (state.cursor_pos == 0) return 0;
        var pos = state.cursor_pos - 1;
        // Skip whitespace
        while (pos > 0 and isWhitespace(state.text_buffer[pos])) {
            pos -= 1;
        }
        // Find start of word
        while (pos > 0 and !isWhitespace(state.text_buffer[pos - 1])) {
            pos -= 1;
        }
        return pos;
    }

    fn moveCursorDown(state: *State) void {
        const line_start = findLineStart(state.*);
        const col = state.cursor_pos - line_start;
        const line_end = findLineEnd(state.*);

        if (line_end >= state.text_len) return; // Already on last line

        // Move to next line
        const next_line_start = line_end + 1;
        var next_line_end = next_line_start;
        while (next_line_end < state.text_len and state.text_buffer[next_line_end] != '\n') {
            next_line_end += 1;
        }

        // Try to maintain column position
        const next_line_len = next_line_end - next_line_start;
        state.cursor_pos = next_line_start + @min(col, next_line_len);
    }

    fn moveCursorUp(state: *State) void {
        const line_start = findLineStart(state.*);
        if (line_start == 0) return; // Already on first line

        const col = state.cursor_pos - line_start;

        // Find previous line
        const prev_line_end = line_start - 1; // Skip newline
        var prev_line_start = prev_line_end;
        while (prev_line_start > 0 and state.text_buffer[prev_line_start - 1] != '\n') {
            prev_line_start -= 1;
        }

        // Try to maintain column position
        const prev_line_len = prev_line_end - prev_line_start;
        state.cursor_pos = prev_line_start + @min(col, prev_line_len);
    }

    fn isWhitespace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }

    const Selection = struct {
        start: usize,
        end: usize,
    };

    fn getVisualSelection(state: State) ?Selection {
        const anchor = state.visual_anchor orelse return null;
        const start = @min(anchor, state.cursor_pos);
        const end = @max(anchor, state.cursor_pos) + 1; // Inclusive
        return .{ .start = start, .end = @min(end, state.text_len) };
    }

    fn pushUndo(state: *State) void {
        if (state.undo_count < state.undo_stack.len) {
            state.undo_stack[state.undo_count] = .{
                .text = state.text_buffer,
                .text_len = state.text_len,
                .cursor_pos = state.cursor_pos,
            };
            state.undo_count += 1;
            state.undo_index = state.undo_count;
        }
    }

    fn performUndo(state: *State) void {
        if (state.undo_index > 0) {
            state.undo_index -= 1;
            const undo = state.undo_stack[state.undo_index];
            state.text_buffer = undo.text;
            state.text_len = undo.text_len;
            state.cursor_pos = undo.cursor_pos;
        }
    }

    fn performRedo(state: *State) void {
        if (state.undo_index < state.undo_count) {
            state.undo_index += 1;
            if (state.undo_index < state.undo_count) {
                const redo = state.undo_stack[state.undo_index];
                state.text_buffer = redo.text;
                state.text_len = redo.text_len;
                state.cursor_pos = redo.cursor_pos;
            }
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "InputEditor init" {
    var state = InputEditor.State.init();
    try std.testing.expect(state.isEmpty());
    try std.testing.expectEqual(InputEditor.State.VimMode.insert, state.vim_mode);
}

test "InputEditor insert characters" {
    var state = InputEditor.State.init();

    // Simulate typing "hello"
    InputEditor.insertChar(&state, 'h');
    InputEditor.insertChar(&state, 'e');
    InputEditor.insertChar(&state, 'l');
    InputEditor.insertChar(&state, 'l');
    InputEditor.insertChar(&state, 'o');

    try std.testing.expectEqualStrings("hello", state.getText());
    try std.testing.expectEqual(@as(usize, 5), state.cursor_pos);
}

test "InputEditor clear" {
    var state = InputEditor.State.init();
    InputEditor.insertChar(&state, 'a');
    InputEditor.insertChar(&state, 'b');

    state.clear();

    try std.testing.expect(state.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), state.cursor_pos);
}

test "InputEditor word navigation" {
    var state = InputEditor.State.init();

    // Insert "hello world"
    for ("hello world") |c| {
        InputEditor.insertChar(&state, c);
    }
    state.cursor_pos = 0;

    // w - next word start
    state.cursor_pos = InputEditor.findNextWordStart(state);
    try std.testing.expectEqual(@as(usize, 6), state.cursor_pos); // "world"

    // b - previous word start
    state.cursor_pos = InputEditor.findPrevWordStart(state);
    try std.testing.expectEqual(@as(usize, 0), state.cursor_pos); // "hello"
}
