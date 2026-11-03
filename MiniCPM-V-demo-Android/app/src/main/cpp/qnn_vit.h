// Interface between the OCR pipeline and the Hexagon NPU vision tower.
//
// Deliberately free of QNN types so llama_jni.cpp does not need the Qualcomm
// headers. The QNN session itself lives in qnn_vit.cpp.

#pragma once

#include <cstdint>

namespace qnnvit {

// The tower runs the CoreML/ANE layout: [1, 3, 14, 14336], i.e. 1024 patches
// laid end to end along the width.  One graph therefore serves every aspect
// ratio -- the caller copies patches at native resolution and leaves the tail
// zero -- which a square canvas cannot do, because a 1540x85 line box loses
// 71% of its horizontal detail when squeezed into 448x448.
//
// The price is that the grid is no longer baked into the graph, so the
// position buckets, the 2x2 gather indices and the padding mask become inputs.
constexpr int kPatch = 14;
constexpr int kPatches = 1024;
constexpr int kLinearW = kPatches * kPatch;              // 14336
constexpr int kCanvasRows = kPatches / 4;                // 256 merged rows

// Loads the context binary and brings the HTP device up. Safe to call twice;
// the second call is a no-op. `skel_dir` must contain libQnnHtpV85Skel.so.
// Returns 0 on success, negative on failure (see the log for the reason).
int init(const char * skel_dir, const char * context_binary);

// Hexagon generation of this device, as the QAIRT arch number (69, 73, 75, 85,
// 89 ...), or 0 when it cannot be determined. A context binary is compiled for
// exactly one generation, so the caller uses this to pick the matching file
// instead of assuming.
//
// Opens the backend only; it never touches a context binary. Still, callers
// must confirm a FastRPC transport exists first: deviceCreate() on a part with
// no Hexagon has been observed to abort the process rather than return an error.
int probe_arch();

bool ready();

void shutdown();

// Encodes one image of pos_w*14 x pos_h*14 pixels (planar source: `rgba` is
// 4 bytes per pixel, row major, alpha ignored) and publishes the result for
// the next image chunk. Requires pos_w*pos_h <= kPatches.
//
// The geometry must match what mtmd's preprocessor derives from the same
// bitmap: mtmd aligns to 28 (patch * n_merge) and, for a crop whose area fits
// the 448x448 budget, keeps the native pixels instead of upscaling, so it sees
// exactly pos_w x pos_h patches. If the two disagree by one patch the token
// counts still line up often enough to look plausible, which is why the caller
// derives both from one size rather than resizing twice.
int encode_rgba(const uint8_t * rgba, int pos_w, int pos_h);

// Hands the most recent embedding to the caller and clears it. Returns nullptr
// when nothing is pending. `*n_tokens` is set to the *valid* row count,
// (pos_h/2)*(pos_w/2) -- the graph always writes kCanvasRows rows, and the
// surplus ones are gathered from pad slots and must be dropped.
const float * take_pending(int * n_tokens);

}  // namespace qnnvit
