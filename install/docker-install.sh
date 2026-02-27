#!/usr/bin/env bash
# =============================================================================
# docker-install.sh
# Installs Docker CE + NVIDIA Container Toolkit on Ubuntu
# Handles automatic disk/LVM detection for /var/lib/docker placement
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Colours & helpers
# -----------------------------------------------------------------------------
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"  | tee -a "${LOG_FILE:-/tmp/docker-install.log}"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"  | tee -a "${LOG_FILE:-/tmp/docker-install.log}"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "${LOG_FILE:-/tmp/docker-install.log}"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"   | tee -a "${LOG_FILE:-/tmp/docker-install.log}" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}==> $*${RESET}" | tee -a "${LOG_FILE:-/tmp/docker-install.log}"; }

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
NON_INTERACTIVE=false
FORCE_DISK=""    # --disk /dev/sdX  — override disk selection
FORCE_VG=""      # --vg <vgname>   — override VG selection
UNINSTALL=false
WITH_COMPOSE=false

usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS]

Options:
  --non-interactive     No prompts; auto-select largest free disk, then largest
                        free VG, then fall back to root partition with a warning
  --disk /dev/sdX       Force use of a specific disk (non-interactive safe)
  --vg <vgname>         Force use of a specific LVM VG (non-interactive safe)
  --uninstall           Remove Docker, NVIDIA toolkit, Docker Compose, and undo
                        volume mounts created by this script
  --with-compose        Also install Docker Compose v2 (plugin)
  -h, --help            Show this help

Examples:
  sudo $0                                   # interactive install
  sudo $0 --non-interactive                 # fully automated
  sudo $0 --non-interactive --vg ubuntu-vg  # automated, specific VG
  sudo $0 --with-compose                    # install with Compose
  sudo $0 --uninstall                       # clean removal
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE=true ;;
        --disk)         FORCE_DISK="$2"; shift ;;
        --vg)           FORCE_VG="$2";   shift ;;
        --uninstall)    UNINSTALL=true ;;
        --with-compose) WITH_COMPOSE=true ;;
        -h|--help) usage ;;
        *) error "Unknown argument: $1"; usage ;;
    esac
    shift
done

# In non-interactive mode, confirm() always returns true
confirm() {
    local prompt="${1:-Continue?}"
    if [[ "$NON_INTERACTIVE" == true ]]; then
        info "(non-interactive) Auto-confirming: ${prompt}"
        return 0
    fi
    read -rp "$(echo -e "${YELLOW}${prompt} [y/N] ${RESET}")" answer
    [[ "${answer,,}" == "y" ]]
}

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
DOCKER_MOUNT="/var/lib/docker"
LVM_USE_PCT=80          # % of free VG space to allocate
MIN_ROOT_FREE_GB=10     # warn if root will drop below this after install
MIN_DOCKER_VOL_GB=50    # warn if docker volume is smaller than this
LOG_FILE="/var/log/docker-install.log"
DAEMON_JSON="/etc/docker/daemon.json"
COMPOSE_VERSION="v2.27.1"   # Docker Compose plugin version to install

# -----------------------------------------------------------------------------
# ERR trap — log failure line and hint before exit
# -----------------------------------------------------------------------------
trap 'error "Script failed at line ${LINENO} — check ${LOG_FILE} for details"' ERR

# -----------------------------------------------------------------------------
# 1. PREFLIGHT CHECKS
# -----------------------------------------------------------------------------
header "Preflight checks"

# Must run as root first (before log init, since log dir needs root)
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${RESET} This script must be run as root (sudo $0)" >&2
    exit 1
fi

# Initialise log file
mkdir -p "$(dirname "$LOG_FILE")"
echo "===== docker-install.sh started at $(date) =====" >> "$LOG_FILE"
[[ "$NON_INTERACTIVE" == true ]] && info "Running in non-interactive mode"
success "Running as root"

