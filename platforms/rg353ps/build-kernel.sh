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
        if [ "$(basename "$patch_file")" = "0007-usb-mass-storage-command-diagnostics.patch" ]; then
          echo "  skip mass-storage diagnostics patch; using checked source edits below"
          continue
        fi
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
irq_new = irq_line + irq_old
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

# Match the function independently of upstream whitespace and local pre-existing edits.
import re
irq_pattern = re.compile(
    r"(static irqreturn_t rockchip_usb2phy_bvalid_irq\(int irq, void \*data\)\s*\{"
    r".*?struct rockchip_usb2phy \*rphy = dev_get_drvdata\(rport->phy->dev.parent\);)",
    re.S,
)
def add_irq_entry(match):
    block = match.group(1)
    if "RG353PS BVALID IRQ entry:" in block:
        return block
    return block + r"""
	bool pending = property_enabled(rphy->grf, &rport->port_cfg->bvalid_det_st);
	dev_info(&rport->phy->dev,
		 "RG353PS BVALID IRQ entry: irq=%d pending=%d mode=%d state=%d bvalid=%d\n",
		 irq, pending, rport->mode, rport->state,
		 property_enabled(rphy->grf, &rport->port_cfg->utmi_bvalid));
"""
text, irq_count = irq_pattern.subn(add_irq_entry, text, count=1)
if irq_count != 1:
    raise SystemExit("Could not locate BVALID IRQ function/body: " + str(irq_count))

