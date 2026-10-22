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
        "\t\t\t\"RG353PS ignoring stale EP0 IN XferComplete during SETUP phase: event_ep=%u event_status=%u setup=%02x.%02x value=%04x index=%04x len=%u next_event=%d setup_pending=%u\\n\",",
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
