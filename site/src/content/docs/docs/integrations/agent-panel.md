---
title: AI Agent Panel
description: The built-in agent panel (ACP) and MCP server for driving Skim with AI agents.
---

Skim integrates with AI agents in two ways:

1. **Agent panel** — a built-in chat interface (`Ctrl-e`) that speaks the
   [Agent Client Protocol](https://agentclientprotocol.com/) (ACP).
2. **External integration** — CLI commands (`skim session …`) and an MCP server
   so agents can drive a running Skim instance.

## The agent panel

Press `Ctrl-e` to toggle a chat panel alongside your diff. Agents are spawned
as subprocesses that communicate over stdio — no daemon.

```bash
# 1. Configure agents in ~/.skim/config.json (see below)
# 2. Open your diff
skim --staged
# 3. Press Ctrl-e to toggle the panel
```

### Configuration

Configure agents and panel settings in `~/.skim/config.json`:

```json
{
  "agent_servers": {
    "Claude Code": {
      "command": "claude-code-acp",
      "skim": { "default": true, "model": "opus" }
    },
    "Codex": {
      "command": "codex",
      "protocol": "codex",
      "approval_policy": "never",
      "sandbox_mode": "workspace-write",
      "web_search": true
    },
    "OpenCode": {
      "command": "opencode",
      "args": ["acp"]
    }
  }
}
```

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `command` | string | Yes | CLI command to spawn the agent |
| `args` | string[] | No | Extra CLI arguments |
| `env` | object | No | Environment variables (`${VAR}` expansion supported) |
| `protocol` | string | No | `"acp"`, `"opencode"`, or `"codex"` |
| `approval_policy` | string | No | Codex approval mode (`"never"`, `"on-request"`) |
| `sandbox_mode` | string | No | Codex sandbox (`"read-only"`, `"workspace-write"`, `"danger-full-access"`) |
| `web_search` | bool | No | Enable Codex's native web-search tool |
| `skim.default` | bool | No | Auto-connect to this agent (default `false`) |
| `skim.model` | string | No | Model to use (e.g. `"opus"`, `"sonnet"`) |
| `skim.mode` | string | No | Session mode (e.g. `"plan"`, `"code"`) |

For native Codex, set `"protocol": "codex"` with `"command": "codex"` — Skim
launches `codex app-server` and applies `sandbox_mode` / `web_search` as
first-class settings.

**Agent selection:**

- **Single agent** — auto-connects immediately.
- **Multiple agents with a default** — auto-connects to the one marked
  `"default": true`.
- **Multiple agents, no default** — shows a selection menu (`j` / `k` to
  navigate, `Enter` to select).

Switch agents anytime via the command palette (`Ctrl-p`, then `>Switch Agent`).

| Option | Values | Default |
| --- | --- | --- |
| `agent_panel_side` | `"left"`, `"right"` | `"right"` |

### `@file` references

Type `@` in the prompt to fuzzy-search and embed file contents:

```
@src/m     → matches src/main.zig, src/modes/*, etc.
@readme    → matches README.md
```

| Key | Action |
| --- | --- |
| `@` | Open the file picker (at a word boundary) |
| `↑` / `↓` or `Ctrl-p` / `Ctrl-n` | Navigate the file list |
| `Enter` or `Tab` | Insert the selected file |
| `Ctrl-C` / `ESC` | Close the file picker |

## Agent-panel keybindings

The panel uses vim-style modal editing.

### Global

| Key | Action |
| --- | --- |
| `Ctrl-E` | Close the panel, return to the diff |
| `Ctrl-G` | Edit the prompt in `$EDITOR` |
| `Ctrl-S` | Stash / unstash the prompt |
| `Ctrl-T` | Toggle the todo-list expansion |

### Insert mode

| Key | Action |
| --- | --- |
| `Enter` | Send the prompt to the agent |
| `Ctrl-J` | Insert a newline |
| `Ctrl-C` / `ESC` | Exit to normal mode |
| `/` | Show the slash-command menu (at prompt start) |
| `@` | Show the file picker (at a word boundary) |
| `!` | Toggle shell-command mode (empty input) |
| `Up` | Restore the stashed prompt (empty input) |

### Normal mode

| Key | Action |
| --- | --- |
| `Ctrl-W h/j/k/l` | Focus a pane / diff edge |
| `Ctrl-W w` | Cycle panes / diff focus |
| `Ctrl-W v` / `Ctrl-W s` | Open a vertical / horizontal split |
| `Ctrl-W c` / `Ctrl-W o` | Close a pane / keep only this pane |
| `Ctrl-W H/J/K/L` | Move the pane to an edge |
| `Ctrl-W + - < >` | Resize the focused pane |
| `i` / `a` / `I` / `A` | Enter insert mode |
| `h` / `l` | Move the cursor left / right |
| `w` / `b` / `e` | Word motions |
| `0` / `$` | Line start / end |
| `gg` / `G` | Jump to top / bottom of the input |
| `Ctrl-D` / `Ctrl-U` | Half-page down / up in the input |
| `x` / `dd` | Delete char / line |
| `:` | Open the command palette |
| `?` | Show help |
| `gb` / `Space+b` | Enter history mode |
| `gt` / `gT` | Next / previous tab |
| `Space+f` | Scroll to bottom, enable follow |
| `V` | Toggle the diff view mode |
| `Tab` | Cycle session modes |
| `Ctrl-C` | Interrupt the agent |

### History mode

Enter with `gb` or `Space+b` to browse and yank from message history.

| Key | Action |
| --- | --- |
| `j` / `k` | Move the cursor down / up |
| `h` / `l` | Jump to the previous / next message |
| `gg` / `G` | Jump to top / bottom |
| `Ctrl-D` / `Ctrl-U` | Page down / up |
| `M` | Center the cursor in the viewport |
| `v` | Enter visual selection mode |
| `y` | Yank the user message at the cursor |
| `yy` | Yank the current line |
| `Y` | Yank the entire current message |
| `Space+f` | Resume follow mode, exit history |
| `i` | Exit to insert mode |
| `Ctrl-C` / `ESC` / `q` | Exit to normal mode |

### Visual mode

Enter with `v` from history mode.

| Key | Action |
| --- | --- |
| `j` / `k` | Extend the selection down / up |
| `y` | Yank the selection to the clipboard |
| `Ctrl-C` / `ESC` / `v` | Exit visual mode |

### Permission prompt

When the agent requests permission:

| Key | Action |
| --- | --- |
| `j` / `k` or `Up` / `Down` | Navigate options |
| `Ctrl-D` / `Ctrl-U` | Scroll message history |
| `Enter` / `y` | Accept the selected option |
| `Ctrl-C` / `ESC` / `n` | Reject / cancel |

### Menus (slash, file picker, command palette)

| Key | Action |
| --- | --- |
| `Ctrl-N` / `Ctrl-P` | Navigate the menu |
| `Tab` | Insert the selected item |
| `Enter` | Insert and execute |
| `Ctrl-C` / `ESC` | Close the menu |

### Slash commands

| Command | Action |
| --- | --- |
| `/clear` | Clear the session and start fresh |
| `/model` | Switch the AI model |
| `/resume` | Resume a previous session |

## MCP server

For agents that speak the Model Context Protocol, add Skim to the agent's
config:

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

**Available MCP tools:**

| Tool | Description |
| --- | --- |
| `list_clients` | List all connected Skim TUI instances |
| `get_diff_context` | Get diff metadata (files, stats, mode) |
| `get_file_diff` | Get the full diff for a specific file |
| `add_comment` | Add a review comment to a specific line |
| `get_comments` | Get all comments from a Skim instance |

The [`skim session` CLI](../../reference/cli/#agent-facing-cli-skim-session)
provides the same capabilities as fallback commands when MCP isn't available.

## Claude Code skill

Install the Skim skill to teach Claude Code how to review with Skim:

```bash
npx skills add ctdio/skim
```

Then ask your agent to review with Skim:

```
Use skim to review this code, post comments in areas I should focus on
```

The agent finds Skim sessions running in the same directory and drives them via
the MCP tools (with CLI fallbacks).
