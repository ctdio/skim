#!/usr/bin/env bash
# Offline prefetch world (Phase 5 harness). Source this file; it defines
# functions only. setup-origin.sh builds the world; run-harness.sh sources this
# for the mutation helpers (force-push, TSV edits, fixtures).
#
# Layout under $WORK:
#   origin.git          bare; main + feature branches + refs/pull/N/head
#   seed/               working clone used to author commits and push
#   clone/              the repo under test (--no-local single-branch clone of
#                       main: no feature branches, no refs/pull/*, no PR objects)
#   bin/gh              copy of fake-gh
#   fixtures/review-N.json
#   targets.tsv         display order, one row per PR (see TSV_COLUMNS)
#   world.env           MAIN_TIP, MAIN_FORK_EARLY, MAIN_FORK, EVIL_BASE_OID, GONE_BASE_TIP
#   gh.log              one line per fake gh call
#   clock               commit-date counter (keeps oids reproducible)
#
# PR layout: see verification-harness.md "setup-origin.sh".

PREFETCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKIM_REPO_ROOT="$(cd "$PREFETCH_LIB_DIR/../../../.." && pwd)"
HARNESS_BIN="${HARNESS_BIN:-$SKIM_REPO_ROOT/zig-out/bin/harness_prefetch}"

# number head_ref base_ref head_oid base_oid updated_at parent_number
TSV_COLUMNS="number head_ref base_ref head_oid base_oid updated_at parent_number"
REPO_KEY="github.com/fake/prefetch"
REPO_OWNER="fake"
REPO_NAME="prefetch"
# Valid-looking oid that exists nowhere: PR 8's base_oid, so the worker wants
# to fetch its (invalid) base branch.
EVIL_BASE_OID="0123456789abcdef0123456789abcdef01234567"

# Isolate every git child (ours and the worker's, which inherits this env) from
# the user's config: signing, hooks, diff.noprefix and pagers would all change
# bytes or behavior.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME="Skim Harness" GIT_AUTHOR_EMAIL="harness@example.invalid"
export GIT_COMMITTER_NAME="Skim Harness" GIT_COMMITTER_EMAIL="harness@example.invalid"
export LC_ALL=C

# =============================================================================
# World construction
# =============================================================================

world_build() {
  WORK="$1"
  mkdir -p "$WORK/bin" "$WORK/fixtures"
  : >"$WORK/gh.log"
  echo 0 >"$WORK/clock"
  cp "$PREFETCH_LIB_DIR/fake-gh" "$WORK/bin/gh"
  chmod +x "$WORK/bin/gh"

  pgit init -q --bare -b main "$WORK/origin.git" || return 1
  pgit clone -q "$WORK/origin.git" "$WORK/seed" 2>/dev/null || return 1
  local seed="$WORK/seed" n
  pgit -C "$seed" checkout -q -b main

  printf 'base line 1\nbase line 2\nbase line 3\n' >"$seed/base.txt"
  # 60 lines every feat-N PR edits at line 3N, so -U10 and -U3 output differ
  # and a wrong context width fails the byte comparison.
  for n in $(seq 1 60); do printf 'shared line %02d\n' "$n"; done >"$seed/shared.txt"
  seed_commit "main: base" || return 1
  printf 'early main\n' >"$seed/early.txt"
  seed_commit "main: early" || return 1
  MAIN_FORK_EARLY="$(pgit -C "$seed" rev-parse HEAD)"
  printf 'later main\n' >"$seed/later.txt"
  seed_commit "main: later" || return 1
  MAIN_FORK="$(pgit -C "$seed" rev-parse HEAD)"

  # Stack: stack-a (main) <- stack-b <- stack-c
  seed_branch_commit stack-a main stack_a.txt || return 1
  seed_branch_commit stack-b stack-a stack_b.txt || return 1
  seed_branch_commit stack-c stack-b stack_c.txt || return 1
  # PR 4 forks from an older main commit than everything else.
  seed_branch_commit feat-4 "$MAIN_FORK_EARLY" feat_4.txt 12 || return 1
  for n in 5 6 8 9 10 11 12 13 14; do
    seed_branch_commit "feat-$n" main "feat_$n.txt" "$((n * 3))" || return 1
  done
  # PR 7 sits on gone-base, which is deleted from origin below.
  seed_branch_commit gone-base main gone_base.txt || return 1
  GONE_BASE_TIP="$(pgit -C "$seed" rev-parse gone-base)"
  seed_branch_commit feat-7 gone-base feat_7.txt 21 || return 1

  pgit -C "$seed" push -q origin main stack-a stack-b stack-c gone-base \
    feat-4 feat-5 feat-6 feat-7 feat-8 feat-9 feat-10 feat-11 feat-12 feat-13 feat-14 || return 1
  local specs=(stack-a:refs/pull/1/head stack-b:refs/pull/2/head stack-c:refs/pull/3/head)
  for n in 4 5 6 7 8 9 10 11 12 13 14; do specs+=("feat-$n:refs/pull/$n/head"); done
  pgit -C "$seed" push -q origin "${specs[@]}" || return 1

  # Trunk advances after every PR was opened: no PR's merge base is the tip,
  # and the shared.txt edit makes a two-dot diff against the tip differ from
  # the merge-base diff.
  pgit -C "$seed" checkout -q main
  printf 'after prs\n' >"$seed/after.txt"
  sed -i 's/^shared line 58$/shared line 58 changed on main after the PRs/' "$seed/shared.txt"
  seed_commit "main: after PRs" || return 1
  pgit -C "$seed" push -q origin main || return 1
  MAIN_TIP="$(pgit -C "$seed" rev-parse main)"

  # --no-local: a plain local clone copies the whole object store, which would
  # make every PR head "present" and the worker would never fetch.
  pgit clone -q --no-local --single-branch --branch main "$WORK/origin.git" "$WORK/clone" 2>/dev/null || return 1

  write_world_env
  write_targets_tsv
  for n in $(tsv_numbers); do write_review_fixture "$n" || return 1; done

  # Gaps on the remote, created after targets.tsv recorded the oids.
  pgit -C "$WORK/origin.git" update-ref -d refs/pull/6/head || return 1
  pgit -C "$WORK/origin.git" update-ref -d refs/heads/gone-base || return 1
}

