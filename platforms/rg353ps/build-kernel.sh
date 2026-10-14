#!/bin/sh
# Build a ROCKNIX-derived Linux kernel/DTB/modules set for RG353PS.
#
# This is an intermediate kernel bundle, NOT a complete BaseOS image.
# It does not flash media or touch the handheld's internal storage.
set -eu

PLATFORM_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$PLATFORM_DIR/../.." && pwd)"
HERE="$REPO_ROOT"
# shellcheck source=../../tools/common.sh
. "$REPO_ROOT/tools/common.sh"

KERNEL_VERSION="7.2.7"
KERNEL_SHA256="4ac34c47db2540ffb2713943f8d891ff1702e0ba6934525a493b7d1cad43145a"
KERNEL_URL="https://www.kernel.org/pub/linux/kernel/v7.x/linux-${KERNEL_VERSION}.tar.xz"
KERNEL_RELEASE_SUFFIX="-baseos-rg353ps"
ROCKNIX_REF="becc8cb2a97b8b44b25d39dd5b6aa8f77b0af1c5"

WORK="${RG353PS_KERNEL_WORK:-$REPO_ROOT/work/rg353ps/kernel}"
TARBALL="$WORK/linux-${KERNEL_VERSION}.tar.xz"
PATCHSET="$WORK/patches.rg353ps"
INPUT_KEY_FILE="$WORK/inputs.sha256"
OUTPUT="$WORK/output"

for cmd in curl docker; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "missing required command: $cmd" >&2
    exit 1
  }
done

mkdir -p "$WORK" "$OUTPUT"

if [ ! -f "$TARBALL" ] || [ "$(baseos_sha256 "$TARBALL")" != "$KERNEL_SHA256" ]; then
  echo "== downloading Linux $KERNEL_VERSION =="
  rm -f "$TARBALL.part"
  curl -fL --retry 3 -o "$TARBALL.part" "$KERNEL_URL"
  got="$(baseos_sha256 "$TARBALL.part")"
  [ "$got" = "$KERNEL_SHA256" ] || {
    echo "Linux source SHA-256 mismatch: expected $KERNEL_SHA256, got $got" >&2
    rm -f "$TARBALL.part"
    exit 1
  }
  mv "$TARBALL.part" "$TARBALL"
fi

