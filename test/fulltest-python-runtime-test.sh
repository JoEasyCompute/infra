#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FULLTEST="$ROOT_DIR/test/fulltest.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

load_fulltest_defs() {
    local tmp_dir="$1"
    local defs="$tmp_dir/fulltest-defs.sh"

    mkdir -p "$tmp_dir"
    awk '/^# Two-pass parse:/ { exit } { print }' "$FULLTEST" > "$defs"
    # shellcheck source=/dev/null
    source "$defs" >/dev/null
}

test_rebuilds_stale_pytorch_venv() {
    local tmp_dir="$1"
    load_fulltest_defs "$tmp_dir"

    local fake_python="$tmp_dir/python3.11"
    local venv_dir="$tmp_dir/pytorch-venv"
    PYTORCH_VENV="$venv_dir"
    PIP_EXTRA=""

    cat > "$fake_python" <<'PYEOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-m" ] && [ "${2:-}" = "venv" ]; then
    venv_dir="$3"
    mkdir -p "$venv_dir/bin"
    cat > "$venv_dir/bin/python" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "-c" ]; then
    exit 0
fi
if [ "\${1:-}" = "-m" ] && [ "\${2:-}" = "pip" ]; then
    exit 0
fi
exit 1
EOF
    chmod +x "$venv_dir/bin/python"
    echo "created-by-selected-python" > "$venv_dir/runtime-marker"
    exit 0
fi
if [ "${1:-}" = "-c" ]; then
    exit 0
fi
exit 1
PYEOF
    chmod +x "$fake_python"

    mkdir -p "$venv_dir/bin"
    cat > "$venv_dir/bin/python" <<'PYEOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-c" ]; then
    exit 1
fi
if [ "${1:-}" = "-m" ] && [ "${2:-}" = "pip" ]; then
    echo "stale-venv-was-used" > "$(dirname "$0")/../runtime-marker"
    exit 0
fi
exit 1
PYEOF
    chmod +x "$venv_dir/bin/python"

    ensure_pytorch_venv "$fake_python" "$venv_dir"

    local marker
    marker="$(cat "$venv_dir/runtime-marker" 2>/dev/null || true)"
    [ "$marker" = "created-by-selected-python" ] \
        || fail "stale PyTorch venv was reused instead of rebuilt"
}

test_standalone_allows_system_python312() {
    local tmp_dir="$1"
    load_fulltest_defs "$tmp_dir"

    local fake_bin="$tmp_dir/bin"
    local found_file="$tmp_dir/found-python"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/python3" <<'PYEOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-c" ]; then
    code="${2:-}"
    case "$code" in
        *"3, 12"*|*">= (3, 10)"*|*">= (3,10)"*) exit 0 ;;
        *) exit 1 ;;
    esac
fi
exit 1
PYEOF
    chmod +x "$fake_bin/python3"

    INFRA_PYTHON_BENCH=""
    PATH="$fake_bin:/usr/bin:/bin" find_benchmark_python >"$found_file"
    local found
    found="$(cat "$found_file")"
    [ "$found" = "$fake_bin/python3" ] \
        || fail "standalone Python 3.12 fallback was not selected"
}

main() {
    local tmp_dir
    tmp_dir="$(mktemp -d /tmp/fulltest-python-runtime.XXXXXX)"
    trap "rm -rf '$tmp_dir'" EXIT

    ( test_rebuilds_stale_pytorch_venv "$tmp_dir/stale-venv" )
    rm -rf "$tmp_dir"/*
    ( test_standalone_allows_system_python312 "$tmp_dir/system-python" )
    echo "fulltest Python runtime tests passed"
}

main "$@"
