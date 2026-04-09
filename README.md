# GPU Node Provisioning Suite

Script-driven tooling for provisioning, validating, and operating GPU compute nodes on Ubuntu 22.04 and 24.04.

This repo is aimed at bare-metal and hosted GPU nodes where the main job is:

- install the GPU software stack
- install Docker and the container runtime layout
- validate the machine before it enters service
- keep a set of operational utilities nearby for inventory, network checks, power policy, and monitoring

## What This Repo Covers

There are two primary provisioning paths:

- NVIDIA/CUDA nodes
- AMD/ROCm nodes

The current NVIDIA path can be run either:

- as a single orchestrated workflow with automatic reboot resume
- as individual scripts run manually

The AMD path can now be run either:

- as a dedicated orchestrated workflow with automatic reboot resume
- as individual scripts run manually

Current platform status:

- NVIDIA: orchestrated + manual
- AMD: orchestrated + manual

## Repo Layout

```text
.
├── install/
│   ├── provision.sh            # NVIDIA orchestration across reboots
│   ├── provision-amd.sh        # AMD orchestration across reboots
│   ├── base-install.sh         # NVIDIA driver + CUDA + supporting packages
│   ├── docker-install.sh       # Docker CE + NVIDIA toolkit + runtime storage
│   ├── amd-base-install.sh     # AMDGPU + ROCm base installer
│   ├── gpu-power-limit.sh      # Persistent NVIDIA power-limit service installer
│   ├── install-p2p-driver.sh   # Experimental Tinygrad P2P driver flow
│   └── backup/                 # Legacy / archived helper scripts
├── test/
│   ├── fulltest.sh             # NVIDIA multi-GPU acceptance test
│   ├── disktest.sh             # Disk validation and fio-based health/perf suite
│   ├── ramtest.sh              # System RAM burn-in using stressapptest
│   └── network-test.sh         # Network connectivity and throughput test
├── gpucheck/                   # Inventory / hardware inspection scripts
├── monitor/                    # Monitoring helpers, including IPMI watcher
├── network/                    # Simple network utility scripts and IP lists
├── docs/                       # Detailed script reference guides
└── drivers/                    # Driver-related assets
```

## Canonical Workflows

### NVIDIA: Orchestrated Provisioning

This is the main end-to-end path for NVIDIA nodes.

Scripts involved:

- [install/provision.sh](/Users/josephcheung/Desktop/dev/infra/install/provision.sh)
- [install/base-install.sh](/Users/josephcheung/Desktop/dev/infra/install/base-install.sh)
- [install/docker-install.sh](/Users/josephcheung/Desktop/dev/infra/install/docker-install.sh)
- [test/fulltest.sh](/Users/josephcheung/Desktop/dev/infra/test/fulltest.sh)

How it works:

1. `provision.sh` installs a `provision-resume.service`.
2. Stage 1 runs `base-install.sh`.
3. The machine reboots if the NVIDIA driver must be loaded by the kernel.
4. The resume service calls `provision.sh --resume` after boot.
5. Stage 2 runs `docker-install.sh`.
6. The machine may reboot again if Nouveau blacklisting needs a reboot to take effect.
7. Stage 3 runs `fulltest.sh`.
8. On success, the resume service is disabled and the run is marked complete.

Shared runtime location used by the orchestrator:

```text
/opt/provision/
├── base-install.sh
├── docker-install.sh
├── fulltest.sh
├── provision.sh
├── state/
│   ├── provision.state
│   ├── docker-install.state
│   └── .provision_complete
└── logs/
    ├── provision.log
    ├── provision.jsonl
    ├── docker-install.log
    └── docker-install.jsonl
```

### NVIDIA: Manual Provisioning

If you want more control, run the stages directly:

1. [install/base-install.sh](/Users/josephcheung/Desktop/dev/infra/install/base-install.sh)
2. reboot if required
3. [install/docker-install.sh](/Users/josephcheung/Desktop/dev/infra/install/docker-install.sh)
4. reboot if required
5. [test/fulltest.sh](/Users/josephcheung/Desktop/dev/infra/test/fulltest.sh)

### AMD: Orchestrated Provisioning

This is the main end-to-end path for AMD nodes.

Scripts involved:

- [install/provision-amd.sh](/Users/josephcheung/Desktop/dev/infra/install/provision-amd.sh)
- [install/amd-base-install.sh](/Users/josephcheung/Desktop/dev/infra/install/amd-base-install.sh)
- [install/docker-install.sh](/Users/josephcheung/Desktop/dev/infra/install/docker-install.sh)

