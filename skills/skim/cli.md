# Skim CLI Reference

Use these commands via Bash when MCP tools (`mcp__skim__*`) are not available.

`skim session <cmd>` and the shorter `skim <cmd>` are the same command.

**Flag warning:** session commands (`list`, `context`, `diff`) select a session
with `--id, -i <PID>`. Comment commands use `--session, -s <PID>` instead,
because on `comment reply` and `comment delete` `-i` already means `--index`.

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
| `+` | Added line (use `--line-type new`) |
| `-` | Deleted line (use `--line-type old`) |
| ` ` | Context line (use `--line-type new`) |
| First number | OLD line number (blank for added) |
| Second number | NEW line number (blank for deleted) |

---

## Comment Commands

### Add Comment

```bash
skim session comment add -f <file> -l <line> [-t new|old] [-a <name>] "comment text"
```

Add a comment to a specific line. Use this to raise something new; to answer an
existing comment use `comment reply`.

**Options:**
- `-f, --file <path>` - File path as shown in diff **(required)**
- `-l, --line <num>` - Line number from diff output **(required)**
- `-t, --line-type <new|old>` - Line type (default: `new`)
- `-a, --author <name>` - Author label (default: `you`)
- `-s, --session <PID>` - Target specific session

**Examples:**

Comment on an added line:
```bash
skim session comment add \
  --file src/app.zig \
  --line 42 \
  --line-type new \
  --author claude \
  "Consider adding error handling here"
```

Comment on a deleted line:
```bash
skim session comment add \
  --file src/app.zig \
  --line 41 \
  --line-type old \
  --author claude \
  "Good removal - this was a security risk"
```

Short form:
```bash
skim session comment add -f src/app.zig -l 42 -a claude "Check for null"
```

---

### Reply to a Comment

```bash
skim session comment reply -i <index> [-a <name>] "reply text"
```

Append a reply to an existing comment's thread. This is how you answer a question
the reviewer left for you — it keeps the answer attached to the line it is about
instead of starting a disconnected comment.

**Options:**
- `-i, --index <num>` - Comment index from `comment list` **(required)**
- `-a, --author <name>` - Author label (default: `you`)
- `-s, --session <PID>` - Target specific session

**Example:**
```bash
$ skim session comment reply -i 0 -a claude "It is memoized inside foo()."
Reply added.
```

**Always pass `--author`.** It is the label shown next to your reply in the TUI;
omitting it attributes your reply to the reviewer.

**`--index` is positional.** Deleting a comment shifts every index above it down
by one. Run `comment list` immediately before replying rather than reusing an
index from earlier.

---

### List Comments

```bash
skim session comment list [--session <PID>] [--json]
```

List all comments and their reply threads.

**Options:**
- `-s, --session <PID>` - Target specific session
- `--json` - JSON output

**Example:**
```bash
$ skim session comment list
Comments (2):

  [0] src/app.zig
      you: why is this not cached?
        ↳ claude: foo() memoizes internally

  [1] src/main.zig
      claude: Potential null pointer dereference
```

JSON output carries `author` on each comment and a `replies` array whose entries
each have `index`, `author`, and `text`. Read `author` to tell your own messages
from the reviewer's — a thread whose last message is the reviewer's and reads as
a question is one to answer.

---

### Delete Comment

```bash
skim session comment delete <index> [--session <PID>]
```

Delete a comment and its whole thread, by index (from `comment list`).

**Options:**
- `-s, --session <PID>` - Target specific session

**Example:**
```bash
$ skim session comment delete 0
Comment deleted.
```

Deleting shifts every higher index down by one. Re-list before using another
index.

---

## Session Selection

- **One session:** Selected automatically
- **Multiple sessions:** Specify `--id <PID>` (session commands) or
  `--session <PID>` (comment commands)
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
    -a claude \
    "Good null check, but consider logging the error too"
Comment added.

# 4. Read the thread and answer anything addressed to you
$ skim session comment list
Comments (1):

  [0] src/main.zig
      you: why is this not cached?

$ skim session comment reply -i 0 -a claude "foo() memoizes internally."
Reply added.
```

## Error Messages

| Error | Meaning | Solution |
|-------|---------|----------|
| `No skim sessions running` | No TUI running | Start skim first |
| `Multiple sessions found` | Ambiguous target | Use `--id`/`--session <PID>` |
| `Session not found` | Invalid PID | Run `skim session list` |
| `--file is required` | Missing file arg | Add `-f <path>` |
| `--line is required` | Missing line arg | Add `-l <num>` |
| `--index is required` | Missing index on reply | Add `-i <num>` |
| `Invalid comment index` | Comment deleted or index stale | Run `comment list` again |
