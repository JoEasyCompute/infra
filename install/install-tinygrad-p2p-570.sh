#!/usr/bin/env bash
# Headless install: NVIDIA 570.148.08 userspace (no OpenGL/X, no kernel modules)
# + tinygrad P2P-patched open kernel modules for the same version.
# Target OS: Ubuntu 22.04 (Jammy)

set -euo pipefail

REQ_UBU="22.04"
DRV_VER="570.148.08"
RUNFILE="NVIDIA-Linux-x86_64-${DRV_VER}.run"
RUNURL_PRIMARY="https://us.download.nvidia.com/tesla/${DRV_VER}/${RUNFILE}"
DL_DIR="/root"
BUILD_DIR="/usr/src/tinygrad-open-gpu-kernel-modules"
TG_REPO="https://github.com/tinygrad/open-gpu-kernel-modules.git"
TG_TAG="570.148.08-p2p"

need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }; }
log(){ echo "[INFO] $*"; }
die(){ echo "[FAIL] $*" >&2; exit 1; }
need_root

. /etc/os-release
[[ "${VERSION_ID:-}" == "$REQ_UBU" ]] || log "Warning: expected Ubuntu $REQ_UBU, found ${VERSION_ID:-unknown}"

# Secure Boot gate (unsigned modules)
if command -v mokutil >/dev/null 2>&1; then
  if mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"; then
    die "Secure Boot is enabled. Disable it or sign the modules before proceeding."
  fi
fi

# Essentials + headers
apt-get update -y
apt-get install -y build-essential dkms linux-headers-$(uname -r) git wget curl pkg-config

# Blacklist nouveau (compute nodes don’t need it)
if ! grep -q "^blacklist nouveau" /etc/modprobe.d/blacklist-nouveau.conf 2>/dev/null; then
  cat >/etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
  update-initramfs -u
fi

# Ensure any old NVIDIA modules are unloaded (no GUI path here)
for m in nvidia_drm nvidia_modeset nvidia_uvm nvidia_fs nvidia; do
  if lsmod | grep -q "^${m}"; then rmmod "$m" || true; fi
done

# Get the .run package (exact version)
mkdir -p "$DL_DIR"
if [[ ! -f "${DL_DIR}/${RUNFILE}" ]]; then
  log "Downloading ${RUNFILE}…"
  wget -q --show-progress -O "${DL_DIR}/${RUNFILE}" "${RUNURL_PRIMARY}" || die "Download failed. Fetch manually and place in ${DL_DIR}."
fi
chmod +x "${DL_DIR}/${RUNFILE}"

# Install userspace ONLY, headless-friendly:
# --no-opengl-files: skip GLX/OpenGL stacks
# --no-kernel-modules: we will install tinygrad-built modules
# --no-x-check/--no-nouveau-check: suppress installer checks in headless
sh "${DL_DIR}/${RUNFILE}" \
  --silent \
  --no-opengl-files \
  --no-kernel-modules \
  --no-x-check \
  --no-nouveau-check || die "NVIDIA userspace install failed."

# Build & install tinygrad P2P-patched open kernel modules (version-pinned)
if [[ -d "$BUILD_DIR/.git" ]]; then
  git -C "$BUILD_DIR" fetch --tags
else
  rm -rf "$BUILD_DIR"
  git clone "$TG_REPO" "$BUILD_DIR"
fi
git -C "$BUILD_DIR" checkout -f "refs/tags/${TG_TAG}"

make -C "$BUILD_DIR" -j"$(nproc)" modules
make -C "$BUILD_DIR" -j"$(nproc)" modules_install

depmod -a
update-initramfs -u

# Load only what headless compute needs (no DRM)
modprobe nvidia
modprobe nvidia_uvm

# Enable persistence for stable long-running jobs
if command -v nvidia-smi >/dev/null 2>&1; then
  systemctl enable nvidia-persistenced >/dev/null 2>&1 || true
  systemctl start nvidia-persistenced || true
  nvidia-smi -pm 1 || true
fi

# Validation
echo
log "Validation:"
set +e
modinfo nvidia | egrep -i 'filename|version'
nvidia-smi || true
echo
echo ">>> Topology (P2P paths):"
nvidia-smi topo -m || true
echo
log "Install complete. Userspace + kernel modules should both report ${DRV_VER}."
log "If P2P is not visible yet, reboot once and re-check."
