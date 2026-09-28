#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bin_dir="$project_dir/.build/standalone/release"
if [ "${1:-}" = --show-bin-path ] && [ "$#" -eq 1 ]; then
    printf '%s\n' "$bin_dir"
    exit 0
fi
if [ "$#" -ne 0 ]; then
    echo "Usage: sh scripts/build.sh [--show-bin-path]" >&2
    exit 1
fi
if [ "$(uname -s)" != Darwin ]; then
    echo "siri-say requires macOS." >&2
    exit 1
fi
# There are no package dependencies. Compile directly to avoid invalid search
# paths injected by Swift Build with the Command Line Tools toolchain.
mkdir -p "$bin_dir"
swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macosx26.0" \
    "$project_dir"/Sources/SiriSay/*.swift -o "$bin_dir/siri-say"
printf 'Built %s/siri-say\n' "$bin_dir"
