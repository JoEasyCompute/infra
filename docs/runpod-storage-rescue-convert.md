# Convert provisioned loop-image hosts to RunPod storage

Use [the rescue converter](../install/runpod-storage-rescue-convert.sh) for the
specific loop-image layout installed by `docker-install.sh`. The older
`docker-storage-layout-convert.sh` only rearranges mount paths and retains the
loop image; it does not meet RunPod's dedicated-LV requirement.

The reference host was inspected read-only over SSH on 2026-11-16. It has:

- EFI: 1 GiB; `/boot`: 2 GiB.
- `ubuntu-vg/ubuntu-lv`: approximately 3.64 TiB, ext4, mounted at `/`; no VG space free.
- `/var/lib/container-runtime.img`: 2.7 TiB logical XFS loop image, mounted at
  `/var/lib/docker`; the image consumes about 135 GiB of root disk blocks.
- Docker volume usage: about 164 GiB according to `df`; file allocation measured
  about 111 GiB. These figures can change with workloads.
- `/var/lib/docker/containerd` bound to `/var/lib/containerd`.
- Docker `overlay2` on XFS, metacopy disabled, user remapping enabled,
  NVIDIA runtime configured, and `live-restore` enabled.

This host needs an independent rescue boot. The script does not resize a live
root, stop workloads, change SSH keys, reboot, or enter rescue automatically.
There is no live conversion path for this disk layout.

## Prepare

1. Arrange a maintenance window and a provider rescue console. Shut down workloads
   cleanly, then shut down the installed OS. Because `live-restore` is enabled,
   stopping the Docker service alone does not establish that workloads stopped.
2. Take an independent root/system recovery backup or provider disk backup.
   The converter's backup covers container data and configuration, not every root
   file or the original disk image. Root shrinking is not automatically reversible.
3. Attach a separate physical backup disk with ext4 or XFS. Provision at least
   250 GiB **free** for the observed host, then recheck current usage. The script
   requires file allocation plus 20% and 1 GiB; a growing host may need more.
   It rejects backup storage on the root disk, loop devices, network mounts,
   and filesystems that cannot reliably preserve the required Linux metadata.
4. Copy the converter somewhere accessible from the rescue environment. If you
   store it on the installed root, copy it into the rescue filesystem before
   unmounting that root. Keep the backup disk mounted during the whole operation.

Optional live read-only report (after installing the script under `/opt/provision`):

```bash
sudo bash /opt/provision/runpod-storage-rescue-convert.sh \
  --root-lv /dev/ubuntu-vg/ubuntu-lv --check
```

This report lists devices; it does not certify that offline conversion can
succeed. Apply mode performs additional layout, filesystem, space, and backup
checks while in rescue.

## Run from rescue

Ensure the rescue system has Bash, Python 3, LVM2, e2fsprogs, xfsprogs, rsync
(with ACL/xattr support), and util-linux. Activate the existing VG if the rescue
system has not done so. Verify device identities with `lsblk`, `lvs`, and `vgs`.
Unmount the installed root and its boot mounts; disable rescue swap before apply.
The converter rejects any mounted root LV, including one auto-mounted by rescue.

Mount your independent backup disk at a path such as `/mnt/runpod-backup`.
Do not substitute the root disk or create a backup image on root. With the script
copied into the rescue environment, run:

```bash
sudo bash ./runpod-storage-rescue-convert.sh \
  --root-lv /dev/ubuntu-vg/ubuntu-lv --check

# This performs the conversion and removes the old loop image after backup.
sudo bash ./runpod-storage-rescue-convert.sh \
  --root-lv /dev/ubuntu-vg/ubuntu-lv \
  --backup-dir /mnt/runpod-backup \
  --apply
```

Apply mode:

1. Requires an unmounted, linear ext4 `ubuntu-lv` in a VG containing only that LV.
   Confirms the exact loop-image/containerd-bind source layout and standard
   Docker `overlay2` configuration. Refuses hidden data beneath runtime mounts.
