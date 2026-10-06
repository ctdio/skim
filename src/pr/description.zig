//! Line-oriented formatting of a PR description (GitHub markdown) for the
//! description block above the diff. Pure: no vaxis, no tree-sitter.
//!
//! `layout` runs once per fetched body and turns it into display lines: block
//! syntax (headings, list markers, task boxes, quotes, code fences, rules) is
//! resolved into a `Kind`, and the markup that only makes sense on GitHub (HTML
//! comments from PR templates, bare HTML tag lines, fence lines) is dropped.
//! Each output line becomes one LineMap record, so a long description scrolls
//! line by line. `inlineSpans` resolves the inline markup of one line's text at
//! render time.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Kind = enum { text, heading, bullet, ordered, task, quote, code, rule, blank };

pub const Line = struct {
    kind: Kind,
    /// Content after the block marker. For `.code`, the raw line.
    text: []const u8,
    /// List nesting depth (two leading spaces per level).
    depth: u8 = 0,
    /// Heading level 1-6 for `.heading`.
    level: u8 = 0,
    /// The ordinal marker (`1.`, `2)`) for `.ordered`.
    marker: []const u8 = "",
    /// For `.task`.
    checked: bool = false,
};

pub const Role = enum { plain, bold, italic, strike, code, link };

pub const Span = struct {
    text: []const u8,
    role: Role,
};

/// Display lines for `body`. Strings borrow from `body` except where a line
/// had an HTML comment cut out of it (those are allocated on `allocator`).
/// Runs of blank lines collapse to one; leading and trailing blanks are
/// dropped. An empty or markup-only body yields no lines.
pub fn layout(allocator: Allocator, body: []const u8) ![]Line {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(allocator);

    var in_comment = false;
    var fence: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw_line| {
        const raw = std.mem.trimEnd(u8, raw_line, "\r");

        if (fence) |marker| {
            if (std.mem.startsWith(u8, std.mem.trimStart(u8, raw, " "), marker)) {
                fence = null;
                continue;
            }
            try lines.append(allocator, .{ .kind = .code, .text = try expandTabs(allocator, raw) });
            continue;
        }

        const line = try stripComments(allocator, .{ .line = raw, .in_comment = &in_comment });
        const removed_comment = line.len != raw.len;
        const trimmed = std.mem.trim(u8, line, " \t");

        if (fenceMarker(trimmed)) |marker| {
            fence = marker;
            continue;
        }
        if (trimmed.len == 0) {
            // A line that held only a comment vanishes instead of leaving a gap.
            if (!removed_comment) try appendBlank(allocator, &lines);
            continue;
        }
        if (isHtmlTagLine(trimmed)) continue;

        try lines.append(allocator, classify(line));
    }

    while (lines.items.len > 0 and lines.items[lines.items.len - 1].kind == .blank) _ = lines.pop();
    return lines.toOwnedSlice(allocator);
}

/// Resolve inline markup in `text`: `code`, **bold** / __bold__, *italic*,
/// ~~strike~~, [links](url) and ![images](url). Markers are dropped and link
/// targets hidden. `_` is never read as italic, so snake_case identifiers
/// survive. Unclosed markers stay as literal text.
pub fn inlineSpans(allocator: Allocator, text: []const u8) ![]Span {
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(allocator);

    var plain_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const match = matchInline(text, i) orelse {
            i += 1;
            continue;
        };
        if (i > plain_start) try spans.append(allocator, .{ .text = text[plain_start..i], .role = .plain });
        if (match.prefix.len > 0) try spans.append(allocator, .{ .text = match.prefix, .role = .link });
        if (match.inner.len > 0) try spans.append(allocator, .{ .text = match.inner, .role = match.role });
        i = match.end;
        plain_start = i;
    }
    if (plain_start < text.len) try spans.append(allocator, .{ .text = text[plain_start..], .role = .plain });
    return spans.toOwnedSlice(allocator);
}

const InlineMatch = struct {
    role: Role,
    inner: []const u8,
    /// Text shown before `inner` in the same role (the image label).
    prefix: []const u8 = "",
    end: usize,
};

fn matchInline(text: []const u8, i: usize) ?InlineMatch {
    const rest = text[i..];
    if (rest[0] == '`') return delimited(text, .{ .at = i, .open = "`", .role = .code });
    if (std.mem.startsWith(u8, rest, "**")) return delimited(text, .{ .at = i, .open = "**", .role = .bold });
    if (std.mem.startsWith(u8, rest, "__")) return delimited(text, .{ .at = i, .open = "__", .role = .bold });
    if (std.mem.startsWith(u8, rest, "~~")) return delimited(text, .{ .at = i, .open = "~~", .role = .strike });
    if (rest[0] == '*' and rest.len > 1 and rest[1] != ' ') return delimited(text, .{ .at = i, .open = "*", .role = .italic });
    if (std.mem.startsWith(u8, rest, "![")) {
        var m = link(text, i + 1) orelse return null;
        m.prefix = "image: ";
        return m;
    }
    if (rest[0] == '[') return link(text, i);
    return null;
}

