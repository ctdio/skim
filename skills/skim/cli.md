# Skim CLI Reference

Use these commands via Bash when MCP tools (`mcp__skim__*`) are not available.

## Session Commands

### List Sessions

```bash
skim session list [--json]
```

Find running skim instances.

**Options:**
- `--json` - Output in JSON format

**Example:**
```bash
$ skim session list
Running sessions (1):

  PID:   12345
  CWD:   /home/user/project
  Diff:  working
  Files: 3
```

**JSON output:**
```bash
$ skim session list --json
[{"pid":12345,"port":9999,"cwd":"/home/user/project","diff_ref":"working","files":3}]
```

---

### Get Context

```bash
skim session context [--id <PID>] [--json]
```

Get session metadata.

**Options:**
- `--id, -i <PID>` - Target specific session (auto-selects if only one)
- `--json` - JSON output

**Example:**
```bash
$ skim session context
CWD:      /home/user/project
Diff:     working
View:     unified
Comments: 2

Files (3):
  - src/main.zig
  - src/app.zig
  - README.md
```

---

### Get Diff

```bash
skim session diff [--id <PID>] [--file <path>]
```

Get diff content with line numbers. **Always call this before adding comments.**

**Options:**
- `--id, -i <PID>` - Target specific session
- `--file, -f <path>` - Filter to specific file

**Example:**
```bash
$ skim session diff --file src/app.zig
=== src/app.zig ===

@@ Hunk 0: -10,5 +10,6 @@
+       42 | const x = 1;
-  41      | const old = 2;
   41   42 | unchanged
```

**Reading the output:**
| Column | Meaning |
|--------|---------|
| `+` | Added line (use `--type new`) |
| `-` | Deleted line (use `--type old`) |
| ` ` | Context line (use `--type new`) |
| First number | OLD line number (blank for added) |
| Second number | NEW line number (blank for deleted) |

---

## Comment Commands

### Add Comment

```bash
skim session comment add -f <file> -l <line> [-t new|old] "comment text"
```

Add a comment to a specific line.

**Options:**
- `-f, --file <path>` - File path as shown in diff **(required)**
- `-l, --line <num>` - Line number from diff output **(required)**
- `-t, --type <new|old>` - Line type (default: `new`)
- `--id, -i <PID>` - Target specific session

**Examples:**

Comment on an added line:
```bash
skim session comment add \
  --file src/app.zig \
  --line 42 \
  --type new \
  "Consider adding error handling here"
```

Comment on a deleted line:
```bash
skim session comment add \
  --file src/app.zig \
  --line 41 \
  --type old \
  "Good removal - this was a security risk"
```

Short form:
```bash
skim session comment add -f src/app.zig -l 42 "Check for null"
```

---

### List Comments

```bash
skim session comment list [--id <PID>] [--json]
```

List all comments in a session.

**Options:**
- `--id, -i <PID>` - Target specific session
- `--json` - JSON output

**Example:**
```bash
$ skim session comment list
Comments (2):

  [0] src/app.zig
      Consider adding error handling here

  [1] src/main.zig
      Potential null pointer dereference
```

---

### Delete Comment

```bash
skim session comment delete <index> [--id <PID>]
```

Delete a comment by its index (from `comment list`).

**Options:**
- `--id, -i <PID>` - Target specific session

**Example:**
```bash
$ skim session comment delete 0
Comment deleted.
```

---

## Global Options

All session commands support:
- `--id, -i <PID>` - Target specific session (auto-selects if only one)
- `-h, --help` - Help for any command

## Session Selection

- **One session:** Selected automatically
- **Multiple sessions:** Must specify `--id <PID>`
- **No sessions:** Error message with instructions to start skim

---

## Starting Skim

If no sessions are running, start skim first:

```bash
skim                    # Working directory changes (unstaged)
skim --staged           # Staged changes only
skim main..feature      # Compare branches/refs
```

---

## Complete Workflow Example

```bash
# 1. Find a session
$ skim session list
Running sessions (1):

  PID:   12345
  CWD:   /home/user/project
  Diff:  working
  Files: 3

# 2. Get the diff to see line numbers
$ skim session diff --file src/main.zig
=== src/main.zig ===

@@ Hunk 0: -50,3 +50,5 @@
+       55 | if (result == null) {
+       56 |     return error.NullValue;
+       57 | }

# 3. Add a comment (appears in TUI immediately)
$ skim session comment add \
    -f src/main.zig \
    -l 55 \
    -t new \
    "Good null check, but consider logging the error too"
Comment added.

# 4. Verify the comment
$ skim session comment list
Comments (1):

  [0] src/main.zig
      Good null check, but consider logging the error too
```

## Error Messages

| Error | Meaning | Solution |
|-------|---------|----------|
| `No skim sessions running` | No TUI running | Start skim first |
| `Multiple sessions found` | Ambiguous target | Use `--id <PID>` |
| `Session not found` | Invalid PID | Run `skim session list` |
| `--file is required` | Missing file arg | Add `-f <path>` |
| `--line is required` | Missing line arg | Add `-l <num>` |
