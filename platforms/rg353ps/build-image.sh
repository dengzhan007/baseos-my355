#!/bin/sh
# Assemble a 2 GiB RG353PS first-boot smoke-test SD image.
# This writes a disk image file only; it never opens a physical block device.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
. "$REPO_ROOT/tools/common.sh"

WORK="${RG353PS_WORK:-$REPO_ROOT/work/rg353ps}"
KERNEL_OUT="$WORK/kernel/output"
KERNEL_META="$KERNEL_OUT/kernel-build.json"
ROOTFS="$WORK/rootfs"
UBOOT="$WORK/rg353ps-uboot.bin"
OUTPUT="$WORK/baseos-rg353ps-smoke.img"
BOOT_MIB=256
TOTAL_SIZE=2G
ROOT_PARTUUID="d462d29a-c5ca-4a4f-90c1-8d9423dd3535"

for cmd in docker python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing required command: $cmd" >&2; exit 1; }
done
[ -s "$UBOOT" ] || { echo "missing $UBOOT (run ./platforms/rg353ps/build-uboot.sh)" >&2; exit 1; }
[ -s "$KERNEL_OUT/Image" ] || { echo "missing kernel Image (run ./platforms/rg353ps/build-kernel.sh)" >&2; exit 1; }
[ -s "$KERNEL_OUT/rk3566-anbernic-rg353ps.dtb" ] || { echo "missing RG353PS Linux DTB" >&2; exit 1; }
[ -s "$KERNEL_META" ] || { echo "missing kernel metadata" >&2; exit 1; }
[ -x "$ROOTFS/usr/bin/busybox" ] || { echo "missing rootfs (run ./platforms/rg353ps/build-rootfs.sh)" >&2; exit 1; }

KREL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kernel_release"])' "$KERNEL_META")"
[ -d "$ROOTFS/lib/modules/$KREL" ] || { echo "rootfs has no matching modules for $KREL" >&2; exit 1; }

echo "== assembling RG353PS smoke-test image =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$WORK":/work \
  -e BOOT_MIB="$BOOT_MIB" \
  -e TOTAL_SIZE="$TOTAL_SIZE" \
  -e ROOT_PARTUUID="$ROOT_PARTUUID" \
  debian:bookworm-slim sh -euc '
    export DEBIAN_FRONTEND=noninteractive
    apt-get -qq update
    apt-get -qq install -y --no-install-recommends \
      gdisk dosfstools mtools e2fsprogs coreutils gzip util-linux

    IMG=/work/baseos-rg353ps-smoke.img
    BOOTFS=/work/boot-fat.img
    ROOTFS_IMG=/work/rootfs-ext4.img
    rm -f "$IMG" "$BOOTFS" "$ROOTFS_IMG" "$IMG.gz" "$IMG.sha256"
    truncate -s "$TOTAL_SIZE" "$IMG"

    # Rockchip IDB/SPL begins at LBA 64, and the U-Boot FIT begins at absolute
    # LBA 16384. Keep the first partition at LBA 32768 (16 MiB) or later.
    UBOOT_BYTES=$(stat -c %s /work/rg353ps-uboot.bin)
    UBOOT_LIMIT=$(( (32768 - 64) * 512 ))
    [ "$UBOOT_BYTES" -le "$UBOOT_LIMIT" ] || {
      echo "U-Boot region overlaps the first partition boundary" >&2
      exit 1
    }

    sgdisk --clear \
      --new=1:32768:+${BOOT_MIB}M --typecode=1:0700 --change-name=1:BASEOS_BOOT \
      --new=2:0:0 --typecode=2:8300 --change-name=2:BASEOS_ROOT \
      --partition-guid=2:"$ROOT_PARTUUID" "$IMG"

    partition_value() {
      sgdisk --info="$1" "$IMG" | sed -n "s/^$2: *\\([0-9][0-9]*\\).*/\\1/p"
    }
    BOOT_START="$(partition_value 1 "First sector")"
    BOOT_END="$(partition_value 1 "Last sector")"
    ROOT_START="$(partition_value 2 "First sector")"
    ROOT_END="$(partition_value 2 "Last sector")"
    [ -n "$BOOT_START" ] && [ -n "$ROOT_START" ] || {
      echo "unable to read partition boundaries from sgdisk" >&2
      exit 1
    }
    BOOT_BYTES=$(( (BOOT_END - BOOT_START + 1) * 512 ))
    ROOT_BYTES=$(( (ROOT_END - ROOT_START + 1) * 512 ))

    # FAT boot partition follows the ROCKNIX Generic extlinux layout.
    truncate -s "$BOOT_BYTES" "$BOOTFS"
    mkfs.vfat -F 32 -n BASEOS_BOOT "$BOOTFS"
    mmd -i "$BOOTFS" ::/extlinux
    mmd -i "$BOOTFS" ::/device_trees
    mcopy -i "$BOOTFS" /work/kernel/output/Image ::/Image
    mcopy -i "$BOOTFS" /work/kernel/output/rk3566-anbernic-rg353ps.dtb ::/device_trees/rk3566-anbernic-rg353ps.dtb

    cat > /tmp/extlinux.conf <<EOF
