#!/usr/bin/env bash

# ═══════════════════════════════════════════════════════════════
# base-install-amd.sh — AMD GPU Node Base Installation Script
# Target:   Any supported AMD GPU (ROCm-compatible)
# Supports: Ubuntu 22.04 / 24.04 / 26.04 (x86_64)
# Installs: AMDGPU DKMS driver, ROCm stack, rocm-bandwidth-test
# Version:  2.0 (2026-03-15)
# ═══════════════════════════════════════════════════════════════
#
# Notes:
#   * ROCm 10.0.0 / AMDGPU 31.50 is an opt-in current production release.
#   * Ubuntu 22.04 requires kernel 5.15+ (stock LTS kernel is fine).
#   * Ubuntu 24.04 requires kernel 6.8+ (stock noble HWE kernel is fine).
#   * Ubuntu 26.04 is a preview lane that uses AMD's 31.30 preview repos.
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
REPLACE_GPU_STACK=false
GPU_DRIVER_CHANGED=false
AMD_REINSTALL_MARKER="/var/lib/amd-node-install/reinstall-boot-id"
FREEZE_GPU_STACK=false
UNFREEZE_GPU_STACK=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --rocm    <10.0.0|7.13|7.2.4|7.2|7.1>   ROCm version to install
  --yes                      Non-interactive mode, use defaults (7.13 on 26.04; 7.2 otherwise)
  --replace-gpu-stack        Remove installed AMD GPU packages, then stop for reboot before reinstall
  --freeze-gpu-stack         Accepted for orchestration symmetry; AMD uses repo pinning instead of apt holds
  --unfreeze-gpu-stack       Accepted for orchestration symmetry; AMD uses repo pinning instead of apt holds
  --uninstall                Full clean removal -- restores system to post-OS-install state
  -h, --help                 Show this help

Examples:
  $(basename "$0")                   # Interactive install
  $(basename "$0") --rocm 7.13       # 26.04 preview lane
  $(basename "$0") --freeze-gpu-stack # Accepted, but AMD stack control is repo-pin based
  $(basename "$0") --rocm 7.2.4      # Latest verified production release
  $(basename "$0") --rocm 10.0.0     # Current production release (AMDGPU 31.50)
  $(basename "$0") --rocm 7.2        # Explicit ROCm version
  $(basename "$0") --yes             # Non-interactive with defaults
  $(basename "$0") --uninstall       # Interactive uninstall
  $(basename "$0") --uninstall --yes # Non-interactive uninstall
  sudo bash install/amd-stack-pin.sh --status   # Inspect the active ROCm pin
  sudo bash install/amd-stack-pin.sh --reset    # Restore the expected pin file

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
        --replace-gpu-stack) REPLACE_GPU_STACK=true; shift ;;
        --freeze-gpu-stack) FREEZE_GPU_STACK=true; shift ;;
        --unfreeze-gpu-stack) UNFREEZE_GPU_STACK=true; shift ;;
        --uninstall) UNINSTALL=true; shift ;;
        -h|--help)   usage ;;
        *) error "Unknown option: $1. Use --help for usage." ;;
    esac
done

if [[ "${FREEZE_GPU_STACK}" == true ]] && [[ "${UNFREEZE_GPU_STACK}" == true ]]; then
    error "--freeze-gpu-stack and --unfreeze-gpu-stack are mutually exclusive"
