#!/bin/bash
# Offline PR-review world for the end-to-end harnesses. Source this file; it
# defines functions only.
#
#   world_setup <work_dir>   build the git world + fake gh under <work_dir>
#   skim_start <args...>     launch $SKIM in a fresh tmux session in the clone
#   wait_for_pane / pane_has / wait_for_log / log_count / send / ...
#
# Layout under <work_dir> (see verification-harness.md, Phase 1):
#   home/          HOME for skim (fresh ~/.skim: no cache, config or log bleed)
#   origin.git     bare repo: main, refs/pull/1/head (feat-a), refs/pull/2/head (feat-b)
#   clone/         cwd for skim; origin url https://github.com/fake/repo.git,
#                  redirected to origin.git with url.<path>.insteadOf
#   bin/gh         fake gh (offline/fake-gh), first on PATH
#   bin/gt         stub Graphite CLI that always fails (keeps a real gt out)
#   fixtures/      pr-list.json, review-1.json, review-2.json
#   fake-gh.conf   knobs read by the fake gh on every call
#   gh.log         one line per gh call: <kind>\x1f<argv...>
#   stderr.log     skim's stderr
#
# Markers the scenarios assert on:
#   PR #1 "Alpha change"  head feat-a: adds a_only.txt (ALPHA-ANCHOR-<n> lines),
#                         alpha_code.zig (~400 Zig lines), edits lib.zig + base.txt.
#                         Thread PRRT_A1 on a_only.txt line 3 (RIGHT), body ALPHA-THREAD-MARKER.
#   PR #2 "Bravo change"  head feat-b: adds b_only.txt (BRAVO-LINE-<n>),
#                         bravo_code.zig, different edits to lib.zig + base.txt. No threads.

WORLD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKIM_REPO_ROOT="$(cd "$WORLD_LIB_DIR/../../../.." && pwd)"
SKIM="${SKIM:-$SKIM_REPO_ROOT/zig-out/bin/skim}"
FAKE_REMOTE_URL="https://github.com/fake/repo.git"

# =============================================================================
# World construction
# =============================================================================

world_setup() {
  WORK="$1"
  mkdir -p "$WORK/home" "$WORK/bin" "$WORK/fixtures"
  : >"$WORK/gh.log"
  : >"$WORK/fake-gh.conf"
  cp "$WORLD_LIB_DIR/fake-gh" "$WORK/bin/gh"
  chmod +x "$WORK/bin/gh"
  # Shadow a real Graphite CLI: the PR picker runs `gt state` synchronously on
  # every list load, which stalls the UI for ~0.5s and breaks key timing.
  # Failing makes skim fall back to base_ref stacking, as without gt.
  printf '#!/bin/sh\nexit 1\n' >"$WORK/bin/gt"
  chmod +x "$WORK/bin/gt"

  # Isolated git identity/config so the user's ~/.gitconfig (signing, hooks,
  # pagers) never runs inside the world.
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME="Skim Harness" GIT_AUTHOR_EMAIL="harness@example.invalid"
  export GIT_COMMITTER_NAME="Skim Harness" GIT_COMMITTER_EMAIL="harness@example.invalid"

  world_git init -q --bare -b main "$WORK/origin.git" || return 1
  world_git clone -q "$WORK/origin.git" "$WORK/seed" 2>/dev/null || return 1
  local seed="$WORK/seed"
  world_git -C "$seed" checkout -q -b main

  printf 'base line 1\nbase line 2\nbase line 3\nbase line 4\nbase line 5\n' >"$seed/base.txt"
  gen_lib_zig "" >"$seed/lib.zig"
  world_git -C "$seed" add -A
  world_git -C "$seed" commit -q -m "base" || return 1

  world_git -C "$seed" checkout -q -b feat-a main
  gen_marker_file "ALPHA-ANCHOR" 40 >"$seed/a_only.txt"
  gen_code_zig "alpha" 400 >"$seed/alpha_code.zig"
  gen_lib_zig "alpha" >"$seed/lib.zig"
  sed -i 's/^base line 2$/base line 2 edited by ALPHA/' "$seed/base.txt"
  world_git -C "$seed" add -A
  world_git -C "$seed" commit -q -m "Alpha change" || return 1

  world_git -C "$seed" checkout -q -b feat-b main
  gen_marker_file "BRAVO-LINE" 40 >"$seed/b_only.txt"
  gen_code_zig "bravo" 400 >"$seed/bravo_code.zig"
  gen_lib_zig "bravo" >"$seed/lib.zig"
  sed -i 's/^base line 4$/base line 4 edited by BRAVO/' "$seed/base.txt"
  world_git -C "$seed" add -A
  world_git -C "$seed" commit -q -m "Bravo change" || return 1

  world_git -C "$seed" push -q origin main feat-a feat-b || return 1
  world_git -C "$seed" push -q origin "feat-a:refs/pull/1/head" "feat-b:refs/pull/2/head" || return 1
  SHA_A="$(world_git -C "$seed" rev-parse feat-a)"
  SHA_B="$(world_git -C "$seed" rev-parse feat-b)"

  world_git clone -q -b main "$WORK/origin.git" "$WORK/clone" 2>/dev/null || return 1
  world_git -C "$WORK/clone" remote set-url origin "$FAKE_REMOTE_URL"
  world_git -C "$WORK/clone" config "url.$WORK/origin.git.insteadOf" "$FAKE_REMOTE_URL"
  world_git -C "$WORK/clone" config user.name "Skim Harness"
  world_git -C "$WORK/clone" config user.email "harness@example.invalid"

  write_fixtures
}

