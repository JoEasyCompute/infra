#!/usr/bin/env bash
# Exercise selection and repository output without host changes or downloads.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
awk '
    /^(select_rocm_version|clear_amd_repo_files|install_rocm_repos)\(\) *\{/ { copying=1 }
    copying { print }
    copying && /^\}$/ { copying=0 }
' "$ROOT_DIR/install/amd-base-install.sh" > "$TEST_TMP/functions.sh"
source "$TEST_TMP/functions.sh"
info() { :; }; success() { :; }; section() { :; }
error() { echo "$*" >&2; exit 1; }
BOLD='' NC=''

check_selection() (
    UBUNTU_VERSION_ID=$1 ROCM_VERSION=$2 NON_INTERACTIVE=$3
    select_rocm_version <<< "$4" > /dev/null
    [[ "$ROCM_VERSION" == "$5" ]] || { echo "Wrong selection: $ROCM_VERSION (expected $5)" >&2; exit 1; }
)
for os in 22.04 24.04; do
    check_selection "$os" 10.0.0 true '' 10.0.0
    check_selection "$os" '' false 4 10.0.0
    check_selection "$os" '' true '' 7.2
    check_selection "$os" '' false 2 7.1
    check_selection "$os" '' false '' 7.2
    check_selection "$os" 7.2 true '' 7.2
    check_selection "$os" 7.1 true '' 7.1
    if (check_selection "$os" 99.0 true '' 99.0) 2>/dev/null; then
        echo 'Unknown release incorrectly accepted' >&2; exit 1
    fi
done
check_selection 26.04 '' true '' 7.13
if (check_selection 26.04 10.0.0 true '' 10.0.0) 2>/dev/null; then
    echo 'Stable release incorrectly accepted on preview OS' >&2; exit 1
fi

# Capture repository files; reject any unexpected privileged command.
sudo() {
    case "$1" in
        mkdir|rm) return 0 ;;
        tee) cat > "$TEST_TMP/$(basename "$2")" ;;
        *) echo "Unexpected sudo: $*" >&2; exit 1 ;;
    esac
}
wget() { printf 'test key'; }
gpg() {
    case "$*" in
        *--recv-keys*) return 0 ;;
        *--export*) printf 'driver key' ;;
        *) cat ;;
    esac
}
apt_get() { [[ "$*" == 'update -q' ]]; }
for spec in '22.04 jammy' '24.04 noble'; do
    read -r UBUNTU_VERSION_ID UBUNTU_CODENAME <<< "$spec"
    ROCM_VERSION=10.0.0
    install_rocm_repos
    grep -Fxq "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/amdgpu/31.50/ubuntu $UBUNTU_CODENAME main" "$TEST_TMP/amdgpu.list"
    distro=${UBUNTU_VERSION_ID/./}
    grep -Fxq "deb [arch=amd64 signed-by=/etc/apt/keyrings/amdrocm.gpg] https://stable.repo.amd.com/rocm/core/packages/ubuntu$distro stable main" "$TEST_TMP/rocm.list"
done
echo 'AMD version selection and repository tests passed'
