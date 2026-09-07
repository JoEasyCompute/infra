#!/usr/bin/env bash
# Safe behavioral tests: filesystem moves are real; mounts and services are fake.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONVERTER="${SCRIPT_DIR}/../install/docker-storage-layout-convert.sh"

if [[ ${1:-} != --case ]]; then
    failures=0
    for case_name in runpod-to-default default-to-runpod dry-run-default dry-run-runpod late-collision symlink-collision reserved-directory; do
        if bash "$0" --case "$case_name"; then
            echo "PASS: $case_name"
        else
            echo "FAIL: $case_name" >&2
            failures=$((failures + 1))
        fi
    done
    [[ $failures -eq 0 ]]
    exit
fi

case_name=$2
set --
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/docker-storage-convert.XXXXXX")
trap 'rm -rf "$TEST_ROOT" "$TEST_ROOT-output"' EXIT
# Load definitions without invoking the CLI, root check, or any host operation.
awk '/^require_root_unless_status$/ { exit } { print }' "$CONVERTER" > "$TEST_ROOT/functions.sh"
source "$TEST_ROOT/functions.sh"
VOLUME="${TEST_ROOT}/volume"
CONTAINER_RUNTIME_MOUNT="${TEST_ROOT}/data/container-runtime"
DOCKER_MOUNTPOINT="${TEST_ROOT}/var/lib/docker"
CONTAINERD_MOUNTPOINT="${TEST_ROOT}/var/lib/containerd"
DEFAULT_DOCKER_DATA_DIR="${CONTAINER_RUNTIME_MOUNT}/docker"
DEFAULT_CONTAINERD_DATA_DIR="${CONTAINER_RUNTIME_MOUNT}/containerd"
RUNPOD_CONTAINERD_DATA_DIR="${DOCKER_MOUNTPOINT}/containerd"
DAEMON_JSON="${TEST_ROOT}/etc/docker/daemon.json"
FSTAB="${TEST_ROOT}/etc/fstab"
ASSUME_YES=true
mkdir -p "$VOLUME/containerd" "$(dirname "$DOCKER_MOUNTPOINT")" "$(dirname "$CONTAINER_RUNTIME_MOUNT")" "$(dirname "$DAEMON_JSON")"
printf '{"log-driver":"local","data-root":"original"}\n' > "$DAEMON_JSON"
printf '# unrelated entry\nUUID=os / ext4 defaults 0 1\n' > "$FSTAB"

# A symlink exposes the volume; remounting hides the underlying directory just
# like a real mount. No mount, systemctl, or privileged command is ever invoked.
mountpoint() { [[ $1 == -q && -L $2 ]]; }
systemctl() { [[ $1 == is-active || $1 == stop || $1 == start ]]; }
findmnt() {
    local target=${!#}
    [[ -L "$target" ]] || return 1
    readlink "$target"
}
umount() {
    [[ $# == 1 && $1 == "$TEST_ROOT/"* && -L $1 ]] || return 1
    rm "$1"
    if [[ -d "$1.underlying" ]]; then
        mv "$1.underlying" "$1"
    else
        mkdir "$1"
    fi
}
mount() {
    local target=$1 source
    [[ $# == 1 && $target == "$TEST_ROOT/"* ]] || return 1
    source=$(fstab_field_for_target "$target" 1)
    case "$source" in
        UUID=runtime|/images/runtime.img) source=$VOLUME ;;
        "$TEST_ROOT/"*) [[ -d "$source" ]] || return 1 ;;
        *) return 1 ;;
    esac
    [[ -d "$target" && ! -L "$target" ]] || return 1
    mv "$target" "$target.underlying"
    ln -s "$source" "$target"
}
# Implement only GNU sed's fstab-target deletion, including on macOS hosts.
sed() {
    [[ $# == 3 && $1 == -i && $3 == "$FSTAB" ]] || return 1
    python3 - "$2" "$3" <<'PY'
import re
import sys
expression, path = sys.argv[1:]
target = expression.split('[[:space:]]')[1]
with open(path) as handle:
    lines = handle.readlines()
with open(path, 'w') as handle:
    handle.writelines(line for line in lines if not re.search(r'\s' + re.escape(target) + r'\s', line))
PY
}

layout=default
case "$case_name" in
    runpod-to-default|dry-run-default|reserved-directory) layout=runpod ;;
esac
if [[ $layout == runpod ]]; then
    docker_data=$VOLUME
    ln -s "$VOLUME" "$DOCKER_MOUNTPOINT"
    mkdir "$CONTAINER_RUNTIME_MOUNT"
    printf '/images/runtime.img %s xfs loop,noatime,prjquota 0 2\n' "$DOCKER_MOUNTPOINT" >> "$FSTAB"
    printf '%s %s none bind,nofail 0 0\n' "$RUNPOD_CONTAINERD_DATA_DIR" "$CONTAINERD_MOUNTPOINT" >> "$FSTAB"
else
    docker_data=$VOLUME/docker
    mkdir "$docker_data"
    ln -s "$VOLUME" "$CONTAINER_RUNTIME_MOUNT"
    ln -s "$DEFAULT_DOCKER_DATA_DIR" "$DOCKER_MOUNTPOINT"
    printf 'UUID=runtime %s xfs defaults,noatime,prjquota 0 2\n' "$CONTAINER_RUNTIME_MOUNT" >> "$FSTAB"
    printf '%s %s none bind,nofail 0 0\n' "$DEFAULT_DOCKER_DATA_DIR" "$DOCKER_MOUNTPOINT" >> "$FSTAB"
    printf '%s %s none bind,nofail 0 0\n' "$DEFAULT_CONTAINERD_DATA_DIR" "$CONTAINERD_MOUNTPOINT" >> "$FSTAB"
fi
ln -s "$VOLUME/containerd" "$CONTAINERD_MOUNTPOINT"
mkdir "$docker_data/overlay2" "$VOLUME/lost+found"
printf 'image-layer\n' > "$docker_data/overlay2/layer"
printf 'hidden-state\n' > "$docker_data/.state"
printf 'containerd-state\n' > "$VOLUME/containerd/metadata"
printf 'recovered-data\n' > "$VOLUME/lost+found/recovered"
cp "$FSTAB" "$TEST_ROOT/original-fstab"

snapshot() {
    python3 - "$TEST_ROOT" "${1:-}" <<'PY'
import hashlib
import os
import sys
root = sys.argv[1]
for path, dirs, files in os.walk(root):
    dirs.sort()
    for name in sorted(dirs + files):
        full = os.path.join(path, name)
        if sys.argv[2] == 'ignore-backups' and '.layout-convert.' in name:
            continue
        value = os.readlink(full) if os.path.islink(full) else (
            hashlib.sha256(open(full, 'rb').read()).hexdigest() if os.path.isfile(full) else 'directory')
        print(os.path.relpath(full, root), value)
PY
}

case "$case_name" in
    late-collision) printf 'first\n' > "$docker_data/aaa"; mkdir "$docker_data/zzz" "$VOLUME/zzz" ;;
    symlink-collision) ln -s missing "$VOLUME/overlay2" ;;
    reserved-directory) mkdir "$VOLUME/docker"; printf 'existing\n' > "$VOLUME/docker/keep" ;;
    dry-run-*) DRY_RUN=true ;;
