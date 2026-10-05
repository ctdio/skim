#!/usr/bin/env bash
# Phase 5 prefetch harness: builds the offline world (setup-origin.sh), then
# drives zig-out/bin/harness_prefetch through scenarios H1-H15 and asserts on
# DB rows, GIT_TRACE output and the fake gh call log. Prints one PASS/FAIL line
# per assertion; exits non-zero on any failure.
#
# Usage: zig build harness-prefetch && run-harness.sh
#        WORK=/tmp/somewhere run-harness.sh      # world location (must not exist yet)
#        KEEP_WORK=1 run-harness.sh              # keep the mktemp world after a pass
#        STOP_AFTER=H1 run-harness.sh            # stop after a scenario
#
# A world created with mktemp is removed on exit unless KEEP_WORK is set or an
# assertion failed; a WORK you pass in is always kept.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

command -v git >/dev/null || { echo "SKIPPED: git not in PATH"; exit 0; }
[ -x "$HARNESS_BIN" ] || { echo "FAIL setup: $HARNESS_BIN missing (run: zig build harness-prefetch)"; exit 1; }

if [ -z "${WORK:-}" ]; then
  WORK="$(mktemp -d /tmp/skim-prefetch-XXXX)"
  [ -z "${KEEP_WORK:-}" ] && trap remove_work_unless_failed EXIT
fi
WORK="$WORK" "$PREFETCH_LIB_DIR/setup-origin.sh" >/dev/null || { echo "FAIL setup: setup-origin.sh failed"; exit 1; }
source "$WORK/world.env"
export FAKE_GH_LOG="$WORK/gh.log"
export FAKE_GH_FIXTURES="$WORK/fixtures"
DB="$WORK/prs.db"
CLONE="$WORK/clone"
FAILS=0
SCENARIO=setup

remove_work_unless_failed() {
  if ((FAILS == 0)); then rm -rf "$WORK"; fi
}

main() {
  echo "WORK=$WORK"
  scenario_H1
  scenario_H1b
  scenario_H2
  scenario_H3
  scenario_H4
  scenario_H5
  scenario_H6
  scenario_H10
  scenario_H7
  scenario_H8
  scenario_H9
  scenario_H11
  scenario_H12
  scenario_H13
  scenario_H14
  scenario_H15
  finish
}

# =============================================================================
# Scenarios
# =============================================================================

scenario_H1() {
  begin H1
  seed_db
  run_prefetch H1 --focus 1
  expect_eq "phase is idle" idle "$STATUS_PHASE"
  # PR 6 (head unreachable) fails its diff job. PR 8 (invalid base name) is
  # .skipped per technical-details, which may or may not count as a failure;
  # >= 1 is what the tech design guarantees.
  expect_true "failures >= 1 (PR 6)" "[ ${STATUS_FAILURES:-0} -ge 1 ]"

  local n
  for n in 1 2 3 4 5 9 10 11 12 13 14; do
    expect_cached_diff "$n"
  done

  local head1 head2 head3
  head1="$(tsv_get 1 head_oid)"; head2="$(tsv_get 2 head_oid)"; head3="$(tsv_get 3 head_oid)"
  expect_eq "PR 2 keyed on its parent (merge base = PR 1 head)" "$head1" "$(dump_key "$head1" "$head2")"
  expect_eq "PR 2 diff touches only stack_b.txt" "stack_b.txt" "$(diff_files "$(dump_key "$head1" "$head2")" "$head2")"

  local ws_mb
  ws_mb="$(dump_key "$MAIN_TIP" "$head3")"
  expect_true "whole-stack key for PR 3 exists (base tip = main tip)" "[ '$ws_mb' != none ]"
  expect_eq "whole-stack diff touches stack_a/b/c" "stack_a.txt stack_b.txt stack_c.txt" "$(diff_files "$ws_mb" "$head3" | tr '\n' ' ' | sed 's/ $//')"

  local mb4
  mb4="$(dump_key "$MAIN_TIP" "$(tsv_get 4 head_oid)")"
  expect_true "PR 4 merge base is not the main tip" "[ '$mb4' != '$MAIN_TIP' ]"
  expect_eq "PR 4 merge base is its fork point" "$MAIN_FORK_EARLY" "$mb4"

  local trace="$WORK/trace-H1.log" first_fetch first_fetch_line first_diff_line
  first_fetch="$(trace_lines "$trace" fetch | head -1)"
  expect_true "first git fetch is a batch (more than one refspec)" "[ $(refspec_count "$first_fetch") -gt 1 ]"
  first_fetch_line="$(trace_line_no "$trace" fetch)"
  first_diff_line="$(trace_line_no "$trace" diff)"
  expect_true "batch fetch happens before any git diff" "[ -n '$first_fetch_line' ] && [ -n '$first_diff_line' ] && [ $first_fetch_line -lt ${first_diff_line:-0} ]"
  expect_true "first git diff is for the focused PR 1" "trace_lines '$trace' diff | head -1 | grep -q '$head1'"
  expect_true "clone has no FETCH_HEAD (--no-write-fetch-head)" "[ ! -e '$CLONE/.git/FETCH_HEAD' ]"

  # Snapshots for H1b/H7.
  cp "$WORK/targets.tsv" "$WORK/targets-H1.tsv"
  dump_diffs >"$WORK/diffs-H1.tsv"
  dump_threads >"$WORK/threads-H1.tsv"
  cp "$FAKE_GH_LOG" "$WORK/gh-H1.log"
  stop_point H1
}

