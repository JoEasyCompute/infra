#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEFAULT_PROFILE="ornith-35b-practical"
PUBLISHED_PROFILE="ornith-397b-published"
MXFP4_PROFILE="ornith-397b-mxfp4-128k"

DEFAULT_MODEL="deepreinforce-ai/Ornith-1.0-35B"
DEFAULT_MODEL_REVISION="5df2ed3f675c7beaa490328cc70bb573b65fb660"
DEFAULT_MAX_MODEL_LEN=16384
DEFAULT_TOOL_CALL_PARSER="qwen3_xml"
DEFAULT_REASONING_PARSER="qwen3"
DEFAULT_NVIDIA_VLLM_IMAGE="vllm/vllm-openai:v0.25.1-cu129"
DEFAULT_AMD_VLLM_IMAGE="rocm/vllm:rocm7.13.0_gfx120X-all_ubuntu24.04_py3.13_pytorch_2.10.0_vllm_0.19.1"
DEFAULT_DATASET="terminal-bench@2.0"
DEFAULT_AGENT="terminus-2"
DEFAULT_HARBOR_PARSER="json"
DEFAULT_TEMPERATURE="1.0"
DEFAULT_TOP_P="1.0"
DEFAULT_HARBOR_VERSION="0.20.0"

PUBLISHED_MODEL="deepreinforce-ai/Ornith-1.0-397B"
PUBLISHED_MODEL_REVISION="5e3e761811e804c295c1d3c0ce68b21da6154209"
PUBLISHED_DATASET="terminal-bench/terminal-bench-2-1@6"
PUBLISHED_MAX_MODEL_LEN=131072
PUBLISHED_TASK_CPUS=32
PUBLISHED_TASK_MEMORY_MB=49152

MXFP4_MODEL="olka-fi/Ornith-1.0-397B-MXFP4"
MXFP4_MODEL_REVISION="04940815e4ddf15e2b7cc4710e81e3cecc25540b"
MXFP4_DCP_SIZE=4
MXFP4_KV_CACHE_DTYPE="fp8"
MXFP4_MAX_NUM_SEQS=1
MXFP4_MIN_FREE_GB=300
MXFP4_MIN_AGGREGATE_VRAM_MIB=256000

PROFILE="$DEFAULT_PROFILE"
PROFILE_MODIFIED=false
BACKEND="auto"
MODEL_NAME=""
MODEL_REVISION=""
VLLM_IMAGE=""
GPU_SELECTION="all"
TP_SIZE=""
PORT=8000
MAX_MODEL_LEN=""
GPU_MEMORY_UTILIZATION=""
DECODE_CONTEXT_PARALLEL_SIZE=""
KV_CACHE_DTYPE=""
CALCULATE_KV_SCALES=false
MAX_NUM_SEQS=""
CPU_OFFLOAD_GB=""
ENFORCE_EAGER=false
LANGUAGE_MODEL_ONLY=false
TOOL_CALL_PARSER=""
REASONING_PARSER=""
BENCHMARK_DATASET=""
HARBOR_AGENT=""
HARBOR_PARSER=""
TEMPERATURE=""
TOP_P=""
TASK_CPUS=""
TASK_MEMORY_MB=""
N_CONCURRENT=""
STARTUP_TIMEOUT=1800
MIN_FREE_GB=""
OUTPUT_DIR=""
SMOKE_ONLY=false
DRY_RUN=false
PULL_IMAGE=true
KEEP_SERVER=false
MODEL_WAS_SET=false
REVISION_WAS_SET=false
IMAGE_WAS_SET=false
EAGER_WAS_SET=false
HARBOR_ARGS=()
HARBOR_ARGS_PRESENT=false
HARBOR_COMMAND_DISPLAY=""
HARBOR_ARGS_DISPLAY=""
VLLM_COMMAND_DISPLAY=""

RUN_DIR=""
CONTAINER_NAME=""
SERVER_LOG=""
CONSOLE_LOG=""
HARBOR_LOG=""
MODELS_JSON=""
SMOKE_REQUEST=""
SMOKE_RESPONSE=""
METADATA_FILE=""
SUMMARY_FILE=""
SELECTED_GPUS=""
SELECTED_GPU_COUNT=0
DOCKER_GPU_SPEC=""
SERVED_MODEL_NAME=""
IMAGE_DIGEST=""
DOCKER_VERSION=""
GPU_RUNTIME_VERSION=""
GPU_ARCHITECTURES=""
GPU_INVENTORY=""
AMD_DEVICE_ROOT="${VLLM_BENCHMARK_DEVICE_ROOT:-/dev}"
LOG_FOLLOW_PID=""
STARTED_SERVER=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [-- HARBOR_ARGS...]

Run a vLLM OpenAI-compatible server in Docker and evaluate it with Harbor.
Run the NVIDIA backend after base-install.sh and docker-install.sh. Run the AMD
backend after amd-base-install.sh and docker-install.sh with
--skip-nvidia-toolkit --skip-nouveau-blacklist.

Options:
  --profile NAME               Benchmark profile: $DEFAULT_PROFILE or
                               $PUBLISHED_PROFILE or $MXFP4_PROFILE
                               (default: $DEFAULT_PROFILE)
  --backend NAME               GPU backend: auto, nvidia, or amd (default: auto)
  --model NAME                 Hugging Face model (default: $DEFAULT_MODEL)
  --model-revision REVISION    Immutable model revision (default: pinned Ornith revision)
  --vllm-image IMAGE           Pinned backend-compatible vLLM image
                               NVIDIA default: $DEFAULT_NVIDIA_VLLM_IMAGE
                               AMD default: $DEFAULT_AMD_VLLM_IMAGE
  --gpus LIST                  Comma-separated GPU indices, or all (default: all)
  --tp-size COUNT              Tensor-parallel workers
                               (default: profile setting or selected GPU count)
  --port PORT                  Local API port (default: 8000)
  --max-model-len TOKENS       Maximum model context (profile default)
  --gpu-memory-utilization N   vLLM GPU memory fraction (profile default)
  --decode-context-parallel-size COUNT
                               vLLM decode context parallel workers (profile default)
  --kv-cache-dtype TYPE        vLLM KV cache dtype (profile default)
  --calculate-kv-scales        Calculate FP8 KV cache scales dynamically
  --no-calculate-kv-scales     Do not calculate KV cache scales
  --max-num-seqs COUNT         Maximum concurrent vLLM sequences
  --cpu-offload-gb GB          CPU weight offload per GPU (profile default: 0)
  --enforce-eager              Disable CUDA graph execution
  --no-enforce-eager           Allow backend-default CUDA graph execution
  --language-model-only        Disable unused multimodal processing
  --no-language-model-only     Allow normal multimodal processing
  --tool-call-parser NAME      vLLM tool parser; none disables (default: qwen3_xml)
  --reasoning-parser NAME      vLLM reasoning parser; none disables (default: qwen3)
  --dataset NAME               Harbor dataset (default: $DEFAULT_DATASET)
  --agent NAME                 Harbor agent (default: $DEFAULT_AGENT)
  --harbor-parser NAME         Harbor response parser (profile default: json)
  --temperature NUMBER         Harbor agent temperature (profile default: 1.0)
  --top-p NUMBER               Harbor agent top-p (profile default: 1.0)
  --task-cpus COUNT            Override CPUs available to each Harbor task
  --task-memory-mb MB          Override memory available to each Harbor task
  --n-concurrent COUNT         Concurrent Harbor tasks (profile default)
  --startup-timeout SECONDS    Maximum model startup wait (default: 1800)
  --min-free-gb GB             Required Docker-root free space; 0 disables
                               (profile default)
  --output-dir PATH            Run artifact directory (default: test/logs/vllm-benchmark/TIMESTAMP)
  --smoke                      Stop after the API chat-completion smoke test
  --dry-run                    Print commands without checking the host or creating files
  --no-pull                    Use the locally cached vLLM image
  --keep-server                Leave the named vLLM container running on exit
  -h, --help                   Show this help

