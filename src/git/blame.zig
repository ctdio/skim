const std = @import("std");

const Allocator = std.mem.Allocator;

/// Blame information for a single line
pub const BlameLine = struct {
    commit_hash: [8]u8, // Short hash (8 chars)
    author: []const u8, // Author name (owned)
    username: []const u8, // Username from email (owned, empty if same as author or not available)
    summary: []const u8, // Commit message first line (owned)
    timestamp: i64, // Unix timestamp
    original_lineno: u32, // Line number in original commit

    pub fn deinit(self: *BlameLine, allocator: Allocator) void {
        allocator.free(self.author);
        if (self.username.len > 0) allocator.free(self.username);
        if (self.summary.len > 0) allocator.free(self.summary);
    }
};

/// Blame data for an entire file
pub const BlameData = struct {
    lines: []BlameLine, // Blame info indexed by 1-based line number
    allocator: Allocator,

    pub fn deinit(self: *BlameData) void {
        for (self.lines) |*line| {
            line.deinit(self.allocator);
        }
        self.allocator.free(self.lines);
    }

    /// Get blame info for a line (1-based line number)
    pub fn getLine(self: *const BlameData, lineno: u32) ?*const BlameLine {
        if (lineno == 0 or lineno > self.lines.len) return null;
        return &self.lines[lineno - 1];
    }
};

/// Get blame data for a file
/// For new files (additions), we blame against HEAD
/// For deleted lines, we blame against the parent commit
pub fn getBlame(allocator: Allocator, file_path: []const u8, ref: ?[]const u8) !BlameData {
    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    try args.append("git");
    try args.append("blame");
    try args.append("--porcelain");

    // If a ref is specified, blame at that ref
    if (ref) |r| {
        try args.append(r);
        try args.append("--");
    }

    try args.append(file_path);

    var child = std.process.Child.init(args.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 50 * 1024 * 1024); // 50MB limit
    errdefer allocator.free(stdout);

    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1 * 1024 * 1024);
    defer allocator.free(stderr);

    const term = try child.wait();

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                allocator.free(stdout);
                return error.GitCommandFailed;
            }
        },
        else => {
            allocator.free(stdout);
            return error.GitCommandFailed;
        },
    }

    defer allocator.free(stdout);
    return parseBlameOutput(allocator, stdout);
}

