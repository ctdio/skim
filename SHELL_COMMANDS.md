# Shell Command Feature

## Overview

Skim now supports running shell commands directly from the agent panel using the `!` prefix. Commands are executed locally, their output is displayed in the chat UI, and both the command and output are sent to the AI agent as an embedded resource for context.

## Usage

In the agent panel (press `a` to open), type a command starting with `!` and press Enter:

```
!ls -la
!git status
!npm test
!echo "Hello from shell"
```

**Visual Feedback**: When you type `!`, the prompt changes from `>` (magenta) to `$` (yellow) to indicate you're in shell command mode, giving you immediate visual confirmation.

## How It Works

1. **Command Input**: When you type `!command` and press Enter in the agent panel:
   - The input is detected as a shell command (starts with `!`)
   - The command is shown in the chat as a user message

2. **Execution**: 
   - The command runs using your default shell (`$SHELL` or `/bin/sh`)
   - A tool message appears showing the command is running
   - Output is captured from both stdout and stderr

3. **Display**:
   - The tool message updates with the command output
   - Shows both stdout and stderr (if present)
   - Displays exit code and execution status

4. **Agent Context**:
   - The full command and output are sent as an embedded resource
   - The AI agent receives the complete context
   - Format:
     ```
     $ <command>
     <stdout>
     # stderr:
     <stderr>
     # exit code: <code>
     ```

## Example

Input:
```
!git log --oneline -5
```

The agent receives:
```
$ git log --oneline -5
ba56e48 refactor(agent): tighten spacing in tool output
dfab80b perf: optimize event loop polling to reduce CPU usage
ba2df8c feat: add fzf-like scoring for @file fuzzy search
a691fa9 feat: add @file fuzzy search with ACP embedded resources
90e0255 docs: trim verbose wording from readme
# exit code: 0
```

## Features

- **Real-time execution**: Commands run immediately
- **Full output capture**: Both stdout and stderr are captured
- **Exit code tracking**: Success/failure status is tracked
- **Agent integration**: Output automatically sent to AI for analysis
- **Visual feedback**: Tool message shows execution status
- **Shell environment**: Runs in your default shell with full environment

## Limitations

- Commands are blocking (UI may freeze for long-running commands)
- No streaming output during execution (shows all output after completion)
- No interactive input support (stdin is closed)
- 10MB output limit

## Future Enhancements

Potential improvements:
- [ ] Async/non-blocking execution
- [ ] Streaming output (show last 10 lines during execution)
- [ ] Progress indicator for long-running commands
- [ ] Command history and autocomplete
- [ ] Interrupt/cancel running commands

## Implementation

See `src/modes/agent_mode.zig`:
- `handleShellCommand()`: Main execution logic
- `sendCommandOutputToAgent()`: Sends output to AI agent as embedded resource

The feature integrates with the existing agent panel UI and uses the tool message system for consistent display.
