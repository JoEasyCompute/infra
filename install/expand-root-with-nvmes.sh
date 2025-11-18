#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Expand root LV by absorbing selected NVMe disks
# - Detects root VG/LV automatically
# - Prompts per-disk before destructive wipe
# - Unmounts & comments fstab entries for the disk's partitions
# - Creates GPT + single partition, PV, vgextend, lvextend, and grows FS
# - Handles missing PV ghosts with vgreduce --removemissing
# Usage:
#   sudo bash expand-root-with-nvmes.sh [--dry-run]
# ============================================

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

say() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERR]\033[0m  $*" >&2; }
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ $*"
  else
    eval "$@"
  fi
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 1; }
}

need_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Please run as root (sudo)."
    exit 1
  fi
}

# -------- prerequisites
need_root
for b in lsblk findmnt blkid sed awk grep awk sgdisk parted wipefs pvcreate vgextend vgs pvs lvs lvextend df resize2fs xfs_growfs pvscan vgscan vgreduce vgdisplay vgck lvmdevices; do
  require_bin "$b" || true
done

# -------- discover root LV/VG and filesystem
ROOT_SRC="$(findmnt -no SOURCE /)"
ROOT_FSTYPE="$(findmnt -no FSTYPE /)"

if [[ "$ROOT_SRC" =~ ^/dev/mapper/ ]]; then
  # Map /dev/mapper/vg-lv -> VG & LV
  VG_NAME="$(lvs --noheadings -o vg_name "$ROOT_SRC" | awk '{$1=$1;print}')"
  LV_NAME="$(lvs --noheadings -o lv_name "$ROOT_SRC" | awk '{$1=$1;print}')"
  LV_PATH="/dev/${VG_NAME}/${LV_NAME}"
elif [[ "$ROOT_SRC" =~ ^/dev/[^/]+$ ]]; then
  # Not LVM? we’ll try to discover underlying LV via lsblk
  LV_PATH="$(lsblk -no NAME,TYPE "$ROOT_SRC" 2>/dev/null | awk '$2=="lvm"{print $1}' | head -n1)"
  if [[ -n "$LV_PATH" ]]; then
    LV_PATH="/dev/mapper/${LV_PATH}"
    VG_NAME="$(lvs --noheadings -o vg_name "$LV_PATH" | awk '{$1=$1;print}')"
    LV_NAME="$(lvs --noheadings -o lv_name "$LV_PATH" | awk '{$1=$1;print}')"
  fi
else
  err "Could not determine root LV from $ROOT_SRC"
  exit 1
fi

if [[ -z "${VG_NAME:-}" || -z "${LV_NAME:-}" ]]; then
  err "Unable to determine root VG/LV (found source: $ROOT_SRC). Aborting."
  exit 1
fi

say "Root filesystem: / ($ROOT_FSTYPE)"
say "Root LV path   : $LV_PATH"
say "Root VG/LV     : ${VG_NAME}/${LV_NAME}"

# -------- helper: comment out fstab entries for a device or its UUIDs
comment_fstab_for_part() {
  local part="$1"
  local ts="$(date +%Y%m%d-%H%M%S)"
  local fstab="/etc/fstab"
  local backup="/etc/fstab.backup.${ts}"
  [[ -f "$backup" ]] || run "cp -a $fstab $backup"

  local uuid=""
  if uuid="$(blkid -s UUID -o value "$part" 2>/dev/null)"; then
    :
  else
    uuid=""
  fi

  # Comment lines matching the specific /dev path or UUID=...
  if grep -Eq "^[^#].*(/dev/$(basename "$part")\b)" "$fstab" || { [[ -n "$uuid" ]] && grep -Eq "^[^#].*(UUID=${uuid})" "$fstab"; }; then
    say "Commenting out /etc/fstab entries for $part"
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "+ sed -i -E 's@^([^#].*(/dev/$(basename "$part")\\b|UUID=${uuid})).*@# \\0@' $fstab"
    else
      sed -i -E "s@^([^#].*(/dev/$(basename "$part")\\b|UUID=${uuid})).*@# \\0@" "$fstab"
    fi
  fi
}