fi

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
        "26.04") UBUNTU_CODENAME="resolute" ;;
        *) error "Unsupported Ubuntu version: ${VERSION_ID}. Supported: 22.04, 24.04, 26.04" ;;
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

    # Existing GPU packages are handled by prepare_amd_upgrade after confirmation.

    # Kernel version check -- amdgpu-dkms only builds successfully against
    # kernels that AMD has qualified. For ROCm 7.x:
    #   Ubuntu 22.04: supported kernels are 5.15.x (GA) and 6.8.x (HWE).
    #                 Kernels 6.11+ are NOT yet supported and will fail to build.
    #   Ubuntu 24.04: supported kernel is 6.8.x (GA).
    #                 ROCm 7.2.4 also supports 6.17.x HWE on Ubuntu 24.04.4.
    #   Ubuntu 26.04: preview lane; follow AMD 31.30 release guidance.
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
        # ROCm 7.2.4 additionally qualifies Ubuntu 24.04.4 HWE kernel 6.17.
        # https://rocm.docs.amd.com/projects/install-on-linux/en/docs-7.2.4/reference/system-requirements.html
        if [[ "${ROCM_VERSION}" == "7.2.4" ]] && (( knum == 617 )); then
            success "Kernel ${kver}: supported for ROCm ${ROCM_VERSION} on Ubuntu 24.04.4"
        elif (( knum == 608 )); then
            success "Kernel ${kver}: supported for ROCm ${ROCM_VERSION} on Ubuntu 24.04"
        elif (( knum > 608 )); then
            warn "Kernel ${kver} is outside the qualified kernels for ROCm ${ROCM_VERSION} on Ubuntu 24.04"
            if [[ "${ROCM_VERSION}" == "7.2.4" ]]; then
                warn "Supported kernels: 6.8.x (GA), 6.17.x (HWE on Ubuntu 24.04.4)"
            else
                warn "amdgpu-dkms WILL LIKELY FAIL TO BUILD. Supported kernel: 6.8.x (GA)"
            fi
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
    elif [[ "${UBUNTU_VERSION_ID}" == "26.04" ]]; then
        warn "Ubuntu 26.04 is an experimental ROCm 7.13 preview lane; follow AMD 31.30 preview kernel guidance if DKMS fails."
        (( warnings++ )) || true
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
    if [[ "${UBUNTU_VERSION_ID}" == "26.04" ]]; then
        if [[ -n "${ROCM_VERSION}" ]]; then
            case "${ROCM_VERSION}" in
                "7.13") success "ROCm version (--rocm arg): ${ROCM_VERSION} (preview)"; return ;;
                *) error "Invalid --rocm for Ubuntu 26.04: ${ROCM_VERSION}. Valid: 7.13" ;;
            esac
        fi
        if [[ "${NON_INTERACTIVE}" == true ]]; then
            ROCM_VERSION="7.13"
            success "ROCm version (default preview): ${ROCM_VERSION}"
            return
        fi
        echo ""
        echo -e "${BOLD}Select ROCm Version (Ubuntu 26.04 preview lane):${NC}"
        echo "  1) 7.13 -- preview release [default]"
        echo ""
        read -rp "Enter choice [1, default=1]: " rocm_choice
        case "${rocm_choice}" in
            "") ROCM_VERSION="7.13" ;;
            1) ROCM_VERSION="7.13" ;;
            *) ROCM_VERSION="7.13" ;;
        esac
        success "ROCm version: ${ROCM_VERSION} (preview)"
        return
    fi

    if [[ -n "${ROCM_VERSION}" ]]; then
        case "${ROCM_VERSION}" in
            "10.0.0"|"7.2.4"|"7.2"|"7.1") success "ROCm version (--rocm arg): ${ROCM_VERSION}"; return ;;
            "7.13") error "ROCm 7.13 is only supported on Ubuntu 26.04 in the preview lane" ;;
            *) error "Invalid --rocm: ${ROCM_VERSION}. Valid: 7.1, 7.2, 7.2.4, 10.0.0" ;;
        esac
    fi
    if [[ "${NON_INTERACTIVE}" == true ]]; then
        ROCM_VERSION="7.2"; success "ROCm version (default): ${ROCM_VERSION}"; return
    fi
    echo ""
    echo -e "${BOLD}Select ROCm Version:${NC}"
    echo "  1) 7.2  -- production release [default]"
    echo "  2) 7.1  -- previous stable"
    echo "  3) 7.2.4 -- latest verified production release"
    echo "  4) 10.0.0 -- current production release (AMDGPU 31.50)"
    echo ""
    read -rp "Enter choice [1-4, default=1]: " rocm_choice
    case "${rocm_choice}" in
        2) ROCM_VERSION="7.1" ;;
        3) ROCM_VERSION="7.2.4" ;;
        4) ROCM_VERSION="10.0.0" ;;
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
    if [[ "${UBUNTU_VERSION_ID}" == "26.04" ]]; then
        echo -e "  ROCm version:   ${ROCM_VERSION} (preview)"
    else
        echo -e "  ROCm version:   ${ROCM_VERSION}"
    fi
    echo -e "  GPU target:     Any ROCm-compatible AMD GPU"
    echo -e "  PyTorch arch:   auto-detected post-reboot (Step 9.5)"
    echo -e "  Log file:       ${LOG_FILE}"
    if [[ "${FREEZE_GPU_STACK}" == true || "${UNFREEZE_GPU_STACK}" == true ]]; then
        echo -e "  GPU stack:     AMD uses repo pinning; freeze/unfreeze flags are informational here"
        echo -e "  Pin helper:    install/amd-stack-pin.sh --status | --reset"
    fi
    echo -e "${BOLD}=======================================${NC}"
    echo ""
    if [[ "${NON_INTERACTIVE}" == false ]]; then
        read -rp "Proceed with installation? [Y/n]: " proceed
        [[ "${proceed,,}" == "n" ]] && error "Aborted by user."
        info "Starting installation..."
    else
        info "Non-interactive mode -- starting installation..."
    fi

    if [[ "${FREEZE_GPU_STACK}" == true || "${UNFREEZE_GPU_STACK}" == true ]]; then
        warn "AMD nodes already use repo pinning (`/etc/apt/preferences.d/rocm-pin-600`) to control package selection."
        warn "The freeze/unfreeze flags are accepted for orchestration symmetry, but no apt-mark hold/unhold action is performed on AMD."
        warn "Use install/amd-stack-pin.sh --status to inspect the current pin or --reset to restore it."
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
        software-properties-common apt-transport-https ca-certificates curl gnupg wget debconf-utils \
        || error "Bootstrap package install failed"

    # Kernel headers and modules-extra -- both required for amdgpu-dkms
    local kver; kver=$(uname -r)
    info "Installing kernel headers for: ${kver}"
    apt_get install -y \
        "linux-headers-${kver}" \
        linux-headers-generic \
        "linux-modules-extra-${kver}" \
        || warn "Kernel headers install had warnings -- DKMS build may fail"

    if command -v debconf-set-selections &>/dev/null; then
        printf 'iperf3 iperf3/start_daemon boolean true\n' | sudo debconf-set-selections
        success "Preseeded iperf3 to start as a daemon automatically"
    else
        warn "debconf-set-selections not found -- iperf3 may prompt during install"
    fi

    info "Installing base packages..."
    sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout="${APT_LOCK_TIMEOUT}" install -y \
        git cmake build-essential dkms alsa-utils \
        gcc-11 g++-11 gcc-12 g++-12 lsb-release \
        ipmitool jq fzf ripgrep fd-find bat \
        pciutils usbutils iproute2 util-linux dmidecode lshw \
        coreutils chrony nvme-cli bpytop nvtop mokutil \
        python3 python3-pip python3-venv \
        python3-setuptools python3-wheel \
        smartmontools stress-ng fio lm-sensors ethtool iperf3 \
        rsync xorriso squashfs-tools grub-common grub-pc-bin grub-efi-amd64-bin \
        lvm2 mdadm lsof ioping \
        || error "Base package install failed"

    sudo systemctl enable --now chrony \
        || warn "Failed to enable chrony"
    success "Base packages installed"
}

