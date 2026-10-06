//! Case-insensitive substring match shared by `github.zig` (gh error
//! classification), `filter_query.zig` (sidebar text terms) and the
//! model/commit/branch selection modes.

const std = @import("std");

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "containsIgnoreCase: an empty needle matches everything" {
    try testing.expect(containsIgnoreCase("octocat", ""));
    try testing.expect(containsIgnoreCase("", ""));
}

test "containsIgnoreCase: ignores case on both sides" {
    try testing.expect(containsIgnoreCase("OctoCat", "octo"));
    try testing.expect(containsIgnoreCase("octocat", "CAT"));
    try testing.expect(!containsIgnoreCase("OctoCat", "alice"));
}

test "containsIgnoreCase: matches at the start, middle and end" {
    try testing.expect(containsIgnoreCase("fix/login", "fix"));
    try testing.expect(containsIgnoreCase("fix/login", "x/lo"));
    try testing.expect(containsIgnoreCase("fix/login", "login"));
}

test "containsIgnoreCase: a needle longer than the haystack never matches" {
    try testing.expect(!containsIgnoreCase("main", "mainline"));
    try testing.expect(!containsIgnoreCase("", "a"));
}

test "containsIgnoreCase: a partial overlap at the end is not a match" {
    try testing.expect(!containsIgnoreCase("feature", "uref"));
}
