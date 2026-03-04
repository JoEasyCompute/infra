# docker-install.sh — Reference Guide

## Overview

`docker-install.sh` is a production-grade installer for Docker CE and the NVIDIA Container Toolkit on Ubuntu systems. It is designed to be safe to run on fresh nodes, partially provisioned nodes, and nodes being reprovisioned — handling all of the following automatically:

- Provisioning a shared XFS volume (with reflink/copy-on-write) for both Docker and containerd
- Migrating any existing data before mounting, so re-provisioning never causes data loss
- Installing and configuring Docker CE with sensible production defaults
- Optionally installing Docker Compose v2 with checksum verification
- Installing the NVIDIA Container Toolkit with GPG key verification
- Blacklisting the Nouveau driver
- Tracking progress phase-by-phase so re-runs resume from where they left off

It can be run standalone or called by `provision.sh` as part of a full multi-stage provisioning pipeline.

---

## Storage Architecture

A key design decision in this script is that Docker and containerd **share a single XFS volume**, rather than each consuming separate mounts. This means the full volume capacity is available to whichever runtime needs it at any given time — no pre-splitting required.

### Layout

```
/data/container-runtime/          ← XFS volume (single mount)
├── docker/                        ← Docker data root
│   ├── image/
│   ├── overlay2/
│   ├── volumes/
│   └── ...
└── containerd/                    ← containerd data root
    ├── io.containerd.snapshotter.v1.overlayfs/
    └── ...

/var/lib/docker      → /data/container-runtime/docker      (symlink)
/var/lib/containerd  → /data/container-runtime/containerd  (symlink)
```

Both Docker and containerd continue to reference their standard paths under `/var/lib/` — the symlinks make the redirection transparent to all tooling. The XFS volume is formatted with `reflink=1` (copy-on-write), which allows Docker's overlay2 driver to share unchanged file blocks between image layers, reducing both disk usage and copy time.

### Why XFS over ext4

| Feature | XFS | ext4 |
|---|---|---|
| Reflink (CoW layer dedup) | ✓ Yes (`-m reflink=1`) | ✗ No |
| Online grow (no unmount) | ✓ Yes | ✓ Yes |
| Large file performance | ✓ Better | Good |
| overlay2 support | ✓ Yes (ftype=1, default) | ✓ Yes |
| Metadata scaling | ✓ Better at scale | Adequate |

### fstab Entry

The volume is mounted by UUID (not device path) so it survives disk rename events across reboots. The `noatime` option skips access-time updates on every read, which meaningfully reduces I/O overhead for container workloads:

```
UUID=<uuid>  /data/container-runtime  xfs  defaults,noatime,nofail  0  2
```

---

## Requirements

| Requirement | Details |
|---|---|
| OS | Ubuntu 20.04, 22.04, or 24.04 |
| Privileges | Must be run as root (`sudo`) |
| Required tools | `curl`, `gpg`, `lsblk`, `df`, `awk`, `sed`, `python3` |
| Auto-installed | `xfsprogs` (if not present, installed automatically in Phase 1) |
| Recommended | `rsync` (used for data migration; falls back to `cp -ax` if absent) |
| Python | 3.6+ (used for JSON generation and log rotation) |
| Network | Outbound HTTPS to `download.docker.com`, `github.com`, `nvidia.github.io` |
| LVM tools | `vgs`, `vgdisplay`, `lvcreate` — only needed when using LVM storage |

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
| `--disk /dev/sdX` | Force use of a specific disk for the container runtime volume |
| `--vg <vgname>` | Force use of a specific LVM volume group for the container runtime volume |
| `--with-compose` | Also install Docker Compose v2 (latest stable, checksum-verified) |
| `--uninstall` | Full removal — Docker, toolkit, Compose, volume mounts, and symlinks |
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
        │       ├─► Required tool check (warns if rsync absent)
        │       └─► Existing Docker detection
        │
        ├─► PHASE 1: DISK_SETUP
        │       ├─► Check if /data/container-runtime already mounted → verify layout + skip format
        │       ├─► Auto-install xfsprogs if missing
        │       ├─► Scan for free disks (unpartitioned, unmounted)
        │       ├─► Scan for free LVM VG space
        │       ├─► Run storage decision tree (see below)
        │       ├─► Format selected device as XFS (reflink=1, ftype=1, noatime)
        │       ├─► Add UUID-based fstab entry (idempotent)
        │       ├─► Mount → /data/container-runtime
        │       ├─► Migrate existing data (if any) from /var/lib/docker and /var/lib/containerd
        │       └─► Create subdirs + place /var/lib symlinks (idempotent)
        │
        ├─► PHASE 2: DOCKER_INSTALL
        │       ├─► Add Docker APT repository + keyring
        │       ├─► Verify Docker GPG key fingerprint
        │       ├─► apt-get install docker-ce docker-ce-cli containerd.io
        │       ├─► Enable + start docker and containerd services
        │       └─► Add invoking user to docker group
        │
        ├─► PHASE 3: DAEMON_CONFIG
        │       ├─► Detect filesystem type on /data/container-runtime
        │       │     xfs / ext4 → overlay2  (xfs requires ftype=1, set at format time)
        │       │     btrfs      → btrfs
        │       │     zfs        → zfs
        │       ├─► Write /etc/docker/daemon.json (Python, guaranteed valid JSON)
        │       │     log-driver, log-opts, storage-driver
        │       │     data-root → /data/container-runtime/docker
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
        │       ├─► Check if already blacklisted → skip if so (idempotent)
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
                ├─► Volume usage + symlink targets
                └─► Phase state table
