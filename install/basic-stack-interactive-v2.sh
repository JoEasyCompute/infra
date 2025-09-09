#!/usr/bin/env bash
# basic-stack-interactive-v3.sh
# Interactive, sudo-aware bootstrap for Ubuntu 22.04/24.04 GPU nodes.
# - Actions: Install/Configure OR Roll back tinygrad P2P → official 570.148.08
# - Consolidated driver-choice menu (mutually exclusive): 570 stock / 570 tinygrad P2P / 575 / 580 / None
# - Uses sudo internally; you do NOT need to run this script with sudo.
# - Supports Docker + NVIDIA CTK (with hardened keyring/repo setup), CUDA toolkit, gpu-burn, gpud, autologin, sudoers.

set -euo pipefail

# -------------------------- Utilities ------------------------------------------
SUDO=""
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo -E"
  else
    echo "ERROR: This script needs root privileges occasionally and 'sudo' is not available." >&2
    exit 1
  fi
fi

log(){ echo "[INFO] $*"; }
warn(){ echo "[WARN] $*" >&2; }
die(){ echo "[FAIL] $*" >&2; exit 1; }

apt_retry(){
  local n=0 max=5 sleep_s=5
  until "$@"; do
    n=$((n+1))
    if (( n >= max )); then
      return 1
    fi
    sleep $sleep_s
  done
}

ask_default(){
  local prompt="$1"; local def="$2"; local ans=""
  read -rp "$prompt [$def]: " ans || true
  if [[ -z "$ans" ]]; then echo "$def"; else echo "$ans"; fi
}

ask_yes_no(){
  local prompt="$1"; local def="${2^^}"; local ans=""
  while true; do
    read -rp "$prompt [${def}]: " ans || true
    ans="${ans:-$def}"; ans="${ans^^}"
    case "$ans" in
      Y|YES) echo "Y"; return 0;;
      N|NO)  echo "N"; return 0;;
    esac
    echo "Please answer Y or N."
  done
}

have(){ command -v "$1" >/dev/null 2>&1; }

secure_boot_check(){
  if have mokutil; then
    if mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"; then
      die "Secure Boot is enabled. Disable it or sign the modules before proceeding."
    fi
  fi
}

ensure_user(){
  local u="$1"
  id -u "$u" >/dev/null 2>&1 || die "User '$u' does not exist. Create it first."
}

unload_nvidia(){
  for m in nvidia_drm nvidia_modeset nvidia_uvm nvidia_fs nvidia; do
    if lsmod | grep -q "^${m}"; then
      if [[ -n "$SUDO" ]]; then $SUDO rmmod "$m" || true; else rmmod "$m" || true; fi
    fi
  done
}

# -------------------------- Distro gates ---------------------------------------
. /etc/os-release
CODENAME="${VERSION_CODENAME:-jammy}"
if [[ "$CODENAME" != "jammy" && "$CODENAME" != "noble" ]]; then
  warn "This script is tuned for Ubuntu 22.04 (jammy) and 24.04 (noble). Detected: $CODENAME."
fi
CUDA_DISTRO="ubuntu2204"
[[ "$CODENAME" == "noble" ]] && CUDA_DISTRO="ubuntu2404"

# -------------------------- Action choice --------------------------------------
echo "Select action:"
echo "  1) Install / Configure"
echo "  2) Roll back tinygrad P2P → official 570.148.08 kernel modules"
echo "  3) Exit"
ACTION=$(ask_default "Select [1-3]" "1")

