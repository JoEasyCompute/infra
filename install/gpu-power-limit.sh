#!/usr/bin/env bash
# gpu-power-limit.sh
# Generates and installs a systemd service to set NVIDIA GPU power limits at boot.
#
# Usage:
#   sudo ./gpu-power-limit.sh            # auto-detect GPU type, apply preset, install
#   ./gpu-power-limit.sh --dry-run       # preview only, no changes made
#   sudo ./gpu-power-limit.sh --override 400  # force a specific wattage for all GPUs
#   sudo ./gpu-power-limit.sh --gpu-limit 0:350 --gpu-limit 1:320

set -euo pipefail

# ─── Presets (GPU model substring → watts) ───────────────────────────────────
GPU_PRESET_MODELS=("5090" "4090" "A100" "H100" "A4000")
GPU_PRESET_WATTS=(450 300 300 500 140)
DEFAULT_FALLBACK_WATTS=300   # used if no preset matches and no --override given

# ─── Config ───────────────────────────────────────────────────────────────────
SERVICE_NAME="nvidia-runtime-policy"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
HELPER_FILE="/usr/local/sbin/${SERVICE_NAME}.sh"
NVIDIA_SMI="${NVIDIA_SMI:-/usr/bin/nvidia-smi}"
DRY_RUN=false
OVERRIDE_WATTS=""
PER_GPU_LIMIT_INDICES=()
PER_GPU_LIMIT_WATTS=()

# ─── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
dryrun()  { echo -e "${YELLOW}[DRY-RUN]${NC} $*"; }

per_gpu_limit_pos() {
    local search_idx="$1"
    local pos

    for pos in "${!PER_GPU_LIMIT_INDICES[@]}"; do
        if [[ "${PER_GPU_LIMIT_INDICES[$pos]}" == "$search_idx" ]]; then
            printf "%s\n" "$pos"
            return 0
        fi
    done

    return 1
}

parse_gpu_limit() {
    local spec="$1"
    local idx watts pos

    if [[ "$spec" =~ ^([0-9]+)[=:]([0-9]+)$ ]]; then
        idx="${BASH_REMATCH[1]}"
        watts="${BASH_REMATCH[2]}"
    else
        error "--gpu-limit requires INDEX:WATTS (e.g. --gpu-limit 0:350)"
        exit 1
    fi

    if pos="$(per_gpu_limit_pos "$idx")"; then
        warn "GPU ${idx} power limit specified more than once; using latest value."
        PER_GPU_LIMIT_WATTS[$pos]="$watts"
    else
        PER_GPU_LIMIT_INDICES+=("$idx")
        PER_GPU_LIMIT_WATTS+=("$watts")
    fi
}

gpu_power_limit_for_index() {
    local idx="$1"
    local pos

    if pos="$(per_gpu_limit_pos "$idx")"; then
        printf "%s\n" "${PER_GPU_LIMIT_WATTS[$pos]}"
    else
        printf "%s\n" "$POWER_LIMIT"
    fi
}

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --override)
            if [[ -z "${2:-}" || ! "${2:-}" =~ ^[0-9]+$ ]]; then
                error "--override requires a numeric wattage (e.g. --override 400)"
                exit 1
            fi
            OVERRIDE_WATTS="$2"
            shift 2
            ;;
        --gpu-limit)
            if [[ -z "${2:-}" ]]; then
                error "--gpu-limit requires INDEX:WATTS (e.g. --gpu-limit 0:350)"
                exit 1
            fi
            parse_gpu_limit "$2"
            shift 2
            ;;
        --help|-h)
            echo -e "${BOLD}Usage:${NC} $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --dry-run           Preview the generated service file without making any changes"
            echo "  --override WATTS    Force a specific power limit for all GPUs (skips preset lookup)"
            echo "  --gpu-limit I:W     Override one GPU index with a specific wattage (repeatable)"
            echo "  --help              Show this help"
            echo ""
            echo -e "${BOLD}GPU Presets:${NC}"
            for pos in "${!GPU_PRESET_MODELS[@]}"; do
                printf "  %-10s %dW\n" "${GPU_PRESET_MODELS[$pos]}" "${GPU_PRESET_WATTS[$pos]}"
            done | sort
            echo ""
            echo -e "${BOLD}Examples:${NC}"
            echo "  sudo $0                      # detect GPU, apply preset, install service"
            echo "  $0 --dry-run                 # preview without changes"
            echo "  sudo $0 --override 350       # force 350W on all GPUs"
            echo "  sudo $0 --gpu-limit 0:350 --gpu-limit 1:320"
            exit 0
            ;;
        *)
            error "Unknown argument: $1 (use --help for usage)"
            exit 1
            ;;
    esac
