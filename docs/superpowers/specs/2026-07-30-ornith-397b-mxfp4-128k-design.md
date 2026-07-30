# Ornith 397B MXFP4 128K Profile Design

## Goal

Add an experimental NVIDIA-only benchmark profile that attempts to run
Ornith-1.0-397B with a 128K maximum context on eight 32 GB GPUs by combining a
community MXFP4 checkpoint with vLLM context parallelism and a quantized KV
cache.

The profile is a capacity-oriented derivative of `ornith-397b-published`. It
does not reproduce the publisher's BF16 checkpoint and must not be compared
directly with the published Terminal-Bench score.

## Scope

The implementation will:

- add `ornith-397b-mxfp4-128k` as a third profile
- preserve `ornith-35b-practical` as the default
- leave `ornith-397b-published` unchanged
- add the vLLM controls needed to express and override the memory strategy
- reject unsupported backends and incompatible GPU topologies before downloads
- record every effective memory and parallelism setting in run artifacts
- update the benchmark guide, README, project decisions, and project memory

The implementation will not:

- publish or mirror model weights
- silently enable CPU offload
- claim that the checkpoint is publisher-official
- claim that startup is guaranteed on eight RTX 5090 GPUs
- change `fulltest.sh` or include this benchmark in unattended validation

## CLI Contract

The intended unmodified invocation is:

```bash
./test/vllm-benchmark-test.sh \
    --profile ornith-397b-mxfp4-128k \
    --backend nvidia \
    --gpus 0,1,2,3,4,5,6,7 \
    --tp-size 8
```

`--backend auto` remains the global default and may resolve to NVIDIA on a
normal NVIDIA-only host. The explicit backend in the example also makes
hardware-free `--dry-run` usable.

The wrapper will add these general vLLM options:

- `--decode-context-parallel-size COUNT`
- `--kv-cache-dtype TYPE`
- `--calculate-kv-scales` and `--no-calculate-kv-scales`
- `--max-num-seqs COUNT`
- `--cpu-offload-gb GB`
- `--enforce-eager` and `--no-enforce-eager`
- `--language-model-only` and `--no-language-model-only`

Boolean pairs select whether the corresponding positive vLLM flag is emitted;
the wrapper does not pass invented negative flags through to vLLM. Existing
profiles retain their current effective commands, including the existing AMD
eager-mode behavior.

## Profile Defaults

`ornith-397b-mxfp4-128k` sets:

- model: `olka-fi/Ornith-1.0-397B-MXFP4`
- model revision: `04940815e4ddf15e2b7cc4710e81e3cecc25540b`
- served model name: `Ornith-1.0-397B-MXFP4`
- dataset: `terminal-bench/terminal-bench-2-1@6`
- agent: `terminus-2`
- vLLM image: the pinned NVIDIA default,
  `vllm/vllm-openai:v0.25.1-cu129`
- maximum model length: `131072`
- tensor parallel size: `8`
- decode context parallel size: `4`
- KV cache dtype: `fp8`
- calculate KV scales: enabled
- GPU memory utilization: `0.95`
- maximum concurrent vLLM sequences: `1`
- eager execution: enabled
- language-model-only serving: enabled
- CPU offload: `0` GB per GPU
- tool parser: `qwen3_xml`
- reasoning parser: `qwen3`
- Harbor parser: `json`
- Harbor temperature: `1.0`
- Harbor top-p: `1.0`
- Harbor concurrency: `1`
- Harbor task CPUs: `32`
- Harbor task memory: `49152` MB
- minimum Docker-root free space: `300` GB

Values that map to disabled or zero behavior are omitted from the vLLM command
instead of being passed as redundant arguments.

## Memory Strategy

The pinned checkpoint contains approximately 225.94 GB of repository payload,
or 210.42 GiB, before vLLM runtime allocations. Eight nominal 32 GB GPUs
provide only a narrow remaining margin for non-quantized weights, CUDA
workspace, communication buffers, and KV cache.

