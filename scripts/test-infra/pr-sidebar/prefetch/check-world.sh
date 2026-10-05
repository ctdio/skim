#!/usr/bin/env bash
# Diagnostic: build (or reuse) the prefetch world and check every property the
# H1-H8 scenarios rely on, using plain git against a scratch copy of the clone
# (the world itself is left untouched). Also pins down the GIT_TRACE line
# format the run-harness assertions grep for.
#
# Usage: check-world.sh                 # fresh world in a mktemp dir
#        WORK=/path check-world.sh      # reuse a world built by setup-origin.sh
# Exit 0 = every check passed.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

command -v git >/dev/null || { echo "SKIPPED: git not in PATH"; exit 0; }

if [ -z "${WORK:-}" ] || [ ! -d "$WORK/origin.git" ]; then
  WORK="${WORK:-$(mktemp -d /tmp/skim-prefetch-check-XXXX)}"
  world_build "$WORK" || { echo "FAIL setup: world_build failed"; exit 1; }
fi
source "$WORK/world.env"
fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
# check <name> <shell expression>: the expression is eval'd, so pipes, `!`
# and `&&` stay inside the check.
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
head_of() { tsv_get "$1" head_oid; }

origin="$WORK/origin.git"
scratch="$WORK/check-clone"
rm -rf "$scratch"
cp -a "$WORK/clone" "$scratch"

# --- origin -------------------------------------------------------------------
for n in 1 2 3 4 5 7 8 9 10 11 12 13 14; do
  pgit -C "$origin" rev-parse -q --verify "refs/pull/$n/head" >/dev/null || fail "origin has refs/pull/$n/head"
done
pass "origin has refs/pull/{1-5,7-14}/head"
check "origin lacks refs/pull/6/head" '! pgit -C "$origin" rev-parse -q --verify refs/pull/6/head'
check "origin lacks refs/heads/gone-base" '! pgit -C "$origin" rev-parse -q --verify refs/heads/gone-base'
check "origin main tip is MAIN_TIP" '[ "$(pgit -C "$origin" rev-parse main)" = "$MAIN_TIP" ]'

# --- clone under test ----------------------------------------------------------
check "clone has no refs/pull or refs/skim" '[ -z "$(pgit -C "$WORK/clone" for-each-ref refs/pull refs/skim)" ]'
check "clone tracks only origin/main" '[ "$(pgit -C "$WORK/clone" for-each-ref --format='\''%(refname)'\'' refs/remotes | grep -v HEAD)" = "refs/remotes/origin/main" ]'
check "clone has no FETCH_HEAD" '[ ! -e "$WORK/clone/.git/FETCH_HEAD" ]'
batch_input="$(for n in $(tsv_numbers); do head_of "$n"; done; echo "$MAIN_TIP"; echo "$EVIL_BASE_OID")"
batch_out="$(printf '%s\n' "$batch_input" | pgit -C "$scratch" cat-file --batch-check)"
check "cat-file: every PR head is missing from the clone" '[ "$(grep -c '\'' missing$'\'' <<<"$batch_out")" = "$(( $(tsv_numbers | wc -l) + 1 ))" ]'
check "cat-file: main tip is present" 'grep -q "^$MAIN_TIP commit" <<<"$batch_out"'

# --- batch fetch semantics (scratch copy) --------------------------------------
fetch_flags=(fetch --quiet --no-tags --no-write-fetch-head --no-recurse-submodules origin)
specs=()
for n in 1 2 3 4 5 6 7 9; do specs+=("+refs/pull/$n/head:refs/skim/pr-$n"); done
specs+=("+refs/heads/gone-base:refs/remotes/origin/gone-base")
err="$(pgit -C "$scratch" "${fetch_flags[@]}" "${specs[@]}" 2>&1)"; code=$?
check "batch with a missing pull ref exits 128" '[ "$code" = 128 ]'
check "stderr names the first missing ref only" '[ "$err" = "fatal: couldn'\''t find remote ref refs/pull/6/head" ]'
check "failed batch updated no refs" '[ -z "$(pgit -C "$scratch" for-each-ref refs/skim)" ]'
unset 'specs[5]'
err="$(pgit -C "$scratch" "${fetch_flags[@]}" "${specs[@]}" 2>&1)"; code=$?
check "retry without pull/6 names refs/heads/gone-base" '[ "$code" = 128 ] && [ "$err" = "fatal: couldn'\''t find remote ref refs/heads/gone-base" ]'
specs=("${specs[@]:0:${#specs[@]}-1}")
GIT_TRACE="$WORK/trace-sample.log" pgit -C "$scratch" "${fetch_flags[@]}" "${specs[@]}"
check "batch of present refs succeeds" '[ "$(pgit -C "$scratch" for-each-ref refs/skim | wc -l)" = 7 ]'
check "--no-write-fetch-head leaves FETCH_HEAD absent" '[ ! -e "$scratch/.git/FETCH_HEAD" ]'
pgit -C "$scratch" remote set-url origin "$WORK/nope.git"
err="$(pgit -C "$scratch" "${fetch_flags[@]}" "+refs/pull/1/head:refs/skim/pr-1" 2>&1)"; code=$?
check "unreachable origin fails without 'couldn't find remote ref' (H8)" '[ "$code" != 0 ] && ! grep -q "couldn'\''t find remote ref" <<<"$err"'
echo "     unreachable stderr: $(head -1 <<<"$err")"
pgit -C "$scratch" remote set-url origin "$origin"

