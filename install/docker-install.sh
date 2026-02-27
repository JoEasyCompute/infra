#!/usr/bin/env bash
# =============================================================================
# docker-install.sh
# Installs Docker CE + NVIDIA Container Toolkit on Ubuntu
# Handles automatic disk/LVM detection for /var/lib/docker placement
#
# Part of the /opt/provision provisioning suite.
# State file: /opt/provision/state/docker-install.state
# Log:        /opt/provision/logs/docker-install.log
# JSON log:   /opt/provision/logs/docker-install.jsonl
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Paths & constants
# -----------------------------------------------------------------------------
PROVISION_DIR="/opt/provision"
STATE_DIR="${PROVISION_DIR}/state"
LOG_DIR="${PROVISION_DIR}/logs"
LOG_FILE="${LOG_DIR}/docker-install.log"
JSONL_FILE="${LOG_DIR}/docker-install.jsonl"
STATE_FILE="${STATE_DIR}/docker-install.state"
LOG_MAX_RUNS=3                 # keep last N run blocks in the human log

DOCKER_MOUNT="/var/lib/docker"
LVM_USE_PCT=80
MIN_ROOT_FREE_GB=10
MIN_DOCKER_VOL_GB=50
DAEMON_JSON="/etc/docker/daemon.json"

# Known-good GPG fingerprints
DOCKER_GPG_FP="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
NVIDIA_GPG_FP="EB693B3035CD5710E2317D3F04025462 7A305A5C"  # spaces OK for display

# -----------------------------------------------------------------------------
# Colours & helpers
# -----------------------------------------------------------------------------
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# JSON log helper — writes a structured line to the .jsonl file
_jlog() {
    local level="$1"; local phase="$2"; local msg="$3"
    local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    printf '{"ts":"%s","level":"%s","phase":"%s","host":"%s","msg":"%s"}\n' \
        "$ts" "$level" "$phase" "$(hostname -s)" "$msg" \
        >> "${JSONL_FILE}" 2>/dev/null || true
}

CURRENT_PHASE="INIT"

info()    {
    echo -e "${CYAN}[INFO]${RESET}  $*"  | tee -a "${LOG_FILE}"
    _jlog "info"    "$CURRENT_PHASE" "$*"
}
success() {
    echo -e "${GREEN}[OK]${RESET}    $*"  | tee -a "${LOG_FILE}"
    _jlog "success" "$CURRENT_PHASE" "$*"
}
warn()    {
    echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "${LOG_FILE}"
    _jlog "warn"    "$CURRENT_PHASE" "$*"
}
error()   {
    echo -e "${RED}[ERROR]${RESET} $*"   | tee -a "${LOG_FILE}" >&2
    _jlog "error"   "$CURRENT_PHASE" "$*"
}
header()  {
    echo -e "\n${BOLD}${CYAN}==> $*${RESET}" | tee -a "${LOG_FILE}"
    _jlog "info"    "$CURRENT_PHASE" "==> $*"
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
NON_INTERACTIVE=false
FORCE_DISK=""
FORCE_VG=""
UNINSTALL=false
WITH_COMPOSE=false
RESET_STATE=false
CALLED_BY_PROVISION=false   # set by provision.sh to suppress reboot prompt

usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS]

Options:
  --non-interactive     No prompts; auto-select largest free disk, then largest
                        free VG, then fall back to root partition
  --disk /dev/sdX       Force use of a specific disk
  --vg <vgname>         Force use of a specific LVM VG
  --with-compose        Also install Docker Compose v2 (latest stable)
  --uninstall           Remove Docker, NVIDIA toolkit, Compose and undo mounts
  --reset-state         Clear phase state file and re-run all phases from scratch
  --called-by-provision Internal flag set by provision.sh
  -h, --help            Show this help

