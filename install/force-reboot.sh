#!/usr/bin/env bash

set -euo pipefail

DRY_RUN=true
SYSRQ_PATH="/proc/sys/kernel/sysrq"
SYSRQ_TRIGGER="/proc/sysrq-trigger"
SYSRQ_ORIG=""
SYSRQ_ENABLED=0

usage() {
    cat <<'USAGE'
Usage: force-reboot.sh [--yes] [--dry-run] [--help]

Emergency in-band reboot helper using kernel SysRq.

Default behavior:
  - dry-run only
  - prints the reboot plan and the out-of-band fallback hint

Options:
  --yes      Execute the SysRq reboot sequence
  --dry-run  Print the plan only, do not touch SysRq
  --help     Show this help

Sequence when executed:
  1. Enable SysRq
  2. Sync filesystems
  3. Remount filesystems read-only
  4. Trigger an immediate reboot

Fallback:
  If the host does not come back, use install/ipmi-power-cycle.sh from an
  operator machine with BMC/IPMI access.
USAGE
}

log() {
    printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
    printf '[%s] WARN: %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2
}

fail() {
    printf '[%s] ERROR: %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2
    exit 1
}

restore_sysrq() {
    if [[ "$SYSRQ_ENABLED" -eq 1 && -n "$SYSRQ_ORIG" && -w "$SYSRQ_PATH" ]]; then
        printf '%s\n' "$SYSRQ_ORIG" > "$SYSRQ_PATH" || true
    fi
}

trap restore_sysrq EXIT INT TERM

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)
            DRY_RUN=false
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "Unknown option: $1"
            ;;
    esac
done

log "Emergency reboot helper"

if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: no changes will be made."
    log "Plan:"
    log "  1. Enable SysRq"
    log "  2. Sync filesystems"
    log "  3. Remount filesystems read-only"
    log "  4. Trigger immediate reboot"
    warn "Out-of-band fallback: use install/ipmi-power-cycle.sh from an operator machine if the host does not return."
    exit 0
fi

if [[ "$EUID" -ne 0 ]]; then
    fail "Please run with sudo or as root."
fi

if [[ ! -w "$SYSRQ_PATH" || ! -w "$SYSRQ_TRIGGER" ]]; then
    fail "SysRq interfaces are not writable on this host."
fi

SYSRQ_ORIG="$(cat "$SYSRQ_PATH" 2>/dev/null || true)"
[[ -n "$SYSRQ_ORIG" ]] || fail "Unable to read current SysRq state."

log "SysRq path       : $SYSRQ_PATH"
log "SysRq trigger    : $SYSRQ_TRIGGER"
log "Current SysRq    : $SYSRQ_ORIG"

log "Executing emergency reboot sequence."
warn "Out-of-band fallback: if the host does not return, use install/ipmi-power-cycle.sh from an operator machine."

log "Step 1/4: enabling SysRq"
printf '1\n' > "$SYSRQ_PATH"
SYSRQ_ENABLED=1

log "Step 2/4: syncing filesystems"
printf 's\n' > "$SYSRQ_TRIGGER"
sleep 1

log "Step 3/4: remounting filesystems read-only"
printf 'u\n' > "$SYSRQ_TRIGGER"
sleep 1

log "Step 4/4: triggering immediate reboot"
printf 'b\n' > "$SYSRQ_TRIGGER"
