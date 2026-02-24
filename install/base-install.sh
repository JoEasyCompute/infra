#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════
# base-install.sh — GPU Node Base Installation Script
# Supports: Ubuntu 22.04 / 24.04 (x86_64)
# Installs: NVIDIA drivers, CUDA toolkit, cuDNN, DCGM, gpu-burn
# ═══════════════════════════════════════════════════════════════

# ─── Logging setup ────────────────────────────────────────────
LOG_DIR="/var/log/gpu-node-install"
LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
sudo mkdir -p "${LOG_DIR}"
sudo chmod 777 "${LOG_DIR}"
# Tee all stdout+stderr to log file and terminal
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "════════════════════════════════════════════════════════"
echo " GPU Node Installation Script"
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
error()   { echo -e "${RED}[ERROR]${NC}   $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}── $* ──${NC}"; }

# ─── CLI argument parsing (non-interactive / CI mode) ─────────
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
  $(basename "$0")                        # Interactive mode
  $(basename "$0") --driver 580 --cuda 12-9   # Explicit versions
  $(basename "$0") --yes                  # Non-interactive with defaults
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

# ═══════════════════════════════════════════════════════════════
# STEP 1 — Detect Ubuntu Version
# ═══════════════════════════════════════════════════════════════
detect_ubuntu() {
    section "Detecting OS"

    [[ -f /etc/os-release ]] || error "Cannot detect OS — /etc/os-release not found"
    # shellcheck source=/dev/null
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
    local errors=0

    # ── Sudo access ──────────────────────────────────────────
    if sudo -n true 2>/dev/null; then
        success "Sudo access: OK"
    else
        error "Script requires sudo access. Run as a sudoer or with sudo."
    fi

    # ── Architecture ─────────────────────────────────────────
    local arch
    arch=$(uname -m)
    if [[ "${arch}" == "x86_64" ]]; then
        success "Architecture: ${arch}"
    else
        error "Unsupported architecture: ${arch}. Only x86_64 is supported."
    fi

    # ── Disk space — require 15GB free on /usr ───────────────
    local free_gb
    free_gb=$(df --output=avail -BG /usr | tail -1 | tr -d 'G ')
    if (( free_gb >= 15 )); then
        success "Disk space: ${free_gb}GB free on /usr (need 15GB+)"
    else
        error "Insufficient disk space: ${free_gb}GB free on /usr — need at least 15GB"
    fi

    # ── Network reachability ─────────────────────────────────
    # curl may not be installed yet on a fresh node — use ping as primary check,
    # curl as a secondary HTTPS check only if available
    check_host_reachable() {
        local host="$1"
        local label="$2"
        local is_required="$3"   # "error" or "warn"

        if ping -c 1 -W 5 "${host}" &>/dev/null; then
            # Host is reachable at network level — now verify HTTPS if curl available.
            # Use -L to follow CDN redirects (e.g. Akamai), -k only for reachability test
            # (ca-certificates may not be installed yet on a fresh node).
            if command -v curl &>/dev/null; then
                if curl -sfL --max-time 10 "https://${host}" -o /dev/null 2>/dev/null; then
                    success "Network: ${label} reachable (HTTPS OK)"
                elif curl -sfLk --max-time 10 "https://${host}" -o /dev/null 2>/dev/null; then
                    warn "Network: ${label} reachable but TLS verification failed — ca-certificates may need update (will be fixed during base package install)"
                else
                    warn "Network: ${label} pingable but HTTPS check failed — continuing (apt will surface real errors)"
                fi
            else
                success "Network: ${label} reachable (ping OK — curl not yet installed)"
            fi
        else
            if [[ "${is_required}" == "error" ]]; then
                error "Cannot reach ${host} — host is not pingable, check network/firewall"
            else
                warn "Cannot reach ${host} — related steps may fail"
            fi
        fi
    }

    check_host_reachable "developer.download.nvidia.com" "NVIDIA repo" "error"
    check_host_reachable "github.com"                    "GitHub"      "warn"

    # ── Secure Boot ──────────────────────────────────────────
    if command -v mokutil &>/dev/null; then
        if mokutil --sb-state 2>/dev/null | grep -q "enabled"; then
            warn "Secure Boot is ENABLED — DKMS/nvidia-open modules may fail to load after reboot"
            warn "Disable Secure Boot in BIOS, or enroll the MOK key post-install"
            if [[ "${NON_INTERACTIVE}" == false ]]; then
                read -rp "  Continue anyway? [y/N]: " sb_confirm
                [[ "${sb_confirm,,}" == "y" ]] || error "Aborted by user (Secure Boot concern)."
            else
                warn "Non-interactive mode — continuing despite Secure Boot"
            fi
        else
            success "Secure Boot: disabled (OK for DKMS)"
        fi
    else
        info "mokutil not found — skipping Secure Boot check"
    fi

    # ── Existing NVIDIA packages ──────────────────────────────
    if dpkg -l 2>/dev/null | grep -qP '^ii\s+(nvidia-driver|libnvidia-compute|cuda-)'; then
        warn "Existing NVIDIA/CUDA packages detected:"
        dpkg -l 2>/dev/null | grep -P '^ii\s+(nvidia|cuda|cudnn)' | awk '{printf "    %-45s %s\n", $2, $3}' || true
        warn "These may conflict with the new install."
        warn "To purge: sudo apt purge ~nnvidia ~ncuda && sudo apt autoremove"
        if [[ "${NON_INTERACTIVE}" == false ]]; then
            read -rp "  Continue anyway? [y/N]: " purge_confirm
            [[ "${purge_confirm,,}" == "y" ]] || error "Aborted by user (existing NVIDIA packages)."
        else
            warn "Non-interactive mode — continuing despite existing packages"
        fi
    else
        success "No conflicting NVIDIA/CUDA packages found"
    fi

    # ── Kernel headers available ──────────────────────────────
    local kernel_ver
    kernel_ver=$(uname -r)
    if apt-cache show "linux-headers-${kernel_ver}" &>/dev/null; then
        success "Kernel headers available for: ${kernel_ver}"
    else
        warn "linux-headers-${kernel_ver} not found in apt cache — DKMS build may fail"
        (( errors++ )) || true
    fi

    # ── Summary ───────────────────────────────────────────────
    if (( errors > 0 )); then
        warn "${errors} pre-flight warning(s) — review above before proceeding"
    else
        success "All pre-flight checks passed"
    fi
}

