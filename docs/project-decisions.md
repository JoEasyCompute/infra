# Project Decisions

Human-readable summary of the current repo-level decisions that are also tracked in OMX memory.

This file is intended to help operators and future contributors understand the current stable paths, experimental lanes, and recent workflow decisions without needing OMX tooling.

---

## Stable vs Experimental Paths

### Stable

- `test/fulltest.sh`
  - Stable production GPU validation path.
  - Avoid heavy in-place flow refactors unless they have been validated on real Linux GPU hosts.

- `test/disktest.sh`
  - Current disk validation path.
  - Interactive by default on a TTY.
  - Supports `--non-interactive` for automation.

### Experimental

- `test/gpu-fulltest-v2.sh`
  - Experimental prepare-then-run variant of `test/fulltest.sh`.
  - Used as the safe lane for structural refactors to GPU validation flow.
  - Should be validated on real GPU hosts before replacing `test/fulltest.sh`.

- Ubuntu 26.04 support
  - `install/base-install.sh` now accepts Ubuntu 26.04 via the `ubuntu2604` CUDA repo codename.
  - `install/amd-base-install.sh` accepts Ubuntu 26.04 as a preview lane using AMD's 31.30 driver repo and `amdrocm7.13`.
  - Treat the AMD 26.04 path as experimental until it has been validated on real hardware.
  - `install/amd-stack-pin.sh` is the operator-facing helper for inspecting or restoring the AMD ROCm apt pin.

---

## Current Decisions

### 1. Do not heavily restructure `test/fulltest.sh` in place

Reason:

- `fulltest.sh` is an operational validation script, so regression risk is more important than internal architectural neatness.
- If the GPU validation flow needs broader structural experimentation, do it in `test/gpu-fulltest-v2.sh` first.

### 2. `disktest.sh` is operator-first on TTYs

Current behavior:

- guided interactive mode on TTY by default
- `--non-interactive` preserved for automation
- interactive mode selection
- checkbox-style disk selection
- per-disk reports written under the run log directory

### 3. Build-tree permission problems should fail early

Current behavior in `fulltest.sh`:

- warns early if build trees or cloned repos are root-owned or otherwise unwritable
- gives ownership-fix guidance before later rebuild / clean steps fail more opaquely

### 4. RAID / ESP redundancy is an opt-in install lane

Current behavior:

- `install/install-raid.sh` stages the RAID helper scripts by default
- `--activate` is required before the apt hook and systemd timer/service are installed
- non-RAID hosts are unaffected unless an operator explicitly activates the lane
- activation is intended for UEFI hosts with multiple ESPs; the installer blocks the common non-RAID case by default

### 5. NVIDIA stack freezing is explicit, not automatic

Current behavior:

- `base-install.sh` warns if held NVIDIA/CUDA packages already exist
- the validated stack can be frozen with `install/nvidia-stack-hold.sh --hold`
- `base-install.sh --unfreeze-gpu-stack` temporarily removes holds, performs the install/update, validates, and then re-freezes the result
- the default install path does not silently remove holds
- `install/provision.sh` passes `--freeze-gpu-stack` and `--unfreeze-gpu-stack` through to the NVIDIA stage-1 install
- AMD orchestration accepts the same flags for CLI symmetry, but the AMD stack is governed by repo pinning rather than apt-mark holds
- `install/amd-stack-pin.sh --status` shows the active ROCm pin and `--reset` restores the expected pin file

### 6. NVIDIA base install applies GPU fallback recovery policy

Current behavior:

- `install/base-install.sh` manages a systemd timeout block in `/etc/systemd/system.conf`
- the managed systemd values are `DefaultTimeoutStopSec=30s` and `DefaultTimeoutAbortSec=15s`
- it writes `/etc/sysctl.d/99-gpu-fallback.conf` with kernel panic / oops / hung-task fallback settings
- the policy is host-wide: a kernel oops or hung task from any subsystem can trigger panic/reboot, not only NVIDIA/GPU faults
- this is intentional for unattended compute nodes where automatic recovery is preferred over leaving a wedged host online for live debugging
- this is a first-layer, in-band mitigation; it does not guarantee recovery when the kernel reboot path blocks on a GPU that has fallen off the PCIe bus
- `install/force-reboot.sh` provides the in-band emergency SysRq reboot path for an operator at the host console when a normal reboot sequence is not completing
- `install/ipmi-power-cycle.sh` provides the out-of-band manual recovery path for that condition by asking the BMC/IPMI controller to power-cycle the chassis
- `install/rebuild-gpu-livefs.sh` is the host-side live-image rebuild helper for regenerating the `gpu-test` netboot image from a mounted USB root filesystem
- `install/build-gpu-liveiso.sh` is the standalone helper that turns a mounted USB root filesystem into a bootable `gpu-test` ISO without requiring the intermediate `rebuild-gpu-livefs.sh` step
- uninstall removes the managed systemd block and the sysctl drop-in