The profile reduces that pressure as follows:

- MXFP4 compresses the routed expert weights while retaining other weights at
  higher precision.
- TP8 distributes model weights over all eight GPUs.
- DCP4 shards the decode KV cache over groups of four existing TP ranks. This
  avoids the four-way KV duplication that TP8 would otherwise create for a
  model with two KV heads.
- FP8 KV cache approximately halves KV storage relative to BF16.
- Calculated KV scales avoid relying on fixed scale `1.0`.
- One vLLM sequence and one Harbor task prevent concurrent requests from
  multiplying KV demand.
- Eager execution avoids CUDA graph memory reservations.
- Language-model-only mode excludes unused multimodal processing.

These settings make an eight-GPU attempt plausible, not guaranteed. Actual
capacity depends on the checkpoint implementation, vLLM kernels, driver,
allocator fragmentation, and GPU-reported usable memory. A real eight-GPU
startup and smoke test is the acceptance boundary for hardware compatibility.

## Backend And Topology Validation

The profile is supported only when the resolved backend is `nvidia`. An
explicit AMD selection, or `auto` resolving to AMD, fails before Docker image
or model downloads with an instruction to use a supported NVIDIA host. The
existing AMD profiles and commands remain unchanged.

An unmodified run requires exactly eight selected GPUs and TP8. The wrapper
will validate the effective topology after GPU selection:

- selected GPU count must be at least `8`
- tensor parallel size must equal the selected GPU count so every visible GPU
  contributes memory
- decode context parallel size must be a positive divisor of tensor parallel
  size
- the selected GPUs must expose at least approximately 250 GiB of aggregate
  reported VRAM

The aggregate-memory check is a hardware-run preflight, not a dry-run
requirement. Insufficient reported VRAM is a hard failure before downloads.
Passing the check is not a promise that vLLM will fit.

Operators may override TP size, DCP size, or other profile settings for
larger NVIDIA hardware topologies. A topology override must still satisfy
`TP_SIZE == selected GPU count` and `TP_SIZE % DCP_SIZE == 0`; valid deviations
mark the profile modified. Selecting fewer than eight GPUs remains a hard
failure because it cannot meet this profile's capacity target.

## Override Rules

Profile values are defaults applied before normal argument parsing, so
explicit options win regardless of argument order. Any deviation from a
profile-controlled value marks `profile_modified=true`, including:

- model, revision, dataset, image, or maximum context
- selected GPU count, TP size, or DCP size
- KV cache dtype or scale calculation
- GPU memory utilization or maximum sequence count
- eager mode, language-model-only mode, or CPU offload
- parsers, sampling values, Harbor concurrency, or task resources
- minimum Docker free-space threshold

When modified, the wrapper warns that the run is not the tested profile and
must not be treated as directly comparable. It still rejects internally
invalid combinations.

For an out-of-memory startup, documentation may suggest
`--cpu-offload-gb 2` as an explicit fallback. CPU offload is intentionally not
the default because it changes latency, host-memory demand, and benchmark
comparability.

## Command Construction

For the unmodified profile, the vLLM command adds:

```text
--tensor-parallel-size 8
--decode-context-parallel-size 4
--max-model-len 131072
--gpu-memory-utilization 0.95
--kv-cache-dtype fp8
--calculate-kv-scales
--max-num-seqs 1
--enforce-eager
--language-model-only
```

It does not add `--cpu-offload-gb` when the effective value is zero.

The Harbor command uses `--n-concurrent 1` and retains the pinned Terminal-
Bench 2.1 dataset, Terminus-2 agent, JSON parser, sampling values, and task
resources from the published-settings profile.

## Failure Handling

Validation errors must be actionable and occur before side effects whenever
the required information is already available. In particular:

- unsupported profile names fail before backend or Docker checks
- AMD use fails before downloads
- invalid numeric values and TP/DCP combinations fail before Docker checks
- a hardware run with the wrong GPU count or insufficient aggregate VRAM fails
  before image or model downloads
