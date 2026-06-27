#!/usr/bin/env bash

# ═══════════════════════════════════════════════════════════════
# base-install.sh — GPU Node Base Installation Script
# Supports: Ubuntu 22.04 / 24.04 / 26.04 (x86_64)
# Installs: NVIDIA drivers, CUDA toolkit, cuDNN, DCGM, gpu-burn
# Version:  1.9 (2026-02-27)
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
echo " GPU Node Installation Script  (v1.9 — 2026-02-27)"
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
CUDA_TOOLKIT_VERSION=""
CUDA_DISPLAY_VERSION=""
CUDA_CUDNN_SUFFIX=""
NON_INTERACTIVE=false
UNINSTALL=false
SKIP_GPU_STACK=false
FREEZE_GPU_STACK=false
UNFREEZE_GPU_STACK=false
GPU_STACK_HOLD_DETECTED=false
GPU_STACK_HOLD_AFTER_INSTALL=false
GPU_STACK_HELD_PACKAGES=()
GPU_STACK_INSTALLED_PACKAGES=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --driver  <575|580|595|610>        NVIDIA driver version (default: interactive)
  --cuda    <12-9|13|13.3>           CUDA toolkit version  (default: interactive)
  --yes                      Non-interactive mode, use defaults (580 + 12-9)
  --no-gpu-stack             Skip NVIDIA driver / CUDA toolkit / DCGM / gpu-burn install
  --freeze-gpu-stack         Hold the validated NVIDIA/CUDA stack after install
  --unfreeze-gpu-stack       Temporarily unhold NVIDIA/CUDA packages before install, then re-hold after validation
  --uninstall                Full clean removal — restores system to post-OS-install state
  -h, --help                 Show this help

Examples:
  $(basename "$0")                           # Interactive install
  $(basename "$0") --driver 580 --cuda 12-9  # Explicit versions
  $(basename "$0") --driver 610 --cuda 13.3  # Latest supported stack
  $(basename "$0") --no-gpu-stack           # Base host tooling only
  $(basename "$0") --freeze-gpu-stack        # Freeze the validated stack after install
  $(basename "$0") --unfreeze-gpu-stack      # Unhold, upgrade, then re-freeze
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
        --no-gpu-stack) SKIP_GPU_STACK=true; shift ;;
        --freeze-gpu-stack) FREEZE_GPU_STACK=true; shift ;;
        --unfreeze-gpu-stack) UNFREEZE_GPU_STACK=true; shift ;;
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
        "26.04") UBUNTU_CODENAME="ubuntu2604" ;;
        *) error "Unsupported Ubuntu version: ${VERSION_ID}. Supported: 22.04, 24.04, 26.04" ;;
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
    if [[ "${SKIP_GPU_STACK}" == false ]]; then
        check_host "developer.download.nvidia.com" "NVIDIA repo" "hard"
    else
        success "NVIDIA repo network check: skipped (--no-gpu-stack)"
    fi
    check_host "github.com" "GitHub" "soft"

    # Secure Boot
    if [[ "${SKIP_GPU_STACK}" == false ]]; then
        if command -v mokutil &>/dev/null && mokutil --sb-state 2>/dev/null | grep -q "enabled"; then
            warn "Secure Boot ENABLED — DKMS modules may fail to load. Disable in BIOS."
            if [[ "${NON_INTERACTIVE}" == false ]]; then
                read -rp "  Continue anyway? [y/N]: " sb_confirm
                [[ "${sb_confirm,,}" == "y" ]] || error "Aborted."
            fi
        else
            success "Secure Boot: disabled (OK)"
        fi
    else
        success "Secure Boot check: skipped (--no-gpu-stack)"
    fi

    # Existing NVIDIA
    if [[ "${SKIP_GPU_STACK}" == false ]]; then
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
    else
        success "Existing NVIDIA/CUDA package conflict check: skipped (--no-gpu-stack)"
    fi

    # Kernel headers — check AND warn clearly since we install them in base packages
    if [[ "${SKIP_GPU_STACK}" == false ]]; then
        local kver; kver=$(uname -r)
        if apt-cache show "linux-headers-${kver}" &>/dev/null; then
            success "Kernel headers: available for ${kver}"
        else
            warn "linux-headers-${kver} not in apt cache — will attempt install anyway"
            (( warnings++ )) || true
        fi
    else
        success "Kernel headers check: skipped (--no-gpu-stack)"
    fi

    (( warnings > 0 )) && warn "${warnings} warning(s) above" || success "All pre-flight checks passed"
}

# ═══════════════════════════════════════════════════════════════
# STEP 2.5 — NVIDIA/CUDA hold management
# ═══════════════════════════════════════════════════════════════
GPU_STACK_HOLD_REGEX='^(cuda-|cudnn9-cuda-|datacenter-gpu-manager|libcuda|libcudnn|libnvidia|nvidia-)'
GPU_STACK_HOLD_EXCLUDE_REGEX='^(cuda-keyring|nvidia-container-toolkit|nvidia-container-runtime|libnvidia-container)'

_gpu_stack_packages_from_dpkg() {
    dpkg -l 2>/dev/null \
        | awk '$1 == "ii" { print $2 }' \
        | grep -E "${GPU_STACK_HOLD_REGEX}" \
        | grep -Ev "${GPU_STACK_HOLD_EXCLUDE_REGEX}" \
        | sort -u \
        || true
}

_gpu_stack_packages_from_holds() {
    apt-mark showhold 2>/dev/null \
        | grep -E "${GPU_STACK_HOLD_REGEX}" \
        | grep -Ev "${GPU_STACK_HOLD_EXCLUDE_REGEX}" \
        | sort -u \
        || true
}