write_world_env() {
  cat >"$WORK/world.env" <<EOF
MAIN_TIP=$MAIN_TIP
MAIN_FORK_EARLY=$MAIN_FORK_EARLY
MAIN_FORK=$MAIN_FORK
GONE_BASE_TIP=$GONE_BASE_TIP
EVIL_BASE_OID=$EVIL_BASE_OID
EOF
}

# base_oid: trunk PRs get the main tip (GitHub's baseRefOid); stacked PRs get
# the parent's head; PR 7 gets the tip of gone-base (deleted from origin, so its
# refspec must be dropped from the batch); PR 8 gets an oid that exists nowhere.
write_targets_tsv() {
  local tsv="$WORK/targets.tsv" n head
  printf '# %s\n' "$(echo "$TSV_COLUMNS" | tr ' ' '\t')" >"$tsv"
  tsv_append 1 stack-a main "$(seed_oid stack-a)" "$MAIN_TIP" 0
  tsv_append 2 stack-b stack-a "$(seed_oid stack-b)" "$(seed_oid stack-a)" 1
  tsv_append 3 stack-c stack-b "$(seed_oid stack-c)" "$(seed_oid stack-b)" 2
  for n in 4 5 6 9 10 11 12 13 14; do
    head="$(seed_oid "feat-$n")"
    tsv_append "$n" "feat-$n" main "$head" "$MAIN_TIP" 0
  done
  tsv_append 7 feat-7 gone-base "$(seed_oid feat-7)" "$GONE_BASE_TIP" 0
  tsv_append 8 feat-8 -evil "$(seed_oid feat-8)" "$EVIL_BASE_OID" 0
  sort_tsv
}

# tsv_append <number> <head_ref> <base_ref> <head_oid> <base_oid> <parent_number>
tsv_append() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$(updated_at_for "$1" 0)" "$6" >>"$(targets_tsv)"
}

# Display order is ascending PR number (keeps "nearest 10" arithmetic obvious).
sort_tsv() {
  local tsv tmp
  tsv="$(targets_tsv)"
  tmp="$(mktemp)"
  { grep '^#' "$tsv"; grep -v '^#' "$tsv" | sort -t$'\t' -k1,1n; } >"$tmp"
  mv "$tmp" "$tsv"
}

# updated_at_for <number> <bump>: deterministic timestamp; bump N moves it N hours later.
updated_at_for() {
  printf '2026-01-%02dT%02d:00:%02dZ' "$((1 + $2))" "$(($1 % 24))" "$1"
}

