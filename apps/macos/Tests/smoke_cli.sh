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

# Workspace import + up
TEST_REPO="$(mktemp -d /tmp/spaces-smoke-repo.XXXXXX)"
(
  cd "$TEST_REPO"
  git init -q
  git config user.email "smoke@example.com"
  git config user.name "smoke"
  echo hi > README.md
  git add README.md
  git commit -q -m init
)

IMPORT_ERR="$(mktemp)"
if "$BIN" workspace import "$TEST_REPO" --title "smoke" --tooltip "smoke test" >/dev/null 2>"$IMPORT_ERR"; then
  echo "expected import without a registered project to fail"
  exit 1
fi
grep -q -- "Add the project in the app" "$IMPORT_ERR"

UP_ERR="$(mktemp)"
if "$BIN" workspace up "$TEST_REPO" >/dev/null 2>"$UP_ERR"; then
  echo "expected up without a registered workspace to fail"
  exit 1
fi
grep -q -- "Run \`spaces workspace import \\[path\\]\` first" "$UP_ERR"

UPDATE_ERR="$(mktemp)"
if "$BIN" workspace update "$TEST_REPO" >/dev/null 2>"$UPDATE_ERR"; then
  echo "expected update without metadata flags to fail"
  exit 1
fi
grep -q -- "at least one field" "$UPDATE_ERR"

echo "smoke_cli.sh: PASS"
