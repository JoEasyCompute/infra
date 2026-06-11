# `install/rebuild-gpu-livefs.sh`

Rebuilds the `gpu-test` live image from an already-installed USB root filesystem.

This is a host-side image build helper, not an in-place repair tool:

- it copies a mounted root filesystem from a USB root into `/srv/live-build/gpu-test-rootfs`
- it generalizes host-specific state such as machine-id, SSH host keys, logs, and shell history
- it refreshes the live boot stack inside a chroot
- it builds a SquashFS image under `/srv/netboot/gpu-test/casper/filesystem.squashfs`
- it copies the selected kernel and initrd into `/srv/netboot/gpu-test/`

## Usage

```bash
sudo ./install/rebuild-gpu-livefs.sh /mnt/usbroot
```

If no argument is given, the script defaults to `/mnt/usbroot`.

You can also choose the SquashFS compressor:

```bash
sudo COMPRESSOR=xz ./install/rebuild-gpu-livefs.sh /mnt/usbroot
```

Supported compressors:

- `zstd` (default)
- `xz`

## Prerequisites

Run this as root on the build host.

The script expects:

- a mounted source root filesystem with `etc/` and `boot/`
- `rsync`
- `mksquashfs`
- `chroot`

## Output

The script writes:

- rootfs workspace: `/srv/live-build/gpu-test-rootfs`
- netboot artifacts: `/srv/netboot/gpu-test/`
- SquashFS: `/srv/netboot/gpu-test/casper/filesystem.squashfs`
- metadata: `/srv/netboot/gpu-test/build-info.txt`

It also prints an example iPXE stanza that boots the generated image.

## Operational Notes

- The generated live image installs `casper`, `live-boot`, `live-config`, `initramfs-tools`, `network-manager`, and `openssh-server` inside the chroot before rebuilding initramfs.
- The script preserves the kernel/initrd pair from the source rootfs and selects the newest kernel version present there.
- If the source rootfs is not a valid installed system, the script stops before any image output is created.
- The live image name is currently fixed as `gpu-test`.
