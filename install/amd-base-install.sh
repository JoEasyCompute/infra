#!/usr/bin/env bash

# ═══════════════════════════════════════════════════════════════
# base-install-amd.sh — AMD GPU Node Base Installation Script
# Target:   Any supported AMD GPU (ROCm-compatible)
# Supports: Ubuntu 22.04 / 24.04 (x86_64)
# Installs: AMDGPU DKMS driver, ROCm stack, rocm-bandwidth-test
# Version:  2.0 (2026-03-15)
# ═══════════════════════════════════════════════════════════════
#
# Notes:
#   * ROCm 7.2 is the current production release.
#   * Ubuntu 22.04 requires kernel 5.15+ (stock LTS kernel is fine).
#   * Ubuntu 24.04 requires kernel 6.8+ (stock noble HWE kernel is fine).
#   * AMD GPUs require the user to be in the 'render' and 'video' groups.
#   * No DCGM equivalent exists for AMD; rocm-smi and rocminfo are used instead.
#   * P2P / xGMI support varies by GPU family. Consumer/pro RDNA cards use
#     PCIe peer transfers; Instinct cards support xGMI natively.
#
# No set -e -- explicit error checking on every critical step.
# set -u catches unbound variables. set -o pipefail catches pipe failures.
set -uo pipefail

# --- Logging ----------------------------------------------------
LOG_DIR="/var/log/amd-node-install"
sudo mkdir -p "${LOG_DIR}" && sudo chmod 777 "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2> >(tee -a "${LOG_FILE}" >&2)

echo "================================================================"
echo " AMD GPU Node Installation Script  (v2.0 -- 2026-03-15)"
echo " Target: Any ROCm-compatible AMD GPU"
echo " Log: ${LOG_FILE}"
echo " Started: $(date)"
echo "================================================================"
echo ""

# --- Color helpers -----------------------------------------------
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}    $*"; }
success() { echo -e "${GREEN}[OK]${NC}      $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC}   $*"; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}-- $* --${NC}"; }

APT_LOCK_TIMEOUT=1800

apt_get() {
    sudo DEBIAN_FRONTEND=noninteractive \
        apt-get -o DPkg::Lock::Timeout="${APT_LOCK_TIMEOUT}" "$@"
}

# --- CLI argument parsing ----------------------------------------
ROCM_VERSION=""
NON_INTERACTIVE=false
UNINSTALL=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --rocm    <7.2|7.1>        ROCm version to install (default: interactive -> 7.2)
  --yes                      Non-interactive mode, use defaults (ROCm 7.2)
  --uninstall                Full clean removal -- restores system to post-OS-install state
  -h, --help                 Show this help

Examples:
  $(basename "$0")                   # Interactive install
  $(basename "$0") --rocm 7.2        # Explicit ROCm version
  $(basename "$0") --yes             # Non-interactive with defaults
  $(basename "$0") --uninstall       # Interactive uninstall
  $(basename "$0") --uninstall --yes # Non-interactive uninstall

Post-install validation:
  rocm-smi                   # GPU status (analogous to nvidia-smi)
  rocminfo                   # Detailed GPU topology
  rocm-bandwidth-test -a     # PCIe bandwidth test
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rocm)      ROCM_VERSION="$2"; shift 2 ;;
        --yes)       NON_INTERACTIVE=true; shift ;;
        --uninstall) UNINSTALL=true; shift ;;
        -h|--help)   usage ;;
        *) error "Unknown option: $1. Use --help for usage." ;;
    esac
done

# ================================================================
# STEP 1 -- Detect Ubuntu Version
# ================================================================
detect_ubuntu() {
    section "Detecting OS"
    [[ -f /etc/os-release ]] || error "Cannot detect OS -- /etc/os-release not found"
    source /etc/os-release
    [[ "${ID}" == "ubuntu" ]] || error "This script requires Ubuntu. Detected: ${ID}"
    case "${VERSION_ID}" in
        "22.04") UBUNTU_CODENAME="jammy" ;;
        "24.04") UBUNTU_CODENAME="noble" ;;
        *) error "Unsupported Ubuntu version: ${VERSION_ID}. Supported: 22.04, 24.04" ;;
    esac
    UBUNTU_VERSION_ID="${VERSION_ID}"
    success "Detected Ubuntu ${VERSION_ID} -> codename: ${UBUNTU_CODENAME}"
}

