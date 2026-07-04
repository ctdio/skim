#!/bin/bash
# Capture REAL write-path mutation responses (Phase 3 ground truth).
#
# THE most load-bearing Phase 3 infra: `review_parse.parseCreatedReviewId` and
# `parseCreatedThread` must parse the EXACT JSON GitHub returns from the write
# mutations — not planning-time guesses. This script spins up a throwaway PR,
# runs the three mutations skim will issue (addPullRequestReview to create a
# PENDING review, addPullRequestReviewThread for a line comment AND a range
# comment with a hostile body, deletePullRequestReview to discard), and saves
# each raw response as a fixture the unit tests paste as canned data.
#
# It also proves two harness-critical facts against reality:
#   * REUSE: a second addPullRequestReviewThread against the same reviewId does
#     NOT create a second PENDING review (reviews(states:PENDING).totalCount==1).
#   * ERROR ENVELOPE: a bad path yields the `{"errors":[...]}` (HTTP 200) shape
#     both parsers must detect — captured so the error-path unit test is real.
#
# The thread-node selection MIRRORS `github.review_query`'s reviewThreads node
# so `review_parse` can reuse ONE thread-node parser for fetch AND mutation.
#
# Usage:  ./capture-mutations.sh
#   SKIM_PR_CAPTURE_DIR=/path ./capture-mutations.sh   # override fixture dir
#   SP_KEEP=1 ./capture-mutations.sh                   # leave the PR for inspection
#
# Exit 0 = PASS or SKIP (prerequisite missing); Exit 1 = FAIL.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scratch-pr-lib.sh
. "$SCRIPT_DIR/scratch-pr-lib.sh"

OUT_DIR="${SKIM_PR_CAPTURE_DIR:-$HOME/.ai/plans/skim-github-pr-review/phase-03-pending-review/captured}"

HOSTILE_BODY=$'harness single-line "quote" %s émoji 🎉\nsecond line with `backtick` & <html>'
RANGE_BODY=$'multi\nline range body "with quotes" 100% 🚀'

sp_preflight || exit 0
mkdir -p "$OUT_DIR"

sp_create_scratch_pr || { echo "FAIL: scratch PR setup"; exit 1; }

fail=0
gql() { gh api graphql "$@"; }

# --- 1. addPullRequestReview (omit event => PENDING) -----------------------
ADD_REVIEW="$OUT_DIR/mutation-add-review.json"
gql -f query='mutation($prId:ID!,$oid:GitObjectID!){
      addPullRequestReview(input:{pullRequestId:$prId, commitOID:$oid}){
        pullRequestReview { id state }
      }
    }' \
  -f prId="$SP_PR_NODE_ID" -f oid="$SP_HEAD_OID" >"$ADD_REVIEW" 2>/dev/null \
  || { echo "FAIL: addPullRequestReview"; exit 1; }

REVIEW_ID="$(jq -r '.data.addPullRequestReview.pullRequestReview.id' "$ADD_REVIEW")"
REVIEW_STATE="$(jq -r '.data.addPullRequestReview.pullRequestReview.state' "$ADD_REVIEW")"
if [ -z "$REVIEW_ID" ] || [ "$REVIEW_ID" = "null" ]; then
  echo "FAIL: addPullRequestReview returned no review id"; cat "$ADD_REVIEW"; exit 1
fi
[ "$REVIEW_STATE" = "PENDING" ] || { echo "  WARN: review state is '$REVIEW_STATE' (expected PENDING)"; fail=1; }
echo "  PASS: addPullRequestReview -> $REVIEW_ID state=$REVIEW_STATE"

# Shared thread-node selection (byte-mirror of github.review_query's nodes).
THREAD_SELECTION='thread {
        id isResolved isOutdated line startLine originalLine diffSide startDiffSide path subjectType
        comments(first: 50) {
          totalCount
          pageInfo { hasNextPage }
          nodes {
            id databaseId author { login } body createdAt diffHunk
            pullRequestReview { id state } replyTo { id }
          }
        }
      }'

