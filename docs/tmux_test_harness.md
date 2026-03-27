# tmux Test Harness

This document describes a generic tmux-based harness for running Skim and capturing state/logs while driving the UI via keystrokes. It is designed for automated or semi-automated testing workflows.

## Create a Session

Start Skim in one pane and tail logs in another:

```bash
tmux new-session -d -s skim-harness -c /home/ctdio/projects/open-source/skim "./zig-out/bin/skim"
tmux split-window -v -t skim-harness -c /home/ctdio/projects/open-source/skim "tail -f ~/.skim/tui.log"
tmux attach -t skim-harness
```

## Capture Visible Output

Capture the visible buffer from the TUI pane:

```bash
tmux capture-pane -pt skim-harness.0
```

This is useful for verifying the current screen without direct interaction.

## Send Keys to the TUI

Drive the UI with keystrokes:

```bash
tmux send-keys -t skim-harness.0 j j j
tmux send-keys -t skim-harness.0 Enter
```

For navigation keys and commands, reference the project keybindings in `README.md` (the authoritative list is under **Keybindings**).

## Replay Saved Codex Sessions

The replay command is useful when you want an agent to investigate or verify a UI issue against a real saved session instead of a live agent:

```bash
tmux new-session -d -s skim-replay -c /home/ctdio/projects/open-source/skim \
  "./zig-out/bin/skim debug replay-codex ~/.codex/sessions/...jsonl --tui"
tmux split-window -v -t skim-replay -c /home/ctdio/projects/open-source/skim "tail -f ~/.skim/tui.log"
tmux attach -t skim-replay
```

Replay-specific controls:

```bash
tmux send-keys -t skim-replay.0 Space   # play/pause
tmux send-keys -t skim-replay.0 n       # step one event
tmux send-keys -t skim-replay.0 r       # restart
tmux send-keys -t skim-replay.0 q       # exit replay
```

This works well for agent-assisted testing:
- Use a real session log as a deterministic fixture
- Capture pane output before and after specific replay steps
- Reproduce rendering or input bugs without waiting on live agent traffic
- Pair replay output with snapshot tests for durable regression coverage

## Clean Up

Detach from the session:

```bash
tmux detach
```

Kill the session when finished:

```bash
tmux kill-session -t skim-harness
tmux kill-session -t skim-replay
```

## Notes

- Capture output is best-effort; full-screen TUI output may include escape codes.
- Logs are written to `~/.skim/tui.log`.
