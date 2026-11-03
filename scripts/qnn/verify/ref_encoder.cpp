// Reference encoder for the MiniCPM-OCR 1.0 4x vision tower.
//
// Loads only the mmproj, feeds a *pre-processed* f32 image straight into
// `clip_image_encode`, and writes the resulting token embeddings to disk.
// Feeding the post-preprocessing buffer keeps this tool independent of the
// image resize code, so a PyTorch port can be compared against it on exactly
// the same input.
//
// Usage:
//   ref_encoder <mmproj.gguf> <in.f32> <W> <H> <out.f32> [n_threads]
//
//   in.f32  : W*H*3 floats, interleaved RGB (clip_image_f32.buf layout)
//   out.f32 : n_tokens*n_embd floats, one token per row
//
// Optional env:
//   REF_DUMP_DIR   - directory to dump intermediate tensors into
//   REF_DUMP_NAMES - comma separated substrings; only matching tensors dump
//   REF_THREADS    - default thread count

#include "clip.h"
#include "clip-impl.h"

#include "ggml-backend.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

struct dump_ctx {
    std::string dir;
    std::vector<std::string> names;
};

static bool wants(const dump_ctx & d, const struct ggml_tensor * t) {
    if (d.names.empty() || t->name[0] == '\0') {
        return false;
    }
    const std::string n(t->name);
    for (const auto & s : d.names) {
        if (n.find(s) != std::string::npos) {
            return true;
        }
    }
    return false;
}

static bool dump_cb(struct ggml_tensor * t, bool ask, void * user_data) {
    if (ask) {
        return true;
    }
    auto * d = static_cast<dump_ctx *>(user_data);
    if (!wants(*d, t)) {
        return true;
    }

    const int64_t nbytes = ggml_nbytes(t);
    std::vector<uint8_t> stage;
    const void * data = t->data;
    if (!ggml_backend_buffer_is_host(t->buffer)) {
        stage.resize(nbytes);
        ggml_backend_tensor_get(t, stage.data(), 0, nbytes);
        data = stage.data();
    }

    char safe[256];
    size_t k = 0;
    for (const char * p = t->name; *p && k + 1 < sizeof(safe); ++p) {
        const char c = *p;
        safe[k++] = (c == '/' || c == ' ' || c == '\\') ? '_' : c;
    }
    safe[k] = '\0';

    const std::string bin = d->dir + "/" + safe + ".bin";
    FILE * f = fopen(bin.c_str(), "wb");
    if (!f) {
        fprintf(stderr, "cannot write %s\n", bin.c_str());
        return true;
    }
    fwrite(data, 1, nbytes, f);
    fclose(f);

    const std::string txt = d->dir + "/" + safe + ".shape";
    f = fopen(txt.c_str(), "w");
    if (f) {
        fprintf(f, "%s", ggml_type_name(t->type));
        for (int i = 0; i < GGML_MAX_DIMS; ++i) {
            fprintf(f, " %lld", (long long) t->ne[i]);
        }
        fprintf(f, "\n");
        fclose(f);
    }
    return true;
}

int main(int argc, char ** argv) {
    if (argc < 6) {
        fprintf(stderr,
                "usage: %s <mmproj.gguf> <in.f32> <W> <H> <out.f32> [n_threads]\n",
                argv[0]);
        return 2;
    }

    const char * gguf_path = argv[1];
    const char * in_path   = argv[2];
    const int    W         = atoi(argv[3]);
    const int    H         = atoi(argv[4]);
    const char * out_path  = argv[5];

    int n_threads = 8;
    if (const char * e = getenv("REF_THREADS")) {
        n_threads = atoi(e);
    }
    if (argc > 6) {
        n_threads = atoi(argv[6]);
    }

    dump_ctx dctx;
    if (const char * dir = getenv("REF_DUMP_DIR")) {
        dctx.dir = dir;
    }
    if (const char * names = getenv("REF_DUMP_NAMES")) {
        std::string s(names);
        size_t pos = 0;
        while (pos <= s.size()) {
            const size_t comma = s.find(',', pos);
            const std::string item = s.substr(pos, comma == std::string::npos ? std::string::npos : comma - pos);
            if (!item.empty()) {
                dctx.names.push_back(item);
            }
            if (comma == std::string::npos) {
                break;
            }
            pos = comma + 1;
        }
    }

    clip_context_params params{};
    params.use_gpu             = false;
    params.flash_attn_type     = CLIP_FLASH_ATTN_TYPE_DISABLED;
    params.image_min_tokens    = 0;
    params.image_max_tokens    = 0;
    params.image_max_slice_nums = 0;
    params.warmup              = false;
    params.cb_eval             = dctx.names.empty() ? nullptr : dump_cb;
    params.cb_eval_user_data   = &dctx;
    params.no_alloc            = false;

    clip_init_result init = clip_init(gguf_path, params);
    if (!init.ctx_v) {
        fprintf(stderr, "clip_init failed\n");
        return 1;
    }
    clip_ctx * ctx = init.ctx_v;

    fprintf(stderr, "image %dx%d  patch=%d  embd=%d\n",
            W, H, clip_get_patch_size(ctx), clip_n_mmproj_embd(ctx));

    // read the pre-processed image
    std::vector<float> buf(static_cast<size_t>(W) * H * 3);
    FILE * f = fopen(in_path, "rb");
    if (!f) {
        fprintf(stderr, "cannot open %s\n", in_path);
        return 1;
    }
    const size_t got = fread(buf.data(), sizeof(float), buf.size(), f);
    fclose(f);
    if (got != buf.size()) {
        fprintf(stderr, "short read: %zu / %zu floats\n", got, buf.size());
        return 1;
    }

    clip_image_f32 img;
    img.nx  = W;
    img.ny  = H;
    img.buf = std::move(buf);

    const int n_embd   = clip_n_mmproj_embd(ctx);
    const int n_tokens = clip_n_output_tokens(ctx, &img);
    fprintf(stderr, "n_tokens=%d n_embd=%d\n", n_tokens, n_embd);

    std::vector<float> out(static_cast<size_t>(n_tokens) * n_embd, 0.0f);
    if (!clip_image_encode(ctx, n_threads, &img, out.data())) {
        fprintf(stderr, "clip_image_encode failed\n");
        return 1;
    }

    f = fopen(out_path, "wb");
    if (!f) {
        fprintf(stderr, "cannot write %s\n", out_path);
        return 1;
    }
    fwrite(out.data(), sizeof(float), out.size(), f);
    fclose(f);

    double sum = 0.0, sum_sq = 0.0;
    float mn = out[0], mx = out[0];
    for (float v : out) {
        sum += v;
        sum_sq += static_cast<double>(v) * v;
        mn = v < mn ? v : mn;
        mx = v > mx ? v : mx;
    }
    const double mean = sum / out.size();
    fprintf(stderr, "wrote %s  [%d, %d]  mean=%.6f std=%.6f min=%.6f max=%.6f\n",
            out_path, n_tokens, n_embd, mean,
            std::sqrt(sum_sq / out.size() - mean * mean), mn, mx);

    clip_free(ctx);
    return 0;
}
