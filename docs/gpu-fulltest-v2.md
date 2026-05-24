# gpu-fulltest-v2.sh — Experimental GPU Test Suite

Experimental prepare-then-run variant of `test/fulltest.sh` for NVIDIA GPU validation on Ubuntu 22.04 / 24.04.

This script exists to test a cleaner control flow without replacing the current stable path:

- `test/fulltest.sh` — stable / current production path
- `test/gpu-fulltest-v2.sh` — experimental refactor candidate

---

## Goal

Keep roughly the same GPU validation coverage as `fulltest.sh`, but change the execution model to:

1. detect the system
2. prepare only the selected tests
3. run the selected tests
4. print a summary that distinguishes prepare failures from test failures

This means build-heavy failures should happen earlier, before long test execution begins.

---

## Current Scope

`gpu-fulltest-v2.sh` covers the same core test names as `fulltest.sh`, plus an experimental node-wide stress mode:

- `preflight`
- `ecc`
- `pcie`
- `clocks`
- `nccl`
- `cuda-samples`
- `nvbandwidth`
- `dcgm`
- `pytorch`
- `memtest`
- `stress`
- `node-stress`
- `post-stress-recovery`
- `gpu-policy`

The main architectural difference is that selected build/runtime dependencies are prepared up front.

---

## Prepare Phase

The script currently has explicit prepare steps for selected tests such as:

- NCCL libraries and `nccl-tests`
- CUDA sample binaries
- `nvbandwidth`
- PyTorch runtime
- `cuda_memtest`
- stress backends (`gpu-fryer`, `gpu-burn`, or PyTorch fallback)
- node-stress, which combines `stress-ng` CPU + RAM load with the GPU burn backend
- post-stress recovery, which verifies the GPUs and driver state settle cleanly after stress
- optional GPU policy checks for persistence / idle temp / power-limit expectations

Preparation is only done for tests the operator selected.

---

## Usage

```bash
./test/gpu-fulltest-v2.sh [test...] [--gpu <index[,index...]>] [--burn-duration <seconds>] [--node-stress-minutes <m>] [--clean] [--list] [--help]
```

Examples:

```bash
./test/gpu-fulltest-v2.sh
./test/gpu-fulltest-v2.sh --gpu 3
./test/gpu-fulltest-v2.sh --gpu 2,4,5 memtest stress
./test/gpu-fulltest-v2.sh node-stress
./test/gpu-fulltest-v2.sh node-stress --node-stress-minutes 15
./test/gpu-fulltest-v2.sh nccl pytorch
./test/gpu-fulltest-v2.sh post-stress-recovery
GPU_POLICY_REQUIRE_PERSISTENCE=1 ./test/gpu-fulltest-v2.sh gpu-policy
./test/gpu-fulltest-v2.sh --clean
```

---

## Notes

- This script is intentionally **experimental**.
- It should be validated on real GPU hosts before being treated as a replacement for `fulltest.sh`.
- Build / permission handling inherited from the current fulltest improvements is still active here, so stale root-owned build trees should warn before rebuilds.
- The PyTorch benchmark now keeps its generated DDP repro script on failure and prints a condensed failure summary plus a suggested debug rerun command.
- The PyTorch prepare/run path now logs the active `python3` runtime and warns when Python 3.12+ is in use because `torch.distributed` / `torchrun` segfaults have been seen there.
- Sustained stress and node-stress now treat thermal/performance-only outcomes as summary remarks, and unavailable backends are listed under `NOT BEING RUN` instead of failing the overall run.
- `SW_Thermal`-only exits are treated as remarks in the stress summary, provided there are no hard-crash indicators.
- `stress` and `node-stress` also detect sustained 12V-2x6 / 12VHPWR connector power anomalies; these are remark-only by default unless `POWER_ANOMALY_AS_REMARK=0` is set.
- `post-stress-recovery` adds an extra post-load driver / GPU sanity check after the stress tests and records thermal residue as remarks.
- `gpu-policy` is an optional advisory test by default; set `GPU_POLICY_STRICT=1` and the `GPU_POLICY_*` thresholds to enforce fleet policy.
- CUDA samples source-layout/build mismatches are recorded as `NOT BEING RUN` instead of failing the run. The lookup checks both the current `cpp/` tree and the legacy `Samples/` tree.

### 12V-2x6 / 12VHPWR Early-Warning Methodology

The sustained power-anomaly detector used by `stress` and `node-stress` is the
same one documented in `docs/fulltest.md`.

In short:

- it samples GPU temperature, power, fan, and SM clock every 5 seconds during
  the burn;
- it ignores the first 30 seconds so ramp-up noise does not trip the detector;
- it compares each GPU against the peer median power at the same timestamp;
- it flags a sample when power is at least 25 W below the peer median and fan
  is at least 85%;
- it marks a GPU when that pattern appears in at least 50% of post-warmup
  samples; and
- it requires 3 or more GPUs in scope so the peer median is meaningful.

This is a heuristic warning for a likely connector or cable contact-resistance
problem, not a direct electrical proof. By default, the experimental lane
records it as a remark via `POWER_ANOMALY_AS_REMARK=1`; set
`POWER_ANOMALY_AS_REMARK=0` if you want the same condition to fail the run.

---

## Operator Guidance

Use `gpu-fulltest-v2.sh` when you want to evaluate the prepare-then-run flow.

Use `fulltest.sh` when you want the current stable behavior.
