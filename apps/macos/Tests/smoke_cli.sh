#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT_DIR/.build/debug/spaceship"

if [[ ! -x "$BIN" ]]; then
  echo "Building spaceship..."
  (cd "$ROOT_DIR" && swift build >/dev/null)
fi

TMP_HOME="$(mktemp -d /tmp/spaceship-smoke-home.XXXXXX)"
trap 'rm -rf "$TMP_HOME"' EXIT
export HOME="$TMP_HOME"

# Project + workspace CRUD
TEST_REPO="/tmp/spaceship-smoke-repo"
rm -rf "$TEST_REPO"
mkdir -p "$TEST_REPO"
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

"$BIN" workspace create --project-dir "$TEST_REPO" --name s1 >/dev/null

WS_LIST="$($BIN workspace list --project-dir "$TEST_REPO" --all)"
echo "$WS_LIST" | grep -q $'\ts1\t'

echo "smoke_cli.sh: PASS"
