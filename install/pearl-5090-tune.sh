#!/usr/bin/env bash
# Apply the Pearl RTX 5090 runtime tuning profile.

set -euo pipefail

NVIDIA_SMI="${NVIDIA_SMI:-/usr/bin/nvidia-smi}"
POWER_LIMIT_W=400
GPU_CLOCK_MHZ=2490
MEMORY_CLOCK_MHZ=7000
DRY_RUN=false
FORCE=false
GPU_FILTER=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS]

Applies the Pearl RTX 5090 runtime tuning profile:
  - persistence mode enabled
  - power limit: ${POWER_LIMIT_W}W
  - graphics clock lock: ${GPU_CLOCK_MHZ}MHz
  - memory clock lock: ${MEMORY_CLOCK_MHZ}MHz

Options:
  --gpu LIST           Comma-separated GPU indices to tune, e.g. 0 or 0,2,3
  --power-limit WATTS  Override the default ${POWER_LIMIT_W}W power limit
  --gpu-clock MHZ      Override the default ${GPU_CLOCK_MHZ}MHz graphics clock lock
  --memory-clock MHZ   Override the default ${MEMORY_CLOCK_MHZ}MHz memory clock lock
  --force              Apply even when selected GPUs are not reported as RTX 5090
  --dry-run            Print the nvidia-smi commands without applying changes
  -h, --help           Show this help

Environment:
  NVIDIA_SMI           Path to nvidia-smi (default: /usr/bin/nvidia-smi)

Examples:
  sudo $0
  sudo $0 --gpu 0,1
  sudo $0 --power-limit 380
  $0 --dry-run --gpu 2
EOF
}

require_numeric_arg() {
    local flag="$1" value="$2"
    if [[ -z "$value" || ! "$value" =~ ^[0-9]+$ ]]; then
        error "${flag} requires a numeric value"
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gpu)
            if [[ -z "${2:-}" || ! "${2:-}" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
                error "--gpu requires comma-separated numeric indices, e.g. --gpu 0,2"
                exit 1
            fi
            GPU_FILTER="$2"
            shift 2
            ;;
        --power-limit)
            require_numeric_arg "$1" "${2:-}"
            POWER_LIMIT_W="$2"
            shift 2
            ;;
        --gpu-clock)
            require_numeric_arg "$1" "${2:-}"
            GPU_CLOCK_MHZ="$2"
            shift 2
            ;;
        --memory-clock)
            require_numeric_arg "$1" "${2:-}"
            MEMORY_CLOCK_MHZ="$2"
            shift 2
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
            exit 0
            ;;
        *)
            error "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ "$DRY_RUN" == false && "$EUID" -ne 0 ]]; then
    error "GPU tuning requires root. Re-run with sudo, or use --dry-run."
    exit 1
fi

if ! command -v "$NVIDIA_SMI" &>/dev/null; then
    error "nvidia-smi not found at ${NVIDIA_SMI}. Is the NVIDIA driver installed?"
    exit 1
fi

mapfile -t GPU_ROWS < <("$NVIDIA_SMI" --query-gpu=index,name,power.min_limit,power.max_limit \
    --format=csv,noheader,nounits 2>/dev/null | tr -d '\r')
if [[ "${#GPU_ROWS[@]}" -eq 0 ]]; then
    error "No NVIDIA GPUs detected."
    exit 1
fi

declare -A GPU_NAMES=()
declare -A GPU_MIN_POWER=()
declare -A GPU_MAX_POWER=()
ALL_GPUS=()

for row in "${GPU_ROWS[@]}"; do
    IFS=',' read -r idx name min_power max_power <<< "$row"
    idx="${idx// /}"
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    min_power="${min_power// /}"
    max_power="${max_power// /}"
    min_power="${min_power%.*}"
    max_power="${max_power%.*}"
    if ! [[ "$min_power" =~ ^[0-9]+$ && "$max_power" =~ ^[0-9]+$ ]]; then
        error "GPU ${idx}: could not read numeric power range from nvidia-smi."
        exit 1
    fi

    ALL_GPUS+=("$idx")
    GPU_NAMES["$idx"]="$name"
    GPU_MIN_POWER["$idx"]="$min_power"
    GPU_MAX_POWER["$idx"]="$max_power"