Examples:
  sudo $0                                   # interactive install
  sudo $0 --non-interactive                 # fully automated
  sudo $0 --non-interactive --vg ubuntu-vg  # automated, pin VG
  sudo $0 --with-compose                    # install with Compose
  sudo $0 --uninstall                       # clean removal
  sudo $0 --reset-state                     # force full re-run
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive)    NON_INTERACTIVE=true ;;
        --disk)               FORCE_DISK="$2"; shift ;;
        --vg)                 FORCE_VG="$2";   shift ;;
        --with-compose)       WITH_COMPOSE=true ;;
        --uninstall)          UNINSTALL=true ;;
        --reset-state)        RESET_STATE=true ;;
        --called-by-provision) CALLED_BY_PROVISION=true ;;
        -h|--help) usage ;;
        *) echo -e "${RED}[ERROR]${RESET} Unknown argument: $1" >&2; usage ;;
    esac
    shift
done

# confirm() respects --non-interactive
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
# ERR trap
# -----------------------------------------------------------------------------
trap 'error "Script failed at line ${LINENO} — phase=${CURRENT_PHASE} — check ${LOG_FILE}"' ERR

# -----------------------------------------------------------------------------
# Root check & log/state init (must come before any helper calls)
# -----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${RESET} Must be run as root: sudo $0" >&2
    exit 1
fi

mkdir -p "${LOG_DIR}" "${STATE_DIR}"

# -----------------------------------------------------------------------------
# Log rotation — keep last LOG_MAX_RUNS run blocks
# -----------------------------------------------------------------------------
_rotate_log() {
    local logfile="$1"
    [[ -f "$logfile" ]] || return 0
    local delimiter="===== docker-install.sh started"
    local run_count
    run_count=$(grep -c "^${delimiter}" "$logfile" 2>/dev/null || echo 0)
    if (( run_count >= LOG_MAX_RUNS )); then
        # Keep only the last (LOG_MAX_RUNS - 1) runs, then append new run
        local tmp; tmp=$(mktemp)
        awk -v delim="$delimiter" -v keep="$((LOG_MAX_RUNS - 1))" '
            /^===== docker-install\.sh started/ { found++; buf="" }
            { buf = buf $0 "\n" }
            END {
                split(buf, lines, "\n")
                # Re-scan original to get last (keep) blocks
            }
        ' "$logfile" > "$tmp" 2>/dev/null || true
        # Simpler approach: split on delimiter, keep last N-1 blocks
        python3 - "$logfile" "$((LOG_MAX_RUNS - 1))" "$delimiter" <<'PYEOF'
import sys
path, keep_str, delim = sys.argv[1], sys.argv[2], sys.argv[3]
keep = int(keep_str)
with open(path) as f:
    content = f.read()
blocks = content.split(delim)
# blocks[0] is empty or pre-amble, blocks[1:] are actual run blocks
runs = blocks[1:]
kept = runs[-keep:] if len(runs) >= keep else runs
result = delim.join([""] + kept) if kept else ""
with open(path, "w") as f:
    f.write(result.lstrip("\n"))
PYEOF
        rm -f "$tmp"
    fi
}

_rotate_log "$LOG_FILE"
echo "===== docker-install.sh started at $(date) =====" >> "$LOG_FILE"
[[ "$NON_INTERACTIVE" == true ]] && info "Running in non-interactive mode"

# Also rotate the JSONL — keep last LOG_MAX_RUNS*100 lines as a rough bound
if [[ -f "$JSONL_FILE" ]]; then
    local_lines=$(wc -l < "$JSONL_FILE" 2>/dev/null || echo 0)
    max_lines=$(( LOG_MAX_RUNS * 150 ))
    if (( local_lines > max_lines )); then
        tail -n "$max_lines" "$JSONL_FILE" > "${JSONL_FILE}.tmp" \
            && mv "${JSONL_FILE}.tmp" "$JSONL_FILE"
    fi
fi
_jlog "info" "INIT" "docker-install.sh started"

# -----------------------------------------------------------------------------
# State file helpers
# -----------------------------------------------------------------------------
# Phases in execution order
PHASES=(
    DISK_SETUP
    DOCKER_INSTALL
    DAEMON_CONFIG
    COMPOSE_INSTALL
    NVIDIA_TOOLKIT
    NOUVEAU_BLACKLIST
)

state_get() {
    local phase="$1"
    grep "^${phase}=" "${STATE_FILE}" 2>/dev/null | cut -d= -f2 || echo ""
}

