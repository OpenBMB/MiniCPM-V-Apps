//
//  LayoutBridge.mm
//  MiniCPM-V-demo
//
//  ONNX runtime wrapper for PP-DocLayoutV3 layout detection.
//  Single session, CPU execution provider.
//

#import "LayoutBridge.h"

#import "OrtSession.h"
#import "ort_env.h"
#import "ort_value.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <mutex>
#include <numeric>
#include <vector>

namespace {

static ORTEnv              * g_env     = nullptr;
static ORTSession          * g_session = nullptr;
static bool                  g_inited  = false;
static std::mutex            g_mutex;

static const int kNumClasses = 25;
static const int kNumQueries = 300;

// Aligned with HF preprocessor_config.json:
//   image_mean = [0, 0, 0], image_std = [1, 1, 1]
//   rescale_factor = 1/255 (applied before mean/std)
static const float kMean[] = { 0.0f, 0.0f, 0.0f };
static const float kStd[]  = { 1.0f, 1.0f, 1.0f };

/// PyTorch bicubic cubic convolution kernel (A = –0.75).
/// Used by torch.nn.functional.interpolate(mode='bicubic', align_corners=False)
/// and tvF.resize(interpolation=BICUBIC, antialias=False).
static inline float cubic(float x) {
    x = std::fabs(x);
    if (x < 1.0f) return ((1.25f * x - 2.25f) * x * x + 1.0f);
    if (x < 2.0f) return (((-0.75f * x + 3.75f) * x - 6.0f) * x + 3.0f);
    return 0.0f;
}

static inline float sigmoid_clip(float x) {
    x = std::max(-50.0f, std::min(50.0f, x));
    return 1.0f / (1.0f + std::exp(-x));
}

/// Votes are the column sums (numpy axis=0) of the upper triangle plus the
/// strict lower triangle of (1 - scores^T). Rank 0 is the first block.
static std::vector<int> get_order_seqs(const float * order_logits, int N) {
    std::vector<float> os(static_cast<size_t>(N) * N);
    for (int i = 0; i < N * N; ++i) os[i] = sigmoid_clip(order_logits[i]);

    std::vector<float> votes(N, 0.0f);
    for (int j = 0; j < N; ++j) {
        for (int i = 0; i < j; ++i)
            votes[j] += os[static_cast<size_t>(i) * N + j];
        for (int i = j + 1; i < N; ++i)
            votes[j] += 1.0f - os[static_cast<size_t>(j) * N + i];
    }

    std::vector<int> ptrs(N);
    std::iota(ptrs.begin(), ptrs.end(), 0);
    std::stable_sort(ptrs.begin(), ptrs.end(),
                      [&](int a, int b) { return votes[a] < votes[b]; });

    std::vector<int> seq(N);
    for (int k = 0; k < N; ++k) seq[ptrs[k]] = k;
    return seq;
}

struct DetBox {
    int   label;
    float score;
    float x1, y1, x2, y2;
    float order;
};

/// _iou_np: widths include the +1 pixel used by the torch NMS.
static float iou_plus1(const DetBox & a, const DetBox & b) {
    const float xi1 = std::max(a.x1, b.x1);
    const float yi1 = std::max(a.y1, b.y1);
    const float xi2 = std::min(a.x2, b.x2);
    const float yi2 = std::min(a.y2, b.y2);
    const float iw = xi2 - xi1 + 1.0f;
    const float ih = yi2 - yi1 + 1.0f;
    if (iw <= 0.0f || ih <= 0.0f) return 0.0f;
    const float ia = iw * ih;
    const float a1 = (a.x2 - a.x1 + 1.0f) * (a.y2 - a.y1 + 1.0f);
    const float a2 = (b.x2 - b.x1 + 1.0f) * (b.y2 - b.y1 + 1.0f);
    const float denom = a1 + a2 - ia;
    return denom > 0.0f ? ia / denom : 0.0f;
}

/// _is_contained_np: inner's intersection with outer covers >= 90% of inner.
/// No +1 here. This is a different formula from NMS IoU.
static bool is_contained_90(const DetBox & inner, const DetBox & outer) {
    const float ix1 = std::max(inner.x1, outer.x1);
    const float iy1 = std::max(inner.y1, outer.y1);
    const float ix2 = std::min(inner.x2, outer.x2);
    const float iy2 = std::min(inner.y2, outer.y2);
    const float iw = std::max(0.0f, ix2 - ix1);
    const float ih = std::max(0.0f, iy2 - iy1);
    const float ia = iw * ih;
    const float a1 = (inner.x2 - inner.x1) * (inner.y2 - inner.y1);
    return a1 > 0.0f && ia / a1 >= 0.9f;
}

/// _nms_np with the call-site thresholds, not the function defaults.
static std::vector<int> nms_keep(const std::vector<DetBox> & boxes) {
    std::vector<int> order(boxes.size());
    std::iota(order.begin(), order.end(), 0);
    std::stable_sort(order.begin(), order.end(), [&](int a, int b) {
        return boxes[a].score > boxes[b].score;
    });

    std::vector<int> kept;
    std::vector<char> dead(boxes.size(), 0);
    for (size_t n = 0; n < order.size(); ++n) {
        const int c = order[n];
        if (dead[c]) continue;
        kept.push_back(c);
        for (size_t m = n + 1; m < order.size(); ++m) {
            const int r = order[m];
            if (dead[r]) continue;
            const float thr = boxes[c].label != boxes[r].label ? 0.98f : 0.6f;
            if (iou_plus1(boxes[c], boxes[r]) >= thr) dead[r] = 1;
        }
    }
    return kept;
}

} // namespace

