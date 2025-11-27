# Skim

A keyboard-driven TUI for code reviews built in Zig. Fast, minimal, and focused on getting out of your way.

## Features

- Sub-10ms startup, 60 FPS scrolling, ~209KB binary
- Vim-style modal interface (hjkl, Ctrl-n/p)
- File-by-file diff navigation
- Unified and side-by-side views
- Tree-sitter syntax highlighting with async processing (JS/TS/Zig full support)
- **Command palette: `Ctrl-p` for files, `:` for commands (vim-style), or type `>` to switch modes**
- **Built-in help with `?` - comprehensive keybindings reference**
- **Search with `/` - smart case matching across all files**
- Live refresh (press 'r')
- Full git diff compatibility (working dir, staged, branch comparisons)
- Comment system with export to clipboard ('y' for current, 'Y' for all)
- Editor integration (Ctrl-g opens file at line in $EDITOR)

## Installation

### Prerequisites

- Zig 0.13.0 or later
- Git

### Building from Source

```bash
git clone https://github.com/yourusername/skim.git
cd skim

# Debug build (for development)
zig build

# OR release build (optimized)
zig build -Doptimize=ReleaseFast
```

The binary will be available at `./zig-out/bin/skim`.

## Quick Start

```bash
# Build and run
zig build
./zig-out/bin/skim

# Review your changes
./zig-out/bin/skim --staged
```

Navigate with `j`/`k` to move the cursor, `h`/`l` to switch files. Press `Enter` to focus on a file for detailed review. Press `s` to toggle between unified and side-by-side views.

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
| `Ctrl-p` | **Open command palette** |
| `j` | Cursor down |
| `k` | Cursor up |
| `g` | Jump to top of file |
| `G` | Jump to bottom of file |
| `[h` | Jump to previous code change block (supports count prefix) |
| `]h` | Jump to next code change block (supports count prefix) |
| `{` | Jump to previous empty line (supports count prefix) |
| `}` | Jump to next empty line (supports count prefix) |
| `Ctrl-d` | Page down |
| `Ctrl-u` | Page up |
| `Shift-M` | Center cursor in viewport |
| `/` | Enter search mode |
| `Ctrl-p` | Open file palette (type `>` to switch to commands) |
| `:` | Open command palette (vim-style) |
| `?` | Show keybindings help |
| `n` | Jump to next search match |
| `N` | Jump to previous search match |
| `Enter` | Add/edit comment on cursor line |
| `d` | Delete comment under cursor |
| `D` | Clear all comments |
| `Ctrl-g` | Open current file in $EDITOR |
| `y` | Yank (copy) current comment to clipboard |
| `Y` | Yank (copy) all comments to clipboard |
| `s` | Toggle unified/side-by-side view |
| `r` | Refresh diff (reload from git) |
| `Ctrl-C` × 2 | Force exit (double-press within 1 second) |

### SEARCH Mode

Search through diff content:

| Key | Action |
|-----|--------|
| Type | Enter search query (smart case: lowercase=ignore case, uppercase=exact) |
| `Enter` | Execute search and jump to first match |
| `ESC` | Cancel and return to NORMAL mode |
| `Backspace` | Delete character from query |

**Search behavior:**
- **Smart case**: Search is case-insensitive unless query contains uppercase letters
- **Global**: Searches across all files in the diff
- **Code lines only**: Searches through diff content (add/delete/context lines)
- Use `n`/`N` in NORMAL mode to navigate between matches

### COMMAND PALETTE Mode

Quick access to files and commands:

| Key | Action |
|-----|--------|
| Type | Filter files/commands by name (case-insensitive) |
| `>` | Prefix to switch between file/command mode |
| `↑`/`↓` or `Ctrl-p`/`Ctrl-n` | Navigate selection |
| `Enter` | Execute selected command or jump to file |
| `ESC` | Cancel and return to NORMAL mode |
| `Backspace` | Delete character from filter |

**Two modes in one:**
- **File Mode** (`Ctrl-p`): Type to filter and jump to files in the diff
  - Smart path truncation for long paths (e.g., `p/o/s/src/file.zig`)
  - Substring matching on file paths
  - Type `>` prefix to switch to command mode
- **Command Mode** (`:` key): Access built-in commands (vim-style)
  - **Toggle View Mode**: Switch between unified and side-by-side
  - **Refresh Diff**: Reload the diff from git
  - **Show Help**: Display help overlay
  - **Quit**: Exit Skim
  - Backspace `>` to switch back to file mode

### COMMENT Mode

Edit comments on specific lines:

| Key | Action |
|-----|--------|
| `Enter` | Save comment and return to NORMAL mode |
| `Shift-Enter` | Insert newline in comment |
| `ESC` | Cancel and return to NORMAL mode |
| `Backspace` | Delete character before cursor |

## AI Agent Integration

Skim includes an MCP (Model Context Protocol) server that allows AI agents like Claude to review your code changes. The agent can read diff context, add comments to specific lines, and the comments appear in real-time in your TUI.

### Quick Start for AI Reviews

```bash
# 1. Start the skim daemon (runs in background)
skim daemon start

# 2. Open your diff in skim
skim --staged

# 3. Press 'R' to start an AI review (requires SKIM_REVIEW_COMMAND configured)
# Or press 'L' to view the review log panel
```

### Daemon Commands

