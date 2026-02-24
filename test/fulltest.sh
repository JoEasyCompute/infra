#!/bin/bash
# =============================================================================
# fulltest.sh — Multi-GPU test suite
# Supports: RTX 4090/5090, A4000, A100, H100 on Ubuntu 22.04/24.04
# Usage:  ./fulltest.sh [test...] [--list] [--clean] [--help]
#   Tests: nccl, cuda-samples, nvbandwidth, dcgm, pytorch, memtest, stress
#   If no tests specified, all are run.
# =============================================================================

set -o pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Constants and globals
# ─────────────────────────────────────────────────────────────────────────────

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BUILD_DIR="$SCRIPT_DIR/build"   # all clones/binaries go here
readonly LOG_FILE="$SCRIPT_DIR/fulltest_$(date +%Y%m%d_%H%M%S).log"

CLEAN_BUILD=false   # set to true by --clean
BURN_DURATION=300   # seconds; override with --burn-duration <seconds>

mkdir -p "$BUILD_DIR"

# Write identification header to log immediately
{
    echo "============================================================"
    echo "  fulltest.sh — GPU Test Suite"
    echo "  Date     : $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "  Hostname : $(hostname -f 2>/dev/null || hostname)"
    echo "  IP(s)    : $(hostname -I 2>/dev/null | tr ' ' ',' | sed 's/,$//' || echo 'unknown')"
    echo "  User     : $(whoami)"
    echo "  Script   : $SCRIPT_DIR/fulltest.sh"
    echo "============================================================"
} | tee "$LOG_FILE"

RESULTS_PASS=()
RESULTS_FAIL=()
RESULTS_SKIP=()

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

# ─────────────────────────────────────────────────────────────────────────────
# Utilities
# ─────────────────────────────────────────────────────────────────────────────

log() { echo "$@" | tee -a "$LOG_FILE"; }
log_run() { "$@" 2>&1 | tee -a "$LOG_FILE"; return "${PIPESTATUS[0]}"; }

# Run a command inside a directory, always return to $SCRIPT_DIR afterward.
in_dir() {
    local dir="$1"; shift
    (cd "$dir" && "$@")          # subshell — no cd leakage on failure
}

# apt_install — idempotent, quiet package install
apt_install() {
    for pkg in "$@"; do
        if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            log "  apt: installing $pkg"
            sudo apt-get install -y "$pkg" 2>&1 | tee -a "$LOG_FILE"
        fi
    done
}

# ensure_cmake — install cmake if missing
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
# Builds in an out-of-source build/ subdir; patches out sm_110 first.
cmake_build() {
    local src="$1" bin="$2"
    local bdir="$src/build"

    [ -f "$bdir/$bin" ] && { log "  Already built: $bin"; return 0; }

    log "  Building $bin..."

    # Patch out sm_110: it was removed from CUDA 12.9 but hardcoded in cuda-samples CMakeLists.
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

    NUM_GPUS=$(nvidia-smi -L 2>/dev/null | grep -c '^GPU' || true)
    if [ -z "$NUM_GPUS" ] || [ "$NUM_GPUS" -eq 0 ]; then
        log "ERROR: No NVIDIA GPUs detected. Aborting."
        exit 1
    fi
    log "  GPUs detected       : $NUM_GPUS"

    GPU_NAMES=$(nvidia-smi --query-gpu=name --format=csv,noheader \
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
        nvidia-smi --query-gpu=compute_cap --format=csv,noheader \
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
        *)  TORCH_CUDA="cu128" ;;
    esac
    log "  PyTorch wheel       : https://download.pytorch.org/whl/$TORCH_CUDA"

    # pip flag for Ubuntu 24.04+ (PEP 668)
    if [ "$UBUNTU_MAJOR" -ge 24 ] 2>/dev/null; then
        PIP_EXTRA="--break-system-packages"
    else
        PIP_EXTRA=""
    fi

    [ "$NUM_GPUS" -eq 1 ] && log "  NOTE: Single GPU — multi-GPU tests run in single-GPU mode."
    log ""
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
    [ ! -d "$BUILD_DIR/nccl-tests" ] && \
        git clone https://github.com/NVIDIA/nccl-tests.git "$BUILD_DIR/nccl-tests"

    if [ -f "$perf" ]; then
        # Verify binary links against the current system libnccl
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

    log "  Building nccl-tests..."
    in_dir "$BUILD_DIR/nccl-tests" bash -c "
        make clean 2>/dev/null || true
        make -j$(nproc) CUDA_HOME='$CUDA_HOME_DIR'
    " 2>&1 | tee -a "$LOG_FILE"
}

