//! Pure side-aware anchoring of GitHub review threads onto skim's parsed diff
//! coordinates. Zero IO — `[]ReviewThread` + `[]parser.FileDiff` in, a total
//! `[]AnchoredThread` out (AD-4: anchors are derived here on every rebuild, never
//! stored on the thread). AD-6 lives here and only here: GitHub's `diffSide`
//! maps onto skim's line numbers — RIGHT matches `new_lineno` (add/context),
//! LEFT matches `old_lineno` (delete/context). GitHub's `line` is the LAST line
//! of a multi-line range, which is exactly where skim renders range anchors.

const std = @import("std");
const review_parse = @import("review_parse.zig");
const parser = @import("../git/parser.zig");
const placement = @import("thread_placement.zig");

const Allocator = std.mem.Allocator;

pub const BucketReason = placement.BucketReason;
pub const Placement = placement.Placement;
pub const AnchoredThread = placement.AnchoredThread;
pub const countUnplaced = placement.countUnplaced;

/// Map every thread to a render placement. Total: `result.len == threads.len`,
/// with `result[i].thread_idx == i`. The caller owns the returned slice.
pub fn anchorThreads(
    allocator: Allocator,
    threads: []const review_parse.ReviewThread,
    files: []const parser.FileDiff,
) ![]AnchoredThread {
    const result = try allocator.alloc(AnchoredThread, threads.len);
    errdefer allocator.free(result);

    for (threads, 0..) |thread, idx| {
        result[idx] = .{ .thread_idx = idx, .placement = placeThread(thread, files) };
    }

    return result;
}

pub const GithubCoords = struct { side: review_parse.Side, line_no: u32 };

/// Map a diff line to the GitHub `(side, line)` a new comment should target
/// (AD-6, the pure skim→GitHub inverse of the anchoring above). A delete line
/// belongs to the LEFT (old) side; add/context lines to the RIGHT (new) side.
/// Returns null only when the required line number is absent (a malformed diff,
/// e.g. a delete line with no `old_lineno`) — callers refuse rather than panic.
pub fn deriveGithubCoords(line: parser.Line) ?GithubCoords {
    switch (line.line_type) {
        .delete => {
            const l = line.old_lineno orelse return null;
            return .{ .side = .left, .line_no = l };
        },
        .add, .context => {
            const l = line.new_lineno orelse return null;
            return .{ .side = .right, .line_no = l };
        },
    }
}

// =============================================================================
// Helpers
// =============================================================================

fn placeThread(thread: review_parse.ReviewThread, files: []const parser.FileDiff) Placement {
    const file_idx = findFile(files, thread.path) orelse return .unplaced;

    // FILE-subject threads have no line by design.
    if (thread.subject_type == .file) {
        return .{ .file_bucket = .{ .file_idx = file_idx, .reason = .file_level } };
    }

    // Outdated threads (or threads GitHub could not map to a current line) bucket
    // even if `original_line` would resolve — the current diff no longer shows it.
    if (thread.is_outdated or thread.line == null) {
        return .{ .file_bucket = .{ .file_idx = file_idx, .reason = .outdated } };
    }

    const anchor_line = thread.line.?;
    const resolved = switch (thread.side) {
        .right => resolveLine(files, file_idx, anchor_line, false),
        .left => resolveLine(files, file_idx, anchor_line, true),
    };

    if (resolved) |coord| {
        return .{ .inline_line = .{
            .file_idx = coord.file_idx,
            .hunk_idx = coord.hunk_idx,
            .line_idx = coord.line_idx,
        } };
    }

    // Line exists in the file but falls outside the -U10 context window.
    return .{ .file_bucket = .{ .file_idx = file_idx, .reason = .out_of_context } };
}

/// Match a diff file by path — new_path first (post-rename name GitHub reports),
/// old_path as the fallback for threads created against the pre-rename path.
fn findFile(files: []const parser.FileDiff, path: []const u8) ?usize {
    if (path.len == 0) return null;
    for (files, 0..) |file, idx| {
        if (file.new_path.len > 0 and std.mem.eql(u8, file.new_path, path)) return idx;
    }
    for (files, 0..) |file, idx| {
        if (file.old_path.len > 0 and std.mem.eql(u8, file.old_path, path)) return idx;
    }
    return null;
}

const Coord = struct { file_idx: usize, hunk_idx: usize, line_idx: usize };

/// Find the diff coordinate of `line_number` within a known file. `use_old`
/// selects `old_lineno` (LEFT side) vs `new_lineno` (RIGHT side). Mirrors
/// `mcp/line_resolver.zig` but returns only the positional coordinate.
fn resolveLine(files: []const parser.FileDiff, file_idx: usize, line_number: u32, use_old: bool) ?Coord {
    const file = &files[file_idx];
    for (file.hunks, 0..) |hunk, hunk_idx| {
        for (hunk.lines, 0..) |line, line_idx| {
            const target = if (use_old) line.old_lineno else line.new_lineno;
            if (target) |lineno| {
                if (lineno == line_number) {
                    return .{ .file_idx = file_idx, .hunk_idx = hunk_idx, .line_idx = line_idx };
                }
            }
        }
    }
    return null;
}
