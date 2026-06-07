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
