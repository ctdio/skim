//! Process-wide `std.Io` and environment access.
//!
//! Zig 0.16 moved file, process, and synchronization primitives behind an `Io`
//! value that every operation takes as a parameter, and `std.process.Init` hands
//! that value (plus the environment block) to `main`. Threading both through
//! every signature in skim would touch several hundred call sites for no design
//! benefit, so executables stash them here via `init` and every subsystem reaches
//! them through `get`/`environ` -- the same shape `std.testing` uses.
//!
//! Test binaries are served by the test runner's instance instead, so unit tests
//! need no setup.

const builtin = @import("builtin");
const std = @import("std");

var io_instance: std.Io = undefined;
var environ_instance: std.process.Environ = undefined;
var environ_map_instance: *std.process.Environ.Map = undefined;

/// Adopt the runtime-provided I/O implementation and environment. Every
/// executable must call this before any subsystem touches the filesystem,
/// spawns a process, or takes a lock.
pub fn init(process_init: std.process.Init) void {
    io_instance = process_init.io;
    environ_instance = process_init.minimal.environ;
    environ_map_instance = process_init.environ_map;
}

pub fn get() std.Io {
    if (builtin.is_test) return std.testing.io;
    return io_instance;
}

pub fn environ() std.process.Environ {
    if (builtin.is_test) return std.testing.environ;
    return environ_instance;
}

/// The parsed environment vaxis wants a handle on. The test runner has no
/// equivalent, so test binaries get an empty map instead.
pub fn environMap() *std.process.Environ.Map {
    if (builtin.is_test) {
        if (test_environ_map == null) test_environ_map = .init(std.heap.page_allocator);
        return &test_environ_map.?;
    }
    return environ_map_instance;
}

var test_environ_map: ?std.process.Environ.Map = null;

/// Borrowed environment lookup. Replaces 0.15's `std.posix.getenv`, which 0.16
/// removed along with the rest of the process-global environment access.
pub fn getEnv(key: []const u8) ?[:0]const u8 {
    return environ().getPosix(key);
}

/// Replacement for 0.15's `std.process.getEnvVarOwned`. Caller owns the result.
pub fn getEnvVarOwned(gpa: std.mem.Allocator, key: []const u8) std.process.Environ.GetAllocError![]u8 {
    return environ().getAlloc(gpa, key);
}

/// Replaces 0.15's `File.readToEndAlloc`, which 0.16 folded into `Io.Reader`.
/// Reads from the file's current position to EOF. Caller owns the result.
pub fn readAllAlloc(file: std.Io.File, gpa: std.mem.Allocator, max_bytes: usize) ![]u8 {
    var stage: [4096]u8 = undefined;
    var file_reader = file.readerStreaming(get(), &stage);
    return file_reader.interface.allocRemaining(gpa, .limited(max_bytes));
}

/// Toggle `O_NONBLOCK` on a descriptor. 0.16 removed `std.posix.fcntl`, and the
/// non-blocking flag is the only thing skim ever used it for, so this goes
/// straight to libc.
pub fn setNonBlocking(handle: std.posix.fd_t, nonblocking: bool) !void {
    const o_nonblock: c_int = @bitCast(@as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
    const flags = std.c.fcntl(handle, std.posix.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    const updated = if (nonblocking) flags | o_nonblock else flags & ~o_nonblock;
    if (std.c.fcntl(handle, std.posix.F.SETFL, updated) < 0) return error.FcntlFailed;
}

/// Absolute path for `path`, resolved against the current working directory.
/// Replaces 0.15's `Dir.realpathAlloc`, which 0.16 removed along with the rest
/// of `std.fs`; symlinks are left unresolved, which is all the `file://` URIs
/// this feeds need. Caller owns the result.
pub fn absolutePathAlloc(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(gpa, &.{path});

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.c.getcwd(&buf, buf.len) == null) return error.CurrentWorkingDirectoryUnlinked;
    return std.fs.path.resolve(gpa, &.{ std.mem.sliceTo(&buf, 0), path });
}

/// One blocking read from a file or pipe. Replaces 0.15's `File.read`, which
/// 0.16 folded into `Io.Reader`. Returns 0 at end of stream.
pub fn readFile(file: std.Io.File, buffer: []u8) !usize {
    var dest: [1][]u8 = .{buffer};
    return file.readStreaming(get(), &dest);
}

/// An append-only file. 0.16 dropped `File.seek`, so the write offset is
/// tracked here and advanced on every write. Callers serialize their own access.
pub const AppendFile = struct {
    file: std.Io.File,
    offset: u64,

    /// Opens `path` (creating it if absent) positioned at end of file.
    pub fn open(path: []const u8) !AppendFile {
        const file = try std.Io.Dir.createFileAbsolute(get(), path, .{ .truncate = false });
        errdefer file.close(get());
        const info = try file.stat(get());
        return .{ .file = file, .offset = info.size };
    }

    pub fn write(self: *AppendFile, bytes: []const u8) !void {
        try self.file.writePositionalAll(get(), bytes, self.offset);
        self.offset += bytes.len;
    }

    pub fn close(self: *AppendFile) void {
        self.file.close(get());
    }
};

/// Replaces `std.Thread.sleep`, which 0.16 moved onto `Io`.
pub fn sleep(nanoseconds: u64) void {
    std.Io.sleep(get(), .{ .nanoseconds = @intCast(nanoseconds) }, .awake) catch {};
}

/// Wall-clock seconds since the Unix epoch. Replaces `std.time.timestamp`.
pub fn timestamp() i64 {
    return std.Io.Timestamp.now(get(), .real).toSeconds();
}

/// Replaces `std.time.milliTimestamp`.
pub fn milliTimestamp() i64 {
    return std.Io.Timestamp.now(get(), .real).toMilliseconds();
}

/// Replaces `std.time.nanoTimestamp`.
pub fn nanoTimestamp() i96 {
    return std.Io.Timestamp.now(get(), .real).toNanoseconds();
}

/// Monotonic stopwatch replacing `std.time.Timer`, which 0.16 removed in favour
/// of `std.Io.Timestamp`. `start` keeps an (empty) error set so the many
/// `Timer.start() catch null` profiling call sites read exactly as before.
pub const Timer = struct {
    started: std.Io.Timestamp,

    pub fn start() error{}!Timer {
        return .{ .started = .now(get(), .awake) };
    }

    /// Nanoseconds elapsed since `start` or the last `reset`.
    pub fn read(self: *Timer) u64 {
        const elapsed = self.started.durationTo(.now(get(), .awake)).nanoseconds;
        return if (elapsed < 0) 0 else @intCast(elapsed);
    }

    pub fn reset(self: *Timer) void {
        self.started = .now(get(), .awake);
    }

    pub fn lap(self: *Timer) u64 {
        const elapsed = self.read();
        self.reset();
        return elapsed;
    }
};
