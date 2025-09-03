#!/bin/bash
# auto login to tty1
# Make the logind settings robust to commented/uncommented defaults
sudo sed -i \
  -e 's/^[#]*NAutoVTs=.*/NAutoVTs=1/' \
  -e 's/^[#]*ReserveVT=.*/ReserveVT=2/' \
  /etc/systemd/logind.conf

# Ensure target user exists before enabling autologin
if ! id -u ezc >/dev/null 2>&1; then
  echo "User 'ezc' not found; please create it first." >&2
  exit 1
fi

sudo mkdir -p /etc/systemd/system/getty@tty1.service.d/
echo -e "[Service]\nExecStart=\nExecStart=-/sbin/agetty --noissue --autologin ezc %I \$TERM" | sudo tee /etc/systemd/system/getty@tty1.service.d/override.conf > /dev/null

# Apply changes immediately (optional if a reboot is planned)
sudo systemctl daemon-reload
sudo systemctl restart systemd-logind.service
sudo systemctl restart getty@tty1.service

# enable sudo without password for user ezc
if ! sudo grep -q "^ezc ALL=(ALL) NOPASSWD:ALL" /etc/sudoers.d/ezc; then
    sudo mkdir -p /etc/sudoers.d/
    sudo touch /etc/sudoers.d/ezc
fi
sudo chmod 0440 /etc/sudoers.d/ezc
# Add sudoers entry if not already present
sudo grep -q "^ezc ALL=(ALL) NOPASSWD:ALL" /etc/sudoers.d/ezc || \
    echo "ezc ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/ezc > /dev/null || \
    { echo "Failed to add sudoers entry"; exit 1; }

# Validate sudoers file and enforce permissions
sudo visudo -cf /etc/sudoers.d/ezc || { echo "Invalid sudoers file" >&2; exit 1; }
sudo chmod 0440 /etc/sudoers.d/ezc
