#!/usr/bin/env bash
# =============================================================================
# docker-storage-layout-convert.sh
# Converts an existing Docker/containerd runtime volume between layouts while
# preserving the existing fstab mount spec, such as UUID=..., /dev/..., or a
# loopback image path.
#
# Default layout:
#   /data/container-runtime            <- XFS volume
#   /data/container-runtime/docker     <- Docker data root
#   /data/container-runtime/containerd <- containerd data root
#   /var/lib/docker                    <- bind mount
#   /var/lib/containerd                <- bind mount
#
# RunPod-compatible layout:
#   /var/lib/docker                    <- XFS volume and Docker data root
#   /var/lib/docker/containerd         <- containerd data root
#   /var/lib/containerd                <- bind mount
# =============================================================================

set -euo pipefail

CONTAINER_RUNTIME_MOUNT="/data/container-runtime"
DOCKER_MOUNTPOINT="/var/lib/docker"
CONTAINERD_MOUNTPOINT="/var/lib/containerd"
DEFAULT_DOCKER_DATA_DIR="${CONTAINER_RUNTIME_MOUNT}/docker"
DEFAULT_CONTAINERD_DATA_DIR="${CONTAINER_RUNTIME_MOUNT}/containerd"
RUNPOD_CONTAINERD_DATA_DIR="${DOCKER_MOUNTPOINT}/containerd"
DAEMON_JSON="/etc/docker/daemon.json"
FSTAB="/etc/fstab"

TO_LAYOUT=""
ASSUME_YES=false
DRY_RUN=false
NO_START=false
SHOW_STATUS=false

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}==> $*${RESET}"; }

usage() {
    cat <<EOF
Usage: sudo $0 --to runpod|default [OPTIONS]

Convert Docker/containerd storage between the default layout and the
RunPod-compatible layout.

Options:
  --to runpod           Convert default layout to RunPod-compatible layout
  --to default          Convert RunPod-compatible layout to default layout
  --yes                 Do not prompt before converting
  --dry-run             Print planned actions without changing the host
  --no-start            Do not restart Docker/containerd after conversion
  --status              Show detected layout and exit
  -h, --help            Show this help

Examples:
  sudo $0 --status
  sudo $0 --to runpod --dry-run
  sudo $0 --to runpod --yes
  sudo $0 --to default --yes
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --to)
            if [[ $# -lt 2 ]]; then
                error "--to requires runpod or default"
                usage
            fi
            TO_LAYOUT="${2:-}"
            shift
            ;;
        --yes) ASSUME_YES=true ;;
        --dry-run) DRY_RUN=true ;;
        --no-start) NO_START=true ;;
        --status) SHOW_STATUS=true ;;
        -h|--help) usage ;;
        *) error "Unknown argument: $1"; usage ;;
    esac
    shift
done

run() {
    if [[ "$DRY_RUN" == true ]]; then
        printf '+ %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

confirm() {
    local prompt="$1"
    if [[ "$ASSUME_YES" == true ]]; then
        info "Auto-confirming: ${prompt}"
        return 0
    fi
    read -rp "$(echo -e "${YELLOW}${prompt} [y/N] ${RESET}")" answer
    [[ "${answer,,}" == "y" ]]
}

require_root_unless_status() {
    if [[ "$SHOW_STATUS" == true || "$DRY_RUN" == true ]]; then
        return 0
    fi
    if [[ $EUID -ne 0 ]]; then
        error "Must be run as root: sudo $0 --to runpod|default"
        exit 1
    fi
}

require_tools() {
    local missing=0
    for cmd in findmnt mountpoint awk sed python3 systemctl; do
        if ! command -v "$cmd" &>/dev/null; then
            error "Required tool not found: $cmd"
            missing=1
        fi
    done
    (( missing == 0 )) || exit 1
}

fstab_line_for_target() {
    local target="$1"
    awk -v target="$target" '
        $0 !~ /^[[:space:]]*#/ && NF >= 2 && $2 == target { print; exit }
    ' "$FSTAB" 2>/dev/null || true
}

fstab_field_for_target() {
    local target="$1" field="$2"
    awk -v target="$target" -v field="$field" '
        $0 !~ /^[[:space:]]*#/ && NF >= 2 && $2 == target { print $field; exit }
    ' "$FSTAB" 2>/dev/null || true
}

remove_fstab_target() {
    local target="$1"
    run sed -i "\|[[:space:]]${target}[[:space:]]|d" "$FSTAB"
}

append_fstab_line() {
    local line="$1"
    if [[ "$DRY_RUN" == true ]]; then
        printf '+ append to %q: %s\n' "$FSTAB" "$line"
    else
        printf '%s\n' "$line" >> "$FSTAB"
    fi
}

backup_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local backup="${file}.layout-convert.$(date +%Y%m%d%H%M%S).bak"
    run cp -a "$file" "$backup"
    info "Backup: ${backup}"
}

