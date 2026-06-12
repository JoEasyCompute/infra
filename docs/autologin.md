# `install/autologin.sh`

`install/autologin.sh` enables or disables graphical autologin for the current invoking user on the supported desktop managers:

- GDM3
- LightDM
- SDDM

It is intended for Ubuntu desktop-style hosts where you want the current sudo user to be logged in automatically after boot.

## Usage

```bash
sudo ./install/autologin.sh --enable
sudo ./install/autologin.sh --disable
sudo ./install/autologin.sh --status
```

## How It Picks The User

By default, the script uses the invoking `sudo` user:

- `SUDO_USER` when present
- otherwise `logname`
- or `--user <name>` if you want to override the detected account

`root` autologin is intentionally not supported.

## What It Changes

- GDM3: writes a managed block into `/etc/gdm3/custom.conf`
- LightDM: writes `/etc/lightdm/lightdm.conf.d/99-infra-autologin.conf`
- SDDM: writes `/etc/sddm.conf.d/99-infra-autologin.conf`

Disabling autologin removes the managed snippet or file again.

## Notes

- Changes take effect on the next graphical login or after a reboot.
- For console autologin on `tty1`, use [console-autologin.md](console-autologin.md).
