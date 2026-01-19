---
name: skim-review
description: Code review workflow using skim TUI
triggers:
  - /skim-review
  - /skim
  - review with skim
---

# Skim Code Review

You are helping the user review code changes using skim, a keyboard-driven TUI for code reviews.

## Discovery

First, check for running skim sessions:

```bash
skim sessions list --json
```

**If no sessions running:**
Tell the user to start skim in another terminal:
- `skim` for working directory changes
- `skim --staged` for staged changes
- `skim main..feature` for branch comparison

**If one session found:**
Proceed with that session automatically.

**If multiple sessions found:**
Ask the user which session to use, showing the cwd and diff_ref for each.

## Getting Context

Once you have a session, get the diff context:

```bash
skim context --session <PID> --json
```

This returns:
- Files changed with full diff content
- Existing comments
- Current working directory

## Reviewing Code

Analyze the diff and provide feedback. For each issue found:

1. Identify the file and line number
2. Determine if the line is in the "new" or "old" version
3. Write a clear, actionable comment

## Adding Comments

Use the CLI to add comments:

```bash
skim comment add --session <PID> --file "src/app.zig" --line 42 --line-type new "Consider checking for null here"
```

Parameters:
- `--file`: File path as shown in the diff
- `--line`: Line number in that file
- `--line-type`: "new" for added/modified lines, "old" for deleted lines
- The final argument is the comment text

## Listing Comments

To see all comments in the session:

```bash
skim comment list --session <PID> --json
```

## Deleting Comments

To remove a comment by index:

```bash
skim comment delete <INDEX> --session <PID>
```

## Workflow

1. **Discover** - Find the skim session
2. **Understand** - Get context and analyze the diff
3. **Review** - Identify issues, suggest improvements
4. **Comment** - Add comments to specific lines
5. **Iterate** - User may ask for more review or refinements

## Tips

- Focus on substantive issues (bugs, logic errors, security)
- Be specific about line numbers and context
- Suggest concrete fixes when possible
- The user can see comments appear in real-time in the TUI
- Comments support multi-line text (use quotes)

## Example Session

User: "Review my changes"

1. Run `skim sessions list --json`
2. If session found, run `skim context --session <PID> --json`
3. Analyze the diff
4. Add comments for issues found
5. Summarize findings for user
