const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;

/// Handle keyboard input when in graphite stack selection mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    const stack = app.state.graphite_stack orelse {
        // No stack - go back to normal mode
        app.mode = .normal;
        return;
    };

    const branch_count = stack.branches.len;
    if (branch_count == 0) {
        app.mode = .normal;
        return;
    }

    // Handle Ctrl+key combinations
    // Note: With tip at top, down moves toward parent (lower index), up moves toward child (higher index)
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n' => {
                // Next (down) - move toward parent
                app.state.graphite_stack_selection = if (app.state.graphite_stack_selection == 0) branch_count - 1 else app.state.graphite_stack_selection - 1;
                return;
            },
            'p' => {
                // Previous (up) - move toward child/tip
                app.state.graphite_stack_selection = (app.state.graphite_stack_selection + 1) % branch_count;
                return;
            },
            else => {},
        }
    }

    // Handle arrow keys
    // Down moves toward parent (trunk), up moves toward child (tip)
    if (key.codepoint == vaxis.Key.down) {
        app.state.graphite_stack_selection = if (app.state.graphite_stack_selection == 0) branch_count - 1 else app.state.graphite_stack_selection - 1;
        return;
    }
    if (key.codepoint == vaxis.Key.up) {
        app.state.graphite_stack_selection = (app.state.graphite_stack_selection + 1) % branch_count;
        return;
    }

    // Handle special keys
    switch (key.codepoint) {
        'j' => {
            // j (down) - move toward parent/trunk
            app.state.graphite_stack_selection = if (app.state.graphite_stack_selection == 0) branch_count - 1 else app.state.graphite_stack_selection - 1;
        },
        'k' => {
            // k (up) - move toward child/tip
            app.state.graphite_stack_selection = (app.state.graphite_stack_selection + 1) % branch_count;
        },
        27 => { // ESC key
            app.mode = .normal;
        },
        '\r' => { // Enter key - select branch and view its diff
            try app.selectGraphiteStackBranch(app.state.graphite_stack_selection);
        },
        'q' => { // q to quit stack picker
            app.mode = .normal;
        },
        else => {},
    }
}
