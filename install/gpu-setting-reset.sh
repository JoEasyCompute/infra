#!/usr/bin/env bash
# Reset NVIDIA GPU and memory clock locks applied through nvidia-smi.

set -euo pipefail

NVIDIA_SMI="${NVIDIA_SMI:-/usr/bin/nvidia-smi}"
DRY_RUN=false
GPU_FILTER=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS]

Resets NVIDIA application graphics and memory clock locks for all GPUs,
or for a comma-separated set of GPU indices.

Options:
  --gpu LIST     Comma-separated GPU indices to reset, e.g. 0 or 0,2,3
  --dry-run      Print the nvidia-smi commands without applying changes
  -h, --help     Show this help

Environment:
  NVIDIA_SMI     Path to nvidia-smi (default: /usr/bin/nvidia-smi)

Examples:
  sudo $0
  sudo $0 --gpu 0,1
  $0 --dry-run --gpu 2
EOF
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
    error "Clock reset requires root. Re-run with sudo, or use --dry-run."
    exit 1
fi

if ! command -v "$NVIDIA_SMI" &>/dev/null; then
    error "nvidia-smi not found at ${NVIDIA_SMI}. Is the NVIDIA driver installed?"
    exit 1
fi

mapfile -t ALL_GPUS < <("$NVIDIA_SMI" --query-gpu=index --format=csv,noheader,nounits 2>/dev/null | tr -d ' \r')
if [[ "${#ALL_GPUS[@]}" -eq 0 ]]; then
    error "No NVIDIA GPUs detected."
    exit 1
fi

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

run_cmd() {
    if [[ "$DRY_RUN" == true ]]; then
        printf '[DRY-RUN] %q' "$NVIDIA_SMI"
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi

    "$NVIDIA_SMI" "$@"
}

info "Resetting clock locks on GPU index(es): ${TARGET_GPUS[*]}"

failed=false
for idx in "${TARGET_GPUS[@]}"; do
    info "GPU ${idx}: resetting graphics clock lock"
    if run_cmd -i "$idx" -rgc; then
        success "GPU ${idx}: graphics clock lock reset"
    else
        warn "GPU ${idx}: graphics clock reset failed"
        failed=true
    fi

    info "GPU ${idx}: resetting memory clock lock"
    if run_cmd -i "$idx" -rmc; then
        success "GPU ${idx}: memory clock lock reset"
    else
        warn "GPU ${idx}: memory clock reset failed"
        failed=true
    fi
done

if [[ "$failed" == true ]]; then
    error "One or more reset commands failed."
    exit 1
fi

if [[ "$DRY_RUN" == false ]]; then
    "$NVIDIA_SMI" --query-gpu=index,name,clocks.current.graphics,clocks.current.memory,power.limit \
        --format=csv
fi

success "GPU clock settings reset."
