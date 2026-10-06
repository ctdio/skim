#!/bin/bash
# Diagnostic: prove the offline PR-review world works WITHOUT the TUI, so a red
# switch-isolation.sh scenario can be blamed on skim rather than the harness.
#
#   1. bare origin carries main + refs/pull/{1,2}/head
#   2. github.fetchRef's refspecs resolve through url.<bare>.insteadOf
#   3. the fake gh answers every call shape skim makes (and fails on demand)
#   4. the fixtures parse through skim's REAL parsers (`skim debug pr-view`,
#      `pr-anchor`, `pr-comment`), and the failure path classifies as network
#   5. the Zig lane-test fakes planned in testing-strategy.md (fake_gh_script /
#      fake_git_script) dispatch correctly on the argv skim really sends
#   6. (tmux present) `skim pr` renders the PR sidebar and enters PR 1 offline
#
# Usage:  bash scripts/test-infra/pr-review/offline/check-offline-world.sh
# Exit 0 = PASS (or SKIP lines for missing tmux/skim); Exit 1 = FAIL.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=world-lib.sh
. "$HERE/world-lib.sh"

FAILS=0

main() {
  command -v git >/dev/null 2>&1 || { echo "FAIL: git not in PATH"; exit 1; }
  ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skim-offline-world.XXXXXX")"
  trap cleanup EXIT

  check_world
  check_fake_gh
  if [ -x "$SKIM" ]; then
    check_real_parsers
    check_lane_fakes
  else
    echo "SKIP real-parser + lane-fake checks: $SKIM not built (run 'zig build')"
  fi
  if ! command -v tmux >/dev/null 2>&1; then
    echo "SKIP tui smoke: tmux not in PATH"
  elif [ ! -x "$SKIM" ]; then
    echo "SKIP tui smoke: $SKIM not built"
  else
    check_tui_smoke
  fi

  if ((FAILS)); then
    echo ""
    echo "FAIL: $FAILS check(s) failed; work dir kept: $ROOT"
    exit 1
  fi
  echo ""
  echo "PASS: offline world, fake gh, real parsers and lane fakes verified."
  exit 0
}

# =============================================================================
# Checks
# =============================================================================

check_world() {
  WORK="$ROOT/world"
  mkdir -p "$WORK"
  if ! world_setup "$WORK" >"$ROOT/setup.log" 2>&1; then
    fail "world_setup failed: $(tail -3 "$ROOT/setup.log")"
    exit 1
  fi
  local refs
  refs="$(git -C "$WORK/origin.git" for-each-ref --format='%(refname)')"
  expect_contains "bare origin has refs/heads/main" "$refs" "refs/heads/main"
  expect_contains "bare origin has refs/pull/1/head" "$refs" "refs/pull/1/head"
  expect_contains "bare origin has refs/pull/2/head" "$refs" "refs/pull/2/head"
  expect_eq "refs/pull/1/head == feat-a" "$(git -C "$WORK/origin.git" rev-parse refs/pull/1/head)" "$SHA_A"
  expect_eq "refs/pull/2/head == feat-b" "$(git -C "$WORK/origin.git" rev-parse refs/pull/2/head)" "$SHA_B"
  expect_eq "clone origin url is the fake GitHub url" \
    "$(git -C "$WORK/clone" config --get remote.origin.url)" "$FAKE_REMOTE_URL"
  if world_selfcheck_fetch >>"$ROOT/setup.log" 2>&1; then
    pass "fetchRef refspecs (+pull/N/head, +main) resolve through insteadOf"
  else
    fail "git fetch through insteadOf failed: $(tail -3 "$ROOT/setup.log")"
  fi
  local files
  files="$(git -C "$WORK/clone" diff --name-only "origin/main...$SHA_A" 2>/dev/null | paste -sd' ')"
  expect_eq "PR 1 diff files" "$files" "a_only.txt alpha_code.zig base.txt lib.zig"
  files="$(git -C "$WORK/clone" diff --name-only "origin/main...$SHA_B" 2>/dev/null | paste -sd' ')"
  expect_eq "PR 2 diff files" "$files" "b_only.txt base.txt bravo_code.zig lib.zig"
  local hunks
  hunks="$(git -C "$WORK/clone" diff "origin/main...$SHA_A" -- lib.zig | grep -c '^@@')"
  ((hunks >= 20)) && pass "lib.zig has $hunks hunks in PR 1 (highlight load)" || fail "lib.zig has only $hunks hunks"
}

