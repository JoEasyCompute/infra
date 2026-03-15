# docker-install.sh — Reference Guide

## Overview

`docker-install.sh` is a production-grade installer for Docker CE and the NVIDIA Container Toolkit on Ubuntu systems. It is designed to be safe to run on fresh nodes, partially provisioned nodes, and nodes being reprovisioned — handling all of the following automatically:

- Provisioning a shared XFS volume (with reflink and project quota support) for both Docker and containerd
- Migrating any existing data before mounting, so re-provisioning never causes data loss
- Installing and configuring Docker CE with sensible production defaults
- Optionally installing Docker Compose v2 with checksum verification
- Installing the NVIDIA Container Toolkit with GPG key verification
- Blacklisting the Nouveau driver
- Tracking progress phase-by-phase so re-runs resume from where they left off

It can be run standalone or called by `provision.sh` as part of a full multi-stage provisioning pipeline.

---

## Storage Architecture

Docker and containerd **share a single XFS volume** rather than each consuming separate mounts. The full volume capacity is available to whichever runtime needs it at any given time — no pre-splitting required.

### Layout

```
/data/container-runtime/              ← XFS volume (single mount, prjquota)
├── docker/                            ← Docker data root
│   ├── image/
│   ├── overlay2/
│   ├── volumes/
│   └── ...
└── containerd/                        ← containerd data root
    ├── io.containerd.snapshotter.v1.overlayfs/
    └── ...

/var/lib/docker      ← bind mount → /data/container-runtime/docker
/var/lib/containerd  ← bind mount → /data/container-runtime/containerd
```

Both Docker and containerd reference their standard `/var/lib/` paths. The bind mounts make those paths genuine mountpoints at the kernel VFS level — not symlinks — which is required for correct operation with tools that perform atomic file operations (such as the vast.ai installer).

### Why Bind Mounts, Not Symlinks

An earlier version of this script used symlinks at `/var/lib/docker` and `/var/lib/containerd`. This caused failures with tools (including the vast.ai installer) that call `rename(2)` on those paths. The kernel rejects `rename()` when the path resolves through a symlink target directory, returning `EXDEV` or `EINVAL`. Bind mounts make the paths genuinely equivalent at the VFS layer, so `rename()` and all other syscalls work correctly regardless of which path is used.

Bind mount fstab entries are written alongside the XFS volume entry so both survive reboots:

**Real block device or LVM:**
```
# XFS volume (UUID-keyed — survives disk renames)
UUID=<uuid>  /data/container-runtime  xfs  defaults,noatime,nofail,prjquota  0  2

# Bind mounts — registered by _ensure_subdirs_and_bind_mounts
/data/container-runtime/docker      /var/lib/docker      none  bind,nofail  0  0
/data/container-runtime/containerd  /var/lib/containerd  none  bind,nofail  0  0
```

**Loopback image (root fallback):**
```
# Loop mount — kernel handles losetup automatically via the loop option
/var/lib/container-runtime.img  /data/container-runtime  xfs  loop,noatime,prjquota,nofail  0  0

# Bind mounts — written immediately after the loop entry, in fstab order
/data/container-runtime/docker      /var/lib/docker      none  bind,nofail  0  0
/data/container-runtime/containerd  /var/lib/containerd  none  bind,nofail  0  0
```

### Why XFS over ext4

| Feature | XFS | ext4 |
|---|---|---|
| Reflink (CoW layer dedup) | ✓ Yes (`-m reflink=1`) | ✗ No |
| Project quota (`prjquota`) | ✓ Yes | Limited |
| Online grow (no unmount) | ✓ Yes | ✓ Yes |
| Large file performance | ✓ Better | Good |
| overlay2 support | ✓ Yes (ftype=1, default) | ✓ Yes |

### XFS Mount Options

