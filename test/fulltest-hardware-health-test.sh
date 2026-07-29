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

silence_fulltest_logging() {
    log() {
        :
    }
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"
    [[ "$haystack" == *"$needle"* ]] || fail "$label: missing '$needle'"
}

test_opt_in_names_are_not_default() {
    local tmp_dir="$1"
    load_fulltest_defs "$tmp_dir"

    local name
    for name in pcie-errors memory-health fabric-health; do
        is_valid_test_name "$name" || fail "$name is not accepted by the CLI"
        if printf '%s\n' "${DEFAULT_TESTS[@]}" | grep -Fxq "$name"; then
            fail "$name must remain opt-in"
        fi
    done
}

test_counter_delta_only_flags_increases() {
    local tmp_dir="$1"
    load_fulltest_defs "$tmp_dir"
    silence_fulltest_logging

    local before="$tmp_dir/before"
    local after="$tmp_dir/after"
    printf '%s\n' \
        'gpu=0|pcie.replay_counter=12' \
        'gpu=1|pcie.replay_counter=9' > "$before"
    printf '%s\n' \
        'gpu=0|pcie.replay_counter=12' \
        'gpu=1|pcie.replay_counter=11' > "$after"

    local output rc=0
    output=$(compare_metric_snapshots "$before" "$after") || rc=$?
    [ "$rc" -eq 1 ] || fail "counter increase was not reported as a failure"
    assert_contains "$output" 'gpu=1|pcie.replay_counter: 9 -> 11' \
        "counter delta output"
    [[ "$output" != *'gpu=0'* ]] || fail "unchanged counters must not be reported"
}

test_memory_health_classification() {
    local tmp_dir="$1"
    load_fulltest_defs "$tmp_dir"
    silence_fulltest_logging

    local healthy="$tmp_dir/memory-healthy.txt"
    local failed="$tmp_dir/memory-failed.txt"
    local modern_failed="$tmp_dir/memory-modern-failed.txt"
    local unsupported="$tmp_dir/memory-unsupported.txt"
    cat > "$healthy" <<'EOF'
ECC Errors
    Volatile
        Single Bit
            Total                           : 0
        Double Bit
            Total                           : 0
    Aggregate
        Single Bit
            Total                           : 4
        Double Bit
            Total                           : 0
Retired Pages
    Single Bit ECC                          : 2
    Double Bit ECC                          : 0
    Pending Page Blacklist                  : No
Remapped Rows
    Correctable Error                       : 1
    Uncorrectable Error                     : 0
    Pending                                 : No
    Remapping Failure Occurred              : No
    Bank Remap Availability Histogram
        Maximum                             : 32 bank(s)
        High                                : 0 bank(s)
        Partial                             : 0 bank(s)
        Low                                 : 0 bank(s)
        None                                : 0 bank(s)
EOF
    cat > "$failed" <<'EOF'
ECC Errors
    Aggregate
        Double Bit
            Total                           : 1
Retired Pages
    Pending Page Blacklist                  : Yes
Remapped Rows
    Pending                                 : Yes
    Remapping Failure Occurred              : Yes
    Bank Remap Availability Histogram
        None                                : 2 bank(s)
EOF
    cat > "$unsupported" <<'EOF'
ECC Errors
    Volatile
        Single Bit
            Total                           : N/A
Retired Pages
    Pending Page Blacklist                  : N/A
Remapped Rows
    Pending                                 : N/A
EOF
    cat > "$modern_failed" <<'EOF'
ECC Errors
    Volatile
        SRAM Correctable                    : 0
        SRAM Uncorrectable                  : 1
        DRAM Correctable                    : 0
        DRAM Uncorrectable                  : 0
        Channel Repair Pending              : Yes
        TPC Repair Pending                  : No
        Unrepairable Memory                 : No
EOF

    RESULTS_REMARK=()
    MEMORY_HEALTH_APPLICABLE=false
    assess_memory_health_report 0 "A100" "$healthy" \
        || fail "historical corrected/retired memory events must be remarks"
    [ "$MEMORY_HEALTH_APPLICABLE" = true ] \
        || fail "supported memory-health report was treated as unsupported"
    [ "${#RESULTS_REMARK[@]}" -gt 0 ] \
        || fail "historical corrected/retired events did not produce a remark"

    RESULTS_REMARK=()
    MEMORY_HEALTH_APPLICABLE=false
    if assess_memory_health_report 0 "A100" "$failed"; then
        fail "uncorrectable/pending/remap-failure memory state did not fail"
    fi

    RESULTS_REMARK=()
    MEMORY_HEALTH_APPLICABLE=false
    if assess_memory_health_report 0 "H100" "$modern_failed"; then
        fail "modern SRAM/DRAM uncorrectable ECC state did not fail"
    fi

    RESULTS_REMARK=()
    MEMORY_HEALTH_APPLICABLE=false
    assess_memory_health_report 0 "RTX" "$unsupported" \
        || fail "unsupported memory-health fields must not fail"
    [ "$MEMORY_HEALTH_APPLICABLE" = false ] \
        || fail "unsupported report was treated as applicable"
}

