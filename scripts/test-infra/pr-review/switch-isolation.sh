#!/bin/bash
# End-to-end harness: switching the reviewed PR (A -> B) never lets A's review
# data, in-flight work, queued writes or view state reach B (Phase 1 of the
# pr-review-sidebar plan, FR-1 / AD-7).
#
# Drives the REAL zig-out/bin/skim in tmux against a disposable, fully offline
# world (offline/world-lib.sh): a bare "origin" with refs/pull/{1,2}/head, a
# clone whose fake GitHub remote is redirected to it with insteadOf, and a fake
# gh (offline/fake-gh) first on PATH that logs every call to gh.log.
#
# Usage:
#   zig build
#   bash scripts/test-infra/pr-review/switch-isolation.sh [scenario...] 2>&1 | tee /tmp/p1-harness.log
#
#   Scenarios (default: all): latest-wins latest-wins-miss gh-fail-on-switch queued-post-binding
#   queued-post-after-failed-create rapid-switch-stress view-state-reset
#   stale-post-failure non-pr-comments-restored failed-entry-keeps-comments
#   leave-during-entry post-on-both leave-while-post-drains
#
#   SKIM=/path/to/skim   override the binary (default: <repo>/zig-out/bin/skim)
#   KEEP_WORK=1          keep the work dir even when everything passes
#
# Output: one line per scenario: PASS <name> / FAIL <name>: <reason> /
# SKIP <name>: <reason>. Exit 1 if any FAIL. On FAIL the last pane capture,
# gh.log and skim's stderr go to <work>/fail-<name>.txt and the work dir is kept.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=offline/world-lib.sh
. "$HERE/offline/world-lib.sh"

# Status line while the inline comment editor is open (local or GitHub target).
EDITOR_RE='^-- [A-Z]+ \(comment\) --'

ALL_SCENARIOS=(
  latest-wins
  latest-wins-miss
  gh-fail-on-switch
  queued-post-binding
  queued-post-after-failed-create
  rapid-switch-stress
  view-state-reset
  stale-post-failure
  non-pr-comments-restored
  failed-entry-keeps-comments
  leave-during-entry
  post-on-both
  leave-while-post-drains
)