| Option | Purpose |
|---|---|
| `noatime` | Skip access-time updates on every read — reduces I/O overhead for container workloads |
| `nofail` | Don't halt boot if the volume is temporarily unavailable |
| `prjquota` | Enable XFS project quota support — required by vast.ai and Docker's `--storage-opt size=` feature |

If the script detects an existing fstab entry for the UUID that is **missing** `prjquota`, it patches it in automatically before mounting.

---

## Requirements

| Requirement | Details |
|---|---|
| OS | Ubuntu 20.04, 22.04, or 24.04 |
| Privileges | Must be run as root (`sudo`) |
| Required tools | `curl`, `gpg`, `lsblk`, `df`, `awk`, `sed`, `python3` |
| Auto-installed | `xfsprogs` (installed automatically in Phase 1 if missing) |
| Recommended | `rsync` (used for data migration; falls back to `cp -ax` if absent) |
| Python | 3.6+ (used for JSON generation and log rotation) |
| Network | Outbound HTTPS to `download.docker.com`, `github.com`, `nvidia.github.io` |
| LVM tools | `vgs`, `lvcreate` — only needed when using LVM storage |
| `util-linux` | `fallocate` — only needed for loopback image path (pre-installed on Ubuntu) |

---

## Installation

```bash
sudo mkdir -p /opt/provision
sudo cp install/docker-install.sh /opt/provision/
sudo chmod +x /opt/provision/docker-install.sh
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
| `--uninstall` | Full removal — Docker, toolkit, Compose, bind mounts, and volume |
| `--reset-state` | Clear phase state file and re-run all phases from scratch |
| `--skip-nvidia-toolkit` | Skip NVIDIA Container Toolkit install (useful on AMD hosts) |
| `--skip-nouveau-blacklist` | Skip Nouveau blacklist step (useful on AMD hosts) |
| `--called-by-provision` | Internal flag set by `provision.sh` — do not use manually |
| `-h, --help` | Show help and exit |

### Quick Examples

```bash
# Interactive install — prompts for disk/VG selection
sudo /opt/provision/docker-install.sh

# Fully automated
sudo /opt/provision/docker-install.sh --non-interactive

# Automated with Docker Compose
sudo /opt/provision/docker-install.sh --non-interactive --with-compose

# Automated, pin to a specific LVM VG
sudo /opt/provision/docker-install.sh --non-interactive --vg ubuntu-vg

# Automated, pin to a specific disk
sudo /opt/provision/docker-install.sh --non-interactive --disk /dev/sdb

# Force a complete re-run
sudo /opt/provision/docker-install.sh --reset-state --non-interactive

# Reuse on an AMD host
sudo /opt/provision/docker-install.sh --non-interactive --skip-nvidia-toolkit --skip-nouveau-blacklist

# Clean uninstall
sudo /opt/provision/docker-install.sh --uninstall
```

---

## Execution Flow

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
        │       ├─► Check if /data/container-runtime already mounted
        │       │     YES → verify bind mounts active + skip format
        │       ├─► Auto-install xfsprogs if missing
        │       ├─► Scan for free disks (unpartitioned, unmounted)
        │       ├─► Scan LVM VGs for free space (via vgs --units g)
        │       ├─► Run storage decision tree (see below)
        │       ├─► Format selected device/image: mkfs.xfs -m reflink=1 -i maxpct=25
        │       ├─► Mount now for this session
        │       ├─► Write fstab entries (in order):
        │       │     block/LVM: UUID=...  xfs  defaults,noatime,nofail,prjquota
        │       │     loopback:  /var/lib/container-runtime.img  xfs  loop,noatime,prjquota,nofail
        │       │     both:      bind entry for /var/lib/docker
        │       │                bind entry for /var/lib/containerd
        │       │     (prjquota patched into any pre-existing block device fstab entry)
        │       ├─► Migrate existing data from /var/lib/docker + /var/lib/containerd
        │       └─► Create subdirs + bind-mount both into /var/lib/ (idempotent)
        │               Converts any existing symlinks to bind mounts automatically
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
        │       │     data-root → /data/container-runtime/docker
        │       │     log-driver json-file, max-size 100m, max-file 3
        │       │     default-runtime: nvidia (only if nvidia-smi present)
        │       ├─► Validate JSON (python3 json.load)
        │       └─► Restart Docker
        │
        ├─► PHASE 4: COMPOSE_INSTALL  (skipped unless --with-compose)
        │       ├─► Query GitHub API for latest Compose version (fallback v2.27.1)
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
        │       ├─► Patch daemon.json → add default-runtime: nvidia
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
                ├─► Volume usage + bind mount sources
                └─► Phase state table
```