# =============================================================================
# TSV access
# =============================================================================

# The TSV every helper reads and writes: $TARGETS when set (H9's separate
# world), else the main $WORK/targets.tsv.
targets_tsv() {
  echo "${TARGETS:-$WORK/targets.tsv}"
}

# tsv_get <number> <column-name>
tsv_get() {
  local col
  col="$(tsv_col_index "$2")" || return 1
  awk -F'\t' -v n="$1" -v c="$col" '!/^#/ && $1 == n { print $c; exit }' "$(targets_tsv)"
}

# tsv_set <number> <column-name> <value>
tsv_set() {
  local col tmp
  col="$(tsv_col_index "$2")" || return 1
  tmp="$(mktemp)"
  awk -F'\t' -v OFS='\t' -v n="$1" -v c="$col" -v v="$3" '!/^#/ && $1 == n { $c = v } { print }' "$(targets_tsv)" >"$tmp"
  mv "$tmp" "$(targets_tsv)"
}

tsv_numbers() {
  awk -F'\t' '!/^#/ { print $1 }' "$(targets_tsv)"
}

tsv_col_index() {
  local i=1 name
  for name in $TSV_COLUMNS; do
    [ "$name" = "$1" ] && { echo "$i"; return 0; }
    i=$((i + 1))
  done
  echo "tsv: unknown column $1" >&2
  return 1
}

# =============================================================================
# Scenario mutations
# =============================================================================

# H5: rewrite PR 5's commit, force-push branch and pull ref, record the new
# head + updated_at in targets.tsv, regenerate review-5.json. Prints the old head.
world_force_push_pr5() {
  local seed="$WORK/seed" old new
  old="$(tsv_get 5 head_oid)"
  pgit -C "$seed" checkout -q feat-5 || return 1
  printf 'feat-5 rewritten\n' >"$seed/feat_5.txt"
  pgit -C "$seed" add -A
  tick
  pgit -C "$seed" commit -q --amend -m "feat-5 (force-pushed)" || return 1
  new="$(pgit -C "$seed" rev-parse HEAD)"
  pgit -C "$seed" push -q -f origin feat-5 "+feat-5:refs/pull/5/head" || return 1
  pgit -C "$seed" checkout -q main
  tsv_set 5 head_oid "$new"
  tsv_set 5 updated_at "$(updated_at_for 5 1)"
  write_review_fixture 5
  echo "$old"
}

# H7: bump a PR's updated_at (bump index N) and regenerate its fixture.
world_bump_updated_at() {
  tsv_set "$1" updated_at "$(updated_at_for "$1" "$2")"
  write_review_fixture "$1"
}

# H8: a PR whose head exists on origin but not in the clone.
world_add_pr15() {
  seed_branch_commit feat-15 main feat_15.txt 45 || return 1
  pgit -C "$WORK/seed" push -q origin feat-15 feat-15:refs/pull/15/head || return 1
  pgit -C "$WORK/seed" checkout -q main
  tsv_append 15 feat-15 main "$(seed_oid feat-15)" "$MAIN_TIP" 0
  write_review_fixture 15
}

# H9: 130 trunk PRs (201..330) whose heads exist on origin only as
# refs/pull/N/head, listed in $TARGETS. More than fetch_cap, so the first
# batch cannot ask for all of them.
world_add_cap_prs() {
  local seed="$WORK/seed" n specs=()
  printf '# %s\n' "$(echo "$TSV_COLUMNS" | tr ' ' '\t')" >"$(targets_tsv)"
  for n in $(seq 201 330); do
    pgit -C "$seed" checkout -q -b "cap-$n" "$MAIN_TIP" || return 1
    printf 'cap %s\n' "$n" >"$seed/cap_$n.txt"
    seed_commit "cap-$n" || return 1
    specs+=("cap-$n:refs/pull/$n/head")
    tsv_append "$n" "cap-$n" main "$(seed_oid "cap-$n")" "$MAIN_TIP" 0
  done
  pgit -C "$seed" push -q origin "${specs[@]}" || return 1
  pgit -C "$seed" checkout -q main
}

