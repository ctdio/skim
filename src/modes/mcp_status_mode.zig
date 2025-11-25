const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;

/// Handle keyboard input when in MCP status mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    switch (key.codepoint) {
        'q', vaxis.Key.escape => {
            // Exit MCP status mode
            app.mode = .normal;
            app.needs_render = true;
        },
        else => {},
    }
}
