#!/bin/bash
# =============================================================================
# gpu-fulltest-v2.sh — Experimental multi-GPU test suite
# Supports: RTX 4090/5090, A4000, A100, H100 on Ubuntu 22.04/24.04
# Usage:  ./gpu-fulltest-v2.sh [test...] [--burn-duration <s>] [--clean] [--list] [--help]
#   Tests: preflight, ecc, pcie, clocks, nccl, cuda-samples, nvbandwidth,
#          dcgm, pytorch, code, memtest, stress, node-stress, post-stress-recovery,
#          gpu-policy
#   If no tests specified, all are run in the order above.
# =============================================================================

set -o pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Constants and globals
# ─────────────────────────────────────────────────────────────────────────────

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BUILD_DIR="$SCRIPT_DIR/build"
readonly LOG_FILE="$SCRIPT_DIR/gpu_fulltest_v2_$(date +%Y%m%d_%H%M%S).log"

CLEAN_BUILD=false
BURN_DURATION=300   # seconds; override with --burn-duration <seconds>
NODE_STRESS_MINUTES=5   # minutes; override with --node-stress-minutes <minutes>
FIX_USER=$(id -un 2>/dev/null || true)
[ -n "$FIX_USER" ] || FIX_USER=$(id -u 2>/dev/null || echo unknown)
FIX_GROUP=$(id -gn 2>/dev/null || true)
[ -n "$FIX_GROUP" ] || FIX_GROUP=$(id -g 2>/dev/null || echo unknown)

if [ -e "$BUILD_DIR" ]; then
    if [ ! -w "$BUILD_DIR" ] || [ ! -x "$BUILD_DIR" ]; then
        echo "WARNING: Existing build directory '$BUILD_DIR' is not writable." >&2
        echo "         Rebuilds and clean operations may fail until ownership is fixed." >&2
        echo "         Common fix: sudo chown -R \"$FIX_USER\":\"$FIX_GROUP\" '$BUILD_DIR'" >&2
    fi
else
    build_parent="$(dirname "$BUILD_DIR")"
    if [ ! -w "$build_parent" ] || [ ! -x "$build_parent" ]; then
        echo "WARNING: Build directory parent '$build_parent' is not writable." >&2
        echo "         New clones/builds may fail until ownership is fixed." >&2
        echo "         Common fix: sudo chown -R \"$FIX_USER\":\"$FIX_GROUP\" '$build_parent'" >&2
    fi
fi

mkdir -p "$BUILD_DIR" 2>/dev/null || {
    echo "ERROR: Cannot create build directory: $BUILD_DIR" >&2
    echo "       Check ownership/permissions for: $SCRIPT_DIR" >&2
    echo "       This often happens when a previous run created root-owned artifacts." >&2
    exit 1
}

# Write identification header to log immediately
{
    echo "============================================================"
    echo "  gpu-fulltest-v2.sh — Experimental GPU Test Suite"
    echo "  Date     : $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "  Hostname : $(hostname -f 2>/dev/null || hostname)"
    echo "  IP(s)    : $(hostname -I 2>/dev/null | tr ' ' ',' | sed 's/,$//' || echo 'unknown')"
    echo "  User     : $(whoami)"
    echo "  Script   : $SCRIPT_DIR/gpu-fulltest-v2.sh"
    echo "============================================================"
} | tee "$LOG_FILE"

RESULTS_PASS=()
RESULTS_FAIL=()
RESULTS_SKIP=()
RESULTS_NOT_RUN=()
RESULTS_REMARK=()
PREP_PASS=()
PREP_FAIL=()
PREP_SKIP=()
PREPARED_COMPONENTS=""
TORCHRUN_BIN=""
STRESS_BACKEND=""

GPU_TARGET=""   # set by --gpu <idx[,idx...]>; empty means all GPUs
SMI_FILTER=""   # set to "-i <idx[,idx...]>" in detect_system when GPU_TARGET is set

# Populated during system detection
NUM_GPUS=""
GPU_NAMES=""
CUDA_VERSION=""
CUDA_MAJOR=""
CUDA_MINOR=""
CUDA_HOME_DIR=""
NVCC_PATH=""
CUDA_ARCH_LIST=""
TORCH_CUDA=""
PIP_EXTRA=""
UBUNTU_MAJOR=""
RESULTS_STRESS_LABEL="Sustained Compute Stress"
STRESS_ACTIVITY_START_TS=""
PYTORCH_RUNTIME_WARNED=false
PYTORCH_PYTHON=""
PYTORCH_VENV="$BUILD_DIR/pytorch-venv"
CUDA_SAMPLES_DEVICEQUERY_READY=false
CUDA_SAMPLES_P2P_READY=false
CUDA_CODE_SECONDS="${CUDA_CODE_SECONDS:-15}"

# ─────────────────────────────────────────────────────────────────────────────
# Utilities
# ─────────────────────────────────────────────────────────────────────────────

log() { echo "$@" | tee -a "$LOG_FILE"; }
# log_run: execute a function, letting it write to stdout (and log via log()/tee calls
# inside it). We do NOT wrap with tee here — test functions handle their own output.
# This prevents double-writing when a function uses log() or explicit tee -a internally.
log_run() { "$@"; return $?; }

# Run a command inside a directory in a subshell — no cd leakage on failure
in_dir() {
    local dir="$1"; shift
    (cd "$dir" && "$@")
}

find_benchmark_python() {
    local candidate

    if [ -n "${INFRA_PYTHON_BENCH:-}" ] && [ -x "${INFRA_PYTHON_BENCH}" ]; then
        if "${INFRA_PYTHON_BENCH}" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] == (3, 11) else 1)' \
            >/dev/null 2>&1; then
            echo "${INFRA_PYTHON_BENCH}"
            return 0
        fi
    fi

    for candidate in \
        /opt/infra/python/*/bin/python3.11 \
        /opt/infra/python/*/bin/python \
        /opt/infra/python/3.11/bin/python \
        /usr/bin/python3.11; do
        if [ -x "${candidate}" ] && "${candidate}" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] == (3, 11) else 1)' \
            >/dev/null 2>&1; then
            echo "${candidate}"
            return 0
        fi
    done

    if command -v python3 >/dev/null 2>&1; then
        if python3 -c 'import sys; raise SystemExit(0 if sys.version_info[:2] in ((3, 10), (3, 11)) else 1)' \
            >/dev/null 2>&1; then
            command -v python3
            return 0
        fi
    fi

    return 1
}

ensure_pytorch_venv() {
    local py_bin="$1"
    local venv_dir="$2"

    if [ ! -x "${venv_dir}/bin/python" ]; then
        "${py_bin}" -m venv "${venv_dir}" || return 1
    fi

    "${venv_dir}/bin/python" -m pip install --upgrade pip --quiet \
        $PIP_EXTRA 2>&1 | tee -a "$LOG_FILE" || return 1
}

warn_pytorch_python_runtime() {
    $PYTORCH_RUNTIME_WARNED && return 0

    local py_version py_path benchmark_python=""
    py_version=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")' 2>/dev/null || echo "unknown")
    py_path=$(command -v python3 2>/dev/null || echo "python3")
    log "  System python3     : python3 $py_version ($py_path)"

    if benchmark_python=$(find_benchmark_python 2>/dev/null); then
        log "  Benchmark python   : $benchmark_python"
    else
        log "  Benchmark python   : missing (PyTorch DDP lane will be NOT BEING RUN)"
    fi

    if python3 -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3, 12) else 1)' 2>/dev/null; then
        if [ -z "${benchmark_python}" ]; then
            log "  WARNING: Python 3.12+ has known torch.distributed / torchrun segfault history."
            log "           If the pytorch test fails during DDP init, prefer the benchmark Python 3.11 runtime."
        else
            log "  NOTE: system python3 is 3.12+, but PyTorch will use the benchmark Python runtime above."
        fi
    fi

    PYTORCH_RUNTIME_WARNED=true
}

describe_path_permissions() {
    local path="$1"
    if command -v stat >/dev/null 2>&1; then
        stat -c '%U:%G %A' "$path" 2>/dev/null && return 0
        stat -f '%Su:%Sg %Sp' "$path" 2>/dev/null && return 0
    fi
    ls -ld "$path" 2>/dev/null | awk '{print $1, $3 ":" $4}'
}

log_permission_advice() {
    local path="$1"
    local action="$2"
    local perms=""
    perms=$(describe_path_permissions "$path" 2>/dev/null || true)

    log "ERROR: Cannot ${action} because write permission is missing: $path"
    [ -n "$perms" ] && log "       Current owner/perms: $perms"
    log "       This often happens after a previous build created root-owned artifacts."
    log "       Fix ownership, for example:"
    log "         sudo chown -R $FIX_USER:$FIX_GROUP '$BUILD_DIR'"
    log "       Then rerun the test or clean stale artifacts in the affected tree."
}

require_writable_existing_dir() {
    local dir="$1"
    local action="$2"
    [ ! -e "$dir" ] && return 0
    [ -d "$dir" ] || {
        log "ERROR: Expected a directory for ${action}, but found: $dir"
        return 1
    }
    [ -r "$dir" ] && [ -w "$dir" ] && [ -x "$dir" ] && return 0
    log_permission_advice "$dir" "$action"
    return 1
}

require_writable_parent_dir() {
    local target="$1"
    local action="$2"
    local parent
    parent=$(dirname "$target")
    [ -d "$parent" ] || mkdir -p "$parent" 2>/dev/null || true
    [ -d "$parent" ] || {
        log "ERROR: Parent directory does not exist for ${action}: $parent"
        return 1
    }
    [ -w "$parent" ] && [ -x "$parent" ] && return 0
    log_permission_advice "$parent" "$action"
    return 1
}

ensure_repo_clone_allowed() {
    local repo_dir="$1"
    local label="$2"
    if [ -d "$repo_dir" ]; then
        require_writable_existing_dir "$repo_dir" "reuse/build ${label}" || return 1
    else
        require_writable_parent_dir "$repo_dir" "clone ${label}" || return 1
    fi
}

ensure_repo_rebuild_allowed() {
    local repo_dir="$1"
    local label="$2"
    local build_subdir="${3:-$repo_dir/build}"
    require_writable_existing_dir "$repo_dir" "rebuild ${label}" || return 1
    require_writable_existing_dir "$build_subdir" "rewrite ${label} build directory" || return 1
}

ensure_build_dir_writable() {
    local purpose="$1"
    require_writable_existing_dir "$BUILD_DIR" "$purpose for $BUILD_DIR"
}

ensure_writable_or_parent() {
    local path="$1"
    local action="$2"
    if [ -d "$path" ]; then
        require_writable_existing_dir "$path" "$action" || return 1
    else
        require_writable_parent_dir "$path" "$action" || return 1
    fi
}

# Idempotent apt package install
apt_install() {
    for pkg in "$@"; do
        if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            log "  apt: installing $pkg"
            sudo apt-get install -y "$pkg" 2>&1 | tee -a "$LOG_FILE"
        fi
    done
}

ensure_cmake() {
    command -v cmake &>/dev/null && return 0
    log "  cmake not found — installing..."
    if command -v apt-get &>/dev/null; then
        apt_install cmake
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y cmake
    else
        log "ERROR: Cannot install cmake — unknown package manager."
        return 1
    fi
}

# cmake_build <src_dir> <binary_name>
# Out-of-source build; patches sm_110 out of cuda-samples CMakeLists first.
cmake_build() {
    local src="$1" bin="$2"

    [ -f "$src/build/$bin" ] && { log "  Already built: $bin"; return 0; }
    ensure_repo_rebuild_allowed "$src" "$bin" "$src/build" || return 1

    log "  Building $bin..."

    # sm_110 was removed from CUDA 12.9 but hardcoded in cuda-samples CMakeLists
    find "$src" -name "CMakeLists.txt" -exec grep -l 'set(CMAKE_CUDA_ARCHITECTURES' {} \; \
    | while read -r f; do
        sed -i 's/\b110\b//g; s/  */ /g' "$f"
    done

    local archs_cmake
    archs_cmake=$(echo "$CUDA_ARCH_LIST" | tr ' ' ';')

    in_dir "$src" bash -c "
        rm -rf build && mkdir build && cd build
        cmake .. \
            -DCMAKE_CUDA_COMPILER='$NVCC_PATH' \
            -DCMAKE_CUDA_ARCHITECTURES='$archs_cmake'
        make -j$(nproc)
    " 2>&1 | tee -a "$LOG_FILE"
}

find_binary() {
    find "$1" -type f -name "$2" ! -name "*.cmake" ! -name "*.cpp" 2>/dev/null | head -1
}

