# docker-install.sh — Reference Guide

## Overview

`docker-install.sh` is a production-grade installer for Docker CE and the NVIDIA Container Toolkit on Ubuntu systems. It is designed to be safe to run on fresh nodes, partially provisioned nodes, and nodes being reprovisioned — handling all of the following automatically:

- Selecting the best available storage for `/var/lib/docker` (dedicated disk, LVM, or root fallback)
- Installing and configuring Docker CE with sensible production defaults
- Optionally installing Docker Compose v2 with checksum verification
- Installing the NVIDIA Container Toolkit with GPG key verification
- Blacklisting the Nouveau driver
- Tracking progress phase-by-phase so re-runs resume from where they left off

It can be run standalone or called by `provision.sh` as part of a full multi-stage provisioning pipeline.

---

## Requirements

| Requirement | Details |
|---|---|
| OS | Ubuntu 20.04, 22.04, or 24.04 |
| Privileges | Must be run as root (`sudo`) |
| Tools | `curl`, `gpg`, `lsblk`, `df`, `awk`, `sed`, `python3` |
| Python | 3.6+ (used for JSON generation and log rotation) |
| Network | Outbound HTTPS to `download.docker.com`, `github.com`, `nvidia.github.io` |
| LVM tools | `vgs`, `vgdisplay`, `lvcreate` — only needed if using LVM storage |

---

## Installation

```bash
# Copy to the provision directory (recommended)
sudo mkdir -p /opt/provision
sudo cp docker-install.sh /opt/provision/
sudo chmod +x /opt/provision/docker-install.sh

# Or run from any location
sudo chmod +x docker-install.sh
```

---

## Usage

```
sudo /opt/provision/docker-install.sh [OPTIONS]
```

### Options

| Option | Description |
|---|---|
| `--non-interactive` | No prompts; auto-selects best disk/VG, auto-confirms all decisions |
| `--disk /dev/sdX` | Force use of a specific disk for `/var/lib/docker` |
| `--vg <vgname>` | Force use of a specific LVM volume group for `/var/lib/docker` |
| `--with-compose` | Also install Docker Compose v2 (latest stable, checksum-verified) |
| `--uninstall` | Full removal — Docker, toolkit, Compose, volume mounts |
| `--reset-state` | Clear phase state file and re-run all phases from scratch |
| `--called-by-provision` | Internal flag set by `provision.sh` — do not use manually |
| `-h, --help` | Show help and exit |

### Quick Examples

```bash
# Interactive install — prompts for disk/VG selection
sudo /opt/provision/docker-install.sh

# Fully automated — no prompts, auto-selects storage
sudo /opt/provision/docker-install.sh --non-interactive

# Automated with Docker Compose
sudo /opt/provision/docker-install.sh --non-interactive --with-compose

# Automated, pin to a specific LVM VG
sudo /opt/provision/docker-install.sh --non-interactive --vg ubuntu-vg

# Automated, pin to a specific disk
sudo /opt/provision/docker-install.sh --non-interactive --disk /dev/sdb

# Force a complete re-run (ignore existing state)
sudo /opt/provision/docker-install.sh --reset-state --non-interactive

# Clean uninstall
sudo /opt/provision/docker-install.sh --uninstall
```

---

## Execution Flow

The script is structured as six sequential phases. Each phase writes its status to the state file, so a re-run after a failure automatically skips completed phases and retries only what failed.

