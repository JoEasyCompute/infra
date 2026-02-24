#!/bin/bash

# Multi-GPU test suite — platform independent
# Supports any NVIDIA GPU: RTX 4090, A4000, RTX 5090, A100, H100, etc.
# Requires: NVIDIA drivers, CUDA toolkit, git, cmake, make, gcc, python3-pip
#   Install missing deps: apt install git cmake build-essential python3-pip
# DCGM is optional — tests are skipped gracefully if not installed
# Run from any directory; all artifacts are placed under ROOT_DIR

set -o pipefail  # catch pipe failures but continue on individual test errors

ROOT_DIR=$(pwd)

# ─────────────────────────────────────────────
# System Detection
# ─────────────────────────────────────────────

echo "========================================"
echo "System Detection"
echo "========================================"

# Detect OS version once at the top for use throughout the script
UBUNTU_VER=$(lsb_release -rs 2>/dev/null || echo "0")
UBUNTU_MAJOR=$(echo "$UBUNTU_VER" | cut -d. -f1)
OS_ID=$(lsb_release -is 2>/dev/null || echo "Unknown")
echo "  OS                  : $OS_ID $UBUNTU_VER"

NUM_GPUS=$(nvidia-smi -L | grep -c '^GPU')
echo "  GPUs detected       : $NUM_GPUS"

GPU_NAMES=$(nvidia-smi --query-gpu=name --format=csv,noheader \
    | tr -d '\r' | sort -u | tr '\n' ',' | sed 's/,$//')
echo "  GPU model(s)        : $GPU_NAMES"

# Detect nvcc
NVCC_PATH=""
for candidate in "$(command -v nvcc 2>/dev/null)" \
                 /usr/local/cuda/bin/nvcc \
                 /usr/bin/nvcc; do
    if [ -x "$candidate" ]; then
        NVCC_PATH="$candidate"
        break
    fi
done
if [ -z "$NVCC_PATH" ]; then
    echo "ERROR: nvcc not found. Install CUDA toolkit or add nvcc to PATH."
    exit 1
fi
CUDA_HOME_DIR=$(dirname "$(dirname "$NVCC_PATH")")
CUDA_VERSION=$("$NVCC_PATH" --version | grep -oP 'release \K[0-9]+\.[0-9]+')
echo "  nvcc path           : $NVCC_PATH"
echo "  CUDA home           : $CUDA_HOME_DIR"
echo "  CUDA version        : $CUDA_VERSION"

# Detect CUDA arch — strip \r since nvidia-smi can emit Windows-style line endings
CUDA_ARCH_LIST=$(
    nvidia-smi --query-gpu=compute_cap --format=csv,noheader \
    | tr -d '\r' \
    | tr -d '.' \
    | sort -u \
    | tr '\n' ' ' \
    | xargs
)
echo "  CUDA architecture(s): $CUDA_ARCH_LIST"

# PyTorch wheel suffix
CUDA_MAJOR=$(echo "$CUDA_VERSION" | cut -d. -f1)
CUDA_MINOR=$(echo "$CUDA_VERSION" | cut -d. -f2)
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
echo "  PyTorch wheel       : https://download.pytorch.org/whl/$TORCH_CUDA"

[ "$NUM_GPUS" -eq 1 ] && \
    echo "  NOTE: Single GPU — multi-GPU tests will run in single-GPU mode."

echo ""

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────

# Result tracking — populated by run_test and skip_test
RESULTS_PASS=()
RESULTS_FAIL=()
RESULTS_SKIP=()

run_test() {
    local name="$1"
    shift
    echo "========================================"
    echo "Running: $name"
    echo "========================================"
    local rc=0
    "$@" || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "[ PASS ] $name"
        RESULTS_PASS+=("$name")
    else
        echo "[ FAIL ] $name (exit code $rc)"
        RESULTS_FAIL+=("$name")
    fi
    echo ""
}

skip_test() {
    echo "========================================"
    echo "SKIPPED: $1"
    echo "Reason : $2"
    echo "========================================"
    RESULTS_SKIP+=("$1 — $2")
    echo ""
}

