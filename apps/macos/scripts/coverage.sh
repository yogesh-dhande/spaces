#!/bin/sh
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cache_dir="$root/.build/clang-module-cache"
coverage_dir="$root/.build/coverage"
mkdir -p "$cache_dir"
mkdir -p "$coverage_dir"
export CLANG_MODULE_CACHE_PATH="$cache_dir"
export LLVM_PROFILE_FILE="$coverage_dir/%m.profraw"

echo "Running swift test with coverage..."
"$root/scripts/swiftpm.sh" test --enable-code-coverage --disable-sandbox

profdata_path=$(find "$root/.build" -type f -name "*.profdata" | sort | tail -n 1)
if [ -z "${profdata_path:-}" ]; then
    echo "Coverage data not found. Expected a .profdata file under .build." >&2
    exit 1
fi

package_name=$(sed -n 's/^[[:space:]]*name:[[:space:]]*"\([^"]*\)".*/\1/p' "$root/Package.swift" | head -n 1)
expected_test_binary="${package_name}PackageTests"
test_binary=""
if [ -n "${package_name:-}" ]; then
    test_binary=$(find "$root/.build" -type f -path "*${expected_test_binary}.xctest/Contents/MacOS/${expected_test_binary}" | sort | tail -n 1)
fi
if [ -z "${test_binary:-}" ]; then
    test_binary=$(find "$root/.build" -type f -path "*PackageTests.xctest/Contents/MacOS/*PackageTests" | grep -v "\.dSYM" | sort | tail -n 1)
fi
if [ -z "${test_binary:-}" ]; then
    echo "Test binary not found under .build." >&2
    exit 1
fi

echo "Coverage report:"
xcrun llvm-cov report \
    -instr-profile "$profdata_path" \
    --ignore-filename-regex="\\.build|/Tests/" \
    "$test_binary"
