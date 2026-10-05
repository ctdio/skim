#!/usr/bin/env bash
# Phase 6a offline harness for the PR sidebar surface. Builds a disposable,
# fully offline world, then runs zig-out/bin/pr_surface_harness (the real App,
# SyncWorker and review entry worker, in-process) and the optional tmux smoke
# test S12 against the real zig-out/bin/skim.
#
# World (under $WORK):
#   origin.git, clone/, bin/gh, fixtures/review-N.json, targets.tsv, gh.log
#                       Phase 5's prefetch/setup-origin.sh (reused, not forked)
#   clone/              origin url https://github.com/skim-fixture/repo.git,
#                       redirected to origin.git with url.<path>.insteadOf
#   clone-local/        plain clone whose origin stays a local path (S8)
#   sync/<kind>/gh      launchers for Phase 3's sync/fake-gh with a per-kind
#                       FAKE_GH_ROOT (sync/<kind>/root): `network` and
#                       `unauthenticated` fail every SkimSync* operation with
#                       the captured stderr/exit code; `missing` is a path that
#                       does not exist (spawn fails -> not_installed);
#                       `slow` holds every call for 8s (S14)
#   bin/gt              stub Graphite CLI that always fails
#   home/.skim/         HOME for the harness and S12 (prs.db, config.json)
#
# Usage:
#   scripts/test-infra/pr-sidebar/surface-harness.sh [all|S1..S14|seed-only <fixture>] 2>&1 | tee /tmp/p6a-harness.log
#   scripts/test-infra/pr-sidebar/surface-harness.sh --check-world   # verify the world only (no harness binary)
#   KEEP_WORK=1   keep $WORK after the run (always kept when something failed)
#   SKIM_HARNESS_NO_BUILD=1   skip `zig build pr-surface-harness` / `zig build`
#
# Output: PASS/FAIL/SKIP lines; exit 1 on any FAIL. `grep -c '^FAIL'` must be 0.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
PREFETCH_DIR="$HERE/prefetch"
SYNC_DIR="$HERE/sync"
SYNC_FAKE="$SYNC_DIR/fake-gh"
HARNESS_BIN="$ROOT/zig-out/bin/pr_surface_harness"
SKIM_BIN="$ROOT/zig-out/bin/skim"

REPO_URL="https://github.com/skim-fixture/repo.git"
# In-process scenarios; S12 runs from this script.
IN_PROCESS="S1 S2 S3 S4 S5 S6 S7 S8 S9 S10 S13 S14"
FAILS=0

main() {
  local target="${1:-all}"

  command -v git >/dev/null || { skip_all "git not in PATH"; exit 0; }
  command -v bash >/dev/null || { skip_all "bash not in PATH"; exit 0; }
  check_prerequisites || exit 1

  WORK="$(mktemp -d /tmp/skim-surface-XXXX)"
  trap cleanup EXIT
  echo "WORK=$WORK"
  build_world || { fail setup "world construction failed (see above)"; exit 1; }
  if [ "$target" = "--check-world" ]; then
    export_env
    check_world
    exit $((FAILS > 0))
  fi

  # Before export_env: zig keeps its global cache under the real HOME.
  build_binaries || exit 1
  export_env
  case "$target" in
    seed-only)
      (cd "$WORK/clone" && "$HARNESS_BIN" seed-only "${2:-origin14}") || fail seed-only "exit $?"
      ;;
    S12)
      run_s12
      ;;
    all)
      run_in_process all
      check_gh_routing
      run_s12
      ;;
    *)
      run_in_process "$target"
      check_gh_routing
      ;;
  esac
  exit $((FAILS > 0))
}

# =============================================================================
# World
# =============================================================================

build_world() {
  WORK="$WORK" "$PREFETCH_DIR/setup-origin.sh" >/dev/null || return 1

  # The surface rejects non-github origins, so the clone gets a GitHub URL
  # that git rewrites to the local bare repo.
  git -C "$WORK/clone" remote set-url origin "$REPO_URL" || return 1
  git -C "$WORK/clone" config "url.$WORK/origin.git.insteadOf" "$REPO_URL" || return 1
  git clone -q "$WORK/origin.git" "$WORK/clone-local" 2>/dev/null || return 1

  printf '#!/bin/sh\nexit 1\n' >"$WORK/bin/gt"
  chmod +x "$WORK/bin/gt"

  mkdir -p "$WORK/home/.skim" "$WORK/home/.config" "$WORK/home/.cache"
  write_sync_kind network "$SYNC_DIR/captured/network-failure" || return 1
  write_sync_kind unauthenticated "$SYNC_DIR/captured/auth-failure" || return 1
  mkdir -p "$WORK/sync/missing"
  write_slow_kind
}

