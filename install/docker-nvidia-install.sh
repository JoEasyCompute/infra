#!/usr/bin/env bash
# docker-nvidia-setup.sh
# Install Docker + NVIDIA Container Toolkit on Ubuntu 22.04/24.04
# Safe to run as a regular user; uses sudo internally.
set -euo pipefail

log() { echo -e "[INFO] $*"; }
warn() { echo -e "[WARN] $*" >&2; }
err() { echo -e "[ERROR] $*" >&2; }

# Ensure sudo exists and we can prompt for password if needed
if ! command -v sudo >/dev/null 2>&1; then
  err "sudo is required. Please install sudo and add your user to sudoers."
  exit 1
fi

# Detect release
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
else
  err "Cannot detect OS release."
  exit 1
fi

if [[ "${ID:-}" != "ubuntu" ]]; then
  warn "This script targets Ubuntu. Detected ID='${ID:-unknown}'. Proceeding anyway..."
fi

UBU_VER="${VERSION_ID:-}"
case "$UBU_VER" in
  22.04|24.04) : ;;
  *)
    warn "Untested Ubuntu version '$UBU_VER'. Proceeding..."
    ;;
esac

USER_NAME="${SUDO_USER:-$USER}"
log "Running as user: $USER_NAME"

log "Installing prerequisites..."
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg lsb-release apt-transport-https software-properties-common

log "Setting up Docker repository..."
sudo install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
fi
echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

log "Installing Docker..."
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

log "Enabling & starting Docker service..."
sudo systemctl enable --now docker

log "Setting up NVIDIA Container Toolkit repository..."
distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
sudo install -m 0755 -d /usr/share/keyrings
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit.gpg
curl -fsSL "https://nvidia.github.io/libnvidia-container/${distribution}/libnvidia-container.list" \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

log "Installing NVIDIA Container Toolkit..."
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit

log "Configuring Docker to use NVIDIA runtime..."
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

log "Adding user '$USER_NAME' to 'docker' group (for passwordless docker)..."
sudo usermod -aG docker "$USER_NAME" || true

# Decide how to run docker for sanity check (group change doesn’t apply to current shell)
DOCKER_CMD="docker"
if ! id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx docker; then
  DOCKER_CMD="sudo docker"
fi

log "Running NVIDIA sanity test inside container (this may pull an image)..."
CUDA_IMG="nvidia/cuda:12.6.2-base-ubuntu22.04"
set +e
$DOCKER_CMD run --rm --gpus all "$CUDA_IMG" nvidia-smi
RC=$?
set -e

if [[ $RC -ne 0 ]]; then
  warn "Sanity test failed with exit code $RC."
  warn "If this is your first time using docker as a non-root user, log out/in or run: newgrp docker"
  warn "You can rerun the test with: $DOCKER_CMD run --rm --gpus all $CUDA_IMG nvidia-smi"
else
  log "Sanity test succeeded ✅"
fi

echo
echo "------------------------------------------------------------"
echo "SUCCESS: Docker + NVIDIA toolkit installed."
echo "- User '$USER_NAME' added to 'docker' group."
echo "- For non-sudo docker usage now, run:  newgrp docker"
echo "- Re-run sanity test: docker run --rm --gpus all $CUDA_IMG nvidia-smi"
echo "------------------------------------------------------------"
