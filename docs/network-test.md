# network-test.sh Documentation

Network connectivity and performance testing between servers over TCP/IP.

## Overview

`network-test.sh` validates network health and performance between servers on the same L2 segment. It runs a series of tests progressing from basic connectivity through sustained bandwidth stress testing, producing both human-readable and structured JSONL logs.

### Test Flow

```
Discovery → Interface Health → Connectivity → Latency → MTU Probe → Bandwidth → Stress (optional)
```

### Key Features

- **Server/client architecture** — run server on one machine, client on another
- **Auto-installs dependencies** — iperf3 installed automatically if missing
- **Interface error tracking** — captures NIC error counters before/after tests to detect issues
- **MTU path discovery** — validates jumbo frame support end-to-end
- **Structured logging** — JSONL output for programmatic analysis
- **Log rotation** — keeps last 3 test runs

## Requirements

- Linux (Ubuntu 22.04/24.04 tested)
- Root privileges (for ethtool and some tests)
- Network connectivity between test hosts
- Tools (auto-installed if missing):
  - `iperf3` — bandwidth testing
  - `hping3` — advanced latency testing (optional)

## Installation

```bash
# Copy to your provision directory
cp test/network-test.sh /opt/provision/
chmod +x /opt/provision/network-test.sh
```

## Usage

### Server Mode

Start the iperf3 server on the target machine:

```bash
sudo /opt/provision/network-test.sh --server
```

Options:
- `--port <port>` — listen port (default: 5201)

The server runs in foreground until stopped with Ctrl+C.

### Client Mode

Run the full test suite against a target server:

```bash
sudo /opt/provision/network-test.sh --client <target>
```

Options:
- `--port <port>` — server port (default: 5201)
- `--duration <seconds>` — duration per bandwidth test (default: 10s)
- `--stress` — enable 60-second sustained stress test

Examples:

```bash
# Basic test
sudo /opt/provision/network-test.sh --client 192.168.1.100

# Custom port and duration
sudo /opt/provision/network-test.sh --client 192.168.1.100 --port 5202 --duration 15

# Full test with stress mode
sudo /opt/provision/network-test.sh --client 192.168.1.100 --stress
```

### Local-Only Mode

Check local interface health without a remote target:

```bash
sudo /opt/provision/network-test.sh --local-only
```

Useful for validating interface configuration and checking error counters before deploying.

## Test Stages

### 1. Discovery

Enumerates all network interfaces and their properties:

- Interface name, state, MTU
- Link speed (from ethtool)
- IP address
- Identifies primary interface (default route)

**Output:**
```
[2026-03-13 10:30:00] === DISCOVERY ===
[2026-03-13 10:30:00] INFO  Hostname: gpu-server-01
[2026-03-13 10:30:00] INFO  Network interfaces:

  eth0             UP        MTU: 9000   Speed: 25000Mb/s  IP: 192.168.1.10
  eth1             UP        MTU: 1500   Speed: 10000Mb/s  IP: 10.0.0.10

[2026-03-13 10:30:00] INFO  Primary interface (default route): eth0
```

### 2. Interface Health

Detailed health check of the interface used for testing:

| Check | Description |
|-------|-------------|
| Link state | UP/DOWN status |
| Carrier | Physical link presence |
| MTU | Current MTU setting |
| Speed/Duplex | Negotiated link speed |
| Auto-negotiation | Enabled/disabled |
| IP configuration | Address and gateway |
| Error counters | Baseline capture for delta comparison |

**JSONL event:** `interface_speed`, `ip_config`

### 3. Connectivity

Validates basic network path to target:

| Test | Description |
|------|-------------|
| DNS resolution | Resolves hostname to IP (if applicable) |
| ICMP ping | Basic reachability (3 pings) |
| TCP port check | Verifies iperf3 server is reachable |

**Failure behavior:** If TCP connectivity fails, the script exits with instructions to start the server.

### 4. Latency

Performs 50 rapid pings to measure latency characteristics:

| Metric | Description |
|--------|-------------|
| Min | Minimum RTT |
| Avg | Average RTT |
| Max | Maximum RTT |
| StdDev | Standard deviation (jitter indicator) |
| P99 | 99th percentile latency |
| Packet loss | Percentage of dropped packets |

