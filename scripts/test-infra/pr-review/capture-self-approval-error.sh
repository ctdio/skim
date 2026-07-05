#!/bin/bash
# Capture the REAL GitHub self-approval rejection envelope (Phase 5 fixture).
#
# WHY THIS EXISTS: AD-10 forbids a live APPROVE on the harness's own scratch PR
# in the E2E flow, and the submit state machine's self-approval unit test asserts
# on a CANNED error envelope. That canned envelope must be GROUND TRUTH, not a
# guess — GitHub's wording ("Can not approve your own pull request") and the JSON
# shape (`errors[].message`) are what `review_controller`'s error_msg path and
# `github.classifyGhFailure`/submit error handling must string-match on. The
# failure IS the fixture (testing-strategy.md).
#
# It creates a throwaway scratch PR (via scratch-pr-lib.sh), opens a PENDING
# review through `gh api` directly (NOT skim — so this runs BEFORE the implementer
# ships anything), then submits event=APPROVE and captures the rejection to
#   captured/self-approval-error.json   (raw gh api graphql error envelope)
#   captured/self-approval-error.txt    (the message line + notes for the fixture)
# Teardown (branch + PR + pending review) always runs via the lib EXIT trap.
#
# GRACEFUL DEGRADATION:
#   * SKIP (exit 0) when gh/git/jq missing or unauthenticated, or no push access.
#   * A scratch PR is authored BY the viewer, so APPROVE must be rejected. If the
#     submit unexpectedly SUCCEEDS (GitHub changed the rule), that is a FAIL — the
#     phase's AD-10 assumption would be broken and the plan needs revisiting.
#
# Usage:  ./capture-self-approval-error.sh
#   SP_KEEP=1 ./capture-self-approval-error.sh   # leave the PR for inspection
#
# Exit 0 = PASS (envelope captured) or SKIP; Exit 1 = FAIL.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPTURED_DIR="$SCRIPT_DIR/captured"
# shellcheck source=scratch-pr-lib.sh
. "$SCRIPT_DIR/scratch-pr-lib.sh"

sp_preflight || exit 0
sp_create_scratch_pr || { echo "FAIL: scratch PR setup"; exit 1; }

# Open a pending review so we have a pullRequestReviewId to submit against.
REVIEW_ID="$(gh api graphql \
  -f query='mutation($prId:ID!,$oid:GitObjectID!){
      addPullRequestReview(input:{pullRequestId:$prId, commitOID:$oid}){ pullRequestReview { id } }
    }' -f prId="$SP_PR_NODE_ID" -f oid="$SP_HEAD_OID" \
  --jq '.data.addPullRequestReview.pullRequestReview.id' 2>/dev/null)"
[ -n "$REVIEW_ID" ] && [ "$REVIEW_ID" != "null" ] || { echo "FAIL: create pending review"; exit 1; }

# Attempt APPROVE on our own PR. gh exits nonzero, prints the GraphQL error
# envelope (data + errors) as pure JSON on stdout, and a "gh: <message>" summary
# on stderr. Capture the two streams SEPARATELY so the .json file stays valid JSON.
mkdir -p "$CAPTURED_DIR"
STDERR_FILE="$(mktemp)"
STDOUT="$(gh api graphql \
  -f query='mutation($rid:ID!){submitPullRequestReview(input:{pullRequestReviewId:$rid, event:APPROVE}){pullRequestReview{id state}}}' \
  -f rid="$REVIEW_ID" 2>"$STDERR_FILE")"
EC=$?
STDERR="$(cat "$STDERR_FILE")"; rm -f "$STDERR_FILE"

if [ "$EC" -eq 0 ]; then
  # If GitHub let us approve our own PR, AD-10's premise is wrong — surface loudly.
  echo "FAIL: self-APPROVE unexpectedly SUCCEEDED — AD-10 premise broken. Response:"
  echo "$STDOUT"
  exit 1
fi

# stdout is the pure JSON envelope on the usual 200-with-errors path. If empty
# (non-200), fall back to the stderr text so the fixture still records something.
if [ -n "$STDOUT" ]; then
  printf '%s\n' "$STDOUT" > "$CAPTURED_DIR/self-approval-error.json"
else
  printf '%s\n' "$STDERR" > "$CAPTURED_DIR/self-approval-error.json"
fi

# Extract the message for the fixture: prefer the structured envelope, then the
# gh stderr "gh: <message>" line, then a literal-string fallback.
MSG="$(printf '%s' "$STDOUT" | jq -r '.errors[]?.message // empty' 2>/dev/null | head -1)"
[ -n "$MSG" ] || MSG="$(printf '%s' "$STDERR" | sed -n 's/^gh: //p' | head -1)"
[ -n "$MSG" ] || MSG="$(printf '%s\n%s' "$STDOUT" "$STDERR" | grep -oiE 'can ?not approve your own pull request[^"]*' | head -1)"

{
  echo "# Ground-truth GitHub self-approval rejection (captured $(date -u +%Y-%m-%dT%H:%M:%SZ))"
  echo "# gh $(gh --version | head -1 | awk '{print $3}')  repo=$SP_OWNER/$SP_REPO  viewer=$(gh api graphql -f query='{viewer{login}}' --jq '.data.viewer.login' 2>/dev/null)"
  echo "# submitPullRequestReview(event:APPROVE) on the viewer's own PR."
  echo "#"
  echo "# Fixture use: review_controller's submit-error path + github error"
  echo "# classification must map an envelope carrying this message to a readable"
  echo "# 'cannot approve your own pull request'-class error_msg (dialog stays open,"
  echo "# body preserved). The unit test feeds a canned envelope with this message."
  echo ""
  echo "MESSAGE=$MSG"
  echo ""
  echo "# Raw envelope saved alongside in self-approval-error.json"
} > "$CAPTURED_DIR/self-approval-error.txt"

echo "PASS: captured self-approval rejection"
echo "  message: $MSG"
echo "  json:    $CAPTURED_DIR/self-approval-error.json"
echo "  notes:   $CAPTURED_DIR/self-approval-error.txt"
