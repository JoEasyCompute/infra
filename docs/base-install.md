# base-install.sh

GPU node base installation script for vast.ai and production deployments.
Installs the full NVIDIA/CUDA stack on a fresh Ubuntu node by default, with an
optional `--no-gpu-stack` mode that skips the NVIDIA driver, CUDA toolkit,
DCGM, and gpu-burn install path while still setting up the general host tools.
The matching uninstall path restores the system to a clean OS state for
reprovisioning.

**Version:** 1.9  
**Supports:** Ubuntu 22.04 / 24.04 / 26.04 (x86_64)

---

## Requirements

| Requirement | Detail |
|---|---|
| OS | Ubuntu 22.04 (Jammy), 24.04 (Noble), or 26.04 (Resolute), x86_64 only |
| Disk space | 15 GB free on `/usr` |
| Access | User with passwordless `sudo` |
| Network | Reachable: `developer.download.nvidia.com`, `github.com` (NVIDIA repo only required when installing the GPU stack) |
| Secure Boot | Must be **disabled** in BIOS for the NVIDIA GPU stack path (DKMS modules won't load otherwise) |

---

## Quick Start

```bash
# Clone the repo (if not already present)
git clone https://github.com/joeasycompute/infra.git ~/infra
cd ~/infra/install

chmod +x base-install.sh nvidia-stack-hold.sh

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
  --driver  <575|580|595|610>        NVIDIA driver version (default: interactive prompt)
  --cuda    <12-9|13|13.3>           CUDA toolkit version  (default: interactive prompt)
  --yes                      Non-interactive mode, skip all prompts, use defaults
  --no-gpu-stack             Skip NVIDIA driver / CUDA toolkit / DCGM / gpu-burn install
  --freeze-gpu-stack         Hold the validated NVIDIA/CUDA packages after install
  --unfreeze-gpu-stack       Temporarily unhold NVIDIA/CUDA packages before install, then re-hold after validation
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
./base-install.sh --driver 595 --cuda 13.3
./base-install.sh --driver 610 --cuda 13.3
./base-install.sh --driver 575 --cuda 12-9

# Base host tooling only, skip NVIDIA driver/CUDA/DCGM/gpu-burn
./base-install.sh --no-gpu-stack
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

Ubuntu 26.04 is supported too; the script automatically maps it to the `ubuntu2604` NVIDIA repo codename.
If you use `--no-gpu-stack`, the NVIDIA repo / Secure Boot checks are skipped and the installer stops after the host tooling and general recovery setup.

### GPU fallback recovery policy

During install, `base-install.sh` also writes a managed GPU fallback policy:

- `/etc/systemd/system.conf`
  - `DefaultTimeoutStopSec=30s`
  - `DefaultTimeoutAbortSec=15s`
- `/etc/sysctl.d/99-gpu-fallback.conf`
  - `kernel.panic=10`
  - `kernel.panic_on_oops=1`
  - `kernel.hung_task_panic=1`
  - `kernel.hung_task_timeout_secs=120`

The systemd settings are wrapped in a managed block so reruns are idempotent and uninstall can remove only the installer-managed lines. The sysctl file is owned by root and applied with `sysctl --system`.

Operational effect:

- Shortens systemd service shutdown waits:
  - `DefaultTimeoutStopSec=30s` limits the default time systemd waits for services to stop cleanly.
  - `DefaultTimeoutAbortSec=15s` limits the default time allowed for abort/termination handling.
- Enables automatic reboot after severe kernel failure conditions:
  - `kernel.panic=10` reboots the node 10 seconds after a kernel panic.
  - `kernel.panic_on_oops=1` treats a kernel oops as fatal, causing a panic instead of trying to continue.
  - `kernel.hung_task_panic=1` panics the kernel when a hung task is detected.
  - `kernel.hung_task_timeout_secs=120` defines the hung-task threshold as 120 seconds.

This is intended for unattended GPU nodes where a wedged driver, kernel fault, or hung task is worse than an automatic reboot. It is a **host-wide** policy, not NVIDIA-only: kernel oops and hung-task conditions from non-GPU components can also trigger a panic/reboot. Operators should only use this behavior on nodes where automatic recovery is preferred over preserving a stuck system for live debugging.

This policy is a first-layer, in-band recovery aid. It can help when a NVIDIA driver failure turns into a kernel oops, panic, hung-task detection, or a userspace shutdown timeout. It is not guaranteed to recover every `GPU has fallen off the bus` case: if the kernel reboot path itself blocks while waiting on a disappeared PCIe GPU, the OS may still be unable to complete a warm reboot. In that condition, an out-of-band BMC/IPMI power cycle is the reliable recovery path because it does not depend on the wedged host OS.

For a last-resort in-band emergency reboot from the host console, use `install/force-reboot.sh --yes` as root. It syncs filesystems, remounts them read-only, then triggers a SysRq reboot. It defaults to dry-run unless `--yes` is supplied.

For manual out-of-band recovery, use `install/ipmi-power-cycle.sh` from an operator machine that can reach the BMC/IPMI network:

```bash
# Dry run: checks BMC reachability and chassis power status only
IPMI_PASS='redacted' ./install/ipmi-power-cycle.sh --host 192.0.2.50 --user ADMIN

# Destructive action: asks the BMC to power-cycle the chassis
IPMI_PASS='redacted' ./install/ipmi-power-cycle.sh --host 192.0.2.50 --user ADMIN --yes
```

The helper requires the BMC/IPMI address, not the host OS address. It reads the password from `IPMI_PASS` or `IPMI_PASSWORD`, or prompts securely when run interactively. It refuses to power cycle unless `--yes` is supplied.

Uninstall removes the managed systemd block and `/etc/sysctl.d/99-gpu-fallback.conf`, then reloads systemd/sysctl state where possible.

### Freeze or update the NVIDIA stack

After a successful validation run, you can freeze the validated GPU stack:

```bash
sudo ./nvidia-stack-hold.sh --hold
sudo ./nvidia-stack-hold.sh --status
```

To temporarily update a held node, rerun `base-install.sh` with `--unfreeze-gpu-stack`. That removes the hold first, installs the requested driver/CUDA versions, validates the node, and then re-holds the resulting stack.

If the script detects a held NVIDIA/CUDA stack on startup, it will warn and point you to `nvidia-stack-hold.sh --unhold` for the maintenance window path.

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
| 595 | 13.3 | cudnn9-cuda-13-3 | Current |
| 610 | 13.3 | cudnn9-cuda-13-3 | Latest |

> **Note:** Driver 575 + CUDA 13.x is a known incompatible combination.
> The script will warn and prompt before continuing if this is selected.
>
> **Note:** `nvidia-utils-575` is installed explicitly for driver 575 to provide
> `nvidia-smi` and related tools. Drivers 580+ include these automatically
> through their metapackage and do not need it.

---

## What Gets Installed

### Base system packages
| Package | Purpose |
|---|---|
| `build-essential`, `cmake`, `dkms` | Compiler toolchain and kernel module build system |
| `gcc-11`, `g++-11`, `gcc-12`, `g++-12` | GCC versions required for NVIDIA driver compilation |
| `linux-headers-$(uname -r)`, `linux-headers-generic` | Kernel headers — required for DKMS to build `nvidia.ko` |
| `python3`, `python3-pip`, `python3-venv` | Python runtime |
| `uv` | Python package/project manager installed to `/usr/local/bin` |
| `Benchmark Python 3.11 runtime` | Managed via `uv python install 3.11` into `/opt/infra/python`; exposed through `/etc/profile.d/infra-python.sh` for the PyTorch benchmark lane |
| `fzf`, `jq`, `ripgrep`, `fd-find`, `bat` | Common operator CLI search/inspection tools (`fd` and `bat` compatibility symlinks are created when needed) |
| `yq` | Official GitHub release binary installed to `/usr/local/bin/yq` (not via apt) |
| shell aliases | Repo `.aliases` copied to `~/.aliases`, sourced by bash/zsh, and converted to `~/.aliases.fish` for fish |
| SSH / sudo access | Adds the repo SSH key to `~/.ssh/authorized_keys` and a passwordless sudoers drop-in for the target user |
| `git` | Source control |
| `chrony` | NTP time synchronisation (enabled as a service) |
| `nvme-cli` | NVMe drive management and health checks |
| `smartmontools` | SMART disk health monitoring (also used by `disktest.sh`) |
| `ipmitool` | IPMI/BMC hardware management |
| `pciutils` | PCIe device inspection (`lspci`) |
| `usbutils` | USB device inspection (`lsusb`) |
| `iproute2`, `util-linux`, `dmidecode`, `lshw` | System hardware introspection |
| `lvm2`, `mdadm` | LVM and software RAID management (also used by `disktest.sh`) |
| `lsof`, `ioping` | Open file detection and disk latency checking (also used by `disktest.sh`) |
| `rsync`, `xorriso`, `squashfs-tools`, `grub-common`, `grub-pc-bin`, `grub-efi-amd64-bin` | Host-side live-image / ISO build tooling used by `install/rebuild-gpu-livefs.sh` and `install/build-gpu-liveiso.sh` |
| `bpytop` | Resource monitor |
| `mokutil` | Secure Boot state inspection |
| `stress-ng` | System stress testing and burn-in workloads |
| `fio` | Disk I/O benchmarking and validation |
| `lm-sensors` | Hardware sensor and temperature monitoring |
| `ethtool` | NIC feature, link, and offload inspection |
| `iperf3` | Network bandwidth testing (also used by `network-test.sh`) |

`uv` is installed by `base-install.sh` via Astral's standalone installer and
placed in `/usr/local/bin` so it is available on the system PATH without
modifying shell profiles.
`base-install.sh` also uses `uv` to provision and refresh a benchmark-safe
Python 3.11 runtime for the PyTorch lane, keeping the distro's default
`python3` unchanged.
`fd` and `bat` compatibility symlinks are created when the Ubuntu packages
expose the commands as `fdfind` and `batcat`.

### NVIDIA / CUDA stack
| Package | Purpose |
|---|---|
| `cuda-toolkit-<version>` | CUDA compiler (`nvcc`), libraries, and development tools |
| `libnvidia-compute-<version>` | NVIDIA compute runtime |
| `nvidia-dkms-<version>-open` | Open-source NVIDIA kernel module (DKMS-managed) |
| `nvidia-utils-575` | `nvidia-smi`, `nvidia-debugdump`, and userspace tools — **driver 575 only** (580+ include these via their metapackage) |
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
| Shell aliases | `~/.aliases` is installed from repo root; `~/.bashrc`, `~/.zshrc`, and `~/.config/fish/config.fish` are updated to source the managed alias files |
| SSH / sudo access | `~/.ssh/authorized_keys` updated with the repo key; `/etc/sudoers.d/99-infra-<user>` grants passwordless sudo if the user did not already have it |
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
install_python_tooling  — Installs uv via Astral installer
install_benchmark_python_runtime — Installs benchmark Python 3.11 via uv and writes /etc/profile.d/infra-python.sh
install_user_access     — Adds SSH authorized key and passwordless sudoers for the target user
install_shell_aliases   — Copies repo .aliases and wires bash/zsh/fish startup files
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
- The target user’s SSH key and sudoers drop-in are re-applied if missing, and the SSH file permissions are refreshed
- Shell alias blocks in `~/.bashrc`, `~/.zshrc`, and `~/.config/fish/config.fish` are refreshed from the repo on each run

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
| 9.5 | Managed alias blocks removed from `~/.aliases`, `~/.bashrc`, `~/.zshrc`, `~/.config/fish/config.fish`, and `~/.aliases.fish` |
| 9.6 | Managed SSH authorized key entry removed and the passwordless sudoers drop-in deleted |
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

`base-install.sh` pre-installs the disk-validation dependencies used by
`disktest.sh`:

| Package | Installed by |
|---|---|
| `smartmontools` | `base-install.sh` |
| `nvme-cli` | `base-install.sh` |
| `ioping` | `base-install.sh` |
| `lvm2`, `mdadm`, `lsof` | `base-install.sh` |
| `pciutils` | `base-install.sh` |
| `util-linux` | `base-install.sh` |
| `python3` | `base-install.sh` |
| benchmark Python 3.11 runtime | `base-install.sh` |
| `uv` | `base-install.sh` |
| `fio` | `base-install.sh` |

This means `disktest.sh` can be run immediately after a reboot following
`base-install.sh` without any additional dependency setup.

---

## File Locations Reference

| Path | Purpose |
|---|---|
| `/var/log/gpu-node-install/` | Timestamped install/uninstall logs |
| `/etc/profile.d/cuda.sh` | CUDA PATH for all users (all login shells) |
| `/etc/profile.d/infra-python.sh` | Benchmark Python 3.11 PATH/runtime exports for the PyTorch lane |
| `/etc/systemd/system.conf` | Managed systemd stop/abort timeout block for GPU fallback recovery |
| `/etc/sysctl.d/99-gpu-fallback.conf` | Kernel panic / hung-task fallback policy for GPU nodes |
| `/opt/infra/python/` | Benchmark Python 3.11 installation root managed by `uv` |
| `~/.aliases` | Bash alias file copied from repo root by `base-install.sh` |
| `~/.aliases.fish` | Fish wrapper file generated from `~/.aliases` and sourced by `config.fish` |
| `~/.ssh/authorized_keys` | Target user authorized key file updated with the repo SSH key |
| `/etc/sudoers.d/99-infra-<user>` | Passwordless sudo drop-in for the target user if not already present |
| `/usr/share/keyrings/cuda-archive-keyring.gpg` | NVIDIA apt repo signing key |
| `/etc/apt/sources.list.d/cuda-*.list` | NVIDIA CUDA apt source |
| `/etc/apt/sources.list.d/*graphics-drivers*` | graphics-drivers PPA source |
| `~/infra/` | Infrastructure tooling repo |
| `~/gpu-burn/` | GPU burn test repo and binary |
