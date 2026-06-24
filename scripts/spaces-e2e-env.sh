#!/usr/bin/env bash

spaces_e2e_load_env() {
  local root_dir="${1:?missing repository root}"
  local env_file="$root_dir/.env"

  if [[ ! -f "$env_file" ]]; then
    return 0
  fi

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

spaces_e2e_require_env() {
  local root_dir="${1:?missing repository root}"
  local env_file="$root_dir/.env"

  if [[ ! -f "$env_file" ]]; then
    echo "Error: required env file was not found at $env_file." >&2
    return 1
  fi

  spaces_e2e_load_env "$root_dir"
}

spaces_e2e_require_remote_host_env() {
  local root_dir="${1:?missing repository root}"

  spaces_e2e_require_env "$root_dir"
  if [[ -z "${SPACES_E2E_REMOTE_SSH_HOST:-}" ]]; then
    echo "Error: SPACES_E2E_REMOTE_SSH_HOST is required in $root_dir/.env for remote E2E." >&2
    return 1
  fi
}
