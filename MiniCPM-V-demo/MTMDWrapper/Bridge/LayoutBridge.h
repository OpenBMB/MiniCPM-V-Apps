//
//  LayoutBridge.h
//  MiniCPM-V-demo
//
//  Thin C bridge for PP-DocLayoutV3 ONNX layout detection via onnxruntime-objc.
//  Only exposes pure C so Swift can consume it via the Bridging Header.
//

#ifndef LAYOUT_BRIDGE_H
#define LAYOUT_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A single detected layout element.
typedef struct {
    float x1, y1;   // top-left corner in original image pixel coordinates
    float x2, y2;   // bottom-right corner in original image pixel coordinates
    float score;    // confidence [0, 1]
    int   label_id; // 0–24
} layout_detection_t;

/// Load the PP-DocLayoutV3 ONNX model from disk.
///
/// @param onnx_path  Absolute path to the ONNX file.
/// @return           Opaque context pointer on success, NULL on failure.
///                   Call layout_free() to release.
void * layout_init(const char * onnx_path);

/// Release all resources held by the layout detection session.
void   layout_free(void * ctx);

/// Detect layout elements in an RGB image.
///
/// @param ctx         Context from layout_init().
/// @param rgb         Interleaved RGB888 bytes (HWC layout, no alpha).
/// @param width       Image width in pixels.
/// @param height      Image height in pixels.
/// @param threshold   Confidence threshold (recommended 0.3f).
/// @param out_dets    Output: array of detections (caller frees with free()).
/// @param out_count   Output: number of detections.
///
/// @return 0 on success, non-zero on error.
///
/// A box is kept only when its score is strictly greater than the threshold.
/// NMS widths and heights include one pixel.
///
/// Thread-safety: NOT thread-safe (OrtSession is not thread-safe).
/// Caller must serialise access or use a mutex.
int layout_detect(void * ctx,
                  const uint8_t * rgb, int width, int height,
                  float threshold,
                  layout_detection_t ** out_dets, int * out_count);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // LAYOUT_BRIDGE_H