### 7. Base installs manage PCIe / NVMe boot policy at install time

Current behavior:

- `install/base-install.sh` and `install/amd-base-install.sh` both write a managed GRUB drop-in at `/etc/default/grub.d/99-infra-pcie-aspm.cfg`
- the drop-in appends `pcie_aspm=off`, `pci=noaer`, `pci=realloc=on`, `pcie_aspm.policy=performance`, and `nvme_core.default_ps_max_latency_us=0` to the boot command line so PCIe / storage power-management is tuned consistently on fresh installs
- the setting is idempotent across reruns because it lives in a managed drop-in rather than a hand-edited grub file
- `install/pcie-aspm.sh` is the standalone operator helper for checking, enabling, or disabling that same managed boot policy after provisioning
- uninstall removes the drop-in and regenerates grub configuration

This is a conservative stability choice for GPU hosts where ASPM-related link state changes can contribute to device instability.

### 8. User bootstrap is available as a standalone helper

Current behavior:

- `install/base-install.sh` still performs the normal SSH authorized-key and passwordless sudo setup for the target user during provisioning
- `install/user-bootstrap.sh` exists as a standalone helper for operators who want to create or update a user account, install a named repo bootstrap key from `keys/bootstrap/`, a custom key file, or pasted key text, and grant passwordless sudo without rerunning the full base install
- `install/user-bootstrap.sh --list-keys` shows available repo-managed bootstrap key names without requiring root
- the helper requires an explicit key selector for bootstrap mode and does not fall back to a hidden default key
- `root` remains unsupported as a bootstrap target

### 9. Sustained stress detects 12V-2x6 / 12VHPWR power anomalies as remarks by default

Current behavior:

- `test/fulltest.sh` and `test/gpu-fulltest-v2.sh` both analyse burn telemetry for sustained low-power / high-fan / cooler-than-peers patterns during `stress` and `node-stress`
- the detector is remark-only by default (`POWER_ANOMALY_AS_REMARK=1`) so fleet operators can see the warning without failing the run
- operators can opt back into hard-fail behavior by setting `POWER_ANOMALY_AS_REMARK=0`
- the warning is treated as a connector early-warning, not a generic thermal failure, because it is intended to catch likely 12V-2x6 / 12VHPWR contact resistance issues before the GPU falls off the bus
- the same detector and default behavior are documented in both `docs/fulltest.md` and `docs/gpu-fulltest-v2.md`

### 10. Future improvement plans for the power-anomaly detector

Planned follow-up work:

- add a standalone replay mode so archived burn telemetry can be analyzed without rerunning a stress test
- consider late-onset anomaly detection by comparing early vs late portions of the post-warmup window
- revisit the default severity only after more real-host data is collected across multiple GPU families and cooling topologies

These are tracked as future improvements, not current behavior.

### 11. `code.sh` is a lightweight per-GPU CUDA stress lane

Current behavior:

- `test/code.sh` compiles `test/code.cu` with `nvcc` when needed and runs the resulting binary
- `test/fulltest.sh` and `test/gpu-fulltest-v2.sh` include a `code` test that loops across every visible GPU in order
- the suites respect `--gpu` remapping by running the wrapper against logical device IDs `0..N-1`
- `CUDA_CODE_SECONDS` controls the per-GPU runtime inside the suites and defaults to `15`
- if `nvcc` is unavailable, the suites record the test as `NOT BEING RUN` instead of failing the whole validation pass

This gives the GPU test kit a simple, explicit integer-ALU stress path in addition to `memtest` and the heavier sustained-stress backends.

### 12. Stable `fulltest.sh` owns the PyTorch runtime boundary

Current behavior:

