//
//  Implementation of the MBMtmd C bridge.  Targets the public API surface
//  only: llama.h, mtmd.h, mtmd-helper.h.  Deliberately does NOT include any
//  internal common/* header, so the framework modulemap stays tiny and
//  re-syncing llama.cpp upstream stays trivial.
//
//  Deep rationale and measurements: Comni/v47/ios-app-引擎桥接说明.md

#import "MBMtmd.h"
// 内嵌的缓存预热表（top48u / top48w），由 stable_1002/warmup/mk_bridge_header.py 生成。
#import "MBPrewarmTable.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

// 直接用 C API 查「本进程还能分配多少」，用来给 ubatch 封顶 —— 这样不必依赖
// Swift 层的 MBDeviceMemoryProbe（桥接层不该反向依赖 Swift）。
#include <os/proc.h>

// Public llama.cpp headers exposed via llama.framework's modulemap.
#include <llama/llama.h>
#include <llama/mtmd.h>
#include <llama/mtmd-helper.h>

#include <algorithm>
#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <mach/mach.h>

// 日志双写：NSLog（可直播抓）+ Documents/mb_run_log.txt（完整，unified log 会截断单条）。
static const char * mb_run_log_path(void) {
    static char path[4096] = {0};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @autoreleasepool {
            NSArray<NSString *> * dirs =
                NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
            NSString * dir = dirs.firstObject ?: NSTemporaryDirectory();
            NSString * p = [dir stringByAppendingPathComponent:@"mb_run_log.txt"];
            snprintf(path, sizeof(path), "%s", p.fileSystemRepresentation);
        }
    });
    return path;
}

static void mb_log_raw_line(const char * text) {
    FILE * f = fopen(mb_run_log_path(), "a");
    if (f) {
        fputs(text, f);
        fputc('\n', f);
        fclose(f);
    }
    NSLog(@"[MBLOG] %s", text);
}

static void mb_logf(const char * fmt, ...) __attribute__((format(printf, 1, 2)));
static void mb_logf(const char * fmt, ...) {
    va_list ap, ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    const int n = vsnprintf(nullptr, 0, fmt, ap);
    va_end(ap);
    if (n < 0) {
        va_end(ap2);
        return;
    }
    std::string s(static_cast<size_t>(n) + 1, '\0');
    vsnprintf(&s[0], static_cast<size_t>(n) + 1, fmt, ap2);
    va_end(ap2);
    s.resize(static_cast<size_t>(n));
    mb_log_raw_line(s.c_str());
}

// 完整文本（prompt / 输出）：文件里保留全部字节；NSLog 只是直播辅助。
void mb_mtmd_log_text(const char * tag, const char * text) {
    if (!tag) tag = "text";
    if (!text) text = "(null)";
    const size_t len = strlen(text);
    FILE * f = fopen(mb_run_log_path(), "a");
    if (f) {
        fprintf(f, "===== %s (%zu bytes) =====\n", tag, len);
        fwrite(text, 1, len, f);
        fputc('\n', f);
        fclose(f);
    }
    NSString * ns = [[NSString alloc] initWithBytes:text length:len encoding:NSUTF8StringEncoding];
    if (ns) {
        NSLog(@"[MBLOG] %s (%zu bytes)\n%@", tag, len, ns);
    } else {
        NSLog(@"[MBLOG] %s (%zu bytes, non-utf8)", tag, len);
    }
}

// DSpark：libcommon 导出了 common_speculative_* / common_context_* 符号。
// 结构体布局必须与 libcommon 编译的那份逐字一致，否则写字段会错位。详见文档 §3。

enum common_speculative_type {
    COMMON_SPECULATIVE_TYPE_NONE          = 0,
    COMMON_SPECULATIVE_TYPE_DRAFT_SIMPLE  = 1,
    COMMON_SPECULATIVE_TYPE_DRAFT_EAGLE3  = 2,
    COMMON_SPECULATIVE_TYPE_DRAFT_MTP     = 3,
    COMMON_SPECULATIVE_TYPE_DRAFT_DFLASH  = 4,
    COMMON_SPECULATIVE_TYPE_DRAFT_DSPARK  = 5,
    COMMON_SPECULATIVE_TYPE_NGRAM_SIMPLE  = 6,
    COMMON_SPECULATIVE_TYPE_NGRAM_MAP_K   = 7,
    COMMON_SPECULATIVE_TYPE_NGRAM_MAP_K4V = 8,
    COMMON_SPECULATIVE_TYPE_NGRAM_MOD     = 9,
    COMMON_SPECULATIVE_TYPE_NGRAM_CACHE   = 10,
    COMMON_SPECULATIVE_TYPE_COUNT         = 11,
};

enum common_context_seq_rm_type {
    COMMON_CONTEXT_SEQ_RM_TYPE_NO   = 0, // seq_rm not supported (e.g. no memory module)
    COMMON_CONTEXT_SEQ_RM_TYPE_PART = 1, // can seq_rm partial sequences
    COMMON_CONTEXT_SEQ_RM_TYPE_FULL = 2, // can seq_rm full sequences only
    COMMON_CONTEXT_SEQ_RM_TYPE_RS   = 3, // can seq_rm partial sequences, bounded by n_rs_seq
};

// 逐字抄自 common/common.h（见文件头说明，布局必须一致）。
// 漏抄字段是静默的（编译链接都不报错）：曾漏抄 `docker_repo`，使 mparams 之后的
// 字段在 common_speculative_init 眼中全部错位。字段变动必须回原头文件逐字核对。
struct common_params_model {
    std::string path        = "";
    std::string url         = "";
    std::string hf_repo     = "";
    std::string hf_file     = "";
    std::string docker_repo = "";
    std::string name        = "";
};

struct common_cpu_params {
    int      n_threads                   = -1;
    bool     cpumask[GGML_MAX_N_THREADS] = {false};
    bool     mask_valid                  = false;
    enum ggml_sched_priority  priority   = GGML_SCHED_PRIO_NORMAL;
    bool     strict_cpu                  = false;
    uint32_t poll                        = 50;
};

struct common_params_speculative_draft {
    int32_t n_max = 3;
    int32_t n_min = 0;

    float p_split = 0.1f;
    float p_min   = 0.0f;

    bool backend_sampling = true;

    common_params_model mparams;

    llama_context * ctx_tgt = nullptr;
    llama_context * ctx_dft = nullptr;

    int32_t n_gpu_layers = -1;

    ggml_type cache_type_k = GGML_TYPE_F16;
    ggml_type cache_type_v = GGML_TYPE_F16;

    common_cpu_params cpuparams;
    common_cpu_params cpuparams_batch;

    std::vector<ggml_backend_dev_t> devices;

    std::vector<llama_model_tensor_buft_override> tensor_buft_overrides;
};

struct common_params_speculative_ngram_mod {
    int32_t n_match = 24;
    int32_t n_max = 64;
    int32_t n_min = 48;
};

struct common_params_speculative_ngram_map {
    uint16_t size_n   = 12;
    uint16_t size_m   = 48;
    uint16_t min_hits = 1;
};

struct common_params_speculative_ngram_cache {
    std::string lookup_cache_static;
    std::string lookup_cache_dynamic;
};

struct common_params_speculative {
    std::vector<enum common_speculative_type> types = { COMMON_SPECULATIVE_TYPE_NONE };

    common_params_speculative_draft draft;

    common_params_speculative_ngram_mod ngram_mod;
    common_params_speculative_ngram_map ngram_simple;
    common_params_speculative_ngram_map ngram_map_k;
    common_params_speculative_ngram_map ngram_map_k4v;
    common_params_speculative_ngram_cache ngram_cache;
};

struct common_speculative;

struct common_speculative_draft_params {
    bool drafting = false;
    int32_t n_max = -1;
    llama_pos   n_past;
    llama_token id_last;
    const std::vector<llama_token> * prompt;
    std::vector<llama_token> * result;
};

common_speculative * common_speculative_init(common_params_speculative & params, uint32_t n_seq);
void common_speculative_free(common_speculative * spec);
common_speculative_draft_params & common_speculative_get_draft_params(common_speculative * spec, llama_seq_id seq_id);
void common_speculative_begin(common_speculative * spec, llama_seq_id seq_id, const std::vector<llama_token> & prompt);
bool common_speculative_process(common_speculative * spec, const llama_batch & batch);
void common_speculative_draft(common_speculative * spec);
void common_speculative_accept(common_speculative * spec, llama_seq_id seq_id, uint16_t n_accepted);

common_context_seq_rm_type common_context_can_seq_rm(llama_context * ctx);
void common_context_seq_rm(llama_context * ctx, llama_seq_id seq_id, llama_pos p0, llama_pos p1);

// ── ABI 防漂移闸门 ──────────────────────────────────────────────────────────
//
// 结构体是手抄的，字段漏抄或顺序变动不会报错，只会让 common_speculative_init
// 读到错位内存。下面的尺寸用真头文件在本机 sizeof 得到；结构体一变动这里就编译
// 失败，强制回去逐字核对。
#define MB_ABI_ASSERT(T, N) static_assert(sizeof(T) == (N), \
    "ABI 漂移: " #T " 尺寸与 common/*.h 不符，请回去逐字核对字段顺序")

MB_ABI_ASSERT(common_params_model,                 144);
MB_ABI_ASSERT(common_cpu_params,                   532);
MB_ABI_ASSERT(common_params_speculative_draft,    1312);
MB_ABI_ASSERT(common_params_speculative_ngram_mod,  12);
MB_ABI_ASSERT(common_params_speculative_ngram_map,   6);
MB_ABI_ASSERT(common_params_speculative_ngram_cache, 48);
MB_ABI_ASSERT(common_params_speculative,          1416);
MB_ABI_ASSERT(common_speculative_draft_params,      32);

#undef MB_ABI_ASSERT

namespace {

// ChatML 模板手写：GGUF 内嵌模板没有 instruct 变体的 enable_thinking=false 前缀。
// 刻意不注入默认 system prompt（会把模型带偏成用英文答中文）。详见文档 §4。

// One-shot helper for llama_token -> std::string using only public llama.h API.
// Mirrors what common_token_to_piece does, minus the std::vector roundtrip.
std::string token_to_piece_impl(const llama_vocab * vocab, llama_token token) {
    // special=true so that special tokens like <think> / </think> are rendered
    // as their text form (e.g. "<think>") instead of empty strings.  This lets
    // the Swift UI layer parse thinking blocks.  EOG tokens (<|im_end|>) never
    // reach here because is_eog is checked first in mb_mtmd_loop.
    char buf[256];
    int32_t n = llama_token_to_piece(vocab, token, buf, sizeof(buf), /*lstrip=*/0, /*special=*/true);
    if (n >= 0) {
        return std::string(buf, n);
    }
    std::vector<char> wide(static_cast<size_t>(-n));
    int32_t n2 = llama_token_to_piece(vocab, token, wide.data(), static_cast<int32_t>(wide.size()),
                                      /*lstrip=*/0, /*special=*/true);
    if (n2 < 0) {
        return std::string();
    }
    return std::string(wide.data(), static_cast<size_t>(n2));
}

// Validate whether a byte buffer forms valid UTF-8.  Mirrors the Android
// JNI is_valid_utf8() used alongside cached_token_chars.
bool is_valid_utf8(const char * str) {
    if (!str) return true;
    const auto * bytes = reinterpret_cast<const unsigned char *>(str);
    while (*bytes) {
        int num;
        if      ((*bytes & 0x80) == 0x00) num = 1;
        else if ((*bytes & 0xE0) == 0xC0) num = 2;
        else if ((*bytes & 0xF0) == 0xE0) num = 3;
        else if ((*bytes & 0xF8) == 0xF0) num = 4;
        else return false;
        bytes++;
        for (int i = 1; i < num; i++) {
            if ((*bytes & 0xC0) != 0x80) return false;
            bytes++;
        }
    }
    return true;
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
    mtmd_context_ptr    vision;       // nullptr for text-only models

    // ── DSpark 投机解码 ──
    llama_model_ptr     model_dft;    // 草稿模型
    llama_context_ptr   lctx_dft;     // 草稿 context
    void *              spec = nullptr;    // common_speculative*（类型在文件顶部的 compat 段声明）
    bool                spec_enabled = false;
    int                 spec_n_max = 0;

    /// `common_context_can_seq_rm(目标 context)` 的探测结果，在 KV 为空时探测一次后缓存。
    /// 该函数内部会 `llama_memory_clear()` 两次、清空目标 KV —— prefill 之后调会把刚
    /// 建好的 prompt KV 抹掉（表现为输出乱码），所以只能缓存、不能现调。
    /// -1 = 尚未探测；0..3 = COMMON_CONTEXT_SEQ_RM_TYPE_* 的值。
    int                 spec_rm_capable = -1;
    std::string         draft_model_path;  // 草稿模型路径（lctx 重建后要照着它重建 spec）
    std::deque<std::string> spec_out;      // 待吐出的已受理 token 片段（已经是完整 UTF-8）
    bool                spec_end_after = false; // spec_out 吐完就结束（本轮撞了 EOG）
    std::vector<llama_token> spec_prompt;  // 供 common_speculative_begin 用
    bool                spec_began = false;
    // 锚点 = 本轮送进验证批的那个「已生成」token。valid=false 时本轮从 logits 采样并
    // 吐给 UI；valid=true 时复用上一轮的 bonus token（已采样并 accept 过，不能重复吐）。
    bool                spec_anchor_valid = false;
    llama_token         spec_anchor = 0;
    // 统计
    size_t              spec_rounds = 0;
    size_t              spec_drafted = 0;
    size_t              spec_accepted = 0;

    // n_batch the lctx was actually built with (after llama_n_batch(ctx)
    // query).  We use this for both the prefill batch size and the size of
    // our llama_batch ring buffer.
    int32_t             n_batch = 2048;

    // 当前 lctx 是用什么 ub / n_ctx 建的（自适应切换时用来判断要不要重建）。
    int32_t             n_ubatch_cur = 0;
    int32_t             n_ctx_cur    = 0;
    // 启动参数显式给了 ub 时不启用自适应（基准要能钉死配置）。
    bool                ubatch_adaptive = false;

    // 重建 lctx 时要沿用同样的线程数。
    int32_t             n_threads = 4;

    // 是否启用了按层窗口（决定 ubatch 的硬上限，见 moe_ub_window_max）。
    bool                moe_window_active = false;

    // 缓存预热档位（0 = 关）。与 init 时的 apply_moe_prewarm_env 同源；这里存一份，
    // 供每轮 prefill 之前「提前读入」预热表用（见 mb_prewarm_moe_experts）。
    int                 moe_prewarm_level = 0;

    llama_batch         batch{};         // generation-loop batch (n_tokens=1)
    bool                batch_inited = false;

    const llama_vocab * vocab = nullptr; // borrowed from model

    llama_pos           n_past = 0;      // position counter for seq=0

    bool                text_only = false; // true for text-only models (no mmproj)

    int                 model_version = 46; // 26=V2.6, 40=V4.0, 46=V4.6, 47=V4.7 MoE SSD, 471=V4.7 1B (dense), 5=MiniCPM5

    bool                enable_thinking = false; // MiniCPM5 / V-4.6; default off

    std::string         experts_path;        // owned copy for llama_model_params
    std::string         pending_image_path;  // ChatML (image-in-user-turn): image is folded into the next user turn

// 选图时先做 ViT 编码，KV 写入留到发送轮。
// 一张图 ≠ 一个 chunk，所以保留有序列表按位置匹配。详见文档 §5。
    struct pending_image_cache {
        struct piece {
            int32_t            n_tokens = 0;
            std::vector<float> embd;
        };

        std::string        path;
        std::vector<piece> pieces;
        double             encode_ms = 0.0;

        bool valid() const { return !pieces.empty(); }

        int32_t total_tokens() const {
            int32_t n = 0;
            for (const auto & p : pieces) n += p.n_tokens;
            return n;
        }

        void clear() {
            path.clear();
            std::vector<piece>().swap(pieces);
            encode_ms = 0.0;
        }
    } pending_image;

    int32_t             moe_k_prefill = 0;   // 0 = not MoE; p8d8 = 8 (see MB_MOE_K_PREFILL)
    int32_t             moe_k_decode  = 0;   // 0 = not MoE; p8d8 = 8 (see MB_MOE_K_DECODE)

    // UTF-8 byte cache: BPE byte-level tokens may split multi-byte chars
    // (e.g. emoji 😊 = F0 9F 98 8A across 4 tokens). We accumulate raw
    // bytes here and only emit when the sequence forms valid UTF-8, exactly
    // matching Android's cached_token_chars + is_valid_utf8 pattern.
    std::string         cached_piece;

    std::string         last_error;

    // Per-turn prefill / decode accounting (native wall time).
    bool                perf_turn_open = false;
    int32_t             perf_prefill_tokens = 0;
    int32_t             perf_decode_tokens = 0;
    double              perf_prefill_ms = 0;
    double              perf_decode_ms = 0;
    // Send-turn prep that is NOT prefill: mmproj reload (mb_ensure_vision), image file
    // decode, mtmd_tokenize (resize + slice + canvas geometry). Counted separately so
    // the reported prefill t/s is the real llama prefill, not "everything up to decode".
    double              perf_prep_ms = 0;

    // Eager image encode, measured at image-select time (outside the turn).
    // Reported separately so prefill_ms stays "the send-turn work only".
    int32_t             perf_image_tokens = 0;
    double              perf_image_ms = 0;

    ~mb_mtmd_context() {
        // spec 持有 ctx_tgt / ctx_dft 的裸指针，必须在两个 context 之前释放。
        if (spec) {
            common_speculative_free(static_cast<common_speculative *>(spec));
            spec = nullptr;
        }
        if (batch_inited) {
            llama_batch_free(batch);
        }
        // unique_ptrs handle the rest in the right order:
        //   lctx_dft -> model_dft -> vision -> sampler -> lctx -> model
        // (mtmd_context internally borrows model; vision must die before model.)
    }
};

// ---------------------------------------------------------------------------
//  Helpers
// ---------------------------------------------------------------------------

static std::string g_last_init_error;
static std::string g_last_llama_error;

static void mb_llama_log(enum ggml_log_level level, const char * text, void * /*user_data*/) {
    if (text && *text) {
        fputs(text, stderr);
        if (level == GGML_LOG_LEVEL_ERROR) {
            g_last_llama_error = text;
            while (!g_last_llama_error.empty() &&
                   (g_last_llama_error.back() == '\n' || g_last_llama_error.back() == '\r')) {
                g_last_llama_error.pop_back();
            }
        }
        // 引擎的 MoE 诊断（`[moe-ssd] ...`）只走 stderr，而 iOS 上 app 进程的 stderr
        // 既进不了 unified log、也进不了沙盒文件 —— 真机上等于看不到。这里把这一族
        // 单独镜像进 mb_run_log.txt，其余 llama 日志不落盘（否则会被 lv4 的噪声淹没）。
        if (strstr(text, "[moe-ssd]")) {
            mb_log_raw_line(text);
        }
    }
}

static void ensure_llama_log(void) {
    static std::once_flag once;
    std::call_once(once, [] {
        llama_log_set(mb_llama_log, nullptr);
    });
}

static void set_error(mb_mtmd_context * ctx, const std::string & err) {
    g_last_init_error = err;
    if (ctx) ctx->last_error = err;
    fprintf(stderr, "[MBMtmd] %s\n", err.c_str());
    fflush(stderr);
}

const char * mb_mtmd_last_init_error(void) {
    return g_last_init_error.c_str();
}

static double now_ms() {
    using clock = std::chrono::steady_clock;
    return std::chrono::duration<double, std::milli>(clock::now().time_since_epoch()).count();
}

// Resident footprint of this process -- what jetsam actually accounts against.
// Counts the Metal-backed weights and the encoder, so it is the number to watch when
// deciding whether an eviction is close. task_info() is not cheap: call it at
// transitions (model load, encoder release), never per token. Returns -1.0 on failure.
static double footprint_mib() {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t) &info, &count) != KERN_SUCCESS) {
        return -1.0;
    }
    return static_cast<double>(info.phys_footprint) / (1024.0 * 1024.0);
}