esac
before=$(snapshot)
set +e
(
    set -e
    if [[ $layout == runpod ]]; then
        convert_runpod_to_default
    else
        convert_default_to_runpod
    fi
) > "$TEST_ROOT-output" 2>&1
result=$?
set -e
output=$(cat "$TEST_ROOT-output")
rm "$TEST_ROOT-output"
case "$case_name" in
    *collision|reserved-directory)
        [[ $result -eq 1 && $output == *'Refusing'* ]] || { echo "Expected collision rejection: $output" >&2; exit 1; }
        [[ $(snapshot ignore-backups) == "$before" ]] || { echo 'Collision moved data or changed configuration' >&2; exit 1; }
        ;;
    dry-run-*)
        [[ $result -eq 0 ]] || { echo "$output" >&2; exit 1; }
        [[ $(snapshot) == "$before" ]] || { echo 'Dry run mutated filesystem' >&2; exit 1; }
        ;;
    *)
        [[ $result -eq 0 ]] || { echo "$output" >&2; exit 1; }
        [[ $(cat "$DOCKER_MOUNTPOINT/overlay2/layer" 2>/dev/null) == image-layer ]] || { echo 'Docker layer is missing after remount' >&2; exit 1; }
        [[ $(cat "$DOCKER_MOUNTPOINT/.state") == hidden-state ]]
        [[ $(cat "$CONTAINERD_MOUNTPOINT/metadata") == containerd-state ]]
        [[ $(cat "$VOLUME/lost+found/recovered") == recovered-data ]]
        [[ $(awk '$1 == "UUID=os" {print}' "$FSTAB") == 'UUID=os / ext4 defaults 0 1' ]]
        cmp "$TEST_ROOT/original-fstab" "$FSTAB".layout-convert.*.bak
        if [[ $layout == runpod ]]; then
            expected_root=$DEFAULT_DOCKER_DATA_DIR
            [[ $(fstab_line_for_target "$CONTAINER_RUNTIME_MOUNT") == "/images/runtime.img  $CONTAINER_RUNTIME_MOUNT  xfs  loop,noatime,prjquota  0  2" ]]
        else
            expected_root=$DOCKER_MOUNTPOINT
            [[ $(fstab_line_for_target "$DOCKER_MOUNTPOINT") == "UUID=runtime  $DOCKER_MOUNTPOINT  xfs  defaults,noatime,prjquota  0  2" ]]
        fi
        python3 - "$DAEMON_JSON" "$expected_root" <<'PY'
import json
import sys
with open(sys.argv[1]) as handle:
    assert json.load(handle) == {'log-driver': 'local', 'data-root': sys.argv[2]}
PY
        ;;
esac
