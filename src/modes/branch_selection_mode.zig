const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const git = @import("../git/diff.zig");
const DiffSource = git.DiffSource;

/// Handle keyboard input when in branch selection mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    if (app.state.branch_list.len == 0) {
        // No branches - go back to empty menu
        app.mode = .normal;
        return;
    }

    const filtered_count = app.state.filtered_branches.items.len;

    // Handle Ctrl+key combinations
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n' => {
                if (filtered_count > 0 and app.state.branch_selection < filtered_count - 1) {
                    app.state.branch_selection += 1;
                }
                return;
            },
            'p' => {
                if (app.state.branch_selection > 0) {
                    app.state.branch_selection -= 1;
                }
                return;
            },
            else => {},
        }
    }

    // Handle arrow keys
    if (key.codepoint == vaxis.Key.down) {
        if (filtered_count > 0 and app.state.branch_selection < filtered_count - 1) {
            app.state.branch_selection += 1;
        }
        return;
    }
    if (key.codepoint == vaxis.Key.up) {
        if (app.state.branch_selection > 0) {
            app.state.branch_selection -= 1;
        }
        return;
    }

    // Handle special keys
    switch (key.codepoint) {
        'j' => {
            if (filtered_count > 0 and app.state.branch_selection < filtered_count - 1) {
                app.state.branch_selection += 1;
            }
        },
        'k' => {
            if (app.state.branch_selection > 0) {
                app.state.branch_selection -= 1;
            }
        },
        27 => { // ESC key - clear search or go back
            if (app.state.branch_search_len > 0) {
                // Clear search
                app.state.branch_search_len = 0;
                app.state.branch_selection = 0;
                try app.filterBranches();
            } else {
                // Go back to empty menu
                app.mode = .normal;
            }
        },
        vaxis.Key.backspace => { // Backspace - delete last search char
            if (app.state.branch_search_len > 0) {
                app.state.branch_search_len -= 1;
                app.state.branch_selection = 0;
                try app.filterBranches();
            }
        },
        '\r' => { // Enter key - select branch and diff against it
            if (filtered_count == 0) return;

            const filtered_idx = app.state.filtered_branches.items[app.state.branch_selection];
            const selected_branch = app.state.branch_list[filtered_idx];
            const branch_copy = try app.allocator.dupe(u8, selected_branch);
            errdefer app.allocator.free(branch_copy);

            const head = try app.allocator.dupe(u8, "HEAD");
            errdefer app.allocator.free(head);

            // Free old diff_source if needed
            switch (app.state.diff_source) {
                .working_dir => {},
                .single_ref => |sr| {
                    app.allocator.free(sr.ref);
                },
                .two_refs => |tr| {
                    app.allocator.free(tr.ref1);
                    app.allocator.free(tr.ref2);
                },
            }

            // Set up new diff source
            app.state.diff_source = DiffSource{ .two_refs = .{
                .ref1 = branch_copy,
                .ref2 = head,
                .use_merge_base = true,
            } };

            // Go back to normal mode and refresh
            app.mode = .normal;
            try app.refresh();
        },
        else => {
            // Handle text input for search
            if (key.codepoint >= 32 and key.codepoint <= 126) { // Printable ASCII
                if (app.state.branch_search_len < app.state.branch_search_query.len - 1) {
                    app.state.branch_search_query[app.state.branch_search_len] = @intCast(key.codepoint);
                    app.state.branch_search_len += 1;
                    app.state.branch_selection = 0;
                    try app.filterBranches();
                }
            }
        },
    }
}
