#!/usr/bin/env bash

spaces_e2e_load_env() {
  local root_dir="${1:?missing repository root}"
  if [[ "${SPACES_SKIP_ENV_FILE:-0}" == "1" ]]; then
    return 0
  fi

  local env_file="${SPACES_ENV_FILE:-$root_dir/.env}"
  [[ -f "$env_file" ]] || return 0

  local had_allexport=0
  case "$-" in
    *a*) had_allexport=1 ;;
  esac

  set -a
  # shellcheck source=/dev/null
  source "$env_file"
  if [[ "$had_allexport" == "0" ]]; then
    set +a
  fi
}
