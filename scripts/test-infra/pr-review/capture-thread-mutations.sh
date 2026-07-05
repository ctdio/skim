#!/bin/bash
# Capture REAL thread-interaction mutation responses (Phase 4 ground truth).
#
# THE most load-bearing Phase 4 infra: `review_parse` (parseCreatedComment,
# parseResolveResult, parseUpdatedComment) and `review_controller.applyMutationResult`
# must parse the EXACT JSON GitHub returns from the conversation mutations — not
# planning-time guesses. This script spins up a throwaway PR, drives the five
# mutations Phase 4 issues, and saves each raw response as a fixture the unit
# tests paste as canned data.
#
# It ALSO pins the three behaviors the Phase 4 verification harness flagged as
# risks (recorded in stdout AND in captured/RISKS.txt):
#   1. reply-joins-pending — does addPullRequestReviewThreadReply attach to an
#      existing PENDING review (reply comment's pullRequestReview.state==PENDING)?
#   2. deletePullRequestReviewComment payload shape (selectable fields differ:
#      {clientMutationId, pullRequestReview, pullRequestReviewComment}).
#   3. thread state after deleting the LAST comment — does the thread vanish
#      from reviewThreads, or remain with an empty comments list?
#
# The reply comment-node selection MIRRORS `github.review_query`'s comment nodes
# so `review_parse` can reuse ONE comment-node parser for fetch AND reply.
#
# Usage:  ./capture-thread-mutations.sh
#   SKIM_PR_CAPTURE_DIR=/path ./capture-thread-mutations.sh   # override fixture dir
#   SP_KEEP=1 ./capture-thread-mutations.sh                   # leave the PR for inspection
#
# Exit 0 = PASS or SKIP (prerequisite missing); Exit 1 = FAIL.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scratch-pr-lib.sh
. "$SCRIPT_DIR/scratch-pr-lib.sh"

OUT_DIR="${SKIM_PR_CAPTURE_DIR:-$HOME/.ai/plans/skim-github-pr-review/phase-04-thread-interactions/captured}"
RISKS="$OUT_DIR/RISKS.txt"

REPLY_BODY=$'harness reply "quoted" %s émoji 🎯\nsecond line `backtick` & <html>'
EDIT_BODY=$'edited reply body — 100% changed 🔁'

sp_preflight || exit 0
mkdir -p "$OUT_DIR"

sp_create_scratch_pr || { echo "FAIL: scratch PR setup"; exit 1; }

fail=0
gql() { gh api graphql "$@"; }

# Comment-node selection: byte-mirror of github.review_query's comment nodes so
# review_parse.parseCreatedComment reuses the SAME node parser as the fetch path.
COMMENT_SELECTION='id databaseId author { login } body createdAt diffHunk
        pullRequestReview { id state } replyTo { id }'

record_risk() { echo "$1" | tee -a "$RISKS"; }
: >"$RISKS"
echo "Phase 4 risk pins (captured $(date -u +%Y-%m-%dT%H:%M:%SZ) against $SP_OWNER/$SP_REPO PR #$SP_PR)" >>"$RISKS"
echo "" >>"$RISKS"

# --- setup: pending review + one seed thread ------------------------------
REVIEW_ID="$(gql -f query='mutation($prId:ID!,$oid:GitObjectID!){
      addPullRequestReview(input:{pullRequestId:$prId, commitOID:$oid}){ pullRequestReview { id state } }
    }' -f prId="$SP_PR_NODE_ID" -f oid="$SP_HEAD_OID" \
  --jq '.data.addPullRequestReview.pullRequestReview.id' 2>/dev/null)"
[ -n "$REVIEW_ID" ] && [ "$REVIEW_ID" != "null" ] || { echo "FAIL: create pending review"; exit 1; }

SEED="$(gql -f query="mutation(\$rid:ID!,\$path:String!,\$line:Int!,\$side:DiffSide!,\$body:String!){
      addPullRequestReviewThread(input:{pullRequestReviewId:\$rid, path:\$path, line:\$line, side:\$side, body:\$body}){
        thread { id comments(first:10){ nodes { $COMMENT_SELECTION } } }
      }
    }" -f rid="$REVIEW_ID" -f path="README.md" -F line="$SP_NEW_START" -f side="RIGHT" \
  -f body="seed comment for phase-4 conversation" 2>/dev/null)"
THREAD_ID="$(echo "$SEED" | jq -r '.data.addPullRequestReviewThread.thread.id')"
SEED_CID="$(echo "$SEED" | jq -r '.data.addPullRequestReviewThread.thread.comments.nodes[0].id')"
[ -n "$THREAD_ID" ] && [ "$THREAD_ID" != "null" ] || { echo "FAIL: seed thread"; exit 1; }
echo "  setup: review=$REVIEW_ID thread=$THREAD_ID seed-comment=$SEED_CID"

