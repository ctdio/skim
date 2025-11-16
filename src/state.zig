const std = @import("std");
const parser = @import("git/parser.zig");
const rendering_common = @import("rendering/common.zig");
const syntax = @import("syntax.zig");

const App = @import("app.zig").App;
const Layout = rendering_common.Layout;

// Highlighting job - lightweight request struct
pub const HighlightJob = struct {
    file_path: []const u8, // Borrowed reference
    content: []const u8, // Borrowed reference (new file content: add/context lines)
    old_content: []const u8, // Borrowed reference (old file content: delete/context lines)
    file_idx: usize,
};

// Completed highlighting result
pub const HighlightResult = struct {
    file_idx: usize,
    highlights: ?[]syntax.Highlight, // Highlights for new file (add/context lines)
    old_highlights: ?[]syntax.Highlight, // Highlights for old file (delete/context lines)
    failed: bool,
};

// Long-lived worker thread that maintains cached parsers
pub const HighlightWorker = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    job_queue: std.ArrayList(HighlightJob),
    result_queue: std.ArrayList(HighlightResult),
    mutex: std.Thread.Mutex,
    should_stop: bool,
    highlighter: syntax.SyntaxHighlighter,

    pub fn init(allocator: std.mem.Allocator) !*HighlightWorker {
        const worker = try allocator.create(HighlightWorker);
        errdefer allocator.destroy(worker);

        worker.* = .{
            .allocator = allocator,
            .thread = undefined, // Will be set below
            .job_queue = std.ArrayList(HighlightJob).init(allocator),
            .result_queue = std.ArrayList(HighlightResult).init(allocator),
            .mutex = std.Thread.Mutex{},
            .should_stop = false,
            .highlighter = try syntax.SyntaxHighlighter.init(allocator),
        };
        errdefer worker.highlighter.deinit();

        // Spawn the worker thread
        worker.thread = try std.Thread.spawn(.{}, workerThreadMain, .{worker});

        return worker;
    }

    pub fn deinit(self: *HighlightWorker) void {
        // Signal worker to stop
        self.mutex.lock();
        self.should_stop = true;
        self.mutex.unlock();

        // Wait for thread to finish
        self.thread.join();

        // Clean up queues
        self.job_queue.deinit();

        // Free any remaining results
        for (self.result_queue.items) |result| {
            if (result.highlights) |highlights| {
                self.highlighter.freeHighlights(highlights);
            }
        }
        self.result_queue.deinit();

        self.highlighter.deinit();
        self.allocator.destroy(self);
    }

    // Submit a job (non-blocking, just adds to queue)
    pub fn submitJob(self: *HighlightWorker, job: HighlightJob) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.job_queue.append(job);
    }

    // Check for completed results (non-blocking)
    pub fn pollResults(self: *HighlightWorker, out_results: *std.ArrayList(HighlightResult)) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Transfer all completed results to caller
        for (self.result_queue.items) |result| {
            try out_results.append(result);
        }
        self.result_queue.clearRetainingCapacity();
    }

    // Worker thread main loop
    fn workerThreadMain(self: *HighlightWorker) void {
        while (true) {
            // Check if we should stop
            self.mutex.lock();
            if (self.should_stop) {
                self.mutex.unlock();
                return;
            }

            // Get next job if available
            const job_opt = if (self.job_queue.items.len > 0)
                self.job_queue.orderedRemove(0)
            else
                null;
            self.mutex.unlock();

            if (job_opt) |job| {
                // Process the job (outside the lock for parallel work)
                // Highlight NEW file (add/context lines)
                const highlights = self.highlighter.highlightFile(job.file_path, job.content) catch null;

                // Highlight OLD file (delete/context lines)
                const old_highlights = self.highlighter.highlightFile(job.file_path, job.old_content) catch null;

                // Store result
                self.mutex.lock();
                self.result_queue.append(.{
                    .file_idx = job.file_idx,
                    .highlights = highlights,
                    .old_highlights = old_highlights,
                    .failed = highlights == null and old_highlights == null,
                }) catch {};
                self.mutex.unlock();
            } else {
                // No jobs available, sleep briefly to avoid busy-wait
                std.time.sleep(1 * std.time.ns_per_ms);
            }
        }
    }
};

// Legacy struct for compatibility (deprecated)
pub const AsyncHighlightJob = struct {
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    // Input data (set before spawning thread)
    file_path: []u8, // Owned copy
    content: []u8, // Owned copy of NEW file content (add/context lines)
    old_content: []u8, // Owned copy of OLD file content (delete/context lines)
    file_idx: usize,
    // Output data (written by thread, read by main)
    highlights: ?[]syntax.Highlight, // Highlights for new file
    old_highlights: ?[]syntax.Highlight, // Highlights for old file
    done: bool,
    failed: bool,

    pub fn init(allocator: std.mem.Allocator) !*AsyncHighlightJob {
        const job = try allocator.create(AsyncHighlightJob);
        job.* = .{
            .mutex = std.Thread.Mutex{},
            .allocator = allocator,
            .file_path = &[_]u8{},
            .content = &[_]u8{},
            .old_content = &[_]u8{},
            .file_idx = 0,
            .highlights = null,
            .old_highlights = null,
            .done = false,
            .failed = false,
        };
        return job;
    }

    pub fn deinit(self: *AsyncHighlightJob) void {
        if (self.file_path.len > 0) self.allocator.free(self.file_path);
        if (self.content.len > 0) self.allocator.free(self.content);
        if (self.old_content.len > 0) self.allocator.free(self.old_content);
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

    // Highlight NEW file content (add/context lines)
    const highlights = highlighter.highlightFile(job.file_path, job.content) catch {
        job.mutex.lock();
        job.failed = true;
        job.done = true;
        job.mutex.unlock();
        return;
    };

    // Highlight OLD file content (delete/context lines)
    const old_highlights = highlighter.highlightFile(job.file_path, job.old_content) catch {
        job.mutex.lock();
        job.failed = true;
        job.done = true;
        job.mutex.unlock();
        return;
    };

    // Store results (thread-safe)
    job.mutex.lock();
    job.highlights = highlights;
    job.old_highlights = old_highlights;
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
        const thread = try std.Thread.spawn(.{}, highlightWorker, .{job});
        thread.detach(); // Let it run independently

        return job;
    }
};
