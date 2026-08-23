//! Browser-side diff session: one parsed diff, one in-memory screen, one key
//! dispatcher. This is the whole engine behind the wasm build; `main.zig` in
//! this directory is only the C ABI around it.
//!
//! The session renders through the same `UnifiedRenderer`/`SideBySideRenderer`
//! the TUI uses, into the mock `vaxis.Screen` from `testing/harness.zig`, and
//! returns ANSI text for xterm.js. `cli/print.zig` drives the same pipeline for
//! `skim print`.
//!
//! Only the pure part of normal mode is reachable here. Keys that shell out to
//! git, an editor, an agent, or the clipboard have no meaning in a browser, so
//! `handleKey` maps a subset rather than calling `modes/normal_mode.zig`.

const std = @import("std");
const vaxis = @import("vaxis");
const core = @import("web_core");

const Allocator = std.mem.Allocator;
const App = core.App;
const Language = core.Language;
const Navigation = core.Navigation;
const StateHelpers = core.StateHelpers;
const SyntaxHighlighter = core.SyntaxHighlighter;
const folds = core.folds;
const harness = core.harness;
const Layout = core.Layout;
const SideBySideRenderer = core.SideBySideRenderer;
const UI = core.UI;
const UnifiedRenderer = core.UnifiedRenderer;
const hunk_view = core.hunk_view;
const parser = core.parser;
const help = core.help;
const search_mode = core.search_mode;
const visual_mode = core.visual_mode;
const help_mode = core.help_mode;
const command_palette_mode = core.command_palette_mode;
const command_palette = core.command_palette;
const CommentController = core.CommentController;
const CommentEditor = core.CommentEditor;

pub const Params = struct {
    diff_text: []const u8,
    width: u16,
    height: u16,
};

/// One open diff. Holds the App, the screen it draws into, and the ANSI text of
/// the last frame. The caller owns nothing: `ansi` stays valid until the next
/// `render` or `deinit`.
pub const Session = struct {
    allocator: Allocator,
    app: App,
    ctx: harness.TestContext,
    ansi: []const u8,

    pub fn init(allocator: Allocator, params: Params) !Session {
        const files = try parser.parse(allocator, params.diff_text);
        errdefer {
            for (files) |*file| file.deinit(allocator);
            allocator.free(files);
        }

        var app = try App.initForRenderBench(allocator, files);
        errdefer freeApp(allocator, &app);

        highlightAll(allocator, app.state.files, &app.syntax_highlighter);

        var ctx = try harness.createTestContext(allocator, params.width, params.height);
        errdefer ctx.deinit();

        var session = Session{
            .allocator = allocator,
            .app = app,
            .ctx = ctx,
            .ansi = &.{},
        };

        // Prime `viewport_height`/`viewport_width`, which the renderer sets and
        // every navigation key reads. Without this the first key moves against a
        // zero-height viewport.
        _ = try session.render();
        return session;
    }

    pub fn deinit(self: *Session) void {
        self.allocator.free(self.ansi);
        self.ctx.deinit();
        freeApp(self.allocator, &self.app);
    }

    pub fn resize(self: *Session, width: u16, height: u16) !void {
        const ctx = try harness.createTestContext(self.allocator, width, height);
        self.ctx.deinit();
        self.ctx = ctx;
        _ = try self.render();
    }

    /// Route one key to the mode that owns it. Only the modes a browser can
    /// serve are wired: normal, search, visual, comment, help, and the
    /// command palette.
    pub fn handleKey(self: *Session, raw: vaxis.Key) !void {
        const closing = isCloseChord(raw);
        const key: vaxis.Key = if (closing) .{ .codepoint = vaxis.Key.escape } else raw;
        switch (self.app.mode) {
            .search => try search_mode.handleKey(&self.app, key),
            .comment => try commentKey(&self.app, raw, closing),
            .visual => try visual_mode.handleKey(&self.app, key),
            .help => try help_mode.handleKey(&self.app, key),
            .command_palette => try command_palette_mode.handleKey(&self.app, key),
            else => try normalKey(&self.app, key),
        }
    }

    /// Draw the current state and return it as ANSI text for a terminal
    /// emulator. The returned slice is owned by the session.
    pub fn render(self: *Session) ![]const u8 {
        _ = self.ctx.arena.reset(.retain_capacity);

        try drawFrame(&self.app, self.ctx.window());

        const next = try self.ctx.captureToAnsi();
        self.allocator.free(self.ansi);
        self.ansi = next;
        self.app.needs_render = false;
        return self.ansi;
    }
};