fn delimited(text: []const u8, params: struct { at: usize, open: []const u8, role: Role }) ?InlineMatch {
    const start = params.at + params.open.len;
    if (start >= text.len) return null;
    const close = std.mem.indexOfPos(u8, text, start, params.open) orelse return null;
    if (close == start) return null;
    return .{ .role = params.role, .inner = text[start..close], .end = close + params.open.len };
}

/// `[label](target)` starting at the `[` at `at`.
fn link(text: []const u8, at: usize) ?InlineMatch {
    const label_end = std.mem.indexOfScalarPos(u8, text, at + 1, ']') orelse return null;
    if (label_end + 1 >= text.len or text[label_end + 1] != '(') return null;
    const target_end = std.mem.indexOfScalarPos(u8, text, label_end + 2, ')') orelse return null;
    return .{ .role = .link, .inner = text[at + 1 .. label_end], .end = target_end + 1 };
}

fn classify(line: []const u8) Line {
    const indent = leadingSpaces(line);
    const depth: u8 = @intCast(@min(indent / 2, 8));
    const content = std.mem.trimStart(u8, line, " \t");

    if (headingLevel(content)) |level| {
        const after = std.mem.trimStart(u8, content[level..], " ");
        return .{ .kind = .heading, .level = @intCast(level), .text = std.mem.trimEnd(u8, after, " #") };
    }
    if (isRule(content)) return .{ .kind = .rule, .text = "" };
    if (content[0] == '>') {
        return .{ .kind = .quote, .text = std.mem.trimStart(u8, content[1..], " ") };
    }
    if (content.len >= 2 and (content[0] == '-' or content[0] == '*' or content[0] == '+') and content[1] == ' ') {
        const item = std.mem.trimStart(u8, content[2..], " ");
        if (item.len >= 3 and item[0] == '[' and item[2] == ']' and (item.len == 3 or item[3] == ' ')) {
            const mark = item[1];
            if (mark == ' ' or mark == 'x' or mark == 'X') {
                return .{ .kind = .task, .depth = depth, .checked = mark != ' ', .text = std.mem.trimStart(u8, item[3..], " ") };
            }
        }
        return .{ .kind = .bullet, .depth = depth, .text = item };
    }
    if (orderedMarkerLen(content)) |len| {
        return .{ .kind = .ordered, .depth = depth, .marker = content[0..len], .text = std.mem.trimStart(u8, content[len..], " ") };
    }
    return .{ .kind = .text, .text = std.mem.trim(u8, line, " \t") };
}

fn appendBlank(allocator: Allocator, lines: *std.ArrayList(Line)) !void {
    if (lines.items.len == 0) return;
    if (lines.items[lines.items.len - 1].kind == .blank) return;
    try lines.append(allocator, .{ .kind = .blank, .text = "" });
}

/// Remove `<!-- ... -->` from `line`, carrying an unclosed comment into the
/// next line through `in_comment`. Returns `line` itself when nothing was cut.
fn stripComments(allocator: Allocator, params: struct { line: []const u8, in_comment: *bool }) ![]const u8 {
    const line = params.line;
    if (!params.in_comment.* and std.mem.indexOf(u8, line, "<!--") == null) return line;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < line.len) {
        if (params.in_comment.*) {
            const close = std.mem.indexOfPos(u8, line, i, "-->") orelse return out.toOwnedSlice(allocator);
            params.in_comment.* = false;
            i = close + 3;
            continue;
        }
        const open = std.mem.indexOfPos(u8, line, i, "<!--") orelse {
            try out.appendSlice(allocator, line[i..]);
            break;
        };
        try out.appendSlice(allocator, line[i..open]);
        params.in_comment.* = true;
        i = open + 4;
    }
    return out.toOwnedSlice(allocator);
}

/// The fence string (``` or ~~~) a line opens, or null.
fn fenceMarker(trimmed: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, trimmed, "```")) return "```";
    if (std.mem.startsWith(u8, trimmed, "~~~")) return "~~~";
    return null;
}

/// A line that is nothing but HTML tags (`<details>`, `</summary>`, `<br>`),
/// which a terminal cannot render.
fn isHtmlTagLine(trimmed: []const u8) bool {
    if (trimmed[0] != '<' or trimmed[trimmed.len - 1] != '>') return false;
    var depth: usize = 0;
    for (trimmed) |c| {
        switch (c) {
            '<' => depth += 1,
            '>' => depth -|= 1,
            else => if (depth == 0 and c != ' ') return false,
        }
    }
    return true;
}

