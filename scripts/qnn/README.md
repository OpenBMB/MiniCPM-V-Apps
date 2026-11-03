# MiniCPM-OCR vision tower on the Hexagon NPU

Optional. OCR runs the 4x vision tower on the CPU out of the box; this turns it
into a Hexagon (QNN HTP) graph, which is roughly two orders of magnitude faster
per crop.

Measured on Snapdragon 8 Elite (HTP V85), Android 17, QAIRT 2.51.200.

## What it saves

One vision-encoder pass per layout box. On the CPU the 4x ViT costs about 78 s
per crop, and a dense A4 page has ~30 boxes. On the NPU the encoder is under a
second per crop, so the page stops being encoder-bound.

## One binary per DSP generation

An HTP graph is compiled for exactly one DSP architecture, so a binary only runs
on chips of that generation. The app maps the SoC to a generation, loads the
matching file, and then asks the driver to confirm the generation matches before
the session is opened. Anything unlisted keeps the CPU vision tower and says so
in the log.

`QnnVit.VALIDATED_SOCS` in the Android client is the list that decides this. It
is deliberately not a general SoC-to-generation table: calling into QNN on a part
whose DSP generation has no matching stub has been seen to abort the process
rather than return an error, so a part is only added once a binary for it has
been built and actually run on the hardware.

| Hexagon | Graph file | Validated on |
|---|---|---|
| v85 | `minicpm-ocr-qnn-v85.bin` | SM8750, SM8975 (Snapdragon 8 Elite / 8 Elite Gen 5) |
| v69 / v73 / v75 | `minicpm-ocr-qnn-v<arch>.bin` | build the binary, then add the part |

The DSP skeleton (`libQnnHtpV<arch>Skel.so`) must be in
`app/src/main/assets/qnn/` for every generation you intend to serve; the app
extracts the one matching the device. Today only v85 ships, so other Qualcomm
parts fall back to the CPU even when the binary is present.

## Layout

The graph takes the same linear canvas the iOS CoreML/ANE build uses: 1024
patches of 14x14 laid end to end along the width, `[1, 3, 14, 14336]`. Patches
are copied at native resolution and the slack stays zero, so one binary covers
every aspect ratio. The grid is a runtime input, not a compile-time constant.

That costs some extra graph inputs:

| Input | Shape | Type | Meaning |
|---|---|---|---|
| `image` | `[1, 3, 14, 14336]` | fp16 | packed patches, RGB |
| `position_ids` | `[1024]` | int32 | position bucket per patch |
| `merger_ds_idx_0..3` | `[256]` | int32 | the four 2x2 gather corners |
| `attn_bias` | `[1024]` | fp16 | 0 for real patches, -3e4 for padding |

`attn_bias` is not optional. Attention runs over the whole canvas, so without it
the zero padding still lands in every softmax denominator and shifts the real
tokens: cosine drops to 0.94 on a 6x110 crop and 0.78 on a 16x16 one. Masked,
both match the 2d graph at 1.0000000.

## Producing the binaries

Needs QAIRT 2.51.200 on an x86_64 Linux host. The converter is a Python entry
point, so the usual numpy / pyyaml / packaging apply, and `onnx` must stay on
1.18.x: QAIRT 2.51 reads `onnx.version.version`, which onnx 1.23 removed.

```bash
export QAIRT=/path/to/qairt/2.51.200

# 1) weights out of the published mmproj
python3 convert/extract_weights.py <mmproj-f16-4x.gguf> vit.pt

# 2) ONNX. --linear is required; --merger-gelu tanh too, because HTP has no
#    Erf and the merger is the only exact-erf GELU in the model.
python3 convert/export_onnx.py vit.pt out/minicpm-ocr-vit.onnx \
    --linear --fp16 --merger-gelu tanh

# 3) one context binary per generation
for a in v69 v73 v75 v85; do
    convert/convert_to_dlc.sh out/minicpm-ocr-vit.onnx minicpm-ocr-qnn-$a $a
done
```

`export_onnx.py` verifies itself against PyTorch before writing: expect cosine
1.0000000 at fp32 and 0.99997 or better at fp16.

Also collect the matching skeletons from the SDK, one per generation:

```bash
cp $QAIRT/lib/hexagon-v85/unsigned/libQnnHtpV85Skel.so app/src/main/assets/qnn/
```

## Using the binaries

The app never downloads these by itself. Fetch or build them, then push each one
the device can actually use:

```bash
adb push minicpm-ocr-qnn-v85.bin /data/local/tmp/
adb shell run-as com.tianchi.minicpmv mkdir -p files/models/minicpm-ocr-1.0
adb shell "run-as com.tianchi.minicpmv cp /data/local/tmp/minicpm-ocr-qnn-v85.bin \
           files/models/minicpm-ocr-1.0/"
```

Confirm it engaged:

```bash
adb logcat -s QnnVit | grep -E "probe|tower ready|chunk fed"
# probe: Hexagon arch = 85
# NPU vision tower ready (graph '...', 7 inputs, 256 rows)
# eval_chunks_with_npu: image chunk fed from NPU (<n> tokens)
```

Expected fallbacks, all of which keep OCR working on the CPU:

```
no FastRPC transport; OCR will use the ggml vision tower
no context binary for arch v75 at ...; OCR will use the ggml vision tower
```

Nothing QNN-related is tracked by git: the headers and `.so` files live in the
QAIRT SDK, and the binaries are per-architecture. The code in
`app/src/main/cpp/qnn_vit.{h,cpp}` builds either way.

## Verify

`verify/` holds the numerical checks used to justify the swap. `ref_encoder`
runs the ggml tower on a fixed input and dumps tokens; `compare_npu.py` diffs
those against the NPU's. `mtmd_shape_probe` reports the token count mtmd derives
for a given image, which is what the two sides have to agree on.

## Known limit

Layout detection emits line-level boxes, and a box wider than the 448-px slice
keeps its native pixels in this layout instead of being squashed. Content that
is wide *and* tall at once can still exceed the 1024-patch canvas; those crops
drop their bottom rows in row-major order, so full-width columns survive.
