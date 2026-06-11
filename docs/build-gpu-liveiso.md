# `install/build-gpu-liveiso.sh`

Builds a bootable live ISO directly from a mounted USB root filesystem.

This helper is standalone:

- it copies the mounted root filesystem from a USB root into `/srv/live-build/gpu-test-rootfs`
- it generalizes host-specific state such as machine-id, SSH host keys, logs, and shell history
- it refreshes the live boot stack inside a chroot
- it builds a SquashFS payload and stages a GRUB live layout
- it emits a bootable ISO under `/srv/iso/gpu-test.iso`

## Usage

```bash
sudo ./install/build-gpu-liveiso.sh /mnt/usbroot
```

If no argument is given, the script defaults to `/mnt/usbroot`.

You can also choose the SquashFS compressor or output path:

```bash
sudo COMPRESSOR=xz ./install/build-gpu-liveiso.sh /mnt/usbroot
sudo ./install/build-gpu-liveiso.sh --output /srv/iso/gpu-test.iso /mnt/usbroot
```

## Prerequisites

Run this as root on the build host.

The script expects:

- a mounted source root filesystem with `etc/` and `boot/`
- `grub-mkrescue`
- `xorriso`
- `rsync`
- `mksquashfs`
- `chroot`

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

- The generated live ISO boots via `casper`.
- The helper stages a minimal GRUB live layout under `/srv/live-build/gpu-test-iso-staging`.
- The resulting image is meant for bootable media, not for modifying the source USB root.
