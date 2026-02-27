# base-install.sh

GPU node base installation script for vast.ai and production deployments.
Installs the full NVIDIA/CUDA stack on a fresh Ubuntu node, with a matching
uninstall path that restores the system to a clean OS state for reprovisioning.

**Version:** 1.8  
**Supports:** Ubuntu 22.04 / 24.04 (x86_64)

---

## Requirements

| Requirement | Detail |
|---|---|
| OS | Ubuntu 22.04 (Jammy) or 24.04 (Noble), x86_64 only |
| Disk space | 15 GB free on `/usr` |
| Access | User with passwordless `sudo` |
| Network | Reachable: `developer.download.nvidia.com`, `github.com` |
| Secure Boot | Must be **disabled** in BIOS (DKMS modules won't load otherwise) |

---

## Quick Start

```bash
# Clone the repo (if not already present)
git clone https://github.com/joeasycompute/infra.git ~/infra
cd ~/infra/install

chmod +x base-install.sh

# Interactive install — recommended for first-time use
./base-install.sh

# Non-interactive install with defaults (driver 580 + CUDA 12-9)
./base-install.sh --yes

# Uninstall / reprovision
./base-install.sh --uninstall
```

---

## Usage

```
./base-install.sh [OPTIONS]

Options:
  --driver  <575|580|590>    NVIDIA driver version (default: interactive prompt)
  --cuda    <12-9|13>        CUDA toolkit version  (default: interactive prompt)
  --yes                      Non-interactive mode, skip all prompts, use defaults
  --uninstall                Full clean removal — restores system to post-OS-install state
  -h, --help                 Show help
```

---

## Examples

### Interactive install (recommended)
```bash
./base-install.sh
```
Walks through driver and CUDA version selection with a confirmation summary
before touching the system.

### Specify versions explicitly
```bash
./base-install.sh --driver 580 --cuda 12-9
./base-install.sh --driver 590 --cuda 13
./base-install.sh --driver 575 --cuda 12-9
```

### Non-interactive / CI / automation
```bash
# Uses defaults: driver 580 + CUDA 12-9
./base-install.sh --yes

# Explicit versions, no prompts
./base-install.sh --driver 580 --cuda 12-9 --yes
```
Useful for Ansible playbooks, Terraform provisioners, or scripted deployments
across a fleet of nodes.

### Uninstall (interactive)
```bash
./base-install.sh --uninstall
```
Shows a summary of everything that will be removed, prompts for confirmation,
optionally removes the `gpu-burn` and `infra` repos, then offers a reboot.

### Uninstall (non-interactive)
```bash
./base-install.sh --uninstall --yes
```
Runs the full removal silently with no prompts. Repos are preserved. Reboot
must be done manually afterwards.

---

## Version Matrix

| Driver | CUDA | cuDNN | Status |
|--------|------|-------|--------|
| 575 | 12-9 | cudnn9-cuda-12 | Stable |
| 580 | 12-9 | cudnn9-cuda-12 | **Recommended** |
| 580 | 13 | cudnn9-cuda-13 | Latest |
| 590 | 12-9 | cudnn9-cuda-12 | Beta |
| 590 | 13 | cudnn9-cuda-13 | Beta / Latest |

> **Note:** Driver 575 + CUDA 13 is a known incompatible combination.
> The script will warn and prompt before continuing if this is selected.

---

## What Gets Installed

### Base system packages
| Package | Purpose |
|---|---|
| `build-essential`, `cmake`, `dkms` | Compiler toolchain and kernel module build system |
| `gcc-11`, `g++-11`, `gcc-12`, `g++-12` | GCC versions required for NVIDIA driver compilation |
| `linux-headers-$(uname -r)`, `linux-headers-generic` | Kernel headers — required for DKMS to build `nvidia.ko` |
| `python3`, `python3-pip`, `python3-venv` | Python runtime |
| `git` | Source control |
| `chrony` | NTP time synchronisation (enabled as a service) |
| `nvme-cli` | NVMe drive management and health checks |
| `smartmontools` | SMART disk health monitoring (also used by `disktest.sh`) |
| `ipmitool` | IPMI/BMC hardware management |
| `pciutils` | PCIe device inspection (`lspci`) |
| `iproute2`, `util-linux`, `dmidecode`, `lshw` | System hardware introspection |
| `lvm2`, `mdadm` | LVM and software RAID management (also used by `disktest.sh`) |
| `lsof`, `ioping` | Open file detection and disk latency checking (also used by `disktest.sh`) |
| `bpytop` | Resource monitor |
| `mokutil` | Secure Boot state inspection |

### NVIDIA / CUDA stack
| Package | Purpose |
|---|---|
| `cuda-toolkit-<version>` | CUDA compiler (`nvcc`), libraries, and development tools |
| `libnvidia-compute-<version>` | NVIDIA compute runtime |
| `nvidia-dkms-<version>-open` | Open-source NVIDIA kernel module (DKMS-managed) |
| `nvidia-utils-<version>` | `nvidia-smi`, `nvidia-debugdump`, and userspace tools |
| `cudnn9-cuda-<major>` | cuDNN deep learning primitives |
| `nvtop` | GPU process monitor (htop for GPUs) |
| `datacenter-gpu-manager-4-cuda<major>` | DCGM health and telemetry service |

### Repos cloned
| Repo | Location | Purpose |
|---|---|---|
| `joeasycompute/infra` | `~/infra` | Infrastructure tooling and test scripts |
| `wilicc/gpu-burn` | `~/gpu-burn` | GPU stress test — built automatically if `nvcc` is available |

### System configuration
| Change | Detail |
|---|---|
| GCC alternatives | `gcc-12` set as default via `update-alternatives` (priority 12 > 11) |
| CUDA keyring | `cuda-keyring_1.1-1_all.deb` installed to authenticate NVIDIA apt repo |
| CUDA PATH | `/etc/profile.d/cuda.sh` written — adds `/usr/local/cuda/bin` and `lib64` for all users |
| DCGM service | `nvidia-dcgm` enabled and started |
| Chrony service | `chrony` enabled and started for NTP sync |

---

## Installation Flow

```
detect_ubuntu          — Reads /etc/os-release, maps to NVIDIA repo codename
preflight_checks       — Sudo, arch, disk space, network, Secure Boot, existing packages
select_driver_version  — Interactive menu or --driver arg
select_cuda_version    — Interactive menu or --cuda arg
validate_combination   — Warns on known-incompatible combinations
confirm_install        — Summary box + final y/n prompt (skipped with --yes)
install_base_packages  — Bootstrap → PPA → kernel headers → base packages
configure_gcc_alts     — update-alternatives for gcc-11/12
install_cuda_keyring   — Downloads and installs NVIDIA apt signing key
install_nvidia_stack   — Driver + CUDA + cuDNN + nvidia-utils + nvtop
configure_cuda_path    — Writes /etc/profile.d/cuda.sh
install_dcgm           — Installs and starts datacenter-gpu-manager
setup_repos            — Clones infra + gpu-burn, builds gpu-burn if nvcc available
validate_install       — Checks nvidia-smi, nvcc, dcgm, chrony, gpu-burn
offer_reboot           — Prompts to reboot (required to load NVIDIA kernel module)
```

---

## Logging

Every run writes a timestamped log to `/var/log/gpu-node-install/`:

```
/var/log/gpu-node-install/install-20260224-141142.log
```

Both stdout and stderr are captured. On a failed run, check the log for the
exact command and error that caused the failure. The log file path is always
printed at the top of the run and again in the final summary.

```bash
# View the most recent log
ls -lt /var/log/gpu-node-install/ | head -5
cat /var/log/gpu-node-install/install-<timestamp>.log
```

---

## Post-Install Steps

After the script completes, a reboot is required to load the NVIDIA kernel module:

```bash
sudo reboot
```

After rebooting, verify the installation:

```bash
# Check driver and CUDA version
nvidia-smi

# Check compiler
nvcc --version

# Check GPU count and names
nvidia-smi --query-gpu=index,name,driver_version --format=csv

# Check DCGM service
sudo systemctl status nvidia-dcgm

# Run a quick GPU burn test
cd ~/gpu-burn
./gpu_burn 60
```

If `nvcc` is not in PATH after reboot, source the profile manually:

```bash
source /etc/profile.d/cuda.sh
# Or log out and back in
```

---

## Re-running the Script

The script is **idempotent** — safe to re-run on an already provisioned node:

- `apt-get install` skips already-installed packages
- CUDA keyring install is skipped if `/usr/share/keyrings/cuda-archive-keyring.gpg` already exists
- `git clone` is replaced with `git pull --ff-only` if the repo directory already exists
- GCC `update-alternatives` entries are safe to re-register

---

## Uninstall — Full Reprovision Cleanup

`--uninstall` restores the system to the state it was in immediately after
OS installation. The 15-step removal sequence covers every artifact left by
the install:

| Step | What is removed |
|------|----------------|
| 1 | `nvidia-dcgm` and `nvidia-persistenced` services stopped and disabled |
| 2 | All `nvidia*`, `cuda*`, `cudnn*`, `dcgm*`, `smartmontools`, `ioping` packages purged |
| 3 | DKMS entries explicitly removed (`dkms remove --all`) |
| 4 | Built `.ko` kernel module files deleted from `/lib/modules/`, `depmod -a` run |
| 5 | `/etc/modprobe.d/nvidia*.conf` and `blacklist-nouveau.conf` removed |
| 6 | `update-initramfs -u -k all` — initramfs rebuilt without NVIDIA/nouveau blacklist |
| 7 | Nouveau driver re-enabled (blacklist entries cleared, `modprobe nouveau` attempted) |
| 8 | `/etc/ld.so.conf.d/cuda*.conf` removed, `ldconfig` updated |
| 9 | `/etc/profile.d/cuda.sh` removed, current session PATH cleaned |
| 10 | `cuda-keyring` package purged, `.gpg` key and apt source lists removed |
| 11 | `graphics-drivers` PPA removed |
| 12 | GCC `update-alternatives` entries for gcc-11/12 cleared |
| 13 | `gpu-burn` and `infra` repos — optionally removed (prompted interactively) |
| 14 | `apt autoremove` + `apt update` |
| 15 | Verification pass — checks packages, DKMS, PATH, modprobe.d all clean |

> **Note:** `lvm2`, `mdadm`, and `lsof` are deliberately **not** removed during
> uninstall as they are general system utilities that may be needed by other
> components on the node.

After uninstall, **reboot before reprovisioning**:

```bash
sudo reboot
# Then reprovision:
./base-install.sh --driver 580 --cuda 12-9
```

---

## Troubleshooting

### Script exits silently after confirmation prompt
Check the log file — the most common cause is `apt-get update` failing due to
a locked apt database (another process running) or a stale PPA:

```bash
cat /var/log/gpu-node-install/install-<timestamp>.log | tail -50
sudo lsof /var/lib/dpkg/lock-frontend   # check for apt lock
```

### `nvidia-smi: command not found` after reboot
The `nvidia-utils-<version>` package may not have installed. Check:

```bash
dpkg -l | grep nvidia-utils
# If missing:
sudo apt-get install nvidia-utils-580   # adjust version
```

### DKMS build failed — no kernel module after reboot
Check that kernel headers were installed for the running kernel:

```bash
uname -r
dpkg -l | grep "linux-headers-$(uname -r)"
# If missing:
sudo apt-get install "linux-headers-$(uname -r)"
sudo dkms autoinstall
```

### `nvcc: command not found` after reboot
The CUDA PATH profile was not sourced. Either log out/in or:

```bash
source /etc/profile.d/cuda.sh
nvcc --version
```

### Secure Boot blocks driver loading
After install, the NVIDIA DKMS module must be signed or Secure Boot must be
disabled. Check:

```bash
mokutil --sb-state       # should say "SecureBoot disabled"
dmesg | grep -i "nvidia\|secure\|module"
```
Disable Secure Boot in BIOS/UEFI firmware settings and reboot.

### DCGM not starting
DCGM requires `nvidia-smi` to be operational (driver loaded). If the node just
had drivers installed, reboot first, then:

```bash
sudo systemctl start nvidia-dcgm
sudo systemctl status nvidia-dcgm
```

Or re-run the script after reboot — it will detect `nvidia-smi` and install
DCGM at that point:

```bash
./base-install.sh --driver 580 --cuda 12-9 --yes
```

---

## Integration with disktest.sh

`base-install.sh` pre-installs all packages needed by `disktest.sh` except
`fio`, which `disktest.sh` auto-installs on first run:

| Package | Installed by |
|---|---|
| `smartmontools` | `base-install.sh` |
| `nvme-cli` | `base-install.sh` |
| `ioping` | `base-install.sh` |
| `lvm2`, `mdadm`, `lsof` | `base-install.sh` |
| `pciutils` | `base-install.sh` |
| `util-linux` | `base-install.sh` |
| `python3` | `base-install.sh` |
| `fio` | `disktest.sh` (auto-installs) |

This means `disktest.sh` can be run immediately after a reboot following
`base-install.sh` without any additional dependency setup.

---

## File Locations Reference

| Path | Purpose |
|---|---|
| `/var/log/gpu-node-install/` | Timestamped install/uninstall logs |
| `/etc/profile.d/cuda.sh` | CUDA PATH for all users (all login shells) |
| `/usr/share/keyrings/cuda-archive-keyring.gpg` | NVIDIA apt repo signing key |
| `/etc/apt/sources.list.d/cuda-*.list` | NVIDIA CUDA apt source |
| `/etc/apt/sources.list.d/*graphics-drivers*` | graphics-drivers PPA source |
| `~/infra/` | Infrastructure tooling repo |
| `~/gpu-burn/` | GPU burn test repo and binary |
