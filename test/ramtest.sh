#!/usr/bin/env bash
# =============================================================================
# ramtest.sh — Server RAM validation using stressapptest
# Designed for post-provision burn-in on Linux hosts.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

MODE="full"                # quick | full | burn
DURATION=3600              # seconds
RESERVE_MB=""             # auto = max(4 GiB, 10% of RAM)
TEST_MEM_MB=""            # explicit override
MEM_GB_INPUT=""
RESERVE_GB_INPUT=""
THREADS=""                # auto = min(nproc, 8)
LOG_DIR="/tmp/ramtest_$(date +%Y%m%d_%H%M%S)"
NO_INSTALL=false
STOP_ON_ERROR=true
VERBOSITY=8
STRESS_BIN=""
TOTAL_RAM_MB=0
ECC_BEFORE_CE=0
ECC_BEFORE_UE=0
ECC_AFTER_CE=0
ECC_AFTER_UE=0
EDAC_SUPPORTED=false

log()    { echo -e "${CYAN}[$(date +%H:%M:%S)]${RESET} $*"; }
pass()   { echo -e "${GREEN}[PASS]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET} $*"; }
fail()   { echo -e "${RED}[FAIL]${RESET} $*"; }
die()    { echo -e "${RED}FATAL:${RESET} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }

usage() {
    printf '%b' "$(cat <<EOF2
${BOLD}ramtest.sh${RESET} — Server RAM validation with stressapptest

${BOLD}USAGE:${RESET}
  ./ramtest.sh [OPTIONS]

${BOLD}MODES:${RESET}
  --quick             15-minute qualification run
  --full              60-minute burn-in [default]
  --burn              4-hour extended burn-in

${BOLD}SIZING:${RESET}
  --duration SEC      Override runtime in seconds
  --mem-gb GB         Test this much RAM in GiB
  --reserve-gb GB     Leave this much RAM free for the OS
  --threads N         stressapptest copy/invert/CPU thread count [default: min(nproc, 8)]

${BOLD}BEHAVIOR:${RESET}
  --log-dir DIR       Directory for logs [default: /tmp/ramtest_*]
  --no-install        Do not auto-install stressapptest if missing
  --keep-going        Continue after errors instead of stopping on first error
  -h, --help          Show this help

${BOLD}EXAMPLES:${RESET}
  sudo ./ramtest.sh --quick
  sudo ./ramtest.sh --full --reserve-gb 8
  sudo ./ramtest.sh --burn --mem-gb 240 --threads 8
EOF2
)"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick)       MODE="quick"; DURATION=900 ;;
        --full)        MODE="full";  DURATION=3600 ;;
        --burn)        MODE="burn";  DURATION=14400 ;;
        --duration)    DURATION="$2"; shift ;;
        --mem-gb)      MEM_GB_INPUT="$2"; shift ;;
        --reserve-gb)  RESERVE_GB_INPUT="$2"; shift ;;
        --threads)     THREADS="$2"; shift ;;
        --log-dir)     LOG_DIR="$2"; shift ;;
        --no-install)  NO_INSTALL=true ;;
        --keep-going)  STOP_ON_ERROR=false ;;
        -h|--help)     usage ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

trap 'echo -e "${RED}[ERROR]${RESET} ramtest.sh failed at line ${LINENO}" >&2' ERR

have() { command -v "$1" >/dev/null 2>&1; }

require_positive_int() {
    local value="$1" label="$2"
    [[ "$value" =~ ^[0-9]+$ ]] || die "$label must be an integer"
    (( value > 0 )) || die "$label must be > 0"
}

pkg_install_hint() {
    if have apt-get; then
        echo "sudo apt-get update && sudo apt-get install -y stressapptest"
    elif have dnf; then
        echo "sudo dnf install -y stressapptest"
    elif have yum; then
        echo "sudo yum install -y stressapptest"
    elif have zypper; then
        echo "sudo zypper install -y stressapptest"
    elif have pacman; then
        echo "sudo pacman -Sy --noconfirm stressapptest"
    else
        echo "Install stressapptest using your package manager"
    fi
}

