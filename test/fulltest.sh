#!/bin/bash

# Updated script to install and run multi-GPU tests on Ubuntu with RTX 5090
# Assumptions: NVIDIA drivers, CUDA 12.8+, DCGM installed; run as root or with sudo where needed
# Git, cmake, make, gcc, pip, python3 required (install if missing: apt install git cmake build-essential python3-pip)
# Added installation of libnccl2 and libnccl-dev for NCCL tests
# Added -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc and -DCMAKE_CUDA_ARCHITECTURES=90 to cmake calls for CUDA detection and architecture
# Build only if binaries not present

set -e  # Exit on error

NUM_GPUS=$(nvidia-smi -L | grep -c '^GPU')  # Detect number of GPUs
echo "Detected $NUM_GPUS GPUs."

# Function to run a test section
run_test() {
    echo "========================================"
    echo "Running: $1"
    echo "========================================"
    shift
    "$@"
    echo "Test completed."
}

# Install NCCL if not present
install_nccl() {
    if ! dpkg -l | grep -q libnccl-dev; then
        echo "Installing libnccl2 and libnccl-dev..."
        sudo apt update
        sudo apt install -y libnccl2 libnccl-dev
    else
        echo "libnccl-dev already installed."
    fi
}

# 1. NCCL Test
install_nccl_tests() {
    install_nccl  # Install NCCL before building tests
    if [ ! -d "nccl-tests" ]; then
        git clone https://github.com/NVIDIA/nccl-tests.git
    fi
    if [ ! -f "nccl-tests/build/all_reduce_perf" ]; then
        cd nccl-tests
        make clean || true  # Clean previous build artifacts, ignore error
        make -j
        cd ..
    fi
}

run_nccl_test() {
    ./nccl-tests/build/all_reduce_perf -b 8 -e 1G -f 2 -g $NUM_GPUS
}

install_nccl_tests
run_test "NCCL Test" run_nccl_test

# 2. CUDA Samples and Bandwidth Test
install_cuda_samples() {
    if [ ! -d "cuda-samples" ]; then
        git clone https://github.com/NVIDIA/cuda-samples.git
    fi

    # Build deviceQuery
    if [ ! -f "cuda-samples/Samples/1_Utilities/deviceQuery/build/deviceQuery" ]; then
        cd cuda-samples/Samples/1_Utilities/deviceQuery
        mkdir -p build
        cd build
        cmake .. -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc -DCMAKE_CUDA_ARCHITECTURES=90
        make -j
        cd ../../../../..
    fi

    # Build bandwidthTest
    if [ ! -f "cuda-samples/Samples/1_Utilities/bandwidthTest/build/bandwidthTest" ]; then
        cd cuda-samples/Samples/1_Utilities/bandwidthTest
        mkdir -p build
        cd build
        cmake .. -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc -DCMAKE_CUDA_ARCHITECTURES=90
        make -j
        cd ../../../../..
    fi

    # Build p2pBandwidthLatencyTest
    if [ ! -f "cuda-samples/Samples/0_Simple/p2pBandwidthLatencyTest/build/p2pBandwidthLatencyTest" ]; then
        cd cuda-samples/Samples/0_Simple/p2pBandwidthLatencyTest
        mkdir -p build
        cd build
        cmake .. -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc -DCMAKE_CUDA_ARCHITECTURES=90
        make -j
        cd ../../../../..
    fi
}

run_cuda_samples() {
    ./cuda-samples/Samples/1_Utilities/deviceQuery/build/deviceQuery
    ./cuda-samples/Samples/1_Utilities/bandwidthTest/build/bandwidthTest --device=all --memory=pinned
    ./cuda-samples/Samples/0_Simple/p2pBandwidthLatencyTest/build/p2pBandwidthLatencyTest
}

install_cuda_samples
run_test "CUDA Samples and Bandwidth Test" run_cuda_samples

# 3. DCGM Diagnostics
run_dcgm_diag() {
    dcgmi discovery -l
    dcgmi diag -r 3
    dcgmi dmon -e 1000,1001 -c 10
}

run_test "DCGM Diagnostics" run_dcgm_diag

# 4. AI/ML Benchmarks (PyTorch multi-GPU example)
install_pytorch() {
    pip3 install --upgrade pip
    pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128
    pip3 install accelerate  # For easier multi-GPU
}

run_ai_benchmark() {
    cat << EOF > pytorch_multi_gpu_test.py
import torch
import torch.nn as nn
import torch.distributed as dist
from torch.nn.parallel import DistributedDataParallel as DDP

dist.init_process_group(backend='nccl')
model = nn.Linear(10000, 10000).cuda()
model = DDP(model)
input_tensor = torch.randn(1000, 10000).cuda()
for _ in range(100):
    output = model(input_tensor)
print("PyTorch multi-GPU test completed.")
EOF

    torchrun --nproc_per_node $NUM_GPUS pytorch_multi_gpu_test.py
    rm pytorch_multi_gpu_test.py
}

install_pytorch
run_test "AI/ML Benchmarks (PyTorch Example)" run_ai_benchmark

# 5. cuda_memtest
install_cuda_memtest() {
    if [ ! -d "cuda_memtest" ]; then
        git clone https://github.com/ComputationalRadiationPhysics/cuda_memtest.git
    fi
    if [ ! -f "cuda_memtest/cuda_memtest" ]; then
        cd cuda_memtest
        make clean || true
        make -j
        cd ..
    fi
}

run_cuda_memtest() {
    ./cuda_memtest/cuda_memtest --stress --num_passes 10 --devices all
}

install_cuda_memtest
run_test "cuda_memtest" run_cuda_memtest

# 6. gpu-burn
install_gpu_burn() {
    if [ ! -d "gpu-burn" ]; then
        git clone https://github.com/wilicc/gpu-burn.git
    fi
    if [ ! -f "gpu-burn/gpu-burn" ]; then
        cd gpu-burn
        make clean || true
        make -j
        cd ..
    fi
}

run_gpu_burn() {
    ./gpu-burn/gpu-burn -d -tc -m 300  # Run for 5 minutes
}

install_gpu_burn
run_test "gpu-burn" run_gpu_burn

echo "All tests completed successfully."