// ===== Helpers =====

/// Compose one frame: header, diff content, status bar, and the help overlay.
///
/// `rendering/frame.zig` cannot be reused. It dispatches over every mode skim
/// has, and the branch-selection and empty menus call git during the render
/// itself (`ui.zig` -> `git.getDiffStats`), which does not compile for wasm.
/// This draws the same windows for the diff view alone.
fn drawFrame(app: *App, win: vaxis.Window) !void {
    win.clear();
    app.resetFrameAllocators();
    win.hideCursor();

    if (win.width == 0 or win.height == 0) return;
    app.state.viewport_width = win.width;
    if (app.state.files.len == 0) return;

    const content_height = win.height -| Layout.header_height -| Layout.status_height;

    try UI.renderHeader(app, win.child(.{
        .x_off = 0,
        .y_off = 0,
        .width = win.width,
        .height = Layout.header_height,
    }));

    const content_win = win.child(.{
        .x_off = 0,
        .y_off = Layout.header_height,
        .width = win.width,
        .height = content_height,
    });
    switch (app.state.view_mode) {
        .unified => try UnifiedRenderer.renderContent(app, content_win),
        .side_by_side => try SideBySideRenderer.renderContent(app, content_win),
    }

    try UI.renderStatus(app, win.child(.{
        .x_off = 0,
        .y_off = win.height -| Layout.status_height,
        .width = win.width,
        .height = Layout.status_height,
    }));

    if (app.mode == .help) try help.renderHelpPopup(app, win);
    if (app.mode == .command_palette) try command_palette.renderCommandPalette(app, win);
}

