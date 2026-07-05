const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const comment_editor = @import("../comments/editor.zig");
const review_controller = @import("../pr/review_controller.zig");

/// Handle keyboard input in the submit-review dialog (FR-6/FR-7). Tab cycles the
/// verdict, Ctrl-D runs the two-step discard confirm, and the embedded vim editor
/// owns the body: Enter / Ctrl-S submits, Shift-Enter / Ctrl-J inserts a newline,
/// Esc from vim-normal closes the dialog (preserving the body for reopen).
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    const review = &app.state.review;
    if (app.state.review_submit_editor == null) {
        app.mode = .normal;
        return;
    }
    const editor_state = &app.state.review_submit_editor.?;

    // Tab / Shift-Tab cycle the verdict (before the editor, so Tab never inserts).
    if (key.codepoint == vaxis.Key.tab and !key.mods.shift) {
        review_controller.cycleVerdict(review, true);
        review_controller.disarmDiscardConfirm(review);
        app.needs_render = true;
        return;
    }
    if (key.codepoint == vaxis.Key.tab and key.mods.shift) {
        review_controller.cycleVerdict(review, false);
        review_controller.disarmDiscardConfirm(review);
        app.needs_render = true;
        return;
    }

    // Ctrl-D: two-step discard confirmation (AD-8 draft safety for a destructive op).
    if (key.mods.ctrl and key.codepoint == 'd') {
        if (review_controller.discardArmed(review)) {
            app.discardReviewNow();
        } else {
            review_controller.armDiscardConfirm(review);
            app.showStatusMessage("press ^D again to discard the pending review");
            app.needs_render = true;
        }
        return;
    }

    // Any other key disarms a pending discard confirmation.
    if (review_controller.discardArmed(review)) review_controller.disarmDiscardConfirm(review);

    // Esc from vim-normal closes the dialog; Esc from insert falls through to the
    // editor (leaves insert mode), matching vim muscle memory.
    if (key.codepoint == vaxis.Key.escape and editor_state.vim_mode == .normal) {
        app.closeReviewSubmit();
        return;
    }

    const action = try comment_editor.CommentEditor.VimEditor.handleKey(editor_state, key, app.allocator);
    if (action) |act| {
        switch (act) {
            .save => app.submitReviewNow(),
            .cancel => app.closeReviewSubmit(),
        }
    } else {
        app.needs_render = true;
    }
}