2. Mounts the image read-only, copies its contents to a new external backup
   directory, preserving numeric IDs, hard links, ACLs, xattrs, and sparse files.
   A checksum/metadata dry run must report no differences before proceeding.
3. Saves fstab, Docker configuration, and LVM metadata in that backup directory.
   Checks projected root usage before deleting the image; checks actual usage
   afterward too. Leaves a 450 GiB usage ceiling before the shrink attempt.
4. Removes the verified image, checks ext4, shrinks the filesystem to 499 GiB,
   verifies its geometry, reduces the LV to 500 GiB, then expands ext4 to fill it.
   A filesystem-check or shrink failure prevents the subsequent LV reduction.
5. Creates `docker-lv` with `100%FREE`, formats it with
   `mkfs.xfs -n ftype=1`, restores the backup, and verifies the restored data.
6. Writes the new mount entries, preserving root/EFI/boot/swap entries:

   ```fstab
   UUID=<docker-lv UUID> /var/lib/docker xfs defaults,noatime,prjquota,nofail 0 0
   /var/lib/docker/containerd /var/lib/containerd none bind,nofail 0 0
   ```

   Sets Docker's base `data-root` to `/var/lib/docker` while preserving NVIDIA,
   user-remapping, logging, and other daemon settings. Under user remapping,
   `docker info` may report a subdirectory such as `/var/lib/docker/100000.100000`;
   this is expected.

EFI and `/boot` partitions and root's filesystem UUID are unchanged. Backups stay
on the external disk. No Docker commands or workload starts run from rescue.
The script exits and unmounts its own temporary mounts; it never reboots for you.

## Validate and retain the backup

After successful completion, boot the installed OS and run:

```bash
sudo lvs
findmnt /var/lib/docker
findmnt /var/lib/containerd
sudo xfs_info /var/lib/docker
sudo findmnt --verify
sudo docker info
sudo docker ps -a
nvidia-smi
```

Check 500 GiB root, a dedicated XFS `docker-lv`, `ftype=1`, `prjquota`, and the
UUID fstab entry. Test the expected containers, data volumes, remapped ownership,
GPU container operation, networking, and a further reboot before deleting any
external backup. The earlier acceptance results do not validate this migration.

File-level verification proves copied content and metadata match; it does not
prove every container can restart. Custom overlay features, Docker's containerd
snapshotter image store, and different source layouts need separate migration
review. The reference host's standard overlay2 setup is the intended target.

## If an operation fails

Do not blindly rerun, reformat, or reboot. Read the error and inspect `lvs`,
`lsblk`, the temporary mount paths, and the external backup. Cleanup attempts only
the script's mounts; a busy mount may remain and is reported.

- Before image deletion: original runtime image remains; investigate backup or
  preflight errors and leave the original OS disk intact.
- After image deletion: the external `runtime/` directory and config backups are
  the recovery source. The old fstab still references the image until the final
  stage, so the installed OS is not ready for normal boot yet.
- During root resizing: use the provider console and ext4/LVM recovery tools.
  Keep the full root/system recovery backup. Never reduce the LV if filesystem
  shrinking did not finish successfully.
- After LV creation or during restore: do not run the installer to reformat the
  new LV. Inspect its contents and restore from the retained external backup;
  finish fstab/daemon configuration only after the restore verifies.

`BACKUP-VERIFIED` records a completed external copy. `CONVERSION-COMPLETE`
records a completed restore/configuration pass; it does not replace reboot and
workload validation.

The offline shrink order follows the [resize2fs manual](https://man7.org/linux/man-pages/man8/resize2fs.8.html)
and [LVM lvreduce manual](https://man7.org/linux/man-pages/man8/lvreduce.8.html).
Copy/verification options follow the [upstream rsync manual](https://download.samba.org/pub/rsync/rsync.1.html).
Overlay migration limits are described in the [kernel OverlayFS documentation](https://docs.kernel.org/filesystems/overlayfs.html#changes-to-underlying-filesystems).
