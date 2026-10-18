#!/bin/sh
# RG353PS boot-partition diagnostic task.
# BaseOS runs this file once on every boot when /mnt/boot/BASEOS-RUN.SH exists.
# Keep output on TF1 data (/mnt/SDCARD); if unavailable, use the boot partition.
set +e
PATH=/sbin:/bin:/usr/sbin:/usr/bin
export PATH
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null)"
[ -n "$STAMP" ] || STAMP="unknown-time"
OUTDIR=/mnt/SDCARD
grep -q ' /mnt/SDCARD ' /proc/mounts 2>/dev/null || OUTDIR=/mnt/boot
OUT="$OUTDIR/rg353ps-boot-diag-$STAMP.txt"
exec >"$OUT" 2>&1
section() { echo; echo "===== $* ====="; }
section "AUTORUN MARKER"
echo "BASEOS-RUN.SH executed at $(date)"
echo "Output: $OUT"
echo "Boot script path: /mnt/boot/BASEOS-RUN.SH"
section "KERNEL ID"
uname -a
cat /proc/version 2>/dev/null
cat /proc/cmdline 2>/dev/null
cat /proc/sys/kernel/osrelease 2>/dev/null
section "DEVICE TREE"
for f in /proc/device-tree/model /proc/device-tree/compatible /sys/firmware/devicetree/base/model /sys/firmware/devicetree/base/compatible; do
  if [ -r "$f" ]; then echo "--- $f ---"; tr '\000' '\n' < "$f"; fi
done
section "PRINTK"
cat /proc/sys/kernel/printk 2>/dev/null
dmesg -n 7 2>&1
section "KERNEL IMAGE AND DIAGNOSTIC STRINGS"
for f in /mnt/boot/Image /mnt/boot/Image-* /boot/Image /boot/vmlinuz*; do
  [ -f "$f" ] || continue
  echo "--- $f ---"
  ls -l "$f"
  if command -v strings >/dev/null 2>&1; then
    strings "$f" 2>/dev/null | grep -E 'RG353PS BVALID IRQ entry|otg-bvalid IRQ|RG353PS USB PHY OTG sample|extcon.*notify' | head -n 80
  else
    echo "strings command unavailable in this rootfs"
  fi
done
section "PHY MODULES"
cat /proc/modules 2>/dev/null
find /lib/modules/"$(uname -r)" -type f \( -iname '*rockchip*usb2*.ko*' -o -iname '*dwc3*.ko*' \) 2>/dev/null
section "DYNAMIC DEBUG"
if [ -r /sys/kernel/debug/dynamic_debug/control ]; then
  grep -Ei 'phy-rockchip-inno-usb2|dwc3' /sys/kernel/debug/dynamic_debug/control 2>/dev/null | head -n 150
else
  echo "dynamic_debug control unavailable"
fi
section "USB PHY / UDC / EXTCON"
grep -Ei 'RG353PS|usb2phy|phy-fe8a0000|BVALID|otg-bvalid|extcon|fcc00000|dwc3|mass.storage|usb.storage|UDC|regulator\.17|otg_switch' /proc/kmsg 2>/dev/null
dmesg 2>&1 | grep -Ei 'RG353PS|usb2phy|phy-fe8a0000|BVALID|otg-bvalid|extcon|fcc00000|dwc3|mass.storage|usb.storage|UDC|regulator\.17|otg_switch' | tail -n 600
section "INTERRUPTS"
grep -Ei 'usb|phy|otg|dwc' /proc/interrupts 2>/dev/null
section "USB SYSFS"
for f in /sys/class/udc/*/state /sys/class/udc/*/current_speed /sys/class/udc/*/maximum_speed /sys/class/udc/*/function /sys/class/extcon/*/state; do
  [ -r "$f" ] || continue
  echo "--- $f ---"
  cat "$f"
done
section "END"
echo "Diagnostic finished at $(date)"
sync
