#!/bin/bash
# THE highest-value live check for Phase 2 (per verification-harness.md).
#
# Proves AD-6's core assumption against a REAL PR, end-to-end, WITHOUT depending
# on the not-yet-built `skim debug pr-anchor`: it replicates skim's exact diff
# command and skim's resolveNewLine/resolveOldLine math in pure git+awk, then
# asserts that the line skim WOULD anchor each non-outdated inline thread to has
# content byte-identical to the LAST line of that comment's GitHub diffHunk (the
# line GitHub itself anchored against). A pass means: GitHub `line`/`diffSide`
# maps cleanly onto skim's `new_lineno`/`old_lineno` under
# `-U10 origin/<base>...refs/skim/pr-<n>` (merge-base). A fail means off-by-one,
# LEFT/RIGHT vs old/new swap, or merge-base drift — a WRONG-LINE anchor that the
# totality invariant alone can NEVER catch.
#
# skim's exact PR diff (see app.zig enterReviewDiff + git/diff.zig getDiff):
#   git diff --no-color --no-ext-diff -U10 origin/<base>...refs/skim/pr-<n>
# skim's ref fetch (see github.fetchRef):
#   git fetch origin +pull/<n>/head:refs/skim/pr-<n>   (+ best-effort base)
#
# Usage:  ./verify-anchor-groundtruth.sh [owner name number [base]]
#   defaults: ziglang zig 26001 master
#   Reuse a clone (skip the expensive re-clone) with:
#     SKIM_ANCHOR_WORKDIR=/path/to/existing/clone ./verify-anchor-groundtruth.sh ...
#
# Exit 0 = PASS or SKIP (no gh/network, or no inline thread => nothing to check);
# Exit 1 = FAIL (a real wrong-line anchor — investigate AD-6 before shipping).

set -u

OWNER="${1:-ziglang}"
NAME="${2:-zig}"
NUMBER="${3:-26001}"
BASE_ARG="${4:-}"

