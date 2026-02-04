#!/usr/bin/env bash
set -euo pipefail

REPO="${1:-.}"
REPO_ABS="$(cd "$REPO" && pwd)"

cd "$REPO_ABS"

# Open repo
surf .

# Get top 3 recent files
FILES="$(./recent_files.sh "$REPO_ABS")"

echo "$FILES"
# Open them (word-splitting is safe because each line is one path)
if [ -n "$FILES" ]; then
  surf $FILES
fi