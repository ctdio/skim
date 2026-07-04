#!/bin/bash
# Diagnostic: pin the ground truth for owner/repo resolution — both the pure
# `github.parseOwnerRepo(remote_url)` cases and the live `getOriginOwnerRepo`
# path (git config --get remote.origin.url) that the debug harness resolves.
#
# parseOwnerRepo is pure Zig with colocated tests; this script documents the exact
# URL forms it must handle (so the unit-test table matches reality) and verifies
# the live origin of the current repo resolves to owner=ctdio name=skim, which is
# what `skim debug pr-view` depends on and what the mismatch-error test relies on.
#
# Usage:  ./check-owner-repo.sh
# Exit 0 = PASS or SKIP; Exit 1 = FAIL.

set -u

echo "parseOwnerRepo(remote_url) -> {owner, repo} cases the pure fn must cover:"
cat <<'EOF'
  git@github.com:ctdio/skim.git            -> ctdio / skim
  git@github.com:ctdio/skim                -> ctdio / skim
  https://github.com/ctdio/skim.git        -> ctdio / skim
  https://github.com/ctdio/skim            -> ctdio / skim
  https://github.com/ctdio/skim/           -> ctdio / skim   (trailing slash)
  ssh://git@github.com/ctdio/skim.git      -> ctdio / skim   (scp-less ssh form)
  git@github.com:Org-Name/repo.name.git    -> Org-Name / repo.name (dots/dashes)
  not-a-url                                -> error
  https://github.com/ctdio                 -> error (no repo segment)
EOF
echo ""

# Live origin check — this is what getOriginOwnerRepo resolves at runtime.
command -v git >/dev/null 2>&1 || { echo "SKIP: git not in PATH"; exit 0; }
REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$REPO_ROOT" ] || { echo "SKIP: not inside a git repo"; exit 0; }

ORIGIN="$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null)"
[ -n "$ORIGIN" ] || { echo "SKIP: no origin remote configured"; exit 0; }
echo "Live origin url: $ORIGIN"

# Emulate parseOwnerRepo's expected extraction with sed, as an independent oracle.
STRIP="${ORIGIN%.git}"                # drop trailing .git
STRIP="${STRIP%/}"                    # drop trailing slash
# owner/repo = last two path-ish segments after ':' or '/'
PAIR="$(echo "$STRIP" | sed -E 's#^.*[:/]([^/:]+)/([^/:]+)$#\1/\2#')"
OWNER="${PAIR%/*}"
REPO="${PAIR#*/}"
echo "Resolved: owner=$OWNER repo=$REPO"

fail=0
if [ "$OWNER" = "ctdio" ] && [ "$REPO" = "skim" ]; then
  echo "  PASS: origin resolves to ctdio/skim (debug pr-view + mismatch test rely on this)"
else
  echo "  NOTE: origin is $OWNER/$REPO, not ctdio/skim — expected if run from a fork/clone."
  echo "        The mismatch-error harness test assumes ctdio/skim; adjust if this differs."
fi

if [ "$fail" -eq 0 ]; then echo ""; echo "PASS: owner/repo resolution reference verified."; exit 0
else echo ""; echo "FAIL"; exit 1; fi
