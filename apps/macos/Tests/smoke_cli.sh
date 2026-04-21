#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT_DIR/.build/debug/mx"

if [[ ! -x "$BIN" ]]; then
  echo "Building mx..."
  (cd "$ROOT_DIR" && swift build >/dev/null)
fi

TMP_HOME="$(mktemp -d /tmp/muxy-smoke-home.XXXXXX)"
trap 'rm -rf "$TMP_HOME"' EXIT
export HOME="$TMP_HOME"

# Project + workspace CRUD
TEST_REPO="$(mktemp -d /tmp/muxy-smoke-repo.XXXXXX)"
(
  cd "$TEST_REPO"
  git init -q
  git config user.email "smoke@example.com"
  git config user.name "smoke"
  echo hi > README.md
  git add README.md
  git commit -q -m init
)
"$BIN" project add --dir "$TEST_REPO" >/dev/null

LIST_OUT="$($BIN project list)"
echo "$LIST_OUT" | grep -q "$(basename "$TEST_REPO")"

JSON_ERR="$(mktemp)"
if "$BIN" project list --json >/dev/null 2>"$JSON_ERR"; then
  echo "expected --json to fail"
  exit 1
fi
grep -q -- "--json" "$JSON_ERR"

WS_LIST="$($BIN workspace list --project-dir "$TEST_REPO" --all)"
echo "$WS_LIST" | grep -q "^default"

WS_GET="$($BIN workspace get --dir "$TEST_REPO")"
echo "$WS_GET" | grep -q "^default"

echo "smoke_cli.sh: PASS"
