#!/usr/bin/env bash
# installer.sh
# One-pass bootstrap for Ubuntu 22.04/24.04 GPU nodes:
# - Autologin on tty1 for a target user
# - Passwordless sudo for that user
# - Prereqs (toolchain, dkms, etc.)
# - NVIDIA CUDA repo keyring (auto-selects jammy/noble)
# - Optional NVIDIA driver (570|575|580) in headless or desktop mode
# - Docker + NVIDIA Container Toolkit
# - Nouveau blacklist + initramfs refresh
# - Build gpu-burn
# - Optional gpud agent
#
# Usage:
#   ./installer.sh --user ezc --driver 580 --mode headless
#   ./installer.sh --user ezc --driver 575 --mode desktop
#
# Flags:
#   --user <name>        Linux account to configure (default: ezc)
#   --driver <ver>       570 | 575 | 580 (default: 575)
#   --mode <type>        headless | desktop (default: headless)
#   --no-docker          Skip Docker + NVIDIA Container Toolkit
#   --no-autologin       Skip tty1 autologin configuration
#   --no-sudoers         Skip passwordless sudo
#   --no-gpuburn         Skip gpu-burn build
#   --no-gpud            Skip gpud installation
#   --noninteractive     APT runs non-interactively (CI-safe)

set -euo pipefail
set -o errtrace

# -------------------------- Self-elevate --------------------------------------
if (( EUID != 0 )); then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "$0" "$@"
  else
    echo "ERROR: root privileges required and 'sudo' not found." >&2
    exit 1
  fi
fi

# -------------------------- Defaults & CLI ------------------------------------
USER_NAME="ezc"
DRIVER_VER="575"
DRIVER_MODE="headless"
INSTALL_DOCKER=1
DO_AUTOLOGIN=1
DO_SUDOERS=1
DO_GPU_BURN=1
DO_GPUD=1
APT_NONINTERACTIVE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)           USER_NAME="${2:?}"; shift 2 ;;
    --driver)         DRIVER_VER="${2:?}"; shift 2 ;;
    --mode)           DRIVER_MODE="${2:?}"; shift 2 ;;
    --no-docker)      INSTALL_DOCKER=0; shift ;;
    --no-autologin)   DO_AUTOLOGIN=0; shift ;;
    --no-sudoers)     DO_SUDOERS=0; shift ;;
    --no-gpuburn)     DO_GPU_BURN=0; shift ;;
    --no-gpud)        DO_GPUD=0; shift ;;
    --noninteractive) APT_NONINTERACTIVE=1; shift ;;
    -h|--help)        grep -E '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [[ "$DRIVER_VER" != "570" && "$DRIVER_VER" != "575" && "$DRIVER_VER" != "580" ]]; then
  echo "ERROR: --driver must be 570, 575 or 580" >&2; exit 2
fi
if [[ "$DRIVER_MODE" != "headless" && "$DRIVER_MODE" != "desktop" ]]; then
  echo "ERROR: --mode must be headless or desktop" >&2; exit 2
fi

if [[ $APT_NONINTERACTIVE -eq 1 ]]; then
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  APT_FLAGS="-o Dpkg::Options::=--force-confnew -yq"
else
  APT_FLAGS="-y"
fi

log() { echo "[$(date +'%F %T')] $*"; }
on_err(){ echo "[ERROR] line $1: command failed"; }
trap 'on_err $LINENO' ERR

# -------------------------- OS Detection --------------------------------------
if [[ -r /etc/os-release ]]; then . /etc/os-release; else
  echo "ERROR: /etc/os-release not found." >&2; exit 1
fi
if [[ "${ID:-}" != "ubuntu" ]]; then
  echo "ERROR: Only Ubuntu 22.04/24.04 supported." >&2; exit 1
