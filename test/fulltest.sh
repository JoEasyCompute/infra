#!/bin/bash

# Multi-GPU test suite — platform independent
# Supports any NVIDIA GPU: RTX 4090, A4000, RTX 5090, A100, H100, etc.
# Requires: NVIDIA drivers, CUDA toolkit, git, cmake, make, gcc, python3-pip
#   Install missing deps: apt install git cmake build-essential python3-pip
# DCGM is optional — tests are skipped gracefully if not installed
# Run from any directory; all artifacts are placed under ROOT_DIR

set -e

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

run_test() {
    echo "========================================"
    echo "Running: $1"
    echo "========================================"
    shift
    "$@"
    echo "Test completed."
    echo ""
}

skip_test() {
    echo "========================================"
    echo "SKIPPED: $1"
    echo "Reason : $2"
    echo "========================================"
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
        if ! dpkg -l 2>/dev/null | grep -q libnccl-dev; then
            echo "  Installing libnccl2 and libnccl-dev..."
            sudo apt-get update -qq
            sudo apt-get install -y libnccl2 libnccl-dev
        else
            echo "  libnccl-dev already installed."
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
    if [ ! -f "$ROOT_DIR/nccl-tests/build/all_reduce_perf" ]; then
        cd "$ROOT_DIR/nccl-tests"
        make clean || true
        make -j"$(nproc)" CUDA_HOME="$CUDA_HOME_DIR"
        cd "$ROOT_DIR"
    else
        echo "  nccl-tests already built."
    fi
}

run_nccl_test() {
    "$ROOT_DIR/nccl-tests/build/all_reduce_perf" -b 8 -e 1G -f 2 -g "$NUM_GPUS"
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

    if [ ! -f "$ROOT_DIR/nvbandwidth/nvbandwidth" ]; then
        cd "$ROOT_DIR/nvbandwidth"
        # NVBandwidth builds in-source (cmake .) per upstream docs
        cmake . -DCMAKE_CUDA_COMPILER="$NVCC_PATH"
        make -j"$(nproc)"
        cd "$ROOT_DIR"
    else
        echo "  nvbandwidth already built."
    fi
}

run_nvbandwidth() {
    # Run the core bandwidth tests: host<->device and device<->device
    "$ROOT_DIR/nvbandwidth/nvbandwidth" \
        -t host_to_device_memcpy_ce \
           device_to_host_memcpy_ce \
           device_to_device_memcpy_read_ce \
           device_to_device_memcpy_write_ce \
           device_to_device_bidirectional_memcpy_read_ce
}

install_nvbandwidth
run_test "NVBandwidth (GPU Memory Bandwidth)" run_nvbandwidth

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
    "$ROOT_DIR/cuda_memtest/build/cuda_memtest" --stress --num_passes 10 --devices all
}

install_cuda_memtest
run_test "cuda_memtest (GPU Memory Stress)" run_cuda_memtest

# ─────────────────────────────────────────────
# 7. gpu-burn
# ─────────────────────────────────────────────

install_gpu_burn() {
    if [ ! -d "$ROOT_DIR/gpu-burn" ]; then
        git clone https://github.com/wilicc/gpu-burn.git "$ROOT_DIR/gpu-burn"
    fi
    if [ ! -f "$ROOT_DIR/gpu-burn/gpu-burn" ]; then
        cd "$ROOT_DIR/gpu-burn"
        make clean || true
        FIRST_ARCH=$(echo "$CUDA_ARCH_LIST" | awk '{print $1}')
        COMPUTE="sm_${FIRST_ARCH}" make -j"$(nproc)"
        cd "$ROOT_DIR"
    else
        echo "  gpu-burn already built."
    fi
}

run_gpu_burn() {
    "$ROOT_DIR/gpu-burn/gpu-burn" -d -tc -m 300
}

install_gpu_burn
run_test "gpu-burn (Sustained Compute Stress, 5 min)" run_gpu_burn

# ─────────────────────────────────────────────

echo "========================================"
echo "All tests completed successfully."
echo "  GPUs     : $GPU_NAMES"
echo "  Arch(es) : $CUDA_ARCH_LIST"
echo "  CUDA     : $CUDA_VERSION"
echo "========================================"