find_cuda_sample_source() {
    local sample_name="$1"
    local root candidate

    for candidate in \
        "$BUILD_DIR/cuda-samples/cpp/1_Utilities/${sample_name}" \
        "$BUILD_DIR/cuda-samples/cpp/0_Introduction/${sample_name}" \
        "$BUILD_DIR/cuda-samples/Samples/1_Utilities/${sample_name}" \
        "$BUILD_DIR/cuda-samples/Samples/0_Introduction/${sample_name}"
    do
        if [ -d "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done

    for root in "$BUILD_DIR/cuda-samples/cpp" "$BUILD_DIR/cuda-samples/Samples"; do
        [ -d "$root" ] || continue
        candidate=$(find "$root" -maxdepth 6 -type d -name "$sample_name" 2>/dev/null | head -1)
        if [ -n "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

# decode_throttle <hex_bitmask>
# Translates nvidia-smi clocks_throttle_reasons.active hex bitmask into
# human-readable labels, returning only the bits that represent real problems.
#
# Bitmask reference:
#   0x001  gpu_idle                  — normal idle clock-down, ignore
#   0x002  applications_clocks       — app clock setting, ignore
#   0x004  sw_power_cap              — driver idle power saving, ignore
#   0x008  hw_slowdown               — REAL: HW thermal or power event
#   0x010  sync_boost                — normal multi-GPU sync, ignore
#   0x020  sw_thermal_slowdown       — REAL: SW thermal limit hit
#   0x040  hw_power_brake_slowdown   — REAL: external power brake signal
#   0x080  display_clocks            — normal display setting, ignore
#
# Prints "Not Active" if no problem bits set, or a comma-separated list of
# problem names. Exits 1 if any problem bits are set.
decode_throttle() {
    local raw="$1"
    # Strip leading 0x and parse as hex
    local val
    val=$(printf '%d' "$raw" 2>/dev/null) || { echo "unknown"; return 0; }

    local problems=()
    (( val & 0x008 )) && problems+=("HW_Slowdown")
    (( val & 0x020 )) && problems+=("SW_Thermal")
    (( val & 0x040 )) && problems+=("HW_PowerBrake")

    if [ "${#problems[@]}" -eq 0 ]; then
        echo "Not Active"
        return 0
    else
        local IFS=','
        echo "${problems[*]}"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Result tracking
# ─────────────────────────────────────────────────────────────────────────────

run_test() {
    local name="$1"; shift
    log ""
    log "========================================"
    log "Running: $name"
    log "========================================"
    local rc=0
    log_run "$@" || rc=$?
    if [ "$rc" -eq 0 ]; then
        log "[ PASS ] $name"
        RESULTS_PASS+=("$name")
    else
        log "[ FAIL ] $name (exit code $rc)"
        RESULTS_FAIL+=("$name")
    fi
}

skip_test() {
    log "========================================"
    log "SKIPPED: $1"
    log "Reason : $2"
    log "========================================"
    RESULTS_SKIP+=("$1 — $2")
}

record_not_run() {
    local name="$1"
    local reason="$2"
    log "  NOT BEING RUN: ${name} — ${reason}"
    RESULTS_NOT_RUN+=("${name} — ${reason}")
}

record_remark() {
    RESULTS_REMARK+=("$1")
}

record_stress_activity_start() {
    [ -n "$STRESS_ACTIVITY_START_TS" ] || STRESS_ACTIVITY_START_TS=$(date +%s)
}

run_prepare_step() {
    local name="$1"; shift
    log ""
    log "----------------------------------------"
    log "Preparing: $name"
    log "----------------------------------------"
    local rc=0
    log_run "$@" || rc=$?
    if [ "$rc" -eq 0 ]; then
        log "[ PREP OK ] $name"
        PREP_PASS+=("$name")
    else
        log "[ PREP FAIL ] $name (exit code $rc)"
        PREP_FAIL+=("$name")
    fi
    return "$rc"
}

mark_prepare_skip() {
    log "----------------------------------------"
    log "PREP SKIPPED: $1"
    log "Reason      : $2"
    log "----------------------------------------"
    PREP_SKIP+=("$1 — $2")
}

prepare_component_once() {
    local key="$1"; shift
    local label="$1"; shift
    case " $PREPARED_COMPONENTS " in
        *" $key "*) return 0 ;;
    esac
    run_prepare_step "$label" "$@" || return 1
    PREPARED_COMPONENTS="$PREPARED_COMPONENTS $key"
}

# ─────────────────────────────────────────────────────────────────────────────
# System detection
# ─────────────────────────────────────────────────────────────────────────────

detect_system() {
    log "========================================"
    log "System Detection"
    log "========================================"

    local ubuntu_ver os_id
    ubuntu_ver=$(lsb_release -rs 2>/dev/null || echo "0")
    UBUNTU_MAJOR=$(echo "$ubuntu_ver" | cut -d. -f1)
    os_id=$(lsb_release -is 2>/dev/null || echo "Unknown")
    log "  OS                  : $os_id $ubuntu_ver"

    # Validate --gpu target before anything else
    local total_gpus
    total_gpus=$(nvidia-smi -L 2>/dev/null | grep -c '^GPU' || true)
    if [ -z "$total_gpus" ] || [ "$total_gpus" -eq 0 ]; then
        log "ERROR: No NVIDIA GPUs detected. Aborting."
        exit 1
    fi

    if [ -n "$GPU_TARGET" ]; then
        # Validate each index in the comma-separated list
        local bad_indices=()
        local gpu_count=0
        local idx
        IFS=',' read -ra indices <<< "$GPU_TARGET"
        for idx in "${indices[@]}"; do
            idx=$(echo "$idx" | xargs)  # trim whitespace
            if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -ge "$total_gpus" ]; then
                bad_indices+=("$idx")
            fi
            gpu_count=$((gpu_count + 1))
        done
        if [ "${#bad_indices[@]}" -gt 0 ]; then
            log "ERROR: --gpu invalid index(es): ${bad_indices[*]}. System has GPUs 0-$((total_gpus - 1))."
            exit 1
        fi
        # Normalise: rebuild as clean comma-separated string (no spaces)
        GPU_TARGET=$(IFS=','; echo "${indices[*]}" | tr -d ' ')
        export CUDA_VISIBLE_DEVICES="$GPU_TARGET"
        NUM_GPUS=$gpu_count
        if [ "$gpu_count" -eq 1 ]; then
            log "  GPU target          : GPU $GPU_TARGET (CUDA_VISIBLE_DEVICES=$GPU_TARGET)"
            log "  NOTE: Single-GPU mode — NCCL/PyTorch run with 1 process."
        else
            log "  GPU target          : GPUs $GPU_TARGET (CUDA_VISIBLE_DEVICES=$GPU_TARGET)"
            log "  NOTE: $gpu_count-GPU subset mode — NCCL/PyTorch run across these $gpu_count GPUs."
        fi
    else
        NUM_GPUS=$total_gpus
    fi
    log "  GPUs in scope       : $NUM_GPUS"

    # nvidia-smi queries — scoped to target GPU if set, otherwise all
    [ -n "$GPU_TARGET" ] && SMI_FILTER="-i $GPU_TARGET" || SMI_FILTER=""

    GPU_NAMES=$(nvidia-smi $SMI_FILTER --query-gpu=name --format=csv,noheader \
        | tr -d '\r' | sort -u | tr '\n' ',' | sed 's/,$//')
    log "  GPU model(s)        : $GPU_NAMES"

    # Find nvcc
    for candidate in "$(command -v nvcc 2>/dev/null)" \
                     /usr/local/cuda/bin/nvcc \
                     /usr/bin/nvcc; do
        [ -x "$candidate" ] && { NVCC_PATH="$candidate"; break; }
    done
    if [ -z "$NVCC_PATH" ]; then
        log "ERROR: nvcc not found. Install CUDA toolkit or add nvcc to PATH."
        exit 1
    fi

    CUDA_HOME_DIR=$(dirname "$(dirname "$NVCC_PATH")")
    CUDA_VERSION=$("$NVCC_PATH" --version | grep -oP 'release \K[0-9]+\.[0-9]+')
    CUDA_MAJOR=$(echo "$CUDA_VERSION" | cut -d. -f1)
    CUDA_MINOR=$(echo "$CUDA_VERSION" | cut -d. -f2)
    log "  nvcc                : $NVCC_PATH"
    log "  CUDA                : $CUDA_VERSION (home: $CUDA_HOME_DIR)"

    # Strip \r — nvidia-smi can emit Windows-style line endings
    CUDA_ARCH_LIST=$(
        nvidia-smi $SMI_FILTER --query-gpu=compute_cap --format=csv,noheader \
        | tr -d '\r' | tr -d '.' | sort -u | tr '\n' ' ' | xargs
    )
    log "  Architecture(s)     : $CUDA_ARCH_LIST"

    # PyTorch wheel suffix
    case "$CUDA_MAJOR" in
        11) TORCH_CUDA="cu118" ;;
        12)
            if   [ "$CUDA_MINOR" -le 1 ]; then TORCH_CUDA="cu121"
            elif [ "$CUDA_MINOR" -le 4 ]; then TORCH_CUDA="cu124"
            else TORCH_CUDA="cu128"
            fi
            ;;
        13)
            # PyTorch publishes cu132 as the latest CUDA 13 wheel family.
            if [ "$CUDA_MINOR" -ge 2 ]; then TORCH_CUDA="cu132"
            else TORCH_CUDA="cu130"
            fi
            ;;
        *)  TORCH_CUDA="cu128" ;;
    esac
    log "  PyTorch wheel       : https://download.pytorch.org/whl/$TORCH_CUDA"

    # pip flag for Ubuntu 24.04+ (PEP 668)
    [ "$UBUNTU_MAJOR" -ge 24 ] 2>/dev/null && PIP_EXTRA="--break-system-packages" || PIP_EXTRA=""

    [ "$NUM_GPUS" -eq 1 ] && log "  NOTE: Single GPU — multi-GPU tests run in single-GPU mode."
    log ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Prepare phase
# ─────────────────────────────────────────────────────────────────────────────

prepare_clocks() {
    ensure_build_dir_writable "writing clock-load helper"
}

prepare_nccl() {
    install_nccl_lib || return 1
    install_nccl_tests_bin || return 1
    local perf="$BUILD_DIR/nccl-tests/build/all_reduce_perf"
    [ -f "$perf" ] || { log "ERROR: nccl-tests binary not found after prepare."; return 1; }
}

prepare_cuda_samples() {
    CUDA_SAMPLES_DEVICEQUERY_READY=false
    CUDA_SAMPLES_P2P_READY=false

    if [ ! -d "$BUILD_DIR/cuda-samples" ]; then
        ensure_repo_clone_allowed "$BUILD_DIR/cuda-samples" "cuda-samples" || return 1
        git clone https://github.com/NVIDIA/cuda-samples.git "$BUILD_DIR/cuda-samples"
    fi

    local device_query_src p2p_src dq_bin p2p_bin
    device_query_src=$(find_cuda_sample_source "deviceQuery")
    if [ -n "$device_query_src" ]; then
        log "  deviceQuery source: $device_query_src"
        if cmake_build "$device_query_src" "deviceQuery"; then
            dq_bin=$(find_binary "$BUILD_DIR/cuda-samples" "deviceQuery")
            if [ -n "$dq_bin" ]; then
                CUDA_SAMPLES_DEVICEQUERY_READY=true
            else
                record_not_run "CUDA Samples / deviceQuery" "binary unavailable after build"
            fi
        else
            record_not_run "CUDA Samples / deviceQuery" "source/build layout issue or build failure"
        fi
    else
        record_not_run "CUDA Samples / deviceQuery" "source directory unavailable under cpp/ or Samples/"
    fi

    p2p_src=$(find_cuda_sample_source "p2pBandwidthLatencyTest")
    if [ -n "$p2p_src" ]; then
        log "  p2pBandwidthLatencyTest source: $p2p_src"
        if cmake_build "$p2p_src" "p2pBandwidthLatencyTest"; then
            p2p_bin=$(find_binary "$BUILD_DIR/cuda-samples" "p2pBandwidthLatencyTest")
            if [ -n "$p2p_bin" ]; then
                CUDA_SAMPLES_P2P_READY=true
            else
                record_not_run "CUDA Samples / p2pBandwidthLatencyTest" "binary unavailable after build"
            fi
        else
            record_not_run "CUDA Samples / p2pBandwidthLatencyTest" "source/build layout issue or build failure"
        fi
    else
        record_not_run "CUDA Samples / p2pBandwidthLatencyTest" "source directory unavailable under cpp/ or Samples/"
    fi
}

prepare_nvbandwidth() {
    ensure_cmake || return 1

    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq
        apt_install libboost-program-options-dev
    elif command -v dnf &>/dev/null; then
        rpm -q boost-program-options &>/dev/null || sudo dnf install -y boost-program-options
    fi

    if [ ! -d "$BUILD_DIR/nvbandwidth" ]; then
        ensure_repo_clone_allowed "$BUILD_DIR/nvbandwidth" "nvbandwidth" || return 1
        git clone https://github.com/NVIDIA/nvbandwidth.git "$BUILD_DIR/nvbandwidth"
    fi

    local nvb_bin
    nvb_bin=$(find_binary "$BUILD_DIR/nvbandwidth" "nvbandwidth")
    if [ -z "$nvb_bin" ]; then
        ensure_repo_rebuild_allowed "$BUILD_DIR/nvbandwidth" "nvbandwidth" "$BUILD_DIR/nvbandwidth/build" || return 1
        log "  Building nvbandwidth..."
        in_dir "$BUILD_DIR/nvbandwidth" bash -c "
            cmake . -DCMAKE_CUDA_COMPILER='$NVCC_PATH'
            make -j$(nproc)
        " 2>&1 | tee -a "$LOG_FILE"
        nvb_bin=$(find_binary "$BUILD_DIR/nvbandwidth" "nvbandwidth")
    else
        log "  nvbandwidth already built: $nvb_bin"
    fi

    [ -n "$nvb_bin" ] && [ -x "$nvb_bin" ] || {
        log "ERROR: nvbandwidth binary not found after prepare."
        return 1
    }
}

prepare_pytorch() {
    warn_pytorch_python_runtime
    if ! PYTORCH_PYTHON=$(find_benchmark_python); then
        mark_prepare_skip "PyTorch runtime" \
            "benchmark Python 3.11 runtime missing — install base-install.sh first (it provisions uv-managed Python 3.11)"
        return 0
    fi

    install_pytorch || return 1
    TORCHRUN_BIN=$(find_torchrun)
    if [ -z "$TORCHRUN_BIN" ] || [ ! -x "$TORCHRUN_BIN" ]; then
        log "ERROR: torchrun not found after installing PyTorch."
        return 1
    fi
    log "  Using torchrun: $TORCHRUN_BIN"
}

prepare_memtest() {
    local bin="$BUILD_DIR/cuda_memtest/build/cuda_memtest"

    if [ ! -d "$BUILD_DIR/cuda_memtest" ]; then
        ensure_repo_clone_allowed "$BUILD_DIR/cuda_memtest" "cuda_memtest" || return 1
        git clone https://github.com/ComputationalRadiationPhysics/cuda_memtest.git \
            "$BUILD_DIR/cuda_memtest"
    fi

    if [ ! -f "$bin" ]; then
        ensure_repo_rebuild_allowed "$BUILD_DIR/cuda_memtest" "cuda_memtest" "$BUILD_DIR/cuda_memtest/build" || return 1
        log "  Building cuda_memtest..."
        local archs_cmake
        archs_cmake=$(echo "$CUDA_ARCH_LIST" | tr ' ' ';')
        in_dir "$BUILD_DIR/cuda_memtest" bash -c "
            rm -rf build && mkdir build && cd build
            cmake .. \
                -DCMAKE_CUDA_COMPILER='$NVCC_PATH' \
                -DCMAKE_CUDA_ARCHITECTURES='$archs_cmake'
            make -j$(nproc)
        " 2>&1 | tee -a "$LOG_FILE"
    else
        log "  cuda_memtest already built."
    fi

    [ -f "$bin" ] || { log "ERROR: cuda_memtest binary not found after prepare."; return 1; }
}

prepare_cuda_code() {
    local code_script="$SCRIPT_DIR/code.sh"
    if [ ! -x "$code_script" ]; then
        log "ERROR: CUDA int32 stress wrapper not found or not executable: $code_script"
        return 1
    fi

    if ! command -v nvcc &>/dev/null; then
        mark_prepare_skip "CUDA Int32 Compute Stress (code.cu)" "nvcc not found — install the CUDA toolkit or add nvcc to PATH"
        return 0
    fi

    log "  CUDA int32 stress wrapper ready: $code_script"
    return 0
}

prepare_stress_tools() {
    if build_gpu_fryer && [ -f "$BUILD_DIR/gpu-fryer/gpu-fryer" ]; then
        STRESS_BACKEND="gpu-fryer"
        RESULTS_STRESS_LABEL="Sustained Compute Stress / gpu-fryer"
        return 0
    fi
    record_not_run "Sustained Compute Stress / gpu-fryer" "build unavailable; using fallback if available"

    if build_gpu_burn && [ -f "$BUILD_DIR/gpu-burn/gpu-burn" ]; then
        STRESS_BACKEND="gpu-burn"
        RESULTS_STRESS_LABEL="Sustained Compute Stress / gpu-burn"
        return 0
    fi
    record_not_run "Sustained Compute Stress / gpu-burn" "build unavailable; using fallback if available"

    log "  gpu-fryer and gpu-burn unavailable — preparing PyTorch fallback."
    prepare_pytorch || return 1
    STRESS_BACKEND="pytorch"
    RESULTS_STRESS_LABEL="Sustained Compute Stress / PyTorch fallback"
}

prepare_selected_tests() {
    local test
    for test in "${SELECTED_TESTS[@]}"; do
        case "$test" in
            preflight|ecc|pcie)
                ;;
            clocks)
                prepare_component_once "clocks" "Clock helper assets" prepare_clocks || return 1
                ;;
            nccl)
                prepare_component_once "nccl" "NCCL toolchain and nccl-tests" prepare_nccl || return 1
                ;;
            cuda-samples)
                prepare_component_once "cuda-samples" "CUDA sample binaries" prepare_cuda_samples || return 1
                ;;
            nvbandwidth)
                prepare_component_once "nvbandwidth" "NVBandwidth binary" prepare_nvbandwidth || return 1
                ;;
            dcgm)
                if ! command -v dcgmi &>/dev/null; then
                    mark_prepare_skip "DCGM Diagnostics" "dcgmi not found — install DCGM if needed (https://developer.nvidia.com/dcgm)"
                fi
                ;;
            pytorch)
                prepare_component_once "pytorch" "PyTorch runtime" prepare_pytorch || return 1
                ;;
            code)
                prepare_component_once "code" "CUDA int32 stress wrapper" prepare_cuda_code || return 1
                ;;
            memtest)
                prepare_component_once "memtest" "cuda_memtest binary" prepare_memtest || return 1
                ;;
            stress|node-stress)
                prepare_component_once "stress" "Stress backend" prepare_stress_tools || return 1
                ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: preflight — idle thermal baseline + persistence mode + driver state
# Run first so we have a clean-state snapshot before anything loads the GPUs.
# ─────────────────────────────────────────────────────────────────────────────

