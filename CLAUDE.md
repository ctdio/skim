# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Skim is a lightning-fast, keyboard-driven TUI for code reviews built in Zig. It provides vim-style navigation for reviewing git diffs with sub-10ms startup time and 60 FPS scrolling performance.

**Current Status**: Alpha - Phase 1 MVP complete, actively developing Phase 2 core features.

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
- Binary output: `./zig-out/bin/skim`
- Dependencies managed in `build.zig.zon`:
  - vaxis v0.5.1 (TUI rendering)
  - z-tree-sitter (syntax highlighting with JavaScript, TypeScript, Python, Rust, Go, Zig, C, C++ support)
- Release builds automatically strip symbols for minimal size (~209KB target)

## Architecture

### High-Level Structure

The codebase follows a clean separation of concerns with four main layers:

1. **CLI Layer** (`main.zig`): Argument parsing and initialization
2. **Application Layer** (`app.zig`): Modal state machine, event handling, and TUI rendering
3. **Git Integration Layer** (`git/`): Command execution and diff parsing
4. **Syntax Highlighting** (`syntax.zig`): Tree-sitter integration for code highlighting

### Key Design Decisions

**Modal Interface**: Uses vim-inspired modes (NORMAL, FOCUSED, comment) for keyboard-driven navigation. Mode switching and keybindings follow vim conventions.

**Shell-out to Git**: All git operations execute the system git binary via subprocess. This respects user's git config and ensures compatibility with all git features.

**Streaming Parser**: The diff parser (`git/parser.zig`) uses a single-pass O(n) algorithm that can handle large diffs efficiently. It processes unified diff format line-by-line without backtracking.

**Virtual Scrolling**: Only renders visible content in the terminal viewport. Pre-allocates a 256KB frame text buffer to avoid allocations during render loop.

**Minimal Dependencies**: Only two external dependencies - vaxis for terminal rendering and z-tree-sitter for syntax highlighting. Core logic uses only Zig standard library.

#### syntax.zig - Tree-sitter Integration
- **SyntaxHighlighter**: Manages syntax highlighting using tree-sitter parsers
- **Language detection**: Automatic language detection from file extensions
- **Supported languages**: JavaScript/JSX, TypeScript/TSX, Zig, Python, Rust, Go, C, C++
- **Highlight struct**: Byte-range based highlighting with semantic categories
- **Color mapping**: Maps tree-sitter captures to 8-color terminal palette
- **Query files**: Embedded .scm files for JavaScript, TypeScript, and Zig highlighting
- **Lazy loading**: Highlights generated on first render and cached in FileDiff struct
- **Context-only highlighting**: Applied only to context lines for better diff readability

### Core Components

#### app.zig - State Machine and Rendering
- **App struct**: Manages all application state including current file, cursor position, scroll offset, mode, view mode, and syntax highlighter
- **Mode enum**: NORMAL (file navigation), FOCUSED (in-file scrolling), comment (placeholder for future)
- **ViewMode enum**: unified vs. side-by-side diff display (both fully implemented)
- **Event loop**: Processes keyboard input and terminal events using vaxis
- **Render pipeline**: Header → dividers → content (with gutter + syntax highlighting) → status bar
- **Color scheme**:
  - Diff colors: Dark green/red backgrounds with light text for add/delete lines
  - Syntax highlighting: Magenta (keywords), blue (functions), green (types), yellow (strings/numbers), cyan (comments/constants)
- **Ctrl-C handling**: Double-press within 1 second to force exit (prevents accidental quits)
- **Refresh capability**: Press 'r' to reload diff while preserving current file position

#### git/diff.zig - Git Command Execution
- **getDiff()**: Executes `git diff` with 3-line context, returns unified diff output
- **getChangedFiles()**: Fast mode that only lists changed files without content
- **100MB limit**: Protects against accidentally loading massive diffs
- Uses `--no-color` and `--no-ext-diff` flags for consistent parsing

#### git/parser.zig - Unified Diff Parser
- **FileDiff struct**: Contains file paths (old/new), array of hunks, and cached syntax highlights
- **Hunk struct**: Contains header (line ranges) and array of lines with old/new line numbers
- **Line struct**: Individual diff line with type (add/delete/context), content, and line numbers for both old and new files
- **Parser algorithm**: Single-pass tokenization on newlines, handles implicit counts in hunk headers (e.g., `@@ -1 +1 @@`)
- Strips `a/` and `b/` prefixes from file paths
- Handles `/dev/null` for new/deleted files
- Tracks line numbers for accurate gutter display in both unified and side-by-side views

### Performance Targets
- Cold startup: <10ms ✅
- Binary size: <2MB (current: 209KB) ✅
- Memory usage: <50MB ✅
- Scrolling FPS: 60 ✅

## Development Workflow

### Testing Strategy
- Tests are colocated with implementation code in source files
- Use `zig build test` to run all unit tests
- Current coverage: arg parsing (3 tests), diff execution (1 test), parser (3 tests)
- When adding new features, write tests in the same file after the implementation

### Debugging TUI Applications
- Skim is a full-screen TUI app - stdout is used for rendering
- To debug, use `std.log` which writes to stderr, or write debug output to a file
- The terminal is in raw mode during execution, so crashes may leave the terminal in a bad state (run `reset` to fix)

### Code Style
- Follow Zig standard formatting (run `zig fmt` on modified files)
- Use descriptive variable names consistent with Zig conventions
- Keep functions focused and testable
- Prefer explicit error handling over assumptions

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

### Working with Vaxis (TUI Library)
- Vaxis handles terminal initialization, raw mode, and event loop
- Use `vaxis.Window` for drawing in terminal regions
- Use `window.print()` with segments for styled text output
- Colors are set via `vaxis.Style` with RGB or indexed colors (see Color constants in app.zig)
- Segments allow multi-style rendering on single line (used for syntax highlighting)
- Vaxis automatically handles terminal resizing
- Frame text buffer (256KB) used for temporary string allocation during rendering

### Working with Tree-sitter (Syntax Highlighting)
- z-tree-sitter provides Zig bindings to tree-sitter
- Language grammars loaded via `zts.loadLanguage()`
- Queries defined in `.scm` files embedded at compile time
- Query execution returns captures with byte ranges
- Highlights cached per-file to avoid reparsing
- Only context lines are highlighted (add/delete keep solid colors)

## Git Integration

The app supports three diff modes:
1. **Working directory**: `skim` (unstaged changes)
2. **Staged changes**: `skim --staged`
3. **Ref comparison**: `skim ref1..ref2` (branches, commits, tags)

All git commands run in the current working directory and respect user's git configuration.
