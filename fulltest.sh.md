# fulltest.sh — GPU Test Suite

Multi-GPU acceptance and health validation script for NVIDIA GPUs.  
Supports: RTX 4090 / RTX 5090, A4000, A100, H100 on Ubuntu 22.04 / 24.04.

---

## Requirements

**Must be pre-installed (script will not install these):**

| Requirement | Notes |
|---|---|
| NVIDIA driver | 575+ recommended for CUDA 12.9 |
| CUDA toolkit | nvcc must be on PATH or in `/usr/local/cuda/bin` |
| `git`, `make`, `gcc` | Build tools |
| `python3-pip` | For PyTorch install |
| `bc` | For duration formatting |

**Auto-installed on first run:**

| Dependency | Used by |
|---|---|
| `cmake` | nvbandwidth, cuda_memtest, cuda-samples |
| `libboost-program-options-dev` | nvbandwidth |
| `libnccl2` / `libnccl-dev` | NCCL test (version-pinned to match CUDA) |
| PyTorch + accelerate | PyTorch DDP benchmark, clock test, PCIe test |
| Rust toolchain (via rustup) | gpu-fryer (stress test) |

**Optional:**

| Dependency | Notes |
|---|---|
| `dcgmi` (DCGM) | DCGM test is skipped gracefully if not installed |

---

## Installation

```bash
# Clone or copy fulltest.sh to your test directory
chmod +x fulltest.sh

# First run — all dependencies and build artifacts go into ./build/
./fulltest.sh
```

All cloned repos and compiled binaries are placed under `./build/` next to the script. Nothing is written to system directories.

---

## Usage

```
./fulltest.sh [test...] [--burn-duration <seconds>] [--clean] [--list] [--help]
```

### Run all tests
```bash
./fulltest.sh
```

### Run specific tests only
```bash
./fulltest.sh preflight ecc pcie clocks     # hardware health checks only
./fulltest.sh nccl pytorch                  # communication + framework only
./fulltest.sh memtest                       # VRAM integrity only
./fulltest.sh stress                        # stress test only (default 5 min)
```

### Options

| Option | Description |
|---|---|
| `--burn-duration <seconds>` | Override stress test duration (default: 300 = 5 min) |
| `--clean` | Delete `build/` directory (forces full rebuild on next run) |
| `--list` | Print available test names and exit |
| `--help` | Show usage and exit |

### Examples

```bash
# Full suite with 30-minute stress test
./fulltest.sh --burn-duration 1800

# 1-hour stress test only
./fulltest.sh stress --burn-duration 3600

# Wipe all build artifacts and re-run everything fresh
./fulltest.sh --clean

# Clean then immediately run a specific test
./fulltest.sh --clean nccl
```

---

## Tests

Tests run in this order when none are specified. Each test is independently selectable by name.

### `preflight` — Idle Baseline
Runs before any load is applied. Captures a per-GPU snapshot of temperature, power draw, SM clock, memory clock, fan speed, and throttle reason at idle. Also checks persistence mode and driver version.

- **Fails if:** Any GPU is throttling due to a real hardware problem (thermal or power brake) at idle, or idle temperature exceeds 60°C.
- **Notes:** `sw_power_cap` (0x4) at idle is normal power-saving behaviour and is ignored.

---

### `ecc` — ECC Error Check
Checks ECC mode and uncorrected error count per GPU.

| GPU Type | Behaviour |
|---|---|
| GeForce (RTX 4090, 5090) | ECC not supported — skipped with a note, not a failure |
| Workstation (A4000, A6000) | ECC supported but off by default — warning with enable instructions |
| Data Centre (A100, H100) | ECC on by default — fails if any uncorrected errors found |

- **Fails if:** A Data Centre GPU reports uncorrected ECC errors (indicates live VRAM corruption — GPU should be replaced).

---

### `pcie` — PCIe Link Check
Verifies PCIe link width and generation per GPU. Spins up a brief GPU load before sampling to force links to full negotiated speed.

| Check | Behaviour |
|---|---|
| Gen mismatch (e.g. Gen1 vs Gen3) | **Warning only** — ASPM idle power-gating is normal |
| Width mismatch (e.g. x8 vs x16) | **Hard failure** — lane count never power-gates |

