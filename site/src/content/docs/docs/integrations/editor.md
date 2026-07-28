---
title: Editor Integration
description: Jump from a diff line straight into your $EDITOR.
---

When a change needs more than a comment, open the file in your editor at the
exact line — without hunting for it.

| Key | Action |
| --- | --- |
| `Ctrl-g` | Open the current file in `$EDITOR` at the cursor's line |

Skim launches the editor named by your `$EDITOR` environment variable and, when
the editor supports it, positions the cursor on the line you were reviewing.

## Setting `$EDITOR`

Set `$EDITOR` in your shell profile, for example:

```bash
export EDITOR=nvim
# or
export EDITOR="code --wait"
```

Most terminal editors (`vim`, `nvim`, `nano`, `hx`) support jumping to a line
directly. GUI editors that provide a CLI (such as VS Code's `code`) work too —
use their wait flag so Skim knows when you're done.

Next: [AI agent panel](../agent-panel/).
