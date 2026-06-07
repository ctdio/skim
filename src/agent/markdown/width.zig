const std = @import("std");
const vaxis = @import("vaxis");

const DisplayWidth = vaxis.DisplayWidth;

// Local copy of the display-width wrapper. The markdown subtree is compiled as a
// standalone module (see build.zig markdown_tests), so it can't import
// ../../rendering/width.zig without escaping its module root. This mirrors the
// already-duplicated displayWidth/sliceByDisplayWidth helpers in tables.zig that
// keep the markdown module self-contained. See src/rendering/width.zig.
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