detect_layout() {
    local docker_source containerd_source
    docker_source=$(findmnt -n -o SOURCE --target "$DOCKER_MOUNTPOINT" 2>/dev/null || true)
    containerd_source=$(findmnt -n -o SOURCE --target "$CONTAINERD_MOUNTPOINT" 2>/dev/null || true)

    if mountpoint -q "$CONTAINER_RUNTIME_MOUNT" 2>/dev/null \
        && mountpoint -q "$DOCKER_MOUNTPOINT" 2>/dev/null \
        && mountpoint -q "$CONTAINERD_MOUNTPOINT" 2>/dev/null \
        && [[ -d "$DEFAULT_DOCKER_DATA_DIR" ]] \
        && [[ -d "$DEFAULT_CONTAINERD_DATA_DIR" ]]; then
        echo "default"
        return 0
    fi

    if mountpoint -q "$DOCKER_MOUNTPOINT" 2>/dev/null \
        && mountpoint -q "$CONTAINERD_MOUNTPOINT" 2>/dev/null \
        && [[ -d "$RUNPOD_CONTAINERD_DATA_DIR" ]]; then
        if [[ "$containerd_source" == "$RUNPOD_CONTAINERD_DATA_DIR" || -n "$(fstab_line_for_target "$DOCKER_MOUNTPOINT")" ]]; then
            echo "runpod"
            return 0
        fi
    fi

    if [[ -n "$docker_source" || -n "$containerd_source" ]]; then
        echo "unknown"
    else
        echo "none"
    fi
}

show_status() {
    local layout
    layout=$(detect_layout)
    header "Docker storage layout status"
    echo "Detected layout: ${layout}"
    echo "Mounts:"
    for target in "$CONTAINER_RUNTIME_MOUNT" "$DOCKER_MOUNTPOINT" "$CONTAINERD_MOUNTPOINT"; do
        if mountpoint -q "$target" 2>/dev/null; then
            echo "  ${target} <- $(findmnt -n -o SOURCE --target "$target" 2>/dev/null || echo '?')"
        else
            echo "  ${target} <- (not mounted)"
        fi
    done
    echo "fstab entries:"
    for target in "$CONTAINER_RUNTIME_MOUNT" "$DOCKER_MOUNTPOINT" "$CONTAINERD_MOUNTPOINT"; do
        local line
        line=$(fstab_line_for_target "$target")
        echo "  ${target}: ${line:-'(none)'}"
    done
    if [[ -f "$DAEMON_JSON" ]]; then
        echo "Docker data-root:"
        python3 - "$DAEMON_JSON" <<'PYEOF'
import json
import sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    print("  " + str(cfg.get("data-root", "(default)")))
except Exception as exc:
    print("  unreadable: " + str(exc))
PYEOF
    fi
}

stop_services() {
    for svc in docker containerd; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            run systemctl stop "$svc"
            info "Stopped ${svc}"
        fi
    done
}

start_services() {
    [[ "$NO_START" == true ]] && { warn "Skipping service restart by request"; return 0; }
    for svc in containerd docker; do
        run systemctl start "$svc"
        info "Started ${svc}"
    done
}

umount_if_mounted() {
    local target="$1"
    if mountpoint -q "$target" 2>/dev/null; then
        run umount "$target"
    fi
}

