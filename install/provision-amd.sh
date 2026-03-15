#!/usr/bin/env bash
# =============================================================================
# provision-amd.sh
# Top-level provisioning orchestrator for AMD GPU nodes
#
# Orchestrates AMD base install and Docker setup across reboots:
#   stage1: amd-base-install.sh  (AMDGPU + ROCm)   -> reboot if needed
#   stage2: docker-install.sh    (Docker only)     -> done
#   stage3: validation           (ROCm + Docker)   -> done
#
# Layout:
#   Scripts: /opt/provision-amd/
#   State:   /opt/provision-amd/state/provision.state
#   Logs:    /opt/provision-amd/logs/provision.log
# =============================================================================

set -euo pipefail

PROVISION_DIR="/opt/provision-amd"
STATE_DIR="${PROVISION_DIR}/state"
LOG_DIR="${PROVISION_DIR}/logs"
LOG_FILE="${LOG_DIR}/provision.log"
JSONL_FILE="${LOG_DIR}/provision.jsonl"
STATE_FILE="${STATE_DIR}/provision.state"
LOG_MAX_RUNS=5

SCRIPT_BASE_INSTALL="${PROVISION_DIR}/amd-base-install.sh"
SCRIPT_DOCKER_INSTALL="${PROVISION_DIR}/docker-install.sh"

RESUME_SERVICE="provision-amd-resume"
RESUME_SERVICE_FILE="/etc/systemd/system/${RESUME_SERVICE}.service"

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

NON_INTERACTIVE=false
WITH_COMPOSE=false
FORCE_VG=""
FORCE_DISK=""
RESET_STATE=false
RESUME=false
SHOW_STATUS=false

usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS]

Orchestrates AMD GPU node provisioning across reboots.

Options:
  --non-interactive     Pass through to sub-scripts; no prompts
  --with-compose        Install Docker Compose (passed to docker-install.sh)
  --vg <vgname>         Pass VG selection to docker-install.sh
  --disk /dev/sdX       Pass disk selection to docker-install.sh
  --reset-state         Wipe provision state and restart from stage1
  --resume              Internal: called by ${RESUME_SERVICE}.service on boot
  --status              Show current provisioning state and exit
  -h, --help            Show this help

Examples:
  sudo $0
  sudo $0 --non-interactive --with-compose
  sudo $0 --non-interactive --vg ubuntu-vg
  sudo $0 --status
EOF
    exit 0
}

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

trap 'error "provision-amd.sh failed at line ${LINENO} — stage=${CURRENT_STAGE}"' ERR

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${RESET} Must be run as root: sudo $0" >&2
    exit 1
fi

mkdir -p "${LOG_DIR}" "${STATE_DIR}"

