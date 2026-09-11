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
| `stress-ng`, `lm-sensors` | For the node-stress CPU/RAM load and sensor snapshots |
| `bc` | For duration formatting in burn test output |

### Auto-installed on first run

| Dependency | Used by |
|---|---|
| `cmake` | nvbandwidth, cuda_memtest, cuda-samples |
| `libboost-program-options-dev` | nvbandwidth |
| `libnccl2` / `libnccl-dev` | NCCL test — version-pinned to match active CUDA toolkit |
| PyTorch | pytorch test, clock test, pcie test, PyTorch stress fallback |
| Rust toolchain (via rustup) | gpu-fryer (primary stress tool) |

### Optional

| Dependency | Notes |
|---|---|
| `dcgmi` (DCGM) | `dcgm` and opt-in `fabric-health` tests use DCGM. Missing DCGM is reported without failing the suite. Install from https://developer.nvidia.com/dcgm |

---

## Installation

```bash
chmod +x test/fulltest.sh test/code.sh

# First run — clones repos and builds binaries into ./build/
./test/fulltest.sh
```

Deploy `fulltest.sh`, executable `code.sh`, and readable `code.cu` together in the same directory. For the orchestrated bundle and reboot behavior, see [provision.md](provision.md). The provisioner rejects an incomplete bundle before stage 1; the standalone CUDA wrapper also rejects a missing source even if an older binary exists in `build/`.

All cloned repos and compiled binaries are placed under `./build/` next to the script. Nothing is written to system directories except NCCL and apt packages.

If a previous run left `./build/` or one of the cloned repos owned by root or otherwise unwritable, the script now warns before clone / rebuild / helper-script write / `--clean` operations and tells you how to fix ownership. A common recovery command is:

```bash
sudo chown -R "$USER":"$(id -gn)" ./test/build
```

---

## Usage

```
./test/fulltest.sh [test...] [-test...] [--gpu <index[,index...]>] [--burn-duration <seconds>] [--node-stress-minutes <m>] [--clean] [--list] [--help]
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
./test/fulltest.sh code                             # CUDA int32 stress across all visible GPUs
./test/fulltest.sh -code                            # all default tests except code.cu
./test/fulltest.sh -memtest                         # all default tests except memtest
./test/fulltest.sh -code -memtest                   # exclude multiple tests in one run
./test/fulltest.sh nccl pytorch -code               # explicit tests without code.cu
./test/fulltest.sh memtest                         # VRAM integrity only
./test/fulltest.sh stress                          # stress test only (default 5 min)
./test/fulltest.sh node-stress                     # CPU + RAM + GPU stress (default 5 min)
./test/fulltest.sh pcie-errors memory-health fabric-health  # opt-in deep hardware diagnostics
```

### Combine: specific tests on specific GPUs
```bash
./test/fulltest.sh --gpu 3 memtest stress
./test/fulltest.sh --gpu 2,4,5 memtest stress
./test/fulltest.sh --gpu 0,1 preflight ecc pcie
./test/fulltest.sh --gpu 0,1 pcie-errors memory-health fabric-health
./test/fulltest.sh node-stress --node-stress-minutes 15
```

---

## Options

| Option | Default | Description |
|---|---|---|
| `--gpu <index[,index...]>` | all GPUs | Target one or more GPUs by index — single (`3`) or comma-separated (`2,4,5`). Indices are 0-based as shown by `nvidia-smi`. |
| `-<test>` / `--exclude <test>` | none | Exclude named tests from the run. Repeat the flag or prefix for multiple exclusions, such as `-code -memtest`. |
| `--burn-duration <seconds>` | `300` (5 min) | Duration of the sustained stress test. |
| `--node-stress-minutes <m>` | `5` | Duration of the node-wide CPU + RAM + GPU stress test. |
| `--clean` | — | Delete `./build/` and exit. Forces full rebuild on next run. Can be combined with tests to clean then immediately run. |
| `--list` | — | Print available test names and exit. |
| `--help` / `-h` | — | Show usage and exit. |

