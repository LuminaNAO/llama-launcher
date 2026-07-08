#!/usr/bin/env bash
# Full-feature test of the packaged llama-launcher + llama-hdd in a fresh
# Arch container — the "did we break the AUR user" test, without AUR.
#
# Modes:
#   (default)  fast: makepkg on the host, pacman -U in the container
#   --paru     the real thing: build paru from the AUR inside the container,
#              paru -S freeclaw (real AUR), paru -Bi the local packages —
#              the full `paru -S freeclaw llama-hdd llama-launcher` journey
#   --keep     keep the work dir for inspection
#
# Asserts: tunes shipped, system build discovered, tune menu lists the smoke
# tune, full launch (proxy + HDD cache) on a ~1 MB model, /health, a
# completion, session-switch slot-cache write, clean stop.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
HDD_SRC="$(realpath "$(dirname "$ROOT_DIR")/llama-hdd.cpp")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/llama-fft.XXXXXX")"
KEEP=0 MODE=fast
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=1 ;;
        --paru) MODE=paru ;;
        *) echo "unknown arg: $arg"; exit 1 ;;
    esac
done
cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

run_docker() {
    if docker info >/dev/null 2>&1; then docker "$@"; else sg docker -c "docker $*"; fi
}

launcher_branch="$(git -C "$ROOT_DIR" branch --show-current)"
hdd_branch="$(git -C "$HDD_SRC" branch --show-current)"

if [ "$MODE" = "fast" ]; then
    echo "=== build packages on host (fast mode)"
    mkdir -p "$WORK/hdd" "$WORK/launcher"
    cp "$HDD_SRC/aur/PKGBUILD" "$WORK/hdd/"
    sed -i "s|git+https://[^\"#]*#tag=v\${pkgver}|git+file://$HDD_SRC#branch=$hdd_branch|" "$WORK/hdd/PKGBUILD"
    cp "$ROOT_DIR/PKGBUILD" "$WORK/launcher/"
    sed -i "s|git+https://[^\"#]*#tag=\"v\${pkgver}\"|git+file://$ROOT_DIR#branch=$launcher_branch|" "$WORK/launcher/PKGBUILD"
    (cd "$WORK/hdd" && LLAMA_HDD_BACKEND=cpu makepkg -fd > makepkg.log 2>&1) || { tail -20 "$WORK/hdd/makepkg.log"; exit 1; }
    (cd "$WORK/launcher" && makepkg -fd > makepkg.log 2>&1) || { tail -20 "$WORK/launcher/makepkg.log"; exit 1; }
fi

cat > "$WORK/inner.sh" << INNERVARS
#!/bin/bash
INSTALL_MODE="$MODE"
HDD_BRANCH="$hdd_branch"
LAUNCHER_BRANCH="$launcher_branch"
INNERVARS
cat >> "$WORK/inner.sh" << 'INNER'
set -uo pipefail
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }

RUNTIME_DEPS="gcc-libs glibc openmp curl bash cmake git jq yq bc nodejs openssh util-linux"

if [ "$INSTALL_MODE" = "paru" ]; then
    pacman -Syu --noconfirm --needed base-devel git sudo $RUNTIME_DEPS > /pacman.log 2>&1 || fail "base install"
    useradd -m builder && echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
    sudo -u builder bash -ec 'cd ~ && git clone -q https://aur.archlinux.org/paru.git && cd paru && makepkg -si --noconfirm' >> /pacman.log 2>&1 || { tail -20 /pacman.log; fail "paru source build"; }
    pass "paru installed: $(paru --version | head -1)"

    sudo -u builder paru -S --noconfirm freeclaw >> /pacman.log 2>&1 || { tail -20 /pacman.log; fail "paru -S freeclaw"; }
    pass "freeclaw from real AUR: $(pacman -Q freeclaw)"

    sudo -u builder bash -ec "
    mkdir -p ~/aur/llama-hdd ~/aur/llama-launcher
    cp /srv/llama-hdd.cpp/aur/PKGBUILD ~/aur/llama-hdd/
    sed -i 's|git+https://[^\"#]*#tag=v\${pkgver}|git+file:///srv/llama-hdd.cpp#branch=$HDD_BRANCH|' ~/aur/llama-hdd/PKGBUILD
    cp /srv/llama-launcher/PKGBUILD ~/aur/llama-launcher/
    sed -i 's|git+https://[^\"#]*#tag=\"v\${pkgver}\"|git+file:///srv/llama-launcher#branch=$LAUNCHER_BRANCH|' ~/aur/llama-launcher/PKGBUILD
    cd ~/aur/llama-hdd && LLAMA_HDD_BACKEND=cpu paru -Bi --noconfirm . > ~/paru-hdd.log 2>&1 || { tail -20 ~/paru-hdd.log; exit 1; }
    cd ~/aur/llama-launcher && paru -Bi --noconfirm . > ~/paru-launcher.log 2>&1 || { tail -20 ~/paru-launcher.log; exit 1; }
    " || fail "paru -Bi local packages"
