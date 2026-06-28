# gpu-power-limit.sh

Generates and installs a systemd service (`nvidia-runtime-policy.service`) that sets NVIDIA GPU power limits persistently at boot. Supports auto-detection of GPU model with built-in presets, per-node override, per-GPU overrides, and a safe dry-run mode.

---

## Requirements

- Ubuntu 22.04 / 24.04
- NVIDIA driver installed (`nvidia-smi` available at `/usr/bin/nvidia-smi` by default; override with `NVIDIA_SMI=/path/to/nvidia-smi` if needed)
- `systemd`
- `sudo` / root access for installation

---

## Quick Start

```bash
# Make executable
chmod +x install/gpu-power-limit.sh

# Preview what would be installed (no changes made)
./install/gpu-power-limit.sh --dry-run

# Auto-detect GPU, apply preset, install and start service
sudo ./install/gpu-power-limit.sh

# Force a specific wattage across all GPUs
sudo ./install/gpu-power-limit.sh --override 350

# Override individual GPU indices while keeping the preset for the rest
sudo ./install/gpu-power-limit.sh --gpu-limit 0:350 --gpu-limit 1:320
```

---

## Options

| Flag | Description |
|------|-------------|
| *(none)* | Auto-detect GPU model, apply preset, install service |
| `--dry-run` | Preview the generated service file and resolved power limit — no changes made |
| `--override WATTS` | Skip preset lookup and force the given wattage on all GPUs |
| `--gpu-limit INDEX:WATTS` | Override one GPU index with a specific wattage. Repeat for multiple GPUs. `INDEX=WATTS` is also accepted. |
| `--help` | Show usage and list of built-in presets |

---

## GPU Presets

Power limits are resolved automatically from the GPU model name reported by `nvidia-smi`. The first GPU (`-i 0`) is used for model detection — assumes a homogeneous node.

| GPU Model | Preset Power Limit |
|-----------|--------------------|
| RTX 5090  | 450W               |
| RTX 4090  | 300W               |
| H100      | 500W               |
| A100      | 300W               |
| A4000     | 140W               |
| *(no match)* | 300W (fallback, warns) |

If no preset matches, the script warns and falls back to `300W`. Use `--override` to set an explicit limit for unlisted models.

To add a new preset, edit the preset arrays near the top of the script:

```bash
GPU_PRESET_MODELS=("5090" "4090" "A100" "H100" "A4000" "3090")
GPU_PRESET_WATTS=(450 300 300 500 140 350)
```

The match is a substring check against the full GPU name, so `"4090"` will match `"NVIDIA GeForce RTX 4090"`.

---

## What Gets Installed

The script writes the following service file to `/etc/systemd/system/nvidia-runtime-policy.service`:

```ini
[Unit]
Description=NVIDIA runtime policy (persistence + power cap @ <WATTS>W)
After=multi-user.target systemd-udev-settle.service
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nvidia-runtime-policy.sh
TimeoutStartSec=360
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

The helper script waits for `/dev/nvidiactl` and `nvidia-smi -L` to become ready after boot before applying persistence mode and the requested power cap. This avoids the boot-order race where the service could otherwise be skipped if the driver is not ready yet.

When `--gpu-limit` is used, the helper applies persistence mode once, then enumerates GPU indices at boot and applies either the base power limit or the per-index override:

```bash
# Base limit is the detected preset, except GPU 0 and GPU 1 get explicit caps
sudo ./install/gpu-power-limit.sh --gpu-limit 0:350 --gpu-limit 1:320

# Base limit is 300W everywhere, except GPU 3 gets 250W
sudo ./install/gpu-power-limit.sh --override 300 --gpu-limit 3:250
```

Then runs:

```bash
systemctl daemon-reload
systemctl enable nvidia-runtime-policy.service
systemctl restart nvidia-runtime-policy.service
```

---

## Validation

Before writing anything, the script validates the resolved wattage for each GPU against that GPU's `power.min_limit` and `power.max_limit` as reported by `nvidia-smi`. If any GPU would reject its requested wattage, the script aborts without making changes.

```
[OK]    GPU 0: 300W ✓  (allowed range: 100W – 450W)
[OK]    GPU 1: 250W ✓  (allowed range: 100W – 450W)
```

---

## Examples

```bash
# Dry-run on a 4090 node — preview the 300W preset
./install/gpu-power-limit.sh --dry-run

# Install on a 5090 node — applies 450W preset automatically
sudo ./install/gpu-power-limit.sh

# Override to 250W regardless of GPU model
sudo ./install/gpu-power-limit.sh --override 250

# Dry-run with override — preview a custom wattage before committing
./install/gpu-power-limit.sh --dry-run --override 250

# Set GPU 0 to 350W and GPU 1 to 320W; all other GPUs use the preset/fallback
sudo ./install/gpu-power-limit.sh --gpu-limit 0:350 --gpu-limit 1:320

# Set a default of 300W, with GPU 3 capped lower
sudo ./install/gpu-power-limit.sh --override 300 --gpu-limit 3:250
```

---

## Managing the Service

```bash
# Check current status
systemctl status nvidia-runtime-policy.service

# View logs
journalctl -u nvidia-runtime-policy.service

# Verify live power limits
nvidia-smi --query-gpu=index,name,power.limit --format=csv

# Disable and remove
sudo systemctl disable --now nvidia-runtime-policy.service
sudo rm /etc/systemd/system/nvidia-runtime-policy.service
sudo systemctl daemon-reload
```

---

## Tested On

| Platform | Driver | GPUs |
|----------|--------|------|
| Ubuntu 22.04 | 575 / 580 / 595 / 610 | RTX 4090, RTX 5090, A100, H100, A4000 |
| Ubuntu 24.04 | 575 / 580 / 595 / 610 | RTX 4090, RTX 5090, A100, H100, A4000 |