scenario_H1b() {
  begin H1b
  run_prefetch H1b --focus 1
  local trace="$WORK/trace-H1b.log"
  # PR 6's head can never be fetched (its pull ref is gone), so a new worker
  # retries it once: one fetch carrying only that refspec, and one failing
  # merge-base for its head. Nothing else may repeat.
  expect_eq "no git merge-base on the second round (except PR 6)" 0 \
    "$(trace_lines "$trace" merge-base | grep -vc "$(tsv_get 6 head_oid)")"
  expect_eq "no git diff on the second round" 0 "$(trace_lines "$trace" diff | wc -l)"
  expect_eq "only PR 6's unreachable ref is refetched" "" \
    "$(trace_lines "$trace" fetch | grep -o '+refs/[^ ]*' | grep -v '^+refs/pull/6/head:' | sort -u)"
  expect_eq "diff_cache rows unchanged" "$(cut -f1,2,3,5 "$WORK/diffs-H1.tsv")" "$(dump_diffs | cut -f1,2,3,5)"
  expect_eq "gh call log did not grow" "$(wc -l <"$WORK/gh-H1.log")" "$(wc -l <"$FAKE_GH_LOG")"
  stop_point H1b
}

scenario_H2() {
  begin H2
  local trace="$WORK/trace-H1.log" fetches
  fetches="$(trace_lines "$trace" fetch)"
  expect_true "first batch contains refs/pull/6/head" "sed -n 1p <<<\"\$fetches\" | grep -q '+refs/pull/6/head:'"
  expect_true "second fetch drops refs/pull/6/head" "[ \$(wc -l <<<\"\$fetches\") -ge 2 ] && ! sed -n 2p <<<\"\$fetches\" | grep -q '+refs/pull/6/head:'"
  local batched=0 line
  while IFS= read -r line; do
    [ "$(refspec_count "$line")" -gt 1 ] || break
    batched=$((batched + 1))
  done <<<"$fetches"
  expect_true "at most 1 + 3 batched fetches before any single-refspec fetch (got $batched)" "[ $batched -le 4 ]"
  expect_eq "PR 6 has no diff_cache row" "" "$(rows_for_head "$(tsv_get 6 head_oid)")"
  stop_point H2
}

scenario_H3() {
  begin H3
  # gone-base was deleted from origin after the TSV recorded its tip, so the
  # first batch fails on refs/heads/gone-base too. The worker drops it and
  # retries; the tip still arrives through PR 7's own pull ref history.
  local fetches
  fetches="$(trace_lines "$WORK/trace-H1.log" fetch)"
  expect_true "first batch asks for refs/heads/gone-base" "sed -n 1p <<<\"\$fetches\" | grep -q '+refs/heads/gone-base:'"
  expect_true "a later batch drops refs/heads/gone-base" "tail -n +2 <<<\"\$fetches\" | grep -q ' +refs/' && tail -n +2 <<<\"\$fetches\" | grep -v -q '+refs/heads/gone-base:'"
  expect_cached_diff 7
  local n missing=""
  for n in 9 10 11 12 13 14; do
    [ -n "$(rows_for_head "$(tsv_get "$n" head_oid)")" ] || missing+=" $n"
  done
  expect_eq "PRs 9-14 (later in the batch) are cached" "" "$missing"
  stop_point H3
}

scenario_H4() {
  begin H4
  expect_eq "'-evil' never reaches git argv" 0 "$(cat "$WORK"/trace-*.log | grep -c -- '-evil')"
  expect_eq "PR 8 has no diff_cache row" "" "$(rows_for_head "$(tsv_get 8 head_oid)")"
  expect_true "harness stderr logs the rejected ref name" "grep -qiE 'InvalidRefName|reject' '$WORK/harness-H1.err'"
  stop_point H4
}

scenario_H5() {
  begin H5
  local old_head old_mb new_head
  old_head="$(tsv_get 5 head_oid)"
  old_mb="$(dump_key "$MAIN_TIP" "$old_head")"
  printf 'stale bytes for the pre-force-push head\n' >"$WORK/stale-5.diff"
  harness put-diff --db "$DB" --repo-id "$REPO_ID" --merge-base "$old_mb" --head "$old_head" --file "$WORK/stale-5.diff" --now 1 ||
    fail "put-diff stale row for PR 5"
  harness pin --db "$DB" --repo-id "$REPO_ID" --number 5 --head "$old_head" --merge-base "$old_mb" || fail "pin PR 5 at old key"
  echo "$old_head $old_mb" >"$WORK/pr5-old-key"

  world_force_push_pr5 >/dev/null || fail "force-push PR 5"
  new_head="$(tsv_get 5 head_oid)"
  expect_true "PR 5 head changed in targets.tsv" "[ '$new_head' != '$old_head' ]"
  seed_db
  run_prefetch H5 --focus 5
  expect_cached_diff 5
  expect_eq "old pinned PR 5 row is still present" "$old_mb $old_head" "$(dump_diffs | awk -F'\t' -v h="$old_head" '$2 == h { print $1, $2 }')"
  expect_eq "refs/skim/pr-5 moved to the force-pushed head" "$new_head" "$(git -C "$CLONE" rev-parse refs/skim/pr-5 2>/dev/null)"
  stop_point H5
}

