#!/usr/bin/env bash
# Convert the provisioner's loop-image layout from an independent rescue OS.
# Default mode is read-only. --apply removes the image and shrinks root ONLY
# after an external, checksum-verified Docker/containerd backup exists.
set -euo pipefail
export LC_ALL=C

ROOT_LV=""
BACKUP_DIR=""
APPLY=false
ROOT_MNT="" IMAGE_MNT="" DOCKER_MNT="" WORK="" BACKUP=""

fail() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }
usage() {
    cat <<'HELP'
Usage: sudo bash runpod-storage-rescue-convert.sh --root-lv /dev/VG/ubuntu-lv [OPTIONS]

Run from an independent rescue OS after a clean shutdown. Never run --apply
on the installed OS. EFI and /boot are not changed. Root becomes 500 GiB ext4;
all remaining VG space becomes docker-lv, XFS ftype=1 at /var/lib/docker.

  --root-lv DEVICE     Explicit existing ubuntu-lv (required; no guessing)
  --check              Read-only device/mount report (default; works while live)
  --backup-dir DIR     Existing directory on a mounted external ext4/XFS disk;
                      a new backup subdirectory is created and retained
  --apply             Perform offline conversion, including deleting the old
                      loop image AFTER verified external runtime backup
  -h, --help          Show help

Supported source: /var/lib/container-runtime.img mounted directly at
/var/lib/docker, with /var/lib/docker/containerd bound at /var/lib/containerd.
A full independent OS/disk backup is strongly recommended before maintenance.
There is no automatic rollback or reboot. After a failure, keep the backup and
inspect the reported stage; do not blindly rerun a partially completed resize.
HELP
}

assert_offline() {
    local mounts
    mounts=$(lsblk -nr -o MOUNTPOINTS "$ROOT_LV") || fail "Cannot inspect root LV mounts"
    [[ -z "${mounts//[[:space:]]/}" ]] || fail "Root LV is mounted or used as swap; boot rescue and unmount it first"
}

check_ext4() {
    local result=0
    e2fsck -f -p "$1" || result=$?
    (( result <= 1 )) || fail "e2fsck returned ${result}; repair the offline filesystem before continuing"
}

verify_copy() {
    local changes
    changes=$(rsync -aHAXSx --numeric-ids --checksum --dry-run --itemize-changes --delete "$1/" "$2/") ||
        fail "Copy verification scan failed; source is preserved"
    [[ -z "$changes" ]] || fail "Copy verification found differences; source is preserved: ${changes}"
}

assert_root_fits_without_image() {
    local used blocks links
    used=$(df -B1 --output=used "$1" | awk 'NR==2 {print $1}')
    blocks=$(stat -c %b "$2")
    links=$(stat -c %h "$2")
    [[ "$used" =~ ^[0-9]+$ && "$blocks" =~ ^[0-9]+$ && "$links" == 1 ]] || fail "Cannot safely estimate reclaimable image space (image must have one hard link)"
    (( used - blocks * 512 < 483183820800 )) || fail "Root excluding image uses at least 450 GiB; free OS space before conversion. Image is preserved."
}

shrink_root() {
    assert_offline
    check_ext4 "$ROOT_LV"
    info "Shrinking ext4 to 499 GiB, then root LV to 500 GiB"
    resize2fs "$ROOT_LV" 499G
    check_ext4 "$ROOT_LV"
    local geometry blocks block_size
    geometry=$(dumpe2fs -h "$ROOT_LV")
    blocks=$(awk '/^Block count:/ {print $3}' <<< "$geometry")
    block_size=$(awk '/^Block size:/ {print $3}' <<< "$geometry")
    [[ "$blocks" =~ ^[0-9]+$ && "$block_size" =~ ^[0-9]+$ ]] || fail "Cannot verify shrunken ext4 geometry"
    (( blocks > 0 && block_size > 0 && blocks * block_size < 536870912000 )) || fail "Filesystem does not fit safely in 500 GiB; LV reduction refused"
    lvreduce --yes -L 500G "$ROOT_LV"
    resize2fs "$ROOT_LV"
    check_ext4 "$ROOT_LV"
}

