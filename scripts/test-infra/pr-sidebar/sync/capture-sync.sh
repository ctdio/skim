#!/usr/bin/env bash
# Records real sync responses for skim's PR sidebar into captured/.
# Read-only GraphQL queries. Run by hand; tests never run this.
#   REPO=vercel/next.js EMPTY_REPO=ctdio/skim ./capture-sync.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="$here/captured"
repo="${REPO:-vercel/next.js}"
empty_repo="${EMPTY_REPO:-ctdio/skim}"
owner="${repo%/*}"; name="${repo#*/}"

command -v gh >/dev/null || { echo "SKIP: gh not installed"; exit 0; }
command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }
gh auth status >/dev/null 2>&1 || { echo "SKIP: gh not authenticated"; exit 0; }
mkdir -p "$out"

q() { cat "$here/$1.graphql"; }
fail() { echo "FAIL: $*"; exit 1; }

gh api graphql -f query="$(q index)" -f owner="$owner" -f name="$name" > "$out/index-page1.json"
cursor="$(jq -r '.data.repository.pullRequests.pageInfo.endCursor' "$out/index-page1.json")"
gh api graphql -f query="$(q index)" -f owner="$owner" -f name="$name" -f cursor="$cursor" > "$out/index-page2.json"
gh api graphql -f query="$(q closed)" -f owner="$owner" -f name="$name" > "$out/closed-page1.json"
gh api graphql -f query="$(q reconcile)" -f owner="$owner" -f name="$name" > "$out/reconcile-page1.json"

mapfile -t ids < <(jq -r '.data.repository.pullRequests.nodes[0:25][].id' "$out/index-page1.json")
id_args=(); for id in "${ids[@]}"; do id_args+=(-f "ids[]=$id"); done
gh api graphql -f query="$(q hydrate)" "${id_args[@]}" > "$out/hydrate-batch.json"

set +e
gh api graphql -f query="$(q hydrate)" -f "ids[]=${ids[0]}" -f "ids[]=PR_doesNotExist000" \
  > "$out/hydrate-partial-error.json" 2> "$out/hydrate-partial-error.stderr"
echo $? > "$out/hydrate-partial-error.code"
gh api graphql -f query="$(q index)" -f owner="$owner" -f name="no-such-repo-skim-capture" \
  > "$out/not-found-repo.json" 2> "$out/not-found-repo.stderr"
GH_CONFIG_DIR="$(mktemp -d)" GH_TOKEN= GITHUB_TOKEN= gh api graphql -f query='{viewer{login}}' \
  > /dev/null 2> "$out/auth-failure.stderr"
echo $? > "$out/auth-failure.code"
# A refused proxy connection stands in for an unreachable host.
HTTPS_PROXY=http://127.0.0.1:9 gh api graphql -f query='{viewer{login}}' \
  > /dev/null 2> "$out/network-failure.stderr"
echo $? > "$out/network-failure.code"
set -e

gh api graphql -f query="$(q index)" -f owner="${empty_repo%/*}" -f name="${empty_repo#*/}" > "$out/empty-index.json"
login="$(jq -r '.data.viewer.login' "$out/index-page1.json")"
gh api graphql -f query="$(q teams)" -f owner="$login" -f login="$login" > "$out/teams-null-org.json"

# Wire-format assertions: the parser depends on every one of these.
jq -e '.data.viewer.login and (.data.repository.pullRequests.nodes | length == 100)
       and .data.repository.pullRequests.pageInfo.hasNextPage' "$out/index-page1.json" >/dev/null || fail "index page shape"
jq -e '.data.repository.pullRequests.nodes[0] | .id and .number and .updatedAt and .headRefOid and .baseRefOid
       and (.labels.nodes | type == "array")' "$out/index-page1.json" >/dev/null || fail "index node fields"
# GitHub's UPDATED_AT sort key lags the reported updatedAt (captured
# 2026-10-04: #90554 at 19:47 sorted after rows at 18:00). The sync engine
# pages 6h below the watermark (planner.watermark_lookback_secs) and re-reads
# the whole index on reconcile runs to cover it, so only the property the
# watermark itself needs is asserted here: row 0 is the newest.
jq -e '[.data.repository.pullRequests.nodes[].updatedAt] | .[0] == max' "$out/index-page1.json" >/dev/null || fail "index row 0 is not the newest"
jq -e '.data.repository.pullRequests.nodes | all(.state == "CLOSED" or .state == "MERGED")' "$out/closed-page1.json" >/dev/null || fail "closed states"
jq -e '.data.nodes | length == 25 and all(has("additions") and has("reviewDecision") and has("latestOpinionatedReviews"))' "$out/hydrate-batch.json" >/dev/null || fail "hydrate shape"
jq -e '.data.nodes[1] == null and .errors[0].type == "NOT_FOUND"' "$out/hydrate-partial-error.json" >/dev/null || fail "partial error shape"
[ "$(cat "$out/hydrate-partial-error.code")" = 1 ] || fail "partial error exit code"
jq -e '.data.repository == null' "$out/not-found-repo.json" >/dev/null || fail "not-found shape"
grep -q "gh auth login" "$out/auth-failure.stderr" || fail "auth stderr wording"
grep -q "dial tcp" "$out/network-failure.stderr" || fail "network stderr wording"
jq -e '.data.repository.pullRequests.pageInfo == {"hasNextPage":false,"endCursor":null}' "$out/empty-index.json" >/dev/null || fail "empty page shape"
jq -e '.data.viewer.organization == null' "$out/teams-null-org.json" >/dev/null || fail "teams null org"

echo "PASS: captured $(ls "$out" | wc -l) files into $out"
