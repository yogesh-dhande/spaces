#!/bin/sh
set -eu

cache_dir="$(pwd)/.build/clang-module-cache"
coverage_dir="$(pwd)/.build/coverage"
mkdir -p "$cache_dir"
mkdir -p "$coverage_dir"
export CLANG_MODULE_CACHE_PATH="$cache_dir"
export LLVM_PROFILE_FILE="$coverage_dir/%m.profraw"

echo "Running swift test with coverage..."
"$(pwd)/scripts/swiftpm.sh" test --enable-code-coverage --disable-sandbox

profdata_path=$(find .build -type f -name "*.profdata" | sort | tail -n 1)
if [ -z "${profdata_path:-}" ]; then
    echo "Coverage data not found. Expected a .profdata file under .build." >&2
    exit 1
fi

test_binary=$(find .build -type f -path "*PackageTests.xctest/Contents/MacOS/*" | sort | head -n 1)
if [ -z "${test_binary:-}" ]; then
    test_binary=$(find .build -type f -name "*PackageTests*" | grep -v "\.dSYM" | sort | head -n 1)
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