# ================================================================
# STEP 2 -- Pre-flight Checks
# ================================================================
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

    # Disk space -- ROCm stack is large (~8-10 GB)
    local free_gb
    free_gb=$(df --output=avail -BG /usr | tail -1 | tr -d 'G ')
    if (( free_gb >= 15 )); then
        success "Disk space: ${free_gb}GB free on /usr"
    else
        error "Insufficient disk space: ${free_gb}GB free on /usr -- need 15GB+ (ROCm is large)"
    fi

    # Network
    check_host() {
        local host="$1" label="$2" required="$3"
        if ping -c 1 -W 5 "${host}" &>/dev/null; then
            if command -v curl &>/dev/null; then
                if curl -sfL --max-time 10 "https://${host}" -o /dev/null 2>/dev/null; then
                    success "Network: ${label} (HTTPS OK)"
                elif curl -sfLk --max-time 10 "https://${host}" -o /dev/null 2>/dev/null; then
                    warn "Network: ${label} -- TLS untrusted (ca-certificates will be updated)"
                else
                    warn "Network: ${label} pingable, HTTPS check failed -- continuing"
                fi
            else
                success "Network: ${label} (ping OK)"
            fi
        else
            [[ "${required}" == "hard" ]] \
                && error "Cannot reach ${host} -- check network/firewall" \
                || warn "Cannot reach ${host} -- some steps may fail"
        fi
    }
    check_host "repo.radeon.com" "AMD ROCm repo" "hard"
    check_host "github.com"      "GitHub"         "soft"

    # Secure Boot -- DKMS modules will fail to load if enabled
    if command -v mokutil &>/dev/null && mokutil --sb-state 2>/dev/null | grep -q "enabled"; then
        warn "Secure Boot ENABLED -- AMDGPU DKMS module may fail to load. Disable in BIOS."
        if [[ "${NON_INTERACTIVE}" == false ]]; then
            read -rp "  Continue anyway? [y/N]: " sb_confirm
            [[ "${sb_confirm,,}" == "y" ]] || error "Aborted."
        fi
    else
        success "Secure Boot: disabled (OK)"
    fi

    # Existing AMDGPU / ROCm packages
    if dpkg -l 2>/dev/null | grep -qP '^ii\s+(amdgpu|rocm|hip-)'; then
        warn "Existing AMDGPU/ROCm packages found -- may conflict:"
        dpkg -l 2>/dev/null | grep -P '^ii\s+(amdgpu|rocm|hip-)' | awk '{printf "    %s %s\n", $2, $3}' || true
        if [[ "${NON_INTERACTIVE}" == false ]]; then
            read -rp "  Continue anyway? [y/N]: " purge_confirm
            [[ "${purge_confirm,,}" == "y" ]] || error "Aborted."
        fi
    else
        success "No conflicting AMDGPU/ROCm packages"
    fi

    # Kernel version check -- amdgpu-dkms only builds successfully against
    # kernels that AMD has qualified. For ROCm 7.x:
    #   Ubuntu 22.04: supported kernels are 5.15.x (GA) and 6.8.x (HWE).
    #                 Kernels 6.11+ are NOT yet supported and will fail to build.
    #   Ubuntu 24.04: supported kernel is 6.8.x (GA).
    #                 Kernels 6.11+ are NOT yet supported and will fail to build.
    # Source: https://rocm.docs.amd.com/projects/install-on-linux/en/latest/reference/system-requirements.html
    local kver; kver=$(uname -r)
    local kmaj kmin
    kmaj=$(echo "${kver}" | cut -d. -f1)
    kmin=$(echo "${kver}" | cut -d. -f2)
    local knum=$(( kmaj * 100 + kmin ))   # e.g. 5.15 -> 515, 6.8 -> 608, 6.11 -> 611

    if [[ "${UBUNTU_VERSION_ID}" == "22.04" ]]; then
        # 22.04 supports: 5.15.x (GA) and 6.8.x (HWE). Anything above 6.8 is unsupported.
        if (( knum == 515 )) || (( knum == 608 )); then
            success "Kernel ${kver}: supported for ROCm ${ROCM_VERSION} on Ubuntu 22.04"
        elif (( knum > 608 )); then
            warn "Kernel ${kver} is NEWER than supported range for ROCm 7.x on Ubuntu 22.04"
            warn "amdgpu-dkms WILL LIKELY FAIL TO BUILD. Supported kernels: 5.15.x (GA), 6.8.x (HWE)"
            warn "Fix: boot into the 6.8 HWE kernel or install it:"
            warn "  sudo apt install linux-generic-hwe-22.04 && sudo reboot"
            warn "  Then re-run this script after rebooting into 6.8."
            if [[ "${NON_INTERACTIVE}" == false ]]; then
                read -rp "  Continue anyway? [y/N]: " kver_confirm
                [[ "${kver_confirm,,}" == "y" ]] || error "Aborted. Reboot into a supported kernel first."
            fi
            (( warnings++ )) || true
        else
            # Below 5.15 — very unlikely on a fresh 22.04, but catch it
            warn "Kernel ${kver} is older than expected for Ubuntu 22.04 (expected 5.15+)"
            (( warnings++ )) || true
        fi
    elif [[ "${UBUNTU_VERSION_ID}" == "24.04" ]]; then
        # 24.04 GA kernel is 6.8. Kernels above 6.8 (e.g. 6.11 HWE) are unsupported.
        if (( knum == 608 )); then
            success "Kernel ${kver}: supported for ROCm ${ROCM_VERSION} on Ubuntu 24.04"
        elif (( knum > 608 )); then
            warn "Kernel ${kver} is NEWER than supported range for ROCm 7.x on Ubuntu 24.04"
            warn "amdgpu-dkms WILL LIKELY FAIL TO BUILD. Supported kernel: 6.8.x (GA)"
            warn "Fix: revert to GA kernel or pin it:"
            warn "  sudo apt install linux-image-6.8.0-generic linux-headers-6.8.0-generic"
            warn "  Then reboot and select 6.8 in GRUB before re-running this script."
            if [[ "${NON_INTERACTIVE}" == false ]]; then
                read -rp "  Continue anyway? [y/N]: " kver_confirm
                [[ "${kver_confirm,,}" == "y" ]] || error "Aborted. Reboot into a supported kernel first."
            fi
            (( warnings++ )) || true
        else
            warn "Kernel ${kver} is older than the 24.04 GA kernel (6.8) -- unexpected"
            (( warnings++ )) || true
        fi
    fi

    # Kernel headers -- required for amdgpu-dkms
    if apt-cache show "linux-headers-${kver}" &>/dev/null; then
        success "Kernel headers: available for ${kver}"
    else
        warn "linux-headers-${kver} not in apt cache -- will attempt install anyway"
        (( warnings++ )) || true
    fi

    # Check for AMD GPU in lspci
    if lspci 2>/dev/null | grep -qi "amd\|radeon\|advanced micro"; then
        local gpu_info
        gpu_info=$(lspci 2>/dev/null | grep -i "amd\|radeon" | head -3)
        success "AMD GPU detected in lspci:"
        echo "${gpu_info}" | sed 's/^/    /'
    else
        warn "No AMD GPU detected in lspci -- verify hardware before continuing"
        (( warnings++ )) || true
    fi

    (( warnings > 0 )) && warn "${warnings} warning(s) above" || success "All pre-flight checks passed"
}

