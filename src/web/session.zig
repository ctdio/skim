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
const mouse = core.mouse;
const parser = core.parser;
const help = core.help;
const search_mode = core.search_mode;
const visual_mode = core.visual_mode;
const help_mode = core.help_mode;
const command_palette_mode = core.command_palette_mode;
const command_palette = core.command_palette;
const CommentController = core.CommentController;
const CommentEditor = core.CommentEditor;
const agent = core.agent;
const acp_session_replay = core.acp_session_replay;
const debug_replay_controller = core.debug_replay_controller;
const mcp_handlers = core.mcp_handlers;
const tui_server = core.tui_server;

pub const Params = struct {
    diff_text: []const u8,
    width: u16,
    height: u16,
};

/// Ceiling on one `Session.scroll` call. Every line is a keystroke, so a host
/// that hands over a runaway count would otherwise hold the tab.
const max_scroll_lines = 512;

/// A second screen, for a host that gives the agent panel a terminal of its own
/// beside the diff instead of the right 30% of one frame.
///
/// Absent until the host asks for a panel frame, and while it exists the diff
/// keeps its full width. A browser can put two boxes side by side, which a
/// terminal cannot, so this is the one place the web build lays skim out
/// differently from the TUI.
const AgentSurface = struct {
    ctx: harness.TestContext,
    ansi: []const u8,
};

