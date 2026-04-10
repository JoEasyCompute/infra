# fulltest.sh — GPU Test Suite

Multi-GPU acceptance and health validation script for NVIDIA GPUs.  
Supports: RTX 4090 / RTX 5090, A4000, A100, H100 on Ubuntu 22.04 / 24.04.

---

## Requirements

### Must be pre-installed

| Requirement | Notes |
|---|---|
| NVIDIA driver | 575+ recommended for CUDA 12.9 |
| CUDA toolkit | `nvcc` must be on PATH or in `/usr/local/cuda/bin` |
| `git`, `make`, `gcc` | Build tools |
| `python3`, `python3-pip` | For PyTorch and inline test scripts |
| `bc` | For duration formatting in burn test output |

### Auto-installed on first run

| Dependency | Used by |
|---|---|
| `cmake` | nvbandwidth, cuda_memtest, cuda-samples |
| `libboost-program-options-dev` | nvbandwidth |
| `libnccl2` / `libnccl-dev` | NCCL test — version-pinned to match active CUDA toolkit |
| PyTorch + accelerate | pytorch test, clock test, pcie test |
| Rust toolchain (via rustup) | gpu-fryer (primary stress tool) |

### Optional

| Dependency | Notes |
|---|---|
| `dcgmi` (DCGM) | `dcgm` test is skipped gracefully if not installed. Install from https://developer.nvidia.com/dcgm |

---

## Installation

```bash
chmod +x test/fulltest.sh

# First run — clones repos and builds binaries into ./build/
./test/fulltest.sh
```

All cloned repos and compiled binaries are placed under `./build/` next to the script. Nothing is written to system directories except NCCL and apt packages.

If a previous run left `./build/` or one of the cloned repos owned by root or otherwise unwritable, the script now warns before clone / rebuild / helper-script write / `--clean` operations and tells you how to fix ownership. A common recovery command is:

```bash
sudo chown -R "$USER":"$(id -gn)" ./test/build
```

---

## Usage

```
./test/fulltest.sh [test...] [--gpu <index[,index...]>] [--burn-duration <seconds>] [--clean] [--list] [--help]
```

### Run all tests on all GPUs
```bash
./test/fulltest.sh
```

### Run all tests on specific GPU(s)
```bash
./test/fulltest.sh --gpu 3            # single GPU
./test/fulltest.sh --gpu 2,4,5        # subset of GPUs
```

### Run specific tests only
```bash
./test/fulltest.sh preflight ecc pcie clocks       # hardware health checks only
./test/fulltest.sh nccl pytorch                    # communication + framework only
./test/fulltest.sh memtest                         # VRAM integrity only
./test/fulltest.sh stress                          # stress test only (default 5 min)
```

### Combine: specific tests on specific GPUs
```bash
./test/fulltest.sh --gpu 3 memtest stress
./test/fulltest.sh --gpu 2,4,5 memtest stress
./test/fulltest.sh --gpu 0,1 preflight ecc pcie
```

---

## Options

| Option | Default | Description |
|---|---|---|
| `--gpu <index[,index...]>` | all GPUs | Target one or more GPUs by index — single (`3`) or comma-separated (`2,4,5`). Indices are 0-based as shown by `nvidia-smi`. |
| `--burn-duration <seconds>` | `300` (5 min) | Duration of the sustained stress test. |
| `--clean` | — | Delete `./build/` and exit. Forces full rebuild on next run. Can be combined with tests to clean then immediately run. |
| `--list` | — | Print available test names and exit. |
| `--help` / `-h` | — | Show usage and exit. |

If `--clean` or a rebuild path fails because `./build/` is not writable, the script now prints the affected path, current owner / permissions when available, and a suggested `chown` command instead of failing later in the build.

---

## Examples

```bash
# Full suite, all GPUs
./test/fulltest.sh

# Full suite, GPU 3 only (e.g. after a card swap)
./test/fulltest.sh --gpu 3

# Full suite on GPUs 2, 4, and 5 (e.g. after swapping multiple cards)
./test/fulltest.sh --gpu 2,4,5

# 30-minute stress test on GPU 5 only
./test/fulltest.sh --gpu 5 stress --burn-duration 1800

# memtest + stress on a specific subset
./test/fulltest.sh --gpu 2,4,5 memtest stress

# 1-hour stress test on all GPUs
./test/fulltest.sh stress --burn-duration 3600

# Quick hardware health check only
./test/fulltest.sh preflight ecc pcie clocks

# NCCL + PyTorch DDP only (comms stack validation)
./test/fulltest.sh nccl pytorch

# Wipe all build artifacts and start fresh
./test/fulltest.sh --clean

# Wipe build artifacts then immediately run NCCL
./test/fulltest.sh --clean nccl

# List available test names
./test/fulltest.sh --list
```

