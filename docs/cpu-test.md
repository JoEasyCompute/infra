# cpu-test.sh — Single-CPU Stress Tester

`test/cpu-test.sh` is a focused `stress-ng` wrapper for exercising one logical
CPU at a time. It is meant for isolating CPU-side instability from GPU, disk,
and network workloads.

Use it when you want to answer questions like:

- does one logical CPU or socket show instability under load?
- is a failure reproducible without GPUs involved?
- does temperature logging correlate with a specific CPU or socket?

---

## What It Does

The script:

- detects the total logical CPU count with `nproc --all`
- detects socket count with `lscpu`
- runs `stress-ng` on one logical CPU at a time using `--taskset`
- supports per-socket ranges or a sequential all-CPU pass
- optionally logs temperatures with `sensors` and `--tz`
- writes logs and progress into a per-run directory under `/tmp`
- can be pointed at an explicit run directory with `--run-dir` if you want to
  inspect or resume the same run later

The script requires `stress-ng` to be installed already. It does not auto-install
dependencies.

---

## Usage

```bash
./test/cpu-test.sh [OPTIONS]
```

### Options

| Option | Default | Description |
|---|---|---|
| `--mode <mode>` | `sequential` | `sequential`, `socket0`, or `socket1` |
| `--time <seconds>` | `60` | Stress duration per logical CPU |
| `--method <name>` | `matrixprod` | `stress-ng` CPU method, such as `matrixprod` or `fft` |
| `--run-dir <path>` | auto-created under `/tmp` | Directory for the log transcript and resume file |
| `--temp` | off | Enable temperature logging with `sensors` and `--tz` |
| `-h, --help` | — | Show help and exit |

---

## Modes

| Mode | Behavior |
|---|---|
| `sequential` | Iterates from CPU 0 to the last logical CPU |
| `socket0` | Runs only the first socket’s logical CPU range |
| `socket1` | Runs only the second socket’s logical CPU range |

The script computes the socket boundaries from `nproc` and `lscpu` output.

---

## Examples

```bash
# Run all logical CPUs sequentially
sudo ./test/cpu-test.sh --mode sequential

# Stress only the first socket for 45 seconds per logical CPU
sudo ./test/cpu-test.sh --mode socket0 --time 45

# Use a different stress-ng method and enable temperature snapshots
sudo ./test/cpu-test.sh --mode socket1 --method fft --temp
```

---

## Logs and Run State

Each run gets its own directory, by default under `/tmp`, containing:

- `stress_test_log.txt` — console transcript
- `stress_progress.txt` — last CPU index processed

If you want to reuse the same directory for a later pass, supply
`--run-dir /path/to/existing-run-dir`.

---

## Notes

- This script is CPU-focused and GPU-free.
- It is useful for isolating a bad core, socket, or thermal issue.
- For combined host-wide stress, use `test/cpu-ram-stress.sh` or
  `test/fulltest.sh --node-stress` once GPU load should be included too.
- The script expects `stress-ng` to be present; install it via
  `install/base-install.sh` if needed.