---

## Storage Decision Logic (Phase 1 — DISK_SETUP)

```
Is /data/container-runtime already mounted?
    YES → Verify bind mounts active at /var/lib/docker and /var/lib/containerd
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
        → mkfs.xfs with reflink=1
        → fstab entry with noatime,nofail,prjquota
     NO ↓

Is there free space in any LVM VG? (detected via vgs --units g)
    YES →
        Non-interactive or --vg given:
            --vg specified → use that VG
            otherwise      → auto-select VG with most free space
        Interactive:
            Show numbered list of VGs with free space and projected allocation
            User selects one (or skips to root fallback)
        → lvcreate using 80% of free VG extents
        → mkfs.xfs with reflink=1
        → fstab entry with noatime,nofail,prjquota
     NO ↓

No dedicated storage available — create loopback image on root:
    → Print warning + df -h /
    → Hard fail if root has < 20 GB free (not enough to create a usable image)
    → Compute image size = 80% of root free space (in whole GB)
    → Warn NOT recommended for production GPU/ML workloads
    → Require explicit confirmation (auto-confirm in non-interactive)
    → Call _provision_loopback_image <size_gb> (see below)
```

### Data Migration

Before setting up bind mounts, the script checks whether `/var/lib/docker` or `/var/lib/containerd` already exist as real directories with content. If they do:

```
For each of /var/lib/docker and /var/lib/containerd:

    Already a bind mountpoint?
        → Skip (already migrated and mounted)

    Real directory with content?
        → Stop docker and containerd services
        → rsync -aHSx <source>/ → /data/container-runtime/<subdir>/
            -a: archive mode   -H: hard links
            -S: sparse files   -x: stay on one filesystem
        → Rename source to <path>.pre-migration.bak
        (falls back to cp -ax if rsync is not installed)

    Empty directory?
        → Remove it (clean slate for bind mount)

    Existing symlink?
        → Remove it and replace with bind mount
```

The `.pre-migration.bak` directories are intentionally left on disk. Remove them manually once you have confirmed the new layout is working correctly.

### Loopback Image Provisioning (`_provision_loopback_image`)

Used only when no dedicated disk or LVM space is found. Provides the same XFS features and bind-mount layout as a real block device while keeping container data isolated from root.

**Sequence:**

```
1. fallocate -l <size>G /var/lib/container-runtime.img
     (fully pre-allocated — no sparse file; falls back to dd if fallocate
      is unsupported on the underlying filesystem)

2. chmod 600 /var/lib/container-runtime.img

3. mkfs.xfs -f -L container_rt -m reflink=1 -i maxpct=25 <image>
     (same XFS flags as a real block device: reflink + overlay2-safe ftype)

4. mount -o loop,noatime,prjquota <image> /data/container-runtime
     (kernel handles losetup automatically when it sees the loop option)

5. Write three fstab entries (in order):
     /var/lib/container-runtime.img  /data/container-runtime          xfs   loop,noatime,prjquota,nofail  0  0
     /data/container-runtime/docker  /var/lib/docker                  none  bind,nofail                   0  0
     /data/container-runtime/containerd  /var/lib/containerd          none  bind,nofail                   0  0

6. _migrate_existing_data               (same as real device path)

7. _ensure_subdirs_and_bind_mounts      (same as real device path)
```