scenario_H6() {
  begin H6
  local head1 head9 mb1 mb9 before expected
  head1="$(tsv_get 1 head_oid)"; head9="$(tsv_get 9 head_oid)"
  mb1="$(dump_key "$MAIN_TIP" "$head1")"; mb9="$(dump_key "$MAIN_TIP" "$head9")"
  harness pin --db "$DB" --repo-id "$REPO_ID" --number 1 --head "$head1" --merge-base "$mb1" || fail "pin PR 1"
  harness pin --db "$DB" --repo-id "$REPO_ID" --number 9 --head "$head9" --merge-base "$mb9" || fail "pin PR 9"
  before="$(dump_diffs | wc -l)"

  # Every key is already cached here, so this only evicts because the worker
  # evicts once per targets version before going idle.
  run_prefetch H6 --focus 1 --budget 1 --keep-nearest 0
  expected="$(printf '%s %s\n%s %s\n%s\n' "$mb1" "$head1" "$mb9" "$head9" "$(cat "$WORK/pr5-old-key" | awk '{ print $2, $1 }')" | sort)"
  expect_eq "only pinned rows survive a 1-byte budget" "$expected" "$(dump_diffs | awk -F'\t' '{ print $1, $2 }' | sort)"
  expect_eq "phase is idle under budget pressure" idle "$STATUS_PHASE"

  run_prefetch H6-refill --focus 1
  expect_eq "default budget repopulates the evicted rows" "$before" "$(dump_diffs | wc -l)"

  # Room for the pinned rows plus the three unpinned rows nearest the focus
  # (PR 2, PR 3, PR 3's whole stack): every farther row must go, whatever
  # order the earlier runs wrote or touched them in.
  local head2 head3 ws_mb keep budget
  head2="$(tsv_get 2 head_oid)"; head3="$(tsv_get 3 head_oid)"
  ws_mb="$(dump_key "$MAIN_TIP" "$head3")"
  keep="$({
    echo "$mb1 $head1"
    echo "$mb9 $head9"
    awk '{ print $2, $1 }' "$WORK/pr5-old-key"
    echo "$head1 $head2"
    echo "$head2 $head3"
    echo "$ws_mb $head3"
  } | sort)"
  budget="$(dump_diffs | awk -F'\t' -v keep="$keep" '
    BEGIN { n = split(keep, k, "\n"); for (i = 1; i <= n; i++) want[k[i]] = 1 }
    want[$1 " " $2] { total += $3 }
    END { print total + 0 }')"
  run_prefetch H6-partial --focus 1 --budget "$budget" --keep-nearest 0
  expect_eq "a partial budget keeps the rows nearest the focus" "$keep" "$(dump_diffs | awk -F'\t' '{ print $1, $2 }' | sort)"

  run_prefetch H6-refill2 --focus 1
  expect_eq "default budget repopulates after the partial eviction" "$before" "$(dump_diffs | wc -l)"
  stop_point H6
}

# Runs right after H6 (same fully cached world), before H7 moves PR 2/4's
# updated_at. --no-threads leaves the thread rows for PRs 11-14 unfetched, as
# H7 expects.
scenario_H10() {
  begin H10
  local before keep budget
  before="$(dump_diffs | wc -l)"
  # Room for the pinned rows plus the rows of the four PRs nearest PR 14.
  keep="$({
    awk '{ print $2, $1 }' "$WORK/pr5-old-key"
    pr_key 1
    pr_key 9
    pr_key 11
    pr_key 12
    pr_key 13
    pr_key 14
  } | sort -u)"
  budget="$(rows_size "$keep")"

  run_prefetch H10-move --focus 1 --then-focus 14 --budget "$budget" --keep-nearest 0 --no-threads
  expect_eq "focus 1 settles idle" idle "$INITIAL_PHASE"
  expect_eq "after the move to PR 14: idle" idle "$STATUS_PHASE"
  expect_eq "after the move to PR 14: no error" none "$STATUS_LAST_ERROR"
  expect_eq "a focus move keeps the rows nearest the new focus" "$keep" "$(dump_diffs | awk -F'\t' '{ print $1, $2 }' | sort)"

  run_prefetch H10-refill --focus 1 --no-threads
  expect_eq "default budget repopulates after the focus-move eviction" "$before" "$(dump_diffs | wc -l)"

  run_prefetch H10-fresh --focus 14 --budget "$budget" --keep-nearest 0 --no-threads
  expect_eq "a fresh worker at PR 14 keeps the rows nearest PR 14" "$keep" "$(dump_diffs | awk -F'\t' '{ print $1, $2 }' | sort)"

  # Churn: the cache is settled around PR 14 for this budget. A new targets
  # version at the same focus may only probe the first row past the eviction
  # boundary (one per view), and a one-position move on top of that may only
  # diff the rows that crossed the boundary.
  local same step
  run_prefetch H10-same --focus 14 --budget "$budget" --keep-nearest 0 --no-threads
  same="$(diff_count "$WORK/trace-H10-same.log")"
  expect_true "same focus, new version: at most 2 git diffs (ran $same)" "[ $same -le 2 ]"
  expect_eq "same focus, new version: rows unchanged" "$keep" "$(dump_diffs | awk -F'\t' '{ print $1, $2 }' | sort)"
  run_prefetch H10-step --focus 14 --then-focus 13 --budget "$budget" --keep-nearest 0 --no-threads
  step=$(($(diff_count "$WORK/trace-H10-step.log") - same))
  expect_true "one-position focus move: at most 2 git diffs past the settle (ran $step)" "[ $step -le 2 ]"

  run_prefetch H10-refill2 --focus 1 --no-threads
  expect_eq "default budget repopulates after the fresh-worker eviction" "$before" "$(dump_diffs | wc -l)"
  stop_point H10
}

