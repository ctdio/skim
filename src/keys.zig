const std = @import("std");
const vaxis = @import("vaxis");

/// Terminal key events, folded into the one shape the rest of skim switches on.
///
/// Under the kitty keyboard protocol a key event is no longer "the character
/// the user typed". `?` arrives as the base key `/` plus a shift modifier, with
/// the real character parked in `shifted_codepoint`/`text`; a caps-locked `a`
/// arrives as `a` with a caps_lock modifier; and the modifier keys themselves
/// arrive as ordinary key events carrying private-use codepoints (shift is
/// U+E061). Legacy terminals send none of that — they send `?` as `?` and never
/// mention shift at all.
///
/// Every mode handler in `src/modes/` compares `key.codepoint` against literal
/// characters, so the protocol difference has to be erased once, at the door,
/// rather than at each of several hundred comparisons.
///
/// Returns null for an event that carries no character at all — a bare modifier
/// press — which callers should drop rather than dispatch. Otherwise the
/// returned key has `codepoint` set to the character the user actually typed.
pub fn normalize(key: vaxis.Key) ?vaxis.Key {
    if (key.isModifier()) return null;

    var out = key;
    if (typedChar(key)) |cp| out.codepoint = cp;
    return out;
}

/// The character a key event stands for, or null when the event's own
/// `codepoint` is already the answer (or is not a character at all).
fn typedChar(key: vaxis.Key) ?u21 {
    // A ctrl/alt/super chord is named by its *base* key: ctrl+shift+m is bound
    // as 'm' with both modifiers, not as 'M'. Only the shift/lock modifiers
    // change which character a key produces.
    if (key.mods.ctrl or key.mods.alt or key.mods.super or key.mods.hyper or key.mods.meta) {
        return null;
    }

    // The terminal already told us what the key produced. Prefer it: it is the
    // only field that survives caps lock, dead keys and alternate layouts.
    if (key.text) |text| {
        var iter = (std.unicode.Utf8View.init(text) catch return null).iterator();
        const first = iter.nextCodepoint() orelse return null;
        // A grapheme cluster the terminal could not name with a single
        // codepoint (an emoji sequence, an IME commit) has no character to fold
        // into; leave it for whoever reads `text` directly.
        if (iter.nextCodepoint() != null) return null;
        if (isPrintable(first)) return first;
        return null;
    }

    if (key.mods.shift) {
        if (key.shifted_codepoint) |cp| {
            if (isPrintable(cp)) return cp;
        }
    }
    return null;
}

fn isPrintable(cp: u21) bool {
    return cp >= 32 and cp != 127;
}

const testing = std.testing;

test "normalize drops bare modifier presses" {
    try testing.expect(normalize(.{ .codepoint = vaxis.Key.left_shift, .mods = .{ .shift = true } }) == null);
    try testing.expect(normalize(.{ .codepoint = vaxis.Key.right_control, .mods = .{ .ctrl = true } }) == null);
}

test "normalize resolves shifted punctuation to the typed character" {
    // Kitty reports shift+/ as `CSI 47:63;2;63u`.
    const key = normalize(.{
        .codepoint = '/',
        .shifted_codepoint = '?',
        .text = "?",
        .mods = .{ .shift = true },
    }).?;
    try testing.expectEqual(@as(u21, '?'), key.codepoint);
}

test "normalize resolves shifted letters without associated text" {
    const key = normalize(.{
        .codepoint = 'a',
        .shifted_codepoint = 'A',
        .mods = .{ .shift = true },
    }).?;
    try testing.expectEqual(@as(u21, 'A'), key.codepoint);
}

test "normalize applies caps lock" {
    const key = normalize(.{ .codepoint = 'a', .text = "A", .mods = .{ .caps_lock = true } }).?;
    try testing.expectEqual(@as(u21, 'A'), key.codepoint);
}

test "normalize leaves ctrl chords on their base key" {
    const key = normalize(.{
        .codepoint = 'm',
        .shifted_codepoint = 'M',
        .mods = .{ .ctrl = true, .shift = true },
    }).?;
    try testing.expectEqual(@as(u21, 'm'), key.codepoint);
    try testing.expect(key.mods.ctrl and key.mods.shift);
}

test "normalize leaves legacy events untouched" {
    const key = normalize(.{ .codepoint = '?' }).?;
    try testing.expectEqual(@as(u21, '?'), key.codepoint);

    const enter = normalize(.{ .codepoint = vaxis.Key.enter }).?;
    try testing.expectEqual(vaxis.Key.enter, enter.codepoint);
}

test "normalize ignores text for control keys" {
    // Some terminals attach the carriage return as associated text.
    const key = normalize(.{ .codepoint = vaxis.Key.enter, .text = "\r" }).?;
    try testing.expectEqual(vaxis.Key.enter, key.codepoint);
}
