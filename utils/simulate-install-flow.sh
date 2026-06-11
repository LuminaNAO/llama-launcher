#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}/llama-launcher-install-sim.$$"

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $1" >&2
        exit 1
    fi
}

assert_contains() {
    local file="$1"
    local needle="$2"
    if ! grep -F "$needle" "$file" >/dev/null; then
        echo "ERROR: expected output not found:" >&2
        echo "  $needle" >&2
        echo "" >&2
        echo "--- $file ---" >&2
        sed -n '1,260p' "$file" >&2
        exit 1
    fi
}

copy_clean_repo() {
    local dest="$1"
    mkdir -p "$dest"
    tar \
        --exclude='.git' \
        --exclude='builds' \
        --exclude='.llama-launcher-config' \
        --exclude='.launch-history' \
        --exclude='llama.log' \
        --exclude='llama-deep.log' \
        -C "$ROOT_DIR" -cf - . | tar -C "$dest" -xf -
}

write_fake_server() {
    local dest="$1"
    local marker="$2"
    mkdir -p "$(dirname "$dest")"
    cat > "$dest" <<EOF
#!/bin/sh
echo "$marker \$@"
exit 0
EOF
    chmod +x "$dest"
}

write_fake_downloader() {
    local dest="$1"
    local marker="$2"
    mkdir -p "$(dirname "$dest")"
    cat > "$dest" <<EOF
#!/bin/sh
set -eu
filename="model.gguf"
repo=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --filename|--file) filename="\$2"; shift 2 ;;
    *) repo="\$1"; shift ;;
  esac
done
mkdir -p "\$LLAMACPP_MODELS_DIR/Qwen3.6-27B-MTP"
: > "\$LLAMACPP_MODELS_DIR/Qwen3.6-27B-MTP/\$filename"
echo "$marker repo=\$repo filename=\$filename dir=\$LLAMACPP_MODELS_DIR"
EOF
    chmod +x "$dest"
}

simulate_git_clone_install() {
    local root="$TMP_ROOT/git-clone"
    local home_dir="$root/home"
    local clone="$root/clone"
    local bin_dir="$root/bin"
    local install_out="$root/install.out"
    local launch_out="$root/launch.out"

    mkdir -p "$home_dir" "$bin_dir"
    copy_clean_repo "$clone"
    write_fake_server "$clone/builds/rocm/bin/llama-server" "FAKE_CLONE_LLAMA_SERVER"
    write_fake_downloader "$bin_dir/fake-download-model" "FAKE_CLONE_DOWNLOAD"

    # install.sh prompts:
    #   default models dir, create it, default slot dir, create it, skip install-time download.
    printf '\ny\n\ny\nn\n' |
        env -i HOME="$home_dir" USER=sim SHELL=/bin/bash PATH="$bin_dir:/usr/local/bin:/usr/bin:/bin" \
            "$clone/install.sh" > "$install_out" 2>&1

    # launcher prompts:
    #   download author pick, select model, accept suggested tune,
    #   public/internal ports, enable HDD cache, proxy+log.
    printf '1\n1\n\n49201\n49202\n2\n3\n' |
        env -i HOME="$home_dir" USER=sim SHELL=/bin/bash \
            PATH="$home_dir/.local/bin:$bin_dir:/usr/local/bin:/usr/bin:/bin" \
            LLAMA_LAUNCHER_DOWNLOAD_MODEL="$bin_dir/fake-download-model" \
            llama-launcher > "$launch_out" 2>&1

    assert_contains "$install_out" "Installed: $home_dir/.local/bin/llama-launcher -> $clone/llama-server-launcher.sh"
    assert_contains "$install_out" "Installed: $home_dir/.local/bin/llama-download-model -> $clone/download-model.sh"
    assert_contains "$launch_out" "Download author best pick: Qwen3.6-27B-MTP 64GB coding (Qwen3.6-27B-UD-Q4_K_XL.gguf)"
    assert_contains "$launch_out" "FAKE_CLONE_DOWNLOAD repo=unsloth/Qwen3.6-27B-MTP-GGUF filename=Qwen3.6-27B-UD-Q4_K_XL.gguf"
    assert_contains "$launch_out" "64gb-q4-140k-coding-v1"
    assert_contains "$launch_out" "Slot save namespace: $home_dir/llama-launcher/slots/Qwen3.6-27B-UD-Q4_K_XL"
    assert_contains "$launch_out" "FAKE_CLONE_LLAMA_SERVER"

    echo "ok: git clone install flow"
}

