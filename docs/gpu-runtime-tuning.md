# NVIDIA GPU Runtime Tuning

This page covers two operator utilities for live NVIDIA runtime clock tuning:

- `install/pearl-5090-tune.sh`
- `install/gpu-setting-reset.sh`

These scripts apply or remove runtime `nvidia-smi` settings. They are intended for manual host operation after the NVIDIA driver is installed and `nvidia-smi` can enumerate GPUs.

For persistent boot-time power policy, use `install/gpu-power-limit.sh` instead. That script installs `nvidia-runtime-policy.service` and reapplies power limits after reboot.

## Pearl RTX 5090 Tune

`install/pearl-5090-tune.sh` applies the Pearl RTX 5090 runtime profile:

```text
persistence mode: enabled
power limit:      400W
graphics clock:   2490MHz
memory clock:     7000MHz
```

The script refuses to run on non-5090 GPUs unless `--force` is passed. It validates the requested power limit against the min/max range reported by `nvidia-smi` before applying settings.

```bash
# Apply the default Pearl 5090 profile to all RTX 5090 GPUs
sudo ./install/pearl-5090-tune.sh

# Tune only selected GPU indices
sudo ./install/pearl-5090-tune.sh --gpu 0,1

# Preview commands without applying changes
./install/pearl-5090-tune.sh --dry-run --gpu 2

# Override the default profile values
sudo ./install/pearl-5090-tune.sh --power-limit 380 --gpu-clock 2450 --memory-clock 7000
```

The power-limit command is treated as required. Graphics and memory clock locks are reported as warnings if the current driver or GPU does not support that lock operation.

## Reset Clock Locks

`install/gpu-setting-reset.sh` removes graphics and memory clock locks from all NVIDIA GPUs, or from selected GPU indices.

```bash
# Reset all GPU and memory clock locks
sudo ./install/gpu-setting-reset.sh

# Reset only selected GPU indices
sudo ./install/gpu-setting-reset.sh --gpu 0,1

# Preview reset commands
./install/gpu-setting-reset.sh --dry-run --gpu 2
```

The reset script does not disable persistence mode and does not remove systemd services. If `install/gpu-power-limit.sh` installed `nvidia-runtime-policy.service`, that service may still reapply power limits at boot.

## Common Options

| Option | Script | Description |
|---|---|---|
| `--gpu LIST` | both | Comma-separated GPU indices, for example `0` or `0,2,3` |
| `--dry-run` | both | Print `nvidia-smi` commands without applying changes |
| `NVIDIA_SMI=/path/to/nvidia-smi` | both | Override the default `/usr/bin/nvidia-smi` path |
| `--force` | Pearl tune only | Allow the Pearl profile on GPUs not reported as RTX 5090 |

## Verification

After applying or resetting runtime settings, inspect the live GPU state:

```bash
nvidia-smi --query-gpu=index,name,power.limit,clocks.current.graphics,clocks.current.memory --format=csv
nvidia-smi -q -d CLOCK
```

If a setting does not stick, check the driver logs and whether another service or workload is changing GPU policy:

```bash
journalctl -k -n 100 --no-pager
systemctl status nvidia-runtime-policy.service --no-pager
```
