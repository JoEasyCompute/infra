# disktest.sh — Comprehensive Disk Test Suite

A production-grade disk validation tool for GPU nodes, bare-metal servers, and storage systems. Modelled after the `fulltest.sh` GPU test suite pattern: **discovery → safety → health → performance → stress → summary**.

---

## Requirements

### Dependencies

| Tool | Package | Role |
|---|---|---|
| `fio` | `fio` | All I/O benchmarks |
| `smartctl` | `smartmontools` | SMART/health data |
| `lsblk`, `blockdev` | `util-linux` | Device discovery |
| `python3` | `python3` | fio result parsing |
| `nvme` *(optional)* | `nvme-cli` | NVMe-specific health checks |
| `ioping` *(optional)* | `ioping` | Supplemental latency data |
| `lspci` *(optional)* | `pciutils` | PCIe controller topology |

**Dependencies are auto-detected and auto-installed** on first run if you have a supported package manager (`apt-get`, `dnf`, `yum`, `zypper`, `pacman`). Required tools will abort the run if they can't be installed; optional tools degrade gracefully.

Manual install (Ubuntu/Debian):
```bash
sudo apt install fio smartmontools nvme-cli ioping pciutils
```

### Permissions

Root is required for SMART data, raw block device I/O, and auto-installing dependencies.

```bash
sudo ./disktest.sh [OPTIONS]
```

Running without root will warn and proceed in a limited mode (SMART checks may fail, auto-install is disabled).

---

## Installation

```bash
# Download
curl -O https://github.com/joeasycompute/infra/disktest.sh
chmod +x disktest.sh

# Or clone alongside fulltest.sh in your validation toolkit
```

---

## Quick Start

```bash
# Preview what would run — no disk I/O
sudo ./disktest.sh --dry-run

# Health check only (safe on any system)
sudo ./disktest.sh --health

# Quick check on all disks (~3 min per disk)
sudo ./disktest.sh --quick

# Full test on all disks (~15 min per disk)
sudo ./disktest.sh --full

# Target a single drive
sudo ./disktest.sh --full --device /dev/nvme0n1

# Full test with JSON output for CI/automation
sudo ./disktest.sh --full --json
```

---

## Modes

| Mode | What Runs | Est. Time (per disk) |
|---|---|---|
| `--health` | SMART + NVMe health only | ~10s |
| `--quick` | Health + sequential read/write | ~3 min |
| `--full` | Health + sequential + random + latency + FS layer | ~15 min |
| `--stress` | Full + extended endurance + thermal check | ~30–40 min |

> Default mode is `--full` if no mode flag is specified.

### `--health`
SMART status, reallocated/pending/uncorrectable sector counts, drive temperature, and NVMe-specific metrics (wear %, available spare). No I/O is performed. Safe to run on live production systems.

### `--quick`
Health checks plus sequential read and write at 1M block size with QD32. Good for a fast post-deployment sanity check.

### `--full`
The standard validation run. Includes:
- SMART / NVMe health
- Sequential read + write (1M blocks, QD32)
- Random 4K read at QD1 / QD4 / QD16 / QD32
- Random 4K mixed 70/30 read/write at QD16
- QD1 latency profile with p50/p95/p99/p99.9 percentiles
- Filesystem fsync latency (on any mounted FS found on the device)
- Multi-disk parallel bandwidth test (if 2+ safe devices found)

### `--stress`
Everything in `--full`, plus a sustained write test designed to expose the SLC cache cliff on TLC/QLC NAND, and a mixed load endurance run. Post-stress temperature is re-checked and flagged if elevated.

---

## All Options

### Mode Flags
```
--quick       SMART health + sequential I/O only
--full        All tests (default)
--stress      Full + extended endurance
--health      SMART/NVMe health checks only, no I/O
--dry-run     Show test plan and time estimate, then exit — no disk I/O
```