test_nccl() {
    install_nccl_lib
    install_nccl_tests_bin

    local perf="$BUILD_DIR/nccl-tests/build/all_reduce_perf"
    [ -f "$perf" ] || { log "ERROR: nccl-tests binary not found."; return 1; }

    if "$perf" -b 8 -e 1G -f 2 -g "$NUM_GPUS" 2>&1 | tee -a "$LOG_FILE"; then
        return 0
    fi

    # Re-run with debug output to capture the actual NCCL error
    log ""
    log "  NCCL failed — re-running with NCCL_DEBUG=INFO for diagnostics:"
    NCCL_DEBUG=INFO "$perf" -b 8 -e 32M -f 2 -g "$NUM_GPUS" 2>&1 \
        | grep -E "NCCL|WARN|error|Error|fatal" | head -60 | tee -a "$LOG_FILE"
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: CUDA Samples
# ─────────────────────────────────────────────────────────────────────────────

test_cuda_samples() {
    [ ! -d "$BUILD_DIR/cuda-samples" ] && \
        git clone https://github.com/NVIDIA/cuda-samples.git "$BUILD_DIR/cuda-samples"

    cmake_build "$BUILD_DIR/cuda-samples/Samples/1_Utilities/deviceQuery" "deviceQuery"

    local p2p_src
    p2p_src=$(find "$BUILD_DIR/cuda-samples/Samples" -maxdepth 3 \
        -type d -name "p2pBandwidthLatencyTest" 2>/dev/null | head -1)
    [ -n "$p2p_src" ] && cmake_build "$p2p_src" "p2pBandwidthLatencyTest"

    local rc=0

    log "--- deviceQuery ---"
    local dq_bin
    dq_bin=$(find_binary "$BUILD_DIR/cuda-samples" "deviceQuery")
    if [ -n "$dq_bin" ]; then
        "$dq_bin" 2>&1 | tee -a "$LOG_FILE" || rc=1
    else
        log "  WARN: deviceQuery binary not found"; rc=1
    fi

    log "--- p2pBandwidthLatencyTest ---"
    local p2p_bin
    p2p_bin=$(find_binary "$BUILD_DIR/cuda-samples" "p2pBandwidthLatencyTest")
    if [ -n "$p2p_bin" ]; then
        "$p2p_bin" 2>&1 | tee -a "$LOG_FILE" || rc=1
    else
        log "  WARN: p2pBandwidthLatencyTest binary not found"; rc=1
    fi

    return $rc
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: NVBandwidth
# ─────────────────────────────────────────────────────────────────────────────

test_nvbandwidth() {
    ensure_cmake || return 1

    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq
        apt_install libboost-program-options-dev
    elif command -v dnf &>/dev/null; then
        rpm -q boost-program-options &>/dev/null || sudo dnf install -y boost-program-options
    fi

    [ ! -d "$BUILD_DIR/nvbandwidth" ] && \
        git clone https://github.com/NVIDIA/nvbandwidth.git "$BUILD_DIR/nvbandwidth"

    local nvb_bin
    nvb_bin=$(find_binary "$BUILD_DIR/nvbandwidth" "nvbandwidth")

    if [ -z "$nvb_bin" ]; then
        log "  Building nvbandwidth..."
        in_dir "$BUILD_DIR/nvbandwidth" bash -c "
            cmake . -DCMAKE_CUDA_COMPILER='$NVCC_PATH'
            make -j$(nproc)
        " 2>&1 | tee -a "$LOG_FILE"
        nvb_bin=$(find_binary "$BUILD_DIR/nvbandwidth" "nvbandwidth")
    else
        log "  nvbandwidth already built: $nvb_bin"
    fi

    if [ -z "$nvb_bin" ] || [ ! -x "$nvb_bin" ]; then
        log "ERROR: nvbandwidth binary not found after build."
        return 1
    fi

    # device-to-device tests are expected to be skipped on single-GPU systems
    "$nvb_bin" \
        -t host_to_device_memcpy_ce \
           device_to_host_memcpy_ce \
           device_to_device_memcpy_read_ce \
           device_to_device_memcpy_write_ce \
           device_to_device_bidirectional_memcpy_read_ce \
        2>&1 | tee -a "$LOG_FILE"
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
    pip3 install --upgrade pip --quiet $PIP_EXTRA 2>&1 | tee -a "$LOG_FILE"
    pip3 install torch torchvision torchaudio \
        --index-url "https://download.pytorch.org/whl/${TORCH_CUDA}" \
        --quiet $PIP_EXTRA 2>&1 | tee -a "$LOG_FILE"
    pip3 install accelerate --quiet $PIP_EXTRA 2>&1 | tee -a "$LOG_FILE"
}

find_torchrun() {
    find "$HOME/.local/bin" /usr/local/bin /usr/bin \
        -name torchrun 2>/dev/null | head -1
}

test_pytorch() {
    install_pytorch

    local torchrun
    torchrun=$(find_torchrun)
    if [ -z "$torchrun" ] || [ ! -x "$torchrun" ]; then
        log "ERROR: torchrun not found after installing PyTorch."
        return 1
    fi
    log "  Using torchrun: $torchrun"

    local script="$BUILD_DIR/_pytorch_ddp_test.py"
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

    local rc=0
    "$torchrun" --nproc_per_node "$NUM_GPUS" "$script" 2>&1 | tee -a "$LOG_FILE" || rc=$?
    rm -f "$script"
    return $rc
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: cuda_memtest
# ─────────────────────────────────────────────────────────────────────────────

test_memtest() {
    local bin="$BUILD_DIR/cuda_memtest/build/cuda_memtest"

    if [ ! -d "$BUILD_DIR/cuda_memtest" ]; then
        git clone https://github.com/ComputationalRadiationPhysics/cuda_memtest.git \
            "$BUILD_DIR/cuda_memtest"
    fi

    if [ ! -f "$bin" ]; then
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

    [ -f "$bin" ] || { log "ERROR: cuda_memtest binary not found after build."; return 1; }

    # Run one process per GPU in parallel; collect all exit codes
    local pids=() failed=0
    for i in $(seq 0 $((NUM_GPUS - 1))); do
        "$bin" --stress --num_passes 10 --device "$i" 2>&1 | tee -a "$LOG_FILE" &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "$pid" || failed=$((failed + 1))
    done
    [ "$failed" -eq 0 ] || { log "ERROR: cuda_memtest failed on $failed GPU(s)"; return 1; }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: Sustained stress
#   Hierarchy: gpu-fryer (Rust, no CUDA compile) → gpu-burn → PyTorch fallback
# ─────────────────────────────────────────────────────────────────────────────

build_gpu_fryer() {
    local bin="$BUILD_DIR/gpu-fryer/gpu-fryer"
    [ -f "$bin" ] && { log "  gpu-fryer already built."; return 0; }

    if ! command -v cargo &>/dev/null; then
        log "  cargo not found — installing Rust toolchain..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
        # shellcheck source=/dev/null
        source "$HOME/.cargo/env"
    fi
    command -v cargo &>/dev/null || { log "  WARNING: cargo unavailable."; return 1; }

    [ ! -d "$BUILD_DIR/gpu-fryer" ] && \
        git clone https://github.com/huggingface/gpu-fryer.git "$BUILD_DIR/gpu-fryer"

    LIBRARY_PATH="$CUDA_HOME_DIR/lib64:${LIBRARY_PATH:-}" \
        in_dir "$BUILD_DIR/gpu-fryer" bash -c "
            cargo build --release
            cp target/release/gpu-fryer .
        " 2>&1 | tee -a "$LOG_FILE"
}

build_gpu_burn() {
    local bin="$BUILD_DIR/gpu-burn/gpu-burn"
    [ -f "$bin" ] && { log "  gpu-burn already built."; return 0; }

    [ ! -d "$BUILD_DIR/gpu-burn" ] && \
        git clone https://github.com/wilicc/gpu-burn.git "$BUILD_DIR/gpu-burn"

    # COMPUTE must be "X.Y" — Makefile does -arch=compute_$(subst .,,${COMPUTE})
    local compute_cap
    compute_cap=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader \
        | tr -d '\r' | sort -u | head -1)

    in_dir "$BUILD_DIR/gpu-burn" bash -c "
        make clean 2>/dev/null || true
        make -j$(nproc) COMPUTE='$compute_cap' CUDAPATH='$CUDA_HOME_DIR'
    " 2>&1 | tee -a "$LOG_FILE"
}

run_pytorch_stress() {
    local script="$BUILD_DIR/_gpu_stress.py"
    cat > "$script" << PYEOF
import torch, time, sys

DURATION = ${BURN_DURATION}
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

test_stress() {
    local label="Sustained Compute Stress"
    local duration_min
    duration_min=$(echo "scale=1; $BURN_DURATION / 60" | bc)

    if build_gpu_fryer && [ -f "$BUILD_DIR/gpu-fryer/gpu-fryer" ]; then
        log "  Using gpu-fryer (BF16, ${duration_min} min)"
        RESULTS_STRESS_LABEL="$label / gpu-fryer"
        "$BUILD_DIR/gpu-fryer/gpu-fryer" --use-bf16 "$BURN_DURATION" 2>&1 | tee -a "$LOG_FILE"

    elif build_gpu_burn && [ -f "$BUILD_DIR/gpu-burn/gpu-burn" ]; then
        log "  Using gpu-burn (FP64, ${duration_min} min)"
        RESULTS_STRESS_LABEL="$label / gpu-burn"
        "$BUILD_DIR/gpu-burn/gpu-burn" -d -tc "$BURN_DURATION" 2>&1 | tee -a "$LOG_FILE"

    else
        log "  gpu-fryer and gpu-burn unavailable — using PyTorch cuBLAS fallback."
        RESULTS_STRESS_LABEL="$label / PyTorch fallback"
        run_pytorch_stress
    fi
}

# Need label variable accessible outside function
RESULTS_STRESS_LABEL="Sustained Compute Stress"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

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
    if [ "$fail_count" -gt 0 ]; then
        log "  FAILED ($fail_count):"
        for r in "${RESULTS_FAIL[@]}"; do log "    ✗  $r"; done
        log ""
        log "========================================"
        log "  RESULT: $fail_count test(s) FAILED"
        log "========================================"
        return 1
    else
        log "========================================"
        log "  RESULT: ALL $pass_count TESTS PASSED"
        log "========================================"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing and main
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: $(basename "$0") [test...] [--clean] [--list] [--help]

Available tests (run in this order if none specified):
  nccl          NCCL all-reduce communication test
  cuda-samples  deviceQuery + p2pBandwidthLatencyTest
  nvbandwidth   Host<->device and device<->device memory bandwidth
  dcgm          DCGM diagnostics (skipped if dcgmi not installed)
  pytorch       PyTorch multi-GPU DDP benchmark
  memtest       cuda_memtest VRAM integrity (10 passes per GPU)
  stress        Sustained compute stress: gpu-fryer / gpu-burn / PyTorch

Options:
  --burn-duration <seconds>  Duration for stress test (default: 300 = 5 min)
  --clean                    Delete all build artifacts and exit (re-clone and rebuild on next run)
  --list                     List available test names and exit
  --help, -h                 Show this help

Examples:
  ./fulltest.sh                         # run all tests (5 min stress)
  ./fulltest.sh nccl pytorch            # run only NCCL and PyTorch tests
  ./fulltest.sh stress --burn-duration 3600  # stress test for 1 hour
  ./fulltest.sh --burn-duration 1800    # all tests, 30 min stress
  ./fulltest.sh --clean                 # wipe build/ directory
  ./fulltest.sh --clean nccl            # clean then immediately run nccl
  ./fulltest.sh --list                  # list available tests
EOF
}

ALL_TESTS=(nccl cuda-samples nvbandwidth dcgm pytorch memtest stress)
SELECTED_TESTS=()

for arg in "$@"; do
    case "$arg" in
        --help|-h) usage; exit 0 ;;
        --list)
            echo "Available tests: ${ALL_TESTS[*]}"
            exit 0
            ;;
        --clean)
            CLEAN_BUILD=true
            ;;
        --burn-duration)
            # handled by next iteration via shift-style lookahead below
            ;;
        nccl|cuda-samples|nvbandwidth|dcgm|pytorch|memtest|stress)
            SELECTED_TESTS+=("$arg") ;;
        *)
            echo "Unknown argument: $arg" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Re-parse with index to handle --burn-duration <value>