# Submit the review as COMMENT so we have a SUBMITTED (non-draft) thread — the
# common case for conversing (replies/resolve on already-submitted threads).
gql -f query='mutation($rid:ID!){submitPullRequestReview(input:{pullRequestReviewId:$rid, event:COMMENT}){pullRequestReview{id state}}}' \
  -f rid="$REVIEW_ID" >/dev/null 2>&1 || { echo "FAIL: submit review as COMMENT"; exit 1; }
echo "  setup: review submitted as COMMENT (thread is now non-draft)"

# --- 1. REPLY (no pending review present -> the immediate-post case) --------
REPLY_JSON="$OUT_DIR/mutation-reply.json"
gql -f query="mutation(\$tid:ID!,\$body:String!){
      addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:\$tid, body:\$body}){
        comment { $COMMENT_SELECTION }
      }
    }" -f tid="$THREAD_ID" -f body="$REPLY_BODY" >"$REPLY_JSON" 2>/dev/null \
  || { echo "FAIL: reply mutation"; exit 1; }

REPLY_CID="$(jq -r '.data.addPullRequestReviewThreadReply.comment.id' "$REPLY_JSON")"
REPLY_BODY_GOT="$(jq -r '.data.addPullRequestReviewThreadReply.comment.body' "$REPLY_JSON")"
REPLY_STATE="$(jq -r '.data.addPullRequestReviewThreadReply.comment.pullRequestReview.state' "$REPLY_JSON")"
if [ -z "$REPLY_CID" ] || [ "$REPLY_CID" = "null" ]; then
  echo "FAIL: reply returned no comment id"; cat "$REPLY_JSON"; exit 1
fi
if [ "$REPLY_BODY_GOT" = "$REPLY_BODY" ]; then
  echo "  PASS: reply $REPLY_CID; body round-tripped byte-exact through argv"
else
  echo "  FAIL: reply body fidelity broke"; echo "    sent: $(printf '%q' "$REPLY_BODY")"; echo "    got:  $(printf '%q' "$REPLY_BODY_GOT")"; fail=1
fi
record_risk "RISK 1a (reply WITHOUT a pending review): reply comment pullRequestReview.state = $REPLY_STATE"

# --- 2. RESOLVE ------------------------------------------------------------
RESOLVE_JSON="$OUT_DIR/mutation-resolve.json"
gql -f query='mutation($tid:ID!){resolveReviewThread(input:{threadId:$tid}){thread{id isResolved}}}' \
  -f tid="$THREAD_ID" >"$RESOLVE_JSON" 2>/dev/null || { echo "FAIL: resolve mutation"; exit 1; }
if [ "$(jq -r '.data.resolveReviewThread.thread.isResolved' "$RESOLVE_JSON")" = "true" ]; then
  echo "  PASS: resolve -> isResolved:true"
else
  echo "  FAIL: resolve did not set isResolved:true"; cat "$RESOLVE_JSON"; fail=1
fi

# --- 3. UNRESOLVE ----------------------------------------------------------
UNRESOLVE_JSON="$OUT_DIR/mutation-unresolve.json"
gql -f query='mutation($tid:ID!){unresolveReviewThread(input:{threadId:$tid}){thread{id isResolved}}}' \
  -f tid="$THREAD_ID" >"$UNRESOLVE_JSON" 2>/dev/null || { echo "FAIL: unresolve mutation"; exit 1; }
if [ "$(jq -r '.data.unresolveReviewThread.thread.isResolved' "$UNRESOLVE_JSON")" = "false" ]; then
  echo "  PASS: unresolve -> isResolved:false"
else
  echo "  FAIL: unresolve did not set isResolved:false"; cat "$UNRESOLVE_JSON"; fail=1
fi

# --- 4. UPDATE (edit own) — edit the reply we just posted ------------------
UPDATE_JSON="$OUT_DIR/mutation-update-comment.json"
gql -f query='mutation($cid:ID!,$body:String!){
      updatePullRequestReviewComment(input:{pullRequestReviewCommentId:$cid, body:$body}){
        pullRequestReviewComment { id body }
      }
    }' -f cid="$REPLY_CID" -f body="$EDIT_BODY" >"$UPDATE_JSON" 2>/dev/null \
  || { echo "FAIL: update mutation"; exit 1; }
UPDATE_BODY_GOT="$(jq -r '.data.updatePullRequestReviewComment.pullRequestReviewComment.body' "$UPDATE_JSON")"
if [ "$UPDATE_BODY_GOT" = "$EDIT_BODY" ]; then
  echo "  PASS: update -> body replaced byte-exact"
else
  echo "  FAIL: update body mismatch"; echo "    sent: $(printf '%q' "$EDIT_BODY")"; echo "    got:  $(printf '%q' "$UPDATE_BODY_GOT")"; fail=1
fi

# --- 5. REPLY-JOINS-PENDING pin: create a NEW pending review, reply again --
REVIEW_ID2="$(gql -f query='mutation($prId:ID!,$oid:GitObjectID!){
      addPullRequestReview(input:{pullRequestId:$prId, commitOID:$oid}){ pullRequestReview { id state } }
    }' -f prId="$SP_PR_NODE_ID" -f oid="$SP_HEAD_OID" \
  --jq '.data.addPullRequestReview.pullRequestReview.id' 2>/dev/null)"
