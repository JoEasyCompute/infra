#!/usr/bin/env bash
# manage-gpu.sh
# Installs or updates an initramfs hook that binds selected NVIDIA GPU PCI slots
# to vfio-pci early in boot. Each selected GPU is handled as a pair: .0 and .1.
#
# Usage:
#   sudo ./manage-gpu.sh                # interactive toggle menu
#   sudo ./manage-gpu.sh --disable 25:00
#   sudo ./manage-gpu.sh --enable 25:00
#   ./manage-gpu.sh --list
#   ./manage-gpu.sh --dry-run --disable 25:00

set -euo pipefail

HOOK_FILE="/etc/initramfs-tools/scripts/init-top/vfio-bind-gpus"
DRY_RUN=false
LIST_ONLY=false
ACTION=""
SELECTED_SLOTS=()

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Install or update an initramfs hook that binds selected NVIDIA GPUs to vfio-pci.
Selections are PCI slots, and each slot is applied as a pair: function .0 and .1.

Options:
  --disable SLOT[,SLOT...]  Add GPU slot(s) to the vfio-pci boot hook
  --enable SLOT[,SLOT...]   Remove GPU slot(s) from the vfio-pci boot hook
  --list                    Show detected NVIDIA GPUs and currently disabled slots
  --dry-run                 Preview changes without writing files or updating initramfs
  -h, --help                Show this help

Slot examples:
  25:00
  25:00.0
  0000:25:00.0

Examples:
  sudo $0
  sudo $0 --disable 25:00
  sudo $0 --enable 25:00,26:00
  $0 --dry-run --disable 0000:25:00.0
EOF
}

split_slots() {
    local raw="$1"
    local item
    IFS=',' read -ra parts <<< "$raw"
    for item in "${parts[@]}"; do
        [[ -n "$item" ]] && SELECTED_SLOTS+=("$item")
    done
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --disable)
            ACTION="disable"
            [[ -n "${2:-}" ]] || { error "--disable requires a PCI slot"; exit 1; }
            split_slots "$2"
            shift 2
            ;;
        --enable)
            ACTION="enable"
            [[ -n "${2:-}" ]] || { error "--enable requires a PCI slot"; exit 1; }
            split_slots "$2"
            shift 2
            ;;
        --list)
            LIST_ONLY=true
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
            error "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ "$ACTION" == "" && "${#SELECTED_SLOTS[@]}" -gt 0 ]]; then
    error "Internal argument error: slots were supplied without an action"
    exit 1
fi

if [[ "$LIST_ONLY" == false && "$DRY_RUN" == false && "$EUID" -ne 0 ]]; then
    error "Installation requires root. Re-run with sudo, or use --dry-run/--list."
    exit 1
fi

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "Required command not found: $1"
        exit 1
    fi
}

normalize_slot() {
    local raw="$1"
    raw="${raw#0000:}"
    raw="${raw%.*}"

    if [[ ! "$raw" =~ ^[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}$ ]]; then
        error "Invalid PCI slot '${1}'. Expected forms like 25:00, 25:00.0, or 0000:25:00.0."
        exit 1
    fi

    printf '0000:%s\n' "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
}

device_pair_for_slot() {
    local slot="$1"
    printf '%s.0 %s.1\n' "$slot" "$slot"
}

read_existing_slots() {
    [[ -f "$HOOK_FILE" ]] || return 0
    sed -n 's/^# VFIO_GPU_SLOTS="\([^"]*\)"/\1/p' "$HOOK_FILE" | tr ' ' '\n' | sed '/^$/d'
}

slot_is_selected() {
    local needle="$1"
    shift
    local slot
    for slot in "$@"; do
        [[ "$slot" == "$needle" ]] && return 0
    done
    return 1
}

detected_gpu_slots() {
    command -v lspci >/dev/null 2>&1 || return 0
    lspci -Dnn | awk '
        {
            line = tolower($0)
        }
        line ~ /nvidia/ && line ~ /(vga compatible controller|3d controller|display controller)/ {
            split($1, parts, ".")
            print parts[1]
        }
    ' | sort -u
}

describe_slot() {
    local slot="$1"
    local line
    if ! command -v lspci >/dev/null 2>&1; then
        printf '%s.0 (lspci not found)\n' "$slot"
        return 0
    fi
    line="$(lspci -Dnn -s "${slot}.0" 2>/dev/null || true)"
    [[ -n "$line" ]] || line="${slot}.0 (not currently visible to lspci)"
    printf '%s\n' "$line"
}

