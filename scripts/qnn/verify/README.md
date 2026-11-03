# Verifying the PyTorch port against ggml

The port is only trusted because it reproduces ggml's encoder, not because it
looks right. Two stages:

## 1. Build the reference encoder

```bash
export LLAMA_SRC=/path/to/llama.cpp-omni
export LLAMA_BUILD=$LLAMA_SRC/build-mac-ref     # any Release build works
./build_ref_encoder.sh
```

It links against `libmtmd`, which exports `clip_image_encode()`, so nothing in
ggml has to be rebuilt.

## 2. Compare

```bash
export MMPROJ=/path/to/MiniCPM-OCR-1_0-mmproj-F16-4x.gguf
python3 verify.py            # PyTorch (fp32)  vs  ggml, per-tensor dumps
python3 verify_linear.py     # same, for the CoreML-style linear layout
```

`verify.py` feeds both implementations the *same* preprocessed `float32` buffer,
so a mismatch can only come from the model, never from image resizing. It
compares 13 named tensors (`pos_embed`, the first layer's q/k/v and attention
output, `post_ln`, `merger_out`) instead of just the final embedding, so a
wrong result says *where* it went wrong.

## Runtime comparison against device output

```bash
python3 compare_npu.py npu_448x448.f32 dumps/448x448/final.f32
```

Reports max/mean absolute difference, relative error, and cosine. The device
numbers in the parent `README.md` come from this. Bit-exactness is not expected: HTP
accumulates fp16 in a different association order and the merger uses the tanh
GELU approximation.

## What each file is

| File | Purpose |
|---|---|
| `ref_encoder.cpp` | ggml reference: mmproj in, preprocessed RGB in, embeddings out |
| `verify.py` | PyTorch 2D layout vs reference, per-tensor |
| `compare_npu.py` | device output vs reference, cosine + relative error |
| `mtmd_shape_probe.cpp` | what mtmd's preprocessor *sizes* an image to, without paying for a ViT pass |
| `build_probe.sh` | builds the shape probe against the same build tree |
