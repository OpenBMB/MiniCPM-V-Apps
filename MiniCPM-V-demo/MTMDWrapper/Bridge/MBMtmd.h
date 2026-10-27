//
//  MBMtmd.h
//  MiniCPM-V-demo
//
//  Thin C bridge over upstream llama.cpp mtmd public API.
//
//  Replaces the previous demo-private `mtmd-ios.h` that lived inside our
//  llama.cpp fork.  This file deliberately:
//
//    - exposes a pure C surface (no std::string in the header) so it can be
//      consumed via the Swift Bridging Header without enabling C++ interop
//      on every Swift translation unit;
//    - only #includes the public mtmd headers shipped in llama.xcframework
//      (mtmd.h / mtmd-helper.h / llama.h / ggml.h) — no demo-private
//      llama.cpp patches;
//    - keeps the call signatures 1:1 with the old `mtmd_ios_*` family so
//      MTMDWrapper.swift only needs symbol renaming, not behavioural changes.
//
//  The implementation lives in MBMtmd.mm and is built into the iOS app target
//  itself (NOT into the framework), so syncing llama.cpp upstream stays a
//  near-zero-conflict operation.
//

#ifndef MB_MTMD_H
#define MB_MTMD_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque context.
typedef struct mb_mtmd_context mb_mtmd_context;

// Initialization parameters.
//
// Differences vs the legacy `mtmd_ios_params`:
//   - `model_path` / `mmproj_path` are NOT in this struct; they are passed as
//     dedicated arguments to `mb_mtmd_init` so Swift callers don't need to
//     juggle `withCString` lifetimes when populating a struct field.
//   - `coreml_path` is gone (CoreML / ANE path is dropped while we re-sync to
//     upstream master).
//   - `image_max_tokens` (master mtmd's token-budget knob, only consumed by the
//     llava-uhd dyn_size path; minicpmv ignores it — see the `image_max_pixels = -1`
//     dump on the V4.7 mmproj) is exposed alongside `image_max_slice_nums`
//     (the slice-count knob the demo's chat slider actually drives). -1 on
//     either field means "model default".
//   - `n_ubatch` is exposed so the iOS / desktop caller can pick a per-device
//     memory budget.  See MBDeviceMemoryProbe.swift for how the iOS app maps
//     `os_proc_available_memory()` to a tier; `0` means "use bridge default"
//     (currently 512 — a conservative middle ground).
typedef struct mb_mtmd_params {
    int   n_predict;
    int   n_ctx;
    int   n_ubatch;            // physical batch size; dominates GPU compute buffer (set 0 for default)
    int   n_threads;
    float temperature;
    float top_p;                 // 1.0 = disabled;  only active when < 1.0
    int   top_k;                 // 0   = disabled;  only active when > 0
    bool  use_gpu;
    bool  mmproj_use_gpu;
    bool  warmup;
    int   image_max_tokens;
    int   image_max_slice_nums;  // llava-uhd slice cap (minicpmv / lfm2); -1 = model default
    int   moe_slot_bank;         // in-RAM expert slots; used together with moe_experts_path
    int   moe_decode_window;     // per-layer decode cache width in slots; 0 = app decides (see MTMDParams)
    int   moe_lookahead_prefetch_depth;        // 0 = off; 1..16 = predicted experts to prefetch
    // Expert-window cache prewarm (LLAMA_MOE_PREWARM). 0 = off; else the table size
    // (one of 8/16/32/48/64/96) of the **weighted** table baked into MBPrewarmTable.h.
    // The bridge writes the table to the sandbox and points the engine at it; the
    // engine loads it into the per-layer decode window just before the first token.
    int   moe_prewarm_level;
    // Which baked table the prewarm uses (only consulted when moe_prewarm_level > 0):
    //   0 = default weighted table, size = moe_prewarm_level
    //   1..4 = K4-total cluster tables    (k4t1..k4t4, 96 rows each)
    //   5..8 = K4-bottleneck cluster tables (k4b1..k4b4, 96 rows each)
    // Cluster tables come from clustering the 12 35BA3B showcase cases
    // (see stable_1002/warmup/run12/clusters/); they are truncated to the window
    // like the default tables, so a small `c` still works.
    int   moe_prewarm_table_id;
    // DSpark speculative decoding: draft tokens per round (`n_max`, clamped 0..16).
    //   0     = off (default; byte-for-byte the legacy one-token-per-call loop)
    //   1..16 = draft block width; only takes effect when `draft_model_path` is non-empty
    // When enabled the bridge also sets LLAMA_MOE_WINDOW_MAX_ROWS = n_max + 1 before the
    // target model load, and n_rs_seq = n_max on the target/draft contexts for rollback.
    int   spec_draft_n_max;
} mb_mtmd_params;

// Loop return value.
//
// `token` is a heap-allocated UTF-8 C string owned by the caller; free with
// `mb_mtmd_string_free`.  `is_end == true` signals end-of-generation; in that
// case `token` may be NULL.
typedef struct mb_mtmd_token {
    char * token;
    bool   is_end;
} mb_mtmd_token;

