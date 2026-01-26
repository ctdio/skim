const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const comment_editor = @import("../comments/editor.zig");
const navigation = @import("../navigation.zig");
const Navigation = navigation.Navigation;

/// Handle keyboard input when in comment mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    const input = &app.state.active_comment_input.?;

    // Ctrl+E - toggle agent panel (handle before vim editor)
    if (key.mods.ctrl and key.codepoint == 'e') {
        try app.toggleAgentPanel();
        return;
    }

    // Delegate to comment editor module
    const action = try comment_editor.CommentEditor.handleKey(input, key, app.allocator);

    // Handle save/cancel actions
    if (action) |act| {
        switch (act) {
            .save => {
                try app.saveCurrentComment();
                app.mode = .normal;
                app.state.active_comment_input = null;
                app.needs_render = true; // Force full redraw after saving comment
            },
            .cancel => {
                app.mode = .normal;
                app.state.active_comment_input = null;
                app.needs_render = true; // Force full redraw after canceling comment
            },
        }
    } else {
        // Still editing - adjust scroll to keep expanding comment visible
        // This handles multiline text and prevents the comment from scrolling off screen
        Navigation.ensureCommentBoxVisible(app);
    }
}
