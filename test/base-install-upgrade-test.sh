#!/usr/bin/env bash
# Run without sourcing installer startup or touching the host's package manager.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/install/base-install.sh"
for fn in nvidia_driver_snapshot plan_nvidia_update check_nvidia_reboot install_nvidia_stack offer_reboot; do
    eval "$(awk -v name="$fn" '$0 == name "() {" {copy=1} copy {print} copy && /^}$/ {exit}' "$SCRIPT")"
done
info() { echo "$*"; }
warn() { echo "$*"; }
success() { echo "$*"; }
section() { :; }
print_gpu_stack_packages() { printf '%s\n' "$@"; }
error() { echo "$*" >&2; exit 1; }
dpkg-query() { printf '%s\n' "$MOCK_PACKAGES"; }
MOCK_PACKAGES=$'installed nvidia-dkms-580-open 580.1\nconfig-files nvidia-utils-575 575.1\ninstalled unrelated 1'
[[ $(nvidia_driver_snapshot) == 'nvidia-dkms-580-open 580.1' ]]
DRIVER_VERSION=610 CUDA_VERSION=13.3 CUDA_DISPLAY_VERSION=13.3
GPU_STACK_HOLD_DETECTED=false UNFREEZE_GPU_STACK=false
output=$(plan_nvidia_update)
[[ $output == *'APT will update'* ]]
GPU_STACK_HOLD_DETECTED=true
if (plan_nvidia_update) >/dev/null 2>&1; then
    echo 'FAIL: held stack accepted without unfreeze' >&2; exit 1
fi
UNFREEZE_GPU_STACK=true
plan_nvidia_update >/dev/null
# Override only the package snapshot for deterministic reboot tests on any host.
nvidia_driver_snapshot() { echo "$MOCK_SNAPSHOT"; }
modinfo() { return 1; }
NVIDIA_DRIVER_BEFORE='nvidia-dkms-580-open 580.1'
MOCK_SNAPSHOT=$NVIDIA_DRIVER_BEFORE
NVIDIA_REBOOT_REQUIRED=false
check_nvidia_reboot
[[ $NVIDIA_REBOOT_REQUIRED == false ]]
MOCK_SNAPSHOT='nvidia-dkms-610-open 610.1'
NVIDIA_REBOOT_REQUIRED=false
check_nvidia_reboot
[[ $NVIDIA_REBOOT_REQUIRED == true ]]
# nvidia-smi can work while an old module remains loaded.
nvidia-smi() { return 0; }
SKIP_GPU_STACK=false NON_INTERACTIVE=true GPU_STACK_HOLD_DETECTED=false
GPU_STACK_HOLD_AFTER_INSTALL=false UNFREEZE_GPU_STACK=false
BOLD='' NC='' GREEN='' LOG_FILE=/unused UBUNTU_VERSION_ID=24.04
output=$(offer_reboot)
[[ $output == *'reboot manually'* ]]
SKIP_GPU_STACK=true
output=$(offer_reboot)
[[ $output == *'Host tooling install complete'* && $output != *'reboot manually'* ]]
# Failed simulation must prevent the mutating apt transaction.
CUDA_TOOLKIT_VERSION=13-3 CUDA_CUDNN_SUFFIX=13
sudo() {
    if [[ "$*" == *--simulate* ]]; then return 1; fi
    echo 'MUTATING APT CALLED'; return 0
}
if output=$(install_nvidia_stack 2>&1); then
    echo 'FAIL: unresolved transaction accepted' >&2; exit 1
fi
[[ $output != *'MUTATING APT CALLED'* ]]
echo 'NVIDIA upgrade checks passed'
