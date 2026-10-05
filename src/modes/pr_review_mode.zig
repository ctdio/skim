//! Key handling for the PR sidebar (`pr_review` mode = the sidebar has focus,
//! AD-8), plus the few diff-focus keys that change meaning while the PR
//! surface is open (`handleDiffFocusKey`), so every PR-surface key lives here.
//! Navigation, filtering and presets are the sidebar controller's; this file
//! owns focus and hands entry/sync/close to App.

const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const Layout = @import("../rendering/common.zig").Layout;
const pr_surface = if (@import("../platform.zig").is_web) @import("../pr/surface_stub.zig") else @import("../pr/surface.zig");
const review_controller = @import("../pr/review_controller.zig");
const sidebar_controller = @import("../pr/sidebar/controller.zig");
const sidebar_render = @import("../pr/sidebar/render.zig");
const sidebar_layout = @import("../pr/sidebar/layout.zig");

const Key = vaxis.Key;

pub fn handleKey(app: *App, key: Key) !void {
    const sb = &app.state.sidebar;
    app.needs_render = true;
    if (sb.prompt != null) return handlePromptKey(app, key);

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
        'l', Key.tab => if (!key.mods.shift) focusDiff(app),
        Key.enter => try openSelected(app),
        'f' => sidebar_controller.openPrompt(sb),
        'F' => {
            try sidebar_controller.cyclePreset(sb, app.allocator);
            pr_surface.pushVisible(&app.state.pr_surface, .{ .allocator = app.allocator, .sidebar = sb });
        },
        'R' => pr_surface.requestSync(&app.state.pr_surface),
        'o' => pr_surface.openInBrowser(sb),
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
    return false;
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
        else => blk: {
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

/// Enter: start entry for the selected PR unless it is already on screen (or
/// on its way), then hand focus to the diff.
fn openSelected(app: *App) !void {
    const record = sidebar_controller.selectedPr(&app.state.sidebar) orelse return;
    if (shownOrEntering(&app.state.review, record.number)) {
        focusDiff(app);
        return;
    }
    try app.reviewSelectedPr();
}

fn shownOrEntering(review: *const review_controller.ReviewSession, number: u32) bool {
    if (review.next_entry) |next| return next.number == number;
    if (review_controller.entryPending(review)) return review.entering_number == number;
    return review_controller.isActive(review) and review.number == number;
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
    focusDiff(app);
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
