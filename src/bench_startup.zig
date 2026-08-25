const std = @import("std");
const git = @import("git/diff.zig");
const parser = @import("git/parser.zig");
const syntax = @import("highlighting/core.zig");
const skim_io = @import("skim_io");
const DiffSource = git.DiffSource;

pub fn main(process_init: std.process.Init) !void {
    skim_io.init(process_init);

    const start_time = skim_io.nanoTimestamp();
    std.log.info("=== STARTUP BENCHMARK ===", .{});
    std.log.info("[{d}ms] Benchmark started", .{0});

    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const gpa_time = skim_io.nanoTimestamp();
    std.log.info("[{d}ms] GPA initialized", .{@divTrunc(gpa_time - start_time, std.time.ns_per_ms)});

    // Measure git diff
    const diff_start = skim_io.nanoTimestamp();
    const diff_text = try git.getDiff(allocator, .{ .working_dir = .{ .staged = false } });
    defer allocator.free(diff_text);

    const diff_end = skim_io.nanoTimestamp();
    const diff_duration = diff_end - diff_start;
    std.log.info("[{d}ms] Git diff complete ({d} bytes, took {d}ms)", .{
        @divTrunc(diff_end - start_time, std.time.ns_per_ms),
        diff_text.len,
        @divTrunc(diff_duration, std.time.ns_per_ms),
    });

    // Measure parsing
    const parse_start = skim_io.nanoTimestamp();
    const files = try parser.parse(allocator, diff_text);
    defer {
        for (files) |*file| {
            file.deinit(allocator);
        }
        allocator.free(files);
    }

    const parse_end = skim_io.nanoTimestamp();
    const parse_duration = parse_end - parse_start;
    std.log.info("[{d}ms] Diff parsed ({d} files, took {d}ms)", .{
        @divTrunc(parse_end - start_time, std.time.ns_per_ms),
        files.len,
        @divTrunc(parse_duration, std.time.ns_per_ms),
    });

    // Measure syntax highlighter init
    const syntax_start = skim_io.nanoTimestamp();
    var highlighter = try syntax.SyntaxHighlighter.init(allocator);
    defer highlighter.deinit();

    const syntax_end = skim_io.nanoTimestamp();
    const syntax_duration = syntax_end - syntax_start;
    std.log.info("[{d}ms] Syntax highlighter initialized (took {d}ms)", .{
        @divTrunc(syntax_end - start_time, std.time.ns_per_ms),
        @divTrunc(syntax_duration, std.time.ns_per_ms),
    });

    // Test syntax highlighting on all files to show caching benefit
    for (files, 0..) |*file, idx| {
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;

        // Build file content from hunks
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(allocator);

        for (file.hunks) |hunk| {
            for (hunk.lines) |line| {
                try content.appendSlice(allocator, line.content);
                try content.append(allocator, '\n');
            }
        }

        const highlight_start = skim_io.nanoTimestamp();
        const highlights = try highlighter.highlightFile(file_path, content.items);
        defer highlighter.freeHighlights(highlights);

        const highlight_end = skim_io.nanoTimestamp();
        const highlight_duration = highlight_end - highlight_start;
        std.log.info("[{d}ms] File {d} highlighted: {s} ({d} highlights, took {d}ms)", .{
            @divTrunc(highlight_end - start_time, std.time.ns_per_ms),
            idx + 1,
            file_path,
            highlights.len,
            @divTrunc(highlight_duration, std.time.ns_per_ms),
        });
    }

    const total_time = skim_io.nanoTimestamp();
    std.log.info("=== TOTAL: {d}ms ===", .{@divTrunc(total_time - start_time, std.time.ns_per_ms)});
}
