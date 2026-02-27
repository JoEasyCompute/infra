#!/usr/bin/env bash

# ═══════════════════════════════════════════════════════════════
# base-install.sh — GPU Node Base Installation Script
# Supports: Ubuntu 22.04 / 24.04 (x86_64)
# Installs: NVIDIA drivers, CUDA toolkit, cuDNN, DCGM, gpu-burn
# Version:  1.7 (2026-02-27)
# ═══════════════════════════════════════════════════════════════

# No set -e — explicit error checking on every critical step.
# set -u catches unbound variables. set -o pipefail catches pipe failures.
set -uo pipefail

# ─── Logging ──────────────────────────────────────────────────
LOG_DIR="/var/log/gpu-node-install"
sudo mkdir -p "${LOG_DIR}" && sudo chmod 777 "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2> >(tee -a "${LOG_FILE}" >&2)

echo "════════════════════════════════════════════════════════"
echo " GPU Node Installation Script  (v1.7 — 2026-02-27)"
echo " Log: ${LOG_FILE}"
echo " Started: $(date)"
echo "════════════════════════════════════════════════════════"
echo ""

# ─── Color helpers ────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}    $*"; }
success() { echo -e "${GREEN}[OK]${NC}      $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC}   $*"; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}── $* ──${NC}"; }

# ─── CLI argument parsing ──────────────────────────────────────
DRIVER_VERSION=""
CUDA_VERSION=""
NON_INTERACTIVE=false
UNINSTALL=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --driver  <575|580|590>    NVIDIA driver version (default: interactive)
  --cuda    <12-9|13>        CUDA toolkit version  (default: interactive)
  --yes                      Non-interactive mode, use defaults (580 + 12-9)
  --uninstall                Full clean removal — restores system to post-OS-install state
  -h, --help                 Show this help

Examples:
  $(basename "$0")                           # Interactive install
  $(basename "$0") --driver 580 --cuda 12-9  # Explicit versions
  $(basename "$0") --yes                     # Non-interactive with defaults
  $(basename "$0") --uninstall               # Interactive uninstall
  $(basename "$0") --uninstall --yes         # Non-interactive uninstall
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --driver)    DRIVER_VERSION="$2"; shift 2 ;;
        --cuda)      CUDA_VERSION="$2";   shift 2 ;;
        --yes)       NON_INTERACTIVE=true; shift ;;
        --uninstall) UNINSTALL=true; shift ;;
        -h|--help)   usage ;;
        *) error "Unknown option: $1. Use --help for usage." ;;
    esac
done

# ═══════════════════════════════════════════════════════════════
# STEP 1 — Detect Ubuntu Version
# ═══════════════════════════════════════════════════════════════
detect_ubuntu() {
    section "Detecting OS"
    [[ -f /etc/os-release ]] || error "Cannot detect OS — /etc/os-release not found"
    source /etc/os-release
    [[ "${ID}" == "ubuntu" ]] || error "This script requires Ubuntu. Detected: ${ID}"
    case "${VERSION_ID}" in
        "22.04") UBUNTU_CODENAME="ubuntu2204" ;;
        "24.04") UBUNTU_CODENAME="ubuntu2404" ;;
        *) error "Unsupported Ubuntu version: ${VERSION_ID}. Supported: 22.04, 24.04" ;;
    esac
    UBUNTU_VERSION_ID="${VERSION_ID}"
    success "Detected Ubuntu ${VERSION_ID} → repo: ${UBUNTU_CODENAME}"
}

