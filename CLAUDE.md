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

Five main layers:

1. **CLI Layer** (`main.zig`): Arg parsing, initialization
2. **Application Layer** (`app.zig`): Modal state machine, event handling, rendering coordination
3. **Line Tracking** (`line_map.zig`): Pre-computed position registry for all renderable lines
4. **Git Integration** (`git/`): Command execution, diff parsing
5. **Syntax Highlighting** (`syntax.zig`): Tree-sitter integration

### Key Design Decisions

**Modal Interface**: Vim-inspired modes (NORMAL, comment).

**Shell-out to Git**: Executes system git binary. Respects user config, always compatible.

**Streaming Parser**: Single-pass O(n) parser in `git/parser.zig`. No backtracking.

**Virtual Scrolling**: Render visible lines only. 256KB pre-allocated frame buffer.

**LineMap System**: Pre-compute all line positions once during initialization. Single source of truth for positioning prevents sync issues between navigation and rendering.

**Minimal Dependencies**: Just vaxis (TUI) and z-tree-sitter (highlighting). Core uses Zig stdlib only.

#### syntax.zig - Tree-sitter Integration
- Language detection from file extensions
- Supported: JS/JSX, TS/TSX, Zig, Python, Rust, Go, C, C++
- Byte-range based highlights with semantic categories
- Maps captures to 8-color palette
- Query files: Embedded .scm files (JS, TS, Zig have full queries)
- Async: Generated in background thread (non-blocking), cached per file, parser instances cached per language
- Applied to all lines (add/delete/context) - syntax foreground colors overlay diff backgrounds

### Core Components

#### comments.zig - Comment Storage and Management
- **CommentStore**: In-memory storage for review comments
- **Comment**: Attached to specific hunk/line with captured context (line type, content, line numbers)
- **Operations**: Add, update, delete, find, export with context
- **Integration**: Comments trigger LineMap rebuild when added/deleted
- **Export**: 'y' key yanks comments to clipboard with full context

#### navigation.zig - Navigation Logic
- **Cursor movement**: moveCursorUp/Down with count prefix support (j/k)
- **File navigation**: navigateToNextFile/navigateToPreviousFile (h/l, Ctrl-n/p)
- **Scrolling**: pageUp/Down, scrollToTop/Bottom, centerCursor
- **Visibility**: ensureCursorVisible adds 3-line padding for j/k (not file nav)
- **File snapping**: File navigation sets both cursor and scroll to header line

#### state.zig - State Helpers and Async Highlighting
- **StateHelpers**: Diff stats calculation, async highlighting management
- **AsyncHighlightJob**: Thread-safe background syntax highlighting
- **Non-blocking**: Highlighting happens in background, UI stays responsive
- **Parser caching**: Tree-sitter parsers cached per language for fast highlighting

#### ui.zig - UI Rendering Components
- **renderHeader()**: File info with additions/deletions stats
- **renderStatus()**: Mode indicator, position, context-aware keybindings
- **renderDivider()**: Box-drawing dividers (top/middle/bottom)
- **renderEmpty()**: "No changes to review" message
- **Context-aware**: Status bar changes based on cursor position (file header, code line, comment line, etc.)

#### editor.zig - External Editor Integration
- **Ctrl-g**: Open current file at line in external editor
- **Editor detection**: Checks $VISUAL, $EDITOR env vars
- **Terminal editors**: vim, nvim, nano, emacs, helix, etc. - suspends TUI, restores after
- **GUI editors**: VSCode, Sublime, etc. - spawns in background
- **Line argument**: Handles different line number formats (+line, --goto, embedded :line)

#### rendering/ - Rendering Subsystem
- **common.zig**: Shared types (Color palette, Layout constants, FrameChars box-drawing)
- **utils.zig**: Frame buffer management, text allocation for vaxis
- **file_header.zig**: File header rendering with stats
- **unified.zig**: Unified diff view renderer (single column)
- **side_by_side.zig**: Side-by-side diff view renderer (split columns with divider)
- **All renderers**: Iterate through LineMap records, render based on line type

