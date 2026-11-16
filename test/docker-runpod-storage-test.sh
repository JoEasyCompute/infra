#!/usr/bin/env bash
# No host mutations: exercise extracted RunPod setup with mocked inspections.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
awk '/^(_runpod_root_vg|_runpod_grow_root|_runpod_verify_volume|_runpod_disk_setup)\(\)/ {copying=1} copying {print} copying && /^\}$/ {copying=0}' "$ROOT/install/docker-install.sh" > "$TMP/functions"
for scenario in fresh small_root full_root loop small_loop existing wrong_fs wrong_vg insufficient_space malformed_space extend_failure resize_failure; do
    status=0
    (
        set -euo pipefail
        source "$TMP/functions"
        FORCE_DISK='' FORCE_VG='' DOCKER_MOUNTPOINT=/var/lib/docker
        MIN_CONTAINER_VOL_GB=100 ROOT_GROWN=false
        info() { :; }; error() { echo "$*" >&2; }; success() { :; }
        findmnt() { if [[ "$*" == *FSTYPE* ]]; then echo ext4; else echo /dev/mapper/ubuntu--vg-ubuntu--lv; fi; }
        lvs() {
            case "$*" in
                *lv_size*) if [[ "$scenario" == full_root ]]; then echo 2000000000000
                    elif [[ "$ROOT_GROWN" == true ]]; then echo 536870912000
                    elif [[ "$scenario" == small_root || "$scenario" == small_loop || "$scenario" == insufficient_space || "$scenario" == malformed_space || "$scenario" == extend_failure || "$scenario" == resize_failure ]]; then echo 107374182400
                    else echo 536870912000; fi ;;
                *lv_name*) echo ubuntu-lv ;;
                *vg_name*) echo ubuntu-vg ;;
                *) [[ "$scenario" == existing || "$scenario" == wrong_fs ]] ;;
            esac
        }
        vgs() {
            if [[ "$*" == *vg_extent_size* ]]; then
                if [[ "$scenario" == insufficient_space ]]; then echo '4194304 100'
                elif [[ "$scenario" == malformed_space ]]; then echo broken
                else echo '4194304 1000000'; fi
            else echo 100000; fi
        }
        lvextend() { echo "GROW $*"; [[ "$scenario" != extend_failure ]] || return 1; ROOT_GROWN=true; }
        resize2fs() { echo "FS_GROW $*"; [[ "$scenario" != resize_failure ]]; }
        mountpoint() { [[ "$scenario" == loop || "$scenario" == small_loop ]]; }
        lsblk() { echo loop; }
        blkid() { if [[ "$scenario" == wrong_fs ]]; then echo ext4; else echo xfs; fi; }
        lvcreate() { echo "CREATE $*"; }
        mkfs.xfs() { echo "FORMAT $*"; exit 70; }
        _runpod_verify_volume() { echo VERIFY; return 1; }
        [[ "$scenario" != wrong_vg ]] || FORCE_VG=other
        _runpod_disk_setup
    ) > "$TMP/$scenario" 2>&1 || status=$?
    case "$scenario" in
        fresh|small_root) [[ $status == 70 ]] && grep -q 'CREATE -l 100%FREE -n docker-lv ubuntu-vg' "$TMP/$scenario" && grep -q -- '-n ftype=1' "$TMP/$scenario" ;;
        *) [[ $status != 0 ]] && ! grep -Eq 'CREATE|FORMAT' "$TMP/$scenario" ;;
    esac || { cat "$TMP/$scenario"; echo "FAIL $scenario ($status)"; exit 1; }
    if [[ "$scenario" == small_root ]]; then
        grep -q 'GROW -L 500G' "$TMP/$scenario"
        grep -q FS_GROW "$TMP/$scenario"
        [[ "$(grep -n GROW "$TMP/$scenario" | tail -1 | cut -d: -f1)" -lt "$(grep -n CREATE "$TMP/$scenario" | cut -d: -f1)" ]]
    fi
    if [[ "$scenario" == small_loop || "$scenario" == insufficient_space || "$scenario" == malformed_space ]]; then
        ! grep -q '^GROW' "$TMP/$scenario"
    fi
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
