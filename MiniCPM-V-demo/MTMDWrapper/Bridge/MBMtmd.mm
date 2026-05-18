//
//  MBMtmd.mm
//  MiniCPM-V-demo
//
//  Implementation of the MBMtmd C bridge.  Translates the call patterns we
//  used to get out of the demo-private `mtmd-ios.cpp` (which lived inside
//  our llama.cpp fork) into the upstream-master public API surface:
//
//      llama.h         - model + context lifecycle, llama_batch, sampler chain
//      mtmd.h          - vision context + tokenization
//      mtmd-helper.h   - bitmap loading + eval-chunks dispatch
//
//  By design we do NOT touch any internal common/* / sampling.h / chat.h
//  headers.  Those live behind the static libcommon shipped inside
//  llama.framework but are not part of the framework's public Headers
//  module.  Keeping the bridge self-contained means the framework's
//  modulemap surface stays tiny (mtmd.h + mtmd-helper.h + llama core) and
//  re-syncing llama.cpp upstream stays trivial.
//

#import "MBMtmd.h"

// Public llama.cpp headers exposed via llama.framework's modulemap.
#include <llama/llama.h>
#include <llama/mtmd.h>
#include <llama/mtmd-helper.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {

// MiniCPM-V 4.6 instruct chatml template fragment.
//
// We hand-roll the template instead of using llama_chat_apply_template /
// common_chat_format because the GGUF-embedded chat_template doesn't encode
// the instruct variant's `enable_thinking=false` prefix
// (`<think>\n\n</think>\n\n` between assistant header and content), and the
// non-jinja apply path doesn't know how to splice it in either.
//
// We deliberately do NOT inject any default system prompt here.  The
// reference Python pipeline (`AutoModel.chat(...)` / `apply_chat_template`)
// does not insert one either when the caller passes only a user message,
// and any English-only system string ("You are a helpful assistant.") was
// observed to bias MiniCPM-V into answering Chinese queries in English —
// which is exactly the bug we hit on iOS after porting the legacy bridge.
// If a caller really wants a system prompt, it should be requested
// explicitly via `mb_mtmd_prefill_text(..., role="system")` before the
// first user turn.

// One-shot helper for llama_token -> std::string using only public llama.h API.
// Mirrors what common_token_to_piece does, minus the std::vector roundtrip.
std::string token_to_piece_impl(const llama_vocab * vocab, llama_token token) {
    char buf[256];
    int32_t n = llama_token_to_piece(vocab, token, buf, sizeof(buf), /*lstrip=*/0, /*special=*/false);
    if (n >= 0) {
        return std::string(buf, n);
    }
    // Buffer too small (extremely rare for a single token).  Re-try with the
    // exact required size.  Use std::vector<char> so we have a writable
    // buffer (std::string::data() returns const char* before C++17, which
    // does not match llama_token_to_piece's char* parameter).
    std::vector<char> wide(static_cast<size_t>(-n));
    int32_t n2 = llama_token_to_piece(vocab, token, wide.data(), static_cast<int32_t>(wide.size()),
                                      /*lstrip=*/0, /*special=*/false);
    if (n2 < 0) {
        return std::string();
    }
    return std::string(wide.data(), static_cast<size_t>(n2));
}

// Add a single token to a freshly-cleared llama_batch with seq_id={0} and
// logits=true (so the next sample call sees its logits).
void batch_add_one(llama_batch & b, llama_token tok, llama_pos pos, llama_seq_id seq) {
    b.n_tokens         = 1;
    b.token[0]         = tok;
    b.pos[0]           = pos;
    b.n_seq_id[0]      = 1;
    b.seq_id[0][0]     = seq;
    b.logits[0]        = 1;
}

// RAII for llama-side handles owned by the bridge ctx.  We use raw pointers
// because llama.h does not ship a C++ unique_ptr deleter set; a tiny custom
// deleter struct avoids pulling in <llama-cpp.h> (which is not in the
// framework's public Headers).
struct llama_model_deleter   { void operator()(llama_model   * m) const { if (m) llama_model_free(m); } };
struct llama_context_deleter { void operator()(llama_context * c) const { if (c) llama_free(c);       } };
struct llama_sampler_deleter { void operator()(llama_sampler * s) const { if (s) llama_sampler_free(s); } };
struct mtmd_context_deleter  { void operator()(mtmd_context  * v) const { if (v) mtmd_free(v);        } };

