# GPU Node Tools

Automation scripts for provisioning GPU compute nodes on Ubuntu 22.04/24.04.

## Scripts
- **install/base-install.sh**
  End-to-end setup: NVIDIA drivers, GPU Burn.
- **install/docker-install.sh**
  Docker disk provisioning, docker, nvidia container toolkit
- **install/install-p2p-driver.sh**
  Install Tinygrad P2P drivers (experiment)
- **test/fulltest.sh**
  full gpu test
- **test/disktest.sh**
  disk test

## Usage
```bash
