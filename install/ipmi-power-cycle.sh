#!/usr/bin/env bash
#
# ipmi-power-cycle.sh
#
# Out-of-band BMC/IPMI power-cycle helper for GPU nodes that cannot complete
# an in-band Linux reboot after a GPU falls off the PCIe bus.
#

set -euo pipefail

IPMI_HOST=""
IPMI_USER="${IPMI_USER:-ADMIN}"
IPMI_INTERFACE="${IPMI_INTERFACE:-lanplus}"
IPMI_TIMEOUT="${IPMI_TIMEOUT:-10}"
CONFIRM="false"

usage() {
    cat <<'USAGE'
Usage: ipmi-power-cycle.sh --host <bmc-ip-or-dns> [OPTIONS]

Out-of-band IPMI power-cycle helper. Target the BMC/IPMI address, not the
host OS address. The script checks current chassis power status first and
requires --yes before sending the destructive power-cycle command.

Options:
  --host <ip-or-dns>       BMC/IPMI address to target (required)
  --user <user>            IPMI username (default: ADMIN, or IPMI_USER)
  --interface <name>       ipmitool interface (default: lanplus, or IPMI_INTERFACE)
  --timeout <seconds>      ipmitool timeout wrapper (default: 10, or IPMI_TIMEOUT)
  --yes                    Actually run 'chassis power cycle'
  -h, --help               Show this help

Password handling:
  Set IPMI_PASS or IPMI_PASSWORD to avoid an interactive prompt. If neither is
  set and stdin is a TTY, the script prompts securely. The password is passed
  to ipmitool via the IPMI_PASSWORD environment variable with '-E' so it is not
  placed on the ipmitool command line.

Examples:
  IPMI_PASS='secret' ./ipmi-power-cycle.sh --host 192.0.2.50 --user ADMIN
  IPMI_PASS='secret' ./ipmi-power-cycle.sh --host 192.0.2.50 --user ADMIN --yes
USAGE
}

log() {
    printf '%s\n' "$*"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

run_ipmitool() {
    local password="$1"
    shift

    IPMI_PASSWORD="${password}" timeout "${IPMI_TIMEOUT}" \
        ipmitool -I "${IPMI_INTERFACE}" -H "${IPMI_HOST}" -U "${IPMI_USER}" -E "$@"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)
            [[ $# -ge 2 ]] || fail "--host requires a value"
            IPMI_HOST="$2"
            shift 2
            ;;
        --user)
            [[ $# -ge 2 ]] || fail "--user requires a value"
            IPMI_USER="$2"
            shift 2
            ;;
        --interface)
            [[ $# -ge 2 ]] || fail "--interface requires a value"
            IPMI_INTERFACE="$2"
            shift 2
            ;;
        --timeout)
            [[ $# -ge 2 ]] || fail "--timeout requires a value"
            IPMI_TIMEOUT="$2"
            shift 2
            ;;
        --yes)
            CONFIRM="true"
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

[[ -n "${IPMI_HOST}" ]] || { usage; fail "--host is required"; }
[[ "${IPMI_TIMEOUT}" =~ ^[0-9]+$ ]] || fail "--timeout must be a positive integer"
[[ "${IPMI_TIMEOUT}" -gt 0 ]] || fail "--timeout must be greater than zero"

require_command timeout
require_command ipmitool

IPMI_PASS_VALUE="${IPMI_PASS:-${IPMI_PASSWORD:-}}"
if [[ -z "${IPMI_PASS_VALUE}" ]]; then
    if [[ -t 0 ]]; then
        printf 'IPMI password for %s@%s: ' "${IPMI_USER}" "${IPMI_HOST}" >&2
        read -r -s IPMI_PASS_VALUE
        printf '\n' >&2
    else
        fail "Set IPMI_PASS or IPMI_PASSWORD when running non-interactively"
    fi
fi

log "Target BMC      : ${IPMI_HOST}"
log "IPMI user       : ${IPMI_USER}"
log "IPMI interface  : ${IPMI_INTERFACE}"
log "Command timeout : ${IPMI_TIMEOUT}s"
log ""
log "Checking chassis power status..."
if ! run_ipmitool "${IPMI_PASS_VALUE}" chassis power status; then
    fail "Unable to read chassis power status from ${IPMI_HOST}"
fi

if [[ "${CONFIRM}" != "true" ]]; then
    log ""
    log "DRY RUN: not sending chassis power cycle. Re-run with --yes to execute."
    exit 0
fi

log ""
log "Sending IPMI chassis power cycle to ${IPMI_HOST}..."
run_ipmitool "${IPMI_PASS_VALUE}" chassis power cycle
log "Power-cycle command accepted. Monitor the BMC/host console for reboot progress."
