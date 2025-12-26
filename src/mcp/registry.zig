const std = @import("std");
const net = std.net;
const protocol = @import("protocol.zig");
const parser = @import("../git/parser.zig");
const line_resolver = @import("line_resolver.zig");

const Allocator = std.mem.Allocator;

/// Session ID type (UUID string)
pub const SessionId = [36]u8;

/// Information about a connected skim client
pub const ClientInfo = struct {
    id: SessionId,
    stream: net.Stream,
    cwd: []const u8,
    diff_ref: []const u8,
    files: []protocol.FileInfo,
    connected_at: i64,
    last_seen: i64,
    recv_buffer: [262144]u8,  // 256KB to handle large file diffs
    recv_len: usize,

    pub fn deinit(self: *ClientInfo, allocator: Allocator) void {
        allocator.free(self.cwd);
        allocator.free(self.diff_ref);
        for (self.files) |file| {
            allocator.free(file.path);
            allocator.free(file.old_path);
        }
        allocator.free(self.files);
        self.stream.close();
    }
};

/// Registry of connected skim TUI clients
pub const ClientRegistry = struct {
    allocator: Allocator,
    clients: std.AutoHashMap(SessionId, *ClientInfo),

    pub fn init(allocator: Allocator) ClientRegistry {
        return .{
            .allocator = allocator,
            .clients = std.AutoHashMap(SessionId, *ClientInfo).init(allocator),
        };
    }

    pub fn deinit(self: *ClientRegistry) void {
        var it = self.clients.valueIterator();
        while (it.next()) |client_ptr| {
            client_ptr.*.deinit(self.allocator);
            self.allocator.destroy(client_ptr.*);
        }
        self.clients.deinit();
    }

    /// Add a new client to the registry
    pub fn add(self: *ClientRegistry, stream: net.Stream, hello: protocol.HelloPayload) !*ClientInfo {
        const client = try self.allocator.create(ClientInfo);
        errdefer self.allocator.destroy(client);

        // Parse session ID
        var id: SessionId = undefined;
        if (hello.id.len >= 36) {
            @memcpy(&id, hello.id[0..36]);
        } else {
            // Pad with zeros if ID is shorter
            @memset(&id, 0);
            @memcpy(id[0..hello.id.len], hello.id);
        }

        // Duplicate file info
        var files = try self.allocator.alloc(protocol.FileInfo, hello.files.len);
        errdefer self.allocator.free(files);

        for (hello.files, 0..) |file, i| {
            files[i] = .{
                .path = try self.allocator.dupe(u8, file.path),
                .old_path = try self.allocator.dupe(u8, file.old_path),
                .hunk_count = file.hunk_count,
            };
        }

        const now = std.time.timestamp();
        client.* = .{
            .id = id,
            .stream = stream,
            .cwd = try self.allocator.dupe(u8, hello.cwd),
            .diff_ref = try self.allocator.dupe(u8, hello.diff_ref),
            .files = files,
            .connected_at = now,
            .last_seen = now,
            .recv_buffer = undefined,
            .recv_len = 0,
        };

        try self.clients.put(id, client);
        return client;
    }

    /// Remove a client from the registry
    pub fn remove(self: *ClientRegistry, id: SessionId) void {
        if (self.clients.fetchRemove(id)) |entry| {
            entry.value.deinit(self.allocator);
            self.allocator.destroy(entry.value);
        }
    }

    /// Get a client by ID
    pub fn get(self: *ClientRegistry, id: SessionId) ?*ClientInfo {
        return self.clients.get(id);
    }

    /// Get a client by ID string
    pub fn getByIdString(self: *ClientRegistry, id_str: []const u8) ?*ClientInfo {
        if (id_str.len < 36) return null;

        var id: SessionId = undefined;
        @memcpy(&id, id_str[0..36]);
        return self.get(id);
    }

    /// List all connected clients
    pub fn list(self: *ClientRegistry, allocator: Allocator) ![]ClientListEntry {
        // Zig 0.15: ArrayList is unmanaged
        var entries: std.ArrayList(ClientListEntry) = .{};
        errdefer entries.deinit(allocator);

        var it = self.clients.valueIterator();
        while (it.next()) |client_ptr| {
            const client = client_ptr.*;
            try entries.append(allocator, .{
                .id = &client.id,
                .cwd = client.cwd,
                .diff_ref = client.diff_ref,
                .file_count = client.files.len,
                .connected_at = client.connected_at,
            });
        }

        return entries.toOwnedSlice(allocator);
    }

    /// Entry for client listing
    pub const ClientListEntry = struct {
        id: *const SessionId,
        cwd: []const u8,
        diff_ref: []const u8,
        file_count: usize,
        connected_at: i64,
    };

    /// Get count of connected clients
    pub fn count(self: *const ClientRegistry) usize {
        return self.clients.count();
    }

    /// Check if a client exists
    pub fn contains(self: *const ClientRegistry, id: SessionId) bool {
        return self.clients.contains(id);
    }

    /// Update last_seen timestamp for a client
    pub fn touch(self: *ClientRegistry, id: SessionId) void {
        if (self.clients.get(id)) |client| {
            client.last_seen = std.time.timestamp();
        }
    }

    /// Get all client streams for broadcasting
    pub fn getAllStreams(self: *ClientRegistry, allocator: Allocator) ![]net.Stream {
        var streams: std.ArrayList(net.Stream) = .{};
        errdefer streams.deinit(allocator);

        var it = self.clients.valueIterator();
        while (it.next()) |client_ptr| {
            try streams.append(allocator, client_ptr.*.stream);
        }

        return streams.toOwnedSlice(allocator);
    }

    /// Iterator over all clients
    pub fn iterator(self: *ClientRegistry) std.AutoHashMap(SessionId, *ClientInfo).ValueIterator {
        return self.clients.valueIterator();
    }
};

/// Generate a random UUID v4 string
pub fn generateSessionId() SessionId {
    var id: SessionId = undefined;
    var rng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));
    const random = rng.random();

    // Generate random bytes
    var bytes: [16]u8 = undefined;
    random.bytes(&bytes);

    // Set version (4) and variant bits
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // Version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // Variant 1

    // Format as UUID string: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    const hex = "0123456789abcdef";
    var i: usize = 0;
    var pos: usize = 0;

    inline for ([_]usize{ 4, 2, 2, 2, 6 }) |group_len| {
        if (pos > 0) {
            id[pos] = '-';
            pos += 1;
        }
        for (0..group_len) |_| {
            id[pos] = hex[bytes[i] >> 4];
            id[pos + 1] = hex[bytes[i] & 0x0f];
            pos += 2;
            i += 1;
        }
    }

    return id;
}

// =============================================================================
// Tests
// =============================================================================

test "registry add and remove" {
    const allocator = std.testing.allocator;

    var registry = ClientRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 0), registry.count());
}

test "generate session id format" {
    const id = generateSessionId();

    // Check format: 8-4-4-4-12
    try std.testing.expectEqual(@as(u8, '-'), id[8]);
    try std.testing.expectEqual(@as(u8, '-'), id[13]);
    try std.testing.expectEqual(@as(u8, '-'), id[18]);
    try std.testing.expectEqual(@as(u8, '-'), id[23]);

    // Check version (position 14 should be '4')
    try std.testing.expectEqual(@as(u8, '4'), id[14]);
}
