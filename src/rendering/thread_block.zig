//! App-free renderer for a GitHub review thread as a multi-row block, plus the
//! matching pure height calculation. Kept out of `utils.zig` (which is coupled
//! to `App`'s frame bump-buffer) so it can be snapshot-tested against a bare
//! vaxis window and so the height/row math is a single shared source of truth:
//! `renderThreadDisplay` and `threadDisplayHeight` both walk `planRows`, so a
//! block's rendered height always equals what navigation reserves for it
//! (unlike the estimated comment-height path, this cannot drift).
//!
//! AD-6 does not apply here — side was already resolved at the anchoring
//! boundary; this module only draws what it is handed.

const std = @import("std");
const vaxis = @import("vaxis");
const cells = @import("cells.zig");
const common = @import("common.zig");
const width_util = @import("width.zig");
const review_parse = @import("../pr/review_parse.zig");
const thread_placement = @import("../pr/thread_placement.zig");

const Allocator = std.mem.Allocator;
const Color = common.Color;

pub const ThreadRenderInfo = struct {
    thread: *const review_parse.ReviewThread,
    is_bucketed: bool,
    bucket_reason: ?thread_placement.BucketReason = null,
    expanded: bool,
    is_cursor: bool = false,
    /// True while this thread is an optimistic placeholder whose draft post is
    /// still in flight — the block carries a `[POSTING…]` badge.
    posting: bool = false,
    /// True while a thread interaction (reply/resolve/edit/delete) is in flight
    /// against this thread — the block carries a `[…]` working badge.
    busy: bool = false,
    /// The anchored code line's content, rendered as the `−` row of a suggestion
    /// on an inline thread. Null for bucketed threads (no target line to show).
    target_line_content: ?[]const u8 = null,
};

const RowKind = enum {
    collapsed,
    header,
    body,
    reply_author,
    sugg_open,
    sugg_del,
    sugg_add,
    sugg_close,
    bottom,
};

const PlannedRow = struct {
    kind: RowKind,
    /// Content text (already normalized, borrowed from the arena). The left
    /// glyph/prefix is supplied per-kind at draw time.
    text: []const u8,
};

/// Render the thread block starting at `start_row`, returning the number of rows
/// drawn. Text is allocated from `frame_allocator` (must outlive the `win.print`
/// calls — the caller's per-frame arena).
pub fn renderThreadDisplay(
    win: vaxis.Window,
    info: ThreadRenderInfo,
    start_row: usize,
    width: usize,
    frame_allocator: Allocator,
) usize {
    const rows = planRows(frame_allocator, info, width) catch return 0;

    var drawn: usize = 0;
    for (rows) |r| {
        const row_offset = start_row + drawn;
        if (row_offset >= win.height) break;
        drawRow(win, r, row_offset, info.is_cursor, frame_allocator) catch break;
        drawn += 1;
    }
    return drawn;
}

/// Rows the block occupies at `width`. Matches `renderThreadDisplay`'s output
/// exactly (both consume `planRows`). Uses a scratch arena on `allocator`.
pub fn threadDisplayHeight(allocator: Allocator, info: ThreadRenderInfo, width: usize) usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const rows = planRows(arena.allocator(), info, width) catch return 1;
    return rows.len;
}

// =============================================================================
// Row planning (the single source of truth for layout)
// =============================================================================

const min_content_width = 12;

fn planRows(arena: Allocator, info: ThreadRenderInfo, width: usize) ![]PlannedRow {
    var rows: std.ArrayList(PlannedRow) = .empty;

    const thread = info.thread;
    const comments = thread.comments;

    // Collapsed: a single summary row.
    if (!info.expanded) {
        const summary = try collapsedSummary(arena, info);
        try rows.append(arena, .{ .kind = .collapsed, .text = summary });
        return rows.toOwnedSlice(arena);
    }

    // The content column left of the sidebar glyph + a space.
    const text_width = if (width > 4) width - 4 else min_content_width;

    // Header row: first author + date + badges.
    const first_author = if (comments.len > 0) comments[0].author else "(no comments)";
    const first_date = if (comments.len > 0) datePart(comments[0].created_at) else "";
    const first_draft = comments.len > 0 and comments[0].review_state == .pending;
    const header = try formatByline(arena, .{
        .author = first_author,
        .date = first_date,
        .badges = try badges(arena, info, first_draft),
    });
    try rows.append(arena, .{ .kind = .header, .text = header });

    // Comment bodies (comment 0 under the header; replies get their own byline).
    for (comments, 0..) |comment, i| {
        if (i > 0) {
            const reply_draft = comment.review_state == .pending;
            const byline = try formatByline(arena, .{
                .author = comment.author,
                .date = datePart(comment.created_at),
                .badges = if (reply_draft) "[DRAFT]" else "",
            });
            try rows.append(arena, .{ .kind = .reply_author, .text = byline });
        }

        try planBody(arena, &rows, info, comment.body, text_width);
    }

    try rows.append(arena, .{ .kind = .bottom, .text = "" });
    return rows.toOwnedSlice(arena);
}

