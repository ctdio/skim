const std = @import("std");
const git = @import("git/diff.zig");
const parser = @import("git/parser.zig");
const syntax = @import("syntax.zig");
const DiffSource = git.DiffSource;

pub fn main() !void {
    const start_time = std.time.nanoTimestamp();
    std.log.info("=== FIRST RENDER BENCHMARK ===", .{});
    std.log.info("Simulating what happens when app renders for first time", .{});
    std.log.info("", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Git diff
    const diff_text = try git.getDiff(allocator, .{ .working_dir = .{ .staged = false } });
    defer allocator.free(diff_text);
    const diff_time = std.time.nanoTimestamp();
    std.log.info("[{d}ms] Git diff loaded", .{@divTrunc(diff_time - start_time, std.time.ns_per_ms)});

    // 2. Parse diff
    var files = try parser.parse(allocator, diff_text);
    defer {
        for (files) |*file| {
            file.deinit(allocator);
        }
        allocator.free(files);
    }
    const parse_time = std.time.nanoTimestamp();
    std.log.info("[{d}ms] Diff parsed ({d} files)", .{ @divTrunc(parse_time - start_time, std.time.ns_per_ms), files.len });

    // 3. Create syntax highlighter
    var highlighter = try syntax.SyntaxHighlighter.init(allocator);
    defer highlighter.deinit();

    if (files.len == 0) {
        std.log.info("No files to render", .{});
        return;
    }

    // 4. Simulate first render - this is what ensureHighlights does
    std.log.info("", .{});
    std.log.info("--- FIRST RENDER (file 0) ---", .{});
    const render_start = std.time.nanoTimestamp();

    const file = &files[0];
    const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;
    std.log.info("Rendering: {s}", .{file_path});

    // Build file content (what ensureHighlights does)
    var content = std.ArrayList(u8).init(allocator);
    defer content.deinit();

    for (file.hunks) |hunk| {
        for (hunk.lines) |line| {
            switch (line.line_type) {
                .delete => {},
                .add, .context => {
                    try content.appendSlice(line.content);
                    try content.append('\n');
                },
            }
        }
    }
    const content_time = std.time.nanoTimestamp();
    std.log.info("  [{d}ms] Content built ({d} bytes)", .{
        @divTrunc(content_time - start_time, std.time.ns_per_ms),
        content.items.len,
    });

    // Highlight file (expensive part)
    const highlight_start = std.time.nanoTimestamp();
    const highlights = try highlighter.highlightFile(file_path, content.items);
    defer highlighter.freeHighlights(highlights);
    const highlight_time = std.time.nanoTimestamp();
    std.log.info("  [{d}ms] Syntax highlighted ({d} highlights) - TOOK {d}ms", .{
        @divTrunc(highlight_time - start_time, std.time.ns_per_ms),
        highlights.len,
        @divTrunc(highlight_time - highlight_start, std.time.ns_per_ms),
    });

    const render_time = std.time.nanoTimestamp();
    std.log.info("[{d}ms] First render complete (total render time: {d}ms)", .{
        @divTrunc(render_time - start_time, std.time.ns_per_ms),
        @divTrunc(render_time - render_start, std.time.ns_per_ms),
    });

    const total_time = std.time.nanoTimestamp();
    std.log.info("", .{});
    std.log.info("=== TOTAL STARTUP TIME: {d}ms ===", .{@divTrunc(total_time - start_time, std.time.ns_per_ms)});
    std.log.info("  (This is what user experiences before seeing UI)", .{});
}