# Patch all CMakeLists.txt files under a directory to remove sm_110.
# The cuda-samples repo hardcodes "set(CMAKE_CUDA_ARCHITECTURES 75 80 86 87 89 90 100 110 120)"
# inside each sample. This is a plain set(), not a CACHE variable, so it overwrites
# any -DCMAKE_CUDA_ARCHITECTURES flag we pass on the command line. sm_110 does not
# exist in any real GPU and was removed from CUDA 12.9's supported target list,
# causing every build to fail. We patch it out before invoking cmake.
patch_cmake_arch() {
    local dir="$1"
    while IFS= read -r f; do
        if grep -q 'set(CMAKE_CUDA_ARCHITECTURES' "$f"; then
            sed -i 's/\b110\b//g' "$f"   # remove sm_110
            sed -i 's/  */ /g' "$f"       # collapse double spaces
        fi
    done < <(find "$dir" -name "CMakeLists.txt")
}

cmake_build() {
    local src="$1"
    local bin="$2"
    if [ ! -f "$src/build/$bin" ]; then
        echo "  Building $bin..."
        patch_cmake_arch "$src"
        cd "$src"
        rm -rf build
        mkdir -p build
        cd build
        ARCHS_CMAKE=$(echo "$CUDA_ARCH_LIST" | tr ' ' ';')
        cmake .. \
            -DCMAKE_CUDA_COMPILER="$NVCC_PATH" \
            -DCMAKE_CUDA_ARCHITECTURES="$ARCHS_CMAKE"
        make -j"$(nproc)"
        cd "$ROOT_DIR"
    else
        echo "  Already built: $bin"
    fi
}

find_binary() {
    find "$1" -type f -name "$2" 2>/dev/null | head -1
}

# ─────────────────────────────────────────────
# 1. NCCL Tests
# ─────────────────────────────────────────────

install_nccl() {
    if command -v dpkg &>/dev/null; then
        # Derive the major CUDA version from the toolkit (e.g. 12.9 -> "12")
        local cuda_major
        cuda_major=$(echo "$CUDA_VERSION" | cut -d. -f1)

        # Check if libnccl is already installed AND matches our CUDA major version.
        # If the wrong cuda variant is installed (e.g. +cuda13.1 when we have cuda12),
        # remove it and reinstall the correct one to avoid the
        # "CUDA driver version is insufficient" runtime mismatch.
        local installed_nccl
        installed_nccl=$(dpkg -l 2>/dev/null | awk "/libnccl2 /{print \$3}" | head -1)

        if [ -n "$installed_nccl" ]; then
            # Extract the cuda suffix from the installed version (e.g. "2.29.3-1+cuda13.1" -> "13")
            local installed_cuda_major
            installed_cuda_major=$(echo "$installed_nccl" | grep -oP '\+cuda\K[0-9]+')
            if [ "$installed_cuda_major" != "$cuda_major" ]; then
                echo "  WARNING: libnccl2 $installed_nccl is built for CUDA ${installed_cuda_major}.x"
                echo "           but toolkit is CUDA ${CUDA_VERSION} — reinstalling matching version..."
                sudo apt-get remove -y libnccl2 libnccl-dev 2>/dev/null || true
                installed_nccl=""
            else
                echo "  libnccl2 $installed_nccl matches CUDA ${cuda_major}.x — OK."
            fi
        fi

        if [ -z "$installed_nccl" ]; then
            echo "  Installing libnccl2/libnccl-dev for CUDA ${cuda_major}.x..."
            sudo apt-get update -qq

            # Try exact cuda version first (e.g. cuda12.9), then fall back to cuda12
            local exact_ver
            exact_ver=$(apt-cache madison libnccl2 2>/dev/null                 | grep "+cuda${CUDA_VERSION}" | head -1 | awk '{print $3}')
            local major_ver
            major_ver=$(apt-cache madison libnccl2 2>/dev/null                 | grep "+cuda${cuda_major}\." | sort -t. -k2 -rn | head -1 | awk '{print $3}')

            local target_ver="${exact_ver:-$major_ver}"
            if [ -n "$target_ver" ]; then
                echo "  Pinning to libnccl2=$target_ver"
                sudo apt-get install -y "libnccl2=$target_ver" "libnccl-dev=$target_ver"
            else
                echo "  WARNING: No cuda${cuda_major}.x NCCL build found — installing latest (may mismatch)."
                sudo apt-get install -y libnccl2 libnccl-dev
            fi
        fi

    elif command -v rpm &>/dev/null; then
        if ! rpm -q libnccl-devel &>/dev/null; then
            echo "  Installing libnccl-devel (RHEL/Rocky)..."
            sudo dnf install -y libnccl-devel
        else
            echo "  libnccl-devel already installed."
        fi
    else
        echo "  WARNING: Unknown package manager — ensure NCCL is installed manually."
    fi
}

