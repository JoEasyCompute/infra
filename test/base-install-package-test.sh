#!/usr/bin/env bash
# Verify package selection without running installer startup or APT.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$(awk '$0 == "install_nvidia_stack() {" {copy=1} copy {print} copy && /^}$/ {exit}' "${ROOT_DIR}/install/base-install.sh")"
info() { :; }; section() { :; }; success() { :; }
error() { echo "$*" >&2; exit 1; }
check_nvidia_reboot() { :; }
CUDA_TOOLKIT_VERSION=13-4 CUDA_DISPLAY_VERSION=13.4 CUDA_CUDNN_SUFFIX=13-4
apt-cache() {
    printf '%s\n' 'libnvidia-compute | 615.71.09-1ubuntu1 | repo' 'libnvidia-compute | 615.71.09-2ubuntu1 | repo' 'libnvidia-compute | 595.91.07-1ubuntu1 | repo'
}
sudo() { printf 'APT %s\n' "$*"; }
DRIVER_VERSION=615
output=$(install_nvidia_stack)
[[ $output == *'libnvidia-compute=615.71.09-2ubuntu1'* && $output == *'nvidia-dkms-open=615.71.09-2ubuntu1'* ]] || { echo 'FAIL: modern driver package names/version'; exit 1; }
[[ $output == *'nvidia-driver-pinning-615'* && $output != *'nvidia-utils-615'* ]]
[[ $output == *'cuda-toolkit-13-4'* && $output == *'cudnn9-cuda-13-4'* ]]
DRIVER_VERSION=595
output=$(install_nvidia_stack)
[[ $output == *'libnvidia-compute=595.91.07-1ubuntu1'* && $output != *'=615.'* ]]
DRIVER_VERSION=580
output=$(install_nvidia_stack)
[[ $output == *'libnvidia-compute-580'* && $output == *'nvidia-dkms-580-open'* && $output == *'nvidia-utils-580'* ]]
DRIVER_VERSION=615
apt-cache() { :; }
if output=$(install_nvidia_stack 2>&1); then echo 'FAIL: missing branch accepted'; exit 1; fi
[[ $output != *'APT '* ]]
echo 'NVIDIA package selection checks passed'