check_fake_gh() {
  local gh="$WORK/bin/gh" out
  : >"$WORK/gh.log"
  out="$("$gh" pr list --limit 50 --json number,title 2>&1)"
  expect_contains "fake gh: pr list returns both PRs" "$out" '"Bravo change"'
  out="$("$gh" pr view 2 --json number 2>&1)"
  expect_contains "fake gh: pr view 2 returns PR 2 meta" "$out" '"baseRefName":"main"'
  out="$("$gh" api graphql -f query=q -f owner=fake -f name=repo -F number=1 2>&1)"
  expect_contains "fake gh: review query for #1 has the A thread" "$out" "ALPHA-THREAD-MARKER"
  out="$("$gh" api graphql -f query=q -f prId=PR_A -f oid=x 2>&1)"
  expect_contains "fake gh: create pending review echoes prId" "$out" '"PRR_FOR_PR_A"'
  out="$("$gh" api graphql -f query=q -f rid=PRR_FOR_PR_A -f path=a_only.txt -f side=RIGHT -f 'body=he said "hi"' -F line=5 2>&1)"
  expect_contains "fake gh: add thread echoes path/line/rid" "$out" '"line":5,"startLine":null'
  expect_contains "fake gh: add thread JSON-escapes the body" "$out" 'he said \"hi\"'
  local start=$SECONDS
  FAKE_GH_DELAY_2=1 "$gh" api graphql -f query=q -F number=2 >/dev/null 2>&1
  ((SECONDS - start >= 1)) && pass "fake gh: FAKE_GH_DELAY_2 delays the #2 review query" || fail "FAKE_GH_DELAY_2 had no effect"
  fake_gh_set FAKE_GH_FAIL_2 1
  out="$("$gh" api graphql -f query=q -F number=2 2>&1)"
  local rc=$?
  ((rc == 1)) && [[ "$out" == *"error connecting to"* ]] &&
    pass "fake gh: fake-gh.conf FAKE_GH_FAIL_2=1 -> exit 1 + network stderr" ||
    fail "fake gh: FAIL_2 gave rc=$rc out=$out"
  fake_gh_set FAKE_GH_FAIL_2 0
  "$gh" bogus >/dev/null 2>&1 && fail "fake gh: unknown call exited 0" || pass "fake gh: unknown call exits 1"
  expect_eq "fake gh: gh.log has one line per call" "$(wc -l <"$WORK/gh.log" | tr -d ' ')" "8"
  expect_eq "fake gh: gh.log kinds" "$(cut -d$'\x1f' -f1 "$WORK/gh.log" | paste -sd' ')" \
    "list view review create thread review review unknown"
}

check_real_parsers() {
  local out rc
  : >"$WORK/gh.log"
  : >"$WORK/fake-gh.conf"
  out="$(in_clone "$SKIM" debug pr-view 1 2>&1)"
  rc=$?
  ((rc == 0)) && [[ "$out" == *"PR #1: Alpha change"* && "$out" == *"node: PR_A"* && "$out" == *"ALPHA-THREAD-MARKER"* ]] &&
    pass "skim debug pr-view 1 parses review-1.json (PR_A, thread)" || fail "pr-view 1: rc=$rc $out"
  out="$(in_clone "$SKIM" debug pr-view 2 2>&1)"
  rc=$?
  ((rc == 0)) && [[ "$out" == *"node: PR_B"* && "$out" == *"threads: 0"* ]] &&
    pass "skim debug pr-view 2 parses review-2.json (PR_B, no threads)" || fail "pr-view 2: rc=$rc $out"
  out="$(in_clone "$SKIM" debug pr-anchor 1 2>&1)"
  rc=$?
  ((rc == 0)) && [[ "$out" == *"a_only.txt:3 [right] open -> inline"* ]] &&
    pass "skim debug pr-anchor 1: A's thread anchors inline via the real fetchRef + diff" || fail "pr-anchor 1: rc=$rc $out"
  out="$(in_clone "$SKIM" debug pr-comment 1 --path a_only.txt --line 5 --side right --body "probe" 2>&1)"
  rc=$?
  ((rc == 0)) && [[ "$out" == *"PRR_FOR_PR_A"* && "$out" == *"a_only.txt:5"* ]] &&
    pass "skim debug pr-comment 1: create + add-thread responses parse" || fail "pr-comment 1: rc=$rc $out"
  out="$(FAKE_GH_FAIL_2=1 in_clone "$SKIM" debug pr-view 2 2>&1)"
  rc=$?
  ((rc != 0)) && [[ "$out" == *"network"* ]] &&
    pass "FAKE_GH_FAIL_2=1 classifies as .network in skim" || fail "fail path: rc=$rc $out"
  cp "$WORK/gh.log" "$ROOT/real-argv.log"
}