main() {
  local scenarios=("$@")
  ((${#scenarios[@]} == 0)) && scenarios=("${ALL_SCENARIOS[@]}")

  if ! command -v tmux >/dev/null 2>&1; then
    for s in "${scenarios[@]}"; do echo "SKIP $s: tmux not in PATH"; done
    exit 0
  fi
  command -v git >/dev/null 2>&1 || { echo "FAIL setup: git not in PATH"; exit 1; }
  [ -x "$SKIM" ] || { echo "FAIL setup: $SKIM not found (run 'zig build' first)"; exit 1; }

  ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skim-switch-isolation.XXXXXX")"
  ANY_FAIL=0
  trap cleanup EXIT

  for s in "${scenarios[@]}"; do
    run_scenario "$s"
  done

  ((ANY_FAIL)) && exit 1
  exit 0
}

# =============================================================================
# Scenarios
# =============================================================================

# Risk 1: Enter A, j, Enter B while A's gh is still sleeping -> B wins.
scenario_latest_wins() {
  fake_gh_set FAKE_GH_DELAY_1 4
  skim_start pr
  wait_for_pane "Alpha change" 10 || { REASON="sidebar never showed PRs"; return 1; }
  # Both heads are local, so prefetch caches both diffs: wait for the ◆ glyphs
  # so A's entry is deterministically a hit whose thread fetch is the slow part.
  wait_for_pane "#1 Alpha change.*◆" 10 || { REASON="prefetch never cached PR 1"; return 1; }
  wait_for_pane "#2 Bravo change.*◆" 10 || { REASON="prefetch never cached PR 2"; return 1; }
  send Enter
  wait_for_log '^review.*number=1' 1 5 || { REASON="no gh review call for PR 1"; return 1; }
  wait_for_pane "a_only.txt" 5 || { REASON="A's cached diff (a_only.txt) never appeared"; return 1; }
  send Tab
  wait_for_pane "-- PRS --" 3 || { REASON="Tab did not return focus to the PR list: $(status_line)"; return 1; }
  send j
  sleep 0.2
  send Enter
  wait_for_pane "b_only.txt" 10 || { REASON="B's diff (b_only.txt) never appeared"; return 1; }
  # A's fake gh sleeps 4s; wait past it so a late A result would have landed.
  sleep 5
  pane_has "b_only.txt" || { REASON="B's diff was replaced after A's late result"; return 1; }
  pane_has "a_only.txt" && { REASON="A's diff (a_only.txt) is on screen"; return 1; }
  pane_has "ALPHA-THREAD-MARKER" && { REASON="A's thread is on screen"; return 1; }
  status_line | grep -q "PR #2" || { REASON="status line does not name PR #2: $(status_line)"; return 1; }
  return 0
}

# Risk 1 (miss path): neither head is local and the prefetch worker's fetches
# are refused, so both entries fetch. B's Enter while A's gh sleeps parks B
# behind A's entry; A's late result is discarded and B's entry runs after it.
scenario_latest_wins_miss() {
  drop_local_pr_heads
  block_prefetch_fetches
  fake_gh_set FAKE_GH_DELAY_1 6
  skim_start pr
  wait_for_pane "Alpha change" 10 || { REASON="sidebar never showed PRs"; return 1; }
  # A miss entry fetches A's threads before its diff streams in, so the list
  # keeps focus while it is in flight. The two number=1 calls are the boot
  # row's entry and the prefetch worker's thread fetch; the worker fetches
  # PR 2's threads only after its (equally slow) PR 1 call, so until then
  # any number=2 call is B's entry.
  wait_for_log '^review.*number=1' 2 10 || { REASON="no gh review calls for PR 1"; return 1; }
  assert_prefetch_blocked || return 1
  send Enter
  sleep 0.2
  in_sidebar || { REASON="Enter on PR 1 left the list before its entry landed: $(status_line)"; return 1; }
  send j
  sleep 0.2
  send Enter
  sleep 1
  (($(log_count '^review.*number=2') == 0)) || { REASON="PR 2's entry ran while PR 1's was in flight (not parked)"; return 1; }
  in_sidebar || { REASON="the list lost focus while B's entry was parked: $(status_line)"; return 1; }
  wait_for_log '^review.*number=2' 2 15 || { REASON="PR 2's parked entry never ran"; return 1; }
  wait_for_pane "b_only.txt" 10 || { REASON="B's diff (b_only.txt) never appeared"; return 1; }
  sleep 1
  pane_has "b_only.txt" || { REASON="B's diff was replaced after A's late result"; return 1; }
  pane_has "a_only.txt" && { REASON="A's diff (a_only.txt) is on screen"; return 1; }
  pane_has "ALPHA-THREAD-MARKER" && { REASON="A's thread is on screen"; return 1; }
  status_line | grep -q "PR #2" || { REASON="status line does not name PR #2: $(status_line)"; return 1; }
  return 0
}

# Risk 2: B's gh fails -> B's diff, none of A's threads/number.
scenario_gh_fail_on_switch() {
  fake_gh_set FAKE_GH_FAIL_2 1
  skim_start pr
  wait_for_pane "Alpha change" 10 || { REASON="sidebar never showed PRs"; return 1; }
  send Enter
  wait_for_pane "ALPHA-THREAD-MARKER" 10 || { REASON="A's thread never rendered"; return 1; }
  open_sidebar || { REASON="could not reopen the PR sidebar via the palette"; return 1; }
  send j
  sleep 0.2
  send Enter
  wait_for_pane "b_only.txt" 10 || { REASON="B's diff (b_only.txt) never appeared"; return 1; }
  wait_for_log '^review.*number=2' 1 5 || { REASON="no gh review call for PR 2"; return 1; }
  sleep 1
  # The PR sidebar lists A's title by design and stays open; check only the
  # diff columns to its right.
  pane_has "Alpha change" || { REASON="the PR sidebar is no longer showing the list"; return 1; }
  diff_pane_has "ALPHA-THREAD-MARKER" && { REASON="A's thread is shown on B"; return 1; }
  diff_pane_has "Alpha change" && { REASON="A's title is shown on B"; return 1; }
  status_line | grep -q "PR #1" && { REASON="status line still names PR #1: $(status_line)"; return 1; }
  return 0
}

# Risk 3: a post queued on A drains after the switch and is sent with A's ids.
scenario_queued_post_binding() {
  fake_gh_set FAKE_GH_DELAY_CREATE 6
  skim_start pr
  wait_for_pane "Alpha change" 10 || { REASON="sidebar never showed PRs"; return 1; }
  send Enter
  wait_for_pane "ALPHA-ANCHOR-010" 10 || { REASON="A's diff never rendered"; return 1; }
  comment_on "ALPHA-ANCHOR-010" "QUEUED-FIRST" || { REASON="could not post the first comment"; return 1; }
  comment_on "ALPHA-ANCHOR-020" "QUEUED-SECOND" || { REASON="could not queue the second comment"; return 1; }
  switch_to_pr2 || return 1
  wait_for_log '^thread' 2 15 || { REASON="expected 2 addPullRequestReviewThread calls, got $(log_count '^thread')"; return 1; }
  sleep 1
  assert_all_writes_on_a || return 1
  (($(log_count '^create') == 1)) || { REASON="expected exactly 1 pending-review create, got $(log_count '^create')"; return 1; }
  assert_b_clean_of_a_drafts || return 1
  return 0
}

# Risk 3 (variant): A's first create fails, so the queued post has no review
# id and must create one itself — on PR_A, not on the PR now showing.
scenario_queued_post_after_failed_create() {
  fake_gh_set FAKE_GH_DELAY_CREATE 6
  fake_gh_set FAKE_GH_FAIL_CREATE 1
  skim_start pr
  wait_for_pane "Alpha change" 10 || { REASON="sidebar never showed PRs"; return 1; }
  send Enter
  wait_for_pane "ALPHA-ANCHOR-010" 10 || { REASON="A's diff never rendered"; return 1; }
  comment_on "ALPHA-ANCHOR-010" "QUEUED-FIRST" || { REASON="could not post the first comment"; return 1; }
  wait_for_log '^create' 1 5 || { REASON="first create never called"; return 1; }
  fake_gh_set FAKE_GH_FAIL_CREATE 0
  comment_on "ALPHA-ANCHOR-020" "QUEUED-SECOND" || { REASON="could not queue the second comment"; return 1; }
  switch_to_pr2 || return 1
  wait_for_log '^create' 2 15 || { REASON="queued post never created its own pending review (creates: $(log_count '^create'))"; return 1; }
  wait_for_log '^thread' 1 10 || { REASON="queued post never sent its thread"; return 1; }
  sleep 1
  assert_all_writes_on_a || return 1
  assert_b_clean_of_a_drafts || return 1
  return 0
}

# Risk 4: rapid A/B switching while highlighting is busy -> no crash, final
# screen matches the last Enter.
scenario_rapid_switch_stress() {
  fake_gh_set FAKE_GH_DELAY_1 1
  fake_gh_set FAKE_GH_DELAY_2 1
  skim_start pr
  wait_for_pane "Alpha change" 10 || { REASON="sidebar never showed PRs"; return 1; }
  local i
  for ((i = 0; i < 10; i++)); do
    # A late entry can flip the UI to the diff at any moment, so a key meant
    # for the sidebar may land in normal mode and open the comment editor.
    dismiss_editor
    in_sidebar || open_sidebar || { REASON="iteration $i: could not reopen the sidebar"; return 1; }
    send Enter
    sleep 0.1
    if ((i % 2 == 0)); then send j; else send k; fi
    sleep 0.05
    send Enter
    if ((i % 3 == 0)) && wait_for_pane "PR #[12]( |$)" 4; then
      dismiss_editor
      send C-d
      sleep 0.1
      send C-d
    fi
    sleep 0.$((RANDOM % 8))
    skim_alive || { REASON="skim exited during iteration $i"; return 1; }
  done

  # Final switch: whatever is still in flight, this Enter must win.
  local target="" attempt
  for ((attempt = 0; attempt < 5; attempt++)); do
    dismiss_editor
    in_sidebar || open_sidebar || continue
    send j
    sleep 0.15
    target="$(sidebar_selected_number)"
    send Enter
    sleep 0.3
    pane_has "$EDITOR_RE" || break
    target=""
  done
  [ -n "$target" ] || { REASON="could not issue the final sidebar Enter"; return 1; }

  local mine theirs
  if [ "$target" = "1" ]; then mine=a_only.txt theirs=b_only.txt; else mine=b_only.txt theirs=a_only.txt; fi
  # A cache hit's diff source names the head oid, not refs/skim/pr-N, so the
  # status line's PR number identifies the PR.
  wait_for_pane "PR #$target( |$)" 15 || { REASON="final screen never showed PR #$target (last Enter): $(status_line)"; return 1; }
  # Outlast every earlier switch's fake-gh delay.
  sleep 3
  skim_alive || { REASON="skim exited after the switches"; return 1; }
  stderr_has_crash && { REASON="crash text in stderr.log"; return 1; }
  status_line | grep -qE "PR #$target( |$)" || { REASON="screen moved off PR #$target after the last Enter: $(status_line)"; return 1; }
  send g g
  sleep 0.5
  pane_has "$mine" || { REASON="PR #$target's diff ($mine) not shown"; return 1; }
  pane_has "$theirs" && { REASON="the other PR's file ($theirs) shown on PR #$target"; return 1; }
  return 0
}

# Risk 5: folds and search on A do not follow the switch.
scenario_view_state_reset() {
  skim_start pr
  wait_for_pane "Alpha change" 10 || { REASON="sidebar never showed PRs"; return 1; }
  send Enter
  wait_for_pane "ALPHA-ANCHOR-010" 10 || { REASON="A's diff never rendered"; return 1; }
  search_for "ALPHA-ANCHOR"
  wait_for_pane "matches\]" 3 || { REASON="search on A did not register"; return 1; }
  # zC: fold the file under the cursor (a_only.txt, file 0).
  send z C
  wait_for_pane "▶ a_only.txt" 3 || { REASON="zC did not fold a_only.txt (fold key path changed?)"; return 1; }
  open_sidebar || { REASON="could not reopen the PR sidebar via the palette"; return 1; }
  send j
  sleep 0.2
  send Enter
  wait_for_pane "b_only.txt" 10 || { REASON="B's diff never appeared"; return 1; }
  sleep 1
  pane_has "▶ b_only.txt" && { REASON="B's first file is folded (A's fold followed the switch)"; return 1; }
  pane_has "▼ b_only.txt" || { REASON="B's first file header not shown expanded"; return 1; }
  status_line | grep -q "matches\]" && { REASON="A's search indicator shown on B: $(status_line)"; return 1; }
  return 0
}

# Risk 6: a queued A post failing after the switch reports the previous-PR
# error and does not pre-fill B's editor.
scenario_stale_post_failure() {
  fake_gh_set FAKE_GH_DELAY_CREATE 6
  fake_gh_set FAKE_GH_FAIL_THREAD 1
  skim_start pr
  wait_for_pane "Alpha change" 10 || { REASON="sidebar never showed PRs"; return 1; }
  send Enter
  wait_for_pane "ALPHA-ANCHOR-010" 10 || { REASON="A's diff never rendered"; return 1; }
  comment_on "ALPHA-ANCHOR-010" "QUEUED-FIRST" || { REASON="could not post the first comment"; return 1; }
  comment_on "ALPHA-ANCHOR-020" "QUEUED-SECOND" || { REASON="could not queue the second comment"; return 1; }
  switch_to_pr2 || return 1
  local saw_msg=0 deadline=$((SECONDS + 15))
  while ((SECONDS < deadline)); do
    pane_has "previous PR" && saw_msg=1
    (($(log_count '^thread') >= 2)) && ((saw_msg)) && break
    sleep 0.1
  done
  (($(log_count '^thread') >= 2)) || { REASON="expected 2 thread calls, got $(log_count '^thread')"; return 1; }
  ((saw_msg)) || { REASON="status never showed the 'previous PR' error: $(status_line)"; return 1; }
  sleep 1
  search_for "BRAVO-LINE-005"
  sleep 0.3
  send Enter
  wait_for_pane "$EDITOR_RE" 3 || { REASON="comment editor did not open on B"; return 1; }
  pane_has "QUEUED-FIRST|QUEUED-SECOND" && { REASON="B's editor is pre-filled with A's draft"; return 1; }
  send C-w
  return 0
}

# Risk 7: working-tree local comments are parked on the PR surface and
# restored after leaving it.
scenario_non_pr_comments_restored() {
  # Same hunk shape as PR 1's base.txt edit (line 2 replaced), so a comment
  # keyed by (file, hunk, line) WOULD render on PR 1 if it leaked.
  sed -i 's/^base line 2$/WT-DIRTY-LINE/' "$WORK/clone/base.txt"
  skim_start
  wait_for_pane "WT-DIRTY-LINE" 10 || { REASON="working-tree diff never showed base.txt change"; return 1; }
  search_for "WT-DIRTY-LINE"
  sleep 0.3
  send Enter
  wait_for_pane "$EDITOR_RE" 3 || { REASON="comment editor did not open on the working tree"; return 1; }
  type_text "WT-NOTE"
  send C-s
  wait_for_pane_gone "$EDITOR_RE" 3 || { REASON="comment editor did not close"; return 1; }
  wait_for_pane "WT-NOTE" 3 || { REASON="local comment WT-NOTE not rendered after save"; return 1; }
  palette_run "pr"
  wait_for_pane "Alpha change" 10 || { REASON="PR sidebar did not open from the palette"; return 1; }
  send Enter
  wait_for_pane "a_only.txt" 10 || { REASON="PR 1 diff never appeared"; return 1; }
  sleep 1
  search_for "edited by ALPHA"
  wait_for_pane "edited by ALPHA" 3 || { REASON="PR 1's base.txt edit not on screen"; return 1; }
  pane_has "WT-NOTE" && { REASON="working-tree comment WT-NOTE shown on the PR"; return 1; }
  palette_run "diff:working"
  wait_for_pane "\\[Working\\]" 10 || { REASON="did not return to the working-tree diff"; return 1; }
  # Leaving the PR surface resets the cursor to the top, so the working tree's
  # only file (and its comment) is on screen without moving.
  wait_for_pane "WT-DIRTY-LINE" 5 || { REASON="working-tree diff top not on screen (cursor kept from the PR?)"; return 1; }
  wait_for_pane "WT-NOTE" 3 || { REASON="WT-NOTE not restored after leaving the PR surface"; return 1; }
  return 0
}

# Risk 7 (variant): the PR entry fails (git fetch), so the working-tree diff
# never leaves the screen — and neither may its local comments.
scenario_failed_entry_keeps_comments() {
  sed -i 's/^base line 2$/WT-DIRTY-LINE/' "$WORK/clone/base.txt"
  world_git -C "$WORK/origin.git" update-ref -d refs/pull/1/head
  # Drop A's head from the clone too: a local head would make the entry a
  # prefetch cache hit that never fetches.
  world_git -C "$WORK/clone" update-ref -d refs/remotes/origin/feat-a
  world_git -C "$WORK/clone" reflog expire --expire=now --all
  world_git -C "$WORK/clone" gc --quiet --prune=now
  skim_start
  add_wt_note || return 1
  palette_run "pr"
  wait_for_pane "Alpha change" 10 || { REASON="PR sidebar did not open from the palette"; return 1; }
  send Enter
  wait_for_pane "fetch failed" 15 || { REASON="sidebar never reported the failed fetch"; return 1; }
  send Escape
  wait_for_pane "\\[Working\\]" 5 || { REASON="Esc did not return to the working-tree diff: $(status_line)"; return 1; }
  pane_has "WT-NOTE" || { REASON="WT-NOTE vanished after a failed PR entry"; return 1; }
  return 0
}

# Risk 7 (variant): leave the PR surface while the next PR's entry is still in
# flight. Its late result must not pull the user back onto a PR diff.
scenario_leave_during_entry() {
  sed -i 's/^base line 2$/WT-DIRTY-LINE/' "$WORK/clone/base.txt"
  skim_start
  add_wt_note || return 1
  palette_run "pr"
  wait_for_pane "Alpha change" 10 || { REASON="PR sidebar did not open from the palette"; return 1; }
  send Enter
  wait_for_pane "a_only.txt" 10 || { REASON="PR 1 diff never appeared"; return 1; }
  fake_gh_set FAKE_GH_DELAY_2 4
  open_sidebar || { REASON="could not reopen the PR sidebar via the palette"; return 1; }
  send j
  sleep 0.2
  send Enter
  wait_for_log '^review.*number=2' 1 5 || { REASON="no gh review call for PR 2"; return 1; }
  send Escape
  sleep 0.3
  in_sidebar && { REASON="Esc did not close the sidebar"; return 1; }
  palette_run "diff:working"
  wait_for_pane "\\[Working\\]" 10 || { REASON="did not return to the working-tree diff"; return 1; }
  # PR 2's fake gh sleeps 4s; wait past it so a late entry would have landed.
  sleep 5
  status_line | grep -q "\\[Working\\]" || { REASON="late PR 2 entry replaced the working diff: $(status_line)"; return 1; }
  pane_has "b_only.txt" && { REASON="PR 2's diff (b_only.txt) is on screen"; return 1; }
  pane_has "WT-NOTE" || { REASON="WT-NOTE not shown on the working-tree diff"; return 1; }
  return 0
}

# Risk 3 (variant): post on A (slow create), switch to B and post there while
# A's write is in flight. Each body lands on its own PR's pending review.
scenario_post_on_both() {
  fake_gh_set FAKE_GH_DELAY_CREATE 6
  skim_start pr
  wait_for_pane "Alpha change" 10 || { REASON="sidebar never showed PRs"; return 1; }
  send Enter
  wait_for_pane "ALPHA-ANCHOR-010" 10 || { REASON="A's diff never rendered"; return 1; }
  comment_on "ALPHA-ANCHOR-010" "A-BODY" || { REASON="could not post on A"; return 1; }
  switch_to_pr2 || return 1
  sleep 0.5
  comment_on "BRAVO-LINE-005" "B-BODY" || { REASON="could not post on B"; return 1; }
  wait_for_log '^thread' 2 20 || { REASON="expected 2 addPullRequestReviewThread calls, got $(log_count '^thread')"; return 1; }
  sleep 1
  local calls
  calls="$(tr '\037' '\n' <"$WORK/gh.log")"
  grep -qx 'prId=PR_A' <<<"$calls" || { REASON="no pending-review create on PR_A"; return 1; }
  grep -qx 'prId=PR_B' <<<"$calls" || { REASON="B's post did not create its own review on PR_B"; return 1; }
  grep -a 'rid=PRR_FOR_PR_A' "$WORK/gh.log" | grep -q 'B-BODY' && { REASON="B-BODY posted to A's review"; return 1; }
  grep -a 'rid=PRR_FOR_PR_B' "$WORK/gh.log" | grep -q 'A-BODY' && { REASON="A-BODY posted to B's review"; return 1; }
  grep -a 'rid=PRR_FOR_PR_A' "$WORK/gh.log" | grep -q 'A-BODY' || { REASON="A-BODY never posted to A's review"; return 1; }
  grep -a 'rid=PRR_FOR_PR_B' "$WORK/gh.log" | grep -q 'B-BODY' || { REASON="B-BODY never posted to B's review"; return 1; }
  pane_has "A-BODY" && { REASON="A's draft body shown on B"; return 1; }
  wait_for_pane "B-BODY" 5 || { REASON="B's own posted draft not rendered on B"; return 1; }
  return 0
}

# Risk 3 + 7: leave the PR surface for the working tree while A's posts are
# still draining (slow create, second post queued). Both still go to PR_A
# under one pending review, and nothing PR-related shows on the working diff.
scenario_leave_while_post_drains() {
  sed -i 's/^base line 2$/WT-DIRTY-LINE/' "$WORK/clone/base.txt"
  fake_gh_set FAKE_GH_DELAY_CREATE 6
  skim_start
  add_wt_note || return 1
  palette_run "pr"
  wait_for_pane "Alpha change" 10 || { REASON="PR sidebar did not open from the palette"; return 1; }
  send Enter
  wait_for_pane "a_only.txt" 10 || { REASON="PR 1 diff never appeared"; return 1; }
  sleep 1
  comment_on "ALPHA-ANCHOR-010" "QUEUED-FIRST" || { REASON="could not post the first comment"; return 1; }
  comment_on "ALPHA-ANCHOR-020" "QUEUED-SECOND" || { REASON="could not queue the second comment"; return 1; }
  if (($(log_count '^thread') > 0)); then
    REASON="harness timing: A's thread call ran before leaving; raise FAKE_GH_DELAY_CREATE"
    return 1
  fi
  palette_run "diff:working"
  wait_for_pane "\\[Working\\]" 10 || { REASON="did not return to the working-tree diff"; return 1; }
  # Watch the screen for the whole drain, not just its end.
  local seen_drafts=0 deadline=$((SECONDS + 20))
  while ((SECONDS < deadline)) && (($(log_count '^thread') < 2)); do
    pane_has "QUEUED-FIRST|QUEUED-SECOND" && seen_drafts=1
    sleep 0.2
  done
  (($(log_count '^thread') == 2)) || { REASON="expected 2 addPullRequestReviewThread calls, got $(log_count '^thread')"; return 1; }
  sleep 1.5
  assert_all_writes_on_a || return 1
  (($(log_count '^create') == 1)) || { REASON="expected exactly 1 pending-review create, got $(log_count '^create')"; return 1; }
  ((seen_drafts == 0)) || { REASON="A's draft body appeared on the working diff during the drain"; return 1; }
  pane_has "QUEUED-FIRST|QUEUED-SECOND" && { REASON="A's draft body on the working diff after the drain"; return 1; }
  status_line | grep -q "\\[Working\\]" || { REASON="not on the working-tree diff after the drain: $(status_line)"; return 1; }
  status_line | grep -qE "drafts:|PR #" && { REASON="working-tree status shows PR state: $(status_line)"; return 1; }
  pane_has "WT-NOTE" || { REASON="WT-NOTE not shown on the working-tree diff"; return 1; }
  return 0
}

# =============================================================================
# Helpers
# =============================================================================

run_scenario() {
  local name="$1" fn="scenario_${1//-/_}"
  if ! declare -F "$fn" >/dev/null; then
    echo "FAIL $name: unknown scenario"
    ANY_FAIL=1
    return
  fi
  WORK="$ROOT/$name"
  mkdir -p "$WORK"
  if ! world_setup "$WORK" >"$WORK/setup.log" 2>&1 || ! world_selfcheck_fetch >>"$WORK/setup.log" 2>&1; then
    echo "FAIL $name: offline git world setup failed (see $WORK/setup.log)"
    ANY_FAIL=1
    return
  fi
  : >"$WORK/gh.log"
  REASON=""
  "$fn"
  local rc=$?
  if ((rc == 0)) && skim_alive && ! stderr_has_crash; then
    echo "PASS $name"
  elif ((rc == 2)); then
    echo "SKIP $name: $REASON"
  else
    [ -z "$REASON" ] && REASON="skim crashed or exited (see stderr.log)"
    stderr_has_crash && REASON="$REASON; crash text in stderr.log"
    echo "FAIL $name: $REASON"
    dump_failure "$name"
    ANY_FAIL=1
  fi
  skim_stop
}

dump_failure() {
  local out="$ROOT/fail-$1.txt"
  {
    echo "== $1: $REASON"
    echo "== pane"
    pane
    echo "== gh.log"
    log_readable
    echo "== fake-gh.conf"
    cat "$WORK/fake-gh.conf"
    echo "== stderr.log (tail)"
    tail -50 "$WORK/stderr.log" 2>/dev/null
  } >"$out"
  echo "     details: $out"
}

cleanup() {
  skim_stop
  if ((ANY_FAIL)) || [ "${KEEP_WORK:-0}" = "1" ]; then
    echo "work dir kept: $ROOT"
  else
    rm -rf "$ROOT"
  fi
}

status_line() {
  pane | grep -E -- '^-- [A-Z ]+ --' | tail -1
}

# Columns the PR sidebar takes, divider included, in the default 200-column
# pane: clamp(200 * 28 / 100, 32, 56) (src/pr/sidebar/layout.zig).
SIDEBAR_COLS=56

# The pane with the sidebar's columns cut off. Bash slices by character only
# under a UTF-8 locale, and the sidebar draws multi-byte glyphs.
diff_pane() {
  local LC_ALL=C.UTF-8 line
  while IFS= read -r line; do
    printf '%s\n' "${line:SIDEBAR_COLS}"
  done < <(pane)
}

diff_pane_has() {
  diff_pane | grep -qE -- "$1"
}

# The PR sidebar has focus (`pr_review` mode).
in_sidebar() {
  status_line | grep -q -- "-- PRS --"
}

# Remove both PR heads from the clone, so a PR entry has to fetch.
drop_local_pr_heads() {
  world_git -C "$WORK/clone" update-ref -d refs/remotes/origin/feat-a
  world_git -C "$WORK/clone" update-ref -d refs/remotes/origin/feat-b
  world_git -C "$WORK/clone" reflog expire --expire=now --all
  world_git -C "$WORK/clone" gc --quiet --prune=now
}

# A `git` first on skim's PATH that refuses the prefetch worker's fetches (the
# only ones passing --no-auto-maintenance) and runs everything else, so the
# worker caches no diff and every entry stays a miss. Each refusal is logged
# to $PREFETCH_BLOCKED_LOG so a scenario can prove the block fired.
block_prefetch_fetches() {
  local real_git
  real_git="$(command -v git)"
  PREFETCH_BLOCKED_LOG="$WORK/prefetch-blocked.log"
  : >"$PREFETCH_BLOCKED_LOG"
  {
    echo '#!/usr/bin/env bash'
    echo 'for arg in "$@"; do'
    echo "  [ \"\$arg\" = \"--no-auto-maintenance\" ] && { echo \"\$*\" >>$(printf '%q' "$PREFETCH_BLOCKED_LOG"); echo \"fatal: prefetch fetch blocked by switch-isolation\" >&2; exit 128; }"
    echo 'done'
    echo "exec $(printf '%q' "$real_git") \"\$@\""
  } >"$WORK/bin/git"
  chmod +x "$WORK/bin/git"
}

# The miss scenario only tests parking if B's head is still absent when B is
# entered: the prefetch worker must have tried (and been refused) and left
# neither refs/skim/pr-2 nor B's commit in the clone.
assert_prefetch_blocked() {
  local i
  for ((i = 0; i < 100; i++)); do
    [ -s "$PREFETCH_BLOCKED_LOG" ] && break
    sleep 0.1
  done
  [ -s "$PREFETCH_BLOCKED_LOG" ] || { REASON="the prefetch worker's fetch never reached the blocking git wrapper"; return 1; }
  world_git -C "$WORK/clone" show-ref --verify --quiet refs/skim/pr-2 && { REASON="refs/skim/pr-2 exists before B's entry: prefetch was not blocked"; return 1; }
  world_git -C "$WORK/clone" cat-file -e "$SHA_B^{commit}" 2>/dev/null && { REASON="B's head is local before B's entry: the entry would not miss"; return 1; }
  return 0
}

open_sidebar() {
  palette_run "pr"
  wait_for_pane "Bravo change" 5 && wait_for_pane "-- PRS --" 3
}

dismiss_editor() {
  if pane_has "$EDITOR_RE"; then
    send C-w
    wait_for_pane_gone "$EDITOR_RE" 2
  fi
}

# Number of the highlighted sidebar row (marked with ▌).
sidebar_selected_number() {
  pane | grep '▌' | grep -oE '#[0-9]+' | head -1 | tr -d '#'
}

search_for() {
  send /
  sleep 0.2
  type_text "$1"
  send Enter
  sleep 0.3
}

# comment_on <search text> <body>: put the cursor on the line, open the editor
# (Enter in normal mode), type, save with Ctrl-s.
comment_on() {
  search_for "$1"
  send Enter
  wait_for_pane "$EDITOR_RE" 3 || return 1
  type_text "$2"
  send C-s
  wait_for_pane_gone "$EDITOR_RE" 3
}

# Wait for the working-tree diff, then leave WT-NOTE on the WT-DIRTY-LINE edit.
add_wt_note() {
  wait_for_pane "WT-DIRTY-LINE" 10 || { REASON="working-tree diff never showed base.txt change"; return 1; }
  search_for "WT-DIRTY-LINE"
  sleep 0.3
  send Enter
  wait_for_pane "$EDITOR_RE" 3 || { REASON="comment editor did not open on the working tree"; return 1; }
  type_text "WT-NOTE"
  send C-s
  wait_for_pane_gone "$EDITOR_RE" 3 || { REASON="comment editor did not close"; return 1; }
  wait_for_pane "WT-NOTE" 3 || { REASON="local comment WT-NOTE not rendered after save"; return 1; }
}

# Switch to PR 2 while A's slow pending-review create is still running. The
# guard makes a too-slow switch a loud harness failure, not a false PASS.
switch_to_pr2() {
  open_sidebar || { REASON="could not reopen the PR sidebar via the palette"; return 1; }
  send j
  sleep 0.2
  send Enter
  if (($(log_count '^thread') > 0)); then
    REASON="harness timing: A's thread call ran before the switch; raise FAKE_GH_DELAY_CREATE"
    return 1
  fi
  wait_for_pane "b_only.txt" 10 || { REASON="B's diff (b_only.txt) never appeared"; return 1; }
}

assert_all_writes_on_a() {
  local bad
  bad="$(tr '\037' '\n' <"$WORK/gh.log" | grep -E '^(prId|rid)=' | grep -vE '^(prId=PR_A|rid=PRR_FOR_PR_A)$' | sort -u | paste -sd' ')"
  [ -z "$bad" ] || { REASON="write sent with non-A ids: $bad"; return 1; }
}

assert_b_clean_of_a_drafts() {
  pane_has "QUEUED-FIRST|QUEUED-SECOND" && { REASON="A's draft body shown on B"; return 1; }
  status_line | grep -q "drafts:" && { REASON="B's status counts A's drafts: $(status_line)"; return 1; }
  status_line | grep -q "PR #2" || { REASON="status line does not name PR #2: $(status_line)"; return 1; }
  return 0
}

main "$@"
