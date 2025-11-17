# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Skim is a keyboard-driven TUI for code reviews built in Zig. Vim-style navigation, sub-10ms startup, 60 FPS scrolling.

**Current Status**: Alpha - Phase 2 complete, Phase 3 in progress (LineMap system, async highlighting, and editor integration complete).

## Build System

### Prerequisites
- Zig 0.13.0 or later
- Git must be available in PATH

### Common Commands

```bash
# Build debug binary (default - use for development and debugging)
zig build

# Build optimized release binary (for production use)
zig build -Doptimize=ReleaseFast

# Build and run (passes args to the app)
zig build run -- [args]

# Run unit tests
zig build test

# Run the built binary directly
./zig-out/bin/skim
./zig-out/bin/skim --staged
./zig-out/bin/skim main..feature-branch

# Debug with stderr logging
./zig-out/bin/skim 2>debug.log
```

**IMPORTANT for debugging**: Always use `zig build` (debug mode) when debugging. Debug builds have:
- Better stack traces
- Assertions enabled
- No optimizations that interfere with debugging
- std.log.debug() messages enabled

### Build Configuration
- Output: `./zig-out/bin/skim`
- Dependencies (in `build.zig.zon`):
  - vaxis v0.5.1 (TUI rendering)
  - z-tree-sitter (syntax highlighting - JS, TS, Zig, Python, Rust, Go, C, C++)
- Release builds strip symbols (~209KB)

## Architecture

For detailed architecture documentation, see [docs/architecture.md](docs/architecture.md).

**Quick Overview:**
- **CLI Layer** (`main.zig`): Arg parsing, initialization
- **Application Layer** (`app.zig`): Modal state machine, event handling
- **Line Tracking** (`line_map.zig`): Pre-computed position registry
- **Git Integration** (`git/`): Command execution, diff parsing
- **Rendering** (`rendering/`): Unified and side-by-side views
- **Syntax Highlighting** (`syntax.zig`): Async tree-sitter integration

**Key Design Principles:**
- Modal interface (vim-style)
- Shell-out to git (respects user config)
- LineMap system (single source of truth for positioning)
- Virtual scrolling (render visible lines only)
- Minimal dependencies (vaxis + z-tree-sitter)

## Development Workflow

### Testing
- Tests colocated with implementation
- Run: `zig build test`
- Coverage includes: arg parsing, diff execution, parser, line_map, comments, editor

### Debugging TUI Apps
- Stdout is for rendering - use `std.log` (stderr) or write to file
- Terminal in raw mode - crashes may corrupt it (run `reset`)
- Debug builds: `zig build` (better stack traces, assertions enabled)

### Code Style
- Run `zig fmt`
- Descriptive names, focused functions
- Explicit error handling

## Key Implementation Patterns

For detailed implementation guides, see [docs/architecture.md](docs/architecture.md).

### LineMap System
- Pre-computed registry of all renderable lines (file headers, hunk headers, code lines, comments, spacers)
- Single source of truth for positioning
- Global line numbers (0-based, sequential)
- Rebuilt when: init, refresh, comment add/delete

### Modal State Machine
- Modes: normal, comment, search, visual, command_palette, help, branch_selection
- Mode handlers in `src/modes/`
- When adding modes: update `Mode` enum, create handler file, update status bar

### Adding Features
- **New keybinding**: Update mode handler in `src/modes/`, update status bar help, update README
- **New language**: Add grammar to `build.zig.zon`, update `syntax.zig`, add `.scm` query file
- **New line type**: Update `LineType` enum, update `LineMap.build()`, update renderers

## Git Integration

Three diff modes:
1. Working directory: `skim`
2. Staged: `skim --staged`
3. Ref comparison: `skim ref1..ref2`

Runs git in CWD, respects user config.
