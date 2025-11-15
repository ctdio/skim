const std = @import("std");
const vaxis = @import("vaxis");
const Allocator = std.mem.Allocator;

/// CommentEditor - Vim-style comment editing with modal interface
/// Uses namespace pattern with explicit state passing (Option B)
pub const CommentEditor = struct {
    /// Active comment input state
    pub const State = struct {
        target_file_path: []const u8, // Which file
        target_hunk_idx: usize, // Which hunk (start for ranges)
        target_line_idx: usize, // Which line (relative to hunk, start for ranges)
        target_end_hunk_idx: ?usize, // End hunk for range comments (null = single line)
        target_end_line_idx: ?usize, // End line for range comments (null = single line)
        editing_comment_idx: ?usize, // If editing existing comment, its index
        text_buffer: [4096]u8, // Input buffer
        text_len: usize, // Current text length
        cursor_pos: usize, // Cursor position in buffer
        vim_mode: VimMode, // Current vim mode (normal, insert, or visual)
        visual_anchor: ?usize, // Visual mode: position where selection started
        pending_find: ?PendingFind, // Waiting for character for f/t/F/T
        pending_operator: ?PendingOperator, // Waiting for motion after operator (d, y, c)
        pending_replace: bool, // Waiting for character for 'r' command
        pending_z: bool, // Waiting for second z for zz (center cursor)
        pending_text_object: ?TextObject, // Waiting for text object (iw, aw, etc.)
        yank_buffer: [4096]u8, // Yank/copy buffer
        yank_len: usize, // Length of yanked text
        count_prefix: ?usize, // Count prefix for operations (e.g., 3 in 3dd)
        undo_stack: [32]UndoState, // Undo history
        undo_count: usize, // Number of undo states
        undo_index: usize, // Current position in undo stack
        last_find: ?LastFind, // Last f/t/F/T command for ; and ,
        last_change: ?LastChange, // Last change for . repeat
        command_buffer: [256]u8, // Command-line buffer (for :w, :q, etc.)
        command_len: usize, // Length of command

        pub const VimMode = enum {
            normal,
            insert,
            visual,
            command, // Ex command mode (:w, :q, etc.)
        };

        pub const PendingFind = enum {
            f, // Find character forward (move to char)
            t, // Till character forward (move before char)
            F, // Find character backward
            T, // Till character backward
        };

        pub const PendingOperator = enum {
            d, // Delete
            y, // Yank
            c, // Change
        };

        pub const TextObject = enum {
            iw, // inner word
            aw, // around word
            i_quote, // inside quotes
            a_quote, // around quotes
            i_paren, // inside parentheses
            a_paren, // around parentheses
            i_bracket, // inside brackets
            a_bracket, // around brackets
            i_brace, // inside braces
            a_brace, // around braces
        };

        pub const UndoState = struct {
            text: [4096]u8,
            text_len: usize,
            cursor_pos: usize,
        };

        pub const LastFind = struct {
            command: PendingFind,
            char: u8,
        };

        pub const LastChange = struct {
            operator: PendingOperator,
            motion: ?u8, // Key for motion (w, e, b, etc.)
            count: ?usize,
        };
    };

    /// Handle key input based on current vim mode
    /// Returns true if the editor should exit (save or cancel)
    pub fn handleKey(state: *State, key: vaxis.Key, allocator: Allocator) !?SaveAction {
        // Ctrl+S - save comment (works in all modes)
        if (key.mods.ctrl and key.codepoint == 's') {
            return .save;
        }

        // Dispatch based on vim mode
        switch (state.vim_mode) {
            .normal => return try handleNormalMode(state, key, allocator),
            .insert => return try handleInsertMode(state, key),
            .visual => return try handleVisualMode(state, key, allocator),
            .command => return try handleCommandMode(state, key),
        }
    }

    pub const SaveAction = enum {
        save, // Save and exit
        cancel, // Cancel without saving
    };

    // Normal mode key handler
    fn handleNormalMode(state: *State, key: vaxis.Key, allocator: Allocator) !?SaveAction {
        // Handle Ctrl+R for redo
        if (key.mods.ctrl and key.codepoint == 'r') {
            performRedo(state);
            return null;
        }

        // Handle Ctrl+D for page down
        if (key.mods.ctrl and key.codepoint == 'd') {
            const count = state.count_prefix orelse 1;
            var i: usize = 0;
            while (i < count * 10) : (i += 1) { // Move down 10 lines per page
                moveCursorDown(state);
            }
            state.count_prefix = null;
            return null;
        }

        // Handle Ctrl+U for page up
        if (key.mods.ctrl and key.codepoint == 'u') {
            const count = state.count_prefix orelse 1;
            var i: usize = 0;
            while (i < count * 10) : (i += 1) { // Move up 10 lines per page
                moveCursorUp(state);
            }
            state.count_prefix = null;
            return null;
        }

        // Handle Ctrl+W to exit (like closing a tab in VS Code/browsers)
        if (key.mods.ctrl and key.codepoint == 'w') {
            return .cancel;
        }

        // Handle pending replace (r command)
        if (state.pending_replace) {
            if (key.codepoint >= 32 and key.codepoint < 127) {
                pushUndo(state);
                if (state.cursor_pos < state.text_len) {
                    state.text_buffer[state.cursor_pos] = @intCast(key.codepoint);
                }
                state.pending_replace = false;
            }
            return null;
        }

        // Handle pending find commands (f/t/F/T)
        if (state.pending_find) |find_cmd| {
            if (key.codepoint >= 32 and key.codepoint < 127) {
                const target_char: u8 = @intCast(key.codepoint);
                state.last_find = .{ .command = find_cmd, .char = target_char };
                try executeFind(state, find_cmd, target_char);
                state.pending_find = null;
            }
            return null;
        }

        // Handle count prefix (0-9)
        if (key.codepoint >= '0' and key.codepoint <= '9') {
            const digit = key.codepoint - '0';
            if (state.count_prefix) |current| {
                state.count_prefix = current * 10 + digit;
            } else if (digit != 0) { // 0 is a motion, not a count prefix
                state.count_prefix = digit;
            } else {
                // 0 is "go to start of line"
                state.cursor_pos = findLineStart(state.*);
            }
            return null;
        }

        // Handle pending operator + motion (dw, yw, etc.) or line operation (dd, yy, cc)
        if (state.pending_operator) |operator| {
            const count = state.count_prefix orelse 1;

            // Check for double operator (dd, yy, cc) - operate on whole lines
            const is_line_operation = switch (operator) {
                .d => key.codepoint == 'd',
                .y => key.codepoint == 'y',
                .c => key.codepoint == 'c',
            };

            if (is_line_operation) {
                pushUndo(state);
                // Operate on count lines
                const line_start = findLineStart(state.*);
                var line_end = findLineEnd(state.*);

                // Extend to count lines
                var lines: usize = 1;
                while (lines < count and line_end < state.text_len) : (lines += 1) {
                    if (state.text_buffer[line_end] == '\n') line_end += 1;
                    while (line_end < state.text_len and state.text_buffer[line_end] != '\n') {
                        line_end += 1;
                    }
                }

                // Include final newline if there is one
                if (line_end < state.text_len and state.text_buffer[line_end] == '\n') {
                    line_end += 1;
                }

                try executeOperator(state, operator, line_start, line_end, allocator);
                state.pending_operator = null;
                state.count_prefix = null;
                return null;
            }

            // Handle line-wise motions (j/k)
            if (key.codepoint == 'j' or key.codepoint == 'k') {
                pushUndo(state);
                const line_start = findLineStart(state.*);
                var line_end = findLineEnd(state.*);

                // Extend by count lines in the direction
                var lines: usize = 0;
                while (lines < count) : (lines += 1) {
                    if (key.codepoint == 'j') {
                        // Down
                        if (line_end < state.text_len) {
                            if (state.text_buffer[line_end] == '\n') line_end += 1;
                            while (line_end < state.text_len and state.text_buffer[line_end] != '\n') {
                                line_end += 1;
                            }
                        }
                    } else {
                        // Up - would need to implement going backwards
                        // For now just handle current line
                    }
                }

                // Include newline
                if (line_end < state.text_len and state.text_buffer[line_end] == '\n') {
                    line_end += 1;
                }

                try executeOperator(state, operator, line_start, line_end, allocator);
                state.pending_operator = null;
                state.count_prefix = null;
                return null;
            }

            // Execute motion to get end position (with count)
            pushUndo(state);
            const start_pos = state.cursor_pos;
            var end_pos: usize = start_pos;

            var i: usize = 0;
            while (i < count) : (i += 1) {
                end_pos = switch (key.codepoint) {
                    'w' => findNextWordStart(state.*),
                    'e' => findWordEnd(state.*),
                    'b' => findPrevWordStart(state.*),
                    '$' => findLineEnd(state.*),
                    '^' => blk: {
                        var pos = findLineStart(state.*);
                        while (pos < state.text_len and (state.text_buffer[pos] == ' ' or state.text_buffer[pos] == '\t')) {
                            pos += 1;
                        }
                        break :blk pos;
                    },
                    '{' => findPrevParagraph(state.*),
                    '}' => findNextParagraph(state.*),
                    else => {
                        // Invalid motion - cancel operator
                        state.pending_operator = null;
                        state.count_prefix = null;
                        return null;
                    },
                };
            }

            // Execute operator on range
            try executeOperator(state, operator, start_pos, end_pos, allocator);
            state.pending_operator = null;
            state.count_prefix = null;
            return null;
        }

        const count = state.count_prefix orelse 1;

        switch (key.codepoint) {
            // Undo/Redo
            'u' => {
                performUndo(state);
                state.count_prefix = null;
            },

            // Mode transitions
            'i' => {
                state.vim_mode = .insert;
                state.count_prefix = null;
            },
            'a' => {
                state.cursor_pos = @min(state.cursor_pos + 1, state.text_len);
                state.vim_mode = .insert;
                state.count_prefix = null;
            },
            'I' => {
                state.cursor_pos = findLineStart(state.*);
                state.vim_mode = .insert;
                state.count_prefix = null;
            },
            'A' => {
                state.cursor_pos = findLineEnd(state.*);
                state.vim_mode = .insert;
                state.count_prefix = null;
            },
            'o' => {
                pushUndo(state);
                state.cursor_pos = findLineEnd(state.*);
                try insertChar(state, '\n');
                state.vim_mode = .insert;
                state.count_prefix = null;
            },
            'O' => {
                pushUndo(state);
                const line_start = findLineStart(state.*);
                state.cursor_pos = line_start;
                try insertChar(state, '\n');
                state.cursor_pos = line_start;
                state.vim_mode = .insert;
                state.count_prefix = null;
            },
            's' => { // Substitute character (delete + insert)
                pushUndo(state);
                if (state.cursor_pos < state.text_len) {
                    try deleteChar(state, state.cursor_pos);
                }
                state.vim_mode = .insert;
                state.count_prefix = null;
            },

            // Navigation with count support
            'h' => {
                var i: usize = 0;
                while (i < count and state.cursor_pos > 0) : (i += 1) {
                    state.cursor_pos -= 1;
                }
                state.count_prefix = null;
            },
            'l' => {
                var i: usize = 0;
                while (i < count and state.cursor_pos < state.text_len) : (i += 1) {
                    state.cursor_pos += 1;
                }
                state.count_prefix = null;
            },
            'j' => {
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    moveCursorDown(state);
                }
                state.count_prefix = null;
            },
            'k' => {
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    moveCursorUp(state);
                }
                state.count_prefix = null;
            },
            'w' => {
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    state.cursor_pos = findNextWordStart(state.*);
                }
                state.count_prefix = null;
            },
            'e' => {
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    state.cursor_pos = findWordEnd(state.*);
                }
                state.count_prefix = null;
            },
            'b' => {
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    state.cursor_pos = findPrevWordStart(state.*);
                }
                state.count_prefix = null;
            },
            '$' => {
                state.cursor_pos = findLineEnd(state.*);
                state.count_prefix = null;
            },
            '^' => { // First non-blank of line
                var pos = findLineStart(state.*);
                while (pos < state.text_len and (state.text_buffer[pos] == ' ' or state.text_buffer[pos] == '\t')) {
                    pos += 1;
                }
                state.cursor_pos = pos;
                state.count_prefix = null;
            },
            'g' => { // gg - go to start of buffer
                if (state.count_prefix == null) {
                    // Waiting for second 'g'
                    state.count_prefix = 999; // Use as a flag for 'g' pressed
                } else {
                    state.cursor_pos = 0;
                    state.count_prefix = null;
                }
            },
            'G' => {
                state.cursor_pos = state.text_len;
                state.count_prefix = null;
            },
            '{' => { // Previous paragraph
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    state.cursor_pos = findPrevParagraph(state.*);
                }
                state.count_prefix = null;
            },
            '}' => { // Next paragraph
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    state.cursor_pos = findNextParagraph(state.*);
                }
                state.count_prefix = null;
            },

            // Visual mode
            'v' => {
                state.visual_anchor = state.cursor_pos;
                state.vim_mode = .visual;
                state.count_prefix = null;
            },

            // Command mode
            ':' => {
                state.command_len = 0;
                state.vim_mode = .command;
                state.count_prefix = null;
            },

            // Find commands
            'f' => {
                state.pending_find = .f;
                // count_prefix preserved for repeat
            },
            't' => {
                state.pending_find = .t;
                // count_prefix preserved for repeat
            },
            'F' => {
                state.pending_find = .F;
                // count_prefix preserved for repeat
            },
            'T' => {
                state.pending_find = .T;
                // count_prefix preserved for repeat
            },
            ';' => { // Repeat last find
                if (state.last_find) |last| {
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        try executeFind(state, last.command, last.char);
                    }
                }
                state.count_prefix = null;
            },
            ',' => { // Repeat last find in opposite direction
                if (state.last_find) |last| {
                    const opposite = switch (last.command) {
                        .f => State.PendingFind.F,
                        .F => State.PendingFind.f,
                        .t => State.PendingFind.T,
                        .T => State.PendingFind.t,
                    };
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        try executeFind(state, opposite, last.char);
                    }
                }
                state.count_prefix = null;
            },

            // Editing
            'r' => {
                state.pending_replace = true;
                state.count_prefix = null;
            },
            'x' => { // Delete character under cursor
                pushUndo(state);
                var i: usize = 0;
                while (i < count and state.cursor_pos < state.text_len) : (i += 1) {
                    try deleteChar(state, state.cursor_pos);
                }
                state.count_prefix = null;
            },
            'd' => state.pending_operator = .d,
            'y' => state.pending_operator = .y,
            'c' => state.pending_operator = .c,
            'C' => { // Change to end of line
                pushUndo(state);
                const line_end = findLineEnd(state.*);
                while (state.cursor_pos < line_end) {
                    try deleteChar(state, state.cursor_pos);
                }
                state.vim_mode = .insert;
                state.count_prefix = null;
            },
            'D' => { // Delete to end of line
                pushUndo(state);
                const line_end = findLineEnd(state.*);
                while (state.cursor_pos < line_end) {
                    try deleteChar(state, state.cursor_pos);
                }
                state.count_prefix = null;
            },
            'Y' => { // Yank line (like yy)
                const line_start = findLineStart(state.*);
                var line_end = findLineEnd(state.*);
                if (line_end < state.text_len and state.text_buffer[line_end] == '\n') {
                    line_end += 1;
                }
                const yank_size = line_end - line_start;
                if (yank_size > 0 and yank_size <= state.yank_buffer.len) {
                    @memcpy(state.yank_buffer[0..yank_size], state.text_buffer[line_start..line_end]);
                    state.yank_len = yank_size;
                }
                state.count_prefix = null;
            },
            'p' => { // Paste after cursor
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    try pasteAfterCursor(state, allocator);
                }
                state.count_prefix = null;
            },
            'P' => { // Paste before cursor
                pushUndo(state);
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    // Insert yanked text at cursor position
                    for (0..state.yank_len) |j| {
                        if (state.text_len >= state.text_buffer.len) break;
                        try insertChar(state, state.yank_buffer[j]);
                    }
                    // Move cursor back to start of pasted text
                    if (state.yank_len > 0 and state.cursor_pos >= state.yank_len) {
                        state.cursor_pos -= state.yank_len;
                    }
                }
                state.count_prefix = null;
            },
            'J' => { // Join lines
                pushUndo(state);
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const line_end = findLineEnd(state.*);
                    // If there's a newline, replace it with a space
                    if (line_end < state.text_len and state.text_buffer[line_end] == '\n') {
                        state.text_buffer[line_end] = ' ';
                    }
                }
                state.count_prefix = null;
            },
            'M' => { // Move to middle line (vim-style)
                centerCommentCursor(state);
            },

            27 => { // ESC - Clear pending state (use :q or Ctrl-S to exit)
                // Clear any pending state
                state.pending_find = null;
                state.pending_operator = null;
                state.pending_replace = false;
                state.count_prefix = null;
                // Don't exit - use :q or Ctrl-S to save/exit
            },

            else => {
                // Unknown key - clear count prefix
                state.count_prefix = null;
            },
        }

        return null;
    }

    // Insert mode key handler
    fn handleInsertMode(state: *State, key: vaxis.Key) !?SaveAction {
        // Ctrl+W - exit comment editor (modern app behavior)
        if (key.mods.ctrl and key.codepoint == 'w') {
            return .cancel;
        }

        // ESC or Ctrl+C - return to normal mode
        if (key.codepoint == 27 or (key.codepoint == 'c' and key.mods.ctrl)) {
            state.vim_mode = .normal;
            // Move cursor left by 1 if not at start (vim behavior)
            if (state.cursor_pos > 0) {
                state.cursor_pos -= 1;
            }
            return null;
        }

        // Enter - insert newline
        if (key.matches(vaxis.Key.enter, .{})) {
            try insertChar(state, '\n');
            return null;
        }

        switch (key.codepoint) {
            127, 8 => { // Backspace / Delete
                if (state.cursor_pos > 0) {
                    try deleteChar(state, state.cursor_pos - 1);
                    state.cursor_pos -= 1;
                }
            },
            else => {
                // Regular character input
                if (key.codepoint >= 32 and key.codepoint < 127) {
                    try insertChar(state, @intCast(key.codepoint));
                }
            },
        }

        return null;
    }

    // Visual mode key handler
    fn handleVisualMode(state: *State, key: vaxis.Key, allocator: Allocator) !?SaveAction {
        // Ctrl+W - exit comment editor (modern app behavior)
        if (key.mods.ctrl and key.codepoint == 'w') {
            return .cancel;
        }

        // Handle pending find commands (f/t/F/T) in visual mode
        if (state.pending_find) |find_cmd| {
            if (key.codepoint >= 32 and key.codepoint < 127) {
                const target_char: u8 = @intCast(key.codepoint);
                state.last_find = .{ .command = find_cmd, .char = target_char };
                try executeFind(state, find_cmd, target_char);
                state.pending_find = null;
            } else if (key.codepoint == 27) { // ESC cancels pending find
                state.pending_find = null;
            }
            return null;
        }

        // Handle count prefix (0-9) - allows things like 2ft in visual mode
        if (key.codepoint >= '0' and key.codepoint <= '9') {
            const digit = key.codepoint - '0';
            if (state.count_prefix) |current| {
                state.count_prefix = current * 10 + digit;
            } else if (digit != 0) {
                state.count_prefix = digit;
            } else {
                // 0 is "go to start of line"
                state.cursor_pos = findLineStart(state.*);
            }
            return null;
        }

        switch (key.codepoint) {
            // Exit visual mode
            27 => { // ESC
                state.vim_mode = .normal;
                state.visual_anchor = null;
            },
            'v' => { // Toggle visual mode off
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
            'w' => {
                const count = state.count_prefix orelse 1;
                state.count_prefix = null;
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    state.cursor_pos = findNextWordStart(state.*);
                }
            },
            'e' => {
                const count = state.count_prefix orelse 1;
                state.count_prefix = null;
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    state.cursor_pos = findWordEnd(state.*);
                }
            },
            'b' => {
                const count = state.count_prefix orelse 1;
                state.count_prefix = null;
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    state.cursor_pos = findPrevWordStart(state.*);
                }
            },
            '0' => {
                state.count_prefix = null;
                state.cursor_pos = findLineStart(state.*);
            },
            '$' => {
                state.count_prefix = null;
                state.cursor_pos = findLineEnd(state.*);
            },
            'G' => {
                state.count_prefix = null;
                state.cursor_pos = state.text_len;
            },
            // Character find motions
            'f' => state.pending_find = .f,
            't' => state.pending_find = .t,
            'F' => state.pending_find = .F,
            'T' => state.pending_find = .T,
            ';' => { // Repeat last find (respects count: 3; repeats find 3 times)
                if (state.last_find) |last| {
                    const repeat_count = state.count_prefix orelse 1;
                    var i: usize = 0;
                    while (i < repeat_count) : (i += 1) {
                        state.count_prefix = 1; // Each iteration finds 1 occurrence
                        try executeFind(state, last.command, last.char);
                    }
                }
            },
            ',' => { // Repeat last find in opposite direction (respects count)
                if (state.last_find) |last| {
                    const repeat_count = state.count_prefix orelse 1;
                    const opposite = switch (last.command) {
                        .f => State.PendingFind.F,
                        .F => State.PendingFind.f,
                        .t => State.PendingFind.T,
                        .T => State.PendingFind.t,
                    };
                    var i: usize = 0;
                    while (i < repeat_count) : (i += 1) {
                        state.count_prefix = 1; // Each iteration finds 1 occurrence
                        try executeFind(state, opposite, last.char);
                    }
                }
            },

            // Operations on selection
            'y' => { // Yank (copy) selection
                state.count_prefix = null; // Clear count
                const selection = getVisualSelection(state.*) orelse return null;
                const start = selection.start;
                const end = selection.end;

                // Copy selection to yank buffer
                const yank_size = end - start;
                if (yank_size > 0 and yank_size <= state.yank_buffer.len) {
                    @memcpy(state.yank_buffer[0..yank_size], state.text_buffer[start..end]);
                    state.yank_len = yank_size;

                    // Also copy to system clipboard
                    copyToSystemClipboard(state.text_buffer[start..end], allocator) catch |err| {
                        std.log.err("Failed to copy to system clipboard: {}", .{err});
                    };
                }

                state.vim_mode = .normal;
                state.visual_anchor = null;
            },
            'd' => { // Delete selection
                state.count_prefix = null; // Clear count
                const selection = getVisualSelection(state.*) orelse return null;
                const start = selection.start;
                const end = selection.end;

                // Delete from end to start to maintain positions
                var pos = end;
                while (pos > start) {
                    pos -= 1;
                    try deleteChar(state, pos);
                }

                // Place cursor at start of deletion
                state.cursor_pos = start;
                state.vim_mode = .normal;
                state.visual_anchor = null;
            },

            else => {
                // Clear count prefix for unrecognized keys
                state.count_prefix = null;
            },
        }

        return null;
    }

    // Command mode key handler
    fn handleCommandMode(state: *State, key: vaxis.Key) !?SaveAction {
        // ESC - return to normal mode
        if (key.codepoint == 27) {
            state.vim_mode = .normal;
            state.command_len = 0;
            return null;
        }

        // Enter - execute command
        if (key.matches(vaxis.Key.enter, .{})) {
            const command = state.command_buffer[0..state.command_len];

            // Parse and execute command
            if (std.mem.eql(u8, command, "w")) {
                // :w - save comment
                return .save;
            } else if (std.mem.eql(u8, command, "q")) {
                // :q - quit without saving
                return .cancel;
            } else if (std.mem.eql(u8, command, "wq")) {
                // :wq - save and quit
                return .save;
            } else {
                // Unknown command - just return to normal mode
                state.vim_mode = .normal;
                state.command_len = 0;
            }
            return null;
        }

        // Backspace - delete character from command
        if (key.codepoint == 127 or key.codepoint == 8) {
            if (state.command_len > 0) {
                state.command_len -= 1;
            }
            return null;
        }

        // Regular character input - add to command buffer
        if (key.codepoint >= 32 and key.codepoint < 127) {
            if (state.command_len < state.command_buffer.len) {
                state.command_buffer[state.command_len] = @intCast(key.codepoint);
                state.command_len += 1;
            }
        }

        return null;
    }

    // Execute a find command (f/t/F/T) with count support
    fn executeFind(state: *State, cmd: State.PendingFind, target_char: u8) !void {
        const line_start = findLineStart(state.*);
        const line_end = findLineEnd(state.*);
        const count = state.count_prefix orelse 1;
        state.count_prefix = null; // Clear count after use

        var found_count: usize = 0;

        switch (cmd) {
            .f => { // Find forward - move to character
                var pos = state.cursor_pos + 1;
                while (pos < line_end) : (pos += 1) {
                    if (state.text_buffer[pos] == target_char) {
                        found_count += 1;
                        if (found_count == count) {
                            state.cursor_pos = pos;
                            return;
                        }
                    }
                }
            },
            .t => { // Till forward - move before character
                var pos = state.cursor_pos + 1;
                while (pos < line_end) : (pos += 1) {
                    if (state.text_buffer[pos] == target_char) {
                        found_count += 1;
                        if (found_count == count) {
                            state.cursor_pos = pos - 1;
                            return;
                        }
                    }
                }
            },
            .F => { // Find backward - move to character
                if (state.cursor_pos > line_start) {
                    var pos = state.cursor_pos - 1;
                    while (pos >= line_start) {
                        if (state.text_buffer[pos] == target_char) {
                            found_count += 1;
                            if (found_count == count) {
                                state.cursor_pos = pos;
                                return;
                            }
                        }
                        if (pos == line_start) break;
                        pos -= 1;
                    }
                }
            },
            .T => { // Till backward - move after character
                if (state.cursor_pos > line_start) {
                    var pos = state.cursor_pos - 1;
                    while (pos >= line_start) {
                        if (state.text_buffer[pos] == target_char) {
                            found_count += 1;
                            if (found_count == count) {
                                state.cursor_pos = pos + 1;
                                return;
                            }
                        }
                        if (pos == line_start) break;
                        pos -= 1;
                    }
                }
            },
        }
    }

    // Get visual selection range
    fn getVisualSelection(state: State) ?struct { start: usize, end: usize } {
        const anchor = state.visual_anchor orelse return null;
        const cursor = state.cursor_pos;

        const start = @min(anchor, cursor);
        var end = @max(anchor, cursor);

        // Visual mode is inclusive - include character under cursor
        if (end < state.text_len) {
            end += 1;
        }

        return .{ .start = start, .end = end };
    }

    // Helper: Insert character at cursor position
    fn insertChar(state: *State, char: u8) !void {
        if (state.text_len >= state.text_buffer.len) return;

        const remaining = state.text_len - state.cursor_pos;
        if (remaining > 0) {
            std.mem.copyBackwards(
                u8,
                state.text_buffer[state.cursor_pos + 1 .. state.text_len + 1],
                state.text_buffer[state.cursor_pos..state.text_len],
            );
        }
        state.text_buffer[state.cursor_pos] = char;
        state.text_len += 1;
        state.cursor_pos += 1;
    }

    // Helper: Delete character at position
    fn deleteChar(state: *State, pos: usize) !void {
        if (pos >= state.text_len) return;

        const remaining = state.text_len - pos - 1;
        if (remaining > 0) {
            std.mem.copyForwards(
                u8,
                state.text_buffer[pos .. state.text_len - 1],
                state.text_buffer[pos + 1 .. state.text_len],
            );
        }
        state.text_len -= 1;
    }

    // Helper: Find start of current line
    fn findLineStart(state: State) usize {
        var pos = state.cursor_pos;
        while (pos > 0 and state.text_buffer[pos - 1] != '\n') {
            pos -= 1;
        }
        return pos;
    }

    // Helper: Find end of current line
    fn findLineEnd(state: State) usize {
        var pos = state.cursor_pos;
        while (pos < state.text_len and state.text_buffer[pos] != '\n') {
            pos += 1;
        }
        return pos;
    }

    // Helper: Move cursor down one line
    fn moveCursorDown(state: *State) void {
        const current_line_start = findLineStart(state.*);
        const current_line_end = findLineEnd(state.*);
        const col_offset = state.cursor_pos - current_line_start;

        // Move to start of next line
        if (current_line_end < state.text_len) {
            const next_line_start = current_line_end + 1;
            var next_line_end = next_line_start;
            while (next_line_end < state.text_len and state.text_buffer[next_line_end] != '\n') {
                next_line_end += 1;
            }

            // Try to preserve column position
            const next_line_len = next_line_end - next_line_start;
            state.cursor_pos = next_line_start + @min(col_offset, next_line_len);
        }
    }

    // Helper: Move cursor up one line
    fn moveCursorUp(state: *State) void {
        const current_line_start = findLineStart(state.*);
        const col_offset = state.cursor_pos - current_line_start;

        // Move to start of previous line
        if (current_line_start > 0) {
            const prev_line_end = current_line_start - 1; // Skip the newline
            var prev_line_start = prev_line_end;
            while (prev_line_start > 0 and state.text_buffer[prev_line_start - 1] != '\n') {
                prev_line_start -= 1;
            }

            // Try to preserve column position
            const prev_line_len = prev_line_end - prev_line_start;
            state.cursor_pos = prev_line_start + @min(col_offset, prev_line_len);
        }
    }

    // Helper: Center cursor in comment text (move to middle line)
    fn centerCommentCursor(state: *State) void {
        if (state.text_len == 0) return;

        // Count total lines in the text
        var line_count: usize = 1;
        var i: usize = 0;
        while (i < state.text_len) : (i += 1) {
            if (state.text_buffer[i] == '\n') {
                line_count += 1;
            }
        }

        // Find the middle line
        const middle_line = line_count / 2;

        // Navigate to the middle line
        var current_line: usize = 0;
        var pos: usize = 0;
        while (pos < state.text_len and current_line < middle_line) {
            if (state.text_buffer[pos] == '\n') {
                current_line += 1;
            }
            pos += 1;
        }

        // Position cursor at the start of the middle line
        state.cursor_pos = pos;
    }

    // Helper: Find next word start
    fn findNextWordStart(state: State) usize {
        var pos = state.cursor_pos;

        // Skip current word
        while (pos < state.text_len and !isWordBoundary(state.text_buffer[pos])) {
            pos += 1;
        }

        // Skip whitespace
        while (pos < state.text_len and isWordBoundary(state.text_buffer[pos])) {
            pos += 1;
        }

        return pos;
    }

    // Helper: Find previous word start
    fn findPrevWordStart(state: State) usize {
        if (state.cursor_pos == 0) return 0;

        var pos = state.cursor_pos - 1;

        // Skip whitespace backwards
        while (pos > 0 and isWordBoundary(state.text_buffer[pos])) {
            pos -= 1;
        }

        // Skip word backwards
        while (pos > 0 and !isWordBoundary(state.text_buffer[pos - 1])) {
            pos -= 1;
        }

        return pos;
    }

    // Helper: Find end of current word
    fn findWordEnd(state: State) usize {
        var pos = state.cursor_pos;

        // If we're on whitespace, skip to next word first
        if (pos < state.text_len and isWordBoundary(state.text_buffer[pos])) {
            while (pos < state.text_len and isWordBoundary(state.text_buffer[pos])) {
                pos += 1;
            }
        }

        // Move to end of word
        while (pos < state.text_len and !isWordBoundary(state.text_buffer[pos])) {
            pos += 1;
        }

        // Back up one if we ended on the boundary (to land on last char of word)
        if (pos > state.cursor_pos) {
            pos -= 1;
        }

        return pos;
    }

    // Execute an operator (d/y/c) on a range
    fn executeOperator(state: *State, operator: State.PendingOperator, start_pos: usize, end_pos: usize, allocator: Allocator) !void {
        const range_start = @min(start_pos, end_pos);
        const range_end = @max(start_pos, end_pos);

        switch (operator) {
            .y => { // Yank
                const yank_size = range_end - range_start;
                if (yank_size > 0 and yank_size <= state.yank_buffer.len) {
                    @memcpy(state.yank_buffer[0..yank_size], state.text_buffer[range_start..range_end]);
                    state.yank_len = yank_size;

                    // Also copy to system clipboard
                    copyToSystemClipboard(state.text_buffer[range_start..range_end], allocator) catch |err| {
                        std.log.err("Failed to copy to system clipboard: {}", .{err});
                    };
                }
            },
            .d => { // Delete
                // Yank before deleting (vim behavior)
                const yank_size = range_end - range_start;
                if (yank_size > 0 and yank_size <= state.yank_buffer.len) {
                    @memcpy(state.yank_buffer[0..yank_size], state.text_buffer[range_start..range_end]);
                    state.yank_len = yank_size;

                    // Also copy to system clipboard
                    copyToSystemClipboard(state.text_buffer[range_start..range_end], allocator) catch |err| {
                        std.log.err("Failed to copy to system clipboard: {}", .{err});
                    };
                }

                // Delete from end to start to maintain positions
                var pos = range_end;
                while (pos > range_start) {
                    pos -= 1;
                    try deleteChar(state, pos);
                }

                // Place cursor at start of deletion
                state.cursor_pos = range_start;
            },
            .c => { // Change (delete and enter insert mode)
                // Yank before deleting
                const yank_size = range_end - range_start;
                if (yank_size > 0 and yank_size <= state.yank_buffer.len) {
                    @memcpy(state.yank_buffer[0..yank_size], state.text_buffer[range_start..range_end]);
                    state.yank_len = yank_size;

                    // Also copy to system clipboard
                    copyToSystemClipboard(state.text_buffer[range_start..range_end], allocator) catch |err| {
                        std.log.err("Failed to copy to system clipboard: {}", .{err});
                    };
                }

                // Delete from end to start
                var pos = range_end;
                while (pos > range_start) {
                    pos -= 1;
                    try deleteChar(state, pos);
                }

                // Enter insert mode at deletion point
                state.cursor_pos = range_start;
                state.vim_mode = .insert;
            },
        }
    }

    // Copy text to system clipboard (macOS pbcopy)
    fn copyToSystemClipboard(text: []const u8, allocator: Allocator) !void {
        const argv = [_][]const u8{"pbcopy"};
        var child = std.process.Child.init(&argv, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        if (child.stdin) |stdin| {
            try stdin.writeAll(text);
            stdin.close();
            child.stdin = null;
        }

        _ = try child.wait();
    }

    // Read text from system clipboard (macOS pbpaste)
    fn readFromSystemClipboard(allocator: Allocator) ![]const u8 {
        const argv = [_][]const u8{"pbpaste"};
        var child = std.process.Child.init(&argv, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        const stdout = child.stdout.?;
        const output = try stdout.readToEndAlloc(allocator, 1024 * 1024); // 1MB max

        _ = try child.wait();

        return output;
    }

    // Paste yanked text after cursor (tries system clipboard first, falls back to yank buffer)
    fn pasteAfterCursor(state: *State, allocator: Allocator) !void {
        // Try to paste from system clipboard first
        const clipboard_text = readFromSystemClipboard(allocator) catch null;
        defer if (clipboard_text) |text| allocator.free(text);

        // Move cursor forward by 1 to paste after
        if (state.cursor_pos < state.text_len) {
            state.cursor_pos += 1;
        }

        if (clipboard_text) |text| {
            // Paste from system clipboard
            for (text) |char| {
                if (state.text_len >= state.text_buffer.len) break;
                try insertChar(state, char);
            }
        } else if (state.yank_len > 0) {
            // Fall back to yank buffer
            for (0..state.yank_len) |i| {
                if (state.text_len >= state.text_buffer.len) break;
                try insertChar(state, state.yank_buffer[i]);
            }
        } else {
            // Nothing to paste - move cursor back
            if (state.cursor_pos > 0) {
                state.cursor_pos -= 1;
            }
            return;
        }

        // Leave cursor at end of pasted text
        if (state.cursor_pos > 0) {
            state.cursor_pos -= 1;
        }
    }

    // Helper: Check if character is a word boundary
    fn isWordBoundary(char: u8) bool {
        return char == ' ' or char == '\n' or char == '\t' or char == '.' or char == ',' or char == ';';
    }

    // Helper: Save current state to undo stack
    fn pushUndo(state: *State) void {
        if (state.undo_count >= state.undo_stack.len) {
            // Stack full - shift everything down
            var i: usize = 1;
            while (i < state.undo_stack.len) : (i += 1) {
                state.undo_stack[i - 1] = state.undo_stack[i];
            }
            state.undo_count = state.undo_stack.len - 1;
        }

        // Truncate redo history if we're not at the end
        if (state.undo_index < state.undo_count) {
            state.undo_count = state.undo_index;
        }

        // Save current state
        const undo_state = &state.undo_stack[state.undo_count];
        @memcpy(undo_state.text[0..state.text_len], state.text_buffer[0..state.text_len]);
        undo_state.text_len = state.text_len;
        undo_state.cursor_pos = state.cursor_pos;

        state.undo_count += 1;
        state.undo_index = state.undo_count;
    }

    // Helper: Undo last change
    fn performUndo(state: *State) void {
        if (state.undo_index == 0) return; // Nothing to undo

        state.undo_index -= 1;
        const undo_state = &state.undo_stack[state.undo_index];

        @memcpy(state.text_buffer[0..undo_state.text_len], undo_state.text[0..undo_state.text_len]);
        state.text_len = undo_state.text_len;
        state.cursor_pos = undo_state.cursor_pos;
    }

    // Helper: Redo last undone change
    fn performRedo(state: *State) void {
        if (state.undo_index >= state.undo_count) return; // Nothing to redo

        const undo_state = &state.undo_stack[state.undo_index];

        @memcpy(state.text_buffer[0..undo_state.text_len], undo_state.text[0..undo_state.text_len]);
        state.text_len = undo_state.text_len;
        state.cursor_pos = undo_state.cursor_pos;

        state.undo_index += 1;
    }

    // Helper: Find next blank line (paragraph movement)
    fn findNextParagraph(state: State) usize {
        var pos = state.cursor_pos;
        var found_content = false;

        // Skip current line
        while (pos < state.text_len and state.text_buffer[pos] != '\n') {
            pos += 1;
        }
        if (pos < state.text_len) pos += 1; // Skip the newline

        // Find next blank line or end
        while (pos < state.text_len) {
            const line_start = pos;
            var is_blank = true;

            // Check if line is blank
            while (pos < state.text_len and state.text_buffer[pos] != '\n') {
                if (state.text_buffer[pos] != ' ' and state.text_buffer[pos] != '\t') {
                    is_blank = false;
                    found_content = true;
                }
                pos += 1;
            }

            if (is_blank and found_content) {
                return line_start;
            }

            if (pos < state.text_len) pos += 1; // Skip newline
        }

        return state.text_len;
    }

    // Helper: Find previous blank line (paragraph movement)
    fn findPrevParagraph(state: State) usize {
        if (state.cursor_pos == 0) return 0;

        var pos = state.cursor_pos;
        var found_content = false;

        // Move to start of current line
        while (pos > 0 and state.text_buffer[pos - 1] != '\n') {
            pos -= 1;
        }

        // Move up one line
        if (pos > 0) pos -= 1;
        while (pos > 0 and state.text_buffer[pos - 1] != '\n') {
            pos -= 1;
        }

        // Find previous blank line
        while (pos > 0) {
            const line_start = pos;
            var is_blank = true;
            var line_end = pos;

            // Check if line is blank
            while (line_end < state.text_len and state.text_buffer[line_end] != '\n') {
                if (state.text_buffer[line_end] != ' ' and state.text_buffer[line_end] != '\t') {
                    is_blank = false;
                    found_content = true;
                }
                line_end += 1;
            }

            if (is_blank and found_content) {
                return line_start;
            }

            // Move to previous line
            if (pos == 0) break;
            pos -= 1;
            while (pos > 0 and state.text_buffer[pos - 1] != '\n') {
                pos -= 1;
            }
        }

        return 0;
    }
};