simulate_packaged_aur_install() {
    local root="$TMP_ROOT/aur"
    local home_dir="$root/home"
    local bin_dir="$root/usr-bin"
    local lib_dir="$root/usr-lib/llama-launcher"
    local share_dir="$root/usr-share/llama-launcher/model-configs"
    local data_dir="$root/data"
    local launch_out="$root/launch.out"

    mkdir -p "$home_dir" "$bin_dir" "$lib_dir" "$share_dir" "$data_dir/builds/rocm/bin"
    cp "$ROOT_DIR/llama-server-launcher.sh" "$bin_dir/llama-launcher"
    # Simulate /usr/bin without writing outside /tmp.
    sed -i "s#    /usr/bin|/usr/local/bin|/bin)#    $bin_dir|/usr/bin|/usr/local/bin|/bin)#" "$bin_dir/llama-launcher"
    chmod +x "$bin_dir/llama-launcher"
    cp "$ROOT_DIR/llama-deep-proxy.mjs" "$lib_dir/llama-deep-proxy.mjs"
    cp -a "$ROOT_DIR/model-configs/." "$share_dir/"
    write_fake_downloader "$lib_dir/download-model.sh" "FAKE_AUR_DOWNLOAD"
    write_fake_server "$data_dir/builds/rocm/bin/llama-server" "FAKE_AUR_LLAMA_SERVER"

    # launcher prompts:
    #   create default models dir, download author pick, select model,
    #   accept suggested tune, public/internal ports, enable HDD cache, proxy+log.
    printf 'y\n1\n1\n\n49211\n49212\n2\n3\n' |
        env -i HOME="$home_dir" USER=sim SHELL=/bin/bash PATH="$bin_dir:/usr/local/bin:/usr/bin:/bin" \
            LLAMA_LAUNCHER_DIR="$data_dir" \
            LLAMA_LAUNCHER_LIB_DIR="$lib_dir" \
            LLAMA_LAUNCHER_MODEL_CONFIG_DIR="$share_dir" \
            llama-launcher > "$launch_out" 2>&1

    assert_contains "$launch_out" "Download author best pick: Qwen3.6-27B-MTP 64GB coding (Qwen3.6-27B-UD-Q4_K_XL.gguf)"
    assert_contains "$launch_out" "FAKE_AUR_DOWNLOAD repo=unsloth/Qwen3.6-27B-MTP-GGUF filename=Qwen3.6-27B-UD-Q4_K_XL.gguf"
    assert_contains "$launch_out" "64gb-q4-140k-coding-v1"
    assert_contains "$launch_out" "Slot save namespace: $home_dir/llama-launcher/llama-slots/Qwen3.6-27B-UD-Q4_K_XL"
    assert_contains "$launch_out" "FAKE_AUR_LLAMA_SERVER"

    echo "ok: packaged/AUR install flow"
}

simulate_packaged_aur_clone_tunes() {
    local root="$TMP_ROOT/aur-clone-tunes"
    local home_dir="$root/home"
    local bin_dir="$root/usr-bin"
    local lib_dir="$root/usr-lib/llama-launcher"
    local data_dir="$root/data"
    local cache_dir="$root/cache"
    local aur_clone="$cache_dir/yay/llama-launcher"
    local launch_out="$root/launch.out"

    mkdir -p \
        "$home_dir/llama-launcher/models/Qwen3.6-27B-MTP" \
        "$bin_dir" \
        "$lib_dir" \
        "$data_dir/builds/rocm/bin" \
        "$aur_clone/model-configs"
    : > "$home_dir/llama-launcher/models/Qwen3.6-27B-MTP/Qwen3.6-27B-UD-Q4_K_XL.gguf"

    cp "$ROOT_DIR/llama-server-launcher.sh" "$bin_dir/llama-launcher"
    # Simulate /usr/bin without writing outside /tmp.
    sed -i "s#    /usr/bin|/usr/local/bin|/bin)#    $bin_dir|/usr/bin|/usr/local/bin|/bin)#" "$bin_dir/llama-launcher"
    chmod +x "$bin_dir/llama-launcher"
    cp "$ROOT_DIR/llama-deep-proxy.mjs" "$lib_dir/llama-deep-proxy.mjs"
    cp "$ROOT_DIR"/model-configs/Qwen3.6-27B-MTP.*.yaml "$aur_clone/model-configs/"
    write_fake_downloader "$lib_dir/download-model.sh" "FAKE_AUR_CLONE_DOWNLOAD"
    write_fake_server "$data_dir/builds/rocm/bin/llama-server" "FAKE_AUR_CLONE_LLAMA_SERVER"

    # launcher prompts:
    #   select model, accept suggested tune, public/internal ports, enable HDD cache, proxy+log.
    printf '1\n\n49221\n49222\n2\n3\n' |
        env -i HOME="$home_dir" USER=sim SHELL=/bin/bash PATH="$bin_dir:/usr/local/bin:/usr/bin:/bin" \
            XDG_CACHE_HOME="$cache_dir" \
            LLAMA_LAUNCHER_DIR="$data_dir" \
            LLAMA_LAUNCHER_LIB_DIR="$lib_dir" \
            LLAMA_LAUNCHER_MODEL_CONFIG_DIR="$root/missing-share/model-configs" \
            llama-launcher > "$launch_out" 2>&1

    assert_contains "$launch_out" "📋 Tune: 64gb-q4-140k-coding-v1"
    assert_contains "$launch_out" "Available tunes for Qwen3.6-27B-MTP"
    assert_contains "$launch_out" "FAKE_AUR_CLONE_LLAMA_SERVER"
    if grep -F "Tune: none (using system profile)" "$launch_out" >/dev/null; then
        echo "ERROR: packaged AUR clone tune discovery fell back to system profile" >&2
        sed -n '1,260p' "$launch_out" >&2
        exit 1
    fi

    echo "ok: packaged/AUR clone tune discovery"
}

require_cmd bash
require_cmd grep
require_cmd node
require_cmd sed
require_cmd tar
require_cmd yq

mkdir -p "$TMP_ROOT"

bash -n "$ROOT_DIR/llama-server-launcher.sh" "$ROOT_DIR/install.sh" "$ROOT_DIR/download-model.sh" "$ROOT_DIR"/utils/*.sh
simulate_git_clone_install
simulate_packaged_aur_install
simulate_packaged_aur_clone_tunes

echo "ok: install-flow simulation complete"
