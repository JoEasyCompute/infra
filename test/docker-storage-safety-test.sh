#!/usr/bin/env bash
# Host-independent storage-selection regression tests. All host inspection and
# destructive operations are mocked; only extracted installer functions run.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
awk '
    /^(lvm_gib_to_int|disk_is_unused|phase_disk_setup)\(\) *\{/ { copying=1 }
    copying { print }
    copying && /^\}$/ { copying=0 }
' "$REPO_ROOT/install/docker-install.sh" > "$TEST_TMP/functions.sh"

run_case() (
    set -euo pipefail
    . "$TEST_TMP/functions.sh"
    local scenario="$1"
    local trace="$TEST_TMP/$scenario.trace"
    : > "$trace"
    FORCE_DISK="" FORCE_VG="" NON_INTERACTIVE=true
    CONTAINER_RUNTIME_MOUNT=/mock/runtime
    LOOPBACK_IMG=/mock/runtime.img LOOPBACK_IMG_PCT=80
    MIN_ROOT_FREE_GB=20 LVM_USE_PCT=80
    BOLD="" RESET="" YELLOW=""
    case "$scenario" in
        forced_vg|invalid_vg|full_vg|existing_lv|vg_probe_failure|lvcreate_failure|mounted_target|malformed_vg) FORCE_VG=chosen-vg ;;
        forced_disk|unsafe_forced_disk|invalid_disk|partition_target|conflicting_flags|disk_probe_failure) FORCE_DISK=/dev/chosen ;;
    esac
    [[ "$scenario" != conflicting_flags ]] || FORCE_VG=chosen-vg
    info() { :; }; success() { :; }; warn() { :; }; error() { echo "$*" >&2; }
    confirm() { return 0; }
    mountpoint() { [[ "$scenario" == mounted_target ]]; }
    _ensure_subdirs_and_bind_mounts() { echo reused_mount >> "$trace"; }
    # Mock the block-device predicate while retaining ordinary test semantics.
    test() {
        if [[ "${1:-}" == -b ]]; then
            [[ "$scenario" != invalid_disk && "$2" == /dev/* ]]
        else builtin test "$@"; fi
    }
    lsblk() {
        local args="$*" target="${!#}"
        case "$args" in
            '-dno NAME,TYPE')
                [[ "$scenario" != enumeration_failure ]] || return 1
                case "$scenario" in
                    forced_disk) echo 'other disk' ;;
                    invalid_disk) : ;;
                    *) echo 'chosen disk' ;;
                esac
                ;;
            *SIZE*) echo 1073741824000 ;;
            *TYPE*)
                [[ "$scenario" != disk_probe_failure ]] || return 1
                if [[ "$scenario" == partition_target ]]; then echo part; else echo disk; fi
                ;;
            *MOUNTPOINT*)
                [[ "$scenario" != mount_probe_failure ]] || return 1
                [[ "$scenario" != mounted_disk ]] || echo /in-use
                ;;
            *NAME*)
                [[ "$scenario" != topology_probe_failure ]] || return 1
                echo "${target##*/}"
                case "$scenario" in partitioned_disk) echo chosen1 ;; held_disk) echo dm-0 ;; esac
                ;;
            *) echo "Unexpected lsblk: $*" >&2; return 90 ;;
        esac
        return 0
    }
    wipefs() {
        [[ "$scenario" != signature_probe_failure ]] || return 1
        case "$scenario" in
            whole_filesystem|unsafe_forced_disk) echo xfs ;;
            raid_signature) echo linux_raid_member ;;
            lvm_signature) echo LVM2_member ;;
        esac
        return 0
    }
    blkid() {
        case "$scenario" in
            blkid_signature) echo 'TYPE="ext4"'; return 0 ;;
            blkid_probe_failure) return 4 ;;
            ambiguous_signature) return 8 ;;
        esac
        return 2
    }
    vgs() {
        case "$scenario" in
            vg_probe_failure) return 1 ;;
            invalid_vg) return 5 ;;
            full_vg) echo 0 ;;
            malformed_vg) echo '1000 broken' ;;
            *) if [[ "$*" == *--nosuffix* ]]; then echo 1000; else echo 'chosen-vg 1000g'; fi ;;
        esac
    }
    lvdisplay() { [[ "$scenario" == existing_lv ]]; }
    lvcreate() { [[ "$scenario" != lvcreate_failure ]] || return 5; echo "lvcreate $*" >> "$trace"; }
    mkfs.xfs() { echo "mkfs $*" >> "$trace"; exit 70; }
    # Hard stops ensure no test can reach actual mounting or fstab writes.
    mount() { echo 'UNEXPECTED mount' >> "$trace"; exit 91; }
    apt-get() { echo 'UNEXPECTED apt-get' >> "$trace"; exit 91; }
    df() { :; }
    free_gb_on_mount() { echo 100; }
    _provision_loopback_image() { echo loopback >> "$trace"; exit 71; }
    phase_disk_setup
)

failures=0
check() {
    local scenario="$1" expected="$2" status=0 trace
    run_case "$scenario" > "$TEST_TMP/$scenario.output" 2>&1 || status=$?
    trace=$(cat "$TEST_TMP/$scenario.trace")
    case "$expected" in
        disk) [[ "$trace" != *'mkfs -f '* && $status == 70 && "$trace" == *' /dev/chosen' && "$trace" != *lvcreate* ]] ;;
        vg) [[ "$trace" != *'mkfs -f '* && $status == 70 && "$trace" == *'lvcreate -l 80%FREE -n container_rt chosen-vg'* && "$trace" == *' /dev/chosen-vg/container_rt'* ]] ;;
        no_disk) [[ "$trace" != *' /dev/chosen' && "$trace" != *'UNEXPECTED'* && $status != 0 ]] ;;
        reused) [[ $status == 0 && "$trace" == reused_mount ]] ;;
        abort) [[ $status != 0 && $status != 70 && $status != 71 && -z "$trace" ]] ;;
    esac && { echo "PASS $scenario"; return; }
    echo "FAIL $scenario: expected $expected, exit=$status, operations=[$trace]"
    cat "$TEST_TMP/$scenario.output"
    failures=$((failures + 1))
}

check blank_disk disk
check forced_disk disk
check forced_vg vg
check mounted_target reused
for scenario in whole_filesystem raid_signature lvm_signature blkid_signature ambiguous_signature mounted_disk partitioned_disk held_disk signature_probe_failure blkid_probe_failure mount_probe_failure topology_probe_failure; do
    check "$scenario" no_disk
done
for scenario in unsafe_forced_disk invalid_disk partition_target conflicting_flags invalid_vg full_vg existing_lv vg_probe_failure disk_probe_failure enumeration_failure lvcreate_failure malformed_vg; do
    check "$scenario" abort
done
if (( failures > 0 )); then
    echo "$failures storage safety regression(s) failed"
    exit 1
fi
echo 'All storage safety regressions passed (no root, format, or mount operations).'
