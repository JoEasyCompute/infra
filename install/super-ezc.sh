#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${script_dir}/console-autologin.sh"

if [[ ! -x "${target}" ]]; then
    echo "Missing helper: ${target}" >&2
    exit 1
fi

if [[ $# -gt 0 ]]; then
    exec "${target}" "$@"
fi

echo "super-ezc.sh is deprecated; use install/console-autologin.sh instead." >&2
exec "${target}" --enable --user ezc
