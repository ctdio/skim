const std = @import("std");
const line_map = @import("line_map.zig");
const parser = @import("git/parser.zig");

const Allocator = std.mem.Allocator;

/// Search state for / search mode
pub const SearchState = struct {
    query_buffer: [256]u8, // Search query input buffer
    query_len: usize, // Current query length
    matches: std.ArrayList(usize), // Global line indices of matches
    current_match_idx: ?usize, // Index in matches array (not global line)
    allocator: Allocator, // For matches ArrayList

    pub fn init(allocator: Allocator) SearchState {
        return .{
            .query_buffer = undefined,
            .query_len = 0,
            .matches = .{},
            .current_match_idx = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SearchState) void {
        self.matches.deinit(self.allocator);
    }

    pub fn reset(self: *SearchState) void {
        self.query_len = 0;
        self.matches.clearRetainingCapacity();
        self.current_match_idx = null;
    }

    pub fn hasMatches(self: *const SearchState) bool {
        return self.matches.items.len > 0;
    }

    pub fn getCurrentMatchLine(self: *const SearchState) ?usize {
        if (self.current_match_idx) |idx| {
            if (idx < self.matches.items.len) {
                return self.matches.items[idx];
            }
        }
        return null;
    }

    pub fn getQuery(self: *const SearchState) []const u8 {
        return self.query_buffer[0..self.query_len];
    }
};

/// Perform search across all lines in the LineMap
pub fn performSearch(
    search_state: *SearchState,
    lmap: *const line_map.LineMap,
    files: []const parser.FileDiff,
) !void {
    search_state.matches.clearRetainingCapacity();

    if (search_state.query_len == 0) return;

    const query = search_state.query_buffer[0..search_state.query_len];

    // Smart case: case-insensitive if query is all lowercase, sensitive otherwise
    const is_case_sensitive = isCaseSensitive(query);

    // Search through all lines in LineMap
    const total_lines = lmap.getTotalLines();
    var line_idx: usize = 0;
    while (line_idx < total_lines) : (line_idx += 1) {
        const record = lmap.getLineRecord(line_idx) orelse continue;

        // Only search code lines (add, delete, context)
        if (record.line_type != .code_line) continue;

        const file = &files[record.file_idx];
        const code = record.line_type.code_line;
        const line_content = file.hunks[code.hunk_idx].lines[code.line_idx_in_hunk].content;

        // Search for query in line content
        if (searchInLine(line_content, query, is_case_sensitive)) {
            try search_state.matches.append(search_state.allocator, line_idx);
        }
    }
}

/// Jump to first search match at or after cursor position
/// Returns the new cursor line if a match was found
pub fn jumpToFirstMatch(search_state: *SearchState, current_cursor: usize) ?usize {
    if (!search_state.hasMatches()) return null;

    var found = false;

    // Find first match at or after cursor
    for (search_state.matches.items, 0..) |match_line, idx| {
        if (match_line >= current_cursor) {
            search_state.current_match_idx = idx;
            found = true;
            return match_line;
        }
    }

    // If no match after cursor, wrap to first match
    if (!found and search_state.matches.items.len > 0) {
        search_state.current_match_idx = 0;
        return search_state.matches.items[0];
    }

    return null;
}

/// Move to the next search match (with wraparound)
/// Returns the new cursor line if a match was found
pub fn nextMatch(search_state: *SearchState, current_cursor: usize) ?usize {
    if (!search_state.hasMatches()) return null;

    if (search_state.current_match_idx) |current_idx| {
        // Move to next match
        const next_idx = (current_idx + 1) % search_state.matches.items.len;
        search_state.current_match_idx = next_idx;
    } else {
        // No current match - find first match after cursor
        var found = false;
        for (search_state.matches.items, 0..) |match_line, idx| {
            if (match_line > current_cursor) {
                search_state.current_match_idx = idx;
                found = true;
                break;
            }
        }
        // If no match after cursor, wrap to first
        if (!found and search_state.matches.items.len > 0) {
            search_state.current_match_idx = 0;
        }
    }

    return search_state.getCurrentMatchLine();
}

/// Move to the previous search match (with wraparound)
/// Returns the new cursor line if a match was found
pub fn previousMatch(search_state: *SearchState, current_cursor: usize) ?usize {
    if (!search_state.hasMatches()) return null;

    if (search_state.current_match_idx) |current_idx| {
        // Move to previous match (with wraparound)
        const prev_idx = if (current_idx == 0)
            search_state.matches.items.len - 1
        else
            current_idx - 1;
        search_state.current_match_idx = prev_idx;
    } else {
        // No current match - find last match before cursor
        var found = false;
        var idx = search_state.matches.items.len;
        while (idx > 0) {
            idx -= 1;
            const match_line = search_state.matches.items[idx];
            if (match_line < current_cursor) {
                search_state.current_match_idx = idx;
                found = true;
                break;
            }
        }
        // If no match before cursor, wrap to last
        if (!found and search_state.matches.items.len > 0) {
            search_state.current_match_idx = search_state.matches.items.len - 1;
        }
    }

    return search_state.getCurrentMatchLine();
}

/// Check if a line contains the search query
pub fn searchInLine(haystack: []const u8, needle: []const u8, case_sensitive: bool) bool {
    if (needle.len > haystack.len) return false;
    if (needle.len == 0) return false;

    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        const slice = haystack[i .. i + needle.len];
        if (case_sensitive) {
            if (std.mem.eql(u8, slice, needle)) return true;
        } else {
            if (std.ascii.eqlIgnoreCase(slice, needle)) return true;
        }
    }
    return false;
}

/// Determine if search should be case-sensitive based on query content
/// Smart case: case-insensitive if query is all lowercase, sensitive otherwise
pub fn isCaseSensitive(query: []const u8) bool {
    for (query) |c| {
        if (c >= 'A' and c <= 'Z') return true;
    }
    return false;
}

// ===== Tests =====

test "searchInLine - case sensitive" {
    try std.testing.expect(searchInLine("Hello World", "World", true));
    try std.testing.expect(!searchInLine("Hello World", "world", true));
    try std.testing.expect(!searchInLine("Hello World", "WORLD", true));
}

test "searchInLine - case insensitive" {
    try std.testing.expect(searchInLine("Hello World", "world", false));
    try std.testing.expect(searchInLine("Hello World", "WORLD", false));
    try std.testing.expect(searchInLine("Hello World", "WoRlD", false));
}

test "searchInLine - edge cases" {
    // Empty strings
    try std.testing.expect(!searchInLine("", "test", false));
    try std.testing.expect(!searchInLine("test", "", false));

    // Needle longer than haystack
    try std.testing.expect(!searchInLine("hi", "hello", false));

    // Multiple occurrences
    try std.testing.expect(searchInLine("test test test", "test", false));

    // Partial match
    try std.testing.expect(!searchInLine("testing", "tin", false));
    try std.testing.expect(searchInLine("testing", "test", false));
}

test "isCaseSensitive - smart case" {
    try std.testing.expect(!isCaseSensitive("hello"));
    try std.testing.expect(!isCaseSensitive("hello world"));
    try std.testing.expect(isCaseSensitive("Hello"));
    try std.testing.expect(isCaseSensitive("hELLO"));
    try std.testing.expect(isCaseSensitive("HELLO"));
}
