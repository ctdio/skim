//! Thin wrapper over the SQLite C API: the only file in skim that touches it.
//!
//! The library is built with SQLITE_THREADSAFE=2, so a `Db` (and every `Stmt`
//! prepared on it) must be used by exactly one thread.

const std = @import("std");
const c = @import("sqlite_c");
const skim_io = @import("skim_io");

pub const Error = error{ Busy, Corrupt, Constraint, SqliteError, OutOfMemory };

pub const OpenFlags = struct {
    read_only: bool = false,
    create: bool = true,
};

pub const BeginMode = enum { deferred, immediate };

/// Distinguishes BLOB from TEXT at bind sites (both are byte slices).
pub const Blob = struct { bytes: []const u8 };

/// `SQLITE_TRANSIENT` translates to a cast of -1 that does not compile as a
/// pointer; this is the same sentinel. It makes SQLite copy bound bytes, so
/// bind sites carry no lifetime rules.
const transient: c.sqlite3_destructor_type = @ptrFromInt(std.math.maxInt(usize));

pub const Db = struct {
    handle: *c.sqlite3,

    /// `path` must be NUL-terminated; ":memory:" is allowed. Opens with
    /// SQLITE_OPEN_NOMUTEX: a Db is used by exactly one thread.
    pub fn open(path: [:0]const u8, flags: OpenFlags) Error!Db {
        var open_flags: c_int = c.SQLITE_OPEN_NOMUTEX;
        if (flags.read_only) {
            open_flags |= c.SQLITE_OPEN_READONLY;
        } else {
            open_flags |= c.SQLITE_OPEN_READWRITE;
            if (flags.create) open_flags |= c.SQLITE_OPEN_CREATE;
        }

        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path.ptr, &handle, open_flags, null);
        if (rc != c.SQLITE_OK) {
            // SQLite allocates a handle even on most failures; it must be closed.
            if (handle) |h| _ = c.sqlite3_close_v2(h);
            try check(rc);
        }
        return .{ .handle = handle orelse return error.OutOfMemory };
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close_v2(self.handle);
        self.* = undefined;
    }

    /// Runs every statement in `sql`; rows are discarded.
    pub fn exec(self: *Db, sql: [:0]const u8) Error!void {
        try check(c.sqlite3_exec(self.handle, sql.ptr, null, null, null));
    }

    /// Compiles the first statement in `sql`. SQL with no statement (empty or
    /// comment-only) is an error rather than a Stmt that cannot step.
    pub fn prepare(self: *Db, sql: []const u8) Error!Stmt {
        var handle: ?*c.sqlite3_stmt = null;
        const len = std.math.cast(c_int, sql.len) orelse return error.SqliteError;
        try check(c.sqlite3_prepare_v2(self.handle, sql.ptr, len, &handle, null));
        return .{
            .handle = handle orelse return error.SqliteError,
            .db = self.handle,
        };
    }

    pub fn begin(self: *Db, mode: BeginMode) Error!void {
        try self.exec(switch (mode) {
            .deferred => "BEGIN DEFERRED",
            .immediate => "BEGIN IMMEDIATE",
        });
    }

    pub fn commit(self: *Db) Error!void {
        try self.exec("COMMIT");
    }

    /// Best effort, never fails the caller: used from `errdefer`, where the
    /// transaction may already have been rolled back by SQLite itself.
    pub fn rollback(self: *Db) void {
        _ = c.sqlite3_exec(self.handle, "ROLLBACK", null, null, null);
    }

    /// Rows modified by the most recent INSERT/UPDATE/DELETE.
    pub fn changes(self: *Db) usize {
        return @intCast(c.sqlite3_changes64(self.handle));
    }

    pub fn lastInsertRowId(self: *Db) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    /// Last error text for logs; borrowed until the next call on this Db.
    pub fn errmsg(self: *Db) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.handle));
    }

    /// `PRAGMA user_version`. Write it with `exec`.
    pub fn userVersion(self: *Db) Error!u32 {
        var stmt = try self.prepare("PRAGMA user_version");
        defer stmt.finalize();
        if (!try stmt.step()) return error.SqliteError;
        return std.math.cast(u32, stmt.columnInt(0)) orelse error.SqliteError;
    }
};

