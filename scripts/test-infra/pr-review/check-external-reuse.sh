#!/bin/bash
# Reuse of an EXTERNALLY-created pending review (Phase 3 edge case).
#
# The critical draft-safety guarantee: a pending review created OUTSIDE skim
# (e.g. on github.com, or by another tool) must be REUSED by skim's first
# comment, never duplicated. This creates the pending review directly via
# `gh api graphql addPullRequestReview`, THEN posts one comment via
# `skim debug pr-comment`, and asserts reviews(states:PENDING).totalCount == 1.
# A count of 2 means skim created its own review instead of reusing the fetched
# `pending_review_id` -> FAIL.
#
# GRACEFUL DEGRADATION: SKIP when gh/git/jq missing/unauthed/no-push, or when
# `skim debug pr-comment` is not yet implemented (detected via debug --help).
#
# Usage:  ./check-external-reuse.sh
#   SKIM_BIN=/path/to/skim ./check-external-reuse.sh
#
# Exit 0 = PASS or SKIP; Exit 1 = FAIL.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=scratch-pr-lib.sh
. "$SCRIPT_DIR/scratch-pr-lib.sh"

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

# Create the pending review OUTSIDE skim, directly through the API.
EXT_REVIEW="$(gh api graphql \
  -f query='mutation($prId:ID!,$oid:GitObjectID!){addPullRequestReview(input:{pullRequestId:$prId, commitOID:$oid}){pullRequestReview{id state}}}' \
  -f prId="$SP_PR_NODE_ID" -f oid="$SP_HEAD_OID" \
  --jq '.data.addPullRequestReview.pullRequestReview.id' 2>/dev/null)"
[ -n "$EXT_REVIEW" ] && [ "$EXT_REVIEW" != "null" ] || { echo "FAIL: could not create external pending review"; exit 1; }
echo "external pending review: $EXT_REVIEW"

# skim posts one comment; it must REUSE the external review, not create a new one.
"$BIN" debug pr-comment "$SP_PR" --path README.md --line "$SP_NEW_START" --side right \
  --body "reuse-external-review probe" || { echo "FAIL: pr-comment"; exit 1; }

PENDING="$(gh api graphql \
  -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviews(states:PENDING,first:10){totalCount}}}}' \
  -f o="$SP_OWNER" -f r="$SP_REPO" -F n="$SP_PR" \
  --jq '.data.repository.pullRequest.reviews.totalCount' 2>/dev/null)"

if [ "$PENDING" = "1" ]; then
  echo "PASS: external pending review reused (totalCount == 1)"
  exit 0
else
  echo "FAIL: expected 1 pending review, saw '$PENDING' — skim duplicated the external review"
  exit 1
fi
