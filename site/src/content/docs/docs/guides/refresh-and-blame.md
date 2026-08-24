---
title: Live Refresh & Blame
description: Reload the diff from git and toggle inline git blame.
---

## Live refresh

As you edit files in another window, press `r` to reload the diff from git.
Skim re-reads the current diff and updates the view **without losing your
place**, so you can keep an editor and a review side by side and refresh as you
go.

| Key | Action |
| --- | --- |
| `r` | Refresh the diff (reload from git) |

Because Skim always reflects the live state of git, refresh also picks up
changes from [staging](../staging/): stage a file with `a`, refresh, and see
it move.

## Git blame

Toggle a git blame column in the gutter to see which commit last touched each
line as you review.

| Key | Action |
| --- | --- |
| `B` | Toggle git blame in the gutter |

Blame is rendered inline in the gutter alongside the line numbers, so it
doesn't disrupt the diff layout.

Next: [keybindings & commands](../../reference/keybindings/).