/// The browser-safe half of `modes/normal_mode.zig`. Keys that shell out to git,
/// an editor, an agent, the clipboard, or GitHub have no meaning here, so they
/// are left unmapped rather than stubbed.
fn normalKey(app: *App, key: vaxis.Key) !void {
    if (app.state.files.len == 0) return;

    if (app.state.pending_z) {
        app.state.pending_z = false;
        switch (key.codepoint) {
            27 => return,
            'z' => {
                Navigation.centerViewportOnCursor(app);
                app.state.cursor_column = 0;
                return;
            },
            'a' => return folds.toggleFoldUnderCursor(app),
            'c' => return folds.closeFoldUnderCursor(app),
            'o' => return folds.openFoldUnderCursor(app),
            'C' => return folds.closeFileFoldUnderCursor(app),
            'O' => return folds.openFileFoldUnderCursor(app),
            'M' => return folds.closeAllFoldsAndRebuild(app),
            'R' => return folds.openAllFoldsAndRebuild(app),
            else => {},
        }
    }

    if (app.state.pending_g) {
        app.state.pending_g = false;
        if (key.codepoint == 27) return;
        if (key.codepoint == 'g') {
            Navigation.scrollToTop(app);
            app.state.cursor_column = 0;
            return;
        }
    }

    if (app.state.pending_bracket) {
        app.state.pending_bracket = false;
        if (key.codepoint == 27) return;
        if (key.codepoint == 'h') {
            Navigation.jumpToPreviousCodeChange(app);
            app.state.cursor_column = 0;
            return;
        }
        if (key.codepoint == 'c') {
            Navigation.jumpToPreviousComment(app);
            app.state.cursor_column = 0;
            return;
        }
    }

    if (app.state.pending_close_bracket) {
        app.state.pending_close_bracket = false;
        if (key.codepoint == 27) return;
        if (key.codepoint == 'h') {
            Navigation.jumpToNextCodeChange(app);
            app.state.cursor_column = 0;
            return;
        }
        if (key.codepoint == 'c') {
            Navigation.jumpToNextComment(app);
            app.state.cursor_column = 0;
            return;
        }
    }

    if (app.state.pending_find) |command| {
        app.state.pending_find = null;
        if (key.codepoint == 27) return;
        if (key.codepoint <= 127) app.executeFindInLine(command, @intCast(key.codepoint));
        return;
    }

    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n' => {
                Navigation.navigateToNextFile(app);
                app.state.cursor_column = 0;
            },
            'p', 'P' => {
                if (key.mods.shift or key.codepoint == 'P') {
                    try app.startCommandPaletteInCommandMode();
                } else {
                    try app.startCommandPalette();
                }
            },
            'd' => {
                Navigation.pageDown(app);
                app.state.cursor_column = 0;
            },
            'u' => {
                Navigation.pageUp(app);
                app.state.cursor_column = 0;
            },
            'f' => {
                Navigation.fullPageDown(app);
                app.state.cursor_column = 0;
            },
            'b' => {
                Navigation.fullPageUp(app);
                app.state.cursor_column = 0;
            },
            else => {},
        }
        return;
    }

    if (!key.mods.alt and !key.mods.shift) {
        if (key.codepoint >= '1' and key.codepoint <= '9') {
            const digit: usize = @intCast(key.codepoint - '0');
            app.state.count_prefix = if (app.state.count_prefix) |count| count * 10 + digit else digit;
            return;
        }
        if (key.codepoint == '0' and app.state.count_prefix != null) {
            app.state.count_prefix = app.state.count_prefix.? * 10;
            return;
        }
    }

    switch (key.codepoint) {
        'j', vaxis.Key.down => {
            Navigation.moveCursorDown(app);
            app.state.cursor_column = 0;
        },
        'k', vaxis.Key.up => {
            Navigation.moveCursorUp(app);
            app.state.cursor_column = 0;
        },
        'h' => {
            Navigation.navigateToPreviousFile(app);
            app.state.cursor_column = 0;
        },
        'l' => {
            Navigation.navigateToNextFile(app);
            app.state.cursor_column = 0;
        },
        'g' => app.state.pending_g = true,
        'G' => {
            Navigation.scrollToBottom(app);
            app.state.cursor_column = 0;
        },
        ' ', vaxis.Key.page_down => {
            Navigation.fullPageDown(app);
            app.state.cursor_column = 0;
        },
        'b', vaxis.Key.page_up => {
            Navigation.fullPageUp(app);
            app.state.cursor_column = 0;
        },
        'M' => {
            Navigation.centerCursor(app);
            app.state.cursor_column = 0;
        },
        's' => app.toggleViewMode(),
        '\t' => {
            if (key.mods.shift) {
                try hunk_view.cycleHunkViewModePrev(app);
            } else {
                try hunk_view.cycleHunkViewMode(app);
            }
        },
        '/' => app.startSearch(),
        ':' => try app.startCommandPaletteInCommandMode(),
        'n' => {
            app.searchNext();
            app.state.cursor_column = 0;
        },
        'N' => {
            app.searchPrevious();
            app.state.cursor_column = 0;
        },
        'v', 'V' => app.startVisualMode(),
        'f' => app.state.pending_find = .f,
        't' => app.state.pending_find = .t,
        'F' => app.state.pending_find = .F,
        'T' => app.state.pending_find = .T,
        ';' => {
            if (app.state.last_find) |last| app.executeFindInLine(last.command, last.char);
        },
        'z' => app.state.pending_z = true,
        '[' => app.state.pending_bracket = true,
        ']' => app.state.pending_close_bracket = true,
        '{' => {
            Navigation.jumpToPreviousEmptyLine(app);
            app.state.cursor_column = 0;
        },
        '}' => {
            Navigation.jumpToNextEmptyLine(app);
            app.state.cursor_column = 0;
        },
        vaxis.Key.enter => try CommentController.startCommentInput(app),
        'd' => try CommentController.deleteCommentUnderCursor(app),
        'D' => try CommentController.clearAllComments(app),
        'o' => CommentController.toggleCommentUnderCursorExpanded(app),
        '?' => app.mode = .help,
        27 => app.mode = .normal,
        else => app.state.count_prefix = null,
    }
}

/// Whether a key means "close whatever is open".
///
/// A terminal sends 0x1b for Ctrl-[ and reads Ctrl-C as "close this", but a
/// browser reports both as a letter with the control bit set, so the session
/// recognises them itself. Neither key ever ends a session — there is nothing
/// behind the page to return to — so every mode treats them as its cancel key.
fn isCloseChord(key: vaxis.Key) bool {
    return key.mods.ctrl and (key.codepoint == 'c' or key.codepoint == '[');
}

