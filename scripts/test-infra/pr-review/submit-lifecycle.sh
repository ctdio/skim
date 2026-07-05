#!/bin/bash
# End-to-end submit + discard smoke: the terminal review action through the REAL
# skim binary (Phase 5 mandatory tester check).
#
# Submit is the consequential action of the whole feature, so prove it live
# against a throwaway scratch PR, driving `skim debug pr-*` (AD-2: the debug CLI
# calls the same sync cores the TUI uses):
#   A. draft one comment -> submit event=COMMENT with a body -> the review body is
#      published, the pending review is GONE, no "draft" survives.
#   B. body-only submit (NO drafts): submit again with just a body -> the
#      ensure-pending-review path creates a review on the fly and submits it.
#   C. discard path: draft a comment -> discard -> the draft is gone.
#   D. self-approval rejection (error path): submit event=approve on our own PR;
#      record GitHub's actual wording. The REQUIREMENT is a readable classified
#      error + nonzero exit; the exact message match is a WARN, not a FAIL
#      (ground truth captured separately by capture-self-approval-error.sh).
# Teardown (branch + PR + any pending review) always runs via the lib EXIT trap.
#
# GRACEFUL DEGRADATION:
#   * SKIP (exit 0) when gh/git/jq missing or unauthenticated, or no push access.
#   * SKIP (exit 0) when `pr-submit` is not yet in `skim debug --help` — so this
#     can be committed alongside the scaffolding and goes green the moment the
#     implementer adds the subcommand. Detection uses the --help listing, NOT the
#     "Unknown debug subcommand" stderr (that path exits(1) before the buffered
#     stderr flushes, so the string never reaches the pipe).
#   * Once pr-submit exists and gh is authed, a mid-run failure is a real FAIL.
#     A leftover PR/branch/pending review is a FAIL (the trap must reap them).
#
# Usage:  ./submit-lifecycle.sh
#   SKIM_BIN=/path/to/skim ./submit-lifecycle.sh   # custom binary
#   SP_KEEP=1 ./submit-lifecycle.sh                # leave PR for inspection
#
# Exit 0 = PASS or SKIP; Exit 1 = FAIL.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=scratch-pr-lib.sh
. "$SCRIPT_DIR/scratch-pr-lib.sh"

REVIEW_BODY='harness review body "quoted" %s émoji 📝'
BODY_ONLY='second, body-only review 🧪'

sp_preflight || exit 0

BIN="${SKIM_BIN:-$REPO_ROOT/zig-out/bin/skim}"
if [ ! -x "$BIN" ]; then
  echo "Building skim ($BIN not found)..."
  ( cd "$REPO_ROOT" && zig build ) || { echo "FAIL: zig build failed"; exit 1; }
fi

if ! "$BIN" debug --help 2>&1 | grep -q 'pr-submit'; then
  echo "SKIP: 'skim debug pr-submit' not implemented yet (not in debug --help)"
  exit 0
fi

sp_create_scratch_pr || { echo "FAIL: scratch PR setup"; exit 1; }

pending_count() {
  gh api graphql \
    -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviews(states:PENDING,first:10){totalCount}}}}' \
    -f o="$SP_OWNER" -f r="$SP_REPO" -F n="$SP_PR" \
    --jq '.data.repository.pullRequest.reviews.totalCount' 2>/dev/null
}

# GitHub's GraphQL reads are eventually consistent AFTER a mutation: a read issued
# immediately following pr-submit/pr-discard can return stale data (observed live —
# a discard's server-side PENDING count reported 0 while a back-to-back pr-view
# still projected the just-discarded draft). So never assert once on a post-mutation
# read; poll with a bounded backoff and only treat a value that never settles as a
# real FAIL. This keeps the hard-fail on genuine leftover pending reviews/drafts
# while removing the read-lag race from the mandatory PASS gate.
SETTLE_ATTEMPTS="${SP_SETTLE_ATTEMPTS:-6}"
SETTLE_SLEEP="${SP_SETTLE_SLEEP:-1}"

# Poll the authoritative server-side PENDING count until it equals $1.
# Returns 0 once it settles, else 1 (and reports the last-seen value).
wait_pending_count() {
  local want="$1" got="" i=0
  while [ "$i" -lt "$SETTLE_ATTEMPTS" ]; do
    got="$(pending_count)"
    [ "$got" = "$want" ] && return 0
    i=$(( i + 1 ))
    sleep "$SETTLE_SLEEP"
  done
  echo "    (pending count settled at '${got:-?}', wanted '$want' after ${SETTLE_ATTEMPTS} tries)"
  return 1
}

