const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;

const page_step: usize = 10;

/// Handle keyboard input in the read-only PR info panel (FR-7). j/k scroll the
/// description a line at a time, Ctrl-d/Ctrl-u a page; i / Esc / q close it; r
/// re-fetches review data (retry after a failed fetch — see the data-unavailable
/// note in `review_render`).
///
/// Scroll targets are intentionally loose: they only move in the right direction.
/// The render pass clamps `info_scroll` to the true wrapped bottom every frame
/// (`review_controller.clampInfoScroll`), which is the only place that knows the
/// popup's description-column width — so `G` and page-down can overshoot here and
/// still land exactly, without the handler needing the popup geometry.
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    const review = &app.state.review;

    if (key.codepoint == vaxis.Key.escape or key.codepoint == 'q' or key.codepoint == 'i') {
        app.mode = .normal;
        app.needs_render = true;
        return;
    }

    if (key.codepoint == 'r') {
        app.startReviewRefetch();
        app.needs_render = true;
        return;
    }

    if (key.mods.ctrl and key.codepoint == 'd') {
        review.info_scroll +|= page_step;
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
            review.info_scroll +|= 1;
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
            review.info_scroll = std.math.maxInt(usize);
            app.needs_render = true;
        },
        else => {},
    }
}
