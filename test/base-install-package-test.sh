#!/usr/bin/env bash
# Verify package selection without running installer startup or APT.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for fn in legacy_nvidia_package_removals prepare_nvidia_driver_transition install_nvidia_stack; do
    eval "$(awk -v name="$fn" '$0 == name "() {" {copy=1} copy {print} copy && /^}$/ {exit}' "${ROOT_DIR}/install/base-install.sh")"
done
info() { :; }; section() { :; }; success() { :; }
error() { echo "$*" >&2; exit 1; }
check_nvidia_reboot() { :; }
KEYRING_CALLED=false
install_cuda_keyring() { KEYRING_CALLED=true; }
CUDA_TOOLKIT_VERSION=13-4 CUDA_DISPLAY_VERSION=13.4 CUDA_CUDNN_SUFFIX=13-4
MOCK_INSTALLED_NVIDIA=$'installed libnvidia-compute-580 580.178.04-1ubuntu1\ninstalled nvidia-dkms-580-open 580.178.04-1ubuntu1\ninstalled nvidia-kernel-common-580 580.173.02-1ubuntu1\ninstalled unrelated-package 1'
dpkg-query() { printf '%s\n' "$MOCK_INSTALLED_NVIDIA"; }
apt-cache() {
    printf '%s\n' 'libnvidia-compute | 615.71.09-1ubuntu1 | repo' 'libnvidia-compute | 615.71.09-2ubuntu1 | repo' 'libnvidia-compute | 595.91.07-1ubuntu1 | repo'
}
PIN_INSTALLED=false
APT_CALLS=''
sudo() {
    APT_CALLS+="$*"$'\n'
    printf 'APT %s\n' "$*"
    if [[ "$*" == *cuda-toolkit* && "${DRIVER_VERSION}" == 595 && "$PIN_INSTALLED" != true ]]; then
        echo 'FAIL: 595 dependencies resolved before branch pin was installed' >&2
        return 1
    fi
    if [[ "$*" == 'apt-get install -V -y nvidia-driver-pinning-'* ]]; then
        PIN_INSTALLED=true
    fi
}
DRIVER_VERSION=615
GPU_STACK_INSTALLED_EARLY=false
KEYRING_CALLED=false
prepare_nvidia_driver_transition >/dev/null
[[ $KEYRING_CALLED == true && $APT_CALLS == *'apt-get --simulate install'* && $APT_CALLS == *'libnvidia-compute-580-'* && $APT_CALLS == *'nvidia-kernel-common-580-'* && $GPU_STACK_INSTALLED_EARLY == true ]] || { echo 'FAIL: complete driver transition not performed before bootstrap'; exit 1; }
output=$(install_nvidia_stack)
[[ $output == *'libnvidia-compute=615.71.09-2ubuntu1'* && $output == *'nvidia-dkms-open=615.71.09-2ubuntu1'* ]] || { echo 'FAIL: modern driver package names/version'; exit 1; }
[[ $output == *'libnvidia-compute-580-'* && $output == *'nvidia-dkms-580-open-'* && $output == *'nvidia-kernel-common-580-'* ]] || { echo 'FAIL: old driver packages not removed in apt transactions'; exit 1; }
[[ $output == *'nvidia-driver-pinning-615'* && $output != *'nvidia-utils-615'* ]]
[[ $output == *'cuda-toolkit-13-4'* && $output == *'cudnn9-cuda-13-4'* ]]
DRIVER_VERSION=595
output=$(install_nvidia_stack)
[[ $output == *'libnvidia-compute=595.91.07-1ubuntu1'* && $output != *'=615.'* ]]
DRIVER_VERSION=580
output=$(install_nvidia_stack)
[[ $output == *'libnvidia-compute-580'* && $output == *'nvidia-dkms-580-open'* && $output == *'nvidia-utils-580'* ]]
# A failed stack simulation may leave the pin installed, but must not install drivers.
DRIVER_VERSION=595
sudo() {
    printf 'APT %s\n' "$*"
    if [[ "$*" == *--simulate* && "$*" == *cuda-toolkit* ]]; then return 1; fi
    if [[ "$*" != *--simulate* && "$*" == *cuda-toolkit* ]]; then
        echo 'DRIVER INSTALL CALLED'
    fi
}
if output=$(install_nvidia_stack 2>&1); then echo 'FAIL: unresolved stack accepted'; exit 1; fi
[[ $output == *'apt-get install -V -y nvidia-driver-pinning-595'* ]]
[[ $output != *'DRIVER INSTALL CALLED'* ]]
DRIVER_VERSION=615
apt-cache() { :; }
if output=$(install_nvidia_stack 2>&1); then echo 'FAIL: missing branch accepted'; exit 1; fi
[[ $output != *'APT '* ]]
echo 'NVIDIA package selection checks passed'
