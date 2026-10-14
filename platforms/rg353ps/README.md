# RG353PS port — experimental

This directory is an isolated porting target for the Anbernic RG353PS
(Rockchip RK3566). It is intentionally separate from the existing Miyoo Flip
build so the current `my355` release path remains unchanged.

## Current status

The first milestone is the **U-Boot build target only**. The script builds
the Anbernic RGxx3 mainline bootloader and places its components in the
Rockchip SD-card boot layout used by ROCKNIX.

**This is not a complete BaseOS image and is not ready to flash as a card image.**
It does not yet build or package the RG353PS Linux kernel, Linux device tree,
root filesystem, GPT/partition layout, frontend, or updater. The output
`work/rg353ps/rg353ps-uboot.bin` is an intermediate bootloader region, not a
standalone SD-card image. Do not write it to a card as though it were a full
image.

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
Linux DTB. The RTL8821CS mainline Wi-Fi/Bluetooth firmware and signed regulatory
database are collected separately. Kernel config/patch provenance is in
[kernel/UPSTREAM.md](kernel/UPSTREAM.md).

The result is `work/rg353ps/baseos-rg353ps-smoke.img.gz`, a 2 GiB SD-card
**bring-up image**. It boots a minimal BusyBox userspace and displays diagnostic
messages; it does not yet launch a game frontend and does not include BaseOS's
read-only/A-B update system. It is not considered supported until it is tested
on real RG353PS hardware.

## Porting safety constraints

- Keep this target isolated from `build-all.sh` and `work/my355`; the existing
  Miyoo Flip target must continue to build unchanged.
- Never use the Miyoo preloader installer, `mtd5` patch, `miyoo355_fw.img`,
  Android boot image, stock harvest or `my355`-specific U-Boot commands on the RG353PS.
- Keep U-Boot's control DTB separate from the Linux DTB
  `rk3566-anbernic-rg353ps.dtb`.
- The image builder only writes a disk-image file. When testing, write the
  compressed image to a spare TF card and keep the original system card intact.
