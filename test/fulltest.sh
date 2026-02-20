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

# GPU count
NUM_GPUS=$(nvidia-smi -L | grep -c '^GPU')
echo "  GPUs detected       : $NUM_GPUS"

# GPU names (all unique models present)
GPU_NAMES=$(nvidia-smi --query-gpu=name --format=csv,noheader | sort -u | tr '\n' ',' | sed 's/,$//')
echo "  GPU model(s)        : $GPU_NAMES"

# Collect all unique compute capabilities across all GPUs
# e.g. "8.6" → "86"; mixed systems get space-separated list
CUDA_ARCH_LIST=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | sort -u | tr -d '.' | tr '\n' ' ' | xargs)
# CMake wants semicolon-separated for multi-arch builds
CUDA_ARCHS_CMAKE=$(echo "$CUDA_ARCH_LIST" | tr ' ' ';')
echo "  CUDA architecture(s): $CUDA_ARCH_LIST"

# Detect nvcc — check PATH first, then common install locations
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
CUDA_HOME_DIR=$(dirname "$(dirname "$NVCC_PATH")")  # e.g. /usr/local/cuda
CUDA_VERSION=$("$NVCC_PATH" --version | grep -oP 'release \K[0-9]+\.[0-9]+')
echo "  nvcc path           : $NVCC_PATH"
echo "  CUDA home           : $CUDA_HOME_DIR"
echo "  CUDA version        : $CUDA_VERSION"

# Derive PyTorch wheel suffix from installed CUDA version
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
    *)  TORCH_CUDA="cu128" ;;  # fallback for future CUDA versions
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

# Build a CUDA sample in its own build/ subdirectory using CMake
# Usage: cmake_build <src_dir> <expected_binary_name>
cmake_build() {
    local src="$1"
    local bin="$2"
    if [ ! -f "$src/build/$bin" ]; then
        echo "  Building $bin..."
        cd "$src"
        rm -rf build
        mkdir -p build
        cd build
        cmake .. \
            -DCMAKE_CUDA_COMPILER="$NVCC_PATH" \
            -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCHS_CMAKE"
        make -j"$(nproc)"
        cd "$ROOT_DIR"
    else
        echo "  Already built: $bin"
    fi
}

# Find a compiled binary anywhere under a base directory
find_binary() {
    find "$1" -type f -name "$2" 2>/dev/null | head -1
}

# ─────────────────────────────────────────────
# 1. NCCL Tests
# ─────────────────────────────────────────────

