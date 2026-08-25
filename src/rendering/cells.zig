const std = @import("std");
const vaxis = @import("vaxis");

const Window = vaxis.Window;
const Segment = vaxis.Cell.Segment;
const PrintOptions = Window.PrintOptions;
const PrintResult = Window.PrintResult;

/// Placement for `fillGlyph`, mirroring the shape of `PrintOptions`.
pub const GlyphOptions = struct {
    col: u16,
    row: u16,
    /// Number of consecutive cells to fill, clipped to the window width.
    count: u16 = 1,
    style: vaxis.Cell.Style = .{},
};

/// Drop-in replacement for `vaxis.Window.print` that skips the grapheme
/// iterator and the Unicode width tables when every segment is printable ASCII
/// — which covers nearly all diff content plus every background-padding run.
///
/// `vaxis.Window.print` runs a grapheme-break state machine and a `DisplayWidth`
/// lookup per character. On a full 190x60 screen of ASCII that is ~4x the cost
/// of writing the cells directly, and it dominates a diff frame. Segments with
/// any non-ASCII byte delegate to `win.print` unchanged, so wide characters,
/// combining marks, and emoji keep exact vaxis semantics.
pub fn print(win: Window, segments: []const Segment, opts: PrintOptions) PrintResult {
    // Word wrapping needs the tokenizer in vaxis; only grapheme/none are hot.
    if (opts.wrap == .word) return win.print(segments, opts);

    for (segments) |segment| {
        if (!isPrintableAscii(segment.text)) return win.print(segments, opts);
    }

    return printAscii(win, segments, opts);
}

/// Convenience wrapper mirroring `vaxis.Window.printSegment`.
pub fn printSegment(win: Window, segment: Segment, opts: PrintOptions) PrintResult {
    return print(win, &.{segment}, opts);
}

/// Writes a horizontal run of one single-width glyph, skipping the width
/// machinery entirely. `print` cannot help here: borders, dividers, and the
/// side-by-side diagonal fill are all non-ASCII, so they take the `win.print`
/// fallback and pay a grapheme-break pass plus a `DisplayWidth` lookup for
/// every cell — for the diagonal fill, across half the terminal on every
/// changed row.
///
/// The caller asserts the glyph occupies exactly one cell. Anything wider (CJK,
/// emoji) must go through `print`, which measures it.
pub fn fillGlyph(win: Window, grapheme: []const u8, opts: GlyphOptions) void {
    if (opts.count == 0 or opts.row >= win.height or opts.col >= win.width) return;

    const end = @min(opts.col +| opts.count, win.width);
    var col = opts.col;
    while (col < end) : (col += 1) {
        win.writeCell(col, opts.row, .{
            .char = .{ .grapheme = grapheme, .width = 1 },
            .style = opts.style,
            // Mirrors the `.grapheme` branch of `vaxis.Window.print`, which
            // these call sites used before.
            .wrapped = col + 1 >= win.width,
        });
    }
}

/// Mirrors the `.grapheme`/`.none` branches of `vaxis.Window.print` byte for
/// byte, with width fixed at 1 because every byte is known printable ASCII.
fn printAscii(win: Window, segments: []const Segment, opts: PrintOptions) PrintResult {
    const wraps = opts.wrap == .grapheme;
    var row = opts.row_offset;
    var col = opts.col_offset;

    const overflow: bool = blk: for (segments) |segment| {
        for (segment.text, 0..) |_, i| {
            if (col >= win.width) {
                if (!wraps) break :blk true;
                row += 1;
                col = 0;
            }
            if (wraps and row >= win.height) break :blk true;

            if (opts.commit) win.writeCell(col, row, .{
                .char = .{ .grapheme = segment.text[i .. i + 1], .width = 1 },
                .style = segment.style,
                .link = segment.link,
                .wrapped = wraps and col + 1 >= win.width,
            });

            if (wraps) col += 1 else col +|= 1;
        }
    } else false;

    if (wraps and col >= win.width) {
        row += 1;
        col = 0;
    }

    return .{ .row = row, .col = col, .overflow = overflow };
}

