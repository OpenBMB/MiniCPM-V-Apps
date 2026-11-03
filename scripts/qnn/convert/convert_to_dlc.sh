#!/bin/bash
# Convert the exported OCR ViT (ONNX, fp16) into a QNN context binary for HTP V85.
#
# Written against QAIRT 2.51.200 on x86_64 Linux. Nothing here is
# device-specific: the resulting .bin runs on any Snapdragon with V85 (8 Elite),
# but it is bound to (a) the exact input shape baked into the ONNX and (b) the
# QAIRT major.minor that produced it, because libQnnHtp.so / the DSP skel must
# match (a vendor-partition skel from an older QAIRT fails with an undefined
# `qnn_2_51_200_skel_handle_invoke`).
#
# Usage:
#   export QAIRT=/path/to/qairt/2.51.200
#   ./convert_to_dlc.sh vit_448x448_fp16.onnx vit_448x448
#
# Inputs : <onnx>            e.g. vit_448x448_fp16.onnx (+ its .data sidecar)
# Outputs: <name>.dlc        ~879 MB, converter intermediate
#          <name>.bin        ~897 MB, the context binary the app loads
set -euo pipefail

ONNX=${1:?usage: convert_to_dlc.sh <onnx> <name> [arch]}
NAME=${2:?usage: convert_to_dlc.sh <onnx> <name> [arch]}
ARCH=${3:-v85}
: "${QAIRT:?set QAIRT to the QAIRT 2.51.200 install root}"

BIN_DIR="$QAIRT/bin/x86_64-linux-clang"
LIB_DIR="$QAIRT/lib/x86_64-linux-clang"

# HTP graphs are compiled for one DSP architecture, so a binary only runs on
# chips of that generation. This is the target arch, not the build host.
case "$ARCH" in
    v68|v69|v73|v75|v79|v81|v85|v89) ;;
    *) echo "unsupported arch '$ARCH'" >&2; exit 1 ;;
esac

[[ -f "$ONNX" ]] || { echo "missing $ONNX" >&2; exit 1; }
[[ -f "$ONNX.data" ]] || echo "warning: $ONNX.data not found; is the model >2 GB?" >&2

WORK=$(cd "$(dirname "$ONNX")" && pwd)
cd "$WORK"

# ---------------------------------------------------------------------------
# 1) ONNX -> DLC
# ---------------------------------------------------------------------------
# HTP executes fp16 anyway, so the fp16 export is what we convert. The
# converter is a Python entry point; it needs numpy/pyyaml/packaging and
# onnx==1.18.0 -- QAIRT 2.51 reads `onnx.version.version`, which onnx 1.23
# removed, so a newer onnx dies with AttributeError before it reads the model.
"$BIN_DIR/qairt-converter" \
    -i "$(basename "$ONNX")" \
    --float_bitwidth 16 \
    --target_backend HTP \
    --output_path "$NAME.dlc"

# ---------------------------------------------------------------------------
# 2) HTP backend config
# ---------------------------------------------------------------------------
# Two non-obvious requirements, both discovered the hard way:
#
#   * graph_names must equal the DLC's internal graph name, which is the DLC
#     basename without the extension. A mismatch is silently ignored: the
#     binary still gets produced, just without this graph's settings.
#   * fp16_relaxed_precision is a no-op from QAIRT 2.35 onwards ("determined
#     based on SoC support"); regenerating with it flipped produced a
#     byte-identical binary here. Left out on purpose rather than kept as a
#     knob that does nothing.
cat > "$NAME.htp_config.json" <<EOF
{
  "graphs": [
    {
      "graph_names": ["$NAME"],
      "vtcm_mb": 8
    }
  ],
  "devices": [
    {
      "dsp_arch": "$ARCH",
      "pd_session": "unsigned"
    }
  ]
}
EOF

# The generator's --config_file is read by the *extension* library, and it only
# looks inside "backend_extensions". Passing {"graphs": ...} at the top level
# makes every key an "Unknown Key" that is logged and dropped, so the binary is
# silently built with defaults.
cat > "$NAME.backend_ext.json" <<EOF
{
  "backend_extensions": {
    "shared_library_path": "$LIB_DIR/libQnnHtpNetRunExtensions.so",
    "config_file_path": "$WORK/$NAME.htp_config.json"
  }
}
EOF

# ---------------------------------------------------------------------------
# 3) DLC -> context binary
# ---------------------------------------------------------------------------
# --binary_file takes the stem only; the tool appends .bin itself, so passing
# "$NAME.bin" yields "$NAME.bin.bin".
"$BIN_DIR/qnn-context-binary-generator" \
    --backend "$LIB_DIR/libQnnHtp.so" \
    --dlc_path "$NAME.dlc" \
    --binary_file "$NAME" \
    --config_file "$NAME.backend_ext.json" \
    --output_dir . \
    --log_level info

ls -l "$NAME.dlc" "$NAME.bin"
echo
echo "Push to the device (the app never downloads this file):"
echo "  adb push $NAME.bin /data/local/tmp/"
echo "  adb shell run-as <applicationId> mkdir -p files/models/minicpm-ocr-1.0"
echo "  adb shell \"run-as <applicationId> cp /data/local/tmp/$NAME.bin files/models/minicpm-ocr-1.0/\""
