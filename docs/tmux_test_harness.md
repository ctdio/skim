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

## Clean Up

Detach from the session:

```bash
tmux detach
```

Kill the session when finished:

```bash
tmux kill-session -t skim-harness
```

## Notes

- Capture output is best-effort; full-screen TUI output may include escape codes.
- Logs are written to `~/.skim/tui.log`.