# ═══════════════════════════════════════════════════════════════
# STEP 2 — Pre-flight Checks
# ═══════════════════════════════════════════════════════════════
preflight_checks() {
    section "Pre-flight Checks"
    local warnings=0

    # Sudo
    if sudo -n true 2>/dev/null; then
        success "Sudo access: OK"
    else
        error "Script requires sudo access."
    fi

    # Architecture
    local arch; arch=$(uname -m)
    [[ "${arch}" == "x86_64" ]] && success "Architecture: ${arch}" \
        || error "Unsupported architecture: ${arch}. Only x86_64 supported."

    # Disk space
    local free_gb
    free_gb=$(df --output=avail -BG /usr | tail -1 | tr -d 'G ')
    if (( free_gb >= 15 )); then
        success "Disk space: ${free_gb}GB free on /usr"
    else
        error "Insufficient disk space: ${free_gb}GB free on /usr — need 15GB+"
    fi

    # Network
    check_host() {
        local host="$1" label="$2" required="$3"
        if ping -c 1 -W 5 "${host}" &>/dev/null; then
            if command -v curl &>/dev/null; then
                if curl -sfL --max-time 10 "https://${host}" -o /dev/null 2>/dev/null; then
                    success "Network: ${label} (HTTPS OK)"
                elif curl -sfLk --max-time 10 "https://${host}" -o /dev/null 2>/dev/null; then
                    warn "Network: ${label} — TLS untrusted (ca-certificates will be updated)"
                else
                    warn "Network: ${label} pingable, HTTPS check failed — continuing"
                fi
            else
                success "Network: ${label} (ping OK)"
            fi
        else
            [[ "${required}" == "hard" ]] \
                && error "Cannot reach ${host} — check network/firewall" \
                || warn "Cannot reach ${host} — some steps may fail"
        fi
    }
    check_host "developer.download.nvidia.com" "NVIDIA repo" "hard"
    check_host "github.com" "GitHub" "soft"

    # Secure Boot
    if command -v mokutil &>/dev/null && mokutil --sb-state 2>/dev/null | grep -q "enabled"; then
        warn "Secure Boot ENABLED — DKMS modules may fail to load. Disable in BIOS."
        if [[ "${NON_INTERACTIVE}" == false ]]; then
            read -rp "  Continue anyway? [y/N]: " sb_confirm
            [[ "${sb_confirm,,}" == "y" ]] || error "Aborted."
        fi
    else
        success "Secure Boot: disabled (OK)"
    fi

    # Existing NVIDIA
    if dpkg -l 2>/dev/null | grep -qP '^ii\s+(nvidia-driver|libnvidia-compute|cuda-)'; then
        warn "Existing NVIDIA/CUDA packages found — may conflict:"
        dpkg -l 2>/dev/null | grep -P '^ii\s+(nvidia|cuda|cudnn)' | awk '{printf "    %s %s\n", $2, $3}' || true
        if [[ "${NON_INTERACTIVE}" == false ]]; then
            read -rp "  Continue anyway? [y/N]: " purge_confirm
            [[ "${purge_confirm,,}" == "y" ]] || error "Aborted."
        fi
    else
        success "No conflicting NVIDIA/CUDA packages"
    fi

    # Kernel headers — check AND warn clearly since we install them in base packages
    local kver; kver=$(uname -r)
    if apt-cache show "linux-headers-${kver}" &>/dev/null; then
        success "Kernel headers: available for ${kver}"
    else
        warn "linux-headers-${kver} not in apt cache — will attempt install anyway"
        (( warnings++ )) || true
    fi

    (( warnings > 0 )) && warn "${warnings} warning(s) above" || success "All pre-flight checks passed"
}

# ═══════════════════════════════════════════════════════════════
# STEP 3 — Version Selection
# ═══════════════════════════════════════════════════════════════
select_driver_version() {
    if [[ -n "${DRIVER_VERSION}" ]]; then
        case "${DRIVER_VERSION}" in
            575|580|590) success "Driver version (--driver arg): ${DRIVER_VERSION}" ; return ;;
            *) error "Invalid --driver: ${DRIVER_VERSION}. Valid: 575, 580, 590" ;;
        esac
    fi
    if [[ "${NON_INTERACTIVE}" == true ]]; then
        DRIVER_VERSION="580"; success "Driver version (default): ${DRIVER_VERSION}"; return
    fi
    echo ""
    echo -e "${BOLD}Select NVIDIA Driver Version:${NC}"
    echo "  1) 575  — stable, widely tested"
    echo "  2) 580  — recommended [default]"
    echo "  3) 590  — latest/beta"
    echo ""
    read -rp "Enter choice [1-3, default=2]: " driver_choice
    case "${driver_choice}" in
        1) DRIVER_VERSION="575" ;;
        3) DRIVER_VERSION="590" ;;
        *) DRIVER_VERSION="580" ;;
    esac
    success "Driver version: ${DRIVER_VERSION}"
}