state_set() {
    local phase="$1" status="$2"
    # Remove existing entry then append
    if [[ -f "$STATE_FILE" ]]; then
        sed -i "/^${phase}=/d" "$STATE_FILE"
    fi
    echo "${phase}=${status}" >> "$STATE_FILE"
    _jlog "info" "$phase" "state=${status}"
}

phase_done() {
    [[ "$(state_get "$1")" == "complete" ]]
}

# --reset-state wipes the state file
if [[ "$RESET_STATE" == true ]]; then
    rm -f "$STATE_FILE"
    info "State file cleared — all phases will re-run"
fi

# Helper: wrap a phase with state tracking
# Usage: run_phase PHASE_NAME "Description" <function_name>
run_phase() {
    local phase="$1" desc="$2" fn="$3"
    CURRENT_PHASE="$phase"
    if phase_done "$phase"; then
        info "Phase ${phase} already complete — skipping (use --reset-state to re-run)"
        return 0
    fi
    header "${desc}"
    state_set "$phase" "running"
    if "$fn"; then
        state_set "$phase" "complete"
        _jlog "success" "$phase" "phase complete"
    else
        state_set "$phase" "failed"
        error "Phase ${phase} failed — fix the issue and re-run to resume"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# UNINSTALL MODE
# -----------------------------------------------------------------------------
if [[ "$UNINSTALL" == true ]]; then
    CURRENT_PHASE="UNINSTALL"
    header "Uninstall mode"
    warn "This will remove Docker CE, NVIDIA Container Toolkit, Docker Compose,"
    warn "and any volume mounts created by this script under ${DOCKER_MOUNT}."
    warn "All container images, volumes, and data will be DESTROYED."
    confirm "Proceed with full uninstall?" || { info "Aborted."; exit 0; }

    for svc in docker containerd; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            info "Stopping ${svc}..."
            systemctl stop "$svc" || true
            systemctl disable "$svc" || true
        fi
    done

    info "Removing Docker packages..."
    apt-get purge -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin 2>/dev/null || true

    info "Removing NVIDIA Container Toolkit..."
    apt-get purge -y nvidia-container-toolkit nvidia-container-runtime \
        nvidia-docker2 2>/dev/null || true

    apt-get autoremove -y 2>/dev/null || true

    rm -f /etc/apt/sources.list.d/docker.list \
          /etc/apt/sources.list.d/nvidia-container-toolkit.list \
          /etc/apt/keyrings/docker.gpg \
          /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    apt-get update -qq

    rm -f "${DAEMON_JSON}"
    rm -f /usr/local/lib/docker/cli-plugins/docker-compose

    if mountpoint -q "${DOCKER_MOUNT}" 2>/dev/null; then
        warn "Unmounting ${DOCKER_MOUNT}..."
        umount "${DOCKER_MOUNT}" || true
        sed -i "\|${DOCKER_MOUNT}|d" /etc/fstab
        info "Removed fstab entry — underlying disk/LV NOT wiped (manual step)"
    fi

    rm -rf /var/lib/docker /var/lib/containerd /etc/docker
    rm -f /etc/modprobe.d/blacklist-nouveau.conf
    rm -f "$STATE_FILE"

    success "Uninstall complete — reboot recommended"
    exit 0
fi

# -----------------------------------------------------------------------------
# PREFLIGHT
# -----------------------------------------------------------------------------
CURRENT_PHASE="PREFLIGHT"
header "Preflight checks"

if ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
    warn "This script targets Ubuntu. Detected OS:"
    grep PRETTY_NAME /etc/os-release || true
    confirm "Continue anyway?" || exit 1
fi

UBUNTU_CODENAME=$(lsb_release -cs 2>/dev/null || echo "unknown")
success "OS: Ubuntu ${UBUNTU_CODENAME}"

for cmd in curl gpg lsblk df awk sed python3; do
    if ! command -v "$cmd" &>/dev/null; then
        error "Required tool not found: $cmd"
        exit 1
    fi
done
success "Required tools present"

if command -v docker &>/dev/null && [[ "$(state_get DOCKER_INSTALL)" != "complete" ]]; then
    warn "Docker is already installed: $(docker --version)"
    confirm "Re-run installation anyway?" || exit 0
fi

# -----------------------------------------------------------------------------
# HELPERS
# -----------------------------------------------------------------------------
free_gb_on_mount() {
    df -BG "$1" 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4); print $4}' || echo 0
}
lvm_gib_to_int() {
    echo "$1" | awk '{printf "%d", $1}'
}

