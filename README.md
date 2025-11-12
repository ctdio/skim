# Skim

A keyboard-driven TUI for code reviews built in Zig. Fast, minimal, and focused on getting out of your way.

## Features

- Sub-10ms startup, 60 FPS scrolling, ~209KB binary
- Vim-style modal interface (hjkl, Ctrl-n/p)
- File-by-file diff navigation
- Unified and side-by-side views
- Tree-sitter syntax highlighting with async processing (JS/TS/Zig full support)
- **Search with `/` - smart case matching across all files**
- Live refresh (press 'r')
- Full git diff compatibility (working dir, staged, branch comparisons)
- Comment system with export to clipboard ('y' to yank)
- Editor integration (Ctrl-g opens file at line in $EDITOR)

## Installation

### Prerequisites

- Zig 0.13.0 or later
- Git

### Building from Source

```bash
git clone https://github.com/yourusername/skim.git
cd skim

# Debug build (for development)
zig build

# OR release build (optimized)
zig build -Doptimize=ReleaseFast
```

The binary will be available at `./zig-out/bin/skim`.

## Quick Start

```bash
# Build and run
zig build
./zig-out/bin/skim

# Review your changes
./zig-out/bin/skim --staged
```

Navigate with `j`/`k` to move the cursor, `h`/`l` to switch files. Press `Enter` to focus on a file for detailed review. Press `s` to toggle between unified and side-by-side views.

## Usage

Skim follows git diff conventions for specifying what to review:

```bash
# Review working directory changes
skim

# Review staged changes
skim --staged

# Working directory vs. specific branch
skim main

# Staged changes vs. specific branch
skim --staged main

# Compare two branches (two ways)
skim main feature
skim main..feature

# Compare commits
skim abc123..def456

# Merge-base comparison (changes on feature since diverging from main)
skim main...feature

# Working directory vs. 5 commits ago
skim HEAD~5
```

## Keybindings

### NORMAL Mode (Default)

Navigate files and position cursor with vim-style movements:

| Key | Action |
|-----|--------|
| `h` | Previous file |
| `l` | Next file |
| `Ctrl-n` | Next file (alternative) |
| `Ctrl-p` | Previous file (alternative) |
| `j` | Cursor down |
| `k` | Cursor up |
| `g` | Jump to top of file |
| `G` | Jump to bottom of file |
| `Ctrl-d` | Page down |
| `Ctrl-u` | Page up |
| `Shift-M` | Center cursor in viewport |
| `/` | Enter search mode |
| `n` | Jump to next search match |
| `N` | Jump to previous search match |
| `Enter` | Add/edit comment on cursor line |
| `d` | Delete comment under cursor |
| `D` | Clear all comments |
| `Ctrl-g` | Open current file in $EDITOR |
| `y` | Yank (copy) comments to clipboard |
| `s` | Toggle unified/side-by-side view |
| `r` | Refresh diff (reload from git) |
| `q` | Quit |
| `Ctrl-C` × 2 | Force exit (double-press within 1 second) |

### SEARCH Mode

Search through diff content:

| Key | Action |
|-----|--------|
| Type | Enter search query (smart case: lowercase=ignore case, uppercase=exact) |
| `Enter` | Execute search and jump to first match |
| `ESC` | Cancel and return to NORMAL mode |
| `Backspace` | Delete character from query |

**Search behavior:**
- **Smart case**: Search is case-insensitive unless query contains uppercase letters
- **Global**: Searches across all files in the diff
- **Code lines only**: Searches through diff content (add/delete/context lines)
- Use `n`/`N` in NORMAL mode to navigate between matches

### COMMENT Mode

Edit comments on specific lines:

| Key | Action |
|-----|--------|
| `Enter` | Save comment and return to NORMAL mode |
| `Shift-Enter` | Insert newline in comment |
| `ESC` | Cancel and return to NORMAL mode |
| `Backspace` | Delete character before cursor |

## Architecture