Environment:
  HF_TOKEN                     Optional Hugging Face token for gated model downloads.
                               The value is passed by variable name and never logged.

Examples:
  $(basename "$0") --gpus 0,1,2,3 --tp-size 4
  $(basename "$0") --profile $PUBLISHED_PROFILE --gpus 0,1,2,3,4,5,6,7 --tp-size 8
  $(basename "$0") --profile $MXFP4_PROFILE --backend nvidia --gpus 0,1,2,3,4,5,6,7 --tp-size 8
  $(basename "$0") --backend amd --gpus 0,1,2,3 --tp-size 4
  $(basename "$0") --smoke --gpus 0 --tp-size 1
  $(basename "$0") --dry-run --gpus 0,1 --tp-size 2
  $(basename "$0") -- --task-name terminal-bench-core
EOF
}

log() {
    local line

    line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    printf '%s\n' "$line"
    if [[ -n "$CONSOLE_LOG" ]]; then
        printf '%s\n' "$line" >>"$CONSOLE_LOG"
    fi
}

warn() {
    local line

    line="[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*"
    printf '%s\n' "$line" >&2
    if [[ -n "$CONSOLE_LOG" ]]; then
        printf '%s\n' "$line" >>"$CONSOLE_LOG"
    fi
}

die() {
    local line

    line="[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*"
    printf '%s\n' "$line" >&2
    if [[ -n "$CONSOLE_LOG" ]]; then
        printf '%s\n' "$line" >>"$CONSOLE_LOG"
    fi
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 \
        || die "Required command not found: $1"
}

print_command() {
    local arg

    printf '  '
    for arg in "$@"; do
        printf '%q ' "$arg"
    done
    printf '\n'
}

format_command() {
    local arg

    for arg in "$@"; do
        printf '%q ' "$arg"
    done
}

is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

discover_profile() {
    local args=("$@")
    local index=0

    while (( index < ${#args[@]} )); do
        case "${args[$index]}" in
            --profile)
                (( index + 1 < ${#args[@]} )) \
                    || die "--profile requires a value"
                PROFILE="${args[$((index + 1))]}"
                index=$((index + 2))
                ;;
            --)
                break
                ;;
            *)
                index=$((index + 1))
                ;;
        esac
    done

    case "$PROFILE" in
        "$DEFAULT_PROFILE"|"$PUBLISHED_PROFILE"|"$MXFP4_PROFILE")
            ;;
        *)
            die "unsupported profile: $PROFILE"
            ;;
    esac
}

apply_profile_defaults() {
    HARBOR_AGENT="$DEFAULT_AGENT"
    HARBOR_PARSER="$DEFAULT_HARBOR_PARSER"
    TEMPERATURE="$DEFAULT_TEMPERATURE"
    TOP_P="$DEFAULT_TOP_P"
    TOOL_CALL_PARSER="$DEFAULT_TOOL_CALL_PARSER"
    REASONING_PARSER="$DEFAULT_REASONING_PARSER"
    GPU_MEMORY_UTILIZATION="0.90"
    DECODE_CONTEXT_PARALLEL_SIZE=1
    KV_CACHE_DTYPE="auto"
    CALCULATE_KV_SCALES=false
    MAX_NUM_SEQS=""
    CPU_OFFLOAD_GB="0"
    ENFORCE_EAGER=false
    LANGUAGE_MODEL_ONLY=false
    N_CONCURRENT=4
    MIN_FREE_GB=100

    case "$PROFILE" in
        "$DEFAULT_PROFILE")
            MODEL_NAME="$DEFAULT_MODEL"
            MODEL_REVISION="$DEFAULT_MODEL_REVISION"
            BENCHMARK_DATASET="$DEFAULT_DATASET"
            MAX_MODEL_LEN="$DEFAULT_MAX_MODEL_LEN"
            TASK_CPUS=""
            TASK_MEMORY_MB=""
            ;;
        "$PUBLISHED_PROFILE")
            MODEL_NAME="$PUBLISHED_MODEL"
            MODEL_REVISION="$PUBLISHED_MODEL_REVISION"
            BENCHMARK_DATASET="$PUBLISHED_DATASET"
            MAX_MODEL_LEN="$PUBLISHED_MAX_MODEL_LEN"
            TASK_CPUS="$PUBLISHED_TASK_CPUS"
            TASK_MEMORY_MB="$PUBLISHED_TASK_MEMORY_MB"
            ;;
        "$MXFP4_PROFILE")
            MODEL_NAME="$MXFP4_MODEL"
            MODEL_REVISION="$MXFP4_MODEL_REVISION"
            BENCHMARK_DATASET="$PUBLISHED_DATASET"
            MAX_MODEL_LEN="$PUBLISHED_MAX_MODEL_LEN"
            TASK_CPUS="$PUBLISHED_TASK_CPUS"
            TASK_MEMORY_MB="$PUBLISHED_TASK_MEMORY_MB"
            TP_SIZE=8
            GPU_MEMORY_UTILIZATION="0.95"
            DECODE_CONTEXT_PARALLEL_SIZE="$MXFP4_DCP_SIZE"
            KV_CACHE_DTYPE="$MXFP4_KV_CACHE_DTYPE"
            CALCULATE_KV_SCALES=true
            MAX_NUM_SEQS="$MXFP4_MAX_NUM_SEQS"
            ENFORCE_EAGER=true
            LANGUAGE_MODEL_ONLY=true
            N_CONCURRENT=1
            MIN_FREE_GB="$MXFP4_MIN_FREE_GB"
            ;;
    esac
}

