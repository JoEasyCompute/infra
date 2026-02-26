#!/usr/bin/env bash
# =============================================================================
# disktest.sh — Comprehensive Disk Test Suite
# Modeled after GPU fulltest.sh patterns: discovery → health → perf → stress
# =============================================================================

set -euo pipefail

# ─── Color / formatting ──────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ─── Defaults ─────────────────────────────────────────────────────────────────
MODE="full"           # quick | full | stress | health
TARGET_DEV=""         # empty = all block devices
OUTPUT_JSON=false
BASELINE_FILE=""
SAVE_BASELINE=false
DRY_RUN=false         # show plan without running any I/O
FORCE=false           # bypass in-use / RAID safety checks
RUNTIME_SHORT=30      # seconds per fio job in quick mode
RUNTIME_FULL=60       # seconds per fio job in full mode
RUNTIME_STRESS=300    # seconds for stress test
LOG_DIR="/tmp/disktest_$(date +%Y%m%d_%H%M%S)"
RESULTS=()
FAILED_TESTS=()
WARNED_TESTS=()

# Per-device safety verdicts (populated by check_device_safety)
declare -A DEV_SAFE       # true | false
declare -A DEV_SAFE_MSG   # reason if unsafe

# ─── Thresholds ───────────────────────────────────────────────────────────────
MIN_SEQ_READ_MB=200       # MB/s minimum sequential read
MIN_SEQ_WRITE_MB=100      # MB/s minimum sequential write
MIN_RAND_READ_IOPS=1000   # IOPS minimum random 4K read
MAX_LATENCY_US=5000       # µs max acceptable p99 latency
SMART_REALLOCATED_MAX=10  # max reallocated sectors before warning

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

log()   { echo -e "${CYAN}[$(date +%H:%M:%S)]${RESET} $*"; }
pass()  { echo -e "${GREEN}[PASS]${RESET} $*"; RESULTS+=("PASS: $*"); }
fail()  { echo -e "${RED}[FAIL]${RESET} $*"; RESULTS+=("FAIL: $*"); FAILED_TESTS+=("$*"); }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; RESULTS+=("WARN: $*"); WARNED_TESTS+=("$*"); }
info()  { echo -e "       $*"; }
header(){ echo -e "\n${BOLD}${CYAN}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }
die()   { echo -e "${RED}FATAL: $*${RESET}" >&2; exit 1; }

usage() {
    cat <<EOF
${BOLD}disktest.sh${RESET} — Comprehensive Disk Test Suite

${BOLD}USAGE:${RESET}
  ./disktest.sh [OPTIONS]

${BOLD}MODES:${RESET}
  --quick           SMART health + sequential I/O only (~3 min per disk)
  --full            All tests: health, sequential, random, latency (~15 min) [default]
  --stress          Extended endurance + thermal test (~30+ min)
  --health          SMART/NVMe health checks only (no I/O tests)
  --dry-run         Show exactly what would run without touching any disk

${BOLD}TARGETING:${RESET}
  --device DEV      Test only this device (e.g. /dev/nvme0n1, /dev/sda)
  --exclude DEV     Skip this device (repeatable)
  --force           Skip in-use / RAID / LVM safety checks (dangerous!)

${BOLD}OUTPUT:${RESET}
  --json            Machine-readable JSON summary to stdout
  --log-dir DIR     Directory for detailed fio/smartctl logs [default: /tmp/disktest_*]
  --save-baseline   Save results as baseline for future comparison
  --compare FILE    Compare results against a saved baseline

${BOLD}EXAMPLES:${RESET}
  sudo ./disktest.sh --full
  sudo ./disktest.sh --dry-run                      # preview plan, no I/O
  sudo ./disktest.sh --quick --device /dev/nvme0n1
  sudo ./disktest.sh --stress --device /dev/sda --json
  sudo ./disktest.sh --full --save-baseline
  sudo ./disktest.sh --quick --compare /tmp/disktest_baseline.json
EOF
    exit 0
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

EXCLUDE_DEVS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick)    MODE="quick" ;;
        --full)     MODE="full" ;;
        --stress)   MODE="stress" ;;
        --health)   MODE="health" ;;
        --dry-run)  DRY_RUN=true ;;
        --force)    FORCE=true ;;
        --device)   TARGET_DEV="$2"; shift ;;
        --exclude)  EXCLUDE_DEVS+=("$2"); shift ;;
        --json)     OUTPUT_JSON=true ;;
        --log-dir)  LOG_DIR="$2"; shift ;;
        --save-baseline) SAVE_BASELINE=true ;;
        --compare)  BASELINE_FILE="$2"; shift ;;
        --help|-h)  usage ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

# =============================================================================
# PREREQUISITES
# =============================================================================

