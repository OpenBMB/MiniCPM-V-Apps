#!/usr/bin/env python3
"""Extract every tensor of the 4x mmproj GGUF into a torch state dict.

The GGUF reader hands back numpy arrays whose *last* axis is ggml's ne[0]
(ggml is column-major, numpy is row-major), so the numpy shape of a 2-D
weight `[in, out]` comes out as `(out, in)` -- which is exactly what
`torch.nn.Linear` stores.  The same reversal gives
`v.patch_embd.weight` as `(out_ch, in_ch, kh, kw)`, i.e. `nn.Conv2d` layout.

Quantised types are stored as raw bytes; only BF16 / F16 / F32 appear in
this file and all three are converted losslessly to float32.

Usage:
    python3 extract_weights.py <mmproj.gguf> <out.pt>
"""

import sys

import numpy as np
import torch
import gguf

# ggml_type ids we care about
GGML_TYPE_F32 = 0
GGML_TYPE_F16 = 1
GGML_TYPE_BF16 = 30


def _bf16_to_f32(raw_u8: np.ndarray) -> np.ndarray:
    """Reinterpret raw little-endian bf16 bytes as float32."""
    u16 = np.ascontiguousarray(raw_u8).view(np.uint16)
    return ((u16.astype(np.uint32) << 16).view(np.float32))


def read_gguf_state_dict(path: str, verbose: bool = True) -> dict:
    reader = gguf.GGUFReader(path)
    out = {}

    for t in reader.tensors:
        name = t.name
        ttype = t.tensor_type

        if ttype == GGML_TYPE_F32:
            arr = np.array(t.data, dtype=np.float32, copy=True)
        elif ttype == GGML_TYPE_F16:
            arr = np.array(t.data, dtype=np.float16, copy=True).astype(np.float32)
        elif ttype == GGML_TYPE_BF16:
            # t.data is a uint8 view of ggml's ne order (reversed vs. numpy),
            # so its last axis carries two bytes per element.  Derive the
            # logical shape from that view instead of t.shape, which is ne
            # order and therefore NOT reversed.
            byte_shape = tuple(int(x) for x in t.data.shape)
            shape = byte_shape[:-1] + (byte_shape[-1] // 2,)
            flat = _bf16_to_f32(t.data.reshape(-1))
            arr = flat.reshape(shape)
        else:
            raise NotImplementedError(f"{name}: unsupported ggml type {ttype}")

        out[name] = torch.from_numpy(arr.copy())

    if verbose:
        total = sum(v.numel() for v in out.values())
        print(f"read {len(out)} tensors, {total/1e6:.1f} M params, "
              f"{sum(v.numel()*4 for v in out.values())/2**30:.2f} GiB as fp32")

    return out


def main():
    src = sys.argv[1]
    dst = sys.argv[2]
    sd = read_gguf_state_dict(src)
    torch.save(sd, dst)
    print(f"[written] {dst}")


if __name__ == "__main__":
    main()
