# RG353PS frontends

Normal boot does not require editing `baseos.conf` to select a frontend. BaseOS probes the second TF card (TF2) first, normally `/dev/mmcblk2p1`, and mounts it at `/mnt/TF2`. It scans the card root for a usable adapter at `.baseos/frontends/<name>/launch.sh`; if one is present, TF2 wins.

If TF2 is absent, cannot be mounted, or has no usable frontend adapter, BaseOS scans the first/system TF card's `BASEOS_DATA` user partition at `/mnt/SDCARD`. If neither card provides a usable frontend, the built-in diagnostic UI starts. The compatibility path `/mnt/sdcard` follows whichever card supplied the selected frontend.

Install frontend ZIP contents at the root of the card you want to use. TF2 has priority whenever it contains a usable frontend, so a frontend installed on TF1 will only be selected when TF2 is absent or has no usable adapter. Do not place frontend payloads on `BASEOS_BOOT`; that small FAT partition is for boot files and maintenance.

Automatic discovery recognizes `nextui`, `slot`, and `custom` adapters in the order listed by `frontends_order` (default: `nextui,slot,custom`). The old `frontend=...` and `allow_external_frontend_adapters=...` settings are ignored by the automatic selector; no manual opt-in is needed. Adapter scripts are executed with root privileges, so only use frontend packages you trust.

The intended system-card layout is `BASEOS_BOOT` (FAT boot files), `BASEOS_ROOT` (fixed-size Linux system partition), and `BASEOS_DATA` (exFAT user space). The first-boot initializer expands a blank `BASEOS_DATA` partition to the end of the physical card, formats it as exFAT and mounts it at `/mnt/SDCARD`. On cards larger than the 2 GiB image, the user partition is extended to use the rest of the card. If no free space exists, the initializer logs a warning rather than shrinking the root partition.

The adapter environment includes `PLATFORM=rg353ps` and `BASEOS_BOOT=/mnt/boot`. `BASEOS_FRONTEND_ROOT` points to the selected card root (`/mnt/TF2` or `/mnt/SDCARD`); `BASEOS_DATA_DIR` and `BASEOS_USERDATA_DIR` are created under that selected root.

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

When a successful `baseos-rg353ps-slot` workflow artifact is available, back up the card and flash the new three-partition image if your current image predates `BASEOS_DATA`. Shut down after the first boot so the data partition can finish initializing.

To install Slot on TF2, extract the ZIP contents directly into the root of the TF2 card (not into a containing folder, and not onto `BASEOS_BOOT`). To install it on TF1 instead, extract the same contents into the root of the `BASEOS_DATA` partition. No `baseos.conf` edits are required: BaseOS automatically chooses a usable frontend on TF2 first, then falls back to TF1 user data.

Keep the original system card and your saves backed up while testing. Because the frontend adapter is a shell script executed with root privileges, only install packages you trust.

This first target is intentionally a limited milestone: successful compilation
or menu launch does not establish correctness of all buttons, sound, battery,
brightness, sleep/wake, emulator launch, saves, or long-duration behavior.
NextUI remains a separate porting target; its H700 launcher currently assumes
an H700-specific `mali` SDL backend and stock-OS services, so it needs its own
adapter/runtime work rather than reusing the H700 zip as-is.
