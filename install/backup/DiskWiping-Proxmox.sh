# Disk Wiping proxmox
for DEV in /dev/sdh; do
  # find any VGs that use this PV
  VGS=$(pvs --noheadings -o vg_name $DEV 2>/dev/null | awk 'NF' | sort -u)
  for VG in $VGS; do
    # remove all LVs in the VG, then the VG itself
    lvremove -ff -y $VG
    vgchange -an $VG
    vgremove -ff -y $VG
  done
  # remove PV label from the disk
  pvremove -ff -y $DEV || true

  # if anything still has it open, show it (useful for debugging)
  fuser -mv $DEV || true

  # finally wipe all filesystem/partition signatures
  wipefs -a $DEV
done
