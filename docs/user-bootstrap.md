# `install/user-bootstrap.sh`

`install/user-bootstrap.sh` creates or updates a local user, installs an SSH public key into the user's `authorized_keys`, and grants passwordless sudo.

It is intended for initial account setup on a host where you want the new user to be able to log in over SSH and administer the machine immediately.

## Usage

```bash
sudo ./install/user-bootstrap.sh --user ezc
sudo ./install/user-bootstrap.sh --user alice --shell /bin/zsh
sudo ./install/user-bootstrap.sh --user ezc --key-file /path/to/id_ed25519.pub
sudo ./install/user-bootstrap.sh --user ezc --key-text "ssh-ed25519 AAAA... comment"
sudo ./install/user-bootstrap.sh --user ezc --status
```

## Options

- `--user <name>`: user to create or update
- `--shell <path>`: login shell for newly created users, default `/bin/bash`
- `--comment <text>`: GECOS/comment field for new users, default to the username
- `--key-file <path>`: public key file to install instead of the repo default key
- `--key-text <text>`: public key text to install instead of the repo default key
- `--status`: inspect whether the user, sudo access, SSH key, and sudoers drop-in are present

`root` is intentionally not supported.

`--key-file` and `--key-text` are mutually exclusive.

## What It Changes

- creates the user if needed, or ensures the user is in the `sudo` group if already present
- creates `~/.ssh` with `0700` permissions
- installs `~/.ssh/authorized_keys` with `0600` permissions
- writes `/etc/sudoers.d/99-infra-<user>` with `NOPASSWD:ALL`
- validates the sudoers drop-in with `visudo -cf` before completing

## Notes

- The default SSH key matches the repo's base-install access key.
- Existing authorized keys are preserved; the helper only appends missing key lines.
- For graphical autologin, use [autologin.md](autologin.md). For tty1 autologin, use [console-autologin.md](console-autologin.md).