if [[ "$ACTION" == "2" ]]; then
  # ---------------------- Rollback path ----------------------------------------
  secure_boot_check
  RUNFILE_DEFAULT="/tmp/NVIDIA-Linux-x86_64-570.148.08.run"
  RUNFILE="$(ask_default 'Path to NVIDIA 570.148.08 .run (will be downloaded if missing)' "$RUNFILE_DEFAULT")"
  PURGE_TINYGRAD_DIR="$(ask_default 'Purge tinygrad build dir (/usr/src/tinygrad-open-gpu-kernel-modules)? (Y/N)' "N")"

  # Ensure prerequisites
  if [[ -n "$SUDO" ]]; then
    apt_retry $SUDO apt-get update -y
    apt_retry $SUDO apt-get install -y build-essential dkms linux-headers-$(uname -r) curl
  else
    apt-get update -y
    apt-get install -y build-essential dkms linux-headers-$(uname -r) curl
  fi

  # Fetch the .run if needed
  if [[ ! -f "$RUNFILE" ]]; then
    URL="https://us.download.nvidia.com/tesla/570.148.08/$(basename "$RUNFILE")"
    log "Downloading official NVIDIA .run from ${URL}"
    if ! curl -fSL "$URL" -o "$RUNFILE"; then
      die "Failed to download the .run file. Download it manually and re-run."
    fi
  fi
  if [[ -n "$SUDO" ]]; then $SUDO chmod +x "$RUNFILE"; else chmod +x "$RUNFILE"; fi

  log "Unloading current NVIDIA modules (if loaded)…"
  unload_nvidia

  log "Installing official NVIDIA 570.148.08 kernel modules from .run"
  if [[ -n "$SUDO" ]]; then
    $SUDO sh "$RUNFILE" --silent --no-opengl-files --no-x-check --no-nouveau-check
  else
    sh "$RUNFILE" --silent --no-opengl-files --no-x-check --no-nouveau-check
  fi

  log "Reloading modules"
  if [[ -n "$SUDO" ]]; then
    $SUDO depmod -a
    $SUDO update-initramfs -u
    $SUDO modprobe nvidia
    $SUDO modprobe nvidia_uvm
  else
    depmod -a
    update-initramfs -u
    modprobe nvidia
    modprobe nvidia_uvm
  fi

  if have nvidia-smi; then
    if [[ -n "$SUDO" ]]; then
      $SUDO systemctl enable nvidia-persistenced >/dev/null 2>&1 || true
      $SUDO systemctl start nvidia-persistenced || true
    else
      systemctl enable nvidia-persistenced >/dev/null 2>&1 || true
      systemctl start nvidia-persistenced || true
    fi
    nvidia-smi -pm 1 || true
  fi

  if [[ "${PURGE_TINYGRAD_DIR^^}" == "Y" ]]; then
    if [[ -n "$SUDO" ]]; then
      $SUDO rm -rf /usr/src/tinygrad-open-gpu-kernel-modules || true
    else
      rm -rf /usr/src/tinygrad-open-gpu-kernel-modules || true
    fi
    log "Removed /usr/src/tinygrad-open-gpu-kernel-modules"
  fi

  echo
  log "Validation:"
  if have modinfo; then modinfo nvidia | egrep -i 'filename|version' || true; fi
  if have nvidia-smi; then nvidia-smi || true; echo; nvidia-smi topo -m || true; fi

  log "Rollback complete. A reboot is recommended."
  exit 0
elif [[ "$ACTION" == "3" ]]; then
  echo "No action taken."; exit 0
fi

# -------------------------- Interactive inputs (Install path) ------------------
CURRENT_USER="${SUDO_USER:-${USER}}"
TARGET_USER=$(ask_default "Target user to configure (docker group, autologin/sudoers)" "$CURRENT_USER")

echo "Which NVIDIA driver path do you want?"
echo "  1) 570 (stock, via apt)"
echo "  2) 570 (tinygrad P2P-patched, requires 570.148.08 .run)"
echo "  3) 575 (via apt)"
echo "  4) 580 (via apt)"
echo "  5) No NVIDIA driver"
DRV_CHOICE=$(ask_default "Select [1-5]" "3")

DRIVER_VER="none"
DRIVER_MODE="headless"
P2P_OPEN="N"
RUNFILE_DEFAULT="/tmp/NVIDIA-Linux-x86_64-570.148.08.run"
RUNFILE="$RUNFILE_DEFAULT"

case "$DRV_CHOICE" in
  1)
    DRIVER_VER="570"
    DRIVER_MODE=$(ask_default "Driver mode (headless/desktop)" "headless")
    ;;
  2)
    DRIVER_VER="570"
    DRIVER_MODE="headless"
    P2P_OPEN="Y"
    RUNFILE=$(ask_default "Path for NVIDIA 570.148.08 .run (userspace-only install)" "$RUNFILE_DEFAULT")
    ;;
  3)
    DRIVER_VER="575"
    DRIVER_MODE=$(ask_default "Driver mode (headless/desktop)" "headless")
    ;;
  4)
    DRIVER_VER="580"
    DRIVER_MODE=$(ask_default "Driver mode (headless/desktop)" "headless")
    ;;
  5)
    DRIVER_VER="none"
    ;;
  *)
    echo "Invalid selection."; exit 2;;
