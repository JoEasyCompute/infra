#!/usr/bin/env bash
# =============================================================================
# provision.sh
# Top-level provisioning orchestrator for GPU nodes
#
# Orchestrates three stages across reboots:
#   stage1: base-install.sh  (NVIDIA driver install)         → reboot
#   stage2: docker-install.sh (Docker + toolkit)             → reboot if needed
#   stage3: fulltest.sh       (GPU validation suite)         → done
#
# Layout:
#   Scripts:    /opt/provision/
#   State:      /opt/provision/state/provision.state
#   Logs:       /opt/provision/logs/provision.log
#               /opt/provision/logs/provision.jsonl
#
# Usage:
#   sudo /opt/provision/provision.sh [OPTIONS]
#
# On first run, installs a systemd one-shot service
# (provision-resume.service) that auto-resumes after each reboot.
# The service disables itself once stage3 completes.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
PROVISION_DIR="/opt/provision"
STATE_DIR="${PROVISION_DIR}/state"
LOG_DIR="${PROVISION_DIR}/logs"
LOG_FILE="${LOG_DIR}/provision.log"
JSONL_FILE="${LOG_DIR}/provision.jsonl"
STATE_FILE="${STATE_DIR}/provision.state"
LOG_MAX_RUNS=5

SCRIPT_BASE_INSTALL="${PROVISION_DIR}/base-install.sh"
SCRIPT_DOCKER_INSTALL="${PROVISION_DIR}/docker-install.sh"
SCRIPT_FULLTEST="${PROVISION_DIR}/fulltest.sh"

RESUME_SERVICE="provision-resume"
RESUME_SERVICE_FILE="/etc/systemd/system/${RESUME_SERVICE}.service"

# -----------------------------------------------------------------------------
# Colours & helpers
# -----------------------------------------------------------------------------
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

_jlog() {
    local level="$1" stage="$2" msg="$3"
    local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    printf '{"ts":"%s","level":"%s","stage":"%s","host":"%s","msg":"%s"}\n' \
        "$ts" "$level" "$stage" "$(hostname -s)" "$msg" \
        >> "${JSONL_FILE}" 2>/dev/null || true
}

CURRENT_STAGE="INIT"

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"  | tee -a "${LOG_FILE}"; _jlog "info"    "$CURRENT_STAGE" "$*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"  | tee -a "${LOG_FILE}"; _jlog "success" "$CURRENT_STAGE" "$*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "${LOG_FILE}"; _jlog "warn"    "$CURRENT_STAGE" "$*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"   | tee -a "${LOG_FILE}" >&2; _jlog "error" "$CURRENT_STAGE" "$*"; }
header()  { echo -e "\n${BOLD}${CYAN}==> $*${RESET}" | tee -a "${LOG_FILE}"; _jlog "info" "$CURRENT_STAGE" "==> $*"; }

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
NON_INTERACTIVE=false
WITH_COMPOSE=false
FORCE_VG=""
FORCE_DISK=""
RESET_STATE=false
RESUME=false        # set internally by the systemd resume service

usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS]

Orchestrates full GPU node provisioning across reboots.

Options:
  --non-interactive     Pass through to sub-scripts; no prompts
  --with-compose        Install Docker Compose (passed to docker-install.sh)
  --vg <vgname>         Pass VG selection to docker-install.sh
  --disk /dev/sdX       Pass disk selection to docker-install.sh
  --reset-state         Wipe provision state and restart from stage1
  --resume              Internal: called by provision-resume.service on boot
  --status              Show current provisioning state and exit
  -h, --help            Show this help

Examples:
  sudo $0                           # interactive full provision
  sudo $0 --non-interactive         # automated (cloud-init / Ansible)
  sudo $0 --non-interactive --with-compose --vg ubuntu-vg
  sudo $0 --status                  # check progress
  sudo $0 --reset-state             # start over
EOF
    exit 0
}

SHOW_STATUS=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE=true ;;
        --with-compose)    WITH_COMPOSE=true ;;
        --vg)              FORCE_VG="$2"; shift ;;
        --disk)            FORCE_DISK="$2"; shift ;;
        --reset-state)     RESET_STATE=true ;;
        --resume)          RESUME=true ;;
        --status)          SHOW_STATUS=true ;;
        -h|--help) usage ;;
        *) echo -e "${RED}[ERROR]${RESET} Unknown argument: $1" >&2; usage ;;
    esac
    shift
