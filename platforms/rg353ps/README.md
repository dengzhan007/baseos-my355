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

## Porting constraints

- Keep this target separate from `build-all.sh` and the current `work/my355`
  pipeline until the kernel, rootfs and card layout are explicitly implemented.
- Do not use Miyoo Flip's preloader installer, `mtd5` patch, `miyoo355_fw.img`,
  Android boot image, stock harvest, or Miyoo-specific `my355` U-Boot commands.
- Use the Linux DTB `rk3566-anbernic-rg353ps.dtb` from a verified RG353PS
  kernel build. Do not substitute U-Boot's control DTB for the Linux DTB.
- Test first from a removable SD card and retain a known-good recovery card.
  A successful compile is not proof of a successful boot; the first full image
  needs real-device testing.

## Next milestones

1. Choose and pin the RG353PS kernel and Linux DTB source (ROCKNIX is the
   baseline reference).
2. Build a rootfs without assuming Miyoo-specific vendor libraries or firmware.
3. Define and test the RG353PS SD-card partition/boot configuration and produce
   a complete image without internal-flash modifications.
4. Port BaseOS boot, read-only rootfs, settings and update behavior in separate
   stages, with shell tests and hardware validation between them.