auto_install_stressapptest() {
    local cmd=""
    if have apt-get; then
        cmd="apt-get update -qq && apt-get install -y stressapptest"
    elif have dnf; then
        cmd="dnf install -y stressapptest"
    elif have yum; then
        cmd="yum install -y stressapptest"
    elif have zypper; then
        cmd="zypper install -y stressapptest"
    elif have pacman; then
        cmd="pacman -Sy --noconfirm stressapptest"
    fi

    [[ -n "$cmd" ]] || die "stressapptest is missing. $(pkg_install_hint)"
    [[ $EUID -eq 0 ]] || die "stressapptest is missing and auto-install requires root. $(pkg_install_hint)"

    header "Installing stressapptest"
    eval "$cmd"
}

sum_glob_values() {
    local total=0
    local file value
    shopt -s nullglob
    for file in "$@"; do
        if [[ -r "$file" ]]; then
            value=$(<"$file")
            [[ "$value" =~ ^[0-9]+$ ]] || value=0
            total=$((total + value))
        fi
    done
    shopt -u nullglob
    echo "$total"
}

snapshot_edac() {
    local ce_glob=(/sys/devices/system/edac/mc/mc*/ce_count)
    local ue_glob=(/sys/devices/system/edac/mc/mc*/ue_count)
    shopt -s nullglob
    if (( ${#ce_glob[@]} == 0 && ${#ue_glob[@]} == 0 )); then
        shopt -u nullglob
        echo "unsupported"
        return
    fi
    shopt -u nullglob
    echo "$(sum_glob_values /sys/devices/system/edac/mc/mc*/ce_count) $(sum_glob_values /sys/devices/system/edac/mc/mc*/ue_count)"
}

print_inventory() {
    local ecc_mode="unknown" info_total_gb info_test_gb info_reserve_gb
    if have dmidecode && [[ $EUID -eq 0 ]]; then
        ecc_mode=$(dmidecode -t memory 2>/dev/null | awk -F: '/Error Correction Type:/ {gsub(/^ +/, "", $2); print $2; exit}')
        [[ -n "$ecc_mode" ]] || ecc_mode="unknown"
    fi

    info_total_gb=$(awk -v mb="$TOTAL_RAM_MB" 'BEGIN { printf "%.1f", mb / 1024 }')
    info_test_gb=$(awk -v mb="$TEST_MEM_MB" 'BEGIN { printf "%.1f", mb / 1024 }')
    info_reserve_gb=$(awk -v mb="$RESERVE_MB" 'BEGIN { printf "%.1f", mb / 1024 }')

    log "Detected RAM:       ${info_total_gb} GiB"
    log "Testing RAM:        ${info_test_gb} GiB"
    log "OS reserve:         ${info_reserve_gb} GiB"
    log "Thread count:       ${THREADS}"
    log "ECC mode:           ${ecc_mode}"
    log "Mode/runtime:       ${MODE} / ${DURATION}s"
    log "Log directory:      ${LOG_DIR}"
}

header "Checking prerequisites"
require_positive_int "$DURATION" "--duration"
[[ -z "$THREADS" ]] || require_positive_int "$THREADS" "--threads"
if [[ -n "$MEM_GB_INPUT" ]]; then
    require_positive_int "$MEM_GB_INPUT" "--mem-gb"
    TEST_MEM_MB=$(( MEM_GB_INPUT * 1024 ))
fi
if [[ -n "$RESERVE_GB_INPUT" ]]; then
    require_positive_int "$RESERVE_GB_INPUT" "--reserve-gb"
    RESERVE_MB=$(( RESERVE_GB_INPUT * 1024 ))
fi

TOTAL_RAM_MB=$(awk '/MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)
(( TOTAL_RAM_MB > 1024 )) || die "Unable to determine total system RAM"

if [[ -z "$RESERVE_MB" ]]; then
    RESERVE_MB=$(( TOTAL_RAM_MB / 10 ))
    if (( RESERVE_MB < 4096 )); then
        RESERVE_MB=4096
    fi
fi

if [[ -z "$TEST_MEM_MB" ]]; then
    TEST_MEM_MB=$(( TOTAL_RAM_MB - RESERVE_MB ))
fi

MIN_TEST_MB=1024
(( TEST_MEM_MB >= MIN_TEST_MB )) || die "Refusing to test less than ${MIN_TEST_MB} MiB; adjust --reserve-gb/--mem-gb"
(( TEST_MEM_MB < TOTAL_RAM_MB )) || die "Test memory must be smaller than total RAM to leave room for the OS"

if [[ -z "$THREADS" ]]; then
    THREADS=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)
    (( THREADS > 8 )) && THREADS=8
fi

if ! have stressapptest; then
    if [[ "$NO_INSTALL" == true ]]; then
        die "stressapptest is required. $(pkg_install_hint)"
    fi
    auto_install_stressapptest
fi

STRESS_BIN=$(command -v stressapptest)
[[ -x "$STRESS_BIN" ]] || die "stressapptest not found after installation"

mkdir -p "$LOG_DIR"

if [[ $EUID -ne 0 ]]; then
    warn "Running without root; package install, dmidecode, and some ECC observations may be limited"
fi

header "System inventory"
print_inventory

header "ECC baseline"
if snapshot=$(snapshot_edac); [[ "$snapshot" != "unsupported" ]]; then
    EDAC_SUPPORTED=true
    read -r ECC_BEFORE_CE ECC_BEFORE_UE <<< "$snapshot"
    log "EDAC counters before run: corrected=${ECC_BEFORE_CE} uncorrected=${ECC_BEFORE_UE}"
else
    warn "No EDAC counters found under /sys/devices/system/edac; continuing without ECC delta tracking"
fi

header "Running stressapptest"
CMD=(
    "$STRESS_BIN"
    -W
    -s "$DURATION"
    -M "$TEST_MEM_MB"
    -m "$THREADS"
    -i "$THREADS"
    -C "$THREADS"
    -v "$VERBOSITY"
    -l "$LOG_DIR/stressapptest.log"
)

if [[ "$STOP_ON_ERROR" == true ]]; then
    CMD+=(--stop_on_errors --max_errors 1)
fi

log "Command: ${CMD[*]}"
set +e
"${CMD[@]}" 2>&1 | tee "$LOG_DIR/console.log"
SAT_RC=${PIPESTATUS[0]}
set -e

header "Post-run checks"
if [[ "$EDAC_SUPPORTED" == true ]]; then
    read -r ECC_AFTER_CE ECC_AFTER_UE <<< "$(snapshot_edac)"
    CE_DELTA=$(( ECC_AFTER_CE - ECC_BEFORE_CE ))
    UE_DELTA=$(( ECC_AFTER_UE - ECC_BEFORE_UE ))
    log "EDAC counters after run:  corrected=${ECC_AFTER_CE} uncorrected=${ECC_AFTER_UE}"
    log "EDAC delta:               corrected=${CE_DELTA} uncorrected=${UE_DELTA}"
    if (( UE_DELTA > 0 )); then
        fail "Uncorrected ECC errors increased during the RAM test"
        exit 1
    fi
    if (( CE_DELTA > 0 )); then
        warn "Corrected ECC errors increased during the RAM test; inspect DIMM/channel health"
    fi
fi

if (( SAT_RC != 0 )); then
    fail "stressapptest exited with code ${SAT_RC}. Review $LOG_DIR/stressapptest.log"
    exit "$SAT_RC"
fi

if grep -Eiq 'error|miscompare|uncorrected' "$LOG_DIR/stressapptest.log"; then
    warn "stressapptest log contains error keywords; inspect $LOG_DIR/stressapptest.log before declaring the host healthy"
fi

pass "RAM validation completed successfully"
log "Logs saved under: $LOG_DIR"
log "For deeper pre-boot coverage, run Memtest86+ from external media during maintenance windows"