// 一行总占用：jetsam 口径的 footprint、还能再分配多少、Metal 记账。
// 只在加载 / mmproj / park 这些拐点打，不要进 token 循环。
static void mb_log_mem(const char * where) {
    const double fp = footprint_mib();
    const double av = (double) os_proc_available_memory() / (1024.0 * 1024.0);
    double metal = -1.0;
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (dev) {
            metal = (double) dev.currentAllocatedSize / (1024.0 * 1024.0);
        }
    }
    // 走 mb_logf：NSLog（能直播抓）+ 落盘。fprintf(stderr) 在 iPhone 上进不了
    // pymobiledevice3 syslog，事后再也捞不到。
    mb_logf("[MEM] %s footprint=%.0f MiB available=%.0f MiB metal=%.0f MiB",
            where, fp, av, metal);
}

// 同上，但标签允许带参数（把 ub / n_ctx / 序号打进去，事后好对账）。
static void mb_log_mem_label(const char * fmt, ...) {
    char buf[320];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    mb_log_mem(buf);
}

// 释放后延迟复测的毫秒数（0 = 不延迟）。用来区分「驱动延迟回收」与「引用没断」。
static int mb_mem_probe_sleep_ms(void) {
    static const int v = []() -> int {
        const char * env = std::getenv("MB_MEM_PROBE_SLEEP_MS");
        if (!env || !*env) return 0;
        const int n = std::atoi(env);
        return n > 0 ? n : 0;
    }();
    return v;
}

static int clamp_lookahead_prefetch_depth(int depth) {
    if (depth < 0) return 0;
    if (depth > 16) return 16;
    return depth;
}

// 路线 A：图文整段合成一个 embedding 批次（见 eval_prefill_embd_batch），默认开启。
// 要 A/B 就在 setenv 之前把 MB_MEDIA_EMBD_BATCH 设成 0（引擎侧只读一次）。
static void apply_media_embd_batch_env(const char * where) {
    if (std::getenv("MB_MEDIA_EMBD_BATCH") == nullptr) {
        setenv("MB_MEDIA_EMBD_BATCH", "1", 1);
    }
    const char * v = std::getenv("MB_MEDIA_EMBD_BATCH");
    fprintf(stderr, "[MBMtmd] %s MB_MEDIA_EMBD_BATCH=%s\n", where, v ? v : "(null)");
}

static void apply_lookahead_prefetch_env(int depth, const char * where) {
    depth = clamp_lookahead_prefetch_depth(depth);
    char buf[8];
    snprintf(buf, sizeof(buf), "%d", depth);
    setenv("LLAMA_MOE_LOOKAHEAD_PREFETCH", depth > 0 ? "1" : "0", 1);
    setenv("LLAMA_MOE_LOOKAHEAD_PREFETCH_DEPTH", buf, 1);
    const char * on = std::getenv("LLAMA_MOE_LOOKAHEAD_PREFETCH");
    const char * d = std::getenv("LLAMA_MOE_LOOKAHEAD_PREFETCH_DEPTH");
    fprintf(stderr, "[MBMtmd] %s getenv LOOKAHEAD_PREFETCH=%s DEPTH=%s\n",
            where, on ? on : "(null)", d ? d : "(null)");
}

// mmap 默认开启（`-moeNoMmap` 退回）。剥离专家后映射区只剩非专家权重，
// 可回收；端上实测开 mmap 快 18.8%。详见文档 §6。
static bool moe_use_mmap_launch_arg(void) {
    NSArray<NSString *> * args = [[NSProcessInfo processInfo] arguments];
    return ![args containsObject:@"-moeNoMmap"];
}

// `-moeThreads N`：CPU 线程数（默认 4，设备是 6 核）。
//
// 与 `-moeIoThreads` 不同 —— 那个是引擎自己的读盘线程池，这个是 llama_context 的
// CPU 线程数（图构建、自定义 op、采样）。加它只为能扫出最优值：手拨不可复现。
static int32_t moe_threads_launch_arg(void) {
    NSArray<NSString *> * args = [[NSProcessInfo processInfo] arguments];
    NSUInteger i = [args indexOfObject:@"-moeThreads"];
    if (i == NSNotFound || i + 1 >= args.count) {
        return 0;
    }
    const int32_t v = [args[i + 1] intValue];
    return v > 0 ? v : 0;
}

// `-moeIoThreads N`：并行读盘线程数（默认 4）。现在约一半读由 RAM 提供，
// 提高并行度可能比之前（纯闪存、已饱和）更有收益。
static void apply_moe_io_threads_env(const char * where) {
    NSArray<NSString *> * args = [[NSProcessInfo processInfo] arguments];
    NSUInteger i = [args indexOfObject:@"-moeIoThreads"];
    if (i == NSNotFound || i + 1 >= args.count) {
        fprintf(stderr, "[MBMtmd] %s MOE_IO_THREADS unset (default)\n", where);
        return;
    }
    const char * v = [args[i + 1] UTF8String];
    setenv("LLAMA_MOE_IO_THREADS", v, 1);
    fprintf(stderr, "[MBMtmd] %s MOE_IO_THREADS=%s\n", where, v);
}

// `-moeNoPageCache` / `-moePhasePageCache`：experts 读取是否绕过 page cache
// （引擎侧 LLAMA_MOE_F_NOCACHE）。默认 0（不绕过，旧行为）。
// 动机：读会经 page cache，专家字节被存两份（page cache + slot 窗口），而我们从不
// 用那份 —— 纯浪费，还带来页分配/淘汰开销。
// `-moeNoPageCache` 强制绕过；`-moePhasePageCache` 交给引擎按阶段切（prefill 绕、
// decode 不绕）—— 仅在 Mac 这类快盘上实测有收益。
static void apply_moe_nocache_env(const char * where) {
    NSArray<NSString *> * args = [[NSProcessInfo processInfo] arguments];
    const char * mode = "0";
    if ([args containsObject:@"-moeNoPageCache"]) {
        mode = "1";
    } else if ([args containsObject:@"-moePhasePageCache"]) {
        mode = "auto";
    }
    setenv("LLAMA_MOE_F_NOCACHE", mode, 1);
    if (strcmp(mode, "0") != 0) {
        fprintf(stderr, "[MBMtmd] %s LLAMA_MOE_F_NOCACHE=%s\n", where, mode);
    }
}

// `-moeLogEveryStep`：每步都打引擎的 decode 归因行（默认只在 #<=8 和 %32 打）。
// 没有它，设备上只能看到前 8 步 —— 而前 8 步还在缓存爬坡，稳态 miss 根本看不到，
// 拿爬坡值比配置会得出完全错误的结论。
static void apply_moe_log_every_step_env(const char * where) {
    NSArray<NSString *> * args = [[NSProcessInfo processInfo] arguments];
    const BOOL every = [args containsObject:@"-moeLogEveryStep"];
    setenv("LLAMA_MOE_LOG_EVERY_STEP", every ? "1" : "0", 1);
    if (every) {
        fprintf(stderr, "[MBMtmd] %s LLAMA_MOE_LOG_EVERY_STEP=1\n", where);
    }
}

// 缓存预热：首 token 前把静态表读进各层窗口。唯一入口是 App 设置
// （刻意不读 env —— 会静默压过设置页）。注意 park 每轮清空窗口，所以每轮都会重新预热。
static const char * mb_prewarm_table_for_tag(const char * tag) {
    if (!tag) return nullptr;
    if (strcmp(tag, "w8")  == 0) return k_mb_prewarm_w8;
    if (strcmp(tag, "w16") == 0) return k_mb_prewarm_w16;
    if (strcmp(tag, "w32") == 0) return k_mb_prewarm_w32;
    if (strcmp(tag, "w48") == 0) return k_mb_prewarm_w48;
    if (strcmp(tag, "w64") == 0) return k_mb_prewarm_w64;
    if (strcmp(tag, "w96") == 0) return k_mb_prewarm_w96;
    if (strcmp(tag, "u8")  == 0) return k_mb_prewarm_u8;
    if (strcmp(tag, "u16") == 0) return k_mb_prewarm_u16;
    if (strcmp(tag, "u32") == 0) return k_mb_prewarm_u32;
    if (strcmp(tag, "u48") == 0) return k_mb_prewarm_u48;
    if (strcmp(tag, "u64") == 0) return k_mb_prewarm_u64;
    if (strcmp(tag, "k4t1") == 0) return k_mb_prewarm_k4t1;
    if (strcmp(tag, "k4t2") == 0) return k_mb_prewarm_k4t2;
    if (strcmp(tag, "k4t3") == 0) return k_mb_prewarm_k4t3;
    if (strcmp(tag, "k4t4") == 0) return k_mb_prewarm_k4t4;
    if (strcmp(tag, "k4b1") == 0) return k_mb_prewarm_k4b1;
    if (strcmp(tag, "k4b2") == 0) return k_mb_prewarm_k4b2;
    if (strcmp(tag, "k4b3") == 0) return k_mb_prewarm_k4b3;
    if (strcmp(tag, "k4b4") == 0) return k_mb_prewarm_k4b4;
    return nullptr;
}

/// K=4 聚类表：id -> tag。中文档见 mb_mtmd_params::moe_prewarm_table_id。
/// 1..4 = total 目标（最大化全局命中率），5..8 = bottleneck 目标（最大化最差 case）。
static const char * mb_prewarm_cluster_tag(int table_id) {
    switch (table_id) {
        case 1: return "k4t1";
        case 2: return "k4t2";
        case 3: return "k4t3";
        case 4: return "k4t4";
        case 5: return "k4b1";
        case 6: return "k4b2";
        case 7: return "k4b3";
        case 8: return "k4b4";
        default: return nullptr;
    }
}

/// 把预热档位钳到「缓存区容量 c」以内：
/// 预热写进的是**缓存区**（引擎侧 `claim_slot_in_window(..., cache_only=true)`，
/// 容量 = c，不含预读区 K）。表比缓存区大 ⇒ 认领阶段会自我淘汰（LRU 抖动）、
/// 白读 I/O，所以按窗口钳制。取不超过 window 的最大合法档位（8/16/32/48/64/96）。
static int clamp_prewarm_to_window(int level, int window) {
    if (level <= 0 || window <= 0) {
        return 0;
    }
    if (level <= window) {
        return level;
    }
    static const int kLevels[] = { 8, 16, 32, 48, 64, 96 };
    int best = 0;
    for (size_t i = 0; i < sizeof(kLevels) / sizeof(kLevels[0]); ++i) {
        if (kLevels[i] <= window && kLevels[i] <= level) {
            best = kLevels[i];
        }
    }
    return best;
}

/// 按 `keep` 条/层把表写出去（keep<=0 = 原样）。表每行是逗号分隔的专家 id；
/// `#` 开头的注释行原样保留。用于把 96 条的集群表截到当前窗口 c 能装下的条数
/// （表本身就是「每层按常用度降序」的排名，取前缀仍然有意义）。
static void mb_fwrite_prewarm_truncated(FILE * f, const char * table, int keep) {
    const char * p = table;
    while (p && *p) {
        const char * eol = strchr(p, '\n');
        const size_t len = eol ? static_cast<size_t>(eol - p) : strlen(p);
        if (keep > 0 && len > 0 && p[0] != '#') {
            int seen = 0;
            size_t cut = len;
            for (size_t i = 0; i < len; ++i) {
                if (p[i] == ',') {
                    ++seen;
                    if (seen == keep) { cut = i; break; }
                }
            }
            fwrite(p, 1, cut, f);
        } else {
            fwrite(p, 1, len, f);
        }
        fputc('\n', f);
        if (!eol) break;
        p = eol + 1;
    }
}

/// 返回**实际生效**的预热档位（0 = 关）。
///
/// `table_id` 选表（0 = 默认加权表，大小取 `level`；1..8 = K=4 集群表，96 条/层）。
/// `level <= 0` 一律关闭（设置页的「关」），跟选了什么表无关。
static int apply_moe_prewarm_env(int level, int table_id, int window, const char * where) {
    // 清掉历史遗留：别的进程/旧版本可能设过这个 env，引擎侧会读它。
    unsetenv("LLAMA_MOE_PREWARM");

    if (level <= 0) {
        mb_logf("[MBMtmd] %s prewarm: off (level=%d, window=%d)", where, level, window);
        return 0;
    }

    char tagbuf[16];
    const char * tag = nullptr;
    int table_max = 0;
    if (table_id > 0) {
        tag = mb_prewarm_cluster_tag(table_id);
        table_max = 96;
        if (!tag) {
            mb_logf("[MBMtmd] %s prewarm: 未知表 id=%d，已关闭", where, table_id);
            return 0;
        }
    } else {
        // 默认加权表：档位就是表大小，tag = w<level>。
        table_max = level;
        snprintf(tagbuf, sizeof(tagbuf), "w%d", level);
        tag = tagbuf;
    }

    const char * table = mb_prewarm_table_for_tag(tag);
    if (!table) {
        mb_logf("[MBMtmd] %s prewarm: 表 %s 无对应数据，已关闭", where, tag);
        return 0;
    }

    // 表不能超过缓存区容量 c（否则认领阶段自我淘汰、白读 I/O）。
    const int eff = clamp_prewarm_to_window(table_max, window);
    if (eff <= 0) {
        mb_logf("[MBMtmd] %s prewarm: off (表 %s 需 %d 条 > 窗口 c=%d)", where, tag, table_max, window);
        return 0;
    }
    if (eff != table_max) {
        mb_logf("[MBMtmd] %s prewarm: 表 %s 有 %d 条/层，按窗口 c=%d 截到 %d",
                where, tag, table_max, window, eff);
    }

    static char path[4096] = {0};
    @autoreleasepool {
        NSArray<NSString *> * dirs =
            NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString * dir = dirs.firstObject ?: NSTemporaryDirectory();
        NSString * name = [NSString stringWithFormat:@"moe_prewarm_%s.txt", tag];
        NSString * p = [dir stringByAppendingPathComponent:name];
        snprintf(path, sizeof(path), "%s", p.fileSystemRepresentation);
    }
    FILE * f = fopen(path, "w");
    if (!f) {
        mb_logf("[MBMtmd] %s prewarm: 写表失败 %s", where, path);
        return 0;
    }
    mb_fwrite_prewarm_truncated(f, table, eff);
    fclose(f);
    setenv("LLAMA_MOE_PREWARM", path, 1);
    mb_logf("[MBMtmd] %s prewarm: %s (%d 条/层) -> %s", where, tag, eff, path);
    return eff;
}

// `-moeDummyRead`：真读 experts 但读进 scratch，不碰 GPU 可见的 slot 缓冲区。
// 与 `-moeSkipRead` 一起构成三态，用来把「I/O」与「写 GPU 缓冲区」分开。
static void apply_moe_dummy_read_env(const char * where) {
    NSArray<NSString *> * args = [[NSProcessInfo processInfo] arguments];
    const BOOL dummy = [args containsObject:@"-moeDummyRead"];
    setenv("LLAMA_MOE_DUMMY_READ", dummy ? "1" : "0", 1);
    if (dummy) {
        fprintf(stderr, "[MBMtmd] %s LLAMA_MOE_DUMMY_READ=1\n", where);
    }
}

// `-moeReadDelayUs N`：给每次专家读加固定延迟，用于量「读时间如何传播到总时间」。
static void apply_moe_read_delay_env(const char * where) {
    NSArray<NSString *> * args = [[NSProcessInfo processInfo] arguments];
    NSUInteger i = [args indexOfObject:@"-moeReadDelayUs"];
    if (i == NSNotFound || i + 1 >= args.count) {
        return;
    }
    const char * v = [args[i + 1] UTF8String];
    setenv("LLAMA_MOE_READ_DELAY_US", v, 1);
    fprintf(stderr, "[MBMtmd] %s MOE_READ_DELAY_US=%s\n", where, v);
}

// `-moeMatmulSplit K`：把 MoE 的 n_expert_used 切成 [0,8-K) 立即提交、[8-K,8) 把
// 读盘延后到前一段算完之后（K 是延后的名次个数，不是先算的个数），只为与读重叠。
// 默认 0（关闭）。端上实测为负收益：只挪读的时间、不省读的量，分段开销吃掉全部收益。
static constexpr int MB_MOE_MATMUL_SPLIT_DEFAULT = 0;

