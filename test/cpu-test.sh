#!/bin/bash
# =============================================
# Smart Single-Logical-CPU Stress Tester
# With socket support + optional temperature logging
# =============================================

set -euo pipefail

# Default values
STRESS_TIME=60
CPU_METHOD="matrixprod"
LOG_FILE="stress_test_log.txt"
PROGRESS_FILE="stress_progress.txt"
MODE="sequential"        # sequential, socket0, socket1
ENABLE_TEMP=false

# ================== Help ==================
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --mode <mode>      Test mode: sequential, socket0, socket1 (default: sequential)
  --time <seconds>   Stress duration per logical CPU (default: 60)
  --method <name>    CPU stress method (matrixprod, fft, all, etc.) (default: matrixprod)
  --temp             Enable temperature logging (--tz + sensors)
  -h, --help         Show this help

Examples:
  ./stress_single_cpu.sh --mode socket0 --time 45 --temp
  ./stress_single_cpu.sh --mode socket1 --method fft
  ./stress_single_cpu.sh --mode sequential
EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --mode)    MODE="$2"; shift 2 ;;
        --time)    STRESS_TIME="$2"; shift 2 ;;
        --method)  CPU_METHOD="$2"; shift 2 ;;
        --temp)    ENABLE_TEMP=true; shift ;;
        -h|--help) usage ;;
        *)         echo "Unknown option: $1"; usage ;;
    esac
done

echo "=== Smart Single-CPU Stress Tester ==="

# Auto-detection
TOTAL_CPUS=$(nproc --all)
SOCKETS=$(lscpu | grep -i "^Socket(s):" | awk '{print $2}' || echo 1)

echo "Detected: $TOTAL_CPUS logical CPUs | $SOCKETS socket(s)"
echo "Mode: $MODE | Time: ${STRESS_TIME}s | Method: $CPU_METHOD | Temp logging: $ENABLE_TEMP"
echo "==================================================" | tee -a "$LOG_FILE"

if ! command -v stress-ng &> /dev/null; then
    echo "Error: stress-ng is not installed!" >&2
    exit 1
fi

# Determine CPU range
if [ "$MODE" = "socket0" ]; then
    START_CPU=0
    END_CPU=$((TOTAL_CPUS / SOCKETS - 1))
elif [ "$MODE" = "socket1" ]; then
    START_CPU=$((TOTAL_CPUS / SOCKETS))
    END_CPU=$((TOTAL_CPUS - 1))
else
    START_CPU=0
    END_CPU=$((TOTAL_CPUS - 1))
fi

echo "Testing logical CPUs $START_CPU to $END_CPU" | tee -a "$LOG_FILE"

# Resume support
if [ -f "$PROGRESS_FILE" ]; then
    LAST_CPU=$(cat "$PROGRESS_FILE" | tr -d '[:space:]')
    if [[ "$LAST_CPU" =~ ^[0-9]+$ ]] && [ "$LAST_CPU" -ge "$START_CPU" ] && [ "$LAST_CPU" -le "$END_CPU" ]; then
        echo "Resuming from logical CPU $LAST_CPU" | tee -a "$LOG_FILE"
        START_CPU=$LAST_CPU
    fi
fi

for (( cpu=START_CPU; cpu<=END_CPU; cpu++ )); do
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$TIMESTAMP] Starting logical CPU $cpu" | tee -a "$LOG_FILE"

    # Save progress BEFORE test
    echo "$cpu" > "$PROGRESS_FILE"

    # Build stress-ng command
    CMD="stress-ng --taskset $cpu --cpu 1 --cpu-method $CPU_METHOD --cpu-load 100 --timeout ${STRESS_TIME}s --metrics-brief"

    if [ "$ENABLE_TEMP" = true ]; then
        CMD="$CMD --tz"
        # Optional: Show current sensors reading
        echo "[$TIMESTAMP] Current temperatures:" | tee -a "$LOG_FILE"
        sensors 2>/dev/null | tee -a "$LOG_FILE" || true
    fi

    # Run the test
    if $CMD 2>&1 | tee -a "$LOG_FILE"; then
        echo "[$TIMESTAMP] Logical CPU $cpu → OK" | tee -a "$LOG_FILE"
    else
        echo "[$TIMESTAMP] Logical CPU $cpu → FAILED!" | tee -a "$LOG_FILE"
    fi

    sleep 3
done

rm -f "$PROGRESS_FILE"
echo "[$TIMESTAMP] Test completed for range $START_CPU-$END_CPU" | tee -a "$LOG_FILE"
echo "Full log: $LOG_FILE"
