# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Skim is a keyboard-driven TUI for code reviews built in Zig. Vim-style navigation, sub-10ms startup, 60 FPS scrolling.

**Current Status**: Alpha - Phase 2 complete, working on Phase 3.

## Build System

### Prerequisites
- Zig 0.13.0 or later
- Git must be available in PATH

### Common Commands

```bash
# Build optimized release binary
zig build -Doptimize=ReleaseFast

# Build and run (passes args to the app)
zig build run -- [args]

# Run unit tests
zig build test

# Run the built binary directly
./zig-out/bin/skim
./zig-out/bin/skim --staged
./zig-out/bin/skim main..feature-branch
```

### Build Configuration
- Output: `./zig-out/bin/skim`
- Dependencies (in `build.zig.zon`):
  - vaxis v0.5.1 (TUI rendering)
  - z-tree-sitter (syntax highlighting - JS, TS, Zig, Python, Rust, Go, C, C++)
- Release builds strip symbols (~209KB)

## Architecture

Four main layers:

1. **CLI Layer** (`main.zig`): Arg parsing, initialization
2. **Application Layer** (`app.zig`): Modal state machine, event handling, rendering
3. **Git Integration** (`git/`): Command execution, diff parsing
4. **Syntax Highlighting** (`syntax.zig`): Tree-sitter integration

### Key Design Decisions

**Modal Interface**: Vim-inspired modes (NORMAL, FOCUSED, comment).

**Shell-out to Git**: Executes system git binary. Respects user config, always compatible.

**Streaming Parser**: Single-pass O(n) parser in `git/parser.zig`. No backtracking.

**Virtual Scrolling**: Render visible lines only. 256KB pre-allocated frame buffer.

**Minimal Dependencies**: Just vaxis (TUI) and z-tree-sitter (highlighting). Core uses Zig stdlib only.

#### syntax.zig - Tree-sitter Integration
- Language detection from file extensions
- Supported: JS/JSX, TS/TSX, Zig, Python, Rust, Go, C, C++
- Byte-range based highlights with semantic categories
- Maps captures to 8-color palette
- Query files: Embedded .scm files (JS, TS, Zig have full queries)
- Lazy: Generated on first render, cached per file
- Applied to all lines (add/delete/context) - syntax colors overlay diff backgrounds

### Core Components

#### app.zig - State Machine and Rendering
- **App struct**: Current file, cursor, scroll, mode, view mode, syntax highlighter
- **Mode enum**: NORMAL (file nav), FOCUSED (in-file scroll), comment (placeholder)
- **ViewMode enum**: unified or side-by-side
- **Event loop**: Keyboard/terminal events via vaxis
- **Render pipeline**: Header → content (gutter + syntax) → status bar
- **Colors**: Dark green/red backgrounds for add/delete lines. Syntax highlighting overlays with: red (keywords), magenta (functions), yellow (types), blue (strings/numbers), cyan (comments)
- **Ctrl-C**: Double-press within 1s to exit
- **Refresh**: 'r' key reloads diff, preserves position

#### git/diff.zig - Git Command Execution
- **getDiff()**: Runs `git diff` with 10-line context
- **getChangedFiles()**: Lists changed files only (no content)
- 100MB output limit
- Flags: `--no-color --no-ext-diff`

#### git/parser.zig - Unified Diff Parser
- **FileDiff**: Paths (old/new), hunks, cached highlights
- **Hunk**: Header (line ranges), lines with old/new numbers
- **Line**: Type (add/delete/context), content, line numbers
- Single-pass, handles implicit counts in `@@` headers
- Strips `a/`/`b/` prefixes, handles `/dev/null`
- Tracks line numbers for accurate gutters

### Performance Targets
- Cold startup: <10ms ✅
- Binary size: <2MB (current: 209KB) ✅
- Memory usage: <50MB ✅
- Scrolling FPS: 60 ✅

## Development Workflow

### Testing
- Tests colocated with implementation
- Run: `zig build test`
- Coverage: arg parsing (3), diff execution (1), parser (3)

### Debugging TUI Apps
- Stdout is for rendering - use `std.log` (stderr) or write to file
- Terminal in raw mode - crashes may corrupt it (run `reset`)

### Code Style
- Run `zig fmt`
- Descriptive names, focused functions
- Explicit error handling

## Development Phases

**Phase 1: MVP** ✅ Complete
- Git integration, unified diff parser, file navigation, basic rendering

**Phase 2: Core Features** ✅ Complete
- ✅ FOCUSED mode vim navigation (g/G for top/bottom)
- ✅ Side-by-side diff view (toggle with 's' key)
- ✅ Tree-sitter syntax highlighting (JS/TS/Zig with query files)
- ✅ Refresh functionality ('r' key to reload diff)
- ✅ Proper line number tracking in gutters
- ⏳ Comment system (placeholder in place, 'c' key reserved)
- ⏳ Export to annotated patch
- ⏳ Hunk navigation
- ⏳ Help overlay

**Phase 3: Polish** (Next)
- Expand syntax highlighting to Python, Rust, Go, C, C++ (parsers ready, need query files)
- Mouse support
- Configuration file
- Color schemes / themes
- Performance profiling and optimization

**Phase 4: Advanced**
- Comment persistence and management
- Delta integration for enhanced diff rendering
- Fuzzy file search
- Git workflow integration (stage hunks, etc.)

## Key Implementation Notes

### Modal State Management
The app uses an enum-based mode system. When adding new modes:
1. Add variant to `Mode` enum in app.zig
2. Update `handleKeyEvent()` switch statement with mode-specific keybindings
3. Update status bar in `renderStatusBar()` to show mode-appropriate help text
4. Consider mode transition logic and escape paths

### Adding New Keybindings
1. Update appropriate mode case in `handleKeyEvent()` switch (normal, focused, or comment mode)
2. Update status bar help text in `renderStatus()` to document the new binding
3. Add entry to README.md keybindings table
4. If adding new vim-style keys, follow vim conventions for consistency

**Current keybindings:**
- NORMAL mode: h/l (file nav), j/k (cursor), Ctrl-n/p (file nav), Ctrl-d/u (page), Enter (focus), s (toggle view), r (refresh), q (quit)
- FOCUSED mode: j/k (scroll), Ctrl-d/u (page), g/G (top/bottom), Esc (normal)

### Extending the Diff Parser
The parser is designed to be strict about unified diff format. If adding support for new diff features:
1. Add fields to relevant structs (FileDiff, Hunk, Line)
2. Update parsing logic in single-pass algorithm (avoid backtracking)
3. Add comprehensive tests covering edge cases
4. Ensure backward compatibility with existing diff output

### Vaxis (TUI Library)
- Handles terminal init, raw mode, event loop, resizing
- `vaxis.Window` for drawing regions
- `window.print()` with segments for multi-style text
- Colors via `vaxis.Style` (see Color constants in app.zig)
- 256KB frame text buffer for temp allocations

### Tree-sitter (Syntax Highlighting)
- z-tree-sitter = Zig bindings
- Grammars via `zts.loadLanguage()`
- Queries: `.scm` files embedded at compile time
- Highlights cached per-file
- Applied to all lines - syntax foreground colors overlay diff backgrounds (green for add, red for delete)

## Git Integration

Three diff modes:
1. Working directory: `skim`
2. Staged: `skim --staged`
3. Ref comparison: `skim ref1..ref2`

Runs git in CWD, respects user config.
