const std = @import("std");
const vaxis = @import("vaxis");
const Allocator = std.mem.Allocator;
const App = @import("../app.zig").App;
const git = @import("../git/diff.zig");
const containsIgnoreCase = @import("../pr/filter.zig").containsIgnoreCase;
const DiffSource = git.DiffSource;

/// Branch selection sub-state: the loaded branch list, the search/filter query,
/// and the filtered index view. All fields default so it stays out of the State
/// init literal.
pub const BranchSelectState = struct {
    list: [][]const u8 = &[_][]const u8{}, // List of available branches for selection
    selection: usize = 0, // Selected branch index in branch selection menu
    search_query: [256]u8 = undefined, // Search query buffer for filtering branches
    search_len: usize = 0, // Length of search query
    filtered: std.ArrayList(usize) = .empty, // Indices of branches matching search query

    pub fn deinit(self: *BranchSelectState, allocator: Allocator) void {
        for (self.list) |branch| {
            allocator.free(branch);
        }
        allocator.free(self.list);
        self.filtered.deinit(allocator);
    }
};

/// Handle keyboard input when in branch selection mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    if (app.state.branch_select.list.len == 0) {
        // No branches - go back to empty menu
        app.mode = .normal;
        return;
    }

    const filtered_count = app.state.branch_select.filtered.items.len;

    // Handle Ctrl+key combinations
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n' => {
                if (filtered_count > 0) {
                    app.state.branch_select.selection = (app.state.branch_select.selection + 1) % filtered_count;
                }
                return;
            },
            'p' => {
                if (filtered_count > 0) {
                    app.state.branch_select.selection = if (app.state.branch_select.selection == 0) filtered_count - 1 else app.state.branch_select.selection - 1;
                }
                return;
            },
            else => {},
        }
    }

    // Handle arrow keys
    if (key.codepoint == vaxis.Key.down) {
        if (filtered_count > 0) {
            app.state.branch_select.selection = (app.state.branch_select.selection + 1) % filtered_count;
        }
        return;
    }
    if (key.codepoint == vaxis.Key.up) {
        if (filtered_count > 0) {
            app.state.branch_select.selection = if (app.state.branch_select.selection == 0) filtered_count - 1 else app.state.branch_select.selection - 1;
        }
        return;
    }

    // Handle special keys
    switch (key.codepoint) {
        'j' => {
            if (filtered_count > 0) {
                app.state.branch_select.selection = (app.state.branch_select.selection + 1) % filtered_count;
            }
        },
        'k' => {
            if (filtered_count > 0) {
                app.state.branch_select.selection = if (app.state.branch_select.selection == 0) filtered_count - 1 else app.state.branch_select.selection - 1;
            }
        },
        27 => { // ESC key - clear search or go back
            if (app.state.branch_select.search_len > 0) {
                // Clear search
                app.state.branch_select.search_len = 0;
                app.state.branch_select.selection = 0;
                try filter(&app.state.branch_select, app.allocator);
            } else {
                // Go back to empty menu
                app.mode = .normal;
            }
        },
        vaxis.Key.backspace => { // Backspace - delete last search char
            if (app.state.branch_select.search_len > 0) {
                app.state.branch_select.search_len -= 1;
                app.state.branch_select.selection = 0;
                try filter(&app.state.branch_select, app.allocator);
            }
        },
        '\r' => { // Enter key - select branch and diff against it
            if (filtered_count == 0) return;

            const filtered_idx = app.state.branch_select.filtered.items[app.state.branch_select.selection];
            const selected_branch = app.state.branch_select.list[filtered_idx];
            const branch_copy = try app.allocator.dupe(u8, selected_branch);
            errdefer app.allocator.free(branch_copy);

            const head = try app.allocator.dupe(u8, "HEAD");
            errdefer app.allocator.free(head);

            // Free old diff_source if needed
            switch (app.state.diff_source) {
                .working_dir, .stdin => {},
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
            app.state.pager_mode = false;
            app.mode = .normal;
            try app.refresh();
        },
        else => {
            // Handle text input for search
            if (key.codepoint >= 32 and key.codepoint <= 126) { // Printable ASCII
                if (app.state.branch_select.search_len < app.state.branch_select.search_query.len - 1) {
                    app.state.branch_select.search_query[app.state.branch_select.search_len] = @intCast(key.codepoint);
                    app.state.branch_select.search_len += 1;
                    app.state.branch_select.selection = 0;
                    try filter(&app.state.branch_select, app.allocator);
                }
            }
        },
    }
}

/// Reset and load the branch list for the picker.
pub fn start(self: *BranchSelectState, allocator: Allocator) !void {
    // Free old branch list
    for (self.list) |branch| {
        allocator.free(branch);
    }
    allocator.free(self.list);

    // Fetch branches
    self.list = try git.getBranches(allocator);
    self.selection = 0;
    self.search_len = 0;

    // Initialize filtered list with all branches
    try filter(self, allocator);
}

/// Rebuild the filtered index list from the current search query.
pub fn filter(self: *BranchSelectState, allocator: Allocator) !void {
    self.filtered.clearRetainingCapacity();

    const query = self.search_query[0..self.search_len];

    // If no query, show all branches
    if (query.len == 0) {
        for (self.list, 0..) |_, idx| {
            try self.filtered.append(allocator, idx);
        }
        return;
    }

    // Case-insensitive search
    for (self.list, 0..) |branch, idx| {
        if (containsIgnoreCase(branch, query)) {
            try self.filtered.append(allocator, idx);
        }
    }

    // Clamp selection to filtered list
    if (self.filtered.items.len > 0 and self.selection >= self.filtered.items.len) {
        self.selection = self.filtered.items.len - 1;
    }
}