If `--clean` or a rebuild path fails because `./build/` is not writable, the script now prints the affected path, current owner / permissions when available, and a suggested `chown` command instead of failing later in the build.

If you are trying to decide whether a failure looks like software, hardware, power, thermal, or configuration drift, see [docs/test-triage.md](docs/test-triage.md) for a generic decision path.

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

# CPU + RAM + GPU stress for 15 minutes
./test/fulltest.sh node-stress --node-stress-minutes 15

# Post-load recovery check after stress
./test/fulltest.sh post-stress-recovery

# Optional policy check with persistence enforcement
GPU_POLICY_REQUIRE_PERSISTENCE=1 ./test/fulltest.sh gpu-policy

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

Default tests run in a fixed order when none are specified. `pcie-errors`,
`memory-health`, `fabric-health`, and `gpu-policy` are opt-in and run only when
named explicitly. `pcie-errors` is the final test in the default suite.

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

### `memory-health` — Persistent GPU Memory Health *(opt-in)*

Inspects the persistent memory-health surfaces exposed by the installed
driver and GPU:

- volatile and aggregate correctable/uncorrectable ECC state
- retired pages and pending page retirement
- Ampere-and-newer row-remapper counts, pending repairs, repair failures, and
  exhausted remap banks
- newer SRAM/DRAM ECC and channel/TPC repair state when exposed

Historical corrected errors and completed page retirement are retained as
remarks because those counters can legitimately remain nonzero after the
driver has isolated the affected memory. Uncorrectable ECC, pending repair,
row-remapping failure, unrepairable memory, or exhausted remap capacity fails
the test.

Consumer GPUs that expose none of these fields are reported as
`NOT BEING RUN`; they are not treated as clean data-centre GPUs.

```bash
./test/fulltest.sh memory-health
./test/fulltest.sh --gpu 2 memory-health
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

### `pcie-errors` — PCIe Error Delta

Captures each scoped GPU's cumulative PCIe replay counter and Linux PCIe AER
device counters, runs the CUDA `p2pBandwidthLatencyTest` (including
host-to-device traffic), and captures the counters again. Existing historical
counts do not fail; any increase during the measured traffic interval does.

The test also scans available kernel logs for fatal or uncorrectable PCIe/AER
events from the current boot and current test interval. Previous-boot events
are historical and do not fail a post-reseat validation run. If the host boots
with `pci=noaer`, AER sysfs counters are unavailable, or kernel logs are
inaccessible, that limitation is recorded while any available replay/AER
checks continue. If neither replay nor AER counters are available, the test
is reported as `NOT BEING RUN`; this is not counted as a pass.

```bash
./test/fulltest.sh pcie-errors
./test/fulltest.sh --gpu 0,3 pcie-errors
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

**Fails if:** Either binary builds and then exits non-zero at runtime.

**Reported as `NOT BEING RUN` instead of failures if:** The sample source layout changed, the build output is unavailable after attempting to build, or the sample binary cannot be found after prepare/build. The lookup now checks both the current `cpp/` tree and the legacy `Samples/` tree.

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

### `fabric-health` — NVLink / NVSwitch Health *(opt-in)*

Uses DCGM to inspect supported NVLink and NVSwitch port states, then compares
generation-appropriate fabric error counters before and after the CUDA P2P
traffic workload.

With `--gpu`, the traffic workload and per-GPU error counters are scoped to
the selected GPUs. DCGM's link-state inventory remains system-wide because
the command reports the shared GPU/NVSwitch fabric as one topology.

- supported ports reported `Down` fail
- supported ports reported `Disabled` produce a remark because some platform
  topologies disable ports intentionally
- unchanged cumulative counters are historical and do not fail
- newly increased CRC, replay, recovery, BER, discard, integrity, malformed,
  or overrun counters fail

