//! GitHub backend: shells out to the `gh` CLI and hands the raw JSON to the
//! pure parser in `parse.zig`. This is the imperative shell — the only IO in
//! the PR data layer lives here.

const std = @import("std");
const parse = @import("parse.zig");

pub const Error = error{ GhCommandFailed, GhNotFound };

const default_limit = 50;

const json_fields = "number,title,author,headRefName,baseRefName,isDraft,updatedAt,url,statusCheckRollup";

/// List open PRs for the repo in the current working directory.
pub fn listPullRequests(allocator: std.mem.Allocator) !parse.PullRequestList {
    const raw = try listPullRequestsRaw(allocator);
    defer allocator.free(raw);
    return parse.parse(allocator, raw);
}

/// List open PRs as the raw JSON `gh` emits, so callers can persist it verbatim
/// (e.g. to the on-disk cache) before parsing. Caller owns the returned bytes.
pub fn listPullRequestsRaw(allocator: std.mem.Allocator) ![]u8 {
    var buf: [16]u8 = undefined;
    const limit = std.fmt.bufPrint(&buf, "{d}", .{default_limit}) catch unreachable;

    const argv = [_][]const u8{
        "gh", "pr", "list", "--limit", limit, "--json", json_fields,
    };

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
        .max_output_bytes = 16 * 1024 * 1024,
    }) catch |err| switch (err) {
        error.FileNotFound => return Error.GhNotFound,
        else => return err,
    };
    errdefer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) {
            std.log.err("gh pr list failed ({d}): {s}", .{ code, result.stderr });
            return Error.GhCommandFailed;
        },
        else => return Error.GhCommandFailed,
    }

    return result.stdout;
}

/// Fetch a PR's head into a stable local ref (`refs/skim/pr-<number>`) without
/// touching the working tree, and fetch its base branch so `base...head` can be
/// diffed. Uses `pull/<number>/head`, which GitHub exposes on `origin` even for
/// fork PRs — so no extra remotes or worktrees are needed. Returns the local
/// head ref name; caller owns it.
pub fn fetchRef(allocator: std.mem.Allocator, params: struct {
    number: u32,
    base_ref: []const u8,
}) ![]u8 {
    const head_ref = try std.fmt.allocPrint(allocator, "refs/skim/pr-{d}", .{params.number});
    errdefer allocator.free(head_ref);

    const refspec = try std.fmt.allocPrint(allocator, "+pull/{d}/head:{s}", .{ params.number, head_ref });
    defer allocator.free(refspec);

    try runGit(allocator, &.{ "git", "fetch", "--quiet", "origin", refspec });

    if (params.base_ref.len > 0) {
        // Land the base in its remote-tracking ref so `origin/<base>...head`
        // resolves. Best-effort: a missing base only weakens the merge-base.
        const base_spec = try std.fmt.allocPrint(allocator, "+{s}:refs/remotes/origin/{s}", .{ params.base_ref, params.base_ref });
        defer allocator.free(base_spec);
        runGit(allocator, &.{ "git", "fetch", "--quiet", "origin", base_spec }) catch {};
    }

    return head_ref;
}

fn runGit(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
    }) catch |err| switch (err) {
        error.FileNotFound => return Error.GhNotFound,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) {
            std.log.err("git fetch failed ({d}): {s}", .{ code, result.stderr });
            return Error.GhCommandFailed;
        },
        else => return Error.GhCommandFailed,
    }
}