```
docker-install.sh
        │
        ├─► PREFLIGHT
        │       ├─► Root check
        │       ├─► Log file init + rotation (keeps last 3 runs)
        │       ├─► Ubuntu OS detection
        │       ├─► Required tool check
        │       └─► Existing Docker detection
        │
        ├─► PHASE 1: DISK_SETUP
        │       ├─► Check if /var/lib/docker already separately mounted → skip if yes
        │       ├─► Scan for free disks (unpartitioned, unmounted)
        │       ├─► Scan for free LVM VG space
        │       ├─► Run storage decision tree (see below)
        │       ├─► Format selected device as ext4
        │       ├─► Add UUID-based fstab entry (idempotent)
        │       └─► Mount and verify available space
        │
        ├─► PHASE 2: DOCKER_INSTALL
        │       ├─► Add Docker APT repository + keyring
        │       ├─► Verify Docker GPG key fingerprint
        │       ├─► apt-get install docker-ce docker-ce-cli containerd.io
        │       ├─► Enable + start docker and containerd services
        │       └─► Add invoking user to docker group
        │
        ├─► PHASE 3: DAEMON_CONFIG
        │       ├─► Detect filesystem type → determine storage driver
        │       │     ext4 / xfs → overlay2
        │       │     btrfs      → btrfs
        │       │     zfs        → zfs
        │       ├─► Write /etc/docker/daemon.json (Python, guaranteed valid JSON)
        │       │     log-driver, log-opts, storage-driver, data-root
        │       │     default-runtime: nvidia (only if nvidia-smi present now)
        │       ├─► Validate JSON (python3 json.load)
        │       └─► Restart Docker
        │
        ├─► PHASE 4: COMPOSE_INSTALL  (skipped unless --with-compose)
        │       ├─► Query GitHub API for latest Compose release version
        │       │     fallback → v2.27.1 if API unreachable
        │       ├─► Detect host architecture (amd64 / arm64 / armhf)
        │       ├─► Download binary + SHA256 checksum from GitHub releases
        │       ├─► Verify checksum — hard fail on mismatch
        │       ├─► Install to /usr/local/lib/docker/cli-plugins/docker-compose
        │       └─► Verify with docker compose version
        │
        ├─► PHASE 5: NVIDIA_TOOLKIT
        │       ├─► Check nvidia-smi → warn if driver absent (non-blocking)
        │       ├─► Add NVIDIA Container Toolkit APT repository
        │       ├─► Verify NVIDIA GPG key fingerprint
        │       ├─► Fix architecture placeholder in repo list (dynamic, not hardcoded)
        │       ├─► apt-get install nvidia-container-toolkit
        │       ├─► nvidia-ctk runtime configure --runtime=docker
        │       ├─► Patch daemon.json → add default-runtime: nvidia (Python)
        │       └─► Restart Docker
        │
        ├─► PHASE 6: NOUVEAU_BLACKLIST
        │       ├─► Check if already blacklisted → skip if so
        │       ├─► Write /etc/modprobe.d/blacklist-nouveau.conf
        │       └─► update-initramfs -u
        │
        ├─► VALIDATION
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

---

## Storage Decision Logic (Phase 1 — DISK_SETUP)

Determining where to place `/var/lib/docker` is the most complex part of the script. The decision tree runs in priority order:

```
Is /var/lib/docker already a separate mountpoint?
    YES → Skip all disk setup entirely
     NO ↓

Are there any free disks? (no partitions, not mounted)
    YES →
        Non-interactive or --disk given:
            --disk specified → use that disk
            otherwise       → auto-select the largest free disk
        Interactive:
            Show numbered list of free disks
            User selects one (or skips to LVM check)
        → Format as ext4, mount, add to fstab by UUID
     NO ↓

Is there free space in any LVM VG?
    YES →
        Non-interactive or --vg given:
            --vg specified → use that VG
            otherwise      → auto-select VG with most free space
        Interactive:
            Show numbered list of VGs with free space
            User selects one (or skips to root fallback)
        → lvcreate using 80% of free VG extents
        → Format as ext4, mount, add to fstab by UUID
     NO ↓

No dedicated storage available:
    → Print warning + df -h /
    → Warn if root has < 10 GB free
    → Warn this is not recommended for GPU/ML workloads
    → Require explicit confirmation (or auto-confirm in non-interactive mode)
    → Proceed on root partition
