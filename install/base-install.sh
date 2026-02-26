#!/usr/bin/env bash

# ═══════════════════════════════════════════════════════════════
# base-install.sh — GPU Node Base Installation Script
# Supports: Ubuntu 22.04 / 24.04 (x86_64)
# Installs: NVIDIA drivers, CUDA toolkit, cuDNN, DCGM, gpu-burn
# Version:  1.6 (2026-02-24)
# ═══════════════════════════════════════════════════════════════

# No set -e — we use explicit error checking so nothing dies silently.
# set -u catches unbound variables. set -o pipefail catches pipe failures.
set -uo pipefail

# ─── Logging ──────────────────────────────────────────────────
# Simple approach: tee to file, keep stdin untouched.
# We don't redirect stdin at all — read prompts work normally.
LOG_DIR="/var/log/gpu-node-install"
sudo mkdir -p "${LOG_DIR}" && sudo chmod 777 "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"

# Only redirect stdout/stderr — stdin is left alone
exec > >(tee -a "${LOG_FILE}") 2> >(tee -a "${LOG_FILE}" >&2)

echo "════════════════════════════════════════════════════════"
echo " GPU Node Installation Script  (v1.6 — 2026-02-24)"
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

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --driver  <575|580|590>    NVIDIA driver version (default: interactive)
  --cuda    <12-9|13>        CUDA toolkit version  (default: interactive)
  --yes                      Non-interactive mode, use defaults (580 + 12-9)
  -h, --help                 Show this help

Examples:
  $(basename "$0")                          # Interactive mode
  $(basename "$0") --driver 580 --cuda 12-9 # Explicit versions
  $(basename "$0") --yes                    # Non-interactive with defaults
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --driver) DRIVER_VERSION="$2"; shift 2 ;;
        --cuda)   CUDA_VERSION="$2";   shift 2 ;;
        --yes)    NON_INTERACTIVE=true; shift ;;
        -h|--help) usage ;;
        *) error "Unknown option: $1. Use --help for usage." ;;
    esac
done

# ─── Helper: run a command and exit on failure with clear message ──
run() {
    local desc="$1"; shift
    info "Running: $*"
    if ! "$@"; then
        error "Failed at step: ${desc}\n  Command: $*\n  Check log: ${LOG_FILE}"
    fi
}

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

    # Kernel headers
    local kver; kver=$(uname -r)
    if apt-cache show "linux-headers-${kver}" &>/dev/null; then
        success "Kernel headers: available for ${kver}"
    else
        warn "linux-headers-${kver} not in apt cache — DKMS build may fail"
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

    info "Bootstrapping prerequisites (software-properties-common etc)..."
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

    info "Installing base packages..."
    sudo apt-get install -y \
        git cmake build-essential dkms alsa-utils \
        gcc-11 g++-11 gcc-12 g++-12 lsb-release \
        ipmitool jq pciutils iproute2 util-linux dmidecode lshw \
        coreutils chrony nvme-cli smartmontools fio ioping bpytop mokutil \
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
        "cudnn9-cuda-${CUDA_MAJOR}" \
        nvtop \
        || error "NVIDIA stack install failed — check apt output above"
    success "NVIDIA stack installed"
}

# ═══════════════════════════════════════════════════════════════
# STEP 9 — DCGM
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
# STEP 10 — Repos & gpu-burn
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
# STEP 11 — Validation
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
        warn "nvcc not in PATH"; (( warnings++ )) || true
    fi

    systemctl is-active --quiet nvidia-dcgm 2>/dev/null \
        && success "nvidia-dcgm: running" \
        || { warn "nvidia-dcgm: not running (expected before reboot)"; (( warnings++ )) || true; }

    systemctl is-active --quiet chrony \
        && success "chrony: running" \
        || { warn "chrony not running"; (( warnings++ )) || true; }

    [[ -f "${HOME}/gpu-burn/gpu_burn" ]] \
        && success "gpu-burn: ready" \
        || { warn "gpu-burn: not built"; (( warnings++ )) || true; }

    [[ -d "${HOME}/infra" ]] \
        && success "infra repo: present" \
        || { warn "infra repo: missing"; (( warnings++ )) || true; }

    echo ""
    (( warnings > 0 )) \
        && warn "${warnings} item(s) pending — most resolve after reboot" \
        || success "All checks passed — node is ready"
}

# ═══════════════════════════════════════════════════════════════
# STEP 12 — Reboot
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
# Main
# ═══════════════════════════════════════════════════════════════
main() {
    detect_ubuntu
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
    install_dcgm
    setup_repos
    validate_install
    offer_reboot
}

main
