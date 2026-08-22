const std = @import("std");
const vaxis = @import("vaxis");

const DisplayWidth = vaxis.DisplayWidth;

// vaxis (zg-based) measures grapheme width against a DisplayWidth instance built
// from the Unicode tables. We own a single instance loaded lazily on first use
// and kept for the process lifetime, so width queries work uniformly across the
// TUI, headless, and test paths without threading the instance through every
// render helper. Access is single-threaded (the render loop), so the lazy init
// needs no synchronization.
var width_data: ?DisplayWidth = null;
var load_failed: bool = false;

/// Display width of a UTF-8 string in terminal cells, accounting for wide
/// characters (CJK, emoji). Falls back to a codepoint count if the Unicode
/// tables cannot be loaded.
pub fn gwidth(str: []const u8) u16 {
    const data = ensureData() orelse return fallbackWidth(str);
    return vaxis.gwidth.gwidth(str, .unicode, data);
}

/// Calculate the display width of a UTF-8 string in terminal cells, accounting
/// for wide characters (emoji, CJK) that take 2 terminal cells.
pub fn displayWidth(text: []const u8) usize {
    // Printable ASCII is one cell per byte. Diff content is overwhelmingly
    // ASCII and side-by-side calls this once per visible line for its wrap
    // math, so skipping the per-codepoint `gwidth` calls below matters.
    if (isPrintableAscii(text)) return text.len;

    var width: usize = 0;
    var byte_pos: usize = 0;

    while (byte_pos < text.len) {
        const char_len = std.unicode.utf8ByteSequenceLength(text[byte_pos]) catch 1;
        const char_end = @min(byte_pos + char_len, text.len);
        width += gwidth(text[byte_pos..char_end]);
        byte_pos = char_end;
    }

    return width;
}

/// Slice a UTF-8 string by display width (terminal cells), not bytes.
/// Returns a slice of the input text containing at most `max_width` terminal
/// cells, ending at a valid UTF-8 boundary.
pub fn sliceByDisplayWidth(text: []const u8, max_width: usize) []const u8 {
    if (max_width == 0) return text[0..0];

    const limit = @min(text.len, max_width);
    var ascii_end: usize = 0;
    while (ascii_end < limit) : (ascii_end += 1) {
        const byte = text[ascii_end];
        if (byte < 0x20 or byte >= 0x7f) break;
    }
    if (ascii_end == limit) return text[0..limit];

    var width: usize = 0;
    var byte_pos: usize = 0;

    if (ascii_end > 0) {
        width = ascii_end;
        byte_pos = ascii_end;
    }

    while (byte_pos < text.len) {
        const char_len = std.unicode.utf8ByteSequenceLength(text[byte_pos]) catch 1;
        const char_end = @min(byte_pos + char_len, text.len);
        const char_width = gwidth(text[byte_pos..char_end]);
        if (width + char_width > max_width) break;
        width += char_width;
        byte_pos = char_end;
    }

    return text[0..byte_pos];
}

/// Word-wraps `text` to `max_width` display cells, yielding one slice per line
/// (breaking on spaces where possible, hard-breaking otherwise). The single
/// iteration primitive behind `wrapText`, `wrapRowCount`, and the info-panel
/// description draw, so rendered wrap and height accounting cannot drift. A
/// `max_width` of 0 yields nothing; empty `text` yields one empty line.
pub const WrapIterator = struct {
    text: []const u8,
    max_width: usize,
    pos: usize = 0,
    done: bool = false,

    pub fn next(self: *WrapIterator) ?[]const u8 {
        if (self.done or self.max_width == 0) return null;
        if (self.text.len == 0) {
            self.done = true;
            return self.text;
        }
        if (self.pos >= self.text.len) return null;

        const seg = wrapSegment(self.text, self.pos, self.max_width);
        const line = self.text[self.pos..seg.seg_end];
        if (seg.done) self.done = true else self.pos = seg.next_start;
        return line;
    }
};

/// Word-wrap `text` to `max_width` display cells. Caller owns the returned list.
pub fn wrapText(allocator: std.mem.Allocator, text: []const u8, max_width: usize) !std.ArrayList([]const u8) {
    var lines: std.ArrayList([]const u8) = .{};
    errdefer lines.deinit(allocator);

    var it = WrapIterator{ .text = text, .max_width = max_width };
    while (it.next()) |line| try lines.append(allocator, line);

    return lines;
}