### Targeting
```
--device DEV        Test only this device  (e.g. /dev/nvme0n1, /dev/sda)
--exclude DEV       Skip this device (flag is repeatable)
--force             Bypass safety checks for in-use / RAID / LVM devices (DANGEROUS)
```

### Output
```
--json              Print machine-readable JSON summary to stdout
--log-dir DIR       Override log directory (default: /tmp/disktest_YYYYMMDD_HHMMSS/)
--save-baseline     Save results JSON as a baseline for future comparison
--compare FILE      Compare current results against a saved baseline JSON
```

---

## Safety System

Before any I/O begins, every device is inspected for conditions that would make raw block writes dangerous:

| Condition | Detection Method | Behaviour |
|---|---|---|
| Mounted partition (including root/boot) | `lsblk` MOUNTPOINT | Raw I/O skipped |
| Software RAID member | `/proc/mdstat` | Raw I/O skipped |
| LVM Physical Volume | `pvs` | Raw I/O skipped |
| ZFS vdev | `zpool status` | Raw I/O skipped |

Devices that fail safety checks will still have SMART / health checks run against them. Only raw fio I/O tests are skipped.

```
[FAIL] /dev/sda — UNSAFE for raw I/O: has mounted partitions: / /boot
[WARN] /dev/sda — Raw I/O tests will be SKIPPED (use --force to override)
```