/// True when every byte is in the printable ASCII range, so each byte is
/// exactly one grapheme of width 1. Control bytes (including `\n`, which
/// `vaxis.Window.print` treats specially) and any byte >= 0x7f are excluded.
fn isPrintableAscii(text: []const u8) bool {
    const Chunk = @Vector(16, u8);
    var i: usize = 0;
    while (i + 16 <= text.len) : (i += 16) {
        const chunk: Chunk = text[i..][0..16].*;
        const too_low = chunk < @as(Chunk, @splat(0x20));
        const too_high = chunk > @as(Chunk, @splat(0x7e));
        if (@reduce(.Or, too_low) or @reduce(.Or, too_high)) return false;
    }
    while (i < text.len) : (i += 1) {
        if (text[i] < 0x20 or text[i] > 0x7e) return false;
    }
    return true;
}

// Tests assert byte-for-byte equivalence with vaxis.Window.print by rendering
// the same segments into two screens and comparing every cell.

const TestScreens = struct {
    allocator: std.mem.Allocator,
    reference: vaxis.Screen,
    fast: vaxis.Screen,

    fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) !TestScreens {
        const winsize = vaxis.Winsize{ .rows = rows, .cols = cols, .x_pixel = 0, .y_pixel = 0 };
        return .{
            .allocator = allocator,
            .reference = try vaxis.Screen.init(allocator, winsize),
            .fast = try vaxis.Screen.init(allocator, winsize),
        };
    }

    fn deinit(self: *TestScreens) void {
        self.reference.deinit(self.allocator);
        self.fast.deinit(self.allocator);
    }

    fn windowFor(screen: *vaxis.Screen) Window {
        return .{
            .x_off = 0,
            .y_off = 0,
            .parent_x_off = 0,
            .parent_y_off = 0,
            .width = screen.width,
            .height = screen.height,
            .screen = screen,
        };
    }

    /// Prints `segments` into a child window of both screens, so the
    /// window-to-screen offset translation in `writeRun` is exercised rather
    /// than the degenerate zero-offset case.
    fn expectChildMatches(
        self: *TestScreens,
        child: vaxis.Window.ChildOptions,
        segments: []const Segment,
        opts: PrintOptions,
    ) !void {
        const expected = TestScreens.windowFor(&self.reference).child(child).print(segments, opts);
        const actual = print(TestScreens.windowFor(&self.fast).child(child), segments, opts);

        try std.testing.expectEqual(expected.row, actual.row);
        try std.testing.expectEqual(expected.col, actual.col);
        try std.testing.expectEqual(expected.overflow, actual.overflow);

        try self.expectCellsMatch();
    }

    /// Prints `segments` through both `vaxis.Window.print` and `cells.print`,
    /// then asserts the results and every screen cell match.
    fn expectMatches(self: *TestScreens, segments: []const Segment, opts: PrintOptions) !void {
        const expected = TestScreens.windowFor(&self.reference).print(segments, opts);
        const actual = print(TestScreens.windowFor(&self.fast), segments, opts);

        try std.testing.expectEqual(expected.row, actual.row);
        try std.testing.expectEqual(expected.col, actual.col);
        try std.testing.expectEqual(expected.overflow, actual.overflow);

        try self.expectCellsMatch();
    }

    /// Asserts every cell of the two screens is identical.
    fn expectCellsMatch(self: *TestScreens) !void {
        for (self.reference.buf, self.fast.buf) |ref_cell, fast_cell| {
            try std.testing.expectEqualStrings(ref_cell.char.grapheme, fast_cell.char.grapheme);
            try std.testing.expectEqual(ref_cell.char.width, fast_cell.char.width);
            try std.testing.expectEqual(ref_cell.style, fast_cell.style);
            try std.testing.expectEqual(ref_cell.wrapped, fast_cell.wrapped);
        }
    }
};

test "print: matches vaxis for an ascii segment" {
    var screens = try TestScreens.init(std.testing.allocator, 20, 4);
    defer screens.deinit();

    try screens.expectMatches(&.{.{ .text = "const value = 42;" }}, .{});
}

test "print: matches vaxis when an ascii segment wraps rows" {
    var screens = try TestScreens.init(std.testing.allocator, 10, 4);
    defer screens.deinit();

    try screens.expectMatches(&.{.{ .text = "abcdefghijklmnopqrstuvwxyz" }}, .{});
}

