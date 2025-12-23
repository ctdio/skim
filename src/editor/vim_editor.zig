const std = @import("std");
const vaxis = @import("vaxis");
const Allocator = std.mem.Allocator;

/// Centralized vim-style text editor with modal interface.
/// Used by both comment editor and agent input editor.
pub fn VimEditor(comptime buffer_size: usize) type {
    return struct {
        const Self = @This();

        pub const State = struct {
            text_buffer: [buffer_size]u8,
            text_len: usize,
            cursor_pos: usize,
            vim_mode: VimMode,
            visual_anchor: ?usize,
            pending_find: ?PendingFind,
            pending_operator: ?PendingOperator,
            pending_replace: bool,
            pending_z: bool,
            pending_text_object: ?TextObject,
            yank_buffer: [buffer_size]u8,
            yank_len: usize,
            count_prefix: ?usize,
            undo_stack: [32]UndoState,
            undo_count: usize,
            undo_index: usize,
            last_find: ?LastFind,
            last_change: ?LastChange,
            command_buffer: [256]u8,
            command_len: usize,

            pub const VimMode = enum {
                normal,
                insert,
                visual,
                command,
            };

            pub const PendingFind = enum {
                f,
                t,
                F,
                T,
            };

            pub const PendingOperator = enum {
                d,
                y,
                c,
            };

            pub const TextObject = enum {
                iw,
                aw,
                i_quote,
                a_quote,
                i_paren,
                a_paren,
                i_bracket,
                a_bracket,
                i_brace,
                a_brace,
            };

            pub const UndoState = struct {
                text: [buffer_size]u8,
                text_len: usize,
                cursor_pos: usize,
            };

            pub const LastFind = struct {
                command: PendingFind,
                char: u8,
            };

            pub const LastChange = struct {
                operator: PendingOperator,
                motion: ?u8,
                count: ?usize,
            };

            pub fn init() State {
                return initWithMode(.insert);
            }

            pub fn initWithMode(mode: VimMode) State {
                var state: State = undefined;
                @memset(&state.text_buffer, 0);
                @memset(&state.yank_buffer, 0);
                @memset(&state.command_buffer, 0);
                state.text_len = 0;
                state.cursor_pos = 0;
                state.vim_mode = mode;
                state.visual_anchor = null;
                state.pending_find = null;
                state.pending_operator = null;
                state.pending_replace = false;
                state.pending_z = false;
                state.pending_text_object = null;
                state.yank_len = 0;
                state.count_prefix = null;
                state.undo_count = 0;
                state.undo_index = 0;
                state.last_find = null;
                state.last_change = null;
                state.command_len = 0;
                return state;
            }

            pub fn getText(self: *const State) []const u8 {
                return self.text_buffer[0..self.text_len];
            }

            pub fn clear(self: *State) void {
                @memset(&self.text_buffer, 0);
                self.text_len = 0;
                self.cursor_pos = 0;
                self.vim_mode = .insert;
                self.visual_anchor = null;
                self.pending_find = null;
                self.pending_operator = null;
                self.pending_replace = false;
                self.count_prefix = null;
            }

            pub fn isEmpty(self: *const State) bool {
                return self.text_len == 0;
            }

            pub fn setText(self: *State, text: []const u8) void {
                const copy_len = @min(text.len, buffer_size);
                @memcpy(self.text_buffer[0..copy_len], text[0..copy_len]);
                self.text_len = copy_len;
                self.cursor_pos = @min(self.cursor_pos, copy_len);
            }
        };

        pub const SaveAction = enum {
            save,
            cancel,
        };

        /// Handle key input based on current vim mode.
        /// Returns SaveAction if editor should exit.
        pub fn handleKey(state: *State, key: vaxis.Key, allocator: Allocator) !?SaveAction {
            // Ctrl+S - save (works in all modes)
            if (key.mods.ctrl and key.codepoint == 's') {
                return .save;
            }

            switch (state.vim_mode) {
                .normal => return try handleNormalMode(state, key, allocator),
                .insert => return try handleInsertMode(state, key),
                .visual => return try handleVisualMode(state, key, allocator),
                .command => return try handleCommandMode(state, key),
            }
        }

        fn handleNormalMode(state: *State, key: vaxis.Key, allocator: Allocator) !?SaveAction {
            // Ctrl+R for redo
            if (key.mods.ctrl and key.codepoint == 'r') {
                performRedo(state);
                return null;
            }

            // Ctrl+D for page down
            if (key.mods.ctrl and key.codepoint == 'd') {
                const count = state.count_prefix orelse 1;
                var i: usize = 0;
                while (i < count * 10) : (i += 1) {
                    moveCursorDown(state);
                }
                state.count_prefix = null;
                return null;
            }

            // Ctrl+U for page up
            if (key.mods.ctrl and key.codepoint == 'u') {
                const count = state.count_prefix orelse 1;
                var i: usize = 0;
                while (i < count * 10) : (i += 1) {
                    moveCursorUp(state);
                }
                state.count_prefix = null;
                return null;
            }

            // Ctrl+W to exit
            if (key.mods.ctrl and key.codepoint == 'w') {
                return .cancel;
            }

            // Handle pending replace
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

            // Handle pending find commands
            if (state.pending_find) |find_cmd| {
                if (key.codepoint >= 32 and key.codepoint < 127) {
                    const target_char: u8 = @intCast(key.codepoint);
                    state.last_find = .{ .command = find_cmd, .char = target_char };
                    try executeFind(state, find_cmd, target_char);
                    state.pending_find = null;
                }
                return null;
            }

            // Handle count prefix
            if (key.codepoint >= '0' and key.codepoint <= '9') {
                const digit = key.codepoint - '0';
                if (state.count_prefix) |current| {
                    state.count_prefix = current * 10 + digit;
                } else if (digit != 0) {
                    state.count_prefix = digit;
                } else {
                    state.cursor_pos = findLineStart(state.*);
                }
                return null;
            }

            // Handle pending operator + motion
            if (state.pending_operator) |operator| {
                const count = state.count_prefix orelse 1;

                // Double operator (dd, yy, cc)
                const is_line_operation = switch (operator) {
                    .d => key.codepoint == 'd',
                    .y => key.codepoint == 'y',
                    .c => key.codepoint == 'c',
                };

                if (is_line_operation) {
                    pushUndo(state);
                    const line_start = findLineStart(state.*);
                    var line_end = findLineEnd(state.*);

                    var lines: usize = 1;
                    while (lines < count and line_end < state.text_len) : (lines += 1) {
                        if (state.text_buffer[line_end] == '\n') line_end += 1;
                        while (line_end < state.text_len and state.text_buffer[line_end] != '\n') {
                            line_end += 1;
                        }
                    }

                    if (line_end < state.text_len and state.text_buffer[line_end] == '\n') {
                        line_end += 1;
                    }

                    try executeOperator(state, operator, line_start, line_end, allocator);
                    state.pending_operator = null;
                    state.count_prefix = null;
                    return null;
                }

                // Line-wise motions (j/k)
                if (key.codepoint == 'j' or key.codepoint == 'k') {
                    pushUndo(state);
                    const line_start = findLineStart(state.*);
                    var line_end = findLineEnd(state.*);

                    var lines: usize = 0;
                    while (lines < count) : (lines += 1) {
                        if (key.codepoint == 'j') {
                            if (line_end < state.text_len) {
                                if (state.text_buffer[line_end] == '\n') line_end += 1;
                                while (line_end < state.text_len and state.text_buffer[line_end] != '\n') {
                                    line_end += 1;
                                }
                            }
                        }
                    }

                    if (line_end < state.text_len and state.text_buffer[line_end] == '\n') {
                        line_end += 1;
                    }

                    try executeOperator(state, operator, line_start, line_end, allocator);
                    state.pending_operator = null;
                    state.count_prefix = null;
                    return null;
                }

                // Execute motion
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
                            state.pending_operator = null;
                            state.count_prefix = null;
                            return null;
                        },
                    };
                }

                try executeOperator(state, operator, start_pos, end_pos, allocator);
                state.pending_operator = null;
                state.count_prefix = null;
                return null;
            }

            const count = state.count_prefix orelse 1;

            switch (key.codepoint) {
                'u' => {
                    performUndo(state);
                    state.count_prefix = null;
                },
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
                's' => {
                    pushUndo(state);
                    if (state.cursor_pos < state.text_len) {
                        try deleteChar(state, state.cursor_pos);
                    }
                    state.vim_mode = .insert;
                    state.count_prefix = null;
                },
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
                '^' => {
                    var pos = findLineStart(state.*);
                    while (pos < state.text_len and (state.text_buffer[pos] == ' ' or state.text_buffer[pos] == '\t')) {
                        pos += 1;
                    }
                    state.cursor_pos = pos;
                    state.count_prefix = null;
                },
                'g' => {
                    if (state.count_prefix == null) {
                        state.count_prefix = 999; // Flag for 'g' pressed
                    } else {
                        state.cursor_pos = 0;
                        state.count_prefix = null;
                    }
                },
                'G' => {
                    state.cursor_pos = state.text_len;
                    state.count_prefix = null;
                },
                '{' => {
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        state.cursor_pos = findPrevParagraph(state.*);
                    }
                    state.count_prefix = null;
                },
                '}' => {
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        state.cursor_pos = findNextParagraph(state.*);
                    }
                    state.count_prefix = null;
                },
                'v' => {
                    state.visual_anchor = state.cursor_pos;
                    state.vim_mode = .visual;
                    state.count_prefix = null;
                },
                ':' => {
                    state.command_len = 0;
                    state.vim_mode = .command;
                    state.count_prefix = null;
                },
                'f' => state.pending_find = .f,
                't' => state.pending_find = .t,
                'F' => state.pending_find = .F,
                'T' => state.pending_find = .T,
                ';' => {
                    if (state.last_find) |last| {
                        var i: usize = 0;
                        while (i < count) : (i += 1) {
                            try executeFind(state, last.command, last.char);
                        }
                    }
                    state.count_prefix = null;
                },
                ',' => {
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
                'r' => {
                    state.pending_replace = true;
                    state.count_prefix = null;
                },
                'x' => {
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
                'C' => {
                    pushUndo(state);
                    const line_end = findLineEnd(state.*);
                    while (state.cursor_pos < line_end) {
                        try deleteChar(state, state.cursor_pos);
                    }
                    state.vim_mode = .insert;
                    state.count_prefix = null;
                },
                'D' => {
                    pushUndo(state);
                    const line_end = findLineEnd(state.*);
                    while (state.cursor_pos < line_end) {
                        try deleteChar(state, state.cursor_pos);
                    }
                    state.count_prefix = null;
                },
                'Y' => {
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
                'p' => {
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        try pasteAfterCursor(state, allocator);
                    }
                    state.count_prefix = null;
                },
                'P' => {
                    pushUndo(state);
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        for (0..state.yank_len) |j| {
                            if (state.text_len >= state.text_buffer.len) break;
                            try insertChar(state, state.yank_buffer[j]);
                        }
                        if (state.yank_len > 0 and state.cursor_pos >= state.yank_len) {
                            state.cursor_pos -= state.yank_len;
                        }
                    }
                    state.count_prefix = null;
                },
                'J' => {
                    pushUndo(state);
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        const line_end = findLineEnd(state.*);
                        if (line_end < state.text_len and state.text_buffer[line_end] == '\n') {
                            state.text_buffer[line_end] = ' ';
                        }
                    }
                    state.count_prefix = null;
                },
                'M' => centerCursor(state),
                27 => {
                    state.pending_find = null;
                    state.pending_operator = null;
                    state.pending_replace = false;
                    state.count_prefix = null;
                },
                else => state.count_prefix = null,
            }

            return null;
        }

        fn handleInsertMode(state: *State, key: vaxis.Key) !?SaveAction {
            // Ctrl+W - exit
            if (key.mods.ctrl and key.codepoint == 'w') {
                return .cancel;
            }

            // ESC or Ctrl+C - return to normal mode
            if (key.codepoint == 27 or (key.codepoint == 'c' and key.mods.ctrl)) {
                state.vim_mode = .normal;
                if (state.cursor_pos > 0) {
                    state.cursor_pos -= 1;
                }
                return null;
            }

            // Shift+Enter or Ctrl+J - insert newline
            if (key.matches(vaxis.Key.enter, .{ .shift = true }) or
                (key.mods.ctrl and key.codepoint == 'j'))
            {
                try insertChar(state, '\n');
                return null;
            }

            // Enter (no modifiers) - save
            if (key.matches(vaxis.Key.enter, .{})) {
                return .save;
            }

            switch (key.codepoint) {
                127, 8 => {
                    if (state.cursor_pos > 0) {
                        try deleteChar(state, state.cursor_pos - 1);
                        state.cursor_pos -= 1;
                    }
                },
                else => {
                    if (key.codepoint >= 32 and key.codepoint < 127) {
                        try insertChar(state, @intCast(key.codepoint));
                    }
                },
            }

            return null;
        }

        fn handleVisualMode(state: *State, key: vaxis.Key, allocator: Allocator) !?SaveAction {
            // Ctrl+W - exit
            if (key.mods.ctrl and key.codepoint == 'w') {
                return .cancel;
            }

            // Handle pending find commands
            if (state.pending_find) |find_cmd| {
                if (key.codepoint >= 32 and key.codepoint < 127) {
                    const target_char: u8 = @intCast(key.codepoint);
                    state.last_find = .{ .command = find_cmd, .char = target_char };
                    try executeFind(state, find_cmd, target_char);
                    state.pending_find = null;
                } else if (key.codepoint == 27) {
                    state.pending_find = null;
                }
                return null;
            }

            // Handle count prefix
            if (key.codepoint >= '0' and key.codepoint <= '9') {
                const digit = key.codepoint - '0';
                if (state.count_prefix) |current| {
                    state.count_prefix = current * 10 + digit;
                } else if (digit != 0) {
                    state.count_prefix = digit;
                } else {
                    state.cursor_pos = findLineStart(state.*);
                }
                return null;
            }

            switch (key.codepoint) {
                27 => {
                    state.vim_mode = .normal;
                    state.visual_anchor = null;
                },
                'v' => {
                    state.vim_mode = .normal;
                    state.visual_anchor = null;
                },
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
                'f' => state.pending_find = .f,
                't' => state.pending_find = .t,
                'F' => state.pending_find = .F,
                'T' => state.pending_find = .T,
                ';' => {
                    if (state.last_find) |last| {
                        const repeat_count = state.count_prefix orelse 1;
                        var i: usize = 0;
                        while (i < repeat_count) : (i += 1) {
                            state.count_prefix = 1;
                            try executeFind(state, last.command, last.char);
                        }
                    }
                },
                ',' => {
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
                            state.count_prefix = 1;
                            try executeFind(state, opposite, last.char);
                        }
                    }
                },
                'y' => {
                    state.count_prefix = null;
                    const selection = getVisualSelection(state.*) orelse return null;
                    const start = selection.start;
                    const end = selection.end;

                    const yank_size = end - start;
                    if (yank_size > 0 and yank_size <= state.yank_buffer.len) {
                        @memcpy(state.yank_buffer[0..yank_size], state.text_buffer[start..end]);
                        state.yank_len = yank_size;

                        copyToSystemClipboard(state.text_buffer[start..end], allocator) catch |err| {
                            std.log.err("Failed to copy to system clipboard: {any}", .{err});
                        };
                    }

                    state.vim_mode = .normal;
                    state.visual_anchor = null;
                },
                'd' => {
                    state.count_prefix = null;
                    const selection = getVisualSelection(state.*) orelse return null;
                    const start = selection.start;
                    const end = selection.end;

                    var pos = end;
                    while (pos > start) {
                        pos -= 1;
                        try deleteChar(state, pos);
                    }

                    state.cursor_pos = start;
                    state.vim_mode = .normal;
                    state.visual_anchor = null;
                },
                else => state.count_prefix = null,
            }

            return null;
        }

        fn handleCommandMode(state: *State, key: vaxis.Key) !?SaveAction {
            if (key.codepoint == 27) {
                state.vim_mode = .normal;
                state.command_len = 0;
                return null;
            }

            if (key.matches(vaxis.Key.enter, .{})) {
                const command = state.command_buffer[0..state.command_len];

                if (std.mem.eql(u8, command, "w")) {
                    return .save;
                } else if (std.mem.eql(u8, command, "q")) {
                    return .cancel;
                } else if (std.mem.eql(u8, command, "wq")) {
                    return .save;
                } else {
                    state.vim_mode = .normal;
                    state.command_len = 0;
                }
                return null;
            }

            if (key.codepoint == 127 or key.codepoint == 8) {
                if (state.command_len > 0) {
                    state.command_len -= 1;
                }
                return null;
            }

            if (key.codepoint >= 32 and key.codepoint < 127) {
                if (state.command_len < state.command_buffer.len) {
                    state.command_buffer[state.command_len] = @intCast(key.codepoint);
                    state.command_len += 1;
                }
            }

            return null;
        }

        // =====================================================================
        // Helper functions
        // =====================================================================

        fn executeFind(state: *State, cmd: State.PendingFind, target_char: u8) !void {
            const line_start = findLineStart(state.*);
            const line_end = findLineEnd(state.*);
            const count = state.count_prefix orelse 1;
            state.count_prefix = null;

            var found_count: usize = 0;

            switch (cmd) {
                .f => {
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
                .t => {
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
                .F => {
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
                .T => {
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

        fn getVisualSelection(state: State) ?struct { start: usize, end: usize } {
            const anchor = state.visual_anchor orelse return null;
            const cursor = state.cursor_pos;

            const start = @min(anchor, cursor);
            var end = @max(anchor, cursor);

            if (end < state.text_len) {
                end += 1;
            }

            return .{ .start = start, .end = end };
        }

        fn insertChar(state: *State, char: u8) !void {
            insertCharImpl(state, char);
        }

        fn insertCharImpl(state: *State, char: u8) void {
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

        pub fn insertCharPublic(state: *State, char: u8) void {
            insertCharImpl(state, char);
        }

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

        fn findLineStart(state: State) usize {
            var pos = state.cursor_pos;
            while (pos > 0 and state.text_buffer[pos - 1] != '\n') {
                pos -= 1;
            }
            return pos;
        }

        fn findLineEnd(state: State) usize {
            var pos = state.cursor_pos;
            while (pos < state.text_len and state.text_buffer[pos] != '\n') {
                pos += 1;
            }
            return pos;
        }

        fn moveCursorDown(state: *State) void {
            const current_line_start = findLineStart(state.*);
            const current_line_end = findLineEnd(state.*);
            const col_offset = state.cursor_pos - current_line_start;

            if (current_line_end < state.text_len) {
                const next_line_start = current_line_end + 1;
                var next_line_end = next_line_start;
                while (next_line_end < state.text_len and state.text_buffer[next_line_end] != '\n') {
                    next_line_end += 1;
                }

                const next_line_len = next_line_end - next_line_start;
                state.cursor_pos = next_line_start + @min(col_offset, next_line_len);
            }
        }

        fn moveCursorUp(state: *State) void {
            const current_line_start = findLineStart(state.*);
            const col_offset = state.cursor_pos - current_line_start;

            if (current_line_start > 0) {
                const prev_line_end = current_line_start - 1;
                var prev_line_start = prev_line_end;
                while (prev_line_start > 0 and state.text_buffer[prev_line_start - 1] != '\n') {
                    prev_line_start -= 1;
                }

                const prev_line_len = prev_line_end - prev_line_start;
                state.cursor_pos = prev_line_start + @min(col_offset, prev_line_len);
            }
        }

        fn centerCursor(state: *State) void {
            if (state.text_len == 0) return;

            var line_count: usize = 1;
            var i: usize = 0;
            while (i < state.text_len) : (i += 1) {
                if (state.text_buffer[i] == '\n') {
                    line_count += 1;
                }
            }

            const middle_line = line_count / 2;

            var current_line: usize = 0;
            var pos: usize = 0;
            while (pos < state.text_len and current_line < middle_line) {
                if (state.text_buffer[pos] == '\n') {
                    current_line += 1;
                }
                pos += 1;
            }

            state.cursor_pos = pos;
        }

        fn findNextWordStart(state: State) usize {
            var pos = state.cursor_pos;

            while (pos < state.text_len and !isWordBoundary(state.text_buffer[pos])) {
                pos += 1;
            }

            while (pos < state.text_len and isWordBoundary(state.text_buffer[pos])) {
                pos += 1;
            }

            return pos;
        }

        fn findPrevWordStart(state: State) usize {
            if (state.cursor_pos == 0) return 0;

            var pos = state.cursor_pos - 1;

            while (pos > 0 and isWordBoundary(state.text_buffer[pos])) {
                pos -= 1;
            }

            while (pos > 0 and !isWordBoundary(state.text_buffer[pos - 1])) {
                pos -= 1;
            }

            return pos;
        }

        fn findWordEnd(state: State) usize {
            var pos = state.cursor_pos;

            if (pos < state.text_len and isWordBoundary(state.text_buffer[pos])) {
                while (pos < state.text_len and isWordBoundary(state.text_buffer[pos])) {
                    pos += 1;
                }
            }

            while (pos < state.text_len and !isWordBoundary(state.text_buffer[pos])) {
                pos += 1;
            }

            if (pos > state.cursor_pos) {
                pos -= 1;
            }

            return pos;
        }

        fn executeOperator(state: *State, operator: State.PendingOperator, start_pos: usize, end_pos: usize, allocator: Allocator) !void {
            const range_start = @min(start_pos, end_pos);
            const range_end = @max(start_pos, end_pos);

            switch (operator) {
                .y => {
                    const yank_size = range_end - range_start;
                    if (yank_size > 0 and yank_size <= state.yank_buffer.len) {
                        @memcpy(state.yank_buffer[0..yank_size], state.text_buffer[range_start..range_end]);
                        state.yank_len = yank_size;

                        copyToSystemClipboard(state.text_buffer[range_start..range_end], allocator) catch |err| {
                            std.log.err("Failed to copy to system clipboard: {any}", .{err});
                        };
                    }
                },
                .d => {
                    const yank_size = range_end - range_start;
                    if (yank_size > 0 and yank_size <= state.yank_buffer.len) {
                        @memcpy(state.yank_buffer[0..yank_size], state.text_buffer[range_start..range_end]);
                        state.yank_len = yank_size;

                        copyToSystemClipboard(state.text_buffer[range_start..range_end], allocator) catch |err| {
                            std.log.err("Failed to copy to system clipboard: {any}", .{err});
                        };
                    }

                    var pos = range_end;
                    while (pos > range_start) {
                        pos -= 1;
                        try deleteChar(state, pos);
                    }

                    state.cursor_pos = range_start;
                },
                .c => {
                    const yank_size = range_end - range_start;
                    if (yank_size > 0 and yank_size <= state.yank_buffer.len) {
                        @memcpy(state.yank_buffer[0..yank_size], state.text_buffer[range_start..range_end]);
                        state.yank_len = yank_size;

                        copyToSystemClipboard(state.text_buffer[range_start..range_end], allocator) catch |err| {
                            std.log.err("Failed to copy to system clipboard: {any}", .{err});
                        };
                    }

                    var pos = range_end;
                    while (pos > range_start) {
                        pos -= 1;
                        try deleteChar(state, pos);
                    }

                    state.cursor_pos = range_start;
                    state.vim_mode = .insert;
                },
            }
        }

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

        fn readFromSystemClipboard(allocator: Allocator) ![]const u8 {
            const argv = [_][]const u8{"pbpaste"};
            var child = std.process.Child.init(&argv, allocator);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Ignore;

            try child.spawn();

            const stdout = child.stdout.?;
            const output = try stdout.readToEndAlloc(allocator, 1024 * 1024);

            _ = try child.wait();

            return output;
        }

        fn pasteAfterCursor(state: *State, allocator: Allocator) !void {
            const clipboard_text = readFromSystemClipboard(allocator) catch null;
            defer if (clipboard_text) |text| allocator.free(text);

            if (state.cursor_pos < state.text_len) {
                state.cursor_pos += 1;
            }

            if (clipboard_text) |text| {
                for (text) |char| {
                    if (state.text_len >= state.text_buffer.len) break;
                    try insertChar(state, char);
                }
            } else if (state.yank_len > 0) {
                for (0..state.yank_len) |i| {
                    if (state.text_len >= state.text_buffer.len) break;
                    try insertChar(state, state.yank_buffer[i]);
                }
            } else {
                if (state.cursor_pos > 0) {
                    state.cursor_pos -= 1;
                }
                return;
            }

            if (state.cursor_pos > 0) {
                state.cursor_pos -= 1;
            }
        }

        fn isWordBoundary(char: u8) bool {
            return char == ' ' or char == '\n' or char == '\t' or char == '.' or char == ',' or char == ';';
        }

        fn pushUndo(state: *State) void {
            if (state.undo_count >= state.undo_stack.len) {
                var i: usize = 1;
                while (i < state.undo_stack.len) : (i += 1) {
                    state.undo_stack[i - 1] = state.undo_stack[i];
                }
                state.undo_count = state.undo_stack.len - 1;
            }

            if (state.undo_index < state.undo_count) {
                state.undo_count = state.undo_index;
            }

            const undo_state = &state.undo_stack[state.undo_count];
            @memcpy(undo_state.text[0..state.text_len], state.text_buffer[0..state.text_len]);
            undo_state.text_len = state.text_len;
            undo_state.cursor_pos = state.cursor_pos;

            state.undo_count += 1;
            state.undo_index = state.undo_count;
        }

        fn performUndo(state: *State) void {
            if (state.undo_index == 0) return;

            state.undo_index -= 1;
            const undo_state = &state.undo_stack[state.undo_index];

            @memcpy(state.text_buffer[0..undo_state.text_len], undo_state.text[0..undo_state.text_len]);
            state.text_len = undo_state.text_len;
            state.cursor_pos = undo_state.cursor_pos;
        }

        fn performRedo(state: *State) void {
            if (state.undo_index >= state.undo_count) return;

            const undo_state = &state.undo_stack[state.undo_index];

            @memcpy(state.text_buffer[0..undo_state.text_len], undo_state.text[0..undo_state.text_len]);
            state.text_len = undo_state.text_len;
            state.cursor_pos = undo_state.cursor_pos;

            state.undo_index += 1;
        }

        fn findNextParagraph(state: State) usize {
            var pos = state.cursor_pos;
            var found_content = false;

            while (pos < state.text_len and state.text_buffer[pos] != '\n') {
                pos += 1;
            }
            if (pos < state.text_len) pos += 1;

            while (pos < state.text_len) {
                const line_start = pos;
                var is_blank = true;

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

                if (pos < state.text_len) pos += 1;
            }

            return state.text_len;
        }

        fn findPrevParagraph(state: State) usize {
            if (state.cursor_pos == 0) return 0;

            var pos = state.cursor_pos;
            var found_content = false;

            while (pos > 0 and state.text_buffer[pos - 1] != '\n') {
                pos -= 1;
            }

            if (pos > 0) pos -= 1;
            while (pos > 0 and state.text_buffer[pos - 1] != '\n') {
                pos -= 1;
            }

            while (pos > 0) {
                const line_start = pos;
                var is_blank = true;
                var line_end = pos;

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

                if (pos == 0) break;
                pos -= 1;
                while (pos > 0 and state.text_buffer[pos - 1] != '\n') {
                    pos -= 1;
                }
            }

            return 0;
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

const TestEditor = VimEditor(4096);

test "VimEditor init" {
    var state = TestEditor.State.init();
    try std.testing.expect(state.isEmpty());
    try std.testing.expectEqual(TestEditor.State.VimMode.insert, state.vim_mode);
}

test "VimEditor insert characters" {
    var state = TestEditor.State.init();

    TestEditor.insertCharPublic(&state, 'h');
    TestEditor.insertCharPublic(&state, 'e');
    TestEditor.insertCharPublic(&state, 'l');
    TestEditor.insertCharPublic(&state, 'l');
    TestEditor.insertCharPublic(&state, 'o');

    try std.testing.expectEqualStrings("hello", state.getText());
    try std.testing.expectEqual(@as(usize, 5), state.cursor_pos);
}

test "VimEditor clear" {
    var state = TestEditor.State.init();
    TestEditor.insertCharPublic(&state, 'a');
    TestEditor.insertCharPublic(&state, 'b');

    state.clear();

    try std.testing.expect(state.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), state.cursor_pos);
}