LABEL BaseOS-RG353PS
  MENU LABEL BaseOS RG353PS experimental bring-up
  LINUX /Image
  FDT /device_trees/rk3566-anbernic-rg353ps.dtb
  APPEND root=PARTUUID=$ROOT_PARTUUID rootfstype=ext4 rootwait rw console=tty0 console=ttyS2,1500000n8 loglevel=7 init=/sbin/init
EOF
    mcopy -i "$BOOTFS" /tmp/extlinux.conf ::/extlinux/extlinux.conf

    # Create ext4 directly from the staged root directory; no loop device or
    # mount is required, and the filesystem fills its GPT partition exactly.
    truncate -s "$ROOT_BYTES" "$ROOTFS_IMG"
    mkfs.ext4 -F -L BASEOS_ROOT -d /work/rootfs "$ROOTFS_IMG"

    # The combined bootloader is a raw region, never a full disk image. Place it
    # at LBA 64, then write filesystems into their GPT partition extents.
    dd if=/work/rg353ps-uboot.bin of="$IMG" bs=512 seek=64 \
      conv=notrunc,fsync status=none
    dd if="$BOOTFS" of="$IMG" bs=512 seek="$BOOT_START" \
      conv=notrunc,fsync status=none
    dd if="$ROOTFS_IMG" of="$IMG" bs=512 seek="$ROOT_START" \
      conv=notrunc,fsync status=none

    sgdisk --verify "$IMG"
    echo "Partition layout:"
    sgdisk --print "$IMG"
    cat > /work/image-build.json <<EOF
{
  "target": "Anbernic RG353PS",
  "image": "baseos-rg353ps-smoke.img.gz",
  "disk_size": "2 GiB",
  "bootloader_lba": 64,
  "boot_partition_start_lba": "$BOOT_START",
  "root_partition_start_lba": "$ROOT_START",
  "root_partition_guid": "$ROOT_PARTUUID",
  "purpose": "first-boot hardware bring-up",
  "finished_frontend": false,
  "hardware_tested": false
}
EOF
    gzip -1 -c "$IMG" > "$IMG.gz"
    cd /work
    sha256sum "$(basename "$IMG")" "$(basename "$IMG.gz")" > "$(basename "$IMG").sha256"
    echo "Created SD-card smoke-test image:"
    ls -lh "$IMG" "$IMG.gz" "$IMG.sha256" /work/image-build.json
  '

echo "Smoke-test image: $OUTPUT.gz"
echo "Checksum file: $OUTPUT.sha256"
echo "Use a spare SD card only; this is not the finished frontend build."