pub const Stmt = struct {
    handle: *c.sqlite3_stmt,
    db: *c.sqlite3,

    /// 1-based. Accepts integers, bool (0/1), byte slices and pointers to byte
    /// arrays (TEXT), `Blob` (BLOB), `null`, and optionals of those (null →
    /// NULL). Anything else is a compile error.
    pub fn bind(self: *Stmt, index: u16, value: anytype) Error!void {
        const T = @TypeOf(value);
        const i: c_int = index;
        const rc = rc: {
            if (T == Blob) break :rc bindBytes(self.handle, i, value.bytes, .blob);
            switch (@typeInfo(T)) {
                .null => break :rc c.sqlite3_bind_null(self.handle, i),
                .optional => {
                    if (value) |inner| return self.bind(index, inner);
                    break :rc c.sqlite3_bind_null(self.handle, i);
                },
                .bool => break :rc c.sqlite3_bind_int64(self.handle, i, @intFromBool(value)),
                .int, .comptime_int => break :rc c.sqlite3_bind_int64(self.handle, i, @intCast(value)),
                .pointer => break :rc bindBytes(self.handle, i, textSlice(value), .text),
                else => @compileError("sqlite: cannot bind a value of type " ++ @typeName(T)),
            }
        };
        try check(rc);
    }

    /// Binds tuple fields to parameters 1..N in order.
    pub fn bindAll(self: *Stmt, values: anytype) Error!void {
        inline for (values, 1..) |value, index| {
            try self.bind(index, value);
        }
    }

    /// true → a row is available; false → the statement is done.
    pub fn step(self: *Stmt) Error!bool {
        const rc = c.sqlite3_step(self.handle);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        try check(rc);
        return error.SqliteError;
    }

    /// 0-based. NULL reads as 0.
    pub fn columnInt(self: *Stmt, index: u16) i64 {
        return c.sqlite3_column_int64(self.handle, index);
    }

    /// 0-based. NULL reads as "". Borrowed until the next step/reset/finalize.
    pub fn columnText(self: *Stmt, index: u16) Error![]const u8 {
        return try self.columnTextOpt(index) orelse "";
    }

    /// 0-based. Borrowed until the next step/reset/finalize.
    pub fn columnTextOpt(self: *Stmt, index: u16) Error!?[]const u8 {
        // column_text must run before column_bytes: it performs the conversion
        // whose length column_bytes then reports. It returns NULL for a
        // non-NULL value only when that conversion could not allocate.
        const ptr = c.sqlite3_column_text(self.handle, index) orelse {
            if (self.columnIsNull(index)) return null;
            return error.OutOfMemory;
        };
        const len: usize = @intCast(c.sqlite3_column_bytes(self.handle, index));
        return ptr[0..len];
    }

    /// 0-based. NULL and zero-length blobs read as "". Borrowed until the next
    /// step/reset/finalize.
    pub fn columnBlob(self: *Stmt, index: u16) []const u8 {
        const ptr = c.sqlite3_column_blob(self.handle, index) orelse return "";
        const len: usize = @intCast(c.sqlite3_column_bytes(self.handle, index));
        return @as([*]const u8, @ptrCast(ptr))[0..len];
    }

    pub fn columnIsNull(self: *Stmt, index: u16) bool {
        return c.sqlite3_column_type(self.handle, index) == c.SQLITE_NULL;
    }

    /// Rewinds and clears bindings so the statement can be reused.
    pub fn reset(self: *Stmt) void {
        _ = c.sqlite3_reset(self.handle);
        _ = c.sqlite3_clear_bindings(self.handle);
    }

    pub fn finalize(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.handle);
        self.* = undefined;
    }
};

/// Map a result code onto `Error` by its primary code (the low byte).
fn check(rc: c_int) Error!void {
    if (rc == c.SQLITE_OK) return;
    return switch (rc & 0xff) {
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.Busy,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB => error.Corrupt,
        c.SQLITE_CONSTRAINT => error.Constraint,
        c.SQLITE_NOMEM => error.OutOfMemory,
        else => error.SqliteError,
    };
}

fn bindBytes(stmt: *c.sqlite3_stmt, index: c_int, bytes: []const u8, kind: enum { text, blob }) c_int {
    return switch (kind) {
        .text => c.sqlite3_bind_text64(stmt, index, bytes.ptr, bytes.len, transient, c.SQLITE_UTF8),
        .blob => c.sqlite3_bind_blob64(stmt, index, bytes.ptr, bytes.len, transient),
    };
}

