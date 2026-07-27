---
title: Overview
description: What Skim is, who it's for, and how the pieces fit together.
---

**Skim** is a keyboard-driven terminal UI for reviewing code changes. It reads
diffs straight from git and renders them with a vim-style modal interface, so
you can move through a review entirely from the home row — no mouse, no leaving
the terminal.

## Why Skim

Reviewing changes in a pager means scrolling walls of text with no sense of
structure. GUI tools pull you out of your keyboard flow, and `git diff` gives
you nowhere to leave a note as you read. Skim keeps the whole loop in the
terminal:

- **Vim-style modal interface** — `hjkl`, `Ctrl-n`/`Ctrl-p`, and change-to-change
  motions.
- **File-by-file navigation** with a fuzzy command palette.
- **Unified and side-by-side** views, plus hunk view modes.
- **Tree-sitter syntax highlighting**, processed asynchronously for smooth
  scrolling.
- **Inline comments** you can export to the clipboard.
- **Staging, live refresh, git blame, and Graphite** stack navigation — from
  inside the TUI.
- **A built-in AI agent panel** (ACP) and an MCP server for external agents.

## How it works

Skim is a single binary that shells out to `git` in your current directory,
so it respects your existing git configuration and works in any repository.
It follows git's own diff conventions for specifying what to review:

```bash
skim                 # working-directory changes
skim --staged        # staged changes
skim main            # working dir vs. a branch
skim main..feature   # compare two refs
```

Rendering uses [libvaxis](https://github.com/rockorager/libvaxis) for the TUI
and [tree-sitter](https://tree-sitter.github.io/) for syntax highlighting.
Startup is sub-10ms and scrolling targets 60 FPS.

## Next steps

- [Prerequisites](../prerequisites/) — what you need installed.
- [Build from source](../build-from-source/) — clone, build, run.
- [Your first review](../first-review/) — a quick tour of the interface.
- [Keybindings & commands](../../reference/keybindings/) — the complete keymap.