[ -n "$REVIEW_ID2" ] && [ "$REVIEW_ID2" != "null" ] || { echo "FAIL: create 2nd pending review"; exit 1; }

REPLY_PENDING_JSON="$OUT_DIR/mutation-reply-pending.json"
gql -f query="mutation(\$tid:ID!,\$body:String!){
      addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:\$tid, body:\$body}){
        comment { $COMMENT_SELECTION }
      }
    }" -f tid="$THREAD_ID" -f body="reply issued while a pending review exists" \
  >"$REPLY_PENDING_JSON" 2>/dev/null || { echo "FAIL: reply-into-pending mutation"; exit 1; }
PENDING_REPLY_STATE="$(jq -r '.data.addPullRequestReviewThreadReply.comment.pullRequestReview.state' "$REPLY_PENDING_JSON")"
PENDING_REPLY_CID="$(jq -r '.data.addPullRequestReviewThreadReply.comment.id' "$REPLY_PENDING_JSON")"
record_risk "RISK 1b (reply WITH a pending review present): reply comment pullRequestReview.state = $PENDING_REPLY_STATE"
if [ "$PENDING_REPLY_STATE" = "PENDING" ]; then
  echo "  PIN: reply attaches to the pending review (state=PENDING) — draft badge path is EXERCISED"
else
  echo "  PIN: reply does NOT attach to pending review (state=$PENDING_REPLY_STATE) — skim renders whatever the response says"
fi
# Discard the 2nd pending review so the delete-last-comment step is deterministic
# (this also removes PENDING_REPLY_CID).
gql -f query='mutation($id:ID!){deletePullRequestReview(input:{pullRequestReviewId:$id}){pullRequestReview{id}}}' \
  -f id="$REVIEW_ID2" >/dev/null 2>&1 || true

# --- 6. DELETE payload shape + delete the edited reply ---------------------
DELETE_JSON="$OUT_DIR/mutation-delete-comment.json"
gql -f query='mutation($id:ID!){
      deletePullRequestReviewComment(input:{id:$id}){
        clientMutationId
        pullRequestReviewComment { id databaseId }
      }
    }' -f id="$REPLY_CID" >"$DELETE_JSON" 2>/dev/null \
  || { echo "FAIL: delete mutation"; exit 1; }
DEL_KEYS="$(jq -r '.data.deletePullRequestReviewComment | keys | join(",")' "$DELETE_JSON" 2>/dev/null)"
record_risk "RISK 2 (deletePullRequestReviewComment payload keys): $DEL_KEYS"
echo "  PASS: delete payload keys = $DEL_KEYS"

# --- 7. DELETE-LAST-COMMENT pin: delete the only remaining (seed) comment,--
#     then re-query reviewThreads to see whether the thread vanished. --------
gql -f query='mutation($id:ID!){deletePullRequestReviewComment(input:{id:$id}){clientMutationId}}' \
  -f id="$SEED_CID" >/dev/null 2>&1 || { echo "FAIL: delete seed comment"; exit 1; }

THREADS_AFTER="$OUT_DIR/thread-after-delete-last.json"
gql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){
      reviewThreads(first:20){ totalCount nodes { id isResolved comments(first:10){ totalCount nodes { id } } } }
    }}}' -f o="$SP_OWNER" -f r="$SP_REPO" -F n="$SP_PR" >"$THREADS_AFTER" 2>/dev/null \
  || { echo "FAIL: reviewThreads re-query"; exit 1; }
STILL_PRESENT="$(jq -r --arg t "$THREAD_ID" '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.id==$t)] | length' "$THREADS_AFTER")"
TOTAL_THREADS="$(jq -r '.data.repository.pullRequest.reviewThreads.totalCount' "$THREADS_AFTER")"
if [ "$STILL_PRESENT" = "0" ]; then
  record_risk "RISK 3 (thread after deleting its LAST comment): thread VANISHES from reviewThreads (totalCount now $TOTAL_THREADS)"
  echo "  PIN: deleting the last comment removed the thread from reviewThreads — apply: remove SessionThread + re-anchor"
else
  EMPTY_COUNT="$(jq -r --arg t "$THREAD_ID" '.data.repository.pullRequest.reviewThreads.nodes[] | select(.id==$t) | .comments.totalCount' "$THREADS_AFTER")"
  record_risk "RISK 3 (thread after deleting its LAST comment): thread REMAINS with comments.totalCount=$EMPTY_COUNT (totalCount $TOTAL_THREADS)"
  echo "  PIN: thread survives with $EMPTY_COUNT comments after deleting the last — apply accordingly"
fi

echo ""
echo "Fixtures written to: $OUT_DIR"
ls -1 "$OUT_DIR"/mutation-*.json "$OUT_DIR"/thread-after-delete-last.json 2>/dev/null | sed 's/^/  /'
echo ""
echo "Risk pins recorded to: $RISKS"
sed 's/^/  /' "$RISKS"

if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "FAIL: one or more checks failed (see above)"; fi
exit "$fail"