extern "C" {

void * layout_init(const char * onnx_path) {
    if (!onnx_path || !*onnx_path) {
        fprintf(stderr, "[LayoutBridge] layout_init: missing onnx_path\n");
        return nullptr;
    }
    std::lock_guard<std::mutex> lock(g_mutex);

    if (!g_env) {
        NSError * err = nil;
        g_env = [[ORTEnv alloc] initWithLoggingLevel:ORTLoggingLevelWarning error:&err];
        if (!g_env) {
            fprintf(stderr, "[LayoutBridge] ORTEnv init failed: %s\n", err.localizedDescription.UTF8String);
            return nullptr;
        }
    }

    if (g_session) {
        fprintf(stderr, "[LayoutBridge] layout_init: already loaded\n");
        g_inited = true;
        return &g_session;
    }

    NSError * err = nil;
    ORTSessionOptions * opts = [[ORTSessionOptions alloc] initWithError:&err];
    NSString * path = [NSString stringWithUTF8String:onnx_path];
    g_session = [[ORTSession alloc] initWithEnv:g_env modelPath:path sessionOptions:opts error:&err];
    if (err) {
        fprintf(stderr, "[LayoutBridge] ORTSession init failed: %s\n", err.localizedDescription.UTF8String);
        return nullptr;
    }
    g_inited = true;
    fprintf(stderr, "[LayoutBridge] model loaded: %s\n", onnx_path);
    return &g_session;
}

void layout_free(void * ctx) {
    std::lock_guard<std::mutex> lock(g_mutex);
    (void)ctx;
    g_session = nil;
    g_env     = nil;
    g_inited  = false;
}

int layout_detect(void * ctx, const uint8_t * rgb, int width, int height,
                   float threshold, layout_detection_t ** out_dets, int * out_count) {
    if (!ctx || !rgb || width <= 0 || height <= 0 || !out_dets || !out_count) return -1;
    if (!g_inited || !g_session) return -1;
    *out_dets  = nullptr;
    *out_count = 0;

    // Preprocess: stretch-resize to 800x800 with bicubic interpolation,
    // matching tvF.resize(interpolation=BICUBIC, antialias=False), which uses
    // the Catmull-Rom cubic kernel (Keys alpha = -0.5).
    const int kInputSize = 800;

    const float scale_x = (float)kInputSize / width;
    const float scale_y = (float)kInputSize / height;

    size_t tensor_size = 1 * 3 * kInputSize * kInputSize;
    std::vector<float> pixel_buffer(tensor_size, 0.0f);

    for (int c = 0; c < 3; ++c) {
        float * chan = pixel_buffer.data() + c * kInputSize * kInputSize;
        for (int y = 0; y < kInputSize; ++y) {
            float src_y = (y + 0.5f) / scale_y - 0.5f;
            int    sy0  = (int)std::floor(src_y) - 1;

            float w_y[4];
            for (int dy = 0; dy < 4; ++dy) w_y[dy] = cubic(src_y - (float)(sy0 + dy));

            for (int x = 0; x < kInputSize; ++x) {
                float src_x = (x + 0.5f) / scale_x - 0.5f;
                int    sx0  = (int)std::floor(src_x) - 1;

                float w_x[4];
                for (int dx = 0; dx < 4; ++dx) w_x[dx] = cubic(src_x - (float)(sx0 + dx));

                float val = 0.0f;
                for (int dy = 0; dy < 4; ++dy) {
                    int sy = sy0 + dy;
                    if (sy < 0) sy = 0; else if (sy >= height) sy = height - 1;
                    for (int dx = 0; dx < 4; ++dx) {
                        int sx = sx0 + dx;
                        if (sx < 0) sx = 0; else if (sx >= width) sx = width - 1;
                        val += w_x[dx] * w_y[dy] * (float)rgb[(sy * width + sx) * 3 + c];
                    }
                }
                chan[y * kInputSize + x] = (val / 255.0f - kMean[c]) / kStd[c];
            }
        }
    }

    // Inference
    NSError * err = nil;
    NSMutableData * inputData = [NSMutableData dataWithBytes:pixel_buffer.data()
                                                      length:tensor_size * sizeof(float)];
    ORTValue * input = [[ORTValue alloc] initWithTensorData:inputData
                                                 elementType:ORTTensorElementDataTypeFloat
                                                       shape:@[@1, @3, @(kInputSize), @(kInputSize)]
                                                       error:&err];
    if (err || !input) {
        fprintf(stderr, "[LayoutBridge] create input failed\n");
        return -1;
    }

    NSMutableData * logits_buf      = [NSMutableData dataWithLength:1 * kNumQueries * kNumClasses * sizeof(float)];
    NSMutableData * boxes_buf       = [NSMutableData dataWithLength:1 * kNumQueries * 4 * sizeof(float)];
    NSMutableData * order_logits_buf= [NSMutableData dataWithLength:1 * kNumQueries * kNumQueries * sizeof(float)];

    ORTValue * logits_out = [[ORTValue alloc] initWithTensorData:logits_buf
                                                      elementType:ORTTensorElementDataTypeFloat
                                                            shape:@[@1, @(kNumQueries), @(kNumClasses)]
                                                            error:&err];
    ORTValue * boxes_out  = [[ORTValue alloc] initWithTensorData:boxes_buf
                                                      elementType:ORTTensorElementDataTypeFloat
                                                            shape:@[@1, @(kNumQueries), @4]
                                                            error:&err];
    ORTValue * order_out  = [[ORTValue alloc] initWithTensorData:order_logits_buf
                                                      elementType:ORTTensorElementDataTypeFloat
                                                            shape:@[@1, @(kNumQueries), @(kNumQueries)]
                                                            error:&err];

    // pixel_mask: dead input (model doesn't read it when no padding), but ONNX
    // runtime requires all declared inputs.  Always all-ones since we stretch-resize.
    NSMutableData * mask_buf = [NSMutableData dataWithLength:1 * kInputSize * kInputSize * sizeof(float)];
    float * mask_ptr = (float *)mask_buf.mutableBytes;
    std::fill(mask_ptr, mask_ptr + kInputSize * kInputSize, 1.0f);
    ORTValue * mask = [[ORTValue alloc] initWithTensorData:mask_buf
                                                elementType:ORTTensorElementDataTypeFloat
                                                      shape:@[@1, @(kInputSize), @(kInputSize)]
                                                      error:&err];

    if (!logits_out || !boxes_out || !order_out || !mask) {
        fprintf(stderr, "[LayoutBridge] create outputs failed\n");
        return -1;
    }

    BOOL ok = NO;
    @try {
        ok = [g_session runWithInputs:@{@"pixel_values": input,
                                          @"pixel_mask": mask}
                                outputs:@{@"logits": logits_out,
                                          @"pred_boxes": boxes_out,
                                          @"order_logits": order_out}
                             runOptions:nil
                                  error:&err];
    } @catch (NSException *e) {
        fprintf(stderr, "[LayoutBridge] ONNX exception: %s\n", e.reason.UTF8String);
        return -1;
    }
    if (!ok) {
        fprintf(stderr, "[LayoutBridge] inference failed: %s\n", err ? err.localizedDescription.UTF8String : "");
        return -1;
    }

    // Order is computed on the full 300x300 logits, then indexed by the
    // surviving queries.
    const float * logits_ptr       = (const float *)logits_buf.bytes;
    const float * boxes_ptr        = (const float *)boxes_buf.bytes;
    const float * order_logits_ptr = (const float *)order_logits_buf.bytes;

    const int n_flat = kNumQueries * kNumClasses;
    std::vector<float> flat_scores(n_flat);
    for (int i = 0; i < n_flat; ++i) flat_scores[i] = sigmoid_clip(logits_ptr[i]);

    std::vector<int> rank(n_flat);
    std::iota(rank.begin(), rank.end(), 0);
    const int topk = std::min(kNumQueries, n_flat);
    std::partial_sort(rank.begin(), rank.begin() + topk, rank.end(),
                      [&](int a, int b) { return flat_scores[a] > flat_scores[b]; });

    const auto order_seq = get_order_seqs(order_logits_ptr, kNumQueries);

    std::vector<DetBox> boxes;
    boxes.reserve(topk);
    for (int k = 0; k < topk; ++k) {
        const int flat = rank[k];
        const int label = flat % kNumClasses;
        const int q = flat / kNumClasses;
        const float * box = boxes_ptr + q * 4;
        const float cx = box[0], cy = box[1], bw = box[2], bh = box[3];
        DetBox d;
        d.label = label;
        d.score = flat_scores[flat];
        // Normalized cxcywh -> xyxy, then times the original image size.
        d.x1 = (cx - 0.5f * bw) * (float)width;
        d.y1 = (cy - 0.5f * bh) * (float)height;
        d.x2 = (cx + 0.5f * bw) * (float)width;
        d.y2 = (cy + 0.5f * bh) * (float)height;
        d.order = (float)order_seq[q];
        // np.round is half-to-even. Coords stay integer-valued floats.
        d.x1 = std::nearbyint(d.x1);
        d.y1 = std::nearbyint(d.y1);
        d.x2 = std::nearbyint(d.x2);
        d.y2 = std::nearbyint(d.y2);
        boxes.push_back(d);
    }

    // score > threshold, not >=. label > -1 is always true for this head.
    std::vector<DetBox> kept;
    for (const auto & b : boxes) {
        if (b.score > threshold && b.label > -1) kept.push_back(b);
    }
    boxes.swap(kept);
    if (boxes.empty()) return 0;

    {
        const auto sel = nms_keep(boxes);
        std::vector<DetBox> nmsed;
        nmsed.reserve(sel.size());
        for (int i : sel) nmsed.push_back(boxes[i]);
        boxes.swap(nmsed);
    }
    if (boxes.empty()) return 0;

    // image (class 14) covering most of the page is dropped, but only when
    // more than one box remains. If the filter would drop every box, the
    // torch code leaves the list unchanged.
    if (boxes.size() > 1) {
        const float img_area = (float)width * (float)height;
        const float area_thres = width > height ? 0.82f : 0.93f;
        std::vector<DetBox> filtered;
        for (const auto & b : boxes) {
            if (b.label == 14) {
                const int x1 = (int)std::max(0.0f, b.x1);
                const int y1 = (int)std::max(0.0f, b.y1);
                const int x2 = (int)std::min((float)width, b.x2);
                const int y2 = (int)std::min((float)height, b.y2);
                const float ba = (float)(x2 - x1) * (float)(y2 - y1);
                if (ba <= area_thres * img_area) filtered.push_back(b);
            } else {
                filtered.push_back(b);
            }
        }
        if (!filtered.empty()) boxes.swap(filtered);
    }
    if (boxes.empty()) return 0;

    // MERGE_BBOXES_MODE, all "large": chart, display_formula, doc_title,
    // inline_formula, paragraph_title swallow a box they cover by >= 90%.
    // Every class is scored against the same pre-filter list, then the masks
    // are combined. There is no "formula" class in this label set.
    if (boxes.size() >= 2) {
        const int cats[] = { 3, 5, 6, 15, 17 };
        std::vector<char> keep_mask(boxes.size(), 1);
        for (int cat : cats) {
            std::vector<char> contained(boxes.size(), 0);
            for (size_t i = 0; i < boxes.size(); ++i) {
                for (size_t j = 0; j < boxes.size(); ++j) {
                    if (i == j) continue;
                    if (boxes[j].label == cat && is_contained_90(boxes[i], boxes[j]))
                        contained[i] = 1;
                }
            }
            for (size_t i = 0; i < boxes.size(); ++i)
                if (contained[i]) keep_mask[i] = 0;
        }
        std::vector<DetBox> merged;
        for (size_t i = 0; i < boxes.size(); ++i)
            if (keep_mask[i]) merged.push_back(boxes[i]);
        boxes.swap(merged);
    }
    if (boxes.empty()) return 0;

    std::stable_sort(boxes.begin(), boxes.end(),
                     [](const DetBox & a, const DetBox & b) { return a.order < b.order; });

    std::vector<DetBox> clipped;
    for (const auto & b : boxes) {
        const int xmin = (int)std::max(0.0f, b.x1);
        const int ymin = (int)std::max(0.0f, b.y1);
        const int xmax = (int)std::min((float)width, b.x2);
        const int ymax = (int)std::min((float)height, b.y2);
        if (xmax <= xmin || ymax <= ymin) continue;
        DetBox c = b;
        c.x1 = (float)xmin; c.y1 = (float)ymin;
        c.x2 = (float)xmax; c.y2 = (float)ymax;
        clipped.push_back(c);
    }

    *out_count = (int)clipped.size();
    if (*out_count == 0) return 0;
    *out_dets = (layout_detection_t *)malloc(*out_count * sizeof(layout_detection_t));
    if (!*out_dets) { *out_count = 0; return -1; }
    for (size_t i = 0; i < clipped.size(); ++i) {
        const auto & c = clipped[i];
        (*out_dets)[i].x1 = c.x1; (*out_dets)[i].y1 = c.y1;
        (*out_dets)[i].x2 = c.x2; (*out_dets)[i].y2 = c.y2;
        (*out_dets)[i].score = c.score;
        (*out_dets)[i].label_id = c.label;
    }
    fprintf(stderr, "[LayoutBridge] %d boxes (score > %.2f)\n",
            *out_count, threshold);
    return 0;
}

} // extern "C"