# Skim Architecture Guide

This document provides a comprehensive overview of Skim's codebase architecture, design decisions, and guidelines for maintainers.

## Table of Contents
1. [Architecture Overview](#architecture-overview)
2. [Module Organization](#module-organization)
3. [Key Design Patterns](#key-design-patterns)
4. [Data Flow](#data-flow)
5. [Adding New Features](#adding-new-features)
6. [Code Organization Principles](#code-organization-principles)

---

## Architecture Overview

Skim is organized into five main layers:

```
┌─────────────────────────────────────────────┐
│ CLI Layer (main.zig)                        │
│ - Argument parsing                          │
│ - Initialization                            │
└─────────────────┬───────────────────────────┘
                  │
┌─────────────────▼───────────────────────────┐
│ Application Layer (app.zig)                 │
│ - Modal state machine                       │
│ - Event routing                             │
│ - Rendering coordination                    │
└─────┬───────────────────────────┬───────────┘
      │                           │
┌─────▼──────────┐    ┌──────────▼──────────┐
│ Mode Handlers  │    │ UI Components       │
│ (src/modes/)   │    │ (ui.zig)            │
└────────────────┘    └─────────────────────┘
      │                           │
┌─────▼───────────────────────────▼───────────┐
│ Core Systems                                 │
│ - LineMap (line_map.zig)                    │
│ - Navigation (navigation.zig)               │
│ - State Helpers (state.zig)                 │
└─────┬───────────────────────────┬───────────┘
      │                           │
┌─────▼──────────┐    ┌──────────▼──────────┐
│ Git Integration│    │ Rendering System    │
│ (git/)         │    │ (rendering/)        │
└────────────────┘    └─────────────────────┘
```

### Layer Responsibilities

**CLI Layer** (`main.zig`)
- Parse command-line arguments (working dir, staged, ref comparison)
- Initialize terminal and vaxis
- Create and run App instance

**Application Layer** (`app.zig`)
- Central state machine managing 7 modes: normal, comment, search, visual, command_palette, help, branch_selection
- Event loop handling keyboard and terminal events
- Coordinate rendering pipeline
- **Size:** ~2,500 lines (reduced from 3,099 after refactoring)

**Mode Handlers** (`src/modes/`)
- Isolated logic for each interaction mode
- See [Mode System](#mode-system) for details

**UI Components** (`ui.zig`)
- Header rendering (file info, stats)
- Status bar (mode indicator, keybindings)
- Empty state screens
- Branch selection menu

**Core Systems**
- **LineMap** (`line_map.zig`): Pre-computed position registry for all renderable lines
- **Navigation** (`navigation.zig`): Cursor movement and scrolling logic
- **State Helpers** (`state.zig`): Async highlighting, diff stats

**Git Integration** (`git/`)
- Execute git commands (`git diff`, `git log`, etc.)
- Parse unified diff format
- Track file and hunk metadata

**Rendering System** (`rendering/`)
- Unified diff view (single column)
- Side-by-side diff view (split columns)
- Syntax highlighting integration
- Comment display

---

## Module Organization

### src/ Directory Structure

```
src/
├── main.zig              - CLI entry point
├── app.zig               - Application state machine (2,494 lines)
├── navigation.zig        - Cursor/scroll navigation (559 lines)
├── line_map.zig          - Line position registry (394 lines)
├── state.zig             - State helpers, async highlighting (533 lines)
├── ui.zig                - UI components (647 lines)
├── syntax.zig            - Tree-sitter integration (628 lines)
├── comments.zig          - Comment storage (482 lines)
├── comment_editor.zig    - Vim-like comment editor (1,399 lines)
├── command_palette.zig   - Command palette (567 lines)
├── help.zig              - Help overlay
├── editor.zig            - External editor integration
│
├── modes/                - Mode handlers (extracted Phase 1)
│   ├── normal_mode.zig           (299 lines)
│   ├── comment_mode.zig          (36 lines)
│   ├── search_mode.zig           (72 lines)
│   ├── visual_mode.zig           (78 lines)
│   ├── command_palette_mode.zig  (75 lines)
│   ├── help_mode.zig             (11 lines)
│   └── branch_selection_mode.zig (127 lines)
│
├── git/                  - Git integration
│   ├── diff.zig          - Execute git commands
│   └── parser.zig        - Unified diff parser
│
└── rendering/            - Rendering system
    ├── common.zig        - Color palette, layout constants
    ├── utils.zig         - Rendering utilities (1,104 lines)
    ├── styles.zig        - Style calculation (extracted Phase 2)
    ├── unified.zig       - Unified diff renderer (453 lines)
    ├── side_by_side.zig  - Side-by-side renderer (998 lines)
    └── file_header.zig   - File header rendering
```

### File Size Guidelines

**Target Sizes:**
- **Small:** < 200 lines (focused, single-purpose)
- **Medium:** 200-600 lines (well-defined subsystem)
- **Large:** 600-1,000 lines (complex but cohesive)
- **Very Large:** > 1,000 lines (consider splitting)

**Current Large Files:**
- `rendering/utils.zig` (1,104 lines) - candidate for further splitting
- `comment_editor.zig` (1,399 lines) - complex vim editor, acceptable
- `rendering/side_by_side.zig` (998 lines) - has duplication with unified.zig

---

## Key Design Patterns

### 1. Modal State Machine

Skim uses a central modal state machine in `app.zig`:

```zig
const Mode = enum {
    normal,           // Navigation and viewing
    comment,          // Editing comments
    search,           // Text search
    visual,           // Visual selection (like vim)
    command_palette,  // Command fuzzy finder
    help,             // Help overlay
    branch_selection, // Branch selection menu
};
```

**Event Flow:**
```
User Input → handleKey() → Mode Switch → Mode Handler → Update State → Render
```

**Adding a New Mode:**
1. Add enum variant to `Mode` in `app.zig`
2. Create `src/modes/your_mode.zig` with `pub fn handleKey(app: *App, key: vaxis.Key) !void`
3. Add case to `handleKey()` switch in `app.zig`
4. Add mode indicator to status bar in `ui.zig`

### 2. Global Line Coordinate System

**Definition:** Every renderable line has a unique zero-based index called a "global line number."

**What counts as a line:**
- File headers ("diff --git a/file.txt b/file.txt")
- Hunk headers ("@@ -1,3 +1,4 @@")
- Code lines (add/delete/context)
- Comment lines
- Spacer lines (3 blank lines between files)

**Purpose:**
- Single source of truth for positioning
- Prevents sync issues between navigation and rendering
- Makes cursor and scroll calculations simple

**Example:**
```
Global Line | Type         | Content
-----------|--------------|---------------------------
0          | file_header  | diff --git a/foo.txt ...
1          | hunk_header  | @@ -1,2 +1,3 @@
2          | code_line    |  context line
3          | code_line    | -deleted line
4          | comment_line | "This deletion looks wrong"
5          | code_line    | +added line
6          | spacer       | (blank)
7          | spacer       | (blank)
8          | spacer       | (blank)
9          | file_header  | diff --git a/bar.txt ...
```

**Usage:**
- `app.state.global_cursor_line` - cursor position
- `app.state.global_scroll_offset` - first visible line
- `LineMap.getLineRecord(global_line)` - get line metadata

**Key Invariant:** Global line numbers are always sequential with no gaps.

### 3. LineMap System

The LineMap pre-computes all line positions during initialization.

**Why?**
- Previously, navigation and rendering calculated positions independently → sync bugs
- LineMap ensures one source of truth

**Lifecycle:**
```
Init/Refresh → Build LineMap → Navigation uses it → Rendering uses it
                    ↑
                    └── Rebuild on comment add/delete ─────────┘
```

**LineRecord Structure:**
```zig
const LineRecord = struct {
    global_line: usize,
    file_idx: usize,
    line_type: LineType, // union of file_header, hunk_header, code_line, comment_line, spacer
};
```

**When to Rebuild:**
- `app.init()` - initial build
- `app.refresh()` - diff reload
- `saveCurrentComment()` - after adding comment
- `deleteCommentUnderCursor()` - after deleting comment

### 4. Rendering Pipeline

```
app.render()
    ↓
resetFrameTextBuffer()  (clear 256KB temp buffer)
    ↓
renderHeader()         (file info, stats)
    ↓
renderContent()        (unified OR side_by_side)
    ↓
    Iterate through LineMap records
    ├─ file_header → render file path
    ├─ hunk_header → render @@ range @@
    ├─ code_line → render with syntax highlighting
    ├─ comment_line → render comment box
    └─ spacer → render blank line
    ↓
renderStatus()         (mode, position, keybindings)
```

**Frame Text Buffer:**
- 256KB pre-allocated buffer in `app.state.frame_text_buffer`
- Used for temporary string allocations during rendering
- Reset at start of each frame
- Prevents per-frame heap allocations

### 5. Syntax Highlighting

**Architecture:**
```
Code Line → Request Highlights → Check Cache → If Missing:
                                               ├─ Spawn Background Thread
                                               ├─ Parse with Tree-sitter
                                               ├─ Run Queries
                                               └─ Store in Cache
            ↓
Apply Highlights → Render with Colors
```

**Key Components:**
- `syntax.zig` - Tree-sitter integration
- `state.zig` - HighlightWorker, AsyncHighlightJob
- Cache stored in `FileDiff.cached_highlights`

**Supported Languages:**
- JavaScript, TypeScript (with JSX/TSX)
- Zig, Python, Rust, Go, C, C++

**How it Works:**
1. Highlighting is requested for visible files only
2. Background thread parses file and runs tree-sitter queries
3. Results cached in file struct
4. Syntax colors overlay diff backgrounds (green/red)

---

## Data Flow

### App Initialization

```
main.zig
    ↓
Parse CLI args → Determine DiffSource
    ↓
App.init(allocator, diff_source)
    ↓
git.getDiff() → Execute git command
    ↓
parser.parseDiff() → Parse unified diff
    ↓
LineMap.build() → Compute line positions
    ↓
Run event loop
```

### Keyboard Event Flow

```
User presses key
    ↓
vaxis event loop
    ↓
app.handleKey()
    ↓
Mode-specific handler (src/modes/*)
    ↓
Update state (cursor, mode, etc.)
    ↓
Trigger re-render
```

### Comment Flow

```
User presses Enter on code line
    ↓
startCommentInput()
    ├─ Create CommentInput state
    ├─ Switch to comment mode
    └─ Render comment box
    ↓
User types in comment editor
    ↓
saveCurrentComment()
    ├─ Store in CommentStore
    ├─ Rebuild LineMap (comment now has a line)
    └─ Switch back to normal mode
```

---

## Adding New Features

### Adding a Keybinding

**1. Identify the mode** (normal, comment, visual, etc.)

**2. Edit the mode handler:**
```zig
// src/modes/normal_mode.zig
switch (key.codepoint) {
    'x' => try app.yourNewFeature(),
    // ...
}
```

**3. Implement the feature in app.zig:**
```zig
pub fn yourNewFeature(self: *App) !void {
    // Implementation
}
```

**4. Update status bar help text:**
```zig
// src/ui.zig - renderStatus()
// Add your keybinding to the help text
```

### Adding a New Mode

See [Modal State Machine](#1-modal-state-machine) section.

### Adding a Language for Syntax Highlighting

**1. Add tree-sitter grammar to `build.zig.zon`**

**2. Add language detection in `syntax.zig`:**
```zig
fn detectLanguage(path: []const u8) ?Language {
    // Add file extension mapping
}
```

**3. Add query file:**
- Create `queries/your-language.scm` with tree-sitter queries
- Embed in `build.zig`

**4. Update documentation**

---

## Code Organization Principles

### From CLAUDE.md

**File Structure (top-down):**
```zig
// 1. Imports (all at top, no gaps)
const std = @import("std");
const vaxis = @import("vaxis");

// 2. Types/Interfaces (all together)
const MyType = struct { ... };

// 3. Constants (if any)
const DEFAULT_VALUE = 10;

// 4. Main exports - the "what" this module does
pub fn mainFeature() void { ... }

// 5. Implementation details - the "how" it works
fn helper() void { ... }
```

**Function Rules:**
- Use `fn` keyword (not arrow functions)
- Public functions first, helpers at bottom
- Keep functions focused (< 100 lines ideal)

**Error Handling:**
- Use `err` in catch blocks (not `e`, `error`, or `ex`)
- Pass full error object to logger
```zig
catch (err) {
    logger.error({ err, context }, "Operation failed");
}
```

**Type Safety:**
- Avoid `any` - use proper interfaces
- Use `unknown` with type guards when needed
- Prefer explicit types over inference in public APIs

### Locality of Behavior

**Principle:** Behavior should be obvious from looking at the code.

**Good:**
```zig
pub fn handleSearch(app: *App) void {
    const query = app.getQuery();
    const results = search(query);
    app.displayResults(results);
}
```

**Bad:**
```zig
// Behavior hidden in event subscriptions elsewhere
pub fn handleSearch(app: *App) void {
    eventBus.emit("search_start", app);
}
```

### When to Extract Code

**Extract to new file when:**
- Module exceeds 1,000 lines
- Clear subsystem with distinct responsibility
- Code is reused across multiple files
- Testing in isolation would be valuable

**Keep together when:**
- Tightly coupled (changes together)
- Small and focused (< 500 lines)
- Only used in one place

---

## Performance Considerations

### Targets

- **Cold startup:** < 10ms ✅
- **Binary size:** < 2MB ✅ (currently 209KB release)
- **Memory usage:** < 50MB ✅
- **Scrolling FPS:** 60 ✅

### Optimizations

**1. Pre-allocation:**
- 256KB frame text buffer (avoids per-frame allocations)
- LineMap computed once (not per render)

**2. Virtual Scrolling:**
- Only render visible lines
- Skip highlighting for off-screen files

**3. Async Highlighting:**
- Non-blocking tree-sitter parsing
- Cache results per file

**4. Shell-out to Git:**
- Respects user config
- No git library dependency (smaller binary)

---

## Testing Strategy

### Current State

- Unit tests colocated with implementation
- Run with `zig build test`
- Coverage: arg parsing, diff execution, parser, line_map, comments, editor

### Adding Tests

```zig
// At bottom of your_module.zig
test "describe what you're testing" {
    const allocator = std.testing.allocator;
    // Test implementation
    try std.testing.expectEqual(expected, actual);
}
```

### Test TUI Apps

- Use `std.log` for debugging (goes to stderr)
- Write to file if needed
- Terminal may be corrupted on crash (run `reset`)

---

## Common Patterns

### Accessing Line Content

```zig
const record = app.state.line_map.getLineRecord(global_line) orelse return;
const file = &app.state.files[record.file_idx];

switch (record.line_type) {
    .code_line => |code| {
        const line = &file.hunks[code.hunk_idx].lines[code.line_idx_in_hunk];
        const content = line.content;
    },
    // ...
}
```

### Navigating to a File

```zig
const header_line = app.state.line_map.getFileHeaderLine(file_idx) orelse return;
app.state.global_cursor_line = header_line;
app.state.global_scroll_offset = header_line;
Navigation.ensureCursorVisible(app, false);
```

### Adding a Comment

```zig
// Create comment
const comment = try app.state.comment_store.addComment(
    file_path, hunk_idx, line_idx, line_type, line_content,
    old_line_num, new_line_num, comment_text
);

// Rebuild LineMap to include new comment line
app.state.line_map.deinit();
app.state.line_map = try line_map.LineMap.build(...);
```

---

## Debugging Tips

### Enable Debug Logging

```bash
# Build debug binary
zig build

# Run with stderr logging
./zig-out/bin/skim 2>debug.log

# View logs
tail -f debug.log
```

### Common Issues

**LineMap out of sync:**
- Check if LineMap was rebuilt after state changes
- Verify global line bounds checking

**Rendering glitches:**
- Check frame text buffer hasn't overflowed
- Verify segment widths calculated correctly

**Mode confusion:**
- Add logging to mode transitions
- Check mode state in status bar

---

## Future Architecture Improvements

### Potential Refactorings (Not Prioritized)

**1. Context Structs (High Impact, High Complexity)**
- Replace `app: *App` with focused contexts
- `RenderContext`, `NavigationContext`, `StateContext`
- Benefits: Better testability, clearer dependencies
- Effort: Touches many files

**2. Rendering Base Consolidation (Medium Impact, High Complexity)**
- Extract common logic from unified.zig and side_by_side.zig
- ~200 lines of duplicated hunk header rendering
- Benefits: DRY, easier to maintain
- Effort: Requires careful testing of both renderers

**3. Comment System Organization (Medium Impact, Medium Complexity)**
- Create `src/comments/` directory
- Consolidate: storage, editor, rendering, operations
- Benefits: Better organization
- Effort: Moderate refactoring

**4. Split rendering/utils.zig (Low-Medium Impact, Medium Complexity)**
- Create: text_utils.zig, comment_rendering.zig, gutter_rendering.zig
- Benefits: Smaller, focused files
- Effort: Extract ~1,100 lines

---

## Conclusion

Skim's architecture emphasizes:
- **Clarity:** Modal state machine with isolated mode handlers
- **Performance:** Pre-allocation, virtual scrolling, async highlighting
- **Maintainability:** Focused modules, clear data flow
- **Simplicity:** Minimal dependencies, shell-out to git

The recent refactoring (Phases 1-2) has significantly improved code organization, reducing app.zig by 20% and creating a clear module structure for modes.

For questions or suggestions, see the main README.md or open an issue.