- `test/fulltest.sh` prefers the `base-install.sh` managed Python 3.11 runtime under `/opt/infra/python`
- if `base-install.sh` has not run, stable `fulltest.sh` can fall back to a supported system Python 3.10-3.12
- all PyTorch-backed stable helpers use the same isolated `build/pytorch-venv`, including DDP, PCIe load, clock load, and PyTorch stress fallback
- an existing PyTorch venv is rebuilt when its base interpreter does not match the selected runtime
- the shared runtime installs only `torch`; unused optional packages such as `torchvision`, `torchaudio`, and `accelerate` must not gate hardware tests
- runtime preparation verifies that Torch imports, sees a CUDA GPU, and provides `torchrun` from the managed venv
- `torchrun` is resolved only from the managed venv, not from global user or system paths

This keeps the normal workflow (`base-install.sh` first, then `fulltest.sh`) aligned while preserving a standalone `fulltest.sh` path for hosts that already have a usable Python runtime.

### 13. Deep persistent GPU health diagnostics are opt-in

Current behavior:

- `pcie-errors` compares PCIe replay counters around a CUDA P2P traffic interval and scans available kernel logs for fatal/uncorrectable PCIe events
- `memory-health` inspects ECC, retired-page, row-remapper, and newer repair-state fields without clearing counters
- `fabric-health` uses DCGM to compare NVLink/NVSwitch state and generation-specific error counters around P2P traffic
- cumulative historical counts do not fail by themselves; new counter growth and hard pending/failure states do
- unsupported hardware, missing DCGM, and unavailable counters are reported as `NOT BEING RUN`
- all three tests are selectable but excluded from `DEFAULT_TESTS`

This keeps routine provisioning runtime unchanged while giving operators
targeted diagnostics for suspected PCIe, persistent memory, or fabric faults.

### 14. vLLM model evaluation is a standalone post-provision lane

Current behavior:

- `test/vllm-benchmark-test.sh` runs only when an operator invokes it; it is not
  part of `fulltest.sh` or the automatic provisioning stages
- backend selection defaults to `auto`: a usable `nvidia-smi` GPU inventory
  selects NVIDIA, while a usable `rocminfo` GPU inventory plus `/dev/kfd` and
  `/dev/dri` selects AMD
- mixed NVIDIA/AMD hosts must use an explicit backend; undetected hosts fail
  before Docker checks or artifact creation, and metadata records the resolved
  `nvidia` or `amd` backend rather than the requested `auto` value
- explicit `--backend nvidia|amd --dry-run` remains hardware-free; default
  auto dry-runs perform only read-only vendor detection
- NVIDIA host prerequisites come from `base-install.sh` and
  `docker-install.sh`; AMD host prerequisites come from `amd-base-install.sh`
  and the Docker installer's AMD skip flags
- the NVIDIA backend uses the pinned
  `vllm/vllm-openai:v0.25.1-cu129` image; the CUDA 12.9 variant preserves
  compatibility with the repository's supported NVIDIA 575 driver lane
- the AMD backend targets R9700S-class `gfx120X` GPUs and uses the pinned
  `rocm/vllm:rocm7.13.0_gfx120X-all_ubuntu24.04_py3.13_pytorch_2.10.0_vllm_0.19.1`
  image so the container runtime matches the repository's ROCm 7.13 R9700S
  host lane
- the wrapper rejects the default AMD image on other GPU architectures;
  operators must provide a pinned architecture-compatible `--vllm-image`
- AMD containers receive `/dev/kfd` and `/dev/dri`, use
  `ROCR_VISIBLE_DEVICES` for selection, and run vLLM in eager mode for the
  RDNA 4 path
- Harbor `0.20.0` runs through an isolated uv-managed Python 3.12 tool
  environment, independently of the managed Python 3.11 runtime used by
  `fulltest.sh`
- the default `ornith-35b-practical` profile uses an immutable 35B Hugging
  Face revision, `terminal-bench@2.0`, 16K context, and model-specific vLLM
  parser settings
- the explicit `ornith-397b-published` profile pins the current immutable
  Ornith-1.0-397B revision, Harbor dataset snapshot
  `terminal-bench/terminal-bench-2-1@6`, 128K context, JSON response parsing,
  temperature/top-p 1.0, and 32 CPU / 49,152 MB task overrides
