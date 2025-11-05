const std = @import("std");
const parser = @import("git/parser.zig");
const rendering_common = @import("rendering/common.zig");

const App = @import("app.zig").App;
const Layout = rendering_common.Layout;

pub const StateHelpers = struct {
    // Calculate the maximum line number in a file (for gutter width calculation)
    pub fn getMaxLineNumber(file: *const parser.FileDiff) u32 {
        var max: u32 = 0;
        for (file.hunks) |hunk| {
            for (hunk.lines) |line| {
                if (line.old_lineno) |old| {
                    max = @max(max, old);
                }
                if (line.new_lineno) |new| {
                    max = @max(max, new);
                }
            }
        }
        return max;
    }

    // Count the number of digits in a number
    pub fn countDigits(n: u32) usize {
        if (n == 0) return 1;
        var count: usize = 0;
        var num = n;
        while (num > 0) {
            count += 1;
            num /= 10;
        }
        return count;
    }

    // Calculate the gutter width for a file (digits + sign character)
    pub fn getGutterWidth(file: *const parser.FileDiff) usize {
        const max_lineno = getMaxLineNumber(file);
        const digits = countDigits(max_lineno);
        // gutter width = number width + sign width (1 char)
        const calculated = digits + 1;
        // Ensure minimum width for consistency
        return @max(calculated, Layout.min_gutter_width);
    }

    // Calculate additions and deletions in a file
    pub fn calculateDiffStats(_: *App, file: *const parser.FileDiff) struct { additions: usize, deletions: usize } {
        var additions: usize = 0;
        var deletions: usize = 0;

        for (file.hunks) |hunk| {
            for (hunk.lines) |line| {
                switch (line.line_type) {
                    .add => additions += 1,
                    .delete => deletions += 1,
                    .context => {},
                }
            }
        }

        return .{ .additions = additions, .deletions = deletions };
    }

    // Calculate byte offset of a line in the NEW file content
    // Used to map line positions to highlight byte offsets
    // Skips deletions since they're not in the reconstructed file
    pub fn getLineByteOffset(file: *const parser.FileDiff, target_hunk_idx: usize, target_line_idx: usize) usize {
        var offset: usize = 0;

        for (file.hunks, 0..) |hunk, hunk_idx| {
            for (hunk.lines, 0..) |line, line_idx| {
                if (hunk_idx == target_hunk_idx and line_idx == target_line_idx) {
                    return offset;
                }
                // Only count additions and context (deletions are not in new file)
                switch (line.line_type) {
                    .delete => {}, // Skip - not in reconstructed content
                    .add, .context => {
                        offset += line.content.len + 1; // +1 for newline
                    },
                }
            }
        }

        return offset;
    }

    // Ensure syntax highlights are loaded for the given file
    pub fn ensureHighlights(app: *App, file: *parser.FileDiff) !void {
        if (file.highlights != null) return; // Already cached

        // Build the NEW file content from hunks
        // Skip deletions (old file), include additions and context (new file)
        var content = std.ArrayList(u8).init(app.allocator);
        defer content.deinit();

        for (file.hunks) |hunk| {
            for (hunk.lines) |line| {
                switch (line.line_type) {
                    .delete => {}, // Skip deletions - not in new file
                    .add, .context => {
                        try content.appendSlice(line.content);
                        try content.append('\n');
                    },
                }
            }
        }

        // Get file path (prefer new_path for syntax detection)
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

        // Generate highlights
        const highlights = try app.syntax_highlighter.highlightFile(file_path, content.items);

        // Cache them (NOTE: This modifies a "const" pointer, which is a hack for now)
        const mutable_file = @constCast(file);
        mutable_file.highlights = highlights;
    }
};
