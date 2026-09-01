//! Test root for the MCP surface. Zig only runs `test` blocks from a
//! compilation's root file, so tests that need `mcp/adapter.zig` have to live
//! here rather than beside it — the same reason `review_test_root.zig` and its
//! siblings exist.
//!
//! What it guards: `skills/skim/` is what an agent reads to learn this server,
//! and nothing links the two. A renamed tool leaves the docs pointing at a name
//! that no longer exists, and the only symptom is an agent calling a tool that
//! isn't there. These tests bind the docs to the registration list so the drift
//! breaks the build instead.

const std = @import("std");
const adapter = @import("mcp/adapter.zig");

const tool_prefix = "mcp__skim__";

const skill_docs = [_][]const u8{
    @embedFile("skill_skill_md"),
    @embedFile("skill_mcp_md"),
    @embedFile("skill_cli_md"),
    @embedFile("skill_workflow_md"),
};

test "every tool the skill docs name is registered by the server" {
    var server = adapter.McpAdapter.init(std.testing.allocator);
    defer server.deinit();

    for (skill_docs) |doc| {
        var rest = doc;
        while (std.mem.indexOf(u8, rest, tool_prefix)) |at| {
            rest = rest[at + tool_prefix.len ..];
            const name = leadingToolName(rest);
            if (name.len == 0) continue;

            if (!isRegistered(&server, name)) {
                std.debug.print(
                    "skill docs name an unregistered MCP tool: {s}{s}\n",
                    .{ tool_prefix, name },
                );
                return error.UnregisteredToolInSkillDocs;
            }
        }
    }
}

test "every tool the server registers is named in the skill docs" {
    var server = adapter.McpAdapter.init(std.testing.allocator);
    defer server.deinit();

    for (server.server.tools.items) |t| {
        var documented = false;
        for (skill_docs) |doc| {
            if (std.mem.indexOf(u8, doc, t.name) != null) {
                documented = true;
                break;
            }
        }
        if (!documented) {
            std.debug.print("registered MCP tool missing from the skill docs: {s}\n", .{t.name});
            return error.UndocumentedTool;
        }
    }
}

test "the skill docs use the session_id parameter the tools actually take" {
    for (skill_docs) |doc| {
        if (std.mem.indexOf(u8, doc, "client_id") != null) {
            std.debug.print("skill docs use 'client_id'; the tools take 'session_id'\n", .{});
            return error.StaleParameterName;
        }
    }
}

fn isRegistered(server: *adapter.McpAdapter, name: []const u8) bool {
    for (server.server.tools.items) |t| {
        if (std.mem.eql(u8, t.name, name)) return true;
    }
    return false;
}

/// The tool name at the front of `text`, i.e. its leading run of `[a-z0-9_]`.
fn leadingToolName(text: []const u8) []const u8 {
    var end: usize = 0;
    while (end < text.len) : (end += 1) {
        const c = text[end];
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
        if (!ok) break;
    }
    return text[0..end];
}

test "initialize advertises the server instructions" {
    const allocator = std.testing.allocator;

    var server = adapter.McpAdapter.init(allocator);
    defer server.deinit();

    const response = try server.server.encodeInitializeResponse(allocator);
    defer allocator.free(response);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    const instructions = parsed.value.object.get("instructions") orelse
        return error.MissingInstructions;
    try std.testing.expect(instructions == .string);

    // The two things a model most reliably gets wrong without being told.
    try std.testing.expect(std.mem.indexOf(u8, instructions.string, "author") != null);
    try std.testing.expect(std.mem.indexOf(u8, instructions.string, "reply_to_comment") != null);
}

test "the instructions only name tools the server registers" {
    const allocator = std.testing.allocator;

    var server = adapter.McpAdapter.init(allocator);
    defer server.deinit();

    // Backtick-quoted names in the instructions are tool references; every one
    // has to resolve or the guidance sends the model at a tool that is not there.
    var rest: []const u8 = server.server.config.instructions;
    while (std.mem.indexOfScalar(u8, rest, '`')) |open_at| {
        rest = rest[open_at + 1 ..];
        const close_at = std.mem.indexOfScalar(u8, rest, '`') orelse break;
        const quoted = rest[0..close_at];
        rest = rest[close_at + 1 ..];

        // Only check things shaped like a tool name, not params like `author`.
        if (!std.mem.endsWith(u8, quoted, "_comment") and
            !std.mem.endsWith(u8, quoted, "_comments") and
            !std.mem.endsWith(u8, quoted, "_sessions") and
            !std.mem.endsWith(u8, quoted, "_diff")) continue;

        if (!isRegistered(&server, quoted)) {
            std.debug.print("instructions name an unregistered tool: {s}\n", .{quoted});
            return error.UnregisteredToolInInstructions;
        }
    }
}
