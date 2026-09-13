#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
source /dev/stdin <<< "$(awk '/^(amd_installed_packages|prepare_amd_upgrade|amd_driver_version|amd_reboot_required)\(\) *\{/ { copy=1 } copy { print } copy && /^\}$/ { copy=0 }' "$ROOT_DIR/install/amd-base-install.sh")"
info() { :; }; warn() { :; }; success() { :; }
error() { echo "$*" >&2; exit 1; }
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
AMD_REINSTALL_MARKER="$TEST_TMP/boot"
ROCM_VERSION=10.0.0 NON_INTERACTIVE=true REPLACE_GPU_STACK=false
dpkg-query() { printf '%s\n' "$FIXTURE"; }
apt-mark() { :; }
FIXTURE='ii  amdrocm10.0 10.0.0-4'
prepare_amd_upgrade
FIXTURE='hi  amdrocm10.0 10.0.0-4'
apt-mark() { echo amdrocm10.0; }
if (prepare_amd_upgrade); then echo 'Held installed package must block update' >&2; exit 1; fi
apt-mark() { :; }
FIXTURE='ii  rocm-core 7.2.0.70200-1'
if (prepare_amd_upgrade); then echo 'Legacy migration should require explicit replacement' >&2; exit 1; fi
FIXTURE='ii  amdrocm10.0 10.0.0-4'
ROCM_VERSION=7.2
if (prepare_amd_upgrade); then echo 'Reverse migration should require explicit replacement' >&2; exit 1; fi
FIXTURE='rc  rocm-core 7.2.0.70200-1'
prepare_amd_upgrade
GPU_DRIVER_CHANGED=true
amd_reboot_required || { echo 'Changed driver requires reboot' >&2; exit 1; }

# A successful status command must not hide a loaded/on-disk driver mismatch.
GPU_DRIVER_CHANGED=false
cat() {
    case "$1" in
        /sys/module/amdgpu/version) echo old ;;
        /proc/sys/kernel/random/boot_id) echo current-boot ;;
        *) command cat "$@" ;;
    esac
}
modinfo() { echo new; }
amd_reboot_required || { echo 'Loaded driver mismatch requires reboot' >&2; exit 1; }
modinfo() { echo old; }
if amd_reboot_required; then echo 'Unchanged driver should not require reboot' >&2; exit 1; fi
printf 'current-boot\n' > "$AMD_REINSTALL_MARKER"
if (prepare_amd_upgrade); then echo 'Same-boot reinstall must be blocked' >&2; exit 1; fi
printf 'previous-boot\n' > "$AMD_REINSTALL_MARKER"
sudo() { "$@"; }
FIXTURE=''
prepare_amd_upgrade
[[ ! -f "$AMD_REINSTALL_MARKER" ]] || { echo 'Completed reboot marker not cleared' >&2; exit 1; }

# Replacement purges explicit package names and stops before installation.
FIXTURE=$'ii  rocm-core 7.2.0.70200-1\nii  amdgpu-dkms 6.16.1\nii  chrony 4.0'
REPLACE_GPU_STACK=true
apt_get() { printf '%s\n' "$*" >> "$TEST_TMP/apt-trace"; }
(prepare_amd_upgrade)
grep -Fxq 'purge -y rocm-core amdgpu-dkms' "$TEST_TMP/apt-trace"
[[ -f "$AMD_REINSTALL_MARKER" ]] || { echo 'Replacement must save reboot marker' >&2; exit 1; }
echo 'AMD upgrade checks passed'