check_prereqs() {
    header "Checking Prerequisites"

    # ── Root check ────────────────────────────────────────────────────────────
    if [[ $EUID -ne 0 ]]; then
        warn "Not running as root — SMART data and raw device tests may be limited"
        warn "Re-run with: sudo ./disktest.sh"
    fi

    # ── Detect package manager ────────────────────────────────────────────────
    local PKG_MGR=""
    local PKG_UPDATE=""
    if command -v apt-get &>/dev/null; then
        PKG_MGR="apt-get install -y"
        PKG_UPDATE="apt-get update -qq"
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf install -y"
        PKG_UPDATE="true"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum install -y"
        PKG_UPDATE="true"
    elif command -v zypper &>/dev/null; then
        PKG_MGR="zypper install -y"
        PKG_UPDATE="true"
    elif command -v pacman &>/dev/null; then
        PKG_MGR="pacman -S --noconfirm"
        PKG_UPDATE="pacman -Sy"
    else
        warn "No supported package manager found — cannot auto-install dependencies"
        PKG_MGR=""
    fi

    # ── Package name mappings per distro ──────────────────────────────────────
    # Format: "command:apt_pkg:dnf_pkg:pacman_pkg"
    # Required tools
    declare -A REQUIRED=(
        [fio]="fio:fio:fio"
        [smartctl]="smartmontools:smartmontools:smartmontools"
        [lsblk]="util-linux:util-linux:util-linux"
        [blockdev]="util-linux:util-linux:util-linux"
        [python3]="python3:python3:python3"
    )
    # Optional tools (degraded mode if missing)
    declare -A OPTIONAL=(
        [nvme]="nvme-cli:nvme-cli:nvme-cli"
        [ioping]="ioping:ioping:ioping"
        [lspci]="pciutils:pciutils:pciutils"
    )

    _pkg_name() {
        # Extract package name for current package manager
        local entry="$1"
        local parts
        IFS=':' read -ra parts <<< "$entry"
        if command -v apt-get &>/dev/null;   then echo "${parts[0]}";
        elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then echo "${parts[1]}";
        elif command -v pacman &>/dev/null;  then echo "${parts[2]}";
        else echo "${parts[0]}"; fi
    }

    _try_install() {
        local pkg="$1"
        if [[ -z "$PKG_MGR" ]]; then
            warn "Cannot install '$pkg' — no package manager available"
            return 1
        fi
        if [[ $EUID -ne 0 ]]; then
            warn "Cannot install '$pkg' — re-run as root to enable auto-install"
            return 1
        fi
        log "Installing '$pkg'..."
        if [[ -n "$PKG_UPDATE" ]] && ! $PKG_UPDATE_DONE; then
            log "Updating package index..."
            eval "$PKG_UPDATE" > /dev/null 2>&1 || true
            PKG_UPDATE_DONE=true
        fi
        if eval "$PKG_MGR $pkg" > /dev/null 2>&1; then
            pass "Installed: $pkg"
            return 0
        else
            fail "Failed to install: $pkg"
            return 1
        fi
    }

    PKG_UPDATE_DONE=false

    # ── Check & install required tools ────────────────────────────────────────
    local any_missing=false
    for cmd in "${!REQUIRED[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            info "$(command -v "$cmd")  ✓  ($cmd)"
        else
            warn "$cmd not found"
            local pkg
            pkg=$(_pkg_name "${REQUIRED[$cmd]}")
            if _try_install "$pkg"; then
                # Verify it's now available
                if ! command -v "$cmd" &>/dev/null; then
                    fail "$cmd still not found after installing $pkg"
                    any_missing=true
                fi
            else
                any_missing=true
            fi
        fi
    done

    $any_missing && die "Required dependencies could not be satisfied — aborting"

    # ── Check & install optional tools ────────────────────────────────────────
    for cmd in "${!OPTIONAL[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            info "$(command -v "$cmd")  ✓  ($cmd)"
        else
            warn "$cmd not found (optional)"
            local pkg
            pkg=$(_pkg_name "${OPTIONAL[$cmd]}")
            _try_install "$pkg" || true   # non-fatal
        fi
    done

    # ── Final feature flags based on what's available ─────────────────────────
    HAS_NVME=$(command -v nvme &>/dev/null && echo true || echo false)
    HAS_IOPING=$(command -v ioping &>/dev/null && echo true || echo false)
    HAS_LSPCI=$(command -v lspci &>/dev/null && echo true || echo false)

    $HAS_NVME   || warn "nvme-cli unavailable — NVMe-specific health checks disabled"
    $HAS_IOPING || info "ioping unavailable — latency checks will use fio only"
    $HAS_LSPCI  || info "lspci unavailable — PCIe topology info will be skipped"

    mkdir -p "$LOG_DIR"
    log "Log directory: $LOG_DIR"
}

# =============================================================================
# DEVICE DISCOVERY
# =============================================================================

declare -A DEV_TYPE   # ssd | hdd | nvme | unknown
declare -A DEV_SIZE   # human-readable
declare -A DEV_MODEL

