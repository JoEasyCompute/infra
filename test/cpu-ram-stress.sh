#!/usr/bin/env bash
# =============================================================================
# cpu-ram-stress.sh — CPU + RAM isolation stress test using stress-ng
# Designed to help isolate host stability issues away from GPU workloads.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

MINUTES=5
SECONDS_OVERRIDE=""
CPU_WORKERS=""
VM_WORKERS=2
RESERVE_GB=""
NO_INSTALL=false
LOG_DIR="/tmp/cpu_ram_stress_$(date +%Y%m%d_%H%M%S)"
LOG_FILE=""

log()  { echo -e "${CYAN}[INFO]${RESET} $*"; }
pass() { echo -e "${GREEN}[PASS]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; }
die()  { echo -e "${RED}FATAL:${RESET} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }

usage() {
    cat <<EOF
cpu-ram-stress.sh — CPU + RAM stress isolation test

Runs stress-ng with CPU workers and VM workers only, so you can separate host
instability from GPU-related issues.

USAGE:
  ./cpu-ram-stress.sh [OPTIONS]

OPTIONS:
  --minutes MIN        Run duration in minutes [default: 5]
  --seconds SEC        Override run duration in seconds
  --cpu-workers N      CPU worker count [default: number of online CPUs]
  --vm-workers N       RAM/VM worker count [default: 2]
  --reserve-gb GB      Leave this much RAM free for the OS [default: max(4 GiB, 10% of RAM)]
  --log-dir DIR       Directory for log output [default: /tmp/cpu_ram_stress_*]
  --no-install        Do not auto-install stress-ng if it is missing
  -h, --help          Show this help

NOTES:
  - VM workers share the remaining RAM budget after the reserve is applied.
  - The script uses stress-ng's metrics brief output and returns non-zero if the
    stress run fails.

EXAMPLES:
  sudo ./cpu-ram-stress.sh
  sudo ./cpu-ram-stress.sh --minutes 15
  sudo ./cpu-ram-stress.sh --cpu-workers 8 --vm-workers 4 --reserve-gb 6
EOF
    exit 0
}

have() { command -v "$1" >/dev/null 2>&1; }

require_positive_int() {
    local value="$1" label="$2"
    [[ "$value" =~ ^[0-9]+$ ]] || die "$label must be a positive integer"
    (( value > 0 )) || die "$label must be greater than zero"
}

pkg_install_hint() {
    if have apt-get; then
        echo "sudo apt-get update && sudo apt-get install -y stress-ng"
    elif have dnf; then
        echo "sudo dnf install -y stress-ng"
    elif have yum; then
        echo "sudo yum install -y stress-ng"
    elif have zypper; then
        echo "sudo zypper install -y stress-ng"
    elif have pacman; then
        echo "sudo pacman -Sy --noconfirm stress-ng"
    else
        echo "Install stress-ng using your package manager"
    fi
}

auto_install_stress_ng() {
    local cmd=""
    if have apt-get; then
        cmd="apt-get update -qq && apt-get install -y stress-ng"
    elif have dnf; then
        cmd="dnf install -y stress-ng"
    elif have yum; then
        cmd="yum install -y stress-ng"
    elif have zypper; then
        cmd="zypper install -y stress-ng"
    elif have pacman; then
        cmd="pacman -Sy --noconfirm stress-ng"
    fi

    [[ -n "$cmd" ]] || die "stress-ng is missing. $(pkg_install_hint)"
    [[ $EUID -eq 0 ]] || die "stress-ng is missing and auto-install requires root. $(pkg_install_hint)"

    header "Installing stress-ng"
    eval "$cmd"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --minutes)     MINUTES="$2"; shift 2 ;;
        --seconds)     SECONDS_OVERRIDE="$2"; shift 2 ;;
        --cpu-workers) CPU_WORKERS="$2"; shift 2 ;;
        --vm-workers)   VM_WORKERS="$2"; shift 2 ;;
        --reserve-gb)   RESERVE_GB="$2"; shift 2 ;;
        --log-dir)      LOG_DIR="$2"; shift 2 ;;
        --no-install)   NO_INSTALL=true; shift ;;
        -h|--help)      usage ;;
        *) die "Unknown option: $1" ;;
    esac
done

require_positive_int "$MINUTES" "--minutes"
[[ -z "$SECONDS_OVERRIDE" ]] || require_positive_int "$SECONDS_OVERRIDE" "--seconds"
[[ -z "$CPU_WORKERS" ]] || require_positive_int "$CPU_WORKERS" "--cpu-workers"
require_positive_int "$VM_WORKERS" "--vm-workers"

mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/cpu_ram_stress_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)

trap 'warn "Interrupted"; exit 130' INT TERM

header "CPU + RAM Stress"
log "Log file: ${LOG_FILE}"

TOTAL_RAM_MB=$(awk '/MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)
(( TOTAL_RAM_MB > 1024 )) || die "Unable to determine total system RAM"

if [[ -z "$RESERVE_GB" ]]; then
    RESERVE_MB=$(( TOTAL_RAM_MB / 10 ))
    (( RESERVE_MB < 4096 )) && RESERVE_MB=4096
else
    require_positive_int "$RESERVE_GB" "--reserve-gb"
    RESERVE_MB=$(( RESERVE_GB * 1024 ))
fi

TEST_MEM_MB=$(( TOTAL_RAM_MB - RESERVE_MB ))
(( TEST_MEM_MB > 0 )) || die "Reserve leaves no memory for stress testing"

VM_PER_WORKER_MB=$(( TEST_MEM_MB / VM_WORKERS ))
(( VM_PER_WORKER_MB >= 512 )) || die "Requested VM pressure is too low; reduce --vm-workers or --reserve-gb"

if ! have stress-ng; then
    if [[ "$NO_INSTALL" == true ]]; then
        die "stress-ng not found. $(pkg_install_hint)"
    fi
    auto_install_stress_ng
fi

if [[ -z "$CPU_WORKERS" ]]; then
    CPU_WORKERS=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)
fi

DURATION_SECS=$(( MINUTES * 60 ))
[[ -n "$SECONDS_OVERRIDE" ]] && DURATION_SECS="$SECONDS_OVERRIDE"

log "Detected RAM:       $(( TOTAL_RAM_MB / 1024 )) GiB"
log "Reserve for OS:     $(( RESERVE_MB / 1024 )) GiB"
log "Target RAM:         $(( TEST_MEM_MB / 1024 )) GiB"
log "CPU workers:        $CPU_WORKERS"
log "VM workers:         $VM_WORKERS"
log "VM bytes/worker:    ${VM_PER_WORKER_MB}M"
log "Duration:           ${DURATION_SECS}s"

header "Running stress-ng"
rc=0
stress-ng \
    --cpu "$CPU_WORKERS" \
    --cpu-method all \
    --vm "$VM_WORKERS" \
    --vm-bytes "${VM_PER_WORKER_MB}M" \
    --vm-method all \
    --vm-keep \
    --timeout "${DURATION_SECS}s" \
    --metrics-brief \
    2>&1 | tee -a "$LOG_FILE" || rc=$?

if [[ "$rc" -eq 0 ]]; then
    pass "CPU + RAM stress completed successfully"
    exit 0
fi

fail "stress-ng exited with code $rc"
exit "$rc"