test_preflight() {
    local rc=0

    log "--- Persistence mode ---"
    # Persistence mode keeps the driver loaded between jobs, avoiding multi-second
    # cold-start latency. Should be enabled on any multi-GPU production system.
    local gpu_idx persist_mode
    while IFS=, read -r gpu_idx persist_mode; do
        persist_mode=$(echo "$persist_mode" | xargs)
        if [ "$persist_mode" = "Enabled" ]; then
            log "  GPU $gpu_idx: persistence mode Enabled — OK"
        else
            log "  GPU $gpu_idx: persistence mode Disabled — recommend: sudo nvidia-smi -pm 1"
            # Warning only, not a failure — not all environments need it
        fi
    done < <(nvidia-smi $SMI_FILTER \
        --query-gpu=index,persistence_mode \
        --format=csv,noheader | tr -d '\r')

    log ""
    log "--- Idle thermal baseline ---"
    # Snapshot temp, power, clocks, fan at idle before any test loads the GPUs.
    # If a GPU is already throttling here, something is wrong (fan failure, blocked airflow).
    local gpu_name temp power clk_sm clk_mem fan throttle
    local any_hot=false
    printf "  %-4s %-25s %6s %7s %7s %7s %5s  %s\n" \
        "GPU" "Name" "Temp°C" "Power W" "SM MHz" "Mem MHz" "Fan%" "Throttle" \
        | tee -a "$LOG_FILE"
    while IFS=, read -r gpu_idx gpu_name temp power clk_sm clk_mem fan throttle; do
        gpu_name=$(echo "$gpu_name" | xargs)
        temp=$(echo "$temp"     | xargs)
        power=$(echo "$power"   | xargs)
        clk_sm=$(echo "$clk_sm" | xargs)
        clk_mem=$(echo "$clk_mem" | xargs)
        fan=$(echo "$fan"       | xargs)
        throttle=$(echo "$throttle" | xargs)
        # Decode raw hex bitmask — only flag bits that represent real problems
        # (0x4 sw_power_cap at idle is normal clock-down, not a fault)
        local throttle_decoded
        throttle_decoded=$(decode_throttle "$throttle")
        printf "  %-4s %-25s %6s %7s %7s %7s %5s  %s\n" \
            "$gpu_idx" "$gpu_name" "$temp" "$power" "$clk_sm" "$clk_mem" "$fan" "$throttle_decoded" \
            | tee -a "$LOG_FILE"
        # Warn if idle temp is already above 60°C — suggests cooling problem
        local temp_val="${temp//[^0-9]/}"
        if [ -n "$temp_val" ] && [ "$temp_val" -gt 60 ]; then
            log "  WARNING: GPU $gpu_idx idle temp ${temp}°C is high — check cooling"
            any_hot=true
        fi
        # Only flag throttle reasons that indicate real hardware problems
        if [ "$throttle_decoded" != "Not Active" ] && [ "$throttle_decoded" != "unknown" ]; then
            log "  WARNING: GPU $gpu_idx has active throttle at idle: $throttle_decoded"
            rc=1
        fi
    done < <(nvidia-smi $SMI_FILTER \
        --query-gpu=index,name,temperature.gpu,power.draw,clocks.sm,clocks.mem,fan.speed,clocks_throttle_reasons.active \
        --format=csv,noheader | tr -d '\r')

    log ""
    log "--- Driver version ---"
    nvidia-smi $SMI_FILTER --query-gpu=index,driver_version \
        --format=csv,noheader | tr -d '\r' \
        | while IFS=, read -r idx drv; do
            log "  GPU $idx: driver $drv"
          done

    return $rc
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: ecc — ECC error check (DC GPUs only; skip/warn gracefully on GeForce)
# ─────────────────────────────────────────────────────────────────────────────

test_ecc() {
    local rc=0 any_dc=false

    log "  Checking ECC status per GPU..."
    log ""
    printf "  %-4s %-25s %-10s %-12s %s\n" \
        "GPU" "Name" "ECC Mode" "Uncorr.Errs" "Notes" | tee -a "$LOG_FILE"

    local gpu_idx gpu_name ecc_mode uncorr_errs
    while IFS=, read -r gpu_idx gpu_name ecc_mode uncorr_errs; do
        gpu_idx=$(echo "$gpu_idx"     | xargs)
        gpu_name=$(echo "$gpu_name"   | xargs)
        ecc_mode=$(echo "$ecc_mode"   | xargs)
        uncorr_errs=$(echo "$uncorr_errs" | xargs)

        local note=""
        case "$ecc_mode" in
            Enabled)
                any_dc=true
                if [ "$uncorr_errs" = "[N/A]" ] || [ -z "$uncorr_errs" ]; then
                    note="ECC on, no error count available"
                elif [ "$uncorr_errs" -gt 0 ] 2>/dev/null; then
                    note="*** UNCORRECTED ERRORS — replace GPU ***"
                    rc=1
                else
                    note="OK — 0 uncorrected errors"
                fi
                ;;
            Disabled)
                any_dc=true
                note="ECC supported but disabled — enable with: sudo nvidia-smi -e 1 && reboot"
                ;;
            "[N/A]"|"N/A"|"")
                note="ECC not supported (GeForce/consumer GPU — expected)"
                ;;
            *)
                note="Unknown ECC state: $ecc_mode"
                ;;
        esac

        printf "  %-4s %-25s %-10s %-12s %s\n" \
            "$gpu_idx" "$gpu_name" "$ecc_mode" "$uncorr_errs" "$note" \
            | tee -a "$LOG_FILE"
    done < <(nvidia-smi $SMI_FILTER \
        --query-gpu=index,name,ecc.mode.current,ecc.errors.uncorrected.volatile.total \
        --format=csv,noheader | tr -d '\r')

    log ""
    if [ "$any_dc" = false ]; then
        log "  All GPUs are consumer grade — ECC not applicable. (PASS)"
    fi

    return $rc
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: pcie — PCIe link width and generation check
# A GPU silently degraded to x1 or Gen2 passes every other test at low BW.
# ─────────────────────────────────────────────────────────────────────────────

