#!/bin/sh
# Build a ROCKNIX-derived Linux kernel/DTB/modules set for RG353PS.
#
# This is an intermediate kernel bundle, NOT a complete BaseOS image.
# It does not flash media or touch the handheld's internal storage.
set -eu

PLATFORM_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$PLATFORM_DIR/../.." && pwd)"
HERE="$REPO_ROOT"
# shellcheck source=../../tools/common.sh
. "$REPO_ROOT/tools/common.sh"

KERNEL_VERSION="7.2.7"
KERNEL_SHA256="4ac34c47db2540ffb2713943f8d891ff1702e0ba6934525a493b7d1cad43145a"
KERNEL_URL="https://www.kernel.org/pub/linux/kernel/v7.x/linux-${KERNEL_VERSION}.tar.xz"
KERNEL_RELEASE_SUFFIX="-baseos-rg353ps"
ROCKNIX_REF="becc8cb2a97b8b44b25d39dd5b6aa8f77b0af1c5"

BASEOS_WORK="${RG353PS_WORK:-$REPO_ROOT/work/rg353ps}"
WORK="${RG353PS_KERNEL_WORK:-$BASEOS_WORK/kernel}"
FIRMWARE_OUT="$BASEOS_WORK/firmware"
REGDB_CERT="$PLATFORM_DIR/kernel/certs/wens.x509.pem"
TARBALL="$WORK/linux-${KERNEL_VERSION}.tar.xz"
PATCHSET="$WORK/patches.rg353ps"
INPUT_KEY_FILE="$WORK/inputs.sha256"
OUTPUT="$WORK/output"

for cmd in curl docker; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "missing required command: $cmd" >&2
    exit 1
  }
done

mkdir -p "$WORK" "$OUTPUT"

[ -s "$REGDB_CERT" ] || { echo "missing pinned Wens regulatory-database certificate: $REGDB_CERT" >&2; exit 1; }
if [ ! -s "$FIRMWARE_OUT/regulatory.db" ] || [ ! -s "$FIRMWARE_OUT/regulatory.db.p7s" ]; then
  echo "== collecting firmware, including early-boot regulatory database =="
  "$PLATFORM_DIR/build-firmware.sh"
fi
REGDB_SHA="$(baseos_sha256 "$FIRMWARE_OUT/regulatory.db")"
REGDB_SIG_SHA="$(baseos_sha256 "$FIRMWARE_OUT/regulatory.db.p7s")"
REGDB_CERT_SHA="$(baseos_sha256 "$REGDB_CERT")"

if [ ! -f "$TARBALL" ] || [ "$(baseos_sha256 "$TARBALL")" != "$KERNEL_SHA256" ]; then
  echo "== downloading Linux $KERNEL_VERSION =="
  rm -f "$TARBALL.part"
  curl -fL --retry 3 -o "$TARBALL.part" "$KERNEL_URL"
  got="$(baseos_sha256 "$TARBALL.part")"
  [ "$got" = "$KERNEL_SHA256" ] || {
    echo "Linux source SHA-256 mismatch: expected $KERNEL_SHA256, got $got" >&2
    rm -f "$TARBALL.part"
    exit 1
  }
  mv "$TARBALL.part" "$TARBALL"
fi

