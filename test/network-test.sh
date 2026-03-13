#!/usr/bin/env bash
#===============================================================================
# network-test.sh - Network connectivity and performance testing between servers
#
# Modes:
#   --server              Start iperf3 server and wait for clients
#   --client <target>     Run full test suite against target host
#   --local-only          Test local interface health only (no remote target)
#
# Features:
#   - Interface discovery and health checks
#   - Latency testing with statistics (min/avg/max/stddev/p99)
#   - TCP bandwidth testing (single-stream, multi-stream, bidirectional)
#   - MTU path discovery and jumbo frame validation
#   - Interface error counter monitoring (before/after delta)
#   - Optional stress test mode for sustained transfers
#
# Output:
#   - Human-readable log: ./logs/network-test/network-test-YYYYMMDD-HHMMSS.log
#   - JSONL structured log: ./logs/network-test/network-test-YYYYMMDD-HHMMSS.jsonl
#   - Keeps last 3 runs, rotates older logs
#
# Usage:
#   ./network-test.sh --server [--port 5201]
#   ./network-test.sh --client <target> [--port 5201] [--duration 10] [--stress]
#   ./network-test.sh --local-only
#   ./network-test.sh --help
#
# Requirements:
#   - iperf3 (auto-installed if missing)
#   - ping, ip, ethtool (standard Linux tools)
#
#===============================================================================

set -o pipefail

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs/network-test"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/network-test-${TIMESTAMP}.log"
JSONL_FILE="${LOG_DIR}/network-test-${TIMESTAMP}.jsonl"
MAX_LOG_RUNS=3

# Defaults
DEFAULT_PORT=5201
DEFAULT_DURATION=10
STRESS_DURATION=60
PING_COUNT=50
MTU_PROBE_SIZES=(1500 4000 9000)

# Runtime variables
MODE=""
TARGET=""
PORT="${DEFAULT_PORT}"
DURATION="${DEFAULT_DURATION}"
STRESS_MODE=false
INTERFACE=""
ERRORS_BEFORE=""
ERRORS_AFTER=""

#-------------------------------------------------------------------------------
# Color helpers
#-------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
fi

#-------------------------------------------------------------------------------
# Logging functions
#-------------------------------------------------------------------------------
log_init() {
    mkdir -p "${LOG_DIR}"
    touch "${LOG_FILE}" "${JSONL_FILE}"

    # Rotate old logs - keep only last MAX_LOG_RUNS
    local log_files jsonl_files
    log_files=($(ls -1t "${LOG_DIR}"/network-test-*.log 2>/dev/null | tail -n +$((MAX_LOG_RUNS + 1))))
    jsonl_files=($(ls -1t "${LOG_DIR}"/network-test-*.jsonl 2>/dev/null | tail -n +$((MAX_LOG_RUNS + 1))))

    for f in "${log_files[@]}" "${jsonl_files[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
}

log() {
    local level="$1"
    shift
    local message="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"

    # Human-readable output
    case "${level}" in
        INFO)  printf "${CYAN}[%s]${NC} ${GREEN}INFO${NC}  %s\n" "$ts" "$message" ;;
        WARN)  printf "${CYAN}[%s]${NC} ${YELLOW}WARN${NC}  %s\n" "$ts" "$message" ;;
        ERROR) printf "${CYAN}[%s]${NC} ${RED}ERROR${NC} %s\n" "$ts" "$message" ;;
        PASS)  printf "${CYAN}[%s]${NC} ${GREEN}PASS${NC}  %s\n" "$ts" "$message" ;;
        FAIL)  printf "${CYAN}[%s]${NC} ${RED}FAIL${NC}  %s\n" "$ts" "$message" ;;
        STAGE) printf "\n${CYAN}[%s]${NC} ${BOLD}${BLUE}=== %s ===${NC}\n" "$ts" "$message" ;;
        *)     printf "${CYAN}[%s]${NC} %s\n" "$ts" "$message" ;;
    esac | tee -a "${LOG_FILE}"
}