static void apply_moe_matmul_split_env(const char * where) {
    NSArray<NSString *> * args = [[NSProcessInfo processInfo] arguments];
    NSUInteger i = [args indexOfObject:@"-moeMatmulSplit"];
    const char * v = nullptr;
    if (i != NSNotFound && i + 1 < args.count) {
        v = [args[i + 1] UTF8String];
    } else if (MB_MOE_MATMUL_SPLIT_DEFAULT > 0) {
        static char buf[8];
        snprintf(buf, sizeof(buf), "%d", MB_MOE_MATMUL_SPLIT_DEFAULT);
        v = buf;
    }
    if (!v) {
        return;
    }
    setenv("LLAMA_MOE_MATMUL_SPLIT", v, 1);
    fprintf(stderr, "[MBMtmd] %s MOE_MATMUL_SPLIT=%s%s\n", where, v,
            i != NSNotFound ? " (启动参数)" : " (编译期默认)");
}

// `-moeSkipRead`：诊断用 —— 走完全部记账但不真读盘，用来把「I/O」和
// 「40 次 GPU/CPU 往返 + 调度」的成本分开。输出会是错的，只看时间。
static void apply_moe_skip_read_env(const char * where) {
    NSArray<NSString *> * args = [[NSProcessInfo processInfo] arguments];
    const BOOL skip = [args containsObject:@"-moeSkipRead"];
    setenv("LLAMA_MOE_SKIP_READ", skip ? "1" : "0", 1);
    fprintf(stderr, "[MBMtmd] %s LLAMA_MOE_SKIP_READ=%d\n", where, skip ? 1 : 0);
}

// `-moeNoOwnAlloc`：让 MoE 专家张量退回「和非专家权重共用一个 buffer」的旧行为，
// 供同会话 A/B 用（该判断在引擎侧读环境变量 LLAMA_MOE_NO_OWN_ALLOC，进程内只读一次）。
static void apply_moe_own_alloc_env(const char * where) {
    NSArray<NSString *> * args = [[NSProcessInfo processInfo] arguments];
    const BOOL disable = [args containsObject:@"-moeNoOwnAlloc"];
    setenv("LLAMA_MOE_NO_OWN_ALLOC", disable ? "1" : "0", 1);
    fprintf(stderr, "[MBMtmd] %s LLAMA_MOE_NO_OWN_ALLOC=%d\n", where, disable ? 1 : 0);
}

// 每层 decode 窗口宽度（slot 数）。走启动参数而不是环境变量：真机上没有别的
// 办法把 env 传进 App，而 devicectl 的 `-moeXxx` 启动参数可以。
//
// 必须在**模型加载前**设好：模型侧按它建张量布局（见 qwen35moe 里的
// base / prefill view / decode view 布局），运行时绑定时再读同一个值。
static void apply_moe_layer_windows_env(const char * where) {
    // 按层窗口宽度：`-moeLayerWindows 0:176,1:80`（层:缓存区宽度，逗号分隔）。
    // 未列出的层沿用 LLAMA_MOE_DECODE_WINDOW。总量与均匀分配一致时才是公平对照 ——
    // 配置由 runs-m4max-private/plan_layer_windows.py 离线算出。
    NSArray<NSString *> * args = [[NSProcessInfo processInfo] arguments];
    NSUInteger i = [args indexOfObject:@"-moeLayerWindows"];
    if (i == NSNotFound || i + 1 >= args.count) {
        fprintf(stderr, "[MBMtmd] %s MOE_LAYER_WINDOWS unset (均匀窗口)\n", where);
        return;
    }
    const char * v = [args[i + 1] UTF8String];
    setenv("LLAMA_MOE_LAYER_WINDOWS", v, 1);
    fprintf(stderr, "[MBMtmd] %s MOE_LAYER_WINDOWS=%s (启动参数)\n", where, v);
}

static void apply_moe_decode_window_env(int param_slots, const char * where) {
    // 优先级：启动参数（实验用）> MTMDParams 里 app 算出的值 > 不启用。
    NSArray<NSString *> * args = [[NSProcessInfo processInfo] arguments];
    NSUInteger i = [args indexOfObject:@"-moeDecodeWindow"];
    if (i != NSNotFound && i + 1 < args.count) {
        const char * v = [args[i + 1] UTF8String];
        setenv("LLAMA_MOE_DECODE_WINDOW", v, 1);
        fprintf(stderr, "[MBMtmd] %s MOE_DECODE_WINDOW=%s (启动参数)\n", where, v);
        return;
    }
    if (param_slots > 0) {
        char buf[16];
        snprintf(buf, sizeof(buf), "%d", param_slots);
        setenv("LLAMA_MOE_DECODE_WINDOW", buf, 1);
        fprintf(stderr, "[MBMtmd] %s MOE_DECODE_WINDOW=%s (按可用内存自动)\n", where, buf);
        return;
    }
    // 显式写 0：同进程里先开过窗口再改成关，必须覆盖掉旧的环境变量。
    setenv("LLAMA_MOE_DECODE_WINDOW", "0", 1);
    fprintf(stderr, "[MBMtmd] %s MOE_DECODE_WINDOW=0 (无按层缓存)\n", where);
}

// DSpark: 每层 decode 窗口要覆盖的批宽（行数），必须在目标模型加载前设好（模型侧按它
// 建每层张量布局，见 llama-moe-slot.cpp 的 resolve_decode_window）。默认只服务单 token
// decode，投机验证批宽 = n_max+1，不设就会掉出窗口（Mac 上 n_max=7 从 10.32 掉到 4.63）。
// 设大不等于一定生效：引擎会按缓存区容量夹紧，装不下时退到更小的行数（不会崩）。
static int apply_spec_moe_window_env(int n_max, const char * where) {
    char buf[16];
    snprintf(buf, sizeof(buf), "%d", n_max + 1);
    setenv("LLAMA_MOE_WINDOW_MAX_ROWS", buf, 1);
    const char * v = std::getenv("LLAMA_MOE_WINDOW_MAX_ROWS");
    fprintf(stderr, "[MBMtmd] %s LLAMA_MOE_WINDOW_MAX_ROWS=%s (投机批宽 n_max+1)\n",
            where, v ? v : "(null)");
    fflush(stderr);
    return v ? atoi(v) : 0;
}

static double tok_per_sec(int32_t n, double ms) {
    return (n > 0 && ms > 0.0) ? (1000.0 * (double) n / ms) : 0.0;
}

static void perf_begin_turn_if_needed(mb_mtmd_context * ctx) {
    if (!ctx || ctx->perf_turn_open) return;
    ctx->perf_prefill_tokens = 0;
    ctx->perf_decode_tokens = 0;
    ctx->perf_prefill_ms = 0;
    ctx->perf_decode_ms = 0;
    ctx->perf_turn_open = true;
}

// ChatML + Qwen3-style template (shared by Qwen3.6 and the 35a3_hf_v47 text
// tower): thinking is ON unless enable_thinking=false, which injects an empty
// <think> block. Default-on is why a missing suffix looks like a slow decode —
// the model is writing a chain of thought first.
static const char * chatml_nothink_header() {
    return "<|im_start|>assistant\n<think>\n\n</think>\n\n";
}

// 36 = Qwen3.6 MoE, 47 = MiniCPM-V 4.7 MoE SSD. Both use the ChatML template
// above and both fold the image into the next user turn.
static inline bool is_chatml_moe(int model_version) {
    return model_version == 36 || model_version == 47;
}

// ChatML templates that fold the image INTO the user turn, i.e. the
// `<__media__>` marker must sit inside `<|im_start|>user\n … <|im_end|>`.
// 36/47 are the MoE SSD variants; **471 = MiniCPM-V 4.7 1B** — dense Qwen3.5 with
// the *4.7* chat template, so it needs the same turn structure, but it has no SSD
// expert window (no experts, no FFN experts), hence it must stay OUT of
// is_chatml_moe(), which gates the MoE prewarm path.
static inline bool is_chatml_image_deferred(int model_version) {
    return model_version == 36 || model_version == 47 || model_version == 471;
}

// 记 prefill。**n_tokens 必须是真正送进图里的 token 数**，不是 n_past 增量 ——
// 图片 chunk 走 canvas 后 n_pos = 1（整图共用 canvas 原点），但实际有几百个 token
// 参与计算。之前按 n_past 增量算，带图时把分母压到个位数，P t/s 会低到 5 t/s
// （实际是 50~70）。文本路径两者相等，所以只在带图时暴露。
static void perf_add_prefill(mb_mtmd_context * ctx, int32_t n_tokens, double t0_ms) {
    if (!ctx) return;
    perf_begin_turn_if_needed(ctx);
    if (n_tokens > 0) ctx->perf_prefill_tokens += n_tokens;
    ctx->perf_prefill_ms += std::max(0.0, now_ms() - t0_ms);
}

// 非 prefill 的准备耗时（见 ctx->perf_prep_ms 的说明）。单独记，不混进 prefill_ms。
static void perf_add_prep(mb_mtmd_context * ctx, double ms) {
    if (!ctx) return;
    perf_begin_turn_if_needed(ctx);
    ctx->perf_prep_ms += std::max(0.0, ms);
}

static constexpr int MB_MOE_EXPERTS_USED = 8;
static constexpr int MB_MOE_EXPERT_COUNT = 256;
// p8d8 (top-8 for both prefill and decode) is the only precision-safe default:
// the experts and the checkpoint are trained at K=8, and lowering K changes the
// sampled trajectory. p4d4 is a speed/precision trade that measured ~1.6x on Mac
// but is NOT free -- see logs/newmodel_v47/quality/ANALYSIS.md (K=4 is the floor;
// K=2 is unusable on device). Do not lower these without an explicit decision.
static constexpr int MB_MOE_K_PREFILL = 8;
static constexpr int MB_MOE_K_DECODE  = 8;

// MoE decode trace probe: NOT available on this branch.
//
// Upstream's App variant turns on LLAMA_MOE_LAYER_TRACE so the framework prints one
// `[moe-ssd] layertrace ...` line per layer plus a `layertrace-sum` per token, which is
// what made the install / gpu_gap / tail split readable. That probe was deliberately left
// out of this llama.cpp-omni tree, so setting those env vars here would be a no-op.
// Per-step speed is read from the in-app overlay instead (see MTMDWrapper.showPerfSpeedInToolbar).

// Experts stays at training K=8. Runtime top-k is cparams only — do not
// override GGUF / manifest expert_used_count.
// With p8d8 the runtime K equals hparams' expert_used_count, so apply_moe_k is
// a no-op for the lifetime of the context.
static void apply_moe_k(mb_mtmd_context * ctx, int32_t k) {
    if (!ctx || !ctx->lctx || ctx->experts_path.empty() || k <= 0) {
        return;
    }
    const int32_t cur = llama_n_expert_used(ctx->lctx.get());
    if (cur == k) {
        return;
    }
    llama_set_n_expert_used(ctx->lctx.get(), k);
    fprintf(stderr, "[MBMtmd] moe_k %d -> %d\n", cur, llama_n_expert_used(ctx->lctx.get()));
}

// Adapter for the older mtmd shipped by this engine branch.
//
// The iOS wrapper is written against upstream's newer helper API, where
// mtmd_helper_bitmap_init_from_file() takes (ctx, path, placeholder, opt) and returns a
// `mtmd_helper_bitmap_wrapper` (bitmap + video stream). This branch's mtmd still has the
// two-argument form returning a bare mtmd_bitmap*, and no video at all. Keep the call
// sites below on the newer shape through this shim so the two App variants stay diffable.
static mtmd_bitmap * mb_bitmap_from_file(const mtmd_context * ctx, const char * image_path) {
    return mtmd_helper_bitmap_init_from_file(const_cast<mtmd_context *>(ctx), image_path);
}

// ── mmproj (ViT) release / reload ──
// 图像 embedding 进 KV 后释放 ViT，下次再来图才重载：mmproj ~1 GiB 否则会空占整个生成期。
// 注意：卸载不改变加载期峰值，reserve 里的 mmproj 预留不能省。详见文档 §8。
static constexpr bool MB_MOE_UNLOAD_MMPROJ_AFTER_PREFILL = true;

static bool mb_unload_mmproj_enabled() {
    static const bool on = []() {
        const char * env = std::getenv("MB_MOE_UNLOAD_MMPROJ");
        return env ? (env[0] != '\0' && env[0] != '0') : MB_MOE_UNLOAD_MMPROJ_AFTER_PREFILL;
    }();
    return on;
}

// DSpark 的建/拆，定义在下面（spec_create / spec_teardown）：mmproj 的卸载/重载
// 要驱动投机器的生命周期，所以这里先声明。
static void spec_create(mb_mtmd_context * ctx);
static void spec_teardown(mb_mtmd_context * ctx, bool drop_draft_model);

// Returns true if this call released the encoder.
static bool mb_release_vision(mb_mtmd_context * ctx, const char * where) {
    if (!mb_unload_mmproj_enabled()) {
        return false;
    }
    if (!ctx || !ctx->vision || !mtmd_vision_loaded(ctx->vision.get())) {
        return false;
    }
    const double before = footprint_mib();
    if (!mtmd_vision_unload(ctx->vision.get())) {
        return false;
    }
    const double after = footprint_mib();
    mb_logf("[MBMtmd] mmproj released after %s: footprint %.0f -> %.0f MiB (freed %.0f MiB)",
            where, before, after, before - after);
    mb_log_mem("after mmproj release");
    return true;
}

// Counterpart to mb_release_vision(). No-op while the encoder is already resident, or for
// text-only models. Returns false only when a needed reload failed.
static bool mb_ensure_vision(mb_mtmd_context * ctx, const char * where) {
    if (!ctx || !ctx->vision || mtmd_vision_loaded(ctx->vision.get()) || ctx->text_only) {
        return true;
    }
    const double before = footprint_mib();
    const double t0 = now_ms();
    if (!mtmd_vision_reload(ctx->vision.get())) {
        set_error(ctx, std::string("failed to reload mmproj for ") + where);
        return false;
    }
    const double after = footprint_mib();
    mb_logf("[MBMtmd] mmproj reloaded for %s in %.0f ms: footprint %.0f -> %.0f MiB (+%.0f MiB)",
            where, now_ms() - t0, before, after, after - before);
    mb_log_mem("after mmproj reload");
    return true;
}

static void mb_park_moe_expert_memory(mb_mtmd_context * ctx, const char * where) {
    if (!ctx || !ctx->lctx) {
        return;
    }
    mb_logf("[MBMtmd] park moe expert memory (%s)", where);
    llama_moe_park_expert_memory(ctx->lctx.get());
    mb_log_mem("after park expert window");
}

// 预热时机（关键，别挪）：mmproj 已卸载、ubatch 重建已完成、用户内容还没评估。
// 此时读盘不挤内存、也不在首 token 关键路径上（引擎侧只「重挂」映射，零 I/O）。
static void mb_prewarm_moe_experts(mb_mtmd_context * ctx, const char * where) {
    if (!ctx || !ctx->lctx || ctx->moe_prewarm_level <= 0) {
        return;
    }
    const double t0 = now_ms();
    mb_logf("[MBMtmd] prewarm experts (%s, level=%d)", where, ctx->moe_prewarm_level);
    llama_moe_prewarm_experts(ctx->lctx.get());
    mb_logf("[MBMtmd] prewarm experts done (%s) in %.0f ms", where, now_ms() - t0);
    mb_log_mem("after prewarm experts");
}

static bool moe_adaptive_ubatch(mb_mtmd_context * ctx, bool has_image, int n_tokens);

// 文本 chunk 求值：helper 的等价复刻，外加把每批喂给草稿侧。
// 必须复刻的原因是 helper 把 batch 藏在内部，DSpark 拿不到中间层特征。详见文档 §14。
static int32_t eval_text_chunk_feed_draft(mb_mtmd_context * ctx,
                                          const mtmd_input_chunk * chunk,
                                          llama_pos n_past,
                                          llama_seq_id seq_id,
                                          int32_t n_batch,
                                          bool logits_last,
                                          llama_pos * new_n_past) {
    size_t n_tokens = 0;
    const llama_token * tokens = mtmd_input_chunk_get_tokens_text(chunk, &n_tokens);
    if (!tokens) {
        return -1;
    }

    llama_batch batch = llama_batch_init(n_batch, /*embd=*/0, /*n_seq_max=*/1);
    if (!batch.token) {
        return -1;
    }

    size_t i = 0;
    while (i < n_tokens) {
        batch.n_tokens = 0;
        for (; i < n_tokens && batch.n_tokens < n_batch; i++) {
            const int32_t j = batch.n_tokens;
            batch.token[j]     = tokens[i];
            batch.pos[j]       = n_past++;
            batch.n_seq_id[j]  = 1;
            batch.seq_id[j][0] = seq_id;
            batch.logits[j]    = false;
            batch.n_tokens++;
        }

        const bool is_last_token = (i == n_tokens);
        if (logits_last && is_last_token) {
            batch.logits[batch.n_tokens - 1] = true;
        }

        if (llama_decode(ctx->lctx.get(), batch) != 0) {
            fprintf(stderr, "[MBMtmd] prefill: llama_decode(text chunk) failed\n");
            fflush(stderr);
            llama_batch_free(batch);
            return -1;
        }

        // 必须在 decode 之后、下一批 decode 之前 —— 否则 layer_inp 已被下一批覆盖。
        if (ctx->spec_enabled && ctx->spec) {
            for (int32_t j = 0; j < batch.n_tokens; ++j) {
                ctx->spec_prompt.push_back(batch.token[j]);
            }
            if (!common_speculative_process(static_cast<common_speculative *>(ctx->spec), batch)) {
                fprintf(stderr, "[MBMtmd] common_speculative_process() failed during prefill "
                                "(text chunk); drafts may degrade\n");
                fflush(stderr);
            }
        }

        *new_n_past += batch.n_tokens;
    }

    llama_batch_free(batch);
    return 0;
}

