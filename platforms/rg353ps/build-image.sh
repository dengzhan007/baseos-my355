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
ROOT_MIB=1280
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
  -v "$REPO_ROOT/assets":/assets:ro \
  -e BOOT_MIB="$BOOT_MIB" \
  -e ROOT_MIB="$ROOT_MIB" \
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

    # Keep the root filesystem bounded; partition 3 is the user area and
    # stays blank in the image so first boot can extend it to the physical TF card.
    sgdisk --clear \
      --new=1:32768:+${BOOT_MIB}M --typecode=1:0700 --change-name=1:BASEOS_BOOT \
      --new=2:0:+${ROOT_MIB}M --typecode=2:8300 --change-name=2:BASEOS_ROOT \
      --new=3:0:0 --typecode=3:0700 --change-name=3:BASEOS_DATA \
      --partition-guid=2:"$ROOT_PARTUUID" "$IMG"

    partition_value() {
      sgdisk --info="$1" "$IMG" | sed -n "s/^$2: *\\([0-9][0-9]*\\).*/\\1/p"
    }
    BOOT_START="$(partition_value 1 "First sector")"
    BOOT_END="$(partition_value 1 "Last sector")"
    ROOT_START="$(partition_value 2 "First sector")"
    ROOT_END="$(partition_value 2 "Last sector")"
    DATA_START="$(partition_value 3 "First sector")"
    DATA_END="$(partition_value 3 "Last sector")"
    [ -n "$BOOT_START" ] && [ -n "$ROOT_START" ] && [ -n "$DATA_START" ] || {
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
    # Runtime reads this same editable file; NextUI Bootlogo.pak can replace it.
    mcopy -i "$BOOTFS" /assets/bootlogo.bmp ::/bootlogo.bmp
    mcopy -o -i "$BOOTFS" /work/rootfs/etc/baseos.conf ::/baseos.conf

    cat > /tmp/extlinux.conf <<EOF
DEFAULT BaseOS-RG353PS
TIMEOUT 1
MENU HIDE
LABEL BaseOS-RG353PS
  MENU LABEL BaseOS RG353PS
  LINUX /Image
  FDT /device_trees/rk3566-anbernic-rg353ps.dtb
  APPEND root=PARTUUID=$ROOT_PARTUUID rootfstype=ext4 rootwait rw quiet loglevel=3 vt.global_cursor_default=0 cpufreq.default_governor=performance console=ttyS2,1500000n8 init=/sbin/init
EOF
    mcopy -i "$BOOTFS" /tmp/extlinux.conf ::/extlinux/extlinux.conf

    # Create ext4 directly from the staged root directory; partition 2 has a
    # fixed size so the remaining partition can be used for persistent userdata.
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
  "user_data_partition_number": 3,
  "user_data_partition_start_lba": "$DATA_START",
  "user_data_partition_initial_end_lba": "$DATA_END",
  "user_data_filesystem": "exFAT, initialized and expanded on first boot",
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