# ================================================================
# STEP 3 -- ROCm Version Selection
# ================================================================
select_rocm_version() {
    if [[ -n "${ROCM_VERSION}" ]]; then
        case "${ROCM_VERSION}" in
            "7.2"|"7.1") success "ROCm version (--rocm arg): ${ROCM_VERSION}"; return ;;
            *) error "Invalid --rocm: ${ROCM_VERSION}. Valid: 7.1, 7.2" ;;
        esac
    fi
    if [[ "${NON_INTERACTIVE}" == true ]]; then
        ROCM_VERSION="7.2"; success "ROCm version (default): ${ROCM_VERSION}"; return
    fi
    echo ""
    echo -e "${BOLD}Select ROCm Version:${NC}"
    echo "  1) 7.2  -- current production release [default]"
    echo "  2) 7.1  -- previous stable"
    echo ""
    read -rp "Enter choice [1-2, default=1]: " rocm_choice
    case "${rocm_choice}" in
        2) ROCM_VERSION="7.1" ;;
        *) ROCM_VERSION="7.2" ;;
    esac
    success "ROCm version: ${ROCM_VERSION}"
}

# ================================================================
# STEP 4 -- Confirm
# ================================================================
confirm_install() {
    echo ""
    echo -e "${BOLD}=======================================${NC}"
    echo -e "  Ubuntu:         ${UBUNTU_VERSION_ID} (${UBUNTU_CODENAME})"
    echo -e "  AMDGPU driver:  amdgpu-dkms (ROCm ${ROCM_VERSION} repo)"
    echo -e "  ROCm version:   ${ROCM_VERSION}"
    echo -e "  GPU target:     Any ROCm-compatible AMD GPU"
    echo -e "  PyTorch arch:   auto-detected post-reboot (Step 9.5)"
    echo -e "  Log file:       ${LOG_FILE}"
    echo -e "${BOLD}=======================================${NC}"
    echo ""
    if [[ "${NON_INTERACTIVE}" == false ]]; then
        read -rp "Proceed with installation? [Y/n]: " proceed
        [[ "${proceed,,}" == "n" ]] && error "Aborted by user."
        info "Starting installation..."
    else
        info "Non-interactive mode -- starting installation..."
    fi
}

# ================================================================
# STEP 5 -- Base packages
# ================================================================
install_base_packages() {
    section "Base System Packages"

    info "Bootstrapping prerequisites..."
    apt_get update -q \
        || error "apt-get update failed"
    apt_get install -y \
        software-properties-common apt-transport-https ca-certificates curl gnupg wget \
        || error "Bootstrap package install failed"

    # Kernel headers and modules-extra -- both required for amdgpu-dkms
    local kver; kver=$(uname -r)
    info "Installing kernel headers for: ${kver}"
    apt_get install -y \
        "linux-headers-${kver}" \
        linux-headers-generic \
        "linux-modules-extra-${kver}" \
        || warn "Kernel headers install had warnings -- DKMS build may fail"

    info "Installing base packages..."
    apt_get install -y \
        git cmake build-essential dkms alsa-utils \
        gcc-11 g++-11 gcc-12 g++-12 lsb-release \
        ipmitool jq pciutils iproute2 util-linux dmidecode lshw \
        coreutils chrony nvme-cli bpytop mokutil \
        python3 python3-pip python3-venv \
        python3-setuptools python3-wheel \
        smartmontools \
        lvm2 mdadm lsof ioping \
        || error "Base package install failed"
    # Note: fio is intentionally NOT installed here -- managed by disktest.sh.

    sudo systemctl enable --now chrony \
        || warn "Failed to enable chrony"
    success "Base packages installed"
}

# ================================================================
# STEP 6 -- GCC alternatives
# ================================================================
configure_gcc_alternatives() {
    section "GCC Alternatives"
    sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 11
    sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-11 11
    sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 12
    sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-12 12
    success "GCC alternatives configured (active: gcc-12)"
}

