//! Test root for the PR store (src/pr/db/). Its own step because it is the
//! only test binary that links SQLite.

const std = @import("std");

pub const sqlite = @import("pr/db/sqlite.zig");
pub const migrations = @import("pr/db/migrations.zig");
pub const types = @import("pr/db/types.zig");
pub const store = @import("pr/db/store.zig");
// std + skim_io only; for the drift test below.
const github = @import("pr/github.zig");

test {
    std.testing.refAllDecls(@This());
}

test "SyncErrorKind mirrors github.GhErrorKind" {
    // types.zig must not import github.zig (it stays SQLite- and process-free
    // for the wasm build), so the two enums are kept in step here, the one
    // place that can see both.
    inline for (std.meta.fields(github.GhErrorKind)) |f| {
        try std.testing.expect(std.meta.stringToEnum(types.SyncErrorKind, f.name) != null);
    }
    try std.testing.expectEqual(std.meta.fields(github.GhErrorKind).len, std.meta.fields(types.SyncErrorKind).len);
}
