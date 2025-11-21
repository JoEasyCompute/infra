#!/usr/bin/env bash
#
# gpu-watchdog.sh
#
# Detects "GPU has fallen off the bus" events and attempts recovery.
# If recovery fails, marks the node as requiring a restart instead of rebooting.
#

set -uo pipefail

LOG_FILE="/var/log/gpu-watchdog.log"
FLAG_FILE="/var/run/gpu_needs_restart"

log() {
    local msg="$*"
    local ts
    ts="$(date --iso-8601=seconds)"
    echo "$ts [$(hostname)] $msg" | tee -a "$LOG_FILE"
}

# 1) Check for relevant kernel messages in the last 5 minutes
if ! journalctl -k --since "5 minutes ago" 2>/dev/null | \
    grep -E "fallen off the bus|Xid .*fallen off the bus" >/dev/null 2>&1; then
    # No recent "fallen off the bus" events detected, exit quietly
    exit 0
fi

log "Detected GPU 'fallen off the bus' event in kernel log (last 5 minutes)."

# 2) Sanity check for nvidia-smi
if ! command -v nvidia-smi >/dev/null 2>&1; then
    log "nvidia-smi not found; cannot manage GPUs. Marking node as requiring restart."
    touch "$FLAG_FILE"
    exit 1
fi

if ! nvidia-smi >/dev/null 2>&1; then
    log "nvidia-smi failed; unable to talk to GPUs. Marking node as requiring restart."
    touch "$FLAG_FILE"
    exit 1
fi

# 3) Try best-effort GPU reset where supported
if nvidia-smi -L >/dev/null 2>&1; then
    mapfile -t GPU_IDS < <(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null || true)
    for gpu in "${GPU_IDS[@]}"; do
        log "Attempting 'nvidia-smi --gpu-reset -i ${gpu}' (may not be supported on all GPUs)."
        if ! nvidia-smi --gpu-reset -i "$gpu" >/dev/null 2>&1; then
            log "GPU ${gpu} reset not supported or failed (this may be normal for GeForce cards)."
        fi
    done
else
    log "nvidia-smi -L failed; skipping per-GPU reset step."
fi

# 4) Try module reload (best effort)
MODULES_DOWN=(nvidia_drm nvidia_modeset nvidia_uvm nvidia)
MODULES_UP=(nvidia nvidia_uvm nvidia_modeset nvidia_drm)

for m in "${MODULES_DOWN[@]}"; do
    if lsmod | awk '{print $1}' | grep -q "^${m}$"; then
        log "Unloading module ${m}."
        if ! modprobe -r "$m" 2>>"$LOG_FILE"; then
            log "Failed to unload ${m} (likely still in use). Continuing."
        fi
    fi
done

for m in "${MODULES_UP[@]}"; do
    if ! lsmod | awk '{print $1}' | grep -q "^${m}$"; then
        log "Loading module ${m}."
        if ! modprobe "$m" 2>>"$LOG_FILE"; then
            log "Failed to load ${m}. Continuing."
        fi
    fi
done

# 5) Final check – did we recover?
if nvidia-smi >/dev/null 2>&1; then
    log "GPU watchdog: recovery appears successful (nvidia-smi OK)."
    if [ -f "$FLAG_FILE" ]; then
        rm -f "$FLAG_FILE"
    fi
    exit 0
else
    log "GPU watchdog: automatic recovery failed; node requires restart."
    touch "$FLAG_FILE"
    # Optional broadcast to any logged-in users
    echo "GPU watchdog on $(hostname): GPU has fallen off the bus and automatic recovery failed; node requires restart." | wall 2>/dev/null || true
    exit 1
fi