# ================================================================
# STEP 7 -- AMD ROCm GPG key + repos
# ================================================================
install_rocm_repos() {
    section "AMD ROCm Repository & Signing Key"

    # Remove any stale repo files from a previous (possibly failed) run.
    # This prevents apt from using an old/wrong URL on the apt-get update below.
    if [[ -f /etc/apt/sources.list.d/amdgpu.list ]] || [[ -f /etc/apt/sources.list.d/rocm.list ]]; then
        info "Removing stale AMD repo files from previous run..."
        sudo rm -f /etc/apt/sources.list.d/amdgpu.list \
                   /etc/apt/sources.list.d/rocm.list \
                   /etc/apt/preferences.d/rocm-pin-600
        apt_get update -q 2>/dev/null || true   # flush stale cache; errors OK here
        success "Stale repo files removed"
    fi

    # The amdgpu driver repo uses a build number (e.g. 30.30), NOT the ROCm
    # version string. The ROCm apt repo DOES use the ROCm version string.
    # Mapping: ROCm 7.2 -> amdgpu 30.30 | ROCm 7.1 -> amdgpu 30.20.1
    # Source: https://repo.radeon.com/amdgpu/ (directory listing)
    local AMDGPU_BUILD_VERSION
    case "${ROCM_VERSION}" in
        "7.2") AMDGPU_BUILD_VERSION="30.30" ;;
        "7.1") AMDGPU_BUILD_VERSION="30.20.1" ;;
        *)     error "No known amdgpu build version for ROCm ${ROCM_VERSION}" ;;
    esac
    info "ROCm ${ROCM_VERSION} -> AMDGPU driver build: ${AMDGPU_BUILD_VERSION}"

    # GPG keyring directory (recommended location per AMD docs)
    sudo mkdir -p --mode=0755 /etc/apt/keyrings

    info "Downloading AMD ROCm GPG key..."
    wget -q -O - https://repo.radeon.com/rocm/rocm.gpg.key \
        | gpg --dearmor \
        | sudo tee /etc/apt/keyrings/rocm.gpg > /dev/null \
        || error "Failed to install AMD ROCm GPG key"
    success "GPG key installed -> /etc/apt/keyrings/rocm.gpg"

    # AMDGPU driver repo (provides amdgpu-dkms)
    # NOTE: this URL uses the build number (e.g. 30.30), NOT the ROCm version.
    info "Adding AMDGPU driver repository (build ${AMDGPU_BUILD_VERSION})..."
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/amdgpu/${AMDGPU_BUILD_VERSION}/ubuntu ${UBUNTU_CODENAME} main" \
        | sudo tee /etc/apt/sources.list.d/amdgpu.list > /dev/null

    # ROCm software repo
    # NOTE: this URL DOES use the ROCm version string.
    info "Adding ROCm software repository (${ROCM_VERSION})..."
    printf "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/%s %s main\ndeb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/graphics/%s/ubuntu %s main\n" \
        "${ROCM_VERSION}" "${UBUNTU_CODENAME}" "${ROCM_VERSION}" "${UBUNTU_CODENAME}" \
        | sudo tee /etc/apt/sources.list.d/rocm.list > /dev/null

    # Pin AMD repos to priority 600 so they win over Ubuntu defaults for AMD packages
    printf "Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600\n" \
        | sudo tee /etc/apt/preferences.d/rocm-pin-600 > /dev/null

    apt_get update -q || error "apt-get update after ROCm repo setup failed"
    success "AMD ROCm repositories configured (ROCm ${ROCM_VERSION} / amdgpu ${AMDGPU_BUILD_VERSION}, ${UBUNTU_CODENAME})"
}

# ================================================================
# STEP 8 -- AMDGPU DKMS driver + ROCm stack
# ================================================================
install_amd_stack() {
    section "AMDGPU Driver + ROCm Stack"
    info "Installing amdgpu-dkms kernel driver..."
    apt_get install -V -y \
        amdgpu-dkms \
        || error "amdgpu-dkms install failed -- check kernel headers and DKMS"
    success "amdgpu-dkms installed"

    info "Installing ROCm ${ROCM_VERSION} stack..."
    # 'rocm' meta-package pulls in: HIP runtime, OpenCL, rocm-smi, rocminfo,
    # ROCm libraries (rocBLAS, rocFFT, MIOpen, etc.), and profiling tools.
    apt_get install -V -y \
        rocm \
        || error "ROCm stack install failed -- check apt output above"
    success "ROCm stack installed"

    # Add current user to required groups for GPU device access
    info "Adding ${USER} to 'render' and 'video' groups..."
    sudo usermod -a -G render,video "${USER}" \
        || warn "Failed to add user to render/video groups -- add manually: sudo usermod -a -G render,video \$USER"
    success "User groups updated (takes effect on next login)"
}

# ================================================================
# STEP 9 -- ROCm PATH
# ================================================================
configure_rocm_path() {
    section "ROCm PATH Configuration"

    # Set for current session so rocm-smi / rocminfo work in validate_install
    export PATH="/opt/rocm/bin:${PATH}"
    export LD_LIBRARY_PATH="/opt/rocm/lib:${LD_LIBRARY_PATH:-}"

    # Persist across all future logins via /etc/profile.d/
    sudo tee /etc/profile.d/rocm.sh > /dev/null << 'PROFEOF'
# ROCm toolkit PATH -- added by base-install-amd.sh
export PATH="/opt/rocm/bin:${PATH}"
export LD_LIBRARY_PATH="/opt/rocm/lib:${LD_LIBRARY_PATH:-}"
PROFEOF
    sudo chmod 644 /etc/profile.d/rocm.sh

    # HSA_OVERRIDE_GFX_VERSION is NOT needed for R9700 (gfx1201 is natively
    # recognized by ROCm 7.x). Document it anyway for reference.
    info "GPU arch will be auto-detected post-reboot via rocminfo"
    success "ROCm PATH configured -- /opt/rocm/bin added for all users"
}


