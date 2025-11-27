# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Skim is a keyboard-driven TUI for code reviews built in Zig. Vim-style navigation, sub-10ms startup, 60 FPS scrolling.

**Current Status**: Alpha - Phase 4 in progress (MCP daemon, AI agent integration, review command system).

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
- **CLI Layer** (`main.zig`): Arg parsing, initialization, subcommand routing
- **Application Layer** (`app.zig`): Modal state machine, event handling
- **Line Tracking** (`line_map.zig`): Pre-computed position registry
- **Git Integration** (`git/`): Command execution, diff parsing
- **Rendering** (`rendering/`): Unified and side-by-side views
- **Syntax Highlighting** (`syntax.zig`): Async tree-sitter integration
- **MCP System** (`mcp/`): Daemon, adapters, and protocol for AI agent integration
- **Logging** (`logging.zig`): File-based logging to `~/.skim/*.log`
- **Review** (`review.zig`, `config.zig`): Review command execution with template substitution

**Key Design Principles:**
- Modal interface (vim-style)
- Shell-out to git (respects user config)
- LineMap system (single source of truth for positioning)
- Virtual scrolling (render visible lines only)
- Minimal dependencies (vaxis + z-tree-sitter)
- Daemon architecture for AI agent integration

## Logging System

Logs are written to files in `~/.skim/` instead of stderr (since stdout/stderr are used for TUI rendering):

```bash
~/.skim/
├── tui.log      # TUI client logs
├── daemon.log   # Daemon process logs
├── mcp.log      # MCP adapter logs
└── review.log   # Review command output
```

**Using logs for debugging:**
```bash
# Watch TUI logs in real-time
tail -f ~/.skim/tui.log

# Watch daemon logs
tail -f ~/.skim/daemon.log

# View review output
cat ~/.skim/review.log
```

The logging module (`src/logging.zig`) overrides `std.log` to write to these files with timestamps and log levels.

## MCP System Overview

The MCP (Model Context Protocol) system enables AI agents to interact with skim. It uses a daemon architecture:

```
┌─────────────────────────────────────────────────────────────────┐
│                     AI Agent (Claude, etc.)                     │
└───────────────────────────┬─────────────────────────────────────┘
                            │ JSON-RPC over stdio
┌───────────────────────────▼─────────────────────────────────────┐
│                    MCP Adapter (skim mcp --stdio)               │
│                    Translates MCP ↔ Internal Protocol           │
└───────────────────────────┬─────────────────────────────────────┘
                            │ TCP (port 9998)
┌───────────────────────────▼─────────────────────────────────────┐
│                         Daemon                                  │
│  - Manages TUI client registry                                  │
│  - Routes messages between adapters and TUI clients             │
│  - Implements MCP tools (list_clients, add_comment, etc.)       │
└───────────────────────────┬─────────────────────────────────────┘
                            │ TCP (port 9999)
┌───────────────────────────▼─────────────────────────────────────┐
│                      Skim TUI Client                            │
│  - Connects to daemon on startup                                │
│  - Registers with session info (cwd, diff_ref, files)           │
│  - Responds to daemon requests (add_comment, get_diff, etc.)    │
└─────────────────────────────────────────────────────────────────┘
```

**Key MCP files:**
- `daemon.zig`: Central server managing clients and adapters
- `adapter.zig`: stdio adapter for AI agents (MCP JSON-RPC)
- `client.zig`: TUI-side client connecting to daemon
- `protocol.zig`: TUI ↔ Daemon message protocol
- `tools.zig`: MCP tool implementations (list_clients, add_comment, etc.)
- `discovery.zig`: Daemon discovery via `~/.skim/daemon.json`
- `framework.zig`: Mini MCP JSON-RPC framework

## Review Command System

The review command (`R` key) runs a configurable shell command that can invoke an AI agent:

**Configuration priority:**
1. `SKIM_REVIEW_COMMAND` environment variable
2. `~/.skim/config.json` with `review_command` field

**Template variables in commands:**
- `{client_id}` - Skim session ID (for MCP targeting)
- `{repo}` - Git repository path
- `{diff_ref}` - Diff reference (e.g., "staged", "main..feature")
- `{adapter_port}` - MCP adapter port (default 9998)

**Example:**
```bash
export SKIM_REVIEW_COMMAND='claude --mcp skim "Review {diff_ref} in {repo}"'
```

**Implementation:**
- `config.zig`: Loads command and performs template substitution
- `review.zig`: Spawns process, manages lifecycle, reads output
- Output redirected to `~/.skim/review.log`
- Status viewable via `L` key (review log panel)

## Development Workflow

### Testing
- Tests colocated with implementation
- Run: `zig build test`
- Coverage includes: arg parsing, diff execution, parser, line_map, comments, editor

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
- **New MCP tool**: Add to `src/mcp/tools.zig`, register in `createServer()`, update tool docs
- **New template var**: Add to `ReviewContext` struct, update `substituteTemplateVars()` in `config.zig`

## Git Integration

Three diff modes:
1. Working directory: `skim`
2. Staged: `skim --staged`
3. Ref comparison: `skim ref1..ref2`

Runs git in CWD, respects user config.