/// Split a body into plain text (wrapped) and a `suggestion` mini-diff, emitting
/// rows for each. CRLF is normalized here (bodies arrive `\r\n` from GitHub).
fn planBody(arena: Allocator, rows: *std.ArrayList(PlannedRow), info: ThreadRenderInfo, raw_body: []const u8, text_width: usize) !void {
    const body = try normalizeNewlines(arena, raw_body);
    const parts = splitSuggestion(body);

    try planWrappedText(arena, rows, parts.before, text_width);

    if (parts.suggestion) |sugg| {
        try rows.append(arena, .{ .kind = .sugg_open, .text = "suggestion" });
        if (!info.is_bucketed) {
            if (info.target_line_content) |target| {
                try rows.append(arena, .{ .kind = .sugg_del, .text = width_util.sliceByDisplayWidth(target, text_width) });
            }
        }
        var it = std.mem.splitScalar(u8, sugg, '\n');
        while (it.next()) |line| {
            try rows.append(arena, .{ .kind = .sugg_add, .text = width_util.sliceByDisplayWidth(line, text_width) });
        }
        try rows.append(arena, .{ .kind = .sugg_close, .text = "" });
    }

    try planWrappedText(arena, rows, parts.after, text_width);
}

fn planWrappedText(arena: Allocator, rows: *std.ArrayList(PlannedRow), text: []const u8, text_width: usize) !void {
    if (text.len == 0) return;
    var line_it = std.mem.splitScalar(u8, text, '\n');
    while (line_it.next()) |line| {
        const wrapped = try width_util.wrapText(arena, line, text_width);
        for (wrapped.items) |seg| {
            try rows.append(arena, .{ .kind = .body, .text = seg });
        }
    }
}

// =============================================================================
// Drawing
// =============================================================================

fn drawRow(win: vaxis.Window, row: PlannedRow, row_offset: usize, is_cursor: bool, frame_allocator: Allocator) !void {
    const accent: vaxis.Style = if (is_cursor)
        .{ .fg = Color.yellow, .bold = true }
    else
        .{ .fg = Color.cyan, .bold = true };
    const text_style: vaxis.Style = if (is_cursor)
        .{ .fg = Color.bright_white }
    else
        .{ .fg = Color.white };
    const dim_style: vaxis.Style = .{ .fg = Color.dim_gray };

    var segs: std.ArrayList(vaxis.Cell.Segment) = .empty;

    switch (row.kind) {
        .collapsed => {
            try segs.append(frame_allocator, .{ .text = "▸ ", .style = accent });
            try segs.append(frame_allocator, .{ .text = row.text, .style = dim_style });
        },
        .header => {
            try segs.append(frame_allocator, .{ .text = "┌ ● ", .style = accent });
            try segs.append(frame_allocator, .{ .text = row.text, .style = accent });
        },
        .body => {
            try segs.append(frame_allocator, .{ .text = "│ ", .style = accent });
            try segs.append(frame_allocator, .{ .text = row.text, .style = text_style });
        },
        .reply_author => {
            try segs.append(frame_allocator, .{ .text = "│ ↳ ", .style = accent });
            try segs.append(frame_allocator, .{ .text = row.text, .style = accent });
        },
        .sugg_open => {
            try segs.append(frame_allocator, .{ .text = "│ ┌ ", .style = accent });
            try segs.append(frame_allocator, .{ .text = row.text, .style = dim_style });
        },
        .sugg_del => {
            try segs.append(frame_allocator, .{ .text = "│ ", .style = accent });
            try segs.append(frame_allocator, .{ .text = "- ", .style = .{ .fg = Color.diff_sign_delete } });
            try segs.append(frame_allocator, .{ .text = row.text, .style = .{ .fg = Color.diff_sign_delete } });
        },
        .sugg_add => {
            try segs.append(frame_allocator, .{ .text = "│ ", .style = accent });
            try segs.append(frame_allocator, .{ .text = "+ ", .style = .{ .fg = Color.diff_sign_add } });
            try segs.append(frame_allocator, .{ .text = row.text, .style = .{ .fg = Color.diff_sign_add } });
        },
        .sugg_close => {
            try segs.append(frame_allocator, .{ .text = "│ └", .style = accent });
        },
        .bottom => {
            try segs.append(frame_allocator, .{ .text = "└─", .style = accent });
        },
    }

    _ = cells.print(win, segs.items, .{ .row_offset = @intCast(row_offset), .col_offset = 0, .wrap = .none });
}

