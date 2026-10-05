#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../../.."
zig build harness-pr-sync 2>&1 | tee /tmp/pr-sync-harness.log
