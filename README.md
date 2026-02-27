# GPU Node Tools

Automation scripts for provisioning GPU compute nodes on Ubuntu 22.04/24.04.

## Scripts
- **install/base-install.sh**
  End-to-end setup: NVIDIA drivers, GPU Burn.
- **install/docker-install.sh**
  Docker disk provisioning, docker, nvidia container toolkit
- **install/install-p2p-driver.sh**
  Install Tinygrad P2P drivers (experiment)
- **test/fulltest.sh**
  full gpu test
- **test/disktest.sh**
  disk test

## Usage
```bash


# GPU Node Provisioning Suite

## Overview

This suite automates the full provisioning of GPU nodes — from NVIDIA driver installation through Docker setup to hardware validation. It is designed for Ubuntu-based hosts running RTX 4090/5090, A4000, A100, and H100 GPUs in production environments such as vast.ai deployments.

The suite consists of four scripts that work independently or as an orchestrated pipeline:

| Script | Purpose |
|---|---|
| `base-install.sh` | NVIDIA driver installation |
| `docker-install.sh` | Docker CE + NVIDIA Container Toolkit + volume setup |
| `fulltest.sh` | GPU validation suite (NCCL, thermal, PCIe, bandwidth) |
| `provision.sh` | Orchestrator — runs all three across reboots automatically |

All scripts share a common directory at `/opt/provision/` for state, logs, and coordination.

---

## Directory Layout

```
/opt/provision/
├── base-install.sh          # Stage 1 script
├── docker-install.sh        # Stage 2 script
├── fulltest.sh              # Stage 3 script
├── provision.sh             # Orchestrator
├── state/
│   ├── provision.state      # Orchestrator stage state
│   ├── docker-install.state # Docker install phase state
│   └── .provision_complete  # Sentinel file — created when all stages done
└── logs/
    ├── provision.log        # Human-readable orchestrator log
    ├── provision.jsonl      # Structured JSON log (one object per line)
    ├── docker-install.log   # Human-readable Docker install log
    └── docker-install.jsonl # Structured JSON log for Docker install