# Keep patch application order aligned with ROCKNIX's kernel package:
# RK3566 device patches, then RK3566/Rockchip RK817 power-supply patches.
cat "$PLATFORM_DIR"/kernel/patches/rk3566/*.patch \
    "$PLATFORM_DIR"/kernel/patches/mainline-rockchip/*.patch > "$PATCHSET"
PATCH_SHA="$(baseos_sha256 "$PATCHSET")"
CONFIG_SHA="$(baseos_sha256 "$PLATFORM_DIR/kernel/config/linux.aarch64.conf")"
printf '%s\n%s\n%s\n%s\n' "$KERNEL_VERSION" "$ROCKNIX_REF" "$PATCH_SHA" "$CONFIG_SHA" > "$INPUT_KEY_FILE"
INPUT_KEY="$(baseos_sha256 "$INPUT_KEY_FILE")"

echo "== building Linux $KERNEL_VERSION for RG353PS =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$WORK":/work \
  -v "$PLATFORM_DIR/kernel":/inputs:ro \
  -e KERNEL_VERSION="$KERNEL_VERSION" \
  -e KERNEL_RELEASE_SUFFIX="$KERNEL_RELEASE_SUFFIX" \
  -e INPUT_KEY="$INPUT_KEY" \
  -e PATCH_SHA="$PATCH_SHA" \
  -e CONFIG_SHA="$CONFIG_SHA" \
  -e ROCKNIX_REF="$ROCKNIX_REF" \
  debian:bookworm-slim sh -euc '
    export DEBIAN_FRONTEND=noninteractive
    apt-get -qq update
    apt-get -qq install -y --no-install-recommends \
      build-essential bc bison flex libssl-dev libelf-dev libncurses-dev \
      device-tree-compiler rsync kmod dwarves python3 python3-dev xz-utils zstd \
      ca-certificates

    if [ "$(uname -m)" = aarch64 ]; then
      CROSS=""
    else
      CROSS=aarch64-linux-gnu-
      apt-get -qq install -y --no-install-recommends gcc-aarch64-linux-gnu
    fi

    SRC="/work/src/linux-$KERNEL_VERSION"
    OUT="/work/output"
    mkdir -p /work/src "$OUT"

    if [ ! -d "$SRC" ] ||
       [ "$(cat "$SRC/.baseos-rg353ps-input-key" 2>/dev/null || true)" != "$INPUT_KEY" ]; then
      rm -rf "$SRC"
      tar -xf "/work/linux-$KERNEL_VERSION.tar.xz" -C /work/src
      test -f "$SRC/Makefile" || {
        echo "unexpected Linux source archive layout" >&2
        exit 1
      }

      for patch_file in /inputs/patches/rk3566/*.patch; do
        echo "  patch: RK3566/$(basename "$patch_file")"
        patch -s -p1 -d "$SRC" --batch --forward < "$patch_file"
      done
      for patch_file in /inputs/patches/mainline-rockchip/*.patch; do
        echo "  patch: mainline-rockchip/$(basename "$patch_file")"
        patch -s -p1 -d "$SRC" --batch --forward < "$patch_file"
      done

      cp /inputs/config/linux.aarch64.conf "$SRC/.config"
      cd "$SRC"
      ./scripts/config --set-str CONFIG_DEFAULT_HOSTNAME "BaseOS-RG353PS"
      ./scripts/config --set-str CONFIG_LOCALVERSION "$KERNEL_RELEASE_SUFFIX"
      # ROCKNIX injects its own initramfs path at package-build time. BaseOS
      # boots from its SD-card root partition, so never leave the placeholder.
      ./scripts/config --set-str CONFIG_INITRAMFS_SOURCE ""
      # Avoid embedding debug symbols into the intermediate kernel/modules.
      ./scripts/config --disable CONFIG_DEBUG_INFO
      ./scripts/config --disable CONFIG_DEBUG_INFO_DWARF5
      ./scripts/config --disable CONFIG_DEBUG_INFO_BTF
      ./scripts/config --disable CONFIG_DEBUG_INFO_BTF_MODULES
      export ARCH=arm64 CROSS_COMPILE="$CROSS" SOURCE_DATE_EPOCH=0
      make olddefconfig
      printf "%s\n" "$INPUT_KEY" > "$SRC/.baseos-rg353ps-input-key"
    fi

    cd "$SRC"
    export ARCH=arm64 CROSS_COMPILE="$CROSS" SOURCE_DATE_EPOCH=0
    export KBUILD_BUILD_USER=baseos KBUILD_BUILD_HOST=rg353ps
    make -j"$(nproc)" Image dtbs modules

    DTB="$SRC/arch/arm64/boot/dts/rockchip/rk3566-anbernic-rg353ps.dtb"
    test -s "$SRC/arch/arm64/boot/Image" || {
      echo "kernel Image was not produced" >&2
      exit 1
    }
    test -s "$DTB" || {
      echo "RG353PS DTB missing: $DTB" >&2
      exit 1
    }

    KREL="$(make -s kernelrelease)"
    rm -rf "$OUT/modules-root"
    mkdir -p "$OUT/modules-root"
    make modules_install INSTALL_MOD_PATH="$OUT/modules-root" INSTALL_MOD_STRIP=1
    MODDIR="$OUT/modules-root/lib/modules/$KREL"
    test -d "$MODDIR" || {
      echo "modules were not installed for kernel release $KREL" >&2
      exit 1
    }
    rm -f "$MODDIR/build" "$MODDIR/source"

    cp "$SRC/arch/arm64/boot/Image" "$OUT/Image"
    cp "$DTB" "$OUT/rk3566-anbernic-rg353ps.dtb"
    cp "$SRC/.config" "$OUT/linux.config"
    cp "$SRC/System.map" "$OUT/System.map"
    cp "$SRC/Module.symvers" "$OUT/Module.symvers"
    tar --zstd -cf "$OUT/modules-$KREL.tar.zst" -C "$MODDIR" .
    rm -rf "$OUT/modules-root"

    cat > "$OUT/kernel-build.json" <<EOF
{
  "target": "Anbernic RG353PS",
  "soc": "Rockchip RK3566",
  "kernel_version": "$KERNEL_VERSION",
  "kernel_release": "$KREL",
  "kernel_source_sha256": "$KERNEL_SHA256",
  "rocknix_distribution_commit": "$ROCKNIX_REF",
  "rk3566_patch_set_sha256": "$PATCH_SHA",
  "kernel_config_sha256": "$CONFIG_SHA",
  "device_tree": "rk3566-anbernic-rg353ps.dtb",
  "complete_sd_image": false,
  "hardware_tested": false
}
EOF
    cd "$OUT"
    sha256sum Image rk3566-anbernic-rg353ps.dtb "modules-$KREL.tar.zst" linux.config System.map Module.symvers kernel-build.json > SHA256SUMS
    echo "Built kernel $KREL and RG353PS DTB under $OUT"
  '

echo
echo "Kernel intermediate artifacts in $OUTPUT:"
for f in "$OUTPUT/Image" "$OUTPUT/rk3566-anbernic-rg353ps.dtb" "$OUTPUT/kernel-build.json" "$OUTPUT/SHA256SUMS"; do
  [ -f "$f" ] || { echo "missing expected output: $f" >&2; exit 1; }
  printf "  %-40s %s\n" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
done
echo "The modules bundle is also in $OUTPUT; this is not a complete SD-card image."