# ================================================================
# STEP 9.5 -- AI/ML environment: PyTorch arch targeting + pip install guidance
# ================================================================
configure_ml_environment() {
    section "AI/ML Environment Configuration"

    # ── Auto-detect installed GPU arch(es) via rocminfo ───────
    # PYTORCH_ROCM_ARCH must match the architecture(s) of the installed GPU(s).
    # We detect this at install time using rocminfo so the script works for any
    # AMD GPU — R9700 (gfx1201), RX 7900 XTX (gfx1100), MI300X (gfx942), etc.
    #
    # rocminfo requires the amdgpu kernel module to be loaded, so it is only
    # available if the GPU was present and the driver already loaded before this
    # script ran (e.g. a second run after a reboot). On a first-run fresh install
    # the module is not loaded yet, so we fall back to a safe placeholder and
    # print clear instructions for the user to complete after rebooting.

    local detected_arches=""

    if command -v rocminfo &>/dev/null && rocminfo &>/dev/null 2>&1; then
        # Extract unique gfx arch strings, join with semicolons for PyTorch
        detected_arches=$(rocminfo 2>/dev/null \
            | grep -oP 'gfx\d+' \
            | sort -u \
            | tr '\n' ';' \
            | sed 's/;$//')
    fi

    if [[ -n "${detected_arches}" ]]; then
        info "Detected GPU arch(es): ${detected_arches}"
        info "Setting PYTORCH_ROCM_ARCH=${detected_arches}"

        # Write the detected value persistently
        sudo tee -a /etc/profile.d/rocm.sh > /dev/null << MLEOF

# AI/ML environment -- added by base-install-amd.sh
# PyTorch kernel compilation target -- auto-detected from installed GPU(s).
# For mixed-arch multi-GPU nodes, separate arches with semicolons e.g. gfx1100;gfx1201
export PYTORCH_ROCM_ARCH="${detected_arches}"

# HIP visible devices -- unset means all GPUs visible (correct default).
# Override per-job with: HIP_VISIBLE_DEVICES=0,1 python train.py
# export HIP_VISIBLE_DEVICES=0

# HSA_OVERRIDE_GFX_VERSION -- only needed if ROCm does not natively recognize
# your GPU. Uncomment and set to your GPU's gfx version if required.
# export HSA_OVERRIDE_GFX_VERSION=12.0.1
MLEOF
        export PYTORCH_ROCM_ARCH="${detected_arches}"
        success "PYTORCH_ROCM_ARCH=${detected_arches} written to /etc/profile.d/rocm.sh"

    else
        # Driver not loaded yet (normal on first install before reboot).
        # Write a placeholder with clear instructions.
        warn "GPU arch could not be auto-detected (amdgpu module not loaded yet -- normal before first reboot)"
        warn "PYTORCH_ROCM_ARCH placeholder written -- update it after rebooting (see instructions below)"

        sudo tee -a /etc/profile.d/rocm.sh > /dev/null << 'MLEOF'

# AI/ML environment -- added by base-install-amd.sh
# PYTORCH_ROCM_ARCH could not be auto-detected because the amdgpu kernel module
# was not loaded at install time. After rebooting, run:
#   rocminfo | grep -oP 'gfx\d+' | sort -u
# and replace PLACEHOLDER below with the detected arch(es), semicolon-separated.
# Examples: gfx1201 (R9700), gfx1100 (RX 7900 XTX), gfx942 (MI300X)
#           gfx1100;gfx1201 (mixed multi-GPU node)
export PYTORCH_ROCM_ARCH="PLACEHOLDER"

# HIP visible devices -- unset means all GPUs visible (correct default).
# Override per-job with: HIP_VISIBLE_DEVICES=0,1 python train.py
# export HIP_VISIBLE_DEVICES=0

# HSA_OVERRIDE_GFX_VERSION -- only needed if ROCm does not natively recognize
# your GPU. Uncomment and set to your GPU's gfx version if required.
# export HSA_OVERRIDE_GFX_VERSION=12.0.1
MLEOF

        info ""
        info "After rebooting, detect and set your GPU arch:"
        info "  1. rocminfo | grep -oP 'gfx[0-9]+' | sort -u"
        info "  2. sudo sed -i 's/PYTORCH_ROCM_ARCH=.*/PYTORCH_ROCM_ARCH=\"<your_arch>\"/' /etc/profile.d/rocm.sh"
        info "  Or re-run this script after reboot -- it will auto-detect and set the correct value."
        info ""
    fi

    # ── Common ML env vars reference ─────────────────────────
    # The profile.d file above contains PYTORCH_ROCM_ARCH. Additional
    # per-job overrides you may want at runtime:
    #
    #   HIP_VISIBLE_DEVICES=0,1    -- restrict to specific GPUs
    #   ROCR_VISIBLE_DEVICES=0,1   -- HSA-level GPU visibility (lower level)
    #   GPU_MAX_HW_QUEUES=8        -- tune HW queue depth for multi-stream workloads
    #
    # HSA_OVERRIDE_GFX_VERSION: only needed for GPUs not natively recognized by
    # the installed ROCm version. Most current GPUs (gfx900+) are recognized
    # natively by ROCm 7.x. Check: rocminfo | grep "Name:" | grep gfx

    # ── PyTorch install instructions ──────────────────────────
    # The standard 'pip install torch' gives a CUDA build -- it will NOT use
    # the AMD GPU. You must use the ROCm-specific index URL.
    # PyTorch is not installed here because:
    #   1. The index URL changes per ROCm release
    #   2. Most workloads use Docker images or per-project venvs
    #   3. The driver must be loaded (post-reboot) before torch.cuda works

    info "PyTorch for ROCm -- post-reboot install commands:"
    echo ""
    echo "    # 1. Confirm your GPU arch after reboot:"
    echo "    rocminfo | grep -oP 'gfx[0-9]+' | sort -u"
    echo ""
    echo "    # 2a. pip install (system or venv):"
    echo "    pip install torch torchvision torchaudio \\"
    echo "        --index-url https://download.pytorch.org/whl/rocm${ROCM_VERSION}"
    echo ""
    echo "    # 2b. AMD Docker image (recommended for production):"
    echo "    docker pull rocm/pytorch:rocm${ROCM_VERSION}_ubuntu22.04_py3.10_pytorch_release_2.8.0"
    echo ""
    echo "    # 3. Verify (ROCm surfaces AMD GPUs through torch.cuda intentionally):"
    echo '    python3 -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"'
    echo ""
    info "Other ROCm-native tools:"
    echo ""
    echo "    # vLLM -- picks up ROCm automatically when PYTORCH_ROCM_ARCH is set"
    echo "    pip install vllm"
    echo ""
    echo "    # llama.cpp -- HIP backend (replace gfx1201 with your arch)"
    echo '    cmake -B build -DGGML_HIP=ON -DAMDGPU_TARGETS=$(rocminfo | grep -oP '"'"'gfx[0-9]+'"'"' | sort -u | tr '"'"'\n'"'"' '"'"','"'"' | sed '"'"'s/,$//'"'"') ..'
    echo "    cmake --build build --config Release"
    echo ""

    success "AI/ML environment configured"
}