configure_pcie_aspm() {
    section "PCIe / NVMe Boot Policy"

    local grub_d="/etc/default/grub.d/99-infra-pcie-aspm.cfg"

    sudo install -d -m 0755 /etc/default/grub.d
    sudo tee "${grub_d}" >/dev/null <<'EOF'
# PCIe / storage boot policy — added by amd-base-install.sh
case " ${GRUB_CMDLINE_LINUX_DEFAULT:-} " in
    *" pcie_aspm=off "*) ;;
    *) GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:+${GRUB_CMDLINE_LINUX_DEFAULT} }pcie_aspm=off" ;;
esac
case " ${GRUB_CMDLINE_LINUX_DEFAULT:-} " in
    *" pci=noaer "*) ;;
    *) GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:+${GRUB_CMDLINE_LINUX_DEFAULT} }pci=noaer" ;;
esac
case " ${GRUB_CMDLINE_LINUX_DEFAULT:-} " in
    *" pci=realloc=on "*) ;;
    *) GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:+${GRUB_CMDLINE_LINUX_DEFAULT} }pci=realloc=on" ;;
esac
case " ${GRUB_CMDLINE_LINUX_DEFAULT:-} " in
    *" pcie_aspm.policy=performance "*) ;;
    *) GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:+${GRUB_CMDLINE_LINUX_DEFAULT} }pcie_aspm.policy=performance" ;;
esac
case " ${GRUB_CMDLINE_LINUX_DEFAULT:-} " in
    *" nvme_core.default_ps_max_latency_us=0 "*) ;;
    *) GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:+${GRUB_CMDLINE_LINUX_DEFAULT} }nvme_core.default_ps_max_latency_us=0" ;;
esac
EOF
    sudo chown root:root "${grub_d}"
    sudo chmod 0644 "${grub_d}"

    if command -v update-grub &>/dev/null; then
        sudo update-grub >/dev/null \
            && success "Applied PCIe / NVMe boot policy from ${grub_d}" \
            || warn "update-grub reported warnings while applying ${grub_d}"
    else
        warn "update-grub not found — reboot will not pick up ${grub_d} until grub config is regenerated"
    fi
}

remove_pcie_aspm() {
    section "Removing PCIe / NVMe Boot Policy"

    local grub_d="/etc/default/grub.d/99-infra-pcie-aspm.cfg"

    if [[ -f "${grub_d}" ]]; then
        sudo rm -f "${grub_d}"
        success "Removed ${grub_d}"
        if command -v update-grub &>/dev/null; then
            sudo update-grub >/dev/null \
                || warn "update-grub reported warnings after removing ${grub_d}"
        fi
    else
        info "${grub_d} not present -- skipping"
    fi
}

install_yq_tool() {
    section "yq Installation"

    if command -v yq &>/dev/null; then
        success "yq already installed: $(yq --version 2>/dev/null || echo unknown)"
        return
    fi

    local binary tmp_file
    case "$(uname -m)" in
        x86_64) binary="yq_linux_amd64" ;;
        aarch64|arm64) binary="yq_linux_arm64" ;;
        *)
            error "Unsupported architecture for yq binary install: $(uname -m)"
            ;;
    esac

    tmp_file="$(mktemp /tmp/yq.XXXXXX)" || error "Unable to create temporary file for yq download"
    trap 'rm -f "$tmp_file"' RETURN

    info "Downloading yq from GitHub releases (${binary})..."
    curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/${binary}" -o "$tmp_file" \
        || error "Failed to download yq binary"

    sudo install -m 0755 "$tmp_file" /usr/local/bin/yq \
        || error "Failed to install yq to /usr/local/bin"
    rm -f "$tmp_file"
    trap - RETURN

    command -v yq &>/dev/null \
        || error "yq install completed but command is still not on PATH"
    success "yq installed: $(yq --version 2>/dev/null || echo unknown)"
}

install_cli_tool_compat_symlinks() {
    section "CLI Tool Compatibility Symlinks"

    if command -v fdfind &>/dev/null; then
        if command -v fd &>/dev/null; then
            info "fd already available: $(command -v fd)"
        else
            info "Creating fd compatibility symlink to fdfind"
            sudo install -d /usr/local/bin
            sudo ln -sf "$(command -v fdfind)" /usr/local/bin/fd
        fi
    fi

    if command -v batcat &>/dev/null; then
        if command -v bat &>/dev/null; then
            info "bat already available: $(command -v bat)"
        else
            info "Creating bat compatibility symlink to batcat"
            sudo install -d /usr/local/bin
            sudo ln -sf "$(command -v batcat)" /usr/local/bin/bat
        fi
    fi
}

