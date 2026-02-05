const std = @import("std");

const Allocator = std.mem.Allocator;

pub const PatchLineKind = enum {
    context,
    add,
    delete,
};

pub const PatchLine = struct {
    kind: PatchLineKind,
    text: []const u8,
};

pub const Hunk = struct {
    lines: []PatchLine,

    pub fn deinit(self: *Hunk, allocator: Allocator) void {
        for (self.lines) |line| {
            allocator.free(line.text);
        }
        allocator.free(self.lines);
    }
};

pub const FilePatch = struct {
    kind: Kind,
    path: []const u8,
    new_path: ?[]const u8 = null,
    hunks: []Hunk,

    pub const Kind = enum {
        add,
        update,
        delete,
    };

    pub fn deinit(self: *FilePatch, allocator: Allocator) void {
        allocator.free(self.path);
        if (self.new_path) |p| allocator.free(p);
        for (self.hunks) |*h| h.deinit(allocator);
        allocator.free(self.hunks);
    }
};

pub const AppliedPatch = struct {
    old_text: []const u8,
    new_text: []const u8,
};

pub fn parseApplyPatch(allocator: Allocator, patch_text: []const u8) ![]FilePatch {
    var files: std.ArrayList(FilePatch) = .{};
    errdefer {
        for (files.items) |*file| file.deinit(allocator);
        files.deinit(allocator);
    }

    var current_kind: ?FilePatch.Kind = null;
    var current_path: ?[]const u8 = null;
    var current_new_path: ?[]const u8 = null;
    var current_hunks: std.ArrayList(Hunk) = .{};
    var current_lines: std.ArrayList(PatchLine) = .{};

    const flush_hunk = struct {
        fn call(alloc: Allocator, hunks: *std.ArrayList(Hunk), lines: *std.ArrayList(PatchLine)) !void {
            if (lines.items.len == 0) return;
            const owned_lines = try lines.toOwnedSlice(alloc);
            try hunks.append(alloc, .{ .lines = owned_lines });
            lines.* = .{};
        }
    };

    const flush_file = struct {
        fn call(
            alloc: Allocator,
            file_list: *std.ArrayList(FilePatch),
            kind: *?FilePatch.Kind,
            path: *?[]const u8,
            new_path: *?[]const u8,
            hunks: *std.ArrayList(Hunk),
            lines: *std.ArrayList(PatchLine),
        ) !void {
            if (kind.* == null or path.* == null) return;
            try flush_hunk.call(alloc, hunks, lines);
            const owned_hunks = try hunks.toOwnedSlice(alloc);
            try file_list.append(alloc, .{
                .kind = kind.*.?,
                .path = path.*.?,
                .new_path = new_path.*,
                .hunks = owned_hunks,
            });
            kind.* = null;
            path.* = null;
            new_path.* = null;
            hunks.* = .{};
        }
    };

    var iter = std.mem.splitScalar(u8, patch_text, '\n');
    while (iter.next()) |raw_line| {
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;

        if (std.mem.startsWith(u8, line, "*** Begin Patch")) {
            continue;
        }
        if (std.mem.startsWith(u8, line, "*** End Patch")) {
            break;
        }
        if (std.mem.startsWith(u8, line, "*** Add File: ")) {
            try flush_file.call(allocator, &files, &current_kind, &current_path, &current_new_path, &current_hunks, &current_lines);
            current_kind = .add;
            current_path = try allocator.dupe(u8, line[14..]);
            continue;
        }
        if (std.mem.startsWith(u8, line, "*** Update File: ")) {
            try flush_file.call(allocator, &files, &current_kind, &current_path, &current_new_path, &current_hunks, &current_lines);
            current_kind = .update;
            current_path = try allocator.dupe(u8, line[17..]);
            continue;
        }
        if (std.mem.startsWith(u8, line, "*** Delete File: ")) {
            try flush_file.call(allocator, &files, &current_kind, &current_path, &current_new_path, &current_hunks, &current_lines);
            current_kind = .delete;
            current_path = try allocator.dupe(u8, line[17..]);
            continue;
        }
        if (std.mem.startsWith(u8, line, "*** Move to: ")) {
            if (current_path != null) {
                current_new_path = try allocator.dupe(u8, line[13..]);
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "@@")) {
            try flush_hunk.call(allocator, &current_hunks, &current_lines);
            continue;
        }

        if (current_kind == null or current_path == null) continue;
        if (line.len == 0) continue;

        const prefix = line[0];
        const text = if (line.len > 1) line[1..] else "";

        const kind = switch (prefix) {
            ' ' => PatchLineKind.context,
            '+' => PatchLineKind.add,
            '-' => PatchLineKind.delete,
            else => continue,
        };

        const owned_text = try allocator.dupe(u8, text);
        try current_lines.append(allocator, .{ .kind = kind, .text = owned_text });
    }

    try flush_file.call(allocator, &files, &current_kind, &current_path, &current_new_path, &current_hunks, &current_lines);

    return files.toOwnedSlice(allocator);
}

