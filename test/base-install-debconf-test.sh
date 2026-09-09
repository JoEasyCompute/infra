#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/install/base-install.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() {
    local needle="$1"
    grep -Fq -- "$needle" "$SCRIPT" || fail "missing: $needle"
}

require_text 'sudo env DEBIAN_FRONTEND=noninteractive apt-get install'
require_text 'keyboard-configuration keyboard-configuration/layout select English (UK)'
require_text 'keyboard-configuration keyboard-configuration/model select'
require_text 'keyboard-configuration keyboard-configuration/variant select'
require_text 'console-setup console-setup/charmap select UTF-8'
require_text 'debconf-set-selections'

echo "base-install debconf regression checks passed"
