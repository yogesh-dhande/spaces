#!/usr/bin/env bash
set -euo pipefail

REPO="${1:-.}"
REPO_ABS="$(cd "$REPO" && pwd)"

# Exclude heavy/noisy dirs
find "$REPO_ABS" \
  -path "$REPO_ABS/.git" -prune -o \
  -path "$REPO_ABS/node_modules" -prune -o \
  -path "$REPO_ABS/.venv" -prune -o \
  -path "$REPO_ABS/dist" -prune -o \
  -path "$REPO_ABS/build" -prune -o \
  -type f -print0 \
| xargs -0 stat -f "%m %N" \
| sort -nr \
| head -n 1 \
| awk '{ $1=""; sub(/^ /,""); print }'