scenario_H7() {
  begin H7
  # 1. The H1 snapshot: nearest 10 to PR 1 in display order 1..14 are 1-10.
  expect_eq "H1 cached threads for exactly PRs 1-10" "1 2 3 4 5 6 7 8 9 10" "$(cut -f1 "$WORK/threads-H1.tsv" | tr '\n' ' ' | sed 's/ $//')"
  local n mismatched=""
  for n in $(cut -f1 "$WORK/threads-H1.tsv"); do
    [ "$(awk -F'\t' -v n="$n" '$1 == n { print $2 }' "$WORK/threads-H1.tsv")" = "$(tsv_get_from "$WORK/targets-H1.tsv" "$n" 6)" ] || mismatched+=" $n"
  done
  expect_eq "thread rows carry the TSV updated_at" "" "$mismatched"
  expect_eq "H1 made one gh call per PR 1-10" "1 2 3 4 5 6 7 8 9 10" "$(gh_numbers "$WORK/gh-H1.log")"

  # 2. Bumping PR 4's updated_at refetches PR 4 only.
  local gh_before threads_before
  world_bump_updated_at 4 1
  seed_db
  gh_before="$(wc -l <"$FAKE_GH_LOG")"
  threads_before="$(dump_threads)"
  run_prefetch H7-bump --focus 1
  expect_eq "only PR 4's threads were refetched" "4" "$(gh_numbers_since "$gh_before")"
  expect_eq "PR 4 thread row has the new updated_at" "$(tsv_get 4 updated_at)" "$(dump_threads | awk -F'\t' '$1 == 4 { print $2 }')"
  expect_eq "other thread rows' fetched_at unchanged" \
    "$(awk -F'\t' '$1 != 4 { print $1, $3 }' <<<"$threads_before")" \
    "$(dump_threads | awk -F'\t' '$1 != 4 { print $1, $3 }')"

  # 3. Focus at the far end: nearest 10 to PR 14 are 5-14; 5-10 are fresh.
  gh_before="$(wc -l <"$FAKE_GH_LOG")"
  run_prefetch H7-focus14 --focus 14
  expect_eq "focus 14 fetches threads for exactly PRs 11-14" "11 12 13 14" "$(gh_numbers_since "$gh_before")"

  # 4. gh fails for PR 2: others complete, PR 2 keeps its old row.
  local old_pr2
  old_pr2="$(dump_threads | awk -F'\t' '$1 == 2 { print $2 }')"
  world_bump_updated_at 2 1
  rm -f "$WORK/fixtures/review-2.json"
  seed_db
  gh_before="$(wc -l <"$FAKE_GH_LOG")"
  run_prefetch H7-ghfail --focus 1
  expect_eq "phase is idle after a gh failure" idle "$STATUS_PHASE"
  expect_true "failures >= 1 after a gh failure" "[ ${STATUS_FAILURES:-0} -ge 1 ]"
  expect_eq "gh was asked for PR 2 only" "2" "$(gh_numbers_since "$gh_before")"
  expect_eq "PR 2 keeps its old thread row" "$old_pr2" "$(dump_threads | awk -F'\t' '$1 == 2 { print $2 }')"
  stop_point H7
}

scenario_H8() {
  begin H8
  local before head15
  before="$(dump_diffs | cut -f1,2,3,5)"
  git -C "$CLONE" remote set-url origin "$WORK/nope.git"
  world_add_pr15 || fail "add PR 15"
  head15="$(tsv_get 15 head_oid)"
  seed_db
  run_prefetch H8 --focus 1
  expect_eq "exactly one git fetch (no per-refspec fan-out)" 1 "$(trace_lines "$WORK/trace-H8.log" fetch | wc -l)"
  expect_eq "last_error is fetch_failed" fetch_failed "$STATUS_LAST_ERROR"
  expect_eq "phase is idle" idle "$STATUS_PHASE"
  expect_eq "existing diff_cache rows untouched" "$before" "$(dump_diffs | cut -f1,2,3,5)"
  expect_eq "PR 15 has no diff_cache row" "" "$(rows_for_head "$head15")"
  git -C "$CLONE" remote set-url origin "$WORK/origin.git"
  stop_point H8
}

scenario_H9() {
  begin H9
  # A separate DB and target list over the same origin and clone.
  local DB="$WORK/prs-cap.db" TARGETS="$WORK/targets-cap.tsv" REPO_ID n
  world_add_cap_prs || abort "building the 130 cap PRs failed"
  for n in $(tsv_numbers); do write_review_fixture "$n" || abort "fixture $n"; done
  seed_db
  run_prefetch H9 --focus 201 --then-focus 330 --timeout-ms 120000

  expect_eq "first settle is idle" idle "$INITIAL_PHASE"
  expect_eq "first settle: the 100 PRs inside the fetch cap are ready" 100 "$INITIAL_READY"
  expect_eq "first settle: no failures for the 30 PRs past the cap" 0 "$INITIAL_FAILURES"
  expect_eq "first settle: no error" none "$INITIAL_LAST_ERROR"
  expect_eq "after the focus move to PR 330: all 130 ready" 130 "$STATUS_READY"
  expect_eq "after the focus move: no failures" 0 "$STATUS_FAILURES"
  expect_eq "after the focus move: no error" none "$STATUS_LAST_ERROR"

  local fetches
  fetches="$(trace_lines "$WORK/trace-H9.log" fetch)"
  expect_eq "two fetch batches in one targets version" 2 "$(grep -c . <<<"$fetches")"
  expect_eq "first batch asks for 100 heads" 100 "$(refspec_count "$(sed -n 1p <<<"$fetches")")"
  expect_eq "second batch asks for the 30 heads past the first cap" 30 "$(refspec_count "$(sed -n 2p <<<"$fetches")")"
  expect_eq "130 diff rows cached" 130 "$(dump_diffs | wc -l)"
  stop_point H9
}