install_nccl_tests() {
    install_nccl
    if [ ! -d "$ROOT_DIR/nccl-tests" ]; then
        git clone https://github.com/NVIDIA/nccl-tests.git "$ROOT_DIR/nccl-tests"
    fi
    # Always rebuild if libnccl was just reinstalled (binary may be stale/mismatched)
    if [ ! -f "$ROOT_DIR/nccl-tests/build/all_reduce_perf" ]; then
        echo "  Building nccl-tests..."
        cd "$ROOT_DIR/nccl-tests"
        make clean || true
        make -j"$(nproc)" CUDA_HOME="$CUDA_HOME_DIR"
        cd "$ROOT_DIR"
    else
        # Verify the existing binary links against the correct libnccl
        local linked_nccl
        linked_nccl=$(ldd "$ROOT_DIR/nccl-tests/build/all_reduce_perf" 2>/dev/null             | grep libnccl | awk '{print $3}')
        local system_nccl="/usr/lib/x86_64-linux-gnu/libnccl.so.2"
        if [ -n "$linked_nccl" ] && [ "$linked_nccl" != "$system_nccl" ]; then
            echo "  nccl-tests links against $linked_nccl but system has $system_nccl — rebuilding..."
            cd "$ROOT_DIR/nccl-tests"
            make clean || true
            make -j"$(nproc)" CUDA_HOME="$CUDA_HOME_DIR"
            cd "$ROOT_DIR"
        else
            echo "  nccl-tests already built and libnccl matches."
        fi
    fi
}

run_nccl_test() {
    local perf="$ROOT_DIR/nccl-tests/build/all_reduce_perf"

    # First run normally
    if "$perf" -b 8 -e 1G -f 2 -g "$NUM_GPUS"; then
        return 0
    fi

    # On failure, re-run with NCCL_DEBUG=INFO to capture diagnostic detail
    echo ""
    echo "  NCCL test failed — re-running with NCCL_DEBUG=INFO for diagnostics:"
    echo "  (look for lines starting with NCCL INFO or WARN below)"
    echo ""
    NCCL_DEBUG=INFO "$perf" -b 8 -e 32M -f 2 -g "$NUM_GPUS" 2>&1 |         grep -E "^(NCCL|#|ezc|.*error|.*Error|.*WARN|.*fatal)" | head -60
    return 1
}

install_nccl_tests
run_test "NCCL All-Reduce Test" run_nccl_test

# ─────────────────────────────────────────────
# 2. CUDA Samples (deviceQuery, p2pBandwidthLatencyTest)
#    Note: bandwidthTest was removed in cuda-samples 12.9 (inaccurate results).
#    NVBandwidth is its replacement — see section 3 below.
# ─────────────────────────────────────────────

install_cuda_samples() {
    if [ ! -d "$ROOT_DIR/cuda-samples" ]; then
        git clone https://github.com/NVIDIA/cuda-samples.git "$ROOT_DIR/cuda-samples"
    fi

    local dq_src="$ROOT_DIR/cuda-samples/Samples/1_Utilities/deviceQuery"
    [ -d "$dq_src" ] && cmake_build "$dq_src" "deviceQuery" \
        || echo "  WARNING: deviceQuery source not found."

    # p2p location varies by repo version — use find to handle any future moves
    local p2p_src
    p2p_src=$(find "$ROOT_DIR/cuda-samples/Samples" -maxdepth 3 \
        -type d -name "p2pBandwidthLatencyTest" 2>/dev/null | head -1)
    if [ -n "$p2p_src" ]; then
        cmake_build "$p2p_src" "p2pBandwidthLatencyTest"
    else
        echo "  WARNING: p2pBandwidthLatencyTest source not found."
    fi
}

