const std = @import("std");

const Allocator = std.mem.Allocator;

/// List of known terminal-based editors
const TERMINAL_EDITORS = [_][]const u8{
    "vim",
    "nvim",
    "vi",
    "nano",
    "emacs",
    "emacs -nw",
    "micro",
    "helix",
    "hx",
    "joe",
    "mcedit",
    "ed",
};

const LineArgumentMode = enum {
    none,
    plus,
    goto_flag,
    embed_colon,
};

const CommandAnalysis = struct {
    mode: LineArgumentMode,
    uses_open: bool,
    has_args_separator: bool,
};

/// Determine if the editor command is terminal-based
pub fn isTerminalEditor(editor_cmd: []const u8) bool {
    // Check if the editor command starts with any of the known terminal editors
    for (TERMINAL_EDITORS) |term_editor| {
        if (std.mem.startsWith(u8, editor_cmd, term_editor)) {
            return true;
        }
    }

    // Check for common flags that indicate terminal mode
    if (std.mem.indexOf(u8, editor_cmd, "-nw") != null or
        std.mem.indexOf(u8, editor_cmd, "--nw") != null or
        std.mem.indexOf(u8, editor_cmd, "-t") != null or
        std.mem.indexOf(u8, editor_cmd, "--terminal") != null)
    {
        return true;
    }

    return false;
}

/// Check if current editor is terminal-based (for external use)
pub fn isCurrentEditorTerminal(allocator: Allocator) !bool {
    const editor_cmd = try getEditorCommand(allocator);
    defer allocator.free(editor_cmd);
    return isTerminalEditor(editor_cmd);
}

/// Get the editor command from environment variables
/// Priority: EDITOR -> VISUAL -> "vi"
fn getEditorCommand(allocator: Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "EDITOR")) |editor| {
        return editor;
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "VISUAL")) |visual| {
        return visual;
    } else |_| {}

    // Default to vi
    return try allocator.dupe(u8, "vi");
}

/// Open a file in the user's editor
/// If is_terminal_editor is true, the editor will be opened in the current terminal
/// If line_number is provided, attempt to open the file at that line
pub fn openInEditor(
    allocator: Allocator,
    file_path: []const u8,
    line_number: ?usize,
) !void {
    const editor_cmd = try getEditorCommand(allocator);
    defer allocator.free(editor_cmd);

    const is_terminal = isTerminalEditor(editor_cmd);

    // Build the command with arguments
    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    var allocated_args = std.ArrayList([]u8).init(allocator);
    defer {
        for (allocated_args.items) |allocated| {
            allocator.free(allocated);
        }
        allocated_args.deinit();
    }

    // Split editor command in case it contains flags
    var cmd_iter = std.mem.splitScalar(u8, editor_cmd, ' ');
    while (cmd_iter.next()) |part| {
        if (part.len > 0) {
            try args.append(part);
        }
    }

    const analysis = analyzeEditorArgs(args.items);
    var appended_args_separator = analysis.has_args_separator;

    // Add line number argument if supported and provided
    var line_arg_buffer: [32]u8 = undefined;
    var file_arg_appended = false;

    if (line_number) |raw_line| {
        if (args.items.len > 0) {
            const line_to_use: usize = if (raw_line == 0) 1 else raw_line;
            if (analysis.uses_open and !appended_args_separator) {
                try args.append("--args");
                appended_args_separator = true;
            }

            switch (analysis.mode) {
                .plus => {
                    const plus_arg = try std.fmt.bufPrint(&line_arg_buffer, "+{d}", .{line_to_use});
                    try args.append(plus_arg);
                },
                .goto_flag => {
                    try args.append("--goto");
                    const goto_arg = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ file_path, line_to_use });
                    try allocated_args.append(goto_arg);
                    try args.append(goto_arg);
                    file_arg_appended = true;
                },
                .embed_colon => {
                    const colon_arg = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ file_path, line_to_use });
                    try allocated_args.append(colon_arg);
                    try args.append(colon_arg);
                    file_arg_appended = true;
                },
                .none => {},
            }
        }
    }

    // Add the file path if it hasn't already been embedded alongside --goto or colon syntax
    if (!file_arg_appended) {
        try args.append(file_path);
    }

    // Debug: log the command being executed
    if (line_number) |line| {
        std.log.debug("Opening editor at line {d}: {s}", .{ line, file_path });
    } else {
        std.log.debug("Opening editor (no line number): {s}", .{file_path});
    }
    std.log.debug("Full command: ", .{});
    for (args.items, 0..) |arg, i| {
        std.log.debug("  args[{d}] = '{s}'", .{ i, arg });
    }

    // Spawn the editor process
    var child = std.process.Child.init(args.items, allocator);

    if (is_terminal) {
        // Terminal editor: inherit stdin/stdout/stderr for interactive use
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
    } else {
        // GUI editor: detach from terminal
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
    }

    try child.spawn();

    // Wait for terminal editors, but don't wait for GUI editors
    if (is_terminal) {
        _ = try child.wait();
    }
}

