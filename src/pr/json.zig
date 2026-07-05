//! Typed getters over `std.json.ObjectMap`, shared by the two PR parsers
//! (`parse.zig`, `review_parse.zig`). Each degrades to a safe default on a
//! missing or wrong-typed field so the parsers stay branch-free at the call
//! site; no IO, no allocation.

const std = @import("std");

pub fn objField(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const v = obj.get(key) orelse return null;
    if (v != .object) return null;
    return v.object;
}

pub fn objValue(value: std.json.Value, key: []const u8) ?std.json.ObjectMap {
    if (value != .object) return null;
    return objField(value.object, key);
}

pub fn arrField(obj: std.json.ObjectMap, key: []const u8) ?[]std.json.Value {
    const v = obj.get(key) orelse return null;
    if (v != .array) return null;
    return v.array.items;
}

pub fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

pub fn boolField(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return v == .bool and v.bool;
}

pub fn u32Field(obj: std.json.ObjectMap, key: []const u8) u32 {
    return optU32Field(obj, key) orelse 0;
}

pub fn optU32Field(obj: std.json.ObjectMap, key: []const u8) ?u32 {
    const v = obj.get(key) orelse return null;
    if (v != .integer) return null;
    return std.math.cast(u32, v.integer);
}

pub fn u64Field(obj: std.json.ObjectMap, key: []const u8) u64 {
    const v = obj.get(key) orelse return 0;
    if (v != .integer) return 0;
    if (v.integer < 0) return 0;
    return @intCast(v.integer);
}
