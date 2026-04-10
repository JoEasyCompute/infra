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

`gpu-fulltest-v2.sh` covers the same test names as `fulltest.sh`:

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

Preparation is only done for tests the operator selected.

---

## Usage

```bash
./test/gpu-fulltest-v2.sh [test...] [--gpu <index[,index...]>] [--burn-duration <seconds>] [--clean] [--list] [--help]
```

Examples:

```bash
./test/gpu-fulltest-v2.sh
./test/gpu-fulltest-v2.sh --gpu 3
./test/gpu-fulltest-v2.sh --gpu 2,4,5 memtest stress
./test/gpu-fulltest-v2.sh nccl pytorch
./test/gpu-fulltest-v2.sh --clean
```

---

## Notes

- This script is intentionally **experimental**.
- It should be validated on real GPU hosts before being treated as a replacement for `fulltest.sh`.
- Build / permission handling inherited from the current fulltest improvements is still active here, so stale root-owned build trees should warn before rebuilds.
- The PyTorch benchmark now keeps its generated DDP repro script on failure and prints a condensed failure summary plus a suggested debug rerun command.
- The PyTorch prepare/run path now logs the active `python3` runtime and warns when Python 3.12+ is in use because `torch.distributed` / `torchrun` segfaults have been seen there.

---

## Operator Guidance

Use `gpu-fulltest-v2.sh` when you want to evaluate the prepare-then-run flow.

Use `fulltest.sh` when you want the current stable behavior.