# ================================================================
# STEP 5.5 -- Python tooling
# ================================================================
install_python_tooling() {
    section "Python Tooling"

    if command -v uv &>/dev/null; then
        success "uv already installed: $(uv --version)"
        return
    fi

    info "Installing uv to /usr/local/bin via Astral installer..."
    curl -LsSf https://astral.sh/uv/install.sh \
        | sudo env UV_INSTALL_DIR="/usr/local/bin" UV_NO_MODIFY_PATH=1 sh \
        || error "uv install failed"

    command -v uv &>/dev/null \
        || error "uv install completed but uv is not on PATH"
    success "uv installed: $(uv --version)"
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
clear_amd_repo_files() {
    # Remove any stale repo files from a previous (possibly failed) run.
    # This prevents apt from using an old/wrong URL on the apt-get update below.
    if [[ -f /etc/apt/sources.list.d/amdgpu.list ]] || [[ -f /etc/apt/sources.list.d/rocm.list ]]; then
        info "Removing stale AMD repo files from previous run..."
        sudo rm -f /etc/apt/sources.list.d/amdgpu.list \
                   /etc/apt/sources.list.d/rocm.list \
                   /etc/apt/preferences.d/rocm-pin-600
        success "Stale repo files removed"
    fi
}

install_rocm_repos() {
    section "AMD ROCm Repository & Signing Key"
    clear_amd_repo_files

    # The amdgpu driver repo uses a build number (e.g. 30.30), NOT the ROCm
    # version string. The ROCm apt repo DOES use the ROCm version string.
    # Mapping:
    #   ROCm 7.2.4 -> amdgpu 30.30.4
    #   ROCm 7.2  -> amdgpu 30.30
    #   ROCm 7.1  -> amdgpu 30.20.1
    #   ROCm 7.13 -> amdgpu 31.30 (preview lane / Ubuntu 26.04)
    # Source: https://repo.radeon.com/amdgpu/ (directory listing)
    local AMDGPU_BUILD_VERSION
    case "${ROCM_VERSION}" in
        "10.0.0") AMDGPU_BUILD_VERSION="31.50" ;;
        "7.2.4") AMDGPU_BUILD_VERSION="30.30.4" ;;
        "7.2") AMDGPU_BUILD_VERSION="30.30" ;;
        "7.1") AMDGPU_BUILD_VERSION="30.20.1" ;;
        "7.13") AMDGPU_BUILD_VERSION="31.30" ;;
        *)     error "No known amdgpu build version for ROCm ${ROCM_VERSION}" ;;
    esac
    info "ROCm ${ROCM_VERSION} -> AMDGPU driver build: ${AMDGPU_BUILD_VERSION}"

    # GPG keyring directory (recommended location per AMD docs)
    sudo mkdir -p --mode=0755 /etc/apt/keyrings

    local DRIVER_KEYRING="/etc/apt/keyrings/rocm.gpg"
    local ROCM_KEYRING="/etc/apt/keyrings/rocm.gpg"
    local ROCM_REPO_URL=""
    local ROCM_KEY_URL="https://repo.radeon.com/rocm/rocm.gpg.key"
    local ROCM_DRIVER_REPO_URL=""

    if [[ "${ROCM_VERSION}" == "10.0.0" ]]; then
        DRIVER_KEYRING="/etc/apt/keyrings/rocm.gpg"
        ROCM_KEYRING="/etc/apt/keyrings/amdrocm.gpg"
        ROCM_KEY_URL="https://stable.repo.amd.com/rocm/gpg/packages.gpg"
        ROCM_REPO_URL="deb [arch=amd64 signed-by=${ROCM_KEYRING}] https://stable.repo.amd.com/rocm/core/packages/ubuntu${UBUNTU_VERSION_ID/./} stable main"
        ROCM_DRIVER_REPO_URL="deb [arch=amd64 signed-by=${DRIVER_KEYRING}] https://repo.radeon.com/amdgpu/${AMDGPU_BUILD_VERSION}/ubuntu ${UBUNTU_CODENAME} main"
    elif [[ "${UBUNTU_VERSION_ID}" == "26.04" ]]; then
        DRIVER_KEYRING="/etc/apt/keyrings/amdrocm.gpg"
        ROCM_KEYRING="/etc/apt/keyrings/amdrocm.gpg"
        ROCM_KEY_URL="https://repo.amd.com/rocm/packages/gpg/rocm.gpg"
        ROCM_REPO_URL="deb [arch=amd64 signed-by=${ROCM_KEYRING}] https://repo.amd.com/rocm/packages-multi-arch/ubuntu2604 stable main"
        ROCM_DRIVER_REPO_URL="deb [arch=amd64 signed-by=${DRIVER_KEYRING}] https://repo.radeon.com/amdgpu/${AMDGPU_BUILD_VERSION}/ubuntu ${UBUNTU_CODENAME} main"
    else
        ROCM_REPO_URL=""
        ROCM_DRIVER_REPO_URL="deb [arch=amd64 signed-by=${DRIVER_KEYRING}] https://repo.radeon.com/amdgpu/${AMDGPU_BUILD_VERSION}/ubuntu ${UBUNTU_CODENAME} main"
    fi

    info "Downloading AMD ROCm GPG key..."
    wget -q -O - "${ROCM_KEY_URL}" \
        | gpg --dearmor \
        | sudo tee "${ROCM_KEYRING}" > /dev/null \
        || error "Failed to install AMD ROCm GPG key"
    success "GPG key installed -> ${ROCM_KEYRING}"

    # The AMDGPU driver repository uses the repo.radeon.com signing key;
    # ROCm 10 uses the separate stable.repo.amd.com key above.
    if [[ "${ROCM_VERSION}" == "10.0.0" ]]; then
        info "Downloading AMDGPU driver repository GPG key..."
        local key_tmp_dir
        key_tmp_dir=$(mktemp -d)
        if ! GNUPGHOME="${key_tmp_dir}" gpg --batch --keyserver hkps://keyserver.ubuntu.com \
            --recv-keys 9386B48A1A693C5C >/dev/null 2>&1; then
            rm -rf "${key_tmp_dir}"
            error "Failed to retrieve AMDGPU repository GPG key 9386B48A1A693C5C"
        fi
        if ! GNUPGHOME="${key_tmp_dir}" gpg --batch --export 9386B48A1A693C5C \
            | sudo tee "${DRIVER_KEYRING}" > /dev/null; then
            rm -rf "${key_tmp_dir}"
            error "Failed to install AMDGPU repository GPG key"
        fi
        rm -rf "${key_tmp_dir}"
        success "GPG key installed -> ${DRIVER_KEYRING}"
    fi

    # AMDGPU driver repo (provides amdgpu-dkms)
    # NOTE: this URL uses the build number (e.g. 30.30), NOT the ROCm version.
    info "Adding AMDGPU driver repository (build ${AMDGPU_BUILD_VERSION})..."
    echo "${ROCM_DRIVER_REPO_URL}" \
        | sudo tee /etc/apt/sources.list.d/amdgpu.list > /dev/null

    # ROCm software repo
    # NOTE: the 26.04 preview lane uses repo.amd.com; 22.04 / 24.04 retain the
    # existing repo.radeon.com package layout for the current production stack.
    if [[ "${ROCM_VERSION}" == "10.0.0" ]]; then
        info "Adding ROCm 10.0.0 repository..."
        echo "${ROCM_REPO_URL}" | sudo tee /etc/apt/sources.list.d/rocm.list > /dev/null
        printf "Package: *\nPin: release o=stable.repo.amd.com\nPin-Priority: 600\n" | sudo tee /etc/apt/preferences.d/rocm-pin-600 > /dev/null
    elif [[ "${UBUNTU_VERSION_ID}" == "26.04" ]]; then
        info "Adding ROCm software repository (${ROCM_VERSION} preview)..."
        echo "${ROCM_REPO_URL}" \
            | sudo tee /etc/apt/sources.list.d/rocm.list > /dev/null
        printf "Package: *\nPin: release o=repo.amd.com\nPin-Priority: 600\n" \
            | sudo tee /etc/apt/preferences.d/rocm-pin-600 > /dev/null
    else
        info "Adding ROCm software repository (${ROCM_VERSION})..."
        printf "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/%s %s main\ndeb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/graphics/%s/ubuntu %s main\n" \
            "${ROCM_VERSION}" "${UBUNTU_CODENAME}" "${ROCM_VERSION}" "${UBUNTU_CODENAME}" \
            | sudo tee /etc/apt/sources.list.d/rocm.list > /dev/null
        printf "Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600\n" \
            | sudo tee /etc/apt/preferences.d/rocm-pin-600 > /dev/null
    fi

    apt_get update -q || error "apt-get update after ROCm repo setup failed"
    success "AMD ROCm repositories configured (ROCm ${ROCM_VERSION} / amdgpu ${AMDGPU_BUILD_VERSION}, ${UBUNTU_CODENAME})"
}

