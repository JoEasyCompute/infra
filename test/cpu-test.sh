#!/bin/bash
# =============================================
# Generic Single-Logical-CPU Stress Test Script
# Auto-detects CPUs + uses native --timeout
# =============================================

set -euo pipefail

# ================== CONFIGURATION ==================
STRESS_TIME=60          # Seconds per logical CPU
CPU_METHOD="matrixprod" # matrixprod, fft, all, etc.
LOG_FILE="stress_test_log.txt"
PROGRESS_FILE="stress_progress.txt"
# ===================================================

echo "=== Generic Single-Logical-CPU Stress Test ==="

# Auto-detect number of logical CPUs
if command -v nproc &> /dev/null; then
    TOTAL_CPUS=$(nproc --all)
else
    TOTAL_CPUS=$(grep -c '^processor' /proc/cpuinfo)
fi

echo "Detected $TOTAL_CPUS logical CPUs"
echo "Time per CPU: ${STRESS_TIME}s | Method: $CPU_METHOD"
echo "Log: $LOG_FILE | Progress: $PROGRESS_FILE"
echo "=================================================="

if ! command -v stress-ng &> /dev/null; then
    echo "Error: stress-ng is not installed!" >&2
    echo "Install it first (apt/dnf/yum)." >&2
    exit 1
fi

# Resume support
if [ -f "$PROGRESS_FILE" ]; then
    LAST_CPU=$(cat "$PROGRESS_FILE" | tr -d '[:space:]')
    if [[ "$LAST_CPU" =~ ^[0-9]+$ ]] && [ "$LAST_CPU" -lt "$TOTAL_CPUS" ]; then
        echo "Resuming from logical CPU $LAST_CPU"
        START_CPU=$LAST_CPU
    else
        START_CPU=0
    fi
else
    START_CPU=0
fi

echo "Starting from logical CPU $START_CPU" | tee -a "$LOG_FILE"

for (( cpu=START_CPU; cpu<TOTAL_CPUS; cpu++ )); do
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$TIMESTAMP] Starting logical CPU $cpu / $TOTAL_CPUS" | tee -a "$LOG_FILE"

    # Save progress BEFORE test
    echo "$cpu" > "$PROGRESS_FILE"

    # Native stress-ng timeout (recommended)
    if stress-ng \
        --taskset "$cpu" \
        --cpu 1 \
        --cpu-method "$CPU_METHOD" \
        --cpu-load 100 \
        --timeout "${STRESS_TIME}s" \
        --metrics-brief 2>&1 | tee -a "$LOG_FILE"; then

        echo "[$TIMESTAMP] Logical CPU $cpu completed successfully" | tee -a "$LOG_FILE"
    else
        echo "[$TIMESTAMP] Logical CPU $cpu FAILED (exit code $?)" | tee -a "$LOG_FILE"
    fi

    sleep 3   # cooldown
done

rm -f "$PROGRESS_FILE"
echo "=================================================="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Test completed! All $TOTAL_CPUS logical CPUs done." | tee -a "$LOG_FILE"
