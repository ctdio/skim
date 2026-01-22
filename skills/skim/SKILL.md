---
name: skim
description: |
  Interact with skim code review sessions. Use when the user says "/skim",
  "review with skim", "add skim comment", "skim session", or needs to:
  - Review code changes in a running skim TUI
  - Add comments to specific lines in a diff
  - List or manage review comments
  - Get diff context to understand changes
---

# Skim Code Review Integration

Skim is a keyboard-driven TUI for code reviews. You can interact with running sessions to review code and add comments programmatically.

## Interface Selection

**Try MCP first, fall back to CLI:**

1. Check if `mcp__skim__list_clients` tool exists
2. If yes: use MCP tools (direct, no shell needed)
3. If no or fails: use CLI commands via Bash

## Quick Reference

### Step 1: Find Sessions

**MCP:**
```json
mcp__skim__list_clients {}
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

If no sessions: tell user to start skim (`skim`, `skim --staged`, `skim main..feature`)

### Step 2: Get Diff (REQUIRED before commenting)

**MCP:** (use PID from list_clients as client_id)
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
  "client_id": "12345",
  "file": "src/app.zig",
  "line": 42,
  "line_type": "new",
  "text": "Consider adding error handling here"
}
```

**CLI:**
```bash
skim session comment add \
  --file src/app.zig \
  --line 42 \
  --type new \
  "Consider adding error handling here"
```

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