select_cuda_version() {
    if [[ -n "${CUDA_VERSION}" ]]; then
        case "${CUDA_VERSION}" in
            "12-9") CUDA_TOOLKIT_VERSION="12-9"; CUDA_MAJOR="12" ;;
            "13")   CUDA_TOOLKIT_VERSION="13";   CUDA_MAJOR="13" ;;
            *) error "Invalid --cuda: ${CUDA_VERSION}. Valid: 12-9, 13" ;;
        esac
        success "CUDA version (--cuda arg): ${CUDA_TOOLKIT_VERSION}"; return
    fi
    if [[ "${NON_INTERACTIVE}" == true ]]; then
        CUDA_TOOLKIT_VERSION="12-9"; CUDA_MAJOR="12"
        success "CUDA version (default): ${CUDA_TOOLKIT_VERSION}"; return
    fi
    echo ""
    echo -e "${BOLD}Select CUDA Toolkit Version:${NC}"
    echo "  1) 12-9  — stable [default]"
    echo "  2) 13    — latest"
    echo ""
    read -rp "Enter choice [1-2, default=1]: " cuda_choice
    case "${cuda_choice}" in
        2) CUDA_TOOLKIT_VERSION="13"; CUDA_MAJOR="13" ;;
        *) CUDA_TOOLKIT_VERSION="12-9"; CUDA_MAJOR="12" ;;
    esac
    success "CUDA version: ${CUDA_TOOLKIT_VERSION}"
}

validate_combination() {
    if [[ "${CUDA_MAJOR}" == "13" && "${DRIVER_VERSION}" == "575" ]]; then
        warn "Driver 575 + CUDA 13 may have compatibility issues. Recommended: 580 or 590."
        if [[ "${NON_INTERACTIVE}" == false ]]; then
            read -rp "  Continue anyway? [y/N]: " yn
            [[ "${yn,,}" == "y" ]] || error "Aborted."
        fi
    fi
    success "Combination: Driver ${DRIVER_VERSION} + CUDA ${CUDA_TOOLKIT_VERSION}"
}

# ═══════════════════════════════════════════════════════════════
# STEP 4 — Confirm
# ═══════════════════════════════════════════════════════════════
confirm_install() {
    echo ""
    echo -e "${BOLD}════════════════════════════════════════${NC}"
    echo -e "  Ubuntu:        ${UBUNTU_VERSION_ID} (${UBUNTU_CODENAME})"
    echo -e "  NVIDIA Driver: ${DRIVER_VERSION}-open (DKMS)"
    echo -e "  CUDA Toolkit:  ${CUDA_TOOLKIT_VERSION}"
    echo -e "  cuDNN:         cudnn9-cuda-${CUDA_MAJOR}"
    echo -e "  Log file:      ${LOG_FILE}"
    echo -e "${BOLD}════════════════════════════════════════${NC}"
    echo ""
    if [[ "${NON_INTERACTIVE}" == false ]]; then
        read -rp "Proceed with installation? [Y/n]: " proceed
        [[ "${proceed,,}" == "n" ]] && error "Aborted by user."
        info "Starting installation..."
    else
        info "Non-interactive mode — starting installation..."
    fi
}

# ═══════════════════════════════════════════════════════════════
# STEP 5 — Base packages
# ═══════════════════════════════════════════════════════════════
install_base_packages() {
    section "Base System Packages"

    info "Bootstrapping prerequisites..."
    sudo apt-get update -q \
        || error "apt-get update failed"
    sudo apt-get install -y \
        software-properties-common apt-transport-https ca-certificates curl gnupg \
        || error "Bootstrap package install failed"

    info "Adding graphics-drivers PPA..."
    sudo add-apt-repository -y ppa:graphics-drivers/ppa \
        || error "Failed to add graphics-drivers PPA"
    sudo apt-get update -q \
        || error "apt-get update after PPA failed"

    # Install kernel headers explicitly — required for DKMS to build nvidia module.
    # Without this, DKMS silently fails and nvidia.ko is never built.
    local kver; kver=$(uname -r)
    info "Installing kernel headers for: ${kver}"
    sudo apt-get install -y \
        "linux-headers-${kver}" \
        linux-headers-generic \
        || warn "Kernel headers install had warnings — DKMS build may fail"

    info "Installing base packages..."
    sudo apt-get install -y \
        git cmake build-essential dkms alsa-utils \
        gcc-11 g++-11 gcc-12 g++-12 lsb-release \
        ipmitool jq pciutils iproute2 util-linux dmidecode lshw \
        coreutils chrony nvme-cli bpytop mokutil \
        python3 python3-pip python3-venv \
        || error "Base package install failed"

    sudo systemctl enable --now chrony \
        || warn "Failed to enable chrony"
    success "Base packages installed"
}

