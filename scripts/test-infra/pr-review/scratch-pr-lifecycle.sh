#!/bin/bash
# End-to-end write-path smoke: the full pending-review lifecycle through the
# REAL skim binary (Phase 3 mandatory tester check; template for Phases 4-5).
#
# Drives `skim debug pr-comment` / `pr-discard` (AD-2: the debug CLI calls the
# same sync cores the TUI uses) against a throwaway scratch PR:
#   1. line comment (hostile body: quotes, %s, emoji)
#   2. range comment (multiline body, startLine/startSide)
#   3. verify both PENDING drafts via `skim debug pr-view`, byte-exact body
#   4. reuse: both comments share exactly ONE pending review
#   5. discard, then verify no drafts survive
# Teardown (branch + PR + any pending review) always runs via the lib's EXIT trap.
#
# GRACEFUL DEGRADATION:
#   * SKIP (exit 0) when gh/git/jq missing or unauthenticated, or no push access.
#   * SKIP (exit 0) when `pr-comment` is not yet in `skim debug --help` — so this
#     can be committed alongside the scaffolding and goes green the moment the
#     implementer adds the subcommands. Detection uses the --help listing, NOT the
#     "Unknown debug subcommand" stderr (that path exits(1) before the buffered
#     stderr flushes, so the string never reaches the pipe).
#   * Once pr-comment exists and gh is authed, a mid-run failure is a real FAIL.
#
# Usage:  ./scratch-pr-lifecycle.sh
#   SKIM_BIN=/path/to/skim ./scratch-pr-lifecycle.sh   # custom binary
#   SP_KEEP=1 ./scratch-pr-lifecycle.sh                # leave PR for inspection
#
# Exit 0 = PASS or SKIP; Exit 1 = FAIL.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=scratch-pr-lib.sh
. "$SCRIPT_DIR/scratch-pr-lib.sh"

LINE_BODY='harness single-line "quote" %s émoji 🎉'
RANGE_BODY=$'multi\nline body "quoted"'

sp_preflight || exit 0

BIN="${SKIM_BIN:-$REPO_ROOT/zig-out/bin/skim}"
if [ ! -x "$BIN" ]; then
  echo "Building skim ($BIN not found)..."
  ( cd "$REPO_ROOT" && zig build ) || { echo "FAIL: zig build failed"; exit 1; }
fi

if ! "$BIN" debug --help 2>&1 | grep -q 'pr-comment'; then
  echo "SKIP: 'skim debug pr-comment' not implemented yet (not in debug --help)"
  exit 0
fi

sp_create_scratch_pr || { echo "FAIL: scratch PR setup"; exit 1; }

# 1. line comment
"$BIN" debug pr-comment "$SP_PR" --path README.md --line "$SP_NEW_START" --side right \
  --body "$LINE_BODY" || { echo "FAIL: line comment"; exit 1; }

# 2. range comment (+1..+3 of the appended block)
"$BIN" debug pr-comment "$SP_PR" --path README.md --line $((SP_NEW_START+3)) --side right \
  --start-line $((SP_NEW_START+1)) --start-side right --body "$RANGE_BODY" \
  || { echo "FAIL: range comment"; exit 1; }

# 3. both PENDING, body fidelity through the round trip
# NOTE: pr-view does NOT print 'draft' per review-draft thread — the only 'draft'
# token is the PR-level `draft: true` flag (once). Count the actual draft threads
# via the `threads: N` header line and confirm a backing pending review exists.
OUT="$("$BIN" debug pr-view "$SP_PR")"
echo "$OUT" | grep -q 'émoji 🎉'            || { echo "FAIL: body fidelity (emoji/quote body missing)"; exit 1; }
echo "$OUT" | grep -qE 'threads: 2$'        || { echo "FAIL: expected 2 draft threads in pr-view"; exit 1; }
echo "$OUT" | grep -q 'pending review:'     || { echo "FAIL: expected a pending review backing the drafts"; exit 1; }

# 4. reuse: exactly ONE pending review backs both comments
PENDING="$(gh api graphql \
  -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviews(states:PENDING,first:10){totalCount}}}}' \
  -f o="$SP_OWNER" -f r="$SP_REPO" -F n="$SP_PR" \
  --jq '.data.repository.pullRequest.reviews.totalCount' 2>/dev/null)"
[ "$PENDING" = "1" ] || { echo "FAIL: expected 1 pending review, saw '$PENDING' (duplicated?)"; exit 1; }

# 5. discard, then verify gone
# NOTE: grepping 'draft' here is WRONG — the PR is still a draft PR, so `draft: true`
# always matches. Deleting the pending review deletes its draft threads, so assert
# the pending-review line is gone and the thread count drops to 0.
"$BIN" debug pr-discard "$SP_PR" || { echo "FAIL: discard"; exit 1; }
OUT_AFTER="$("$BIN" debug pr-view "$SP_PR")"
echo "$OUT_AFTER" | grep -q 'pending review:' && { echo "FAIL: pending review survived discard"; exit 1; }
echo "$OUT_AFTER" | grep -qE 'threads: 0$'     || { echo "FAIL: draft threads survived discard"; exit 1; }

echo "PASS"