Missing DCGM, no discovered NVLink/NVSwitch ports, or unavailable
generation-specific error counters are reported under `NOT BEING RUN`.

```bash
./test/fulltest.sh fabric-health
./test/fulltest.sh --gpu 0,1 fabric-health
```

---

### `pytorch` — Distributed Training Correctness

Installs PyTorch (wheel auto-selected by CUDA version) and runs a DistributedDataParallel training check via `torchrun`, with one process per selected GPU. This remains a default test.

Runs five FP32 SGD steps using a 128→64→16 network and batches of 32. Each rank has distinct deterministic inputs. Every step computes loss, runs backward, checks finite gradients, performs the optimiser update, and checks finite parameters. Gradients and parameters must agree with rank 0 (`rtol=1e-5`, `atol=1e-6`), and parameters must change from their initial values. The CUDA device is selected before NCCL initialisation; collective timeout is 120 seconds.

**Fails if:** runtime preparation or any training operation fails, gradients are missing/non-finite, parameters diverge between ranks, or no update occurs. On one GPU this validates local training; cross-GPU synchronisation requires at least two selected GPUs.

**Runtime contract:** The lane prefers the benchmark Python 3.11 runtime provisioned by `base-install.sh` (via `uv` or the installed `/opt/infra/python` tree). If `base-install.sh` has not run, `fulltest.sh` falls back to a supported system Python 3.10-3.12 and creates its own isolated `build/pytorch-venv`. Existing PyTorch venvs are rebuilt when their base interpreter does not match the selected runtime, so reruns do not keep stale Python or wheel families alive.

The shared runtime installs only `torch`, then verifies that the venv can import it, access at least one CUDA GPU, and provide its own `torchrun`. `torchvision`, `torchaudio`, and `accelerate` are not required by these tests and cannot block PCIe, clock, stress, or DDP validation when their CUDA-specific wheels are unavailable.

**Failure diagnostics:** On failure, the script now keeps the generated DDP repro script in `/tmp`, emits a condensed summary of the failing `local_rank` / child exit code, and prints a direct `torchrun` repro command plus a suggested debug rerun with `NCCL_DEBUG=INFO` and `TORCH_DISTRIBUTED_DEBUG=DETAIL`.

**Python runtime warning:** The script logs the active system `python3` runtime plus the PyTorch runtime it will actually use. If no supported Python runtime is available, PyTorch is skipped with an explicit `NOT BEING RUN` reason.

**PyTorch wheel selection:**

| CUDA Version | Wheel |
|---|---|
| 11.x | `cu118` |
| 12.0–12.1 | `cu121` |
| 12.2–12.4 | `cu124` |
| 12.5–12.9 | `cu128` |
| 13.0–13.1 | `cu130` |
| 13.2–13.3 | `cu132` |

**Notes:** On Ubuntu 24.04+, `--break-system-packages` is added to pip installs automatically (PEP 668 compliance).

---

### `numerics` — Numerical Correctness

Default test using the same managed PyTorch environment. For each selected GPU, compare 128×128 matrix products in FP32, FP16, and native BF16 against CPU float64 results computed from identical dtype-quantised inputs. Patterns cover seeded random inputs, identity, cancellation, and reciprocal input scaling. TF32 and reduced-precision reductions are disabled for this check.

Each element must satisfy `abs(actual-reference) <= atol + rtol*abs(reference)`. Both tolerances are `2e-5` for FP32, `2e-3` for FP16, and `2e-2` for BF16. Logs show GPU, precision, pattern, maximum absolute error, normalised error, and tolerance. Non-finite values or disagreement fail; unsupported native BF16 skips only that precision. An unavailable supported Python runtime follows the existing `NOT BEING RUN` convention. These are correctness thresholds, not performance targets; real GPU validation is required across the supported fleet.

```bash
./test/fulltest.sh --gpu 0,1 pytorch numerics
./test/fulltest.sh -numerics                  # omit numerical checks from default run
```

