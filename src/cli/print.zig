//! Pretty-print diffs to stdout with ANSI colors.
//!
//! Uses the same rendering system as the TUI (vaxis) via headless App mode.
//! This ensures visual consistency between TUI and print output.

const std = @import("std");
const git = @import("../git/diff.zig");
const parser = @import("../git/parser.zig");
const harness = @import("../testing/harness.zig");
const App = @import("../app.zig").App;
const render_unified = @import("../rendering/unified.zig");
const syntax = @import("../highlighting/core.zig");
const state_helpers = @import("../state.zig").StateHelpers;

const Allocator = std.mem.Allocator;
const UnifiedRenderer = render_unified.UnifiedRenderer;

const DEFAULT_WIDTH: u16 = 120;

/// Attempt to detect terminal width using ioctl.
/// Returns null if not a TTY or detection fails.
fn getTerminalWidth() ?u16 {
    // Try stderr first (often remains a TTY when stdout is piped)
    const stderr = std.fs.File.stderr();
    if (!std.posix.isatty(stderr.handle)) return null;

    var ws: std.posix.winsize = undefined;
    const result = std.posix.system.ioctl(stderr.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (result == 0 and ws.col > 0) {
        return ws.col;
    }
    return null;
}

/// Resolve the width to use for rendering.
/// Priority: explicit config > terminal detection > default
fn resolveWidth(config_width: ?u16) u16 {
    if (config_width) |w| return w;
    if (getTerminalWidth()) |w| return w;
    return DEFAULT_WIDTH;
}

pub fn run(allocator: Allocator, args: []const []const u8) !void {
    const config = try parseArgs(allocator, args);
    defer config.deinit(allocator);

    // Only check for piped stdin when no refs provided (working_dir mode)
    const should_check_stdin = config.diff_source == .working_dir;
    const raw_stdin = if (should_check_stdin) try readStdinIfPiped(allocator) else null;

    // Only use stdin content if it's non-empty
    const stdin_content: ?[]const u8 = if (raw_stdin) |content|
        if (content.len > 0) content else null
    else
        null;

    defer {
        if (raw_stdin) |content| {
            if (stdin_content == null) allocator.free(content);
        }
    }
    defer if (stdin_content) |content| allocator.free(content);

    const width = resolveWidth(config.width);

    // For stdin mode, we need special handling (parse directly)
    if (stdin_content) |content| {
        try renderStdinDiff(allocator, content, config.max_lines, width);
        return;
    }

    // Initialize headless App (loads and parses diff)
    var app = App.initHeadless(allocator, config.diff_source) catch |err| {
        switch (err) {
            error.GitCommandFailed => std.process.exit(1),
            else => return err,
        }
    };
    defer app.deinit();

    // Handle empty diff
    if (app.state.files.len == 0) {
        std.debug.print("No changes\n", .{});
        return;
    }

    // Render to vaxis screen and convert to ANSI
    try renderAndOutput(allocator, &app, config.max_lines, width);
}

fn renderStdinDiff(allocator: Allocator, content: []const u8, max_lines: ?usize, width: u16) !void {
    // Parse diff from stdin
    const clean_text = try parser.stripAnsi(allocator, content);
    defer allocator.free(clean_text);

    const files = try parser.parse(allocator, clean_text);
    defer {
        for (files) |*file| file.deinit(allocator);
        allocator.free(files);
    }

    if (files.len == 0) {
        std.debug.print("No changes\n", .{});
        return;
    }

    // For stdin mode, we can't use the full App (no git repo) so we use a simpler approach
    // Create a minimal headless app with working_dir source and replace the files
    var app = try App.initHeadless(allocator, .{ .working_dir = .{ .staged = false } });
    defer app.deinit();

    // Replace the app's files with our parsed stdin files
    // First free the app's files
    for (app.state.files) |*file| file.deinit(allocator);
    allocator.free(app.state.files);

    // Assign our files
    app.state.files = files;

    // Rebuild line map
    app.state.line_map.deinit();
    const line_map_mod = @import("../line_map.zig");
    app.state.line_map = try line_map_mod.LineMap.build(allocator, files, &app.state.comment_store, .all, true);

    try renderAndOutput(allocator, &app, max_lines, width);

    // Prevent double-free - mark as stolen
    app.state.files = &[_]parser.FileDiff{};
}

fn renderAndOutput(allocator: Allocator, app: *App, max_diff_lines: ?usize, width: u16) !void {
    // Apply syntax highlighting synchronously (print mode doesn't need async)
    applySyntaxHighlighting(allocator, app.state.files, &app.syntax_highlighter);

    // Count actual diff lines (lines in hunks, not headers/spacers)
    const total_diff_lines = countDiffLines(app.state.files);

    // Calculate render height based on diff line limit
    const total_render_lines = app.state.line_map.records.len;
    const render_limit = if (max_diff_lines) |limit|
        calcRenderLinesForDiffLimit(app.state.line_map, limit)
    else
        total_render_lines;
    const lines_to_render = @min(total_render_lines, render_limit);
    const truncated = total_diff_lines > (max_diff_lines orelse total_diff_lines);

    const height: u16 = @intCast(@min(lines_to_render, 10000));

    // Create test context (mock vaxis screen)
    var ctx = try harness.createTestContext(allocator, width, height);
    defer ctx.deinit();

    const win = ctx.window();

    // Set viewport to show all lines (no scrolling)
    app.state.viewport_height = win.height;
    app.state.global_scroll_offset = 0;
    app.state.global_cursor_line = 0;

    // Render using the real UnifiedRenderer
    try UnifiedRenderer.renderContent(app, win);

    // Convert to ANSI and output
    const ansi_output = try ctx.captureToAnsi();
    defer allocator.free(ansi_output);

    // Write to stdout
    var stdout_buffer: [4096]u8 = undefined;
    var file_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try file_writer.interface.writeAll(ansi_output);
    try file_writer.interface.writeByte('\n');

    // Show truncation warning on stdout (same stream ensures ordering)
    if (truncated) {
        const shown_diff_lines = max_diff_lines orelse total_diff_lines;
        try file_writer.interface.print(
            "\x1b[33m[truncated: showing {d} of {d} diff lines. Use --no-limit to show all, or --limit=N]\x1b[0m\n",
            .{ shown_diff_lines, total_diff_lines },
        );
    }
    
    file_writer.interface.flush() catch {};
}

/// Apply syntax highlighting synchronously to all hunks.
/// In print mode we can afford to block since there's no UI to keep responsive.
fn applySyntaxHighlighting(allocator: Allocator, files: []parser.FileDiff, highlighter: *syntax.SyntaxHighlighter) void {
    for (files) |*file| {
        const file_path = if (file.new_path.len > 0) file.new_path else file.old_path;
        
        // Skip unknown languages
        const lang = syntax.Language.fromFilePath(file_path);
        if (lang == .unknown) continue;

        for (file.hunks) |*hunk| {
            // Skip if already highlighted
            if (hunk.highlights != null) continue;

            // Build content for new file (add/context lines)
            const content = state_helpers.buildHunkContent(allocator, hunk) catch continue;
            defer allocator.free(content);

            // Build content for old file (delete/context lines)
            const old_content = state_helpers.buildHunkOldContent(allocator, hunk) catch continue;
            defer allocator.free(old_content);

            // Highlight synchronously
            if (highlighter.highlightFile(file_path, content)) |highlights| {
                hunk.highlights = highlights;
            } else |_| {}

            if (highlighter.highlightFile(file_path, old_content)) |old_highlights| {
                hunk.old_highlights = old_highlights;
            } else |_| {}
        }
    }
}

/// Count actual diff lines (lines in hunks, not headers/spacers).
fn countDiffLines(files: []const parser.FileDiff) usize {
    var count: usize = 0;
    for (files) |file| {
        for (file.hunks) |hunk| {
            count += hunk.lines.len;
        }
    }
    return count;
}

/// Calculate how many render lines are needed to show N diff lines.
/// Returns the index to stop at (exclusive) in the line_map records.
fn calcRenderLinesForDiffLimit(line_map: @import("../line_map.zig").LineMap, diff_line_limit: usize) usize {
    var diff_count: usize = 0;
    for (line_map.records, 0..) |record, i| {
        if (record.line_type == .code_line) {
            diff_count += 1;
            if (diff_count >= diff_line_limit) {
                return i + 1; // Include this line
            }
        }
    }
    return line_map.records.len; // Show all if limit not reached
}

const Config = struct {
    diff_source: git.DiffSource,
    max_lines: ?usize, // null means no limit
    width: ?u16, // null means auto-detect from terminal

    fn deinit(self: *const Config, allocator: Allocator) void {
        switch (self.diff_source) {
            .working_dir, .stdin => {},
            .single_ref => |sr| allocator.free(sr.ref),
            .two_refs => |tr| {
                allocator.free(tr.ref1);
                allocator.free(tr.ref2);
            },
        }
    }
};

// Default limit to prevent terminal lockup on massive diffs
const DEFAULT_MAX_LINES: usize = 5000;

fn parseArgs(allocator: Allocator, args: []const []const u8) !Config {
    var staged = false;
    var max_lines: ?usize = DEFAULT_MAX_LINES;
    var width: ?u16 = null;
    var positional_args: std.ArrayList([]const u8) = .{};
    defer positional_args.deinit(allocator);

    // Skip "skim" and "print"
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--staged") or std.mem.eql(u8, arg, "--cached")) {
            staged = true;
        } else if (std.mem.eql(u8, arg, "--no-limit")) {
            max_lines = null;
        } else if (std.mem.startsWith(u8, arg, "--limit=")) {
            const value = arg["--limit=".len..];
            max_lines = std.fmt.parseInt(usize, value, 10) catch {
                std.debug.print("Invalid --limit value: {s}\n", .{value});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--limit") or std.mem.eql(u8, arg, "-n")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("--limit requires a value\n", .{});
                std.process.exit(1);
            }
            max_lines = std.fmt.parseInt(usize, args[i], 10) catch {
                std.debug.print("Invalid --limit value: {s}\n", .{args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "--width=") or std.mem.startsWith(u8, arg, "-w=")) {
            const prefix_len = if (std.mem.startsWith(u8, arg, "--width=")) "--width=".len else "-w=".len;
            const value = arg[prefix_len..];
            width = std.fmt.parseInt(u16, value, 10) catch {
                std.debug.print("Invalid --width value: {s}\n", .{value});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--width") or std.mem.eql(u8, arg, "-w")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("--width requires a value\n", .{});
                std.process.exit(1);
            }
            width = std.fmt.parseInt(u16, args[i], 10) catch {
                std.debug.print("Invalid --width value: {s}\n", .{args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            std.process.exit(0);
        } else if (arg[0] == '-') {
            std.debug.print("Unknown option: {s}\n", .{arg});
            try printHelp();
            std.process.exit(1);
        } else {
            try positional_args.append(allocator, arg);
        }
    }

    // Build DiffSource based on positional arguments
    const diff_source = if (positional_args.items.len == 0) blk: {
        break :blk git.DiffSource{ .working_dir = .{ .staged = staged } };
    } else if (positional_args.items.len == 1) blk: {
        const arg = positional_args.items[0];

        // Check for triple-dot syntax first
        if (std.mem.indexOf(u8, arg, "...")) |pos| {
            const ref1 = try allocator.dupe(u8, arg[0..pos]);
            const ref2 = try allocator.dupe(u8, arg[pos + 3 ..]);
            break :blk git.DiffSource{ .two_refs = .{ .ref1 = ref1, .ref2 = ref2, .use_merge_base = true } };
        }
        // Check for double-dot syntax
        else if (std.mem.indexOf(u8, arg, "..")) |pos| {
            const ref1 = try allocator.dupe(u8, arg[0..pos]);
            const ref2 = try allocator.dupe(u8, arg[pos + 2 ..]);
            break :blk git.DiffSource{ .two_refs = .{ .ref1 = ref1, .ref2 = ref2, .use_merge_base = false } };
        }
        // Single ref
        else {
            const ref = try allocator.dupe(u8, arg);
            break :blk git.DiffSource{ .single_ref = .{ .ref = ref, .staged = staged } };
        }
    } else if (positional_args.items.len == 2) blk: {
        const ref1 = try allocator.dupe(u8, positional_args.items[0]);
        const ref2 = try allocator.dupe(u8, positional_args.items[1]);
        break :blk git.DiffSource{ .two_refs = .{ .ref1 = ref1, .ref2 = ref2, .use_merge_base = false } };
    } else {
        std.debug.print("Too many arguments. Expected at most 2 refs.\n", .{});
        try printHelp();
        std.process.exit(1);
    };

    return Config{ .diff_source = diff_source, .max_lines = max_lines, .width = width };
}

fn readStdinIfPiped(allocator: Allocator) !?[]const u8 {
    const stdin_file = std.fs.File.stdin();
    const stdin_is_tty = std.posix.isatty(stdin_file.handle);

    if (stdin_is_tty) {
        return null;
    }

    const max_size = 50 * 1024 * 1024;
    return try stdin_file.readToEndAlloc(allocator, max_size);
}

fn printHelp() !void {
    var stdout_buffer: [4096]u8 = undefined;
    var file_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer file_writer.interface.flush() catch {};
    const stdout = &file_writer.interface;
    try stdout.writeAll(
        \\skim print - Pretty-print diffs with syntax highlighting
        \\
        \\USAGE:
        \\    skim print [OPTIONS] [<ref> | <ref1>..<ref2> | <ref1>...<ref2>]
        \\    git diff | skim print
        \\
        \\OPTIONS:
        \\    --staged, --cached    Show staged changes
        \\    -n, --limit <N>       Max lines to output (default: 5000)
        \\    --no-limit            Remove line limit (use with caution)
        \\    -w, --width <N>       Output width (default: auto-detect, fallback: 120)
        \\    -h, --help            Print this help message
        \\
        \\EXAMPLES:
        \\    skim print                    # Working directory changes
        \\    skim print --staged           # Staged changes
        \\    skim print main..feature      # Compare branches
        \\    skim print HEAD~5             # Last 5 commits
        \\    skim print --no-limit HEAD~20 # Full output, no truncation
        \\    skim print -w 200             # Force 200 column width
        \\    git diff | skim print         # Pipe diff from git
        \\    skim print | less -R          # Pipe to less with colors
        \\
    );
}
