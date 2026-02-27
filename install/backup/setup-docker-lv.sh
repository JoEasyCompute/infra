#!/usr/bin/env bash
set -euo pipefail

#############################################
# Configurable parameters
#############################################
VG_NAME="${VG_NAME:-ubuntu-vg}"        # default VG from Ubuntu 22.04 installer
LV_NAME="${LV_NAME:-docker-lv}"       # new logical volume name
MOUNT_POINT="${MOUNT_POINT:-/var/lib/docker}"
PERCENT_FREE="${PERCENT_FREE:-70}"    # use 70% of current free space in VG

#############################################
# Sanity checks
#############################################
if [[ $EUID -ne 0 ]]; then
  echo "Please run this script as root (sudo $0) or set EUID=0."
  exit 1
fi

echo ">>> Using VG:       ${VG_NAME}"
echo ">>> New LV name:    ${LV_NAME}"
echo ">>> Mount point:    ${MOUNT_POINT}"
echo ">>> Using           ${PERCENT_FREE}% of free space in VG"

# Check VG exists
if ! vgs "${VG_NAME}" &>/dev/null; then
  echo "ERROR: Volume group '${VG_NAME}' not found."
  exit 1
fi

# Check LV does not already exist
if lvs "${VG_NAME}/${LV_NAME}" &>/dev/null; then
  echo "ERROR: Logical volume '${VG_NAME}/${LV_NAME}' already exists. Aborting."
  exit 1
fi

#############################################
# Create LV using 70% of FREE space
#############################################
echo ">>> Creating LV '${LV_NAME}' using ${PERCENT_FREE}%FREE of VG '${VG_NAME}'..."
lvcreate -l "${PERCENT_FREE}%FREE" -n "${LV_NAME}" "${VG_NAME}"

LV_PATH="/dev/${VG_NAME}/${LV_NAME}"
echo ">>> LV created at ${LV_PATH}"

#############################################
# Format LV as XFS with ftype=1
#############################################
echo ">>> Formatting ${LV_PATH} as XFS (ftype=1)..."
mkfs.xfs -n ftype=1 "${LV_PATH}"

#############################################
# Get filesystem UUID
#############################################
UUID="$(blkid -s UUID -o value "${LV_PATH}")"
if [[ -z "${UUID}" ]]; then
  echo "ERROR: Unable to fetch UUID for ${LV_PATH}."
  exit 1
fi
echo ">>> Filesystem UUID: ${UUID}"

#############################################
# Stop Docker if running
#############################################
DOCKER_WAS_ACTIVE="false"
if systemctl is-active --quiet docker; then
  echo ">>> Docker service is active, stopping it..."
  DOCKER_WAS_ACTIVE="true"
  systemctl stop docker
fi

#############################################
# Prepare mount points and migrate data (if any)
#############################################
echo ">>> Ensuring mount point exists: ${MOUNT_POINT}"
mkdir -p "${MOUNT_POINT}"

TEMP_MOUNT="/mnt/docker-new"
echo ">>> Creating temporary mount point: ${TEMP_MOUNT}"
mkdir -p "${TEMP_MOUNT}"

echo ">>> Mounting new LV on ${TEMP_MOUNT}..."
mount "${LV_PATH}" "${TEMP_MOUNT}"

# If /var/lib/docker already has data, rsync it into the new filesystem
if [ -n "$(ls -A "${MOUNT_POINT}" 2>/dev/null || true)" ]; then
  echo ">>> Existing data detected in ${MOUNT_POINT}, migrating with rsync..."
  rsync -aHAXx "${MOUNT_POINT}/" "${TEMP_MOUNT}/"
else
  echo ">>> ${MOUNT_POINT} is empty, no data to migrate."
fi

echo ">>> Unmounting ${TEMP_MOUNT}..."
umount "${TEMP_MOUNT}"

#############################################
# Update /etc/fstab (UUID-based entry)
#############################################
echo ">>> Updating /etc/fstab (backup at /etc/fstab.bak)..."
cp /etc/fstab /etc/fstab.bak

# Remove any existing line for /var/lib/docker to avoid duplicates
sed -i "\|${MOUNT_POINT}|d" /etc/fstab

# Append new UUID-based entry
echo "UUID=${UUID} ${MOUNT_POINT} xfs rw,auto,pquota 0 0" >> /etc/fstab

echo ">>> New /etc/fstab entry:"
tail -n 1 /etc/fstab

#############################################
# Mount the new filesystem at /var/lib/docker
#############################################
echo ">>> Mounting ${MOUNT_POINT} from ${LV_PATH}..."
mount "${MOUNT_POINT}"

#############################################
# Start Docker if it was previously active
#############################################
if [[ "${DOCKER_WAS_ACTIVE}" == "true" ]]; then
  echo ">>> Restarting Docker service..."
  systemctl start docker
fi

echo ">>> Completed."
echo "LV:           ${LV_PATH}"
echo "Mount point:  ${MOUNT_POINT}"
echo "UUID:         ${UUID}"
echo "fstab entry:  UUID=${UUID} ${MOUNT_POINT} xfs rw,auto,pquota 0 0"
