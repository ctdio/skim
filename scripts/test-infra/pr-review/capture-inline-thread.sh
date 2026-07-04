#!/bin/bash
# Capture the full review payload for a PR that has a non-outdated INLINE thread,
# saving it as a Phase-2 ground-truth fixture, and print each inline thread's
# anchor coordinates + the diffHunk tail (the line GitHub anchored it to).
#
# This is the fixture the anchor-CORRECTNESS check asserts against: for a
# non-outdated inline thread, skim's anchored diff line MUST equal the last line
# of that comment's diffHunk. This script exposes that ground truth so the
# implementer can build hand-mirrored FileDiff unit fixtures and the tester can
# diff live output against it.
#
# Usage:  ./capture-inline-thread.sh [owner name number]
#   defaults: ziglang zig 26001  (single non-outdated RIGHT-side inline thread,
#             small test-case file, stable historical fixture)
#
# Exit 0 = PASS/SKIP; Exit 1 = FAIL (no inline thread on the chosen PR, or gh err).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUERY_FILE="$SCRIPT_DIR/pr-review.graphql"
OUT_DIR="${SKIM_PR_CAPTURE_DIR:-$HOME/.ai/plans/skim-github-pr-review/phase-02-inline-threads/captured}"

OWNER="${1:-ziglang}"
NAME="${2:-zig}"
NUMBER="${3:-26001}"

command -v gh >/dev/null 2>&1 || { echo "SKIP: gh not in PATH"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not in PATH"; exit 0; }
gh auth status >/dev/null 2>&1 || { echo "SKIP: gh not authenticated"; exit 0; }
[ -f "$QUERY_FILE" ] || { echo "FAIL: query file missing at $QUERY_FILE"; exit 1; }

mkdir -p "$OUT_DIR"
RAW="$OUT_DIR/pr-${OWNER}-${NAME}-${NUMBER}.json"

if ! gh api graphql \
      -f query="$(cat "$QUERY_FILE")" \
      -f owner="$OWNER" \
      -f name="$NAME" \
      -F number="$NUMBER" \
      >"$RAW" 2>"$OUT_DIR/capture-stderr.log"; then
  echo "FAIL: gh api graphql exited nonzero"
  echo "stderr: $(cat "$OUT_DIR/capture-stderr.log")"
  exit 1
fi

echo "Captured $(wc -c <"$RAW") bytes -> $RAW"

PR='.data.repository.pullRequest'
BASE=$(jq -r "$PR.baseRefName" "$RAW")
HEAD=$(jq -r "$PR.headRefName" "$RAW")
echo "base=$BASE head=$HEAD"

INLINE_COUNT=$(jq -r "[$PR.reviewThreads.nodes[] | select(.isOutdated==false and .line!=null and .subjectType==\"LINE\")] | length" "$RAW")

if [ "$INLINE_COUNT" -lt 1 ]; then
  echo "FAIL: PR #$NUMBER has NO non-outdated inline thread — not a valid correctness fixture."
  echo "      Run find-inline-thread-pr.sh to pick a PR that does."
  exit 1
fi

echo ""
echo "Non-outdated inline threads ($INLINE_COUNT) — anchor ground truth:"
jq -r "$PR.reviewThreads.nodes[]
  | select(.isOutdated==false and .line!=null and .subjectType==\"LINE\")
  | \"  path=\(.path)\n    line=\(.line) startLine=\(.startLine) side=\(.diffSide) resolved=\(.isResolved)\n    expected anchored line content (diffHunk tail, marker-stripped):\n      [\(.comments.nodes[0].diffHunk | split(\"\n\") | .[-1] | .[1:])]\"" "$RAW"

echo ""
echo "PASS: fixture captured with >=1 non-outdated inline thread."
echo "Next: ./verify-anchor-groundtruth.sh $OWNER $NAME $NUMBER"
