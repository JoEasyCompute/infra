# Repository Guidelines

## Project Structure & Module Organization
This repository is a GPU node provisioning suite centered on shell-first automation. Keep install flows in `install/`, validation scripts in `test/`, hardware inventory helpers in `gpucheck/`, monitoring utilities in `monitor/`, network helpers in `network/`, and long-form operator docs in `docs/`. Store legacy or one-off scripts in `install/backup/`; avoid adding new primary workflows there.

## Build, Test, and Development Commands
There is no single build system; contributors work directly with scripts.

- `chmod +x install/*.sh test/*.sh` — ensure scripts are executable before local runs.
- `bash -n install/provision.sh install/docker-install.sh test/fulltest.sh` — fast syntax check for Bash changes.
- `python3 -m py_compile monitor/calc_ipmi_energy.py test/network-batch.sh` — syntax check Python helpers.
- `./test/network-batch.sh --help` — safe smoke test for the orchestration helper.
- `sudo /opt/provision/provision.sh --status` — inspect orchestrated NVIDIA state on a provisioned host.
- `./test/fulltest.sh` / `./test/disktest.sh` / `./test/network-test.sh` — hardware validation runs; execute only on suitable hosts.

## Coding Style & Naming Conventions
Match the surrounding file style. Bash scripts use `#!/usr/bin/env bash`, `set -euo pipefail`, uppercase constants, and 4-space indentation inside functions and conditionals. Python helpers should target Python 3, use type hints where already present, and prefer `snake_case` for functions, variables, and filenames. Keep comments operational and concise. Reuse existing log helpers and status output patterns instead of inventing new ones.

## Testing Guidelines
Validate the smallest affected surface first: syntax checks, then the specific script's `--help`/`--status` path, then hardware-backed runs when needed. Place new test utilities under `test/` and name them for the behavior they verify (for example, `network-batch.sh`). Do not commit generated artifacts such as `test/build/`, `test/logs/`, `test/fulltest_*.log`, or local `.omx/` state.

## Commit & Pull Request Guidelines
Recent history uses short, direct subjects focused on the touched area. Keep new commit subjects imperative and specific (for example, `Document AMD provisioning recovery steps`). In pull requests, include: purpose, impacted paths, operator-visible changes, validation performed, and sample output or screenshots when logs/CLI behavior changed. Link related issues or host runbooks when available.

## Security & Configuration Tips
Treat host-specific IPs, inventory files, and provisioning state as sensitive operational data. Prefer redacted examples in docs, and keep environment-specific paths such as `/opt/provision` and `/opt/provision-amd` consistent with the current orchestration scripts.
