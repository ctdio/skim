# Skim Code Review Workflow

Step-by-step guide for reviewing code changes with skim.

## Step 1: Find the Session

**MCP:**
```json
mcp__skim__list_clients {}
```

**CLI:**
```bash
skim session list
```

**Handle results:**
- **No sessions** → Tell user: "Start skim first with `skim`, `skim --staged`, or `skim main..feature`"
- **One session** → Use its PID as `client_id`
- **Multiple sessions** → Ask user which one (show CWD and diff_ref)

## Step 2: Get the Diff

**MCP:**
```json
mcp__skim__get_file_diff {
  "client_id": "12345",
  "file": "src/app.zig"
}
```

**CLI:**
```bash
skim session diff --file src/app.zig
```

This shows all changed lines with their line numbers:

```
=== src/app.zig ===

@@ Hunk 0: -10,5 +10,6 @@
+       42 | added code        <- line_type: "new", line: 42
-  41      | removed code      <- line_type: "old", line: 41
   41   42 | context           <- line_type: "new", line: 42
```

**Mapping diff output to comment parameters:**

| Marker | line_type | Which line number to use |
|--------|-----------|--------------------------|
| `+` | `"new"` | The NEW column (second number) |
| `-` | `"old"` | The OLD column (first number) |
| ` ` | `"new"` | The NEW column (second number) |

## Step 3: Review and Comment

Analyze the diff for issues:

**High priority:**
- Bugs and logic errors (incorrect conditionals, off-by-one)
- Security vulnerabilities (injection, auth bypass)
- Missing error handling (unchecked returns, unhandled exceptions)

**Medium priority:**
- Performance concerns (N+1 queries, unnecessary allocations)
- Race conditions and concurrency issues

**Lower priority:**
- Code style and naming
- Documentation gaps

For each issue, add a comment:

**MCP:**
```json
mcp__skim__add_comment {
  "client_id": "12345",
  "file": "src/app.zig",
  "line": 42,
  "line_type": "new",
  "text": "This could return null - add error handling"
}
```

**CLI:**
```bash
skim session comment add \
  -f src/app.zig \
  -l 42 \
  -t new \
  "This could return null - add error handling"
```

## Step 4: Summarize

After adding comments, summarize your findings:

```
I reviewed the changes and added 3 comments:

1. **src/auth.zig:156** - Missing null check on user lookup
2. **src/api.zig:89** - SQL injection risk with string interpolation
3. **src/handler.zig:42** - Error case returns without logging

The auth and API issues should be addressed before merging.
```

## Writing Effective Comments

### Be Specific About Line Numbers

Always get the diff first. Never guess line numbers.

```
Bad:  "There's a bug somewhere in the auth code"
Good: "Line 156: user.id could be null here if lookup fails"
```

### Suggest Concrete Fixes

```
Bad:  "This might cause issues"
Good: "This can return null when user not found. Add:
       if (user == null) return error.NotFound;"
```

### Use Multi-line Comments for Complex Issues

**MCP:**
```json
mcp__skim__add_comment {
  "client_id": "12345",
  "file": "src/db.zig",
  "line": 78,
  "line_type": "new",
  "text": "Race condition: Two requests could read the same counter value.\n\nConsider using atomic operations or a transaction:\n```zig\nconst count = @atomicRmw(u32, &counter, .Add, 1, .SeqCst);\n```"
}
```

### Focus on Substantive Issues

Prioritize bugs and security over style nitpicks. A code review should catch things that could cause production issues, not enforce personal preferences.

## Verifying Comments

After adding comments, optionally verify they were added:

**MCP:**
```json
mcp__skim__get_comments {
  "client_id": "12345"
}
```

**CLI:**
```bash
skim session comment list
```

## Complete Example Session

```
Agent: First, let me find your skim session.

[calls mcp__skim__list_clients {}]
→ "12345 (working in /home/user/project)"

Agent: Found session 12345. Let me get the diff.

[calls mcp__skim__get_file_diff { "client_id": "12345", "file": "src/auth.zig" }]
→ Shows diff with line numbers

Agent: I see several changes. Let me review them...

[Reviews diff, identifies issue on line 156]

[calls mcp__skim__add_comment {
  "client_id": "12345",
  "file": "src/auth.zig",
  "line": 156,
  "line_type": "new",
  "text": "user could be null here if lookup fails. Add null check before accessing user.id"
}]
→ "Comment request sent"

Agent: I've added a comment about the null check issue.
The comment should now be visible in your skim TUI.
```
