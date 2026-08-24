---
title: Navigating Diffs
description: Move through files and changes with vim-style motions.
---

Skim's NORMAL mode is built around vim motions, so navigating a review feels
like moving through a buffer. Many motions accept a **count prefix** (type a
number first), just like vim.

## Files and cursor

| Key | Action |
| --- | --- |
| `h` / `l` | Previous / next file |
| `Ctrl-n` | Next file (alternative) |
| `j` / `k` | Cursor down / up |
| `Enter` | Focus the file under the cursor |

## Paging

| Key | Action |
| --- | --- |
| `Space` / `Ctrl-f` / `PageDown` | Full page down |
| `b` / `Ctrl-b` / `PageUp` | Full page up |
| `Ctrl-d` / `Ctrl-u` | Half-page down / up |

## Jumps

| Key | Action |
| --- | --- |
| `gg` | Jump to the top of the file |
| `G` | Jump to the bottom of the file |
| `Shift-M` | Center the cursor in the viewport |
| `zz` | Center the viewport on the cursor |

## Hopping between changes

These are the motions you'll lean on most in a review. They skip the unchanged
context and land you on what actually changed.

| Key | Action |
| --- | --- |
| `[h` / `]h` | Previous / next code change (accepts a count prefix) |
| `[c` / `]c` | Previous / next comment |
| `{` / `}` | Previous / next empty line (accepts a count prefix) |

:::tip
Combine `]h` with a count: `3]h` jumps forward three changes at once.
:::

## Folding

Collapse hunks and whole files to keep large diffs manageable.

| Key | Action |
| --- | --- |
| `za` | Toggle the fold at the cursor (hunk-level) |
| `zc` / `zo` | Close / open the fold at the cursor |
| `zC` / `zO` | Close / open the whole file fold (from anywhere in the file) |
| `zM` / `zR` | Close / open all folds |

Next: [view modes](../view-modes/).