**Expected values for L2:**
- Average latency: < 1ms (excellent), < 5ms (acceptable)
- Packet loss: 0%

**JSONL events:** `latency_stats`, `latency_p99`, `packet_loss`

### 5. MTU Path Discovery

Probes the network path to validate MTU support:

| MTU | Description |
|-----|-------------|
| 1500 | Standard Ethernet |
| 4000 | Mid-size jumbo |
| 9000 | Full jumbo frames |

Uses ICMP with the "Don't Fragment" (DF) bit set. If a packet is too large for the path, the test fails for that MTU size.

**Output:**
```
[2026-03-13 10:30:05] INFO  Testing MTU 1500 (payload 1472 bytes)...
[2026-03-13 10:30:05] PASS  MTU 1500: OK
[2026-03-13 10:30:06] INFO  Testing MTU 9000 (payload 8972 bytes)...
[2026-03-13 10:30:06] PASS  MTU 9000: OK

[2026-03-13 10:30:06] PASS  Jumbo frames (9000 MTU) supported end-to-end
```

**JSONL events:** `mtu_probe`, `mtu_path_max`

### 6. Bandwidth

TCP throughput testing using iperf3:

| Test | Description |
|------|-------------|
| Single stream | One TCP connection, baseline throughput |
| 4-stream parallel | Four simultaneous connections, saturates link |
| Bidirectional | Simultaneous send/receive |

**Output:**
```
[2026-03-13 10:30:10] INFO  Testing TCP bandwidth (single stream, 10s)...
[2026-03-13 10:30:20] PASS  Single stream: 9.41 Gbps
[2026-03-13 10:30:21] INFO  Testing TCP bandwidth (4 parallel streams, 10s)...
[2026-03-13 10:30:31] PASS  4-stream: 9.89 Gbps
[2026-03-13 10:30:32] INFO  Testing TCP bandwidth (bidirectional, 10s)...
[2026-03-13 10:30:42] PASS  Bidirectional: Send 9.45 Gbps, Recv 9.43 Gbps
```

**JSONL events:** `bandwidth_single`, `bandwidth_4stream`, `bandwidth_bidir`

### 7. Stress Test (Optional)

60-second sustained transfer to identify:

- Thermal throttling on NICs
- Switch buffer exhaustion
- Driver/firmware stability issues

Enabled with `--stress` flag. Shows interval throughput every 10 seconds.

**JSONL event:** `stress_test`

### 8. Final Summary

Compares interface error counters before and after testing:

