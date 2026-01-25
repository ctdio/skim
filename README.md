# Skim

A keyboard-driven TUI for code reviews built in Zig.

## Features

- Vim-style modal interface (hjkl, Ctrl-n/p)
- File-by-file diff navigation
- Unified and side-by-side views
- Hunk view modes: show all lines, only additions, or only deletions
- Tree-sitter syntax highlighting with async processing (JS/TS/Zig full support)
- Command palette: `Ctrl-p` for files, `:` for commands (vim-style), or type `>` to switch modes
- Built-in help with `?`
- Search with `/` across all files
- Visual selection mode for multi-line operations
- Character find commands (`f`/`t`/`F`/`T` like vim)
- Live refresh (press 'r')
- Full git diff compatibility (working dir, staged, branch comparisons)
- Comment system with export to clipboard ('y' for current, 'Y' for all)
- Editor integration (Ctrl-g opens file at line in $EDITOR)
- Git blame display toggle
- File staging from within the TUI
- Graphite stack integration (navigate stacked PRs)
- AI agent panel with `@file` fuzzy search for embedding file contents

## Installation

### Pre-built Binaries

Download the latest release for your platform from [GitHub Releases](https://github.com/ctdio/skim/releases):

| Platform | Download |
|----------|----------|
| macOS (Apple Silicon) | `skim-macos-arm64.tar.gz` |
| macOS (Intel) | `skim-macos-x86_64.tar.gz` |
| Linux (x86_64) | `skim-linux-x86_64.tar.gz` |
| Linux (ARM64) | `skim-linux-arm64.tar.gz` |

```bash
# Example: macOS Apple Silicon
curl -L https://github.com/ctdio/skim/releases/latest/download/skim-macos-arm64.tar.gz | tar xz
sudo mv skim /usr/local/bin/
```

### Building from Source

#### Prerequisites

- Zig 0.15.1
- Git

```bash
git clone https://github.com/ctdio/skim.git
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

Navigate with `j`/`k`, switch files with `h`/`l`. Press `Enter` to focus a file. Press `s` to toggle unified/side-by-side views.

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

#### Navigation

| Key | Action |
|-----|--------|
| `h` / `l` | Previous / Next file |
| `j` / `k` | Cursor down / up |
| `Ctrl-n` | Next file (alternative) |
| `Ctrl-d` / `Ctrl-u` | Page down / up |
| `gg` | Jump to top of file |
| `G` | Jump to bottom of file |
| `Shift-M` | Center cursor in viewport |
| `zz` | Center viewport on cursor |
| `[h` / `]h` | Previous / Next code change (supports count prefix) |
| `[c` / `]c` | Previous / Next comment |
| `{` / `}` | Previous / Next empty line (supports count prefix) |

#### Character Find (like vim)

| Key | Action |
|-----|--------|
| `f{char}` | Find character forward (cursor on character) |
| `F{char}` | Find character backward (cursor on character) |
| `t{char}` | Find character forward (cursor before character) |
| `T{char}` | Find character backward (cursor after character) |
| `;` | Repeat last find in same direction |

#### Search & Command Palette

| Key | Action |
|-----|--------|
| `/` | Enter search mode |
| `n` / `N` | Next / Previous search match |
| `Ctrl-p` | Open file palette (type `>` to switch to commands) |
| `:` | Open command palette (vim-style) |
| `?` | Show keybindings help |

#### Comments

| Key | Action |
|-----|--------|
| `Enter` | Add/edit comment on cursor line |
| `d` | Delete comment under cursor |
| `D` | Clear all comments |
| `o` | Toggle comment expand/collapse |
| `y` | Yank (copy) current comment to clipboard |
| `Y` | Yank (copy) all comments to clipboard |
| `gY` | Yank all comments to agent input |

#### View Modes

| Key | Action |
|-----|--------|
| `s` | Toggle unified/side-by-side view |
| `Tab` / `Shift-Tab` | Cycle hunk view mode (all / additions only / deletions only) |
| `B` | Toggle git blame in gutter |

#### Visual Mode

| Key | Action |
|-----|--------|
| `v` / `V` | Enter visual selection mode |

#### Git Operations

| Key | Action |
|-----|--------|
| `r` | Refresh diff (reload from git) |
| `a` | Stage current file (`git add`) |
| `A` | Stage all files (`git add -A`) |

#### Graphite Integration

| Key | Action |
|-----|--------|
| `S` | Open Graphite stack picker |
| `[s` | Navigate to parent branch (toward trunk) |
| `]s` | Navigate to child branch (toward tip) |

#### Other

| Key | Action |
|-----|--------|
| `Ctrl-g` | Open current file in $EDITOR |
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
- Case-insensitive unless query contains uppercase
- Searches across all files in the diff
- Searches diff content only (add/delete/context lines)
- Use `n`/`N` in NORMAL mode to navigate matches

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

**Two modes:**
- **File Mode** (`Ctrl-p`): Filter and jump to files
  - Type `>` to switch to command mode
- **Command Mode** (`:` key): Built-in commands (vim-style)
  - Toggle View Mode, Refresh Diff, Show Help, Quit
  - Backspace `>` to switch to file mode

### VISUAL Mode

Select multiple lines for operations:

| Key | Action |
|-----|--------|
| `j` / `k` | Extend selection down / up |
| `h` / `l` | Previous / Next file |
| `g` / `G` | Jump to top / bottom |
| `Ctrl-d` / `Ctrl-u` | Page down / up |
| `y` | Yank (copy) selection to clipboard |
| `Enter` | Create comment for visual selection |
| `v` / `ESC` | Exit visual mode |

### COMMENT Mode

Edit comments with vim-style editing:

| Key | Action |
|-----|--------|
| `Enter` | Save comment and return to NORMAL mode |
| `Ctrl-J` | Insert newline in comment |
| `ESC` | Cancel and return to NORMAL mode |
| `i` / `a` / `I` / `A` | Insert modes (before cursor / after cursor / line start / line end) |
| `h` / `j` / `k` / `l` | Move cursor |
| `w` / `b` / `e` | Word motions (next word / back word / end of word) |
| `0` / `$` | Jump to line start / end |
| `x` | Delete character under cursor |
| `dd` | Delete entire line |
| `Backspace` | Delete character before cursor |

## AI Agent Integration

MCP (Model Context Protocol) server for AI agent code reviews. Agents can read diffs, add comments, and see results in real-time.

### Quick Start for AI Reviews

```bash
# 1. Start the skim daemon (runs in background)
skim daemon start

# 2. Open your diff in skim
skim --staged

# 3. Use MCP tools from your AI agent to interact with skim
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

### Claude Code Plugin

This repo includes a Claude Code plugin with a `/skim` skill that teaches Claude Code how to review code with skim.

**Install from GitHub:**

```bash
# Add the skim marketplace
/plugin marketplace add ctdio/skim

# Install the plugin
/plugin install skim@ctdio-skim
```

**Or install from a local clone:**

```bash
# Clone the repo
git clone https://github.com/ctdio/skim.git

# Add as a local marketplace (point to .claude-plugin directory)
/plugin marketplace add ./skim/.claude-plugin

# Install the plugin
/plugin install skim@skim
```

**Usage:**

Once installed, invoke the skill in Claude Code:

```
/skim                    # Show help and find sessions
/skim review this code   # Ask Claude to review the diff
```

The skill provides Claude Code with:
- Instructions for using skim MCP tools (`mcp__skim__*`)
- Fallback CLI commands if MCP is unavailable
- Guidance on line types and comment workflows

### MCP Tools Available

The skim MCP server exposes these tools to AI agents:

| Tool | Description |
|------|-------------|
| `list_clients` | List all connected skim TUI instances |
| `get_diff_context` | Get diff metadata (files, stats, mode) |
| `get_file_diff` | Get full diff content for a specific file |
| `add_comment` | Add a review comment to a specific line |
| `get_comments` | Get all comments from a skim instance |

### Log Files

Skim writes logs to `~/.skim/`:
- `tui.log` - TUI client logs
- `daemon.log` - Daemon process logs
- `mcp.log` - MCP adapter logs

---

## Agent Panel

Built-in chat interface for AI agents. Uses ACP (Agent Client Protocol) to communicate with agents like Claude Code.

### Quick Start

```bash
# 1. Configure agents in ~/.skim/config.json:
# {
#   "agent_servers": {
#     "Claude Code": {
#       "command": "claude",
#       "args": ["acp"],
#       "skim": { "default": true, "model": "sonnet" }
#     }
#   }
# }

# 2. Open your diff in skim
skim --staged

# 3. Press Ctrl-e to toggle the agent panel
```

### Agent Panel Keybindings

The agent panel uses vim-style modal editing. Keybindings are organized by mode.

#### Global (work in any mode)

| Key | Action |
|-----|--------|
| `Ctrl-E` | Close panel, return to diff |
| `Ctrl-G` | Edit prompt in $EDITOR |
| `Ctrl-W h/l` | Focus diff/agent panel |
| `Ctrl-W w` | Cycle focus between panels |
| `Ctrl-S` | Stash/unstash prompt |
| `Ctrl-T` | Toggle todo list expansion |

#### Insert Mode (typing in prompt)

| Key | Action |
|-----|--------|
| `Enter` | Send prompt to agent |
| `Ctrl-J` | Insert newline in prompt |
| `ESC` / `Ctrl-C` | Exit to normal mode |
| `/` | Show slash command menu (at start) |
| `@` | Show file picker (at start) |
| `!` | Toggle shell command mode (empty input) |
| `Up` | Restore staged prompt (empty input) |

#### Normal Mode (vim on prompt)

| Key | Action |
|-----|--------|
| `i` / `a` / `I` / `A` | Enter insert mode |
| `h` / `l` | Move cursor left/right |
| `w` / `b` / `e` | Word motions |
| `0` / `$` | Line start/end |
| `gg` / `G` | Jump to top/bottom of input |
| `Ctrl-D` / `Ctrl-U` | Half-page down/up in input |
| `x` / `dd` | Delete char/line |
| `:` | Open command palette |
| `?` | Show help |
| `gb` | Enter history mode |
| `gt` / `gT` | Next/previous tab |
| `Space+f` | Scroll to bottom, enable follow |
| `z` | Toggle full screen |
| `V` | Toggle diff view mode |
| `Tab` | Cycle session modes |
| `ESC ESC` | Interrupt agent (double-tap) |

#### History Mode (enter with `gb`)

Browse and yank from message history.

| Key | Action |
|-----|--------|
| `j` / `k` | Move cursor down/up |
| `h` / `l` | Jump to prev/next message |
| `gg` / `G` | Jump to top/bottom |
| `Ctrl-D` / `Ctrl-U` | Page down/up |
| `M` | Move cursor to middle of viewport |
| `v` | Enter visual selection mode |
| `y` | Yank user message at cursor |
| `yy` | Yank current line |
| `Y` | Yank entire current message |
| `i` | Exit to insert mode |
| `ESC` / `q` | Exit to normal mode |

#### Visual Mode (in history, enter with `v`)

| Key | Action |
|-----|--------|
| `j` / `k` | Extend selection down/up |
| `y` | Yank selection to clipboard |
| `ESC` / `v` | Exit visual mode |

#### Permission Prompt (when agent requests permission)

| Key | Action |
|-----|--------|
| `j` / `k` or `Up` / `Down` | Navigate options |
| `Ctrl-D` / `Ctrl-U` | Scroll message history |
| `Enter` / `y` | Accept selected option |
| `ESC` / `n` | Reject/cancel |

#### Slash Menu (when visible after `/`)

| Key | Action |
|-----|--------|
| `Ctrl-N` / `Ctrl-P` | Navigate menu |
| `Tab` | Insert selected command |
| `Enter` | Insert and send command |
| `ESC` | Close menu |

#### File Picker (when visible after `@`)

| Key | Action |
|-----|--------|
| `Ctrl-N` / `Ctrl-P` | Navigate files |
| `Enter` / `Tab` | Insert selected file |
| `ESC` | Close picker |

#### Command Palette (opened with `:`)

| Key | Action |
|-----|--------|
| `Up` / `Down` or `Ctrl-P` / `Ctrl-N` | Navigate commands |
| `Enter` | Execute selected command |
| `ESC` | Close palette |

#### Built-in Slash Commands

| Command | Action |
|---------|--------|
| `/clear` | Clear session and start fresh |
| `/model` | Switch AI model |
| `/resume` | Resume previous session |

### @file References

Type `@` in the agent prompt to fuzzy-search and embed file contents:

```
@src/m     → fuzzy matches src/main.zig, src/modes/*, etc.
@readme    → matches README.md
```

When you send the prompt, `@file` references are replaced with the file's contents as embedded resources for the AI agent.

| Key | Action |
|-----|--------|
| `@` | Open file picker (at word boundary) |
| `↑`/`↓` or `Ctrl-p`/`Ctrl-n` | Navigate file list |
| `Enter` or `Tab` | Insert selected file |
| `ESC` | Close file picker |

### Configuration

Configure agents and panel settings in `~/.skim/config.json`:

```json
{
  "agent_panel_side": "right",
  "agent_servers": {
    "Claude Code": {
      "command": "claude",
      "args": ["acp"],
      "env": {
        "ANTHROPIC_API_KEY": "${ANTHROPIC_API_KEY}"
      },
      "skim": {
        "default": true,
        "model": "sonnet",
        "mode": "plan"
      }
    },
    "Codex": {
      "command": "codex",
      "args": ["acp"]
    }
  }
}
```

#### Agent Configuration Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `command` | string | Yes | CLI command to spawn the agent |
| `args` | string[] | No | Additional CLI arguments to pass to the agent |
| `env` | object | No | Environment variables (supports `${VAR}` expansion) |
| `skim.default` | bool | No | Auto-connect to this agent (default: `false`) |
| `skim.model` | string | No | AI model to use (e.g., `"sonnet"`, `"opus"`) |
| `skim.mode` | string | No | Agent session mode (e.g., `"plan"`, `"code"`) |

#### Agent Selection Behavior

- **No agents configured**: Shows error message in agent panel
- **Single agent**: Auto-connects immediately
- **Multiple agents with default**: Auto-connects to the agent marked `"default": true`
- **Multiple agents, no default**: Shows selection menu (navigate with `j`/`k`, select with `Enter`)

You can switch agents anytime via the command palette (`Ctrl-p`, then `>Switch Agent`).

#### Other Options

| Option | Values | Default |
|--------|--------|---------|
| `agent_panel_side` | `"left"`, `"right"` | `"right"` |

### ACP Protocol

The Agent Client Protocol (ACP) enables communication between skim and AI coding agents via stdio transport.

**Supported agents:**
- Agents implementing the ACP stdio transport (e.g., `claude acp`, `codex acp`)

---

## Credits

Built with:
- [libvaxis](https://github.com/rockorager/libvaxis) - TUI rendering library
- [tree-sitter](https://tree-sitter.github.io/) - Parser generator for syntax highlighting
- Language grammars from [tree-sitter-grammars](https://github.com/tree-sitter-grammars):
  - JavaScript/JSX, TypeScript/TSX
  - Python, Rust, Go, Zig
  - C, C++
  - JSON, YAML, TOML, Markdown, HTML, CSS, Bash

## License

MIT