test_nvlink_status_and_error_parsing() {
    local tmp_dir="$1"
    load_fulltest_defs "$tmp_dir"
    silence_fulltest_logging

    local healthy="$tmp_dir/nvlink-healthy.txt"
    local failed="$tmp_dir/nvlink-failed.txt"
    local errors="$tmp_dir/nvlink-errors.txt"
    cat > "$healthy" <<'EOF'
GPU 0: UUUU____
GPU 1: UUUU____
EOF
    cat > "$failed" <<'EOF'
GPU 0: UUDX____
EOF
    cat > "$errors" <<'EOF'
Link 0
  CRC FLIT Error: 2
  Replay Error: 0
Link 1
  Recovery Error: 1
EOF

    assess_nvlink_status "$healthy" || fail "healthy NVLink status failed"
    if assess_nvlink_status "$failed"; then
        fail "down NVLink was not classified as a failure"
    fi

    local metrics
    metrics=$(extract_nvlink_error_metrics 0 "$errors")
    assert_contains "$metrics" 'gpu=0|link=0|CRC_FLIT_Error=2' \
        "NVLink error metric"
    assert_contains "$metrics" 'gpu=0|link=1|Recovery_Error=1' \
        "NVLink recovery metric"
}

test_pcie_kernel_scan_handles_clean_and_unbounded_logs() {
    local tmp_dir="$1"
    load_fulltest_defs "$tmp_dir"
    silence_fulltest_logging

    local fake_bin="$tmp_dir/bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/journalctl" <<'EOF'
#!/usr/bin/env bash
echo "kernel: ordinary driver message"
EOF
    cat > "$fake_bin/dmesg" <<'EOF'
#!/usr/bin/env bash
echo "old boot: PCIe Bus Error severity=Fatal"
EOF
    chmod +x "$fake_bin/journalctl" "$fake_bin/dmesg"

    PATH="$fake_bin:/usr/bin:/bin" scan_pcie_kernel_errors 1

    cat > "$fake_bin/journalctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$fake_bin/journalctl"

    if ! PATH="$fake_bin:/usr/bin:/bin" scan_pcie_kernel_errors 1; then
        fail "unbounded dmesg history must not fail a bounded PCIe interval"
    fi
}

test_dispatch_has_no_top_level_local() {
    if awk '/^# Two-pass parse:/ { found=1 } found { print }' "$FULLTEST" \
        | grep -Eq '^[[:space:]]+local[[:space:]]'; then
        fail "top-level dispatch contains a local declaration"
    fi
}

main() {
    local tmp_dir
    tmp_dir="$(mktemp -d /tmp/fulltest-hardware-health.XXXXXX)"
    trap "rm -rf '$tmp_dir'" EXIT

    ( test_opt_in_names_are_not_default "$tmp_dir/names" )
    ( test_counter_delta_only_flags_increases "$tmp_dir/counters" )
    ( test_memory_health_classification "$tmp_dir/memory" )
    ( test_nvlink_status_and_error_parsing "$tmp_dir/nvlink" )
    ( test_pcie_kernel_scan_handles_clean_and_unbounded_logs "$tmp_dir/kernel-log" )
    test_dispatch_has_no_top_level_local
    echo "fulltest hardware health tests passed"
}

main "$@"
