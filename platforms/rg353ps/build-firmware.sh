#!/bin/sh
# Collect the mainline firmware needed by the RG353PS RTL8821CS combo.
# Sources and hashes follow ROCKNIX's pinned linux-firmware/wireless-regdb packages.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
. "$REPO_ROOT/tools/common.sh"

WORK="${RG353PS_WORK:-$REPO_ROOT/work/rg353ps}"
CACHE="$WORK/firmware-cache"
OUT="$WORK/firmware"
LINUX_FW_VERSION="20260309"
LINUX_FW_SHA256="28fb1b57fa9531edbd001a2462068267f10622e613abd40f952344b3f1fc5a16"
REGDB_VERSION="2026.05.30"
REGDB_SHA256="8a27bfc081bafed8c24dd70fab0d96f098e5a0bfcd08d3da672595f225ab8993"
LINUX_FW_TARBALL="$CACHE/linux-firmware-$LINUX_FW_VERSION.tar.gz"
REGDB_TARBALL="$CACHE/wireless-regdb-$REGDB_VERSION.tar.xz"

mkdir -p "$CACHE" "$OUT"

fetch_verified() {
  url="$1"
  destination="$2"
  expected="$3"
  if [ ! -f "$destination" ] || [ "$(baseos_sha256 "$destination")" != "$expected" ]; then
    rm -f "$destination.part"
    echo "== downloading $(basename "$destination") =="
    curl -fL --retry 3 -o "$destination.part" "$url"
    got="$(baseos_sha256 "$destination.part")"
    [ "$got" = "$expected" ] || {
      echo "SHA-256 mismatch for $destination: expected $expected, got $got" >&2
      rm -f "$destination.part"
      exit 1
    }
    mv "$destination.part" "$destination"
  fi
}

fetch_verified \
  "https://cdn.kernel.org/pub/linux/kernel/firmware/linux-firmware-$LINUX_FW_VERSION.tar.gz" \
  "$LINUX_FW_TARBALL" "$LINUX_FW_SHA256"
fetch_verified \
  "https://www.kernel.org/pub/software/network/wireless-regdb/wireless-regdb-$REGDB_VERSION.tar.xz" \
  "$REGDB_TARBALL" "$REGDB_SHA256"

SRC="$WORK/firmware-src"
REGSRC="$WORK/regdb-src"
rm -rf "$SRC" "$REGSRC" "$OUT"
mkdir -p "$SRC" "$REGSRC" "$OUT"
tar -xzf "$LINUX_FW_TARBALL" -C "$SRC" --strip-components=1
tar -xJf "$REGDB_TARBALL" -C "$REGSRC" --strip-components=1

mkdir -p "$OUT/rtw88" "$OUT/rtl_bt"
copy_required() {
  source="$1"
  dest="$2"
  [ -s "$source" ] || {
    echo "required firmware is missing: $source" >&2
    exit 1
  }
  mkdir -p "$(dirname "$dest")"
  cp "$source" "$dest"
}
copy_optional() {
  source="$1"
  dest="$2"
  if [ -s "$source" ]; then
    mkdir -p "$(dirname "$dest")"
    cp "$source" "$dest"
  fi
}

# Mainline rtw88 driver for the SDIO RTL8821CS Wi-Fi function.
copy_required "$SRC/rtw88/rtw8821c_fw.bin" "$OUT/rtw88/rtw8821c_fw.bin"
# Mainline Bluetooth driver tries the RTL8821CS names, with RTL8723BS fallback.
copy_required "$SRC/rtl_bt/rtl8821cs_fw.bin" "$OUT/rtl_bt/rtl8821cs_fw.bin"
copy_optional "$SRC/rtl_bt/rtl8821cs_config.bin" "$OUT/rtl_bt/rtl8821cs_config.bin"
copy_optional "$SRC/rtl_bt/rtl8723bs_fw.bin" "$OUT/rtl_bt/rtl8723bs_fw.bin"
copy_optional "$SRC/rtl_bt/rtl8723bs_config.bin" "$OUT/rtl_bt/rtl8723bs_config.bin"

copy_required "$REGSRC/regulatory.db" "$OUT/regulatory.db"
copy_required "$REGSRC/regulatory.db.p7s" "$OUT/regulatory.db.p7s"

cat > "$OUT/firmware-manifest.txt" <<EOF
target=Anbernic RG353PS
wifi_chip=Realtek RTL8821CS
linux_firmware_version=$LINUX_FW_VERSION
linux_firmware_sha256=$LINUX_FW_SHA256
wireless_regdb_version=$REGDB_VERSION
wireless_regdb_sha256=$REGDB_SHA256
required_wifi_firmware=rtw88/rtw8821c_fw.bin
required_bluetooth_firmware=rtl_bt/rtl8821cs_fw.bin
regulatory_database=regulatory.db,regulatory.db.p7s
EOF
(
  cd "$OUT"
  find rtw88 rtl_bt -type f -print
  printf '%s\n' regulatory.db regulatory.db.p7s firmware-manifest.txt
) | LC_ALL=C sort > "$OUT/FILES"
(
  cd "$OUT"
  sha256sum $(cat FILES) > SHA256SUMS
)

echo "RG353PS firmware bundle ready: $OUT"
cat "$OUT/firmware-manifest.txt"
