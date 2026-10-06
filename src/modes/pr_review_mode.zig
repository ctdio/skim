//! Key handling for the PR sidebar (`pr_review` mode = the sidebar has focus,
//! AD-8), plus the few diff-focus keys that change meaning while the PR
//! surface is open (`handleDiffFocusKey`), so every PR-surface key lives here.
//! Navigation, filtering and presets are the sidebar controller's; this file
//! owns focus, the PR view toggles (`S`, `c`, `m`) and hands previews,
//! sync and close to App.

const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const clipboard = @import("../clipboard.zig");
const flip = @import("../pr/flip.zig");
const flip_controller = @import("../pr/flip_controller.zig");
const Layout = @import("../rendering/common.zig").Layout;
const pr_surface = if (@import("../platform.zig").is_web) @import("../pr/surface_stub.zig") else @import("../pr/surface.zig");
const sidebar_controller = @import("../pr/sidebar/controller.zig");
const sidebar_render = @import("../pr/sidebar/render.zig");
const sidebar_layout = @import("../pr/sidebar/layout.zig");

const Key = vaxis.Key;

pub fn handleKey(app: *App, key: Key) !void {
    const sb = &app.state.sidebar;
    app.needs_render = true;
    if (sb.prompt != null) return handlePromptKey(app, key);
    if (sb.menu != null) return handleMenuKey(app, key);

    if (app.state.pending_ctrl_w) {
        app.state.pending_ctrl_w = false;
        switch (chordKey(key)) {
            'l', 'w' => focusRightOfSidebar(app),
            else => {},
        }
        return;
    }
    if (sb.pending_g) {
        sb.pending_g = false;
        if (key.codepoint == 'g' and !key.mods.ctrl) {
            sidebar_controller.moveToEdge(sb, .top);
            return;
        }
    }
    if (sb.pending_z) {
        sb.pending_z = false;
        if (key.codepoint == 'a' and !key.mods.ctrl) {
            try sidebar_controller.toggleExpand(sb, app.allocator);
            return;
        }
    }

    const half_page: isize = @intCast(@max(listRows(app) / 2, 1));
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n' => sidebar_controller.moveStack(sb, 1),
            'p' => sidebar_controller.moveStack(sb, -1),
            'd' => sidebar_controller.move(sb, half_page),
            'u' => sidebar_controller.move(sb, -half_page),
            'b' => toggleSidebar(app),
            'w' => app.state.pending_ctrl_w = true,
            else => {},
        }
        return;
    }

    switch (key.codepoint) {
        'j', Key.down => sidebar_controller.move(sb, 1),
        'k', Key.up => sidebar_controller.move(sb, -1),
        'J' => try sidebar_controller.moveWithinStack(sb, app.allocator, 1),
        'K' => try sidebar_controller.moveWithinStack(sb, app.allocator, -1),
        Key.page_down => sidebar_controller.move(sb, half_page * 2),
        Key.page_up => sidebar_controller.move(sb, -half_page * 2),
        'g' => sb.pending_g = true,
        'G' => sidebar_controller.moveToEdge(sb, .bottom),
        'z' => sb.pending_z = true,
        ' ' => try sidebar_controller.toggleExpand(sb, app.allocator),
        'h' => try sidebar_controller.collapse(sb, app.allocator),
        'l', Key.tab => if (!key.mods.shift) enterPreviewed(app),
        Key.enter => openSelected(app),
        'S' => toggleWholeStack(app),
        'c' => try toggleSinceSeen(app),
        'm' => if (sidebar_controller.selectedPr(sb)) |record| toggleSeen(app, record.number),
        'f' => sidebar_controller.openMenu(sb),
        '/' => sidebar_controller.openPrompt(sb),
        'F' => {
            try sidebar_controller.cyclePreset(sb, app.allocator);
            pr_surface.pushVisible(&app.state.pr_surface, .{ .allocator = app.allocator, .sidebar = sb });
        },
        'R' => pr_surface.requestSync(&app.state.pr_surface),
        'o' => pr_surface.openInBrowser(&app.state.pr_surface, sb),
        'y' => yank(app, .branch),
        'Y' => yank(app, .url),
        Key.escape => try app.prSidebarBack(),
        else => {},
    }
}

/// Keys that mean something different while the PR surface is open and the
/// diff has focus. Returns true when consumed. Called first by normal_mode.
pub fn handleDiffFocusKey(app: *App, key: Key) !bool {
    const sb = &app.state.sidebar;
    if (!sb.open) return false;
    if (key.mods.ctrl and key.codepoint == 'b') {
        // Too narrow for both panes, the diff hides the sidebar: showing it
        // means giving it the screen.
        if (!fitsBesideDiff(app)) {
            showAndFocusSidebar(app);
            return true;
        }
        toggleSidebar(app);
        return true;
    }
    if (key.codepoint == Key.tab and !key.mods.shift and !key.mods.ctrl) {
        showAndFocusSidebar(app);
        return true;
    }
    if (key.mods.ctrl or key.mods.alt or normalPrefixPending(app)) return false;
    switch (key.codepoint) {
        'S' => toggleWholeStack(app),
        'c' => try toggleSinceSeen(app),
        'm' => if (app.state.flip.previewed) |number| toggleSeen(app, number),
        else => return false,
    }
    app.needs_render = true;
    return true;
}

