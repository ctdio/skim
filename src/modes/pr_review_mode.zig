//! Key handling for the native PR picker (`pr_review` mode). Search is always
//! live — printable keys narrow the list as you type, so ctrl chords drive
//! navigation to keep letters free. ctrl-a opens an author-filter overlay that
//! pins one author on top of the text search. Enter reviews the highlighted PR
//! natively by swapping the diff in-process (no child skim, no worktree).

const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const pr_controller = @import("../pr/controller.zig");

pub fn handleKey(app: *App, key: vaxis.Key) !void {
    if (app.state.pr.picking_author) {
        try handleAuthorKey(app, key);
        return;
    }
    try handleListKey(app, key);
}

// =============================================================================
// Helpers
// =============================================================================

fn handleListKey(app: *App, key: vaxis.Key) !void {
    const page: isize = @intCast(@max(viewportRows(app), 1));

    const pr = &app.state.pr;
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n', 'j' => pr_controller.move(pr, 1),
            'p', 'k' => pr_controller.move(pr, -1),
            'd' => pr_controller.move(pr, @divTrunc(page, 2)),
            'u' => pr_controller.move(pr, -@divTrunc(page, 2)),
            'r' => try pr_controller.startListLoad(pr, app.allocator),
            'o' => pr_controller.openInBrowser(pr),
            'a' => pr_controller.openAuthorPicker(pr, app.allocator),
            else => {},
        }
        return;
    }

    switch (key.codepoint) {
        vaxis.Key.escape => app.prClearOrLeave(),
        vaxis.Key.enter => try app.reviewSelectedPr(),
        vaxis.Key.down => pr_controller.move(pr, 1),
        vaxis.Key.up => pr_controller.move(pr, -1),
        vaxis.Key.page_down => pr_controller.move(pr, page),
        vaxis.Key.page_up => pr_controller.move(pr, -page),
        vaxis.Key.backspace => pr_controller.backspaceQuery(pr, app.allocator),
        0x20...0x7E => pr_controller.appendQueryChar(pr, app.allocator, @intCast(key.codepoint)),
        else => {},
    }
}

fn handleAuthorKey(app: *App, key: vaxis.Key) !void {
    const page: isize = @intCast(@max(viewportRows(app), 1));

    const pr = &app.state.pr;
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n', 'j' => pr_controller.authorMove(pr, 1),
            'p', 'k' => pr_controller.authorMove(pr, -1),
            else => {},
        }
        return;
    }

    switch (key.codepoint) {
        vaxis.Key.escape => pr_controller.closeAuthorPicker(pr, app.allocator),
        vaxis.Key.enter => pr_controller.applySelectedAuthor(pr, app.allocator),
        vaxis.Key.down => pr_controller.authorMove(pr, 1),
        vaxis.Key.up => pr_controller.authorMove(pr, -1),
        vaxis.Key.page_down => pr_controller.authorMove(pr, page),
        vaxis.Key.page_up => pr_controller.authorMove(pr, -page),
        vaxis.Key.backspace => pr_controller.backspaceAuthorQuery(pr, app.allocator),
        0x20...0x7E => pr_controller.appendAuthorQueryChar(pr, app.allocator, @intCast(key.codepoint)),
        else => {},
    }
}

fn viewportRows(app: *App) usize {
    if (app.vx == null) return 0;
    const win = app.vx.?.window();
    return if (win.height > 2) win.height - 2 else 0;
}