How it works:

1. `provision-amd.sh` installs a `provision-amd-resume.service`.
2. Stage 1 runs `amd-base-install.sh`.
3. The machine reboots if the AMDGPU kernel module still needs to be loaded.
4. The resume service calls `provision-amd.sh --resume` after boot.
5. Stage 2 runs `docker-install.sh` in AMD mode, skipping NVIDIA-only phases.
6. Stage 3 validates `rocm-smi`, `rocminfo`, and Docker.
7. On success, the resume service is disabled and the run is marked complete.

AMD container note:

- this path does not install an AMD equivalent to `nvidia-container-toolkit`
- it uses standard Docker plus ROCm on the host
- AMD GPU containers are expected to access GPUs through device passthrough such as:
  - `/dev/kfd`
  - `/dev/dri`

Shared runtime location used by the AMD orchestrator:

```text
/opt/provision-amd/
├── amd-base-install.sh
├── docker-install.sh
├── provision-amd.sh
├── state/
│   ├── provision.state
│   ├── docker-install.state
│   └── .provision_complete
└── logs/
    ├── provision.log
    ├── provision.jsonl
    ├── docker-install.log
    └── docker-install.jsonl
```

### AMD: Manual Provisioning

The AMD manual path starts with:

- [install/amd-base-install.sh](/Users/josephcheung/Desktop/dev/infra/install/amd-base-install.sh)

This installs the AMDGPU DKMS driver, ROCm stack, and post-install environment setup. It is documented in:

- [docs/amd-base-install.md](/Users/josephcheung/Desktop/dev/infra/docs/amd-base-install.md)

## Quick Start

### NVIDIA Orchestrated: Automated

```bash
sudo mkdir -p /opt/provision
sudo cp install/base-install.sh install/docker-install.sh install/provision.sh test/fulltest.sh /opt/provision/
sudo chmod +x /opt/provision/*.sh

sudo /opt/provision/provision.sh --non-interactive --with-compose
sudo /opt/provision/provision.sh --status
```

Use this when you want the provisioning flow to resume automatically across reboots.

### NVIDIA Orchestrated: Interactive

```bash
sudo mkdir -p /opt/provision
sudo cp install/base-install.sh install/docker-install.sh install/provision.sh test/fulltest.sh /opt/provision/
sudo chmod +x /opt/provision/*.sh

sudo /opt/provision/provision.sh --with-compose
```

Interactive mode allows prompts in the underlying scripts where applicable.

### NVIDIA Manual

```bash
chmod +x install/base-install.sh install/docker-install.sh test/fulltest.sh

sudo ./install/base-install.sh
sudo reboot

sudo ./install/docker-install.sh --with-compose
sudo reboot

./test/fulltest.sh
```

### AMD Manual

```bash
chmod +x install/amd-base-install.sh
sudo ./install/amd-base-install.sh
```

### AMD Orchestrated

```bash
sudo mkdir -p /opt/provision-amd
sudo cp install/amd-base-install.sh install/docker-install.sh install/provision-amd.sh /opt/provision-amd/
sudo chmod +x /opt/provision-amd/*.sh

sudo /opt/provision-amd/provision-amd.sh --non-interactive --with-compose
sudo /opt/provision-amd/provision-amd.sh --status
```

## Major Scripts

