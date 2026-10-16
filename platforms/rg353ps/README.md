# RG353PS port — experimental

This directory is an isolated porting target for the Anbernic RG353PS
(Rockchip RK3566). It is intentionally separate from the existing Miyoo Flip
build so the current `my355` release path remains unchanged.

## Current status

The branch now builds an end-to-end **2 GiB experimental SD smoke image**:
mainline U-Boot, Linux kernel and RG353PS DTB, modules, RTL8821CS firmware,
a minimal BusyBox root filesystem, and a GPT-partitioned disk image. The
latest successful build before the current JPEG test-helper addition is
[workflow run #62](https://github.com/dengzhan007/baseos-my355/actions/runs/38702742778).

The image has been booted on physical RG353PS hardware. The submitted hardware
report shows `/dev/video0` (Hantro stateless decoder) and `/dev/video1`
(Hantro JPEG encoder) both pass `v4l2-compliance 1.28.1` with 48/48 tests,
96/96 combined. A one-frame YM12-to-JPEG encode also succeeded. Physical testing
has additionally confirmed controller navigation, RK817 playback volume changes
and clean shutdown on a 2-second power-key hold. Remaining work includes actual
audio playback, Wi-Fi/BT association and audio, battery/charging accuracy, HDMI,
3D graphics, suspend/resume, storage endurance and long-duration stability.

**This remains an experimental bring-up image, not a finished BaseOS release.** The built-in diagnostic UI is the fallback when no usable frontend adapter is found. Frontend selection is automatic; users do not need to edit `baseos.conf` to identify a frontend.

At boot, BaseOS scans TF2 first (normally `/dev/mmcblk2p1`) and mounts it at `/mnt/TF2`. If the card root contains a recognized, usable adapter at `.baseos/frontends/<name>/launch.sh`, that frontend is selected. If TF2 is absent, cannot be mounted, or has no usable frontend, BaseOS scans TF1's `BASEOS_DATA` partition at `/mnt/SDCARD`. The `/mnt/sdcard` compatibility link follows the selected frontend root. Slot is staged onto writable `/tmp` before launch because exFAT/Windows extraction does not reliably preserve Unix executable permissions. If neither card contains a usable adapter, the diagnostic UI starts. Storage initialization logs are saved as `BASEOS_BOOT/baseos-userdata-init.txt`, and frontend discovery logs as `BASEOS_BOOT/baseos-frontend-detection.txt`, for PC-side troubleshooting. The tty1 selector is not started until TF1 user storage has been initialized, mounted, and recorded with a persistent marker. If storage is not ready, a full-screen retry prompt is shown instead of diagnostics. After first initialization succeeds, BaseOS asks for A/Enter once, then continues automatic frontend discovery. The old `frontend=...` and `allow_external_frontend_adapters=...` configuration keys are ignored; frontend adapter scripts execute with root privileges, so install only trusted packages.

The image layout separates `BASEOS_BOOT`, a fixed-size `BASEOS_ROOT`, and `BASEOS_DATA` for frontend/user files. At first boot, the blank user partition is expanded to the physical card's end and formatted as exFAT, then mounted at `/mnt/SDCARD`. Install frontend ZIP contents at the root of TF2 for priority use, or at the root of TF1's `BASEOS_DATA` for fallback use—not on the small FAT boot partition. Existing images from before this change do not gain a dedicated user-data partition unless reflashed; back up the card first. The boot partition remains visible to a PC for maintenance, while the Linux root partition is separate from user files. The system still lacks a final read-only root, A/B updater and release packaging. Use a spare TF card. The file `work/rg353ps/rg353ps-uboot.bin` remains an intermediate bootloader region, not a standalone SD-card image.

For details, see [FRONTENDS.md](FRONTENDS.md).

## Graphics userspace and first render test

The physical RG353PS graphics audit identified a working Rockchip DRM display
controller and a loaded Panfrost Mali-G52 kernel driver, but the earlier image
did not contain EGL/GLES/GBM userspace libraries or tools. The rootfs build now
installs Mesa EGL/GLES/GBM, the Panfrost DRI driver, SDL2 runtime, `eglinfo`,
`modetest`, and `kmscube`. This is a first graphics-stack test environment,
not yet proof of hardware-accelerated rendering or frontend compatibility.

On the device, run:

```sh
/usr/sbin/rg353ps-graphics-stack-test
```

The test writes `/mnt/boot/rg353ps-graphics-stack-test.txt` (or
`/tmp/rg353ps-graphics-stack-test.txt` if the boot partition is not writable).
It enumerates DRM connectors, captures EGL information, and runs `kmscube` on
`/dev/dri/card0` for a maximum of 12 seconds. The built-in display should show
a spinning cube. Exit code 124 from the timed cube command is expected if the
process ran until the timeout; an earlier EGL/DRM error is a failure to
investigate. Run it from the serial shell when no other application owns the
DRM display; it temporarily modesets the built-in screen.

The script also runs a small SDL2 test program through `SDL_VIDEODRIVER=kmsdrm`.
If successful, the internal screen should display red, green, blue and dark
screens for about eight seconds. It prints the actual SDL video backend,
display mode, GLES renderer and version, then exits cleanly. This is the
next milestone for frontend compatibility; it still does not prove NextUI or
Slot itself can run.

For the earlier KMS cube test, BusyBox `timeout` may report exit code 143
after stopping `kmscube` with SIGTERM (rather than the more common 124).
Either can be expected if the cube stayed on screen for the timed interval and
there were no earlier DRM/EGL errors. EGL warnings for unavailable Wayland/X11
are not, by themselves, evidence that the headless GBM/KMS path failed.

The October 2026 report also showed the device clock about 10 days ahead of the
current date; check `date -u` and fix time synchronization before diagnosing
TLS/download errors.

## Build the U-Boot milestone

Host prerequisites: Docker, Git, curl, and the host's usual shell utilities.
From the repository root:

```sh
./platforms/rg353ps/build-uboot.sh
```

The script pins U-Boot v2026.01 by SHA-256 and checks out a fixed Rockchip
`rkbin` revision for the DDR and BL31 binaries. It uses
`anbernic-rgxx3-rk3566_defconfig`, following the RK3566 Generic package in
[ROCKNIX](https://github.com/ROCKNIX/distribution/tree/next/projects/ROCKNIX/devices/RK3566/packages/u-boot-Generic).
The panel-power sequencing patch is based on ROCKNIX's
`0003-board-rockchip-Fix-panel-detection-logic-for-mainlin.patch`.

The generated combined bootloader follows ROCKNIX's layout helper:
`idbloader.img` at LBA 0 and `u-boot.itb` at LBA 16320 (512-byte sectors).
The script also saves the FIT and checksum/metadata alongside the combined
bootloader under `work/rg353ps/`.

## Build a first-boot SD smoke image

The scripts are deliberately separated from the Miyoo Flip build. From the
repository root, run:

```sh
./platforms/rg353ps/build-uboot.sh
./platforms/rg353ps/build-kernel.sh
./platforms/rg353ps/build-firmware.sh
./platforms/rg353ps/build-rootfs.sh
./platforms/rg353ps/build-image.sh
```

The build uses U-Boot v2026.01 / Anbernic RGxx3 defconfig, Linux 7.2.7 with the
ROCKNIX RK3566 configuration and hardware patches, and the matching RG353PS
Linux DTB. The RTL8821CS mainline Wi-Fi/Bluetooth firmware is collected
separately. Because built-in cfg80211 requests its signed regulatory database
early in boot, regulatory.db and its signature are also embedded in the kernel;
the current wireless-regdb signing certificate is included as an additional
trusted key. Kernel config/patch and certificate provenance is in
[kernel/UPSTREAM.md](kernel/UPSTREAM.md).

The result is `work/rg353ps/baseos-rg353ps-smoke.img.gz`, a 2 GiB SD-card
**bring-up image**. It uses a 256 MiB FAT `BASEOS_BOOT` partition, a bounded
1280 MiB ext4 `BASEOS_ROOT` partition, and a blank `BASEOS_DATA` partition.
The first-boot initializer expands the user partition to the actual TF-card end
and formats it as exFAT, then mounts it at `/mnt/SDCARD`. This allows the same
card to hold user-installed frontend packages, ROMs and saves. It boots a
minimal BusyBox userspace plus hardware diagnostic tools and an evdev-driven
text UI on tty1; it is not the finished game frontend or the final read-only/A-B
BaseOS update system. It is not considered supported until tested on real
RG353PS hardware.

After boot, run `/usr/sbin/rg353ps-v4l2-report` to capture driver status,
V4L2 capabilities, and advertised capture/output formats to
`/tmp/rg353ps-v4l2-report.txt` while also printing them to the console.
You can also inspect the nodes directly:

```sh
v4l2-ctl --list-devices
v4l2-ctl -d /dev/video0 --all
v4l2-ctl -d /dev/video0 --list-formats-ext
v4l2-ctl -d /dev/video0 --list-formats-out-ext
v4l2-ctl -d /dev/video1 --all
v4l2-ctl -d /dev/video1 --list-formats-ext
v4l2-ctl -d /dev/video1 --list-formats-out-ext
```

The V4L2 API compliance and one-frame hardware JPEG encode tests have passed.
The encode helper is `/usr/sbin/rg353ps-jpeg-encode-test`; it feeds one 96x32
YM12 frame to `/dev/video1`, captures the JPEG output, and checks the start/end
markers. A pass confirms a plausible bitstream was produced, but does not
replace decoding/viewing the image or longer-duration testing.

For the next hardware pass, run `/usr/sbin/rg353ps-hardware-audit`. It creates
a read-only inventory of display/backlight, input devices, audio, battery and
thermal sensors, storage, network, Bluetooth/USB, V4L2 formats/compliance, and
relevant kernel messages. It writes its report under `/mnt/boot` when writable,
otherwise under `/tmp`. It does not deliberately press buttons, play audio,
toggle radios, change power state or reboot.

The diagnostic image includes `evtest`, `alsa-utils` and `iw`. The interactive control UI is compiled as a static ARM64 executable during the rootfs build.
After reviewing the inventory, test controls interactively with
`evtest /dev/input/eventX` (replace `eventX` with the device name from the
report and press each physical button), inspect audio with `aplay -l` and
`amixer scontrols`, and check wireless interfaces with `iw dev`. Do not start
wireless associations or change mixer values as part of the passive inventory.

## Porting safety constraints

- Keep this target isolated from `build-all.sh` and `work/my355`; the existing
  Miyoo Flip target must continue to build unchanged.
- Never use the Miyoo preloader installer, `mtd5` patch, `miyoo355_fw.img`,
  Android boot image, stock harvest or `my355`-specific U-Boot commands on the RG353PS.
- Keep U-Boot's control DTB separate from the Linux DTB
  `rk3566-anbernic-rg353ps.dtb`.
- The image builder only writes a disk-image file. When testing, write the
  compressed image to a spare TF card and keep the original system card intact.
