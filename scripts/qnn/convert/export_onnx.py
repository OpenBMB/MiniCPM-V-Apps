#!/usr/bin/env python3
"""Export the 4x ViT to ONNX and verify it.

QNN/HTP has no dynamic shapes, so one .onnx (and later one context binary)
corresponds to exactly one input shape.

Two layouts:

`2d`     one fixed (W, H) canvas.  W and H must be multiples of 28
         (patch_size * n_merge) -- that is what the OCR image preprocessor
         produces.  Single `image` input; every aspect ratio needs its own
         compiled model.

`linear` the CoreML/ANE canvas, [1, 3, 14, 14336] = 1024 patches end to end.
         The shape is grid-independent: the caller copies patches at native
         resolution and leaves the tail zero, so ONE model serves every aspect
         ratio.  The price is that the grid can no longer be baked into the
         graph, so the position buckets, the 2x2 gather ids and the padding
         mask all become inputs -- 7 in total.

Usage:
    python3 export_onnx.py <vit_weights.pt> <W> <H> <out.onnx> [--fp16]
    python3 export_onnx.py <vit_weights.pt> 0 0 <out.onnx> --layout linear --fp16

--fp16 halves the file (the HTP executes fp16 anyway) and is what the DLC /
context-binary build should use; the fp32 export stays useful as a CPU
reference.

W/H are ignored by --layout linear; they are kept positional so the 2d command
line does not change.
"""

import argparse
import glob
import os

import numpy as np
import torch

from vit_ocr4x import (ATTN_MASK_NEG, LINEAR_W, N_PATCH_MAX, N_PATCH_OUT,
                       PATCH, Ocr4xViT, attn_bias_grid, merger_indices_padded,
                       pack_linear, positions_padded)

OPSET = 17
# Gather is listed as supported for opsets 1/11/13 and the HTP opdef only takes
# int32 or uint32 indices; 13 keeps the graph inside that window.
OPSET_LINEAR = 13

# (pos_h, pos_w) grids the linear graph is checked against.  The canvas is
# always 1024 patches, so the cost is the same for every entry.
VERIFY_GRIDS = [(32, 32), (6, 110), (18, 56), (2, 512)]

# Two different questions, two different tolerances:
#
#   torch linear vs torch 2d -- pure layout bookkeeping.  Packing, position
#   buckets, the 2x2 gather and the mask either agree exactly or the answer is
#   garbage, so this must be 1.0 to the last digit.
#
#   onnxruntime vs torch -- export fidelity.  In fp16 the 27 layers accumulate
#   rounding in a different association order, which is real but tiny; the
#   448x448 fp16 export measured 0.9999669 here, so anything in that range is
#   expected rather than suspicious.
COS_MIN_LAYOUT = 0.9999999
COS_MIN_EXPORT_FP16 = 0.9999
COS_MIN_EXPORT_FP32 = 0.999999


def normalize_onnx(path: str) -> None:
    """Fold `Constant` nodes into initializers and write one external blob.

    torch's TorchScript exporter spills every weight as a separate
    `_Constant_<n>_attr__value` file next to the model when the graph exceeds
    2 GB.  QNN tooling, and any sane copy to the build box, wants a single
    `.onnx` plus one `.data` sidecar with real initializers.
    """
    import onnx

    model = onnx.load(path, load_external_data=True)
    graph = model.graph

    used = {init.name for init in graph.initializer}
    used |= {i.name for i in graph.input}

    new_inits = []
    keep = []
    k = 0
    for node in graph.node:
        if node.op_type != "Constant" or len(node.attribute) != 1:
            keep.append(node)
            continue
        attr = node.attribute[0]
        if attr.name != "value":
            keep.append(node)
            continue
        name = f"w{k:04d}"
        k += 1
        while name in used:
            name = f"w{k:04d}"
            k += 1
        used.add(name)
        tensor = attr.t
        tensor.name = name
        # drop the Constant node's output name, point consumers at the initializer
        out_name = node.output[0]
        for other in graph.node:
            for i, inp in enumerate(other.input):
                if inp == out_name:
                    other.input[i] = name
        new_inits.append(tensor)

    del graph.node[:]
    graph.node.extend(keep)
    graph.initializer.extend(new_inits)

    location = os.path.basename(path) + ".data"
    target = os.path.join(os.path.dirname(os.path.abspath(path)), location)
    if os.path.exists(target):
        os.remove(target)
    onnx.save(model, path, save_as_external_data=True,
              all_tensors_to_one_file=True,
              location=location,
              size_threshold=1024)
    onnx.checker.check_model(path)


