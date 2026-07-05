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

/// Word-wrap `text` to `max_width` display cells, breaking on spaces where
/// possible and hard-breaking otherwise. Caller owns the returned list.
pub fn wrapText(allocator: std.mem.Allocator, text: []const u8, max_width: usize) !std.ArrayList([]const u8) {
    var lines: std.ArrayList([]const u8) = .{};
    errdefer lines.deinit(allocator);

    if (max_width == 0) return lines;

    if (text.len == 0) {
        try lines.append(allocator, text);
        return lines;
    }

    var byte_start: usize = 0;
    while (byte_start < text.len) {
        const remaining = text[byte_start..];
        if (displayWidth(remaining) <= max_width) {
            try lines.append(allocator, remaining);
            break;
        }

        const chunk = sliceByDisplayWidth(remaining, max_width);
        var break_byte_pos = chunk.len;
        var found_space = false;
        var i: usize = chunk.len;
        while (i > 0) : (i -= 1) {
            if (chunk[i - 1] == ' ') {
                break_byte_pos = i - 1;
                found_space = true;
                break;
            }
        }
        if (!found_space) break_byte_pos = chunk.len;
        if (break_byte_pos == 0) break_byte_pos = chunk.len; // avoid zero-progress / dropped leading space

        try lines.append(allocator, remaining[0..break_byte_pos]);
        byte_start += break_byte_pos;
        if (found_space) {
            while (byte_start < text.len and text[byte_start] == ' ') byte_start += 1;
        }
    }

    return lines;
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

fn fallbackWidth(str: []const u8) u16 {
    return @intCast(std.unicode.utf8CountCodepoints(str) catch str.len);
}
