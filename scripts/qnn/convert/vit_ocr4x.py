#!/usr/bin/env python3
"""PyTorch reproduction of the MiniCPM-OCR 1.0 4x vision tower.

Mirrors `clip_graph_minicpmv4_7::build()` in the `is_4x` branch
(`hparams.n_merge == 2`): patch embed -> learned position embed -> 27 full
attention ViT layers -> post_ln -> 2x2 gather + concat -> merger MLP.

Two input layouts are supported:

`2d`   `[1, 3, H, W]`, patches come out as an H/14 x W/14 grid.  This is what
       `ggml_conv_2d` in clip.cpp produces, and what the reference encoder uses.
       The canvas shape is baked into the graph, so every image size needs its
       own compiled model -- which is why a row-shaped OCR crop had to be
       squashed into a square.

`linear` `[1, 3, 14, N*14]`, i.e. N patches laid end to end along the width.
       Conv (kernel 14, stride 14) then outputs [1, 1152, 1, N], height 1.
       This is the layout the CoreML/ANE build uses (see vision.cpp
       `vision_image_batch_encode_coreml`), and it is what lets ONE fixed
       1024-patch canvas serve every aspect ratio: patches are copied at native
       resolution and the slack is left at zero.

The linear layout is only valid together with a variable `merger_ds_idx_*`:
the 2x2 gather has to pick spatial neighbours, and "which linear index is the
neighbour" depends on the grid width.  ggml already treats those four indices
as graph inputs (`add_i32_input("merger_ds_idx_0", n_out)` in clip.cpp); the 2d
path here keeps them constant only because its grid is fixed.

The position bucket bookkeeping (`positions`) is a literal port of
`clip_image_batch_encode` in clip.cpp -- getting it off by one silently
produces wrong embeddings, so keep it verbatim.
"""

import numpy as np
import torch
import torch.nn.functional as F

N_LAYER = 27
N_EMBD = 1152
N_HEAD = 16
N_FF = 4304
PATCH = 14
PROJ_DIM = 1024
LN_EPS = 1e-6

# position embedding grid side (clip.vision.position_embd is 70*70)
POS_GRID = 70

# Linear layout canvas: 1024 patches, matching the CoreML build.
N_PATCH_MAX = 1024
LINEAR_W = N_PATCH_MAX * PATCH      # 14336
N_PATCH_OUT = N_PATCH_MAX // 4      # 256 merged tokens in the canvas

# A crop usually fills only part of the canvas; the tail stays zero.  Those
# slots still reach every softmax, where they dilute the real tokens -- a 6x110
# grid drops cosine to 0.9435 without a mask.  -3e4 is large enough that fp16
# exp() underflows to exactly 0 and small enough to stay finite.
ATTN_MASK_NEG = -3e4

# the projection weights stored as BF16 in the GGUF (everything else is F32)
_BF16_LINEARS = {"attn_q", "attn_k", "attn_v", "attn_out", "ffn_up", "ffn_down"}


def positions_grid(pos_h: int, pos_w: int) -> np.ndarray:
    """clip.cpp: bucket_coords[i] = floor(70*i/side), idx = bh*70 + bw.

    Row major over a pos_h x pos_w grid, which is also the order the patches
    come out of `conv2d` -- so `positions` is layout independent.
    """
    bh = np.floor(70.0 * np.arange(pos_h) / pos_h).astype(np.int64)
    bw = np.floor(70.0 * np.arange(pos_w) / pos_w).astype(np.int64)
    return (bh[:, None] * POS_GRID + bw[None, :]).reshape(-1)


def ds_idx(off_r: int, off_c: int, ds_h: int, ds_w: int, stride_w: int) -> np.ndarray:
    """clip.cpp make_ds_idx: row-major, picks (2i+off_r, 2j+off_c)."""
    i = np.arange(ds_h, dtype=np.int64)[:, None]
    j = np.arange(ds_w, dtype=np.int64)[None, :]
    return ((2 * i + off_r) * stride_w + (2 * j + off_c)).reshape(-1)


