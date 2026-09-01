//! `skim skill` — print the agent guide that ships inside the binary.
//!
//! The MCP `get_skill` tool serves the same documents. This is the shell-only
//! path: an agent that can run commands but has no skim MCP server configured
//! can still learn the surface before touching it.

const std = @import("std");
const skim_io = @import("skim_io");
const skill = @import("../skill.zig");

var stdout_buffer: [4096]u8 = undefined;

pub const Args = struct {
    topic: skill.Topic = .overview,
    help: bool = false,
};

pub fn run(args: Args) !void {
    if (args.help) return printHelp();

    var file_writer = std.Io.File.stdout().writer(skim_io.get(), &stdout_buffer);
    defer file_writer.interface.flush() catch {};
    try file_writer.interface.writeAll(skill.document(args.topic));
}

/// Parse `skim skill [TOPIC]`. An unknown topic is an error rather than a
/// silent fallback to the overview: an agent that asked for `mcp` and got the
/// overview would not notice, and would act on the wrong reference.
pub fn parseArgs(args: []const []const u8) !Args {
    var parsed: Args = .{};

    // args[0] is the binary, args[1] is "skill".
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            parsed.help = true;
            continue;
        }
        parsed.topic = skill.Topic.parse(arg) orelse return error.UnknownTopic;
    }

    return parsed;
}

pub fn printUnknownTopic() void {
    var file_writer = std.Io.File.stderr().writer(skim_io.get(), &stdout_buffer);
    defer file_writer.interface.flush() catch {};
    file_writer.interface.print(
        "Unknown topic. Available topics: {s}\n",
        .{skill.topic_names},
    ) catch {};
}

fn printHelp() !void {
    var file_writer = std.Io.File.stdout().writer(skim_io.get(), &stdout_buffer);
    defer file_writer.interface.flush() catch {};

    try file_writer.interface.print(
        \\skim skill - Print the agent guide for driving skim
        \\
        \\USAGE:
        \\    skim skill [TOPIC]
        \\
        \\TOPICS:
        \\    overview    How to review with skim (default)
        \\    mcp         Full MCP tool reference
        \\    cli         Full CLI command reference
        \\    workflow    Step-by-step review workflow
        \\
        \\EXAMPLES:
        \\    skim skill
        \\    skim skill cli
        \\    skim skill mcp
        \\
        \\The same documents are served over MCP by the `get_skill` tool.
        \\
    , .{});
}

test "no topic means the overview" {
    const parsed = try parseArgs(&.{ "skim", "skill" });
    try std.testing.expectEqual(skill.Topic.overview, parsed.topic);
    try std.testing.expect(!parsed.help);
}

test "a named topic is selected" {
    const parsed = try parseArgs(&.{ "skim", "skill", "cli" });
    try std.testing.expectEqual(skill.Topic.cli, parsed.topic);
}

test "an unknown topic is rejected rather than silently defaulted" {
    try std.testing.expectError(error.UnknownTopic, parseArgs(&.{ "skim", "skill", "nonsense" }));
}

test "help is requested with the usual flags" {
    try std.testing.expect((try parseArgs(&.{ "skim", "skill", "--help" })).help);
    try std.testing.expect((try parseArgs(&.{ "skim", "skill", "-h" })).help);
}