fi
VER_RAW="${VERSION_ID:-}"
VER_COMPACT="${VER_RAW//./}"
case "$VER_COMPACT" in
  2204) CUDA_DISTRO="ubuntu2204"; CODENAME="jammy" ;;
  2404) CUDA_DISTRO="ubuntu2404"; CODENAME="noble" ;;
  *) echo "ERROR: Unsupported Ubuntu ${VER_RAW}. Only 22.04 or 24.04." >&2; exit 1 ;;
esac
log "OS detected: Ubuntu ${VER_RAW} (${CODENAME}); CUDA repo path: ${CUDA_DISTRO}"

# -------------------------- Helpers -------------------------------------------
wait_for_apt() {
  local max_wait=300
  local waited=0
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    if (( waited >= max_wait )); then
      echo "ERROR: apt lock held for too long. Exiting." >&2
      exit 1
    fi
    echo "Waiting for apt lock... (${waited}s)"
    sleep 5
    waited=$((waited + 5))
  done
}

apt_retry() {
  # Transparent retry wrapper for apt-get commands
  wait_for_apt
  local n=0 max=4
  until "$@"; do
    n=$((n+1))
    if (( n >= max )); then return 1; fi
    sleep $((2*n))
    log "Retrying: $* (attempt ${n}/${max})"
    wait_for_apt
  done
}

require_pkgs() {
  log "Installing required packages: $*"
  apt_retry apt-get update -y
  apt_retry apt-get install $APT_FLAGS "$@"
}

ensure_user() {
  if ! id -u "$USER_NAME" >/dev/null 2>&1; then
    log "User '$USER_NAME' not found. Creating..."
    useradd -m -s /bin/bash "$USER_NAME"
    echo "${USER_NAME}:${USER_NAME}" | chpasswd  # Set password same as username (insecure but standard for test/bootstrap)
    log "User '$USER_NAME' created."
  fi
}

# -------------------------- Autologin (optional) ------------------------------
if [[ $DO_AUTOLOGIN -eq 1 ]]; then
  ensure_user
  log "Configuring tty1 autologin for user '${USER_NAME}'"
  
  # Use drop-in for logind.conf
  mkdir -p /etc/systemd/logind.conf.d
  cat >/etc/systemd/logind.conf.d/99-autologin.conf <<EOF
[Login]
NAutoVTs=1
ReservedVT=2
EOF

  # Use drop-in for getty@tty1
  mkdir -p /etc/systemd/system/getty@tty1.service.d/
  cat >/etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --noissue --autologin ${USER_NAME} %I \$TERM
EOF
  
  systemctl daemon-reload
  systemctl restart systemd-logind || true
fi

# -------------------------- Sudoers (optional) --------------------------------
if [[ $DO_SUDOERS -eq 1 ]]; then
  ensure_user
  log "Granting passwordless sudo to '${USER_NAME}'"
  mkdir -p /etc/sudoers.d
  SUDO_FILE="/etc/sudoers.d/${USER_NAME}"
  echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" > "$SUDO_FILE"
  chmod 0440 "$SUDO_FILE"
  if ! visudo -cf "$SUDO_FILE" >/dev/null; then
    echo "ERROR: sudoers validation failed; reverting." >&2
    rm -f "$SUDO_FILE"
    exit 1
  fi
fi

# -------------------------- Base Tooling --------------------------------------
log "Installing base toolchain and dependencies"
require_pkgs software-properties-common \
             apt-transport-https ca-certificates curl gnupg lsb-release \
             git cmake build-essential dkms alsa-utils ipmitool \
             gcc-12 g++-12 jq pciutils iproute2 util-linux dmidecode lshw coreutils

log "Adding Graphics Drivers PPA (idempotent)"
add-apt-repository -y ppa:graphics-drivers/ppa || true
apt_retry apt-get update -y

log "Configuring GCC/G++ alternatives"
if command -v gcc-11 >/dev/null 2>&1; then
  update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 11 || true
fi
if command -v g++-11 >/dev/null 2>&1; then
  update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-11 11 || true
fi
update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 12 || true
update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-12 12 || true