write_hook() {
    local slots=("$@")
    local devices=()
    local slot pair dev

    if [[ "${#slots[@]}" -eq 0 ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            info "Would remove ${HOOK_FILE} because no GPU slots remain selected."
        elif [[ -f "$HOOK_FILE" ]]; then
            rm -f "$HOOK_FILE"
            success "Removed ${HOOK_FILE}; no GPU slots remain selected."
        else
            info "No existing hook to remove."
        fi
        return 0
    fi

    for slot in "${slots[@]+"${slots[@]}"}"; do
        read -r -a pair <<< "$(device_pair_for_slot "$slot")"
        for dev in "${pair[@]+"${pair[@]}"}"; do
            devices+=("$dev")
        done
    done

    local slots_line devices_line
    slots_line="${slots[*]}"
    devices_line="${devices[*]}"

    if [[ "$DRY_RUN" == true ]]; then
        info "Would write ${HOOK_FILE} with slots: ${slots_line}"
        cat <<EOF
#!/bin/sh
# Generated by manage-gpu.sh. Re-run that script to change selections.
# VFIO_GPU_SLOTS="${slots_line}"
PREREQ=""
prereqs() { echo "\$PREREQ"; }
case "\$1" in
  prereqs) prereqs; exit 0;;
esac
set -eu
modprobe vfio-pci || true
for dev in ${devices_line}; do
  [ -e "/sys/bus/pci/devices/\$dev" ] || continue
  echo vfio-pci > "/sys/bus/pci/devices/\$dev/driver_override"
  if [ -L "/sys/bus/pci/devices/\$dev/driver" ]; then
    cur="\$(readlink -f /sys/bus/pci/devices/\$dev/driver)"
    drv="\$(basename "\$cur")"
    echo "\$dev" > "/sys/bus/pci/drivers/\$drv/unbind" || true
  fi
  echo "\$dev" > /sys/bus/pci/drivers/vfio-pci/bind || true
done
exit 0
EOF
        return 0
    fi

    install -d -m 0755 "$(dirname "$HOOK_FILE")"
    tee "$HOOK_FILE" >/dev/null <<EOF
#!/bin/sh
# Generated by manage-gpu.sh. Re-run that script to change selections.
# VFIO_GPU_SLOTS="${slots_line}"
PREREQ=""
prereqs() { echo "\$PREREQ"; }
case "\$1" in
  prereqs) prereqs; exit 0;;
esac
set -eu
modprobe vfio-pci || true
for dev in ${devices_line}; do
  [ -e "/sys/bus/pci/devices/\$dev" ] || continue
  echo vfio-pci > "/sys/bus/pci/devices/\$dev/driver_override"
  if [ -L "/sys/bus/pci/devices/\$dev/driver" ]; then
    cur="\$(readlink -f /sys/bus/pci/devices/\$dev/driver)"
    drv="\$(basename "\$cur")"
    echo "\$dev" > "/sys/bus/pci/drivers/\$drv/unbind" || true
  fi
  echo "\$dev" > /sys/bus/pci/drivers/vfio-pci/bind || true
done
exit 0
EOF
    chmod +x "$HOOK_FILE"
    success "Wrote ${HOOK_FILE} with slots: ${slots_line}"
}

update_initramfs() {
    if [[ "$DRY_RUN" == true ]]; then
        info "Would run: update-initramfs -u"
        return 0
    fi
    require_command update-initramfs
    info "Running: update-initramfs -u"
    update-initramfs -u
    success "Initramfs updated. Reboot for the binding change to take effect."
}

print_status() {
    local current=("$@")
    local slot mark

    echo ""
    echo -e "${BOLD}Detected NVIDIA GPU slots${RESET}"
    detected=()
    while IFS= read -r slot; do
        [[ -n "$slot" ]] && detected+=("$slot")
    done < <(detected_gpu_slots)
    if [[ "${#detected[@]}" -eq 0 ]]; then
        warn "No NVIDIA display/3D controller slots found with lspci."
    else
        for slot in "${detected[@]}"; do
            mark=" "
            slot_is_selected "$slot" "${current[@]+"${current[@]}"}" && mark="x"
            printf '  [%s] %s\n' "$mark" "$(describe_slot "$slot")"
        done
    fi

    echo ""
    echo -e "${BOLD}Currently selected for vfio-pci at boot${RESET}"
    if [[ "${#current[@]}" -eq 0 ]]; then
        echo "  none"
    else
        for slot in "${current[@]+"${current[@]}"}"; do
            printf '  %s -> %s\n' "$slot" "$(device_pair_for_slot "$slot")"
        done
    fi
    echo ""
}