/// Coerce a byte slice or pointer to a byte array to `[]const u8`, rejecting
/// every other pointer type at compile time.
fn textSlice(value: anytype) []const u8 {
    const info = @typeInfo(@TypeOf(value)).pointer;
    switch (info.size) {
        .slice => if (info.child == u8) return value,
        .one => switch (@typeInfo(info.child)) {
            .array => |array| if (array.child == u8) return value,
            else => {},
        },
        else => {},
    }
    @compileError("sqlite: cannot bind a value of type " ++ @typeName(@TypeOf(value)) ++ " as TEXT");
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "library is built multi-thread (THREADSAFE=2)" {
    try testing.expectEqual(@as(c_int, 2), c.sqlite3_threadsafe());
}

test "Db.open creates a file and exec runs multiple statements" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp);
    defer testing.allocator.free(path);

    var db = try Db.open(path, .{});
    defer db.close();
    try db.exec("CREATE TABLE t(a); INSERT INTO t VALUES(1);");

    var stmt = try db.prepare("SELECT count(*) FROM t");
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqual(@as(i64, 1), stmt.columnInt(0));
    try testing.expect(!try stmt.step());

    _ = try std.Io.Dir.cwd().statFile(skim_io.get(), path, .{});
}

test "Stmt.bind round-trips int, bool, text, blob, null and optionals" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp);
    defer testing.allocator.free(path);
    var db = try Db.open(path, .{});
    defer db.close();
    try db.exec("CREATE TABLE t(i, b, s, x, n, oi, os)");

    var insert = try db.prepare("INSERT INTO t VALUES(?,?,?,?,?,?,?)");
    defer insert.finalize();
    try insert.bindAll(.{
        @as(i64, -7),
        true,
        "h\xc3\xa9llo\x00x",
        Blob{ .bytes = &.{ 0, 1, 2 } },
        @as(?[]const u8, null),
        @as(?u32, 42),
        @as(?[]const u8, "opt"),
    });
    try testing.expect(!try insert.step());

    var select = try db.prepare("SELECT i, b, s, x, n, oi, os FROM t");
    defer select.finalize();
    try testing.expect(try select.step());
    try testing.expectEqual(@as(i64, -7), select.columnInt(0));
    try testing.expectEqual(@as(i64, 1), select.columnInt(1));
    try testing.expectEqualStrings("h\xc3\xa9llo\x00x", try select.columnText(2));
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2 }, select.columnBlob(3));
    try testing.expect(select.columnIsNull(4));
    try testing.expectEqual(@as(?[]const u8, null), try select.columnTextOpt(4));
    try testing.expectEqualStrings("", try select.columnText(4));
    try testing.expectEqual(@as(i64, 42), select.columnInt(5));
    try testing.expectEqualStrings("opt", (try select.columnTextOpt(6)).?);
}

test "Stmt.bind stores empty text and empty blobs as empty, not NULL" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp);
    defer testing.allocator.free(path);
    var db = try Db.open(path, .{});
    defer db.close();
    try db.exec("CREATE TABLE t(s NOT NULL, x NOT NULL)");

    var insert = try db.prepare("INSERT INTO t VALUES(?,?)");
    defer insert.finalize();
    try insert.bindAll(.{ "", Blob{ .bytes = "" } });
    try testing.expect(!try insert.step());

    var select = try db.prepare("SELECT s, x FROM t");
    defer select.finalize();
    try testing.expect(try select.step());
    try testing.expectEqualStrings("", (try select.columnTextOpt(0)).?);
    try testing.expect(!select.columnIsNull(1));
    try testing.expectEqual(@as(usize, 0), select.columnBlob(1).len);
}

test "Stmt.reset allows re-binding the same statement" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp);
    defer testing.allocator.free(path);
    var db = try Db.open(path, .{});
    defer db.close();
    try db.exec("CREATE TABLE t(a INTEGER)");

    var insert = try db.prepare("INSERT INTO t VALUES(?)");
    defer insert.finalize();
    for ([_]i64{ 10, 20, 30 }) |value| {
        try insert.bind(1, value);
        try testing.expect(!try insert.step());
        insert.reset();
    }

    var select = try db.prepare("SELECT sum(a), count(*) FROM t");
    defer select.finalize();
    try testing.expect(try select.step());
    try testing.expectEqual(@as(i64, 60), select.columnInt(0));
    try testing.expectEqual(@as(i64, 3), select.columnInt(1));
}

test "Db.begin/rollback discards writes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp);
    defer testing.allocator.free(path);
    var db = try Db.open(path, .{});
    defer db.close();
    try db.exec("CREATE TABLE t(a)");

    try db.begin(.immediate);
    try db.exec("INSERT INTO t VALUES(1)");
    db.rollback();

    try testing.expectEqual(@as(i64, 0), try countRows(&db));
}

