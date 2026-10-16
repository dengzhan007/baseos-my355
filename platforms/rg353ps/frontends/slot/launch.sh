#!/bin/sh
# BaseOS RG353PS launcher for the SDL2/KMSDRM Slot build.
set -eu

SDCARD="${BASEOS_FRONTEND_ROOT:-/mnt/SDCARD}"
SYSTEM="$SDCARD/System"
LOGDIR="$SDCARD/Logs"

mkdir -p "$LOGDIR" "$SDCARD/Games" "$SDCARD/Saves" 2>/dev/null || :
export SLOT_ROOT="$SDCARD"
export BASEOS_TARGET=rg353ps
export BASEOS_MODEL=rg353ps
export BASEOS_PANEL_ROTATION_CCW=0
export SDL_VIDEODRIVER=kmsdrm
export SDL_AUDIODRIVER=alsa
export SDL_JOYSTICK_DISABLE_UDEV=1
export SDL_HIDAPI_JOYSTICK_DISABLE_UDEV=1
export LD_LIBRARY_PATH="$SYSTEM/lib:$SYSTEM:/usr/lib:/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

if [ ! -x "$SYSTEM/slot" ]; then
  echo "Slot binary missing: $SYSTEM/slot" >> "$LOGDIR/slot.log"
  exit 127
fi

# Create missing content directories and migrate only Slot's own config if needed.
"$SYSTEM/slot" --init-root "$SDCARD" >> "$LOGDIR/slot-session.log" 2>&1 || {
  echo "Slot root initialization failed at $(date)" >> "$LOGDIR/slot-session.log"
  exit 1
}

echo "BaseOS RG353PS Slot launch: $(date)" >> "$LOGDIR/slot-session.log"
exec "$SYSTEM/slot" >> "$LOGDIR/slot.log" 2>&1
