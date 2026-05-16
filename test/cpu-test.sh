#!/bin/bash
# =============================================
# Smart Single-Logical-CPU Stress Tester
# With socket support + optional temperature logging
# =============================================

set -euo pipefail

# Default values
STRESS_TIME=60
CPU_METHOD="matrixprod"
BASE_LOG_DIR="/tmp"
RUN_DIR=""
LOG_FILE=""
PROGRESS_FILE=""
SUMMARY_FILE=""
MODE="sequential"        # sequential, socket0, socket1
ENABLE_TEMP=false
CPU_LIST=()
PASS_COUNT=0
FAIL_COUNT=0

# ================== Help ==================
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --mode <mode>      Test mode: sequential, socket0, socket1 (default: sequential)
  --time <seconds>   Stress duration per logical CPU (default: 60)
  --method <name>    CPU stress method (matrixprod, fft, all, etc.) (default: matrixprod)
  --run-dir <path>   Log/progress directory for this run (default: auto-created under /tmp)
  --temp             Enable temperature logging (--tz + sensors)
  -h, --help         Show this help

Examples:
  ./test/cpu-test.sh --mode socket0 --time 45 --temp
  ./test/cpu-test.sh --mode socket1 --method fft
  ./test/cpu-test.sh --mode sequential
EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --mode)    MODE="${2:-}"; shift 2 ;;
        --time)    STRESS_TIME="${2:-}"; shift 2 ;;
        --method)  CPU_METHOD="${2:-}"; shift 2 ;;
        --run-dir) RUN_DIR="${2:-}"; shift 2 ;;
        --temp)    ENABLE_TEMP=true; shift ;;
        -h|--help) usage ;;
        *)         echo "Unknown option: $1"; usage ;;
    esac
done

echo "=== Smart Single-CPU Stress Tester ==="

case "$MODE" in
    sequential|socket0|socket1) ;;
    *) echo "Error: invalid --mode '$MODE' (expected sequential, socket0, or socket1)" >&2; exit 1 ;;
esac

if ! [[ "$STRESS_TIME" =~ ^[0-9]+$ ]] || [[ "$STRESS_TIME" -le 0 ]]; then
    echo "Error: --time must be a positive integer number of seconds" >&2
    exit 1
fi

if [[ -z "$CPU_METHOD" ]]; then
    echo "Error: --method must not be empty" >&2
    exit 1
fi

if [[ -n "$RUN_DIR" ]]; then
    mkdir -p "$RUN_DIR"
else
    RUN_DIR="$(mktemp -d -p "$BASE_LOG_DIR" cpu-test.XXXXXXXX)"
fi
LOG_FILE="${RUN_DIR}/stress_test_log.txt"
PROGRESS_FILE="${RUN_DIR}/stress_progress.txt"
SUMMARY_FILE="${RUN_DIR}/stress_summary.txt"