// ── 整段 embedding 批次（MB_MEDIA_EMBD_BATCH=1）──
// 目的：让文本 + 全部图像切片进同一个前向（当前是逐片解码，每 token 读盘 ~8 倍）。
// 返回 0=已接管 / -1=已接管但失败 / 1=未接管。详见文档 §15。
static int eval_prefill_embd_batch(mb_mtmd_context * ctx,
                                   const mtmd_input_chunks * chunks,
                                   bool logits_last,
                                   llama_pos * new_n_past) {
    static const bool enabled = [] {
        const char * e = getenv("MB_MEDIA_EMBD_BATCH");
        return e && *e && *e != '0';
    }();
    if (!enabled || !ctx->vision) {
        return 1;
    }
    // 先不碰投机链路：文本 chunk 在开投机时要逐批喂给草稿侧（eval_text_chunk_feed_draft），
    // 合成一个大批次会改变那条链路的行为。要开请先单独验证草稿受理率。
    if (ctx->spec_enabled) {
        return 1;
    }
    const size_t n_chunks = mtmd_input_chunks_size(chunks);
    if (n_chunks == 0) {
        return 1;
    }

    const llama_model * model = llama_get_model(ctx->lctx.get());
    const int32_t n_embd = llama_model_n_embd(model);
    if (n_embd <= 0) {
        return 1;
    }
    const bool mrope = mtmd_decode_use_mrope(ctx->vision.get()) != 0;
    const int32_t n_pos = mrope ? 4 : 1;

    size_t total = 0;
    for (size_t i = 0; i < n_chunks; ++i) {
        const mtmd_input_chunk * c = mtmd_input_chunks_get(chunks, i);
        if (!c) {
            return 1;
        }
        total += (size_t) mtmd_input_chunk_get_n_tokens(c);
    }
    // 必须整段落进**一次** decode：embedding 路径的位置是 section-major
    // （步长 = 总 token 数），跨切片没法按偏移切。
    if (total == 0 || total > (size_t) ctx->n_batch) {
        return 1;
    }

    std::vector<float>        embd(total * (size_t) n_embd);
    std::vector<llama_pos>    pos(total * (size_t) n_pos);
    std::vector<int32_t>      n_seq_id(total, 1);
    std::vector<llama_seq_id> seq_store(total, 0);
    std::vector<llama_seq_id *> seq_id(total);
    std::vector<int8_t>       logits(total, 0);
    for (size_t i = 0; i < total; ++i) {
        seq_id[i] = &seq_store[i];
    }
    if (logits_last) {
        logits[total - 1] = 1;
    }

    const bool eager_ok = ctx->pending_image.valid();
    llama_pos p = ctx->n_past;
    size_t off = 0;
    size_t image_index = 0;

    for (size_t i = 0; i < n_chunks; ++i) {
        const mtmd_input_chunk * chunk = mtmd_input_chunks_get(chunks, i);
        const mtmd_input_chunk_type type = mtmd_input_chunk_get_type(chunk);
        const size_t n_tok = (size_t) mtmd_input_chunk_get_n_tokens(chunk);

        if (type == MTMD_INPUT_CHUNK_TYPE_TEXT) {
            size_t n_text = 0;
            const llama_token * toks = mtmd_input_chunk_get_tokens_text(chunk, &n_text);
            if (!toks || n_text != n_tok) {
                return 1;
            }
            if (llama_model_token_embd(model, toks, (int32_t) n_text,
                                       embd.data() + off * (size_t) n_embd) != 0) {
                set_error(ctx, "embd-batch: llama_model_token_embd failed");
                return -1;
            }
            for (size_t k = 0; k < n_text; ++k) {
                pos[off + k]                   = p + (llama_pos) k;
                pos[off + k + total]           = p + (llama_pos) k;
                pos[off + k + 2 * total]       = p + (llama_pos) k;
                pos[off + k + 3 * total]       = 0; // 与 token 路径一致：第 4 维填 0
            }
            p += (llama_pos) n_text;
            off += n_text;
            continue;
        }

        if (type != MTMD_INPUT_CHUNK_TYPE_IMAGE) {
            return 1; // 音频等暂不支持
        }

        // 图像：优先用选图时算好的 eager 嵌入（按位置匹配，与下面 reuse 判据一致）
        const auto * piece = (image_index < ctx->pending_image.pieces.size() &&
                              ctx->pending_image.pieces[image_index].n_tokens == (int32_t) n_tok)
            ? &ctx->pending_image.pieces[image_index] : nullptr;
        if (piece && piece->embd.size() == n_tok * (size_t) n_embd) {
            std::memcpy(embd.data() + off * (size_t) n_embd,
                        piece->embd.data(), piece->embd.size() * sizeof(float));
        } else {
            // 现编码：这条真的要用 CLIP 权重
            if (!mb_ensure_vision(ctx, "eval_prefill_embd_batch (inline image encode)")) {
                return -1;
            }
            if (mtmd_encode_chunk(ctx->vision.get(), chunk) != 0) {
                set_error(ctx, "embd-batch: mtmd_encode_chunk failed");
                return -1;
            }
            const float * src = mtmd_get_output_embd(ctx->vision.get());
            if (!src) {
                set_error(ctx, "embd-batch: null vision output");
                return -1;
            }
            std::memcpy(embd.data() + off * (size_t) n_embd,
                        src, n_tok * (size_t) n_embd * sizeof(float));
        }

        const mtmd_image_tokens * it = mtmd_input_chunk_get_tokens_image(chunk);
        std::vector<mtmd_decoder_pos> rel(n_tok);
        mtmd_helper_image_get_decoder_pos(it, p, rel.data());
        for (size_t k = 0; k < n_tok; ++k) {
            pos[off + k]             = rel[k].t;
            pos[off + k + total]     = rel[k].y;
            pos[off + k + 2 * total] = rel[k].x;
            pos[off + k + 3 * total] = rel[k].z;
        }
        p += mtmd_input_chunk_get_n_pos(chunk);
        off += n_tok;
        image_index++;
    }

    if (off != total) {
        return 1;
    }

    llama_batch batch = {
        /*n_tokens =*/ (int32_t) total,
        /*token    =*/ nullptr,
        /*embd     =*/ embd.data(),
        /*pos      =*/ pos.data(),
        /*n_seq_id =*/ n_seq_id.data(),
        /*seq_id   =*/ seq_id.data(),
        /*logits   =*/ logits.data(),
    };

    const int64_t t0 = ggml_time_ms();
    if (llama_decode(ctx->lctx.get(), batch) != 0) {
        set_error(ctx, "embd-batch: llama_decode failed");
        return -1;
    }
    fprintf(stderr, "[MBMtmd] embd-batch: %zu token 合成一个 embedding 批次（%s，%lld ms）\n",
            total, mrope ? "M-RoPE" : "1D", (long long) (ggml_time_ms() - t0));

    // 与逐 chunk 路径同样的收尾：一次性，不留陈旧嵌入给下一轮
    ctx->pending_image.clear();
    *new_n_past = p;
    return 0;
}

static int eval_prefill(mb_mtmd_context * ctx,
                        const mtmd_input_chunks * chunks,
                        bool logits_last,
                        llama_pos * new_n_past) {
    // 自适应 ubatch：这里拿不到总 token 数（由 mtmd 内部按 chunk 切），
    // 所以只按「本轮是否带图」判断 —— 图像通常上千 token，必须走大 ub。
    //
    // 重建前先放掉视觉塔（本轮图已 eager 编码时）：下面图像 chunk 走
    // mtmd_helper_decode_image_chunk()，只把预编码的嵌入注进 KV、不做 CLIP 前向，
    // 而重建 llama_context 的 compute buffer 会和常驻 mmproj 叠加到 OOM 点。
    const bool eager_ok = ctx->pending_image.valid();
    if (eager_ok) {
        // 图像轮通常已在选图（mb_mtmd_prewarm_after_image）时就放掉了视觉塔并预热好，
        // 这里多为 no-op；保留作为兜底（例如非 chatml 路径或没走选图）。
        mb_release_vision(ctx, "before ubatch rebuild (eager embedding cached)");
    }
    moe_adaptive_ubatch(ctx, eager_ok, /*n_tokens=*/0);

    // 注意：这里**不再**预热。预热挪到了选图之后（mb_mtmd_prewarm_after_image）、
    // 发送之前，那样那笔读盘落在用户打字的空闲期，既不阻塞首 token，也不进
    // App 的「预处理耗时」（预热与编码是两次独立调用，见 mb_mtmd_prewarm_after_image）。
    // 取舍：纯文本轮不做预热（没有选图这个钩子，且没有图像时首 token 的 miss 本来也少）。

    apply_moe_k(ctx, ctx->moe_k_prefill > 0 ? ctx->moe_k_prefill : MB_MOE_K_PREFILL);

    // 路线 A：图文整段合成一个 embedding 批次一次 decode —— 必须在自适应 ubatch 之后，
    // 因为它可能重建 context，批宽要以重建后的为准。
    {
        const int er = eval_prefill_embd_batch(ctx, chunks, logits_last, new_n_past);
        if (er == 0) {
            return 0;
        }
        if (er < 0) {
            return -1;
        }
        // er > 0：未接管，走下面的逐 chunk 原路径
    }

    const size_t n_chunks = mtmd_input_chunks_size(chunks);

    // Text chunks never touch the CLIP context (mtmd_helper_eval_chunk_single() only looks
    // at the chunk type), so only a turn that actually carries an image needs the ViT back.
    // Reloading for text turns would defeat mb_release_vision() entirely.
    // 真正要用 CLIP 的只有下面「现编码」那条分支。

    llama_pos n_past = ctx->n_past;
    int32_t res = 0;
    size_t image_index = 0;

    for (size_t i = 0; i < n_chunks && res == 0; i++) {
        const bool chunk_logits_last = (i == n_chunks - 1) && logits_last;
        const mtmd_input_chunk * chunk = mtmd_input_chunks_get(chunks, i);
        if (!chunk) {
            res = -1;
            break;
        }

        const bool is_image = mtmd_input_chunk_get_type(chunk) == MTMD_INPUT_CHUNK_TYPE_IMAGE;
        if (!is_image) {
            // 投机开着时走本地版本：它把每个文本 batch 都喂给草稿侧，这是 App（多模态）
            // 路径上唯一能让草稿拿到 prompt 特征的地方；关掉投机关或非文本 chunk 走原 helper。
            const bool is_text = mtmd_input_chunk_get_type(chunk) == MTMD_INPUT_CHUNK_TYPE_TEXT;
            if (is_text && ctx->spec_enabled && ctx->spec) {
                res = eval_text_chunk_feed_draft(
                    ctx, chunk, n_past, /*seq_id=*/0, ctx->n_batch, chunk_logits_last, &n_past);
            } else {
                res = mtmd_helper_eval_chunk_single(
                    ctx->vision.get(), ctx->lctx.get(), chunk,
                    n_past, /*seq_id=*/0, ctx->n_batch, chunk_logits_last, &n_past);
            }
            continue;
        }

        // One image = one chunk per piece (overview + slices), so the eager
        // cache is matched positionally, not by size.
        const int32_t n_tok = static_cast<int32_t>(mtmd_input_chunk_get_n_tokens(chunk));
        const bool reuse = image_index < ctx->pending_image.pieces.size() &&
            ctx->pending_image.pieces[image_index].n_tokens == n_tok;

        if (reuse) {
            auto & piece = ctx->pending_image.pieces[image_index];
            res = mtmd_helper_decode_image_chunk(
                ctx->vision.get(), ctx->lctx.get(), chunk,
                piece.embd.data(), n_past, /*seq_id=*/0,
                ctx->n_batch, &n_past);
            if (res == 0) {
                fprintf(stderr, "[MBMtmd] image chunk %zu: reused eager embedding (%d tok)\n",
                        image_index, n_tok);
            }
        } else {
            // 现编码：这条才真的要用 CLIP 权重（视觉塔可能已被放掉），确保动作在这里做。
            if (!mb_ensure_vision(ctx, "eval_prefill (inline image encode)")) {
                return -1;
            }
            if (ctx->pending_image.valid()) {
                // Should not happen: same bitmap, same ctx, same slice settings.
                // Say so, because a silent mismatch here would be a real bug.
                const int32_t had = image_index < ctx->pending_image.pieces.size()
                    ? ctx->pending_image.pieces[image_index].n_tokens : -1;
                fprintf(stderr,
                        "[MBMtmd] image chunk %zu: eager had %d tok, now %d — encoding inline\n",
                        image_index, had, n_tok);
            }
            res = mtmd_helper_eval_chunk_single(
                ctx->vision.get(), ctx->lctx.get(), chunk,
                n_past, /*seq_id=*/0, ctx->n_batch, chunk_logits_last, &n_past);
        }
        image_index++;
    }

    // One-shot: never let a stale embedding leak into the next turn.
    ctx->pending_image.clear();

    if (res != 0) {
        return res;
    }
    *new_n_past = n_past;
    return 0;
}

// ---------------------------------------------------------------------------
//  Public C API
// ---------------------------------------------------------------------------

mb_mtmd_params mb_mtmd_params_default(void) {
    mb_mtmd_params p = {};
    p.n_predict             = -1;
    p.n_ctx                 = 4096;
    p.n_ubatch              = 0;       // 0 = pick MB_DEFAULT_N_UBATCH below
    p.n_threads             = 4;
    p.temperature           = 0.7f;     // 0 = 贪心（可用 MB_TEMP=0 覆盖）
    p.use_gpu               = true;
    p.mmproj_use_gpu        = true;
    p.warmup                = true;
    p.image_max_tokens      = -1;
    p.image_max_slice_nums  = -1;
    p.moe_slot_bank         = 0;
    p.moe_lookahead_prefetch_depth        = 0;
    p.moe_prewarm_level     = 0;       // 0 = 预热关闭（App 会按设置传 8/16/32/48/64/96）
    p.moe_prewarm_table_id  = 0;       // 0 = 默认加权表；1..8 = K=4 集群表
    p.spec_draft_n_max      = 0;       // 0 = DSpark 投机关闭（默认行为与旧版一致）
    return p;
}

// 未指定 n_ubatch 时的默认。iOS 层会按设备覆盖（MBDeviceMemoryProbe）。
static constexpr int MB_DEFAULT_N_UBATCH = 512;

// 自适应 ubatch：选能一次装下整个 prompt 的最小档（仅 MoE-SSD 路径，未钉 -moeUbatch 时）。
// 核心原则「不切段」—— 切段要重读整批专家；但小 ub 的短上下文 decode 快 ~22%。
// 阶梯取 {128,256,512,1024,2048}。详见文档 §9。
static constexpr int MB_MOE_UB_LADDER[] = { 128, 256, 512, 1024, 2048 };

// 窗口启用时 ubatch 的硬上限：slot bank 与 compute buffer 共用 GPU 内存，
// 不封顶会长 prompt 直接 OOM 崩。不能用 os_proc_available_memory() 判断（窗口尚未记账）。
// 上限 1024，`-moeUbMax <n>` 可扫边界。详见文档 §9.3。
static int32_t moe_ub_window_max() {
    static const int32_t v = []() -> int32_t {
        NSArray<NSString *> * args = [[NSProcessInfo processInfo] arguments];
        const NSUInteger i = [args indexOfObject:@"-moeUbMax"];
        if (i != NSNotFound && i + 1 < args.count) {
            const int n = [args[i + 1] intValue];
            if (n > 0) {
                fprintf(stderr, "[MBMtmd] ub window max = %d (from -moeUbMax)\n", n);
                fflush(stderr);
                return n;
            }
        }
        return 1024;
    }();
    return v;
}

// 按「本次要 prefill 的 token 数」挑档位。带图时拿不到 token 数（由 mtmd 内部切
// chunk），图像通常上千 token，直接用最大档。// 按「本次要 prefill 的 token 数」挑档位。带图时拿不到 token 数（由 mtmd 内部切
// chunk），图像通常上千 token，直接用最大档。
static int32_t moe_ub_for_tokens(bool has_image, int n_tokens) {
    const int n = static_cast<int>(sizeof(MB_MOE_UB_LADDER) / sizeof(MB_MOE_UB_LADDER[0]));
    if (!has_image) {
        for (int i = 0; i < n; ++i) {
            if (n_tokens <= MB_MOE_UB_LADDER[i]) {
                return MB_MOE_UB_LADDER[i];
            }
        }
    }
    return MB_MOE_UB_LADDER[n - 1];
}

// 用户显式钉了 ub（基准/实验）就不自适应。
static bool moe_ubatch_pinned(void) {
    NSArray<NSString *> * args = [[NSProcessInfo processInfo] arguments];
    return [args containsObject:@"-moeUbatch"];
}

// ---------------------------------------------------------------------------
//  DSpark 投机解码 helpers
// ---------------------------------------------------------------------------

// 释放投机解码器（可选连草稿模型/context 一起放掉）。
static void spec_teardown(mb_mtmd_context * ctx, bool drop_draft_model) {
    if (!ctx) return;
    if (ctx->spec) {
        common_speculative_free(static_cast<common_speculative *>(ctx->spec));
        ctx->spec = nullptr;
    }
    ctx->spec_enabled = false;
    // 草稿 context 每次都重建，不复用：它通过 ctx_other 绑死目标 context，而自适应
    // ubatch 会重建目标 context —— 复用会变成 use-after-free。草稿 context 很小。
    ctx->lctx_dft.reset();
    // 模型本体（425 MB）才是省得下来的那部分，按调用方要求决定是否连它一起放掉。
    if (drop_draft_model) {
        ctx->model_dft.reset();
    }
}

// 探测目标 context 的部分回滚能力，结果缓存进 ctx->spec_rm_capable。
//
// 必须在目标 context 刚建好、KV 还是空的时候调用且只调一次：common_context_can_seq_rm()
// 内部会 llama_memory_clear() 两次，prefill 之后调会把刚灌好的 prompt KV 抹掉（输出乱码）。
// 所以「探测」（这里）与「建投机器」（spec_create，可晚到 mmproj 卸载后）拆成两步。
static void spec_probe_rm_capability(mb_mtmd_context * ctx, const char * where) {
    if (!ctx || !ctx->lctx) {
        return;
    }
    ctx->spec_rm_capable = static_cast<int>(common_context_can_seq_rm(ctx->lctx.get()));
    fprintf(stderr, "[MBMtmd] spec: can_seq_rm probe = %d (%s, KV 为空时探测)\n",
            ctx->spec_rm_capable, where);
    fflush(stderr);
}