/// Highlight every hunk up front. The TUI does this on a worker thread; wasm has
/// no threads, and a whole diff costs a few tens of milliseconds once.
fn highlightAll(allocator: Allocator, files: []parser.FileDiff, highlighter: *SyntaxHighlighter) void {
    for (files) |*file| {
        const path = if (file.new_path.len > 0) file.new_path else file.old_path;
        if (Language.fromFilePath(path) == .unknown) continue;

        for (file.hunks) |*hunk| {
            if (hunk.highlights == null) {
                const content = StateHelpers.buildHunkContent(allocator, hunk) catch continue;
                defer allocator.free(content);
                if (highlighter.highlightFile(path, content)) |spans| {
                    hunk.highlights = spans;
                } else |_| {}
            }
            if (hunk.old_highlights == null) {
                const content = StateHelpers.buildHunkOldContent(allocator, hunk) catch continue;
                defer allocator.free(content);
                if (highlighter.highlightFile(path, content)) |spans| {
                    hunk.old_highlights = spans;
                } else |_| {}
            }
        }
    }
}

/// Release exactly what `App.initForRenderBench` and `Session.init` allocated.
/// `App.deinit` cannot be used: it joins worker threads and closes sockets and
/// child processes, none of which exist on wasm. The "session leaves no memory
/// behind" test guards this list against drift.
fn freeApp(allocator: Allocator, app: *App) void {
    app.state.line_map.deinit();
    app.state.comment_store.deinit();
    app.state.search_state.deinit();
    app.state.command_palette_state.deinit();
    app.state.expanded_comments.deinit();
    app.state.collapsed_folds.deinit();
    app.state.branch_stats_cache.deinit();
    app.pending_highlight_jobs.deinit();
    app.frame_segment_arena.deinit();
    app.blame.deinit();
    app.syntax_highlighter.deinit();

    if (app.state.status_message_owned) |message| allocator.free(message);
    allocator.free(app.frame_text_buffer);
    allocator.free(app.state.git_repo_root);
    allocator.free(app.state.file_diff_stats);
    allocator.free(app.state.file_line_counts);

    for (app.state.files) |*file| file.deinit(allocator);
    allocator.free(app.state.files);
}

// ===== Tests =====

