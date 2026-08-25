---
title: Prerequisites
description: What you need installed before building and running Skim.
---

Skim is distributed as source and built with the Zig toolchain. You need two
things on your `PATH`:

## Zig 0.16.0

Skim targets **Zig 0.16.0 or later**. Install it from
[ziglang.org/download](https://ziglang.org/download/), your package manager, or
a version manager such as [`mise`](https://mise.jdx.dev/).

Verify the version:

```bash
zig version
# 0.16.0
```

:::note
Zig's language and build system still change between releases. If you hit build
errors, confirm you're on 0.16.0 rather than an older or much newer release.
:::

## Git

Skim shells out to `git` for every diff it renders, so git must be installed
and available in your `PATH`. Any recent version works.

```bash
git --version
```

Because Skim runs git in your current working directory, it automatically
respects your existing git configuration, including diff settings, pager
config, and credentials.

## Optional

- **[Graphite](https://graphite.dev/) (`gt`)**: enables the stacked-PR
  navigation described in [Graphite stacks](../../integrations/graphite/).
- **An `$EDITOR`**: used by the `Ctrl-g` [editor integration](../../integrations/editor/).
- **An agent CLI** (e.g. Claude Code, Codex): for the
  [AI agent panel](../../integrations/agent-panel/).

Next: [build from source](../build-from-source/).
