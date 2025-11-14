const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("app.zig").App;
const DiffSource = @import("git/diff.zig").DiffSource;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("Memory leak detected!", .{});
        }
    }
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const config = try parseArgs(allocator, args);
    defer config.deinit();

    // Initialize and run the app
    var app = try App.init(allocator, config);
    defer app.deinit();

    try app.run();
}

const Config = struct {
    allocator: std.mem.Allocator,
    diff_source: DiffSource,

    fn deinit(self: *const Config) void {
        switch (self.diff_source) {
            .working_dir => {},
            .single_ref => |sr| {
                self.allocator.free(sr.ref);
            },
            .two_refs => |tr| {
                self.allocator.free(tr.ref1);
                self.allocator.free(tr.ref2);
            },
        }
    }
};

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !Config {
    var staged = false;
    var positional_args = std.ArrayList([]const u8).init(allocator);
    defer positional_args.deinit();

    // Parse flags and collect positional arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--staged") or std.mem.eql(u8, arg, "--cached")) {
            staged = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try printVersion();
            std.process.exit(0);
        } else if (arg[0] == '-') {
            std.debug.print("Unknown option: {s}\n", .{arg});
            try printHelp();
            std.process.exit(1);
        } else {
            try positional_args.append(arg);
        }
    }

    // Build DiffSource based on positional arguments
    const diff_source = if (positional_args.items.len == 0) blk: {
        // No refs: working dir or staged
        break :blk DiffSource{ .working_dir = .{ .staged = staged } };
    } else if (positional_args.items.len == 1) blk: {
        const arg = positional_args.items[0];

        // Check for triple-dot syntax first (must come before double-dot check)
        if (std.mem.indexOf(u8, arg, "...")) |pos| {
            const ref1 = try allocator.dupe(u8, arg[0..pos]);
            const ref2 = try allocator.dupe(u8, arg[pos + 3 ..]);
            break :blk DiffSource{ .two_refs = .{ .ref1 = ref1, .ref2 = ref2, .use_merge_base = true } };
        }
        // Check for double-dot syntax
        else if (std.mem.indexOf(u8, arg, "..")) |pos| {
            const ref1 = try allocator.dupe(u8, arg[0..pos]);
            const ref2 = try allocator.dupe(u8, arg[pos + 2 ..]);
            break :blk DiffSource{ .two_refs = .{ .ref1 = ref1, .ref2 = ref2, .use_merge_base = false } };
        }
        // Single ref
        else {
            const ref = try allocator.dupe(u8, arg);
            break :blk DiffSource{ .single_ref = .{ .ref = ref, .staged = staged } };
        }
    } else if (positional_args.items.len == 2) blk: {
        // Two separate refs
        const ref1 = try allocator.dupe(u8, positional_args.items[0]);
        const ref2 = try allocator.dupe(u8, positional_args.items[1]);
        break :blk DiffSource{ .two_refs = .{ .ref1 = ref1, .ref2 = ref2, .use_merge_base = false } };
    } else {
        std.debug.print("Too many arguments. Expected at most 2 refs.\n", .{});
        try printHelp();
        std.process.exit(1);
    };

    return Config{
        .allocator = allocator,
        .diff_source = diff_source,
    };
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\skim - Lightning-fast code review TUI
        \\
        \\USAGE:
        \\    skim [OPTIONS] [<ref> | <ref1> <ref2> | <ref1>..<ref2> | <ref1>...<ref2>]
        \\
        \\OPTIONS:
        \\    --staged, --cached    Review staged changes (or staged vs. ref if ref provided)
        \\    -h, --help            Print this help message
        \\    -v, --version         Print version information
        \\
        \\DIFF PATTERNS (git-like):
        \\    <none>                Working directory vs. index
        \\    --staged              Index vs. HEAD
        \\    <ref>                 Working directory vs. ref
        \\    --staged <ref>        Index vs. ref
        \\    <ref1> <ref2>         ref1 vs. ref2
        \\    <ref1>..<ref2>        ref1 vs. ref2 (same as above)
        \\    <ref1>...<ref2>       Merge-base of ref1 and ref2 vs. ref2
        \\
        \\EXAMPLES:
        \\    skim                      # Working directory changes
        \\    skim --staged             # Staged changes
        \\    skim main                 # Working dir vs. main branch
        \\    skim --staged main        # Staged vs. main branch
        \\    skim main feature         # Compare two branches
        \\    skim main..feature        # Same as above
        \\    skim main...feature       # Changes on feature since diverging from main
        \\    skim HEAD~5               # Working dir vs. 5 commits ago
        \\
        \\KEYBINDINGS:
        \\    h/l or Ctrl-n/p    Navigate files
        \\    j/k                Cursor up/down (vim-style)
        \\    Ctrl-d/u           Page down/up
        \\    Enter              Focus mode
        \\    c                  Add comment on cursor line
        \\    s                  Toggle split view
        \\    q                  Quit
        \\    Ctrl-C × 2         Force exit (double-press)
        \\    ?                  Help
        \\
    );
}

