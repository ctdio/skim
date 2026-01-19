---
name: skim
description: Quick skim CLI reference
triggers:
  - /skim-help
---

# Skim CLI Commands

## Session Management
```bash
skim sessions list [--json]
```

## Get Diff Context
```bash
skim context [--session <PID>] [--json]
```

## Comments
```bash
skim comment add --file <path> --line <n> [--line-type new|old] "text"
skim comment list [--json]
skim comment delete <index>
```

All commands auto-select session if only one running or cwd matches.
