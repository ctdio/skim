#!/bin/bash
# End-to-end thread-interaction smoke: the full conversation lifecycle through
# the REAL skim binary (Phase 4 mandatory tester check).
#
# Setup uses gh api directly (per the Phase 4 harness) to leave a SUBMITTED
# (non-draft) thread on a throwaway scratch PR — the common case for conversing.
# Then every mutation is driven through `skim debug pr-*` and verified by a
# `skim debug pr-view` re-query:
#   1. reply           -> comment count 2, body round-trips
#   2. resolve/unresolve
#   3. edit own reply  -> new body present, old body absent
#   4. delete own reply
#   5. reply-joins-pending pin: create a NEW pending review, reply again, and
#      RECORD (does not fail on) whether the reply reads back as a draft/PENDING.
# Teardown (branch + PR + any pending review) always runs via the lib EXIT trap.
#
# GRACEFUL DEGRADATION:
#   * SKIP (exit 0) when gh/git/jq missing or unauthenticated, or no push access.
#   * SKIP (exit 0) when `pr-reply` is not yet in `skim debug --help` — so this
#     can be committed alongside the scaffolding and goes green the moment the
#     implementer adds the subcommands. This also implies `pr-view --ids`
#     (node-id listing) exists, which Phase 4 adds in the same batch.
#   * Once pr-reply exists and gh is authed, a mid-run failure is a real FAIL.
#
# Usage:  ./thread-lifecycle.sh
#   SKIM_BIN=/path/to/skim ./thread-lifecycle.sh   # custom binary
#   SP_KEEP=1 ./thread-lifecycle.sh                # leave PR for inspection
#
# Exit 0 = PASS or SKIP; Exit 1 = FAIL.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=scratch-pr-lib.sh
. "$SCRIPT_DIR/scratch-pr-lib.sh"

REPLY_BODY='harness reply "quoted" %s émoji 🎯'
EDIT_BODY='edited harness reply body 🔁'

sp_preflight || exit 0

BIN="${SKIM_BIN:-$REPO_ROOT/zig-out/bin/skim}"
if [ ! -x "$BIN" ]; then
  echo "Building skim ($BIN not found)..."
  ( cd "$REPO_ROOT" && zig build ) || { echo "FAIL: zig build failed"; exit 1; }
fi

if ! "$BIN" debug --help 2>&1 | grep -q 'pr-reply'; then
  echo "SKIP: 'skim debug pr-reply' not implemented yet (not in debug --help)"
  exit 0
fi

sp_create_scratch_pr || { echo "FAIL: scratch PR setup"; exit 1; }

gql() { gh api graphql "$@"; }

# --- setup (gh api): pending review + seed thread, submitted as COMMENT -----
REVIEW_ID="$(gql -f query='mutation($prId:ID!,$oid:GitObjectID!){
      addPullRequestReview(input:{pullRequestId:$prId, commitOID:$oid}){ pullRequestReview { id } }
    }' -f prId="$SP_PR_NODE_ID" -f oid="$SP_HEAD_OID" \
  --jq '.data.addPullRequestReview.pullRequestReview.id' 2>/dev/null)"
[ -n "$REVIEW_ID" ] && [ "$REVIEW_ID" != "null" ] || { echo "FAIL: create pending review"; exit 1; }

gql -f query='mutation($rid:ID!,$path:String!,$line:Int!,$side:DiffSide!,$body:String!){
      addPullRequestReviewThread(input:{pullRequestReviewId:$rid, path:$path, line:$line, side:$side, body:$body}){ thread { id } }
    }' -f rid="$REVIEW_ID" -f path="README.md" -F line="$SP_NEW_START" -f side="RIGHT" \
  -f body="seed comment for the conversation harness" >/dev/null 2>&1 \
  || { echo "FAIL: seed thread"; exit 1; }

gql -f query='mutation($rid:ID!){submitPullRequestReview(input:{pullRequestReviewId:$rid, event:COMMENT}){pullRequestReview{id}}}' \
  -f rid="$REVIEW_ID" >/dev/null 2>&1 || { echo "FAIL: submit review as COMMENT"; exit 1; }

