#!/usr/bin/env bash
# =============================================
# CPU Socket Stress Tester
# Stresses one physical CPU/socket at a time
# using all logical threads on that socket
# =============================================

set -euo pipefail

STRESS_TIME=60
CPU_METHOD="matrixprod"
DEFAULT_RUN_DIR="/var/tmp/cpu-test"
GRANULARITY="socket"
RUN_DIR=""
LOG_FILE=""
PROGRESS_FILE=""
SUMMARY_FILE=""
MODE="sequential"        # sequential, socket0, socket1
ENABLE_TEMP=false
RESET_STATE=false
RESET_STATUS_ONLY=false
STATUS_ONLY=false
TOTAL_CPUS=0
SOCKETS=0
PASS_COUNT=0
FAIL_COUNT=0
TARGET_LABELS=()
TARGET_CPUSETS=()

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --mode <mode>      Test mode: sequential, socket0, socket1 (default: sequential)
  --granularity <g>  Target type: socket or thread (default: socket)
  --time <seconds>   Stress duration per target test (default: 60)
  --method <name>    CPU stress method (matrixprod, fft, all, etc.) (default: matrixprod)
  --run-dir <path>   Log/progress directory for this run (default: /var/tmp/cpu-test)
  --reset-state      Clear prior progress/summary state in --run-dir before testing
  --reset-status     Clear prior progress/summary state in the target run dir and exit
  --status           Show the saved summary/progress from --run-dir and exit
  --temp             Enable temperature logging (--tz + sensors)
  -h, --help         Show this help

Examples:
  ./test/cpu-test.sh --mode sequential
  ./test/cpu-test.sh --mode socket0 --time 300 --temp
  ./test/cpu-test.sh --mode sequential --granularity thread
  ./test/cpu-test.sh --mode socket1 --run-dir /var/tmp/cpu-test-socket1 --reset-state
  ./test/cpu-test.sh --status
  ./test/cpu-test.sh --reset-status
EOF
    exit 0
}

