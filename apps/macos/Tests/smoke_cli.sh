#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT_DIR/.build/debug/spaces"

if [[ ! -x "$BIN" ]]; then
  echo "Building spaces..."
  (cd "$ROOT_DIR" && swift build >/dev/null)
fi

TMP_HOME="$(mktemp -d /tmp/spaces-smoke-home.XXXXXX)"
trap 'rm -rf "$TMP_HOME"' EXIT
export HOME="$TMP_HOME"

HELP_OUT="$(mktemp)"
"$BIN" --help >"$HELP_OUT"
grep -q -- "project" "$HELP_OUT"
grep -q -- "workspace" "$HELP_OUT"
grep -q -- "agent" "$HELP_OUT"
grep -q -- "terminal" "$HELP_OUT"
grep -q -- "mcp" "$HELP_OUT"
if grep -q -- "import" "$HELP_OUT"; then
  echo "expected public import command to be absent"
  exit 1
fi

"$BIN" project list >/dev/null
"$BIN" workspace list >/dev/null
"$BIN" terminal list >/dev/null

START_ERR="$(mktemp)"
if "$BIN" workspace start --workspace missing >/dev/null 2>"$START_ERR"; then
  echo "expected workspace start with an unknown ID to fail"
  exit 1
fi
grep -q -- "Workspace not found" "$START_ERR"

echo "smoke_cli.sh: PASS"