# GPG fingerprint verification helper
verify_gpg_key() {
    local keyfile="$1" expected_fp="$2" label="$3"
    local actual_fp
    actual_fp=$(gpg --no-default-keyring --keyring "gnupg-ring:${keyfile}" \
        --fingerprint 2>/dev/null \
        | grep -A1 "^pub" | tail -1 | tr -d ' ') || true
    # Normalise: strip spaces from expected
    local expected_norm; expected_norm=$(echo "$expected_fp" | tr -d ' ')
    if [[ -z "$actual_fp" ]]; then
        warn "Could not read fingerprint from ${label} key — skipping verification"
        return 0
    fi
    if [[ "$actual_fp" != *"${expected_norm}"* ]] && \
       [[ "${expected_norm}" != *"${actual_fp}"* ]]; then
        error "${label} GPG key fingerprint mismatch!"
        error "  Expected: ${expected_norm}"
        error "  Got:      ${actual_fp}"
        return 1
    fi
    success "${label} GPG key fingerprint verified"
}

# Compose latest version resolver
get_compose_version() {
    local ver
    ver=$(curl -fsSL --max-time 10 \
        "https://api.github.com/repos/docker/compose/releases/latest" \
        2>/dev/null | grep '"tag_name"' | cut -d'"' -f4) || true
    if [[ -z "$ver" ]]; then
        warn "Could not fetch latest Compose version from GitHub API — falling back to v2.27.1"
        ver="v2.27.1"
    fi
    echo "$ver"
}

# =============================================================================
# PHASE FUNCTIONS
# =============================================================================

