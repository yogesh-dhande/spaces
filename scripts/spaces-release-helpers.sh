#!/usr/bin/env bash

# Shared architecture-verification helpers for the macOS release scripts
# (create-app-bundle.sh and verify-release-artifacts.sh). Both scripts check
# that shipped binaries carry both Apple Silicon and Intel slices; this file
# is their single source of truth for that check.
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