# ================================================================
# STEP 8 -- AMDGPU DKMS driver + ROCm stack
# ================================================================
amd_installed_packages() {
    dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package} ${Version}\n' 2>/dev/null \
        | awk '$1 ~ /^[ih]i/ && $2 ~ /^(amdgpu|amdrocm|rocm|hip-|hsa-|miopen|rocblas|rocfft|rocprim|rocrand|rocsolver|rocsparse|rocthrust|comgr|hipblas|hipcub|hipfft|hiprtc|hipsparse)/ { print }'
}

amd_driver_version() {
    dpkg-query -W -f='${Status} ${Version}\n' amdgpu-dkms 2>/dev/null \
        | awk '$1 == "install" && $3 == "installed" { print $4 }'
}

prepare_amd_upgrade() {
    local installed migration=false answer boot_id old_boot pkg held held_pkg
    local packages=()
    if [[ -f "${AMD_REINSTALL_MARKER}" ]]; then
        boot_id=$(cat /proc/sys/kernel/random/boot_id) || error "Cannot determine current boot ID"
        old_boot=$(cat "${AMD_REINSTALL_MARKER}") || error "Cannot read AMD reinstall state"
        [[ "${boot_id}" != "${old_boot}" ]] \
            || error "GPU cleanup already completed on this boot. Run sudo reboot, then rerun this installer with --rocm ${ROCM_VERSION}."
        sudo rm -f "${AMD_REINSTALL_MARKER}" || error "Cannot clear AMD reinstall state"
        info "Reboot after GPU cleanup confirmed; continuing installation."
    fi
    installed=$(amd_installed_packages) || error "Cannot inspect installed AMD packages"
    if [[ -z "${installed}" ]]; then
        if command -v rocminfo >/dev/null 2>&1; then
            error "ROCm tools exist without installed AMD packages. Remove the previous runfile/manual installation with its original uninstaller, reboot, then rerun with --rocm ${ROCM_VERSION}."
        fi
        info "No installed AMD GPU packages; fresh installation."
        return
    fi
    info "Installed AMD GPU packages (name / version):"
    printf '%s\n' "${installed}"
    info "Requested ROCm: ${ROCM_VERSION}"
    held=$(apt-mark showhold) || error "Cannot inspect APT package holds"
    while read -r held_pkg; do
        [[ -n "${held_pkg}" ]] || continue
        if printf '%s\n' "${installed}" | awk -v name="${held_pkg}" '$2 == name { found=1 } END { exit !found }'; then
            error "AMD package ${held_pkg} is held. Review and unhold it explicitly before updating or replacing the GPU stack."
        fi
    done <<< "${held}"
    # AMD's new amdrocm package layout must not be mixed with legacy ROCm.
    if [[ "${ROCM_VERSION}" == "10.0.0" ]]; then
        if printf '%s\n' "${installed}" | awk '$2 ~ /^(rocm|hip-|hsa-|amdrocm.*7\.)/ { found=1 } END { exit !found }'; then migration=true; fi
    elif printf '%s\n' "${installed}" | awk '$2 ~ /^amdrocm/ { found=1 } END { exit !found }'; then
        # The existing preview lane can be updated in place within 7.13.
        if [[ "${ROCM_VERSION}" != "7.13" ]] || printf '%s\n' "${installed}" | awk '$2 ~ /^amdrocm/ && $3 !~ /^7\.13[.-]/ { found=1 } END { exit !found }'; then migration=true; fi
    fi
    if [[ "${migration}" == true && "${REPLACE_GPU_STACK}" == false ]]; then
        warn "Changing ROCm package families requires GPU package removal, a reboot, and a second installer run."
        if [[ "${NON_INTERACTIVE}" == true ]]; then
            error "Rerun with --replace-gpu-stack to authorize GPU package removal; --yes alone does not authorize migration cleanup."
        fi
        read -rp "Remove the listed GPU packages now and stop for reboot? [y/N]: " answer
        [[ "${answer,,}" == y ]] || error "Upgrade cancelled; installed packages retained."
        REPLACE_GPU_STACK=true
    fi
    if [[ "${REPLACE_GPU_STACK}" == true ]]; then
        while read -r pkg; do packages+=("${pkg}"); done < <(printf '%s\n' "${installed}" | awk '{ print $2 }')
        warn "Stop GPU jobs and containers before continuing. This removes only the listed GPU packages; APT may also remove dependent packages."
        apt_get --simulate purge "${packages[@]}" || error "GPU package removal simulation failed"
        if [[ "${NON_INTERACTIVE}" == false ]]; then
            read -rp "Apply this removal plan, then stop for reboot before reinstalling? [y/N]: " answer
            [[ "${answer,,}" == y ]] || error "Upgrade cancelled."
        fi
        boot_id=$(cat /proc/sys/kernel/random/boot_id) || error "Cannot determine boot ID"
        sudo mkdir -p "$(dirname "${AMD_REINSTALL_MARKER}")" || error "Cannot create reinstall state directory"
        apt_get purge -y "${packages[@]}" || error "GPU cleanup failed; fix package errors before retrying."
        printf '%s\n' "${boot_id}" | sudo tee "${AMD_REINSTALL_MARKER}" >/dev/null || error "Cannot save reboot requirement"
        warn "GPU cleanup complete. Reboot REQUIRED before reinstalling; installation stops here."
        printf 'Run: sudo reboot\nAfter reconnecting, run: sudo bash %q --rocm %q\n' "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" "${ROCM_VERSION}"
        exit 0
    fi
    info "Updating the selected GPU stack in place. A changed kernel driver requires reboot even if rocm-smi still works."
}

