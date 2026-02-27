#!/usr/bin/env bash
# gpu-power-limit.sh
# Generates and installs a systemd service to set NVIDIA GPU power limits at boot.
#
# Usage:
#   sudo ./gpu-power-limit.sh            # auto-detect GPU type, apply preset, install
#   ./gpu-power-limit.sh --dry-run       # preview only, no changes made
#   sudo ./gpu-power-limit.sh --override 400  # force a specific wattage for all GPUs

set -euo pipefail

# ─── Presets (GPU model substring → watts) ───────────────────────────────────
declare -A GPU_PRESETS=(
    ["5090"]=450
    ["4090"]=300
    ["A100"]=300
    ["H100"]=500
    ["A4000"]=140
)
DEFAULT_FALLBACK_WATTS=300   # used if no preset matches and no --override given

# ─── Config ───────────────────────────────────────────────────────────────────
SERVICE_NAME="nvidia-runtime-policy"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
NVIDIA_SMI="/usr/bin/nvidia-smi"
DRY_RUN=false
OVERRIDE_WATTS=""

# ─── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
dryrun()  { echo -e "${YELLOW}[DRY-RUN]${NC} $*"; }

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
        --help|-h)
            echo -e "${BOLD}Usage:${NC} $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --dry-run           Preview the generated service file without making any changes"
            echo "  --override WATTS    Force a specific power limit for all GPUs (skips preset lookup)"
            echo "  --help              Show this help"
            echo ""
            echo -e "${BOLD}GPU Presets:${NC}"
            for model in "${!GPU_PRESETS[@]}"; do
                printf "  %-10s %dW\n" "$model" "${GPU_PRESETS[$model]}"
            done | sort
            echo ""
            echo -e "${BOLD}Examples:${NC}"
            echo "  sudo $0                      # detect GPU, apply preset, install service"
            echo "  $0 --dry-run                 # preview without changes"
            echo "  sudo $0 --override 350       # force 350W on all GPUs"
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
    for model in "${!GPU_PRESETS[@]}"; do
        if [[ "$GPU_NAME" == *"$model"* ]]; then
            POWER_LIMIT="${GPU_PRESETS[$model]}"
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

# ─── Validate wattage against each GPU's min/max ─────────────────────────────
VALIDATION_FAILED=false
while IFS=',' read -r idx _name min_raw max_raw; do
    min="${min_raw// /}"; min="${min%.*}"; min="${min%W}"
    max="${max_raw// /}"; max="${max%.*}"; max="${max%W}"
    if (( POWER_LIMIT < min || POWER_LIMIT > max )); then
        error "GPU ${idx}: ${POWER_LIMIT}W is outside allowed range [${min}W – ${max}W]"
        VALIDATION_FAILED=true
    else
        success "GPU ${idx}: ${POWER_LIMIT}W ✓  (allowed range: ${min}W – ${max}W)"
    fi
done < <("$NVIDIA_SMI" --query-gpu=index,name,power.min_limit,power.max_limit \
            --format=csv,noheader)

if [[ "$VALIDATION_FAILED" == true ]]; then
    error "Power limit validation failed. Aborting."
    exit 1
fi

# ─── Build service file content ───────────────────────────────────────────────
SERVICE_CONTENT="[Unit]
Description=NVIDIA runtime policy (persistence + power cap @ ${POWER_LIMIT}W)
After=multi-user.target
ConditionPathExists=/dev/nvidiactl

[Service]
Type=oneshot
ExecStart=${NVIDIA_SMI} -pm 1
ExecStart=${NVIDIA_SMI} -pl ${POWER_LIMIT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target"

# ─── Print preview ────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}── Service file: ${SERVICE_FILE} $( [[ "$DRY_RUN" == true ]] && echo "(DRY-RUN — not written)" ) ──${NC}"
echo "$SERVICE_CONTENT"
echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
echo ""

# ─── Dry-run exits here ───────────────────────────────────────────────────────
if [[ "$DRY_RUN" == true ]]; then
    dryrun "No changes made."
    dryrun "To install, re-run as root (with or without --override):"
    dryrun "  sudo $0 $( [[ -n "$OVERRIDE_WATTS" ]] && echo "--override ${OVERRIDE_WATTS}" )"
    exit 0
fi

# ─── Install ──────────────────────────────────────────────────────────────────
info "Writing ${SERVICE_FILE} ..."
echo "$SERVICE_CONTENT" | tee "$SERVICE_FILE" > /dev/null
success "Service file written."

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
