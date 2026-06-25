# PCIe ASPM Policy Helper

`install/pcie-aspm.sh` is the standalone helper for the managed PCIe ASPM boot policy used by the base installers.

It manages one file only:

- `/etc/default/grub.d/99-infra-pcie-aspm.cfg`

That drop-in appends `pcie_aspm=off` to the boot command line. The helper does not edit `/etc/default/grub` directly.

## Usage

```bash
sudo bash install/pcie-aspm.sh --status
sudo bash install/pcie-aspm.sh --enable
sudo bash install/pcie-aspm.sh --disable
```

## Behavior

- `--status` reports whether the managed drop-in exists and whether the current boot cmdline already contains `pcie_aspm=off`
- `--enable` writes the managed drop-in and runs `update-grub`
- `--disable` removes the managed drop-in and runs `update-grub`
- changes only affect the next boot after `update-grub` completes

## Operator Notes

- This is a boot-policy helper, not a runtime ASPM tweak
- If you need the current boot to reflect a change, reboot after running the helper
- The base installers still apply the same managed policy during provisioning