# ═══════════════════════════════════════════════════════════════
# STEP 6 — GCC alternatives
# ═══════════════════════════════════════════════════════════════
configure_gcc_alternatives() {
    section "GCC Alternatives"
    sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 11
    sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-11 11
    sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 12
    sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-12 12
    success "GCC alternatives configured (active: gcc-12)"
}

# ═══════════════════════════════════════════════════════════════
# STEP 7 — CUDA keyring
# ═══════════════════════════════════════════════════════════════
install_cuda_keyring() {
    section "CUDA Repository Keyring"
    local keyring_gpg="/usr/share/keyrings/cuda-archive-keyring.gpg"
    local deb="cuda-keyring_1.1-1_all.deb"
    local url="https://developer.download.nvidia.com/compute/cuda/repos/${UBUNTU_CODENAME}/x86_64/${deb}"

    if [[ -f "${keyring_gpg}" ]]; then
        info "CUDA keyring already present — skipping"
    else
        info "Downloading: ${url}"
        wget -q --show-progress -O "/tmp/${deb}" "${url}" \
            || error "Failed to download CUDA keyring from ${url}"
        sudo dpkg -i "/tmp/${deb}" \
            || error "Failed to install CUDA keyring"
        rm "/tmp/${deb}"
        success "CUDA keyring installed"
    fi

    sudo apt-get update -q || error "apt-get update after CUDA keyring failed"
    sudo apt-get upgrade -y || warn "apt-get upgrade had warnings (non-fatal)"
}

# ═══════════════════════════════════════════════════════════════
# STEP 8 — NVIDIA stack
# ═══════════════════════════════════════════════════════════════
install_nvidia_stack() {
    section "NVIDIA Driver + CUDA Stack"
    info "Installing driver=${DRIVER_VERSION}, cuda=${CUDA_TOOLKIT_VERSION}, cudnn=cudnn9-cuda-${CUDA_MAJOR}"
    sudo apt-get install -V -y \
        "cuda-toolkit-${CUDA_TOOLKIT_VERSION}" \
        "libnvidia-compute-${DRIVER_VERSION}" \
        "nvidia-dkms-${DRIVER_VERSION}-open" \
        "nvidia-utils-${DRIVER_VERSION}" \
        "cudnn9-cuda-${CUDA_MAJOR}" \
        nvtop \
        || error "NVIDIA stack install failed — check apt output above"
    success "NVIDIA stack installed"
}

# ═══════════════════════════════════════════════════════════════
# STEP 9 — CUDA PATH
# ═══════════════════════════════════════════════════════════════
configure_cuda_path() {
    section "CUDA PATH Configuration"

    # Set for current session immediately so nvcc works in validate_install
    export PATH="/usr/local/cuda/bin:${PATH}"
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"

    # Persist across all future logins via /etc/profile.d/
    sudo tee /etc/profile.d/cuda.sh > /dev/null << 'EOF'
# CUDA toolkit PATH — added by base-install.sh
export PATH="/usr/local/cuda/bin:${PATH}"
export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
EOF
    sudo chmod 644 /etc/profile.d/cuda.sh
    success "CUDA PATH configured — /usr/local/cuda/bin added for all users"
}