fn printVersion() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("skim 0.1.0\n");
}

test "parse args: working directory" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{"skim"};

    const config = try parseArgs(allocator, args);
    defer config.deinit();

    try std.testing.expect(config.diff_source == .working_dir);
    try std.testing.expect(config.diff_source.working_dir.staged == false);
}

test "parse args: staged" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "skim", "--staged" };

    const config = try parseArgs(allocator, args);
    defer config.deinit();

    try std.testing.expect(config.diff_source == .working_dir);
    try std.testing.expect(config.diff_source.working_dir.staged == true);
}

test "parse args: two refs with double-dot" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "skim", "main..feature" };

    const config = try parseArgs(allocator, args);
    defer config.deinit();

    try std.testing.expect(config.diff_source == .two_refs);
    try std.testing.expectEqualStrings("main", config.diff_source.two_refs.ref1);
    try std.testing.expectEqualStrings("feature", config.diff_source.two_refs.ref2);
    try std.testing.expect(config.diff_source.two_refs.use_merge_base == false);
}

test "parse args: single ref" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "skim", "main" };

    const config = try parseArgs(allocator, args);
    defer config.deinit();

    try std.testing.expect(config.diff_source == .single_ref);
    try std.testing.expectEqualStrings("main", config.diff_source.single_ref.ref);
    try std.testing.expect(config.diff_source.single_ref.staged == false);
}

test "parse args: single ref with staged" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "skim", "--staged", "main" };

    const config = try parseArgs(allocator, args);
    defer config.deinit();

    try std.testing.expect(config.diff_source == .single_ref);
    try std.testing.expectEqualStrings("main", config.diff_source.single_ref.ref);
    try std.testing.expect(config.diff_source.single_ref.staged == true);
}

test "parse args: two refs separated" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "skim", "main", "feature" };

    const config = try parseArgs(allocator, args);
    defer config.deinit();

    try std.testing.expect(config.diff_source == .two_refs);
    try std.testing.expectEqualStrings("main", config.diff_source.two_refs.ref1);
    try std.testing.expectEqualStrings("feature", config.diff_source.two_refs.ref2);
    try std.testing.expect(config.diff_source.two_refs.use_merge_base == false);
}

test "parse args: two refs with triple-dot" {
    const allocator = std.testing.allocator;
    const args = &[_][]const u8{ "skim", "main...feature" };

    const config = try parseArgs(allocator, args);
    defer config.deinit();

    try std.testing.expect(config.diff_source == .two_refs);
    try std.testing.expectEqualStrings("main", config.diff_source.two_refs.ref1);
    try std.testing.expectEqualStrings("feature", config.diff_source.two_refs.ref2);
    try std.testing.expect(config.diff_source.two_refs.use_merge_base == true);
}