done

confirm() {
    local prompt="${1:-Continue?}"
    if [[ "$NON_INTERACTIVE" == true ]] || [[ "$RESUME" == true ]]; then
        info "(auto) Confirming: ${prompt}"
        return 0
    fi
    read -rp "$(echo -e "${YELLOW}${prompt} [y/N] ${RESET}")" answer
    [[ "${answer,,}" == "y" ]]
}

# -----------------------------------------------------------------------------
# ERR trap
# -----------------------------------------------------------------------------
trap 'error "provision.sh failed at line ${LINENO} — stage=${CURRENT_STAGE}"' ERR

# -----------------------------------------------------------------------------
# Root check & init
# -----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${RESET} Must be run as root: sudo $0" >&2
    exit 1
fi

mkdir -p "${LOG_DIR}" "${STATE_DIR}"

# Log rotation
_rotate_log() {
    local logfile="$1" max_runs="$2"
    [[ -f "$logfile" ]] || return 0
    local delimiter="===== provision.sh started"
    local run_count
    run_count=$(grep -c "^${delimiter}" "$logfile" 2>/dev/null || echo 0)
    if (( run_count >= max_runs )); then
        python3 - "$logfile" "$((max_runs - 1))" "$delimiter" <<'PYEOF'
import sys
path, keep_str, delim = sys.argv[1], sys.argv[2], sys.argv[3]
keep = int(keep_str)
with open(path) as f:
    content = f.read()
blocks = content.split(delim)
runs = blocks[1:]
kept = runs[-keep:] if len(runs) >= keep else runs
result = delim.join([""] + kept) if kept else ""
with open(path, "w") as f:
    f.write(result.lstrip("\n"))
PYEOF
    fi
}

_rotate_log "$LOG_FILE" "$LOG_MAX_RUNS"
echo "===== provision.sh started at $(date) =====" >> "$LOG_FILE"
_jlog "info" "INIT" "provision.sh started (resume=${RESUME})"

# -----------------------------------------------------------------------------
# State helpers
# -----------------------------------------------------------------------------
STAGES=(stage1_driver stage2_docker stage3_validation)

state_get() {
    grep "^${1}=" "${STATE_FILE}" 2>/dev/null | cut -d= -f2 || echo ""
}

state_set() {
    [[ -f "$STATE_FILE" ]] && sed -i "/^${1}=/d" "$STATE_FILE"
    echo "${1}=${2}" >> "$STATE_FILE"
    _jlog "info" "$1" "state=${2}"
}

stage_done() { [[ "$(state_get "$1")" == "complete" ]]; }

if [[ "$RESET_STATE" == true ]]; then
    rm -f "$STATE_FILE"
    # Also reset sub-script states
    rm -f "${STATE_DIR}/docker-install.state"
    info "All state cleared — provisioning will restart from stage1"
fi

# -----------------------------------------------------------------------------
# --status mode
# -----------------------------------------------------------------------------
if [[ "$SHOW_STATUS" == true ]]; then
    header "Provisioning Status"
    echo -e "${BOLD}Host:${RESET}  $(hostname -s)"
    echo -e "${BOLD}Date:${RESET}  $(date)"
    echo
    for stage in "${STAGES[@]}"; do
        local_status=$(state_get "$stage")
        case "$local_status" in
            complete) echo -e "  ${GREEN}✓${RESET} ${stage}: complete" ;;
            running)  echo -e "  ${YELLOW}~${RESET} ${stage}: running" ;;
            failed)   echo -e "  ${RED}✗${RESET} ${stage}: FAILED" ;;
            *)        echo -e "  ${CYAN}-${RESET} ${stage}: not started" ;;
        esac
    done
    echo
    # Docker install sub-state
    if [[ -f "${STATE_DIR}/docker-install.state" ]]; then
        echo -e "${BOLD}Docker install phases:${RESET}"
        while IFS='=' read -r k v; do
            case "$v" in
                complete) echo -e "  ${GREEN}✓${RESET} ${k}" ;;
                failed)   echo -e "  ${RED}✗${RESET} ${k}: FAILED" ;;
                running)  echo -e "  ${YELLOW}~${RESET} ${k}: running" ;;
                *)        echo -e "  ${CYAN}-${RESET} ${k}" ;;
            esac
        done < "${STATE_DIR}/docker-install.state"
    fi
    echo
    info "Log:      ${LOG_FILE}"
    info "JSON log: ${JSONL_FILE}"
    exit 0