```

---

## Storage Decision Logic (Phase 1 — DISK_SETUP)

```
Is /data/container-runtime already mounted?
    YES → Verify docker/ and containerd/ subdirs exist
          Verify /var/lib symlinks are correct
          Skip format + mount → return
     NO ↓

Auto-install xfsprogs if mkfs.xfs not found

Are there any free disks? (no partitions, not mounted)
    YES →
        Non-interactive or --disk given:
            --disk specified → use that disk
            otherwise       → auto-select the largest free disk
        Interactive:
            Show numbered list of free disks + sizes
            User selects one (or skips to LVM check)
        → Format as XFS (reflink=1), mount, add to fstab by UUID
     NO ↓

Is there free space in any LVM VG?
    YES →
        Non-interactive or --vg given:
            --vg specified → use that VG
            otherwise      → auto-select VG with most free space
        Interactive:
            Show numbered list of VGs with free space and projected allocation
            User selects one (or skips to root fallback)
        → lvcreate using 80% of free VG extents
        → Format as XFS (reflink=1), mount, add to fstab by UUID
     NO ↓

No dedicated storage available:
    → Print warning + df -h /
    → Warn if root has < 10 GB free
    → Warn NOT recommended for GPU/ML workloads
    → Require explicit confirmation (or auto-confirm in non-interactive mode)
    → Create subdirs + symlinks under root (same layout, no separate volume)
```

After the volume is mounted (or root fallback confirmed), two additional steps always run:

### Data Migration

Before creating symlinks, the script checks whether `/var/lib/docker` or `/var/lib/containerd` already exist as real directories (not symlinks) with content. If they do, it migrates the data to the new volume before symlinking:

```
For each of /var/lib/docker and /var/lib/containerd:
    Is it a real directory (not a symlink) with content?
        YES →
            Stop docker and containerd services
            rsync -aHSx <source>/ → /data/container-runtime/<docker|containerd>/
              (-a: archive, -H: hard links, -S: sparse files, -x: single filesystem)
            Rename source to <path>.pre-migration.bak
        Is it empty?
            → Remove the empty directory (clean slate for symlink)
        Is it already a symlink?
            → Skip (already migrated)
```

The `.pre-migration.bak` directories are intentionally left on disk. Once you have confirmed the migration succeeded, they can be removed manually to reclaim root space.

### Symlink Setup

After migration, symlinks are created pointing into the shared volume. This step is idempotent — on re-runs it checks whether existing symlinks already point to the correct targets and only re-links if they have drifted:

```
mkdir -p /data/container-runtime/docker
mkdir -p /data/container-runtime/containerd
chmod 710 on both

/var/lib/docker     → /data/container-runtime/docker     (symlink)
/var/lib/containerd → /data/container-runtime/containerd (symlink)
```

### Storage Sizing

| Threshold | Action |
|---|---|
| Shared volume < 100 GB | Warning printed |
| Root free space < 10 GB | Warning printed |
| LVM allocation | 80% of free VG extents (`lvcreate -l 80%FREE`) |

The minimum is 100 GB (vs 50 GB in a Docker-only setup) because the volume serves both runtimes and GPU/ML base images are large.

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
  "data-root": "/data/container-runtime/docker",
  "default-runtime": "nvidia"
}
```

| Key | Value | Reason |
|---|---|---|
| `log-driver` | `json-file` | Standard, compatible with most log shippers |
| `log-opts.max-size` | `100m` | Prevents logs silently filling the volume |
| `log-opts.max-file` | `3` | Keeps last 300 MB of logs per container |
| `storage-driver` | `overlay2` | Correct for XFS with `ftype=1` (set at format time) |
| `data-root` | `/data/container-runtime/docker` | Explicit path to Docker's subdir on the shared volume |
| `default-runtime` | `nvidia` | Every container gets GPU access without `--gpus all` |

`data-root` points to the docker subdir on the shared volume, not the volume root — this keeps Docker's data cleanly separated from containerd's even though they share the same XFS filesystem.

