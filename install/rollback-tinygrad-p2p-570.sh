#!/usr/bin/env bash
# Headless rollback to official proprietary kernel modules (still 570.148.08)

set -euo pipefail
DRV_VER="570.148.08"
RUNFILE="NVIDIA-Linux-x86_64-${DRV_VER}.run"
DL_DIR="/root"

need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }; }
log(){ echo "[INFO] $*"; }
die(){ echo "[FAIL] $*" >&2; exit 1; }
need_root

if command -v mokutil >/dev/null 2>&1; then
  if mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"; then
    die "Secure Boot is enabled. Disable it or sign the modules."
  fi
fi

# Unload modules
for m in nvidia_drm nvidia_modeset nvidia_uvm nvidia_fs nvidia; do
  if lsmod | grep -q "^${m}"; then rmmod "$m" || true; fi
done

[[ -f "${DL_DIR}/${RUNFILE}" ]] || die "Missing ${DL_DIR}/${RUNFILE}."
chmod +x "${DL_DIR}/${RUNFILE}"

# Install official kernel modules (headless flags still ok)
sh "${DL_DIR}/${RUNFILE}" \
  --silent \
  --no-opengl-files \
  --no-x-check \
  --no-nouveau-check || die "Official module install failed."

log "Validation:"
modinfo nvidia | egrep -i 'filename|version'
nvidia-smi || true
log "Rollback complete."
