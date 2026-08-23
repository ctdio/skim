#!/usr/bin/env sh
# Build the wasm module and write it, gzipped, into the site's public directory.
# The landing-page hero fetches it from `/demo/skim.wasm.gz` at runtime.
#
# The site build runs this first (see the `pre*` scripts in site/package.json).
# It skips with a warning when zig is missing, so someone who only edits docs
# can still run the site: the hero then holds its loading panel, which reports
# the failure once the fetch for the missing module comes back.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$root/site/public/demo"

if ! command -v zig >/dev/null 2>&1; then
  echo "sync-web-assets: zig not found — skipping the wasm build." >&2
  echo "sync-web-assets: the hero will report a failed demo load." >&2
  exit 0
fi

cd "$root"
zig build web

# Only the module is a runtime asset. The site imports the loader straight from
# web/skim.js, so the bundler owns that file.
mkdir -p "$out"

# Ship the module pre-compressed. GitHub Pages does not reliably compress
# `application/wasm`, and the loader unpacks a `.gz` URL in the page, so this
# is what the visitor actually downloads.
gzip -9 -c zig-out/web/skim.wasm > "$out/skim.wasm.gz"

echo "sync-web-assets: wrote $(du -h "$out/skim.wasm.gz" | cut -f1) to site/public/demo/"