# ================================================================
# STEP 10 -- rocm-bandwidth-test
# ================================================================
install_bandwidth_test() {
    section "rocm-bandwidth-test"
    # rocm-bandwidth-test is included in the ROCm 'rocm' meta-package.
    # Verify it is present and document its location.
    if command -v rocm-bandwidth-test &>/dev/null; then
        success "rocm-bandwidth-test: available at $(command -v rocm-bandwidth-test)"
    elif [[ -x /opt/rocm/bin/rocm-bandwidth-test ]]; then
        success "rocm-bandwidth-test: available at /opt/rocm/bin/rocm-bandwidth-test"
    else
        info "Attempting explicit install of rocm-bandwidth-test..."
        apt_get install -y rocm-bandwidth-test \
            || warn "rocm-bandwidth-test not separately packaged -- included in rocm meta-package (reboot first)"
    fi
}

# ================================================================
# STEP 11 -- Repos (infra clone)
# ================================================================
setup_repos() {
    section "Repos"
    local infra_dir="${HOME}/infra"

    if [[ -d "${infra_dir}" ]]; then
        info "infra repo exists -- pulling latest"
        git -C "${infra_dir}" pull --ff-only || warn "git pull infra failed (local changes?)"
    else
        git clone https://github.com/joeasycompute/infra.git "${infra_dir}" \
            || error "Failed to clone infra repo"
        success "Cloned infra -> ${infra_dir}"
    fi
}

