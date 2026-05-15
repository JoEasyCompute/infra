#!/bin/bash
# =============================================
# Generic Single-Logical-CPU Stress Test Script
# Auto-detects total logical CPUs on any system
# With resume support if the server freezes
# =============================================

set -euo pipefail

# ================== CONFIGURATION ==================
STRESS_TIME=60          # Seconds per logical CPU (change as needed)
CPU_METHOD="matrixprod" # Good options: matrixprod, fft, all, sse, avx, etc.
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

# Check stress-ng
if ! command -v stress-ng &> /dev/null; then
    echo "Error: stress-ng is not installed!" >&2
    echo "Install with: sudo apt install stress-ng  (or dnf/yum equivalent)" >&2
    exit 1
fi

# Resume from last progress if exists
if [ -f "$PROGRESS_FILE" ]; then
    LAST_CPU=$(cat "$PROGRESS_FILE" | tr -d '[:space:]')
    if [[ "$LAST_CPU" =~ ^[0-9]+$ ]] && [ "$LAST_CPU" -lt "$TOTAL_CPUS" ]; then
        echo "Resuming from logical CPU $LAST_CPU (previous run was interrupted)"
        START_CPU=$LAST_CPU
    else
        START_CPU=0
    fi
else
    START_CPU=0
fi

echo "Starting test from logical CPU $START_CPU" | tee -a "$LOG_FILE"

for (( cpu=START_CPU; cpu<TOTAL_CPUS; cpu++ )); do
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$TIMESTAMP] Starting logical CPU $cpu / $TOTAL_CPUS" | tee -a "$LOG_FILE"

    # Save progress BEFORE starting the test (important for crash recovery)
    echo "$cpu" > "$PROGRESS_FILE"

    # Run the stress test with timeout
    if timeout "${STRESS_TIME}s" stress-ng \
        --taskset "$cpu" \
        --cpu 1 \
        --cpu-method "$CPU_METHOD" \
        --cpu-load 100 \
        --metrics-brief 2>&1 | tee -a "$LOG_FILE"; then

        echo "[$TIMESTAMP] Logical CPU $cpu completed successfully" | tee -a "$LOG_FILE"
    else
        echo "[$TIMESTAMP] Logical CPU $cpu FAILED or timed out" | tee -a "$LOG_FILE"
        # Optional: uncomment to pause on failure
        # read -p "Press Enter to continue to next CPU..."
    fi

    sleep 3   # Small cooldown between tests
done

# Cleanup when finished
rm -f "$PROGRESS_FILE"

echo "=================================================="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Test completed! All $TOTAL_CPUS logical CPUs processed." | tee -a "$LOG_FILE"
echo "Full log: $LOG_FILE"