**Why fstab works for loop mounts**

The kernel handles the `loop` fstab option natively — it allocates a loop device and calls `losetup` itself before mounting, so there is no need for a helper service or script. Boot-time ordering is guaranteed by the position of entries in fstab: the loop mount is written first, and the two bind mounts are appended directly after it by `_ensure_subdirs_and_bind_mounts`. The kernel processes fstab entries in order, so the bind source directories always exist before the bind mounts are attempted.

`nofail` is applied to all three entries so a missing image file does not block boot.

No systemd service or helper scripts are installed for the loopback path.

---

### Bind Mount Setup (`_ensure_subdirs_and_bind_mounts`)

After migration, bind mounts are created. This function is idempotent — safe to call on re-runs:

```
mkdir -p /data/container-runtime/docker      (chmod 710)
mkdir -p /data/container-runtime/containerd  (chmod 710)

For each (source → target) pair:
    If target is a symlink    → remove it, replace with bind mount
    If target already mounted → skip mount, verify fstab entry
    If target directory absent → mkdir, add fstab entry, mount --bind
```

### Storage Sizing

| Threshold | Action |
|---|---|
| Shared volume < 100 GB | Warning printed |
| Root free space < 20 GB | Hard fail — not enough space to create a loopback image |
| LVM allocation | 80% of free VG extents (`lvcreate -l 80%FREE`) |
| Loopback image size | 80% of root free space at time of provisioning |

---

## Docker Daemon Configuration (Phase 3 — DAEMON_CONFIG)

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
| `log-opts.max-size` | `100m` | Prevents container logs silently filling the volume |
| `log-opts.max-file` | `3` | Keeps last 300 MB of logs per container |
| `storage-driver` | `overlay2` | Correct for XFS with `ftype=1` (set at format time) |
| `data-root` | `/data/container-runtime/docker` | Docker's subdir on the shared volume |
| `default-runtime` | `nvidia` | Every container gets GPU access without `--gpus all` |

`default-runtime` is only written if `nvidia-smi` is present at config time. Phase 5 patches it in afterwards if it was absent.

---

## Docker Compose Install (Phase 4)

Queries the GitHub releases API for the latest stable version, falls back to `v2.27.1` if unreachable. Downloads the binary and its `.sha256` sidecar from the same release, verifies the checksum before installing. Hard fails if the checksum does not match.

| `dpkg --print-architecture` | GitHub release arch |
|---|---|
| `amd64` | `x86_64` |
| `arm64` | `aarch64` |
| `armhf` | `armv7` |

Install location: `/usr/local/lib/docker/cli-plugins/docker-compose`

---

## NVIDIA Container Toolkit (Phase 5)