discover_devices() {
    header "Device Discovery"

    local devices=()

    if [[ -n "$TARGET_DEV" ]]; then
        [[ -b "$TARGET_DEV" ]] || die "Device not found: $TARGET_DEV"
        devices=("$TARGET_DEV")
    else
        # Enumerate non-partition block devices
        while IFS= read -r dev; do
            local skip=false
            for excl in "${EXCLUDE_DEVS[@]:-}"; do
                [[ "/dev/$dev" == "$excl" ]] && skip=true
            done
            $skip || devices+=("/dev/$dev")
        done < <(lsblk -d -n -o NAME,TYPE | awk '$2=="disk"{print $1}')
    fi

    [[ ${#devices[@]} -eq 0 ]] && die "No block devices found"

    log "Found ${#devices[@]} disk(s):"
    for dev in "${devices[@]}"; do
        local name type size model rotational
        name=$(basename "$dev")
        size=$(lsblk -d -n -o SIZE "$dev" 2>/dev/null || echo "?")
        model=$(lsblk -d -n -o MODEL "$dev" 2>/dev/null | xargs || echo "unknown")
        rotational=$(cat "/sys/block/${name}/queue/rotational" 2>/dev/null || echo "?")

        if [[ "$dev" == *nvme* ]]; then
            type="nvme"
        elif [[ "$rotational" == "0" ]]; then
            type="ssd"
        elif [[ "$rotational" == "1" ]]; then
            type="hdd"
        else
            type="unknown"
        fi

        DEV_TYPE["$dev"]="$type"
        DEV_SIZE["$dev"]="$size"
        DEV_MODEL["$dev"]="$model"

        info "  ${BOLD}$dev${RESET} [$type] $size — $model"
    done

    DEVICES=("${devices[@]}")
}

# =============================================================================
# #2 — DEVICE SAFETY CHECK
# Detects mounted partitions, RAID members, LVM PVs, ZFS vdevs
# Populates DEV_SAFE[] and DEV_SAFE_MSG[] for every device
# =============================================================================

check_device_safety() {
    header "Safety Checks"

    local any_unsafe=false

    for dev in "${DEVICES[@]}"; do
        local safe=true
        local reasons=()
        local name
        name=$(basename "$dev")

        # ── 1. Mounted partitions (direct or child) ───────────────────────────
        local mounts
        mounts=$(lsblk -n -o MOUNTPOINT "$dev" 2>/dev/null | grep -v '^$' || true)
        if [[ -n "$mounts" ]]; then
            safe=false
            # Flag root/boot specially
            if echo "$mounts" | grep -qE '^/$|^/boot'; then
                reasons+=("has MOUNTED ROOT/BOOT partition — raw I/O would corrupt live system!")
            else
                local mlist
                mlist=$(echo "$mounts" | tr '\n' ' ' | xargs)
                reasons+=("has mounted partitions: $mlist")
            fi
        fi

        # ── 2. mdadm RAID member ──────────────────────────────────────────────
        if [[ -f /proc/mdstat ]]; then
            if grep -q "$name" /proc/mdstat 2>/dev/null; then
                safe=false
                local md_array
                md_array=$(grep -l "$name" /sys/block/md*/slaves/ 2>/dev/null \
                    | grep -oP 'md\d+' | head -1 || echo "md array")
                reasons+=("is member of software RAID: $md_array")
            fi
        fi

        # ── 3. LVM Physical Volume ────────────────────────────────────────────
        if command -v pvs &>/dev/null; then
            if pvs "$dev" &>/dev/null 2>&1 || \
               pvs 2>/dev/null | grep -q "$name"; then
                safe=false
                local vg
                vg=$(pvs --noheadings -o vg_name "$dev" 2>/dev/null | xargs || echo "unknown VG")
                reasons+=("is an LVM Physical Volume (VG: $vg)")
            fi
        else
            # Fallback: check for LVM signature via lsblk TYPE
            if lsblk -n -o TYPE "$dev" 2>/dev/null | grep -q "lvm"; then
                safe=false
                reasons+=("appears to be an LVM PV (pvs not available for details)")
            fi
        fi

        # ── 4. ZFS vdev ───────────────────────────────────────────────────────
        if command -v zpool &>/dev/null; then
            if zpool status 2>/dev/null | grep -q "$name"; then
                safe=false
                local zp
                zp=$(zpool status 2>/dev/null | grep -B20 "$name" \
                    | grep "pool:" | awk '{print $2}' | head -1 || echo "unknown pool")
                reasons+=("is a ZFS vdev in pool: $zp")
            fi
        fi

        # ── 5. Device is currently open by another process ───────────────────
        if command -v lsof &>/dev/null; then
            local openers
            openers=$(lsof "$dev" 2>/dev/null | awk 'NR>1 {print $1}' | sort -u | head -3 || true)
            if [[ -n "$openers" ]]; then
                # Warn but don't block — kernel itself opens block devs
                warn "$dev — currently open by: $openers"
            fi
        fi

        # ── Record verdict ────────────────────────────────────────────────────
        if $safe; then
            DEV_SAFE["$dev"]=true
            DEV_SAFE_MSG["$dev"]=""
            pass "$dev — safety check: clear for raw I/O"
        else
            DEV_SAFE["$dev"]=false
            DEV_SAFE_MSG["$dev"]="${reasons[*]}"
            any_unsafe=true
            local msg
            msg=$(IFS='; '; echo "${reasons[*]}")

            if $FORCE; then
                warn "$dev — UNSAFE but --force specified: $msg"
                warn "$dev — Proceeding with raw I/O — DATA LOSS POSSIBLE"
                DEV_SAFE["$dev"]=true   # override
            else
                fail "$dev — UNSAFE for raw I/O: $msg"
                warn "$dev — Raw I/O tests will be SKIPPED (use --force to override)"
            fi
        fi
    done

    if $any_unsafe && ! $FORCE; then
        echo ""
        echo -e "${YELLOW}${BOLD}NOTE:${RESET} Unsafe devices will have raw I/O tests skipped."
        echo -e "      SMART/health checks will still run."
        echo -e "      Use ${BOLD}--force${RESET} to override (dangerous on live systems)."
    fi
}

# =============================================================================
# #4 — RUNTIME ESTIMATE
# Print a time estimate before any I/O begins
# =============================================================================

print_runtime_estimate() {
    header "Test Plan & Time Estimate"

    local safe_devs=0
    for dev in "${DEVICES[@]}"; do
        ${DEV_SAFE[$dev]:-false} && (( safe_devs++ )) || true
    done
    local total_devs=${#DEVICES[@]}

    # Seconds per device by mode
    local secs_per_dev=0
    case "$MODE" in
        health) secs_per_dev=10 ;;
        quick)  secs_per_dev=$(( RUNTIME_SHORT * 2 + 15 )) ;;
        full)   secs_per_dev=$(( RUNTIME_FULL * 8 + 60 )) ;;
        stress) secs_per_dev=$(( RUNTIME_STRESS * 3 + RUNTIME_FULL * 8 + 60 )) ;;
    esac

    # Parallel test extra time
    local parallel_secs=0
    if [[ "$MODE" != "health" && "$MODE" != "quick" && $safe_devs -gt 1 ]]; then
        parallel_secs=$RUNTIME_FULL
    fi

    local total_secs=$(( secs_per_dev * safe_devs + parallel_secs ))
    local total_mins=$(( total_secs / 60 ))
    local total_secs_rem=$(( total_secs % 60 ))

    echo -e "  Mode:            ${BOLD}$MODE${RESET}"
    echo -e "  Total devices:   $total_devs  (${safe_devs} safe for I/O)"
    echo -e "  Tests per disk:"

    case "$MODE" in
        health)
            echo    "    • SMART / NVMe health"
            ;;
        quick)
            echo    "    • SMART / NVMe health"
            echo    "    • Sequential read + write  (${RUNTIME_SHORT}s each)"
            ;;
        full)
            echo    "    • SMART / NVMe health"
            echo    "    • Sequential read + write  (${RUNTIME_FULL}s each)"
            echo    "    • Random 4K read  ×4 queue depths  (${RUNTIME_FULL}s each)"
            echo    "    • Random 4K mixed 70/30  (${RUNTIME_FULL}s)"
            echo    "    • QD1 latency profile  (${RUNTIME_FULL}s)"
            echo    "    • Filesystem fsync latency  (30s)"
            [[ $safe_devs -gt 1 ]] && echo "    • Multi-disk parallel  (${RUNTIME_FULL}s)"
            ;;
        stress)
            echo    "    • SMART / NVMe health"
            echo    "    • Sequential read + write  (${RUNTIME_FULL}s each)"
            echo    "    • Random 4K  ×4 QD + mixed  (${RUNTIME_FULL}s each)"
            echo    "    • QD1 latency profile  (${RUNTIME_FULL}s)"
            echo    "    • Filesystem fsync latency  (30s)"
            echo    "    • Stress: sustained write  (${RUNTIME_STRESS}s)"
            echo    "    • Stress: mixed load  (${RUNTIME_STRESS}s)"
            [[ $safe_devs -gt 1 ]] && echo "    • Multi-disk parallel  (${RUNTIME_FULL}s)"
            ;;
    esac

    echo ""
    if [[ $total_mins -gt 0 ]]; then
        echo -e "  ${BOLD}Estimated time:  ~${total_mins}m ${total_secs_rem}s${RESET}"
    else
        echo -e "  ${BOLD}Estimated time:  ~${total_secs}s${RESET}"
    fi
    echo -e "  Log directory:   ${CYAN}$LOG_DIR${RESET}"

    if $DRY_RUN; then
        echo ""
        echo -e "${YELLOW}${BOLD}DRY RUN — no I/O will be performed. Exiting.${RESET}"
        exit 0
    fi

    # Give user 3 seconds to abort on full/stress runs against multiple disks
    if [[ "$MODE" != "health" && $safe_devs -gt 1 && $total_mins -gt 5 ]]; then
        echo ""
        echo -ne "${YELLOW}Starting in 3 seconds — Ctrl+C to abort...${RESET}"
        sleep 1; echo -ne " 2..."
        sleep 1; echo -ne " 1..."
        sleep 1; echo ""
    fi
}

