//
//  OcrBridge.mm
//  MiniCPM-V-demo
//
//  Thin wrapper over MBMtmd's mb_mtmd_* API for OCR inference.
//  OCR-specific: near-greedy sampling (temperature=0.01), 4x downsample
//  auto-detected from GGUF metadata.
//
//  All actual inference logic lives in MBMtmd.mm; this file only provides
//  convenience wrappers with OCR-appropriate defaults.
//

#import "OcrBridge.h"
#import "MBMtmd.h"

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static inline std::string safe_str(const char * s) { return s ? s : ""; }

extern "C" {

void * ocr_init(const char * model_path, const char * mmproj_path, const ocr_params_t * params_in) {
    if (!model_path || !*model_path || !mmproj_path || !*mmproj_path) {
        fprintf(stderr, "[OcrBridge] ocr_init: missing paths\n");
        return nullptr;
    }

    mb_mtmd_params p = mb_mtmd_params_default();
    p.use_gpu      = true;
    p.mmproj_use_gpu = true;
    p.warmup       = false; // OCR: skip warmup to save time
    p.temperature  = 0.01f; // near-greedy
    p.top_k        = 1;     // deterministic: only highest-prob token
    p.top_p        = 0.001f;// deterministic: top 0.1% probability mass
    // 4x: one view is (448/14/2)^2 = 256 tokens. A crop can be the overview
    // plus 9 slices (2560) plus the chat template, and a table may generate
    // 8192 tokens. 4096 cannot hold that. 12288 leaves a margin.
    p.n_ctx        = 12288;
    p.n_threads    = 4;
    p.n_ubatch     = 512;
    p.image_max_slice_nums = 9;

    if (params_in) {
        if (params_in->n_ctx > 0)     p.n_ctx     = params_in->n_ctx;
        if (params_in->n_threads > 0) p.n_threads = params_in->n_threads;
        if (params_in->n_ubatch > 0)  p.n_ubatch  = params_in->n_ubatch;
        if (params_in->temperature > 0) p.temperature = params_in->temperature;
        if (params_in->max_slice_nums > 0) p.image_max_slice_nums = params_in->max_slice_nums;
        p.use_gpu      = params_in->use_gpu;
        p.warmup       = params_in->warmup;
    }

    auto * ctx = mb_mtmd_init(model_path, mmproj_path, nullptr, nullptr, &p);
    if (ctx) {
        // OCR 1.0 的文本塔是 Qwen3.5，图要放进 user 轮，助手头是空的 <think>。
        // 471 正是这条 ChatML 路径，而且不会走 MoE 预热。46 会把图拼在 user 轮外面。
        mb_mtmd_set_model_version(ctx, 471);
        mb_mtmd_set_image_max_slice_nums(ctx, p.image_max_slice_nums);
    }
    return ctx;
}

void ocr_free(void * ctx) {
    if (ctx) mb_mtmd_free(static_cast<mb_mtmd_context *>(ctx));
}

int ocr_prefill_image(void * ctx, const char * image_path) {
    return mb_mtmd_prefill_image(static_cast<mb_mtmd_context *>(ctx), image_path);
}

int ocr_prefill_text(void * ctx, const char * text, const char * role) {
    return mb_mtmd_prefill_text(static_cast<mb_mtmd_context *>(ctx), text, role);
}

ocr_token_t ocr_loop(void * ctx) {
    ocr_token_t result = { nullptr, 0, 0, nullptr };
    if (!ctx) { result.error_code = -1; result.error_msg = "null context"; return result; }

    auto * c = static_cast<mb_mtmd_context *>(ctx);
    mb_mtmd_token t = mb_mtmd_loop(c);
    result.text        = t.token;
    result.is_complete = t.is_end ? 1 : 0;
    result.error_code  = 0;
    // ocr_token_t takes ownership of t.text; caller frees with ocr_string_free()
    return result;
}

ocr_decode_perf_t ocr_decode_perf_peek(void * ctx) {
    ocr_decode_perf_t out = { 0, 0 };
    if (!ctx) return out;
    mb_mtmd_perf perf = mb_mtmd_perf_peek(static_cast<mb_mtmd_context *>(ctx));
    out.decode_tokens = perf.decode_tokens;
    out.decode_ms = perf.decode_ms;
    return out;
}

void ocr_clean_kv_cache(void * ctx) {
    if (ctx) mb_mtmd_clean_kv_cache(static_cast<mb_mtmd_context *>(ctx));
}

char * ocr_recognize(void * ctx, const char * image_path, const char * prompt, int max_tokens) {
    if (!ctx || !image_path || !prompt) return nullptr;

    auto * c = static_cast<mb_mtmd_context *>(ctx);

    if (ocr_prefill_image(c, image_path) != 0) return nullptr;
    if (ocr_prefill_text(c, prompt, "user") != 0) return nullptr;

    std::string result;
    for (int i = 0; i < max_tokens; ++i) {
        mb_mtmd_token tok = mb_mtmd_loop(c);
        if (tok.token) {
            result += tok.token;
            mb_mtmd_string_free(tok.token);
        }
        if (tok.is_end) break;
    }

    char * ret = (char *)malloc(result.size() + 1);
    memcpy(ret, result.data(), result.size());
    ret[result.size()] = '\0';
    return ret;
}

void ocr_string_free(const char * str) {
    free((void *)str);
}

} // extern "C"
