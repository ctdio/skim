---
title: Build from Source
description: Clone the repository and build the Skim binary with Zig.
---

Skim builds with the standard Zig build system. Make sure you have
[Zig 0.15.1 and git](../prerequisites/) first.

## Clone and build

```bash
git clone https://github.com/ctdio/skim.git
cd skim

# Debug build (for development)
zig build

# OR optimized release build
zig build -Doptimize=ReleaseFast
```

The binary is written to `./zig-out/bin/skim`.

:::tip
Use the **debug build** (`zig build`) while developing or debugging. It keeps
assertions on, produces better stack traces, and emits `std.log.debug` output.
Use `-Doptimize=ReleaseFast` for day-to-day use; release builds strip symbols
and are around 209 KB.
:::

## Run it

```bash
# Review working-directory changes
./zig-out/bin/skim

# Review staged changes
./zig-out/bin/skim --staged
```

Put it on your `PATH` (for example by symlinking `zig-out/bin/skim` into a
directory already on `PATH`) so you can invoke `skim` from anywhere.

## Development checks

If you're hacking on Skim itself:

```bash
# Run the test suite
zig build test

# Run the repo-configured ziglint checks
zig build lint
```

`zig build lint` uses the repository's `.ziglint.zon`. The wrapper script
prefers a locally installed `ziglint` binary and otherwise falls back to
`mise x github:rockorager/ziglint@v0.5.2 -- ziglint`.

## Dependencies

Skim pulls its dependencies through `build.zig.zon`:

- **libvaxis**: TUI rendering.
- **tree-sitter** plus language grammars: syntax highlighting for JavaScript,
  TypeScript, Zig, Python, Rust, Go, C, C++, JSON, YAML, TOML, Markdown, HTML,
  CSS, and Bash.

Next: [your first review](../first-review/).