# =============================================================================
# #6 — I/O SCHEDULER ADVISOR
# Recommends and optionally applies optimal scheduler per device type
# =============================================================================

advise_schedulers() {
    header "I/O Scheduler Recommendations"

    local changed=false

    for dev in "${DEVICES[@]}"; do
        local name
        name=$(basename "$dev")
        local type="${DEV_TYPE[$dev]:-unknown}"
        local sched_file="/sys/block/${name}/queue/scheduler"

        if [[ ! -f "$sched_file" ]]; then
            info "  $dev — scheduler sysfs not available"
            continue
        fi

        local current_raw
        current_raw=$(cat "$sched_file" 2>/dev/null || echo "unknown")
        # Extract active scheduler (wrapped in [brackets])
        local current
        current=$(echo "$current_raw" | grep -oP '\[\K[^\]]+' || echo "$current_raw")
        local available
        available=$(echo "$current_raw" | tr -d '[]' | xargs)

        # Determine optimal scheduler
        local optimal reason
        case "$type" in
            nvme)
                optimal="none"
                reason="NVMe has internal command queuing; kernel scheduler adds overhead"
                # mq-deadline is acceptable fallback
                if ! echo "$available" | grep -qw "none"; then
                    optimal="mq-deadline"
                    reason="'none' unavailable; mq-deadline is best for NVMe on this kernel"
                fi
                ;;
            ssd)
                optimal="mq-deadline"
                reason="low-latency deadline prevents starvation on SSD"
                if echo "$available" | grep -qw "none"; then
                    optimal="none"
                    reason="SSD with 'none' available avoids scheduler overhead entirely"
                fi
                ;;
            hdd)
                optimal="bfq"
                reason="BFQ provides fair bandwidth allocation for spinning media"
                if ! echo "$available" | grep -qw "bfq"; then
                    optimal="mq-deadline"
                    reason="BFQ unavailable; mq-deadline is best available for HDD"
                fi
                ;;
            *)
                optimal="mq-deadline"
                reason="unknown device type; mq-deadline is safe default"
                ;;
        esac

        if [[ "$current" == "$optimal" ]]; then
            pass "$dev [$type] — scheduler '$current' is optimal"
        else
            warn "$dev [$type] — scheduler '$current' → recommend '$optimal' ($reason)"
            warn "$dev — Available: $available"

            if [[ $EUID -eq 0 ]] && echo "$available" | grep -qw "$optimal"; then
                echo "$optimal" > "$sched_file" 2>/dev/null && {
                    info "  Applied '$optimal' to $dev"
                    changed=true
                } || warn "  Failed to apply '$optimal' to $dev"
            else
                info "  To apply: echo '$optimal' | sudo tee $sched_file"
            fi
        fi
    done

    $changed && info "Scheduler changes are runtime-only and will reset on reboot."
    info "To persist, add udev rules or configure in /etc/udev/rules.d/"
}

# =============================================================================
# #12 — PER-TEST TIMEOUT WRAPPER
# Wraps fio calls so a hung/dying drive can't stall the entire test suite
# =============================================================================

TIMEOUT_SECS=0   # set per-test before calling run_fio_safe

run_fio_safe() {
    # Identical signature to run_fio but respects TIMEOUT_SECS
    # Falls back to zeroed results on timeout rather than hanging
    local dev="$1"; local label="$2"
    local timeout_val=$(( TIMEOUT_SECS > 0 ? TIMEOUT_SECS : 120 ))

    if command -v timeout &>/dev/null; then
        # Run run_fio in a subshell under timeout
        if ! timeout "$timeout_val" bash -c "
            $(declare -f run_fio)
            run_fio $(printf '%q ' "$@")
        " 2>/dev/null; then
            warn "$dev — fio job '$label' timed out after ${timeout_val}s (drive may be degraded)"
            FIO_BW_READ=0; FIO_BW_WRITE=0
            FIO_IOPS_READ=0; FIO_IOPS_WRITE=0
            FIO_LAT_P99_US=0
            return 1
        fi
    else
        # timeout not available, fall back to plain run_fio
        run_fio "$@"
    fi
}

# =============================================================================
# SMART / HEALTH CHECKS
# =============================================================================

