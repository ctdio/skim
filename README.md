# Skim

A keyboard-driven TUI for code reviews built in Zig. Fast, minimal, and focused on getting out of your way.

## Features

- Sub-10ms startup, 60 FPS scrolling, ~209KB binary
- Vim-style modal interface (hjkl, Ctrl-n/p)
- File-by-file diff navigation
- Unified and side-by-side views
- Tree-sitter syntax highlighting (context lines only, keeping diffs readable)
- Live refresh (press 'r')
- Full git diff compatibility (working dir, staged, branch comparisons)
- Comment system (coming soon)

## Installation

### Prerequisites

- Zig 0.13.0 or later
- Git

### Building from Source

```bash
git clone https://github.com/yourusername/skim.git
cd skim
zig build -Doptimize=ReleaseFast
```

The binary will be available at `./zig-out/bin/skim`.

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
| `Ctrl-d` | Page down |
| `Ctrl-u` | Page up |
| `Enter` | Enter FOCUSED mode |
| `s` | Toggle unified/side-by-side view |
| `r` | Refresh diff (reload from git) |
| `c` | Add comment on cursor line (coming soon) |
| `q` | Quit |
| `Ctrl-C` × 2 | Force exit (double-press within 1 second) |
| `?` | Help (coming soon) |

### FOCUSED Mode

Fine-grained navigation within a file:

| Key | Action |
|-----|--------|
| `j` or `Ctrl-n` | Scroll down one line |
| `k` or `Ctrl-p` | Scroll up one line |
| `Ctrl-d` | Half page down |
| `Ctrl-u` | Half page up |
| `g` | Jump to top |
| `G` | Jump to bottom |
| `ESC` | Return to NORMAL mode |

## Architecture

```
src/
├── main.zig           # CLI arg parsing
├── app.zig            # State machine and rendering
├── syntax.zig         # Tree-sitter integration
├── git/
│   ├── diff.zig       # Git command execution
│   └── parser.zig     # Unified diff parser
└── queries/
    └── *.scm          # Tree-sitter highlighting queries
```

Design decisions:
- Shell out to git (respects user config)
- Single-pass O(n) diff parsing
- Modal interface (vim-style)
- Context-only syntax highlighting
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
- [x] Context-aware highlighting (only on unchanged lines)
- [ ] Comment system
- [ ] Export to annotated patch
- [ ] Hunk navigation (n/N keys)
- [ ] Help overlay

### Phase 3: Polish (Next)

- [ ] Expand syntax highlighting to Python, Rust, Go, C, C++
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
- Syntax highlighting query files for Python, Rust, Go, C, C++
- Comment system implementation
- Hunk navigation
- Mouse support
- Help overlay/documentation
- Testing coverage

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

**Status**: Alpha - Phase 2 core features complete
