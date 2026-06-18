# `install/user-bootstrap.sh`

`install/user-bootstrap.sh` creates or updates a local user, installs an SSH public key into the user's `authorized_keys`, and grants passwordless sudo.

It is intended for initial account setup on a host where you want the new user to be able to log in over SSH and administer the machine immediately.

Repo-managed public keys live under [keys/bootstrap/](../keys/bootstrap). Use `--key-name <name>` to select one, or pass `--key-file` / `--key-text` directly.
Bootstrap mode has no hidden default key; one of those selectors is required. `--status` can still be used without a key selector to inspect the account state.

## Usage

```bash
sudo ./install/user-bootstrap.sh --list-keys
sudo ./install/user-bootstrap.sh --user ezc --key-name ezc
sudo ./install/user-bootstrap.sh --user alice --shell /bin/zsh --key-name alice
sudo ./install/user-bootstrap.sh --user ezc --key-file /path/to/id_ed25519.pub
sudo ./install/user-bootstrap.sh --user ezc --key-text "ssh-ed25519 AAAA... comment"
sudo ./install/user-bootstrap.sh --user ezc --status
```

## Options

- `--user <name>`: user to create or update
- `--shell <path>`: login shell for newly created users, default `/bin/bash`
- `--comment <text>`: GECOS/comment field for new users, default to the username
- `--key-name <name>`: repo-managed public key under `keys/bootstrap/<name>.pub`
- `--key-file <path>`: public key file to install
- `--key-text <text>`: public key text to install
- `--list-keys`: list repo-managed bootstrap keys and exit
- `--status`: inspect whether the user, sudo access, SSH key, and sudoers drop-in are present

`root` is intentionally not supported.

`--key-name`, `--key-file`, and `--key-text` are mutually exclusive. One of them is required for bootstrap mode.

## What It Changes

- creates the user if needed, or ensures the user is in the `sudo` group if already present
- creates `~/.ssh` with `0700` permissions
- installs `~/.ssh/authorized_keys` with `0600` permissions
- writes `/etc/sudoers.d/99-infra-<user>` with `NOPASSWD:ALL`
- validates the sudoers drop-in with `visudo -cf` before completing

## Notes

- The repo key library is intentionally public-key only.
- Existing authorized keys are preserved; the helper only appends missing key lines.
- If you stage the script outside the repo tree, copy `keys/bootstrap/` alongside it so `--key-name` can resolve correctly.
- For graphical autologin, use [autologin.md](autologin.md). For tty1 autologin, use [console-autologin.md](console-autologin.md).
