# Provisioning and reboot recovery

`install/provision.sh` orchestrates NVIDIA driver installation, Docker setup, and `fulltest.sh`. `install/provision-amd.sh` orchestrates AMDGPU/ROCm installation, Docker setup without NVIDIA phases, and AMD runtime validation. Both run on the target Ubuntu host as root.

## Deploy the complete bundle

From the repository root, for NVIDIA:

```bash
sudo mkdir -p /opt/provision
sudo cp install/base-install.sh install/docker-install.sh install/provision.sh \
    install/nvidia-stack-hold.sh test/fulltest.sh test/code.sh test/code.cu /opt/provision/
sudo chmod +x /opt/provision/*.sh
sudo /opt/provision/provision.sh --non-interactive --with-compose
```

The preflight requires executable base/Docker/fulltest/CUDA-wrapper scripts and readable `code.cu` before starting driver installation. Keep `code.cu` beside `code.sh`; a cached binary does not remove this deployment requirement.

For AMD:

```bash
sudo mkdir -p /opt/provision-amd
sudo cp install/amd-base-install.sh install/amd-stack-pin.sh \
    install/docker-install.sh install/provision-amd.sh /opt/provision-amd/
sudo chmod +x /opt/provision-amd/*.sh
sudo /opt/provision-amd/provision-amd.sh --non-interactive --with-compose
```

See [base-install.md](base-install.md), [amd-base-install.md](amd-base-install.md), [docker-install.md](docker-install.md), and [fulltest.md](fulltest.md) for stage-specific behavior.

## Saved options

Each provisioner maintains these files under its own `/opt/provision*/state/` directory:

| File | Purpose |
|---|---|
| `provision.state` | Stage progress |
| `provision.config` | Validated option values, atomically saved with mode `0600` |
| `docker-install.state` | Docker installer phase progress |
| `.provision_complete` | Prevents the resume service from rerunning a completed workflow |

Saved options cover non-interactive mode, Compose, disk or VG selection, RunPod storage layout, and GPU-stack freeze/unfreeze flags. The configuration is parsed as data rather than sourced as shell code. Each vendor's state directory is independent.

A subsequent invocation loads saved choices and applies explicitly supplied options over them. The boot service invokes `--resume --non-interactive`, preserving storage and feature choices while disabling prompts. `--status` does not replace saved configuration. GPU-stack flags affect stage 1; supplying a different option does not rerun an already completed stage.

`--reset-state` clears stage progress and starts configuration from defaults plus the flags on that invocation. Re-specify every desired option when resetting. Resetting is not required for ordinary recovery and does not authorize erasing existing storage.

For runs created before `provision.config` existed, the provisioner cannot reconstruct the original options. It warns and uses defaults plus supplied flags. Before allowing unattended recovery of a legacy run, supply its intended storage/layout/Compose options explicitly.

## Storage choices

Use either `--disk /dev/sdX` or `--vg <name>`, never both. Explicit choices precede automatic selection; an unavailable or unsafe selection fails instead of silently switching to another device.

```bash
sudo /opt/provision/provision.sh --non-interactive --vg ubuntu-vg --with-compose
sudo /opt/provision-amd/provision-amd.sh --non-interactive --disk /dev/sdb --runpod-storage-layout
```

The disk must pass the Docker installer's blank-device checks. Existing filesystems, partitions, mount use, storage holders, and signatures are not evidence of free capacity. See [docker-install.md](docker-install.md) for reuse and recovery limitations.

## Recover a failed stage

```bash
sudo /opt/provision/provision.sh --status
sudo /opt/provision/provision.sh --resume
# AMD equivalents:
sudo /opt/provision-amd/provision-amd.sh --status
sudo /opt/provision-amd/provision-amd.sh --resume
```

Inspect `logs/provision.log`, `logs/provision.jsonl`, and the underlying stage logs in the matching runtime directory. Repair the reported prerequisite and resume. Completed stages remain skipped. If a missing-source error is reported, copy `test/code.cu` beside the NVIDIA runtime's `code.sh` before resuming.

A requested reboot ends the current script invocation; the resume service continues after boot. On completion, the provisioner creates the completion sentinel and removes/disables its resume service.

For intentional full reconfiguration, provide a complete new option set:

```bash
sudo /opt/provision/provision.sh --reset-state --non-interactive --vg ubuntu-vg --with-compose
```

A signed disk or an existing unmounted runtime LV is not reformatted automatically to make a reset succeed. Inspect and restore the intended storage mount, then resume; use the layout converter for an existing Docker volume rather than reinstalling to change its layout.

## Development verification

From the repository root:

```bash
bash test/provision-resume-test.sh
bash test/code-wrapper-test.sh
bash test/docker-storage-safety-test.sh
bash test/docker-storage-convert-test.sh
```

These tests use temporary fixtures and mocked host commands. Real reboot, service, mount, driver, and GPU validation still requires a suitable Ubuntu node.