esac

if [[ "$DRIVER_VER" != "none" && "$DRIVER_MODE" != "headless" && "$DRIVER_MODE" != "desktop" ]]; then
  die "--mode must be headless or desktop"
fi

INSTALL_DOCKER=$(ask_yes_no "Install Docker + NVIDIA Container Toolkit?" "Y")
INSTALL_CUDA=$(ask_yes_no "Install CUDA toolkit?" "N")
CUDA_VER="12.4"
if [[ "$INSTALL_CUDA" == "Y" ]]; then
  CUDA_VER=$(ask_default "CUDA toolkit version (e.g., 12.4)" "12.4")
fi
BUILD_GPU_BURN=$(ask_yes_no "Build gpu-burn under the target user home?" "Y")
INSTALL_GPUD=$(ask_yes_no "Install gpud agent?" "N")
SET_AUTOLOGIN=$(ask_yes_no "Enable tty1 autologin for the target user?" "N")
SET_SUDOERS=$(ask_yes_no "Grant passwordless sudo to the target user?" "N")

# -------------------------- Preconditions --------------------------------------
ensure_user "$TARGET_USER"
secure_boot_check

log "Refreshing apt metadata and upgrading base packages"
if [[ -n "$SUDO" ]]; then
  apt_retry $SUDO apt-get update -y
  apt_retry $SUDO apt-get upgrade -y
else
  apt_retry apt-get update -y
  apt_retry apt-get upgrade -y
fi

log "Installing baseline build and packaging prerequisites"
PKG_BASE="build-essential dkms linux-headers-$(uname -r) git wget curl pkg-config ca-certificates gnupg lsb-release"
if [[ -n "$SUDO" ]]; then
  apt_retry $SUDO apt-get install -y $PKG_BASE
else
  apt_retry apt-get install -y $PKG_BASE
fi

# Add Graphics Drivers PPA (idempotent) for apt-based installs
if [[ "$DRIVER_VER" != "none" && "$P2P_OPEN" != "Y" ]]; then
  log "Adding Graphics Drivers PPA (idempotent)"
  if [[ -n "$SUDO" ]]; then
    $SUDO add-apt-repository -y ppa:graphics-drivers/ppa || true
    apt_retry $SUDO apt-get update -y
  else
    add-apt-repository -y ppa:graphics-drivers/ppa || true
    apt_retry apt-get update -y
  fi
fi

# -------------------------- CUDA Keyring ---------------------------------------
log "Ensuring NVIDIA CUDA keyring for ${CUDA_DISTRO}"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
KEY_DEB="cuda-keyring_1.1-1_all.deb"
KEY_URL="https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_DISTRO}/x86_64/${KEY_DEB}"
if ! dpkg -s cuda-keyring >/dev/null 2>&1; then
  log "Downloading ${KEY_URL}"
  curl -fsSL "$KEY_URL" -o "${TMPD}/${KEY_DEB}"
  if [[ -n "$SUDO" ]]; then
    $SUDO dpkg -i "${TMPD}/${KEY_DEB}"
  else
    dpkg -i "${TMPD}/${KEY_DEB}"
  fi
else
  log "cuda-keyring already installed; skipping."
fi

# -------------------------- Optional autologin ---------------------------------
if [[ "$SET_AUTOLOGIN" == "Y" ]]; then
  log "Configuring tty1 autologin for user '${TARGET_USER}'"
  if [[ -n "$SUDO" ]]; then
    $SUDO sed -i -e 's/^#\?NAutoVTs=.*/NAutoVTs=1/' -e 's/^#\?ReservedVT=.*/ReservedVT=2/' /etc/systemd/logind.conf || true
    $SUDO mkdir -p /etc/systemd/system/getty@tty1.service.d/
    $SUDO bash -c "cat >/etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --noissue --autologin ${TARGET_USER} %I \$TERM
