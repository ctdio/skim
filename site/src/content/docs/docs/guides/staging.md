---
title: Staging from the TUI
description: Stage files with git add without leaving Skim.
---

While reviewing your working-directory changes, you can stage files directly
from Skim, with no need to drop back to the shell to run `git add`.

| Key | Action |
| --- | --- |
| `a` | Stage the current file (`git add`) |
| `A` | Stage all files (`git add -A`) |

Staging runs git in your working directory, so it behaves exactly like the
equivalent `git add` command and respects your git configuration.

:::tip
A common flow: review working-directory changes with `skim`, stage the files
you're happy with using `a`, then re-run against `--staged` (or press `r` to
[refresh](../refresh-and-blame/)) to confirm what you've staged.
:::

Next: [live refresh & blame](../refresh-and-blame/).