Checks for `nvidia-smi` before proceeding — warns if absent but continues (toolkit installs cleanly without the driver; GPU containers won't work until after a reboot with the driver loaded). Both the Docker and NVIDIA APT repository GPG keys are fingerprint-verified before being trusted:

| Key | Expected Fingerprint |
|---|---|
| Docker | `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88` |
| NVIDIA | `EB69 3B30 35CD 5710 E231 7D3F 0402 5462 7A30 5A5C` |

Hard fails if either fingerprint doesn't match.

---

## Phase State & Resume

### State File — `/opt/provision/state/docker-install.state`

```
DISK_SETUP=complete
DOCKER_INSTALL=complete
DAEMON_CONFIG=complete
COMPOSE_INSTALL=complete
NVIDIA_TOOLKIT=failed
NOUVEAU_BLACKLIST=not run
```

| Status | Meaning on re-run |
|---|---|
| `complete` | Phase is skipped |
| `running` | Phase re-runs (script was killed mid-phase) |
| `failed` | Phase re-runs |
| *(absent)* | Phase runs normally |

### Resuming After a Failure

```bash
# Re-run — completed phases are skipped automatically
sudo /opt/provision/docker-install.sh --non-interactive

# Force full re-run from scratch
sudo /opt/provision/docker-install.sh --reset-state --non-interactive

# Re-run a single specific phase
sed -i '/^NVIDIA_TOOLKIT=/d' /opt/provision/state/docker-install.state
sudo /opt/provision/docker-install.sh --non-interactive
```

---

## Logging

### Human-Readable Log — `/opt/provision/logs/docker-install.log`

Retains the last 3 runs automatically. Example output:

```
===== docker-install.sh started at Thu Feb 27 10:23:01 UTC 2026 =====
[INFO]  Running in non-interactive mode
[OK]    OS: Ubuntu jammy
[INFO]  (auto) Selected VG with most free space: ubuntu-vg (3626 GB)
[OK]    Mounted /dev/ubuntu-vg/container_rt → /data/container-runtime (XFS, reflink enabled, prjquota)
[WARN]  Existing data found in /var/lib/docker (42 items) — migrating to /data/container-runtime/docker
[OK]    Migrated /var/lib/docker → /data/container-runtime/docker
[WARN]  /var/lib/docker is a symlink — removing and replacing with bind mount
[OK]    Bind-mounted: /data/container-runtime/docker → /var/lib/docker
[OK]    Bind-mounted: /data/container-runtime/containerd → /var/lib/containerd
```

### JSON Log — `/opt/provision/logs/docker-install.jsonl`

One JSON object per line. Fields: `ts` (ISO 8601 UTC), `level`, `phase`, `host`, `msg`.

```bash
# Tail live progress
tail -f /opt/provision/logs/docker-install.log

# All errors formatted
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
| `/etc/docker/daemon.json` + `/etc/docker` | `rm -f` / `rm -rf` |
| `/var/lib/docker` bind mount | Unmounted, fstab entry removed, directory removed |
| `/var/lib/containerd` bind mount | Unmounted, fstab entry removed, directory removed |
| `/data/container-runtime` XFS volume | Unmounted, fstab entry removed |
| `/data/container-runtime` directory | `rm -rf` (all container data destroyed) |
| `/etc/modprobe.d/blacklist-nouveau.conf` | `rm -f` |
| Phase state file | Deleted |

### What Is NOT Removed

- The underlying disk or LV — intentional. Wiping is a separate manual step.
- `.pre-migration.bak` directories — your safety net from the migration step.
- The docker system group.
- NVIDIA drivers — managed by `base-install.sh`.

> **Loopback uninstall note:** when the loopback path was used, `--uninstall` additionally removes `/var/lib/container-runtime.img` and its fstab entry. All container data in the image is destroyed. The kernel detaches the loop device automatically when the image file is removed.

---

## Troubleshooting

### Verifying the Full Storage Layout

```bash
# XFS volume mounted
mountpoint /data/container-runtime
df -h /data/container-runtime

# XFS features confirmed
xfs_info /data/container-runtime | grep -E 'reflink|ftype'
# Expected: reflink=1, ftype=1

# prjquota active
mount | grep container-runtime | grep prjquota

# Bind mounts active
mountpoint /var/lib/docker
mountpoint /var/lib/containerd

# Bind mount sources
findmnt /var/lib/docker
findmnt /var/lib/containerd
# Expected SOURCE: /data/container-runtime/docker (etc.)

# fstab entries
grep -E 'container-runtime|var/lib/docker|var/lib/containerd' /etc/fstab
```

### Docker Fails to Start After Install

```bash
journalctl -u docker --no-pager -n 50

# Validate daemon.json
python3 -c "import json; print(json.load(open('/etc/docker/daemon.json')))"

# Confirm data-root
docker info | grep 'Docker Root Dir'
# Expected: /data/container-runtime/docker

# Restore daemon.json from backup
sudo cp /etc/docker/daemon.json.bak /etc/docker/daemon.json
sudo systemctl restart docker
```

### Bind Mount Not Active After Reboot

If `/var/lib/docker` or `/var/lib/containerd` are not mounted after a reboot, the most likely cause is that `/data/container-runtime` didn't mount first (the XFS volume was slow to appear or missing). Check:

```bash
# Check XFS volume
mountpoint /data/container-runtime || sudo mount -a

# Re-run bind mounts if volume is now up
sudo mount --bind /data/container-runtime/docker    /var/lib/docker
sudo mount --bind /data/container-runtime/containerd /var/lib/containerd
sudo systemctl restart docker containerd

# Check fstab entries are present
grep 'bind' /etc/fstab
```

If this happens repeatedly, check `journalctl -b -u systemd-remount-fs` and ensure the XFS device is consistently visible at boot.

### Migration Backup Taking Up Root Space

```bash
# Confirm new layout is working first
docker info | grep 'Docker Root Dir'
findmnt /var/lib/docker

# Then remove backups
sudo rm -rf /var/lib/docker.pre-migration.bak
sudo rm -rf /var/lib/containerd.pre-migration.bak
df -h /
```

### Loopback Image Not Mounting After Reboot

If `/data/container-runtime` is not mounted after a reboot on a loopback node:

```bash
# Check what fstab has
grep 'container-runtime' /etc/fstab

# Attempt to mount everything in fstab (safe — skips already-mounted entries)
sudo mount -a

# If mount -a fails, check for errors
dmesg | grep -i 'loop\|container-runtime' | tail -20

# Manually mount if needed
sudo mount -o loop,noatime,prjquota /var/lib/container-runtime.img /data/container-runtime
sudo mount --bind /data/container-runtime/docker    /var/lib/docker
sudo mount --bind /data/container-runtime/containerd /var/lib/containerd
sudo systemctl restart docker containerd

# If the image file is missing — data is unrecoverable
ls -lh /var/lib/container-runtime.img
```

### Volume Running Low on Space

```bash
df -h /data/container-runtime
docker system df

# Clean up unused resources
docker system prune -af --volumes

# Extend online if on LVM (XFS supports online grow — no unmount needed)
sudo lvextend -l +100%FREE /dev/ubuntu-vg/container_rt
sudo xfs_growfs /data/container-runtime
df -h /data/container-runtime
```

### NVIDIA Runtime Not Working

```bash
nvidia-ctk --version
docker info | grep -i runtime
docker run --rm --gpus all nvidia/cuda:12.0-base-ubuntu22.04 nvidia-smi

# Re-run toolkit phase only
sed -i '/^NVIDIA_TOOLKIT=/d' /opt/provision/state/docker-install.state
sudo /opt/provision/docker-install.sh --non-interactive
```

### GPG Key Fingerprint Mismatch

Do not proceed — this may indicate a compromised key or MITM attack. Verify network security and check the fingerprint against the official vendor documentation before continuing.

### Air-Gapped Environments

Set `http_proxy` / `https_proxy` to a local APT mirror, or pre-configure a local repository. For Compose specifically, manually install the binary and mark the phase complete:

```bash
sed -i '/^COMPOSE_INSTALL=/d' /opt/provision/state/docker-install.state
echo "COMPOSE_INSTALL=complete" >> /opt/provision/state/docker-install.state
```

---

## Integration With provision.sh

When called by `provision.sh`, the script receives `--called-by-provision` (suppresses reboot prompts) and `--non-interactive`. Disk and VG selections are forwarded automatically from the top-level invocation.

After stage 2 completes, `provision.sh` verifies that `/data/container-runtime` is mounted and that both `/var/lib/docker` and `/var/lib/containerd` are active mountpoints before proceeding to stage 3 (`fulltest.sh`). If either bind mount is missing it hard-fails with a clear recovery message rather than silently running validation against the wrong storage.

See `provisioning-guide.md` for the full orchestration flow.