args=("$@")
i=0
SELECTED_TESTS=()
while [ "$i" -lt "${#args[@]}" ]; do
    arg="${args[$i]}"
    case "$arg" in
        --help|-h)    usage; exit 0 ;;
        --list)       echo "Available tests: ${ALL_TESTS[*]}"; exit 0 ;;
        --clean)      CLEAN_BUILD=true ;;
        --burn-duration)
            i=$((i + 1))
            val="${args[$i]:-}"
            if [[ ! "$val" =~ ^[0-9]+$ ]] || [ "$val" -lt 1 ]; then
                echo "ERROR: --burn-duration requires a positive integer (seconds)" >&2
                exit 1
            fi
            BURN_DURATION="$val"
            ;;
        nccl|cuda-samples|nvbandwidth|dcgm|pytorch|memtest|stress)
            SELECTED_TESTS+=("$arg") ;;
        *)
            echo "Unknown argument: $arg" >&2
            usage >&2
            exit 1
            ;;
    esac
    i=$((i + 1))
done

# Handle --clean: remove build directory, then continue if tests were also requested
if [ "$CLEAN_BUILD" = true ]; then
    echo "Cleaning build directory: $BUILD_DIR"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    echo "Done."
    # If --clean was the only argument, exit here
    [ "${#SELECTED_TESTS[@]}" -eq 0 ] && exit 0
    echo "Proceeding with tests: ${SELECTED_TESTS[*]}"
    echo ""
