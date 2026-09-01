---
name: skim
description: |
  Interact with skim code review sessions. Use when the user says "/skim",
  "review with skim", "add skim comment", "reply to skim comment", "skim
  session", or needs to:
  - Review code changes in a running skim TUI
  - Add comments to specific lines in a diff
  - Reply to a comment the reviewer left for you
  - List or manage review comments
  - Get diff context to understand changes
---

# Skim Code Review Integration

Skim is a keyboard-driven TUI for code reviews. You can join a running session to
read the diff, leave comments on lines, and answer comments the reviewer
addressed to you.

**A comment is a conversation, not a drop box.** Each comment carries an author
and a thread of replies. When the reviewer asks you something on a line, reply on
that comment rather than opening a new one — that keeps the question and the
answer in the same place.

## Interface Selection

**Try MCP first, fall back to CLI:**

1. Check if `mcp__skim__list_sessions` exists
2. If yes: use MCP tools (direct, no shell needed)
3. If no or it fails: use CLI commands via Bash

## Quick Reference

### Step 1: Find Sessions

**MCP:**
```json
mcp__skim__list_sessions {}
```

**CLI:**
```bash
skim session list
```

Output example:
```
Running sessions (1):

  PID:   12345
  CWD:   /path/to/project
  Diff:  working
  Files: 3
```

The PID is the `session_id` other tools take. With exactly one session running
you can omit it.

If no sessions: tell the user to start skim (`skim`, `skim --staged`,
`skim main..feature`).

### Step 2: Get the Diff (REQUIRED before commenting)

**MCP:**
```json
mcp__skim__get_diff {
  "session_id": "12345",
  "file": "src/app.zig"
}
```

**CLI:**
```bash
skim session diff --file src/app.zig
```

Output format:
```
=== src/app.zig ===

@@ Hunk 0: -10,5 +10,6 @@
+       42 | const x = 1;        <- Added line: line_type="new", line=42
-  41      | const old = 2;      <- Deleted line: line_type="old", line=41
   41   42 | unchanged           <- Context: line_type="new", line=42
```

### Step 3: Add Comments

**MCP:**
```json
mcp__skim__add_comment {
  "session_id": "12345",
  "file": "src/app.zig",
  "line": 42,
  "line_type": "new",
  "text": "Consider adding error handling here",
  "author": "claude"
}
```

**CLI:**
```bash
skim session comment add \
  --file src/app.zig \
  --line 42 \
  --line-type new \
  --author claude \
  "Consider adding error handling here"
```

### Step 4: Read and Answer the Reviewer

`list_comments` returns every comment with its `author` and its `replies`. A
comment whose latest message is from the reviewer and asks something is one you
should answer.

**MCP:**
```json
mcp__skim__list_comments { "session_id": "12345" }
mcp__skim__reply_to_comment {
  "session_id": "12345",
  "index": 0,
  "text": "It is memoized inside foo(), so the second call is free.",
  "author": "claude"
}
```

**CLI:**
```bash
skim session comment list
skim session comment reply -i 0 -a claude "It is memoized inside foo()."
```

**Always pass `author`.** It is the label the reviewer sees next to your reply;
without it your reply is attributed to them.

`index` comes from `list_comments` and is positional — deleting a comment shifts
every index above it. List again if you have deleted anything, or if enough time
has passed that the reviewer may have.

## Line Type Rules

| Diff marker | line_type | Use line from |
|-------------|-----------|---------------|
| `+` (added) | `"new"` | NEW column |
| `-` (deleted) | `"old"` | OLD column |
| ` ` (context) | `"new"` | NEW column |

## For More Details

- `mcp.md` - Full MCP tool reference with all parameters
- `cli.md` - Full CLI command reference
- `workflow.md` - Step-by-step review workflow