/// One open diff. Holds the App, the screen it draws into, and the ANSI text of
/// the last frame. The caller owns nothing: `ansi` stays valid until the next
/// `render` or `deinit`.
pub const Session = struct {
    allocator: Allocator,
    app: App,
    ctx: harness.TestContext,
    ansi: []const u8,
    /// The JSON answer to the last MCP request. Owned by the session, replaced
    /// by the next request.
    json: []const u8,
    agent_surface: ?AgentSurface,

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
            .json = &.{},
            .agent_surface = null,
        };

        // Prime `viewport_height`/`viewport_width`, which the renderer sets and
        // every navigation key reads. Without this the first key moves against a
        // zero-height viewport.
        _ = try session.render();
        return session;
    }

    pub fn deinit(self: *Session) void {
        if (self.agent_surface) |*surface| {
            self.allocator.free(surface.ansi);
            surface.ctx.deinit();
        }
        self.allocator.free(self.json);
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

    /// Scroll the active surface by `lines`: negative up, positive down.
    ///
    /// This is the mouse wheel. The TUI serves it by repeating the keystroke the
    /// active mode already binds to "scroll one line", and `mouse.zig` owns that
    /// choice, so both builds move each surface the same way. A surface with no
    /// vertical scroll — the comment editor, the search box — is left alone.
    ///
    /// The host turns a wheel event into a line count, which is why the count is
    /// clamped: a page-mode wheel event is one screen, so anything past
    /// `max_scroll_lines` is arithmetic that went wrong on the way in.
    pub fn scroll(self: *Session, lines: i32) !void {
        const codepoint = mouse.wheelKeyForMode(self.app.mode, lines > 0) orelse return;

        var moved: u32 = 0;
        const count = @min(@abs(lines), max_scroll_lines);
        while (moved < count) : (moved += 1) {
            try self.handleKey(.{ .codepoint = codepoint });
        }
    }

    /// Draw the current state and return it as ANSI text for a terminal
    /// emulator. The returned slice is owned by the session.
    pub fn render(self: *Session) ![]const u8 {
        _ = self.ctx.arena.reset(.retain_capacity);

        try drawFrame(&self.app, self.ctx.window(), self.agent_surface == null);

        const next = try self.ctx.captureToAnsi();
        self.allocator.free(self.ansi);
        self.ansi = next;
        self.app.needs_render = false;
        return self.ansi;
    }

    /// Draw the agent panel alone, into a screen of its own, and return it as
    /// ANSI text for a second terminal emulator.
    ///
    /// This is for a page that shows skim beside the agent talking to it: two
    /// boxes, each the full height of the frame. The panel is skim's own —
    /// `agent/render.zig` draws it, exactly as it draws the panel a `Ctrl-e`
    /// opens — it is only the box around it that the page chose. Asking for
    /// this frame is also what tells `render` to keep the diff full width.
    ///
    /// The bottom row is skim's status bar, the same one `rendering/frame.zig`
    /// keeps under the panel. Without it the input bubble runs to the floor of
    /// the box and reads as a stray band of colour, and the vim mode the panel
    /// is in has nowhere to appear. The status bar reports the panel rather
    /// than the diff, so it is drawn in agent mode; the panel itself stays
    /// unfocused, because the keyboard belongs to the other box.
    ///
    /// The returned slice is owned by the session and lives until the next
    /// `renderAgent` or `deinit`.
    pub fn renderAgent(self: *Session, width: u16, height: u16) ![]const u8 {
        try self.ensureAgentSurface(width, height);
        const surface = &self.agent_surface.?;

        _ = surface.ctx.arena.reset(.retain_capacity);
        self.app.resetFrameAllocators();

        const win = surface.ctx.window();
        win.clear();
        win.hideCursor();
        if (win.width > 0 and win.height > 0) {
            const status_height: u16 = @intCast(Layout.status_height);
            const panel_height = win.height -| status_height;
            if (panel_height > 0) {
                try agent.renderAgentPanel(&self.app, win.child(.{
                    .x_off = 0,
                    .y_off = 0,
                    .width = win.width,
                    .height = panel_height,
                }));
            }

            const prior_mode = self.app.mode;
            self.app.mode = .agent;
            defer self.app.mode = prior_mode;
            try UI.renderStatus(&self.app, win.child(.{
                .x_off = 0,
                .y_off = win.height -| status_height,
                .width = win.width,
                .height = status_height,
            }));
        }

        const next = try surface.ctx.captureToAnsi();
        self.allocator.free(surface.ansi);
        surface.ansi = next;
        return surface.ansi;
    }

    /// The last agent-panel frame, or nothing when the host has never asked for
    /// one.
    pub fn agentAnsi(self: *const Session) []const u8 {
        const surface = self.agent_surface orelse return &.{};
        return surface.ansi;
    }

    /// Answer an MCP `add_comment` request against the open diff.
    ///
    /// `params_text` is the JSON object the tool sends: `file`, `line`,
    /// `line_type`, `text`. The request goes through `mcp/handlers.zig`, which
    /// is the function the stdio MCP server calls, so a comment the page shows
    /// arrived the way an agent's comment arrives. The returned JSON is owned
    /// by the session.
    pub fn addComment(self: *Session, params_text: []const u8) ![]const u8 {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, params_text, .{});
        defer parsed.deinit();
        return encodeResponse(self, mcp_handlers.handleAddComment(&self.app, parsed.value));
    }

    /// Answer an MCP `list_comments` request. Reports every comment on the open
    /// diff, whoever wrote it.
    pub fn listComments(self: *Session) ![]const u8 {
        return encodeResponse(self, mcp_handlers.handleListComments(&self.app));
    }

    /// Put `text` in the panel's input box, as if it had been typed there.
    ///
    /// This is for a host that types a prompt out one character at a time: it
    /// calls this with each prefix and draws the panel between them. Skim's own
    /// input box holds the text, so it wraps and scrolls the way it does under
    /// a real keyboard. An empty text clears the box, which is what sending the
    /// prompt does.
    ///
    /// The panel has to be open. Nothing types into a panel that is not there.
    pub fn agentInput(self: *Session, text: []const u8) !void {
        if (self.app.tab_manager == null) return error.NoAgentPanel;
        const tab = self.app.tab_manager.?.activeTab() orelse return error.NoAgentPanel;
        tab.agent_state.input.setText(text);
        // To the end, where a typist's cursor is. The box scrolls to the cursor,
        // so a prompt longer than the box shows its last line rather than its
        // first.
        tab.agent_state.input.vim.cursor_pos = tab.agent_state.input.getText().len;
    }

    /// Open the agent panel on a recorded ACP session.
    ///
    /// The browser has no subprocess, so the panel is driven entirely by the
    /// replay: `manager` stays null and `startDebugReplay` reports the status
    /// the UI shows. This is the same path `skim debug acp` uses, so the panel
    /// renders through `agent/render.zig` rather than a stand-in.
    pub fn startAgentReplay(self: *Session, session_text: []const u8) !void {
        const lines = try acp_session_replay.loadReplayLinesFromString(self.allocator, session_text);
        errdefer {
            for (lines) |line| self.allocator.free(line);
            self.allocator.free(lines);
        }

        const tm = try self.app.ensureTabManager();
        const tab = try tm.ensureTab();
        tab.agent_state.startDebugReplay(.acp, lines, .{ .acp = .session_active }, true, false);
        // The page carries a caption that says the session is recorded, so the
        // panel does not need a replay counter saying it again.
        tab.agent_state.hideDebugReplayProgress();
        tm.panel_visible = true;
        _ = try self.render();
    }

    /// Play the next entry of the replay. Returns true when one was played, so
    /// the host knows to read a new frame and to ask again.
    ///
    /// The host owns the pacing, unlike `skim debug acp`, which advances off the
    /// wall clock. The browser build runs against WASI stubs that answer
    /// `clock_time_get` with a constant, so every entry would read as not yet
    /// due and the replay would never move. The page has a real clock; this
    /// takes one step each time it is asked.
    pub fn stepAgent(self: *Session) bool {
        if (self.app.tab_manager == null) return false;
        const tab = self.app.tab_manager.?.activeTab() orelse return false;

        var needs_render = false;
        const stepped = debug_replay_controller.step(.{
            .allocator = self.allocator,
            .agent_state = &tab.agent_state,
            .manager = null,
            .needs_render = &needs_render,
        }) catch return false;
        if (!stepped) return false;

        // Lay the new entry out now, whatever the pacing.
        //
        // `ensureLineMap` rebuilds at most once every 32ms and otherwise keeps
        // the map it has. That is right inside a TUI event loop, which will
        // draw again a frame later. The browser has no loop behind it: the host
        // asks for one frame per entry, and a skipped rebuild is a turn that
        // never appears. Clearing the stamp makes the next draw rebuild.
        tab.agent_state.last_line_map_rebuild = 0;

        // Then follow the newest turn, the way a live session does. `step` puts
        // the panel in history mode, and it does that before the entry it just
        // played has any lines — so the cursor pins to the top and everything
        // after the first turn plays off screen. Draw once to lay the entry
        // out, then move the cursor to the end of what is now there.
        self.layOutPanel();
        tab.agent_state.historyJumpToBottom();

        // Then leave history mode. `step` enters it so the replay can drive the
        // view, but a live session never does: a reader is in history mode
        // because the reader scrolled. The panel marks the cursor line there,
        // and on a page nobody is scrolling that mark reads as a stray
        // highlight on the newest turn, under a status bar that says HISTORY.
        // Following the tail shows the same lines with neither.
        tab.agent_state.exitHistoryMode();
        tab.agent_state.follow_bottom = true;
        return true;
    }

    /// Draw whichever frame the panel lives in, so the entry that just played
    /// has lines before the cursor is moved onto them.
    fn layOutPanel(self: *Session) void {
        if (self.agent_surface) |surface| {
            _ = self.renderAgent(surface.ctx.screen.width, surface.ctx.screen.height) catch {};
        } else {
            _ = self.render() catch {};
        }
    }

    /// Make the panel screen, or remake it at a size the host has changed.
    fn ensureAgentSurface(self: *Session, width: u16, height: u16) !void {
        if (self.agent_surface) |surface| {
            if (surface.ctx.screen.width == width and surface.ctx.screen.height == height) return;
        }

        var ctx = try harness.createTestContext(self.allocator, width, height);
        errdefer ctx.deinit();

        if (self.agent_surface) |*surface| {
            surface.ctx.deinit();
            surface.ctx = ctx;
        } else {
            self.agent_surface = .{ .ctx = ctx, .ansi = &.{} };
        }
    }
};