#### line_map.zig - Line Position Registry
- **LineMap**: Pre-computed registry of all renderable lines built once during init/refresh
- **LineRecord**: Each line has explicit global position, file index, and type-specific metadata
- **LineType union enum**:
  - `file_header`: File header line (e.g., "diff --git a/file.txt b/file.txt")
  - `hunk_header`: Hunk header with hunk index (e.g., "@@ -1,3 +1,4 @@")
  - `code_line`: Diff line (add/delete/context) with hunk and line indices
  - `comment_line`: Comment attached to code line with parent references
  - `spacer`: Blank line between files (3 spacers total per file boundary)
- **Purpose**: Single source of truth for all positioning decisions
- **Rebuilt**: When comments added/deleted or diff refreshed
- **API**: Direct lookups via `getLineRecord()`, `getFileHeaderLine()`, `getFileIndexForLine()`

#### app.zig - State Machine and Rendering Coordination
- **App struct**: Current file, cursor, scroll, mode, view mode, line_map, syntax highlighter, comment store
- **Mode enum**: NORMAL (navigation and viewing), comment (editing comments)
- **ViewMode enum**: unified or side-by-side
- **Event loop**: Keyboard/terminal events via vaxis
- **Render pipeline**:
  1. Header (file info, stats)
  2. Content (iterate through LineMap records, render based on type)
  3. Status bar (mode, position, context-aware keybindings)
- **Rendering**: Both unified and side-by-side renderers iterate through LineMap records, rendering each line based on its type
- **Colors**: Dark green/red backgrounds for add/delete lines. Syntax highlighting overlays with: red (keywords), magenta (functions), yellow (types), blue (strings/numbers), cyan (comments)
- **Ctrl-C**: Double-press within 1s to exit
- **Refresh**: 'r' key reloads diff, rebuilds LineMap, preserves position

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
- Coverage: arg parsing (3), diff execution (1), parser (3), line_map (2), comments (multiple), editor (line argument modes)

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
- ✅ Vim navigation (j/k, g/G for top/bottom)
- ✅ Side-by-side diff view (toggle with 's' key)
- ✅ Tree-sitter syntax highlighting (JS/TS/Zig with query files)
- ✅ Refresh functionality ('r' key to reload diff)
- ✅ Proper line number tracking in gutters
- ✅ Comment system (Enter to create/edit, tracked via LineMap, delete with d/D)
- ✅ Export comments with context ('y' to yank to clipboard)
- ✅ Editor integration (Ctrl-g opens file at line in $EDITOR)
- ⏳ Hunk navigation
- ⏳ Help overlay

**Phase 3: Polish** (Current)
- Expand syntax highlighting to Python, Rust, Go, C, C++ (parsers ready, need query files)
- ✅ LineMap system for accurate positioning (completed)
- ✅ Async highlighting for non-blocking syntax processing (completed)
- ✅ Editor integration with Ctrl-g (completed)
- Mouse support
- Configuration file
- Color schemes / themes
- Performance profiling and optimization
- Hunk navigation
- Help overlay

**Phase 4: Advanced**
- Comment persistence and management
- Delta integration for enhanced diff rendering
- Fuzzy file search
- Git workflow integration (stage hunks, etc.)

## Key Implementation Notes

### Global Line Coordinate System

**Definition**: A global line is a zero-based sequential index (0, 1, 2, ...) that uniquely identifies every renderable line in the entire diff view. It serves as the absolute coordinate system for positioning and navigation throughout Skim.

**Purpose**:
- **Single source of truth** for all positioning decisions (cursor, scroll, lookups)
- **Prevents sync issues** between navigation and rendering logic that occurred with independent position calculations
- **Makes calculations simple** - cursor and scroll are just global line numbers
- **Consistent references** - any line can be referenced unambiguously regardless of type

**What counts as a global line**:
Every visible element in the rendered diff gets a global line number:
- **File headers** - "diff --git a/file.txt b/file.txt" style headers
- **Hunk headers** - "@@ -1,3 +1,4 @@" range indicators
- **Code lines** - add/delete/context lines from the actual diff content
- **Comment lines** - review comments attached to specific code lines
- **Spacer lines** - blank lines between files (3 spacers per file boundary)

