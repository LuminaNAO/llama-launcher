#!/bin/bash
# mlock-fixer.sh — Fix memlock limits for llama-server
#
# Without unlimited memlock, the kernel can swap llama-server pages to disk,
# causing catastrophic performance drops (< 1 tok/s observed).
#
# This script sets unlimited memlock for the current user in
# /etc/security/limits.conf. Requires sudo. You must re-login
# (or reboot) after running for the changes to take effect.
#
# Usage:
#   sudo bash mlock-fixer.sh
#   # then log out and back in

set -euo pipefail

USER_NAME="${SUDO_USER:-$(whoami)}"
LIMITS_FILE="/etc/security/limits.conf"
MARKER="# llama-server mlock fix"

# ── Check privileges ───────────────────────────────────��────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ This script must be run with sudo:"
    echo "   sudo bash $0"
    exit 1
fi

# ── Check current memlock ───────────────────────────────��───────────────────
CURRENT=$(su - "$USER_NAME" -c 'ulimit -l' 2>/dev/null || echo "unknown")
echo "Current memlock for $USER_NAME: $CURRENT"

if [ "$CURRENT" = "unlimited" ]; then
    echo "✅ memlock is already unlimited — nothing to do"
    exit 0
fi

# ── Check if already in limits.conf ─────────────────────────────────────────
if grep -q "$MARKER" "$LIMITS_FILE" 2>/dev/null; then
    echo "⚠️  Entries already exist in $LIMITS_FILE (marked with '$MARKER')"
    echo "   If memlock is still limited, try logging out and back in."
    grep "$MARKER" "$LIMITS_FILE"
    exit 0
fi

# ── Apply fix ───────────────────────────────────────────────────────────────
echo ""
echo "Adding memlock entries to $LIMITS_FILE for user: $USER_NAME"

cat >> "$LIMITS_FILE" << EOF

$MARKER
${USER_NAME}  hard  memlock  unlimited
${USER_NAME}  soft  memlock  unlimited
EOF

echo ""
echo "✅ Added to $LIMITS_FILE:"
echo "   ${USER_NAME}  hard  memlock  unlimited"
echo "   ${USER_NAME}  soft  memlock  unlimited"
echo ""
echo "⚠️  You MUST log out and back in for this to take effect."
echo "   Then verify with: ulimit -l"
echo "   Expected output: unlimited"