unmount_part_if_mounted() {
  local part="$1"
  local mp
  mp="$(findmnt -rn -S "$part" -o TARGET || true)"
  if [[ -n "$mp" ]]; then
    warn "$part is mounted on $mp — unmounting"
    run "umount -l '$part' || true"
    # Also unmount by mountpoint if device nodes changed
    run "umount -l '$mp' || true"
    comment_fstab_for_part "$part"
  fi
}

# -------- scan for candidate NVMe disks
mapfile -t NVME_DISKS < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk" && $1 ~ /^nvme/ {print $1}')
if [[ ${#NVME_DISKS[@]} -eq 0 ]]; then
  err "No NVMe disks detected."
  exit 1
fi

say "Detected NVMe disks: ${NVME_DISKS[*]}"

# -------- process each NVMe disk interactively
SELECTED=()
for disk in "${NVME_DISKS[@]}"; do
  say "Inspecting /dev/$disk"
  # Show current layout
  lsblk "/dev/$disk"
  echo
  read -r -p ">>> ERASE and add /dev/$disk to VG '$VG_NAME'? (yes/NO) " ans
  if [[ "$ans" != "yes" ]]; then
    say "Skipping /dev/$disk"
    continue
  fi
  SELECTED+=("$disk")

  # Unmount any partitions and comment fstab
  mapfile -t PARTS < <(lsblk -nr -o NAME "/dev/$disk" | tail -n +2)
  for p in "${PARTS[@]}"; do
    part="/dev/$p"
    unmount_part_if_mounted "$part"
  done

  # Extra safety: ensure disk is not the one backing the root PV
  if lsblk -no NAME "$LV_PATH" | grep -q "^$disk\$"; then
    err "/dev/$disk appears to back the root LV; refusing to wipe."
    continue
  fi

  # Wipe & recreate partition table
  say "Wiping signatures and partition table on /dev/$disk"
  run "wipefs -a /dev/$disk || true"
  run "sgdisk --zap-all /dev/$disk || true"
  run "partprobe /dev/$disk || true"

  say "Creating GPT + single primary partition on /dev/$disk"
  run "parted -s /dev/$disk mklabel gpt"
  run "parted -s -a optimal /dev/$disk mkpart primary 0% 100%"
  run "partprobe /dev/$disk"

  # Figure out partition path (nvmeXnY -> nvmeXnYp1)
  PART="/dev/${disk}p1"
  # Wait for the node to appear
  for i in {1..10}; do
    [[ -b "$PART" ]] && break
    sleep 0.5
  done
  if [[ ! -b "$PART" ]]; then
    err "Partition $PART not found after creation; skipping this disk."
    continue
  fi

  # Ensure no stale LVM headers, then create PV
  run "wipefs -a $PART || true"
  run "pvremove -ff -y $PART >/dev/null 2>&1 || true"
  say "Creating PV on $PART"
  run "pvcreate -ff -y $PART"

  # Add to VG
  say "Extending VG '$VG_NAME' with $PART"
  run "vgextend $VG_NAME $PART || true"

  # If ghost PV warnings arise, clean them up
  if vgs 2>&1 | grep -qi "missing PV"; then
    warn "VG reports missing PVs. Cleaning up..."
    run "vgreduce --removemissing --force $VG_NAME || true"
    run "vgck --updatemetadata $VG_NAME || true"
    run "pvscan --cache || true"
    run "vgscan --cache || true"
    run "vgchange -ay $VG_NAME || true"
    run "vgscan --mknodes || true"
  fi
done

if [[ ${#SELECTED[@]} -eq 0 ]]; then
  warn "No disks selected; nothing to do."
  exit 0
fi

# -------- extend LV to all free space and grow filesystem
say "Extending LV $LV_PATH to consume all free space in VG '$VG_NAME'"
run "lvextend -l +100%FREE $LV_PATH"

say "Growing filesystem ($ROOT_FSTYPE) on /"
case "$ROOT_FSTYPE" in
  ext4)
    run "resize2fs $LV_PATH"
    ;;
  xfs)
    # Must use mountpoint for xfs_growfs
    run "xfs_growfs /"
    ;;
  *)
    warn "Unknown or unsupported FS type '$ROOT_FSTYPE'. Not resizing automatically."
    warn "Resize manually if needed."
    ;;
esac

say "All done. Summary:"
run "lsblk"
run "vgs"
run "lvs"
run "df -h /"
