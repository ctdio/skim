//! Test root for the sidebar filter language. filter_query reads PrRecord
//! from db/types.zig (no SQLite), so this root links nothing extra.

const std = @import("std");

pub const filter_query = @import("pr/filter_query.zig");

test {
    std.testing.refAllDecls(@This());
}
