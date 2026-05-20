#!/usr/bin/env bash
# /usr/local/sbin/setup-esp-redundancy.sh
#
# ONE-TIME setup script. Run after a fresh install where only one ESP
# is populated. Does two things:
#   1. rsyncs /boot/efi to every other ESP partition on the system
#   2. Adds UEFI boot entries (efibootmgr) for each standby ESP so the
#      firmware can fall back to them if the primary drive dies.
#
# Safe to re-run: rsync is idempotent, and efibootmgr entries are
# skipped if a matching label already exists.

set -euo pipefail

ESP_MOUNT="/boot/efi"
ESP_TYPE_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
EFI_LOADER='\EFI\ubuntu\shimx64.efi'
TMP_MOUNT_BASE="/run/setup-esp"

command -v efibootmgr >/dev/null \
  || { echo "efibootmgr not installed (apt install efibootmgr)"; exit 1; }
[[ -d /sys/firmware/efi ]] \
  || { echo "system is not booted via UEFI; aborting"; exit 1; }

ACTIVE_ESP="$(findmnt -no SOURCE "$ESP_MOUNT")" \
  || { echo "$ESP_MOUNT is not mounted"; exit 1; }

mapfile -t ALL_ESPS < <(
  lsblk -rno NAME,PARTTYPE | \
    awk -v t="$ESP_TYPE_GUID" 'tolower($2)==t {print "/dev/"$1}'
)

echo "Active ESP : $ACTIVE_ESP"
echo "All ESPs   : ${ALL_ESPS[*]}"
echo

mkdir -p "$TMP_MOUNT_BASE"
trap 'umount "$TMP_MOUNT_BASE"/* 2>/dev/null; rm -rf "$TMP_MOUNT_BASE"' EXIT

i=2
for esp in "${ALL_ESPS[@]}"; do
  [[ "$esp" == "$ACTIVE_ESP" ]] && continue

  base="$(basename "$esp")"
  parent="/dev/$(lsblk -no PKNAME "$esp")"
  partnum="$(cat "/sys/class/block/${base}/partition")"
  label="ubuntu-disk${i}"

  # 1. Mount and replicate
  mnt="$TMP_MOUNT_BASE/$base"
  mkdir -p "$mnt"
  mount -t vfat -o rw "$esp" "$mnt"

  echo "==> Replicating to $esp"
  rsync -aHX --delete "$ESP_MOUNT/" "$mnt/"

  umount "$mnt"

  # 2. Add UEFI boot entry if missing
  if efibootmgr | grep -qE "^Boot[0-9A-Fa-f]{4}\*? ${label}\b"; then
    echo "    boot entry '$label' already present, skipping"
  else
    echo "    adding boot entry '$label' -> $parent partition $partnum"
    efibootmgr -c -d "$parent" -p "$partnum" \
               -L "$label" -l "$EFI_LOADER" >/dev/null
  fi

  i=$((i+1))
  echo
done

echo "Done. Current boot order:"
efibootmgr | grep -E '^(BootOrder|Boot[0-9A-Fa-f]{4}\*)'
echo
echo "Tip: use 'efibootmgr -o XXXX,YYYY,ZZZZ,WWWW' to set fallback order."
