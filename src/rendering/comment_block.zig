//! App-free row planning for a local review comment rendered as a multi-row
//! block, plus the matching pure height calculation. Modelled on
//! `thread_block.zig` and for the same reason: the unified renderer, the
//! side-by-side renderer, and navigation's scroll math all need to agree on how
//! tall a comment block is. They agree because all three walk `planRows`, so a
//! block's rendered height always equals what navigation reserves for it.
//!
//! This module decides layout only. Callers own the gutter, the column offset,
//! and the mapping from `Role` to a concrete `vaxis.Style`, because those differ
//! between the unified and side-by-side views.

const std = @import("std");
const comments = @import("../comments/store.zig");
const common = @import("common.zig");
const width_util = @import("width.zig");

const Allocator = std.mem.Allocator;

/// What a span means, so each view can map it onto its own focused/unfocused
/// style pair without this module knowing about `vaxis`.
pub const Role = enum {
    border,
    label,
    text,
    hint,
    background,
    reply_author,
};

pub const Span = struct {
    text: []const u8,
    role: Role,
};

pub const PlannedRow = struct {
    spans: []const Span,
};

pub const CommentRenderInfo = struct {
    comment: *const comments.Comment,
    expanded: bool,
    /// Drives the key-hint suffix on the label row; hints are only drawn for the
    /// block under the cursor.
    is_cursor: bool = false,
    /// True while a reply editor is drawn directly beneath this block. The block
    /// then drops its trailing spacer, because the editor opens with one of its
    /// own and two blank rows read as a gap between two unrelated boxes rather
    /// than one continuing thread.
    editor_below: bool = false,
};

/// Rows the block occupies at `width`. Matches `planRows` exactly (it walks it).
/// Uses a scratch arena on `allocator`.
pub fn commentBlockHeight(allocator: Allocator, info: CommentRenderInfo, width: usize) usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const rows = planRows(arena.allocator(), info, width) catch return 3;
    return rows.len;
}

/// Plan every row of the block at `width` (the full block width including the
/// `┃` border column). Text is allocated from `arena` and borrowed by the spans,
/// so the arena must outlive the caller's draw pass.
pub fn planRows(arena: Allocator, info: CommentRenderInfo, width: usize) ![]PlannedRow {
    var rows: std.ArrayList(PlannedRow) = .empty;

    const comment = info.comment;
    const reply_count = comment.replies.items.len;

    try rows.append(arena, try spacerRow(arena, width));
    try rows.append(arena, try labelRow(arena, info, width));

    // Root comment body. Collapsed blocks cap the body at `max_comment_lines`
    // and trade the remainder for a "... N more lines" hint.
    const body_width = width -| root_body_indent;
    const body = try wrapAll(arena, comment.text, body_width);
    const visible_body = if (info.expanded) body.len else @min(body.len, common.Layout.max_comment_lines);

    for (body[0..visible_body], 0..) |line, idx| {
        const prefix = if (idx == 0) " > " else "   ";
        try rows.append(arena, try textRow(arena, .{
            .prefix = prefix,
            .text = line,
            .role = .text,
            .width = width,
        }));
    }

    if (visible_body < body.len) {
        const remaining = body.len - visible_body;
        const more = try std.fmt.allocPrint(arena, "... {d} more line{s} (press o to expand)", .{
            remaining,
            if (remaining == 1) "" else "s",
        });
        try rows.append(arena, try textRow(arena, .{
            .prefix = "   ",
            .text = more,
            .role = .hint,
            .width = width,
        }));
    }

    // Replies. Collapsed, the thread shrinks to a one-line count so the reader
    // can see a conversation exists without paying its height.
    if (reply_count > 0) {
        if (info.expanded) {
            for (comment.replies.items) |reply| {
                try rows.append(arena, try spacerRow(arena, width));
                try rows.append(arena, try textRow(arena, .{
                    .prefix = reply_marker,
                    .text = reply.author,
                    .role = .reply_author,
                    .width = width,
                }));

                const reply_body = try wrapAll(arena, reply.text, width -| reply_body_indent);
                for (reply_body) |line| {
                    try rows.append(arena, try textRow(arena, .{
                        .prefix = "     ",
                        .text = line,
                        .role = .text,
                        .width = width,
                    }));
                }
            }
        } else {
            // Says how to open itself: a reader who is not on the block sees no
            // key hints, so an unexplained "2 replies" is a dead end.
            const summary = try std.fmt.allocPrint(arena, "{s} {d} repl{s} (press o to expand)", .{
                collapsed_marker,
                reply_count,
                if (reply_count == 1) "y" else "ies",
            });
            try rows.append(arena, try textRow(arena, .{
                .prefix = "   ",
                .text = summary,
                .role = .reply_author,
                .width = width,
            }));
        }
    }

    if (!info.editor_below) try rows.append(arena, try spacerRow(arena, width));
    return rows.toOwnedSlice(arena);
}

