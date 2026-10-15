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
96/96 combined. The remaining hardware check is to exercise a real encode
operation, followed by checks for the other peripherals and boot/shutdown
behavior.

**This is still a bring-up image, not the finished BaseOS port.** It launches
a diagnostic BusyBox userspace rather than a game frontend and does not yet
include BaseOS's read-only root design, A/B updater, release packaging, or
finished user-facing service integration. Treat it as experimental and use a
spare TF card. The file `work/rg353ps/rg353ps-uboot.bin` remains an
intermediate bootloader region, not a standalone SD-card image.

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
**bring-up image**. It boots a minimal BusyBox userspace plus `v4l-utils`, loads
the Hantro VPU driver during startup, and displays diagnostic messages; it does
not yet launch a game frontend and does not include BaseOS's read-only/A-B update
system. It is not considered supported until it is tested on real RG353PS hardware.

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

The V4L2 API compliance test has passed on hardware. The next step is to
verify actual encoder operation. In a newly built smoke image, run:

```sh
/usr/sbin/rg353ps-jpeg-encode-test
```

This feeds one 96x32 YM12 frame to `/dev/video1`, captures the JPEG output, and
checks the JPEG start/end markers. If `/mnt/boot` is mounted and writable, the
script saves both its text report and output JPEG there; otherwise it uses
`/tmp`. A pass confirms the hardware path produced a plausible JPEG bitstream,
but does not replace decoding/viewing that image or longer-duration testing.

## Porting safety constraints

- Keep this target isolated from `build-all.sh` and `work/my355`; the existing
  Miyoo Flip target must continue to build unchanged.
- Never use the Miyoo preloader installer, `mtd5` patch, `miyoo355_fw.img`,
  Android boot image, stock harvest or `my355`-specific U-Boot commands on the RG353PS.
- Keep U-Boot's control DTB separate from the Linux DTB
  `rk3566-anbernic-rg353ps.dtb`.
- The image builder only writes a disk-image file. When testing, write the
  compressed image to a spare TF card and keep the original system card intact.
