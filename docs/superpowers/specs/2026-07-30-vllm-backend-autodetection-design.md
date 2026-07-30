# vLLM Backend Autodetection Design

## Goal

Make `--backend auto` the default for `test/vllm-benchmark-test.sh` so a
provisioned host automatically selects the NVIDIA or AMD execution path while
retaining explicit backend overrides.

## CLI Contract

Supported values are:

- `--backend auto`: default; detect exactly one usable GPU backend
- `--backend nvidia`: force NVIDIA command construction
- `--backend amd`: force AMD command construction

Profiles remain backend-independent. Autodetection changes only the selected
container image, device/runtime arguments, inventory path, and prerequisite
checks.

## Detection

NVIDIA is considered usable when `nvidia-smi` exists and its index query
reports at least one GPU.

AMD is considered usable when:

- `rocminfo` exists and reports at least one `gfx*` GPU agent
- `/dev/kfd` exists
- `/dev/dri` exists

The device root remains replaceable through `VLLM_BENCHMARK_DEVICE_ROOT` for
the hardware-free regression harness.

Detection outcomes:

- NVIDIA only: resolve to `nvidia`
- AMD only: resolve to `amd`
- both: fail and require explicit `--backend nvidia` or `--backend amd`
- neither: fail with an actionable provisioning/runtime message

The resolved backend is recorded in dry-run output, logs, metadata, and
summary artifacts. No separate `requested_backend` field is needed because
the effective backend controls reproducibility.

## Dry-Run Behavior

Default `--backend auto --dry-run` performs read-only hardware detection but
still skips Docker checks, downloads, and filesystem changes. This means a
non-GPU development host must use an explicit backend to inspect a command:

```bash
./test/vllm-benchmark-test.sh --backend nvidia --dry-run
./test/vllm-benchmark-test.sh --backend amd --dry-run
```

Explicit backend dry-runs do not require the corresponding hardware or vendor
tools.

## Tests

The static harness will verify:

- help reports `auto` as the default
- mocked NVIDIA-only detection resolves to NVIDIA
- mocked AMD-only detection resolves to AMD
- mixed detection fails with an explicit-backend instruction
- no detected backend fails before Docker or artifact creation
- explicit NVIDIA and AMD dry-runs remain hardware-free
- practical and published profiles remain unchanged after backend resolution
- existing mocked NVIDIA and AMD lifecycle tests continue to pass

## Documentation

README, the detailed benchmark guide, project decisions, and project memory
will describe automatic selection, explicit overrides, mixed-host behavior,
and the non-GPU dry-run requirement.
