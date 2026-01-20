# Skim CLI Reference

Use these commands if MCP tools (`mcp__skim__*`) are not available.

## Session Commands

### List Sessions

```bash
skim session list [--json]
```

Find running skim instances.

**Output:**
```
Running skim sessions (1):
  PID: 12345
  CWD: /path/to/project
  Diff: working
  Files: 3
```

### Get Context

```bash
skim session context [--id <PID>] [--json]
```

Get session metadata.

**Options:**
- `--id, -i <PID>` - Target specific session (auto-selects if only one)
- `--json` - JSON output

### Get Diff

```bash
skim session diff [--id <PID>] [--file <path>] [--json]
```

Get diff content with line numbers. **Always call this before adding comments.**

**Options:**
- `--id, -i <PID>` - Target specific session
- `--file, -f <path>` - Filter to specific file
- `--json` - JSON output

**Output:**
```
=== src/app.zig ===

@@ Hunk 0: -10,5 +10,6 @@
+       42 | const x = 1;
-  41      | const old = 2;
   41   42 | unchanged
```

**Reading the output:**
- First column: `+` (added), `-` (deleted), ` ` (context)
- Second column: OLD line number (or blank for added lines)
- Third column: NEW line number (or blank for deleted lines)
- After `|`: The actual code

## Comment Commands

### Add Comment

```bash
skim session comment add -f <file> -l <line> [-t new|old] "comment text"
```

Add a comment to a specific line.

**Options:**
- `-f, --file <path>` - File path as shown in diff (required)
- `-l, --line <num>` - Line number from diff output (required)
- `-t, --type <new|old>` - Line type: "new" for +/context, "old" for - lines (default: new)
- `--id, -i <PID>` - Target specific session

**Example:**
```bash
skim session comment add \
  --file src/app.zig \
  --line 42 \
  --type new \
  "Consider adding error handling here"
```

### List Comments

```bash
skim session comment list [--id <PID>] [--json]
```

List all comments in a session.

### Delete Comment

```bash
skim session comment delete <index> [--id <PID>]
```

Delete a comment by its index (from `comment list`).

## Global Options

All commands support:
- `--id, -i <PID>` - Target specific session (auto-selects if only one)
- `--json` - JSON output (where applicable)
- `-h, --help` - Help for any command

## Session Selection

- If only one session is running, it's selected automatically
- If multiple sessions exist, specify `--id <PID>`
- Sessions in your current working directory are preferred

## Starting Skim

If no sessions are running, start skim first:

```bash
skim                    # Working directory changes
skim --staged           # Staged changes
skim main..feature      # Branch comparison
```

## Example Workflow

```bash
# 1. Find a session
skim session list
# → Found session PID 12345

# 2. Get the diff to see line numbers
skim session diff
# → See all changes with old/new line numbers

# 3. Add a comment
skim session comment add \
  -f src/main.zig \
  -l 55 \
  -t new \
  "Potential null pointer dereference"
# → Comment added, visible in TUI immediately

# 4. Verify the comment
skim session comment list
# → Shows comment at index 0
```