/// Parse git blame --porcelain output
/// Format:
/// <sha1> <orig-line> <final-line> [<num-lines>]
/// author <author-name>
/// author-mail <author-mail>
/// author-time <timestamp>
/// ...
/// \t<line-content>
fn parseBlameOutput(allocator: Allocator, output: []const u8) !BlameData {
    var lines_list = std.ArrayList(BlameLine).init(allocator);
    errdefer {
        for (lines_list.items) |*line| {
            line.deinit(allocator);
        }
        lines_list.deinit();
    }

    // Track commit info by hash (commits can be referenced multiple times)
    // Keys are owned strings that must be freed
    var commit_authors = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = commit_authors.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        commit_authors.deinit();
    }

    var commit_usernames = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = commit_usernames.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        commit_usernames.deinit();
    }

    var commit_summaries = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = commit_summaries.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        commit_summaries.deinit();
    }

    var commit_times = std.StringHashMap(i64).init(allocator);
    defer {
        var iter = commit_times.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        commit_times.deinit();
    }

    var lines_iter = std.mem.splitScalar(u8, output, '\n');

    var current_commit: ?[40]u8 = null;
    var current_author: ?[]const u8 = null;
    var current_username: ?[]const u8 = null;
    var current_summary: ?[]const u8 = null;
    var current_time: i64 = 0;
    var current_orig_lineno: u32 = 0;

    while (lines_iter.next()) |line| {
        if (line.len == 0) continue;

        // Line starting with tab is the actual source line content (end of entry)
        if (line[0] == '\t') {
            if (current_commit) |commit| {
                var short_hash: [8]u8 = undefined;
                @memcpy(&short_hash, commit[0..8]);
                const commit_slice = commit[0..40];

                // Get author from cache or current
                const author = blk: {
                    if (current_author) |a| {
                        break :blk try allocator.dupe(u8, a);
                    }
                    if (commit_authors.get(commit_slice)) |cached| {
                        break :blk try allocator.dupe(u8, cached);
                    }
                    break :blk try allocator.dupe(u8, "unknown");
                };
                errdefer allocator.free(author);

                // Get username from cache or current
                const username = blk: {
                    if (current_username) |u| {
                        break :blk try allocator.dupe(u8, u);
                    }
                    if (commit_usernames.get(commit_slice)) |cached| {
                        break :blk try allocator.dupe(u8, cached);
                    }
                    break :blk try allocator.dupe(u8, "");
                };
                errdefer if (username.len > 0) allocator.free(username);

                // Get summary from cache or current
                const summary = blk: {
                    if (current_summary) |s| {
                        break :blk try allocator.dupe(u8, s);
                    }
                    if (commit_summaries.get(commit_slice)) |cached| {
                        break :blk try allocator.dupe(u8, cached);
                    }
                    break :blk try allocator.dupe(u8, "");
                };
                errdefer if (summary.len > 0) allocator.free(summary);

                // Get time from cache or current
                const time = blk: {
                    if (current_time != 0) break :blk current_time;
                    break :blk commit_times.get(commit_slice) orelse 0;
                };

                try lines_list.append(.{
                    .commit_hash = short_hash,
                    .author = author,
                    .username = username,
                    .summary = summary,
                    .timestamp = time,
                    .original_lineno = current_orig_lineno,
                });

                current_author = null;
                current_username = null;
                current_summary = null;
                current_time = 0;
            }
            continue;
        }

        // Parse header line: <sha1> <orig-line> <final-line> [<num-lines>]
        if (line.len >= 40 and isHexChar(line[0])) {
            var parts = std.mem.tokenizeScalar(u8, line, ' ');
            const hash_str = parts.next() orelse continue;
            if (hash_str.len != 40) continue;

            var commit_buf: [40]u8 = undefined;
            @memcpy(&commit_buf, hash_str[0..40]);
            current_commit = commit_buf;

            const orig_lineno_str = parts.next() orelse continue;
            current_orig_lineno = std.fmt.parseInt(u32, orig_lineno_str, 10) catch continue;
            continue;
        }

        // Parse author line
        if (std.mem.startsWith(u8, line, "author ")) {
            const author_name = line[7..];
            current_author = author_name;

            // Cache it for this commit
            if (current_commit) |commit| {
                const commit_slice = commit[0..40];
                if (!commit_authors.contains(commit_slice)) {
                    const key = try allocator.dupe(u8, commit_slice);
                    errdefer allocator.free(key);
                    const val = try allocator.dupe(u8, author_name);
                    try commit_authors.put(key, val);
                }
            }
            continue;
        }

        // Parse author-mail line (extract username from email)
        if (std.mem.startsWith(u8, line, "author-mail ")) {
            const mail = line[12..];
            // Extract username from email like "<user@example.com>" or "<user+noreply@github.com>"
            const username = extractUsername(mail);
            if (username.len > 0) {
                current_username = username;

                // Cache it for this commit
                if (current_commit) |commit| {
                    const commit_slice = commit[0..40];
                    if (!commit_usernames.contains(commit_slice)) {
                        const key = try allocator.dupe(u8, commit_slice);
                        errdefer allocator.free(key);
                        const val = try allocator.dupe(u8, username);
                        try commit_usernames.put(key, val);
                    }
                }
            }
            continue;
        }

        // Parse author-time line
        if (std.mem.startsWith(u8, line, "author-time ")) {
            const time_str = line[12..];
            current_time = std.fmt.parseInt(i64, time_str, 10) catch 0;

            // Cache it for this commit
            if (current_commit) |commit| {
                const commit_slice = commit[0..40];
                if (!commit_times.contains(commit_slice)) {
                    try commit_times.put(try allocator.dupe(u8, commit_slice), current_time);
                }
            }
            continue;
        }

        // Parse summary line (commit message first line)
        if (std.mem.startsWith(u8, line, "summary ")) {
            const summary = line[8..];
            current_summary = summary;

            // Cache it for this commit
            if (current_commit) |commit| {
                const commit_slice = commit[0..40];
                if (!commit_summaries.contains(commit_slice)) {
                    const key = try allocator.dupe(u8, commit_slice);
                    errdefer allocator.free(key);
                    const val = try allocator.dupe(u8, summary);
                    try commit_summaries.put(key, val);
                }
            }
            continue;
        }
    }

    return BlameData{
        .lines = try lines_list.toOwnedSlice(),
        .allocator = allocator,
    };
}