# Self-check: the exact refspecs github.fetchRef uses resolve through insteadOf.
# Deletes the refs again so skim performs the real fetch.
world_selfcheck_fetch() {
  local clone="$WORK/clone" n
  for n in 1 2; do
    world_git -C "$clone" fetch --quiet origin "+pull/$n/head:refs/skim/pr-$n" || return 1
    world_git -C "$clone" update-ref -d "refs/skim/pr-$n" || return 1
  done
  world_git -C "$clone" fetch --quiet origin "+main:refs/remotes/origin/main" || return 1
}

world_git() {
  git -c init.defaultBranch=main -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}

write_fixtures() {
  cat >"$WORK/fixtures/pr-list.json" <<EOF
[
{"number":1,"title":"Alpha change","author":{"login":"alice"},"headRefName":"feat-a","baseRefName":"main","isDraft":false,"updatedAt":"2026-01-02T00:00:00Z","url":"https://github.com/fake/repo/pull/1","statusCheckRollup":[]},
{"number":2,"title":"Bravo change","author":{"login":"bob"},"headRefName":"feat-b","baseRefName":"main","isDraft":false,"updatedAt":"2026-01-01T00:00:00Z","url":"https://github.com/fake/repo/pull/2","statusCheckRollup":[]}
]
EOF

  cat >"$WORK/fixtures/review-1.json" <<EOF
{"data":{"viewer":{"login":"fake-viewer"},"repository":{"pullRequest":{
"id":"PR_A","number":1,"title":"Alpha change","body":"alpha body","author":{"login":"alice"},
"isDraft":false,"baseRefName":"main","headRefName":"feat-a","headRefOid":"$SHA_A","reviewDecision":"",
"statusCheckRollup":null,"commits":{"nodes":[]},
"reviews":{"pageInfo":{"hasNextPage":false},"nodes":[]},
"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false},"nodes":[
{"id":"PRRT_A1","isResolved":false,"isOutdated":false,"line":3,"startLine":null,"originalLine":3,"diffSide":"RIGHT","startDiffSide":null,"path":"a_only.txt","subjectType":"LINE",
"comments":{"pageInfo":{"hasNextPage":false},"nodes":[
{"id":"PRRC_A1","databaseId":101,"author":{"login":"alice"},"body":"ALPHA-THREAD-MARKER","createdAt":"2026-01-02T00:00:00Z","diffHunk":"@@ -0,0 +1,3 @@","pullRequestReview":{"id":"PRR_A_SUBMITTED","state":"COMMENTED"},"replyTo":null}
]}}
]}
}}}}
EOF

  cat >"$WORK/fixtures/review-2.json" <<EOF
{"data":{"viewer":{"login":"fake-viewer"},"repository":{"pullRequest":{
"id":"PR_B","number":2,"title":"Bravo change","body":"bravo body","author":{"login":"bob"},
"isDraft":false,"baseRefName":"main","headRefName":"feat-b","headRefOid":"$SHA_B","reviewDecision":"",
"statusCheckRollup":null,"commits":{"nodes":[]},
"reviews":{"pageInfo":{"hasNextPage":false},"nodes":[]},
"reviewThreads":{"totalCount":0,"pageInfo":{"hasNextPage":false},"nodes":[]}
}}}}
EOF
}

# Write a fake-gh knob (persisted in fake-gh.conf; read on every gh call).
fake_gh_set() {
  echo "$1=$2" >>"$WORK/fake-gh.conf"
}

gen_marker_file() {
  local prefix="$1" count="$2" i
  for ((i = 1; i <= count; i++)); do
    printf '%s-%03d\n' "$prefix" "$i"
  done
}

