---
title: View Modes
description: Switch between unified and side-by-side layouts and cycle hunk view modes.
---

Skim renders each diff in one of two layouts, and lets you filter which lines a
hunk shows.

## Unified vs. side-by-side

Press `s` to toggle between the two layouts:

- **Unified** — the classic single-column diff, additions and deletions
  interleaved with context.
- **Side-by-side** — old on the left, new on the right, aligned so you can scan
  a change across both columns.

| Key | Action |
| --- | --- |
| `s` | Toggle unified ⇄ side-by-side |

The current layout is shown in the status bar. You can also toggle it from the
command palette (`:` → *Toggle View Mode*).

## Hunk view modes

Within a diff, cycle what each hunk displays. This is handy when you only care
about what was added, or want to review deletions in isolation.

| Key | Action |
| --- | --- |
| `Tab` | Cycle hunk view mode forward |
| `Shift-Tab` | Cycle hunk view mode backward |

The three modes are:

1. **All lines** — additions, deletions, and context (the default).
2. **Additions only** — just the added lines.
3. **Deletions only** — just the removed lines.

## Git blame

Toggle a git blame column in the gutter to see who last touched each line.

| Key | Action |
| --- | --- |
| `B` | Toggle git blame in the gutter |

See also [live refresh & blame](../refresh-and-blame/).

Next: [search & find](../search-and-find/).