```

### Storage Sizing

| Threshold | Action |
|---|---|
| Docker volume < 50 GB | Warning printed |
| Root free space < 10 GB | Warning printed |
| LVM allocation | 80% of free VG extents (`lvcreate -l 80%FREE`) |

### fstab Entry

Entries are written by UUID (not device path), so they survive disk rename events (`/dev/sdb` → `/dev/sdc` etc.) across reboots:

```
UUID=<uuid>  /var/lib/docker  ext4  defaults,nofail  0  2
```

The `nofail` flag prevents boot failures if the volume is temporarily unavailable. The script checks for an existing UUID entry before appending — re-runs will never create duplicate fstab entries.

---

## Docker Daemon Configuration (Phase 3 — DAEMON_CONFIG)

`/etc/docker/daemon.json` is written by the script. If the file already exists it is backed up to `daemon.json.bak` before being overwritten.

### Written Configuration

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

| Key | Value | Reason |
|---|---|---|
| `log-driver` | `json-file` | Standard, compatible with most log shippers |
| `log-opts.max-size` | `100m` | Prevents logs filling the Docker volume silently |
| `log-opts.max-file` | `3` | Keeps last 300 MB of logs per container |
| `storage-driver` | auto-detected | Matches the filesystem under `/var/lib/docker` |
| `data-root` | `/var/lib/docker` | Explicit — ensures Docker uses the mounted volume |
| `default-runtime` | `nvidia` | Every container gets GPU access without `--gpus all` |

`default-runtime` is only written if `nvidia-smi` is present and responding at daemon config time. After the NVIDIA toolkit is installed in Phase 5, the script patches it in via Python if it was absent earlier.

---

## Docker Compose Install (Phase 4 — COMPOSE_INSTALL)

### Version Resolution

The script queries the GitHub API to resolve the latest stable release:

```
GET https://api.github.com/repos/docker/compose/releases/latest
```

If the API is unreachable (air-gapped environments, rate limiting), it falls back to the pinned version `v2.27.1`. The resolved version is logged.

### Checksum Verification

The binary and its SHA256 checksum file are downloaded separately from GitHub releases:

```
https://github.com/docker/compose/releases/download/<version>/docker-compose-linux-<arch>
https://github.com/docker/compose/releases/download/<version>/docker-compose-linux-<arch>.sha256
```

The script computes `sha256sum` of the downloaded binary and compares it against the published checksum. The installation **hard fails** if they do not match — the binary is discarded and an error is written to the log.

### Architecture Mapping

| `dpkg --print-architecture` | GitHub release filename suffix |
|---|---|
| `amd64` | `x86_64` |
| `arm64` | `aarch64` |
| `armhf` | `armv7` |

### Install Location

```
/usr/local/lib/docker/cli-plugins/docker-compose
```

This path is the standard Docker CLI plugin directory. After installation, `docker compose version` (with a space, not a hyphen) is used to verify.

---

## NVIDIA Container Toolkit (Phase 5 — NVIDIA_TOOLKIT)

### Driver Pre-check

Before installing the toolkit, the script checks for `nvidia-smi`. If the driver is not present:

- A warning is written to the log
- In interactive mode, you are asked whether to continue
- In non-interactive mode, installation proceeds with a warning (driver may be installed later)

The toolkit will install successfully without the driver — GPU containers just won't work until the driver is loaded.

### GPG Key Verification

Both the Docker and NVIDIA APT repository GPG keys are fingerprint-verified after download. If the fingerprint does not match the value embedded in the script, the installation fails hard with an error.

| Key | Expected Fingerprint |
|---|---|
| Docker | `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88` |
| NVIDIA | `EB69 3B30 35CD 5710 E231 7D3F 0402 5462 7A30 5A5C` |

### Architecture Fix

The NVIDIA repo list sometimes contains a literal `$(ARCH)` placeholder instead of the resolved architecture. The script detects this and replaces it with the output of `dpkg --print-architecture` — it never hardcodes `amd64`.

---

## Phase State & Resume

### State File

Progress is tracked in `/opt/provision/state/docker-install.state`:

```
DISK_SETUP=complete
DOCKER_INSTALL=complete
DAEMON_CONFIG=complete
COMPOSE_INSTALL=complete
NVIDIA_TOOLKIT=failed
NOUVEAU_BLACKLIST=not run
```

### Phase Lifecycle

```
(absent) → running → complete
                   → failed
