#!/usr/bin/env bash
# provision-docker-disk.sh
# Provision a disk for Docker's data root (/var/lib/docker).
# Safe to run as a regular user; uses sudo internally.
#
# Usage:
#   ./provision-docker-disk.sh /dev/nvme1n1
#
# Notes:
#   - This script DESTROYS existing data on the device.
#   - Make sure to specify the correct device.
#   - Must be run before installing Docker.

set -euo pipefail

log() { echo -e "[INFO] $*"; }
warn() { echo -e "[WARN] $*" >&2; }
err() { echo -e "[ERROR] $*" >&2; exit 1; }

if [[ $# -ne 1 ]]; then
  err "Usage: $0 <block-device> (e.g. /dev/nvme1n1)"
fi

DEVICE="$1"

if [[ ! -b "$DEVICE" ]]; then
  err "Block device $DEVICE does not exist."
fi

MNT="/var/lib/docker"

log "Preparing device $DEVICE for Docker data root..."

# Unmount if mounted
if mount | grep -q "$DEVICE"; then
  warn "$DEVICE is currently mounted, unmounting..."
  sudo umount "$DEVICE" || true
fi

# Wipe filesystem signatures
log "Wiping existing signatures on $DEVICE..."
sudo wipefs -a "$DEVICE"

# Create filesystem
log "Creating ext4 filesystem on $DEVICE..."
sudo mkfs.ext4 -F -L docker-data "$DEVICE"

# Ensure mountpoint exists
sudo mkdir -p "$MNT"

# Backup existing data if present
if [[ -n "$(ls -A $MNT 2>/dev/null)" ]]; then
  warn "$MNT is not empty, moving old data to $MNT.old.$(date +%s)"
  sudo mv "$MNT" "$MNT.old.$(date +%s)"
  sudo mkdir -p "$MNT"
fi

# Get UUID
UUID=$(sudo blkid -s UUID -o value "$DEVICE")
if [[ -z "$UUID" ]]; then
  err "Failed to fetch UUID for $DEVICE"
fi

# Add to fstab if not already there
if ! grep -q "$UUID" /etc/fstab; then
  log "Adding entry to /etc/fstab..."
  echo "UUID=$UUID $MNT ext4 defaults 0 2" | sudo tee -a /etc/fstab >/dev/null
fi

# Mount
log "Mounting $DEVICE at $MNT..."
sudo mount "$MNT"

# Fix ownership
sudo chown root:root "$MNT"
sudo chmod 711 "$MNT"

log "Disk $DEVICE provisioned for Docker at $MNT"
