# shellcheck shell=bash
# Reusable scratch-PR lifecycle for the PR-review write-path harnesses
# (Phase 3 pending-review, reused by Phase 4 thread interactions and Phase 5
# submit). Source this from a harness script; it exposes create/cleanup helpers
# plus the coordinates the write path needs (PR number + node id, head OID, and
# the first added line number that is guaranteed to be RIGHT-side in the diff).
#
# WHY A SHARED LIB: the "build it well once" mandate in the Phase 3 verification
# harness. Every write-path phase needs the same throwaway PR against ctdio/skim
# with a deterministic diff and a trap-driven teardown that leaves NOTHING behind
# (branch, PR, and any pending review are all reaped even on mid-run failure).
#
# USAGE (from a harness script):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$SCRIPT_DIR/scratch-pr-lib.sh"
#   sp_preflight || exit 0            # prints SKIP + returns 1 when unusable
#   sp_create_scratch_pr || exit 1    # sets SP_* globals, arms the EXIT trap
#   # ... exercise the write path against $SP_PR / $SP_PR_NODE_ID / $SP_HEAD_OID ...
#   # cleanup runs automatically on EXIT.
#
# Globals set by sp_create_scratch_pr:
#   SP_PR           PR number (e.g. 123)
#   SP_BRANCH       scratch branch name
#   SP_DEFAULT      repo default branch (fork point)
#   SP_PR_NODE_ID   PR GraphQL node id (PR_kw...) -> addPullRequestReview.pullRequestId
#   SP_HEAD_OID     head commit OID              -> addPullRequestReview.commitOID
#   SP_NEW_START    first appended (added, RIGHT-side) line number in README.md
#   SP_OWNER/SP_REPO  origin owner/name (default ctdio/skim)
#
# Env overrides:
#   SP_OWNER, SP_REPO   target repo (default: resolved from origin, fallback ctdio/skim)
#   SP_NUM_LINES        appended scratch lines (default 5)
#   SP_KEEP=1           skip teardown (leave the PR for manual inspection)

SP_PR=""
SP_BRANCH=""
SP_DEFAULT=""
SP_PR_NODE_ID=""
SP_HEAD_OID=""
SP_NEW_START=""
SP_WORKTREE=""
SP_OWNER="${SP_OWNER:-}"
SP_REPO="${SP_REPO:-}"

sp_preflight() {
  command -v gh  >/dev/null 2>&1 || { echo "SKIP: gh not in PATH"; return 1; }
  command -v git >/dev/null 2>&1 || { echo "SKIP: git not in PATH"; return 1; }
  command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not in PATH"; return 1; }
  gh auth status >/dev/null 2>&1 || { echo "SKIP: gh not authenticated"; return 1; }

  local origin owner_repo
  if [ -z "$SP_OWNER" ] || [ -z "$SP_REPO" ]; then
    owner_repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"
    [ -n "$owner_repo" ] || { echo "SKIP: cannot resolve origin owner/repo"; return 1; }
    SP_OWNER="${owner_repo%%/*}"
    SP_REPO="${owner_repo##*/}"
  fi

  # Push access is required; without it a scratch PR cannot be created.
  local can_push
  can_push="$(gh api "repos/$SP_OWNER/$SP_REPO" --jq '.permissions.push' 2>/dev/null)"
  [ "$can_push" = "true" ] || { echo "SKIP: no push access to $SP_OWNER/$SP_REPO"; return 1; }
  return 0
}