test "Db.begin/commit persists writes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp);
    defer testing.allocator.free(path);
    var db = try Db.open(path, .{});
    defer db.close();
    try db.exec("CREATE TABLE t(a)");

    try db.begin(.deferred);
    try db.exec("INSERT INTO t VALUES(1); INSERT INTO t VALUES(2)");
    try db.commit();
    try testing.expectEqual(@as(usize, 1), db.changes());

    var other = try Db.open(path, .{});
    defer other.close();
    try testing.expectEqual(@as(i64, 2), try countRows(&other));
}

test "Db.rollback without an open transaction does not fail" {
    var db = try Db.open(":memory:", .{});
    defer db.close();
    db.rollback();
    try db.exec("SELECT 1");
}

test "Db.lastInsertRowId returns the rowid of the latest insert" {
    var db = try Db.open(":memory:", .{});
    defer db.close();
    try db.exec("CREATE TABLE t(id INTEGER PRIMARY KEY, a); INSERT INTO t(a) VALUES('x'); INSERT INTO t(a) VALUES('y');");
    try testing.expectEqual(@as(i64, 2), db.lastInsertRowId());
}

test "constraint violation maps to error.Constraint" {
    var db = try Db.open(":memory:", .{});
    defer db.close();
    try db.exec("CREATE TABLE t(a PRIMARY KEY); INSERT INTO t VALUES(1);");

    var insert = try db.prepare("INSERT INTO t VALUES(1)");
    defer insert.finalize();
    try testing.expectError(error.Constraint, insert.step());
    try testing.expectError(error.Constraint, db.exec("INSERT INTO t VALUES(1)"));
    try testing.expect(std.mem.indexOf(u8, db.errmsg(), "UNIQUE") != null);
}

test "write lock held by another connection maps to error.Busy" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp);
    defer testing.allocator.free(path);

    var a = try Db.open(path, .{});
    defer a.close();
    try a.exec("CREATE TABLE t(a)");
    var b = try Db.open(path, .{});
    defer b.close();
    try b.exec("PRAGMA busy_timeout=0");

    try a.begin(.immediate);
    defer a.rollback();
    try testing.expectError(error.Busy, b.begin(.immediate));
}

test "opening a non-database file maps to error.Corrupt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp);
    defer testing.allocator.free(path);
    try writeGarbage(path);

    var db = try Db.open(path, .{});
    defer db.close();
    try testing.expectError(error.Corrupt, db.exec("SELECT * FROM sqlite_master"));
}

test "invalid SQL maps to error.SqliteError" {
    var db = try Db.open(":memory:", .{});
    defer db.close();
    try testing.expectError(error.SqliteError, db.prepare("SELEC 1"));
    try testing.expectError(error.SqliteError, db.exec("NOT SQL"));
}

test "prepare rejects SQL with no statement" {
    var db = try Db.open(":memory:", .{});
    defer db.close();
    try testing.expectError(error.SqliteError, db.prepare("  -- nothing"));
}

test "Db.open read_only refuses to create a missing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp);
    defer testing.allocator.free(path);
    try testing.expectError(error.SqliteError, Db.open(path, .{ .read_only = true }));
}

test "userVersion reads PRAGMA user_version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp);
    defer testing.allocator.free(path);
    var db = try Db.open(path, .{});
    defer db.close();

    try testing.expectEqual(@as(u32, 0), try db.userVersion());
    try db.exec("PRAGMA user_version=5");
    try testing.expectEqual(@as(u32, 5), try db.userVersion());
}

/// `<tmp>/test.db` as an absolute, NUL-terminated path. Caller frees.
fn tmpDbPath(tmp: *testing.TmpDir) ![:0]u8 {
    const relative = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/test.db", .{tmp.sub_path});
    defer testing.allocator.free(relative);
    const absolute = try skim_io.absolutePathAlloc(testing.allocator, relative);
    defer testing.allocator.free(absolute);
    return testing.allocator.dupeZ(u8, absolute);
}

fn writeGarbage(path: []const u8) !void {
    const file = try std.Io.Dir.createFileAbsolute(skim_io.get(), path, .{});
    defer file.close(skim_io.get());
    const garbage = [_]u8{0xAB} ** 4096;
    try file.writeStreamingAll(skim_io.get(), &garbage);
}

fn countRows(db: *Db) !i64 {
    var stmt = try db.prepare("SELECT count(*) FROM t");
    defer stmt.finalize();
    _ = try stmt.step();
    return stmt.columnInt(0);
}
