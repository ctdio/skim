const std = @import("std");
const vaxis = @import("vaxis");
const Allocator = std.mem.Allocator;
const App = @import("../app.zig").App;
const git = @import("../git/diff.zig");

/// Commit selection sub-state: the loaded commit list, the search/filter query,
/// lazy-load bookkeeping, and the diff-mode submenu. All fields default so it
/// stays out of the State init literal.
pub const CommitSelectState = struct {
    list: std.ArrayList(git.CommitInfo) = .{}, // Loaded commits
    selection: usize = 0, // Selected index in commit selection menu
    search_query: [256]u8 = undefined, // Search query buffer for filtering commits
    search_len: usize = 0, // Length of search query
    filtered: std.ArrayList(usize) = .{}, // Indices of commits matching search query
    loaded_count: usize = 0, // Total commits loaded (for lazy loading)
    loading: bool = false, // Whether commits are being loaded
    selected_for_diff: ?git.CommitInfo = null, // Commit selected for diff submenu (owned copy)
    diff_mode_selection: usize = 0, // 0 = HEAD vs commit, 1 = commit vs parent

    pub fn deinit(self: *CommitSelectState, allocator: Allocator) void {
        for (self.list.items) |*commit| {
            commit.deinit(allocator);
        }
        self.list.deinit(allocator);
        self.filtered.deinit(allocator);
        if (self.selected_for_diff) |*commit| {
            commit.deinit(allocator);
        }
    }
};

const COMMIT_BATCH_SIZE: usize = 50;

/// Handle keyboard input when in commit selection mode
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    if (app.state.commit_select.list.items.len == 0) {
        // No commits - go back to normal mode
        app.mode = .normal;
        return;
    }

    const filtered_count = app.state.commit_select.filtered.items.len;

    // Handle Ctrl+key combinations
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n' => {
                if (filtered_count > 0) {
                    app.state.commit_select.selection = (app.state.commit_select.selection + 1) % filtered_count;
                    // Trigger lazy loading if near bottom
                    try checkLazyLoad(app);
                }
                return;
            },
            'p' => {
                if (filtered_count > 0) {
                    app.state.commit_select.selection = if (app.state.commit_select.selection == 0) filtered_count - 1 else app.state.commit_select.selection - 1;
                }
                return;
            },
            else => {},
        }
    }

    // Handle arrow keys
    if (key.codepoint == vaxis.Key.down) {
        if (filtered_count > 0) {
            app.state.commit_select.selection = (app.state.commit_select.selection + 1) % filtered_count;
            try checkLazyLoad(app);
        }
        return;
    }
    if (key.codepoint == vaxis.Key.up) {
        if (filtered_count > 0) {
            app.state.commit_select.selection = if (app.state.commit_select.selection == 0) filtered_count - 1 else app.state.commit_select.selection - 1;
        }
        return;
    }

    // Handle special keys
    switch (key.codepoint) {
        'j' => {
            if (filtered_count > 0) {
                app.state.commit_select.selection = (app.state.commit_select.selection + 1) % filtered_count;
                try checkLazyLoad(app);
            }
        },
        'k' => {
            if (filtered_count > 0) {
                app.state.commit_select.selection = if (app.state.commit_select.selection == 0) filtered_count - 1 else app.state.commit_select.selection - 1;
            }
        },
        27 => { // ESC key - clear search or go back
            if (app.state.commit_select.search_len > 0) {
                // Clear search
                app.state.commit_select.search_len = 0;
                app.state.commit_select.selection = 0;
                try filter(&app.state.commit_select, app.allocator);
            } else {
                // Go back to normal mode
                app.mode = .normal;
            }
        },
        vaxis.Key.backspace => { // Backspace - delete last search char
            if (app.state.commit_select.search_len > 0) {
                app.state.commit_select.search_len -= 1;
                app.state.commit_select.selection = 0;
                try filter(&app.state.commit_select, app.allocator);
            }
        },
        '\r' => { // Enter key - select commit and show diff mode submenu
            if (try selectForDiff(&app.state.commit_select, app.allocator)) {
                app.mode = .commit_diff_mode;
            }
        },
        else => {
            // Handle text input for search
            if (key.codepoint >= 32 and key.codepoint <= 126) { // Printable ASCII
                if (app.state.commit_select.search_len < app.state.commit_select.search_query.len - 1) {
                    app.state.commit_select.search_query[app.state.commit_select.search_len] = @intCast(key.codepoint);
                    app.state.commit_select.search_len += 1;
                    app.state.commit_select.selection = 0;
                    try filter(&app.state.commit_select, app.allocator);
                }
            }
        },
    }
}

