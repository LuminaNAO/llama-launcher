#!/bin/bash
# set-rc-watchdog-timeout.sh — raise the NVIDIA RC watchdog notify timeout.
#
# Background (see snapshots/CUDA-LAUNCH-TIMEOUT-incidents.md): the driver's
# Robust-Channel watchdog runs its own tiny 2D job on its own channel and, if
# that job isn't serviced within RmWatchDogTimeOut seconds (default 7), RCs
# whichever channel is running — surfacing in llama-server as
#   "CUDA error: the launch timed out and was terminated"  (Xid 8).
# The GPU was still completing decode steps inside the window on every logged
# incident, i.e. the watchdog job was starved, not the GPU hung. Raising the
# timeout removes that false positive while keeping recovery for a real hang.
#
# The key is read once at GPU init via NVreg_RegistryDwords. nvidia is loaded
# from the initramfs on this box (mkinitcpio.conf.d/20-nvidia.conf), so the
# modprobe.d file must be baked into the image: this script rebuilds it through
# limine-mkinitcpio (no /etc/mkinitcpio.d presets here) and verifies the conf
# is actually inside each image before declaring success. Takes effect on reboot.
#
# Usage:
#   sudo utils/set-rc-watchdog-timeout.sh [SECONDS]   # default 60
#   sudo utils/set-rc-watchdog-timeout.sh --revert    # remove conf, rebuild
#   sudo utils/set-rc-watchdog-timeout.sh --verify    # only check images contain the conf
#        utils/set-rc-watchdog-timeout.sh --status    # live value + conf + last Xid
#
# After reboot:  grep RegistryDwords /proc/driver/nvidia/params
# The next Xid line (if any) prints "Notify Timeout Seconds: <SECONDS>".

set -euo pipefail

CONF=/etc/modprobe.d/nvidia-rc-watchdog.conf
KEY=RmWatchDogTimeOut
DEFAULT_SECS=60
MODE=set
SECS=$DEFAULT_SECS

case "${1:-}" in
	--revert) MODE=revert ;;
	--verify) MODE=verify ;;
	--status) MODE=status ;;
	-h|--help) sed -n '2,25p' "$0"; exit 0 ;;
	"") ;;
	*)
		SECS="$1"
		if ! [[ "$SECS" =~ ^[0-9]+$ ]] || (( SECS < 1 || SECS > 3600 )); then
			echo "ERROR: SECONDS must be an integer 1..3600 (got '$SECS')" >&2
			exit 2
		fi
		(( SECS < 7 )) && echo "WARNING: $SECS s is below the driver default of 7 s — this makes crashes MORE likely." >&2
		;;
esac