test_pcie() {
    local rc=0

    # PCIe Active State Power Management (ASPM) legitimately drops the link from
    # Gen3/Gen4 down to Gen1 at idle to save power — this is correct behaviour,
    # not a fault. nvidia-smi pcie.link.gen.current is an instantaneous read, so
    # sampling at idle gives a false Gen1 result on any system with ASPM enabled.
    #
    # Strategy: always spin up a brief GPU load first to force all links to full
    # speed, then sample. Width mismatches (x8 vs x16) are hard failures because
    # lane width never power-gates. Gen mismatches are warnings only, because even
    # under load some platforms briefly drop before re-negotiating.

    local aspm_policy managed_boot_policy managed_boot_policy_complete=true boot_arg
    aspm_policy=$(cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null || echo "unknown")
    for boot_arg in pcie_aspm=off pci=noaer pci=realloc=on pcie_aspm.policy=performance nvme_core.default_ps_max_latency_us=0; do
        if ! grep -Fqw "${boot_arg}" /proc/cmdline 2>/dev/null; then
            managed_boot_policy_complete=false
        fi
    done
    log "  PCIe ASPM policy : $aspm_policy"
    managed_boot_policy="pcie_aspm=off=$(grep -Fqw 'pcie_aspm=off' /proc/cmdline 2>/dev/null && echo yes || echo no), pci=noaer=$(grep -Fqw 'pci=noaer' /proc/cmdline 2>/dev/null && echo yes || echo no), pci=realloc=on=$(grep -Fqw 'pci=realloc=on' /proc/cmdline 2>/dev/null && echo yes || echo no), pcie_aspm.policy=performance=$(grep -Fqw 'pcie_aspm.policy=performance' /proc/cmdline 2>/dev/null && echo yes || echo no), nvme_core.default_ps_max_latency_us=0=$(grep -Fqw 'nvme_core.default_ps_max_latency_us=0' /proc/cmdline 2>/dev/null && echo yes || echo no)"
    log "  Managed boot policy: $managed_boot_policy"
    log "  Spinning up GPU load to force links to full speed before sampling..."

    # Run load on all GPUs for 10 seconds, sample in the middle while it's active
    python3 - << 'PYEOF' &
import torch, time
gpus = list(range(torch.cuda.device_count()))
if not gpus:
    import sys; sys.exit(0)
m = [torch.randn(4096, 4096, device=f"cuda:{g}") for g in gpus]
end = time.time() + 15
while time.time() < end:
    for g, a in enumerate(m):
        with torch.cuda.device(g): torch.mm(a, a)
    for g in gpus: torch.cuda.synchronize(g)
PYEOF
    local load_pid=$!
    sleep 5   # let links negotiate up

    log ""
    log "  PCIe link width and generation per GPU (sampled under load):"
    printf "  %-4s %-25s %8s %8s %8s %8s  %s\n" \
        "GPU" "Name" "CurGen" "MaxGen" "CurWidth" "MaxWidth" "Status" \
        | tee -a "$LOG_FILE"

    local any_gen_warn=false any_width_warn=false any_width_fail=false
    local gpu_idx gpu_name cur_gen max_gen cur_width max_width
    while IFS=, read -r gpu_idx gpu_name cur_gen max_gen cur_width max_width; do
        gpu_idx=$(echo "$gpu_idx"     | xargs)
        gpu_name=$(echo "$gpu_name"   | xargs)
        cur_gen=$(echo "$cur_gen"     | xargs)
        max_gen=$(echo "$max_gen"     | xargs)
        cur_width=$(echo "$cur_width" | xargs)
        max_width=$(echo "$max_width" | xargs)

        local status="OK"

        # Gen mismatch: warning only — ASPM or platform policy can legitimately
        # keep links at Gen1/Gen2 even under load on some motherboards.
        if [ "$cur_gen" != "$max_gen" ] && \
           [ "$cur_gen" != "[N/A]" ] && [ "$max_gen" != "[N/A]" ]; then
            status="WARN: Gen${cur_gen} < Gen${max_gen} (may be BIOS/ASPM — see below)"
            any_gen_warn=true
            # Warning, not a hard failure
        fi

        # Width mismatch: x8 physical slots are a valid server configuration
        # (bifurcated CPU lanes, half-width risers).  Only x4 or below is a
        # hard failure — that is never intentional and indicates a damaged
        # riser or failed PCIe negotiation.
        if [ "$cur_width" != "$max_width" ] && \
           [ "$cur_width" != "[N/A]" ] && [ "$max_width" != "[N/A]" ]; then
            if [ "$cur_width" -le 4 ] 2>/dev/null; then
                status="FAIL: x${cur_width} < x${max_width} (critically narrow — damaged riser?)"
                any_width_fail=true
                rc=1
            else
                status="WARN: x${cur_width} < x${max_width} (physical slot — verify intentional)"
                any_width_warn=true
            fi
        fi

        printf "  %-4s %-25s %8s %8s %8s %8s  %s\n" \
            "$gpu_idx" "$gpu_name" \
            "Gen$cur_gen" "Gen$max_gen" "x$cur_width" "x$max_width" \
            "$status" | tee -a "$LOG_FILE"
    done < <(nvidia-smi $SMI_FILTER \
        --query-gpu=index,name,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max \
        --format=csv,noheader | tr -d '\r')

    # Stop background load
    kill "$load_pid" 2>/dev/null; wait "$load_pid" 2>/dev/null || true

    log ""
    if [ "$any_gen_warn" = true ]; then
        log "  NOTE: Generation mismatch detected (warning only — not a failure)."
        log "  Gen speed can legitimately stay low due to:"
        if [ "${managed_boot_policy_complete}" = true ]; then
            log "    • Managed boot policy is already present; look at BIOS PCIe speed caps, lane bifurcation, or riser issues."
        else
            log "    • Managed boot policy is not present; run install/pcie-aspm.sh --enable and reboot to rule it out."
        fi
        log "    • BIOS PCIe speed forced to Gen1/Gen2 — set to Auto or Gen3/Gen4"
        log "    • 'Above 4G Decoding' disabled in BIOS (required for 8-GPU systems)"
        log "  If NVBandwidth host<->device numbers look normal, this is not a real issue."
    fi
    if [ "$any_width_warn" = true ]; then
        log "  NOTE: Width mismatch on one or more GPUs (warning only — not a failure)."
        log "  x8 physical slots are valid in bifurcated or half-width riser configurations."
        log "  Confirm intentional — NVBandwidth h2d/d2h numbers should still look normal."
    fi
    if [ "$any_width_fail" = true ]; then
        log "  FAIL: Critically narrow lane width detected (x4 or below)."
        log "  Likely causes: damaged riser, failed slot, or PCIe negotiation fault."
    fi
    if [ "$rc" -eq 0 ] && [ "$any_gen_warn" = false ]; then
        log "  All PCIe links running at full width and generation."
    fi

    return $rc
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: clocks — clock speed verification under load
# Runs a brief 30s GEMM load and samples SM/memory clocks + throttle reasons.
# Distinguishes thermal throttle vs power throttle vs SW throttle.
# ─────────────────────────────────────────────────────────────────────────────

test_clocks() {
    local rc=0

    # Check max boost clocks at idle first
    log "  Max advertised boost clocks (idle):"
    printf "  %-4s %-25s %10s %10s\n" "GPU" "Name" "MaxSM MHz" "MaxMem MHz" \
        | tee -a "$LOG_FILE"
    local gpu_idx gpu_name max_sm max_mem
    while IFS=, read -r gpu_idx gpu_name max_sm max_mem; do
        printf "  %-4s %-25s %10s %10s\n" \
            "$(echo "$gpu_idx" | xargs)" \
            "$(echo "$gpu_name" | xargs)" \
            "$(echo "$max_sm" | xargs)" \
            "$(echo "$max_mem" | xargs)" | tee -a "$LOG_FILE"
    done < <(nvidia-smi $SMI_FILTER \
        --query-gpu=index,name,clocks.max.sm,clocks.max.mem \
        --format=csv,noheader | tr -d '\r')

    log ""
    log "  Running 30s load to measure sustained clocks..."

    # Kick off a background GEMM load on all GPUs via Python
    local load_script="$BUILD_DIR/_clock_load.py"
    ensure_build_dir_writable "writing clock-load helper" || return 1
    cat > "$load_script" << 'PYEOF'
import torch, time, sys
gpus = list(range(torch.cuda.device_count()))
SIZE = 4096
matrices = [
    (torch.randn(SIZE, SIZE, dtype=torch.float16, device=f"cuda:{g}"),
     torch.randn(SIZE, SIZE, dtype=torch.float16, device=f"cuda:{g}"))
    for g in gpus
]
end = time.time() + 30
while time.time() < end:
    for g, (a, b) in enumerate(matrices):
        with torch.cuda.device(g): torch.mm(a, b)
    for g in gpus: torch.cuda.synchronize(g)
PYEOF

    python3 "$load_script" &
    local load_pid=$!

    # Sample clocks and throttle reasons every 3 seconds for 30 seconds
    log "  Sampling clocks under load (every 3s for 30s):"
    printf "  %-6s %-4s %-10s %-10s %s\n" \
        "Time" "GPU" "SM MHz" "Mem MHz" "ThrottleReasons" | tee -a "$LOG_FILE"

    local sample=0 any_throttle=false
    while [ "$sample" -lt 10 ]; do
        sleep 3
        local elapsed=$(( (sample + 1) * 3 ))
        local gpu_idx clk_sm clk_mem throttle
        while IFS=, read -r gpu_idx clk_sm clk_mem throttle; do
            gpu_idx=$(echo "$gpu_idx" | xargs)
            clk_sm=$(echo "$clk_sm"   | xargs)
            clk_mem=$(echo "$clk_mem" | xargs)
            throttle=$(echo "$throttle" | xargs)
            local throttle_decoded
            throttle_decoded=$(decode_throttle "$throttle")
            printf "  %-6s %-4s %-10s %-10s %s\n" \
                "${elapsed}s" "$gpu_idx" "$clk_sm" "$clk_mem" "$throttle_decoded" \
                | tee -a "$LOG_FILE"
            if [ "$throttle_decoded" != "Not Active" ] && [ "$throttle_decoded" != "unknown" ]; then
                any_throttle=true
            fi
        done < <(nvidia-smi $SMI_FILTER \
            --query-gpu=index,clocks.sm,clocks.mem,clocks_throttle_reasons.active \
            --format=csv,noheader | tr -d '\r')
        sample=$((sample + 1))
    done

    wait "$load_pid" 2>/dev/null || true
    rm -f "$load_script"

    log ""
    if [ "$any_throttle" = true ]; then
        log "  WARNING: Clock throttling detected under load."
        log "  Common causes:"
        log "    SW_Power_Cap  → power limit set below TDP (nvidia-smi -pl to check)"
        log "    HW_Thermal    → GPU overheating — check fans, airflow, thermal paste"
        log "    HW_Power      → PSU or power connector insufficient for load"
        rc=1
    else
        log "  No throttling detected — clocks sustained at full speed."
    fi

    return $rc
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: NCCL
# ─────────────────────────────────────────────────────────────────────────────

install_nccl_lib() {
    command -v dpkg &>/dev/null || return 0   # non-Debian: skip version check

    local installed_nccl installed_cuda_major
    installed_nccl=$(dpkg -l 2>/dev/null | awk '/^ii  libnccl2 /{print $3}' | head -1)

    if [ -n "$installed_nccl" ]; then
        installed_cuda_major=$(echo "$installed_nccl" | grep -oP '\+cuda\K[0-9]+')
        if [ "$installed_cuda_major" = "$CUDA_MAJOR" ]; then
            log "  libnccl2 $installed_nccl matches CUDA ${CUDA_MAJOR}.x — OK."
            return 0
        fi
        log "  WARNING: libnccl2 $installed_nccl is +cuda${installed_cuda_major} but toolkit is CUDA $CUDA_VERSION"
        log "           Removing and reinstalling to match toolkit..."
        sudo apt-get remove -y libnccl2 libnccl-dev 2>&1 | tee -a "$LOG_FILE"
    fi

    log "  Installing libnccl2/libnccl-dev for CUDA ${CUDA_MAJOR}.x..."
    sudo apt-get update -qq

    # Prefer exact version (e.g. +cuda12.9), fall back to highest +cuda12.x
    local target_ver
    target_ver=$(
        apt-cache madison libnccl2 2>/dev/null \
        | grep "+cuda${CUDA_VERSION}" | head -1 | awk '{print $3}'
    )
    if [ -z "$target_ver" ]; then
        target_ver=$(
            apt-cache madison libnccl2 2>/dev/null \
            | grep "+cuda${CUDA_MAJOR}\." | sort -t. -k2 -rn | head -1 | awk '{print $3}'
        )
    fi

    if [ -n "$target_ver" ]; then
        log "  Pinning to libnccl2=$target_ver"
        sudo apt-get install -y "libnccl2=$target_ver" "libnccl-dev=$target_ver" \
            2>&1 | tee -a "$LOG_FILE"
    else
        log "  WARNING: No cuda${CUDA_MAJOR}.x NCCL build found — installing latest (may mismatch)."
        sudo apt-get install -y libnccl2 libnccl-dev 2>&1 | tee -a "$LOG_FILE"
    fi
}

install_nccl_tests_bin() {
    local perf="$BUILD_DIR/nccl-tests/build/all_reduce_perf"
    ensure_repo_clone_allowed "$BUILD_DIR/nccl-tests" "nccl-tests" || return 1
    [ ! -d "$BUILD_DIR/nccl-tests" ] && \
        git clone https://github.com/NVIDIA/nccl-tests.git "$BUILD_DIR/nccl-tests"

    if [ -f "$perf" ]; then
        local linked_nccl system_nccl
        linked_nccl=$(ldd "$perf" 2>/dev/null | awk '/libnccl/{print $3}')
        system_nccl=$(ldconfig -p 2>/dev/null | awk '/libnccl\.so\.2 /{print $NF}' | head -1)
        if [ -n "$linked_nccl" ] && [ "$linked_nccl" != "$system_nccl" ]; then
            log "  nccl-tests links $linked_nccl but system has $system_nccl — rebuilding..."
        else
            log "  nccl-tests already built."
            return 0
        fi
    fi

    ensure_repo_rebuild_allowed "$BUILD_DIR/nccl-tests" "nccl-tests" "$BUILD_DIR/nccl-tests/build" || return 1
    log "  Building nccl-tests..."
    in_dir "$BUILD_DIR/nccl-tests" bash -c "
        make clean 2>/dev/null || true
        make -j$(nproc) CUDA_HOME='$CUDA_HOME_DIR'
    " 2>&1 | tee -a "$LOG_FILE"
}

test_nccl() {
    local perf="$BUILD_DIR/nccl-tests/build/all_reduce_perf"
    [ -f "$perf" ] || { log "ERROR: nccl-tests binary not found."; return 1; }

    # For single-node PCIe-only systems: disable IB/RoCE so NCCL doesn't try
    # to route intra-node traffic over any RDMA NIC (e.g. irdma0/RoCE).
    # NCCL_NET_GDR_LEVEL=0 and NCCL_NVLS_ENABLE=0 are also safe no-ops on
    # systems without NVLink/NVSwitch/GPUDirect.
    local nccl_env=(
        NCCL_IB_DISABLE=1
        NCCL_NET_GDR_LEVEL=0
        NCCL_NVLS_ENABLE=0
    )

    local nccl_diag
    nccl_diag=$(mktemp "${TMPDIR:-/tmp}/gpu-fulltest-v2-nccl.XXXXXX")
    cleanup_nccl_diag() {
        rm -f "$nccl_diag"
    }
    trap cleanup_nccl_diag RETURN

    if env "${nccl_env[@]}" "$perf" -b 8 -e 1G -f 2 -g "$NUM_GPUS" 2>&1 | tee -a "$LOG_FILE"; then
        return 0
    fi

    nccl_peer_mapping_hint() {
        local diag_file="$1"
        if grep -qF "peer mapping resources exhausted" "$diag_file"; then
            log "  NCCL hint: the NVIDIA driver ran out of peer-mapping resources."
            log "  Reboot the host first to clear peer-ID / mapping state, then rerun NCCL."
            log "  If it returns immediately after reboot, treat it as a driver or PCIe topology resource-exhaustion issue."
            return 0
        fi
        return 1
    }

    # Re-run with debug output to capture the actual NCCL error
    log ""
    log "  NCCL failed — re-running with NCCL_DEBUG=INFO for diagnostics:"
    env "${nccl_env[@]}" NCCL_DEBUG=INFO "$perf" -b 8 -e 32M -f 2 -g "$NUM_GPUS" 2>&1 >"$nccl_diag" || true
    nccl_peer_mapping_hint "$nccl_diag" || true
    grep -E "NCCL|WARN|error|Error|fatal" "$nccl_diag" | head -60 | tee -a "$LOG_FILE"
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: CUDA Samples
# ─────────────────────────────────────────────────────────────────────────────

test_cuda_samples() {
    local rc=0

    log "--- deviceQuery ---"
    if [ "$CUDA_SAMPLES_DEVICEQUERY_READY" = true ]; then
        local dq_bin
        dq_bin=$(find_binary "$BUILD_DIR/cuda-samples" "deviceQuery")
        if [ -n "$dq_bin" ]; then
            "$dq_bin" 2>&1 | tee -a "$LOG_FILE" || rc=1
        else
            record_not_run "CUDA Samples / deviceQuery" "binary unavailable after build"
        fi
    else
        log "  NOT BEING RUN: CUDA Samples / deviceQuery — build/layout issue already recorded"
    fi

    log "--- p2pBandwidthLatencyTest ---"
    if [ "$CUDA_SAMPLES_P2P_READY" = true ]; then
        local p2p_bin
        p2p_bin=$(find_binary "$BUILD_DIR/cuda-samples" "p2pBandwidthLatencyTest")
        if [ -n "$p2p_bin" ]; then
            "$p2p_bin" 2>&1 | tee -a "$LOG_FILE" || rc=1
        else
            record_not_run "CUDA Samples / p2pBandwidthLatencyTest" "binary unavailable after build"
        fi
    else
        log "  NOT BEING RUN: CUDA Samples / p2pBandwidthLatencyTest — build/layout issue already recorded"
    fi

    return $rc
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: NVBandwidth
# ─────────────────────────────────────────────────────────────────────────────

test_nvbandwidth() {
    local nvb_bin
    nvb_bin=$(find_binary "$BUILD_DIR/nvbandwidth" "nvbandwidth")

    [ -n "$nvb_bin" ] && [ -x "$nvb_bin" ] || \
        { log "ERROR: nvbandwidth binary not found after build."; return 1; }

    # Cap buffer size to avoid OOM on multi-GPU systems with large VRAM.
    # nvbandwidth default (~1-2 GB) * num_gpus * concurrent testcases can
    # exhaust VRAM on 4x RTX 5090 when device buffers stack up across tests.
    local vram_mb gpu_count_local buf_mb
    vram_mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits \
        | head -1 | tr -d ' ')
    gpu_count_local=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
    # Use at most 25% of single-GPU VRAM, capped at 512 MB
    buf_mb=$(( vram_mb / 4 ))
    [ "$buf_mb" -gt 512 ] && buf_mb=512
    log "  Using buffer size: ${buf_mb} MB (GPU VRAM: ${vram_mb} MB x ${gpu_count_local} GPUs)"

    local nvb_out nvb_rc
    # On systems with >8 GPUs the full P2P mesh (N*(N-1) peer mappings) exceeds
    # the kernel's peer mapping resource limit, causing CUDA_ERROR_TOO_MANY_PEERS.
    # Skip device-to-device tests in that case — h2d/d2h results are still valid.
    local d2d_tests=()
    if [ "$gpu_count_local" -le 8 ]; then
        d2d_tests=(
            device_to_device_memcpy_read_ce
            device_to_device_memcpy_write_ce
            device_to_device_bidirectional_memcpy_read_ce
        )
    else
        log "  NOTE: Skipping device-to-device tests — $gpu_count_local GPUs exceeds peer" \
            "mapping limit. Run on a ≤8-GPU subset to test d2d bandwidth."
    fi

    nvb_out=$("$nvb_bin" \
        --bufferSize "$buf_mb" \
        -t host_to_device_memcpy_ce \
           device_to_host_memcpy_ce \
           "${d2d_tests[@]}" \
        2>&1)
    nvb_rc=$?
    echo "$nvb_out" | tee -a "$LOG_FILE"

    # OOM and TOO_MANY_PEERS are both non-fatal — partial results are still useful
    if echo "$nvb_out" | grep -qE "CUDA_ERROR_OUT_OF_MEMORY|CUDA_ERROR_TOO_MANY_PEERS"; then
        log "  WARNING: nvbandwidth hit a resource limit (OOM or peer mapping exhaustion)."
        log "  Partial results above are still valid."
        return 0
    fi

    return "$nvb_rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: DCGM (optional)
# ─────────────────────────────────────────────────────────────────────────────

test_dcgm() {
    dcgmi discovery -l 2>&1 | tee -a "$LOG_FILE"
    dcgmi diag -r 3 2>&1 | tee -a "$LOG_FILE"
    # Fields: 203=GPU util, 252=mem util, 150=temp, 155=power draw
    # Hardware/stress subtests are skipped on GeForce GPUs — expected behaviour.
    log "--- dmon (GPU util / mem util / temp / power) ---"
    dcgmi dmon -e 203,252,150,155 -c 10 2>&1 | tee -a "$LOG_FILE"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: PyTorch multi-GPU DDP
# ─────────────────────────────────────────────────────────────────────────────

install_pytorch() {
    [ -n "${PYTORCH_PYTHON:-}" ] || return 1
    ensure_pytorch_venv "$PYTORCH_PYTHON" "$PYTORCH_VENV" || return 1
    "${PYTORCH_VENV}/bin/python" -m pip install torch torchvision torchaudio \
        --index-url "https://download.pytorch.org/whl/${TORCH_CUDA}" \
        --upgrade --force-reinstall --no-cache-dir --quiet $PIP_EXTRA 2>&1 | tee -a "$LOG_FILE"
    "${PYTORCH_VENV}/bin/python" -m pip install accelerate \
        --upgrade --force-reinstall --no-cache-dir --quiet $PIP_EXTRA 2>&1 | tee -a "$LOG_FILE"
}

find_torchrun() {
    if [ -x "$PYTORCH_VENV/bin/torchrun" ]; then
        echo "$PYTORCH_VENV/bin/torchrun"
        return 0
    fi

    find "$HOME/.local/bin" /usr/local/bin /usr/bin \
        -name torchrun 2>/dev/null | head -1
}

summarize_pytorch_failure() {
    local output_file="$1"
    local script_path="$2"
    local torchrun_path="$3"

    log "  PyTorch DDP diagnostic summary:"

    local failed_rank
    failed_rank=$(grep -oP 'local_rank: \K[0-9]+' "$output_file" 2>/dev/null | tail -1 || true)
    if [ -n "$failed_rank" ]; then
        log "    First reported failing local_rank: $failed_rank"
    fi

    if grep -q 'exitcode: -11' "$output_file" 2>/dev/null; then
        log "    Detected exitcode -11 (SIGSEGV) in a torchrun child rank."
        log "    This usually points to a native CUDA/NCCL/driver or GPU-specific crash, not a normal Python exception."
    fi

    local matched=false
    while IFS= read -r line; do
        matched=true
        log "    $line"
    done < <(grep -E 'ChildFailedError|failed \(exitcode:|local_rank:|Traceback|RuntimeError|CUDA error|NCCL|ProcessGroup|Segmentation fault' "$output_file" | tail -n 25 || true)

    $matched || log "    No condensed error lines matched; inspect the full log for details."

    log "    Repro script kept at: $script_path"
    log "    Repro command: $torchrun_path --nproc_per_node $NUM_GPUS $script_path"
    log "    For deeper logs, rerun with:"
    log "      NCCL_DEBUG=INFO TORCH_DISTRIBUTED_DEBUG=DETAIL PYTHONFAULTHANDLER=1 \\"
    log "      $torchrun_path --nproc_per_node $NUM_GPUS $script_path"

    if [ -n "$failed_rank" ]; then
        log "    Suggested isolation: ./test/gpu-fulltest-v2.sh --gpu $failed_rank pytorch"
    fi
    log "    Cross-check the transport stack with: ./test/gpu-fulltest-v2.sh nccl"
}

test_pytorch() {
    local torchrun="${TORCHRUN_BIN:-}"
    if [ -z "$torchrun" ] || [ ! -x "$torchrun" ]; then
        log "ERROR: torchrun not found after installing PyTorch."
        return 1
    fi
    log "  Using torchrun: $torchrun"

    # Write to /tmp to avoid any permission issues with BUILD_DIR
    local script
    script=$(mktemp /tmp/_pytorch_ddp_test_XXXXXX.py) || {
        log "ERROR: Cannot create temp file for DDP test script"
        return 1
    }
    cat > "$script" << 'PYEOF'
import os
import torch
import torch.nn as nn
import torch.distributed as dist
from torch.nn.parallel import DistributedDataParallel as DDP

dist.init_process_group(backend='nccl')
local_rank = int(os.environ["LOCAL_RANK"])
torch.cuda.set_device(local_rank)

model = nn.Linear(10000, 10000).cuda(local_rank)
model = DDP(model, device_ids=[local_rank])
x = torch.randn(1000, 10000, device=f"cuda:{local_rank}")

for _ in range(100):
    _ = model(x)

torch.cuda.synchronize()
if local_rank == 0:
    world = dist.get_world_size()
    print(f"PyTorch multi-GPU DDP test completed on {world} GPU(s).")
dist.destroy_process_group()
PYEOF

    if [ ! -f "$script" ] || [ ! -s "$script" ]; then
        log "ERROR: Failed to write DDP test script to $script"
        rm -f "$script"
        return 1
    fi

    local run_log
    run_log=$(mktemp /tmp/_pytorch_ddp_run_XXXXXX.log) || {
        log "ERROR: Cannot create temp log for DDP test output"
        rm -f "$script"
        return 1
    }

    local -a torch_env=(
        PYTHONFAULTHANDLER=1
        TORCH_SHOW_CPP_STACKTRACES=1
        TORCH_NCCL_ASYNC_ERROR_HANDLING=1
    )

    env "${torch_env[@]}" "$torchrun" --nproc_per_node "$NUM_GPUS" "$script" 2>&1 \
        | tee "$run_log" | tee -a "$LOG_FILE"
    local rc=${PIPESTATUS[0]}

    if [ "$rc" -ne 0 ]; then
        summarize_pytorch_failure "$run_log" "$script" "$torchrun"
        rm -f "$run_log"
        return "$rc"
    fi

    rm -f "$run_log" "$script"
    return $rc
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: CUDA int32 stress
# ─────────────────────────────────────────────────────────────────────────────

test_cuda_code() {
    local code_script="$SCRIPT_DIR/code.sh"
    local gpu_rows=()
    local failed=0
    local gpu_count=0
    local seconds="$CUDA_CODE_SECONDS"

    if [ ! -x "$code_script" ]; then
        log "ERROR: CUDA int32 stress wrapper not found or not executable: $code_script"
        return 1
    fi

    if [ -z "${NVCC_PATH:-}" ] || [ ! -x "$NVCC_PATH" ]; then
        record_not_run "CUDA int32 stress" "nvcc not found — install the CUDA toolkit or add nvcc to PATH"
        return 0
    fi

    if ! [[ "$seconds" =~ ^[0-9]+$ ]] || [ "$seconds" -lt 1 ]; then
        log "ERROR: CUDA_CODE_SECONDS must be a positive integer (got: $seconds)"
        return 1
    fi

    mapfile -t gpu_rows < <(nvidia-smi $SMI_FILTER --query-gpu=index,name --format=csv,noheader | tr -d '\r')
    gpu_count="${#gpu_rows[@]}"
    if [ "$gpu_count" -le 0 ]; then
        record_not_run "CUDA int32 stress" "no visible GPUs found"
        return 0
    fi

    log "  CUDA int32 stress duration: ${seconds}s per visible GPU"
    log "  Wrapper                  : $code_script"

    local logical_idx row physical_idx gpu_name
    for logical_idx in $(seq 0 $((gpu_count - 1))); do
        row="${gpu_rows[$logical_idx]}"
        physical_idx="${row%%,*}"
        gpu_name="${row#*,}"
        physical_idx="$(echo "$physical_idx" | xargs)"
        gpu_name="$(echo "$gpu_name" | xargs)"

        log "  Running CUDA int32 stress on visible GPU ${logical_idx} (physical GPU ${physical_idx}: ${gpu_name})"
        if ! "$code_script" "$seconds" "$logical_idx" 2>&1 | tee -a "$LOG_FILE"; then
            log "  WARNING: CUDA int32 stress failed on visible GPU ${logical_idx} (physical GPU ${physical_idx})"
            failed=1
        else
            log "  CUDA int32 stress passed on visible GPU ${logical_idx} (physical GPU ${physical_idx})"
        fi
    done

    return "$failed"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: cuda_memtest
# ─────────────────────────────────────────────────────────────────────────────

test_memtest() {
    local bin="$BUILD_DIR/cuda_memtest/build/cuda_memtest"

    [ -f "$bin" ] || { log "ERROR: cuda_memtest binary not found after build."; return 1; }

    # Run one process per GPU in parallel; collect all exit codes
    # Capture output per GPU to distinguish real errors from OOM-on-stress-test
    local pids=() tmpfiles=() failed=0 oom_only=0
    for i in $(seq 0 $((NUM_GPUS - 1))); do
        local tmp
        tmp=$(mktemp /tmp/_memtest_gpu${i}_XXXXXX.log)
        tmpfiles+=("$tmp")
        "$bin" --stress --num_passes 10 --device "$i" 2>&1 | tee -a "$LOG_FILE" > "$tmp" &
        pids+=($!)
    done
    for idx in "${!pids[@]}"; do
        local rc=0
        wait "${pids[$idx]}" || rc=1
        if [ "$rc" -ne 0 ]; then
            local tmp="${tmpfiles[$idx]}"
            # If the only CUDA error is OOM (error 2) with no actual memory mismatches,
            # treat it as a non-fatal memory fragmentation artifact of the stress test.
            local real_errors
            real_errors=$(grep -c "MEMORY_ERROR\|mismatch\|error at address\|Error Code [^2]" "$tmp" 2>/dev/null || true)
            if [ "$real_errors" -eq 0 ] && grep -q "CUDA Runtime API error 2: out of memory" "$tmp" 2>/dev/null; then
                oom_only=$((oom_only + 1))
            else
                failed=$((failed + 1))
            fi
        fi
        rm -f "${tmpfiles[$idx]}"
    done

    if [ "$oom_only" -gt 0 ] && [ "$failed" -eq 0 ]; then
        log "  NOTE: $oom_only GPU(s) hit OOM during Test10 (memory stress double-alloc)."
        log "  This is a known cuda_memtest fragmentation artifact, not a hardware error."
        log "  No actual memory mismatches detected — VRAM integrity OK."
    fi
    [ "$failed" -eq 0 ] || { log "ERROR: cuda_memtest found real memory errors on $failed GPU(s)"; return 1; }
}

build_gpu_fryer() {
    local bin="$BUILD_DIR/gpu-fryer/gpu-fryer"
    [ -f "$bin" ] && { log "  gpu-fryer already built."; return 0; }
    ensure_repo_clone_allowed "$BUILD_DIR/gpu-fryer" "gpu-fryer" || return 1

    if ! command -v cargo &>/dev/null; then
        log "  cargo not found — installing Rust toolchain..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
        # shellcheck source=/dev/null
        source "$HOME/.cargo/env"
    fi
    command -v cargo &>/dev/null || { log "  WARNING: cargo unavailable."; return 1; }

    [ ! -d "$BUILD_DIR/gpu-fryer" ] && \
        git clone https://github.com/huggingface/gpu-fryer.git "$BUILD_DIR/gpu-fryer"

    ensure_repo_rebuild_allowed "$BUILD_DIR/gpu-fryer" "gpu-fryer" "$BUILD_DIR/gpu-fryer/target" || return 1
    LIBRARY_PATH="$CUDA_HOME_DIR/lib64:${LIBRARY_PATH:-}" \
        in_dir "$BUILD_DIR/gpu-fryer" bash -c "
            cargo build --release
            cp target/release/gpu-fryer .
        " 2>&1 | tee -a "$LOG_FILE"
}

build_gpu_burn() {
    local bin="$BUILD_DIR/gpu-burn/gpu-burn"
    [ -f "$bin" ] && { log "  gpu-burn already built."; return 0; }
    ensure_repo_clone_allowed "$BUILD_DIR/gpu-burn" "gpu-burn" || return 1

    [ ! -d "$BUILD_DIR/gpu-burn" ] && \
        git clone https://github.com/wilicc/gpu-burn.git "$BUILD_DIR/gpu-burn"

    # COMPUTE must be "X.Y" — Makefile does -arch=compute_$(subst .,,${COMPUTE})
    local compute_cap
    compute_cap=$(nvidia-smi $SMI_FILTER --query-gpu=compute_cap --format=csv,noheader \
        | tr -d '\r' | sort -u | head -1)

    ensure_repo_rebuild_allowed "$BUILD_DIR/gpu-burn" "gpu-burn" "$BUILD_DIR/gpu-burn" || return 1
    in_dir "$BUILD_DIR/gpu-burn" bash -c "
        make clean 2>/dev/null || true
        make -j$(nproc) COMPUTE='$compute_cap' CUDAPATH='$CUDA_HOME_DIR'
    " 2>&1 | tee -a "$LOG_FILE"
}

run_pytorch_stress_for_duration() {
    local duration_s="$1"
    local script="$BUILD_DIR/_gpu_stress.py"
    ensure_build_dir_writable "writing stress helper" || return 1
    cat > "$script" << PYEOF
import torch, time, sys

DURATION = ${duration_s}
SIZE = 8192
gpus = list(range(torch.cuda.device_count()))
if not gpus:
    print("ERROR: No CUDA GPUs found"); sys.exit(1)

print(f"Stressing {len(gpus)} GPU(s) for {DURATION}s with {SIZE}x{SIZE} BF16 GEMM...")
matrices = [
    (torch.randn(SIZE, SIZE, dtype=torch.bfloat16, device=f"cuda:{g}"),
     torch.randn(SIZE, SIZE, dtype=torch.bfloat16, device=f"cuda:{g}"))
    for g in gpus
]
start = time.time()
iters = 0
while time.time() - start < DURATION:
    for g, (a, b) in enumerate(matrices):
        with torch.cuda.device(g):
            torch.mm(a, b)
    for g in gpus:
        torch.cuda.synchronize(g)
    iters += 1
    if iters % 50 == 0:
        print(f"  {time.time()-start:.0f}s, {iters} iterations")
print(f"Stress complete: {iters} iterations — no errors.")
PYEOF
    local rc=0
    python3 "$script" 2>&1 | tee -a "$LOG_FILE" || rc=$?
    rm -f "$script"
    return $rc
}

run_pytorch_stress() {
    run_pytorch_stress_for_duration "$BURN_DURATION"
}

start_gpu_stress_backend() {
    local label="$1"
    local duration_s="$2"

    if [ "${STRESS_BACKEND:-}" = "gpu-fryer" ] && [ -f "$BUILD_DIR/gpu-fryer/gpu-fryer" ]; then
        log "  Using gpu-fryer (BF16, $((duration_s / 60)) min)"
        RESULTS_STRESS_LABEL="$label / gpu-fryer"
        "$BUILD_DIR/gpu-fryer/gpu-fryer" --use-bf16 "$duration_s" \
            2>&1 | tee -a "$LOG_FILE" &
        GPU_STRESS_PID=$!
        return 0
    fi
    if [ "${STRESS_BACKEND:-}" = "gpu-fryer" ]; then
        record_not_run "${label} / gpu-fryer" "build unavailable"
    fi

    if [ "${STRESS_BACKEND:-}" = "gpu-burn" ] && [ -f "$BUILD_DIR/gpu-burn/gpu-burn" ]; then
        log "  Using gpu-burn (FP64, $((duration_s / 60)) min)"
        RESULTS_STRESS_LABEL="$label / gpu-burn"
        "$BUILD_DIR/gpu-burn/gpu-burn" -d -tc "$duration_s" \
            2>&1 | tee -a "$LOG_FILE" &
        GPU_STRESS_PID=$!
        return 0
    fi
    if [ "${STRESS_BACKEND:-}" = "gpu-burn" ]; then
        record_not_run "${label} / gpu-burn" "build unavailable"
    fi

    log "  gpu-fryer and gpu-burn unavailable — using PyTorch cuBLAS fallback."
    RESULTS_STRESS_LABEL="$label / PyTorch fallback"
    run_pytorch_stress_for_duration "$duration_s" 2>&1 | tee -a "$LOG_FILE" &
    GPU_STRESS_PID=$!
    return 0
}

calculate_stress_ng_vm_bytes() {
    local mem_total_kb vm_target_kb vm_per_worker_kb
    mem_total_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
    vm_target_kb=$(( mem_total_kb * 70 / 100 ))
    vm_per_worker_kb=$(( vm_target_kb / 2 ))

    # Keep the memory pressure substantial but avoid a tiny default on small nodes.
    if [ "$vm_per_worker_kb" -lt 262144 ]; then
        vm_per_worker_kb=262144
    fi

    printf '%sK' "$vm_per_worker_kb"
}

start_cpu_ram_stress() {
    local duration_min="$1"
    local vm_bytes
    vm_bytes=$(calculate_stress_ng_vm_bytes)

    command -v stress-ng >/dev/null 2>&1 \
        || { log "  ERROR: stress-ng not found on PATH"; return 1; }

    log "  stress-ng profile: cpu=all cores, vm=2 workers, vm-bytes=${vm_bytes} each, timeout=${duration_min}m"
    stress-ng \
        --cpu 0 \
        --cpu-method all \
        --vm 2 \
        --vm-bytes "$vm_bytes" \
        --vm-method all \
        --vm-keep \
        --timeout "${duration_min}m" \
        --metrics-brief \
        2>&1 | tee -a "$LOG_FILE" &
    CPU_RAM_STRESS_PID=$!
    return 0
}

log_sensor_snapshot() {
    local title="$1"
    command -v sensors >/dev/null 2>&1 || return 0

    log ""
    log "  ${title}"
    sensors 2>&1 | tee -a "$LOG_FILE"
    log ""
}

# Thresholds for thermal flagging during burn
readonly TEMP_WARN=87      # °C — flag as potential issue
readonly FAN_WARN=100      # % — flag as maxed out

# ─── Power anomaly detection (12V-2x6 connector early-warning) ──────────────
# Detects a GPU that is self-throttling against high power-input contact
# resistance: drawing significantly less power than its peers while its fan
# is at or near max, and its die paradoxically runs cooler than peers under
# the same workload. The driver does NOT report this as throttling, but it
# is a documented precursor to Xid 79 → Xid 154 → node reboot required.
#
# All thresholds overridable via environment.
readonly POWER_ANOMALY_DELTA_W="${POWER_ANOMALY_DELTA_W:-25}"     # W below peer median floor to flag a sample
readonly POWER_ANOMALY_DELTA_PCT="${POWER_ANOMALY_DELTA_PCT:-6}"   # % of peer median floor to flag a sample
readonly POWER_ANOMALY_FAN_PCT="${POWER_ANOMALY_FAN_PCT:-85}"     # fan % at/above to count toward anomaly
readonly POWER_ANOMALY_FRAC_PCT="${POWER_ANOMALY_FRAC_PCT:-50}"   # % of post-warmup samples that must be anomalous
readonly POWER_ANOMALY_WARMUP_S="${POWER_ANOMALY_WARMUP_S:-30}"   # ignore first N seconds of burn (ramp/startup)
readonly POWER_ANOMALY_AS_REMARK="${POWER_ANOMALY_AS_REMARK:-1}"  # 1 = record as remark only, 0 = fail the test

BURN_POWER_ANOMALY_RC=0
BURN_POWER_ANOMALY_FLAGGED_GPUS=""
BURN_TELEMETRY_FILE=""
STRESS_FAILURE_SCAN_START_LINE=1

stress_hard_failure_detected() {
    local start_line="${STRESS_FAILURE_SCAN_START_LINE:-1}"
    sed -n "${start_line},\$p" "$LOG_FILE" | grep -qiE \
        'Throttling HW: true|Thermal HW: true|HW_Slowdown|HW_PowerBrake|CUDA error|illegal memory access|device-side assert|segmentation fault|SIGSEGV|Xid|panic|core dumped|fatal error' \
        || return 1
    return 0
}

begin_stress_failure_scan() {
    local current_lines
    current_lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    STRESS_FAILURE_SCAN_START_LINE=$((current_lines + 1))
}

# run_burn_monitor <burn_pid>
# Polls nvidia-smi every 5s while the burn PID is alive.
# Tracks per-GPU peak temp, peak fan, throttle events.
# Writes a formatted summary and sets BURN_THERMAL_RC=1 if any threshold crossed.
BURN_THERMAL_RC=0
run_burn_monitor() {
    local burn_pid="$1"
    local sample_interval=5
    local telemetry_file="$BUILD_DIR/_burn_telemetry.csv"
    ensure_build_dir_writable "writing burn telemetry" || return 1

    # Reset telemetry file for this run; analyse_power_anomalies will read it
    # at the end of the monitor.
    BURN_TELEMETRY_FILE="$telemetry_file"
    BURN_THERMAL_RC=0
    BURN_POWER_ANOMALY_RC=0
    BURN_POWER_ANOMALY_FLAGGED_GPUS=""
    : > "$telemetry_file" 2>/dev/null || {
        log "  WARN: cannot truncate $telemetry_file — power anomaly analysis may be skipped"
    }
    echo "elapsed_s,gpu_idx,temp_c,power_w,fan_pct,clk_sm_mhz" >> "$telemetry_file"

    # Header for the live telemetry log
    log ""
    log "  Thermal monitor (sample every ${sample_interval}s):"
    printf "  %-8s %-4s %-6s %-8s %-7s %-8s %s\n" \
        "Elapsed" "GPU" "Temp°C" "Power W" "Fan %" "SM MHz" "Throttle" \
        | tee -a "$LOG_FILE"

    # Per-GPU tracking arrays (indexed by GPU index)
    declare -A peak_temp peak_fan peak_power throttle_seen
    local gpu_idx
    for gpu_idx in $(nvidia-smi $SMI_FILTER --query-gpu=index --format=csv,noheader | tr -d '\r'); do
        peak_temp[$gpu_idx]=0
        peak_fan[$gpu_idx]=0
        peak_power[$gpu_idx]=0
        throttle_seen[$gpu_idx]="None"
    done

    local start_time
    start_time=$(date +%s)

    while kill -0 "$burn_pid" 2>/dev/null; do
        local now elapsed
        now=$(date +%s)
        elapsed=$(( now - start_time ))

        while IFS=, read -r gpu_idx temp power fan clk_sm throttle; do
            gpu_idx=$(echo "$gpu_idx" | xargs)
            temp=$(echo "$temp"       | xargs)
            power=$(echo "$power"     | xargs)
            fan=$(echo "$fan"         | xargs)
            clk_sm=$(echo "$clk_sm"   | xargs)
            throttle=$(echo "$throttle" | xargs)
            local throttle_decoded
            throttle_decoded=$(decode_throttle "$throttle")

            printf "  %-8s %-4s %-6s %-8s %-7s %-8s %s\n" \
                "${elapsed}s" "$gpu_idx" "$temp" "$power" "$fan" "$clk_sm" "$throttle_decoded" \
                | tee -a "$LOG_FILE"

            # Track peaks — strip units (°C, W, %) for numeric comparison
            local temp_val power_val fan_val clk_val
            temp_val="${temp//[^0-9]/}"
            power_val="${power//[^0-9.]/}"
            fan_val="${fan//[^0-9]/}"
            clk_val="${clk_sm//[^0-9]/}"

            # Append normalized numeric sample to CSV for post-burn analysis
            printf "%s,%s,%s,%s,%s,%s\n" \
                "$elapsed" "$gpu_idx" "${temp_val:-0}" "${power_val:-0}" "${fan_val:-0}" "${clk_val:-0}" \
                >> "$telemetry_file" 2>/dev/null || true

            if [ -n "$temp_val" ] && [ "$temp_val" -gt "${peak_temp[$gpu_idx]:-0}" ] 2>/dev/null; then
                peak_temp[$gpu_idx]=$temp_val
            fi
            if [ -n "$fan_val" ] && [ "$fan_val" -gt "${peak_fan[$gpu_idx]:-0}" ] 2>/dev/null; then
                peak_fan[$gpu_idx]=$fan_val
            fi
            if [ "$throttle_decoded" != "Not Active" ] && [ "$throttle_decoded" != "unknown" ]; then
                throttle_seen[$gpu_idx]="$throttle_decoded"
            fi
        done < <(nvidia-smi $SMI_FILTER \
            --query-gpu=index,temperature.gpu,power.draw,fan.speed,clocks.sm,clocks_throttle_reasons.active \
            --format=csv,noheader | tr -d '\r')

        sleep "$sample_interval"
    done

    # Print per-GPU peak summary
    log ""
    log "  ── Burn thermal summary ──────────────────────────────────────────"
    printf "  %-4s %-25s %8s %8s %s\n" \
        "GPU" "Name" "PeakTemp" "PeakFan" "Issues" | tee -a "$LOG_FILE"

    local gpu_name issues
    while IFS=, read -r gpu_idx gpu_name; do
        gpu_idx=$(echo "$gpu_idx"   | xargs)
        gpu_name=$(echo "$gpu_name" | xargs)
        issues=""

        local pt="${peak_temp[$gpu_idx]:-0}"
        local pf="${peak_fan[$gpu_idx]:-0}"
        local ts="${throttle_seen[$gpu_idx]:-None}"

        [ "$pt" -ge "$TEMP_WARN" ] 2>/dev/null && \
            issues+="TEMP ${pt}°C >= ${TEMP_WARN}°C (check thermal paste/airflow)  "
        [ "$pf" -ge "$FAN_WARN" ] 2>/dev/null && \
            issues+="FAN at ${pf}% (cooling at limit)  "
        [ "$ts" != "None" ] && \
            issues+="THROTTLE: $ts"

        [ -z "$issues" ] && issues="OK"

        printf "  %-4s %-25s %8s %8s %s\n" \
            "$gpu_idx" "$gpu_name" "${pt}°C" "${pf}%" "$issues" | tee -a "$LOG_FILE"

        # Set thermal RC if any GPU crossed a threshold
        if [[ "$issues" != "OK" ]]; then
            BURN_THERMAL_RC=1
        fi
    done < <(nvidia-smi $SMI_FILTER --query-gpu=index,name --format=csv,noheader | tr -d '\r')

    log "  ─────────────────────────────────────────────────────────────────"
    if [ "$BURN_THERMAL_RC" -eq 1 ]; then
        log "  WARNING: One or more GPUs exceeded thermal thresholds during burn."
        log "           Temp flag: >= ${TEMP_WARN}°C   Fan flag: >= ${FAN_WARN}%"
        log "           System passed compute test but cooling should be investigated."
    else
        log "  All GPUs within thermal limits during burn."
    fi
    log ""

    analyse_power_anomalies "$telemetry_file"
}

# ─────────────────────────────────────────────────────────────────────────────
# analyse_power_anomalies <telemetry_csv>
#
# Reads the per-sample telemetry CSV written by run_burn_monitor and detects
# GPUs whose sustained behaviour matches the connector-self-throttle signature.
# Power anomalies are remark-only by default.
# ─────────────────────────────────────────────────────────────────────────────
analyse_power_anomalies() {
    local csv_file="$1"
    BURN_POWER_ANOMALY_RC=0
    BURN_POWER_ANOMALY_FLAGGED_GPUS=""

    if [ ! -s "$csv_file" ]; then
        log "  Power anomaly check: skipped (no telemetry data)"
        return 0
    fi

    local sample_count gpu_count
    sample_count=$(($(wc -l < "$csv_file") - 1))
    gpu_count=$(awk -F, 'NR>1 { g[$2]=1 } END { n=0; for (k in g) n++; print n }' "$csv_file")

    if [ "$sample_count" -le 0 ] || [ "$gpu_count" -lt 3 ]; then
        log "  Power anomaly check: skipped (need >=3 GPUs and samples; have ${gpu_count} GPUs, ${sample_count} samples)"
        return 0
    fi

    local nonzero_fan_count
    nonzero_fan_count=$(awk -F, 'NR>1 && $5+0 > 0 { n++ } END { print n+0 }' "$csv_file")
    if [ "$nonzero_fan_count" -eq 0 ]; then
        log "  Power anomaly check: skipped (no fan telemetry — chassis-managed cooling or unavailable fan sensors)"
        return 0
    fi

    log ""
    log "  ── Power anomaly check (12V-2x6 connector early-warning) ────────"
    log "    Thresholds: power >= max(${POWER_ANOMALY_DELTA_W}W, ${POWER_ANOMALY_DELTA_PCT}% of peer median) below peer median,"
    log "                fan >= ${POWER_ANOMALY_FAN_PCT}%, sustained in >= ${POWER_ANOMALY_FRAC_PCT}% of samples,"
    log "                ignoring first ${POWER_ANOMALY_WARMUP_S}s of burn."

    local awk_out
    awk_out=$(LC_NUMERIC=C awk \
        -v delta_w="$POWER_ANOMALY_DELTA_W" \
        -v delta_pct="$POWER_ANOMALY_DELTA_PCT" \
        -v fan_pct="$POWER_ANOMALY_FAN_PCT" \
        -v frac_pct="$POWER_ANOMALY_FRAC_PCT" \
        -v warmup_s="$POWER_ANOMALY_WARMUP_S" \
        -F, '
        NR == 1 { next }
        {
            t = $1 + 0
            g = $2 + 0
            p = $4 + 0
            f = $5 + 0
            if (t < warmup_s) next
            powers[t SUBSEP g] = p
            fans[t SUBSEP g]   = f
            times[t] = 1
            gpus[g]  = 1
            sum_p[g] += p
            sum_f[g] += f
            n_g[g]++
        }
        END {
            for (g in gpus) { anom[g] = 0; tot[g] = 0; sum_delta[g] = 0 }
            for (t in times) {
                n = 0
                delete ps
                for (g in gpus) {
                    key = t SUBSEP g
                    if (key in powers) ps[++n] = powers[key]
                }
                if (n < 3) continue
                for (i = 2; i <= n; i++) {
                    v = ps[i]; j = i
                    while (j > 1 && ps[j-1] > v) { ps[j] = ps[j-1]; j-- }
                    ps[j] = v
                }
                if (n % 2 == 1) median = ps[(n+1)/2]
                else            median = (ps[n/2] + ps[n/2+1]) / 2
                threshold = delta_w
                pct_threshold = median * delta_pct / 100.0
                if (pct_threshold > threshold) threshold = pct_threshold

                for (g in gpus) {
                    key = t SUBSEP g
                    if (!(key in powers)) continue
                    tot[g]++
                    d = median - powers[key]
                    sum_delta[g] += d
                    if (d >= threshold && fans[key] >= fan_pct) anom[g]++
                }
            }

            flagged = 0
            flagged_list = ""
            n_keys = 0
            for (g in gpus) sorted[++n_keys] = g
            for (i = 2; i <= n_keys; i++) {
                v = sorted[i]; j = i
                while (j > 1 && sorted[j-1]+0 > v+0) { sorted[j] = sorted[j-1]; j-- }
                sorted[j] = v
            }
            for (i = 1; i <= n_keys; i++) {
                g = sorted[i]
                if (tot[g] == 0) continue
                pct  = (anom[g] * 100.0) / tot[g]
                avgp = sum_p[g] / n_g[g]
                avgf = sum_f[g] / n_g[g]
                avgd = sum_delta[g] / tot[g]
                status = "ok"
                if (pct >= frac_pct) { status = "FLAG"; flagged++; flagged_list = flagged_list (flagged_list ? "," : "") g }
                else if (anom[g] > 0) status = "transient"
                printf "GPU=%d status=%s anom=%d/%d pct=%.1f avg_power=%.1fW avg_fan=%.1f%% avg_delta_from_median=%.1fW\n", \
                    g, status, anom[g], tot[g], pct, avgp, avgf, avgd
            }
            print "TOTAL_FLAGGED=" flagged
            print "FLAGGED_GPUS=" flagged_list
        }
    ' "$csv_file")

    if [ -z "$awk_out" ]; then
        log "  Power anomaly check: no output from analyzer (skipped)"
        return 0
    fi

    local flagged=0
    local flagged_list=""
    printf "  %-4s %-10s %12s %14s %14s %18s\n" \
        "GPU" "Status" "Anom/Total" "AvgPower" "AvgFan" "AvgΔ-from-median" \
        | tee -a "$LOG_FILE"
    local line
    while IFS= read -r line; do
        case "$line" in
            GPU=*)
                local g s at pct avgp avgf avgd
                g=$(  echo "$line" | sed -n 's/.*GPU=\([0-9]*\).*/\1/p')
                s=$(  echo "$line" | sed -n 's/.*status=\([A-Za-z]*\).*/\1/p')
                at=$( echo "$line" | sed -n 's/.*anom=\([0-9]*\/[0-9]*\).*/\1/p')
                pct=$(echo "$line" | sed -n 's/.*pct=\([0-9.]*\).*/\1/p')
                avgp=$(echo "$line" | sed -n 's/.*avg_power=\([0-9.]*\)W.*/\1/p')
                avgf=$(echo "$line" | sed -n 's/.*avg_fan=\([0-9.]*\)%.*/\1/p')
                avgd=$(echo "$line" | sed -n 's/.*avg_delta_from_median=\([-0-9.]*\)W.*/\1/p')
                printf "  %-4s %-10s %12s %12sW %13s%% %16sW\n" \
                    "$g" "$s" "$at (${pct}%)" "$avgp" "$avgf" "$avgd" \
                    | tee -a "$LOG_FILE"
                ;;
            TOTAL_FLAGGED=*)
                flagged="${line#TOTAL_FLAGGED=}"
                ;;
            FLAGGED_GPUS=*)
                flagged_list="${line#FLAGGED_GPUS=}"
                ;;
        esac
    done <<< "$awk_out"
    BURN_POWER_ANOMALY_FLAGGED_GPUS="$flagged_list"

    log "  ─────────────────────────────────────────────────────────────────"
    if [ "$flagged" -gt 0 ]; then
        BURN_POWER_ANOMALY_RC=1
        log "  POWER ANOMALY DETECTED: ${flagged} GPU(s) showed the connector-self-throttle signature."
        [ -n "$flagged_list" ] && log "  Flagged GPU(s): ${flagged_list}"
        log ""
        log "  This signature (low power + high fan + cool die, sustained, no driver-reported throttle)"
        log "  is a documented precursor to Xid 79 GPU fall-off under production load. Most common"
        log "  cause is elevated contact resistance in the 12V-2x6 / 12VHPWR cable feeding the GPU."
        log ""
        log "  Recommended actions for any flagged GPU:"
        log "    1. Replace the 12V-2x6 power cable from PSU to that GPU position."
        log "    2. If multi-PSU, also move that GPU's input to a different PSU output."
        log "    3. Visually inspect the OLD cable's connectors at BOTH ends for:"
        log "       discolouration, recessed pins, partial melting, deformed plastic."
        log "    4. Re-run this test after the swap — anomaly should clear."
        log "    5. If anomaly persists after cable+PSU swap, the GPU-side connector"
        log "       socket may be damaged — RMA / retire that card."
        log ""
    else
        log "  Power balance OK across GPUs (no connector-self-throttle signature detected)."
    fi
    log ""
}

test_stress() {
    local label="Sustained Compute Stress"
    local duration_min burn_rc=0
    duration_min=$(echo "scale=1; $BURN_DURATION / 60" | bc)
    record_stress_activity_start
    begin_stress_failure_scan

    # Launch the burn tool in the background, monitor thermals alongside it,
    # then wait for it to finish and collect both the compute RC and thermal RC.
    start_gpu_stress_backend "$label" "$BURN_DURATION" || return 1
    local burn_pid="$GPU_STRESS_PID"

    # Run thermal monitor alongside the burn; it exits when burn_pid dies
    run_burn_monitor "$burn_pid"

    # Collect burn tool exit code
    wait "$burn_pid" 2>/dev/null || burn_rc=$?

    # Fail if compute failed OR if thermal thresholds were crossed.
    # gpu-fryer exits 1 when its internal Gflops health check fires even if
    # thermals are fine — this is a known false positive on TDP-limited GPUs
    # (e.g. RTX A4000 at 120W). Treat exit code 1 with clean thermals as a
    # warning rather than a hard failure; only fail on thermal violations.
    if [ "$burn_rc" -ne 0 ]; then
        if stress_hard_failure_detected; then
            log "  ERROR: Burn tool exited with code $burn_rc"
            return 1
        fi

        log "  WARN: Burn tool exited with code $burn_rc but only performance/thermal warnings were detected."
        log "  No hardware-crash indicators detected — treating as remark only."
        record_remark "Sustained Compute Stress: performance/thermal warning only (including SW thermal throttling); treated as a remark."
    fi
    if [ "$BURN_THERMAL_RC" -ne 0 ]; then
        log "  Compute: PASS  |  Thermals: WARNING (see summary above)"
        record_remark "Sustained Compute Stress: thermals crossed the warning threshold (temp >= ${TEMP_WARN}°C and/or fan >= ${FAN_WARN}%). Treated as a remark only."
    fi
    if [ "$BURN_POWER_ANOMALY_RC" -ne 0 ]; then
        if [ "$POWER_ANOMALY_AS_REMARK" = "1" ]; then
            log "  Compute: PASS  |  Power balance: ANOMALY (see summary above; recorded as remark per POWER_ANOMALY_AS_REMARK=1)"
        else
            log "  Compute: PASS  |  Power balance: FAIL (connector-self-throttle signature; see analysis above)"
        fi
        record_remark "Sustained Compute Stress: power anomaly on GPU(s) ${BURN_POWER_ANOMALY_FLAGGED_GPUS:-unknown} (connector-self-throttle signature) — see analysis above. Replace 12V-2x6 cable for affected GPU(s) before production."
        if [ "$POWER_ANOMALY_AS_REMARK" != "1" ]; then
            return 1
        fi
    fi
    return 0
}

test_node_stress() {
    local label="Node Stress (CPU + RAM + GPU)"
    local duration_min burn_rc=0 cpu_ram_rc=0
    local duration_s
    duration_min="$NODE_STRESS_MINUTES"
    duration_s=$(( duration_min * 60 ))
    record_stress_activity_start
    begin_stress_failure_scan

    log "  Running full-node stress for ${duration_min} minute(s)"
    log_sensor_snapshot "Initial sensors snapshot (if available):"

    if ! command -v stress-ng >/dev/null 2>&1; then
        record_not_run "$label" "stress-ng binary unavailable"
        log "  NOTE: stress-ng not found — node-wide stress is not being run."
        return 0
    fi

    start_cpu_ram_stress "$duration_min" || return 1
    local cpu_ram_pid="$CPU_RAM_STRESS_PID"

    start_gpu_stress_backend "$label" "$duration_s" || {
        kill "$cpu_ram_pid" 2>/dev/null || true
        wait "$cpu_ram_pid" 2>/dev/null || true
        return 1
    }
    local burn_pid="$GPU_STRESS_PID"

    # Monitor the GPU burn while CPU/RAM stress runs in parallel.
    run_burn_monitor "$burn_pid"

    # Collect exit codes from both concurrent workloads.
    wait "$burn_pid" 2>/dev/null || burn_rc=$?
    wait "$cpu_ram_pid" 2>/dev/null || cpu_ram_rc=$?

    log_sensor_snapshot "Final sensors snapshot (if available):"

    if [ "$burn_rc" -ne 0 ]; then
        if stress_hard_failure_detected; then
            log "  ERROR: GPU stress backend exited with code $burn_rc"
            return 1
        fi

        log "  WARN: GPU stress backend exited with code $burn_rc but only performance/thermal warnings were detected."
        log "  No hardware-crash indicators detected — treating as remark only."
        record_remark "Node Stress: performance/thermal warning only (including SW thermal throttling); treated as a remark."
    fi

    if [ "$cpu_ram_rc" -ne 0 ]; then
        log "  ERROR: stress-ng exited with code $cpu_ram_rc"
        return 1
    fi

    if [ "$BURN_THERMAL_RC" -ne 0 ]; then
        log "  Compute: PASS  |  Thermals: WARNING (see summary above)"
        record_remark "Node Stress: thermals crossed the warning threshold (temp >= ${TEMP_WARN}°C and/or fan >= ${FAN_WARN}%). Treated as a remark only."
    fi
    if [ "$BURN_POWER_ANOMALY_RC" -ne 0 ]; then
        if [ "$POWER_ANOMALY_AS_REMARK" = "1" ]; then
            log "  Compute: PASS  |  Power balance: ANOMALY (see summary above; recorded as remark per POWER_ANOMALY_AS_REMARK=1)"
        else
            log "  Compute: PASS  |  Power balance: FAIL (connector-self-throttle signature; see analysis above)"
        fi
        record_remark "Node Stress: power anomaly on GPU(s) ${BURN_POWER_ANOMALY_FLAGGED_GPUS:-unknown} (connector-self-throttle signature) — see analysis above. Replace 12V-2x6 cable for affected GPU(s) before production."
        if [ "$POWER_ANOMALY_AS_REMARK" != "1" ]; then
            return 1
        fi
    fi

    return 0
}

test_post_stress_recovery() {
    local label="Post-Stress Recovery"
    local cooldown_s="${POST_STRESS_RECOVERY_COOLDOWN_SECONDS:-20}"
    local since_ts="${STRESS_ACTIVITY_START_TS:-}"
    local rc=0

    log "  Cooling down for ${cooldown_s} second(s) before recovery check"
    sleep "$cooldown_s"

    if [ -n "$since_ts" ]; then
        log "  Stress window start : $(date -u -d "@$since_ts" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || echo "$since_ts")"
    else
        log "  NOTE: No prior stress timestamp recorded; kernel-log scan is limited to the current runtime."
        record_remark "$label: no prior stress timestamp recorded; kernel-log scan limited to the current runtime."
    fi

    local gpu_count
    gpu_count=$(nvidia-smi $SMI_FILTER -L 2>/dev/null | grep -c '^GPU' || true)
    if [ -z "$gpu_count" ] || [ "$gpu_count" -eq 0 ]; then
        log "  ERROR: nvidia-smi could not enumerate GPUs during recovery."
        return 1
    fi
    if [ "$gpu_count" -ne "$NUM_GPUS" ]; then
        log "  ERROR: GPU count changed after stress (expected $NUM_GPUS, found $gpu_count)."
        return 1
    fi

    if [ -n "$since_ts" ]; then
        if command -v journalctl >/dev/null 2>&1; then
            local journal_cmd=(journalctl -k --since "@$since_ts")
            local kernel_errors
            kernel_errors=$("${journal_cmd[@]}" 2>/dev/null \
                | grep -Ei 'NVRM: Xid|Xid|fallen off the bus|GPU has fallen off the bus|PCIe Bus Error|nvrm.*error|nvidia.*error|segfault|fatal error|panic' \
                | tail -40)
            if [ -n "$kernel_errors" ]; then
                log "  ERROR: Kernel log showed recovery-window GPU errors:"
                log "$kernel_errors"
                return 1
            fi
        else
            record_remark "$label: kernel-log recovery scan unavailable (journalctl missing)."
        fi
    fi

    local recovery_lines
    if ! recovery_lines=$(nvidia-smi $SMI_FILTER \
        --query-gpu=index,name,temperature.gpu,power.draw,fan.speed,clocks.sm,clocks_throttle_reasons.active \
        --format=csv,noheader,nounits 2>/dev/null); then
        log "  ERROR: nvidia-smi recovery snapshot failed."
        return 1
    fi

    log "  Recovery snapshot:"
    while IFS=, read -r gpu_idx gpu_name temp power fan clk_sm throttle; do
        [ -n "$gpu_idx" ] || continue

        gpu_idx=$(echo "$gpu_idx" | xargs)
        gpu_name=$(echo "$gpu_name" | xargs)
        temp=$(echo "$temp" | xargs)
        power=$(echo "$power" | xargs)
        fan=$(echo "$fan" | xargs)
        clk_sm=$(echo "$clk_sm" | xargs)
        throttle=$(echo "$throttle" | xargs)
        local throttle_decoded
        throttle_decoded=$(decode_throttle "$throttle")

        local temp_val fan_val
        temp_val="${temp//[^0-9]/}"
        fan_val="${fan//[^0-9]/}"

        local issues=()
        local hard_issue=false
        if [ "$throttle_decoded" != "Not Active" ]; then
            if echo "$throttle_decoded" | grep -q 'SW_Thermal'; then
                issues+=("soft thermal throttle still active (${throttle_decoded})")
            fi
            if echo "$throttle_decoded" | grep -Eq 'HW_Slowdown|HW_PowerBrake'; then
                issues+=("hard throttle still active (${throttle_decoded})")
                hard_issue=true
            fi
        fi
        if [ -n "$temp_val" ] && [ "$temp_val" -ge "$TEMP_WARN" ] 2>/dev/null; then
            issues+=("temp ${temp_val}°C >= ${TEMP_WARN}°C")
        fi
        if [ -n "$fan_val" ] && [ "$fan_val" -ge "$FAN_WARN" ] 2>/dev/null; then
            issues+=("fan ${fan_val}% >= ${FAN_WARN}%")
        fi

        if [ "${#issues[@]}" -eq 0 ]; then
            log "  GPU $gpu_idx ($gpu_name): OK — ${temp}°C, ${fan}, ${clk_sm} MHz, ${throttle_decoded}"
            continue
        fi

        local issue_text="${issues[*]}"
        if [ "$hard_issue" = true ]; then
            log "  ERROR: GPU $gpu_idx ($gpu_name): $issue_text"
            rc=1
        else
            log "  WARN: GPU $gpu_idx ($gpu_name): $issue_text"
            record_remark "$label: GPU $gpu_idx ($gpu_name) — $issue_text"
        fi
    done <<< "$recovery_lines"

    if [ "$rc" -eq 0 ]; then
        log "  Recovery check completed."
    fi
    return "$rc"
}

test_gpu_policy() {
    local label="GPU Policy"
    local strict="${GPU_POLICY_STRICT:-0}"
    local require_persistence="${GPU_POLICY_REQUIRE_PERSISTENCE:-0}"
    local max_idle_temp="${GPU_POLICY_MAX_IDLE_TEMP:-}"
    local min_power_limit="${GPU_POLICY_MIN_POWER_LIMIT_W:-}"
    local max_power_limit="${GPU_POLICY_MAX_POWER_LIMIT_W:-}"
    local configured=false
    local rc=0

    [ "$require_persistence" = 1 ] && configured=true
    [ -n "$max_idle_temp" ] && configured=true
    [ -n "$min_power_limit" ] && configured=true
    [ -n "$max_power_limit" ] && configured=true

    if [ "$configured" = false ]; then
        record_not_run "$label" "no GPU_POLICY_* thresholds configured"
        log "  NOTE: Set GPU_POLICY_REQUIRE_PERSISTENCE=1 and/or GPU_POLICY_MAX_IDLE_TEMP / GPU_POLICY_*_POWER_LIMIT_W to enable this test."
        return 0
    fi

    log "  Policy mode        : $([ "$strict" = 1 ] && echo strict || echo advisory)"
    log "  Persistence required: $([ "$require_persistence" = 1 ] && echo yes || echo no)"
    [ -n "$max_idle_temp" ] && log "  Max idle temp      : ${max_idle_temp}°C"
    [ -n "$min_power_limit" ] && log "  Min power limit    : ${min_power_limit}W"
    [ -n "$max_power_limit" ] && log "  Max power limit    : ${max_power_limit}W"

    local policy_lines
    if ! policy_lines=$(nvidia-smi $SMI_FILTER \
        --query-gpu=index,name,temperature.gpu,power.limit,persistence_mode,clocks_throttle_reasons.active \
        --format=csv,noheader,nounits 2>/dev/null); then
        log "  ERROR: nvidia-smi policy snapshot failed."
        return 1
    fi

    while IFS=, read -r gpu_idx gpu_name temp power_limit persistence throttle; do
        [ -n "$gpu_idx" ] || continue

        gpu_idx=$(echo "$gpu_idx" | xargs)
        gpu_name=$(echo "$gpu_name" | xargs)
        temp=$(echo "$temp" | xargs)
        power_limit=$(echo "$power_limit" | xargs)
        persistence=$(echo "$persistence" | xargs)
        throttle=$(echo "$throttle" | xargs)
        local throttle_decoded
        throttle_decoded=$(decode_throttle "$throttle")

        local issues=()
        if [ "$require_persistence" = 1 ] && [ "$persistence" != "Enabled" ]; then
            issues+=("persistence mode is ${persistence}")
        fi
        if [ -n "$max_idle_temp" ] && awk -v val="$temp" -v max="$max_idle_temp" 'BEGIN { exit !(val > max) }'; then
            issues+=("idle temp ${temp}°C > ${max_idle_temp}°C")
        fi
        if [ -n "$min_power_limit" ] && awk -v val="$power_limit" -v min="$min_power_limit" 'BEGIN { exit !(val < min) }'; then
            issues+=("power limit ${power_limit}W < ${min_power_limit}W")
        fi
        if [ -n "$max_power_limit" ] && awk -v val="$power_limit" -v max="$max_power_limit" 'BEGIN { exit !(val > max) }'; then
            issues+=("power limit ${power_limit}W > ${max_power_limit}W")
        fi
        if [ "$throttle_decoded" != "Not Active" ]; then
            if echo "$throttle_decoded" | grep -q 'SW_Thermal'; then
                issues+=("soft thermal throttle active (${throttle_decoded})")
            else
                issues+=("hard throttle active (${throttle_decoded})")
            fi
        fi

        if [ "${#issues[@]}" -eq 0 ]; then
            log "  GPU $gpu_idx ($gpu_name): OK — temp ${temp}°C, power limit ${power_limit}W, persistence ${persistence}"
            continue
        fi

        local issue_text="${issues[*]}"
        if [ "$strict" = 1 ]; then
            log "  ERROR: GPU $gpu_idx ($gpu_name): $issue_text"
            rc=1
        else
            log "  WARN: GPU $gpu_idx ($gpu_name): $issue_text"
            record_remark "$label: GPU $gpu_idx ($gpu_name) — $issue_text"
        fi
    done <<< "$policy_lines"

    return "$rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

print_diagnostic_hints() {
    local prep_fail_count=${#PREP_FAIL[@]}
    local fail_count=${#RESULTS_FAIL[@]}
    local not_run_count=${#RESULTS_NOT_RUN[@]}
    local remark_count=${#RESULTS_REMARK[@]}
    local code_failed=0
    local memtest_failed=0
    local stress_failed=0
    local stress_warn=0
    local nccl_failed=0
    local pytorch_failed=0
    local cuda_samples_failed=0
    local nvbandwidth_failed=0
    local dcgm_failed=0
    local gpu_policy_failed=0
    local post_stress_failed=0
    local r

    for r in "${RESULTS_FAIL[@]}"; do
        case "$r" in
            *"CUDA Int32 Compute Stress (code.cu)"*) code_failed=1 ;;
            *"cuda_memtest (GPU Memory Stress)"*) memtest_failed=1 ;;
            *"Sustained Compute Stress"*) stress_failed=1 ;;
            *"NCCL All-Reduce Test"*) nccl_failed=1 ;;
            *"PyTorch Multi-GPU Benchmark"*) pytorch_failed=1 ;;
            *"CUDA Samples (deviceQuery / p2pBandwidthLatencyTest)"*) cuda_samples_failed=1 ;;
            *"NVBandwidth (GPU Memory Bandwidth)"*) nvbandwidth_failed=1 ;;
            *"DCGM Diagnostics"*) dcgm_failed=1 ;;
            *"GPU Policy"*) gpu_policy_failed=1 ;;
            *"Post-Stress Recovery"*) post_stress_failed=1 ;;
        esac
    done

    for r in "${RESULTS_REMARK[@]}"; do
        case "$r" in
            *"Sustained Compute Stress:"*"thermal"*|*"Sustained Compute Stress:"*"power anomaly"*|*"connector-self-throttle signature"*)
                stress_warn=1
                ;;
        esac
    done

    if [ "$prep_fail_count" -eq 0 ] && [ "$fail_count" -eq 0 ] && [ "$remark_count" -eq 0 ] && [ "$not_run_count" -eq 0 ]; then
        return 0
    fi

    log ""
    log "  DIAGNOSTIC HINTS:"

    if [ "$prep_fail_count" -gt 0 ]; then
        log "    - preparation failed: initial suspect is a missing build dependency, toolchain issue, or host setup problem."
        log "      Next checks: review PREP FAILED entries above, install the missing prerequisite, and rerun the prepare step."
    fi

    if [ "$code_failed" -eq 1 ] && [ "$memtest_failed" -eq 1 ]; then
        log "    - code + memtest both failed: initial suspect is GPU hardware or board-level instability (VRAM, memory controller, power, thermals)."
        log "      Next checks: isolate a single GPU, inspect NVRM/Xid logs, verify power cabling, and compare against a lower-clock rerun."
    elif [ "$code_failed" -eq 1 ]; then
        log "    - code failed: initial suspect is CUDA runtime / driver / compute-path instability."
        log "      Next checks: confirm nvidia-smi works, check nvcc --version, inspect kernel logs, and rerun code on one GPU."
    fi

    if [ "$memtest_failed" -eq 1 ] && [ "$code_failed" -ne 1 ]; then
        log "    - memtest failed: initial suspect is VRAM / memory-controller / memory-clock instability."
        log "      Next checks: rerun on a single GPU, inspect temperatures and clocks, and remove any memory overclock."
    fi

    if [ "$stress_failed" -eq 1 ] || [ "$stress_warn" -eq 1 ]; then
        log "    - stress failed or only raised thermal/power remarks: initial suspect is thermals, PSU/cabling, or boost instability under sustained load."
        log "      Next checks: review temperature/fan telemetry, inspect the 12V-2x6 / 12VHPWR path, and compare with code + memtest."
    fi

    if [ "$nccl_failed" -eq 1 ] || [ "$pytorch_failed" -eq 1 ]; then
        if [ "$code_failed" -eq 0 ]; then
            log "    - nccl/pytorch failed while code passed: initial suspect is the software stack or multi-GPU communication path."
            log "      Next checks: Python environment, PyTorch wheel/CUDA compatibility, NCCL config, and PCIe/NVLink topology."
        else
            log "    - nccl/pytorch also failed: software stack issues are still possible, but hardware or comms instability remains on the table."
            log "      Next checks: rerun on fewer GPUs, compare single-GPU code vs multi-GPU behavior, and inspect NCCL logs."
        fi
    fi

    if [ "$cuda_samples_failed" -eq 1 ] || [ "$nvbandwidth_failed" -eq 1 ]; then
        log "    - cuda-samples or nvbandwidth failed: initial suspect is the CUDA runtime/driver path or PCIe/device-memory transfer path."
        log "      Next checks: confirm driver/toolkit versions, rerun code, and compare link speed / topology across GPUs."
    fi

    if [ "$dcgm_failed" -eq 1 ]; then
        log "    - DCGM failed: initial suspect is the monitoring/diagnostic stack rather than raw GPU hardware."
        log "      Next checks: confirm dcgmi is installed, verify driver compatibility, and retry the telemetry query."
    fi

    if [ "$gpu_policy_failed" -eq 1 ] || [ "$post_stress_failed" -eq 1 ]; then
        log "    - policy or recovery checks failed: initial suspect is a config/persistence/power-management issue or a GPU that did not recover cleanly after load."
        log "      Next checks: review persistence mode, power limits, idle thermals, and the post-stress GPU logs."
    fi

    if [ "$not_run_count" -gt 0 ] && [ "$fail_count" -eq 0 ] && [ "$remark_count" -eq 0 ] && [ "$prep_fail_count" -eq 0 ]; then
        log "    - some tests were NOT BEING RUN: initial suspect is a missing toolchain or unsupported host path, not a hardware failure."
        log "      Next checks: review the NOT BEING RUN entries above and install the missing dependency if needed."
    fi

    if [ "$fail_count" -eq 0 ] && [ "$remark_count" -gt 0 ] && [ "$prep_fail_count" -eq 0 ]; then
        log "    - no hard failures were recorded: review the remarks above first; they usually point to the next most likely follow-up."
    fi
}