set_daemon_data_root() {
    local data_root="$1"
    if [[ "$DRY_RUN" == true ]]; then
        printf '+ set %s data-root to %s\n' "$DAEMON_JSON" "$data_root"
        return 0
    fi
    mkdir -p "$(dirname "$DAEMON_JSON")"
    if [[ -f "$DAEMON_JSON" ]]; then
        python3 - "$DAEMON_JSON" "$data_root" <<'PYEOF'
import json
import sys
path, data_root = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        cfg = json.load(f)
except FileNotFoundError:
    cfg = {}
cfg["data-root"] = data_root
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYEOF
    else
        python3 - "$DAEMON_JSON" "$data_root" <<'PYEOF'
import json
import sys
path, data_root = sys.argv[1], sys.argv[2]
cfg = {"data-root": data_root}
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYEOF
    fi
}

move_children() {
    local src_dir="$1" dest_dir="$2"
    shift 2
    local excludes=("$@")

    run mkdir -p "$dest_dir"

    local moved=0
    shopt -s dotglob nullglob
    for path in "$src_dir"/*; do
        local base skip=false
        base=$(basename "$path")
        for excluded in "${excludes[@]}"; do
            if [[ "$base" == "$excluded" ]]; then
                skip=true
                break
            fi
        done
        [[ "$skip" == true ]] && continue
        if [[ -e "${dest_dir}/${base}" ]]; then
            error "Refusing to overwrite existing target: ${dest_dir}/${base}"
            exit 1
        fi
        run mv "$path" "$dest_dir/"
        moved=$((moved + 1))
    done
    shopt -u dotglob nullglob
    info "Moved ${moved} top-level entries from ${src_dir} to ${dest_dir}"
}

convert_default_to_runpod() {
    header "Convert default layout to RunPod layout"

    local mount_spec fs_type mount_opts dump pass
    mount_spec=$(fstab_field_for_target "$CONTAINER_RUNTIME_MOUNT" 1)
    fs_type=$(fstab_field_for_target "$CONTAINER_RUNTIME_MOUNT" 3)
    mount_opts=$(fstab_field_for_target "$CONTAINER_RUNTIME_MOUNT" 4)
    dump=$(fstab_field_for_target "$CONTAINER_RUNTIME_MOUNT" 5)
    pass=$(fstab_field_for_target "$CONTAINER_RUNTIME_MOUNT" 6)

    [[ -n "$mount_spec" ]] || { error "No fstab entry found for ${CONTAINER_RUNTIME_MOUNT}"; exit 1; }
    [[ -n "$fs_type" ]] || fs_type="xfs"
    [[ -n "$mount_opts" ]] || mount_opts="defaults,noatime,nofail,prjquota"
    [[ -n "$dump" ]] || dump="0"
    [[ -n "$pass" ]] || pass="2"

    confirm "Convert default storage layout to RunPod layout?" || { info "Aborted"; exit 0; }
    backup_file "$FSTAB"
    backup_file "$DAEMON_JSON"
    stop_services

    if [[ ! -d "$DEFAULT_DOCKER_DATA_DIR" ]]; then
        error "Docker data directory not found: ${DEFAULT_DOCKER_DATA_DIR}"
        exit 1
    fi
    move_children "$DEFAULT_DOCKER_DATA_DIR" "$CONTAINER_RUNTIME_MOUNT"
    run rmdir "$DEFAULT_DOCKER_DATA_DIR" 2>/dev/null || true

    umount_if_mounted "$CONTAINERD_MOUNTPOINT"
    umount_if_mounted "$DOCKER_MOUNTPOINT"
    umount_if_mounted "$CONTAINER_RUNTIME_MOUNT"

    remove_fstab_target "$CONTAINER_RUNTIME_MOUNT"
    remove_fstab_target "$DOCKER_MOUNTPOINT"
    remove_fstab_target "$CONTAINERD_MOUNTPOINT"
    append_fstab_line "${mount_spec}  ${DOCKER_MOUNTPOINT}  ${fs_type}  ${mount_opts}  ${dump}  ${pass}"
    append_fstab_line "${RUNPOD_CONTAINERD_DATA_DIR}  ${CONTAINERD_MOUNTPOINT}  none  bind,nofail  0  0"

    run mkdir -p "$DOCKER_MOUNTPOINT" "$CONTAINERD_MOUNTPOINT"
    run mount "$DOCKER_MOUNTPOINT"
    run mkdir -p "$RUNPOD_CONTAINERD_DATA_DIR"
    run mount "$CONTAINERD_MOUNTPOINT"
    set_daemon_data_root "$DOCKER_MOUNTPOINT"
    start_services
    success "Converted to RunPod-compatible layout"
}

convert_runpod_to_default() {
    header "Convert RunPod layout to default layout"

    local mount_spec fs_type mount_opts dump pass
    mount_spec=$(fstab_field_for_target "$DOCKER_MOUNTPOINT" 1)
    fs_type=$(fstab_field_for_target "$DOCKER_MOUNTPOINT" 3)
    mount_opts=$(fstab_field_for_target "$DOCKER_MOUNTPOINT" 4)
    dump=$(fstab_field_for_target "$DOCKER_MOUNTPOINT" 5)
    pass=$(fstab_field_for_target "$DOCKER_MOUNTPOINT" 6)

    [[ -n "$mount_spec" ]] || { error "No fstab entry found for ${DOCKER_MOUNTPOINT}"; exit 1; }
    [[ -n "$fs_type" ]] || fs_type="xfs"
    [[ -n "$mount_opts" ]] || mount_opts="defaults,noatime,nofail,prjquota"
    [[ -n "$dump" ]] || dump="0"
    [[ -n "$pass" ]] || pass="2"

    confirm "Convert RunPod storage layout to default layout?" || { info "Aborted"; exit 0; }
    backup_file "$FSTAB"
    backup_file "$DAEMON_JSON"
    stop_services

    move_children "$DOCKER_MOUNTPOINT" "$DEFAULT_DOCKER_DATA_DIR" "containerd" "docker" "lost+found"
    run mkdir -p "$RUNPOD_CONTAINERD_DATA_DIR"

    umount_if_mounted "$CONTAINERD_MOUNTPOINT"
    umount_if_mounted "$DOCKER_MOUNTPOINT"

    remove_fstab_target "$CONTAINER_RUNTIME_MOUNT"
    remove_fstab_target "$DOCKER_MOUNTPOINT"
    remove_fstab_target "$CONTAINERD_MOUNTPOINT"
    append_fstab_line "${mount_spec}  ${CONTAINER_RUNTIME_MOUNT}  ${fs_type}  ${mount_opts}  ${dump}  ${pass}"
    append_fstab_line "${DEFAULT_DOCKER_DATA_DIR}  ${DOCKER_MOUNTPOINT}  none  bind,nofail  0  0"
    append_fstab_line "${DEFAULT_CONTAINERD_DATA_DIR}  ${CONTAINERD_MOUNTPOINT}  none  bind,nofail  0  0"

    run mkdir -p "$CONTAINER_RUNTIME_MOUNT" "$DOCKER_MOUNTPOINT" "$CONTAINERD_MOUNTPOINT"
    run mount "$CONTAINER_RUNTIME_MOUNT"
    run mkdir -p "$DEFAULT_DOCKER_DATA_DIR" "$DEFAULT_CONTAINERD_DATA_DIR"
    run mount "$DOCKER_MOUNTPOINT"
    run mount "$CONTAINERD_MOUNTPOINT"
    set_daemon_data_root "$DEFAULT_DOCKER_DATA_DIR"
    start_services
    success "Converted to default layout"
}

require_root_unless_status
require_tools

if [[ "$SHOW_STATUS" == true ]]; then
    show_status
    exit 0
fi

case "$TO_LAYOUT" in
    runpod|default) ;;
    "") error "Missing required --to runpod|default"; usage ;;
    *) error "Invalid target layout: ${TO_LAYOUT}"; usage ;;
esac

current_layout=$(detect_layout)
if [[ "$current_layout" == "$TO_LAYOUT" ]]; then
    success "Already using ${TO_LAYOUT} layout"
    exit 0
fi
if [[ "$current_layout" == "unknown" || "$current_layout" == "none" ]]; then
    error "Cannot safely convert from detected layout: ${current_layout}"
    error "Run '$0 --status' and inspect the current mount/fstab state."
    exit 1
fi

case "$TO_LAYOUT" in
    runpod)
        [[ "$current_layout" == "default" ]] || { error "Expected current layout default, got ${current_layout}"; exit 1; }
        convert_default_to_runpod
        ;;
    default)
        [[ "$current_layout" == "runpod" ]] || { error "Expected current layout runpod, got ${current_layout}"; exit 1; }
        convert_runpod_to_default
        ;;
esac
