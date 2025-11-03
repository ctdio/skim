# Skim

A lightning-fast, keyboard-driven TUI for code reviews built in Zig. Skim through your diffs with vim-style navigation and seamless AI integration.

## Features

- **🚀 Blazing Fast**: Sub-10ms startup time, 60 FPS scrolling, ~209KB binary
- **⌨️ Vim-Style Navigation**: Modal interface with hjkl movements and Ctrl-n/p support
- **📁 File-Centric**: Navigate diffs file-by-file with intuitive keybindings
- **🎨 Clean UI**: Unified and side-by-side diff views with tree-sitter syntax highlighting
- **🔍 Smart Highlighting**: Context lines get full syntax highlighting; add/delete lines use solid colors
- **♻️ Live Refresh**: Press 'r' to reload diff while maintaining your position
- **🔧 Git Integration**: Review working directory changes or compare any two branches/commits
- **💬 AI-Ready**: Comment system and export coming soon

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

Skim is built with performance and simplicity in mind:

```
src/
├── main.zig           # Entry point and CLI arg parsing
├── app.zig            # Main application state machine and rendering
├── syntax.zig         # Tree-sitter syntax highlighting
├── git/
│   ├── diff.zig       # Git command execution
│   └── parser.zig     # Unified diff parser
└── queries/
    ├── javascript.scm # JS/JSX highlighting queries
    ├── typescript.scm # TS/TSX highlighting queries
    └── zig.scm        # Zig highlighting queries
```

### Design Philosophy

1. **Fast by Default**: Using Zig's zero-cost abstractions and efficient terminal rendering
2. **Shell Out to Git**: Respects user's git config, always up-to-date
3. **Streaming Parser**: O(n) single-pass diff parsing with line number tracking
4. **Modal Interface**: Vim-inspired for keyboard efficiency
5. **Smart Syntax Highlighting**: Tree-sitter integration with context-aware coloring

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

## Why "Skim"?

Because that's exactly what you do - **skim through diffs** quickly and efficiently. No clutter, no friction, just pure speed.

## Contributing

Contributions are welcome! Priority areas:

- [ ] Syntax highlighting query files for Python, Rust, Go, C, C++
- [ ] Comment system implementation
- [ ] Hunk navigation
- [ ] Mouse support
- [ ] Help overlay/documentation
- [ ] Testing coverage

## License

MIT

## Inspiration

Built to solve the pain points of:
- gh's limited review interface
- lazygit's heavy feature set
- delta's lack of interactivity

Skim combines the best of all worlds: fast, focused, and keyboard-driven.

---

**Status**: Alpha - Phase 2 core features complete! Side-by-side view ✅ | Syntax highlighting ✅ | Live refresh ✅