append_log() {
    printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

write_summary() {
    local current_target="$1"
    local current_status="$2"
    local current_cpuset="$3"
    local target_labels_csv

    target_labels_csv="$(IFS=,; echo "${TARGET_LABELS[*]}")"

    python3 - "$SUMMARY_FILE" "$RUN_DIR" "$MODE" "$GRANULARITY" "$CPU_METHOD" "$STRESS_TIME" \
        "$TOTAL_CPUS" "$SOCKETS" "$PASS_COUNT" "$FAIL_COUNT" "$current_target" \
        "$current_status" "$current_cpuset" "$target_labels_csv" "$RESET_STATE" <<'PY'
import os
import sys

(
    summary_file,
    run_dir,
    mode,
    granularity,
    cpu_method,
    stress_time,
    total_cpus,
    sockets,
    pass_count,
    fail_count,
    current_target,
    current_status,
    current_cpuset,
    target_labels_csv,
    reset_state,
) = sys.argv[1:]

content = f"""cpu-test.sh run summary
Run dir: {run_dir}
Mode: {mode}
Granularity: {granularity}
Method: {cpu_method}
Per-target runtime: {stress_time}s
Detected logical CPUs: {total_cpus}
Detected sockets: {sockets}
Target labels: {target_labels_csv}
Pass count: {pass_count}
Fail count: {fail_count}
Current target: {current_target}
Current status: {current_status}
Current cpuset: {current_cpuset}
State reset requested: {reset_state}
"""

tmp_file = f"{summary_file}.tmp"
with open(tmp_file, "w", encoding="utf-8") as handle:
    handle.write(content)
    handle.flush()
    os.fsync(handle.fileno())

os.replace(tmp_file, summary_file)
dir_fd = os.open(os.path.dirname(summary_file) or ".", os.O_RDONLY)
try:
    os.fsync(dir_fd)
finally:
    os.close(dir_fd)
PY
}

flush_run_state() {
    sync "$LOG_FILE" "$PROGRESS_FILE" "$SUMMARY_FILE" 2>/dev/null || sync || true
}

resolve_targets() {
    local line cpu socket
    local -a socket_ids
    local -A socket_cpus=()
    local -a cpu_socket_lines

    TOTAL_CPUS="$(nproc --all)"
    mapfile -t cpu_socket_lines < <(lscpu -p=CPU,SOCKET | grep -v '^#' || true)
    if [[ "${#cpu_socket_lines[@]}" -eq 0 ]]; then
        echo "Error: unable to read CPU/socket topology from lscpu" >&2
        exit 1
    fi

    mapfile -t socket_ids < <(
        printf '%s\n' "${cpu_socket_lines[@]}" \
            | awk -F, '{print $2}' \
            | sort -n -u
    )
    SOCKETS="${#socket_ids[@]}"

    for line in "${cpu_socket_lines[@]}"; do
        IFS=, read -r cpu socket <<< "$line"
        [[ "$cpu" =~ ^[0-9]+$ ]] || continue
        if [[ -n "${socket_cpus[$socket]:-}" ]]; then
            socket_cpus[$socket]="${socket_cpus[$socket]},${cpu}"
        else
            socket_cpus[$socket]="${cpu}"
        fi
    done

    case "$GRANULARITY" in
        socket)
            case "$MODE" in
                sequential)
                    for socket in "${socket_ids[@]}"; do
                        TARGET_LABELS+=("socket${socket}")
                        TARGET_CPUSETS+=("${socket_cpus[$socket]}")
                    done
                    ;;
                socket0)
                    [[ -n "${socket_cpus[0]:-}" ]] || { echo "Error: no logical CPUs found for socket0" >&2; exit 1; }
                    TARGET_LABELS=("socket0")
                    TARGET_CPUSETS=("${socket_cpus[0]}")
                    ;;
                socket1)
                    [[ "$SOCKETS" -ge 2 ]] || { echo "Error: --mode socket1 requested, but only ${SOCKETS} socket(s) were detected" >&2; exit 1; }
                    [[ -n "${socket_cpus[1]:-}" ]] || { echo "Error: no logical CPUs found for socket1" >&2; exit 1; }
                    TARGET_LABELS=("socket1")
                    TARGET_CPUSETS=("${socket_cpus[1]}")
                    ;;
                *)
                    echo "Error: invalid --mode '$MODE' (expected sequential, socket0, or socket1)" >&2
                    exit 1
                    ;;
            esac
            ;;
        thread)
            case "$MODE" in
                sequential)
                    for socket in "${socket_ids[@]}"; do
                        IFS=, read -r -a socket_cpu_array <<< "${socket_cpus[$socket]}"
                        for cpu in "${socket_cpu_array[@]}"; do
                            TARGET_LABELS+=("cpu${cpu}")
                            TARGET_CPUSETS+=("${cpu}")
                        done
                    done
                    ;;
                socket0)
                    [[ -n "${socket_cpus[0]:-}" ]] || { echo "Error: no logical CPUs found for socket0" >&2; exit 1; }
                    IFS=, read -r -a socket_cpu_array <<< "${socket_cpus[0]}"
                    for cpu in "${socket_cpu_array[@]}"; do
                        TARGET_LABELS+=("cpu${cpu}")
                        TARGET_CPUSETS+=("${cpu}")
                    done
                    ;;
                socket1)
                    [[ "$SOCKETS" -ge 2 ]] || { echo "Error: --mode socket1 requested, but only ${SOCKETS} socket(s) were detected" >&2; exit 1; }
                    [[ -n "${socket_cpus[1]:-}" ]] || { echo "Error: no logical CPUs found for socket1" >&2; exit 1; }
                    IFS=, read -r -a socket_cpu_array <<< "${socket_cpus[1]}"
                    for cpu in "${socket_cpu_array[@]}"; do
                        TARGET_LABELS+=("cpu${cpu}")
                        TARGET_CPUSETS+=("${cpu}")
                    done
                    ;;
                *)
                    echo "Error: invalid --mode '$MODE' (expected sequential, socket0, or socket1)" >&2
                    exit 1
                    ;;
            esac
            ;;
        *)
            echo "Error: invalid --granularity '$GRANULARITY' (expected socket or thread)" >&2
            exit 1
            ;;
    esac

    if [[ "${#TARGET_LABELS[@]}" -eq 0 ]]; then
        echo "Error: no targets matched mode '$MODE' with granularity '$GRANULARITY'" >&2
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="${2:-}"; shift 2 ;;
        --granularity) GRANULARITY="${2:-}"; shift 2 ;;
        --time) STRESS_TIME="${2:-}"; shift 2 ;;
        --method) CPU_METHOD="${2:-}"; shift 2 ;;
        --run-dir) RUN_DIR="${2:-}"; shift 2 ;;
        --reset-state) RESET_STATE=true; shift ;;
        --reset-status) RESET_STATUS_ONLY=true; shift ;;
        --status) STATUS_ONLY=true; shift ;;
        --temp) ENABLE_TEMP=true; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

echo "=== CPU Socket Stress Tester ==="

if ! [[ "$STRESS_TIME" =~ ^[0-9]+$ ]] || [[ "$STRESS_TIME" -le 0 ]]; then
    echo "Error: --time must be a positive integer number of seconds" >&2
    exit 1
fi

if [[ -z "$CPU_METHOD" ]]; then
    echo "Error: --method must not be empty" >&2
    exit 1
fi

case "$GRANULARITY" in
    socket|thread) ;;
    *)
        echo "Error: --granularity must be socket or thread" >&2
        exit 1
        ;;
esac

if [[ "$RESET_STATE" == true && -z "$RUN_DIR" ]]; then
    echo "Error: --reset-state requires --run-dir so the prior state location is explicit" >&2
    exit 1
fi

if [[ "$RESET_STATE" == true && "$RESET_STATUS_ONLY" == true ]]; then
    echo "Error: use either --reset-state or --reset-status, not both" >&2
    exit 1