# ================================================================
# STEP 12 -- Validation
# ================================================================
validate_install() {
    section "Post-install Validation"
    local warnings=0

    # rocm-smi (analogous to nvidia-smi)
    if command -v rocm-smi &>/dev/null && rocm-smi &>/dev/null; then
        local gpu_count
        gpu_count=$(rocm-smi --showid 2>/dev/null | grep -c "GPU\[" || echo "?")
        success "rocm-smi: ${gpu_count} GPU(s) detected"
        rocm-smi --showproductname 2>/dev/null | grep -v "^$" | sed 's/^/  /' || true
    else
        warn "rocm-smi not operational (reboot required to load amdgpu kernel module)"; (( warnings++ )) || true
    fi

    # rocminfo -- shows GPU topology and gfx arch
    if command -v rocminfo &>/dev/null; then
        local gfx_arches
        gfx_arches=$(rocminfo 2>/dev/null | grep -oP 'gfx\d+' | sort -u | tr '
' ' ' || echo "unknown")
        success "rocminfo: GPU arch(es) detected: ${gfx_arches}"
    else
        warn "rocminfo not available (reboot required)"; (( warnings++ )) || true
    fi

    # DKMS build status for amdgpu
    if command -v dkms &>/dev/null; then
        local dkms_status
        dkms_status=$(dkms status 2>/dev/null | grep -i amdgpu || true)
        if echo "${dkms_status}" | grep -q "installed"; then
            success "amdgpu DKMS: installed -- ${dkms_status}"
        elif [[ -n "${dkms_status}" ]]; then
            warn "amdgpu DKMS status: ${dkms_status}"
            (( warnings++ )) || true
        else
            warn "amdgpu DKMS: no entries found (may need reboot)"; (( warnings++ )) || true
        fi
    fi

    # Group membership
    if groups "${USER}" 2>/dev/null | grep -qw render; then
        success "User groups: ${USER} is in 'render' group"
    else
        warn "User ${USER} not yet in 'render' group -- effective after next login"
        (( warnings++ )) || true
    fi

    systemctl is-active --quiet chrony \
        && success "chrony: running" \
        || { warn "chrony not running"; (( warnings++ )) || true; }

    [[ -d "${HOME}/infra" ]] \
        && success "infra repo: present" \
        || { warn "infra repo: missing"; (( warnings++ )) || true; }

    echo ""
    (( warnings > 0 )) \
        && warn "${warnings} item(s) pending -- most resolve after reboot" \
        || success "All checks passed -- node is ready"
}

# ================================================================
# STEP 13 -- Reboot prompt (install)
# ================================================================
offer_reboot() {
    echo ""
    echo -e "${BOLD}=======================================${NC}"
    echo -e "${GREEN}${BOLD} Installation complete!${NC}"
    echo -e "  ROCm: ${ROCM_VERSION}  |  Ubuntu: ${UBUNTU_VERSION_ID}"
    echo -e "  Full log: ${LOG_FILE}"
    echo -e "${BOLD}=======================================${NC}"
    echo ""
    echo -e "  Post-reboot validation commands:"
    echo -e "    rocm-smi                   # GPU status"
    echo -e "    rocminfo                   # GPU topology + gfx arch"
    echo -e "    rocm-bandwidth-test -a     # PCIe/inter-GPU bandwidth"
    echo ""

    if ! (command -v rocm-smi &>/dev/null && rocm-smi &>/dev/null 2>/dev/null); then
        if [[ "${NON_INTERACTIVE}" == true ]]; then
            info "Non-interactive -- reboot manually to activate AMDGPU kernel module."
        else
            read -rp "Reboot now to load AMDGPU kernel module? [Y/n]: " do_reboot
            if [[ "${do_reboot,,}" != "n" ]]; then
                info "Rebooting in 5 seconds... (Ctrl+C to cancel)"
                sleep 5
                sudo reboot
            else
                warn "Remember to reboot before running GPU workloads"
            fi
        fi
    else
        success "AMDGPU driver already active -- no reboot needed"
    fi
}

# ================================================================
# UNINSTALL -- Full clean removal, restores post-OS-install state
# ================================================================
uninstall_node() {
    section "Uninstall -- Full AMD GPU Stack Removal"

    echo ""
    echo -e "${BOLD}The following will be removed to restore a clean OS state:${NC}"
    echo "  * amdgpu-dkms kernel driver and all built .ko files"
    echo "  * ROCm stack (rocm meta-package and all dependencies)"
    echo "  * DKMS kernel module entries for amdgpu"
    echo "  * /etc/apt/sources.list.d/amdgpu.list, rocm.list"
    echo "  * /etc/apt/preferences.d/rocm-pin-600"
    echo "  * /etc/apt/keyrings/rocm.gpg"
    echo "  * /etc/profile.d/rocm.sh PATH + ML env vars (PYTORCH_ROCM_ARCH etc.)"
    echo "  * /opt/rocm directory"
    echo "  * GCC update-alternatives entries"
    echo "  * Storage tools: smartmontools, lvm2, mdadm, lsof, ioping"
    echo "  * infra repo (optional)"
    echo "  * Orphaned apt dependencies"
    echo ""

    if [[ "${NON_INTERACTIVE}" == false ]]; then
        read -rp "Proceed with full uninstall? [y/N]: " confirm_uninstall
        [[ "${confirm_uninstall,,}" == "y" ]] || error "Uninstall aborted by user."
    else
        info "Non-interactive mode -- proceeding with uninstall"
    fi

    # -- 1. Purge ROCm and AMDGPU packages -----------------------
    section "Removing ROCm / AMDGPU Packages"
    info "Collecting installed AMD/ROCm packages..."

    local pkgs_to_remove
    pkgs_to_remove=$(dpkg -l 2>/dev/null \
        | grep -P '^ii\s+(amdgpu|rocm|hip-|hsa-|miopen|rocblas|rocfft|roc|comgr|hipsparse|hipblas|rocthrust|rocsparse|rocsolver|rocrand|rocprim|hipcub|hipfft|hiprtc|hipblaslt|smartmontools|ioping)' \
        | awk '{print $2}' | tr '\n' ' ')

    if [[ -n "${pkgs_to_remove}" ]]; then
        echo "  Packages to remove:"
        echo "${pkgs_to_remove}" | tr ' ' '\n' | sed 's/^/    /' | grep -v '^$'
        echo ""
        # shellcheck disable=SC2086
        apt_get purge -y ${pkgs_to_remove} \
            || warn "Some packages failed to purge -- continuing"
        success "AMD/ROCm packages purged"
    else
        info "No AMD/ROCm packages found -- already clean"
    fi

    # -- 2. DKMS explicit cleanup ---------------------------------
    section "Cleaning DKMS Entries"
    if command -v dkms &>/dev/null; then
        local dkms_entries
        dkms_entries=$(dkms status 2>/dev/null | grep -i amdgpu | awk -F'[,: ]+' '{print $1"/"$2}' || true)
        if [[ -n "${dkms_entries}" ]]; then
            while IFS= read -r entry; do
                [[ -z "${entry}" ]] && continue
                info "Removing DKMS entry: ${entry}"
                sudo dkms remove "${entry}" --all 2>/dev/null || true
            done <<< "${dkms_entries}"
            success "DKMS amdgpu entries removed"
        else
            info "No DKMS amdgpu entries found -- already clean"
        fi
    else
        info "dkms not installed -- skipping"
    fi

    # -- 3. Remove built kernel module files ----------------------
    section "Removing Kernel Module Files"
    local ko_count
    ko_count=$(sudo find /lib/modules -name "amdgpu*.ko*" 2>/dev/null | wc -l)
    if (( ko_count > 0 )); then
        info "Found ${ko_count} amdgpu .ko file(s) -- removing..."
        sudo find /lib/modules -name "amdgpu*.ko*" -delete 2>/dev/null || true
        sudo depmod -a
        success "Kernel module files removed and module map rebuilt"
    else
        info "No amdgpu .ko files found -- already clean"
    fi

    # -- 4. Remove /opt/rocm if still present ---------------------
    section "Removing /opt/rocm"
    if [[ -d /opt/rocm ]]; then
        info "Removing /opt/rocm directory..."
        sudo rm -rf /opt/rocm
        success "/opt/rocm removed"
    else
        info "/opt/rocm not found -- already clean"
    fi

    # -- 5. Remove ROCm PATH profile.d entry ----------------------
    section "Removing ROCm PATH Configuration"
    if [[ -f /etc/profile.d/rocm.sh ]]; then
        sudo rm -f /etc/profile.d/rocm.sh
        success "Removed /etc/profile.d/rocm.sh"
    else
        info "/etc/profile.d/rocm.sh not found -- already clean"
    fi
    export PATH=$(echo "${PATH}" | tr ':' '\n' | grep -v rocm | tr '\n' ':' | sed 's/:$//')
    export LD_LIBRARY_PATH=$(echo "${LD_LIBRARY_PATH:-}" | tr ':' '\n' | grep -v rocm | tr '\n' ':' | sed 's/:$//')

    # -- 6. Remove AMD apt sources and keyring --------------------
    section "Removing AMD ROCm Repos & Keyring"
    sudo rm -f /etc/apt/sources.list.d/amdgpu.list \
               /etc/apt/sources.list.d/rocm.list
    sudo rm -f /etc/apt/preferences.d/rocm-pin-600
    sudo rm -f /etc/apt/keyrings/rocm.gpg
    apt_get update -q || warn "apt-get update had warnings (non-fatal)"
    success "AMD ROCm apt sources and keyring removed"

    # -- 7. Remove GCC alternatives -------------------------------
    section "Removing GCC Alternatives"
    for ver in 11 12; do
        [[ -f "/usr/bin/gcc-${ver}" ]] \
            && sudo update-alternatives --remove gcc "/usr/bin/gcc-${ver}" 2>/dev/null || true
        [[ -f "/usr/bin/g++-${ver}" ]] \
            && sudo update-alternatives --remove g++ "/usr/bin/g++-${ver}" 2>/dev/null || true
    done
    success "GCC alternatives cleared"

    # -- 8. Optional: remove repos --------------------------------
    section "Repo Cleanup (Optional)"
    local infra_dir="${HOME}/infra"

    if [[ "${NON_INTERACTIVE}" == false ]]; then
        if [[ -d "${infra_dir}" ]]; then
            read -rp "  Remove ${infra_dir}? [y/N]: " rm_repo
            if [[ "${rm_repo,,}" == "y" ]]; then
                rm -rf "${infra_dir}"
                success "Removed: ${infra_dir}"
            else
                info "Keeping: ${infra_dir}"
            fi
        fi
    else
        info "Non-interactive mode -- keeping repos (remove manually if needed)"
    fi

    # -- 9. apt autoremove + update -------------------------------
    section "Final apt Cleanup"
    apt_get autoremove -y  || warn "autoremove had warnings (non-fatal)"
    apt_get update -q      || warn "apt-get update had warnings (non-fatal)"
    success "apt cleanup complete"

    # -- 10. Final verification -----------------------------------
    section "Uninstall Verification"
    local remaining
    remaining=$(dpkg -l 2>/dev/null \
        | grep -P '^ii\s+(amdgpu|rocm|hip-|hsa-|miopen|rocblas)' \
        | awk '{print $2}' | tr '\n' ' ' || true)

    if [[ -n "${remaining}" ]]; then
        warn "Some packages still present:"
        echo "${remaining}" | tr ' ' '\n' | sed 's/^/    /' | grep -v '^$'
        warn "Run manually if needed: sudo apt purge ${remaining}"
    else
        success "Package check: clean -- no AMD/ROCm packages remaining"
    fi

    local dkms_remaining
    dkms_remaining=$(dkms status 2>/dev/null | grep -i amdgpu || true)
    if [[ -n "${dkms_remaining}" ]]; then
        warn "DKMS entries still present: ${dkms_remaining}"
    else
        success "DKMS check: clean"
    fi

    [[ -f /etc/profile.d/rocm.sh ]] \
        && warn "/etc/profile.d/rocm.sh still exists" \
        || success "PATH check: rocm.sh removed"

    [[ -d /opt/rocm ]] \
        && warn "/opt/rocm still present" \
        || success "/opt/rocm check: removed"

    echo ""
    echo -e "${BOLD}=======================================${NC}"
    echo -e "${GREEN}${BOLD} Uninstall complete!${NC}"
    echo -e "  System restored to clean OS state."
    echo -e "  Reboot required to fully unload amdgpu kernel module."
    echo -e "  Full log: ${LOG_FILE}"
    echo -e "${BOLD}=======================================${NC}"
    echo ""

    if [[ "${NON_INTERACTIVE}" == false ]]; then
        read -rp "Reboot now to complete cleanup? [Y/n]: " do_reboot
        if [[ "${do_reboot,,}" != "n" ]]; then
            info "Rebooting in 5 seconds... (Ctrl+C to cancel)"
            sleep 5
            sudo reboot
        else
            warn "Reboot required before reprovisioning -- run: sudo reboot"
        fi
    else
        info "Non-interactive -- reboot manually: sudo reboot"
    fi
}

# ================================================================
# Main
# ================================================================
main() {
    detect_ubuntu

    if [[ "${UNINSTALL}" == true ]]; then
        uninstall_node
    else
        preflight_checks

        section "Version Selection"
        select_rocm_version
        confirm_install

        install_base_packages
        configure_gcc_alternatives
        install_rocm_repos
        install_amd_stack
        configure_rocm_path
        configure_ml_environment
        install_bandwidth_test
        setup_repos
        validate_install
        offer_reboot
    fi
}

main