// 建立（或重建）投机解码器，指向当前的 ctx->lctx。
//
// 必须在目标 context 建好之后、首次 prefill decode 之前调用；自适应 ubatch 重建 lctx
// 之后也要再调一次（common_params_speculative 存的是裸 ctx_tgt 指针，换了 context 就悬空）。
static void spec_create(mb_mtmd_context * ctx) {
    if (!ctx || ctx->draft_model_path.empty() || ctx->spec_n_max <= 0 || !ctx->lctx) {
        return;
    }

    spec_teardown(ctx, /*drop_draft_model=*/false);

    // 1) 草稿模型：全放 GPU。
    if (!ctx->model_dft) {
        llama_model_params mparams_dft = llama_model_default_params();
        mparams_dft.n_gpu_layers = 99;
        ctx->model_dft.reset(llama_model_load_from_file(ctx->draft_model_path.c_str(), mparams_dft));
        if (!ctx->model_dft) {
            fprintf(stderr, "[MBMtmd] DSpark off: failed to load draft model '%s'\n",
                    ctx->draft_model_path.c_str());
            fflush(stderr);
            ctx->spec_n_max = 0;
            return;
        }
    }

    // 2) 草稿 context：n_ctx 跟目标一样（prompt + 验证批总要装得下），n_ubatch >= n_max+1。
    if (!ctx->lctx_dft) {
        llama_context_params cparams_dft = llama_context_default_params();
        cparams_dft.n_ctx           = static_cast<uint32_t>(std::max(2048, (int) ctx->n_ctx_cur));
        cparams_dft.n_batch         = 2048;
        cparams_dft.n_ubatch        = static_cast<uint32_t>(std::max(128, ctx->spec_n_max + 1));
        cparams_dft.n_threads       = ctx->n_threads;
        cparams_dft.n_threads_batch = ctx->n_threads;
        cparams_dft.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
        // 草稿 context 的 n_rs_seq 必须是 0：草稿是 DFLASH 架构（非循环），引擎的
        // 部分回滚 allow-list 不含它。回滚只需目标 context 支持，草稿侧由
        // common_speculative::process() 按验证批位置重写覆盖（同 server-context.cpp）。
        cparams_dft.n_rs_seq        = 0;
        // DFlash / DSpark 草稿不自带 token embedding 与 lm head，都从目标模型读，
        // 所以草稿 context 必须在目标 context 之后建（不设会直接初始化失败）。
        cparams_dft.ctx_other       = ctx->lctx.get();
        ctx->lctx_dft.reset(llama_init_from_model(ctx->model_dft.get(), cparams_dft));
        if (!ctx->lctx_dft) {
            fprintf(stderr, "[MBMtmd] DSpark off: failed to create draft context\n");
            fflush(stderr);
            ctx->model_dft.reset();
            ctx->spec_n_max = 0;
            return;
        }
    }

    // 3) common_params_speculative —— 字段与 common/common.h 一致（见文件顶部说明）。
    common_params_speculative p;
    p.types                  = { COMMON_SPECULATIVE_TYPE_DRAFT_DSPARK };
    p.draft.mparams.path     = ctx->draft_model_path;
    p.draft.ctx_tgt          = ctx->lctx.get();
    p.draft.ctx_dft          = ctx->lctx_dft.get();
    p.draft.n_max            = ctx->spec_n_max;
    p.draft.n_min            = 0;
    p.draft.p_min            = 0.0f;
    p.draft.backend_sampling = false;   // App 不用 backend sampler

    ctx->spec = common_speculative_init(p, /*n_seq=*/1);
    if (!ctx->spec) {
        fprintf(stderr, "[MBMtmd] DSpark off: common_speculative_init returned null\n");
        fflush(stderr);
        ctx->spec_n_max = 0;
        return;
    }

    // 4) 校验部分回滚能力：只有 RS / PART 才能直接 seq_rm 截断（checkpoint 路径未实现）。
    // 用上面缓存的探测结果，绝不现调（本函数可能已推迟到 prefill 之后）。
    const int rm_raw = ctx->spec_rm_capable;
    const bool rm_ok = (rm_raw == COMMON_CONTEXT_SEQ_RM_TYPE_RS ||
                        rm_raw == COMMON_CONTEXT_SEQ_RM_TYPE_PART);
    if (!rm_ok) {
        fprintf(stderr,
                "[MBMtmd] DSpark off: can_seq_rm probe=%d (需要 RS(3) 或 PART(1))；"
                "部分回滚不可用 —— 退化为逐 token 生成\n", rm_raw);
        fflush(stderr);
        spec_teardown(ctx, /*drop_draft_model=*/true);
        ctx->spec_n_max = 0;
        return;
    }

    ctx->spec_enabled = true;

    const char * rows_env = std::getenv("LLAMA_MOE_WINDOW_MAX_ROWS");
    fprintf(stderr, "[MBMtmd] DSpark on: n_max=%d draft=%s n_rs_seq=%u window_max_rows=%s can_seq_rm=%d\n",
            ctx->spec_n_max, ctx->draft_model_path.c_str(),
            llama_n_rs_seq(ctx->lctx.get()),
            rows_env ? rows_env : "(unset)",
            ctx->spec_rm_capable);
    fflush(stderr);
}

// 吐出一个缓冲片段。spec_out 为空时按 spec_end_after 决定是否结束生成。
// 诊断：按产出顺序打印每个 token id（`MB_TOKLOG=1` 时生效）。
//
// 用途：固定种子 + 贪心时，base 与 DSpark 两条路径的输出**理论上应该逐 token 相同**。
// 比对文本只能看到「第几个字符分叉」，比对 token 序列才能直接定位**第一个分叉的步号**，
// 再结合那一步的 logits 判断是「目标的 argmax 变了」（KV/窗口问题）还是「accept 采纳错了」。
static void mb_toklog(const char * path, llama_token id) {
    static const int      enabled = getenv("MB_TOKLOG") ? 1 : 0;
    static long long      idx     = 0;
    if (!enabled) {
        return;
    }
    fprintf(stderr, "[TOKLOG] path=%s idx=%lld id=%d\n", path, idx++, (int) id);
}

static mb_mtmd_token spec_drain(mb_mtmd_context * ctx) {
    mb_mtmd_token r = { /*token=*/nullptr, /*is_end=*/false };
    if (!ctx->spec_out.empty()) {
        std::string piece = std::move(ctx->spec_out.front());
        ctx->spec_out.pop_front();
        const bool last = ctx->spec_out.empty() && ctx->spec_end_after;
        if (last) {
            ctx->spec_end_after = false;
        }
        if (!piece.empty()) {
            r.token = static_cast<char *>(malloc(piece.size() + 1));
            if (r.token) {
                memcpy(r.token, piece.data(), piece.size());
                r.token[piece.size()] = '\0';
            }
        }
        r.is_end = last;
        return r;
    }
    if (ctx->spec_end_after) {
        ctx->spec_end_after = false;
        r.is_end = true;
    }
    return r;
}

// 用给定的 n_ctx / n_ubatch 重建 lctx。
//
// **只能在 n_past == 0 时调用** —— 重建会丢掉整个 KV。所有调用点都先检查 n_past，
// 因为自适应只关心「本轮要 prefill 多长」，而每条消息是增量 prefill 的
// （见 mb_mtmd_prefill_text 的 start_n_past），所以只有会话首次 prefill 需要判断。
static bool recreate_lctx(mb_mtmd_context * ctx, int32_t n_ctx, int32_t n_ubatch) {
    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx           = static_cast<uint32_t>(n_ctx);
    cparams.n_batch         = 2048;
    cparams.n_ubatch        = static_cast<uint32_t>(n_ubatch);
    cparams.n_threads       = ctx->n_threads;
    cparams.n_threads_batch = ctx->n_threads;
    cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
    cparams.no_perf         = false;
    // 投机开启时保留 n_rs_seq —— 否则重建后 can_seq_rm 会退到 PART/FULL，
    // 部分回滚失效（spec_create 重新校验时会直接关掉投机）。
    if (ctx->spec_enabled && ctx->spec_n_max > 0) {
        cparams.n_rs_seq = static_cast<uint32_t>(ctx->spec_n_max);
    }

    const double t0 = now_ms();
// 必须先释放旧 context 再建新的：否则新旧短暂共存会把峰值推过设备上限。
// 内存探针 A/B/C/D 的判读见 mb_mem_probe_sleep_ms。
    mb_log_mem_label("rebuild A before free: old_ub=%d old_n_ctx=%d new_ub=%d new_n_ctx=%d",
                     ctx->n_ubatch_cur, ctx->n_ctx_cur, n_ubatch, n_ctx);
    ctx->lctx.reset();
    mb_log_mem_label("rebuild B after free: new_ub=%d new_n_ctx=%d", n_ubatch, n_ctx);
    if (const int probe_sleep_ms = mb_mem_probe_sleep_ms(); probe_sleep_ms > 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(probe_sleep_ms));
        mb_log_mem_label("rebuild D +%dms after free: new_ub=%d new_n_ctx=%d",
                         probe_sleep_ms, n_ubatch, n_ctx);
    }
    ctx->lctx.reset(llama_init_from_model(ctx->model.get(), cparams));
    mb_log_mem_label("rebuild C after init: new_ub=%d new_n_ctx=%d", n_ubatch, n_ctx);
    if (!ctx->lctx) {
        set_error(ctx, "failed to recreate llama_context for adaptive ubatch");
        return false;
    }
    ctx->n_batch      = static_cast<int32_t>(llama_n_batch(ctx->lctx.get()));
    ctx->n_ubatch_cur = n_ubatch;
    ctx->n_ctx_cur    = n_ctx;
    // 投机解码器持有旧 lctx 的裸指针，换成新 context 之后必须重建。
    // 此刻 n_past == 0，草稿 KV 还是空的，重建不丢状态。
    if (ctx->spec_n_max > 0 && !ctx->draft_model_path.empty()) {
        spec_create(ctx);
    }
    fprintf(stderr, "[MBMtmd] adaptive ubatch -> %d (n_ctx=%d, rebuilt in %.0f ms)\n",
            n_ubatch, n_ctx, now_ms() - t0);
    fflush(stderr);
    mb_log_mem("after adaptive ubatch rebuild");
    return true;
}

// 本次 prefill 该用多大的 ubatch。返回 false 表示不用动。
//
// 只看「这一次要 prefill 多少 token」：短的就配小 ub（decode 更快），
// 长的（或带图）就配大 ub（避免切段后每段重读专家）。
static bool moe_adaptive_ubatch(mb_mtmd_context * ctx, bool has_image, int n_tokens) {
    if (!ctx->ubatch_adaptive || ctx->n_past != 0) {
        return false;   // n_past > 0 时重建会丢 KV
    }
    int32_t want = moe_ub_for_tokens(has_image, n_tokens);
    const int32_t ub_max = moe_ub_window_max();
    if (ctx->moe_window_active && want > ub_max) {
        fprintf(stderr, "[MBMtmd] ubatch capped to %d (window active; a bigger ub would "
                        "starve the compute buffer and OOM)\n", ub_max);
        fflush(stderr);
        want = ub_max;
    }
    if (want == ctx->n_ubatch_cur) {
        return false;
    }
    fprintf(stderr, "[MBMtmd] adaptive ubatch: %s first prefill (has_image=%d, n_tokens=%d); "
                    "switch %d -> %d\n",
            ctx->text_only ? "text-only" : "vision",
            has_image ? 1 : 0, n_tokens, ctx->n_ubatch_cur, want);
    fflush(stderr);
    return recreate_lctx(ctx, ctx->n_ctx_cur, want);
}

mb_mtmd_context * mb_mtmd_init(const char * model_path,
                               const char * mmproj_path,
                               const char * moe_experts_path,
                               const char * draft_model_path,
                               const mb_mtmd_params * params_in) {
    if (!model_path || !*model_path || !mmproj_path || !*mmproj_path) {
        g_last_init_error = "mb_mtmd_init: missing model_path or mmproj_path";
        fprintf(stderr, "[MBMtmd] %s\n", g_last_init_error.c_str());
        return nullptr;
    }

    ensure_llama_log();
    g_last_init_error.clear();
    g_last_llama_error.clear();

    mb_logf("[MBMtmd] ===== init (multimodal), log file = %s =====", mb_run_log_path());

    mb_mtmd_params params = params_in ? *params_in : mb_mtmd_params_default();

    llama_backend_init();

    // std::make_unique is C++14; some Xcode build configs in this project use
    // gnu++0x (= C++11) for ObjC++ targets, so we stick with the C++11 form.
    std::unique_ptr<mb_mtmd_context> ctx(new mb_mtmd_context());
    if (moe_experts_path && *moe_experts_path) {
        ctx->experts_path = moe_experts_path;
        ctx->model_version = 47;
    }

    // ---- DSpark 投机解码：参数落地（还没有任何 context） ----
    ctx->spec_n_max = params.spec_draft_n_max;
    if (ctx->spec_n_max < 0)  ctx->spec_n_max = 0;
    if (ctx->spec_n_max > 16) ctx->spec_n_max = 16;
    if (draft_model_path && *draft_model_path) {
        ctx->draft_model_path = draft_model_path;
    }
    // 没给草稿模型 / n_max=0 → 投机全程关闭，行为与旧版逐字节一致。
    const bool want_spec = !ctx->draft_model_path.empty() && ctx->spec_n_max > 0;
    if (want_spec) {
        // 必须在目标模型加载之前设：模型侧按它建每层张量布局。
        apply_spec_moe_window_env(ctx->spec_n_max, "before model load");
    } else {
        fprintf(stderr, "[MBMtmd] DSpark off (n_max=%d draft=%s)\n",
                ctx->spec_n_max, ctx->draft_model_path.empty() ? "(none)" : ctx->draft_model_path.c_str());
    }

    // ---- Load text model ----
    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = params.use_gpu ? 999 : 0;
    // No `load_mtp` on this branch: llama_model_params has no such field here.
    int slot_bank = 0;
    if (!ctx->experts_path.empty()) {
        mparams.moe_experts_path = ctx->experts_path.c_str();
        slot_bank = params.moe_slot_bank > 0 ? params.moe_slot_bank : 8;
        mparams.moe_slot_bank    = slot_bank;
        // 默认用 mmap，见 moe_use_mmap_launch_arg 的说明（剥离 gguf 后已可在端上工作）。
        mparams.use_mmap         = moe_use_mmap_launch_arg();
        apply_lookahead_prefetch_env(params.moe_lookahead_prefetch_depth, "before model load");
        apply_moe_decode_window_env(params.moe_decode_window, "before model load");
        apply_moe_own_alloc_env("before model load");
        apply_moe_skip_read_env("before model load");
        apply_moe_io_threads_env("before model load");
        apply_moe_matmul_split_env("before model load");
        apply_moe_dummy_read_env("before model load");
        apply_moe_read_delay_env("before model load");
        apply_moe_nocache_env("before model load");
        ctx->moe_prewarm_level = apply_moe_prewarm_env(
            params.moe_prewarm_level, params.moe_prewarm_table_id,
            params.moe_decode_window, "before model load");
        ctx->moe_k_prefill = MB_MOE_K_PREFILL;
        ctx->moe_k_decode  = MB_MOE_K_DECODE;
        fprintf(stderr, "[MBMtmd] MoE SSD experts=%s slot_bank=%d shared=on lookahead=d%d moe_k=prefill%d/decode%d\n",
                mparams.moe_experts_path, slot_bank, clamp_lookahead_prefetch_depth(params.moe_lookahead_prefetch_depth),
                ctx->moe_k_prefill, ctx->moe_k_decode);
    }

    ctx->model.reset(llama_model_load_from_file(model_path, mparams));
    if (!ctx->model) {
        set_error(ctx.get(), std::string("Failed to load model from: ") + model_path);
        return nullptr;
    }

// 内存预算：n_ubatch 主导 GPU compute buffer（n_ubatch=1024 约 970 MiB）。
// n_batch 保持 2048（只影响 dispatch 次数）。flash_attn=AUTO。
// MoE：单 graph 的 unique experts ≤ min(ub*n_used, n_expert)，必须装进共享 bank。
// 完整分解见 Comni/v47/ios-app-调优参数与实测.md §1。
    ctx->ubatch_adaptive = !moe_ubatch_pinned();
    int requested_ubatch = ctx->ubatch_adaptive
        ? MB_MOE_UB_LADDER[0]
        : (params.n_ubatch > 0 ? params.n_ubatch : MB_DEFAULT_N_UBATCH);
    {
        const int32_t t_override = moe_threads_launch_arg();
        ctx->n_threads = t_override > 0 ? t_override : (params.n_threads > 0 ? params.n_threads : 4);
        if (t_override > 0) {
            fprintf(stderr, "[MBMtmd] n_threads overridden to %d (launch arg)\n", t_override);
        }
    }
    // 窗口是否启用决定 ubatch 的硬上限（见 MB_MOE_UB_WINDOW_MAX）。
    ctx->moe_window_active = params.moe_decode_window > 0;
    if (!ctx->experts_path.empty()) {
        // 调用方没给 ubatch 时，旧行为是保守取 1（只要 8 个 slot 就够）。
        // 自适应模式下不能这么做 —— 那会把 SMALL(128) 打回 1，自适应的意义就没了；
        // 下面的 bank 夹取已经保证「窗口装得下」。
        if (params.n_ubatch <= 0 && !ctx->ubatch_adaptive) {
            requested_ubatch = 1;
        }
        if (slot_bank < MB_MOE_EXPERT_COUNT) {
            const int max_ub = std::max(1, slot_bank / MB_MOE_EXPERTS_USED);
            requested_ubatch = std::min(requested_ubatch, max_ub);
        }
    }

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx           = static_cast<uint32_t>(params.n_ctx > 0 ? params.n_ctx : 4096);
    cparams.n_batch         = static_cast<uint32_t>(std::max(2, requested_ubatch < 512 ? 512 : requested_ubatch));
    cparams.n_ubatch        = static_cast<uint32_t>(requested_ubatch);
    cparams.n_threads       = ctx->n_threads;
    cparams.n_threads_batch = ctx->n_threads;
    cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
    cparams.no_perf         = false;
    // DSpark: 部分回滚靠 n_rs_seq（回滚量 = 验证批里被拒的行数，<= n_max）。
    if (want_spec) {
        cparams.n_rs_seq = static_cast<uint32_t>(ctx->spec_n_max);
    }

    fprintf(stderr, "[MBMtmd] llama_context: n_ctx=%u n_batch=%u n_ubatch=%u n_rs_seq=%u flash_attn=AUTO\n",
            cparams.n_ctx, cparams.n_batch, cparams.n_ubatch, cparams.n_rs_seq);

    if (!ctx->experts_path.empty()) {
        apply_lookahead_prefetch_env(params.moe_lookahead_prefetch_depth, "before llama_context");
    }
    try {
        ctx->lctx.reset(llama_init_from_model(ctx->model.get(), cparams));
    } catch (const std::exception & e) {
        set_error(ctx.get(), std::string("llama_init exception: ") + e.what());
        return nullptr;
    }
    if (!ctx->lctx) {
        std::string err = "Failed to create llama_context";
        if (!g_last_llama_error.empty()) {
            err += ": ";
            err += g_last_llama_error;
        } else {
            err += " (n_ctx=" + std::to_string(cparams.n_ctx)
                + " n_ubatch=" + std::to_string(cparams.n_ubatch)
                + "; often Metal OOM on iPhone)";
        }
        set_error(ctx.get(), err);
        return nullptr;
    }
    apply_moe_k(ctx.get(), ctx->moe_k_prefill);
    apply_media_embd_batch_env("multimodal init");

    // DSpark：在 KV 还是空的时候探测一次部分回滚能力并缓存（见 spec_probe_rm_capability）。
    if (want_spec) {
        spec_probe_rm_capability(ctx.get(), "multimodal init");
    }

    ctx->vocab   = llama_model_get_vocab(ctx->model.get());
    ctx->n_batch = static_cast<int32_t>(llama_n_batch(ctx->lctx.get()));
    ctx->n_ubatch_cur = requested_ubatch;
    ctx->n_ctx_cur    = static_cast<int32_t>(cparams.n_ctx);
    mb_log_mem("after llama_context (window allocated)");

    // ---- DSpark: 建投机解码器（必须在首个 prefill decode 之前） ----
    // 草稿的 KV 只由 common_speculative_process() 填充、且被 spec_enabled 门控；等到
    // prefill 之后才建，开场 prompt 的特征就喂不进草稿，受理率大幅下降（输出仍正确）。
    // 此时不要调 common_context_can_seq_rm() —— 它会清空目标 KV（上面已探测并缓存）。
    if (want_spec) {
        spec_create(ctx.get());
    }

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
        // 临时覆盖开关（只为和 llama-cli 做对照，不设就是默认 0.5，行为一字不变）。
        // 用 devicectl device process launch -e '{"MB_TEMP":"0"}' 启动即可贪心复现。
        float    temp = params.temperature;
        uint32_t seed = LLAMA_DEFAULT_SEED;
        if (const char * e = getenv("MB_TEMP")) { temp = (float) atof(e); }
        if (const char * e = getenv("MB_SEED")) { seed = (uint32_t) strtoul(e, nullptr, 10); }

        if (temp > 0.0f) {
            if (params.top_k > 0) {
                llama_sampler_chain_add(ctx->sampler.get(), llama_sampler_init_top_k(params.top_k));
            }
            if (params.top_p > 0.0f && params.top_p < 1.0f) {
                llama_sampler_chain_add(ctx->sampler.get(), llama_sampler_init_top_p(params.top_p, /*min_keep=*/1));
            }
            llama_sampler_chain_add(ctx->sampler.get(), llama_sampler_init_temp(temp));
            llama_sampler_chain_add(ctx->sampler.get(), llama_sampler_init_dist(seed));
            mb_logf("[MBMtmd] sampler: temp=%.3f dist seed=%u (MB_TEMP=%s MB_SEED=%s)",
                    temp, (unsigned) seed,
                    getenv("MB_TEMP") ? getenv("MB_TEMP") : "(unset)",
                    getenv("MB_SEED") ? getenv("MB_SEED") : "(unset)");
        } else {
            llama_sampler_chain_add(ctx->sampler.get(), llama_sampler_init_greedy());
            mb_logf("[MBMtmd] sampler: greedy (temp=0, MB_TEMP=%s)",
                    getenv("MB_TEMP") ? getenv("MB_TEMP") : "(unset)");
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
        vparams.use_gpu              = params.mmproj_use_gpu;
        vparams.print_timings        = false;
        vparams.n_threads            = params.n_threads;
        vparams.warmup                = ctx->experts_path.empty() ? params.warmup : false;
        vparams.image_max_tokens      = params.image_max_tokens;
        vparams.image_max_slice_nums  = params.image_max_slice_nums;

        const double before_mmproj = footprint_mib();
        ctx->vision.reset(mtmd_init_from_file(mmproj_path, ctx->model.get(), vparams));
        if (!ctx->vision) {
            set_error(ctx.get(), std::string("Failed to load mmproj from: ") + mmproj_path);
            return nullptr;
        }
        fprintf(stderr, "[MBMtmd] footprint after mmproj load: %.0f -> %.0f MiB (+%.0f MiB)\n",
                before_mmproj, footprint_mib(), footprint_mib() - before_mmproj);
        mb_log_mem("after mmproj load");
    }

    return ctx.release();
}