update_profile_modified() {
    local expected_model expected_revision expected_dataset expected_max_model_len
    local expected_task_cpus expected_task_memory_mb
    local expected_gpu_memory_utilization="0.90"
    local expected_dcp_size=1
    local expected_kv_cache_dtype="auto"
    local expected_calculate_kv_scales=false
    local expected_max_num_seqs=""
    local expected_cpu_offload_gb="0"
    local expected_enforce_eager=false
    local expected_language_model_only=false
    local expected_n_concurrent=4

    case "$PROFILE" in
        "$DEFAULT_PROFILE")
            expected_model="$DEFAULT_MODEL"
            expected_revision="$DEFAULT_MODEL_REVISION"
            expected_dataset="$DEFAULT_DATASET"
            expected_max_model_len="$DEFAULT_MAX_MODEL_LEN"
            expected_task_cpus=""
            expected_task_memory_mb=""
            ;;
        "$PUBLISHED_PROFILE")
            expected_model="$PUBLISHED_MODEL"
            expected_revision="$PUBLISHED_MODEL_REVISION"
            expected_dataset="$PUBLISHED_DATASET"
            expected_max_model_len="$PUBLISHED_MAX_MODEL_LEN"
            expected_task_cpus="$PUBLISHED_TASK_CPUS"
            expected_task_memory_mb="$PUBLISHED_TASK_MEMORY_MB"
            ;;
        "$MXFP4_PROFILE")
            expected_model="$MXFP4_MODEL"
            expected_revision="$MXFP4_MODEL_REVISION"
            expected_dataset="$PUBLISHED_DATASET"
            expected_max_model_len="$PUBLISHED_MAX_MODEL_LEN"
            expected_task_cpus="$PUBLISHED_TASK_CPUS"
            expected_task_memory_mb="$PUBLISHED_TASK_MEMORY_MB"
            expected_gpu_memory_utilization="0.95"
            expected_dcp_size="$MXFP4_DCP_SIZE"
            expected_kv_cache_dtype="$MXFP4_KV_CACHE_DTYPE"
            expected_calculate_kv_scales=true
            expected_max_num_seqs="$MXFP4_MAX_NUM_SEQS"
            expected_enforce_eager=true
            expected_language_model_only=true
            expected_n_concurrent=1
            ;;
    esac

    if [[ "$PROFILE" != "$MXFP4_PROFILE" && "$BACKEND" == "amd" ]]; then
        expected_enforce_eager=true
    fi

    PROFILE_MODIFIED=false
    if [[ "$MODEL_NAME" != "$expected_model" \
        || "$MODEL_REVISION" != "$expected_revision" \
        || "$BENCHMARK_DATASET" != "$expected_dataset" \
        || "$MAX_MODEL_LEN" != "$expected_max_model_len" \
        || "$TOOL_CALL_PARSER" != "$DEFAULT_TOOL_CALL_PARSER" \
        || "$REASONING_PARSER" != "$DEFAULT_REASONING_PARSER" \
        || "$HARBOR_AGENT" != "$DEFAULT_AGENT" \
        || "$HARBOR_PARSER" != "$DEFAULT_HARBOR_PARSER" \
        || "$TEMPERATURE" != "$DEFAULT_TEMPERATURE" \
        || "$TOP_P" != "$DEFAULT_TOP_P" \
        || "$TASK_CPUS" != "$expected_task_cpus" \
        || "$TASK_MEMORY_MB" != "$expected_task_memory_mb" \
        || "$GPU_MEMORY_UTILIZATION" != "$expected_gpu_memory_utilization" \
        || "$DECODE_CONTEXT_PARALLEL_SIZE" != "$expected_dcp_size" \
        || "$KV_CACHE_DTYPE" != "$expected_kv_cache_dtype" \
        || "$CALCULATE_KV_SCALES" != "$expected_calculate_kv_scales" \
        || "$MAX_NUM_SEQS" != "$expected_max_num_seqs" \
        || "$CPU_OFFLOAD_GB" != "$expected_cpu_offload_gb" \
        || "$ENFORCE_EAGER" != "$expected_enforce_eager" \
        || "$LANGUAGE_MODEL_ONLY" != "$expected_language_model_only" \
        || "$N_CONCURRENT" != "$expected_n_concurrent" ]]
    then
        PROFILE_MODIFIED=true
    fi

    if [[ "$PROFILE" == "$MXFP4_PROFILE" ]] \
        && [[ "$MIN_FREE_GB" != "$MXFP4_MIN_FREE_GB" \
            || "$TP_SIZE" != "8" \
            || "$SELECTED_GPU_COUNT" != "8" \
            || "$VLLM_IMAGE" != "$DEFAULT_NVIDIA_VLLM_IMAGE" ]]
    then
        PROFILE_MODIFIED=true
    fi
}

warn_profile_constraints() {
    if [[ "$PROFILE" == "$PUBLISHED_PROFILE" ]]; then
        warn "The 397B BF16 checkpoint requires an exceptionally large multi-GPU memory pool;" \
            "verify usable capacity before pulling the model"
    fi
    if [[ "$PROFILE" == "$MXFP4_PROFILE" ]]; then
        warn "The community MXFP4 checkpoint is experimental and is not directly comparable with the publisher's BF16 result"
        warn "A real eight-GPU startup test is still required; passing preflight does not guarantee the model will fit"
    fi
    if [[ "$PROFILE_MODIFIED" == true ]]; then
        warn "Effective settings are not directly comparable with the unmodified $PROFILE profile"
    fi
}

nvidia_backend_detected() {
    local gpu_indices

    command -v nvidia-smi >/dev/null 2>&1 || return 1
    gpu_indices="$(
        nvidia-smi \
            --query-gpu=index \
            --format=csv,noheader,nounits 2>/dev/null
    )" || return 1
    grep -Eq '^[[:space:]]*[0-9]+[[:space:]]*$' <<<"$gpu_indices"
}

amd_backend_detected() {
    local rocminfo_output

    command -v rocminfo >/dev/null 2>&1 || return 1
    [[ -e "$AMD_DEVICE_ROOT/kfd" && -d "$AMD_DEVICE_ROOT/dri" ]] || return 1
    rocminfo_output="$(rocminfo 2>/dev/null)" || return 1
    awk '
        $1 == "Name:" && $2 ~ /^gfx[0-9]+$/ {
            found = 1
        }
        END {
            exit !found
        }
    ' <<<"$rocminfo_output"
}

resolve_backend() {
    local nvidia_detected=false
    local amd_detected=false

    case "$BACKEND" in
        nvidia|amd)
            return 0
            ;;
        auto)
            ;;
        *)
            die "--backend must be 'auto', 'nvidia', or 'amd'"
            ;;
    esac

    if nvidia_backend_detected; then
        nvidia_detected=true
    fi
    if amd_backend_detected; then
        amd_detected=true
    fi

    if [[ "$nvidia_detected" == true && "$amd_detected" == true ]]; then
        die "Auto backend detected both NVIDIA and AMD GPUs; use --backend nvidia or --backend amd"
    fi
    if [[ "$nvidia_detected" == true ]]; then
        BACKEND="nvidia"
        return 0
    fi
    if [[ "$amd_detected" == true ]]; then
        BACKEND="amd"
        return 0
    fi

    die "Auto backend could not detect a usable NVIDIA or AMD GPU backend; verify the vendor runtime or use an explicit --backend"
}

apply_backend_defaults() {
    case "$BACKEND" in
        nvidia)
            if [[ "$IMAGE_WAS_SET" == false ]]; then
                VLLM_IMAGE="$DEFAULT_NVIDIA_VLLM_IMAGE"
            fi
            ;;
        amd)
            if [[ "$IMAGE_WAS_SET" == false ]]; then
                VLLM_IMAGE="$DEFAULT_AMD_VLLM_IMAGE"
            fi
            if [[ "$EAGER_WAS_SET" == false ]]; then
                ENFORCE_EAGER=true
            fi
            ;;
        *)
            die "Internal error: unresolved backend: $BACKEND"
            ;;
    esac
}

validate_arguments() {
    is_positive_integer "$PORT" && (( PORT <= 65535 )) \
        || die "--port must be an integer from 1 to 65535"
    is_positive_integer "$MAX_MODEL_LEN" \
        || die "--max-model-len must be a positive integer"
    is_positive_integer "$N_CONCURRENT" \
        || die "--n-concurrent must be a positive integer"
    is_positive_integer "$DECODE_CONTEXT_PARALLEL_SIZE" \
        || die "--decode-context-parallel-size must be a positive integer"
    [[ -z "$MAX_NUM_SEQS" ]] || is_positive_integer "$MAX_NUM_SEQS" \
        || die "--max-num-seqs must be a positive integer"
    is_positive_integer "$STARTUP_TIMEOUT" \
        || die "--startup-timeout must be a positive integer"
    [[ -z "$TASK_CPUS" ]] || is_positive_integer "$TASK_CPUS" \
        || die "--task-cpus must be a positive integer"
    [[ -z "$TASK_MEMORY_MB" ]] || is_positive_integer "$TASK_MEMORY_MB" \
        || die "--task-memory-mb must be a positive integer"
    [[ "$MIN_FREE_GB" =~ ^[0-9]+$ ]] \
        || die "--min-free-gb must be a non-negative integer"
    [[ "$CPU_OFFLOAD_GB" =~ ^[0-9]+([.][0-9]+)?$ ]] \
        || die "--cpu-offload-gb must be a non-negative number"
    [[ -n "$KV_CACHE_DTYPE" ]] \
        || die "--kv-cache-dtype must not be empty"
    [[ "$GPU_MEMORY_UTILIZATION" =~ ^0(\.[0-9]+)?$|^1(\.0+)?$ ]] \
        || die "--gpu-memory-utilization must be between 0 and 1"
    awk -v value="$GPU_MEMORY_UTILIZATION" \
        'BEGIN { exit !(value > 0 && value <= 1) }' \
        || die "--gpu-memory-utilization must be greater than 0"
    [[ "$TEMPERATURE" =~ ^[0-9]+([.][0-9]+)?$ ]] \
        && awk -v value="$TEMPERATURE" \
            'BEGIN { exit !(value >= 0 && value <= 2) }' \
        || die "--temperature must be between 0 and 2"
    [[ "$TOP_P" =~ ^[0-9]+([.][0-9]+)?$ ]] \
        && awk -v value="$TOP_P" \
            'BEGIN { exit !(value > 0 && value <= 1) }' \
        || die "--top-p must be greater than 0 and at most 1"
    [[ -n "$HARBOR_PARSER" ]] \
        || die "--harbor-parser must not be empty"
    [[ "$GPU_SELECTION" == "all" || "$GPU_SELECTION" =~ ^[0-9]+(,[0-9]+)*$ ]] \
        || die "--gpus must be 'all' or a comma-separated list of GPU indices"
    [[ "$VLLM_IMAGE" != *":latest" ]] \
        || die "--vllm-image must use a pinned tag, not :latest"

    if [[ "$MODEL_WAS_SET" == true && "$REVISION_WAS_SET" == false ]]; then
        die "A custom --model requires an explicit immutable --model-revision"
    fi
    if [[ "$PROFILE" == "$MXFP4_PROFILE" && "$BACKEND" != "nvidia" ]]; then
        die "$MXFP4_PROFILE requires the NVIDIA backend"
    fi
}