const test_diff =
    \\diff --git a/src/greet.zig b/src/greet.zig
    \\index 1111111..2222222 100644
    \\--- a/src/greet.zig
    \\+++ b/src/greet.zig
    \\@@ -1,5 +1,6 @@
    \\ const std = @import("std");
    \\
    \\-pub fn greet() void {
    \\-    std.debug.print("hi\n", .{});
    \\+pub fn greet(name: []const u8) void {
    \\+    std.debug.print("hi {s}\n", .{name});
    \\+    std.debug.print("bye\n", .{});
    \\ }
    \\
;

const two_file_diff = test_diff ++
    \\diff --git a/src/farewell.zig b/src/farewell.zig
    \\index 3333333..4444444 100644
    \\--- a/src/farewell.zig
    \\+++ b/src/farewell.zig
    \\@@ -1,3 +1,4 @@
    \\ pub fn farewell() void {
    \\-    std.debug.print("bye\n", .{});
    \\+    std.debug.print("bye for now\n", .{});
    \\+    std.debug.print("take care\n", .{});
    \\ }
    \\
;

fn openTwoFileSession(allocator: Allocator) !Session {
    return Session.init(allocator, .{
        .diff_text = two_file_diff,
        .width = 80,
        .height = 24,
    });
}

fn openTestSession(allocator: Allocator) !Session {
    return Session.init(allocator, .{
        .diff_text = test_diff,
        .width = 80,
        .height = 24,
    });
}

fn press(session: *Session, codepoint: u21) !void {
    try session.handleKey(.{ .codepoint = codepoint });
}

/// Render, then read the screen back as plain text. `Session.render` returns
/// ANSI, where escape codes split words apart and defeat a substring match.
/// Caller owns the result.
fn renderPlain(session: *Session) ![]const u8 {
    _ = try session.render();
    return session.ctx.captureToText();
}

/// Comment mode: the vim editor owns every key. `modes/comment_mode.zig` cannot
/// be reused because its Ctrl-E branch opens the agent panel, which spawns a
/// process and so does not compile for wasm.
fn commentKey(app: *App, key: vaxis.Key, closing: bool) !void {
    const input = &(app.state.active_comment_input orelse return);

    // The editor's own exit key is Ctrl-W, which a browser keeps for itself, so
    // the box would otherwise trap the visitor. A close chord cancels it, and so
    // does Escape once the editor is in vim normal mode, where Escape has
    // nothing left to undo.
    if (closing or (key.codepoint == vaxis.Key.escape and input.vim.vim_mode == .normal)) {
        app.mode = .normal;
        app.state.active_comment_input = null;
        return;
    }

    const action = try CommentEditor.handleKey(input, key, app.allocator) orelse {
        Navigation.ensureCommentBoxVisible(app);
        return;
    };

    switch (action) {
        .save => {
            if (try CommentController.saveCurrentComment(app)) {
                app.mode = .normal;
                app.state.active_comment_input = null;
            }
        },
        .cancel => {
            app.mode = .normal;
            app.state.active_comment_input = null;
        },
    }
}

/// Advance the cursor to the first code line, which is the only line type that
/// accepts a comment.
fn moveToCodeLine(session: *Session) !void {
    const total = session.app.state.line_map.getTotalLines();
    var steps: usize = 0;
    while (steps <= total) : (steps += 1) {
        const record = session.app.state.line_map.getLineRecord(session.app.state.global_cursor_line) orelse
            return error.NoLineRecord;
        if (record.line_type == .code_line) return;
        try press(session, 'j');
    }
    return error.NoCodeLine;
}

fn selectedCommandName(session: *Session) []const u8 {
    return session.app.state.command_palette_state.getSelectedCommand().?.name;
}

fn typeText(session: *Session, text: []const u8) !void {
    for (text) |char| try press(session, char);
}

fn countCodepoints(text: []const u8) usize {
    var count: usize = 0;
    var view = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (view.nextCodepoint()) |_| count += 1;
    return count;
}

test "render shows the path of the changed file" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    const output = try renderPlain(&session);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "src/greet.zig") != null);
}

test "render shows an added line from the diff" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    const output = try renderPlain(&session);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "pub fn greet(name: []const u8) void {") != null);
}

test "j moves the cursor down one line" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    const before = session.app.state.global_cursor_line;
    try press(&session, 'j');
    try std.testing.expectEqual(before + 1, session.app.state.global_cursor_line);
}

test "k after j returns the cursor to where it started" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    const before = session.app.state.global_cursor_line;
    try press(&session, 'j');
    try press(&session, 'k');
    try std.testing.expectEqual(before, session.app.state.global_cursor_line);
}

test "zM folds every file so no code line is rendered" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try press(&session, 'z');
    try press(&session, 'M');

    const output = try renderPlain(&session);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "src/greet.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pub fn greet") == null);
}

test "zR after zM brings the code lines back" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try press(&session, 'z');
    try press(&session, 'M');
    try press(&session, 'z');
    try press(&session, 'R');

    const output = try renderPlain(&session);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "pub fn greet") != null);
}

test "s switches the view to side by side" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try press(&session, 's');
    try std.testing.expect(session.app.state.view_mode == .side_by_side);
}

test "search jumps the cursor to the matched line" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try press(&session, '/');
    for ("bye") |char| try press(&session, char);
    try session.handleKey(.{ .codepoint = vaxis.Key.enter });

    const record = session.app.state.line_map.getLineRecord(session.app.state.global_cursor_line);
    try std.testing.expect(record != null);
    try std.testing.expect(session.app.state.search_state.hasMatches());
}

test "resize changes the width of the rendered frame" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try session.resize(40, 10);
    const output = try renderPlain(&session);
    defer std.testing.allocator.free(output);

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(countCodepoints(line) <= 40);
    }
    try std.testing.expectEqual(@as(usize, 40), session.app.state.viewport_width);
}

test "a diff with no file changes still opens a session" {
    var session = try Session.init(std.testing.allocator, .{
        .diff_text = "",
        .width = 80,
        .height = 24,
    });
    defer session.deinit();

    try std.testing.expectEqual(@as(usize, 0), session.app.state.files.len);
}

test "a session leaves no memory behind" {
    var session = try openTestSession(std.testing.allocator);
    session.deinit();
}

