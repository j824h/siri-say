#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
if [ ! -s LICENSE ]; then
    echo "Choose a project license and add LICENSE before packaging a release." >&2
    exit 1
fi
sh scripts/build.sh
bin_dir=$(sh scripts/build.sh --show-bin-path)
version=$("$bin_dir/siri-say" --version | awk '{print $2}')
arch=$(uname -m)
name="siri-say-$version-macos-$arch"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
mkdir -p "$stage/$name" dist
install -m 755 "$bin_dir/siri-say" "$stage/$name/siri-say"
cp README.md LICENSE THIRD_PARTY_NOTICES.md "$stage/$name/"
cp -R LICENSES "$stage/$name/"
cat > "$stage/$name/INSTALL.txt" <<'EOF'
This archive contains a standalone macOS executable for the architecture in
the archive name. It requires macOS 26+ and downloaded Siri voices.

From the extracted directory:
  mkdir -p "$HOME/.local/bin"
  install -m 755 siri-say "$HOME/.local/bin/siri-say"
  "$HOME/.local/bin/siri-say" --help

Add $HOME/.local/bin to PATH if needed. Uninstall by removing that executable.
Keep LICENSE, LICENSES, and THIRD_PARTY_NOTICES.md when redistributing.
EOF
tar -czf "dist/$name.tar.gz" -C "$stage" "$name"
cd dist
shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256"
printf 'Created dist/%s.tar.gz and checksum\n' "$name"
