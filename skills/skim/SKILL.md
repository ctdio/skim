---
name: skim
description: |
  Interact with skim code review sessions. Use when the user says "/skim",
  "review with skim", "add skim comment", "skim session", or needs to:
  - Review code changes in a running skim TUI
  - Add comments to specific lines in a diff
  - List or manage review comments
  - Get diff context to understand changes
version: 0.1.0
---

# Skim Code Review Integration

Skim is a keyboard-driven TUI for code reviews. You can interact with running sessions to review code and add comments programmatically.

## Interface Selection

**Try MCP first, fall back to CLI:**

1. Check if `mcp__skim__list_sessions` exists in your available tools
2. If yes → use MCP tools (faster, more reliable)
3. If no or tool call fails → use CLI commands via Bash

**MCP tool names (exact):**
- `mcp__skim__list_sessions` - NOT list_clients
- `mcp__skim__get_context` - session metadata
- `mcp__skim__get_diff` - diff content with line numbers
- `mcp__skim__add_comment`
- `mcp__skim__list_comments`
- `mcp__skim__delete_comment`

## Quick Start

### 1. Find a session

**MCP:**
```
mcp__skim__list_sessions
```

**CLI (if MCP unavailable):**
```bash
skim session list
```

If no sessions: tell user to start skim (`skim`, `skim --staged`, `skim main..feature`)

### 2. Get the diff (to see line numbers)

**MCP:**
```
mcp__skim__get_diff
```

**CLI:**
```bash
skim session diff
```

### 3. Add comments

**MCP:**
```
mcp__skim__add_comment { "file": "src/app.zig", "line": 42, "line_type": "new", "text": "Check for null" }
```

**CLI:**
```bash
skim session comment add -f src/app.zig -l 42 -t new "Check for null"
```

## Understanding Line Types

The diff output shows:
```
+       42 | added code      ← line_type: "new", line: 42
-  41      | removed code    ← line_type: "old", line: 41
   41   42 | context         ← line_type: "new", line: 42
```

## For More Details

- `mcp.md` - Full MCP tool reference
- `cli.md` - Full CLI command reference
- `workflow.md` - Step-by-step review workflow
