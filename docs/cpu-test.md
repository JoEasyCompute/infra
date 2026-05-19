# cpu-test.sh — CPU Socket Stress Tester

`test/cpu-test.sh` is a focused `stress-ng` wrapper that supports two target
granularities:

- **socket** — one physical CPU/socket at a time using **all logical threads on that socket at once**
- **thread** — one logical CPU/thread target at a time

This is meant for isolating CPU-package instability from GPU, disk, and network
workloads.

Use it when you want to answer questions like:

- does CPU socket 0 or socket 1 fail under full local load?
- can I identify which physical CPU/package is unstable?
- if the machine hangs or powers off, which socket was being tested?
- how do I clear the prior resume/status markers before re-testing?

---

## What It Does

The script:

- detects total logical CPUs with `nproc --all`
- detects socket topology with `lscpu -p=CPU,SOCKET`
- builds a logical-CPU set for each detected socket
- runs `stress-ng` either:
  - against **all logical threads for one socket at a time**
  - or against **one logical CPU/thread target at a time**
- supports:
  - `sequential` — test each socket in order
  - `socket0` — test only CPU/socket 0
  - `socket1` — test only CPU/socket 1
- defaults to `--granularity socket`
- supports `--granularity thread` to retain the old individual logical CPU mode
- optionally logs temperatures with `sensors` and `--tz`
- writes run state into a per-run directory under `/var/tmp` by default
- keeps a durable summary and progress marker so a crash/reboot still leaves a
  useful checkpoint
- supports `--status` so you can inspect the saved state after reboot
- supports `--reset-state` so you can clear prior resume/status files before
  re-testing in the same run directory

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
| `--granularity <g>` | `socket` | `socket` for package-level testing, `thread` for one logical CPU at a time |
| `--time <seconds>` | `60` | Stress duration per CPU/socket test |
| `--method <name>` | `matrixprod` | `stress-ng` CPU method, such as `matrixprod` or `fft` |
| `--run-dir <path>` | auto-created under `/var/tmp` | Directory for logs and state files |
| `--status` | off | Show the saved summary/progress from `--run-dir` and exit |
| `--reset-state` | off | Clear previous progress/summary state in `--run-dir` before re-testing |
| `--temp` | off | Enable temperature logging with `sensors` and `--tz` |
| `-h, --help` | — | Show help and exit |

---

## Modes

| Mode | Behavior |
|---|---|
| `sequential` | Tests each detected CPU/socket in order, one socket at a time |
| `socket0` | Tests only CPU/socket 0 using all of its logical threads |
| `socket1` | Tests only CPU/socket 1 using all of its logical threads |

This is intentionally **socket-oriented**, not thread-oriented. If a host hangs
while `socket0` is under full load, you can immediately attribute the crash to
that CPU/package-level test stage.

## Granularity

| Granularity | Behavior |
|---|---|
| `socket` | One physical CPU/socket at a time, using all logical CPUs on that socket |
| `thread` | One logical CPU/thread target at a time |

When `--granularity thread` is used:

- `--mode sequential` iterates all logical CPUs one by one
- `--mode socket0` iterates only the logical CPUs that belong to socket 0
- `--mode socket1` iterates only the logical CPUs that belong to socket 1

---

## Examples

```bash
# Test all detected sockets one by one
sudo ./test/cpu-test.sh --mode sequential --time 300

# Test only CPU/socket 0 for 5 minutes with temperature logging
sudo ./test/cpu-test.sh --mode socket0 --time 300 --temp

# Test each logical CPU individually across the whole machine
sudo ./test/cpu-test.sh --mode sequential --granularity thread --time 60

# Test only the logical CPUs that belong to socket 1, one at a time
sudo ./test/cpu-test.sh --mode socket1 --granularity thread --time 60

# Reuse a persistent run directory and clear old state before retesting
sudo ./test/cpu-test.sh \
  --mode socket1 \
  --run-dir /var/tmp/cpu-test-socket1 \
  --reset-state
```

---

## Logs and Run State

Each run gets its own directory, by default under `/var/tmp`, containing:

- `stress_test_log.txt` — console transcript
- `stress_progress.txt` — current socket target label for resume (`socket0`, `socket1`, etc.)
- `stress_summary.txt` — current target, current status, pass/fail counts, and run metadata

`/var/tmp` is used instead of `/tmp` so the checkpoint is more likely to survive
a reboot after a hang or power loss.

---

## Crash / Power-Loss Behavior

If the machine hangs or powers off during a test:

- the final console line in `stress_test_log.txt` should usually show which
  socket target was starting or running
- `stress_progress.txt` should contain the socket label that was in progress
- `stress_summary.txt` should show:
  - `Current target: socket0` or `socket1`
  - `Current status: running` if the box died during the test
  - pass/fail counts from any targets completed before the crash

That gives you enough information after reboot to know **which CPU/socket was
under test when the machine died**.

You can also inspect the saved state directly through the script:

```bash
sudo ./test/cpu-test.sh --run-dir /var/tmp/cpu-test-socket0 --status
```

---

## Clearing Residue State for Re-Testing

If you want to retest using the same run directory but clear the old resume and
summary markers first, use:

```bash
sudo ./test/cpu-test.sh --run-dir /var/tmp/cpu-test-socket0 --reset-state --mode socket0
```

`--reset-state` clears the old state files before the new run begins.

---

## Notes

- This script is CPU-focused and GPU-free.
- Default usage is intended to identify **which physical CPU/socket** is unstable
  under full local thread load.
- `--granularity thread` is the narrower isolation mode when you need to pin the
  issue down to an individual logical CPU/thread target.
- For combined host-wide stress, use `test/cpu-ram-stress.sh` or
  `test/fulltest.sh --node-stress` once GPU load should be included too.
- The script expects `stress-ng` to be present; install it via
  `install/base-install.sh` if needed.