patch_boot_config() {
    python3 - "$1" "$2" <<'PY'
import json
import os
import pathlib
import sys
root, uuid = pathlib.Path(sys.argv[1]), sys.argv[2]
fstab = root / 'etc/fstab'
remove = {'/var/lib/docker', '/var/lib/containerd', '/data/container-runtime'}
lines = []
for line in fstab.read_text().splitlines():
    fields = line.split()
    if fields and not line.lstrip().startswith('#') and len(fields) >= 2:
        if fields[1] in remove:
            continue
    lines.append(line)
lines += [f'UUID={uuid} /var/lib/docker xfs defaults,noatime,prjquota,nofail 0 0',
          '/var/lib/docker/containerd /var/lib/containerd none bind,nofail 0 0']
# Keep unrelated root, EFI, boot and swap entries verbatim.
temp = fstab.with_name('fstab.runpod.tmp')
temp.write_text('\n'.join(lines) + '\n')
os.chmod(temp, fstab.stat().st_mode & 0o777)
os.replace(temp, fstab)
daemon = root / 'etc/docker/daemon.json'
config = json.loads(daemon.read_text()) if daemon.exists() else {}
config['data-root'] = '/var/lib/docker'
daemon.parent.mkdir(parents=True, exist_ok=True)
temp = daemon.with_name('daemon.json.runpod.tmp')
temp.write_text(json.dumps(config, indent=2) + '\n')
os.chmod(temp, (daemon.stat().st_mode & 0o777) if daemon.exists() else 0o644)
os.replace(temp, daemon)
PY
}

cleanup() {
    local result=$?
    trap - EXIT
    # Do not recursively delete work paths: an unmount could fail.
    for target in "$DOCKER_MNT" "$IMAGE_MNT" "$ROOT_MNT"; do
        if [[ -n "$target" ]] && mountpoint -q "$target"; then
            if ! umount "$target"; then
                echo "[WARN] Could not unmount ${target}" >&2
                result=1
            fi
        fi
    done
    [[ -z "$WORK" ]] || rmdir "$WORK/docker" "$WORK/image" "$WORK/root" "$WORK" 2>/dev/null || true
    if (( result != 0 )); then
        echo "[ERROR] Conversion stopped. Backup: ${BACKUP:-not yet created}. Do not reboot or rerun blindly; inspect disk and fstab state." >&2
    fi
    exit "$result"
}

