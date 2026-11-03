#!/usr/bin/env python3
"""Structural verification of the PyTorch 4x ViT port against ggml.

For each image size the tool:
  1. runs `ref_encoder` and dumps pos_embed / layer 0 internals / post_ln /
     merger tensors,
  2. replays the PyTorch forward and compares them,
  3. feeds ggml's own `post_ln` output into the PyTorch merger, which isolates
     the 2x2 gather index bookkeeping from the drift that accumulates over the
     27 attention blocks.

Layer 0 is compared tightly because it appears before any drift: it is the
part that proves the position buckets, the head split and the QKV layout.
Deeper layers are only compared for shape/sanity -- ggml rounds activations to
bf16 inside `mul_mat`, so the reference itself carries ~2e-3 relative noise per
layer and an exact match is not achievable (nor meaningful).

Usage:
    python3 verify.py <vit_weights.pt> [size ...]      # size = WxH
"""

import os
import subprocess
import sys

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
# vit_ocr4x.py lives with the conversion scripts, one directory up
sys.path.insert(0, os.path.join(HERE, os.pardir, "convert"))
from vit_ocr4x import Ocr4xViT, load_input

MMPROJ = os.environ.get(
    "MMPROJ",
    os.path.join(HERE, os.pardir, os.pardir, "models",
                 "MiniCPM-OCR-1_0-mmproj-F16-4x.gguf"))
REF_ENCODER = os.path.join(HERE, "ref_encoder")

DUMP_NAMES = ("pos_embed,layer_inp_normed-0,Qcur-0,Kcur-0,Vcur-0,kqv_out-0,"
              "attn_out-0,ffn_inp_normed-0,ffn_gelu-0,ffn_out-0,layer_out-0,"
              "post_ln,merger_normed,merger_out")


def make_input(path, w, h, seed=1234):
    rng = np.random.default_rng(seed)
    a = (rng.random((h, w, 3), dtype=np.float32) * 2.0 - 1.0).astype(np.float32)
    a.tofile(path)


def run_ref(inp, w, h, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    env = dict(os.environ, REF_DUMP_DIR=out_dir, REF_DUMP_NAMES=DUMP_NAMES)
    cmd = [REF_ENCODER, MMPROJ, inp, str(w), str(h),
           os.path.join(out_dir, "final.f32"), "8"]
    r = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout, r.stderr)
        raise SystemExit("ref_encoder failed")


def load_dump(out_dir, name):
    binp = os.path.join(out_dir, name + ".bin")
    shp = os.path.join(out_dir, name + ".shape")
    if not os.path.exists(binp):
        return None
    with open(shp) as f:
        parts = f.read().split()
    ne = [int(x) for x in parts[1:5]]
    data = np.fromfile(binp, dtype=np.float32)
    if data.size != int(np.prod(ne)):
        return None
    return data.reshape(-1, ne[0])


def rel(a, b):
    return np.abs(a - b).mean() / max(np.abs(b).mean(), 1e-12)


def main():
    weights = sys.argv[1]
    sizes = [tuple(int(v) for v in s.split("x")) for s in sys.argv[2:]] or \
            [(448, 448), (448, 336), (392, 504)]

    sd = torch.load(weights, map_location="cpu")
    model = Ocr4xViT(sd, trace=True, round_act=True)

    print(f"{'size':12s} {'n_tok':>6s}  {'pos_embed':>10s} {'ln1_0':>10s} "
          f"{'Q_0':>10s} {'kqv_0':>10s} {'attn_0':>10s} {'merger*':>10s} {'final cos':>10s}")

    for (w, h) in sizes:
        tag = f"{w}x{h}"
        inp = os.path.join(HERE, f"input_{tag}.f32")
        make_input(inp, w, h)
        out_dir = os.path.join(HERE, "dumps", tag)
        run_ref(inp, w, h, out_dir)

        img = load_input(inp, w, h)
        with torch.no_grad():
            model.forward(img)

        cols = []
        for nm in ["pos_embed", "layer_inp_normed-0", "Qcur-0", "kqv_out-0", "attn_out-0"]:
            g = load_dump(out_dir, nm)
            t = model.trace[nm].numpy()
            cols.append(f"{rel(t, g):10.2e}")

        # merger isolation: ggml post_ln -> torch merger
        post = torch.from_numpy(load_dump(out_dir, "post_ln"))
        with torch.no_grad():
            mout = model.forward_merger(post, h // 14, w // 14).numpy()
        gm = load_dump(out_dir, "merger_out")
        cols.append(f"{rel(mout, gm):10.2e}")

        gold = np.fromfile(os.path.join(out_dir, "final.f32"), dtype=np.float32)
        got = model.forward(img).numpy()
        gold = gold.reshape(got.shape)
        cos = float(np.dot(got.ravel(), gold.ravel()) /
                    (np.linalg.norm(got) * np.linalg.norm(gold)))
        print(f"{tag:12s} {got.shape[0]:6d}  " + " ".join(cols) + f" {cos:10.7f}")


if __name__ == "__main__":
    main()