log_json() {
    local event="$1"
    shift
    local ts
    ts="$(date -Iseconds)"

    # Build JSON object
    local json="{\"timestamp\":\"${ts}\",\"event\":\"${event}\""
    while [[ $# -ge 2 ]]; do
        local key="$1"
        local value="$2"
        shift 2
        # Escape quotes in value
        value="${value//\"/\\\"}"
        # Check if value is numeric
        if [[ "$value" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
            json="${json},\"${key}\":${value}"
        else
            json="${json},\"${key}\":\"${value}\""
        fi
    done
    json="${json}}"

    echo "$json" >> "${JSONL_FILE}"
}

header() {
    local text="$1"
    local width=70
    local padding=$(( (width - ${#text} - 2) / 2 ))

    echo ""
    printf "${BOLD}${BLUE}"
    printf '%*s' "$width" '' | tr ' ' '='
    printf '\n'
    printf '%*s %s %*s\n' "$padding" '' "$text" "$padding" ''
    printf '%*s' "$width" '' | tr ' ' '='
    printf "${NC}\n"
    echo ""
} | tee -a "${LOG_FILE}"

#-------------------------------------------------------------------------------
# Utility functions
#-------------------------------------------------------------------------------
command_exists() {
    command -v "$1" &>/dev/null
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log ERROR "This script must be run as root (for ethtool and some tests)"
        exit 1
    fi
}

install_iperf3() {
    if command_exists iperf3; then
        log INFO "iperf3 is already installed: $(iperf3 --version 2>&1 | head -1)"
        return 0
    fi

    log INFO "Installing iperf3..."

    if command_exists apt-get; then
        apt-get update -qq && apt-get install -y -qq iperf3
    elif command_exists dnf; then
        dnf install -y -q iperf3
    elif command_exists yum; then
        yum install -y -q iperf3
    else
        log ERROR "Cannot install iperf3: no supported package manager found"
        return 1
    fi

    if command_exists iperf3; then
        log PASS "iperf3 installed successfully"
        return 0
    else
        log ERROR "iperf3 installation failed"
        return 1
    fi
}

install_hping3() {
    if command_exists hping3; then
        return 0
    fi

    log INFO "Installing hping3 for advanced latency testing..."

    if command_exists apt-get; then
        apt-get install -y -qq hping3 2>/dev/null || true
    elif command_exists dnf; then
        dnf install -y -q hping3 2>/dev/null || true
    elif command_exists yum; then
        yum install -y -q hping3 2>/dev/null || true
    fi

    # hping3 is optional, don't fail if not available
    if command_exists hping3; then
        log INFO "hping3 installed"
    else
        log WARN "hping3 not available (optional, continuing without)"
    fi
}

get_primary_interface() {
    # Get the interface used for default route
    local iface
    iface=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K\S+' | head -1)

    if [[ -z "$iface" ]]; then
        # Fallback: first non-loopback interface that's UP
        iface=$(ip -o link show | awk -F': ' '$2 !~ /lo|docker|br-|veth|virbr/ && /state UP/ {print $2; exit}')
    fi

    echo "$iface"
}

get_interface_for_target() {
    local target="$1"
    ip route get "$target" 2>/dev/null | grep -oP 'dev \K\S+' | head -1
}

#-------------------------------------------------------------------------------
# Discovery Stage
#-------------------------------------------------------------------------------
run_discovery() {
    log STAGE "DISCOVERY"

    log INFO "Hostname: $(hostname)"
    log INFO "Kernel: $(uname -r)"
    log_json "discovery_start" "hostname" "$(hostname)" "kernel" "$(uname -r)"

    # List all network interfaces
    log INFO "Network interfaces:"
    echo "" | tee -a "${LOG_FILE}"

    while IFS= read -r line; do
        local iface state mtu
        iface=$(echo "$line" | awk -F': ' '{print $2}')
        [[ "$iface" =~ ^(lo|docker|br-|veth|virbr) ]] && continue

        state=$(ip -o link show "$iface" 2>/dev/null | grep -oP 'state \K\S+')
        mtu=$(ip -o link show "$iface" 2>/dev/null | grep -oP 'mtu \K\d+')

        local ip_addr
        ip_addr=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
        [[ -z "$ip_addr" ]] && ip_addr="(no IPv4)"

        local speed="N/A"
        if command_exists ethtool; then
            speed=$(ethtool "$iface" 2>/dev/null | grep -i "Speed:" | awk '{print $2}') || speed="N/A"
        fi

        printf "  %-15s  %-8s  MTU: %-5s  Speed: %-10s  IP: %s\n" \
            "$iface" "$state" "$mtu" "$speed" "$ip_addr" | tee -a "${LOG_FILE}"

        log_json "interface_discovered" \
            "interface" "$iface" \
            "state" "$state" \
            "mtu" "$mtu" \
            "speed" "$speed" \
            "ip" "$ip_addr"
    done < <(ip -o link show)

    echo "" | tee -a "${LOG_FILE}"

    # Identify primary interface
    INTERFACE=$(get_primary_interface)
    if [[ -n "$INTERFACE" ]]; then
        log INFO "Primary interface (default route): ${INTERFACE}"
        log_json "primary_interface" "interface" "$INTERFACE"
    else
        log WARN "Could not determine primary interface"
    fi
}

#-------------------------------------------------------------------------------
# Interface Health Stage
#-------------------------------------------------------------------------------
capture_interface_errors() {
    local iface="$1"
    local when="$2"  # "before" or "after"

    if ! command_exists ethtool; then
        log WARN "ethtool not available, skipping interface error counters"
        return
    fi

    local stats
    stats=$(ethtool -S "$iface" 2>/dev/null | grep -iE 'error|drop|crc|collision|overrun|carrier|fifo' || true)

    if [[ "$when" == "before" ]]; then
        ERRORS_BEFORE="$stats"
    else
        ERRORS_AFTER="$stats"
    fi
}

report_interface_errors() {
    local iface="$1"

    log INFO "Interface error counters for ${iface}:"

    if [[ -z "$ERRORS_BEFORE" ]]; then
        log WARN "  No error counters captured"
        return
    fi

    # Parse and compare before/after
    local has_new_errors=false

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local name value_before value_after
        name=$(echo "$line" | awk -F: '{print $1}' | xargs)
        value_before=$(echo "$line" | awk -F: '{print $2}' | xargs)

        value_after=$(echo "$ERRORS_AFTER" | grep "^ *${name}:" | awk -F: '{print $2}' | xargs)
        [[ -z "$value_after" ]] && value_after="$value_before"

        local delta=$((value_after - value_before))

        if [[ $delta -gt 0 ]]; then
            printf "  ${YELLOW}%-40s: %s -> %s (Δ +%d)${NC}\n" "$name" "$value_before" "$value_after" "$delta" | tee -a "${LOG_FILE}"
            has_new_errors=true
            log_json "interface_error_delta" "interface" "$iface" "counter" "$name" "before" "$value_before" "after" "$value_after" "delta" "$delta"
        fi
    done <<< "$ERRORS_BEFORE"

    if [[ "$has_new_errors" == false ]]; then
        log PASS "  No new errors during test"
        log_json "interface_errors" "interface" "$iface" "status" "clean"
    fi
}

run_interface_health() {
    log STAGE "INTERFACE HEALTH"

    local iface="${INTERFACE}"
    [[ -n "$TARGET" ]] && iface=$(get_interface_for_target "$TARGET")
    [[ -z "$iface" ]] && iface=$(get_primary_interface)

    if [[ -z "$iface" ]]; then
        log ERROR "No interface to check"
        return 1
    fi

    log INFO "Checking interface: ${iface}"

    # Link state
    local state
    state=$(ip -o link show "$iface" 2>/dev/null | grep -oP 'state \K\S+')
    if [[ "$state" == "UP" ]]; then
        log PASS "Link state: UP"
    else
        log FAIL "Link state: ${state}"
    fi
    log_json "link_state" "interface" "$iface" "state" "$state"

    # Carrier
    local carrier
    carrier=$(cat "/sys/class/net/${iface}/carrier" 2>/dev/null || echo "unknown")
    if [[ "$carrier" == "1" ]]; then
        log PASS "Carrier: present"
    else
        log WARN "Carrier: ${carrier}"
    fi

    # MTU
    local mtu
    mtu=$(ip -o link show "$iface" 2>/dev/null | grep -oP 'mtu \K\d+')
    log INFO "MTU: ${mtu}"
    log_json "interface_mtu" "interface" "$iface" "mtu" "$mtu"

    # Speed and duplex (if ethtool available)
    if command_exists ethtool; then
        local speed duplex
        speed=$(ethtool "$iface" 2>/dev/null | grep -i "Speed:" | awk '{print $2}')
        duplex=$(ethtool "$iface" 2>/dev/null | grep -i "Duplex:" | awk '{print $2}')

        log INFO "Speed: ${speed:-N/A}, Duplex: ${duplex:-N/A}"
        log_json "interface_speed" "interface" "$iface" "speed" "${speed:-N/A}" "duplex" "${duplex:-N/A}"

        # Check for link issues
        local autoneg
        autoneg=$(ethtool "$iface" 2>/dev/null | grep -i "Auto-negotiation:" | awk '{print $2}')
        [[ -n "$autoneg" ]] && log INFO "Auto-negotiation: ${autoneg}"
    fi

    # Capture baseline error counters
    capture_interface_errors "$iface" "before"

    # IP configuration
    local ip_addr gateway
    ip_addr=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)
    gateway=$(ip route | grep "default.*${iface}" | awk '{print $3}' | head -1)

    log INFO "IP: ${ip_addr:-none}, Gateway: ${gateway:-none}"
    log_json "ip_config" "interface" "$iface" "ip" "${ip_addr:-none}" "gateway" "${gateway:-none}"

    INTERFACE="$iface"
}

#-------------------------------------------------------------------------------
# Connectivity Stage
#-------------------------------------------------------------------------------
run_connectivity() {
    local target="$1"

    log STAGE "CONNECTIVITY"

    # DNS resolution (if target is hostname)
    if [[ ! "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log INFO "Resolving hostname: ${target}"
        local resolved
        resolved=$(getent hosts "$target" 2>/dev/null | awk '{print $1}' | head -1)
        if [[ -n "$resolved" ]]; then
            log PASS "DNS resolved: ${target} -> ${resolved}"
            log_json "dns_resolution" "hostname" "$target" "ip" "$resolved" "status" "success"
        else
            log FAIL "DNS resolution failed for ${target}"
            log_json "dns_resolution" "hostname" "$target" "status" "failed"
            return 1
        fi
    fi

    # Basic ICMP ping
    log INFO "Testing ICMP connectivity to ${target}..."
    if ping -c 3 -W 2 "$target" &>/dev/null; then
        log PASS "ICMP ping successful"
        log_json "icmp_connectivity" "target" "$target" "status" "success"
    else
        log FAIL "ICMP ping failed (host unreachable or ICMP blocked)"
        log_json "icmp_connectivity" "target" "$target" "status" "failed"
        # Don't return - ICMP might be blocked but TCP works
    fi

    # TCP connectivity to iperf3 port
    log INFO "Testing TCP connectivity to ${target}:${PORT}..."
    if timeout 5 bash -c "echo >/dev/tcp/${target}/${PORT}" 2>/dev/null; then
        log PASS "TCP port ${PORT} is reachable"
        log_json "tcp_connectivity" "target" "$target" "port" "$PORT" "status" "success"
    else
        log FAIL "TCP port ${PORT} is not reachable (is iperf3 server running?)"
        log_json "tcp_connectivity" "target" "$target" "port" "$PORT" "status" "failed"
        log INFO "Hint: Start server with: $0 --server --port ${PORT}"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# Latency Stage
#-------------------------------------------------------------------------------
run_latency() {
    local target="$1"

    log STAGE "LATENCY"

    log INFO "Running latency test (${PING_COUNT} pings)..."

    # Collect ping times
    local ping_output
    ping_output=$(ping -c "${PING_COUNT}" -i 0.1 "$target" 2>&1)

    if [[ $? -ne 0 ]]; then
        log WARN "Ping test had issues (some packets may have been lost)"
    fi

    # Parse ping statistics
    local stats_line
    stats_line=$(echo "$ping_output" | grep "rtt min/avg/max")

    if [[ -n "$stats_line" ]]; then
        # Format: rtt min/avg/max/mdev = 0.123/0.456/0.789/0.012 ms
        local values
        values=$(echo "$stats_line" | grep -oP '[\d.]+/[\d.]+/[\d.]+/[\d.]+')

        local min avg max mdev
        IFS='/' read -r min avg max mdev <<< "$values"

        log INFO "Latency statistics:"
        printf "  Min:    %s ms\n" "$min" | tee -a "${LOG_FILE}"
        printf "  Avg:    %s ms\n" "$avg" | tee -a "${LOG_FILE}"
        printf "  Max:    %s ms\n" "$max" | tee -a "${LOG_FILE}"
        printf "  StdDev: %s ms\n" "$mdev" | tee -a "${LOG_FILE}"

        log_json "latency_stats" \
            "target" "$target" \
            "min_ms" "$min" \
            "avg_ms" "$avg" \
            "max_ms" "$max" \
            "stddev_ms" "$mdev" \
            "samples" "$PING_COUNT"

        # Evaluate latency (for L2, should be <1ms)
        local avg_int=${avg%.*}
        if [[ $avg_int -lt 1 ]]; then
            log PASS "Average latency is sub-millisecond (excellent for L2)"
        elif [[ $avg_int -lt 5 ]]; then
            log PASS "Average latency is acceptable"
        else
            log WARN "Average latency is high for L2 segment (${avg} ms)"
        fi
    fi

    # Packet loss
    local loss_line
    loss_line=$(echo "$ping_output" | grep "packet loss")
    local loss_pct
    loss_pct=$(echo "$loss_line" | grep -oP '\d+(?=% packet loss)')

    if [[ -n "$loss_pct" ]]; then
        if [[ "$loss_pct" == "0" ]]; then
            log PASS "Packet loss: 0%"
        else
            log WARN "Packet loss: ${loss_pct}%"
        fi
        log_json "packet_loss" "target" "$target" "loss_percent" "$loss_pct"
    fi

    # Calculate p99 from raw ping times
    local times
    times=$(echo "$ping_output" | grep -oP 'time=\K[\d.]+' | sort -n)
    local count
    count=$(echo "$times" | wc -l)

    if [[ $count -gt 10 ]]; then
        local p99_index=$(( (count * 99 + 99) / 100 ))
        local p99
        p99=$(echo "$times" | sed -n "${p99_index}p")
        if [[ -n "$p99" ]]; then
            printf "  P99:    %s ms\n" "$p99" | tee -a "${LOG_FILE}"
            log_json "latency_p99" "target" "$target" "p99_ms" "$p99"
        fi
    fi
}

#-------------------------------------------------------------------------------
# MTU Path Discovery Stage
#-------------------------------------------------------------------------------
run_mtu_probe() {
    local target="$1"

    log STAGE "MTU PATH DISCOVERY"

    log INFO "Probing MTU path to ${target}..."

    local max_working_mtu=0

    for mtu in "${MTU_PROBE_SIZES[@]}"; do
        # Payload size = MTU - IP header (20) - ICMP header (8)
        local payload=$((mtu - 28))

        log INFO "Testing MTU ${mtu} (payload ${payload} bytes)..."

        # Use ping with DF bit set (-M do)
        if ping -c 2 -W 2 -M do -s "$payload" "$target" &>/dev/null; then
            log PASS "MTU ${mtu}: OK"
            max_working_mtu=$mtu
            log_json "mtu_probe" "target" "$target" "mtu" "$mtu" "status" "success"
        else
            log WARN "MTU ${mtu}: Fragmentation needed or blocked"
            log_json "mtu_probe" "target" "$target" "mtu" "$mtu" "status" "failed"
        fi
    done

    echo "" | tee -a "${LOG_FILE}"
    if [[ $max_working_mtu -ge 9000 ]]; then
        log PASS "Jumbo frames (9000 MTU) supported end-to-end"
    elif [[ $max_working_mtu -ge 1500 ]]; then
        log INFO "Maximum working MTU: ${max_working_mtu}"
        [[ $max_working_mtu -lt 9000 ]] && log INFO "Jumbo frames not supported (9000 MTU failed)"
    else
        log WARN "MTU path discovery inconclusive"
    fi

    log_json "mtu_path_max" "target" "$target" "max_mtu" "$max_working_mtu"
}

#-------------------------------------------------------------------------------
# Bandwidth Stage
#-------------------------------------------------------------------------------
run_bandwidth() {
    local target="$1"
    local duration="$2"

    log STAGE "BANDWIDTH"

    if ! command_exists iperf3; then
        log ERROR "iperf3 not available"
        return 1
    fi

    # Single stream TCP
    log INFO "Testing TCP bandwidth (single stream, ${duration}s)..."
    local result
    result=$(iperf3 -c "$target" -p "$PORT" -t "$duration" -J 2>&1)

    if [[ $? -eq 0 ]]; then
        local bps
        bps=$(echo "$result" | jq -r '.end.sum_sent.bits_per_second // .end.sum_received.bits_per_second // 0' 2>/dev/null)

        if [[ -n "$bps" && "$bps" != "0" && "$bps" != "null" ]]; then
            local gbps
            gbps=$(echo "scale=2; $bps / 1000000000" | bc)
            log PASS "Single stream: ${gbps} Gbps"
            log_json "bandwidth_single" "target" "$target" "gbps" "$gbps" "duration_s" "$duration"
        else
            log WARN "Could not parse bandwidth result"
        fi
    else
        log FAIL "iperf3 single stream test failed"
        echo "$result" | head -5 | tee -a "${LOG_FILE}"
    fi

    # Multi-stream TCP (4 parallel streams)
    log INFO "Testing TCP bandwidth (4 parallel streams, ${duration}s)..."
    result=$(iperf3 -c "$target" -p "$PORT" -t "$duration" -P 4 -J 2>&1)

    if [[ $? -eq 0 ]]; then
        local bps
        bps=$(echo "$result" | jq -r '.end.sum_sent.bits_per_second // .end.sum_received.bits_per_second // 0' 2>/dev/null)

        if [[ -n "$bps" && "$bps" != "0" && "$bps" != "null" ]]; then
            local gbps
            gbps=$(echo "scale=2; $bps / 1000000000" | bc)
            log PASS "4-stream: ${gbps} Gbps"
            log_json "bandwidth_4stream" "target" "$target" "gbps" "$gbps" "duration_s" "$duration"
        fi
    else
        log FAIL "iperf3 multi-stream test failed"
    fi

    # Bidirectional test
    log INFO "Testing TCP bandwidth (bidirectional, ${duration}s)..."
    result=$(iperf3 -c "$target" -p "$PORT" -t "$duration" --bidir -J 2>&1)

    if [[ $? -eq 0 ]]; then
        local send_bps recv_bps
        send_bps=$(echo "$result" | jq -r '.end.sum_sent.bits_per_second // 0' 2>/dev/null)
        recv_bps=$(echo "$result" | jq -r '.end.sum_received.bits_per_second // 0' 2>/dev/null)

        if [[ -n "$send_bps" && "$send_bps" != "0" ]]; then
            local send_gbps recv_gbps
            send_gbps=$(echo "scale=2; $send_bps / 1000000000" | bc)
            recv_gbps=$(echo "scale=2; $recv_bps / 1000000000" | bc)
            log PASS "Bidirectional: Send ${send_gbps} Gbps, Recv ${recv_gbps} Gbps"
            log_json "bandwidth_bidir" "target" "$target" "send_gbps" "$send_gbps" "recv_gbps" "$recv_gbps" "duration_s" "$duration"
        fi
    else
        log WARN "Bidirectional test failed (may not be supported by server version)"
    fi
}

#-------------------------------------------------------------------------------
# Stress Test Stage
#-------------------------------------------------------------------------------
run_stress() {
    local target="$1"
    local duration="${STRESS_DURATION}"

    log STAGE "STRESS TEST"

    log INFO "Running sustained bandwidth test (${duration}s)..."
    log INFO "This will help identify thermal throttling or buffer issues"

    local result
    result=$(iperf3 -c "$target" -p "$PORT" -t "$duration" -P 4 -i 10 2>&1)

    if [[ $? -eq 0 ]]; then
        log PASS "Stress test completed"

        # Show interval data
        echo "" | tee -a "${LOG_FILE}"
        echo "Interval throughput:" | tee -a "${LOG_FILE}"
        echo "$result" | grep -E '^\[.*\].*sec.*Gbits/sec' | while read -r line; do
            echo "  $line" | tee -a "${LOG_FILE}"
        done

        # Final summary
        local final_bps
        final_bps=$(echo "$result" | grep -E 'sender$' | tail -1 | awk '{print $(NF-2)}')
        [[ -n "$final_bps" ]] && log INFO "Final throughput: ${final_bps} Gbits/sec"

        log_json "stress_test" "target" "$target" "duration_s" "$duration" "status" "completed"
    else
        log FAIL "Stress test failed"
        log_json "stress_test" "target" "$target" "duration_s" "$duration" "status" "failed"
    fi
}

#-------------------------------------------------------------------------------
# Server Mode
#-------------------------------------------------------------------------------
run_server() {
    header "NETWORK TEST - SERVER MODE"

    if ! command_exists iperf3; then
        install_iperf3 || exit 1
    fi

    log INFO "Starting iperf3 server on port ${PORT}..."
    log INFO "Press Ctrl+C to stop"
    log_json "server_start" "port" "$PORT"

    echo "" | tee -a "${LOG_FILE}"

    # Run iperf3 server (foreground)
    iperf3 -s -p "$PORT" 2>&1 | tee -a "${LOG_FILE}"
}

#-------------------------------------------------------------------------------
# Client Mode
#-------------------------------------------------------------------------------
run_client() {
    local target="$1"

    header "NETWORK TEST - CLIENT MODE"

    log INFO "Target: ${target}:${PORT}"
    log INFO "Duration: ${DURATION}s per test"
    log INFO "Stress mode: ${STRESS_MODE}"
    log_json "test_start" "mode" "client" "target" "$target" "port" "$PORT" "duration" "$DURATION" "stress" "$STRESS_MODE"

    # Install dependencies
    install_iperf3 || exit 1
    install_hping3

    # Run test stages
    run_discovery
    run_interface_health
    run_connectivity "$target" || exit 1
    run_latency "$target"
    run_mtu_probe "$target"
    run_bandwidth "$target" "$DURATION"

    if [[ "$STRESS_MODE" == true ]]; then
        run_stress "$target"
    fi

    # Final interface error check
    capture_interface_errors "$INTERFACE" "after"

    log STAGE "FINAL SUMMARY"
    report_interface_errors "$INTERFACE"

    echo "" | tee -a "${LOG_FILE}"
    log INFO "Test completed"
    log INFO "Human log: ${LOG_FILE}"
    log INFO "JSONL log: ${JSONL_FILE}"
    log_json "test_complete" "status" "success"
}

#-------------------------------------------------------------------------------
# Local-Only Mode
#-------------------------------------------------------------------------------
run_local_only() {
    header "NETWORK TEST - LOCAL INTERFACE CHECK"

    log_json "test_start" "mode" "local_only"

    run_discovery
    run_interface_health

    # Show current error counters
    log STAGE "INTERFACE ERROR COUNTERS"

    if command_exists ethtool && [[ -n "$INTERFACE" ]]; then
        local stats
        stats=$(ethtool -S "$INTERFACE" 2>/dev/null | grep -iE 'error|drop|crc|collision|overrun|carrier|fifo' || true)

        if [[ -n "$stats" ]]; then
            echo "$stats" | while read -r line; do
                local name value
                name=$(echo "$line" | awk -F: '{print $1}' | xargs)
                value=$(echo "$line" | awk -F: '{print $2}' | xargs)

                if [[ "$value" -gt 0 ]]; then
                    printf "  ${YELLOW}%-40s: %s${NC}\n" "$name" "$value" | tee -a "${LOG_FILE}"
                else
                    printf "  %-40s: %s\n" "$name" "$value" | tee -a "${LOG_FILE}"
                fi
            done
        else
            log INFO "No error counters available"
        fi
    else
        log WARN "Cannot read error counters (ethtool not available or no interface)"
    fi

    echo "" | tee -a "${LOG_FILE}"
    log INFO "Local check completed"
    log INFO "Human log: ${LOG_FILE}"
    log INFO "JSONL log: ${JSONL_FILE}"
    log_json "test_complete" "status" "success"
}

#-------------------------------------------------------------------------------
# Usage
#-------------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [MODE] [OPTIONS]

Modes:
  --server              Start iperf3 server and wait for client connections
  --client <target>     Run full test suite against target host
  --local-only          Check local interface health only (no remote target)

Options:
  --port <port>         Port for iperf3 (default: ${DEFAULT_PORT})
  --duration <seconds>  Duration per bandwidth test (default: ${DEFAULT_DURATION}s)
  --stress              Enable stress test (${STRESS_DURATION}s sustained transfer)
  --help                Show this help message

Examples:
  # Start server on machine A
  ./network-test.sh --server

  # Run client test from machine B
  ./network-test.sh --client 192.168.1.100

  # Full test with stress mode
  ./network-test.sh --client 192.168.1.100 --duration 15 --stress

  # Just check local interfaces
  ./network-test.sh --local-only

Output:
  Logs are saved to: ${LOG_DIR}/
  - network-test-YYYYMMDD-HHMMSS.log   (human-readable)
  - network-test-YYYYMMDD-HHMMSS.jsonl (structured)

EOF
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server)
                MODE="server"
                shift
                ;;
            --client)
                MODE="client"
                TARGET="$2"
                if [[ -z "$TARGET" ]]; then
                    echo "Error: --client requires a target host"
                    exit 1
                fi
                shift 2
                ;;
            --local-only)
                MODE="local"
                shift
                ;;
            --port)
                PORT="$2"
                shift 2
                ;;
            --duration)
                DURATION="$2"
                shift 2
                ;;
            --stress)
                STRESS_MODE=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Validate mode
    if [[ -z "$MODE" ]]; then
        echo "Error: Must specify --server, --client <target>, or --local-only"
        echo ""
        usage
        exit 1
    fi

    # Initialize logging
    log_init

    # Run appropriate mode
    case "$MODE" in
        server)
            run_server
            ;;
        client)
            require_root
            run_client "$TARGET"
            ;;
        local)
            require_root
            run_local_only
            ;;
    esac
}

main "$@"
