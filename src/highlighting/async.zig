const std = @import("std");
const syntax = @import("core.zig");

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
            .job_queue = .{},
            .result_queue = .{},
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
        self.job_queue.deinit(self.allocator);

        // Free any remaining results
        for (self.result_queue.items) |result| {
            if (result.highlights) |highlights| {
                self.highlighter.freeHighlights(highlights);
            }
        }
        self.result_queue.deinit(self.allocator);

        self.highlighter.deinit();
        self.allocator.destroy(self);
    }

    // Submit a job (non-blocking, just adds to queue)
    pub fn submitJob(self: *HighlightWorker, job: HighlightJob) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.job_queue.append(self.allocator, job);
    }

    // Check for completed results (non-blocking)
    pub fn pollResults(self: *HighlightWorker, allocator: std.mem.Allocator, out_results: *std.ArrayList(HighlightResult)) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Transfer all completed results to caller
        for (self.result_queue.items) |result| {
            try out_results.append(allocator, result);
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
                self.result_queue.append(self.allocator, .{
                    .file_idx = job.file_idx,
                    .highlights = highlights,
                    .old_highlights = old_highlights,
                    .failed = highlights == null and old_highlights == null,
                }) catch {};
                self.mutex.unlock();
            } else {
                // No jobs available, sleep briefly to avoid busy-wait
                std.Thread.sleep(1 * std.time.ns_per_ms);
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
pub fn highlightWorker(job: *AsyncHighlightJob) void {
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
