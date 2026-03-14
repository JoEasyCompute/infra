# base-install-amd.sh — AMD GPU Node Installation Guide

**Version:** 1.3 (2026-03-14)  
**Target:** AMD Radeon AI Pro R9700 (RDNA4 / gfx1201)  
**Supported OS:** Ubuntu 22.04 LTS, Ubuntu 24.04 LTS (x86_64)

---

## Overview

`base-install-amd.sh` provisions a bare Ubuntu server with the full AMD GPU software stack needed for AI/ML compute workloads on the Radeon AI Pro R9700. It installs the AMDGPU DKMS kernel driver, the ROCm software stack, configures the AI/ML environment for PyTorch compatibility, and clones the `joeasycompute/infra` repo.

This script is the AMD counterpart to `base-install.sh` (NVIDIA/CUDA). The design patterns are identical — same logging, preflight checks, interactive/non-interactive modes, structured sections, and uninstall capability.

### What it installs

| Component | AMD equivalent | NVIDIA equivalent |
|---|---|---|
| Kernel driver | `amdgpu-dkms` | `nvidia-dkms-*-open` |
| Compute stack | `rocm` meta-package | `cuda-toolkit` + `cudnn` |
| GPU status tool | `rocm-smi` | `nvidia-smi` |
| GPU topology | `rocminfo` | `nvidia-smi -q` |
| Bandwidth test | `rocm-bandwidth-test` | `nvbandwidth` |
| ML arch target | `PYTORCH_ROCM_ARCH=gfx1201` | `CUDA_VISIBLE_DEVICES` |

The `rocm` meta-package pulls in: HIP runtime, OpenCL, rocBLAS, rocFFT, MIOpen (≈ cuDNN), hipBLASLt, rocm-smi, rocminfo, and profiling tools. There is no AMD equivalent of DCGM.

### What it does NOT install

PyTorch is intentionally not pip-installed by this script. The correct ROCm wheel index URL changes per release, most production workloads use per-project venvs or Docker (`rocm/pytorch` images), and the driver must be loaded (post-reboot) before `torch.cuda` is useful. The script prints the exact install commands to use post-reboot.

---

## Requirements