validate_effective_topology() {
    if [[ "$PROFILE" == "$MXFP4_PROFILE" ]]; then
        (( SELECTED_GPU_COUNT >= 8 )) \
            || die "$MXFP4_PROFILE requires at least 8 selected GPUs"
        (( TP_SIZE == SELECTED_GPU_COUNT )) \
            || die "$MXFP4_PROFILE tensor parallel size must equal the selected GPU count"
    fi

    (( TP_SIZE % DECODE_CONTEXT_PARALLEL_SIZE == 0 )) \
        || die "--decode-context-parallel-size: decode context parallel size must divide tensor parallel size"
}

check_mxfp4_gpu_capacity() {
    local index memory_mib total_mib=0
    local selected=()

    [[ "$PROFILE" == "$MXFP4_PROFILE" ]] || return 0
    IFS=',' read -r -a selected <<<"$SELECTED_GPUS"
    for index in "${selected[@]}"; do
        memory_mib="$(
            awk -F',' -v target="$index" '
                {
                    gpu_index = $1
                    memory = $3
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", gpu_index)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", memory)
                    if (gpu_index == target) {
                        print memory
                        exit
                    }
                }
            ' <<<"$GPU_INVENTORY"
        )"
        [[ "$memory_mib" =~ ^[0-9]+$ ]] \
            || die "Could not determine memory for selected NVIDIA GPU $index"
        total_mib=$((total_mib + memory_mib))
    done

    (( total_mib >= MXFP4_MIN_AGGREGATE_VRAM_MIB )) \
        || die "$MXFP4_PROFILE requires at least ${MXFP4_MIN_AGGREGATE_VRAM_MIB} MiB aggregate selected GPU memory; found ${total_mib} MiB"
}

prepare_dry_run_gpu_selection() {
    if [[ "$GPU_SELECTION" == "all" ]]; then
        SELECTED_GPUS="all"
        SELECTED_GPU_COUNT=1
    else
        SELECTED_GPUS="$GPU_SELECTION"
        SELECTED_GPU_COUNT="$(awk -F',' '{print NF}' <<<"$SELECTED_GPUS")"
    fi

    if [[ -z "$TP_SIZE" ]]; then
        TP_SIZE="$SELECTED_GPU_COUNT"
    fi
    is_positive_integer "$TP_SIZE" \
        || die "--tp-size must be a positive integer"
    if [[ "$SELECTED_GPUS" != "all" ]] && (( TP_SIZE > SELECTED_GPU_COUNT )); then
        die "--tp-size cannot exceed the number of selected GPUs"
    fi
    if [[ "$BACKEND" == "nvidia" ]]; then
        # Docker requires literal inner quotes when a device selector has commas.
        DOCKER_GPU_SPEC="\"device=$SELECTED_GPUS\""
    fi
}

prepare_nvidia_gpu_inventory() {
    local available_indices

    GPU_RUNTIME_VERSION="$(
        nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null \
            | head -n 1 \
            || true
    )"
    GPU_INVENTORY="$(
        nvidia-smi \
            --query-gpu=index,name,memory.total \
            --format=csv,noheader,nounits
    )"
    [[ -n "$GPU_INVENTORY" ]] \
        || die "nvidia-smi did not report any GPUs"

    available_indices="$(
        awk -F',' '{
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
            print $1
        }' <<<"$GPU_INVENTORY"
    )"
    finalize_gpu_selection "$available_indices"
    # Docker requires literal inner quotes when a device selector has commas.
    DOCKER_GPU_SPEC="\"device=$SELECTED_GPUS\""
}

prepare_amd_gpu_inventory() {
    local amd_agents available_indices gpu_count index rocm_smi_inventory

    amd_agents="$(
        rocminfo 2>/dev/null \
            | awk '$1 == "Name:" && $2 ~ /^gfx[0-9]+$/ {print $2}'
    )"
    gpu_count="$(awk 'NF {count++} END {print count + 0}' <<<"$amd_agents")"
    (( gpu_count > 0 )) \
        || die "rocminfo did not report any AMD GPU agents"

    available_indices=""
    for ((index = 0; index < gpu_count; index++)); do
        if [[ -n "$available_indices" ]]; then
            available_indices+=$'\n'
        fi
        available_indices+="$index"
    done

    GPU_ARCHITECTURES="$(printf '%s\n' "$amd_agents" | sort -u | paste -sd, -)"
    if [[ "$VLLM_IMAGE" == "$DEFAULT_AMD_VLLM_IMAGE" ]] \
        && grep -Evq '^gfx120[01]$' <<<"$amd_agents"; then
        die "The default AMD image supports gfx120X GPUs; use a pinned architecture-compatible --vllm-image for $GPU_ARCHITECTURES"
    fi
    GPU_RUNTIME_VERSION="$(rocm-smi --version 2>/dev/null | head -n 1 || true)"
    rocm_smi_inventory="$(
        rocm-smi --showproductname --showmeminfo vram --csv 2>/dev/null \
            || rocm-smi 2>/dev/null
    )"
    GPU_INVENTORY="$(
        printf 'ROCm architectures: %s\n%s\n' \
            "$GPU_ARCHITECTURES" \
            "$rocm_smi_inventory"
    )"
    finalize_gpu_selection "$available_indices"
}

finalize_gpu_selection() {
    local available_indices="$1"
    local selected index

    if [[ "$GPU_SELECTION" == "all" ]]; then
        SELECTED_GPUS="$(paste -sd, <<<"$available_indices")"
    else
        SELECTED_GPUS="$GPU_SELECTION"
        IFS=',' read -r -a selected <<<"$SELECTED_GPUS"
        for index in "${selected[@]}"; do
            grep -Fxq "$index" <<<"$available_indices" \
                || die "GPU index $index is not present on this host"
        done
        if [[ "$(printf '%s\n' "${selected[@]}" | sort -u | wc -l | tr -d ' ')" -ne "${#selected[@]}" ]]; then
            die "--gpus contains a duplicate GPU index"
        fi
    fi

    SELECTED_GPU_COUNT="$(awk -F',' '{print NF}' <<<"$SELECTED_GPUS")"
    if [[ -z "$TP_SIZE" ]]; then
        TP_SIZE="$SELECTED_GPU_COUNT"
    fi
    is_positive_integer "$TP_SIZE" \
        || die "--tp-size must be a positive integer"
    (( TP_SIZE <= SELECTED_GPU_COUNT )) \
        || die "--tp-size cannot exceed the number of selected GPUs"
}