fn getBaseCommand(command: []const u8) []const u8 {
    if (command.len == 0) {
        return command;
    }

    if (std.mem.lastIndexOfScalar(u8, command, '/')) |idx| {
        return command[idx + 1 ..];
    }

    if (std.mem.lastIndexOfScalar(u8, command, '\\')) |idx| {
        return command[idx + 1 ..];
    }

    return command;
}

fn detectLineArgumentMode(raw_cmd: []const u8) LineArgumentMode {
    const base_cmd = normalizeCommandName(raw_cmd);
    if (containsIgnoreCase(base_cmd, "vim") or
        containsIgnoreCase(base_cmd, "nvim") or
        containsIgnoreCase(base_cmd, "vi") or
        containsIgnoreCase(base_cmd, "nano") or
        containsIgnoreCase(base_cmd, "emacs") or
        containsIgnoreCase(base_cmd, "micro") or
        containsIgnoreCase(base_cmd, "helix") or
        containsIgnoreCase(base_cmd, "hx") or
        containsIgnoreCase(base_cmd, "kak"))
    {
        return .plus;
    }

    if (containsIgnoreCase(base_cmd, "code") or
        containsIgnoreCase(base_cmd, "codium") or
        containsIgnoreCase(base_cmd, "cursor"))
    {
        return .goto_flag;
    }

    if (containsIgnoreCase(base_cmd, "subl") or
        containsIgnoreCase(base_cmd, "zed") or
        containsIgnoreCase(base_cmd, "textmate"))
    {
        return .embed_colon;
    }

    return .none;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) {
        return false;
    }

    var idx: usize = 0;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        var matched = true;
        var offset: usize = 0;
        while (offset < needle.len) : (offset += 1) {
            const hay = std.ascii.toLower(haystack[idx + offset]);
            const ned = std.ascii.toLower(needle[offset]);
            if (hay != ned) {
                matched = false;
                break;
            }
        }

        if (matched) {
            return true;
        }
    }

    return false;
}

fn analyzeEditorArgs(args: []const []const u8) CommandAnalysis {
    if (args.len == 0) {
        return .{ .mode = .none, .uses_open = false, .has_args_separator = false };
    }

    const first = getBaseCommand(args[0]);
    if (containsIgnoreCase(first, "open")) {
        var app_name: []const u8 = "";
        var has_args_separator = false;

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--app") or std.mem.eql(u8, arg, "--application")) {
                if (i + 1 < args.len) {
                    app_name = args[i + 1];
                    i += 1;
                }
            } else if (std.mem.eql(u8, arg, "--args")) {
                has_args_separator = true;
                break;
            } else if (std.mem.endsWith(u8, arg, ".app")) {
                app_name = arg;
            }
        }

        const mode = if (app_name.len > 0)
            detectLineArgumentMode(app_name)
        else
            .none;

        return .{
            .mode = mode,
            .uses_open = true,
            .has_args_separator = has_args_separator,
        };
    }

    return .{
        .mode = detectLineArgumentMode(first),
        .uses_open = false,
        .has_args_separator = false,
    };
}

fn normalizeCommandName(command: []const u8) []const u8 {
    var base = getBaseCommand(command);
    if (base.len >= 4 and std.mem.endsWith(u8, base, ".app")) {
        base = base[0 .. base.len - 4];
    }
    return base;
}

test "detectLineArgumentMode identifies common editors" {
    try std.testing.expectEqual(LineArgumentMode.plus, detectLineArgumentMode("nvim"));
    try std.testing.expectEqual(LineArgumentMode.goto_flag, detectLineArgumentMode("code"));
    try std.testing.expectEqual(LineArgumentMode.embed_colon, detectLineArgumentMode("subl"));
    try std.testing.expectEqual(LineArgumentMode.none, detectLineArgumentMode("unknown"));
}

test "isTerminalEditor recognizes vim variants" {
    try std.testing.expect(isTerminalEditor("vim"));
    try std.testing.expect(isTerminalEditor("nvim"));
    try std.testing.expect(isTerminalEditor("vi"));
}

test "isTerminalEditor recognizes other terminal editors" {
    try std.testing.expect(isTerminalEditor("nano"));
    try std.testing.expect(isTerminalEditor("emacs -nw"));
    try std.testing.expect(isTerminalEditor("helix"));
}

test "isTerminalEditor rejects GUI editors" {
    try std.testing.expect(!isTerminalEditor("code"));
    try std.testing.expect(!isTerminalEditor("subl"));
    try std.testing.expect(!isTerminalEditor("atom"));
}

test "analyzeEditorArgs detects open with application" {
    const args = [_][]const u8{ "open", "-a", "Cursor" };
    const analysis = analyzeEditorArgs(&args);
    try std.testing.expect(analysis.uses_open);
    try std.testing.expect(!analysis.has_args_separator);
    try std.testing.expectEqual(LineArgumentMode.goto_flag, analysis.mode);
}

test "analyzeEditorArgs detects existing args separator" {
    const args = [_][]const u8{ "open", "-a", "Zed", "--args" };
    const analysis = analyzeEditorArgs(&args);
    try std.testing.expect(analysis.uses_open);
    try std.testing.expect(analysis.has_args_separator);
    try std.testing.expectEqual(LineArgumentMode.embed_colon, analysis.mode);
}
