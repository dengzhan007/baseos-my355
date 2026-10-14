#!/bin/sh
# Build the experimental RG353PS U-Boot bootloader region.
#
# This is NOT a complete SD-card image. It must not be flashed as one.
# Usage from repository root: ./platforms/rg353ps/build-uboot.sh
set -eu

PLATFORM_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$PLATFORM_DIR/../.." && pwd)"
HERE="$REPO_ROOT"
# shellcheck source=../../tools/common.sh
. "$REPO_ROOT/tools/common.sh"

UBOOT_VERSION="v2026.01"
UBOOT_SHA256="03bb43c58d2343ee48dd191e0f181f0108425b179d84519add3a977071c3f654"
UBOOT_URL="https://github.com/u-boot/u-boot/archive/refs/tags/$UBOOT_VERSION.tar.gz"
UBOOT_DEFCONFIG="anbernic-rgxx3-rk3566_defconfig"
RKBIN_REF="74213af1e952c4683d2e35952507133b61394862"
RKBIN_URL="https://github.com/rockchip-linux/rkbin.git"

WORK="${RG353PS_WORK:-$REPO_ROOT/work/rg353ps}"
TARBALL="$WORK/u-boot-$UBOOT_VERSION.tar.gz"
RKBIN_DIR="$WORK/rkbin"
PATCHSET="$WORK/patches.cat"

for cmd in curl git docker python3; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "missing required command: $cmd" >&2
    exit 1
  }
done

mkdir -p "$WORK"

if [ ! -f "$TARBALL" ] || [ "$(baseos_sha256 "$TARBALL")" != "$UBOOT_SHA256" ]; then
  echo "== downloading U-Boot $UBOOT_VERSION =="
  curl -fSL --retry 3 -o "$TARBALL.part" "$UBOOT_URL"
  got="$(baseos_sha256 "$TARBALL.part")"
  [ "$got" = "$UBOOT_SHA256" ] || {
    echo "U-Boot SHA-256 mismatch: expected $UBOOT_SHA256, got $got" >&2
    rm -f "$TARBALL.part"
    exit 1
  }
  mv "$TARBALL.part" "$TARBALL"
fi

if [ ! -d "$RKBIN_DIR/.git" ] ||
   [ "$(git -C "$RKBIN_DIR" rev-parse HEAD 2>/dev/null || true)" != "$RKBIN_REF" ]; then
  rm -rf "$RKBIN_DIR"
  git init "$RKBIN_DIR"
  git -C "$RKBIN_DIR" remote add origin "$RKBIN_URL"
  git -C "$RKBIN_DIR" fetch --depth 1 origin "$RKBIN_REF"
  git -C "$RKBIN_DIR" checkout --detach FETCH_HEAD
  [ "$(git -C "$RKBIN_DIR" rev-parse HEAD)" = "$RKBIN_REF" ] || {
    echo "failed to check out the pinned rkbin revision $RKBIN_REF" >&2
    exit 1
  }
fi

cat "$PLATFORM_DIR"/patches/*.patch > "$PATCHSET"
PATCH_SHA="$(baseos_sha256 "$PATCHSET")"

echo "== building RG353PS U-Boot ($UBOOT_DEFCONFIG) =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$WORK":/work \
  -v "$PLATFORM_DIR/patches":/patches:ro \
  -e UBOOT_VERSION="$UBOOT_VERSION" \
  -e UBOOT_DEFCONFIG="$UBOOT_DEFCONFIG" \
  -e PATCH_SHA="$PATCH_SHA" \
  debian:bookworm-slim sh -euc '
    export DEBIAN_FRONTEND=noninteractive
    apt-get -qq update
    apt-get -qq install -y --no-install-recommends \
      build-essential bc bison flex libssl-dev patch python3 python3-dev \
      python3-setuptools python3-pyelftools device-tree-compiler \
      libgnutls28-dev uuid-dev swig

    SRC="/work/build/u-boot-${UBOOT_VERSION#v}"
    mkdir -p /work/build
    if [ ! -d "$SRC" ] ||
       [ "$(cat /work/build/patches.sha256 2>/dev/null || true)" != "$PATCH_SHA" ]; then
      rm -rf "$SRC"
      tar -xf "/work/u-boot-$UBOOT_VERSION.tar.gz" -C /work/build
      for p in /patches/*.patch; do
        echo "  patch: $(basename "$p")"
        patch -p1 -d "$SRC" --batch --forward < "$p"
      done
      printf "%s\\n" "$PATCH_SHA" > /work/build/patches.sha256
    fi

    cd "$SRC"
    if [ "$(uname -m)" = aarch64 ]; then
      CROSS=""
    else
      CROSS=aarch64-linux-gnu-
      apt-get -qq install -y --no-install-recommends gcc-aarch64-linux-gnu
    fi

    BL31="/work/rkbin/bin/rk35/rk3568_bl31_v1.45.elf"
    DDR_BIN="/work/rkbin/bin/rk35/rk3568_ddr_1056MHz_v1.23.bin"
    test -s "$BL31"
    test -s "$DDR_BIN"

    export ARCH=arm64 CROSS_COMPILE="$CROSS" SOURCE_DATE_EPOCH=0
    make mrproper
    make LDFLAGS="" "$UBOOT_DEFCONFIG" u-boot.dtb u-boot.img tools
    make LDFLAGS="" BL31="$BL31" ROCKCHIP_TPL="$DDR_BIN" -j"$(nproc)"

    test -s spl/u-boot-spl.bin
    test -s u-boot.itb
    tools/mkimage -n rk3568 -T rksd \
      -d "$DDR_BIN:spl/u-boot-spl.bin" -C bzip2 idbloader.img

    # Match ROCKNIX rkhelper: SPL/DDR at LBA 0, FIT at LBA 16320.
    OUT=/work/rg353ps-uboot.bin
    rm -f "$OUT"
    dd if=idbloader.img of="$OUT" bs=512 seek=0 conv=notrunc status=none
    dd if=u-boot.itb of="$OUT" bs=512 seek=16320 conv=notrunc status=none
    cp u-boot.itb /work/rg353ps-u-boot.itb
    cp idbloader.img /work/rg353ps-idbloader.img
    sha256sum "$OUT" /work/rg353ps-u-boot.itb /work/rg353ps-idbloader.img > /work/rg353ps-uboot.sha256
    cat > /work/rg353ps-uboot.json <<EOF
{
  "target": "Anbernic RG353PS",
  "soc": "Rockchip RK3566",
  "u_boot_version": "$UBOOT_VERSION",
  "defconfig": "$UBOOT_DEFCONFIG",
  "rkbin_revision": "74213af1e952c4683d2e35952507133b61394862",
  "idbloader_lba": 0,
  "u_boot_fit_lba": 16320,
  "complete_sd_image": false,
  "hardware_tested": false
}
EOF
    echo "Built /work/rg353ps-uboot.bin (bootloader region only; not a card image)"
  '

echo
echo "Intermediate bootloader artifacts:"
for f in "$WORK/rg353ps-uboot.bin" "$WORK/rg353ps-u-boot.itb" "$WORK/rg353ps-idbloader.img" "$WORK/rg353ps-uboot.json" "$WORK/rg353ps-uboot.sha256"; do
  [ -f "$f" ] || { echo "missing expected output: $f" >&2; exit 1; }
  printf "  %-32s %s\\n" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
done
echo "WARNING: this is not a bootable BaseOS SD-card image. Do not flash it as one."