| Script | Role | Detailed Doc |
|---|---|---|
| `install/provision.sh` | Orchestrates NVIDIA provisioning across reboots | Covered here |
| `install/provision-amd.sh` | Orchestrates AMD provisioning across reboots | Covered here |
| `install/base-install.sh` | NVIDIA driver, CUDA, cuDNN, DCGM, and base tooling | [docs/base-install.md](/Users/josephcheung/Desktop/dev/infra/docs/base-install.md) |
| `install/docker-install.sh` | Docker CE, NVIDIA Container Toolkit, and runtime storage layout | [docs/docker-install.md](/Users/josephcheung/Desktop/dev/infra/docs/docker-install.md) |
| `test/fulltest.sh` | NVIDIA GPU acceptance and health validation | [docs/fulltest.md](/Users/josephcheung/Desktop/dev/infra/docs/fulltest.md) |
| `test/gpu-fulltest-v2.sh` | Experimental prepare-then-run variant of the NVIDIA GPU validation flow | [docs/gpu-fulltest-v2.md](/Users/josephcheung/Desktop/dev/infra/docs/gpu-fulltest-v2.md) |
| `install/amd-base-install.sh` | AMDGPU + ROCm base install | [docs/amd-base-install.md](/Users/josephcheung/Desktop/dev/infra/docs/amd-base-install.md) |
| `test/disktest.sh` | Disk health, throughput, and stress validation with guided interactive mode and per-disk reports | [docs/disktest.md](/Users/josephcheung/Desktop/dev/infra/docs/disktest.md) |
| `test/ramtest.sh` | System RAM burn-in and ECC-aware memory validation | [docs/ramtest.md](/Users/josephcheung/Desktop/dev/infra/docs/ramtest.md) |
| `test/network-test.sh` | Network connectivity, latency, MTU, and bandwidth validation | [docs/network-test.md](/Users/josephcheung/Desktop/dev/infra/docs/network-test.md) |
| `test/network-batch.sh` | SSH-based orchestration helper for chain, pair, rotate, grouped, and plan-export network validation | [docs/network-batch.md](/Users/josephcheung/Desktop/dev/infra/docs/network-batch.md) |
| `install/gpu-power-limit.sh` | Installs a persistent NVIDIA power-limit policy service | [docs/gpu-power-limit.md](/Users/josephcheung/Desktop/dev/infra/docs/gpu-power-limit.md) |
| Combined acceptance workflow | Client-facing 60-node validation kit combining GPU, network, disk, burn, reboot, and variance checks | [docs/client-acceptance-test-kit.md](/Users/josephcheung/Desktop/dev/infra/docs/client-acceptance-test-kit.md) |

## Provisioning Details

### `install/provision.sh`

Current top-level behavior:

- validates that `base-install.sh`, `docker-install.sh`, and `fulltest.sh` exist under `/opt/provision`
- installs a one-shot `provision-resume.service`
- tracks stage state in `/opt/provision/state/provision.state`
- supports:
  - `--non-interactive`
  - `--with-compose`
  - `--vg <vgname>`
  - `--disk /dev/sdX`
  - `--reset-state`
  - `--resume`
  - `--status`
- verifies the NVIDIA driver is loaded before stage 2
- verifies Docker is active before stage 3

Stage names:

- `stage1_driver`
- `stage2_docker`
- `stage3_validation`

### `install/docker-install.sh`

Current storage model:

- prefers a dedicated disk when one is available
- otherwise can consume free LVM space
- otherwise can fall back to a loopback image on root
- mounts the shared runtime at `/data/container-runtime`
- uses bind mounts for:
  - `/var/lib/docker`
  - `/var/lib/containerd`

Current tracked phases:

- `DISK_SETUP`
- `DOCKER_INSTALL`
- `DAEMON_CONFIG`
- `COMPOSE_INSTALL`
- `NVIDIA_TOOLKIT`
- `NOUVEAU_BLACKLIST`

It can also be reused on AMD hosts with:

- `--skip-nvidia-toolkit`
- `--skip-nouveau-blacklist`

On AMD hosts, this means:

- `docker-install.sh` still installs Docker CE, containerd, storage layout, and optional Compose
- it does not install an AMD-specific Docker runtime/toolkit equivalent
- AMD GPU containers are expected to use standard Docker device passthrough for ROCm, typically exposing:
  - `/dev/kfd`
  - `/dev/dri`

### `install/provision-amd.sh`

Current top-level behavior:

- validates that `amd-base-install.sh` and `docker-install.sh` exist under `/opt/provision-amd`
- installs a one-shot `provision-amd-resume.service`
- tracks stage state in `/opt/provision-amd/state/provision.state`
- supports:
  - `--non-interactive`
  - `--with-compose`
  - `--vg <vgname>`
  - `--disk /dev/sdX`
  - `--reset-state`
  - `--resume`
  - `--status`
- verifies `rocm-smi` is operational before stage 2
- reuses `docker-install.sh` while skipping NVIDIA-only phases
- validates `rocm-smi`, `rocminfo`, and Docker in stage 3
- does not configure a separate AMD Docker runtime; AMD GPU container access is expected via ROCm device passthrough

### `test/fulltest.sh`

This is the main NVIDIA validation suite. It covers:

- preflight checks
- ECC inspection
- PCIe link checks
- clock/throttle behavior under load
- NCCL validation
- CUDA sample builds
- nvbandwidth
- DCGM diagnostics
- PyTorch distributed checks
- VRAM memtest
- sustained compute stress