# ~400 distinct lines of Zig, so a PR diff gives the highlight worker real work.
gen_code_zig() {
  local tag="$1" lines="$2" i
  printf 'const std = @import("std");\n\n'
  for ((i = 1; i * 8 <= lines; i++)); do
    printf 'pub fn %s_fn_%03d(allocator: std.mem.Allocator, n: usize) ![]u8 {\n' "$tag" "$i"
    printf '    const buf = try allocator.alloc(u8, n + %d);\n' "$i"
    printf '    for (buf, 0..) |*b, idx| b.* = @intCast((idx * %d) %% 251);\n' "$i"
    printf '    if (n > %d) return error.TooLarge; // "%s" marker %d\n' "$((i * 3))" "$tag" "$i"
    printf '    const label = "%s-%03d";\n' "$tag" "$i"
    printf '    std.log.debug("{s} {d}", .{ label, n });\n'
    printf '    return buf;\n'
    printf '}\n'
  done
}

# A 600-line file whose every 20th line differs per tag, giving ~30 hunks in
# the same file (same file path in both PRs, so HunkKeys collide across diffs).
gen_lib_zig() {
  local tag="$1" i
  for ((i = 1; i <= 600; i++)); do
    if [ -n "$tag" ] && ((i % 20 == 0)); then
      printf 'pub const value_%03d: u32 = %d; // %s edit\n' "$i" "$((i * 7))" "$tag"
    else
      printf 'pub const value_%03d: u32 = %d;\n' "$i" "$i"
    fi
  done
}

# =============================================================================
# tmux driving
# =============================================================================

# skim_start [skim args...]  — env overrides via SKIM_ENV="K=V K2=V2"
skim_start() {
  SESSION="skim-harness-$$-${RANDOM}"
  local args="" a
  for a in "$@"; do args+=" $(printf '%q' "$a")"; done
  tmux new-session -d -s "$SESSION" -x "${PANE_W:-200}" -y "${PANE_H:-50}" \
    "cd $(printf '%q' "$WORK/clone") && env HOME=$(printf '%q' "$WORK/home") XDG_CONFIG_HOME=$(printf '%q' "$WORK/home/.config") XDG_CACHE_HOME=$(printf '%q' "$WORK/home/.cache") PATH=$(printf '%q' "$WORK/bin:$PATH") ${SKIM_ENV:-} $(printf '%q' "$SKIM")$args 2>$(printf '%q' "$WORK/stderr.log"); echo SKIM-EXITED-\$?; sleep 600"
}

skim_stop() {
  [ -n "${SESSION:-}" ] && tmux kill-session -t "$SESSION" 2>/dev/null
  SESSION=""
}

pane() {
  tmux capture-pane -p -t "$SESSION" 2>/dev/null
}

pane_has() {
  pane | grep -qE -- "$1"
}

# send <tmux key>...  (tmux send-keys names: Enter, Escape, C-j, C-s, ...)
send() {
  tmux send-keys -t "$SESSION" "$@"
}

# type_text <literal text>
type_text() {
  tmux send-keys -t "$SESSION" -l -- "$1"
}

# wait_for_pane <regex> <timeout_s>
wait_for_pane() {
  local re="$1" deadline=$((SECONDS + ${2:-10}))
  while ((SECONDS < deadline)); do
    pane_has "$re" && return 0
    sleep 0.1
  done
  pane_has "$re"
}

# wait_for_pane_gone <regex> <timeout_s>
wait_for_pane_gone() {
  local re="$1" deadline=$((SECONDS + ${2:-10}))
  while ((SECONDS < deadline)); do
    pane_has "$re" || return 0
    sleep 0.1
  done
  ! pane_has "$re"
}

# log_count <regex>  — gh.log lines matching (fields are \x1f-separated)
log_count() {
  grep -cE -- "$1" "$WORK/gh.log" 2>/dev/null || true
}

# wait_for_log <regex> <min_count> <timeout_s>
wait_for_log() {
  local re="$1" min="${2:-1}" deadline=$((SECONDS + ${3:-10}))
  while ((SECONDS < deadline)); do
    (($(log_count "$re") >= min)) && return 0
    sleep 0.1
  done
  (($(log_count "$re") >= min))
}

# gh.log rendered readable (\x1f -> " | ")
log_readable() {
  tr '\037' '|' <"$WORK/gh.log" | sed 's/|/ | /g'
}

skim_alive() {
  [ "$(tmux list-panes -t "$SESSION" -F '#{pane_dead}' 2>/dev/null)" = "0" ] && ! pane_has 'SKIM-EXITED-'
}

stderr_has_crash() {
  grep -qE 'panic|Segmentation|reached unreachable|General protection' "$WORK/stderr.log" 2>/dev/null
}

# Open the command palette in command mode and run the first match for <query>.
palette_run() {
  send ':'
  sleep 0.2
  type_text "$1"
  sleep 0.3
  send Enter
}
