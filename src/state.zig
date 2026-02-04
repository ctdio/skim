const std = @import("std");
const parser = @import("git/parser.zig");
const rendering_common = @import("rendering/common.zig");
const highlighting = @import("highlighting/async.zig");

const App = @import("app.zig").App;
const Layout = rendering_common.Layout;

// Re-export async highlighting types for backward compatibility
pub const HighlightJob = highlighting.HighlightJob;
pub const HighlightResult = highlighting.HighlightResult;
pub const HighlightWorker = highlighting.HighlightWorker;
pub const AsyncHighlightJob = highlighting.AsyncHighlightJob;

pub const StateHelpers = struct {
    pub const FileDiffStats = struct {
        additions: usize,
        deletions: usize,
    };
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

    // Calculate the gutter width across all files (for consistent width in continuous view)
    pub fn getGlobalGutterWidth(files: []const parser.FileDiff) usize {
        return getGlobalGutterWidthWithBlame(files, false);
    }

    // Calculate the gutter width with optional blame info
    // Blame format: "12ab34cd username____ Dec  5 2024 2mo msg_trunc... " = 8 + 1 + 12 + 1 + 11 + 1 + 4 + 1 + 16 + 1 = 56 chars
    // Or continuation: "│" (same commit as previous line)
    pub const BLAME_GUTTER_WIDTH: usize = 56;
    pub const BLAME_SEPARATOR_WIDTH: usize = 1; // "│" separator between blame and line number

    pub fn getGlobalGutterWidthWithBlame(files: []const parser.FileDiff, show_blame: bool) usize {
        var max_lineno: u32 = 0;
        for (files) |*file| {
            const file_max = getMaxLineNumber(file);
            max_lineno = @max(max_lineno, file_max);
        }
        const digits = countDigits(max_lineno);
        const calculated = digits + 1;
        const base_width = @max(calculated, Layout.min_gutter_width);

        if (show_blame) {
            return base_width + BLAME_GUTTER_WIDTH + BLAME_SEPARATOR_WIDTH;
        }
        return base_width;
    }

    // Calculate additions and deletions in a file
    pub fn calculateDiffStats(_: *App, file: *const parser.FileDiff) FileDiffStats {
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

    // Calculate total additions and deletions across all files
    pub fn calculateTotalDiffStats(_: *App, files: []const parser.FileDiff) struct { files: usize, additions: usize, deletions: usize } {
        var total_additions: usize = 0;
        var total_deletions: usize = 0;

        for (files) |*file| {
            for (file.hunks) |hunk| {
                for (hunk.lines) |line| {
                    switch (line.line_type) {
                        .add => total_additions += 1,
                        .delete => total_deletions += 1,
                        .context => {},
                    }
                }
            }
        }

        return .{ .files = files.len, .additions = total_additions, .deletions = total_deletions };
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
    // Non-blocking: Only applies highlights if already computed
    // Never blocks to compute new highlights during rendering
    pub fn ensureHighlights(app: *App, file: *parser.FileDiff, allow_async: bool) !void {
        _ = app;
        _ = allow_async;
        // Do nothing - only use highlights that are already computed
        // New highlights will be computed by background thread in main loop
        _ = file;
    }

    // Synchronous highlighting - blocks until complete
    fn highlightFileSync(app: *App, file: *parser.FileDiff) !void {
        if (file.highlights != null) return;

        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

        // Build the NEW file content from hunks
        // Skip deletions (old file), include additions and context (new file)
        var content: std.ArrayList(u8) = .{};
        defer content.deinit(app.allocator);

        for (file.hunks) |hunk| {
            for (hunk.lines) |line| {
                switch (line.line_type) {
                    .delete => {}, // Skip deletions - not in new file
                    .add, .context => {
                        try content.appendSlice(app.allocator, line.content);
                        try content.append(app.allocator, '\n');
                    },
                }
            }
        }

        // Generate highlights
        const highlights = try app.syntax_highlighter.highlightFile(file_path, content.items);

        // Cache them (NOTE: This modifies a "const" pointer, which is a hack for now)
        const mutable_file = @constCast(file);
        mutable_file.highlights = highlights;
    }

    // Request async highlighting for a specific file
    // Non-blocking: Just flags that highlighting is needed, doesn't compute it
    pub fn startAsyncHighlight(app: *App, file: *parser.FileDiff) !void {
        _ = file;
        // Don't block - just flag that we need highlighting
        // The main loop will spawn a background thread to do the work
        app.needs_async_highlight = true;
    }

    // Build file content efficiently (single allocation, fast)
    pub fn buildFileContent(allocator: std.mem.Allocator, file: *const parser.FileDiff) ![]u8 {
        // Step 1: Calculate exact size needed
        var total_size: usize = 0;
        for (file.hunks) |hunk| {
            for (hunk.lines) |line| {
                switch (line.line_type) {
                    .delete => {},
                    .add, .context => {
                        total_size += line.content.len + 1; // +1 for newline
                    },
                }
            }
        }

        // Step 2: Single allocation with exact size
        const content = try allocator.alloc(u8, total_size);
        errdefer allocator.free(content);

        // Step 3: Copy data in single pass (very fast memcpy operations)
        var offset: usize = 0;
        for (file.hunks) |hunk| {
            for (hunk.lines) |line| {
                switch (line.line_type) {
                    .delete => {},
                    .add, .context => {
                        @memcpy(content[offset .. offset + line.content.len], line.content);
                        offset += line.content.len;
                        content[offset] = '\n';
                        offset += 1;
                    },
                }
            }
        }

        return content;
    }

    // Build old file content from diff (context + delete lines only)
    // Returns owned slice that must be freed by caller
    pub fn buildOldFileContent(allocator: std.mem.Allocator, file: *const parser.FileDiff) ![]u8 {
        // Step 1: Calculate exact size needed
        var total_size: usize = 0;
        for (file.hunks) |hunk| {
            for (hunk.lines) |line| {
                switch (line.line_type) {
                    .add => {}, // Skip additions - not in old file
                    .delete, .context => {
                        total_size += line.content.len + 1; // +1 for newline
                    },
                }
            }
        }

        // Step 2: Single allocation with exact size
        const content = try allocator.alloc(u8, total_size);
        errdefer allocator.free(content);

        // Step 3: Copy data in single pass
        var offset: usize = 0;
        for (file.hunks) |hunk| {
            for (hunk.lines) |line| {
                switch (line.line_type) {
                    .add => {}, // Skip additions
                    .delete, .context => {
                        @memcpy(content[offset .. offset + line.content.len], line.content);
                        offset += line.content.len;
                        content[offset] = '\n';
                        offset += 1;
                    },
                }
            }
        }

        return content;
    }

    // Get byte offset for a line in the OLD file (for deleted/context lines)
    pub fn getOldLineByteOffset(file: *const parser.FileDiff, target_hunk_idx: usize, target_line_idx: usize) usize {
        var offset: usize = 0;

        for (file.hunks, 0..) |hunk, hunk_idx| {
            for (hunk.lines, 0..) |line, line_idx| {
                if (hunk_idx == target_hunk_idx and line_idx == target_line_idx) {
                    return offset;
                }
                // Only count deletions and context (additions are not in old file)
                switch (line.line_type) {
                    .add => {}, // Skip - not in old file
                    .delete, .context => {
                        offset += line.content.len + 1; // +1 for newline
                    },
                }
            }
        }

        return offset;
    }

    /// Build content for a single hunk (new file: add/context lines)
    pub fn buildHunkContent(allocator: std.mem.Allocator, hunk: *const parser.Hunk) ![]u8 {
        // Step 1: Calculate exact size needed
        var total_size: usize = 0;
        for (hunk.lines) |line| {
            switch (line.line_type) {
                .delete => {},
                .add, .context => {
                    total_size += line.content.len + 1; // +1 for newline
                },
            }
        }

        // Step 2: Single allocation with exact size
        const content = try allocator.alloc(u8, total_size);
        errdefer allocator.free(content);

        // Step 3: Copy data in single pass
        var offset: usize = 0;
        for (hunk.lines) |line| {
            switch (line.line_type) {
                .delete => {},
                .add, .context => {
                    @memcpy(content[offset .. offset + line.content.len], line.content);
                    offset += line.content.len;
                    content[offset] = '\n';
                    offset += 1;
                },
            }
        }

        return content;
    }

    /// Build content for a single hunk (old file: delete/context lines)
    pub fn buildHunkOldContent(allocator: std.mem.Allocator, hunk: *const parser.Hunk) ![]u8 {
        // Step 1: Calculate exact size needed
        var total_size: usize = 0;
        for (hunk.lines) |line| {
            switch (line.line_type) {
                .add => {}, // Skip additions - not in old file
                .delete, .context => {
                    total_size += line.content.len + 1; // +1 for newline
                },
            }
        }

        // Step 2: Single allocation with exact size
        const content = try allocator.alloc(u8, total_size);
        errdefer allocator.free(content);

        // Step 3: Copy data in single pass
        var offset: usize = 0;
        for (hunk.lines) |line| {
            switch (line.line_type) {
                .add => {}, // Skip additions
                .delete, .context => {
                    @memcpy(content[offset .. offset + line.content.len], line.content);
                    offset += line.content.len;
                    content[offset] = '\n';
                    offset += 1;
                },
            }
        }

        return content;
    }

    /// Byte offset within a single hunk (new file: add/context lines)
    pub fn getLineByteOffsetInHunk(hunk: *const parser.Hunk, target_line_idx: usize) usize {
        var offset: usize = 0;

        for (hunk.lines, 0..) |line, line_idx| {
            if (line_idx == target_line_idx) {
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

        return offset;
    }

    /// Byte offset within a single hunk (old file: delete/context lines)
    pub fn getOldLineByteOffsetInHunk(hunk: *const parser.Hunk, target_line_idx: usize) usize {
        var offset: usize = 0;

        for (hunk.lines, 0..) |line, line_idx| {
            if (line_idx == target_line_idx) {
                return offset;
            }
            // Only count deletions and context (additions are not in old file)
            switch (line.line_type) {
                .add => {}, // Skip - not in old file
                .delete, .context => {
                    offset += line.content.len + 1; // +1 for newline
                },
            }
        }

        return offset;
    }

    // Spawn a background thread to highlight a file (truly async)
    // Optimized: Build content on main thread with single allocation (fast)
    // Only parser loading/highlighting happens in background (slow part)
    pub fn spawnAsyncHighlight(app: *App, file_idx: usize) !*AsyncHighlightJob {
        if (file_idx >= app.state.files.len) return error.InvalidFileIndex;
        const file = &app.state.files[file_idx];

        if (file.highlights != null) return error.AlreadyHighlighted;

        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

        // Build NEW file content (add/context lines)
        const content = try buildFileContent(app.allocator, file);
        errdefer app.allocator.free(content);

        // Build OLD file content (delete/context lines)
        const old_content = try buildOldFileContent(app.allocator, file);
        errdefer app.allocator.free(old_content);

        // Create job with owned copies of data
        const job = try AsyncHighlightJob.init(app.allocator);
        errdefer job.deinit();

        job.file_path = try app.allocator.dupe(u8, file_path);
        job.content = content;
        job.old_content = old_content;
        job.file_idx = file_idx;

        // Spawn worker thread
        const thread = try std.Thread.spawn(.{}, highlighting.highlightWorker, .{job});
        thread.detach(); // Let it run independently

        return job;
    }
};