prepare_gpu_selection() {
    if [[ "$BACKEND" == "nvidia" ]]; then
        prepare_nvidia_gpu_inventory
    else
        prepare_amd_gpu_inventory
    fi
}

build_server_command() {
    SERVER_COMMAND=(
        docker run
        --detach
        --name "$CONTAINER_NAME"
    )

    if [[ "$BACKEND" == "nvidia" ]]; then
        SERVER_COMMAND+=(--gpus "$DOCKER_GPU_SPEC")
    else
        SERVER_COMMAND+=(
            --device /dev/kfd
            --device /dev/dri
            --group-add video
            --cap-add SYS_PTRACE
            --security-opt seccomp=unconfined
        )
        if [[ "$SELECTED_GPUS" != "all" ]]; then
            SERVER_COMMAND+=(--env "ROCR_VISIBLE_DEVICES=$SELECTED_GPUS")
        fi
    fi

    SERVER_COMMAND+=(
        --ipc=host
        --volume infra-vllm-hf-cache:/root/.cache/huggingface
        --publish "127.0.0.1:$PORT:8000"
    )

    if [[ -n "${HF_TOKEN:-}" ]]; then
        SERVER_COMMAND+=(--env HF_TOKEN)
    fi

    if [[ "$BACKEND" == "amd" ]]; then
        SERVER_COMMAND+=(--entrypoint vllm "$VLLM_IMAGE" serve)
    else
        SERVER_COMMAND+=("$VLLM_IMAGE")
    fi

    SERVER_COMMAND+=(
        --model "$MODEL_NAME"
        --served-model-name "$SERVED_MODEL_NAME"
        --revision "$MODEL_REVISION"
        --tensor-parallel-size "$TP_SIZE"
        --max-model-len "$MAX_MODEL_LEN"
        --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION"
        --enable-prefix-caching
        --enable-auto-tool-choice
    )
    if [[ "$ENFORCE_EAGER" == true ]]; then
        SERVER_COMMAND+=(--enforce-eager)
    fi
    if (( DECODE_CONTEXT_PARALLEL_SIZE > 1 )); then
        SERVER_COMMAND+=(
            --decode-context-parallel-size "$DECODE_CONTEXT_PARALLEL_SIZE"
        )
    fi
    if [[ "$KV_CACHE_DTYPE" != "auto" ]]; then
        SERVER_COMMAND+=(--kv-cache-dtype "$KV_CACHE_DTYPE")
    fi
    if [[ "$CALCULATE_KV_SCALES" == true ]]; then
        SERVER_COMMAND+=(--calculate-kv-scales)
    fi
    if [[ -n "$MAX_NUM_SEQS" ]]; then
        SERVER_COMMAND+=(--max-num-seqs "$MAX_NUM_SEQS")
    fi
    if awk -v value="$CPU_OFFLOAD_GB" 'BEGIN { exit !(value > 0) }'; then
        SERVER_COMMAND+=(--cpu-offload-gb "$CPU_OFFLOAD_GB")
    fi
    if [[ "$LANGUAGE_MODEL_ONLY" == true ]]; then
        SERVER_COMMAND+=(--language-model-only)
    fi
    if [[ "$TOOL_CALL_PARSER" != "none" ]]; then
        SERVER_COMMAND+=(--tool-call-parser "$TOOL_CALL_PARSER")
    fi
    if [[ "$REASONING_PARSER" != "none" ]]; then
        SERVER_COMMAND+=(--reasoning-parser "$REASONING_PARSER")
    fi
    SERVER_COMMAND+=(--trust-remote-code)
    VLLM_COMMAND_DISPLAY="$(format_command "${SERVER_COMMAND[@]}")"
}

build_harbor_command() {
    HARBOR_COMMAND=(
        uv tool run
        --isolated
        --python 3.12
        --managed-python
        --from "harbor==$DEFAULT_HARBOR_VERSION"
        harbor
    )
    HARBOR_RUN_COMMAND=(
        "${HARBOR_COMMAND[@]}"
        run
        --dataset "$BENCHMARK_DATASET"
        --agent "$HARBOR_AGENT"
        --model "openai/$SERVED_MODEL_NAME"
        --n-concurrent "$N_CONCURRENT"
        --agent-kwarg "api_base=http://127.0.0.1:$PORT/v1"
        --agent-kwarg "parser_name=$HARBOR_PARSER"
        --agent-kwarg "temperature=$TEMPERATURE"
        --agent-kwarg "top_p=$TOP_P"
    )
    if [[ -n "$TASK_CPUS" ]]; then
        HARBOR_RUN_COMMAND+=(--override-cpus "$TASK_CPUS")
    fi
    if [[ -n "$TASK_MEMORY_MB" ]]; then
        HARBOR_RUN_COMMAND+=(--override-memory-mb "$TASK_MEMORY_MB")
    fi
    if [[ "$HARBOR_ARGS_PRESENT" == true ]]; then
        HARBOR_RUN_COMMAND+=("${HARBOR_ARGS[@]}")
        HARBOR_ARGS_DISPLAY="$(format_command "${HARBOR_ARGS[@]}")"
    fi
    HARBOR_COMMAND_DISPLAY="$(format_command "${HARBOR_RUN_COMMAND[@]}")"
}

show_dry_run() {
    local planned_output

    planned_output="${OUTPUT_DIR:-$REPO_ROOT/test/logs/vllm-benchmark/TIMESTAMP}"
    if [[ "$BACKEND" == "amd" ]]; then
        CONTAINER_NAME="infra-vllm-benchmark-amd-$PORT"
    else
        CONTAINER_NAME="infra-vllm-benchmark-$PORT"
    fi
    SERVED_MODEL_NAME="${MODEL_NAME##*/}"
    build_server_command
    build_harbor_command

    printf 'Dry run; no host checks or filesystem changes will be made.\n'
    printf 'Profile: %s\n' "$PROFILE"
    printf 'Profile modified: %s\n' "$PROFILE_MODIFIED"
    printf 'Backend: %s\n' "$BACKEND"
    warn_profile_constraints
    printf 'Output directory: %s\n' "$planned_output"
    printf 'Minimum Docker free space: %s GB\n' "$MIN_FREE_GB"
    printf 'vLLM server command:\n'
    print_command "${SERVER_COMMAND[@]}"
    printf 'Harbor environment: OPENAI_API_KEY=EMPTY OPENAI_API_BASE=%s\n' \
        "http://127.0.0.1:$PORT/v1"
    if [[ "$SMOKE_ONLY" == false ]]; then
        printf 'Harbor command:\n'
        print_command "${HARBOR_RUN_COMMAND[@]}"
    else
        printf 'Harbor benchmark: skipped by --smoke\n'
    fi
    if [[ "$BACKEND" == "amd" && "$MODEL_NAME" == "$DEFAULT_MODEL" ]] \
        && (( SELECTED_GPU_COUNT < 4 )); then
        printf 'WARNING: the default 35B BF16 model is intended for at least four 32GB R9700S-class GPUs.\n'
    fi
}

port_is_occupied() {
    python3 - "$PORT" <<'PY'
import socket
import sys

with socket.socket() as sock:
    sock.settimeout(0.3)
    raise SystemExit(0 if sock.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)
PY
}

