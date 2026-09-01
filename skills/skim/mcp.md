# Skim MCP Tools Reference

Use these tools when `mcp__skim__*` tools are available.

Every tool takes an optional `session_id` (the PID from `list_sessions`). With
exactly one session running you can omit it.

## Tool Reference

### mcp__skim__list_sessions

List all running skim TUI sessions.

**Parameters:** None

**Example call:**
```json
mcp__skim__list_sessions {}
```

**Returns:**
```
Running sessions (1):

  PID:   12345
  CWD:   /path/to/project
  Diff:  working
  Files: 3
```

The PID (e.g. `12345`) is the `session_id` other tools take.

---

### mcp__skim__get_context

Get session metadata (files, mode, stats).

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `session_id` | string | No | Session PID from list_sessions |

**Example call:**
```json
mcp__skim__get_context {
  "session_id": "12345"
}
```

**Returns:** JSON with `diff_ref`, `cwd`, `view_mode`, `files`, `comment_count`

---

### mcp__skim__get_diff

Get the full diff content with line numbers. **Always call this before adding
comments** to see which lines exist.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `session_id` | string | No | Session PID from list_sessions |
| `file` | string | No | Limit to one file; omit for the whole diff |

**Example call:**
```json
mcp__skim__get_diff {
  "session_id": "12345",
  "file": "src/app.zig"
}
```

**Returns:**
```
=== src/app.zig ===

@@ Hunk 0: -10,5 +10,6 @@
+       42 | const x = 1;
-  41      | const old = 2;
   41   42 | unchanged
```

**Reading the output:**
- Column 1: `+` (added), `-` (deleted), ` ` (context)
- Column 2: OLD line number (blank for added lines)
- Column 3: NEW line number (blank for deleted lines)
- After `|`: the actual code

---

### mcp__skim__add_comment

Add a comment to a specific line. Use this to raise something new; to answer an
existing comment use `reply_to_comment` instead.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `session_id` | string | No | Session PID from list_sessions |
| `file` | string | Yes | File path exactly as shown in the diff |
| `line` | integer | Yes | Line number from the diff output |
| `line_type` | string | Yes | `"new"` for +/context lines, `"old"` for - lines |
| `text` | string | Yes | Comment text (multi-line with `\n`) |
| `author` | string | No | Your name; defaults to the local reviewer |

**Example calls:**

Comment on an added line (line 42 in the NEW file):
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

Comment on a deleted line (line 41 in the OLD file):
```json
mcp__skim__add_comment {
  "session_id": "12345",
  "file": "src/app.zig",
  "line": 41,
  "line_type": "old",
  "text": "Good that this was removed - it was a security risk",
  "author": "claude"
}
```

Multi-line comment with a code suggestion:
```json
mcp__skim__add_comment {
  "session_id": "12345",
  "file": "src/db.zig",
  "line": 78,
  "line_type": "new",
  "text": "Race condition: two requests could read the same counter value.\n\nConsider an atomic:\n```zig\nconst count = @atomicRmw(u32, &counter, .Add, 1, .seq_cst);\n```",
  "author": "claude"
}
```

**Returns:** JSON with `success` and `comment_index`

---

### mcp__skim__reply_to_comment

Append a reply to an existing comment's thread. This is how you answer a question
the reviewer left for you — it keeps the answer attached to the line it is about
instead of starting a disconnected comment.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `session_id` | string | No | Session PID from list_sessions |
| `index` | integer | Yes | Comment index from list_comments |
| `text` | string | Yes | Reply text (multi-line with `\n`) |
| `author` | string | No | Your name; defaults to the local reviewer |

**Example call:**
```json
mcp__skim__reply_to_comment {
  "session_id": "12345",
  "index": 0,
  "text": "It is memoized inside foo(), so the second call is free.",
  "author": "claude"
}
```

**Returns:** JSON with `success` and `reply_index`

**Always pass `author`.** It is the label shown next to your reply in the TUI;
omitting it attributes your reply to the reviewer.

**`index` is positional.** Deleting a comment shifts every index above it down by
one. Call `list_comments` immediately before replying rather than reusing an
index from earlier in the conversation.

The reply appears in the TUI right away and the thread is expanded, so the
reviewer sees it without pressing anything.

---

### mcp__skim__list_comments

List all comments and their reply threads.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `session_id` | string | No | Session PID from list_sessions |

**Example call:**
```json
mcp__skim__list_comments {
  "session_id": "12345"
}
```

**Returns:** JSON with a `comments` array. Each entry has `index`, `file_path`,
`line`, `line_type`, `author`, `text`, and a `replies` array whose entries each
have `index`, `author`, and `text`.

Read `author` to tell your own messages from the reviewer's. A thread whose last
message is the reviewer's and reads as a question is one to answer with
`reply_to_comment`.

---

### mcp__skim__delete_comment

Delete a comment and its whole thread.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `session_id` | string | No | Session PID from list_sessions |
| `index` | integer | Yes | Comment index from list_comments |

**Example call:**
```json
mcp__skim__delete_comment {
  "session_id": "12345",
  "index": 0
}
```

Deleting shifts every higher index down by one. Re-list before using another
index.

---

## Line Type Decision Tree

```
Is the line marked with '-' (deleted)?
├─ YES → line_type: "old", use OLD line number
└─ NO ('+' or ' ') → line_type: "new", use NEW line number
```

## Complete Workflow Example

```
1. Find the session:
   mcp__skim__list_sessions {}
   → PID 12345 (working in /home/user/project)

2. Get the diff to see line numbers:
   mcp__skim__get_diff { "session_id": "12345", "file": "src/main.zig" }

3. Add a comment (appears in the TUI immediately):
   mcp__skim__add_comment {
     "session_id": "12345",
     "file": "src/main.zig",
     "line": 55,
     "line_type": "new",
     "text": "Potential null pointer dereference",
     "author": "claude"
   }

4. Read the thread and answer anything addressed to you:
   mcp__skim__list_comments { "session_id": "12345" }
   → comment 0, author "you": "why is this not cached?"

   mcp__skim__reply_to_comment {
     "session_id": "12345",
     "index": 0,
     "text": "foo() memoizes internally.",
     "author": "claude"
   }
```

## Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `"Session not found"` | Invalid session_id | Run list_sessions again |
| `"Invalid comment index"` | Comment deleted or index stale | Run list_comments again |
| `"'text' must not be empty"` | Blank or whitespace-only reply | Send real text |
| `"Invalid line_type"` | Not "new" or "old" | Use exactly `"new"` or `"old"` |