EOF"
    $SUDO systemctl daemon-reload
    $SUDO systemctl restart systemd-logind || true
  else
    sed -i -e 's/^#\?NAutoVTs=.*/NAutoVTs=1/' -e 's/^#\?ReservedVT=.*/ReservedVT=2/' /etc/systemd/logind.conf || true
    mkdir -p /etc/systemd/system/getty@tty1.service.d/
    cat >/etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --noissue --autologin ${TARGET_USER} %I \$TERM
EOF
    systemctl daemon-reload
    systemctl restart systemd-logind || true
  fi
fi

# -------------------------- Optional sudoers -----------------------------------
if [[ "$SET_SUDOERS" == "Y" ]]; then
  log "Granting passwordless sudo to '${TARGET_USER}'"
  if [[ -n "$SUDO" ]]; then
    $SUDO mkdir -p /etc/sudoers.d
    SUDO_FILE="/etc/sudoers.d/${TARGET_USER}"
    echo "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" | $SUDO tee "$SUDO_FILE" >/dev/null
    $SUDO chmod 0440 "$SUDO_FILE"
    $SUDO visudo -cf "$SUDO_FILE" >/dev/null || { $SUDO rm -f "$SUDO_FILE"; die "sudoers validation failed; reverted."; }
  else
    mkdir -p /etc/sudoers.d
    SUDO_FILE="/etc/sudoers.d/${TARGET_USER}"
    echo "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" > "$SUDO_FILE"
    chmod 0440 "$SUDO_FILE"
    visudo -cf "$SUDO_FILE" >/dev/null || { rm -f "$SUDO_FILE"; die "sudoers validation failed; reverted."; }
  fi
fi

# -------------------------- Blacklist nouveau ----------------------------------
log "Blacklisting nouveau and updating initramfs"
if ! grep -q '^blacklist nouveau' /etc/modprobe.d/blacklist.conf 2>/dev/null; then
  if [[ -n "$SUDO" ]]; then
    echo "blacklist nouveau" | $SUDO tee -a /etc/modprobe.d/blacklist.conf >/dev/null
  else
    echo "blacklist nouveau" >> /etc/modprobe.d/blacklist.conf
  fi
fi
if [[ -n "$SUDO" ]]; then $SUDO update-initramfs -u; else update-initramfs -u; fi

# -------------------------- NVIDIA drivers -------------------------------------
install_tinygrad_p2p_open(){
  secure_boot_check
  log "Installing prerequisites for building open kernel modules"
  if [[ -n "$SUDO" ]]; then
    apt_retry $SUDO apt-get install -y build-essential dkms linux-headers-$(uname -r) git wget curl pkg-config
  else
    apt_retry apt-get install -y build-essential dkms linux-headers-$(uname -r) git wget curl pkg-config
  fi

  local runfile="$RUNFILE"
  local drv_tag="570.148.08"
  local tg_repo="https://github.com/tinygrad/open-gpu-kernel-modules.git"
  local tg_tag="570.148.08-p2p"
  local build_dir="/usr/src/tinygrad-open-gpu-kernel-modules"

  if [[ ! -f "$runfile" ]]; then
    local url="https://us.download.nvidia.com/tesla/${drv_tag}/$(basename "$runfile")"
    log "Downloading NVIDIA userspace ${drv_tag} to $runfile"
    curl -fSL "$url" -o "$runfile"
  fi
  if [[ -n "$SUDO" ]]; then $SUDO chmod +x "$runfile"; else chmod +x "$runfile"; fi

  log "Installing NVIDIA userspace ${drv_tag} (no kernel modules, headless)"
  if [[ -n "$SUDO" ]]; then
    $SUDO sh "$runfile" --silent --no-opengl-files --no-kernel-modules --no-x-check --no-nouveau-check
  else
    sh "$runfile" --silent --no-opengl-files --no-kernel-modules --no-x-check --no-nouveau-check
  fi

  if [[ -d "$build_dir/.git" ]]; then
    log "Updating tinygrad open-gpu-kernel-modules"
    if [[ -n "$SUDO" ]]; then $SUDO git -C "$build_dir" fetch --tags; else git -C "$build_dir" fetch --tags; fi
  else
    if [[ -n "$SUDO" ]]; then $SUDO rm -rf "$build_dir"; else rm -rf "$build_dir"; fi
    if [[ -n "$SUDO" ]]; then $SUDO git clone "$tg_repo" "$build_dir"; else git clone "$tg_repo" "$build_dir"; fi
  fi
  if [[ -n "$SUDO" ]]; then $SUDO git -C "$build_dir" checkout -f "refs/tags/${tg_tag}"; else git -C "$build_dir" checkout -f "refs/tags/${tg_tag}"; fi

  log "Building tinygrad OPEN modules (${tg_tag})"
  if [[ -n "$SUDO" ]]; then $SUDO make -C "$build_dir" -j"$(nproc)" modules; else make -C "$build_dir" -j"$(nproc)" modules; fi
  log "Installing modules"
  if [[ -n "$SUDO" ]]; then $SUDO make -C "$build_dir" -j"$(nproc)" modules_install; else make -C "$build_dir" -j"$(nproc)" modules_install; fi

  if [[ -n "$SUDO" ]]; then $SUDO depmod -a; $SUDO update-initramfs -u; else depmod -a; update-initramfs -u; fi
  if [[ -n "$SUDO" ]]; then $SUDO modprobe nvidia; $SUDO modprobe nvidia_uvm; else modprobe nvidia; modprobe nvidia_uvm; fi

  if have nvidia-smi; then
    if [[ -n "$SUDO" ]]; then
      $SUDO systemctl enable nvidia-persistenced >/dev/null 2>&1 || true
      $SUDO systemctl start nvidia-persistenced || true
    else
      systemctl enable nvidia-persistenced >/dev/null 2>&1 || true
      systemctl start nvidia-persistenced || true
    fi
    nvidia-smi -pm 1 || true
  fi

  log "tinygrad P2P open modules installed. Expect driver/library 570.148.08."
}