capture_gpu_stack_hold_state() {
    mapfile -t GPU_STACK_INSTALLED_PACKAGES < <(_gpu_stack_packages_from_dpkg)
    mapfile -t GPU_STACK_HELD_PACKAGES < <(_gpu_stack_packages_from_holds)
    if (( ${#GPU_STACK_HELD_PACKAGES[@]} > 0 )); then
        GPU_STACK_HOLD_DETECTED=true
    else
        GPU_STACK_HOLD_DETECTED=false
    fi
}

print_gpu_stack_packages() {
    local title="$1"
    shift
    local -a packages=("$@")

    echo "${title}"
    if (( ${#packages[@]} > 0 )); then
        printf '    %s\n' "${packages[@]}"
    else
        echo "    (none)"
    fi
}

warn_about_gpu_stack_holds() {
    capture_gpu_stack_hold_state
    if [[ "${GPU_STACK_HOLD_DETECTED}" == true ]]; then
        section "GPU Stack Hold Detected"
        warn "Held NVIDIA/CUDA packages were found on this node."
        print_gpu_stack_packages "Held packages:" "${GPU_STACK_HELD_PACKAGES[@]}"
        if [[ "${UNFREEZE_GPU_STACK}" == true ]]; then
            info "The installer will temporarily unhold these packages before installation."
        else
            warn "They will stay frozen unless you rerun with --unfreeze-gpu-stack."
            warn "To unhold manually: run nvidia-stack-hold.sh --unhold from the repo's install/ directory (or from /opt/provision if copied there)"
        fi
    fi
}

unhold_gpu_stack_packages() {
    capture_gpu_stack_hold_state
    if (( ${#GPU_STACK_HELD_PACKAGES[@]} == 0 )); then
        info "No held NVIDIA/CUDA packages found — nothing to unhold"
        return 0
    fi

    section "Unholding NVIDIA/CUDA Packages"
    print_gpu_stack_packages "Removing holds from:" "${GPU_STACK_HELD_PACKAGES[@]}"
    sudo apt-mark unhold "${GPU_STACK_HELD_PACKAGES[@]}" \
        || error "Failed to unhold NVIDIA/CUDA packages"
    success "NVIDIA/CUDA holds removed"
}

hold_gpu_stack_packages() {
    capture_gpu_stack_hold_state
    if (( ${#GPU_STACK_INSTALLED_PACKAGES[@]} == 0 )); then
        warn "No installed NVIDIA/CUDA packages found to hold"
        return 0
    fi

    section "Freezing NVIDIA/CUDA Packages"
    print_gpu_stack_packages "Applying holds to:" "${GPU_STACK_INSTALLED_PACKAGES[@]}"
    sudo apt-mark hold "${GPU_STACK_INSTALLED_PACKAGES[@]}" \
        || error "Failed to hold NVIDIA/CUDA packages"
    success "NVIDIA/CUDA packages held"
}

# ═══════════════════════════════════════════════════════════════
# STEP 3 — Version Selection
# ═══════════════════════════════════════════════════════════════
select_driver_version() {
    if [[ -n "${DRIVER_VERSION}" ]]; then
        case "${DRIVER_VERSION}" in
            575|580|595|610) success "Driver version (--driver arg): ${DRIVER_VERSION}" ; return ;;
            *) error "Invalid --driver: ${DRIVER_VERSION}. Valid: 575, 580, 595, 610" ;;
        esac
    fi
    if [[ "${NON_INTERACTIVE}" == true ]]; then
        DRIVER_VERSION="580"; success "Driver version (default): ${DRIVER_VERSION}"; return
    fi
    echo ""
    echo -e "${BOLD}Select NVIDIA Driver Version:${NC}"
    echo "  1) 575  — stable, widely tested"
    echo "  2) 580  — recommended [default]"
    echo "  3) 595  — current"
    echo "  4) 610  — latest"
    echo ""
    read -rp "Enter choice [1-4, default=2]: " driver_choice
    case "${driver_choice}" in
        1) DRIVER_VERSION="575" ;;
        3) DRIVER_VERSION="595" ;;
        4) DRIVER_VERSION="610" ;;
        *) DRIVER_VERSION="580" ;;
    esac
    success "Driver version: ${DRIVER_VERSION}"
}

select_cuda_version() {
    if [[ -n "${CUDA_VERSION}" ]]; then
        case "${CUDA_VERSION}" in
            "12-9"|"12.9")
                CUDA_TOOLKIT_VERSION="12-9"
                CUDA_DISPLAY_VERSION="12.9"
                CUDA_MAJOR="12"
                CUDA_CUDNN_SUFFIX="12"
                ;;
            "13"|"13.0")
                CUDA_TOOLKIT_VERSION="13"
                CUDA_DISPLAY_VERSION="13.0"
                CUDA_MAJOR="13"
                CUDA_CUDNN_SUFFIX="13"
                ;;
            "13-3"|"13.3")
                CUDA_TOOLKIT_VERSION="13-3"
                CUDA_DISPLAY_VERSION="13.3"
                CUDA_MAJOR="13"
                CUDA_CUDNN_SUFFIX="13-3"
                ;;
            *) error "Invalid --cuda: ${CUDA_VERSION}. Valid: 12-9, 13, 13.3" ;;
        esac
        success "CUDA version (--cuda arg): ${CUDA_DISPLAY_VERSION}"; return
    fi
    if [[ "${NON_INTERACTIVE}" == true ]]; then
        CUDA_TOOLKIT_VERSION="12-9"; CUDA_MAJOR="12"
        CUDA_DISPLAY_VERSION="12.9"; CUDA_CUDNN_SUFFIX="12"
        success "CUDA version (default): ${CUDA_DISPLAY_VERSION}"; return
    fi
    echo ""
    echo -e "${BOLD}Select CUDA Toolkit Version:${NC}"
    echo "  1) 12.9  — stable [default]"
    echo "  2) 13.3  — latest"
    echo "  3) 13.0  — legacy 13.x"
    echo ""
    read -rp "Enter choice [1-3, default=1]: " cuda_choice
    case "${cuda_choice}" in
        2)
            CUDA_TOOLKIT_VERSION="13-3"
            CUDA_DISPLAY_VERSION="13.3"
            CUDA_MAJOR="13"
            CUDA_CUDNN_SUFFIX="13-3"
            ;;
        3)
            CUDA_TOOLKIT_VERSION="13"
            CUDA_DISPLAY_VERSION="13.0"
            CUDA_MAJOR="13"
            CUDA_CUDNN_SUFFIX="13"
            ;;
        *)
            CUDA_TOOLKIT_VERSION="12-9"
            CUDA_DISPLAY_VERSION="12.9"
            CUDA_MAJOR="12"
            CUDA_CUDNN_SUFFIX="12"
            ;;
    esac
    success "CUDA version: ${CUDA_DISPLAY_VERSION}"
}