check_smart() {
    local dev="$1"
    local devname
    devname=$(basename "$dev")
    local type="${DEV_TYPE[$dev]:-unknown}"

    log "SMART health: $dev"

    # ── Overall SMART status ──────────────────────────────────────────────
    local smart_status
    smart_status=$(smartctl -H "$dev" 2>/dev/null | grep -i "overall-health\|result:" || true)

    if echo "$smart_status" | grep -qi "PASSED\|OK"; then
        pass "$dev — SMART overall health: PASSED"
    elif echo "$smart_status" | grep -qi "FAILED"; then
        fail "$dev — SMART overall health: FAILED — drive may be failing!"
    else
        warn "$dev — SMART status unclear (may need root or supported device)"
    fi

    # ── Key SMART attributes ──────────────────────────────────────────────
    local smartlog="$LOG_DIR/smart_${devname}.txt"
    smartctl -a "$dev" > "$smartlog" 2>&1 || true

    # Reallocated sectors
    local realloc
    realloc=$(grep -i "Reallocated_Sector_Ct\|Reallocated Sectors" "$smartlog" 2>/dev/null \
        | awk '{print $NF}' | head -1 || echo "0")
    realloc=$(echo "$realloc" | tr -cd '0-9')
    realloc=${realloc:-0}

    if [[ "$realloc" -gt "$SMART_REALLOCATED_MAX" ]]; then
        warn "$dev — Reallocated sectors: $realloc (threshold: $SMART_REALLOCATED_MAX)"
    elif [[ "$realloc" -gt 0 ]]; then
        warn "$dev — Reallocated sectors: $realloc (non-zero, monitor closely)"
    else
        pass "$dev — Reallocated sectors: 0"
    fi

    # Pending / uncorrectable
    for attr in "Current_Pending_Sector" "Offline_Uncorrectable"; do
        local val
        val=$(grep "$attr" "$smartlog" 2>/dev/null | awk '{print $NF}' | head -1 | tr -cd '0-9' || echo "0")
        val=${val:-0}
        if [[ "$val" -gt 0 ]]; then
            fail "$dev — $attr: $val — immediate attention required!"
        fi
    done

    # Temperature
    local temp
    temp=$(grep -i "Temperature_Celsius\|Temperature:" "$smartlog" 2>/dev/null \
        | awk '{print $NF}' | head -1 | tr -cd '0-9' || echo "")
    if [[ -n "$temp" ]]; then
        if [[ "$temp" -gt 70 ]]; then
            warn "$dev — Temperature: ${temp}°C (HIGH)"
        elif [[ "$temp" -gt 55 ]]; then
            warn "$dev — Temperature: ${temp}°C (elevated)"
        else
            pass "$dev — Temperature: ${temp}°C"
        fi
    fi

    # ── NVMe-specific ─────────────────────────────────────────────────────
    if [[ "$type" == "nvme" ]] && ${HAS_NVME:-false}; then
        local nvmelog="$LOG_DIR/nvme_${devname}.txt"
        nvme smart-log "$dev" > "$nvmelog" 2>&1 || true

        local wear
        wear=$(grep "percentage_used\|Percentage Used" "$nvmelog" 2>/dev/null \
            | grep -oP '\d+' | head -1 || echo "")
        if [[ -n "$wear" ]]; then
            if [[ "$wear" -gt 90 ]]; then
                fail "$dev — NVMe wear: ${wear}% (drive near end of life!)"
            elif [[ "$wear" -gt 70 ]]; then
                warn "$dev — NVMe wear: ${wear}%"
            else
                pass "$dev — NVMe wear: ${wear}%"
            fi
        fi

        local spare
        spare=$(grep "available_spare\b\|Available Spare:" "$nvmelog" 2>/dev/null \
            | grep -oP '\d+' | head -1 || echo "")
        if [[ -n "$spare" ]]; then
            if [[ "$spare" -lt 10 ]]; then
                fail "$dev — NVMe available spare: ${spare}%"
            else
                pass "$dev — NVMe available spare: ${spare}%"
            fi
        fi
    fi
}

# =============================================================================
# FIO HELPER — run a job and extract bandwidth/IOPS/latency
# =============================================================================