mb_mtmd_context * mb_mtmd_init_text_only(const char * model_path,
                                         const char * moe_experts_path,
                                         const char * draft_model_path,
                                         const mb_mtmd_params * params_in) {
    if (!model_path || !*model_path) {
        g_last_init_error = "mb_mtmd_init_text_only: missing model_path";
        fprintf(stderr, "[MBMtmd] %s\n", g_last_init_error.c_str());
        return nullptr;
    }

    ensure_llama_log();
    g_last_init_error.clear();
    g_last_llama_error.clear();

    mb_logf("[MBMtmd] ===== init (text-only), log file = %s =====", mb_run_log_path());

    mb_mtmd_params params = params_in ? *params_in : mb_mtmd_params_default();

    llama_backend_init();

    std::unique_ptr<mb_mtmd_context> ctx(new mb_mtmd_context());
    ctx->text_only = true;

    // ---- DSpark 投机解码：参数落地（还没有任何 context） ----
    ctx->spec_n_max = params.spec_draft_n_max;
    if (ctx->spec_n_max < 0)  ctx->spec_n_max = 0;
    if (ctx->spec_n_max > 16) ctx->spec_n_max = 16;
    if (draft_model_path && *draft_model_path) {
        ctx->draft_model_path = draft_model_path;
    }
    const bool want_spec = !ctx->draft_model_path.empty() && ctx->spec_n_max > 0;
    if (want_spec) {
        apply_spec_moe_window_env(ctx->spec_n_max, "before model load (text-only)");
    } else {
        fprintf(stderr, "[MBMtmd] DSpark off (n_max=%d draft=%s)\n",
                ctx->spec_n_max, ctx->draft_model_path.empty() ? "(none)" : ctx->draft_model_path.c_str());
    }

    // ---- Load text model ----
    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = params.use_gpu ? 999 : 0;
    // No `load_mtp` on this branch: llama_model_params has no such field here.
    // 纯文本也要能挂 experts：35B-A3B 全量专家 ~20GB，8GB 手机只能走 SSD 流式。
    // 基准用这条路径（不需要 mmproj / 视觉塔），同时省下 ~1GB 常驻。
    int slot_bank = 0;
    if (moe_experts_path && *moe_experts_path) {
        ctx->experts_path        = moe_experts_path;
        mparams.moe_experts_path = ctx->experts_path.c_str();
        slot_bank = params.moe_slot_bank > 0 ? params.moe_slot_bank : 8;
        mparams.moe_slot_bank    = slot_bank;
        mparams.use_mmap         = moe_use_mmap_launch_arg();  // 默认关，见上面说明
        apply_lookahead_prefetch_env(params.moe_lookahead_prefetch_depth, "before model load (text-only)");
        apply_moe_log_every_step_env("before model load (text-only)");
        apply_moe_layer_windows_env("before model load (text-only)");
        apply_moe_decode_window_env(params.moe_decode_window, "before model load (text-only)");
        apply_moe_own_alloc_env("before model load (text-only)");
        apply_moe_skip_read_env("before model load (text-only)");
        apply_moe_io_threads_env("before model load (text-only)");
        apply_moe_matmul_split_env("before model load (text-only)");
        apply_moe_dummy_read_env("before model load (text-only)");
        apply_moe_read_delay_env("before model load (text-only)");
        apply_moe_nocache_env("before model load (text-only)");
        ctx->moe_prewarm_level = apply_moe_prewarm_env(
            params.moe_prewarm_level, params.moe_prewarm_table_id,
            params.moe_decode_window, "before model load (text-only)");
        ctx->moe_k_prefill = MB_MOE_K_PREFILL;
        ctx->moe_k_decode  = MB_MOE_K_DECODE;
        fprintf(stderr, "[MBMtmd] text-only MoE SSD experts=%s slot_bank=%d shared=on lookahead=d%d moe_k=prefill%d/decode%d\n",
                mparams.moe_experts_path, slot_bank, clamp_lookahead_prefetch_depth(params.moe_lookahead_prefetch_depth),
                ctx->moe_k_prefill, ctx->moe_k_decode);
    }

    ctx->model.reset(llama_model_load_from_file(model_path, mparams));
    if (!ctx->model) {
        set_error(ctx.get(), std::string("Failed to load model from: ") + model_path);
        return nullptr;
    }

    // ---- Create llama_context ----
    // 自适应：没显式钉 ub 时，先用**小** ub 建 context（短 prompt 的常见情形直接受益，
    // decode 快约 22%）；等到首次 prefill 发现是长 prompt / 带图，再重建为大 ub。
    ctx->ubatch_adaptive = !moe_ubatch_pinned();
    const int requested_ubatch = ctx->ubatch_adaptive
        ? MB_MOE_UB_LADDER[0]
        : (params.n_ubatch > 0 ? params.n_ubatch : MB_DEFAULT_N_UBATCH);
    {
        const int32_t t_override = moe_threads_launch_arg();
        ctx->n_threads = t_override > 0 ? t_override : (params.n_threads > 0 ? params.n_threads : 4);
        if (t_override > 0) {
            fprintf(stderr, "[MBMtmd] n_threads overridden to %d (launch arg)\n", t_override);
        }
    }
    // 窗口是否启用决定 ubatch 的硬上限（见 MB_MOE_UB_WINDOW_MAX）。
    ctx->moe_window_active = params.moe_decode_window > 0;

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx           = static_cast<uint32_t>(params.n_ctx > 0 ? params.n_ctx : 4096);
    cparams.n_batch         = 2048;
    cparams.n_ubatch        = static_cast<uint32_t>(requested_ubatch);
    cparams.n_threads       = ctx->n_threads;
    cparams.n_threads_batch = ctx->n_threads;
    cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
    cparams.no_perf         = false;
    if (want_spec) {
        cparams.n_rs_seq = static_cast<uint32_t>(ctx->spec_n_max);
    }

    fprintf(stderr, "[MBMtmd] text-only llama_context: n_ctx=%u n_batch=%u n_ubatch=%u n_rs_seq=%u flash_attn=AUTO\n",
            cparams.n_ctx, cparams.n_batch, cparams.n_ubatch, cparams.n_rs_seq);

    ctx->lctx.reset(llama_init_from_model(ctx->model.get(), cparams));
    if (!ctx->lctx) {
        set_error(ctx.get(), "Failed to create llama_context");
        return nullptr;
    }

    ctx->vocab   = llama_model_get_vocab(ctx->model.get());
    ctx->n_batch = static_cast<int32_t>(llama_n_batch(ctx->lctx.get()));
    ctx->n_ubatch_cur = requested_ubatch;
    ctx->n_ctx_cur    = static_cast<int32_t>(cparams.n_ctx);
    mb_log_mem("after llama_context text-only (window allocated)");
    if (want_spec) {
        spec_probe_rm_capability(ctx.get(), "text-only init");
    }

    // ---- DSpark: 建投机解码器（必须在首个 prefill decode 之前） ----
    // 纯文本模型没有 mmproj，不存在「与视觉塔争内存」的问题，所以这里直接建。
    if (want_spec) {
        spec_create(ctx.get());
    }

    // ---- Build sampler chain ----
    // MiniCPM 5: temperature=0.6, top_p=0.95 (from generation_config.json)
    {
        llama_sampler_chain_params scp = llama_sampler_chain_default_params();
        scp.no_perf = false;
        ctx->sampler.reset(llama_sampler_chain_init(scp));
        if (!ctx->sampler) {
            set_error(ctx.get(), "Failed to init sampler chain");
            return nullptr;
        }
        // 采样参数。与多模态 init 路径保持一致：可用 MB_TEMP / MB_SEED 环境变量
        // 覆盖（`devicectl device process launch -e '{"MB_TEMP":"0","MB_SEED":"42"}'`）。
        //
        // 之前这里写死 `dist(LLAMA_DEFAULT_SEED)`，导致**纯文本路径无法复现**：
        // 同一个 prompt 两次运行输出不同，既没法做「开/关投机解码输出是否一致」
        // 这种正确性校验，也没法做可复现的基准。两条路径行为不一致本身就是个坑。
        float    temp = params.temperature > 0.0f ? params.temperature : 0.6f;
        uint32_t seed = LLAMA_DEFAULT_SEED;
        if (const char * e = getenv("MB_TEMP")) { temp = (float) atof(e); }
        if (const char * e = getenv("MB_SEED")) { seed = (uint32_t) strtoul(e, nullptr, 10); }
        if (temp > 0.0f) {
            llama_sampler_chain_add(ctx->sampler.get(), llama_sampler_init_top_p(0.95f, /*min_keep=*/1));
            llama_sampler_chain_add(ctx->sampler.get(), llama_sampler_init_temp(temp));
            llama_sampler_chain_add(ctx->sampler.get(), llama_sampler_init_dist(seed));
            mb_logf("sampler (text-only): temp=%.3f dist seed=%u (MB_TEMP=%s MB_SEED=%s)",
                    temp, (unsigned) seed,
                    getenv("MB_TEMP") ? getenv("MB_TEMP") : "(unset)",
                    getenv("MB_SEED") ? getenv("MB_SEED") : "(unset)");
        } else {
            llama_sampler_chain_add(ctx->sampler.get(), llama_sampler_init_greedy());
            mb_logf("sampler (text-only): greedy (MB_TEMP=%s)",
                    getenv("MB_TEMP") ? getenv("MB_TEMP") : "(unset)");
        }
    }

    // ---- Allocate generation batch ----
    ctx->batch        = llama_batch_init(ctx->n_batch, /*embd=*/0, /*n_seq_max=*/1);
    ctx->batch_inited = true;
    if (!ctx->batch.token) {
        set_error(ctx.get(), "Failed to llama_batch_init");
        return nullptr;
    }

    // No vision context for text-only models
    // ctx->vision remains nullptr

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
    // 草稿 context 也跟着清 —— 否则新对话的第一轮会看到上一段会话的专家特征。
    if (ctx->lctx_dft) {
        llama_memory_seq_rm(llama_get_memory(ctx->lctx_dft.get()), /*seq=*/0, /*p0=*/0, /*p1=*/-1);
    }
    ctx->n_past = 0;
    ctx->pending_image_path.clear();
    ctx->pending_image.clear();
    // 投机解码的分轮状态（prefill 时会重新 begin）。
    ctx->spec_out.clear();
    ctx->spec_end_after = false;
    ctx->spec_prompt.clear();
    ctx->spec_began = false;
    ctx->spec_anchor_valid = false;
    ctx->cached_piece.clear();
    return true;
}

void mb_mtmd_set_model_version(mb_mtmd_context * ctx, int version) {
    if (ctx) ctx->model_version = version;
}

void mb_mtmd_set_enable_thinking(mb_mtmd_context * ctx, bool enable) {
    if (ctx) ctx->enable_thinking = enable;
}

void mb_mtmd_set_image_max_slice_nums(mb_mtmd_context * ctx, int n) {
    if (!ctx || !ctx->vision) {
        return;
    }
    // -1 / 0 => model default; 1 => overview only; 2..9 => explicit cap.
    // The slicing decision is re-read on every encode, so this takes effect
    // on the next image without reloading the mmproj. mtmd also remembers it across an
    // mmproj release/reload cycle (see mtmd_set_image_max_slice_nums).
    mtmd_set_image_max_slice_nums(ctx->vision.get(), n);
    fprintf(stderr, "[MBMtmd] image_max_slice_nums = %d\n", n);
}

int mb_mtmd_set_moe_lookahead_prefetch_depth(mb_mtmd_context * ctx, int depth) {
    depth = clamp_lookahead_prefetch_depth(depth);
    apply_lookahead_prefetch_env(depth, "runtime");
    if (!ctx || !ctx->lctx) {
        return depth;
    }
    llama_set_moe_lookahead_prefetch_depth(ctx->lctx.get(), depth);
    fprintf(stderr, "[MBMtmd] moe lookahead depth now %d\n", llama_get_moe_lookahead_prefetch_depth(ctx->lctx.get()));
    return llama_get_moe_lookahead_prefetch_depth(ctx->lctx.get());
}

int mb_mtmd_get_moe_lookahead_prefetch_depth(const mb_mtmd_context * ctx) {
    if (!ctx || !ctx->lctx) {
        return 0;
    }
    return llama_get_moe_lookahead_prefetch_depth(ctx->lctx.get());
}

// ---------------------------------------------------------------------------
//  Memory rollback helper
// ---------------------------------------------------------------------------

// 部分 prefill 失败后回滚 KV/SSM。混合 SSM 模型不支持 p0>0 的部分截断，
// 只能整段清空（丢历史，但好过留下「此后每次 prefill 都失败」的僵尸态）。
// true=干净部分回滚；false=已整段清空（n_past 现在为 0）。
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

    const double t0 = now_ms();
    const llama_pos start_n_past_for_perf = ctx->n_past;

    if (!mb_ensure_vision(ctx, caller_label)) {
        return -1;
    }

    mtmd_bitmap * raw_bmp = mb_bitmap_from_file(ctx->vision.get(), image_path);
    if (!raw_bmp) {
        set_error(ctx, std::string(caller_label) + ": failed to load image: " + image_path);
        return -1;
    }
    // Adopt ownership; freed with the input_chunks below or here on early exit.
    std::unique_ptr<mtmd_bitmap, void(*)(mtmd_bitmap*)> bmp(raw_bmp, mtmd_bitmap_free);

    mtmd_input_text text = {};
    const char * marker = mtmd_default_marker();
    text.text          = marker;
    // No `text_len`: this branch's mtmd_input_text is still the NUL-terminated
    // (text, add_special, parse_special) triple and measures with strlen() itself.
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
    // 到这一步为止都还是「准备」（mmproj 重载 / 图片解码 / tokenize+切片），不是 prefill。
    // 从此刻起才是真正要计入 prefill t/s 的 llama 前向。
    const double t_prefill_start = now_ms();
    int32_t   ev = eval_prefill(ctx, chunks, /*logits_last=*/false, &new_n_past);
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
    perf_add_prep  (ctx, t_prefill_start - t0);
    perf_add_prefill(ctx, static_cast<int32_t>(mtmd_helper_get_n_tokens(chunks)), t_prefill_start);
    return 0;
}