inspect_devices() {
    [[ -b "$ROOT_LV" ]] || fail "Not a block device: ${ROOT_LV}"
    # Keep the LVM path: some LVM versions parse /dev/dm-N as a VG name.
    local name fstype
    name=$(lvs --noheadings -o lv_name "$ROOT_LV") || fail "Not an LVM LV"
    name=${name//[[:space:]]/}
    [[ "$name" == ubuntu-lv ]] || fail "Expected ubuntu-lv, got ${name}"
    VG=$(lvs --noheadings -o vg_name "$ROOT_LV") || fail "Cannot inspect root VG"
    VG=${VG//[[:space:]]/}
    [[ -n "$VG" ]] || fail "Empty VG name"
    fstype=$(blkid -s TYPE -o value "$ROOT_LV") || fail "Cannot inspect root filesystem"
    [[ "$fstype" == ext4 ]] || fail "Root must be ext4"
    lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS "$ROOT_LV"
    lvs -o lv_name,vg_name,lv_size,segtype "$VG"
    vgs "$VG"
}

validate_backup_disk() {
    [[ -d "$BACKUP_DIR" ]] || fail "--backup-dir must be an existing directory on external storage"
    BACKUP_DIR=$(readlink -f "$BACKUP_DIR")
    local source fstype options
    source=$(findmnt -n -o SOURCE -T "$BACKUP_DIR") || fail "Cannot inspect backup mount"
    fstype=$(findmnt -n -o FSTYPE -T "$BACKUP_DIR") || fail "Cannot inspect backup filesystem"
    options=$(findmnt -n -o OPTIONS -T "$BACKUP_DIR") || fail "Cannot inspect backup mount options"
    [[ "$fstype" == ext4 || "$fstype" == xfs ]] || fail "Backup needs a local ext4/XFS filesystem for ownership, hardlinks and xattrs"
    [[ ",$options," == *,rw,* ]] || fail "Backup filesystem is read-only"
    [[ -b "$source" ]] || fail "Backup must use an external block filesystem (no bind subdirectory, network or overlay mounts)"
    assert_independent_devices "$ROOT_LV" "$source"
}

assert_independent_devices() {
    local root_ancestors backup_ancestors types
    types=$(lsblk -snr -o TYPE "$2") || fail "Cannot inspect backup device types"
    # lsblk cannot follow a loop device through its backing file to the disk.
    if grep -Fxq loop <<< "$types" || ! grep -Fxq disk <<< "$types"; then
        fail "Backup needs an independent physical disk; loop-backed storage is unsupported"
    fi
    root_ancestors=$(lsblk -snr -o MAJ:MIN "$1") || fail "Cannot inspect root device ancestry"
    backup_ancestors=$(lsblk -snr -o MAJ:MIN "$2") || fail "Cannot inspect backup device ancestry"
    [[ -n "$root_ancestors" && -n "$backup_ancestors" ]] || fail "Empty device ancestry"
    local device
    while IFS= read -r device; do
        if grep -Fxq "$device" <<< "$root_ancestors"; then
            fail "Backup shares a physical device with root; use independent external storage"
        fi
    done <<< "$backup_ancestors"
}

convert_offline() {
    assert_offline
    [[ -z "$(swapon --show=NAME --noheadings)" ]] || fail "Disable swap in rescue before conversion"
    local count segments root_bytes
    count=$(lvs --noheadings -o lv_name "$VG" | awk 'NF {n++} END {print n+0}')
    [[ "$count" == 1 ]] || fail "Expected a root-only VG; additional LVs need manual planning"
    segments=$(lvs --noheadings -o segtype "$ROOT_LV")
    [[ "${segments//[[:space:]]/}" == linear ]] || fail "Only a simple linear root LV is supported"
    root_bytes=$(lvs --noheadings --units b --nosuffix -o lv_size "$ROOT_LV")
    awk 'NF==1 && $1 ~ /^[0-9]+([.][0-9]+)?$/ && $1 > 537944653824 {ok=1} END {exit !ok}' <<< "$root_bytes" ||
        fail "Root must be larger than 501 GiB; this is a full-root loop-image converter"
    validate_backup_disk
    check_ext4 "$ROOT_LV"
    WORK=$(mktemp -d /run/runpod-convert.XXXXXX)
    ROOT_MNT="$WORK/root" IMAGE_MNT="$WORK/image" DOCKER_MNT="$WORK/docker"
    mkdir "$ROOT_MNT" "$IMAGE_MNT" "$DOCKER_MNT"
    trap cleanup EXIT
    mount "$ROOT_LV" "$ROOT_MNT"
    local image="$ROOT_MNT/var/lib/container-runtime.img"
    [[ -f "$image" && ! -L "$image" ]] || fail "Expected regular loop image is missing"
    [[ "$(stat -c %d "$image")" == "$(stat -c %d "$ROOT_MNT")" ]] || fail "Image is not on root filesystem"
    # Recognize only the exact source layout observed on the reference host.
    python3 - "$ROOT_MNT" <<'PY'
import json
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
entries = [line.split() for line in (root / 'etc/fstab').read_text().splitlines()
           if line.strip() and not line.lstrip().startswith('#')]
docker = [e for e in entries if len(e) >= 4 and e[1] == '/var/lib/docker']
containerd = [e for e in entries if len(e) >= 4 and e[1] == '/var/lib/containerd']
assert len(docker) == 1 and docker[0][0] == '/var/lib/container-runtime.img' and docker[0][2] == 'xfs' and 'loop' in docker[0][3].split(','), 'Unsupported Docker fstab layout'
assert len(containerd) == 1 and containerd[0][0] == '/var/lib/docker/containerd' and 'bind' in containerd[0][3].split(','), 'Unsupported containerd fstab layout'
p = root / 'etc/docker/daemon.json'
cfg = json.loads(p.read_text()) if p.exists() else {}
assert cfg.get('data-root', '/var/lib/docker') == '/var/lib/docker', 'Unexpected Docker data-root'
assert cfg.get('storage-driver', 'overlay2') == 'overlay2', 'Only overlay2 is supported'
assert not cfg.get('storage-opts'), 'Custom overlay storage options require manual migration review'
assert not cfg.get('features', {}).get('containerd-snapshotter', False), 'Docker containerd snapshotter requires manual migration review'
PY
    [[ ! -L "$ROOT_MNT/var/lib/docker" && ! -L "$ROOT_MNT/var/lib/containerd" ]] || fail "Runtime targets must not be symlinks"
    # Hidden data would otherwise be silently ignored. Require empty underlying
    # target directories; the live inspection cannot see beneath these mounts.
    local target
    for target in "$ROOT_MNT/var/lib/docker" "$ROOT_MNT/var/lib/containerd"; do
        [[ ! -d "$target" || -z "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail "Hidden runtime data at ${target}; reconcile it manually first"
    done
    assert_root_fits_without_image "$ROOT_MNT" "$image"
    mount -t xfs -o loop,ro "$image" "$IMAGE_MNT"
    xfs_info "$IMAGE_MNT" | grep -Eq 'ftype=1([[:space:]]|$)' || fail "Source XFS requires ftype=1"
    [[ -d "$IMAGE_MNT/containerd" && ! -L "$IMAGE_MNT/containerd" ]] || fail "Missing containerd directory in image"
    local used available
    used=$(du -sx --block-size=1 "$IMAGE_MNT" | awk '{print $1}')
    available=$(df -B1 --output=avail "$BACKUP_DIR" | awk 'NR==2 {print $1}')
    (( available > used + used / 5 + 1073741824 )) || fail "External backup needs runtime usage plus 20% and 1 GiB free"
    umask 077
    BACKUP=$(mktemp -d "$BACKUP_DIR/runpod-convert.XXXXXX")
    mkdir "$BACKUP/runtime" "$BACKUP/config"
    cp -a "$ROOT_MNT/etc/fstab" "$BACKUP/config/fstab"
    [[ ! -f "$ROOT_MNT/etc/docker/daemon.json" ]] || cp -a "$ROOT_MNT/etc/docker/daemon.json" "$BACKUP/config/daemon.json"
    lvs --units b -o lv_name,vg_name,lv_size,devices > "$BACKUP/config/lvs.txt"
    vgcfgbackup -f "$BACKUP/config/vg.conf" "$VG"
    info "Backing up Docker/containerd to ${BACKUP}/runtime (this may take hours)"
    rsync -aHAXSx --numeric-ids --info=progress2 "$IMAGE_MNT/" "$BACKUP/runtime/"
    verify_copy "$IMAGE_MNT" "$BACKUP/runtime"
    sync
    touch "$BACKUP/BACKUP-VERIFIED"
    umount "$IMAGE_MNT"
    # First irreversible data change. External verified data remains untouched.
    info "Backup verified. Removing root-disk loop image before shrinking root"
    rm -- "$image"
    sync
    used=$(df -B1 --output=used "$ROOT_MNT" | awk 'NR==2 {print $1}')
    (( used < 483183820800 )) || fail "Root still uses at least 450 GiB; free space offline before resizing. Runtime backup retained."
    umount "$ROOT_MNT"
    shrink_root
    local docker_lv="/dev/${VG}/docker-lv" uuid
    lvcreate -l 100%FREE -n docker-lv "$VG"
    mkfs.xfs -n ftype=1 "$docker_lv"
    mount "$ROOT_LV" "$ROOT_MNT"
    mount -t xfs -o noatime,prjquota "$docker_lv" "$DOCKER_MNT"
    info "Restoring Docker/containerd from verified external backup"
    rsync -aHAXSx --numeric-ids --info=progress2 "$BACKUP/runtime/" "$DOCKER_MNT/"
    verify_copy "$BACKUP/runtime" "$DOCKER_MNT"
    uuid=$(blkid -s UUID -o value "$docker_lv")
    [[ -n "$uuid" ]] || fail "New docker-lv has no UUID"
    mkdir -p "$ROOT_MNT/var/lib/docker" "$ROOT_MNT/var/lib/containerd"
    patch_boot_config "$ROOT_MNT" "$uuid"
    findmnt --verify --tab-file "$ROOT_MNT/etc/fstab" --target-prefix "$ROOT_MNT"
    sync
    touch "$BACKUP/CONVERSION-COMPLETE"
    info "Conversion complete. External backup retained at ${BACKUP}"
    info "EFI and /boot unchanged. Reboot manually to installed OS, then verify mounts, Docker and GPUs."
}

main() {
    while (( $# )); do
        case "$1" in
            --root-lv|--backup-dir)
                (( $# >= 2 )) && [[ -n "$2" && "$2" != --* ]] || fail "$1 requires a value"
                if [[ "$1" == --root-lv ]]; then ROOT_LV="$2"; else BACKUP_DIR="$2"; fi
                shift ;;
            --check) APPLY=false ;;
            --apply) APPLY=true ;;
            -h|--help) usage; return 0 ;;
            *) fail "Unknown argument: $1" ;;
        esac
        shift
    done
    [[ -n "$ROOT_LV" ]] || fail "Specify --root-lv explicitly (see --help)"
    (( EUID == 0 )) || fail "Run with sudo for accurate device inspection"
    local tool
    for tool in lvs vgs lsblk blkid readlink; do command -v "$tool" >/dev/null || fail "Missing tool: $tool"; done
    inspect_devices
    if [[ "$APPLY" != true ]]; then
        info "Read-only check complete. --apply requires independent rescue boot, unmounted root and --backup-dir."
        return 0
    fi
    for tool in e2fsck dumpe2fs resize2fs lvreduce lvcreate vgcfgbackup mkfs.xfs xfs_info rsync python3 mount umount mountpoint findmnt swapon stat du df sync; do
        command -v "$tool" >/dev/null || fail "Missing rescue tool: $tool"
    done
    convert_offline
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then main "$@"; fi
