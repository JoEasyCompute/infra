#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONVERTER="${ROOT_DIR}/install/docker-storage-layout-convert.sh"
DOCS="${ROOT_DIR}/docs/docker-install.md"

require_file() {
    local file="$1"
    [[ -f "$file" ]] || { echo "Missing file: $file" >&2; return 1; }
}

require_help_option() {
    local option="$1"
    if ! bash "$CONVERTER" --help | grep -Fq -- "$option"; then
        echo "Missing ${option} in converter --help" >&2
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

require_file "$CONVERTER"
require_help_option "--to runpod"
require_help_option "--to default"
require_help_option "--dry-run"
require_help_option "--no-start"
require_help_option "--status"

require_source_text "$CONVERTER" "convert_default_to_runpod()"
require_source_text "$CONVERTER" "convert_runpod_to_default()"
require_source_text "$CONVERTER" "set_daemon_data_root"
require_source_text "$CONVERTER" "UUID="
require_source_text "$CONVERTER" '${RUNPOD_CONTAINERD_DATA_DIR}  ${CONTAINERD_MOUNTPOINT}  none  bind,nofail  0  0'
require_source_text "$DOCS" "docker-storage-layout-convert.sh"