fi

# -----------------------------------------------------------------------------
# Script existence checks
# -----------------------------------------------------------------------------
header "Preflight checks"
CURRENT_STAGE="PREFLIGHT"

missing=0
for script in "$SCRIPT_BASE_INSTALL" "$SCRIPT_DOCKER_INSTALL" "$SCRIPT_FULLTEST"; do
    if [[ ! -f "$script" ]]; then
        error "Script not found: $script"
        (( missing++ ))
    elif [[ ! -x "$script" ]]; then
        error "Script not executable: $script (run: chmod +x $script)"
        (( missing++ ))
    else
        success "Found: $script"
    fi
done
(( missing > 0 )) && {
    error "${missing} script(s) missing from ${PROVISION_DIR}"
    error "Copy all scripts to ${PROVISION_DIR} and chmod +x them before running"
    exit 1
}

# -----------------------------------------------------------------------------
# Resume service installer
# Installs a systemd one-shot that re-calls provision.sh --resume on boot
# The service is enabled now and disables itself after stage3 completes
# -----------------------------------------------------------------------------
install_resume_service() {
    cat > "${RESUME_SERVICE_FILE}" <<UNIT
[Unit]
Description=GPU Node Provisioning Resume
After=network-online.target
Wants=network-online.target
# Only run if provisioning is not yet complete
ConditionPathExists=!/opt/provision/state/.provision_complete

[Service]
Type=oneshot
ExecStart=/opt/provision/provision.sh --resume --non-interactive
StandardOutput=journal
StandardError=journal
TimeoutStartSec=3600
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable "${RESUME_SERVICE}.service"
    success "Resume service installed and enabled (${RESUME_SERVICE_FILE})"
}

mark_provision_complete() {
    touch "${STATE_DIR}/.provision_complete"
    systemctl disable "${RESUME_SERVICE}.service" 2>/dev/null || true
    rm -f "${RESUME_SERVICE_FILE}"
    systemctl daemon-reload
    success "Provisioning complete — resume service disabled"
}

# Install resume service on first run (not on --resume calls)
if [[ "$RESUME" == false ]] && [[ ! -f "${RESUME_SERVICE_FILE}" ]]; then
    install_resume_service
fi

# -----------------------------------------------------------------------------
# Build sub-script argument strings
# -----------------------------------------------------------------------------
DOCKER_ARGS="--non-interactive --called-by-provision"
[[ "$WITH_COMPOSE" == true ]] && DOCKER_ARGS+=" --with-compose"
[[ -n "$FORCE_VG" ]]          && DOCKER_ARGS+=" --vg ${FORCE_VG}"
[[ -n "$FORCE_DISK" ]]        && DOCKER_ARGS+=" --disk ${FORCE_DISK}"

BASE_ARGS=""
[[ "$NON_INTERACTIVE" == true ]] && BASE_ARGS+=" --non-interactive"

FULLTEST_ARGS=""
[[ "$NON_INTERACTIVE" == true ]] && FULLTEST_ARGS+=" --non-interactive"

