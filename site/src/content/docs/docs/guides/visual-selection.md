---
title: Visual Selection
description: Select multiple lines to yank or comment on them at once.
---

VISUAL mode lets you select a range of lines and act on the whole range —
either copying it or attaching a single comment that spans it.

## Enter visual mode

| Key | Action |
| --- | --- |
| `v` / `V` | Enter visual selection mode |

## Extend the selection

| Key | Action |
| --- | --- |
| `j` / `k` | Extend the selection down / up |
| `h` / `l` | Previous / next file |
| `g` / `G` | Jump to top / bottom |
| `Ctrl-d` / `Ctrl-u` | Page down / up |

## Act on the selection

| Key | Action |
| --- | --- |
| `y` | Yank (copy) the selection to the clipboard |
| `Enter` | Create a comment for the visual selection |
| `v` / `ESC` | Exit visual mode |

A comment created from a visual selection is attached to the whole range, so
it travels with the lines it covers. See
[comments & export](../comments-and-export/) for how comments are exported.

Next: [comments & export](../comments-and-export/).