run_cuda_samples() {
    local bin

    echo "--- deviceQuery ---"
    bin=$(find_binary "$ROOT_DIR/cuda-samples" "deviceQuery")
    [ -n "$bin" ] && "$bin" || echo "  SKIPPED (binary not found)"

    echo "--- p2pBandwidthLatencyTest ---"
    bin=$(find_binary "$ROOT_DIR/cuda-samples" "p2pBandwidthLatencyTest")
    [ -n "$bin" ] && "$bin" || echo "  SKIPPED (binary not found)"
}

install_cuda_samples
run_test "CUDA Samples (deviceQuery / p2pBandwidthLatencyTest)" run_cuda_samples

# ─────────────────────────────────────────────
# 3. NVBandwidth — official replacement for bandwidthTest (removed in 12.9)
#    Measures host<->device and device<->device memory bandwidth accurately.
#    Requires: libboost-program-options-dev
# ─────────────────────────────────────────────

install_nvbandwidth() {
    # Ensure cmake is available — it may not be installed on minimal systems
    if ! command -v cmake &>/dev/null; then
        echo "  cmake not found — installing..."
        if command -v apt-get &>/dev/null; then
            sudo apt-get update -qq
            sudo apt-get install -y cmake
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y cmake
        else
            echo "ERROR: Cannot install cmake — unknown package manager."
            return 1
        fi
    fi

    # Install boost dependency
    if command -v dpkg &>/dev/null; then
        if ! dpkg -l 2>/dev/null | grep -q libboost-program-options-dev; then
            echo "  Installing libboost-program-options-dev..."
            sudo apt-get update -qq
            sudo apt-get install -y libboost-program-options-dev
        else
            echo "  libboost-program-options-dev already installed."
        fi
    elif command -v rpm &>/dev/null; then
        if ! rpm -q boost-program-options &>/dev/null; then
            echo "  Installing boost-program-options (RHEL/Rocky)..."
            sudo dnf install -y boost-program-options
        fi
    fi

    if [ ! -d "$ROOT_DIR/nvbandwidth" ]; then
        git clone https://github.com/NVIDIA/nvbandwidth.git "$ROOT_DIR/nvbandwidth"
    fi

    NVB_BIN=$(find "$ROOT_DIR/nvbandwidth" -maxdepth 2 -type f -name "nvbandwidth"         ! -name "*.cmake" ! -name "*.cpp" 2>/dev/null | head -1)

    if [ -z "$NVB_BIN" ]; then
        echo "  Building nvbandwidth..."
        cd "$ROOT_DIR/nvbandwidth"
        cmake . -DCMAKE_CUDA_COMPILER="$NVCC_PATH"
        make -j"$(nproc)"
        cd "$ROOT_DIR"
        NVB_BIN=$(find "$ROOT_DIR/nvbandwidth" -maxdepth 2 -type f -name "nvbandwidth"             ! -name "*.cmake" ! -name "*.cpp" 2>/dev/null | head -1)
    else
        echo "  nvbandwidth already built: $NVB_BIN"
    fi

    if [ -z "$NVB_BIN" ] || [ ! -x "$NVB_BIN" ]; then
        echo "ERROR: nvbandwidth binary not found after build."
        return 1
    fi
}

run_nvbandwidth() {
    NVB_BIN=$(find "$ROOT_DIR/nvbandwidth" -maxdepth 2 -type f -name "nvbandwidth"         ! -name "*.cmake" ! -name "*.cpp" 2>/dev/null | head -1)

    if [ -z "$NVB_BIN" ] || [ ! -x "$NVB_BIN" ]; then
        echo "ERROR: nvbandwidth binary not found — build may have failed."
        return 1
    fi

    # Run core bandwidth tests; device-to-device tests are waived on single GPU — expected
    "$NVB_BIN"         -t host_to_device_memcpy_ce            device_to_host_memcpy_ce            device_to_device_memcpy_read_ce            device_to_device_memcpy_write_ce            device_to_device_bidirectional_memcpy_read_ce
}

