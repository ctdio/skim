---
title: Command-Line Usage
description: How to invoke Skim, use it as a git pager, and the agent-facing CLI.
---

Skim follows git's diff conventions for specifying what to review. Run it in
any git repository.

## Diff sources

```bash
# Review working-directory changes
skim

# Review staged changes
skim --staged

# Working directory vs. a specific branch
skim main

# Staged changes vs. a specific branch
skim --staged main

# Compare two branches (two forms)
skim main feature
skim main..feature

# Compare commits
skim abc123..def456

# Merge-base comparison (changes on feature since it diverged from main)
skim main...feature

# Working directory vs. 5 commits ago
skim HEAD~5
```

See [git diff sources](../../integrations/git-diff-sources/) for a fuller
explanation of each form.

## As a git pager

Skim can read a diff from stdin, which makes it usable as a git pager. Add this
to your `~/.gitconfig`:

```ini
[pager]
    diff = skim diff
    show = skim diff
    log = skim diff
```

Or configure it from the command line:

```bash
git config --global pager.diff "skim diff"
git config --global pager.show "skim diff"
git config --global pager.log "skim diff"
```

You can also pipe diffs in directly:

```bash
git diff | skim diff
git show HEAD | skim diff
cat some.patch | skim diff
```

## Agent-facing CLI (`skim session`)

The `skim session` command lets external agents interact with running Skim TUI
instances.

```bash
# List running skim sessions
skim session list
skim session list --json

# Get session context (files, diff ref, view mode)
skim session context
skim session context --json

# Get diff content (with line numbers for commenting)
skim session diff
skim session diff --file src/app.zig

# Add a comment
skim session comment add --file src/app.zig --line 42 "Check for null"
skim session comment add -f main.zig -l 10 --type old "Remove this"

# List comments
skim session comment list
skim session comment list --json

# Delete a comment by index
skim session comment delete 0
```

**Common options:**

- `--id <PID>`: target a specific session when several are running.
- `--json`: emit JSON for programmatic parsing.
- `--type <old|new>`: for comments: `new` for added lines, `old` for deleted
  lines.

**Diff output format:**

```
MARKER OLD_LINE NEW_LINE | CONTENT
+       -       42       | const x = 1;    # added line   (use --type new)
-       15      -        | const y = 2;    # deleted line (use --type old)
        16      43       | const z = 3;    # context line
```

## MCP server

Skim also ships a stdio MCP server for agents that speak the Model Context
Protocol:

```bash
skim mcp --stdio
```

See the [AI agent panel](../../integrations/agent-panel/) page for MCP tool
details and agent configuration.

## Logs

Skim writes logs to `~/.skim/` (stdout/stderr are used for TUI rendering):

- `~/.skim/tui.log`: TUI client logs.
- `~/.skim/mcp.log`: MCP adapter logs.