# ═══════════════════════════════════════════════════════════════
# STEP 3 — Select Driver and CUDA versions
# ═══════════════════════════════════════════════════════════════
select_driver_version() {
    if [[ -n "${DRIVER_VERSION}" ]]; then
        # Validate CLI-provided value
        case "${DRIVER_VERSION}" in
            575|580|590) success "Driver version (from args): ${DRIVER_VERSION}" ;;
            *) error "Invalid --driver value: ${DRIVER_VERSION}. Valid: 575, 580, 590" ;;
        esac
        return
    fi

    if [[ "${NON_INTERACTIVE}" == true ]]; then
        DRIVER_VERSION="580"
        success "Driver version (default): ${DRIVER_VERSION}"
        return
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
            *) error "Invalid --cuda value: ${CUDA_VERSION}. Valid: 12-9, 13" ;;
        esac
        success "CUDA toolkit version (from args): ${CUDA_TOOLKIT_VERSION}"
        return
    fi

    if [[ "${NON_INTERACTIVE}" == true ]]; then
        CUDA_TOOLKIT_VERSION="12-9"
        CUDA_MAJOR="12"
        success "CUDA toolkit version (default): ${CUDA_TOOLKIT_VERSION}"
        return
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
    success "CUDA toolkit version: ${CUDA_TOOLKIT_VERSION}"
}

