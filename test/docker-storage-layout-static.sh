#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER_INSTALL="${ROOT_DIR}/install/docker-install.sh"
PROVISION="${ROOT_DIR}/install/provision.sh"
PROVISION_AMD="${ROOT_DIR}/install/provision-amd.sh"

require_help_option() {
    local script="$1"
    local option="$2"

    if ! bash "$script" --help | grep -Fq -- "$option"; then
        echo "Missing ${option} in ${script} --help" >&2
        return 1
    fi
}

require_source_text() {
    local file="$1"
    local text="$2"

    if ! grep -Fq -- "$text" "$file"; then
        echo "Missing expected text in ${file}: ${text}" >&2
        return 1
    fi
}

require_help_option "$DOCKER_INSTALL" "--runpod-storage-layout"
require_help_option "$PROVISION" "--runpod-storage-layout"
require_help_option "$PROVISION_AMD" "--runpod-storage-layout"

require_source_text "$DOCKER_INSTALL" 'DOCKER_DATA_DIR="${DOCKER_MOUNTPOINT}"'
require_source_text "$DOCKER_INSTALL" 'CONTAINERD_DATA_DIR="${DOCKER_MOUNTPOINT}/containerd"'
require_source_text "$DOCKER_INSTALL" "UUID=\${uuid}  \${DOCKER_MOUNTPOINT}  xfs  defaults,noatime,nofail,prjquota  0  2"
require_source_text "$DOCKER_INSTALL" "\${CONTAINERD_DATA_DIR}  \${CONTAINERD_MOUNTPOINT}  none  bind,nofail  0  0"
require_source_text "$PROVISION" "RUNPOD_STORAGE_LAYOUT"
require_source_text "$PROVISION_AMD" "RUNPOD_STORAGE_LAYOUT"