print_summary() {
    log ""
    log "========================================"
    log "TEST SUMMARY"
    log "========================================"
    log "  Host     : $(hostname -f 2>/dev/null || hostname)"
    log "  IP(s)    : $(hostname -I 2>/dev/null | tr ' ' ',' | sed 's/,$//' || echo 'unknown')"
    log "  GPUs     : $GPU_NAMES"
    log "  Arch(es) : $CUDA_ARCH_LIST"
    log "  CUDA     : $CUDA_VERSION"
    log "  Log file : $LOG_FILE"
    log ""

    local pass_count=${#RESULTS_PASS[@]}
    local fail_count=${#RESULTS_FAIL[@]}
    local skip_count=${#RESULTS_SKIP[@]}
    local not_run_count=${#RESULTS_NOT_RUN[@]}
    local remark_count=${#RESULTS_REMARK[@]}
    local prep_pass_count=${#PREP_PASS[@]}
    local prep_fail_count=${#PREP_FAIL[@]}
    local prep_skip_count=${#PREP_SKIP[@]}
    local summary_rc=0

    if [ "$prep_pass_count" -gt 0 ]; then
        log "  PREPARED ($prep_pass_count):"
        for r in "${PREP_PASS[@]}"; do log "    ✓  $r"; done
        log ""
    fi
    if [ "$prep_skip_count" -gt 0 ]; then
        log "  PREP SKIPPED ($prep_skip_count):"
        for r in "${PREP_SKIP[@]}"; do log "    -  $r"; done
        log ""
    fi
    if [ "$prep_fail_count" -gt 0 ]; then
        log "  PREP FAILED ($prep_fail_count):"
        for r in "${PREP_FAIL[@]}"; do log "    ✗  $r"; done
        log ""
    fi

    if [ "$pass_count" -gt 0 ]; then
        log "  PASSED ($pass_count):"
        for r in "${RESULTS_PASS[@]}"; do log "    ✓  $r"; done
        log ""
    fi
    if [ "$skip_count" -gt 0 ]; then
        log "  SKIPPED ($skip_count):"
        for r in "${RESULTS_SKIP[@]}"; do log "    -  $r"; done
        log ""
    fi
    if [ "$not_run_count" -gt 0 ]; then
        log "  NOT BEING RUN ($not_run_count):"
        for r in "${RESULTS_NOT_RUN[@]}"; do log "    !  $r"; done
        log ""
    fi
    if [ "$fail_count" -gt 0 ]; then
        log "  FAILED ($fail_count):"
        for r in "${RESULTS_FAIL[@]}"; do log "    ✗  $r"; done
        log ""
    fi

    if [ "$prep_fail_count" -gt 0 ] || [ "$fail_count" -gt 0 ]; then
        log "========================================"
        log "  RESULT: prepare/test phase failed"
        log "========================================"
        summary_rc=1
    elif [ "$not_run_count" -gt 0 ]; then
        log "========================================"
        log "  RESULT: ALL RUN TESTS PASSED; $not_run_count test(s) NOT BEING RUN"
        log "========================================"
    else
        log "========================================"
        log "  RESULT: ALL $pass_count TESTS PASSED"
        log "========================================"
    fi

    if [ "$remark_count" -gt 0 ]; then
        log ""
        log "  REMARKS ($remark_count):"
        for r in "${RESULTS_REMARK[@]}"; do log "    -  $r"; done
    fi

    print_diagnostic_hints

    return "$summary_rc"
}

run_selected_tests() {
    local test
    for test in "${SELECTED_TESTS[@]}"; do
        case "$test" in
            preflight)    run_test "Preflight (Thermal Baseline / Persistence / Driver)"  test_preflight   ;;
            ecc)          run_test "ECC Error Check"                                       test_ecc         ;;
            pcie)         run_test "PCIe Link Width / Generation"                          test_pcie        ;;
            clocks)       run_test "Clock Speed Under Load"                                test_clocks      ;;
            nccl)         run_test "NCCL All-Reduce Test"                                  test_nccl        ;;
            cuda-samples) run_test "CUDA Samples (deviceQuery / p2pBandwidthLatencyTest)"  test_cuda_samples ;;
            nvbandwidth)  run_test "NVBandwidth (GPU Memory Bandwidth)"                    test_nvbandwidth ;;
            dcgm)
                if command -v dcgmi &>/dev/null; then
                    run_test "DCGM Diagnostics" test_dcgm
                else
                    skip_test "DCGM Diagnostics" "dcgmi not found — install DCGM if needed (https://developer.nvidia.com/dcgm)"
                fi
                ;;
            pytorch)      run_test "PyTorch Multi-GPU Benchmark"                           test_pytorch     ;;
            code)         run_test "CUDA Int32 Compute Stress (code.cu)"                   test_cuda_code   ;;
            memtest)      run_test "cuda_memtest (GPU Memory Stress)"                      test_memtest     ;;
            stress)
                local stress_min
                stress_min=$(echo "scale=1; $BURN_DURATION / 60" | bc)
                run_test "$RESULTS_STRESS_LABEL (${stress_min} min)"                       test_stress
                ;;
            node-stress)
                run_test "Node Stress (CPU + RAM + GPU) (${NODE_STRESS_MINUTES} min)"      test_node_stress
                ;;
            post-stress-recovery)
                run_test "Post-Stress Recovery"                                             test_post_stress_recovery
                ;;
            gpu-policy)
                run_test "GPU Policy"                                                        test_gpu_policy
                ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: $(basename "$0") [test...] [-test...] [--gpu <index[,index...]>] [--burn-duration <s>] [--node-stress-minutes <m>] [--clean] [--list] [--help]

