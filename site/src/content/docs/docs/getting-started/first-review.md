---
title: Your First Review
description: A guided tour of the Skim interface. Open a diff and move through it.
---

With Skim [built](../build-from-source/) and on your `PATH`, open a diff from
any git repository.

## Open a diff

```bash
cd your-project

# Review your uncommitted changes
skim

# Or review what you've staged
skim --staged
```

Skim launches into **NORMAL mode** showing the first changed file.

## Move around

The essentials, all vim-shaped:

| Key | Action |
| --- | --- |
| `j` / `k` | Move the cursor down / up |
| `h` / `l` | Previous / next file |
| `Enter` | Focus the file under the cursor |
| `s` | Toggle unified ⇄ side-by-side |
| `Ctrl-d` / `Ctrl-u` | Half-page down / up |
| `gg` / `G` | Jump to the top / bottom of the file |
| `[h` / `]h` | Previous / next code change |
| `?` | Open the built-in keybindings help |

## Jump to a file

Press `Ctrl-p` to open the fuzzy **file palette**, type a few characters of a
filename, and press `Enter` to jump straight to it. Type `>` inside the palette
to switch to **command mode** (or open it directly with `:`), where you can run
commands like *Toggle View Mode*, *Refresh Diff*, and *Quit*.

## Leave a comment

Put the cursor on any line and press `Enter` to attach a comment. When you're
done reviewing, press `y` to yank the comment under the cursor to your
clipboard, or `Y` to yank **all** comments at once, ready to paste into a PR
or chat.

## Refresh as you work

Made more changes in your editor? Press `r` to reload the diff from git without
losing your place.

## Quit

Press `:` and run `quit`, or use the command palette.

## Where to next

- [Navigating diffs](../../guides/navigating-diffs/): motions in depth.
- [View modes](../../guides/view-modes/): unified, side-by-side, and hunk modes.
- [Comments & export](../../guides/comments-and-export/): the full comment workflow.
- [Keybindings & commands](../../reference/keybindings/): the complete keymap.