# -------------------------- CUDA Keyring (auto-select) ------------------------
log "Ensuring NVIDIA CUDA keyring for ${CUDA_DISTRO}"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
KEY_DEB="cuda-keyring_1.1-1_all.deb"
KEY_URL="https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_DISTRO}/x86_64/${KEY_DEB}"

if ! dpkg -s cuda-keyring >/dev/null 2>&1; then
  log "Downloading ${KEY_URL}"
  curl -fsSL "$KEY_URL" -o "${TMPD}/${KEY_DEB}"
  dpkg -i "${TMPD}/${KEY_DEB}"
else
  log "cuda-keyring already installed; skipping."
fi

log "Running apt-get update && upgrade"
apt_retry apt-get update -y
apt_retry apt-get upgrade $APT_FLAGS

# -------------------------- NVIDIA Driver (optional track) --------------------
if dpkg -l | grep -q "nvidia-driver"; then
    log "NVIDIA driver already installed. Skipping installation to avoid conflicts."
else
    if [[ "$DRIVER_MODE" == "headless" ]]; then
      PKGS=("nvidia-headless-${DRIVER_VER}-open" "nvidia-utils-${DRIVER_VER}")
    else
      PKGS=("nvidia-driver-${DRIVER_VER}-open")
    fi
    log "Installing NVIDIA driver packages (${DRIVER_MODE}): ${PKGS[*]}"
    apt_retry apt-get install $APT_FLAGS "${PKGS[@]}"
fi

# -------------------------- Docker + NVIDIA CTK (optional) --------------------
if [[ $INSTALL_DOCKER -eq 1 ]]; then
  log "Installing Docker Engine"
  mkdir -p /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  fi
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt_retry apt-get update -y
  apt_retry apt-get install $APT_FLAGS docker-ce docker-ce-cli containerd.io
  systemctl enable --now docker.service containerd.service

  log "Installing NVIDIA Container Toolkit"
  if [[ ! -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg ]]; then
      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  fi
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  sed -i 's/\$(ARCH)/amd64/g' /etc/apt/sources.list.d/nvidia-container-toolkit.list || true
  apt_retry apt-get update -y
  apt_retry apt-get install $APT_FLAGS nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker || true

  # Add a user to the docker group for convenience
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    usermod -aG docker "$SUDO_USER" || true
  elif [[ "$USER_NAME" != "root" ]]; then
    usermod -aG docker "$USER_NAME" || true
  fi
fi

# -------------------------- Blacklist nouveau ---------------------------------
log "Blacklisting nouveau and updating initramfs"
if ! grep -q '^blacklist nouveau' /etc/modprobe.d/blacklist.conf 2>/dev/null; then
  echo "blacklist nouveau" >> /etc/modprobe.d/blacklist.conf
fi
update-initramfs -u

# -------------------------- GPU Burn (optional) -------------------------------
if [[ $DO_GPU_BURN -eq 1 ]]; then
  log "Building gpu-burn"
  ensure_user
  TARGET_HOME=$(eval echo "~${USER_NAME}") || TARGET_HOME="/root"
  install -d -m 0755 "${TARGET_HOME}/gpu-burn"
  chown -R "${USER_NAME}:${USER_NAME}" "${TARGET_HOME}/gpu-burn"
  su - "$USER_NAME" -c "bash -lc '
    set -e
    if [[ ! -d ~/gpu-burn/.git ]]; then
      rm -rf ~/gpu-burn
      git clone https://github.com/wilicc/gpu-burn.git ~/gpu-burn
    fi
    cd ~/gpu-burn && make
  '"
fi

# -------------------------- gpud (optional) -----------------------------------
if [[ $DO_GPUD -eq 1 ]]; then
  log "Installing gpud"
  ensure_user
  su - "$USER_NAME" -c "bash -lc 'curl -fsSL https://pkg.gpud.dev/install.sh | sh'"
fi

log "Bootstrap complete. A reboot is recommended to ensure nouveau is removed and NVIDIA drivers load cleanly."
