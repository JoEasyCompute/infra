# `install/build-gpu-liveiso.sh`

Converts a prepared live tree into a bootable live ISO.

This script is the companion to `install/rebuild-gpu-livefs.sh`:

- `rebuild-gpu-livefs.sh` builds the `gpu-test` live tree under `/srv/netboot/gpu-test/`
- `build-gpu-liveiso.sh` turns that tree into a bootable ISO image

## Usage

```bash
sudo ./install/build-gpu-liveiso.sh
```

By default, the script uses the live tree created by `rebuild-gpu-livefs.sh`:

```text
/srv/netboot/gpu-test
```

You can override the input tree or output path:

```bash
sudo ./install/build-gpu-liveiso.sh /srv/netboot/gpu-test
sudo ./install/build-gpu-liveiso.sh --output /srv/iso/gpu-test.iso /srv/netboot/gpu-test
```

## Prerequisites

Run this as root on the build host.

The script expects:

- a prepared live tree with `casper/filesystem.squashfs`, `vmlinuz`, and `initrd`
- `grub-mkrescue`
- `xorriso`
- `rsync`

## Output

The default ISO path is:

```text
/srv/iso/gpu-test.iso
```

The script also writes a small metadata file beside the ISO:

```text
/srv/iso/gpu-test.iso.build-info.txt
```

## Operational Notes

- The script stages a minimal GRUB live layout under `/srv/live-build/gpu-test-iso-staging`.
- The generated ISO boots the live image via `casper` and points GRUB at the staged kernel and initrd.
- The resulting image is meant for bootable media, not for modifying the source live tree.