fi

if [[ -n "$RUN_DIR" ]]; then
    mkdir -p "$RUN_DIR"
else
    RUN_DIR="$DEFAULT_RUN_DIR"
    mkdir -p "$RUN_DIR"
fi

LOG_FILE="${RUN_DIR}/stress_test_log.txt"
PROGRESS_FILE="${RUN_DIR}/stress_progress.txt"
SUMMARY_FILE="${RUN_DIR}/stress_summary.txt"

if [[ "$RESET_STATUS_ONLY" == true ]]; then
    rm -f "$PROGRESS_FILE" "$SUMMARY_FILE"
    echo "Cleared status files in $RUN_DIR"
    exit 0
fi

if [[ "$STATUS_ONLY" == true ]]; then
    if [[ -f "$SUMMARY_FILE" ]]; then
        cat "$SUMMARY_FILE"
    else
        echo "No summary file found at $SUMMARY_FILE"
    fi
    if [[ -f "$PROGRESS_FILE" ]]; then
        printf '\nProgress target: %s\n' "$(tr -d '[:space:]' < "$PROGRESS_FILE")"
    else
        printf '\nProgress target: none\n'
    fi
    exit 0
fi

if [[ "$RESET_STATE" == true ]]; then
    rm -f "$PROGRESS_FILE" "$SUMMARY_FILE"
fi

: > "$LOG_FILE"

if ! command -v stress-ng &>/dev/null; then
    echo "Error: stress-ng is not installed!" >&2
    exit 1
fi

resolve_targets

append_log "Detected: $TOTAL_CPUS logical CPUs | $SOCKETS socket(s)"
append_log "Mode: $MODE | Granularity: $GRANULARITY | Time: ${STRESS_TIME}s | Method: $CPU_METHOD | Temp logging: $ENABLE_TEMP"
append_log "Run dir: $RUN_DIR"
append_log "=================================================="
append_log "Testing targets: ${TARGET_LABELS[*]}"
for idx in "${!TARGET_LABELS[@]}"; do
    append_log "  ${TARGET_LABELS[$idx]} -> logical CPUs ${TARGET_CPUSETS[$idx]}"
done
write_summary "not-started" "pending" "n/a"
flush_run_state

RESUME_TARGET=""
if [[ -f "$PROGRESS_FILE" ]]; then
    LAST_TARGET="$(tr -d '[:space:]' < "$PROGRESS_FILE")"
    if [[ -n "$LAST_TARGET" ]]; then
        RESUME_TARGET="$LAST_TARGET"
        append_log "Resuming from target $RESUME_TARGET"
    fi
fi

START_INDEX=0
if [[ -n "$RESUME_TARGET" ]]; then
    for idx in "${!TARGET_LABELS[@]}"; do
        if [[ "${TARGET_LABELS[$idx]}" == "$RESUME_TARGET" ]]; then
            START_INDEX="$idx"
            break
        fi
    done
fi

for (( idx=START_INDEX; idx<${#TARGET_LABELS[@]}; idx++ )); do
    target_label="${TARGET_LABELS[$idx]}"
    cpuset="${TARGET_CPUSETS[$idx]}"
    worker_count="$(awk -F, '{print NF}' <<< "$cpuset")"
    TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

    append_log "[$TIMESTAMP] Starting ${target_label} with logical CPUs ${cpuset} (${worker_count} workers)"
    echo "$target_label" > "$PROGRESS_FILE"
    write_summary "$target_label" "running" "$cpuset"
    flush_run_state

    stress_cmd=(
        stress-ng
        --taskset "$cpuset"
        --cpu "$worker_count"
        --cpu-method "$CPU_METHOD"
        --cpu-load 100
        --timeout "${STRESS_TIME}s"
        --metrics-brief
    )

    if [[ "$ENABLE_TEMP" == true ]]; then
        stress_cmd+=(--tz)
        if command -v sensors &>/dev/null; then
            append_log "[$TIMESTAMP] Current temperatures:"
            sensors 2>/dev/null | tee -a "$LOG_FILE" || true
        else
            append_log "[$TIMESTAMP] Temperature logging requested, but 'sensors' is not installed"
        fi
    fi

    if "${stress_cmd[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        append_log "[$TIMESTAMP] ${target_label} → OK"
        PASS_COUNT=$((PASS_COUNT + 1))
        write_summary "$target_label" "pass" "$cpuset"
    else
        append_log "[$TIMESTAMP] ${target_label} → FAILED!"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        write_summary "$target_label" "fail" "$cpuset"
    fi
    flush_run_state
    sleep 3
done

rm -f "$PROGRESS_FILE"
write_summary "complete" "done" "n/a"
flush_run_state
append_log "[$TIMESTAMP] Test completed for targets: ${TARGET_LABELS[*]}"
append_log "Summary: ${SUMMARY_FILE}"
append_log "Full log: $LOG_FILE"
