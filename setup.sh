#!/usr/bin/env bash
# otikoboot setup: build, stage kernel+initrd on the ESP, add a boot entry
# alongside GRUB, and arm a ONE-SHOT boot into it (BootNext).
#
#   ./setup.sh                       install, using kernel 6.17.0-20-generic
#   ./setup.sh install 7.0.0-42-generic
#   ./setup.sh remove                delete the entry and the ESP files
#
# BootOrder is never changed, so GRUB/Zorin stays the default.
set -euo pipefail

CMD="${1:-install}"
KVER="${2:-6.17.0-20-generic}"
LABEL="otikoboot"
EXPECT_ROOT="/dev/nvme0n1p2"      # must match root= in loader.c

cd "$(dirname "$0")"

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[ -d /sys/firmware/efi ] || die "not booted in UEFI mode"
command -v sudo >/dev/null || die "sudo not found"

ESP_MNT=/boot/efi
ESP_DIR="$ESP_MNT/EFI/otiko"

entry_num() {
    sudo efibootmgr | sed -n "s/^Boot\([0-9A-Fa-f]\{4\}\)\*\{0,1\} *${LABEL}.*/\1/p" | head -1
}

if [ "$CMD" = "remove" ]; then
    NUM="$(entry_num || true)"
    if [ -n "$NUM" ]; then
        info "removing boot entry Boot$NUM"
        sudo efibootmgr -B -b "$NUM" >/dev/null
    else
        info "no $LABEL boot entry found"
    fi
    info "removing $ESP_DIR"
    sudo rm -rf "$ESP_DIR"
    info "done"
    exit 0
fi

[ "$CMD" = "install" ] || die "usage: $0 [install [kver] | remove]"

# --- sanity checks -----------------------------------------------------------
KERNEL="/boot/vmlinuz-$KVER"
INITRD="/boot/initrd.img-$KVER"
[ -e "$KERNEL" ] || die "$KERNEL not found (ls /boot)"
[ -e "$INITRD" ] || die "$INITRD not found (ls /boot)"

ROOT_SRC="$(findmnt -no SOURCE /)"
[ "$ROOT_SRC" = "$EXPECT_ROOT" ] || \
    die "root is $ROOT_SRC but loader.c uses root=$EXPECT_ROOT; fix loader.c first"

ESP_DEV="$(findmnt -no SOURCE "$ESP_MNT")" || die "$ESP_MNT is not mounted"
ESP_BASE="$(basename "$ESP_DEV")"
DISK="/dev/$(lsblk -no PKNAME "$ESP_DEV" | head -1)"
PART="$(cat "/sys/class/block/$ESP_BASE/partition")"
info "ESP: $ESP_DEV (disk $DISK, partition $PART)"

NEED_KB=$(( ( $(sudo stat -Lc %s "$KERNEL") + $(sudo stat -Lc %s "$INITRD") ) / 1024 + 20000 ))
AVAIL_KB="$(df --output=avail -k "$ESP_MNT" | tail -1 | tr -d ' ')"
[ "$AVAIL_KB" -gt "$NEED_KB" ] || die "not enough space on ESP"

if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
    echo "WARNING: Secure Boot is ENABLED. The unsigned loader.efi will not run."
    echo "         Disable Secure Boot in firmware before rebooting into it."
fi

# --- build -------------------------------------------------------------------
if ! dpkg -s gnu-efi >/dev/null 2>&1 || ! command -v efibootmgr >/dev/null; then
    info "installing build dependencies"
    sudo apt-get install -y gnu-efi build-essential efibootmgr
fi
info "building"
make clean >/dev/null
make

# --- stage on ESP ------------------------------------------------------------
info "staging kernel $KVER on the ESP"
sudo mkdir -p "$ESP_DIR"
sudo cp "$KERNEL"    "$ESP_DIR/vmlinuz"
sudo cp "$INITRD"    "$ESP_DIR/initrd.img"
sudo cp loader.efi   "$ESP_DIR/loader.efi"
sync

# --- boot entry (does not touch BootOrder) ----------------------------------
NUM="$(entry_num || true)"
if [ -z "$NUM" ]; then
    info "creating boot entry"
    sudo efibootmgr -C --disk "$DISK" --part "$PART" --label "$LABEL" \
        --loader '\EFI\otiko\loader.efi' >/dev/null
    NUM="$(entry_num)"
fi
[ -n "$NUM" ] || die "could not find the $LABEL entry in efibootmgr output"

info "arming one-shot boot (BootNext = Boot$NUM)"
sudo efibootmgr -n "$NUM" >/dev/null

echo
sudo efibootmgr | grep -E "BootNext|BootOrder|$LABEL"
echo
echo "Ready. Make sure Secure Boot is off, then: sudo reboot"
echo "After boot: uname -r  (expect $KVER)  and  cat /proc/cmdline  (expect initrd=\\EFI\\otiko\\initrd.img, no BOOT_IMAGE=)"
echo "If it hangs, power-cycle: BootNext was one-shot, so you land back in GRUB."