// ===== Helpers =====

/// Encode one handler response as JSON and hand ownership of the text to the
/// session.
///
/// The handlers allocate their result with the app allocator and the TUI server
/// frees it after it writes the socket. There is no socket here, so this frees
/// it instead — the session tests run on the testing allocator, which fails on
/// a leak.
fn encodeResponse(session: *Session, response: tui_server.Response) ![]const u8 {
    defer freeResponse(session.allocator, response);

    const next = switch (response) {
        .result => |value| try std.fmt.allocPrint(session.allocator, "{f}", .{std.json.fmt(value, .{})}),
        .err => |failure| try std.fmt.allocPrint(
            session.allocator,
            "{{\"error\":{{\"code\":{d},\"message\":{f}}}}}",
            .{ failure.code, std.json.fmt(failure.message, .{}) },
        ),
    };

    session.allocator.free(session.json);
    session.json = next;
    return session.json;
}

fn freeResponse(allocator: Allocator, response: tui_server.Response) void {
    switch (response) {
        // `tui_server.errorResponse` carries a string literal.
        .err => {},
        .result => |value| freeJsonValue(allocator, value),
    }
}

/// Free a handler result. Keys are string literals and are left alone; every
/// string value the two handlers put in one is a fresh dupe.
fn freeJsonValue(allocator: Allocator, value: std.json.Value) void {
    switch (value) {
        .string => |text| allocator.free(text),
        .array => |array| {
            for (array.items) |item| freeJsonValue(allocator, item);
            var owned = array;
            owned.deinit();
        },
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| freeJsonValue(allocator, entry.value_ptr.*);
            var owned = object;
            owned.deinit();
        },
        else => {},
    }
}

