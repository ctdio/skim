# AGENTS.md

This file provides guidance to AI agents when working with code in this repository.

## Project Overview

Skim is a keyboard-driven TUI for code reviews built in Zig. Vim-style navigation, sub-10ms startup, 60 FPS scrolling.

**Current Status**: Alpha - AI agent integration complete (ACP + MCP support).

## Build System

### Prerequisites
- Zig 0.15.1 or later
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
  - vaxis (TUI rendering)
  - tree-sitter + language grammars (syntax highlighting - JS, TS, Zig, Python, Rust, Go, C, C++, JSON, YAML, TOML, Markdown, HTML, CSS, Bash)
- Release builds strip symbols (~209KB)

## Architecture

For detailed architecture documentation, see [docs/architecture.md](docs/architecture.md).

**Quick Overview:**
- **CLI Layer** (`main.zig`): Arg parsing, init, subcommand routing
- **Application Layer** (`app.zig`): Modal state machine, event handling
- **Line Tracking** (`line_map.zig`): Position registry
- **Git Integration** (`git/`): Command execution, diff parsing
- **Rendering** (`rendering/`): Unified/side-by-side views
- **Syntax Highlighting** (`highlighting/`): Async tree-sitter with parser caching
- **ACP System** (`acp/`): Agent Client Protocol for built-in agent panel
- **Agent UI** (`agent/`): Chat panel, markdown rendering, message history
- **MCP Server** (`mcp/`): Model Context Protocol for external agent integration
- **CLI Commands** (`cli/`): Session management, comment operations
- **Logging** (`logging.zig`): File logging to `~/.skim/*.log`

**Key Design Principles:**
- Modal interface (vim-style)
- Shell-out to git (respects user config)
- LineMap registry for positioning
- Virtual scrolling (render visible lines only)
- Minimal dependencies (vaxis + tree-sitter)
- Direct subprocess spawning for AI agents (no daemon)

## Logging System

Logs are written to files in `~/.skim/` instead of stderr (since stdout/stderr are used for TUI rendering):

```bash
~/.skim/
├── tui.log      # TUI client logs
└── mcp.log      # MCP adapter logs
```

**Using logs for debugging:**
```bash
# Watch TUI logs in real-time
tail -f ~/.skim/tui.log
```

The logging module (`src/logging.zig`) overrides `std.log` to write to these files with timestamps and log levels.

## AI Integration Overview

Skim integrates with AI agents in two ways:

### 1. Agent Panel (ACP - Built-in)

The built-in agent panel (`Ctrl-e`) uses the Agent Client Protocol for direct communication with AI agents. Agents are spawned as subprocesses with stdio communication.

```
┌─────────────────────────────────────────────────────────────────┐
│                      Skim TUI                                   │
│  - Spawns agent as child process                                │
│  - Communicates via JSON-RPC over stdio                         │
│  - Renders agent responses in chat panel                        │
└───────────────────────────┬─────────────────────────────────────┘
                            │ stdio (JSON-RPC)
┌───────────────────────────▼─────────────────────────────────────┐
│                    AI Agent Process                             │
│  (Claude Code, Codex, etc.)                                     │
└─────────────────────────────────────────────────────────────────┘
```

**Key ACP files:**
- `acp/manager.zig`: Session lifecycle and agent discovery
- `acp/client.zig`: Agent communication and message handling
- `acp/codec.zig`: JSON-RPC encoding/decoding
- `acp/transport.zig`: Stdio transport layer
- `acp/process.zig`: Agent process spawning
- `acp/sessions/`: Vendor-specific adapters (Claude, Codex)

**Key Agent UI files:**
- `agent/state.zig`: Agent panel state machine
- `agent/render.zig`: Chat panel rendering
- `agent/chat_line_map.zig`: Message line registry
- `agent/markdown/`: Markdown parsing and rendering

### 2. MCP Server (External Agents)

For AI agents that support MCP (Model Context Protocol), skim provides a stdio-based MCP server (`skim mcp --stdio`).