/// FR-8 on rewritten history: fold every file that did not change since
/// seen, or unfold exactly those again.
pub fn toggleChangedOnly(app: *App) !void {
    switch (try flip_controller.toggleChangedOnly(app.flipCtx())) {
        .no_seen_diff => return app.showStatusError("no seen diff to compare"),
        .folded, .unfolded => {},
    }
    app.rebuildReviewLineMap();
    app.needs_render = true;
}

/// `Ctrl-w h` from the diff or a right-hand agent: the sidebar, when shown.
pub fn sidebarFocusable(app: *const App) bool {
    return app.state.sidebar.open and app.state.sidebar.visible;
}

// =============================================================================
// Helpers
// =============================================================================

fn handlePromptKey(app: *App, key: Key) !void {
    const sb = &app.state.sidebar;
    const prompt_key: sidebar_controller.PromptKey = switch (key.codepoint) {
        Key.enter => .enter,
        Key.escape => .escape,
        Key.backspace => .backspace,
        Key.right, Key.end => .keep,
        // Raw control characters: Ctrl-U and Ctrl-W on terminals that send them.
        21 => .clear,
        23 => .delete_word,
        else => blk: {
            if (key.mods.ctrl and key.codepoint == 'u') break :blk .clear;
            if (key.mods.ctrl and key.codepoint == 'w') break :blk .delete_word;
            if (key.mods.ctrl or key.mods.alt) return;
            // Named keys (arrows, F-keys) carry no text; plain ASCII may come
            // without it from synthetic input.
            const printable = key.text != null or (key.codepoint >= 0x20 and key.codepoint < 0x7F);
            if (!printable or key.codepoint < 0x20) return;
            break :blk .{ .char = key.codepoint };
        },
    };
    if (try sidebar_controller.promptKey(sb, app.allocator, prompt_key) == .query_changed) {
        pr_surface.pushVisible(&app.state.pr_surface, .{ .allocator = app.allocator, .sidebar = sb });
    }
}

/// `f` menu: j/k, arrows and g/G move, Space/Enter activate, `/` jumps to
/// the query prompt, Esc, `f` or `q` close. Other keys are swallowed so a
/// stray one cannot act on the list behind the menu.
fn handleMenuKey(app: *App, key: Key) !void {
    if (key.mods.ctrl or key.mods.alt) return;
    const menu_key: sidebar_controller.MenuKey = switch (key.codepoint) {
        'j', Key.down => .down,
        'k', Key.up => .up,
        'g' => .top,
        'G' => .bottom,
        ' ', Key.enter => .activate,
        '/' => .custom,
        'f', 'q', Key.escape => .close,
        else => return,
    };
    const sb = &app.state.sidebar;
    switch (try sidebar_controller.menuKey(sb, app.allocator, menu_key)) {
        .none => {},
        .query_changed => pr_surface.pushVisible(&app.state.pr_surface, .{ .allocator = app.allocator, .sidebar = sb }),
        .too_long => app.showStatusError("filter too long for another term"),
    }
}

/// Enter: open the selected PR in the diff. Already previewed: focus it and
/// mark it seen. On its way: focus it when it lands. Else preview it now
/// (no debounce) with the diff taking focus.
fn openSelected(app: *App) void {
    const record = sidebar_controller.selectedPr(&app.state.sidebar) orelse return;
    const state = &app.state.flip;
    if (state.loading_number == record.number) {
        state.focus_diff = true;
        return;
    }
    if (state.previewed == record.number) {
        enterPreviewed(app);
        return;
    }
    state.pending = null;
    state.view = .pr;
    state.focus_diff = true;
    app.previewPr(record.number);
}

/// `l`/Tab: focus the diff; when it shows the selected PR, that is reading
/// it, so it is marked seen.
fn enterPreviewed(app: *App) void {
    focusDiff(app);
    const record = sidebar_controller.selectedPr(&app.state.sidebar) orelse return;
    const state = &app.state.flip;
    if (app.mode != .normal or state.previewed != record.number or state.loading_number != null) return;
    flip_controller.markSeen(app.flipCtx(), record.number);
}

/// `S` (FR-7): the whole stack's diff for the shown PR, or back to its own.
fn toggleWholeStack(app: *App) void {
    const number = app.state.flip.previewed orelse return app.showStatusMessage("no PR shown");
    if (app.state.flip.previewed_view == .whole_stack) return switchView(app, .{ .number = number, .view = .pr });
    const sb = &app.state.sidebar;
    const index = sidebar_controller.recordIndex(sb, number) orelse return;
    if (sidebar_controller.stackPlace(sb, index).tip == null) return app.showStatusMessage("not a stacked PR");
    switchView(app, .{ .number = number, .view = .whole_stack });
}