/// Compose one frame: header, diff content, status bar, and the help overlay.
///
/// `rendering/frame.zig` cannot be reused. It dispatches over every mode skim
/// has, and the branch-selection and empty menus call git during the render
/// itself (`ui.zig` -> `git.getDiffStats`), which does not compile for wasm.
/// This draws the same windows for the diff view alone.
fn drawFrame(app: *App, win: vaxis.Window, embed_panel: bool) !void {
    win.clear();
    app.resetFrameAllocators();
    win.hideCursor();

    if (win.width == 0 or win.height == 0) return;

    // The agent panel takes the right 30%, the same split `rendering/frame.zig`
    // uses. Zero when the panel is closed, and zero for a host that draws the
    // panel into a terminal of its own — see `Session.renderAgent`.
    const panel_width: u16 = if (embed_panel and app.isAgentPanelVisible()) win.width * 3 / 10 else 0;
    const diff_width = win.width -| panel_width;

    if (panel_width > 0) {
        try agent.renderAgentPanel(app, win.child(.{
            .x_off = diff_width,
            .y_off = 0,
            .width = panel_width,
            .height = win.height,
        }));
    }

    if (diff_width == 0) return;
    const diff_win = win.child(.{
        .x_off = 0,
        .y_off = 0,
        .width = diff_width,
        .height = win.height,
    });

    app.state.viewport_width = diff_win.width;
    if (app.state.files.len == 0) return;

    const content_height = diff_win.height -| Layout.header_height -| Layout.status_height;

    try UI.renderHeader(app, diff_win.child(.{
        .x_off = 0,
        .y_off = 0,
        .width = diff_win.width,
        .height = Layout.header_height,
    }));

    const content_win = diff_win.child(.{
        .x_off = 0,
        .y_off = Layout.header_height,
        .width = diff_win.width,
        .height = content_height,
    });
    switch (app.state.view_mode) {
        .unified => try UnifiedRenderer.renderContent(app, content_win),
        .side_by_side => try SideBySideRenderer.renderContent(app, content_win),
    }

    try UI.renderStatus(app, diff_win.child(.{
        .x_off = 0,
        .y_off = diff_win.height -| Layout.status_height,
        .width = diff_win.width,
        .height = Layout.status_height,
    }));

    if (app.mode == .help) try help.renderHelpPopup(app, diff_win);
    if (app.mode == .command_palette) try command_palette.renderCommandPalette(app, diff_win);
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
    if (app.tab_manager) |*tm| tm.deinit();
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

test "a wheel notch down scrolls the diff by the lines it asks for" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    const before = session.app.state.global_cursor_line;
    try session.scroll(mouse.lines_per_notch);
    try std.testing.expectEqual(before + mouse.lines_per_notch, session.app.state.global_cursor_line);
}

