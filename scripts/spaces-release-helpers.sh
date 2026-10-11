#!/usr/bin/env bash

# Shared helpers for the macOS release scripts. create-app-bundle.sh and
# verify-release-artifacts.sh check that shipped binaries carry both Apple
# Silicon and Intel slices; this file is their single source of truth for that
# check. create-dmg.sh builds its image through spaces_release_create_dmg so a
# regression test runs the same hdiutil call the release does.
#
# create-dmg.sh also copies libghostty-vt dylibs (mirroring a shape of
# create-app-bundle.sh's dylib handling), but that copy runs inside an
# installer script embedded in the DMG that executes standalone on the
# end user's Mac after install, with no repository checkout to source from.
# That logic is intentionally left un-shared here; see the dylib-copying
# section of the accompanying refactor notes for why.

# True when $2 appears as a space-delimited token in $1 (a `lipo -archs`
# space-separated architecture list, e.g. "arm64 x86_64").
spaces_release_binary_has_arch() {
  local archs="$1"
  local arch="$2"
  case " $archs " in
    *" $arch "* ) return 0 ;;
    * ) return 1 ;;
  esac
}

# Verifies that the binary at $1 (described as $2 in messages) exists and is
# a universal arm64+x86_64 Mach-O binary, exiting 1 with an "Error: ..."
# message on stderr otherwise. This is create-app-bundle.sh's original
# require_universal_macos_binary: it tolerates `lipo` itself failing (e.g. on
# a not-yet-copied or non-Mach-O candidate) by treating that the same as an
# empty architecture list, and reports both missing architectures in one
# combined message.
#
# verify-release-artifacts.sh's check differs in two ways it relies on
# (see spaces_release_require_universal_binary_verbose below): it prints an
# informational "$label architectures: $archs" line before checking, and it
# lets a `lipo` failure abort the script via `set -e` with lipo's own error
# text rather than treating it as an empty list.
spaces_release_require_universal_binary() {
  local binary_path="$1"
  local label="$2"
  local archs

  if [[ ! -f "$binary_path" ]]; then
    echo "Error: Missing $label at $binary_path" >&2
    exit 1
  fi

  archs="$(lipo -archs "$binary_path" 2>/dev/null || true)"
  if ! spaces_release_binary_has_arch "$archs" arm64 || ! spaces_release_binary_has_arch "$archs" x86_64; then
    echo "Error: $label must be universal arm64+x86_64, but found: ${archs:-unknown} ($binary_path)" >&2
    exit 1
  fi
}

# verify-release-artifacts.sh's original require_universal_binary: prints the
# architecture list for every checked binary, does not suppress a `lipo`
# failure (an unreadable/non-Mach-O binary aborts the script via `set -e`
# with lipo's own stderr and exit status), and reports a missing arm64 slice
# and a missing x86_64 slice as two distinct single-architecture messages
# rather than one combined message.
spaces_release_require_universal_binary_verbose() {
  local binary_path="$1"
  local label="$2"
  local archs

  if [[ ! -f "$binary_path" ]]; then
    echo "Error: Missing $label at $binary_path" >&2
    exit 1
  fi

  archs="$(lipo -archs "$binary_path")"
  echo "$label architectures: $archs"

  if ! spaces_release_binary_has_arch "$archs" arm64; then
    echo "Error: $label is missing arm64 support." >&2
    exit 1
  fi

  if ! spaces_release_binary_has_arch "$archs" x86_64; then
    echo "Error: $label is missing x86_64 support." >&2
    exit 1
  fi
}

# Non-exiting predicate form of spaces_release_require_universal_binary,
# used by create-app-bundle.sh to decide whether an existing libghostty-vt
# dylib can be reused as-is rather than rebuilt from the static xcframework.
spaces_release_is_universal_binary() {
  local binary_path="$1"
  local archs

  [[ -f "$binary_path" ]] || return 1
  archs="$(lipo -archs "$binary_path" 2>/dev/null || true)"
  spaces_release_binary_has_arch "$archs" arm64 && spaces_release_binary_has_arch "$archs" x86_64
}

# True when $1 exists as a regular dirent or as a symlink, including a
# dangling one (which `-e` alone would miss but `cp -P` can still copy
# verbatim without following it). create-app-bundle.sh uses this to decide
# whether a candidate libghostty-vt dylib is present before inspecting it.
spaces_release_dylib_copy_candidate() {
  [[ -e "$1" || -L "$1" ]]
}

# Creates a compressed DMG at $3 (volume name $2) from the folder $1.
#
# The image size is explicit because hdiutil sizes a -srcfolder image from the files' allocated
# blocks but then copies their logical length, so a sparse or transparently compressed file in the
# bundle overflows the image ("No space left on device"). The size comes from the apparent (logical)
# size, plus 20% and 32 MB of headroom for filesystem metadata; UDZO compresses the unused space
# away, so the final DMG does not grow.
spaces_release_create_dmg() {
  local source_dir="$1"
  local volume_name="$2"
  local dmg_path="$3"
  local apparent_mb
  apparent_mb="$(du -sAm "$source_dir" | cut -f1)"
  spaces_release_hdiutil_retrying "$dmg_path" create -volname "$volume_name" -srcfolder "$source_dir" \
    -size "$((apparent_mb + apparent_mb / 5 + 32))m" -ov -format UDZO "$dmg_path"
}

# Runs `hdiutil "${@:2}"`, retrying only when it fails with host resource contention. $1 is a
# partial output path to remove before each retry so a retry never starts from a half-written image
# (create's -ov would overwrite it anyway), or "" when the call writes nothing (attach).
#
# GitHub-hosted macOS runners and parallel local verify runs occasionally make hdiutil fail with
# "Resource busy" (create) or "Resource temporarily unavailable" (attach) because other jobs share
# the host (#599); this has hit after the full test suite and every signing check already passed.
# hdiutil already retries internally within one invocation, so a failure here means the host was
# contended for that whole window. Retry the whole call with backoff on top of that: 5 attempts,
# sleeping 5+10+20+40 = 75s in the worst case plus five hdiutil invocations.
#
# Only those two contention errors are retried. A deterministic failure (for example the image-size
# overflow "No space left on device" that create_dmg_sparse_file.sh guards) must fail at once rather
# than after 75s of retries. hdiutil's stderr always reaches the caller's stderr; stdout is untouched.
spaces_release_hdiutil_retrying() {
  local partial_output_path="$1"
  shift
  local max_attempts=5
  local backoff_seconds=5
  local attempt status stderr_file
  stderr_file="$(mktemp "${TMPDIR:-/tmp}/spaces-hdiutil-stderr.XXXXXX")"
  for (( attempt = 1; attempt <= max_attempts; attempt++ )); do
    status=0
    hdiutil "$@" 2>"$stderr_file" || status=$?
    cat "$stderr_file" >&2
    if (( status == 0 )); then
      rm -f "$stderr_file"
      return 0
    fi
    if (( attempt == max_attempts )) || ! grep -Eq 'Resource busy|Resource temporarily unavailable' "$stderr_file"; then
      rm -f "$stderr_file"
      return "$status"
    fi
    echo "hdiutil $1 hit resource contention (attempt $attempt/$max_attempts); retrying in ${backoff_seconds}s..." >&2
    if [[ -n "$partial_output_path" ]]; then
      rm -f "$partial_output_path"
    fi
    sleep "$backoff_seconds"
    backoff_seconds=$(( backoff_seconds * 2 ))
  done
}
