#!/usr/bin/env bash
# Full-feature test of the packaged llama-launcher + llama-hdd in a fresh
# Arch container — the "did we break the AUR user" test, without AUR.
#
#   1. makepkg both packages from the LOCAL repos (file:// source override)
#   2. pacman -U them in a pristine archlinux container
#   3. assert: tunes shipped, system build discovered, tune menu lists the
#      smoke tune, full launch (proxy + HDD cache) on a ~1 MB model,
#      /health, a completion, slot-cache write, clean stop
#
# Usage: full-feature-test.sh [--keep]   (--keep leaves the work dir behind)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
HDD_SRC="$(realpath "$(dirname "$ROOT_DIR")/llama-hdd.cpp")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/llama-fft.XXXXXX")"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1
cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

docker_cmd=(docker)
docker info >/dev/null 2>&1 || docker_cmd=(sg docker -c)
run_docker() {
    if [ "${docker_cmd[0]}" = "docker" ]; then docker "$@"; else sg docker -c "docker $*"; fi
}

echo "=== 1/3 build packages from local sources"
mkdir -p "$WORK/hdd" "$WORK/launcher"
cp "$HDD_SRC/aur/PKGBUILD" "$WORK/hdd/"
sed -i "s|git+https://[^\"#]*#tag=v\${pkgver}|git+file://$HDD_SRC#branch=$(git -C "$HDD_SRC" branch --show-current)|" "$WORK/hdd/PKGBUILD"
cp "$ROOT_DIR/PKGBUILD" "$WORK/launcher/"
sed -i "s|git+https://[^\"#]*#tag=\"v\${pkgver}\"|git+file://$ROOT_DIR#branch=$(git -C "$ROOT_DIR" branch --show-current)|" "$WORK/launcher/PKGBUILD"
(cd "$WORK/hdd" && LLAMA_HDD_BACKEND=cpu makepkg -fd > makepkg.log 2>&1) || { tail -20 "$WORK/hdd/makepkg.log"; exit 1; }
(cd "$WORK/launcher" && makepkg -fd > makepkg.log 2>&1) || { tail -20 "$WORK/launcher/makepkg.log"; exit 1; }
echo "   $(ls "$WORK"/hdd/*.pkg.tar.* | xargs -n1 basename)"
echo "   $(ls "$WORK"/launcher/*.pkg.tar.* | xargs -n1 basename)"

echo "=== 2/3 write container test"
cat > "$WORK/inner.sh" << 'INNER'
#!/bin/bash
set -uo pipefail
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }

pacman -Syu --noconfirm --needed gcc-libs glibc openmp curl bash cmake git jq yq bc nodejs openssh util-linux > /pacman.log 2>&1 || fail "base install"
pacman -U --noconfirm /work/hdd/llama-hdd-*.pkg.tar.* /work/launcher/llama-launcher-*.pkg.tar.* >> /pacman.log 2>&1 || fail "package install"
pass "packages installed: $(pacman -Q llama-hdd llama-launcher | tr '\n' ' ')"

# tunes shipped?
n_tunes=$(pacman -Ql llama-launcher | grep -c "usr/share/llama-launcher/model-configs/.*\.yaml") || true
[ "$n_tunes" -ge 5 ] || fail "bundled tunes missing from package (found $n_tunes)"
pass "package ships $n_tunes tunes"

# yq sanity (whatever version string it claims)
probe="$(printf 'a: "1"\n' | yq -r '.a')" && [ "$probe" = "1" ] || fail "yq probe"
pass "yq works ($(yq --version 2>/dev/null))"

llama-server --version >/dev/null 2>&1 || fail "llama-server --version"
pass "system llama-server: $(llama-server --version 2>&1 | head -1)"

# tiny model
mkdir -p /root/llama-launcher/models/stories260K
curl -sL --retry 3 -o /root/llama-launcher/models/stories260K/stories260K.gguf \
    "https://huggingface.co/ggml-org/models/resolve/main/tinyllamas/stories260K.gguf" || fail "model download"
pass "model downloaded ($(du -h /root/llama-launcher/models/stories260K/stories260K.gguf | cut -f1))"

# tune menu lists the smoke tune (interactive path; abort after menu)
menu_out="$(printf '0\n' | timeout 20 script -qec "llama-launcher --build system --model /root/llama-launcher/models/stories260K/stories260K.gguf --proxy --log --port 40801 --internal-port 40802" /dev/null 2>&1 | head -40 || true)"
echo "$menu_out" | grep -q "Available tunes for stories260K" || fail "tune menu did not appear: $menu_out"
echo "$menu_out" | grep -q "cpu-smoke-v1" || fail "bundled smoke tune not listed: $menu_out"
llama-launcher stop >/dev/null 2>&1 || true
pass "tune menu shows bundled cpu-smoke-v1"

# full launch: system build + tune + proxy + hdd cache
cd /root
nohup llama-launcher --build system \
    --model /root/llama-launcher/models/stories260K/stories260K.gguf \
    --tune cpu-smoke-v1 --hdd-cache --proxy --log \
    --port 40801 --internal-port 40802 --parallel 1 > /launch.log 2>&1 &
for i in $(seq 1 60); do
    curl -s -m 2 http://127.0.0.1:40801/health 2>/dev/null | grep -q '"ok"' && break
    sleep 1
    [ "$i" = 60 ] && { tail -30 /launch.log; fail "server never became healthy"; }
done
pass "launched, healthy on :40801 (proxy) $(curl -s http://127.0.0.1:40801/health)"

# completion through the proxy
comp="$(curl -s -m 30 http://127.0.0.1:40801/v1/chat/completions \
    -H "Authorization: Bearer ollama-local" -H "Content-Type: application/json" \
    -d '{"messages":[{"role":"user","content":"Once upon a time"}],"max_tokens":16}')"
echo "$comp" | grep -q '"content"' || fail "no completion content: $comp"
pass "completion ok: $(echo "$comp" | head -c 120)..."

# anthropic endpoint + HDD slot cache write
curl -s -m 30 http://127.0.0.1:40801/v1/messages \
    -H "x-api-key: ollama-local" -H "anthropic-version: 2023-06-01" -H "Content-Type: application/json" \
    -d '{"model":"stories","max_tokens":8,"messages":[{"role":"user","content":"The cat"}]}' > /dev/null
sleep 3
slots=$(ls /root/llama-launcher/slots/stories260K/ 2>/dev/null | wc -l)
[ "$slots" -ge 1 ] || fail "no HDD slot cache files written"
pass "HDD cache wrote $slots slot file(s)"

# clean stop
llama-launcher stop > /stop.log 2>&1
sleep 2
pgrep -f "llama-server|llama-deep-proxy" > /dev/null && fail "processes survived stop"
pass "clean stop"

echo "ALL-TESTS-PASSED"
INNER
chmod +x "$WORK/inner.sh"

echo "=== 3/3 run in fresh archlinux container"
run_docker run --rm -v "$WORK:/work:ro" archlinux:latest bash /work/inner.sh