if [[ "$DRIVER_VER" == "none" ]]; then
  log "Skipping NVIDIA driver installation per selection."
elif [[ "$P2P_OPEN" == "Y" ]]; then
  log "P2P path selected: NVIDIA 570.148.08 userspace + tinygrad open kernel modules (headless)"
  install_tinygrad_p2p_open
else
  log "Installing NVIDIA driver (${DRIVER_MODE}) via apt"
  if [[ "$DRIVER_MODE" == "headless" ]]; then
    PKGS=("nvidia-headless-${DRIVER_VER}-open" "nvidia-utils-${DRIVER_VER}")
  else
    PKGS=("nvidia-driver-${DRIVER_VER}-open")
  fi
  if [[ -n "$SUDO" ]]; then
    apt_retry $SUDO apt-get install -y "${PKGS[@]}"
  else
    apt_retry apt-get install -y "${PKGS[@]}"
  fi
  if have nvidia-smi; then
    if [[ -n "$SUDO" ]]; then
      $SUDO systemctl enable nvidia-persistenced >/dev/null 2>&1 || true
      $SUDO systemctl start nvidia-persistenced || true
    else
      systemctl enable nvidia-persistenced >/dev/null 2>&1 || true
      systemctl start nvidia-persistenced || true
    fi
    nvidia-smi -pm 1 || true
  fi
fi

# -------------------------- Docker + NVIDIA CTK (optional) ---------------------
if [[ "$(echo "$INSTALL_DOCKER" | tr '[:lower:]' '[:upper:]')" == "Y" ]]; then
  log "Installing Docker Engine"
  if [[ -n "$SUDO" ]]; then
    apt_retry $SUDO apt-get install -y apt-transport-https ca-certificates curl gnupg
    $SUDO install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
    $SUDO bash -c 'echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list'
    apt_retry $SUDO apt-get update -y
    apt_retry $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    apt_retry apt-get install -y apt-transport-https ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    bash -c 'echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list'
    apt_retry apt-get update -y
    apt_retry apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  log "Installing NVIDIA Container Toolkit"
  # --- Harden NVIDIA Container Toolkit apt repo (idempotent) ---
  if [[ -n "$SUDO" ]]; then
    $SUDO rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list || true
    $SUDO install -m 0755 -d /usr/share/keyrings
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | $SUDO gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#^deb .*stable/deb/#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/#' \
      | $SUDO tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
    apt_retry $SUDO apt-get update -y
  else
    rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list || true
    install -m 0755 -d /usr/share/keyrings
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#^deb .*stable/deb/#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/#' \
      | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
    apt_retry apt-get update -y
  fi
  # --- End harden ---

  if [[ -n "$SUDO" ]]; then
    apt_retry $SUDO apt-get install -y nvidia-container-toolkit
    $SUDO nvidia-ctk runtime configure --runtime=docker || true
    $SUDO systemctl restart docker || true
    $SUDO usermod -aG docker "$TARGET_USER"
  else
    apt_retry apt-get install -y nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker || true
    systemctl restart docker || true
    usermod -aG docker "$TARGET_USER"
  fi
  log "Docker installed; user '$TARGET_USER' added to docker group (re-login required)."
