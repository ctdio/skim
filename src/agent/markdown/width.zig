const std = @import("std");
const vaxis = @import("vaxis");

/// Display width of a UTF-8 string in terminal cells, accounting for wide
/// characters (CJK, emoji).
///
/// Local copy of the display-width wrapper. The markdown subtree is compiled as a
/// standalone module (see build.zig markdown_tests), so it can't import
/// ../../rendering/width.zig without escaping its module root. This mirrors the
/// already-duplicated displayWidth/sliceByDisplayWidth helpers in tables.zig that
/// keep the markdown module self-contained. See src/rendering/width.zig.
pub fn gwidth(str: []const u8) u16 {
    return vaxis.gwidth.gwidth(str, .unicode);
}
