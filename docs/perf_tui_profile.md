# TUI Profiling and Self-Testing

This guide documents a repeatable workflow for profiling Skim's TUI rendering, capturing state from the UI, and reviewing performance logs.

## Quick Start

1) Build in debug mode with profiling enabled:

```bash
zig build -Dprofile=true
```

2) Start the TUI with render profiling enabled:

```bash
SKIM_PROFILE_RENDER=1 SKIM_PROFILE_RENDER_EVERY=30 ./zig-out/bin/skim
```

3) Tail logs in another terminal:

```bash
tail -f ~/.skim/tui.log
```

## What to Look For

The log contains two main scopes:

- `profile_loop`: high-level frame timing (render vs vaxis)
- `profile_render`: breakdown of header/content/status and micro counters

Example entries:

```
profile_loop: frame 30: render_ns=29723064 vx_ns=6977290
profile_render: render micro: slice_ns=... pad_ns=... highlight_ns=... build_ns=...
```

Interpretation:

- `render_ns` much larger than `vx_ns` means time is spent in app-side rendering
- `highlight_ns` and `build_ns` are typically the largest hot spots in content rendering
- `gutter_ns`, `slice_ns`, and `pad_ns` should be relatively small

## tmux Workflow (Recommended)

This is the same flow used during development to drive the TUI and watch logs side-by-side. For a generic tmux harness (capture + key driving), see `docs/tmux_test_harness.md`.

Start a profiling session in tmux:

```bash
tmux new-session -d -s skim-profile -c /home/ctdio/projects/open-source/skim "SKIM_PROFILE_RENDER=1 SKIM_PROFILE_RENDER_EVERY=30 ./zig-out/bin/skim"
tmux split-window -v -t skim-profile -c /home/ctdio/projects/open-source/skim "tail -f ~/.skim/tui.log"
tmux attach -t skim-profile
```

Useful tmux keys:

- Detach: `Ctrl-b d`
- Switch panes: `Ctrl-b` then arrow keys
- Kill session: `tmux kill-session -t skim-profile`

## Capturing TUI State (Non-Interactive)

Because Skim is a full-screen TUI, you can capture the current pane contents using tmux:

```bash
tmux capture-pane -pt skim-profile.0
```

This prints the visible buffer from the TUI pane. It can include escape codes and may be incomplete, but it is useful for:

- Verifying the current screen
- Checking which menu or view is active
- Confirming cursor position or selection state

## Automated Key Driving

You can send keys into the TUI pane to simulate navigation:

```bash
tmux send-keys -t skim-profile.0 j j j
tmux send-keys -t skim-profile.0 Enter
```

This allows reproducible sequences (scroll, select, toggle views) while profiling.

## Common Scenarios to Test

- Unified view vs side-by-side
- Long scrolling (large diffs)
- Search highlight enabled
- Blame toggled on/off

## Notes

- Profiling output is written to `~/.skim/tui.log`
- Debug builds provide more logging and better stack traces
- If the terminal gets corrupted after a crash, run `reset`