install_nvbandwidth && run_test "NVBandwidth (GPU Memory Bandwidth)" run_nvbandwidth \
    || { RESULTS_FAIL+=("NVBandwidth (GPU Memory Bandwidth)"); echo "[ FAIL ] NVBandwidth build failed"; }

# ─────────────────────────────────────────────
# 4. DCGM Diagnostics (optional)
# ─────────────────────────────────────────────

if command -v dcgmi &>/dev/null; then
    run_dcgm_diag() {
        dcgmi discovery -l
        dcgmi diag -r 3
        # Monitor key fields for 10 samples.
        # Fields: 203=GPU utilization, 252=memory utilization, 150=temperature, 155=power
        # NOTE: Hardware/stress tests skip on GeForce GPUs (Data Center GPUs only) - expected.
        echo "--- dmon (GPU util / memory util / temperature / power) ---"
        dcgmi dmon -e 203,252,150,155 -c 10
    }
    run_test "DCGM Diagnostics" run_dcgm_diag
else
    skip_test "DCGM Diagnostics" \
        "dcgmi not found — install DCGM if needed (https://developer.nvidia.com/dcgm)"
fi

# ─────────────────────────────────────────────
# 5. PyTorch Multi-GPU Benchmark
# ─────────────────────────────────────────────

install_pytorch() {
    # --break-system-packages is required on Ubuntu 24.04+ (PEP 668 enforced)
    # but not recognised on 22.04 (Python 3.10) and will cause an error there
    if [ "$UBUNTU_MAJOR" -ge 24 ] 2>/dev/null; then
        PIP_EXTRA="--break-system-packages"
    else
        PIP_EXTRA=""
    fi

    pip3 install --upgrade pip --quiet $PIP_EXTRA
    pip3 install torch torchvision torchaudio \
        --index-url "https://download.pytorch.org/whl/${TORCH_CUDA}" --quiet $PIP_EXTRA
    pip3 install accelerate --quiet $PIP_EXTRA
}

run_ai_benchmark() {
    cat << 'PYEOF' > "$ROOT_DIR/_pytorch_multi_gpu_test.py"
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
    print(f"PyTorch multi-GPU test completed on {world} GPU(s).")
dist.destroy_process_group()
PYEOF

    # torchrun installs to ~/.local/bin which may not be on PATH — find it explicitly
    TORCHRUN=$(python3 -m torch.utils.collect_env 2>/dev/null | grep -oP 'executable.*?\K/[^ ]+' | head -1 || true)
    if [ -z "$TORCHRUN" ]; then
        TORCHRUN=$(find "$HOME/.local/bin" /usr/local/bin /usr/bin -name torchrun 2>/dev/null | head -1 || true)
    fi
    if [ -z "$TORCHRUN" ] || [ ! -x "$TORCHRUN" ]; then
        echo "ERROR: torchrun not found after installing PyTorch."
        rm -f "$ROOT_DIR/_pytorch_multi_gpu_test.py"
        return 1
    fi
    echo "  Using torchrun: $TORCHRUN"
    "$TORCHRUN" --nproc_per_node "$NUM_GPUS" "$ROOT_DIR/_pytorch_multi_gpu_test.py"
    rm -f "$ROOT_DIR/_pytorch_multi_gpu_test.py"
}

install_pytorch
run_test "PyTorch Multi-GPU Benchmark" run_ai_benchmark

# ─────────────────────────────────────────────
# 6. cuda_memtest
# ─────────────────────────────────────────────