write_summary() {
    local current_cpu="$1"
    local current_status="$2"
    local cpu_list_csv
    cpu_list_csv="$(IFS=,; echo "${CPU_LIST[*]}")"

    python3 - "$SUMMARY_FILE" "$RUN_DIR" "$MODE" "$CPU_METHOD" "$STRESS_TIME" \
        "$TOTAL_CPUS" "$SOCKETS" "$PASS_COUNT" "$FAIL_COUNT" "$current_cpu" \
        "$current_status" "$cpu_list_csv" <<'PY'
import os
import sys

(
    summary_file,
    run_dir,
    mode,
    cpu_method,
    stress_time,
    total_cpus,
    sockets,
    pass_count,
    fail_count,
    current_cpu,
    current_status,
    cpu_list_csv,
) = sys.argv[1:]

content = f"""cpu-test.sh run summary
Run dir: {run_dir}
Mode: {mode}
Method: {cpu_method}
Per-CPU runtime: {stress_time}s
Detected logical CPUs: {total_cpus}
Detected sockets: {sockets}
Target CPUs: {cpu_list_csv}
Pass count: {pass_count}
Fail count: {fail_count}
Current CPU: {current_cpu}
Current status: {current_status}
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

# Auto-detection
TOTAL_CPUS=$(nproc --all)
mapfile -t CPU_SOCKET_LINES < <(lscpu -p=CPU,SOCKET | grep -v '^#' || true)
if [[ "${#CPU_SOCKET_LINES[@]}" -eq 0 ]]; then
    echo "Error: unable to read CPU/socket topology from lscpu" >&2
    exit 1
fi
mapfile -t SOCKET_IDS < <(
    printf '%s\n' "${CPU_SOCKET_LINES[@]}" \
        | awk -F, '{print $2}' \
        | sort -n -u
)
SOCKETS="${#SOCKET_IDS[@]}"

echo "Detected: $TOTAL_CPUS logical CPUs | $SOCKETS socket(s)"
echo "Mode: $MODE | Time: ${STRESS_TIME}s | Method: $CPU_METHOD | Temp logging: $ENABLE_TEMP"
echo "Run dir: $RUN_DIR"
echo "==================================================" | tee -a "$LOG_FILE"
write_summary "not-started" "pending"
flush_run_state

if ! command -v stress-ng &> /dev/null; then
    echo "Error: stress-ng is not installed!" >&2
    exit 1
fi

if [[ "$MODE" == "socket1" && "$SOCKETS" -lt 2 ]]; then
    echo "Error: --mode socket1 requested, but only ${SOCKETS} socket(s) were detected" >&2
    exit 1
fi

for line in "${CPU_SOCKET_LINES[@]}"; do
    IFS=, read -r cpu socket <<< "$line"
    [[ "$cpu" =~ ^[0-9]+$ ]] || continue
    case "$MODE" in
        sequential)
            CPU_LIST+=("$cpu")
            ;;
        socket0)
            [[ "$socket" == "0" ]] && CPU_LIST+=("$cpu")
            ;;
        socket1)
            [[ "$socket" == "1" ]] && CPU_LIST+=("$cpu")
            ;;
    esac
done

if [[ "${#CPU_LIST[@]}" -eq 0 ]]; then
    echo "Error: no logical CPUs matched mode '$MODE'" >&2
    exit 1
fi

echo "Testing logical CPUs: ${CPU_LIST[*]}" | tee -a "$LOG_FILE"
write_summary "not-started" "pending"
flush_run_state

# Resume support
RESUME_CPU=""
if [ -f "$PROGRESS_FILE" ]; then
    LAST_CPU=$(cat "$PROGRESS_FILE" | tr -d '[:space:]')
    if [[ "$LAST_CPU" =~ ^[0-9]+$ ]]; then
        echo "Resuming from logical CPU $LAST_CPU" | tee -a "$LOG_FILE"
        RESUME_CPU="$LAST_CPU"
    fi
fi

START_INDEX=0
if [[ -n "$RESUME_CPU" ]]; then
    for idx in "${!CPU_LIST[@]}"; do
        if [[ "${CPU_LIST[$idx]}" == "$RESUME_CPU" ]]; then
            START_INDEX="$idx"
            break
        fi
    done
fi

for (( idx=START_INDEX; idx<${#CPU_LIST[@]}; idx++ )); do
    cpu="${CPU_LIST[$idx]}"
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$TIMESTAMP] Starting logical CPU $cpu" | tee -a "$LOG_FILE"

    # Save progress BEFORE test
    echo "$cpu" > "$PROGRESS_FILE"

    # Build stress-ng command
    stress_cmd=(
        stress-ng
        --taskset "$cpu"
        --cpu 1
        --cpu-method "$CPU_METHOD"
        --cpu-load 100
        --timeout "${STRESS_TIME}s"
        --metrics-brief
    )

    if [ "$ENABLE_TEMP" = true ]; then
        stress_cmd+=(--tz)
        if command -v sensors &> /dev/null; then
            echo "[$TIMESTAMP] Current temperatures:" | tee -a "$LOG_FILE"
            sensors 2>/dev/null | tee -a "$LOG_FILE" || true
        else
            echo "[$TIMESTAMP] Temperature logging requested, but 'sensors' is not installed" | tee -a "$LOG_FILE"
        fi
    fi

    # Run the test
    if "${stress_cmd[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        echo "[$TIMESTAMP] Logical CPU $cpu → OK" | tee -a "$LOG_FILE"
        ((PASS_COUNT++))
        write_summary "$cpu" "pass"
    else
        echo "[$TIMESTAMP] Logical CPU $cpu → FAILED!" | tee -a "$LOG_FILE"
        ((FAIL_COUNT++))
        write_summary "$cpu" "fail"
    fi
    flush_run_state

    sleep 3
done

rm -f "$PROGRESS_FILE"
write_summary "complete" "done"
flush_run_state
echo "[$TIMESTAMP] Test completed for CPUs: ${CPU_LIST[*]}" | tee -a "$LOG_FILE"
echo "Summary: ${SUMMARY_FILE}" | tee -a "$LOG_FILE"
echo "Full log: $LOG_FILE"
