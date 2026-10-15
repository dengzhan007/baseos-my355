#!/bin/sh
# Build the RG353PS diagnostic rootfs: BusyBox plus V4L2 inspection tools.
# The Miyoo Flip stock-library harvest and all my355-specific scripts are excluded.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
. "$REPO_ROOT/tools/common.sh"

WORK="${RG353PS_WORK:-$REPO_ROOT/work/rg353ps}"
KERNEL_OUT="$WORK/kernel/output"
KERNEL_META="$KERNEL_OUT/kernel-build.json"
FIRMWARE_OUT="$WORK/firmware"
ROOTFS="$WORK/rootfs"

for cmd in docker python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing required command: $cmd" >&2; exit 1; }
done
[ -s "$KERNEL_META" ] || { echo "missing $KERNEL_META (run ./platforms/rg353ps/build-kernel.sh)" >&2; exit 1; }
[ -s "$FIRMWARE_OUT/firmware-manifest.txt" ] || "$HERE/build-firmware.sh"

KREL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kernel_release"])' "$KERNEL_META")"
MODULES_TARBALL="$KERNEL_OUT/modules-$KREL.tar.zst"
[ -s "$MODULES_TARBALL" ] || { echo "missing kernel modules bundle: $MODULES_TARBALL" >&2; exit 1; }
[ -s "$FIRMWARE_OUT/rtw88/rtw8821c_fw.bin" ] || { echo "missing RTL8821CS Wi-Fi firmware" >&2; exit 1; }
[ -s "$FIRMWARE_OUT/rtl_bt/rtl8821cs_fw.bin" ] || { echo "missing RTL8821CS Bluetooth firmware" >&2; exit 1; }
[ -s "$FIRMWARE_OUT/rtl_bt/rtl8821cs_config.bin" ] || { echo "missing required RTL8821CS Bluetooth config" >&2; exit 1; }

baseos_require_aarch64
mkdir -p "$WORK"

echo "== building RG353PS diagnostic rootfs for kernel $KREL =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_AARCH64" \
  -v "$WORK":/work \
  -v "$HERE/rootfs":/rootfs-src:ro \
  -e KREL="$KREL" \
  alpine:3.22 sh -euc '
    apk add --no-cache busybox-static tar zstd

    R=/work/rootfs
    rm -rf "$R"
    mkdir -p "$R"
    # BaseOS uses merged-/usr so BusyBox applet links and future packages agree
    # on executable paths. Keep this system independent of Miyoo vendor files.
    mkdir -p "$R/usr/bin" "$R/usr/sbin" "$R/usr/lib" "$R/usr/share"
    ln -s usr/bin "$R/bin"
    ln -s usr/sbin "$R/sbin"
    ln -s usr/lib "$R/lib"
    ln -s lib "$R/lib64"
    mkdir -p "$R/proc" "$R/sys" "$R/dev" "$R/run" "$R/tmp" "$R/var" \
      "$R/data" "$R/root" "$R/etc" "$R/mnt" "$R/mnt/boot" "$R/mnt/roms"

    cp /bin/busybox.static "$R/usr/bin/busybox"
    # This runs in the arm64 container (QEMU binfmt is registered by CI/local
    # setup), creating applet links inside the rootfs rather than on the host.
    chroot "$R" /usr/bin/busybox --install -s
    test -L "$R/sbin/init" || { echo "BusyBox init applet is unavailable" >&2; exit 1; }
    test -L "$R/sbin/modprobe" || { echo "BusyBox modprobe applet is unavailable" >&2; exit 1; }
    test -L "$R/sbin/getty" || { echo "BusyBox getty applet is unavailable" >&2; exit 1; }

    # Install the exact matching kernel modules produced by build-kernel.sh.
    mkdir -p "$R/lib/modules/$KREL"
    tar --zstd -xf "/work/kernel/output/modules-$KREL.tar.zst" -C "$R/lib/modules/$KREL"
    rm -f "$R/lib/modules/$KREL/build" "$R/lib/modules/$KREL/source"

    # Only the firmware required by the mainline RTL8821CS driver and signed
    # regulatory database is included; no broad firmware package is copied.
    mkdir -p "$R/lib/firmware"
    cp -a /work/firmware/. "$R/lib/firmware/"

    cp -a /rootfs-src/. "$R/"

    # Install v4l-utils and its shared-library dependencies into the target
    # rootfs. The build container is arm64, matching the RG353PS target.
    # Disable package scripts: this is a minimal diagnostic rootfs, not a full
    # Alpine installation, and target post-install hooks must not run at build.
    mkdir -p "$R/etc/apk/keys"
    cp -a /etc/apk/keys/. "$R/etc/apk/keys/"
    cp /etc/apk/repositories "$R/etc/apk/repositories"
    apk --root "$R" --arch aarch64 --initdb --no-scripts --no-cache add v4l-utils
    test -x "$R/usr/bin/v4l2-ctl" || {
      echo "v4l2-ctl was not installed into target rootfs" >&2
      exit 1
    }

    chmod 0755 "$R/etc/init.d/rcS"
    chmod 0755 "$R/usr/sbin/rg353ps-v4l2-report"
    chmod 0755 "$R/usr/sbin/rg353ps-jpeg-encode-test"
    chmod 0755 "$R/usr/sbin/rg353ps-hardware-audit"
    chmod 1777 "$R/tmp"
    mkdir -p "$R/run" "$R/root" "$R/var/empty"
    printf "root:x:0:0:root:/root:/bin/sh\n" > "$R/etc/passwd"
    printf "root:x:0:\n" > "$R/etc/group"
    printf "root:*:19000:0:99999:7:::\n" > "$R/etc/shadow"
    ln -sfn /proc/mounts "$R/etc/mtab"
    ln -sfn /run/resolv.conf "$R/etc/resolv.conf"
    printf "BaseOS RG353PS rootfs\n" > "$R/etc/motd"
    printf "%s\n" "$KREL" > "$R/etc/baseos-kernel-release"

    cat > "$R/etc/baseos-build.json" <<EOF
{
  "target": "Anbernic RG353PS",
  "kernel_release": "$KREL",
  "userspace": "static BusyBox",
  "purpose": "first-boot hardware bring-up",
  "finished_frontend": false,
  "hardware_tested": false
}
EOF
    echo "rootfs prepared at $R"
  '

for file in "$ROOTFS/usr/bin/busybox" "$ROOTFS/sbin/init" "$ROOTFS/etc/init.d/rcS" "$ROOTFS/usr/sbin/rg353ps-hardware-audit" "$ROOTFS/lib/modules/$KREL/modules.dep"; do
  [ -e "$file" ] || { echo "rootfs missing required file: $file" >&2; exit 1; }
done

echo "RG353PS rootfs ready: $ROOTFS"
echo "Kernel release: $KREL"
echo "This rootfs is a test environment and does not include the final game frontend."