_rotate_log() {
    local logfile="$1" max_runs="$2"
    [[ -f "$logfile" ]] || return 0
    local delimiter="===== provision-amd.sh started"
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
echo "===== provision-amd.sh started at $(date) =====" >> "$LOG_FILE"
_jlog "info" "INIT" "provision-amd.sh started (resume=${RESUME})"

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
    rm -f "$STATE_FILE" "${STATE_DIR}/docker-install.state" "${STATE_DIR}/.provision_complete"
    if [[ -f "${RESUME_SERVICE_FILE}" ]]; then
        systemctl enable "${RESUME_SERVICE}.service" 2>/dev/null || true
    fi
    info "All state cleared — provisioning will restart from stage1"
fi

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

header "Preflight checks"
CURRENT_STAGE="PREFLIGHT"

missing=0
for script in "$SCRIPT_BASE_INSTALL" "$SCRIPT_DOCKER_INSTALL"; do
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
(( missing > 0 )) && exit 1

install_resume_service() {
    cat > "${RESUME_SERVICE_FILE}" <<UNIT
[Unit]
Description=AMD GPU Node Provisioning Resume
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/opt/provision-amd/state/.provision_complete

[Service]
Type=oneshot
ExecStart=/opt/provision-amd/provision-amd.sh --resume --non-interactive
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

if [[ "$RESUME" == false ]] && [[ ! -f "${RESUME_SERVICE_FILE}" ]]; then
    install_resume_service
fi

DOCKER_ARGS="--called-by-provision --skip-nvidia-toolkit --skip-nouveau-blacklist"
[[ "$NON_INTERACTIVE" == true ]] && DOCKER_ARGS="--non-interactive ${DOCKER_ARGS}"
[[ "$WITH_COMPOSE" == true ]] && DOCKER_ARGS+=" --with-compose"
[[ -n "$FORCE_VG" ]]          && DOCKER_ARGS+=" --vg ${FORCE_VG}"
[[ -n "$FORCE_DISK" ]]        && DOCKER_ARGS+=" --disk ${FORCE_DISK}"

BASE_ARGS=""
[[ "$NON_INTERACTIVE" == true ]] && BASE_ARGS+=" --yes"

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
        error "Stage ${stage} FAILED"
        error "Resume with: sudo ${PROVISION_DIR}/provision-amd.sh --resume"
        error "Or start over with: sudo ${PROVISION_DIR}/provision-amd.sh --reset-state"
        exit 1
    fi
}

do_reboot() {
    local reason="$1"
    warn "Reboot required: ${reason}"
    warn "The ${RESUME_SERVICE} service will continue automatically after reboot"
    _jlog "warn" "$CURRENT_STAGE" "rebooting: ${reason}"
    if [[ "$NON_INTERACTIVE" == false ]] && [[ "$RESUME" == false ]]; then
        confirm "Reboot now?" || {
            warn "Reboot deferred — run 'sudo reboot' then re-run provision-amd.sh to continue"
            exit 0
        }
    fi
    info "Rebooting in 5 seconds..."
    sleep 5
    reboot
}

validate_amd_stack() {
    header "AMD stack validation"
    local failures=0

    if command -v rocm-smi &>/dev/null && rocm-smi &>/dev/null 2>&1; then
        success "rocm-smi operational"
    else
        error "rocm-smi not operational"
        (( failures++ ))
    fi

    if command -v rocminfo &>/dev/null && rocminfo &>/dev/null 2>&1; then
        success "rocminfo operational"
    else
        error "rocminfo not operational"
        (( failures++ ))
    fi

    if command -v rocm-bandwidth-test &>/dev/null || [[ -x /opt/rocm/bin/rocm-bandwidth-test ]]; then
        success "rocm-bandwidth-test available"
    else
        warn "rocm-bandwidth-test not found"
    fi

    if systemctl is-active --quiet docker; then
        success "Docker running"
    else
        error "Docker is not running"
        (( failures++ ))
    fi

    return $(( failures == 0 ? 0 : 1 ))
}

CURRENT_STAGE="stage1_driver"
if ! stage_done "stage1_driver"; then
    run_stage "stage1_driver" "AMDGPU + ROCm Install" "$SCRIPT_BASE_INSTALL" "$BASE_ARGS"
    if ! (command -v rocm-smi &>/dev/null && rocm-smi &>/dev/null 2>&1); then
        do_reboot "AMDGPU/ROCm installed — reboot required to load kernel module"
    fi
fi

CURRENT_STAGE="stage2_docker"
if ! stage_done "stage2_docker"; then
    if ! (command -v rocm-smi &>/dev/null && rocm-smi &>/dev/null 2>&1); then
        error "AMDGPU driver not loaded — did stage1 reboot complete?"
        error "If you rebooted manually, re-run: sudo ${PROVISION_DIR}/provision-amd.sh --resume"
        exit 1
    fi

    run_stage "stage2_docker" "Docker Install (AMD host)" "$SCRIPT_DOCKER_INSTALL" "$DOCKER_ARGS"

    if mountpoint -q /data/container-runtime 2>/dev/null; then
        success "Container runtime volume mounted: $(df -h /data/container-runtime | awk 'NR==2{print $2" total, "$4" free"}')"
        for link in /var/lib/docker /var/lib/containerd; do
            if ! mountpoint -q "$link" 2>/dev/null; then
                error "  ${link} is not a mountpoint — DISK_SETUP may have failed mid-run"
                exit 1
            fi
            src=$(findmnt -n -o SOURCE --target "$link" 2>/dev/null || true)
            case "$link" in
                /var/lib/docker) expected="/data/container-runtime/docker" ;;
                /var/lib/containerd) expected="/data/container-runtime/containerd" ;;
            esac
            if [[ "$src" != "$expected" ]]; then
                error "  ${link} source mismatch — expected ${expected}, got ${src:-'(unknown)'}"
                exit 1
            fi
            success "  ${link} bind-mounted from ${src}"
        done
    else
        warn "No dedicated volume at /data/container-runtime — container runtime is on root"
    fi
fi

CURRENT_STAGE="stage3_validation"
if ! stage_done "stage3_validation"; then
    header "Stage: AMD validation"
    state_set "stage3_validation" "running"
    if validate_amd_stack; then
        state_set "stage3_validation" "complete"
        success "Stage stage3_validation complete"
    else
        state_set "stage3_validation" "failed"
        error "Stage stage3_validation FAILED"
        exit 1
    fi
fi

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
rocm-smi --showproductname 2>/dev/null | grep -v "^$" | sed 's/^/  /' || true
docker version --format '  Docker: Client={{.Client.Version}} Server={{.Server.Engine.Version}}' 2>/dev/null || true
[[ "$WITH_COMPOSE" == true ]] && docker compose version 2>/dev/null | sed 's/^/  /' || true

echo
info "Provision log:  ${LOG_FILE}"
info "JSON log:       ${JSONL_FILE}"

_jlog "success" "COMPLETE" "all stages complete"
