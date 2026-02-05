#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT_DIR/.build/debug/agentmux"

if [[ ! -x "$BIN" ]]; then
  echo "Building agentmux..."
  (cd "$ROOT_DIR" && swift build >/dev/null)
fi

TMP_DB="$(mktemp /tmp/agentmux-smoke.XXXXXX.db)"
trap 'rm -f "$TMP_DB"' EXIT

# Project CRUD
"$BIN" project create --db "$TMP_DB" --name smoke --repo-root /tmp >/dev/null
"$BIN" project update --db "$TMP_DB" --name smoke --repo-root /tmp >/dev/null

LIST_OUT="$($BIN project list --db "$TMP_DB")"
echo "$LIST_OUT" | grep -q "smoke"

# Stream CRUD
TEST_REPO="/tmp/agentmux-smoke-repo"
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
"$BIN" project update --db "$TMP_DB" --name smoke --repo-root "$TEST_REPO" >/dev/null
"$BIN" stream create --db "$TMP_DB" --project smoke --stream s1 --display 1 --space 1 >/dev/null

STREAM_LIST="$($BIN stream list --db "$TMP_DB" --project smoke)"
echo "$STREAM_LIST" | grep -q $'\ts1\t'

echo "smoke_cli.sh: PASS"