// Default params (mirrors mtmd-cli style: temperature sampling, top_k/p
// disabled to align with MiniCPM-V generation_config.json).
mb_mtmd_params mb_mtmd_params_default(void);

// Construct a context.
//
// `model_path` and `mmproj_path` MUST point to existing GGUF files; both are
// owned by the caller and may be freed as soon as `mb_mtmd_init` returns.
// `moe_experts_path` may be NULL or empty for a dense model.
// `draft_model_path` is the optional DSpark draft GGUF; NULL / empty disables speculative
// decoding (and it only takes effect together with `params->spec_draft_n_max > 0`).
// `params` may be NULL, in which case `mb_mtmd_params_default()` is used.
//
// Returns NULL on failure. Call `mb_mtmd_last_init_error()` for the reason
// (ctx is destroyed on failure so `mb_mtmd_get_last_error` cannot be used).
mb_mtmd_context * mb_mtmd_init(const char * model_path,
                               const char * mmproj_path,
                               const char * moe_experts_path,
                               const char * draft_model_path,
                               const mb_mtmd_params * params);

// Last `mb_mtmd_init` / `mb_mtmd_init_text_only` failure. Empty if none.
// Lifetime: valid until the next init call.
const char * mb_mtmd_last_init_error(void);

// Construct a text-only context (no mmproj / vision module).
//
// Used for pure-text models like MiniCPM 5 that do not have a vision encoder.
// `model_path` MUST point to an existing GGUF file.
// `moe_experts_path` may be NULL or empty for a plain dense text model; when set, routed
// experts stream from the experts (same contract as mb_mtmd_init).
// `draft_model_path` behaves exactly as in mb_mtmd_init (NULL / empty = off).
// Returns NULL on failure.
mb_mtmd_context * mb_mtmd_init_text_only(const char * model_path,
                                         const char * moe_experts_path,
                                         const char * draft_model_path,
                                         const mb_mtmd_params * params);

// Release all resources owned by the context.
void mb_mtmd_free(mb_mtmd_context * ctx);

// Prefill an image (general "user attached an image" path).
//
// For V4.6-and-earlier models this encodes *and* writes the KV immediately:
//   bitmap = mtmd_helper_bitmap_init_from_file(image_path)
//   chunks = mtmd_tokenize(<__media__>, [bitmap])
//   chunk-by-chunk eval (logits_last=false)
//
// For ChatML-MoE models (model_version 36/47) the image is deferred instead:
// the media marker has to sit inside `<|im_start|>user\n…<|im_end|>`, and that
// string only exists once the user text arrives. Only the KV write is deferred
// though — the ViT encode is position-independent, so it runs here (eager) and
// `mb_mtmd_prefill_text` reuses the embedding at the right position. That is
// what makes the caller-visible "image preprocessing" time a real number.
//
// Advances n_past on the immediate path; on the deferred path the advance
// happens in the following mb_mtmd_prefill_text.
// Returns 0 on success, non-zero on failure (use mb_mtmd_get_last_error).
int mb_mtmd_prefill_image(mb_mtmd_context * ctx, const char * image_path);

// Expert-window prewarm for the image just encoded by mb_mtmd_prefill_image.
//
// Deliberately a SEPARATE entry point (not folded into mb_mtmd_prefill_image) so the
// caller can time "image preprocessing" without the prewarm read in it: the caller
// measures the encode, then calls this. The prewarm then shows up in neither the
// preprocess timing nor the first-token path (it runs in the idle window between
// picking the image and hitting send).
//
// Also rebuilds the adaptive ubatch first (the rebuild swaps the llama_context the
// MoE runtime hangs off, so it must precede the prewarm). No-op when the model is
// not ChatML-MoE, no image is pending, or prewarm is off. Returns 0 on success.
int mb_mtmd_prewarm_after_image(mb_mtmd_context * ctx);

// Prefill a single video frame.  Currently behaves the same as
// mb_mtmd_prefill_image; kept as a separate entry point so the iOS video
// pipeline can later attach frame-specific markers without touching Swift.
int mb_mtmd_prefill_frame(mb_mtmd_context * ctx, const char * image_path);

// Prefill a chat-formatted text turn.  `role` is one of "user" / "assistant"
// / "system".  Internally wraps `text` in MiniCPM-V 4.6's chatml template
// fragment (the same template the mtmd-ios bridge used to apply manually,
// because the model's GGUF chat_template does not encode the
// enable_thinking=false prefix).  Advances n_past with logits_last=true so
// the next call to mb_mtmd_loop can sample.
int mb_mtmd_prefill_text(mb_mtmd_context * ctx, const char * text, const char * role);