done

# ─── Root check (skip for dry-run) ───────────────────────────────────────────
if [[ "$DRY_RUN" == false && "$EUID" -ne 0 ]]; then
    error "Installation requires root. Re-run with sudo, or use --dry-run to preview."
    exit 1
fi

# ─── Checks ───────────────────────────────────────────────────────────────────
if ! command -v "$NVIDIA_SMI" &>/dev/null; then
    error "nvidia-smi not found at ${NVIDIA_SMI}. Is the NVIDIA driver installed?"
    exit 1
fi

GPU_COUNT=$("$NVIDIA_SMI" --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
if [[ "$GPU_COUNT" -eq 0 ]]; then
    error "No NVIDIA GPUs detected."
    exit 1
fi

for idx in "${PER_GPU_LIMIT_INDICES[@]}"; do
    if (( idx >= GPU_COUNT )); then
        error "--gpu-limit references GPU ${idx}, but detected GPU indices are 0-$((GPU_COUNT - 1))."
        exit 1
    fi
done

# ─── Detect GPU model and resolve power limit ─────────────────────────────────
# Read the first GPU's name for preset matching (assumes homogeneous nodes)
GPU_NAME=$("$NVIDIA_SMI" -i 0 --query-gpu=name --format=csv,noheader | xargs)

echo ""
info "Detected ${GPU_COUNT} GPU(s): ${GPU_NAME}"
"$NVIDIA_SMI" --query-gpu=index,name,power.limit,power.min_limit,power.max_limit \
    --format=csv,noheader | column -t -s',' | sed 's/^/        /'
echo ""

if [[ -n "$OVERRIDE_WATTS" ]]; then
    POWER_LIMIT="$OVERRIDE_WATTS"
    info "Power limit source: ${BOLD}--override${NC} → ${BOLD}${POWER_LIMIT}W${NC}"
else
    # Walk presets, pick first match
    POWER_LIMIT=""
    MATCHED_MODEL=""
    for pos in "${!GPU_PRESET_MODELS[@]}"; do
        model="${GPU_PRESET_MODELS[$pos]}"
        if [[ "$GPU_NAME" == *"$model"* ]]; then
            POWER_LIMIT="${GPU_PRESET_WATTS[$pos]}"
            MATCHED_MODEL="$model"
            break
        fi
    done

    if [[ -n "$POWER_LIMIT" ]]; then
        info "Power limit source: ${BOLD}preset (${MATCHED_MODEL})${NC} → ${BOLD}${POWER_LIMIT}W${NC}"
    else
        POWER_LIMIT="$DEFAULT_FALLBACK_WATTS"
        warn "No preset matched '${GPU_NAME}' — falling back to default: ${POWER_LIMIT}W"
        warn "Use --override WATTS to set an explicit limit, or add a preset to the script."
    fi
fi

if [[ "${#PER_GPU_LIMIT_INDICES[@]}" -gt 0 ]]; then
    info "Per-GPU power limit overrides:"
    for pos in "${!PER_GPU_LIMIT_INDICES[@]}"; do
        idx="${PER_GPU_LIMIT_INDICES[$pos]}"
        info "  GPU ${idx} → ${BOLD}${PER_GPU_LIMIT_WATTS[$pos]}W${NC}"
    done
fi

# ─── Validate wattage against each GPU's min/max ─────────────────────────────
VALIDATION_FAILED=false
while IFS=',' read -r idx _name min_raw max_raw; do
    idx="${idx// /}"
    min="${min_raw// /}"; min="${min%.*}"; min="${min%W}"
    max="${max_raw// /}"; max="${max%.*}"; max="${max%W}"
    limit="$(gpu_power_limit_for_index "$idx")"
    if (( limit < min || limit > max )); then
        error "GPU ${idx}: ${limit}W is outside allowed range [${min}W – ${max}W]"
        VALIDATION_FAILED=true
    else
        success "GPU ${idx}: ${limit}W ✓  (allowed range: ${min}W – ${max}W)"
    fi
done < <("$NVIDIA_SMI" --query-gpu=index,name,power.min_limit,power.max_limit \
            --format=csv,noheader)

if [[ "$VALIDATION_FAILED" == true ]]; then
    error "Power limit validation failed. Aborting."
    exit 1
fi

# ─── Build service file content ───────────────────────────────────────────────
PER_GPU_HELPER_BLOCK=""
for pos in "${!PER_GPU_LIMIT_INDICES[@]}"; do
    idx="${PER_GPU_LIMIT_INDICES[$pos]}"
    PER_GPU_HELPER_BLOCK+="        ${idx}) limit=\"${PER_GPU_LIMIT_WATTS[$pos]}\" ;;"$'\n'
done

if [[ "${#PER_GPU_LIMIT_INDICES[@]}" -gt 0 ]]; then
    APPLY_POWER_LIMITS_BLOCK='while IFS= read -r gpu_idx; do
    case "$gpu_idx" in
'"${PER_GPU_HELPER_BLOCK}"'        *) limit="$POWER_LIMIT" ;;
    esac
    "$NVIDIA_SMI" -i "$gpu_idx" -pl "$limit"