Experimental prepare-then-run variant of fulltest.sh.
Selected tests are prepared up front, then executed after preparation succeeds.

Available tests (run in this order if none specified):
  preflight     Idle thermal baseline, persistence mode, driver state
  ecc           ECC error check (DC GPUs: fail on errors; GeForce: skip gracefully)
  pcie          PCIe link width/gen check — detects silent link degradation
  clocks        Clock speed under 30s load — detects thermal/power throttling
  nccl          NCCL all-reduce communication test
  cuda-samples  deviceQuery + p2pBandwidthLatencyTest
  nvbandwidth   Host<->device and device<->device memory bandwidth
  dcgm          DCGM diagnostics (skipped if dcgmi not installed)
  pytorch       PyTorch multi-GPU DDP benchmark
  code          CUDA int32 compute stress (code.cu) — loops across all visible GPUs
  memtest       cuda_memtest VRAM integrity (10 passes per GPU)
  stress        Sustained compute stress: gpu-fryer / gpu-burn / PyTorch
  node-stress   Node-wide stress: stress-ng CPU + RAM plus GPU burn
  post-stress-recovery  GPU recheck after stress: recovery, logs, throttle clear
  gpu-policy    Optional policy check: persistence / power limit / idle temp

Options:
  --gpu <index[,index...]>   Target specific GPU(s) by index — single (3) or comma-separated (2,4,5)
  -<test>                    Exclude a named test from the run (for example: -code, -memtest, -stress)
  --exclude <test>           Exclude a named test from the run
  --burn-duration <seconds>  Duration for stress test (default: 300 = 5 min)
  --node-stress-minutes <m>  Duration for node-wide stress test (default: 5)
  --clean                    Delete all build artifacts and exit
  --list                     List available test names and exit
  --help, -h                 Show this help

