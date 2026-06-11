#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="gpu-test"
BUILD_BASE="/srv/live-build"
NETBOOT_BASE="/srv/netboot"
ISO_BASE="/srv/iso"

DEFAULT_LIVE_TREE="${NETBOOT_BASE}/${IMAGE_NAME}"
STAGING_DIR="${BUILD_BASE}/${IMAGE_NAME}-iso-staging"
LIVE_TREE="${DEFAULT_LIVE_TREE}"
ISO_PATH="${ISO_PATH:-${ISO_BASE}/${IMAGE_NAME}.iso}"

usage() {
  cat <<EOF
Usage: $0 [--output ISO_PATH] [LIVE_TREE]

Convert a prepared live tree into a bootable live ISO.

The default LIVE_TREE is the output from rebuild-gpu-livefs.sh:
  ${DEFAULT_LIVE_TREE}

Options:
  -o, --output ISO_PATH   Destination ISO path (default: ${ISO_PATH})
  -h, --help              Show this help text

Environment:
  ISO_PATH                Alternate way to set the ISO output path.

Expected live tree layout:
  LIVE_TREE/casper/filesystem.squashfs
  LIVE_TREE/vmlinuz
  LIVE_TREE/initrd

Examples:
  sudo $0
  sudo $0 /srv/netboot/${IMAGE_NAME}
  sudo $0 --output /srv/iso/${IMAGE_NAME}.iso /srv/netboot/${IMAGE_NAME}
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
          LIVE_TREE="$1"
        fi
        break
        ;;
      -*)
        fail "Unknown option: $1. Use --help for usage."
        ;;
      *)
        if [[ "$LIVE_TREE" != "$DEFAULT_LIVE_TREE" ]]; then
          fail "Too many arguments. Use --help for usage."
        fi
        LIVE_TREE="$1"
        shift
        ;;
    esac
  done
}

install_prereqs_hint() {
  for cmd in grub-mkrescue xorriso rsync; do
    command -v "$cmd" >/dev/null || fail "Missing command: $cmd. Install required packages first."
  done
}

check_live_tree() {
  [[ -d "$LIVE_TREE" ]] || fail "Live tree path does not exist: $LIVE_TREE"
  [[ -f "$LIVE_TREE/casper/filesystem.squashfs" ]] || fail "Missing $LIVE_TREE/casper/filesystem.squashfs"
  [[ -f "$LIVE_TREE/vmlinuz" ]] || fail "Missing $LIVE_TREE/vmlinuz"
  [[ -f "$LIVE_TREE/initrd" ]] || fail "Missing $LIVE_TREE/initrd"
}

prepare_staging() {
  log "Creating staging tree: $STAGING_DIR"
  rm -rf "$STAGING_DIR"
  mkdir -p "$STAGING_DIR/boot/grub" "$STAGING_DIR/casper"

  log "Copying live tree payload"
  rsync -a "$LIVE_TREE/casper/" "$STAGING_DIR/casper/"
  cp -a "$LIVE_TREE/vmlinuz" "$STAGING_DIR/casper/vmlinuz"
  cp -a "$LIVE_TREE/initrd" "$STAGING_DIR/casper/initrd"
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
Live tree: $LIVE_TREE
ISO path: $ISO_PATH
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
  install_prereqs_hint
  check_live_tree
  prepare_staging
  write_grub_cfg
  build_iso
  write_metadata
  print_result
}

main "$@"