# sync/slow/gh: logs each call, then holds it for 8s before answering, so a
# sync is in flight while S14 closes the surface.
write_slow_kind() {
  local root="$WORK/sync/slow/root"
  mkdir -p "$root/step-1"
  : >"$root/calls.log"
  cat >"$WORK/sync/slow/gh" <<EOF
#!/usr/bin/env bash
FAKE_GH_ROOT=$(printf '%q' "$root") SLEEP_MS=8000 exec $(printf '%q' "$SYNC_FAKE") "\$@"
EOF
  chmod +x "$WORK/sync/slow/gh"
}

# write_sync_kind <kind> <captured-prefix>: a launcher whose FAKE_GH_ROOT fails
# every SkimSync* operation (names read from queries.zig) with the captured
# stderr and exit code, so whichever call sync makes first fails.
write_sync_kind() {
  local kind="$1" captured="$2" root="$WORK/sync/$1/root" op
  mkdir -p "$root/step-1"
  : >"$root/calls.log"
  for op in $(sync_ops); do
    cp "$captured.stderr" "$root/step-1/fail-$op"
    cp "$captured.code" "$root/step-1/fail-$op.code"
  done
  cat >"$WORK/sync/$kind/gh" <<EOF
#!/usr/bin/env bash
FAKE_GH_ROOT=$(printf '%q' "$root") exec $(printf '%q' "$SYNC_FAKE") "\$@"
EOF
  chmod +x "$WORK/sync/$kind/gh"
}

sync_ops() {
  grep -o 'query SkimSync[A-Za-z]*' "$ROOT/src/pr/sync/queries.zig" | sed 's/^query //' | sort -u
}

export_env() {
  export HOME="$WORK/home"
  export XDG_CONFIG_HOME="$WORK/home/.config" XDG_CACHE_HOME="$WORK/home/.cache"
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
  export GIT_TRACE="$WORK/git-trace.log"
  export FAKE_GH_LOG="$WORK/gh.log" FAKE_GH_FIXTURES="$WORK/fixtures"
  export SKIM_HARNESS_WORK="$WORK"
  export SKIM_HARNESS_REPO="$WORK/clone"
  export SKIM_HARNESS_REPO_LOCAL="$WORK/clone-local"
  export SKIM_HARNESS_REPO_KEY="$REPO_URL"
  export SKIM_HARNESS_REVIEW_GH="$WORK/bin/gh"
  export SKIM_HARNESS_SYNC_FAKE="$SYNC_FAKE"
  export SKIM_HARNESS_SYNC_DIR="$WORK/sync"
  export SKIM_HARNESS_TARGETS="$WORK/targets.tsv"
  SKIM_HARNESS_PR9_FILES="$(pr_file_count 9)"
  export SKIM_HARNESS_PR9_FILES
  # Belt and braces: a gh call that bypasses both gh_bin options still hits a
  # fake and shows up in $FAKE_GH_LOG.
  export PATH="$WORK/bin:$PATH"
}

# Files in `origin/main...refs/pull/N/head` (what Enter on PR N loads),
# read from the bare origin so clone/ stays pristine.
pr_file_count() {
  git -C "$WORK/origin.git" diff --name-only "main...refs/pull/$1/head" | wc -l | tr -d ' '
}

# =============================================================================
# Runs
# =============================================================================

build_binaries() {
  [ -n "${SKIM_HARNESS_NO_BUILD:-}" ] && return 0
  (cd "$ROOT" && zig build pr-surface-harness) >"$WORK/build-harness.log" 2>&1 || {
    fail build "zig build pr-surface-harness failed; first errors:"
    grep -m 20 'error:' "$WORK/build-harness.log" | sed 's/^/    /'
    return 1
  }
  (cd "$ROOT" && zig build) >"$WORK/build-skim.log" 2>&1 || {
    fail build "zig build failed; see $WORK/build-skim.log"
    return 1
  }
}

run_in_process() {
  [ -x "$HARNESS_BIN" ] || { fail setup "$HARNESS_BIN missing (run: zig build pr-surface-harness)"; return; }
  (cd "$WORK/clone" && "$HARNESS_BIN" "$1") 2>"$WORK/harness-stderr.log"
  local code=$?
  if ((code != 0)); then
    FAILS=$((FAILS + 1))
    echo "  (harness exit $code; stderr: $WORK/harness-stderr.log)"
  fi
}

