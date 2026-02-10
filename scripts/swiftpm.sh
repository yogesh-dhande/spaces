#!/bin/sh
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cache_dir="$root/.build/spm-cache"
config_dir="$root/.build/spm-config"
security_dir="$root/.build/spm-security"
clang_cache_dir="$root/.build/clang-module-cache"

mkdir -p "$cache_dir" "$config_dir" "$security_dir" "$clang_cache_dir"
export CLANG_MODULE_CACHE_PATH="$clang_cache_dir"

disable_sandbox=1
for arg in "$@"; do
  if [ "$arg" = "--disable-sandbox" ]; then
    disable_sandbox=0
    break
  fi
done

if [ "$disable_sandbox" -eq 1 ]; then
  set -- "$@" --disable-sandbox
fi

exec swift "$@" \
  --cache-path "$cache_dir" \
  --config-path "$config_dir" \
  --security-path "$security_dir"