**Key MCP files:**
- `mcp/adapter.zig`: stdio MCP server for external agents
- `mcp/tools.zig`: MCP tool implementations (list_clients, add_comment, etc.)
- `mcp/framework.zig`: Mini MCP JSON-RPC framework

## Development Workflow

### Testing
- Tests colocated with implementation
- Run: `zig build test`
- Coverage includes: arg parsing, diff execution, parser, line_map, comments, editor

### Snapshot Testing (IMPORTANT for UI changes)

**When modifying UI rendering, ALWAYS add or update snapshot tests.**

The project uses snapshot testing to verify UI output. Infrastructure is in `src/testing/`:
- `snapshot.zig`: Core snapshot comparison logic
- `harness.zig`: Mock screen/window for capturing rendered output
- `snapshot_scenarios.zig`: Test scenarios organized by domain
- `snapshots/`: 55+ snapshot files (`.snap` extension)

**Three testing domains:**
1. **Diff rendering** - File headers, hunk headers, diff lines (`diff_test_helpers.zig`)
2. **Agent chat UI** - Messages, tool calls, plan entries (`agent_test_helpers.zig`)
3. **Markdown rendering** - Headers, formatting, code blocks (`markdown_test_helpers.zig`)

**Running snapshot tests:**
```bash
# Run tests (compares against existing snapshots)
zig build test

# Update snapshots after intentional changes
SKIM_UPDATE_SNAPSHOTS=1 zig build test
```

**Writing a snapshot test:**
```zig
test "snapshot: my_feature" {
    const allocator = std.testing.allocator;
    var ctx = try harness.createTestContext(allocator, 80, 24);
    defer ctx.deinit();

    // Render to test window
    const win = ctx.window();
    renderMyFeature(win, params, ctx.frameAllocator());

    // Compare against snapshot
    const text = try ctx.captureToText();
    defer allocator.free(text);
    try snapshot.expectSnapshot(allocator, "my_feature", text);
}
```

**When to add snapshot tests:**
- Adding new UI components or rendering functions
- Modifying existing renderers (diff lines, headers, status bar, etc.)
- Changing text formatting, spacing, or visual structure
- Adding new line types to LineMap

### Debugging TUI Apps
- Stdout/stderr not available (TUI rendering) - logs go to `~/.skim/*.log`
- Use `std.log.debug/info/warn/err()` - routed to component-specific log files
- Watch logs in real-time: `tail -f ~/.skim/tui.log`
- Terminal in raw mode - crashes may corrupt it (run `reset`)
- Debug builds: `zig build` (better stack traces, assertions enabled)

### Code Style
- Run `zig fmt`
- Descriptive names, focused functions
- Explicit error handling

## Key Implementation Patterns

See [docs/architecture.md](docs/architecture.md).

### LineMap System
- Registry of renderable lines (file headers, hunk headers, code lines, comments, spacers)
- Source of truth for positioning
- Global line numbers (0-based, sequential)
- Rebuilt on: init, refresh, comment add/delete

### Modal State Machine
- Modes: normal, comment, search, visual, command_palette, help, branch_selection, commit_selection, graphite_stack, agent, model_selection, agent_selection, session_picker
- Mode handlers in `src/modes/`
- When adding modes: update `Mode` enum, create handler file, update status bar

### Adding Features
- **New keybinding**: Update mode handler in `src/modes/`, update status bar help, update README
- **New language**: Add grammar to `build.zig.zon`, update `highlighting/core.zig`, add `.scm` query file in `queries/`
- **New line type**: Update `LineType` enum, update `LineMap.build()`, update renderers, **add snapshot tests**
- **New MCP tool**: Add to `src/mcp/tools.zig`, update tool docs
- **UI rendering changes**: Update renderers, **add/update snapshot tests in `src/testing/`**

## Git Integration

Three diff modes:
1. Working directory: `skim`
2. Staged: `skim --staged`
3. Ref comparison: `skim ref1..ref2`

Runs git in CWD, respects user config.
