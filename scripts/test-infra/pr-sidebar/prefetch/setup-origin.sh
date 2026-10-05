#!/usr/bin/env bash
# Build the offline prefetch world (bare origin, seed, clone, fake gh,
# fixtures, targets.tsv) under $WORK. Prints WORK=<path> on success.
#
# Usage: WORK=/tmp/skim-prefetch-xyz setup-origin.sh
#        setup-origin.sh                 # creates a fresh mktemp dir
set -euo pipefail
source "$(dirname "$0")/lib.sh"

command -v git >/dev/null || { echo "SKIPPED: git not in PATH"; exit 0; }

WORK="${WORK:-$(mktemp -d /tmp/skim-prefetch-XXXX)}"
if [ -e "$WORK/origin.git" ]; then
  echo "setup-origin: $WORK already has a world; use a fresh WORK" >&2
  exit 1
fi
world_build "$WORK"
echo "WORK=$WORK"