# Re-query pr-view until the fixed string $2 is PRESENT. Returns 0/1.
wait_view_present() {
  local pr="$1" needle="$2" i=0
  while [ "$i" -lt "$SETTLE_ATTEMPTS" ]; do
    "$BIN" debug pr-view "$pr" | grep -qF "$needle" && return 0
    i=$(( i + 1 ))
    sleep "$SETTLE_SLEEP"
  done
  return 1
}

# Re-query pr-view until the fixed string $2 is ABSENT. Returns 0/1.
wait_view_absent() {
  local pr="$1" needle="$2" i=0
  while [ "$i" -lt "$SETTLE_ATTEMPTS" ]; do
    "$BIN" debug pr-view "$pr" | grep -qF "$needle" || return 0
    i=$(( i + 1 ))
    sleep "$SETTLE_SLEEP"
  done
  return 1
}

# --- A. draft -> submit COMMENT with body ----------------------------------
"$BIN" debug pr-comment "$SP_PR" --path README.md --line "$SP_NEW_START" --side right \
  --body "draft before submit" || { echo "FAIL: seed draft comment"; exit 1; }
wait_pending_count 1 || { echo "FAIL: expected 1 pending review before submit"; exit 1; }

"$BIN" debug pr-submit "$SP_PR" --event comment --body "$REVIEW_BODY" \
  || { echo "FAIL: submit COMMENT"; exit 1; }

# Authoritative server truth first (the PENDING review must clear), THEN assert
# the pr-view projection with retries to absorb GitHub's post-mutation read lag.
wait_pending_count 0 || { echo "FAIL: server still reports a PENDING review after submit"; exit 1; }
wait_view_present "$SP_PR" 'émoji 📝'        || { echo "FAIL: submitted review body missing from pr-view"; exit 1; }
wait_view_absent  "$SP_PR" 'pending review:' || { echo "FAIL: pending review survived submit (still in pr-view)"; exit 1; }
echo "  PASS: A. draft submitted as COMMENT, pending review cleared"

# --- B. body-only submit (no drafts -> ensure-pending-review path) ----------
"$BIN" debug pr-submit "$SP_PR" --event comment --body "$BODY_ONLY" \
  || { echo "FAIL: body-only submit (ensure-pending-review path)"; exit 1; }
wait_pending_count 0 || { echo "FAIL: body-only submit left a PENDING review behind"; exit 1; }
wait_view_present "$SP_PR" 'body-only review' \
  || { echo "FAIL: body-only review body missing from pr-view"; exit 1; }
echo "  PASS: B. body-only submit published, no dangling pending review"

# --- C. discard path --------------------------------------------------------
"$BIN" debug pr-comment "$SP_PR" --path README.md --line $((SP_NEW_START+1)) --side right \
  --body "to be discarded" || { echo "FAIL: seed discard draft"; exit 1; }
wait_pending_count 1 || { echo "FAIL: expected a pending review before discard"; exit 1; }
"$BIN" debug pr-discard "$SP_PR" || { echo "FAIL: discard"; exit 1; }
# Gate on the authoritative server count clearing BEFORE asserting the draft is
# gone from pr-view — an immediate read can lag and misreport a leftover draft
# (this is the exact race that made case C flaky: 1/3 runs failed here).
wait_pending_count 0 || { echo "FAIL: pending review survived discard"; exit 1; }
wait_view_absent "$SP_PR" 'to be discarded' || { echo "FAIL: discarded draft still visible in pr-view"; exit 1; }
echo "  PASS: C. discard removed the pending draft"

# --- D. self-approval rejection (record actual wording; WARN on mismatch) ---
APPROVE_ERR="$("$BIN" debug pr-submit "$SP_PR" --event approve --body "" 2>&1)"
APPROVE_EC=$?
if [ "$APPROVE_EC" -eq 0 ]; then
  echo "FAIL: self-APPROVE via skim unexpectedly SUCCEEDED (AD-10 premise broken)"
  echo "  output: $APPROVE_ERR"
  exit 1
fi
if echo "$APPROVE_ERR" | grep -qi 'approve your own pull request'; then
  echo "  PASS: D. self-approve rejected with the expected 'own pull request' wording"
else
  echo "  WARN: D. self-approve rejected (exit=$APPROVE_EC) but wording not matched — record actual:"
  echo "        $(echo "$APPROVE_ERR" | head -2)"
fi
wait_pending_count 0 || { echo "FAIL: failed self-approve left a PENDING review behind"; exit 1; }

echo "PASS"