class LinearGraph(torch.nn.Module):
    """The seven-input signature the QNN graph exposes, in export order.

    `Ocr4xViT.forward` keeps its keyword form (the CPU reference calls it that
    way); ONNX needs a positional one.
    """

    def __init__(self, vit: Ocr4xViT, grid):
        super().__init__()
        self.vit = vit
        self.grid = grid

    def forward(self, image, position_ids, ds0, ds1, ds2, ds3, attn_bias):
        return self.vit(image, ds_idx_t=[ds0, ds1, ds2, ds3],
                        input_ids=position_ids, grid=self.grid,
                        attn_bias=attn_bias)


LINEAR_INPUTS = ["image", "position_ids", "merger_ds_idx_0", "merger_ds_idx_1",
                 "merger_ds_idx_2", "merger_ds_idx_3", "attn_bias"]


def linear_example(pos_h: int, pos_w: int, dtype):
    """One (image, aux...) tuple for a given grid, all on the fixed canvas."""
    rng = np.random.default_rng(1234 ^ (pos_h * 7919 + pos_w))
    hwc = (rng.random((pos_h * PATCH, pos_w * PATCH, 3), dtype=np.float32) * 2.0 - 1.0)
    packed = pack_linear(hwc, pos_w, pos_h)
    image = torch.from_numpy(packed).permute(2, 0, 1).unsqueeze(0).contiguous()
    image = image.to(dtype)
    pos = torch.from_numpy(positions_padded(pos_h, pos_w).astype(np.int32))
    ds = [torch.from_numpy(v.astype(np.int32)) for v in merger_indices_padded(pos_h, pos_w)]
    bias = torch.from_numpy(attn_bias_grid(pos_h, pos_w)).to(dtype)
    return hwc, image, pos, ds, bias


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    a = a.ravel().astype(np.float64)
    b = b.ravel().astype(np.float64)
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b)))


def verify_2d(model: Ocr4xViT, onnx_path: str, w: int, h: int, fp16: bool) -> None:
    import onnxruntime as ort

    sess = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
    rng = np.random.default_rng(1234)
    img = ((rng.random((h, w, 3), dtype=np.float32) * 2.0 - 1.0)
           .transpose(2, 0, 1)[None].copy())
    with torch.no_grad():
        ref = model.forward(torch.from_numpy(img)).float().numpy()
    got = sess.run(None, {"image": img.astype(np.float16 if fp16 else np.float32)})[0]

    d = np.abs(got.astype(np.float32) - ref)
    print(f"onnxruntime check: shape {got.shape} max abs diff {d.max():.3e} "
          f"mean {d.mean():.3e}  (rel to mean |ref| {d.mean()/np.abs(ref).mean():.2e})")
    print(f"onnxruntime cosine: {cosine(got, ref):.7f}")


