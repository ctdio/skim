const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const review_controller = @import("../pr/review_controller.zig");

const page_step: usize = 10;

/// Handle keyboard input in the read-only PR info panel (FR-7). j/k scroll the
/// description a line at a time, Ctrl-d/Ctrl-u a page; i / Esc / q close it.
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    const review = &app.state.review;

    if (key.codepoint == vaxis.Key.escape or key.codepoint == 'q' or key.codepoint == 'i') {
        app.mode = .normal;
        app.needs_render = true;
        return;
    }

    // Clamp against the whole scrollable region (Checks + Reviews + Description),
    // not just the description — otherwise the tail of a CI-heavy PR is unreachable
    // and G lands short of the true bottom (FR-7).
    const max_scroll = review_controller.infoLineCount(review) -| 1;

    if (key.mods.ctrl and key.codepoint == 'd') {
        review.info_scroll = @min(review.info_scroll + page_step, max_scroll);
        app.needs_render = true;
        return;
    }
    if (key.mods.ctrl and key.codepoint == 'u') {
        review.info_scroll -|= page_step;
        app.needs_render = true;
        return;
    }

    switch (key.codepoint) {
        'j' => {
            review.info_scroll = @min(review.info_scroll + 1, max_scroll);
            app.needs_render = true;
        },
        'k' => {
            review.info_scroll -|= 1;
            app.needs_render = true;
        },
        'g' => {
            review.info_scroll = 0;
            app.needs_render = true;
        },
        'G' => {
            review.info_scroll = max_scroll;
            app.needs_render = true;
        },
        else => {},
    }
}
