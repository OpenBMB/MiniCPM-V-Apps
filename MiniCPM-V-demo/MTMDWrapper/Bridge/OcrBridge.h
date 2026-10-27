//
//  OcrBridge.h
//  MiniCPM-V-demo
//
//  Thin C bridge over llama.cpp + mtmd for OCR inference.
//  Shares the same llama.xcframework as MBMtmd but with OCR-specific
//  sampling parameters (nearly greedy).
//
//  4x downsample mode is auto-detected from GGUF metadata
//  (clip.vision.downsample_mode = 4).
//

#ifndef OCR_BRIDGE_H
#define OCR_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Inference parameters for OCR model.
typedef struct {
    int     n_ctx;            // context size (default 12288)
    int     n_threads;        // CPU threads (default 4)
    int     n_ubatch;         // physical batch size (default 512)
    float   temperature;      // sampling temperature (OCR: ~0.01)
    bool    use_gpu;          // Metal GPU acceleration
    bool    warmup;           // run a dummy inference to warm up GPU
    int     max_slice_nums;   // max image slices (default 9, -1 = model default)
} ocr_params_t;

/// A single generated token from the OCR model.
typedef struct {
    const char * text;        // heap-allocated UTF-8 token text (caller must free with ocr_string_free)
    int          is_complete; // 1 = generation complete (EOS token generated)
    int          error_code;  // 0 = success, non-zero = error
    const char * error_msg;   // error description (NULL if no error)
} ocr_token_t;

/// Initialise OCR model (LLM GGUF + mmproj GGUF).
/// @return Opaque context pointer, or NULL on failure.
void *       ocr_init(const char * model_path, const char * mmproj_path, const ocr_params_t * params);

/// Release all OCR resources.
void         ocr_free(void * ctx);

/// Prefill an image into the KV cache (visual token encoding).
/// @return 0 on success, non-zero on failure.
int          ocr_prefill_image(void * ctx, const char * image_path);

/// Prefill a text prompt into the KV cache (ChatML-formatted).
/// @param role  "user" or "assistant" or "system".
/// @return 0 on success, non-zero on failure.
int          ocr_prefill_text(void * ctx, const char * text, const char * role);

/// Sample one token, decode it, and return the result.
/// Call in a loop until is_complete == 1.
ocr_token_t  ocr_loop(void * ctx);

/// Decode counters for the open turn. Does not close the turn.
typedef struct {
    int32_t decode_tokens;
    double  decode_ms;
} ocr_decode_perf_t;

ocr_decode_perf_t ocr_decode_perf_peek(void * ctx);

/// Clear the KV cache (reuse context for a new crop without re-init).
void         ocr_clean_kv_cache(void * ctx);

/// One-shot image OCR: image_path -> complete markdown string.
/// Internally: ocr_prefill_image + ocr_prefill_text(prompt) + ocr_loop to EOS.
/// @param ctx         Ocr context from ocr_init.
/// @param image_path  Path to crop image (PNG/JPG).
/// @param prompt      Text prompt (e.g. "Text Recognition:").
/// @param max_tokens  Maximum tokens to generate before force-stop.
/// @return            Heap-allocated markdown string (caller must free with ocr_string_free),
///                    or NULL on failure.
char *       ocr_recognize(void * ctx, const char * image_path, const char * prompt, int max_tokens);

/// Free a string returned by ocr_loop or ocr_recognize.
void         ocr_string_free(const char * str);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // OCR_BRIDGE_H