else
    pacman -Syu --noconfirm --needed $RUNTIME_DEPS > /pacman.log 2>&1 || fail "base install"
    pacman -U --noconfirm /work/hdd/llama-hdd-*.pkg.tar.* /work/launcher/llama-launcher-*.pkg.tar.* >> /pacman.log 2>&1 || fail "package install"
fi
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

# anthropic endpoint + HDD slot cache: the proxy saves ONLY on session
# switch (or shutdown), keyed by x-openclaw-session-id — run session A,
# then session B to force A's save.
msg="$(curl -s -m 30 http://127.0.0.1:40801/v1/messages \
    -H "x-api-key: ollama-local" -H "anthropic-version: 2023-06-01" -H "Content-Type: application/json" \
    -H "x-openclaw-session-id: aaaaaaaaaaaa-aaaaaaaaaaaa" \
    -d '{"model":"stories","max_tokens":8,"messages":[{"role":"user","content":"The cat sat"}]}')"
echo "$msg" | grep -q '"type":"message"\|content' || fail "/v1/messages (session A) failed: $msg"
curl -s -m 30 http://127.0.0.1:40801/v1/messages \
    -H "x-api-key: ollama-local" -H "anthropic-version: 2023-06-01" -H "Content-Type: application/json" \
    -H "x-openclaw-session-id: bbbbbbbbbbbb-bbbbbbbbbbbb" \
    -d '{"model":"stories","max_tokens":8,"messages":[{"role":"user","content":"The dog ran"}]}' > /dev/null
slots=0
for i in $(seq 1 15); do
    slots=$(find /root/llama-launcher -path "*slots*" -name "*.meta.json" 2>/dev/null | wc -l)
    [ "$slots" -ge 1 ] && break
    sleep 1
done
if [ "$slots" -lt 1 ]; then
    echo "--- launch.log preamble:"; head -50 /launch.log
    echo "--- proxy/cache lines in llama.log:"
    grep -a "llama-deep-proxy\|REQUEST POST\|HDD CACHE" /root/.local/share/llama-launcher/llama.log 2>/dev/null | head -20
    fail "no HDD slot cache files written"
fi
pass "HDD cache wrote $slots slot file(s) on session switch"

# freeclaw smoke (paru mode) — the freeclaw package installs bin/openclaw
if [ "$INSTALL_MODE" = "paru" ]; then
    fv="$(sudo -u builder openclaw --version 2>&1 | head -1)" || fail "freeclaw (openclaw) --version: $fv"
    pass "freeclaw runs: openclaw $fv"
fi

# clean stop
llama-launcher stop > /stop.log 2>&1
sleep 2
pgrep -f "llama-server|llama-deep-proxy" > /dev/null && fail "processes survived stop"
pass "clean stop"

echo "ALL-TESTS-PASSED"
INNER
chmod +x "$WORK/inner.sh"

echo "=== run in fresh archlinux container ($MODE mode)"
if [ "$MODE" = "paru" ]; then
    run_docker run --rm -v "$WORK:/work:ro" -v "$HDD_SRC:/srv/llama-hdd.cpp:ro" -v "$ROOT_DIR:/srv/llama-launcher:ro" archlinux:latest bash /work/inner.sh
else
    run_docker run --rm -v "$WORK:/work:ro" archlinux:latest bash /work/inner.sh
fi