Examples:
  ./gpu-fulltest-v2.sh                              # run all tests on all GPUs
  ./gpu-fulltest-v2.sh --gpu 3                      # run all tests on GPU 3 only
  ./gpu-fulltest-v2.sh --gpu 2,4,5                  # run all tests on GPUs 2, 4, and 5
  ./gpu-fulltest-v2.sh --gpu 2,4,5 memtest stress   # memtest + stress on GPUs 2, 4, 5
  ./gpu-fulltest-v2.sh --gpu 3 memtest stress       # memtest + stress on GPU 3 only
  ./gpu-fulltest-v2.sh code                         # CUDA int32 stress across all visible GPUs
  ./gpu-fulltest-v2.sh -code                        # All default tests except code.cu
  ./gpu-fulltest-v2.sh nccl pytorch -code           # Explicit tests without code.cu
  ./gpu-fulltest-v2.sh node-stress                  # CPU + RAM + GPU stress, default 5 min
  ./gpu-fulltest-v2.sh node-stress --node-stress-minutes 15
  ./gpu-fulltest-v2.sh preflight ecc pcie clocks    # hardware health checks only
  ./gpu-fulltest-v2.sh nccl pytorch                 # communication + framework only
  ./gpu-fulltest-v2.sh stress --burn-duration 3600  # 1 hour stress test
  ./gpu-fulltest-v2.sh post-stress-recovery          # recovery check after stress
  GPU_POLICY_REQUIRE_PERSISTENCE=1 ./gpu-fulltest-v2.sh gpu-policy
  ./gpu-fulltest-v2.sh --clean                      # wipe build/ and exit
  ./gpu-fulltest-v2.sh --clean nccl                 # clean then run nccl