test "an unmapped key leaves the cursor where it was" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    const before = session.app.state.global_cursor_line;
    try press(&session, 'r');
    try std.testing.expectEqual(before, session.app.state.global_cursor_line);
}

test "enter on a code line opens the comment editor" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try moveToCodeLine(&session);
    try press(&session, vaxis.Key.enter);
    try std.testing.expectEqual(App.Mode.comment, session.app.mode);
}

test "a saved comment renders under the code line" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try moveToCodeLine(&session);
    try press(&session, vaxis.Key.enter);
    try typeText(&session, "needs a test");
    try press(&session, vaxis.Key.enter);

    try std.testing.expectEqual(App.Mode.normal, session.app.mode);
    const output = try renderPlain(&session);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "needs a test") != null);
}

test "ctrl-w leaves the comment editor without saving" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try moveToCodeLine(&session);
    try press(&session, vaxis.Key.enter);
    try typeText(&session, "throw this away");
    try session.handleKey(.{ .codepoint = 'w', .mods = .{ .ctrl = true } });

    try std.testing.expectEqual(App.Mode.normal, session.app.mode);
    try std.testing.expectEqual(@as(usize, 0), session.app.state.comment_store.comments.items.len);
}

test "d on a comment line deletes the comment" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try moveToCodeLine(&session);
    try press(&session, vaxis.Key.enter);
    try typeText(&session, "delete me");
    try press(&session, vaxis.Key.enter);
    try std.testing.expectEqual(@as(usize, 1), session.app.state.comment_store.comments.items.len);

    // Saving parks the cursor on the new comment line.
    const record = session.app.state.line_map.getLineRecord(session.app.state.global_cursor_line).?;
    try std.testing.expect(record.line_type == .comment_line);

    try press(&session, 'd');
    try std.testing.expectEqual(@as(usize, 0), session.app.state.comment_store.comments.items.len);
}

test "the comment editor shows a cursor in the input box" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try moveToCodeLine(&session);
    try press(&session, vaxis.Key.enter);
    _ = try session.render();
    try std.testing.expect(session.ctx.screen.cursor_vis);
}

test "]c jumps the cursor to the next comment" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try moveToCodeLine(&session);
    try press(&session, vaxis.Key.enter);
    try typeText(&session, "look here");
    try press(&session, vaxis.Key.enter);

    try press(&session, 'g');
    try press(&session, 'g');
    try press(&session, ']');
    try press(&session, 'c');

    const record = session.app.state.line_map.getLineRecord(session.app.state.global_cursor_line).?;
    try std.testing.expect(record.line_type == .comment_line);
}

test "[c jumps the cursor back to the previous comment" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try moveToCodeLine(&session);
    try press(&session, vaxis.Key.enter);
    try typeText(&session, "look here");
    try press(&session, vaxis.Key.enter);

    try press(&session, 'G');
    try press(&session, '[');
    try press(&session, 'c');

    const record = session.app.state.line_map.getLineRecord(session.app.state.global_cursor_line).?;
    try std.testing.expect(record.line_type == .comment_line);
}

test "f moves the cursor to the character it finds" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try moveToCodeLine(&session);
    try press(&session, 'f');
    try press(&session, '@');

    try std.testing.expect(session.app.state.cursor_column > 0);
}

test "an unfound character leaves the cursor column alone" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try moveToCodeLine(&session);
    try press(&session, 'f');
    try press(&session, '~');

    try std.testing.expectEqual(@as(usize, 0), session.app.state.cursor_column);
}

test "v starts visual mode and Esc leaves it" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try press(&session, 'v');
    try std.testing.expectEqual(App.Mode.visual, session.app.mode);

    try press(&session, 27);
    try std.testing.expectEqual(App.Mode.normal, session.app.mode);
}

test "j in visual mode extends the selection instead of leaving it" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try moveToCodeLine(&session);
    const anchor = session.app.state.global_cursor_line;
    try press(&session, 'v');
    try press(&session, 'j');

    try std.testing.expectEqual(App.Mode.visual, session.app.mode);
    try std.testing.expectEqual(anchor, session.app.state.visual_anchor.?);
    try std.testing.expectEqual(anchor + 1, session.app.state.global_cursor_line);
}