amd_reboot_required() {
    [[ "${GPU_DRIVER_CHANGED}" == true ]] && return 0
    local loaded disk
    loaded=$(cat /sys/module/amdgpu/version 2>/dev/null) || return 0
    disk=$(modinfo -F version amdgpu 2>/dev/null) || return 0
    [[ -z "${loaded}" || "${loaded}" != "${disk}" ]]
}

install_amd_stack() {
    section "AMDGPU Driver + ROCm Stack"
    local driver_before driver_after
    driver_before=$(amd_driver_version)
    local rocm_pkg="rocm"
    if [[ "${ROCM_VERSION}" == "10.0.0" ]]; then
        rocm_pkg="amdrocm10.0"
    elif [[ "${UBUNTU_VERSION_ID}" == "26.04" ]]; then
        rocm_pkg="amdrocm7.13"
    fi
    apt_get --simulate install amdgpu-dkms "${rocm_pkg}" \
        || error "APT cannot resolve the GPU stack update. Review conflicts before changing packages."
    info "Installing amdgpu-dkms kernel driver..."
    apt_get install -V -y \
        amdgpu-dkms \
        || error "amdgpu-dkms install failed -- check kernel headers and DKMS"
    success "amdgpu-dkms installed"
    driver_after=$(amd_driver_version)
    [[ "${driver_before}" == "${driver_after}" ]] || GPU_DRIVER_CHANGED=true

    info "Installing ROCm ${ROCM_VERSION} stack..."
    # 'rocm' / 'amdrocm7.13' pulls in: HIP runtime, OpenCL, rocm-smi, rocminfo,
    # ROCm libraries (rocBLAS, rocFFT, MIOpen, etc.), and profiling tools.
    apt_get install -V -y \
        "${rocm_pkg}" \
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
    local rocm_root="/opt/rocm"
    if [[ "${ROCM_VERSION}" == "10.0.0" ]]; then
        rocm_root="/opt/rocm/core-10.0"
    fi
    export PATH="${rocm_root}/bin:${PATH}"
    export LD_LIBRARY_PATH="${rocm_root}/lib:${LD_LIBRARY_PATH:-}"

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
    echo "    docker pull rocm/pytorch:rocm${ROCM_VERSION}_ubuntu${UBUNTU_VERSION_ID}_py3.10_pytorch_release_2.8.0"
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
    echo -e "  PCIe boot policy: managed (pcie_aspm=off, pci=noaer, pci=realloc=on, pcie_aspm.policy=performance, nvme_core.default_ps_max_latency_us=0)"
    echo -e "  Full log: ${LOG_FILE}"
    echo -e "${BOLD}=======================================${NC}"
    echo ""
    echo -e "  Post-reboot validation commands:"
    echo -e "    rocm-smi                   # GPU status"
    echo -e "    rocminfo                   # GPU topology + gfx arch"
    echo -e "    rocm-bandwidth-test -a     # PCIe/inter-GPU bandwidth"
    echo ""

    if amd_reboot_required; then
        warn "Reboot required to activate the installed AMDGPU driver. After reboot, rerun this installer with --rocm ${ROCM_VERSION} if validation or ML architecture setup was deferred."
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
    echo "  * ROCm stack (rocm / amdrocm meta-package and all dependencies)"
    echo "  * DKMS kernel module entries for amdgpu"
    echo "  * /etc/apt/sources.list.d/amdgpu.list, rocm.list"
    echo "  * /etc/apt/preferences.d/rocm-pin-600"
    echo "  * /etc/apt/keyrings/rocm.gpg, /etc/apt/keyrings/amdrocm.gpg"
    echo "  * /etc/profile.d/rocm.sh PATH + ML env vars (PYTORCH_ROCM_ARCH etc.)"
    echo "  * /opt/rocm directory"
    echo "  * PCIe / NVMe boot policy (pcie_aspm=off, pci=noaer, pci=realloc=on, pcie_aspm.policy=performance, nvme_core.default_ps_max_latency_us=0)"
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
        | grep -P '^ii\s+(amdgpu|amdgpu-install|amdrocm|rocm|hip-|hsa-|miopen|rocblas|rocfft|roc|comgr|hipsparse|hipblas|rocthrust|rocsparse|rocsolver|rocrand|rocprim|hipcub|hipfft|hiprtc|hipblaslt|smartmontools|ioping)' \
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

    # -- 5.5. Remove PCIe / NVMe boot policy ----------------------
    remove_pcie_aspm

    # -- 6. Remove AMD apt sources and keyring --------------------
    section "Removing AMD ROCm Repos & Keyring"
    sudo rm -f /etc/apt/sources.list.d/amdgpu.list \
               /etc/apt/sources.list.d/rocm.list
    sudo rm -f /etc/apt/preferences.d/rocm-pin-600
    sudo rm -f /etc/apt/keyrings/rocm.gpg \
               /etc/apt/keyrings/amdrocm.gpg
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

    # -- 8. Remove uv standalone binary ---------------------------
    section "Removing uv"
    if command -v uv &>/dev/null || [[ -x /usr/local/bin/uv ]]; then
        sudo rm -f /usr/local/bin/uv
        hash -r 2>/dev/null || true
        success "uv removed from /usr/local/bin"
    else
        info "uv not present -- already clean"
    fi

    # -- 8.5. Remove yq standalone binary -------------------------
    section "Removing yq"
    if command -v yq &>/dev/null || [[ -x /usr/local/bin/yq ]]; then
        sudo rm -f /usr/local/bin/yq
        hash -r 2>/dev/null || true
        success "yq removed from /usr/local/bin"
    else
        info "yq not present -- already clean"
    fi

    # -- 9. Optional: remove repos --------------------------------
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

    # -- 10. apt autoremove + update ------------------------------
    section "Final apt Cleanup"
    apt_get autoremove -y  || warn "autoremove had warnings (non-fatal)"
    apt_get update -q      || warn "apt-get update had warnings (non-fatal)"
    success "apt cleanup complete"

    # -- 11. Final verification -----------------------------------
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

    [[ -x /usr/local/bin/uv ]] \
        && warn "/usr/local/bin/uv still exists" \
        || success "uv check: removed"

    [[ -x /usr/local/bin/yq ]] \
        && warn "/usr/local/bin/yq still exists" \
        || success "yq check: removed"

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
# Disable SSH password authentication only after installing the login user's key.
finalize_ssh_access() {
    section "Final Step -- SSH Key Authentication"
    local target_user target_home target_group ssh_dir keys key_tmp config_tmp backup effective peer
    local config="/etc/ssh/sshd_config"
    local access_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG3WsgbyzKCqXrdZJyWiRA/SHPC1nGAfs6bvnj7K/PZ9 ezc@local'
    target_user="${SUDO_USER:-${USER:-}}"
    [[ -n "${target_user}" && "${target_user}" != root ]] \
        || error "SSH password login was not changed. Run the installer via sudo from the intended non-root login account."
    target_home=$(getent passwd "${target_user}" | awk -F: '{print $6}')
    [[ "${target_home}" == /* && -d "${target_home}" ]] || error "Cannot resolve the SSH user's home directory"
    target_group=$(id -gn "${target_user}") || error "Cannot resolve the SSH user's group"
    [[ -x /usr/sbin/sshd && -f "${config}" ]] || error "OpenSSH server is required before disabling password login"
    sudo /usr/sbin/sshd -t || error "Existing SSH configuration is invalid; password login was not changed"
    ssh_dir="${target_home}/.ssh"
    keys="${ssh_dir}/authorized_keys"
    key_tmp=$(mktemp) || error "Cannot create key staging file"
    if [[ -f "${keys}" ]]; then
        sudo cat "${keys}" > "${key_tmp}" || { rm -f "${key_tmp}"; error "Cannot read authorized_keys"; }
    fi
    if ! grep -Fxq "${access_key}" "${key_tmp}"; then
        printf '\n%s\n' "${access_key}" >> "${key_tmp}"
    fi
    sudo install -d -m 0700 -o "${target_user}" -g "${target_group}" "${ssh_dir}" \
        && sudo install -m 0600 -o "${target_user}" -g "${target_group}" "${key_tmp}" "${keys}" \
        || { rm -f "${key_tmp}"; error "Cannot install SSH authorized key"; }
    rm -f "${key_tmp}"
    sudo -u "${target_user}" ssh-keygen -l -f "${keys}" >/dev/null \
        || error "No readable valid SSH key; password login was not changed"

    config_tmp=$(mktemp) || error "Cannot stage SSH configuration"
    backup=$(mktemp) || { rm -f "${config_tmp}"; error "Cannot back up SSH configuration"; }
    sudo cat "${config}" > "${backup}" || { rm -f "${config_tmp}" "${backup}"; error "Cannot back up SSH configuration"; }
    # OpenSSH uses the first global value. Put this before distro/cloud-init
    # Includes, and remove only our own block on subsequent installer runs.
    {
        printf '%s\n' '# BEGIN infra SSH key-only login' \
            'PubkeyAuthentication yes' 'PasswordAuthentication no' \
            'KbdInteractiveAuthentication no' '# END infra SSH key-only login'
        sudo awk '
            /^# BEGIN infra SSH key-only login$/ { skip=1; next }
            /^# END infra SSH key-only login$/ { skip=0; next }
            !skip { print }
        ' "${config}"
    } > "${config_tmp}"
    peer="${SSH_CONNECTION:-}"
    peer="${peer%% *}"
    peer="${peer:-127.0.0.1}"
    if ! sudo /usr/sbin/sshd -t -f "${config_tmp}"; then
        rm -f "${config_tmp}" "${backup}"
        error "Proposed SSH configuration is invalid; original retained"
    fi
    effective=$(sudo /usr/sbin/sshd -T -f "${config_tmp}" -C "user=${target_user},host=${peer},addr=${peer}") || {
        rm -f "${config_tmp}" "${backup}"; error "Cannot verify effective SSH configuration";
    }
    if ! printf '%s\n' "${effective}" | grep -Fxq 'passwordauthentication no' \
        || ! printf '%s\n' "${effective}" | grep -Fxq 'kbdinteractiveauthentication no' \
        || ! printf '%s\n' "${effective}" | grep -Fxq 'pubkeyauthentication yes' \
        || ! printf '%s\n' "${effective}" | grep -Eq '^authenticationmethods (any|publickey)$' \
        || ! printf '%s\n' "${effective}" | awk -v absolute="${keys}" '
            $1 == "authorizedkeysfile" {
                for (i=2; i<=NF; i++) if ($i == ".ssh/authorized_keys" || $i == "%h/.ssh/authorized_keys" || $i == absolute) found=1
            }
            END { exit !found }
        '; then
        rm -f "${config_tmp}" "${backup}"
        error "SSH Match rules or AuthorizedKeysFile override key-only access for ${target_user}; original configuration retained"
    fi
    if ! sudo install -m 0644 -o root -g root "${config_tmp}" "${config}" \
        || ! sudo /usr/sbin/sshd -t \
        || ! sudo systemctl reload ssh; then
        sudo install -m 0644 -o root -g root "${backup}" "${config}" || error "SSH rollback failed; backup is ${backup}"
        sudo systemctl reload ssh || warn "Could not reload restored SSH configuration"
        rm -f "${config_tmp}" "${backup}"
        error "SSH change failed; previous configuration restored"
    fi
    rm -f "${config_tmp}" "${backup}"
    success "SSH public-key login configured for ${target_user}; password and keyboard-interactive login disabled."
    info "Existing SSH sessions stay open. New connections must use an authorized private key."
}

main() {
    detect_ubuntu

    if [[ "${UNINSTALL}" == true ]]; then
        uninstall_node
    else
        section "Version Selection"
        select_rocm_version
        preflight_checks
        confirm_install
        prepare_amd_upgrade

        # A failed earlier install may have left sources pointing at the wrong
        # keyring. Remove our managed sources before the first bootstrap update.
        clear_amd_repo_files
        install_base_packages
        configure_pcie_aspm
        install_cli_tool_compat_symlinks
        install_yq_tool
        install_python_tooling
        configure_gcc_alternatives
        install_rocm_repos
        install_amd_stack
        configure_rocm_path
        configure_ml_environment
        install_bandwidth_test
        setup_repos
        validate_install
        finalize_ssh_access
        offer_reboot
    fi
}

main