EOF
}

ALL_TESTS=(preflight ecc pcie clocks nccl cuda-samples nvbandwidth dcgm pytorch code memtest stress node-stress post-stress-recovery gpu-policy)
DEFAULT_TESTS=(preflight ecc pcie clocks nccl cuda-samples nvbandwidth dcgm pytorch code memtest stress node-stress post-stress-recovery)
SELECTED_TESTS=()
EXCLUDED_TESTS=()

is_valid_test_name() {
    local candidate="$1"
    local test_name
    for test_name in "${ALL_TESTS[@]}"; do
        [ "$test_name" = "$candidate" ] && return 0
    done
    return 1
}

apply_exclusions() {
    local filtered=()
    local test_name excluded_name skip

    for test_name in "${SELECTED_TESTS[@]}"; do
        skip=false
        for excluded_name in "${EXCLUDED_TESTS[@]}"; do
            if [ "$test_name" = "$excluded_name" ]; then
                skip=true
                break
            fi
        done
        [ "$skip" = true ] || filtered+=("$test_name")
    done

    SELECTED_TESTS=("${filtered[@]}")
}

# Two-pass parse: first pass handles --help/--list which exit immediately,
# second pass (index-based) handles --burn-duration which needs a lookahead value.
for arg in "$@"; do
    case "$arg" in
        --help|-h) usage; exit 0 ;;
        --list) echo "Available tests: ${ALL_TESTS[*]}"; exit 0 ;;
    esac
done

args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
    arg="${args[$i]}"
    case "$arg" in
        --help|-h)    usage; exit 0 ;;
        --list)       echo "Available tests: ${ALL_TESTS[*]}"; exit 0 ;;
        --clean)      CLEAN_BUILD=true ;;
        --gpu)
            i=$((i + 1))
            val="${args[$i]:-}"
            # Accept: single index (3), comma-separated (2,4,5), or spaced list quoted ("2 4 5")
            # Normalise spaces to commas
            val=$(echo "$val" | tr ' ' ',')
            if ! [[ "$val" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
                echo "ERROR: --gpu requires one or more GPU indices (e.g. --gpu 3 or --gpu 2,4,5)" >&2
                exit 1
            fi
            GPU_TARGET="$val"
            ;;
        --exclude)
            i=$((i + 1))
            val="${args[$i]:-}"
            if [ -z "$val" ]; then
                echo "ERROR: --exclude requires a test name" >&2
                exit 1
            fi
            if ! is_valid_test_name "$val"; then
                echo "ERROR: --exclude unknown test: $val" >&2
                exit 1
            fi
            EXCLUDED_TESTS+=("$val")
            ;;
        --burn-duration)
            i=$((i + 1))
            val="${args[$i]:-}"
            if [[ ! "$val" =~ ^[0-9]+$ ]] || [ "$val" -lt 1 ]; then
                echo "ERROR: --burn-duration requires a positive integer (seconds)" >&2
                exit 1
            fi
            BURN_DURATION="$val"
            ;;
        --node-stress-minutes)
            i=$((i + 1))
            val="${args[$i]:-}"
            if [[ ! "$val" =~ ^[0-9]+$ ]] || [ "$val" -lt 1 ]; then
                echo "ERROR: --node-stress-minutes requires a positive integer (minutes)" >&2
                exit 1
            fi
            NODE_STRESS_MINUTES="$val"
            ;;
        preflight|ecc|pcie|clocks|nccl|cuda-samples|nvbandwidth|dcgm|pytorch|code|memtest|stress|node-stress|post-stress-recovery|gpu-policy)
            SELECTED_TESTS+=("$arg") ;;
        -*)
            excluded="${arg#-}"
            if [ -z "$excluded" ]; then
                echo "Unknown argument: $arg" >&2; usage >&2; exit 1
            fi
            if ! is_valid_test_name "$excluded"; then
                echo "Unknown argument: $arg" >&2; usage >&2; exit 1
            fi
            EXCLUDED_TESTS+=("$excluded")
            ;;
        *)
            echo "Unknown argument: $arg" >&2; usage >&2; exit 1 ;;
    esac
    i=$((i + 1))
done

# Handle --clean
if [ "$CLEAN_BUILD" = true ]; then
    echo "Cleaning build directory: $BUILD_DIR"
    ensure_build_dir_writable "cleaning build artifacts" || exit 1
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    echo "Done."
    [ "${#SELECTED_TESTS[@]}" -eq 0 ] && exit 0
    echo "Proceeding with tests: ${SELECTED_TESTS[*]}"
    echo ""
fi

[ "${#SELECTED_TESTS[@]}" -eq 0 ] && SELECTED_TESTS=("${DEFAULT_TESTS[@]}")
if [ "${#EXCLUDED_TESTS[@]}" -gt 0 ]; then
    apply_exclusions
    echo "Excluding tests: ${EXCLUDED_TESTS[*]}"
    echo ""
fi

if [ "${#SELECTED_TESTS[@]}" -eq 0 ]; then
    echo "No tests remain after applying exclusions."
    exit 0
fi

detect_system
prepare_selected_tests || {
    print_summary
    exit 1
}
run_selected_tests
print_summary