# Keep patch application order aligned with ROCKNIX's kernel package:
# RK3566 device patches, then RK3566/Rockchip RK817 power-supply patches.
cat "$PLATFORM_DIR"/kernel/patches/rk3566/*.patch \
    "$PLATFORM_DIR"/kernel/patches/mainline-rockchip/*.patch > "$PATCHSET"
PATCH_SHA="$(baseos_sha256 "$PATCHSET")"
CONFIG_SHA="$(baseos_sha256 "$PLATFORM_DIR/kernel/config/linux.aarch64.conf")"
BUILDER_SHA="$(baseos_sha256 "$PLATFORM_DIR/build-kernel.sh")"
printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
  "$KERNEL_VERSION" "$ROCKNIX_REF" "$PATCH_SHA" "$CONFIG_SHA" \
  "$REGDB_SHA" "$REGDB_SIG_SHA" "$REGDB_CERT_SHA" "$BUILDER_SHA" > "$INPUT_KEY_FILE"
INPUT_KEY="$(baseos_sha256 "$INPUT_KEY_FILE")"

echo "== building Linux $KERNEL_VERSION for RG353PS =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$WORK":/work \
  -v "$PLATFORM_DIR/kernel":/inputs:ro \
  -v "$FIRMWARE_OUT":/regdb-fw:ro \
  -e KERNEL_VERSION="$KERNEL_VERSION" \
  -e KERNEL_RELEASE_SUFFIX="$KERNEL_RELEASE_SUFFIX" \
  -e KERNEL_SHA256="$KERNEL_SHA256" \
  -e INPUT_KEY="$INPUT_KEY" \
  -e PATCH_SHA="$PATCH_SHA" \
  -e CONFIG_SHA="$CONFIG_SHA" \
  -e ROCKNIX_REF="$ROCKNIX_REF" \
  -e REGDB_SHA="$REGDB_SHA" \
  -e REGDB_SIG_SHA="$REGDB_SIG_SHA" \
  -e REGDB_CERT_SHA="$REGDB_CERT_SHA" \
  debian:bookworm-slim sh -euc '
    export DEBIAN_FRONTEND=noninteractive
    apt-get -qq update
    apt-get -qq install -y --no-install-recommends \
      build-essential bc bison flex libssl-dev libelf-dev libncurses-dev \
      device-tree-compiler rsync kmod dwarves python3 python3-dev xz-utils zstd \
      ca-certificates openssl

    if [ "$(uname -m)" = aarch64 ]; then
      CROSS=""
    else
      CROSS=aarch64-linux-gnu-
      apt-get -qq install -y --no-install-recommends gcc-aarch64-linux-gnu
    fi

    SRC="/work/src/linux-$KERNEL_VERSION"
    OUT="/work/output"
    mkdir -p /work/src "$OUT"

    if [ ! -d "$SRC" ] ||
       [ "$(cat "$SRC/.baseos-rg353ps-input-key" 2>/dev/null || true)" != "$INPUT_KEY" ]; then
      rm -rf "$SRC"
      tar -xf "/work/linux-$KERNEL_VERSION.tar.xz" -C /work/src
      test -f "$SRC/Makefile" || {
        echo "unexpected Linux source archive layout" >&2
        exit 1
      }

      for patch_file in /inputs/patches/rk3566/*.patch; do
        echo "  patch: RK3566/$(basename "$patch_file")"
        patch -s -p1 -d "$SRC" --batch --forward < "$patch_file"
      done
      for patch_file in /inputs/patches/mainline-rockchip/*.patch; do
        echo "  patch: mainline-rockchip/$(basename "$patch_file")"
        patch -s -p1 -d "$SRC" --batch --forward < "$patch_file"
      done

      # Apply the RG353PS Hantro JPEG colorimetry workaround directly to the
      # pinned kernel source. Keep this as an exact, checked source edit rather
      # than a hand-maintained unified-diff hunk, so CI fails with a clear
      # message if the upstream context ever changes.
      python3 - <<PYCODE
from pathlib import Path

source = Path("$SRC/drivers/media/platform/verisilicon/hantro_v4l2.c")
text = source.read_text()

raw_defaults_old = """\tfmt->colorspace = V4L2_COLORSPACE_JPEG;
\tfmt->ycbcr_enc = V4L2_YCBCR_ENC_DEFAULT;
\tfmt->quantization = V4L2_QUANTIZATION_DEFAULT;
\tfmt->xfer_func = V4L2_XFER_FUNC_DEFAULT;"""
raw_defaults_new = """\tif (fmt->pixelformat == V4L2_PIX_FMT_JPEG) {
\t\t/* V4L2_COLORSPACE_JPEG is shorthand; other fields must be zero. */
\t\tfmt->colorspace = V4L2_COLORSPACE_JPEG;
\t\tfmt->ycbcr_enc = V4L2_YCBCR_ENC_DEFAULT;
\t\tfmt->quantization = V4L2_QUANTIZATION_DEFAULT;
\t\tfmt->xfer_func = V4L2_XFER_FUNC_DEFAULT;
\t} else {
\t\tfmt->colorspace = V4L2_COLORSPACE_SRGB;
\t\tfmt->ycbcr_enc = V4L2_MAP_YCBCR_ENC_DEFAULT(fmt->colorspace);
\t\tfmt->quantization =
\t\t\tV4L2_MAP_QUANTIZATION_DEFAULT(false, fmt->colorspace,
\t\t\t\t\t\t      fmt->ycbcr_enc);
\t\tfmt->xfer_func = V4L2_MAP_XFER_FUNC_DEFAULT(fmt->colorspace);
\t}"""
old_count = text.count(raw_defaults_old)
new_count = text.count(raw_defaults_new)
if old_count == 1:
    text = text.replace(raw_defaults_old, raw_defaults_new, 1)
elif new_count == 1:
    pass  # already modified by a prior matching patch; safe to continue
else:
    raise SystemExit(
        "Could not uniquely locate Hantro raw-format defaults: "
        f"original={old_count}, patched={new_count}"
    )

out_old = """\t/* Colorimetry information are always propagated. */
\tctx->dst_fmt.colorspace = pix_mp->colorspace;
\tctx->dst_fmt.ycbcr_enc = pix_mp->ycbcr_enc;
\tctx->dst_fmt.xfer_func = pix_mp->xfer_func;
\tctx->dst_fmt.quantization = pix_mp->quantization;"""
out_new = """\tif (ctx->is_encoder && ctx->dst_fmt.pixelformat == V4L2_PIX_FMT_JPEG) {
\t\t/* V4L2_COLORSPACE_JPEG is shorthand; other fields must be zero. */
\t\tctx->dst_fmt.colorspace = V4L2_COLORSPACE_JPEG;
\t\tctx->dst_fmt.ycbcr_enc = V4L2_YCBCR_ENC_DEFAULT;
\t\tctx->dst_fmt.quantization = V4L2_QUANTIZATION_DEFAULT;
\t\tctx->dst_fmt.xfer_func = V4L2_XFER_FUNC_DEFAULT;
\t} else {
\t\t/* Colorimetry information are always propagated. */
\t\tctx->dst_fmt.colorspace = pix_mp->colorspace;
\t\tctx->dst_fmt.ycbcr_enc = pix_mp->ycbcr_enc;
\t\tctx->dst_fmt.xfer_func = pix_mp->xfer_func;
\t\tctx->dst_fmt.quantization = pix_mp->quantization;
\t}"""
out_old_count = text.count(out_old)
out_new_count = text.count(out_new)
if out_old_count == 1:
    text = text.replace(out_old, out_new, 1)
elif out_new_count == 1:
    pass
else:
    raise SystemExit(
        "Could not uniquely locate Hantro output colorimetry propagation: "
        f"original={out_old_count}, patched={out_new_count}"
    )

src_old = """\t/* Colorimetry information are always propagated. */
\tctx->src_fmt.colorspace = pix_mp->colorspace;
\tctx->src_fmt.ycbcr_enc = pix_mp->ycbcr_enc;
\tctx->src_fmt.xfer_func = pix_mp->xfer_func;
\tctx->src_fmt.quantization = pix_mp->quantization;"""
src_new = """\tif (ctx->is_encoder && pix_mp->pixelformat == V4L2_PIX_FMT_JPEG) {
\t\tctx->src_fmt.colorspace = V4L2_COLORSPACE_SRGB;
\t\tctx->src_fmt.ycbcr_enc = V4L2_YCBCR_ENC_601;
\t\tctx->src_fmt.xfer_func = V4L2_XFER_FUNC_SRGB;
\t\tctx->src_fmt.quantization = V4L2_QUANTIZATION_LIM_RANGE;
\t} else {
\t\t/* Colorimetry information are always propagated. */
\t\tctx->src_fmt.colorspace = pix_mp->colorspace;
\t\tctx->src_fmt.ycbcr_enc = pix_mp->ycbcr_enc;
\t\tctx->src_fmt.xfer_func = pix_mp->xfer_func;
\t\tctx->src_fmt.quantization = pix_mp->quantization;
\t}"""
src_old_count = text.count(src_old)
src_new_count = text.count(src_new)
if src_old_count == 1:
    text = text.replace(src_old, src_new, 1)
elif src_new_count == 1:
    pass
else:
    raise SystemExit(
        "Could not uniquely locate Hantro CAPTURE-to-OUTPUT colorimetry propagation: "
        f"original={src_old_count}, patched={src_new_count}"
    )

needle = """\tvpu_debug(0, "CAPTURE codec mode: %d\\\\n", ctx->vpu_dst_fmt->codec_mode);"""
replacement = """\tif (ctx->is_encoder && pix_mp->pixelformat == V4L2_PIX_FMT_JPEG) {
\t\t/* V4L2_COLORSPACE_JPEG is shorthand; other fields must be zero. */
\t\tpix_mp->colorspace = V4L2_COLORSPACE_JPEG;
\t\tpix_mp->ycbcr_enc = V4L2_YCBCR_ENC_DEFAULT;
\t\tpix_mp->quantization = V4L2_QUANTIZATION_DEFAULT;
\t\tpix_mp->xfer_func = V4L2_XFER_FUNC_DEFAULT;
\t\tctx->dst_fmt.colorspace = pix_mp->colorspace;
\t\tctx->dst_fmt.ycbcr_enc = pix_mp->ycbcr_enc;
\t\tctx->dst_fmt.quantization = pix_mp->quantization;
\t\tctx->dst_fmt.xfer_func = pix_mp->xfer_func;
\t}

