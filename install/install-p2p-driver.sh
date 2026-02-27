#!/usr/bin/env bash
# =============================================================================
# install-p2p-driver.sh
# Tinygrad P2P NVIDIA Driver - Install / Uninstall
#
# Enables PCIe BAR1 P2P (peer-to-peer) GPU transfers on consumer cards
# (RTX 4090, some 3090s) by patching NVIDIA's open kernel modules.
# RTX 5090 support exists in the 570.x branch but is still experimental.
#
# Source: https://github.com/tinygrad/open-gpu-kernel-modules
#
# REQUIREMENTS (must be set in BIOS before running):
#   - Large BAR / Resizable BAR: ENABLED
#   - IOMMU / VT-d:              DISABLED
#   - Secure Boot:               DISABLED
#
# USAGE:
#   sudo bash install-p2p-driver.sh install    # Install P2P driver
#   sudo bash install-p2p-driver.sh uninstall  # Restore stock driver
#   sudo bash install-p2p-driver.sh status     # Check P2P status
#   sudo bash install-p2p-driver.sh verify     # Run P2P bandwidth test
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

# Driver version → branch mapping.
# Latest stable for 4090: 565.57.01  |  Experimental for 5090: 570.148.08
DRIVER_VERSION_4090="565.57.01"
DRIVER_VERSION_5090="570.148.08"
REPO_URL="https://github.com/tinygrad/open-gpu-kernel-modules"

BUILD_DIR="/opt/tinygrad-p2p"
BACKUP_DIR="/opt/tinygrad-p2p-backup"
STATE_FILE="/etc/tinygrad-p2p.state"
LOG_FILE="/var/log/tinygrad-p2p-install.log"

# Module names to replace
NVIDIA_MODULES=(nvidia nvidia-modeset nvidia-uvm nvidia-drm)

# =============================================================================
# Colours & helpers
# =============================================================================

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" | tee -a "$LOG_FILE"; }
die()     { error "$*"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}\n" | tee -a "$LOG_FILE"; }

# =============================================================================
# Preflight checks
# =============================================================================

check_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (sudo)."
}

check_dependencies() {
    header "Checking dependencies"
    local missing_cmds=()
    local missing_pkgs=()
    local kernel_ver
    kernel_ver=$(uname -r)

    for cmd in git make gcc dkms wget curl nvidia-smi; do
        command -v "$cmd" &>/dev/null || missing_cmds+=("$cmd")
    done

    # Kernel headers are required for building kernel modules
    if [[ ! -d "/lib/modules/${kernel_ver}/build" ]]; then
        missing_pkgs+=("linux-headers-${kernel_ver}")
    fi

    if [[ ${#missing_cmds[@]} -gt 0 || ${#missing_pkgs[@]} -gt 0 ]]; then
        warn "Missing commands: ${missing_cmds[*]:-none}"
        warn "Missing packages: ${missing_pkgs[*]:-none}"
        info "Installing missing packages..."
        apt-get update -qq
        apt-get install -y build-essential dkms wget git "${missing_pkgs[@]}" 2>&1 | tee -a "$LOG_FILE"
    fi

    # Verify kernel headers installed correctly
    if [[ ! -d "/lib/modules/${kernel_ver}/build" ]]; then
        die "Kernel headers for ${kernel_ver} could not be installed. " \
            "Try: apt-get install linux-headers-${kernel_ver}"
    fi

    success "All dependencies satisfied (kernel: ${kernel_ver})"
}

detect_gpu() {
    header "Detecting GPU hardware"

    if ! command -v nvidia-smi &>/dev/null; then
        die "nvidia-smi not found. Install NVIDIA drivers first."
    fi

    GPU_NAMES=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo "unknown")
    GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l || echo 0)
    CURRENT_DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "unknown")

    info "Detected $GPU_COUNT GPU(s):"
    while IFS= read -r gpu; do
        info "  → $gpu"
    done <<< "$GPU_NAMES"
    info "Current driver: $CURRENT_DRIVER"

    # Determine if we have 5090s
    HAS_5090=false
    HAS_4090=false
    while IFS= read -r gpu; do
        [[ "$gpu" == *"5090"* ]] && HAS_5090=true
        [[ "$gpu" == *"4090"* ]] && HAS_4090=true
    done <<< "$GPU_NAMES"

    if $HAS_5090; then
        DRIVER_VERSION="$DRIVER_VERSION_5090"
        BRANCH="${DRIVER_VERSION_5090}-p2p"
        warn "RTX 5090 detected. Using driver ${DRIVER_VERSION_5090} (EXPERIMENTAL)"
        warn "P2P on 5090 is not fully verified - see github.com/tinygrad/open-gpu-kernel-modules/issues/42"
        echo ""
        read -rp "Continue with experimental 5090 support? [y/N] " confirm
        [[ "${confirm,,}" == "y" ]] || die "Aborted by user."
    elif $HAS_4090; then
        DRIVER_VERSION="$DRIVER_VERSION_4090"
        BRANCH="${DRIVER_VERSION_4090}-p2p"
        info "RTX 4090 detected. Using stable driver ${DRIVER_VERSION_4090}"
    else
        warn "No RTX 4090 or 5090 detected."
        warn "P2P patching targets Ada/Blackwell large BAR. Other GPUs may not work."
        echo ""
        read -rp "Continue anyway? [y/N] " confirm
        [[ "${confirm,,}" == "y" ]] || die "Aborted by user."
        # Default to 4090 branch
        DRIVER_VERSION="$DRIVER_VERSION_4090"
        BRANCH="${DRIVER_VERSION_4090}-p2p"
    fi
}