test "a wheel notch back up returns the diff to where it started" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    const before = session.app.state.global_cursor_line;
    try session.scroll(mouse.lines_per_notch);
    try session.scroll(-mouse.lines_per_notch);
    try std.testing.expectEqual(before, session.app.state.global_cursor_line);
}

test "a scroll of no lines leaves the diff where it was" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    const before = session.app.state.global_cursor_line;
    try session.scroll(0);
    try std.testing.expectEqual(before, session.app.state.global_cursor_line);
}

test "a scroll past the end of the diff stops at the last line" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try session.scroll(std.math.maxInt(i32));
    const last = session.app.state.line_map.getTotalLines() - 1;
    try std.testing.expectEqual(last, session.app.state.global_cursor_line);
}

test "a scroll with the help overlay open moves the overlay, not the cursor" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    const cursor = session.app.state.global_cursor_line;
    try press(&session, '?');
    try session.scroll(1);

    try std.testing.expectEqual(@as(usize, 1), session.app.state.help_scroll_offset);
    try std.testing.expectEqual(cursor, session.app.state.global_cursor_line);
}

test "a scroll with the comment editor open is ignored" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try moveToCodeLine(&session);
    const cursor = session.app.state.global_cursor_line;
    try press(&session, vaxis.Key.enter);
    try std.testing.expectEqual(App.Mode.comment, session.app.mode);

    try session.scroll(mouse.lines_per_notch);
    try std.testing.expectEqual(cursor, session.app.state.global_cursor_line);
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

/// Two JSONL entries in the shape `skim debug acp` reads: one user turn, one
/// agent turn.
const agent_replay_session =
    \\{"type":"user","message":{"content":"why did this loop change?"}}
    \\{"type":"assistant","message":{"content":"The bound moved so the last element is included."}}
;

test "startAgentReplay opens the panel" {
    var session = try Session.init(std.testing.allocator, .{
        .diff_text = test_diff,
        .width = 160,
        .height = 24,
    });
    defer session.deinit();

    try std.testing.expect(!session.app.isAgentPanelVisible());
    try session.startAgentReplay(agent_replay_session);
    try std.testing.expect(session.app.isAgentPanelVisible());
}

test "every replayed turn reaches the frame when the host draws between steps" {
    var session = try Session.init(std.testing.allocator, .{
        .diff_text = test_diff,
        .width = 160,
        .height = 24,
    });
    defer session.deinit();

    try session.startAgentReplay(agent_replay_session);

    // The browser draws after every step, which is the case a single draw at
    // the end does not cover.
    var steps: usize = 0;
    while (steps < 16) : (steps += 1) {
        if (!session.stepAgent()) break;
        _ = try session.render();
    }

    const text = try renderPlain(&session);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "why did this loop change?") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "The bound moved") != null);
}

