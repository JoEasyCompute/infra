#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="gpu-test"
BUILD_BASE="/srv/live-build"
ISO_BASE="/srv/iso"

DEFAULT_USB_ROOT="/mnt/usbroot"
ROOTFS="${BUILD_BASE}/${IMAGE_NAME}-rootfs"
STAGING_DIR="${BUILD_BASE}/${IMAGE_NAME}-iso-staging"
USB_ROOT="${DEFAULT_USB_ROOT}"
ISO_PATH="${ISO_PATH:-${ISO_BASE}/${IMAGE_NAME}.iso}"
COMPRESSOR="${COMPRESSOR:-zstd}"

usage() {
  cat <<EOF
Usage: $0 [--output ISO_PATH] [USB_ROOT]

Convert a mounted USB root filesystem into a bootable live ISO.

The default source root filesystem is:
  ${DEFAULT_USB_ROOT}

Options:
  -o, --output ISO_PATH   Destination ISO path (default: ${ISO_PATH})
  -h, --help              Show this help text

Environment:
  ISO_PATH                Alternate way to set the ISO output path.
  COMPRESSOR              SquashFS compressor to use: zstd (default) or xz.

Expected source tree layout:
  USB_ROOT/etc
  USB_ROOT/boot
  USB_ROOT/boot/vmlinuz-*
  USB_ROOT/boot/initrd.img-*

Examples:
  sudo $0
  sudo $0 /mnt/usbroot
  sudo COMPRESSOR=xz $0 /mnt/usbroot
  sudo $0 --output /srv/iso/${IMAGE_NAME}.iso /mnt/usbroot
EOF
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

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -o|--output)
        [[ $# -ge 2 ]] || fail "Missing value for $1."
        ISO_PATH="$2"
        shift 2
        ;;
      --output=*)
        ISO_PATH="${1#*=}"
        shift
        ;;
      --)
        shift
        [[ $# -le 1 ]] || fail "Too many arguments. Use --help for usage."
        if [[ $# -eq 1 ]]; then
          USB_ROOT="$1"
        fi
        break
        ;;
      -*)
        fail "Unknown option: $1. Use --help for usage."
        ;;
      *)
        if [[ "$USB_ROOT" != "$DEFAULT_USB_ROOT" ]]; then
          fail "Too many arguments. Use --help for usage."
        fi
        USB_ROOT="$1"
        shift
        ;;
    esac
  done
}

install_prereqs_hint() {
  for cmd in grub-mkrescue xorriso rsync mksquashfs chroot mountpoint; do
    command -v "$cmd" >/dev/null || fail "Missing command: $cmd. Install required packages first."
  done
}

check_usb_root() {
  [[ -d "$USB_ROOT" ]] || fail "USB root path does not exist: $USB_ROOT"
  [[ -d "$USB_ROOT/etc" ]] || fail "No /etc found under $USB_ROOT"
  [[ -d "$USB_ROOT/boot" ]] || fail "No /boot found under $USB_ROOT"
  compgen -G "$USB_ROOT/boot/vmlinuz-*" >/dev/null || fail "No kernel found under $USB_ROOT/boot"
  compgen -G "$USB_ROOT/boot/initrd.img-*" >/dev/null || fail "No initrd found under $USB_ROOT/boot"
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

cleanup_mounts() {
  set +e
  mountpoint -q "$ROOTFS/run"  && umount "$ROOTFS/run"
  mountpoint -q "$ROOTFS/sys"  && umount "$ROOTFS/sys"
  mountpoint -q "$ROOTFS/proc" && umount "$ROOTFS/proc"
  mountpoint -q "$ROOTFS/dev"  && umount "$ROOTFS/dev"
  set -e
}

prepare_staging() {
  log "Creating staging tree: $STAGING_DIR"
  rm -rf "$STAGING_DIR"
  mkdir -p "$STAGING_DIR/boot/grub" "$STAGING_DIR/casper"
}

write_grub_cfg() {
  cat >"$STAGING_DIR/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5
set timeout_style=menu

menuentry "${IMAGE_NAME} live ISO" {
    search --no-floppy --set=root --file /casper/filesystem.squashfs
    linux /casper/vmlinuz boot=casper live-media-path=/casper quiet splash ---
    initrd /casper/initrd
}
EOF
}

build_squashfs() {
  log "Building SquashFS"

  rm -f "$STAGING_DIR/casper/filesystem.squashfs"

  case "$COMPRESSOR" in
    xz)
      mksquashfs "$ROOTFS" "$STAGING_DIR/casper/filesystem.squashfs" \
        -comp xz -b 1M -noappend
      ;;
    zstd)
      mksquashfs "$ROOTFS" "$STAGING_DIR/casper/filesystem.squashfs" \
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

  cp -a "$ROOTFS/boot/vmlinuz-$kver" "$STAGING_DIR/casper/vmlinuz"
  cp -a "$ROOTFS/boot/initrd.img-$kver" "$STAGING_DIR/casper/initrd"

  echo "$kver" > "$STAGING_DIR/kernel.version"

  log "Kernel version: $kver"
}

build_iso() {
  mkdir -p "$(dirname "$ISO_PATH")"
  rm -f "$ISO_PATH"

  log "Building ISO: $ISO_PATH"
  grub-mkrescue -o "$ISO_PATH" "$STAGING_DIR" >/dev/null
}

write_metadata() {
  cat >"${ISO_PATH}.build-info.txt" <<EOF
Image name: $IMAGE_NAME
Built at: $(date -Is)
Source root: $USB_ROOT
ISO path: $ISO_PATH
Kernel: $(cat "$STAGING_DIR/kernel.version")
Compressor: $COMPRESSOR
SquashFS size: $(du -h "$STAGING_DIR/casper/filesystem.squashfs" | awk '{print $1}')
EOF
}

print_result() {
  log "Build complete"
  echo
  cat "${ISO_PATH}.build-info.txt"
  echo
  ls -lh "$ISO_PATH" "${ISO_PATH}.build-info.txt"
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
  prepare_staging
  build_squashfs
  copy_kernel_initrd
  write_grub_cfg
  build_iso
  write_metadata
  print_result
}

main "$@"
