#!/usr/bin/env bash
# Exercise both unattended defaults and interactive blank/explicit choices.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for fn in select_driver_version select_cuda_version; do
    eval "$(awk -v name="$fn" '$0 == name "() {" {copy=1} copy {print} copy && /^}$/ {exit}' "$ROOT_DIR/install/base-install.sh")"
done
success() { :; }
error() { echo "$*" >&2; exit 1; }
BOLD='' NC=''
for NON_INTERACTIVE in true false; do
    DRIVER_VERSION='' CUDA_VERSION=''
    select_driver_version <<< '' >/dev/null
    select_cuda_version <<< '' >/dev/null
    [[ $DRIVER_VERSION == 620 ]] || { echo 'FAIL: default driver must be 620'; exit 1; }
    [[ $CUDA_TOOLKIT_VERSION == 13-4 && $CUDA_DISPLAY_VERSION == 13.4 && $CUDA_MAJOR == 13 && $CUDA_CUDNN_SUFFIX == 13-4 ]] || { echo 'FAIL: default CUDA must be 13.4'; exit 1; }
done
NON_INTERACTIVE=false DRIVER_VERSION='' CUDA_VERSION=''
select_driver_version <<< '2' >/dev/null
select_cuda_version <<< '1' >/dev/null
[[ $DRIVER_VERSION == 580 && $CUDA_TOOLKIT_VERSION == 12-9 && $CUDA_CUDNN_SUFFIX == 12 ]]
NON_INTERACTIVE=true DRIVER_VERSION=615 CUDA_VERSION=13
select_driver_version >/dev/null
select_cuda_version >/dev/null
[[ $DRIVER_VERSION == 615 && $CUDA_TOOLKIT_VERSION == 13 && $CUDA_CUDNN_SUFFIX == 13 ]]
echo 'NVIDIA default selection checks passed'