# -----------------------------------------------------------------------------
# UNINSTALL MODE
# -----------------------------------------------------------------------------
if [[ "$UNINSTALL" == true ]]; then
    header "Uninstall mode"
    warn "This will remove Docker CE, NVIDIA Container Toolkit, Docker Compose,"
    warn "and any volume mounts created by this script under ${DOCKER_MOUNT}."
    warn "Container images, volumes, and data under ${DOCKER_MOUNT} will be DESTROYED."
    confirm "Proceed with full uninstall?" || { info "Aborted."; exit 0; }

    # Stop and disable services
    for svc in docker containerd; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            info "Stopping ${svc}..."
            systemctl stop "$svc" || true
            systemctl disable "$svc" || true
        fi
    done

    # Remove packages
    info "Removing Docker packages..."
    apt-get purge -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin 2>/dev/null || true

    info "Removing NVIDIA Container Toolkit..."
    apt-get purge -y nvidia-container-toolkit nvidia-container-runtime \
        nvidia-docker2 2>/dev/null || true

    apt-get autoremove -y 2>/dev/null || true

    # Remove APT repos and keys
    rm -f /etc/apt/sources.list.d/docker.list \
          /etc/apt/sources.list.d/nvidia-container-toolkit.list \
          /etc/apt/keyrings/docker.gpg \
          /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    apt-get update -qq

    # Remove daemon config
    rm -f "${DAEMON_JSON}"

    # Remove Docker Compose binary if manually installed
    rm -f /usr/local/lib/docker/cli-plugins/docker-compose

    # Unmount and clean up Docker volume if it's a separate mount
    if mountpoint -q "${DOCKER_MOUNT}" 2>/dev/null; then
        warn "Unmounting ${DOCKER_MOUNT}..."
        umount "${DOCKER_MOUNT}" || true
        # Remove fstab entry for this mount point
        sed -i "\|${DOCKER_MOUNT}|d" /etc/fstab
        info "Removed fstab entry for ${DOCKER_MOUNT}"
        warn "The underlying disk/LV was NOT wiped — remove manually if needed"
    fi

    # Remove leftover Docker directories
    rm -rf /var/lib/docker /var/lib/containerd /etc/docker
    rm -f /etc/modprobe.d/blacklist-nouveau.conf

    # Remove docker group membership note (group itself left as harmless)
    success "Uninstall complete — a reboot is recommended"
    exit 0
fi

# Ubuntu only
if ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
    warn "This script targets Ubuntu. Detected OS:"
    grep PRETTY_NAME /etc/os-release || true
    confirm "Continue anyway?" || exit 1
fi

UBUNTU_CODENAME=$(lsb_release -cs 2>/dev/null || echo "unknown")
success "OS: Ubuntu ${UBUNTU_CODENAME}"

# Check for required tools
for cmd in curl gpg lsblk df awk sed; do
    if ! command -v "$cmd" &>/dev/null; then
        error "Required tool not found: $cmd"
        exit 1
    fi
done
success "Required tools present"

# Check if Docker is already installed
if command -v docker &>/dev/null; then
    warn "Docker is already installed: $(docker --version)"
    confirm "Re-run installation anyway?" || exit 0
fi

# -----------------------------------------------------------------------------
# 2. DISK SPACE DETECTION
# -----------------------------------------------------------------------------
header "Disk & volume detection"

# Helper: free space in GB on a given mount point
free_gb_on_mount() {
    df -BG "$1" 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4); print $4}' || echo 0
}

# Helper: convert GiB string (e.g. "45.00 GiB") to integer GB
lvm_gib_to_int() {
    echo "$1" | awk '{printf "%d", $1}'
}

# ---- Check if /var/lib/docker is already on its own mount ----
if mountpoint -q "$DOCKER_MOUNT" 2>/dev/null; then
    success "${DOCKER_MOUNT} is already a separate mount point — skipping disk setup"
    SKIP_DISK_SETUP=true
else
    SKIP_DISK_SETUP=false
fi