**Concrete Example**:
```
Global Line | Line Type      | Content
------------|----------------|----------------------------------
0           | file_header    | diff --git a/foo.txt b/foo.txt
1           | hunk_header    | @@ -1,2 +1,3 @@
2           | code_line      |  context line
3           | code_line      | -deleted line
4           | comment_line   | "This deletion looks wrong"
5           | code_line      | +added line
6           | spacer         | (blank)
7           | spacer         | (blank)
8           | spacer         | (blank)
9           | file_header    | diff --git a/bar.txt b/bar.txt
10          | hunk_header    | @@ -1,1 +1,1 @@
11          | code_line      | -old content
12          | code_line      | +new content
```

**Usage in the codebase**:
- `app.state.global_cursor_line` - Cursor's current absolute position in the diff
- `app.state.global_scroll_offset` - First visible line in the viewport (top of screen)
- `LineMap.getLineRecord(global_line)` - Look up any line's metadata by its global position
- **Navigation**: Updates `global_cursor_line` to target position (e.g., file header, next line)
- **Rendering**: Starts at `global_scroll_offset`, renders records sequentially until viewport full
- **Bounds checking**: Total lines = `LineMap.getTotalLines()`, valid range is `[0, total_lines)`

**Key invariant**: Global line numbers are always sequential with no gaps. When LineMap is rebuilt (e.g., after adding/deleting comments), all global line numbers are recalculated to maintain this invariant.

### LineMap-Based Rendering Architecture

**Core Principle**: All line positioning comes from a pre-computed LineMap. No on-the-fly position calculations.

**Why LineMap?**: Previously, navigation and rendering calculated positions independently, leading to sync issues especially with comments and spacers. LineMap ensures consistency by computing positions once.

**Rendering Flow**:
1. LineMap built during init (also rebuilt on refresh or when comments change)
2. Renderers (unified/side-by-side) iterate through LineMap records
3. Each record contains: global_line, file_idx, and line_type (union enum with type-specific data)
4. Renderer switches on line_type to render appropriate content
5. Active comment input (before saving) rendered as special case after code lines

**Navigation Flow**:
1. File navigation (h/l): Uses `getFileHeaderLine()` to find exact header position
2. Sets both cursor and scroll_offset to header line (snaps to top)
3. Triggers full re-render with `needs_render = true`
4. Line navigation (j/k): Updates cursor, `ensureCursorVisible()` adds padding

**When to Rebuild LineMap**:
- During init (`app.init()`)
- After refresh (`app.refresh()`)
- After saving comment (`saveCurrentComment()`)
- After deleting comment (`deleteCommentUnderCursor()`)

**Adding New Line Types**:
1. Add variant to `LineType` union enum with required metadata
2. Update `LineMap.build()` to create records for new type
3. Update renderers (unified/side-by-side) to handle new type in switch
4. Add helper functions to LineMap for common queries (e.g., `isFileHeader()`)

### Modal State Management
The app uses an enum-based mode system. When adding new modes:
1. Add variant to `Mode` enum in app.zig
2. Update `handleKeyEvent()` switch statement with mode-specific keybindings
3. Update status bar in `renderStatusBar()` to show mode-appropriate help text
4. Consider mode transition logic and escape paths

### Adding New Keybindings
1. Update appropriate mode case in `handleKeyEvent()` switch (normal or comment mode)
2. Update status bar help text in `renderStatus()` to document the new binding
3. Add entry to README.md keybindings table
4. If adding new vim-style keys, follow vim conventions for consistency

**Current keybindings:**
- NORMAL mode:
  - Navigation: h/l (prev/next file), j/k (cursor up/down with count prefix), g/G (top/bottom), Ctrl-n/p (file nav), Ctrl-d/u (page), Shift+M (center)
  - Comments: Enter (add/edit comment), d (delete comment under cursor), D (clear all comments), y (yank comments to clipboard)
  - View: s (toggle unified/side-by-side), r (refresh diff)
  - Integration: Ctrl-g (open in $EDITOR at line)
  - Exit: q (quit), Ctrl-C twice (force quit)
- comment mode: Enter (save), Shift+Enter (newline), ESC (cancel), regular typing

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