using llama_model_ptr   = std::unique_ptr<llama_model,   llama_model_deleter>;
using llama_context_ptr = std::unique_ptr<llama_context, llama_context_deleter>;
using llama_sampler_ptr = std::unique_ptr<llama_sampler, llama_sampler_deleter>;
using mtmd_context_ptr  = std::unique_ptr<mtmd_context,  mtmd_context_deleter>;

} // namespace

struct mb_mtmd_context {
    llama_model_ptr     model;
    llama_context_ptr   lctx;
    llama_sampler_ptr   sampler;
    mtmd_context_ptr    vision;

    // n_batch the lctx was actually built with (after llama_n_batch(ctx)
    // query).  We use this for both the prefill batch size and the size of
    // our llama_batch ring buffer.
    int32_t             n_batch = 2048;

    llama_batch         batch{};         // generation-loop batch (n_tokens=1)
    bool                batch_inited = false;

    const llama_vocab * vocab = nullptr; // borrowed from model

    llama_pos           n_past = 0;      // position counter for seq=0

    std::string         last_error;

    ~mb_mtmd_context() {
        if (batch_inited) {
            llama_batch_free(batch);
        }
        // unique_ptrs handle the rest in the right order:
        //   sampler -> vision -> lctx -> model
        // (mtmd_context internally borrows model; vision must die before model.)
    }
};

// ---------------------------------------------------------------------------
//  Helpers
// ---------------------------------------------------------------------------

static void set_error(mb_mtmd_context * ctx, const std::string & err) {
    if (ctx) ctx->last_error = err;
    fprintf(stderr, "[MBMtmd] %s\n", err.c_str());
}

// ---------------------------------------------------------------------------
//  Public C API
// ---------------------------------------------------------------------------

mb_mtmd_params mb_mtmd_params_default(void) {
    mb_mtmd_params p = {};
    p.n_predict         = -1;
    p.n_ctx             = 4096;
    p.n_ubatch          = 0;       // 0 = pick MB_DEFAULT_N_UBATCH below
    p.n_threads         = 4;
    p.temperature       = 0.7f;
    p.use_gpu           = true;
    p.mmproj_use_gpu    = true;
    p.warmup            = true;
    p.image_max_tokens  = -1;
    return p;
}

// Default n_ubatch when the caller did not specify one (mb_mtmd_params.n_ubatch == 0).
//
// 512 is a "safe everywhere" middle ground — on a measurement run with
// MiniCPM-V 4.6 Q4_K_M it spends ~487 MiB of MTL0 compute buffer, fitting
// comfortably under the ~1.5 GB application memory limit on a 4 GB iPhone.
// For tighter or looser devices the iOS layer overrides this via
// MBDeviceMemoryProbe; the bridge default is only used when no caller is
// driving the value (e.g. the macOS bridge_test CLI without env override).
static constexpr int MB_DEFAULT_N_UBATCH = 512;

