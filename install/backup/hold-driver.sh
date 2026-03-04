#!/bin/bash
sudo apt-mark hold nvidia-dkms-570-open nvidia-driver-570-open libnvidia-compute-570

# Freeze the stack on 580.65.06 until you plan an upgrade
sudo apt-mark hold nvidia-driver-580-open nvidia-dkms-580-open nvidia-kernel-source-580-open \
                   nvidia-kernel-common-580 libnvidia-*580 nvidia-*-580 xserver-xorg-video-nvidia-580
