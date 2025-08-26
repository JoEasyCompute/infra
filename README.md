# GPU Node Tools

Automation scripts for provisioning GPU compute nodes on Ubuntu 22.04/24.04.

## Scripts
- **install/installer.sh**
  End-to-end setup: autologin, passwordless sudo, NVIDIA drivers, Docker, GPU Burn.

## Usage
```bash
sudo ./install/installer.sh --user ezc --driver 580 --mode headless