### `nccl-extended` — Additional Collectives (Opt-in)

Run all-gather and reduce-scatter from the existing NCCL tests build, with correctness checking enabled (`-c 1`). Each uses 8-byte to 64-MiB messages, doubling sizes, ten measured iterations and two warmups, plus a 180-second process watchdog with ten seconds of termination grace. The existing single-node PCIe transport settings are reused. A failed collective, build failure, or timeout fails the test; fewer than two selected GPUs is reported as `NOT BEING RUN`.

```bash
./test/fulltest.sh --gpu 0,1 nccl-extended
```

The [upstream NCCL tests documentation](https://github.com/NVIDIA/nccl-tests) describes correctness checking and shared collective options. This test requires GNU `timeout` from coreutils on the target Ubuntu host.

### `load-cycles` — Idle-to-Load Transitions (Opt-in)

Alternates idle intervals and FP32 1024×1024 GEMM bursts on all selected GPUs. Each burst launches work on every GPU before synchronising, then checks finite output. The selected GPU UUID inventory must remain unchanged before/after the stages. New Xid, fallen-off-bus, and fatal PCIe messages attributed to a selected GPU's UUID or PCI address fail within the bounded kernel-log window. Non-Fatal PCIe messages do not trigger the fatal classifier, and events attributed to unselected devices do not fail the selected run. Unattributed events and unavailable journal access are recorded as remarks for inspection.

| Environment variable | Default | Accepted values |
|---|---|---|
| `GPU_LOAD_CYCLES` | `5` | Integers 1–100 |
| `GPU_LOAD_IDLE_SECONDS` | `5` | Integers 1–300 |
| `GPU_LOAD_SECONDS` | `10` | Integers 1–300 |

Default workload time is approximately 75 seconds plus inspection overhead. GNU `timeout` bounds execution to `cycles × (idle + load) + 120` seconds, with ten seconds of termination grace; runtime installation/preparation occurs before that watchdog. Individual driver and journal calls have ten/fifteen-second timeouts. No GPU reset, clock changes, or power-limit changes are performed. This exercises transitions but does not guarantee any particular power state or replace long burn-in.

```bash
./test/fulltest.sh --gpu 0,1 load-cycles
GPU_LOAD_CYCLES=10 GPU_LOAD_IDLE_SECONDS=10 GPU_LOAD_SECONDS=20 \
    ./test/fulltest.sh --gpu 0,1 load-cycles
```

### Regression checks for training and extended GPU tests

```bash
bash test/fulltest-training-test.sh
bash test/fulltest-numerics-test.sh
bash test/fulltest-load-cycles-test.sh
bash test/fulltest-extended-test.sh
```

The suites check the generated Python, numerical validator, CLI inclusion/exclusion, runtime routing, failure propagation, mocked inventories and collective arguments. Where local PyTorch is installed, the training regression also executes two CPU/Gloo ranks and injects missing backward/update operations, non-finite loss and rank divergence. Without PyTorch it explicitly skips those cases. Passing these development checks does not establish correctness on physical CUDA GPUs; validate one GPU and a multi-GPU subset before fleet rollout.

### `code` — CUDA Int32 Compute Stress

Runs the tiny `test/code.sh` wrapper, which compiles `test/code.cu` with `nvcc` if needed and then executes it on each visible GPU in turn.

The wrapper now targets the visible GPUs' compute capabilities directly with SASS-only `-gencode` flags when possible, so the test avoids PTX JIT compatibility problems on newer toolkits/drivers.

The suite invokes it sequentially across all GPUs in scope using logical device IDs `0..N-1`, so it respects `--gpu` remapping via `CUDA_VISIBLE_DEVICES`.

The per-GPU runtime is controlled by `CUDA_CODE_SECONDS` and defaults to `15` seconds inside the suite. The standalone wrapper defaults to `30` seconds when run directly.

**Fails if:** the wrapper is missing, `nvcc` is unavailable, the CUDA build fails, or the kernel exits non-zero on any visible GPU.

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

### 12V-2x6 / 12VHPWR Early-Warning Methodology

`stress` and `node-stress` also watch for a *power-balance* pattern that can
precede a 12V-2x6 / 12VHPWR cable or connector failure. This is a heuristic
signal, not a direct electrical measurement, so the script treats it as an
early warning rather than proof of damage.

How the detector works:

1. The burn monitor samples each GPU every 5 seconds and records temperature,
   power draw, fan percentage, and SM clock.
2. The first 30 seconds of the burn are ignored to skip startup ramp and fan
   spin-up.
3. For each timestamp, the script computes the median power draw across all
   GPUs in scope.
4. A GPU sample is considered anomalous if:
   - its power draw is at least `max(25 W, 6% of the peer median)` below the peer median, and
   - its fan is at or above 85%.
5. If a GPU meets that condition in at least 50% of the post-warmup samples,
   it is flagged as a potential connector issue.

Why this helps:

- A weak 12V-2x6 / 12VHPWR connection can make one GPU self-limit under load
  even when the driver does not report a hard throttle reason.
- That often shows up as a GPU that stays cooler, draws less power, and runs
  its fan harder than peers at the same time.
- Because the driver may not expose this as a normal throttle state, the burn
  test checks the raw telemetry directly instead of relying only on
  `nvidia-smi` throttle flags.

The detector requires at least 3 GPUs in scope so it has a meaningful peer
median to compare against. When it triggers, `fulltest.sh` records the result
as a remark by default (`POWER_ANOMALY_AS_REMARK=1`) and includes the flagged
GPU index list in the remark text; set `POWER_ANOMALY_AS_REMARK=0` if you want
the same condition to fail the test.

If no usable fan telemetry is available, the detector skips cleanly rather than
guessing from power alone. That is intentional for chassis-managed cooling
platforms where on-card fan speed is not exposed.

### Future improvement plans

The current detector is intentionally conservative. Future follow-up work may
add:

- a replay mode so archived burn telemetry can be re-analysed without rerunning
  the stress test
- late-onset anomaly detection for GPUs that look normal early in the run but
  drift into a connector-fault pattern after heat soak
- a policy review for whether the detector should remain remark-only by
  default once more fleet data exists across different GPU families

These are planned improvements only; they are not part of the current stable
behavior.

**Fails if:**
- The burn tool exits non-zero for a real compute error or GPU crash

**Reported as remarks instead of failures if:**
- Any GPU in scope exceeds the thermal warning threshold during the run (`TEMP_WARN` / `FAN_WARN`)
- The burn tool emits a performance-health warning but thermals remain clean
- The burn tool exits only because a GPU reports `SW_Thermal` / soft thermal throttling, with no hard-crash indicators
- A 12V-2x6 / 12VHPWR connector early-warning pattern is detected; see the methodology above (remark-only by default)

In other words: thermal or fan-limit findings are recorded as remarks, while the test only fails on an actual GPU crash or other hard failure signal.

When either of those warning-only cases happens, the final summary adds a `REMARKS` section rather than marking the test as failed. If a backend cannot be built and the script falls back to another engine, the summary also adds a `NOT BEING RUN` entry for the unavailable backend.

### `node-stress` — Node-Wide Stress

Runs the existing GPU stress backend at the same time as `stress-ng` CPU and RAM pressure so you can approximate maximum whole-node power and thermal load.

**Workloads:**

| Component | Method | Notes |
|---|---|---|
| CPU | `stress-ng --cpu 0` | All available CPU cores |
| RAM | `stress-ng --vm 2 --vm-bytes ... --vm-keep` | Sustained memory allocation + touching |
| GPU | Same backend used by `stress` | `gpu-fryer` → `gpu-burn` → PyTorch fallback |

`stress-ng` picks a memory target dynamically from total system RAM so the default profile is heavy without immediately turning into an OOM test. The node-stress mode also prints `sensors` snapshots when `lm-sensors` is available.

The same 12V-2x6 / 12VHPWR power-balance detector used by `stress` is applied
here as well, because the GPU backend is shared and the extra CPU/RAM pressure
can make marginal power delivery issues easier to reproduce.

**Fails if:**
- The GPU backend exits non-zero for a real compute error or GPU crash
- `stress-ng` exits non-zero

**Reported as remarks instead of failures if:**
- Any GPU exceeds the thermal warning threshold tracked by the GPU burn monitor
- The GPU backend emits a performance-health warning but thermals remain clean
- The GPU backend exits only because of `SW_Thermal` / soft thermal throttling, with no hard-crash indicators
- A 12V-2x6 / 12VHPWR connector early-warning pattern is detected; see the methodology above (remark-only by default)

In other words: thermal or fan-limit findings are recorded as remarks, while the test only fails on an actual GPU crash or other hard failure signal.

If `stress-ng`, `gpu-fryer`, or `gpu-burn` is unavailable, the summary records that component as `NOT BEING RUN` rather than treating the whole run as a failure.

---

### `post-stress-recovery` — Post-Stress Recovery

Runs after stress workloads to confirm the node has recovered cleanly instead of only surviving under load.

**Checks:**
- `nvidia-smi` still enumerates the same GPU count in scope
- kernel logs since the stress window do not contain new GPU faults, Xid events, bus drops, or driver resets
- each GPU has moved back into a normal recovery state after the cool-down delay

**Fails if:**
- GPU enumeration changes or `nvidia-smi` cannot query the GPUs
- new kernel log GPU faults appear during the recovery window
- a hard throttle condition remains active after the cool-down window

**Reported as remarks instead of failures if:**
- GPUs are still warm / fans are still high while cooling down
- only soft thermal throttling remains after the burn
- kernel log recovery scanning is unavailable on the host

The recovery delay is configurable via `POST_STRESS_RECOVERY_COOLDOWN_SECONDS` (default: 20).

---

### `gpu-policy` — GPU Policy Check

Optional policy test for fleet-specific expectations such as persistence mode, idle temperature ceilings, and power limit bounds.

This test is **selectable**, and it is advisory by default. Set `GPU_POLICY_STRICT=1` to make policy violations fail the test.

**Policy inputs:**

| Env var | Meaning |
|---|---|
| `GPU_POLICY_REQUIRE_PERSISTENCE=1` | Require persistence mode to be enabled |
| `GPU_POLICY_MAX_IDLE_TEMP=<°C>` | Fail/remark if idle temperature exceeds this ceiling |
| `GPU_POLICY_MIN_POWER_LIMIT_W=<W>` | Require a minimum power limit |
| `GPU_POLICY_MAX_POWER_LIMIT_W=<W>` | Require a maximum power limit |
| `GPU_POLICY_STRICT=1` | Treat policy violations as failures instead of remarks |

If no `GPU_POLICY_*` thresholds are set, the script records the test as `NOT BEING RUN`.

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
| `NODE_STRESS_MINUTES` | `5` | Default node-wide stress duration in minutes (overridden by `--node-stress-minutes`) |
| `TEMP_WARN` | `87` | Temperature threshold in °C for burn test thermal flag |
| `FAN_WARN` | `100` | Fan speed threshold in % for burn test thermal flag |
| `POWER_ANOMALY_DELTA_W` | `25` | Power delta below peer median required to flag a sample |
| `POWER_ANOMALY_FAN_PCT` | `85` | Fan speed threshold used by the connector anomaly detector |
| `POWER_ANOMALY_FRAC_PCT` | `50` | Percentage of post-warmup samples that must be anomalous |
| `POWER_ANOMALY_WARMUP_S` | `30` | Initial burn seconds ignored before anomaly counting starts |
| `POWER_ANOMALY_AS_REMARK` | `1` | Default behavior for power anomalies (`1` = remark only, `0` = fail) |

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