# Helper: run a stage with state tracking
run_stage() {
    local stage="$1" desc="$2" script="$3" args="$4"
    CURRENT_STAGE="$stage"

    if stage_done "$stage"; then
        info "Stage ${stage} already complete — skipping"
        return 0
    fi

    header "Stage: ${desc}"
    state_set "$stage" "running"

    # shellcheck disable=SC2086
    if bash "$script" $args; then
        state_set "$stage" "complete"
        success "Stage ${stage} complete"
    else
        state_set "$stage" "failed"
        error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        error "Stage ${stage} FAILED"
        error "Fix the issue, then resume with:"
        error "  sudo ${PROVISION_DIR}/provision.sh --resume"
        error "Or start over with:"
        error "  sudo ${PROVISION_DIR}/provision.sh --reset-state"
        error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Reboot helper — schedules reboot and exits cleanly
# The resume service will re-enter provision.sh after boot
# -----------------------------------------------------------------------------
do_reboot() {
    local reason="$1"
    warn "Reboot required: ${reason}"
    warn "The provision-resume service will continue automatically after reboot"
    _jlog "warn" "$CURRENT_STAGE" "rebooting: ${reason}"

    if [[ "$NON_INTERACTIVE" == false ]] && [[ "$RESUME" == false ]]; then
        confirm "Reboot now?" || {
            warn "Reboot deferred — run 'sudo reboot' then re-run provision.sh to continue"
            exit 0
        }
    fi

    info "Rebooting in 5 seconds..."
    sleep 5
    reboot
}

# -----------------------------------------------------------------------------
# STAGE 1 — Driver install (base-install.sh)
# -----------------------------------------------------------------------------
CURRENT_STAGE="stage1_driver"
if ! stage_done "stage1_driver"; then
    run_stage "stage1_driver" "NVIDIA Driver Install" \
        "$SCRIPT_BASE_INSTALL" "$BASE_ARGS"

    # After driver install, a reboot is required to load the driver
    do_reboot "NVIDIA driver installed — must reboot to load kernel module"
    # execution stops here; resume service picks up after reboot
fi

# -----------------------------------------------------------------------------
# STAGE 2 — Docker + NVIDIA toolkit (docker-install.sh)
# -----------------------------------------------------------------------------
CURRENT_STAGE="stage2_docker"
if ! stage_done "stage2_docker"; then
    # Verify driver loaded before proceeding
    if ! command -v nvidia-smi &>/dev/null || ! nvidia-smi &>/dev/null; then
        error "NVIDIA driver not loaded — did stage1 reboot complete?"
        error "If you rebooted manually, re-run: sudo ${PROVISION_DIR}/provision.sh --resume"
        exit 1
    fi
    success "NVIDIA driver loaded: $(nvidia-smi --query-gpu=driver_version \
        --format=csv,noheader | head -1)"

    run_stage "stage2_docker" "Docker + NVIDIA Toolkit Install" \
        "$SCRIPT_DOCKER_INSTALL" "$DOCKER_ARGS"

    # Reboot if nouveau was blacklisted (initramfs updated)
    if grep -q "blacklist nouveau" /etc/modprobe.d/blacklist-nouveau.conf 2>/dev/null \
       && lsmod | grep -q "^nouveau " 2>/dev/null; then
        do_reboot "nouveau blacklisted — must reboot to apply"
    fi
fi

# -----------------------------------------------------------------------------
# STAGE 3 — GPU validation (fulltest.sh)
# -----------------------------------------------------------------------------
CURRENT_STAGE="stage3_validation"
if ! stage_done "stage3_validation"; then
    # Verify Docker is running before validation
    if ! systemctl is-active --quiet docker; then
        error "Docker is not running — stage2 may not have completed correctly"
        exit 1
    fi

    run_stage "stage3_validation" "GPU Validation Suite" \
        "$SCRIPT_FULLTEST" "$FULLTEST_ARGS"
fi

# -----------------------------------------------------------------------------
# ALL STAGES COMPLETE
# -----------------------------------------------------------------------------
CURRENT_STAGE="COMPLETE"
header "Provisioning Complete"

mark_provision_complete

echo
echo -e "${BOLD}${GREEN}All stages complete on $(hostname -s)${RESET}"
echo
echo -e "${BOLD}Stage summary:${RESET}"
for stage in "${STAGES[@]}"; do
    echo -e "  ${GREEN}✓${RESET} ${stage}: $(state_get "$stage")"
done

echo
echo -e "${BOLD}System:${RESET}"
if command -v nvidia-smi &>/dev/null; then
    nvidia-smi --query-gpu=name,driver_version,memory.total \
        --format=csv,noheader | sed 's/^/  GPU: /'
fi
docker version --format \
    '  Docker: Client={{.Client.Version}} Server={{.Server.Engine.Version}}' \
    2>/dev/null || true
[[ "$WITH_COMPOSE" == true ]] && \
    docker compose version 2>/dev/null | sed 's/^/  /' || true

echo
info "Provision log:  ${LOG_FILE}"
info "JSON log:       ${JSONL_FILE}"
info "Full test logs: ${LOG_DIR}/fulltest*.log"

_jlog "success" "COMPLETE" "all stages complete"