# ---- Detect free (unpartitioned/unused) disks ----
FREE_DISKS=()
if [[ "$SKIP_DISK_SETUP" == false ]]; then
    info "Scanning for free disks (no partitions, not mounted)..."
    while IFS= read -r disk; do
        # Skip if it has children (partitions / LVM PVs already set up)
        children=$(lsblk -no NAME "/dev/${disk}" 2>/dev/null | tail -n +2 | wc -l)
        if [[ "$children" -eq 0 ]]; then
            size=$(lsblk -bdno SIZE "/dev/${disk}" 2>/dev/null || echo 0)
            size_gb=$(( size / 1024 / 1024 / 1024 ))
            FREE_DISKS+=("/dev/${disk}:${size_gb}GB")
            info "  Found free disk: /dev/${disk} (${size_gb} GB)"
        fi
    done < <(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}')
fi

# ---- Detect free LVM VG space ----
FREE_VGS=()
if [[ "$SKIP_DISK_SETUP" == false ]] && command -v vgdisplay &>/dev/null; then
    info "Scanning LVM volume groups for free space..."
    while IFS= read -r vg_name; do
        free_str=$(vgdisplay "$vg_name" 2>/dev/null \
            | awk '/Free  PE/ {print $5, $6}')
        free_gb=$(lvm_gib_to_int "$free_str")
        if [[ "$free_gb" -gt 0 ]]; then
            FREE_VGS+=("${vg_name}:${free_gb}GB")
            info "  VG '${vg_name}' has ~${free_gb} GB free"
        fi
    done < <(vgs --noheadings -o vg_name 2>/dev/null | awk '{print $1}')
fi

# -----------------------------------------------------------------------------
# 3. VOLUME SETUP DECISION TREE
# -----------------------------------------------------------------------------
header "Volume setup"

SETUP_METHOD="none"   # disk | lvm | root

if [[ "$SKIP_DISK_SETUP" == true ]]; then
    SETUP_METHOD="skip"

