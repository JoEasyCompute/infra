# Bootstrap SSH Keys

This directory stores repo-managed **public** SSH keys used by `install/user-bootstrap.sh`.

Guidelines:

- Store public keys only.
- Name files `<key-name>.pub`.
- Pass the key with `--key-name <key-name>`.
- Use `--list-keys` to see the available names.

The helper does not use a silent default key. Operators must choose a key explicitly, or supply `--key-file` / `--key-text`.