- less than 300 GB free under the Docker root fails before artifact creation
- normal startup timeout, server-log capture, named-container cleanup, and
  localhost-only API binding remain unchanged

Dry-run remains side-effect free. An explicit NVIDIA dry-run validates the
declared GPU count and command shape but cannot prove memory capacity.

## Metadata And Summary

`metadata.json`, `summary.txt`, and dry-run output will include:

- selected profile and `profile_modified`
- model, immutable revision, image, dataset, and selected GPUs
- TP and DCP sizes
- maximum context and GPU memory utilization
- KV cache dtype and whether scale calculation is enabled
- maximum vLLM sequences
- eager-mode and language-model-only state
- CPU offload per GPU
- Harbor concurrency and task resources
- Docker free-space threshold

The full effective vLLM and Harbor commands remain visible without exposing
`HF_TOKEN`.

## Documentation

The README and detailed benchmark guide will:

- list the third profile without changing the default
- show the explicit eight-GPU invocation
- label the checkpoint community-published and the profile experimental
- explain that MXFP4 results are not directly comparable with BF16 results
- state the approximate 226 GB download and 300 GB Docker-space preflight
- explain the TP8/DCP4, FP8 KV, and single-sequence memory strategy
- document the optional 2 GB-per-GPU CPU-offload fallback
- retain the requirement to run base installation and Docker installation
  first

Project decisions and project memory will record the same operational
boundary.

## Tests

The hardware-free regression harness will verify:

- help lists all three profiles and the new vLLM controls
- existing practical and published profile dry-run commands are unchanged
- the MXFP4 profile selects the pinned model revision, image, and dataset
- its dry-run emits 128K, TP8/DCP4, FP8 KV, calculated scales, one sequence,
  eager mode, language-model-only mode, and 0.95 memory utilization
- its Harbor command emits concurrency one and the pinned task resources
- its effective minimum free-space requirement is 300 GB
- the profile rejects AMD before any Docker command
- the profile rejects fewer than eight selected GPUs or a TP size that leaves
  selected GPUs unused
- DCP values that do not divide TP fail
- valid explicit overrides are order-independent and mark the profile modified
- zero CPU offload emits no vLLM option and a non-zero override does
- boolean enable/disable overrides produce the expected command
- dry-run creates no artifacts and does not expose the token value
- mocked hardware lifecycle tests preserve cleanup and metadata behavior

An NVIDIA hardware acceptance run must additionally verify:

- all eight selected GPUs are visible inside the pinned container
- the immutable checkpoint downloads and loads
- vLLM exposes the expected served model
- the exact chat-completion smoke response passes
- the server log contains no out-of-memory or unsupported-kernel failure
- a bounded Terminal-Bench task can start with Harbor concurrency one

The profile remains experimental until that hardware acceptance run succeeds
on an eight-RTX-5090 host.

## Reproducibility Boundary

The checkpoint is a community conversion, not a DeepReinforce release. Its
pinned model card reports `compressed-tensors` MXFP4 quantization and vLLM
testing on different Blackwell hardware, but it does not establish eight-RTX-
5090 compatibility or score equivalence with the publisher's BF16 model.

The design follows vLLM's documented context-parallel deployment model and
serve options. Exact behavior remains dependent on the pinned image and model
revision:

- [pinned MXFP4 model card](https://huggingface.co/olka-fi/Ornith-1.0-397B-MXFP4/blob/04940815e4ddf15e2b7cc4710e81e3cecc25540b/README.md)
- [pinned MXFP4 repository tree](https://huggingface.co/olka-fi/Ornith-1.0-397B-MXFP4/tree/04940815e4ddf15e2b7cc4710e81e3cecc25540b)
- [vLLM context-parallel deployment](https://docs.vllm.ai/en/latest/serving/context_parallel_deployment/)
- [vLLM serve options](https://docs.vllm.ai/en/latest/cli/serve/)
