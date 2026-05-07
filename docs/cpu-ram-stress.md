# cpu-ram-stress.sh — CPU + RAM Isolation Stress

Standalone `stress-ng` wrapper for isolating host-side stability issues away
from GPU workloads.

Use this when you want to answer:

- does the system remain stable under heavy CPU load?
- does the system remain stable under heavy memory pressure?
- are failures still present when GPUs are not involved?

---

## What It Does

Runs `stress-ng` with:

- all CPU workers by default
- VM/memory workers by default
- a memory budget that leaves headroom for the OS
- a configurable runtime in minutes

The script prints a log file path, system RAM sizing, chosen worker counts, and
the final `stress-ng` exit code.

If `stress-ng` is missing, the script can auto-install it when run as root unless
`--no-install` is used.

---

## Usage

```bash
./test/cpu-ram-stress.sh [OPTIONS]
```

### Common options

| Option | Default | Description |
|---|---|---|
| `--minutes MIN` | `5` | Run duration in minutes |
| `--seconds SEC` | derived from minutes | Override duration in seconds |
| `--cpu-workers N` | online CPU count | Number of CPU stress workers |
| `--vm-workers N` | `2` | Number of VM / RAM stress workers |
| `--reserve-gb GB` | max(4 GiB, 10% of RAM) | RAM left free for the OS |
| `--log-dir DIR` | `/tmp/cpu_ram_stress_*` | Log output directory |
| `--no-install` | off | Do not auto-install `stress-ng` if missing |

---

## Examples

```bash
sudo ./test/cpu-ram-stress.sh
sudo ./test/cpu-ram-stress.sh --minutes 15
sudo ./test/cpu-ram-stress.sh --cpu-workers 8 --vm-workers 4 --reserve-gb 6
```

---

## Notes

- This script is intentionally GPU-free.
- It is useful when you want to separate CPU/RAM instability from GPU
  temperature, power, or driver issues.
- For whole-node maximum-load testing, use `test/fulltest.sh node-stress`.