check_docker_free_space() {
    local docker_root available_kb required_kb

    (( MIN_FREE_GB > 0 )) || return 0
    docker_root="$(docker info --format '{{.DockerRootDir}}')"
    [[ -n "$docker_root" && -d "$docker_root" ]] \
        || die "Docker root directory is unavailable: $docker_root"
    available_kb="$(df -Pk "$docker_root" | awk 'NR == 2 {print $4}')"
    required_kb=$((MIN_FREE_GB * 1024 * 1024))
    [[ "$available_kb" =~ ^[0-9]+$ ]] \
        || die "Could not determine free space under Docker root: $docker_root"
    (( available_kb >= required_kb )) \
        || die "Docker root needs at least ${MIN_FREE_GB}GB free; found $((available_kb / 1024 / 1024))GB"
}

write_metadata() {
    local status="$1"
    local exit_code="$2"

    python3 - \
        "$METADATA_FILE" \
        "$status" \
        "$exit_code" \
        "$BACKEND" \
        "$PROFILE" \
        "$PROFILE_MODIFIED" \
        "$MODEL_NAME" \
        "$MODEL_REVISION" \
        "$SERVED_MODEL_NAME" \
        "$VLLM_IMAGE" \
        "$IMAGE_DIGEST" \
        "$SELECTED_GPUS" \
        "$TP_SIZE" \
        "$MAX_MODEL_LEN" \
        "$GPU_MEMORY_UTILIZATION" \
        "$DECODE_CONTEXT_PARALLEL_SIZE" \
        "$KV_CACHE_DTYPE" \
        "$CALCULATE_KV_SCALES" \
        "$MAX_NUM_SEQS" \
        "$CPU_OFFLOAD_GB" \
        "$ENFORCE_EAGER" \
        "$LANGUAGE_MODEL_ONLY" \
        "$MIN_FREE_GB" \
        "$TOOL_CALL_PARSER" \
        "$REASONING_PARSER" \
        "$HARBOR_PARSER" \
        "$TEMPERATURE" \
        "$TOP_P" \
        "$TASK_CPUS" \
        "$TASK_MEMORY_MB" \
        "$BENCHMARK_DATASET" \
        "$HARBOR_AGENT" \
        "$DEFAULT_HARBOR_VERSION" \
        "$N_CONCURRENT" \
        "$PORT" \
        "$DOCKER_VERSION" \
        "$GPU_RUNTIME_VERSION" \
        "$GPU_ARCHITECTURES" \
        "$GPU_INVENTORY" \
        "$SMOKE_ONLY" \
        "$VLLM_COMMAND_DISPLAY" \
        "$HARBOR_COMMAND_DISPLAY" \
        "$HARBOR_ARGS_DISPLAY" \
        "$([[ -n "${HF_TOKEN:-}" ]] && printf true || printf false)" <<'PY'
import json
import sys
from datetime import datetime, timezone

(
    path,
    status,
    exit_code,
    backend,
    profile,
    profile_modified,
    model,
    revision,
    served_model,
    image,
    image_digest,
    selected_gpus,
    tp_size,
    max_model_len,
    gpu_memory_utilization,
    decode_context_parallel_size,
    kv_cache_dtype,
    calculate_kv_scales,
    max_num_seqs,
    cpu_offload_gb,
    enforce_eager,
    language_model_only,
    min_free_gb,
    tool_call_parser,
    reasoning_parser,
    harbor_parser,
    temperature,
    top_p,
    task_cpus,
    task_memory_mb,
    dataset,
    agent,
    harbor_version,
    n_concurrent,
    port,
    docker_version,
    gpu_runtime_version,
    gpu_architectures,
    gpu_inventory,
    smoke_only,
    vllm_command,
    harbor_command,
    harbor_extra_args,
    hf_token_present,
) = sys.argv[1:]

payload = {
    "timestamp_utc": datetime.now(timezone.utc).isoformat(),
    "status": status,
    "exit_code": int(exit_code),
    "mode": "smoke" if smoke_only == "true" else "benchmark",
    "backend": backend,
    "profile": profile,
    "profile_modified": profile_modified == "true",
    "model": model,
    "model_revision": revision,
    "served_model_name": served_model,
    "vllm_image": image,
    "vllm_image_digest": image_digest,
    "selected_gpus": selected_gpus.split(","),
    "tensor_parallel_size": int(tp_size),
    "max_model_len": int(max_model_len),
    "gpu_memory_utilization": float(gpu_memory_utilization),
    "decode_context_parallel_size": int(decode_context_parallel_size),
    "kv_cache_dtype": kv_cache_dtype,
    "calculate_kv_scales": calculate_kv_scales == "true",
    "max_num_seqs": int(max_num_seqs) if max_num_seqs else None,
    "cpu_offload_gb": float(cpu_offload_gb),
    "enforce_eager": enforce_eager == "true",
    "language_model_only": language_model_only == "true",
    "min_free_gb": int(min_free_gb),
    "tool_call_parser": tool_call_parser,
    "reasoning_parser": reasoning_parser,
    "harbor_parser": harbor_parser,
    "temperature": float(temperature),
    "top_p": float(top_p),
    "task_cpus": int(task_cpus) if task_cpus else None,
    "task_memory_mb": int(task_memory_mb) if task_memory_mb else None,
    "dataset": dataset,
    "agent": agent,
    "harbor_version": harbor_version,
    "n_concurrent": int(n_concurrent),
    "port": int(port),
    "docker_version": docker_version,
    "gpu_runtime_version": gpu_runtime_version,
    "gpu_architectures": [
        item for item in gpu_architectures.split(",") if item
    ],
    "gpu_inventory": gpu_inventory.splitlines(),
    "vllm_command": vllm_command,
    "harbor_command": harbor_command,
    "harbor_extra_args": harbor_extra_args,
    "hf_token_present": hf_token_present == "true",
}

with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
}

write_summary() {
    local status="$1"
    local exit_code="$2"

    {
        printf 'status=%s\n' "$status"
        printf 'exit_code=%s\n' "$exit_code"
        printf 'mode=%s\n' "$([[ "$SMOKE_ONLY" == true ]] && printf smoke || printf benchmark)"
        printf 'backend=%s\n' "$BACKEND"
        printf 'profile=%s\n' "$PROFILE"
        printf 'profile_modified=%s\n' "$PROFILE_MODIFIED"
        printf 'model=%s\n' "$MODEL_NAME"
        printf 'model_revision=%s\n' "$MODEL_REVISION"
        printf 'vllm_image=%s\n' "$VLLM_IMAGE"
        printf 'selected_gpus=%s\n' "$SELECTED_GPUS"
        printf 'tensor_parallel_size=%s\n' "$TP_SIZE"
        printf 'max_model_len=%s\n' "$MAX_MODEL_LEN"
        printf 'gpu_memory_utilization=%s\n' "$GPU_MEMORY_UTILIZATION"
        printf 'decode_context_parallel_size=%s\n' "$DECODE_CONTEXT_PARALLEL_SIZE"
        printf 'kv_cache_dtype=%s\n' "$KV_CACHE_DTYPE"
        printf 'calculate_kv_scales=%s\n' "$CALCULATE_KV_SCALES"
        printf 'max_num_seqs=%s\n' "$MAX_NUM_SEQS"
        printf 'cpu_offload_gb=%s\n' "$CPU_OFFLOAD_GB"
        printf 'enforce_eager=%s\n' "$ENFORCE_EAGER"
        printf 'language_model_only=%s\n' "$LANGUAGE_MODEL_ONLY"
        printf 'min_free_gb=%s\n' "$MIN_FREE_GB"
        printf 'gpu_runtime_version=%s\n' "$GPU_RUNTIME_VERSION"
        printf 'gpu_architectures=%s\n' "$GPU_ARCHITECTURES"
        printf 'tool_call_parser=%s\n' "$TOOL_CALL_PARSER"
        printf 'reasoning_parser=%s\n' "$REASONING_PARSER"
        printf 'harbor_parser=%s\n' "$HARBOR_PARSER"
        printf 'temperature=%s\n' "$TEMPERATURE"
        printf 'top_p=%s\n' "$TOP_P"
        printf 'task_cpus=%s\n' "$TASK_CPUS"
        printf 'task_memory_mb=%s\n' "$TASK_MEMORY_MB"
        printf 'dataset=%s\n' "$BENCHMARK_DATASET"
        printf 'vllm_command=%s\n' "$VLLM_COMMAND_DISPLAY"
        printf 'harbor_command=%s\n' "$HARBOR_COMMAND_DISPLAY"
        printf 'harbor_extra_args=%s\n' "$HARBOR_ARGS_DISPLAY"
        printf 'run_directory=%s\n' "$RUN_DIR"
        if [[ "$KEEP_SERVER" == true && "$STARTED_SERVER" == true ]]; then
            printf 'server_container=%s (kept running)\n' "$CONTAINER_NAME"
        fi
    } >"$SUMMARY_FILE"
}