test "a replayed turn reaches the rendered frame" {
    var session = try Session.init(std.testing.allocator, .{
        .diff_text = test_diff,
        .width = 160,
        .height = 24,
    });
    defer session.deinit();

    try session.startAgentReplay(agent_replay_session);

    // Bounded so a stuck replay fails the test rather than hangs it.
    var steps: usize = 0;
    while (steps < 16) : (steps += 1) {
        if (!session.stepAgent()) break;
    }

    const text = try renderPlain(&session);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "why did this loop change?") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "The bound moved") != null);
    // The diff must still be there beside the panel.
    try std.testing.expect(std.mem.indexOf(u8, text, "greet") != null);
}

test "add_comment through the MCP handler puts the comment on the diff" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    const answer = try session.addComment(
        \\{"file":"src/greet.zig","line":3,"line_type":"new","text":"name is never checked"}
    );
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"success\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), session.app.state.comment_store.comments.items.len);

    const text = try renderPlain(&session);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "name is never checked") != null);
}

test "add_comment on a line the diff does not have reports an error" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    const answer = try session.addComment(
        \\{"file":"src/greet.zig","line":900,"line_type":"new","text":"nowhere"}
    );
    try std.testing.expect(std.mem.indexOf(u8, answer, "\"error\"") != null);
    try std.testing.expectEqual(@as(usize, 0), session.app.state.comment_store.comments.items.len);
}

test "list_comments reports the comment the visitor typed" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try moveToCodeLine(&session);
    try press(&session, vaxis.Key.enter);
    try typeText(&session, "why the extra print");
    try press(&session, vaxis.Key.enter);

    const answer = try session.listComments();
    try std.testing.expect(std.mem.indexOf(u8, answer, "why the extra print") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "src/greet.zig") != null);
}

test "list_comments on a diff with no comments reports an empty list" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    const answer = try session.listComments();
    try std.testing.expectEqualStrings("{\"comments\":[]}", answer);
}

test "a session that served MCP requests leaves no memory behind" {
    var session = try openTestSession(std.testing.allocator);
    _ = try session.addComment(
        \\{"file":"src/greet.zig","line":3,"line_type":"new","text":"hold this"}
    );
    _ = try session.listComments();
    session.deinit();
}

/// Render the panel surface, then read it back as plain text. Caller owns the
/// result.
fn renderAgentPlain(session: *Session, width: u16, height: u16) ![]const u8 {
    _ = try session.renderAgent(width, height);
    return session.agent_surface.?.ctx.captureToText();
}

test "the panel drawn into a screen of its own holds the replayed turns" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try session.startAgentReplay(agent_replay_session);
    _ = try session.renderAgent(56, 24);

    var steps: usize = 0;
    while (steps < 16) : (steps += 1) {
        if (!session.stepAgent()) break;
    }

    const panel = try renderAgentPlain(&session, 56, 24);
    defer std.testing.allocator.free(panel);
    try std.testing.expect(std.mem.indexOf(u8, panel, "why did this loop change?") != null);
    try std.testing.expect(std.mem.indexOf(u8, panel, "The bound moved") != null);
}

test "the diff keeps its full width while the panel has a screen of its own" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try session.startAgentReplay(agent_replay_session);
    _ = try session.renderAgent(56, 24);
    while (session.stepAgent()) {}

    const diff = try renderPlain(&session);
    defer std.testing.allocator.free(diff);

    // The panel belongs to the other screen, and the diff has the whole width.
    try std.testing.expect(std.mem.indexOf(u8, diff, "The bound moved") == null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "pub fn greet(name: []const u8) void {") != null);
    try std.testing.expectEqual(@as(usize, 80), session.app.state.viewport_width);
}

test "a panel screen follows the size the host asks for" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try session.startAgentReplay(agent_replay_session);
    _ = try session.renderAgent(56, 24);
    try std.testing.expectEqual(@as(u16, 56), session.agent_surface.?.ctx.screen.width);

    _ = try session.renderAgent(40, 30);
    try std.testing.expectEqual(@as(u16, 40), session.agent_surface.?.ctx.screen.width);
    try std.testing.expectEqual(@as(u16, 30), session.agent_surface.?.ctx.screen.height);
}