- the experimental NVIDIA-only `ornith-397b-mxfp4-128k` profile pins the
  community `olka-fi/Ornith-1.0-397B-MXFP4` revision
  `04940815e4ddf15e2b7cc4710e81e3cecc25540b` and keeps the 128K context with
  TP8/DCP4, FP8 KV cache with calculated scales, 0.95 memory utilization, one
  vLLM sequence, eager mode, language-model-only serving, and Harbor
  concurrency one
- practical and published profiles remain backend-independent and leave GPU
  topology operator-controlled; the MXFP4 profile is the deliberate exception
  and requires NVIDIA, at least eight selected GPUs, TP equal to the selected
  count, and DCP that divides TP
- explicit CLI settings override profile values regardless of argument order
  and mark run metadata as modified when effective profile-controlled values
  differ; the MXFP4 profile additionally tracks its image, topology, KV,
  sequence, execution-mode, concurrency, offload, and storage settings
- the MXFP4 hardware path requires at least 256,000 MiB aggregate selected
  NVIDIA memory and 300 GB free under the Docker root before downloads; these
  checks reduce avoidable downloads but do not guarantee vLLM will fit
- a bounded API readiness check and chat-completion smoke test gate the Harbor
  evaluation
- the wrapper binds only to localhost, never kills an arbitrary port owner, and
  cleans up only its named container
- run metadata, server output, smoke evidence, Harbor output, and task results
  are stored under `test/logs/vllm-benchmark/`

The default `terminal-bench@2.0` run is a model/agent task-success evaluation,
not a vLLM throughput benchmark. Its 16K context results must not be compared
directly with published 128K-context scores or runs with different images,
revisions, agents, parsers, concurrency, or datasets.

The 397B profile is named `published`, not `exact`. The public model card does
not disclose the original Harbor patch, immutable dataset snapshot, or
absolute four-hour task-timeout override. This repository pins Harbor `0.20.0`
and the current immutable Terminal-Bench 2.1 registry snapshot instead of
guessing undisclosed inputs. The wrapper defaults to one attempt per task;
operators can forward `--n-attempts 5` to Harbor when they want the disclosed
five-run shape.

The MXFP4 profile is a capacity experiment, not a published-score
reproduction. Its approximately 226 GB checkpoint is a community conversion,
and neither its quantization nor its vLLM settings are directly comparable
with the publisher's BF16 result. CPU offload stays disabled by default; an
operator may request `--cpu-offload-gb 2` as a modified fallback. The
experimental label remains until the pinned image and checkpoint pass startup
and the exact smoke response on a real eight-RTX-5090 host.

The default Ornith BF16 model does not fit on one 32 GB R9700S. The documented
AMD default uses at least four cards; one-card runs require a smaller or
quantized custom model with an immutable revision. The AMD `rocm/vllm` image
is a compatibility exception for the ROCm 7.13 `gfx120X` lane and should move
to a pinned upstream vLLM ROCm image once an equivalent ROCm 7.13-or-newer
build is available and validated.

---

## Operator Notes

### `disktest.sh`

Interactive disk picker controls:

- `↑` / `↓` — move
- `Space` — check / uncheck focused disk
- `Enter` — confirm selection
- `a` — select all / deselect all
- `q` — cancel

Per-disk reports are written under:

```text
<log-dir>/reports/
```

### `gpu-fulltest-v2.sh`

Current design goal:

1. detect
2. prepare selected tests
3. run selected tests
4. summarize prepare + test results separately

This script has mocked verification evidence for the prepare-then-run flow, but it should still be treated as experimental until exercised on real GPU hosts.

---

## Recent Validation Notes

- `disktest.sh`
  - verified with syntax checks and Dockerized Linux/Bash runs
  - interactive dry-run flow and health JSON/report output exercised

- `fulltest.sh`
  - permission warning refinements verified with syntax checks and Dockerized non-root unwritable-build scenarios

- `gpu-fulltest-v2.sh`
  - verified with syntax/help output
  - verified in a mocked container flow where prepare succeeds before execution
  - verified in a mocked container flow where prepare failure stops execution early

---

## Practical Guidance

- Use `test/fulltest.sh` for current real validation work.
- Use `test/gpu-fulltest-v2.sh` only for experimental flow evaluation.
- Use `install/install-raid.sh` only when the host actually has a multi-disk ESP / RAID boot layout, and leave it in stage-only mode on ordinary hosts.
- Keep changes to validation scripts small and evidence-driven unless working in the experimental lane.