check_bios_requirements() {
    header "Checking BIOS/system requirements"
    local issues=()

    # Check IOMMU - should be OFF for P2P
    if dmesg 2>/dev/null | grep -qi "IOMMU enabled\|AMD-Vi: Enabled\|DMAR: IOMMU"; then
        issues+=("IOMMU appears to be ENABLED — disable it in BIOS (VT-d / AMD IOMMU)")
    else
        success "IOMMU: not detected as active"
    fi

    # Check Secure Boot
    if command -v mokutil &>/dev/null; then
        if mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"; then
            issues+=("Secure Boot is ENABLED — disable it in BIOS")
        else
            success "Secure Boot: disabled"
        fi
    fi

    # Check Large BAR on first GPU
    FIRST_GPU_PCI=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null | head -1 | sed 's/^0000://')
    if [[ -n "$FIRST_GPU_PCI" ]]; then
        BAR1_SIZE=$(lspci -vvv -s "$FIRST_GPU_PCI" 2>/dev/null | grep -i "Memory.*prefetchable" | awk '{print $NF}' | grep -v "^\[" | head -1 || echo "unknown")
        if [[ "$BAR1_SIZE" == *"G"* ]]; then
            success "Large BAR detected on $FIRST_GPU_PCI: $BAR1_SIZE"
        else
            issues+=("Large BAR may not be enabled on GPU $FIRST_GPU_PCI (BAR1: ${BAR1_SIZE}). Enable Resizable BAR in BIOS.")
        fi
    fi

    if [[ ${#issues[@]} -gt 0 ]]; then
        error "BIOS requirement issues found:"
        for issue in "${issues[@]}"; do
            error "  ✗ $issue"
        done
        echo ""
        warn "These issues WILL prevent P2P from working."
        read -rp "Continue anyway (for testing)? [y/N] " confirm
        [[ "${confirm,,}" == "y" ]] || die "Fix BIOS settings and re-run."
    else
        success "All BIOS requirements look satisfied"
    fi
}

check_already_installed() {
    if [[ -f "$STATE_FILE" ]]; then
        local installed_version
        installed_version=$(grep "^VERSION=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "unknown")
        warn "Tinygrad P2P driver already installed (version: ${installed_version})"
        read -rp "Reinstall? [y/N] " confirm
        [[ "${confirm,,}" == "y" ]] || die "Aborted. Use 'uninstall' first if needed."
    fi
}

# =============================================================================
# Installation
# =============================================================================

backup_existing_modules() {
    header "Backing up existing kernel modules"
    local kernel_ver
    kernel_ver=$(uname -r)
    local module_dir="/lib/modules/${kernel_ver}/kernel/drivers/video"
    # DKMS path
    local dkms_dir="/lib/modules/${kernel_ver}/updates/dkms"

    mkdir -p "$BACKUP_DIR"

    # Save current driver version info
    echo "ORIGINAL_DRIVER=${CURRENT_DRIVER}" > "${BACKUP_DIR}/restore.info"
    echo "KERNEL=${kernel_ver}" >> "${BACKUP_DIR}/restore.info"
    echo "DATE=$(date -u +%Y%m%dT%H%M%SZ)" >> "${BACKUP_DIR}/restore.info"

    # Find and backup existing .ko files
    local backed_up=0
    for mod in "${NVIDIA_MODULES[@]}"; do
        local ko_path
        ko_path=$(find /lib/modules/"${kernel_ver}" -name "${mod}.ko*" 2>/dev/null | head -1 || true)
        if [[ -n "$ko_path" ]]; then
            cp "$ko_path" "${BACKUP_DIR}/" 2>/dev/null || true
            info "Backed up: $ko_path"
            backed_up=$((backed_up + 1))
        fi
    done

    # Also save dkms state
    if command -v dkms &>/dev/null; then
        dkms status 2>/dev/null > "${BACKUP_DIR}/dkms-status.txt" || true
    fi

    success "Backed up $backed_up module(s) to ${BACKUP_DIR}"
}

download_driver_run() {
    header "Downloading NVIDIA driver ${DRIVER_VERSION} (userspace only)"
    local run_file="NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"
    local download_url="https://us.download.nvidia.com/XFree86/Linux-x86_64/${DRIVER_VERSION}/${run_file}"

    mkdir -p "$BUILD_DIR"

    if [[ -f "${BUILD_DIR}/${run_file}" ]]; then
        info "Driver .run already downloaded, skipping."
    else
        info "Downloading from: $download_url"
        wget -q --show-progress -O "${BUILD_DIR}/${run_file}" "$download_url" \
            || die "Download failed. Check driver version or network connectivity."
        chmod +x "${BUILD_DIR}/${run_file}"
    fi
    success "Driver .run ready: ${BUILD_DIR}/${run_file}"
}

install_userspace_driver() {
    header "Installing NVIDIA userspace driver (--no-kernel-modules)"
    info "This installs CUDA libraries, nvidia-smi, etc. but keeps stock kernel modules for now."

    # Remove DKMS nvidia if present to avoid conflicts
    if dkms status 2>/dev/null | grep -q "^nvidia"; then
        warn "Removing existing DKMS nvidia module..."
        local existing_ver
        existing_ver=$(dkms status 2>/dev/null | grep "^nvidia" | head -1 | awk -F'[,/ ]' '{print $2}')
        dkms remove "nvidia/${existing_ver}" --all 2>/dev/null || true
    fi

    "${BUILD_DIR}/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run" \
        --no-kernel-modules \
        --silent \
        --accept-license \
        2>&1 | tee -a "$LOG_FILE" \
        || die "Userspace driver installation failed."

    success "Userspace driver ${DRIVER_VERSION} installed"
}

build_p2p_kernel_modules() {
    header "Building P2P kernel modules from tinygrad fork"
    local repo_dir="${BUILD_DIR}/open-gpu-kernel-modules"

    if [[ -d "$repo_dir" ]]; then
        info "Removing existing repo clone..."
        rm -rf "$repo_dir"
    fi

    info "Cloning branch ${BRANCH} ..."
    git clone --depth=1 --branch "$BRANCH" "$REPO_URL" "$repo_dir" \
        2>&1 | tee -a "$LOG_FILE" \
        || die "Git clone failed. Check network or branch name."

    info "Building kernel modules (this takes a few minutes)..."
    pushd "$repo_dir" > /dev/null
        make modules -j"$(nproc)" \
            2>&1 | tee -a "$LOG_FILE" \
            || die "Build failed. Check kernel headers are installed."
    popd > /dev/null

    success "P2P kernel modules built successfully"
}

install_p2p_kernel_modules() {
    header "Installing P2P kernel modules"
    local repo_dir="${BUILD_DIR}/open-gpu-kernel-modules"
    pushd "$repo_dir" > /dev/null

    # Unload existing modules (best effort - display server may hold some)
    info "Unloading existing NVIDIA kernel modules..."
    for mod in nvidia-drm nvidia-modeset nvidia-uvm nvidia; do
        if lsmod | grep -q "^${mod} "; then
            rmmod "$mod" 2>/dev/null || warn "Could not unload ${mod} (may be in use)"
        fi
    done

    # Install via the repo's install.sh if present, otherwise make modules_install
    if [[ -f "install.sh" ]]; then
        info "Running repo install.sh..."
        bash install.sh 2>&1 | tee -a "$LOG_FILE" \
            || die "install.sh failed"
    else
        info "Running make modules_install..."
        make modules_install -j"$(nproc)" \
            2>&1 | tee -a "$LOG_FILE" \
            || die "modules_install failed"
    fi

    # Update module dependencies
    depmod -a
    popd > /dev/null

    # Write state file for uninstall
    cat > "$STATE_FILE" <<EOF
VERSION=${DRIVER_VERSION}
BRANCH=${BRANCH}
BUILD_DIR=${BUILD_DIR}
BACKUP_DIR=${BACKUP_DIR}
INSTALLED=$(date -u +%Y%m%dT%H%M%SZ)
KERNEL=$(uname -r)
GPU_4090=${HAS_4090}
GPU_5090=${HAS_5090}
EOF

    success "P2P kernel modules installed"
}

pin_driver_version() {
    header "Pinning driver version to prevent apt auto-upgrade"
    # Hold nvidia packages at current version
    local packages
    packages=$(apt-cache show nvidia-driver-* 2>/dev/null | grep "^Package:" | awk '{print $2}' | grep "${DRIVER_VERSION%%.*}" || true)

    if [[ -n "$packages" ]]; then
        for pkg in $packages; do
            apt-mark hold "$pkg" 2>/dev/null && info "Held: $pkg" || true
        done
        success "Driver packages held from auto-upgrade"
    else
        warn "Could not find apt packages to hold. Consider manually pinning driver ${DRIVER_VERSION}."
        warn "Add to /etc/apt/preferences.d/nvidia-hold:"
        warn "  Package: nvidia-*"
        warn "  Pin: version ${DRIVER_VERSION%%.*}.*"
        warn "  Pin-Priority: 1001"
    fi
}

# =============================================================================
# Uninstallation
# =============================================================================

uninstall_p2p_driver() {
    header "Uninstalling tinygrad P2P driver"

    if [[ ! -f "$STATE_FILE" ]]; then
        warn "State file not found at ${STATE_FILE}. P2P driver may not be installed."
        read -rp "Attempt forced uninstall? [y/N] " confirm
        [[ "${confirm,,}" == "y" ]] || die "Aborted."
    fi

    local kernel_ver
    kernel_ver=$(uname -r)

    # Unload P2P modules
    info "Unloading P2P kernel modules..."
    for mod in nvidia-drm nvidia-modeset nvidia-uvm nvidia; do
        if lsmod | grep -q "^${mod} "; then
            rmmod "$mod" 2>/dev/null || warn "Could not unload ${mod}"
        fi
    done

    # Restore backed-up modules if available
    if [[ -d "$BACKUP_DIR" ]] && ls "${BACKUP_DIR}"/*.ko* &>/dev/null 2>&1; then
        info "Restoring backed up kernel modules..."
        local module_dst
        module_dst=$(find /lib/modules/"${kernel_ver}" -name "nvidia.ko*" -exec dirname {} \; 2>/dev/null | head -1 || echo "/lib/modules/${kernel_ver}/kernel/drivers/video")

        for ko in "${BACKUP_DIR}"/*.ko*; do
            cp "$ko" "${module_dst}/" 2>/dev/null && info "Restored: $(basename "$ko")" || warn "Could not restore: $(basename "$ko")"
        done
        depmod -a
        success "Original modules restored"
    else
        warn "No backup modules found. Reinstalling stock NVIDIA driver from apt..."
        local stock_ver
        stock_ver=$(grep "^ORIGINAL_DRIVER=" "${BACKUP_DIR}/restore.info" 2>/dev/null | cut -d= -f2 || echo "")

        if [[ -n "$stock_ver" ]]; then
            apt-get install -y --reinstall "nvidia-kernel-open-${stock_ver%%.*}" 2>/dev/null \
                || apt-get install -y --reinstall nvidia-dkms-* 2>/dev/null \
                || warn "Could not auto-reinstall stock driver. Run: sudo apt-get install --reinstall nvidia-driver-*"
        else
            warn "Could not determine original driver version."
            warn "Manually reinstall with: sudo apt-get install --reinstall nvidia-driver-<version>"
        fi
    fi

    # Remove DKMS registration — read state before we delete it below
    local dkms_name driver_version dkms_src
    dkms_name=$(grep "^DKMS_NAME=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "nvidia-p2p")
    driver_version=$(grep "^VERSION=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "")
    dkms_src=$(grep "^DKMS_SRC=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "")

    if [[ -n "$driver_version" ]] && dkms status 2>/dev/null | grep -q "${dkms_name}/${driver_version}"; then
        info "Removing DKMS registration for ${dkms_name}/${driver_version}..."
        dkms remove "${dkms_name}/${driver_version}" --all 2>/dev/null \
            && success "DKMS entry removed" \
            || warn "DKMS remove failed — may need manual cleanup"
    fi
    [[ -n "$dkms_src" && -d "$dkms_src" ]] && rm -rf "$dkms_src" && info "Removed DKMS source: ${dkms_src}"

    # Unhold packages
    apt-mark unhold nvidia-* 2>/dev/null || true

    # Clean up
    rm -f "$STATE_FILE"
    info "State file removed"

    warn "A reboot is required to complete uninstallation."
    read -rp "Reboot now? [y/N] " confirm
    [[ "${confirm,,}" == "y" ]] && reboot
}

# =============================================================================
# Status & Verification
# =============================================================================

check_status() {
    header "P2P Driver Status"

    if [[ -f "$STATE_FILE" ]]; then
        success "Tinygrad P2P driver is INSTALLED"
        cat "$STATE_FILE" | while IFS='=' read -r k v; do
            info "  ${k}: ${v}"
        done
    else
        warn "Tinygrad P2P driver does NOT appear to be installed"
    fi

    echo ""
    header "Current NVIDIA topology (P2P)"
    nvidia-smi topo -p2p p 2>/dev/null || warn "Could not query P2P topology"

    echo ""
    header "BAR1 Memory Usage"
    nvidia-smi --query-gpu=index,name,bar1.total,bar1.used --format=csv 2>/dev/null || true

    echo ""
    header "Kernel modules in use"
    for mod in "${NVIDIA_MODULES[@]}"; do
        if lsmod | grep -q "^${mod} "; then
            success "  ${mod}: loaded"
        else
            warn "  ${mod}: NOT loaded"
        fi
    done
}

run_p2p_verify() {
    header "Running P2P bandwidth verification"

    # Quick check - does nvidia-smi show P2P capable?
    info "Checking P2P topology..."
    if nvidia-smi topo -p2p p 2>/dev/null | grep -q "OK\|SYS\|NODE\|PHB\|PXB"; then
        local p2p_rows
        p2p_rows=$(nvidia-smi topo -p2p p 2>/dev/null | grep -v "^$\|Legend\|X =\|SYS\|NODE\|PHB\|PXB\|PIX\|NV" | wc -l)
        if nvidia-smi topo -p2p p 2>/dev/null | grep -q "OK"; then
            success "P2P is showing as available between some GPU pairs"
        else
            warn "P2P topology shows no OK pairs — patch may not be active or BIOS settings need checking"
        fi
    fi

    # Try to build and run p2pBandwidthLatencyTest if CUDA samples are available
    local cuda_samples_dir
    cuda_samples_dir=$(find /usr/local -name "p2pBandwidthLatencyTest" 2>/dev/null | head -1 || \
                       find /root -name "p2pBandwidthLatencyTest" 2>/dev/null | head -1 || echo "")

    if [[ -n "$cuda_samples_dir" ]]; then
        info "Found p2pBandwidthLatencyTest, running..."
        "$cuda_samples_dir" 2>&1 | tee -a "$LOG_FILE" || warn "P2P bandwidth test failed"
    else
        warn "p2pBandwidthLatencyTest not found."
        info "To build it:"
        info "  git clone https://github.com/NVIDIA/cuda-samples"
        info "  cd cuda-samples/Samples/5_Domain_Specific/p2pBandwidthLatencyTest"
        info "  make && ./p2pBandwidthLatencyTest"
    fi

    # Quick Python NCCL test if torch is available
    if python3 -c "import torch; assert torch.cuda.device_count() >= 2" &>/dev/null 2>&1; then
        info "Running quick PyTorch P2P check..."
        python3 - <<'PYEOF' 2>&1 | tee -a "$LOG_FILE"
import torch
n = torch.cuda.device_count()
print(f"GPU count: {n}")
for i in range(n):
    for j in range(n):
        if i != j:
            can = torch.cuda.can_device_access_peer(i, j)
            status = "✓ P2P OK" if can else "✗ NO P2P"
            print(f"  GPU{i} → GPU{j}: {status}")
PYEOF
    fi
}

# =============================================================================
# Post-install
# =============================================================================

on_install_failure() {
    error "Install failed — attempting rollback..."

    for mod in nvidia-drm nvidia-modeset nvidia-uvm nvidia; do
        rmmod "$mod" 2>/dev/null || true
    done

    local kernel_ver
    kernel_ver=$(uname -r)
    if [[ -d "$BACKUP_DIR" ]] && ls "${BACKUP_DIR}"/*.ko* &>/dev/null 2>&1; then
        local module_dst
        module_dst=$(find /lib/modules/"${kernel_ver}" -name "nvidia.ko*" -exec dirname {} \; 2>/dev/null | head -1 \
                     || echo "/lib/modules/${kernel_ver}/kernel/drivers/video")
        for ko in "${BACKUP_DIR}"/*.ko*; do
            cp "$ko" "${module_dst}/" 2>/dev/null && warn "Restored: $(basename "$ko")" || true
        done
        depmod -a
        warn "Original modules restored. System should be in its prior state."
    else
        warn "No backup modules found. You may need to reinstall the stock driver manually."
        warn "Run: apt-get install --reinstall nvidia-driver-*"
    fi

    rm -f "$STATE_FILE"

    if dkms status 2>/dev/null | grep -q "nvidia-p2p"; then
        dkms remove "nvidia-p2p/${DRIVER_VERSION}" --all 2>/dev/null || true
    fi

    error "Rollback complete. Check ${LOG_FILE} for details."
    exit 1
}

# =============================================================================
# DKMS Integration
# =============================================================================

register_dkms() {
    header "Registering P2P modules with DKMS"
    local repo_dir="${BUILD_DIR}/open-gpu-kernel-modules"
    local dkms_name="nvidia-p2p"
    local dkms_src="/usr/src/${dkms_name}-${DRIVER_VERSION}"

    # Remove any previous registration
    if dkms status 2>/dev/null | grep -q "${dkms_name}/${DRIVER_VERSION}"; then
        info "Removing previous DKMS registration..."
        dkms remove "${dkms_name}/${DRIVER_VERSION}" --all 2>/dev/null || true
    fi

    info "Copying source to ${dkms_src}..."
    rm -rf "$dkms_src"
    cp -r "$repo_dir" "$dkms_src"

    cat > "${dkms_src}/dkms.conf" <<EOF
PACKAGE_NAME="${dkms_name}"
PACKAGE_VERSION="${DRIVER_VERSION}"
BUILT_MODULE_NAME[0]="nvidia"
BUILT_MODULE_LOCATION[0]="kernel-open/nvidia/"
DEST_MODULE_LOCATION[0]="/kernel/drivers/video/"
BUILT_MODULE_NAME[1]="nvidia-modeset"
BUILT_MODULE_LOCATION[1]="kernel-open/nvidia-modeset/"
DEST_MODULE_LOCATION[1]="/kernel/drivers/video/"
BUILT_MODULE_NAME[2]="nvidia-drm"
BUILT_MODULE_LOCATION[2]="kernel-open/nvidia-drm/"
DEST_MODULE_LOCATION[2]="/kernel/drivers/video/"
BUILT_MODULE_NAME[3]="nvidia-uvm"
BUILT_MODULE_LOCATION[3]="kernel-open/nvidia-uvm/"
DEST_MODULE_LOCATION[3]="/kernel/drivers/video/"
MAKE="make modules -j\$(nproc)"
CLEAN="make clean"
AUTOINSTALL="yes"
EOF

    dkms add "${dkms_name}/${DRIVER_VERSION}" 2>&1 | tee -a "$LOG_FILE" \
        || die "DKMS add failed"
    dkms build "${dkms_name}/${DRIVER_VERSION}" 2>&1 | tee -a "$LOG_FILE" \
        || die "DKMS build failed"
    dkms install "${dkms_name}/${DRIVER_VERSION}" 2>&1 | tee -a "$LOG_FILE" \
        || die "DKMS install failed"

    echo "DKMS_NAME=${dkms_name}" >> "$STATE_FILE"
    echo "DKMS_SRC=${dkms_src}" >> "$STATE_FILE"

    success "DKMS registration complete — modules will auto-rebuild after kernel updates"
}

# =============================================================================
# Kernel staleness check
# =============================================================================

check_kernel_staleness() {
    header "Checking for stale P2P modules"

    if [[ ! -f "$STATE_FILE" ]]; then
        warn "P2P driver does not appear to be installed."
        return 0
    fi

    local installed_kernel current_kernel dkms_name driver_version
    installed_kernel=$(grep "^KERNEL=" "$STATE_FILE" | cut -d= -f2)
    current_kernel=$(uname -r)
    dkms_name=$(grep "^DKMS_NAME=" "$STATE_FILE" | cut -d= -f2 || echo "nvidia-p2p")
    driver_version=$(grep "^VERSION=" "$STATE_FILE" | cut -d= -f2)

    info "Installed for kernel : ${installed_kernel}"
    info "Running kernel       : ${current_kernel}"

    if [[ "$installed_kernel" != "$current_kernel" ]]; then
        warn "Kernel mismatch detected!"

        if dkms status 2>/dev/null | grep "${dkms_name}/${driver_version}" | grep -q "${current_kernel}.*installed"; then
            success "DKMS already rebuilt modules for ${current_kernel} — you're good."
        else
            warn "DKMS has NOT rebuilt for ${current_kernel} yet. Attempting rebuild now..."
            dkms build "${dkms_name}/${driver_version}" -k "${current_kernel}" 2>&1 | tee -a "$LOG_FILE" \
                && dkms install "${dkms_name}/${driver_version}" -k "${current_kernel}" 2>&1 | tee -a "$LOG_FILE" \
                && success "DKMS rebuild successful. Reboot to activate." \
                || error "DKMS rebuild failed. Check ${LOG_FILE}. You may need to re-run install."
        fi

        sed -i "s/^KERNEL=.*/KERNEL=${current_kernel}/" "$STATE_FILE"
    else
        success "Kernel matches — modules are current (${current_kernel})"
    fi

    echo ""
    local all_loaded=true
    for mod in "${NVIDIA_MODULES[@]}"; do
        if lsmod | grep -q "^${mod} "; then
            success "Module loaded: ${mod}"
        else
            warn "Module NOT loaded: ${mod}"
            all_loaded=false
        fi
    done
    $all_loaded || warn "Some modules not loaded. A reboot may be required."

    echo ""
    info "DKMS status:"
    dkms status 2>/dev/null | grep -E "${dkms_name}|nvidia" | while read -r line; do
        info "  $line"
    done
}

post_install_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}${BOLD}║          Tinygrad P2P Driver - Install Complete          ║${RESET}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  Driver version : ${BOLD}${DRIVER_VERSION}${RESET}"
    echo -e "  Branch         : ${BOLD}${BRANCH}${RESET}"
    echo -e "  Build dir      : ${BUILD_DIR}"
    echo -e "  Backup dir     : ${BACKUP_DIR}"
    echo -e "  Log            : ${LOG_FILE}"
    echo ""
    echo -e "${YELLOW}  ⚠  A reboot is required to load the P2P kernel modules.${RESET}"
    echo -e "${YELLOW}  ⚠  After reboot, run:${RESET}"
    echo -e "       sudo bash install-p2p-driver.sh status"
    echo -e "       sudo bash install-p2p-driver.sh verify"
    echo ""
    if $HAS_5090; then
        echo -e "${YELLOW}  ⚠  5090 P2P support is EXPERIMENTAL. Monitor dmesg for Xid errors.${RESET}"
        echo -e "       dmesg -w | grep -i 'NVRM\\|p2p\\|Xid'"
        echo ""
    fi
    echo -e "${CYAN}  To uninstall:${RESET}"
    echo -e "       sudo bash install-p2p-driver.sh uninstall"
    echo ""

    read -rp "Reboot now? [y/N] " confirm
    [[ "${confirm,,}" == "y" ]] && reboot
}

# =============================================================================
# Main
# =============================================================================

usage() {
    echo ""
    echo -e "${BOLD}Usage:${RESET} sudo bash $(basename "$0") <command>"
    echo ""
    echo "  install    Install tinygrad P2P patched NVIDIA driver"
    echo "  uninstall  Restore original stock NVIDIA driver"
    echo "  status     Show P2P driver installation status"
    echo "  verify     Run P2P bandwidth verification tests"
    echo "  check      Detect stale modules after kernel update, auto-rebuild if needed"
    echo ""
    echo "  Before running install, ensure BIOS has:"
    echo "    - Resizable BAR / Large BAR: ENABLED"
    echo "    - IOMMU / VT-d:             DISABLED"
    echo "    - Secure Boot:              DISABLED"
    echo ""
}

mkdir -p "$(dirname "$LOG_FILE")"
echo "=== $(date -u) ===" >> "$LOG_FILE"

case "${1:-}" in
    install)
        check_root
        check_dependencies
        detect_gpu
        check_bios_requirements
        check_already_installed

        # Auto-rollback trap — fires if anything exits non-zero after this point
        INSTALL_STARTED=true
        trap 'on_install_failure' ERR

        backup_existing_modules
        download_driver_run
        install_userspace_driver
        build_p2p_kernel_modules
        install_p2p_kernel_modules
        register_dkms
        pin_driver_version

        trap - ERR  # Clear trap on success
        post_install_summary
        ;;
    uninstall)
        check_root
        uninstall_p2p_driver
        ;;
    status)
        check_status
        ;;
    verify)
        run_p2p_verify
        ;;
    check)
        check_root
        check_kernel_staleness
        ;;
    *)
        usage
        exit 1
        ;;
esac
