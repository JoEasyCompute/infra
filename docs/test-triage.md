# Test Triage Guide

This repo has several different kinds of tests, and they fail for different reasons.
This guide is a lightweight decision path for operators who want to answer a simple question:

> Is this likely software, hardware, or an environment/configuration issue — and what should I check next?

The short version:

- **`code`** = CUDA runtime / driver / compute sanity
- **`memtest`** = VRAM integrity
- **`stress`** = sustained power / thermals / boost stability
- **`pytorch`** = framework/runtime / Python / PyTorch / NCCL stack
- **`nccl`** = GPU-to-GPU communication / PCIe / NVLink / NCCL transport
- **`pcie-errors`** = PCIe replay growth and fatal/uncorrectable bus errors
- **`memory-health`** = persistent ECC, retired-page, and row-remapper state
- **`fabric-health`** = NVLink/NVSwitch port state and error-counter growth
- **`disktest`** = storage path, permissions, disk health, fio behavior
- **`network-test`** = link, routing, MTU, bandwidth, remote reachability
- **`cpu-test` / `cpu-ram-stress` / `ramtest`** = CPU, RAM, socket, thermal, memory-controller issues

Provisioned NVIDIA and AMD hosts now boot with the managed PCIe / NVMe policy disabled or tuned by default. If a PCIe link still looks slow under load, treat BIOS lane-speed caps, bifurcation, or riser issues as the next suspects before assuming ASPM is the cause.

---

## Quick Decision Tree

### 1) Start with the narrowest sanity test

For GPU nodes, start with:

1. `code`
2. `memtest`
3. `stress`
4. `nccl`
5. `pytorch`

Why:

- `code` is the simplest direct CUDA runtime check
- `memtest` is specifically looking for VRAM integrity problems
- `stress` is better for power/thermal instability
- `nccl` checks GPU-to-GPU communication
- `pytorch` checks the framework/runtime stack

This ordering helps separate “basic CUDA works” from “only this specific higher-level stack fails.”

---

## GPU Failure Interpretation

### If `code` fails

Suspect:

- CUDA toolkit / `nvcc` install problem
- NVIDIA driver/runtime mismatch
- kernel module / device node problem
- unstable GPU compute path
- power or thermal instability under integer compute

Next checks:

1. Confirm `nvidia-smi` works
2. Confirm `nvcc --version` and the CUDA toolkit install
3. Re-run `code` on a single GPU
4. Compare with `memtest`
5. If only one GPU fails, isolate that GPU/slot/power cable

How to read it:

- **`code` fails, `memtest` passes** → often software/driver/runtime, or compute/power/thermal instability
- **`code` fails, `memtest` fails** → stronger hardware suspicion

---

### If `memtest` fails

Suspect:

- bad VRAM
- unstable memory clock / voltage
- memory controller issues
- thermal issue affecting VRAM

Next checks:

1. Re-run `memtest` on that single GPU
2. Lower memory clocks / remove overclocks
3. Check temperatures and power
4. Compare against `code`

How to read it:

- `memtest` failure is one of the strongest hardware indicators in this repo

---

### If `stress` fails

Suspect:

- thermals
- PSU / cabling / connector issues
- boost/power limit instability
- long-run compute instability

Next checks:

1. Check thermal summary and fan/power telemetry
2. Look for power-anomaly remarks
3. Check chassis airflow, fan curves, and GPU temps
4. Re-run at shorter duration
5. Compare against `code` and `memtest`

How to read it:

- `stress` failing while `memtest` passes often points away from pure VRAM failure and toward power/thermal behavior

---

### If `nccl` fails

Suspect:

- GPU-to-GPU transport issue
- PCIe/NVLink/topology issue
- NCCL configuration/runtime issue
- multi-GPU communication instability

Next checks:

1. Run `code` and `memtest` on the same GPUs
2. Re-run `nccl` on fewer GPUs
3. Compare one GPU vs multi-GPU behavior
4. Check PCIe topology / link speed

How to read it:

- If single-GPU tests pass but `nccl` fails, suspect interconnect or NCCL stack rather than raw GPU compute

---

### If `pcie-errors` fails

Suspect a marginal riser, slot, lane negotiation problem, motherboard path, or
GPU PCIe interface. An existing nonzero replay counter is historical; this
test fails only when the counter grows during its measured traffic interval or
available kernel logs report a fatal/uncorrectable PCIe event.