# Replays the argv skim really sent (captured above) through the fake scripts
# testing-strategy.md plans to embed in review_controller.zig as test constants.
check_lane_fakes() {
  local lane="$ROOT/lane"
  mkdir -p "$lane"
  cat >"$lane/gh" <<'EOF'
#!/bin/sh
d=$(dirname "$0")
echo "$*" >> "$d/gh.log"
case "$*" in
  *number=42*) cat "$d/review-42.json" ;;
  *number=7*)  cat "$d/review-7.json" ;;
  *prId=*)     cat "$d/create-review.json" ;;
  *rid=*)      cat "$d/add-thread.json" ;;
  *tid=*)      cat "$d/reply.json" ;;
  *) echo "unknown fake gh call" >&2; exit 1 ;;
esac
EOF
  cat >"$lane/git" <<'EOF'
#!/bin/sh
case "$1" in
  fetch) exit 0 ;;
  config) echo https://github.com/fake/repo.git ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$lane/gh" "$lane/git"
  echo REVIEW42 >"$lane/review-42.json"
  echo REVIEW7 >"$lane/review-7.json"
  echo CREATE >"$lane/create-review.json"
  echo THREAD >"$lane/add-thread.json"
  echo REPLY >"$lane/reply.json"

  local kind argv out want
  while IFS= read -r line; do
    kind="${line%%$'\x1f'*}"
    IFS=$'\x1f' read -r -a argv <<<"${line#*$'\x1f'}"
    # Map the world's PR numbers onto the lane fixtures' (#1 -> 42, #2 -> 7).
    argv=("${argv[@]/#number=1/number=42}")
    argv=("${argv[@]/#number=2/number=7}")
    case "$kind" in
      review) want="REVIEW" ;;
      create) want="CREATE" ;;
      thread) want="THREAD" ;;
      *) continue ;;
    esac
    out="$("$lane/gh" "${argv[@]}" 2>&1)"
    [[ "$out" == "$want"* ]] || { fail "lane fake gh: $kind argv dispatched to '$out' (want $want*)"; return; }
  done <"$ROOT/real-argv.log"
  pass "lane fake_gh_script dispatches real review/create/thread argv correctly"

  local reply_argv=(api graphql -f "query=mutation (\$tid: ID!, \$body: String!) {
  addPullRequestReviewThreadReply" -f tid=PRRT_1 -f body=hi)
  out="$("$lane/gh" "${reply_argv[@]}" 2>&1)"
  [[ "$out" == "REPLY" ]] && pass "lane fake_gh_script dispatches reply (tid=) argv" || fail "lane reply dispatch: $out"

  local logged
  logged="$(grep -c 'number=42' "$lane/gh.log")"
  ((logged >= 1)) && pass "lane gh.log: count invocations by marker (number=42 lines: $logged), not by line count" ||
    fail "lane gh.log missing number=42"

  out="$("$lane/git" config --get remote.origin.url)"
  expect_eq "lane fake_git_script answers getOriginOwnerRepo" "$out" "https://github.com/fake/repo.git"
  "$lane/git" fetch --quiet origin "+pull/42/head:refs/skim/pr-42" && pass "lane fake_git_script accepts fetchRef" ||
    fail "lane fake git fetch failed"
}

check_tui_smoke() {
  : >"$WORK/gh.log"
  : >"$WORK/fake-gh.conf"
  skim_start pr
  if wait_for_pane "Alpha change" 10 && pane_has "Bravo change"; then
    pass "tui: skim pr lists both fake PRs"
  else
    fail "tui: sidebar never showed the fake PRs: $(pane | head -5)"
    skim_stop
    return
  fi
  send Enter
  # The diff names the head oid the fetch landed, shown abbreviated.
  if wait_for_pane "ALPHA-THREAD-MARKER" 10 && pane_has "\.\.\.${SHA_A:0:7}\]"; then
    pass "tui: Enter on PR 1 fetches its head and renders A's thread"
  else
    fail "tui: PR 1 never rendered: $(pane | tail -2)"
  fi
  skim_stop
}

# =============================================================================
# Helpers
# =============================================================================

in_clone() {
  (cd "$WORK/clone" && env HOME="$WORK/home" PATH="$WORK/bin:$PATH" "$@")
}

pass() { echo "  PASS: $1"; }
fail() {
  echo "  FAIL: $1"
  FAILS=$((FAILS + 1))
}

expect_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: got '$2', want '$3'"; fi
}

expect_contains() {
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1: '$3' not in output: $2"; fi
}

cleanup() {
  skim_stop
  ((FAILS)) || rm -rf "$ROOT"
}

main "$@"