It writes timestamped logs in the same directory where `fulltest.sh` is run.

## Operational Utility Scripts

### Inventory / Hardware

Important scripts under [gpucheck/](/Users/josephcheung/Desktop/dev/infra/gpucheck):

- [gpucheck/inv.sh](/Users/josephcheung/Desktop/dev/infra/gpucheck/inv.sh): GPU to PCIe slot mapping, link details, power, temperature, NUMA, CSV/JSON output
- `srv-inv.sh`, `srv-inv-lite.sh`, `modinv.sh`, `dimm-inv.sh`, `bare-inv.sh`: broader host inventory helpers
- `gpu-watchdog.sh` plus matching `.service` and `.timer`: watchdog support

### Monitoring

Important files under [monitor/](/Users/josephcheung/Desktop/dev/infra/monitor):

- [monitor/ipmi-watch.sh](/Users/josephcheung/Desktop/dev/infra/monitor/ipmi-watch.sh): IPMI reachability checks, outage tracking, Prometheus textfile export, email alerting
- [monitor/calc_ipmi_energy.py](/Users/josephcheung/Desktop/dev/infra/monitor/calc_ipmi_energy.py): IPMI energy-related helper

### Network

Important files under [network/](/Users/josephcheung/Desktop/dev/infra/network):

- [network/iptest.sh](/Users/josephcheung/Desktop/dev/infra/network/iptest.sh): CSV-driven ping sweep for unresponsive IPs
- `iplist.csv`, `iplist_clean.csv`, `googledns-ipv6.txt`: network input/reference data

## Logs, State, and Generated Files

What this repo will generate locally:

- `test/build/`
- `test/fulltest_*.log`
- `test/logs/`

These are ignored in [.gitignore](/Users/josephcheung/Desktop/dev/infra/.gitignore).

When using the orchestrated `/opt/provision` flow, expect:

- orchestrator logs under `/opt/provision/logs/`
- stage state under `/opt/provision/state/`
- `fulltest` logs in `/opt/provision/` itself because the script writes beside its own path

When using the orchestrated `/opt/provision-amd` flow, expect:

- orchestrator logs under `/opt/provision-amd/logs/`
- stage state under `/opt/provision-amd/state/`

## Detailed Documentation

Script reference guides now live under [docs/](/Users/josephcheung/Desktop/dev/infra/docs):

- [docs/base-install.md](/Users/josephcheung/Desktop/dev/infra/docs/base-install.md)
- [docs/docker-install.md](/Users/josephcheung/Desktop/dev/infra/docs/docker-install.md)
- [docs/fulltest.md](/Users/josephcheung/Desktop/dev/infra/docs/fulltest.md)
- [docs/gpu-fulltest-v2.md](/Users/josephcheung/Desktop/dev/infra/docs/gpu-fulltest-v2.md)
- [docs/disktest.md](/Users/josephcheung/Desktop/dev/infra/docs/disktest.md)
- [docs/ramtest.md](/Users/josephcheung/Desktop/dev/infra/docs/ramtest.md)
- [docs/network-test.md](/Users/josephcheung/Desktop/dev/infra/docs/network-test.md)
- [docs/network-batch.md](/Users/josephcheung/Desktop/dev/infra/docs/network-batch.md)
- [docs/client-acceptance-test-kit.md](/Users/josephcheung/Desktop/dev/infra/docs/client-acceptance-test-kit.md)
- [docs/gpu-power-limit.md](/Users/josephcheung/Desktop/dev/infra/docs/gpu-power-limit.md)
- [docs/amd-base-install.md](/Users/josephcheung/Desktop/dev/infra/docs/amd-base-install.md)

The root README is intended to answer:

- what this repo is for
- which script to run first
- which workflow is current
- where state and logs go

The `docs/` files are intended to answer:

- exact script options
- deep implementation details
- platform-specific notes
- troubleshooting at the individual script level

## Legacy Material

[install/backup/](/Users/josephcheung/Desktop/dev/infra/install/backup) contains archived or older helper scripts.

Treat that directory as reference material, not the primary supported workflow.

## Suggested Next Improvements

Documentation work that would still add value:

- add a short troubleshooting section for common provisioning failures
- add a dedicated docs page for `gpucheck/` inventory scripts
- add a docs page for `monitor/` usage and deployment
- add a dedicated detailed doc for `install/provision-amd.sh`
