# RG353PS kernel inputs

The Linux build target uses pinned inputs taken from ROCKNIX's RK3566 build
recipe. The original upstream definitions are recorded here for traceability.

- ROCKNIX distribution commit: `becc8cb2a97b8b44b25d39dd5b6aa8f77b0af1c5`
- Linux stable release: `7.2.7`
- Source URL: https://www.kernel.org/pub/linux/kernel/v7.x/linux-7.2.7.tar.xz
- Source SHA-256: `4ac34c47db2540ffb2713943f8d891ff1702e0ba6934525a493b7d1cad43145a`
- Kernel config: `linux.aarch64.conf`, copied from
  `projects/ROCKNIX/devices/RK3566/linux/linux.aarch64.conf`
- Device patches: copied from
  `projects/ROCKNIX/devices/RK3566/patches/linux/`
- RK817 power supply patches: copied from
  `projects/ROCKNIX/packages/linux/patches/mainline-rockchip/`

The upstream kernel already contains
`arch/arm64/boot/dts/rockchip/rk3566-anbernic-rg353ps.dts`. The build target
compiles that DTB from the exact same patched source tree as the `Image` and
kernel modules; it does not substitute the U-Boot control tree for Linux's DTB.

The config file's ROCKNIX-specific initramfs placeholder is deliberately cleared
by the builder because BaseOS will use a root partition on the SD card. The
result is only a kernel bundle. A matching full SD-card image, userspace,
firmware files, boot arguments, and real-device validation are still required.