# A git (then a gh) that never answers: the child timeout kills its whole
# process group, the worker records the failure and still goes idle.
scenario_H11() {
  begin H11
  local DB="$WORK/prs-hang.db" CLONE="$WORK/clone-hang" REPO_ID started elapsed
  local git_pid_file="$WORK/hang-git.pid" gh_pid_file="$WORK/hang-gh.pid" deaf_pid_file="$WORK/hang-gh-deaf.pid"
  write_hang_script "$WORK/bin/hang-git" "$git_pid_file" fetch
  write_hang_script "$WORK/bin/hang-gh" "$gh_pid_file" ""
  write_hang_script "$WORK/bin/hang-gh-deaf" "$deaf_pid_file" "" ignore-term
  pgit clone -q --no-local --single-branch --branch main "$WORK/origin.git" "$CLONE" 2>/dev/null || abort "clone for H11 failed"
  seed_db

  started=$SECONDS
  run_prefetch H11-git --focus 1 --no-threads --git-bin "$WORK/bin/hang-git" --git-timeout-ms 1000
  elapsed=$((SECONDS - started))
  expect_eq "hung git: last_error is fetch_failed" fetch_failed "$STATUS_LAST_ERROR"
  expect_eq "hung git: phase is idle" idle "$STATUS_PHASE"
  expect_true "hung git: run finished well before the 300s hang (${elapsed}s)" "[ $elapsed -lt 20 ]"
  expect_true "hung git: its background grandchild was killed" "pid_gone '$git_pid_file'"

  # The main clone has every commit, so only the thread jobs reach a child.
  CLONE="$WORK/clone"
  DB="$WORK/prs-hang-gh.db"
  seed_db
  started=$SECONDS
  run_prefetch H11-gh --focus 1 --gh-bin "$WORK/bin/hang-gh" --git-timeout-ms 1000
  elapsed=$((SECONDS - started))
  expect_eq "hung gh: last_error is gh_failed" gh_failed "$STATUS_LAST_ERROR"
  expect_eq "hung gh: phase is idle" idle "$STATUS_PHASE"
  expect_true "hung gh: run finished well before the 300s hang (${elapsed}s)" "[ $elapsed -lt 20 ]"
  expect_true "hung gh: its background grandchild was killed" "pid_gone '$gh_pid_file'"

  # The same gh with SIGTERM ignored by it and its grandchild: only the
  # SIGKILL after the grace period ends them.
  DB="$WORK/prs-hang-gh-deaf.db"
  seed_db
  started=$SECONDS
  run_prefetch H11-gh-deaf --focus 1 --gh-bin "$WORK/bin/hang-gh-deaf" --git-timeout-ms 1000
  elapsed=$((SECONDS - started))
  expect_eq "TERM-deaf gh: last_error is gh_failed" gh_failed "$STATUS_LAST_ERROR"
  expect_eq "TERM-deaf gh: phase is idle" idle "$STATUS_PHASE"
  expect_true "TERM-deaf gh: run finished well before the 300s hang (${elapsed}s)" "[ $elapsed -lt 20 ]"
  expect_true "TERM-deaf gh: its background grandchild was killed" "pid_gone '$deaf_pid_file'"
  stop_point H11
}

# Eviction after focus jumps: one worker that moves its cursor within a
# targets version must end with the rows a fresh worker at the final focus
# would cache. Rows of mixed sizes (H12-mixed) and a long walk over same-size
# rows (H12-walk, H9's 130 PRs) both used to strand evicted rows.
scenario_H12() {
  begin H12
  local TARGETS="$WORK/targets-mixed.tsv" DB="$WORK/prs-mixed-full.db" REPO_ID small large size
  world_add_mixed_prs || abort "building the 40 mixed PRs failed"
  seed_db
  run_prefetch H12-sizes --focus 401 --no-threads
  small="$(dump_diffs | awk -F'\t' '$3 < 1000 { print $3 }' | sort -n | tail -1)"
  large="$(dump_diffs | awk -F'\t' '$3 >= 1000 { print $3 }' | sort -n | tail -1)"
  expect_true "mixed world: one large diff outweighs all 30 small ones (${large}B vs 30x${small}B)" "[ $large -gt $((30 * small)) ]"
  # Three large rows and two small ones at the large end; at the small end,
  # every small row and two large ones.
  expect_same_survivors H12-mixed $((3 * large + 2 * small)) 401 --focus 440
  expect_eq "H12-mixed: exactly PRs 401-432 survive at 401" \
    "$(for n in $(seq 401 432); do tsv_get "$n" head_oid; done | sort)" \
    "$(DB="$WORK/prs-H12-mixed-moved.db" dump_diffs | cut -f2 | sort)"
  # The default keep_nearest pins the ten large rows at 440 past the budget;
  # the move to 401 must still unpin and evict them.
  KEEP_NEAREST=10 expect_same_survivors H12-mixed-keep $((3 * large + 2 * small)) 401 --focus 440
  expect_same_survivors H12-mixed-trip $((3 * large + 2 * small)) 401 --focus 401 --then-focus 440

  TARGETS="$WORK/targets-cap.tsv"
  DB="$WORK/prs-cap.db"
  seed_db
  size="$(dump_diffs | awk -F'\t' 'NR == 1 { print $3 }')"
  expect_same_survivors H12-walk $((50 * size + size / 2)) 201 --focus 201 --then-focus 330 --timeout-ms 120000
  stop_point H12
}

