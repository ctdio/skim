//! Loopback TCP sockets for the MCP server and its clients.
//!
//! Zig 0.16's `std.Io.net` assumes blocking descriptors driven by green
//! threads: every implementation treats `EAGAIN` as a programmer bug rather
//! than a condition to report. skim's MCP server instead polls `O_NONBLOCK`
//! sockets from the TUI event loop, so this module talks to libc directly and
//! surfaces `WouldBlock` to its callers.

const std = @import("std");

const posix = std.posix;

pub const ReadError = error{
    WouldBlock,
    ConnectionResetByPeer,
    BrokenPipe,
    SystemResources,
    Unexpected,
};

pub const WriteError = ReadError;

pub const AcceptError = error{
    WouldBlock,
    ConnectionAborted,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    Unexpected,
};

pub const ListenError = error{
    AddressInUse,
    PermissionDenied,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    Unexpected,
};

pub const ConnectError = error{
    ConnectionRefused,
    ConnectionResetByPeer,
    PermissionDenied,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    Timeout,
    Unexpected,
};

/// A connected TCP socket.
pub const Stream = struct {
    handle: posix.socket_t,

    /// Returns 0 at end of stream. Fails with `WouldBlock` when the socket is
    /// non-blocking and no data is ready.
    pub fn read(self: Stream, buffer: []u8) ReadError!usize {
        while (true) {
            const rc = std.c.read(self.handle, buffer.ptr, buffer.len);
            if (rc >= 0) return @intCast(rc);
            switch (posix.errno(rc)) {
                .INTR => continue,
                else => |err| return transferError(err),
            }
        }
    }

    pub fn writeAll(self: Stream, bytes: []const u8) WriteError!void {
        var index: usize = 0;
        while (index < bytes.len) {
            const rc = std.c.write(self.handle, bytes.ptr + index, bytes.len - index);
            if (rc >= 0) {
                index += @intCast(rc);
                continue;
            }
            switch (posix.errno(rc)) {
                .INTR => continue,
                else => |err| return transferError(err),
            }
        }
    }

    pub fn close(self: Stream) void {
        _ = std.c.close(self.handle);
    }
};

/// A listening TCP socket bound to the loopback interface.
pub const Server = struct {
    handle: posix.socket_t,
    /// Resolved after bind, so a caller that asked for port 0 can read the
    /// ephemeral port the kernel picked.
    port: u16,

    /// Fails with `WouldBlock` when the listener is non-blocking and no
    /// connection is pending.
    pub fn accept(self: *Server) AcceptError!Stream {
        while (true) {
            const rc = std.c.accept(self.handle, null, null);
            if (rc >= 0) return .{ .handle = rc };
            switch (posix.errno(rc)) {
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .CONNABORTED => return error.ConnectionAborted,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOBUFS, .NOMEM => return error.SystemResources,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }

    pub fn deinit(self: *Server) void {
        _ = std.c.close(self.handle);
        self.* = undefined;
    }
};

/// Bind and listen on 127.0.0.1. Pass port 0 to let the kernel choose one and
/// read it back from `Server.port`.
pub fn listenLoopback(port: u16) ListenError!Server {
    const handle = std.c.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    if (handle < 0) return socketError(posix.errno(handle));
    errdefer _ = std.c.close(handle);

    const enable: c_int = 1;
    _ = std.c.setsockopt(handle, posix.SOL.SOCKET, posix.SO.REUSEADDR, &enable, @sizeOf(c_int));

    var addr = loopbackAddress(port);
    if (std.c.bind(handle, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) < 0) {
        return switch (posix.errno(@as(c_int, -1))) {
            .ADDRINUSE, .ADDRNOTAVAIL => error.AddressInUse,
            .ACCES => error.PermissionDenied,
            else => |err| posix.unexpectedErrno(err),
        };
    }
    if (std.c.listen(handle, 128) < 0) {
        return switch (posix.errno(@as(c_int, -1))) {
            .ADDRINUSE => error.AddressInUse,
            else => |err| posix.unexpectedErrno(err),
        };
    }

    var bound: posix.sockaddr.in = undefined;
    var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    if (std.c.getsockname(handle, @ptrCast(&bound), &bound_len) < 0) return error.Unexpected;

    return .{ .handle = handle, .port = std.mem.bigToNative(u16, bound.port) };
}

/// Connect to 127.0.0.1 on `port`.
pub fn connectLoopback(port: u16) ConnectError!Stream {
    const handle = std.c.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    if (handle < 0) return switch (posix.errno(handle)) {
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => error.SystemResources,
        .ACCES, .PERM => error.PermissionDenied,
        else => |err| posix.unexpectedErrno(err),
    };
    errdefer _ = std.c.close(handle);

    var addr = loopbackAddress(port);
    while (true) {
        if (std.c.connect(handle, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) >= 0) {
            return .{ .handle = handle };
        }
        switch (posix.errno(@as(c_int, -1))) {
            .INTR => continue,
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .ACCES, .PERM => return error.PermissionDenied,
            .TIMEDOUT => return error.Timeout,
            .NOBUFS, .NOMEM => return error.SystemResources,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn loopbackAddress(port: u16) posix.sockaddr.in {
    return .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f00_0001),
    };
}

fn transferError(err: posix.E) ReadError {
    return switch (err) {
        .AGAIN => error.WouldBlock,
        .CONNRESET, .NOTCONN => error.ConnectionResetByPeer,
        .PIPE => error.BrokenPipe,
        .NOBUFS, .NOMEM => error.SystemResources,
        else => |e| posix.unexpectedErrno(e),
    };
}

fn socketError(err: posix.E) ListenError {
    return switch (err) {
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => error.SystemResources,
        .ACCES, .PERM => error.PermissionDenied,
        else => |e| posix.unexpectedErrno(e),
    };
}
