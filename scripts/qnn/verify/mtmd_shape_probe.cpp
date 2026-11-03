// Measure what mtmd's image preprocessing actually produces, without paying for
// a ViT pass.  mtmd_tokenize() runs get_slice_instructions() + slice_image() and
// records the resulting token count, so the resize decision (and therefore the
// resolution the encoder sees) is fully observable here.
//
// Build: ./build_probe.sh
// Usage: ./mtmd_shape_probe <text.gguf> <mmproj.gguf> <image> [<image> ...]

#include "mtmd.h"
#include "mtmd-helper.h"
#include "llama.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

int main(int argc, char ** argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <text.gguf> <mmproj.gguf> <image> [<image> ...]\n", argv[0]);
        return 2;
    }

    llama_backend_init();

    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = 0; // only the text model's metadata is needed here

    llama_model * model = llama_model_load_from_file(argv[1], mparams);
    if (!model) {
        fprintf(stderr, "failed to load text model: %s\n", argv[1]);
        return 1;
    }

    mtmd_context_params cparams = mtmd_context_params_default();
    cparams.use_gpu     = false;
    cparams.print_timings = false;
    cparams.n_threads   = 4;
    cparams.media_marker = mtmd_default_marker();

    mtmd_context * ctx = mtmd_init_from_file(argv[2], model, cparams);
    if (!ctx) {
        fprintf(stderr, "failed to load mmproj: %s\n", argv[2]);
        llama_model_free(model);
        return 1;
    }

    for (int i = 3; i < argc; ++i) {
        const char * path = argv[i];

        mtmd_bitmap * bmp = mtmd_helper_bitmap_init_from_file(ctx, path);
        if (!bmp) {
            fprintf(stderr, "SKIP %s: cannot decode image\n", path);
            continue;
        }

        // one image placeholder + a trailing prompt, which is what OcrEngine sends
        std::string prompt = std::string(cparams.media_marker) + "\nText Recognition:";
        mtmd_input_text text = { prompt.c_str(), /*add_special=*/true, /*parse_special=*/true };

        const mtmd_bitmap * bitmaps[1] = { bmp };
        mtmd_input_chunks * chunks = mtmd_input_chunks_init();
        const int32_t rc = mtmd_tokenize(ctx, chunks, &text, bitmaps, 1);

        if (rc != 0) {
            fprintf(stderr, "FAIL %s: tokenize rc=%d\n", path, rc);
        } else {
            const size_t n_chunks = mtmd_input_chunks_size(chunks);
            size_t n_img_tok = 0;
            for (size_t c = 0; c < n_chunks; ++c) {
                const mtmd_input_chunk * chunk = mtmd_input_chunks_get(chunks, c);
                if (mtmd_input_chunk_get_type(chunk) == MTMD_INPUT_CHUNK_TYPE_IMAGE) {
                    n_img_tok += mtmd_input_chunk_get_n_tokens(chunk);
                }
            }
            printf("RESULT\t%s\t%zu\n", path, n_img_tok);
            fflush(stdout);
        }

        mtmd_input_chunks_free(chunks);
        mtmd_bitmap_free(bmp);
    }

    mtmd_free(ctx);
    llama_model_free(model);
    llama_backend_free();
    return 0;
}