# --- GIT_TRACE line format -------------------------------------------------------
GIT_TRACE="$WORK/trace-sample.log" pgit -C "$scratch" merge-base "$MAIN_TIP" "$(head_of 1)" >/dev/null
GIT_TRACE="$WORK/trace-sample.log" pgit -C "$scratch" diff --no-color --no-ext-diff -U10 "$MAIN_TIP" "$(head_of 1)" >/dev/null
check "trace has 'built-in: git fetch' lines" 'grep -q '\''trace: built-in: git fetch '\'' "$WORK/trace-sample.log"'
check "trace fetch line carries the refspecs" 'grep '\''trace: built-in: git fetch '\'' "$WORK/trace-sample.log" | head -1 | grep -q '\''+refs/pull/1/head:refs/skim/pr-1'\'''
check "trace has 'built-in: git merge-base' lines" 'grep -q '\''trace: built-in: git merge-base '\'' "$WORK/trace-sample.log"'
check "trace has 'built-in: git diff' lines" 'grep -q '\''trace: built-in: git diff '\'' "$WORK/trace-sample.log"'
check "-c config options are not echoed into the trace argv" '! grep '\''built-in: git fetch'\'' "$WORK/trace-sample.log" | grep -q -- '\''-c '\'''
echo "     sample: $(grep -m1 'built-in: git fetch ' "$WORK/trace-sample.log" | cut -c1-160)"

# --- stacks and merge bases ------------------------------------------------------
check "PR 2 merge base with PR 1 head is PR 1 head (stacked key)" ' [ "$(pgit -C "$scratch" merge-base "$(head_of 1)" "$(head_of 2)")" = "$(head_of 1)" ]'
check "PR 2 three-dot diff touches only stack_b.txt" ' [ "$(pgit -C "$scratch" diff --name-only refs/skim/pr-1...refs/skim/pr-2)" = "stack_b.txt" ]'
check "PR 3 whole-stack diff touches stack_a/b/c" ' [ "$(pgit -C "$scratch" diff --name-only "$MAIN_TIP"...refs/skim/pr-3 | tr '\''\n'\'' '\'' '\'')" = "stack_a.txt stack_b.txt stack_c.txt " ]'
check "PR 4 merge base is the early fork, not the main tip" ' [ "$(pgit -C "$scratch" merge-base "$MAIN_TIP" "$(head_of 4)")" = "$MAIN_FORK_EARLY" ]'
check "PR 5 merge base is MAIN_FORK, not the main tip" ' [ "$(pgit -C "$scratch" merge-base "$MAIN_TIP" "$(head_of 5)")" = "$MAIN_FORK" ]'
mb="$(pgit -C "$scratch" merge-base "$MAIN_TIP" "$(head_of 4)")"
check "two-dot from merge base == three-dot (cache key form matches miss path)" ' cmp -s <(pgit -C "$scratch" diff --no-color --no-ext-diff -U10 "$mb" "$(head_of 4)") <(pgit -C "$scratch" diff --no-color --no-ext-diff -U10 "$MAIN_TIP"...refs/skim/pr-4)'

check "-U3 and -U10 output differ for PR 9 (context width is observable)" '! cmp -s <(pgit -C "$scratch" diff -U3 "$MAIN_TIP"...refs/skim/pr-9) <(pgit -C "$scratch" diff -U10 "$MAIN_TIP"...refs/skim/pr-9)'
check "two-dot from the main tip differs from three-dot for PR 9 (merge base matters)" '! cmp -s <(pgit -C "$scratch" diff -U10 "$MAIN_TIP" refs/skim/pr-9) <(pgit -C "$scratch" diff -U10 "$MAIN_TIP"...refs/skim/pr-9)'

# --- targets.tsv -----------------------------------------------------------------
check "targets.tsv has 14 rows in display order 1..14" '[ "$(tsv_numbers | tr '\''\n'\'' '\'' '\'')" = "1 2 3 4 5 6 7 8 9 10 11 12 13 14 " ]'
check "PR 7 base_oid is the deleted gone-base tip" '[ "$(tsv_get 7 base_oid)" = "$GONE_BASE_TIP" ]'
check "PR 8 base_ref is -evil" '[ "$(tsv_get 8 base_ref)" = "-evil" ]'
check "PR 3 parent is 2" '[ "$(tsv_get 3 parent_number)" = 2 ]'

# --- fake gh -----------------------------------------------------------------------
gh_log="$WORK/check-gh.log"; : >"$gh_log"
out="$(FAKE_GH_LOG="$gh_log" FAKE_GH_FIXTURES="$WORK/fixtures" "$WORK/bin/gh" api graphql -f "query=query {
  multi line }" -f owner=fake -f name=prefetch -F number=3)"
check "fake gh serves review-3.json" '[ "$out" = "$(cat "$WORK/fixtures/review-3.json")" ]'
check "fake gh logs one line per call with number=3" '[ "$(wc -l <"$gh_log")" = 1 ] && grep -q '\''number=3$'\'' "$gh_log"'
err="$(FAKE_GH_LOG="$gh_log" FAKE_GH_FIXTURES="$WORK/fixtures" "$WORK/bin/gh" api graphql -F number=99 2>&1 >/dev/null)"; code=$?
check "fake gh fails for an unknown PR with gh's not-found text" '[ "$code" = 1 ] && grep -q '\''Could not resolve to a PullRequest'\'' <<<"$err"'

if [ -x "$HARNESS_BIN" ]; then
  for f in "$WORK"/fixtures/review-*.json; do
    "$HARNESS_BIN" check-review --file "$f" >/dev/null || fail "parsePrDetails accepts $(basename "$f")"
  done
  pass "every fixture parses with review_parse.parsePrDetails"
else
  echo "SKIP fixture parse check: $HARNESS_BIN not built (zig build harness-prefetch)"
fi

rm -rf "$scratch"
echo
echo "WORK=$WORK"
if ((fails > 0)); then echo "$fails check(s) failed"; exit 1; fi
echo "all world checks passed"