`default-runtime` is only written if `nvidia-smi` is present and responding at config time. After the NVIDIA toolkit installs in Phase 5, the script patches it in via Python if it was absent earlier.

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

---

## NVIDIA Container Toolkit (Phase 5 — NVIDIA_TOOLKIT)

### Driver Pre-check

Before installing the toolkit, the script checks for `nvidia-smi`. If the driver is not present, a warning is written and in interactive mode you are asked whether to continue. In non-interactive mode installation proceeds with a warning. The toolkit installs successfully without the driver — GPU containers just won't work until the driver is loaded and the host is rebooted.

### GPG Key Verification

Both the Docker and NVIDIA APT repository GPG keys are fingerprint-verified after download. If the fingerprint does not match the value embedded in the script, the installation fails hard.

| Key | Expected Fingerprint |
|---|---|
| Docker | `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88` |
| NVIDIA | `EB69 3B30 35CD 5710 E231 7D3F 0402 5462 7A30 5A5C` |

### Architecture Fix

The NVIDIA repo list sometimes contains a literal `$(ARCH)` placeholder. The script detects this and replaces it with the output of `dpkg --print-architecture` — it never hardcodes `amd64`.

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

Simply re-run the script — completed phases are skipped, only the failed phase retries:

```bash
sudo /opt/provision/docker-install.sh --non-interactive
```

### Forcing a Full Re-run

```bash
sudo /opt/provision/docker-install.sh --reset-state --non-interactive
```

### Resetting a Single Phase

```bash
# Example: re-run only the NVIDIA_TOOLKIT phase
sed -i '/^NVIDIA_TOOLKIT=/d' /opt/provision/state/docker-install.state
sudo /opt/provision/docker-install.sh --non-interactive
```

---

## Logging

### Human-Readable Log

Located at `/opt/provision/logs/docker-install.log`. Each run appends a timestamped block. The script retains the **last 3 runs** automatically — the log will never grow unbounded.

```
===== docker-install.sh started at Thu Feb 27 10:23:01 UTC 2026 =====
[INFO]  Running in non-interactive mode
[OK]    OS: Ubuntu jammy
[INFO]  (auto) Selected largest free disk: /dev/sdb (500 GB)
[OK]    Mounted /dev/sdb → /data/container-runtime (XFS, reflink enabled)
[WARN]  Existing data found in /var/lib/docker (42 items) — migrating...
[OK]    Migrated /var/lib/docker → /data/container-runtime/docker
[OK]    Created symlink: /var/lib/docker → /data/container-runtime/docker
[OK]    Created symlink: /var/lib/containerd → /data/container-runtime/containerd
...
[OK]    docker-install.sh complete
```

### JSON Log

Located at `/opt/provision/logs/docker-install.jsonl`. Every log event is written as a JSON object (one per line), suitable for Loki, Elasticsearch, Splunk, or any structured log pipeline.

```json
{"ts":"2026-02-27T10:23:01Z","level":"info","phase":"INIT","host":"gpu-node-01","msg":"docker-install.sh started"}
{"ts":"2026-02-27T10:23:04Z","level":"info","phase":"DISK_SETUP","host":"gpu-node-01","msg":"(auto) Selected largest free disk: /dev/sdb (500 GB)"}
{"ts":"2026-02-27T10:23:12Z","level":"warn","phase":"DISK_SETUP","host":"gpu-node-01","msg":"Existing data found in /var/lib/docker (42 items) — migrating to /data/container-runtime/docker"}
{"ts":"2026-02-27T10:23:58Z","level":"success","phase":"DISK_SETUP","host":"gpu-node-01","msg":"Migrated /var/lib/docker → /data/container-runtime/docker (backup: /var/lib/docker.pre-migration.bak)"}
{"ts":"2026-02-27T10:24:15Z","level":"success","phase":"DOCKER_INSTALL","host":"gpu-node-01","msg":"Docker installed: Docker version 26.1.0"}
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

# Errors only, formatted
grep '"level":"error"' /opt/provision/logs/docker-install.jsonl | python3 -m json.tool
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
| Docker + NVIDIA APT repos and keyring files | `rm -f` |
| `/etc/docker/daemon.json` | `rm -f` |
| `/var/lib/docker` symlink | `rm -f` |
| `/var/lib/containerd` symlink | `rm -f` |
| `/data/container-runtime` mount | Unmounted |
| `/data/container-runtime` fstab entry | Removed from `/etc/fstab` |
| `/data/container-runtime` directory | `rm -rf` (all container data destroyed) |
| `/etc/docker` | `rm -rf` |
| `/etc/modprobe.d/blacklist-nouveau.conf` | `rm -f` |
| Phase state file | Deleted |

### What Is NOT Removed

- The underlying disk or LV — intentional. Wiping is a separate manual step to prevent accidental data loss.
- `.pre-migration.bak` directories — intentional. These are your safety net from the migration step. Remove manually once you have confirmed the original data is no longer needed.
- The docker system group.
- NVIDIA drivers — managed by `base-install.sh`, not this script.

A reboot is recommended after uninstall to cleanly unload kernel modules.

---

## Troubleshooting

### Checking What Failed

```bash
# Human log — last 50 lines
tail -50 /opt/provision/logs/docker-install.log

