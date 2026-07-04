#!/bin/bash
# Diagnostic + capture: run the Phase 1 PR-review GraphQL query against a real
# public PR through `gh api graphql`, assert the wire-format assumptions the
# parser depends on, and save the raw payload as ground truth for canned tests.
#
# This is the single most load-bearing piece of Phase 1 test infra: it proves
# the exact `gh api graphql -f/-F` argv construction that `github.runGhApiGraphql`
# must mirror, and it re-captures the real payload so `review_parse.zig` tests
# assert against reality (not planning-time assumptions that may have drifted).
#
# Usage:  ./capture-graphql.sh [owner name number]
#   defaults: ziglang zig 26015  (public PR with a known outdated+resolved thread,
#             a suggestion block, and a reply chain)
#
# Exit 0 = PASS or SKIP (prerequisite missing); Exit 1 = FAIL (wire format broke).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUERY_FILE="$SCRIPT_DIR/pr-review.graphql"
OUT_DIR="${SKIM_PR_CAPTURE_DIR:-$HOME/.ai/plans/skim-github-pr-review/phase-01-foundation/captured}"

OWNER="${1:-ziglang}"
NAME="${2:-zig}"
NUMBER="${3:-26015}"

command -v gh  >/dev/null 2>&1 || { echo "SKIP: gh not in PATH"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not in PATH"; exit 0; }
gh auth status >/dev/null 2>&1 || { echo "SKIP: gh not authenticated"; exit 0; }
[ -f "$QUERY_FILE" ] || { echo "FAIL: query file missing at $QUERY_FILE"; exit 1; }

mkdir -p "$OUT_DIR"
RAW="$OUT_DIR/pr-${OWNER}-${NAME}-${NUMBER}.json"

# The argv below is the reference the Zig Child.run must reproduce exactly:
#   gh api graphql -f query=<multiline> -f owner=<s> -f name=<s> -F number=<int>
# `-f` = string variable, `-F` = typed variable (so `number` arrives as Int!, not a string).
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

fail=0
assert() { # <jq-filter> <description>
  if [ "$(jq -r "$1" "$RAW" 2>/dev/null)" = "true" ]; then
    echo "  PASS: $2"
  else
    echo "  FAIL: $2 (filter: $1 => $(jq -c "$1" "$RAW" 2>&1))"
    fail=1
  fi
}

PR='.data.repository.pullRequest'
echo "Wire-format assertions:"
assert ".data.viewer.login != null"                 "viewer.login present (drives is_mine + pending_review_id)"
assert "$PR.id | startswith(\"PR_\")"               "pullRequest.id is a PR_ node id (mutation target)"
assert "$PR.number == $NUMBER"                       "number echoes request"
assert "$PR.headRefOid | test(\"^[0-9a-f]{40}\$\")"  "headRefOid is a 40-char oid (pending-review commitOID)"
assert "$PR.reviewDecision != null"                  "reviewDecision present"
assert "$PR.statusCheckRollup.state != null"         "top-level rollup.state present"
assert "($PR.reviewThreads.nodes | length) >= 1"     "at least one review thread parsed"

# The documented gotchas the parser branches on. These are asserted structurally
# (types/shape), not by exact value, so external activity on the public PR can't
# cause a spurious FAIL.
T0="$PR.reviewThreads.nodes[0]"
assert "$T0.id | startswith(\"PRRT_\")"              "thread id is a PRRT_ node id"
assert "($T0.diffSide == \"LEFT\" or $T0.diffSide == \"RIGHT\")" "diffSide in {LEFT,RIGHT}"
assert "($T0.subjectType == \"LINE\" or $T0.subjectType == \"FILE\")" "subjectType in {LINE,FILE}"
assert "($T0.comments.nodes | length) >= 1"          "thread has >=1 comment"
assert "$T0.comments.nodes[0].id | startswith(\"PRRC_\")" "comment id is a PRRC_ node id"
assert "($T0.comments.nodes[0].databaseId | type) == \"number\"" "comment databaseId is numeric"

# Outdated-thread invariant: whenever a thread is outdated, `line` is null but
# `originalLine` survives. This is the single trickiest parse branch (nullable u32).
assert "[$PR.reviewThreads.nodes[] | select(.isOutdated) | (.line == null and .originalLine != null)] | all" \
       "every outdated thread has line==null AND originalLine!=null"

# nullable startDiffSide (was null on the captured thread) must be tolerated.
assert "($T0 | has(\"startDiffSide\"))"              "startDiffSide field present (may be null)"

echo ""
echo "Structural summary (for the implementer building canned test constants):"
jq "{
  viewer: .data.viewer.login,
  pr: {number: $PR.number, id: $PR.id, reviewDecision: $PR.reviewDecision, isDraft: $PR.isDraft,
       rollup: $PR.statusCheckRollup.state, truncated_reviews: $PR.reviews.pageInfo.hasNextPage,
       truncated_threads: $PR.reviewThreads.pageInfo.hasNextPage},
  threads: [$PR.reviewThreads.nodes[] | {id, path, line, originalLine, diffSide, startDiffSide,
       isResolved, isOutdated, subjectType,
       comments: [.comments.nodes[] | {id, author: .author.login, review_state: .pullRequestReview.state,
       replyTo: .replyTo.id}]}]
}" "$RAW"

if [ "$fail" -eq 0 ]; then
  echo ""
  echo "PASS: all wire-format assertions held; raw payload saved for canned tests."
  exit 0
else
  echo ""
  echo "FAIL: wire format drifted from parser assumptions (see above)."
  exit 1
fi