def merger_indices(pos_h: int, pos_w: int) -> list:
    """The four 2x2 gather index vectors for a pos_h x pos_w patch grid.

    Mirrors the `merger_ds_idx_*` block of `clip_image_batch_encode`.  With
    ODD pos_h the bottom row is dropped (ds_h = pos_h // 2), exactly like ggml.
    """
    h2, w2 = pos_h // 2, pos_w // 2
    return [ds_idx(o_r, o_c, h2, w2, pos_w)
            for o_r, o_c in ((0, 0), (0, 1), (1, 0), (1, 1))]


def positions_padded(pos_h: int, pos_w: int, n: int = N_PATCH_MAX) -> np.ndarray:
    """`positions_grid` widened to the canvas, tail filled with bucket 0.

    QNN shapes are compile-time constants, so the graph input is always `n`
    long; only the first pos_h*pos_w entries are real.  The tail reuses bucket
    0 because those activations never reach the merger.
    """
    pos = positions_grid(pos_h, pos_w)
    out = np.zeros(n, dtype=np.int64)
    out[:pos.size] = pos
    return out


def merger_indices_padded(pos_h: int, pos_w: int,
                          n_out: int = N_PATCH_OUT) -> list:
    """`merger_indices` as four fixed-length vectors, tail pointing at patch 0.

    The surplus rows gather patch 0 and produce embeddings nobody reads; the
    caller keeps only the first (pos_h // 2) * (pos_w // 2) rows.
    """
    out = []
    for idx in merger_indices(pos_h, pos_w):
        p = np.zeros(n_out, dtype=np.int64)
        p[:idx.size] = idx
        out.append(p)
    return out


def attn_bias_grid(pos_h: int, pos_w: int, n: int = N_PATCH_MAX) -> np.ndarray:
    """Per-key bias: 0 on real patches, ATTN_MASK_NEG on the zero-padded tail."""
    out = np.zeros(n, dtype=np.float32)
    out[pos_h * pos_w:] = ATTN_MASK_NEG
    return out


