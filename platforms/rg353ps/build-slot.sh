#!/bin/sh
# Build an experimental Slot frontend bundle for RG353PS (SDL2/KMSDRM + Mesa/Panfrost).
# The output is a ZIP for the frontend SD card; it does not modify the OS image.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
. "$REPO_ROOT/tools/common.sh"

WORK="${RG353PS_WORK:-$REPO_ROOT/work/rg353ps}"
OUT="$WORK/frontends"
mkdir -p "$OUT"

for cmd in docker; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing required command: $cmd" >&2; exit 1; }
done

echo "== building experimental RG353PS Slot bundle =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_AARCH64" \
  -v "$HERE/frontends/slot":/slot-port:ro \
  -v "$OUT":/out \
  rust:1-alpine3.22 sh -euc '
    apk add --no-cache git build-base cmake curl zip pkgconf musl-utils linux-headers \
      zlib-dev libpng-dev libzip-dev

    SLOT_REV=e5b12adb2a267bc6658bc80eb50bff9622fb79e4
    MGBA_REV=e31759b24e7a4e3899285ff720d7b573ac328ae7
    GPSP_REV=7b2dd37394e2822110cacef321e9bb291a305b77
    SRC=/tmp/slot-src
    TARGET=/tmp/slot-target
    PKG=/out/baseos-rg353ps-slot
    rm -rf "$SRC" "$TARGET" "$PKG"
    git clone --filter=blob:none https://github.com/BrandonKowalski/slot.git "$SRC"
    git -C "$SRC" checkout --detach "$SLOT_REV"

    # Switch Slot from its device-specific native EGL window to the already
    # verified SDL2 KMSDRM + EGL/GLES path, then map RG353PS A/B by Nintendo layout.
    cp /slot-port/fbdev.rs "$SRC/crates/slot-gfx/src/fbdev.rs"
    git -C "$SRC" apply /slot-port/slot-nintendo-ab.patch

    cd "$SRC"
    cargo build --profile device --target-dir "$TARGET" -p slot --no-default-features --features device
    test -x "$TARGET/device/slot"

    mkdir -p "$PKG/System" "$PKG/.baseos/frontends/slot"
    cp "$TARGET/device/slot" "$PKG/System/slot"
    cp /slot-port/launch.sh "$PKG/.baseos/frontends/slot/launch.sh"
    chmod 0755 "$PKG/.baseos/frontends/slot/launch.sh" "$PKG/System/slot"
    cp -R licenses "$PKG/System/licenses"
    "$PKG/System/slot" --init-root "$PKG"

    # Build both upstream Slot libretro cores with the same musl/aarch64 ABI
    # as this experimental BaseOS userspace.
    sh cores/mgba/build.sh build "$MGBA_REV" /tmp/mgba-work "$PKG/System/mgba_libretro.so"

    GPSP_TARBALL=/tmp/gpsp-src.tar.gz
    curl -fsSL -o "$GPSP_TARBALL" "https://github.com/libretro/gpsp/archive/$GPSP_REV.tar.gz"
    tar -tzf "$GPSP_TARBALL" | grep "^gpsp-$GPSP_REV/Makefile$" >/dev/null
    sh cores/gpsp/build.sh build "$GPSP_REV" "$GPSP_TARBALL" /tmp/gpsp-work "$PKG/System/gpsp_libretro.so"

    # Include source/provenance required for the GPL-licensed gpSP core and keep
    # both core build recipes and source patches with the distributable bundle.
    cp "$GPSP_TARBALL" "$PKG/System/licenses/gpsp-$GPSP_REV.tar.gz"
    cp "$PKG/System/gpsp_libretro.so.meta" "$PKG/System/licenses/gpsp-$GPSP_REV.meta"
    for p in cores/gpsp/*.patch; do
      cp "$p" "$PKG/System/licenses/gpsp-$(basename "$p")"
    done
    MGBA_BUILT_REV="$(grep "^commit=" "$PKG/System/mgba_libretro.so.meta" | cut -d= -f2)"
    cp "$PKG/System/mgba_libretro.so.meta" "$PKG/System/licenses/mgba-$MGBA_BUILT_REV.meta"
    for p in cores/mgba/*.patch; do
      cp "$p" "$PKG/System/licenses/mgba-$(basename "$p")"
    done

    cat > "$PKG/README-RG353PS.txt" <<EOF
BaseOS RG353PS Slot frontend experiment
=======================================

This bundle is for the second/front-end SD card, not the BaseOS boot partition.
Copy the contents of this ZIP to the root of the frontend SD card. It supplies a
Slot build patched to use SDL2 KMSDRM + EGL/GLES and RG353PS Nintendo A/B mapping,
plus musl-compatible mGBA and gpSP cores.

On the BaseOS boot FAT partition, edit baseos.conf to use:
  frontend=slot
  allow_external_frontend_adapters=yes

The second card is mounted at /mnt/SDCARD. The adapter is:
  /mnt/SDCARD/.baseos/frontends/slot/launch.sh

This is an experimental port. The UI, input behavior, emulator launch, sound,
battery/backlight, shutdown, save states and extended play have not yet all
been verified on physical RG353PS hardware. Keep a separate copy of saves and
do not overwrite your original system card.
EOF
    chmod 0644 "$PKG/README-RG353PS.txt"
    cd "$PKG"
    zip -qry /out/baseos-rg353ps-slot.zip .
    sha256sum /out/baseos-rg353ps-slot.zip > /out/baseos-rg353ps-slot.zip.sha256
    ls -lh /out/baseos-rg353ps-slot.zip /out/baseos-rg353ps-slot.zip.sha256
  '

echo "Slot bundle: $OUT/baseos-rg353ps-slot.zip"
echo "Checksum:    $OUT/baseos-rg353ps-slot.zip.sha256"