/// Handle keyboard input when in commit diff mode submenu
pub fn handleDiffModeKey(app: *App, key: vaxis.Key) !void {
    // Handle Ctrl+key combinations
    if (key.mods.ctrl) {
        switch (key.codepoint) {
            'n' => {
                app.state.commit_select.diff_mode_selection = (app.state.commit_select.diff_mode_selection + 1) % 2;
                return;
            },
            'p' => {
                app.state.commit_select.diff_mode_selection = if (app.state.commit_select.diff_mode_selection == 0) 1 else 0;
                return;
            },
            else => {},
        }
    }

    // Handle arrow keys
    if (key.codepoint == vaxis.Key.down) {
        app.state.commit_select.diff_mode_selection = (app.state.commit_select.diff_mode_selection + 1) % 2;
        return;
    }
    if (key.codepoint == vaxis.Key.up) {
        app.state.commit_select.diff_mode_selection = if (app.state.commit_select.diff_mode_selection == 0) 1 else 0;
        return;
    }

    switch (key.codepoint) {
        'j' => {
            app.state.commit_select.diff_mode_selection = (app.state.commit_select.diff_mode_selection + 1) % 2;
        },
        'k' => {
            app.state.commit_select.diff_mode_selection = if (app.state.commit_select.diff_mode_selection == 0) 1 else 0;
        },
        '1' => {
            app.state.commit_select.diff_mode_selection = 0;
            try app.applyCommitDiff();
        },
        '2' => {
            app.state.commit_select.diff_mode_selection = 1;
            try app.applyCommitDiff();
        },
        27 => { // ESC - go back to commit selection
            // Free the selected commit
            if (app.state.commit_select.selected_for_diff) |*commit| {
                commit.deinit(app.allocator);
                app.state.commit_select.selected_for_diff = null;
            }
            app.mode = .commit_selection;
        },
        '\r' => { // Enter - apply selected diff mode
            try app.applyCommitDiff();
        },
        else => {},
    }
}

/// Check if we need to lazy load more commits
fn checkLazyLoad(app: *App) !void {
    const filtered_count = app.state.commit_select.filtered.items.len;
    const loaded_count = app.state.commit_select.list.items.len;

    // If we're within 5 items of the bottom of the loaded list and not currently loading
    if (filtered_count > 0 and app.state.commit_select.selection >= filtered_count -| 5) {
        // Only load more if we might be near the end of loaded commits
        // Get the actual commit index at current selection
        if (app.state.commit_select.selection < filtered_count) {
            const actual_idx = app.state.commit_select.filtered.items[app.state.commit_select.selection];
            if (actual_idx >= loaded_count -| 5) {
                try loadMore(&app.state.commit_select, app.allocator);
            }
        }
    }
}

/// Reset and load the first batch of commits for the picker.
pub fn start(self: *CommitSelectState, allocator: Allocator) !void {
    // Free old commit list
    for (self.list.items) |*commit| {
        commit.deinit(allocator);
    }
    self.list.clearRetainingCapacity();

    // Reset state
    self.selection = 0;
    self.search_len = 0;
    self.loaded_count = 0;
    self.loading = false;

    // Load first batch of commits
    try loadMore(self, allocator);

    // Initialize filtered list
    try filter(self, allocator);
}

/// Load the next batch of commits and refresh the filtered view.
pub fn loadMore(self: *CommitSelectState, allocator: Allocator) !void {
    if (self.loading) return;

    self.loading = true;
    defer self.loading = false;

    const new_commits = git.getCommits(allocator, self.loaded_count, COMMIT_BATCH_SIZE) catch |err| {
        std.log.err("Failed to load commits: {}", .{err});
        return;
    };
    errdefer {
        for (new_commits) |*c| c.deinit(allocator);
        allocator.free(new_commits);
    }

    // Append to commit list
    for (new_commits) |commit| {
        try self.list.append(allocator, commit);
    }
    allocator.free(new_commits);

    self.loaded_count += COMMIT_BATCH_SIZE;

    // Update filtered list
    try filter(self, allocator);
}

/// Rebuild the filtered index list from the current search query.
pub fn filter(self: *CommitSelectState, allocator: Allocator) !void {
    self.filtered.clearRetainingCapacity();

    const query = self.search_query[0..self.search_len];

    // If no query, show all commits
    if (query.len == 0) {
        for (self.list.items, 0..) |_, idx| {
            try self.filtered.append(allocator, idx);
        }
    } else {
        // Filter by hash, subject, author (case-insensitive)
        for (self.list.items, 0..) |commit, idx| {
            if (matchesQuery(commit, query)) {
                try self.filtered.append(allocator, idx);
            }
        }
    }

    // Clamp selection to filtered list
    if (self.filtered.items.len > 0 and self.selection >= self.filtered.items.len) {
        self.selection = self.filtered.items.len - 1;
    }
}

/// Copy the highlighted commit into `selected_for_diff` and prime the diff-mode
/// submenu. Returns false when there is nothing selected to act on.
pub fn selectForDiff(self: *CommitSelectState, allocator: Allocator) !bool {
    const filtered_count = self.filtered.items.len;
    if (filtered_count == 0) return false;

    const filtered_idx = self.filtered.items[self.selection];
    const commit = self.list.items[filtered_idx];

    // Free any existing selected commit
    if (self.selected_for_diff) |*old_commit| {
        old_commit.deinit(allocator);
    }

    // Make a copy of the selected commit
    self.selected_for_diff = .{
        .hash = try allocator.dupe(u8, commit.hash),
        .short_hash = try allocator.dupe(u8, commit.short_hash),
        .subject = try allocator.dupe(u8, commit.subject),
        .author = try allocator.dupe(u8, commit.author),
        .date = try allocator.dupe(u8, commit.date),
    };

    self.diff_mode_selection = 0;
    return true;
}

fn matchesQuery(commit: git.CommitInfo, query: []const u8) bool {
    // Case-insensitive substring match on hash, subject, author
    return containsIgnoreCase(commit.hash, query) or
        containsIgnoreCase(commit.short_hash, query) or
        containsIgnoreCase(commit.subject, query) or
        containsIgnoreCase(commit.author, query);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    const end = haystack.len - needle.len + 1;
    outer: for (0..end) |i| {
        for (0..needle.len) |j| {
            const h = std.ascii.toLower(haystack[i + j]);
            const n = std.ascii.toLower(needle[j]);
            if (h != n) continue :outer;
        }
        return true;
    }
    return false;
}
