# Skim MCP Tools Reference

Use these tools when `mcp__skim__*` tools are available.

## Tool Reference

### mcp__skim__list_clients

List all connected skim TUI sessions.

**Parameters:** None

**Example call:**
```json
mcp__skim__list_clients {}
```

**Returns:**
```
Connected skim clients:
- 12345 (working in /path/to/project)
- 67890 (main..feature in /another/project)
```

The ID shown (e.g., `12345`) is the `client_id` needed for other tools.

---

### mcp__skim__get_diff_context

Get session metadata (files, mode, stats).

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `client_id` | string | Yes | Session PID from list_clients |

**Example call:**
```json
mcp__skim__get_diff_context {
  "client_id": "12345"
}
```

**Returns:** JSON with `diff_ref`, `cwd`, `view_mode`, `files`, `comment_count`

---

### mcp__skim__get_file_diff

Get the full diff content for a specific file with line numbers. **Always call this before adding comments** to see available lines.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `client_id` | string | Yes | Session PID from list_clients |
| `file` | string | Yes | File path as shown in session |
| `view_mode` | string | No | `"unified"` (default) or `"side_by_side"` |

**Example call:**
```json
mcp__skim__get_file_diff {
  "client_id": "12345",
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
- After `|`: The actual code

---

### mcp__skim__add_comment

Add a comment to a specific line.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `client_id` | string | Yes | Session PID from list_clients |
| `file` | string | Yes | File path exactly as shown in diff |
| `line` | integer | Yes | Line number from diff output |
| `line_type` | string | Yes | `"new"` for +/context lines, `"old"` for - lines |
| `text` | string | Yes | Comment text (supports multi-line with `\n`) |

**Example calls:**

Comment on an added line (line 42 in NEW file):
```json
mcp__skim__add_comment {
  "client_id": "12345",
  "file": "src/app.zig",
  "line": 42,
  "line_type": "new",
  "text": "Consider adding error handling here"
}
```

Comment on a deleted line (line 41 in OLD file):
```json
mcp__skim__add_comment {
  "client_id": "12345",
  "file": "src/app.zig",
  "line": 41,
  "line_type": "old",
  "text": "Good that this was removed - it was a security risk"
}
```

Multi-line comment with code suggestion:
```json
mcp__skim__add_comment {
  "client_id": "12345",
  "file": "src/db.zig",
  "line": 78,
  "line_type": "new",
  "text": "Race condition: Two requests could read the same counter value.\n\nConsider using atomic operations:\n```zig\nconst count = @atomicRmw(u32, &counter, .Add, 1, .SeqCst);\n```"
}
```

**Returns:** `"Comment request sent"` on success

---

### mcp__skim__get_comments

List all comments in the session.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `client_id` | string | Yes | Session PID from list_clients |

**Example call:**
```json
mcp__skim__get_comments {
  "client_id": "12345"
}
```

**Returns:** JSON with `comments` array containing file_path, line, line_type, text for each comment

---

## Line Type Decision Tree

```
Is the line marked with '-' (deleted)?
├─ YES → line_type: "old", use OLD line number
└─ NO ('+' or ' ') → line_type: "new", use NEW line number
```

## Complete Workflow Example

```
1. List clients to get client_id:
   mcp__skim__list_clients {}
   → "12345 (working in /home/user/project)"

2. Get the diff to see line numbers:
   mcp__skim__get_file_diff { "client_id": "12345", "file": "src/main.zig" }
   → Shows diff with line numbers

3. Add a comment (appears in TUI immediately):
   mcp__skim__add_comment {
     "client_id": "12345",
     "file": "src/main.zig",
     "line": 55,
     "line_type": "new",
     "text": "Potential null pointer dereference"
   }

4. Verify comments:
   mcp__skim__get_comments { "client_id": "12345" }
```

## Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `"Client not found"` | Invalid client_id | Run list_clients again |
| `"Invalid line_type"` | Not "new" or "old" | Use exactly `"new"` or `"old"` |
| `"Missing required field"` | Missing parameter | Check all required params |