""" + needle
count = text.count(needle)
if count != 1:
    raise SystemExit(f"Expected exactly one Hantro CAPTURE debug anchor, found {count}")
source.write_text(text.replace(needle, replacement, 1))
print("Applied checked Hantro JPEG CAPTURE colorimetry fix")
PYCODE

      # Keep the peripheral-only RG353PS USB2 PHY available for VBUS detection.
      # These checked replacements are part of the build rather than a hand-written
      # unified diff, so source context/count mismatches fail with an explicit error.
      python3 - <<PYCODE
from pathlib import Path

source = Path("$SRC/drivers/phy/rockchip/phy-rockchip-inno-usb2.c")
text = source.read_text()

marker = """static void rockchip_usb2phy_otg_sm_work(struct work_struct *work)
{
"""
helper_and_marker = """/*
 * Peripheral-only ports must stay available for VBUS detection and gadget
 * setup. Avoid state-machine power-off transitions in this mode.
 */
static void rockchip_usb2phy_sm_power_off(struct rockchip_usb2phy_port *rport)
{
	if (rport->mode == USB_DR_MODE_PERIPHERAL)
		return;

	rockchip_usb2phy_power_off(rport->phy);
}

static void rockchip_usb2phy_otg_sm_work(struct work_struct *work)
{
"""
if text.count(marker) != 1:
    raise SystemExit(
        "Could not uniquely locate Rockchip USB2 OTG state machine: "
        f"found {text.count(marker)}"
    )
if "static void rockchip_usb2phy_sm_power_off(" in text:
    raise SystemExit("USB2 peripheral PHY helper already exists unexpectedly")
text = text.replace(marker, helper_and_marker, 1)

otg_start = text.index("static void rockchip_usb2phy_otg_sm_work")
otg_end = text.index("static const char *chg_to_string", otg_start)
otg = text[otg_start:otg_end]
otg_count = otg.count("rockchip_usb2phy_power_off(rport->phy);")
if otg_count != 4:
    raise SystemExit(
        "Unexpected power-off call count in USB2 OTG state machine: "
        f"{otg_count}, expected 4"
    )
otg = otg.replace(
    "rockchip_usb2phy_power_off(rport->phy);",
    "rockchip_usb2phy_sm_power_off(rport);"
)
text = text[:otg_start] + otg + text[otg_end:]

chg_start = text.index("static void rockchip_chg_detect_work")
chg_end = text.index("static void rockchip_usb2phy_sm_work", chg_start)
chg = text[chg_start:chg_end]
chg_count = chg.count("rockchip_usb2phy_power_off(rport->phy);")
if chg_count != 1:
    raise SystemExit(
        "Unexpected power-off call count in USB2 charger detection: "
        f"{chg_count}, expected 1"
    )
chg = chg.replace(
    "rockchip_usb2phy_power_off(rport->phy);",
    "rockchip_usb2phy_sm_power_off(rport);"
)
text = text[:chg_start] + chg + text[chg_end:]

source.write_text(text)
print("Applied checked RG353PS USB2 peripheral PHY fix (5 state-machine call sites)")
PYCODE

      # Instrument the RG353PS peripheral PHY and re-sample VBUS even when
      # the BVALID IRQ does not fire. Keep edits anchored to unique source code.
      python3 - <<PYCODE
from pathlib import Path

source = Path("$SRC/drivers/phy/rockchip/phy-rockchip-inno-usb2.c")
text = source.read_text()

mode_old = "\trport->mode = of_usb_get_dr_mode_by_phy(child_np, -1);" + chr(10)
mode_format = "RG353PS USB PHY mode: port=%pOF mode=%d id=%u" + chr(92) + "n"
mode_line = chr(9) + "dev_info(rphy->dev, \"" + mode_format + "\", child_np, rport->mode, rport->port_id);" + chr(10)
mode_new = mode_old + mode_line
mode_old_count = text.count(mode_old)
if mode_old_count == 1:
    text = text.replace(mode_old, mode_new, 1)
elif text.count(mode_new) == 1:
    pass
else:
    raise SystemExit("Could not uniquely locate USB PHY mode assignment: " + str(mode_old_count))

import re

# Restrict the sample counter, VBUS read and periodic polling to the OTG
# state-machine function. The charger-detection worker has a similar VBUS
# read, but it must not use this function-local counter.
otg_start = text.index("static void rockchip_usb2phy_otg_sm_work(struct work_struct *work)")
otg_end = text.index("static const char *chg_to_string", otg_start)
otg = text[otg_start:otg_end]

counter_old = "\tbool vbus_attach, sch_work, notify_charger;" + chr(10)
counter_new = counter_old + "\tstatic unsigned int rg353ps_peripheral_samples;" + chr(10)
counter_count = otg.count(counter_old)
if counter_count == 1:
    otg = otg.replace(counter_old, counter_new, 1)
elif otg.count(counter_new) == 1:
    pass
else:
    raise SystemExit("Could not uniquely locate OTG sample counter declaration: " + str(counter_count))

vbus_pattern = re.compile(
    r"\tvbus_attach = property_enabled\(rphy->grf,\s*&rport->port_cfg->utmi_bvalid\);\n"
)
vbus_marker = "RG353PS USB PHY OTG sample:"
vbus_matches = list(vbus_pattern.finditer(otg))
if len(vbus_matches) == 1:
    match = vbus_matches[0]
    after = otg[match.end():match.end() + 700]
    if vbus_marker not in after:
        vbus_format = "RG353PS USB PHY OTG sample: mode=%d state=%d bvalid=%d suspended=%d host_extcon=%d" + chr(92) + "n"
        log_line = (
            "\tif (rport->mode != USB_DR_MODE_PERIPHERAL ||\n"
            "\t    (++rg353ps_peripheral_samples % 5) == 1)\n"
            "\t\tdev_info(&rport->phy->dev, \"" + vbus_format
            + "\", rport->mode, rport->state, vbus_attach, rport->suspended, "
            + "rphy->edev ? extcon_get_state(rphy->edev, EXTCON_USB_HOST) : -ENODEV);\n"
        )
        otg = otg[:match.end()] + log_line + otg[match.end():]
elif len(vbus_matches) == 0 and vbus_marker in otg:
    pass
else:
    raise SystemExit("Could not uniquely locate OTG state-machine VBUS read: " + str(len(vbus_matches)))

# In B_IDLE, keep the fixed-peripheral PHY state machine polling at its normal
# two-second cadence so VBUS can be detected without a working edge interrupt.
poll_anchor = "\t\tif (rport->vbus_attached != vbus_attach) {"
poll_insert = (
    "\t\tif (rport->mode == USB_DR_MODE_PERIPHERAL)\n"
    "\t\t\tsch_work = true;\n\n"
)
poll_count = otg.count(poll_anchor)
if poll_count == 1:
    if not otg.startswith(poll_insert, otg.find(poll_anchor)):
        otg = otg.replace(poll_anchor, poll_insert + poll_anchor, 1)
elif poll_count == 0 and poll_insert in otg:
    pass
else:
    raise SystemExit("Could not uniquely locate OTG B_IDLE polling point: " + str(poll_count))

text = text[:otg_start] + otg + text[otg_end:]

irq_old = "\tif (!property_enabled(rphy->grf, &rport->port_cfg->bvalid_det_st))" + chr(10) + "\t\treturn IRQ_NONE;" + chr(10)
irq_line = chr(9) + "dev_info(&rport->phy->dev, \"RG353PS USB PHY VBUS-valid IRQ observed" + chr(92) + "n\");" + chr(10)
irq_new = irq_old + irq_line
irq_count = text.count(irq_old)
if irq_count == 1:
    text = text.replace(irq_old, irq_new, 1)
elif text.count(irq_new) == 1:
    pass
else:
    raise SystemExit("Could not uniquely locate BVALID IRQ check: " + str(irq_count))

source.write_text(text)
print("Applied RG353PS peripheral VBUS polling and rate-limited PHY diagnostics")
PYCODE


      # Add targeted BVALID IRQ and extcon diagnostics to distinguish
      # "IRQ never fires" from "IRQ fires but PHY status is not valid".
      python3 - <<PYCODE
from pathlib import Path

source = Path("$SRC/drivers/phy/rockchip/phy-rockchip-inno-usb2.c")
text = source.read_text()

irq_old = """static irqreturn_t rockchip_usb2phy_bvalid_irq(int irq, void *data)
{
	struct rockchip_usb2phy_port *rport = data;
	struct rockchip_usb2phy *rphy = dev_get_drvdata(rport->phy->dev.parent);

	if (!property_enabled(rphy->grf, &rport->port_cfg->bvalid_det_st))
		return IRQ_NONE;
"""
irq_new = """static irqreturn_t rockchip_usb2phy_bvalid_irq(int irq, void *data)
{
	struct rockchip_usb2phy_port *rport = data;
	struct rockchip_usb2phy *rphy = dev_get_drvdata(rport->phy->dev.parent);
	bool pending = property_enabled(rphy->grf, &rport->port_cfg->bvalid_det_st);

	dev_info(&rport->phy->dev,
		 "RG353PS BVALID IRQ entry: irq=%d pending=%d mode=%d state=%d bvalid=%d\n",
		 irq, pending, rport->mode, rport->state,
		 property_enabled(rphy->grf, &rport->port_cfg->utmi_bvalid));

	if (!pending)
		return IRQ_NONE;
"""
irq_count = text.count(irq_old)
if irq_count == 1:
    text = text.replace(irq_old, irq_new, 1)
elif text.count(irq_new) != 1:
    raise SystemExit("Could not uniquely patch BVALID IRQ entry: " + str(irq_count))

extcon_old = """			if (notify_charger && rphy->edev) {
				extcon_set_state_sync(rphy->edev,
							cable, vbus_attach);
				if (cable == EXTCON_CHG_USB_SDP)
					extcon_set_state_sync(rphy->edev,
							      EXTCON_USB,
							      vbus_attach);
			}
"""
extcon_new = """			if (notify_charger && rphy->edev) {
				dev_info(&rport->phy->dev,
					 "RG353PS extcon notify before: cable=%d vbus=%d usb=%d\n",
					 cable, vbus_attach,
					 extcon_get_state(rphy->edev, EXTCON_USB));
				extcon_set_state_sync(rphy->edev,
							cable, vbus_attach);
				if (cable == EXTCON_CHG_USB_SDP)
					extcon_set_state_sync(rphy->edev,
							      EXTCON_USB,
							      vbus_attach);
				dev_info(&rport->phy->dev,
					 "RG353PS extcon notify after: cable=%d vbus=%d usb=%d\n",
					 cable, vbus_attach,
					 extcon_get_state(rphy->edev, EXTCON_USB));
			}
"""
extcon_count = text.count(extcon_old)
if extcon_count == 1:
    text = text.replace(extcon_old, extcon_new, 1)
elif text.count(extcon_new) != 1:
    raise SystemExit("Could not uniquely patch extcon notification block: " + str(extcon_count))

request_old = """			ret = devm_request_threaded_irq(rphy->dev, rport->bvalid_irq,
							NULL,
							rockchip_usb2phy_bvalid_irq,
							IRQF_ONESHOT,
							"rockchip_usb2phy_bvalid",
							rport);
			if (ret) {
"""
request_new = """			ret = devm_request_threaded_irq(rphy->dev, rport->bvalid_irq,
							NULL,
							rockchip_usb2phy_bvalid_irq,
							IRQF_ONESHOT,
							"rockchip_usb2phy_bvalid",
							rport);
			dev_info(rphy->dev,
				 "RG353PS BVALID IRQ request: irq=%d result=%d mode=%d\\n",
				 rport->bvalid_irq, ret, rport->mode);
			if (ret) {
"""
request_count = text.count(request_old)
if request_count == 1:
    text = text.replace(request_old, request_new, 1)
elif text.count(request_new) != 1:
    raise SystemExit("Could not uniquely patch BVALID IRQ request logging: " + str(request_count))

source.write_text(text)
print("Applied RG353PS BVALID IRQ entry, registration, and extcon-notify diagnostics")
PYCODE

      # cfg80211 is built into this kernel and can request the regdb before
      # the SD root partition is available. Embed both files in the kernel.
      test -s /regdb-fw/regulatory.db
      test -s /regdb-fw/regulatory.db.p7s
      cp /regdb-fw/regulatory.db "$SRC/regulatory.db"
      cp /regdb-fw/regulatory.db.p7s "$SRC/regulatory.db.p7s"

      # This pinned kernel does not trust the current wireless-regdb Wens
      # signing key by default. Add its X.509 cert as an extra regdb key.
      mkdir -p "$SRC/net/wireless/certs/regdb-extra"
      openssl x509 -in /inputs/certs/wens.x509.pem -outform DER \
        -out "$SRC/net/wireless/certs/regdb-extra/wens.x509"

      cp /inputs/config/linux.aarch64.conf "$SRC/.config"
      cd "$SRC"
      ./scripts/config --enable CONFIG_CFG80211_CERTIFICATION_ONUS
      ./scripts/config --enable CONFIG_CFG80211_REQUIRE_SIGNED_REGDB
      ./scripts/config --enable CONFIG_CFG80211_USE_KERNEL_REGDB_KEYS
      ./scripts/config --set-str CONFIG_CFG80211_EXTRA_REGDB_KEYDIR "$SRC/net/wireless/certs/regdb-extra"
      ./scripts/config --set-str CONFIG_EXTRA_FIRMWARE "regulatory.db regulatory.db.p7s"
      ./scripts/config --set-str CONFIG_EXTRA_FIRMWARE_DIR "$SRC"
      ./scripts/config --set-str CONFIG_DEFAULT_HOSTNAME "BaseOS-RG353PS"
      ./scripts/config --set-str CONFIG_LOCALVERSION "$KERNEL_RELEASE_SUFFIX"
      # ROCKNIX injects its own initramfs path at package-build time. BaseOS
      # boots from its SD-card root partition, so never leave the placeholder.
      ./scripts/config --set-str CONFIG_INITRAMFS_SOURCE ""
      # Avoid embedding debug symbols into the intermediate kernel/modules.
      ./scripts/config --disable CONFIG_DEBUG_INFO
      ./scripts/config --disable CONFIG_DEBUG_INFO_DWARF5
      ./scripts/config --disable CONFIG_DEBUG_INFO_BTF
      ./scripts/config --disable CONFIG_DEBUG_INFO_BTF_MODULES
      export ARCH=arm64 CROSS_COMPILE="$CROSS" SOURCE_DATE_EPOCH=0
      make olddefconfig
      grep -Fqx 'CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y' .config || {
        echo "signed regulatory-database verification was disabled" >&2; exit 1;
      }
      grep -Fqx 'CONFIG_CFG80211_USE_KERNEL_REGDB_KEYS=y' .config || {
        echo "kernel regulatory-database key support is disabled" >&2; exit 1;
      }
      grep -Fqx "CONFIG_CFG80211_EXTRA_REGDB_KEYDIR=\"$SRC/net/wireless/certs/regdb-extra\"" .config || {
        echo "Wens certificate directory was not retained in kernel config" >&2; exit 1;
      }
      grep -Fqx "CONFIG_EXTRA_FIRMWARE=\"regulatory.db regulatory.db.p7s\"" .config || {
        echo "early-boot regulatory database was not embedded" >&2; exit 1;
      }
      grep -Fqx "CONFIG_EXTRA_FIRMWARE_DIR=\"$SRC\"" .config || {
        echo "kernel extra-firmware source directory was not retained" >&2; exit 1;
      }
      printf "%s\n" "$INPUT_KEY" > "$SRC/.baseos-rg353ps-input-key"
    fi

    cd "$SRC"
    export ARCH=arm64 CROSS_COMPILE="$CROSS" SOURCE_DATE_EPOCH=0
    export KBUILD_BUILD_USER=baseos KBUILD_BUILD_HOST=rg353ps
    make -j"$(nproc)" Image dtbs modules

    DTB="$SRC/arch/arm64/boot/dts/rockchip/rk3566-anbernic-rg353ps.dtb"
    test -s "$SRC/arch/arm64/boot/Image" || {
      echo "kernel Image was not produced" >&2
      exit 1
    }
    test -s "$DTB" || {
      echo "RG353PS DTB missing: $DTB" >&2
      exit 1
    }

    KREL="$(make -s kernelrelease)"
    rm -rf "$OUT/modules-root"
    mkdir -p "$OUT/modules-root"
    make modules_install INSTALL_MOD_PATH="$OUT/modules-root" INSTALL_MOD_STRIP=1
    MODDIR="$OUT/modules-root/lib/modules/$KREL"
    test -d "$MODDIR" || {
      echo "modules were not installed for kernel release $KREL" >&2
      exit 1
    }
    rm -f "$MODDIR/build" "$MODDIR/source"

    cp "$SRC/arch/arm64/boot/Image" "$OUT/Image"
    cp "$DTB" "$OUT/rk3566-anbernic-rg353ps.dtb"
    cp "$SRC/.config" "$OUT/linux.config"
    cp "$SRC/System.map" "$OUT/System.map"
    cp "$SRC/Module.symvers" "$OUT/Module.symvers"
    tar --zstd -cf "$OUT/modules-$KREL.tar.zst" -C "$MODDIR" .
    rm -rf "$OUT/modules-root"

    cat > "$OUT/kernel-build.json" <<EOF
{
  "target": "Anbernic RG353PS",
  "soc": "Rockchip RK3566",
  "kernel_version": "$KERNEL_VERSION",
  "kernel_release": "$KREL",
  "kernel_source_sha256": "$KERNEL_SHA256",
  "rocknix_distribution_commit": "$ROCKNIX_REF",
  "rk3566_patch_set_sha256": "$PATCH_SHA",
  "kernel_config_sha256": "$CONFIG_SHA",
  "regulatory_database_sha256": "$REGDB_SHA",
  "regulatory_signature_sha256": "$REGDB_SIG_SHA",
  "regdb_signing_certificate_sha256": "$REGDB_CERT_SHA",
  "regulatory_database_embedded_in_kernel": true,
  "device_tree": "rk3566-anbernic-rg353ps.dtb",
  "complete_sd_image": false,
  "hardware_tested": false
}
EOF
    cd "$OUT"
    sha256sum Image rk3566-anbernic-rg353ps.dtb "modules-$KREL.tar.zst" linux.config System.map Module.symvers kernel-build.json > SHA256SUMS
    echo "Built kernel $KREL and RG353PS DTB under $OUT"
  '

echo
echo "Kernel intermediate artifacts in $OUTPUT:"
for f in "$OUTPUT/Image" "$OUTPUT/rk3566-anbernic-rg353ps.dtb" "$OUTPUT/kernel-build.json" "$OUTPUT/SHA256SUMS"; do
  [ -f "$f" ] || { echo "missing expected output: $f" >&2; exit 1; }
  printf "  %-40s %s\n" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
done
echo "The modules bundle is also in $OUTPUT; this is not a complete SD-card image."
