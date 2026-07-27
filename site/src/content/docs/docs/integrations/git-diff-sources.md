---
title: Git Diff Sources
description: Every way to tell Skim what to review — working dir, staged, and ref comparisons.
---

Skim shells out to `git` in your current directory and follows git's own diff
conventions, so the argument you'd pass to `git diff` is (broadly) the argument
you pass to `skim`.

## Working directory

```bash
skim
```

Shows unstaged changes in your working tree — the same set `git diff` would
show.

## Staged changes

```bash
skim --staged
```

Shows what you've staged — the equivalent of `git diff --staged`. You can stage
files from inside the TUI with `a` / `A`; see [staging](../../guides/staging/).

## Against a branch or ref

```bash
# Working directory compared to a branch
skim main

# Staged changes compared to a branch
skim --staged main
```

## Comparing two refs

```bash
# Two branches
skim main feature
skim main..feature

# Two commits
skim abc123..def456
```

Both the space-separated (`main feature`) and range (`main..feature`) forms
compare the two endpoints directly.

## Merge-base comparison

```bash
skim main...feature
```

The three-dot form compares against the **merge base** — it shows the changes
made on `feature` since it diverged from `main`, ignoring changes that landed on
`main` in the meantime. This is usually what you want when reviewing a branch
for merge.

## Relative refs

```bash
# Working directory vs. 5 commits ago
skim HEAD~5
```

Any ref git understands works, including `HEAD~n`, tags, and SHAs.

## Respecting your git config

Because Skim runs git in your working directory, it inherits your git
configuration automatically — diff settings, includes, and credentials all
apply exactly as they would on the command line.

See also the [command-line usage](../../reference/cli/) reference.