// Per-turn prefill / decode counters. Wall time is native eval only
// (tokenize + llama_decode / chunk eval), not Swift UI sleep.
//
// `image_encode_ms` / `image_tokens` describe the *eager* ViT encode that runs
// at image-select time for ChatML-MoE models (see mb_mtmd_prefill_image). It is
// deliberately kept out of prefill_ms: by the time the user turn is prefilled
// the image is already an embedding, so folding it in would make prefill t/s
// incomparable across turns.
typedef struct mb_mtmd_perf {
    int32_t prefill_tokens;
    int32_t decode_tokens;
    double  prefill_ms;
    double  decode_ms;
    double  prep_ms;           // send-turn prep (mmproj reload / image decode / tokenize); outside prefill_ms
    int32_t moe_k_prefill;     // 0 = not MoE SSD
    int32_t moe_k_decode;
    int32_t image_tokens;      // 0 = no eager image this turn
    double  image_encode_ms;   // measured outside prefill_ms
} mb_mtmd_perf;

// Start a fresh turn. Next prefill_image / prefill_text also auto-starts
// a turn if none is open, so an explicit reset is optional.
void mb_mtmd_perf_reset(mb_mtmd_context * ctx);

// Copy the current turn's counters. Closes the turn so the next prefill
// starts a new one. Safe to call with a NULL ctx (returns zeros).
mb_mtmd_perf mb_mtmd_perf_snapshot(mb_mtmd_context * ctx);

// Same counters as snapshot, but does not close the turn, log, or park memory.
// Used to refresh the on-screen live speed while generation is still running.
mb_mtmd_perf mb_mtmd_perf_peek(mb_mtmd_context * ctx);

// Sample one token, decode it back into the KV cache, and return it.
// Repeated calls drive generation forward until is_end becomes true (EOG).
mb_mtmd_token mb_mtmd_loop(mb_mtmd_context * ctx);

// Free a token string previously returned via mb_mtmd_token.token.
void mb_mtmd_string_free(char * str);

// 把一段完整文本（prompt / 生成结果）记进运行日志：NSLog + App 沙盒
// Documents/mb_run_log.txt。Swift 侧用它落盘完整输出，避免 unified log 截断。
void mb_mtmd_log_text(const char * tag, const char * text);

// Last error message for the given ctx; empty string if no error.  Lifetime
// is tied to ctx; copy if you need to keep it.
const char * mb_mtmd_get_last_error(mb_mtmd_context * ctx);

// Wipe the KV cache (sequence 0) and reset n_past to 0.  Used between turns
// when starting a fresh conversation; does NOT tear down the model.
bool mb_mtmd_clean_kv_cache(mb_mtmd_context * ctx);

// Set the MiniCPM-V model version so the prompt template can branch on it.
//
// Values follow the convention:
//   26  = MiniCPM-V 2.6 (no thinking support)
//   40  = MiniCPM-V 4.0 (no thinking support)
//   46  = MiniCPM-V 4.6 (thinking disabled via empty block)
//    5  = MiniCPM 5 text-only (thinking gated by mb_mtmd_set_enable_thinking)
//   36  = Qwen3.6 (thinking always off: empty <think> block; template default is ON)
//   47  = MiniCPM-V 4.7 MoE SSD (same ChatML template as 36: thinking always off)
//
// Must be called after mb_mtmd_init / mb_mtmd_init_text_only.
// If never called, defaults to 46 (legacy behaviour).
void mb_mtmd_set_model_version(mb_mtmd_context * ctx, int version);

// MiniCPM5 / V-4.6 thinking toggle. Default is off (empty <think> block).
// On:  assistant header + "<think>\n" so the model writes its own reasoning.
// Off: assistant header + "<think>\n\n</think>\n\n" so it answers immediately.
// No-op for models without thinking (V-4 / V-2.6). Safe to call between
// turns; next prefill_text picks up the new value. Must be called after init.
void mb_mtmd_set_enable_thinking(mb_mtmd_context * ctx, bool enable);

// Runtime override of the per-image slice-count knob.
//
// Internally calls mtmd_set_image_max_slice_nums on the underlying
// mtmd_context, which patches clip_hparams.custom_image_max_slice_nums
// in place.  The slicing decision is re-read on every encode (see
// mtmd-image.cpp::get_slice_instructions), so the next image picks up
// the new value automatically — no need to reload the mmproj.
//
// `n` semantics:
//   -1 (or 0)  = revert to the model default (currently 9 for MiniCPM-V)
//    1         = disable slicing entirely (single overview image, ~9x fewer
//                tokens, much faster on mobile but loses fine detail)
//    2..9      = explicit cap chosen by the chat-page slider
//
// Safe to call between images.  No-op for models that don't use slicing.
void mb_mtmd_set_image_max_slice_nums(mb_mtmd_context * ctx, int n);

// MoE look-ahead expert prefetch depth. 0 = no next-layer predict / prefetch.
// 1..16 = predicted experts. Applies on the next llama_decode; no model reload.
// No-op if this context has no MoE experts. Returns the clamped value in use.
int mb_mtmd_set_moe_lookahead_prefetch_depth(mb_mtmd_context * ctx, int depth);
int mb_mtmd_get_moe_lookahead_prefetch_depth(const mb_mtmd_context * ctx);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // MB_MTMD_H