// Encode `image_path` now and stash the embedding for the coming user turn.
//
// Only valid for chatml-moe: those models defer the image to the user turn,
// and this is the half of that work which does not depend on KV position.
// Returns 0 on success; ctx->pending_image is left invalid on failure.
static int eager_encode_image(mb_mtmd_context * ctx, const char * image_path) {
    ctx->pending_image.clear();
    if (!ctx->lctx) {
        set_error(ctx, "eager_encode: context not ready");
        return -1;
    }
    // 第二轮选图：窗口 MTLBuffer 还占 Metal 工作集，CLIP 会 OOM。第一轮不要拆——
    // 后面第一次 llama_decode 会把整块窗口重新包上，iPad 上第一轮 decode 会卡住。
    // 生成结束后已经 park 过；n_past>0 时这里是兜底。
    if (ctx->n_past > 0) {
        mb_park_moe_expert_memory(ctx, "before eager image encode");
    }
    if (!mb_ensure_vision(ctx, "eager image encode")) {
        return -1;
    }

    const double t0 = now_ms();

    mtmd_bitmap * raw_bmp = mb_bitmap_from_file(ctx->vision.get(), image_path);
    if (!raw_bmp) {
        set_error(ctx, std::string("eager_encode: failed to load image: ") + image_path);
        return -1;
    }
    std::unique_ptr<mtmd_bitmap, void(*)(mtmd_bitmap*)> bmp(raw_bmp, mtmd_bitmap_free);

    // A marker-only prompt is enough to obtain the image chunk: how the image
    // itself is chunked does not depend on the surrounding text.
    const char * marker = mtmd_default_marker();
    mtmd_input_text in = {};
    in.text          = marker;
    in.add_special   = false;
    in.parse_special = true;

    mtmd_input_chunks * chunks = mtmd_input_chunks_init();
    if (!chunks) {
        set_error(ctx, "eager_encode: mtmd_input_chunks_init failed");
        return -1;
    }
    std::unique_ptr<mtmd_input_chunks, void(*)(mtmd_input_chunks*)> chunks_guard(chunks, mtmd_input_chunks_free);

    const mtmd_bitmap * bmp_arr[1] = { bmp.get() };
    if (mtmd_tokenize(ctx->vision.get(), chunks, &in, bmp_arr, 1) != 0) {
        set_error(ctx, "eager_encode: mtmd_tokenize failed");
        return -1;
    }

    // One image may tokenize into several image chunks (1 overview + N
    // slices), so encode every one of them, in order.
    const size_t n_chunks = mtmd_input_chunks_size(chunks);
    const int n_mmproj_embd = llama_model_n_embd_inp(llama_get_model(ctx->lctx.get()));

    int32_t total_tokens = 0;
    for (size_t i = 0; i < n_chunks; i++) {
        const mtmd_input_chunk * c = mtmd_input_chunks_get(chunks, i);
        if (!c || mtmd_input_chunk_get_type(c) != MTMD_INPUT_CHUNK_TYPE_IMAGE) {
            continue;
        }

        if (mtmd_encode_chunk(ctx->vision.get(), c) != 0) {
            set_error(ctx, "eager_encode: mtmd_encode_chunk failed at chunk "
                           + std::to_string(i));
            ctx->pending_image.clear();
            return -1;
        }

        const int32_t n_tokens = static_cast<int32_t>(mtmd_input_chunk_get_n_tokens(c));
        const float * embd = mtmd_get_output_embd(ctx->vision.get());
        if (!embd || n_tokens <= 0) {
            set_error(ctx, "eager_encode: empty embedding at chunk " + std::to_string(i));
            ctx->pending_image.clear();
            return -1;
        }

        // mtmd keeps the encoded floats in a shared buffer, so we own a copy:
        // n_tokens * llama_model_n_embd_inp(model) floats, same shape
        // mtmd_helper_decode_image_chunk() expects.
        mb_mtmd_context::pending_image_cache::piece piece;
        piece.n_tokens = n_tokens;
        piece.embd.assign(embd, embd + static_cast<size_t>(n_tokens) * static_cast<size_t>(n_mmproj_embd));
        ctx->pending_image.pieces.push_back(std::move(piece));
        total_tokens += n_tokens;
    }

    if (ctx->pending_image.pieces.empty()) {
        set_error(ctx, "eager_encode: tokenize produced no image chunk");
        return -1;
    }

    ctx->pending_image.path = image_path;
    ctx->pending_image.encode_ms = now_ms() - t0;

    ctx->perf_image_tokens = total_tokens;
    ctx->perf_image_ms = ctx->pending_image.encode_ms;

    size_t total_floats = 0;
    for (const auto & p : ctx->pending_image.pieces) total_floats += p.embd.size();

    mb_logf("[MBMtmd] eager image encode: %s %zu chunk(s), %d tok (%.2f MiB) in %.0f ms",
            image_path, ctx->pending_image.pieces.size(), total_tokens,
            static_cast<double>(total_floats) * sizeof(float) / 1024.0 / 1024.0,
            ctx->pending_image.encode_ms);
    return 0;
}

int mb_mtmd_prefill_image(mb_mtmd_context * ctx, const char * image_path) {
    if (!ctx || !image_path || !*image_path) {
        if (ctx) set_error(ctx, "prefill_image: empty image path");
        return -1;
    }
    // ChatML image-in-user-turn (model_version 36/47/471): the media marker must
    // sit inside <|im_start|>user ... <|im_end|>, and that string only exists once
    // the user text arrives — so the KV write is deferred to prefill_text.
    // Encoding is position-independent, so do it right here: that is what makes
    // the UI's "预处理耗时" a real number instead of 0.0s.
    if (is_chatml_image_deferred(ctx->model_version)) {
        const int rc = eager_encode_image(ctx, image_path);
        if (rc != 0) {
            // Leave pending_image_path unset rather than arming a turn that
            // would send a broken image.
            return rc;
        }
        ctx->pending_image_path = image_path;
        // 预热**刻意不在这里**做，而是拆成独立入口 mb_mtmd_prewarm_after_image()。
        // 原因：App 的「预处理耗时」是包着本调用的墙钟，预热放进来会被算进去
        // （实测 w64 多 1.05 s、w96 约 1.6 s）。拆开后 App 先记下编码耗时、再调
        // 预热，那笔读在 UI 上完全不可见。
        return 0;
    }
    return prefill_image_like(ctx, image_path, "prefill_image");
}

// 选图后的隐藏步骤：重建自适应 ubatch + 预热。
// 别与 prefill_image 合回去 —— 上层「预处理耗时」包着后者，预热会被计入（+1.0~1.6 s）。
// 顺序要紧：先重建 ubatch（会换掉 lctx），再预热。详见文档 §13。
int mb_mtmd_prewarm_after_image(mb_mtmd_context * ctx) {
    if (!ctx) {
        return -1;
    }
    if (!is_chatml_moe(ctx->model_version) || ctx->pending_image_path.empty()) {
        // 没有待发送的图（或非 ChatML MoE 模型）→ 没有预热对象。
        return 0;
    }
    // 探针：这一步是 5316 MiB 峰值的所在 —— mmproj 刻意仍常驻（见上面的注释），
    // 而下面 moe_adaptive_ubatch 会把 ub 从 128 抬到 1024，重建 lctx 时旧 compute
    // buffer 与新 compute buffer 的交接全在这里发生。前后各记一次，才能把「重建
    // 增量」和「预热读盘增量」分开看。
    mb_log_mem_label("prewarm/rebuild: before (mmproj resident, cur_ub=%d)", ctx->n_ubatch_cur);
    moe_adaptive_ubatch(ctx, /*has_image=*/true, /*n_tokens=*/0);
    mb_log_mem_label("prewarm/rebuild: after (cur_ub=%d)", ctx->n_ubatch_cur);
    mb_prewarm_moe_experts(ctx, "after eager image encode (before send)");
    return 0;
}

int mb_mtmd_prefill_frame(mb_mtmd_context * ctx, const char * image_path) {
    return prefill_image_like(ctx, image_path, "prefill_frame");
}

int mb_mtmd_prefill_text(mb_mtmd_context * ctx, const char * text_in, const char * role_in) {
    if (!ctx || !text_in || !role_in || !*text_in || !*role_in) {
        if (ctx) set_error(ctx, "prefill_text: empty text or role");
        return -1;
    }

    if (!ctx->perf_turn_open && ctx->lctx) {
        llama_perf_context_reset(ctx->lctx.get());
    }

    // DSpark：新一轮 turn —— 重置分轮状态，让 begin() 重跑、输出缓冲不跨轮残留。
    if (ctx->spec_enabled) {
        ctx->spec_out.clear();
        ctx->spec_end_after = false;
        ctx->spec_prompt.clear();
        ctx->spec_began = false;
        ctx->spec_anchor_valid = false;
    }

    const std::string role = role_in;
    const std::string text = std::string(text_in);

// 首轮需显式加 BOS：模型 metadata 的 add_bos_token=false，BOS 归模板管。
    std::string formatted;

    // Prepend BOS for text-only models on the first turn.
    if (ctx->text_only && ctx->n_past == 0) {
        formatted = "<s>";
    }

    if (role == "user") {
        const bool chatml_moe = is_chatml_image_deferred(ctx->model_version);
        if (chatml_moe && !ctx->pending_image_path.empty()) {
            formatted += std::string("<|im_start|>user\n") + mtmd_default_marker() + "\n" + text
                + "<|im_end|>\n" + chatml_nothink_header();
            fprintf(stderr, "[MBMtmd] chatml moe thinking=off (image turn)\n");
        } else {
            formatted += "<|im_start|>user\n" + text + "<|im_end|>\n";
            const bool supports_thinking = ctx->text_only
                || ctx->model_version == 46
                || ctx->model_version == 460
                || ctx->model_version == 461;
            if (chatml_moe) {
                formatted += chatml_nothink_header();
                fprintf(stderr, "[MBMtmd] chatml moe thinking=off (text turn)\n");
            } else if (supports_thinking) {
                // MiniCPM5 / V-4.6: match Jinja2 enable_thinking branches.
                // parse_special=true maps "<think>" to one special token.
                if (ctx->enable_thinking) {
                    formatted += "<|im_start|>assistant\n<think>\n";
                } else {
                    formatted += "<|im_start|>assistant\n<think>\n\n</think>\n\n";
                }
            } else {
                // V4.0 / V2.6: plain assistant header, no thinking support
                formatted += "<|im_start|>assistant\n";
            }
        }
    } else if (role == "assistant") {
        formatted += text + "<|im_end|>\n";
    } else if (role == "system") {
        formatted += "<|im_start|>system\n" + text + "<|im_end|>\n";
    } else {
        set_error(ctx, "prefill_text: unknown role: " + role);
        return -1;
    }

    // 落盘本轮「真正喂给模型」的模板文本 + 原始输入，供事后与 llama-cli 对照。
    {
        const std::string tag = "PROMPT[" + role + "]";
        mb_mtmd_log_text(tag.c_str(), formatted.c_str());
        mb_logf("[MBMtmd] prompt raw role=%s n_past=%d pending_image=%s chars=%zu",
                role.c_str(), (int) ctx->n_past,
                ctx->pending_image_path.empty() ? "(none)" : ctx->pending_image_path.c_str(),
                text.size());
    }

    const double t0 = now_ms();
    const llama_pos start_n_past_for_perf = ctx->n_past;

    if (ctx->text_only) {
        // Text-only path: use llama_tokenize directly (no mtmd/vision context).
        // BOS is managed explicitly via the template (see <s> above), so
        // add_special is always false to avoid double BOS.
        const bool add_special = false;

        int32_t n_tokens = llama_tokenize(ctx->vocab, formatted.c_str(),
                                          static_cast<int32_t>(formatted.size()),
                                          nullptr, 0, add_special, /*parse_special=*/true);
        if (n_tokens < 0) n_tokens = -n_tokens;

        std::vector<llama_token> tokens(static_cast<size_t>(n_tokens));
        int32_t actual = llama_tokenize(ctx->vocab, formatted.c_str(),
                                        static_cast<int32_t>(formatted.size()),
                                        tokens.data(), n_tokens, add_special, /*parse_special=*/true);
        if (actual < 0) {
            set_error(ctx, "prefill_text: llama_tokenize failed");
            return -1;
        }
        tokens.resize(static_cast<size_t>(actual));

        // 自适应 ubatch：本次要 prefill 的 token 数已经确定，据此挑 ub。
        // 只在 n_past == 0（会话首次）会真正重建；之后每条消息都是增量 prefill，
        // 长度与本轮无关，所以不再切换。
        moe_adaptive_ubatch(ctx, /*has_image=*/false, static_cast<int>(tokens.size()));

        // Prefill tokens in batches
        const llama_pos start_n_past = ctx->n_past;
        const int32_t batch_size = ctx->n_batch;

        apply_moe_k(ctx, ctx->moe_k_prefill > 0 ? ctx->moe_k_prefill : MB_MOE_K_PREFILL);

        // tokenize + 自适应 ubatch 重建都算准备，不算 prefill。
        const double t_prefill_start = now_ms();

        for (size_t i = 0; i < tokens.size(); i += static_cast<size_t>(batch_size)) {
            size_t end = std::min(i + static_cast<size_t>(batch_size), tokens.size());
            int32_t chunk_len = static_cast<int32_t>(end - i);
            bool is_last_chunk = (end == tokens.size());

            llama_batch batch = llama_batch_init(chunk_len, /*embd=*/0, /*n_seq_max=*/1);
            batch.n_tokens = chunk_len;
            for (int32_t j = 0; j < chunk_len; j++) {
                batch.token[j]      = tokens[i + static_cast<size_t>(j)];
                batch.pos[j]        = ctx->n_past + j;
                batch.n_seq_id[j]   = 1;
                batch.seq_id[j][0]  = 0;
                batch.logits[j]     = (is_last_chunk && j == chunk_len - 1) ? 1 : 0;
            }

            if (llama_decode(ctx->lctx.get(), batch) != 0) {
                llama_batch_free(batch);
                rollback_to_n_past(ctx, start_n_past);
                set_error(ctx, "prefill_text: llama_decode failed (text-only path)");
                return -1;
            }

            // DSpark：每一次 decode 都要把刚 decode 的 batch 喂给 process()（草稿的编解码器
            // 按 batch 的行区间读目标中间层特征，换别的 batch 会错位）。
            if (ctx->spec_enabled) {
                for (int32_t j = 0; j < chunk_len; j++) {
                    ctx->spec_prompt.push_back(tokens[i + static_cast<size_t>(j)]);
                }
                if (!common_speculative_process(static_cast<common_speculative *>(ctx->spec), batch)) {
                    fprintf(stderr, "[MBMtmd] common_speculative_process() failed during prefill; "
                                    "drafts may degrade\n");
                    fflush(stderr);
                }
            }

            ctx->n_past += chunk_len;
            llama_batch_free(batch);
        }

        perf_add_prep  (ctx, t_prefill_start - t0);
        perf_add_prefill(ctx, static_cast<int32_t>(tokens.size()), t_prefill_start);
        return 0;
    }

    // Vision model path: use mtmd_tokenize + chunk-by-chunk eval.
    // If this turn carries an image, eval_prefill reuses the eager embedding.
    mtmd_input_text in = {};
    in.text          = formatted.c_str();
    in.add_special   = (ctx->n_past == 0);
    in.parse_special = true;

    mtmd_input_chunks * chunks = mtmd_input_chunks_init();
    if (!chunks) {
        set_error(ctx, "prefill_text: mtmd_input_chunks_init failed");
        return -1;
    }
    std::unique_ptr<mtmd_input_chunks, void(*)(mtmd_input_chunks*)> chunks_guard(chunks, mtmd_input_chunks_free);

    std::unique_ptr<mtmd_bitmap, void(*)(mtmd_bitmap*)> bmp(nullptr, mtmd_bitmap_free);
    const mtmd_bitmap * bmp_arr[1] = { nullptr };
    size_t n_bitmaps = 0;
    const std::string turn_image_path = ctx->pending_image_path;
    if (!turn_image_path.empty() && !ctx->text_only) {
        if (!mb_ensure_vision(ctx, "prefill_text (image turn)")) {
            return -1;
        }
        mtmd_bitmap * raw_bmp = mb_bitmap_from_file(ctx->vision.get(), turn_image_path.c_str());
        if (!raw_bmp) {
            set_error(ctx, "prefill_text: failed to load pending image: " + turn_image_path);
            return -1;
        }
        bmp.reset(raw_bmp);
        bmp_arr[0] = bmp.get();
        n_bitmaps = 1;
        ctx->pending_image_path.clear();
    }

    // An eager embedding is only valid for the exact image this turn tokenizes.
    // Anything else (no image this turn, or a different path) drops it and
    // eval_prefill falls back to encoding inline.
    if (ctx->pending_image.valid() && ctx->pending_image.path != turn_image_path) {
        ctx->pending_image.clear();
    }

    int32_t res = mtmd_tokenize(ctx->vision.get(), chunks, &in, n_bitmaps ? bmp_arr : nullptr, n_bitmaps);
    if (res != 0) {
        set_error(ctx, "prefill_text: mtmd_tokenize failed, res=" + std::to_string(res));
        return -1;
    }

    const llama_pos start_n_past = ctx->n_past;
    llama_pos new_n_past = start_n_past;
    // tokenize（含图像预处理/切片）不算 prefill，见 perf_prep_ms 的说明。
    const double t_prefill_start = now_ms();
    int32_t ev = eval_prefill(ctx, chunks, /*logits_last=*/true, &new_n_past);
    if (ev != 0) {
        const bool clean_rollback = rollback_to_n_past(ctx, start_n_past);
        const std::string suffix = clean_rollback
            ? " (KV rolled back to n_past=" + std::to_string(start_n_past) + ")"
            : " (partial rollback unsupported on SSM/hybrid; full wipe + n_past=0; conversation history cleared)";
        set_error(ctx, "prefill_text: eval_prefill failed, ret=" + std::to_string(ev) + suffix);
        return -1;
    }

    ctx->n_past = new_n_past;
    perf_add_prep  (ctx, t_prefill_start - t0);
    perf_add_prefill(ctx, static_cast<int32_t>(mtmd_helper_get_n_tokens(chunks)), t_prefill_start);

// embedding 已进 KV，其后不再需要 ViT。首轮无图的情形也覆盖（门控在首轮，
// 避免逐帧会话中途重载）。
    const bool opening_turn = (start_n_past_for_perf == 0);
    if (!ctx->text_only && (n_bitmaps > 0 || opening_turn)) {
        mb_release_vision(ctx, n_bitmaps > 0 ? "image prefill" : "text-only opening turn");
    }
    return 0;
}

