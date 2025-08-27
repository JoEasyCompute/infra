# Disk Wiping
for DEV in /dev/sdb /dev/sdc /dev/sdd /dev/sde /dev/sdf; do
  # find any VGs that use this PV
  VGS=$(sudo pvs --noheadings -o vg_name $DEV 2>/dev/null | awk 'NF' | sort -u)
  for VG in $VGS; do
    # remove all LVs in the VG, then the VG itself
    sudo lvremove -ff -y $VG
    sudo vgchange -an $VG
    sudo vgremove -ff -y $VG
  done
  # remove PV label from the disk
  sudo pvremove -ff -y $DEV || true

  # if anything still has it open, show it (useful for debugging)
  sudo fuser -mv $DEV || true

  # finally wipe all filesystem/partition signatures
  sudo wipefs -a $DEV
done