---

## GPU Targeting (`--gpu`)

`--gpu` accepts a single index or a comma-separated list of indices, matching the physical GPU numbers shown by `nvidia-smi` (0-based).

```bash
--gpu 3          # single GPU
--gpu 2,4,5      # subset of GPUs
```

When specified:

- `CUDA_VISIBLE_DEVICES` is set to the target list, scoping all CUDA processes to those GPUs only
- All `nvidia-smi` queries use `-i <list>` to filter telemetry, thermal data, ECC, PCIe, and clock tables to those cards only
- `NUM_GPUS` is set to the count of indices provided, so NCCL runs with `-g N` and PyTorch with `--nproc_per_node N`
- `memtest` runs `--device 0..N-1` (remapped from physical indices via `CUDA_VISIBLE_DEVICES`)
- All indices are validated against the actual GPU count — any invalid index exits immediately with a clear error

```bash
# Test GPU 3 only
./test/fulltest.sh --gpu 3 memtest stress

# Test GPUs 2, 4, and 5 together
./test/fulltest.sh --gpu 2,4,5

# Invalid index gives a clean error
./test/fulltest.sh --gpu 9
# ERROR: --gpu invalid index(es): 9. System has GPUs 0-7.
```

> NCCL all-reduce and PyTorch DDP run across whatever GPUs are in scope — they work correctly with 1 GPU, a subset, or all GPUs.

---

## Tests

Tests run in this fixed order when none are specified. Each test is independently selectable by name.

---

### `preflight` — Idle Baseline

Runs before any load is applied. Captures a per-GPU snapshot at idle covering persistence mode, thermals, and driver version.

**Persistence mode:** Checks each GPU has persistence mode enabled. Warns (not fails) if disabled, with the command to enable it (`sudo nvidia-smi -pm 1`).

**Thermal baseline:** Records temperature, power draw, SM clock, memory clock, fan speed, and throttle reason per GPU at idle in a formatted table.

**Driver version:** Logs the active driver version per GPU.

**Fails if:**
- Any GPU has an active hardware throttle reason at idle (HW_Slowdown, SW_Thermal, or HW_PowerBrake)
- Any GPU idle temperature exceeds 60°C

**Notes:** `sw_power_cap` (bitmask `0x4`) at idle is normal power-saving clock-down — decoded and suppressed. Only real hardware fault bits trigger a warning.

---

### `ecc` — ECC Error Check

Checks ECC mode and uncorrected volatile error count per GPU.

| GPU Type | Behaviour |
|---|---|
| GeForce (RTX 4090, 5090, etc.) | ECC not supported — noted in output, not a failure |
| Workstation (A4000, A6000, etc.) | ECC supported but off by default — warning with enable command |
| Data Centre (A100, H100, etc.) | ECC on by default — hard failure if uncorrected errors > 0 |

**Fails if:** A Data Centre GPU reports any uncorrected ECC errors. This indicates live VRAM corruption — the GPU should be replaced.

**Enable ECC on workstation GPUs:**
```bash
sudo nvidia-smi -e 1
sudo reboot
```

---

### `pcie` — PCIe Link Check

Verifies PCIe link width and generation per GPU. Always spins up a brief GPU load before sampling to force links to their negotiated speed.

| Check | Severity | Notes |
|---|---|---|
| Gen mismatch (e.g. Gen1 vs Gen3) | **Warning only** | ASPM legitimately power-gates link speed at idle — not a failure |
| Width mismatch (e.g. x8 vs x16) | **Hard failure** | Lane count never power-gates — always a physical problem |

**Fails if:** Any GPU is running fewer PCIe lanes than its maximum (x8 when capable of x16). Likely causes: GPU in an x8 physical slot, damaged riser cable, or BIOS lane allocation.

**Notes:** Gen speed mismatch at idle is not a real issue on systems with ASPM enabled — this is explained in the test output. If NVBandwidth host↔device bandwidth numbers are normal (~25–30 GB/s for PCIe 4.0 x16), there is no actual problem.

