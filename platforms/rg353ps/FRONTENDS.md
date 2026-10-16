# RG353PS frontends

The diagnostic UI is the safe default and fallback. The frontend selector
is configured in `baseos.conf` on `BASEOS_BOOT`. Profiles are `diagnostic`,
`auto`, `nextui`, `slot`, and `custom`.

The intended layout is now three partitions on the same TF card:
`BASEOS_BOOT` (FAT boot files and `baseos.conf`), `BASEOS_ROOT` (bounded
Linux system partition), and `BASEOS_DATA` (exFAT user space). On first boot,
the new initializer expands `BASEOS_DATA` to the end of the physical card if
it is blank, formats it, and mounts it at `/mnt/SDCARD`. Frontend adapters,
`System/`, ROMs and saves belong on this user-data partition—not on the boot
partition. On cards larger than the 2 GiB image, the user partition is extended
to use the rest of the card. If the card has no free space for a user partition,
the initializer logs a warning and does not shrink or rewrite the mounted root
filesystem.

Adapters are expected under `/mnt/SDCARD/.baseos/frontends/<name>/launch.sh`.
External adapters run with root privileges, so execution is disabled by default.
After installing an adapter you trust, set both `frontend=slot` (or `auto`)
and `allow_external_frontend_adapters=yes` in `baseos.conf`. The configured
second-card device remains only as a fallback for legacy/external storage.

The adapter environment includes `PLATFORM=rg353ps`, `BASEOS_BOOT=/mnt/boot`,
`BASEOS_FRONTEND_ROOT=/mnt/SDCARD`,
`BASEOS_DATA_DIR=/mnt/SDCARD/.baseos/data`, and
`BASEOS_USERDATA_DIR=/mnt/SDCARD/.baseos/userdata`.

**Important:** images built before the three-partition layout have no dedicated
user-data partition. Back up the card and flash a new image before expecting
same-card frontend installation. The boot partition remains a small maintenance
partition and is still visible to a PC; the Linux root partition is separate
from user files. A read-only root and A/B updater remain future work.

The RG353PS global hotkey service is independent of the UI process. It handles
volume +/- as RK817 playback-only mixer adjustments, and a 2-second power-key
hold as a clean shutdown. The diagnostic UI only displays those input events.


## First frontend target: Slot (experimental)

SDL2 KMSDRM/EGL/GLES now initializes on the RG353PS and reports the Mali-G52
Panfrost renderer. The first frontend adaptation target is Slot because its
device UI is smaller than NextUI's H700-specific userspace. Upstream Slot
currently targets Anbernic H700 devices and is Game Boy / Game Boy Color / Game
Boy Advance focused; this is not an upstream-supported RG353PS port.

The independent builder is:

```sh
./platforms/rg353ps/build-slot.sh
```

It pins the upstream Slot source revision, replaces its device-specific EGL
window with SDL2 KMSDRM, applies the RG353PS Nintendo-layout A/B mapping, and
builds a separate frontend-card ZIP. The package builder is a separate CI job;
it does not inject Slot into the default OS smoke image or alter the Miyoo Flip
build. The bundle includes the exact patched Slot source plus corresponding
mGBA/gpSP source archives and patch/license materials under
`System/licenses/`. Do not consider the bundle device-validated until its CI
build passes and it has been smoke-tested on the handheld.

When a successful `baseos-rg353ps-slot` workflow artifact is available, boot
once with the new three-partition image, shut down, and put the TF card in a PC.
Extract the ZIP contents to the root of the `BASEOS_DATA` user partition (not
`BASEOS_BOOT`). Then edit `baseos.conf` on the FAT `BASEOS_BOOT` partition:

```
frontend=slot
allow_external_frontend_adapters=yes
```

The opt-in is required because adapters located on the external frontend card
are shell scripts executed as root. If the adapter is missing or the opt-in is
not enabled, BaseOS falls back to the diagnostic UI. Keep the original system
card and your saves backed up while testing.

This first target is intentionally a limited milestone: successful compilation
or menu launch does not establish correctness of all buttons, sound, battery,
brightness, sleep/wake, emulator launch, saves, or long-duration behavior.
NextUI remains a separate porting target; its H700 launcher currently assumes
an H700-specific `mali` SDL backend and stock-OS services, so it needs its own
adapter/runtime work rather than reusing the H700 zip as-is.