def verify_linear(sd: dict, dtype, model: Ocr4xViT, onnx_path: str,
                  grids, merger_gelu: str) -> None:
    """Linear graph vs the 2d reference, on every grid in `grids`.

    The two paths differ only in how patches are laid out in memory, so after
    the position lookup and the 2x2 gather they must agree to fp noise.  The
    grid decides how many of the 256 canvas rows are real, so each case also
    checks the token count the caller would slice to.
    """
    import onnxruntime as ort

    sess = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
    names = [i.name for i in sess.get_inputs()]
    assert names == LINEAR_INPUTS, f"unexpected graph inputs: {names}"

    fp16 = dtype == torch.float16
    cos_min_export = COS_MIN_EXPORT_FP16 if fp16 else COS_MIN_EXPORT_FP32

    ok = True
    for pos_h, pos_w in grids:
        hwc, image, pos, ds, bias = linear_example(pos_h, pos_w, dtype)

        # 2d reference at the same resolution: nothing is padded, nothing moves
        ref_model = Ocr4xViT(sd, dtype=dtype, merger_gelu=merger_gelu,
                             fixed_size=(pos_w * PATCH, pos_h * PATCH), layout="2d")
        img2d = torch.from_numpy(hwc).permute(2, 0, 1).unsqueeze(0).contiguous().to(dtype)
        with torch.no_grad():
            ref = ref_model.forward(img2d).float().numpy()
        del ref_model

        with torch.no_grad():
            lin = model.forward(image, ds_idx_t=ds, input_ids=pos,
                                grid=(pos_h, pos_w), attn_bias=bias).float().numpy()

        feed = {"image": image.numpy(), "position_ids": pos.numpy(),
                "attn_bias": bias.numpy()}
        for i, v in enumerate(ds):
            feed[f"merger_ds_idx_{i}"] = v.numpy()
        got = sess.run(None, feed)[0]

        n_out = (pos_h // 2) * (pos_w // 2)
        shape_ok = got.shape == (N_PATCH_OUT, 1024) and ref.shape[0] == n_out

        c_torch = cosine(lin[:n_out], ref)
        c_ort = cosine(got[:n_out], ref)
        d_ort = np.abs(got[:n_out].astype(np.float32) - ref).max()
        layout_ok = c_torch > COS_MIN_LAYOUT
        export_ok = c_ort > cos_min_export
        good = shape_ok and layout_ok and export_ok
        ok &= good
        print(f"  grid {pos_h:>2}x{pos_w:<3} patches={pos_h * pos_w:>4} "
              f"tokens={n_out:>3} shape={got.shape} "
              f"layout={c_torch:.7f}{'' if layout_ok else ' FAIL'} "
              f"export={c_ort:.7f}{'' if export_ok else ' FAIL'} "
              f"maxdiff={d_ort:.2e} {'OK' if good else 'FAIL'}")

    if not ok:
        raise SystemExit("linear verification failed")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("weights")
    ap.add_argument("w", type=int)
    ap.add_argument("h", type=int)
    ap.add_argument("out")
    ap.add_argument("--layout", default="2d", choices=["2d", "linear"])
    ap.add_argument("--opset", type=int, default=None)
    ap.add_argument("--fp16", action="store_true")
    ap.add_argument("--merger-gelu", default="none", choices=["none", "tanh"],
                    help="QNN/HTP has no Erf op; the NPU graph must use 'tanh'")
    args = ap.parse_args()

    out_dir = os.path.dirname(os.path.abspath(args.out))
    for stale in glob.glob(os.path.join(out_dir, "*_Constant*_attr__value")):
        os.remove(stale)

    linear = args.layout == "linear"
    opset = args.opset if args.opset is not None else (OPSET_LINEAR if linear else OPSET)
    dtype = torch.float16 if args.fp16 else torch.float32
    sd = torch.load(args.weights, map_location="cpu")

    if not linear:
        model = Ocr4xViT(sd, dtype=dtype, fixed_size=(args.w, args.h),
                         merger_gelu=args.merger_gelu)
        torch.onnx.export(
            model,
            (torch.zeros(1, 3, args.h, args.w, dtype=dtype),),
            args.out,
            input_names=["image"],
            output_names=["embeddings"],
            opset_version=opset,
            do_constant_folding=True,
            dynamo=False,
        )
        normalize_onnx(args.out)
    else:
        if args.w or args.h:
            print(f"note: --layout linear ignores W={args.w} H={args.h}; "
                  f"the canvas is always [1, 3, {PATCH}, {LINEAR_W}]")
        # The grid is NOT baked in: this one is only the example input.
        grid = (1, N_PATCH_MAX)
        model = Ocr4xViT(sd, dtype=dtype, merger_gelu=args.merger_gelu,
                         fixed_size=(LINEAR_W, PATCH), layout="linear")
        graph = LinearGraph(model, grid)

        # all-zero aux inputs: they are graph inputs, their values do not shape
        # the graph, and the real ones are checked per grid below
        image = torch.zeros(1, 3, PATCH, LINEAR_W, dtype=dtype)
        pos = torch.zeros(N_PATCH_MAX, dtype=torch.int32)
        ds = [torch.zeros(N_PATCH_OUT, dtype=torch.int32) for _ in range(4)]
        bias = torch.zeros(N_PATCH_MAX, dtype=dtype)

        torch.onnx.export(
            graph,
            (image, pos, *ds, bias),
            args.out,
            input_names=LINEAR_INPUTS,
            output_names=["embeddings"],
            opset_version=opset,
            do_constant_folding=True,
            dynamo=False,
        )
        normalize_onnx(args.out)

    for stale in glob.glob(os.path.join(out_dir, "*_Constant*_attr__value")):
        os.remove(stale)

    size_mib = os.path.getsize(args.out) / 2 ** 20
    data = args.out + ".data"
    data_mib = os.path.getsize(data) / 2 ** 20 if os.path.exists(data) else 0.0
    print(f"[written] {args.out}  layout={args.layout} opset={opset} dtype={dtype}  "
          f"{size_mib:.1f} + {data_mib:.1f} MiB")

    if linear:
        print("linear layout vs 2d reference:")
        verify_linear(sd, dtype, model, args.out, VERIFY_GRIDS, args.merger_gelu)
    else:
        verify_2d(model, args.out, args.w, args.h, args.fp16)

    import onnx
    m = onnx.load(args.out, load_external_data=False)
    ops = sorted({n.op_type for n in m.graph.node})
    inputs = [(i.name, i.type.tensor_type.elem_type) for i in m.graph.input]
    print(f"inputs={inputs}")
    print(f"nodes={len(m.graph.node)} initializers={len(m.graph.initializer)} ops={ops}")


if __name__ == "__main__":
    main()