# A repository gh cannot resolve fails every thread job the same way: one gh
# call disables thread jobs for the rest of that targets version.
scenario_H13() {
  begin H13
  local DB="$WORK/prs-norepo.db" REPO_ID gh_log="$WORK/gh-norepo.log"
  cat >"$WORK/bin/gh-norepo" <<SCRIPT
#!/usr/bin/env bash
echo call >>"$gh_log"
echo "GraphQL: Could not resolve to a Repository with the name '$REPO_OWNER/$REPO_NAME'. (repository)" >&2
exit 1
SCRIPT
  chmod +x "$WORK/bin/gh-norepo"
  seed_db
  run_prefetch H13 --focus 1 --gh-bin "$WORK/bin/gh-norepo"
  expect_eq "unresolvable repository: one gh call for the targets version" 1 "$(wc -l <"$gh_log")"
  expect_eq "unresolvable repository: last_error is gh_failed" gh_failed "$STATUS_LAST_ERROR"
  expect_eq "unresolvable repository: phase is idle" idle "$STATUS_PHASE"
  run_prefetch H13-again --focus 1 --gh-bin "$WORK/bin/gh-norepo"
  expect_eq "unresolvable repository: one more gh call for the next targets version" 2 "$(wc -l <"$gh_log")"
  stop_point H13
}

# Another skim process sharing the DB deletes this worker's diff rows while
# it idles. The focus moves that follow must re-check the rows it believes
# are cached: at the final focus the rows and the ready count equal a fresh
# worker's, not a stale count over whatever the moves happened to rewrite.
scenario_H14() {
  begin H14
  local TARGETS="$WORK/targets-cap.tsv" DB="$WORK/prs-cap.db" REPO_ID size
  seed_db
  size="$(dump_diffs | awk -F'\t' 'NR == 1 { print $3 }')"
  expect_same_survivors H14 $((50 * size + size / 2)) 259 --focus 260 --wipe-diffs --then-focus 330 --timeout-ms 120000
  stop_point H14
}

# stop() while a git or gh child is in flight: the run returns long before the
# 300s hang and leaves no grandchild behind. stop() only SIGTERMs the group;
# for a child that ignores SIGTERM the worker escalates to SIGKILL, so stop
# itself still returns at once.
scenario_H15() {
  begin H15
  local DB="$WORK/prs-stop-git.db" CLONE="$WORK/clone-stop" REPO_ID
  local git_pid_file="$WORK/stop-git.pid" gh_pid_file="$WORK/stop-gh.pid" deaf_pid_file="$WORK/stop-gh-deaf.pid"
  write_hang_script "$WORK/bin/stop-git" "$git_pid_file" fetch
  write_hang_script "$WORK/bin/stop-gh" "$gh_pid_file" ""
  write_hang_script "$WORK/bin/stop-gh-deaf" "$deaf_pid_file" "" ignore-term
  pgit clone -q --no-local --single-branch --branch main "$WORK/origin.git" "$CLONE" 2>/dev/null || abort "clone for H15 failed"
  seed_db

  stop_prefetch H15-git 1500 --focus 1 --no-threads --git-bin "$WORK/bin/stop-git"
  expect_true "stop mid-fetch: the hung git was in flight" "[ -s '$git_pid_file' ]"
  expect_true "stop mid-fetch: stop returned in ${STOP_MS}ms" "[ -n '$STOP_MS' ] && [ '$STOP_MS' -lt 1000 ]"
  expect_true "stop mid-fetch: run finished well before the 300s hang (${ELAPSED_S}s)" "[ $ELAPSED_S -lt 20 ]"
  expect_true "stop mid-fetch: its background grandchild was killed" "pid_gone '$git_pid_file'"

  # The main clone has every commit, so only the thread jobs reach a child.
  CLONE="$WORK/clone"
  DB="$WORK/prs-stop-gh.db"
  seed_db
  stop_prefetch H15-gh 1500 --focus 1 --gh-bin "$WORK/bin/stop-gh"
  expect_true "stop mid-gh: the hung gh was in flight" "[ -s '$gh_pid_file' ]"
  expect_true "stop mid-gh: stop returned in ${STOP_MS}ms" "[ -n '$STOP_MS' ] && [ '$STOP_MS' -lt 1000 ]"
  expect_true "stop mid-gh: run finished well before the 300s hang (${ELAPSED_S}s)" "[ $ELAPSED_S -lt 20 ]"
  expect_true "stop mid-gh: its background grandchild was killed" "pid_gone '$gh_pid_file'"

  DB="$WORK/prs-stop-gh-deaf.db"
  seed_db
  stop_prefetch H15-gh-deaf 1500 --focus 1 --gh-bin "$WORK/bin/stop-gh-deaf"
  expect_true "stop mid-gh, TERM-deaf: the hung gh was in flight" "[ -s '$deaf_pid_file' ]"
  expect_true "stop mid-gh, TERM-deaf: stop returned in ${STOP_MS}ms" "[ -n '$STOP_MS' ] && [ '$STOP_MS' -lt 1000 ]"
  expect_true "stop mid-gh, TERM-deaf: run finished well before the 300s hang (${ELAPSED_S}s)" "[ $ELAPSED_S -lt 20 ]"
  expect_true "stop mid-gh, TERM-deaf: its background grandchild was killed" "pid_gone '$deaf_pid_file'"
  stop_point H15
}

# =============================================================================
# Harness driving
# =============================================================================

harness() {
  "$HARNESS_BIN" "$@"
}