# All errors from JSON log, formatted
grep '"level":"error"' /opt/provision/logs/docker-install.jsonl | python3 -m json.tool

# Phase state
cat /opt/provision/state/docker-install.state
```

### Verifying the Volume Layout

```bash
# Confirm volume is mounted
mountpoint /data/container-runtime
df -h /data/container-runtime

# Confirm filesystem is XFS with reflink
xfs_info /data/container-runtime | grep -E 'reflink|ftype'
# Expected output includes: reflink=1, ftype=1

# Confirm symlinks
ls -la /var/lib/docker /var/lib/containerd
# Expected:
# /var/lib/docker -> /data/container-runtime/docker
# /var/lib/containerd -> /data/container-runtime/containerd
```

### Docker Fails to Start After Install

```bash
# Check daemon logs
journalctl -u docker --no-pager -n 50

# Validate daemon.json
python3 -c "import json; print(json.load(open('/etc/docker/daemon.json')))"

# Confirm data-root is correct
docker info | grep 'Docker Root Dir'
# Expected: /data/container-runtime/docker

# Restore daemon.json from backup if corrupt
sudo cp /etc/docker/daemon.json.bak /etc/docker/daemon.json
sudo systemctl restart docker
```

### Symlink Pointing to Wrong Location

```bash
# Check current symlink targets
readlink /var/lib/docker
readlink /var/lib/containerd

# Re-run disk setup phase to re-link correctly
sed -i '/^DISK_SETUP=/d' /opt/provision/state/docker-install.state
sudo /opt/provision/docker-install.sh --non-interactive
```

### Migration Backup Taking Up Root Space

```bash
# Verify migration succeeded first
ls /data/container-runtime/docker
ls /data/container-runtime/containerd

# Then remove backups
sudo rm -rf /var/lib/docker.pre-migration.bak
sudo rm -rf /var/lib/containerd.pre-migration.bak

# Confirm root space reclaimed
df -h /
```

### NVIDIA Runtime Not Working

```bash
# Verify toolkit installed
nvidia-ctk --version

# Check docker info for runtime
docker info | grep -i runtime

# Test GPU access
docker run --rm --gpus all nvidia/cuda:12.0-base-ubuntu22.04 nvidia-smi

# If nvidia runtime is missing, re-run Phase 5
sed -i '/^NVIDIA_TOOLKIT=/d' /opt/provision/state/docker-install.state
sudo /opt/provision/docker-install.sh --non-interactive
```

### Docker Compose Not Found After Install

```bash
ls -la /usr/local/lib/docker/cli-plugins/docker-compose
docker compose version

# Re-run compose phase only
sed -i '/^COMPOSE_INSTALL=/d' /opt/provision/state/docker-install.state
sudo /opt/provision/docker-install.sh --non-interactive --with-compose
```

### Container Runtime Volume Running Low on Space

```bash
# Current usage breakdown
df -h /data/container-runtime
docker system df

# Clean unused images, stopped containers, dangling volumes
docker system prune -af --volumes

# If on LVM, extend the volume online (XFS supports online grow — no unmount needed)
sudo lvextend -l +100%FREE /dev/ubuntu-vg/container_rt
sudo xfs_growfs /data/container-runtime
df -h /data/container-runtime
```

### GPG Key Fingerprint Mismatch

The key downloaded from the vendor CDN does not match the expected fingerprint embedded in the script. Do not proceed — this may indicate a compromised key or a MITM attack. Verify network security and compare the fingerprint against the official vendor documentation before continuing.

### Air-Gapped / No Internet Access

If outbound HTTPS is not available:

1. Set `http_proxy` / `https_proxy` to point to a local APT mirror before running
2. Pre-download packages and configure a local repository
3. For Compose, manually install and mark the phase complete:

```bash
# After manually placing the binary at the correct path
sed -i '/^COMPOSE_INSTALL=/d' /opt/provision/state/docker-install.state
echo "COMPOSE_INSTALL=complete" >> /opt/provision/state/docker-install.state
```

---

## Integration With provision.sh

When called by `provision.sh`, the script receives `--called-by-provision` (suppresses reboot prompts — the orchestrator manages reboot timing) and `--non-interactive`. Disk and VG selections passed to `provision.sh` are forwarded automatically.

The phase state file at `/opt/provision/state/docker-install.state` is read directly by `provision.sh --status`, so per-phase progress is always visible from the orchestrator level.

See `provisioning-guide.md` for the full multi-stage orchestration flow.
