# Skim Code Review Workflow

Step-by-step guide for reviewing code changes with skim.

## Step 1: Find the Session

**MCP:**
```
mcp__skim__list_sessions
```

**CLI:**
```bash
skim session list
```

**Handle results:**
- No sessions → Tell user to start skim (`skim`, `skim --staged`, or `skim ref1..ref2`)
- One session → Proceed automatically
- Multiple sessions → Ask which one (show cwd and diff_ref)

## Step 2: Get the Diff

**MCP:**
```
mcp__skim__get_diff
```

**CLI:**
```bash
skim session diff
```

This shows all changed lines with their line numbers. The format tells you what to use for comments:

```
+       42 | added code      ← line_type: "new", line: 42
-  41      | removed code    ← line_type: "old", line: 41
   41   42 | context         ← line_type: "new", line: 42
```

## Step 3: Review and Comment

Analyze the diff for:
- **Bugs and logic errors** - Incorrect conditionals, off-by-one errors
- **Security vulnerabilities** - Injection risks, auth issues
- **Missing error handling** - Unchecked returns, unhandled exceptions
- **Code style issues** - Naming, formatting, complexity
- **Performance concerns** - N+1 queries, unnecessary allocations

For each issue found, add a comment:

**MCP:**
```
mcp__skim__add_comment {
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

After adding comments, summarize your findings for the user. They can see the comments in real-time in the TUI.

Example summary:
```
I reviewed the changes and added 3 comments:

1. **src/auth.zig:156** - Missing null check on user lookup
2. **src/api.zig:89** - SQL injection risk with string interpolation
3. **src/handler.zig:42** - Error case returns without logging

The auth and API issues should be addressed before merging.
```

## Tips for Effective Reviews

### Be Specific About Line Numbers
Always reference the exact line from the diff output. Don't guess.

### Suggest Concrete Fixes
```
❌ "This might cause issues"
✅ "This can return null when user not found. Add: `if (user == null) return error.NotFound;`"
```

### Focus on Substantive Issues
Prioritize bugs and security over style nitpicks.

### Multi-line Comments
Comments support multi-line text - use them to explain complex issues:
```
mcp__skim__add_comment {
  "file": "src/db.zig",
  "line": 78,
  "line_type": "new",
  "text": "Race condition: Two requests could read the same counter value.\n\nConsider using atomic operations or a transaction:\n```zig\nconst count = @atomicRmw(u32, &counter, .Add, 1, .SeqCst);\n```"
}
```

### Verify Comments Were Added
After adding comments, optionally list them to confirm:

**MCP:** `mcp__skim__list_comments`
**CLI:** `skim session comment list`
