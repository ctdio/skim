---
title: Comments & Export
description: Leave inline review comments and export them to the clipboard.
---

Skim's comment system lets you annotate a diff as you read, then export your
notes to paste into a PR, an issue, or a chat with an agent.

## Add and edit comments

Put the cursor on a line and press `Enter` to add or edit a comment there. You
can also create a comment spanning a [visual selection](../visual-selection/).

| Key | Action |
| --- | --- |
| `Enter` | Add / edit a comment on the cursor line |
| `d` | Delete the comment under the cursor |
| `D` | Clear all comments |
| `o` | Toggle a comment's expand / collapse |
| `[c` / `]c` | Jump to the previous / next comment |

## Editing a comment (COMMENT mode)

While editing, Skim gives you a compact vim-style editor:

| Key | Action |
| --- | --- |
| `Enter` | Save the comment and return to NORMAL mode |
| `Ctrl-J` | Insert a newline in the comment |
| `ESC` | Cancel and return to NORMAL mode |
| `i` / `a` / `I` / `A` | Insert modes (before / after cursor, line start / end) |
| `h` / `j` / `k` / `l` | Move the cursor |
| `w` / `b` / `e` | Word motions (next / back / end of word) |
| `0` / `$` | Jump to line start / end |
| `x` | Delete the character under the cursor |
| `dd` | Delete the entire line |
| `Backspace` | Delete the character before the cursor |

## Export to the clipboard

When you're ready to share your review, yank comments out:

| Key | Action |
| --- | --- |
| `y` | Yank (copy) the comment under the cursor |
| `Y` | Yank **all** comments |
| `gY` | Yank all comments to the agent input |

`gY` sends your comments straight into the [AI agent panel](../../integrations/agent-panel/)
input, so you can hand the whole review to an agent.

Next: [staging from the TUI](../staging/).
