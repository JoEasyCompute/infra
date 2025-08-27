#!/bin/bash
# runpod installation procedure
# install ubuntu 22.04.5
sudo add-apt-repository ppa:graphics-drivers/ppa
sudo apt update
sudo apt install git apt-transport-https ca-certificates curl software-properties-common cmake build-essential dkms -y

# sudo apt purge '^nvidia.*' '^libnvidia.*' '^cuda.*'
# sudo apt autoremove
# sudo apt autoclean

# install nvidia keyring
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb

sudo apt install gcc-12 g++-12
sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 11
sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-11 11
sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 12
sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-12 12

sudo update-alternatives --config gcc  # Choose gcc-12
sudo update-alternatives --config g++  # Choose g++-12

# sudo apt install nvidia-driver-575-open nvidia-dkms-575-open nvidia-utils-575 -y
sudo apt -V -y install cuda-toolkit-12-9 libnvidia-compute-575 nvidia-dkms-575-open nvidia-utils-575 cudnn9-cuda-12


# update all packages
sudo apt-get update && sudo apt-get upgrade -y

# download latest & install nvidia driver
LATEST_VER=$(curl -s https://www.nvidia.com/Download/processFind.aspx | grep -oP '([0-9]{3}\.[0-9]{2}\.[0-9]{2})' | head -1) && \
wget -q https://us.download.nvidia.com/XFree86/Linux-x86_64/${LATEST_VER}/NVIDIA-Linux-x86_64-${LATEST_VER}.run && \
chmod +x NVIDIA-Linux-x86_64-${LATEST_VER}.run && \
sudo systemctl isolate multi-user.target && \
sudo ./NVIDIA-Linux-x86_64-${LATEST_VER}.run --silent --no-cc-version-check --disable-nouveau --dkms

#wget https://us.download.nvidia.com/XFree86/Linux-x86_64/575.64.05/NVIDIA-Linux-x86_64-575.64.05.run
#sudo sh NVIDIA-Linux-x86_64-575.64.05.run

# reboot once
sudo reboot now

# install kernel 6.8
sudo apt install --install-recommends linux-generic-hwe-22.04 -y

# reboot once
sudo reboot now

# create new volume for runpod-data
sudo lvcreate -L 3000G -n runpoddata ubuntu-vg

# mount more drive space
# sudo parted /dev/nvme1n1 mklabel gpt
# sudo parted -a optimal /dev/nvme1n1 mkpart primary 0% 100%
# sudo pvcreate /dev/nvme1n1p1
# sudo vgextend ubuntu-vg /dev/nvme1n1p1
# sudo lvcreate -l 100%FREE -n runpoddata ubuntu-vg

# sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv


