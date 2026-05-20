#!/usr/bin/env bash
#
# Optional installer for the RAID / ESP redundancy lane.
#
# By default this only stages the helper scripts into /usr/local/sbin
# so they are available on RAID hosts without changing apt/systemd
# behavior on non-RAID machines.
#
# Use --activate to install the apt hook and systemd units, and
# --bootstrap to run the one-time ESP population / UEFI registration
# step after activation.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${SCRIPT_DIR}/raid"

DEST_SBIN="/usr/local/sbin"
DEST_APT_HOOK="/etc/apt/apt.conf.d"
DEST_SYSTEMD="/etc/systemd/system"

STAGE_ONLY=true
ACTIVATE=false
BOOTSTRAP=false
DRY_RUN=false
FORCE=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install the optional RAID / ESP redundancy helpers from install/raid/.

Default behavior:
  - installs the helper scripts into /usr/local/sbin
  - does NOT install the apt hook or systemd units
  - has no effect on non-RAID hosts unless --activate is used

Options:
  --activate      Install apt hook + systemd timer/service and enable the timer
  --bootstrap     Run setup-esp-redundancy.sh after installation
  --force         Skip the UEFI / multi-ESP safety checks for activation
  --dry-run       Show the actions without making changes
  -h, --help      Show this help

Examples:
  sudo $(basename "$0")
  sudo $(basename "$0") --activate
  sudo $(basename "$0") --activate --bootstrap
  $(basename "$0") --dry-run --activate
EOF
    exit 0
}

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "This installer must be run as root. Re-run with sudo."
        exit 1
    fi
}

have_uefi() {
    [[ -d /sys/firmware/efi ]]
}

count_esps() {
    local guid="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
    lsblk -rno PARTTYPE 2>/dev/null | awk -v t="$guid" 'tolower($1)==t {c++} END {print c+0}'
}

activation_safety_checks() {
    local esp_count

    if ! have_uefi; then
        if [[ "$DRY_RUN" == true ]]; then
            warn "UEFI boot not detected; a real activation would fail on this host."
        else
            error "UEFI boot not detected. Use --force only if you know the host is suitable."
            exit 1
        fi
    fi

    if ! command -v lsblk >/dev/null 2>&1; then
        if [[ "$DRY_RUN" == true ]]; then
            warn "lsblk is not available; a real activation would fail the ESP count check."
            return 0
        fi
        error "lsblk not found. Install util-linux before using --activate."
        exit 1
    fi

    esp_count="$(count_esps)"
    if (( esp_count < 2 )); then
        if [[ "$DRY_RUN" == true ]]; then
            warn "Only ${esp_count} ESP found; a real activation would fail on this host."
        else
            error "Only ${esp_count} ESP found. RAID activation is intended for multi-disk ESP setups."
            error "Use stage-only mode on non-RAID hosts, or pass --force to override."
            exit 1
        fi
    fi
}

run() {
    if [[ "$DRY_RUN" == true ]]; then
        printf '[DRY-RUN] '
        printf '%q ' "$@"
        printf '\n'
    else
        "$@"
    fi
}

install_file() {
    local src="$1" dest_dir="$2" mode="$3"
    local dst="${dest_dir}/$(basename "$src")"
    [[ -f "$src" ]] || { error "Missing source file: $src"; exit 1; }
    run install -d -m 0755 "$dest_dir"
    run install -m "$mode" "$src" "$dst"
    info "staged $(basename "$src") -> $dst"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --activate)
            ACTIVATE=true
            STAGE_ONLY=false
            shift
            ;;
        --bootstrap)
            BOOTSTRAP=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Unknown argument: $1"
            usage
            ;;
    esac
done

if [[ "$STAGE_ONLY" == true && "$BOOTSTRAP" == true ]]; then
    error "--bootstrap requires --activate"
    exit 1
fi

if [[ "$DRY_RUN" == false ]]; then
    require_root
fi

[[ -d "$SOURCE_DIR" ]] || { error "Source directory not found: $SOURCE_DIR"; exit 1; }

info "Source: $SOURCE_DIR"
MODE_DESC="stage-only"
[[ "$ACTIVATE" == true ]] && MODE_DESC="activate"
[[ "$BOOTSTRAP" == true ]] && MODE_DESC="${MODE_DESC} + bootstrap"
info "Mode:   ${MODE_DESC}"

install_file "$SOURCE_DIR/sync-esp.sh" "$DEST_SBIN" 0755
install_file "$SOURCE_DIR/setup-esp-redundancy.sh" "$DEST_SBIN" 0755

if [[ "$ACTIVATE" == true ]]; then
    if [[ "$FORCE" == false ]]; then
        activation_safety_checks
    fi

    install_file "$SOURCE_DIR/99-sync-esp" "$DEST_APT_HOOK" 0644
    install_file "$SOURCE_DIR/sync-esp.service" "$DEST_SYSTEMD" 0644
    install_file "$SOURCE_DIR/sync-esp.timer" "$DEST_SYSTEMD" 0644

    run systemctl daemon-reload
    run systemctl enable --now sync-esp.timer
    if [[ "$DRY_RUN" == true ]]; then
        success "RAID sync timer would be enabled"
    else
        success "RAID sync timer enabled"
    fi
fi

if [[ "$BOOTSTRAP" == true ]]; then
    if [[ ! -x "${DEST_SBIN}/setup-esp-redundancy.sh" ]]; then
        error "Expected ${DEST_SBIN}/setup-esp-redundancy.sh to be installed first"
        exit 1
    fi
    run "${DEST_SBIN}/setup-esp-redundancy.sh"
fi

cat <<EOF

Done.
- Helper scripts are installed in ${DEST_SBIN}
- Apt hook / timer are $([[ "$ACTIVATE" == true ]] && [[ "$DRY_RUN" == true ]] && echo "scheduled for installation" || ([[ "$ACTIVATE" == true ]] && echo "enabled" || echo "not installed"))
- Non-RAID hosts are unaffected unless you explicitly used --activate
EOF
