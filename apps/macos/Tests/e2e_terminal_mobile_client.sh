#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

pkill -x Spaces >/dev/null 2>&1 || true

python3 apps/macos/Tests/poc_mobile_terminal_client.py --transport tcp