fn headingLevel(content: []const u8) ?usize {
    var level: usize = 0;
    while (level < content.len and content[level] == '#') level += 1;
    if (level == 0 or level > 6) return null;
    if (level < content.len and content[level] != ' ') return null;
    return level;
}

fn isRule(content: []const u8) bool {
    const c = content[0];
    if (c != '-' and c != '*' and c != '_') return false;
    var count: usize = 0;
    for (content) |ch| {
        if (ch == c) {
            count += 1;
        } else if (ch != ' ') return false;
    }
    return count >= 3;
}

fn orderedMarkerLen(content: []const u8) ?usize {
    var digits: usize = 0;
    while (digits < content.len and digits < 9 and std.ascii.isDigit(content[digits])) digits += 1;
    if (digits == 0 or digits + 1 >= content.len) return null;
    const punct = content[digits];
    if ((punct != '.' and punct != ')') or content[digits + 1] != ' ') return null;
    return digits + 1;
}

fn leadingSpaces(line: []const u8) usize {
    var n: usize = 0;
    for (line) |c| {
        switch (c) {
            ' ' => n += 1,
            '\t' => n += 4,
            else => break,
        }
    }
    return n;
}

/// Code keeps its indentation, but the cell grid has no tab stops: a tab
/// becomes four spaces.
fn expandTabs(allocator: Allocator, line: []const u8) ![]const u8 {
    const tabs = std.mem.count(u8, line, "\t");
    if (tabs == 0) return line;
    const out = try allocator.alloc(u8, line.len + tabs * 3);
    _ = std.mem.replace(u8, line, "\t", "    ", out);
    return out;
}

const testing = std.testing;

fn expectLines(body: []const u8, expected: []const Line) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lines = try layout(arena.allocator(), body);
    try testing.expectEqualDeep(expected, lines);
}

test "layout classifies block syntax" {
    try expectLines(
        \\## Why
        \\Plain text
        \\- item
        \\  * nested
        \\- [ ] todo
        \\- [x] done
        \\3. third
        \\> quoted
        \\---
    , &.{
        .{ .kind = .heading, .level = 2, .text = "Why" },
        .{ .kind = .text, .text = "Plain text" },
        .{ .kind = .bullet, .text = "item" },
        .{ .kind = .bullet, .depth = 1, .text = "nested" },
        .{ .kind = .task, .text = "todo" },
        .{ .kind = .task, .checked = true, .text = "done" },
        .{ .kind = .ordered, .marker = "3.", .text = "third" },
        .{ .kind = .quote, .text = "quoted" },
        .{ .kind = .rule, .text = "" },
    });
}

test "layout keeps fenced code verbatim and drops the fences" {
    try expectLines("```zig\n  const x = 1; // **not bold**\n\tindented\n```\nafter", &.{
        .{ .kind = .code, .text = "  const x = 1; // **not bold**" },
        .{ .kind = .code, .text = "    indented" },
        .{ .kind = .text, .text = "after" },
    });
}

test "layout strips template comments and html-only lines" {
    try expectLines("<!-- Describe your change -->\r\nFixes the bug<!-- inline -->\r\n<details>\r\n<!--\r\nmulti\r\nline -->\r\n", &.{
        .{ .kind = .text, .text = "Fixes the bug" },
    });
}

test "layout collapses blank runs and trims leading and trailing blanks" {
    try expectLines("\n\none\n\n\n\ntwo\n\n", &.{
        .{ .kind = .text, .text = "one" },
        .{ .kind = .blank, .text = "" },
        .{ .kind = .text, .text = "two" },
    });
}

test "layout of an empty body has no lines" {
    try expectLines("  \r\n<!-- template only -->\r\n", &.{});
}

test "inlineSpans resolves code, emphasis, and links" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const spans = try inlineSpans(arena.allocator(), "Use `foo_bar` for **speed**, see [docs](http://x) or *this* ~~old~~");
    try testing.expectEqualDeep(&[_]Span{
        .{ .text = "Use ", .role = .plain },
        .{ .text = "foo_bar", .role = .code },
        .{ .text = " for ", .role = .plain },
        .{ .text = "speed", .role = .bold },
        .{ .text = ", see ", .role = .plain },
        .{ .text = "docs", .role = .link },
        .{ .text = " or ", .role = .plain },
        .{ .text = "this", .role = .italic },
        .{ .text = " ", .role = .plain },
        .{ .text = "old", .role = .strike },
    }, spans);
}

test "inlineSpans labels images and leaves snake_case and unclosed markers alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const spans = try inlineSpans(arena.allocator(), "![screenshot](u) my_var * 2 **open");
    try testing.expectEqualDeep(&[_]Span{
        .{ .text = "image: ", .role = .link },
        .{ .text = "screenshot", .role = .link },
        .{ .text = " my_var * 2 **open", .role = .plain },
    }, spans);
}