# Every sync call must go through gh_bin (the sync launchers), never through
# PATH to the review fake. Review-fake graphql calls always carry number=.
check_gh_routing() {
  local stray
  stray="$(grep 'query=<elided>' "$FAKE_GH_LOG" | grep -v 'number=' || true)"
  if [ -n "$stray" ]; then
    fail routing "sync gh not routed through gh_bin: $(echo "$stray" | head -n1)"
  else
    pass routing "no sync query reached the review fake via PATH"
  fi
}

# S12: the real binary paints the sidebar from the seeded DB.
run_s12() {
  command -v tmux >/dev/null || { echo "SKIP S12: tmux not in PATH"; return; }
  [ -x "$SKIM_BIN" ] || { fail S12 "$SKIM_BIN missing (run: zig build)"; return; }
  [ -x "$HARNESS_BIN" ] || { fail S12 "$HARNESS_BIN missing (run: zig build pr-surface-harness)"; return; }
  (cd "$WORK/clone" && "$HARNESS_BIN" seed-only origin14 >/dev/null) || { fail S12 "seed-only origin14 failed"; return; }

  local sock="$WORK/tmux.sock" pane="" i
  local cmd
  cmd="cd $(printf '%q' "$WORK/clone") && env FAKE_GH_LOG=$(printf '%q' "$WORK/gh-s12.log") $(printf '%q' "$SKIM_BIN") pr 2>$(printf '%q' "$WORK/s12-stderr.log"); echo SKIM-EXITED-\$?; sleep 30"
  tmux -S "$sock" -f /dev/null new-session -d -s skim6a -x 160 -y 40 "$cmd" || { fail S12 "tmux new-session failed"; return; }

  for i in $(seq 1 50); do
    pane="$(tmux -S "$sock" capture-pane -p -t skim6a 2>/dev/null)"
    grep -q '#9' <<<"$pane" && break
    sleep 0.1
  done
  if ! grep -q '#9' <<<"$pane"; then
    printf '%s\n' "$pane" >"$WORK/s12-pane.txt"
    tmux -S "$sock" kill-server 2>/dev/null
    fail S12 "no '#9' in the pane within 5s (pane: $WORK/s12-pane.txt)"
    return
  fi
  if ! head -n 3 <<<"$pane" | grep -qE 'offline|gh:|never synced|syncing|ago'; then
    printf '%s\n' "$pane" >"$WORK/s12-pane.txt"
    tmux -S "$sock" kill-server 2>/dev/null
    fail S12 "no sync status in the first three lines (pane: $WORK/s12-pane.txt)"
    return
  fi

  tmux -S "$sock" send-keys -t skim6a C-c
  for i in $(seq 1 20); do
    pane="$(tmux -S "$sock" capture-pane -p -t skim6a 2>/dev/null)"
    grep -q 'SKIM-EXITED-' <<<"$pane" && break
    sleep 0.1
  done
  tmux -S "$sock" kill-server 2>/dev/null
  if grep -q 'SKIM-EXITED-0' <<<"$pane"; then
    pass S12 "skim pr painted #9 with a sync status and quit on Ctrl-C"
  else
    printf '%s\n' "$pane" >"$WORK/s12-pane.txt"
    fail S12 "skim pr did not exit 0 within 2s of Ctrl-C (pane: $WORK/s12-pane.txt)"
  fi
}

# =============================================================================
# --check-world: verify everything the scenarios rely on, without the binary
# =============================================================================