interactive_select() {
    local current=("$@")
    local detected=()
    local choices answer idx slot current_label result_label

    detected=()
    while IFS= read -r slot; do
        [[ -n "$slot" ]] && detected+=("$slot")
    done < <(detected_gpu_slots)
    if [[ "${#detected[@]}" -eq 0 ]]; then
        error "No NVIDIA display/3D controller slots found with lspci."
        exit 1
    fi

    echo -e "${BOLD}Select NVIDIA GPU slot(s) to toggle:${RESET}"
    for idx in "${!detected[@]}"; do
        slot="${detected[$idx]}"
        current_label="enabled now"
        result_label="select -> disable"
        if slot_is_selected "$slot" "${current[@]+"${current[@]}"}"; then
            current_label="disabled now"
            result_label="select -> enable"
        fi
        printf '  %2d) %-11s [%s; %s] %s\n' "$((idx + 1))" "$slot" "$current_label" "$result_label" "$(describe_slot "$slot")"
    done
    echo ""
    read -rp "Enter number(s), comma-separated, or q to quit: " answer
    [[ "$answer" != "q" && "$answer" != "Q" ]] || exit 0

    IFS=',' read -ra choices <<< "$answer"
    SELECTED_SLOTS=()
    for idx in "${choices[@]}"; do
        idx="${idx//[[:space:]]/}"
        if [[ ! "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#detected[@]} )); then
            error "Invalid selection: ${idx}"
            exit 1
        fi
        SELECTED_SLOTS+=("${detected[$((idx - 1))]}")
    done
}

CURRENT_SLOTS=()
while IFS= read -r slot; do
    [[ -n "$slot" ]] && CURRENT_SLOTS+=("$slot")
done < <(read_existing_slots)

NEXT_SLOTS=()
for slot in "${CURRENT_SLOTS[@]+"${CURRENT_SLOTS[@]}"}"; do
    normalized="$(normalize_slot "$slot")"
    if ! slot_is_selected "$normalized" "${NEXT_SLOTS[@]+"${NEXT_SLOTS[@]}"}"; then
        NEXT_SLOTS+=("$normalized")
    fi
done

if [[ "$LIST_ONLY" == true ]]; then
    print_status "${NEXT_SLOTS[@]+"${NEXT_SLOTS[@]}"}"
    exit 0
fi

if [[ "$ACTION" == "" ]]; then
    print_status "${NEXT_SLOTS[@]+"${NEXT_SLOTS[@]}"}"
    interactive_select "${NEXT_SLOTS[@]+"${NEXT_SLOTS[@]}"}"
fi

if [[ "${#SELECTED_SLOTS[@]}" -eq 0 ]]; then
    error "No GPU slots selected."
    exit 1
fi

NORMALIZED_SELECTED=()
for slot in "${SELECTED_SLOTS[@]}"; do
    NORMALIZED_SELECTED+=("$(normalize_slot "$slot")")
done

if [[ "$ACTION" == "disable" ]]; then
    for slot in "${NORMALIZED_SELECTED[@]}"; do
        if ! slot_is_selected "$slot" "${NEXT_SLOTS[@]+"${NEXT_SLOTS[@]}"}"; then
            NEXT_SLOTS+=("$slot")
        fi
    done
elif [[ "$ACTION" == "enable" ]]; then
    FILTERED=()
    for slot in "${NEXT_SLOTS[@]+"${NEXT_SLOTS[@]}"}"; do
        slot_is_selected "$slot" "${NORMALIZED_SELECTED[@]}" || FILTERED+=("$slot")
    done
    NEXT_SLOTS=("${FILTERED[@]+"${FILTERED[@]}"}")
else
    for slot in "${NORMALIZED_SELECTED[@]}"; do
        if slot_is_selected "$slot" "${NEXT_SLOTS[@]+"${NEXT_SLOTS[@]}"}"; then
            FILTERED=()
            for existing in "${NEXT_SLOTS[@]+"${NEXT_SLOTS[@]}"}"; do
                [[ "$existing" != "$slot" ]] && FILTERED+=("$existing")
            done
            NEXT_SLOTS=("${FILTERED[@]+"${FILTERED[@]}"}")
        else
            NEXT_SLOTS+=("$slot")
        fi
    done
fi

if [[ "${#NEXT_SLOTS[@]}" -gt 0 ]]; then
    SORTED_SLOTS=()
    while IFS= read -r slot; do
        [[ -n "$slot" ]] && SORTED_SLOTS+=("$slot")
    done < <(printf '%s\n' "${NEXT_SLOTS[@]}" | sort -u)
    NEXT_SLOTS=("${SORTED_SLOTS[@]+"${SORTED_SLOTS[@]}"}")
fi

write_hook "${NEXT_SLOTS[@]+"${NEXT_SLOTS[@]}"}"
update_initramfs
print_status "${NEXT_SLOTS[@]+"${NEXT_SLOTS[@]}"}"
