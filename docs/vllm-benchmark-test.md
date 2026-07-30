# vLLM Harbor Benchmark

`test/vllm-benchmark-test.sh` launches a pinned vLLM OpenAI-compatible server
in Docker, checks the API, and runs a pinned Harbor evaluation against it.

This is an opt-in post-provision test. It is not part of `fulltest.sh` or the
automatic provisioning stages.

## What It Measures

The default `ornith-35b-practical` profile evaluates:

- model: `deepreinforce-ai/Ornith-1.0-35B`
- model revision: `5df2ed3f675c7beaa490328cc70bb573b65fb660`
- NVIDIA vLLM image: `vllm/vllm-openai:v0.25.1-cu129`
- AMD vLLM image:
  `rocm/vllm:rocm7.13.0_gfx120X-all_ubuntu24.04_py3.13_pytorch_2.10.0_vllm_0.19.1`
- Harbor: `0.20.0`
- dataset: `terminal-bench@2.0`
- agent: `terminus-2`

This is a model and agent task-success evaluation. It is not a vLLM token
throughput or latency benchmark.

The default maximum context is 16,384 tokens so the run is practical on
provisioned GPU nodes. Do not compare its score directly with a published
128K-context model-card result or a run using different concurrency, parser,
agent, image, model revision, or dataset settings.

## Benchmark Profiles

| Setting | `ornith-35b-practical` | `ornith-397b-published` |
| --- | --- | --- |
| Model | `deepreinforce-ai/Ornith-1.0-35B` | `deepreinforce-ai/Ornith-1.0-397B` |
| Revision | `5df2ed3f675c7beaa490328cc70bb573b65fb660` | `5e3e761811e804c295c1d3c0ce68b21da6154209` |
| Dataset | `terminal-bench@2.0` | `terminal-bench/terminal-bench-2-1@6` |
| Maximum context | 16,384 | 131,072 |
| vLLM parsers | `qwen3_xml`, `qwen3` | `qwen3_xml`, `qwen3` |
| Harbor parser | `json` | `json` |
| Temperature / top-p | `1.0` / `1.0` | `1.0` / `1.0` |
| Task resources | Dataset defaults | 32 CPUs / 49,152 MB RAM |

The profile does not select the NVIDIA or AMD backend, GPU indices, or tensor
parallelism. Backend resolution happens separately through autodetection or an
explicit override. GPU indices and tensor parallelism remain
operator-controlled because usable capacity depends on the host topology and
backend image.

