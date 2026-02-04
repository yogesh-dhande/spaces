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
"$BIN" project create --db "$TMP_DB" --name smoke --repo-root /tmp --editor vscode --browser-tabs http://localhost:3000 >/dev/null
"$BIN" project update --db "$TMP_DB" --name smoke --editor cursor >/dev/null

LIST_OUT="$($BIN project list --db "$TMP_DB")"
echo "$LIST_OUT" | grep -q "smoke"
echo "$LIST_OUT" | grep -q "editor=cursor"

# Project window CRUD
"$BIN" project window add --db "$TMP_DB" --project smoke --name t1 --kind terminal --bundle-id com.apple.Terminal --display 1 --tile bottomRight --command 'echo hi' >/dev/null
WIN_LIST="$($BIN project window list --db "$TMP_DB" --project smoke)"
echo "$WIN_LIST" | grep -q "name=t1"
echo "$WIN_LIST" | grep -q "tile=bottomRight"

"$BIN" project window update --db "$TMP_DB" --project smoke --index 0 --tile topLeft >/dev/null
WIN_LIST2="$($BIN project window list --db "$TMP_DB" --project smoke)"
echo "$WIN_LIST2" | grep -q "tile=topLeft"

"$BIN" project window remove --db "$TMP_DB" --project smoke --index 0 >/dev/null
WIN_LIST3="$($BIN project window list --db "$TMP_DB" --project smoke || true)"
[[ -z "$WIN_LIST3" ]]

# Stream CRUD (without show/hide to avoid GUI dependencies)
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
"$BIN" stream create --db "$TMP_DB" --project smoke --stream s1 >/dev/null
STREAM_LIST="$($BIN stream list --db "$TMP_DB" --project smoke)"
echo "$STREAM_LIST" | grep -q $'\ts1\t'

# Active-state lifecycle checks (no configured windows required)
ACTIVE0="$($BIN list-active --db "$TMP_DB" || true)"
[[ -z "$ACTIVE0" ]]

"$BIN" show --db "$TMP_DB" --project smoke --stream s1 >/dev/null
ACTIVE1="$($BIN list-active --db "$TMP_DB")"
echo "$ACTIVE1" | grep -q $'smoke\ts1\t'

"$BIN" hide --db "$TMP_DB" --project smoke --stream s1 >/dev/null
ACTIVE2="$($BIN list-active --db "$TMP_DB" || true)"
[[ -z "$ACTIVE2" ]]

# Doctor output shape should include stream row
DOCTOR="$($BIN doctor --db "$TMP_DB" --project smoke --stream s1)"
echo "$DOCTOR" | grep -q $'smoke\ts1\twindows:'

"$BIN" stream destroy --db "$TMP_DB" --project smoke --stream s1 >/dev/null

"$BIN" project delete --db "$TMP_DB" --name smoke >/dev/null

echo "smoke_cli.sh: PASS"