- **Fails if:** Any GPU is running at fewer PCIe lanes than its maximum (x8 when capable of x16). This indicates a physical slot limitation, riser cable issue, or BIOS lane allocation problem.
- **Notes:** Gen speed mismatch at idle is not a failure. If NVBandwidth host↔device numbers are normal, Gen mismatch is not a real issue.

---

### `clocks` — Clock Verification Under Load
Runs a 30-second GEMM workload and samples SM clock, memory clock, and throttle reason every 3 seconds across all GPUs.

- **Fails if:** Any real throttle reason is detected (HW_Slowdown, SW_Thermal, HW_PowerBrake).
- **Reports:** A live table of clocks per GPU per sample, and a final note on throttle cause if any.

Throttle reason guide:

| Reason | Cause |
|---|---|
| `HW_Slowdown` | Hardware thermal or power event |
| `SW_Thermal` | GPU hit its temperature limit |
| `HW_PowerBrake` | External power brake signal (PSU/power delivery) |
| `sw_power_cap` | Normal idle clock-down — ignored |

---

### `nccl` — NCCL All-Reduce
Runs `all_reduce_perf` from [nccl-tests](https://github.com/NVIDIA/nccl-tests) across all GPUs, testing message sizes from 8B to 1GB.

- **Fails if:** NCCL communication fails for any reason.
- **On failure:** Automatically re-runs with `NCCL_DEBUG=INFO` and prints filtered diagnostic output, so the root cause is visible without a manual re-run.
- **NCCL version pinning:** `libnccl2` is automatically checked against the active CUDA toolkit version. If a mismatched version is found (e.g. `+cuda13.1` when toolkit is CUDA 12.9), it is removed and the correct version installed before building.

---

### `cuda-samples` — CUDA Runtime Validation
Builds and runs two samples from [cuda-samples](https://github.com/NVIDIA/cuda-samples):

| Sample | Tests |
|---|---|
| `deviceQuery` | CUDA runtime initialisation, GPU enumeration, capability reporting |
| `p2pBandwidthLatencyTest` | GPU-to-GPU P2P bandwidth and latency |

- **Fails if:** Either binary fails to build or returns a non-zero exit code.
- **Notes:** `sm_110` is automatically patched out of CMakeLists before building — it was removed in CUDA 12.9 but hardcoded in the cuda-samples repo.

---

### `nvbandwidth` — Memory Bandwidth
Runs [NVBandwidth](https://github.com/NVIDIA/nvbandwidth) (NVIDIA's official replacement for the removed `bandwidthTest`) measuring:

- Host → Device (PCIe upload)
- Device → Host (PCIe download)
- Device → Device read / write / bidirectional (VRAM throughput)

- **Fails if:** NVBandwidth returns a non-zero exit code.
- **Notes:** Device-to-device tests are waived on single-GPU systems — this is expected.

---

### `dcgm` — DCGM Diagnostics *(optional)*
Runs NVIDIA Data Centre GPU Manager diagnostics if `dcgmi` is installed. Skipped gracefully if not.

Runs:
- `dcgmi discovery -l` — enumerate GPUs
- `dcgmi diag -r 3` — deployment health check
- `dcgmi dmon` — 10 samples of GPU util, memory util, temperature, power

- **Notes:** Hardware and stress subtests within DCGM are skipped on GeForce GPUs — this is expected behaviour, not a failure.
- **Install DCGM:** https://developer.nvidia.com/dcgm

---

### `pytorch` — Multi-GPU DDP Benchmark
Installs PyTorch (version matched to the active CUDA toolkit) and runs a multi-GPU DistributedDataParallel benchmark using `torchrun`.

Runs 100 forward passes of a large linear layer across all GPUs using NCCL as the collective backend.

- **Fails if:** PyTorch install fails, `torchrun` is not found, NCCL process group init fails, or any GPU returns an error during the forward pass.
- **Notes:** PyTorch wheel is auto-selected based on CUDA version (cu118 / cu121 / cu124 / cu128). On Ubuntu 24.04, `--break-system-packages` is used automatically.

---

### `memtest` — VRAM Integrity
Builds and runs [cuda_memtest](https://github.com/ComputationalRadiationPhysics/cuda_memtest) — the GPU equivalent of memtest86.

Runs 10 passes of Test 10 (memory stress) per GPU in parallel, writing pseudorandom patterns across all available VRAM and verifying readback.

- **Fails if:** Any GPU reports a memory error on any pass.
- **Notes:** All GPUs are tested simultaneously. Exit codes are collected after all finish — a failure on any GPU fails the test.

---

### `stress` — Sustained Compute Stress
Runs a sustained compute workload for the specified duration (default 5 minutes) while a background thermal monitor samples every 5 seconds.

**Tool selection hierarchy:**

| Tool | Method | Notes |
|---|---|---|
| [gpu-fryer](https://github.com/huggingface/gpu-fryer) | BF16 Tensor Core GEMM | Primary — Rust binary, no CUDA compile, works on all drivers |
| [gpu-burn](https://github.com/wilicc/gpu-burn) | FP64 GEMM | Secondary fallback |
| PyTorch cuBLAS loop | BF16 8192×8192 GEMM | Final fallback — always available |

**Thermal monitoring during burn:**

The monitor records per-GPU peak temperature, peak fan speed, and any throttle events. At the end it prints a summary table and flags:

| Threshold | Flag |
|---|---|
| Temperature ≥ 87°C | `TEMP` warning |
| Fan speed = 100% | `FAN` warning |
| Any active throttle reason | `THROTTLE` warning |

- **Fails if:** The burn tool exits with a non-zero code (compute error), **or** any GPU exceeds a thermal threshold.
- **Thresholds** are configurable at the top of the script: `TEMP_WARN` (default 87°C) and `FAN_WARN` (default 100%).

---

## Output

### Screen output
All test output is printed to the terminal as it runs, with section headers and `[ PASS ]` / `[ FAIL ]` / `[ SKIPPED ]` markers.

### Log file
A timestamped log file is written to the same directory as the script:
```
fulltest_YYYYMMDD_HHMMSS.log
```

The log header includes hostname, IP addresses, user, and timestamp for identification when collecting logs from multiple machines.

### Summary
The final summary shows:
```
========================================
TEST SUMMARY
========================================
  Host     : my-gpu-server
  IP(s)    : 10.0.0.5
  GPUs     : NVIDIA GeForce RTX 5090
  Arch(es) : 120
  CUDA     : 12.9
  Log file : /home/user/test/fulltest_20260224_150515.log

  PASSED (11):
    ✓  Preflight (Thermal Baseline / Persistence / Driver)
    ✓  ECC Error Check
    ...

  SKIPPED (1):
    -  DCGM Diagnostics — dcgmi not found

  FAILED (1):
    ✗  Sustained Compute Stress (5.0 min)

========================================
  RESULT: 1 test(s) FAILED
========================================
```

Exit code is `0` if all tests pass, `1` if any test fails — suitable for CI/CD pipelines.

---

## Build Directory

All compiled binaries and cloned repos are placed under `./build/` next to the script. Builds are idempotent — already-built binaries are reused on subsequent runs.

```
build/
  nccl-tests/
  cuda-samples/
  nvbandwidth/
  cuda_memtest/
  gpu-fryer/
  gpu-burn/
```

To force a full rebuild:
```bash
./fulltest.sh --clean
```

Or delete manually:
```bash
rm -rf build/
```

---

## Common Issues

### NCCL fails with "CUDA driver version is insufficient"
`libnccl2` is built against a different CUDA version than your toolkit. The script detects and fixes this automatically on the next run. To fix manually:
```bash
apt-cache madison libnccl2 | grep cuda12   # find matching version
sudo apt-get install libnccl2=<version> libnccl-dev=<version>
./fulltest.sh --clean nccl
```

### PCIe test reports Gen1 warning
Normal on systems with ASPM enabled — the link power-gates to Gen1 at idle. This is a warning, not a failure. Verify by checking NVBandwidth host↔device results. If bandwidth is normal (~25–30 GB/s for PCIe 4.0 x16), there is no real issue.

### Preflight fails with throttle warning at idle
Indicates a real hardware throttle event at idle (not normal idle clock-down). Check `nvidia-smi -q -d CLOCK` for details and `nvidia-smi --query-gpu=clocks_throttle_reasons.active --format=csv`.

### cuda-samples build fails on CUDA 12.9
The script patches out `sm_110` from CMakeLists automatically. If build still fails, run `./fulltest.sh --clean cuda-samples` to force a fresh clone and rebuild.

### gpu-fryer build fails (Rust)
Rust is installed automatically via rustup. If cargo is unavailable after install, the script falls back to gpu-burn, then to the PyTorch stress fallback. No action needed unless you specifically want gpu-fryer.