To force Gen3 at all times (disables power saving):
```bash
sudo sh -c 'echo performance > /sys/module/pcie_aspm/parameters/policy'
```

---

### `clocks` — Clock Verification Under Load

Runs a 30-second GEMM workload and samples SM clock, memory clock, and throttle reason every 3 seconds across all GPUs in scope. Prints a live table during the test, then a summary.

**Fails if:** Any real throttle reason is active during the load.

**Throttle reason guide:**

| Reason | Meaning | Action |
|---|---|---|
| `HW_Slowdown` | Hardware thermal or power event | Check temps, PSU, power connectors |
| `SW_Thermal` | GPU hit its temperature limit | Improve cooling or reduce power limit |
| `HW_PowerBrake` | External power brake signal | Check PSU capacity and cable connections |
| `sw_power_cap` | Normal idle clock-down | Ignored — not a problem |

---

### `nccl` — NCCL All-Reduce

Runs `all_reduce_perf` from [nccl-tests](https://github.com/NVIDIA/nccl-tests) across all GPUs in scope, sweeping message sizes from 8B to 1GB.

**Fails if:** NCCL communication fails for any message size.

**On failure:** Automatically re-runs with `NCCL_DEBUG=INFO` and prints filtered diagnostic output — no manual re-run needed.

**NCCL version pinning:** Before building, the script checks `libnccl2`'s CUDA suffix against the active toolkit. If mismatched (e.g. `+cuda13.1` with a CUDA 12.9 toolkit — a known issue when DCGM pulls in a different NCCL variant), it removes and reinstalls the correct version automatically.

To fix manually:
```bash
apt-cache madison libnccl2 | grep cuda12
sudo apt-get install libnccl2=<version> libnccl-dev=<version>
./test/fulltest.sh --clean nccl
```

---

### `cuda-samples` — CUDA Runtime Validation

Builds and runs two samples from [cuda-samples](https://github.com/NVIDIA/cuda-samples):

| Sample | What it tests |
|---|---|
| `deviceQuery` | CUDA runtime init, GPU enumeration, driver/runtime version, capability flags |
| `p2pBandwidthLatencyTest` | GPU-to-GPU P2P access, bandwidth, and latency |

**Fails if:** Either binary fails to build or exits non-zero.

**Notes:** `sm_110` is automatically patched out of CMakeLists before building — it was removed in CUDA 12.9 but is hardcoded in the cuda-samples repo.

---

### `nvbandwidth` — Memory Bandwidth

Runs [NVBandwidth](https://github.com/NVIDIA/nvbandwidth) — NVIDIA's official replacement for the removed `bandwidthTest`:

| Test | Description |
|---|---|
| `host_to_device_memcpy_ce` | PCIe upload bandwidth |
| `device_to_host_memcpy_ce` | PCIe download bandwidth |
| `device_to_device_memcpy_read_ce` | VRAM read bandwidth |
| `device_to_device_memcpy_write_ce` | VRAM write bandwidth |
| `device_to_device_bidirectional_memcpy_read_ce` | Bidirectional VRAM bandwidth |

**Fails if:** NVBandwidth exits non-zero.

**Buffer sizing:** The script automatically caps the per-GPU buffer to 25% of single-GPU VRAM, with a hard ceiling of 512 MB. This prevents OOM failures on multi-GPU systems with large VRAM (e.g. 8× RTX 5090) where nvbandwidth's default buffer size multiplied across GPUs and concurrent test cases can exhaust available memory.

**OOM handling:** If nvbandwidth hits an out-of-memory error despite the buffer cap, the result is treated as a **warning rather than a failure** — partial bandwidth results are still logged and useful. A note is printed directing attention to any other VRAM consumers that may be running.

**Notes:** Device-to-device tests are skipped by NVBandwidth itself on single-GPU systems — expected, not a failure.

---

### `dcgm` — DCGM Diagnostics *(optional)*

Runs NVIDIA Data Centre GPU Manager diagnostics if `dcgmi` is installed. Skipped gracefully with an install link if not present.

Runs:
- `dcgmi discovery -l` — enumerate GPUs
- `dcgmi diag -r 3` — deployment-level health check
- `dcgmi dmon -e 203,252,150,155 -c 10` — 10 samples of GPU util, memory util, temperature, and power draw

**Notes:** DCGM hardware and stress subtests are automatically skipped on GeForce GPUs — this is expected behaviour, not a test failure.

---

### `pytorch` — Multi-GPU DDP Benchmark

Installs PyTorch (wheel auto-selected by CUDA version) and runs a multi-GPU DistributedDataParallel benchmark via `torchrun`.

Runs 100 forward passes of a 10,000×10,000 linear layer across all GPUs in scope using NCCL as the collective backend.

**Fails if:** PyTorch install fails, `torchrun` not found, NCCL process group init fails, or any forward pass errors.

**Failure diagnostics:** On failure, the script now keeps the generated DDP repro script in `/tmp`, emits a condensed summary of the failing `local_rank` / child exit code, and prints a direct `torchrun` repro command plus a suggested debug rerun with `NCCL_DEBUG=INFO` and `TORCH_DISTRIBUTED_DEBUG=DETAIL`.

**Python runtime warning:** The script now logs the active `python3` runtime before installing/running PyTorch. If it detects Python 3.12 or newer, it warns that `torch.distributed` / `torchrun` has known segfault history there and recommends Python 3.10/3.11 if DDP initialization crashes.

**PyTorch wheel selection:**

| CUDA Version | Wheel |
|---|---|
| 11.x | `cu118` |
| 12.0–12.1 | `cu121` |
| 12.2–12.4 | `cu124` |
| 12.5+ | `cu128` |

**Notes:** On Ubuntu 24.04+, `--break-system-packages` is added to pip installs automatically (PEP 668 compliance).

---

### `memtest` — VRAM Integrity

Builds and runs [cuda_memtest](https://github.com/ComputationalRadiationPhysics/cuda_memtest) — the GPU equivalent of memtest86.

Runs 10 passes of memory stress testing per GPU in scope, writing pseudorandom patterns across all available VRAM and verifying readback. All GPUs run in parallel; exit codes are collected after all complete.

**Fails if:** Any GPU reports a memory error on any pass.

---

### `stress` — Sustained Compute Stress

Runs a sustained compute workload for the configured duration while a background thermal monitor samples every 5 seconds.

**Tool selection (in priority order):**

| Tool | Method | Notes |
|---|---|---|
| [gpu-fryer](https://github.com/huggingface/gpu-fryer) | BF16 Tensor Core GEMM | Primary — Rust binary, no CUDA compilation required |
| [gpu-burn](https://github.com/wilicc/gpu-burn) | FP64 GEMM | Secondary fallback |
| PyTorch cuBLAS loop | BF16 8192×8192 GEMM | Final fallback — always available if PyTorch is installed |

**Thermal monitoring during burn:**

A background monitor samples all GPUs in scope every 5 seconds throughout the burn and prints a live table:

```
  Elapsed  GPU  Temp°C  Power W   Fan %   SM MHz  Throttle
  5s         0    72    440.5 W    78%     2520    Not Active
  5s         1    74    441.2 W    79%     2520    Not Active
```

At the end a per-GPU peak summary is printed:

```
  GPU  Name                      PeakTemp  PeakFan  Issues
  0    NVIDIA GeForce RTX 5090      84°C      92%   OK
  1    NVIDIA GeForce RTX 5090      89°C     100%   TEMP 89°C >= 87°C  FAN at 100%
```

**Thermal thresholds** (configurable at the top of the script):

| Constant | Default | Flag |
|---|---|---|
| `TEMP_WARN` | `87°C` | `TEMP <n>°C >= 87°C (check thermal paste/airflow)` |
| `FAN_WARN` | `100%` | `FAN at 100% (cooling at limit)` |

**Fails if:**
- The burn tool exits non-zero (compute error or GPU crash)
- Any GPU in scope exceeds a thermal threshold during the run

> A thermal failure means the compute test passed but cooling needs investigation. The GPU appears as `FAIL` in the summary to ensure it gets attention rather than being buried in scrollback.

---

## Output

### Terminal

All output is printed live to the terminal with section headers and result markers:

```
========================================
Running: NCCL All-Reduce Test
========================================
...
[ PASS ] NCCL All-Reduce Test
```

### Log file

A timestamped log is written alongside the script:

```
fulltest_YYYYMMDD_HHMMSS.log
```

The log header captures hostname, IP addresses, user, and timestamp — useful when collecting logs from multiple machines:

```
============================================================
  fulltest.sh — GPU Test Suite
  Date     : 2026-02-24 15:05:15 UTC
  Hostname : ezc-tensora-15g
  IP(s)    : 172.16.10.16
  User     : ezc
  Script   : /home/ezc/infra/test/fulltest.sh
============================================================
```

### Summary

The final summary block is self-contained and includes host identification:

```
========================================
TEST SUMMARY
========================================
  Host     : ezc-tensora-15g
  IP(s)    : 172.16.10.16
  GPUs     : NVIDIA GeForce RTX 5090
  Arch(es) : 120
  CUDA     : 12.9
  Log file : /home/ezc/infra/test/fulltest_20260224_150515.log

  PASSED (11):
    ✓  Preflight (Thermal Baseline / Persistence / Driver)
    ✓  ECC Error Check
    ✓  PCIe Link Width / Generation
    ✓  Clock Speed Under Load
    ✓  NCCL All-Reduce Test
    ✓  CUDA Samples (deviceQuery / p2pBandwidthLatencyTest)
    ✓  NVBandwidth (GPU Memory Bandwidth)
    ✓  DCGM Diagnostics
    ✓  PyTorch Multi-GPU Benchmark
    ✓  cuda_memtest (GPU Memory Stress)
    ✓  Sustained Compute Stress (5.0 min)

========================================
  RESULT: ALL 11 TESTS PASSED
========================================
```

**Exit code:** `0` if all tests pass, `1` if any test fails — suitable for CI/CD pipelines.

---

## Build Directory

All compiled binaries and cloned repos live under `./build/` next to the script. Builds are idempotent — existing binaries are reused on subsequent runs.

```
build/
  nccl-tests/
  cuda-samples/
  nvbandwidth/
  cuda_memtest/
  gpu-fryer/
  gpu-burn/
```

**Force full rebuild:**
```bash
# Clean and exit
./test/fulltest.sh --clean

# Clean then immediately run specific tests
./test/fulltest.sh --clean nccl memtest
```

---

## Configurable Constants

Defined near the top of the script — edit directly to change defaults:

| Constant | Default | Description |
|---|---|---|
| `BURN_DURATION` | `300` | Default stress duration in seconds (overridden by `--burn-duration`) |
| `TEMP_WARN` | `87` | Temperature threshold in °C for burn test thermal flag |
| `FAN_WARN` | `100` | Fan speed threshold in % for burn test thermal flag |

---

## Common Issues

### NCCL fails with "CUDA driver version is insufficient"

`libnccl2` is built against a different CUDA version than the active toolkit. This commonly happens when DCGM installs `libnccl2+cuda13.x` on a CUDA 12.x system. The script detects and fixes this automatically on the next run. To fix manually:

```bash
apt-cache madison libnccl2 | grep cuda12
sudo apt-get install libnccl2=<version> libnccl-dev=<version>
./test/fulltest.sh --clean nccl
```

### PCIe test shows Gen1 warning

Normal on any system with ASPM (Active State Power Management) enabled — the PCIe link power-gates to Gen1 at idle. This is a **warning, not a failure**. Confirm there is no real issue by checking NVBandwidth host↔device results: if bandwidth is normal (~25–30 GB/s for PCIe 4.0 x16), the hardware is fine.

### Preflight fails with throttle warning at idle

Indicates a real hardware throttle event at idle (not normal clock-down). Investigate with:

```bash
nvidia-smi --query-gpu=index,clocks_throttle_reasons.active --format=csv
nvidia-smi -q -d CLOCK
```

### cuda-samples build fails on CUDA 12.9

The script patches `sm_110` out of CMakeLists automatically. If the build still fails, force a clean rebuild:

```bash
./test/fulltest.sh --clean cuda-samples
```

### gpu-fryer unavailable (Rust not installed)

Rust is installed automatically via `rustup`. If `cargo` is still unavailable, the script falls back to gpu-burn, then to the PyTorch cuBLAS stress fallback automatically — no manual action needed.

### `--gpu` reports invalid index

```bash
./test/fulltest.sh --gpu 9
# ERROR: --gpu invalid index(es): 9. System has GPUs 0-7.

./test/fulltest.sh --gpu 2,9,4
# ERROR: --gpu invalid index(es): 9. System has GPUs 0-7.
```

Use `nvidia-smi -L` to list available GPU indices.