test "print: matches vaxis when an ascii segment lands exactly on the edge" {
    var screens = try TestScreens.init(std.testing.allocator, 10, 4);
    defer screens.deinit();

    try screens.expectMatches(&.{.{ .text = "abcdefghij" }}, .{});
}

test "print: matches vaxis when an ascii segment overflows the last row" {
    var screens = try TestScreens.init(std.testing.allocator, 4, 2);
    defer screens.deinit();

    try screens.expectMatches(&.{.{ .text = "abcdefghijklmnop" }}, .{});
}

test "print: matches vaxis for multiple styled ascii segments" {
    var screens = try TestScreens.init(std.testing.allocator, 20, 4);
    defer screens.deinit();

    try screens.expectMatches(&.{
        .{ .text = "const ", .style = .{ .bold = true } },
        .{ .text = "value", .style = .{ .fg = .{ .index = 3 } } },
        .{ .text = " = 42;", .style = .{ .bg = .{ .index = 1 } } },
    }, .{});
}

test "print: matches vaxis with a column offset" {
    var screens = try TestScreens.init(std.testing.allocator, 20, 4);
    defer screens.deinit();

    try screens.expectMatches(&.{.{ .text = "offset" }}, .{ .col_offset = 12, .row_offset = 1 });
}

test "print: matches vaxis for wrap none" {
    var screens = try TestScreens.init(std.testing.allocator, 8, 2);
    defer screens.deinit();

    try screens.expectMatches(&.{.{ .text = "truncate me" }}, .{ .wrap = .none });
}

test "print: matches vaxis when commit is false" {
    var screens = try TestScreens.init(std.testing.allocator, 8, 2);
    defer screens.deinit();

    try screens.expectMatches(&.{.{ .text = "measure only" }}, .{ .commit = false });
}

test "print: matches vaxis for an empty segment" {
    var screens = try TestScreens.init(std.testing.allocator, 8, 2);
    defer screens.deinit();

    try screens.expectMatches(&.{.{ .text = "" }}, .{});
}

test "print: matches vaxis for a wide-character segment" {
    var screens = try TestScreens.init(std.testing.allocator, 20, 4);
    defer screens.deinit();

    try screens.expectMatches(&.{.{ .text = "日本語テキスト" }}, .{});
}

test "print: matches vaxis for a box-drawing segment" {
    var screens = try TestScreens.init(std.testing.allocator, 20, 4);
    defer screens.deinit();

    try screens.expectMatches(&.{.{ .text = "┃" }}, .{});
}

test "print: matches vaxis for a segment mixing ascii and non-ascii" {
    var screens = try TestScreens.init(std.testing.allocator, 20, 4);
    defer screens.deinit();

    try screens.expectMatches(&.{.{ .text = "ok → done" }}, .{});
}

test "print: matches vaxis for a segment containing a newline" {
    var screens = try TestScreens.init(std.testing.allocator, 20, 4);
    defer screens.deinit();

    try screens.expectMatches(&.{.{ .text = "first\nsecond" }}, .{});
}

test "print: matches vaxis for a long padded ascii run" {
    var screens = try TestScreens.init(std.testing.allocator, 64, 3);
    defer screens.deinit();

    try screens.expectMatches(&.{
        .{ .text = "+added line" },
        .{ .text = "                                                       ", .style = .{ .bg = .{ .index = 2 } } },
    }, .{});
}

test "print: matches vaxis inside an offset child window" {
    var screens = try TestScreens.init(std.testing.allocator, 24, 6);
    defer screens.deinit();

    try screens.expectChildMatches(
        .{ .x_off = 5, .y_off = 2, .width = 10, .height = 3 },
        &.{.{ .text = "hello world", .style = .{ .fg = .{ .index = 5 } } }},
        .{},
    );
}

test "print: matches vaxis when a child window clips the run at its right edge" {
    var screens = try TestScreens.init(std.testing.allocator, 24, 6);
    defer screens.deinit();

    try screens.expectChildMatches(
        .{ .x_off = 18, .y_off = 1, .width = 6, .height = 2 },
        &.{.{ .text = "abcdefghijkl" }},
        .{},
    );
}

