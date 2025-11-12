const std = @import("std");
const parser = @import("git/parser.zig");
const rendering_common = @import("rendering/common.zig");
const syntax = @import("syntax.zig");

const App = @import("app.zig").App;
const Layout = rendering_common.Layout;

// Thread-safe async highlighting system
pub const AsyncHighlightJob = struct {
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    // Input data (set before spawning thread)
    file_path: []u8, // Owned copy
    content: []u8, // Owned copy
    file_idx: usize,
    // Output data (written by thread, read by main)
    highlights: ?[]syntax.Highlight,
    done: bool,
    failed: bool,

    pub fn init(allocator: std.mem.Allocator) !*AsyncHighlightJob {
        const job = try allocator.create(AsyncHighlightJob);
        job.* = .{
            .mutex = std.Thread.Mutex{},
            .allocator = allocator,
            .file_path = &[_]u8{},
            .content = &[_]u8{},
            .file_idx = 0,
            .highlights = null,
            .done = false,
            .failed = false,
        };
        return job;
    }

    pub fn deinit(self: *AsyncHighlightJob) void {
        if (self.file_path.len > 0) self.allocator.free(self.file_path);
        if (self.content.len > 0) self.allocator.free(self.content);
        self.allocator.destroy(self);
    }

    // Check if job is complete (thread-safe)
    pub fn isDone(self: *AsyncHighlightJob) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.done;
    }

    // Get results (thread-safe) - transfers ownership of highlights
    pub fn takeResults(self: *AsyncHighlightJob) ?[]syntax.Highlight {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.done or self.failed) return null;
        const result = self.highlights;
        self.highlights = null; // Transfer ownership
        return result;
    }
};

// Worker thread function for highlighting
fn highlightWorker(job: *AsyncHighlightJob) void {
    // Create a new syntax highlighter for this thread (tree-sitter not thread-safe)
    var highlighter = syntax.SyntaxHighlighter.init(job.allocator) catch {
        job.mutex.lock();
        job.failed = true;
        job.done = true;
        job.mutex.unlock();
        return;
    };
    defer highlighter.deinit();

    // Do the highlighting work
    const highlights = highlighter.highlightFile(job.file_path, job.content) catch {
        job.mutex.lock();
        job.failed = true;
        job.done = true;
        job.mutex.unlock();
        return;
    };

    // Store results (thread-safe)
    job.mutex.lock();
    job.highlights = highlights;
    job.done = true;
    job.mutex.unlock();
}

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

    // Calculate the gutter width across all files (for consistent width in continuous view)
    pub fn getGlobalGutterWidth(files: []const parser.FileDiff) usize {
        var max_lineno: u32 = 0;
        for (files) |*file| {
            const file_max = getMaxLineNumber(file);
            max_lineno = @max(max_lineno, file_max);
        }
        const digits = countDigits(max_lineno);
        const calculated = digits + 1;
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
    // Smart caching: If parser is already loaded, apply immediately (fast ~7ms)
    // If parser not cached and allow_async=false, skip (will be applied async later)
    pub fn ensureHighlights(app: *App, file: *parser.FileDiff, allow_async: bool) !void {
        if (file.highlights != null) return; // Already cached

        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

        // Check if parser/query is already cached - if so, use it immediately
        if (app.syntax_highlighter.isCached(file_path)) {
            // Parser is cached - highlighting is fast (~7ms), do it now
            try highlightFileSync(app, file);
            return;
        }

        // Parser not cached - this would be slow (~400ms)
        if (!allow_async) {
            return; // Render without syntax colors for now
        }

        // Synchronous highlighting (fallback or explicit request)
        try highlightFileSync(app, file);
    }

    // Synchronous highlighting - blocks until complete
    fn highlightFileSync(app: *App, file: *parser.FileDiff) !void {
        if (file.highlights != null) return;

        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

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

        // Generate highlights
        const highlights = try app.syntax_highlighter.highlightFile(file_path, content.items);

        // Cache them (NOTE: This modifies a "const" pointer, which is a hack for now)
        const mutable_file = @constCast(file);
        mutable_file.highlights = highlights;
    }

    // Start async highlighting for a specific file
    // Smart: If parser cached, apply immediately (~7ms). If not cached, skip (will load async later)
    pub fn startAsyncHighlight(app: *App, file: *parser.FileDiff) !void {
        if (file.highlights != null) return; // Already highlighted

        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

        // Only highlight if parser is already cached (fast path)
        if (app.syntax_highlighter.isCached(file_path)) {
            try highlightFileSync(app, file);
        }
        // If parser not cached, skip - don't block navigation
        // The main loop will trigger highlighting after first render
    }

    // Spawn a background thread to highlight a file (truly async)
    pub fn spawnAsyncHighlight(app: *App, file_idx: usize) !*AsyncHighlightJob {
        if (file_idx >= app.state.files.len) return error.InvalidFileIndex;
        const file = &app.state.files[file_idx];

        if (file.highlights != null) return error.AlreadyHighlighted;

        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

        // Build file content
        var content = std.ArrayList(u8).init(app.allocator);
        defer content.deinit();

        for (file.hunks) |hunk| {
            for (hunk.lines) |line| {
                switch (line.line_type) {
                    .delete => {}, // Skip deletions
                    .add, .context => {
                        try content.appendSlice(line.content);
                        try content.append('\n');
                    },
                }
            }
        }

        // Create job with owned copies of data
        const job = try AsyncHighlightJob.init(app.allocator);
        errdefer job.deinit();

        job.file_path = try app.allocator.dupe(u8, file_path);
        job.content = try app.allocator.dupe(u8, content.items);
        job.file_idx = file_idx;

        // Spawn worker thread
        const thread = try std.Thread.spawn(.{}, highlightWorker, .{job});
        thread.detach(); // Let it run independently

        return job;
    }
};