extcon_old = """			if (notify_charger && rphy->edev) {
				extcon_set_state_sync(rphy->edev,
							cable, vbus_attach);
				if (cable == EXTCON_CHG_USB_SDP)
					extcon_set_state_sync(rphy->edev,
							      EXTCON_USB,
							      vbus_attach);
			}
"""
extcon_new = r"""			if (notify_charger && rphy->edev) {
				dev_info(&rport->phy->dev,
					 "RG353PS extcon notify before: cable=%d vbus=%d usb=%d\\n",
					 cable, vbus_attach,
					 extcon_get_state(rphy->edev, EXTCON_USB));
				extcon_set_state_sync(rphy->edev,
							cable, vbus_attach);
				if (cable == EXTCON_CHG_USB_SDP)
					extcon_set_state_sync(rphy->edev,
							      EXTCON_USB,
							      vbus_attach);
				dev_info(&rport->phy->dev,
					 "RG353PS extcon notify after: cable=%d vbus=%d usb=%d\\n",
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
request_new = r"""			ret = devm_request_threaded_irq(rphy->dev, rport->bvalid_irq,
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

      # GRF register diagnostics were removed: the pinned kernel source does not
      # expose a uniquely matching VBUS-read anchor. Keep the already-applied
      # peripheral polling and IRQ diagnostics without blocking the kernel build.

      # Log the shared-IRQ path as well: when rphy->irq is configured,
      # port_irq_init() intentionally skips the per-port otg-bvalid IRQ.
      # In that case, BVALID events are dispatched through rockchip_usb2phy_irq.
      python3 - <<PYCODE
from pathlib import Path
import re

source = Path("$SRC/drivers/phy/rockchip/phy-rockchip-inno-usb2.c")
text = source.read_text()

def inject_function(prefix, body, label):
    global text
    pattern = re.compile(re.escape(prefix) + r".*?\)\s*\{", re.S)
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise SystemExit(f"Could not uniquely locate {label}: {len(matches)}")
    match = matches[0]
    if label in text[match.start():match.start() + 1200]:
        return
    text = text[:match.end()] + "\n" + body + text[match.end():]

inject_function(
    "static int rockchip_usb2phy_probe(",
    "\tdev_info(&pdev->dev, \"RG353PS PHY probe entry\\\\n\");",
    "RG353PS PHY probe entry:",
)

inject_function(
    "static irqreturn_t rockchip_usb2phy_irq(",
    "\tdev_info(((struct rockchip_usb2phy *)data)->dev, \"RG353PS shared PHY IRQ entry: irq=%d configured_irq=%d num_ports=%u\\\\n\",\n"
    "\t\t irq, ((struct rockchip_usb2phy *)data)->irq, ((struct rockchip_usb2phy *)data)->phy_cfg->num_ports);",
    "RG353PS shared PHY IRQ entry:",
)

inject_function(
    "static int rockchip_usb2phy_port_irq_init(",
    "\tdev_info(rphy->dev, \"RG353PS port IRQ init entry: port_id=%u mode=%d shared_irq=%d\\\\n\",\n"
    "\t\t rport->port_id, rport->mode, rphy->irq);",
    "RG353PS port IRQ init entry:",
)

# A positive shared IRQ intentionally bypasses per-port otg-bvalid registration.
early_old = """\tif (rphy->irq > 0)
\t\treturn 0;
"""
early_new = """\tif (rphy->irq > 0) {
\t\tdev_info(rphy->dev,
\t\t\t "RG353PS port IRQ init: using shared IRQ=%d; skipping per-port IRQ registration\\\\n",
\t\t\t rphy->irq);
\t\treturn 0;
\t}
"""
if text.count(early_old) == 1:
    text = text.replace(early_old, early_new, 1)
elif text.count(early_new) != 1:
    raise SystemExit("Could not uniquely instrument shared IRQ early return")

inject_function(
    "static void rockchip_usb2phy_otg_sm_work(",
    "\tdev_info(&container_of(work, struct rockchip_usb2phy_port, otg_sm_work.work)->phy->dev, \"RG353PS OTG state-machine entry\\\\n\");",
    "RG353PS OTG state-machine entry",
)

source.write_text(text)
print("Applied RG353PS probe/shared-IRQ/OTG state-machine entry diagnostics")
PYCODE

      # Windows USB2 enumeration workaround for the RG353PS DWC3 gadget.
      # The current log shows bcdUSB changing from 0x0200 before UDC bind to
      # 0x0201 afterward, which advertises USB 2.0 LPM/BOS capability. Test the
      # legacy USB2 descriptor path by disabling gadget LPM on this peripheral
      # controller only. Host-mode USB LPM is unaffected.
      python3 - <<PYCODE
from pathlib import Path

source = Path("$SRC/arch/arm64/boot/dts/rockchip/rk3566-anbernic-rgxx3.dtsi")
text = source.read_text()

old = """&usb_host0_xhci {
\tdr_mode = "peripheral";
\tphys = <&usb2phy0_otg>;
\tphy-names = "usb2-phy";
\tstatus = "okay";
};"""
new = """&usb_host0_xhci {
\tdr_mode = "peripheral";
\tphys = <&usb2phy0_otg>;
\tphy-names = "usb2-phy";
\tsnps,usb2-gadget-lpm-disable;
\tstatus = "okay";
};"""
old_count = text.count(old)
new_count = text.count(new)
if old_count == 1:
    text = text.replace(old, new, 1)
elif new_count == 1:
    pass
else:
    raise SystemExit(
        "Could not uniquely patch RG353PS DWC3 USB2 gadget LPM property: "
        f"original={old_count}, patched={new_count}"
    )
source.write_text(text)
print("Disabled USB2 LPM advertisement for the RG353PS peripheral gadget")
PYCODE

      # Add EP0 setup, direction mismatch, and ENDTRANSFER timeout diagnostics.
      # These edits only add logging; they preserve the upstream recovery behavior.
      python3 - <<PYCODE
from pathlib import Path
import re

source = Path("$SRC/drivers/usb/dwc3/ep0.c")
text = source.read_text()
bs = chr(92)

# Record each setup request so a later EP0 failure can be tied to the host request.
setup_anchor = "\tif ((ctrl->bRequestType & USB_TYPE_MASK) == USB_TYPE_STANDARD)"
setup_marker = "RG353PS EP0 SETUP type=%02x"
if setup_marker not in text:
    if text.count(setup_anchor) != 1:
        raise SystemExit("Could not uniquely locate post-parse DWC3 EP0 SETUP logging point")
    setup_lines = [
        "\tdev_info(dwc->dev,",
        "\t\t\"RG353PS EP0 SETUP type=%02x req=%02x value=%04x index=%04x len=%u state=%d expect_in=%u next=%d pending=%u connected=%u softconnect=%u pullups=%u" + bs + "n\",",
        "\t\tctrl->bRequestType, ctrl->bRequest,",
        "\t\tle16_to_cpu(ctrl->wValue), le16_to_cpu(ctrl->wIndex), len,",
        "\t\tdwc->ep0state, dwc->ep0_expect_in, dwc->ep0_next_event,",
        "\t\tdwc->setup_packet_pending, dwc->connected, dwc->softconnect,",
        "\t\tdwc->pullups_connected);",
    ]
    setup_diag = "\n".join(setup_lines)
    text = text.replace(setup_anchor, setup_diag + "\n\n" + setup_anchor, 1)

# Expand the wrong-direction message with the endpoint resource state.
direction_marker = "expect_in=%d event_ep=%d event_status=%d ep0state=%d next_event=%d"
if direction_marker not in text:
    message = "unexpected direction for Data Phase"
    positions = [m.start() for m in re.finditer(re.escape(message), text)]
    if len(positions) != 1:
        raise SystemExit("Could not uniquely locate DWC3 EP0 direction-mismatch message: " + str(len(positions)))
    pos = positions[0]
    line_start = text.rfind("\n", 0, pos) + 1
    line_end = text.find("\n", pos)
    if line_end < 0:
        line_end = len(text)
    line = text[line_start:line_end]
    if "dev_err" not in line:
        raise SystemExit("DWC3 EP0 direction-mismatch message is not in dev_err")
    indent = line[:len(line) - len(line.lstrip())]
    direction_lines = [
        indent + "dev_err(dwc->dev,",
        indent + "\t\"unexpected direction for Data Phase: expect_in=%d event_ep=%d event_status=%d ep0state=%d next_event=%d ep0out_ri=%u ep0in_ri=%u ep0out_flags=%x ep0in_flags=%x pending=%u connected=%u softconnect=%u pullups=%u" + bs + "n\",",
        indent + "\tdwc->ep0_expect_in, (int)event->endpoint_number, (int)event->status,",
        indent + "\tdwc->ep0state, dwc->ep0_next_event,",
        indent + "\tdwc->eps[0]->resource_index, dwc->eps[1]->resource_index,",
        indent + "\tdwc->eps[0]->flags, dwc->eps[1]->flags,",
        indent + "\tdwc->setup_packet_pending, dwc->connected, dwc->softconnect,",
        indent + "\tdwc->pullups_connected);",
    ]
    replacement = "\n".join(direction_lines)
    text = text[:line_start] + replacement + text[line_end:]

# Include the endpoint command context when EP0 ENDTRANSFER times out.
end_marker = "ep0 data phase end transfer failed: %d"
end_context_marker = "ENDTRANSFER context dep=%u resource_index=%u"
if end_context_marker not in text:
    if text.count(end_marker) != 1:
        raise SystemExit("Could not uniquely locate DWC3 EP0 ENDTRANSFER error")
    old_end = (
        "\tret = dwc3_send_gadget_ep_cmd(dep, cmd, &params);\n"
        "\tif (ret)\n"
        "\t\tdev_err_ratelimited(dwc->dev,\n"
        "\t\t\t\"ep0 data phase end transfer failed: %d" + bs + "n\", ret);"
    )
    if text.count(old_end) != 1:
        raise SystemExit("Could not uniquely locate complete DWC3 EP0 ENDTRANSFER call")
    new_end = (
        "\tret = dwc3_send_gadget_ep_cmd(dep, cmd, &params);\n"
        "\tif (ret)\n"
        "\t\tdev_err_ratelimited(dwc->dev,\n"
        "\t\t\t\"ep0 data phase end transfer failed: %d ENDTRANSFER context dep=%u resource_index=%u flags=%x ep0state=%d expect_in=%u next_event=%d pending=%u connected=%u softconnect=%u pullups=%u" + bs + "n\",\n"
        "\t\t\tret, dep->number, dep->resource_index, dep->flags,\n"
        "\t\t\tdwc->ep0state, dwc->ep0_expect_in, dwc->ep0_next_event,\n"
        "\t\t\tdwc->setup_packet_pending, dwc->connected, dwc->softconnect,\n"
        "\t\t\tdwc->pullups_connected);"
    )
    text = text.replace(old_end, new_end, 1)

# A stale XferNotReady(DATA) may arrive after a newer zero-length SETUP.
# If next_event is not NRDY_DATA, the current request has no data phase expected.
# Avoid ENDTRANSFER/stall recovery on that out-of-phase event; keep normal
# direction-mismatch recovery for a request that really expects DATA.
guard_marker = "RG353PS ignoring stale EP0 DATA-not-ready"
if guard_marker not in text:
    fn_start = text.find("static void dwc3_ep0_xfernotready(")
    if fn_start < 0:
        raise SystemExit("Could not locate DWC3 EP0 XferNotReady handler")
    brace = text.find("{", fn_start)
    switch_marker = "\n\tswitch (event->status) {"
    switch_at = text.find(switch_marker, brace)
    if brace < 0 or switch_at < 0:
        raise SystemExit("Could not locate DWC3 EP0 XferNotReady status switch")
    guard_lines = [
        "\tif (dwc->ep0state == EP0_SETUP_PHASE &&",
        "\t    dwc->ep0_next_event != DWC3_EP0_NRDY_DATA &&",
        "\t    event->status == DEPEVT_STATUS_CONTROL_DATA &&",
        "\t    dwc->ep0_expect_in != event->endpoint_number) {",
        "\t\tdev_warn_ratelimited(dwc->dev,",
        "\t\t\t\"RG353PS ignoring stale EP0 DATA-not-ready while waiting for completion: event_ep=%u expect_in=%u ep0state=%d next_event=%d" + bs + "n\",",
        "\t\t\tevent->endpoint_number, dwc->ep0_expect_in,",
        "\t\t\tdwc->ep0state, dwc->ep0_next_event);",
        "\t\treturn;",
        "\t}",
    ]
    text = text[:switch_at] + "\n" + "\n".join(guard_lines) + text[switch_at:]

# Guard a late EP0 IN completion that arrives after the state machine
# has already returned to SETUP phase. USB SETUP packets are received on
# endpoint 0 OUT; EP0 IN completion bytes must not be reinterpreted as a new
# setup request from the shared controller TRB buffer.
xfer_guard_marker = "RG353PS ignoring stale EP0 IN XferComplete during SETUP phase"
if xfer_guard_marker not in text:
    fn_start = text.find("static void dwc3_ep0_xfer_complete(")
    if fn_start < 0:
        raise SystemExit("Could not locate DWC3 EP0 XferComplete handler")
    fn_brace = text.find("{", fn_start)
    fn_end = text.find("\n}\n", fn_brace)
    if fn_brace < 0 or fn_end < 0:
        raise SystemExit("Could not locate DWC3 EP0 XferComplete function body")
    fn = text[fn_start:fn_end + 3]
    old_prefix = (
        "\tdep->flags &= ~DWC3_EP_TRANSFER_STARTED;\n"
        "\tdep->resource_index = 0;\n"
        "\tdwc->setup_packet_pending = false;"
    )
    if fn.count(old_prefix) != 1:
        raise SystemExit("Could not uniquely locate EP0 XferComplete state reset")
    guard_lines = [
        "\tif (dwc->ep0state == EP0_SETUP_PHASE &&",
        "\t    event->endpoint_number != 0) {",
        "\t\tstruct usb_ctrlrequest *stale = (void *)dwc->ep0_trb;",
        "\t\tdev_warn_ratelimited(dwc->dev,",
        "\t\t\t\"RG353PS ignoring stale EP0 IN XferComplete during SETUP phase: event_ep=%u event_status=%u setup=%02x.%02x value=%04x index=%04x len=%u next_event=%d setup_pending=%u\",",
        "\t\t\tevent->endpoint_number, event->status,",
        "\t\t\tstale->bRequestType, stale->bRequest,",
        "\t\t\tle16_to_cpu(stale->wValue), le16_to_cpu(stale->wIndex),",
        "\t\t\tle16_to_cpu(stale->wLength), dwc->ep0_next_event,",
        "\t\t\tdwc->setup_packet_pending);",
        "\t\tdep->flags &= ~DWC3_EP_TRANSFER_STARTED;",
        "\t\tdep->resource_index = 0;",
        "\t\treturn;",
        "\t}",
        "",
    ]
    guard = "\n".join(guard_lines) + "\n" + old_prefix
    fn = fn.replace(old_prefix, guard, 1)
    text = text[:fn_start] + fn + text[fn_end + 3:]
source.write_text(text)
print("Applied RG353PS EP0 stale IN-completion guard")

source.write_text(text)
print("Applied RG353PS DWC3 EP0 request diagnostics, stale-event guard, and timeout context")
PYCODE

      # Trace DWC3 bulk-OUT endpoint events and device reset/disconnect events.
      python3 - <<PYCODE
from pathlib import Path
import re

source = Path("$SRC/drivers/usb/dwc3/gadget.c")
text = source.read_text()

# Log physical endpoint 2 (logical USB EP1 OUT), used by mass storage.
fn_start = text.index("static void dwc3_endpoint_interrupt(")
fn_end = text.find("\n}\n", fn_start)
if fn_start < 0 or fn_end < 0:
    raise SystemExit("Could not locate DWC3 endpoint interrupt handler")
func = text[fn_start:fn_end + 3]
event_marker = "RG353PS DWC3 bulk-out event"
if event_marker not in func:
    queue_anchor = "\tdep = dwc->eps[epnum];"
    event_diag = (
        queue_anchor + "\n"
        "\tif (dep && dep->number == 2 && !dep->direction &&\n"
        "\t    (event->endpoint_event == DWC3_DEPEVT_XFERCOMPLETE ||\n"
        "\t     event->endpoint_event == DWC3_DEPEVT_XFERINPROGRESS ||\n"
        "\t     event->endpoint_event == DWC3_DEPEVT_XFERNOTREADY ||\n"
        "\t     event->endpoint_event == DWC3_DEPEVT_EPCMDCMPLT)) {\n"
        "\t\tstruct dwc3_request *req = list_first_entry_or_null(&dep->started_list, struct dwc3_request, list);\n"
        "\t\tstruct dwc3_trb *trb = req ? req->trb : NULL;\n"
        "\t\tif (event->endpoint_event == DWC3_DEPEVT_XFERCOMPLETE || event->endpoint_event == DWC3_DEPEVT_EPCMDCMPLT) {\n"
        "\t\t\tdev_info(dwc->dev,\n"
        "\t\t\t\t\"RG353PS DWC3 bulk-out event epnum=%u event=%u status=%u params=%08x flags=%08x resource=%u enq=%u deq=%u started_empty=%u pending_empty=%u req=%p req_status=%d req_len=%u req_actual=%u remaining=%u num_trbs=%u trb_dma=%llx trb_size=%08x trb_ctrl=%08x ev_count=%u ev_lpos=%u GEVNTCOUNT=%08x link_state=%u speed=%d connected=%u\\\\n\",\n"
        "\t\t\t\tepnum, event->endpoint_event, event->status, event->parameters,\n"
        "\t\t\t\tdep->flags, dep->resource_index, dep->trb_enqueue, dep->trb_dequeue,\n"
        "\t\t\t\tlist_empty(&dep->started_list), list_empty(&dep->pending_list), req,\n"
        "\t\t\t\treq ? req->status : -1, req ? req->request.length : 0,\n"
        "\t\t\t\treq ? req->request.actual : 0, req ? req->remaining : 0,\n"
        "\t\t\t\treq ? req->num_trbs : 0, req ? (unsigned long long)req->trb_dma : 0ULL,\n"
        "\t\t\t\ttrb ? le32_to_cpu(trb->size) : 0, trb ? le32_to_cpu(trb->ctrl) : 0,\n"
        "\t\t\t\tdwc->ev_buf ? dwc->ev_buf->count : 0, dwc->ev_buf ? dwc->ev_buf->lpos : 0,\n"
        "\t\t\t\tdwc3_readl(dwc, DWC3_GEVNTCOUNT(0)), dwc->link_state, dwc->gadget->speed, dwc->connected);\n"
        "\t\t} else {\n"
        "\t\t\tdev_info_ratelimited(dwc->dev,\n"
        "\t\t\t\t\"RG353PS DWC3 bulk-out event epnum=%u event=%u status=%u params=%08x flags=%08x resource=%u enq=%u deq=%u link_state=%u speed=%d connected=%u\\\\n\",\n"
        "\t\t\t\tepnum, event->endpoint_event, event->status, event->parameters,\n"
        "\t\t\t\tdep->flags, dep->resource_index, dep->trb_enqueue, dep->trb_dequeue,\n"
        "\t\t\t\tdwc->link_state, dwc->gadget->speed, dwc->connected);\n"
        "\t\t}\n"
        "\t}\n"
    )
    if func.count(queue_anchor) != 1:
        raise SystemExit("Could not uniquely locate DWC3 endpoint lookup")
    func = func.replace(queue_anchor, event_diag, 1)
    text = text[:fn_start] + func + text[fn_end + 3:]

def inject_device_event(signature, marker, log_line):
    global text
    pattern = re.compile(re.escape(signature) + r"\s*\{")
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise SystemExit("Could not uniquely locate DWC3 event function: " + signature + " count=" + str(len(matches)))
    match = matches[0]
    body_end = text.find("\n}", match.end())
    if body_end < 0:
        raise SystemExit("Could not locate DWC3 event function end: " + signature)
    if marker not in text[match.end():body_end]:
        text = text[:match.end()] + "\n" + log_line + text[match.end():]

inject_device_event(
    "static void dwc3_gadget_reset_interrupt(struct dwc3 *dwc)",
    "RG353PS DWC3 device RESET event",
    "\tdev_info(dwc->dev, \"RG353PS DWC3 device RESET event speed=%d link_state=%u connected=%u setup_pending=%u\\\\n\", dwc->gadget->speed, dwc->link_state, dwc->connected, dwc->setup_packet_pending);",
)

# Snapshot the live endpoint/request/TRB state at USB RESET, before the
# reset handler tears down EP2. This distinguishes an unconsumed hardware TRB
# from a queued-request/software-list problem.
reset_start = text.index("static void dwc3_gadget_reset_interrupt(struct dwc3 *dwc)")
reset_end = text.find("\n}\n", reset_start)
if reset_start < 0 or reset_end < 0:
    raise SystemExit("Could not locate DWC3 reset handler for EP2 snapshot")
reset_func = text[reset_start:reset_end + 3]
snapshot_marker = "RG353PS RESET EP2 snapshot"
if snapshot_marker not in reset_func:
    reset_log_prefix = "\tdev_info(dwc->dev, \"RG353PS DWC3 device RESET event"
    line_start = reset_func.find(reset_log_prefix)
    line_end = reset_func.find("\n", line_start)
    if line_start < 0 or line_end < 0:
        raise SystemExit("Could not locate DWC3 reset event log for EP2 snapshot")
    snapshot = r"""
	{
		struct dwc3_ep *out = dwc->eps[2];
		if (out) {
			struct dwc3_request *req;
			struct dwc3_trb *trb = NULL;

			req = list_first_entry_or_null(&out->started_list,
						       struct dwc3_request, list);
			if (req)
				trb = req->trb;
			else if (out->trb_pool)
				trb = &out->trb_pool[out->trb_dequeue];

			dev_info(dwc->dev,
				"RG353PS RESET EP2 snapshot flags=%08x resource=%u trb_enq=%u trb_deq=%u started_empty=%u pending_empty=%u cancelled_empty=%u req=%p req_status=%d req_len=%u req_actual=%u req_remaining=%u req_num_trbs=%u req_trb_dma=%llx trb=%p trb_bpl=%08x trb_bph=%08x trb_size=%08x trb_ctrl=%08x ev_count=%u ev_lpos=%u ev_len=%u GEVNTCOUNT=%08x GEVNTSIZ=%08x DCTL=%08x DSTS=%08x GUSB2PHYCFG=%08x GUCTL1=%08x DEPCMD=%08x PAR0=%08x PAR1=%08x PAR2=%08x\n",
				out->flags, out->resource_index, out->trb_enqueue,
				out->trb_dequeue, list_empty(&out->started_list),
				list_empty(&out->pending_list), list_empty(&out->cancelled_list),
				req, req ? req->status : -1,
				req ? req->request.length : 0,
				req ? req->request.actual : 0,
				req ? req->remaining : 0,
				req ? req->num_trbs : 0,
				req ? (unsigned long long)req->trb_dma : 0ULL,
				trb, trb ? le32_to_cpu(trb->bpl) : 0,
				trb ? le32_to_cpu(trb->bph) : 0,
				trb ? le32_to_cpu(trb->size) : 0,
				trb ? le32_to_cpu(trb->ctrl) : 0,
				dwc->ev_buf ? dwc->ev_buf->count : 0,
				dwc->ev_buf ? dwc->ev_buf->lpos : 0,
				dwc->ev_buf ? dwc->ev_buf->length : 0,
				dwc3_readl(dwc, DWC3_GEVNTCOUNT(0)),
				dwc3_readl(dwc, DWC3_GEVNTSIZ(0)),
				dwc3_readl(dwc, DWC3_DCTL), dwc3_readl(dwc, DWC3_DSTS),
				dwc3_readl(dwc, DWC3_GUSB2PHYCFG(0)),
				dwc3_readl(dwc, DWC3_GUCTL1),
				dwc3_readl(dwc, DWC3_DEPCMD(2)),
				dwc3_readl(dwc, DWC3_DEPCMDPAR0(2)),
				dwc3_readl(dwc, DWC3_DEPCMDPAR1(2)),
				dwc3_readl(dwc, DWC3_DEPCMDPAR2(2)));
		}
	}
"""
    reset_func = reset_func[:line_end + 1] + snapshot + reset_func[line_end + 1:]
    text = text[:reset_start] + reset_func + text[reset_end + 3:]

inject_device_event(
    "static void dwc3_gadget_disconnect_interrupt(struct dwc3 *dwc)",
    "RG353PS DWC3 device DISCONNECT event",
    "\tdev_info(dwc->dev, \"RG353PS DWC3 device DISCONNECT event speed=%d link_state=%u connected=%u setup_pending=%u\\\\n\", dwc->gadget->speed, dwc->link_state, dwc->connected, dwc->setup_packet_pending);",
)

# Trace START/UPDATE/END TRANSFER commands for physical endpoint 2 (USB EP1 OUT).
# usb_ep_queue returning 0 alone does not prove DWC3 actually started the transfer.
fn_start = text.index("int dwc3_send_gadget_ep_cmd(")
fn_end = text.find("\n}\n", fn_start)
if fn_start < 0 or fn_end < 0:
    raise SystemExit("Could not locate dwc3_send_gadget_ep_cmd")
func = text[fn_start:fn_end + 3]
cmd_anchor = "\tdwc3_writel(dwc, DWC3_DEPCMD(epnum), cmd);"
if "RG353PS EP2 DEPCMD begin" not in func:
    cmd_diag = r"""
	if (epnum == 2 &&
	    (DWC3_DEPCMD_CMD(cmd) == DWC3_DEPCMD_STARTTRANSFER ||
	     DWC3_DEPCMD_CMD(cmd) == DWC3_DEPCMD_UPDATETRANSFER ||
	     DWC3_DEPCMD_CMD(cmd) == DWC3_DEPCMD_ENDTRANSFER)) {
		struct dwc3_request *rg_req =
			list_first_entry_or_null(&dep->started_list, struct dwc3_request, list);
		struct dwc3_trb *rg_trb = rg_req ? rg_req->trb : NULL;
		dev_info(dwc->dev,
			"RG353PS EP2 DEPCMD begin cmd=%u raw=%08x params=%08x/%08x/%08x flags=%08x resource_index=%u trb_enq=%u trb_deq=%u req=%p req_status=%d req_len=%u req_actual=%u req_remaining=%u trb_dma=%llx trb_bpl=%08x trb_bph=%08x trb_size=%08x trb_ctrl=%08x link_state=%u speed=%d connected=%u GEVNTCOUNT=%08x GEVNTSIZ=%08x DCTL=%08x DSTS=%08x GUSB2PHYCFG=%08x GUCTL1=%08x\n",
			DWC3_DEPCMD_CMD(cmd), cmd, params ? params->param0 : 0, params ? params->param1 : 0,
			params ? params->param2 : 0, dep->flags, dep->resource_index,
			dep->trb_enqueue, dep->trb_dequeue, rg_req, rg_req ? rg_req->request.status : -1,
			rg_req ? rg_req->request.length : 0, rg_req ? rg_req->request.actual : 0,
			rg_req ? rg_req->remaining : 0, rg_req ? (unsigned long long)rg_req->trb_dma : 0ULL,
			rg_trb ? le32_to_cpu(rg_trb->bpl) : 0, rg_trb ? le32_to_cpu(rg_trb->bph) : 0,
			rg_trb ? le32_to_cpu(rg_trb->size) : 0, rg_trb ? le32_to_cpu(rg_trb->ctrl) : 0,
			dwc->link_state, dwc->gadget->speed, dwc->connected,
			dwc3_readl(dwc, DWC3_GEVNTCOUNT(0)), dwc3_readl(dwc, DWC3_GEVNTSIZ(0)),
			dwc3_readl(dwc, DWC3_DCTL), dwc3_readl(dwc, DWC3_DSTS),
		dwc3_readl(dwc, DWC3_GUSB2PHYCFG(0)), dwc3_readl(dwc, DWC3_GUCTL1));
	}
"""
    if func.count(cmd_anchor) != 1:
        raise SystemExit("Could not uniquely locate DWC3 DEPCMD write")
    func = func.replace(cmd_anchor, cmd_diag + "\n" + cmd_anchor, 1)
done_marker = "\n\treturn ret;\n}"
if "RG353PS EP2 DEPCMD done" not in func:
    cmd_done = r"""
	if (epnum == 2 &&
	    (DWC3_DEPCMD_CMD(cmd) == DWC3_DEPCMD_STARTTRANSFER ||
	     DWC3_DEPCMD_CMD(cmd) == DWC3_DEPCMD_UPDATETRANSFER ||
	     DWC3_DEPCMD_CMD(cmd) == DWC3_DEPCMD_ENDTRANSFER)) {
		struct dwc3_request *rg_req =
			list_first_entry_or_null(&dep->started_list, struct dwc3_request, list);
		struct dwc3_trb *rg_trb = rg_req ? rg_req->trb : NULL;
		dev_info(dwc->dev,
			"RG353PS EP2 DEPCMD done cmd=%u ret=%d cmd_status=%d raw=%08x flags=%08x resource_index=%u trb_enq=%u trb_deq=%u req=%p req_status=%d req_len=%u req_actual=%u req_remaining=%u trb_dma=%llx trb_bpl=%08x trb_bph=%08x trb_size=%08x trb_ctrl=%08x link_state=%u speed=%d connected=%u GEVNTCOUNT=%08x GEVNTSIZ=%08x DCTL=%08x DSTS=%08x GUSB2PHYCFG=%08x GUCTL1=%08x\n",
			DWC3_DEPCMD_CMD(cmd), ret, cmd_status,
			dwc3_readl(dwc, DWC3_DEPCMD(epnum)), dep->flags,
			dep->resource_index, dep->trb_enqueue, dep->trb_dequeue, rg_req,
			rg_req ? rg_req->request.status : -1, rg_req ? rg_req->request.length : 0,
			rg_req ? rg_req->request.actual : 0, rg_req ? rg_req->remaining : 0,
			rg_req ? (unsigned long long)rg_req->trb_dma : 0ULL,
			rg_trb ? le32_to_cpu(rg_trb->bpl) : 0, rg_trb ? le32_to_cpu(rg_trb->bph) : 0,
			rg_trb ? le32_to_cpu(rg_trb->size) : 0, rg_trb ? le32_to_cpu(rg_trb->ctrl) : 0,
			dwc->link_state, dwc->gadget->speed, dwc->connected,
			dwc3_readl(dwc, DWC3_GEVNTCOUNT(0)), dwc3_readl(dwc, DWC3_GEVNTSIZ(0)),
			dwc3_readl(dwc, DWC3_DCTL), dwc3_readl(dwc, DWC3_DSTS),
			dwc3_readl(dwc, DWC3_GUSB2PHYCFG(0)), dwc3_readl(dwc, DWC3_GUCTL1));
	}
"""
    if func.count(done_marker) != 1:
        raise SystemExit("Could not uniquely locate DWC3 DEPCMD return")
    func = func.replace(done_marker, "\n" + cmd_done + done_marker, 1)
text = text[:fn_start] + func + text[fn_end + 3:]
print("Applied RG353PS DWC3 endpoint-command diagnostics")

# Log every DWC3 device-level event, including link-state, wakeup and suspend
# transitions. The previous test shows WRITE(10) OUT requests remain HWO-owned
# for ~20 seconds, but no EP2 transfer-completion event is logged before reset.
device_event_marker = "RG353PS DWC3 device-event raw="
if device_event_marker not in text:
    event_pattern = re.compile(
        r"static void dwc3_gadget_interrupt\([^)]*\)\s*\{", re.S
    )
    event_matches = list(event_pattern.finditer(text))
    if len(event_matches) != 1:
        raise SystemExit(
            "Could not uniquely locate DWC3 device event handler: "
            f"matches={len(event_matches)}"
        )
    event_match = event_matches[0]
    event_lines = [
        "\tstatic unsigned int rg353ps_device_event_seq;",
        "\tdev_info(dwc->dev,",
        "\t\t\"RG353PS DWC3 device-event raw=%08x seq=%u speed=%d link_state=%u connected=%u ep2_flags=%08x ep2_resource=%u ep2_enq=%u ep2_deq=%u GEVNTCOUNT=%08x GEVNTSIZ=%08x DCTL=%08x DSTS=%08x GUSB2PHYCFG=%08x" + chr(92) + "n\",",
        "\t\t*(const u32 *)event, ++rg353ps_device_event_seq,",
        "\t\tdwc->gadget->speed, dwc->link_state, dwc->connected,",
        "\t\tdwc->eps[2] ? dwc->eps[2]->flags : 0,",
        "\t\tdwc->eps[2] ? dwc->eps[2]->resource_index : 0,",
        "\t\tdwc->eps[2] ? dwc->eps[2]->trb_enqueue : 0,",
        "\t\tdwc->eps[2] ? dwc->eps[2]->trb_dequeue : 0,",
        "\t\tdwc3_readl(dwc, DWC3_GEVNTCOUNT(0)),",
        "\t\tdwc3_readl(dwc, DWC3_GEVNTSIZ(0)),",
        "\t\tdwc3_readl(dwc, DWC3_DCTL), dwc3_readl(dwc, DWC3_DSTS),",
        "\t\tdwc3_readl(dwc, DWC3_GUSB2PHYCFG(0)));",
    ]
    event_diag = "\n".join(event_lines) + "\n"
    text = text[:event_match.end()] + "\n" + event_diag + text[event_match.end():]

# v14: trace every raw EP2 endpoint event before the normal event dispatcher.
# v13 rate-limited non-terminal events and only logged selected event types.
entry_start = text.index("static void dwc3_process_event_entry(")
entry_end = text.find("\n}\n", entry_start)
if entry_start < 0 or entry_end < 0:
    raise SystemExit("Could not locate DWC3 raw event entry dispatcher")
entry_func = text[entry_start:entry_end + 3]
raw_marker = "RG353PS EP2 raw-event"
if raw_marker not in entry_func:
    anchor = "\ttrace_dwc3_event(event->raw, dwc);"
    raw_diag = (
        anchor + "\n"
        "\tif (!event->type.is_devspec && event->depevt.endpoint_number == 2) {\n"
        "\t\tstruct dwc3_ep *out = dwc->eps[2];\n"
        "\t\tstruct dwc3_request *req = NULL;\n"
        "\t\tstruct dwc3_trb *trb = NULL;\n"
        "\t\tif (out) {\n"
        "\t\t\treq = list_first_entry_or_null(&out->started_list, struct dwc3_request, list);\n"
        "\t\t\tif (req)\n"
        "\t\t\t\ttrb = req->trb;\n"
        "\t\t}\n"
        "\t\tdev_info(dwc->dev,\n"
        "\t\t\t\"RG353PS EP2 raw-event raw=%08x epnum=%u event=%u status=%u params=%08x flags=%08x resource=%u enq=%u deq=%u started_empty=%u pending_empty=%u req=%p req_status=%d req_len=%u req_actual=%u remaining=%u num_trbs=%u trb_dma=%llx trb_bpl=%08x trb_bph=%08x trb_size=%08x trb_ctrl=%08x ev_count=%u ev_lpos=%u GEVNTCOUNT=%08x DCTL=%08x DSTS=%08x GUSB2PHYCFG=%08x GUCTL1=%08x\\\\n\",\n"
        "\t\t\tevent->raw, event->depevt.endpoint_number, event->depevt.endpoint_event,\n"
        "\t\t\tevent->depevt.status, event->depevt.parameters,\n"
        "\t\t\tout ? out->flags : 0, out ? out->resource_index : 0,\n"
        "\t\t\tout ? out->trb_enqueue : 0, out ? out->trb_dequeue : 0,\n"
        "\t\t\tout ? list_empty(&out->started_list) : 1,\n"
        "\t\t\tout ? list_empty(&out->pending_list) : 1, req,\n"
        "\t\t\treq ? req->status : -1, req ? req->request.length : 0,\n"
        "\t\t\treq ? req->request.actual : 0, req ? req->remaining : 0,\n"
        "\t\t\treq ? req->num_trbs : 0, req ? (unsigned long long)req->trb_dma : 0ULL,\n"
        "\t\t\ttrb ? le32_to_cpu(trb->bpl) : 0, trb ? le32_to_cpu(trb->bph) : 0,\n"
        "\t\t\ttrb ? le32_to_cpu(trb->size) : 0, trb ? le32_to_cpu(trb->ctrl) : 0,\n"
        "\t\t\tdwc->ev_buf ? dwc->ev_buf->count : 0,\n"
        "\t\t\tdwc->ev_buf ? dwc->ev_buf->lpos : 0,\n"
        "\t\t\tdwc3_readl(dwc, DWC3_GEVNTCOUNT(0)),\n"
        "\t\t\tdwc3_readl(dwc, DWC3_DCTL), dwc3_readl(dwc, DWC3_DSTS),\n"
        "\t\t\tdwc3_readl(dwc, DWC3_GUSB2PHYCFG(0)), dwc3_readl(dwc, DWC3_GUCTL1));\n"
        "\t}\n"
    )
    if entry_func.count(anchor) != 1:
        raise SystemExit("Could not uniquely locate raw DWC3 event entry anchor")
    entry_func = entry_func.replace(anchor, raw_diag, 1)
    text = text[:entry_start] + entry_func + text[entry_end + 3:]

# Ensure the new raw-event trace is applied before persisting the source.
source.write_text(text)
print("Applied RG353PS DWC3 raw EP2 event tracing v14")
PYCODE

      # Add checked diagnostics to the existing USB mass-storage function. These
      # source edits use exact markers instead of a hand-maintained unified diff.
      python3 - <<PYCODE
from pathlib import Path

source = Path("$SRC/drivers/usb/gadget/function/f_mass_storage.c")
text = source.read_text()

include_old = "#include <linux/fs.h>\n#include <linux/kstrtox.h>"
include_new = "#include <linux/fs.h>\n#include <linux/jiffies.h>\n#include <linux/kstrtox.h>"
if include_new not in text:
    count = text.count(include_old)
    if count != 1:
        raise SystemExit("Could not uniquely locate mass-storage include insertion point: " + str(count))
    text = text.replace(include_old, include_new, 1)

start_marker = "\tstatic char\t\tunknown[16];\n\n\tdump_cdb(common);"
start_lines = [
    "\tstatic char\t\tunknown[16];",
    "\tstatic unsigned int rg353ps_storage_seq;",
    "\tunsigned int rg353ps_storage_id = 0;",
    "\tunsigned long rg353ps_storage_started = 0;",
    "",
    "\tif (common->cmnd[0] == 0x0a || common->cmnd[0] == 0x2a ||",
    "\t    common->cmnd[0] == 0xaa || common->cmnd[0] == 0x8a ||",
    "\t    common->cmnd[0] == 0x35) {",
    "\t\trg353ps_storage_id = ++rg353ps_storage_seq;",
    "\t\trg353ps_storage_started = jiffies;",
    "\t\tpr_info(\"baseos-msdiag: SCSI start seq=%u op=0x%02x \"",
    "\t\t\t\"len=%u dir=%d cdb2-5=%02x%02x%02x%02x \"",
    "\t\t\t\"cdb7-8=%02x%02x" + chr(92) + "n\",",
    "\t\t\trg353ps_storage_id, common->cmnd[0],",
    "\t\t\tcommon->data_size, common->data_dir,",
    "\t\t\tcommon->cmnd[2], common->cmnd[3],",
    "\t\t\tcommon->cmnd[4], common->cmnd[5],",
    "\t\t\tcommon->cmnd[7], common->cmnd[8]);",
    "\t}",
    "\tdump_cdb(common);",
]
start_replacement = "\n".join(start_lines)
count = text.count(start_marker)
if count != 1:
    raise SystemExit("Could not uniquely locate SCSI command entry point: " + str(count))
text = text.replace(start_marker, start_replacement, 1)

finish_marker = (
    "\t\tcommon->residue -= reply;\n"
    "\t}\t\t\t\t/* Otherwise it" + chr(39) + "s already set */\n\n"
    "\treturn 0;\n}"
)
finish_lines = [
    "\t\tcommon->residue -= reply;",
    "\t}\t\t\t\t/* Otherwise it" + chr(39) + "s already set */",
    "",
    "\tif (rg353ps_storage_id)",
    "\t\tpr_info(\"baseos-msdiag: SCSI finish seq=%u op=0x%02x \"",
    "\t\t\t\"reply=%d sense=%d sense_info=%u phase_error=%d \"",
    "\t\t\t\"residue=%u short_packet=%d elapsed_ms=%u" + chr(92) + "n\",",
    "\t\t\trg353ps_storage_id, common->cmnd[0], reply,",
    "\t\t\tcommon->curlun ? common->curlun->sense_data : -1,",
    "\t\t\tcommon->curlun ? common->curlun->sense_data_info : 0,",
    "\t\t\tcommon->phase_error, common->residue,",
    "\t\t\tcommon->short_packet_received,",
    "\t\t\tjiffies_to_msecs(jiffies - rg353ps_storage_started));",
    "\treturn 0;",
    "}",
]
finish_replacement = "\n".join(finish_lines)
count = text.count(finish_marker)
if count != 1:
    raise SystemExit("Could not uniquely locate SCSI command completion point: " + str(count))
text = text.replace(finish_marker, finish_replacement, 1)

# Instrument abnormal USB bulk-OUT completions using stable callback boundaries.
bulk_out_begin = "\tdump_msg(common, \"bulk-out\", req->buf, req->actual);"
bulk_out_end = "\tif (req->status == -ECONNRESET)"
begin_count = text.count(bulk_out_begin)
if begin_count != 1:
    raise SystemExit("Could not uniquely locate Bulk-OUT callback entry: " + str(begin_count))
begin = text.index(bulk_out_begin)
end = text.find(bulk_out_end, begin + len(bulk_out_begin))
if end < 0:
    raise SystemExit("Could not locate Bulk-OUT callback end after its entry")
bulk_out_replacement = (
    "\tdump_msg(common, \"bulk-out\", req->buf, req->actual);\n"
    "\tif (req->status || req->actual != bh->bulk_out_intended_length) {\n"
    "\t\tpr_info(\"baseos-msdiag: BULK OUT mismatch op=0x%02x status=%d actual=%u intended=%u\\\\n\",\n"
    "\t\t\tcommon->cmnd[0], req->status, req->actual,\n"
    "\t\t\tbh->bulk_out_intended_length);\n"
    "\t\tDBG(common, \"%s --> %d, %u/%u\\\\n\", __func__,\n"
    "\t\t    req->status, req->actual, bh->bulk_out_intended_length);\n"
    "\t}\n"
)
text = text[:begin] + bulk_out_replacement + text[end:]

source.write_text(text)
print("Applied RG353PS SCSI and Bulk-OUT diagnostics")
PYCODE

      # Trace the Bulk-only Command Status Wrapper (CSW) independently from
      # SCSI command processing. A SCSI "finish" log is emitted before the CSW
      # is queued, so it does not prove that the host received the completion.
      python3 - <<PYCODE
from pathlib import Path

source = Path("$SRC/drivers/usb/gadget/function/f_mass_storage.c")
text = source.read_text()

# Record CSW queue attempts and usb_ep_queue() return values in start_transfer().
start = text.index("static int start_transfer(")
end = text.index("static bool start_in_transfer(", start)
func = text[start:end]
queue_marker = "baseos-msdiag: CSW queue result"
if queue_marker not in func:
    decl_old = "\tint\trc;\n\n\tif (ep == fsg->bulk_in)"
    decl_new = (
        "\tint\trc;\n"
        "\tbool rg353ps_is_csw = false;\n"
        "\tu32 rg353ps_csw_tag = 0;\n"
        "\tu8 rg353ps_csw_status = 0;\n"
        "\tu32 rg353ps_csw_residue = 0;\n\n"
        "\tif (ep == fsg->bulk_in && req->length == US_BULK_CS_WRAP_LEN) {\n"
        "\t\tstruct bulk_cs_wrap *rg353ps_csw = (void *)req->buf;\n"
        "\t\tif (le32_to_cpu(rg353ps_csw->Signature) == US_BULK_CS_SIGN) {\n"
        "\t\t\trg353ps_is_csw = true;\n"
        "\t\t\trg353ps_csw_tag = le32_to_cpu(rg353ps_csw->Tag);\n"
        "\t\t\trg353ps_csw_status = rg353ps_csw->Status;\n"
        "\t\t\trg353ps_csw_residue = le32_to_cpu(rg353ps_csw->Residue);\n"
        "\t\t\tpr_info(\"baseos-msdiag: CSW submit tag=%u status=%u residue=%u len=%u\\\\n\",\n"
        "\t\t\t\trg353ps_csw_tag, rg353ps_csw_status,\n"
        "\t\t\t\trg353ps_csw_residue, req->length);\n"
        "\t\t}\n"
        "\t}\n\n"
        "\tif (ep == fsg->bulk_in)"
    )
    if func.count(decl_old) != 1:
        raise SystemExit("Could not uniquely locate start_transfer() declarations")
    func = func.replace(decl_old, decl_new, 1)

    queue_old = "\trc = usb_ep_queue(ep, req, GFP_KERNEL);"
    queue_new = (
        queue_old + "\n"
        "\tif (rg353ps_is_csw)\n"
        "\t\tpr_info(\"baseos-msdiag: CSW queue result tag=%u rc=%d\\\\n\",\n"
        "\t\t\trg353ps_csw_tag, rc);"
    )
    if func.count(queue_old) != 1:
        raise SystemExit("Could not uniquely locate usb_ep_queue() in start_transfer()")
    func = func.replace(queue_old, queue_new, 1)
    text = text[:start] + func + text[end:]

# Record whether the host-controller endpoint completed the actual CSW request.
start = text.index("static void bulk_in_complete(")
end = text.index("static void bulk_out_complete(", start)
func = text[start:end]
complete_marker = "baseos-msdiag: CSW complete"
if complete_marker not in func:
    decl = "\tstruct fsg_buffhd\t*bh = req->context;\n"
    diag = (
        decl +
        "\n"
        "\tif (req->length == US_BULK_CS_WRAP_LEN) {\n"
        "\t\tstruct bulk_cs_wrap *rg353ps_csw = (void *)req->buf;\n"
        "\t\tif (le32_to_cpu(rg353ps_csw->Signature) == US_BULK_CS_SIGN)\n"
        "\t\t\tpr_info(\"baseos-msdiag: CSW complete tag=%u status=%u residue=%u req_status=%d actual=%u len=%u\\\\n\",\n"
        "\t\t\t\tle32_to_cpu(rg353ps_csw->Tag), rg353ps_csw->Status,\n"
        "\t\t\t\tle32_to_cpu(rg353ps_csw->Residue), req->status,\n"
        "\t\t\t\treq->actual, req->length);\n"
        "\t}\n"
    )
    if func.count(decl) != 1:
        raise SystemExit("Could not uniquely locate bulk_in_complete() callback context")
    func = func.replace(decl, diag, 1)
    text = text[:start] + func + text[end:]

source.write_text(text)
print("Applied RG353PS CSW queue/completion diagnostics")
PYCODE

      # Distinguish a queued Bulk-OUT data request that never completes from a
      # failed usb_ep_queue(). Log WRITE(10) request enqueue and completion.
      python3 - <<PYCODE
from pathlib import Path

source = Path("$SRC/drivers/usb/gadget/function/f_mass_storage.c")
text = source.read_text()

start = text.index("static bool start_out_transfer(")
end = text.index("static int sleep_thread(", start)
func = text[start:end]
queue_anchor = "\trc = start_transfer(common->fsg, common->fsg->bulk_out, bh->outreq);"
queue_new = (
    queue_anchor + "\n"
    "\tif (common->cmnd[0] == 0x2a)\n"
    "\t\tpr_info(\"baseos-msdiag: BULK OUT queue lba=%u intended=%u req_len=%u req=%p rc=%d\\\\n\",\n"
    "\t\t\tget_unaligned_be32(&common->cmnd[2]),\n"
    "\t\t\tbh->bulk_out_intended_length, bh->outreq->length,\n"
    "\t\t\tbh->outreq, rc);"
)
if "baseos-msdiag: BULK OUT queue lba=" not in func:
    if func.count(queue_anchor) != 1:
        raise SystemExit("Could not uniquely locate Bulk-OUT queue in start_out_transfer()")
    func = func.replace(queue_anchor, queue_new, 1)
text = text[:start] + func + text[end:]

start = text.index("static void bulk_out_complete(")
end = text.index("static int _fsg_common_get_max_lun(", start)
func = text[start:end]
complete_anchor = "\tdump_msg(common, \"bulk-out\", req->buf, req->actual);"
complete_new = (
    complete_anchor + "\n"
    "\tif (common->cmnd[0] == 0x2a)\n"
    "\t\tpr_info(\"baseos-msdiag: BULK OUT complete req=%p status=%d actual=%u intended=%u\\\\n\",\n"
    "\t\t\treq, req->status, req->actual,\n"
    "\t\t\tbh->bulk_out_intended_length);"
)
if "baseos-msdiag: BULK OUT complete req=" not in func:
    if func.count(complete_anchor) != 1:
        raise SystemExit("Could not uniquely locate Bulk-OUT completion callback")
    func = func.replace(complete_anchor, complete_new, 1)
text = text[:start] + func + text[end:]

source.write_text(text)
print("Applied RG353PS WRITE(10) Bulk-OUT queue/completion diagnostics")
PYCODE

      # Correlate each asynchronous Bulk-OUT callback to the SCSI command that queued it.
      # common->cmnd is shared and may already point at a newer command by callback time.
      python3 - <<PYCODE
from pathlib import Path
import re

source = Path("$SRC/drivers/usb/gadget/function/f_mass_storage.c")
text = source.read_text()

# Store the current logged SCSI sequence on fsg_common so each request can
# copy it into the individual buffer head before queueing.
common_start = text.index("struct fsg_common {")
common_end = text.index("\n};", common_start)
common = text[common_start:common_end]
common_marker = re.compile(r"(?m)^([ \t]*u32[ \t]+tag;[ \t]*)$")
common_new = r"\1\n\tu32 rg353ps_storage_seq_current;"
common_text, common_count = common_marker.subn(common_new, common, count=1)
if common_count == 1:
    text = text[:common_start] + common_text + text[common_end:]
elif "rg353ps_storage_seq_current" not in common:
    raise SystemExit("Could not uniquely add current SCSI sequence to fsg_common: " + str(common_count))

scsi_start = text.index("static int do_scsi_command(")
scsi_end = text.find("\nstatic int ", scsi_start + 1)
if scsi_end < 0:
    raise SystemExit("Could not locate end of do_scsi_command()")
scsi_func = text[scsi_start:scsi_end]
seq_anchor = "\n\tdump_cdb(common);"
seq_insert = "\n\tcommon->rg353ps_storage_seq_current = rg353ps_storage_id;\n\tdump_cdb(common);"
seq_count = scsi_func.count(seq_anchor)
if seq_count == 1:
    scsi_func = scsi_func.replace(seq_anchor, seq_insert, 1)
elif scsi_func.count(seq_insert) != 1:
    raise SystemExit("Could not uniquely assign SCSI sequence before command processing: " + str(seq_count))
text = text[:scsi_start] + scsi_func + text[scsi_end:]

# Include the BOT tag in SCSI start/finish records so they can be matched
# to CSW submit/completion records.
text, start_fmt_count = re.subn(
    r"baseos-msdiag: SCSI start seq=%u op=0x%02x",
    "baseos-msdiag: SCSI start seq=%u tag=%u op=0x%02x", text, count=1)
if start_fmt_count != 1:
    raise SystemExit("Could not uniquely extend SCSI start log with BOT tag")
text, finish_fmt_count = re.subn(
    r"baseos-msdiag: SCSI finish seq=%u op=0x%02x",
    "baseos-msdiag: SCSI finish seq=%u tag=%u op=0x%02x", text, count=1)
if finish_fmt_count != 1:
    raise SystemExit("Could not uniquely extend SCSI finish log with BOT tag")
tag_args = "\t\t\trg353ps_storage_id, common->cmnd[0],"
tag_args_new = "\t\t\trg353ps_storage_id, common->tag, common->cmnd[0],"
tag_count = text.count(tag_args)
if tag_count != 2:
    raise SystemExit("Expected two SCSI log argument lists to add BOT tags, found " + str(tag_count))
text = text.replace(tag_args, tag_args_new)

# Add durable ownership metadata to each buffer head that can own a Bulk-OUT request.
header = Path("$SRC/drivers/usb/gadget/function/storage_common.h")
htext = header.read_text()
buff_start = htext.find("struct fsg_buffhd {")
if buff_start < 0:
    raise SystemExit("Could not locate struct fsg_buffhd in storage_common.h")
buff_end = htext.find("\n};", buff_start)
if buff_end < 0:
    raise SystemExit("Could not locate end of struct fsg_buffhd")
buff = htext[buff_start:buff_end]
if "rg353ps_out_seq" not in buff:
    field_pattern = re.compile(r"(?m)^([ \t]*unsigned int[ \t]+bulk_out_intended_length;[ \t]*)$")
    replacement = (
        r"\1\n\t/* Diagnostic owner metadata for this asynchronous Bulk-OUT request. */\n"
        r"\tu32 rg353ps_out_seq;\n"
        r"\tu32 rg353ps_out_tag;\n"
        r"\tu32 rg353ps_out_lba;\n"
        r"\tu8 rg353ps_out_op;\n\tu8 rg353ps_out_is_cbw;"
    )
    buff2, field_count = field_pattern.subn(replacement, buff, count=1)
    if field_count != 1:
        raise SystemExit("Could not uniquely add per-request metadata to fsg_buffhd: " + str(field_count))
    htext = htext[:buff_start] + buff2 + htext[buff_end:]
    header.write_text(htext)

# Save request owner fields before the endpoint request is queued.
out_start = text.index("static bool start_out_transfer(")
out_end = text.index("static int sleep_thread(", out_start)
out_func = text[out_start:out_end]
state_anchor = "\tbh->state = BUF_STATE_RECEIVING;"
state_new = (
    state_anchor + "\n"
    "\tbh->rg353ps_out_is_cbw = bh->bulk_out_intended_length == 31 && bh->outreq->length == 512;\n"
    "\tbh->rg353ps_out_seq = bh->rg353ps_out_is_cbw ? 0 : common->rg353ps_storage_seq_current;\n"
    "\tbh->rg353ps_out_tag = bh->rg353ps_out_is_cbw ? 0 : common->tag;\n"
    "\tbh->rg353ps_out_op = bh->rg353ps_out_is_cbw ? 0 : common->cmnd[0];\n"
    "\tbh->rg353ps_out_lba = !bh->rg353ps_out_is_cbw && common->cmnd[0] == 0x2a ? get_unaligned_be32(&common->cmnd[2]) : 0;\n"
    "\tif (bh->rg353ps_out_is_cbw)\n"
    "\t\tpr_info(\"baseos-msdiag: BULK OUT owner kind=CBW req=%p intended=%u req_len=%u\\\\n\",\n"
    "\t\t\tbh->outreq, bh->bulk_out_intended_length, bh->outreq->length);\n"
    "\telse if (bh->rg353ps_out_op == 0x2a)\n"
    "\t\tpr_info(\"baseos-msdiag: BULK OUT owner kind=DATA seq=%u tag=%u op=0x%02x lba=%u req=%p intended=%u req_len=%u\\\\n\",\n"
    "\t\t\tbh->rg353ps_out_seq, bh->rg353ps_out_tag, bh->rg353ps_out_op,\n"
    "\t\t\tbh->rg353ps_out_lba, bh->outreq, bh->bulk_out_intended_length,\n"
    "\t\t\tbh->outreq->length);"
)
state_count = out_func.count(state_anchor)
if state_count == 1:
    out_func = out_func.replace(state_anchor, state_new, 1)
elif out_func.count("BULK OUT owner seq=%u") != 1:
    raise SystemExit("Could not uniquely tag queued Bulk-OUT request: " + str(state_count))
text = text[:out_start] + out_func + text[out_end:]

# Completion callbacks use per-request metadata, not the shared command buffer.
complete_start = text.index("static void bulk_out_complete(")
complete_end = text.index("static int _fsg_common_get_max_lun(", complete_start)
complete_func = text[complete_start:complete_end]

old_mismatch = (
    "pr_info(\"baseos-msdiag: BULK OUT mismatch op=0x%02x status=%d actual=%u intended=%u\\\\n\",\n"
    "\t\t\tcommon->cmnd[0], req->status, req->actual,\n"
    "\t\t\tbh->bulk_out_intended_length);"
)
new_mismatch = (
    "if (bh->rg353ps_out_is_cbw) {\n"
    "\t\t\tpr_info(\"baseos-msdiag: BULK OUT mismatch kind=CBW req=%p status=%d actual=%u intended=%u req_len=%u\\\\n\",\n"
    "\t\t\t\treq, req->status, req->actual, bh->bulk_out_intended_length, req->length);\n"
    "\t\t} else {\n"
    "\t\t\tpr_info(\"baseos-msdiag: BULK OUT mismatch kind=DATA seq=%u tag=%u op=0x%02x lba=%u req=%p status=%d actual=%u intended=%u\\\\n\",\n"
    "\t\t\t\tbh->rg353ps_out_seq, bh->rg353ps_out_tag, bh->rg353ps_out_op,\n"
    "\t\t\t\tbh->rg353ps_out_lba, req, req->status, req->actual, bh->bulk_out_intended_length);\n"
    "\t\t}"
)
if old_mismatch in complete_func:
    complete_func = complete_func.replace(old_mismatch, new_mismatch, 1)
elif "BULK OUT mismatch seq=%u tag=%u" not in complete_func:
    raise SystemExit("Could not replace shared-command Bulk-OUT mismatch log")

old_complete = (
    "if (common->cmnd[0] == 0x2a)\n"
    "\t\tpr_info(\"baseos-msdiag: BULK OUT complete req=%p status=%d actual=%u intended=%u\\\\n\",\n"
    "\t\t\treq, req->status, req->actual,\n"
    "\t\t\tbh->bulk_out_intended_length);"
)
new_complete = (
    "if (bh->rg353ps_out_is_cbw) {\n"
    "\t\tpr_info(\"baseos-msdiag: BULK OUT complete kind=CBW req=%p status=%d actual=%u intended=%u req_len=%u\\\\n\",\n"
    "\t\t\treq, req->status, req->actual, bh->bulk_out_intended_length, req->length);\n"
    "\t} else if (bh->rg353ps_out_op == 0x2a) {\n"
    "\t\tpr_info(\"baseos-msdiag: BULK OUT complete kind=DATA seq=%u tag=%u op=0x%02x lba=%u req=%p status=%d actual=%u intended=%u\\\\n\",\n"
    "\t\t\tbh->rg353ps_out_seq, bh->rg353ps_out_tag, bh->rg353ps_out_op,\n"
    "\t\t\tbh->rg353ps_out_lba, req, req->status, req->actual,\n"
    "\t\t\tbh->bulk_out_intended_length);\n"
    "}"
)
if old_complete in complete_func:
    complete_func = complete_func.replace(old_complete, new_complete, 1)
elif "BULK OUT complete seq=%u tag=%u" not in complete_func:
    raise SystemExit("Could not replace shared-command Bulk-OUT completion log")

text = text[:complete_start] + complete_func + text[complete_end:]
source.write_text(text)
print("Applied per-request Bulk-OUT ownership and SCSI/CSW tag correlation diagnostics")
PYCODE

      # v16: explicitly distinguish received WRITE data from post-UA throw-away data.
      python3 - <<PYCODE
from pathlib import Path

source = Path("$SRC/drivers/usb/gadget/function/f_mass_storage.c")
text = source.read_text()
header = Path("$SRC/drivers/usb/gadget/function/storage_common.h")
htext = header.read_text()

# Request path IDs: 1=actual WRITE, 2=throw-away after failed command/Unit Attention,
# 3=CBW. The path is copied into the buffer head before usb_ep_queue().
if "rg353ps_out_path" not in htext:
    marker = "\tu8 rg353ps_out_is_cbw;"
    if htext.count(marker) != 1:
        raise SystemExit("Could not uniquely add Bulk-OUT path field")
    htext = htext.replace(marker, marker + "\n\tu8 rg353ps_out_path;", 1)
    header.write_text(htext)

def edit_func(start_sig, end_sig, transform, label):
    global text
    start = text.index(start_sig)
    end = text.index(end_sig, start + len(start_sig))
    func = text[start:end]
    func2 = transform(func)
    if func2 == func:
        raise SystemExit("No changes applied to " + label)
    text = text[:start] + func2 + text[end:]

# Explicitly tag the three places which queue Bulk-OUT requests.
def patch_do_write(func):
    anchor = "\tamount_left_to_write = common->data_size_from_cmnd;\n\n\twhile (amount_left_to_write > 0) {"
    replacement = (
        "\tamount_left_to_write = common->data_size_from_cmnd;\n"
        "\tpr_info(\"baseos-msdiag: FSG WRITE enter seq=%u tag=%u op=0x%02x lba=%llu bytes=%u residue=%u usb_left=%u unit_attention=%u sense=%u\\\\n\",\n"
        "\t\tcommon->rg353ps_storage_seq_current, common->tag, common->cmnd[0],\n"
        "\t\t(unsigned long long)lba, common->data_size_from_cmnd,\n"
        "\t\tcommon->residue, common->usb_amount_left,\n"
        "\t\tcurlun->unit_attention_data, curlun->sense_data);\n\n"
        "\twhile (amount_left_to_write > 0) {"
    )
    if func.count(anchor) != 1:
        raise SystemExit("Could not uniquely locate WRITE loop entry")
    func = func.replace(anchor, replacement, 1)
    # Keep the upstream FSG buffer-sized WRITE requests and buffer pipeline.
    # Do not serialize writes or cap each USB OUT request at 512 bytes; those
    # diagnostic changes magnified scheduling latency and did not fix the stall.
    queue_anchor = (
        "\t\t\tset_bulk_out_req_length(common, bh, amount);\n"
        "\t\t\tif (!start_out_transfer(common, bh))"
    )
    queue_replacement = (
        "\t\t\tset_bulk_out_req_length(common, bh, amount);\n"
        "\t\t\tbh->rg353ps_out_path = 1;\n"
        "\t\t\tpr_info(\"baseos-msdiag: FSG WRITE queue seq=%u tag=%u lba=%llu amount=%u left_req=%u left_write=%u usb_left=%u residue=%u bh=%p req=%p state=%d\\\\n\",\n"
        "\t\t\t\tcommon->rg353ps_storage_seq_current, common->tag,\n"
        "\t\t\t\t(unsigned long long)lba, amount, amount_left_to_req,\n"
        "\t\t\t\tamount_left_to_write, common->usb_amount_left, common->residue,\n"
        "\t\t\t\tbh, bh->outreq, bh->state);\n"
        "\t\t\tif (!start_out_transfer(common, bh))"
    )
    if func.count(queue_anchor) != 1:
        raise SystemExit("Could not uniquely locate WRITE Bulk-OUT queue")
    func = func.replace(queue_anchor, queue_replacement, 1)
    wait_anchor = (
        "\t\trc = sleep_thread(common, false, bh);\n"
        "\t\tif (rc)\n"
        "\t\t\treturn rc;"
    )
    wait_replacement = (
        "\t\trc = sleep_thread(common, false, bh);\n"
        "\t\tif (rc) {\n"
        "\t\t\tpr_info(\"baseos-msdiag: FSG WRITE wait-interrupted seq=%u tag=%u rc=%d lba=%llu req=%p status=%d actual=%u intended=%u state=%d residue=%u\\\\n\",\n"
        "\t\t\t\tcommon->rg353ps_storage_seq_current, common->tag, rc,\n"
        "\t\t\t\t(unsigned long long)lba, bh->outreq, bh->outreq->status,\n"
        "\t\t\t\tbh->outreq->actual, bh->bulk_out_intended_length,\n"
        "\t\t\t\tbh->state, common->residue);\n"
        "\t\t\treturn rc;\n"
        "\t\t}\n"
        "\t\tpr_info(\"baseos-msdiag: FSG WRITE wait-complete seq=%u tag=%u lba=%llu req=%p status=%d actual=%u intended=%u state=%d residue=%u\\\\n\",\n"
        "\t\t\tcommon->rg353ps_storage_seq_current, common->tag,\n"
        "\t\t\t(unsigned long long)lba, bh->outreq, bh->outreq->status,\n"
        "\t\t\tbh->outreq->actual, bh->bulk_out_intended_length,\n"
        "\t\t\tbh->state, common->residue);"
    )
    if func.count(wait_anchor) != 1:
        raise SystemExit("Could not uniquely locate WRITE wait")
    func = func.replace(wait_anchor, wait_replacement, 1)
    write_anchor = "\t\tnwritten = kernel_write(curlun->filp, bh->buf, amount,"
    write_replacement = (
        "\t\tpr_info(\"baseos-msdiag: FSG WRITE backing-write seq=%u tag=%u lba=%llu bytes=%u offset=%llu\\\\n\",\n"
        "\t\t\tcommon->rg353ps_storage_seq_current, common->tag,\n"
        "\t\t\t(unsigned long long)lba, amount, (unsigned long long)file_offset);\n"
        + write_anchor
    )
    if func.count(write_anchor) != 1:
        raise SystemExit("Could not uniquely locate WRITE backing write")
    return func.replace(write_anchor, write_replacement, 1)

edit_func("static int do_write(struct fsg_common *common)",
          "static int do_synchronize_cache(", patch_do_write, "do_write")

def patch_throwaway(func):
    loop_anchor = (
        "\tfor (bh = common->next_buffhd_to_drain;\n"
        "\t     bh->state != BUF_STATE_EMPTY || common->usb_amount_left > 0;\n"
        "\t     bh = common->next_buffhd_to_drain) {"
    )
    loop_replacement = (
        "\tpr_info(\"baseos-msdiag: FSG DISCARD enter seq=%u tag=%u op=0x%02x residue=%u usb_left=%u sense=%u unit_attention=%u\\\\n\",\n"
        "\t\tcommon->rg353ps_storage_seq_current, common->tag, common->cmnd[0],\n"
        "\t\tcommon->residue, common->usb_amount_left,\n"
        "\t\tcommon->curlun ? common->curlun->sense_data : 0,\n"
        "\t\tcommon->curlun ? common->curlun->unit_attention_data : 0);\n"
        + loop_anchor
    )
    if func.count(loop_anchor) != 1:
        raise SystemExit("Could not uniquely locate throw-away data loop")
    func = func.replace(loop_anchor, loop_replacement, 1)
    queue_anchor = (
        "\t\t\tset_bulk_out_req_length(common, bh2, amount);\n"
        "\t\t\tif (!start_out_transfer(common, bh2))"
    )
    queue_replacement = (
        "\t\t\tset_bulk_out_req_length(common, bh2, amount);\n"
        "\t\t\tbh2->rg353ps_out_path = 2;\n"
        "\t\t\tpr_info(\"baseos-msdiag: FSG DISCARD queue seq=%u tag=%u op=0x%02x amount=%u usb_left=%u residue=%u bh=%p req=%p state=%d\\\\n\",\n"
        "\t\t\t\tcommon->rg353ps_storage_seq_current, common->tag, common->cmnd[0],\n"
        "\t\t\t\tamount, common->usb_amount_left, common->residue,\n"
        "\t\t\t\tbh2, bh2->outreq, bh2->state);\n"
        "\t\t\tif (!start_out_transfer(common, bh2))"
    )
    if func.count(queue_anchor) != 1:
        raise SystemExit("Could not uniquely locate throw-away queue")
    func = func.replace(queue_anchor, queue_replacement, 1)
    wait_anchor = (
        "\t\trc = sleep_thread(common, false, bh);\n"
        "\t\tif (rc)\n"
        "\t\t\treturn rc;"
    )
    wait_replacement = (
        "\t\trc = sleep_thread(common, false, bh);\n"
        "\t\tif (rc) {\n"
        "\t\t\tpr_info(\"baseos-msdiag: FSG DISCARD wait-interrupted seq=%u tag=%u rc=%d req=%p path=%u status=%d actual=%u intended=%u state=%d usb_left=%u residue=%u\\\\n\",\n"
        "\t\t\t\tcommon->rg353ps_storage_seq_current, common->tag, rc,\n"
        "\t\t\t\tbh->outreq, bh->rg353ps_out_path, bh->outreq->status,\n"
        "\t\t\t\tbh->outreq->actual, bh->bulk_out_intended_length,\n"
        "\t\t\t\tbh->state, common->usb_amount_left, common->residue);\n"
        "\t\t\treturn rc;\n"
        "\t\t}\n"
        "\t\tpr_info(\"baseos-msdiag: FSG DISCARD wait-complete seq=%u tag=%u req=%p path=%u status=%d actual=%u intended=%u state=%d usb_left=%u residue=%u\\\\n\",\n"
        "\t\t\tcommon->rg353ps_storage_seq_current, common->tag,\n"
        "\t\t\tbh->outreq, bh->rg353ps_out_path, bh->outreq->status,\n"
        "\t\t\tbh->outreq->actual, bh->bulk_out_intended_length,\n"
        "\t\t\tbh->state, common->usb_amount_left, common->residue);"
    )
    if func.count(wait_anchor) != 1:
        raise SystemExit("Could not uniquely locate throw-away wait")
    return func.replace(wait_anchor, wait_replacement, 1)

edit_func("static int throw_away_data(struct fsg_common *common)",
          "static int finish_reply(struct fsg_common *common)",
          patch_throwaway, "throw_away_data")

def patch_get_next(func):
    anchor = "\tset_bulk_out_req_length(common, bh, US_BULK_CB_WRAP_LEN);\n\tif (!start_out_transfer(common, bh))"
    replacement = "\tset_bulk_out_req_length(common, bh, US_BULK_CB_WRAP_LEN);\n\tbh->rg353ps_out_path = 3;\n\tif (!start_out_transfer(common, bh))"
    if func.count(anchor) != 1:
        raise SystemExit("Could not uniquely locate CBW submission")
    return func.replace(anchor, replacement, 1)

edit_func("static int get_next_command(struct fsg_common *common)",
          "static int alloc_request(", patch_get_next, "get_next_command")

# Label each queued/completed request with its origin. This prevents requests
# drained after Unit Attention from being mistaken for a WRITE that reached do_write().
start = text.index("static bool start_out_transfer(")
end = text.index("static int sleep_thread(", start)
func = text[start:end]
needle = "\tbh->rg353ps_out_is_cbw = bh->bulk_out_intended_length == 31 && bh->outreq->length == 512;"
if needle not in func:
    raise SystemExit("Could not find CBW classification in start_out_transfer")
func = func.replace(needle, needle + "\n\tif (bh->rg353ps_out_is_cbw)\n\t\tbh->rg353ps_out_path = 3;", 1)
text = text[:start] + func + text[end:]

replacements = [
    ("BULK OUT owner kind=CBW req=%p", "BULK OUT owner kind=CBW path=%u req=%p"),
    ("BULK OUT mismatch kind=CBW req=%p", "BULK OUT mismatch kind=CBW path=%u req=%p"),
    ("BULK OUT complete kind=CBW req=%p", "BULK OUT complete kind=CBW path=%u req=%p"),
    ("BULK OUT owner kind=DATA seq=%u", "BULK OUT owner kind=DATA path=%u seq=%u"),
    ("BULK OUT mismatch kind=DATA seq=%u", "BULK OUT mismatch kind=DATA path=%u seq=%u"),
    ("BULK OUT complete kind=DATA seq=%u", "BULK OUT complete kind=DATA path=%u seq=%u"),
]
for old, new in replacements:
    if text.count(old) < 1:
        raise SystemExit("Could not find expected Bulk-OUT log format: " + old)
    text = text.replace(old, new)
text = text.replace(
    "\t\t\tbh->outreq, bh->bulk_out_intended_length, bh->outreq->length);",
    "\t\t\tbh->rg353ps_out_path, bh->outreq, bh->bulk_out_intended_length, bh->outreq->length);", 1)
# Callback log lines have different indentation levels; match them independently.
import re
cbw_pattern = re.compile(r"(?m)^([ \t]*)req, req->status, req->actual, bh->bulk_out_intended_length, req->length\);$")
text, cbw_count = cbw_pattern.subn(
    r"\1bh->rg353ps_out_path, req, req->status, req->actual, bh->bulk_out_intended_length, req->length);",
    text)
if cbw_count != 2:
    raise SystemExit("Expected two CBW callback argument lists, found " + str(cbw_count))
data_pattern = re.compile(r"(?m)^([ \t]*)bh->rg353ps_out_seq, bh->rg353ps_out_tag, bh->rg353ps_out_op,")
text, data_count = data_pattern.subn(
    r"\1bh->rg353ps_out_path, bh->rg353ps_out_seq, bh->rg353ps_out_tag, bh->rg353ps_out_op,",
    text)
if data_count != 3:
    raise SystemExit("Expected three DATA diagnostic argument lists, found " + str(data_count))

# Make clear that the existing SCSI "finish" record is the return from
# do_scsi_command(), before finish_reply()/throw_away_data()/send_status().
text = text.replace(
    "baseos-msdiag: SCSI finish seq=%u tag=%u op=0x%02x",
    "baseos-msdiag: SCSI finish stage=do_scsi_command-return seq=%u tag=%u op=0x%02x",
    1
)

# Capture which data/status branch follows the SCSI handler return.
start = text.index("static int finish_reply(struct fsg_common *common)")
end = text.index("static void send_status(struct fsg_common *common)", start)
func = text[start:end]
switch_anchor = "\tswitch (common->data_dir) {"
switch_diag = (
    "\tpr_info(\"baseos-msdiag: FSG finish_reply seq=%u tag=%u op=0x%02x dir=%d residue=%u usb_left=%u short_packet=%d sense=%u unit_attention=%u\\\\n\",\n"
    "\t\tcommon->rg353ps_storage_seq_current, common->tag, common->cmnd[0],\n"
    "\t\tcommon->data_dir, common->residue, common->usb_amount_left,\n"
    "\t\tcommon->short_packet_received,\n"
    "\t\tcommon->curlun ? common->curlun->sense_data : 0,\n"
    "\t\tcommon->curlun ? common->curlun->unit_attention_data : 0);\n\n"
)
if func.count(switch_anchor) != 1:
    raise SystemExit("Could not uniquely locate finish_reply data direction switch")
func = func.replace(switch_anchor, switch_diag + switch_anchor, 1)
text = text[:start] + func + text[end:]

source.write_text(text)
print("Applied RG353PS v16 FSG WRITE-vs-DISCARD path diagnostics")
PYCODE

      # High-Speed diagnostic v25: retain EP2/TRB tracing but revert the four experimental
      # DWC3 USB2-PHY DT quirks. This isolates PHY-default behavior at High-Speed.
      python3 - <<PYCODE
from pathlib import Path

source = Path("$SRC/arch/arm64/boot/dts/rockchip/rk3566-anbernic-rg353ps.dts")
if not source.is_file():
    raise SystemExit("Could not locate RG353PS device tree for v25 USB2-PHY default test")
text = source.read_text()

# Remove the exact node override injected by earlier diagnostic builds if the
# cached source tree was reused. Do not remove any upstream property definitions.
legacy_override = """&usb_host0_xhci {
\tsnps,dis_enblslpm_quirk;
\tsnps,dis-u2-freeclk-exists-quirk;
\tsnps,dis_u2_susphy_quirk;
\tsnps,dis-tx-ipgap-linecheck-quirk;
};

/* BASEOS_RG353PS_TEST_DWC3_EP2_DEPCMD_TRACE_V16 */
"""
if legacy_override in text:
    text = text.replace(legacy_override, "", 1)
elif "BASEOS_RG353PS_TEST_DWC3_EP2_DEPCMD_TRACE_V16" in text:
    raise SystemExit("Found the legacy v16 DWC3 PHY marker without its expected override")

marker = "BASEOS_RG353PS_TEST_DWC3_EP2_DEFAULT_PHY_V25"
if marker not in text:
    text = text.rstrip() + "\n\n/* " + marker + " */\n"
source.write_text(text)
if marker not in text or legacy_override in text:
    raise SystemExit("Could not restore upstream DWC3 USB2-PHY defaults for v25")
print("Applied RG353PS v25: upstream DWC3 USB2-PHY defaults; EP2/TRB diagnostics retained")
PYCODE

      # Keep the upstream mass-storage buffer size and normal pipelined OUT requests.
      # Field tests showed that the 4 KiB buffer experiment did not stop the stall,
      # while serializing WRITE(10) requests made transfer speed substantially worse.
      # Leave the existing queue/completion and DWC3 diagnostics enabled.

      # High-Speed diagnostic v17: read-only request-map and actual backing-write timing.
      # No queue serialization, speed/PHY/buffer/noFUA changes; only trace ownership and latency.
      python3 - <<PYCODE
from pathlib import Path
import re

# FSG: capture USB request identity immediately before and after usb_ep_queue().
fsg_source = Path("$SRC/drivers/usb/gadget/function/f_mass_storage.c")
fsg_text = fsg_source.read_text()
fsg_marker = "RG353PS FSG request-map v17 phase=prequeue"
if fsg_marker not in fsg_text:
    start = fsg_text.index("static bool start_out_transfer(")
    end = fsg_text.index("static int sleep_thread(", start)
    func = fsg_text[start:end]
    queue_anchor = "\trc = start_transfer(common->fsg, common->fsg->bulk_out, bh->outreq);"
    queue_replacement = r"""
	if (bh->rg353ps_out_op == 0x2a)
		pr_info("baseos-msdiag: RG353PS FSG request-map v17 phase=prequeue path=%u seq=%u tag=%u op=0x%02x lba=%u bh=%p state=%d req=%p context=%p buf=%p dma=%llx len=%u actual=%u status=%d intended=%u\n",
			bh->rg353ps_out_path, bh->rg353ps_out_seq, bh->rg353ps_out_tag,
			bh->rg353ps_out_op, bh->rg353ps_out_lba, bh, bh->state,
			bh->outreq, bh->outreq->context, bh->outreq->buf,
			(unsigned long long)bh->outreq->dma, bh->outreq->length,
			bh->outreq->actual, bh->outreq->status,
			bh->bulk_out_intended_length);
	rc = start_transfer(common->fsg, common->fsg->bulk_out, bh->outreq);
	if (bh->rg353ps_out_op == 0x2a)
		pr_info("baseos-msdiag: RG353PS FSG request-map v17 phase=postqueue path=%u seq=%u tag=%u op=0x%02x lba=%u bh=%p state=%d req=%p context=%p buf=%p dma=%llx len=%u actual=%u status=%d intended=%u queue_rc=%d\n",
			bh->rg353ps_out_path, bh->rg353ps_out_seq, bh->rg353ps_out_tag,
			bh->rg353ps_out_op, bh->rg353ps_out_lba, bh, bh->state,
			bh->outreq, bh->outreq->context, bh->outreq->buf,
			(unsigned long long)bh->outreq->dma, bh->outreq->length,
			bh->outreq->actual, bh->outreq->status,
			bh->bulk_out_intended_length, rc);
"""
    if func.count(queue_anchor) != 1:
        raise SystemExit("Could not uniquely locate FSG Bulk-OUT queue for v17 request map")
    func = func.replace(queue_anchor, queue_replacement, 1)
    fsg_text = fsg_text[:start] + func + fsg_text[end:]

# FSG backend: measure the real kernel_write call, but do not change its synchronization.
fsg_marker_write = "RG353PS FSG WRITE backing-result v17"
if fsg_marker_write not in fsg_text:
    start = fsg_text.index("static int do_write(struct fsg_common *common)")
    end = fsg_text.index("static int do_synchronize_cache(", start)
    func = fsg_text[start:end]
    brace = func.index("{") + 1
    func = func[:brace] + "\n\tunsigned long rg353ps_write_started;\n" + func[brace:]
    write_anchor = "\t\tnwritten = kernel_write(curlun->filp, bh->buf, amount,"
    if func.count(write_anchor) != 1:
        raise SystemExit("Could not uniquely locate kernel_write in do_write for v17 timing")
    pos = func.index(write_anchor)
    func = func[:pos] + "\t\trg353ps_write_started = jiffies;\n" + func[pos:]
    pos = func.index(write_anchor)
    semi = func.index(";", pos)
    result_diag = r"""
		pr_info("baseos-msdiag: RG353PS FSG WRITE backing-result v17 seq=%u tag=%u lba=%llu requested=%u result=%lld elapsed_ms=%u file_offset_now=%llu bh=%p bh_state=%d req=%p req_status=%d req_actual=%u intended=%u\n",
			common->rg353ps_storage_seq_current, common->tag,
			(unsigned long long)lba, amount, (long long)nwritten,
			jiffies_to_msecs(jiffies - rg353ps_write_started),
			(unsigned long long)file_offset, bh, bh->state, bh->outreq,
			bh->outreq->status, bh->outreq->actual,
			bh->bulk_out_intended_length);
"""
    func = func[:semi + 1] + "\n" + result_diag + func[semi + 1:]
    fsg_text = fsg_text[:start] + func + fsg_text[end:]
fsg_source.write_text(fsg_text)
print("Applied RG353PS v17 FSG request-map and backing-write timing diagnostics")

# DWC3: map the internal controller request to the gadget USB request and TRB.
dwc_source = Path("$SRC/drivers/usb/dwc3/gadget.c")
dwc_text = dwc_source.read_text()
dwc_marker = "RG353PS EP2 REQMAP v17 phase=before-command"
if dwc_marker not in dwc_text:
    start = dwc_text.index("int dwc3_send_gadget_ep_cmd(")
    end = dwc_text.find("\n}\n", start)
    if end < 0:
        raise SystemExit("Could not locate end of dwc3_send_gadget_ep_cmd for v17 request map")
    func = dwc_text[start:end + 3]
    needle = "\t\tstruct dwc3_trb *rg_trb = rg_req ? rg_req->trb : NULL;"
    if func.count(needle) != 2:
        raise SystemExit("Expected two EP2 request snapshots in DEPCMD routine, found " + str(func.count(needle)))
    before_diag = r"""
		dev_info(dwc->dev,
			"RG353PS EP2 REQMAP v17 phase=before-command cmd=%u dwc_req=%p usb_req=%p context=%p buf=%p usb_dma=%llx trb=%p trb_dma=%llx req_status=%d req_len=%u req_actual=%u remaining=%u resource=%u enq=%u deq=%u trb_size=%08x trb_ctrl=%08x\n",
			DWC3_DEPCMD_CMD(cmd), rg_req,
			rg_req ? &rg_req->request : NULL,
			rg_req ? rg_req->request.context : NULL,
			rg_req ? rg_req->request.buf : NULL,
			rg_req ? (unsigned long long)rg_req->request.dma : 0ULL,
			rg_trb, rg_req ? (unsigned long long)rg_req->trb_dma : 0ULL,
			rg_req ? rg_req->request.status : -1,
			rg_req ? rg_req->request.length : 0,
			rg_req ? rg_req->request.actual : 0,
			rg_req ? rg_req->remaining : 0,
			dep->resource_index, dep->trb_enqueue, dep->trb_dequeue,
			rg_trb ? le32_to_cpu(rg_trb->size) : 0,
			rg_trb ? le32_to_cpu(rg_trb->ctrl) : 0);
"""
    after_diag = before_diag.replace(
        "phase=before-command", "phase=after-command"
    )
    func = func.replace(needle, needle + "\n" + before_diag, 1)
    func = func.replace(needle, needle + "\n" + after_diag, 1)
    dwc_text = dwc_text[:start] + func + dwc_text[end + 3:]
dwc_source.write_text(dwc_text)
print("Applied RG353PS v17 DWC3 USB-request/TRB mapping diagnostics")
PYCODE

      # High-Speed diagnostic v18: explicit OUT request reset, abort short DISCARD data and decode EP2 command completion.
      python3 - <<PYCODE
from pathlib import Path
import re

fsg_source = Path("$SRC/drivers/usb/gadget/function/f_mass_storage.c")
fsg_text = fsg_source.read_text()

# The controller normally initializes status and actual at queue time. Reset
# them at the function boundary too, while preserving the old values in logs.
start = fsg_text.index("static bool start_out_transfer(")
end = fsg_text.index("static int sleep_thread(", start)
func = fsg_text[start:end]
queue_anchor = "\trc = start_transfer(common->fsg, common->fsg->bulk_out, bh->outreq);"
reset_marker = "baseos-msdiag: FSG request-reuse-reset v18"
if reset_marker not in func:
    reset_code = (
        "\tif (bh->outreq->actual != 0 || bh->outreq->status != 0)\n"
        "\t\tpr_info(\"baseos-msdiag: FSG request-reuse-reset v18 path=%u seq=%u tag=%u req=%p old_actual=%u old_status=%d len=%u intended=%u\\\\n\",\n"
        "\t\t\tbh->rg353ps_out_path, bh->rg353ps_out_seq, bh->rg353ps_out_tag,\n"
        "\t\t\tbh->outreq, bh->outreq->actual, bh->outreq->status,\n"
        "\t\t\tbh->outreq->length, bh->bulk_out_intended_length);\n"
        "\tbh->outreq->actual = 0;\n"
        "\tbh->outreq->status = -EINPROGRESS;\n"
    )
    if func.count(queue_anchor) != 1:
        raise SystemExit("Could not uniquely locate FSG start_out_transfer queue call")
    func = func.replace(queue_anchor, reset_code + queue_anchor, 1)
    fsg_text = fsg_text[:start] + func + fsg_text[end:]

# A short successful OUT transfer in DISCARD means the data phase ended early.
# Do not carry on and immediately queue a new 512-byte CBW request over the
# tail of a command data phase. Use the normal BOT abort/recovery path.
start = fsg_text.index("static int throw_away_data(struct fsg_common *common)")
end = fsg_text.index("static int finish_reply(struct fsg_common *common)", start)
func = fsg_text[start:end]
short_marker = "baseos-msdiag: FSG DISCARD short-packet abort v18"
if short_marker not in func:
    complete_re = re.compile(
        r"""(?s)(\t\tpr_info\("baseos-msdiag: FSG DISCARD wait-complete.*?common->usb_amount_left, common->residue\);\n)"""
    )
    matches = list(complete_re.finditer(func))
    if len(matches) != 1:
        raise SystemExit("Could not uniquely locate FSG DISCARD completion log for short-packet guard: " + str(len(matches)))
    short_guard = r"""
		if (bh->outreq->status == 0 &&
		    bh->outreq->actual < bh->bulk_out_intended_length) {
			pr_info("baseos-msdiag: FSG DISCARD short-packet abort v18 seq=%u tag=%u req=%p actual=%u intended=%u usb_left=%u residue=%u bh=%p state=%d next_fill=%p next_drain=%p\n",
				common->rg353ps_storage_seq_current, common->tag,
				bh->outreq, bh->outreq->actual,
				bh->bulk_out_intended_length, common->usb_amount_left,
				common->residue, bh, bh->state,
				common->next_buffhd_to_fill,
				common->next_buffhd_to_drain);
			bh->state = BUF_STATE_EMPTY;
			common->next_buffhd_to_drain = bh->next;
			common->short_packet_received = 1;
			raise_exception(common, FSG_STATE_ABORT_BULK_OUT);
			return -EINTR;
		}
"""
    insert_at = matches[0].end()
    func = func[:insert_at] + short_guard + func[insert_at:]
    fsg_text = fsg_text[:start] + func + fsg_text[end:]
fsg_source.write_text(fsg_text)
print("Applied v18 FSG request-reset and short-DISCARD BOT recovery handling")

dwc_source = Path("$SRC/drivers/usb/dwc3/gadget.c")
dwc_text = dwc_source.read_text()
event_marker = "RG353PS EP2 EPCMDCMPLT v18"
if event_marker not in dwc_text:
    start = dwc_text.index("static void dwc3_gadget_endpoint_command_complete(")
    end = dwc_text.find("\n}\n", start)
    if end < 0:
        raise SystemExit("Could not locate DWC3 endpoint command-completion handler")
    func = dwc_text[start:end + 3]
    anchor = "\tif (cmd != DWC3_DEPCMD_ENDTRANSFER)"
    diag = r"""
	if (dep->number == 2) {
		struct dwc3_request *rg_req =
			list_first_entry_or_null(&dep->started_list,
						 struct dwc3_request, list);
		struct dwc3_trb *rg_trb = rg_req ? rg_req->trb : NULL;
		dev_info(dep->dwc->dev,
			 "RG353PS EP2 EPCMDCMPLT v18 status=%u params=%08x cmd=%u flags=%08x resource=%u enq=%u deq=%u started_empty=%u pending_empty=%u dwc_req=%p usb_req=%p usb_status=%d usb_len=%u usb_actual=%u remaining=%u trb_dma=%llx trb_size=%08x trb_ctrl=%08x\n",
			 event->status, event->parameters, cmd, dep->flags,
			 dep->resource_index, dep->trb_enqueue, dep->trb_dequeue,
			 list_empty(&dep->started_list), list_empty(&dep->pending_list),
			 rg_req, rg_req ? &rg_req->request : NULL,
			 rg_req ? rg_req->request.status : -1,
			 rg_req ? rg_req->request.length : 0,
			 rg_req ? rg_req->request.actual : 0,
			 rg_req ? rg_req->remaining : 0,
			 rg_req ? (unsigned long long)rg_req->trb_dma : 0ULL,
			 rg_trb ? le32_to_cpu(rg_trb->size) : 0,
			 rg_trb ? le32_to_cpu(rg_trb->ctrl) : 0);
	}
"""
    if func.count(anchor) != 1:
        raise SystemExit("Could not uniquely locate DWC3 ENDTRANSFER command check")
    func = func.replace(anchor, diag + "\n" + anchor, 1)
    dwc_text = dwc_text[:start] + func + dwc_text[end + 3:]
dwc_source.write_text(dwc_text)
print("Applied v18 DWC3 EP2 endpoint-command completion diagnostics")
PYCODE

            # High-Speed diagnostic v19: preserve normal request lifecycle and distinguish USB wait from backing-write stalls.
      python3 - <<PYCODE
from pathlib import Path

fsg_source = Path("$SRC/drivers/usb/gadget/function/f_mass_storage.c")
fsg_text = fsg_source.read_text()

# A queued request is initialized by the UDC. Keep the old-state log, but do
# not manually write the public usb_request fields before the queue operation.
reset_pair = "\tbh->outreq->actual = 0;\n\tbh->outreq->status = -EINPROGRESS;\n"
reset_count = fsg_text.count(reset_pair)
if reset_count == 1:
    fsg_text = fsg_text.replace(reset_pair, "", 1)
elif reset_count != 0:
    raise SystemExit("Unexpected count while removing v18 request-field writes: " + str(reset_count))
fsg_text = fsg_text.replace(
    "FSG request-reuse-reset v18",
    "FSG request-reuse-state v19"
)

# The v18 short-DISCARD branch duplicated the upstream error check and changed
# short_packet_received. Restore the upstream single recovery path.
guard_marker = "baseos-msdiag: FSG DISCARD short-packet abort v18"
if guard_marker in fsg_text:
    marker_pos = fsg_text.index(guard_marker)
    guard_start = fsg_text.rfind("\t\tif (bh->outreq->status == 0 &&", 0, marker_pos)
    guard_end_marker = "\t\t\treturn -EINTR;\n\t\t}"
    guard_end = fsg_text.find(guard_end_marker, marker_pos)
    if guard_start < 0 or guard_end < 0:
        raise SystemExit("Could not safely remove the redundant v18 short-DISCARD branch")
    fsg_text = fsg_text[:guard_start] + fsg_text[guard_end + len(guard_end_marker):]

# Report the exact point at which a WRITE is blocked waiting for Bulk-OUT.
start = fsg_text.index("static int do_write(struct fsg_common *common)")
end = fsg_text.index("static int do_synchronize_cache(", start)
func = fsg_text[start:end]
wait_marker = "RG353PS FSG WRITE wait-OUT v19"
if wait_marker not in func:
    wait_anchor = "\t\trc = sleep_thread(common, false, bh);"
    wait_diag = r"""
		pr_info("baseos-msdiag: RG353PS FSG WRITE wait-OUT v19 seq=%u tag=%u lba=%llu amount_left_req=%u amount_left_write=%u bh=%p bh_state=%d req=%p req_status=%d req_actual=%u intended=%u\\n",
			common->rg353ps_storage_seq_current, common->tag,
			(unsigned long long)lba, amount_left_to_req,
			amount_left_to_write, bh, bh->state, bh->outreq,
			bh->outreq->status, bh->outreq->actual,
			bh->bulk_out_intended_length);
"""
    if func.count(wait_anchor) != 1:
        raise SystemExit("Could not uniquely locate the WRITE Bulk-OUT wait: " + str(func.count(wait_anchor)))
    func = func.replace(wait_anchor, wait_diag + wait_anchor, 1)

# Report entry to kernel_write, not only its return. If enter has no matching
# backing-result, that localizes the stall to the backing filesystem/block path.
backing_marker = "RG353PS FSG WRITE backing-enter v19"
if backing_marker not in func:
    write_anchor = "\t\trg353ps_write_started = jiffies;\n\t\tnwritten = kernel_write(curlun->filp, bh->buf, amount,"
    backing_diag = r"""
		pr_info("baseos-msdiag: RG353PS FSG WRITE backing-enter v19 seq=%u tag=%u lba=%llu amount=%u file_offset=%llu bh=%p bh_state=%d req=%p req_status=%d req_actual=%u intended=%u\\n",
			common->rg353ps_storage_seq_current, common->tag,
			(unsigned long long)lba, amount,
			(unsigned long long)file_offset, bh, bh->state,
			bh->outreq, bh->outreq->status, bh->outreq->actual,
			bh->bulk_out_intended_length);
"""
    if func.count(write_anchor) != 1:
        raise SystemExit("Could not uniquely locate the kernel_write timing anchor: " + str(func.count(write_anchor)))
    func = func.replace(write_anchor, backing_diag + write_anchor, 1)

fsg_text = fsg_text[:start] + func + fsg_text[end:]
fsg_source.write_text(fsg_text)
print("Applied v19 WRITE-stage tracing and restored standard request/short-discard handling")
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

      # High-Speed diagnostic v29: restore upstream DWC3 transfer lifecycle.
      # Keep the diagnostic tracing, but never ENDTRANSFER/restart EP2 after each request.
      python3 - <<PYCODE
from pathlib import Path
import re

source = Path("$SRC/drivers/usb/dwc3/gadget.c")
if not source.is_file():
    raise SystemExit("Could not locate DWC3 gadget source for v29 cleanup")
text = source.read_text()

# Remove only the prior diagnostic non-stream LST overrides, if present in a
# reused source tree. Leave upstream TRB control handling untouched.
legacy_patterns = [
    r"\t/\* BASEOS_RG353PS_EP2_BULK_OUT_LST_PER_REQUEST_V26 \*/\n"
    r"\tif \(dep->number == 2 &&\n"
    r"\t    usb_endpoint_dir_out\(dep->endpoint.desc\) &&\n"
    r"\t    !dep->stream_capable && trb_length == 512 && !chain\)\n"
    r"\t\ttrb->ctrl \|= DWC3_TRB_CTRL_LST;\n",
    r"\t/\* BASEOS_RG353PS_EP2_BULK_OUT_LST_FOR_WRITE_CHUNK_V27 \*/\n"
    r"\tif \(dep->number == 2 &&\n"
    r"\t    usb_endpoint_dir_out\(dep->endpoint.desc\) &&\n"
    r"\t    !dep->stream_capable && is_last && trb_length == 512 && !chain\)\n"
    r"\t\ttrb->ctrl \|= DWC3_TRB_CTRL_LST;\n",
]
for pattern in legacy_patterns:
    text = re.sub(pattern, "", text, count=1)

# Remove the v28 ENDTRANSFER hook from a reused source tree. The original
# END_TRANSFER_PENDING check below the hook is retained verbatim.
marker = "BASEOS_RG353PS_EP2_IDLE_OUT_ENDTRANSFER_RESTART_V28"
if marker in text:
    pattern = re.compile(
        r"\t/\* BASEOS_RG353PS_EP2_IDLE_OUT_ENDTRANSFER_RESTART_V28 \*/.*?"
        r"(?=\tif \(dep->flags & DWC3_EP_END_TRANSFER_PENDING\)\n"
        r"\t\tgoto out;)",
        re.S,
    )
    text, removed = pattern.subn("", text, count=1)
    if removed != 1:
        raise SystemExit("Could not safely remove the v28 idle EP2 OUT ENDTRANSFER hook")

for legacy_marker in (
    "BASEOS_RG353PS_EP2_BULK_OUT_LST_PER_REQUEST_V26",
    "BASEOS_RG353PS_EP2_BULK_OUT_LST_FOR_WRITE_CHUNK_V27",
    "BASEOS_RG353PS_EP2_IDLE_OUT_ENDTRANSFER_RESTART_V28",
):
    if legacy_marker in text:
        raise SystemExit("Legacy DWC3 transfer experiment remains: " + legacy_marker)
source.write_text(text)

fsg_source = Path("$SRC/drivers/usb/gadget/function/f_mass_storage.c")
if not fsg_source.is_file():
    raise SystemExit("Could not locate mass-storage function source for v29 cleanup")
fsg_text = fsg_source.read_text()
old_tag = (
    "\t/* BASEOS_RG353PS_FSG_TAG_LST_WRITE_CHUNK_V27 */\n"
    "\t/* Diagnostic marker only: non-stream DWC3 uses this only in the paired v27 test. */\n"
    "\tbh->outreq->is_last = bh->rg353ps_out_path == 1 &&\n"
    "\t\tbh->bulk_out_intended_length == 512;\n"
)
if old_tag in fsg_text:
    fsg_text = fsg_text.replace(old_tag, "", 1)
if "BASEOS_RG353PS_FSG_TAG_LST_WRITE_CHUNK_V27" in fsg_text:
    raise SystemExit("Legacy v27 request.is_last marker remains in mass-storage function")
fsg_source.write_text(fsg_text)

print("Applied RG353PS v29: upstream DWC3 transfer lifecycle; native FSG WRITE chunking/pipeline; standard TRB flags")
PYCODE

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
  "usb_storage_diagnostic_revision": "usb-high-speed-dwc3-upstream-ep2-normal-fsg-write-v29",
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
