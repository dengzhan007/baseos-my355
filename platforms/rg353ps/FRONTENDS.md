# RG353PS frontends

Normal boot does not require editing `baseos.conf` to select a frontend. BaseOS probes the second TF card (TF2) first, normally `/dev/mmcblk2p1`, and mounts it at `/mnt/TF2`. It scans the card root for a usable adapter at `.baseos/frontends/<name>/launch.sh`; if one is present, TF2 wins.

If TF2 is absent, cannot be mounted, or has no usable frontend adapter, BaseOS scans the first/system TF card's `BASEOS_DATA` user partition at `/mnt/SDCARD`. If neither card provides a usable frontend, the built-in diagnostic UI starts. The compatibility path `/mnt/sdcard` follows whichever card supplied the selected frontend.

Install frontend ZIP contents at the root of the card you want to use. TF2 has priority whenever it contains a usable frontend, so a frontend installed on TF1 will only be selected when TF2 is absent or has no usable adapter. Do not place frontend payloads on `BASEOS_BOOT`; that small FAT partition is for boot files and maintenance.

Automatic discovery checks the adapter IDs listed by `frontends_order` (default: `nextui,custom`), then scans for any installed `.baseos/frontends/<name>/launch.sh` or `baseos/frontends/<name>/launch.sh` adapter. The old `frontend=...` and `allow_external_frontend_adapters=...` settings are ignored by the automatic selector; no manual opt-in is needed. Adapter scripts are executed with root privileges, so only use frontend packages you trust.

The intended system-card layout is `BASEOS_BOOT` (FAT boot files), `BASEOS_ROOT` (fixed-size Linux system partition), and `BASEOS_DATA` (exFAT user space). The first-boot initializer expands a blank `BASEOS_DATA` partition to the end of the physical card, formats it as exFAT and mounts it at `/mnt/SDCARD`. On cards larger than the 2 GiB image, the user partition is extended to use the rest of the card. If no free space exists, the initializer logs a warning rather than shrinking the root partition. Before tty1 starts either a frontend or the diagnostic UI, BaseOS waits until this user area is mounted and the persistent initialization marker is written. If initialization fails, a full-screen recovery prompt blocks normal UI startup and lets the user retry. After the first successful initialization, a full-screen confirmation asks for A/Enter once before automatic frontend discovery continues; the acknowledgement is persisted on `BASEOS_BOOT`. Storage failures are written to `BASEOS_BOOT/baseos-userdata-init.txt`, and frontend selection results to `BASEOS_BOOT/baseos-frontend-detection.txt`; both can be inspected from a PC without a serial console.

The adapter environment includes `PLATFORM=rg353ps` and `BASEOS_BOOT=/mnt/boot`. `BASEOS_FRONTEND_ROOT` points to the selected card root (`/mnt/TF2` or `/mnt/SDCARD`); `BASEOS_DATA_DIR` and `BASEOS_USERDATA_DIR` are created under that selected root.

**Important:** images built before the three-partition layout have no dedicated
user-data partition. Back up the card and flash a new image before expecting
same-card frontend installation. The boot partition remains a small maintenance
partition and is still visible to a PC; the Linux root partition is separate
from user files. A read-only root and A/B updater remain future work.

The RG353PS global hotkey service is independent of the UI process. It handles
volume +/- as RK817 playback-only mixer adjustments, and a 2-second power-key
hold as a clean shutdown. The diagnostic UI only displays those input events.


## Frontend packaging is maintained separately

BaseOS only discovers and launches frontend adapters; frontend source code, platform patches, build recipes and frontend-specific launch logic belong in their respective frontend repositories. For example, the RG353PS NextUI adaptation is maintained in the separate NextUI repository, and the experimental Slot port is maintained in the separate Slot repository.

Install a frontend bundle by extracting its ZIP to the root of the selected frontend card. BaseOS looks for `.baseos/frontends/<name>/launch.sh` first and also accepts the compatibility path `baseos/frontends/<name>/launch.sh`. No frontend-specific binary is embedded in the BaseOS image. Adapter scripts execute with root privileges, so only install packages you trust.