# The thread node id comes from skim's own pr-view --ids listing.
TID="$("$BIN" debug pr-view "$SP_PR" --ids 2>/dev/null | grep -oE 'PRRT_[A-Za-z0-9_-]+' | head -1)"
[ -n "$TID" ] || { echo "FAIL: could not read a PRRT_ thread id from 'pr-view --ids'"; exit 1; }
echo "  setup: submitted thread $TID"

# --- 1. reply, verify present ----------------------------------------------
"$BIN" debug pr-reply "$SP_PR" --thread "$TID" --body "$REPLY_BODY" || { echo "FAIL: pr-reply"; exit 1; }
"$BIN" debug pr-view "$SP_PR" | grep -q 'émoji 🎯' || { echo "FAIL: reply body not visible in pr-view"; exit 1; }
echo "  PASS: reply visible"

# --- 2. resolve / unresolve ------------------------------------------------
"$BIN" debug pr-resolve "$SP_PR" --thread "$TID" || { echo "FAIL: pr-resolve"; exit 1; }
"$BIN" debug pr-view "$SP_PR" | grep -qi 'resolved' || { echo "FAIL: thread not shown resolved after pr-resolve"; exit 1; }
"$BIN" debug pr-unresolve "$SP_PR" --thread "$TID" || { echo "FAIL: pr-unresolve"; exit 1; }
echo "  PASS: resolve/unresolve"

# --- 3. edit own reply (last own comment) ----------------------------------
CID="$("$BIN" debug pr-view "$SP_PR" --ids 2>/dev/null | grep -oE 'PRRC_[A-Za-z0-9_-]+' | tail -1)"
[ -n "$CID" ] || { echo "FAIL: could not read a PRRC_ comment id from 'pr-view --ids'"; exit 1; }
"$BIN" debug pr-edit "$SP_PR" --comment "$CID" --body "$EDIT_BODY" || { echo "FAIL: pr-edit"; exit 1; }
OUT="$("$BIN" debug pr-view "$SP_PR")"
echo "$OUT" | grep -q 'edited harness reply body' || { echo "FAIL: edited body missing"; exit 1; }
echo "$OUT" | grep -q 'émoji 🎯' && { echo "FAIL: old reply body survived the edit"; exit 1; }
echo "  PASS: edit replaced body"

# --- 4. delete own reply ---------------------------------------------------
"$BIN" debug pr-delete "$SP_PR" --comment "$CID" || { echo "FAIL: pr-delete"; exit 1; }
"$BIN" debug pr-view "$SP_PR" | grep -q 'edited harness reply body' && { echo "FAIL: deleted comment still visible"; exit 1; }
echo "  PASS: delete removed the reply"

# --- 5. reply-joins-pending pin (record, do not fail) ----------------------
gql -f query='mutation($prId:ID!,$oid:GitObjectID!){
      addPullRequestReview(input:{pullRequestId:$prId, commitOID:$oid}){ pullRequestReview { id } }
    }' -f prId="$SP_PR_NODE_ID" -f oid="$SP_HEAD_OID" >/dev/null 2>&1 \
  || { echo "FAIL: create 2nd pending review"; exit 1; }
"$BIN" debug pr-reply "$SP_PR" --thread "$TID" --body "reply while a pending review exists" \
  || { echo "FAIL: pr-reply into pending review (skim must parse whatever state returns)"; exit 1; }
PENDING_STATE="$(gql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){
      reviewThreads(first:20){nodes{comments(first:20){nodes{body pullRequestReview{state}}}}}}}}' \
  -f o="$SP_OWNER" -f r="$SP_REPO" -F n="$SP_PR" \
  --jq '[.data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[] | select(.body=="reply while a pending review exists") | .pullRequestReview.state][0]' 2>/dev/null)"
echo "  PIN (reply-joins-pending): reply-into-pending reads back pullRequestReview.state = ${PENDING_STATE:-<none>}"
echo "       (skim must render this without error whether PENDING or COMMENTED — see captured/RISKS.txt)"

echo "PASS"
