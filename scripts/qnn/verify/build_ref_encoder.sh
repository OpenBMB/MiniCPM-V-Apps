#!/bin/sh
# Build ref_encoder (the ggml reference this whole port is validated against)
# against an existing llama.cpp-omni build tree.
#
#   LLAMA_SRC=/path/to/llama.cpp-omni LLAMA_BUILD=/path/to/llama.cpp-omni/build \
#       ./build_ref_encoder.sh
#
# It links against libmtmd, which exports clip_image_encode(), so no ggml
# sources need to be rebuilt. Configure the build tree first:
#   cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
LLAMA_SRC=${LLAMA_SRC:?set LLAMA_SRC to the llama.cpp-omni checkout}
LLAMA_BUILD=${LLAMA_BUILD:-$LLAMA_SRC/build}
BIN="$LLAMA_BUILD/bin"

"${CXX:-clang++}" -std=c++17 -O2 \
    -I "$LLAMA_SRC/tools/mtmd" \
    -I "$LLAMA_SRC/include" \
    -I "$LLAMA_SRC/ggml/include" \
    "$HERE/ref_encoder.cpp" \
    -L "$BIN" -lmtmd -lllama -lggml -lggml-base \
    -Wl,-rpath,"$BIN" \
    -o "$HERE/ref_encoder"

echo "built $HERE/ref_encoder"
