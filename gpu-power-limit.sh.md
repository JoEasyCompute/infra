# gpu-power-limit.sh

Generates and installs a systemd service (`nvidia-runtime-policy.service`) that sets NVIDIA GPU power limits persistently at boot. Supports auto-detection of GPU model with built-in presets, per-node override, and a safe dry-run mode.

---

## Requirements

- Ubuntu 22.04 / 24.04
- NVIDIA driver installed (`nvidia-smi` available at `/usr/bin/nvidia-smi`)
- `systemd`
- `sudo` / root access for installation

---

## Quick Start

```bash
# Make executable
chmod +x gpu-power-limit.sh

# Preview what would be installed (no changes made)
./gpu-power-limit.sh --dry-run

# Auto-detect GPU, apply preset, install and start service
sudo ./gpu-power-limit.sh

# Force a specific wattage across all GPUs
sudo ./gpu-power-limit.sh --override 350
```

---

## Options

| Flag | Description |
|------|-------------|
| *(none)* | Auto-detect GPU model, apply preset, install service |
| `--dry-run` | Preview the generated service file and resolved power limit — no changes made |
| `--override WATTS` | Skip preset lookup and force the given wattage on all GPUs |
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

To add a new preset, edit the `GPU_PRESETS` associative array near the top of the script:

```bash
declare -A GPU_PRESETS=(
    ["5090"]=450
    ["4090"]=300
    ["H100"]=500
    ["A100"]=300
    ["A4000"]=140
    ["3090"]=350   # ← add new entries here
)
```

The match is a substring check against the full GPU name, so `"4090"` will match `"NVIDIA GeForce RTX 4090"`.

---

## What Gets Installed

The script writes the following service file to `/etc/systemd/system/nvidia-runtime-policy.service`:

```ini
[Unit]
Description=NVIDIA runtime policy (persistence + power cap @ <WATTS>W)
After=multi-user.target
ConditionPathExists=/dev/nvidiactl

[Service]
Type=oneshot
ExecStart=/usr/bin/nvidia-smi -pm 1
ExecStart=/usr/bin/nvidia-smi -pl <WATTS>
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Then runs:

```bash
systemctl daemon-reload
systemctl enable nvidia-runtime-policy.service
systemctl restart nvidia-runtime-policy.service
```

---

## Validation

Before writing anything, the script validates the resolved wattage against each GPU's `power.min_limit` and `power.max_limit` as reported by `nvidia-smi`. If any GPU would reject the requested wattage, the script aborts without making changes.

```
[OK]    GPU 0: 300W ✓  (allowed range: 100W – 450W)
[OK]    GPU 1: 300W ✓  (allowed range: 100W – 450W)
```

---

## Examples

```bash
# Dry-run on a 4090 node — preview the 300W preset
./gpu-power-limit.sh --dry-run

# Install on a 5090 node — applies 450W preset automatically
sudo ./gpu-power-limit.sh

# Override to 250W regardless of GPU model
sudo ./gpu-power-limit.sh --override 250

# Dry-run with override — preview a custom wattage before committing
./gpu-power-limit.sh --dry-run --override 250
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
| Ubuntu 22.04 | 575 / 580 / 590 | RTX 4090, RTX 5090, A100, H100, A4000 |
| Ubuntu 24.04 | 575 / 580 / 590 | RTX 4090, RTX 5090, A100, H100, A4000 |
