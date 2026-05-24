# Project Decisions

Human-readable summary of the current repo-level decisions that are also tracked in OMX memory.

This file is intended to help operators and future contributors understand the current stable paths, experimental lanes, and recent workflow decisions without needing OMX tooling.

---

## Stable vs Experimental Paths

### Stable

- `test/fulltest.sh`
  - Stable production GPU validation path.
  - Avoid heavy in-place flow refactors unless they have been validated on real Linux GPU hosts.

- `test/disktest.sh`
  - Current disk validation path.
  - Interactive by default on a TTY.
  - Supports `--non-interactive` for automation.

### Experimental

- `test/gpu-fulltest-v2.sh`
  - Experimental prepare-then-run variant of `test/fulltest.sh`.
  - Used as the safe lane for structural refactors to GPU validation flow.
  - Should be validated on real GPU hosts before replacing `test/fulltest.sh`.

- Ubuntu 26.04 support
  - `install/base-install.sh` now accepts Ubuntu 26.04 via the `ubuntu2604` CUDA repo codename.
  - `install/amd-base-install.sh` accepts Ubuntu 26.04 as a preview lane using AMD's 31.30 driver repo and `amdrocm7.13`.
  - Treat the AMD 26.04 path as experimental until it has been validated on real hardware.
  - `install/amd-stack-pin.sh` is the operator-facing helper for inspecting or restoring the AMD ROCm apt pin.

---

## Current Decisions

### 1. Do not heavily restructure `test/fulltest.sh` in place

Reason:

- `fulltest.sh` is an operational validation script, so regression risk is more important than internal architectural neatness.
- If the GPU validation flow needs broader structural experimentation, do it in `test/gpu-fulltest-v2.sh` first.

### 2. `disktest.sh` is operator-first on TTYs

Current behavior:

- guided interactive mode on TTY by default
- `--non-interactive` preserved for automation
- interactive mode selection
- checkbox-style disk selection
- per-disk reports written under the run log directory

### 3. Build-tree permission problems should fail early

Current behavior in `fulltest.sh`:

- warns early if build trees or cloned repos are root-owned or otherwise unwritable
- gives ownership-fix guidance before later rebuild / clean steps fail more opaquely

### 4. RAID / ESP redundancy is an opt-in install lane

Current behavior:

- `install/install-raid.sh` stages the RAID helper scripts by default
- `--activate` is required before the apt hook and systemd timer/service are installed
- non-RAID hosts are unaffected unless an operator explicitly activates the lane
- activation is intended for UEFI hosts with multiple ESPs; the installer blocks the common non-RAID case by default

### 5. NVIDIA stack freezing is explicit, not automatic

Current behavior:

- `base-install.sh` warns if held NVIDIA/CUDA packages already exist
- the validated stack can be frozen with `install/nvidia-stack-hold.sh --hold`
- `base-install.sh --unfreeze-gpu-stack` temporarily removes holds, performs the install/update, validates, and then re-freezes the result
- the default install path does not silently remove holds
- `install/provision.sh` passes `--freeze-gpu-stack` and `--unfreeze-gpu-stack` through to the NVIDIA stage-1 install
- AMD orchestration accepts the same flags for CLI symmetry, but the AMD stack is governed by repo pinning rather than apt-mark holds
- `install/amd-stack-pin.sh --status` shows the active ROCm pin and `--reset` restores the expected pin file

### 6. NVIDIA base install applies GPU fallback recovery policy

Current behavior:

- `install/base-install.sh` manages a systemd timeout block in `/etc/systemd/system.conf`
- the managed systemd values are `DefaultTimeoutStopSec=30s` and `DefaultTimeoutAbortSec=15s`
- it writes `/etc/sysctl.d/99-gpu-fallback.conf` with kernel panic / oops / hung-task fallback settings
- the policy is host-wide: a kernel oops or hung task from any subsystem can trigger panic/reboot, not only NVIDIA/GPU faults
- this is intentional for unattended compute nodes where automatic recovery is preferred over leaving a wedged host online for live debugging
- this is a first-layer, in-band mitigation; it does not guarantee recovery when the kernel reboot path blocks on a GPU that has fallen off the PCIe bus
- `install/ipmi-power-cycle.sh` provides the out-of-band manual recovery path for that condition by asking the BMC/IPMI controller to power-cycle the chassis
- uninstall removes the managed systemd block and the sysctl drop-in

### 7. Sustained stress detects 12V-2x6 / 12VHPWR power anomalies as remarks by default

Current behavior:

- `test/fulltest.sh` and `test/gpu-fulltest-v2.sh` both analyse burn telemetry for sustained low-power / high-fan / cooler-than-peers patterns during `stress` and `node-stress`
- the detector is remark-only by default (`POWER_ANOMALY_AS_REMARK=1`) so fleet operators can see the warning without failing the run
- operators can opt back into hard-fail behavior by setting `POWER_ANOMALY_AS_REMARK=0`
- the warning is treated as a connector early-warning, not a generic thermal failure, because it is intended to catch likely 12V-2x6 / 12VHPWR contact resistance issues before the GPU falls off the bus
- the same detector and default behavior are documented in both `docs/fulltest.md` and `docs/gpu-fulltest-v2.md`

### 8. Future improvement plans for the power-anomaly detector

Planned follow-up work:

- add a standalone replay mode so archived burn telemetry can be analyzed without rerunning a stress test
- consider late-onset anomaly detection by comparing early vs late portions of the post-warmup window
- revisit the default severity only after more real-host data is collected across multiple GPU families and cooling topologies

These are tracked as future improvements, not current behavior.

---

## Operator Notes

### `disktest.sh`

Interactive disk picker controls:

- `↑` / `↓` — move
- `Space` — check / uncheck focused disk
- `Enter` — confirm selection
- `a` — select all / deselect all
- `q` — cancel

Per-disk reports are written under:

```text
<log-dir>/reports/
```

### `gpu-fulltest-v2.sh`

Current design goal:

1. detect
2. prepare selected tests
3. run selected tests
4. summarize prepare + test results separately

This script has mocked verification evidence for the prepare-then-run flow, but it should still be treated as experimental until exercised on real GPU hosts.

---

## Recent Validation Notes

- `disktest.sh`
  - verified with syntax checks and Dockerized Linux/Bash runs
  - interactive dry-run flow and health JSON/report output exercised

- `fulltest.sh`
  - permission warning refinements verified with syntax checks and Dockerized non-root unwritable-build scenarios

- `gpu-fulltest-v2.sh`
  - verified with syntax/help output
  - verified in a mocked container flow where prepare succeeds before execution
  - verified in a mocked container flow where prepare failure stops execution early

---

## Practical Guidance

- Use `test/fulltest.sh` for current real validation work.
- Use `test/gpu-fulltest-v2.sh` only for experimental flow evaluation.
- Use `install/install-raid.sh` only when the host actually has a multi-disk ESP / RAID boot layout, and leave it in stage-only mode on ordinary hosts.
- Keep changes to validation scripts small and evidence-driven unless working in the experimental lane.