test "enter in visual mode opens a comment on the selection" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try moveToCodeLine(&session);
    try press(&session, 'v');
    try press(&session, 'j');
    try press(&session, vaxis.Key.enter);

    try std.testing.expectEqual(App.Mode.comment, session.app.mode);
}

test "j in help mode scrolls the overlay and leaves the cursor alone" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    const cursor = session.app.state.global_cursor_line;
    try press(&session, '?');
    try std.testing.expectEqual(App.Mode.help, session.app.mode);

    try press(&session, 'j');
    try std.testing.expectEqual(@as(usize, 1), session.app.state.help_scroll_offset);
    try std.testing.expectEqual(cursor, session.app.state.global_cursor_line);

    try press(&session, 'q');
    try std.testing.expectEqual(App.Mode.normal, session.app.mode);
}

test "ctrl-p opens the file picker with a file in it" {
    var session = try openTwoFileSession(std.testing.allocator);
    defer session.deinit();

    try session.handleKey(.{ .codepoint = 'p', .mods = .{ .ctrl = true } });
    try std.testing.expectEqual(App.Mode.command_palette, session.app.mode);

    const output = try renderPlain(&session);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "src/greet.zig") != null);
}

test "typing in the file picker narrows the list to one file" {
    var session = try openTwoFileSession(std.testing.allocator);
    defer session.deinit();

    try session.handleKey(.{ .codepoint = 'p', .mods = .{ .ctrl = true } });
    try typeText(&session, "farewell");

    const palette = &session.app.state.command_palette_state;
    try std.testing.expectEqual(@as(usize, 1), palette.filtered_commands.items.len);
    try std.testing.expectEqualStrings("src/farewell.zig", palette.getSelectedCommand().?.name);
}

test "enter in the file picker jumps to the file" {
    var session = try openTwoFileSession(std.testing.allocator);
    defer session.deinit();

    try std.testing.expectEqual(@as(usize, 0), session.app.state.current_file_idx);

    try session.handleKey(.{ .codepoint = 'p', .mods = .{ .ctrl = true } });
    try typeText(&session, "farewell");
    try press(&session, vaxis.Key.enter);

    try std.testing.expectEqual(App.Mode.normal, session.app.mode);
    try std.testing.expectEqual(@as(usize, 1), session.app.state.current_file_idx);
}

test "esc closes the file picker" {
    var session = try openTwoFileSession(std.testing.allocator);
    defer session.deinit();

    try session.handleKey(.{ .codepoint = 'p', .mods = .{ .ctrl = true } });
    try press(&session, 27);
    try std.testing.expectEqual(App.Mode.normal, session.app.mode);
}

test "colon opens the palette in command mode" {
    var session = try openTwoFileSession(std.testing.allocator);
    defer session.deinit();

    try press(&session, ':');
    try std.testing.expectEqual(App.Mode.command_palette, session.app.mode);

    const palette = &session.app.state.command_palette_state;
    try std.testing.expectEqualStrings(">", palette.query_buffer[0..palette.query_len]);
}

test "a command from the palette switches the view mode" {
    var session = try openTwoFileSession(std.testing.allocator);
    defer session.deinit();

    try press(&session, ':');
    try typeText(&session, "toggle view");
    try press(&session, vaxis.Key.enter);

    try std.testing.expectEqual(App.Mode.normal, session.app.mode);
    try std.testing.expect(session.app.state.view_mode == .side_by_side);
}

test "ctrl-n moves the palette selection down" {
    var session = try openTwoFileSession(std.testing.allocator);
    defer session.deinit();

    try session.handleKey(.{ .codepoint = 'p', .mods = .{ .ctrl = true } });
    try std.testing.expectEqualStrings("src/greet.zig", selectedCommandName(&session));

    try session.handleKey(.{ .codepoint = 'n', .mods = .{ .ctrl = true } });
    try std.testing.expectEqualStrings("src/farewell.zig", selectedCommandName(&session));
}

test "ctrl-j and ctrl-k move the palette selection too" {
    var session = try openTwoFileSession(std.testing.allocator);
    defer session.deinit();

    try session.handleKey(.{ .codepoint = 'p', .mods = .{ .ctrl = true } });
    try session.handleKey(.{ .codepoint = 'j', .mods = .{ .ctrl = true } });
    try std.testing.expectEqualStrings("src/farewell.zig", selectedCommandName(&session));

    try session.handleKey(.{ .codepoint = 'k', .mods = .{ .ctrl = true } });
    try std.testing.expectEqualStrings("src/greet.zig", selectedCommandName(&session));
}

