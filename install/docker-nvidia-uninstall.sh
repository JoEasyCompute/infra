#!/usr/bin/env bash
# docker-nvidia-uninstall.sh
# Uninstall NVIDIA Container Toolkit + Docker CE on Ubuntu.
# Safe to run as a regular user; uses sudo internally.
set -euo pipefail

log() { echo -e "[INFO] $*"; }
warn() { echo -e "[WARN] $*" >&2; }
err() { echo -e "[ERROR] $*" >&2; }

PURGE_DATA=0
if [[ "${1:-}" == "--purge-data" ]]; then
  PURGE_DATA=1
  warn "!!! --purge-data requested: /var/lib/docker and /var/lib/containerd will be DELETED."
fi

if ! command -v sudo >/dev/null 2>&1; then
  err "sudo is required. Please install sudo and add your user to sudoers."
  exit 1
fi

log "Stopping Docker services if running..."
sudo systemctl stop docker || true
sudo systemctl stop containerd || true

log "Removing NVIDIA Container Toolkit packages..."
sudo apt-get remove -y nvidia-container-toolkit || true
sudo apt-get autoremove -y || true

log "Removing Docker packages..."
sudo apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true
sudo apt-get autoremove -y || true

log "Removing apt sources & keyrings (Docker + NVIDIA)..."
sudo rm -f /etc/apt/sources.list.d/docker.list
sudo rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo rm -f /etc/apt/keyrings/docker.gpg
sudo rm -f /usr/share/keyrings/nvidia-container-toolkit.gpg

log "Reloading package lists..."
sudo apt-get update || true

if [[ $PURGE_DATA -eq 1 ]]; then
  warn "Purging container state & images under /var/lib/docker and /var/lib/containerd..."
  sudo rm -rf /var/lib/docker /var/lib/containerd
fi

log "Disabling leftover services (if any)..."
sudo systemctl disable docker || true
sudo systemctl disable containerd || true

echo
echo "------------------------------------------------------------"
echo "UNINSTALL COMPLETE."
if [[ $PURGE_DATA -eq 1 ]]; then
  echo "- Data directories were removed."
else
  echo "- Data directories were left intact (use --purge-data to remove)."
fi
echo "You can remove the 'docker' group manually if desired: sudo groupdel docker"
echo "------------------------------------------------------------"
