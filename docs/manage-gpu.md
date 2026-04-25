# GPU Management Helper

[install/manage-gpu.sh](/Users/josephcheung/Desktop/dev/infra/install/manage-gpu.sh) installs an initramfs hook that binds selected NVIDIA GPU PCI slots to `vfio-pci` early in boot.

Use it when a host needs one or more GPUs hidden from the NVIDIA driver. Each selected GPU slot is applied as a pair:

```text
0000:25:00.0
0000:25:00.1
```

This matches GPUs that expose the main device on function `.0` and the paired audio/control function on `.1`.

## Interactive Use

```bash
sudo install/manage-gpu.sh
```

The script lists NVIDIA display/3D controllers detected by:

```bash
lspci -Dnn
```

Select one or more menu numbers to toggle those slots. Each row shows the current state and the result if that number is selected, for example `enabled now; select -> disable` or `disabled now; select -> enable`.

## Prerequisites

The helper uses standard Ubuntu tools: `bash`, `lspci`, `modprobe`, `update-initramfs`, and core utilities such as `awk`, `sed`, `sort`, `tee`, `install`, `readlink`, and `basename`.

[install/base-install.sh](/Users/josephcheung/Desktop/dev/infra/install/base-install.sh) already installs `pciutils`, which provides `lspci`. The remaining tools are part of a normal Ubuntu Server install or the `initramfs-tools`/`kmod` base packages.

## Non-Interactive Use

Disable one GPU slot:

```bash
sudo install/manage-gpu.sh --disable 25:00
```

Disable multiple GPU slots:

```bash
sudo install/manage-gpu.sh --disable 25:00,26:00
```

Enable a GPU again by removing it from the hook:

```bash
sudo install/manage-gpu.sh --enable 25:00
```

Preview without writing files:

```bash
install/manage-gpu.sh --dry-run --disable 25:00
```

Show detected GPUs and current selections:

```bash
install/manage-gpu.sh --list
```

## Files Changed On The Host

The script writes:

```text
/etc/initramfs-tools/scripts/init-top/vfio-bind-gpus
```

Then it runs:

```bash
update-initramfs -u
```

If all selected GPUs are enabled again, the generated hook is removed and initramfs is updated.

## Reboot Required

Changes take effect after reboot. The hook runs in initramfs before the normal NVIDIA driver bind path, sets `driver_override=vfio-pci`, unbinds any early driver attachment, and binds the selected device functions to `vfio-pci`.