status() {
	echo "== live driver params =="
	grep -E 'RegistryDwords:' /proc/driver/nvidia/params 2>/dev/null || echo "(nvidia not loaded)"
	echo
	echo "== $CONF =="
	if [[ -f $CONF ]]; then cat "$CONF"; else echo "(absent — driver default 7 s in effect)"; fi
	echo
	echo "== other modprobe.d files touching NVreg_RegistryDwords =="
	grep -lsE 'NVreg_RegistryDwords' /etc/modprobe.d/*.conf /run/modprobe.d/*.conf /usr/lib/modprobe.d/*.conf 2>/dev/null | grep -vx "$CONF" || echo "(none)"
	echo
	echo "== kernel cmdline =="
	tr ' ' '\n' </proc/cmdline | grep -iE 'NVreg_RegistryDwords' || echo "(no NVreg_RegistryDwords on cmdline)"
	echo
	echo "== last RC watchdog event this boot =="
	journalctl -k -b --no-pager 2>/dev/null | grep -E 'RC watchdog|Xid' | tail -2 || true
}

if [[ $MODE == status ]]; then status; exit 0; fi

if (( EUID != 0 )); then
	echo "ERROR: must run as root:  sudo $0 ${1:-}" >&2
	exit 1
fi

# Refuse to silently fight another source of NVreg_RegistryDwords. modprobe
# concatenates 'options' lines but a second RegistryDwords value would replace
# ours, and a kernel-cmdline value overrides modprobe.d entirely.
conflicts=$(grep -lsE 'NVreg_RegistryDwords' /etc/modprobe.d/*.conf /run/modprobe.d/*.conf /usr/lib/modprobe.d/*.conf 2>/dev/null | grep -vx "$CONF" || true)
if [[ -n $conflicts ]]; then
	echo "ERROR: NVreg_RegistryDwords is already set in:" >&2
	echo "$conflicts" >&2
	echo "Merge $KEY=$SECS into that file instead (values are ';'-separated)." >&2
	exit 1
fi
if grep -qiE 'NVreg_RegistryDwords' /proc/cmdline; then
	echo "ERROR: NVreg_RegistryDwords is on the kernel cmdline — it would override $CONF." >&2
	echo "Edit KERNEL_CMDLINE in /etc/default/limine instead." >&2
	exit 1
fi

if [[ $MODE == revert ]]; then
	if [[ -f $CONF ]]; then
		rm -f "$CONF"
		echo "Removed $CONF (driver default 7 s after reboot)."
	else
		echo "$CONF not present; nothing to revert."
	fi
elif [[ $MODE == set ]]; then
	tmp=$(mktemp "${CONF}.XXXXXX")
	cat >"$tmp" <<-EOF
	# Written by llama-launcher/utils/set-rc-watchdog-timeout.sh — do not hand-edit;
	# re-run the script to change or --revert to remove.
	# NVIDIA RC watchdog notify timeout in seconds (driver default 7). Raised so the
	# watchdog's own starved job doesn't RC llama-server's channel (Xid 8 /
	# cudaErrorLaunchTimeout). See llama-launcher/snapshots/CUDA-LAUNCH-TIMEOUT-incidents.md
	options nvidia NVreg_RegistryDwords="$KEY=$SECS"
	EOF
	chmod 0644 "$tmp"
	mv -f "$tmp" "$CONF"
	echo "Wrote $CONF:"
	grep '^options' "$CONF"

	# modprobe parses it now even though the module is already loaded; this
	# catches a malformed line before we spend a rebuild on it. Capture first:
	# --showconfig is megabytes, and grep -q on a pipe would SIGPIPE modprobe,
	# which pipefail then reports as a (false) failure.
	showconfig=$(modprobe --showconfig 2>/dev/null || true)
	if ! grep -qF "$KEY=$SECS" <<<"$showconfig"; then
		echo "ERROR: modprobe does not see '$KEY=$SECS' — conf not parsed. Aborting before rebuild." >&2
		exit 1
	fi
	echo "modprobe config parses OK."
fi

if [[ $MODE != verify ]]; then
	echo
	echo "Rebuilding initramfs (nvidia is loaded from the image, so the conf must be baked in)..."
	if command -v limine-mkinitcpio >/dev/null 2>&1; then
		# Kernels with no nvidia module (e.g. -lts without linux-*-nvidia-open)
		# fail inside this and are skipped by the hook; that is pre-existing
		# and harmless here — no nvidia module means no watchdog to configure.
		limine-mkinitcpio
	else
		# Generic Arch fallback: preset-driven rebuild.
		mkinitcpio -P
	fi
fi

echo
echo "Verifying the conf is inside each initramfs image..."
esp=$(grep -E '^ESP_PATH=' /etc/default/limine 2>/dev/null | cut -d'"' -f2 || true)
esp=${esp:-/boot}
# limine-entry-tool installs images as <ESP>/<machine-id>/<kernel>/initramfs
# (plus initramfs-fallback); plain Arch uses /boot/initramfs-<kernel>.img.
shopt -s nullglob
images=("$esp"/*/*/initramfs* /boot/initramfs-*.img)
shopt -u nullglob
if (( ${#images[@]} == 0 )); then
	echo "WARNING: no initramfs images found under $esp — cannot verify; check limine-mkinitcpio output above." >&2
	exit 1
fi
fail=0
for img in "${images[@]}"; do
	# limine-snapper-sync keeps prior images under limine_history/ so btrfs
	# snapshots stay bootable. They are frozen copies of older builds, not
	# what the current entry boots — never judge them.
	if [[ $img == */limine_history/* ]]; then
		echo "  SKIP   $img (snapshot history, not the live image)"
		continue
	fi
	# Same capture-first pattern as above: lsinitcpio output is long.
	listing=$(lsinitcpio "$img" 2>/dev/null || true)
	# An image with no nvidia module (a kernel lacking linux-*-nvidia-open)
	# has no watchdog to configure; the conf's absence there is not a failure.
	if ! grep -qE '/nvidia\.ko' <<<"$listing"; then
		echo "  SKIP   $img (no nvidia module in this image)"
		continue
	fi
	if grep -qF "modprobe.d/$(basename "$CONF")" <<<"$listing"; then
		[[ $MODE == revert ]] && { echo "  STALE  $img still contains the conf"; fail=1; } || echo "  OK     $img"
	else
		[[ $MODE == revert ]] && echo "  OK     $img (conf removed)" || { echo "  MISSING $img"; fail=1; }
	fi
done
(( fail )) && { echo "ERROR: verification failed — do NOT rely on this until fixed." >&2; exit 1; }

echo
if [[ $MODE == revert ]]; then
	echo "Done. Reboot to return to the driver default (7 s)."
elif [[ $MODE == verify ]]; then
	echo "Verified: every image above contains $(basename "$CONF")."
else
	echo "Done. Reboot to apply. Then confirm with:"
	echo "  grep RegistryDwords /proc/driver/nvidia/params      # expect $KEY=$SECS"
	echo "Any future Xid 8 line in dmesg will show 'Notify Timeout Seconds: $SECS'."
fi
