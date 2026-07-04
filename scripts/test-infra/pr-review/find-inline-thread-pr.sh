#!/bin/bash
# Reconnaissance: find public PRs that have at least one NON-OUTDATED INLINE
# review thread (isOutdated == false && line != null && subjectType == LINE).
#
# WHY THIS EXISTS (Phase 2 gap): the known fixture ziglang/zig #26015 has a
# single OUTDATED thread (line == null) -> it buckets, so the *inline* anchor
# path is never exercised live by it. The anchor-CORRECTNESS check in
# verification-harness.md ("highest-value live check in the whole feature")
# REQUIRES a PR with a non-outdated inline thread. This script finds one so the
# tester doesn't hunt manually.
#
# Usage:  ./find-inline-thread-pr.sh [owner] [name] [state]
#   defaults: ziglang zig OPEN   (open PRs are likelier to carry live threads)
#
# Output: one line per matching PR, most-recently-updated first:
#   PR #<n>  inline=<count>  total=<count>  <title>
# Pick any with inline>=1 and feed it to capture-inline-thread.sh /
# verify-anchor-groundtruth.sh.
#
# Exit 0 = ran (even if zero matches); SKIP (exit 0) if prerequisites missing.

set -u

OWNER="${1:-ziglang}"
NAME="${2:-zig}"
STATE="${3:-OPEN}"

command -v gh >/dev/null 2>&1 || { echo "SKIP: gh not in PATH"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not in PATH"; exit 0; }
gh auth status >/dev/null 2>&1 || { echo "SKIP: gh not authenticated"; exit 0; }

RESP=$(gh api graphql \
  -f query='
    query($owner:String!,$name:String!,$state:[PullRequestState!]){
      repository(owner:$owner,name:$name){
        pullRequests(first:40, states:$state, orderBy:{field:UPDATED_AT,direction:DESC}){
          nodes{
            number title
            reviewThreads(first:100){
              totalCount
              nodes{ isOutdated line subjectType }
            }
          }
        }
      }
    }' \
  -f owner="$OWNER" -f name="$NAME" -f state="$STATE" 2>/tmp/find-inline-err.log) || {
    echo "FAIL: gh api graphql exited nonzero"
    echo "stderr: $(cat /tmp/find-inline-err.log)"
    exit 1
  }

MATCHES=$(echo "$RESP" | jq -r '
  .data.repository.pullRequests.nodes[]
  | { number, title,
      inline: [ .reviewThreads.nodes[]
                | select(.isOutdated==false and .line!=null and .subjectType=="LINE") ]
              | length,
      total: .reviewThreads.totalCount }
  | select(.inline > 0)
  | "PR #\(.number)  inline=\(.inline)  total=\(.total)  \(.title[0:60])"')

if [ -z "$MATCHES" ]; then
  echo "No $STATE PR in $OWNER/$NAME currently has a non-outdated inline thread."
  echo "Try a different state (CLOSED/MERGED) or repo. Exit 0 (not a failure)."
  exit 0
fi

echo "Non-outdated inline-thread PRs in $OWNER/$NAME ($STATE), newest first:"
echo "$MATCHES"