# Create a throwaway branch + draft PR with a deterministic README diff.
# Arms an EXIT trap so teardown always runs. Returns non-zero (and cleans up)
# on any failure so the caller can `|| exit 1`.
sp_create_scratch_pr() {
  local ts num_lines i
  ts="$(date +%s)-$$"
  num_lines="${SP_NUM_LINES:-5}"
  SP_BRANCH="skim-test/review-harness-$ts"

  trap sp_cleanup EXIT

  SP_DEFAULT="$(gh repo view "$SP_OWNER/$SP_REPO" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null)"
  [ -n "$SP_DEFAULT" ] || { echo "FAIL: cannot resolve default branch"; return 1; }

  git fetch origin "$SP_DEFAULT" >/dev/null 2>&1 || { echo "FAIL: git fetch origin $SP_DEFAULT"; return 1; }

  # Base line count BEFORE appending -> first appended line is an added RIGHT-side line.
  local base_lines
  base_lines="$(git show "origin/$SP_DEFAULT:README.md" 2>/dev/null | wc -l | tr -d ' ')"
  [ -n "$base_lines" ] && [ "$base_lines" -gt 0 ] || { echo "FAIL: cannot read origin/$SP_DEFAULT:README.md"; return 1; }
  SP_NEW_START=$(( base_lines + 1 ))

  # Build the commit in an isolated worktree so the caller's checkout stays clean.
  SP_WORKTREE="$(mktemp -d)"
  git worktree add "$SP_WORKTREE" -b "$SP_BRANCH" "origin/$SP_DEFAULT" >/dev/null 2>&1 \
    || { echo "FAIL: git worktree add"; return 1; }
  i=1
  while [ "$i" -le "$num_lines" ]; do
    echo "harness-line-$i" >> "$SP_WORKTREE/README.md"
    i=$(( i + 1 ))
  done
  git -C "$SP_WORKTREE" commit -am "test: review harness scratch change (auto, safe to delete)" >/dev/null 2>&1 \
    || { echo "FAIL: git commit"; return 1; }
  git -C "$SP_WORKTREE" push -u origin "$SP_BRANCH" >/dev/null 2>&1 \
    || { echo "FAIL: git push -u origin $SP_BRANCH"; return 1; }
  # The commit now lives on the pushed branch; the local worktree is disposable.
  git worktree remove --force "$SP_WORKTREE" >/dev/null 2>&1
  SP_WORKTREE=""

  # gh pr create prints the PR URL on stdout (no --json support); the number is the tail.
  local pr_url
  pr_url="$(gh pr create --repo "$SP_OWNER/$SP_REPO" --draft --head "$SP_BRANCH" --base "$SP_DEFAULT" \
    --title "test: review harness (auto, safe to close)" \
    --body "Automated write-path verification PR. Safe to close." 2>/dev/null)" || true
  SP_PR="${pr_url##*/}"
  [ -n "$SP_PR" ] || SP_PR="$(gh pr list --repo "$SP_OWNER/$SP_REPO" --head "$SP_BRANCH" --json number --jq '.[0].number' 2>/dev/null)"
  case "$SP_PR" in
    ''|*[!0-9]*) echo "FAIL: could not determine scratch PR number"; return 1 ;;
  esac

  # Resolve node id + head OID for the mutation inputs.
  local meta
  meta="$(gh api graphql \
    -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){id headRefOid}}}' \
    -f o="$SP_OWNER" -f r="$SP_REPO" -F n="$SP_PR" 2>/dev/null)" || { echo "FAIL: gh api graphql (pr metadata)"; return 1; }
  SP_PR_NODE_ID="$(echo "$meta" | jq -r '.data.repository.pullRequest.id')"
  SP_HEAD_OID="$(echo "$meta" | jq -r '.data.repository.pullRequest.headRefOid')"
  [ -n "$SP_PR_NODE_ID" ] && [ "$SP_PR_NODE_ID" != "null" ] || { echo "FAIL: empty PR node id"; return 1; }
  [ -n "$SP_HEAD_OID" ] && [ "$SP_HEAD_OID" != "null" ] || { echo "FAIL: empty head OID"; return 1; }

  echo "scratch PR #$SP_PR ($SP_BRANCH) node=$SP_PR_NODE_ID oid=${SP_HEAD_OID:0:12} added-line=$SP_NEW_START"
  return 0
}

# Delete any PENDING review the viewer owns on the scratch PR (via gh api, so it
# does not depend on skim), close the PR + delete the branch, and drop any
# leftover worktree. Idempotent; safe to call more than once.
sp_cleanup() {
  [ "${SP_KEEP:-0}" = "1" ] && { echo "SP_KEEP=1 set — leaving scratch PR #$SP_PR ($SP_BRANCH)"; return 0; }

  if [ -n "$SP_PR" ] && [ -n "$SP_OWNER" ] && [ -n "$SP_REPO" ]; then
    local pending
    pending="$(gh api graphql \
      -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviews(states:PENDING,first:20){nodes{id}}}}}' \
      -f o="$SP_OWNER" -f r="$SP_REPO" -F n="$SP_PR" 2>/dev/null \
      | jq -r '.data.repository.pullRequest.reviews.nodes[].id' 2>/dev/null)"
    local rid
    for rid in $pending; do
      gh api graphql \
        -f query='mutation($id:ID!){deletePullRequestReview(input:{pullRequestReviewId:$id}){pullRequestReview{id}}}' \
        -f id="$rid" >/dev/null 2>&1 || true
    done
    gh pr close "$SP_PR" --repo "$SP_OWNER/$SP_REPO" --delete-branch >/dev/null 2>&1 || true
  fi
  [ -n "$SP_BRANCH" ] && git push origin --delete "$SP_BRANCH" >/dev/null 2>&1 || true
  [ -n "$SP_WORKTREE" ] && [ -d "$SP_WORKTREE" ] && git worktree remove --force "$SP_WORKTREE" >/dev/null 2>&1 || true
  # Prevent a second trap invocation from re-running teardown.
  SP_PR=""; SP_BRANCH=""; SP_WORKTREE=""
}