pub fn applyFilePatch(allocator: Allocator, cwd: ?[]const u8, patch: FilePatch) !AppliedPatch {
    const old_text = if (patch.kind == .add)
        try allocator.dupe(u8, "")
    else
        try readFileContent(allocator, cwd, patch.path);

    if (patch.kind == .delete) {
        const new_text = try allocator.dupe(u8, "");
        return .{ .old_text = old_text, .new_text = new_text };
    }

    if (patch.kind == .add) {
        const new_text = try joinPatchLines(allocator, patch.hunks, .add);
        return .{ .old_text = old_text, .new_text = new_text };
    }

    const new_text = try applyHunks(allocator, old_text, patch.hunks);
    return .{ .old_text = old_text, .new_text = new_text };
}

fn readFileContent(allocator: Allocator, cwd: ?[]const u8, path: []const u8) ![]const u8 {
    var file: std.fs.File = undefined;

    if (std.fs.path.isAbsolute(path)) {
        file = try std.fs.openFileAbsolute(path, .{});
    } else if (cwd) |base| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, path });
        defer allocator.free(full_path);
        file = try std.fs.openFileAbsolute(full_path, .{});
    } else {
        file = try std.fs.cwd().openFile(path, .{});
    }
    defer file.close();

    return try file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

fn splitLines(allocator: Allocator, text: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .{};
    errdefer lines.deinit(allocator);

    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line| {
        try lines.append(allocator, line);
    }
    return lines.toOwnedSlice(allocator);
}

fn joinLines(allocator: Allocator, lines: []const []const u8) ![]const u8 {
    if (lines.len == 0) return allocator.dupe(u8, "");

    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);

    for (lines, 0..) |line, idx| {
        if (idx > 0) try output.append(allocator, '\n');
        try output.appendSlice(allocator, line);
    }

    return output.toOwnedSlice(allocator);
}

fn joinPatchLines(allocator: Allocator, hunks: []const Hunk, include_kind: PatchLineKind) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .{};
    errdefer lines.deinit(allocator);

    for (hunks) |hunk| {
        for (hunk.lines) |line| {
            if (line.kind == include_kind) {
                try lines.append(allocator, line.text);
            }
        }
    }

    const joined = try joinLines(allocator, lines.items);
    lines.deinit(allocator);
    return joined;
}

fn applyHunks(allocator: Allocator, old_text: []const u8, hunks: []const Hunk) ![]const u8 {
    var old_lines = try splitLines(allocator, old_text);
    defer allocator.free(old_lines);

    var output_lines: std.ArrayList([]const u8) = .{};
    errdefer output_lines.deinit(allocator);

    var search_start: usize = 0;

    for (hunks) |hunk| {
        var hunk_old: std.ArrayList([]const u8) = .{};
        defer hunk_old.deinit(allocator);
        var hunk_new: std.ArrayList([]const u8) = .{};
        defer hunk_new.deinit(allocator);

        for (hunk.lines) |line| {
            switch (line.kind) {
                .context => {
                    try hunk_old.append(allocator, line.text);
                    try hunk_new.append(allocator, line.text);
                },
                .delete => try hunk_old.append(allocator, line.text),
                .add => try hunk_new.append(allocator, line.text),
            }
        }

        const pos = findHunkStart(old_lines, search_start, hunk_old.items) orelse return error.HunkNotFound;

        try output_lines.appendSlice(allocator, old_lines[search_start..pos]);
        try output_lines.appendSlice(allocator, hunk_new.items);

        search_start = pos + hunk_old.items.len;
    }

    if (search_start < old_lines.len) {
        try output_lines.appendSlice(allocator, old_lines[search_start..]);
    }

    const joined = try joinLines(allocator, output_lines.items);
    output_lines.deinit(allocator);
    return joined;
}

fn findHunkStart(haystack: []const []const u8, start_idx: usize, needle: []const []const u8) ?usize {
    if (needle.len == 0) return start_idx;
    if (start_idx >= haystack.len) return null;
    if (needle.len > haystack.len - start_idx) return null;

    var idx: usize = start_idx;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        var matches = true;
        for (needle, 0..) |line, offset| {
            if (!std.mem.eql(u8, haystack[idx + offset], line)) {
                matches = false;
                break;
            }
        }
        if (matches) return idx;
    }

    return null;
}

test "parse apply_patch with update" {
    const allocator = std.testing.allocator;
    const patch_text =
        "*** Begin Patch\n" ++
        "*** Update File: test.txt\n" ++
        "@@\n" ++
        "-old\n" ++
        "+new\n" ++
        "*** End Patch\n";

    const files = try parseApplyPatch(allocator, patch_text);
    defer {
        for (files) |*file| file.deinit(allocator);
        allocator.free(files);
    }

    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqual(FilePatch.Kind.update, files[0].kind);
    try std.testing.expectEqualStrings("test.txt", files[0].path);
}

test "apply patch add file" {
    const allocator = std.testing.allocator;
    const patch_text =
        "*** Begin Patch\n" ++
        "*** Add File: new.txt\n" ++
        "+hello\n" ++
        "+world\n" ++
        "*** End Patch\n";

    const files = try parseApplyPatch(allocator, patch_text);
    defer {
        for (files) |*file| file.deinit(allocator);
        allocator.free(files);
    }

    const applied = try applyFilePatch(allocator, null, files[0]);
    defer allocator.free(applied.old_text);
    defer allocator.free(applied.new_text);

    try std.testing.expectEqualStrings("hello\nworld", applied.new_text);
}
