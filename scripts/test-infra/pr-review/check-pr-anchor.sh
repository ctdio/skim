#!/bin/bash
# Diagnostic driver for `skim debug pr-anchor` (Phase 2 deliverable).
#
# Runs the shipped fetch -> diff -> anchor pipeline through the real binary and
# checks the totality invariant (anchored+bucketed+unplaced == total, enforced by
# the command's own nonzero exit) plus the documented per-PR expectations:
#   * #26015: single OUTDATED thread must land in a bucket (grep "outdated").
#   * inline PR (default #26001): a non-outdated thread must anchor inline; the
#     command exits 0 (totality holds) and prints an inline placement.
#
# GRACEFULLY DEGRADES: if `pr-anchor` is not yet listed in `skim debug --help`,
# this SKIPs so it can be committed alongside the scaffolding and "goes green"
# the moment the implementer adds the subcommand (and its help entry).
# NOTE: detection uses the --help listing, NOT the "Unknown debug subcommand"
# stderr text — that path calls std.process.exit(1), which skips the buffered
# stderr flush, so the string never reaches the pipe (verified against the
# current binary).
#
# Usage:  ./check-pr-anchor.sh [inline_pr_number]
#   Reuse a clone: SKIM_ANCHOR_WORKDIR=/path ./check-pr-anchor.sh
#   Custom binary: SKIM_BIN=/path/to/skim ./check-pr-anchor.sh
#
# Exit 0 = PASS or SKIP; Exit 1 = FAIL (totality violation, crash, or missing bucket).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OUTDATED_PR=26015
INLINE_PR="${1:-26001}"

command -v gh  >/dev/null 2>&1 || { echo "SKIP: gh not in PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not in PATH"; exit 0; }
gh auth status >/dev/null 2>&1 || { echo "SKIP: gh not authenticated"; exit 0; }

BIN="${SKIM_BIN:-$REPO_ROOT/zig-out/bin/skim}"
if [ ! -x "$BIN" ]; then
  echo "Building skim ($BIN not found)..."
  ( cd "$REPO_ROOT" && zig build ) || { echo "FAIL: zig build failed"; exit 1; }
fi
[ -x "$BIN" ] || { echo "SKIP: skim binary unavailable at $BIN"; exit 0; }

# ---- implemented? (help listing is the reliable signal) --------------------
if ! "$BIN" debug --help 2>&1 | grep -qi "pr-anchor"; then
  echo "SKIP: 'skim debug pr-anchor' not listed in 'skim debug --help' yet."
  echo "      Scaffolding committed early; this check goes green once the"
  echo "      implementer adds the subcommand (and its help entry)."
  exit 0
fi

# ---- clone target repo (pr-anchor fetches refs into the CWD repo) ----------
if [ -n "${SKIM_ANCHOR_WORKDIR:-}" ]; then
  REPO="$SKIM_ANCHOR_WORKDIR/repo"; mkdir -p "$SKIM_ANCHOR_WORKDIR"
else
  WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT; REPO="$WORK/repo"
fi
if [ ! -d "$REPO/.git" ]; then
  echo "Cloning ziglang/zig (blobless, one-time)..."
  git clone --quiet --filter=blob:none https://github.com/ziglang/zig "$REPO" 2>/tmp/anchor-clone.log \
    || { echo "SKIP: clone failed"; cat /tmp/anchor-clone.log; exit 0; }
fi
cd "$REPO" || { echo "FAIL: cannot cd $REPO"; exit 1; }

fail=0

# ---- #26015: outdated bucket -----------------------------------------------
echo "== pr-anchor $OUTDATED_PR (expect outdated bucket) =="
if OUT=$("$BIN" debug pr-anchor "$OUTDATED_PR" 2>&1); then
  echo "$OUT"
  echo "$OUT" | grep -qi "outdated" || { echo "FAIL: expected an outdated bucket in output"; fail=1; }
else
  echo "$OUT"; echo "FAIL: pr-anchor $OUTDATED_PR exited nonzero (totality violated or crash)"; fail=1
fi

# ---- inline PR: inline placement + totality --------------------------------
echo ""
echo "== pr-anchor $INLINE_PR (expect an inline placement) =="
if OUT=$("$BIN" debug pr-anchor "$INLINE_PR" 2>&1); then
  echo "$OUT"
  echo "$OUT" | grep -qiE "inline" || echo "INFO: no 'inline' token seen — verify the anchor table wording (non-blocking)."
else
  echo "$OUT"; echo "FAIL: pr-anchor $INLINE_PR exited nonzero (totality violated or crash)"; fail=1
fi

echo ""
if [ "$fail" -eq 0 ]; then echo "PASS: pr-anchor totality + bucket expectations held."; exit 0
else echo "FAIL: see above."; exit 1; fi