# -----------------------------------------------------------------------------
phase_disk_setup() {
# -----------------------------------------------------------------------------
    CURRENT_PHASE="DISK_SETUP"

    # Already on its own mount — nothing to do
    if mountpoint -q "$DOCKER_MOUNT" 2>/dev/null; then
        success "${DOCKER_MOUNT} is already a separate mount — skipping"
        return 0
    fi

    # Detect free disks
    local free_disks=()
    info "Scanning for free disks..."
    while IFS= read -r disk; do
        local children
        children=$(lsblk -no NAME "/dev/${disk}" 2>/dev/null | tail -n +2 | wc -l)
        if [[ "$children" -eq 0 ]]; then
            local size size_gb
            size=$(lsblk -bdno SIZE "/dev/${disk}" 2>/dev/null || echo 0)
            size_gb=$(( size / 1024 / 1024 / 1024 ))
            free_disks+=("/dev/${disk}:${size_gb}GB")
            info "  Free disk: /dev/${disk} (${size_gb} GB)"
        fi
    done < <(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}')

    # Detect free LVM VGs
    local free_vgs=()
    if command -v vgs &>/dev/null; then
        info "Scanning LVM VGs for free space..."
        while IFS= read -r vg_name; do
            local free_str free_gb
            free_str=$(vgdisplay "$vg_name" 2>/dev/null | awk '/Free  PE/{print $5,$6}')
            free_gb=$(lvm_gib_to_int "$free_str")
            if (( free_gb > 0 )); then
                free_vgs+=("${vg_name}:${free_gb}GB")
                info "  VG '${vg_name}': ~${free_gb} GB free"
            fi
        done < <(vgs --noheadings -o vg_name 2>/dev/null | awk '{print $1}')
    fi

    local setup_method="none"
    local selected_disk="" selected_vg=""

    # --- Disk selection ---
    if [[ ${#free_disks[@]} -gt 0 ]]; then
        if [[ "$NON_INTERACTIVE" == true ]] || [[ -n "$FORCE_DISK" ]]; then
            if [[ -n "$FORCE_DISK" ]]; then
                selected_disk="$FORCE_DISK"
            else
                local largest=0
                for entry in "${free_disks[@]}"; do
                    local dev sz sz_num
                    dev="${entry%%:*}"; sz="${entry##*:}"; sz_num="${sz//GB/}"
                    if (( sz_num > largest )); then largest=$sz_num; selected_disk="$dev"; fi
                done
                info "(auto) Selected largest free disk: ${selected_disk} (${largest} GB)"
            fi
            setup_method="disk"
        else
            echo
            echo -e "${BOLD}Free disks available:${RESET}"
            local idx=1
            declare -A disk_map
            for entry in "${free_disks[@]}"; do
                local dev sz; dev="${entry%%:*}"; sz="${entry##*:}"
                echo "  $idx) $dev  ($sz)"
                disk_map[$idx]="$dev"; (( idx++ ))
            done
            echo "  $idx) Skip — use LVM or root instead"
            while true; do
                read -rp "$(echo -e "${YELLOW}Select disk for ${DOCKER_MOUNT} [1-${idx}]: ${RESET}")" choice
                [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= idx )) && break
                warn "Enter a number between 1 and ${idx}"
            done
            if (( choice < idx )); then
                selected_disk="${disk_map[$choice]}"; setup_method="disk"
            fi
        fi
    fi

    # --- LVM VG selection ---
    if [[ "$setup_method" == "none" ]] && [[ ${#free_vgs[@]} -gt 0 ]]; then
        if [[ "$NON_INTERACTIVE" == true ]] || [[ -n "$FORCE_VG" ]]; then
            if [[ -n "$FORCE_VG" ]]; then
                selected_vg="$FORCE_VG"
            else
                local largest=0
                for entry in "${free_vgs[@]}"; do
                    local vg sz sz_num
                    vg="${entry%%:*}"; sz="${entry##*:}"; sz_num="${sz//GB/}"
                    if (( sz_num > largest )); then largest=$sz_num; selected_vg="$vg"; fi
                done
                info "(auto) Selected VG with most free space: ${selected_vg} (${largest} GB)"
            fi
            setup_method="lvm"
        else
            echo
            echo -e "${BOLD}LVM VGs with free space:${RESET}"
            local idx=1
            declare -A vg_map
            for entry in "${free_vgs[@]}"; do
                local vg sz alloc_gb
                vg="${entry%%:*}"; sz="${entry##*:}"
                alloc_gb=$(( ${sz//GB/} * LVM_USE_PCT / 100 ))
                echo "  $idx) $vg  (free: $sz → allocate ~${alloc_gb} GB at ${LVM_USE_PCT}%)"
                vg_map[$idx]="$vg"; (( idx++ ))
            done
            echo "  $idx) Skip — install on root"
            while true; do
                read -rp "$(echo -e "${YELLOW}Select VG for ${DOCKER_MOUNT} [1-${idx}]: ${RESET}")" choice
                [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= idx )) && break
                warn "Enter a number between 1 and ${idx}"
            done
            if (( choice < idx )); then
                selected_vg="${vg_map[$choice]}"; setup_method="lvm"
            fi
        fi
    fi

    # --- Scenario D: root fallback ---
    if [[ "$setup_method" == "none" ]]; then
        warn "No free disks or LVM space — Docker will install on root partition"
        df -h /
        local root_free; root_free=$(free_gb_on_mount /)
        (( root_free < MIN_ROOT_FREE_GB )) && \
            warn "Root only has ${root_free} GB free — may be insufficient"
        confirm "Continue on root partition?" || { info "Aborted."; exit 0; }
        return 0
    fi

    # --- Execute disk setup ---
    local uuid
    if [[ "$setup_method" == "disk" ]]; then
        local existing
        existing=$(lsblk -no NAME "${selected_disk}" | tail -n +2 | wc -l)
        if (( existing > 0 )); then
            warn "${selected_disk} has existing partitions:"
            lsblk "${selected_disk}"
            confirm "Wipe and reformat ${selected_disk}? ALL DATA LOST." || exit 1
        fi
        info "Formatting ${selected_disk} as ext4..."
        mkfs.ext4 -L docker_data -F "${selected_disk}"
        uuid=$(blkid -s UUID -o value "${selected_disk}")

    elif [[ "$setup_method" == "lvm" ]]; then
        local lv_name="docker_data"
        local lv_path="/dev/${selected_vg}/${lv_name}"
        if lvdisplay "${lv_path}" &>/dev/null; then
            warn "LV ${lv_path} already exists"
            confirm "Use existing LV (will reformat)?" || exit 1
        else
            info "Creating LV using ${LVM_USE_PCT}% of free space in ${selected_vg}..."
            lvcreate -l "${LVM_USE_PCT}%FREE" -n "${lv_name}" "${selected_vg}"
        fi
        info "Formatting ${lv_path} as ext4..."
        mkfs.ext4 -L docker_data "${lv_path}"
        uuid=$(blkid -s UUID -o value "${lv_path}")
    fi

    mkdir -p "${DOCKER_MOUNT}"
    if ! grep -q "UUID=${uuid}" /etc/fstab; then
        echo "UUID=${uuid}  ${DOCKER_MOUNT}  ext4  defaults,nofail  0  2" >> /etc/fstab
    else
        info "fstab entry for UUID=${uuid} already present"
    fi
    mount -a

    local vol_free; vol_free=$(free_gb_on_mount "${DOCKER_MOUNT}")
    (( vol_free < MIN_DOCKER_VOL_GB )) && \
        warn "Docker volume only ${vol_free} GB — recommend at least ${MIN_DOCKER_VOL_GB} GB"
    success "Docker volume ready: ${vol_free} GB available at ${DOCKER_MOUNT}"
}

# -----------------------------------------------------------------------------
phase_docker_install() {
# -----------------------------------------------------------------------------
    CURRENT_PHASE="DOCKER_INSTALL"

    info "Adding Docker APT repository..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Verify Docker GPG key fingerprint
    verify_gpg_key "/etc/apt/keyrings/docker.gpg" "$DOCKER_GPG_FP" "Docker"

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    info "Installing docker-ce, docker-ce-cli, containerd.io..."
    apt-get install -y docker-ce docker-ce-cli containerd.io

    systemctl enable --now docker.service
    systemctl enable --now containerd.service
    success "Docker installed: $(docker --version)"

    TARGET_USER="${SUDO_USER:-}"
    if [[ -n "$TARGET_USER" ]]; then
        usermod -aG docker "$TARGET_USER"
        success "Added '${TARGET_USER}' to docker group (re-login required)"
    else
        warn "Could not determine non-root user — run: sudo usermod -aG docker \$USER"
    fi
}

# -----------------------------------------------------------------------------
phase_daemon_config() {
# -----------------------------------------------------------------------------
    CURRENT_PHASE="DAEMON_CONFIG"

    local storage_driver="overlay2"
    if [[ -d "${DOCKER_MOUNT}" ]]; then
        local fs_type
        fs_type=$(df -T "${DOCKER_MOUNT}" | awk 'NR==2{print $2}')
        case "$fs_type" in
            btrfs) storage_driver="btrfs" ;;
            zfs)   storage_driver="zfs" ;;
            *)     storage_driver="overlay2" ;;
        esac
    fi
    info "Storage driver: ${storage_driver}"

    mkdir -p /etc/docker
    [[ -f "${DAEMON_JSON}" ]] && {
        warn "${DAEMON_JSON} already exists — backing up to ${DAEMON_JSON}.bak"
        cp "${DAEMON_JSON}" "${DAEMON_JSON}.bak"
    }

    python3 - <<PYEOF
import json, subprocess, shutil
cfg = {
    "log-driver": "json-file",
    "log-opts": {"max-size": "100m", "max-file": "3"},
    "storage-driver": "${storage_driver}",
    "data-root": "${DOCKER_MOUNT}"
}
if shutil.which("nvidia-smi"):
    try:
        subprocess.check_call(["nvidia-smi"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cfg["default-runtime"] = "nvidia"
    except subprocess.CalledProcessError:
        pass
with open("${DAEMON_JSON}", "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYEOF

    # Validate
    python3 -c "import json; json.load(open('${DAEMON_JSON}'))" \
        && success "daemon.json valid" \
        || { error "daemon.json JSON validation failed"; exit 1; }

    systemctl restart docker
    success "Daemon configured: log-rotation=100m×3, storage=${storage_driver}"
}

# -----------------------------------------------------------------------------
phase_compose_install() {
# -----------------------------------------------------------------------------
    CURRENT_PHASE="COMPOSE_INSTALL"
    [[ "$WITH_COMPOSE" == true ]] || { info "Compose not requested — skipping"; return 0; }

    local compose_version
    compose_version=$(get_compose_version)
    info "Installing Docker Compose ${compose_version}..."

    local compose_arch
    compose_arch=$(dpkg --print-architecture)
    case "$compose_arch" in
        amd64) compose_arch="x86_64" ;;
        arm64) compose_arch="aarch64" ;;
        armhf) compose_arch="armv7" ;;
    esac

    local compose_dir="/usr/local/lib/docker/cli-plugins"
    local compose_bin="${compose_dir}/docker-compose"
    local base_url="https://github.com/docker/compose/releases/download/${compose_version}"
    local compose_url="${base_url}/docker-compose-linux-${compose_arch}"
    local checksum_url="${base_url}/docker-compose-linux-${compose_arch}.sha256"

    mkdir -p "${compose_dir}"
    local tmp_bin; tmp_bin=$(mktemp)
    local tmp_sum; tmp_sum=$(mktemp)

    info "Downloading Docker Compose binary..."
    curl -fsSL "${compose_url}"  -o "${tmp_bin}"
    info "Downloading SHA256 checksum..."
    curl -fsSL "${checksum_url}" -o "${tmp_sum}"

    # Verify checksum
    local expected_sum actual_sum
    expected_sum=$(awk '{print $1}' "${tmp_sum}")
    actual_sum=$(sha256sum "${tmp_bin}" | awk '{print $1}')
    if [[ "$expected_sum" != "$actual_sum" ]]; then
        rm -f "$tmp_bin" "$tmp_sum"
        error "Docker Compose checksum mismatch!"
        error "  Expected: ${expected_sum}"
        error "  Got:      ${actual_sum}"
        return 1
    fi
    success "Docker Compose checksum verified"

    mv "${tmp_bin}" "${compose_bin}"
    chmod +x "${compose_bin}"
    rm -f "$tmp_sum"

    if docker compose version &>/dev/null; then
        success "Docker Compose installed: $(docker compose version)"
    else
        warn "Binary installed but 'docker compose version' failed — check ${compose_bin}"
    fi
}

# -----------------------------------------------------------------------------
phase_nvidia_toolkit() {
# -----------------------------------------------------------------------------
    CURRENT_PHASE="NVIDIA_TOOLKIT"

    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        success "NVIDIA driver: $(nvidia-smi --query-gpu=driver_version \
            --format=csv,noheader | head -1)"
    else
        warn "NVIDIA driver not detected — toolkit will install but GPU containers"
        warn "will not work until driver is installed and host is rebooted"
        if [[ "$NON_INTERACTIVE" == false ]]; then
            confirm "Continue installing NVIDIA Container Toolkit anyway?" || {
                info "Skipping NVIDIA Container Toolkit"
                return 0
            }
        fi
    fi

    info "Adding NVIDIA APT repository..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    verify_gpg_key \
        "/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg" \
        "$NVIDIA_GPG_FP" "NVIDIA"

    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null

    local host_arch; host_arch=$(dpkg --print-architecture)
    sed -i "s/\$(ARCH)/${host_arch}/" /etc/apt/sources.list.d/nvidia-container-toolkit.list

    apt-get update -qq
    apt-get install -y nvidia-container-toolkit

    info "Configuring NVIDIA runtime..."
    nvidia-ctk runtime configure --runtime=docker

    # Patch daemon.json to set default-runtime=nvidia
    if [[ -f "${DAEMON_JSON}" ]]; then
        python3 - <<'PYEOF'
import json
with open('/etc/docker/daemon.json') as f:
    cfg = json.load(f)
cfg['default-runtime'] = 'nvidia'
with open('/etc/docker/daemon.json', 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
PYEOF
        info "Set default-runtime=nvidia in ${DAEMON_JSON}"
    fi

    systemctl restart docker
    success "NVIDIA Container Toolkit installed"
}

# -----------------------------------------------------------------------------
phase_nouveau_blacklist() {
# -----------------------------------------------------------------------------
    CURRENT_PHASE="NOUVEAU_BLACKLIST"

    local blacklist_file="/etc/modprobe.d/blacklist-nouveau.conf"
    if grep -q "blacklist nouveau" "$blacklist_file" 2>/dev/null; then
        info "Nouveau already blacklisted — skipping"
        return 0
    fi
    echo "blacklist nouveau"        >> "$blacklist_file"
    echo "options nouveau modeset=0" >> "$blacklist_file"
    update-initramfs -u
    success "Nouveau blacklisted — reboot required to take effect"
}

# =============================================================================
# MAIN — run phases
# =============================================================================
run_phase "DISK_SETUP"        "Disk & volume setup"              phase_disk_setup
run_phase "DOCKER_INSTALL"    "Installing Docker CE"             phase_docker_install
run_phase "DAEMON_CONFIG"     "Configuring Docker daemon"        phase_daemon_config
run_phase "COMPOSE_INSTALL"   "Installing Docker Compose"        phase_compose_install
run_phase "NVIDIA_TOOLKIT"    "Installing NVIDIA Container Toolkit" phase_nvidia_toolkit
run_phase "NOUVEAU_BLACKLIST" "Blacklisting Nouveau driver"      phase_nouveau_blacklist

# =============================================================================
# POST-INSTALL VALIDATION
# =============================================================================
CURRENT_PHASE="VALIDATION"
header "Post-install validation"

info "Running hello-world container..."
if docker run --rm hello-world &>/dev/null; then
    success "docker run hello-world — OK"
else
    warn "hello-world failed — check: journalctl -u docker"
fi

if nvidia-ctk --version &>/dev/null; then
    success "nvidia-ctk: $(nvidia-ctk --version 2>&1 | head -1)"
else
    warn "nvidia-ctk not in PATH"
fi

if [[ "$WITH_COMPOSE" == true ]] && docker compose version &>/dev/null; then
    success "docker compose: $(docker compose version)"
fi

# =============================================================================
# SUMMARY
# =============================================================================
CURRENT_PHASE="SUMMARY"
header "Installation Summary"

echo
echo -e "${BOLD}Docker:${RESET}"
docker version --format \
    '  Client: {{.Client.Version}}  |  Server: {{.Server.Engine.Version}}' \
    2>/dev/null || true

[[ "$WITH_COMPOSE" == true ]] && {
    echo -e "${BOLD}Docker Compose:${RESET}"
    docker compose version 2>/dev/null | sed 's/^/  /' || echo "  (not available)"
}

echo -e "${BOLD}Daemon config:${RESET}"
sed 's/^/  /' "${DAEMON_JSON}" 2>/dev/null || echo "  (not found)"

echo -e "${BOLD}Storage layout:${RESET}"
df -h "${DOCKER_MOUNT}" / | awk 'NR==1{print "  "$0} NR>1{print "  "$0}'

echo -e "${BOLD}Phase state:${RESET}"
for phase in "${PHASES[@]}"; do
    local_status=$(state_get "$phase")
    echo "  ${phase}: ${local_status:-not run}"
done

echo
TARGET_USER="${SUDO_USER:-}"
[[ -n "$TARGET_USER" ]] && \
    warn "ACTION: Re-login as '${TARGET_USER}' to use Docker without sudo"

if ! lsmod | grep -q "^nvidia " 2>/dev/null; then
    warn "ACTION: Reboot required to load NVIDIA driver / apply nouveau blacklist"
fi

echo
success "docker-install.sh complete"
info "Log:       ${LOG_FILE}"
info "JSON log:  ${JSONL_FILE}"
info "State:     ${STATE_FILE}"

_jlog "success" "SUMMARY" "docker-install.sh complete"
