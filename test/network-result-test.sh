#!/usr/bin/env bash
# Regression tests for client result reporting. No root, packages, or network.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
for dependency in jq bc; do
    command -v "$dependency" >/dev/null || { echo "Required for tests: $dependency" >&2; exit 1; }
done
mkdir -p "$TEST_DIR/bin"
# Load production functions without starting the CLI; mock only host operations.
sed '/^main "\$@"$/d' "$SCRIPT_DIR/network-test.sh" > "$TEST_DIR/functions.sh"
cat > "$TEST_DIR/runner.sh" <<'RUNNER'
source "$TEST_DIR/functions.sh"
require_root() { :; }
command_exists() {
    [[ "$SCENARIO" == missing_jq && "$1" == jq ]] && return 1
    command -v "$1" &>/dev/null
}
install_iperf3() { [[ "$SCENARIO" != dependency_failure ]]; }
install_hping3() { :; }
run_discovery() { :; }
run_interface_health() { INTERFACE=mock0; }
run_latency() { :; }
run_mtu_probe() { :; }
capture_interface_errors() { :; }
report_interface_errors() { :; }
LOG_DIR="$CASE_DIR"
LOG_FILE="$CASE_DIR/result.log"
JSONL_FILE="$CASE_DIR/result.jsonl"
main --client 192.0.2.1 --duration 1 "$@"
RUNNER
cat > "$TEST_DIR/bin/iperf3" <<'IPERF'
#!/usr/bin/env bash
kind=single
case " $* " in
    *' -i 10 '*) kind=stress ;;
    *' --bidir '*) kind=bidir ;;
    *' -P 4 '*) kind=multi ;;
esac
if [[ "$SCENARIO" == "${kind}_failure" ]]; then
    echo 'iperf3: connection failed' >&2
    exit 1
fi
if [[ "$SCENARIO" == bidir_unsupported && "$kind" == bidir ]]; then
    echo "iperf3: unrecognized option '--bidir'" >&2
    exit 1
fi
case "$SCENARIO:$kind" in
    malformed:single) echo 'invalid JSON'; exit 0 ;;
    missing:single|multi_missing:multi) echo '{"end":{}}'; exit 0 ;;
    zero:single) echo '{"end":{"sum_sent":{"bits_per_second":0}}}'; exit 0 ;;
    invalid:single) echo '{"end":{"sum_sent":{"bits_per_second":"oops"}}}'; exit 0 ;;
    nan:single) echo '{"end":{"sum_sent":{"bits_per_second":NaN}}}'; exit 0 ;;
    infinite:single) echo '{"end":{"sum_sent":{"bits_per_second":Infinity}}}'; exit 0 ;;
    negative:single) echo '{"end":{"sum_sent":{"bits_per_second":-1}}}'; exit 0 ;;
    received_only:single) echo '{"end":{"sum_received":{"bits_per_second":2000000000}}}'; exit 0 ;;
esac
if [[ "$kind" == stress ]]; then
    echo '[SUM] 0.00-60.00 sec 10 GBytes 2 Gbits/sec sender'
else
    echo '{"end":{"sum_sent":{"bits_per_second":2000000000},"sum_received":{"bits_per_second":2000000000}}}'
fi
IPERF
cat > "$TEST_DIR/bin/timeout" <<'TIMEOUT'
#!/usr/bin/env bash
# Do not execute the /dev/tcp probe.
[[ "$SCENARIO" != connectivity_failure ]]
TIMEOUT
cat > "$TEST_DIR/bin/ping" <<'PING'
#!/usr/bin/env bash
exit 0
PING
chmod +x "$TEST_DIR/bin/"*
export TEST_DIR
export PATH="$TEST_DIR/bin:$PATH"
failures=0
run_case() {
    local scenario="$1" expected="$2"
    shift 2
    local case_dir="$TEST_DIR/$scenario" rc=0 status
    mkdir -p "$case_dir"
    SCENARIO="$scenario" CASE_DIR="$case_dir" bash "$TEST_DIR/runner.sh" "$@" > "$case_dir/output" 2>&1 || rc=$?
    status=$(jq -r 'select(.event == "test_complete") | .status' "$case_dir/result.jsonl")
    if [[ "$status" != "$expected" ]] || { [[ "$expected" == success ]] && [[ "$rc" -ne 0 ]]; } || { [[ "$expected" == failed ]] && [[ "$rc" -eq 0 ]]; }; then
        echo "FAIL $scenario: expected $expected, got status=${status:-missing} exit=$rc"
        failures=$((failures + 1))
    else
        echo "PASS $scenario: status=$status exit=$rc"
    fi
}
run_case healthy success
run_case single_failure failed
run_case multi_failure failed
run_case malformed failed
run_case missing failed
run_case multi_missing failed
run_case zero failed
run_case invalid failed
run_case negative failed
run_case nan failed
run_case infinite failed
run_case missing_jq failed
run_case received_only success
run_case bidir_unsupported success
run_case bidir_failure success
run_case healthy_stress success --stress
run_case stress_failure failed --stress
run_case connectivity_failure failed
run_case dependency_failure failed
[[ "$failures" -eq 0 ]]
