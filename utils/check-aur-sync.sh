#!/usr/bin/env bash
# Diff the live AUR PKGBUILDs against the canonical in-repo templates.
# The AUR agent must publish these files wholesale; a pkgver-only bump of a
# stale PKGBUILD has shipped broken source refs, missing deps, and missing
# packaged files before. Exit nonzero if any package drifted.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CODE_DIR="$(dirname "$ROOT_DIR")"

declare -A TEMPLATES=(
    [llama-launcher]="$ROOT_DIR/PKGBUILD"
    [llama-hdd]="$CODE_DIR/llama-hdd.cpp/aur/PKGBUILD"
    [freeclaw]="$CODE_DIR/freeclaw/aur/PKGBUILD"
)

rc=0
for pkg in llama-launcher llama-hdd freeclaw; do
    template="${TEMPLATES[$pkg]}"
    if [ ! -f "$template" ]; then
        echo "?? $pkg: template not found at $template (skipping)"
        continue
    fi
    live="$(curl -sf "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=$pkg")"
    if [ -z "$live" ]; then
        echo "?? $pkg: could not fetch AUR PKGBUILD"
        rc=1
        continue
    fi
    if diff -q <(printf '%s\n' "$live") "$template" > /dev/null 2>&1; then
        echo "OK $pkg: AUR matches in-repo template"
    else
        echo "!! $pkg: AUR PKGBUILD DRIFTED from $template"
        diff <(printf '%s\n' "$live") "$template" | sed 's/^/   /' | head -20
        rc=1
    fi
done
exit $rc