validate_combination() {
    # CUDA 13 is safest with driver 580+
    if [[ "${CUDA_MAJOR}" == "13" && "${DRIVER_VERSION}" == "575" ]]; then
        warn "Driver 575 + CUDA 13 may have compatibility issues. Recommended: driver 580 or 590."
        if [[ "${NON_INTERACTIVE}" == false ]]; then
            read -rp "  Continue anyway? [y/N]: " confirm
            [[ "${confirm,,}" == "y" ]] || error "Aborted by user."
        else
            warn "Non-interactive mode — continuing with potentially incompatible combination"
        fi
    fi
    success "Combination validated: Driver ${DRIVER_VERSION} + CUDA ${CUDA_TOOLKIT_VERSION}"
}

# ═══════════════════════════════════════════════════════════════
# STEP 4 — Confirm before installing
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
    else
        info "Non-interactive mode — proceeding automatically"
    fi
}

# ═══════════════════════════════════════════════════════════════
# STEP 5 — Base system packages
# ═══════════════════════════════════════════════════════════════
install_base_packages() {
    section "Base System Packages"

    info "Adding graphics-drivers PPA..."
    sudo add-apt-repository -y ppa:graphics-drivers/ppa
    sudo apt-get update -q

    info "Installing base packages..."
    sudo apt-get install -y \
        git apt-transport-https ca-certificates curl software-properties-common \
        cmake build-essential dkms alsa-utils \
        gcc-11 g++-11 gcc-12 g++-12 gnupg lsb-release \
        ipmitool jq pciutils iproute2 util-linux dmidecode lshw \
        coreutils chrony nvme-cli bpytop mokutil \
        python3 python3-pip python3-venv

    sudo systemctl enable --now chrony
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
# STEP 7 — CUDA repo keyring
# ═══════════════════════════════════════════════════════════════
install_cuda_keyring() {
    section "CUDA Repository Keyring"

    local keyring_gpg="/usr/share/keyrings/cuda-archive-keyring.gpg"
    local deb="cuda-keyring_1.1-1_all.deb"
    local url="https://developer.download.nvidia.com/compute/cuda/repos/${UBUNTU_CODENAME}/x86_64/${deb}"

    if [[ -f "${keyring_gpg}" ]]; then
        info "CUDA keyring already installed — skipping download"
    else
        info "Downloading CUDA keyring..."
        info "  URL: ${url}"
        wget -q --show-progress -O "/tmp/${deb}" "${url}"
        sudo dpkg -i "/tmp/${deb}"
        rm "/tmp/${deb}"
        success "CUDA keyring installed"
    fi

    sudo apt-get update -q
    sudo apt-get upgrade -y
}

# ═══════════════════════════════════════════════════════════════
# STEP 8 — NVIDIA driver, CUDA toolkit, cuDNN, nvtop
# ═══════════════════════════════════════════════════════════════
install_nvidia_stack() {
    section "NVIDIA Driver + CUDA Stack"

    info "Installing: driver=${DRIVER_VERSION}, cuda=${CUDA_TOOLKIT_VERSION}, cudnn=cudnn9-cuda-${CUDA_MAJOR}"
    sudo apt-get install -V -y \
        "cuda-toolkit-${CUDA_TOOLKIT_VERSION}" \
        "libnvidia-compute-${DRIVER_VERSION}" \
        "nvidia-dkms-${DRIVER_VERSION}-open" \
        "cudnn9-cuda-${CUDA_MAJOR}" \
        nvtop

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
        sudo apt-get install -y "datacenter-gpu-manager-4-cuda${live_cuda_major}"
        sudo systemctl enable --now nvidia-dcgm
        success "DCGM installed and enabled"
    else
        warn "nvidia-smi not available — DCGM install deferred (reboot first, then re-run)"
    fi
}

# ═══════════════════════════════════════════════════════════════
# STEP 10 — Clone repos and build gpu-burn
# ═══════════════════════════════════════════════════════════════
setup_repos() {
    section "Repos & gpu-burn"

    local infra_dir="${HOME}/infra"
    local gpuburn_dir="${HOME}/gpu-burn"

    if [[ -d "${infra_dir}" ]]; then
        info "infra repo already exists — pulling latest"
        git -C "${infra_dir}" pull --ff-only || warn "Could not pull infra repo (local changes?)"
    else
        git clone https://github.com/joeasycompute/infra.git "${infra_dir}"
        success "Cloned infra → ${infra_dir}"
    fi

    if [[ -d "${gpuburn_dir}" ]]; then
        info "gpu-burn repo already exists — pulling latest"
        git -C "${gpuburn_dir}" pull --ff-only || warn "Could not pull gpu-burn repo (local changes?)"
    else
        git clone https://github.com/wilicc/gpu-burn.git "${gpuburn_dir}"
        success "Cloned gpu-burn → ${gpuburn_dir}"
    fi

    if command -v nvcc &>/dev/null; then
        info "Building gpu-burn..."
        (cd "${gpuburn_dir}" && make)
        success "gpu-burn built: ${gpuburn_dir}/gpu_burn"
    else
        warn "nvcc not in PATH — skipping gpu-burn build (reboot first, then re-run)"
    fi
}

# ═══════════════════════════════════════════════════════════════
# STEP 11 — Post-install validation
# ═══════════════════════════════════════════════════════════════
validate_install() {
    section "Post-install Validation"
    local warnings=0

    # nvidia-smi
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        local gpu_name
        gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
        local gpu_count
        gpu_count=$(nvidia-smi --query-gpu=count --format=csv,noheader | head -1)
        success "nvidia-smi: ${gpu_count}x ${gpu_name}"
    else
        warn "nvidia-smi not operational (expected after fresh driver install — reboot required)"
        (( warnings++ )) || true
    fi

    # nvcc
    if command -v nvcc &>/dev/null; then
        success "nvcc: $(nvcc --version | grep -oP 'release \K[0-9.]+')"
    else
        warn "nvcc not in PATH (may need reboot or PATH reload)"
        (( warnings++ )) || true
    fi

    # nvidia-dcgm
    if systemctl is-active --quiet nvidia-dcgm 2>/dev/null; then
        success "nvidia-dcgm: running"
    else
        warn "nvidia-dcgm: not running (expected before reboot)"
        (( warnings++ )) || true
    fi

    # chrony
    if systemctl is-active --quiet chrony; then
        success "chrony: running"
    else
        warn "chrony: not running"
        (( warnings++ )) || true
    fi

    # gpu-burn binary
    if [[ -f "${HOME}/gpu-burn/gpu_burn" ]]; then
        success "gpu-burn: built and ready"
    else
        warn "gpu-burn: not built (expected if nvcc was missing pre-reboot)"
        (( warnings++ )) || true
    fi

    # infra repo
    if [[ -d "${HOME}/infra" ]]; then
        success "infra repo: present"
    else
        warn "infra repo: not found"
        (( warnings++ )) || true
    fi

    echo ""
    if (( warnings > 0 )); then
        warn "${warnings} item(s) need attention — most will resolve after reboot"
    else
        success "All validation checks passed — node is ready"
    fi
}

# ═══════════════════════════════════════════════════════════════
# STEP 12 — Reboot prompt
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
            info "Non-interactive mode — skipping reboot. Reboot manually to load kernel modules."
        else
            read -rp "Reboot now to load NVIDIA kernel modules? [Y/n]: " do_reboot
            if [[ "${do_reboot,,}" != "n" ]]; then
                info "Rebooting in 5 seconds... (Ctrl+C to cancel)"
                sleep 5
                sudo reboot
            else
                warn "Remember to reboot before running GPU workloads or gpu-burn"
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