| Counter | Concern if increasing |
|---------|----------------------|
| rx_errors, tx_errors | General errors |
| rx_crc_errors | Cable/transceiver issues |
| rx_dropped, tx_dropped | Buffer overruns, driver issues |
| collisions | Duplex mismatch (shouldn't happen on modern networks) |
| rx_over_errors | Ring buffer overflow |

**Output:**
```
[2026-03-13 10:31:45] === FINAL SUMMARY ===
[2026-03-13 10:31:45] INFO  Interface error counters for eth0:
[2026-03-13 10:31:45] PASS    No new errors during test
```

## Output Files

Logs are saved to `./logs/network-test/` relative to the script location:

| File | Description |
|------|-------------|
| `network-test-YYYYMMDD-HHMMSS.log` | Human-readable log with colors |
| `network-test-YYYYMMDD-HHMMSS.jsonl` | Structured JSON lines for parsing |

Log rotation keeps the last 3 test runs automatically.

### JSONL Schema

Each line is a JSON object with:

```json
{"timestamp":"2026-03-13T10:30:00+00:00","event":"bandwidth_single","target":"192.168.1.100","gbps":9.41,"duration_s":"10"}
```

Key events:

| Event | Fields |
|-------|--------|
| `test_start` | mode, target, port, duration, stress |
| `interface_discovered` | interface, state, mtu, speed, ip |
| `latency_stats` | target, min_ms, avg_ms, max_ms, stddev_ms, samples |
| `latency_p99` | target, p99_ms |
| `packet_loss` | target, loss_percent |
| `mtu_probe` | target, mtu, status |
| `bandwidth_single` | target, gbps, duration_s |
| `bandwidth_4stream` | target, gbps, duration_s |
| `bandwidth_bidir` | target, send_gbps, recv_gbps, duration_s |
| `interface_error_delta` | interface, counter, before, after, delta |
| `test_complete` | status |

## Interpreting Results

### Bandwidth Expectations

| Link Speed | Expected Single-Stream | Expected Multi-Stream |
|------------|------------------------|----------------------|
| 1 Gbps | 940+ Mbps | 940+ Mbps |
| 10 Gbps | 9.3+ Gbps | 9.8+ Gbps |
| 25 Gbps | 20+ Gbps | 24+ Gbps |
| 100 Gbps | 40-60 Gbps | 90+ Gbps |

Single-stream TCP is limited by CPU and latency. Multi-stream tests better reflect actual link capacity.

### Common Issues

| Symptom | Possible Cause |
|---------|---------------|
| Low single-stream throughput | High latency, CPU bottleneck, small TCP buffers |
| Multi-stream doesn't scale | NIC ring buffer too small, IRQ affinity issues |
| Throughput drops during stress | Thermal throttling, switch buffer exhaustion |
| MTU 9000 fails | Jumbo frames not enabled on switch/NIC |
| Packet loss > 0% | Congestion, cable issues, duplex mismatch |
| Interface errors increase | Bad cable, failing transceiver, driver bug |

### Recommended Actions

**Before testing:**
```bash
# Verify jumbo frames enabled (if expected)
ip link show eth0 | grep mtu

# Check ring buffer sizes
ethtool -g eth0

# Verify offloads enabled
ethtool -k eth0 | grep -E 'tcp-segmentation|generic-receive'
```

**If throughput is low:**
```bash
# Increase TCP buffer sizes
sysctl -w net.core.rmem_max=134217728
sysctl -w net.core.wmem_max=134217728
sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728"
sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728"

# Check IRQ affinity
cat /proc/interrupts | grep eth0
```

## Integration with Other Scripts

### Running Before fulltest.sh

For multi-node GPU clusters, validate network before running GPU tests:

```bash
# On all nodes, start server in background
/opt/provision/network-test.sh --server &

# From head node, test connectivity to each worker
for node in worker1 worker2 worker3; do
    /opt/provision/network-test.sh --client $node
done

# Then run GPU validation
./test/fulltest.sh
```

### Automated Validation

Parse JSONL for automated pass/fail:

```bash
# Check if bandwidth met threshold (e.g., 9 Gbps for 10G link)
threshold=9.0
result=$(jq -r 'select(.event=="bandwidth_4stream") | .gbps' \
    logs/network-test/network-test-*.jsonl | tail -1)

if (( $(echo "$result >= $threshold" | bc -l) )); then
    echo "PASS: Bandwidth $result Gbps >= $threshold Gbps"
else
    echo "FAIL: Bandwidth $result Gbps < $threshold Gbps"
    exit 1
fi
```

## Troubleshooting

### "TCP port 5201 is not reachable"

The iperf3 server isn't running or is blocked:

```bash
# On server, verify iperf3 is listening
ss -tlnp | grep 5201

# Check firewall
iptables -L -n | grep 5201
ufw status

# Try a different port
/opt/provision/network-test.sh --server --port 5202
/opt/provision/network-test.sh --client target --port 5202
```

### "iperf3 not available"

Auto-install failed. Install manually:

```bash
# Ubuntu/Debian
apt-get update && apt-get install -y iperf3

# RHEL/CentOS
dnf install -y iperf3
```

### "ethtool not available"

Install ethtool for full interface diagnostics:

```bash
apt-get install -y ethtool
```

### Bidirectional test fails

Older iperf3 versions don't support `--bidir`. This is a warning only and doesn't affect other tests.

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-03-13 | Initial release |

## See Also

- `fulltest.sh` — Multi-GPU validation and stress testing
- `disktest.sh` — Disk performance validation
- `provision.sh` — Top-level provisioning orchestrator
