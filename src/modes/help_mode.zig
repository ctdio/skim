const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;

/// Handle keyboard input when in help mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    _ = key;
    // Any key press exits help mode (ESC, ?, or any other key)
    app.mode = .normal;
    app.needs_render = true; // Force full redraw after closing popup
}