check_world() {
  local url head expected out code

  url="$(git -C "$WORK/clone" config --get remote.origin.url)"
  [ "$url" = "$SKIM_HARNESS_REPO_KEY" ] && pass W1 "clone origin url is $url (the surface's repo key)" ||
    fail W1 "clone origin url is '$url', expected $SKIM_HARNESS_REPO_KEY"

  head="$(git -C "$WORK/clone" ls-remote origin refs/pull/9/head | cut -f1)"
  expected="$(awk -F'\t' '$1 == 9 { print $4 }' "$SKIM_HARNESS_TARGETS")"
  [ -n "$head" ] && [ "$head" = "$expected" ] && pass W2 "github origin resolves to origin.git via insteadOf (refs/pull/9/head = ${head:0:8})" ||
    fail W2 "ls-remote refs/pull/9/head gave '$head', targets.tsv says '$expected'"

  url="$(git -C "$WORK/clone-local" config --get remote.origin.url)"
  [ "$url" = "$WORK/origin.git" ] && pass W3 "clone-local origin is a local path (S8)" ||
    fail W3 "clone-local origin is '$url'"

  out="$("$SKIM_HARNESS_REVIEW_GH" api graphql -f query=x -F owner=skim-fixture -F name=repo -F number=9 2>&1)"
  code=$?
  ((code == 0)) && grep -q '"number":9' <<<"$out" && grep -q 'number=9' "$FAKE_GH_LOG" &&
    pass W4 "review fake serves review-9.json and logs number=9" ||
    fail W4 "review fake for PR 9: exit $code, output: ${out:0:120}"

  out="$("$SKIM_HARNESS_REVIEW_GH" pr view 999 --json baseRefName 2>&1)"
  code=$?
  ((code == 1)) && grep -q 'Could not resolve' <<<"$out" &&
    pass W5 "review fake rejects an unknown PR like gh (S10 boot 999)" ||
    fail W5 "review fake for PR 999: exit $code, output: ${out:0:120}"

  check_sync_kind W6 network 1 'dial tcp'
  check_sync_kind W7 unauthenticated 4 'gh auth login'

  [ ! -e "$SKIM_HARNESS_SYNC_DIR/missing/gh" ] && pass W8 "sync/missing/gh does not exist (spawn -> not_installed)" ||
    fail W8 "sync/missing/gh exists"

  [ -d "$HOME/.skim" ] && [ -z "$(ls -A "$HOME/.skim")" ] && [ -z "$(git config --global --list 2>/dev/null)" ] &&
    pass W9 "temp HOME has an empty .skim and git sees no global config" ||
    fail W9 "HOME=$HOME not isolated"

  [ "$SKIM_HARNESS_PR9_FILES" = 2 ] && pass W10 "PR 9's diff touches 2 files (feat_9.txt, shared.txt): S9 expects files.len == 2" ||
    fail W10 "PR 9's diff touches $SKIM_HARNESS_PR9_FILES files"

  [ "$(command -v gh)" = "$WORK/bin/gh" ] && [ "$(command -v gt)" = "$WORK/bin/gt" ] &&
    pass W11 "gh and gt on PATH are the fakes" || fail W11 "PATH gh=$(command -v gh) gt=$(command -v gt)"

  [ "$(grep -vc '^#' "$SKIM_HARNESS_TARGETS")" = 14 ] && pass W12 "targets.tsv lists 14 PRs (origin14 fixture)" ||
    fail W12 "targets.tsv does not list 14 PRs"
}

# check_sync_kind <id> <kind> <exit-code> <stderr-needle>: every SkimSync*
# operation fails through the launcher, and the call is logged.
check_sync_kind() {
  local id="$1" kind="$2" want_code="$3" needle="$4" op out code bad=""
  local launcher="$SKIM_HARNESS_SYNC_DIR/$kind/gh" log="$SKIM_HARNESS_SYNC_DIR/$kind/root/calls.log"
  for op in $(sync_ops); do
    out="$("$launcher" api graphql -f "query=query $op(\$owner: String!) { x }" -F owner=skim-fixture 2>&1 >/dev/null)"
    code=$?
    if ((code != want_code)) || ! grep -q "$needle" <<<"$out"; then
      bad="$op exit $code stderr '${out:0:80}'"
      break
    fi
  done
  if [ -z "$bad" ] && [ "$(wc -l <"$log")" -eq "$(sync_ops | wc -l)" ]; then
    pass "$id" "sync/$kind/gh fails all $(sync_ops | wc -l) SkimSync ops with exit $want_code and '$needle'; calls logged"
  else
    fail "$id" "sync/$kind/gh: ${bad:-call log has $(wc -l <"$log") lines}"
  fi
  : >"$log"
}

# =============================================================================
# Helpers
# =============================================================================

check_prerequisites() {
  local f missing=0
  for f in "$PREFETCH_DIR/setup-origin.sh" "$PREFETCH_DIR/lib.sh" "$PREFETCH_DIR/fake-gh" "$SYNC_FAKE" \
    "$SYNC_DIR/captured/network-failure.stderr" "$SYNC_DIR/captured/network-failure.code" \
    "$SYNC_DIR/captured/auth-failure.stderr" "$SYNC_DIR/captured/auth-failure.code"; do
    [ -e "$f" ] || { fail setup "prerequisite missing: $f"; missing=1; }
  done
  return $missing
}

cleanup() {
  if ((FAILS == 0)) && [ -z "${KEEP_WORK:-}" ]; then
    rm -rf "$WORK"
  else
    echo "kept WORK=$WORK"
  fi
}

skip_all() {
  local s
  for s in $IN_PROCESS S12; do echo "SKIP $s: $1"; done
}

pass() { echo "PASS $1: $2"; }

fail() {
  echo "FAIL $1: $2"
  FAILS=$((FAILS + 1))
}

main "$@"
