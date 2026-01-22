#!/bin/bash
sudo add-apt-repository ppa:graphics-drivers/ppa
sudo apt install git apt-transport-https ca-certificates curl software-properties-common cmake build-essential dkms alsa-utils gcc-12 g++-12 gnupg lsb-release ipmitool jq pciutils iproute2 util-linux dmidecode lshw coreutils chrony bpytop -y
sudo systemctl enable chrony --now
sudo apt install python3 python3-pip python3-venv -y

#install gcc and g++ to enable nvidia driver installation
sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 11
sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-11 11
sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 12
sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-12 12
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt-get update && sudo apt-get upgrade -y
sudo apt -V -y install cuda-toolkit-12-9 libnvidia-compute-580 nvidia-dkms-580-open cudnn9-cuda-12
sudo apt -V -y install nvtop

git clone https://github.com/wilicc/gpu-burn.git
# git clone https://github.com/jjziets/pytorch-benchmark-volta.git
cd gpu-burn
make
cd ~

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

sudo tee /etc/systemd/system/nvidia-runtime-policy.service > /dev/null <<'EOF'
[Unit]
Description=NVIDIA runtime policy (persistence + power cap)
After=multi-user.target
ConditionPathExists=/dev/nvidiactl


[Service]
Type=oneshot
ExecStart=/usr/bin/nvidia-smi -pm 1
ExecStart=/usr/bin/nvidia-smi -pl 540
RemainAfterExit=yes


[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable nvidia-runtime-policy.service
sudo systemctl restart nvidia-runtime-policy.service