```

| Status | Meaning on Re-run |
|---|---|
| `complete` | Phase is skipped |
| `running` | Phase re-runs (script crashed mid-phase) |
| `failed` | Phase re-runs |
| *(absent)* | Phase runs normally |

### Resuming After a Failure

Simply re-run the script — it will skip completed phases and retry only what failed:

```bash
sudo /opt/provision/docker-install.sh --non-interactive
```

### Forcing a Full Re-run

```bash
sudo /opt/provision/docker-install.sh --reset-state --non-interactive
```

This deletes the state file. All six phases run from scratch. Useful after an uninstall or when reprovisioning a node.

---

## Logging

### Human-Readable Log

Located at `/opt/provision/logs/docker-install.log`. Each run appends a timestamped block. The script retains the **last 3 runs** and trims older content automatically — the log will never grow unbounded.

```
===== docker-install.sh started at Thu Feb 27 10:23:01 UTC 2026 =====
[INFO]  Running in non-interactive mode
[OK]    OS: Ubuntu jammy
[INFO]  Phase DISK_SETUP already complete — skipping
[INFO]  Phase DOCKER_INSTALL already complete — skipping
...
[OK]    docker-install.sh complete
```

### JSON Log

Located at `/opt/provision/logs/docker-install.jsonl`. Every log event is written as a JSON object (one per line). Suitable for ingestion into Loki, Elasticsearch, Splunk, or any structured log pipeline.

```json
{"ts":"2026-02-27T10:23:01Z","level":"info","phase":"INIT","host":"gpu-node-01","msg":"docker-install.sh started"}
{"ts":"2026-02-27T10:23:04Z","level":"info","phase":"DISK_SETUP","host":"gpu-node-01","msg":"(auto) Selected largest free disk: /dev/sdb (500 GB)"}
{"ts":"2026-02-27T10:24:15Z","level":"success","phase":"DOCKER_INSTALL","host":"gpu-node-01","msg":"Docker installed: Docker version 26.1.0"}
{"ts":"2026-02-27T10:25:30Z","level":"warn","phase":"NVIDIA_TOOLKIT","host":"gpu-node-01","msg":"NVIDIA driver not detected — toolkit will install but GPU containers will not work until driver is loaded"}
{"ts":"2026-02-27T10:26:44Z","level":"error","phase":"NVIDIA_TOOLKIT","host":"gpu-node-01","msg":"Script failed at line 312 — phase=NVIDIA_TOOLKIT — check /opt/provision/logs/docker-install.log"}
```

### JSON Log Fields

| Field | Type | Description |
|---|---|---|
| `ts` | string | ISO 8601 UTC timestamp |
| `level` | string | `info`, `success`, `warn`, `error` |
| `phase` | string | Script phase name at time of event |
| `host` | string | Short hostname (`hostname -s`) |
| `msg` | string | Log message |

### Tailing Live Progress

```bash
tail -f /opt/provision/logs/docker-install.log

# Errors only from JSON log
grep '"level":"error"' /opt/provision/logs/docker-install.jsonl
```

---

## Uninstall

```bash
sudo /opt/provision/docker-install.sh --uninstall
```

### What Gets Removed

| Item | Action |
|---|---|
| `docker-ce`, `docker-ce-cli`, `containerd.io` | `apt-get purge` |
| `docker-buildx-plugin`, `docker-compose-plugin` | `apt-get purge` |
| `nvidia-container-toolkit`, `nvidia-container-runtime` | `apt-get purge` |
| Docker Compose CLI plugin binary | `rm -f` |
| Docker APT repo + keyring | `rm -f` |
| NVIDIA APT repo + keyring | `rm -f` |
| `/etc/docker/daemon.json` | `rm -f` |
| `/var/lib/docker`, `/var/lib/containerd`, `/etc/docker` | `rm -rf` |
| `/etc/modprobe.d/blacklist-nouveau.conf` | `rm -f` |
| `/var/lib/docker` fstab entry | Removed from `/etc/fstab` |
| `/var/lib/docker` mount | Unmounted |
| Phase state file | Deleted |

### What Is NOT Removed

- The underlying disk or LV — this is intentional. Reformatting is a separate manual step to prevent accidental data loss.
- The docker system group.
- NVIDIA drivers — managed by `base-install.sh`, not this script.

A reboot is recommended after uninstall to cleanly unload kernel modules.

---

## Troubleshooting

### Checking What Failed

```bash
# Human log — last 50 lines
tail -50 /opt/provision/logs/docker-install.log

