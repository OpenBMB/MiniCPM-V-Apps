#!/usr/bin/env python3
"""Diff the NPU probe output against the ggml CPU reference.

The probe writes float32 [256, 1024]; the ggml reference for the same input
lives in `dumps/448x448/final.f32`.  Because the HTP graph runs in fp16 and
its merger GELU is the tanh approximation (HTP has no Erf), the two will not
match bit for bit -- the useful numbers are the cosine and the relative
error, and how they compare with the fp16 PyTorch export.

Usage:
    python3 compare_npu.py <npu.f32> [ref.f32]
"""

import sys

import numpy as np

N_TOKENS = 256
N_EMBD = 1024


def stats(a, b, tag):
    d = np.abs(a - b)
    cos = float(np.dot(a.ravel().astype(np.float64), b.ravel().astype(np.float64)) /
                (np.linalg.norm(a.astype(np.float64)) * np.linalg.norm(b.astype(np.float64))))
    print(f"{tag:16s} max={d.max():.4e} mean={d.mean():.4e} "
          f"rel={d.mean() / np.abs(b).mean():.3e} cos={cos:.7f}")
    return cos


def main():
    npu_path = sys.argv[1]
    ref_path = sys.argv[2] if len(sys.argv) > 2 else "dumps/448x448/final.f32"

    npu = np.fromfile(npu_path, dtype=np.float32).reshape(N_TOKENS, N_EMBD)
    ref = np.fromfile(ref_path, dtype=np.float32).reshape(N_TOKENS, N_EMBD)

    print(f"npu  mean/std: {npu.mean():+.6f} / {npu.std():.6f}")
    print(f"ref  mean/std: {ref.mean():+.6f} / {ref.std():.6f}")
    stats(npu, ref, "npu vs ggml")

    a = npu
    b = ref
    cos = (a * b).sum(1) / (np.linalg.norm(a, axis=1) * np.linalg.norm(b, axis=1) + 1e-12)
    print(f"per-token cos: min={cos.min():.7f} (tok {cos.argmin()}) mean={cos.mean():.7f}")

    # where is the worst token, and is it a numerically extreme row?
    bad = cos.argmin()
    print(f"worst token {bad}: |ref| mean={np.abs(ref[bad]).mean():.4f} "
          f"max={np.abs(ref[bad]).max():.4f}; |npu| mean={np.abs(npu[bad]).mean():.4f}")


if __name__ == "__main__":
    main()
