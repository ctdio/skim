# Skim Architecture

This document provides an in-depth overview of Skim's architecture, design decisions, and implementation details.

## Table of Contents

1. [System Overview](#system-overview)
2. [Module Architecture](#module-architecture)
3. [Data Flow](#data-flow)
4. [Rendering Pipeline](#rendering-pipeline)
5. [Syntax Highlighting](#syntax-highlighting)
6. [Performance Optimizations](#performance-optimizations)
7. [Design Patterns](#design-patterns)

## System Overview

TUI for reviewing git diffs. Priorities: performance, simplicity, correctness.

### Technology Stack

- Zig 0.13.0+
- libvaxis v0.5.1 (TUI)
- z-tree-sitter (syntax highlighting)
- System git binary

## Module Architecture

The codebase is organized into four main layers:

```
┌─────────────────────────────────────────┐
│         CLI Layer (main.zig)            │
│  ┌────────────────────────────────┐     │
│  │ Argument parsing               │     │
│  │ DiffSource configuration       │     │
│  └────────────────────────────────┘     │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│    Application Layer (app.zig)          │
│  ┌────────────────────────────────┐     │
│  │ Modal state machine            │     │
│  │ Event handling                 │     │
│  │ Rendering orchestration        │     │
│  │ Frame buffer management        │     │
│  └────────────────────────────────┘     │
└─────┬───────────────────────────┬───────┘
      │                           │
┌─────▼──────────┐        ┌──────▼────────┐
│  Git Layer     │        │ Syntax Layer  │
│  (git/*.zig)   │        │ (syntax.zig)  │
│  ┌──────────┐  │        │ ┌──────────┐  │
│  │ diff.zig │  │        │ │ Highlighter│ │
│  │ parser   │  │        │ │ Query files│ │
│  └──────────┘  │        │ └──────────┘  │
└────────────────┘        └───────────────┘
```

### 1. CLI Layer (main.zig)

Parse args, configure DiffSource, initialize app, manage memory.

```zig
pub const Config = struct {
    allocator: std.mem.Allocator,
    diff_source: DiffSource,
};
```

Diff patterns: `skim`, `skim --staged`, `skim ref`, `skim ref1 ref2`, `skim ref1..ref2`, `skim ref1...ref2`

### 2. Application Layer (app.zig)

Manages state and rendering.

**App Structure:**
```zig
pub const App = struct {
    allocator: Allocator,
    vx: Vaxis,                    // Terminal instance
    tty: vaxis.Tty,               // TTY handle
    mode: Mode,                   // Current modal state
    state: State,                 // Application state
    should_quit: bool,
    last_ctrl_c: i64,             // For double-press exit
    header_line_buffers: [2][4096]u8,  // Pre-allocated header buffers
    frame_text_buffer: []u8,      // 256KB frame scratch space
    frame_text_used: usize,
    syntax_highlighter: SyntaxHighlighter,
};
```

**Modal System:**
```zig
const Mode = enum {
    normal,   // File navigation, cursor positioning
    focused,  // In-file scrolling with vim keys
    comment,  // Comment editing (placeholder)
};
```

**Application State:**
```zig
const State = struct {
    diff_source: DiffSource,
    files: []parser.FileDiff,           // Parsed diff files
    line_map: LineMap,                  // Pre-computed line positions
    global_cursor_line: usize,          // Cursor position (global line number)
    global_scroll_offset: usize,        // Viewport scroll position (global line number)
    view_mode: ViewMode,                // unified vs. side-by-side
    viewport_height: usize,             // For scroll calculations
    comment_store: CommentStore,        // In-memory comment storage
    syntax_highlighter: SyntaxHighlighter,
};
```

**View Modes:**
```zig
const ViewMode = enum {
    unified,       // Traditional unified diff
    side_by_side,  // Split view with old/new side-by-side
};
```

### 2.5. Line Map Layer (line_map.zig)

The LineMap system provides a **global line coordinate system** - a pre-computed registry of all renderable lines that serves as the single source of truth for positioning.

#### Global Line Coordinate System

**Definition**: A global line is a zero-based sequential index (0, 1, 2, ...) that uniquely identifies every renderable line in the entire diff view.

**Why it exists**:
- Eliminates sync issues between navigation and rendering logic
- Simplifies cursor and scroll calculations (both are just global line numbers)
- Provides consistent, unambiguous references to any line
- Built once, used everywhere - no duplicate position calculations

**What gets a global line number**:
- File headers (e.g., "diff --git a/file.txt b/file.txt")
- Hunk headers (e.g., "@@ -1,3 +1,4 @@")
- Code lines (add/delete/context from diff)
- Comment lines (review comments attached to code lines)
- Spacer lines (3 blank lines between each file)

**Example layout**:
```
Global 0: file_header    "diff --git a/foo.txt b/foo.txt"
Global 1: hunk_header    "@@ -1,2 +1,3 @@"
Global 2: code_line      " context line"
Global 3: code_line      "-deleted line"
Global 4: comment_line   "This deletion looks wrong"
Global 5: code_line      "+added line"
Global 6: spacer         (blank)
Global 7: spacer         (blank)
Global 8: spacer         (blank)
Global 9: file_header    "diff --git a/bar.txt b/bar.txt"
...
```

#### LineMap Structure

```zig
pub const LineRecord = struct {
    global_line: usize,      // Sequential position (0, 1, 2, ...)
    file_idx: usize,         // Which file this line belongs to
    line_type: LineType,     // Union enum with type-specific metadata
};

pub const LineType = union(enum) {
    file_header,
    hunk_header: struct { hunk_idx: usize },
    code_line: struct {
        hunk_idx: usize,
        line_idx_in_hunk: usize,
    },
    comment_line: struct {
        parent_hunk_idx: usize,
        parent_line_idx: usize,
        comment_idx: usize,
    },
    spacer: struct {
        after_file_idx: usize,
        spacer_line_num: usize,
    },
};

pub const LineMap = struct {
    records: []LineRecord,   // All lines in sequential order
    allocator: Allocator,

    pub fn build(allocator, files, comment_store) !LineMap
    pub fn getLineRecord(global_line: usize) ?*const LineRecord
    pub fn getFileHeaderLine(file_idx: usize) ?usize
    pub fn getTotalLines() usize
    // ... other helper methods
};
```

#### Building the LineMap

LineMap is built during initialization and rebuilt when structure changes:
1. Iterate through all files sequentially
2. For each file: add file header, then iterate hunks
3. For each hunk: add hunk header, then iterate lines
4. For each code line: add code line record, check for attached comment
5. If comment exists: add comment line record
6. Between files: add 3 spacer records
7. Assign sequential global line numbers (no gaps)

**Rebuild triggers**:
- Application init
- Diff refresh ('r' key)
- Comment added/saved
- Comment deleted

#### Usage in Navigation & Rendering

**Navigation**:
```zig
// Move cursor down
state.global_cursor_line += 1;

// Jump to file
state.global_cursor_line = line_map.getFileHeaderLine(file_idx);
state.global_scroll_offset = state.global_cursor_line;

// Bounds checking
if (state.global_cursor_line >= line_map.getTotalLines()) {
    state.global_cursor_line = line_map.getTotalLines() - 1;
}
```

**Rendering**:
```zig
// Start from scroll offset, render until viewport full
for (line_map.records) |*record| {
    if (record.global_line < state.global_scroll_offset) continue;
    if (row >= viewport_height) break;

    // Render based on line type
    switch (record.line_type) {
        .file_header => renderFileHeader(),
        .hunk_header => renderHunkHeader(),
        .code_line => renderCodeLine(),
        .comment_line => renderComment(),
        .spacer => renderBlankLine(),
    }
    row += 1;
}
```

**Key invariant**: Global line numbers are always sequential with no gaps (0, 1, 2, ..., N-1).

### 3. Git Integration Layer (git/)

#### git/diff.zig - Command Execution

```zig
pub fn getDiff(allocator: Allocator, source: DiffSource) ![]u8
pub fn getChangedFiles(allocator: Allocator, source: DiffSource) ![]FileStatus
```

Command: `git diff --no-color --no-ext-diff -U7` (7 context lines, 100MB limit)

#### git/parser.zig - Unified Diff Parser

Single-pass O(n) parser.
```zig
pub const FileDiff = struct {
    old_path: []const u8,
    new_path: []const u8,
    hunks: []Hunk,
    highlights: ?[]syntax.Highlight,  // Cached after first render
};

pub const Hunk = struct {
    header: HunkHeader,
    lines: []Line,
};

pub const HunkHeader = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    context: []const u8,
};

pub const Line = struct {
    line_type: LineType,
    content: []const u8,
    old_lineno: ?u32,  // Line number in old file
    new_lineno: ?u32,  // Line number in new file
};
```

Parser state machine: `diff --git` → new file, `---`/`+++` → paths, `@@` → hunk header, `+`/`-`/` ` → lines. Tracks line numbers, handles edge cases.

### 4. Syntax Highlighting Layer (syntax.zig)
```zig
pub const SyntaxHighlighter = struct {
    allocator: std.mem.Allocator,

    pub fn highlightFile(file_path: []const u8, content: []const u8) ![]Highlight
};

pub const Highlight = struct {
    start_byte: usize,
    end_byte: usize,
    category: []const u8,  // e.g., "keyword", "function", "string"
};
```

Languages: JS/JSX, TS/TSX, Zig (full queries). Python, Rust, Go, C/C++ (parsers ready, need queries).

Colors: Keywords (magenta), functions (blue), types (green), strings/numbers (yellow), comments (cyan).

## Data Flow

### Initialization Flow

```
User runs: skim main..feature
    │
    ▼
main.zig: parseArgs()
    │
    ▼
DiffSource{ .two_refs = { "main", "feature" } }
    │
    ▼
App.init()
    │
    ├─▶ git.getDiff() ──▶ Execute: git diff --no-color --no-ext-diff -U7 main feature
    │       │
    │       ▼
    │   parser.parse() ──▶ []FileDiff
    │
    ├─▶ SyntaxHighlighter.init()
    │
    └─▶ vaxis.Tty.init() + Vaxis.init()
    │
    ▼
App.run() ──▶ Event loop starts
```

### Event Loop

```
┌──────────────────────────┐
│   Vaxis Event Loop       │
└────────┬─────────────────┘
         │
         ▼
    Poll events
         │
    ┌────┴────┐
    │ Event?  │
    └────┬────┘
         │
    ┌────▼────────────┐
    │ Key Press       │──▶ handleKey()
    │                 │     │
    │                 │     ├─▶ Mode-specific handler
    │                 │     │   (normal, focused, comment)
    │                 │     │
    │                 │     ├─▶ Update state
    │                 │     │   (cursor, scroll, file index)
    │                 │     │
    │                 │     └─▶ Set should_quit if needed
    └─────────────────┘
         │
    ┌────▼────────────┐
    │ Window Resize   │──▶ vx.resize()
    └─────────────────┘
         │
    ┌────▼────────────┐
    │ Render Frame    │──▶ render()
    │                 │     │
    │                 │     └─▶ Rendering Pipeline
    └─────────────────┘
         │
         └──▶ Loop until should_quit
```

### Refresh Flow

When user presses 'r':

```
handleKey('r')
    │
    ▼
refresh()
    │
    ├─▶ Store current file path
    │
    ├─▶ git.getDiff(diff_source)
    │       │
    │       ▼
    │   parser.parse() ──▶ new []FileDiff
    │
    ├─▶ Find same file in new files
    │   (by path matching)
    │
    ├─▶ Free old FileDiff structs
    │
    ├─▶ Update state.files
    │
    └─▶ Restore file index, reset scroll
```

## Rendering Pipeline

Full frame render each time (optimized for speed):

```
render(win: vaxis.Window)
    │
    ├─▶ Reset frame_text_buffer
    │
    ├─▶ renderHeader()
    │   └─▶ File count, mode, view mode, current file stats
    │
    ├─▶ renderDivider(.top)
    │   └─▶ ╭─────────────────╮
    │
    ├─▶ renderContent()
    │   │
    │   ├─▶ unified: renderContentUnified()
    │   │   │
    │   │   ├─▶ ensureHighlights() (lazy load)
    │   │   │
    │   │   ├─▶ Render borders (│)
    │   │   │
    │   │   └─▶ For each visible line:
    │   │       ├─▶ renderHunkHeader()
    │   │       └─▶ renderDiffLine()
    │   │           ├─▶ renderGutter() (line numbers)
    │   │           └─▶ renderWrappedTextWithHighlights()
    │   │               └─▶ createHighlightedSegments()
    │   │
    │   └─▶ side_by_side: renderContentSideBySide()
    │       └─▶ Similar but two columns with middle divider
    │
    ├─▶ renderDivider(.bottom)
    │   └─▶ ╰─────────────────╯
    │
    └─▶ renderStatus()
        └─▶ Mode-specific keybinding help
```

### Virtual Scrolling
Skip off-screen hunks, render visible lines only.

### Text Wrapping
Long lines wrap to viewport width, line number on first row only.

### Cursor Tracking
3-line padding around cursor, auto-adjust scroll to keep visible.

## Syntax Highlighting

Lazy generation on first render, cached per file:

```zig
fn ensureHighlights(file: *FileDiff) !void {
    if (file.highlights != null) return;  // Already cached

    // Reconstruct NEW file content from diff
    var content = ArrayList(u8).init();
    for (file.hunks) |hunk| {
        for (hunk.lines) |line| {
            switch (line.line_type) {
                .delete => {},  // Skip - not in new file
                .add, .context => {
                    content.append(line.content);
                    content.append('\n');
                },
            }
        }
    }

    // Generate highlights
    highlights = syntax_highlighter.highlightFile(file_path, content.items);
    file.highlights = highlights;  // Cache for subsequent renders
}
```

### Byte Offset Mapping

Calculate byte offset for each line in reconstructed file:

```zig
fn getLineByteOffset(file: *FileDiff, hunk_idx: usize, line_idx: usize) usize {
    var offset: usize = 0;
    for (file.hunks[0..hunk_idx]) |hunk| {
        for (hunk.lines) |line| {
            switch (line.line_type) {
                .delete => {},  // Skip
                .add, .context => offset += line.content.len + 1,
            }
        }
    }
    // Add lines in current hunk up to target line
    return offset;
}
```

### Segment Generation

Convert highlights to terminal segments:

```zig
fn createHighlightedSegments(text: []const u8, byte_offset: usize) ![]Segment {
    // Find highlights overlapping this line
    for (highlights) |h| {
        if (h.end_byte > line_start and h.start_byte < line_end) {
            // Add segment with syntax color
            segments.append(.{
                .text = text[h.start_byte..h.end_byte],
                .style = getStyleForCategory(h.category),
            });
        }
    }
}
```

### Context-Only Highlighting

Context lines get syntax highlighting. Add/delete lines keep solid colors for clarity.

## Performance Optimizations

### Memory Management
- 256KB pre-allocated frame buffer (reused each frame)
- 4KB pre-allocated header buffers

### Lazy Evaluation
- Syntax highlights: generated once, cached
- Viewport culling: skip off-screen hunks

### Single-Pass Algorithms
- Diff parser: tokenize once, no backtracking
- Renderer: one pass top-to-bottom

### Compile-Time Optimizations
- Embedded query files (no runtime I/O)
- Static string maps (constant-time lookups)

## Design Patterns

### Modal State Machine
Vim-inspired modes: normal (file nav), focused (scroll), comment (future).

### Lazy Initialization
Defer expensive ops: syntax highlights, file reconstruction.

### Explicit State Updates
State changes are localized and clear.

### Error Handling
Zig's explicit error propagation with errdefer cleanup.

### Struct-of-Arrays
Cache-friendly: lines stored contiguously in hunks.

## Future Architecture Considerations

### Comment System

Planned architecture for comment functionality:

```zig
pub const Comment = struct {
    file_path: []const u8,
    hunk_idx: usize,
    line_idx: usize,
    content: []const u8,
    timestamp: i64,
};

pub const CommentStore = struct {
    comments: std.ArrayList(Comment),

    pub fn addComment(file: *FileDiff, line_idx: usize, text: []const u8) !void
    pub fn getCommentsForLine(file: *FileDiff, line_idx: usize) []Comment
    pub fn exportAsAnnotatedPatch() ![]u8
};
```

### Configuration System

Planned TOML-based configuration:

```toml
[ui]
theme = "dark"
line_numbers = true
context_lines = 7

[keybindings]
quit = "q"
toggle_view = "s"

[highlighting]
enabled = true
languages = ["javascript", "typescript", "zig"]
```

### Performance Monitoring

Potential instrumentation points:
- Frame render time
- Git command execution time
- Diff parsing time
- Syntax highlighting time
- Memory usage tracking

## Summary

Architecture priorities: performance, simplicity, correctness, extensibility.

Sub-10ms startup, 60 FPS scrolling, ~209KB binary.
