//! Key handling for the native PR picker (`pr_review` mode). Search is always
//! live — printable keys narrow the list as you type, so ctrl chords drive
//! navigation to keep letters free. ctrl-a opens an author-filter overlay that
//! pins one author on top of the text search. Enter reviews the highlighted PR
//! natively by swapping the diff in-process (no child skim, no worktree).

const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;

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

    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n', 'j' => app.prMove(1),
            'p', 'k' => app.prMove(-1),
            'd' => app.prMove(@divTrunc(page, 2)),
            'u' => app.prMove(-@divTrunc(page, 2)),
            'r' => try app.startPrListLoad(),
            'o' => app.openPrInBrowser(),
            'a' => app.openPrAuthorPicker(),
            else => {},
        }
        return;
    }

    switch (key.codepoint) {
        vaxis.Key.escape => app.prClearOrLeave(),
        vaxis.Key.enter => try app.reviewSelectedPr(),
        vaxis.Key.down => app.prMove(1),
        vaxis.Key.up => app.prMove(-1),
        vaxis.Key.page_down => app.prMove(page),
        vaxis.Key.page_up => app.prMove(-page),
        vaxis.Key.backspace => app.prBackspaceQuery(),
        0x20...0x7E => app.prAppendQueryChar(@intCast(key.codepoint)),
        else => {},
    }
}

fn handleAuthorKey(app: *App, key: vaxis.Key) !void {
    const page: isize = @intCast(@max(viewportRows(app), 1));

    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n', 'j' => app.prAuthorMove(1),
            'p', 'k' => app.prAuthorMove(-1),
            else => {},
        }
        return;
    }

    switch (key.codepoint) {
        vaxis.Key.escape => app.closePrAuthorPicker(),
        vaxis.Key.enter => app.applySelectedPrAuthor(),
        vaxis.Key.down => app.prAuthorMove(1),
        vaxis.Key.up => app.prAuthorMove(-1),
        vaxis.Key.page_down => app.prAuthorMove(page),
        vaxis.Key.page_up => app.prAuthorMove(-page),
        vaxis.Key.backspace => app.prBackspaceAuthorQuery(),
        0x20...0x7E => app.prAppendAuthorQueryChar(@intCast(key.codepoint)),
        else => {},
    }
}

fn viewportRows(app: *App) usize {
    if (app.vx == null) return 0;
    const win = app.vx.?.window();
    return if (win.height > 2) win.height - 2 else 0;
}
