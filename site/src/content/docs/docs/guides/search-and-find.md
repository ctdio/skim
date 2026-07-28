---
title: Search & Find
description: Search across the diff and dart along lines with vim character-find.
---

Skim gives you two ways to move to a specific piece of text: full **search**
across the diff, and vim-style **character find** within a line.

## Search

Press `/` to enter **SEARCH mode**, type a query, and press `Enter` to jump to
the first match.

| Key | Action |
| --- | --- |
| `/` | Enter search mode |
| *(type)* | Build the query (smart-case) |
| `Enter` | Execute search, jump to first match |
| `Backspace` | Delete a character from the query |
| `ESC` | Cancel and return to NORMAL mode |

Once you've searched, move between matches from NORMAL mode:

| Key | Action |
| --- | --- |
| `n` / `N` | Next / previous match |

**Search behavior:**

- **Smart case** — a lowercase query is case-insensitive; include any uppercase
  letter and the search becomes case-sensitive.
- Searches across **all files** in the diff at once.
- Matches diff content only — added, deleted, and context lines.

## Character find

The vim `f`/`t`/`F`/`T` family jumps the cursor to a character on the current
line.

| Key | Action |
| --- | --- |
| `f{char}` | Find character forward — cursor lands **on** the character |
| `F{char}` | Find character backward — cursor lands **on** the character |
| `t{char}` | Find character forward — cursor lands **before** the character |
| `T{char}` | Find character backward — cursor lands **after** the character |
| `;` | Repeat the last find in the same direction |

Next: [visual selection](../visual-selection/).