/// The key hints shown on the label row of the focused block.
pub fn keyHints(buf: []u8, expanded: bool) []const u8 {
    const expand_hint = if (expanded) "o:Collapse" else "o:Expand";
    return std.fmt.bufPrint(buf, "Enter:Edit  r:Reply  d:Delete  {s}", .{expand_hint}) catch
        "Enter:Edit  r:Reply  d:Delete";
}

// =============================================================================
// Row construction
// =============================================================================

/// Columns consumed left of the root body text: `┃` + `" > "`.
const root_body_indent = 4;
/// Columns consumed left of a reply's body text: `┃` + five spaces.
const reply_body_indent = 6;
const reply_marker = "   ↳ ";
const collapsed_marker = "▸";
const border = "┃";

fn spacerRow(arena: Allocator, width: usize) !PlannedRow {
    const spans = try arena.alloc(Span, 2);
    spans[0] = .{ .text = border, .role = .border };
    spans[1] = .{ .text = try blanks(arena, width -| 1), .role = .background };
    return .{ .spans = spans };
}

/// `┃ Comment · author              Enter:Edit  r:Reply  d:Delete  o:Expand`
///
/// The author suffix is omitted for a plain single-author note, where naming the
/// only participant is noise; it appears once a thread has more than one voice.
fn labelRow(arena: Allocator, info: CommentRenderInfo, width: usize) !PlannedRow {
    const comment = info.comment;
    const has_replies = comment.replies.items.len > 0;
    const show_author = has_replies or !std.mem.eql(u8, comment.author, comments.local_author);

    const label = if (show_author)
        try std.fmt.allocPrint(arena, " Comment · {s}", .{comment.author})
    else
        try arena.dupe(u8, " Comment");

    var spans: std.ArrayList(Span) = .empty;
    try spans.append(arena, .{ .text = border, .role = .border });
    try spans.append(arena, .{ .text = label, .role = .label });

    const used = 1 + width_util.displayWidth(label);

    if (info.is_cursor) {
        var hints_buf: [96]u8 = undefined;
        const hints = keyHints(&hints_buf, info.expanded);
        const hints_width = width_util.displayWidth(hints);

        // Only offer the hints when they fit with a gap; a clipped hint row reads
        // as corruption rather than help.
        if (width > used + hints_width + hint_gap) {
            try spans.append(arena, .{ .text = try blanks(arena, width - used - hints_width), .role = .background });
            try spans.append(arena, .{ .text = try arena.dupe(u8, hints), .role = .hint });
            return .{ .spans = try spans.toOwnedSlice(arena) };
        }
    }

    try spans.append(arena, .{ .text = try blanks(arena, width -| used), .role = .background });
    return .{ .spans = try spans.toOwnedSlice(arena) };
}

const hint_gap = 2;

fn textRow(arena: Allocator, params: struct {
    prefix: []const u8,
    text: []const u8,
    role: Role,
    width: usize,
}) !PlannedRow {
    const spans = try arena.alloc(Span, 3);
    spans[0] = .{ .text = border, .role = .border };
    spans[1] = .{ .text = params.prefix, .role = if (params.role == .hint) .hint else .text };

    const content_width = params.width -| (1 + width_util.displayWidth(params.prefix));
    spans[2] = .{ .text = try padTo(arena, params.text, content_width), .role = params.role };
    return .{ .spans = spans };
}

// =============================================================================
// Text helpers
// =============================================================================

/// Wrap every newline-separated line of `text` at `max_width`, flattened into a
/// single list of display rows. An empty text still occupies one row, matching
/// what the renderers draw.
fn wrapAll(arena: Allocator, text: []const u8, max_width: usize) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;

    var line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |line| {
        var wrapped = try width_util.wrapText(arena, line, max_width);
        defer wrapped.deinit(arena);
        if (wrapped.items.len == 0) {
            try out.append(arena, "");
            continue;
        }
        for (wrapped.items) |segment| try out.append(arena, segment);
    }

    return out.toOwnedSlice(arena);
}

/// Clip `text` to `width` display columns and pad the remainder with spaces, so
/// every row paints its full background.
fn padTo(arena: Allocator, text: []const u8, width: usize) ![]const u8 {
    const visible = width_util.sliceByDisplayWidth(text, width);
    const visible_width = width_util.displayWidth(visible);

    const buf = try arena.alloc(u8, visible.len + (width -| visible_width));
    @memcpy(buf[0..visible.len], visible);
    @memset(buf[visible.len..], ' ');
    return buf;
}

fn blanks(arena: Allocator, count: usize) ![]const u8 {
    const buf = try arena.alloc(u8, count);
    @memset(buf, ' ');
    return buf;
}