done < <("$NVIDIA_SMI" --query-gpu=index --format=csv,noheader,nounits | tr -d " \r")
'
    SERVICE_DESCRIPTION="NVIDIA runtime policy (persistence + mixed GPU power caps; base ${POWER_LIMIT}W)"
else
    APPLY_POWER_LIMITS_BLOCK='"$NVIDIA_SMI" -pl "$POWER_LIMIT"
'
    SERVICE_DESCRIPTION="NVIDIA runtime policy (persistence + power cap @ ${POWER_LIMIT}W)"
fi

HELPER_CONTENT="#!/usr/bin/env bash
set -euo pipefail

NVIDIA_SMI=\"${NVIDIA_SMI}\"
POWER_LIMIT=\"${POWER_LIMIT}\"
WAIT_SECONDS=300
POLL_INTERVAL=2

for ((elapsed=0; elapsed<WAIT_SECONDS; elapsed+=POLL_INTERVAL)); do
    if [[ -e /dev/nvidiactl ]] && \"\$NVIDIA_SMI\" -L >/dev/null 2>&1; then
        break
    fi
    sleep \"\$POLL_INTERVAL\"
done

if ! [[ -e /dev/nvidiactl ]] || ! \"\$NVIDIA_SMI\" -L >/dev/null 2>&1; then
    echo \"[ERROR] NVIDIA devices were not ready within \${WAIT_SECONDS}s; power limit not applied.\" >&2
    exit 1
fi

\"\$NVIDIA_SMI\" -pm 1
${APPLY_POWER_LIMITS_BLOCK}
"

SERVICE_CONTENT="[Unit]
Description=${SERVICE_DESCRIPTION}
After=multi-user.target systemd-udev-settle.service
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
ExecStart=${HELPER_FILE}
TimeoutStartSec=360
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target"

# ─── Print preview ────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}── Service file: ${SERVICE_FILE} $( [[ "$DRY_RUN" == true ]] && echo "(DRY-RUN — not written)" ) ──${NC}"
echo "$SERVICE_CONTENT"
echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
echo ""
echo -e "${CYAN}${BOLD}── Helper file: ${HELPER_FILE} $( [[ "$DRY_RUN" == true ]] && echo "(DRY-RUN — not written)" ) ──${NC}"
echo "$HELPER_CONTENT"
echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
echo ""

# ─── Dry-run exits here ───────────────────────────────────────────────────────
if [[ "$DRY_RUN" == true ]]; then
    INSTALL_ARGS=()
    [[ -n "$OVERRIDE_WATTS" ]] && INSTALL_ARGS+=(--override "$OVERRIDE_WATTS")
    for pos in "${!PER_GPU_LIMIT_INDICES[@]}"; do
        INSTALL_ARGS+=(--gpu-limit "${PER_GPU_LIMIT_INDICES[$pos]}:${PER_GPU_LIMIT_WATTS[$pos]}")
    done

    dryrun "No changes made."
    dryrun "To install, re-run as root:"
    dryrun "  sudo $0 ${INSTALL_ARGS[*]}"
    exit 0
fi

# ─── Install ──────────────────────────────────────────────────────────────────
info "Writing ${SERVICE_FILE} ..."
echo "$SERVICE_CONTENT" | tee "$SERVICE_FILE" > /dev/null
success "Service file written."

info "Writing ${HELPER_FILE} ..."
echo "$HELPER_CONTENT" | tee "$HELPER_FILE" > /dev/null
chmod 0755 "$HELPER_FILE"
success "Helper script written."

info "Running: systemctl daemon-reload"
systemctl daemon-reload
success "Daemon reloaded."

info "Running: systemctl enable ${SERVICE_NAME}.service"
systemctl enable "${SERVICE_NAME}.service"
success "Service enabled (will start on boot)."

info "Running: systemctl restart ${SERVICE_NAME}.service"
systemctl restart "${SERVICE_NAME}.service"
success "Service started."

echo ""
info "Current power limits after applying service:"
"$NVIDIA_SMI" --query-gpu=index,name,power.limit --format=csv,noheader | \
    sed 's/^/        /'
echo ""
success "Done. '${SERVICE_NAME}.service' is active and enabled."