cleanup() {
    local exit_code=$?
    local status="failed"

    trap - EXIT
    set +e
    if [[ -n "$LOG_FOLLOW_PID" ]]; then
        kill "$LOG_FOLLOW_PID" >/dev/null 2>&1
        wait "$LOG_FOLLOW_PID" >/dev/null 2>&1
    fi
    if [[ "$STARTED_SERVER" == true && "$KEEP_SERVER" == false ]]; then
        log "Removing vLLM container: $CONTAINER_NAME"
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    fi
    if (( exit_code == 0 )); then
        status="completed"
    fi
    if [[ -n "$METADATA_FILE" ]]; then
        write_metadata "$status" "$exit_code" || true
        write_summary "$status" "$exit_code" || true
    fi
    exit "$exit_code"
}

wait_for_server() {
    local deadline=$((SECONDS + STARTUP_TIMEOUT))

    log "Waiting up to ${STARTUP_TIMEOUT}s for the vLLM API"
    while (( SECONDS < deadline )); do
        if [[ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)" != "true" ]]; then
            tail -n 50 "$SERVER_LOG" >&2 || true
            die "vLLM container stopped before becoming ready"
        fi

        if curl \
            --silent \
            --show-error \
            --fail \
            --max-time 10 \
            --output "$MODELS_JSON" \
            "http://127.0.0.1:$PORT/v1/models"
        then
            if python3 - "$MODELS_JSON" "$SERVED_MODEL_NAME" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
model_ids = {item.get("id") for item in payload.get("data", [])}
raise SystemExit(0 if sys.argv[2] in model_ids else 1)
PY
            then
                log "vLLM API is ready"
                return 0
            fi
        fi
        sleep 5
    done

    tail -n 50 "$SERVER_LOG" >&2 || true
    die "vLLM did not become ready within ${STARTUP_TIMEOUT}s"
}

run_smoke_test() {
    python3 - "$SMOKE_REQUEST" "$SERVED_MODEL_NAME" <<'PY'
import json
import sys

payload = {
    "model": sys.argv[2],
    "messages": [
        {
            "role": "user",
            "content": "Reply with exactly: vLLM smoke test passed",
        }
    ],
    "temperature": 0,
    "max_tokens": 32,
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

    log "Running OpenAI-compatible chat-completion smoke test"
    curl \
        --silent \
        --show-error \
        --fail \
        --max-time 120 \
        --header "Content-Type: application/json" \
        --data-binary "@$SMOKE_REQUEST" \
        --output "$SMOKE_RESPONSE" \
        "http://127.0.0.1:$PORT/v1/chat/completions"

    python3 - "$SMOKE_RESPONSE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
choices = payload.get("choices") or []
message = choices[0].get("message", {}) if choices else {}
content = message.get("content")
valid = isinstance(content, str) and content.strip() == "vLLM smoke test passed"
raise SystemExit(0 if valid else 1)
PY
    log "Chat-completion smoke test passed"
}

discover_profile "$@"
apply_profile_defaults

while (( $# > 0 )); do
    case "$1" in
        --profile)
            [[ $# -ge 2 ]] || die "--profile requires a value"
            shift 2
            ;;
        --backend)
            [[ $# -ge 2 ]] || die "--backend requires a value"
            BACKEND="$2"
            shift 2
            ;;
        --model)
            [[ $# -ge 2 ]] || die "--model requires a value"
            MODEL_NAME="$2"
            MODEL_WAS_SET=true
            shift 2
            ;;
        --model-revision)
            [[ $# -ge 2 ]] || die "--model-revision requires a value"
            MODEL_REVISION="$2"
            REVISION_WAS_SET=true
            shift 2
            ;;
        --vllm-image)
            [[ $# -ge 2 ]] || die "--vllm-image requires a value"
            VLLM_IMAGE="$2"
            IMAGE_WAS_SET=true
            shift 2
            ;;
        --gpus)
            [[ $# -ge 2 ]] || die "--gpus requires a value"
            GPU_SELECTION="${2//[[:space:]]/}"
            shift 2
            ;;
        --tp-size)
            [[ $# -ge 2 ]] || die "--tp-size requires a value"
            TP_SIZE="$2"
            shift 2
            ;;
        --port)
            [[ $# -ge 2 ]] || die "--port requires a value"
            PORT="$2"
            shift 2
            ;;
        --max-model-len)
            [[ $# -ge 2 ]] || die "--max-model-len requires a value"
            MAX_MODEL_LEN="$2"
            shift 2
            ;;
        --gpu-memory-utilization)
            [[ $# -ge 2 ]] || die "--gpu-memory-utilization requires a value"
            GPU_MEMORY_UTILIZATION="$2"
            shift 2
            ;;
        --decode-context-parallel-size)
            [[ $# -ge 2 ]] || die "--decode-context-parallel-size requires a value"
            DECODE_CONTEXT_PARALLEL_SIZE="$2"
            shift 2
            ;;
        --kv-cache-dtype)
            [[ $# -ge 2 ]] || die "--kv-cache-dtype requires a value"
            KV_CACHE_DTYPE="$2"
            shift 2
            ;;
        --calculate-kv-scales)
            CALCULATE_KV_SCALES=true
            shift
            ;;
        --no-calculate-kv-scales)
            CALCULATE_KV_SCALES=false
            shift
            ;;
        --max-num-seqs)
            [[ $# -ge 2 ]] || die "--max-num-seqs requires a value"
            MAX_NUM_SEQS="$2"
            shift 2
            ;;
        --cpu-offload-gb)
            [[ $# -ge 2 ]] || die "--cpu-offload-gb requires a value"
            CPU_OFFLOAD_GB="$2"
            shift 2
            ;;
        --enforce-eager)
            ENFORCE_EAGER=true
            EAGER_WAS_SET=true
            shift
            ;;
        --no-enforce-eager)
            ENFORCE_EAGER=false
            EAGER_WAS_SET=true
            shift
            ;;
        --language-model-only)
            LANGUAGE_MODEL_ONLY=true
            shift
            ;;
        --no-language-model-only)
            LANGUAGE_MODEL_ONLY=false
            shift
            ;;
        --tool-call-parser)
            [[ $# -ge 2 ]] || die "--tool-call-parser requires a value"
            TOOL_CALL_PARSER="$2"
            shift 2
            ;;
        --reasoning-parser)
            [[ $# -ge 2 ]] || die "--reasoning-parser requires a value"
            REASONING_PARSER="$2"
            shift 2
            ;;
        --dataset)
            [[ $# -ge 2 ]] || die "--dataset requires a value"
            BENCHMARK_DATASET="$2"
            shift 2
            ;;
        --agent)
            [[ $# -ge 2 ]] || die "--agent requires a value"
            HARBOR_AGENT="$2"
            shift 2
            ;;
        --harbor-parser)
            [[ $# -ge 2 ]] || die "--harbor-parser requires a value"
            HARBOR_PARSER="$2"
            shift 2
            ;;
        --temperature)
            [[ $# -ge 2 ]] || die "--temperature requires a value"
            TEMPERATURE="$2"
            shift 2
            ;;
        --top-p)
            [[ $# -ge 2 ]] || die "--top-p requires a value"
            TOP_P="$2"
            shift 2
            ;;
        --task-cpus)
            [[ $# -ge 2 ]] || die "--task-cpus requires a value"
            TASK_CPUS="$2"
            shift 2
            ;;
        --task-memory-mb)
            [[ $# -ge 2 ]] || die "--task-memory-mb requires a value"
            TASK_MEMORY_MB="$2"
            shift 2
            ;;
        --n-concurrent)
            [[ $# -ge 2 ]] || die "--n-concurrent requires a value"
            N_CONCURRENT="$2"
            shift 2
            ;;
        --startup-timeout)
            [[ $# -ge 2 ]] || die "--startup-timeout requires a value"
            STARTUP_TIMEOUT="$2"
            shift 2
            ;;
        --min-free-gb)
            [[ $# -ge 2 ]] || die "--min-free-gb requires a value"
            MIN_FREE_GB="$2"
            shift 2
            ;;
        --output-dir)
            [[ $# -ge 2 ]] || die "--output-dir requires a value"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --smoke)
            SMOKE_ONLY=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-pull)
            PULL_IMAGE=false
            shift
            ;;
        --keep-server)
            KEEP_SERVER=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            HARBOR_ARGS=("$@")
            if (( $# > 0 )); then
                HARBOR_ARGS_PRESENT=true
            fi
            break
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

resolve_backend
apply_backend_defaults
validate_arguments

if [[ "$DRY_RUN" == true ]]; then
    prepare_dry_run_gpu_selection
    validate_effective_topology
    update_profile_modified
    show_dry_run
    exit 0
fi

for command in docker curl python3 uv; do
    require_command "$command"
done
if [[ "$BACKEND" == "nvidia" ]]; then
    require_command nvidia-smi
else
    require_command rocm-smi
    require_command rocminfo
    [[ -e "$AMD_DEVICE_ROOT/kfd" ]] \
        || die "AMD compute device is unavailable: $AMD_DEVICE_ROOT/kfd"
    [[ -d "$AMD_DEVICE_ROOT/dri" ]] \
        || die "AMD DRM device directory is unavailable: $AMD_DEVICE_ROOT/dri"
fi

if (( EUID == 0 )); then
    warn "Running as root; benchmark artifacts and uv caches will be root-owned"
fi

docker info >/dev/null 2>&1 \
    || die "Docker is unavailable. Start Docker or re-login after docker-install.sh added your user to the docker group"

prepare_gpu_selection
validate_effective_topology
check_mxfp4_gpu_capacity
update_profile_modified
SERVED_MODEL_NAME="${MODEL_NAME##*/}"
if [[ "$BACKEND" == "amd" ]]; then
    CONTAINER_NAME="infra-vllm-benchmark-amd-$PORT"
else
    CONTAINER_NAME="infra-vllm-benchmark-$PORT"
fi
build_server_command
build_harbor_command

if port_is_occupied; then
    die "Port $PORT is already in use; choose another port with --port"
fi
if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    die "Container $CONTAINER_NAME already exists; remove it or choose another port"
fi

check_docker_free_space

if [[ -n "$OUTPUT_DIR" ]]; then
    RUN_DIR="$OUTPUT_DIR"
    if [[ -d "$RUN_DIR" && -n "$(find "$RUN_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        die "Output directory is not empty: $RUN_DIR"
    fi
else
    RUN_DIR="$REPO_ROOT/test/logs/vllm-benchmark/$(date -u '+%Y%m%d_%H%M%S')"
fi

mkdir -p "$RUN_DIR"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
SERVER_LOG="$RUN_DIR/server.log"
CONSOLE_LOG="$RUN_DIR/console.log"
HARBOR_LOG="$RUN_DIR/harbor.log"
MODELS_JSON="$RUN_DIR/models.json"
SMOKE_REQUEST="$RUN_DIR/smoke-request.json"
SMOKE_RESPONSE="$RUN_DIR/smoke-response.json"
METADATA_FILE="$RUN_DIR/metadata.json"
SUMMARY_FILE="$RUN_DIR/summary.txt"
touch "$SERVER_LOG" "$CONSOLE_LOG"
trap cleanup EXIT
trap 'exit 130' INT TERM

DOCKER_VERSION="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
write_metadata "starting" 0

log "Run directory: $RUN_DIR"
log "Profile: $PROFILE (modified: $PROFILE_MODIFIED)"
log "Backend: $BACKEND"
log "Model: $MODEL_NAME@$MODEL_REVISION"
log "GPUs: $SELECTED_GPUS (tensor parallel size: $TP_SIZE)"
log "vLLM image: $VLLM_IMAGE"
warn_profile_constraints
if [[ "$BACKEND" == "amd" && "$MODEL_NAME" == "$DEFAULT_MODEL" ]] \
    && (( SELECTED_GPU_COUNT < 4 )); then
    warn "The default 35B BF16 model is intended for at least four 32GB R9700S-class GPUs"
fi
if [[ -n "${HF_TOKEN:-}" && "$KEEP_SERVER" == true ]]; then
    warn "HF_TOKEN will remain in the kept container environment until $CONTAINER_NAME is removed"
fi

if [[ "$PULL_IMAGE" == true ]]; then
    log "Pulling pinned vLLM image"
    docker pull "$VLLM_IMAGE"
fi
docker image inspect "$VLLM_IMAGE" >/dev/null 2>&1 \
    || die "vLLM image is unavailable locally: $VLLM_IMAGE"
IMAGE_DIGEST="$(
    docker image inspect \
        --format '{{index .RepoDigests 0}}' \
        "$VLLM_IMAGE" 2>/dev/null \
        || true
)"

if ! docker volume inspect infra-vllm-hf-cache >/dev/null 2>&1; then
    log "Creating persistent Hugging Face cache volume"
    docker volume create infra-vllm-hf-cache >/dev/null
fi

if [[ "$BACKEND" == "nvidia" ]]; then
    log "Checking NVIDIA Container Toolkit access"
    docker run \
        --rm \
        --gpus "$DOCKER_GPU_SPEC" \
        --entrypoint nvidia-smi \
        "$VLLM_IMAGE" >/dev/null
else
    log "Checking ROCm device access inside the vLLM image"
    docker run \
        --rm \
        --device /dev/kfd \
        --device /dev/dri \
        --group-add video \
        --cap-add SYS_PTRACE \
        --security-opt seccomp=unconfined \
        --entrypoint rocminfo \
        "$VLLM_IMAGE" >/dev/null
fi

log "Launching named vLLM container: $CONTAINER_NAME"
"${SERVER_COMMAND[@]}" >/dev/null
STARTED_SERVER=true

docker logs --follow "$CONTAINER_NAME" >>"$SERVER_LOG" 2>&1 &
LOG_FOLLOW_PID=$!

wait_for_server
run_smoke_test

if [[ "$SMOKE_ONLY" == true ]]; then
    log "Smoke-only validation completed"
    exit 0
fi

log "Checking Harbor $DEFAULT_HARBOR_VERSION in an isolated Python 3.12 tool environment"
"${HARBOR_COMMAND[@]}" --version

log "Running $BENCHMARK_DATASET with agent $HARBOR_AGENT"
(
    cd "$RUN_DIR"
    OPENAI_API_KEY=EMPTY \
    OPENAI_API_BASE="http://127.0.0.1:$PORT/v1" \
        "${HARBOR_RUN_COMMAND[@]}" 2>&1 | tee "$HARBOR_LOG"
)

log "Harbor evaluation completed; inspect $RUN_DIR/jobs for task scores"