Re-run on one GPU, compare slots/risers, and run `pcie` plus `nvbandwidth` to
separate link negotiation from data-path reliability. The PCIe error lane also
compares Linux AER device counters around host-to-device traffic when NVIDIA's
replay counter is unavailable, and only evaluates kernel events from the
current boot and current test interval.

---

### If `memory-health` fails

Treat uncorrectable ECC, pending retirement/remapping, remap failure,
unrepairable memory, or exhausted remap capacity as a hardware-service event.
Historical corrected errors or completed retirement appear as remarks and
should be trended rather than treated as an immediate failure.

---

### If `fabric-health` fails

Suspect an NVLink, NVSwitch, Fabric Manager, GPU endpoint, or platform fabric
problem. Compare the reported link/counter with `nccl`; isolate the affected
GPU pair where possible. Disabled links are remarks because some platform
topologies intentionally disable ports, while down supported links and
counter growth fail.

---

### If `pytorch` fails

Suspect:

- Python environment issue
- PyTorch wheel / CUDA compatibility problem
- NCCL or distributed init problem
- multiprocessing / rank startup problem

Next checks:

1. Confirm the active Python version
2. Check the installed PyTorch wheel and CUDA compatibility
3. Run `nccl`
4. Run `code`
5. Compare against a clean Python environment if possible

How to read it:

- If `code` passes but `pytorch` fails, the problem is often in the software stack rather than the GPU hardware itself
- If the suite reports PyTorch as `NOT BEING RUN`, first check whether any supported Python runtime is available: the managed benchmark Python 3.11 from `base-install.sh` is preferred, but standalone `fulltest.sh` can fall back to system Python 3.10-3.12

---

## Non-GPU Tests

### If `disktest` fails

Suspect:

- raw disk health
- permission issues on the block device
- fio/ioengine problems
- filesystem / mount / ownership issues

Next checks:

1. Re-run with `--help` or `--status` paths if available
2. Check `smartctl`, `lsblk`, `blkid`, and device permissions
3. Inspect the per-disk report under the run log directory
4. Try a single-disk run before a multi-disk run

---

### If `network-test` or `network-batch` fails

Suspect:

- link / MTU / routing / DNS
- remote host reachability
- iperf service issues
- NIC or switch path instability

Next checks:

1. Verify basic reachability first
2. Check MTU and interface counters
3. Confirm remote server mode started successfully
4. Re-run with a single pair before a multi-host batch

---

### If `cpu-test`, `cpu-ram-stress`, or `ramtest` fails

Suspect:

- CPU instability
- socket-level thermal issue
- memory-controller / DRAM issue
- board power delivery issue

Next checks:

1. Isolate to one socket or one CPU thread
2. Compare against RAM-only or CPU-only tests
3. Check temperatures and ECC / machine check logs
4. Re-run with lower stress duration if needed

---

## Practical Isolation Pattern

When you want to decide “software or hardware?”, use this pattern:

1. **Run `code`**
2. **Run `memtest`**
3. **Run `stress`**
4. **Run `nccl`**
5. **Run `pytorch`**

Interpretation:

- **`code` fails alone** → software/driver/runtime is a strong suspect, but hardware still possible
- **`memtest` fails** → hardware / VRAM / memory-path suspect
- **`stress` fails with `memtest` passing** → power / thermal / boost instability suspect
- **`nccl` or `pytorch` fail with `code` passing** → software stack / comms / framework suspect
- **Only one GPU fails** → isolate that GPU, slot, and power path

---

## What to Capture Before Changing Anything

If a test fails, collect:

- exact test name
- GPU model and index
- run duration
- whether the failure is repeatable
- `nvidia-smi` output
- relevant kernel log lines
- temperature / power / fan behavior
- whether the same GPU passes `code` but fails `memtest` or `stress`

This makes it much easier to tell hardware from software.

---

## Rule of Thumb

- **Memory test failure** → hardware suspicion goes up
- **Framework failure with raw CUDA tests passing** → software suspicion goes up
- **Stress/power/thermal failure** → look at cooling, power, and cabling first
- **Single-GPU failure** → isolate that GPU and its slot/power path

If in doubt, start with `code` and `memtest`.
