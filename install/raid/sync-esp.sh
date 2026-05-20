#!/usr/bin/env bash
# /usr/local/sbin/sync-esp.sh
#
# Replicate the currently-mounted EFI System Partition to all other ESPs
# on the system. Idempotent and safe to run frequently. Logs to syslog
# under the tag "sync-esp" (view with: journalctl -t sync-esp).
#
# Detects ESPs by partition type GUID, so it works regardless of how
# many drives you have or what they're named (nvme*, sd*, etc.).

set -euo pipefail

ESP_MOUNT="/boot/efi"
ESP_TYPE_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
TMP_MOUNT_BASE="/run/sync-esp"
LOCK_FILE="/run/sync-esp.lock"

log()  { logger -t sync-esp -- "$*"; printf '%s\n' "$*"; }
warn() { logger -t sync-esp -p user.warn -- "$*"; printf 'WARN: %s\n' "$*" >&2; }
die()  { logger -t sync-esp -p user.err  -- "$*"; printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -d "$TMP_MOUNT_BASE" ]]; then
    for m in "$TMP_MOUNT_BASE"/*; do
      [[ -d "$m" ]] && mountpoint -q "$m" && umount "$m" 2>/dev/null || true
    done
    rmdir "$TMP_MOUNT_BASE"/* 2>/dev/null || true
    rmdir "$TMP_MOUNT_BASE"   2>/dev/null || true
  fi
}
trap cleanup EXIT

# Single-instance lock so dpkg + timer can't collide
exec 9>"$LOCK_FILE"
flock -n 9 || { log "another instance running, exiting"; exit 0; }

ACTIVE_ESP="$(findmnt -no SOURCE "$ESP_MOUNT")" \
  || die "$ESP_MOUNT is not mounted"

mapfile -t ALL_ESPS < <(
  lsblk -rno NAME,PARTTYPE | \
    awk -v t="$ESP_TYPE_GUID" 'tolower($2)==t {print "/dev/"$1}'
)

(( ${#ALL_ESPS[@]} > 1 )) \
  || die "only ${#ALL_ESPS[@]} ESP found, nothing to sync"

log "active=$ACTIVE_ESP, total ESPs=${#ALL_ESPS[@]}"
mkdir -p "$TMP_MOUNT_BASE"

rc=0
for esp in "${ALL_ESPS[@]}"; do
  [[ "$esp" == "$ACTIVE_ESP" ]] && continue

  mnt="$TMP_MOUNT_BASE/$(basename "$esp")"
  mkdir -p "$mnt"

  if ! mount -t vfat -o rw "$esp" "$mnt" 2>/dev/null; then
    warn "could not mount $esp, skipping"
    rc=1
    continue
  fi

  if rsync -aHX --delete "$ESP_MOUNT/" "$mnt/"; then
    log "synced -> $esp"
  else
    warn "rsync to $esp returned non-zero"
    rc=1
  fi

  umount "$mnt"
done

exit "$rc"