/// Rows `text` occupies when wrapped to `max_width` — equals
/// `wrapText(...).items.len` but allocation-free, so height/scroll accounting can
/// call it every frame.
pub fn wrapRowCount(text: []const u8, max_width: usize) usize {
    var count: usize = 0;
    var it = WrapIterator{ .text = text, .max_width = max_width };
    while (it.next()) |_| count += 1;
    return count;
}

const WrapSegment = struct { seg_end: usize, next_start: usize, done: bool };

/// One wrap step over `text` starting at `byte_start`: bytes `[byte_start, seg_end)`
/// form the next line and `next_start` is where the following line begins (leading
/// spaces after a space-break are skipped). `done` marks the final segment (the
/// remainder fits in `max_width`). Callers guarantee `byte_start < text.len` and
/// `max_width > 0`. The single source of truth for both `wrapText` and
/// `wrapRowCount`, so rendered wrap and height accounting cannot drift.
fn wrapSegment(text: []const u8, byte_start: usize, max_width: usize) WrapSegment {
    const remaining = text[byte_start..];
    if (displayWidth(remaining) <= max_width) {
        return .{ .seg_end = text.len, .next_start = text.len, .done = true };
    }

    const chunk = sliceByDisplayWidth(remaining, max_width);
    var break_len = chunk.len;
    var found_space = false;
    var i: usize = chunk.len;
    while (i > 0) : (i -= 1) {
        if (chunk[i - 1] == ' ') {
            break_len = i - 1;
            found_space = true;
            break;
        }
    }
    if (!found_space) break_len = chunk.len;
    if (break_len == 0) {
        // chunk.len == 0 means the leading grapheme is wider than max_width, so
        // sliceByDisplayWidth returned nothing; emit one overflowing grapheme to
        // guarantee forward progress. Otherwise a break at position 0 would drop a
        // leading space, so keep the whole chunk instead.
        break_len = if (chunk.len == 0)
            @min(std.unicode.utf8ByteSequenceLength(remaining[0]) catch 1, remaining.len)
        else
            chunk.len;
    }

    const seg_end = byte_start + break_len;
    var next_start = seg_end;
    if (found_space) {
        while (next_start < text.len and text[next_start] == ' ') next_start += 1;
    }
    return .{ .seg_end = seg_end, .next_start = next_start, .done = false };
}

test "displayWidth: ascii fast path agrees with the per-codepoint measurement" {
    try std.testing.expectEqual(@as(usize, 0), displayWidth(""));
    try std.testing.expectEqual(@as(usize, 17), displayWidth("const value = 42;"));
    // Tab is a control byte, so it falls to the per-codepoint path where
    // gwidth reports 0 — same as before the fast path existed.
    try std.testing.expectEqual(@as(usize, 0), displayWidth("\t"));
}

test "displayWidth: non-ascii still measures wide characters" {
    try std.testing.expectEqual(@as(usize, 4), displayWidth("日本"));
    try std.testing.expectEqual(@as(usize, 6), displayWidth("ab日本"));
}

test "wrapText: wide grapheme wider than max_width makes forward progress" {
    // A 2-cell emoji at max_width == 1 makes sliceByDisplayWidth return an empty
    // chunk. Without a forward-progress guard the iterator loops forever; this
    // locks the guard that emits one overflowing grapheme per line.
    var lines = try wrapText(std.testing.allocator, "😀😀", 1);
    defer lines.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings("😀", lines.items[0]);
    try std.testing.expectEqualStrings("😀", lines.items[1]);
}

test "wrapRowCount: wide grapheme wider than max_width terminates" {
    try std.testing.expectEqual(@as(usize, 3), wrapRowCount("😀😀😀", 1));
}

fn ensureData() ?*const DisplayWidth {
    if (width_data) |*data| return data;
    if (load_failed) return null;

    width_data = DisplayWidth.init(std.heap.page_allocator) catch {
        load_failed = true;
        return null;
    };
    return &width_data.?;
}

/// True when every byte is a printable ASCII character, so the string occupies
/// exactly `len` cells. Matches the fast-path scan in `sliceByDisplayWidth`.
fn isPrintableAscii(text: []const u8) bool {
    for (text) |byte| {
        if (byte < 0x20 or byte >= 0x7f) return false;
    }
    return true;
}

fn fallbackWidth(str: []const u8) u16 {
    return @intCast(std.unicode.utf8CountCodepoints(str) catch str.len);
}