test "print: matches vaxis when a child window clips the run at its bottom edge" {
    var screens = try TestScreens.init(std.testing.allocator, 12, 6);
    defer screens.deinit();

    try screens.expectChildMatches(
        .{ .x_off = 2, .y_off = 4, .width = 4, .height = 2 },
        &.{.{ .text = "abcdefghijklmnop" }},
        .{},
    );
}

test "print: matches vaxis in a child window with wrap none" {
    var screens = try TestScreens.init(std.testing.allocator, 24, 6);
    defer screens.deinit();

    try screens.expectChildMatches(
        .{ .x_off = 6, .y_off = 3, .width = 5, .height = 2 },
        &.{.{ .text = "truncate" }},
        .{ .wrap = .none },
    );
}

test "print: matches vaxis in a negatively offset child window" {
    var screens = try TestScreens.init(std.testing.allocator, 20, 5);
    defer screens.deinit();

    // Negative offsets take writeRun's fallback branch, where vaxis's per-cell
    // sign checks do the clipping.
    try screens.expectChildMatches(
        .{ .x_off = -3, .y_off = -1, .width = 10, .height = 4 },
        &.{.{ .text = "clipped left edge" }},
        .{},
    );
}

test "fillGlyph: matches vaxis for a run of a box-drawing glyph" {
    var screens = try TestScreens.init(std.testing.allocator, 20, 4);
    defer screens.deinit();

    _ = TestScreens.windowFor(&screens.reference).print(
        &.{.{ .text = "╱╱╱╱╱╱", .style = .{ .fg = .{ .index = 4 } } }},
        .{ .row_offset = 2, .col_offset = 3 },
    );
    fillGlyph(TestScreens.windowFor(&screens.fast), "╱", .{
        .col = 3,
        .row = 2,
        .count = 6,
        .style = .{ .fg = .{ .index = 4 } },
    });

    try screens.expectCellsMatch();
}

test "fillGlyph: clips a run at the window edge instead of wrapping" {
    var screens = try TestScreens.init(std.testing.allocator, 8, 2);
    defer screens.deinit();

    // fillGlyph never wraps, so the reference prints only the glyphs that fit
    // on the row. Cells past the edge must stay untouched on both screens.
    _ = TestScreens.windowFor(&screens.reference).print(
        &.{.{ .text = "┃┃┃" }},
        .{ .row_offset = 0, .col_offset = 5 },
    );
    fillGlyph(TestScreens.windowFor(&screens.fast), "┃", .{ .col = 5, .row = 0, .count = 5 });

    try screens.expectCellsMatch();
}

test "fillGlyph: matches vaxis wrapped flag when the run reaches the right edge" {
    var screens = try TestScreens.init(std.testing.allocator, 6, 2);
    defer screens.deinit();

    _ = TestScreens.windowFor(&screens.reference).print(&.{.{ .text = "╱╱╱╱╱╱" }}, .{});
    fillGlyph(TestScreens.windowFor(&screens.fast), "╱", .{ .col = 0, .row = 0, .count = 6 });

    try screens.expectCellsMatch();
}

test "fillGlyph: writes nothing for a row outside the window" {
    var screens = try TestScreens.init(std.testing.allocator, 8, 2);
    defer screens.deinit();

    fillGlyph(TestScreens.windowFor(&screens.fast), "┃", .{ .col = 0, .row = 9, .count = 4 });

    try screens.expectCellsMatch();
}

test "fillGlyph: writes nothing for a zero count" {
    var screens = try TestScreens.init(std.testing.allocator, 8, 2);
    defer screens.deinit();

    fillGlyph(TestScreens.windowFor(&screens.fast), "┃", .{ .col = 0, .row = 0, .count = 0 });

    try screens.expectCellsMatch();
}

test "isPrintableAscii: rejects control bytes past the vector chunk boundary" {
    try std.testing.expect(isPrintableAscii("0123456789abcdefghij"));
    try std.testing.expect(!isPrintableAscii("0123456789abcdef\thij"));
    try std.testing.expect(!isPrintableAscii("0123456789abcdefghi\x7f"));
}
