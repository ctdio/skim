//! C ABI over `web/session.zig` for the browser build (`zig build web`).
//!
//! The module is a WASI command module: the host must run `_start` once (which
//! initialises libc) before it calls any export below.
//!
//! Call order from JavaScript:
//!   1. `skimAlloc(len)` — get a buffer, write the diff bytes into it
//!   2. `skimLoad(ptr, len, width, height)` — parse, highlight, first frame
//!   3. `skimRender()` / `skimKey(codepoint, mods)` / `skimResize(w, h)`
//!   4. `skimOutPtr()` + `skimOutLen()` — read the ANSI frame, feed it to xterm.js
//!
//! Every call returns a `Status`. Any negative value means the frame did not
//! change and the output buffer must not be read.

const std = @import("std");
const vaxis = @import("vaxis");

const session_mod = @import("session.zig");

const Session = session_mod.Session;

/// Return codes shared with the JavaScript side. Keep in sync with web/skim.js.
pub const Status = enum(i32) {
    ok = 0,
    no_session = -1,
    load_failed = -2,
    render_failed = -3,
    key_failed = -4,
    resize_failed = -5,
};

/// Modifier bits `skimKey` accepts, matching the order of `vaxis.Key.Modifiers`.
const mod_shift: u8 = 1 << 0;
const mod_alt: u8 = 1 << 1;
const mod_ctrl: u8 = 1 << 2;

const allocator = std.heap.c_allocator;

var active: ?Session = null;

/// Reserve `len` bytes for the host to write diff text into. The buffer is owned
/// by the module until `skimLoad` copies out of it.
export fn skimAlloc(len: usize) ?[*]u8 {
    const buffer = allocator.alloc(u8, len) catch return null;
    return buffer.ptr;
}

/// Release a buffer from `skimAlloc`.
export fn skimFree(ptr: [*]u8, len: usize) void {
    allocator.free(ptr[0..len]);
}

/// Open a diff. Replaces any session already open.
export fn skimLoad(ptr: [*]const u8, len: usize, width: u16, height: u16) i32 {
    skimUnload();

    active = Session.init(allocator, .{
        .diff_text = ptr[0..len],
        .width = width,
        .height = height,
    }) catch return @intFromEnum(Status.load_failed);

    return @intFromEnum(Status.ok);
}

/// Close the open session and free everything it holds.
export fn skimUnload() void {
    if (active) |*session| session.deinit();
    active = null;
}

/// Send one key. `codepoint` is a Unicode scalar value; `mods` is a bit set of
/// `mod_shift`, `mod_alt`, and `mod_ctrl`. The parameter is `u32` because the
/// wasm ABI only accepts power-of-two integer widths.
export fn skimKey(codepoint: u32, mods: u8) i32 {
    var session = &(active orelse return @intFromEnum(Status.no_session));
    if (codepoint > std.math.maxInt(u21)) return @intFromEnum(Status.key_failed);

    session.handleKey(.{
        .codepoint = @intCast(codepoint),
        .mods = .{
            .shift = mods & mod_shift != 0,
            .alt = mods & mod_alt != 0,
            .ctrl = mods & mod_ctrl != 0,
        },
    }) catch return @intFromEnum(Status.key_failed);

    return @intFromEnum(Status.ok);
}

/// Change the terminal size and redraw.
export fn skimResize(width: u16, height: u16) i32 {
    var session = &(active orelse return @intFromEnum(Status.no_session));
    session.resize(width, height) catch return @intFromEnum(Status.resize_failed);
    return @intFromEnum(Status.ok);
}

/// Draw the current state into the output buffer.
export fn skimRender() i32 {
    var session = &(active orelse return @intFromEnum(Status.no_session));
    _ = session.render() catch return @intFromEnum(Status.render_failed);
    return @intFromEnum(Status.ok);
}

/// Row of the text cursor in the last frame, 0-based from the top. Only
/// meaningful while `skimCursorVisible` returns 1.
export fn skimCursorRow() u16 {
    const session = &(active orelse return 0);
    return session.ctx.screen.cursor_row;
}

/// Column of the text cursor in the last frame, 0-based from the left.
export fn skimCursorCol() u16 {
    const session = &(active orelse return 0);
    return session.ctx.screen.cursor_col;
}

/// 1 while skim wants a visible text cursor, which is the comment editor. The
/// host should place its own terminal cursor there and show it.
export fn skimCursorVisible() i32 {
    const session = &(active orelse return 0);
    return if (session.ctx.screen.cursor_vis) 1 else 0;
}

/// Start of the last rendered ANSI frame. Valid until the next render.
export fn skimOutPtr() [*]const u8 {
    const session = &(active orelse return "");
    return session.ansi.ptr;
}

/// Byte length of the last rendered ANSI frame.
export fn skimOutLen() usize {
    const session = &(active orelse return 0);
    return session.ansi.len;
}

/// WASI command modules must define an entry point. The host runs it once to
/// initialise libc and then drives the module through the exports above.
pub fn main() void {}