install_nccl() {
    # Works on Debian/Ubuntu; on RHEL/Rocky use dnf install libnccl-devel
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
# 2. CUDA Samples (deviceQuery, bandwidthTest, p2pBandwidthLatencyTest)
# ─────────────────────────────────────────────

install_cuda_samples() {
    if [ ! -d "$ROOT_DIR/cuda-samples" ]; then
        git clone https://github.com/NVIDIA/cuda-samples.git "$ROOT_DIR/cuda-samples"
    fi

    # deviceQuery
    local dq_src="$ROOT_DIR/cuda-samples/Samples/1_Utilities/deviceQuery"
    if [ -d "$dq_src" ]; then
        cmake_build "$dq_src" "deviceQuery"
    else
        echo "  WARNING: deviceQuery source not found."
    fi

    # bandwidthTest
    local bw_src="$ROOT_DIR/cuda-samples/Samples/1_Utilities/bandwidthTest"
    if [ -d "$bw_src" ]; then
        cmake_build "$bw_src" "bandwidthTest"
    else
        echo "  WARNING: bandwidthTest source not found."
    fi

    # p2pBandwidthLatencyTest — path changed across repo versions:
    #   pre-2023 : Samples/0_Simple/p2pBandwidthLatencyTest
    #   2023+    : Samples/5_Domain_Specific/p2pBandwidthLatencyTest
    # Use find to handle any future moves transparently
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

    echo "--- bandwidthTest ---"
    bin=$(find_binary "$ROOT_DIR/cuda-samples" "bandwidthTest")
    [ -n "$bin" ] && "$bin" --device=all --memory=pinned || echo "  SKIPPED (binary not found)"

    echo "--- p2pBandwidthLatencyTest ---"
    bin=$(find_binary "$ROOT_DIR/cuda-samples" "p2pBandwidthLatencyTest")
    [ -n "$bin" ] && "$bin" || echo "  SKIPPED (binary not found)"
}

install_cuda_samples
run_test "CUDA Samples (deviceQuery / bandwidthTest / p2pBandwidthLatencyTest)" run_cuda_samples

# ─────────────────────────────────────────────
# 3. DCGM Diagnostics (optional)
# ─────────────────────────────────────────────

if command -v dcgmi &>/dev/null; then
    run_dcgm_diag() {
        dcgmi discovery -l
        dcgmi diag -r 3
        dcgmi dmon -e 1000,1001 -c 10
    }
    run_test "DCGM Diagnostics" run_dcgm_diag
else
    skip_test "DCGM Diagnostics" \
        "dcgmi not found — install DCGM if needed (https://developer.nvidia.com/dcgm)"
fi

# ─────────────────────────────────────────────
# 4. PyTorch Multi-GPU Benchmark
# ─────────────────────────────────────────────

install_pytorch() {
    pip3 install --upgrade pip --quiet
    pip3 install torch torchvision torchaudio \
        --index-url "https://download.pytorch.org/whl/${TORCH_CUDA}" --quiet
    pip3 install accelerate --quiet
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
PYEOF

    torchrun --nproc_per_node "$NUM_GPUS" "$ROOT_DIR/_pytorch_multi_gpu_test.py"
    rm -f "$ROOT_DIR/_pytorch_multi_gpu_test.py"
}

install_pytorch
run_test "PyTorch Multi-GPU Benchmark" run_ai_benchmark

# ─────────────────────────────────────────────
# 5. cuda_memtest (GPU memory stress)
# ─────────────────────────────────────────────

install_cuda_memtest() {
    if [ ! -d "$ROOT_DIR/cuda_memtest" ]; then
        git clone https://github.com/ComputationalRadiationPhysics/cuda_memtest.git \
            "$ROOT_DIR/cuda_memtest"
    fi
    if [ ! -f "$ROOT_DIR/cuda_memtest/cuda_memtest" ]; then
        cd "$ROOT_DIR/cuda_memtest"
        make clean || true
        make -j"$(nproc)" CUDA_PATH="$CUDA_HOME_DIR"
        cd "$ROOT_DIR"
    else
        echo "  cuda_memtest already built."
    fi
}

run_cuda_memtest() {
    "$ROOT_DIR/cuda_memtest/cuda_memtest" --stress --num_passes 10 --devices all
}

install_cuda_memtest
run_test "cuda_memtest (GPU Memory Stress)" run_cuda_memtest

# ─────────────────────────────────────────────
# 6. gpu-burn (sustained compute stress)
# ─────────────────────────────────────────────

install_gpu_burn() {
    if [ ! -d "$ROOT_DIR/gpu-burn" ]; then
        git clone https://github.com/wilicc/gpu-burn.git "$ROOT_DIR/gpu-burn"
    fi
    if [ ! -f "$ROOT_DIR/gpu-burn/gpu-burn" ]; then
        cd "$ROOT_DIR/gpu-burn"
        make clean || true
        # gpu-burn uses COMPUTE=sm_XX — derive from first detected arch
        FIRST_ARCH=$(echo "$CUDA_ARCH_LIST" | awk '{print $1}')
        COMPUTE="sm_${FIRST_ARCH}" make -j"$(nproc)"
        cd "$ROOT_DIR"
    else
        echo "  gpu-burn already built."
    fi
}

run_gpu_burn() {
    # -d = double precision, -tc = use tensor cores if available, 300 = seconds
    "$ROOT_DIR/gpu-burn/gpu-burn" -d -tc -m 300
}

install_gpu_burn
run_test "gpu-burn (Sustained Compute Stress, 5 min)" run_gpu_burn

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────

echo "========================================"
echo "All tests completed successfully."
echo "  GPUs     : $GPU_NAMES"
echo "  Arch(es) : $CUDA_ARCH_LIST"
echo "  CUDA     : $CUDA_VERSION"
echo "========================================"