elif [[ ${#FREE_DISKS[@]} -gt 0 ]]; then
    # --- Scenario A/C: one or more free disks ---
    if [[ "$NON_INTERACTIVE" == true ]] || [[ -n "$FORCE_DISK" ]]; then
        if [[ -n "$FORCE_DISK" ]]; then
            SELECTED_DISK="$FORCE_DISK"
            info "(non-interactive) Using forced disk: ${SELECTED_DISK}"
        else
            # Auto-pick largest disk
            SELECTED_DISK=""
            LARGEST=0
            for entry in "${FREE_DISKS[@]}"; do
                dev="${entry%%:*}"; sz="${entry##*:}"; sz_num="${sz//GB/}"
                if (( sz_num > LARGEST )); then LARGEST=$sz_num; SELECTED_DISK="$dev"; fi
            done
            info "(non-interactive) Auto-selected largest free disk: ${SELECTED_DISK} (${LARGEST} GB)"
        fi
        SETUP_METHOD="disk"
    else
        echo
        echo -e "${BOLD}Free disks available:${RESET}"
    idx=1
    declare -A DISK_MAP
    for entry in "${FREE_DISKS[@]}"; do
        dev="${entry%%:*}"; sz="${entry##*:}"
        echo "  $idx) $dev  ($sz)"
        DISK_MAP[$idx]="$dev"
        (( idx++ ))
    done
    echo "  $idx) Skip — use LVM or root instead"

    while true; do
        read -rp "$(echo -e "${YELLOW}Select disk to use for ${DOCKER_MOUNT} [1-${idx}]: ${RESET}")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= idx )); then
            break
        fi
        warn "Invalid choice, please enter a number between 1 and ${idx}"
    done

    if (( choice == idx )); then
        info "Skipping free disk — falling through to LVM check"
    else
        SELECTED_DISK="${DISK_MAP[$choice]}"
        SETUP_METHOD="disk"
        info "Selected disk: ${SELECTED_DISK}"
    fi
    fi  # end interactive/non-interactive
fi

if [[ "$SETUP_METHOD" == "none" ]] && [[ ${#FREE_VGS[@]} -gt 0 ]]; then
    # --- Scenario B: free LVM space ---
    if [[ "$NON_INTERACTIVE" == true ]] || [[ -n "$FORCE_VG" ]]; then
        if [[ -n "$FORCE_VG" ]]; then
            SELECTED_VG="$FORCE_VG"
            info "(non-interactive) Using forced VG: ${SELECTED_VG}"
        else
            # Auto-pick VG with most free space
            SELECTED_VG=""
            LARGEST=0
            for entry in "${FREE_VGS[@]}"; do
                vg="${entry%%:*}"; sz="${entry##*:}"; sz_num="${sz//GB/}"
                if (( sz_num > LARGEST )); then LARGEST=$sz_num; SELECTED_VG="$vg"; fi
            done
            info "(non-interactive) Auto-selected VG with most free space: ${SELECTED_VG} (${LARGEST} GB)"
        fi
        SETUP_METHOD="lvm"
    else
        echo
        echo -e "${BOLD}LVM volume groups with free space:${RESET}"
        idx=1
        declare -A VG_MAP
        for entry in "${FREE_VGS[@]}"; do
            vg="${entry%%:*}"; sz="${entry##*:}"
            alloc_gb=$(( $(echo "$sz" | tr -d 'GB') * LVM_USE_PCT / 100 ))
            echo "  $idx) VG: $vg  (free: $sz → will allocate ~${alloc_gb} GB at ${LVM_USE_PCT}%)"
            VG_MAP[$idx]="$vg"
            (( idx++ ))
        done
        echo "  $idx) Skip — install on root partition"

        while true; do
            read -rp "$(echo -e "${YELLOW}Select VG to create Docker LV [1-${idx}]: ${RESET}")" choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= idx )); then
                break
            fi
            warn "Invalid choice, please enter a number between 1 and ${idx}"
        done

        if (( choice == idx )); then
            info "Skipping LVM — Docker will install on root partition"
        else
            SELECTED_VG="${VG_MAP[$choice]}"
        SETUP_METHOD="lvm"
        info "Selected VG: ${SELECTED_VG}"
    fi
    fi  # end interactive/non-interactive
fi

# --- Scenario D: nothing available, install on root with warning ---
if [[ "$SETUP_METHOD" == "none" ]]; then
    echo
    warn "No free disks or LVM space detected. Docker will be installed on the root partition."
    echo
    df -h /
    echo
    root_free=$(free_gb_on_mount /)
    if (( root_free < MIN_ROOT_FREE_GB )); then
        warn "Root partition has only ${root_free} GB free — this may be insufficient."
    fi
    warn "This is NOT recommended for GPU/ML workloads with large images."
    confirm "Continue installing Docker on root partition?" || { info "Aborted."; exit 0; }
    SETUP_METHOD="root"
fi

# -----------------------------------------------------------------------------
# 4. EXECUTE VOLUME SETUP
# -----------------------------------------------------------------------------

if [[ "$SETUP_METHOD" == "disk" ]]; then
    header "Setting up dedicated disk: ${SELECTED_DISK}"

    # Safety check — confirm disk is truly empty
    existing=$(lsblk -no NAME "${SELECTED_DISK}" | tail -n +2 | wc -l)
    if [[ "$existing" -gt 0 ]]; then
        warn "${SELECTED_DISK} appears to have partitions/children:"
        lsblk "${SELECTED_DISK}"
        confirm "Wipe and reformat ${SELECTED_DISK}? ALL DATA WILL BE LOST." || exit 1
    fi

    info "Formatting ${SELECTED_DISK} as ext4..."
    mkfs.ext4 -L docker_data -F "${SELECTED_DISK}"

    UUID=$(blkid -s UUID -o value "${SELECTED_DISK}")
    info "UUID: ${UUID}"

    mkdir -p "${DOCKER_MOUNT}"
    # Guard against duplicate fstab entries on re-runs
    if ! grep -q "UUID=${UUID}" /etc/fstab; then
        echo "UUID=${UUID}  ${DOCKER_MOUNT}  ext4  defaults,nofail  0  2" >> /etc/fstab
    else
        info "fstab entry for UUID=${UUID} already present — skipping"
    fi
    mount -a
    success "Mounted ${SELECTED_DISK} → ${DOCKER_MOUNT}"

elif [[ "$SETUP_METHOD" == "lvm" ]]; then
    header "Creating LVM logical volume in VG: ${SELECTED_VG}"

    LV_NAME="docker_data"
    LV_PATH="/dev/${SELECTED_VG}/${LV_NAME}"

    # Check LV doesn't already exist
    if lvdisplay "${LV_PATH}" &>/dev/null; then
        warn "LV ${LV_PATH} already exists."
        confirm "Use existing LV (will format it)?" || exit 1
    else
        info "Creating LV using ${LVM_USE_PCT}% of free space in ${SELECTED_VG}..."
        lvcreate -l "${LVM_USE_PCT}%FREE" -n "${LV_NAME}" "${SELECTED_VG}"
    fi

    info "Formatting ${LV_PATH} as ext4..."
    mkfs.ext4 -L docker_data "${LV_PATH}"

    UUID=$(blkid -s UUID -o value "${LV_PATH}")
    info "UUID: ${UUID}"

    mkdir -p "${DOCKER_MOUNT}"
    # Guard against duplicate fstab entries on re-runs
    if ! grep -q "UUID=${UUID}" /etc/fstab; then
        echo "UUID=${UUID}  ${DOCKER_MOUNT}  ext4  defaults,nofail  0  2" >> /etc/fstab
    else
        info "fstab entry for UUID=${UUID} already present — skipping"
    fi
    mount -a
    success "Mounted ${LV_PATH} → ${DOCKER_MOUNT}"

elif [[ "$SETUP_METHOD" == "skip" ]]; then
    success "${DOCKER_MOUNT} already mounted — no disk setup needed"

else
    info "Installing Docker on root partition (no separate volume)"
fi

# Post-mount size check
if mountpoint -q "${DOCKER_MOUNT}" 2>/dev/null; then
    vol_free=$(free_gb_on_mount "${DOCKER_MOUNT}")
    if (( vol_free < MIN_DOCKER_VOL_GB )); then
        warn "Docker volume only has ${vol_free} GB free — recommend at least ${MIN_DOCKER_VOL_GB} GB for GPU workloads"
    else
        success "Docker volume: ${vol_free} GB available"
    fi
fi

# -----------------------------------------------------------------------------
# 5. INSTALL DOCKER CE
# -----------------------------------------------------------------------------
header "Installing Docker CE"

info "Adding Docker APT repository..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -qq
info "Installing docker-ce, docker-ce-cli, containerd.io..."
apt-get install -y docker-ce docker-ce-cli containerd.io

systemctl enable --now docker.service
systemctl enable --now containerd.service

success "Docker installed: $(docker --version)"

# Add the SUDO_USER (or specified user) to the docker group
TARGET_USER="${SUDO_USER:-}"
if [[ -n "$TARGET_USER" ]]; then
    usermod -aG docker "$TARGET_USER"
    success "Added '${TARGET_USER}' to docker group (re-login required)"
else
    warn "Could not determine non-root user — add yourself to the docker group manually: sudo usermod -aG docker \$USER"
fi

# -----------------------------------------------------------------------------
# 5a. CONFIGURE DOCKER DAEMON
# -----------------------------------------------------------------------------
header "Configuring Docker daemon"

# Determine storage driver — overlay2 is standard, but check for btrfs/zfs
STORAGE_DRIVER="overlay2"
if [[ -d "${DOCKER_MOUNT}" ]]; then
    fs_type=$(df -T "${DOCKER_MOUNT}" | awk 'NR==2{print $2}')
    case "$fs_type" in
        btrfs) STORAGE_DRIVER="btrfs" ;;
        zfs)   STORAGE_DRIVER="zfs" ;;
        *)     STORAGE_DRIVER="overlay2" ;;
    esac
fi
info "Storage driver: ${STORAGE_DRIVER}"

mkdir -p /etc/docker
if [[ -f "${DAEMON_JSON}" ]]; then
    warn "${DAEMON_JSON} already exists — backing up to ${DAEMON_JSON}.bak"
    cp "${DAEMON_JSON}" "${DAEMON_JSON}.bak"
fi

# Build daemon.json via Python to guarantee valid JSON regardless of runtime
python3 - <<PYEOF
import json
cfg = {
    "log-driver": "json-file",
    "log-opts": {"max-size": "100m", "max-file": "3"},
    "storage-driver": "${STORAGE_DRIVER}",
    "data-root": "${DOCKER_MOUNT}"
}
# Only set default-runtime if driver is already present
import subprocess, shutil
if shutil.which("nvidia-smi"):
    try:
        subprocess.check_call(["nvidia-smi"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cfg["default-runtime"] = "nvidia"
    except subprocess.CalledProcessError:
        pass
with open("${DAEMON_JSON}", "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYEOF

success "daemon.json written"

systemctl restart docker
success "Docker daemon configured: log rotation (100m×3), storage=${STORAGE_DRIVER}"

# -----------------------------------------------------------------------------
# 5b. INSTALL DOCKER COMPOSE (optional)
# -----------------------------------------------------------------------------
if [[ "$WITH_COMPOSE" == true ]]; then
    header "Installing Docker Compose ${COMPOSE_VERSION}"

    COMPOSE_DIR="/usr/local/lib/docker/cli-plugins"
    COMPOSE_BIN="${COMPOSE_DIR}/docker-compose"
    COMPOSE_ARCH=$(dpkg --print-architecture)

    # Map dpkg arch to GitHub release arch naming
    case "$COMPOSE_ARCH" in
        amd64)   COMPOSE_ARCH="x86_64" ;;
        arm64)   COMPOSE_ARCH="aarch64" ;;
        armhf)   COMPOSE_ARCH="armv7" ;;
    esac

    COMPOSE_URL="https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${COMPOSE_ARCH}"

    mkdir -p "${COMPOSE_DIR}"
    info "Downloading Docker Compose from ${COMPOSE_URL}..."
    curl -fsSL "${COMPOSE_URL}" -o "${COMPOSE_BIN}"
    chmod +x "${COMPOSE_BIN}"

    # Verify
    if docker compose version &>/dev/null; then
        success "Docker Compose installed: $(docker compose version)"
    else
        warn "Docker Compose binary installed but 'docker compose version' failed — check ${COMPOSE_BIN}"
    fi
fi

# -----------------------------------------------------------------------------
# 6. INSTALL NVIDIA CONTAINER TOOLKIT
# -----------------------------------------------------------------------------
header "Installing NVIDIA Container Toolkit"

# Check NVIDIA driver is present before installing toolkit
NVIDIA_DRIVER_OK=false
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    NVIDIA_DRIVER_OK=true
    success "NVIDIA driver detected: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
else
    warn "NVIDIA driver not detected (nvidia-smi not found or failed)"
    warn "The toolkit will be installed but GPU containers will not work until the driver is installed and the host is rebooted"
    if [[ "$NON_INTERACTIVE" == false ]]; then
        confirm "Continue installing NVIDIA Container Toolkit anyway?" || {
            info "Skipping NVIDIA Container Toolkit installation"
            SKIP_NVIDIA=true
        }
    fi
fi
SKIP_NVIDIA="${SKIP_NVIDIA:-false}"

if [[ "$SKIP_NVIDIA" == false ]]; then
    info "Adding NVIDIA APT repository..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null

    # Fix arch placeholder — detect dynamically, never hardcode amd64
    HOST_ARCH=$(dpkg --print-architecture)
    sed -i "s/\$(ARCH)/${HOST_ARCH}/" /etc/apt/sources.list.d/nvidia-container-toolkit.list

    apt-get update -qq
    apt-get install -y nvidia-container-toolkit

    info "Configuring NVIDIA runtime for Docker..."
    nvidia-ctk runtime configure --runtime=docker

    # Also ensure default-runtime is nvidia in daemon.json now that toolkit is present
    if command -v python3 &>/dev/null && [[ -f "${DAEMON_JSON}" ]]; then
        python3 - <<'PYEOF'
import json, sys
with open('/etc/docker/daemon.json', 'r') as f:
    cfg = json.load(f)
cfg['default-runtime'] = 'nvidia'
with open('/etc/docker/daemon.json', 'w') as f:
    json.dump(cfg, f, indent=2)
PYEOF
        info "Set default-runtime=nvidia in ${DAEMON_JSON}"
    fi

    systemctl restart docker
    success "NVIDIA Container Toolkit installed"
fi

# -----------------------------------------------------------------------------
# 7. BLACKLIST NOUVEAU
# -----------------------------------------------------------------------------
header "Blacklisting Nouveau driver"

BLACKLIST_FILE="/etc/modprobe.d/blacklist-nouveau.conf"
if grep -q "blacklist nouveau" "$BLACKLIST_FILE" 2>/dev/null; then
    info "Nouveau already blacklisted — skipping"
else
    echo "blacklist nouveau" >> "$BLACKLIST_FILE"
    echo "options nouveau modeset=0" >> "$BLACKLIST_FILE"
    update-initramfs -u
    success "Nouveau blacklisted — a reboot is required to take effect"
fi

# -----------------------------------------------------------------------------
# 8. POST-INSTALL VALIDATION
# -----------------------------------------------------------------------------
header "Post-install validation"

info "Running hello-world container..."
if docker run --rm hello-world &>/dev/null; then
    success "docker run hello-world — OK"
else
    warn "hello-world container failed — check Docker daemon logs: journalctl -u docker"
fi

info "Checking NVIDIA CTK..."
if nvidia-ctk --version &>/dev/null; then
    success "nvidia-ctk: $(nvidia-ctk --version 2>&1 | head -1)"
else
    warn "nvidia-ctk not found in PATH — check installation"
fi

if [[ "$WITH_COMPOSE" == true ]]; then
    info "Checking Docker Compose..."
    if docker compose version &>/dev/null; then
        success "docker compose: $(docker compose version)"
    else
        warn "Docker Compose check failed"
    fi
fi

# -----------------------------------------------------------------------------
# 9. SUMMARY
# -----------------------------------------------------------------------------
header "Installation Summary"

echo
echo -e "${BOLD}Docker:${RESET}"
docker version --format '  Client: {{.Client.Version}}  |  Server: {{.Server.Engine.Version}}' 2>/dev/null || true

if [[ "$WITH_COMPOSE" == true ]]; then
    echo -e "${BOLD}Docker Compose:${RESET}"
    docker compose version 2>/dev/null | sed 's/^/  /' || echo "  (not available)"
fi

echo -e "${BOLD}Daemon config (${DAEMON_JSON}):${RESET}"
cat "${DAEMON_JSON}" 2>/dev/null | sed 's/^/  /' || echo "  (not found)"

echo -e "${BOLD}Storage layout:${RESET}"
df -h "${DOCKER_MOUNT}" / | awk 'NR==1{print "  "$0} NR>1{print "  "$0}'

echo -e "${BOLD}Docker group members:${RESET}"
getent group docker | awk -F: '{print "  "$4}'

echo
if [[ -n "$TARGET_USER" ]]; then
    warn "ACTION REQUIRED: Log out and back in as '${TARGET_USER}' to use Docker without sudo"
fi

if ! lsmod | grep -q "^nvidia " 2>/dev/null; then
    warn "ACTION REQUIRED: NVIDIA driver not loaded yet — reboot to activate blacklist + load driver"
fi

echo
success "docker-install.sh complete"
info "Full log saved to: ${LOG_FILE}"