done

declare -A GPU_EXISTS=()
for idx in "${ALL_GPUS[@]}"; do
    GPU_EXISTS["$idx"]=1
done

TARGET_GPUS=()
if [[ -n "$GPU_FILTER" ]]; then
    IFS=',' read -r -a TARGET_GPUS <<< "$GPU_FILTER"
    for idx in "${TARGET_GPUS[@]}"; do
        if [[ -z "${GPU_EXISTS[$idx]:-}" ]]; then
            error "--gpu references GPU ${idx}, but detected GPU indices are: ${ALL_GPUS[*]}"
            exit 1
        fi
    done
else
    TARGET_GPUS=("${ALL_GPUS[@]}")
fi

for idx in "${TARGET_GPUS[@]}"; do
    if [[ "${GPU_NAMES[$idx]}" != *"5090"* && "$FORCE" == false ]]; then
        error "GPU ${idx} is '${GPU_NAMES[$idx]}', not RTX 5090. Use --force to override."
        exit 1
    fi

    if (( POWER_LIMIT_W < ${GPU_MIN_POWER[$idx]} || POWER_LIMIT_W > ${GPU_MAX_POWER[$idx]} )); then
        error "GPU ${idx}: ${POWER_LIMIT_W}W is outside allowed range ${GPU_MIN_POWER[$idx]}W-${GPU_MAX_POWER[$idx]}W."
        exit 1
    fi
done

run_cmd() {
    if [[ "$DRY_RUN" == true ]]; then
        printf '[DRY-RUN] %q' "$NVIDIA_SMI"
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi

    "$NVIDIA_SMI" "$@"
}

run_required() {
    local label="$1"
    shift

    info "$label"
    run_cmd "$@"
}

run_optional() {
    local label="$1"
    shift

    info "$label"
    if run_cmd "$@"; then
        success "$label"
    else
        warn "${label} failed; this driver/GPU may not support that lock."
        return 1
    fi
}

info "Applying Pearl RTX 5090 profile to GPU index(es): ${TARGET_GPUS[*]}"
info "Profile: power=${POWER_LIMIT_W}W, graphics=${GPU_CLOCK_MHZ}MHz, memory=${MEMORY_CLOCK_MHZ}MHz"

run_required "Enabling persistence mode" -pm 1

optional_failed=false
for idx in "${TARGET_GPUS[@]}"; do
    info "Configuring GPU ${idx}: ${GPU_NAMES[$idx]}"
    run_required "GPU ${idx}: setting power limit to ${POWER_LIMIT_W}W" -i "$idx" -pl "$POWER_LIMIT_W"

    if ! run_optional "GPU ${idx}: locking graphics clock to ${GPU_CLOCK_MHZ}MHz" \
        -i "$idx" -lgc "${GPU_CLOCK_MHZ},${GPU_CLOCK_MHZ}"; then
        optional_failed=true
    fi

    if ! run_optional "GPU ${idx}: locking memory clock to ${MEMORY_CLOCK_MHZ}MHz" \
        -i "$idx" -lmc "${MEMORY_CLOCK_MHZ},${MEMORY_CLOCK_MHZ}"; then
        optional_failed=true
    fi
done

if [[ "$DRY_RUN" == false ]]; then
    "$NVIDIA_SMI" --query-gpu=index,name,power.limit,clocks.current.graphics,clocks.current.memory \
        --format=csv
fi

if [[ "$optional_failed" == true ]]; then
    warn "Pearl profile applied with one or more unsupported clock-lock operations."
else
    success "Pearl RTX 5090 profile applied."
fi