The 397B profile reproduces the settings disclosed by the
[Ornith-1.0-397B model card](https://huggingface.co/deepreinforce-ai/Ornith-1.0-397B)
where the repository can pin them. It uses the immutable Harbor registry
snapshot `terminal-bench/terminal-bench-2-1@6`; the dataset is listed in the
[Harbor dataset registry](https://hub.harborframework.com/datasets/terminal-bench/terminal-bench-2-1/latest).

The 397B BF16 checkpoint requires an exceptionally large multi-GPU memory
pool, particularly at 128K context. The wrapper intentionally does not guess a
minimum GPU count. Always inspect `--dry-run`, verify aggregate usable memory,
and choose `--gpus` and `--tp-size` for the actual node before allowing model
downloads.

Explicit options override profile values regardless of argument order.
Changing a profile-controlled setting records `profile_modified=true` and
prints a warning that the result is not directly comparable with the
unmodified profile.

## Backend Selection

`--backend auto` is the default. Before Docker checks or downloads, the wrapper
performs read-only vendor detection:

- NVIDIA is usable when `nvidia-smi` reports at least one GPU index.
- AMD is usable when `rocminfo` reports at least one `gfx*` agent and
  `/dev/kfd` plus `/dev/dri` are available.

When exactly one backend is usable, the wrapper selects its pinned image,
inventory path, device arguments, and prerequisite checks. The effective
backend (`nvidia` or `amd`) is recorded in metadata and summaries.

If both vendors are usable, the wrapper stops and requires
`--backend nvidia` or `--backend amd`; it does not guess which devices should
run the model. If neither is usable, it stops with vendor-runtime guidance.
An explicit backend always overrides autodetection.

Default `--dry-run` performs this read-only detection but still skips Docker,
downloads, and filesystem changes. On a non-GPU development machine, select a
backend explicitly to inspect its command without requiring vendor hardware:

```bash
./test/vllm-benchmark-test.sh --backend nvidia --dry-run
./test/vllm-benchmark-test.sh --backend amd --dry-run
```

### Published-Score Reproducibility Boundary

The published result also describes a four-hour task limit and an average
over five runs. The public material does not provide the exact Harbor patch,
the original dataset snapshot, or the absolute timeout override. Harbor
`0.20.0` supports the disclosed `reasoning_content` behavior, but its ad hoc
CLI exposes timeout multipliers rather than a single absolute per-task
timeout.

This repository therefore pins Harbor `0.20.0`, model revision
`5e3e761811e804c295c1d3c0ce68b21da6154209`, and dataset snapshot `@6`, while
retaining that snapshot's task-specific timeouts. A result from this profile
is a reproduction of the publicly available settings, not a bit-for-bit
reproduction of the reported score.

## NVIDIA Prerequisites

Run the NVIDIA provisioning stages first:

```bash
sudo ./install/base-install.sh
sudo reboot
sudo ./install/docker-install.sh
sudo reboot
```

The benchmark expects:

- a working NVIDIA driver and `nvidia-smi`
- Docker access for the current user
- NVIDIA Container Toolkit GPU access
- `curl`, `python3`, and `uv`
- enough free space under the Docker root for the image, model, and task images
- internet access for the first image, model, Python, and dataset downloads

`base-install.sh` installs `uv`; `docker-install.sh` installs Docker and the
NVIDIA Container Toolkit. Re-login after `docker-install.sh` if the current
shell does not yet have Docker group access.

The default vLLM image uses its CUDA 12.9 build so it remains compatible with
the repository's supported NVIDIA 575 driver lane as well as newer drivers.

## AMD R9700S Prerequisites

The AMD backend is designed for the AMD Radeon AI PRO R9700S (`gfx1201`,
32 GB) and the related `gfx120X` family. For an R9700S node, use the
repository's Ubuntu 26.04 ROCm 7.13 preview lane:

```bash
sudo ./install/amd-base-install.sh --rocm 7.13
sudo reboot
sudo ./install/docker-install.sh \
    --skip-nvidia-toolkit \
    --skip-nouveau-blacklist
sudo reboot
```

`install/provision-amd.sh` performs the equivalent AMD and Docker stages when
using the orchestrated flow.

The AMD backend expects:

- `rocminfo` to report one `gfx1201` agent per selected R9700S
- `rocm-smi` to report the installed ROCm stack
- `/dev/kfd` and `/dev/dri` to be available to Docker
- Docker access for the current user
- membership in the host `video` and `render` groups

The default image is AMD's pinned ROCm 7.13 `gfx120X` vLLM image. The script
overrides that image's Bash entrypoint with `vllm serve`, passes the ROCm
device nodes, and enables eager execution for the RDNA 4 path. It rejects the
default image on other AMD architectures. A different AMD GPU requires an
immutable architecture-compatible image through `--vllm-image`.

The R9700S product and `gfx1201` support are documented in the
[AMD product specification](https://www.amd.com/en/products/graphics/workstations/radeon-ai-pro/ai-9000-series/amd-radeon-ai-pro-r9700s.html)
and the
[ROCm 7.13 compatibility matrix](https://rocm.docs.amd.com/en/7.13.0-preview/compatibility/compatibility-matrix.html).

The default Ornith model uses BF16 weights and does not fit on one 32 GB
R9700S. Use at least four R9700S-class GPUs for the repository's default
16K-context configuration. For one or two cards, select a smaller or
appropriately quantized model and pin its immutable revision.

## Hugging Face Access

Set `HF_TOKEN` when the selected model requires authenticated Hugging Face
access:

```bash
export HF_TOKEN="..."
```

The script passes the variable into Docker by name. It does not print or store
the token value in wrapper logs or metadata. Docker retains container
environment values for the lifetime of the container, so avoid
`--keep-server` with `HF_TOKEN` unless that debugging tradeoff is intentional.

## Usage

Inspect the NVIDIA plan without vendor checks, downloads, or filesystem
changes:

```bash
./test/vllm-benchmark-test.sh \
    --backend nvidia \
    --dry-run \
    --gpus 0,1,2,3 \
    --tp-size 4
```

Run only server startup and a chat-completion smoke test:

```bash
./test/vllm-benchmark-test.sh \
    --smoke \
    --gpus 0,1,2,3 \
    --tp-size 4
```

Run the full Harbor evaluation:

```bash
./test/vllm-benchmark-test.sh \
    --gpus 0,1,2,3,4,5,6,7 \
    --tp-size 8
```

The smoke and full-run examples above use default backend autodetection.

Run the published-settings 397B profile:

```bash
./test/vllm-benchmark-test.sh \
    --profile ornith-397b-published \
    --gpus 0,1,2,3,4,5,6,7 \
    --tp-size 8
```

One wrapper invocation performs one attempt per task unless Harbor arguments
override that behavior. To request five attempts, matching the published
run-count description:

```bash
./test/vllm-benchmark-test.sh \
    --profile ornith-397b-published \
    --gpus 0,1,2,3,4,5,6,7 \
    --tp-size 8 \
    -- --n-attempts 5
```

Run the AMD R9700S path:

```bash
./test/vllm-benchmark-test.sh \
    --backend amd \
    --smoke \
    --gpus 0,1,2,3 \
    --tp-size 4

./test/vllm-benchmark-test.sh \
    --backend amd \
    --gpus 0,1,2,3 \
    --tp-size 4
```

Inspect the AMD command without requiring an AMD host:

```bash
./test/vllm-benchmark-test.sh \
    --backend amd \
    --dry-run \
    --gpus 0,1,2,3 \
    --tp-size 4
```

Use `--help` for all resource, timeout, image, model, dataset, and output
options. Arguments after `--` are passed directly to `harbor run`:

```bash
./test/vllm-benchmark-test.sh --gpus 0,1 --tp-size 2 -- \
    --task-name terminal-bench-core
```

For a custom model, provide an immutable revision as well:

```bash
./test/vllm-benchmark-test.sh \
    --model organization/model-name \
    --model-revision COMMIT_SHA \
    --gpus 0,1 \
    --tp-size 2
```

Custom models may also require different vLLM tool or reasoning parsers. This
script's parser defaults are specific to the pinned Ornith model. Override
them with `--tool-call-parser` and `--reasoning-parser`, or pass `none` to
disable a parser. Harbor-side parsing and sampling can be changed with
`--harbor-parser`, `--temperature`, and `--top-p`. Use `--task-cpus` and
`--task-memory-mb` to change Harbor task resource overrides.

For a smaller single-R9700S model:

```bash
./test/vllm-benchmark-test.sh \
    --backend amd \
    --model organization/smaller-model \
    --model-revision COMMIT_SHA \
    --gpus 0 \
    --tp-size 1
```

## Safety And Lifecycle

The script:

- binds the API to `127.0.0.1` only
- refuses to replace an existing listener on the selected port
- refuses to reuse an existing benchmark container name
- verifies NVIDIA or ROCm access inside the selected vLLM image
- records the backend, GPU runtime version, and AMD GPU architectures
- checks Docker-root free space before downloads
- uses the persistent Docker volume `infra-vllm-hf-cache` for model cache
- waits for `/v1/models` with a bounded timeout
- runs a chat-completion smoke test before Harbor
- removes only its named container on exit

Use `--keep-server` to leave the named container running for debugging. Remove
it later with:

```bash
docker rm -f infra-vllm-benchmark-8000
docker rm -f infra-vllm-benchmark-amd-8000
```

`--no-pull` requires the configured image to exist locally.

## Artifacts

By default each run is written under:

```text
test/logs/vllm-benchmark/YYYYMMDD_HHMMSS/
```

The directory contains:

- `metadata.json`: profile, effective settings, pinned versions, image digest,
  GPU inventory, and run status
- `summary.txt`: concise completion status and effective configuration
- `console.log`: lifecycle messages emitted by the wrapper
- `server.log`: vLLM container output
- `models.json`: successful readiness response
- `smoke-request.json` and `smoke-response.json`: API smoke evidence
- `harbor.log`: Harbor console output
- `jobs/`: Harbor task results

`metadata.json` and `summary.txt` include the profile name, modified flag,
effective parser/sampling/resource settings, effective Harbor command, and any
arguments forwarded after `--`, so filtered or otherwise customized runs
remain attributable.

The wrapper's successful exit means the configured Harbor command completed.
Inspect Harbor's `jobs/` output for task rewards and benchmark scores.

## Troubleshooting

- auto backend reports both vendors: choose `--backend nvidia` or
  `--backend amd` explicitly.
- auto backend cannot detect a usable vendor: verify `nvidia-smi`, or verify
  `rocminfo`, `/dev/kfd`, and `/dev/dri`; use an explicit backend only when
  intentionally rendering a hardware-free dry-run.
- `Docker is unavailable`: start Docker or re-login after group membership was
  added by `docker-install.sh`.
- NVIDIA container probe fails: verify `nvidia-ctk` configuration and restart
  Docker.
- `rocminfo did not report any AMD GPU agents`: verify the host ROCm install,
  the `amdgpu` driver, and the current user's `video` and `render` groups.
- AMD compute device is unavailable: verify `/dev/kfd` and `/dev/dri` exist
  after rebooting into the supported ROCm kernel.
- default AMD image architecture error: use the R9700S `gfx1201` host lane or
  pass a pinned vLLM image built for the detected AMD architecture.
- Model startup times out: inspect `server.log`, reduce
  `--max-model-len`, verify the tensor-parallel size, and check GPU memory.
- Docker-root free-space check fails: free space or deliberately lower
  `--min-free-gb`; use `0` only when storage capacity is already monitored.
- Harbor fails after the smoke test: inspect `harbor.log` and the partial
  `jobs/` output. The vLLM server log remains available after cleanup.
