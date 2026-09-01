//! The `skills/skim/` documents, compiled into the binary and served on demand.
//!
//! The same guidance ships three ways because agents reach skim three ways. As a
//! Claude Code plugin the files are read off disk; that only helps agents whose
//! harness installed the plugin. This module is for everyone else: an MCP client
//! calls `get_skill`, and an agent with nothing but a shell runs `skim skill`.
//! Serving it from the binary means the guidance is always the version that
//! matches the tools actually registered, which a separately-installed copy
//! cannot promise.

const std = @import("std");

/// Which document to serve. `overview` is the entry point and the default; the
/// rest are the deep dives it links to.
pub const Topic = enum {
    overview,
    mcp,
    cli,
    workflow,

    pub fn parse(name: []const u8) ?Topic {
        if (name.len == 0) return .overview;
        // `skill` is the whole set, spelled as the command's own name.
        if (std.mem.eql(u8, name, "overview") or std.mem.eql(u8, name, "skill")) return .overview;
        if (std.mem.eql(u8, name, "mcp")) return .mcp;
        if (std.mem.eql(u8, name, "cli")) return .cli;
        if (std.mem.eql(u8, name, "workflow")) return .workflow;
        return null;
    }
};

pub const topic_names = "overview, mcp, cli, workflow";

/// The document for `topic`, ready to hand to an agent.
///
/// The overview's YAML frontmatter is stripped: it is plugin-loader metadata
/// (when to activate the skill), and an agent that already called this tool has
/// answered that question by calling it.
pub fn document(topic: Topic) []const u8 {
    return switch (topic) {
        .overview => stripFrontmatter(overview_md),
        .mcp => mcp_md,
        .cli => cli_md,
        .workflow => workflow_md,
    };
}

const overview_md = @embedFile("skill_skill_md");
const mcp_md = @embedFile("skill_mcp_md");
const cli_md = @embedFile("skill_cli_md");
const workflow_md = @embedFile("skill_workflow_md");

const fence = "---";

fn stripFrontmatter(text: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, text, fence ++ "\n")) return text;

    const body = text[fence.len + 1 ..];
    const close = std.mem.indexOf(u8, body, "\n" ++ fence ++ "\n") orelse return text;
    const after = body[close + 1 + fence.len + 1 ..];

    return std.mem.trimStart(u8, after, "\n");
}

test "the overview is served without its plugin frontmatter" {
    const text = document(.overview);
    try std.testing.expect(!std.mem.startsWith(u8, text, "---"));
    try std.testing.expect(std.mem.startsWith(u8, text, "# Skim Code Review Integration"));
}

test "every topic serves a non-empty document" {
    for (std.enums.values(Topic)) |topic| {
        try std.testing.expect(document(topic).len > 0);
    }
}

test "a document without frontmatter is served unchanged" {
    try std.testing.expectEqualStrings("# Title\n\nbody\n", stripFrontmatter("# Title\n\nbody\n"));
}

test "an unterminated frontmatter fence leaves the text alone" {
    try std.testing.expectEqualStrings("---\nname: x\nno close fence\n", stripFrontmatter("---\nname: x\nno close fence\n"));
}

test "parse accepts the topic names it advertises" {
    try std.testing.expectEqual(Topic.overview, Topic.parse("").?);
    try std.testing.expectEqual(Topic.overview, Topic.parse("overview").?);
    try std.testing.expectEqual(Topic.mcp, Topic.parse("mcp").?);
    try std.testing.expectEqual(Topic.cli, Topic.parse("cli").?);
    try std.testing.expectEqual(Topic.workflow, Topic.parse("workflow").?);
    try std.testing.expectEqual(@as(?Topic, null), Topic.parse("nonsense"));
}

test "topic_names lists every topic it advertises" {
    // The string is what the CLI help, the tool description, and both error
    // messages show; a topic added without updating it goes unfindable.
    for (std.enums.values(Topic)) |topic| {
        const name = @tagName(topic);
        try std.testing.expect(std.mem.indexOf(u8, topic_names, name) != null);
        try std.testing.expectEqual(topic, Topic.parse(name).?);
    }
}
