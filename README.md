# Skim

A lightning-fast, keyboard-driven TUI for code reviews built in Zig. Skim through your diffs with vim-style navigation and seamless AI integration.

## Features

- **🚀 Blazing Fast**: Sub-10ms startup time, 60 FPS scrolling
- **⌨️ Vim-Style Navigation**: Modal interface with hjkl movements and Ctrl-n/p support
- **📁 File-Centric**: Navigate diffs file-by-file with intuitive keybindings
- **🎨 Clean UI**: Unified and side-by-side diff views with syntax highlighting
- **💬 AI-Ready**: Add comments and export as annotated diff patches
- **🔧 Git Integration**: Review working directory changes or compare any two branches/commits

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
| `Enter` | Enter FOCUSED mode (for detailed selection) |
| `c` | Add comment on cursor line (coming soon) |
| `s` | Toggle unified/side-by-side view |
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
├── app.zig            # Main application state machine
├── git/
│   ├── diff.zig       # Git command execution
│   └── parser.zig     # Unified diff parser
└── ui/
    └── (coming soon)  # UI components
```

### Design Philosophy

1. **Fast by Default**: Using Zig's zero-cost abstractions and efficient terminal rendering
2. **Shell Out to Git**: Respects user's git config, always up-to-date
3. **Streaming Parser**: O(n) single-pass diff parsing
4. **Modal Interface**: Vim-inspired for keyboard efficiency

## Development Status

### Phase 1: MVP ✅

- [x] Zig project setup with libvaxis
- [x] Git diff execution
- [x] Unified diff parser
- [x] File list navigation (j/k, Ctrl-n/p)
- [x] Unified diff view rendering
- [x] NORMAL mode keybindings
- [x] Status bar

### Phase 2: Core Features (In Progress)

- [ ] FOCUSED mode vim navigation
- [ ] Side-by-side diff view
- [ ] Comment system
- [ ] Export to annotated patch
- [ ] Hunk navigation (h/l keys)
- [ ] Help overlay

### Phase 3: Polish

- [ ] Basic syntax highlighting
- [ ] Mouse support
- [ ] Configuration file
- [ ] Color schemes
- [ ] Performance optimization

### Phase 4: Advanced

- [ ] Comment persistence
- [ ] Delta integration (optional)
- [ ] Tree-sitter syntax highlighting
- [ ] Fuzzy file search

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

Contributions are welcome! Areas of focus:

- [ ] Side-by-side diff rendering
- [ ] Comment system implementation
- [ ] Syntax highlighting
- [ ] Mouse support
- [ ] Testing

## License

MIT

## Inspiration

Built to solve the pain points of:
- gh's limited review interface
- lazygit's heavy feature set
- delta's lack of interactivity

Skim combines the best of all worlds: fast, focused, and keyboard-driven.

---

**Status**: Alpha - Core functionality working, actively developing Phase 2 features.
