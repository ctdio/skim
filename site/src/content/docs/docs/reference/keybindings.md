---
title: Keybindings & Commands
description: The complete Skim keymap across every mode.
---

The complete keymap, organized by mode. Skim is modal: the active mode is shown
in the status bar, and most keys mean different things in different modes.

Press `?` at any time to open the built-in help.

## NORMAL mode

The default mode. Navigate files and position the cursor with vim-style
movements.

### Navigation

| Key | Action |
| --- | --- |
| `h` / `l` | Previous / next file |
| `j` / `k` | Cursor down / up |
| `Ctrl-n` | Next file (alternative) |
| `Space` / `Ctrl-f` / `PageDown` | Page down (full) |
| `b` / `Ctrl-b` / `PageUp` | Page up (full) |
| `Ctrl-d` / `Ctrl-u` | Half-page down / up |
| `gg` | Jump to top of file |
| `G` | Jump to bottom of file |
| `Shift-M` | Center cursor in viewport |
| `zz` | Center viewport on cursor |
| `[h` / `]h` | Previous / next code change (count prefix supported) |
| `[c` / `]c` | Previous / next comment |
| `{` / `}` | Previous / next empty line (count prefix supported) |

### Character find (like vim)

| Key | Action |
| --- | --- |
| `f{char}` | Find character forward (cursor on character) |
| `F{char}` | Find character backward (cursor on character) |
| `t{char}` | Find character forward (cursor before character) |
| `T{char}` | Find character backward (cursor after character) |
| `;` | Repeat last find in the same direction |

### Search & command palette

| Key | Action |
| --- | --- |
| `/` | Enter search mode |
| `n` / `N` | Next / previous search match |
| `Ctrl-p` | Open the file palette (type `>` to switch to commands) |
| `:` | Open the command palette (vim-style) |
| `?` | Show keybindings help |

### Comments

| Key | Action |
| --- | --- |
| `Enter` | Add / edit a comment on the cursor line |
| `d` | Delete the comment under the cursor |
| `D` | Clear all comments |
| `o` | Toggle a comment's expand / collapse |
| `y` | Yank (copy) the current comment to the clipboard |
| `Y` | Yank (copy) all comments to the clipboard |
| `gY` | Yank all comments to the agent input |

### View modes

| Key | Action |
| --- | --- |
| `s` | Toggle unified / side-by-side view |
| `Tab` / `Shift-Tab` | Cycle hunk view mode (all / additions only / deletions only) |
| `B` | Toggle git blame in the gutter |

### Folding

| Key | Action |
| --- | --- |
| `za` | Toggle fold at cursor (hunk-level) |
| `zc` / `zo` | Close / open fold at cursor (hunk-level) |
| `zC` / `zO` | Close / open file fold (from anywhere in the file) |
| `zM` / `zR` | Close / open all folds |

### Visual mode

| Key | Action |
| --- | --- |
| `v` / `V` | Enter visual selection mode |

### Git operations

| Key | Action |
| --- | --- |
| `r` | Refresh diff (reload from git) |
| `a` | Stage the current file (`git add`) |
| `A` | Stage all files (`git add -A`) |

### Graphite integration

| Key | Action |
| --- | --- |
| `S` | Open the Graphite stack picker |
| `[s` | Navigate to the parent branch (toward trunk) |
| `]s` | Navigate to the child branch (toward tip) |

### Agent panel

| Key | Action |
| --- | --- |
| `Ctrl-e` | Toggle the agent panel |
| `Ctrl-w h/j/k/l` | Focus panes in normal mode, falling back to diff at the outer edge |
| `Ctrl-w w` | Cycle panes / diff focus |
| `Ctrl-w v` / `Ctrl-w s` | Open a vertical / horizontal split (agent normal mode) |
| `Ctrl-w c` / `Ctrl-w o` | Close the focused pane / keep only the focused pane |
| `Ctrl-w H/J/K/L` | Move the focused pane to the far edge |
| `Ctrl-w + - < >` | Resize the focused pane |

### Other

| Key | Action |
| --- | --- |
| `Ctrl-g` | Open the current file in `$EDITOR` at the current line |
| `:` | Open the command palette (`:quit` to exit) |

## SEARCH mode

| Key | Action |
| --- | --- |
| *(type)* | Enter a query (smart case — lowercase ignores case, uppercase is exact) |
| `Enter` | Execute the search and jump to the first match |
| `ESC` | Cancel and return to NORMAL mode |
| `Backspace` | Delete a character from the query |

Search is case-insensitive unless the query contains an uppercase letter,
searches across all files, and matches diff content (add / delete / context
lines). Use `n` / `N` in NORMAL mode to move between matches.

## COMMAND PALETTE mode

Quick access to files and commands.

| Key | Action |
| --- | --- |
| *(type)* | Filter files / commands by name (case-insensitive) |
| `>` | Prefix to switch between file and command mode |
| `↑` / `↓` or `Ctrl-p` / `Ctrl-n` | Navigate the selection |
| `Enter` | Execute the selected command or jump to the file |
| `ESC` | Cancel and return to NORMAL mode |
| `Backspace` | Delete a character from the filter |

**Two modes:**

- **File mode** (`Ctrl-p`) — filter and jump to files. Type `>` to switch to
  command mode.
- **Command mode** (`:`) — built-in commands (vim-style): Toggle View Mode,
  Refresh Diff, Show Help, Quit. Backspace over the leading `>` to switch back
  to file mode.

## VISUAL mode

| Key | Action |
| --- | --- |
| `j` / `k` | Extend the selection down / up |
| `h` / `l` | Previous / next file |
| `g` / `G` | Jump to top / bottom |
| `Ctrl-d` / `Ctrl-u` | Page down / up |
| `y` | Yank (copy) the selection to the clipboard |
| `Enter` | Create a comment for the visual selection |
| `v` / `ESC` | Exit visual mode |

## COMMENT mode

Vim-style editing while writing a comment.

| Key | Action |
| --- | --- |
| `Enter` | Save the comment and return to NORMAL mode |
| `Ctrl-J` | Insert a newline in the comment |
| `ESC` | Cancel and return to NORMAL mode |
| `i` / `a` / `I` / `A` | Insert modes (before / after cursor, line start / end) |
| `h` / `j` / `k` / `l` | Move the cursor |
| `w` / `b` / `e` | Word motions (next word / back word / end of word) |
| `0` / `$` | Jump to line start / end |
| `x` | Delete the character under the cursor |
| `dd` | Delete the entire line |
| `Backspace` | Delete the character before the cursor |

## Agent panel

The [AI agent panel](../../integrations/agent-panel/) has its own full modal
keymap (global, insert, normal, history, visual, permission-prompt, and menu
keys). See that page for the complete agent-panel reference.