# --- 2. addPullRequestReviewThread: single line, hostile body --------------
ADD_THREAD="$OUT_DIR/mutation-add-thread.json"
gql -f query="mutation(\$rid:ID!,\$path:String!,\$line:Int!,\$side:DiffSide!,\$body:String!){
      addPullRequestReviewThread(input:{pullRequestReviewId:\$rid, path:\$path, line:\$line, side:\$side, body:\$body}){
        $THREAD_SELECTION
      }
    }" \
  -f rid="$REVIEW_ID" -f path="README.md" -F line="$SP_NEW_START" -f side="RIGHT" \
  -f body="$HOSTILE_BODY" >"$ADD_THREAD" 2>/dev/null \
  || { echo "FAIL: addPullRequestReviewThread (line)"; exit 1; }

THREAD_ID="$(jq -r '.data.addPullRequestReviewThread.thread.id' "$ADD_THREAD")"
GOT_BODY="$(jq -r '.data.addPullRequestReviewThread.thread.comments.nodes[0].body' "$ADD_THREAD")"
if [ -z "$THREAD_ID" ] || [ "$THREAD_ID" = "null" ]; then
  echo "FAIL: addPullRequestReviewThread returned no thread id"; cat "$ADD_THREAD"; exit 1
fi
if [ "$GOT_BODY" = "$HOSTILE_BODY" ]; then
  echo "  PASS: line thread $THREAD_ID; body round-tripped byte-exact through argv"
else
  echo "  FAIL: body fidelity broke through argv"
  echo "        sent: $(printf '%q' "$HOSTILE_BODY")"
  echo "        got:  $(printf '%q' "$GOT_BODY")"
  fail=1
fi

# --- 2b. addPullRequestReviewThread: range (startLine/startSide) -----------
ADD_THREAD_RANGE="$OUT_DIR/mutation-add-thread-range.json"
RANGE_END=$(( SP_NEW_START + 3 ))
RANGE_START=$(( SP_NEW_START + 1 ))
gql -f query="mutation(\$rid:ID!,\$path:String!,\$line:Int!,\$side:DiffSide!,\$sl:Int!,\$ss:DiffSide!,\$body:String!){
      addPullRequestReviewThread(input:{pullRequestReviewId:\$rid, path:\$path, line:\$line, side:\$side, startLine:\$sl, startSide:\$ss, body:\$body}){
        $THREAD_SELECTION
      }
    }" \
  -f rid="$REVIEW_ID" -f path="README.md" -F line="$RANGE_END" -f side="RIGHT" \
  -F sl="$RANGE_START" -f ss="RIGHT" -f body="$RANGE_BODY" >"$ADD_THREAD_RANGE" 2>/dev/null \
  || { echo "FAIL: addPullRequestReviewThread (range)"; exit 1; }

RANGE_TID="$(jq -r '.data.addPullRequestReviewThread.thread.id' "$ADD_THREAD_RANGE")"
RANGE_SL="$(jq -r '.data.addPullRequestReviewThread.thread.startLine' "$ADD_THREAD_RANGE")"
if [ -n "$RANGE_TID" ] && [ "$RANGE_TID" != "null" ]; then
  echo "  PASS: range thread $RANGE_TID startLine=$RANGE_SL line=$RANGE_END"
else
  echo "  FAIL: range addPullRequestReviewThread returned no thread id"; cat "$ADD_THREAD_RANGE"; fail=1
fi

# --- 3. REUSE: both threads must share ONE pending review ------------------
PENDING_COUNT="$(gql \
  -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviews(states:PENDING,first:10){totalCount}}}}' \
  -f o="$SP_OWNER" -f r="$SP_REPO" -F n="$SP_PR" \
  --jq '.data.repository.pullRequest.reviews.totalCount' 2>/dev/null)"
if [ "$PENDING_COUNT" = "1" ]; then
  echo "  PASS: reuse holds — exactly 1 PENDING review after 2 thread mutations"
else
  echo "  FAIL: expected 1 PENDING review, saw '$PENDING_COUNT'"; fail=1
