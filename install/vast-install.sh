sudo lvcreate -l 100%FREE -n docker-lv ubuntu-vg
sudo mkfs.xfs -n ftype=1 /dev/ubuntu-vg/docker-lv
sudo mkdir -p /var/lib/docker
UUID=$(sudo blkid -s UUID -o value /dev/ubuntu-vg/docker-lv)
echo "UUID=$UUID /var/lib/docker xfs defaults,pquota 0 0" | sudo tee -a /etc/fstab >/dev/null
sudo mount -a