// =============================================================================
// Formatting helpers
// =============================================================================

fn collapsedSummary(arena: Allocator, info: ThreadRenderInfo) ![]const u8 {
    const comments = info.thread.comments;
    const n = comments.len;
    const author = if (n > 0) comments[0].author else "(no comments)";
    const badge_text = try badges(arena, info, false);
    return std.fmt.allocPrint(arena, "{d} comment{s} · {s}{s}  (o to expand)", .{
        n,
        if (n == 1) "" else "s",
        author,
        badge_text,
    });
}

const BylineParts = struct { author: []const u8, date: []const u8, badges: []const u8 };

fn formatByline(arena: Allocator, parts: BylineParts) ![]const u8 {
    if (parts.date.len == 0) {
        return std.fmt.allocPrint(arena, "{s}{s}", .{ parts.author, parts.badges });
    }
    return std.fmt.allocPrint(arena, "{s} · {s}{s}", .{ parts.author, parts.date, parts.badges });
}

/// Space-prefixed badge string (e.g. " [RESOLVED] [OUTDATED]"). Empty if none.
fn badges(arena: Allocator, info: ThreadRenderInfo, draft: bool) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    if (info.thread.is_resolved) try buf.appendSlice(arena, " [RESOLVED]");
    if (info.bucket_reason) |reason| {
        switch (reason) {
            .outdated => try buf.appendSlice(arena, " [OUTDATED]"),
            .out_of_context => try buf.appendSlice(arena, " [OUT OF CONTEXT]"),
            .file_level => try buf.appendSlice(arena, " [FILE]"),
        }
    } else if (info.thread.is_outdated) {
        try buf.appendSlice(arena, " [OUTDATED]");
    }
    if (info.posting) try buf.appendSlice(arena, " [POSTING…]");
    if (info.busy) try buf.appendSlice(arena, " […]");
    if (draft) try buf.appendSlice(arena, " [DRAFT]");
    return buf.toOwnedSlice(arena);
}

const SuggestionParts = struct {
    before: []const u8,
    suggestion: ?[]const u8,
    after: []const u8,
};

/// Extract the first ```suggestion fenced block. Returns the text before/after
/// and the fence's inner content (no trailing newline). No fence → all `before`.
fn splitSuggestion(body: []const u8) SuggestionParts {
    const open = findFenceOpen(body) orelse return .{ .before = body, .suggestion = null, .after = "" };
    const content_start = open.content_start;
    // Find the closing fence line (a line that is exactly "```" after trim).
    var idx = content_start;
    var line_start = content_start;
    while (idx <= body.len) : (idx += 1) {
        const at_end = idx == body.len;
        if (at_end or body[idx] == '\n') {
            const line = std.mem.trimEnd(u8, body[line_start..idx], " \t\r");
            if (std.mem.eql(u8, line, "```")) {
                const suggestion = trimTrailingNewline(body[content_start..line_start]);
                const after_start = @min(idx + 1, body.len);
                return .{
                    .before = trimTrailingNewline(body[0..open.fence_start]),
                    .suggestion = suggestion,
                    .after = body[after_start..],
                };
            }
            line_start = idx + 1;
        }
    }
    // Unterminated fence → treat the rest as suggestion content.
    return .{
        .before = trimTrailingNewline(body[0..open.fence_start]),
        .suggestion = trimTrailingNewline(body[content_start..]),
        .after = "",
    };
}

const FenceOpen = struct { fence_start: usize, content_start: usize };

fn findFenceOpen(body: []const u8) ?FenceOpen {
    var idx: usize = 0;
    var line_start: usize = 0;
    while (idx <= body.len) : (idx += 1) {
        const at_end = idx == body.len;
        if (at_end or body[idx] == '\n') {
            const line = std.mem.trimEnd(u8, body[line_start..idx], " \t\r");
            const info_str = std.mem.trimStart(u8, line, " \t");
            if (std.mem.eql(u8, info_str, "```suggestion")) {
                return .{ .fence_start = line_start, .content_start = @min(idx + 1, body.len) };
            }
            line_start = idx + 1;
        }
    }
    return null;
}

fn trimTrailingNewline(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\n");
}

fn datePart(created_at: []const u8) []const u8 {
    // ISO-8601 timestamps start with YYYY-MM-DD. Show just the date for a stable,
    // clock-independent byline (relative "2d ago" would break snapshot tests).
    if (created_at.len >= 10) return created_at[0..10];
    return created_at;
}

fn normalizeNewlines(arena: Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\r') == null) return s;
    var out = try arena.alloc(u8, s.len);
    var n: usize = 0;
    for (s) |c| {
        if (c == '\r') continue;
        out[n] = c;
        n += 1;
    }
    return out[0..n];
}
