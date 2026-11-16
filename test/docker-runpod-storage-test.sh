#!/usr/bin/env bash
# No host mutations: exercise extracted RunPod setup with mocked inspections.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
awk '/^(_runpod_root_vg|_runpod_verify_volume|_runpod_disk_setup)\(\)/ {copying=1} copying {print} copying && /^\}$/ {copying=0}' "$ROOT/install/docker-install.sh" > "$TMP/functions"
for scenario in fresh full_root loop existing wrong_fs wrong_vg; do
    status=0
    (
        set -euo pipefail
        source "$TMP/functions"
        FORCE_DISK='' FORCE_VG='' DOCKER_MOUNTPOINT=/var/lib/docker
        info() { :; }; error() { echo "$*" >&2; }; success() { :; }
        findmnt() { if [[ "$*" == *FSTYPE* ]]; then echo ext4; else echo /dev/mapper/ubuntu--vg-ubuntu--lv; fi; }
        lvs() {
            case "$*" in
                *lv_size*) if [[ "$scenario" == full_root ]]; then echo 2000000000000; else echo 536870912000; fi ;;
                *lv_name*) echo ubuntu-lv ;;
                *vg_name*) echo ubuntu-vg ;;
                *) [[ "$scenario" == existing || "$scenario" == wrong_fs ]] ;;
            esac
        }
        vgs() { echo 100000; }
        mountpoint() { [[ "$scenario" == loop ]]; }
        lsblk() { echo loop; }
        blkid() { if [[ "$scenario" == wrong_fs ]]; then echo ext4; else echo xfs; fi; }
        lvcreate() { echo "CREATE $*"; }
        mkfs.xfs() { echo "FORMAT $*"; exit 70; }
        _runpod_verify_volume() { echo VERIFY; return 1; }
        [[ "$scenario" != wrong_vg ]] || FORCE_VG=other
        _runpod_disk_setup
    ) > "$TMP/$scenario" 2>&1 || status=$?
    case "$scenario" in
        fresh) [[ $status == 70 ]] && grep -q 'CREATE -l 100%FREE -n docker-lv ubuntu-vg' "$TMP/$scenario" && grep -q -- '-n ftype=1' "$TMP/$scenario" ;;
        *) [[ $status != 0 ]] && ! grep -Eq 'CREATE|FORMAT' "$TMP/$scenario" ;;
    esac || { cat "$TMP/$scenario"; echo "FAIL $scenario ($status)"; exit 1; }
    echo "PASS $scenario"
done
for scenario in valid wrong_fs no_ftype wrong_uuid bind_root no_quota; do
    status=0
    (
        source "$TMP/functions"
        DOCKER_MOUNTPOINT=/var/lib/docker
        error() { :; }
        blkid() {
            if [[ "$*" == *TYPE* ]]; then
                if [[ "$scenario" == wrong_fs ]]; then echo ext4; else echo xfs; fi
            else echo test-uuid; fi
        }
        xfs_info() { if [[ "$scenario" == no_ftype ]]; then echo ftype=0; else echo 'naming =version 2 ftype=1'; fi; }
        mountpoint() { return 0; }
        findmnt() {
            case "$*" in
                *UUID*) if [[ "$scenario" == wrong_uuid ]]; then echo other; else echo test-uuid; fi ;;
                *FSROOT*) if [[ "$scenario" == bind_root ]]; then echo /subdir; else echo /; fi ;;
                *OPTIONS*) if [[ "$scenario" == no_quota ]]; then echo rw,noatime; else echo rw,prjquota; fi ;;
            esac
        }
        _runpod_verify_volume /dev/mock/docker-lv
    ) || status=$?
    if [[ "$scenario" == valid ]]; then [[ $status == 0 ]]; else [[ $status != 0 ]]; fi
    echo "PASS verify_$scenario"
done
