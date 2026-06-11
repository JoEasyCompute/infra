#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="gpu-test"
BUILD_BASE="/srv/live-build"
NETBOOT_BASE="/srv/netboot"

ROOTFS="${BUILD_BASE}/${IMAGE_NAME}-rootfs"
OUTDIR="${NETBOOT_BASE}/${IMAGE_NAME}"
CASPER_DIR="${OUTDIR}/casper"

COMPRESSOR="${COMPRESSOR:-zstd}"
USB_ROOT="/mnt/usbroot"

usage() {
  cat <<EOF
Usage: $0 [USB_ROOT]

Rebuild the ${IMAGE_NAME} live image from a mounted USB root filesystem.

Arguments:
  USB_ROOT   Mounted source root filesystem. Defaults to /mnt/usbroot.

Environment:
  COMPRESSOR  SquashFS compressor to use: zstd (default) or xz.

Output:
  ${BUILD_BASE}/${IMAGE_NAME}-rootfs
  ${NETBOOT_BASE}/${IMAGE_NAME}/casper/filesystem.squashfs
  ${NETBOOT_BASE}/${IMAGE_NAME}/vmlinuz
  ${NETBOOT_BASE}/${IMAGE_NAME}/initrd

Examples:
  sudo $0
  sudo $0 /mnt/usbroot
  sudo COMPRESSOR=xz $0 /mnt/usbroot
EOF
}

parse_args() {
  if [[ $# -gt 1 ]]; then
    fail "Too many arguments. Use --help for usage."
  fi

  if [[ $# -eq 1 ]]; then
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        fail "Unknown option: $1. Use --help for usage."
        ;;
      *)
        USB_ROOT="$1"
        ;;
    esac
  fi
}

log() {
  echo "[+] $*"
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    fail "Run as root."
  fi
}

check_usb_root() {
  [[ -d "$USB_ROOT" ]] || fail "USB root path does not exist: $USB_ROOT"
  [[ -d "$USB_ROOT/etc" ]] || fail "No /etc found under $USB_ROOT"
  [[ -d "$USB_ROOT/boot" ]] || fail "No /boot found under $USB_ROOT"
  compgen -G "$USB_ROOT/boot/vmlinuz-*" >/dev/null || fail "No kernel found under $USB_ROOT/boot"
  compgen -G "$USB_ROOT/boot/initrd.img-*" >/dev/null || fail "No initrd found under $USB_ROOT/boot"
}

install_prereqs_hint() {
  for cmd in rsync mksquashfs chroot; do
    command -v "$cmd" >/dev/null || fail "Missing command: $cmd. Install required packages first."
  done
}

cleanup_mounts() {
  set +e
  mountpoint -q "$ROOTFS/run"  && umount "$ROOTFS/run"
  mountpoint -q "$ROOTFS/sys"  && umount "$ROOTFS/sys"
  mountpoint -q "$ROOTFS/proc" && umount "$ROOTFS/proc"
  mountpoint -q "$ROOTFS/dev"  && umount "$ROOTFS/dev"
  set -e
}

copy_rootfs() {
  log "Creating clean rootfs workspace: $ROOTFS"
  rm -rf "$ROOTFS"
  mkdir -p "$ROOTFS"

  log "Copying USB root filesystem from $USB_ROOT"
  rsync -aAXH --numeric-ids \
    --exclude=/dev/* \
    --exclude=/proc/* \
    --exclude=/sys/* \
    --exclude=/run/* \
    --exclude=/tmp/* \
    --exclude=/mnt/* \
    --exclude=/media/* \
    --exclude=/lost+found \
    --exclude=/swapfile \
    --exclude=/var/tmp/* \
    --exclude=/var/cache/apt/archives/*.deb \
    "$USB_ROOT"/ "$ROOTFS"/
}

generalise_rootfs() {
  log "Generalising rootfs"

  rm -f "$ROOTFS/etc/machine-id"
  touch "$ROOTFS/etc/machine-id"
  rm -f "$ROOTFS/var/lib/dbus/machine-id"

  rm -f "$ROOTFS/etc/udev/rules.d/70-persistent-net.rules"
  rm -f "$ROOTFS/etc/ssh/ssh_host_"* || true

  rm -rf "$ROOTFS/var/log/journal/"* || true
  find "$ROOTFS/var/log" -type f -exec truncate -s 0 {} \; || true

  rm -rf "$ROOTFS/tmp/"* || true
  rm -rf "$ROOTFS/var/tmp/"* || true
  rm -f "$ROOTFS/root/.bash_history" || true
  rm -f "$ROOTFS/home/"*/.bash_history || true

  if [[ -f "$ROOTFS/etc/fstab" ]]; then
    cp "$ROOTFS/etc/fstab" "$ROOTFS/etc/fstab.original"
  fi

  cat >"$ROOTFS/etc/fstab" <<'EOF'
proc /proc proc defaults 0 0
tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0
EOF
}

prepare_chroot() {
  log "Mounting chroot bind paths"
  mount --bind /dev  "$ROOTFS/dev"
  mount --bind /proc "$ROOTFS/proc"
  mount --bind /sys  "$ROOTFS/sys"
  mount --bind /run  "$ROOTFS/run"

  log "Installing/refreshing live boot components inside chroot"
  chroot "$ROOTFS" /bin/bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y casper live-boot live-config initramfs-tools network-manager openssh-server
update-initramfs -u -k all

cat >/etc/systemd/system/regenerate-ssh-host-keys.service <<'"'"'EOF'"'"'
[Unit]
Description=Regenerate SSH host keys if missing
Before=ssh.service
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOF

systemctl enable regenerate-ssh-host-keys.service || true
'
}

build_squashfs() {
  log "Building SquashFS"

  mkdir -p "$CASPER_DIR"
  rm -f "$CASPER_DIR/filesystem.squashfs"

  case "$COMPRESSOR" in
    xz)
      mksquashfs "$ROOTFS" "$CASPER_DIR/filesystem.squashfs" \
        -comp xz -b 1M -noappend
      ;;
    zstd)
      mksquashfs "$ROOTFS" "$CASPER_DIR/filesystem.squashfs" \
        -comp zstd -Xcompression-level 15 -b 1M -noappend
      ;;
    *)
      fail "Unsupported COMPRESSOR=$COMPRESSOR. Use xz or zstd."
      ;;
  esac
}