fn isHexChar(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// Extract username from email like "<user@example.com>" or "<12345+username@users.noreply.github.com>"
fn extractUsername(mail: []const u8) []const u8 {
    // Remove angle brackets
    var email = mail;
    if (email.len > 0 and email[0] == '<') {
        email = email[1..];
    }
    if (email.len > 0 and email[email.len - 1] == '>') {
        email = email[0 .. email.len - 1];
    }

    // Find @ symbol
    const at_pos = std.mem.indexOf(u8, email, "@") orelse return "";

    var username = email[0..at_pos];

    // Handle GitHub noreply format: "12345+username@users.noreply.github.com"
    if (std.mem.indexOf(u8, username, "+")) |plus_pos| {
        username = username[plus_pos + 1 ..];
    }

    return username;
}

/// Format author name for display (truncate to max width)
pub fn formatAuthor(author: []const u8, max_width: usize) []const u8 {
    if (author.len <= max_width) return author;
    return author[0..max_width];
}

/// Format date from timestamp as "Mon DD YYYY" (e.g., "Jan 15 2024")
pub fn formatDate(buf: []u8, timestamp: i64) []const u8 {
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    // Convert unix timestamp to date components
    // Days since epoch (Jan 1, 1970)
    const secs_per_day: i64 = 86400;
    var days = @divTrunc(timestamp, secs_per_day);

    // Adjust for negative timestamps
    if (timestamp < 0 and @rem(timestamp, secs_per_day) != 0) {
        days -= 1;
    }

    // Calculate year, month, day from days since epoch
    var year: i32 = 1970;
    var remaining_days = days;

    // Fast-forward years
    while (true) {
        const days_in_year: i64 = if (isLeapYear(year)) 366 else 365;
        if (remaining_days < days_in_year) break;
        remaining_days -= days_in_year;
        year += 1;
    }

    // Handle negative remaining days (dates before 1970)
    while (remaining_days < 0) {
        year -= 1;
        const days_in_year: i64 = if (isLeapYear(year)) 366 else 365;
        remaining_days += days_in_year;
    }

    // Calculate month and day
    const days_in_months = if (isLeapYear(year))
        [_]i64{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: usize = 0;
    while (month < 12 and remaining_days >= days_in_months[month]) {
        remaining_days -= days_in_months[month];
        month += 1;
    }

    const day = remaining_days + 1; // Days are 1-indexed

    // Format as "Mon DD YYYY"
    return std.fmt.bufPrint(buf, "{s} {:2} {}", .{ month_names[month], day, year }) catch "?";
}

/// Format relative time from timestamp (short form)
pub fn formatRelativeTime(buf: []u8, timestamp: i64) []const u8 {
    const now = std.time.timestamp();
    const diff = now - timestamp;

    if (diff < 0) {
        return std.fmt.bufPrint(buf, "future", .{}) catch "?";
    }

    const minutes = @divTrunc(diff, 60);
    const hours = @divTrunc(diff, 3600);
    const days = @divTrunc(diff, 86400);
    const weeks = @divTrunc(diff, 604800);
    const months = @divTrunc(diff, 2592000);
    const years = @divTrunc(diff, 31536000);

    if (years > 0) {
        return std.fmt.bufPrint(buf, "{d}y", .{years}) catch "?";
    } else if (months > 0) {
        return std.fmt.bufPrint(buf, "{d}mo", .{months}) catch "?";
    } else if (weeks > 0) {
        return std.fmt.bufPrint(buf, "{d}w", .{weeks}) catch "?";
    } else if (days > 0) {
        return std.fmt.bufPrint(buf, "{d}d", .{days}) catch "?";
    } else if (hours > 0) {
        return std.fmt.bufPrint(buf, "{d}h", .{hours}) catch "?";
    } else if (minutes > 0) {
        return std.fmt.bufPrint(buf, "{d}m", .{minutes}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "now", .{}) catch "?";
    }
}

fn isLeapYear(year: i32) bool {
    if (@rem(year, 400) == 0) return true;
    if (@rem(year, 100) == 0) return false;
    if (@rem(year, 4) == 0) return true;
    return false;
}