```

---

## Quick Start

### Automated — Recommended for Most Deployments

```bash
# 1. Copy scripts to the provision directory
sudo mkdir -p /opt/provision
sudo cp base-install.sh docker-install.sh fulltest.sh provision.sh /opt/provision/
sudo chmod +x /opt/provision/*.sh

# 2. Run — handles everything including reboots automatically
sudo /opt/provision/provision.sh --non-interactive --with-compose

# 3. Check progress at any time (from another session or after reboot)
sudo /opt/provision/provision.sh --status
```

The orchestrator installs a systemd `provision-resume.service` on first run. This service fires automatically after each reboot and continues from where it left off. No manual intervention is needed between stages unless a stage fails.

### Interactive — For Manual or First-Time Use

```bash
sudo /opt/provision/provision.sh --with-compose
```

You will be prompted at each decision point (disk selection, confirmations, reboots).

---

## provision.sh — The Orchestrator

### What It Does

`provision.sh` coordinates the three provisioning scripts across the reboots that driver and kernel module installation require. It tracks progress in a state file so that after each reboot it picks up exactly where it left off.

### Flow

```
provision.sh
    │
    ├─► Install provision-resume.service (systemd one-shot, runs on every boot)
    │
    ├─► STAGE 1: base-install.sh
    │       │
    │       └─► Installs NVIDIA driver
    │           → Writes stage1_driver=complete
    │           → REBOOTS (driver must be loaded by kernel)
    │
    │   [system reboots — provision-resume.service fires]
    │
    ├─► STAGE 2: docker-install.sh
    │       │
    │       ├─► Verifies NVIDIA driver is loaded (nvidia-smi check)
    │       ├─► Runs docker-install.sh --non-interactive --called-by-provision
    │       └─► Writes stage2_docker=complete
    │           → REBOOTS if nouveau was blacklisted (conditional)
    │
    │   [system reboots if needed — provision-resume.service fires again]
    │
    ├─► STAGE 3: fulltest.sh
    │       │
    │       ├─► Verifies Docker is running
    │       ├─► Runs full GPU validation suite
    │       └─► Writes stage3_validation=complete
    │
    └─► COMPLETE
            │
            ├─► Creates /opt/provision/state/.provision_complete
            ├─► Disables and removes provision-resume.service
            └─► Prints final summary
```

### Resume Behaviour

If a stage fails, `provision.sh` prints a clear error and stops. The resume service is still active, so after you fix the issue you can either:

- Re-run manually: `sudo /opt/provision/provision.sh --resume`
- Simply reboot — the service will retry the failed stage on boot

### Options

| Option | Description |
|---|---|
| `--non-interactive` | No prompts; auto-confirms all decisions |
| `--with-compose` | Passes through to `docker-install.sh` to install Docker Compose |
| `--vg <vgname>` | Pin a specific LVM VG for Docker volume |
| `--disk /dev/sdX` | Pin a specific disk for Docker volume |
| `--reset-state` | Wipe all state and restart from stage 1 |
| `--resume` | Internal flag used by the systemd service |
| `--status` | Show current stage progress and exit |
| `-h, --help` | Show usage |

### Status Output Example

```
==> Provisioning Status
Host:  gpu-node-01
Date:  Thu Feb 27 10:23:01 UTC 2026

  ✓ stage1_driver: complete
  ✓ stage2_docker: complete
  ~ stage3_validation: running

Docker install phases:
  ✓ DISK_SETUP
  ✓ DOCKER_INSTALL
  ✓ DAEMON_CONFIG
  ✓ COMPOSE_INSTALL
  ✓ NVIDIA_TOOLKIT
  ✓ NOUVEAU_BLACKLIST
```

---

## docker-install.sh — Docker & Toolkit Installer

### What It Does

Installs Docker CE, configures the Docker daemon, optionally installs Docker Compose, installs the NVIDIA Container Toolkit, and blacklists the Nouveau driver. Before any installation it determines the best storage location for `/var/lib/docker` by examining available disks and LVM volumes.

### Flow

```
docker-install.sh
    │
    ├─► PREFLIGHT
    │       ├─► Root check
    │       ├─► Ubuntu version detection
    │       ├─► Required tools check (curl, gpg, lsblk, python3 ...)
    │       └─► Existing Docker detection
    │
    ├─► PHASE: DISK_SETUP
    │       │
    │       ├─► Is /var/lib/docker already a separate mount?
    │       │     └─► YES → skip phase entirely
    │       │
    │       ├─► Scan for free disks (no partitions, not mounted)
    │       ├─► Scan for free LVM VG space
    │       │
    │       ├─► Decision tree:
    │       │     ├─► Free disk found?
    │       │     │     ├─► Non-interactive → auto-pick largest
    │       │     │     └─► Interactive → prompt user to choose
    │       │     │
    │       │     ├─► Free LVM VG found? (if no disk selected)
    │       │     │     ├─► Non-interactive → auto-pick VG with most free space
    │       │     │     └─► Interactive → prompt user to choose
    │       │     │
    │       │     └─► Nothing available → warn, require confirmation, use root
    │       │
    │       ├─► Format selected disk/LV as ext4
    │       ├─► Add UUID-based fstab entry (idempotent — no duplicates)
    │       └─► Mount → verify available space
    │
    ├─► PHASE: DOCKER_INSTALL
    │       ├─► Add Docker APT repository
    │       ├─► Verify Docker GPG key fingerprint
    │       ├─► apt-get install docker-ce docker-ce-cli containerd.io
    │       ├─► Enable + start docker and containerd services
    │       └─► Add SUDO_USER to docker group
    │
    ├─► PHASE: DAEMON_CONFIG
    │       ├─► Detect filesystem type → select storage driver
    │       │     (ext4/xfs → overlay2, btrfs → btrfs, zfs → zfs)
    │       ├─► Write /etc/docker/daemon.json via Python (guaranteed valid JSON):
    │       │     - log-driver: json-file
    │       │     - log-opts: max-size=100m, max-file=3
    │       │     - storage-driver: <detected>
    │       │     - data-root: /var/lib/docker
    │       │     - default-runtime: nvidia (only if nvidia-smi present)
    │       ├─► Validate JSON
    │       └─► Restart Docker
    │
    ├─► PHASE: COMPOSE_INSTALL  (only if --with-compose)
    │       ├─► Query GitHub API for latest Compose release version
    │       │     (falls back to v2.27.1 if API unavailable)
    │       ├─► Detect host architecture (amd64/arm64/armhf)
    │       ├─► Download binary + SHA256 checksum from GitHub releases
    │       ├─► Verify checksum — hard fail if mismatch
    │       ├─► Install to /usr/local/lib/docker/cli-plugins/docker-compose
    │       └─► Verify with docker compose version
    │
    ├─► PHASE: NVIDIA_TOOLKIT
    │       ├─► Check nvidia-smi — warn if driver not present (non-blocking)
    │       ├─► Add NVIDIA APT repository
    │       ├─► Verify NVIDIA GPG key fingerprint
    │       ├─► apt-get install nvidia-container-toolkit
    │       ├─► nvidia-ctk runtime configure --runtime=docker
    │       ├─► Patch daemon.json → set default-runtime=nvidia (via Python)
    │       └─► Restart Docker
    │
    ├─► PHASE: NOUVEAU_BLACKLIST
    │       ├─► Check if already blacklisted → skip if so (idempotent)
    │       ├─► Write /etc/modprobe.d/blacklist-nouveau.conf
    │       └─► update-initramfs -u
    │
    ├─► POST-INSTALL VALIDATION
    │       ├─► docker run --rm hello-world
    │       ├─► nvidia-ctk --version
    │       └─► docker compose version (if installed)
    │
    └─► SUMMARY
            ├─► Docker version
            ├─► Compose version (if installed)
            ├─► daemon.json contents
            ├─► Storage layout (df -h)
            └─► Phase state table
```

### Disk Setup Decision Logic

```
Is /var/lib/docker already a separate mountpoint?
    YES → skip all disk setup
    NO  ↓

Are there any free disks (no partitions, not mounted)?
    YES → Non-interactive: auto-select largest
          Interactive:     prompt user to choose (or skip)
    NO  ↓

Is there free space in any LVM VG?
    YES → Non-interactive: auto-select VG with most free space
          Interactive:     prompt user to choose (or skip)
          → lvcreate using 80% of free VG extents
    NO  ↓

Warn: Docker will be installed on root partition
    → Show df -h, require explicit confirmation
    → Proceed on root
```

### Phase State & Resume

Each phase writes its status (`running` → `complete` or `failed`) to `/opt/provision/state/docker-install.state`. On re-run, completed phases are skipped automatically. This means if the script dies mid-way (network failure during apt, etc.) you can simply re-run and it will resume from the failed phase.

```bash
# Resume after a failure
sudo /opt/provision/docker-install.sh --non-interactive

# Force a full re-run ignoring existing state
sudo /opt/provision/docker-install.sh --reset-state
```

### Options

| Option | Description |
|---|---|
| `--non-interactive` | No prompts; auto-selects best disk/VG, auto-confirms all |
| `--disk /dev/sdX` | Force a specific disk for `/var/lib/docker` |
| `--vg <vgname>` | Force a specific LVM VG for `/var/lib/docker` |
| `--with-compose` | Install Docker Compose v2 (latest stable, checksum-verified) |
| `--uninstall` | Full removal of Docker, toolkit, Compose, and volume mounts |
| `--reset-state` | Clear phase state and re-run all phases from scratch |
| `--called-by-provision` | Internal flag set by `provision.sh` — suppresses reboot prompt |
| `-h, --help` | Show usage |

### daemon.json Written by This Script

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "data-root": "/var/lib/docker",
  "default-runtime": "nvidia"
}
```

`default-runtime` is only written when the NVIDIA driver is present at config time. Log rotation (100 MB per file, 3 files max) prevents Docker logs from silently filling the Docker volume.

---

## Logging

### Human-Readable Log

Every `[INFO]`, `[OK]`, `[WARN]`, and `[ERROR]` line is tee'd to the log file. Each run is separated by a timestamped header. The last **3 runs** are retained (older runs are automatically trimmed).

```
===== docker-install.sh started at Thu Feb 27 10:23:01 UTC 2026 =====
[INFO]  Running in non-interactive mode
[OK]    OS: Ubuntu jammy
...
```

### JSON Log (`.jsonl`)

Every log event is also written as a JSON object to the `.jsonl` file (one object per line). This format is directly ingestible by Loki, Elasticsearch, Splunk, or any structured log aggregator.

```json
{"ts":"2026-02-27T10:23:01Z","level":"info","phase":"DOCKER_INSTALL","host":"gpu-node-01","msg":"Installing docker-ce"}
{"ts":"2026-02-27T10:24:15Z","level":"success","phase":"DOCKER_INSTALL","host":"gpu-node-01","msg":"Docker installed: Docker version 26.1.0"}
{"ts":"2026-02-27T10:24:16Z","level":"warn","phase":"NVIDIA_TOOLKIT","host":"gpu-node-01","msg":"NVIDIA driver not detected"}
```

Fields:

| Field | Description |
|---|---|
| `ts` | ISO 8601 UTC timestamp |
| `level` | `info`, `success`, `warn`, `error` |
| `phase` / `stage` | Current execution phase or orchestration stage |
| `host` | Short hostname (`hostname -s`) |
| `msg` | Log message text |

### Log Locations

| File | Description |
|---|---|
| `/opt/provision/logs/provision.log` | Orchestrator human log |
| `/opt/provision/logs/provision.jsonl` | Orchestrator JSON log |
| `/opt/provision/logs/docker-install.log` | Docker install human log |
| `/opt/provision/logs/docker-install.jsonl` | Docker install JSON log |

---

## State Files

### Format

State files are plain `KEY=VALUE` text, one entry per line:

```
DISK_SETUP=complete
DOCKER_INSTALL=complete
DAEMON_CONFIG=complete
COMPOSE_INSTALL=complete
NVIDIA_TOOLKIT=failed
NOUVEAU_BLACKLIST=not run
```

### Values

| Value | Meaning |
|---|---|
| `complete` | Phase finished successfully — will be skipped on re-run |
| `running` | Phase was in progress when script last exited (possible crash) |
| `failed` | Phase exited with an error — will be retried on re-run |
| *(absent)* | Phase has not started |

### Resetting State

```bash
# Reset docker-install phases only
sudo /opt/provision/docker-install.sh --reset-state

# Reset everything (all stages, all phases)
sudo /opt/provision/provision.sh --reset-state
```

---

## Common Scenarios

### New Node — Fully Automated

```bash
sudo mkdir -p /opt/provision
sudo cp *.sh /opt/provision/ && sudo chmod +x /opt/provision/*.sh
sudo /opt/provision/provision.sh --non-interactive --with-compose
# Walk away — reboots and resumes automatically
```

### New Node — Pinning a Specific LVM VG

```bash
sudo /opt/provision/provision.sh --non-interactive --vg ubuntu-vg --with-compose
```

### Re-provisioning an Existing Node

```bash
# Remove Docker first, then re-run
sudo /opt/provision/docker-install.sh --uninstall
sudo /opt/provision/provision.sh --reset-state --non-interactive
```

### Docker Install Only (Driver Already Installed)

```bash
sudo /opt/provision/docker-install.sh --with-compose
```

### Resuming After a Failure

```bash
# Check what failed
sudo /opt/provision/provision.sh --status

# Fix the underlying issue, then resume
sudo /opt/provision/provision.sh --resume --non-interactive
```

### Checking Progress from Another Session

```bash
sudo /opt/provision/provision.sh --status

# Or tail the live log
tail -f /opt/provision/logs/provision.log
```

### Uninstalling Docker Only

```bash
sudo /opt/provision/docker-install.sh --uninstall
```

This removes: Docker CE packages, NVIDIA Container Toolkit, Docker Compose, APT repos, GPG keyring files, `daemon.json`, the `/var/lib/docker` fstab entry (unmounts the volume), and the nouveau blacklist file. The underlying disk or LV is **not** wiped — that is a deliberate manual step.

---

## Security Notes

### GPG Key Verification

Both the Docker and NVIDIA APT repository GPG keys are fingerprint-verified after download before being trusted. If the fingerprint does not match the known-good value embedded in the script, the installation fails hard.

| Key | Expected Fingerprint |
|---|---|
| Docker | `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88` |
| NVIDIA | `EB69 3B30 35CD 5710 E231 7D3F 0402 5462 7A30 5A5C` |

### Docker Compose Checksum

The Compose binary is verified against the official SHA256 checksum published alongside each GitHub release. The installation fails hard if the checksum does not match.

### Architecture Detection

All architecture-specific values (`amd64`, `arm64`, `armv7`) are detected at runtime from `dpkg --print-architecture`. Nothing is hardcoded.

---

## Troubleshooting

### Script Fails Mid-Way

Check the log for the exact line and phase:

```bash
tail -50 /opt/provision/logs/docker-install.log
# or for structured output
grep '"level":"error"' /opt/provision/logs/docker-install.jsonl | tail -10
```

Fix the issue, then re-run — completed phases will be skipped automatically.

### Stage 2 Fails With "NVIDIA driver not loaded"

Stage 1 completed but the reboot did not happen (e.g. you interrupted it), or the driver failed to load.

```bash
# Check driver status
nvidia-smi

# If driver loaded, just resume
sudo /opt/provision/provision.sh --resume

# If driver not loaded, reboot first
sudo reboot
```

### Docker Volume Too Small

If the Docker volume runs out of space during ML workloads, you can extend it:

```bash
# For LVM
sudo lvextend -l +100%FREE /dev/ubuntu-vg/docker_data
sudo resize2fs /dev/ubuntu-vg/docker_data

# Check result
df -h /var/lib/docker
```

### fstab Entry Already Exists

The scripts are idempotent — they check for an existing UUID entry before appending. If you see a duplicate, inspect and clean manually:

```bash
grep "docker" /etc/fstab
# Remove the duplicate line with your editor
```

### Compose Download Fails

If the GitHub API is unreachable (air-gapped environment), the script falls back to the pinned version `v2.27.1`. If the download itself fails, you can manually install Compose and mark the phase complete:

```bash
# Manually install Compose
COMPOSE_DIR="/usr/local/lib/docker/cli-plugins"
sudo mkdir -p "$COMPOSE_DIR"
sudo curl -fsSL https://github.com/docker/compose/releases/download/v2.27.1/docker-compose-linux-x86_64 \
    -o "${COMPOSE_DIR}/docker-compose"
sudo chmod +x "${COMPOSE_DIR}/docker-compose"

# Mark phase complete so re-run skips it
echo "COMPOSE_INSTALL=complete" >> /opt/provision/state/docker-install.state
```

### Resume Service Not Firing After Reboot

```bash
# Check service status
systemctl status provision-resume.service

# Check if sentinel file was created prematurely
ls -la /opt/provision/state/.provision_complete

# If sentinel exists but provisioning is incomplete, remove it
sudo rm /opt/provision/state/.provision_complete
sudo systemctl enable provision-resume.service
```

---

## Multi-Host Usage

For provisioning multiple hosts simultaneously (e.g. via Ansible or cloud-init), use `--non-interactive` with specific VG or disk pins where needed.

### Ansible Example

```yaml
- name: Copy provisioning scripts
  copy:
    src: "{{ item }}"
    dest: /opt/provision/
    mode: '0755'
  loop:
    - base-install.sh
    - docker-install.sh
    - fulltest.sh
    - provision.sh

- name: Run provisioner (non-interactive, handles own reboots)
  command: /opt/provision/provision.sh --non-interactive --with-compose
  async: 3600
  poll: 30

- name: Check provisioning complete
  stat:
    path: /opt/provision/state/.provision_complete
  register: provision_done
  until: provision_done.stat.exists
  retries: 30
  delay: 60
```

### cloud-init Example

```yaml
runcmd:
  - mkdir -p /opt/provision
  - cp /tmp/scripts/*.sh /opt/provision/
  - chmod +x /opt/provision/*.sh
  - /opt/provision/provision.sh --non-interactive --with-compose
```

### Collecting JSON Logs from Multiple Hosts

Each `.jsonl` file includes the `host` field, so logs from multiple nodes can be aggregated and queried without ambiguity:

```bash
# Collect logs from all nodes
for host in gpu-01 gpu-02 gpu-03; do
    scp ${host}:/opt/provision/logs/docker-install.jsonl ./logs/${host}.jsonl
done

# Query all errors across all hosts
cat ./logs/*.jsonl | grep '"level":"error"' | python3 -m json.tool
```
