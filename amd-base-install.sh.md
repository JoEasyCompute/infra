# base-install-amd.sh — AMD GPU Node Installation Guide

**Version:** 2.0 (2026-03-15)  
**Supported GPUs:** Any ROCm-compatible AMD GPU  
**Supported OS:** Ubuntu 22.04 LTS, Ubuntu 24.04 LTS (x86_64)

---

## Overview

`base-install-amd.sh` provisions a bare Ubuntu server with the full AMD GPU software stack needed for compute and AI/ML workloads. It installs the AMDGPU DKMS kernel driver, the ROCm software stack, auto-detects the installed GPU architecture to configure the PyTorch environment, and clones the `joeasycompute/infra` repo.

The script is GPU-agnostic — it works for any ROCm-supported AMD GPU including consumer Radeon (RX 7000/9000 series), professional Radeon PRO/AI PRO, and Instinct data centre cards. Common examples:

| GPU | Architecture |
|-----|-------------|
| Radeon AI Pro R9700 | gfx1201 (RDNA4) |
| Radeon RX 9070 XT | gfx1201 (RDNA4) |
| Radeon RX 7900 XTX | gfx1100 (RDNA3) |
| Radeon PRO W7900 | gfx1100 (RDNA3) |
| Instinct MI300X | gfx942 (CDNA3) |
| Instinct MI250X | gfx90a (CDNA2) |

This script is the AMD counterpart to `base-install.sh` (NVIDIA/CUDA). The design patterns are identical — same logging, preflight checks, interactive/non-interactive modes, structured sections, and full uninstall capability.

### What it installs

| Component | AMD | NVIDIA equivalent |
|-----------|-----|-------------------|
| Kernel driver | `amdgpu-dkms` | `nvidia-dkms-*-open` |
| Compute stack | `rocm` meta-package | `cuda-toolkit` + `cudnn` |
| GPU status tool | `rocm-smi` | `nvidia-smi` |
| GPU topology | `rocminfo` | `nvidia-smi -q` |
| Bandwidth test | `rocm-bandwidth-test` | `nvbandwidth` |
| ML arch targeting | `PYTORCH_ROCM_ARCH` (auto-detected) | auto via CUDA |

The `rocm` meta-package pulls in: HIP runtime, OpenCL, rocBLAS, rocFFT, MIOpen (≈ cuDNN), hipBLASLt, rocm-smi, rocminfo, and profiling tools. There is no AMD equivalent of DCGM.

### What it does NOT install

PyTorch is intentionally not pip-installed by this script. The correct ROCm wheel index URL changes per release, most production workloads use per-project venvs or Docker (`rocm/pytorch` images), and the driver must be loaded (post-reboot) before `torch.cuda` is useful. The script prints the exact install commands to run post-reboot.

---

## Requirements

