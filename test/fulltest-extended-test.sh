#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir=$(mktemp -d /tmp/fulltest-extended.XXXXXX)
trap 'rm -rf "$tmp_dir"' EXIT
awk '/^# Two-pass parse:/ { exit } { print }' "$ROOT_DIR/test/fulltest.sh" > "$tmp_dir/defs.sh"
source "$tmp_dir/defs.sh" >/dev/null
log() { :; }
fail() { echo "FAIL: $*" >&2; exit 1; }

for name in numerics load-cycles nccl-extended; do
    is_valid_test_name "$name" || fail "missing CLI test $name"
done
[[ " ${DEFAULT_TESTS[*]} " == *" numerics "* ]] || fail "numerics must run by default"
for name in load-cycles nccl-extended; do
    [[ " ${DEFAULT_TESTS[*]} " != *" $name "* ]] || fail "$name must be opt-in"
done
SELECTED_TESTS=(pytorch numerics load-cycles nccl-extended)
EXCLUDED_TESTS=(numerics nccl-extended)
apply_exclusions
[[ "${SELECTED_TESTS[*]}" == 'pytorch load-cycles' ]] || fail "new tests cannot be excluded"

NUM_GPUS=2
install_nccl_lib() { return "${INSTALL_RC:-0}"; }
install_nccl_tests_bin() { return 0; }
mkdir -p "$BUILD_DIR/nccl-tests/build"
export TRACE="$tmp_dir/trace"
for name in all_gather reduce_scatter; do
    cat > "$BUILD_DIR/nccl-tests/build/${name}_perf" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$TRACE"
[[ "${CUDA_VISIBLE_DEVICES:-}" == '2,5' ]] || exit 89
[[ "${NCCL_IB_DISABLE:-}" == 1 ]] || exit 88
if [[ "${0##*/}" == "${FAIL_BINARY:-}" ]]; then exit 7; fi
EOF
    chmod +x "$BUILD_DIR/nccl-tests/build/${name}_perf"
done
# Replace only the OS watchdog; binaries execute normally in the fixture.
timeout() {
    [[ "$1" == --kill-after=10s && "$2" == 180s ]] || fail "missing watchdog"
    shift 2
    "$@"
}
export CUDA_VISIBLE_DEVICES=2,5
test_nccl_extended || fail "healthy collectives failed"
for name in all_gather reduce_scatter; do
    grep -q "${name}_perf .* -g 2 .* -c 1" "$TRACE" || fail "missing rank count/correctness: $name"
done
export FAIL_BINARY=all_gather_perf
if test_nccl_extended; then fail "collective failure was swallowed"; fi
unset FAIL_BINARY
INSTALL_RC=1
if test_nccl_extended; then fail "install failure was swallowed"; fi
INSTALL_RC=0
timeout() { return 124; }
rc=0
test_nccl_extended || rc=$?
[[ "$rc" == 124 ]] || fail "watchdog exit status was swallowed"
NUM_GPUS=1
record_not_run() { printf '%s\n' "$*" > "$tmp_dir/not-run"; }
test_nccl_extended || fail "single GPU should be not-run"
[[ -s "$tmp_dir/not-run" ]] || fail "single GPU skip unreported"
echo 'Extended GPU CLI and NCCL tests passed'
