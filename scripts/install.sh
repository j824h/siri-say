#!/bin/sh
set -eu

if [ "$(uname -s)" != Darwin ]; then
    echo "siri-say requires macOS." >&2
    exit 1
fi

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
prefix=${PREFIX:-"$HOME/.local"}
sh "$project_dir/scripts/build.sh"
bin_dir=$(sh "$project_dir/scripts/build.sh" --show-bin-path)
mkdir -p "$prefix/bin"
install -m 755 "$bin_dir/siri-say" "$prefix/bin/siri-say"
printf 'Installed %s/bin/siri-say\n' "$prefix"
case ":$PATH:" in
    *":$prefix/bin:"*) ;;
    *) printf 'Add this directory to your PATH: %s/bin\n' "$prefix" ;;
esac
