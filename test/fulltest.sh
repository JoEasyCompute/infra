#!/bin/bash

# Updated script to install and run multi-GPU tests on Ubuntu with RTX 5090
# Assumptions: NVIDIA drivers, CUDA 12.8+, DCGM installed; run as root or with sudo where needed
# Git, make, gcc, pip, python3 required (install if missing: apt install git build-essential python3-pip)
# Added installation of libnccl2 and libnccl-dev for NCCL tests
# Modified to always build nccl-tests to handle previous failed builds

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
    cd nccl-tests
    make clean  # Clean previous build artifacts
    make -j
    cd ..
}

run_nccl_test() {
    cd nccl-tests
    ./build/all_reduce_perf -b 8 -e 1G -f 2 -g $NUM_GPUS
    cd ..
}

install_nccl_tests
run_test "NCCL Test" run_nccl_test

# 2. CUDA Samples and Bandwidth Test
install_cuda_samples() {
    if [ ! -d "cuda-samples" ]; then
        git clone https://github.com/NVIDIA/cuda-samples.git
    fi
    cd cuda-samples
    make clean  # Optional, but to be consistent
    make -j
    cd ..
}

run_cuda_samples() {
    cd cuda-samples/bin/x86_64/linux/release
    ./deviceQuery
    ./bandwidthTest --device=all --memory=pinned
    ./p2pBandwidthLatencyTest
    cd ../../../..
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
    cd cuda_memtest
    make clean
    make -j
    cd ..
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
    cd gpu-burn
    make clean
    make -j
    cd ..
}

run_gpu_burn() {
    ./gpu-burn/gpu-burn -d -tc -m 300  # Run for 5 minutes
}

install_gpu_burn
run_test "gpu-burn" run_gpu_burn

echo "All tests completed successfully."
