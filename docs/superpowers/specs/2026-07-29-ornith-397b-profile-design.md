# Ornith 397B Published Profile Design

## Goal

Add an explicit vLLM benchmark profile that reproduces the publicly disclosed
Ornith-1.0-397B Terminal-Bench 2.1 settings while preserving the current
35B/16K configuration as the practical default.

## CLI Contract

The benchmark accepts:

```bash
./test/vllm-benchmark-test.sh \
    --profile ornith-397b-published \
    --gpus 0,1,2,3,4,5,6,7 \
    --tp-size 8
```

Supported profiles:

- `ornith-35b-practical`: current default behavior
- `ornith-397b-published`: published-settings reproduction profile

`--profile` is independent of `--backend`; the selected NVIDIA or AMD backend
continues to control container image and GPU runtime configuration.

## Published Profile Values

The 397B profile sets:

- model: `deepreinforce-ai/Ornith-1.0-397B`
- model revision: `5e3e761811e804c295c1d3c0ce68b21da6154209`
- dataset: `terminal-bench/terminal-bench-2-1@6`
- agent: `terminus-2`
- vLLM maximum model length: `131072`
- tool parser: `qwen3_xml`
- reasoning parser: `qwen3`
- Harbor parser: `json`
- Harbor temperature: `1.0`
- Harbor top-p: `1.0`
- Harbor task environment override: 32 CPUs and 49,152 MB RAM

The profile performs one attempt per task per invocation. The published score
was averaged over five runs. Operators can request five attempts explicitly
by forwarding `--n-attempts 5` to Harbor after the wrapper's `--` separator.

## Override Rules

Profile values are defaults, not a separate execution engine. Explicit CLI
options override profile values regardless of argument order. Overriding any
profile-controlled value marks the run as modified in metadata and emits a
warning that the result is not directly comparable with the published profile.

The profile does not select GPUs or tensor parallelism automatically. Hardware
topology remains operator-controlled through `--gpus` and `--tp-size`.

## Capacity And Safety

The script prints a prominent capacity warning before downloads. The 397B BF16
checkpoint contains approximately 397 billion parameters and requires far more
memory than the practical 35B profile. The wrapper does not guess a minimum GPU
count because usable capacity depends on the backend, image, tensor-parallel
topology, and any operator-selected quantized model or image.

Existing lifecycle protections remain unchanged:

- localhost-only API binding
- named backend-specific container
- bounded startup wait
- exact smoke response validation
- secret values excluded from logs and metadata
- cleanup limited to the named benchmark container

## Metadata

`metadata.json` and `summary.txt` record:

- selected profile
- whether profile-controlled values were modified
- effective model and immutable revision
- effective dataset snapshot
- effective context, parser, sampling, CPU, and memory settings
- the full effective Harbor command

This lets operators distinguish the practical profile, the unmodified
published profile, and custom derivatives.

## Reproducibility Boundary

The public model card discloses Terminal-Bench 2.1, Terminus-2, JSON parsing,
temperature/top-p 1.0, a 128K context, four-hour task runs, 32 CPUs, 48 GB RAM,
and five-run averaging. It also states that Harbor was modified to align with
vLLM's `reasoning_content`, but it does not publish the exact Harbor commit,
patch, or dataset registry snapshot used for the reported score.

This repository therefore pins Harbor `0.20.0`, the current immutable model
revision, and Terminal-Bench 2.1 registry snapshot `@6`. The profile reproduces
the published settings that are available. Harbor `0.20.0` natively preserves
`reasoning_content`, so no local Harbor patch is required.

Harbor's ad hoc CLI exposes timeout multipliers rather than an absolute
per-task timeout. Snapshot `@6` contains task-specific agent timeouts ranging
from minutes to hours, and the original four-hour override was not published.
The profile keeps the pinned dataset timeouts instead of guessing a multiplier.
For this reason, and because the original Harbor patch and dataset snapshot
remain undisclosed, the profile must not claim bit-for-bit equivalence with the
reported score.

## Tests

The hardware-free regression harness verifies:

- help output lists both profiles
- the practical profile preserves all existing defaults
- the 397B profile selects the pinned model revision and dataset snapshot
- the 397B profile emits 128K, JSON, temperature/top-p, CPU, and memory settings
- explicit overrides win regardless of argument order and mark the profile
  modified
- unknown profiles fail before host checks
- NVIDIA and AMD command construction remains unchanged
- dry-run creates no artifacts and exposes no token value

Real NVIDIA and AMD hosts remain required to validate model loading, memory
capacity, distributed execution, and end-to-end Terminal-Bench scoring.
