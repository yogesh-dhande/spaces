#!/usr/bin/env bash
set -euo pipefail

# Gates the Editor pane's web app (apps/macos/CodePaneWeb): its tests, its typecheck, its build, and
# that the checked-in bundle under Sources/spacesui/Resources/CodePane is exactly what the current
# source builds. Swift builds consume only the checked-in bundle and never run node, so without this
# lane a broken web change, or a source change committed without rebuilding the bundle, ships
# unnoticed. CI runs this script as its own job.

root="$(cd "$(dirname "$0")/.." && pwd)"
web="$root/CodePaneWeb"
bundle="$root/Sources/spacesui/Resources/CodePane"

cd "$web"

# `npm ci` (not `npm install`) so the lockfile alone decides what is installed and the build is
# reproducible. Preferring the npm cache keeps a warm run off the network.
echo "--- codepane web: npm ci"
npm ci --prefer-offline --no-audit --no-fund

echo "--- codepane web: tests"
npm run test

echo "--- codepane web: typecheck"
npm run typecheck

# Built into a scratch directory and compared, rather than built over the checked-in bundle and
# diffed through git: the comparison then holds for uncommitted and unstaged bundle edits alike
# and the lane never rewrites a tracked file. vite build is byte-for-byte deterministic (hashed
# filenames included) and identical across Node 22 and 24, so any difference is a stale bundle.
scratch="$(mktemp -d "${TMPDIR:-/tmp}/codepane-web-bundle.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

echo "--- codepane web: build"
npm run build -- --outDir "$scratch"

echo "--- codepane web: checked-in bundle matches the build"
if ! diff -r "$scratch" "$bundle"; then
  echo "error: $bundle is stale. Run 'npm run build' in apps/macos/CodePaneWeb and commit the result." >&2
  exit 1
fi
echo "codepane web lane: OK"
