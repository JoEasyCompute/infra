#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/install/base-install.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() {
    local needle="$1"
    grep -Fq -- "$needle" "$SCRIPT" || fail "missing: $needle"
}

require_text 'apt_get_noninteractive() {'
eval "$(awk '$0 == "apt_get_noninteractive() {" {copy=1} copy {print} copy && /^}$/ {exit}' "$SCRIPT")"
sudo() { printf '%s\n' "$*"; }
[[ $(apt_get_noninteractive install keyboard-configuration) == 'env DEBIAN_FRONTEND=noninteractive apt-get install keyboard-configuration' ]] \
    || fail 'apt transactions must always use the noninteractive debconf frontend'

if awk '
    /^[[:space:]]*sudo env DEBIAN_FRONTEND=noninteractive apt-get / {next}
    /^[[:space:]]*(sudo )?apt-get / {print; failed=1}
    END {exit !failed}
' "$SCRIPT" | grep -q .; then
    fail 'found an apt-get invocation outside the noninteractive wrapper'
fi

require_text 'keyboard-configuration keyboard-configuration/layout select English (UK)'
require_text 'keyboard-configuration keyboard-configuration/model select'
require_text 'keyboard-configuration keyboard-configuration/variant select'
require_text 'console-setup console-setup/charmap select UTF-8'
require_text 'debconf-set-selections'

echo "base-install debconf regression checks passed"
