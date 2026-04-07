# ramtest.sh Documentation

Server RAM validation and burn-in using `stressapptest`.

## Overview

`ramtest.sh` is the live-OS complement to the repo's GPU, disk, and network checks. It focuses on **system RAM**, not GPU VRAM, and is intended for post-provision qualification on Linux servers.

The script:

- uses `stressapptest` to maximize randomized memory traffic from CPU and memory worker threads
- sizes the test automatically so the host keeps enough RAM for the OS
- logs the run to a dedicated directory under `/tmp/ramtest_*`
- records EDAC ECC counters before and after the run when the kernel exposes them

For the deepest possible memory validation, pair this with an **offline Memtest86+ run** during a maintenance window. `ramtest.sh` is the best fit for normal provisioning and acceptance workflows because it can run directly on the installed host.

## Requirements

- Linux server (Ubuntu 22.04/24.04 expected, but other distros may work)
- `stressapptest` available in the package manager or preinstalled
- Root recommended for package installation, `dmidecode`, and ECC observations

If `stressapptest` is missing, the script attempts to install it automatically unless `--no-install` is used.

## Usage

```bash
# 15-minute qualification run
sudo ./test/ramtest.sh --quick

# 1-hour default burn-in
sudo ./test/ramtest.sh --full

# Extended run with a larger OS reserve
sudo ./test/ramtest.sh --burn --reserve-gb 8

# Explicit memory target and thread count
sudo ./test/ramtest.sh --duration 7200 --mem-gb 240 --threads 8
```

## Modes

| Mode | Runtime | Use case |
|---|---:|---|
| `--quick` | 15 min | Fast triage after provisioning or DIMM replacement |
| `--full` | 60 min | Default qualification before handing over a host |
| `--burn` | 4 hr | Extended burn-in for new fleet arrivals or suspicious hardware |

## Memory Sizing

By default, the script tests:

- **total RAM minus the larger of 4 GiB or 10% of system RAM**

This keeps the OS responsive while still stressing most installed memory. Override with:

- `--mem-gb <GB>` to test an explicit amount
- `--reserve-gb <GB>` to leave more headroom for the host

## Pass / Fail Behavior

The run fails if:

- `stressapptest` exits non-zero
- uncorrected ECC counters increase during the run

The run warns if corrected ECC counters increase, because that often points to a weak DIMM or channel even when the host survives the test.

Logs are written to the selected `--log-dir` (default `/tmp/ramtest_*`):

- `stressapptest.log` — tool-native log output
- `console.log` — full console transcript

## Operational Notes

- Use this script for **server RAM**; GPU VRAM integrity remains in `test/fulltest.sh memtest`.
- Run **Memtest86+ offline** when chasing intermittent faults, boot-looping hosts, or pre-production burn-in that must cover memory unavailable to the running OS.
- If ECC deltas increase, keep the logs and correlate them with `dmesg`, BMC/IPMI events, and DIMM slot inventory from `gpucheck/srv-inv.sh` or `gpucheck/dimm-inv.sh`.