/// `c` (FR-8): back to the PR's own diff from the since-seen view; else the
/// seen..head diff when the PR fast-forwarded, or the changed-files-only
/// folds when its history was rewritten.
fn toggleSinceSeen(app: *App) !void {
    const number = app.state.flip.previewed orelse return app.showStatusMessage("no PR shown");
    if (app.state.flip.previewed_view == .since_seen) return switchView(app, .{ .number = number, .view = .pr });
    switch (pr_surface.seenComparison(&app.state.pr_surface, .{ .sidebar = &app.state.sidebar, .number = number })) {
        .unchanged => app.showStatusMessage("no changes since seen"),
        .pending => app.showStatusMessage("still comparing with the seen version"),
        .fast_forward => switchView(app, .{ .number = number, .view = .since_seen }),
        .rewritten => try toggleChangedOnly(app),
    }
}

/// Re-preview PR `number` in `view` right away, keeping focus where it is.
fn switchView(app: *App, params: struct { number: u32, view: flip.DiffView }) void {
    app.state.flip.view = params.view;
    app.state.flip.focus_diff = app.mode != .pr_review;
    app.previewPr(params.number);
}

/// A normal-mode chord is waiting for its second key, which `S`/`c`/`m`
/// must reach (`zc` folds, `]c` …).
fn normalPrefixPending(app: *const App) bool {
    const state = &app.state;
    return state.pending_z or state.pending_g or state.pending_bracket or state.pending_close_bracket or state.pending_find != null or state.pending_ctrl_w;
}

/// Focus the diff. A no-op with nothing loaded: normal mode would drive the
/// hidden empty menu.
fn focusDiff(app: *App) void {
    if (app.state.files.len == 0) return;
    app.mode = .normal;
}

/// `Ctrl-w l`/`Ctrl-w w`: the pane right of the sidebar — a left-side agent
/// panel, else the diff.
fn focusRightOfSidebar(app: *App) void {
    if (app.isAgentPanelVisible() and app.getAgentPanelSide() == .left) {
        app.mode = .agent;
        return;
    }
    enterPreviewed(app);
}

/// `m`: toggle PR `number`'s seen state and say which way it went.
fn toggleSeen(app: *App, number: u32) void {
    var buf: [48]u8 = undefined;
    const message = switch (flip_controller.toggleSeen(app.flipCtx(), number)) {
        .marked => std.fmt.bufPrint(&buf, "marked #{d} seen", .{number}),
        .cleared => std.fmt.bufPrint(&buf, "cleared seen for #{d}", .{number}),
        .unchanged => return app.showStatusError("seen state not saved"),
    } catch unreachable;
    app.showStatusMessage(message);
}

/// `y` / `Y`: copy the selected PR's head branch or URL and say what was copied.
fn yank(app: *App, field: sidebar_controller.YankField) void {
    const text = sidebar_controller.yankText(&app.state.sidebar, field) orelse return app.showStatusError(switch (field) {
        .branch => "no branch to yank",
        .url => "no PR URL to yank",
    });
    clipboard.copyToClipboard(app.allocator, text) catch return app.showStatusError("clipboard copy failed");
    const message = switch (field) {
        .branch => std.fmt.allocPrint(app.allocator, "yanked branch {s}", .{text}),
        .url => std.fmt.allocPrint(app.allocator, "yanked {s}", .{text}),
    } catch return app.showStatusMessage("yanked");
    defer app.allocator.free(message);
    app.showStatusMessage(message);
}

fn showAndFocusSidebar(app: *App) void {
    app.state.sidebar.visible = true;
    app.mode = .pr_review;
    app.needs_render = true;
}

/// Whether the terminal fits the sidebar beside the diff. Headless (no
/// screen yet) counts as wide.
fn fitsBesideDiff(app: *const App) bool {
    const vx = app.vx orelse return true;
    const width = vx.screen.width;
    return sidebar_layout.split(.{ .width = width, .visible = true, .sidebar_focused = false }).sidebar_cols > 0;
}

/// `Ctrl-b`: hide the sidebar (focus moves to the diff) or show it again.
/// Hiding needs a loaded diff, or there would be nothing left on screen.
fn toggleSidebar(app: *App) void {
    const sb = &app.state.sidebar;
    app.needs_render = true;
    if (!sb.visible) {
        sb.visible = true;
        return;
    }
    if (app.state.files.len == 0) return;
    sb.visible = false;
    if (app.mode == .pr_review) app.mode = .normal;
}

/// Second key of a `Ctrl-w` chord. `Ctrl-<letter>` arrives as the letter
/// with the ctrl mod, or as the raw control character on some terminals.
fn chordKey(key: Key) u21 {
    if (key.codepoint == 12) return 'l';
    if (key.codepoint == 23) return 'w';
    return key.codepoint;
}

/// List rows in the sidebar column (terminal height minus the status bar),
/// for half-page motions.
fn listRows(app: *App) usize {
    if (app.vx == null) return 0;
    const height = app.vx.?.window().height -| Layout.status_height;
    return sidebar_render.listRows(height, app.state.sidebar.parse_error != null);
}
