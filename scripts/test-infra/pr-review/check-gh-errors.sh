#!/bin/bash
# Diagnostic: probe the REAL `gh` failure paths and assert the stderr substrings
# that `github.classifyGhFailure(exit_code, stderr)` must string-match on.
#
# Why this exists: classifyGhFailure is a pure function, but its correctness is
# entirely a function of strings gh actually emits — which are NOT what docs or
# intuition suggest. This script pins the ground-truth strings so the unit tests
# use real fixtures. Notable finding (gh 2.45.0): `not_authenticated` has TWO
# distinct forms depending on whether auth is absent vs. invalid.
#
# Usage:  ./check-gh-errors.sh
# Exit 0 = PASS or SKIP; Exit 1 = FAIL (a probe produced an unexpected string).

set -u

command -v gh >/dev/null 2>&1 || { echo "SKIP: gh not in PATH"; exit 0; }
gh auth status >/dev/null 2>&1 || { echo "SKIP: gh not authenticated (probes need a working baseline)"; exit 0; }

Q='{ viewer { login } }'
PRQ='query($o:String!,$n:String!,$p:Int!){repository(owner:$o,name:$n){pullRequest(number:$p){id}}}'
fail=0

probe() { # <label> <expected-substring> ; command runs on fd, stderr captured
  local label="$1" expect="$2"
  shift 2
  local err ec
  err="$("$@" 2>&1 >/dev/null)"
  ec=$?
  if echo "$err" | grep -qiF "$expect"; then
    echo "  PASS: [$label] exit=$ec stderr matches \"$expect\""
    echo "        stderr: $(echo "$err" | head -1)"
  else
    echo "  FAIL: [$label] exit=$ec stderr MISSING \"$expect\""
    echo "        stderr: $err"
    fail=1
  fi
}

echo "Probing real gh failure stderr (ground truth for classifyGhFailure):"

# not_found — bogus PR number and bogus repo both use "Could not resolve to a".
probe "not_found (bad PR number)" "Could not resolve to a PullRequest" \
  gh api graphql -f query="$PRQ" -f o=ziglang -f n=zig -F p=999999999

probe "not_found (bad repo)" "Could not resolve to a Repository" \
  gh api graphql -f query="$PRQ" -f o=ziglang -f n=no-such-repo-xyz-000 -F p=1

# not_authenticated form A: invalid token -> 401 Bad credentials (exit 1).
probe "not_authenticated (bad token)" "Bad credentials" \
  env GH_TOKEN=ghp_invalidtoken00000000000000000000000 gh api graphql -f query="$Q"

# not_authenticated form B: no auth configured at all -> "gh auth login" (exit 4).
EMPTY_CFG="$(mktemp -d)"
probe "not_authenticated (no auth)" "gh auth login" \
  env -u GH_TOKEN -u GITHUB_TOKEN GH_CONFIG_DIR="$EMPTY_CFG" gh api graphql -f query="$Q"
rm -rf "$EMPTY_CFG"

# network — unreachable host.
probe "network (unreachable host)" "connect" \
  env -u GH_TOKEN -u GITHUB_TOKEN GH_HOST=nonexistent.invalid gh api graphql -f query="$Q"

echo ""
echo "not_installed is NOT a stderr case: Child.run yields error.FileNotFound when"
echo "gh is absent (github.zig already maps this to Error.GhNotFound). classifyGhFailure"
echo "never sees it; the caller maps the spawn error directly to .not_installed."
echo ""
echo "rate_limited is not triggerable on demand; documented substring: \"API rate limit\"."
echo ""
echo "Classification table classifyGhFailure MUST implement:"
echo "  spawn error.FileNotFound          -> .not_installed"
echo "  stderr ~ 'gh auth login'          -> .not_authenticated"
echo "  stderr ~ 'Bad credentials' / '401'-> .not_authenticated"
echo "  stderr ~ 'Could not resolve to a' -> .not_found"
echo "  stderr ~ 'API rate limit'         -> .rate_limited"
echo "  stderr ~ 'connect' / 'internet'   -> .network"
echo "  else                              -> .other"

if [ "$fail" -eq 0 ]; then echo ""; echo "PASS: all probed stderr strings matched."; exit 0
else echo ""; echo "FAIL: gh stderr strings drifted — update classifyGhFailure fixtures."; exit 1; fi
