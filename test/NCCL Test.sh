#!/bin/bash

# Docker test on NCCL performance, using all GPUs, requires NVIDIA Container Toolkit installed.
docker run --rm --gpus all --ipc=host --shm-size=8g \
  -v /tmp:/hosttmp nvidia/cuda:12.6.2-devel-ubuntu22.04 bash -lc '
set -euo pipefail
apt-get update -y && apt-get install -y --no-install-recommends git make g++ procps
git clone --depth=1 https://github.com/NVIDIA/nccl-tests.git
cd nccl-tests && make MPI=0

G=$(nvidia-smi -L | wc -l)

# Useful logs for support
nvidia-smi -q -x > /hosttmp/nvidia-smi-q.xml
nvidia-smi topo -m > /hosttmp/nvidia-topo.txt

export NCCL_DEBUG=INFO
export NCCL_DEBUG_SUBSYS=INIT,GRAPH,NET
export NCCL_TOPO_DUMP_FILE=/hosttmp/nccl_topo.xml

# PCIe tuning (common on 4090 rigs)
export NCCL_P2P_LEVEL=SYS
export NCCL_NTHREADS=256
export NCCL_MIN_NCHANNELS=16
export NCCL_MAX_NCHANNELS=64

# (Optional) if you still see SHM complaints, keep it on:
# export NCCL_SHM_DISABLE=0

# Background NVML snapshot for proof-of-load:
( while true; do date -Is; nvidia-smi; sleep 5; done ) > /hosttmp/nvidia-smi-nccl.log 2>&1 &
smipid=$!

./build/all_reduce_perf -b 8M -e 4G -f 2 -g "$G" -c 2 -n 60 2>&1 | tee /hosttmp/nccl-all_reduce_perf.log

kill "$smipid" || true
'


#During testing, use tmux split plane to watch bus bandwidth:
watch -n 0.5 \
"nvidia-smi --query-gpu=index,pci.bus_id,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max --format=csv,noheader,nounits"

# Test 2 with share memory
docker run --rm --gpus all \
  --ipc=host --shm-size=8g --ulimit memlock=-1:-1 \
  -e NCCL_DEBUG=INFO \
  -e NCCL_P2P_DISABLE=0 \
  -e NCCL_P2P_LEVEL=NODE \
  -e NCCL_SHM_DISABLE=0 \
  nvidia/cuda:12.6.2-base-ubuntu22.04 \
  bash -lc '
    apt-get update -y && apt-get install -y git build-essential && \
    git clone --depth=1 https://github.com/NVIDIA/nccl-tests && \
    cd nccl-tests && make -j && \
    ./build/all_reduce_perf -b 8M -e 4G -f 2 -g 8 -c 1 -n 60
  '