mb_mtmd_context * mb_mtmd_init(const char * model_path,
                               const char * mmproj_path,
                               const mb_mtmd_params * params_in) {
    if (!model_path || !*model_path || !mmproj_path || !*mmproj_path) {
        fprintf(stderr, "[MBMtmd] mb_mtmd_init: missing model_path or mmproj_path\n");
        return nullptr;
    }

    mb_mtmd_params params = params_in ? *params_in : mb_mtmd_params_default();

    llama_backend_init();

    // std::make_unique is C++14; some Xcode build configs in this project use
    // gnu++0x (= C++11) for ObjC++ targets, so we stick with the C++11 form.
    std::unique_ptr<mb_mtmd_context> ctx(new mb_mtmd_context());

    // ---- Load text model ----
    llama_model_params mparams = llama_model_default_params();
    mparams.use_mmap     = true;
    mparams.use_mlock    = false;
    mparams.n_gpu_layers = params.use_gpu ? 999 : 0;

    ctx->model.reset(llama_model_load_from_file(model_path, mparams));
    if (!ctx->model) {
        set_error(ctx.get(), std::string("Failed to load model from: ") + model_path);
        return nullptr;
    }

    // ---- Create llama_context ----
    //
    // Memory budget notes (this is the part that hurts on older iPhones):
    //
    //   * `n_ubatch` (physical batch) dominates the GPU compute buffer.  The
    //     output projection alone is `n_ubatch * vocab * sizeof(f32)`; for
    //     MiniCPM-V 4.6 on Qwen vocab (~150K) that is roughly (Apple Silicon,
    //     Metal):
    //         n_ubatch=2048  →  ~1946 MiB MTL0 compute  (legacy mtmd-ios default)
    //         n_ubatch=1024  →  ~970  MiB
    //         n_ubatch= 512  →  ~487  MiB
    //         n_ubatch= 256  →  ~243  MiB
    //         n_ubatch= 128  →  ~120  MiB
    //     Speed is roughly flat across this range on A-series GPUs (decode
    //     is bandwidth-bound, not compute-bound), so smaller n_ubatch is a
    //     near-pure memory win.  Caller picks per-device — see
    //     MBDeviceMemoryProbe.swift on iOS — so the bridge stays portable.
    //
    //   * `n_batch` (logical max single submission) stays at 2048; llama
    //     internally chunks batches into n_ubatch-sized physical pieces, so
    //     a large logical batch is "more dispatches", not a memory hit.
    //
    //   * `flash_attn_type=AUTO` lets the backend pick; on Metal this turns
    //     into ENABLED for f16 KV, which avoids materialising the (n_ctx ×
    //     n_ctx) attention matrix and is a strict memory + speed win.
    //
    //   * KV cache dtype stays at the model default (f16) for now.  Dropping
    //     to q8_0 / q4_0 would save another ~half the KV memory but the
    //     quality / latency trade-off needs measuring first; tracked
    //     separately, not done here.
    const int requested_ubatch = params.n_ubatch > 0 ? params.n_ubatch : MB_DEFAULT_N_UBATCH;

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx           = static_cast<uint32_t>(params.n_ctx > 0 ? params.n_ctx : 4096);
    cparams.n_batch         = 2048;
    cparams.n_ubatch        = static_cast<uint32_t>(requested_ubatch);
    cparams.n_threads       = params.n_threads;
    cparams.n_threads_batch = params.n_threads;
    cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
    cparams.no_perf         = false;

    fprintf(stderr, "[MBMtmd] llama_context: n_ctx=%u n_batch=%u n_ubatch=%u flash_attn=AUTO\n",
            cparams.n_ctx, cparams.n_batch, cparams.n_ubatch);

    ctx->lctx.reset(llama_init_from_model(ctx->model.get(), cparams));
    if (!ctx->lctx) {
        set_error(ctx.get(), "Failed to create llama_context");
        return nullptr;
    }

    ctx->vocab   = llama_model_get_vocab(ctx->model.get());
    ctx->n_batch = static_cast<int32_t>(llama_n_batch(ctx->lctx.get()));

    // ---- Build sampler chain (pure-temperature, MiniCPM-V default) ----
    // Aligns with the legacy mtmd-ios.cpp / llama_jni.cpp convention:
    //   penalty_repeat = 1.0   (disabled)
    //   top_k          = 0     (disabled)
    //   top_p          = 1.0   (disabled)
    //   temperature    = params.temperature
    //   final          = dist(seed)
    {
        llama_sampler_chain_params scp = llama_sampler_chain_default_params();
        scp.no_perf = false;
        ctx->sampler.reset(llama_sampler_chain_init(scp));
        if (!ctx->sampler) {
            set_error(ctx.get(), "Failed to init sampler chain");
            return nullptr;
        }
        if (params.temperature > 0.0f) {
            llama_sampler_chain_add(ctx->sampler.get(), llama_sampler_init_temp(params.temperature));
            llama_sampler_chain_add(ctx->sampler.get(), llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
        } else {
            llama_sampler_chain_add(ctx->sampler.get(), llama_sampler_init_greedy());
        }
    }

    // ---- Allocate generation batch ----
    ctx->batch        = llama_batch_init(ctx->n_batch, /*embd=*/0, /*n_seq_max=*/1);
    ctx->batch_inited = true;
    if (!ctx->batch.token) {
        set_error(ctx.get(), "Failed to llama_batch_init");
        return nullptr;
    }

    // ---- Init vision context ----
    {
        mtmd_context_params vparams = mtmd_context_params_default();
        vparams.use_gpu          = params.mmproj_use_gpu;
        vparams.print_timings    = false;
        vparams.n_threads        = params.n_threads;
        vparams.warmup           = params.warmup;
        vparams.image_max_tokens = params.image_max_tokens;
        // image_min_tokens / flash_attn_type / cb_eval are intentionally left
        // at their defaults; the demo never tuned them.

        ctx->vision.reset(mtmd_init_from_file(mmproj_path, ctx->model.get(), vparams));
        if (!ctx->vision) {
            set_error(ctx.get(), std::string("Failed to load mmproj from: ") + mmproj_path);
            return nullptr;
        }
    }

    return ctx.release();
}

void mb_mtmd_free(mb_mtmd_context * ctx) {
    delete ctx;
}

void mb_mtmd_string_free(char * str) {
    if (str) free(str);
}

const char * mb_mtmd_get_last_error(mb_mtmd_context * ctx) {
    if (!ctx) return "";
    return ctx->last_error.c_str();
}

bool mb_mtmd_clean_kv_cache(mb_mtmd_context * ctx) {
    if (!ctx || !ctx->lctx) return false;
    llama_memory_seq_rm(llama_get_memory(ctx->lctx.get()), /*seq=*/0, /*p0=*/0, /*p1=*/-1);
    ctx->n_past = 0;
    return true;
}

void mb_mtmd_set_image_max_slice_nums(mb_mtmd_context * /*ctx*/, int /*n*/) {
    // No-op on upstream master.  See the header comment for context.
    // Intentionally not setting last_error: this is a known UX downgrade,
    // not a runtime failure.
}

// ---------------------------------------------------------------------------
//  Memory rollback helper
// ---------------------------------------------------------------------------

// Roll the KV / SSM state back to (or past, if necessary) `start_n_past`
// after a partially-applied prefill failure.
//
// `llama_memory_seq_rm(seq, p0, -1)` is documented to "Return false if a
// partial sequence cannot be removed. Removing a whole sequence never
// fails."  MiniCPM-V 4.6's LLM (Qwen3-Mamba) is a hybrid SSM + Attention
// model — the SSM half streams state and has no per-token slot concept,
// so partial truncation at p0 > 0 is physically unsupported and the call
// returns false leaving the KV at whatever last position the half-applied
// prefill left it at.
//
// When that happens we have no choice but to wipe the entire sequence and
// reset `ctx->n_past = 0`.  That throws away the conversation history so
// far, but it leaves the ctx in a consistent state instead of an
// "every future prefill fails forever" zombie state, which is the
// failure mode the user actually hits when the upstream M-RoPE
// X < Y check trips (see prefill_image_like / prefill_text comments).
//
// Returns true if a clean partial rollback succeeded (best-case;
// happens on pure-attention models).  Returns false if we had to do the
// full wipe (signals to the caller that ctx->n_past is now 0).
static bool rollback_to_n_past(mb_mtmd_context * ctx, llama_pos start_n_past) {
    llama_memory_t mem = llama_get_memory(ctx->lctx.get());
    if (start_n_past > 0) {
        if (llama_memory_seq_rm(mem, /*seq=*/0, /*p0=*/start_n_past, /*p1=*/-1)) {
            ctx->n_past = start_n_past;
            return true;
        }
        fprintf(stderr, "[MBMtmd] partial rollback to n_past=%d unsupported by this memory module (likely SSM/hybrid); falling back to full wipe.\n",
                static_cast<int>(start_n_past));
    }
    // Either start_n_past == 0 (nothing to rewind anyway) or partial removal
    // refused.  Wipe the whole sequence — guaranteed to succeed by the
    // llama.h contract.
    llama_memory_seq_rm(mem, /*seq=*/0, /*p0=*/0, /*p1=*/-1);
    ctx->n_past = 0;
    return false;
}

// ---------------------------------------------------------------------------
//  Prefill helpers
// ---------------------------------------------------------------------------

// Common path for prefill_image / prefill_frame.  text_prompt is the raw
// chat-formatted text containing exactly one media marker, or nullptr to use
// the default media marker alone (legacy mtmd-ios behaviour).
static int prefill_image_like(mb_mtmd_context * ctx,
                              const char * image_path,
                              const char * caller_label) {
    if (!ctx || !image_path || !*image_path) {
        if (ctx) set_error(ctx, std::string(caller_label) + ": empty image path");
        return -1;
    }

    mtmd_bitmap * raw_bmp = mtmd_helper_bitmap_init_from_file(ctx->vision.get(), image_path);
    if (!raw_bmp) {
        set_error(ctx, std::string(caller_label) + ": failed to load image: " + image_path);
        return -1;
    }
    // Adopt ownership; freed with the input_chunks below or here on early exit.
    std::unique_ptr<mtmd_bitmap, void(*)(mtmd_bitmap*)> bmp(raw_bmp, mtmd_bitmap_free);

    mtmd_input_text text;
    text.text          = mtmd_default_marker();
    text.add_special   = (ctx->n_past == 0);
    text.parse_special = true;

    mtmd_input_chunks * chunks = mtmd_input_chunks_init();
    if (!chunks) {
        set_error(ctx, std::string(caller_label) + ": mtmd_input_chunks_init failed");
        return -1;
    }
    std::unique_ptr<mtmd_input_chunks, void(*)(mtmd_input_chunks*)> chunks_guard(chunks, mtmd_input_chunks_free);

    const mtmd_bitmap * bmp_arr[1] = { bmp.get() };
    int32_t res = mtmd_tokenize(ctx->vision.get(), chunks, &text, bmp_arr, 1);
    if (res != 0) {
        set_error(ctx, std::string(caller_label) + ": mtmd_tokenize failed, res=" + std::to_string(res));
        return -1;
    }

    const llama_pos start_n_past = ctx->n_past;
    llama_pos new_n_past = start_n_past;
    int32_t   ev = mtmd_helper_eval_chunks(ctx->vision.get(),
                                           ctx->lctx.get(),
                                           chunks,
                                           start_n_past,
                                           /*seq_id=*/0,
                                           ctx->n_batch,
                                           /*logits_last=*/false,
                                           &new_n_past);
    if (ev != 0) {
        // mtmd_helper_eval_chunks 是部分原子的：前 i-1 个 chunk 可能已经成功 decode
        // 并把 KV 推进到 start_n_past 之后某个位置；如果只是 return -1 而不动 KV，
        // ctx->n_past 跟 KV 就裂开了，对 M-RoPE / hybrid SSM+Attn 模型（MiniCPM-V
        // 4.6 LLM 是 Qwen3-Mamba）下次 llama_decode 必定撞硬性一致性检查
        // "for M-RoPE, it is required that X < Y"，之后所有 prefill 连环失败。
        // 详细 fallback 策略见 rollback_to_n_past 的 doc comment（partial truncate
        // 在 SSM 路径上 unsupported，会自动 fallback 到全清 + n_past=0）。
        const bool clean_rollback = rollback_to_n_past(ctx, start_n_past);
        const std::string suffix = clean_rollback
            ? " (KV rolled back to n_past=" + std::to_string(start_n_past) + ")"
            : " (partial rollback unsupported on SSM/hybrid; full wipe + n_past=0; conversation history cleared)";
        set_error(ctx, std::string(caller_label) + ": mtmd_helper_eval_chunks failed, ret=" + std::to_string(ev) + suffix);
        return -1;
    }

    ctx->n_past = new_n_past;
    return 0;
}

int mb_mtmd_prefill_image(mb_mtmd_context * ctx, const char * image_path) {
    return prefill_image_like(ctx, image_path, "prefill_image");
}

int mb_mtmd_prefill_frame(mb_mtmd_context * ctx, const char * image_path) {
    return prefill_image_like(ctx, image_path, "prefill_frame");
}

int mb_mtmd_prefill_text(mb_mtmd_context * ctx, const char * text_in, const char * role_in) {
    if (!ctx || !text_in || !role_in || !*text_in || !*role_in) {
        if (ctx) set_error(ctx, "prefill_text: empty text or role");
        return -1;
    }

    const std::string text = text_in;
    const std::string role = role_in;

    // MiniCPM-V 4.6 instruct chatml template fragment.  Hand-rolled because
    // the GGUF-embedded template does not encode the enable_thinking=false
    // prefix.  No default system prompt is injected — see top-of-file note.
    std::string formatted;
    if (role == "user") {
        formatted += "<|im_start|>user\n" + text + "<|im_end|>\n";
        formatted += "<|im_start|>assistant\n<think>\n\n</think>\n\n";
    } else if (role == "assistant") {
        formatted = text + "<|im_end|>\n";
    } else if (role == "system") {
        formatted = "<|im_start|>system\n" + text + "<|im_end|>\n";
    } else {
        set_error(ctx, "prefill_text: unknown role: " + role);
        return -1;
    }

    mtmd_input_text in;
    in.text          = formatted.c_str();
    in.add_special   = (ctx->n_past == 0);
    in.parse_special = true;

    mtmd_input_chunks * chunks = mtmd_input_chunks_init();
    if (!chunks) {
        set_error(ctx, "prefill_text: mtmd_input_chunks_init failed");
        return -1;
    }
    std::unique_ptr<mtmd_input_chunks, void(*)(mtmd_input_chunks*)> chunks_guard(chunks, mtmd_input_chunks_free);

    int32_t res = mtmd_tokenize(ctx->vision.get(), chunks, &in, /*bitmaps=*/nullptr, /*n_bitmaps=*/0);
    if (res != 0) {
        set_error(ctx, "prefill_text: mtmd_tokenize failed, res=" + std::to_string(res));
        return -1;
    }

    const llama_pos start_n_past = ctx->n_past;
    llama_pos new_n_past = start_n_past;
    // logits_last=true so the next mb_mtmd_loop call has fresh logits to sample.
    int32_t ev = mtmd_helper_eval_chunks(ctx->vision.get(),
                                         ctx->lctx.get(),
                                         chunks,
                                         start_n_past,
                                         /*seq_id=*/0,
                                         ctx->n_batch,
                                         /*logits_last=*/true,
                                         &new_n_past);
    if (ev != 0) {
        // 同 prefill_image_like 的回滚策略；SSM/hybrid 模型下 partial truncate 不
        // 支持时会自动 fallback 到全清 + n_past=0。
        const bool clean_rollback = rollback_to_n_past(ctx, start_n_past);
        const std::string suffix = clean_rollback
            ? " (KV rolled back to n_past=" + std::to_string(start_n_past) + ")"
            : " (partial rollback unsupported on SSM/hybrid; full wipe + n_past=0; conversation history cleared)";
        set_error(ctx, "prefill_text: mtmd_helper_eval_chunks failed, ret=" + std::to_string(ev) + suffix);
        return -1;
    }

    ctx->n_past = new_n_past;
    return 0;
}

mb_mtmd_token mb_mtmd_loop(mb_mtmd_context * ctx) {
    mb_mtmd_token result = { /*token=*/nullptr, /*is_end=*/true };
    if (!ctx || !ctx->lctx || !ctx->sampler) return result;

    // 1) Sample one token from the most recent decode's logits.
    llama_token tok = llama_sampler_sample(ctx->sampler.get(), ctx->lctx.get(), /*idx=*/-1);
    llama_sampler_accept(ctx->sampler.get(), tok);

    const bool is_eog = llama_vocab_is_eog(ctx->vocab, tok);

    // 2) Detokenize for the UI BEFORE we feed it back, but only when the
    //    token is non-EOG (EOG tokens have no user-visible piece).
    std::string piece = is_eog ? std::string() : token_to_piece_impl(ctx->vocab, tok);

    // 3) Always feed the token back into the KV cache, EOG included, to
    //    keep n_past consistent — otherwise a hole opens at pos=n_past-1
    //    and subsequent prefills' attention reads uninitialized memory.
    batch_add_one(ctx->batch, tok, ctx->n_past, /*seq=*/0);
    ctx->n_past++;
    if (llama_decode(ctx->lctx.get(), ctx->batch) != 0) {
        set_error(ctx, "loop: llama_decode failed");
        result.is_end = true;
        return result;
    }

    if (is_eog) {
        result.is_end = true;
        return result;
    }

    // 4) Hand piece off to the caller as a malloc'd C string.
    result.token = static_cast<char *>(malloc(piece.size() + 1));
    if (result.token) {
        memcpy(result.token, piece.data(), piece.size());
        result.token[piece.size()] = '\0';
    }
    result.is_end = false;
    return result;
}
