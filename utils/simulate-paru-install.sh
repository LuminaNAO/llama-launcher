#!/usr/bin/env bash
# Simulate a paru/AUR install of llama-hdd entirely locally:
#   1. makepkg the aur/PKGBUILD against a local source tree (file:// override)
#   2. fake-install the package rootlessly (unshare + overlayfs on /usr)
#   3. verify llama-server-launcher.sh picks it up as build type "system"
#
# Usage: simulate-paru-install.sh [path-to-llama-hdd.cpp] [backend]
#   backend defaults to cpu (fed to the PKGBUILD's interactive prompt)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
HDD_SRC="$(realpath "${1:-$(dirname "$ROOT_DIR")/llama-hdd.cpp}")"
BACKEND="${2:-cpu}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/paru-sim.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

for cmd in makepkg unshare git script; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "❌ missing: $cmd"; exit 1; }
done
[ -f "$HDD_SRC/aur/PKGBUILD" ] || { echo "❌ no aur/PKGBUILD under $HDD_SRC"; exit 1; }

echo "📦 1/3 makepkg from local source ($HDD_SRC, backend=$BACKEND)"
mkdir -p "$TMP_ROOT/pkg"
cp "$HDD_SRC/aur/PKGBUILD" "$TMP_ROOT/pkg/"
sed -i "s|git+https://[^\"#]*#tag=\${pkgver}|git+file://$HDD_SRC#branch=$(git -C "$HDD_SRC" branch --show-current)|" \
    "$TMP_ROOT/pkg/PKGBUILD"
# script(1) provides the tty the backend prompt reads from
(cd "$TMP_ROOT/pkg" && script -qec "makepkg -f" /dev/null <<< "$BACKEND" > makepkg.log 2>&1) || {
    echo "❌ makepkg failed; tail of log:"; tail -30 "$TMP_ROOT/pkg/makepkg.log"; exit 1;
}
pkgfile="$(ls "$TMP_ROOT"/pkg/*.pkg.tar.* | head -1)"
# awk reads to EOF: grep -q exits early and SIGPIPEs tar under pipefail
tar -tf "$pkgfile" | awk '$0 == "usr/bin/llama-server" { found=1 } END { exit found ? 0 : 1 }' \
    || { echo "❌ package lacks usr/bin/llama-server"; exit 1; }
echo "   built: $(basename "$pkgfile")"

echo "📦 2/3 rootless fake-install (unshare + overlayfs)"
mkdir -p "$TMP_ROOT"/{root,upperbin,upperlib,workbin,worklib}
tar -xf "$pkgfile" -C "$TMP_ROOT/root" usr

echo "📦 3/3 launcher system-build check"
unshare -mr bash -c "
set -e
mount -t overlay overlay -o lowerdir=/usr/bin,upperdir=$TMP_ROOT/upperbin,workdir=$TMP_ROOT/workbin /usr/bin
mount -t overlay overlay -o lowerdir=/usr/lib,upperdir=$TMP_ROOT/upperlib,workdir=$TMP_ROOT/worklib /usr/lib
cp $TMP_ROOT/root/usr/bin/llama-server /usr/bin/
cp $TMP_ROOT/root/usr/lib/*.so* /usr/lib/ 2>/dev/null || true
/usr/bin/llama-server --version
out=\$('$ROOT_DIR/llama-server-launcher.sh' --build system --model /nonexistent 2>&1 | head -2)
echo \"\$out\"
echo \"\$out\" | grep -q 'Build: system (/usr/bin/llama-server)'
"
echo "✅ paru-install simulation passed (backend=$BACKEND)"