# ═══════════════════════════════════════════════════════════════
# STEP 10 — DCGM
# ═══════════════════════════════════════════════════════════════
install_dcgm() {
    section "DCGM (Datacenter GPU Manager)"
    if command -v nvidia-smi &>/dev/null; then
        local live_cuda_major
        live_cuda_major=$(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version: \K[0-9]+' || echo "${CUDA_MAJOR}")
        info "Installing datacenter-gpu-manager-4-cuda${live_cuda_major}..."
        sudo apt-get install -y "datacenter-gpu-manager-4-cuda${live_cuda_major}" \
            || error "DCGM install failed"
        sudo systemctl enable --now nvidia-dcgm
        success "DCGM installed and enabled"
    else
        warn "nvidia-smi not available — DCGM deferred (reboot first, then re-run)"
    fi
}

# ═══════════════════════════════════════════════════════════════
# STEP 11 — Repos & gpu-burn
# ═══════════════════════════════════════════════════════════════
setup_repos() {
    section "Repos & gpu-burn"
    local infra_dir="${HOME}/infra"
    local gpuburn_dir="${HOME}/gpu-burn"

    if [[ -d "${infra_dir}" ]]; then
        info "infra repo exists — pulling latest"
        git -C "${infra_dir}" pull --ff-only || warn "git pull infra failed (local changes?)"
    else
        git clone https://github.com/joeasycompute/infra.git "${infra_dir}" \
            || error "Failed to clone infra repo"
        success "Cloned infra → ${infra_dir}"
    fi

    if [[ -d "${gpuburn_dir}" ]]; then
        info "gpu-burn repo exists — pulling latest"
        git -C "${gpuburn_dir}" pull --ff-only || warn "git pull gpu-burn failed"
    else
        git clone https://github.com/wilicc/gpu-burn.git "${gpuburn_dir}" \
            || error "Failed to clone gpu-burn repo"
        success "Cloned gpu-burn → ${gpuburn_dir}"
    fi

    if command -v nvcc &>/dev/null; then
        info "Building gpu-burn..."
        (cd "${gpuburn_dir}" && make) || warn "gpu-burn build failed"
        success "gpu-burn built: ${gpuburn_dir}/gpu_burn"
    else
        warn "nvcc not in PATH — gpu-burn build deferred (reboot first, then re-run)"
    fi
}

# ═══════════════════════════════════════════════════════════════
# STEP 12 — Validation
# ═══════════════════════════════════════════════════════════════
validate_install() {
    section "Post-install Validation"
    local warnings=0

    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        local gpu_name gpu_count
        gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
        gpu_count=$(nvidia-smi --query-gpu=count --format=csv,noheader | head -1)
        success "nvidia-smi: ${gpu_count}x ${gpu_name}"
    else
        warn "nvidia-smi not operational (reboot required)"; (( warnings++ )) || true
    fi

    if command -v nvcc &>/dev/null; then
        success "nvcc: $(nvcc --version | grep -oP 'release \K[0-9.]+')"
    else
        warn "nvcc not in PATH (reboot or re-source /etc/profile.d/cuda.sh)"; (( warnings++ )) || true
    fi

    systemctl is-active --quiet nvidia-dcgm 2>/dev/null \
        && success "nvidia-dcgm: running" \
        || { warn "nvidia-dcgm: not running (expected before reboot)"; (( warnings++ )) || true; }

    systemctl is-active --quiet chrony \
        && success "chrony: running" \
        || { warn "chrony not running"; (( warnings++ )) || true; }

    [[ -f "${HOME}/gpu-burn/gpu_burn" ]] \
        && success "gpu-burn: ready" \
        || { warn "gpu-burn: not built (reboot first, then re-run)"; (( warnings++ )) || true; }

    [[ -d "${HOME}/infra" ]] \
        && success "infra repo: present" \
        || { warn "infra repo: missing"; (( warnings++ )) || true; }

    echo ""
    (( warnings > 0 )) \
        && warn "${warnings} item(s) pending — most resolve after reboot" \
        || success "All checks passed — node is ready"
}

# ═══════════════════════════════════════════════════════════════
# STEP 13 — Reboot prompt (install)
# ═══════════════════════════════════════════════════════════════
offer_reboot() {
    echo ""
    echo -e "${BOLD}════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD} Installation complete!${NC}"
    echo -e "  Driver: ${DRIVER_VERSION}-open  |  CUDA: ${CUDA_TOOLKIT_VERSION}  |  Ubuntu: ${UBUNTU_VERSION_ID}"
    echo -e "  Full log: ${LOG_FILE}"
    echo -e "${BOLD}════════════════════════════════════════${NC}"
    echo ""

    if ! (command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null); then
        if [[ "${NON_INTERACTIVE}" == true ]]; then
            info "Non-interactive — reboot manually to activate NVIDIA kernel modules."
        else
            read -rp "Reboot now to load NVIDIA kernel modules? [Y/n]: " do_reboot
            if [[ "${do_reboot,,}" != "n" ]]; then
                info "Rebooting in 5 seconds... (Ctrl+C to cancel)"
                sleep 5
                sudo reboot
            else
                warn "Remember to reboot before running GPU workloads"
            fi
        fi
    else
        success "NVIDIA driver already active — no reboot needed"
    fi
}

# ═══════════════════════════════════════════════════════════════
# UNINSTALL — Full clean removal, restores post-OS-install state
# ═══════════════════════════════════════════════════════════════
uninstall_node() {
    section "Uninstall — Full GPU Stack Removal"

    echo ""
    echo -e "${BOLD}The following will be removed to restore a clean OS state:${NC}"
    echo "  • NVIDIA drivers, CUDA toolkit, cuDNN, DCGM, nvtop"
    echo "  • DKMS kernel module entries and built .ko files"
    echo "  • /etc/modprobe.d/ NVIDIA blacklist and option files"
    echo "  • initramfs rebuilt to remove NVIDIA/nouveau blacklist"
    echo "  • CUDA apt keyring, repo sources"
    echo "  • graphics-drivers PPA"
    echo "  • /etc/profile.d/cuda.sh PATH entry"
    echo "  • /etc/ld.so.conf.d/ CUDA library path entries"
    echo "  • GCC update-alternatives entries"
    echo "  • gpu-burn and infra repos (optional)"
    echo "  • Orphaned apt dependencies"
    echo ""

    if [[ "${NON_INTERACTIVE}" == false ]]; then
        read -rp "Proceed with full uninstall? [y/N]: " confirm_uninstall
        [[ "${confirm_uninstall,,}" == "y" ]] || error "Uninstall aborted by user."
    else
        info "Non-interactive mode — proceeding with uninstall"
    fi

    # ── 1. Stop and disable services ─────────────────────────
    section "Stopping Services"
    for svc in nvidia-dcgm nvidia-persistenced; do
        if systemctl list-units --full -all 2>/dev/null | grep -q "${svc}"; then
            info "Stopping ${svc}..."
            sudo systemctl disable --now "${svc}" 2>/dev/null || true
            success "Stopped and disabled: ${svc}"
        else
            info "Service not found: ${svc} — skipping"
        fi
    done

    # ── 2. Purge NVIDIA / CUDA / cuDNN / DCGM packages ───────
    section "Removing NVIDIA/CUDA Packages"
    info "Collecting installed NVIDIA/CUDA packages..."

    local pkgs_to_remove
    pkgs_to_remove=$(dpkg -l 2>/dev/null \
        | grep -P '^ii\s+(nvidia|cuda|cudnn|datacenter-gpu-manager|libnvidia|libcuda|libcudnn|nvtop)' \
        | awk '{print $2}' | tr '\n' ' ')

    if [[ -n "${pkgs_to_remove}" ]]; then
        echo "  Packages to remove:"
        echo "${pkgs_to_remove}" | tr ' ' '\n' | sed 's/^/    /' | grep -v '^$'
        echo ""
        # shellcheck disable=SC2086
        sudo apt-get purge -y ${pkgs_to_remove} \
            || warn "Some packages failed to purge — continuing"
        success "NVIDIA/CUDA packages purged"
    else
        info "No NVIDIA/CUDA packages found — already clean"
    fi

    # ── 3. DKMS explicit cleanup ──────────────────────────────
    section "Cleaning DKMS Entries"
    # Purging packages doesn't always clean DKMS — do it explicitly
    if command -v dkms &>/dev/null; then
        local dkms_entries
        dkms_entries=$(dkms status 2>/dev/null | grep -i nvidia | awk -F'[,: ]+' '{print $1"/"$2}' || true)
        if [[ -n "${dkms_entries}" ]]; then
            while IFS= read -r entry; do
                [[ -z "${entry}" ]] && continue
                info "Removing DKMS entry: ${entry}"
                sudo dkms remove "${entry}" --all 2>/dev/null || true
            done <<< "${dkms_entries}"
            success "DKMS nvidia entries removed"
        else
            info "No DKMS nvidia entries found — already clean"
        fi
    else
        info "dkms not installed — skipping"
    fi

    # ── 4. Remove built kernel module files ───────────────────
    section "Removing Kernel Module Files"
    local ko_count
    ko_count=$(sudo find /lib/modules -name "nvidia*.ko*" 2>/dev/null | wc -l)
    if (( ko_count > 0 )); then
        info "Found ${ko_count} nvidia .ko file(s) — removing..."
        sudo find /lib/modules -name "nvidia*.ko*" -delete 2>/dev/null || true
        sudo depmod -a
        success "Kernel module files removed and module map rebuilt"
    else
        info "No nvidia .ko files found — already clean"
    fi

    # ── 5. Clean /etc/modprobe.d/ ─────────────────────────────
    section "Cleaning modprobe.d Configuration"
    local modprobe_files
    modprobe_files=$(sudo find /etc/modprobe.d/ -name "nvidia*.conf" \
        -o -name "blacklist-nouveau.conf" 2>/dev/null | tr '\n' ' ')
    if [[ -n "${modprobe_files}" ]]; then
        echo "  Removing:"
        echo "${modprobe_files}" | tr ' ' '\n' | sed 's/^/    /' | grep -v '^$'
        # shellcheck disable=SC2086
        sudo rm -f ${modprobe_files}
        success "modprobe.d NVIDIA/nouveau configs removed"
    else
        info "No NVIDIA modprobe.d files found — already clean"
    fi

    # ── 6. Rebuild initramfs ───────────────────────────────────
    # Critical: without this, nouveau blacklist persists in initrd
    # and the open-source driver won't load on next boot.
    section "Rebuilding initramfs"
    info "Rebuilding initramfs to remove NVIDIA/nouveau blacklist..."
    sudo update-initramfs -u -k all \
        && success "initramfs rebuilt successfully" \
        || warn "initramfs rebuild had warnings — reboot and check dmesg"

    # ── 7. Re-enable Nouveau ──────────────────────────────────
    section "Re-enabling Nouveau Driver"
    # Ensure nouveau is not blocked in any remaining conf
    if grep -r "blacklist nouveau" /etc/modprobe.d/ 2>/dev/null; then
        warn "nouveau blacklist still present in modprobe.d — removing"
        sudo sed -i '/blacklist nouveau/d' /etc/modprobe.d/*.conf 2>/dev/null || true
        sudo sed -i '/options nouveau modeset=0/d' /etc/modprobe.d/*.conf 2>/dev/null || true
    fi
    # Try to load nouveau now (will succeed if GPU is not in use)
    if sudo modprobe nouveau 2>/dev/null; then
        success "Nouveau driver loaded"
    else
        info "Nouveau not loaded yet — will activate after reboot"
    fi

    # ── 8. Clean ld.so.conf.d CUDA entries ────────────────────
    section "Removing CUDA Library Paths"
    local ldconf_files
    ldconf_files=$(sudo find /etc/ld.so.conf.d/ -name "cuda*.conf" \
        -o -name "nvidia*.conf" 2>/dev/null | tr '\n' ' ')
    if [[ -n "${ldconf_files}" ]]; then
        # shellcheck disable=SC2086
        sudo rm -f ${ldconf_files}
        sudo ldconfig
        success "CUDA ld.so.conf.d entries removed and ldconfig updated"
    else
        info "No CUDA ld.so.conf.d entries — already clean"
    fi

    # ── 9. Remove CUDA PATH profile.d entry ───────────────────
    section "Removing CUDA PATH Configuration"
    if [[ -f /etc/profile.d/cuda.sh ]]; then
        sudo rm -f /etc/profile.d/cuda.sh
        success "Removed /etc/profile.d/cuda.sh"
    else
        info "/etc/profile.d/cuda.sh not found — already clean"
    fi
    # Also clean current session PATH of cuda entries
    export PATH=$(echo "${PATH}" | tr ':' '\n' | grep -v cuda | tr '\n' ':' | sed 's/:$//')
    export LD_LIBRARY_PATH=$(echo "${LD_LIBRARY_PATH:-}" | tr ':' '\n' | grep -v cuda | tr '\n' ':' | sed 's/:$//')

    # ── 10. Remove CUDA apt keyring and sources ───────────────
    section "Removing CUDA Repo & Keyring"
    if dpkg -l cuda-keyring 2>/dev/null | grep -q '^ii'; then
        sudo apt-get purge -y cuda-keyring || true
        success "cuda-keyring package removed"
    fi
    sudo rm -f /usr/share/keyrings/cuda-archive-keyring.gpg
    sudo rm -f /etc/apt/sources.list.d/cuda*.list \
               /etc/apt/sources.list.d/nvidia*.list 2>/dev/null || true
    success "CUDA apt sources cleaned"

    # ── 11. Remove graphics-drivers PPA ──────────────────────
    section "Removing graphics-drivers PPA"
    if find /etc/apt/sources.list.d/ -name '*graphics-drivers*' 2>/dev/null | grep -q .; then
        sudo add-apt-repository -y --remove ppa:graphics-drivers/ppa 2>/dev/null \
            || sudo rm -f /etc/apt/sources.list.d/*graphics-drivers* 2>/dev/null || true
        success "graphics-drivers PPA removed"
    else
        info "graphics-drivers PPA not present — skipping"
    fi

    # ── 12. Remove GCC alternatives ───────────────────────────
    section "Removing GCC Alternatives"
    for ver in 11 12; do
        [[ -f "/usr/bin/gcc-${ver}" ]] \
            && sudo update-alternatives --remove gcc "/usr/bin/gcc-${ver}" 2>/dev/null || true
        [[ -f "/usr/bin/g++-${ver}" ]] \
            && sudo update-alternatives --remove g++ "/usr/bin/g++-${ver}" 2>/dev/null || true
    done
    success "GCC alternatives cleared"

    # ── 13. Optional: remove repos ────────────────────────────
    section "Repo Cleanup (Optional)"
    local infra_dir="${HOME}/infra"
    local gpuburn_dir="${HOME}/gpu-burn"

    if [[ "${NON_INTERACTIVE}" == false ]]; then
        for repo_dir in "${gpuburn_dir}" "${infra_dir}"; do
            if [[ -d "${repo_dir}" ]]; then
                read -rp "  Remove ${repo_dir}? [y/N]: " rm_repo
                if [[ "${rm_repo,,}" == "y" ]]; then
                    rm -rf "${repo_dir}"
                    success "Removed: ${repo_dir}"
                else
                    info "Keeping: ${repo_dir}"
                fi
            fi
        done
    else
        info "Non-interactive mode — keeping repos (remove manually if needed)"
    fi

    # ── 14. apt autoremove + update ───────────────────────────
    section "Final apt Cleanup"
    sudo apt-get autoremove -y  || warn "autoremove had warnings (non-fatal)"
    sudo apt-get update -q      || warn "apt-get update had warnings (non-fatal)"
    success "apt cleanup complete"

    # ── 15. Final verification ────────────────────────────────
    section "Uninstall Verification"
    local remaining
    remaining=$(dpkg -l 2>/dev/null \
        | grep -P '^ii\s+(nvidia|cuda|cudnn|datacenter-gpu-manager|libnvidia)' \
        | awk '{print $2}' | tr '\n' ' ' || true)

    if [[ -n "${remaining}" ]]; then
        warn "Some packages still present:"
        echo "${remaining}" | tr ' ' '\n' | sed 's/^/    /' | grep -v '^$'
        warn "Run manually if needed: sudo apt purge ${remaining}"
    else
        success "Package check: clean — no NVIDIA/CUDA packages remaining"
    fi

    local dkms_remaining
    dkms_remaining=$(dkms status 2>/dev/null | grep -i nvidia || true)
    if [[ -n "${dkms_remaining}" ]]; then
        warn "DKMS entries still present: ${dkms_remaining}"
    else
        success "DKMS check: clean"
    fi

    [[ -f /etc/profile.d/cuda.sh ]] \
        && warn "/etc/profile.d/cuda.sh still exists" \
        || success "PATH check: cuda.sh removed"

    find /etc/modprobe.d/ -name "nvidia*.conf" -o -name "blacklist-nouveau.conf" 2>/dev/null \
        | grep -q . \
        && warn "modprobe.d: some NVIDIA configs still present" \
        || success "modprobe.d check: clean"

    echo ""
    echo -e "${BOLD}════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD} Uninstall complete!${NC}"
    echo -e "  System restored to clean OS state."
    echo -e "  Reboot required to fully unload kernel modules."
    echo -e "  Full log: ${LOG_FILE}"
    echo -e "${BOLD}════════════════════════════════════════${NC}"
    echo ""

    if [[ "${NON_INTERACTIVE}" == false ]]; then
        read -rp "Reboot now to complete cleanup? [Y/n]: " do_reboot
        if [[ "${do_reboot,,}" != "n" ]]; then
            info "Rebooting in 5 seconds... (Ctrl+C to cancel)"
            sleep 5
            sudo reboot
        else
            warn "Reboot required before reprovisioning — run: sudo reboot"
        fi
    else
        info "Non-interactive — reboot manually: sudo reboot"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════
main() {
    detect_ubuntu

    if [[ "${UNINSTALL}" == true ]]; then
        uninstall_node
    else
        preflight_checks

        section "Version Selection"
        select_driver_version
        select_cuda_version
        validate_combination
        confirm_install

        install_base_packages
        configure_gcc_alternatives
        install_cuda_keyring
        install_nvidia_stack
        configure_cuda_path
        install_dcgm
        setup_repos
        validate_install
        offer_reboot
    fi
}

main