# H12: 40 trunk PRs (401..440) listed in $TARGETS. 401-430 add one line;
# 431-440 add 800, so each of their diffs outweighs 401-430 together.
world_add_mixed_prs() {
  local seed="$WORK/seed" n i specs=()
  printf '# %s\n' "$(echo "$TSV_COLUMNS" | tr ' ' '\t')" >"$(targets_tsv)"
  for n in $(seq 401 440); do
    pgit -C "$seed" checkout -q -b "mixed-$n" "$MAIN_TIP" || return 1
    if ((n > 430)); then
      for i in $(seq 800); do echo "mixed $n line $i"; done >"$seed/mixed_$n.txt"
    else
      printf 'mixed %s\n' "$n" >"$seed/mixed_$n.txt"
    fi
    seed_commit "mixed-$n" || return 1
    specs+=("mixed-$n:refs/pull/$n/head")
    tsv_append "$n" "mixed-$n" main "$(seed_oid "mixed-$n")" "$MAIN_TIP" 0
  done
  pgit -C "$seed" push -q origin "${specs[@]}" || return 1
  pgit -C "$seed" checkout -q main
}

# =============================================================================
# Fixtures
# =============================================================================

# Payload shape matches review_parse.parsePrDetails (see its tests). Odd PRs
# carry one thread so payloads differ in size.
write_review_fixture() {
  local n="$1" updated head head_ref base_ref threads
  updated="$(tsv_get "$n" updated_at)"
  head="$(tsv_get "$n" head_oid)"
  head_ref="$(tsv_get "$n" head_ref)"
  base_ref="$(tsv_get "$n" base_ref)"
  threads='"reviewThreads":{"totalCount":0,"pageInfo":{"hasNextPage":false},"nodes":[]}'
  if ((n % 2 == 1)); then
    threads='"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false},"nodes":[
{"id":"PRRT_'"$n"'","isResolved":false,"isOutdated":false,"line":1,"startLine":null,"originalLine":1,"diffSide":"RIGHT","startDiffSide":null,"path":"feat_'"$n"'.txt","subjectType":"LINE",
"comments":{"pageInfo":{"hasNextPage":false},"nodes":[
{"id":"PRRC_'"$n"'","databaseId":'"$((1000 + n))"',"author":{"login":"alice"},"body":"PR-'"$n"'-THREAD at '"$updated"'","createdAt":"'"$updated"'","diffHunk":"@@ -0,0 +1 @@","pullRequestReview":{"id":"PRR_'"$n"'","state":"COMMENTED"},"replyTo":null}
]}}
]}'
  fi
  cat >"$WORK/fixtures/review-$n.json" <<EOF
{"data":{"viewer":{"login":"fake-viewer"},"repository":{"pullRequest":{
"id":"PR_$n","number":$n,"title":"PR $n","body":"","author":{"login":"alice"},
"isDraft":false,"baseRefName":"$base_ref","headRefName":"$head_ref","headRefOid":"$head","updatedAt":"$updated","reviewDecision":"",
"statusCheckRollup":null,"commits":{"nodes":[]},
"reviews":{"pageInfo":{"hasNextPage":false},"nodes":[]},
$threads
}}}}
EOF
}

# =============================================================================
# git helpers
# =============================================================================

pgit() {
  git -c init.defaultBranch=main -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}

seed_oid() {
  pgit -C "$WORK/seed" rev-parse "$1"
}

# Fixed, increasing commit dates (persisted in $WORK/clock) so oids are
# reproducible across runs.
tick() {
  local t
  t=$(($(cat "$WORK/clock") + 1))
  echo "$t" >"$WORK/clock"
  export GIT_AUTHOR_DATE="@$((1767225600 + t * 60)) +0000"
  export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"
}

seed_commit() {
  pgit -C "$WORK/seed" add -A
  tick
  pgit -C "$WORK/seed" commit -q -m "$1"
}

# seed_branch_commit <branch> <start-point> <file> [shared-line]: one commit
# adding <file> and, with [shared-line], editing that line of shared.txt.
seed_branch_commit() {
  pgit -C "$WORK/seed" checkout -q -b "$1" "$2" || return 1
  printf '%s line 1\n%s line 2\n' "$1" "$1" >"$WORK/seed/$3"
  if [ -n "${4:-}" ]; then
    sed -i "s/^shared line $(printf '%02d' "$4")\$/shared line $(printf '%02d' "$4") edited by $1/" "$WORK/seed/shared.txt"
  fi
  seed_commit "$1: add $3"
}