copy_kernel_initrd() {
  log "Copying kernel and initrd"

  local latest_kernel
  local kver

  latest_kernel="$(ls "$ROOTFS"/boot/vmlinuz-* | sort -V | tail -1)"
  kver="$(basename "$latest_kernel" | sed 's/^vmlinuz-//')"

  [[ -f "$ROOTFS/boot/initrd.img-$kver" ]] || fail "Missing initrd for kernel $kver"

  mkdir -p "$OUTDIR"
  cp "$ROOTFS/boot/vmlinuz-$kver" "$OUTDIR/vmlinuz"
  cp "$ROOTFS/boot/initrd.img-$kver" "$OUTDIR/initrd"

  echo "$kver" > "$OUTDIR/kernel.version"

  log "Kernel version: $kver"
}

write_metadata() {
  log "Writing metadata"

  cat >"$OUTDIR/build-info.txt" <<EOF
Image name: $IMAGE_NAME
Built at: $(date -Is)
Source root: $USB_ROOT
Kernel: $(cat "$OUTDIR/kernel.version")
Compressor: $COMPRESSOR
SquashFS size: $(du -h "$CASPER_DIR/filesystem.squashfs" | awk '{print $1}')
EOF
}

print_result() {
  log "Build complete"
  echo
  cat "$OUTDIR/build-info.txt"
  echo
  echo "Files:"
  ls -lh "$OUTDIR" "$CASPER_DIR"
  echo
  echo "Example iPXE entry:"
  cat <<EOF
kernel http://PXE-SERVER/${IMAGE_NAME}/vmlinuz boot=casper netboot=url url=http://PXE-SERVER/${IMAGE_NAME}/casper/filesystem.squashfs ip=dhcp ---
initrd http://PXE-SERVER/${IMAGE_NAME}/initrd
boot
EOF
}

main() {
  parse_args "$@"
  need_root
  trap cleanup_mounts EXIT
  install_prereqs_hint
  check_usb_root
  copy_rootfs
  generalise_rootfs
  prepare_chroot
  cleanup_mounts
  build_squashfs
  copy_kernel_initrd
  write_metadata
  print_result
}

main "$@"