class Ocr4xViT(torch.nn.Module):
    """Stateless forward over a plain state dict.

    Subclasses nn.Module so the TorchScript ONNX exporter accepts it.  The
    weights are registered as non-persistent buffers (GGUF names contain dots,
    which nn.Module forbids, so they are mangled on the way in).
    """

    def __init__(self, state_dict: dict, dtype=torch.float32, trace: bool = False,
                 round_act: bool = False, fixed_size=None, merger_gelu: str = "none",
                 layout: str = "2d"):
        super().__init__()
        self._buf = {}
        for k, v in state_dict.items():
            b = k.replace(".", "___")
            self.register_buffer(b, v.to(dtype), persistent=False)
            self._buf[k] = b
        # "none" == erf-exact GELU (what ggml uses in the merger).  QNN/HTP has
        # no Erf op, so the NPU export uses "tanh" instead.
        self.merger_gelu = merger_gelu
        # (W, H) as Python ints; needed for TorchScript tracing, where
        # x.shape entries become Tensors and cannot drive numpy index math.
        self.fixed_size = fixed_size
        self.dtype = dtype
        self.layout = layout
        self.trace = {}
        self.tracing = trace
        # ggml converts the *activation* operand of mul_mat to the weight's
        # vec_dot_type before the dot product, so a bf16 weight sees
        # bf16-rounded activations.  Mirror that to compare like with like.
        self.round_act = round_act

    def _act(self, x):
        if not self.round_act:
            return x
        return x.to(torch.bfloat16).to(self.dtype)

    def _lin(self, x, wname, bname):
        if self.round_act and (wname.startswith("mm.") or wname.split(".")[-2] in _BF16_LINEARS):
            x = self._act(x)
        return F.linear(x, self._w(wname), self._w(bname))

    def _w(self, name):
        return getattr(self, self._buf[name])

    def _t(self, name, tensor):
        if self.tracing:
            self.trace[name] = tensor.detach()

    def forward(self, img: torch.Tensor, ds_idx_t=None, input_ids=None,
                grid=None, attn_bias=None) -> torch.Tensor:
        """img: [1, 3, H, W] (2d) or [1, 3, 14, N*14] (linear).

        `grid` is the *logical* (pos_h, pos_w) patch grid.  The linear layout
        collapses the physical tensor to height 1, so the grid width cannot be
        read back from the conv output -- position buckets and the 2x2 gather
        both need the original shape.
        `ds_idx_t` is required by the linear layout: four int64 tensors of
        length n_out, giving the flat patch ids of the four 2x2 corners.
        `input_ids` optionally overrides the position lookup so padding patches
        can reuse a real bucket (see export_onnx.py).
        `attn_bias` masks the zero-padded tail out of every softmax; without it
        the padding shares the attention denominator with the real patches.
        """
        # Guarded rather than unconditional: `.to()` on a tensor that already
        # has the right dtype still traces to a Cast node, and a no-op Cast in
        # front of a graph input is one more thing for the QNN converter to
        # choke on.
        if img.dtype != self.dtype:
            img = img.to(self.dtype)

        # ---- patch embedding -------------------------------------------------
        x = F.conv2d(img, self._w("v.patch_embd.weight"),
                     self._w("v.patch_embd.bias"), stride=PATCH)
        if grid is not None:
            pos_h, pos_w = grid
        elif self.fixed_size is not None:
            pos_w, pos_h = self.fixed_size[0] // PATCH, self.fixed_size[1] // PATCH
        else:
            _, _, pos_h, pos_w = x.shape
        n_pos = pos_h * pos_w
        # The canvas is fixed at 1024 patches, so the linear layout always
        # produces 1024 activations; the logical grid only decides where the
        # real patches sit inside it.
        n_act = x.shape[2] * x.shape[3]

        if self.layout == "linear":
            # conv leaves height 1; every patch lives on the single row
            assert x.shape[2] == 1, f"linear layout expects height 1, got {x.shape}"
        x = x[0].reshape(N_EMBD, n_act).transpose(0, 1)   # [n_act, 1152]
        self._t("patch_embeds", x)

        # ---- learned positional embedding -----------------------------------
        if input_ids is None:
            pos = torch.from_numpy(positions_grid(pos_h, pos_w))
            if self.layout == "linear":
                # pad the tail with bucket 0; those activations never reach the
                # merger because its indices only point at real patches
                pad = torch.zeros(n_act - pos.shape[0], dtype=torch.int64)
                pos_t = torch.cat([pos, pad])
            else:
                pos_t = pos
            x = x + self._w("v.position_embd.weight")[pos_t]
        else:
            x = x + self._w("v.position_embd.weight")[input_ids]
        self._t("pos_embed", x)

        # ---- 27 ViT blocks ---------------------------------------------------
        d_head = N_EMBD // N_HEAD
        kq_scale = 1.0 / (d_head ** 0.5)
        # broadcast [n_act] over the key axis of every head
        if attn_bias is not None:
            if attn_bias.dtype != self.dtype:
                attn_bias = attn_bias.to(self.dtype)
            bias = attn_bias.view(1, 1, n_act)
        else:
            bias = None

        for il in range(N_LAYER):
            p = f"v.blk.{il}."

            h = F.layer_norm(x, (N_EMBD,), self._w(p + "ln1.weight"),
                             self._w(p + "ln1.bias"), LN_EPS)
            self._t(f"layer_inp_normed-{il}", h)

            q = self._lin(h, p + "attn_q.weight", p + "attn_q.bias")
            k = self._lin(h, p + "attn_k.weight", p + "attn_k.bias")
            v = self._lin(h, p + "attn_v.weight", p + "attn_v.bias")

            def heads(t):
                return t.view(n_act, N_HEAD, d_head).transpose(0, 1)

            q, k, v = heads(q), heads(k), heads(v)
            if self.tracing:
                # ggml's [d_head, n_head, n_pos] flattening is (pos, head) major
                self.trace[f"Qcur-{il}"] = q.permute(1, 0, 2).reshape(-1, d_head)
                self.trace[f"Kcur-{il}"] = k.permute(1, 0, 2).reshape(-1, d_head)
                self.trace[f"Vcur-{il}"] = v.permute(1, 0, 2).reshape(-1, d_head)
            logits = (q @ k.transpose(-1, -2)) * kq_scale
            if bias is not None:
                logits = logits + bias
            attn = torch.softmax(logits, dim=-1)
            o = (attn @ v).transpose(0, 1).reshape(n_act, N_EMBD)
            self._t(f"kqv_out-{il}", o)
            o = self._lin(o, p + "attn_out.weight", p + "attn_out.bias")
            self._t(f"attn_out-{il}", o)
            x = x + o
            self._t(f"ffn_inp-{il}", x)

            h = F.layer_norm(x, (N_EMBD,), self._w(p + "ln2.weight"),
                             self._w(p + "ln2.bias"), LN_EPS)
            self._t(f"ffn_inp_normed-{il}", h)
            # ggml_gelu is the tanh approximation
            h = F.gelu(self._lin(h, p + "ffn_up.weight", p + "ffn_up.bias"),
                       approximate="tanh")
            h = self._lin(h, p + "ffn_down.weight", p + "ffn_down.bias")
            self._t(f"ffn_out-{il}", h)
            x = x + h
            self._t(f"layer_out-{il}", x)

        # ---- post ln ---------------------------------------------------------
        x = F.layer_norm(x, (N_EMBD,), self._w("v.post_ln.weight"),
                         self._w("v.post_ln.bias"), LN_EPS)
        self._t("post_ln", x)

        # ---- final merger: 2x2 gather + concat -------------------------------
        return self.forward_merger(x, pos_h, pos_w, ds_idx_t)

    def forward_merger(self, x: torch.Tensor, pos_h: int, pos_w: int,
                       ds_idx_t=None) -> torch.Tensor:
        """post_ln output -> projector embedding, [n_out, PROJ_DIM]."""
        if ds_idx_t is not None:
            idx = list(ds_idx_t)
        else:
            idx = [torch.from_numpy(v) for v in merger_indices(pos_h, pos_w)]
        cat = torch.cat([x[i] for i in idx], dim=-1)      # [n_out, 4*1152]

        c = F.layer_norm(cat, (4 * N_EMBD,), self._w("mm.input_norm.weight"),
                         self._w("mm.input_norm.bias"), LN_EPS)
        self._t("merger_normed", c)
        # merger MLP uses nn.GELU() (erf based) in the reference; HTP has no Erf
        c = F.gelu(self._lin(c, "mm.up.weight", "mm.up.bias"),
                   approximate=self.merger_gelu)
        out = self._lin(c, "mm.down.weight", "mm.down.bias")
        self._t("merger_out", out)
        return out


