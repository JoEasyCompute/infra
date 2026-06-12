# `install/console-autologin.sh`

`install/console-autologin.sh` enables or disables tty1 console autologin for the current invoking user on Ubuntu hosts.

It is the console counterpart to `install/autologin.sh`, which manages graphical login managers.

## Usage

```bash
sudo ./install/console-autologin.sh --enable
sudo ./install/console-autologin.sh --disable
sudo ./install/console-autologin.sh --status
```

## How It Picks The User

By default, the script uses the invoking `sudo` user:

- `SUDO_USER` when present
- otherwise `logname`
- or `--user <name>` if you want to override the detected account

`root` autologin is intentionally not supported.

## What It Changes

- `getty@tty1.service` gets a managed override in `/etc/systemd/system/getty@tty1.service.d/override.conf`
- systemd logind gets a managed drop-in in `/etc/systemd/logind.conf.d/99-infra-console-autologin.conf`

Disabling autologin removes both managed files again.

## Notes

- The script does not manage passwordless sudo.
- Changes take effect on the next reboot or the next tty1 getty restart.
- `install/super-ezc.sh` remains as a compatibility wrapper that enables tty1 autologin for `ezc`.

