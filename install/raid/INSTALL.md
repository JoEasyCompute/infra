# ESP Redundancy for mdadm RAID Boot Drives

Keeps the EFI System Partition (`/boot/efi`) replicated across all
drives in a software-RAID setup, so the box can boot from any surviving
drive after a failure.

## Preferred install path

From the repository root, run the optional installer:

```bash
sudo install/install-raid.sh
```

By default this only stages the helper scripts into `/usr/local/sbin`.
It does **not** install the apt hook or systemd units unless you pass
`--activate`, so non-RAID hosts remain unaffected.

To fully enable the lane on a RAID host:

```bash
sudo install/install-raid.sh --activate --bootstrap
```

## Files

| File | Destination | Mode |
|---|---|---|
| `sync-esp.sh` | `/usr/local/sbin/sync-esp.sh` | `0755` |
| `setup-esp-redundancy.sh` | `/usr/local/sbin/setup-esp-redundancy.sh` | `0755` |
| `99-sync-esp` | `/etc/apt/apt.conf.d/99-sync-esp` | `0644` |
| `sync-esp.service` | `/etc/systemd/system/sync-esp.service` | `0644` |
| `sync-esp.timer` | `/etc/systemd/system/sync-esp.timer` | `0644` |

If you are using the repository installer, the apt hook and systemd
units are only installed when you explicitly activate the lane.

## Install (run as root)

```bash
# 1. Drop the scripts and units into place
install -m 0755 sync-esp.sh             /usr/local/sbin/
install -m 0755 setup-esp-redundancy.sh /usr/local/sbin/
install -m 0644 99-sync-esp             /etc/apt/apt.conf.d/
install -m 0644 sync-esp.service        /etc/systemd/system/
install -m 0644 sync-esp.timer          /etc/systemd/system/

# 2. One-time: populate standby ESPs and add UEFI boot entries
/usr/local/sbin/setup-esp-redundancy.sh

# 3. Enable the weekly safety-net timer
systemctl daemon-reload
systemctl enable --now sync-esp.timer

# 4. Smoke-test the ongoing sync path
/usr/local/sbin/sync-esp.sh
journalctl -t sync-esp -n 20
```

## Verify

```bash
# All four UEFI boot entries should be present:
efibootmgr -v | grep -E 'ubuntu|Boot[0-9A-F]{4}\*'

# Timer is armed:
systemctl list-timers sync-esp.timer

# apt hook is wired:
apt-get -s install --reinstall hostname 2>&1 | grep -i sync-esp
```

## How it works

- **`sync-esp.sh`** finds every ESP on the system by partition type GUID,
  skips the currently mounted one, and rsyncs the live ESP to each.
  Idempotent; uses `flock` to prevent concurrent runs.
- **The apt hook** invokes `sync-esp.sh` after every dpkg operation, so
  any update to `grub-efi-amd64-signed`, `shim-signed`, etc. is mirrored
  to standby ESPs immediately.
- **The systemd timer** runs `sync-esp.sh` weekly as a belt-and-braces
  catch for anything the apt hook missed (e.g. a manual `grub-install`).
- **`setup-esp-redundancy.sh`** is the one-time bootstrap that both
  populates the standby ESPs and registers them with UEFI firmware via
  `efibootmgr`.

## Failure drill

To prove it works, after the initial setup:

1. From the live system: `efibootmgr -n XXXX` (where `XXXX` is the
   `ubuntu-disk2` BootNum) — boots from disk 2 on next boot only.
2. Reboot. System should come up from the standby ESP.
3. Set boot order back: `efibootmgr -o ORIG,SEQUENCE,HERE`.

For a full drill: physically pull the primary drive and verify the box
still boots. (Pick a maintenance window.)