command -v gh  >/dev/null 2>&1 || { echo "SKIP: gh not in PATH"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not in PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not in PATH"; exit 0; }
gh auth status >/dev/null 2>&1 || { echo "SKIP: gh not authenticated"; exit 0; }

# ---- 1. thread ground truth (path, line, side, diffHunk tail) --------------
THREADS_JSON=$(gh api graphql -f query='
  query($owner:String!,$name:String!,$number:Int!){
    repository(owner:$owner,name:$name){
      pullRequest(number:$number){
        baseRefName
        reviewThreads(first:100){ nodes{
          isOutdated line diffSide subjectType path
          comments(first:1){ nodes{ diffHunk } }
        }}
      }
    }
  }' -f owner="$OWNER" -f name="$NAME" -F number="$NUMBER" 2>/tmp/gt-gh-err.log) || {
    echo "FAIL: gh api graphql exited nonzero"; cat /tmp/gt-gh-err.log; exit 1;
  }

BASE="${BASE_ARG:-$(echo "$THREADS_JSON" | jq -r '.data.repository.pullRequest.baseRefName')}"

# TSV: path \t line \t side \t diffHunkTail(marker-stripped)
TSV=$(echo "$THREADS_JSON" | jq -r '
  .data.repository.pullRequest.reviewThreads.nodes[]
  | select(.isOutdated==false and .line!=null and .subjectType=="LINE")
  | [ .path, (.line|tostring), .diffSide,
      (.comments.nodes[0].diffHunk | split("\n") | .[-1] | .[1:]) ]
  | @tsv')

if [ -z "$TSV" ]; then
  echo "SKIP: PR #$NUMBER has no non-outdated inline thread — nothing to verify."
  echo "      Run find-inline-thread-pr.sh to pick a PR that does."
  exit 0
fi

echo "Ground-truth targets (non-outdated inline threads on #$NUMBER, base=$BASE):"
echo "$TSV" | while IFS=$'\t' read -r p l s _; do echo "  $p  line=$l  side=$s"; done

# ---- 2. clone/fetch + skim's exact diff ------------------------------------
CLEANUP=""
if [ -n "${SKIM_ANCHOR_WORKDIR:-}" ]; then
  WORK="$SKIM_ANCHOR_WORKDIR"
  mkdir -p "$WORK"
else
  WORK=$(mktemp -d); CLEANUP="$WORK"
fi
trap '[ -n "$CLEANUP" ] && rm -rf "$CLEANUP"' EXIT
REPO="$WORK/repo"

if [ ! -d "$REPO/.git" ]; then
  echo "Cloning $OWNER/$NAME (blobless, one-time)..."
  git clone --quiet --filter=blob:none "https://github.com/$OWNER/$NAME" "$REPO" 2>/tmp/gt-clone.log || {
    echo "SKIP: clone failed (network?)"; cat /tmp/gt-clone.log; exit 0;
  }
fi

cd "$REPO" || { echo "FAIL: cannot cd $REPO"; exit 1; }
git fetch --quiet origin "+pull/$NUMBER/head:refs/skim/pr-$NUMBER" 2>/tmp/gt-fetch.log || {
  echo "SKIP: could not fetch PR ref (network?)"; cat /tmp/gt-fetch.log; exit 0;
}
# base fetch is best-effort, exactly like skim (origin/<base> may already exist)
git fetch --quiet origin "+$BASE:refs/remotes/origin/$BASE" 2>/dev/null || true

DIFF=$(git diff --no-color --no-ext-diff -U10 "origin/$BASE...refs/skim/pr-$NUMBER" 2>/tmp/gt-diff.log) || {
  echo "FAIL: skim's diff command errored"; cat /tmp/gt-diff.log; exit 1;
}
[ -n "$DIFF" ] || { echo "FAIL: diff was empty (base/ref resolution?)"; exit 1; }

# ---- 3. resolve each thread the way skim's LineResolver would, compare -----
fail=0
checked=0
while IFS=$'\t' read -r path line side tail; do
  [ -z "$path" ] && continue
  ACTUAL=$(printf '%s\n' "$DIFF" | awk -v want_file="$path" -v side="$side" -v target="$line" '
    function reset(){ infile=0 }
    /^diff --git / { reset(); next }
    /^\+\+\+ b\// { cur=substr($0,7); infile=(cur==want_file); next }
    /^\+\+\+ / { infile=0; next }
    !infile { next }
    /^@@ / {
      oldno=0; newno=0;
      for(i=1;i<=NF;i++){
        if($i ~ /^-[0-9]/){ t=substr($i,2); sub(/,.*/,"",t); oldno=t+0 }
        else if($i ~ /^\+[0-9]/){ t=substr($i,2); sub(/,.*/,"",t); newno=t+0 }
      }
      next
    }
    /^\\/ { next }                                  # "\ No newline at end of file"
    /^-/ {                                          # delete: LEFT/old only
      if(side=="LEFT" && oldno==target){ print substr($0,2); found=1 }
      oldno++; next
    }
    /^\+/ {                                         # add: RIGHT/new only
      if(side=="RIGHT" && newno==target){ print substr($0,2); found=1 }
      newno++; next
    }
    /^ / {                                          # context: both sides
      if((side=="RIGHT" && newno==target)||(side=="LEFT" && oldno==target)){ print substr($0,2); found=1 }
      oldno++; newno++; next
    }
    END{ if(!found) print "<<NOT-IN-DIFF>>" }
  ')
  checked=$((checked+1))
  if [ "$ACTUAL" = "<<NOT-IN-DIFF>>" ]; then
    echo "  INFO: $path:$line ($side) not in -U10 context -> skim would bucket(out_of_context). Not a correctness failure."
  elif [ "$ACTUAL" = "$tail" ]; then
    echo "  PASS: $path:$line ($side) -> [$ACTUAL]"
  else
    echo "  FAIL: $path:$line ($side) WRONG-LINE anchor"
    echo "        skim would anchor to: [$ACTUAL]"
    echo "        diffHunk tail expects: [$tail]"
    fail=1
  fi
done <<< "$TSV"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "PASS: all $checked inline thread(s) anchor to the correct line (AD-6 holds live)."
  exit 0
else
  echo "FAIL: at least one wrong-line anchor — AD-6's side/merge-base mapping is broken."
  exit 1
fi