fi

# --- 4a. NULL-THREAD failure mode: a bad path returns thread:null, NOT an ---
#     errors envelope. Captured so the parser treats `thread == null` as a
#     failure (a real, non-obvious GitHub behavior, verified live).
NULL_THREAD="$OUT_DIR/mutation-null-thread.json"
gql -f query="mutation(\$rid:ID!,\$path:String!,\$line:Int!,\$side:DiffSide!,\$body:String!){
      addPullRequestReviewThread(input:{pullRequestReviewId:\$rid, path:\$path, line:\$line, side:\$side, body:\$body}){
        thread { id }
      }
    }" \
  -f rid="$REVIEW_ID" -f path="does/not/exist.txt" -F line=1 -f side="RIGHT" \
  -f body="should fail" >"$NULL_THREAD" 2>/dev/null || true
if [ "$(jq -r '.data.addPullRequestReviewThread.thread' "$NULL_THREAD" 2>/dev/null)" = "null" ]; then
  echo "  PASS: bad-path add returns thread:null (distinct from an errors envelope)"
else
  echo "  WARN: expected thread:null for a bad path; got:"; cat "$NULL_THREAD"; fail=1
fi

# --- 4b. ERROR ENVELOPE: a second addPullRequestReview while one is PENDING ->
#     {"errors":[...]} (HTTP 200). This is the EXACT error skim's ensure-review
#     queue exists to avoid; captured so the error-path parser test is real.
ERR_ENVELOPE="$OUT_DIR/mutation-error-envelope.json"
gql -f query='mutation($prId:ID!,$oid:GitObjectID!){
      addPullRequestReview(input:{pullRequestId:$prId, commitOID:$oid}){ pullRequestReview { id } }
    }' \
  -f prId="$SP_PR_NODE_ID" -f oid="$SP_HEAD_OID" >"$ERR_ENVELOPE" 2>/dev/null || true
if jq -e '.errors[0].message' "$ERR_ENVELOPE" >/dev/null 2>&1; then
  echo "  PASS: error envelope captured -> $(jq -r '.errors[0].message' "$ERR_ENVELOPE" | head -c 90)"
else
  echo "  WARN: expected {\"errors\":[...]} envelope from double-create; got:"; cat "$ERR_ENVELOPE"; fail=1
fi

# --- 5. deletePullRequestReview (pr-discard core) --------------------------
DEL_REVIEW="$OUT_DIR/mutation-delete-review.json"
gql -f query='mutation($id:ID!){deletePullRequestReview(input:{pullRequestReviewId:$id}){pullRequestReview{id state}}}' \
  -f id="$REVIEW_ID" >"$DEL_REVIEW" 2>/dev/null \
  || { echo "FAIL: deletePullRequestReview"; exit 1; }
DEL_ID="$(jq -r '.data.deletePullRequestReview.pullRequestReview.id' "$DEL_REVIEW")"
if [ "$DEL_ID" = "$REVIEW_ID" ]; then
  echo "  PASS: deletePullRequestReview returned the deleted review id"
else
  echo "  FAIL: deletePullRequestReview response unexpected"; cat "$DEL_REVIEW"; fail=1
fi

# --- 6. verify discard actually cleared the pending review -----------------
POST_DISCARD="$(gql \
  -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviews(states:PENDING,first:10){totalCount}}}}' \
  -f o="$SP_OWNER" -f r="$SP_REPO" -F n="$SP_PR" \
  --jq '.data.repository.pullRequest.reviews.totalCount' 2>/dev/null)"
if [ "$POST_DISCARD" = "0" ]; then
  echo "  PASS: no PENDING review survives discard"
else
  echo "  FAIL: $POST_DISCARD PENDING review(s) survived discard"; fail=1
fi

echo ""
echo "Fixtures written to: $OUT_DIR"
ls -1 "$OUT_DIR"/mutation-*.json 2>/dev/null | sed 's/^/  /'

if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "FAIL: one or more checks failed (see above)"; fi
exit "$fail"