- Ubuntu 22.04.5 or 24.04.3 (x86_64)
- Supported kernel — see [Kernel Requirements](#kernel-requirements)
- 15 GB+ free on `/usr` (ROCm stack is ~8–10 GB)
- Network access to `repo.radeon.com` and `github.com`
- Secure Boot disabled in BIOS
- `sudo` access without password prompt

---

## Kernel Requirements

This is the most common source of `amdgpu-dkms` build failures. AMD's DKMS driver ships with backport shims only up to a certain kernel API level. **The failure mode is kernels that are too new, not too old.**

| Ubuntu | Supported kernels | Unsupported (DKMS build fails) |
|--------|-------------------|-------------------------------|
| 22.04 | 5.15.x (GA) ✅  6.8.x (HWE) ✅ | 6.11+ ❌ |
| 24.04 | 6.8.x (GA) ✅ | 6.11+ HWE ❌ |

The script checks your running kernel in preflight and warns with the exact fix command if you are outside the supported range.

**Ubuntu 22.04 on 5.15 (stock LTS) or 6.8 HWE:** no action needed.

**Ubuntu 22.04 on 6.11+ HWE:** revert before running the script:
```bash
sudo apt install linux-generic-hwe-22.04
sudo reboot
# select 6.8 kernel in GRUB, then re-run the script
```

**Ubuntu 24.04 on 6.11+ HWE:** pin back to GA kernel:
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
| `--rocm 7.2` | 7.2 | 30.30 | Default, current production |
| `--rocm 7.1` | 7.1 | 30.20.1 | Previous stable |

**Important — two separate versioning schemes:** The `amdgpu` driver repo uses a build number (e.g. `30.30`) that does not match the ROCm version string. The script maps these automatically. When a new ROCm release comes out, check `https://repo.radeon.com/amdgpu/` for the correct build number and update the mapping table in `install_rocm_repos()`.

---

## Install Steps

### Step 1 — Detect OS
Reads `/etc/os-release`, confirms Ubuntu, maps version to apt codename (`jammy` / `noble`). Errors on unsupported versions.

### Step 2 — Pre-flight Checks
Runs before any changes are made. Checks in order: sudo access, x86_64 architecture, 15 GB+ free on `/usr`, HTTPS connectivity to `repo.radeon.com` (hard fail) and `github.com` (soft warn), Secure Boot state, existing conflicting AMDGPU/ROCm packages, **kernel version** (see above), kernel headers availability in apt cache, AMD GPU presence in `lspci`.

The GPU not appearing in `lspci` is a warning, not a hard failure — the driver will install fine without the card physically present and will bind to it after reboot.

### Step 3 — ROCm Version Selection
Interactive menu or `--rocm` argument. Defaults to 7.2 in non-interactive mode.

### Step 4 — Confirm
Prints the full install summary: Ubuntu version, AMDGPU driver build number, ROCm version, GPU arch detection note, and log file path. Prompts for confirmation unless `--yes`.

### Step 5 — Base System Packages
Installs: `apt-transport-https`, `ca-certificates`, `curl`, `gnupg`, `wget`, `linux-headers-$(uname -r)`, **`linux-modules-extra-$(uname -r)`** (required for `amdgpu-dkms`, not needed for NVIDIA), `linux-headers-generic`, `git`, `cmake`, `build-essential`, `dkms`, `gcc-11`, `gcc-12`, `g++-11`, `g++-12`, `python3`, `python3-pip`, `python3-venv`, `python3-setuptools`, `python3-wheel`, `chrony`, `smartmontools`, `lvm2`, `mdadm`, `lsof`, `ioping`, `pciutils`, `nvme-cli`, `ipmitool`, `jq`, `dmidecode`, `lshw`, `bpytop`, `mokutil`. `fio` is intentionally excluded — managed by `disktest.sh`.

### Step 6 — GCC Alternatives
Registers gcc-11 and gcc-12 with `update-alternatives`. Active compiler defaults to gcc-12.

### Step 7 — AMD ROCm Repository & Signing Key

**Stale repo cleanup:** Before writing any repo files, removes any existing `amdgpu.list`, `rocm.list`, and `rocm-pin-600` left by a previous run (failed or otherwise), then flushes the apt cache. This means the script is always safe to re-run after a failure.

**Repo setup:**

```
/etc/apt/sources.list.d/amdgpu.list
  → https://repo.radeon.com/amdgpu/{BUILD_NUMBER}/ubuntu {codename} main
  → Uses the AMDGPU build number (e.g. 30.30) — NOT the ROCm version string

/etc/apt/sources.list.d/rocm.list
  → https://repo.radeon.com/rocm/apt/{ROCM_VERSION} {codename} main
  → https://repo.radeon.com/graphics/{ROCM_VERSION}/ubuntu {codename} main
  → Uses the ROCm version string (e.g. 7.2)

/etc/apt/preferences.d/rocm-pin-600
  → Pins repo.radeon.com packages to priority 600
  → Prevents Ubuntu defaults from overriding AMD packages
```

GPG key stored at `/etc/apt/keyrings/rocm.gpg`.

### Step 8 — AMDGPU Driver + ROCm Stack
Installs `amdgpu-dkms` (kernel module, DKMS-managed), then the `rocm` meta-package (full userspace stack). Adds the current user to the `render` and `video` groups — required for GPU device access on all AMD GPUs. Group membership takes effect on next login.

### Step 9 — ROCm PATH Configuration
Writes `/etc/profile.d/rocm.sh`:
```bash
export PATH="/opt/rocm/bin:${PATH}"
export LD_LIBRARY_PATH="/opt/rocm/lib:${LD_LIBRARY_PATH:-}"
```
Also exports into the current shell session so `rocm-smi` and `rocminfo` are available immediately for the validation step.

### Step 9.5 — AI/ML Environment Configuration

This step auto-detects the installed GPU architecture using `rocminfo` and writes `PYTORCH_ROCM_ARCH` to `/etc/profile.d/rocm.sh`. The behaviour depends on whether the `amdgpu` kernel module is loaded at the time the script runs:

**Module loaded (second run after reboot, or GPU already active):**
```bash
# rocminfo is queried, arch(es) extracted and written automatically
export PYTORCH_ROCM_ARCH="gfx1201"           # single GPU
export PYTORCH_ROCM_ARCH="gfx1100;gfx1201"  # mixed multi-GPU node
```

**Module not loaded (first run on fresh install — normal):**
A placeholder is written with clear instructions. The user is prompted to either re-run the script after rebooting (at which point it will auto-detect and replace the placeholder), or set it manually:

```bash
# After reboot, detect your GPU arch:
rocminfo | grep -oP 'gfx[0-9]+' | sort -u

# Then update the placeholder:
sudo sed -i 's/PYTORCH_ROCM_ARCH=.*/PYTORCH_ROCM_ARCH="gfx1201"/' /etc/profile.d/rocm.sh
# Or just re-run the script -- it will auto-detect and set the correct value.
```

**Why `PYTORCH_ROCM_ARCH` matters:** The standard `pip install torch` gives a CUDA build. The ROCm PyTorch wheel compiles JIT kernels at runtime, and `PYTORCH_ROCM_ARCH` tells it which architecture(s) to target. Without this set correctly, PyTorch will either fail to find the GPU or produce slow/broken kernels.

**Other env vars written (commented out as reference):**

`HIP_VISIBLE_DEVICES` — restricts which GPUs a process can see. Unset means all GPUs visible. Override per-job at runtime: `HIP_VISIBLE_DEVICES=0,1 python train.py`.

`HSA_OVERRIDE_GFX_VERSION` — only needed if ROCm does not natively recognize your GPU (rare with ROCm 7.x on supported hardware). Uncomment and set to your GPU's gfx version string if required.

The step also prints post-reboot install commands for PyTorch, vLLM, and llama.cpp.

### Step 10 — rocm-bandwidth-test
Verifies `rocm-bandwidth-test` is present (included in the `rocm` meta-package). Primary post-install bandwidth validation tool, analogous to `nvbandwidth` on NVIDIA nodes.

### Step 11 — Repos
Clones or pulls `https://github.com/joeasycompute/infra.git` to `~/infra`.

### Step 12 — Post-install Validation
Checks: `rocm-smi` GPU count and product name, `rocminfo` detected GPU arch(es) (printed without asserting a specific expected arch), `amdgpu` DKMS build status, `render` group membership, `chrony` service state, `infra` repo presence. Most checks will be pending before the first reboot.

### Step 13 — Reboot Prompt
Offers reboot to load the `amdgpu` kernel module. In non-interactive mode, prints a reminder to reboot manually.

---

## Post-Reboot: Validation

```bash
# Confirm GPU(s) recognized
rocm-smi
rocminfo | grep "Marketing Name"

# Confirm arch detected (use this output to verify PYTORCH_ROCM_ARCH)
rocminfo | grep -oP 'gfx[0-9]+' | sort -u

# Confirm DKMS module loaded
dkms status | grep amdgpu
lsmod | grep amdgpu

# Bandwidth test
rocm-bandwidth-test -a
```

If `PYTORCH_ROCM_ARCH` was set to `PLACEHOLDER` during install (first run before reboot), update it now:
```bash
# Get your arch
ARCH=$(rocminfo | grep -oP 'gfx[0-9]+' | sort -u | tr '\n' ';' | sed 's/;$//')
echo "Detected: $ARCH"

# Update the profile
sudo sed -i "s/PYTORCH_ROCM_ARCH=.*/PYTORCH_ROCM_ARCH=\"${ARCH}\"/" /etc/profile.d/rocm.sh
source /etc/profile.d/rocm.sh

# Or simply re-run the script -- it will auto-detect and replace the placeholder
sudo bash ~/infra/install/base-install-amd.sh --rocm 7.2
```

---

## Post-Reboot: PyTorch Setup

```bash
# Option A: pip (system Python or venv)
pip install torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/rocm7.2

# Option B: AMD official Docker image (recommended for production)
docker pull rocm/pytorch:rocm7.2_ubuntu22.04_py3.10_pytorch_release_2.8.0

# Verify — ROCm intentionally surfaces AMD GPUs through torch.cuda
python3 -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"
```

### Other ROCm-native tools

```bash
# vLLM — picks up ROCm automatically when PYTORCH_ROCM_ARCH is set
pip install vllm

# llama.cpp — HIP backend (arch auto-detected from rocminfo)
ARCH=$(rocminfo | grep -oP 'gfx[0-9]+' | sort -u | tr '\n' ',' | sed 's/,$//')
cmake -B build -DGGML_HIP=ON -DAMDGPU_TARGETS="${ARCH}" ..
cmake --build build --config Release

# Ollama (ROCm-enabled build)
# Follow https://github.com/ollama/ollama — ROCm support is built-in
```

---

## Uninstall

The `--uninstall` path performs a full clean removal and restores the system to its pre-install state:

- Purges all `amdgpu`, `rocm`, `hip-*`, `hsa-*`, `miopen`, `rocblas`, and related packages
- Removes all `amdgpu` DKMS entries and built `.ko` files, rebuilds module map
- Removes `/opt/rocm`
- Removes `/etc/profile.d/rocm.sh` (PATH, LD_LIBRARY_PATH, PYTORCH_ROCM_ARCH, etc.)
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
| `/etc/apt/sources.list.d/amdgpu.list` | AMDGPU driver repo (build number URL) |
| `/etc/apt/sources.list.d/rocm.list` | ROCm software repo (version string URL) |
| `/etc/apt/preferences.d/rocm-pin-600` | AMD repo priority pin |
| `/etc/apt/keyrings/rocm.gpg` | AMD GPG signing key |
| `/opt/rocm/` | ROCm installation root |
| `/opt/rocm/bin/rocm-smi` | GPU status tool |
| `/opt/rocm/bin/rocminfo` | GPU topology and arch info |
| `/opt/rocm/bin/rocm-bandwidth-test` | Bandwidth test |
| `~/infra/` | joeasycompute/infra repo |

---

## Key Differences from base-install.sh (NVIDIA)

| Aspect | AMD (`base-install-amd.sh`) | NVIDIA (`base-install.sh`) |
|--------|----------------------------|-----------------------------|
| Driver package | `amdgpu-dkms` | `nvidia-dkms-{ver}-open` |
| Extra kernel pkg | `linux-modules-extra-$(uname -r)` required | Not required |
| Compute stack | `rocm` (single meta-package) | `cuda-toolkit` + `cudnn9` + `libnvidia-compute` |
| User groups | `render`, `video` required | Not required |
| PATH config | `/etc/profile.d/rocm.sh` | `/etc/profile.d/cuda.sh` |
| Install root | `/opt/rocm/` | `/usr/local/cuda/` |
| Version selector | `--rocm <7.2\|7.1>` | `--driver <575\|580\|590>` + `--cuda <12-9\|13>` |
| Repo URL scheme | Two separate schemes (ROCm version + AMDGPU build number) | Single CUDA keyring |
| Monitoring | `rocm-smi`, `rocminfo` | `nvidia-smi`, DCGM |
| Bandwidth test | `rocm-bandwidth-test` | `nvbandwidth` |
| ML arch env var | `PYTORCH_ROCM_ARCH` (auto-detected) | Not needed (CUDA auto-detects) |
| Kernel upper bound | Must be ≤ 6.8 (newer kernels break DKMS build) | No upper bound |

---

## Changelog

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-03-03 | Initial release (R9700-specific) |
| 1.1 | 2026-03-13 | Fixed `amdgpu.list` URL: AMDGPU build number (30.30) != ROCm version string (7.2) |
| 1.2 | 2026-03-14 | Stale repo cleanup on retry; kernel version check in preflight with per-distro fix guidance |
| 1.3 | 2026-03-14 | Added Step 9.5: ML environment config — `PYTORCH_ROCM_ARCH`, `HIP_VISIBLE_DEVICES`, `HSA_OVERRIDE_GFX_VERSION` reference, post-reboot PyTorch/vLLM/llama.cpp install commands |
| 2.0 | 2026-03-15 | Made script fully GPU-agnostic: removed all R9700/gfx1201 hardcoding; `PYTORCH_ROCM_ARCH` now auto-detected from `rocminfo` at install time, falls back to placeholder with clear update instructions when module not yet loaded |