```
src/
├── main.zig              # CLI arg parsing and initialization
├── app.zig               # State machine, event handling, rendering coordination
├── line_map.zig          # Pre-computed position registry (single source of truth)
├── comments.zig          # Comment storage and management
├── navigation.zig        # Cursor and file navigation logic
├── state.zig             # State helpers and async highlighting
├── ui.zig                # UI components (header, status, dividers)
├── editor.zig            # External editor integration (Ctrl-g)
├── syntax.zig            # Tree-sitter integration
├── git/
│   ├── diff.zig          # Git command execution
│   └── parser.zig        # Unified diff parser (single-pass O(n))
├── rendering/
│   ├── common.zig        # Shared types (Color, Layout, FrameChars)
│   ├── utils.zig         # Frame buffer management
│   ├── file_header.zig   # File header rendering
│   ├── unified.zig       # Unified diff view
│   └── side_by_side.zig  # Side-by-side diff view
└── queries/
    └── *.scm             # Tree-sitter highlighting queries
```

Design decisions:
- Shell out to git (respects user config)
- Single-pass O(n) diff parsing
- Modal interface (vim-style)
- LineMap system for accurate positioning
- Async syntax highlighting (non-blocking)
- Virtual scrolling (render visible lines only)

## Development Status

### Phase 1: MVP ✅

- [x] Zig project setup with libvaxis
- [x] Git diff execution with support for all git diff patterns
- [x] Unified diff parser with line number tracking
- [x] File list navigation (j/k, h/l, Ctrl-n/p)
- [x] Unified diff view rendering
- [x] NORMAL mode keybindings
- [x] Status bar with mode-specific help

### Phase 2: Core Features ✅

- [x] FOCUSED mode vim navigation (g/G for top/bottom)
- [x] Side-by-side diff view with intelligent wrapping
- [x] Tree-sitter syntax highlighting (JS/TS/Zig)
- [x] Live refresh functionality ('r' key)
- [x] Context-aware highlighting (all lines with syntax overlay on diff colors)
- [x] Comment system (Enter to add/edit, d/D to delete/clear)
- [x] Export comments to clipboard ('y' to yank with context)
- [x] Editor integration (Ctrl-g opens file at line in $EDITOR)
- [x] Search functionality with `/` (smart case, global across files)
- [ ] Hunk navigation
- [ ] Help overlay

### Phase 3: Polish (Current)

- [x] LineMap system for accurate positioning
- [x] Async highlighting for non-blocking syntax processing
- [x] Search functionality with visual highlighting (/ for search, n/N for next/previous)
- [ ] Expand syntax highlighting to Python, Rust, Go, C, C++ (parsers ready, need query files)
- [ ] Hunk navigation
- [ ] Help overlay
- [ ] Mouse support
- [ ] Configuration file
- [ ] Color schemes / themes
- [ ] Performance profiling and optimization

### Phase 4: Advanced

- [ ] Comment persistence and management
- [ ] Delta integration for enhanced rendering
- [ ] Fuzzy file search
- [ ] Git workflow integration (stage hunks, etc.)

## Performance Targets

| Metric | Target | Current |
|--------|--------|---------|
| Cold startup | <10ms | ✅ |
| Binary size | <2MB | ✅ 209KB |
| Memory usage | <50MB | ✅ |
| Scrolling FPS | 60 | ✅ |

## Contributing

Priority areas:
- Syntax highlighting query files for Python, Rust, Go, C, C++ (parsers ready, need .scm files)
- Hunk navigation (n/N keys to jump between hunks)
- Help overlay/documentation (show keybindings in-app)
- Mouse support (click to position cursor, scroll to navigate)
- Comment persistence (save/load comments between sessions)
- Testing coverage (especially for new features)

## Credits

Built with:
- [libvaxis](https://github.com/rockorager/libvaxis) - TUI rendering library
- [z-tree-sitter](https://github.com/lfcm64/z-tree-sitter) - Zig bindings for tree-sitter
- [tree-sitter](https://tree-sitter.github.io/) - Parser generator for syntax highlighting
- Language grammars from [tree-sitter-grammars](https://github.com/tree-sitter-grammars):
  - JavaScript/JSX, TypeScript/TSX
  - Python, Rust, Go, Zig
  - C, C++
  - JSON, YAML, TOML, Markdown, HTML, CSS, Bash

## License

MIT

---

**Status**: Alpha - Phase 2 complete, Phase 3 in progress (LineMap system, async highlighting, and editor integration complete)