# Returns: sets FIO_BW_READ, FIO_BW_WRITE, FIO_IOPS_READ, FIO_IOPS_WRITE,
#          FIO_LAT_P99_US (read p99 µs)
run_fio() {
    local dev="$1"; shift
    local label="$1"; shift
    local extra_args=("$@")
    local devname
    devname=$(basename "$dev")
    local outfile="$LOG_DIR/fio_${devname}_${label}.json"

    fio \
        --filename="$dev" \
        --direct=1 \
        --ioengine=libaio \
        --group_reporting \
        --output-format=json \
        --output="$outfile" \
        --name="$label" \
        "${extra_args[@]}" \
        > /dev/null 2>&1 || true

    # Parse JSON results
    if [[ -f "$outfile" ]]; then
        FIO_BW_READ=$(python3 -c "
import json,sys
d=json.load(open('$outfile'))
j=d['jobs'][0]
bw=j['read']['bw']  # KB/s
print(round(bw/1024,1))
" 2>/dev/null || echo "0")

        FIO_BW_WRITE=$(python3 -c "
import json,sys
d=json.load(open('$outfile'))
j=d['jobs'][0]
bw=j['write']['bw']
print(round(bw/1024,1))
" 2>/dev/null || echo "0")

        FIO_IOPS_READ=$(python3 -c "
import json,sys
d=json.load(open('$outfile'))
j=d['jobs'][0]
print(round(j['read']['iops']))
" 2>/dev/null || echo "0")

        FIO_IOPS_WRITE=$(python3 -c "
import json,sys
d=json.load(open('$outfile'))
j=d['jobs'][0]
print(round(j['write']['iops']))
" 2>/dev/null || echo "0")

        FIO_LAT_P99_US=$(python3 -c "
import json,sys
d=json.load(open('$outfile'))
j=d['jobs'][0]
# p99 in nanoseconds → µs
lat=j['read']['clat_ns'].get('percentile',{}).get('99.000000',0)
if lat==0:
    lat=j['read']['lat_ns'].get('percentile',{}).get('99.000000',0)
print(round(lat/1000,1))
" 2>/dev/null || echo "0")
    else
        FIO_BW_READ=0; FIO_BW_WRITE=0
        FIO_IOPS_READ=0; FIO_IOPS_WRITE=0
        FIO_LAT_P99_US=0
    fi
}

# =============================================================================
# SEQUENTIAL I/O TEST
# =============================================================================

test_sequential() {
    local dev="$1"
    local runtime="${2:-$RUNTIME_FULL}"

    if ! ${DEV_SAFE[$dev]:-false}; then
        warn "$dev — Skipping sequential I/O (device not safe for raw writes)"
        return
    fi

    log "Sequential I/O: $dev"
    TIMEOUT_SECS=$(( runtime * 2 + 60 ))

    # Sequential READ
    run_fio_safe "$dev" "seq_read" \
        --rw=read --bs=1M --iodepth=32 \
        --numjobs=1 --runtime="$runtime" --time_based

    local read_mb="$FIO_BW_READ"
    info "  Sequential read:  ${read_mb} MB/s"
    if python3 -c "exit(0 if float('${read_mb}') >= $MIN_SEQ_READ_MB else 1)" 2>/dev/null; then
        pass "$dev — Sequential read: ${read_mb} MB/s (threshold: ${MIN_SEQ_READ_MB} MB/s)"
    else
        fail "$dev — Sequential read: ${read_mb} MB/s (below threshold: ${MIN_SEQ_READ_MB} MB/s)"
    fi

    # Sequential WRITE
    run_fio_safe "$dev" "seq_write" \
        --rw=write --bs=1M --iodepth=32 \
        --numjobs=1 --runtime="$runtime" --time_based

    local write_mb="$FIO_BW_WRITE"
    info "  Sequential write: ${write_mb} MB/s"
    if python3 -c "exit(0 if float('${write_mb}') >= $MIN_SEQ_WRITE_MB else 1)" 2>/dev/null; then
        pass "$dev — Sequential write: ${write_mb} MB/s (threshold: ${MIN_SEQ_WRITE_MB} MB/s)"
    else
        fail "$dev — Sequential write: ${write_mb} MB/s (below threshold: ${MIN_SEQ_WRITE_MB} MB/s)"
    fi
}

# =============================================================================
# RANDOM I/O TEST  (4K, multiple queue depths)
# =============================================================================

test_random_io() {
    local dev="$1"
    local runtime="${2:-$RUNTIME_FULL}"

    if ! ${DEV_SAFE[$dev]:-false}; then
        warn "$dev — Skipping random I/O (device not safe for raw writes)"
        return
    fi

    log "Random 4K I/O: $dev"
    TIMEOUT_SECS=$(( runtime + 30 ))

    # Queue depth sweep
    for qd in 1 4 16 32; do
        run_fio_safe "$dev" "rand_read_qd${qd}" \
            --rw=randread --bs=4k --iodepth="$qd" \
            --numjobs=1 --runtime="$runtime" --time_based

        info "  randread  QD${qd}: ${FIO_IOPS_READ} IOPS  (p99 lat: ${FIO_LAT_P99_US} µs)"
    done

    # Save QD32 read IOPS as the headline number
    local headline_iops="$FIO_IOPS_READ"
    if python3 -c "exit(0 if int('${headline_iops}') >= $MIN_RAND_READ_IOPS else 1)" 2>/dev/null; then
        pass "$dev — Random 4K read QD32: ${headline_iops} IOPS"
    else
        fail "$dev — Random 4K read QD32: ${headline_iops} IOPS (threshold: ${MIN_RAND_READ_IOPS})"
    fi

    # Mixed 70/30 read/write
    run_fio_safe "$dev" "randrw_7030" \
        --rw=randrw --rwmixread=70 --bs=4k --iodepth=16 \
        --numjobs=1 --runtime="$runtime" --time_based

    info "  mixed 70/30 QD16: read=${FIO_IOPS_READ} IOPS  write=${FIO_IOPS_WRITE} IOPS"
}

# =============================================================================
# LATENCY TEST  (QD1 — most sensitive to drive health)
# =============================================================================

test_latency() {
    local dev="$1"
    local runtime="${2:-$RUNTIME_FULL}"

    if ! ${DEV_SAFE[$dev]:-false}; then
        warn "$dev — Skipping latency test (device not safe for raw reads on live system)"
        return
    fi

    log "Latency profile (QD1): $dev"
    TIMEOUT_SECS=$(( runtime + 30 ))

    run_fio_safe "$dev" "lat_qd1" \
        --rw=randread --bs=4k --iodepth=1 \
        --numjobs=1 --runtime="$runtime" --time_based \
        --percentile_list=50:95:99:99.9

    local p99="$FIO_LAT_P99_US"
    info "  QD1 random read p99 latency: ${p99} µs"

    if python3 -c "exit(0 if float('${p99}') <= $MAX_LATENCY_US and float('${p99}') > 0 else 1)" 2>/dev/null; then
        pass "$dev — QD1 p99 latency: ${p99} µs (threshold: ${MAX_LATENCY_US} µs)"
    else
        warn "$dev — QD1 p99 latency: ${p99} µs (threshold: ${MAX_LATENCY_US} µs)"
    fi

    # ioping for raw latency feel if available
    if ${HAS_IOPING:-false}; then
        local iop_out
        iop_out=$(timeout 30 ioping -c 20 "$dev" 2>&1 | tail -3 || true)
        info "  ioping: $iop_out"
    fi
}

# =============================================================================
# STRESS / ENDURANCE TEST
# =============================================================================

test_stress() {
    local dev="$1"
    local runtime="${2:-$RUNTIME_STRESS}"

    if ! ${DEV_SAFE[$dev]:-false}; then
        warn "$dev — Skipping stress test (device not safe for raw writes)"
        return
    fi

    log "Stress test (${runtime}s): $dev — monitoring for thermal throttle & SLC cache exhaustion"
    TIMEOUT_SECS=$(( runtime * 2 + 120 ))

    # Sustained sequential write — will expose SLC cache cliff on TLC/QLC drives
    run_fio_safe "$dev" "stress_seq_write" \
        --rw=write --bs=128k --iodepth=32 \
        --numjobs=2 --runtime="$runtime" --time_based

    info "  Sustained write avg: ${FIO_BW_WRITE} MB/s over ${runtime}s"

    # Mixed stress
    run_fio_safe "$dev" "stress_mixed" \
        --rw=randrw --rwmixread=50 --bs=4k --iodepth=32 \
        --numjobs=4 --runtime="$runtime" --time_based

    info "  Mixed stress avg:  read=${FIO_IOPS_READ} IOPS  write=${FIO_IOPS_WRITE} IOPS"

    pass "$dev — Stress test completed (${runtime}s)"

    # Re-check temperature after stress
    local temp
    temp=$(smartctl -A "$dev" 2>/dev/null \
        | grep -i "Temperature_Celsius" | awk '{print $NF}' | tr -cd '0-9' || echo "")
    if [[ -n "$temp" ]]; then
        if [[ "$temp" -gt 70 ]]; then
            fail "$dev — Post-stress temperature: ${temp}°C (CRITICAL)"
        elif [[ "$temp" -gt 60 ]]; then
            warn "$dev — Post-stress temperature: ${temp}°C"
        else
            info "  Post-stress temperature: ${temp}°C"
        fi
    fi
}

# =============================================================================
# MULTI-DISK PARALLEL TEST  (detect shared controller bottleneck)
# =============================================================================

test_parallel() {
    local -a devs=("$@")
    [[ ${#devs[@]} -lt 2 ]] && return

    header "Multi-Disk Parallel I/O  (${#devs[@]} disks)"
    log "Testing aggregate bandwidth — will expose shared PCIe/controller bottlenecks"

    # Build fio config with one job per disk
    local fio_cfg="$LOG_DIR/fio_parallel.ini"
    {
        echo "[global]"
        echo "direct=1"
        echo "ioengine=libaio"
        echo "rw=read"
        echo "bs=1M"
        echo "iodepth=16"
        echo "runtime=$RUNTIME_FULL"
        echo "time_based=1"
        echo "group_reporting=0"
        echo "output-format=json"
        for dev in "${devs[@]}"; do
            local name
            name=$(basename "$dev")
            echo ""
            echo "[job_${name}]"
            echo "filename=$dev"
        done
    } > "$fio_cfg"

    local parallel_out="$LOG_DIR/fio_parallel_result.json"
    fio "$fio_cfg" --output="$parallel_out" --output-format=json > /dev/null 2>&1 || true

    if [[ -f "$parallel_out" ]]; then
        local agg_bw
        agg_bw=$(python3 -c "
import json
d=json.load(open('$parallel_out'))
total=sum(j['read']['bw'] for j in d['jobs'])
print(round(total/1024,1))
" 2>/dev/null || echo "?")
        info "  Aggregate sequential read: ${agg_bw} MB/s across ${#devs[@]} disks"

        # Per-disk numbers
        python3 - "$parallel_out" "${devs[@]}" <<'PYEOF' 2>/dev/null || true
import json, sys
data = json.load(open(sys.argv[1]))
devs = sys.argv[2:]
for job in data['jobs']:
    bw = round(job['read']['bw']/1024, 1)
    print(f"  {job['jobname']}: {bw} MB/s")
PYEOF
        pass "Multi-disk parallel test completed — see log for per-disk breakdown"
    fi
}

# =============================================================================
# FILESYSTEM LAYER TEST  (catches overlayfs/XFS-style stalls)
# =============================================================================

test_filesystem() {
    local dev="$1"
    local devname
    devname=$(basename "$dev")

    # Find a mounted filesystem on this device or a partition of it
    local mount_point
    mount_point=$(lsblk -n -o MOUNTPOINT "$dev" 2>/dev/null | grep -v '^$' | head -1 || true)

    # Also check partitions
    if [[ -z "$mount_point" ]]; then
        mount_point=$(lsblk -n -o MOUNTPOINT "${dev}"* 2>/dev/null | grep -v '^$' | head -1 || true)
    fi

    if [[ -z "$mount_point" ]]; then
        info "  No mounted filesystem found on $dev — skipping FS layer test"
        return
    fi

    log "Filesystem layer test: $mount_point (on $dev)"

    local fstype
    fstype=$(findmnt -n -o FSTYPE "$mount_point" 2>/dev/null || echo "unknown")
    info "  Filesystem: $fstype at $mount_point"

    local testfile="$mount_point/.disktest_$RANDOM"

    # fsync latency test (critical for Docker/overlay workloads)
    run_fio "$testfile" "fs_fsync" \
        --ioengine=sync --rw=write --bs=4k --iodepth=1 \
        --fsync=1 --numjobs=1 --runtime=30 --time_based \
        --fallocate=none

    info "  fsync write: ${FIO_BW_WRITE} MB/s  (p99 lat: ${FIO_LAT_P99_US} µs)"
    if python3 -c "exit(0 if float('${FIO_LAT_P99_US}') <= 50000 and float('${FIO_LAT_P99_US}') > 0 else 1)" 2>/dev/null; then
        pass "$dev — FS fsync p99 latency: ${FIO_LAT_P99_US} µs"
    else
        warn "$dev — FS fsync p99 latency: ${FIO_LAT_P99_US} µs (may indicate FS stalls)"
    fi

    rm -f "$testfile"* 2>/dev/null || true
}

# =============================================================================
# TOPOLOGY / CONTROLLER INFO
# =============================================================================

show_topology() {
    header "Disk Topology"

    log "Block device tree:"
    lsblk -o NAME,TYPE,SIZE,ROTA,SCHED,MODEL,TRAN 2>/dev/null || lsblk

    # PCIe info for NVMe drives
    if ${HAS_LSPCI:-false}; then
        local nvme_controllers
        nvme_controllers=$(lspci 2>/dev/null | grep -i "Non-Volatile\|NVMe\|AHCI\|SATA" || true)
        if [[ -n "$nvme_controllers" ]]; then
            echo ""
            log "Storage controllers (lspci):"
            echo "$nvme_controllers" | while IFS= read -r line; do
                info "  $line"
            done
        fi
    fi

    # RAID / LVM / ZFS summary
    if [[ -f /proc/mdstat ]]; then
        local md_summary
        md_summary=$(grep -v "^$\|Personalities\|unused" /proc/mdstat 2>/dev/null || true)
        if [[ -n "$md_summary" ]]; then
            echo ""
            log "Software RAID (mdstat):"
            echo "$md_summary" | while IFS= read -r line; do info "  $line"; done
        fi
    fi

    if command -v pvs &>/dev/null; then
        local lvm_summary
        lvm_summary=$(pvs 2>/dev/null || true)
        if [[ -n "$lvm_summary" ]]; then
            echo ""
            log "LVM Physical Volumes:"
            echo "$lvm_summary" | while IFS= read -r line; do info "  $line"; done
        fi
    fi

    if command -v zpool &>/dev/null; then
        local zfs_summary
        zfs_summary=$(zpool list 2>/dev/null || true)
        if [[ -n "$zfs_summary" ]] && ! echo "$zfs_summary" | grep -q "no pools"; then
            echo ""
            log "ZFS Pools:"
            echo "$zfs_summary" | while IFS= read -r line; do info "  $line"; done
        fi
    fi
}

# =============================================================================
# JSON OUTPUT
# =============================================================================

emit_json() {
    local json_file="$LOG_DIR/disktest_results.json"

    python3 - "$json_file" <<PYEOF
import json, sys, datetime

results = {
    "timestamp": datetime.datetime.utcnow().isoformat() + "Z",
    "host": open("/etc/hostname").read().strip() if open("/etc/hostname") else "unknown",
    "mode": "${MODE}",
    "devices": {},
    "summary": {
        "passed": len([r for r in """${RESULTS[*]:-}""".split("\n") if r.startswith("PASS")]),
        "failed": len([r for r in """${RESULTS[*]:-}""".split("\n") if r.startswith("FAIL")]),
        "warned": len([r for r in """${RESULTS[*]:-}""".split("\n") if r.startswith("WARN")]),
    },
    "all_results": """${RESULTS[*]:-}""".split("\n") if """${RESULTS[*]:-}""" else []
}

with open(sys.argv[1], "w") as f:
    json.dump(results, f, indent=2)

print(json.dumps(results, indent=2))
PYEOF
}

# =============================================================================
# FINAL SUMMARY
# =============================================================================

print_summary() {
    header "Test Summary"

    local total=${#RESULTS[@]}
    local passed failed warned
    passed=$(printf '%s\n' "${RESULTS[@]:-}" | grep -c "^PASS:" || true)
    failed=$(printf '%s\n' "${RESULTS[@]:-}" | grep -c "^FAIL:" || true)
    warned=$(printf '%s\n' "${RESULTS[@]:-}" | grep -c "^WARN:" || true)

    echo -e "  Total:   ${BOLD}$total${RESET}"
    echo -e "  ${GREEN}Passed:  $passed${RESET}"
    echo -e "  ${YELLOW}Warned:  $warned${RESET}"
    echo -e "  ${RED}Failed:  $failed${RESET}"
    echo ""

    if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
        echo -e "${RED}${BOLD}FAILURES:${RESET}"
        for f in "${FAILED_TESTS[@]}"; do
            echo -e "  ${RED}✗${RESET} $f"
        done
        echo ""
    fi

    if [[ ${#WARNED_TESTS[@]} -gt 0 ]]; then
        echo -e "${YELLOW}${BOLD}WARNINGS:${RESET}"
        for w in "${WARNED_TESTS[@]}"; do
            echo -e "  ${YELLOW}⚠${RESET} $w"
        done
        echo ""
    fi

    echo -e "Detailed logs: ${CYAN}$LOG_DIR/${RESET}"

    if [[ "$failed" -gt 0 ]]; then
        echo -e "\n${RED}${BOLD}OVERALL: FAIL${RESET}"
        return 1
    elif [[ "$warned" -gt 0 ]]; then
        echo -e "\n${YELLOW}${BOLD}OVERALL: PASS WITH WARNINGS${RESET}"
    else
        echo -e "\n${GREEN}${BOLD}OVERALL: PASS${RESET}"
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║              disktest.sh — Disk Test Suite           ║"
    echo "║         Mode: $(printf '%-40s' "$MODE")║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${RESET}"

    check_prereqs
    discover_devices
    show_topology

    # Safety checks before any I/O (populates DEV_SAFE[])
    check_device_safety

    # Scheduler advisor (runs regardless of mode — info only for health/dry-run)
    advise_schedulers

    # Print estimated runtime and abort if --dry-run
    print_runtime_estimate

    local runtime
    case "$MODE" in
        quick)  runtime="$RUNTIME_SHORT" ;;
        stress) runtime="$RUNTIME_STRESS" ;;
        *)      runtime="$RUNTIME_FULL" ;;
    esac

    for dev in "${DEVICES[@]}"; do
        header "Testing: $dev [${DEV_TYPE[$dev]}] ${DEV_SIZE[$dev]} — ${DEV_MODEL[$dev]}"

        if ! ${DEV_SAFE[$dev]:-false}; then
            warn "$dev — Raw I/O tests SKIPPED: ${DEV_SAFE_MSG[$dev]:-unsafe device}"
            warn "$dev — Running health checks only for this device"
        fi

        # Health checks — always
        check_smart "$dev"

        if [[ "$MODE" == "health" ]]; then
            continue
        fi

        # Sequential — all non-health modes (guarded internally)
        test_sequential "$dev" "$runtime"

        if [[ "$MODE" == "quick" ]]; then
            continue
        fi

        # Full / stress: add random, latency, filesystem
        test_random_io  "$dev" "$runtime"
        test_latency    "$dev" "$runtime"
        test_filesystem "$dev"

        if [[ "$MODE" == "stress" ]]; then
            test_stress "$dev" "$runtime"
        fi
    done

    # Multi-disk parallel test (full/stress with 2+ safe disks)
    local safe_devs=()
    for dev in "${DEVICES[@]}"; do
        ${DEV_SAFE[$dev]:-false} && safe_devs+=("$dev") || true
    done

    if [[ "$MODE" != "health" && "$MODE" != "quick" && ${#safe_devs[@]} -gt 1 ]]; then
        test_parallel "${safe_devs[@]}"
    fi

    if $OUTPUT_JSON; then
        emit_json
    fi

    if $SAVE_BASELINE; then
        local baseline="$LOG_DIR/disktest_baseline.json"
        emit_json > /dev/null 2>&1 || true
        cp "$LOG_DIR/disktest_results.json" "$baseline" 2>/dev/null || true
        log "Baseline saved: $baseline"
    fi

    print_summary
}

main "$@"