def load_input(path: str, w: int, h: int) -> torch.Tensor:
    """Read the interleaved-RGB f32 buffer written for `ref_encoder`."""
    a = np.fromfile(path, dtype=np.float32).reshape(h, w, 3)
    return torch.from_numpy(a).permute(2, 0, 1).unsqueeze(0).contiguous()


def pack_linear(hwc: np.ndarray, pos_w: int, pos_h: int) -> np.ndarray:
    """Pack an HxWx3 float image into the linear canvas, patch by patch.

    Reproduces `vision_image_batch_encode_coreml`: patches are copied at native
    resolution, in row-major order, until the 1024-patch canvas is full.  Any
    pixel before the first patch boundary (H or W not a multiple of 14) is
    dropped, and the tail of the canvas stays zero.
    """
    assert hwc.shape[0] >= pos_h * PATCH and hwc.shape[1] >= pos_w * PATCH
    n = N_PATCH_MAX * PATCH * PATCH            # 200704
    out = np.zeros((PATCH, LINEAR_W, 3), dtype=np.float32)
    k = 0
    for i in range(pos_h):
        for j in range(pos_w):
            block = hwc[i * PATCH:(i + 1) * PATCH, j * PATCH:(j + 1) * PATCH, :]
            col0 = k * PATCH
            out[:, col0:col0 + PATCH, :] = block
            k += 1
    return out