fi

[ "${#SELECTED_TESTS[@]}" -eq 0 ] && SELECTED_TESTS=("${ALL_TESTS[@]}")

# ─── Run ───────────────────────────────────────────────────────────────────

detect_system

for test in "${SELECTED_TESTS[@]}"; do
    case "$test" in
        nccl)         run_test "NCCL All-Reduce Test"                          test_nccl         ;;
        cuda-samples) run_test "CUDA Samples (deviceQuery / p2pBandwidthLatencyTest)" test_cuda_samples ;;
        nvbandwidth)  run_test "NVBandwidth (GPU Memory Bandwidth)"            test_nvbandwidth  ;;
        dcgm)
            if command -v dcgmi &>/dev/null; then
                run_test "DCGM Diagnostics" test_dcgm
            else
                skip_test "DCGM Diagnostics" "dcgmi not found — install DCGM if needed (https://developer.nvidia.com/dcgm)"
            fi
            ;;
        pytorch)      run_test "PyTorch Multi-GPU Benchmark"                   test_pytorch      ;;
        memtest)      run_test "cuda_memtest (GPU Memory Stress)"              test_memtest      ;;
        stress)
            local stress_min
            stress_min=$(echo "scale=1; $BURN_DURATION / 60" | bc)
            run_test "$RESULTS_STRESS_LABEL (${stress_min} min)" test_stress
            ;;
    esac
done

print_summary
