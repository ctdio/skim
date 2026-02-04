# Skim Architecture Guide

This document provides a comprehensive overview of Skim's codebase architecture, design decisions, and guidelines for maintainers.

## Table of Contents
1. [Architecture Overview](#architecture-overview)
2. [Module Organization](#module-organization)
3. [Key Design Patterns](#key-design-patterns)
4. [Data Flow](#data-flow)
5. [Adding New Features](#adding-new-features)
6. [Code Organization Principles](#code-organization-principles)
7. [AI Integration Architecture](#ai-integration-architecture)
8. [Logging System](#logging-system)
9. [Performance Benchmarks](#performance-benchmarks)

---

## Architecture Overview

Skim is organized into several main layers:

```
┌─────────────────────────────────────────────┐
│ CLI Layer (main.zig)                        │
│ - Argument parsing                          │
│ - Initialization                            │
│ - Subcommand routing (mcp, session)         │
└─────────────────┬───────────────────────────┘
                  │
┌─────────────────▼───────────────────────────┐
│ Application Layer (app.zig)                 │
│ - Modal state machine (14 modes)            │
│ - Event routing                             │
│ - Rendering coordination                    │
│ - Agent session management                  │
└─────┬───────────────────────────┬───────────┘
      │                           │
┌─────▼──────────┐    ┌──────────▼──────────┐
│ Mode Handlers  │    │ UI Components       │
│ (src/modes/)   │    │ (ui.zig)            │
└────────────────┘    └─────────────────────┘
      │                           │
┌─────▼───────────────────────────▼───────────┐
│ Core Systems                                │
│ - LineMap (line_map.zig)                    │
│ - Navigation (navigation.zig)               │
│ - State Helpers (state.zig)                 │
│ - Logging (logging.zig)                     │
└─────┬───────────────────────────┬───────────┘
      │                           │
┌─────▼──────────┐    ┌──────────▼──────────┐
│ Git Integration│    │ Rendering System    │
│ (git/)         │    │ (rendering/)        │
└────────────────┘    └─────────────────────┘

┌─────────────────────────────────────────────┐
│ AI Integration                              │
├─────────────────────────────────────────────┤
│ Agent Panel (acp/ + agent/)                 │
│ - Direct subprocess spawning                │
│ - JSON-RPC over stdio                       │
│ - Built-in chat UI                          │
├─────────────────────────────────────────────┤
│ MCP Server (mcp/)                           │
│ - stdio server for external agents          │
│ - Tools: list_clients, add_comment, etc.    │
└─────────────────────────────────────────────┘
```

### Layer Responsibilities

**CLI Layer** (`main.zig`)
- Parse command-line arguments (working dir, staged, ref comparison)
- Route subcommands (`mcp`, `session`)
- Initialize terminal and vaxis
- Create and run App instance

**Application Layer** (`app.zig`)
- Central state machine managing 14 modes (see Mode System below)
- Event loop handling keyboard and terminal events
- Coordinate rendering pipeline
- Manage ACP agent sessions
- **Size:** ~5,000 lines

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
├── main.zig, app.zig  - Entry point and core state machine
├── modes/             - Modal input handlers (one file per mode)
├── acp/               - Agent Client Protocol (built-in agent panel)
├── agent/             - Agent UI rendering, state, and markdown
├── mcp/               - MCP server for external agents
├── cli/               - CLI subcommands (session, comment)
├── git/               - Git integration and diff parsing
├── rendering/         - Diff view rendering (unified, side-by-side)
├── highlighting/      - Syntax highlighting (tree-sitter)
├── comments/          - Comment storage and editing
├── testing/           - Snapshot testing infrastructure
└── queries/           - Tree-sitter query files (.scm)
```

Key root-level files: `line_map.zig` (position registry), `navigation.zig` (cursor/scroll), `ui.zig` (UI components), `logging.zig` (file-based logging), `config.zig` (configuration).

### File Size Guidelines

**Target Sizes:**
- **Small:** < 200 lines (focused, single-purpose)
- **Medium:** 200-600 lines (well-defined subsystem)
- **Large:** 600-1,000 lines (complex but cohesive)
- **Very Large:** > 1,000 lines (consider splitting)

Large files are acceptable when they represent cohesive subsystems (e.g., `app.zig` as the central state machine, agent mode handlers, rendering engines). Split when a file has multiple unrelated responsibilities.

---

## Key Design Patterns

### 1. Modal State Machine

Skim uses a central modal state machine in `app.zig`:

```zig
const Mode = enum {
    normal,            // Navigation and viewing
    comment,           // Editing comments
    search,            // Text search
    visual,            // Visual selection (like vim)
    command_palette,   // Command fuzzy finder
    help,              // Help overlay
    branch_selection,  // Branch selection menu
    commit_selection,  // Commit picker
    commit_diff_mode,  // Post-commit picker submenu
    graphite_stack,    // Graphite stack navigator
    agent,             // Agent chat panel
    model_selection,   // AI model picker
    agent_selection,   // Agent application picker
    session_picker,    // Session resumption picker
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

- **Cold startup:** < 10ms
- **Binary size:** < 2MB (currently ~209KB release)
- **Memory usage:** < 50MB
- **Scrolling FPS:** 60

### Frame Buffer (Bump Allocator Pattern)

Rendering requires many temporary strings (formatted line numbers, padded text, etc.). Instead of allocating/freeing each string, we use a pre-allocated 256KB buffer that works like a bump allocator:

- `frame_text_buffer`: Fixed buffer allocated once at startup
- `frame_text_used`: Counter tracking current position
- `resetFrameTextBuffer()`: Resets counter to 0 at start of each frame
- `frameTextSlice(len)`: Returns next `len` bytes, advances counter

This eliminates per-frame heap allocations entirely. The buffer is large enough for any reasonable frame, and "freeing" is just resetting a counter.

### LineMap (Precomputed Position Registry)

The LineMap is the source of truth for all renderable lines (file headers, hunk headers, code lines, comments, spacers). It's built once and only rebuilt when structure changes.

**Why it matters:** Navigation and rendering both need to know "what's at line N?" If they computed this independently, they'd drift out of sync. The LineMap ensures both use the same data.

**Rebuild triggers:**
- Initial load
- Diff refresh
- Comment add/delete
- Hunk view mode change

**Not rebuilt for:** Scrolling, cursor movement, search, or any read-only operation.

The agent panel uses the same pattern with `ChatLineMap` for message rendering.

### Virtual Scrolling

Only visible lines are rendered. The render loop checks each line against the scroll offset and viewport height:

```zig
if (global_line < scroll_offset) continue;
if (global_line >= scroll_offset + viewport_height) break;
```

This keeps render time constant regardless of diff size.

### Agent Streaming Performance

During agent responses, text streams in continuously. Naive approaches would rebuild the entire line map on every chunk, causing stuttering.

**Optimizations:**
- **Throttled rebuilds:** Line map updates capped at ~30fps (32ms intervals)
- **Incremental updates:** `updateLastMessage()` only recomputes the streaming message, not the entire history
- **Append-only content:** Streaming text appends to a buffer; no reallocations until message completes

### Async Syntax Highlighting

Tree-sitter parsing happens in a background thread with a persistent parser cache:

- Main thread requests highlights for visible hunks
- Worker thread parses and runs queries
- Results cached per file in `FileDiff.cached_highlights`
- Cache invalidated only on refresh

This keeps the main thread responsive during initial load of large diffs.

### Shell-out to Git

Skim runs `git diff` as a subprocess rather than linking a git library:

- Respects user's git config (aliases, diff settings)
- No library initialization overhead
- Smaller binary size
- Parsing unified diff format is straightforward

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

## AI Integration Architecture

Skim integrates with AI agents in two ways: a built-in agent panel (ACP) and an MCP server for external agents.

### 1. Agent Panel (ACP - Agent Client Protocol)

The built-in agent panel uses direct subprocess communication. Agents are spawned as child processes with JSON-RPC over stdio.

```
┌─────────────────────────────────────────────────────────────────┐
│                      Skim TUI                                    │
│  - Spawns agent as child process                                │
│  - Sends/receives JSON-RPC messages via stdio                   │
│  - Renders responses in chat panel                              │
│  - Handles permission prompts, tool calls                       │
└───────────────────────────┬─────────────────────────────────────┘
                            │ stdio (JSON-RPC)
┌───────────────────────────▼─────────────────────────────────────┐
│                    AI Agent Process                              │
│  (Claude Code, Codex, OpenCode, etc.)                           │
└─────────────────────────────────────────────────────────────────┘
```

**Key Components:**

**ACP Manager (`acp/manager.zig`)**
- Session lifecycle management
- Agent discovery from `~/.skim/config.json` or `~/.acp/agents.json`
- State machine: initializing → ready → connected
- Permission handling for agent actions

**ACP Client (`acp/client.zig`)**
- Spawns agent subprocess
- Sends prompts, receives streaming responses
- Tool call handling
- Message aggregation from streaming chunks

**ACP Codec (`acp/codec.zig`)**
- JSON-RPC encoding/decoding
- Streaming JSON handling (agents send partial responses)
- Message ID tracking for request-response correlation

**Session Adapters (`acp/sessions/`)**
- Vendor-specific adapters (Claude, Codex)
- Session history parsing for resumption
- Agent capability detection

**Agent UI (`agent/`)**
- `state.zig`: Agent panel state machine, input handling
- `render.zig`: Chat panel rendering with message streaming
- `chat_line_map.zig`: Message line registry (like LineMap for diff)
- `markdown/`: Full markdown parser and renderer with syntax highlighting

### 2. MCP Server (External Agents)

For AI agents that support MCP (Model Context Protocol), skim provides a stdio-based server.

```
┌─────────────────────────────────────────────────────────────────┐
│                     AI Agent (Claude Desktop, etc.)              │
│  - Invokes MCP tools via JSON-RPC                               │
└───────────────────────────┬─────────────────────────────────────┘
                            │ JSON-RPC over stdio
┌───────────────────────────▼─────────────────────────────────────┐
│                  MCP Server (skim mcp --stdio)                   │
│  - Reads JSON-RPC from stdin, writes to stdout                  │
│  - Implements MCP tools directly                                │
│  - Connects to running TUI instances                            │
└─────────────────────────────────────────────────────────────────┘
```

**MCP Tools (`mcp/tools.zig`)**
- `list_clients`: List connected TUI instances
- `add_comment`: Add comment to specific file/line
- `get_comments`: Retrieve all comments
- `get_diff_context`: Get diff metadata (files, stats)
- `get_file_diff`: Get full diff content for a file

**Framework (`mcp/framework.zig`)**
- Mini MCP JSON-RPC 2.0 implementation
- Tool registration with JSON schema generation
- Request/response encoding
- Error handling with MCP error codes

### CLI Commands for Agents

The `skim session` command provides CLI access for agent integration:

```bash
skim session list           # List running skim sessions
skim session context        # Get session context (files, diff ref)
skim session diff           # Get diff content with line numbers
skim session comment add    # Add a comment
skim session comment list   # List all comments
```

---

## Logging System

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    std.log.* calls                              │
│  std.log.debug("message", .{});                                 │
│  std.log.info("message", .{});                                  │
│  std.log.err("message", .{});                                   │
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│                    logging.logFn                                │
│  - Custom log function (overrides std.log default)              │
│  - Thread-safe via mutex                                        │
│  - Formats: [HH:MM:SS] [LEVEL] (scope) message                  │
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│                 Component-specific log file                     │
│  ~/.skim/tui.log     - TUI client logs                          │
│  ~/.skim/mcp.log     - MCP server logs                          │
└─────────────────────────────────────────────────────────────────┘
```

### Initialization

Each component initializes logging with its type:
```zig
logging.init(.tui);      // In TUI main
logging.init(.mcp);      // In mcp command
defer logging.deinit();
```

### Why File-Based Logging?

- TUI uses stdout for rendering (vaxis)
- stderr also captured by terminal handling
- File logs persist for debugging
- Can `tail -f` for real-time viewing

---

## Performance Benchmarks

Skim includes a synthetic render benchmark that exercises the hot render paths (wrapping, syntax segments, padding, gutter). Use it for baseline comparisons and regression checks.

Run (ReleaseFast is recommended for perf numbers):

```bash
zig build bench-render-content -Doptimize=ReleaseFast
```

Common environment knobs:

- `SKIM_BENCH_VIEW=unified|side_by_side|both`
- `SKIM_BENCH_FILES=10`
- `SKIM_BENCH_HUNKS=6`
- `SKIM_BENCH_LINES=60`
- `SKIM_BENCH_ITERS=300`
- `SKIM_BENCH_WARMUP=50`
- `SKIM_BENCH_WIDTH=190`
- `SKIM_BENCH_HEIGHT=60`
- `SKIM_BENCH_SCROLL=0`
- `SKIM_BENCH_SEARCH="return"` (enable search highlight work)
- `SKIM_BENCH_DIFF_PATH=path/to/diff.patch` (use a real diff file instead of synthetic)

Example runs:

```bash
SKIM_BENCH_VIEW=both \
SKIM_BENCH_ITERS=300 \
SKIM_BENCH_WARMUP=50 \
zig build bench-render-content -Doptimize=ReleaseFast
```

```bash
SKIM_BENCH_DIFF_PATH=fixtures/large.diff \
SKIM_BENCH_VIEW=unified \
SKIM_BENCH_SEARCH="return" \
zig build bench-render-content -Doptimize=ReleaseFast
```

### Performance Techniques

These are the core techniques currently used to keep rendering responsive:

- **LineMap start index:** renderers jump directly to `global_scroll_offset` instead of scanning from line 0.
- **Cached file stats/gutter width:** per-file diff stats and base gutter width are precomputed to avoid per-frame scans.
- **ASCII fast path for wrapping:** `sliceByDisplayWidth` avoids Unicode width calls for common ASCII lines.
- **Per-hunk line offsets:** byte offsets for new/old views are precomputed per hunk to avoid per-line scans.
- **Ordered highlight walk:** highlight segments are built by walking sorted ranges with a binary search start, avoiding full overlap scans.
- **Per-line highlight spans:** line-local highlight spans are cached with precomputed color categories, reducing per-frame mapping overhead.
- **Frame segment arena:** per-frame segment allocations use a bump arena that resets each render, reducing allocator churn (largest observed speedup in render-content benchmarks).
- **Search match binary search:** search highlighting checks line membership via binary search instead of linear scans.

### Render Profiling

Enable per-frame render timing logs via environment variables:

```bash
SKIM_PROFILE_RENDER=1 SKIM_PROFILE_RENDER_EVERY=30 ./zig-out/bin/skim
```

Logs are written to `~/.skim/tui.log` with `profile_render` and `profile_loop` scopes.

---

## Conclusion

Skim's architecture emphasizes:
- **Clarity:** Modal state machine with isolated mode handlers
- **Performance:** Pre-allocation, virtual scrolling, async highlighting
- **Maintainability:** Focused modules, clear data flow
- **Simplicity:** Minimal dependencies, shell-out to git
- **Extensibility:** Direct subprocess spawning for AI agents (ACP + MCP)

The AI integration provides both a built-in agent panel (via ACP) and an MCP server for external agents, enabling flexible AI-assisted code reviews while maintaining the lightweight, fast nature of the core TUI.

For questions or suggestions, see the main README.md or open an issue.