test "a session that opened the palette leaves no memory behind" {
    var session = try openTwoFileSession(std.testing.allocator);
    try press(&session, ':');
    try typeText(&session, "help");
    session.deinit();
}

test "a session with a saved comment leaves no memory behind" {
    var session = try openTestSession(std.testing.allocator);
    try moveToCodeLine(&session);
    try press(&session, vaxis.Key.enter);
    try typeText(&session, "hold this");
    try press(&session, vaxis.Key.enter);
    session.deinit();
}

test "ctrl-c closes the help overlay" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try press(&session, '?');
    try std.testing.expectEqual(App.Mode.help, session.app.mode);

    try session.handleKey(.{ .codepoint = 'c', .mods = .{ .ctrl = true } });
    try std.testing.expectEqual(App.Mode.normal, session.app.mode);
}

test "ctrl-[ closes the help overlay" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try press(&session, '?');
    try session.handleKey(.{ .codepoint = '[', .mods = .{ .ctrl = true } });
    try std.testing.expectEqual(App.Mode.normal, session.app.mode);
}

test "ctrl-c closes the file picker" {
    var session = try openTwoFileSession(std.testing.allocator);
    defer session.deinit();

    try session.handleKey(.{ .codepoint = 'p', .mods = .{ .ctrl = true } });
    try std.testing.expectEqual(App.Mode.command_palette, session.app.mode);

    try session.handleKey(.{ .codepoint = 'c', .mods = .{ .ctrl = true } });
    try std.testing.expectEqual(App.Mode.normal, session.app.mode);
    try std.testing.expectEqual(@as(usize, 0), session.app.state.command_palette_state.query_len);
}

test "ctrl-c leaves visual mode" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try press(&session, 'v');
    try std.testing.expectEqual(App.Mode.visual, session.app.mode);

    try session.handleKey(.{ .codepoint = 'c', .mods = .{ .ctrl = true } });
    try std.testing.expectEqual(App.Mode.normal, session.app.mode);
}

test "ctrl-c closes the search input" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try press(&session, '/');
    try typeText(&session, "hello");

    try session.handleKey(.{ .codepoint = 'c', .mods = .{ .ctrl = true } });
    try std.testing.expectEqual(App.Mode.normal, session.app.mode);
}

test "ctrl-c cancels the comment editor without saving" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try moveToCodeLine(&session);
    try press(&session, vaxis.Key.enter);
    try typeText(&session, "throw this away");

    try session.handleKey(.{ .codepoint = 'c', .mods = .{ .ctrl = true } });
    try std.testing.expectEqual(App.Mode.normal, session.app.mode);
    try std.testing.expectEqual(@as(usize, 0), session.app.state.comment_store.comments.items.len);
}

test "ctrl-c in normal mode never ends the session" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try session.handleKey(.{ .codepoint = 'c', .mods = .{ .ctrl = true } });
    try std.testing.expectEqual(App.Mode.normal, session.app.mode);
    try std.testing.expect(!session.app.should_quit);
}

test "ctrl-[ cancels the comment editor without saving" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try moveToCodeLine(&session);
    try press(&session, vaxis.Key.enter);
    try typeText(&session, "throw this away");

    try session.handleKey(.{ .codepoint = '[', .mods = .{ .ctrl = true } });
    try std.testing.expectEqual(App.Mode.normal, session.app.mode);
    try std.testing.expectEqual(@as(usize, 0), session.app.state.comment_store.comments.items.len);
}

test "escape leaves the comment editor in vim normal mode, and closes it on the second press" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try moveToCodeLine(&session);
    try press(&session, vaxis.Key.enter);
    try typeText(&session, "keep typing");

    try press(&session, vaxis.Key.escape);
    try std.testing.expectEqual(App.Mode.comment, session.app.mode);

    try press(&session, vaxis.Key.escape);
    try std.testing.expectEqual(App.Mode.normal, session.app.mode);
    try std.testing.expectEqual(@as(usize, 0), session.app.state.comment_store.comments.items.len);
}