seed_db() {
  REPO_ID="$(harness seed --db "$DB" --repo-key "$REPO_KEY" --owner "$REPO_OWNER" --name "$REPO_NAME" --targets "$(targets_tsv)")" ||
    abort "seed failed"
}

# run_prefetch <label> [flags...]: one worker run with GIT_TRACE captured to
# trace-<label>.log and stderr to harness-<label>.err. Sets STATUS_*.
run_prefetch() {
  local label="$1" code
  shift
  rm -f "$WORK/trace-$label.log"
  GIT_TRACE="$WORK/trace-$label.log" harness run --db "$DB" --repo-id "$REPO_ID" --repo-root "$CLONE" \
    --owner "$REPO_OWNER" --name "$REPO_NAME" --targets "$(targets_tsv)" --gh-bin "$WORK/bin/gh" "$@" \
    >"$WORK/run-$label.out" 2>"$WORK/harness-$label.err"
  code=$?
  if [ "$code" = 3 ]; then
    fail "harness_prefetch run is not implemented yet (see $WORK/harness-$label.err)"
    abort "cannot continue without the worker"
  fi
  [ "$code" = 2 ] && fail "run $label timed out (see $WORK/harness-$label.err)"
  [ "$code" != 0 ] && [ "$code" != 2 ] && fail "run $label exited $code (see $WORK/harness-$label.err)"
  IFS=$'\t' read -r _ STATUS_PHASE STATUS_READY STATUS_FAILURES STATUS_LAST_ERROR < <(grep '^status' "$WORK/run-$label.out")
  # Only with --then-focus: the settle before the focus move.
  IFS=$'\t' read -r _ INITIAL_PHASE INITIAL_READY INITIAL_FAILURES INITIAL_LAST_ERROR < <(grep '^initial' "$WORK/run-$label.out")
  GENERATION="$(awk -F'\t' '$1 == "generation" { print $2 }' "$WORK/run-$label.out")"
}

# stop_prefetch <label> <stop-after-ms> [flags...]: one worker run that is
# stopped <stop-after-ms> after it starts. Sets STOP_MS (how long stop took)
# and ELAPSED_S (the whole run).
stop_prefetch() {
  local label="$1" after="$2" code started
  shift 2
  started=$SECONDS
  harness run --db "$DB" --repo-id "$REPO_ID" --repo-root "$CLONE" \
    --owner "$REPO_OWNER" --name "$REPO_NAME" --targets "$(targets_tsv)" --gh-bin "$WORK/bin/gh" \
    --stop-after-ms "$after" "$@" >"$WORK/run-$label.out" 2>"$WORK/harness-$label.err"
  code=$?
  ELAPSED_S=$((SECONDS - started))
  [ "$code" != 0 ] && fail "run $label exited $code (see $WORK/harness-$label.err)"
  STOP_MS="$(awk -F'\t' '$1 == "stopped" { print $2 }' "$WORK/run-$label.out")"
}

dump_diffs() {
  harness dump-diffs --db "$DB" --repo-id "$REPO_ID"
}

dump_threads() {
  harness dump-threads --db "$DB" --repo-id "$REPO_ID"
}

# dump_key <base_tip> <head> → merge base oid or "none"
dump_key() {
  harness dump-key --db "$DB" --repo-id "$REPO_ID" --base-tip "$1" --head "$2"
}

# diff_files <merge_base> <head> → files touched by the cached diff
diff_files() {
  harness dump-diff --db "$DB" --repo-id "$REPO_ID" --merge-base "$1" --head "$2" 2>/dev/null |
    awk '/^diff --git / { sub("^b/", "", $4); print $4 }'
}

# pr_key <number> -> "merge_base head" of the PR's own diff row
pr_key() {
  local tip head
  tip="$(harness plan-targets --db "$DB" --repo-id "$REPO_ID" --targets "$(targets_tsv)" | awk -F'\t' -v n="$1" '$1 == n { print $5 }')"
  head="$(tsv_get "$1" head_oid)"
  echo "$(dump_key "$tip" "$head") $head"
}

# rows_size <"mb head" lines> -> total size of those diff_cache rows
rows_size() {
  dump_diffs | awk -F'\t' -v keep="$1" '
    BEGIN { n = split(keep, k, "\n"); for (i = 1; i <= n; i++) want[k[i]] = 1 }
    want[$1 " " $2] { total += $3 }
    END { print total + 0 }'
}

# write_hang_script <path> <pid-file> <git-subcommand> [ignore-term]: a
# stand-in that, for <git-subcommand> (or for every call when it is empty),
# starts a 300s background sleep, records its pid and waits on it; anything
# else runs real git. With ignore-term the script and the sleep it starts
# ignore SIGTERM.
write_hang_script() {
  local trap_line=""
  [ "${4:-}" = ignore-term ] && trap_line="trap '' TERM"
  cat >"$1" <<SCRIPT
#!/usr/bin/env bash
$trap_line
hang() { sleep 300 & echo \$! >"$2"; wait; exit 1; }
[ -z "$3" ] && hang
for arg; do [ "\$arg" = "$3" ] && hang; done
exec git "\$@"
SCRIPT
  chmod +x "$1"
}

# pid_gone <pid-file>: the recorded process no longer exists (polls 2s).
pid_gone() {
  local pid i
  pid="$(cat "$1" 2>/dev/null)" || return 1
  [ -n "$pid" ] || return 1
  for i in $(seq 20); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}