- Ubuntu 22.04.5 or 24.04.3 (x86_64)
- Supported kernel (see [Kernel Requirements](#kernel-requirements) below)
- 15 GB+ free on `/usr` (ROCm stack is ~8–10 GB)
- Network access to `repo.radeon.com` and `github.com`
- Secure Boot disabled in BIOS
- `sudo` access without password prompt

---

## Kernel Requirements

This is the most common source of `amdgpu-dkms` build failures. AMD's DKMS driver ships a fixed kernel driver that only has backport shims up to a certain kernel API level. **The issue is kernels that are too new, not too old.**

| Ubuntu | Supported kernels | Unsupported (DKMS build fails) |
|--------|-------------------|-------------------------------|
| 22.04  | 5.15.x (GA) ✅  6.8.x (HWE) ✅ | 6.11+ ❌ |
| 24.04  | 6.8.x (GA) ✅ | 6.11+ HWE ❌ |

The script checks your running kernel in preflight and warns explicitly if you are outside the supported range, with the exact fix command.

**Ubuntu 22.04 — already on 5.15 (stock LTS):** no action needed, this is supported.

**Ubuntu 22.04 — on 6.8 HWE:** also supported, no action needed.

**Ubuntu 22.04 — on 6.11+ HWE:** revert before running the script:
```bash
sudo apt install linux-generic-hwe-22.04
sudo reboot
# select 6.8 kernel in GRUB, then re-run the script
```

**Ubuntu 24.04 — on 6.11+ HWE:** pin back to GA kernel:
```bash
sudo apt install linux-image-6.8.0-generic linux-headers-6.8.0-generic
sudo reboot
# select 6.8 in GRUB, then re-run the script
```

---

## Usage

```bash
# Interactive install (prompts for ROCm version)
sudo bash base-install-amd.sh

# Explicit ROCm version
sudo bash base-install-amd.sh --rocm 7.2

# Non-interactive / CI (defaults: ROCm 7.2)
sudo bash base-install-amd.sh --yes

# Full uninstall (interactive)
sudo bash base-install-amd.sh --uninstall

# Full uninstall (non-interactive)
sudo bash base-install-amd.sh --uninstall --yes
```

### ROCm version selection

| Option | ROCm | AMDGPU driver build | Notes |
|--------|------|---------------------|-------|
| `--rocm 7.2` | 7.2 | 30.30 | Default, recommended for R9700 |
| `--rocm 7.1` | 7.1 | 30.20.1 | Previous stable |

**Important:** The `amdgpu` driver repo uses a separate build number versioning scheme (e.g. `30.30`) that does not match the ROCm version string. The script maps these automatically. When upgrading ROCm in the future, check `https://repo.radeon.com/amdgpu/` for the correct build number and update the mapping table in `install_rocm_repos()`.

---

## Install Steps

### Step 1 — Detect OS
Reads `/etc/os-release`, confirms Ubuntu, maps version to apt codename (`jammy` / `noble`). Errors on unsupported versions.

### Step 2 — Pre-flight Checks
Runs before any changes are made. Checks: sudo access, x86_64 architecture, 15 GB+ free disk, HTTPS connectivity to `repo.radeon.com` (hard fail) and `github.com` (soft warn), Secure Boot state, existing conflicting packages, **kernel version** (see [Kernel Requirements](#kernel-requirements)), kernel headers availability, AMD GPU presence in `lspci`.

The GPU not appearing in `lspci` is a warning, not a hard failure — the driver will install fine without the card present and bind to it after a reboot with the card seated.

### Step 3 — ROCm Version Selection
Interactive menu or `--rocm` argument. Defaults to 7.2 in non-interactive mode.

### Step 4 — Confirm
Prints the full install summary including Ubuntu version, driver build, ROCm version, GPU target, and `PYTORCH_ROCM_ARCH` setting. Prompts for confirmation unless `--yes` is set.

### Step 5 — Base System Packages
Installs: `apt-transport-https`, `ca-certificates`, `curl`, `gnupg`, `wget`, `linux-headers-$(uname -r)`, `linux-modules-extra-$(uname -r)`, `linux-headers-generic`, `git`, `cmake`, `build-essential`, `dkms`, `gcc-11`, `gcc-12`, `g++-11`, `g++-12`, `python3`, `python3-pip`, `python3-venv`, `python3-setuptools`, `python3-wheel`, `chrony`, `smartmontools`, `lvm2`, `mdadm`, `lsof`, `ioping`, `pciutils`, `nvme-cli`, `ipmitool`, `jq`, `dmidecode`, `lshw`, `bpytop`, `mokutil`.

`linux-modules-extra-$(uname -r)` is required for `amdgpu-dkms` and is not needed for the NVIDIA equivalent. `fio` is intentionally excluded — managed by `disktest.sh`.

### Step 6 — GCC Alternatives
Registers gcc-11 and gcc-12 with `update-alternatives`. Active compiler defaults to gcc-12.

### Step 7 — AMD ROCm Repository & Signing Key

**Stale repo cleanup:** Before writing any repo files, the script removes any existing `amdgpu.list`, `rocm.list`, and `rocm-pin-600` from a previous run (failed or otherwise). This prevents a retry from inheriting a wrong URL. A silent `apt-get update` flushes the stale cache.

**Repo setup:** Three components are configured:

```
/etc/apt/sources.list.d/amdgpu.list
  → https://repo.radeon.com/amdgpu/{BUILD_NUMBER}/ubuntu {codename} main
  → Uses the AMDGPU build number (e.g. 30.30), NOT the ROCm version string

/etc/apt/sources.list.d/rocm.list
  → https://repo.radeon.com/rocm/apt/{ROCM_VERSION} {codename} main
  → https://repo.radeon.com/graphics/{ROCM_VERSION}/ubuntu {codename} main
  → Uses the ROCm version string (e.g. 7.2)

/etc/apt/preferences.d/rocm-pin-600
  → Pins repo.radeon.com packages to priority 600
  → Prevents Ubuntu defaults from overriding AMD packages
```

GPG key is downloaded from `https://repo.radeon.com/rocm/rocm.gpg.key`, dearmored, and stored at `/etc/apt/keyrings/rocm.gpg`.

### Step 8 — AMDGPU Driver + ROCm Stack
Installs `amdgpu-dkms` first (kernel module, DKMS-managed), then the `rocm` meta-package (full userspace stack). Adds the current user to the `render` and `video` groups — required for GPU device access on AMD (no equivalent needed for NVIDIA). Group membership takes effect on next login.

### Step 9 — ROCm PATH Configuration
Writes `/etc/profile.d/rocm.sh` with:
```bash
export PATH="/opt/rocm/bin:${PATH}"
export LD_LIBRARY_PATH="/opt/rocm/lib:${LD_LIBRARY_PATH:-}"
```
Also exports into the current shell session so `rocm-smi` and `rocminfo` are available during the same-session validation step.

### Step 9.5 — AI/ML Environment Configuration
Appends ML-specific environment variables to `/etc/profile.d/rocm.sh`:

```bash
# Set by the script (active):
export PYTORCH_ROCM_ARCH="gfx1201"

# Commented out (reference only):
# export HIP_VISIBLE_DEVICES=0
# export HSA_OVERRIDE_GFX_VERSION=12.0.1
```

**`PYTORCH_ROCM_ARCH=gfx1201`** — critical. Tells PyTorch which GPU architecture to compile JIT kernels for. Without this, PyTorch may target a generic or wrong arch, causing silent performance degradation or outright kernel failures on the R9700. For multi-GPU nodes with mixed architectures, use semicolons: `gfx1100;gfx1201`.

**`HIP_VISIBLE_DEVICES`** — commented out. Unset means all GPUs are visible (correct default). Override per-job at runtime: `HIP_VISIBLE_DEVICES=0,1 python train.py`.

**`HSA_OVERRIDE_GFX_VERSION`** — commented out. Not needed for R9700 under ROCm 7.x since gfx1201 is natively recognized. Kept as a break-glass option in case a future ROCm regression drops gfx1201 recognition.

The script also prints post-reboot PyTorch install instructions (see [Post-Reboot: PyTorch Setup](#post-reboot-pytorch-setup)).

### Step 10 — rocm-bandwidth-test
Verifies `rocm-bandwidth-test` is present (included in the `rocm` meta-package). This is the primary post-install bandwidth validation tool, analogous to `nvbandwidth` on NVIDIA nodes.

### Step 11 — Repos
Clones or pulls `https://github.com/joeasycompute/infra.git` to `~/infra`.

### Step 12 — Post-install Validation
Checks: `rocm-smi` GPU count and product name, `rocminfo` GPU arch (validates `gfx1201`), `amdgpu` DKMS build status, `render` group membership, `chrony` service state, `infra` repo presence. Most checks are expected to be pending before the first reboot — `rocm-smi` and `rocminfo` require the kernel module to be loaded.

### Step 13 — Reboot Prompt
Offers reboot to load the `amdgpu` kernel module. In non-interactive mode, prints a reminder to reboot manually.

---

## Post-Reboot: Validation

```bash
# Confirm GPU is recognized
rocm-smi
rocminfo | grep -A5 "Marketing Name"

# Confirm gfx arch is gfx1201
rocminfo | grep "Name:" | grep gfx

# Confirm DKMS module loaded
dkms status | grep amdgpu
lsmod | grep amdgpu

# Bandwidth test
rocm-bandwidth-test -a
```

---

## Post-Reboot: PyTorch Setup

The standard `pip install torch` gives a CUDA build that will not use the AMD GPU. You must use the ROCm-specific index URL.

```bash
# Option A: pip (system Python or venv)
pip install torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/rocm7.2

# Option B: AMD official Docker image (recommended for production)
docker pull rocm/pytorch:rocm7.2_ubuntu22.04_py3.10_pytorch_release_2.8.0

# Verify — ROCm intentionally surfaces AMD GPUs through torch.cuda
python3 -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"
# Expected: True  AMD Radeon AI PRO R9700
```

### Other ROCm-native tools

```bash
# vLLM — picks up ROCm automatically when PYTORCH_ROCM_ARCH is set
pip install vllm

# llama.cpp — HIP backend
cmake -B build -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1201 ..
cmake --build build --config Release

# Ollama (ROCm-enabled build)
# Follow https://github.com/ollama/ollama — ROCm support is built-in on AMD
```

---

## Known Limitations (R9700 / gfx1201 as of ROCm 7.2)

**MIOpen kernel performance** — MIOpen (AMD's cuDNN equivalent) kernel optimization for gfx1201 is still maturing. PyTorch training benchmarks on RDNA4 may underperform relative to theoretical peak. ROCm 7.x releases are progressively improving gfx1201 MIOpen coverage.

**FP8 via Transformer Engine** — FP8 hardware is present on the R9700, and FP8 works in PyTorch for KV cache. However, ROCm's Transformer Engine currently whitelists only CDNA-class devices for its FP8 path; RDNA4 (gfx1201) is not yet on that whitelist. Track: `ROCm/TransformerEngine#359`.

**P2P / xGMI between multiple R9700s** — PCIe peer-to-peer between consumer/pro RDNA4 cards is not officially supported by ROCm. Multi-GPU workloads will use PCIe host-mediated transfers rather than direct GPU-to-GPU. This affects multi-GPU training bandwidth.

**HIP idle power bug** — Under ROCm 7.1.x, the HIP runtime on gfx1201 keeps GPUs at elevated clocks/power after initialization until the process exits. Track: `ROCm/ROCm#5706`. Workaround: use the Vulkan backend for llama.cpp if idle power matters.

---

## Uninstall

The uninstall path (`--uninstall`) performs a full clean removal and restores the system to its pre-install state:

- Purges all `amdgpu`, `rocm`, `hip-*`, `hsa-*`, `miopen`, `rocblas`, and related packages
- Removes all `amdgpu` DKMS entries and built `.ko` files, rebuilds module map
- Removes `/opt/rocm`
- Removes `/etc/profile.d/rocm.sh` (PATH + ML env vars)
- Removes `/etc/apt/sources.list.d/amdgpu.list`, `rocm.list`
- Removes `/etc/apt/preferences.d/rocm-pin-600`
- Removes `/etc/apt/keyrings/rocm.gpg`
- Removes GCC `update-alternatives` entries
- Optionally removes `~/infra`
- Runs `apt autoremove` to clean orphaned dependencies
- Prompts for reboot to fully unload the kernel module

---

## File Locations

| Path | Purpose |
|------|---------|
| `/var/log/amd-node-install/install-*.log` | Per-run install log |
| `/etc/profile.d/rocm.sh` | PATH, LD_LIBRARY_PATH, PYTORCH_ROCM_ARCH |
| `/etc/apt/sources.list.d/amdgpu.list` | AMDGPU driver repo |
| `/etc/apt/sources.list.d/rocm.list` | ROCm software repo |
| `/etc/apt/preferences.d/rocm-pin-600` | AMD repo priority pin |
| `/etc/apt/keyrings/rocm.gpg` | AMD GPG signing key |
| `/opt/rocm/` | ROCm installation root |
| `/opt/rocm/bin/rocm-smi` | GPU status tool |
| `/opt/rocm/bin/rocminfo` | GPU topology tool |
| `/opt/rocm/bin/rocm-bandwidth-test` | Bandwidth test tool |
| `~/infra/` | joeasycompute/infra repo |

---

## Key Differences from base-install.sh (NVIDIA)

| Aspect | AMD (`base-install-amd.sh`) | NVIDIA (`base-install.sh`) |
|--------|----------------------------|---------------------------|
| Driver package | `amdgpu-dkms` | `nvidia-dkms-{ver}-open` |
| Extra kernel pkg | `linux-modules-extra-$(uname -r)` | Not required |
| Compute stack | `rocm` (single meta-package) | `cuda-toolkit` + `cudnn9` + `libnvidia-compute` |
| User groups | `render`, `video` (required) | Not required |
| PATH config | `/etc/profile.d/rocm.sh` | `/etc/profile.d/cuda.sh` |
| Install root | `/opt/rocm/` | `/usr/local/cuda/` |
| Version selector | `--rocm <7.2\|7.1>` | `--driver <575\|580\|590>` + `--cuda <12-9\|13>` |
| Repo URL scheme | Two separate schemes (ROCm version + AMDGPU build number) | Single CUDA keyring |
| Monitoring | `rocm-smi`, `rocminfo` | `nvidia-smi`, DCGM |
| Bandwidth test | `rocm-bandwidth-test` | `nvbandwidth` |
| ML arch env var | `PYTORCH_ROCM_ARCH=gfx1201` | Not needed (CUDA auto-detects) |
| Kernel constraint | Must be ≤ 6.8 (too-new kernel breaks DKMS build) | No upper kernel constraint |

---

## Changelog

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-03-03 | Initial release |
| 1.1 | 2026-03-13 | Fixed `amdgpu.list` URL: use AMDGPU build number (30.30) not ROCm version string (7.2) |
| 1.2 | 2026-03-14 | Added stale repo cleanup at start of `install_rocm_repos()`; added kernel version check to preflight with per-distro guidance and interactive abort |
| 1.3 | 2026-03-14 | Added Step 9.5: `configure_ml_environment()` — sets `PYTORCH_ROCM_ARCH=gfx1201`, documents `HIP_VISIBLE_DEVICES` and `HSA_OVERRIDE_GFX_VERSION`, prints post-reboot PyTorch/vLLM/llama.cpp install commands |
