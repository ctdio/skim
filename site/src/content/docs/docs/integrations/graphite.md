---
title: Graphite Stacks
description: Navigate stacked pull requests from inside Skim.
---

If you use [Graphite](https://graphite.dev/) to manage stacked pull requests,
Skim can navigate the stack for you — jump between branches without leaving the
review.

## Requirements

Install the Graphite CLI (`gt`) and initialize it in your repository as you
normally would. Skim uses your existing Graphite stack metadata.

## Navigating a stack

| Key | Action |
| --- | --- |
| `S` | Open the Graphite stack picker |
| `[s` | Navigate to the parent branch (toward trunk) |
| `]s` | Navigate to the child branch (toward the tip) |

- **`S`** opens a picker listing the branches in the current stack, so you can
  jump straight to any one of them.
- **`[s` / `]s`** step one branch at a time — `[s` moves down toward the trunk,
  `]s` moves up toward the tip of the stack.

As you move between branches, Skim re-renders the diff for the branch you land
on, so reviewing a stack becomes a matter of stepping through it with `]s`.

Next: [editor integration](../editor/).