# Errors from JSON log
grep '"level":"error"' /opt/provision/logs/docker-install.jsonl | python3 -m json.tool

# Phase state
cat /opt/provision/state/docker-install.state
```

### Docker Fails to Start After Install

```bash
# Check daemon logs
journalctl -u docker --no-pager -n 50

# Validate daemon.json manually
python3 -c "import json; print(json.load(open('/etc/docker/daemon.json')))"

# If daemon.json is corrupt, restore the backup
sudo cp /etc/docker/daemon.json.bak /etc/docker/daemon.json
sudo systemctl restart docker
```

### NVIDIA Runtime Not Working

```bash
# Verify toolkit is installed
nvidia-ctk --version

# Check docker info for runtime
docker info | grep -i runtime

# Test GPU access
docker run --rm --gpus all nvidia/cuda:12.0-base-ubuntu22.04 nvidia-smi
```

If `docker info` does not show `nvidia` as a runtime, re-run Phase 5:

```bash
# Reset just the NVIDIA_TOOLKIT phase
sed -i '/^NVIDIA_TOOLKIT=/d' /opt/provision/state/docker-install.state
sudo /opt/provision/docker-install.sh --non-interactive
```

### Docker Compose Not Found After Install

```bash
# Check the binary exists
ls -la /usr/local/lib/docker/cli-plugins/docker-compose

# Check it is executable
docker compose version

# If checksum failed during install, re-run compose phase only
sed -i '/^COMPOSE_INSTALL=/d' /opt/provision/state/docker-install.state
sudo /opt/provision/docker-install.sh --non-interactive --with-compose
```

### Docker Volume Running Low on Space

```bash
# Check current usage
df -h /var/lib/docker
docker system df

# Clean up unused images, containers, volumes
docker system prune -af --volumes

# If on LVM, extend the volume
sudo lvextend -l +100%FREE /dev/ubuntu-vg/docker_data
sudo resize2fs /dev/ubuntu-vg/docker_data
df -h /var/lib/docker
```

### GPG Key Fingerprint Mismatch

This indicates the key downloaded from the vendor CDN does not match the expected value embedded in the script. Do not proceed — this may indicate a compromised key or MITM attack. Verify network security and compare the fingerprint against the official vendor documentation before continuing.

### Air-Gapped / No Internet Access

If outbound HTTPS is not available, the script will fail when trying to download packages and keys. Options:

1. Use a local APT mirror and set `http_proxy` / `https_proxy` before running
2. Pre-download packages and configure a local repository
3. For Compose specifically: manually download and install, then mark the phase complete:

```bash
# Manually mark Compose phase complete after manual install
sed -i '/^COMPOSE_INSTALL=/d' /opt/provision/state/docker-install.state
echo "COMPOSE_INSTALL=complete" >> /opt/provision/state/docker-install.state
```

---

## Integration With provision.sh

When called by `provision.sh`, the script receives `--called-by-provision` which suppresses the post-install reboot prompt (the orchestrator manages reboot timing). The `--non-interactive` flag is always passed, and disk/VG selections are forwarded from the top-level `provision.sh` invocation.

The Docker install phase state file is checked independently by `provision.sh --status`, so per-phase progress is always visible from the orchestrator.

See `provisioning-guide.md` for the full multi-stage flow.
