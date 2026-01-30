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

const Allocator = std.mem.Allocator;
const UnifiedRenderer = render_unified.UnifiedRenderer;

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

    // For stdin mode, we need special handling (parse directly)
    if (stdin_content) |content| {
        try renderStdinDiff(allocator, content);
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
    try renderAndOutput(allocator, &app);
}

fn renderStdinDiff(allocator: Allocator, content: []const u8) !void {
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

    try renderAndOutput(allocator, &app);

    // Prevent double-free - mark as stolen
    app.state.files = &[_]parser.FileDiff{};
}

fn renderAndOutput(allocator: Allocator, app: *App) !void {
    // Calculate exact height needed (no buffer - avoids trailing sidebar lines)
    const total_lines = app.state.line_map.records.len;
    const height: u16 = @intCast(@min(total_lines, 10000));
    const width: u16 = 120; // Reasonable default width

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

    // Write to stdout (Zig 0.15 API)
    var stdout_buffer: [4096]u8 = undefined;
    var file_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer file_writer.interface.flush() catch {};
    try file_writer.interface.writeAll(ansi_output);
    try file_writer.interface.writeByte('\n');
}

const Config = struct {
    diff_source: git.DiffSource,

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

fn parseArgs(allocator: Allocator, args: []const []const u8) !Config {
    var staged = false;
    var positional_args: std.ArrayList([]const u8) = .{};
    defer positional_args.deinit(allocator);

    // Skip "skim" and "print"
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--staged") or std.mem.eql(u8, arg, "--cached")) {
            staged = true;
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

    return Config{ .diff_source = diff_source };
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
        \\    -h, --help            Print this help message
        \\
        \\EXAMPLES:
        \\    skim print                    # Working directory changes
        \\    skim print --staged           # Staged changes
        \\    skim print main..feature      # Compare branches
        \\    skim print HEAD~5             # Last 5 commits
        \\    git diff | skim print         # Pipe diff from git
        \\    skim print | less -R          # Pipe to less with colors
        \\
    );
}