install_cuda_memtest() {
    if [ ! -d "$ROOT_DIR/cuda_memtest" ]; then
        git clone https://github.com/ComputationalRadiationPhysics/cuda_memtest.git \
            "$ROOT_DIR/cuda_memtest"
    fi
    # cuda_memtest uses CMake only (no plain Makefile); binary lands in build/
    if [ ! -f "$ROOT_DIR/cuda_memtest/build/cuda_memtest" ]; then
        cd "$ROOT_DIR/cuda_memtest"
        rm -rf build && mkdir -p build && cd build
        ARCHS_CMAKE=$(echo "$CUDA_ARCH_LIST" | tr ' ' ';')
        cmake .. \
            -DCMAKE_CUDA_COMPILER="$NVCC_PATH" \
            -DCMAKE_CUDA_ARCHITECTURES="$ARCHS_CMAKE"
        make -j"$(nproc)"
        cd "$ROOT_DIR"
    else
        echo "  cuda_memtest already built."
    fi
}

run_cuda_memtest() {
    # --device takes a single index; run once per GPU in parallel
    local pids=()
    for i in $(seq 0 $((NUM_GPUS - 1))); do
        "$ROOT_DIR/cuda_memtest/build/cuda_memtest" --stress --num_passes 10 --device "$i" &
        pids+=($!)
    done
    # Wait for all and collect exit codes
    local failed=0
    for pid in "${pids[@]}"; do
        wait "$pid" || failed=$((failed + 1))
    done
    [ "$failed" -eq 0 ] || { echo "ERROR: cuda_memtest failed on $failed GPU(s)"; return 1; }
}

install_cuda_memtest
run_test "cuda_memtest (GPU Memory Stress)" run_cuda_memtest

# ─────────────────────────────────────────────
# 7. Sustained Compute Stress
#    Primary:  HuggingFace gpu-fryer (Rust binary, no CUDA compile, CUDA 13 safe)
#    Secondary: wilicc/gpu-burn (classic tool; fallback when gpu-fryer unavailable)
#    Fallback: PyTorch cuBLAS stress loop (always available since PyTorch is installed)
#
#    COMPUTE format for gpu-burn must be "X.Y" (e.g. "12.0") — the Makefile does
#    -arch=compute_$(subst .,,${COMPUTE}), so "12.0" → "compute_120". Passing
#    "sm_120" would produce the broken "compute_sm_120".
# ─────────────────────────────────────────────

install_gpu_burn() {
    if [ -f "$ROOT_DIR/gpu-burn/gpu-burn" ]; then
        echo "  gpu-burn already built."
        return 0
    fi

    if [ ! -d "$ROOT_DIR/gpu-burn" ]; then
        git clone https://github.com/wilicc/gpu-burn.git "$ROOT_DIR/gpu-burn"
    fi

    cd "$ROOT_DIR/gpu-burn"
    make clean || true
    # COMPUTE must be "X.Y" format — Makefile strips the dot internally
    FIRST_ARCH_DOT=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader         | tr -d "\r" | sort -u | head -1)
    make -j"$(nproc)" COMPUTE="$FIRST_ARCH_DOT" CUDAPATH="$CUDA_HOME_DIR"
    cd "$ROOT_DIR"
}

run_gpu_burn() {
    "$ROOT_DIR/gpu-burn/gpu-burn" -d -tc 300
}

install_gpu_fryer() {
    if [ -f "$ROOT_DIR/gpu-fryer/gpu-fryer" ]; then
        echo "  gpu-fryer already built."
        return 0
    fi

    # gpu-fryer is a Rust binary — requires cargo
    if ! command -v cargo &>/dev/null; then
        echo "  cargo not found — installing Rust toolchain..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
        # shellcheck source=/dev/null
        source "$HOME/.cargo/env"
    fi

    if ! command -v cargo &>/dev/null; then
        echo "  WARNING: cargo still not available — will use PyTorch fallback."
        return 1
    fi

    if [ ! -d "$ROOT_DIR/gpu-fryer" ]; then
        git clone https://github.com/huggingface/gpu-fryer.git "$ROOT_DIR/gpu-fryer"
    fi

    cd "$ROOT_DIR/gpu-fryer"
    # Point cargo to the CUDA libs so the build can find libnvidia-ml
    export LIBRARY_PATH="$CUDA_HOME_DIR/lib64:${LIBRARY_PATH:-}"
    cargo build --release
    cp target/release/gpu-fryer .
    cd "$ROOT_DIR"
}

