#!/usr/bin/env bash
# Phase 6b world mutations for the PR surface harness. The in-process
# scenarios (H3, H4a, H4b, H5) shell out to this between asserted steps, never
# inside one; surface-harness.sh --check-world runs every op once. Reuses
# Phase 5's prefetch/lib.sh (pgit, tick, seed_commit, tsv_*, fixtures).
#
# Usage: WORK=<world> flip-world.sh <op>     (WORK defaults to $SKIM_HARNESS_WORK)
#   rewrite-pr5    Rewritten history (H4a, H5). Once per world, main gains a
#                  commit inserting 3 lines at the top of shared.txt. feat-5 is
#                  rebased onto main (its shared.txt edit shifts down 3 lines)
#                  and its second feat_5.txt line changes. shared.txt's +/-
#                  lines stay identical; only hunk numbers move.
#   ff-pr14        Fast-forward (H4b): one commit adding inc.txt on top of feat-14.
#   drop-file-pr9  H3 orphan: PR 9's commit no longer adds feat_9.txt.
#
# Each op pushes the branch and refs/pull/N/head to origin, updates
# targets.tsv (head_oid, updated_at; base_oid too for rewrite-pr5), rewrites
# fixtures/review-N.json and files-N.txt, and prints "old=<oid> new=<oid>".
# Re-seeding the DB from targets.tsv is the caller's job (what sync would do).
set -euo pipefail

WORK="${WORK:-${SKIM_HARNESS_WORK:?WORK or SKIM_HARNESS_WORK must be set}}"
source "$(dirname "${BASH_SOURCE[0]}")/prefetch/lib.sh"

main() {
  [ -d "$WORK/seed" ] || { echo "flip-world: $WORK has no seed clone" >&2; exit 1; }
  case "${1:-}" in
    rewrite-pr5) rewrite_pr5 ;;
    ff-pr14) ff_pr14 ;;
    drop-file-pr9) drop_file_pr9 ;;
    files) write_files_lists ;;
    *)
      echo "usage: flip-world.sh rewrite-pr5|ff-pr14|drop-file-pr9|files" >&2
      exit 2
      ;;
  esac
}

rewrite_pr5() {
  local seed="$WORK/seed" old new main_tip round
  old="$(tsv_get 5 head_oid)"
  round="$(bump 5)"

  pgit -C "$seed" checkout -q main
  if ! grep -q '^inserted by flip-world' "$seed/shared.txt"; then
    { printf 'inserted by flip-world 1\ninserted by flip-world 2\ninserted by flip-world 3\n'; cat "$seed/shared.txt"; } >"$seed/shared.tmp"
    mv "$seed/shared.tmp" "$seed/shared.txt"
    seed_commit "main: insert above shared"
    pgit -C "$seed" push -q origin main
  fi
  main_tip="$(pgit -C "$seed" rev-parse main)"

  pgit -C "$seed" checkout -q feat-5
  tick
  pgit -C "$seed" rebase -q main >/dev/null
  sed -i "s/^feat-5 line 2.*\$/feat-5 line 2 rewrite $round/" "$seed/feat_5.txt"
  pgit -C "$seed" add -A
  tick
  pgit -C "$seed" commit -q --amend -m "feat-5 (rewritten $round)"
  new="$(pgit -C "$seed" rev-parse HEAD)"
  pgit -C "$seed" push -q -f origin feat-5 "+feat-5:refs/pull/5/head"
  pgit -C "$seed" checkout -q main

  # GitHub reports the current trunk tip as baseRefOid.
  tsv_set 5 base_oid "$main_tip"
  record_push 5 "$new" "$round"
  echo "old=$old new=$new"
}

ff_pr14() {
  local seed="$WORK/seed" old new round
  old="$(tsv_get 14 head_oid)"
  round="$(bump 14)"
  pgit -C "$seed" checkout -q feat-14
  printf 'incremental %s\n' "$round" >"$seed/inc.txt"
  seed_commit "feat-14: incremental $round"
  new="$(pgit -C "$seed" rev-parse HEAD)"
  pgit -C "$seed" push -q origin feat-14 "+feat-14:refs/pull/14/head"
  pgit -C "$seed" checkout -q main
  record_push 14 "$new" "$round"
  echo "old=$old new=$new"
}

drop_file_pr9() {
  local seed="$WORK/seed" old new round
  old="$(tsv_get 9 head_oid)"
  round="$(bump 9)"
  pgit -C "$seed" checkout -q feat-9
  pgit -C "$seed" rm -q --ignore-unmatch feat_9.txt
  tick
  pgit -C "$seed" commit -q --amend -m "feat-9 (feat_9.txt dropped)"
  new="$(pgit -C "$seed" rev-parse HEAD)"
  pgit -C "$seed" push -q -f origin feat-9 "+feat-9:refs/pull/9/head"
  pgit -C "$seed" checkout -q main
  record_push 9 "$new" "$round"
  echo "old=$old new=$new"
}

# record_push <number> <new-head> <round>: what a sync after the push would see.
record_push() {
  tsv_set "$1" head_oid "$2"
  tsv_set "$1" updated_at "$(updated_at_for "$1" "$3")"
  write_review_fixture "$1"
  write_files_list "$1"
}

# files-N.txt: the paths of `main...refs/pull/N/head` in origin, one per line
# in git's order (what both the miss path and the cached diff show).
write_files_lists() {
  local n
  for n in $(tsv_numbers); do write_files_list "$n"; done
}

write_files_list() {
  pgit -C "$WORK/origin.git" diff --name-only "main...refs/pull/$1/head" >"$WORK/files-$1.txt" 2>/dev/null ||
    rm -f "$WORK/files-$1.txt"
}

# Per-PR push counter (1, 2, ...): updated_at bump index and rewrite marker.
bump() {
  local file="$WORK/bump-$1" n=0
  [ -f "$file" ] && n="$(cat "$file")"
  n=$((n + 1))
  echo "$n" >"$file"
  echo "$n"
}

main "$@"
