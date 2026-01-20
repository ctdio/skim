# Skim MCP Tools Reference

Use these tools if you have `mcp__skim__*` available.

## Tools

### mcp__skim__list_sessions

List all running skim TUI sessions.

**Parameters:** None (or `session_id` to filter)

**Returns:**
```
Running skim sessions (1):
  PID: 12345
  CWD: /path/to/project
  Diff: working
  Files: 3
```

### mcp__skim__get_context

Get session metadata.

**Parameters:**
- `session_id` (optional) - Target specific session by PID

**Returns:** JSON with `diff_ref`, `cwd`, `view_mode`, `files`, `comment_count`

### mcp__skim__get_diff

Get the full diff content with line numbers. **Always call this before adding comments** to see what lines exist.

**Parameters:**
- `session_id` (optional) - Target specific session
- `file` (optional) - Filter to specific file

**Returns:**
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

### mcp__skim__add_comment

Add a comment to a specific line.

**Parameters:**
- `file` (required) - File path as shown in diff
- `line` (required) - Line number from diff output
- `line_type` (required) - `"new"` for +/context lines, `"old"` for - lines
- `text` (required) - Comment text
- `session_id` (optional) - Target specific session

**Example:**
```json
{
  "file": "src/app.zig",
  "line": 42,
  "line_type": "new",
  "text": "Consider adding error handling here"
}
```

### mcp__skim__list_comments

List all comments in the session.

**Parameters:**
- `session_id` (optional)

**Returns:** JSON with `comments` array

### mcp__skim__delete_comment

Delete a comment by its index.

**Parameters:**
- `index` (required) - Comment index (from list_comments)
- `session_id` (optional)

## Session Selection

- If only one session is running, it's selected automatically
- If multiple sessions, specify `session_id` (the PID)
- If session matches your current working directory, it's preferred

## Example Workflow

```
1. mcp__skim__list_sessions
   → Found session PID 12345

2. mcp__skim__get_diff
   → See all changes with line numbers

3. mcp__skim__add_comment { "file": "src/main.zig", "line": 55, "line_type": "new", "text": "Potential null pointer" }
   → Comment added, visible in TUI immediately

4. mcp__skim__list_comments
   → Verify comment was added
```