run_gpu_fryer() {
    # 300 seconds = 5 minutes; BF16 stresses Tensor Cores on Blackwell/Ada/Hopper
    "$ROOT_DIR/gpu-fryer/gpu-fryer" --use-bf16 300
}

run_pytorch_stress() {
    echo "  Running PyTorch cuBLAS stress (5 min, all GPUs)..."
    cat << 'PYEOF' > "$ROOT_DIR/_gpu_stress.py"
import torch
import time
import sys

duration = 300  # seconds
gpus = list(range(torch.cuda.device_count()))
if not gpus:
    print("ERROR: No CUDA GPUs found")
    sys.exit(1)

SIZE = 8192
print(f"Stressing {len(gpus)} GPU(s) for {duration}s with {SIZE}x{SIZE} BF16 GEMM...")

matrices = []
for g in gpus:
    with torch.cuda.device(g):
        a = torch.randn(SIZE, SIZE, dtype=torch.bfloat16, device=f"cuda:{g}")
        b = torch.randn(SIZE, SIZE, dtype=torch.bfloat16, device=f"cuda:{g}")
        matrices.append((a, b))

start = time.time()
iters = 0
while time.time() - start < duration:
    for g, (a, b) in enumerate(matrices):
        with torch.cuda.device(g):
            _ = torch.mm(a, b)
    for g in gpus:
        torch.cuda.synchronize(g)
    iters += 1
    elapsed = time.time() - start
    if iters % 50 == 0:
        print(f"  {elapsed:.0f}s elapsed, {iters} iterations")

print(f"Stress complete: {iters} iterations in {time.time()-start:.1f}s — no errors.")
PYEOF
    python3 "$ROOT_DIR/_gpu_stress.py"
    rm -f "$ROOT_DIR/_gpu_stress.py"
}

run_stress_test() {
    if [ -f "$ROOT_DIR/gpu-fryer/gpu-fryer" ]; then
        run_gpu_fryer
    elif [ -f "$ROOT_DIR/gpu-burn/gpu-burn" ]; then
        run_gpu_burn
    else
        echo "  gpu-fryer and gpu-burn unavailable — using PyTorch cuBLAS stress fallback."
        run_pytorch_stress
    fi
}

# Try gpu-fryer first (works on all CUDA versions)
# Fall through to gpu-burn (CUDA 12 only) or PyTorch fallback
if install_gpu_fryer; then
    run_test "Sustained Compute Stress / gpu-fryer (5 min)" run_stress_test
elif install_gpu_burn; then
    run_test "Sustained Compute Stress / gpu-burn (5 min)" run_stress_test
else
    run_test "Sustained Compute Stress / PyTorch fallback (5 min)" run_pytorch_stress
fi

# ─────────────────────────────────────────────

echo ""
echo "========================================"
echo "TEST SUMMARY"
echo "========================================"
echo "  GPUs     : $GPU_NAMES"
echo "  Arch(es) : $CUDA_ARCH_LIST"
echo "  CUDA     : $CUDA_VERSION"
echo ""

PASS_COUNT=${#RESULTS_PASS[@]}
FAIL_COUNT=${#RESULTS_FAIL[@]}
SKIP_COUNT=${#RESULTS_SKIP[@]}

if [ "$PASS_COUNT" -gt 0 ]; then
    echo "  PASSED ($PASS_COUNT):"
    for r in "${RESULTS_PASS[@]}"; do echo "    ✓  $r"; done
    echo ""
fi

if [ "$SKIP_COUNT" -gt 0 ]; then
    echo "  SKIPPED ($SKIP_COUNT):"
    for r in "${RESULTS_SKIP[@]}"; do echo "    -  $r"; done
    echo ""
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "  FAILED ($FAIL_COUNT):"
    for r in "${RESULTS_FAIL[@]}"; do echo "    ✗  $r"; done
    echo ""
    echo "========================================"
    echo "  RESULT: $FAIL_COUNT test(s) FAILED"
    echo "========================================"
    exit 1
else
    echo "========================================"
    echo "  RESULT: ALL $PASS_COUNT TESTS PASSED"
    echo "========================================"
fi