# expect_same_survivors <label> <budget> <final-focus> <focus flags...>: a
# worker on a fresh DB settles at each focus the flags give, ending at
# <final-focus>; its diff rows and diffs_ready must equal those of a fresh
# worker that only ever saw <final-focus>. KEEP_NEAREST (default 0) sets
# --keep-nearest for both runs.
expect_same_survivors() {
  local label="$1" budget="$2" final="$3" moved moved_ready fresh
  shift 3
  DB="$WORK/prs-$label-moved.db"
  seed_db
  run_prefetch "$label-moved" "$@" --then-focus "$final" --budget "$budget" --keep-nearest "${KEEP_NEAREST:-0}" --no-threads
  expect_eq "$label: settles idle at $final" idle "$STATUS_PHASE"
  moved_ready="$STATUS_READY"
  moved="$(dump_diffs | awk -F'\t' '{ print $1, $2 }' | sort)"
  DB="$WORK/prs-$label-fresh.db"
  seed_db
  run_prefetch "$label-fresh" --focus "$final" --budget "$budget" --keep-nearest "${KEEP_NEAREST:-0}" --no-threads --timeout-ms 120000
  fresh="$(dump_diffs | awk -F'\t' '{ print $1, $2 }' | sort)"
  expect_true "$label: the fresh worker cached something" "[ -n '$fresh' ]"
  expect_eq "$label: diffs_ready after the moves equals a fresh worker's" "$STATUS_READY" "$moved_ready"
  expect_eq "$label: rows after the moves equal a fresh worker's at $final ($(grep -c . <<<"$fresh") rows, $(diff_count "$WORK/trace-$label-moved.log") git diffs)" "$fresh" "$moved"
}

rows_for_head() {
  dump_diffs | awk -F'\t' -v h="$1" '$2 == h'
}

# The PR's cached diff is byte-identical to what the miss path renders:
# `git diff --no-color --no-ext-diff -U10 <base>...refs/skim/pr-N`.
expect_cached_diff() {
  local n="$1" tip head mb
  tip="$(harness plan-targets --db "$DB" --repo-id "$REPO_ID" --targets "$(targets_tsv)" | awk -F'\t' -v n="$n" '$1 == n { print $5 }')"
  head="$(tsv_get "$n" head_oid)"
  mb="$(dump_key "$tip" "$head")"
  if [ "$mb" = none ]; then
    fail "PR $n: no merge_base_cache row for ($tip, $head)"
    return
  fi
  expect_eq "PR $n: refs/skim/pr-$n is the TSV head" "$head" "$(git -C "$CLONE" rev-parse -q --verify "refs/skim/pr-$n")"
  git -C "$CLONE" diff --no-color --no-ext-diff -U10 "$tip...refs/skim/pr-$n" >"$WORK/expected-$n.diff" 2>"$WORK/expected-$n.err"
  if ! harness dump-diff --db "$DB" --repo-id "$REPO_ID" --merge-base "$mb" --head "$head" >"$WORK/actual-$n.diff" 2>/dev/null; then
    fail "PR $n: no diff_cache row for ($mb, $head)"
    return
  fi
  if cmp -s "$WORK/expected-$n.diff" "$WORK/actual-$n.diff"; then
    pass "PR $n: cached diff == git diff $tip...refs/skim/pr-$n"
  else
    fail "PR $n: cached diff differs from the miss path (expected-$n.diff vs actual-$n.diff)"
  fi
}

# =============================================================================
# Trace and log parsing
# =============================================================================

# trace_lines <file> <subcommand>: argv of each `git <subcommand>` the worker ran.
trace_lines() {
  grep "trace: built-in: git $2 " "$1" 2>/dev/null | sed 's/.*trace: built-in: //'
}

# diff_count <trace file>: how many `git diff` the worker ran.
diff_count() {
  grep -c "trace: built-in: git diff " "$1" 2>/dev/null
}

# trace_line_no <file> <subcommand>: line number of the first such command.
trace_line_no() {
  grep -n "trace: built-in: git $2 " "$1" 2>/dev/null | head -1 | cut -d: -f1
}

refspec_count() {
  grep -o ' +refs/' <<<"$1" | wc -l
}

gh_numbers() {
  grep -o 'number=[0-9]*' "$1" | cut -d= -f2 | sort -n | tr '\n' ' ' | sed 's/ $//'
}

gh_numbers_since() {
  tail -n +"$(($1 + 1))" "$FAKE_GH_LOG" | grep -o 'number=[0-9]*' | cut -d= -f2 | sort -n | tr '\n' ' ' | sed 's/ $//'
}

tsv_get_from() {
  awk -F'\t' -v n="$2" -v c="$3" '!/^#/ && $1 == n { print $c; exit }' "$1"
}

# =============================================================================
# Assertions
# =============================================================================

begin() {
  SCENARIO="$1"
}

pass() {
  echo "PASS $SCENARIO: $1"
}

fail() {
  echo "FAIL $SCENARIO: $1"
  FAILS=$((FAILS + 1))
}

# expect_eq <description> <expected> <actual>
expect_eq() {
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1 (expected '$2', got '$3')"
  fi
}

# expect_true <description> <shell expression>
expect_true() {
  if eval "$2"; then pass "$1"; else fail "$1"; fi
}

stop_point() {
  [ "${STOP_AFTER:-}" = "$1" ] && finish
}

abort() {
  echo "ABORT $SCENARIO: $1"
  FAILS=$((FAILS + 1))
  finish
}

finish() {
  echo
  echo "WORK=$WORK"
  if ((FAILS > 0)); then
    echo "$FAILS assertion(s) failed; world kept at $WORK"
    exit 1
  fi
  echo "all assertions passed"
  exit 0
}

main
