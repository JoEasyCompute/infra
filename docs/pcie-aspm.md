# PCIe / NVMe Boot Policy Helper

`install/pcie-aspm.sh` is the standalone helper for the managed PCIe / NVMe boot policy used by the base installers.

It manages one file only:

- `/etc/default/grub.d/99-infra-pcie-aspm.cfg`

That drop-in appends `pcie_aspm=off`, `pci=noaer`, `pcie_aspm.policy=performance`, and `nvme_core.default_ps_max_latency_us=0` to the boot command line. The helper does not edit `/etc/default/grub` directly.

## Usage

```bash
sudo bash install/pcie-aspm.sh --status
sudo bash install/pcie-aspm.sh --enable
sudo bash install/pcie-aspm.sh --disable
```

## Behavior

- `--status` reports whether the managed drop-in exists and whether the current boot cmdline already contains the managed policy args
- `--enable` writes the managed drop-in and runs `update-grub`
- `--disable` removes the managed drop-in and runs `update-grub`
- changes only affect the next boot after `update-grub` completes

## Operator Notes

- This is a boot-policy helper, not a runtime ASPM tweak
- If you need the current boot to reflect a change, reboot after running the helper
- The base installers still apply the same managed policy during provisioning
