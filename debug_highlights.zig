const std = @import("std");
const syntax = @import("src/syntax.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var highlighter = try syntax.SyntaxHighlighter.init(allocator);
    defer highlighter.deinit();

    const js_code =
        \\const message = "Hello World";
        \\
        \\function greet(name) {
        \\  console.log(name);
        \\  return name;
        \\}
    ;

    const highlights = try highlighter.highlightContent(.javascript, js_code);
    defer highlighter.freeHighlights(highlights);

    std.debug.print("Total highlights: {}\n", .{highlights.len});
    std.debug.print("\nCode:\n{s}\n\n", .{js_code});
    std.debug.print("Highlights:\n", .{});
    for (highlights) |h| {
        const text = js_code[h.start_byte..h.end_byte];
        std.debug.print("  [{d:3}-{d:3}] '{s:<15}' -> {s}\n", .{ h.start_byte, h.end_byte, text, h.category });
    }
}