validate_combination() {
    if [[ "${CUDA_MAJOR}" == "13" && "${DRIVER_VERSION}" == "575" ]]; then
        warn "Driver 575 + CUDA 13.x may have compatibility issues. Recommended: 580, 595, or 610."
        if [[ "${NON_INTERACTIVE}" == false ]]; then
            read -rp "  Continue anyway? [y/N]: " yn
            [[ "${yn,,}" == "y" ]] || error "Aborted."
        fi
    fi
    success "Combination: Driver ${DRIVER_VERSION} + CUDA ${CUDA_DISPLAY_VERSION}"
}

# ═══════════════════════════════════════════════════════════════
# STEP 4 — Confirm
# ═══════════════════════════════════════════════════════════════
confirm_install() {
    echo ""
    echo -e "${BOLD}════════════════════════════════════════${NC}"
    echo -e "  Ubuntu:        ${UBUNTU_VERSION_ID} (${UBUNTU_CODENAME})"
    if [[ "${SKIP_GPU_STACK}" == true ]]; then
        echo -e "  Mode:          host tooling only (--no-gpu-stack)"
    else
        echo -e "  NVIDIA Driver: ${DRIVER_VERSION}-open (DKMS)"
        echo -e "  CUDA Toolkit:  ${CUDA_DISPLAY_VERSION}"
        echo -e "  cuDNN:         cudnn9-cuda-${CUDA_CUDNN_SUFFIX}"
    fi
    echo -e "  Log file:      ${LOG_FILE}"
    if [[ "${FREEZE_GPU_STACK}" == true || "${UNFREEZE_GPU_STACK}" == true ]]; then
        echo -e "  GPU stack:     will be held after validation"
    fi
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
        software-properties-common apt-transport-https ca-certificates curl gnupg debconf-utils \
        || error "Bootstrap package install failed"

    if [[ "${SKIP_GPU_STACK}" == false ]]; then
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
    else
        info "Skipping graphics-drivers PPA and kernel headers (--no-gpu-stack)"
    fi

    if command -v debconf-set-selections &>/dev/null; then
        printf 'iperf3 iperf3/start_daemon boolean true\n' | sudo debconf-set-selections
        success "Preseeded iperf3 to start as a daemon automatically"
    else
        warn "debconf-set-selections not found — iperf3 may prompt during install"
    fi

    info "Installing base packages..."
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        git cmake build-essential dkms alsa-utils \
        gcc-11 g++-11 gcc-12 g++-12 lsb-release \
        ipmitool jq fzf ripgrep fd-find bat \
        pciutils usbutils iproute2 util-linux dmidecode lshw \
        coreutils chrony nvme-cli bpytop mokutil \
        python3 python3-pip python3-venv \
        smartmontools stress-ng fio lm-sensors ethtool iperf3 \
        rsync xorriso squashfs-tools grub-common grub-pc-bin grub-efi-amd64-bin \
        lvm2 mdadm lsof ioping \
        || error "Base package install failed"

    sudo systemctl enable --now chrony \
        || warn "Failed to enable chrony"
    success "Base packages installed"
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

# ═══════════════════════════════════════════════════════════════
# STEP 5.5 — Python tooling
# ═══════════════════════════════════════════════════════════════
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

install_benchmark_python_runtime() {
    section "Benchmark Python Runtime"

    local benchmark_root="/opt/infra/python"
    local benchmark_version="3.11"
    local uv_path py_bin py_bin_dir

    uv_path="$(command -v uv 2>/dev/null || true)"
    [ -n "${uv_path}" ] || error "uv not found — install_python_tooling must run first"

    if [ -n "${INFRA_PYTHON_BENCH:-}" ] && [ -x "${INFRA_PYTHON_BENCH}" ] \
        && [[ "${INFRA_PYTHON_BENCH}" == "${benchmark_root}/"* ]]; then
        info "Refreshing benchmark Python ${benchmark_version} via uv (managed install: ${INFRA_PYTHON_BENCH})..."
    else
        info "Installing benchmark Python ${benchmark_version} via uv..."
    fi
    sudo install -d -m 0755 "${benchmark_root}"
    sudo env UV_PYTHON_INSTALL_DIR="${benchmark_root}" "${uv_path}" python install "${benchmark_version}" --managed-python \
        --reinstall \
        || error "Failed to install benchmark Python ${benchmark_version}"

    py_bin="$(find "${benchmark_root}" -type f -name 'python3.11' -perm -111 2>/dev/null | sort | tail -n 1)"
    if [ -z "${py_bin}" ]; then
        py_bin="$(find "${benchmark_root}" -type f -name 'python' -perm -111 2>/dev/null | sort | tail -n 1)"
    fi
    if [ -z "${py_bin}" ] || [ ! -x "${py_bin}" ]; then
        error "Benchmark Python ${benchmark_version} install completed but the executable could not be found"
    fi

    "${py_bin}" -m venv /tmp/infra-benchmark-python-check 2>/dev/null \
        || error "Benchmark Python ${benchmark_version} cannot create virtual environments"
    rm -rf /tmp/infra-benchmark-python-check

    py_bin_dir="$(dirname "${py_bin}")"
    sudo tee /etc/profile.d/infra-python.sh > /dev/null <<EOF
# Infra benchmark Python — added by base-install.sh
export INFRA_PYTHON_BENCH="${py_bin}"
export INFRA_PYTHON_BENCH_DIR="${py_bin_dir}"
export INFRA_PYTHON_BENCH_VERSION="${benchmark_version}"
export PATH="${py_bin_dir}:\${PATH}"
EOF
    sudo chmod 644 /etc/profile.d/infra-python.sh

    success "Benchmark Python configured: ${py_bin}"
}

# ═══════════════════════════════════════════════════════════════
# STEP 5.55 — GPU fallback recovery policy
# ═══════════════════════════════════════════════════════════════
configure_gpu_fallback_recovery() {
    section "GPU Fallback Recovery Policy"

    local system_conf="/etc/systemd/system.conf"
    local sysctl_conf="/etc/sysctl.d/99-gpu-fallback.conf"
    local managed_start="# >>> infra GPU fallback recovery >>>"
    local managed_end="# <<< infra GPU fallback recovery <<<"
    local tmp_file

    tmp_file="$(mktemp)"
    if [[ -f "${system_conf}" ]]; then
        awk -v start="${managed_start}" -v end="${managed_end}" '
            BEGIN { skip = 0 }
            $0 == start { skip = 1; next }
            $0 == end { skip = 0; next }
            skip == 0 { print }
        ' "${system_conf}" > "${tmp_file}"
    fi
    {
        printf '\n%s\n' "${managed_start}"
        printf '[Manager]\n'
        printf 'DefaultTimeoutStopSec=30s\n'
        printf 'DefaultTimeoutAbortSec=15s\n'
        printf '%s\n' "${managed_end}"
    } >> "${tmp_file}"
    sudo install -m 0644 -o root -g root "${tmp_file}" "${system_conf}" \
        || error "Failed to update ${system_conf}"
    rm -f "${tmp_file}"
    success "Configured systemd stop/abort timeouts in ${system_conf}"

    sudo tee "${sysctl_conf}" >/dev/null <<'EOF'
# GPU node fallback policy — added by base-install.sh
kernel.panic=10
kernel.panic_on_oops=1
kernel.hung_task_panic=1
kernel.hung_task_timeout_secs=120
EOF
    sudo chown root:root "${sysctl_conf}"
    sudo chmod 0644 "${sysctl_conf}"
    sudo sysctl --system >/dev/null \
        && success "Applied GPU fallback sysctl policy from ${sysctl_conf}" \
        || warn "sysctl --system reported warnings while applying ${sysctl_conf}"

    sudo systemctl daemon-reexec 2>/dev/null \
        && success "systemd manager configuration reloaded" \
        || warn "systemd daemon-reexec failed; timeout changes will apply after reboot"
}

configure_pcie_aspm() {
    section "PCIe / NVMe Boot Policy"

    local grub_d="/etc/default/grub.d/99-infra-pcie-aspm.cfg"

    sudo install -d -m 0755 /etc/default/grub.d
    sudo tee "${grub_d}" >/dev/null <<'EOF'
# PCIe / storage boot policy — added by base-install.sh
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

remove_gpu_fallback_recovery() {
    section "Removing GPU Fallback Recovery Policy"

    local system_conf="/etc/systemd/system.conf"
    local sysctl_conf="/etc/sysctl.d/99-gpu-fallback.conf"
    local managed_start="# >>> infra GPU fallback recovery >>>"
    local managed_end="# <<< infra GPU fallback recovery <<<"

    if [[ -f "${system_conf}" ]] && grep -Fxq "${managed_start}" "${system_conf}"; then
        local tmp_file
        tmp_file="$(mktemp)"
        awk -v start="${managed_start}" -v end="${managed_end}" '
            BEGIN { skip = 0 }
            $0 == start { skip = 1; next }
            $0 == end { skip = 0; next }
            skip == 0 { print }
        ' "${system_conf}" > "${tmp_file}"
        sudo install -m 0644 -o root -g root "${tmp_file}" "${system_conf}" \
            || warn "Failed to remove managed systemd timeout block from ${system_conf}"
        rm -f "${tmp_file}"
        success "Removed managed systemd timeout block"
    else
        info "Managed systemd timeout block not present — skipping"
    fi

    if [[ -f "${sysctl_conf}" ]]; then
        sudo rm -f "${sysctl_conf}"
        success "Removed ${sysctl_conf}"
        sudo sysctl --system >/dev/null \
            || warn "sysctl --system reported warnings after removing ${sysctl_conf}"
    else
        info "${sysctl_conf} not present — skipping"
    fi

    sudo systemctl daemon-reexec 2>/dev/null \
        && success "systemd manager configuration reloaded" \
        || warn "systemd daemon-reexec failed; timeout cleanup will fully apply after reboot"
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
        info "${grub_d} not present — skipping"
    fi
}

# ═══════════════════════════════════════════════════════════════
# STEP 5.6 — User access
# ═══════════════════════════════════════════════════════════════
install_user_access() {
    section "User Access"

    local target_user target_home target_group
    target_user="${SUDO_USER:-${USER:-}}"
    [[ -n "${target_user}" && "${target_user}" != "root" ]] || target_user="${USER:-root}"
    target_home="$(getent passwd "${target_user}" 2>/dev/null | awk -F: '{print $6}' || true)"
    [[ -n "${target_home}" ]] || target_home="${HOME:-/root}"
    target_group="$(id -gn "${target_user}" 2>/dev/null || echo "${target_user}")"

    if [[ "${target_user}" == "root" ]]; then
        info "Target user is root — skipping SSH authorized key and sudoers changes"
        return
    fi

    local ssh_dir authorized_keys access_key auth_tmp
    ssh_dir="${target_home}/.ssh"
    authorized_keys="${ssh_dir}/authorized_keys"
    access_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG3WsgbyzKCqXrdZJyWiRA/SHPC1nGAfs6bvnj7K/PZ9 ezc@local'

    sudo install -d -m 0700 -o "${target_user}" -g "${target_group}" "${ssh_dir}"
    auth_tmp="$(mktemp)"
    if [[ -f "${authorized_keys}" ]]; then
        cat "${authorized_keys}" > "${auth_tmp}"
    fi
    if ! grep -Fxq "${access_key}" "${auth_tmp}"; then
        printf '%s\n' "${access_key}" >> "${auth_tmp}"
        success "Added SSH authorized key for ${target_user}"
    else
        success "SSH authorized key already present in ${authorized_keys}"
    fi
    sudo install -m 0600 -o "${target_user}" -g "${target_group}" "${auth_tmp}" "${authorized_keys}"
    rm -f "${auth_tmp}"

    local sudoers_file sudoers_line
    sudoers_file="/etc/sudoers.d/99-infra-${target_user}"
    sudoers_line="${target_user} ALL=(ALL) NOPASSWD:ALL"

    if sudo -l -U "${target_user}" 2>/dev/null | grep -Eq 'NOPASSWD:[[:space:]]*ALL'; then
        success "${target_user} already has passwordless sudo"
    else
        printf '%s\n' "${sudoers_line}" | sudo tee "${sudoers_file}" >/dev/null
        sudo chown root:root "${sudoers_file}"
        sudo chmod 0440 "${sudoers_file}"
        sudo visudo -cf "${sudoers_file}" >/dev/null \
            || error "sudoers validation failed for ${sudoers_file}"
        success "Added passwordless sudoers drop-in for ${target_user}"
    fi
}

# ═══════════════════════════════════════════════════════════════
# STEP 5.7 — Shell aliases
# ═══════════════════════════════════════════════════════════════
install_shell_aliases() {
    section "Shell Aliases"

    local repo_root alias_source target_user target_home target_group
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    alias_source="${repo_root}/.aliases"
    [[ -f "${alias_source}" ]] || error "Repo alias file not found: ${alias_source}"

    target_user="${SUDO_USER:-${USER:-}}"
    [[ -n "${target_user}" && "${target_user}" != "root" ]] || target_user="${USER:-root}"
    target_home="$(getent passwd "${target_user}" 2>/dev/null | awk -F: '{print $6}' || true)"
    [[ -n "${target_home}" ]] || target_home="${HOME:-/root}"
    target_group="$(id -gn "${target_user}" 2>/dev/null || echo "${target_user}")"

    local aliases_file bashrc zshrc fish_config fish_aliases
    aliases_file="${target_home}/.aliases"
    bashrc="${target_home}/.bashrc"
    zshrc="${target_home}/.zshrc"
    fish_config="${target_home}/.config/fish/config.fish"
    fish_aliases="${target_home}/.aliases.fish"

    local managed_start="# >>> infra aliases from repo >>>"
    local managed_end="# <<< infra aliases from repo <<<"
    local tmp_file
    tmp_file="$(mktemp)"

    mkdir -p "${target_home}"

    if [[ -f "${aliases_file}" ]]; then
        awk -v start="${managed_start}" -v end="${managed_end}" '
            BEGIN { skip = 0 }
            $0 == start { skip = 1; next }
            $0 == end { skip = 0; next }
            skip == 0 { print }
        ' "${aliases_file}" > "${tmp_file}"
    fi
    {
        printf '\n%s\n' "${managed_start}"
        cat "${alias_source}"
        printf '%s\n' "${managed_end}"
    } >> "${tmp_file}"
    sudo install -m 0644 -o "${target_user}" -g "${target_group}" "${tmp_file}" "${aliases_file}"
    rm -f "${tmp_file}"
    success "Installed ${aliases_file}"

    install_rc_block() {
        local rc_file="$1" rc_body="$2"
        local rc_tmp
        rc_tmp="$(mktemp)"
        mkdir -p "$(dirname "${rc_file}")"
        if [[ -f "${rc_file}" ]]; then
            awk -v start="${managed_start}" -v end="${managed_end}" '
                BEGIN { skip = 0 }
                $0 == start { skip = 1; next }
                $0 == end { skip = 0; next }
                skip == 0 { print }
            ' "${rc_file}" > "${rc_tmp}"
        fi
        {
            printf '\n%s\n' "${managed_start}"
            printf '%s\n' "${rc_body}"
            printf '%s\n' "${managed_end}"
        } >> "${rc_tmp}"
        sudo install -m 0644 -o "${target_user}" -g "${target_group}" "${rc_tmp}" "${rc_file}"
        rm -f "${rc_tmp}"
    }

    install_rc_block "${bashrc}" '[ -f "$HOME/.aliases" ] && . "$HOME/.aliases"'
    install_rc_block "${zshrc}" '[ -f "$HOME/.aliases" ] && . "$HOME/.aliases"'
    success "Updated bashrc and zshrc to source ~/.aliases"

    {
        printf '# Autogenerated by base-install.sh from repo .aliases\n'
        printf '# Fish wrappers call bash so the repo bash aliases stay the single source of truth.\n\n'
        while IFS= read -r alias_line; do
            [[ "${alias_line}" =~ ^alias[[:space:]]+\'([^\']+)\'= ]] || continue
            local alias_name
            alias_name="${BASH_REMATCH[1]}"
            printf "function %s --description 'Repo alias from ~/.aliases'\n" "${alias_name}"
            printf '    bash -lc '\''source "$HOME/.aliases"; %s'\''\n' "${alias_name}"
            printf 'end\n\n'
        done < "${alias_source}"
    } > "${fish_aliases}.tmp"
    sudo install -m 0644 -o "${target_user}" -g "${target_group}" "${fish_aliases}.tmp" "${fish_aliases}"
    rm -f "${fish_aliases}.tmp"

    install_rc_block "${fish_config}" 'if test -f "$HOME/.aliases.fish"
    source "$HOME/.aliases.fish"
end'
    success "Updated fish config to source generated fish wrappers"

    # Load aliases into the current shell when the script is being run from bash.
    # This does not modify the caller's shell process, but it does validate the file
    # and fails the install if the copied alias file does not source cleanly.
    # shellcheck disable=SC1090
    source "${aliases_file}" || error "Failed to source ${aliases_file}"
    hash -r 2>/dev/null || true
    success "Loaded ~/.aliases in the current install shell"
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
    info "Installing driver=${DRIVER_VERSION}, cuda=${CUDA_DISPLAY_VERSION}, cudnn=cudnn9-cuda-${CUDA_CUDNN_SUFFIX}"

    # Install nvidia-utils explicitly so nvidia-smi and related userspace tools
    # are present for every supported driver version.
    local utils_pkg="nvidia-utils-${DRIVER_VERSION}"
    info "Adding ${utils_pkg} for nvidia-smi and related tools"

    sudo apt-get install -V -y \
        "cuda-toolkit-${CUDA_TOOLKIT_VERSION}" \
        "libnvidia-compute-${DRIVER_VERSION}" \
        "nvidia-dkms-${DRIVER_VERSION}-open" \
        "${utils_pkg}" \
        "cudnn9-cuda-${CUDA_CUDNN_SUFFIX}" \
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

    if [[ "${SKIP_GPU_STACK}" == false ]]; then
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
    else
        info "Skipping gpu-burn repo/build (--no-gpu-stack)"
    fi
}

# ═══════════════════════════════════════════════════════════════
# STEP 12 — Validation
# ═══════════════════════════════════════════════════════════════
validate_install() {
    section "Post-install Validation"
    local warnings=0

    if [[ "${SKIP_GPU_STACK}" == false ]]; then
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
    else
        success "GPU stack skipped: nvidia-smi/nvcc checks not run"
    fi

    if [[ -n "${INFRA_PYTHON_BENCH:-}" ]] && [[ -x "${INFRA_PYTHON_BENCH}" ]]; then
        success "benchmark python: $(${INFRA_PYTHON_BENCH} --version 2>/dev/null || echo unknown)"
    elif command -v python3.11 &>/dev/null; then
        success "python3.11: $(python3.11 --version 2>/dev/null || echo unknown)"
    else
        warn "benchmark Python 3.11 not found (PyTorch DDP lane may be skipped)"; (( warnings++ )) || true
    fi

    if [[ "${SKIP_GPU_STACK}" == false ]]; then
        systemctl is-active --quiet nvidia-dcgm 2>/dev/null \
            && success "nvidia-dcgm: running" \
            || { warn "nvidia-dcgm: not running (expected before reboot)"; (( warnings++ )) || true; }
    else
        success "GPU stack skipped: nvidia-dcgm check not run"
    fi

    systemctl is-active --quiet chrony \
        && success "chrony: running" \
        || { warn "chrony not running"; (( warnings++ )) || true; }

    if [[ "${SKIP_GPU_STACK}" == false ]]; then
        [[ -f "${HOME}/gpu-burn/gpu_burn" ]] \
            && success "gpu-burn: ready" \
            || { warn "gpu-burn: not built (reboot first, then re-run)"; (( warnings++ )) || true; }
    else
        success "GPU stack skipped: gpu-burn check not run"
    fi

    [[ -d "${HOME}/infra" ]] \
        && success "infra repo: present" \
        || { warn "infra repo: missing"; (( warnings++ )) || true; }

    echo ""
    if [[ "${SKIP_GPU_STACK}" == true ]]; then
        success "Base install complete — GPU stack was intentionally skipped"
    elif (( warnings > 0 )); then
        warn "${warnings} item(s) pending — most resolve after reboot"
    else
        success "All checks passed — node is ready"
    fi
}

# ═══════════════════════════════════════════════════════════════
# STEP 13 — Reboot prompt (install)
# ═══════════════════════════════════════════════════════════════
offer_reboot() {
    if [[ "${SKIP_GPU_STACK}" == true ]]; then
        echo ""
        echo -e "${BOLD}════════════════════════════════════════${NC}"
        echo -e "${GREEN}${BOLD} Host tooling install complete!${NC}"
        echo -e "  Mode:     host tooling only (--no-gpu-stack)"
        echo -e "  Log file: ${LOG_FILE}"
        echo -e "${BOLD}════════════════════════════════════════${NC}"
        echo ""
        return 0
    fi

    echo ""
    echo -e "${BOLD}════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD} Installation complete!${NC}"
    echo -e "  Driver: ${DRIVER_VERSION}-open  |  CUDA: ${CUDA_DISPLAY_VERSION}  |  Ubuntu: ${UBUNTU_VERSION_ID}"
    echo -e "  PCIe boot policy: managed (pcie_aspm=off, pci=noaer, pci=realloc=on, pcie_aspm.policy=performance, nvme_core.default_ps_max_latency_us=0)"
    echo -e "  Full log: ${LOG_FILE}"
    echo -e "${BOLD}════════════════════════════════════════${NC}"
    echo ""

    if [[ "${GPU_STACK_HOLD_DETECTED}" == true || "${GPU_STACK_HOLD_AFTER_INSTALL}" == true ]]; then
        section "NVIDIA/CUDA Freeze Reminder"
        warn "A frozen NVIDIA/CUDA stack is present on this node."
        if [[ "${UNFREEZE_GPU_STACK}" == true ]]; then
            success "Temporary bypass path completed — the validated stack was re-frozen after validation."
        fi
        warn "To update later: run nvidia-stack-hold.sh --unhold from the repo's install/ directory (or from /opt/provision if copied there)"
        warn "To temporarily update through this installer: rerun with --unfreeze-gpu-stack"
    fi

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
    echo "  • /etc/profile.d/infra-python.sh benchmark Python entry"
    echo "  • /etc/ld.so.conf.d/ CUDA library path entries"
    echo "  • GPU fallback recovery systemd/sysctl settings"
    echo "  • PCIe / NVMe boot policy (pcie_aspm=off, pci=noaer, pci=realloc=on, pcie_aspm.policy=performance, nvme_core.default_ps_max_latency_us=0)"
    echo "  • GCC update-alternatives entries"
    echo "  • Storage tools: smartmontools, lvm2, mdadm, lsof, ioping"
    echo "  • gpu-burn and infra repos (optional)"
    echo "  • Orphaned apt dependencies"
    echo ""

    if [[ "${NON_INTERACTIVE}" == false ]]; then
        read -rp "Proceed with full uninstall? [y/N]: " confirm_uninstall
        [[ "${confirm_uninstall,,}" == "y" ]] || error "Uninstall aborted by user."
    else
        info "Non-interactive mode — proceeding with uninstall"
    fi

    # Clear any package holds first so the purge path is not blocked by a
    # frozen GPU stack from a previous validation run.
    if apt-mark showhold 2>/dev/null | grep -Eq "${GPU_STACK_HOLD_REGEX}"; then
        section "Removing NVIDIA/CUDA Holds"
        unhold_gpu_stack_packages
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
        | grep -P '^ii\s+(nvidia|cuda|cudnn|datacenter-gpu-manager|libnvidia|libcuda|libcudnn|nvtop|smartmontools|ioping)' \
        | awk '{print $2}' | tr '\n' ' ')
    # Note: lvm2, mdadm, lsof are general system tools — we remove them only if
    # they were not present before our install. We purge selectively below.

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

    # ── 9.1. Remove benchmark Python profile.d entry ───────────
    section "Removing Benchmark Python Configuration"
    if [[ -f /etc/profile.d/infra-python.sh ]]; then
        sudo rm -f /etc/profile.d/infra-python.sh
        success "Removed /etc/profile.d/infra-python.sh"
    else
        info "/etc/profile.d/infra-python.sh not found — already clean"
    fi
    if [[ -d /opt/infra/python ]]; then
        sudo rm -rf /opt/infra/python
        success "Removed /opt/infra/python"
    else
        info "/opt/infra/python not found — already clean"
    fi
    export PATH=$(echo "${PATH}" | tr ':' '\n' | grep -v '/opt/infra/python' | tr '\n' ':' | sed 's/:$//')
    unset INFRA_PYTHON_BENCH INFRA_PYTHON_BENCH_DIR INFRA_PYTHON_BENCH_VERSION

    # ── 9.2. Remove GPU fallback recovery policy ──────────────
    remove_gpu_fallback_recovery

    # ── 9.3. Remove PCIe / NVMe boot policy ────────────────────
    remove_pcie_aspm

    # ── 9.5. Remove shell aliases ─────────────────────────────
    section "Removing Shell Aliases"
    local repo_root alias_source target_user target_home target_group
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    alias_source="${repo_root}/.aliases"
    target_user="${SUDO_USER:-${USER:-}}"
    [[ -n "${target_user}" && "${target_user}" != "root" ]] || target_user="${USER:-root}"
    target_home="$(getent passwd "${target_user}" 2>/dev/null | awk -F: '{print $6}' || true)"
    [[ -n "${target_home}" ]] || target_home="${HOME:-/root}"
    target_group="$(id -gn "${target_user}" 2>/dev/null || echo "${target_user}")"

    local aliases_file bashrc zshrc fish_config fish_aliases managed_start managed_end
    aliases_file="${target_home}/.aliases"
    bashrc="${target_home}/.bashrc"
    zshrc="${target_home}/.zshrc"
    fish_config="${target_home}/.config/fish/config.fish"
    fish_aliases="${target_home}/.aliases.fish"
    managed_start="# >>> infra aliases from repo >>>"
    managed_end="# <<< infra aliases from repo <<<"

    remove_managed_block() {
        local file="$1" tmp
        [[ -f "${file}" ]] || return 0
        tmp="$(mktemp)"
        awk -v start="${managed_start}" -v end="${managed_end}" '
            BEGIN { skip = 0 }
            $0 == start { skip = 1; next }
            $0 == end { skip = 0; next }
            skip == 0 { print }
        ' "${file}" > "${tmp}"
        if [[ -s "${tmp}" ]]; then
            sudo install -m 0644 -o "${target_user}" -g "${target_group}" "${tmp}" "${file}"
        else
            sudo rm -f "${file}"
        fi
        rm -f "${tmp}"
    }

    remove_managed_block "${aliases_file}"
    remove_managed_block "${bashrc}"
    remove_managed_block "${zshrc}"
    remove_managed_block "${fish_config}"
    sudo rm -f "${fish_aliases}"
    success "Removed managed alias blocks and fish wrapper file"

    # ── 9.6. Remove SSH authorized key and sudoers drop-in ─────
    section "Removing User Access"
    local access_key ssh_dir authorized_keys sudoers_file
    access_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG3WsgbyzKCqXrdZJyWiRA/SHPC1nGAfs6bvnj7K/PZ9 ezc@local'
    ssh_dir="${target_home}/.ssh"
    authorized_keys="${ssh_dir}/authorized_keys"
    sudoers_file="/etc/sudoers.d/99-infra-${target_user}"

    if [[ -f "${authorized_keys}" ]]; then
        local auth_tmp
        auth_tmp="$(mktemp)"
        awk -v key="${access_key}" '$0 != key { print }' "${authorized_keys}" > "${auth_tmp}"
        if [[ -s "${auth_tmp}" ]]; then
            sudo install -m 0600 -o "${target_user}" -g "${target_group}" "${auth_tmp}" "${authorized_keys}"
        else
            sudo rm -f "${authorized_keys}"
        fi
        rm -f "${auth_tmp}"
        success "Removed managed SSH authorized key entry"
    else
        info "SSH authorized_keys not present — already clean"
    fi

    if [[ -f "${sudoers_file}" ]]; then
        sudo rm -f "${sudoers_file}"
        success "Removed passwordless sudoers drop-in"
    else
        info "Passwordless sudoers drop-in not present — already clean"
    fi

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

    # ── 13. Remove uv standalone binary ───────────────────────
    section "Removing uv"
    if command -v uv &>/dev/null || [[ -x /usr/local/bin/uv ]]; then
        sudo rm -f /usr/local/bin/uv
        hash -r 2>/dev/null || true
        success "uv removed from /usr/local/bin"
    else
        info "uv not present — already clean"
    fi

    # ── 13.5. Remove yq standalone binary ─────────────────────
    section "Removing yq"
    if command -v yq &>/dev/null || [[ -x /usr/local/bin/yq ]]; then
        sudo rm -f /usr/local/bin/yq
        hash -r 2>/dev/null || true
        success "yq removed from /usr/local/bin"
    else
        info "yq not present — already clean"
    fi

    # ── 14. Optional: remove repos ────────────────────────────
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

    # ── 15. apt autoremove + update ───────────────────────────
    section "Final apt Cleanup"
    sudo apt-get autoremove -y  || warn "autoremove had warnings (non-fatal)"
    sudo apt-get update -q      || warn "apt-get update had warnings (non-fatal)"
    success "apt cleanup complete"

    # ── 16. Final verification ────────────────────────────────
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

    [[ -x /usr/local/bin/uv ]] \
        && warn "/usr/local/bin/uv still exists" \
        || success "uv check: removed"

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
        if [[ "${SKIP_GPU_STACK}" == true ]]; then
            info "--no-gpu-stack selected — NVIDIA driver, CUDA toolkit, cuDNN, DCGM, and gpu-burn steps will be skipped"
            if [[ -n "${DRIVER_VERSION}" || -n "${CUDA_VERSION}" || "${FREEZE_GPU_STACK}" == true || "${UNFREEZE_GPU_STACK}" == true ]]; then
                warn "--no-gpu-stack ignores --driver, --cuda, --freeze-gpu-stack, and --unfreeze-gpu-stack"
            fi
            FREEZE_GPU_STACK=false
            UNFREEZE_GPU_STACK=false
        else
            warn_about_gpu_stack_holds

            section "Version Selection"
            select_driver_version
            select_cuda_version
            validate_combination
        fi
        confirm_install

        if [[ "${SKIP_GPU_STACK}" == false ]]; then
            if [[ "${UNFREEZE_GPU_STACK}" == true ]]; then
                unhold_gpu_stack_packages
                GPU_STACK_HOLD_AFTER_INSTALL=true
            elif [[ "${FREEZE_GPU_STACK}" == true ]]; then
                GPU_STACK_HOLD_AFTER_INSTALL=true
            fi
        fi

        install_base_packages
        install_python_tooling
        install_benchmark_python_runtime
        install_cli_tool_compat_symlinks
        install_yq_tool
        configure_gpu_fallback_recovery
        configure_pcie_aspm
        install_user_access
        install_shell_aliases
        configure_gcc_alternatives
        if [[ "${SKIP_GPU_STACK}" == false ]]; then
            install_cuda_keyring
            install_nvidia_stack
            configure_cuda_path
            install_dcgm
        fi
        setup_repos
        validate_install
        if [[ "${SKIP_GPU_STACK}" == false ]]; then
            if [[ "${GPU_STACK_HOLD_AFTER_INSTALL}" == true ]]; then
                hold_gpu_stack_packages
            fi
        fi
        offer_reboot
    fi
}

main