void mb_mtmd_perf_reset(mb_mtmd_context * ctx) {
    if (!ctx) return;
    ctx->perf_prefill_tokens = 0;
    ctx->perf_decode_tokens = 0;
    ctx->perf_prefill_ms = 0;
    ctx->perf_decode_ms = 0;
    ctx->perf_prep_ms = 0;
    ctx->perf_image_tokens = 0;
    ctx->perf_image_ms = 0;
    ctx->perf_turn_open = false;
}

mb_mtmd_perf mb_mtmd_perf_snapshot(mb_mtmd_context * ctx) {
    mb_mtmd_perf p = {};
    if (!ctx) return p;
    p.prefill_tokens = ctx->perf_prefill_tokens;
    p.decode_tokens  = ctx->perf_decode_tokens;
    p.prefill_ms     = ctx->perf_prefill_ms;
    p.decode_ms      = ctx->perf_decode_ms;
    p.prep_ms        = ctx->perf_prep_ms;
    p.moe_k_prefill  = ctx->moe_k_prefill;
    p.moe_k_decode   = ctx->moe_k_decode;
    p.image_tokens   = ctx->perf_image_tokens;
    p.image_encode_ms = ctx->perf_image_ms;
    ctx->perf_turn_open = false;
    mb_logf("[MBMtmd] perf app: prefill %d tok / %.1f ms = %.2f t/s | decode %d tok / %.1f ms = %.2f t/s | K%d/%d",
            p.prefill_tokens, p.prefill_ms, tok_per_sec(p.prefill_tokens, p.prefill_ms),
            p.decode_tokens, p.decode_ms, tok_per_sec(p.decode_tokens, p.decode_ms),
            p.moe_k_prefill, p.moe_k_decode);
    if (p.image_tokens > 0) {
        // Measured at image-select time, so it sits outside prefill_ms by design.
        mb_logf("[MBMtmd] perf image: %d tok encoded in %.1f ms (eager, outside prefill)",
                p.image_tokens, p.image_encode_ms);
    }
    // One-shot, same as the eager embedding it describes.
    ctx->perf_image_tokens = 0;
    ctx->perf_image_ms = 0;
    if (ctx->lctx) {
        const llama_perf_context_data lp = llama_perf_context(ctx->lctx.get());
        mb_logf("[MBMtmd] perf llama: n_p_eval=%d t_p_eval=%.1f ms = %.2f t/s | n_eval=%d t_eval=%.1f ms = %.2f t/s",
                lp.n_p_eval, lp.t_p_eval_ms, tok_per_sec(lp.n_p_eval, lp.t_p_eval_ms),
                lp.n_eval, lp.t_eval_ms, tok_per_sec(lp.n_eval, lp.t_eval_ms));
    }
    if (ctx->spec_rounds > 0) {
        mb_logf("[MBMtmd] spec stats: rounds=%zu drafted=%zu accepted=%zu accept_rate=%.1f%% avg_accept=%.2f",
                ctx->spec_rounds, ctx->spec_drafted, ctx->spec_accepted,
                ctx->spec_drafted > 0 ? 100.0 * (double) ctx->spec_accepted / (double) ctx->spec_drafted : 0.0,
                ctx->spec_rounds  > 0 ? (double) ctx->spec_accepted / (double) ctx->spec_rounds : 0.0);
    }
    mb_park_moe_expert_memory(ctx, "after generation");
    return p;
}

// Same counters as snapshot, but does not close the turn, log, or park memory.
// Used to refresh the on-screen live speed while generation is still running.
mb_mtmd_perf mb_mtmd_perf_peek(mb_mtmd_context * ctx) {
    mb_mtmd_perf p = {};
    if (!ctx) return p;
    p.prefill_tokens = ctx->perf_prefill_tokens;
    p.decode_tokens  = ctx->perf_decode_tokens;
    p.prefill_ms     = ctx->perf_prefill_ms;
    p.decode_ms      = ctx->perf_decode_ms;
    p.prep_ms        = ctx->perf_prep_ms;
    p.moe_k_prefill  = ctx->moe_k_prefill;
    p.moe_k_decode   = ctx->moe_k_decode;
    p.image_tokens   = ctx->perf_image_tokens;
    p.image_encode_ms = ctx->perf_image_ms;
    return p;
}

// DSpark 投机一轮：采样锚点 → 起草 → 目标验证 → 受理/回滚 → 把已受理 token 灌进 spec_out。
// 返回 spec_out 的第一个片段（也可能是「本轮无输出」）。
static mb_mtmd_token mb_mtmd_loop_spec(mb_mtmd_context * ctx, double t0) {
    auto * spec = static_cast<common_speculative *>(ctx->spec);

    // A) 锚点。本轮第一个 token：prefill 后第一次从当前 logits 采样，且必须吐给 UI；
    //    之后各轮的锚点 = 上一轮的 bonus token（sample_and_accept_n 已采样并 accept 过，
    //    这里既不能重复采样也不能重复吐）。
    if (!ctx->spec_anchor_valid) {
        const llama_token id = llama_sampler_sample(ctx->sampler.get(), ctx->lctx.get(), /*idx=*/-1);
        llama_sampler_accept(ctx->sampler.get(), id);
        ctx->spec_anchor = id;
        ctx->spec_anchor_valid = true;

        if (llama_vocab_is_eog(ctx->vocab, id)) {
            // 锚点就是 EOG：与逐 token 路径一致 —— 也 decode 进 KV，但不产出片段。
            batch_add_one(ctx->batch, id, ctx->n_past, /*seq=*/0);
            ctx->n_past += 1;
            if (llama_decode(ctx->lctx.get(), ctx->batch) != 0) {
                set_error(ctx, "loop(spec): llama_decode(EOG anchor) failed");
            }
            ctx->perf_decode_tokens += 1;
            ctx->perf_decode_ms += std::max(0.0, now_ms() - t0);
            ctx->spec_anchor_valid = false;
            ctx->spec_end_after = false;
            mb_mtmd_token e = { /*token=*/nullptr, /*is_end=*/true };
            return e;
        }

        ctx->cached_piece += token_to_piece_impl(ctx->vocab, id);
        if (is_valid_utf8(ctx->cached_piece.c_str())) {
            ctx->spec_out.push_back(std::move(ctx->cached_piece));
            ctx->cached_piece.clear();
        }
        ctx->perf_decode_tokens += 1;
    }

    // B) 首次 begin（DSpark 的 begin 只校验草稿 KV 的 pos_max，不建 cache）。
    if (!ctx->spec_began) {
        common_speculative_begin(spec, /*seq_id=*/0, ctx->spec_prompt);
        ctx->spec_began = true;
    }

    // C) 起草。DSPARK 的 draft() 只读 dp.n_past / dp.id_last（块宽用 params.n_max）。
    std::vector<llama_token> draft;
    {
        auto & dp = common_speculative_get_draft_params(spec, /*seq_id=*/0);
        dp.drafting = true;
        dp.n_max    = ctx->spec_n_max;
        dp.n_past   = ctx->n_past;
        dp.id_last  = ctx->spec_anchor;
        dp.prompt   = &ctx->spec_prompt;
        dp.result   = &draft;
    }
    common_speculative_draft(spec);

// C2) 删掉草稿刚写进去的噪声块。draft() 会往 [n_past, n_past+n_max-1] 写占位 token，
// 不清掉会让随后的特征注入撞 M-RoPE 位置检查（X-Y = n_max-1 → 每次验证都失败）。
// server-context.cpp 在同一位置做了同样的事。详见文档 §16。
    if (ctx->lctx_dft) {
        common_context_seq_rm(ctx->lctx_dft.get(), /*seq_id=*/0, ctx->n_past, /*p1=*/-1);
    }

    apply_moe_k(ctx, ctx->moe_k_decode > 0 ? ctx->moe_k_decode : MB_MOE_K_DECODE);

    const bool draft_empty = draft.empty();

    // D) 组目标批：[anchor @ n_past, draft[0] @ n_past+1, ...]，全部要 logits。
    {
        int32_t nt = 0;
        auto add = [&](llama_token t, llama_pos p) {
            ctx->batch.token[nt]     = t;
            ctx->batch.pos[nt]       = p;
            ctx->batch.n_seq_id[nt]  = 1;
            ctx->batch.seq_id[nt][0] = 0;
            ctx->batch.logits[nt]    = 1;
            nt++;
        };
        add(ctx->spec_anchor, ctx->n_past);
        for (size_t i = 0; i < draft.size(); i++) {
            add(draft[i], ctx->n_past + 1 + static_cast<llama_pos>(i));
        }
        ctx->batch.n_tokens = nt;
    }

    // E) 目标前向 + 喂草稿侧（编码器/解码器要用目标的中间层特征）。
    if (llama_decode(ctx->lctx.get(), ctx->batch) != 0) {
        ctx->perf_decode_ms += std::max(0.0, now_ms() - t0);
        set_error(ctx, "loop(spec): llama_decode failed");
        mb_mtmd_token e = { /*token=*/nullptr, /*is_end=*/true };
        return e;
    }
    if (!common_speculative_process(spec, ctx->batch)) {
        fprintf(stderr, "[MBMtmd] common_speculative_process() failed during verify; "
                        "next draft may degrade\n");
        fflush(stderr);
    }

    if (draft_empty) {
        // 没有草稿：锚点已随上面的 batch 进 KV，本轮到此为止；下一轮重新采样锚点。
        ctx->n_past += 1;
        ctx->perf_decode_tokens += 1;
        ctx->perf_decode_ms += std::max(0.0, now_ms() - t0);
        ctx->spec_rounds++;
        ctx->spec_anchor_valid = false;
        return spec_drain(ctx);
    }

    // F) 受理：复刻 common_sampler_sample_and_accept_n()。App 用裸 llama_sampler 链，
    //    所以用 llama_sampler_sample/accept 逐行比对 draft，首个不一致处返回修正 token。
    std::vector<llama_token> ids;
    ids.reserve(draft.size() + 1);
    {
        size_t i = 0;
        for (; i < draft.size(); i++) {
            const llama_token id = llama_sampler_sample(ctx->sampler.get(), ctx->lctx.get(),
                                                        static_cast<int32_t>(i));
            llama_sampler_accept(ctx->sampler.get(), id);
            ids.push_back(id);
            if (draft[i] != id) {
                break;
            }
        }
        if (i == draft.size()) {
            const llama_token id = llama_sampler_sample(ctx->sampler.get(), ctx->lctx.get(),
                                                        static_cast<int32_t>(i));
            llama_sampler_accept(ctx->sampler.get(), id);
            ids.push_back(id);
        }
    }
    // ids 至少 1 个：对不上就是 1 个修正 token，全对就是 n_max + 1 个。

    // 诊断：把这一轮的 draft 与目标逐行采样值打出来。
    // 若 `ids[k]`（k>0，即被采纳的草稿位）与逐行采样值一致，说明 accept 是对的；
    // 那时若 base/DSpark 序列仍分叉，就只能是**目标本身的 argmax 变了**（KV/窗口问题）。
    if (getenv("MB_TOKLOG")) {
        fprintf(stderr, "[SPEC] n_past=%d draft=[", (int) ctx->n_past);
        for (size_t k = 0; k < draft.size(); k++) fprintf(stderr, "%s%d", k ? "," : "", (int) draft[k]);
        fprintf(stderr, "] ids=[");
        for (size_t k = 0; k < ids.size(); k++) fprintf(stderr, "%s%d", k ? "," : "", (int) ids[k]);
        fprintf(stderr, "]\n");
    }

    // G) 提交 + 截断被拒行的 KV。n_rs_seq = n_max 保证这里能直接 seq_rm 截断
    //    （checkpoint 存档/恢复那条路本任务没实现）。
    ctx->n_past += static_cast<llama_pos>(ids.size());
    common_context_seq_rm(ctx->lctx.get(), /*seq_id=*/0, ctx->n_past, /*p1=*/-1);

    // 草稿 context 的 KV 也必须截到这里：草稿是 n_rs_seq = 0，引擎不会替它回滚，
    // 不截会让下一轮 process()/draft() 撞 M-RoPE 位置一致性检查（draft 全部 rc=-1）。
    // tools/server/server-context.cpp 在受理后同样显式截断 ctx_dft。
    if (ctx->lctx_dft) {
        common_context_seq_rm(ctx->lctx_dft.get(), /*seq_id=*/0, ctx->n_past, /*p1=*/-1);
    }
    common_speculative_accept(spec, /*seq_id=*/0, static_cast<uint16_t>(ids.size() - 1));

    ctx->spec_rounds++;
    ctx->spec_drafted  += draft.size();
    ctx->spec_accepted += ids.size() - 1;
    ctx->perf_decode_tokens += static_cast<int32_t>(ids.size());
    ctx->perf_decode_ms += std::max(0.0, now_ms() - t0);

    // H) 把 ids 逐个转成输出片段（复用文件里已有的 UTF-8 缓存逻辑）。
    bool hit_eog = false;
    for (size_t i = 0; i < ids.size(); i++) {
        if (llama_vocab_is_eog(ctx->vocab, ids[i])) {
            hit_eog = true;
            break;   // EOG 本身不产出片段，它之后的 token 也不再吐
        }
        ctx->cached_piece += token_to_piece_impl(ctx->vocab, ids[i]);
        mb_toklog("spec", ids[i]);
        if (is_valid_utf8(ctx->cached_piece.c_str())) {
            ctx->spec_out.push_back(std::move(ctx->cached_piece));
            ctx->cached_piece.clear();
        }
    }

    if (hit_eog) {
        // 与逐 token 路径一致：EOG 时把缓存里剩下的字节也吐出去（有损，但不静默吞掉尾部）。
        if (!ctx->cached_piece.empty()) {
            ctx->spec_out.push_back(std::move(ctx->cached_piece));
            ctx->cached_piece.clear();
        }
        ctx->spec_end_after = true;
        ctx->spec_anchor_valid = false;
    } else {
        // 最后一个 ids 是下一轮的锚点；它已经在这一轮吐过了。
        ctx->spec_anchor = ids.back();
        ctx->spec_anchor_valid = true;
    }

    return spec_drain(ctx);
}

mb_mtmd_token mb_mtmd_loop(mb_mtmd_context * ctx) {
    mb_mtmd_token result = { /*token=*/nullptr, /*is_end=*/true };
    if (!ctx || !ctx->lctx || !ctx->sampler) return result;

    const double t0 = now_ms();
    perf_begin_turn_if_needed(ctx);

    // ── 段 A：投机缓冲里还有片段（或只剩一个结束标记）就直接吐 ──
    if (!ctx->spec_out.empty() || ctx->spec_end_after) {
        return spec_drain(ctx);
    }

    // ── 段 B：投机开启时跑一轮投机 ──
    // 未开启投机时走下面逐 token 的原路径，行为一字未改（回归安全网）。
    if (ctx->spec_enabled && ctx->spec) {
        return mb_mtmd_loop_spec(ctx, t0);
    }

    // 1) Sample one token from the most recent decode's logits.
    llama_token tok = llama_sampler_sample(ctx->sampler.get(), ctx->lctx.get(), /*idx=*/-1);
    llama_sampler_accept(ctx->sampler.get(), tok);

    const bool is_eog = llama_vocab_is_eog(ctx->vocab, tok);
    mb_toklog("base", tok);

    // 2) Detokenize for the UI BEFORE we feed it back, but only when the
    //    token is non-EOG (EOG tokens have no user-visible piece).
    std::string piece = is_eog ? std::string() : token_to_piece_impl(ctx->vocab, tok);

    // 3) Always feed the token back into the KV cache, EOG included, to
    //    keep n_past consistent — otherwise a hole opens at pos=n_past-1
    //    and subsequent prefills' attention reads uninitialized memory.
    batch_add_one(ctx->batch, tok, ctx->n_past, /*seq=*/0);
    ctx->n_past++;
    apply_moe_k(ctx, ctx->moe_k_decode > 0 ? ctx->moe_k_decode : MB_MOE_K_DECODE);
    if (llama_decode(ctx->lctx.get(), ctx->batch) != 0) {
        ctx->perf_decode_ms += std::max(0.0, now_ms() - t0);
        set_error(ctx, "loop: llama_decode failed");
        result.is_end = true;
        return result;
    }

    ctx->perf_decode_tokens += 1;
    ctx->perf_decode_ms += std::max(0.0, now_ms() - t0);

    if (is_chatml_moe(ctx->model_version) && ctx->perf_decode_tokens <= 8) {
        fprintf(stderr, "[MBMtmd] decode#%d id=%d piece=", ctx->perf_decode_tokens, tok);
        for (unsigned char c : piece) {
            if (c == '\n') {
                fputs("\\n", stderr);
            } else if (c >= 32 && c < 127) {
                fputc(c, stderr);
            } else {
                fprintf(stderr, "\\x%02x", c);
            }
        }
        fputc('\n', stderr);
        if (piece == "<think>") {
            fprintf(stderr, "[MBMtmd] WARN: model opened <think> — no-think prefix did not stick\n");
        }
    }

    if (is_eog) {
        // Flush any remaining cached bytes on EOG (lossy but ensures we
        // never silently eat trailing output).
        if (!ctx->cached_piece.empty()) {
            piece = ctx->cached_piece;
            ctx->cached_piece.clear();
            result.token = static_cast<char *>(malloc(piece.size() + 1));
            if (result.token) {
                memcpy(result.token, piece.data(), piece.size());
                result.token[piece.size()] = '\0';
            }
        }
        result.is_end = true;
        return result;
    }

    // 4) UTF-8 byte caching: accumulate bytes until they form a valid
    //    UTF-8 sequence.  BPE byte-level tokens for multi-byte chars
    //    (e.g. emoji) arrive as individual bytes that would corrupt
    //    Swift's String(cString:) if passed alone.
    ctx->cached_piece += piece;

    if (is_valid_utf8(ctx->cached_piece.c_str())) {
        const std::string & emit = ctx->cached_piece;
        result.token = static_cast<char *>(malloc(emit.size() + 1));
        if (result.token) {
            memcpy(result.token, emit.data(), emit.size());
            result.token[emit.size()] = '\0';
        }
        ctx->cached_piece.clear();
    }
    // else: result.token stays nullptr → Swift sees empty string, waits
    //       for the next byte token to complete the sequence.

    result.is_end = false;
    return result;
}