```bash
# Start the daemon (runs in background by default)
skim daemon start
skim daemon start --foreground  # Run in foreground for debugging
skim daemon start --port 8888   # Use custom port

# Check daemon status
skim daemon status

# Stop the daemon
skim daemon stop

# Restart the daemon
skim daemon restart
```

The daemon listens on two ports:
- **TUI port (default 9999)**: For skim TUI clients to connect
- **Adapter port (default 9998)**: For MCP adapters (AI agents)

### MCP Server Configuration

Add skim to your AI assistant's MCP configuration:

**Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`):**
```json
{
  "mcpServers": {
    "skim": {
      "command": "skim",
      "args": ["mcp", "--stdio"]
    }
  }
}
```

**Cursor or other MCP-compatible tools:**
```json
{
  "skim": {
    "command": "skim",
    "args": ["mcp", "--stdio"]
  }
}
```

### MCP Tools Available

The skim MCP server exposes these tools to AI agents:

| Tool | Description |
|------|-------------|
| `list_clients` | List all connected skim TUI instances |
| `get_diff_context` | Get diff metadata (files, stats, mode) |
| `get_file_diff` | Get full diff content for a specific file |
| `add_comment` | Add a review comment to a specific line |
| `get_comments` | Get all comments from a skim instance |

### Configuring the Review Command

Set the `SKIM_REVIEW_COMMAND` environment variable or create `~/.skim/config.json`:

**Environment variable:**
```bash
export SKIM_REVIEW_COMMAND='claude --mcp skim "Review this diff for bugs and style issues"'
```

**Config file (`~/.skim/config.json`):**
```json
{
  "review_command": "your-review-command --client {client_id} --repo {repo}"
}
```

### Template Variables

The review command supports these template variables:

| Variable | Description | Example |
|----------|-------------|---------|
| `{client_id}` | The skim session ID | `a1b2c3d4-...` |
| `{repo}` | Path to the git repository | `/home/user/project` |
| `{diff_ref}` | The diff reference being reviewed | `staged`, `main..feature` |
| `{adapter_port}` | The MCP adapter port | `9998` |

**Example command with variables:**
```bash
export SKIM_REVIEW_COMMAND='my-review-tool --session {client_id} --cwd {repo} --ref {diff_ref}'
```

### Review Keybindings

| Key | Action |
|-----|--------|
| `R` | Start AI review (runs SKIM_REVIEW_COMMAND) |
| `L` | Toggle review log side panel |
| `Tab` | Toggle panel style (sidebar/dialog) when panel focused |
| `Ctrl-w h` | Focus left (diff view) from panel |
| `Ctrl-w l` | Focus right (panel) from diff |

### Log Files

Skim writes logs to `~/.skim/`:
- `tui.log` - TUI client logs
- `daemon.log` - Daemon process logs
- `mcp.log` - MCP adapter logs
- `review.log` - Review command output

## Architecture

See [docs/architecture.md](docs/architecture.md) for detailed architecture documentation.

**Quick Overview:**
```
src/
├── main.zig              # CLI entry point
├── app.zig               # State machine, event handling
├── line_map.zig          # Position registry (single source of truth)
├── logging.zig           # File-based logging system
├── review.zig            # Review process management
├── config.zig            # Config loading and template substitution
├── git/                  # Git command execution and parsing
├── rendering/            # Unified and side-by-side renderers
├── modes/                # Mode handlers (normal, comment, search, etc.)
├── mcp/                  # MCP server and daemon
│   ├── daemon.zig        # Central daemon server
│   ├── client.zig        # TUI-side MCP client
│   ├── adapter.zig       # stdio MCP adapter for AI agents
│   ├── protocol.zig      # TUI<->Daemon protocol
│   ├── tools.zig         # MCP tool implementations
│   ├── discovery.zig     # Daemon discovery via ~/.skim/daemon.json
│   └── framework.zig     # MCP JSON-RPC framework
└── syntax.zig            # Tree-sitter syntax highlighting
```

**Design Principles:**
- Shell out to git (respects user config)
- Single-pass O(n) diff parsing
- Modal interface (vim-style)
- LineMap system for accurate positioning
- Async syntax highlighting (non-blocking)
- Virtual scrolling (render visible lines only)
- Daemon architecture for AI integration

## Performance Targets

| Metric | Target | Current |
|--------|--------|---------|
| Cold startup | <10ms | ✅ |
| Binary size | <2MB | ✅ 209KB |
| Memory usage | <50MB | ✅ |
| Scrolling FPS | 60 | ✅ |

## Contributing

Priority areas:
- Syntax highlighting query files for Python, Rust, Go, C, C++ (parsers ready, need .scm files)
- Hunk navigation (n/N keys to jump between hunks)
- Help overlay/documentation (show keybindings in-app)
- Mouse support (click to position cursor, scroll to navigate)
- Comment persistence (save/load comments between sessions)
- Testing coverage (especially for new features)

## Credits

Built with:
- [libvaxis](https://github.com/rockorager/libvaxis) - TUI rendering library
- [z-tree-sitter](https://github.com/lfcm64/z-tree-sitter) - Zig bindings for tree-sitter
- [tree-sitter](https://tree-sitter.github.io/) - Parser generator for syntax highlighting
- Language grammars from [tree-sitter-grammars](https://github.com/tree-sitter-grammars):
  - JavaScript/JSX, TypeScript/TSX
  - Python, Rust, Go, Zig
  - C, C++
  - JSON, YAML, TOML, Markdown, HTML, CSS, Bash

## License

MIT
