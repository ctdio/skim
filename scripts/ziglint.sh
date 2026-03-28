#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ZIGLINT_VERSION="v0.5.2"

cd "$PROJECT_ROOT"

if command -v ziglint >/dev/null 2>&1 && ziglint --version >/dev/null 2>&1; then
    exec ziglint "$@"
fi

if command -v mise >/dev/null 2>&1; then
    exec mise x "github:rockorager/ziglint@${ZIGLINT_VERSION}" -- ziglint "$@"
fi

echo "ziglint is not installed and mise is unavailable." >&2
echo "Install ziglint or mise, then re-run $0." >&2
exit 1