To override (e.g. on a dedicated test bench where you know what you're doing):
```bash
sudo ./disktest.sh --full --force --device /dev/sda
```

> ⚠️ `--force` on a live system with mounted filesystems **will corrupt data**.

---

## I/O Scheduler Advisor

After device discovery, the script checks each device's current I/O scheduler and compares it against the optimal for the device type:

| Device Type | Optimal Scheduler | Reason |
|---|---|---|
| NVMe | `none` | Internal command queuing makes the kernel scheduler redundant |
| SSD | `none` / `mq-deadline` | Avoids scheduler overhead; deadline prevents starvation |
| HDD | `bfq` | Fair bandwidth allocation for spinning media |

If running as root and the recommended scheduler is available, it is applied immediately. Changes are runtime-only and reset on reboot. A `udev` persistence hint is printed.

```
[WARN] /dev/sda [hdd] — scheduler 'mq-deadline' → recommend 'bfq' (BFQ provides fair bandwidth...)
       To apply: echo 'bfq' | sudo tee /sys/block/sda/queue/scheduler
```

---

## Timeout Watchdog

Every `fio` job runs under a timeout scaled to its expected duration plus a buffer. If a drive stalls (common with failing HDDs or extreme throttling), the job is abandoned with a warning and zeroed results rather than hanging the entire test suite.

```
[WARN] /dev/sdb — fio job 'seq_write' timed out after 150s (drive may be degraded)
```

---

## Dry Run

`--dry-run` completes all discovery, safety checks, and scheduler analysis, then prints the full test plan with time estimates and exits without touching any disk. Use this before running on unfamiliar systems.

```bash
sudo ./disktest.sh --stress --dry-run
```

Example output:
```
━━━ Test Plan & Time Estimate ━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Mode:            stress
  Total devices:   4  (3 safe for I/O)
  Tests per disk:
    • SMART / NVMe health
    • Sequential read + write  (300s each)
    • Random 4K  ×4 QD + mixed  (300s each)
    • QD1 latency profile  (300s)
    • Filesystem fsync latency  (30s)
    • Stress: sustained write  (300s)
    • Stress: mixed load  (300s)
    • Multi-disk parallel  (300s)

  Estimated time:  ~42m 30s

DRY RUN — no I/O will be performed. Exiting.
```

---

## Output & Logs

### Console Output

All results use colour-coded prefixes:

| Prefix | Meaning |
|---|---|
| `[PASS]` (green) | Test passed threshold |
| `[WARN]` (yellow) | Passed but worth monitoring |
| `[FAIL]` (red) | Below threshold or error condition |

### Log Files

All detailed output is written to a timestamped directory (default `/tmp/disktest_YYYYMMDD_HHMMSS/`):

| File | Contents |
|---|---|
| `smart_<dev>.txt` | Full `smartctl -a` output |
| `nvme_<dev>.txt` | `nvme smart-log` output |
| `fio_<dev>_<job>.json` | Raw fio JSON per test |
| `fio_parallel_result.json` | Multi-disk parallel fio output |
| `disktest_results.json` | Summary JSON (with `--json` or `--save-baseline`) |

Override the log directory:
```bash
sudo ./disktest.sh --full --log-dir /var/log/disktests/node-07
```

### JSON Output

```bash
sudo ./disktest.sh --full --json 2>/dev/null | jq .summary
```

```json
{
  "passed": 24,
  "failed": 0,
  "warned": 2
}
```

---

## Thresholds

Default pass/fail thresholds. Edit the variables at the top of the script to tune for your hardware:

| Variable | Default | Description |
|---|---|---|
| `MIN_SEQ_READ_MB` | `200` | MB/s minimum sequential read |
| `MIN_SEQ_WRITE_MB` | `100` | MB/s minimum sequential write |
| `MIN_RAND_READ_IOPS` | `1000` | IOPS minimum random 4K read at QD32 |
| `MAX_LATENCY_US` | `5000` | µs maximum p99 QD1 read latency |
| `SMART_REALLOCATED_MAX` | `10` | Reallocated sector count before warning |

For NVMe drives (e.g. Samsung 990 Pro, WD SN850X) you'd typically raise these significantly:
```bash
MIN_SEQ_READ_MB=3000
MIN_SEQ_WRITE_MB=2000
MIN_RAND_READ_IOPS=500000
MAX_LATENCY_US=500
```

---

## Example Workflows

### New Node Certification (vast.ai / bare metal)
```bash
# 1. Preview the plan first
sudo ./disktest.sh --full --dry-run

# 2. Run full validation and save a baseline
sudo ./disktest.sh --full --json --save-baseline --log-dir /var/log/disktests/$(hostname)

# 3. Store the baseline JSON in your node inventory
```

### Nightly Health Check (cron)
```bash
# /etc/cron.d/disktest
0 3 * * * root /opt/disktest.sh --health --json >> /var/log/disktest_nightly.log 2>&1
```

### Post-Incident Drive Investigation
```bash
# Health only — zero writes to a suspect drive
sudo ./disktest.sh --health --device /dev/sdb

# Then if clean, escalate to quick
sudo ./disktest.sh --quick --device /dev/sdb
```

### Excluding the OS Disk
```bash
sudo ./disktest.sh --full --exclude /dev/sda
```

### Parallel Output for Fleet Automation
```bash
sudo ./disktest.sh --full --json 2>/dev/null > /tmp/results_$(hostname).json
```

---

## Test Execution Order

For every device, tests run in this sequence:

```
Prerequisites → Device Discovery → Topology → Safety Checks → Scheduler Advisor
  └─ Per device:
       ├─ SMART / NVMe health
       ├─ Sequential read + write          (skip if unsafe)
       ├─ Random 4K QD sweep              (skip if unsafe, full/stress only)
       ├─ QD1 latency profile             (skip if unsafe, full/stress only)
       ├─ Filesystem fsync latency        (full/stress only)
       └─ Stress endurance                (stress only)
  └─ Multi-disk parallel bandwidth        (full/stress, 2+ safe devices)
  └─ Summary
```

---

## Platform Support

| Platform | Status |
|---|---|
| Ubuntu 22.04 / 24.04 | ✅ Primary target |
| Debian 11 / 12 | ✅ |
| RHEL / Rocky / AlmaLinux 8–9 | ✅ (via `dnf`) |
| Arch Linux | ✅ (via `pacman`) |
| openSUSE / SLES | ✅ (via `zypper`) |

Tested with NVIDIA driver stacks (575/580/590 series) on multi-GPU nodes with NVMe, SATA SSD, and HDD configurations.