test "a session with a panel screen leaves no memory behind" {
    var session = try openTestSession(std.testing.allocator);
    try session.startAgentReplay(agent_replay_session);
    _ = try session.renderAgent(56, 24);
    while (session.stepAgent()) {}
    session.deinit();
}

test "the panel does not advertise that it is a replay" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try session.startAgentReplay(agent_replay_session);
    while (session.stepAgent()) {}

    const panel = try renderAgentPlain(&session, 56, 24);
    defer std.testing.allocator.free(panel);
    try std.testing.expect(std.mem.indexOf(u8, panel, "Replay") == null);
}

test "the panel reports the session state the replay stands in for" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try session.startAgentReplay(agent_replay_session);
    const panel = try renderAgentPlain(&session, 56, 24);
    defer std.testing.allocator.free(panel);

    // Not "Not connected": there is no process, but there is a session.
    try std.testing.expect(std.mem.indexOf(u8, panel, "Active") != null);
    try std.testing.expect(std.mem.indexOf(u8, panel, "Not connected") == null);
}

test "the panel screen carries skim's status bar under it" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try session.startAgentReplay(agent_replay_session);

    const panel = try renderAgentPlain(&session, 56, 24);
    defer std.testing.allocator.free(panel);

    // The status bar reports the panel, not the diff, so it names the vim mode
    // the input is in rather than the diff's own normal mode line.
    try std.testing.expect(std.mem.indexOf(u8, panel, "-- INSERT --") != null);
    try std.testing.expect(std.mem.indexOf(u8, panel, "Enter:send") != null);
}

test "drawing the panel screen leaves the session in the mode it was in" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try session.startAgentReplay(agent_replay_session);
    _ = try session.renderAgent(56, 24);

    try std.testing.expectEqual(@as(App.Mode, .normal), session.app.mode);
}

/// A turn whose text carries an inline code span, for the wrap test below.
const agent_inline_code_session =
    \\{"type":"assistant","message":{"content":"one two three four five six `appendable` seven"}}
;

test "a wrap keeps an inline code span whole" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try session.startAgentReplay(agent_inline_code_session);
    while (session.stepAgent()) {}

    const panel = try renderAgentPlain(&session, 30, 24);
    defer std.testing.allocator.free(panel);

    // A span is a segment of its own, so a wrap that measures each segment
    // against what is left of the line splits the word: "appe" then "ndable".
    try std.testing.expect(std.mem.indexOf(u8, panel, "appendable") != null);
}

test "a played replay leaves the panel out of history mode" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try session.startAgentReplay(agent_replay_session);
    while (session.stepAgent()) {}

    const panel = try renderAgentPlain(&session, 56, 24);
    defer std.testing.allocator.free(panel);

    // History mode marks the cursor line and names itself in the status bar.
    // Nobody scrolled this panel, so neither belongs on it.
    try std.testing.expect(std.mem.indexOf(u8, panel, "-- HISTORY --") == null);
    try std.testing.expect(std.mem.indexOf(u8, panel, "-- INSERT --") != null);
}

test "text typed into the panel shows up in its input box" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try session.startAgentReplay(agent_replay_session);
    try session.agentInput("pull the comment on line 21");

    const panel = try renderAgentPlain(&session, 56, 24);
    defer std.testing.allocator.free(panel);
    try std.testing.expect(std.mem.indexOf(u8, panel, "pull the comment") != null);
}

test "an empty text clears the panel input box" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try session.startAgentReplay(agent_replay_session);
    try session.agentInput("pull the comment on line 21");
    try session.agentInput("");

    const panel = try renderAgentPlain(&session, 56, 24);
    defer std.testing.allocator.free(panel);
    try std.testing.expect(std.mem.indexOf(u8, panel, "pull the comment") == null);
}

test "typing into a panel that is not open reports an error" {
    var session = try openTestSession(std.testing.allocator);
    defer session.deinit();

    try std.testing.expectError(error.NoAgentPanel, session.agentInput("hello"));
}
