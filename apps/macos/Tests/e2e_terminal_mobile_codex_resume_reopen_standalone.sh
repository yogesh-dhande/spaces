#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
THREAD_ID="${SPACES_MOBILE_CODEX_RESUME_THREAD_ID:-019e380a-9def-7852-9834-74c67b2da894}"

SPACES_MOBILE_CODEX_COMMAND="codex resume $THREAD_ID" \
SPACES_MOBILE_REOPEN_SAME_SESSION=1 \
  exec "$SCRIPT_DIR/e2e_terminal_mobile_codex_standalone.sh"