fi

# -------------------------- CUDA toolkit (optional) ----------------------------
if [[ "$(echo "$INSTALL_CUDA" | tr '[:lower:]' '[:upper:]')" == "Y" ]]; then
  log "Installing CUDA toolkit ${CUDA_VER}"
  if [[ -n "$SUDO" ]]; then
    curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_DISTRO}/x86_64/3bf863cc.pub | $SUDO gpg --dearmor -o /usr/share/keyrings/cuda.gpg
    echo "deb [signed-by=/usr/share/keyrings/cuda.gpg] https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_DISTRO}/x86_64/ /" | \
      $SUDO tee /etc/apt/sources.list.d/cuda.repo >/dev/null
    apt_retry $SUDO apt-get update -y
    dash_ver="$(echo "$CUDA_VER" | tr '.' '-')"
    apt_retry $SUDO apt-get install -y cuda-toolkit-${dash_ver}
  else
    curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_DISTRO}/x86_64/3bf863cc.pub | gpg --dearmor -o /usr/share/keyrings/cuda.gpg
    echo "deb [signed-by=/usr/share/keyrings/cuda.gpg] https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_DISTRO}/x86_64/ /" > /etc/apt/sources.list.d/cuda.repo
    apt_retry apt-get update -y
    dash_ver="$(echo "$CUDA_VER" | tr '.' '-')"
    apt_retry apt-get install -y cuda-toolkit-${dash_ver}
  fi
fi

# -------------------------- GPU Burn (optional) --------------------------------
if [[ "$(echo "$BUILD_GPU_BURN" | tr '[:lower:]' '[:upper:]')" == "Y" ]]; then
  log "Building gpu-burn"
  TARGET_HOME=$(eval echo "~${TARGET_USER}") || TARGET_HOME="/root"
  if [[ -n "$SUDO" ]]; then
    $SUDO install -d -m 0755 "${TARGET_HOME}/gpu-burn"
    $SUDO chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/gpu-burn"
    sudo -u "$TARGET_USER" bash -lc '
      set -e
      if [[ ! -d ~/gpu-burn/.git ]]; then
        rm -rf ~/gpu-burn
        git clone https://github.com/wilicc/gpu-burn.git ~/gpu-burn
      fi
      cd ~/gpu-burn && make
    '
  else
    install -d -m 0755 "${TARGET_HOME}/gpu-burn"
    chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/gpu-burn"
    sudo -u "$TARGET_USER" bash -lc '
      set -e
      if [[ ! -d ~/gpu-burn/.git ]]; then
        rm -rf ~/gpu-burn
        git clone https://github.com/wilicc/gpu-burn.git ~/gpu-burn
      fi
      cd ~/gpu-burn && make
    '
  fi
fi

# -------------------------- gpud (optional) ------------------------------------
if [[ "$(echo "$INSTALL_GPUD" | tr '[:lower:]' '[:upper:]')" == "Y" ]]; then
  log "Installing gpud"
  if [[ -n "$SUDO" ]]; then
    sudo -u "$TARGET_USER" bash -lc 'curl -fsSL https://pkg.gpud.dev/install.sh | sh'
  else
    sudo -u "$TARGET_USER" bash -lc 'curl -fsSL https://pkg.gpud.dev/install.sh | sh'
  fi
fi

log "Bootstrap complete. A reboot is recommended to ensure nouveau is removed and NVIDIA drivers load cleanly."
